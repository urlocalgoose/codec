package server

import (
	"context"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func TestSyncCombinedHandlerCompressesPrivateLibrary(t *testing.T) {
	s, _ := testServer(t)
	r := httptest.NewRequest("GET", "/api/v1/library", nil)
	r.Header.Set("Authorization", "Bearer test-secret")
	r.Header.Set("Accept-Encoding", "gzip")
	w := httptest.NewRecorder()
	s.HandlerWithOptions(HandlerOptions{WebDir: t.TempDir(), AuthToken: "test-secret"}).ServeHTTP(w, r)
	if w.Code != 200 || w.Header().Get("Content-Encoding") != "gzip" {
		t.Fatalf("status=%d encoding=%q", w.Code, w.Header().Get("Content-Encoding"))
	}
}

func TestSyncPlaylistEditsAreAtomic(t *testing.T) {
	s, _ := testServer(t)
	ctx := context.Background()
	if err := s.upsertPlaylist(ctx, Playlist{ID: "p", TrackIDs: []string{}}); err != nil {
		t.Fatal(err)
	}
	firstRead, releaseFirst, secondRead := make(chan struct{}), make(chan struct{}), make(chan struct{})
	errs := make(chan error, 2)
	go func() {
		_, err := s.modifyPlaylistTracks(ctx, "p", func(ids []string) []string { close(firstRead); <-releaseFirst; return append(ids, "A") })
		errs <- err
	}()
	<-firstRead
	go func() {
		_, err := s.modifyPlaylistTracks(ctx, "p", func(ids []string) []string { close(secondRead); return append(ids, "B") })
		errs <- err
	}()
	select {
	case <-secondRead:
		t.Error("second edit read before first edit committed")
	case <-time.After(50 * time.Millisecond):
	}
	close(releaseFirst)
	for range 2 {
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
	}
	playlist, err := s.playlistByID(ctx, "p")
	if err != nil || strings.Join(playlist.TrackIDs, ",") != "A,B" {
		t.Fatalf("lost edit: ids=%v error=%v", playlist.TrackIDs, err)
	}
}

func TestSyncTransportPreservesNewerQueue(t *testing.T) {
	for _, kind := range []string{"pause", "seek", "transfer", "volume", "set_repeat", "next", "previous"} {
		t.Run(kind, func(t *testing.T) {
			state := emptyPlaybackStateV2(1000)
			state.Context.QueuedTracks = []TrackReference{{ID: "new", Fingerprint: "new"}}
			stale := PlaybackContextV2{}
			if err := applyPlaybackCommandMutationV2(&state, PlaybackCommandV2{Kind: kind, DeviceID: "phone", Context: &stale}, 2000); err != nil {
				t.Fatal(err)
			}
			if kind == "next" {
				if state.Track == nil || state.Track.ID != "new" {
					t.Fatal("next lost new queued track")
				}
			} else if len(state.Context.QueuedTracks) != 1 || state.Context.QueuedTracks[0].ID != "new" {
				t.Fatal("transport replaced newer queue")
			}
		})
	}
}

func TestSyncLibraryETagChangesAcrossRestart(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	get := func(s *Server, tag string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", "http://codec.test/api/v1/library", nil)
		r.Header.Set("If-None-Match", tag)
		w := httptest.NewRecorder()
		s.Handler().ServeHTTP(w, r)
		return w
	}
	tag := get(s, "").Header().Get("ETag")
	if err := s.upsertTrack(context.Background(), Track{Fingerprint: "added"}); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	w := get(s, tag)
	if w.Code != 200 || w.Header().Get("ETag") == tag {
		t.Fatalf("stale validator survived restart: status=%d", w.Code)
	}
}

func TestSyncPrivateMediaAndCoverVersions(t *testing.T) {
	s, _ := testServer(t)
	path := s.playlistArtworkPath("p")
	if err := os.WriteFile(path, []byte("test-cover"), 0600); err != nil {
		t.Fatal(err)
	}
	version := func(nanos int64) string {
		stamp := time.Unix(100, nanos)
		if err := os.Chtimes(path, stamp, stamp); err != nil {
			t.Fatal(err)
		}
		playlists := []Playlist{{ID: "p"}}
		s.attachPlaylistArtwork(playlists, "http://codec.test")
		return *playlists[0].ArtworkURL
	}
	if version(100000000) == version(200000000) {
		t.Fatal("cover edits in same second have identical URLs")
	}
	w := httptest.NewRecorder()
	serveMedia(w, httptest.NewRequest("GET", "/cover", nil), path, "image/jpeg")
	if got := w.Header().Get("Cache-Control"); got != "private, no-cache" {
		t.Fatalf("unsafe media caching: %q", got)
	}
}

func TestSyncOverflowDisconnectsSubscriber(t *testing.T) {
	h := newPlaybackEventHub()
	events, unsubscribe := h.subscribe()
	defer unsubscribe()
	for range 33 {
		h.broadcast(PlaybackEvent{Type: "device"})
	}
	for range 32 {
		<-events
	}
	select {
	case _, ok := <-events:
		if ok {
			t.Fatal("expected reconnect after overflow")
		}
	default:
		t.Fatal("subscriber silently lost event")
	}
}

func TestLegacyAuxCannotOpenGlobalStream(t *testing.T) {
	s, _ := testServer(t)
	session, err := s.createAuxSession(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	h := s.HandlerWithOptions(HandlerOptions{AuthToken: "test-secret"})
	r := httptest.NewRequest("GET", "/api/v2/playback/events", nil)
	r.Header.Set("Authorization", "Bearer "+session.GuestToken)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatalf("legacy guest stream status=%d", w.Code)
	}
	if err := s.endAuxSession(context.Background(), session.Code); err != nil {
		t.Fatal(err)
	}
	w = httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 401 {
		t.Fatalf("revoked legacy guest status=%d", w.Code)
	}
}

type snapshotBarrierWriter struct {
	*httptest.ResponseRecorder
	initial chan struct{}
	release chan struct{}
	changed chan struct{}
	flushed bool
}

func (w *snapshotBarrierWriter) Flush() {
	if !w.flushed {
		w.flushed = true
		close(w.initial)
		<-w.release
	}
}
func (w *snapshotBarrierWriter) Write(p []byte) (int, error) {
	if strings.Contains(string(p), "after-snapshot") {
		select {
		case w.changed <- struct{}{}:
		default:
		}
	}
	return w.ResponseRecorder.Write(p)
}

func TestSyncSubscribesBeforeSnapshotFlush(t *testing.T) {
	s, _ := testServer(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	w := &snapshotBarrierWriter{ResponseRecorder: httptest.NewRecorder(), initial: make(chan struct{}), release: make(chan struct{}), changed: make(chan struct{}, 1)}
	done := make(chan struct{})
	go func() {
		s.handlePlaybackEventsV2(w, httptest.NewRequest("GET", "/api/v2/playback/events", nil).WithContext(ctx))
		close(done)
	}()
	<-w.initial
	s.playbackEvents.broadcast(PlaybackEvent{Type: "device", Device: &PlaybackDevice{DeviceID: "after-snapshot"}})
	close(w.release)
	select {
	case <-w.changed:
	case <-time.After(time.Second):
		t.Error("event between snapshot and flush was lost")
	}
	cancel()
	<-done
}

func TestSyncLibraryWritesNotifySubscribers(t *testing.T) {
	s, _ := testServer(t)
	events, unsubscribe := s.playbackEvents.subscribe()
	defer unsubscribe()
	if err := s.upsertTrack(context.Background(), Track{Fingerprint: "new"}); err != nil {
		t.Fatal(err)
	}
	select {
	case event := <-events:
		if event.Type != "library" {
			t.Fatalf("expected library notification, got %s", event.Type)
		}
	default:
		t.Fatal("library edit was not published")
	}
}

func TestSyncStaleQueueReplacementReturnsConflict(t *testing.T) {
	s, _ := testServer(t)
	send := func(id, revision, queued string) *httptest.ResponseRecorder {
		body := `{"command_id":"` + id + `","kind":"set_queue","device_id":"web","context":{"queued_tracks":[{"id":"` + queued + `","path":"` + queued + `","fingerprint":"` + queued + `"}]}}`
		r := httptest.NewRequest("POST", "/api/v2/playback/commands", strings.NewReader(body))
		r.Header.Set("If-Match", revision)
		w := httptest.NewRecorder()
		s.Handler().ServeHTTP(w, r)
		return w
	}
	if w := send("first", `"0"`, "A"); w.Code != 200 {
		t.Fatalf("first edit: %d %s", w.Code, w.Body.String())
	}
	if w := send("stale", `"0"`, "B"); w.Code != 409 {
		t.Fatalf("stale edit: %d %s", w.Code, w.Body.String())
	}
	state, err := s.playbackStateV2(context.Background())
	if err != nil || state.Revision != 1 || state.Context.QueuedTracks[0].ID != "A" {
		t.Fatalf("stale edit changed state: %+v %v", state, err)
	}
	if w := send("first", `"0"`, "A"); w.Code != 200 {
		t.Fatalf("idempotent retry: %d", w.Code)
	}
	if w := send("retry", `"1"`, "B"); w.Code != 200 {
		t.Fatalf("refreshed edit: %d %s", w.Code, w.Body.String())
	}
}
