package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testServer(t *testing.T) (*Server, *httptest.Server) {
	t.Helper()
	srv, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	srv.now = func() time.Time { return time.Unix(100, 0) }
	httpServer := httptest.NewServer(srv.Handler())
	t.Cleanup(func() {
		httpServer.Close()
		if err := srv.Close(); err != nil {
			t.Fatal(err)
		}
	})
	return srv, httpServer
}

func TestEmptyLibrarySerializesArrays(t *testing.T) {
	_, httpServer := testServer(t)
	res, err := http.Get(httpServer.URL + "/api/v1/library")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatal(err)
	}
	body := string(raw)
	for _, expected := range []string{
		`"artists":[]`,
		`"albums":[]`,
		`"tracks":[]`,
		`"track_ids":[]`,
	} {
		if !strings.Contains(body, expected) {
			t.Fatalf("expected %s in %s", expected, body)
		}
	}
}

func TestWebAppFallbackServesIndex(t *testing.T) {
	srv, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	webDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(webDir, "index.html"), []byte("<main>Loud app</main>"), 0o644); err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(srv.HandlerWithOptions(HandlerOptions{WebDir: webDir}))
	t.Cleanup(func() {
		httpServer.Close()
		if err := srv.Close(); err != nil {
			t.Fatal(err)
		}
	})

	res, err := http.Get(httpServer.URL + "/playlist/mix")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	body, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatal(err)
	}
	if res.StatusCode != http.StatusOK || !strings.Contains(string(body), "Loud app") {
		t.Fatalf("web app response = %s %q", res.Status, string(body))
	}
}

func TestAuthTokenProtectsAppAndAPI(t *testing.T) {
	srv, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	webDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(webDir, "index.html"), []byte("<main>Loud app</main>"), 0o644); err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(srv.HandlerWithOptions(HandlerOptions{
		WebDir:    webDir,
		AuthToken: "secret",
	}))
	t.Cleanup(func() {
		httpServer.Close()
		if err := srv.Close(); err != nil {
			t.Fatal(err)
		}
	})

	res, err := http.Get(httpServer.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	if res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthorized app status = %s", res.Status)
	}
	_ = res.Body.Close()

	req, _ := http.NewRequest(http.MethodGet, httpServer.URL+"/api/v1/library", nil)
	req.SetBasicAuth("loud", "secret")
	res, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("authorized API status = %s", res.Status)
	}
}

