/** Personal-library authorization stays in a popup hosted by the personal server.
 * Only an explicitly selected, scoped grant or a minimal operation result leaves
 * that origin. Owner credentials, library snapshots and playlists never do. */
export type AuxTransferReference = { source_origin: string; token: string };
export type AuxBridgeRequest = {
  kind: 'contribute' | 'save' | 'membership';
  session_id: string;
  session_origin: string;
  fingerprint?: string;
  grant?: AuxTransferReference;
};
export type AuxBridgeEnvelope = {
  version: 1;
  state: string;
  return_origin: string;
  request: AuxBridgeRequest;
};
export type AuxBridgeResult =
  | { type: 'contribution'; fingerprint: string; grant: AuxTransferReference }
  | { type: 'membership'; fingerprint: string; status: 'present' | 'repair' | 'absent' }
  | { type: 'saved'; fingerprint: string; status: 'saved' | 'playlist_failed'; playlist_added: boolean }
  | { type: 'cancelled' };

const messageType = 'codec.aux.library.result';
const fragmentKey = 'aux-library';
const maxEnvelopeBytes = 8192;

export function auxPersonalOrigin(value: string): string {
  const url = new URL(value);
  const local = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
  if ((url.protocol !== 'https:' && !(local && url.protocol === 'http:')) ||
      url.username || url.password || url.search || url.hash || url.pathname !== '/') {
    throw new Error('Enter the address of your personal Codec server.');
  }
  return url.origin;
}

export function validateAuxBridgeEnvelope(value: unknown): AuxBridgeEnvelope | null {
  if (!value || typeof value !== 'object') return null;
  const envelope = value as AuxBridgeEnvelope;
  if (envelope.version !== 1 || typeof envelope.state !== 'string' ||
      !/^[a-f0-9]{64}$/.test(envelope.state) || !envelope.request) return null;
  const request = envelope.request;
  try {
    if (auxPersonalOrigin(envelope.return_origin) !== envelope.return_origin ||
        auxPersonalOrigin(request.session_origin) !== envelope.return_origin) return null;
    if (!['contribute', 'save', 'membership'].includes(request.kind) ||
        typeof request.session_id !== 'string' || !request.session_id || request.session_id.length > 256) return null;
    if (request.kind !== 'contribute' && (typeof request.fingerprint !== 'string' ||
        !request.fingerprint || request.fingerprint.length > 256)) return null;
    if (request.grant && (auxPersonalOrigin(request.grant.source_origin) !== request.grant.source_origin ||
        !/^auxg_[a-f0-9]{48}$/.test(request.grant.token))) return null;
    // Rebuild the envelope to drop extra fields, including accidental credentials.
    return { version: 1, state: envelope.state, return_origin: envelope.return_origin,
      request: { kind: request.kind, session_id: request.session_id, session_origin: request.session_origin,
        ...(request.fingerprint ? { fingerprint: request.fingerprint } : {}),
        ...(request.grant ? { grant: { source_origin: request.grant.source_origin, token: request.grant.token } } : {}) } };
  } catch { return null; }
}

/** Call before normal invitation/connection parsing. Clearing the fragment keeps
 * request context out of copied URLs and reload history. Retain the result in
 * this popup's memory only. */
export function readAuxLibraryBridgeRequest(): AuxBridgeEnvelope | null {
  if (typeof window === 'undefined') return null;
  const raw = new URLSearchParams(window.location.hash.slice(1)).get(fragmentKey);
  if (!raw || raw.length > maxEnvelopeBytes) return null;
  window.history.replaceState(null, '', window.location.pathname + window.location.search);
  try { return validateAuxBridgeEnvelope(JSON.parse(raw)); } catch { return null; }
}

export function sanitizeAuxBridgeResult(value: unknown, request: AuxBridgeRequest): AuxBridgeResult | null {
  if (!value || typeof value !== 'object') return null;
  const result = value as AuxBridgeResult;
  if (result.type === 'cancelled') return { type: 'cancelled' };
  if (typeof result.fingerprint !== 'string' || !result.fingerprint || result.fingerprint.length > 256) return null;
  if (request.kind !== 'contribute' && result.fingerprint !== request.fingerprint) return null;
  if (result.type === 'contribution' && request.kind === 'contribute') {
    try {
      if (!result.grant || auxPersonalOrigin(result.grant.source_origin) !== result.grant.source_origin ||
          !/^auxg_[a-f0-9]{48}$/.test(result.grant.token)) return null;
      return { type: 'contribution', fingerprint: result.fingerprint,
        grant: { source_origin: result.grant.source_origin, token: result.grant.token } };
    } catch { return null; }
  }
  if (result.type === 'membership' && request.kind === 'membership' &&
      ['present', 'repair', 'absent'].includes(result.status)) {
    return { type: 'membership', fingerprint: result.fingerprint, status: result.status };
  }
  if (result.type === 'saved' && request.kind === 'save' &&
      ['saved', 'playlist_failed'].includes(result.status) && typeof result.playlist_added === 'boolean') {
    return { type: 'saved', fingerprint: result.fingerprint, status: result.status, playlist_added: result.playlist_added };
  }
  return null;
}

/** The bridge UI calls this only after its own-origin operation completes. */
export function completeAuxLibraryBridge(envelope: AuxBridgeEnvelope, result: AuxBridgeResult): void {
  const validated = validateAuxBridgeEnvelope(envelope);
  const safe = validated && sanitizeAuxBridgeResult(result, validated.request);
  if (!validated || !safe || !window.opener) throw new Error('The personal-library window is no longer connected.');
  if (safe.type === 'contribution' && safe.grant.source_origin !== window.location.origin) {
    throw new Error('A personal-library grant must come from this server.');
  }
  window.opener.postMessage({ type: messageType, state: validated.state, result: safe }, validated.return_origin);
}

