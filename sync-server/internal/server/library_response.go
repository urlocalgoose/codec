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
	"strconv"
	"strings"
	"sync"
)

const (
	maxLibraryResponseEntries = 4
	maxLibraryResponseBytes   = 16 << 20
)

type libraryResponseKey struct {
	baseURL  string
	snapshot bool
}

type libraryResponse struct {
	key     libraryResponseKey
	version int64
	etag    string
	plain   []byte
	gzip    []byte
}

func (response *libraryResponse) size() int { return len(response.plain) + len(response.gzip) }

// Keep immutable JSON and gzip bytes, not a mutable Library shared with callers.
// Most installs use one public URL and one LAN URL. Limit both entry count and
// bytes so forwarded-host variations cannot grow memory without bound.
type libraryResponseCache struct {
	mu      sync.Mutex
	entries []*libraryResponse // most recently used first
	bytes   int
}

func (s *Server) libraryETag(key libraryResponseKey, version int64) string {
	baseHash := sha256.Sum256([]byte(key.baseURL))
	// The weak validator deliberately describes the same semantic JSON in
	// identity/gzip encodings. Endpoint and public URL are part of the identity.
	return fmt.Sprintf(`W/"%s-v%d-%x-%t"`, s.libraryEpoch, version, baseHash[:16], key.snapshot)
}

func matchesETag(header, etag string) bool {
	for _, candidate := range strings.Split(header, ",") {
		candidate = strings.TrimSpace(candidate)
		if candidate == "*" || strings.TrimPrefix(candidate, "W/") == strings.TrimPrefix(etag, "W/") {
			return true
		}
	}
	return false
}

func setLibraryHeaders(w http.ResponseWriter, etag string) {
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "private, no-cache")
	addVary(w.Header(), "Accept-Encoding")
}

func (s *Server) serveLibraryResponse(w http.ResponseWriter, r *http.Request, snapshot bool) {
	key := libraryResponseKey{baseURL: publicBaseURL(r), snapshot: snapshot}
	etag := s.libraryETag(key, s.libraryVersion.Load())
	if matchesETag(r.Header.Get("If-None-Match"), etag) {
		setLibraryHeaders(w, etag)
		w.WriteHeader(http.StatusNotModified)
		return
	}
	response, err := s.cachedLibraryResponse(r.Context(), key)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	setLibraryHeaders(w, response.etag)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	body := response.plain
	if acceptsGzip(r) && len(response.gzip) < len(body) && r.Header.Get("Range") == "" {
		body = response.gzip
		w.Header().Set("Content-Encoding", "gzip")
	}
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(http.StatusOK)
	if r.Method != http.MethodHead {
		_, _ = w.Write(body)
	}
}

func (s *Server) cachedLibraryResponse(ctx context.Context, key libraryResponseKey) (*libraryResponse, error) {
	cache := &s.libraryResponses
	// Also coalesce concurrent cache misses: one SQLite scan/encode/compression
	// serves all callers. Library writes never acquire this mutex.
	cache.mu.Lock()
	defer cache.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	version := s.libraryVersion.Load()
	for i := 0; i < len(cache.entries); {
		entry := cache.entries[i]
		if entry.version != version {
			cache.bytes -= entry.size()
			copy(cache.entries[i:], cache.entries[i+1:])
			last := len(cache.entries) - 1
			cache.entries[last] = nil
			cache.entries = cache.entries[:last]
			continue
		}
		if entry.key == key {
			copy(cache.entries[1:i+1], cache.entries[:i])
			cache.entries[0] = entry
			return entry, nil
		}
		i++
	}
	snapshot, err := s.snapshot(ctx, key.baseURL)
	if err != nil {
		return nil, err
	}
	var value any = snapshot.Library
	if key.snapshot {
		value = snapshot
	}
	plain, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	plain = append(plain, '\n') // preserve the existing JSON encoder's wire form
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	var compressed bytes.Buffer
	writer := gzipWriters.Get().(*gzip.Writer)
	writer.Reset(&compressed)
	_, writeErr := writer.Write(plain)
	closeErr := writer.Close()
	writer.Reset(io.Discard)
	gzipWriters.Put(writer)
	if writeErr != nil {
		return nil, writeErr
	}
	if closeErr != nil {
		return nil, closeErr
	}
	response := &libraryResponse{
		key: key, version: version, etag: s.libraryETag(key, version),
		plain: plain, gzip: compressed.Bytes(),
	}
	// A write may commit during the scan. Such a response keeps the older
	// validator (so the next refresh fetches again) and never enters the cache.
	if version == s.libraryVersion.Load() && response.size() <= maxLibraryResponseBytes && ctx.Err() == nil {
		for len(cache.entries) >= maxLibraryResponseEntries || cache.bytes+response.size() > maxLibraryResponseBytes {
			last := len(cache.entries) - 1
			cache.bytes -= cache.entries[last].size()
			cache.entries[last] = nil
			cache.entries = cache.entries[:last]
		}
		cache.entries = append([]*libraryResponse{response}, cache.entries...)
		cache.bytes += response.size()
	}
	return response, nil
}