func TestPushSnapshotAndReadLibrary(t *testing.T) {
	_, httpServer := testServer(t)
	duration := 95.0
	body := PushRequest{
		Schema:   syncSchema,
		DeviceID: "desktop",
		Library: Library{
			Tracks: []Track{{
				ID:              "track_isrc:test",
				Path:            "/music/song.mp3",
				FileName:        "song.mp3",
				Title:           "Song",
				Artist:          "Ada",
				Album:           "Compiler Songs",
				DurationSeconds: &duration,
				IsLiked:         true,
				Fingerprint:     "isrc:TEST",
			}},
			Playlists: []Playlist{{
				ID:       "playlist_mix",
				Name:     "Mix",
				TrackIDs: []string{"track_isrc:test"},
			}},
		},
	}
	raw, _ := json.Marshal(body)
	res, err := http.Post(httpServer.URL+"/api/v1/sync/push", "application/json", bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	if res.StatusCode != http.StatusOK {
		t.Fatalf("push status = %s", res.Status)
	}

	res, err = http.Get(httpServer.URL + "/api/v1/library")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var library Library
	if err := json.NewDecoder(res.Body).Decode(&library); err != nil {
		t.Fatal(err)
	}
	if library.Stats.TrackCount != 1 || library.Stats.LikedCount != 1 {
		t.Fatalf("bad stats: %+v", library.Stats)
	}
	if library.Tracks[0].Path == "/music/song.mp3" {
		t.Fatalf("remote library leaked local path: %s", library.Tracks[0].Path)
	}
	if !library.Playlists[0].IsLiked {
		t.Fatalf("liked playlist should be first and synthesized")
	}
}

func TestAudioUploadSupportsRangePlayback(t *testing.T) {
	_, httpServer := testServer(t)
	track := Track{
		ID:          "track_fp",
		FileName:    "song.mp3",
		Title:       "Song",
		Artist:      "Ada",
		Album:       "Compiler Songs",
		Fingerprint: "fp",
	}
	raw, _ := json.Marshal(track)
	req, _ := http.NewRequest(http.MethodPut, httpServer.URL+"/api/v1/tracks/fp", bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	if res, err := http.DefaultClient.Do(req); err != nil || res.StatusCode != http.StatusNoContent {
		t.Fatalf("metadata upload status = %v, err=%v", statusOf(res), err)
	}

	req, _ = http.NewRequest(http.MethodPut, httpServer.URL+"/api/v1/tracks/fp/audio", strings.NewReader("0123456789"))
	req.Header.Set("Content-Type", "audio/mpeg")
	if res, err := http.DefaultClient.Do(req); err != nil || res.StatusCode != http.StatusNoContent {
		t.Fatalf("audio upload status = %v, err=%v", statusOf(res), err)
	}

	req, _ = http.NewRequest(http.MethodGet, httpServer.URL+"/api/v1/tracks/fp/audio", nil)
	req.Header.Set("Range", "bytes=2-5")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	buf := new(bytes.Buffer)
	_, _ = buf.ReadFrom(res.Body)
	if res.StatusCode != http.StatusPartialContent {
		t.Fatalf("range status = %s", res.Status)
	}
	if got := buf.String(); got != "2345" {
		t.Fatalf("range body = %q", got)
	}
	if res.Header.Get("Content-Range") != "bytes 2-5/10" {
		t.Fatalf("content range = %q", res.Header.Get("Content-Range"))
	}
}

func TestPlaybackSessionLatest(t *testing.T) {
	_, httpServer := testServer(t)
	payload := PlaybackSession{
		DeviceID: "phone",
		SavedAt:  200,
		Session: map[string]any{
			"schema":       "loud.playback.v1",
			"current_time": 42,
		},
	}
	raw, _ := json.Marshal(payload)
	req, _ := http.NewRequest(http.MethodPut, httpServer.URL+"/api/v1/playback-session/phone", bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	if res, err := http.DefaultClient.Do(req); err != nil || res.StatusCode != http.StatusNoContent {
		t.Fatalf("session put status = %v, err=%v", statusOf(res), err)
	}

	res, err := http.Get(httpServer.URL + "/api/v1/playback-session/latest")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var latest PlaybackSession
	if err := json.NewDecoder(res.Body).Decode(&latest); err != nil {
		t.Fatal(err)
	}
	if latest.DeviceID != "phone" || latest.Session["schema"] != "loud.playback.v1" {
		t.Fatalf("bad latest session: %+v", latest)
	}
}

func TestActivePlaybackEmptyState(t *testing.T) {
	_, httpServer := testServer(t)

	res, err := http.Get(httpServer.URL + "/api/v1/playback/active")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("active playback empty status = %s", res.Status)
	}

	var active *ActivePlayback
	if err := json.NewDecoder(res.Body).Decode(&active); err != nil {
		t.Fatal(err)
	}
	if active != nil {
		t.Fatalf("expected nil active playback, got %+v", active)
	}
}

func TestPlaybackDevicesAndTransfer(t *testing.T) {
	_, httpServer := testServer(t)
	trackID := "track_a"
	fingerprint := "isrc:TEST"
	title := "A"
	device := PlaybackDevice{
		DeviceID:         "desktop",
		Name:             "Desktop",
		TrackID:          &trackID,
		TrackFingerprint: &fingerprint,
		TrackTitle:       &title,
		IsPlaying:        true,
		PositionSeconds:  12.5,
		Volume:           0.7,
	}
	raw, _ := json.Marshal(device)
	req, _ := http.NewRequest(http.MethodPut, httpServer.URL+"/api/v1/playback/devices/desktop", bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	if res, err := http.DefaultClient.Do(req); err != nil || res.StatusCode != http.StatusNoContent {
		t.Fatalf("device put status = %v, err=%v", statusOf(res), err)
	}

	res, err := http.Get(httpServer.URL + "/api/v1/playback/devices")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var devices []PlaybackDevice
	if err := json.NewDecoder(res.Body).Decode(&devices); err != nil {
		t.Fatal(err)
	}
	if len(devices) != 1 || devices[0].DeviceID != "desktop" || !devices[0].IsPlaying {
		t.Fatalf("bad devices: %+v", devices)
	}

	transfer := PlaybackTransferRequest{
		DeviceID:         "phone",
		TrackID:          &trackID,
		TrackFingerprint: &fingerprint,
		TrackTitle:       &title,
		IsPlaying:        true,
		PositionSeconds:  13,
		Volume:           0.8,
	}
	raw, _ = json.Marshal(transfer)
	req, _ = http.NewRequest(http.MethodPut, httpServer.URL+"/api/v1/playback/transfer", bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	res, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("transfer status = %s", res.Status)
	}
	var active ActivePlayback
	if err := json.NewDecoder(res.Body).Decode(&active); err != nil {
		t.Fatal(err)
	}
	if active.DeviceID != "phone" || active.TrackFingerprint == nil || *active.TrackFingerprint != fingerprint {
		t.Fatalf("bad transfer response: %+v", active)
	}

	res, err = http.Get(httpServer.URL + "/api/v1/playback/active")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if err := json.NewDecoder(res.Body).Decode(&active); err != nil {
		t.Fatal(err)
	}
	if active.DeviceID != "phone" || !active.IsPlaying || active.PositionSeconds != 13 {
		t.Fatalf("bad active playback: %+v", active)
	}

	phone := device
	phone.DeviceID = "phone"
	phone.PositionSeconds = 21
	raw, _ = json.Marshal(phone)
	req, _ = http.NewRequest(http.MethodPut, httpServer.URL+"/api/v1/playback/devices/phone", bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	if res, err := http.DefaultClient.Do(req); err != nil || res.StatusCode != http.StatusNoContent {
		t.Fatalf("phone heartbeat status = %v, err=%v", statusOf(res), err)
	}

	res, err = http.Get(httpServer.URL + "/api/v1/playback/active")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if err := json.NewDecoder(res.Body).Decode(&active); err != nil {
		t.Fatal(err)
	}
	if active.DeviceID != "phone" || active.PositionSeconds != 21 {
		t.Fatalf("active playback did not follow active device heartbeat: %+v", active)
	}
}

func TestPlaybackEventsSendsInitialSnapshot(t *testing.T) {
	_, httpServer := testServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, httpServer.URL+"/api/v1/playback/events", nil)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.Header.Get("Content-Type") != "text/event-stream; charset=utf-8" {
		t.Fatalf("content type = %q", res.Header.Get("Content-Type"))
	}

	buf := make([]byte, 512)
	n, err := res.Body.Read(buf)
	if err != nil && !errorsIsContextDone(err) {
		t.Fatal(err)
	}
	if !strings.Contains(string(buf[:n]), "event: devices") {
		t.Fatalf("expected initial devices event in %q", string(buf[:n]))
	}
}

func TestPlaybackV2EmptyState(t *testing.T) {
	_, httpServer := testServer(t)

	res, err := http.Get(httpServer.URL + "/api/v2/playback")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("playback v2 empty status = %s", res.Status)
	}

	var state *PlaybackStateV2
	if err := json.NewDecoder(res.Body).Decode(&state); err != nil {
		t.Fatal(err)
	}
	if state != nil {
		t.Fatalf("expected nil playback state, got %+v", state)
	}
}

func TestPlaybackV2PlayPauseAndSeekClock(t *testing.T) {
	srv, httpServer := testServer(t)
	now := time.Unix(100, 0)
	srv.now = func() time.Time { return now }
	track := testTrackReference("track_a")
	context := PlaybackContextV2{
		PlaybackSource: []TrackReference{track},
		Repeat:         "off",
	}

	state := postPlaybackCommandV2(t, httpServer.URL, PlaybackCommandV2{
		CommandID:      "cmd-play",
		Kind:           "play",
		DeviceID:       "desktop",
		TargetDeviceID: strPtr("phone"),
		Track:          &track,
		Context:        &context,
	})
	if state.State != "playing" || state.ActiveDeviceID == nil || *state.ActiveDeviceID != "phone" {
		t.Fatalf("bad play state: %+v", state)
	}
	if state.Clock.StartedAtMS == nil || *state.Clock.StartedAtMS != now.UnixMilli() || state.Clock.StoppedAtMS != nil {
		t.Fatalf("bad play clock: %+v", state.Clock)
	}

	now = now.Add(3 * time.Second)
	state = postPlaybackCommandV2(t, httpServer.URL, PlaybackCommandV2{
		CommandID:       "cmd-seek",
		Kind:            "seek",
		DeviceID:        "desktop",
		TargetDeviceID:  strPtr("phone"),
		PositionSeconds: floatPtr(10),
	})
	if state.State != "playing" || state.Clock.PositionSeconds != 10 || state.Clock.StartedAtMS == nil || *state.Clock.StartedAtMS != now.UnixMilli() {
		t.Fatalf("bad seek while playing: %+v", state)
	}

	now = now.Add(5 * time.Second)
	state = postPlaybackCommandV2(t, httpServer.URL, PlaybackCommandV2{
		CommandID:      "cmd-pause",
		Kind:           "pause",
		DeviceID:       "desktop",
		TargetDeviceID: strPtr("phone"),
	})
	if state.State != "paused" || state.Clock.StartedAtMS != nil || state.Clock.StoppedAtMS == nil {
		t.Fatalf("bad pause clock: %+v", state.Clock)
	}
	if state.Clock.PositionSeconds < 14.9 || state.Clock.PositionSeconds > 15.1 {
		t.Fatalf("pause did not derive position, got %.3f", state.Clock.PositionSeconds)
	}
}

func TestPlaybackV2NextAndDuplicateCommand(t *testing.T) {
	_, httpServer := testServer(t)
	trackA := testTrackReference("track_a")
	trackB := testTrackReference("track_b")
	queued := testTrackReference("track_queued")
	context := PlaybackContextV2{
		PlaybackSource: []TrackReference{trackA, trackB},
		QueuedTracks:   []TrackReference{queued},
		PlaybackIndex:  0,
		Repeat:         "off",
	}

	_ = postPlaybackCommandV2(t, httpServer.URL, PlaybackCommandV2{
		CommandID: "cmd-load",
		Kind:      "play",
		DeviceID:  "desktop",
		Track:     &trackA,
		Context:   &context,
	})
	state := postPlaybackCommandV2(t, httpServer.URL, PlaybackCommandV2{
		CommandID: "cmd-next",
		Kind:      "next",
		DeviceID:  "desktop",
	})
	if state.Track == nil || state.Track.ID != queued.ID || len(state.Context.QueuedTracks) != 0 {
		t.Fatalf("next did not consume queued track: %+v", state)
	}
	revision := state.Revision

	duplicate := postPlaybackCommandV2(t, httpServer.URL, PlaybackCommandV2{
		CommandID: "cmd-next",
		Kind:      "next",
		DeviceID:  "desktop",
	})
	if duplicate.Revision != revision || duplicate.Track == nil || duplicate.Track.ID != queued.ID {
		t.Fatalf("duplicate command advanced state: %+v", duplicate)
	}
}

func TestPlaybackV2EventsSendPlaybackState(t *testing.T) {
	_, httpServer := testServer(t)
	track := testTrackReference("track_a")
	playbackContext := PlaybackContextV2{PlaybackSource: []TrackReference{track}, Repeat: "off"}
	_ = postPlaybackCommandV2(t, httpServer.URL, PlaybackCommandV2{
		CommandID: "cmd-event-play",
		Kind:      "play",
		DeviceID:  "desktop",
		Track:     &track,
		Context:   &playbackContext,
	})

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, httpServer.URL+"/api/v2/playback/events", nil)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()

	buf := make([]byte, 1024)
	n, err := res.Body.Read(buf)
	if err != nil && !errorsIsContextDone(err) {
		t.Fatal(err)
	}
	body := string(buf[:n])
	if !strings.Contains(body, "event: playback_state") || !strings.Contains(body, `"schema":"loud.playback.v2"`) {
		t.Fatalf("expected playback_state event in %q", body)
	}
}

func postPlaybackCommandV2(t *testing.T, baseURL string, command PlaybackCommandV2) PlaybackStateV2 {
	t.Helper()
	raw, _ := json.Marshal(command)
	res, err := http.Post(baseURL+"/api/v2/playback/commands", "application/json", bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(res.Body)
		t.Fatalf("playback command status = %s: %s", res.Status, body)
	}
	var state PlaybackStateV2
	if err := json.NewDecoder(res.Body).Decode(&state); err != nil {
		t.Fatal(err)
	}
	return state
}

func testTrackReference(id string) TrackReference {
	return TrackReference{
		ID:          id,
		Path:        "/music/" + id + ".mp3",
		Fingerprint: "isrc:" + id,
	}
}

func strPtr(value string) *string {
	return &value
}

func floatPtr(value float64) *float64 {
	return &value
}

func statusOf(res *http.Response) string {
	if res == nil {
		return "<nil>"
	}
	return res.Status
}

func errorsIsContextDone(err error) bool {
	return errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded)
}

