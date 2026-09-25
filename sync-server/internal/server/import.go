// Server-side bundle import: a .loud.zip is uploaded once, then unpacked and
// applied in a background job. Progress lives on the server, so a client can
// close the tab, refresh, and pick the job back up by id.
package server

import (
	"archive/zip"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"
)

type ImportJob struct {
	ID                      string   `json:"id"`
	State                   string   `json:"state"` // running | done | failed
	Error                   string   `json:"error,omitempty"`
	Total                   int      `json:"total"`
	Done                    int      `json:"done"`
	Current                 string   `json:"current,omitempty"`
	Added                   int      `json:"added"`
	Existing                int      `json:"existing"`
	Skipped                 int      `json:"skipped"`
	PlaylistAdds            int      `json:"playlist_adds"`
	Liked                   int      `json:"liked"`
	AudioRestored           int      `json:"audio_restored"`
	StartedAtMs             int64    `json:"started_at_ms"`
	FinishedAtMs            int64    `json:"finished_at_ms,omitempty"`
	ArtworkImported         int      `json:"artwork_imported"`
	TrackArtworkImported    int      `json:"track_artwork_imported"`
	PlaylistArtworkImported int      `json:"playlist_artwork_imported"`
	ArtworkAlreadyPresent   int      `json:"artwork_already_present"`
	ArtworkMissing          int      `json:"artwork_missing"`
	ArtworkFailed           int      `json:"artwork_failed"`
	ArtworkWarnings         []string `json:"artwork_warnings,omitempty"`
}

type importManifest struct {
	Schema string `json:"schema"`
	Source struct {
		BasePath string `json:"base_path"`
	} `json:"source"`
	Tracks    []importTrack    `json:"tracks"`
	Playlists []importPlaylist `json:"playlists"`
}

type importTrack struct {
	File            string            `json:"file"`
	Title           string            `json:"title"`
	Artist          string            `json:"artist"`
	Album           string            `json:"album"`
	AlbumArtist     *string           `json:"album_artist"`
	Genre           *string           `json:"genre"`
	Year            *int              `json:"year"`
	TrackNumber     *int              `json:"track_number"`
	DiscNumber      *int              `json:"disc_number"`
	Explicit        *bool             `json:"explicit"`
	DurationMs      *float64          `json:"duration_ms"`
	DurationSeconds *float64          `json:"duration_seconds"`
	Artwork         json.RawMessage   `json:"artwork,omitempty"`
	Liked           bool              `json:"liked"`
	Playlists       []string          `json:"playlists"`
	Fingerprint     string            `json:"fingerprint"`
	Identifiers     map[string]string `json:"identifiers"`
	SourceURLs      map[string]string `json:"source_urls"`
}

type importPlaylist struct {
	Name    string            `json:"name"`
	Mode    string            `json:"mode"`
	Tracks  []json.RawMessage `json:"tracks"`
	Artwork json.RawMessage   `json:"artwork,omitempty"`
}

type importPlaylistRef struct {
	Fingerprint string            `json:"fingerprint"`
	Identifiers map[string]string `json:"identifiers"`
	File        string            `json:"file"`
}

// --- HTTP ------------------------------------------------------------------

func (s *Server) handleImportBundle(w http.ResponseWriter, r *http.Request) {
	dir := filepath.Join(s.dataDir, "imports")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	id := newImportJobID()
	bundlePath := filepath.Join(dir, id+".zip")
	file, err := os.Create(bundlePath)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	written, copyErr := io.Copy(file, io.LimitReader(r.Body, maxBundleBytes+1))
	if copyErr != nil || written > maxBundleBytes {
		file.Close()
		os.Remove(bundlePath)
		if copyErr != nil {
			writeError(w, http.StatusBadRequest, fmt.Errorf("upload interrupted: %w", copyErr))
		} else {
			writeError(w, http.StatusRequestEntityTooLarge, errors.New("bundle exceeds the 64 GiB upload limit"))
		}
		return
	}
	if err := file.Close(); err != nil {
		os.Remove(bundlePath)
		writeError(w, http.StatusInternalServerError, errors.New("could not finish saving the upload"))
		return
	}
	s.startImportJob(id, bundlePath)
	writeJSON(w, http.StatusAccepted, map[string]string{"id": id})
}

