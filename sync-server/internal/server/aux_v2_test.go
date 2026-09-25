package server

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type auxV2Fixture struct {
	t                                          *testing.T
	s                                          *Server
	handler                                    http.Handler
	now                                        atomic.Int64
	id, secret, token, member, token2, member2 string
}

func newAuxV2Fixture(t *testing.T, mode string) *auxV2Fixture {
	t.Helper()
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	f := &auxV2Fixture{t: t, s: s}
	f.now.Store(1000000)
	s.now = func() time.Time { return time.UnixMilli(f.now.Load()) }
	f.handler = s.HandlerWithOptions(HandlerOptions{AuthToken: "owner"})
	t.Cleanup(func() { s.Close() })
	duration := float64(60)
	for _, fp := range []string{"one", "two", "private"} {
		if err = s.upsertTrack(context.Background(), Track{Fingerprint: fp, Title: fp, Artist: "Artist", Album: "Album", DurationSeconds: &duration, IsLiked: true, SourceURLs: map[string]string{"private": "https://private.invalid/song"}, PlaylistIDs: []string{"secret-list"}}); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(s.dataDir, "audio", fp+".mp3")
		os.WriteFile(path, []byte("fake-mp3-"+fp), 0600)
		if err = s.attachMediaPath(context.Background(), fp, "audio_path", path, 12); err != nil {
			t.Fatal(err)
		}
	}
	device := "host-device"
	_, _, err = s.applyPlaybackCommandV2(context.Background(), PlaybackCommandV2{CommandID: "seed", Kind: "play", DeviceID: device, TargetDeviceID: &device, Track: &TrackReference{Fingerprint: "one", ID: "track_one"}})
	if err != nil {
		t.Fatal(err)
	}
	w := f.do("POST", "/api/v2/aux/sessions", "owner", map[string]any{"mode": mode, "host_device_id": device, "host_name": "Host", "catalog_fingerprints": []string{"one", "two"}})
	if w.Code != 201 {
		t.Fatalf("create %d %s", w.Code, w.Body.String())
	}
	var created struct {
		SessionID    string `json:"session_id"`
		InviteSecret string `json:"invite_secret"`
	}
	json.Unmarshal(w.Body.Bytes(), &created)
	f.id = created.SessionID
	f.secret = created.InviteSecret
	f.token, f.member = f.join("First")
	f.token2, f.member2 = f.join("Second")
	return f
}
func (f *auxV2Fixture) do(method, path, token string, body any) *httptest.ResponseRecorder {
	f.t.Helper()
	raw, _ := json.Marshal(body)
	r := httptest.NewRequest(method, path, strings.NewReader(string(raw)))
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	f.handler.ServeHTTP(w, r)
	return w
}
func (f *auxV2Fixture) join(name string) (string, string) {
	f.t.Helper()
	w := f.do("POST", "/api/v2/aux/join", "", map[string]string{"invite_secret": f.secret, "display_name": name})
	if w.Code != 200 {
		f.t.Fatalf("join %d %s", w.Code, w.Body.String())
	}
	var out struct {
		Token  string `json:"participant_token"`
		Member string `json:"participant_id"`
	}
	json.Unmarshal(w.Body.Bytes(), &out)
	return out.Token, out.Member
}
func (f *auxV2Fixture) state(token string) AuxV2State {
	f.t.Helper()
	w := f.do("GET", "/api/v2/aux/sessions/"+f.id+"/state", token, nil)
	if w.Code != 200 {
		f.t.Fatalf("state %d %s", w.Code, w.Body.String())
	}
	var st AuxV2State
	if err := json.Unmarshal(w.Body.Bytes(), &st); err != nil {
		f.t.Fatal(err)
	}
	return st
}
func (f *auxV2Fixture) command(token string, req auxV2Command) *httptest.ResponseRecorder {
	return f.do("POST", "/api/v2/aux/sessions/"+f.id+"/commands", token, req)
}
func (f *auxV2Fixture) okCommand(token string, req auxV2Command) AuxV2State {
	f.t.Helper()
	w := f.command(token, req)
	if w.Code != 200 {
		f.t.Fatalf("command %s %d %s", req.Kind, w.Code, w.Body.String())
	}
	var st AuxV2State
	json.Unmarshal(w.Body.Bytes(), &st)
	return st
}
func TestAuxV2ScopePrivacyAndOutput(t *testing.T) {
	f := newAuxV2Fixture(t, "listen_together")
	if f.token == f.token2 || f.member == f.member2 {
		t.Fatal("participant credentials reused")
	}
	st := f.state(f.token)
	if st.Role != "guest" || st.HostDeviceID != "" || st.MediaToken != "" || len(st.Members) != 0 {
		t.Fatalf("guest leaked owner fields: %+v", st)
	}
	owner := f.state("owner")
	if owner.HostDeviceID != "host-device" || owner.Role != "host" || len(owner.Members) != 2 || !strings.HasPrefix(owner.MediaToken, "auxm_") {
		t.Fatalf("owner state incomplete: %+v", owner)
	}
	global, _ := f.s.playbackStateV2(context.Background())
	if global.ActiveDeviceID == nil || *global.ActiveDeviceID != "host-device" || global.Revision != 1 {
		t.Fatal("joining changed owner playback")
	}
	for _, path := range []string{"/api/v1/library", "/api/v1/sync/snapshot", "/api/v1/export", "/api/v2/playback", "/api/v2/playback/events", "/api/v1/playback/devices", "/api/v1/tracks/private/audio", "/api/v2/aux/sessions", "/api/v2/aux/membership/one"} {
		w := f.do("GET", path, f.token, nil)
		if w.Code != 403 {
			t.Fatalf("guest %s: %d", path, w.Code)
		}
	}
	for _, path := range []string{"/api/v2/playback/commands", "/api/v1/auth/stream-token", "/api/v1/media-grants", "/api/v2/aux/sessions", "/api/v2/aux/grants", "/api/v2/aux/transfers"} {
		w := f.do("POST", path, f.token, map[string]any{"device_id": "host-device", "kind": "transfer"})
		if w.Code != 403 {
			t.Fatalf("guest write %s: %d", path, w.Code)
		}
	}
	w := f.do("PUT", "/api/v1/playback/devices/host-device", f.token, map[string]any{"name": "spoof"})
	if w.Code != 403 {
		t.Fatal("device spoof accepted")
	}
	for _, suffix := range []string{"state", "catalog"} {
		w = f.do("GET", "/api/v2/aux/sessions/"+f.id+"/"+suffix, f.token, nil)
		for _, secret := range []string{"source_urls", "playlist_ids", "is_liked", "path\"", "private.invalid", "private\"", "host-device", "First", "Second"} {
			if strings.Contains(w.Body.String(), secret) {
				t.Fatalf("%s leaked %s", suffix, secret)
			}
		}
		if w.Header().Get("Cache-Control") != "no-store" {
			t.Fatal("shared JSON cacheable")
		}
	}
	for _, token := range []string{f.token, owner.MediaToken} {
		w = f.do("HEAD", "/api/v2/aux/sessions/"+f.id+"/tracks/one/audio", token, nil)
		if w.Code != 200 || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatalf("media %d %s", w.Code, w.Body.String())
		}
		w = f.do("GET", "/api/v2/aux/sessions/"+f.id+"/tracks/private/audio", token, nil)
		if w.Code != 403 {
			t.Fatal("private media readable")
		}
	}
	for _, path := range []string{"/api/v1/library", "/api/v2/aux/sessions/" + f.id + "/state"} {
		if w = f.do("GET", path, owner.MediaToken, nil); w.Code != 401 {
			t.Fatal("media token authorized API")
		}
	}
	var hashes string
	rows, _ := f.s.db.Query(`SELECT token_hash FROM aux_v2_members`)
	for rows.Next() {
		var h string
		rows.Scan(&h)
		hashes += h
	}
	rows.Close()
	if strings.Contains(hashes, f.token) || !strings.Contains(hashes, auxV2Hash(f.token)) {
		t.Fatal("credentials not hashed")
	}
}
func TestAuxV2QueueOwnershipRevisionAndRetries(t *testing.T) {
	f := newAuxV2Fixture(t, "shared_speaker")
	one := f.okCommand(f.token, auxV2Command{CommandID: "a", Kind: "append", Fingerprint: "one"})
	two := f.okCommand(f.token2, auxV2Command{CommandID: "b", Kind: "append", Fingerprint: "two"})
	if len(two.Queue) != 2 {
		t.Fatal("append lost entry")
	}
	retry := f.okCommand(f.token, auxV2Command{CommandID: "a", Kind: "append", Fingerprint: "one"})
	if len(retry.Queue) != 2 {
		t.Fatal("duplicate append")
	}
	if w := f.command(f.token, auxV2Command{CommandID: "a", Kind: "append", Fingerprint: "two"}); w.Code != 409 {
		t.Fatal("id reuse allowed")
	}
	if w := f.command(f.token, auxV2Command{CommandID: "remove-other", Kind: "remove", EntryID: two.Queue[1].EntryID}); w.Code != 403 {
		t.Fatal("removed other participant entry")
	}
	ids := []string{two.Queue[1].EntryID, two.Queue[0].EntryID}
	reorder := f.okCommand(f.token, auxV2Command{CommandID: "reorder-all", Kind: "reorder", EntryIDs: ids, ExpectedRevision: &two.Revision})
	if reorder.Queue[0].ParticipantID != f.member2 || reorder.Current.EntryID != one.Current.EntryID {
		t.Fatal("reorder changed current or denied all queue")
	}
	if w := f.command(f.token2, auxV2Command{CommandID: "stale", Kind: "reorder", EntryIDs: ids, ExpectedRevision: &two.Revision}); w.Code != 409 {
		t.Fatal("stale reorder accepted")
	}
	if w := f.command(f.token, auxV2Command{CommandID: "remove-via-reorder", Kind: "reorder", EntryIDs: ids[:1], ExpectedRevision: &reorder.Revision}); w.Code != 400 {
		t.Fatal("reorder removed member")
	}
	if w := f.command(f.token, auxV2Command{CommandID: "current-reorder", Kind: "reorder", EntryIDs: []string{reorder.Current.EntryID, ids[1]}, ExpectedRevision: &reorder.Revision}); w.Code != 400 {
		t.Fatal("reorder included current")
	}
	nextReq := auxV2Command{CommandID: "skip", Kind: "next", ExpectedRevision: &reorder.Revision}
	next := f.okCommand(f.token, nextReq)
	retry = f.okCommand(f.token, nextReq)
	if retry.Current.EntryID != next.Current.EntryID || len(retry.Queue) != 1 {
		t.Fatal("duplicate skip advanced twice")
	}
	paused := f.okCommand(f.token2, auxV2Command{CommandID: "pause", Kind: "pause"})
	if paused.Status != "paused" {
		t.Fatal("guest pause failed")
	}
	resumed := f.okCommand(f.token, auxV2Command{CommandID: "resume", Kind: "resume"})
	if resumed.Status != "playing" {
		t.Fatal("guest resume failed")
	}
	for _, kind := range []string{"seek", "previous", "volume", "transfer", "set_queue", "set_shuffle", "set_repeat"} {
		if w := f.command(f.token, auxV2Command{CommandID: "forbidden-" + kind, Kind: kind}); w.Code != 400 {
			t.Fatalf("unexpected command %s accepted", kind)
		}
	}
	if w := f.do("POST", "/api/v2/aux/sessions/"+f.id+"/commands", f.token, map[string]any{"command_id": "spoof", "kind": "pause", "device_id": "host-device"}); w.Code != 400 {
		t.Fatal("spoof field accepted")
	}
}
func TestAuxV2TimelineAndConcurrentAppend(t *testing.T) {
	f := newAuxV2Fixture(t, "listen_together")
	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			w := f.command(f.token, auxV2Command{CommandID: fmt.Sprint("parallel-", i), Kind: "append", Fingerprint: "two"})
			if w.Code != 200 {
				t.Errorf("parallel append: %d %s", w.Code, w.Body.String())
			}
		}(i)
	}
	wg.Wait()
	before := f.state(f.token)
	if len(before.Queue) != 12 {
		t.Fatal("concurrent requests lost")
	}
	f.now.Add(65000)
	after := f.state(f.token)
	if after.Current.Track.Fingerprint != "two" || len(after.Queue) != 11 || after.PositionSeconds < 4.9 || after.PositionSeconds > 5.1 {
		t.Fatalf("timeline failed: %+v", after)
	}
	other := f.state(f.token2)
	if other.Revision != after.Revision || other.Current.EntryID != after.Current.EntryID {
		t.Fatal("each listener advanced independently")
	}
	if w := f.command(f.token, auxV2Command{CommandID: "stale-skip", Kind: "next", ExpectedRevision: &before.Revision}); w.Code != 409 {
		t.Fatal("stale pre-advance skip applied")
	}
}
func TestAuxV2InviteRevocationExpiryAndRestart(t *testing.T) {
	f := newAuxV2Fixture(t, "shared_speaker")
	path := "/api/v2/aux/sessions/" + f.id
	f.now.Add(15 * 60 * 1000)
	if w := f.do("POST", "/api/v2/aux/join", "", map[string]string{"invite_secret": f.secret}); w.Code != 404 {
		t.Fatal("expired invite joined")
	}
	f.state(f.token)
	if w := f.do("POST", path+"/invite", f.token, nil); w.Code != 403 {
		t.Fatal("guest renewed invite")
	}
	w := f.do("POST", path+"/invite", "owner", nil)
	if w.Code != 200 {
		t.Fatal("renew failed")
	}
	var out map[string]any
	json.Unmarshal(w.Body.Bytes(), &out)
	f.secret = out["invite_secret"].(string)
	if w = f.do("DELETE", path+"/invite", "owner", nil); w.Code != 204 {
		t.Fatal("revoke failed")
	}
	if w = f.do("POST", "/api/v2/aux/join", "", map[string]string{"invite_secret": f.secret}); w.Code != 404 {
		t.Fatal("revoked invite joined")
	}
	f.state(f.token)
	if w = f.do("DELETE", path+"/members/"+f.member, f.token2, nil); w.Code != 403 {
		t.Fatal("guest removed peer")
	}
	if w = f.do("DELETE", path+"/members/"+f.member, "owner", nil); w.Code != 204 {
		t.Fatal("host remove failed")
	}
	if w = f.do("GET", path+"/state", f.token, nil); w.Code != 401 {
		t.Fatal("removed guest retained access")
	}
	f.state(f.token2)
	// Reopening persists the live principal and every revocation; owner rotation
	// changes only owner access. The original registered cleanup closes old s.
	dir := f.s.dataDir
	f.s.Close()
	reopened, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	reopened.now = func() time.Time { return time.UnixMilli(f.now.Load()) }
	f.s = reopened
	f.handler = reopened.HandlerWithOptions(HandlerOptions{AuthToken: "new-owner"})
	f.state(f.token2)
	f.now.Add(24 * 60 * 60 * 1000)
	if w = f.do("GET", path+"/state", f.token2, nil); w.Code != 401 {
		t.Fatal("credential outlived session")
	}
}
func TestAuxV2EndRevokesAndPreservesOwnerState(t *testing.T) {
	f := newAuxV2Fixture(t, "listen_together")
	owner := f.state("owner")
	f.now.Add(10000)
	if w := f.do("DELETE", "/api/v2/aux/sessions/"+f.id, "owner", nil); w.Code != 204 {
		t.Fatalf("end %d %s", w.Code, w.Body.String())
	}
	for _, token := range []string{f.token, owner.MediaToken} {
		w := f.do("GET", "/api/v2/aux/sessions/"+f.id+"/tracks/one/audio", token, nil)
		if w.Code != 401 {
			t.Fatal("ended credential accepted")
		}
	}
	global, _ := f.s.playbackStateV2(context.Background())
	if global.State != "paused" || global.ActiveDeviceID == nil || *global.ActiveDeviceID != "host-device" || global.Track.Fingerprint != "one" || global.Clock.PositionSeconds < 9.9 {
		t.Fatalf("bad post-Aux owner playback %+v", global)
	}
}
func TestAuxV2RateAndBodyBounds(t *testing.T) {
	f := newAuxV2Fixture(t, "shared_speaker")
	for i := 0; i < 31; i++ {
		w := f.do("POST", "/api/v2/aux/join", "", map[string]string{"invite_secret": "invalid"})
		if i == 30 && w.Code != 429 {
			t.Fatal("unbounded joins")
		}
	}
	for i := 0; i < 26; i++ {
		w := f.command(f.token, auxV2Command{CommandID: fmt.Sprint(i), Kind: "append", Fingerprint: "one"})
		if i == 25 && w.Code != 400 {
			t.Fatal("unbounded pending guest requests")
		}
	}
	if w := f.do("POST", "/api/v2/aux/sessions/"+f.id+"/commands", f.token, map[string]string{"command_id": "large", "kind": strings.Repeat("x", 17000)}); w.Code != 400 {
		t.Fatal("large body accepted")
	}
}

