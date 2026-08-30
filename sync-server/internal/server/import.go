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
	ID           string `json:"id"`
	State        string `json:"state"` // running | done | failed
	Error        string `json:"error,omitempty"`
	Total        int    `json:"total"`
	Done         int    `json:"done"`
	Current      string `json:"current,omitempty"`
	Added        int    `json:"added"`
	Existing     int    `json:"existing"`
	Skipped      int    `json:"skipped"`
	PlaylistAdds int    `json:"playlist_adds"`
	Liked        int    `json:"liked"`
	StartedAtMs  int64  `json:"started_at_ms"`
	FinishedAtMs int64  `json:"finished_at_ms,omitempty"`
}

type importManifest struct {
	Schema    string           `json:"schema"`
	Tracks    []importTrack    `json:"tracks"`
	Playlists []importPlaylist `json:"playlists"`
}

type importTrack struct {
	File        string            `json:"file"`
	Title       string            `json:"title"`
	Artist      string            `json:"artist"`
	Album       string            `json:"album"`
	AlbumArtist *string           `json:"album_artist"`
	Genre       *string           `json:"genre"`
	Year        *int              `json:"year"`
	TrackNumber *int              `json:"track_number"`
	DurationMs  *float64          `json:"duration_ms"`
	Liked       bool              `json:"liked"`
	Playlists   []string          `json:"playlists"`
	Fingerprint string            `json:"fingerprint"`
	Identifiers map[string]string `json:"identifiers"`
	SourceURLs  map[string]string `json:"source_urls"`
}

type importPlaylist struct {
	Name   string            `json:"name"`
	Mode   string            `json:"mode"`
	Tracks []json.RawMessage `json:"tracks"`
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
	if _, err := io.Copy(file, r.Body); err != nil {
		file.Close()
		os.Remove(bundlePath)
		writeError(w, http.StatusBadRequest, fmt.Errorf("upload interrupted: %w", err))
		return
	}
	file.Close()

	job := &ImportJob{ID: id, State: "running", StartedAtMs: s.now().UnixMilli()}
	s.importMu.Lock()
	if s.importJobs == nil {
		s.importJobs = map[string]*ImportJob{}
	}
	s.importJobs[id] = job
	s.importMu.Unlock()

	go s.runBundleImport(job, bundlePath)
	writeJSON(w, http.StatusAccepted, map[string]string{"id": id})
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

	var manifestEntry *zip.File
	byPath := map[string]*zip.File{}
	byBase := map[string]*zip.File{}
	for _, entry := range archive.File {
		if entry.FileInfo().IsDir() {
			continue
		}
		base := path.Base(entry.Name)
		if base == "codec-import.json" || (manifestEntry == nil && strings.HasSuffix(strings.ToLower(base), ".json")) {
			manifestEntry = entry
			continue
		}
		byPath[entry.Name] = entry
		byBase[strings.ToLower(base)] = entry
	}
	if manifestEntry == nil {
		fail(errors.New("bundle has no loud.import.v1 manifest"))
		return
	}

	var manifest importManifest
	if err := readZipJSON(manifestEntry, &manifest); err != nil {
		fail(fmt.Errorf("manifest: %w", err))
		return
	}
	if manifest.Schema != "" && manifest.Schema != "loud.import.v1" {
		fail(fmt.Errorf("unsupported import schema %q", manifest.Schema))
		return
	}

	known, err := s.knownFingerprints(ctx)
	if err != nil {
		fail(err)
		return
	}
	s.updateImportJob(job, func(j *ImportJob) { j.Total = len(manifest.Tracks) })

	identityByFile := map[string]string{}
	var likedTargets []string

	for index, track := range manifest.Tracks {
		identity := importIdentity(track)
		if track.File != "" {
			identityByFile[track.File] = identity
		}
		s.updateImportJob(job, func(j *ImportJob) {
			j.Done = index
			j.Current = firstNonEmptyString(track.Title, path.Base(track.File))
		})

		if known[identity] {
			s.updateImportJob(job, func(j *ImportJob) { j.Existing++ })
		} else {
			entry := byPath[track.File]
			if entry == nil && track.File != "" {
				entry = byBase[strings.ToLower(path.Base(track.File))]
			}
			if entry == nil {
				s.updateImportJob(job, func(j *ImportJob) { j.Skipped++ })
				continue
			}
			if err := s.importBundleTrack(ctx, track, identity, entry); err != nil {
				s.updateImportJob(job, func(j *ImportJob) { j.Skipped++ })
				continue
			}
			known[identity] = true
			s.updateImportJob(job, func(j *ImportJob) { j.Added++ })
		}

		if track.Liked {
			likedTargets = append(likedTargets, identity)
		}
	}
	s.updateImportJob(job, func(j *ImportJob) {
		j.Done = len(manifest.Tracks)
		j.Current = "Applying likes and playlists"
	})

	for _, identity := range likedTargets {
		if err := s.setTrackLiked(ctx, identity, true); err == nil {
			s.updateImportJob(job, func(j *ImportJob) { j.Liked++ })
		}
	}

	// Playlist membership: track-level names plus the playlists section.
	wanted := map[string][]string{}
	order := []string{}
	want := func(name, identity string) {
		name = strings.TrimSpace(name)
		if name == "" || identity == "" {
			return
		}
		if _, seen := wanted[name]; !seen {
			order = append(order, name)
		}
		wanted[name] = append(wanted[name], identity)
	}
	for _, track := range manifest.Tracks {
		for _, name := range track.Playlists {
			want(name, importIdentity(track))
		}
	}
	for _, playlist := range manifest.Playlists {
		for _, raw := range playlist.Tracks {
			want(playlist.Name, importPlaylistRefIdentity(raw, identityByFile))
		}
	}

	existingPlaylists, err := s.playlists(ctx)
	if err != nil {
		fail(err)
		return
	}
	for _, name := range order {
		var target *Playlist
		for i := range existingPlaylists {
			if !existingPlaylists[i].IsLiked && strings.EqualFold(existingPlaylists[i].Name, name) {
				target = &existingPlaylists[i]
				break
			}
		}
		if target == nil {
			created, err := s.createPlaylist(ctx, name)
			if err != nil {
				continue
			}
			existingPlaylists = append(existingPlaylists, created)
			target = &existingPlaylists[len(existingPlaylists)-1]
		}
		have := map[string]bool{}
		for _, id := range target.TrackIDs {
			have[id] = true
		}
		for _, identity := range wanted[name] {
			trackID := "track_" + identity
			if have[trackID] || !known[identity] {
				continue
			}
			if _, err := s.modifyPlaylistTracks(ctx, target.ID, func(ids []string) []string {
				return append(ids, trackID)
			}); err == nil {
				have[trackID] = true
				s.updateImportJob(job, func(j *ImportJob) { j.PlaylistAdds++ })
			}
		}
	}

	s.updateImportJob(job, func(j *ImportJob) {
		j.State = "done"
		j.Current = ""
		j.FinishedAtMs = s.now().UnixMilli()
	})
}