func (s *Server) startImportJob(id, bundlePath string) {
	job := &ImportJob{ID: id, State: "running", Current: "Waiting to import", StartedAtMs: s.now().UnixMilli()}
	s.importMu.Lock()
	if s.importJobs == nil {
		s.importJobs = map[string]*ImportJob{}
	}
	s.importJobs[id] = job
	s.importMu.Unlock()

	go s.runBundleImport(job, bundlePath)
}

func (s *Server) handleImportJob(w http.ResponseWriter, r *http.Request) {
	s.importMu.Lock()
	job, ok := s.importJobs[r.PathValue("id")]
	var snapshot ImportJob
	if ok {
		snapshot = *job
	}
	s.importMu.Unlock()
	if !ok {
		writeError(w, http.StatusNotFound, errors.New("unknown import job"))
		return
	}
	writeJSON(w, http.StatusOK, snapshot)
}

func (s *Server) updateImportJob(job *ImportJob, mutate func(*ImportJob)) {
	s.importMu.Lock()
	mutate(job)
	s.importMu.Unlock()
}

func newImportJobID() string {
	raw := make([]byte, 8)
	if _, err := rand.Read(raw); err != nil {
		return fmt.Sprintf("import_%d", time.Now().UnixNano())
	}
	return "import_" + hex.EncodeToString(raw)
}

// --- The job -----------------------------------------------------------------

