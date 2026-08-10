import type {
  AlbumSummary,
  ArtistSummary,
  Library,
  LibraryStats,
  Playlist,
  SortKey,
  Track,
  TrackReference
} from "./types";

export function libraryStats(library: Library | null): LibraryStats {
  const tracks = library?.tracks ?? [];
  const artists = new Set(tracks.map((track) => normalize(track.artist)));
  const albums = new Set(tracks.map((track) => `${normalize(track.artist)}|${normalize(track.album)}`));

  return {
    trackCount: tracks.length,
    playlistCount: library?.playlists.filter((playlist) => !playlist.is_liked).length ?? 0,
    likedCount: tracks.filter((track) => track.is_liked).length,
    artistCount: artists.size,
    albumCount: albums.size,
    durationSeconds: tracks.reduce((sum, track) => sum + (track.duration_seconds ?? 0), 0)
  };
}

export function playlistTracks(library: Library, playlist: Playlist | null): Track[] {
  if (!playlist) {
    return library.tracks;
  }

  const ids = new Set(playlist.track_ids);
  return library.tracks.filter((track) => ids.has(track.id));
}

export function likedTracks(library: Library): Track[] {
  return library.tracks.filter((track) => track.is_liked);
}

export function trackReference(track: Track): TrackReference {
  return {
    id: track.id,
    path: track.path,
    fingerprint: track.fingerprint
  };
}

export function findTrackByReference(
  library: Library,
  reference: TrackReference | null | undefined
): Track | null {
  if (!reference) {
    return null;
  }

  return (
    library.tracks.find((track) => track.path === reference.path) ??
    library.tracks.find((track) => track.id === reference.id) ??
    library.tracks.find((track) => track.fingerprint === reference.fingerprint) ??
    null
  );
}

export function tracksFromReferences(library: Library, references: TrackReference[]): Track[] {
  return references
    .map((reference) => findTrackByReference(library, reference))
    .filter((track): track is Track => Boolean(track));
}

// Haystacks are memoized per track object so typing in the search box does
// not re-lowercase the entire library on every keystroke.
const searchHaystacks = new WeakMap<Track, string>();

function searchHaystack(track: Track): string {
  let haystack = searchHaystacks.get(track);
  if (haystack === undefined) {
    haystack = [
      track.title,
      track.artist,
      track.album,
      track.album_artist,
      track.genre,
      track.file_name
    ]
      .filter(Boolean)
      .join(" ")
      .toLowerCase();
    searchHaystacks.set(track, haystack);
  }
  return haystack;
}

export function searchTracks(tracks: Track[], query: string): Track[] {
  const tokens = query
    .trim()
    .toLowerCase()
    .split(/\s+/)
    .filter(Boolean);

  if (tokens.length === 0) {
    return tracks;
  }

  return tracks.filter((track) => {
    const haystack = searchHaystack(track);
    return tokens.every((token) => haystack.includes(token));
  });
}

export function sortTracks(tracks: Track[], sortKey: SortKey): Track[] {
  const sorted = [...tracks];

  switch (sortKey) {
    case "title":
      return sorted.sort(compareBy((track) => track.title));
    case "artist":
      return sorted.sort(compareBy((track) => `${track.artist} ${track.album} ${track.track_number ?? 0}`));
    case "album":
      return sorted.sort(compareBy((track) => `${track.album} ${track.track_number ?? 0} ${track.title}`));
    case "added":
      return sorted.sort((a, b) => (b.added_at ?? 0) - (a.added_at ?? 0));
    case "duration":
      return sorted.sort((a, b) => (b.duration_seconds ?? 0) - (a.duration_seconds ?? 0));
    case "default":
    default:
      return sorted;
  }
}

export function createQueue(tracks: Track[], startTrackId: string, shuffle = false): Track[] {
  const startIndex = tracks.findIndex((track) => track.id === startTrackId);
  if (startIndex === -1) {
    return shuffle ? shuffleTracks(tracks) : [...tracks];
  }

  const startTrack = tracks[startIndex];
  const remaining = tracks.filter((track) => track.id !== startTrackId);
  return [startTrack, ...(shuffle ? shuffleTracks(remaining) : remaining)];
}

export function playbackQueue(
  currentTrack: Track | null,
  queuedTracks: Track[],
  sourceTracks: Track[],
  sourceIndex: number
): Track[] {
  const upcomingSource = sourceTracks.slice(Math.max(sourceIndex + 1, 0));
  return currentTrack ? [currentTrack, ...queuedTracks, ...upcomingSource] : [...queuedTracks, ...upcomingSource];
}

export function shuffleTracks(tracks: Track[], random = Math.random): Track[] {
  const shuffled = [...tracks];
  for (let index = shuffled.length - 1; index > 0; index -= 1) {
    const swapIndex = Math.floor(random() * (index + 1));
    [shuffled[index], shuffled[swapIndex]] = [shuffled[swapIndex], shuffled[index]];
  }
  return shuffled;
}