func TestAuxV2ScopedEventsAdvanceAndRevoke(t *testing.T) {
	f := newAuxV2Fixture(t, "listen_together")
	httpServer := httptest.NewServer(f.handler)
	defer httpServer.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", httpServer.URL+"/api/v2/aux/sessions/"+f.id+"/events?access_token="+f.token, nil)
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		t.Fatalf("SSE %d", response.StatusCode)
	}
	reader := bufio.NewReader(response.Body)
	frame := func() string {
		t.Helper()
		out := ""
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				t.Fatalf("SSE read: %v (%s)", err, out)
			}
			out += line
			if line == "\n" {
				return out
			}
		}
	}
	if first := frame(); !strings.Contains(first, `"revision":1`) {
		t.Fatalf("initial SSE: %s", first)
	}
	f.okCommand(f.token2, auxV2Command{CommandID: "sse-append", Kind: "append", Fingerprint: "two"})
	if changed := frame(); !strings.Contains(changed, `"revision":2`) {
		t.Fatalf("SSE invalidation: %s", changed)
	}
	f.now.Add(65000)
	if advanced := frame(); !strings.Contains(advanced, `"revision":3`) {
		t.Fatalf("SSE did not own advancement: %s", advanced)
	}
	st := f.state(f.token2)
	if st.Current.Track.Fingerprint != "two" {
		t.Fatal("SSE never advanced timeline")
	}
	if w := f.do("DELETE", "/api/v2/aux/sessions/"+f.id+"/members/"+f.member, "owner", nil); w.Code != 204 {
		t.Fatal("remove failed")
	}
	if ended := frame(); !strings.Contains(ended, "event: ended") {
		t.Fatalf("removed SSE remained active: %s", ended)
	}
}
func TestAuxV2RevocationRecheckedAfterAuthentication(t *testing.T) {
	f := newAuxV2Fixture(t, "shared_speaker")
	r := httptest.NewRequest("POST", "/api/v2/aux/sessions/"+f.id+"/commands", strings.NewReader(`{"command_id":"late","kind":"pause"}`))
	r.SetPathValue("id", f.id)
	r.Header.Set("Authorization", "Bearer "+f.token)
	principal, valid := f.s.auxV2Authenticate(r, f.token)
	if !valid {
		t.Fatal("fixture authentication failed")
	}
	r = r.WithContext(context.WithValue(r.Context(), auxV2PrincipalKey{}, principal))
	f.do("DELETE", "/api/v2/aux/sessions/"+f.id+"/members/"+f.member, "owner", nil)
	w := httptest.NewRecorder()
	f.s.handleAuxV2Command(w, r)
	if w.Code != 401 {
		t.Fatalf("revoked request raced through mutation %d", w.Code)
	}
}
func TestAuxV2ExpiryStopsStaleOwnerTimeline(t *testing.T) {
	f := newAuxV2Fixture(t, "shared_speaker")
	f.now.Add(24 * 60 * 60 * 1000)
	w := f.do("GET", "/api/v2/aux/sessions", "owner", nil)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"sessions":[]`) {
		t.Fatal("expired session remained discoverable")
	}
	global, _ := f.s.playbackStateV2(context.Background())
	if global.State != "stopped" || global.Track != nil || global.ActiveDeviceID == nil || *global.ActiveDeviceID != "host-device" {
		t.Fatal("expiry resurrected pre-Aux song")
	}
}
func TestAuxV2LegacySessionsPurgedOnReopen(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	old, err := s.createAuxSession(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	dir := s.dataDir
	s.Close()
	s, err = Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if s.isAuxGuestToken(old.GuestToken) {
		t.Fatal("legacy credential survived migration")
	}
	w := httptest.NewRecorder()
	r := httptest.NewRequest("POST", "/api/v1/aux/join", strings.NewReader(`{"code":"`+old.Code+`"}`))
	s.HandlerWithOptions(HandlerOptions{AuthToken: "owner"}).ServeHTTP(w, r)
	if w.Code != 410 {
		t.Fatal("legacy invitation did not require update")
	}
}

func TestAuxV2OwnerCredentialPrefixesRemainCompatible(t *testing.T) {
	s, _ := testServer(t)
	for _, token := range []string{"auxp_owner-chosen", "auxm_owner-chosen"} {
		w := httptest.NewRecorder()
		r := httptest.NewRequest("GET", "/api/v1/library", nil)
		r.Header.Set("Authorization", "Bearer "+token)
		s.HandlerWithOptions(HandlerOptions{AuthToken: token}).ServeHTTP(w, r)
		if w.Code != 200 {
			t.Fatalf("configured owner token rejected: %d", w.Code)
		}
	}
}
func TestAuxV2CatalogLargeSelectionAndSmallState(t *testing.T) {
	f := newAuxV2Fixture(t, "shared_speaker")
	f.do("DELETE", "/api/v2/aux/sessions/"+f.id, "owner", nil)
	fingerprints := []string{"one"}
	for i := 0; i < 600; i++ {
		fp := fmt.Sprintf("%064d", i)
		if err := f.s.upsertTrack(context.Background(), Track{Fingerprint: fp, Title: "Catalog song"}); err != nil {
			t.Fatal(err)
		}
		fingerprints = append(fingerprints, fp)
	}
	w := f.do("POST", "/api/v2/aux/sessions", "owner", map[string]any{"mode": "shared_speaker", "host_device_id": "host-device", "catalog_fingerprints": fingerprints})
	if w.Code != 201 {
		t.Fatalf("large explicit catalog: %d %s", w.Code, w.Body.String())
	}
	if len(w.Body.Bytes()) > 3000 {
		t.Fatal("catalog embedded in session state")
	}
	var created struct {
		SessionID string `json:"session_id"`
	}
	json.Unmarshal(w.Body.Bytes(), &created)
	w = f.do("GET", "/api/v2/aux/sessions/"+created.SessionID+"/catalog", "owner", nil)
	var catalog struct {
		Tracks []AuxV2Track `json:"tracks"`
	}
	json.Unmarshal(w.Body.Bytes(), &catalog)
	if len(catalog.Tracks) != 601 {
		t.Fatal("selected catalog truncated")
	}
}

func TestAuxV2OwnerPlaybackEventsDiscoverStartAndEnd(t *testing.T) {
	f := newAuxV2Fixture(t, "shared_speaker")
	if w := f.do("DELETE", "/api/v2/aux/sessions/"+f.id, "owner", nil); w.Code != 204 {
		t.Fatalf("reset initial Aux: %d", w.Code)
	}
	httpServer := httptest.NewServer(f.handler)
	defer httpServer.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	request, _ := http.NewRequestWithContext(ctx, "GET", httpServer.URL+"/api/v2/playback/events", nil)
	request.Header.Set("Authorization", "Bearer owner")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		t.Fatalf("owner SSE status %d", response.StatusCode)
	}
	reader := bufio.NewReader(response.Body)
	awaitAuxChange := func() {
		t.Helper()
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				t.Fatalf("owner SSE did not deliver Aux change: %v", err)
			}
			if !strings.HasPrefix(line, "data:") {
				continue
			}
			var event map[string]any
			if err = json.Unmarshal([]byte(strings.TrimSpace(strings.TrimPrefix(line, "data:"))), &event); err != nil {
				t.Fatal(err)
			}
			if event["type"] != "aux_changed" {
				continue
			}
			if len(event) != 1 {
				t.Fatalf("discovery event leaked session data: %+v", event)
			}
			return
		}
	}
	created := f.do("POST", "/api/v2/aux/sessions", "owner", map[string]any{"mode": "listen_together", "host_device_id": "host-device", "catalog_fingerprints": []string{"one", "two"}})
	if created.Code != 201 {
		t.Fatalf("create: %d %s", created.Code, created.Body.String())
	}
	awaitAuxChange()
	var session struct {
		SessionID    string `json:"session_id"`
		InviteSecret string `json:"invite_secret"`
	}
	if err = json.Unmarshal(created.Body.Bytes(), &session); err != nil {
		t.Fatal(err)
	}
	f.id, f.secret = session.SessionID, session.InviteSecret
	guest, _ := f.join("Guest")
	if w := f.do("GET", "/api/v2/playback/events", guest, nil); w.Code != 403 {
		t.Fatalf("guest reached owner event stream: %d", w.Code)
	}
	if w := f.do("DELETE", "/api/v2/aux/sessions/"+session.SessionID, "owner", nil); w.Code != 204 {
		t.Fatalf("end: %d %s", w.Code, w.Body.String())
	}
	awaitAuxChange()
}
