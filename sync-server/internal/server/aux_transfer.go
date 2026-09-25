package server

// Aux transfers never reuse owner authorization across origins. The source
// authenticates a selected record with a short-lived, revocable capability;
// the receiving owner imports verified bytes additively into their own library.
import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const auxTransferTTL = 15 * 60
const auxTransferListenTTL = 24 * 60 * 60

type AuxTransferReference struct {
	SourceOrigin string `json:"source_origin"`
	Token        string `json:"token"`
}
type AuxTransferTrack struct {
	Title           string   `json:"title"`
	Artist          string   `json:"artist"`
	Album           string   `json:"album"`
	DurationSeconds *float64 `json:"duration_seconds,omitempty"`
}
type AuxTransferGrantRequest struct {
	Fingerprint       string `json:"fingerprint"`
	SessionID         string `json:"session_id"`
	SessionOrigin     string `json:"session_origin"`
	DestinationOrigin string `json:"destination_origin"`
	AllowCopy         bool   `json:"allow_copy"`
}
type AuxTransferGrant struct {
	ParticipantID string `json:"participant_id,omitempty"`
	AuxTransferGrantRequest
	SourceOrigin     string           `json:"source_origin"`
	Token            string           `json:"token"`
	ExpiresAt        int64            `json:"expires_at"`
	SHA256           string           `json:"sha256"`
	SizeBytes        int64            `json:"size_bytes"`
	AudioType        string           `json:"audio_type"`
	ArtworkSHA256    string           `json:"artwork_sha256,omitempty"`
	ArtworkSizeBytes int64            `json:"artwork_size_bytes,omitempty"`
	Track            AuxTransferTrack `json:"track"`
	MediaURL         string           `json:"media_url"`
	ArtworkURL       string           `json:"artwork_url,omitempty"`
}
type auxTransferResolve struct {
	ParticipantID     string `json:"participant_id,omitempty"`
	Token             string `json:"token"`
	SessionID         string `json:"session_id"`
	SessionOrigin     string `json:"session_origin"`
	DestinationOrigin string `json:"destination_origin"`
	Purpose           string `json:"purpose"`
}
type AuxTransferRequest struct {
	OperationID   string               `json:"operation_id"`
	Grant         AuxTransferReference `json:"grant"`
	SessionID     string               `json:"session_id"`
	SessionOrigin string               `json:"session_origin"`
	PlaylistID    string               `json:"playlist_id,omitempty"`
}
type AuxTransferResult struct {
	OperationID   string `json:"operation_id"`
	Fingerprint   string `json:"fingerprint"`
	TrackID       string `json:"track_id"`
	Status        string `json:"status"`
	PlaylistAdded bool   `json:"playlist_added"`
}

func (s *Server) migrateAuxTransfer(ctx context.Context) error {
	for _, stmt := range []string{
		`CREATE TABLE IF NOT EXISTS aux_transfer_grants (token_hash TEXT PRIMARY KEY, parent_hash TEXT NOT NULL DEFAULT '', descriptor TEXT NOT NULL, revoked INTEGER NOT NULL DEFAULT 0)`,
		`CREATE TABLE IF NOT EXISTS aux_transfers (operation_id TEXT PRIMARY KEY, request_hash TEXT NOT NULL, result TEXT NOT NULL)`,
	} {
		if _, err := s.db.ExecContext(ctx, stmt); err != nil {
			return err
		}
	}
	return nil
}
func (s *Server) registerAuxTransferRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v2/aux/grants", s.handleCreateAuxTransferGrant)
	mux.HandleFunc("DELETE /api/v2/aux/grants", s.handleRevokeAuxTransferGrant)
	mux.HandleFunc("POST /api/v2/aux/grants/resolve", s.handleResolveAuxTransferGrant)
	mux.HandleFunc("GET /api/v2/aux/grants/media/{fingerprint}/{kind}", s.handleAuxTransferMedia)
	mux.HandleFunc("HEAD /api/v2/aux/grants/media/{fingerprint}/{kind}", s.handleAuxTransferMedia)
	mux.HandleFunc("GET /api/v2/aux/membership/{fingerprint}", s.handleAuxTransferMembership)
	mux.HandleFunc("POST /api/v2/aux/transfers", s.handleAuxTransfer)
	mux.HandleFunc("POST /api/v2/aux/membership/{fingerprint}/playlist", s.handleAuxMembershipPlaylist)
}
func auxTransferPublicRequest(r *http.Request) bool {
	return (r.Method == http.MethodPost && r.URL.Path == "/api/v2/aux/grants/resolve") ||
		((r.Method == http.MethodGet || r.Method == http.MethodHead) && strings.HasPrefix(r.URL.Path, "/api/v2/aux/grants/media/"))
}
func auxTransferDecode(w http.ResponseWriter, r *http.Request, v any) error {
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
	defer r.Body.Close()
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		return err
	}
	if d.Decode(new(any)) != io.EOF {
		return errors.New("expected one JSON object")
	}
	return nil
}
func auxHash(value string) string { h := sha256.Sum256([]byte(value)); return hex.EncodeToString(h[:]) }
func auxOpaqueID() (string, error) {
	b := make([]byte, 24)
	_, e := rand.Read(b)
	return hex.EncodeToString(b), e
}
func auxValidID(v string) bool {
	return len(v) > 0 && len(v) <= 256 && !strings.ContainsAny(v, "/\\?#\x00\r\n")
}
func auxOrigin(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return "", errors.New("cross-server sharing requires an HTTPS origin")
	}
	if u.Port() != "" && u.Port() != "443" {
		return "", errors.New("cross-server sharing requires HTTPS port 443")
	}
	return strings.TrimSuffix(u.String(), "/"), nil
}

