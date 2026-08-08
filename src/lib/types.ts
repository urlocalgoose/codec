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
  duration_seconds: number | null;
  artwork_url: string | null;
  playlist_ids: string[];
  added_at: number | null;
  size_bytes: number;
  is_liked: boolean;
  fingerprint: string;
}

export interface TrackReference {
  id: string;
  path: string;
  fingerprint: string;
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
