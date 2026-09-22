package server

import (
	"archive/zip"
	"bytes"
	"context"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// A hosting migration must use the copied library after the old Mac paths
// disappear, retaining the original identity, memberships, and media bytes.
func TestDataDirectoryRelocationPreservesLibraryMediaAndExport(t *testing.T) {
	ctx := context.Background()
	original := filepath.Join(t.TempDir(), "old-mac-data")
	source, err := Open(original)
	if err != nil {
		t.Fatal(err)
	}
	track := Track{ID: "original-track-id", Fingerprint: "spotify:track:relocation", Title: "Retained title", Artist: "Artist", Album: "Album", FileName: "song.wav", IsLiked: true, Identifiers: map[string]string{"custom": "retained"}}
	if err := source.upsertTrack(ctx, track); err != nil {
		source.Close()
		t.Fatal(err)
	}
	playlist := Playlist{ID: "original-playlist-id", Name: "Retained playlist", TrackIDs: []string{track.ID}}
	if err := source.upsertPlaylist(ctx, playlist); err != nil {
		source.Close()
		t.Fatal(err)
	}
	audio := []byte("original audio bytes retained across a hosting migration")
	cover := artworkFixture(t, "png", 81)
	for _, upload := range []struct {
		path string
		body []byte
		mime string
	}{
		{"/api/v1/tracks/" + track.Fingerprint + "/audio", audio, "audio/wav"},
		{"/api/v1/tracks/" + track.Fingerprint + "/artwork", cover, "image/png"},
		{"/api/v1/playlists/" + playlist.ID + "/artwork", cover, "image/png"},
	} {
		response := artworkRequest(source.Handler(), "PUT", upload.path, upload.body, map[string]string{"Content-Type": upload.mime})
		if response.Code != http.StatusNoContent {
			source.Close()
			t.Fatalf("seed %s: %d", upload.path, response.Code)
		}
	}
	before, err := source.snapshot(ctx, "https://music.example.test")
	if err != nil {
		source.Close()
		t.Fatal(err)
	}
	var stored string
	if err := source.db.QueryRowContext(ctx, "SELECT audio_path FROM tracks WHERE fingerprint = ?", track.Fingerprint).Scan(&stored); err != nil {
		source.Close()
		t.Fatal(err)
	}
	if !strings.HasPrefix(stored, original) {
		source.Close()
		t.Fatal("fixture did not store a legacy absolute path")
	}
	if err := source.Close(); err != nil {
		t.Fatal(err)
	}
	destination := filepath.Join(t.TempDir(), "ubuntu-data")
	if err := os.CopyFS(destination, os.DirFS(original)); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(original); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(stored); !os.IsNotExist(err) {
		t.Fatal("old media must be unavailable to prove relocation")
	}

	for attempt := range 2 {
		func() {
			restored, err := Open(destination)
			if err != nil {
				t.Fatal(err)
			}
			defer restored.Close()
			after, err := restored.snapshot(ctx, "https://music.example.test")
			if err != nil {
				t.Fatal(err)
			}
			if after.ServerID != before.ServerID || !reflect.DeepEqual(after.Library.Stats, before.Library.Stats) {
				t.Fatalf("restart %d changed library identity/stats", attempt)
			}
			if len(after.Library.Tracks) != 1 {
				t.Fatal("track disappeared")
			}
			got := after.Library.Tracks[0]
			if got.ID != track.ID || got.Fingerprint != track.Fingerprint || got.Title != track.Title || !got.IsLiked || got.Identifiers["custom"] != "retained" {
				t.Fatal("track metadata changed")
			}
			// Copying onto another filesystem may change image mtimes/cache
			// versions; canonical URL targets and all memberships must survive.
			for i := range after.Library.Playlists {
				if url := after.Library.Playlists[i].ArtworkURL; url != nil {
					plain := strings.SplitN(*url, "?", 2)[0]
					after.Library.Playlists[i].ArtworkURL = &plain
				}
			}
			for i := range before.Library.Playlists {
				if url := before.Library.Playlists[i].ArtworkURL; url != nil {
					plain := strings.SplitN(*url, "?", 2)[0]
					before.Library.Playlists[i].ArtworkURL = &plain
				}
			}
			if !reflect.DeepEqual(after.Library.Playlists, before.Library.Playlists) {
				t.Fatal("playlist identity/order/cover changed")
			}
			if got.ArtworkURL == nil || !strings.Contains(*got.ArtworkURL, "?v=") {
				t.Fatal("moved track artwork has no cache version")
			}
			handler := restored.HandlerWithOptions(HandlerOptions{AuthToken: "isolated-migration-token"})
			headers := map[string]string{"Authorization": "Bearer isolated-migration-token"}
			for _, item := range []struct {
				path     string
				original []byte
				mime     string
			}{
				{"/api/v1/tracks/" + track.Fingerprint + "/audio", audio, "audio/wav"},
				{"/api/v1/tracks/" + track.Fingerprint + "/artwork", cover, "image/png"},
				{"/api/v1/playlists/" + playlist.ID + "/artwork", cover, "image/png"},
			} {
				response := artworkRequest(handler, "GET", item.path, nil, headers)
				if response.Code != 200 || response.Header().Get("Content-Type") != item.mime || !bytes.Equal(response.Body.Bytes(), item.original) {
					t.Fatalf("moved media not served: %s", item.path)
				}
			}
			ranged := artworkRequest(handler, "GET", "/api/v1/tracks/"+track.Fingerprint+"/audio", nil, map[string]string{"Authorization": "Bearer isolated-migration-token", "Range": "bytes=2-8"})
			if ranged.Code != 206 || !bytes.Equal(ranged.Body.Bytes(), audio[2:9]) {
				t.Fatal("moved audio range failed")
			}
			exported := artworkRequest(handler, "GET", "/api/v1/export", nil, headers)
			archive, err := zip.NewReader(bytes.NewReader(exported.Body.Bytes()), int64(exported.Body.Len()))
			if err != nil {
				t.Fatal(err)
			}
			foundAudio, foundCover := false, false
			for _, entry := range archive.File {
				reader, err := entry.Open()
				if err != nil {
					t.Fatal(err)
				}
				data, err := io.ReadAll(reader)
				reader.Close()
				if err != nil {
					t.Fatal(err)
				}
				foundAudio = foundAudio || bytes.Equal(data, audio)
				foundCover = foundCover || bytes.Equal(data, cover)
			}
			if !foundAudio || !foundCover {
				t.Fatal("export lost relocated media")
			}
		}()
	}
}
