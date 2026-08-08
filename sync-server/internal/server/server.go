package server

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
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
}

type HandlerOptions struct {
	WebDir    string
	AuthToken string
}

type playbackEventHub struct {
	mu          sync.Mutex
	nextID      int
	subscribers map[int]chan PlaybackEvent
}

func newPlaybackEventHub() *playbackEventHub {
	return &playbackEventHub{subscribers: map[int]chan PlaybackEvent{}}
}

func (h *playbackEventHub) subscribe() (<-chan PlaybackEvent, func()) {
	h.mu.Lock()
	defer h.mu.Unlock()

	id := h.nextID
	h.nextID++
	ch := make(chan PlaybackEvent, 32)
	h.subscribers[id] = ch

	return ch, func() {
		h.mu.Lock()
		defer h.mu.Unlock()
		delete(h.subscribers, id)
		close(ch)
	}
}

func (h *playbackEventHub) broadcast(event PlaybackEvent) {
	h.mu.Lock()
	defer h.mu.Unlock()

	for _, ch := range h.subscribers {
		select {
		case ch <- event:
		default:
		}
	}
}

func Open(dataDir string) (*Server, error) {
	if err := os.MkdirAll(filepath.Join(dataDir, "audio"), 0o755); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Join(dataDir, "artwork"), 0o755); err != nil {
		return nil, err
	}

	db, err := sql.Open("sqlite", filepath.Join(dataDir, "loud-sync.sqlite"))
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
	mux.HandleFunc("POST /api/v1/sync/push", s.handlePush)
	mux.HandleFunc("PUT /api/v1/tracks/{fingerprint}", s.handleTrackMetadata)
	mux.HandleFunc("PUT /api/v1/tracks/{fingerprint}/audio", s.handlePutAudio)
	mux.HandleFunc("GET /api/v1/tracks/{fingerprint}/audio", s.handleGetAudio)
	mux.HandleFunc("HEAD /api/v1/tracks/{fingerprint}/audio", s.handleGetAudio)
	mux.HandleFunc("PUT /api/v1/tracks/{fingerprint}/artwork", s.handlePutArtwork)
	mux.HandleFunc("GET /api/v1/tracks/{fingerprint}/artwork", s.handleGetArtwork)
	mux.HandleFunc("HEAD /api/v1/tracks/{fingerprint}/artwork", s.handleGetArtwork)
	mux.HandleFunc("PUT /api/v1/playlists/{id}", s.handlePlaylist)
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

	var handler http.Handler = mux
	if strings.TrimSpace(options.WebDir) != "" {
		handler = serveWebApp(strings.TrimSpace(options.WebDir), mux)
	}
	if strings.TrimSpace(options.AuthToken) != "" {
		handler = withAuth(handler, strings.TrimSpace(options.AuthToken))
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
		`CREATE INDEX IF NOT EXISTS idx_tracks_artist ON tracks(artist)`,
		`CREATE INDEX IF NOT EXISTS idx_tracks_album ON tracks(album)`,
		`CREATE INDEX IF NOT EXISTS idx_tracks_updated ON tracks(updated_at)`,
		`CREATE INDEX IF NOT EXISTS idx_playback_devices_updated ON playback_devices(updated_at)`,
	}

	for _, statement := range statements {
		if _, err := s.db.ExecContext(ctx, statement); err != nil {
			return err
		}
	}

	_, err := s.serverID(ctx)
	return err
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

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":              true,
		"schema":          syncSchema,
		"playback_schema": playbackSchemaV2,
	})
}

func (s *Server) handleLibrary(w http.ResponseWriter, r *http.Request) {
	snapshot, err := s.snapshot(r.Context(), publicBaseURL(r))
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, snapshot.Library)
}

func (s *Server) handleSnapshot(w http.ResponseWriter, r *http.Request) {
	snapshot, err := s.snapshot(r.Context(), publicBaseURL(r))
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, snapshot)
}

func (s *Server) handlePush(w http.ResponseWriter, r *http.Request) {
	var req PushRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	if req.Schema != "" && req.Schema != syncSchema {
		writeError(w, http.StatusBadRequest, fmt.Errorf("unsupported sync schema %q", req.Schema))
		return
	}

	report := SyncReport{}
	for _, track := range req.Library.Tracks {
		if err := s.upsertTrack(r.Context(), track); err != nil {
			writeError(w, http.StatusBadRequest, err)
			return
		}
		report.TracksUpserted++
	}
	for _, playlist := range req.Library.Playlists {
		if err := s.upsertPlaylist(r.Context(), playlist); err != nil {
			writeError(w, http.StatusBadRequest, err)
			return
		}
		report.PlaylistsUpserted++
	}
	if req.PlaybackSession != nil {
		deviceID := strings.TrimSpace(req.PlaybackSession.DeviceID)
		if deviceID == "" {
			deviceID = strings.TrimSpace(req.DeviceID)
		}
		if deviceID != "" {
			req.PlaybackSession.DeviceID = deviceID
			if err := s.upsertPlaybackSession(r.Context(), *req.PlaybackSession); err != nil {
				writeError(w, http.StatusBadRequest, err)
				return
			}
			report.SessionsUpserted++
		}
	}
	writeJSON(w, http.StatusOK, report)
}

