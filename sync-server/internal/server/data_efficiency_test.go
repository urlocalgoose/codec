package server

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

func decodedResponse(t *testing.T, response *httptest.ResponseRecorder) []byte {
	t.Helper()
	if response.Header().Get("Content-Encoding") != "gzip" {
		return response.Body.Bytes()
	}
	reader, err := gzip.NewReader(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	body, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	return body
}

func TestJSONCompressionNegotiation(t *testing.T) {
	body := `{"queue":"` + strings.Repeat("song ", 1000) + `"}`
	handler := withGzip(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Add("Vary", "Origin")
		_, _ = io.WriteString(w, body)
	}))
	for _, test := range []struct {
		header string
		gzip   bool
	}{
		{"", false}, {"gzip", true}, {"br, gzip;q=0.8", true},
		{"gzip;q=0", false}, {"gzip;q=0, *;q=1", false}, {"*;q=0.5", true},
		{"xgzip", false}, {"GZip; Q=1", true}, {"gzip;q=invalid", false},
		{"gzip;q=NaN", false}, {"gzip;q=2", false}, {"gzip;q=0.5, identity;q=1", false},
	} {
		t.Run(test.header, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodPost, "/api/v2/playback/commands", nil)
			r.Header.Set("Accept-Encoding", test.header)
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, r)
			if got := w.Header().Get("Content-Encoding") == "gzip"; got != test.gzip {
				t.Fatalf("gzip=%v, expected %v", got, test.gzip)
			}
			if got := string(decodedResponse(t, w)); got != body {
				t.Fatalf("response body changed: %q", got)
			}
			if vary := strings.Join(w.Header().Values("Vary"), ","); !strings.Contains(vary, "Origin") || !strings.Contains(vary, "Accept-Encoding") {
				t.Fatalf("missing Vary fields: %q", vary)
			}
		})
	}
}

func TestJSONCompressionPreservesStreamingAndBodylessResponses(t *testing.T) {
	for _, path := range []string{
		"/api/v2/playback/events", "/api/v1/playback/events", "/api/v1/tracks/song/audio",
		"/api/v1/tracks/song/artwork", "/api/v1/playlists/list/artwork", "/api/v1/export",
		"/api/v1/auth/stream-token", "/api/v1/aux/join", "/api/v1/media-grants",
	} {
		t.Run(path, func(t *testing.T) {
			underlying := httptest.NewRecorder()
			handler := withGzip(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if w != underlying {
					t.Fatal("stream/media/credential writer was wrapped")
				}
				w.(http.Flusher).Flush()
			}))
			r := httptest.NewRequest(http.MethodGet, path, nil)
			r.Header.Set("Accept-Encoding", "gzip")
			handler.ServeHTTP(underlying, r)
		})
	}
	for _, status := range []int{http.StatusNoContent, http.StatusNotModified} {
		r := httptest.NewRequest(http.MethodGet, "/api/v1/library", nil)
		r.Header.Set("Accept-Encoding", "gzip")
		w := httptest.NewRecorder()
		withGzip(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(status) })).ServeHTTP(w, r)
		if w.Code != status || w.Body.Len() != 0 || w.Header().Get("Content-Encoding") != "" {
			t.Fatalf("bodyless response changed: status=%d bytes=%d encoding=%q", w.Code, w.Body.Len(), w.Header().Get("Content-Encoding"))
		}
	}
	for _, method := range []string{http.MethodGet, http.MethodHead} {
		r := httptest.NewRequest(method, "/api/v2/playback", nil)
		r.Header.Set("Accept-Encoding", "gzip")
		if method == http.MethodGet {
			r.Header.Set("Range", "bytes=0-10")
		}
		w := httptest.NewRecorder()
		withGzip(http.HandlerFunc(func(writer http.ResponseWriter, r *http.Request) {
			if writer != w {
				t.Fatal("HEAD/range response was wrapped")
			}
		})).ServeHTTP(w, r)
	}
}

