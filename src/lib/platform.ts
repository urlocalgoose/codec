export const REMOTE_ROOT_PATH = "loud://sync-server";

export function hasNativeBridge(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

export function isRemoteRoot(path: string): boolean {
  return path.startsWith("loud://");
}

/**
 * When served by the Go sync server, the page's own origin is the sync
 * server. Vite dev ports (1420/5173) are excluded so UI debugging does not
 * mistake the dev server for a sync backend.
 */
export function defaultSyncServerUrl(defaultDesktopUrl: string): string {
  if (hasNativeBridge()) {
    return defaultDesktopUrl;
  }

  try {
    const url = new URL(window.location.origin);
    if ((url.protocol === "http:" || url.protocol === "https:") && url.port !== "1420" && url.port !== "5173") {
      return url.origin;
    }
  } catch {
    return "";
  }

  return "";
}

export function createDeviceId(): string {
  const random =
    typeof crypto !== "undefined" && "randomUUID" in crypto
      ? crypto.randomUUID()
      : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  return `device-${random}`;
}

/** Platform + browser, so two browsers on the same machine don't register
 * as identically-named devices in the "Playing on" picker. */
export function defaultDeviceName(): string {
  if (hasNativeBridge()) {
    return "Codec Desktop";
  }

  const userAgent = navigator.userAgent;
  const platform = /iPad/i.test(userAgent)
    ? "iPad"
    : /iPhone/i.test(userAgent)
      ? "iPhone"
      : /Android/i.test(userAgent)
        ? "Android"
        : /Mac/i.test(userAgent)
          ? "Mac"
          : /Windows/i.test(userAgent)
            ? "Windows"
            : /Linux/i.test(userAgent)
              ? "Linux"
              : "Codec";

  const browser = /Edg\//.test(userAgent)
    ? "Edge"
    : /OPR\/|Opera/.test(userAgent)
      ? "Opera"
      : /Firefox\//.test(userAgent)
        ? "Firefox"
        : /Chrome\//.test(userAgent)
          ? "Chrome"
          : /Safari\//.test(userAgent)
            ? "Safari"
            : "Web";

  return `${platform} ${browser}`;
}

/** Default names from before browsers were distinguished; treat them as
 * unset so old sessions migrate to distinct names automatically. */
export const LEGACY_DEFAULT_DEVICE_NAMES = new Set([
  "Mac Web",
  "Codec Web",
  "iPad",
  "iPhone",
  "Android"
]);
