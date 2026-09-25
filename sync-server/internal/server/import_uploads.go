package server

// An archive stays on disk while small, retryable requests assemble it. The
// existing importer sees exactly the original ZIP, only after all bytes arrive.
import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	importChunkBytes     int64 = 8 << 20
	maxImportUploads           = 4
	importUploadLifetime       = 24 * time.Hour
)

type importUpload struct {
	mu        sync.Mutex
	id        string
	path      string
	size      int64
	offset    int64
	jobID     string
	closed    bool
	touchedAt time.Time
}

type importUploadStatus struct {
	ID        string `json:"id"`
	Offset    int64  `json:"offset"`
	Size      int64  `json:"size"`
	ChunkSize int64  `json:"chunk_size"`
	JobID     string `json:"job_id,omitempty"`
}

func (upload *importUpload) status() importUploadStatus {
	return importUploadStatus{upload.id, upload.offset, upload.size, importChunkBytes, upload.jobID}
}

func validImportUploadID(id string) bool {
	if len(id) != len("upload_")+32 || !strings.HasPrefix(id, "upload_") {
		return false
	}
	_, err := hex.DecodeString(strings.TrimPrefix(id, "upload_"))
	return err == nil
}

func (s *Server) initializeImportUploads() error {
	dir := filepath.Join(s.dataDir, "imports", "uploads")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	// In-memory upload sessions cannot be resumed after a process restart.
	// Remove only files owned by this protocol, never arbitrary import files.
	for _, entry := range entries {
		if !entry.IsDir() && strings.HasSuffix(entry.Name(), ".part") && validImportUploadID(strings.TrimSuffix(entry.Name(), ".part")) {
			if err := os.Remove(filepath.Join(dir, entry.Name())); err != nil {
				return err
			}
		}
	}
	s.importUploads = make(map[string]*importUpload)
	s.importUploadStop = make(chan struct{})
	s.importUploadDone = make(chan struct{})
	go func() {
		defer close(s.importUploadDone)
		ticker := time.NewTicker(time.Hour)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				s.expireImportUploads()
			case <-s.importUploadStop:
				return
			}
		}
	}()
	return nil
}

func (s *Server) expireImportUploads() {
	s.importUploadsMu.Lock()
	defer s.importUploadsMu.Unlock()
	for id, upload := range s.importUploads {
		// Never wait on a slow request while holding the global map lock.
		if !upload.mu.TryLock() {
			continue
		}
		if s.now().Sub(upload.touchedAt) >= importUploadLifetime {
			upload.closed = true
			if upload.jobID == "" {
				_ = os.Remove(upload.path)
			}
			delete(s.importUploads, id)
		}
		upload.mu.Unlock()
	}
}

// A successful lookup returns with this upload locked. Paths always come from
// server-generated IDs stored in memory, never from a request's path value.
func (s *Server) lockImportUpload(w http.ResponseWriter, r *http.Request) *importUpload {
	id := r.PathValue("id")
	if !validImportUploadID(id) {
		writeError(w, http.StatusNotFound, errors.New("unknown upload"))
		return nil
	}
	s.importUploadsMu.Lock()
	upload := s.importUploads[id]
	s.importUploadsMu.Unlock()
	if upload == nil {
		writeError(w, http.StatusNotFound, errors.New("unknown or expired upload; select the ZIP again"))
		return nil
	}
	upload.mu.Lock()
	if upload.closed || s.now().Sub(upload.touchedAt) >= importUploadLifetime {
		upload.closed = true
		if upload.jobID == "" {
			_ = os.Remove(upload.path)
		}
		upload.mu.Unlock()
		writeError(w, http.StatusNotFound, errors.New("unknown or expired upload; select the ZIP again"))
		return nil
	}
	return upload
}

