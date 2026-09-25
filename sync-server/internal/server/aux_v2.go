package server

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

const auxV2Schema = "codec.aux.v2"
const auxV2SessionTTL = 24 * 60 * 60
const auxV2InviteTTL = 15 * 60

type auxV2PrincipalKey struct{}
type auxV2Principal struct {
	SessionID, ParticipantID string
	Owner                    bool
}
type auxV2Rate struct {
	Window int64
	Count  int
}
type AuxV2Track struct {
	Grant           *AuxTransferReference `json:"grant,omitempty"`
	Fingerprint     string                `json:"fingerprint"`
	Title           string                `json:"title"`
	Artist          string                `json:"artist"`
	Album           string                `json:"album"`
	DurationSeconds float64               `json:"duration_seconds"`
	MediaURL        string                `json:"media_url"`
	ArtworkURL      string                `json:"artwork_url"`
}
type AuxV2Entry struct {
	EntryID       string     `json:"entry_id"`
	ParticipantID string     `json:"participant_id"`
	Track         AuxV2Track `json:"track"`
}
type auxV2Member struct {
	ParticipantID string `json:"participant_id"`
	DisplayName   string `json:"display_name"`
	JoinedAt      int64  `json:"joined_at"`
	ExpiresAt     int64  `json:"expires_at"`
}
type AuxV2State struct {
	MediaToken         string        `json:"media_token,omitempty"`
	Schema             string        `json:"schema"`
	SessionID          string        `json:"session_id"`
	Mode               string        `json:"mode"`
	HostName           string        `json:"host_name"`
	HostDeviceID       string        `json:"host_device_id,omitempty"`
	Role               string        `json:"role"`
	ParticipantID      string        `json:"participant_id"`
	ExpiresAt          int64         `json:"expires_at"`
	Revision           int64         `json:"revision"`
	ServerTimeMS       int64         `json:"server_time_ms"`
	Status             string        `json:"status"`
	PositionSeconds    float64       `json:"position_seconds"`
	AnchorTimeMS       int64         `json:"anchor_time_ms"`
	Current            *AuxV2Entry   `json:"current"`
	Queue              []AuxV2Entry  `json:"queue"`
	AllowSaves         bool          `json:"allow_saves"`
	AllowContributions bool          `json:"allow_contributions"`
	Members            []auxV2Member `json:"members,omitempty"`
}
type auxV2Stored struct {
	SessionOrigin string                `json:"session_origin"`
	State         AuxV2State            `json:"state"`
	Catalog       map[string]AuxV2Track `json:"catalog"`
}
type auxV2Command struct {
	Grant            *AuxTransferReference `json:"grant,omitempty"`
	CommandID        string                `json:"command_id"`
	Kind             string                `json:"kind"`
	ExpectedRevision *int64                `json:"expected_revision,omitempty"`
	Fingerprint      string                `json:"fingerprint,omitempty"`
	EntryID          string                `json:"entry_id,omitempty"`
	EntryIDs         []string              `json:"entry_ids,omitempty"`
}

