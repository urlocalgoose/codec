// Request/response plumbing, middleware, and static web app serving.
package server

import (
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func writeRequestBody(path string, body io.ReadCloser, maxBytes int64) (int64, error) {
	defer body.Close()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return 0, err
	}
	temp := path + ".tmp"
	file, err := os.Create(temp)
	if err != nil {
		return 0, err
	}
	written, copyErr := io.Copy(file, io.LimitReader(body, maxBytes+1))
	closeErr := file.Close()
	if copyErr != nil {
		_ = os.Remove(temp)
		return 0, copyErr
	}
	if closeErr != nil {
		_ = os.Remove(temp)
		return 0, closeErr
	}
	if written > maxBytes {
		_ = os.Remove(temp)
		return 0, fmt.Errorf("body is larger than %d bytes", maxBytes)
	}
	if err := os.Rename(temp, path); err != nil {
		_ = os.Remove(temp)
		return 0, err
	}
	return written, nil
}

func serveMedia(w http.ResponseWriter, r *http.Request, path, contentType string) {
	file, err := os.Open(path)
	if err != nil {
		writeError(w, http.StatusNotFound, err)
		return
	}
	defer file.Close()
	stat, err := file.Stat()
	if err != nil {
		writeError(w, http.StatusNotFound, err)
		return
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Accept-Ranges", "bytes")
	http.ServeContent(w, r, stat.Name(), stat.ModTime(), file)
}

func serveWebApp(webDir string, api http.Handler) http.Handler {
	indexPath := filepath.Join(webDir, "index.html")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" || strings.HasPrefix(r.URL.Path, "/api/") {
			api.ServeHTTP(w, r)
			return
		}

		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			writeError(w, http.StatusMethodNotAllowed, fmt.Errorf("method not allowed"))
			return
		}

		cleanPath := filepath.Clean("/" + r.URL.Path)
		filePath := filepath.Join(webDir, strings.TrimPrefix(cleanPath, "/"))
		rel, err := filepath.Rel(webDir, filePath)
		if err != nil || strings.HasPrefix(rel, "..") {
			writeError(w, http.StatusBadRequest, fmt.Errorf("invalid web path"))
			return
		}

		if stat, err := os.Stat(filePath); err == nil && !stat.IsDir() {
			http.ServeFile(w, r, filePath)
			return
		}

		if stat, err := os.Stat(indexPath); err == nil && !stat.IsDir() {
			http.ServeFile(w, r, indexPath)
			return
		}

		writeError(w, http.StatusNotFound, fmt.Errorf("web app is not built"))
	})
}

func decodeJSON(r *http.Request, target any) error {
	defer r.Body.Close()
	decoder := json.NewDecoder(io.LimitReader(r.Body, maxJSONBytes))
	decoder.DisallowUnknownFields()
	return decoder.Decode(target)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeSSE(w io.Writer, eventType string, value any) {
	raw, err := json.Marshal(value)
	if err != nil {
		return
	}
	_, _ = fmt.Fprintf(w, "event: %s\n", eventType)
	_, _ = fmt.Fprintf(w, "data: %s\n\n", raw)
}

func writeError(w http.ResponseWriter, status int, err error) {
	writeJSON(w, status, map[string]string{"error": err.Error()})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
	bytes  int
}

func (recorder *statusRecorder) WriteHeader(status int) {
	recorder.status = status
	recorder.ResponseWriter.WriteHeader(status)
}

func (recorder *statusRecorder) Write(body []byte) (int, error) {
	if recorder.status == 0 {
		recorder.status = http.StatusOK
	}
	written, err := recorder.ResponseWriter.Write(body)
	recorder.bytes += written
	return written, err
}

func (recorder *statusRecorder) Flush() {
	if recorder.status == 0 {
		recorder.status = http.StatusOK
	}
	if flusher, ok := recorder.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		recorder := &statusRecorder{ResponseWriter: w}
		next.ServeHTTP(recorder, r)
		status := recorder.status
		if status == 0 {
			status = http.StatusOK
		}
		fmt.Fprintf(
			os.Stdout,
			"%s %s %s -> %d %dB %s\n",
			start.Format("15:04:05"),
			r.Method,
			r.URL.Path,
			status,
			recorder.bytes,
			time.Since(start).Round(time.Millisecond),
		)
	})
}

func withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, HEAD, POST, PUT, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type, Last-Event-ID, Range")
		w.Header().Set("Access-Control-Expose-Headers", "Content-Length, Content-Range, Accept-Ranges")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func withAuth(next http.Handler, token string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" || authorizedRequest(r, token) {
			next.ServeHTTP(w, r)
			return
		}

		w.Header().Set("WWW-Authenticate", `Basic realm="Loud"`)
		writeError(w, http.StatusUnauthorized, fmt.Errorf("authorization required"))
	})
}

func authorizedRequest(r *http.Request, token string) bool {
	if token == "" {
		return true
	}

	if _, password, ok := r.BasicAuth(); ok && constantTimeString(password, token) {
		return true
	}

	const prefix = "Bearer "
	header := r.Header.Get("Authorization")
	if strings.HasPrefix(header, prefix) && constantTimeString(strings.TrimPrefix(header, prefix), token) {
		return true
	}

	return false
}

func constantTimeString(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

func publicBaseURL(r *http.Request) string {
	proto := r.Header.Get("X-Forwarded-Proto")
	if proto == "" {
		proto = "http"
		if r.TLS != nil {
			proto = "https"
		}
	}
	host := r.Header.Get("X-Forwarded-Host")
	if host == "" {
		host = r.Host
	}
	return proto + "://" + host
}
