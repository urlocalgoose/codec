// Library export: one zip holding a loud.import.v1 manifest plus every audio
// file, ready to hand to another Codec. Import dedupes by identity, so
// receivers only gain the songs they don't already have.
package server

import (
	"archive/zip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

type exportManifestTrack struct {
	File        string            `json:"file"`
	Title       string            `json:"title"`
	Artist      string            `json:"artist"`
	Album       string            `json:"album"`
	AlbumArtist *string           `json:"album_artist,omitempty"`
	Genre       *string           `json:"genre,omitempty"`
	Year        *int              `json:"year,omitempty"`
	TrackNumber *int              `json:"track_number,omitempty"`
	DurationMs  *int64            `json:"duration_ms,omitempty"`
	Liked       bool              `json:"liked,omitempty"`
	Fingerprint string            `json:"fingerprint"`
	Identifiers map[string]string `json:"identifiers,omitempty"`
	SourceURLs  map[string]string `json:"source_urls,omitempty"`
}

type exportManifestPlaylistRef struct {
	Fingerprint string `json:"fingerprint"`
}

type exportManifestPlaylist struct {
	Name   string                      `json:"name"`
	Mode   string                      `json:"mode"`
	Tracks []exportManifestPlaylistRef `json:"tracks"`
}

func (s *Server) handleExportLibrary(w http.ResponseWriter, r *http.Request) {
	snapshot, err := s.snapshot(r.Context(), publicBaseURL(r))
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}

	audioPaths, err := s.audioPathsByFingerprint(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}

	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", `attachment; filename="codec-library.zip"`)
	w.WriteHeader(http.StatusOK)

	archive := zip.NewWriter(w)
	defer archive.Close()

	manifestTracks := make([]exportManifestTrack, 0, len(snapshot.Library.Tracks))
	zipPathFor := make(map[string]string, len(snapshot.Library.Tracks))
	usedPaths := make(map[string]bool)

	for _, track := range snapshot.Library.Tracks {
		if audioPaths[track.Fingerprint] == "" {
			continue
		}
		zipPath := exportZipPath(track, usedPaths)
		zipPathFor[track.Fingerprint] = zipPath

		entry := exportManifestTrack{
			File:        zipPath,
			Title:       track.Title,
			Artist:      track.Artist,
			Album:       track.Album,
			AlbumArtist: track.AlbumArtist,
			Genre:       track.Genre,
			Year:        track.Year,
			TrackNumber: track.TrackNumber,
			Liked:       track.IsLiked,
			Fingerprint: track.Fingerprint,
			Identifiers: track.Identifiers,
			SourceURLs:  track.SourceURLs,
		}
		if track.DurationSeconds != nil {
			ms := int64(*track.DurationSeconds * 1000)
			entry.DurationMs = &ms
		}
		manifestTracks = append(manifestTracks, entry)
	}

	manifestPlaylists := make([]exportManifestPlaylist, 0, len(snapshot.Library.Playlists))
	trackByID := make(map[string]Track, len(snapshot.Library.Tracks))
	for _, track := range snapshot.Library.Tracks {
		trackByID[track.ID] = track
	}
	for _, playlist := range snapshot.Library.Playlists {
		if playlist.IsLiked {
			continue // liked flags already ride on the tracks
		}
		refs := make([]exportManifestPlaylistRef, 0, len(playlist.TrackIDs))
		for _, trackID := range playlist.TrackIDs {
			if track, ok := trackByID[trackID]; ok && zipPathFor[track.Fingerprint] != "" {
				refs = append(refs, exportManifestPlaylistRef{Fingerprint: track.Fingerprint})
			}
		}
		if len(refs) > 0 {
			manifestPlaylists = append(manifestPlaylists, exportManifestPlaylist{
				Name:   playlist.Name,
				Mode:   "append",
				Tracks: refs,
			})
		}
	}

	manifest := map[string]any{
		"schema": "loud.import.v1",
		"source": map[string]any{
			"name":         "codec-sync-server",
			"generated_at": s.now().UTC().Format(time.RFC3339),
			"base_path":    "files",
		},
		"tracks":    manifestTracks,
		"playlists": manifestPlaylists,
	}

	manifestWriter, err := archive.Create("codec-import.json")
	if err != nil {
		return
	}
	encoder := json.NewEncoder(manifestWriter)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(manifest); err != nil {
		return
	}

	// Audio rides uncompressed: MP3s don't shrink, and Store keeps the
	// download a straight stream from disk.
	for _, entry := range manifestTracks {
		diskPath := audioPaths[entry.Fingerprint]
		file, err := os.Open(diskPath)
		if err != nil {
			continue
		}
		header := &zip.FileHeader{Name: entry.File, Method: zip.Store, Modified: s.now()}
		writer, err := archive.CreateHeader(header)
		if err != nil {
			file.Close()
			return
		}
		if _, err := io.Copy(writer, file); err != nil {
			file.Close()
			return
		}
		file.Close()
	}
}

func (s *Server) audioPathsByFingerprint(ctx context.Context) (map[string]string, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT fingerprint, audio_path FROM tracks WHERE audio_path IS NOT NULL`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	paths := map[string]string{}
	for rows.Next() {
		var fingerprint, path string
		if err := rows.Scan(&fingerprint, &path); err != nil {
			return nil, err
		}
		paths[fingerprint] = path
	}
	return paths, rows.Err()
}

func exportZipPath(track Track, used map[string]bool) string {
	component := func(value, fallback string) string {
		cleaned := safeFileName(strings.TrimSpace(value))
		if cleaned == "" {
			return fallback
		}
		return cleaned
	}
	base := fmt.Sprintf(
		"files/%s/%s/%s",
		component(track.Artist, "Unknown Artist"),
		component(track.Album, "Unknown Album"),
		component(track.Title, "Untitled"),
	)
	path := base + ".mp3"
	if used[path] {
		path = fmt.Sprintf("%s-%s.mp3", base, safeFileName(track.Fingerprint))
	}
	used[path] = true
	return path
}
