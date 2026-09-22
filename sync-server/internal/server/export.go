// Library export: one zip holding a loud.import.v1 manifest plus every audio
// file, ready to hand to another Codec. Import dedupes by identity, so
// receivers only gain the songs they don't already have.
package server

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"image"
	"io"
	"net/http"
	"os"
	"path"
	"strings"
	"time"
)

type exportManifestTrack struct {
	File            string            `json:"file"`
	Title           string            `json:"title"`
	Artist          string            `json:"artist"`
	Album           string            `json:"album"`
	AlbumArtist     *string           `json:"album_artist,omitempty"`
	Genre           *string           `json:"genre,omitempty"`
	Year            *int              `json:"year,omitempty"`
	TrackNumber     *int              `json:"track_number,omitempty"`
	DiscNumber      *int              `json:"disc_number,omitempty"`
	Explicit        *bool             `json:"explicit,omitempty"`
	DurationSeconds *float64          `json:"duration_seconds,omitempty"`
	Artwork         *bundleArtwork    `json:"artwork,omitempty"`
	DurationMs      *int64            `json:"duration_ms,omitempty"`
	Liked           bool              `json:"liked,omitempty"`
	Fingerprint     string            `json:"fingerprint"`
	Identifiers     map[string]string `json:"identifiers,omitempty"`
	SourceURLs      map[string]string `json:"source_urls,omitempty"`
}

type exportManifestPlaylistRef struct {
	Fingerprint string `json:"fingerprint"`
}

type exportManifestPlaylist struct {
	Name    string                      `json:"name"`
	Mode    string                      `json:"mode"`
	Tracks  []exportManifestPlaylistRef `json:"tracks"`
	Artwork *bundleArtwork              `json:"artwork,omitempty"`
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
	w.Header().Set("Content-Disposition", `attachment; filename="library.loud.zip"`)
	w.WriteHeader(http.StatusOK)

	archive := zip.NewWriter(w)
	defer archive.Close()

	manifestTracks := make([]exportManifestTrack, 0, len(snapshot.Library.Tracks))
	zipPathFor := make(map[string]string, len(snapshot.Library.Tracks))
	usedPaths := make(map[string]bool)
	writtenArtwork := make(map[string]bool)

	for _, track := range snapshot.Library.Tracks {
		if audioPaths[track.Fingerprint] == "" {
			continue
		}
		zipPath := exportZipPath(track, usedPaths)
		zipPathFor[track.Fingerprint] = zipPath

		entry := exportManifestTrack{
			File:            zipPath,
			Title:           track.Title,
			Artist:          track.Artist,
			Album:           track.Album,
			AlbumArtist:     track.AlbumArtist,
			Genre:           track.Genre,
			Year:            track.Year,
			TrackNumber:     track.TrackNumber,
			DiscNumber:      track.DiscNumber,
			Explicit:        track.Explicit,
			DurationSeconds: track.DurationSeconds,
			Liked:           track.IsLiked,
			Fingerprint:     track.Fingerprint,
			Identifiers:     track.Identifiers,
			SourceURLs:      track.SourceURLs,
		}
		if artworkPath, err := s.mediaPath(r.Context(), track.Fingerprint, "artwork_path"); err == nil {
			entry.Artwork, err = exportBundleArtwork(archive, artworkPath, writtenArtwork)
			if err != nil {
				return
			}
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
		entry := exportManifestPlaylist{
			Name:   playlist.Name,
			Mode:   "append",
			Tracks: refs,
		}
		entry.Artwork, err = exportBundleArtwork(archive, s.playlistArtworkPath(playlist.ID), writtenArtwork)
		if err != nil {
			return
		}
		manifestPlaylists = append(manifestPlaylists, entry)
	}

	manifest := map[string]any{
		"schema": "loud.import.v1",
		"source": map[string]any{
			"name":         "codec-sync-server",
			"generated_at": s.now().UTC().Format(time.RFC3339),
			"base_path":    ".",
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
		if info, err := os.Stat(path); err == nil && info.Mode().IsRegular() && info.Size() > 0 {
			paths[fingerprint] = path
		} else if canonical := s.audioPath(fingerprint); canonical != path {
			if info, err := os.Stat(canonical); err == nil && info.Mode().IsRegular() && info.Size() > 0 {
				paths[fingerprint] = canonical
			}
		}
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
	ext := strings.ToLower(path.Ext(track.FileName))
	if ext != ".mp3" && ext != ".m4a" && ext != ".mp4" && ext != ".wav" && ext != ".flac" {
		ext = ".mp3"
	}
	zipPath := base + ext
	if used[strings.ToLower(zipPath)] {
		fallback := fmt.Sprintf("%s-%s", base, safeFileName(track.Fingerprint))
		zipPath = fallback + ext
		// The fingerprint suffix may itself be another song's title. Check
		// every candidate so sanitized names stay unique on all clients.
		for suffix := 2; used[strings.ToLower(zipPath)]; suffix++ {
			zipPath = fmt.Sprintf("%s-%d%s", fallback, suffix, ext)
		}
	}
	used[strings.ToLower(zipPath)] = true
	return zipPath
}

// The manifest carries portable descriptors for original managed images.
// Provenance URLs are never fetched; legacy non-JPEG/PNG images remain served
// by their existing API route but are not advertised as supported new inputs.
func exportBundleArtwork(archive *zip.Writer, filename string, written map[string]bool) (*bundleArtwork, error) {
	file, err := os.Open(filename)
	if err != nil {
		return nil, nil
	}
	data, err := readArtwork(&http.Request{Header: make(http.Header), Body: file})
	if err != nil {
		return nil, nil
	}
	config, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return nil, nil
	}
	digest := fmt.Sprintf("%x", sha256.Sum256(data))
	ext := ".jpg"
	if format == "png" {
		ext = ".png"
	}
	name := "artwork/" + digest + ext
	if !written[name] {
		writer, err := archive.CreateHeader(&zip.FileHeader{Name: name, Method: zip.Store})
		if err != nil {
			return nil, err
		}
		if _, err := writer.Write(data); err != nil {
			return nil, err
		}
		written[name] = true
	}
	return &bundleArtwork{File: name, SHA256: digest, MIME: "image/" + format, Width: config.Width, Height: config.Height}, nil
}
