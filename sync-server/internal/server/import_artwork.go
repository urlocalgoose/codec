package server

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"net/http"
	"os"
	"path"
	"strings"
)

const maxBundleBytes int64 = 64 << 30

type bundleFiles struct {
	entries   map[string]*zip.File
	manifest  *zip.File
	directory string
}

// Archive members are addressed lexically; nothing is extracted using a
// supplied path. Reject symlinks and duplicate names before any library write.
func bundleRelativePath(value string) (string, error) {
	if strings.ContainsAny(value, "\\\x00") || strings.HasPrefix(value, "/") || (len(value) > 1 && value[1] == ':') {
		return "", errors.New("path must be relative to the bundle")
	}
	for _, component := range strings.Split(value, "/") {
		if component == ".." {
			return "", errors.New("parent path traversal is not allowed")
		}
	}
	return path.Clean(value), nil
}

func indexBundle(archive *zip.ReadCloser) (*bundleFiles, error) {
	if len(archive.File) > 100000 {
		return nil, errors.New("bundle has too many entries")
	}
	files := &bundleFiles{entries: map[string]*zip.File{}}
	var expanded uint64
	for _, entry := range archive.File {
		name, err := bundleRelativePath(entry.Name)
		if err != nil {
			return nil, fmt.Errorf("archive entry: %w", err)
		}
		if entry.Mode()&os.ModeSymlink != 0 {
			return nil, errors.New("bundle symlink entries are not supported")
		}
		if entry.FileInfo().IsDir() {
			continue
		}
		if files.entries[name] != nil {
			return nil, fmt.Errorf("duplicate archive path %q", name)
		}
		if entry.UncompressedSize64 > uint64(maxBundleBytes) || expanded > uint64(maxBundleBytes)-entry.UncompressedSize64 {
			return nil, errors.New("expanded bundle exceeds 64 GiB")
		}
		expanded += entry.UncompressedSize64
		files.entries[name] = entry
	}
	// S2Y's loud-import carries the richer inline descriptors when both aliases
	// are included. Equal-priority manifests in different roots are ambiguous.
	for _, canonical := range []string{"loud-import.json", "codec-import.json"} {
		for name, entry := range files.entries {
			if path.Base(name) != canonical {
				continue
			}
			if files.manifest != nil {
				return nil, errors.New("bundle contains multiple import manifest roots")
			}
			files.manifest = entry
			files.directory = path.Dir(name)
		}
		if files.manifest != nil {
			return files, nil
		}
	}
	for name, entry := range files.entries {
		if !strings.HasSuffix(strings.ToLower(name), ".json") {
			continue
		}
		var header struct {
			Schema string `json:"schema"`
		}
		if readZipJSON(entry, &header) != nil || header.Schema != "loud.import.v1" {
			continue
		}
		if files.manifest != nil {
			return nil, errors.New("bundle contains multiple import manifests")
		}
		files.manifest = entry
		files.directory = path.Dir(name)
	}
	if files.manifest == nil {
		return nil, errors.New("bundle has no loud.import.v1 manifest")
	}
	return files, nil
}

func (files *bundleFiles) relative(base, name string) (*zip.File, error) {
	base, err := bundleRelativePath(base)
	if err != nil {
		return nil, err
	}
	name, err = bundleRelativePath(name)
	if err != nil {
		return nil, err
	}
	if name == "." {
		return nil, errors.New("file path is empty")
	}
	entry := files.entries[path.Join(files.directory, base, name)]
	if entry == nil {
		return nil, os.ErrNotExist
	}
	return entry, nil
}

