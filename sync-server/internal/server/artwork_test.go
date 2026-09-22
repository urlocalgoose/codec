package server

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"hash/crc32"
	"image"
	"image/color"
	"image/gif"
	"image/jpeg"
	"image/png"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"
)

func artworkFixture(t *testing.T, format string, shade uint8) []byte {
	t.Helper()
	img := image.NewNRGBA(image.Rect(0, 0, 8, 8))
	for y := range 8 {
		for x := range 8 {
			img.SetNRGBA(x, y, color.NRGBA{R: shade, G: uint8(x * 25), B: uint8(y * 25), A: 180})
		}
	}
	var output bytes.Buffer
	var err error
	if format == "png" {
		err = png.Encode(&output, img)
	} else if format == "gif" {
		err = gif.Encode(&output, img, nil)
	} else {
		err = jpeg.Encode(&output, img, &jpeg.Options{Quality: 95})
	}
	if err != nil {
		t.Fatal(err)
	}
	return output.Bytes()
}

func artworkRequest(handler http.Handler, method, path string, body []byte, headers map[string]string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, bytes.NewReader(body))
	for key, value := range headers {
		r.Header.Set(key, value)
	}
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	return w
}

func artworkEntities(t *testing.T, s *Server) []string {
	t.Helper()
	if err := s.upsertTrack(context.Background(), Track{Fingerprint: "cover-track", Title: "Existing song"}); err != nil {
		t.Fatal(err)
	}
	if err := s.upsertPlaylist(context.Background(), Playlist{ID: "cover-playlist", Name: "Existing playlist", TrackIDs: []string{"track_cover-track"}}); err != nil {
		t.Fatal(err)
	}
	return []string{"/api/v1/tracks/cover-track/artwork", "/api/v1/playlists/cover-playlist/artwork"}
}

func TestArtworkOriginalBytesAndActualMIME(t *testing.T) {
	s, _ := testServer(t)
	handler := s.Handler()
	for _, path := range artworkEntities(t, s) {
		for _, format := range []string{"jpeg", "png"} {
			for _, declared := range []string{"", "image/jpeg", "application/octet-stream"} {
				t.Run(path+"/"+format+"/"+declared, func(t *testing.T) {
					original := artworkFixture(t, format, 91)
					put := artworkRequest(handler, "PUT", path, original, map[string]string{"Content-Type": declared})
					if put.Code != http.StatusNoContent {
						t.Fatalf("upload status %d: %s", put.Code, put.Body)
					}
					var tag string
					for _, method := range []string{"GET", "HEAD"} {
						got := artworkRequest(handler, method, path, nil, nil)
						if got.Code != http.StatusOK || got.Header().Get("Content-Type") != "image/"+format {
							t.Fatalf("%s response: %d %v", method, got.Code, got.Header())
						}
						if got.Header().Get("Content-Length") != strconv.Itoa(len(original)) || got.Header().Get("X-Content-Type-Options") != "nosniff" || got.Header().Get("Cache-Control") != "private, no-cache" {
							t.Fatalf("media headers: %v", got.Header())
						}
						if method == "GET" && !bytes.Equal(got.Body.Bytes(), original) {
							t.Fatal("cover bytes changed")
						}
						if method == "HEAD" && got.Body.Len() != 0 {
							t.Fatal("HEAD sent a body")
						}
						tag = got.Header().Get("ETag")
					}
					if tag == "" || artworkRequest(handler, "GET", path, nil, map[string]string{"If-None-Match": tag}).Code != http.StatusNotModified {
						t.Fatal("unchanged artwork did not revalidate")
					}
				})
			}
		}
	}
}

func artworkPNGDimensions(data []byte, width, height uint32) []byte {
	result := bytes.Clone(data)
	binary.BigEndian.PutUint32(result[16:20], width)
	binary.BigEndian.PutUint32(result[20:24], height)
	binary.BigEndian.PutUint32(result[29:33], crc32.ChecksumIEEE(result[12:29]))
	return result
}

