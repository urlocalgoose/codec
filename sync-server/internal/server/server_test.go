package server

import (
	"bytes"
	"compress/gzip"
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

	// The static shell is public (it holds no data, and aux guests must be
	// able to load the app before they hold a token)...
	res, err := http.Get(httpServer.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	if res.StatusCode != http.StatusOK {
		t.Fatalf("public app shell status = %s", res.Status)
	}
	_ = res.Body.Close()

	// ...but every API route stays locked.
	res, err = http.Get(httpServer.URL + "/api/v1/library")
	if err != nil {
		t.Fatal(err)
	}
	if res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthorized API status = %s", res.Status)
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

func TestLibraryResponseGzipsWhenAccepted(t *testing.T) {
	_, httpServer := testServer(t)

	req, err := http.NewRequest(http.MethodGet, httpServer.URL+"/api/v1/library", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Accept-Encoding", "gzip")
	transport := &http.Transport{DisableCompression: true}
	res, err := (&http.Client{Transport: transport}).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()

	if encoding := res.Header.Get("Content-Encoding"); encoding != "gzip" {
		t.Fatalf("expected gzip encoding, got %q", encoding)
	}
	reader, err := gzip.NewReader(res.Body)
	if err != nil {
		t.Fatal(err)
	}
	body, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), `"tracks"`) {
		t.Fatalf("expected library JSON after gunzip, got %s", body)
	}

	// Clients that do not ask for gzip get plain JSON.
	plainRes, err := http.Get(httpServer.URL + "/api/v1/library")
	if err != nil {
		t.Fatal(err)
	}
	defer plainRes.Body.Close()
	if encoding := plainRes.Header.Get("Content-Encoding"); encoding == "gzip" {
		t.Fatal("expected plain response without Accept-Encoding")
	}
}

func TestLibraryETagServes304UntilTheLibraryChanges(t *testing.T) {
	srv, httpServer := testServer(t)

	get := func(etag string) *http.Response {
		t.Helper()
		req, err := http.NewRequest(http.MethodGet, httpServer.URL+"/api/v1/library", nil)
		if err != nil {
			t.Fatal(err)
		}
		if etag != "" {
			req.Header.Set("If-None-Match", etag)
		}
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { res.Body.Close() })
		return res
	}

	first := get("")
	etag := first.Header.Get("ETag")
	if first.StatusCode != http.StatusOK || etag == "" {
		t.Fatalf("expected 200 with an ETag, got %d %q", first.StatusCode, etag)
	}

	if res := get(etag); res.StatusCode != http.StatusNotModified {
		t.Fatalf("expected 304 for a matching ETag, got %d", res.StatusCode)
	}

	if err := srv.upsertTrack(context.Background(), Track{Fingerprint: "abc", Title: "A"}); err != nil {
		t.Fatal(err)
	}

	changed := get(etag)
	if changed.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 after a library write, got %d", changed.StatusCode)
	}
	if changed.Header.Get("ETag") == etag {
		t.Fatal("expected the ETag to change after a library write")
	}

	// A gzip-accepting client must get a clean 304 too (no trailer bytes).
	req, _ := http.NewRequest(http.MethodGet, httpServer.URL+"/api/v1/library", nil)
	req.Header.Set("If-None-Match", changed.Header.Get("ETag"))
	req.Header.Set("Accept-Encoding", "gzip")
	transport := &http.Transport{DisableCompression: true}
	res, err := (&http.Client{Transport: transport}).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	if res.StatusCode != http.StatusNotModified || len(body) != 0 {
		t.Fatalf("expected empty 304 for gzip client, got %d with %d bytes", res.StatusCode, len(body))
	}
}

