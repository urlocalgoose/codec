// The loud.playback.v2 shared playback state machine.
package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

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
