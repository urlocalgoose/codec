// SQLite + disk persistence for tracks, playlists, and media blobs.
package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

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
	defer s.libraryVersion.Add(1)
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
	defer s.libraryVersion.Add(1)
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

// setTrackLiked flips only the is_liked column, which is authoritative over
// the metadata JSON when the library is read back.
func (s *Server) setTrackLiked(ctx context.Context, fingerprint string, liked bool) error {
	defer s.libraryVersion.Add(1)
	result, err := s.db.ExecContext(
		ctx,
		`UPDATE tracks SET is_liked = ?, updated_at = ? WHERE fingerprint = ?`,
		boolInt(liked), s.now().Unix(), fingerprint,
	)
	if err != nil {
		return err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if affected == 0 {
		return sql.ErrNoRows
	}
	return nil
}

func (s *Server) attachMediaPath(ctx context.Context, fingerprint, column, path string, size int64) error {
	defer s.libraryVersion.Add(1)
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

func (s *Server) audioPath(fingerprint string) string {
	return filepath.Join(s.dataDir, "audio", safeFileName(fingerprint)+".mp3")
}

func (s *Server) artworkPath(fingerprint string) string {
	return filepath.Join(s.dataDir, "artwork", safeFileName(fingerprint)+".jpg")
}