func TestArtworkRejectsInvalidUploadsWithoutReplacingCovers(t *testing.T) {
	s, _ := testServer(t)
	handler := s.Handler()
	valid := artworkFixture(t, "png", 100)
	cases := []struct {
		name   string
		data   []byte
		header string
		status int
	}{
		{"empty", nil, "image/jpeg", 400},
		{"html", []byte("<!doctype html><script>alert(1)</script>"), "image/jpeg", 400},
		{"unsupported_gif_upload", artworkFixture(t, "gif", 22), "image/gif", 400},
		{"truncated_pixels", valid[:len(valid)-12], "image/png", 400},
		{"malformed_content_type", valid, ";broken", 400},
		{"too_many_bytes", make([]byte, maxImageBytes+1), "image/png", 413},
		{"too_wide", artworkPNGDimensions(valid, 8193, 1), "image/png", 413},
		{"too_many_pixels", artworkPNGDimensions(valid, 5000, 5000), "image/png", 413},
	}
	for _, path := range artworkEntities(t, s) {
		if got := artworkRequest(handler, "PUT", path, valid, nil); got.Code != 204 {
			t.Fatalf("setup: %s", got.Body)
		}
		for _, tc := range cases {
			t.Run(path+"/"+tc.name, func(t *testing.T) {
				version := s.libraryVersion.Load()
				got := artworkRequest(handler, "PUT", path, tc.data, map[string]string{"Content-Type": tc.header})
				if got.Code != tc.status {
					t.Fatalf("status=%d want=%d body=%s", got.Code, tc.status, got.Body)
				}
				if s.libraryVersion.Load() != version || !bytes.Equal(artworkRequest(handler, "GET", path, nil, nil).Body.Bytes(), valid) {
					t.Fatal("rejected upload changed the cover or library version")
				}
			})
		}
	}
	leftovers, err := filepath.Glob(filepath.Join(s.dataDir, "artwork", ".artwork-*"))
	if err != nil || len(leftovers) != 0 {
		t.Fatalf("staging files leaked: %v %v", leftovers, err)
	}
}

type interruptedArtworkReader struct{}