func (s *Server) handleCreateImportUpload(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 1024)
	defer r.Body.Close()
	var request struct {
		Size int64 `json:"size"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil || request.Size <= 0 || request.Size > maxBundleBytes {
		writeError(w, http.StatusBadRequest, errors.New("upload size must be between 1 byte and 64 GiB"))
		return
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		writeError(w, http.StatusBadRequest, errors.New("upload request must contain one JSON object"))
		return
	}
	s.expireImportUploads()
	s.importUploadsMu.Lock()
	defer s.importUploadsMu.Unlock()
	active := 0
	for _, upload := range s.importUploads {
		// A request may be writing; that is necessarily still an active upload.
		if !upload.mu.TryLock() {
			active++
			continue
		}
		if !upload.closed && upload.jobID == "" {
			active++
		}
		upload.mu.Unlock()
	}
	if active >= maxImportUploads {
		w.Header().Set("Retry-After", "30")
		writeError(w, http.StatusTooManyRequests, errors.New("four uploads are already active; finish or cancel one first"))
		return
	}
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		writeError(w, http.StatusInternalServerError, errors.New("could not create upload"))
		return
	}
	id := "upload_" + hex.EncodeToString(raw)
	path := filepath.Join(s.dataDir, "imports", "uploads", id+".part")
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		writeError(w, http.StatusInternalServerError, errors.New("could not create upload file"))
		return
	}
	if err := file.Close(); err != nil {
		_ = os.Remove(path)
		writeError(w, http.StatusInternalServerError, errors.New("could not create upload file"))
		return
	}
	upload := &importUpload{id: id, path: path, size: request.Size, touchedAt: s.now()}
	s.importUploads[id] = upload
	writeJSON(w, http.StatusCreated, upload.status())
}

func (s *Server) handleGetImportUpload(w http.ResponseWriter, r *http.Request) {
	upload := s.lockImportUpload(w, r)
	if upload == nil {
		return
	}
	defer upload.mu.Unlock()
	upload.touchedAt = s.now()
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, upload.status())
}

func (s *Server) handlePutImportUpload(w http.ResponseWriter, r *http.Request) {
	defer r.Body.Close()
	upload := s.lockImportUpload(w, r)
	if upload == nil {
		return
	}
	defer upload.mu.Unlock()
	offset, err := strconv.ParseInt(r.URL.Query().Get("offset"), 10, 64)
	if err != nil || offset < 0 {
		writeError(w, http.StatusBadRequest, errors.New("a nonnegative upload offset is required"))
		return
	}
	if upload.jobID != "" || offset != upload.offset {
		writeJSON(w, http.StatusConflict, map[string]any{"error": "upload offset changed; check upload status before retrying", "offset": upload.offset})
		return
	}
	limit := min(importChunkBytes, upload.size-upload.offset)
	if limit == 0 || r.ContentLength > limit {
		writeError(w, http.StatusRequestEntityTooLarge, errors.New("chunk exceeds the upload size or 8 MiB chunk limit"))
		return
	}
	file, err := os.OpenFile(upload.path, os.O_WRONLY, 0)
	if err != nil {
		writeError(w, http.StatusInternalServerError, errors.New("could not open upload file"))
		return
	}
	if _, err := file.Seek(upload.offset, io.SeekStart); err != nil {
		file.Close()
		writeError(w, http.StatusInternalServerError, errors.New("could not continue upload"))
		return
	}
	written, copyErr := io.Copy(file, io.LimitReader(r.Body, limit+1))
	closeErr := file.Close()
	if copyErr != nil || closeErr != nil || written <= 0 || written > limit || (r.ContentLength >= 0 && written != r.ContentLength) {
		// A dropped connection must not advance progress or leave partial bytes.
		if err := os.Truncate(upload.path, upload.offset); err != nil {
			upload.closed = true
			_ = os.Remove(upload.path)
			writeError(w, http.StatusInternalServerError, errors.New("upload could not be recovered; select the ZIP again"))
			return
		}
		status := http.StatusBadRequest
		if written > limit {
			status = http.StatusRequestEntityTooLarge
		}
		if closeErr != nil {
			status = http.StatusInternalServerError
		}
		writeError(w, status, errors.New("chunk was not saved; retry from the last confirmed offset"))
		return
	}
	upload.offset += written
	upload.touchedAt = s.now()
	writeJSON(w, http.StatusOK, upload.status())
}

func (s *Server) handleCompleteImportUpload(w http.ResponseWriter, r *http.Request) {
	upload := s.lockImportUpload(w, r)
	if upload == nil {
		return
	}
	defer upload.mu.Unlock()
	if upload.jobID == "" {
		if upload.offset != upload.size {
			writeError(w, http.StatusConflict, errors.New("upload is not complete"))
			return
		}
		info, err := os.Stat(upload.path)
		if err != nil || info.Size() != upload.size {
			writeError(w, http.StatusConflict, errors.New("upload file is incomplete; select the ZIP again"))
			return
		}
		upload.jobID = newImportJobID()
		s.startImportJob(upload.jobID, upload.path)
	}
	upload.touchedAt = s.now()
	writeJSON(w, http.StatusAccepted, map[string]string{"id": upload.jobID})
}

func (s *Server) handleDeleteImportUpload(w http.ResponseWriter, r *http.Request) {
	upload := s.lockImportUpload(w, r)
	if upload == nil {
		return
	}
	defer upload.mu.Unlock()
	if upload.jobID != "" {
		writeError(w, http.StatusConflict, errors.New("upload has already started importing"))
		return
	}
	if err := os.Remove(upload.path); err != nil && !errors.Is(err, os.ErrNotExist) {
		writeError(w, http.StatusInternalServerError, errors.New("could not remove upload file"))
		return
	}
	upload.closed = true
	w.WriteHeader(http.StatusNoContent)
}