func (s *Server) runBundleImport(job *ImportJob, bundlePath string) {
	defer os.Remove(bundlePath)
	// Two bundle jobs must not race their additive identity/presence decisions.
	s.bundleImportMu.Lock()
	defer s.bundleImportMu.Unlock()
	s.updateImportJob(job, func(j *ImportJob) { j.Current = "Checking ZIP archive" })
	ctx := context.Background()
	fail := func(err error) {
		s.updateImportJob(job, func(j *ImportJob) {
			j.State = "failed"
			j.Error = err.Error()
			j.Current = ""
			j.FinishedAtMs = s.now().UnixMilli()
		})
	}
	archive, err := zip.OpenReader(bundlePath)
	if err != nil {
		fail(fmt.Errorf("not a zip bundle: %w", err))
		return
	}
	defer archive.Close()
	files, err := indexBundle(archive)
	if err != nil {
		fail(err)
		return
	}
	var manifest importManifest
	if err := readZipJSON(files.manifest, &manifest); err != nil {
		fail(fmt.Errorf("manifest: %w", err))
		return
	}
	if manifest.Schema != "" && manifest.Schema != "loud.import.v1" {
		fail(fmt.Errorf("unsupported import schema %q", manifest.Schema))
		return
	}
	if _, err := bundleRelativePath(manifest.Source.BasePath); err != nil {
		fail(fmt.Errorf("source.base_path: %w", err))
		return
	}
	s.updateImportJob(job, func(j *ImportJob) { j.Total = len(manifest.Tracks); j.Current = "Checking music and playlists" })
	// Derive metadata-based identities from the same tags/filename fallbacks
	// that will be stored, before matching or building any playlist references.
	// Reading the bounded ID3 prefix does not extract audio or mutate the library.
	for index := range manifest.Tracks {
		track := &manifest.Tracks[index]
		if strings.TrimSpace(track.Fingerprint) != "" || primaryIdentifierIdentity(track.Identifiers) != "" {
			continue
		}
		var tags id3Tags
		if strings.TrimSpace(track.Title) == "" || strings.TrimSpace(track.Artist) == "" || strings.TrimSpace(track.Album) == "" {
			if entry, err := files.audio(manifest.Source.BasePath, track.File); err == nil {
				if reader, err := entry.Open(); err == nil {
					tags = parseID3Reader(reader)
					reader.Close()
				}
			}
		}
		track.Title = firstNonEmptyString(track.Title, tags.Title, strings.TrimSuffix(path.Base(track.File), path.Ext(track.File)))
		track.Artist = firstNonEmptyString(track.Artist, tags.Artist, "Unknown Artist")
		track.Album = firstNonEmptyString(track.Album, tags.Album, "Unknown Album")
	}
	existingTracks, err := s.tracks(ctx, "")
	if err != nil {
		fail(err)
		return
	}
	known := map[string]string{}
	likedBefore := map[string]bool{}
	newEmbedded := map[string]bool{}
	mediaNames := map[string]string{}
	for _, track := range existingTracks {
		known[track.Fingerprint] = track.ID
		likedBefore[track.Fingerprint] = track.IsLiked
		mediaNames[strings.ToLower(s.audioPath(track.Fingerprint))] = track.Fingerprint
	}
	identityByFile := map[string]string{}
	for _, track := range manifest.Tracks {
		identity := importIdentity(track)
		if prior := identityByFile[track.File]; track.File != "" && prior != "" && prior != identity {
			fail(fmt.Errorf("audio file %q has multiple explicit identities", track.File))
			return
		}
		if track.File != "" {
			identityByFile[track.File] = identity
		}
		destination := strings.ToLower(s.audioPath(identity))
		if prior := mediaNames[destination]; prior != "" && prior != identity {
			fail(errors.New("distinct fingerprints collide on the server media filename"))
			return
		}
		mediaNames[destination] = identity
	}
	// Playlist references may use a provider ID even when the track chose an
	// explicit canonical fingerprint. Ambiguous aliases never choose a song;
	// an actual fingerprint always takes precedence over another song's alias.
	identities := map[string]string{}
	for fingerprint := range known {
		identities[fingerprint] = fingerprint
	}
	for _, track := range manifest.Tracks {
		fingerprint := importIdentity(track)
		identities[fingerprint] = fingerprint
	}
	ambiguous := map[string]bool{}
	registerAliases := func(fingerprint string, identifiers map[string]string) {
		for _, alias := range identifierIdentityCandidates(identifiers) {
			if identities[alias] == alias || ambiguous[alias] {
				continue
			}
			if prior := identities[alias]; prior != "" && prior != fingerprint {
				delete(identities, alias)
				ambiguous[alias] = true
			} else {
				identities[alias] = fingerprint
			}
		}
	}
	for _, track := range existingTracks {
		registerAliases(track.Fingerprint, track.Identifiers)
	}
	for _, track := range manifest.Tracks {
		registerAliases(importIdentity(track), track.Identifiers)
	}
	candidates := s.bundleArtworkCandidates(job, files, manifest)
	existingPlaylists, err := s.playlists(ctx)
	if err != nil {
		fail(err)
		return
	}
	targets := map[string]string{}
	names := map[string]string{}
	validateName := func(name string) error {
		name = strings.TrimSpace(name)
		if name == "" {
			return errors.New("playlist name is empty")
		}
		normalized := normalizeIdentity(name)
		if prior, ok := names[normalized]; ok && prior != name {
			return fmt.Errorf("ambiguous playlist names %q and %q", prior, name)
		}
		names[normalized] = name
		for _, playlist := range existingPlaylists {
			if playlist.IsLiked || normalizeIdentity(playlist.Name) != normalized {
				continue
			}
			if strings.TrimSpace(playlist.Name) != name {
				return fmt.Errorf("playlist %q conflicts with existing %q", name, playlist.Name)
			}
			if prior := targets[name]; prior != "" && prior != playlist.ID {
				return fmt.Errorf("multiple existing playlists named %q", name)
			}
			targets[name] = playlist.ID
		}
		return nil
	}
	wanted := map[string][]string{}
	order := []string{}
	want := func(name, identity string) {
		name = strings.TrimSpace(name)
		if name == "" {
			return
		}
		if _, ok := wanted[name]; !ok {
			wanted[name] = []string{}
			order = append(order, name)
		}
		if identity != "" {
			wanted[name] = append(wanted[name], identity)
		}
	}
	// Explicit playlist order wins; track-level membership only appends omissions.
	for _, playlist := range manifest.Playlists {
		if err := validateName(playlist.Name); err != nil {
			fail(err)
			return
		}
		want(playlist.Name, "") // Empty and artwork-only playlists are real collections.
		for _, ref := range playlist.Tracks {
			want(playlist.Name, importPlaylistRefIdentity(ref, identityByFile, identities))
		}
	}
	for _, track := range manifest.Tracks {
		for _, name := range track.Playlists {
			if err := validateName(name); err != nil {
				fail(err)
				return
			}
			want(name, importIdentity(track))
		}
	}
	validCandidates := make([]bundleArtworkCandidate, 0, len(candidates))
	for _, candidate := range candidates {
		if candidate.playlist {
			// An invalid optional cover is an artwork diagnostic, not a fatal
			// playlist alias. Only usable covers participate in name preflight.
			if _, err := validateBundleArtwork(files, candidate); err != nil {
				s.artworkDiagnostic(job, candidate.target, err)
				continue
			}
			if err := validateName(candidate.target); err != nil {
				fail(err)
				return
			}
		}
		validCandidates = append(validCandidates, candidate)
	}
	candidates = validCandidates
	for index, track := range manifest.Tracks {
		identity := importIdentity(track)
		s.updateImportJob(job, func(j *ImportJob) {
			j.Done = index
			j.Current = firstNonEmptyString(track.Title, path.Base(track.File))
		})
		if known[identity] != "" {
			s.updateImportJob(job, func(j *ImportJob) { j.Existing++ })
			if _, err := s.mediaPath(ctx, identity, "audio_path"); errors.Is(err, os.ErrNotExist) {
				// The metadata may have arrived before its audio, or a blob may
				// have been deleted. Fill it without upserting tags/likes/IDs.
				if entry, err := files.audio(manifest.Source.BasePath, track.File); err == nil {
					embedded, err := s.restoreBundleAudio(ctx, identity, entry)
					if err != nil {
						s.updateImportJob(job, func(j *ImportJob) { j.Skipped++ })
					} else {
						newEmbedded[identity] = embedded
						s.updateImportJob(job, func(j *ImportJob) { j.AudioRestored++ })
					}
				}
			}
		} else {
			entry, err := files.audio(manifest.Source.BasePath, track.File)
			if err != nil {
				s.updateImportJob(job, func(j *ImportJob) { j.Skipped++ })
				continue
			}
			embedded, err := s.importBundleTrack(ctx, track, identity, entry)
			if err != nil {
				s.updateImportJob(job, func(j *ImportJob) { j.Skipped++ })
				continue
			}
			known[identity] = "track_" + identity
			newEmbedded[identity] = embedded
			s.updateImportJob(job, func(j *ImportJob) { j.Added++ })
		}
		if track.Liked && !likedBefore[identity] {
			if err := s.setTrackLiked(ctx, identity, true); err == nil {
				likedBefore[identity] = true
				s.updateImportJob(job, func(j *ImportJob) { j.Liked++ })
			}
		}
	}
	s.updateImportJob(job, func(j *ImportJob) { j.Done = len(manifest.Tracks); j.Current = "Applying playlists and artwork" })
	for _, name := range order {
		id := targets[name]
		if id == "" {
			playlist, err := s.createPlaylist(ctx, name)
			if err != nil {
				fail(err)
				return
			}
			id = playlist.ID
			targets[name] = id
		}
		additions := 0
		_, err := s.modifyPlaylistTracks(ctx, id, func(ids []string) []string {
			have := map[string]bool{}
			for _, id := range ids {
				have[id] = true
			}
			for _, identity := range wanted[name] {
				trackID := known[identity]
				if trackID == "" || have[trackID] {
					continue
				}
				ids = append(ids, trackID)
				have[trackID] = true
				additions++
			}
			return ids
		})
		if err != nil {
			fail(err)
			return
		}
		s.updateImportJob(job, func(j *ImportJob) { j.PlaylistAdds += additions })
	}
	s.applyBundleArtwork(ctx, job, files, candidates, known, targets, newEmbedded)
	s.updateImportJob(job, func(j *ImportJob) { j.State = "done"; j.Current = ""; j.FinishedAtMs = s.now().UnixMilli() })
}

