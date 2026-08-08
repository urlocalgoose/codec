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

export function defaultDeviceName(): string {
  if (hasNativeBridge()) {
    return "Loud Desktop";
  }

  const userAgent = navigator.userAgent;
  if (/iPad/i.test(userAgent)) {
    return "iPad";
  }
  if (/iPhone/i.test(userAgent)) {
    return "iPhone";
  }
  if (/Android/i.test(userAgent)) {
    return "Android";
  }
  if (/Mac/i.test(userAgent)) {
    return "Mac Web";
  }
  return "Loud Web";
}
