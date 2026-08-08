import { formatCount, formatLongDuration, likedTracks, playlistTracks, sortTracks } from "./library";
import type { Library, LibraryStats, Playlist, Track } from "./types";

export function isKnownView(library: Library, view: string): boolean {
  return (
    ["home", "all", "liked", "artists", "albums", "queue"].includes(view) ||
    library.playlists.some((playlist) => playlist.id === view)
  );
}

export function trackSourceForView(
  library: Library | null,
  view: string,
  playlist: Playlist | null,
  queue: Track[]
): Track[] {
  if (!library) {
    return [];
  }

  if (view === "all") {
    return library.tracks;
  }

  if (view === "liked") {
    return likedTracks(library);
  }

  if (view === "queue") {
    return queue;
  }

  if (view === "home") {
    return sortTracks(library.tracks, "added").slice(0, 32);
  }

  if (playlist) {
    return playlistTracks(library, playlist);
  }

  return library.tracks;
}

export function titleForView(view: string, playlist: Playlist | null): string {
  if (playlist) {
    return playlist.name;
  }

  switch (view) {
    case "all":
      return "All Songs";
    case "liked":
      return "Liked Songs";
    case "artists":
      return "Artists";
    case "albums":
      return "Albums";
    case "queue":
      return "Queue";
    case "home":
    default:
      return "Home";
  }
}

export function subtitleForView(library: Library | null, view: string, stats: LibraryStats): string {
  if (!library) {
    return "";
  }

  if (view === "home") {
    return `${formatCount(stats.trackCount, "track")} across ${formatCount(stats.playlistCount, "playlist")}`;
  }

  return "";
}

export function metaForTrackList(
  view: string,
  stats: LibraryStats,
  tracks: Track[],
  durationSeconds: number,
  manualQueue: Track[]
): string {
  if (view === "home") {
    return `${formatCount(stats.trackCount, "track")} · ${formatCount(
      stats.playlistCount,
      "playlist"
    )} · ${formatCount(stats.likedCount, "liked track")} · ${formatLongDuration(stats.durationSeconds)}`;
  }

  if (view === "queue") {
    return `${formatCount(tracks.length, "track")} · ${formatCount(manualQueue.length, "manual queue item")}`;
  }

  return `${formatCount(tracks.length, "track")} · ${formatLongDuration(durationSeconds)}`;
}