func (s *Server) importBundleTrack(ctx context.Context, entry importTrack, identity string, file *zip.File) (bool, error) {
	audioPath := s.audioPath(identity)
	size, err := extractZipEntry(file, audioPath)
	if err != nil {
		return false, err
	}

	tags := parseID3File(audioPath)
	title := firstNonEmptyString(entry.Title, tags.Title, strings.TrimSuffix(path.Base(file.Name), path.Ext(file.Name)))
	artist := firstNonEmptyString(entry.Artist, tags.Artist, "Unknown Artist")
	album := firstNonEmptyString(entry.Album, tags.Album, "Unknown Album")

	track := Track{
		ID:          "track_" + identity,
		Path:        "loud://import/" + identity + "/" + path.Base(file.Name),
		FileName:    path.Base(file.Name),
		Title:       title,
		Artist:      artist,
		Album:       album,
		AlbumArtist: entry.AlbumArtist,
		Genre:       entry.Genre,
		Year:        entry.Year,
		TrackNumber: entry.TrackNumber,
		DiscNumber:  entry.DiscNumber,
		Explicit:    entry.Explicit,
		SizeBytes:   size,
		IsLiked:     entry.Liked,
		Fingerprint: identity,
		Identifiers: entry.Identifiers,
		SourceURLs:  entry.SourceURLs,
	}
	if entry.DurationSeconds != nil && *entry.DurationSeconds >= 0 {
		track.DurationSeconds = entry.DurationSeconds
	} else if entry.DurationMs != nil && *entry.DurationMs > 0 {
		seconds := *entry.DurationMs / 1000
		track.DurationSeconds = &seconds
	}
	added := s.now().Unix()
	track.AddedAt = &added

	if err := s.upsertTrack(ctx, track); err != nil {
		return false, err
	}
	return s.attachBundleAudio(ctx, identity, file.Name, audioPath, size, tags)
}

