package server

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	_ "modernc.org/sqlite"
)

const (
	syncSchema       = "loud.sync.v1"
	playbackSchemaV2 = "loud.playback.v2"
	remoteRoot       = "loud://sync-server"
	likedID          = "playlist_liked"
	likedName        = "Liked Songs"
	maxJSONBytes     = 32 << 20
	maxAudioBytes    = 400 << 20
	maxImageBytes    = 12 << 20
	audioMediaType   = "audio/mpeg"
)

type Server struct {
	dataDir        string
	db             *sql.DB
	now            func() time.Time
	playbackEvents *playbackEventHub
	// Bumped on every library write; drives the library ETag so unchanged
	// refreshes cost a 304 instead of the full payload.
	libraryVersion atomic.Int64
	importMu       sync.Mutex
	importJobs     map[string]*ImportJob
}

type HandlerOptions struct {
	WebDir    string
	AuthToken string
}

func Open(dataDir string) (*Server, error) {
	if err := os.MkdirAll(filepath.Join(dataDir, "audio"), 0o755); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Join(dataDir, "artwork"), 0o755); err != nil {
		return nil, err
	}

	dbPath, err := codecDatabasePath(dataDir)
	if err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)

	srv := &Server{
		dataDir:        dataDir,
		db:             db,
		now:            time.Now,
		playbackEvents: newPlaybackEventHub(),
	}
	if err := srv.migrate(context.Background()); err != nil {
		db.Close()
		return nil, err
	}
	return srv, nil
}

func (s *Server) Close() error {
	return s.db.Close()
}

func (s *Server) Handler() http.Handler {
	return s.HandlerWithOptions(HandlerOptions{})
}

