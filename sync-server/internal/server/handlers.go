// HTTP handlers for the /health and /api endpoints.
package server

import (
	"database/sql"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"mime"
	"net/http"
	"strings"
	"time"
)

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	response := map[string]any{
		"ok":              true,
		"schema":          syncSchema,
		"playback_schema": playbackSchemaV2,
	}
	if id, err := s.serverID(r.Context()); err == nil {
		response["server_id"] = id
	}
	writeJSON(w, http.StatusOK, response)
}

func (s *Server) handleLibrary(w http.ResponseWriter, r *http.Request) {
	if s.writeLibraryPreamble(w, r) {
		return
	}
	snapshot, err := s.snapshot(r.Context(), publicBaseURL(r))
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, snapshot.Library)
}

func (s *Server) handleSnapshot(w http.ResponseWriter, r *http.Request) {
	if s.writeLibraryPreamble(w, r) {
		return
	}
	snapshot, err := s.snapshot(r.Context(), publicBaseURL(r))
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, snapshot)
}

// writeLibraryPreamble sets the validator headers and answers 304 when the
// client already holds the current library version. Most refreshes change
// nothing, so most refreshes become free.
func (s *Server) writeLibraryPreamble(w http.ResponseWriter, r *http.Request) bool {
	etag := fmt.Sprintf(`"v%d-%x"`, s.libraryVersion.Load(), crc32.ChecksumIEEE([]byte(publicBaseURL(r))))
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "no-cache")
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return true
	}
	return false
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

func (s *Server) handleSetTrackLiked(w http.ResponseWriter, r *http.Request) {
	fingerprint := cleanFingerprint(r.PathValue("fingerprint"))
	var req struct {
		Liked bool `json:"liked"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}

	if err := s.setTrackLiked(r.Context(), fingerprint, req.Liked); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			writeError(w, http.StatusNotFound, errors.New("unknown track"))
			return
		}
		writeError(w, http.StatusBadRequest, err)
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"fingerprint": fingerprint,
		"liked":       req.Liked,
	})
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

func (s *Server) handleCreatePlaylist(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name string `json:"name"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	playlist, err := s.createPlaylist(r.Context(), req.Name)
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	writeJSON(w, http.StatusCreated, playlist)
}

func (s *Server) handleDeletePlaylist(w http.ResponseWriter, r *http.Request) {
	if err := s.deletePlaylist(r.Context(), r.PathValue("id")); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			writeError(w, http.StatusNotFound, errors.New("unknown playlist"))
			return
		}
		writeError(w, http.StatusBadRequest, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAddPlaylistTrack(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Fingerprint string `json:"fingerprint"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	fingerprint := cleanFingerprint(req.Fingerprint)
	if fingerprint == "" {
		writeError(w, http.StatusBadRequest, errors.New("missing fingerprint"))
		return
	}
	playlist, err := s.modifyPlaylistTracks(r.Context(), r.PathValue("id"), func(trackIDs []string) []string {
		return append(trackIDs, "track_"+fingerprint)
	})
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			writeError(w, http.StatusNotFound, errors.New("unknown playlist"))
			return
		}
		writeError(w, http.StatusBadRequest, err)
		return
	}
	writeJSON(w, http.StatusOK, playlist)
}

// handleSetPlaylistTracks replaces the playlist's ordered track list - the
// reorder operation. Membership edits should use the add/remove endpoints.
func (s *Server) handleSetPlaylistTracks(w http.ResponseWriter, r *http.Request) {
	var req struct {
		TrackIDs []string `json:"track_ids"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	if req.TrackIDs == nil {
		writeError(w, http.StatusBadRequest, errors.New("track_ids is required"))
		return
	}
	playlist, err := s.modifyPlaylistTracks(r.Context(), r.PathValue("id"), func([]string) []string {
		return req.TrackIDs
	})
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			writeError(w, http.StatusNotFound, errors.New("unknown playlist"))
			return
		}
		writeError(w, http.StatusBadRequest, err)
		return
	}
	writeJSON(w, http.StatusOK, playlist)
}

func (s *Server) handleRemovePlaylistTrack(w http.ResponseWriter, r *http.Request) {
	fingerprint := cleanFingerprint(r.PathValue("fingerprint"))
	trackID := "track_" + fingerprint
	playlist, err := s.modifyPlaylistTracks(r.Context(), r.PathValue("id"), func(trackIDs []string) []string {
		kept := trackIDs[:0]
		for _, id := range trackIDs {
			if id != trackID {
				kept = append(kept, id)
			}
		}
		return kept
	})
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			writeError(w, http.StatusNotFound, errors.New("unknown playlist"))
			return
		}
		writeError(w, http.StatusBadRequest, err)
		return
	}
	writeJSON(w, http.StatusOK, playlist)
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
	if err := s.setAudioType(r.Context(), fingerprint, normalizeAudioType(r.Header.Get("Content-Type"))); err != nil {
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
	serveMedia(w, r, path, s.audioType(r.Context(), fingerprint))
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
