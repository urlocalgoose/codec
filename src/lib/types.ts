export type RepeatMode = "off" | "all" | "one";
export type SortKey = "default" | "title" | "artist" | "album" | "added" | "duration";
export type ViewId = "home" | "all" | "liked" | "artists" | "albums" | "queue" | string;

export interface Library {
  root_path: string;
  scanned_at: number;
  stats: LibraryStats;
  artists: ArtistSummary[];
  albums: AlbumSummary[];
  playlists: Playlist[];
  tracks: Track[];
}

export interface Playlist {
  id: string;
  name: string;
  path: string;
  track_ids: string[];
  is_liked: boolean;
  /** Server-derived custom cover; absent when the playlist uses the default
   * first-track artwork. */
  artwork_url?: string | null;
}

export interface Track {
  id: string;
  path: string;
  file_name: string;
  title: string;
  artist: string;
  album: string;
  album_artist: string | null;
  genre: string | null;
  year: number | null;
  track_number: number | null;
  disc_number?: number | null;
  explicit?: boolean | null;
  identifiers?: Record<string, string>;
  source_urls?: Record<string, string>;
  duration_seconds: number | null;
  artwork_url: string | null;
  playlist_ids: string[];
  added_at: number | null;
  size_bytes: number;
  is_liked: boolean;
  fingerprint: string;
  /** Present only on foreign tracks queued from another Codec server: a
   * granted URL the audio streams from directly. */
  media_url?: string | null;
}

export interface TrackReference {
  id: string;
  path: string;
  fingerprint: string;
  title?: string;
  artist?: string;
  media_url?: string;
  artwork_url?: string;
}

export interface LibraryStats {
  trackCount: number;
  playlistCount: number;
  likedCount: number;
  artistCount: number;
  albumCount: number;
  durationSeconds: number;
}

export interface ArtistSummary {
  name: string;
  trackCount: number;
  albumCount: number;
  durationSeconds: number;
}

export interface AlbumSummary {
  name: string;
  artist: string;
  trackCount: number;
  durationSeconds: number;
  artwork_url: string | null;
}

export interface ImportReport {
  track_artwork_imported: number;
  playlist_artwork_imported: number;
  artwork_already_present: number;
  artwork_missing: number;
  artwork_failed: number;
  artwork_failures: ImportFailure[];
  track_fingerprints: string[];
  new_tracks: number;
  existing_tracks: number;
  skipped_tracks: number;
  liked_updates: number;
  playlist_updates: number;
  imported_paths: string[];
  failures: ImportFailure[];
}

export interface ImportFailure {
  file: string;
  reason: string;
}

/** Optional counters allow the UI to work with older desktop bridges. */
export interface SyncTransferReport {
  tracks_matched?: number;
  tracks_added?: number;
  tracks_uploaded?: number;
  tracks_downloaded?: number;
  tracks_skipped?: number;
  artwork_uploaded?: number;
  artwork_downloaded?: number;
  artwork_already_present?: number;
  artwork_missing?: number;
  artwork_failed?: number;
  track_artwork_uploaded?: number;
  playlist_artwork_uploaded?: number;
  track_artwork_downloaded?: number;
  playlist_artwork_downloaded?: number;
  track_artwork_already_present?: number;
  playlist_artwork_already_present?: number;
  track_artwork_missing?: number;
  playlist_artwork_missing?: number;
  track_artwork_failed?: number;
  playlist_artwork_failed?: number;
  playlists_added?: number;
  playlists_updated?: number;
  playlist_tracks_added?: number;
  playlist_updates?: number;
  liked_updates?: number;
  failures?: { track: string; reason: string }[];
  playlist_mappings?: { source_id: string; source_name: string; destination_id: string; destination_name: string; created: boolean }[];
}
