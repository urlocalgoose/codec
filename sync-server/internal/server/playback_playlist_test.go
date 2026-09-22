package server

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestPlaybackPlaylistNormalizationIsBackwardCompatible(t *testing.T) {
	for _, raw := range []string{`{}`, `{"playlist_id":null}`, `{"playlist_id":" \t "}`} {
		var playbackContext PlaybackContextV2
		if err := json.Unmarshal([]byte(raw), &playbackContext); err != nil {
			t.Fatal(err)
		}
		playbackContext = cleanPlaybackContextV2(playbackContext)
		encoded, err := json.Marshal(playbackContext)
		if err != nil {
			t.Fatal(err)
		}
		if playbackContext.PlaylistID != nil || strings.Contains(string(encoded), "playlist_id") {
			t.Fatalf("unknown playlist must stay absent: %s", encoded)
		}
	}
	// IDs are explicit provenance, even if a library has not arrived or its
	// playlist has since been removed. No membership or name matching occurs.
	input := "  playlist/destination-id  "
	cleaned := cleanPlaybackContextV2(PlaybackContextV2{PlaylistID: &input})
	if cleaned.PlaylistID == nil || *cleaned.PlaylistID != "playlist/destination-id" || input != "  playlist/destination-id  " {
		t.Fatalf("playlist normalization changed caller state or lost ID: %+v", cleaned)
	}
}

func TestPlaybackPlaylistReplacementClearsUnknownOrigin(t *testing.T) {
	for _, kind := range []string{"load", "play", "set_queue", "set_shuffle"} {
		t.Run(kind, func(t *testing.T) {
			track := testTrackReference("shared-track")
			state := emptyPlaybackStateV2(1000)
			state.Track = &track
			state.Context = PlaybackContextV2{PlaylistID: strPtr("old-playlist"), PlaybackSource: []TrackReference{track}}
			// A search/album/library source, including an older client using
			// exactly the same tracks, must not retain the previous playlist.
			replacement := PlaybackContextV2{PlaybackSource: []TrackReference{track}}
			if err := applyPlaybackCommandMutationV2(&state, PlaybackCommandV2{
				Kind: kind, DeviceID: "web", Track: &track, Context: &replacement,
			}, 2000); err != nil {
				t.Fatal(err)
			}
			if state.Context.PlaylistID != nil {
				t.Fatalf("%s retained stale playlist %q", kind, *state.Context.PlaylistID)
			}
		})
	}
}

func TestPlaybackPlaylistTransportIgnoresStaleContext(t *testing.T) {
	for _, kind := range []string{"pause", "seek", "next", "previous", "transfer", "volume", "set_repeat"} {
		t.Run(kind, func(t *testing.T) {
			track := testTrackReference("first")
			state := emptyPlaybackStateV2(1000)
			state.Track = &track
			state.Context = PlaybackContextV2{PlaylistID: strPtr("current-playlist"), PlaybackSource: []TrackReference{track}}
			stale := PlaybackContextV2{PlaylistID: strPtr("old-playlist")}
			if err := applyPlaybackCommandMutationV2(&state, PlaybackCommandV2{
				Kind: kind, DeviceID: "phone", Context: &stale,
			}, 2000); err != nil {
				t.Fatal(err)
			}
			if state.Context.PlaylistID == nil || *state.Context.PlaylistID != "current-playlist" {
				t.Fatalf("%s replaced origin with stale context: %+v", kind, state.Context)
			}
		})
	}
}