func (s *Server) restoreBundleAudio(ctx context.Context, identity string, file *zip.File) (bool, error) {
	audioPath := s.audioPath(identity)
	size, err := extractZipEntry(file, audioPath)
	if err != nil {
		return false, err
	}
	return s.attachBundleAudio(ctx, identity, file.Name, audioPath, size, parseID3File(audioPath))
}

func (s *Server) attachBundleAudio(ctx context.Context, identity, filename, audioPath string, size int64, tags id3Tags) (bool, error) {
	if err := s.setAudioType(ctx, identity, bundleAudioType(filename)); err != nil {
		return false, err
	}
	if err := s.attachMediaPath(ctx, identity, "audio_path", audioPath, size); err != nil {
		return false, err
	}
	if len(tags.Artwork) > 0 {
		if _, err := s.mediaPath(ctx, identity, "artwork_path"); err == nil {
			return false, nil
		}
		artworkPath := s.artworkPath(identity)
		if err := writeArtwork(artworkPath, tags.Artwork, true); err == nil {
			return true, s.attachMediaPath(ctx, identity, "artwork_path", artworkPath, 0)
		}
	}
	return false, nil
}

// --- Identity (docs/codec-import-v1.md; mirrors src-tauri util.rs) ----------

func importIdentity(track importTrack) string {
	if explicit := strings.TrimSpace(track.Fingerprint); explicit != "" {
		return explicit
	}
	if identity := primaryIdentifierIdentity(track.Identifiers); identity != "" {
		return identity
	}
	return fingerprintFor(track.Title, track.Artist, track.Album)
}

func primaryIdentifierIdentity(identifiers map[string]string) string {
	if identities := identifierIdentityCandidates(identifiers); len(identities) > 0 {
		return identities[0]
	}
	return ""
}

