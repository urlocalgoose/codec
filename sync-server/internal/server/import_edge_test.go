package server

import (
	"bytes"
	"context"
	"encoding/binary"
	"net/http"
	"os"
	"strings"
	"testing"
)

func bundleID3Audio(title, artist, album string, artwork []byte) []byte {
	var body []byte
	add := func(id string, value []byte) {
		frame := append([]byte(id), make([]byte, 6)...)
		binary.BigEndian.PutUint32(frame[4:8], uint32(len(value)))
		body = append(body, append(frame, value...)...)
	}
	for _, field := range [][2]string{{"TIT2", title}, {"TPE1", artist}, {"TALB", album}} {
		if field[1] != "" {
			add(field[0], append([]byte{3}, []byte(field[1])...))
		}
	}
	if len(artwork) > 0 {
		add("APIC", append([]byte("\x00image/jpeg\x00\x03\x00"), artwork...))
	}
	header := []byte{'I', 'D', '3', 3, 0, 0, byte(len(body) >> 21 & 127), byte(len(body) >> 14 & 127), byte(len(body) >> 7 & 127), byte(len(body) & 127)}
	return append(append(header, body...), []byte("audio fixture")...)
}

func TestBundleMinimalTracksResolveIdentityAfterTagsAndFilename(t *testing.T) {
	s, _ := testServer(t)
	cover := artworkFixture(t, "png", 140)
	entries := map[string][]byte{
		"loud-import.json": bundleJSON(t, map[string]any{"schema": "loud.import.v1", "tracks": []any{
			map[string]any{"file": "audio/a.mp3"},
			map[string]any{"file": "audio/b.mp3"},
			map[string]any{"file": "audio/tagged.mp3", "artwork": bundleDescriptor("cover.png", cover, "image/png")},
			map[string]any{"file": "audio/override.mp3", "title": "Manifest title"},
		}, "playlists": []any{map[string]any{"name": "All", "tracks": []any{"audio/b.mp3", "audio/tagged.mp3", "audio/a.mp3", "audio/override.mp3"}}}}),
		"audio/a.mp3": []byte("audio a"), "audio/b.mp3": []byte("audio b"),
		"audio/tagged.mp3":   bundleID3Audio("Tag title", "Tag artist", "Tag album", nil),
		"audio/override.mp3": bundleID3Audio("Discarded title", "Tag artist", "Tag album", nil),
		"cover.png":          cover,
	}
	job := importTestBundle(t, s, entries)
	if job.State != "done" || job.Added != 4 || job.Skipped != 0 || job.TrackArtworkImported != 1 {
		t.Fatalf("job %+v", job)
	}
	library := bundleLibrary(t, s)
	fingerprints := []string{
		fingerprintFor("b", "Unknown Artist", "Unknown Album"),
		fingerprintFor("Tag title", "Tag artist", "Tag album"),
		fingerprintFor("a", "Unknown Artist", "Unknown Album"),
		fingerprintFor("Manifest title", "Tag artist", "Tag album"),
	}
	var wantedIDs []string
	for _, fingerprint := range fingerprints {
		track := findBundleTrack(t, library, fingerprint)
		wantedIDs = append(wantedIDs, track.ID)
		if got := artworkRequest(s.Handler(), "GET", "/api/v1/tracks/"+fingerprint+"/audio", nil, nil); got.Code != http.StatusOK || got.Body.Len() == 0 {
			t.Fatalf("missing audio for %s", fingerprint)
		}
	}
	if got := findBundlePlaylist(t, library, "All"); strings.Join(got.TrackIDs, ",") != strings.Join(wantedIDs, ",") {
		t.Fatalf("wrong playlist mapping: %+v", got)
	}
	if got := artworkRequest(s.Handler(), "GET", "/api/v1/tracks/"+fingerprints[1]+"/artwork", nil, nil); !bytes.Equal(got.Body.Bytes(), cover) {
		t.Fatal("inline artwork targeted a stale pre-tag identity")
	}
	if replay := importTestBundle(t, s, entries); replay.Added != 0 || replay.Existing != 4 || replay.PlaylistAdds != 0 {
		t.Fatalf("replay: %+v", replay)
	}
}

