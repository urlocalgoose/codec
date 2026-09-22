package server

import (
	"bytes"
	"errors"
	"fmt"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	maxArtworkDimension = 8192
	maxArtworkPixels    = 16 << 20
)

var errArtworkExists = errors.New("artwork already exists")

type artworkRequestError struct {
	status int
	err    error
}

func (e *artworkRequestError) Error() string { return e.err.Error() }

func artworkCreateOnly(r *http.Request) (bool, error) {
	condition := strings.TrimSpace(r.Header.Get("If-None-Match"))
	if condition != "" && condition != "*" {
		return false, &artworkRequestError{http.StatusBadRequest, errors.New("artwork uploads support only If-None-Match: *")}
	}
	return condition == "*", nil
}

// Validate before replacing any existing file. DecodeConfig bounds memory
// before full decoding, which also rejects truncated/corrupt pixel data. The
// original bytes are stored unchanged: no recompression or loss of PNG alpha.
func readArtwork(r *http.Request) ([]byte, error) {
	defer r.Body.Close()
	if header := r.Header.Get("Content-Type"); header != "" {
		if _, _, err := mime.ParseMediaType(header); err != nil {
			return nil, &artworkRequestError{http.StatusBadRequest, err}
		}
	}
	data, err := io.ReadAll(io.LimitReader(r.Body, maxImageBytes+1))
	if err != nil {
		return nil, &artworkRequestError{http.StatusBadRequest, err}
	}
	if len(data) > maxImageBytes {
		return nil, &artworkRequestError{http.StatusRequestEntityTooLarge, fmt.Errorf("artwork exceeds %d bytes", maxImageBytes)}
	}
	config, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || (format != "jpeg" && format != "png") {
		return nil, &artworkRequestError{http.StatusBadRequest, errors.New("artwork must be a valid JPEG or PNG image")}
	}
	if config.Width <= 0 || config.Height <= 0 || config.Width > maxArtworkDimension || config.Height > maxArtworkDimension || int64(config.Width)*int64(config.Height) > maxArtworkPixels {
		return nil, &artworkRequestError{http.StatusRequestEntityTooLarge, errors.New("artwork dimensions exceed the image limit")}
	}
	if _, _, err := image.Decode(bytes.NewReader(data)); err != nil {
		return nil, &artworkRequestError{http.StatusBadRequest, errors.New("artwork image data is incomplete or corrupt")}
	}
	return data, nil
}

func writeArtwork(path string, data []byte, createOnly bool) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	// A distinct staging file also makes simultaneous uploads safe. Never
	// truncate the current cover while a request is still arriving/validating.
	file, err := os.CreateTemp(filepath.Dir(path), ".artwork-*")
	if err != nil {
		return err
	}
	temp := file.Name()
	defer os.Remove(temp)
	if _, err := file.Write(data); err != nil {
		file.Close()
		return err
	}
	if err := file.Chmod(0o644); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	// Keep cache versions distinct even if a filesystem rounds timestamps or
	// a previous cover has a future mtime after being restored from backup.
	if previous, err := os.Stat(path); err == nil {
		if current, err := os.Stat(temp); err == nil && !current.ModTime().After(previous.ModTime()) {
			stamp := previous.ModTime().Add(time.Nanosecond)
			if err := os.Chtimes(temp, stamp, stamp); err != nil {
				return err
			}
		}
	}
	if createOnly {
		// Linking is an atomic create-if-absent, unlike Stat followed by Rename.
		// Temp and destination share a directory/filesystem; existing art wins.
		if err := os.Link(temp, path); err != nil {
			if errors.Is(err, os.ErrExist) {
				return errArtworkExists
			}
			return err
		}
		return nil
	}
	return os.Rename(temp, path)
}

func writeArtworkError(w http.ResponseWriter, err error) {
	var requestError *artworkRequestError
	switch {
	case errors.Is(err, errArtworkExists):
		writeError(w, http.StatusPreconditionFailed, err)
	case errors.As(err, &requestError):
		writeError(w, requestError.status, err)
	default:
		writeError(w, http.StatusInternalServerError, err)
	}
}

func serveArtwork(w http.ResponseWriter, r *http.Request, path string) {
	file, err := os.Open(path)
	if err != nil {
		writeError(w, http.StatusNotFound, err)
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		writeError(w, http.StatusNotFound, errors.New("no artwork"))
		return
	}
	var prefix [512]byte
	n, err := file.Read(prefix[:])
	if err != nil && err != io.EOF {
		writeError(w, http.StatusNotFound, err)
		return
	}
	contentType := http.DetectContentType(prefix[:n])
	switch contentType {
	case "image/jpeg", "image/png", "image/gif", "image/webp":
		// Legacy embedded-art imports can contain GIF/WebP. Keep serving them
		// with their real MIME while new HTTP uploads remain JPEG/PNG-only.
	default:
		writeError(w, http.StatusNotFound, errors.New("artwork is not a supported image"))
		return
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	// Sniff and serve the same open file, so concurrent replacement cannot
	// pair one cover's Content-Type with another cover's bytes.
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Accept-Ranges", "bytes")
	w.Header().Set("Cache-Control", "private, no-cache")
	w.Header().Set("ETag", fmt.Sprintf(`W/"art-%x-%x"`, info.ModTime().UnixNano(), info.Size()))
	http.ServeContent(w, r, info.Name(), info.ModTime(), file)
}
