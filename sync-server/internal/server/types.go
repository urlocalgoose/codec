package server

type Library struct {
	RootPath  string          `json:"root_path"`
	ScannedAt int64           `json:"scanned_at"`
	Stats     LibraryStats    `json:"stats"`
	Artists   []ArtistSummary `json:"artists"`
	Albums    []AlbumSummary  `json:"albums"`
	Playlists []Playlist      `json:"playlists"`
	Tracks    []Track         `json:"tracks"`
}

type LibraryStats struct {
	TrackCount      int     `json:"trackCount"`
	PlaylistCount   int     `json:"playlistCount"`
	LikedCount      int     `json:"likedCount"`
	ArtistCount     int     `json:"artistCount"`
	AlbumCount      int     `json:"albumCount"`
	DurationSeconds float64 `json:"durationSeconds"`
}

type ArtistSummary struct {
	Name            string  `json:"name"`
	TrackCount      int     `json:"trackCount"`
	AlbumCount      int     `json:"albumCount"`
	DurationSeconds float64 `json:"durationSeconds"`
}

type AlbumSummary struct {
	Name            string  `json:"name"`
	Artist          string  `json:"artist"`
	TrackCount      int     `json:"trackCount"`
	DurationSeconds float64 `json:"durationSeconds"`
	ArtworkURL      *string `json:"artwork_url"`
}

type Playlist struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Path     string   `json:"path"`
	TrackIDs []string `json:"track_ids"`
	IsLiked  bool     `json:"is_liked"`
}

type Track struct {
	ID              string            `json:"id"`
	Path            string            `json:"path"`
	FileName        string            `json:"file_name"`
	Title           string            `json:"title"`
	Artist          string            `json:"artist"`
	Album           string            `json:"album"`
	AlbumArtist     *string           `json:"album_artist"`
	Genre           *string           `json:"genre"`
	Year            *int              `json:"year"`
	TrackNumber     *int              `json:"track_number"`
	DurationSeconds *float64          `json:"duration_seconds"`
	ArtworkURL      *string           `json:"artwork_url"`
	AudioURL        *string           `json:"audio_url,omitempty"`
	PlaylistIDs     []string          `json:"playlist_ids"`
	AddedAt         *int64            `json:"added_at"`
	SizeBytes       int64             `json:"size_bytes"`
	IsLiked         bool              `json:"is_liked"`
	Fingerprint     string            `json:"fingerprint"`
	Identifiers     map[string]string `json:"identifiers,omitempty"`
	SourceURLs      map[string]string `json:"source_urls,omitempty"`
	UpdatedAt       int64             `json:"updated_at,omitempty"`
}

type SyncSnapshot struct {
	Schema      string  `json:"schema"`
	ServerID    string  `json:"server_id"`
	GeneratedAt int64   `json:"generated_at"`
	Library     Library `json:"library"`
}

type PushRequest struct {
	Schema          string           `json:"schema"`
	DeviceID        string           `json:"device_id"`
	Library         Library          `json:"library"`
	PlaybackSession *PlaybackSession `json:"playback_session,omitempty"`
}

type PlaybackSession struct {
	DeviceID  string         `json:"device_id"`
	SavedAt   int64          `json:"saved_at"`
	Session   map[string]any `json:"session"`
	UpdatedAt int64          `json:"updated_at"`
}

type PlaybackDevice struct {
	DeviceID         string  `json:"device_id"`
	Name             string  `json:"name"`
	TrackID          *string `json:"track_id"`
	TrackFingerprint *string `json:"track_fingerprint"`
	TrackTitle       *string `json:"track_title"`
	IsPlaying        bool    `json:"is_playing"`
	PositionSeconds  float64 `json:"position_seconds"`
	Volume           float64 `json:"volume"`
	UpdatedAt        int64   `json:"updated_at"`
}

type ActivePlayback struct {
	DeviceID         string  `json:"device_id"`
	TrackID          *string `json:"track_id"`
	TrackFingerprint *string `json:"track_fingerprint"`
	TrackTitle       *string `json:"track_title"`
	IsPlaying        bool    `json:"is_playing"`
	PositionSeconds  float64 `json:"position_seconds"`
	Volume           float64 `json:"volume"`
	UpdatedAt        int64   `json:"updated_at"`
}

type PlaybackTransferRequest struct {
	DeviceID         string  `json:"device_id"`
	TrackID          *string `json:"track_id,omitempty"`
	TrackFingerprint *string `json:"track_fingerprint,omitempty"`
	TrackTitle       *string `json:"track_title,omitempty"`
	IsPlaying        bool    `json:"is_playing"`
	PositionSeconds  float64 `json:"position_seconds"`
	Volume           float64 `json:"volume"`
}

type PlaybackEvent struct {
	Type          string           `json:"type"`
	Device        *PlaybackDevice  `json:"device,omitempty"`
	Devices       []PlaybackDevice `json:"devices,omitempty"`
	Active        *ActivePlayback  `json:"active,omitempty"`
	PlaybackState *PlaybackStateV2 `json:"playback_state,omitempty"`
}

type SyncReport struct {
	TracksUpserted    int `json:"tracks_upserted"`
	PlaylistsUpserted int `json:"playlists_upserted"`
	SessionsUpserted  int `json:"sessions_upserted"`
}

type TrackReference struct {
	ID          string `json:"id"`
	Path        string `json:"path"`
	Fingerprint string `json:"fingerprint"`
	// Foreign-track fields: a track queued from ANOTHER Codec server rides
	// with everything needed to play it - a granted media URL plus display
	// metadata - so the host library never has to contain it.
	Title      string `json:"title,omitempty"`
	Artist     string `json:"artist,omitempty"`
	MediaURL   string `json:"media_url,omitempty"`
	ArtworkURL string `json:"artwork_url,omitempty"`
}

type PlaybackClockV2 struct {
	PositionSeconds float64 `json:"position_seconds"`
	StartedAtMS     *int64  `json:"started_at_ms"`
	StoppedAtMS     *int64  `json:"stopped_at_ms"`
	UpdatedAtMS     int64   `json:"updated_at_ms"`
}

type PlaybackContextV2 struct {
	PlaybackSource []TrackReference `json:"playback_source"`
	PlaybackIndex  int              `json:"playback_index"`
	QueuedTracks   []TrackReference `json:"queued_tracks"`
	PlayHistory    []TrackReference `json:"play_history"`
	Shuffle        bool             `json:"shuffle"`
	Repeat         string           `json:"repeat"`
}

type PlaybackStateV2 struct {
	Schema         string            `json:"schema"`
	Revision       int64             `json:"revision"`
	ActiveDeviceID *string           `json:"active_device_id"`
	State          string            `json:"state"`
	Track          *TrackReference   `json:"track"`
	Context        PlaybackContextV2 `json:"context"`
	Clock          PlaybackClockV2   `json:"clock"`
	Volume         float64           `json:"volume"`
	ServerTimeMS   int64             `json:"server_time_ms"`
}

type PlaybackCommandV2 struct {
	CommandID       string             `json:"command_id"`
	Kind            string             `json:"kind"`
	DeviceID        string             `json:"device_id"`
	TargetDeviceID  *string            `json:"target_device_id,omitempty"`
	Track           *TrackReference    `json:"track,omitempty"`
	Context         *PlaybackContextV2 `json:"context,omitempty"`
	PositionSeconds *float64           `json:"position_seconds,omitempty"`
	Volume          *float64           `json:"volume,omitempty"`
	Shuffle         *bool              `json:"shuffle,omitempty"`
	Repeat          *string            `json:"repeat,omitempty"`
}