func (s *Server) migrateAuxV2(ctx context.Context) error {
	for _, stmt := range []string{
		`CREATE TABLE IF NOT EXISTS aux_v2_media_tokens(token_hash TEXT PRIMARY KEY,session_id TEXT NOT NULL,expires_at INTEGER NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS aux_v2_sessions(id TEXT PRIMARY KEY, state_json TEXT NOT NULL, expires_at INTEGER NOT NULL, invite_hash TEXT NOT NULL DEFAULT '', invite_expires_at INTEGER NOT NULL DEFAULT 0)`,
		`CREATE TABLE IF NOT EXISTS aux_v2_members(id TEXT PRIMARY KEY,session_id TEXT NOT NULL,token_hash TEXT NOT NULL UNIQUE,display_name TEXT NOT NULL,joined_at INTEGER NOT NULL,expires_at INTEGER NOT NULL)`,
		`CREATE INDEX IF NOT EXISTS aux_v2_members_session ON aux_v2_members(session_id)`,
		`CREATE TABLE IF NOT EXISTS aux_v2_commands(session_id TEXT NOT NULL,participant_id TEXT NOT NULL,command_id TEXT NOT NULL,request_hash TEXT NOT NULL,created_at INTEGER NOT NULL,PRIMARY KEY(session_id,participant_id,command_id))`,
		// The v1 credential gave every participant the same indefinite global access.
		// Cut it off without rotating owner auth or changing ordinary owner playback.
		`DELETE FROM aux_sessions`,
	} {
		if _, err := s.db.ExecContext(ctx, stmt); err != nil {
			return err
		}
	}
	return nil
}
func (s *Server) registerAuxV2Routes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v2/aux/capabilities", func(w http.ResponseWriter, r *http.Request) {
		auxV2JSON(w, 200, map[string]any{"schema": auxV2Schema, "modes": []string{"shared_speaker", "listen_together"}})
	})
	mux.HandleFunc("POST /api/v2/aux/invitation", s.handleAuxV2Invitation)
	mux.HandleFunc("POST /api/v2/aux/join", s.handleAuxV2Join)
	mux.HandleFunc("GET /api/v2/aux/sessions/{id}/status", s.handleAuxV2Status)
	mux.HandleFunc("POST /api/v2/aux/sessions", s.handleAuxV2Create)
	mux.HandleFunc("GET /api/v2/aux/sessions", s.handleAuxV2List)
	mux.HandleFunc("DELETE /api/v2/aux/sessions/{id}", s.handleAuxV2End)
	mux.HandleFunc("GET /api/v2/aux/sessions/{id}/state", s.handleAuxV2State)
	mux.HandleFunc("GET /api/v2/aux/sessions/{id}/events", s.handleAuxV2Events)
	mux.HandleFunc("GET /api/v2/aux/sessions/{id}/catalog", s.handleAuxV2Catalog)
	mux.HandleFunc("POST /api/v2/aux/sessions/{id}/commands", s.handleAuxV2Command)
	mux.HandleFunc("POST /api/v2/aux/sessions/{id}/invite", s.handleAuxV2Invite)
	mux.HandleFunc("DELETE /api/v2/aux/sessions/{id}/invite", s.handleAuxV2Invite)
	mux.HandleFunc("DELETE /api/v2/aux/sessions/{id}/members/{participant_id}", s.handleAuxV2RemoveMember)
	mux.HandleFunc("POST /api/v2/aux/sessions/{id}/tracks/{fingerprint}/copy-grant", s.handleAuxV2CopyGrant)
	mux.HandleFunc("GET /api/v2/aux/sessions/{id}/tracks/{fingerprint}/audio", s.handleAuxV2Media)
	mux.HandleFunc("GET /api/v2/aux/sessions/{id}/tracks/{fingerprint}/artwork", s.handleAuxV2Media)
}
func auxV2Public(r *http.Request) bool {
	p := r.URL.Path
	return (r.Method == "GET" && (p == "/api/v2/aux/capabilities" || (strings.HasPrefix(p, "/api/v2/aux/sessions/") && strings.HasSuffix(p, "/status")))) || (r.Method == "POST" && (p == "/api/v2/aux/join" || p == "/api/v2/aux/invitation"))
}
func auxV2Secret(prefix string) string {
	b := make([]byte, 24)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return prefix + hex.EncodeToString(b)
}
func auxV2Hash(v string) string { h := sha256.Sum256([]byte(v)); return hex.EncodeToString(h[:]) }
func auxV2JSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	writeJSON(w, code, v)
}
func auxV2Error(w http.ResponseWriter, code int, message string) {
	auxV2JSON(w, code, map[string]string{"error": message})
}
func auxV2Decode(w http.ResponseWriter, r *http.Request, v any) error {
	return auxV2DecodeLimit(w, r, v, 16<<10)
}
func auxV2DecodeLimit(w http.ResponseWriter, r *http.Request, v any, limit int64) error {
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		return err
	}
	var extra any
	if err := d.Decode(&extra); err != io.EOF {
		return errors.New("one JSON object required")
	}
	return nil
}
func (s *Server) auxV2Limited(key string, limit int) bool {
	// Call with auxMu held. A bounded minute bucket; no trust in forwarded IPs.
	now := s.now().Unix() / 60
	if s.auxV2Rates == nil {
		s.auxV2Rates = make(map[string]auxV2Rate)
	}
	if len(s.auxV2Rates) > 4096 {
		for k, v := range s.auxV2Rates {
			if v.Window != now {
				delete(s.auxV2Rates, k)
			}
		}
		if len(s.auxV2Rates) > 4096 {
			return true
		}
	}
	v := s.auxV2Rates[key]
	if v.Window != now {
		v = auxV2Rate{Window: now}
	}
	v.Count++
	s.auxV2Rates[key] = v
	return v.Count > limit
}
func auxV2IP(r *http.Request) string {
	ip, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return ip
}
func (s *Server) auxV2Authenticate(r *http.Request, token string) (auxV2Principal, bool) {
	var p auxV2Principal
	var expiry int64
	err := s.db.QueryRowContext(r.Context(), `SELECT m.session_id,m.id,MIN(m.expires_at,s.expires_at) FROM aux_v2_members m JOIN aux_v2_sessions s ON s.id=m.session_id WHERE m.token_hash=?`, auxV2Hash(token)).Scan(&p.SessionID, &p.ParticipantID, &expiry)
	return p, err == nil && s.now().Unix() < expiry
}
func auxV2PrincipalFor(r *http.Request) auxV2Principal {
	p, _ := r.Context().Value(auxV2PrincipalKey{}).(auxV2Principal)
	return p
}
func auxV2GuestRoute(r *http.Request, p auxV2Principal) bool {
	prefix := "/api/v2/aux/sessions/" + p.SessionID + "/"
	suffix, ok := strings.CutPrefix(r.URL.Path, prefix)
	if !ok {
		return false
	}
	if r.Method == "GET" || r.Method == "HEAD" {
		return suffix == "state" || suffix == "catalog" || (r.Method == "GET" && suffix == "events") || (strings.HasPrefix(suffix, "tracks/") && (strings.HasSuffix(suffix, "/audio") || strings.HasSuffix(suffix, "/artwork")))
	}
	return (r.Method == "POST" && (suffix == "commands" || (strings.HasPrefix(suffix, "tracks/") && strings.HasSuffix(suffix, "/copy-grant")))) || (r.Method == "DELETE" && suffix == "members/"+p.ParticipantID)
}
func auxV2Owner(w http.ResponseWriter, r *http.Request) bool {
	if !auxV2PrincipalFor(r).Owner {
		auxV2Error(w, 403, "owner authorization required")
		return false
	}
	return true
}
func (s *Server) auxV2Load(ctx context.Context, id string) (auxV2Stored, error) {
	var raw string
	var expiry int64
	err := s.db.QueryRowContext(ctx, `SELECT state_json,expires_at FROM aux_v2_sessions WHERE id=?`, id).Scan(&raw, &expiry)
	if err != nil {
		return auxV2Stored{}, err
	}
	if s.now().Unix() >= expiry {
		return auxV2Stored{}, sql.ErrNoRows
	}
	var data auxV2Stored
	err = json.Unmarshal([]byte(raw), &data)
	return data, err
}
func (s *Server) auxV2Save(ctx context.Context, data auxV2Stored) error {
	raw, err := json.Marshal(data)
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `UPDATE aux_v2_sessions SET state_json=? WHERE id=?`, string(raw), data.State.SessionID)
	return err
}
func (s *Server) auxV2Read(w http.ResponseWriter, r *http.Request) (auxV2Stored, bool) {
	data, err := s.auxV2Load(r.Context(), r.PathValue("id"))
	if err != nil {
		auxV2Error(w, 404, "Aux session ended or expired")
		return data, false
	}
	p := auxV2PrincipalFor(r)
	if !p.Owner {
		if _, valid := s.auxV2Authenticate(r, presentedToken(r)); !valid {
			auxV2Error(w, 401, "Aux participant expired or removed")
			return data, false
		}
	}
	if !p.Owner && p.SessionID != data.State.SessionID {
		auxV2Error(w, 403, "wrong Aux session")
		return data, false
	}
	if s.auxV2Advance(&data.State) {
		if err := s.auxV2Save(r.Context(), data); err != nil {
			auxV2Error(w, 500, "could not update Aux timeline")
			return data, false
		}
	}
	return data, true
}
func (s *Server) auxV2Position(st AuxV2State) float64 {
	pos := st.PositionSeconds
	if st.Status == "playing" {
		pos += math.Max(0, float64(s.now().UnixMilli()-st.AnchorTimeMS)/1000)
	}
	return pos
}
func auxV2Next(st *AuxV2State, now int64) {
	if len(st.Queue) > 0 {
		entry := st.Queue[0]
		st.Current = &entry
		st.Queue = st.Queue[1:]
		st.PositionSeconds = 0
		st.AnchorTimeMS = now
	} else {
		st.Current = nil
		st.Status = "stopped"
		st.PositionSeconds = 0
		st.AnchorTimeMS = now
	}
}
func (s *Server) auxV2Advance(st *AuxV2State) bool {
	if st.Status != "playing" || st.Current == nil {
		return false
	}
	pos := s.auxV2Position(*st)
	changed := false
	for st.Current != nil && st.Current.Track.DurationSeconds > 0 && pos >= st.Current.Track.DurationSeconds {
		pos -= st.Current.Track.DurationSeconds
		auxV2Next(st, s.now().UnixMilli())
		st.Revision++
		changed = true
	}
	if changed {
		st.PositionSeconds = pos
		if st.Current == nil {
			st.PositionSeconds = 0
		}
		st.AnchorTimeMS = s.now().UnixMilli()
	}
	return changed
}
func (s *Server) auxV2Response(ctx context.Context, data auxV2Stored, p auxV2Principal) AuxV2State {
	st := data.State
	st.Schema = auxV2Schema
	st.ServerTimeMS = s.now().UnixMilli()
	st.PositionSeconds = s.auxV2Position(st)
	st.AnchorTimeMS = st.ServerTimeMS
	st.ParticipantID = p.ParticipantID
	st.Role = "guest"
	st.Members = nil
	if st.Current != nil {
		entry := *st.Current
		entry.Track = auxV2PublicTrack(st.SessionID, entry.Track)
		st.Current = &entry
	}
	st.Queue = append([]AuxV2Entry(nil), st.Queue...)
	for i := range st.Queue {
		st.Queue[i].Track = auxV2PublicTrack(st.SessionID, st.Queue[i].Track)
	}
	if st.Queue == nil {
		st.Queue = []AuxV2Entry{}
	}
	if p.Owner {
		st.Role = "host"
		st.ParticipantID = "host"
		st.MediaToken = s.auxV2OwnerMediaToken(ctx, st.SessionID)
		st.Members = []auxV2Member{}
		rows, err := s.db.QueryContext(ctx, `SELECT id,display_name,joined_at,expires_at FROM aux_v2_members WHERE session_id=? AND expires_at>? ORDER BY joined_at,id`, st.SessionID, s.now().Unix())
		if err == nil {
			defer rows.Close()
			for rows.Next() {
				var m auxV2Member
				if rows.Scan(&m.ParticipantID, &m.DisplayName, &m.JoinedAt, &m.ExpiresAt) == nil {
					st.Members = append(st.Members, m)
				}
			}
		}
	} else {
		st.HostDeviceID = ""
		st.MediaToken = ""
	}
	return st
}
func (s *Server) handleAuxV2Create(w http.ResponseWriter, r *http.Request) {
	if !auxV2Owner(w, r) {
		return
	}
	var req struct {
		Mode                string   `json:"mode"`
		HostDeviceID        string   `json:"host_device_id"`
		HostName            string   `json:"host_name"`
		CatalogFingerprints []string `json:"catalog_fingerprints"`
		AllowSaves          bool     `json:"allow_saves"`
		AllowContributions  bool     `json:"allow_contributions"`
	}
	if auxV2DecodeLimit(w, r, &req, 2<<20) != nil {
		auxV2Error(w, 400, "invalid Aux creation body")
		return
	}
	if (req.Mode != "shared_speaker" && req.Mode != "listen_together") || len(req.HostDeviceID) == 0 || len(req.HostDeviceID) > 200 || len(req.HostName) > 80 || len(req.CatalogFingerprints) > 10000 {
		auxV2Error(w, 400, "valid mode, selected output and at most 10000 catalog tracks required")
		return
	}
	s.auxMu.Lock()
	defer s.auxMu.Unlock()
	s.auxV2Cleanup(r.Context())
	var count int
	if err := s.db.QueryRowContext(r.Context(), `SELECT COUNT(*) FROM aux_v2_sessions WHERE expires_at>?`, s.now().Unix()).Scan(&count); err != nil {
		auxV2Error(w, 500, "Aux storage unavailable")
		return
	}
	if count != 0 {
		auxV2Error(w, 409, "end the current Aux session first")
		return
	}
	id := auxV2Secret("aux_")
	now := s.now().UnixMilli()
	data := auxV2Stored{SessionOrigin: publicBaseURL(r), Catalog: map[string]AuxV2Track{}, State: AuxV2State{Schema: auxV2Schema, SessionID: id, Mode: req.Mode, HostDeviceID: req.HostDeviceID, HostName: strings.TrimSpace(req.HostName), ExpiresAt: s.now().Unix() + auxV2SessionTTL, Revision: 1, Status: "stopped", AnchorTimeMS: now, Queue: []AuxV2Entry{}, AllowSaves: req.AllowSaves, AllowContributions: req.AllowContributions}}
	if data.State.HostName == "" {
		data.State.HostName = "Codec host"
	}
	for _, fp := range req.CatalogFingerprints {
		track, err := s.auxV2CatalogTrack(r.Context(), id, fp)
		if err != nil {
			auxV2Error(w, 400, "catalog contains an unavailable track")
			return
		}
		data.Catalog[fp] = track
	}
	global, err := s.playbackStateV2(r.Context())
	if err != nil {
		auxV2Error(w, 500, "playback unavailable")
		return
	}
	if global != nil {
		if global.ActiveDeviceID != nil && *global.ActiveDeviceID != "" && *global.ActiveDeviceID != req.HostDeviceID {
			auxV2Error(w, 409, "select the existing active output")
			return
		}
		if global.Track != nil {
			track, ok := data.Catalog[global.Track.Fingerprint]
			if !ok {
				auxV2Error(w, 400, "include the currently playing track in the shared catalog")
				return
			}
			data.State.Current = &AuxV2Entry{EntryID: auxV2Secret("entry_"), ParticipantID: "host", Track: track}
			data.State.Status = global.State
			if data.State.Status != "playing" {
				data.State.Status = "paused"
			}
			data.State.PositionSeconds = global.Clock.PositionSeconds
			if global.State == "playing" && global.Clock.StartedAtMS != nil {
				data.State.PositionSeconds += math.Max(0, float64(now-*global.Clock.StartedAtMS)/1000)
			}
			refs := append([]TrackReference{}, global.Context.QueuedTracks...)
			if global.Context.PlaybackIndex >= 0 && global.Context.PlaybackIndex+1 < len(global.Context.PlaybackSource) {
				refs = append(refs, global.Context.PlaybackSource[global.Context.PlaybackIndex+1:]...)
			}
			for _, ref := range refs {
				if track, ok := data.Catalog[ref.Fingerprint]; ok && len(data.State.Queue) < 200 {
					data.State.Queue = append(data.State.Queue, AuxV2Entry{EntryID: auxV2Secret("entry_"), ParticipantID: "host", Track: track})
				}
			}
		}
	}
	secret := auxV2Secret("invite_")
	expiry := s.now().Unix() + auxV2InviteTTL
	raw, _ := json.Marshal(data)
	_, err = s.db.ExecContext(r.Context(), `INSERT INTO aux_v2_sessions(id,state_json,expires_at,invite_hash,invite_expires_at) VALUES(?,?,?,?,?)`, id, string(raw), data.State.ExpiresAt, auxV2Hash(secret), expiry)
	if err != nil {
		auxV2Error(w, 500, "could not create Aux")
		return
	}
	s.playbackEvents.broadcast(PlaybackEvent{Type: "aux_changed"})
	auxV2JSON(w, 201, map[string]any{"schema": auxV2Schema, "session_id": id, "invite_secret": secret, "invite_expires_at": expiry, "state": s.auxV2Response(r.Context(), data, auxV2Principal{Owner: true})})
}
func (s *Server) auxV2CatalogTrack(ctx context.Context, id, fp string) (AuxV2Track, error) {
	if !auxValidID(fp) || cleanFingerprint(fp) != fp {
		return AuxV2Track{}, errors.New("invalid fingerprint")
	}
	var raw string
	var artwork sql.NullString
	err := s.db.QueryRowContext(ctx, `SELECT metadata_json,artwork_path FROM tracks WHERE fingerprint=?`, fp).Scan(&raw, &artwork)
	if err != nil {
		return AuxV2Track{}, err
	}
	var tr Track
	if err = json.Unmarshal([]byte(raw), &tr); err != nil {
		return AuxV2Track{}, err
	}
	base := "/api/v2/aux/sessions/" + id + "/tracks/" + url.PathEscape(fp)
	out := AuxV2Track{Fingerprint: fp, Title: auxV2Text(tr.Title), Artist: auxV2Text(tr.Artist), Album: auxV2Text(tr.Album), MediaURL: base + "/audio"}
	if artwork.Valid && artwork.String != "" {
		out.ArtworkURL = base + "/artwork"
	}
	if tr.DurationSeconds != nil && *tr.DurationSeconds > 0 && *tr.DurationSeconds <= 24*60*60 {
		out.DurationSeconds = *tr.DurationSeconds
	}
	return out, nil
}
func (s *Server) auxV2Cleanup(ctx context.Context) {
	now := s.now().Unix()
	// Owner discovery is also the expiry reconciliation point. Leaving the old
	// pre-Aux global state marked playing could restart a stale song on detach.
	var expiredRaw string
	if err := s.db.QueryRowContext(ctx, `SELECT state_json FROM aux_v2_sessions WHERE expires_at<=? LIMIT 1`, now).Scan(&expiredRaw); err == nil {
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return
		}
		defer tx.Rollback()
		var expired auxV2Stored
		json.Unmarshal([]byte(expiredRaw), &expired)
		previous, err := playbackStateV2InTx(ctx, tx)
		if err != nil {
			return
		}
		stopped := emptyPlaybackStateV2(s.now().UnixMilli())
		if previous != nil {
			stopped.Revision = previous.Revision
			stopped.Volume = previous.Volume
		}
		stopped.Revision++
		if expired.State.HostDeviceID != "" {
			stopped.ActiveDeviceID = &expired.State.HostDeviceID
		}
		raw, _ := json.Marshal(stopped)
		if _, err = tx.ExecContext(ctx, `INSERT INTO playback_state(key,revision,state_json,updated_at) VALUES('global',?,?,?) ON CONFLICT(key) DO UPDATE SET revision=excluded.revision,state_json=excluded.state_json,updated_at=excluded.updated_at`, stopped.Revision, string(raw), s.now().UnixMilli()); err != nil {
			return
		}
		if _, err = tx.ExecContext(ctx, `DELETE FROM aux_v2_sessions WHERE expires_at<=?`, now); err != nil {
			return
		}
		if err = tx.Commit(); err != nil {
			return
		}
		s.playbackEvents.broadcast(PlaybackEvent{Type: "aux_changed"})
		s.playbackEvents.broadcast(PlaybackEvent{Type: "playback_state", PlaybackState: &stopped})
	}
	s.db.ExecContext(ctx, `DELETE FROM aux_v2_members WHERE expires_at<=? OR session_id NOT IN (SELECT id FROM aux_v2_sessions)`, now)
	s.db.ExecContext(ctx, `DELETE FROM aux_v2_commands WHERE session_id NOT IN (SELECT id FROM aux_v2_sessions)`)
	s.db.ExecContext(ctx, `DELETE FROM aux_v2_media_tokens WHERE expires_at<=? OR session_id NOT IN (SELECT id FROM aux_v2_sessions)`, now)
	for id, credential := range s.auxV2MediaTokens {
		if credential.ExpiresAt <= now {
			delete(s.auxV2MediaTokens, id)
		}
	}
}