func TestJSONCompressionBuffersOnlySmallReplies(t *testing.T) {
	for _, size := range []int{0, 1, minimumGzipBytes - 1, minimumGzipBytes, 10000} {
		t.Run(fmt.Sprint(size), func(t *testing.T) {
			body := strings.Repeat("x", size)
			r := httptest.NewRequest(http.MethodPost, "/api/v2/playback/commands", nil)
			r.Header.Set("Accept-Encoding", "gzip")
			w := httptest.NewRecorder()
			withGzip(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusCreated)
				w.WriteHeader(http.StatusTeapot) // only the first final status counts
				for _, c := range []byte(body) {
					_, _ = w.Write([]byte{c})
				}
			})).ServeHTTP(w, r)
			if w.Code != http.StatusCreated || string(decodedResponse(t, w)) != body {
				t.Fatal("chunked response changed")
			}
			if (w.Header().Get("Content-Encoding") == "gzip") != (size >= minimumGzipBytes) {
				t.Fatalf("unexpected encoding for %d-byte reply", size)
			}
		})
	}
}

func TestLibraryValidatorsAcrossCompressionProxyAndEndpoint(t *testing.T) {
	s, _ := testServer(t)
	handler := s.Handler()
	get := func(path, encoding, tag string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodGet, "https://codec.test"+path, nil)
		r.Header.Set("Accept-Encoding", encoding)
		r.Header.Set("If-None-Match", tag)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	first := get("/api/v1/library", "gzip", "")
	tag := first.Header().Get("ETag")
	if !strings.HasPrefix(tag, `W/"`) || first.Header().Get("Cache-Control") != "private, no-cache" {
		t.Fatalf("library must have private policy and weak validator: %v", first.Header())
	}
	strong := strings.TrimPrefix(tag, "W/")
	// A proxy can weaken a strong origin validator after changing content coding.
	for _, candidate := range []string{tag, strong, `"other", ` + tag, "*"} {
		for _, encoding := range []string{"identity", "gzip", "gzip;q=0"} {
			response := get("/api/v1/library", encoding, candidate)
			if response.Code != http.StatusNotModified || response.Body.Len() != 0 || response.Header().Get("Content-Encoding") != "" {
				t.Fatalf("revalidation failed: tag=%s encoding=%s status=%d bytes=%d", candidate, encoding, response.Code, response.Body.Len())
			}
		}
	}
	if !matchesETag("W/"+strong, strong) {
		t.Fatal("weak proxy tag does not match strong origin tag")
	}
	if response := get("/api/v1/sync/snapshot", "gzip", tag); response.Code != http.StatusOK || response.Header().Get("ETag") == tag {
		t.Fatal("library validator was incorrectly reused for snapshot endpoint")
	}
	plain := get("/api/v1/library", "gzip;q=0", "")
	if plain.Header().Get("Content-Encoding") != "" || !bytes.Equal(decodedResponse(t, first), plain.Body.Bytes()) {
		t.Fatal("library gzip refusal or cached encoding failed")
	}
	if response := get("/api/v1/library", "gzip", `"unrelated"`); response.Code != http.StatusOK {
		t.Fatal("nonmatching validator should fetch")
	}
}

