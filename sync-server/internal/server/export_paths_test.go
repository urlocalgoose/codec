package server

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestExportZipPathsRemainUniqueThroughSanitizedFallbackCollisions(t *testing.T) {
	used := map[string]bool{}
	tracks := []Track{
		{Title: "A", Fingerprint: "first"},
		{Title: "A-x", Fingerprint: "second"},
		{Title: "A-x-2", Fingerprint: "third"},
		{Title: "A.", Fingerprint: "x"},
		{Title: "a.", Fingerprint: "X"},
		{Title: "A..", Fingerprint: "x"},
	}
	seen := map[string]bool{}
	for _, track := range tracks {
		track.Artist, track.Album, track.FileName = "Artist", "Album", "original.FLAC"
		name := exportZipPath(track, used)
		key := strings.ToLower(name)
		if seen[key] {
			t.Fatalf("export path reused after sanitizing %q: %s", track.Title, name)
		}
		if !strings.HasSuffix(name, ".flac") {
			t.Fatalf("audio extension changed: %s", name)
		}
		seen[key] = true
	}
}

func TestExportSanitizedFallbackCollisionRoundTripPreservesEveryAudio(t *testing.T) {
	source, _ := testServer(t)
	ctx := context.Background()
	tracks := []Track{
		{ID: "track_first", Title: "A", Fingerprint: "first"},
		{ID: "track_second", Title: "A-x", Fingerprint: "second"},
		{ID: "track_third", Title: "A-x-2", Fingerprint: "third"},
		{ID: "track_x", Title: "A.", Fingerprint: "x"},
	}
	audio := map[string][]byte{}
	for _, track := range tracks {
		track.Artist, track.Album, track.FileName = "Artist", "Album", "source.mp3"
		if err := source.upsertTrack(ctx, track); err != nil {
			t.Fatal(err)
		}
		audio[track.Fingerprint] = []byte("distinct original audio for " + track.Fingerprint)
		response := artworkRequest(source.Handler(), http.MethodPut, "/api/v1/tracks/"+track.Fingerprint+"/audio", audio[track.Fingerprint], nil)
		if response.Code != http.StatusNoContent {
			t.Fatalf("seed audio: %d %s", response.Code, response.Body.String())
		}
	}
	playlist := Playlist{ID: "ordered", Name: "Collision Order", TrackIDs: []string{"track_x", "track_third", "track_second", "track_first"}}
	if err := source.upsertPlaylist(ctx, playlist); err != nil {
		t.Fatal(err)
	}
	exported := artworkRequest(source.Handler(), http.MethodGet, "/api/v1/export", nil, nil)
	if exported.Code != http.StatusOK {
		t.Fatalf("export: %d %s", exported.Code, exported.Body.String())
	}
	archive, err := zip.NewReader(bytes.NewReader(exported.Body.Bytes()), int64(exported.Body.Len()))
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	var manifest importManifest
	for _, entry := range archive.File {
		key := strings.ToLower(entry.Name)
		if seen[key] {
			t.Fatalf("export emitted duplicate ZIP member: %s", entry.Name)
		}
		seen[key] = true
		if entry.Name == "codec-import.json" {
			reader, err := entry.Open()
			if err != nil {
				t.Fatal(err)
			}
			data, err := io.ReadAll(reader)
			reader.Close()
			if err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal(data, &manifest); err != nil {
				t.Fatal(err)
			}
		}
	}
	if len(manifest.Tracks) != len(tracks) {
		t.Fatalf("manifest lost tracks: %d", len(manifest.Tracks))
	}
	receiver, _ := testServer(t)
	job := importTestBundleBytes(t, receiver, exported.Body.Bytes())
	if job.State != "done" || job.Added != len(tracks) || job.Existing != 0 || job.Skipped != 0 {
		t.Fatalf("export cannot be reimported: %+v", job)
	}
	library := bundleLibrary(t, receiver)
	if len(library.Tracks) != len(tracks) {
		t.Fatalf("round trip lost tracks: %d", len(library.Tracks))
	}
	for _, expected := range tracks {
		actual := findBundleTrack(t, library, expected.Fingerprint)
		if actual.Title != expected.Title {
			t.Fatalf("title changed for %s: %q", expected.Fingerprint, actual.Title)
		}
		response := artworkRequest(receiver.Handler(), http.MethodGet, "/api/v1/tracks/"+expected.Fingerprint+"/audio", nil, nil)
		if response.Code != http.StatusOK || !bytes.Equal(response.Body.Bytes(), audio[expected.Fingerprint]) {
			t.Fatalf("audio changed or missing for %s", expected.Fingerprint)
		}
	}
	actualPlaylist := findBundlePlaylist(t, library, playlist.Name)
	if strings.Join(actualPlaylist.TrackIDs, ",") != strings.Join(playlist.TrackIDs, ",") {
		t.Fatalf("playlist order changed: %v", actualPlaylist.TrackIDs)
	}
}