/** Must run directly from the user's click so browser popup blocking is clear. */
export function openAuxLibraryBridge(personalServer: string, request: AuxBridgeRequest,
  options: { signal?: AbortSignal; timeoutMs?: number; requestGrant?: (fingerprint: string, destinationOrigin: string) => Promise<AuxTransferReference> } = {}): Promise<AuxBridgeResult> {
  const personalOrigin = auxPersonalOrigin(personalServer);
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const state = Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
  const envelope = validateAuxBridgeEnvelope({ version: 1, state, return_origin: window.location.origin, request });
  if (!envelope) return Promise.reject(new Error('Invalid personal-library request.'));
  if (options.signal?.aborted) return Promise.reject(new DOMException('Cancelled', 'AbortError'));
  const fragment = new URLSearchParams({ [fragmentKey]: JSON.stringify(envelope) });
  const popup = window.open(`${personalOrigin}/#${fragment}`, `codec-library-${state}`, 'popup,width=520,height=740');
  if (!popup) return Promise.reject(new Error('Allow this popup to open your personal library.'));
  return new Promise((resolve, reject) => {
    let settled = false;
    let grantPending: Promise<AuxTransferReference> | null = null;
    const clean = () => {
      window.removeEventListener('message', receive);
      options.signal?.removeEventListener('abort', abort);
      clearInterval(closed); clearTimeout(timeout);
    };
    const finish = (result?: AuxBridgeResult, error?: Error) => {
      if (settled) return;
      settled = true; clean(); popup.close();
      if (error) reject(error); else resolve(result!);
    };
    const abort = () => finish(undefined, new DOMException('Cancelled', 'AbortError'));
    const receive = (event: MessageEvent) => {
      if (event.source !== popup || event.origin !== personalOrigin || event.data?.state !== state) return;
      if (event.data.type === 'codec.aux.library.grant-request' && envelope.request.kind === 'save' &&
          event.data.fingerprint === envelope.request.fingerprint && options.requestGrant) {
        if (grantPending) return;
        grantPending = Promise.resolve().then(() => options.requestGrant!(envelope.request.fingerprint!, personalOrigin));
        void grantPending.then((grant) => {
          if (!grant || auxPersonalOrigin(grant.source_origin) !== grant.source_origin || !/^auxg_[a-f0-9]{48}$/.test(grant.token)) throw new Error('Invalid scoped copy grant.');
          if (!settled) popup.postMessage({ type: 'codec.aux.library.grant-result', state,
            grant: { source_origin: grant.source_origin, token: grant.token } }, personalOrigin);
        }).catch(() => {
          if (!settled) popup.postMessage({ type: 'codec.aux.library.grant-result', state,
            error: 'This song could not be authorized for saving. The source owner may have disabled copies or left Aux.' }, personalOrigin);
        }).finally(() => { grantPending = null; });
        return;
      }
      if (event.data.type !== messageType) return;
      const result = sanitizeAuxBridgeResult(event.data.result, envelope.request);
      if (!result || (result.type === 'contribution' && result.grant.source_origin !== personalOrigin)) return;
      finish(result);
    };
    const closed = setInterval(() => { if (popup.closed) finish({ type: 'cancelled' }); }, 250);
    const timeout = setTimeout(() => finish(undefined, new Error('The personal-library window timed out. Try again.')),
      Math.min(options.timeoutMs ?? 300_000, 300_000));
    window.addEventListener('message', receive);
    options.signal?.addEventListener('abort', abort, { once: true });
  });
}

/** Called inside the personal popup only when exact membership requires a copy.
 * The opener authorizes the selected Aux track, using its own participant token;
 * no personal credential or playlist choice is included in this handshake. */
export function requestAuxLibraryCopyGrant(envelope: AuxBridgeEnvelope, signal?: AbortSignal): Promise<AuxTransferReference> {
  const validated = validateAuxBridgeEnvelope(envelope);
  if (!validated || validated.request.kind !== 'save' || !window.opener) return Promise.reject(new Error('The Aux window is no longer connected.'));
  if (validated.request.grant) return Promise.resolve(validated.request.grant);
  if (signal?.aborted) return Promise.reject(new DOMException('Cancelled', 'AbortError'));
  return new Promise((resolve, reject) => {
    const cleanup = () => { window.removeEventListener('message', receive); signal?.removeEventListener('abort', abort); clearTimeout(timer); };
    const abort = () => { cleanup(); reject(new DOMException('Cancelled', 'AbortError')); };
    const receive = (event: MessageEvent) => {
      if (event.source !== window.opener || event.origin !== validated.return_origin || event.data?.state !== validated.state ||
          event.data.type !== 'codec.aux.library.grant-result') return;
      cleanup();
      const grant = event.data.grant;
      try {
        if (!grant || auxPersonalOrigin(grant.source_origin) !== grant.source_origin || !/^auxg_[a-f0-9]{48}$/.test(grant.token)) {
          throw new Error('This song could not be authorized for saving. The source owner may have disabled copies or left Aux.');
        }
        resolve({ source_origin: grant.source_origin, token: grant.token });
      } catch (reason) { reject(reason); }
    };
    const timer = setTimeout(() => { cleanup(); reject(new Error('Aux did not respond. Try again.')); }, 30_000);
    window.addEventListener('message', receive); signal?.addEventListener('abort', abort, { once: true });
    window.opener.postMessage({ type: 'codec.aux.library.grant-request', state: validated.state,
      fingerprint: validated.request.fingerprint }, validated.return_origin);
  });
}
