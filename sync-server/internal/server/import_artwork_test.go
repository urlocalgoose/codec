package server

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

func bundleJSON(t *testing.T, value any) []byte {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}
func bundleDescriptor(file string, data []byte, mime string) map[string]any {
	return map[string]any{"file": file, "sha256": fmt.Sprintf("%x", sha256.Sum256(data)), "mime_type": mime, "width": 8, "height": 8, "source_url": "https://example.invalid/never-fetch"}
}
func importTestBundle(t *testing.T, s *Server, entries map[string][]byte) ImportJob {
	t.Helper()
	var data bytes.Buffer
	writer := zip.NewWriter(&data)
	names := make([]string, 0, len(entries))
	for name := range entries {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		entry, err := writer.CreateHeader(&zip.FileHeader{Name: name, Method: zip.Store})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := entry.Write(entries[name]); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return importTestBundleBytes(t, s, data.Bytes())
}
func importTestBundleBytes(t *testing.T, s *Server, data []byte) ImportJob {
	t.Helper()
	filename := filepath.Join(t.TempDir(), "fixture.loud.zip")
	if err := os.WriteFile(filename, data, 0600); err != nil {
		t.Fatal(err)
	}
	job := ImportJob{ID: newImportJobID(), State: "running"}
	s.runBundleImport(&job, filename)
	return job
}
func bundleLibrary(t *testing.T, s *Server) Library {
	t.Helper()
	snapshot, err := s.snapshot(context.Background(), "https://codec.example")
	if err != nil {
		t.Fatal(err)
	}
	return snapshot.Library
}
func findBundleTrack(t *testing.T, library Library, fp string) Track {
	t.Helper()
	for _, track := range library.Tracks {
		if track.Fingerprint == fp {
			return track
		}
	}
	t.Fatalf("missing track %s", fp)
	return Track{}
}
func findBundlePlaylist(t *testing.T, library Library, name string) Playlist {
	t.Helper()
	for _, p := range library.Playlists {
		if p.Name == name {
			return p
		}
	}
	t.Fatalf("missing playlist %s", name)
	return Playlist{}
}

func TestBundleExternalArtworkBeatsNewEmbeddedButPreservesExisting(t *testing.T) {
	s, _ := testServer(t)
	embedded := artworkFixture(t, "jpeg", 10)
	external := artworkFixture(t, "png", 200)
	picture := append([]byte("\x00image/jpeg\x00\x03\x00"), embedded...)
	frame := append([]byte("APIC"), make([]byte, 6)...)
	binary.BigEndian.PutUint32(frame[4:8], uint32(len(picture)))
	frame = append(frame, picture...)
	header := []byte{'I', 'D', '3', 3, 0, 0, byte(len(frame) >> 21 & 127), byte(len(frame) >> 14 & 127), byte(len(frame) >> 7 & 127), byte(len(frame) & 127)}
	audio := append(header, frame...)
	if err := s.upsertTrack(context.Background(), Track{ID: "existing-id", Fingerprint: "existing", Title: "Metadata only", IsLiked: true}); err != nil {
		t.Fatal(err)
	}
	entries := map[string][]byte{
		"loud-import.json": bundleJSON(t, map[string]any{"schema": "loud.import.v1", "tracks": []any{
			map[string]any{"file": "new.mp3", "fingerprint": "new", "liked": true, "playlists": []string{"Ordered"}, "artwork": bundleDescriptor("external.png", external, "image/png")},
			map[string]any{"file": "absent.mp3", "fingerprint": "existing", "liked": true, "artwork": bundleDescriptor("external.png", external, "image/png")},
		}, "playlists": []any{map[string]any{"name": "Ordered", "tracks": []any{"existing", "new"}}}}),
		"new.mp3":      audio,
		"external.png": external,
	}
	job := importTestBundle(t, s, entries)
	if job.State != "done" || job.Added != 1 || job.Existing != 1 || job.TrackArtworkImported != 2 || job.Liked != 1 {
		t.Fatalf("job: %+v", job)
	}
	for _, fp := range []string{"new", "existing"} {
		cover := artworkRequest(s.Handler(), "GET", "/api/v1/tracks/"+fp+"/artwork", nil, nil)
		if !bytes.Equal(cover.Body.Bytes(), external) {
			t.Fatalf("external artwork missing for %s", fp)
		}
	}
	if got := findBundlePlaylist(t, bundleLibrary(t, s), "Ordered"); strings.Join(got.TrackIDs, ",") != "existing-id,track_new" {
		t.Fatalf("explicit playlist order lost: %+v", got)
	}
	// Replay must retain a cover the user subsequently changed, including on
	// an existing metadata-only song whose source audio is not in the bundle.
	changed := artworkRequest(s.Handler(), "PUT", "/api/v1/tracks/new/artwork", embedded, nil)
	if changed.Code != http.StatusNoContent {
		t.Fatal(changed.Body.String())
	}
	replay := importTestBundle(t, s, entries)
	if replay.ArtworkAlreadyPresent != 2 || replay.TrackArtworkImported != 0 || replay.Liked != 0 || replay.PlaylistAdds != 0 {
		t.Fatalf("replay: %+v", replay)
	}
	if cover := artworkRequest(s.Handler(), "GET", "/api/v1/tracks/new/artwork", nil, nil); !bytes.Equal(cover.Body.Bytes(), embedded) {
		t.Fatal("replay replaced the user's cover")
	}
}

func TestBundleProviderPlaylistReferencesResolveOnlyUnambiguousAliases(t *testing.T) {
	s, _ := testServer(t)
	if err := s.upsertTrack(context.Background(), Track{ID: "actual-old-id", Fingerprint: "old-canonical", Identifiers: map[string]string{"isrc": "Old123"}}); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name string
		ref  any
		want string
	}{
		{"isrc", map[string]any{"identifiers": map[string]string{"isrc": "unique"}}, "track_custom-new"},
		{"musicbrainz", map[string]any{"identifiers": map[string]string{"musicbrainz_recording_id": "MbNew"}}, "track_custom-new"},
		{"youtube", "youtube:CaseSensitive", "track_custom-new"},
		{"existing", map[string]any{"identifiers": map[string]string{"isrc": "old123"}}, "actual-old-id"},
		{"actual-wins", map[string]any{"identifiers": map[string]string{"spotify_track_id": "Real"}}, "track_spotify:track:Real"},
		{"ambiguous", map[string]any{"identifiers": map[string]string{"isrc": "shared"}}, ""},
		{"explicit-exact", map[string]any{"fingerprint": "custom-new", "file": "two.mp3"}, "track_custom-new"},
		{"explicit-missing", map[string]any{"fingerprint": "missing", "file": "new.mp3", "identifiers": map[string]string{"isrc": "unique"}}, ""},
		{"explicit-is-not-alias", map[string]any{"fingerprint": "isrc:UNIQUE"}, ""},
		{"file-precedes-alias", map[string]any{"file": "new.mp3", "identifiers": map[string]string{"isrc": "old123"}}, "track_custom-new"},
		{"later-unambiguous-provider", map[string]any{"identifiers": map[string]string{"isrc": "shared", "youtube_video_id": "CaseSensitive"}}, "track_custom-new"},
	}
	playlists := []any{}
	for _, tc := range cases {
		playlists = append(playlists, map[string]any{"name": tc.name, "tracks": []any{tc.ref}})
	}
	job := importTestBundle(t, s, map[string][]byte{
		"loud-import.json": bundleJSON(t, map[string]any{"schema": "loud.import.v1", "tracks": []any{
			map[string]any{"file": "new.mp3", "fingerprint": "custom-new", "identifiers": map[string]string{"isrc": "unique", "musicbrainz_recording_id": "MbNew", "spotify_track_id": "Real", "youtube_video_id": "CaseSensitive"}},
			map[string]any{"file": "two.mp3", "fingerprint": "two", "identifiers": map[string]string{"isrc": "shared"}},
			map[string]any{"file": "three.mp3", "fingerprint": "three", "identifiers": map[string]string{"isrc": "shared"}},
			map[string]any{"file": "real.mp3", "fingerprint": "spotify:track:Real"},
		}, "playlists": playlists}),
		"new.mp3": []byte("new"), "two.mp3": []byte("two"), "three.mp3": []byte("three"), "real.mp3": []byte("real"),
	})
	if job.State != "done" || job.Added != 4 {
		t.Fatalf("job: %+v", job)
	}
	library := bundleLibrary(t, s)
	for _, tc := range cases {
		if got := findBundlePlaylist(t, library, tc.name); strings.Join(got.TrackIDs, ",") != tc.want {
			t.Errorf("%s: got %v, want %q", tc.name, got.TrackIDs, tc.want)
		}
	}
}