func TestPlaylistCRUDEndpoints(t *testing.T) {
	srv, httpServer := testServer(t)

	if err := srv.upsertTrack(context.Background(), Track{Fingerprint: "fp1", Title: "One"}); err != nil {
		t.Fatal(err)
	}

	do := func(method, path string, body string) (*http.Response, map[string]any) {
		t.Helper()
		var reader io.Reader
		if body != "" {
			reader = strings.NewReader(body)
		}
		req, err := http.NewRequest(method, httpServer.URL+path, reader)
		if err != nil {
			t.Fatal(err)
		}
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { res.Body.Close() })
		var decoded map[string]any
		_ = json.NewDecoder(res.Body).Decode(&decoded)
		return res, decoded
	}

	res, playlist := do(http.MethodPost, "/api/v1/playlists", `{"name":"Road Trip"}`)
	if res.StatusCode != http.StatusCreated {
		t.Fatalf("create: expected 201, got %d", res.StatusCode)
	}
	id, _ := playlist["id"].(string)
	if id == "" || playlist["name"] != "Road Trip" {
		t.Fatalf("create: unexpected playlist %v", playlist)
	}

	res, playlist = do(http.MethodPost, "/api/v1/playlists/"+id+"/tracks", `{"fingerprint":"fp1"}`)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("add: expected 200, got %d", res.StatusCode)
	}
	if tracks, _ := playlist["track_ids"].([]any); len(tracks) != 1 || tracks[0] != "track_fp1" {
		t.Fatalf("add: unexpected track_ids %v", playlist["track_ids"])
	}

	// Adding the same track twice stays deduped.
	_, playlist = do(http.MethodPost, "/api/v1/playlists/"+id+"/tracks", `{"fingerprint":"fp1"}`)
	if tracks, _ := playlist["track_ids"].([]any); len(tracks) != 1 {
		t.Fatalf("dedupe: unexpected track_ids %v", playlist["track_ids"])
	}

	res, playlist = do(http.MethodDelete, "/api/v1/playlists/"+id+"/tracks/fp1", "")
	if res.StatusCode != http.StatusOK {
		t.Fatalf("remove: expected 200, got %d", res.StatusCode)
	}
	if tracks, _ := playlist["track_ids"].([]any); len(tracks) != 0 {
		t.Fatalf("remove: unexpected track_ids %v", playlist["track_ids"])
	}

	if res, _ := do(http.MethodDelete, "/api/v1/playlists/"+id, ""); res.StatusCode != http.StatusNoContent {
		t.Fatalf("delete: expected 204, got %d", res.StatusCode)
	}
	if res, _ := do(http.MethodDelete, "/api/v1/playlists/"+id, ""); res.StatusCode != http.StatusNotFound {
		t.Fatalf("delete twice: expected 404, got %d", res.StatusCode)
	}
	if res, _ := do(http.MethodPost, "/api/v1/playlists/nope/tracks", `{"fingerprint":"fp1"}`); res.StatusCode != http.StatusNotFound {
		t.Fatalf("add to unknown: expected 404, got %d", res.StatusCode)
	}
}

func TestAudioUploadsRememberTheirContentType(t *testing.T) {
	srv, httpServer := testServer(t)
	if err := srv.upsertTrack(context.Background(), Track{Fingerprint: "flacfp", Title: "Lossless"}); err != nil {
		t.Fatal(err)
	}

	put, err := http.NewRequest(http.MethodPut, httpServer.URL+"/api/v1/tracks/flacfp/audio", strings.NewReader("flac-bytes"))
	if err != nil {
		t.Fatal(err)
	}
	put.Header.Set("Content-Type", "audio/flac")
	res, err := http.DefaultClient.Do(put)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusNoContent {
		t.Fatalf("upload: expected 204, got %d", res.StatusCode)
	}

	get, err := http.Get(httpServer.URL + "/api/v1/tracks/flacfp/audio")
	if err != nil {
		t.Fatal(err)
	}
	get.Body.Close()
	if got := get.Header.Get("Content-Type"); got != "audio/flac" {
		t.Fatalf("expected audio/flac back, got %q", got)
	}

	// Junk content types fall back to the MP3 default instead of being stored.
	if normalizeAudioType("application/octet-stream") != "audio/mpeg" {
		t.Fatal("expected octet-stream to normalize to audio/mpeg")
	}
}

func TestReorderPlaylistTracks(t *testing.T) {
	srv, httpServer := testServer(t)
	ctx := context.Background()
	for _, fp := range []string{"r1", "r2", "r3"} {
		if err := srv.upsertTrack(ctx, Track{Fingerprint: fp, Title: fp}); err != nil {
			t.Fatal(err)
		}
	}
	playlist, err := srv.createPlaylist(ctx, "Ordered")
	if err != nil {
		t.Fatal(err)
	}
	for _, fp := range []string{"r1", "r2", "r3"} {
		if _, err := srv.modifyPlaylistTracks(ctx, playlist.ID, func(ids []string) []string {
			return append(ids, "track_"+fp)
		}); err != nil {
			t.Fatal(err)
		}
	}

	body := strings.NewReader(`{"track_ids":["track_r3","track_r1","track_r2"]}`)
	req, err := http.NewRequest(http.MethodPut, httpServer.URL+"/api/v1/playlists/"+playlist.ID+"/tracks", body)
	if err != nil {
		t.Fatal(err)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", res.StatusCode)
	}
	var updated Playlist
	if err := json.NewDecoder(res.Body).Decode(&updated); err != nil {
		t.Fatal(err)
	}
	want := []string{"track_r3", "track_r1", "track_r2"}
	if len(updated.TrackIDs) != 3 || updated.TrackIDs[0] != want[0] || updated.TrackIDs[1] != want[1] || updated.TrackIDs[2] != want[2] {
		t.Fatalf("unexpected order %v", updated.TrackIDs)
	}
}