func TestSetTrackLikedTogglesLikeAndLikedPlaylist(t *testing.T) {
	srv, httpServer := testServer(t)

	track := Track{
		ID:          "track_abc",
		Title:       "Crystal Night",
		Artist:      "1986 OMEGA TRIBE",
		Album:       "Crystal Night",
		Fingerprint: "abc",
	}
	if err := srv.upsertTrack(context.Background(), track); err != nil {
		t.Fatal(err)
	}

	putLiked := func(fingerprint string, liked bool) *http.Response {
		t.Helper()
		body, _ := json.Marshal(map[string]bool{"liked": liked})
		req, err := http.NewRequest(http.MethodPut, httpServer.URL+"/api/v1/tracks/"+fingerprint+"/liked", bytes.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { res.Body.Close() })
		return res
	}

	if res := putLiked("abc", true); res.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 liking a known track, got %d", res.StatusCode)
	}

	library, err := srv.snapshot(context.Background(), httpServer.URL)
	if err != nil {
		t.Fatal(err)
	}
	if len(library.Library.Tracks) != 1 || !library.Library.Tracks[0].IsLiked {
		t.Fatalf("expected the track to be liked, got %+v", library.Library.Tracks)
	}
	likedPlaylist := library.Library.Playlists[0]
	if !likedPlaylist.IsLiked || len(likedPlaylist.TrackIDs) != 1 {
		t.Fatalf("expected liked playlist with one track, got %+v", likedPlaylist)
	}

	if res := putLiked("abc", false); res.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 unliking, got %d", res.StatusCode)
	}
	library, err = srv.snapshot(context.Background(), httpServer.URL)
	if err != nil {
		t.Fatal(err)
	}
	if library.Library.Tracks[0].IsLiked {
		t.Fatal("expected the track to be unliked")
	}

	if res := putLiked("missing", true); res.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404 for unknown fingerprint, got %d", res.StatusCode)
	}
}

func TestQueryAccessTokenAuthorizesHeaderlessClients(t *testing.T) {
	srv, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(srv.HandlerWithOptions(HandlerOptions{AuthToken: "sesame"}))
	t.Cleanup(func() {
		httpServer.Close()
		if err := srv.Close(); err != nil {
			t.Fatal(err)
		}
	})

	get := func(path string) int {
		t.Helper()
		res, err := http.Get(httpServer.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		return res.StatusCode
	}

	if status := get("/api/v1/library"); status != http.StatusUnauthorized {
		t.Fatalf("expected 401 without credentials, got %d", status)
	}
	if status := get("/api/v1/library?access_token=wrong"); status != http.StatusUnauthorized {
		t.Fatalf("expected 401 with a wrong token, got %d", status)
	}
	if status := get("/api/v1/library?access_token=sesame"); status != http.StatusOK {
		t.Fatalf("expected 200 with the query token, got %d", status)
	}
	if status := get("/api/v2/playback/events?access_token=sesame"); status != http.StatusOK {
		t.Fatalf("expected 200 for SSE with the query token, got %d", status)
	}
}
