package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestBrowserPlaylistDeletePreflightAndAuthorization(t *testing.T) {
	s, _ := testServer(t)
	if err := s.upsertPlaylist(context.Background(), Playlist{ID: "p", TrackIDs: []string{"track_a", "track_b"}}); err != nil {
		t.Fatal(err)
	}
	handler := s.HandlerWithOptions(HandlerOptions{AuthToken: "test-secret", WebDir: t.TempDir()})
	const route = "/api/v1/playlists/p/tracks/a"
	preflight := httptest.NewRequest(http.MethodOptions, route, nil)
	preflight.Header.Set("Origin", "https://web.codec.test")
	preflight.Header.Set("Access-Control-Request-Method", http.MethodDelete)
	preflight.Header.Set("Access-Control-Request-Headers", "authorization")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, preflight)
	if w.Code != http.StatusNoContent || !strings.Contains(w.Header().Get("Access-Control-Allow-Methods"), "DELETE") || !strings.Contains(w.Header().Get("Access-Control-Allow-Headers"), "Authorization") {
		t.Fatalf("preflight status=%d headers=%v", w.Code, w.Header())
	}
	for _, authenticated := range []bool{false, true} {
		r := httptest.NewRequest(http.MethodDelete, route, nil)
		r.Header.Set("Origin", "https://web.codec.test")
		if authenticated {
			r.Header.Set("Authorization", "Bearer test-secret")
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		want := http.StatusUnauthorized
		if authenticated {
			want = http.StatusOK
		}
		if w.Code != want {
			t.Fatalf("authenticated=%t: status=%d want=%d", authenticated, w.Code, want)
		}
	}
	playlist, err := s.playlistByID(context.Background(), "p")
	if err != nil || strings.Join(playlist.TrackIDs, ",") != "track_b" {
		t.Fatalf("playlist=%+v error=%v", playlist, err)
	}
}

func TestPlaylistRenamePreservesMembershipAndInvalidatesLibrary(t *testing.T) {
	s, _ := testServer(t)
	if err := s.upsertPlaylist(context.Background(), Playlist{ID: "p", Name: "Before", IsLiked: true, TrackIDs: []string{"track_a", "track_b"}}); err != nil {
		t.Fatal(err)
	}
	handler := s.Handler()
	before := httptest.NewRecorder()
	handler.ServeHTTP(before, httptest.NewRequest(http.MethodGet, "/api/v1/library", nil))
	r := httptest.NewRequest(http.MethodPut, "/api/v1/playlists/p/name", strings.NewReader(`{"name":"  After  "}`))
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != http.StatusNoContent {
		t.Fatalf("rename: status=%d body=%s", w.Code, w.Body)
	}
	playlist, err := s.playlistByID(context.Background(), "p")
	if err != nil || playlist.Name != "After" || !playlist.IsLiked || strings.Join(playlist.TrackIDs, ",") != "track_a,track_b" {
		t.Fatalf("playlist=%+v error=%v", playlist, err)
	}
	r = httptest.NewRequest(http.MethodGet, "/api/v1/library", nil)
	r.Header.Set("If-None-Match", before.Header().Get("ETag"))
	after := httptest.NewRecorder()
	handler.ServeHTTP(after, r)
	if after.Code != http.StatusOK || before.Header().Get("ETag") == after.Header().Get("ETag") {
		t.Fatalf("library did not invalidate after rename: status=%d", after.Code)
	}
}

func TestPlaylistRenameRejectsMissingOrEmptyNames(t *testing.T) {
	s, _ := testServer(t)
	if err := s.upsertPlaylist(context.Background(), Playlist{ID: "p", Name: "Before", TrackIDs: []string{"track_a"}}); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		path, body string
		status     int
	}{
		{"/api/v1/playlists/missing/name", `{"name":"After"}`, http.StatusNotFound},
		{"/api/v1/playlists/p/name", `{"name":"  "}`, http.StatusBadRequest},
		{"/api/v1/playlists/p/name", `{}`, http.StatusBadRequest},
		{"/api/v1/playlists/p/name", `{"name":"After","track_ids":[]}`, http.StatusBadRequest},
	} {
		w := httptest.NewRecorder()
		s.Handler().ServeHTTP(w, httptest.NewRequest(http.MethodPut, tc.path, strings.NewReader(tc.body)))
		if w.Code != tc.status {
			t.Fatalf("%s %s: status=%d want=%d", tc.path, tc.body, w.Code, tc.status)
		}
	}
	playlist, err := s.playlistByID(context.Background(), "p")
	if err != nil || playlist.Name != "Before" || strings.Join(playlist.TrackIDs, ",") != "track_a" {
		t.Fatalf("invalid rename changed playlist: %+v error=%v", playlist, err)
	}
}