func TestAuxGuestScope(t *testing.T) {
	srv, _ := testServer(t)
	handler := srv.HandlerWithOptions(HandlerOptions{AuthToken: "host-secret"})
	httpServer := httptest.NewServer(handler)
	t.Cleanup(httpServer.Close)
	ctx := context.Background()
	if err := srv.upsertTrack(ctx, Track{Fingerprint: "auxfp", Title: "Aux Track"}); err != nil {
		t.Fatal(err)
	}

	do := func(method, path, token, body string) *http.Response {
		t.Helper()
		var reader io.Reader
		if body != "" {
			reader = strings.NewReader(body)
		}
		req, err := http.NewRequest(method, httpServer.URL+path, reader)
		if err != nil {
			t.Fatal(err)
		}
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { res.Body.Close() })
		return res
	}

	// Hosts create sessions; strangers cannot.
	if res := do(http.MethodPost, "/api/v1/aux", "", `{}`); res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 creating aux without auth, got %d", res.StatusCode)
	}
	res := do(http.MethodPost, "/api/v1/aux", "host-secret", `{}`)
	if res.StatusCode != http.StatusCreated {
		t.Fatalf("expected 201 creating aux, got %d", res.StatusCode)
	}
	var created struct {
		Code       string `json:"code"`
		GuestToken string `json:"guest_token"`
	}
	if err := json.NewDecoder(res.Body).Decode(&created); err != nil {
		t.Fatal(err)
	}

	// Join is public and hands back the guest token.
	res = do(http.MethodPost, "/api/v1/aux/join", "", `{"code":"`+created.Code+`"}`)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 joining, got %d", res.StatusCode)
	}

	// Guests can browse and drive shared playback...
	if res := do(http.MethodGet, "/api/v1/library", created.GuestToken, ""); res.StatusCode != http.StatusOK {
		t.Fatalf("guest library read: expected 200, got %d", res.StatusCode)
	}
	if res := do(http.MethodGet, "/api/v2/playback", created.GuestToken, ""); res.StatusCode != http.StatusOK {
		t.Fatalf("guest playback read: expected 200, got %d", res.StatusCode)
	}

	// ...but nothing that mutates the library or the session.
	if res := do(http.MethodPut, "/api/v1/tracks/auxfp/liked", created.GuestToken, `{"liked":true}`); res.StatusCode != http.StatusForbidden {
		t.Fatalf("guest like: expected 403, got %d", res.StatusCode)
	}
	if res := do(http.MethodPost, "/api/v1/playlists", created.GuestToken, `{"name":"nope"}`); res.StatusCode != http.StatusForbidden {
		t.Fatalf("guest playlist create: expected 403, got %d", res.StatusCode)
	}
	if res := do(http.MethodPost, "/api/v1/aux", created.GuestToken, `{}`); res.StatusCode != http.StatusForbidden {
		t.Fatalf("guest aux create: expected 403, got %d", res.StatusCode)
	}

	// Ending the session kills the guest token immediately.
	if res := do(http.MethodDelete, "/api/v1/aux/"+created.Code, "host-secret", ""); res.StatusCode != http.StatusNoContent {
		t.Fatalf("end aux: expected 204, got %d", res.StatusCode)
	}
	if res := do(http.MethodGet, "/api/v1/library", created.GuestToken, ""); res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("dead guest token: expected 401, got %d", res.StatusCode)
	}
}

func TestMediaGrantsAreScopedToGrantedTracks(t *testing.T) {
	srv, _ := testServer(t)
	handler := srv.HandlerWithOptions(HandlerOptions{AuthToken: "host-secret"})
	httpServer := httptest.NewServer(handler)
	t.Cleanup(httpServer.Close)
	ctx := context.Background()

	for _, fp := range []string{"granted", "notgranted"} {
		if err := srv.upsertTrack(ctx, Track{Fingerprint: fp, Title: fp}); err != nil {
			t.Fatal(err)
		}
		req, _ := http.NewRequest(http.MethodPut, httpServer.URL+"/api/v1/tracks/"+fp+"/audio", strings.NewReader("bytes"))
		req.Header.Set("Authorization", "Bearer host-secret")
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
	}

	grantReq, _ := http.NewRequest(http.MethodPost, httpServer.URL+"/api/v1/media-grants", strings.NewReader(`{"fingerprints":["granted"]}`))
	grantReq.Header.Set("Authorization", "Bearer host-secret")
	res, err := http.DefaultClient.Do(grantReq)
	if err != nil {
		t.Fatal(err)
	}
	var grant struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(res.Body).Decode(&grant); err != nil {
		t.Fatal(err)
	}
	res.Body.Close()

	get := func(path, token string) int {
		req, _ := http.NewRequest(http.MethodGet, httpServer.URL+path, nil)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		return res.StatusCode
	}

	if code := get("/api/v1/tracks/granted/audio", grant.Token); code != http.StatusOK {
		t.Fatalf("granted audio: expected 200, got %d", code)
	}
	if code := get("/api/v1/tracks/notgranted/audio", grant.Token); code != http.StatusUnauthorized {
		t.Fatalf("ungranted audio: expected 401, got %d", code)
	}
	if code := get("/api/v1/library", grant.Token); code != http.StatusUnauthorized {
		t.Fatalf("grant on library: expected 401, got %d", code)
	}
}