func TestBundleArtworkImportExportAndReceivingClientContract(t *testing.T) {
	s, httpServer := testServer(t)
	ctx := context.Background()
	if err := s.upsertTrack(ctx, Track{ID: "existing-noncanonical-id", Fingerprint: "matched", Title: "Keep my metadata", Artist: "Existing", Album: "Existing", IsLiked: true}); err != nil {
		t.Fatal(err)
	}
	if err := s.upsertPlaylist(ctx, Playlist{ID: "existing-playlist-id", Name: "Road Trip", TrackIDs: []string{"existing-noncanonical-id"}}); err != nil {
		t.Fatal(err)
	}
	original := artworkFixture(t, "jpeg", 30)
	incoming := artworkFixture(t, "png", 140)
	handler := s.Handler()
	if got := artworkRequest(handler, "PUT", "/api/v1/tracks/matched/audio", []byte("old audio bytes"), nil); got.Code != 204 {
		t.Fatal(got.Body.String())
	}
	if got := artworkRequest(handler, "PUT", "/api/v1/playlists/existing-playlist-id/artwork", original, nil); got.Code != 204 {
		t.Fatal(got.Body.String())
	}
	manifest := map[string]any{"schema": "loud.import.v1", "source": map[string]any{"base_path": "payload"}, "tracks": []any{
		map[string]any{"file": "audio/new.mp3", "fingerprint": "spotify:track:New123", "title": "New song", "artist": "New artist", "album": "New album", "duration_seconds": 123.456, "duration_ms": 1, "disc_number": 2, "explicit": false, "identifiers": map[string]string{"isrc": "ABC123", "spotify_track_id": "New123"}, "source_urls": map[string]string{"spotify": "https://example.invalid/song"}, "artwork": bundleDescriptor("artwork/new.png", incoming, "image/png")},
		map[string]any{"file": "audio/absent.mp3", "fingerprint": "matched", "title": "Do not replace", "liked": false},
	}, "playlists": []any{
		map[string]any{"name": "Road Trip", "mode": "replace", "tracks": []any{map[string]any{"fingerprint": "spotify:track:New123"}}, "artwork": bundleDescriptor("artwork/new.png", incoming, "image/png")},
		map[string]any{"name": "New collection", "tracks": []any{map[string]any{"fingerprint": "matched"}, map[string]any{"fingerprint": "spotify:track:New123"}, map[string]any{"fingerprint": "matched"}}},
		map[string]any{"name": "Only cover", "tracks": []any{}, "artwork": bundleDescriptor("artwork/new.png", incoming, "image/png")},
	}}
	entries := map[string][]byte{
		"wrapper/loud-import.json":        bundleJSON(t, manifest),
		"wrapper/codec-import.json":       bundleJSON(t, map[string]any{"schema": "loud.import.v1", "tracks": []any{}}),
		"wrapper/checksums.json":          []byte(`{"schema":"s2y.checksums.v1"}`),
		"wrapper/payload/audio/new.mp3":   []byte("new audio bytes"),
		"wrapper/payload/artwork/new.png": incoming,
		"wrapper/extra/matched.png":       incoming,
		"wrapper/track-artwork.json":      bundleJSON(t, map[string]any{"schema": "s2y.track-artwork.v1", "base_path": "extra", "tracks": []any{map[string]any{"fingerprint": "matched", "artwork": bundleDescriptor("matched.png", incoming, "image/png")}}}),
	}
	job := importTestBundle(t, s, entries)
	if job.State != "done" || job.Added != 1 || job.Existing != 1 || job.Skipped != 0 || job.ArtworkImported != 3 || job.TrackArtworkImported != 2 || job.PlaylistArtworkImported != 1 || job.ArtworkAlreadyPresent != 1 || job.ArtworkFailed != 0 || job.ArtworkMissing != 0 {
		t.Fatalf("job: %+v", job)
	}
	library := bundleLibrary(t, s)
	old := findBundleTrack(t, library, "matched")
	fresh := findBundleTrack(t, library, "spotify:track:New123")
	if old.ID != "existing-noncanonical-id" || old.Title != "Keep my metadata" || !old.IsLiked {
		t.Fatalf("changed existing metadata: %+v", old)
	}
	if fresh.DurationSeconds == nil || *fresh.DurationSeconds != 123.456 || fresh.DiscNumber == nil || *fresh.DiscNumber != 2 || fresh.Explicit == nil || *fresh.Explicit || fresh.Identifiers["isrc"] != "ABC123" || fresh.SourceURLs["spotify"] != "https://example.invalid/song" {
		t.Fatalf("lost optional metadata: %+v", fresh)
	}
	road := findBundlePlaylist(t, library, "Road Trip")
	if road.ID != "existing-playlist-id" || strings.Join(road.TrackIDs, ",") != "existing-noncanonical-id,track_spotify:track:New123" {
		t.Fatalf("playlist replaced: %+v", road)
	}
	if got := findBundlePlaylist(t, library, "New collection"); strings.Join(got.TrackIDs, ",") != "existing-noncanonical-id,track_spotify:track:New123" {
		t.Fatalf("wrong actual ID mapping: %+v", got)
	}
	empty := findBundlePlaylist(t, library, "Only cover")
	if len(empty.TrackIDs) != 0 || empty.ArtworkURL == nil {
		t.Fatalf("empty playlist/cover lost: %+v", empty)
	}
	for _, fp := range []string{"matched", "spotify:track:New123"} {
		track := findBundleTrack(t, library, fp)
		if track.ArtworkURL == nil || !strings.Contains(*track.ArtworkURL, "?v=") {
			t.Fatal("missing versioned track art")
		}
		for _, method := range []string{"GET", "HEAD"} {
			got := artworkRequest(handler, method, "/api/v1/tracks/"+fp+"/artwork", nil, nil)
			if got.Code != 200 || got.Header().Get("Content-Type") != "image/png" || (method == "GET" && !bytes.Equal(got.Body.Bytes(), incoming)) {
				t.Fatalf("receiving route %s %s: %d", method, fp, got.Code)
			}
		}
	}
	if got := artworkRequest(handler, "GET", "/api/v1/playlists/existing-playlist-id/artwork", nil, nil); !bytes.Equal(got.Body.Bytes(), original) {
		t.Fatal("existing custom cover overwritten")
	}
	if got := artworkRequest(handler, "GET", "/api/v1/tracks/spotify:track:New123/audio", nil, map[string]string{"Range": "bytes=0-2"}); got.Code != 206 || got.Body.String() != "new" {
		t.Fatalf("audio range route: %d %q", got.Code, got.Body.String())
	}
	if filename := os.Getenv("CODEC_BUNDLE_CONTRACT_PATH"); filename != "" {
		if err := os.WriteFile(filename, bundleJSON(t, library), 0600); err != nil {
			t.Fatal(err)
		}
	}
	replay := importTestBundle(t, s, entries)
	if replay.State != "done" || replay.Added != 0 || replay.Existing != 2 || replay.PlaylistAdds != 0 || replay.ArtworkImported != 0 || replay.ArtworkAlreadyPresent != 4 {
		t.Fatalf("replay: %+v", replay)
	}
	response, err := http.Get(httpServer.URL + "/api/v1/export")
	if err != nil {
		t.Fatal(err)
	}
	exported, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil || response.StatusCode != 200 {
		t.Fatal("export failed", err)
	}
	receiver, _ := testServer(t)
	roundtrip := importTestBundleBytes(t, receiver, exported)
	if roundtrip.State != "done" || roundtrip.Added != 2 || roundtrip.ArtworkImported != 4 || roundtrip.ArtworkFailed != 0 {
		t.Fatalf("roundtrip: %+v", roundtrip)
	}
	received := bundleLibrary(t, receiver)
	roundtrack := findBundleTrack(t, received, fresh.Fingerprint)
	if roundtrack.DurationSeconds == nil || *roundtrack.DurationSeconds != 123.456 || roundtrack.DiscNumber == nil || *roundtrack.DiscNumber != 2 || roundtrack.Explicit == nil || *roundtrack.Explicit || roundtrack.SourceURLs["spotify"] != fresh.SourceURLs["spotify"] {
		t.Fatalf("export dropped metadata: %+v", roundtrack)
	}
	for _, name := range []string{"Road Trip", "Only cover"} {
		p := findBundlePlaylist(t, received, name)
		got := artworkRequest(receiver.Handler(), "GET", "/api/v1/playlists/"+p.ID+"/artwork", nil, nil)
		expected := incoming
		if name == "Road Trip" {
			expected = original
		}
		if !bytes.Equal(got.Body.Bytes(), expected) {
			t.Fatalf("roundtrip cover changed: %s", name)
		}
	}
}