func TestBundleRestoresMissingAudioWithoutChangingExistingMetadata(t *testing.T) {
	s, _ := testServer(t)
	ctx := context.Background()
	original := artworkFixture(t, "jpeg", 40)
	external := artworkFixture(t, "png", 160)
	for _, fingerprint := range []string{"metadata-only", "deleted", "intact"} {
		track := Track{ID: "kept-" + fingerprint, Fingerprint: fingerprint, Title: "Kept title", Artist: "Kept artist", Album: "Kept album", IsLiked: true, Identifiers: map[string]string{"isrc": "ORIGINAL"}, SourceURLs: map[string]string{"source": "https://example.invalid/original"}}
		if err := s.upsertTrack(ctx, track); err != nil {
			t.Fatal(err)
		}
		if fingerprint != "metadata-only" {
			if got := artworkRequest(s.Handler(), "PUT", "/api/v1/tracks/"+fingerprint+"/audio", []byte("original audio"), nil); got.Code != http.StatusNoContent {
				t.Fatal(got.Body.String())
			}
		}
	}
	if err := os.Remove(s.audioPath("deleted")); err != nil {
		t.Fatal(err)
	}
	if got := artworkRequest(s.Handler(), "PUT", "/api/v1/tracks/deleted/artwork", original, nil); got.Code != http.StatusNoContent {
		t.Fatal(got.Body.String())
	}
	tracks := []any{}
	entries := map[string][]byte{"external.png": external}
	for _, fingerprint := range []string{"metadata-only", "deleted", "intact"} {
		tracks = append(tracks, map[string]any{"file": fingerprint + ".mp3", "fingerprint": fingerprint, "title": "Replacement title", "artist": "Replacement artist", "liked": false, "artwork": bundleDescriptor("external.png", external, "image/png")})
		entries[fingerprint+".mp3"] = bundleID3Audio("Embedded title", "Embedded artist", "Embedded album", original)
	}
	entries["loud-import.json"] = bundleJSON(t, map[string]any{"schema": "loud.import.v1", "tracks": tracks, "playlists": []any{map[string]any{"name": "Recovered", "tracks": []any{"metadata-only", "deleted", "intact"}}}})
	job := importTestBundle(t, s, entries)
	if job.State != "done" || job.Added != 0 || job.Existing != 3 || job.AudioRestored != 2 || job.Skipped != 0 || job.TrackArtworkImported != 2 || job.ArtworkAlreadyPresent != 1 {
		t.Fatalf("job: %+v", job)
	}
	library := bundleLibrary(t, s)
	for _, fingerprint := range []string{"metadata-only", "deleted", "intact"} {
		track := findBundleTrack(t, library, fingerprint)
		if track.ID != "kept-"+fingerprint || track.Title != "Kept title" || track.Artist != "Kept artist" || track.Album != "Kept album" || !track.IsLiked || track.Identifiers["isrc"] != "ORIGINAL" || track.SourceURLs["source"] != "https://example.invalid/original" {
			t.Fatalf("metadata changed: %+v", track)
		}
		wantedAudio := entries[fingerprint+".mp3"]
		if fingerprint == "intact" {
			wantedAudio = []byte("original audio")
		}
		if got := artworkRequest(s.Handler(), "GET", "/api/v1/tracks/"+fingerprint+"/audio", nil, nil); got.Code != http.StatusOK || !bytes.Equal(got.Body.Bytes(), wantedAudio) {
			t.Fatalf("wrong audio for %s", fingerprint)
		}
		wantedCover := external
		if fingerprint == "deleted" {
			wantedCover = original
		}
		if got := artworkRequest(s.Handler(), "GET", "/api/v1/tracks/"+fingerprint+"/artwork", nil, nil); !bytes.Equal(got.Body.Bytes(), wantedCover) {
			t.Fatalf("wrong cover for %s", fingerprint)
		}
	}
	if replay := importTestBundle(t, s, entries); replay.AudioRestored != 0 || replay.Existing != 3 || replay.Added != 0 || replay.TrackArtworkImported != 0 {
		t.Fatalf("replay: %+v", replay)
	}
}

func TestBundleInvalidOptionalSidecarCoverDoesNotBlockAudio(t *testing.T) {
	for _, kind := range []string{"missing-fields", "type", "hash", "missing-file", "mime", "dimensions", "corrupt"} {
		t.Run(kind, func(t *testing.T) {
			s, _ := testServer(t)
			cover := artworkFixture(t, "png", 70)
			descriptor := bundleDescriptor("cover.png", cover, "image/png")
			switch kind {
			case "missing-fields":
				descriptor = map[string]any{"file": "cover.png"}
			case "type":
				descriptor["width"] = "eight"
			case "hash":
				descriptor["sha256"] = strings.Repeat("0", 64)
			case "missing-file":
				descriptor["file"] = "missing.png"
			case "mime":
				descriptor["mime_type"] = "image/jpeg"
			case "dimensions":
				descriptor["width"] = 99999
			case "corrupt":
				cover = []byte("corrupt image")
				descriptor = bundleDescriptor("cover.png", cover, "image/png")
			}
			job := importTestBundle(t, s, map[string][]byte{
				"loud-import.json": bundleJSON(t, map[string]any{"schema": "loud.import.v1", "tracks": []any{map[string]any{"file": "song.mp3", "fingerprint": "new"}}, "playlists": []any{map[string]any{"name": "Mixtape", "tracks": []any{"new"}}}}),
				"song.mp3":         []byte("new audio"), "cover.png": cover,
				"playlist-artwork.json": bundleJSON(t, map[string]any{"schema": "s2y.playlist-artwork.v1", "playlists": []any{map[string]any{"name": "MIXTAPE", "artwork": descriptor}}}),
			})
			if job.State != "done" || job.Added != 1 || job.PlaylistAdds != 1 || job.ArtworkImported != 0 || job.ArtworkFailed+job.ArtworkMissing != 1 || len(job.ArtworkWarnings) != 1 {
				t.Fatalf("job: %+v", job)
			}
			if got := findBundlePlaylist(t, bundleLibrary(t, s), "Mixtape"); len(got.TrackIDs) != 1 || got.ArtworkURL != nil {
				t.Fatalf("playlist damaged: %+v", got)
			}
		})
	}
}