func (s *Server) auxV2Invitation(w http.ResponseWriter, r *http.Request, join bool) {
	var req struct {
		InviteSecret string `json:"invite_secret"`
		DisplayName  string `json:"display_name,omitempty"`
	}
	if auxV2Decode(w, r, &req) != nil || len(req.InviteSecret) > 100 || len(req.DisplayName) > 80 {
		auxV2Error(w, 400, "invalid invitation")
		return
	}
	s.auxMu.Lock()
	defer s.auxMu.Unlock()
	if s.auxV2Limited("join-global", 300) || s.auxV2Limited("join-ip:"+auxV2IP(r), 30) {
		w.Header().Set("Retry-After", "60")
		auxV2Error(w, 429, "too many invitation attempts")
		return
	}
	var id string
	var expiry int64
	err := s.db.QueryRowContext(r.Context(), `SELECT id,invite_expires_at FROM aux_v2_sessions WHERE invite_hash=? AND invite_expires_at>? AND expires_at>?`, auxV2Hash(req.InviteSecret), s.now().Unix(), s.now().Unix()).Scan(&id, &expiry)
	if err != nil {
		auxV2Error(w, 404, "invitation ended or expired")
		return
	}
	data, err := s.auxV2Load(r.Context(), id)
	if err != nil {
		auxV2Error(w, 404, "Aux session ended")
		return
	}
	if !join {
		auxV2JSON(w, 200, map[string]any{"schema": auxV2Schema, "host_name": data.State.HostName, "mode": data.State.Mode, "expires_at": expiry})
		return
	}
	var count int
	s.db.QueryRowContext(r.Context(), `SELECT COUNT(*) FROM aux_v2_members WHERE session_id=? AND expires_at>?`, id, s.now().Unix()).Scan(&count)
	if count >= 32 {
		auxV2Error(w, 409, "Aux participant limit reached")
		return
	}
	member := auxV2Secret("member_")
	token := auxV2Secret("auxp_")
	name := strings.TrimSpace(req.DisplayName)
	if name == "" {
		name = "Guest"
	}
	_, err = s.db.ExecContext(r.Context(), `INSERT INTO aux_v2_members(id,session_id,token_hash,display_name,joined_at,expires_at) VALUES(?,?,?,?,?,?)`, member, id, auxV2Hash(token), name, s.now().Unix(), data.State.ExpiresAt)
	if err != nil {
		auxV2Error(w, 500, "could not join Aux")
		return
	}
	if s.auxV2Advance(&data.State) {
		s.auxV2Save(r.Context(), data)
	}
	auxV2JSON(w, 200, map[string]any{"schema": auxV2Schema, "session_id": id, "participant_id": member, "participant_token": token, "expires_at": data.State.ExpiresAt, "state": s.auxV2Response(r.Context(), data, auxV2Principal{SessionID: id, ParticipantID: member})})
}
func (s *Server) handleAuxV2Invitation(w http.ResponseWriter, r *http.Request) {
	s.auxV2Invitation(w, r, false)
}
func (s *Server) handleAuxV2Join(w http.ResponseWriter, r *http.Request) {
	s.auxV2Invitation(w, r, true)
}
func (s *Server) handleAuxV2Status(w http.ResponseWriter, r *http.Request) {
	var expiry int64
	err := s.db.QueryRowContext(r.Context(), `SELECT expires_at FROM aux_v2_sessions WHERE id=?`, r.PathValue("id")).Scan(&expiry)
	if err != nil || s.now().Unix() >= expiry {
		auxV2JSON(w, 200, map[string]any{"active": false})
		return
	}
	if participant := r.URL.Query().Get("participant_id"); participant != "" && participant != "host" {
		var memberExpiry int64
		err = s.db.QueryRowContext(r.Context(), `SELECT expires_at FROM aux_v2_members WHERE session_id=? AND id=?`, r.PathValue("id"), participant).Scan(&memberExpiry)
		if err != nil || s.now().Unix() >= memberExpiry {
			auxV2JSON(w, 200, map[string]any{"active": false})
			return
		}
		if memberExpiry < expiry {
			expiry = memberExpiry
		}
	}
	auxV2JSON(w, 200, map[string]any{"active": true, "expires_at": expiry})
}