func (interruptedArtworkReader) Read([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }

func TestArtworkInterruptedUploadPreservesExistingCover(t *testing.T) {
	s, _ := testServer(t)
	handler := s.Handler()
	valid := artworkFixture(t, "jpeg", 110)
	for _, path := range artworkEntities(t, s) {
		if got := artworkRequest(handler, "PUT", path, valid, nil); got.Code != 204 {
			t.Fatal(got.Body)
		}
		r := httptest.NewRequest("PUT", path, nil)
		r.Body = io.NopCloser(io.MultiReader(bytes.NewReader(valid[:20]), interruptedArtworkReader{}))
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != 400 || !bytes.Equal(artworkRequest(handler, "GET", path, nil, nil).Body.Bytes(), valid) {
			t.Fatalf("interrupted upload replaced cover: %d", w.Code)
		}
	}
}

func TestArtworkConditionalCreateIsAtomic(t *testing.T) {
	s, _ := testServer(t)
	handler := s.Handler()
	for _, path := range artworkEntities(t, s) {
		const count = 12
		originals := make([][]byte, count)
		responses := make([]*httptest.ResponseRecorder, count)
		var jobs sync.WaitGroup
		start := make(chan struct{})
		for i := range count {
			originals[i] = artworkFixture(t, "png", uint8(i*20))
			jobs.Go(func() {
				<-start
				responses[i] = artworkRequest(handler, "PUT", path, originals[i], map[string]string{"If-None-Match": "*"})
			})
		}
		close(start)
		jobs.Wait()
		winner := -1
		for i, response := range responses {
			switch response.Code {
			case 204:
				if winner != -1 {
					t.Fatal("two conditional uploads both replaced the cover")
				}
				winner = i
			case 412:
			default:
				t.Fatalf("conditional status %d: %s", response.Code, response.Body)
			}
		}
		if winner == -1 || !bytes.Equal(artworkRequest(handler, "GET", path, nil, nil).Body.Bytes(), originals[winner]) {
			t.Fatal("stored cover does not match the sole successful upload")
		}
		version := s.libraryVersion.Load()
		if got := artworkRequest(handler, "PUT", path, originals[winner], map[string]string{"If-None-Match": "*"}); got.Code != 412 || s.libraryVersion.Load() != version {
			t.Fatal("retry did not preserve existing artwork")
		}
		// Ordinary legacy PUT still intentionally replaces the existing cover.
		replacement := artworkFixture(t, "jpeg", 57)
		if got := artworkRequest(handler, "PUT", path, replacement, nil); got.Code != 204 || !bytes.Equal(artworkRequest(handler, "GET", path, nil, nil).Body.Bytes(), replacement) {
			t.Fatal("legacy replacement PUT stopped working")
		}
	}
}

func TestArtworkVersionsSurviveMetadataRenameAndRestart(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	paths := artworkEntities(t, s)
	cover := artworkFixture(t, "jpeg", 19)
	for _, path := range paths {
		if got := artworkRequest(s.Handler(), "PUT", path, cover, nil); got.Code != 204 {
			t.Fatal(got.Body)
		}
	}
	urls := func() [2]string {
		snapshot, err := s.snapshot(context.Background(), "https://codec.test")
		if err != nil {
			t.Fatal(err)
		}
		var result [2]string
		result[0] = *snapshot.Library.Tracks[0].ArtworkURL
		for _, playlist := range snapshot.Library.Playlists {
			if playlist.ID == "cover-playlist" {
				result[1] = *playlist.ArtworkURL
			}
		}
		for _, value := range result {
			parsed, err := url.Parse(value)
			if err != nil || parsed.Query().Get("v") == "" {
				t.Fatalf("unversioned artwork URL: %q", value)
			}
		}
		return result
	}
	before := urls()
	if err := s.renamePlaylist(context.Background(), "cover-playlist", "Renamed"); err != nil {
		t.Fatal(err)
	}
	if err := s.upsertTrack(context.Background(), Track{Fingerprint: "cover-track", Title: "Edited metadata without art"}); err != nil {
		t.Fatal(err)
	}
	if err := s.upsertPlaylist(context.Background(), Playlist{ID: "cover-playlist", Name: "Renamed", TrackIDs: []string{}}); err != nil {
		t.Fatal(err)
	}
	if got := urls(); got != before {
		t.Fatalf("metadata-only updates changed cover URLs: %v %v", before, got)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got := urls(); got != before {
		t.Fatalf("restart changed cover URLs: %v %v", before, got)
	}
	for _, path := range paths {
		if !bytes.Equal(artworkRequest(s.Handler(), "GET", path, nil, nil).Body.Bytes(), cover) {
			t.Fatal("cover lost after rename/restart")
		}
	}
	// A restored future timestamp must still get a new version on replacement.
	stamp := time.Now().Add(time.Hour)
	for _, path := range []string{s.artworkPath("cover-track"), s.playlistArtworkPath("cover-playlist")} {
		if err := os.Chtimes(path, stamp, stamp); err != nil {
			t.Fatal(err)
		}
	}
	before = urls()
	for _, path := range paths {
		if got := artworkRequest(s.Handler(), "PUT", path, artworkFixture(t, "png", 220), nil); got.Code != 204 {
			t.Fatal(got.Body)
		}
	}
	after := urls()
	for i := range before {
		if after[i] == before[i] {
			t.Fatal("replacement cover did not change cache version")
		}
	}
}

func TestArtworkTrackLegacyPathAndMissingCover(t *testing.T) {
	s, _ := testServer(t)
	handler := s.Handler()
	paths := artworkEntities(t, s)
	cover := artworkFixture(t, "png", 38)
	if got := artworkRequest(handler, "PUT", paths[0], cover, nil); got.Code != 204 {
		t.Fatal(got.Body)
	}
	legacy := filepath.Join(t.TempDir(), "old-cover.jpg")
	if err := os.Rename(s.artworkPath("cover-track"), legacy); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec(`UPDATE tracks SET artwork_path = ? WHERE fingerprint = ?`, legacy, "cover-track"); err != nil {
		t.Fatal(err)
	}
	if got := artworkRequest(handler, "PUT", paths[0], artworkFixture(t, "jpeg", 91), map[string]string{"If-None-Match": "*"}); got.Code != 412 {
		t.Fatalf("legacy cover was not protected: %d", got.Code)
	}
	if err := os.Rename(legacy, s.artworkPath("cover-track")); err != nil {
		t.Fatal(err)
	}
	tracks, err := s.tracks(context.Background(), "https://codec.test")
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := url.Parse(*tracks[0].ArtworkURL)
	if err != nil || parsed.Query().Get("v") == "" || !bytes.Equal(artworkRequest(handler, "GET", paths[0], nil, nil).Body.Bytes(), cover) {
		t.Fatal("canonical fallback lost moved cover/version")
	}
	for _, method := range []string{"GET", "HEAD"} {
		if got := artworkRequest(handler, method, paths[1], nil, nil); got.Code != 404 {
			t.Fatalf("missing playlist cover: %d", got.Code)
		}
	}
	if got := artworkRequest(handler, "PUT", "/api/v1/tracks/%20/artwork", cover, nil); got.Code != 400 {
		t.Fatalf("empty fingerprint was accepted: %d", got.Code)
	}
	if _, err := os.Stat(legacy); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("test legacy file unexpectedly reappeared")
	}
}

func TestArtworkLegacyEmbeddedGIFRemainsReadable(t *testing.T) {
	s, _ := testServer(t)
	paths := artworkEntities(t, s)
	cover := artworkFixture(t, "gif", 99)
	files := []string{s.artworkPath("cover-track"), s.playlistArtworkPath("cover-playlist")}
	for _, path := range files {
		if err := os.WriteFile(path, cover, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.attachMediaPath(context.Background(), "cover-track", "artwork_path", files[0], 0); err != nil {
		t.Fatal(err)
	}
	for _, path := range paths {
		for _, method := range []string{"GET", "HEAD"} {
			got := artworkRequest(s.Handler(), method, path, nil, nil)
			if got.Code != 200 || got.Header().Get("Content-Type") != "image/gif" || got.Header().Get("X-Content-Type-Options") != "nosniff" {
				t.Fatalf("legacy GIF response: %d %v", got.Code, got.Header())
			}
			if method == "GET" && !bytes.Equal(got.Body.Bytes(), cover) {
				t.Fatal("legacy GIF changed")
			}
			if method == "HEAD" && got.Body.Len() != 0 {
				t.Fatal("HEAD returned image bytes")
			}
		}
	}
}
