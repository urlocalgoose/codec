package server

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func uploadRequest(t *testing.T, h http.Handler, method, path string, body io.Reader, status int) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest(method, path, body))
	if w.Code != status {
		t.Fatalf("%s %s: %d %s, want %d", method, path, w.Code, w.Body.String(), status)
	}
	return w
}

func createUpload(t *testing.T, s *Server, size int64) importUploadStatus {
	t.Helper()
	w := uploadRequest(t, s.Handler(), "POST", "/api/v1/import/uploads", strings.NewReader(fmt.Sprintf(`{"size":%d}`, size)), 201)
	var result importUploadStatus
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if !validImportUploadID(result.ID) || result.Size != size || result.ChunkSize != importChunkBytes || result.Offset != 0 {
		t.Fatalf("bad status: %+v", result)
	}
	return result
}

func waitImport(t *testing.T, s *Server, id string) ImportJob {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		w := uploadRequest(t, s.Handler(), "GET", "/api/v1/import/jobs/"+id, nil, 200)
		var job ImportJob
		if err := json.Unmarshal(w.Body.Bytes(), &job); err != nil {
			t.Fatal(err)
		}
		if job.State != "running" {
			return job
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("import did not finish")
	return ImportJob{}
}

func TestChunkUploadAssemblesOriginalZIPAndCompletesOnce(t *testing.T) {
	s, _ := testServer(t)
	cover := artworkFixture(t, "png", 88)
	audio := bytes.Repeat([]byte("original music bytes"), 500000)
	manifest := map[string]any{"schema": "loud.import.v1", "tracks": []any{map[string]any{
		"fingerprint": "chunk-fixture", "file": "audio/song.mp3", "title": "Chunk song", "liked": true,
		"artwork": bundleDescriptor("cover.png", cover, "image/png"),
	}}, "playlists": []any{map[string]any{"name": "Chunk collection", "tracks": []any{"chunk-fixture"}, "artwork": bundleDescriptor("cover.png", cover, "image/png")}}}
	var archive bytes.Buffer
	zw := zip.NewWriter(&archive)
	for name, data := range map[string][]byte{"loud-import.json": bundleJSON(t, manifest), "audio/song.mp3": audio, "cover.png": cover} {
		entry, err := zw.CreateHeader(&zip.FileHeader{Name: name, Method: zip.Store})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := entry.Write(data); err != nil {
			t.Fatal(err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	upload := createUpload(t, s, int64(archive.Len()))
	url := "/api/v1/import/uploads/" + upload.ID
	for offset := 0; offset < archive.Len(); {
		end := min(offset+int(importChunkBytes), archive.Len())
		w := uploadRequest(t, s.Handler(), "PUT", fmt.Sprintf("%s?offset=%d", url, offset), bytes.NewReader(archive.Bytes()[offset:end]), 200)
		var status importUploadStatus
		json.Unmarshal(w.Body.Bytes(), &status)
		if status.Offset != int64(end) {
			t.Fatalf("offset %+v", status)
		}
		offset = end
	}
	if tracks := bundleLibrary(t, s).Tracks; len(tracks) != 0 {
		t.Fatal("upload mutated library before completion")
	}
	assembled, err := os.ReadFile(s.importUploads[upload.ID].path)
	if err != nil || !bytes.Equal(assembled, archive.Bytes()) {
		t.Fatal("assembled ZIP changed")
	}
	w := uploadRequest(t, s.Handler(), "POST", url+"/complete", nil, 202)
	var accepted struct {
		ID string `json:"id"`
	}
	json.Unmarshal(w.Body.Bytes(), &accepted)
	if again := uploadRequest(t, s.Handler(), "POST", url+"/complete", nil, 202); again.Body.String() != w.Body.String() {
		t.Fatal("completion started twice")
	}
	uploadRequest(t, s.Handler(), "DELETE", url, nil, 409)
	status := uploadRequest(t, s.Handler(), "GET", url, nil, 200)
	if !strings.Contains(status.Body.String(), accepted.ID) {
		t.Fatal("completed status lost job id")
	}
	job := waitImport(t, s, accepted.ID)
	if job.State != "done" || job.Added != 1 || job.PlaylistAdds != 1 || job.Liked != 1 || job.ArtworkImported != 2 {
		t.Fatalf("job %+v", job)
	}
	if got := artworkRequest(s.Handler(), "GET", "/api/v1/tracks/chunk-fixture/audio", nil, nil); !bytes.Equal(got.Body.Bytes(), audio) {
		t.Fatal("audio bytes changed")
	}
	if got := artworkRequest(s.Handler(), "GET", "/api/v1/tracks/chunk-fixture/artwork", nil, nil); !bytes.Equal(got.Body.Bytes(), cover) {
		t.Fatal("cover bytes changed")
	}
}

type brokenChunkReader struct{ emitted bool }

func (r *brokenChunkReader) Read(p []byte) (int, error) {
	if r.emitted {
		return 0, errors.New("connection interrupted")
	}
	r.emitted = true
	return copy(p, "partial"), nil
}

func TestChunkUploadRollsBackFailedAndOversizedChunks(t *testing.T) {
	s, _ := testServer(t)
	upload := createUpload(t, s, 12)
	url := "/api/v1/import/uploads/" + upload.ID
	uploadRequest(t, s.Handler(), "PUT", url+"?offset=0", strings.NewReader("first"), 200)
	uploadRequest(t, s.Handler(), "PUT", url+"?offset=5", &brokenChunkReader{}, 400)
	// Unknown content length exercises the bounded streaming reader, not just
	// the Content-Length preflight check.
	w := httptest.NewRecorder()
	r := httptest.NewRequest("PUT", url+"?offset=5", strings.NewReader("too many bytes"))
	r.ContentLength = -1
	s.Handler().ServeHTTP(w, r)
	if w.Code != 413 {
		t.Fatalf("oversize status %d", w.Code)
	}
	data, err := os.ReadFile(s.importUploads[upload.ID].path)
	if err != nil || string(data) != "first" {
		t.Fatalf("partial write retained: %q %v", data, err)
	}
	status := uploadRequest(t, s.Handler(), "GET", url, nil, 200)
	var progress importUploadStatus
	json.Unmarshal(status.Body.Bytes(), &progress)
	if progress.Offset != 5 {
		t.Fatalf("offset advanced on failure: %+v", progress)
	}
	uploadRequest(t, s.Handler(), "PUT", url+"?offset=0", strings.NewReader("first"), 409)
	uploadRequest(t, s.Handler(), "PUT", url+"?offset=-1", strings.NewReader("x"), 400)
	uploadRequest(t, s.Handler(), "POST", url+"/complete", nil, 409)
	uploadRequest(t, s.Handler(), "PUT", url+"?offset=5", strings.NewReader("retryOK"), 200)
	data, _ = os.ReadFile(s.importUploads[upload.ID].path)
	if string(data) != "firstretryOK" {
		t.Fatalf("retry corrupted upload: %q", data)
	}
	uploadRequest(t, s.Handler(), "DELETE", url, nil, 204)
	if _, err := os.Stat(s.importUploads[upload.ID].path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("cancel left file: %v", err)
	}
	uploadRequest(t, s.Handler(), "GET", url, nil, 404)
}

func TestChunkUploadLimitsExpiryAndRestartCleanup(t *testing.T) {
	s, _ := testServer(t)
	for _, body := range []string{`{"size":0}`, `{"size":-1}`, `{"size":68719476737}`, `{"size":1.5}`, `{"size":1} {}`, `{"size":1,"path":"../escape"}`} {
		uploadRequest(t, s.Handler(), "POST", "/api/v1/import/uploads", strings.NewReader(body), 400)
	}
	var uploads []importUploadStatus
	for range maxImportUploads {
		uploads = append(uploads, createUpload(t, s, 100))
	}
	uploadRequest(t, s.Handler(), "POST", "/api/v1/import/uploads", strings.NewReader(`{"size":100}`), 429)
	for _, upload := range uploads {
		s.importUploads[upload.ID].touchedAt = s.now().Add(-importUploadLifetime)
	}
	s.expireImportUploads()
	for _, upload := range uploads {
		uploadRequest(t, s.Handler(), "GET", "/api/v1/import/uploads/"+upload.ID, nil, 404)
	}
	createUpload(t, s, 1)
	uploadRequest(t, s.Handler(), "GET", "/api/v1/import/uploads/upload_invalid", nil, 404)

	dir := t.TempDir()
	owned := "upload_" + strings.Repeat("a", 32) + ".part"
	path := filepath.Join(dir, "imports", "uploads")
	os.MkdirAll(path, 0700)
	for _, name := range []string{owned, "keep.txt", "upload_unknown.part"} {
		if err := os.WriteFile(filepath.Join(path, name), []byte("keep"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	reopened, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	if _, err := os.Stat(filepath.Join(path, owned)); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("orphan upload remained after restart")
	}
	for _, name := range []string{"keep.txt", "upload_unknown.part"} {
		if _, err := os.Stat(filepath.Join(path, name)); err != nil {
			t.Fatal("cleanup touched unrelated file")
		}
	}
}

func TestChunkUploadSerializesConcurrentOffsets(t *testing.T) {
	s, _ := testServer(t)
	upload := createUpload(t, s, 10)
	url := "/api/v1/import/uploads/" + upload.ID + "?offset=0"
	codes := make(chan int, 2)
	var wg sync.WaitGroup
	for range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			w := httptest.NewRecorder()
			s.Handler().ServeHTTP(w, httptest.NewRequest("PUT", url, strings.NewReader("first")))
			codes <- w.Code
		}()
	}
	wg.Wait()
	close(codes)
	counts := map[int]int{}
	for code := range codes {
		counts[code]++
	}
	if counts[200] != 1 || counts[409] != 1 {
		t.Fatalf("concurrent writes: %+v", counts)
	}
	data, _ := os.ReadFile(s.importUploads[upload.ID].path)
	if string(data) != "first" {
		t.Fatal("duplicate bytes appended")
	}
}

func TestChunkUploadEndpointsRequireOwnerAuthorization(t *testing.T) {
	s, _ := testServer(t)
	upload := createUpload(t, s, 100)
	guest, err := s.createAuxSession(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	h := s.HandlerWithOptions(HandlerOptions{AuthToken: "owner-test-token"})
	for _, endpoint := range [][2]string{{"POST", "/api/v1/import/uploads"}, {"GET", "/api/v1/import/uploads/" + upload.ID}, {"PUT", "/api/v1/import/uploads/" + upload.ID + "?offset=0"}, {"POST", "/api/v1/import/uploads/" + upload.ID + "/complete"}, {"DELETE", "/api/v1/import/uploads/" + upload.ID}} {
		for _, token := range []string{"", guest.GuestToken} {
			r := httptest.NewRequest(endpoint[0], endpoint[1], strings.NewReader(`{"size":10}`))
			if token != "" {
				r.Header.Set("Authorization", "Bearer "+token)
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			want := 401
			if token != "" {
				want = 403
			}
			if w.Code != want {
				t.Fatalf("%s %s status %d", endpoint[0], endpoint[1], w.Code)
			}
		}
	}
	r := httptest.NewRequest("GET", "/api/v1/import/uploads/"+upload.ID, nil)
	r.Header.Set("Authorization", "Bearer owner-test-token")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatal("owner cannot resume")
	}
}