func TestBundleArtworkValidationAndInlinePriorityPreserveExisting(t *testing.T) {
	for _, kind := range []string{"hash", "mime", "dimensions", "traversal", "absolute", "missing", "corrupt", "oversize", "target"} {
		t.Run(kind, func(t *testing.T) {
			s, _ := testServer(t)
			ctx := context.Background()
			s.upsertTrack(ctx, Track{Fingerprint: "existing", Title: "Kept"})
			original := artworkFixture(t, "jpeg", 30)
			image := artworkFixture(t, "png", 40)
			artworkRequest(s.Handler(), "PUT", "/api/v1/tracks/existing/artwork", original, nil)
			descriptor := bundleDescriptor("cover.png", image, "image/png")
			target := "existing"
			switch kind {
			case "hash":
				descriptor["sha256"] = strings.Repeat("0", 64)
			case "mime":
				descriptor["mime_type"] = "image/jpeg"
			case "dimensions":
				descriptor["width"] = 8193
			case "traversal":
				descriptor["file"] = "../cover.png"
			case "absolute":
				descriptor["file"] = "/cover.png"
			case "missing":
				descriptor["file"] = "absent.png"
			case "corrupt":
				image = []byte("broken PNG")
				descriptor = bundleDescriptor("cover.png", image, "image/png")
			case "oversize":
				image = make([]byte, maxImageBytes+1)
				descriptor = bundleDescriptor("cover.png", image, "image/png")
			case "target":
				target = "no-such-exact-fingerprint"
			}
			entries := map[string][]byte{
				"loud-import.json": bundleJSON(t, map[string]any{"schema": "loud.import.v1", "tracks": []any{map[string]any{"file": "new.mp3", "fingerprint": "new"}}}),
				"new.mp3":          []byte("new audio"), "cover.png": image,
				"track-artwork.json": bundleJSON(t, map[string]any{"schema": "s2y.track-artwork.v1", "tracks": []any{map[string]any{"fingerprint": target, "artwork": descriptor}}}),
			}
			job := importTestBundle(t, s, entries)
			if job.State != "done" || job.Added != 1 || job.ArtworkImported != 0 || job.ArtworkFailed+job.ArtworkMissing != 1 || len(job.ArtworkWarnings) != 1 {
				t.Fatalf("job %+v", job)
			}
			if (kind == "missing") != (job.ArtworkMissing == 1) {
				t.Fatalf("missing/invalid conflated: %+v", job)
			}
			got := artworkRequest(s.Handler(), "GET", "/api/v1/tracks/existing/artwork", nil, nil)
			if !bytes.Equal(got.Body.Bytes(), original) {
				t.Fatal("bad descriptor replaced existing art")
			}
		})
	}
	s, _ := testServer(t)
	valid := artworkFixture(t, "png", 90)
	invalid := bundleDescriptor("missing.png", valid, "image/png")
	entries := map[string][]byte{"loud-import.json": bundleJSON(t, map[string]any{"schema": "loud.import.v1", "tracks": []any{map[string]any{"file": "new.mp3", "fingerprint": "new", "artwork": invalid}}}), "new.mp3": []byte("new audio"), "valid.png": valid,
		"track-artwork.json": bundleJSON(t, map[string]any{"schema": "s2y.track-artwork.v1", "tracks": []any{map[string]any{"fingerprint": "new", "artwork": bundleDescriptor("valid.png", valid, "image/png")}}})}
	job := importTestBundle(t, s, entries)
	if job.ArtworkMissing != 1 || job.ArtworkImported != 0 {
		t.Fatalf("sidecar incorrectly replaced selected inline descriptor: %+v", job)
	}
}

