// Aux sessions: pass-the-aux shared listening (the Spotify Jam move).
// The host mints a short code; guests trade the code for a scoped token
// that can browse the library, stream, and drive the shared queue - and
// nothing else. Ending the session kills every guest token instantly.
package server

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
)

const auxSchema = "loud.aux.v1"

// Unambiguous alphabet: no 0/O, 1/I/L.
const auxCodeAlphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"

type AuxSession struct {
	Code       string `json:"code"`
	GuestToken string `json:"guest_token,omitempty"`
	CreatedAt  int64  `json:"created_at"`
}

func (s *Server) createAuxSession(ctx context.Context) (AuxSession, error) {
	codeBytes := make([]byte, 4)
	if _, err := rand.Read(codeBytes); err != nil {
		return AuxSession{}, err
	}
	code := make([]byte, 4)
	for i, b := range codeBytes {
		code[i] = auxCodeAlphabet[int(b)%len(auxCodeAlphabet)]
	}

	tokenBytes := make([]byte, 24)
	if _, err := rand.Read(tokenBytes); err != nil {
		return AuxSession{}, err
	}

	session := AuxSession{
		Code:       string(code),
		GuestToken: hex.EncodeToString(tokenBytes),
		CreatedAt:  s.now().Unix(),
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO aux_sessions(code, guest_token, created_at) VALUES(?, ?, ?)
	`, session.Code, session.GuestToken, session.CreatedAt)
	return session, err
}

func (s *Server) auxSessionByCode(ctx context.Context, code string) (AuxSession, error) {
	var session AuxSession
	err := s.db.QueryRowContext(ctx, `
		SELECT code, guest_token, created_at FROM aux_sessions WHERE code = ?
	`, strings.ToUpper(strings.TrimSpace(code))).Scan(&session.Code, &session.GuestToken, &session.CreatedAt)
	return session, err
}

func (s *Server) endAuxSession(ctx context.Context, code string) error {
	result, err := s.db.ExecContext(ctx, `DELETE FROM aux_sessions WHERE code = ?`,
		strings.ToUpper(strings.TrimSpace(code)))
	if err != nil {
		return err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if affected == 0 {
		return sql.ErrNoRows
	}
	return nil
}

// isAuxGuestToken reports whether the presented token belongs to an active
// aux session.
func (s *Server) isAuxGuestToken(token string) bool {
	if token == "" {
		return false
	}
	var code string
	err := s.db.QueryRow(`SELECT code FROM aux_sessions WHERE guest_token = ?`, token).Scan(&code)
	return err == nil
}

// auxGuestAllowed is the whole guest permission surface: browse + stream +
// shared playback. Everything else (sync, uploads, playlists, likes, aux
// management) stays host-only.
func auxGuestAllowed(r *http.Request) bool {
	path := r.URL.Path
	switch {
	case path == "/health":
		return true
	case r.Method == http.MethodGet && path == "/api/v1/library":
		return true
	case r.Method == http.MethodGet && strings.HasPrefix(path, "/api/v1/tracks/"):
		return true
	case strings.HasPrefix(path, "/api/v2/playback"):
		return r.Method == http.MethodGet || path == "/api/v2/playback/commands"
	case strings.HasPrefix(path, "/api/v1/playback/devices"):
		return r.Method == http.MethodGet || r.Method == http.MethodPut
	case r.Method == http.MethodGet && !strings.HasPrefix(path, "/api/"):
		// The web app shell itself, so a join link opens the player.
		return true
	default:
		return false
	}
}

// MARK: handlers

func (s *Server) handleCreateAux(w http.ResponseWriter, r *http.Request) {
	session, err := s.createAuxSession(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"schema":      auxSchema,
		"code":        session.Code,
		"guest_token": session.GuestToken,
		"created_at":  session.CreatedAt,
	})
}

func (s *Server) handleListAux(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.QueryContext(r.Context(), `SELECT code, created_at FROM aux_sessions ORDER BY created_at DESC`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	defer rows.Close()
	sessions := []AuxSession{}
	for rows.Next() {
		var session AuxSession
		if err := rows.Scan(&session.Code, &session.CreatedAt); err != nil {
			writeError(w, http.StatusInternalServerError, err)
			return
		}
		sessions = append(sessions, session)
	}
	writeJSON(w, http.StatusOK, sessions)
}

func (s *Server) handleEndAux(w http.ResponseWriter, r *http.Request) {
	if err := s.endAuxSession(r.Context(), r.PathValue("code")); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			writeError(w, http.StatusNotFound, errors.New("unknown aux code"))
			return
		}
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleJoinAux is deliberately public: the short-lived code IS the secret.
func (s *Server) handleJoinAux(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Code string `json:"code"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	session, err := s.auxSessionByCode(r.Context(), req.Code)
	if err != nil {
		writeError(w, http.StatusNotFound, errors.New("that aux code is not live"))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"schema":      auxSchema,
		"code":        session.Code,
		"guest_token": session.GuestToken,
	})
}

// MARK: media grants (cross-server aux)

// A media grant is how two Codec servers jam without ever dialing each
// other: the guest's own server mints a token scoped to specific tracks,
// the queue entry carries granted URLs, and the host's devices stream
// straight from the guest's server. Grants expire on their own.

const mediaGrantTTLSeconds = 24 * 60 * 60

func (s *Server) createMediaGrant(ctx context.Context, fingerprints []string) (string, int64, error) {
	tokenBytes := make([]byte, 24)
	if _, err := rand.Read(tokenBytes); err != nil {
		return "", 0, err
	}
	token := "grant_" + hex.EncodeToString(tokenBytes)
	encoded, err := json.Marshal(fingerprints)
	if err != nil {
		return "", 0, err
	}
	created := s.now().Unix()
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO media_grants(token, fingerprints_json, created_at) VALUES(?, ?, ?)
	`, token, string(encoded), created)
	return token, created + mediaGrantTTLSeconds, err
}

// mediaGrantAllows reports whether the token is a live grant covering the
// media request (GET audio/artwork for a granted fingerprint only).
func (s *Server) mediaGrantAllows(token string, r *http.Request) bool {
	if r.Method != http.MethodGet || !strings.HasPrefix(token, "grant_") {
		return false
	}
	rest, ok := strings.CutPrefix(r.URL.Path, "/api/v1/tracks/")
	if !ok {
		return false
	}
	parts := strings.Split(rest, "/")
	if len(parts) != 2 || (parts[1] != "audio" && parts[1] != "artwork") {
		return false
	}

	var encoded string
	var created int64
	err := s.db.QueryRowContext(r.Context(), `
		SELECT fingerprints_json, created_at FROM media_grants WHERE token = ?
	`, token).Scan(&encoded, &created)
	if err != nil || s.now().Unix() > created+mediaGrantTTLSeconds {
		return false
	}
	var fingerprints []string
	if err := json.Unmarshal([]byte(encoded), &fingerprints); err != nil {
		return false
	}
	for _, fingerprint := range fingerprints {
		if fingerprint == parts[0] {
			return true
		}
	}
	return false
}

func (s *Server) handleCreateMediaGrant(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Fingerprints []string `json:"fingerprints"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	if len(req.Fingerprints) == 0 || len(req.Fingerprints) > 500 {
		writeError(w, http.StatusBadRequest, errors.New("1-500 fingerprints per grant"))
		return
	}
	token, expiresAt, err := s.createMediaGrant(r.Context(), req.Fingerprints)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"token":      token,
		"expires_at": expiresAt,
	})
}
