package server

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"strings"
)

const streamTokenTTLSeconds = 15 * 60

func (s *Server) handleCreateStreamToken(w http.ResponseWriter, r *http.Request) {
	token, expiresAt, err := s.createStreamToken(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"token":      token,
		"expires_at": expiresAt,
	})
}

func (s *Server) createStreamToken(ctx context.Context) (string, int64, error) {
	tokenBytes := make([]byte, 24)
	if _, err := rand.Read(tokenBytes); err != nil {
		return "", 0, err
	}
	created := s.now().Unix()
	expiresAt := created + streamTokenTTLSeconds
	token := "stream_" + hex.EncodeToString(tokenBytes)
	if _, err := s.db.ExecContext(ctx, `DELETE FROM stream_tokens WHERE expires_at < ?`, created); err != nil {
		return "", 0, err
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO stream_tokens(token, created_at, expires_at) VALUES(?, ?, ?)
	`, token, created, expiresAt)
	return token, expiresAt, err
}

func (s *Server) streamTokenAllows(token string, r *http.Request) bool {
	if !strings.HasPrefix(token, "stream_") || !streamTokenPathAllowed(r) {
		return false
	}
	var expiresAt int64
	err := s.db.QueryRowContext(r.Context(), `
		SELECT expires_at FROM stream_tokens WHERE token = ?
	`, token).Scan(&expiresAt)
	return err == nil && s.now().Unix() <= expiresAt
}

func streamTokenPathAllowed(r *http.Request) bool {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		return false
	}
	path := r.URL.Path
	if path == "/api/v1/playback/events" || path == "/api/v2/playback/events" {
		return true
	}
	if !strings.HasPrefix(path, "/api/v1/tracks/") {
		return false
	}
	return strings.HasSuffix(path, "/audio") || strings.HasSuffix(path, "/artwork")
}