func (files *bundleFiles) audio(base, name string) (*zip.File, error) {
	entry, err := files.relative(base, name)
	if err == nil {
		return entry, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	// Older Codec exports included the base folder in tracks[].file too.
	entry, err = files.relative("", name)
	if err == nil {
		return entry, nil
	}
	// Retain legacy loose-file support only when the basename is unambiguous.
	var found *zip.File
	for member, candidate := range files.entries {
		if path.Base(member) != path.Base(name) {
			continue
		}
		if found != nil {
			return nil, errors.New("ambiguous audio filename; retain the bundle folders")
		}
		found = candidate
	}
	if found == nil {
		return nil, os.ErrNotExist
	}
	return found, nil
}

type bundleArtwork struct {
	File           string          `json:"file"`
	SHA256         string          `json:"sha256"`
	MIME           string          `json:"mime_type"`
	Width          int             `json:"width"`
	Height         int             `json:"height"`
	SourceURL      string          `json:"source_url,omitempty"`
	SpotifyURL     string          `json:"spotify_url,omitempty"`
	LicenseURL     string          `json:"license_url,omitempty"`
	AttributionURL string          `json:"attribution_url,omitempty"`
	Provenance     json.RawMessage `json:"provenance,omitempty"`
}
type bundleArtworkCandidate struct {
	target, base string
	playlist     bool
	raw          json.RawMessage
}

func (s *Server) artworkDiagnostic(job *ImportJob, target string, err error) {
	s.updateImportJob(job, func(j *ImportJob) {
		if errors.Is(err, os.ErrNotExist) {
			j.ArtworkMissing++
		} else {
			j.ArtworkFailed++
		}
		if len(j.ArtworkWarnings) < 50 {
			j.ArtworkWarnings = append(j.ArtworkWarnings, fmt.Sprintf("%s: %s", target, err))
		}
	})
}

func (s *Server) bundleArtworkCandidates(job *ImportJob, files *bundleFiles, manifest importManifest) []bundleArtworkCandidate {
	var result []bundleArtworkCandidate
	seen := map[string]bool{}
	add := func(target, base string, playlist bool, raw json.RawMessage) {
		if len(raw) == 0 || string(raw) == "null" {
			return
		}
		target = strings.TrimSpace(target)
		key := fmt.Sprintf("%t:%s", playlist, target)
		if seen[key] {
			return
		}
		seen[key] = true
		result = append(result, bundleArtworkCandidate{target: target, base: base, playlist: playlist, raw: raw})
	}
	for _, track := range manifest.Tracks {
		add(importIdentity(track), manifest.Source.BasePath, false, track.Artwork)
	}
	for _, playlist := range manifest.Playlists {
		add(playlist.Name, manifest.Source.BasePath, true, playlist.Artwork)
	}
	for _, kind := range []struct {
		name, schema, field string
		playlist            bool
	}{
		{"track-artwork.json", "s2y.track-artwork.v1", "tracks", false},
		{"playlist-artwork.json", "s2y.playlist-artwork.v1", "playlists", true},
	} {
		entry := files.entries[path.Join(files.directory, kind.name)]
		if entry == nil {
			continue
		}
		var sidecar struct {
			Schema    string            `json:"schema"`
			Base      string            `json:"base_path"`
			Tracks    []json.RawMessage `json:"tracks"`
			Playlists []json.RawMessage `json:"playlists"`
		}
		if err := readZipJSON(entry, &sidecar); err != nil {
			s.artworkDiagnostic(job, kind.name, err)
			continue
		}
		if sidecar.Schema != kind.schema {
			s.artworkDiagnostic(job, kind.name, errors.New("unsupported artwork sidecar schema"))
			continue
		}
		rows := sidecar.Tracks
		if kind.playlist {
			rows = sidecar.Playlists
		}
		if rows == nil {
			s.artworkDiagnostic(job, kind.name, errors.New("artwork sidecar is missing its entries array"))
			continue
		}
		for _, raw := range rows {
			var item struct {
				Name        string          `json:"name"`
				Fingerprint string          `json:"fingerprint"`
				Artwork     json.RawMessage `json:"artwork"`
			}
			if err := json.Unmarshal(raw, &item); err != nil {
				s.artworkDiagnostic(job, kind.name, err)
				continue
			}
			target := item.Fingerprint
			if kind.playlist {
				target = item.Name
			}
			if strings.TrimSpace(target) == "" || len(item.Artwork) == 0 || string(item.Artwork) == "null" {
				s.artworkDiagnostic(job, kind.name, errors.New("artwork target and descriptor are required"))
				continue
			}
			add(target, sidecar.Base, kind.playlist, item.Artwork)
		}
	}
	return result
}

func validateBundleArtwork(files *bundleFiles, candidate bundleArtworkCandidate) ([]byte, error) {
	var descriptor bundleArtwork
	if err := json.Unmarshal(candidate.raw, &descriptor); err != nil {
		return nil, err
	}
	digest, err := hex.DecodeString(descriptor.SHA256)
	if err != nil || len(digest) != sha256.Size {
		return nil, errors.New("artwork requires a 64-character SHA-256")
	}
	if descriptor.MIME != "image/jpeg" && descriptor.MIME != "image/png" {
		return nil, errors.New("artwork must declare image/jpeg or image/png")
	}
	entry, err := files.relative(candidate.base, descriptor.File)
	if err != nil {
		return nil, err
	}
	if entry.UncompressedSize64 > maxImageBytes {
		return nil, errors.New("artwork exceeds 12 MiB")
	}
	reader, err := entry.Open()
	if err != nil {
		return nil, err
	}
	data, err := readArtwork(&http.Request{Header: make(http.Header), Body: reader})
	if err != nil {
		return nil, err
	}
	actual := sha256.Sum256(data)
	if !bytes.Equal(actual[:], digest) {
		return nil, errors.New("artwork SHA-256 does not match")
	}
	config, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	if "image/"+format != descriptor.MIME || config.Width != descriptor.Width || config.Height != descriptor.Height {
		return nil, errors.New("artwork MIME or dimensions do not match")
	}
	return data, nil
}

func (s *Server) applyBundleArtwork(ctx context.Context, job *ImportJob, files *bundleFiles, candidates []bundleArtworkCandidate, known map[string]string, playlists map[string]string, newEmbedded map[string]bool) {
	for _, candidate := range candidates {
		data, err := validateBundleArtwork(files, candidate)
		if err != nil {
			s.artworkDiagnostic(job, candidate.target, err)
			continue
		}
		destination := ""
		if candidate.playlist {
			id := playlists[candidate.target]
			if id != "" {
				destination = s.playlistArtworkPath(id)
			}
		} else if known[candidate.target] != "" {
			destination = s.artworkPath(candidate.target)
			if _, err := s.mediaPath(ctx, candidate.target, "artwork_path"); err == nil && !newEmbedded[candidate.target] {
				s.updateImportJob(job, func(j *ImportJob) { j.ArtworkAlreadyPresent++ })
				continue
			}
		}
		if destination == "" {
			s.artworkDiagnostic(job, candidate.target, errors.New("artwork target was not found exactly"))
			continue
		}
		// A cover already present before import wins. For a newly added song,
		// a validated external original takes precedence over its APIC fallback.
		createOnly := candidate.playlist || !newEmbedded[candidate.target]
		if err := writeArtwork(destination, data, createOnly); err != nil {
			if errors.Is(err, errArtworkExists) {
				s.updateImportJob(job, func(j *ImportJob) { j.ArtworkAlreadyPresent++ })
			} else {
				s.artworkDiagnostic(job, candidate.target, err)
			}
			continue
		}
		if !candidate.playlist {
			if err := s.attachMediaPath(ctx, candidate.target, "artwork_path", destination, 0); err != nil {
				s.artworkDiagnostic(job, candidate.target, err)
				continue
			}
		} else {
			s.libraryChanged()
		}
		s.updateImportJob(job, func(j *ImportJob) {
			j.ArtworkImported++
			if candidate.playlist {
				j.PlaylistArtworkImported++
			} else {
				j.TrackArtworkImported++
			}
		})
	}
}