func TestBundlePreflightRejectsAmbiguityBeforeAudioWrites(t *testing.T) {
	for _, kind := range []string{"manifests", "case-playlists", "existing-playlists", "traversal", "symlink", "duplicate-entry"} {
		t.Run(kind, func(t *testing.T) {
			s, _ := testServer(t)
			manifest := bundleJSON(t, map[string]any{"schema": "loud.import.v1", "tracks": []any{map[string]any{"file": "new.mp3", "fingerprint": "new"}}, "playlists": []any{map[string]any{"name": "Mixtape"}}})
			entries := map[string][]byte{"loud-import.json": manifest, "new.mp3": []byte("new audio")}
			switch kind {
			case "manifests":
				entries["other/loud-import.json"] = manifest
			case "case-playlists":
				cover := artworkFixture(t, "png", 60)
				entries["cover.png"] = cover
				entries["playlist-artwork.json"] = bundleJSON(t, map[string]any{"schema": "s2y.playlist-artwork.v1", "playlists": []any{map[string]any{"name": "MIXTAPE", "artwork": bundleDescriptor("cover.png", cover, "image/png")}}})
			case "existing-playlists":
				s.upsertPlaylist(context.Background(), Playlist{ID: "one", Name: "Mixtape"})
				s.upsertPlaylist(context.Background(), Playlist{ID: "two", Name: "Mixtape"})
			case "traversal":
				entries["../new.mp3"] = []byte("bad")
			}
			var job ImportJob
			if kind == "symlink" || kind == "duplicate-entry" {
				var raw bytes.Buffer
				w := zip.NewWriter(&raw)
				entry, _ := w.Create("loud-import.json")
				entry.Write(manifest)
				h := &zip.FileHeader{Name: "new.mp3"}
				if kind == "symlink" {
					h.SetMode(os.ModeSymlink | 0777)
				}
				entry, _ = w.CreateHeader(h)
				entry.Write([]byte("source"))
				if kind == "duplicate-entry" {
					entry, _ = w.Create("new.mp3")
					entry.Write([]byte("duplicate"))
				}
				w.Close()
				job = importTestBundleBytes(t, s, raw.Bytes())
			} else {
				job = importTestBundle(t, s, entries)
			}
			if job.State != "failed" || len(bundleLibrary(t, s).Tracks) != 0 {
				t.Fatalf("preflight wrote media: %+v", job)
			}
			if _, err := os.Stat(s.audioPath("new")); !os.IsNotExist(err) {
				t.Fatal("preflight wrote audio")
			}
		})
	}
}
