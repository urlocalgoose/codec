// Presence keeps this device inside the server's two-minute online window.
// A healthy event stream carries changes immediately; occasional reads repair
// dropped events and remain compatible with servers without library events.
export const SYNC_PRESENCE_INTERVAL_MS = 30_000;
export const SYNC_RECONCILE_INTERVAL_MS = 5 * 60_000;
// Browser EventSource hides comment heartbeats, but our 30-second presence
// publishes generate named device events even while playback is idle.
export const SYNC_EVENT_STALE_MS = 60_000;

export function syncEventStreamExpired(lastActivity: number, now = Date.now()): boolean {
  return lastActivity === 0 || now - lastActivity >= SYNC_EVENT_STALE_MS;
}

export function shouldReconcileSync(streamOpen: boolean, lastSuccess: number, now = Date.now()): boolean {
  return !streamOpen || lastSuccess === 0 || now - lastSuccess >= SYNC_RECONCILE_INTERVAL_MS;
}
