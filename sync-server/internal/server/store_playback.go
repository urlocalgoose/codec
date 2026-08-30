// SQLite persistence for playback sessions, devices, and active playback.
package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

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
		device.Name = "Codec Device"
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
	// Only devices that have phoned home recently: presence publishes every
	// 30s, so anything older than this window is offline (or long gone).
	// Clients stamp updated_at in milliseconds.
	cutoff := s.now().Add(-2 * time.Minute).UnixMilli()
	rows, err := s.db.QueryContext(ctx, `
		SELECT device_id, name, track_id, track_fingerprint, track_title, is_playing, position_seconds, volume, updated_at
		FROM playback_devices
		WHERE updated_at >= ?
		ORDER BY updated_at DESC, name
	`, cutoff)
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