func (s *Server) handleTrackMetadata(w http.ResponseWriter, r *http.Request) {
	var track Track
	if err := decodeJSON(r, &track); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	if track.Fingerprint == "" {
		track.Fingerprint = r.PathValue("fingerprint")
	}
	if track.Fingerprint != r.PathValue("fingerprint") {
		writeError(w, http.StatusBadRequest, errors.New("fingerprint mismatch"))
		return
	}
	if err := s.upsertTrack(r.Context(), track); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handlePlaylist(w http.ResponseWriter, r *http.Request) {
	var playlist Playlist
	if err := decodeJSON(r, &playlist); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	if playlist.ID == "" {
		playlist.ID = r.PathValue("id")
	}
	if playlist.ID != r.PathValue("id") {
		writeError(w, http.StatusBadRequest, errors.New("playlist id mismatch"))
		return
	}
	if err := s.upsertPlaylist(r.Context(), playlist); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handlePutAudio(w http.ResponseWriter, r *http.Request) {
	fingerprint := cleanFingerprint(r.PathValue("fingerprint"))
	if fingerprint == "" {
		writeError(w, http.StatusBadRequest, errors.New("missing fingerprint"))
		return
	}
	path := s.audioPath(fingerprint)
	size, err := writeRequestBody(path, r.Body, maxAudioBytes)
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	if err := s.attachMediaPath(r.Context(), fingerprint, "audio_path", path, size); err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleGetAudio(w http.ResponseWriter, r *http.Request) {
	fingerprint := cleanFingerprint(r.PathValue("fingerprint"))
	path, err := s.mediaPath(r.Context(), fingerprint, "audio_path")
	if err != nil {
		writeError(w, http.StatusNotFound, err)
		return
	}
	serveMedia(w, r, path, audioMediaType)
}

func (s *Server) handlePutArtwork(w http.ResponseWriter, r *http.Request) {
	fingerprint := cleanFingerprint(r.PathValue("fingerprint"))
	if fingerprint == "" {
		writeError(w, http.StatusBadRequest, errors.New("missing fingerprint"))
		return
	}
	path := s.artworkPath(fingerprint)
	if _, _, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err != nil && r.Header.Get("Content-Type") != "" {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	_, err := writeRequestBody(path, r.Body, maxImageBytes)
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	if err := s.attachMediaPath(r.Context(), fingerprint, "artwork_path", path, 0); err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleGetArtwork(w http.ResponseWriter, r *http.Request) {
	fingerprint := cleanFingerprint(r.PathValue("fingerprint"))
	path, err := s.mediaPath(r.Context(), fingerprint, "artwork_path")
	if err != nil {
		writeError(w, http.StatusNotFound, err)
		return
	}
	serveMedia(w, r, path, "image/jpeg")
}

func (s *Server) handlePutPlaybackSession(w http.ResponseWriter, r *http.Request) {
	var session PlaybackSession
	if err := decodeJSON(r, &session); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	session.DeviceID = r.PathValue("device_id")
	if err := s.upsertPlaybackSession(r.Context(), session); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleGetPlaybackSession(w http.ResponseWriter, r *http.Request) {
	session, err := s.playbackSession(r.Context(), r.PathValue("device_id"), false)
	if err != nil {
		writeError(w, http.StatusNotFound, err)
		return
	}
	writeJSON(w, http.StatusOK, session)
}

func (s *Server) handleLatestPlaybackSession(w http.ResponseWriter, r *http.Request) {
	session, err := s.playbackSession(r.Context(), "", true)
	if err != nil {
		writeError(w, http.StatusNotFound, err)
		return
	}
	writeJSON(w, http.StatusOK, session)
}

func (s *Server) handlePlaybackDevices(w http.ResponseWriter, r *http.Request) {
	devices, err := s.playbackDevices(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, nonNilPlaybackDevices(devices))
}

func (s *Server) handlePutPlaybackDevice(w http.ResponseWriter, r *http.Request) {
	var device PlaybackDevice
	if err := decodeJSON(r, &device); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	device.DeviceID = r.PathValue("device_id")
	device, err := s.upsertPlaybackDevice(r.Context(), device)
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	s.playbackEvents.broadcast(PlaybackEvent{Type: "device", Device: &device})
	if active, updated, err := s.updateActivePlaybackFromDevice(r.Context(), device); err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	} else if updated {
		s.playbackEvents.broadcast(PlaybackEvent{Type: "active", Active: &active})
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleActivePlayback(w http.ResponseWriter, r *http.Request) {
	active, err := s.activePlayback(r.Context())
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			writeJSON(w, http.StatusOK, nil)
			return
		}
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, active)
}

func (s *Server) handlePlaybackTransfer(w http.ResponseWriter, r *http.Request) {
	var req PlaybackTransferRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	active, err := s.transferPlayback(r.Context(), req)
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	s.playbackEvents.broadcast(PlaybackEvent{Type: "active", Active: &active})
	if devices, err := s.playbackDevices(r.Context()); err == nil {
		s.playbackEvents.broadcast(PlaybackEvent{Type: "devices", Devices: devices})
	}
	writeJSON(w, http.StatusOK, active)
}

func (s *Server) handlePlaybackEvents(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, errors.New("streaming is not supported"))
		return
	}

	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache, no-transform")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	if devices, err := s.playbackDevices(r.Context()); err == nil {
		writeSSE(w, "devices", PlaybackEvent{Type: "devices", Devices: devices})
	}
	if active, err := s.activePlayback(r.Context()); err == nil {
		writeSSE(w, "active", PlaybackEvent{Type: "active", Active: &active})
	}
	flusher.Flush()

	events, unsubscribe := s.playbackEvents.subscribe()
	defer unsubscribe()

	heartbeat := time.NewTicker(15 * time.Second)
	defer heartbeat.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case <-heartbeat.C:
			_, _ = io.WriteString(w, ": heartbeat\n\n")
			flusher.Flush()
		case event := <-events:
			writeSSE(w, event.Type, event)
			flusher.Flush()
		}
	}
}

func (s *Server) handlePlaybackStateV2(w http.ResponseWriter, r *http.Request) {
	state, err := s.playbackStateV2(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	if state == nil {
		writeJSON(w, http.StatusOK, nil)
		return
	}
	nowMS := s.now().UnixMilli()
	state.ServerTimeMS = nowMS
	writeJSON(w, http.StatusOK, state)
}

func (s *Server) handlePlaybackCommandV2(w http.ResponseWriter, r *http.Request) {
	var req PlaybackCommandV2
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}

	state, duplicate, err := s.applyPlaybackCommandV2(r.Context(), req)
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	if !duplicate {
		s.playbackEvents.broadcast(PlaybackEvent{Type: "playback_state", PlaybackState: &state})
	}
	writeJSON(w, http.StatusOK, state)
}

func (s *Server) handlePlaybackEventsV2(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, errors.New("streaming is not supported"))
		return
	}

	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache, no-transform")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	if devices, err := s.playbackDevices(r.Context()); err == nil {
		writeSSE(w, "devices", PlaybackEvent{Type: "devices", Devices: devices})
	}
	if state, err := s.playbackStateV2(r.Context()); err == nil && state != nil {
		state.ServerTimeMS = s.now().UnixMilli()
		writeSSE(w, "playback_state", PlaybackEvent{Type: "playback_state", PlaybackState: state})
	}
	flusher.Flush()

	events, unsubscribe := s.playbackEvents.subscribe()
	defer unsubscribe()

	heartbeat := time.NewTicker(15 * time.Second)
	defer heartbeat.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case <-heartbeat.C:
			_, _ = io.WriteString(w, ": heartbeat\n\n")
			flusher.Flush()
		case event := <-events:
			if event.Type != "devices" && event.Type != "device" && event.Type != "playback_state" {
				continue
			}
			writeSSE(w, event.Type, event)
			flusher.Flush()
		}
	}
}

func (s *Server) snapshot(ctx context.Context, baseURL string) (SyncSnapshot, error) {
	serverID, err := s.serverID(ctx)
	if err != nil {
		return SyncSnapshot{}, err
	}
	tracks, err := s.tracks(ctx, baseURL)
	if err != nil {
		return SyncSnapshot{}, err
	}
	playlists, err := s.playlists(ctx)
	if err != nil {
		return SyncSnapshot{}, err
	}
	playlists = ensureLikedPlaylist(playlists, tracks)
	attachPlaylistIDs(tracks, playlists)
	tracks = nonNilTracks(tracks)
	playlists = nonNilPlaylists(playlists)
	artists := nonNilArtists(summarizeArtists(tracks))
	albums := nonNilAlbums(summarizeAlbums(tracks))

	library := Library{
		RootPath:  remoteRoot,
		ScannedAt: s.now().Unix(),
		Stats:     summarizeStats(tracks, playlists),
		Artists:   artists,
		Albums:    albums,
		Playlists: playlists,
		Tracks:    tracks,
	}
	return SyncSnapshot{
		Schema:      syncSchema,
		ServerID:    serverID,
		GeneratedAt: s.now().Unix(),
		Library:     library,
	}, nil
}