func (s *Server) handleAuxV2State(w http.ResponseWriter, r *http.Request) {
	s.auxMu.Lock()
	defer s.auxMu.Unlock()
	p := auxV2PrincipalFor(r)
	if !p.Owner && s.auxV2Limited("state:"+p.ParticipantID, 240) {
		w.Header().Set("Retry-After", "60")
		auxV2Error(w, 429, "too many Aux requests")
		return
	}
	data, ok := s.auxV2ReadTimeline(w, r)
	if ok {
		auxV2JSON(w, 200, s.auxV2Response(r.Context(), data, auxV2PrincipalFor(r)))
	}
}
func (s *Server) handleAuxV2Catalog(w http.ResponseWriter, r *http.Request) {
	s.auxMu.Lock()
	defer s.auxMu.Unlock()
	p := auxV2PrincipalFor(r)
	if !p.Owner && s.auxV2Limited("catalog:"+p.ParticipantID, 12) {
		w.Header().Set("Retry-After", "60")
		auxV2Error(w, 429, "too many Aux requests")
		return
	}
	data, ok := s.auxV2Read(w, r)
	if !ok {
		return
	}
	tracks := make([]AuxV2Track, 0, len(data.Catalog))
	for _, tr := range data.Catalog {
		tracks = append(tracks, auxV2PublicTrack(data.State.SessionID, tr))
	}
	sort.Slice(tracks, func(i, j int) bool { return tracks[i].Fingerprint < tracks[j].Fingerprint })
	auxV2JSON(w, 200, map[string]any{"schema": auxV2Schema, "tracks": tracks})
}
func (s *Server) handleAuxV2List(w http.ResponseWriter, r *http.Request) {
	if !auxV2Owner(w, r) {
		return
	}
	s.auxMu.Lock()
	defer s.auxMu.Unlock()
	s.auxV2Cleanup(r.Context())
	rows, err := s.db.QueryContext(r.Context(), `SELECT id FROM aux_v2_sessions WHERE expires_at>?`, s.now().Unix())
	if err != nil {
		auxV2Error(w, 500, "Aux unavailable")
		return
	}
	ids := []string{}
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	rows.Close()
	states := []AuxV2State{}
	for _, id := range ids {
		st, err := s.auxV2Timeline(r.Context(), id)
		if err == nil {
			states = append(states, s.auxV2Response(r.Context(), auxV2Stored{State: st}, auxV2Principal{Owner: true}))
		}
	}
	auxV2JSON(w, 200, map[string]any{"schema": auxV2Schema, "sessions": states})
}
func (s *Server) handleAuxV2Invite(w http.ResponseWriter, r *http.Request) {
	if !auxV2Owner(w, r) {
		return
	}
	s.auxMu.Lock()
	defer s.auxMu.Unlock()
	data, ok := s.auxV2Read(w, r)
	if !ok {
		return
	}
	secret := ""
	expiry := int64(0)
	if r.Method == "POST" {
		secret = auxV2Secret("invite_")
		expiry = s.now().Unix() + auxV2InviteTTL
		if expiry > data.State.ExpiresAt {
			expiry = data.State.ExpiresAt
		}
	}
	hash := ""
	if secret != "" {
		hash = auxV2Hash(secret)
	}
	if _, err := s.db.ExecContext(r.Context(), `UPDATE aux_v2_sessions SET invite_hash=?,invite_expires_at=? WHERE id=?`, hash, expiry, data.State.SessionID); err != nil {
		auxV2Error(w, 500, "could not change invitation")
		return
	}
	if secret == "" {
		w.WriteHeader(204)
	} else {
		auxV2JSON(w, 200, map[string]any{"schema": auxV2Schema, "invite_secret": secret, "invite_expires_at": expiry})
	}
}
func (s *Server) handleAuxV2RemoveMember(w http.ResponseWriter, r *http.Request) {
	p := auxV2PrincipalFor(r)
	member := r.PathValue("participant_id")
	if !p.Owner && (p.ParticipantID != member || p.SessionID != r.PathValue("id")) {
		auxV2Error(w, 403, "cannot remove another participant")
		return
	}
	s.auxMu.Lock()
	defer s.auxMu.Unlock()
	if _, ok := s.auxV2Read(w, r); !ok {
		return
	}
	_, err := s.db.ExecContext(r.Context(), `DELETE FROM aux_v2_members WHERE id=? AND session_id=?`, member, r.PathValue("id"))
	if err != nil {
		auxV2Error(w, 500, "could not remove participant")
		return
	}
	w.WriteHeader(204)
}
func (s *Server) handleAuxV2End(w http.ResponseWriter, r *http.Request) {
	if !auxV2Owner(w, r) {
		return
	}
	s.auxMu.Lock()
	defer s.auxMu.Unlock()
	data, ok := s.auxV2Read(w, r)
	if !ok {
		return
	}
	tx, err := s.db.BeginTx(r.Context(), nil)
	if err != nil {
		auxV2Error(w, 500, "could not end Aux")
		return
	}
	defer tx.Rollback()
	global, err := playbackStateV2InTx(r.Context(), tx)
	if err != nil {
		auxV2Error(w, 500, "could not restore owner playback")
		return
	}
	restored := emptyPlaybackStateV2(s.now().UnixMilli())
	if global != nil {
		restored.Revision = global.Revision
		restored.Volume = global.Volume
	}
	restored.Revision++
	restored.ActiveDeviceID = &data.State.HostDeviceID
	if data.State.Current != nil && data.State.Current.Track.Grant == nil {
		tr := data.State.Current.Track
		restored.Track = &TrackReference{ID: "track_" + tr.Fingerprint, Fingerprint: tr.Fingerprint, Title: tr.Title, Artist: tr.Artist}
		restored.State = "paused"
		setPlaybackClockV2(&restored, s.auxV2Position(data.State), s.now().UnixMilli())
	}
	restoredRaw, _ := json.Marshal(restored)
	if _, err = tx.ExecContext(r.Context(), `INSERT INTO playback_state(key,revision,state_json,updated_at) VALUES('global',?,?,?) ON CONFLICT(key) DO UPDATE SET revision=excluded.revision,state_json=excluded.state_json,updated_at=excluded.updated_at`, restored.Revision, string(restoredRaw), s.now().UnixMilli()); err != nil {
		auxV2Error(w, 500, "could not restore owner playback")
		return
	}
	for _, table := range []string{"aux_v2_members", "aux_v2_commands", "aux_v2_media_tokens"} {
		if _, err = tx.ExecContext(r.Context(), `DELETE FROM `+table+` WHERE session_id=?`, data.State.SessionID); err != nil {
			auxV2Error(w, 500, "could not end Aux")
			return
		}
	}
	if _, err = tx.ExecContext(r.Context(), `DELETE FROM aux_v2_sessions WHERE id=?`, data.State.SessionID); err != nil {
		auxV2Error(w, 500, "could not end Aux")
		return
	}
	if err = tx.Commit(); err != nil {
		auxV2Error(w, 500, "could not end Aux")
		return
	}
	delete(s.auxV2MediaTokens, data.State.SessionID)
	s.playbackEvents.broadcast(PlaybackEvent{Type: "aux_changed"})
	s.playbackEvents.broadcast(PlaybackEvent{Type: "playback_state", PlaybackState: &restored})
	w.WriteHeader(204)
}
func (s *Server) handleAuxV2Media(w http.ResponseWriter, r *http.Request) {
	s.auxMu.Lock()
	data, ok := s.auxV2Read(w, r)
	var track AuxV2Track
	if ok {
		track, ok = data.Catalog[r.PathValue("fingerprint")]
		if !ok {
			auxV2Error(w, 403, "track is outside the shared catalog")
		}
	}
	s.auxMu.Unlock()
	if !ok {
		return
	}
	w.Header().Set("Cache-Control", "private, no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	mediaWriter := &auxV2MediaWriter{ResponseWriter: w}
	if track.Grant != nil {
		kind := "artwork"
		if strings.HasSuffix(r.URL.Path, "/audio") {
			kind = "audio"
		}
		s.proxyAuxTransferMedia(mediaWriter, r, *track.Grant, track.Fingerprint, kind, data.State.SessionID, data.SessionOrigin)
		return
	}
	if strings.HasSuffix(r.URL.Path, "/audio") {
		s.handleGetAudio(mediaWriter, r)
	} else {
		s.handleGetArtwork(mediaWriter, r)
	}
}

func (s *Server) handleAuxV2Command(w http.ResponseWriter, r *http.Request) {
	var req auxV2Command
	if err := auxV2Decode(w, r, &req); err != nil {
		auxV2Error(w, 400, "invalid Aux command")
		return
	}
	if req.CommandID == "" || len(req.CommandID) > 100 {
		auxV2Error(w, 400, "command_id required (max 100 bytes)")
		return
	}
	var verified *AuxTransferGrant
	if req.Grant != nil {
		if req.Kind != "append" {
			auxV2Error(w, 400, "grant only applies to append")
			return
		}
		s.auxMu.Lock()
		pre, exists := s.auxV2Read(w, r)
		if !exists {
			s.auxMu.Unlock()
			return
		}
		p := auxV2PrincipalFor(r)
		actor := p.ParticipantID
		if p.Owner {
			actor = "host"
		}
		if s.auxV2Limited("external-command:"+pre.State.SessionID+":"+actor, 30) {
			s.auxMu.Unlock()
			auxV2Error(w, 429, "too many external contribution attempts")
			return
		}
		raw, _ := json.Marshal(req)
		var previous string
		err := s.db.QueryRowContext(r.Context(), `SELECT request_hash FROM aux_v2_commands WHERE session_id=? AND participant_id=? AND command_id=?`, pre.State.SessionID, actor, req.CommandID).Scan(&previous)
		if err == nil {
			if previous != auxV2Hash(string(raw)) {
				auxV2Error(w, 409, "command_id was already used for a different command")
			} else {
				auxV2JSON(w, 200, s.auxV2Response(r.Context(), pre, p))
			}
			s.auxMu.Unlock()
			return
		}
		if !errors.Is(err, sql.ErrNoRows) {
			s.auxMu.Unlock()
			auxV2Error(w, 500, "Aux commands unavailable")
			return
		}
		s.auxMu.Unlock()
		if !pre.State.AllowContributions {
			auxV2Error(w, 403, "host has not enabled contributions from other servers")
			return
		}
		grant, err := s.validateAuxTransferGrant(r.Context(), *req.Grant, r.PathValue("id"), pre.SessionOrigin)
		if err != nil {
			auxV2Error(w, 400, "selected source grant could not be verified")
			return
		}
		if grant.Fingerprint != req.Fingerprint {
			auxV2Error(w, 400, "grant fingerprint mismatch")
			return
		}
		verified = &grant
	}
	s.auxMu.Lock()
	defer s.auxMu.Unlock()
	data, ok := s.auxV2Read(w, r)
	if !ok {
		return
	}
	p := auxV2PrincipalFor(r)
	actor := p.ParticipantID
	if p.Owner {
		actor = "host"
	}
	if s.auxV2Limited("command:"+data.State.SessionID+":"+actor, 120) {
		w.Header().Set("Retry-After", "60")
		auxV2Error(w, 429, "too many Aux commands")
		return
	}
	body, _ := json.Marshal(req)
	hash := auxV2Hash(string(body))
	var previous string
	err := s.db.QueryRowContext(r.Context(), `SELECT request_hash FROM aux_v2_commands WHERE session_id=? AND participant_id=? AND command_id=?`, data.State.SessionID, actor, req.CommandID).Scan(&previous)
	if err == nil {
		if previous != hash {
			auxV2Error(w, 409, "command_id was already used for a different command")
			return
		}
		auxV2JSON(w, 200, s.auxV2Response(r.Context(), data, p))
		return
	} else if !errors.Is(err, sql.ErrNoRows) {
		auxV2Error(w, 500, "Aux commands unavailable")
		return
	}
	if (req.Kind == "reorder" || req.Kind == "next") && req.ExpectedRevision == nil {
		auxV2Error(w, 400, "expected_revision required")
		return
	}
	if req.ExpectedRevision != nil && *req.ExpectedRevision != data.State.Revision {
		auxV2Error(w, 409, "Aux changed; refresh before retrying")
		return
	}
	var commandCount int
	if err := s.db.QueryRowContext(r.Context(), `SELECT COUNT(*) FROM aux_v2_commands WHERE session_id=?`, data.State.SessionID).Scan(&commandCount); err != nil {
		auxV2Error(w, 500, "Aux storage unavailable")
		return
	}
	if commandCount >= 20000 {
		auxV2Error(w, 409, "session command limit reached; start a new session")
		return
	}
	if verified != nil {
		if !data.State.AllowContributions {
			auxV2Error(w, 403, "contributions disabled")
			return
		}
		if existing, ok := data.Catalog[verified.Fingerprint]; ok && (existing.Grant == nil || existing.Grant.SourceOrigin != verified.SourceOrigin) {
			auxV2Error(w, 409, "fingerprint already belongs to a different shared source")
			return
		}
		if len(data.Catalog) >= 10200 {
			auxV2Error(w, 400, "shared catalog is full")
			return
		}
		tr := AuxV2Track{Fingerprint: verified.Fingerprint, Title: auxV2Text(verified.Track.Title), Artist: auxV2Text(verified.Track.Artist), Album: auxV2Text(verified.Track.Album), MediaURL: verified.MediaURL, ArtworkURL: verified.ArtworkURL, Grant: &AuxTransferReference{SourceOrigin: verified.SourceOrigin, Token: verified.Token}}
		if verified.Track.DurationSeconds != nil && *verified.Track.DurationSeconds > 0 && *verified.Track.DurationSeconds <= 86400 {
			tr.DurationSeconds = *verified.Track.DurationSeconds
		}
		data.Catalog[tr.Fingerprint] = tr
	}
	if err := s.auxV2Mutate(&data, req, actor, p.Owner); err != nil {
		var forbidden *auxV2Forbidden
		if errors.As(err, &forbidden) {
			auxV2Error(w, 403, err.Error())
		} else {
			auxV2Error(w, 400, err.Error())
		}
		return
	}
	data.State.Revision++
	tx, err := s.db.BeginTx(r.Context(), nil)
	if err != nil {
		auxV2Error(w, 500, "could not save Aux command")
		return
	}
	defer tx.Rollback()
	raw, _ := json.Marshal(data)
	if _, err = tx.ExecContext(r.Context(), `UPDATE aux_v2_sessions SET state_json=? WHERE id=?`, string(raw), data.State.SessionID); err == nil {
		_, err = tx.ExecContext(r.Context(), `INSERT INTO aux_v2_commands(session_id,participant_id,command_id,request_hash,created_at) VALUES(?,?,?,?,?)`, data.State.SessionID, actor, req.CommandID, hash, s.now().UnixMilli())
	}
	if err == nil {
		err = tx.Commit()
	}
	if err != nil {
		auxV2Error(w, 500, "could not save Aux command")
		return
	}
	auxV2JSON(w, 200, s.auxV2Response(r.Context(), data, p))
}

type auxV2Forbidden struct{ message string }

func (e *auxV2Forbidden) Error() string { return e.message }
func (s *Server) auxV2Mutate(data *auxV2Stored, req auxV2Command, actor string, owner bool) error {
	st := &data.State
	now := s.now().UnixMilli()
	if req.Kind != "append" && req.Fingerprint != "" {
		return errors.New("fingerprint only applies to append")
	}
	if req.Kind != "remove" && req.EntryID != "" {
		return errors.New("entry_id only applies to remove")
	}
	if req.Kind != "reorder" && req.EntryIDs != nil {
		return errors.New("entry_ids only applies to reorder")
	}
	switch req.Kind {
	case "pause":
		st.PositionSeconds = s.auxV2Position(*st)
		st.AnchorTimeMS = now
		if st.Current != nil {
			st.Status = "paused"
		}
	case "resume":
		if st.Current == nil {
			auxV2Next(st, now)
		}
		if st.Current != nil {
			st.PositionSeconds = s.auxV2Position(*st)
			st.AnchorTimeMS = now
			st.Status = "playing"
		}
	case "next":
		auxV2Next(st, now)
	case "append":
		tr, ok := data.Catalog[req.Fingerprint]
		if !ok {
			return errors.New("track is outside the shared catalog")
		}
		if len(st.Queue) >= 200 {
			return errors.New("Aux queue is full")
		}
		own := 0
		for _, e := range st.Queue {
			if e.ParticipantID == actor {
				own++
			}
		}
		if !owner && own >= 25 {
			return errors.New("participant pending request limit reached")
		}
		st.Queue = append(st.Queue, AuxV2Entry{EntryID: auxV2Secret("entry_"), ParticipantID: actor, Track: tr})
	case "remove":
		found := -1
		for i, e := range st.Queue {
			if e.EntryID == req.EntryID {
				if !owner && e.ParticipantID != actor {
					return &auxV2Forbidden{"cannot remove another participant's request"}
				}
				found = i
				break
			}
		}
		if found < 0 {
			return errors.New("pending entry not found")
		}
		st.Queue = append(st.Queue[:found], st.Queue[found+1:]...)
	case "reorder":
		if len(req.EntryIDs) != len(st.Queue) {
			return errors.New("reorder must preserve every upcoming entry")
		}
		entries := map[string]AuxV2Entry{}
		for _, e := range st.Queue {
			entries[e.EntryID] = e
		}
		out := make([]AuxV2Entry, 0, len(st.Queue))
		for _, id := range req.EntryIDs {
			e, ok := entries[id]
			if !ok {
				return errors.New("reorder contains duplicate, current or unknown entry")
			}
			delete(entries, id)
			out = append(out, e)
		}
		st.Queue = out
	default:
		return fmt.Errorf("unsupported Aux command %q", req.Kind)
	}
	return nil
}

type auxV2MediaCredential struct {
	Token     string
	ExpiresAt int64
}

func (s *Server) auxV2OwnerMediaToken(ctx context.Context, id string) string {
	if s.auxV2MediaTokens == nil {
		s.auxV2MediaTokens = map[string]auxV2MediaCredential{}
	}
	if cached, ok := s.auxV2MediaTokens[id]; ok && cached.ExpiresAt > s.now().Unix()+30 {
		return cached.Token
	}
	token := auxV2Secret("auxm_")
	var expiry int64
	if err := s.db.QueryRowContext(ctx, `SELECT expires_at FROM aux_v2_sessions WHERE id=?`, id).Scan(&expiry); err != nil {
		return ""
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO aux_v2_media_tokens(token_hash,session_id,expires_at) VALUES(?,?,?)`, auxV2Hash(token), id, expiry); err != nil {
		return ""
	}
	s.db.ExecContext(ctx, `DELETE FROM aux_v2_media_tokens WHERE expires_at<=? OR session_id NOT IN (SELECT id FROM aux_v2_sessions)`, s.now().Unix())
	s.auxV2MediaTokens[id] = auxV2MediaCredential{Token: token, ExpiresAt: expiry}
	return token
}
func (s *Server) auxV2MediaTokenAllows(r *http.Request, token string) bool {
	if r.Method != "GET" && r.Method != "HEAD" {
		return false
	}
	var id string
	var expiry int64
	err := s.db.QueryRowContext(r.Context(), `SELECT t.session_id,MIN(t.expires_at,s.expires_at) FROM aux_v2_media_tokens t JOIN aux_v2_sessions s ON s.id=t.session_id WHERE token_hash=?`, auxV2Hash(token)).Scan(&id, &expiry)
	if err != nil || s.now().Unix() >= expiry {
		return false
	}
	if r.Method == "GET" && r.URL.Path == "/api/v2/aux/sessions/"+id+"/events" {
		return true
	}
	prefix := "/api/v2/aux/sessions/" + id + "/tracks/"
	return strings.HasPrefix(r.URL.Path, prefix) && (strings.HasSuffix(r.URL.Path, "/audio") || strings.HasSuffix(r.URL.Path, "/artwork"))
}
func (s *Server) handleAuxV2CopyGrant(w http.ResponseWriter, r *http.Request) {
	var req struct {
		DestinationOrigin string `json:"destination_origin"`
	}
	if auxV2Decode(w, r, &req) != nil {
		auxV2Error(w, 400, "invalid copy destination")
		return
	}
	if _, err := auxOrigin(req.DestinationOrigin); err != nil {
		auxV2Error(w, 400, "destination must be an HTTPS origin")
		return
	}
	s.auxMu.Lock()
	principal := auxV2PrincipalFor(r)
	if !principal.Owner && s.auxV2Limited("copy:"+principal.ParticipantID, 12) {
		s.auxMu.Unlock()
		w.Header().Set("Retry-After", "60")
		auxV2Error(w, 429, "too many Aux requests")
		return
	}
	data, ok := s.auxV2Read(w, r)
	if !ok {
		s.auxMu.Unlock()
		return
	}
	track, exists := data.Catalog[r.PathValue("fingerprint")]
	allowed := exists && data.State.AllowSaves
	if track.Grant != nil {
		allowed = exists
	}
	s.auxMu.Unlock()
	if !allowed {
		auxV2Error(w, 403, "source owner has not enabled saving this song")
		return
	}
	origin := data.SessionOrigin
	p := auxV2PrincipalFor(r)
	actor := p.ParticipantID
	if p.Owner {
		actor = "host"
	}
	var ref AuxTransferReference
	if track.Grant != nil {
		ref = *track.Grant
	} else {
		grant, err := s.createAuxTransferGrant(r.Context(), AuxTransferGrantRequest{Fingerprint: track.Fingerprint, SessionID: data.State.SessionID, SessionOrigin: origin, DestinationOrigin: origin, AllowCopy: true}, origin)
		if err != nil {
			auxV2Error(w, 400, "could not authorize selected song copy")
			return
		}
		ref = AuxTransferReference{SourceOrigin: grant.SourceOrigin, Token: grant.Token}
	}
	child, err := s.resolveAuxParticipantCopyGrant(r.Context(), ref, data.State.SessionID, origin, req.DestinationOrigin, actor)
	if err != nil {
		auxV2Error(w, 403, "source owner has not authorized this participant to save the song")
		return
	}
	auxV2JSON(w, 200, child)
}

// Owner media helpers historically include filesystem error details. A session
// response must neither cache private bytes nor disclose those diagnostics.
type auxV2MediaWriter struct {
	http.ResponseWriter
	sent, failed bool
}

func (w *auxV2MediaWriter) WriteHeader(status int) {
	if w.sent {
		return
	}
	w.sent = true
	w.Header().Set("Cache-Control", "private, no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	if status >= 400 {
		w.failed = true
		w.Header().Del("Content-Length")
		w.Header().Set("Content-Type", "application/json")
		w.ResponseWriter.WriteHeader(status)
		w.ResponseWriter.Write([]byte(`{"error":"shared media unavailable"}`))
		return
	}
	w.ResponseWriter.WriteHeader(status)
}
func (w *auxV2MediaWriter) Write(b []byte) (int, error) {
	if !w.sent {
		w.WriteHeader(200)
	}
	if w.failed {
		return len(b), nil
	}
	return w.ResponseWriter.Write(b)
}

func auxV2Text(value string) string {
	runes := []rune(value)
	if len(runes) > 256 {
		runes = runes[:256]
	}
	return string(runes)
}

// Stored source grant credentials never leave the host. Every listener streams
// through its own session authorization so removal revokes fresh requests.
func auxV2PublicTrack(sessionID string, track AuxV2Track) AuxV2Track {
	if track.Grant != nil {
		base := "/api/v2/aux/sessions/" + sessionID + "/tracks/" + url.PathEscape(track.Fingerprint)
		track.MediaURL = base + "/audio"
		if track.ArtworkURL != "" {
			track.ArtworkURL = base + "/artwork"
		}
		track.Grant = nil
	}
	return track
}

// This stream contains session revision invalidations only. A listener fetches
// its separately authorized state after a change; private global events never
// enter this channel. Media capabilities may open this narrowly scoped stream.
func (s *Server) handleAuxV2Events(w http.ResponseWriter, r *http.Request) {
	p := auxV2PrincipalFor(r)
	token := presentedToken(r)
	key := p.ParticipantID
	if p.Owner {
		key = "host:" + r.PathValue("id")
	}
	s.auxMu.Lock()
	if s.auxV2Streams == nil {
		s.auxV2Streams = map[string]int{}
	}
	if s.auxV2Streams[key] >= 2 {
		s.auxMu.Unlock()
		auxV2Error(w, 429, "two Aux event streams per participant")
		return
	}
	s.auxV2Streams[key]++
	s.auxMu.Unlock()
	defer func() {
		s.auxMu.Lock()
		s.auxV2Streams[key]--
		if s.auxV2Streams[key] == 0 {
			delete(s.auxV2Streams, key)
		}
		s.auxMu.Unlock()
	}()
	controller := http.NewResponseController(w)
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "private, no-store, no-transform")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Accel-Buffering", "no")
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	revision := int64(-1)
	ticks := 0
	for {
		s.auxMu.Lock()
		valid := true
		if !p.Owner {
			_, valid = s.auxV2Authenticate(r, token)
		} else if strings.HasPrefix(token, "auxm_") {
			valid = s.auxV2MediaTokenAllows(r, token)
		}
		var st AuxV2State
		var err error
		if valid {
			st, err = s.auxV2Timeline(r.Context(), r.PathValue("id"))
		}
		s.auxMu.Unlock()
		controller.SetWriteDeadline(time.Now().Add(10 * time.Second))
		if !valid || err != nil {
			fmt.Fprint(w, "event: ended\ndata: {}\n\n")
			controller.Flush()
			return
		}
		if st.Revision != revision {
			if _, err = fmt.Fprintf(w, "event: aux_changed\ndata: {\"revision\":%d}\n\n", st.Revision); err != nil {
				return
			}
			revision = st.Revision
			if controller.Flush() != nil {
				return
			}
		} else if ticks%15 == 0 {
			if _, err = fmt.Fprint(w, ": keepalive\n\n"); err != nil {
				return
			}
			if controller.Flush() != nil {
				return
			}
		}
		controller.SetWriteDeadline(time.Time{})
		select {
		case <-r.Context().Done():
			return
		case <-ticker.C:
			ticks++
		}
	}
}

// Polling and SSE share the same serialized, server-owned advancement. Read only
// the bounded current/queue state here; catalog payloads are never streamed.
func (s *Server) auxV2Timeline(ctx context.Context, id string) (AuxV2State, error) {
	var raw string
	var expires int64
	err := s.db.QueryRowContext(ctx, `SELECT json_extract(state_json,'$.state'),expires_at FROM aux_v2_sessions WHERE id=?`, id).Scan(&raw, &expires)
	if err != nil {
		return AuxV2State{}, err
	}
	if s.now().Unix() >= expires {
		return AuxV2State{}, sql.ErrNoRows
	}
	var st AuxV2State
	if err = json.Unmarshal([]byte(raw), &st); err != nil {
		return st, err
	}
	if s.auxV2Advance(&st) {
		updated, _ := json.Marshal(st)
		_, err = s.db.ExecContext(ctx, `UPDATE aux_v2_sessions SET state_json=json_set(state_json,'$.state',json(?)) WHERE id=?`, string(updated), id)
	}
	return st, err
}

func (s *Server) auxV2ReadTimeline(w http.ResponseWriter, r *http.Request) (auxV2Stored, bool) {
	p := auxV2PrincipalFor(r)
	if !p.Owner {
		if p.SessionID != r.PathValue("id") {
			auxV2Error(w, 403, "wrong Aux session")
			return auxV2Stored{}, false
		}
		if _, valid := s.auxV2Authenticate(r, presentedToken(r)); !valid {
			auxV2Error(w, 401, "Aux participant expired or removed")
			return auxV2Stored{}, false
		}
	}
	st, err := s.auxV2Timeline(r.Context(), r.PathValue("id"))
	if err != nil {
		auxV2Error(w, 404, "Aux session ended or expired")
		return auxV2Stored{}, false
	}
	return auxV2Stored{State: st}, true
}