// Production transport resolves and checks every address before dialing that
// exact IP, disallows proxies, and refuses every redirect. There is no runtime
// LAN allowlist or environment switch. Isolated tests inject their own client.
func auxPublicIP(ip net.IP) bool {
	a, ok := netip.AddrFromSlice(ip)
	if !ok {
		return false
	}
	a = a.Unmap()
	if !a.IsGlobalUnicast() || a.IsPrivate() || a.IsLoopback() || a.IsLinkLocalUnicast() || a.IsLinkLocalMulticast() || a.IsUnspecified() {
		return false
	}
	for _, cidr := range []string{"100.64.0.0/10", "192.0.0.0/24", "192.0.2.0/24", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "240.0.0.0/4", "2001:db8::/32", "2001::/23", "2002::/16", "::/96", "64:ff9b::/96", "64:ff9b:1::/48"} {
		if netip.MustParsePrefix(cidr).Contains(a) {
			return false
		}
	}
	return true
}
func newAuxTransferHTTPClient() *http.Client {
	transport := &http.Transport{Proxy: nil, TLSHandshakeTimeout: 5 * time.Second, ResponseHeaderTimeout: 10 * time.Second, DisableKeepAlives: true}
	transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(address)
		if err != nil || port != "443" {
			return nil, errors.New("invalid source endpoint")
		}
		ips, err := net.DefaultResolver.LookupIPAddr(ctx, host)
		if err != nil || len(ips) == 0 {
			return nil, errors.New("source DNS unavailable")
		}
		for _, ip := range ips {
			if !auxPublicIP(ip.IP) {
				return nil, errors.New("source must resolve to public addresses")
			}
		}
		return (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, network, net.JoinHostPort(ips[0].IP.String(), port))
	}
	return &http.Client{Transport: transport, Timeout: 60 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("source redirects are not allowed") }}
}
func (s *Server) auxHTTP() *http.Client {
	if s.auxTransferHTTPClient != nil {
		return s.auxTransferHTTPClient
	}
	return newAuxTransferHTTPClient()
}
func (s *Server) auxRemoteJSON(ctx context.Context, origin, path string, input, output any) error {
	origin, err := auxOrigin(origin)
	if err != nil {
		return err
	}
	var body io.Reader
	method := http.MethodGet
	if input != nil {
		raw, e := json.Marshal(input)
		if e != nil {
			return e
		}
		body = bytes.NewReader(raw)
		method = http.MethodPost
	}
	req, err := http.NewRequestWithContext(ctx, method, origin+path, body)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	res, err := s.auxHTTP().Do(req)
	if err != nil {
		return errors.New("source unavailable or blocked by network policy")
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return errors.New("source permission expired, revoked, or unavailable")
	}
	raw, err := io.ReadAll(io.LimitReader(res.Body, (32<<10)+1))
	if err != nil || len(raw) > 32<<10 {
		return errors.New("invalid source response")
	}
	return json.Unmarshal(raw, output)
}
func (s *Server) auxSessionLive(ctx context.Context, g AuxTransferGrant) error {
	_, err := s.auxSessionExpiry(ctx, g)
	return err
}
func (s *Server) auxSessionExpiry(ctx context.Context, g AuxTransferGrant) (int64, error) {
	if !auxValidID(g.SessionID) || s.now().Unix() >= g.ExpiresAt {
		return 0, errors.New("sharing permission expired")
	}
	var status struct {
		Active    bool  `json:"active"`
		ExpiresAt int64 `json:"expires_at"`
	}
	statusPath := "/api/v2/aux/sessions/" + url.PathEscape(g.SessionID) + "/status"
	if g.ParticipantID != "" {
		statusPath += "?participant_id=" + url.QueryEscape(g.ParticipantID)
	}
	if err := s.auxRemoteJSON(ctx, g.SessionOrigin, statusPath, nil, &status); err != nil {
		return 0, err
	}
	if !status.Active || status.ExpiresAt <= s.now().Unix() {
		return 0, errors.New("Aux session ended")
	}
	return status.ExpiresAt, nil
}
func auxFileDigest(path string, max int64) (string, int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	h := sha256.New()
	n, err := io.Copy(h, io.LimitReader(f, max+1))
	if err != nil || n <= 0 || n > max {
		return "", 0, errors.New("media is empty or too large")
	}
	return hex.EncodeToString(h.Sum(nil)), n, nil
}
func (s *Server) createAuxTransferGrant(ctx context.Context, req AuxTransferGrantRequest, sourceOrigin string) (AuxTransferGrant, error) {
	var g AuxTransferGrant
	sourceOrigin, err := auxOrigin(sourceOrigin)
	if err != nil {
		return g, err
	}
	req.SessionOrigin, err = auxOrigin(req.SessionOrigin)
	if err != nil {
		return g, err
	}
	req.DestinationOrigin, err = auxOrigin(req.DestinationOrigin)
	if err != nil {
		return g, err
	}
	if !auxValidID(req.Fingerprint) || !auxValidID(req.SessionID) || req.DestinationOrigin != req.SessionOrigin {
		return g, errors.New("grant must target its Aux session origin")
	}
	g = AuxTransferGrant{AuxTransferGrantRequest: req, SourceOrigin: sourceOrigin, ExpiresAt: s.now().Unix() + auxTransferListenTTL}
	sessionExpiry, err := s.auxSessionExpiry(ctx, g)
	if err != nil {
		return g, err
	}
	if sessionExpiry < g.ExpiresAt {
		g.ExpiresAt = sessionExpiry
	}
	var raw string
	if err := s.db.QueryRowContext(ctx, `SELECT metadata_json FROM tracks WHERE fingerprint=?`, req.Fingerprint).Scan(&raw); err != nil {
		return g, err
	}
	var track Track
	if err := json.Unmarshal([]byte(raw), &track); err != nil {
		return g, err
	}
	audio, err := s.mediaPath(ctx, req.Fingerprint, "audio_path")
	if err != nil {
		return g, errors.New("source track has no usable audio")
	}
	g.SHA256, g.SizeBytes, err = auxFileDigest(audio, maxAudioBytes)
	if err != nil {
		return g, err
	}
	if artwork, e := s.mediaPath(ctx, req.Fingerprint, "artwork_path"); e == nil {
		g.ArtworkSHA256, g.ArtworkSizeBytes, err = auxFileDigest(artwork, maxImageBytes)
		if err != nil {
			return g, err
		}
	}
	g.AudioType = s.audioType(ctx, req.Fingerprint)
	g.Track = AuxTransferTrack{Title: track.Title, Artist: track.Artist, Album: track.Album, DurationSeconds: track.DurationSeconds}
	token, err := auxOpaqueID()
	if err != nil {
		return g, err
	}
	g.Token = "auxg_" + token
	auxGrantURLs(&g)
	if err := s.storeAuxTransferGrant(ctx, g, ""); err != nil {
		return g, err
	}
	return g, nil
}
func auxGrantURLs(g *AuxTransferGrant) {
	base := g.SourceOrigin + "/api/v2/aux/grants/media/" + url.PathEscape(g.Fingerprint)
	g.MediaURL = base + "/audio?access_token=" + url.QueryEscape(g.Token)
	g.ArtworkURL = ""
	if g.ArtworkSizeBytes > 0 {
		g.ArtworkURL = base + "/artwork?access_token=" + url.QueryEscape(g.Token)
	}
}
func (s *Server) storeAuxTransferGrant(ctx context.Context, g AuxTransferGrant, parent string) error {
	stored := g
	stored.Token = ""
	stored.MediaURL = ""
	stored.ArtworkURL = ""
	raw, err := json.Marshal(stored)
	if err != nil {
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, `DELETE FROM aux_transfer_grants WHERE revoked=1 OR CAST(json_extract(descriptor,'$.expires_at') AS INTEGER)<=?`, s.now().Unix()); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM aux_transfer_grants WHERE parent_hash<>'' AND parent_hash NOT IN (SELECT token_hash FROM aux_transfer_grants)`); err != nil {
		return err
	}
	var count int
	if err = tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM aux_transfer_grants`).Scan(&count); err != nil {
		return err
	}
	if count >= 5000 {
		return errors.New("too many active sharing permissions; retry after older permissions expire")
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO aux_transfer_grants(token_hash,parent_hash,descriptor) VALUES(?,?,?)`, auxHash(g.Token), parent, string(raw)); err != nil {
		return err
	}
	return tx.Commit()
}
func (s *Server) loadAuxTransferGrant(ctx context.Context, token string) (AuxTransferGrant, error) {
	var g AuxTransferGrant
	var raw, parent string
	var revoked int
	if !strings.HasPrefix(token, "auxg_") || len(token) != 53 {
		return g, errors.New("invalid sharing permission")
	}
	err := s.db.QueryRowContext(ctx, `SELECT descriptor,parent_hash,revoked FROM aux_transfer_grants WHERE token_hash=?`, auxHash(token)).Scan(&raw, &parent, &revoked)
	if err != nil || revoked != 0 {
		return g, errors.New("sharing permission revoked")
	}
	if parent != "" {
		if err := s.db.QueryRowContext(ctx, `SELECT revoked FROM aux_transfer_grants WHERE token_hash=?`, parent).Scan(&revoked); err != nil || revoked != 0 {
			return g, errors.New("sharing permission revoked")
		}
	}
	if err := json.Unmarshal([]byte(raw), &g); err != nil {
		return g, err
	}
	g.Token = token
	auxGrantURLs(&g)
	if err := s.auxSessionLive(ctx, g); err != nil {
		return g, err
	}
	return g, nil
}
func (s *Server) handleCreateAuxTransferGrant(w http.ResponseWriter, r *http.Request) {
	var req AuxTransferGrantRequest
	if err := auxTransferDecode(w, r, &req); err != nil {
		writeError(w, 400, err)
		return
	}
	g, err := s.createAuxTransferGrant(r.Context(), req, publicBaseURL(r))
	if err != nil {
		writeError(w, 422, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, 201, g)
}
func (s *Server) handleRevokeAuxTransferGrant(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Token string `json:"token"`
	}
	if err := auxTransferDecode(w, r, &req); err != nil {
		writeError(w, 400, err)
		return
	}
	if _, err := s.db.ExecContext(r.Context(), `UPDATE aux_transfer_grants SET revoked=1 WHERE token_hash=?`, auxHash(req.Token)); err != nil {
		writeError(w, 500, err)
		return
	}
	w.WriteHeader(204)
}
func (s *Server) handleResolveAuxTransferGrant(w http.ResponseWriter, r *http.Request) {
	var req auxTransferResolve
	if err := auxTransferDecode(w, r, &req); err != nil {
		writeError(w, 400, err)
		return
	}
	g, err := s.loadAuxTransferGrant(r.Context(), req.Token)
	if err != nil || g.SessionID != req.SessionID || g.SessionOrigin != req.SessionOrigin {
		writeError(w, 403, errors.New("sharing permission does not match session"))
		return
	}
	if req.ParticipantID != "" && (!auxValidID(req.ParticipantID) || (g.ParticipantID != "" && g.ParticipantID != req.ParticipantID)) {
		writeError(w, 403, errors.New("copy permission belongs to another participant"))
		return
	}
	switch req.Purpose {
	case "listen":
		if g.DestinationOrigin != req.DestinationOrigin || g.DestinationOrigin != g.SessionOrigin {
			writeError(w, 403, errors.New("wrong sharing destination"))
			return
		}
	case "copy":
		if !g.AllowCopy {
			writeError(w, 403, errors.New("source owner has not allowed saving"))
			return
		}
		dest, e := auxOrigin(req.DestinationOrigin)
		if e != nil {
			writeError(w, 400, e)
			return
		}
		if g.DestinationOrigin != g.SessionOrigin && g.DestinationOrigin != dest {
			writeError(w, 403, errors.New("wrong copy destination"))
			return
		}
		if dest != g.DestinationOrigin || (req.ParticipantID != "" && g.ParticipantID == "") {
			parent := auxHash(g.Token)
			id, e := auxOpaqueID()
			if e != nil {
				writeError(w, 500, e)
				return
			}
			g.Token = "auxg_" + id
			g.DestinationOrigin = dest
			if g.ExpiresAt > s.now().Unix()+auxTransferTTL {
				g.ExpiresAt = s.now().Unix() + auxTransferTTL
			}
			if req.ParticipantID != "" {
				g.ParticipantID = req.ParticipantID
			}
			auxGrantURLs(&g)
			if e = s.storeAuxTransferGrant(r.Context(), g, parent); e != nil {
				writeError(w, 500, e)
				return
			}
		}
	default:
		writeError(w, 400, errors.New("invalid grant purpose"))
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, 200, g)
}
func (s *Server) resolveAuxTransferGrant(ctx context.Context, ref AuxTransferReference, sessionID, sessionOrigin, destinationOrigin, purpose string) (AuxTransferGrant, error) {
	var g AuxTransferGrant
	source, err := auxOrigin(ref.SourceOrigin)
	if err != nil {
		return g, err
	}
	if err = s.auxRemoteJSON(ctx, source, "/api/v2/aux/grants/resolve", auxTransferResolve{Token: ref.Token, SessionID: sessionID, SessionOrigin: sessionOrigin, DestinationOrigin: destinationOrigin, Purpose: purpose}, &g); err != nil {
		return g, err
	}
	if g.SourceOrigin != source || g.SessionID != sessionID || g.SessionOrigin != sessionOrigin || g.DestinationOrigin != destinationOrigin || g.ExpiresAt <= s.now().Unix() || g.ExpiresAt > s.now().Unix()+auxTransferListenTTL || !auxValidID(g.Fingerprint) || g.SizeBytes <= 0 || g.SizeBytes > maxAudioBytes || len(g.SHA256) != 64 || g.ArtworkSizeBytes < 0 || g.ArtworkSizeBytes > maxImageBytes || len(g.Track.Title) > 2048 || len(g.Track.Artist) > 2048 || len(g.Track.Album) > 2048 || !strings.HasPrefix(g.Token, "auxg_") || len(g.Token) != 53 {
		return AuxTransferGrant{}, errors.New("source supplied an invalid grant")
	}
	if _, e := hex.DecodeString(g.SHA256); e != nil {
		return AuxTransferGrant{}, errors.New("invalid audio hash")
	}
	if g.ArtworkSizeBytes > 0 {
		if b, e := hex.DecodeString(g.ArtworkSHA256); e != nil || len(b) != 32 {
			return AuxTransferGrant{}, errors.New("invalid artwork hash")
		}
	}
	if purpose == "copy" && !g.AllowCopy {
		return AuxTransferGrant{}, errors.New("source owner has not allowed saving")
	}
	// URLs are always reconstructed from validated origin, exact record, and token.
	auxGrantURLs(&g)
	return g, nil
}
func (s *Server) validateAuxTransferGrant(ctx context.Context, ref AuxTransferReference, sessionID, hostOrigin string) (AuxTransferGrant, error) {
	return s.resolveAuxTransferGrant(ctx, ref, sessionID, hostOrigin, hostOrigin, "listen")
}
func (s *Server) handleAuxTransferMedia(w http.ResponseWriter, r *http.Request) {
	g, err := s.loadAuxTransferGrant(r.Context(), presentedToken(r))
	if err != nil || g.Fingerprint != r.PathValue("fingerprint") {
		writeError(w, 403, errors.New("invalid media permission"))
		return
	}
	column, hash, size, kind := "audio_path", g.SHA256, g.SizeBytes, g.AudioType
	switch r.PathValue("kind") {
	case "audio":
	case "artwork":
		column, hash, size, kind = "artwork_path", g.ArtworkSHA256, g.ArtworkSizeBytes, "image/jpeg"
	default:
		writeError(w, 404, errors.New("unknown media"))
		return
	}
	path, err := s.mediaPath(r.Context(), g.Fingerprint, column)
	if err != nil {
		writeError(w, 404, errors.New("shared media unavailable"))
		return
	}
	// Hash and serve the same open file. A concurrent owner upload renames its
	// new file into place and cannot swap the bytes after this verification.
	file, err := os.Open(path)
	if err != nil {
		writeError(w, 404, errors.New("shared media unavailable"))
		return
	}
	defer file.Close()
	h := sha256.New()
	n, err := io.Copy(h, io.LimitReader(file, size+1))
	if err != nil || n != size || hex.EncodeToString(h.Sum(nil)) != hash {
		writeError(w, 409, errors.New("shared media changed; share it again"))
		return
	}
	if _, err = file.Seek(0, io.SeekStart); err != nil {
		writeError(w, 500, errors.New("shared media unavailable"))
		return
	}
	stat, err := file.Stat()
	if err != nil {
		writeError(w, 500, errors.New("shared media unavailable"))
		return
	}
	out := &auxV2MediaWriter{ResponseWriter: w}
	out.Header().Set("Content-Type", kind)
	out.Header().Set("Accept-Ranges", "bytes")
	http.ServeContent(out, r, "shared-media", stat.ModTime(), file)
}
func (s *Server) auxMembership(ctx context.Context, fingerprint string) (string, string, error) {
	var raw string
	err := s.db.QueryRowContext(ctx, `SELECT metadata_json FROM tracks WHERE fingerprint=?`, fingerprint).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return "absent", "", nil
	}
	if err != nil {
		return "", "", err
	}
	var track Track
	if err = json.Unmarshal([]byte(raw), &track); err != nil {
		return "", "", err
	}
	path, err := s.mediaPath(ctx, fingerprint, "audio_path")
	if err == nil {
		if stat, e := os.Stat(path); e == nil && stat.Mode().IsRegular() && stat.Size() > 0 {
			return "present", track.ID, nil
		}
	}
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return "", "", err
	}
	return "repair", track.ID, nil
}
func (s *Server) handleAuxTransferMembership(w http.ResponseWriter, r *http.Request) {
	state, id, err := s.auxMembership(r.Context(), r.PathValue("fingerprint"))
	if err != nil {
		writeError(w, 500, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, 200, map[string]string{"fingerprint": r.PathValue("fingerprint"), "status": state, "track_id": id})
}
func (s *Server) auxStageMedia(ctx context.Context, rawURL, hash string, size int64) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return "", err
	}
	res, err := s.auxHTTP().Do(req)
	if err != nil {
		return "", errors.New("source media unavailable")
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return "", errors.New("source media permission expired or revoked")
	}
	f, err := os.CreateTemp(s.dataDir, ".aux-stage-")
	if err != nil {
		return "", err
	}
	name := f.Name()
	defer func() { f.Close() }()
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(f, h), io.LimitReader(res.Body, size+1))
	if err != nil || n != size || hex.EncodeToString(h.Sum(nil)) != hash {
		os.Remove(name)
		return "", errors.New("source media hash or size mismatch")
	}
	if err = f.Sync(); err != nil {
		os.Remove(name)
		return "", err
	}
	if err = f.Close(); err != nil {
		os.Remove(name)
		return "", err
	}
	return name, nil
}
func auxUsablePath(stored sql.NullString, fallback string) bool {
	for _, p := range []string{stored.String, fallback} {
		if p != "" {
			if st, e := os.Stat(p); e == nil && st.Mode().IsRegular() && st.Size() > 0 {
				return true
			}
		}
	}
	return false
}
func (s *Server) auxCommitTransfer(ctx context.Context, req AuxTransferRequest, requestHash string, g AuxTransferGrant, audio, artwork string) (AuxTransferResult, error) {
	out := AuxTransferResult{OperationID: req.OperationID, Fingerprint: g.Fingerprint, Status: "saved"}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return out, err
	}
	defer tx.Rollback()
	var raw string
	var ap, ip sql.NullString
	err = tx.QueryRowContext(ctx, `SELECT metadata_json,audio_path,artwork_path FROM tracks WHERE fingerprint=?`, g.Fingerprint).Scan(&raw, &ap, &ip)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return out, err
	}
	if errors.Is(err, sql.ErrNoRows) {
		track := Track{ID: "track_" + g.Fingerprint, Fingerprint: g.Fingerprint, Title: g.Track.Title, Artist: g.Track.Artist, Album: g.Track.Album, DurationSeconds: g.Track.DurationSeconds, FileName: safeFileName(g.Track.Title + ".mp3"), SizeBytes: g.SizeBytes, PlaylistIDs: []string{}, UpdatedAt: s.now().Unix()}
		track.Path = remoteTrackPath(track)
		encoded, _ := json.Marshal(track)
		raw = string(encoded)
		_, err = tx.ExecContext(ctx, `INSERT INTO tracks(fingerprint,metadata_json,title,artist,album,file_name,size_bytes,is_liked,updated_at) VALUES(?,?,?,?,?,?,?,0,?)`, g.Fingerprint, raw, track.Title, track.Artist, track.Album, track.FileName, track.SizeBytes, track.UpdatedAt)
		if err != nil {
			return out, err
		}
	}
	var track Track
	if err = json.Unmarshal([]byte(raw), &track); err != nil {
		return out, err
	}
	out.TrackID = track.ID
	created := []string{}
	committed := false
	defer func() {
		if !committed {
			for _, p := range created {
				os.Remove(p)
			}
		}
	}()
	install := func(staged, column, folder, hash string) error {
		// Content-addressed, distinct paths cannot replace an existing personal blob.
		final := filepath.Join(s.dataDir, folder, "aux-"+auxHash(g.Fingerprint)+"-"+hash)
		if _, e := os.Stat(final); e == nil { // Keep any prior blob and use a unique new path.
			suffix, e := auxOpaqueID()
			if e != nil {
				return e
			}
			final += "-" + suffix
		}
		if e := os.Rename(staged, final); e != nil {
			return e
		}
		created = append(created, final)
		_, e := tx.ExecContext(ctx, `UPDATE tracks SET `+column+`=? WHERE fingerprint=?`, final, g.Fingerprint)
		return e
	}
	if !auxUsablePath(ap, s.audioPath(g.Fingerprint)) {
		if err = install(audio, "audio_path", "audio", g.SHA256); err != nil {
			return out, err
		}
		if _, err = tx.ExecContext(ctx, `UPDATE tracks SET audio_type=?,size_bytes=? WHERE fingerprint=?`, normalizeAudioType(g.AudioType), g.SizeBytes, g.Fingerprint); err != nil {
			return out, err
		}
	}
	if artwork != "" && !auxUsablePath(ip, s.artworkPath(g.Fingerprint)) {
		if err = install(artwork, "artwork_path", "artwork", g.ArtworkSHA256); err != nil {
			return out, err
		}
	}
	result, _ := json.Marshal(out)
	if _, err = tx.ExecContext(ctx, `INSERT INTO aux_transfers(operation_id,request_hash,result) VALUES(?,?,?)`, req.OperationID, requestHash, string(result)); err != nil {
		return out, err
	}
	if err = ctx.Err(); err != nil {
		return out, err
	}
	if err = tx.Commit(); err != nil {
		return out, err
	}
	committed = true
	s.libraryChanged()
	return out, nil
}
func (s *Server) finishAuxTransferPlaylist(ctx context.Context, req AuxTransferRequest, out AuxTransferResult) (AuxTransferResult, error) {
	if req.PlaylistID == "" {
		return out, nil
	}
	playlist, err := s.playlistByID(ctx, req.PlaylistID)
	if err == nil && playlist.IsLiked {
		err = errors.New("choose a regular playlist")
	}
	if err == nil {
		_, err = s.modifyPlaylistTracks(ctx, req.PlaylistID, func(ids []string) []string { return append(ids, out.TrackID) })
	}
	out.Status = "saved"
	out.PlaylistAdded = err == nil
	if err != nil {
		out.Status = "playlist_failed"
	}
	raw, _ := json.Marshal(out)
	_, saveErr := s.db.ExecContext(ctx, `UPDATE aux_transfers SET result=? WHERE operation_id=?`, string(raw), req.OperationID)
	return out, saveErr
}
func (s *Server) transferAuxTrack(ctx context.Context, req AuxTransferRequest, destinationOrigin string) (AuxTransferResult, error) {
	var out AuxTransferResult
	if !auxValidID(req.OperationID) || !auxValidID(req.SessionID) {
		return out, errors.New("operation and session ids are required")
	}
	destinationOrigin, err := auxOrigin(destinationOrigin)
	if err != nil {
		return out, err
	}
	// Serialize retries through commit; source I/O is bounded by a one-minute
	// request context and leaves no partial track on cancellation or failure.
	s.auxTransferMu.Lock()
	defer s.auxTransferMu.Unlock()
	identity := req
	identity.PlaylistID = ""
	encoded, _ := json.Marshal(identity)
	requestHash := auxHash(string(encoded))
	var priorHash, raw string
	err = s.db.QueryRowContext(ctx, `SELECT request_hash,result FROM aux_transfers WHERE operation_id=?`, req.OperationID).Scan(&priorHash, &raw)
	if err == nil {
		if priorHash != requestHash {
			return out, errors.New("operation id already belongs to another transfer")
		}
		if err = json.Unmarshal([]byte(raw), &out); err != nil {
			return out, err
		}
		return s.finishAuxTransferPlaylist(ctx, req, out)
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return out, err
	}
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	g, err := s.resolveAuxTransferGrant(ctx, req.Grant, req.SessionID, req.SessionOrigin, destinationOrigin, "copy")
	if err != nil {
		return out, err
	}
	audio, err := s.auxStageMedia(ctx, g.MediaURL, g.SHA256, g.SizeBytes)
	if err != nil {
		return out, err
	}
	defer os.Remove(audio)
	artwork := ""
	if g.ArtworkSizeBytes > 0 {
		artwork, err = s.auxStageMedia(ctx, g.ArtworkURL, g.ArtworkSHA256, g.ArtworkSizeBytes)
		if err != nil {
			return out, err
		}
		defer os.Remove(artwork)
	}
	if err = ctx.Err(); err != nil {
		return out, err
	}
	out, err = s.auxCommitTransfer(ctx, req, requestHash, g, audio, artwork)
	if err != nil {
		return out, err
	}
	return s.finishAuxTransferPlaylist(ctx, req, out)
}
func (s *Server) handleAuxTransfer(w http.ResponseWriter, r *http.Request) {
	var req AuxTransferRequest
	if err := auxTransferDecode(w, r, &req); err != nil {
		writeError(w, 400, err)
		return
	}
	out, err := s.transferAuxTrack(r.Context(), req, publicBaseURL(r))
	if err != nil {
		writeError(w, 422, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, 200, out)
}

// Only the Aux host holds the original source reference. Participants receive
// a destination- and member-bound copy ticket, which cannot outlive their
// authorization on the host even while the overall session remains active.
func (s *Server) resolveAuxParticipantCopyGrant(ctx context.Context, ref AuxTransferReference, sessionID, sessionOrigin, destinationOrigin, participantID string) (AuxTransferReference, error) {
	var g AuxTransferGrant
	if !auxValidID(participantID) {
		return AuxTransferReference{}, errors.New("participant is required")
	}
	if _, err := auxOrigin(destinationOrigin); err != nil {
		return AuxTransferReference{}, err
	}
	err := s.auxRemoteJSON(ctx, ref.SourceOrigin, "/api/v2/aux/grants/resolve", auxTransferResolve{Token: ref.Token, SessionID: sessionID, SessionOrigin: sessionOrigin, DestinationOrigin: destinationOrigin, Purpose: "copy", ParticipantID: participantID}, &g)
	if err != nil {
		return AuxTransferReference{}, err
	}
	if g.SourceOrigin != ref.SourceOrigin || g.SessionID != sessionID || g.SessionOrigin != sessionOrigin || g.DestinationOrigin != destinationOrigin || g.ParticipantID != participantID || !g.AllowCopy || !strings.HasPrefix(g.Token, "auxg_") || len(g.Token) != 53 || g.ExpiresAt <= s.now().Unix() {
		return AuxTransferReference{}, errors.New("source copy permission invalid")
	}
	return AuxTransferReference{SourceOrigin: g.SourceOrigin, Token: g.Token}, nil
}

// Proxy selected foreign audio through the host's participant authorization.
// The source capability is never exposed in queue/catalog responses. Each new
// range request therefore rechecks membership before contacting the source.
func (s *Server) proxyAuxTransferMedia(w http.ResponseWriter, r *http.Request, ref AuxTransferReference, fingerprint, kind, sessionID, sessionOrigin string) {
	out := &auxV2MediaWriter{ResponseWriter: w}
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	g, err := s.validateAuxTransferGrant(ctx, ref, sessionID, sessionOrigin)
	if err != nil || g.Fingerprint != fingerprint {
		writeError(out, 403, errors.New("shared source unavailable or permission expired"))
		return
	}
	mediaURL, size, contentType := g.MediaURL, g.SizeBytes, normalizeAudioType(g.AudioType)
	if kind == "artwork" {
		mediaURL, size, contentType = g.ArtworkURL, g.ArtworkSizeBytes, "image/jpeg"
	} else if kind != "audio" {
		writeError(out, 404, errors.New("unknown media"))
		return
	}
	if mediaURL == "" || size <= 0 {
		writeError(out, 404, errors.New("shared media unavailable"))
		return
	}
	req, err := http.NewRequestWithContext(ctx, r.Method, mediaURL, nil)
	if err != nil {
		writeError(out, 502, errors.New("source unavailable"))
		return
	}
	if value := r.Header.Get("Range"); value != "" {
		if len(value) > 100 || strings.Contains(value, ",") {
			writeError(out, 416, errors.New("one bounded byte range is supported"))
			return
		}
		req.Header.Set("Range", value)
	}
	response, err := s.auxHTTP().Do(req)
	if err != nil {
		writeError(out, 502, errors.New("source unavailable"))
		return
	}
	defer response.Body.Close()
	if response.StatusCode != 200 && response.StatusCode != 206 {
		writeError(out, 502, errors.New("source media unavailable"))
		return
	}
	if response.ContentLength > size {
		writeError(out, 502, errors.New("source media exceeds grant"))
		return
	}
	out.Header().Set("Content-Type", contentType)
	out.Header().Set("Accept-Ranges", "bytes")
	if value := response.Header.Get("Content-Range"); value != "" && len(value) <= 100 {
		out.Header().Set("Content-Range", value)
	}
	if response.ContentLength >= 0 {
		out.Header().Set("Content-Length", fmt.Sprint(response.ContentLength))
	}
	out.WriteHeader(response.StatusCode)
	if r.Method != http.MethodHead {
		_, _ = io.Copy(out, io.LimitReader(response.Body, size))
	}
}

func (s *Server) handleAuxMembershipPlaylist(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PlaylistID string `json:"playlist_id"`
	}
	if err := auxTransferDecode(w, r, &req); err != nil {
		writeError(w, 400, err)
		return
	}
	fingerprint := r.PathValue("fingerprint")
	status, id, err := s.auxMembership(r.Context(), fingerprint)
	if err != nil || status != "present" {
		writeError(w, 409, errors.New("track does not have a usable personal copy"))
		return
	}
	playlist, err := s.playlistByID(r.Context(), req.PlaylistID)
	if err != nil || playlist.IsLiked {
		writeError(w, 422, errors.New("choose an existing personal playlist"))
		return
	}
	_, err = s.modifyPlaylistTracks(r.Context(), req.PlaylistID, func(ids []string) []string { return append(ids, id) })
	if err != nil {
		writeError(w, 422, errors.New("could not add to personal playlist"))
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, 200, AuxTransferResult{Fingerprint: fingerprint, TrackID: id, Status: "saved", PlaylistAdded: true})
}