func (s *Server) upsertTrack(ctx context.Context, track Track) error {
	track.Fingerprint = cleanFingerprint(track.Fingerprint)
	if track.Fingerprint == "" {
		return errors.New("track fingerprint is required")
	}
	if track.ID == "" {
		track.ID = "track_" + track.Fingerprint
	}
	if track.Title == "" {
		track.Title = strings.TrimSuffix(track.FileName, filepath.Ext(track.FileName))
	}
	if track.Title == "" {
		track.Title = "Unknown Track"
	}
	if track.Artist == "" {
		track.Artist = "Unknown Artist"
	}
	if track.Album == "" {
		track.Album = "Unknown Album"
	}
	if track.FileName == "" {
		track.FileName = safeFileName(track.Title + ".mp3")
	}
	if track.Path == "" || strings.HasPrefix(track.Path, "/") {
		track.Path = remoteTrackPath(track)
	}
	track.UpdatedAt = s.now().Unix()

	metadata, err := json.Marshal(track)
	if err != nil {
		return err
	}

	_, err = s.db.ExecContext(ctx, `
		INSERT INTO tracks(fingerprint, metadata_json, title, artist, album, file_name, size_bytes, is_liked, updated_at)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(fingerprint) DO UPDATE SET
			metadata_json = excluded.metadata_json,
			title = excluded.title,
			artist = excluded.artist,
			album = excluded.album,
			file_name = excluded.file_name,
			size_bytes = CASE WHEN excluded.size_bytes > 0 THEN excluded.size_bytes ELSE tracks.size_bytes END,
			is_liked = excluded.is_liked,
			updated_at = excluded.updated_at
	`, track.Fingerprint, string(metadata), track.Title, track.Artist, track.Album, track.FileName, track.SizeBytes, boolInt(track.IsLiked), track.UpdatedAt)
	return err
}

func (s *Server) upsertPlaylist(ctx context.Context, playlist Playlist) error {
	playlist.ID = strings.TrimSpace(playlist.ID)
	if playlist.ID == "" {
		return errors.New("playlist id is required")
	}
	if playlist.Name == "" {
		playlist.Name = "Playlist"
	}
	if playlist.Path == "" {
		playlist.Path = "loud://playlist/" + playlist.ID
	}
	trackIDs, err := json.Marshal(dedupeStrings(playlist.TrackIDs))
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO playlists(id, name, is_liked, track_ids_json, updated_at)
		VALUES(?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			name = excluded.name,
			is_liked = excluded.is_liked,
			track_ids_json = excluded.track_ids_json,
			updated_at = excluded.updated_at
	`, playlist.ID, playlist.Name, boolInt(playlist.IsLiked), string(trackIDs), s.now().Unix())
	return err
}

func (s *Server) tracks(ctx context.Context, baseURL string) ([]Track, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT metadata_json, audio_path, artwork_path, size_bytes, is_liked, updated_at FROM tracks ORDER BY artist, album, title`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var tracks []Track
	for rows.Next() {
		var metadata string
		var audioPath sql.NullString
		var artworkPath sql.NullString
		var sizeBytes int64
		var liked int
		var updatedAt int64
		if err := rows.Scan(&metadata, &audioPath, &artworkPath, &sizeBytes, &liked, &updatedAt); err != nil {
			return nil, err
		}
		var track Track
		if err := json.Unmarshal([]byte(metadata), &track); err != nil {
			return nil, err
		}
		track.Path = remoteTrackPath(track)
		track.SizeBytes = maxInt64(track.SizeBytes, sizeBytes)
		track.IsLiked = liked == 1
		track.UpdatedAt = updatedAt
		if audioPath.Valid {
			url := fmt.Sprintf("%s/api/v1/tracks/%s/audio", baseURL, pathEscape(track.Fingerprint))
			track.AudioURL = &url
		}
		if artworkPath.Valid {
			url := fmt.Sprintf("%s/api/v1/tracks/%s/artwork", baseURL, pathEscape(track.Fingerprint))
			track.ArtworkURL = &url
		}
		tracks = append(tracks, track)
	}
	return nonNilTracks(tracks), rows.Err()
}

func (s *Server) playlists(ctx context.Context) ([]Playlist, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, name, is_liked, track_ids_json FROM playlists ORDER BY is_liked DESC, lower(name)`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var playlists []Playlist
	for rows.Next() {
		var playlist Playlist
		var liked int
		var rawTrackIDs string
		if err := rows.Scan(&playlist.ID, &playlist.Name, &liked, &rawTrackIDs); err != nil {
			return nil, err
		}
		playlist.IsLiked = liked == 1
		playlist.Path = "loud://playlist/" + playlist.ID
		if err := json.Unmarshal([]byte(rawTrackIDs), &playlist.TrackIDs); err != nil {
			return nil, err
		}
		playlists = append(playlists, playlist)
	}
	return nonNilPlaylists(playlists), rows.Err()
}

func (s *Server) attachMediaPath(ctx context.Context, fingerprint, column, path string, size int64) error {
	if column != "audio_path" && column != "artwork_path" {
		return errors.New("invalid media column")
	}
	if _, err := os.Stat(path); err != nil {
		return err
	}

	result, err := s.db.ExecContext(ctx, fmt.Sprintf(`
		UPDATE tracks SET %s = ?, size_bytes = CASE WHEN ? > 0 THEN ? ELSE size_bytes END, updated_at = ? WHERE fingerprint = ?
	`, column), path, size, size, s.now().Unix(), fingerprint)
	if err != nil {
		return err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if affected > 0 {
		return nil
	}

	track := Track{
		ID:          "track_" + fingerprint,
		Path:        "loud://track/" + fingerprint,
		FileName:    safeFileName(fingerprint + ".mp3"),
		Title:       fingerprint,
		Artist:      "Unknown Artist",
		Album:       "Unknown Album",
		Fingerprint: fingerprint,
		SizeBytes:   size,
		UpdatedAt:   s.now().Unix(),
	}
	if err := s.upsertTrack(ctx, track); err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, fmt.Sprintf(`UPDATE tracks SET %s = ?, size_bytes = CASE WHEN ? > 0 THEN ? ELSE size_bytes END WHERE fingerprint = ?`, column), path, size, size, fingerprint)
	return err
}

func (s *Server) mediaPath(ctx context.Context, fingerprint, column string) (string, error) {
	if column != "audio_path" && column != "artwork_path" {
		return "", errors.New("invalid media column")
	}
	var path sql.NullString
	if err := s.db.QueryRowContext(ctx, fmt.Sprintf(`SELECT %s FROM tracks WHERE fingerprint = ?`, column), fingerprint).Scan(&path); err != nil {
		return "", err
	}
	if !path.Valid || path.String == "" {
		return "", os.ErrNotExist
	}
	if _, err := os.Stat(path.String); err != nil {
		return "", err
	}
	return path.String, nil
}

func (s *Server) upsertPlaybackSession(ctx context.Context, session PlaybackSession) error {
	session.DeviceID = strings.TrimSpace(session.DeviceID)
	if session.DeviceID == "" {
		return errors.New("device id is required")
	}
	if session.SavedAt == 0 {
		session.SavedAt = s.now().UnixMilli()
	}
	raw, err := json.Marshal(session.Session)
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO playback_sessions(device_id, saved_at, session_json, updated_at)
		VALUES(?, ?, ?, ?)
		ON CONFLICT(device_id) DO UPDATE SET
			saved_at = excluded.saved_at,
			session_json = excluded.session_json,
			updated_at = excluded.updated_at
	`, session.DeviceID, session.SavedAt, string(raw), s.now().Unix())
	return err
}