func TestPlaybackPlaylistSurvivesCommandsAndRestart(t *testing.T) {
	dir := t.TempDir()
	server, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	server.now = func() time.Time { return time.Unix(100, 0) }
	httpServer := httptest.NewServer(server.Handler())
	closed := false
	t.Cleanup(func() {
		if !closed {
			httpServer.Close()
			_ = server.Close()
		}
	})
	first, second, queued := testTrackReference("first"), testTrackReference("second"), testTrackReference("queued")
	playbackContext := PlaybackContextV2{
		PlaylistID: strPtr(" playlist-destination "), PlaybackSource: []TrackReference{first, second},
		QueuedTracks: []TrackReference{queued},
	}
	play := PlaybackCommandV2{CommandID: "origin-play", Kind: "play", DeviceID: "phone", Track: &first, Context: &playbackContext}
	state := postPlaybackCommandV2(t, httpServer.URL, play)
	assertOrigin := func(state PlaybackStateV2) {
		t.Helper()
		if state.Context.PlaylistID == nil || *state.Context.PlaylistID != "playlist-destination" {
			t.Fatalf("lost origin: %+v", state)
		}
	}
	assertOrigin(state)
	shuffle := true
	for _, command := range []PlaybackCommandV2{
		{Kind: "next"}, {Kind: "previous", PositionSeconds: floatPtr(0)},
		{Kind: "set_shuffle", Shuffle: &shuffle}, {Kind: "set_repeat", Repeat: strPtr("all")},
		{Kind: "seek", PositionSeconds: floatPtr(17)}, {Kind: "pause"}, {Kind: "play"},
		{Kind: "transfer", TargetDeviceID: strPtr("web")},
	} {
		command.CommandID, command.DeviceID = "origin-"+command.Kind, "phone"
		// The initial play and later resume must have different retry IDs.
		if command.Kind == "play" {
			command.CommandID = "origin-resume"
		}
		state = postPlaybackCommandV2(t, httpServer.URL, command)
		assertOrigin(state)
	}
	state = postPlaybackCommandV2(t, httpServer.URL, PlaybackCommandV2{
		CommandID: "origin-queue", Kind: "set_queue", DeviceID: "web", Context: &state.Context,
	})
	assertOrigin(state)
	if state.Track == nil || state.Track.ID != first.ID || state.Clock.PositionSeconds != 17 || state.ActiveDeviceID == nil || *state.ActiveDeviceID != "web" {
		t.Fatalf("provenance changed playback semantics: %+v", state)
	}
	if err := server.upsertPlaybackSession(context.Background(), PlaybackSession{
		DeviceID: "web", Session: map[string]any{"schema": "loud.playback.v1", "playlist_id": "playlist-destination"},
	}); err != nil {
		t.Fatal(err)
	}
	httpServer.Close()
	if err := server.Close(); err != nil {
		t.Fatal(err)
	}
	closed = true
	reopened, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	restored, err := reopened.playbackStateV2(context.Background())
	if err != nil || restored == nil {
		t.Fatalf("reload: %v %v", restored, err)
	}
	assertOrigin(*restored)
	before, _ := json.Marshal(state)
	after, _ := json.Marshal(restored)
	if string(before) != string(after) {
		t.Fatalf("restart changed playback state: before=%s after=%s", before, after)
	}
	legacySession, err := reopened.playbackSession(context.Background(), "web", false)
	if err != nil || legacySession.Session["playlist_id"] != "playlist-destination" {
		t.Fatalf("v1 session extension was lost: %+v %v", legacySession, err)
	}
	retry, duplicate, err := reopened.applyPlaybackCommandV2(context.Background(), play)
	if err != nil || !duplicate {
		t.Fatalf("retry after restart: duplicate=%v error=%v", duplicate, err)
	}
	assertOrigin(retry)
	current, err := reopened.playbackStateV2(context.Background())
	if err != nil || current.Revision != state.Revision {
		t.Fatalf("retry rewrote current playback: %+v %v", current, err)
	}
}

func TestPlaybackPlaylistSSESnapshotAndHandoff(t *testing.T) {
	_, httpServer := testServer(t)
	track := testTrackReference("first")
	playbackContext := PlaybackContextV2{PlaylistID: strPtr("playlist-destination"), PlaybackSource: []TrackReference{track}}
	postPlaybackCommandV2(t, httpServer.URL, PlaybackCommandV2{
		CommandID: "sse-play", Kind: "play", DeviceID: "phone", Track: &track, Context: &playbackContext,
	})
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, httpServer.URL+"/api/v2/playback/events", nil)
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("events status=%s", response.Status)
	}
	scanner := bufio.NewScanner(response.Body)
	nextState := func() PlaybackStateV2 {
		t.Helper()
		for scanner.Scan() {
			line := scanner.Text()
			if !strings.HasPrefix(line, "data: ") {
				continue
			}
			var event PlaybackEvent
			if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &event); err != nil {
				t.Fatal(err)
			}
			if event.PlaybackState != nil {
				if event.PlaybackState.Context.PlaylistID == nil || *event.PlaybackState.Context.PlaylistID != "playlist-destination" {
					t.Fatalf("SSE lost playlist provenance: %+v", event.PlaybackState)
				}
				return *event.PlaybackState
			}
		}
		t.Fatalf("missing playback event: %v", scanner.Err())
		return PlaybackStateV2{}
	}
	initial := nextState()
	postPlaybackCommandV2(t, httpServer.URL, PlaybackCommandV2{
		CommandID: "sse-transfer", Kind: "transfer", DeviceID: "web", TargetDeviceID: strPtr("web"),
	})
	handoff := nextState()
	if handoff.Revision != initial.Revision+1 || handoff.ActiveDeviceID == nil || *handoff.ActiveDeviceID != "web" {
		t.Fatalf("missing handoff update: %+v", handoff)
	}
}