export function artistSummaries(library: Library): ArtistSummary[] {
  const artists = new Map<string, { tracks: Track[]; albums: Set<string> }>();

  for (const track of library.tracks) {
    const key = normalize(track.artist);
    const existing = artists.get(key) ?? { tracks: [], albums: new Set<string>() };
    existing.tracks.push(track);
    existing.albums.add(normalize(track.album));
    artists.set(key, existing);
  }

  return [...artists.entries()]
    .map(([, value]) => ({
      name: value.tracks[0]?.artist ?? "Unknown Artist",
      trackCount: value.tracks.length,
      albumCount: value.albums.size,
      durationSeconds: value.tracks.reduce((sum, track) => sum + (track.duration_seconds ?? 0), 0)
    }))
    .sort((a, b) => b.trackCount - a.trackCount || a.name.localeCompare(b.name));
}

export function albumSummaries(library: Library): AlbumSummary[] {
  const albums = new Map<string, Track[]>();

  for (const track of library.tracks) {
    const key = `${normalize(track.album_artist ?? track.artist)}|${normalize(track.album)}`;
    albums.set(key, [...(albums.get(key) ?? []), track]);
  }

  return [...albums.values()]
    .map((tracks) => ({
      name: tracks[0]?.album ?? "Unknown Album",
      artist: tracks[0]?.album_artist ?? tracks[0]?.artist ?? "Unknown Artist",
      trackCount: tracks.length,
      durationSeconds: tracks.reduce((sum, track) => sum + (track.duration_seconds ?? 0), 0),
      artwork_url: tracks.find((track) => track.artwork_url)?.artwork_url ?? null
    }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

export function formatDuration(seconds: number | null | undefined): string {
  if (!Number.isFinite(seconds ?? NaN) || !seconds || seconds < 0) {
    return "--:--";
  }

  const total = Math.floor(seconds);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const remainingSeconds = total % 60;

  if (hours > 0) {
    return `${hours}:${minutes.toString().padStart(2, "0")}:${remainingSeconds
      .toString()
      .padStart(2, "0")}`;
  }

  return `${minutes}:${remainingSeconds.toString().padStart(2, "0")}`;
}

export function formatLongDuration(seconds: number): string {
  if (seconds <= 0) {
    return "0 min";
  }

  const hours = Math.floor(seconds / 3600);
  const minutes = Math.round((seconds % 3600) / 60);

  if (hours === 0) {
    return `${minutes} min`;
  }

  if (minutes === 0) {
    return `${hours} hr`;
  }

  return `${hours} hr ${minutes} min`;
}

export function formatCount(count: number, singular: string, plural = `${singular}s`): string {
  return `${count.toLocaleString()} ${count === 1 ? singular : plural}`;
}

export function formatDate(timestamp: number | null): string {
  if (!timestamp) {
    return "Unknown";
  }

  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "numeric",
    year: "numeric"
  }).format(new Date(timestamp * 1000));
}

function compareBy(project: (track: Track) => string) {
  return (a: Track, b: Track) => project(a).localeCompare(project(b));
}

function normalize(value: string): string {
  return value.trim().replace(/\s+/g, " ").toLowerCase();
}

export type HomeRecentItem =
  | { kind: "album"; album: AlbumSummary; cover: Track }
  | { kind: "single"; track: Track };

/** What the Home grid shows: newest first, grouped into album tiles when we
 * have the album, single-track tiles otherwise, capped so "recently added"
 * never means "the whole library". Mirrors the iOS Home view. */
export function homeRecentItems(library: Library | null, limit = 12): HomeRecentItem[] {
  if (!library) {
    return [];
  }

  const albumsByKey = new Map<string, AlbumSummary>();
  for (const album of library.albums) {
    if (album.trackCount >= 2) {
      albumsByKey.set(albumItemKey(album.artist, album.name), album);
    }
  }

  const recent = [...library.tracks].sort((a, b) => (b.added_at ?? 0) - (a.added_at ?? 0));
  const items: HomeRecentItem[] = [];
  const seenAlbums = new Set<string>();

  for (const track of recent) {
    if (items.length >= limit) {
      break;
    }

    const key = albumItemKey(track.album_artist ?? track.artist, track.album);
    const album = albumsByKey.get(key);
    if (album) {
      if (!seenAlbums.has(key)) {
        seenAlbums.add(key);
        items.push({ kind: "album", album, cover: track });
      }
      continue;
    }

    items.push({ kind: "single", track });
  }

  return items;
}

function albumItemKey(artist: string, album: string): string {
  return `${artist.toLowerCase()}|${album.toLowerCase()}`;
}