func identifierIdentityCandidates(identifiers map[string]string) []string {
	get := func(key string) string { return strings.TrimSpace(identifiers[key]) }
	result := make([]string, 0, 4)
	if isrc := get("isrc"); isrc != "" {
		result = append(result, "isrc:"+strings.ToUpper(isrc))
	}
	if mbid := get("musicbrainz_recording_id"); mbid != "" {
		result = append(result, "mbid:"+mbid)
	}
	if spotify := get("spotify_track_id"); spotify != "" {
		result = append(result, "spotify:track:"+spotify)
	}
	if youtube := get("youtube_video_id"); youtube != "" {
		result = append(result, "youtube:"+youtube)
	}
	return result
}

func importPlaylistRefIdentity(raw json.RawMessage, identityByFile, identities map[string]string) string {
	var file string
	if err := json.Unmarshal(raw, &file); err == nil {
		if identity := identityByFile[file]; identity != "" {
			return identity
		}
		return identities[strings.TrimSpace(file)]
	}
	var ref importPlaylistRef
	if err := json.Unmarshal(raw, &ref); err != nil {
		return ""
	}
	if explicit := strings.TrimSpace(ref.Fingerprint); explicit != "" {
		return explicit
	}
	if identity := identityByFile[ref.File]; identity != "" {
		return identity
	}
	for _, alias := range identifierIdentityCandidates(ref.Identifiers) {
		if identity := identities[alias]; identity != "" {
			return identity
		}
	}
	return ""
}

// fingerprintFor matches util.rs fingerprint_for: FNV-1a 64 over the
// normalized "title|artist|album".
func fingerprintFor(title, artist, album string) string {
	hasher := fnv.New64a()
	hasher.Write([]byte(normalizeIdentity(title) + "|" + normalizeIdentity(artist) + "|" + normalizeIdentity(album)))
	return fmt.Sprintf("%016x", hasher.Sum64())
}

func normalizeIdentity(value string) string {
	return strings.ToLower(strings.Join(strings.Fields(value), " "))
}

// --- Zip helpers -------------------------------------------------------------

func readZipJSON(entry *zip.File, into any) error {
	reader, err := entry.Open()
	if err != nil {
		return err
	}
	defer reader.Close()
	if entry.UncompressedSize64 > maxJSONBytes {
		return errors.New("JSON entry exceeds 32 MiB")
	}
	data, err := io.ReadAll(io.LimitReader(reader, maxJSONBytes+1))
	if err != nil {
		return err
	}
	if len(data) > maxJSONBytes {
		return errors.New("JSON entry exceeds 32 MiB")
	}
	return json.Unmarshal(data, into)
}

func extractZipEntry(entry *zip.File, destination string) (int64, error) {
	reader, err := entry.Open()
	if err != nil {
		return 0, err
	}
	defer reader.Close()
	if fileSize := entry.UncompressedSize64; fileSize == 0 || fileSize > maxAudioBytes {
		return 0, errors.New("audio must be nonempty and at most 400 MiB")
	}
	file, err := os.CreateTemp(filepath.Dir(destination), ".bundle-audio-*")
	if err != nil {
		return 0, err
	}
	tmp := file.Name()
	defer os.Remove(tmp)
	size, err := io.Copy(file, io.LimitReader(reader, maxAudioBytes+1))
	closeErr := file.Close()
	if err != nil {
		return 0, err
	}
	if closeErr != nil {
		return 0, closeErr
	}
	if size == 0 || size > maxAudioBytes {
		return 0, errors.New("audio must be nonempty and at most 400 MiB")
	}
	// A stale concurrent upload must never truncate or replace existing audio.
	if err := os.Link(tmp, destination); err != nil {
		return 0, err
	}
	return size, nil
}

func firstNonEmptyString(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func bundleAudioType(name string) string {
	switch strings.ToLower(path.Ext(name)) {
	case ".flac":
		return "audio/flac"
	case ".wav":
		return "audio/wav"
	case ".m4a", ".mp4":
		return "audio/mp4"
	default:
		return "audio/mpeg"
	}
}