func (s *Server) playbackSession(ctx context.Context, deviceID string, latest bool) (PlaybackSession, error) {
	query := `SELECT device_id, saved_at, session_json, updated_at FROM playback_sessions WHERE device_id = ?`
	args := []any{deviceID}
	if latest {
		query = `SELECT device_id, saved_at, session_json, updated_at FROM playback_sessions ORDER BY saved_at DESC, updated_at DESC LIMIT 1`
		args = nil
	}
	var session PlaybackSession
	var raw string
	if err := s.db.QueryRowContext(ctx, query, args...).Scan(&session.DeviceID, &session.SavedAt, &raw, &session.UpdatedAt); err != nil {
		return PlaybackSession{}, err
	}
	if err := json.Unmarshal([]byte(raw), &session.Session); err != nil {
		return PlaybackSession{}, err
	}
	return session, nil
}

func (s *Server) upsertPlaybackDevice(ctx context.Context, device PlaybackDevice) (PlaybackDevice, error) {
	device.DeviceID = strings.TrimSpace(device.DeviceID)
	if device.DeviceID == "" {
		return PlaybackDevice{}, errors.New("device id is required")
	}
	device.Name = strings.TrimSpace(device.Name)
	if device.Name == "" {
		device.Name = "Loud Device"
	}
	device.PositionSeconds = cleanPlaybackPosition(device.PositionSeconds)
	device.Volume = cleanPlaybackVolume(device.Volume)
	device.UpdatedAt = s.now().UnixMilli()

	_, err := s.db.ExecContext(ctx, `
		INSERT INTO playback_devices(device_id, name, track_id, track_fingerprint, track_title, is_playing, position_seconds, volume, updated_at)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(device_id) DO UPDATE SET
			name = excluded.name,
			track_id = excluded.track_id,
			track_fingerprint = excluded.track_fingerprint,
			track_title = excluded.track_title,
			is_playing = excluded.is_playing,
			position_seconds = excluded.position_seconds,
			volume = excluded.volume,
			updated_at = excluded.updated_at
	`, device.DeviceID, device.Name, nullableString(device.TrackID), nullableString(device.TrackFingerprint), nullableString(device.TrackTitle), boolInt(device.IsPlaying), device.PositionSeconds, device.Volume, device.UpdatedAt)
	return device, err
}

func (s *Server) playbackDevices(ctx context.Context) ([]PlaybackDevice, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT device_id, name, track_id, track_fingerprint, track_title, is_playing, position_seconds, volume, updated_at
		FROM playback_devices
		ORDER BY updated_at DESC, name
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var devices []PlaybackDevice
	for rows.Next() {
		device, err := scanPlaybackDevice(rows)
		if err != nil {
			return nil, err
		}
		devices = append(devices, device)
	}
	return nonNilPlaybackDevices(devices), rows.Err()
}

func (s *Server) transferPlayback(ctx context.Context, req PlaybackTransferRequest) (ActivePlayback, error) {
	req.DeviceID = strings.TrimSpace(req.DeviceID)
	if req.DeviceID == "" {
		return ActivePlayback{}, errors.New("device id is required")
	}

	active := ActivePlayback{
		DeviceID:         req.DeviceID,
		TrackID:          cleanStringPointer(req.TrackID),
		TrackFingerprint: cleanStringPointer(req.TrackFingerprint),
		TrackTitle:       cleanStringPointer(req.TrackTitle),
		IsPlaying:        req.IsPlaying,
		PositionSeconds:  cleanPlaybackPosition(req.PositionSeconds),
		Volume:           cleanPlaybackVolume(req.Volume),
		UpdatedAt:        s.now().UnixMilli(),
	}

	if err := s.storeActivePlayback(ctx, active); err != nil {
		return ActivePlayback{}, err
	}

	_, _ = s.db.ExecContext(ctx, `
		UPDATE playback_devices
		SET track_id = ?, track_fingerprint = ?, track_title = ?, is_playing = ?, position_seconds = ?, volume = ?, updated_at = ?
		WHERE device_id = ?
	`, nullableString(active.TrackID), nullableString(active.TrackFingerprint), nullableString(active.TrackTitle), boolInt(active.IsPlaying), active.PositionSeconds, active.Volume, active.UpdatedAt, active.DeviceID)
	return active, nil
}

func (s *Server) updateActivePlaybackFromDevice(ctx context.Context, device PlaybackDevice) (ActivePlayback, bool, error) {
	current, err := s.activePlayback(ctx)
	if errors.Is(err, sql.ErrNoRows) {
		return ActivePlayback{}, false, nil
	}
	if err != nil {
		return ActivePlayback{}, false, err
	}
	if current.DeviceID != device.DeviceID {
		return ActivePlayback{}, false, nil
	}

	active := ActivePlayback{
		DeviceID:         device.DeviceID,
		TrackID:          cleanStringPointer(device.TrackID),
		TrackFingerprint: cleanStringPointer(device.TrackFingerprint),
		TrackTitle:       cleanStringPointer(device.TrackTitle),
		IsPlaying:        device.IsPlaying,
		PositionSeconds:  cleanPlaybackPosition(device.PositionSeconds),
		Volume:           cleanPlaybackVolume(device.Volume),
		UpdatedAt:        device.UpdatedAt,
	}
	if err := s.storeActivePlayback(ctx, active); err != nil {
		return ActivePlayback{}, false, err
	}
	return active, true, nil
}