func (s *Server) importBundleTrack(ctx context.Context, entry importTrack, identity string, file *zip.File) error {
	audioPath := s.audioPath(identity)
	size, err := extractZipEntry(file, audioPath)
	if err != nil {
		return err
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
		SizeBytes:   size,
		IsLiked:     entry.Liked,
		Fingerprint: identity,
		Identifiers: entry.Identifiers,
		SourceURLs:  entry.SourceURLs,
	}
	if entry.DurationMs != nil && *entry.DurationMs > 0 {
		seconds := *entry.DurationMs / 1000
		track.DurationSeconds = &seconds
	}
	added := s.now().Unix()
	track.AddedAt = &added

	if err := s.upsertTrack(ctx, track); err != nil {
		return err
	}
	if err := s.attachMediaPath(ctx, identity, "audio_path", audioPath, size); err != nil {
		return err
	}
	if len(tags.Artwork) > 0 {
		artworkPath := s.artworkPath(identity)
		if err := os.WriteFile(artworkPath, tags.Artwork, 0o644); err == nil {
			_ = s.attachMediaPath(ctx, identity, "artwork_path", artworkPath, 0)
		}
	}
	return nil
}

func (s *Server) knownFingerprints(ctx context.Context) (map[string]bool, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT fingerprint FROM tracks`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	known := map[string]bool{}
	for rows.Next() {
		var fingerprint string
		if err := rows.Scan(&fingerprint); err != nil {
			return nil, err
		}
		known[fingerprint] = true
	}
	return known, rows.Err()
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
	get := func(key string) string { return strings.TrimSpace(identifiers[key]) }
	if isrc := get("isrc"); isrc != "" {
		return "isrc:" + strings.ToUpper(isrc)
	}
	if mbid := get("musicbrainz_recording_id"); mbid != "" {
		return "mbid:" + mbid
	}
	if spotify := get("spotify_track_id"); spotify != "" {
		return "spotify:track:" + spotify
	}
	if youtube := get("youtube_video_id"); youtube != "" {
		return "youtube:" + youtube
	}
	return ""
}

func importPlaylistRefIdentity(raw json.RawMessage, identityByFile map[string]string) string {
	var file string
	if err := json.Unmarshal(raw, &file); err == nil {
		return identityByFile[file]
	}
	var ref importPlaylistRef
	if err := json.Unmarshal(raw, &ref); err != nil {
		return ""
	}
	if explicit := strings.TrimSpace(ref.Fingerprint); explicit != "" {
		return explicit
	}
	if identity := primaryIdentifierIdentity(ref.Identifiers); identity != "" {
		return identity
	}
	return identityByFile[ref.File]
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
	return json.NewDecoder(io.LimitReader(reader, maxJSONBytes)).Decode(into)
}

func extractZipEntry(entry *zip.File, destination string) (int64, error) {
	reader, err := entry.Open()
	if err != nil {
		return 0, err
	}
	defer reader.Close()
	tmp := destination + ".part"
	file, err := os.Create(tmp)
	if err != nil {
		return 0, err
	}
	size, err := io.Copy(file, reader)
	file.Close()
	if err != nil {
		os.Remove(tmp)
		return 0, err
	}
	return size, os.Rename(tmp, destination)
}

func firstNonEmptyString(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}