func (s *Server) HandlerWithOptions(options HandlerOptions) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.handleHealth)
	mux.HandleFunc("GET /api/v1/library", s.handleLibrary)
	mux.HandleFunc("GET /api/v1/sync/snapshot", s.handleSnapshot)
	mux.HandleFunc("GET /api/v1/export", s.handleExportLibrary)
	mux.HandleFunc("POST /api/v1/import/bundle", s.handleImportBundle)
	mux.HandleFunc("GET /api/v1/import/jobs/{id}", s.handleImportJob)
	mux.HandleFunc("POST /api/v1/sync/push", s.handlePush)
	mux.HandleFunc("PUT /api/v1/tracks/{fingerprint}", s.handleTrackMetadata)
	mux.HandleFunc("PUT /api/v1/tracks/{fingerprint}/liked", s.handleSetTrackLiked)
	mux.HandleFunc("PUT /api/v1/tracks/{fingerprint}/audio", s.handlePutAudio)
	mux.HandleFunc("GET /api/v1/tracks/{fingerprint}/audio", s.handleGetAudio)
	mux.HandleFunc("HEAD /api/v1/tracks/{fingerprint}/audio", s.handleGetAudio)
	mux.HandleFunc("PUT /api/v1/tracks/{fingerprint}/artwork", s.handlePutArtwork)
	mux.HandleFunc("GET /api/v1/tracks/{fingerprint}/artwork", s.handleGetArtwork)
	mux.HandleFunc("HEAD /api/v1/tracks/{fingerprint}/artwork", s.handleGetArtwork)
	mux.HandleFunc("PUT /api/v1/playlists/{id}/artwork", s.handlePutPlaylistArtwork)
	mux.HandleFunc("GET /api/v1/playlists/{id}/artwork", s.handleGetPlaylistArtwork)
	mux.HandleFunc("HEAD /api/v1/playlists/{id}/artwork", s.handleGetPlaylistArtwork)
	mux.HandleFunc("DELETE /api/v1/playlists/{id}/artwork", s.handleDeletePlaylistArtwork)
	mux.HandleFunc("PUT /api/v1/playlists/{id}", s.handlePlaylist)
	mux.HandleFunc("POST /api/v1/aux", s.handleCreateAux)
	mux.HandleFunc("GET /api/v1/aux", s.handleListAux)
	mux.HandleFunc("DELETE /api/v1/aux/{code}", s.handleEndAux)
	mux.HandleFunc("POST /api/v1/aux/join", s.handleJoinAux)
	mux.HandleFunc("POST /api/v1/auth/stream-token", s.handleCreateStreamToken)
	mux.HandleFunc("POST /api/v1/media-grants", s.handleCreateMediaGrant)
	mux.HandleFunc("POST /api/v1/playlists", s.handleCreatePlaylist)
	mux.HandleFunc("DELETE /api/v1/playlists/{id}", s.handleDeletePlaylist)
	mux.HandleFunc("POST /api/v1/playlists/{id}/tracks", s.handleAddPlaylistTrack)
	mux.HandleFunc("PUT /api/v1/playlists/{id}/tracks", s.handleSetPlaylistTracks)
	mux.HandleFunc("DELETE /api/v1/playlists/{id}/tracks/{fingerprint}", s.handleRemovePlaylistTrack)
	mux.HandleFunc("PUT /api/v1/playback-session/{device_id}", s.handlePutPlaybackSession)
	mux.HandleFunc("GET /api/v1/playback-session/{device_id}", s.handleGetPlaybackSession)
	mux.HandleFunc("GET /api/v1/playback-session/latest", s.handleLatestPlaybackSession)
	mux.HandleFunc("GET /api/v1/playback/devices", s.handlePlaybackDevices)
	mux.HandleFunc("PUT /api/v1/playback/devices/{device_id}", s.handlePutPlaybackDevice)
	mux.HandleFunc("GET /api/v1/playback/active", s.handleActivePlayback)
	mux.HandleFunc("PUT /api/v1/playback/transfer", s.handlePlaybackTransfer)
	mux.HandleFunc("GET /api/v1/playback/events", s.handlePlaybackEvents)
	mux.HandleFunc("GET /api/v2/playback", s.handlePlaybackStateV2)
	mux.HandleFunc("POST /api/v2/playback/commands", s.handlePlaybackCommandV2)
	mux.HandleFunc("GET /api/v2/playback/events", s.handlePlaybackEventsV2)

	var handler http.Handler = withGzip(mux)
	if strings.TrimSpace(options.WebDir) != "" {
		handler = serveWebApp(strings.TrimSpace(options.WebDir), mux)
	}
	if strings.TrimSpace(options.AuthToken) != "" {
		handler = withAuth(handler, strings.TrimSpace(options.AuthToken), s)
	}
	return logRequests(withCORS(handler))
}