func (s *Server) storeActivePlayback(ctx context.Context, active ActivePlayback) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO active_playback(key, device_id, track_id, track_fingerprint, track_title, is_playing, position_seconds, volume, updated_at)
		VALUES('active', ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(key) DO UPDATE SET
			device_id = excluded.device_id,
			track_id = excluded.track_id,
			track_fingerprint = excluded.track_fingerprint,
			track_title = excluded.track_title,
			is_playing = excluded.is_playing,
			position_seconds = excluded.position_seconds,
			volume = excluded.volume,
			updated_at = excluded.updated_at
	`, active.DeviceID, nullableString(active.TrackID), nullableString(active.TrackFingerprint), nullableString(active.TrackTitle), boolInt(active.IsPlaying), active.PositionSeconds, active.Volume, active.UpdatedAt)
	return err
}

func (s *Server) activePlayback(ctx context.Context) (ActivePlayback, error) {
	var active ActivePlayback
	var trackID sql.NullString
	var trackFingerprint sql.NullString
	var trackTitle sql.NullString
	var isPlaying int
	err := s.db.QueryRowContext(ctx, `
		SELECT device_id, track_id, track_fingerprint, track_title, is_playing, position_seconds, volume, updated_at
		FROM active_playback
		WHERE key = 'active'
	`).Scan(&active.DeviceID, &trackID, &trackFingerprint, &trackTitle, &isPlaying, &active.PositionSeconds, &active.Volume, &active.UpdatedAt)
	if err != nil {
		return ActivePlayback{}, err
	}
	active.TrackID = stringFromNull(trackID)
	active.TrackFingerprint = stringFromNull(trackFingerprint)
	active.TrackTitle = stringFromNull(trackTitle)
	active.IsPlaying = isPlaying == 1
	return active, nil
}

func (s *Server) playbackStateV2(ctx context.Context) (*PlaybackStateV2, error) {
	var raw string
	if err := s.db.QueryRowContext(ctx, `SELECT state_json FROM playback_state WHERE key = 'global'`).Scan(&raw); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	state, err := decodePlaybackStateV2(raw)
	if err != nil {
		return nil, err
	}
	return &state, nil
}

func playbackStateV2InTx(ctx context.Context, tx *sql.Tx) (*PlaybackStateV2, error) {
	var raw string
	if err := tx.QueryRowContext(ctx, `SELECT state_json FROM playback_state WHERE key = 'global'`).Scan(&raw); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	state, err := decodePlaybackStateV2(raw)
	if err != nil {
		return nil, err
	}
	return &state, nil
}

func decodePlaybackStateV2(raw string) (PlaybackStateV2, error) {
	var state PlaybackStateV2
	if err := json.Unmarshal([]byte(raw), &state); err != nil {
		return PlaybackStateV2{}, err
	}
	normalizePlaybackStateV2(&state)
	return state, nil
}

func (s *Server) applyPlaybackCommandV2(ctx context.Context, req PlaybackCommandV2) (PlaybackStateV2, bool, error) {
	req.CommandID = strings.TrimSpace(req.CommandID)
	req.Kind = strings.TrimSpace(req.Kind)
	req.DeviceID = strings.TrimSpace(req.DeviceID)
	if req.CommandID == "" {
		return PlaybackStateV2{}, false, errors.New("command id is required")
	}
	if req.Kind == "" {
		return PlaybackStateV2{}, false, errors.New("command kind is required")
	}
	if req.DeviceID == "" {
		return PlaybackStateV2{}, false, errors.New("device id is required")
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return PlaybackStateV2{}, false, err
	}
	defer tx.Rollback()

	nowMS := s.now().UnixMilli()
	if state, ok, err := playbackCommandResponseV2(ctx, tx, req.CommandID, nowMS); err != nil {
		return PlaybackStateV2{}, false, err
	} else if ok {
		if err := tx.Commit(); err != nil {
			return PlaybackStateV2{}, false, err
		}
		return state, true, nil
	}

	current, err := playbackStateV2InTx(ctx, tx)
	if err != nil {
		return PlaybackStateV2{}, false, err
	}
	var next PlaybackStateV2
	if current == nil {
		next = emptyPlaybackStateV2(nowMS)
	} else {
		next = *current
		normalizePlaybackStateV2(&next)
	}

	if err := applyPlaybackCommandMutationV2(&next, req, nowMS); err != nil {
		return PlaybackStateV2{}, false, err
	}
	next.Revision++
	next.Schema = playbackSchemaV2
	next.ServerTimeMS = nowMS
	normalizePlaybackStateV2(&next)

	raw, err := json.Marshal(next)
	if err != nil {
		return PlaybackStateV2{}, false, err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO playback_state(key, revision, state_json, updated_at)
		VALUES('global', ?, ?, ?)
		ON CONFLICT(key) DO UPDATE SET
			revision = excluded.revision,
			state_json = excluded.state_json,
			updated_at = excluded.updated_at
	`, next.Revision, string(raw), nowMS); err != nil {
		return PlaybackStateV2{}, false, err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO playback_commands(command_id, response_json, created_at)
		VALUES(?, ?, ?)
	`, req.CommandID, string(raw), nowMS); err != nil {
		return PlaybackStateV2{}, false, err
	}
	if err := tx.Commit(); err != nil {
		return PlaybackStateV2{}, false, err
	}
	return next, false, nil
}

func playbackCommandResponseV2(ctx context.Context, tx *sql.Tx, commandID string, nowMS int64) (PlaybackStateV2, bool, error) {
	var raw string
	if err := tx.QueryRowContext(ctx, `SELECT response_json FROM playback_commands WHERE command_id = ?`, commandID).Scan(&raw); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return PlaybackStateV2{}, false, nil
		}
		return PlaybackStateV2{}, false, err
	}
	state, err := decodePlaybackStateV2(raw)
	if err != nil {
		return PlaybackStateV2{}, false, err
	}
	state.ServerTimeMS = nowMS
	return state, true, nil
}

func emptyPlaybackStateV2(nowMS int64) PlaybackStateV2 {
	return PlaybackStateV2{
		Schema: playbackSchemaV2,
		State:  "stopped",
		Context: PlaybackContextV2{
			PlaybackSource: []TrackReference{},
			QueuedTracks:   []TrackReference{},
			PlayHistory:    []TrackReference{},
			Repeat:         "off",
		},
		Clock: PlaybackClockV2{
			PositionSeconds: 0,
			UpdatedAtMS:     nowMS,
		},
		Volume:       1,
		ServerTimeMS: nowMS,
	}
}

func applyPlaybackCommandMutationV2(state *PlaybackStateV2, req PlaybackCommandV2, nowMS int64) error {
	targetDeviceID := commandTargetDeviceID(req)
	currentPosition := playbackStatePositionAtV2(*state, nowMS)

	if req.Context != nil {
		state.Context = cleanPlaybackContextV2(*req.Context)
	}
	if req.Volume != nil {
		state.Volume = cleanPlaybackVolume(*req.Volume)
	}

	switch req.Kind {
	case "load":
		if req.Track == nil {
			return errors.New("load command needs a track")
		}
		track := cleanTrackReference(*req.Track)
		state.Track = &track
		state.ActiveDeviceID = &targetDeviceID
		state.State = "paused"
		setPlaybackClockV2(state, commandPositionOr(req, 0), nowMS)
	case "play":
		if req.Track != nil {
			track := cleanTrackReference(*req.Track)
			state.Track = &track
			currentPosition = commandPositionOr(req, 0)
		} else {
			currentPosition = commandPositionOr(req, currentPosition)
		}
		if state.Track == nil {
			return errors.New("play command needs a track")
		}
		state.ActiveDeviceID = &targetDeviceID
		state.State = "playing"
		setPlaybackClockV2(state, currentPosition, nowMS)
	case "pause":
		state.ActiveDeviceID = &targetDeviceID
		state.State = "paused"
		setPlaybackClockV2(state, commandPositionOr(req, currentPosition), nowMS)
	case "seek":
		state.ActiveDeviceID = &targetDeviceID
		setPlaybackClockV2(state, commandPositionOr(req, 0), nowMS)
	case "next":
		state.ActiveDeviceID = &targetDeviceID
		advancePlaybackNextV2(state, nowMS)
	case "previous":
		state.ActiveDeviceID = &targetDeviceID
		advancePlaybackPreviousV2(state, commandPositionOr(req, currentPosition), nowMS)
	case "set_queue":
		if req.Context == nil {
			return errors.New("set_queue command needs context")
		}
		setPlaybackClockV2(state, currentPosition, nowMS)
	case "set_shuffle":
		if req.Shuffle != nil {
			state.Context.Shuffle = *req.Shuffle
		}
		setPlaybackClockV2(state, currentPosition, nowMS)
	case "set_repeat":
		if req.Repeat != nil {
			state.Context.Repeat = cleanRepeatMode(*req.Repeat)
		}
		setPlaybackClockV2(state, currentPosition, nowMS)
	case "transfer":
		state.ActiveDeviceID = &targetDeviceID
		setPlaybackClockV2(state, commandPositionOr(req, currentPosition), nowMS)
	case "volume":
		setPlaybackClockV2(state, currentPosition, nowMS)
	default:
		return fmt.Errorf("unsupported playback command %q", req.Kind)
	}

	if state.State == "" {
		state.State = "stopped"
	}
	state.Context.PlaybackIndex = clampPlaybackIndex(state.Context.PlaybackIndex, len(state.Context.PlaybackSource))
	return nil
}

func commandTargetDeviceID(req PlaybackCommandV2) string {
	if req.TargetDeviceID != nil && strings.TrimSpace(*req.TargetDeviceID) != "" {
		return strings.TrimSpace(*req.TargetDeviceID)
	}
	return strings.TrimSpace(req.DeviceID)
}

func commandPositionOr(req PlaybackCommandV2, fallback float64) float64 {
	if req.PositionSeconds == nil {
		return cleanPlaybackPosition(fallback)
	}
	return cleanPlaybackPosition(*req.PositionSeconds)
}

func playbackStatePositionAtV2(state PlaybackStateV2, nowMS int64) float64 {
	position := cleanPlaybackPosition(state.Clock.PositionSeconds)
	if state.State != "playing" || state.Clock.StartedAtMS == nil {
		return position
	}
	elapsed := float64(nowMS-*state.Clock.StartedAtMS) / 1000
	if elapsed < 0 {
		return position
	}
	return cleanPlaybackPosition(position + elapsed)
}

func setPlaybackClockV2(state *PlaybackStateV2, position float64, nowMS int64) {
	position = cleanPlaybackPosition(position)
	state.Clock.PositionSeconds = position
	state.Clock.UpdatedAtMS = nowMS
	if state.State == "playing" {
		state.Clock.StartedAtMS = &nowMS
		state.Clock.StoppedAtMS = nil
		return
	}
	state.Clock.StartedAtMS = nil
	state.Clock.StoppedAtMS = &nowMS
}

func advancePlaybackNextV2(state *PlaybackStateV2, nowMS int64) {
	wasPlaying := state.State == "playing"
	if state.Track != nil {
		state.Context.PlayHistory = append(state.Context.PlayHistory, *state.Track)
	}

	if len(state.Context.QueuedTracks) > 0 {
		next := state.Context.QueuedTracks[0]
		state.Context.QueuedTracks = state.Context.QueuedTracks[1:]
		state.Track = &next
		if index := indexTrackReference(state.Context.PlaybackSource, next); index >= 0 {
			state.Context.PlaybackIndex = index
		}
		state.State = stateForTrackChange(wasPlaying)
		setPlaybackClockV2(state, 0, nowMS)
		return
	}

	if len(state.Context.PlaybackSource) == 0 {
		state.State = "stopped"
		setPlaybackClockV2(state, 0, nowMS)
		return
	}

	nextIndex := state.Context.PlaybackIndex
	if state.Track != nil {
		nextIndex++
	}
	if nextIndex >= len(state.Context.PlaybackSource) {
		if state.Context.Repeat == "all" {
			nextIndex = 0
		} else {
			state.State = "stopped"
			setPlaybackClockV2(state, 0, nowMS)
			return
		}
	}

	next := state.Context.PlaybackSource[nextIndex]
	state.Context.PlaybackIndex = nextIndex
	state.Track = &next
	state.State = stateForTrackChange(wasPlaying)
	setPlaybackClockV2(state, 0, nowMS)
}

func advancePlaybackPreviousV2(state *PlaybackStateV2, position float64, nowMS int64) {
	wasPlaying := state.State == "playing"
	if position > 4 || len(state.Context.PlayHistory) == 0 {
		setPlaybackClockV2(state, 0, nowMS)
		return
	}

	previous := state.Context.PlayHistory[len(state.Context.PlayHistory)-1]
	state.Context.PlayHistory = state.Context.PlayHistory[:len(state.Context.PlayHistory)-1]
	if state.Track != nil {
		state.Context.QueuedTracks = append([]TrackReference{*state.Track}, state.Context.QueuedTracks...)
	}
	state.Track = &previous
	if index := indexTrackReference(state.Context.PlaybackSource, previous); index >= 0 {
		state.Context.PlaybackIndex = index
	}
	state.State = stateForTrackChange(wasPlaying)
	setPlaybackClockV2(state, 0, nowMS)
}

func stateForTrackChange(wasPlaying bool) string {
	if wasPlaying {
		return "playing"
	}
	return "paused"
}

func normalizePlaybackStateV2(state *PlaybackStateV2) {
	if state.Schema == "" {
		state.Schema = playbackSchemaV2
	}
	if state.State != "playing" && state.State != "paused" && state.State != "stopped" {
		state.State = "stopped"
	}
	state.Context = cleanPlaybackContextV2(state.Context)
	state.Context.PlaybackIndex = clampPlaybackIndex(state.Context.PlaybackIndex, len(state.Context.PlaybackSource))
	state.Clock.PositionSeconds = cleanPlaybackPosition(state.Clock.PositionSeconds)
	state.Volume = cleanPlaybackVolume(state.Volume)
}

func cleanPlaybackContextV2(context PlaybackContextV2) PlaybackContextV2 {
	context.PlaybackSource = cleanTrackReferences(context.PlaybackSource)
	context.QueuedTracks = cleanTrackReferences(context.QueuedTracks)
	context.PlayHistory = cleanTrackReferences(context.PlayHistory)
	context.Repeat = cleanRepeatMode(context.Repeat)
	context.PlaybackIndex = clampPlaybackIndex(context.PlaybackIndex, len(context.PlaybackSource))
	return context
}

func cleanTrackReferences(references []TrackReference) []TrackReference {
	if len(references) == 0 {
		return []TrackReference{}
	}
	cleaned := make([]TrackReference, 0, len(references))
	for _, reference := range references {
		cleaned = append(cleaned, cleanTrackReference(reference))
	}
	return cleaned
}

func cleanTrackReference(reference TrackReference) TrackReference {
	return TrackReference{
		ID:          strings.TrimSpace(reference.ID),
		Path:        strings.TrimSpace(reference.Path),
		Fingerprint: strings.TrimSpace(reference.Fingerprint),
	}
}

func indexTrackReference(references []TrackReference, target TrackReference) int {
	for index, reference := range references {
		if reference.ID != "" && reference.ID == target.ID {
			return index
		}
		if reference.Fingerprint != "" && reference.Fingerprint == target.Fingerprint {
			return index
		}
		if reference.Path != "" && reference.Path == target.Path {
			return index
		}
	}
	return -1
}

func clampPlaybackIndex(index int, length int) int {
	if length <= 0 {
		return 0
	}
	if index < 0 {
		return 0
	}
	if index >= length {
		return length - 1
	}
	return index
}

func cleanRepeatMode(value string) string {
	switch strings.TrimSpace(value) {
	case "all", "one":
		return strings.TrimSpace(value)
	default:
		return "off"
	}
}

func (s *Server) audioPath(fingerprint string) string {
	return filepath.Join(s.dataDir, "audio", safeFileName(fingerprint)+".mp3")
}

func (s *Server) artworkPath(fingerprint string) string {
	return filepath.Join(s.dataDir, "artwork", safeFileName(fingerprint)+".jpg")
}

func writeRequestBody(path string, body io.ReadCloser, maxBytes int64) (int64, error) {
	defer body.Close()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return 0, err
	}
	temp := path + ".tmp"
	file, err := os.Create(temp)
	if err != nil {
		return 0, err
	}
	written, copyErr := io.Copy(file, io.LimitReader(body, maxBytes+1))
	closeErr := file.Close()
	if copyErr != nil {
		_ = os.Remove(temp)
		return 0, copyErr
	}
	if closeErr != nil {
		_ = os.Remove(temp)
		return 0, closeErr
	}
	if written > maxBytes {
		_ = os.Remove(temp)
		return 0, fmt.Errorf("body is larger than %d bytes", maxBytes)
	}
	if err := os.Rename(temp, path); err != nil {
		_ = os.Remove(temp)
		return 0, err
	}
	return written, nil
}

func serveMedia(w http.ResponseWriter, r *http.Request, path, contentType string) {
	file, err := os.Open(path)
	if err != nil {
		writeError(w, http.StatusNotFound, err)
		return
	}
	defer file.Close()
	stat, err := file.Stat()
	if err != nil {
		writeError(w, http.StatusNotFound, err)
		return
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Accept-Ranges", "bytes")
	http.ServeContent(w, r, stat.Name(), stat.ModTime(), file)
}

func serveWebApp(webDir string, api http.Handler) http.Handler {
	indexPath := filepath.Join(webDir, "index.html")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" || strings.HasPrefix(r.URL.Path, "/api/") {
			api.ServeHTTP(w, r)
			return
		}

		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			writeError(w, http.StatusMethodNotAllowed, fmt.Errorf("method not allowed"))
			return
		}

		cleanPath := filepath.Clean("/" + r.URL.Path)
		filePath := filepath.Join(webDir, strings.TrimPrefix(cleanPath, "/"))
		rel, err := filepath.Rel(webDir, filePath)
		if err != nil || strings.HasPrefix(rel, "..") {
			writeError(w, http.StatusBadRequest, fmt.Errorf("invalid web path"))
			return
		}

		if stat, err := os.Stat(filePath); err == nil && !stat.IsDir() {
			http.ServeFile(w, r, filePath)
			return
		}

		if stat, err := os.Stat(indexPath); err == nil && !stat.IsDir() {
			http.ServeFile(w, r, indexPath)
			return
		}

		writeError(w, http.StatusNotFound, fmt.Errorf("web app is not built"))
	})
}

func decodeJSON(r *http.Request, target any) error {
	defer r.Body.Close()
	decoder := json.NewDecoder(io.LimitReader(r.Body, maxJSONBytes))
	decoder.DisallowUnknownFields()
	return decoder.Decode(target)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeSSE(w io.Writer, eventType string, value any) {
	raw, err := json.Marshal(value)
	if err != nil {
		return
	}
	_, _ = fmt.Fprintf(w, "event: %s\n", eventType)
	_, _ = fmt.Fprintf(w, "data: %s\n\n", raw)
}

func writeError(w http.ResponseWriter, status int, err error) {
	writeJSON(w, status, map[string]string{"error": err.Error()})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
	bytes  int
}

func (recorder *statusRecorder) WriteHeader(status int) {
	recorder.status = status
	recorder.ResponseWriter.WriteHeader(status)
}

func (recorder *statusRecorder) Write(body []byte) (int, error) {
	if recorder.status == 0 {
		recorder.status = http.StatusOK
	}
	written, err := recorder.ResponseWriter.Write(body)
	recorder.bytes += written
	return written, err
}

func (recorder *statusRecorder) Flush() {
	if recorder.status == 0 {
		recorder.status = http.StatusOK
	}
	if flusher, ok := recorder.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		recorder := &statusRecorder{ResponseWriter: w}
		next.ServeHTTP(recorder, r)
		status := recorder.status
		if status == 0 {
			status = http.StatusOK
		}
		fmt.Fprintf(
			os.Stdout,
			"%s %s %s -> %d %dB %s\n",
			start.Format("15:04:05"),
			r.Method,
			r.URL.Path,
			status,
			recorder.bytes,
			time.Since(start).Round(time.Millisecond),
		)
	})
}

func withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, HEAD, POST, PUT, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type, Last-Event-ID, Range")
		w.Header().Set("Access-Control-Expose-Headers", "Content-Length, Content-Range, Accept-Ranges")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func withAuth(next http.Handler, token string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" || authorizedRequest(r, token) {
			next.ServeHTTP(w, r)
			return
		}

		w.Header().Set("WWW-Authenticate", `Basic realm="Loud"`)
		writeError(w, http.StatusUnauthorized, fmt.Errorf("authorization required"))
	})
}

func authorizedRequest(r *http.Request, token string) bool {
	if token == "" {
		return true
	}

	if _, password, ok := r.BasicAuth(); ok && constantTimeString(password, token) {
		return true
	}

	const prefix = "Bearer "
	header := r.Header.Get("Authorization")
	if strings.HasPrefix(header, prefix) && constantTimeString(strings.TrimPrefix(header, prefix), token) {
		return true
	}

	return false
}

func constantTimeString(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

func publicBaseURL(r *http.Request) string {
	proto := r.Header.Get("X-Forwarded-Proto")
	if proto == "" {
		proto = "http"
		if r.TLS != nil {
			proto = "https"
		}
	}
	host := r.Header.Get("X-Forwarded-Host")
	if host == "" {
		host = r.Host
	}
	return proto + "://" + host
}

func cleanFingerprint(value string) string {
	return strings.TrimSpace(value)
}

func remoteTrackPath(track Track) string {
	return "loud://track/" + track.Fingerprint + "/" + safeFileName(track.FileName)
}

func safeFileName(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return "track"
	}
	replacer := strings.NewReplacer("/", "_", "\\", "_", ":", "_", "*", "_", "?", "_", "\"", "_", "<", "_", ">", "_", "|", "_")
	value = replacer.Replace(value)
	value = strings.Trim(value, ". ")
	if value == "" {
		return "track"
	}
	return value
}

func pathEscape(value string) string {
	return strings.ReplaceAll(value, "/", "%2F")
}

func boolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}

func maxInt64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

func dedupeStrings(values []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		out = append(out, value)
	}
	return out
}

func ensureLikedPlaylist(playlists []Playlist, tracks []Track) []Playlist {
	var likedTracks []string
	for _, track := range tracks {
		if track.IsLiked {
			likedTracks = append(likedTracks, track.ID)
		}
	}

	for index := range playlists {
		if playlists[index].IsLiked {
			playlists[index].Name = likedName
			playlists[index].TrackIDs = dedupeStrings(append(playlists[index].TrackIDs, likedTracks...))
			if playlists[index].TrackIDs == nil {
				playlists[index].TrackIDs = []string{}
			}
			return playlists
		}
	}

	return append([]Playlist{{
		ID:       likedID,
		Name:     likedName,
		Path:     "loud://playlist/" + likedID,
		TrackIDs: nonNilStrings(dedupeStrings(likedTracks)),
		IsLiked:  true,
	}}, playlists...)
}

func attachPlaylistIDs(tracks []Track, playlists []Playlist) {
	idsByTrack := map[string][]string{}
	for _, playlist := range playlists {
		for _, trackID := range playlist.TrackIDs {
			idsByTrack[trackID] = append(idsByTrack[trackID], playlist.ID)
		}
	}
	for index := range tracks {
		ids := idsByTrack[tracks[index].ID]
		if tracks[index].IsLiked {
			ids = append(ids, likedID)
		}
		tracks[index].PlaylistIDs = dedupeStrings(append(tracks[index].PlaylistIDs, ids...))
	}
}

func summarizeStats(tracks []Track, playlists []Playlist) LibraryStats {
	artists := map[string]bool{}
	albums := map[string]bool{}
	duration := 0.0
	liked := 0
	for _, track := range tracks {
		artists[strings.ToLower(track.Artist)] = true
		albumArtist := track.Artist
		if track.AlbumArtist != nil && *track.AlbumArtist != "" {
			albumArtist = *track.AlbumArtist
		}
		albums[strings.ToLower(albumArtist+"|"+track.Album)] = true
		if track.DurationSeconds != nil {
			duration += *track.DurationSeconds
		}
		if track.IsLiked {
			liked++
		}
	}
	playlistCount := 0
	for _, playlist := range playlists {
		if !playlist.IsLiked {
			playlistCount++
		}
	}
	return LibraryStats{
		TrackCount:      len(tracks),
		PlaylistCount:   playlistCount,
		LikedCount:      liked,
		ArtistCount:     len(artists),
		AlbumCount:      len(albums),
		DurationSeconds: duration,
	}
}

func summarizeArtists(tracks []Track) []ArtistSummary {
	type bucket struct {
		tracks []Track
		albums map[string]bool
	}
	buckets := map[string]*bucket{}
	for _, track := range tracks {
		key := strings.ToLower(track.Artist)
		if buckets[key] == nil {
			buckets[key] = &bucket{albums: map[string]bool{}}
		}
		buckets[key].tracks = append(buckets[key].tracks, track)
		buckets[key].albums[strings.ToLower(track.Album)] = true
	}
	summaries := make([]ArtistSummary, 0, len(buckets))
	for _, bucket := range buckets {
		duration := 0.0
		for _, track := range bucket.tracks {
			if track.DurationSeconds != nil {
				duration += *track.DurationSeconds
			}
		}
		summaries = append(summaries, ArtistSummary{
			Name:            bucket.tracks[0].Artist,
			TrackCount:      len(bucket.tracks),
			AlbumCount:      len(bucket.albums),
			DurationSeconds: duration,
		})
	}
	sort.Slice(summaries, func(i, j int) bool {
		if summaries[i].TrackCount != summaries[j].TrackCount {
			return summaries[i].TrackCount > summaries[j].TrackCount
		}
		return strings.ToLower(summaries[i].Name) < strings.ToLower(summaries[j].Name)
	})
	return nonNilArtists(summaries)
}

func summarizeAlbums(tracks []Track) []AlbumSummary {
	type bucket struct {
		tracks []Track
	}
	buckets := map[string]*bucket{}
	for _, track := range tracks {
		albumArtist := track.Artist
		if track.AlbumArtist != nil && *track.AlbumArtist != "" {
			albumArtist = *track.AlbumArtist
		}
		key := strings.ToLower(albumArtist + "|" + track.Album)
		if buckets[key] == nil {
			buckets[key] = &bucket{}
		}
		buckets[key].tracks = append(buckets[key].tracks, track)
	}
	summaries := make([]AlbumSummary, 0, len(buckets))
	for _, bucket := range buckets {
		duration := 0.0
		var artwork *string
		for _, track := range bucket.tracks {
			if track.DurationSeconds != nil {
				duration += *track.DurationSeconds
			}
			if artwork == nil && track.ArtworkURL != nil {
				artwork = track.ArtworkURL
			}
		}
		first := bucket.tracks[0]
		artist := first.Artist
		if first.AlbumArtist != nil && *first.AlbumArtist != "" {
			artist = *first.AlbumArtist
		}
		summaries = append(summaries, AlbumSummary{
			Name:            first.Album,
			Artist:          artist,
			TrackCount:      len(bucket.tracks),
			DurationSeconds: duration,
			ArtworkURL:      artwork,
		})
	}
	sort.Slice(summaries, func(i, j int) bool {
		return strings.ToLower(summaries[i].Name) < strings.ToLower(summaries[j].Name)
	})
	return nonNilAlbums(summaries)
}

func nonNilTracks(values []Track) []Track {
	if values == nil {
		return []Track{}
	}
	for index := range values {
		values[index].PlaylistIDs = nonNilStrings(values[index].PlaylistIDs)
	}
	return values
}

func nonNilPlaylists(values []Playlist) []Playlist {
	if values == nil {
		return []Playlist{}
	}
	for index := range values {
		values[index].TrackIDs = nonNilStrings(values[index].TrackIDs)
	}
	return values
}

func nonNilArtists(values []ArtistSummary) []ArtistSummary {
	if values == nil {
		return []ArtistSummary{}
	}
	return values
}

func nonNilAlbums(values []AlbumSummary) []AlbumSummary {
	if values == nil {
		return []AlbumSummary{}
	}
	return values
}

func nonNilPlaybackDevices(values []PlaybackDevice) []PlaybackDevice {
	if values == nil {
		return []PlaybackDevice{}
	}
	return values
}

func nonNilStrings(values []string) []string {
	if values == nil {
		return []string{}
	}
	return values
}

type rowScanner interface {
	Scan(dest ...any) error
}

func scanPlaybackDevice(row rowScanner) (PlaybackDevice, error) {
	var device PlaybackDevice
	var trackID sql.NullString
	var trackFingerprint sql.NullString
	var trackTitle sql.NullString
	var isPlaying int
	err := row.Scan(
		&device.DeviceID,
		&device.Name,
		&trackID,
		&trackFingerprint,
		&trackTitle,
		&isPlaying,
		&device.PositionSeconds,
		&device.Volume,
		&device.UpdatedAt,
	)
	if err != nil {
		return PlaybackDevice{}, err
	}
	device.TrackID = stringFromNull(trackID)
	device.TrackFingerprint = stringFromNull(trackFingerprint)
	device.TrackTitle = stringFromNull(trackTitle)
	device.IsPlaying = isPlaying == 1
	return device, nil
}

func stringFromNull(value sql.NullString) *string {
	if !value.Valid || strings.TrimSpace(value.String) == "" {
		return nil
	}
	cleaned := strings.TrimSpace(value.String)
	return &cleaned
}

func cleanStringPointer(value *string) *string {
	if value == nil {
		return nil
	}
	cleaned := strings.TrimSpace(*value)
	if cleaned == "" {
		return nil
	}
	return &cleaned
}

func nullableString(value *string) any {
	value = cleanStringPointer(value)
	if value == nil {
		return nil
	}
	return *value
}

func cleanPlaybackPosition(value float64) float64 {
	if value < 0 {
		return 0
	}
	if value > 24*60*60 {
		return 24 * 60 * 60
	}
	return value
}

func cleanPlaybackVolume(value float64) float64 {
	if value < 0 {
		return 0
	}
	if value > 1 {
		return 1
	}
	return value
}
