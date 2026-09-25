package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// This transport exists only in a _test.go file. Production always uses the
// pinned-public-IP transport; no environment variable enables loopback access.
type auxIsolatedTransport struct {
	destinations map[string]string
	calls        atomic.Int64
}

func (tr *auxIsolatedTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	tr.calls.Add(1)
	if req.Header.Get("Authorization") != "" {
		return nil, errors.New("owner credentials crossed origin")
	}
	target, ok := tr.destinations[req.URL.Host]
	if !ok {
		return nil, errors.New("unregistered isolated test server")
	}
	base, _ := url.Parse(target)
	clone := req.Clone(req.Context())
	copyURL := *req.URL
	clone.URL = &copyURL
	clone.URL.Scheme, clone.URL.Host = base.Scheme, base.Host
	clone.Header.Set("X-Forwarded-Proto", "https")
	clone.Header.Set("X-Forwarded-Host", req.URL.Host)
	return http.DefaultTransport.RoundTrip(clone)
}

type auxTransferFixture struct {
	source, destination         *Server
	sourceHTTP, destinationHTTP *httptest.Server
	transport                   *auxIsolatedTransport
	active                      atomic.Bool
}

func newAuxTransferFixture(t *testing.T) *auxTransferFixture {
	t.Helper()
	f := &auxTransferFixture{}
	f.active.Store(true)
	var err error
	f.source, err = Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	f.destination, err = Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	f.source.now = func() time.Time { return time.Unix(1000, 0) }
	f.destination.now = f.source.now
	f.sourceHTTP = httptest.NewServer(f.source.HandlerWithOptions(HandlerOptions{AuthToken: "source-owner-test"}))
	handler := f.destination.HandlerWithOptions(HandlerOptions{AuthToken: "destination-owner-test"})
	f.destinationHTTP = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/v2/aux/sessions/isolated-session/status" {
			writeJSON(w, 200, map[string]any{"active": f.active.Load(), "expires_at": int64(9000)})
			return
		}
		handler.ServeHTTP(w, r)
	}))
	f.transport = &auxIsolatedTransport{destinations: map[string]string{"source.example": f.sourceHTTP.URL, "destination.example": f.destinationHTTP.URL}}
	client := &http.Client{Transport: f.transport, Timeout: time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("redirect blocked") }}
	f.source.auxTransferHTTPClient = client
	f.destination.auxTransferHTTPClient = client
	t.Cleanup(func() { f.sourceHTTP.Close(); f.destinationHTTP.Close(); f.source.Close(); f.destination.Close() })
	return f
}
func (f *auxTransferFixture) track(t *testing.T, fp string) {
	t.Helper()
	ctx := context.Background()
	track := Track{ID: "source-private-id", Fingerprint: fp, Title: "Shared song", Artist: "Artist", Album: "Album", IsLiked: true, PlaylistIDs: []string{"private-playlist"}, SourceURLs: map[string]string{"private": "never-share"}}
	if err := f.source.upsertTrack(ctx, track); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(f.source.audioPath(fp), []byte("isolated audio bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := f.source.attachMediaPath(ctx, fp, "audio_path", f.source.audioPath(fp), 20); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(f.source.artworkPath(fp), []byte("isolated cover bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := f.source.attachMediaPath(ctx, fp, "artwork_path", f.source.artworkPath(fp), 0); err != nil {
		t.Fatal(err)
	}
}
func (f *auxTransferFixture) grant(t *testing.T, fp string, copy bool) AuxTransferGrant {
	t.Helper()
	g, err := f.source.createAuxTransferGrant(context.Background(), AuxTransferGrantRequest{Fingerprint: fp, SessionID: "isolated-session", SessionOrigin: "https://destination.example", DestinationOrigin: "https://destination.example", AllowCopy: copy}, "https://source.example")
	if err != nil {
		t.Fatal(err)
	}
	return g
}
func transferRequest(g AuxTransferGrant, id string) AuxTransferRequest {
	return AuxTransferRequest{OperationID: id, Grant: AuxTransferReference{SourceOrigin: g.SourceOrigin, Token: g.Token}, SessionID: g.SessionID, SessionOrigin: g.SessionOrigin}
}
func TestAuxTransferDurableAdditiveAndPlaylistRetry(t *testing.T) {
	f := newAuxTransferFixture(t)
	f.track(t, "exact-song")
	g := f.grant(t, "exact-song", true)
	ctx := context.Background()
	raw, _ := json.Marshal(g)
	if strings.Contains(string(raw), "private") || strings.Contains(string(raw), "is_liked") {
		t.Fatalf("private metadata in grant: %s", raw)
	}
	req := transferRequest(g, "save-one")
	req.PlaylistID = "not-created-yet"
	out, err := f.destination.transferAuxTrack(ctx, req, "https://destination.example")
	if err != nil || out.Status != "playlist_failed" {
		t.Fatalf("copy then playlist failure: %+v %v", out, err)
	}
	if state, _, _ := f.destination.auxMembership(ctx, "exact-song"); state != "present" {
		t.Fatalf("copy not durable: %s", state)
	}
	// Once committed, the copy and playlist-only retry are independent of source.
	f.active.Store(false)
	f.sourceHTTP.Close()
	calls := f.transport.calls.Load()
	if err = f.destination.upsertPlaylist(ctx, Playlist{ID: req.PlaylistID, Name: "My private list", TrackIDs: []string{"older-track"}}); err != nil {
		t.Fatal(err)
	}
	out, err = f.destination.transferAuxTrack(ctx, req, "https://destination.example")
	if err != nil || out.Status != "saved" || !out.PlaylistAdded {
		t.Fatalf("playlist-only retry: %+v %v", out, err)
	}
	if f.transport.calls.Load() != calls {
		t.Fatal("playlist retry contacted expired source")
	}
	for i := 0; i < 3; i++ {
		if _, err = f.destination.transferAuxTrack(ctx, req, "https://destination.example"); err != nil {
			t.Fatal(err)
		}
	}
	playlist, _ := f.destination.playlistByID(ctx, req.PlaylistID)
	if len(playlist.TrackIDs) != 2 || playlist.TrackIDs[0] != "older-track" || playlist.TrackIDs[1] != out.TrackID {
		t.Fatalf("playlist changed order/duplicates: %+v", playlist)
	}
	tracks, _ := f.destination.tracks(ctx, "")
	if len(tracks) != 1 || tracks[0].IsLiked || len(tracks[0].SourceURLs) > 0 {
		t.Fatalf("copy polluted personal metadata: %+v", tracks)
	}
	audio, _ := f.destination.mediaPath(ctx, g.Fingerprint, "audio_path")
	data, _ := os.ReadFile(audio)
	if string(data) != "isolated audio bytes" {
		t.Fatal("not a durable local copy")
	}
	req.Grant.Token = "auxg_" + strings.Repeat("0", 48)
	if _, err = f.destination.transferAuxTrack(ctx, req, "https://destination.example"); err == nil {
		t.Fatal("id reused for different grant")
	}
}
func TestAuxTransferPreservesExistingAndRepairsMissing(t *testing.T) {
	f := newAuxTransferFixture(t)
	ctx := context.Background()
	f.track(t, "matched")
	g := f.grant(t, "matched", true)
	local := Track{ID: "my-local-id", Fingerprint: "matched", Title: "My edits", Artist: "My artist", Album: "My album", IsLiked: true}
	if err := f.destination.upsertTrack(ctx, local); err != nil {
		t.Fatal(err)
	}
	cover := f.destination.artworkPath("matched")
	os.WriteFile(cover, []byte("my cover"), 0600)
	f.destination.attachMediaPath(ctx, "matched", "artwork_path", cover, 0)
	state, _, _ := f.destination.auxMembership(ctx, "matched")
	if state != "repair" {
		t.Fatalf("missing audio must be repair, got %s", state)
	}
	out, err := f.destination.transferAuxTrack(ctx, transferRequest(g, "repair"), "https://destination.example")
	if err != nil || out.TrackID != "my-local-id" {
		t.Fatalf("repair %+v %v", out, err)
	}
	tracks, _ := f.destination.tracks(ctx, "")
	if tracks[0].Title != "My edits" || !tracks[0].IsLiked {
		t.Fatal("existing metadata or like overwritten")
	}
	data, _ := os.ReadFile(cover)
	if string(data) != "my cover" {
		t.Fatal("existing cover overwritten")
	}
	audio, _ := f.destination.mediaPath(ctx, "matched", "audio_path")
	os.WriteFile(audio, []byte("my different master"), 0600)
	_, err = f.destination.transferAuxTrack(ctx, transferRequest(g, "another-save"), "https://destination.example")
	if err != nil {
		t.Fatal(err)
	}
	data, _ = os.ReadFile(audio)
	if string(data) != "my different master" {
		t.Fatal("existing audio overwritten by same logical fingerprint")
	}
}
func TestAuxTransferPermissionsExpiryEndOfflineCancelAndConcurrency(t *testing.T) {
	f := newAuxTransferFixture(t)
	ctx := context.Background()
	f.track(t, "track")
	denied := f.grant(t, "track", false)
	if _, err := f.destination.transferAuxTrack(ctx, transferRequest(denied, "denied"), "https://destination.example"); err == nil {
		t.Fatal("copy permission defaults off")
	}
	g := f.grant(t, "track", true)
	wrong := transferRequest(g, "wrong-session")
	wrong.SessionID = "different"
	if _, err := f.destination.transferAuxTrack(ctx, wrong, "https://destination.example"); err == nil {
		t.Fatal("wrong session accepted")
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := f.destination.transferAuxTrack(cancelled, transferRequest(g, "cancelled"), "https://destination.example"); err == nil {
		t.Fatal("cancelled save succeeded")
	}
	if state, _, _ := f.destination.auxMembership(ctx, "track"); state != "absent" {
		t.Fatal("cancelled transfer left partial track")
	}
	f.active.Store(false)
	if _, err := f.destination.transferAuxTrack(ctx, transferRequest(g, "ended"), "https://destination.example"); err == nil {
		t.Fatal("session end not enforced")
	}
	f.active.Store(true)
	oldNow := f.source.now
	f.source.now = func() time.Time { return time.Unix(g.ExpiresAt, 0) }
	if _, err := f.destination.transferAuxTrack(ctx, transferRequest(g, "expired"), "https://destination.example"); err == nil {
		t.Fatal("expired grant accepted")
	}
	f.source.now = oldNow
	var wg sync.WaitGroup
	errs := make(chan error, 4)
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := f.destination.transferAuxTrack(ctx, transferRequest(g, "same-operation"), "https://destination.example")
			errs <- err
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	tracks, _ := f.destination.tracks(ctx, "")
	if len(tracks) != 1 {
		t.Fatal("concurrent duplicate tracks")
	}
	f.source.db.ExecContext(ctx, `UPDATE aux_transfer_grants SET revoked=1 WHERE token_hash=?`, auxHash(g.Token))
	if _, err := f.destination.transferAuxTrack(ctx, transferRequest(g, "revoked"), "https://destination.example"); err == nil {
		t.Fatal("revoked permission accepted")
	}
	f.sourceHTTP.Close()
	if _, err := f.destination.transferAuxTrack(ctx, transferRequest(g, "offline"), "https://destination.example"); err == nil {
		t.Fatal("offline source reported success")
	}
}
func TestAuxTransferRejectsChangedBytesAndForgedFields(t *testing.T) {
	f := newAuxTransferFixture(t)
	f.track(t, "track")
	g := f.grant(t, "track", true)
	if _, err := f.destination.validateAuxTransferGrant(context.Background(), AuxTransferReference{g.SourceOrigin, g.Token}, g.SessionID, g.SessionOrigin); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(f.source.audioPath("track"), []byte("changed source bytes"), 0600)
	if _, err := f.destination.transferAuxTrack(context.Background(), transferRequest(g, "changed"), "https://destination.example"); err == nil {
		t.Fatal("changed bytes accepted")
	}
	if state, _, _ := f.destination.auxMembership(context.Background(), "track"); state != "absent" {
		t.Fatal("failed copy left metadata")
	}
	// Owner is required for both creating capabilities and personal writes.
	for _, path := range []string{"/api/v2/aux/grants", "/api/v2/aux/transfers"} {
		res, err := http.Post(f.sourceHTTP.URL+path, "application/json", strings.NewReader(`{}`))
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		if res.StatusCode != 401 {
			t.Fatalf("unauthenticated write %s = %d", path, res.StatusCode)
		}
	}
}
func TestAuxTransferProductionSSRFPolicy(t *testing.T) {
	for _, ip := range []string{"127.0.0.1", "10.0.0.1", "172.16.0.1", "192.168.0.1", "169.254.169.254", "100.64.1.1", "::1", "fc00::1", "fe80::1", "::ffff:127.0.0.1", "64:ff9b::7f00:1", "198.18.0.1"} {
		if auxPublicIP(net.ParseIP(ip)) {
			t.Errorf("allowed private/special address %s", ip)
		}
	}
	if !auxPublicIP(net.ParseIP("8.8.8.8")) {
		t.Fatal("public address rejected")
	}
	for _, origin := range []string{"http://example.com", "https://example.com:8443", "https://owner:token@example.com", "https://example.com/private", "https://example.com?token=secret"} {
		if _, err := auxOrigin(origin); err == nil {
			t.Errorf("unsafe origin allowed %s", origin)
		}
	}
	client := newAuxTransferHTTPClient()
	if _, err := client.Get("https://127.0.0.1/secret"); err == nil {
		t.Fatal("production connected to loopback")
	}
	if err := client.CheckRedirect(&http.Request{}, nil); err == nil {
		t.Fatal("production permits source redirects")
	}
}

func TestAuxTransferRejectsOversizedAndUnknownRequestFields(t *testing.T) {
	f := newAuxTransferFixture(t)
	for _, body := range []string{`{"fingerprint":"song","owner_token":"no"}`, `{"fingerprint":"` + strings.Repeat("x", 20<<10) + `"}`} {
		req, _ := http.NewRequest("POST", f.sourceHTTP.URL+"/api/v2/aux/grants", bytes.NewBufferString(body))
		req.Header.Set("Authorization", "Bearer source-owner-test")
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		io.Copy(io.Discard, res.Body)
		res.Body.Close()
		if res.StatusCode != 400 {
			t.Fatalf("unbounded/unknown input status %d", res.StatusCode)
		}
	}
}

func TestAuxTransferDestinationTicketRevocationAndRestart(t *testing.T) {
	f := newAuxTransferFixture(t)
	f.track(t, "ticket-song")
	g := f.grant(t, "ticket-song", true)
	f.transport.destinations["personal.example"] = f.destinationHTTP.URL
	child, err := f.destination.resolveAuxTransferGrant(context.Background(), AuxTransferReference{g.SourceOrigin, g.Token}, g.SessionID, g.SessionOrigin, "https://personal.example", "copy")
	if err != nil {
		t.Fatal(err)
	}
	if child.Token == g.Token || child.DestinationOrigin != "https://personal.example" {
		t.Fatal("copy ticket not bound to destination")
	}
	if _, err = f.destination.resolveAuxTransferGrant(context.Background(), AuxTransferReference{child.SourceOrigin, child.Token}, g.SessionID, g.SessionOrigin, "https://another.example", "copy"); err == nil {
		t.Fatal("copy ticket reused for another destination")
	}
	f.source.db.ExecContext(context.Background(), `UPDATE aux_transfer_grants SET revoked=1 WHERE token_hash=?`, auxHash(g.Token))
	if _, err = f.source.loadAuxTransferGrant(context.Background(), child.Token); err == nil {
		t.Fatal("child survived parent revoke")
	}
	fresh := f.grant(t, "ticket-song", true)
	req := transferRequest(fresh, "persisted-save")
	out, err := f.destination.transferAuxTrack(context.Background(), req, "https://personal.example")
	if err != nil {
		t.Fatal(err)
	}
	// A reopened destination recognizes a completed operation even with no source.
	reopened, err := Open(f.destination.dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	replay, err := reopened.transferAuxTrack(context.Background(), req, "https://personal.example")
	if err != nil || replay.TrackID != out.TrackID {
		t.Fatalf("reopen idempotency %+v %v", replay, err)
	}
}

func auxTransferAPI(t *testing.T, base, method, path, token string, body any, want int, out any) {
	t.Helper()
	var reader io.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		reader = bytes.NewReader(raw)
	}
	req, _ := http.NewRequest(method, base+path, reader)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Forwarded-Proto", "https")
	req.Header.Set("X-Forwarded-Host", "destination.example")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	if res.StatusCode != want {
		t.Fatalf("%s %s got %d want %d: %s", method, path, res.StatusCode, want, raw)
	}
	if out != nil {
		if err = json.Unmarshal(raw, out); err != nil {
			t.Fatal(err)
		}
	}
}
func TestAuxTransferForeignQueueBothModes(t *testing.T) {
	for _, mode := range []string{"shared_speaker", "listen_together"} {
		t.Run(mode, func(t *testing.T) {
			f := newAuxTransferFixture(t)
			f.track(t, "foreign-selected")
			var created struct {
				SessionID    string `json:"session_id"`
				InviteSecret string `json:"invite_secret"`
			}
			auxTransferAPI(t, f.destinationHTTP.URL, "POST", "/api/v2/aux/sessions", "destination-owner-test", map[string]any{"mode": mode, "host_device_id": "host-output", "catalog_fingerprints": []string{}, "allow_contributions": true, "allow_saves": false}, 201, &created)
			var joined struct {
				ParticipantToken string `json:"participant_token"`
				ParticipantID    string `json:"participant_id"`
			}
			auxTransferAPI(t, f.destinationHTTP.URL, "POST", "/api/v2/aux/join", "", map[string]string{"invite_secret": created.InviteSecret, "display_name": "Guest"}, 200, &joined)
			g, err := f.source.createAuxTransferGrant(context.Background(), AuxTransferGrantRequest{Fingerprint: "foreign-selected", SessionID: created.SessionID, SessionOrigin: "https://destination.example", DestinationOrigin: "https://destination.example", AllowCopy: true}, "https://source.example")
			if err != nil {
				t.Fatal(err)
			}
			ref := AuxTransferReference{g.SourceOrigin, g.Token}
			var state AuxV2State
			path := "/api/v2/aux/sessions/" + created.SessionID
			// A valid source capability cannot endorse a guest's different fingerprint.
			auxTransferAPI(t, f.destinationHTTP.URL, "POST", path+"/commands", joined.ParticipantToken, map[string]any{"command_id": "forged", "kind": "append", "fingerprint": "forged", "grant": ref}, 400, nil)
			auxTransferAPI(t, f.destinationHTTP.URL, "POST", path+"/commands", joined.ParticipantToken, map[string]any{"command_id": "foreign-one", "kind": "append", "fingerprint": g.Fingerprint, "grant": ref}, 200, &state)
			var track AuxV2Track
			if len(state.Queue) > 0 {
				track = state.Queue[0].Track
			} else if state.Current != nil {
				track = state.Current.Track
			} else {
				t.Fatal("foreign track missing from shared queue")
			}
			if !strings.HasPrefix(track.MediaURL, path+"/tracks/") || track.Grant != nil || strings.Contains(track.MediaURL, g.Token) {
				t.Fatalf("queue did not use verified source: %+v", track)
			}
			mediaReq, _ := http.NewRequest("GET", f.destinationHTTP.URL+track.MediaURL, nil)
			mediaReq.Header.Set("Authorization", "Bearer "+joined.ParticipantToken)
			res, err := http.DefaultClient.Do(mediaReq)
			if err != nil {
				t.Fatal(err)
			}
			data, _ := io.ReadAll(res.Body)
			res.Body.Close()
			if res.StatusCode != 200 || string(data) != "isolated audio bytes" {
				t.Fatal("source stream unavailable in mode " + mode)
			}
			if res.Header.Get("Cache-Control") != "private, no-store" {
				t.Fatal("shared source media is cacheable")
			}
			mediaReq.Header.Set("Range", "bytes=0-7")
			ranged, e := http.DefaultClient.Do(mediaReq)
			if e != nil {
				t.Fatal(e)
			}
			rangedBytes, _ := io.ReadAll(ranged.Body)
			ranged.Body.Close()
			if ranged.StatusCode != 206 || string(rangedBytes) != "isolated" {
				t.Fatalf("range proxy: %d %q", ranged.StatusCode, rangedBytes)
			}
			var copyRef AuxTransferReference
			auxTransferAPI(t, f.destinationHTTP.URL, "POST", path+"/tracks/"+g.Fingerprint+"/copy-grant", joined.ParticipantToken, map[string]string{"destination_origin": "https://destination.example"}, 200, &copyRef)
			req := transferRequest(g, "save-from-queue")
			req.Grant = copyRef
			var saved AuxTransferResult
			auxTransferAPI(t, f.destinationHTTP.URL, "POST", "/api/v2/aux/transfers", joined.ParticipantToken, req, 403, nil)
			auxTransferAPI(t, f.destinationHTTP.URL, "POST", "/api/v2/aux/transfers", "destination-owner-test", req, 200, &saved)
			auxTransferAPI(t, f.destinationHTTP.URL, "DELETE", path+"/members/"+joined.ParticipantID, "destination-owner-test", nil, 204, nil)
			if _, err = f.source.loadAuxTransferGrant(context.Background(), copyRef.Token); err == nil {
				t.Fatal("removed member retained source copy ticket")
			}
			auxTransferAPI(t, f.destinationHTTP.URL, "GET", track.MediaURL, joined.ParticipantToken, nil, 401, nil)
			if _, err = f.source.loadAuxTransferGrant(context.Background(), g.Token); err != nil {
				t.Fatalf("member removal revoked source owner instead: %v", err)
			}
			auxTransferAPI(t, f.destinationHTTP.URL, "DELETE", path, "destination-owner-test", nil, 204, nil)
			if _, err = f.source.loadAuxTransferGrant(context.Background(), g.Token); err == nil {
				t.Fatal("ended real Aux session still permitted source listening")
			}
			if status, _, _ := f.destination.auxMembership(context.Background(), g.Fingerprint); status != "present" {
				t.Fatal("session end deleted durable personal copy")
			}
		})
	}
}

func TestAuxTransferExistingPlaylistUsesActualLocalIDWithoutSource(t *testing.T) {
	f := newAuxTransferFixture(t)
	ctx := context.Background()
	f.destination.upsertTrack(ctx, Track{ID: "custom-local-id", Fingerprint: "existing", Title: "Personal edit", IsLiked: true})
	audio := f.destination.audioPath("existing")
	os.WriteFile(audio, []byte("personal audio"), 0600)
	f.destination.attachMediaPath(ctx, "existing", "audio_path", audio, 14)
	f.destination.upsertPlaylist(ctx, Playlist{ID: "personal-list", Name: "Private playlist", TrackIDs: []string{"first"}})
	f.sourceHTTP.Close()
	for i := 0; i < 2; i++ {
		auxTransferAPI(t, f.destinationHTTP.URL, "POST", "/api/v2/aux/membership/existing/playlist", "destination-owner-test", map[string]string{"playlist_id": "personal-list"}, 200, nil)
	}
	playlist, err := f.destination.playlistByID(ctx, "personal-list")
	if err != nil || len(playlist.TrackIDs) != 2 || playlist.TrackIDs[1] != "custom-local-id" {
		t.Fatalf("wrong personal membership: %+v %v", playlist, err)
	}
	if f.transport.calls.Load() != 0 {
		t.Fatal("existing copy contacted source for permission")
	}
}

type auxRoundTripFunc func(*http.Request) (*http.Response, error)

func (f auxRoundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestAuxTransferNeverUsesSourceSuppliedURLs(t *testing.T) {
	f := newAuxTransferFixture(t)
	f.track(t, "url-claim")
	g := f.grant(t, "url-claim", true)
	f.destination.auxTransferHTTPClient = &http.Client{Timeout: time.Second, Transport: auxRoundTripFunc(func(req *http.Request) (*http.Response, error) {
		response, err := f.transport.RoundTrip(req)
		if err != nil {
			return nil, err
		}
		if req.URL.Path == "/api/v2/aux/grants/resolve" && response.StatusCode == 200 {
			raw, _ := io.ReadAll(response.Body)
			response.Body.Close()
			var descriptor AuxTransferGrant
			json.Unmarshal(raw, &descriptor)
			descriptor.MediaURL = "https://169.254.169.254/credentials"
			descriptor.ArtworkURL = "https://private.invalid/private"
			raw, _ = json.Marshal(descriptor)
			response.Body = io.NopCloser(bytes.NewReader(raw))
			response.ContentLength = int64(len(raw))
		}
		return response, nil
	})}
	out, err := f.destination.transferAuxTrack(context.Background(), transferRequest(g, "reconstruct-urls"), "https://destination.example")
	if err != nil || out.Status != "saved" {
		t.Fatalf("did not use reconstructed verified endpoints: %+v %v", out, err)
	}
}

func TestAuxTransferSourceGrantStorageBoundAndCleanup(t *testing.T) {
	f := newAuxTransferFixture(t)
	f.track(t, "bounded-grants")
	g := f.grant(t, "bounded-grants", true)
	raw, _ := json.Marshal(g)
	_, err := f.source.db.Exec(`WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<4999) INSERT INTO aux_transfer_grants(token_hash,descriptor) SELECT 'fixture_'||x,? FROM n`, string(raw))
	if err != nil {
		t.Fatal(err)
	}
	req := g.AuxTransferGrantRequest
	if _, err = f.source.createAuxTransferGrant(context.Background(), req, g.SourceOrigin); err == nil {
		t.Fatal("source grant table exceeded hard bound")
	}
	f.source.db.Exec(`UPDATE aux_transfer_grants SET revoked=1 WHERE token_hash='fixture_1'`)
	if _, err = f.source.createAuxTransferGrant(context.Background(), req, g.SourceOrigin); err != nil {
		t.Fatalf("revoked grant not reclaimed: %v", err)
	}
	f.source.db.Exec(`UPDATE aux_transfer_grants SET descriptor=json_set(descriptor,'$.expires_at',0)`)
	if _, err = f.source.createAuxTransferGrant(context.Background(), req, g.SourceOrigin); err != nil {
		t.Fatalf("expired grants not reclaimed: %v", err)
	}
	var count int
	f.source.db.QueryRow(`SELECT COUNT(*) FROM aux_transfer_grants`).Scan(&count)
	if count != 1 {
		t.Fatalf("expired grant count = %d", count)
	}
}