func TestLibraryResponseCacheReuseInvalidationAndURLIsolation(t *testing.T) {
	s, _ := testServer(t)
	ctx := context.Background()
	key := libraryResponseKey{baseURL: "https://first.test"}
	if err := s.upsertTrack(ctx, Track{Fingerprint: "first", Title: "Before"}); err != nil {
		t.Fatal(err)
	}
	path := s.audioPath("first")
	if err := os.WriteFile(path, []byte("audio"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := s.attachMediaPath(ctx, "first", "audio_path", path, 5); err != nil {
		t.Fatal(err)
	}
	first, err := s.cachedLibraryResponse(ctx, key)
	if err != nil {
		t.Fatal(err)
	}
	var group sync.WaitGroup
	for range 20 {
		group.Go(func() {
			response, err := s.cachedLibraryResponse(ctx, key)
			if err != nil || response != first {
				t.Error("concurrent unchanged request did not reuse encoded response")
			}
		})
	}
	group.Wait()
	secondKey := libraryResponseKey{baseURL: "https://second.test"}
	second, err := s.cachedLibraryResponse(ctx, secondKey)
	if err != nil || first == second || first.etag == second.etag {
		t.Fatal("public URLs share cache entry or validator")
	}
	if !bytes.Contains(first.plain, []byte("https://first.test/api/v1/tracks/first/audio")) ||
		!bytes.Contains(second.plain, []byte("https://second.test/api/v1/tracks/first/audio")) ||
		bytes.Contains(second.plain, []byte("https://first.test")) {
		t.Fatal("cached response leaked another origin's media URLs")
	}
	if err := s.upsertTrack(ctx, Track{Fingerprint: "first", Title: "After"}); err != nil {
		t.Fatal(err)
	}
	after, err := s.cachedLibraryResponse(ctx, key)
	if err != nil || first == after || first.etag == after.etag || !bytes.Contains(after.plain, []byte(`"title":"After"`)) {
		t.Fatal("metadata write did not invalidate cached response")
	}
	if err := s.setTrackLiked(ctx, "first", true); err != nil {
		t.Fatal(err)
	}
	liked, err := s.cachedLibraryResponse(ctx, key)
	if err != nil || liked == after || !bytes.Contains(liked.plain, []byte(`"likedCount":1`)) {
		t.Fatal("liked write did not invalidate cached response")
	}
	for i := range maxLibraryResponseEntries + 3 {
		if _, err := s.cachedLibraryResponse(ctx, libraryResponseKey{baseURL: fmt.Sprintf("https://host%d.test", i)}); err != nil {
			t.Fatal(err)
		}
	}
	if len(s.libraryResponses.entries) != maxLibraryResponseEntries || s.libraryResponses.bytes > maxLibraryResponseBytes {
		t.Fatal("library response cache exceeded its bounds")
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := s.cachedLibraryResponse(cancelled, key); err != context.Canceled {
		t.Fatalf("canceled request rebuilt cache: %v", err)
	}
}

func TestLibraryResponseCacheNeverBypassesAuthorization(t *testing.T) {
	s, _ := testServer(t)
	handler := s.HandlerWithOptions(HandlerOptions{AuthToken: "private"})
	var etag string
	for _, auth := range []string{"Bearer private", "", "Bearer wrong"} {
		r := httptest.NewRequest(http.MethodGet, "https://codec.test/api/v1/library", nil)
		r.Header.Set("Authorization", auth)
		r.Header.Set("Accept-Encoding", "gzip")
		r.Header.Set("If-None-Match", etag)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if auth == "Bearer private" && w.Code != http.StatusOK || auth != "Bearer private" && w.Code != http.StatusUnauthorized {
			t.Fatalf("cache bypassed auth with %q: status=%d", auth, w.Code)
		}
		if auth == "Bearer private" {
			etag = w.Header().Get("ETag")
		}
	}
}

func TestLibraryResponseChangingDuringScanIsNotCached(t *testing.T) {
	s, _ := testServer(t)
	ctx := context.Background()
	if err := s.upsertTrack(ctx, Track{Fingerprint: "changing"}); err != nil {
		t.Fatal(err)
	}
	key := libraryResponseKey{baseURL: "https://codec.test"}
	var mutation sync.Once
	// snapshot asks for its timestamp after reading tracks. Commit a mutation
	// at that exact boundary, equivalent to an overlapping library write.
	s.now = func() time.Time {
		mutation.Do(func() {
			if _, err := s.db.ExecContext(ctx, `UPDATE tracks SET is_liked = 1 WHERE fingerprint = 'changing'`); err != nil {
				t.Fatal(err)
			}
			s.libraryChanged()
		})
		return time.Unix(100, 0)
	}
	first, err := s.cachedLibraryResponse(ctx, key)
	if err != nil {
		t.Fatal(err)
	}
	if len(s.libraryResponses.entries) != 0 || first.etag == s.libraryETag(key, s.libraryVersion.Load()) {
		t.Fatal("overlapping write published an old snapshot under the current validator")
	}
	next, err := s.cachedLibraryResponse(ctx, key)
	if err != nil || first.etag == next.etag || !bytes.Contains(next.plain, []byte(`"likedCount":1`)) {
		t.Fatal("refresh after overlapping write did not return the mutation")
	}
}

func TestPlaybackCommandResponseCompression(t *testing.T) {
	s, _ := testServer(t)
	queue := make([]TrackReference, 100)
	for i := range queue {
		queue[i] = TrackReference{ID: fmt.Sprintf("track%d", i), Fingerprint: fmt.Sprintf("fp%d", i)}
	}
	command := PlaybackCommandV2{CommandID: "command-gzip", DeviceID: "phone", Kind: "play", Track: &queue[0], Context: &PlaybackContextV2{PlaybackSource: queue}}
	body, err := json.Marshal(command)
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest(http.MethodPost, "/api/v2/playback/commands", bytes.NewReader(body))
	r.Header.Set("Accept-Encoding", "gzip")
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("command failed: %s", decodedResponse(t, w))
	}
	var state PlaybackStateV2
	if err := json.Unmarshal(decodedResponse(t, w), &state); err != nil || state.Revision != 1 {
		t.Fatalf("invalid compressed command response: %v revision=%d", err, state.Revision)
	}
	if w.Header().Get("Content-Encoding") != "gzip" {
		t.Fatal("playback command response was not compressed")
	}
	if len(state.Context.PlaybackSource) != len(queue) {
		t.Fatal("compression changed the playback queue")
	}
}

// This fixture models a metadata-heavy music library without user data. The
// baseline performs the old scan+summarize+encode+gzip path on every request.
func BenchmarkLibraryResponse(b *testing.B) {
	s, err := Open(b.TempDir())
	if err != nil {
		b.Fatal(err)
	}
	defer s.Close()
	s.now = func() time.Time { return time.Unix(100, 0) }
	ctx := context.Background()
	for i := range 1000 {
		fingerprint := fmt.Sprintf("%x", sha256.Sum256([]byte(fmt.Sprint(i))))
		track := Track{
			Fingerprint: fingerprint, Title: fmt.Sprintf("Track %d", i), Artist: fmt.Sprintf("Artist %d", i%100),
			Album: fmt.Sprintf("Album %d", i%200), FileName: fmt.Sprintf("track-%d.mp3", i), SizeBytes: 5000000,
			Identifiers: map[string]string{"recording": fingerprint[:24], "release": fingerprint[24:]},
			SourceURLs:  map[string]string{"source": "https://source.test/track/" + fingerprint},
		}
		if err := s.upsertTrack(ctx, track); err != nil {
			b.Fatal(err)
		}
	}
	key := libraryResponseKey{baseURL: "https://codec.test"}
	cached, err := s.cachedLibraryResponse(ctx, key)
	if err != nil {
		b.Fatal(err)
	}
	b.Logf("synthetic 1,000-track library: %d JSON bytes, %d gzip bytes (%.1f%% less)", len(cached.plain), len(cached.gzip), 100*(1-float64(len(cached.gzip))/float64(len(cached.plain))))
	b.Run("previous_scan_encode_gzip", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			snapshot, err := s.snapshot(ctx, key.baseURL)
			if err != nil {
				b.Fatal(err)
			}
			writer := gzip.NewWriter(io.Discard)
			if err := json.NewEncoder(writer).Encode(snapshot.Library); err != nil {
				b.Fatal(err)
			}
			_ = writer.Close()
		}
	})
	handler := withGzip(http.HandlerFunc(s.handleLibrary))
	for _, test := range []struct{ name, encoding, etag string }{
		{"cached_identity_200", "identity", ""}, {"cached_gzip_200", "gzip", ""}, {"unchanged_304", "gzip", cached.etag},
	} {
		b.Run(test.name, func(b *testing.B) {
			r := httptest.NewRequest(http.MethodGet, key.baseURL+"/api/v1/library", nil)
			r.Header.Set("Accept-Encoding", test.encoding)
			r.Header.Set("If-None-Match", test.etag)
			writer := &discardResponse{header: make(http.Header)}
			b.ReportAllocs()
			for b.Loop() {
				clear(writer.header)
				handler.ServeHTTP(writer, r)
			}
		})
	}
}

type discardResponse struct{ header http.Header }

func (w *discardResponse) Header() http.Header         { return w.header }
func (w *discardResponse) WriteHeader(status int)      {}
func (w *discardResponse) Write(p []byte) (int, error) { return len(p), nil }
