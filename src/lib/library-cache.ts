/** Local library cache (IndexedDB): the web app hydrates instantly from the
 * last-seen library on load — like the iOS app — and refreshes from the
 * network in the background. Best-effort everywhere: any storage failure
 * just means a cold load. */

import type { Library } from "./types";

const DB_NAME = "codec-cache";
const STORE = "kv";
const LIBRARY_KEY = "library";

function openDatabase(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, 1);
    request.onupgradeneeded = () => {
      request.result.createObjectStore(STORE);
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

export async function readCachedLibrary(): Promise<Library | null> {
  try {
    const db = await openDatabase();
    return await new Promise((resolve) => {
      const request = db.transaction(STORE, "readonly").objectStore(STORE).get(LIBRARY_KEY);
      request.onsuccess = () => resolve((request.result as Library) ?? null);
      request.onerror = () => resolve(null);
    });
  } catch {
    return null;
  }
}

export async function writeCachedLibrary(library: Library): Promise<void> {
  try {
    const db = await openDatabase();
    const stripped = stripAccessTokens(library);
    await new Promise<void>((resolve) => {
      const request = db.transaction(STORE, "readwrite").objectStore(STORE).put(stripped, LIBRARY_KEY);
      request.onsuccess = () => resolve();
      request.onerror = () => resolve();
    });
  } catch {
    // Private mode / quota — the cache is optional.
  }
}

/** Stream tokens in media URLs are short-lived; cache the library without
 * them so hydration re-attaches fresh ones via normalizeLibrary. */
export function stripAccessTokens(library: Library): Library {
  return {
    ...library,
    tracks: library.tracks.map((track) => ({
      ...track,
      artwork_url: stripToken(track.artwork_url)
    })),
    playlists: library.playlists.map((playlist) => ({
      ...playlist,
      artwork_url: stripToken(playlist.artwork_url)
    }))
  };
}

function stripToken<T extends string | null | undefined>(url: T): T {
  if (!url) {
    return url;
  }
  try {
    const parsed = new URL(url);
    parsed.searchParams.delete("access_token");
    return parsed.toString() as T;
  } catch {
    return url;
  }
}