func (s *Server) migrate(ctx context.Context) error {
	statements := []string{
		`PRAGMA journal_mode = WAL`,
		`PRAGMA synchronous = NORMAL`,
		`CREATE TABLE IF NOT EXISTS meta (
			key TEXT PRIMARY KEY,
			value TEXT NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS tracks (
			fingerprint TEXT PRIMARY KEY,
			metadata_json TEXT NOT NULL,
			title TEXT NOT NULL,
			artist TEXT NOT NULL,
			album TEXT NOT NULL,
			file_name TEXT NOT NULL,
			audio_path TEXT,
			artwork_path TEXT,
			size_bytes INTEGER NOT NULL DEFAULT 0,
			is_liked INTEGER NOT NULL DEFAULT 0,
			updated_at INTEGER NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS playlists (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL,
			is_liked INTEGER NOT NULL DEFAULT 0,
			track_ids_json TEXT NOT NULL,
			updated_at INTEGER NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS playback_sessions (
			device_id TEXT PRIMARY KEY,
			saved_at INTEGER NOT NULL,
			session_json TEXT NOT NULL,
			updated_at INTEGER NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS playback_devices (
			device_id TEXT PRIMARY KEY,
			name TEXT NOT NULL,
			track_id TEXT,
			track_fingerprint TEXT,
			track_title TEXT,
			is_playing INTEGER NOT NULL DEFAULT 0,
			position_seconds REAL NOT NULL DEFAULT 0,
			volume REAL NOT NULL DEFAULT 1,
			updated_at INTEGER NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS active_playback (
			key TEXT PRIMARY KEY,
			device_id TEXT NOT NULL,
			track_id TEXT,
			track_fingerprint TEXT,
			track_title TEXT,
			is_playing INTEGER NOT NULL DEFAULT 0,
			position_seconds REAL NOT NULL DEFAULT 0,
			volume REAL NOT NULL DEFAULT 1,
			updated_at INTEGER NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS playback_state (
			key TEXT PRIMARY KEY,
			revision INTEGER NOT NULL,
			state_json TEXT NOT NULL,
			updated_at INTEGER NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS playback_commands (
			command_id TEXT PRIMARY KEY,
			response_json TEXT NOT NULL,
			created_at INTEGER NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS stream_tokens (
			token TEXT PRIMARY KEY,
			created_at INTEGER NOT NULL,
			expires_at INTEGER NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_tracks_artist ON tracks(artist)`,
		`CREATE INDEX IF NOT EXISTS idx_tracks_album ON tracks(album)`,
		`CREATE INDEX IF NOT EXISTS idx_tracks_updated ON tracks(updated_at)`,
		`CREATE INDEX IF NOT EXISTS idx_playback_devices_updated ON playback_devices(updated_at)`,
		`CREATE INDEX IF NOT EXISTS idx_stream_tokens_expires ON stream_tokens(expires_at)`,
	}

	for _, statement := range statements {
		if _, err := s.db.ExecContext(ctx, statement); err != nil {
			return err
		}
	}

	if _, err := s.db.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS media_grants (
		token TEXT PRIMARY KEY,
		fingerprints_json TEXT NOT NULL,
		created_at INTEGER NOT NULL
	)`); err != nil {
		return err
	}

	if _, err := s.db.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS aux_sessions (
		code TEXT PRIMARY KEY,
		guest_token TEXT NOT NULL UNIQUE,
		created_at INTEGER NOT NULL
	)`); err != nil {
		return err
	}

	// audio_type arrived after the first release; ALTER isn't idempotent,
	// so tolerate the duplicate-column error on databases that have it.
	if _, err := s.db.ExecContext(ctx, `ALTER TABLE tracks ADD COLUMN audio_type TEXT`); err != nil &&
		!strings.Contains(err.Error(), "duplicate column") {
		return err
	}

	_, err := s.serverID(ctx)
	return err
}

func codecDatabasePath(dataDir string) (string, error) {
	codecPath := filepath.Join(dataDir, "codec-sync.sqlite")
	if _, err := os.Stat(codecPath); err == nil {
		return codecPath, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}

	oldPath := filepath.Join(dataDir, "loud-sync.sqlite")
	if _, err := os.Stat(oldPath); err == nil {
		for _, suffix := range []string{"", "-wal", "-shm"} {
			oldFile := oldPath + suffix
			codecFile := codecPath + suffix
			if _, statErr := os.Stat(oldFile); errors.Is(statErr, os.ErrNotExist) {
				continue
			} else if statErr != nil {
				return "", statErr
			}
			if err := os.Rename(oldFile, codecFile); err != nil {
				return "", err
			}
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}

	return codecPath, nil
}

func (s *Server) serverID(ctx context.Context) (string, error) {
	var id string
	err := s.db.QueryRowContext(ctx, `SELECT value FROM meta WHERE key = 'server_id'`).Scan(&id)
	if err == nil {
		return id, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return "", err
	}

	random := make([]byte, 16)
	if _, err := rand.Read(random); err != nil {
		return "", err
	}
	id = "server_" + hex.EncodeToString(random)
	_, err = s.db.ExecContext(ctx, `INSERT INTO meta(key, value) VALUES('server_id', ?)`, id)
	return id, err
}
