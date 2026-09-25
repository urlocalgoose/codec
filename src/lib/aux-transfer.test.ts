import { describe, expect, test } from 'bun:test';
import { auxPersonalOrigin, sanitizeAuxBridgeResult, validateAuxBridgeEnvelope } from './aux-transfer';
const request = { kind: 'contribute' as const, session_id: 'session', session_origin: 'https://host.example' };
const envelope = { version: 1, state: 'a'.repeat(64), return_origin: 'https://host.example', request };
describe('personal library bridge privacy', () => {
  test('requires explicit origin and strong return state', () => {
    expect(validateAuxBridgeEnvelope(envelope)).not.toBeNull();
    expect(validateAuxBridgeEnvelope({ ...envelope, state: 'predictable' })).toBeNull();
    expect(validateAuxBridgeEnvelope({ ...envelope, return_origin: 'https://other.example' })).toBeNull();
    expect(() => auxPersonalOrigin('https://owner:secret@personal.example')).toThrow();
    expect(() => auxPersonalOrigin('http://personal.example')).toThrow();
  });
  test('returns only the selected grant and fingerprint', () => {
    const grant = { source_origin: 'https://personal.example', token: `auxg_${'b'.repeat(48)}` };
    expect(sanitizeAuxBridgeResult({ type: 'contribution', fingerprint: 'song', grant,
      owner_token: 'never return', playlists: ['Private playlist'] }, request)).toEqual({ type: 'contribution', fingerprint: 'song', grant });
    expect(sanitizeAuxBridgeResult({ type: 'contribution', fingerprint: 'song', grant: { ...grant, token: 'owner-token' } }, request)).toBeNull();
  });
  test('does not accept save success for another song or copy unknown membership', () => {
    const save = { ...request, kind: 'save' as const, fingerprint: 'expected' };
    expect(sanitizeAuxBridgeResult({ type: 'saved', fingerprint: 'other', status: 'saved', playlist_added: true }, save)).toBeNull();
    expect(sanitizeAuxBridgeResult({ type: 'membership', fingerprint: 'expected', status: 'unknown' }, { ...save, kind: 'membership' })).toBeNull();
  });
});

import { openAuxLibraryBridge } from './aux-transfer';

function fakeBridgeWindow() {
  const original = Object.getOwnPropertyDescriptor(globalThis, 'window');
  const listeners = new Set<(event: MessageEvent) => void>();
  const messages: Array<{ value: unknown; target: string }> = [];
  let openedURL = '';
  const popup = { closed: false, close() { this.closed = true; },
    postMessage(value: unknown, target: string) { messages.push({ value, target }); } };
  const fake = {
    location: { origin: 'https://host.example' },
    open(url: string) { openedURL = url; return popup; },
    addEventListener(type: string, callback: (event: MessageEvent) => void) { if (type === 'message') listeners.add(callback); },
    removeEventListener(type: string, callback: (event: MessageEvent) => void) { if (type === 'message') listeners.delete(callback); },
  };
  Object.defineProperty(globalThis, 'window', { configurable: true, value: fake });
  return {
    popup, messages,
    envelope() { return JSON.parse(new URLSearchParams(new URL(openedURL).hash.slice(1)).get('aux-library')!); },
    send(data: unknown, origin = 'https://personal.example', source: unknown = popup) {
      for (const callback of listeners) callback({ data, origin, source } as MessageEvent);
    },
    restore() { if (original) Object.defineProperty(globalThis, 'window', original); else Reflect.deleteProperty(globalThis, 'window'); },
  };
}

test('staged save checks membership without a grant and accepts only matching popup, origin and state', async () => {
  const mock = fakeBridgeWindow();
  try {
    let grantCalls = 0;
    const promise = openAuxLibraryBridge('https://personal.example', { ...request, kind: 'save', fingerprint: 'song' }, {
      requestGrant: async () => { grantCalls++; throw new Error('copy disabled'); },
    });
    const { state } = mock.envelope();
    const result = { type: 'saved', fingerprint: 'song', status: 'saved', playlist_added: true } as const;
    const data = { type: 'codec.aux.library.result', state, result };
    let done = false; void promise.then(() => { done = true; });
    mock.send(data, 'https://attacker.example');
    mock.send(data, 'https://personal.example', {});
    mock.send({ ...data, state: 'incorrect-state' });
    mock.send({ ...data, result: { ...result, fingerprint: 'wrong-song' } });
    await Promise.resolve();
    expect(done).toBe(false);
    mock.send(data);
    expect(await promise).toEqual(result);
    expect(grantCalls).toBe(0); // Existing personal copy needs no source permission.
  } finally { mock.restore(); }
});

test('staged copy request returns only the selected scoped grant, never callback extra fields', async () => {
  const mock = fakeBridgeWindow();
  try {
    const calls: string[][] = [];
    const grant = { source_origin: 'https://source.example', token: `auxg_${'d'.repeat(48)}` };
    const promise = openAuxLibraryBridge('https://personal.example', { ...request, kind: 'save', fingerprint: 'song' }, {
      requestGrant: async (fingerprint, destination) => { calls.push([fingerprint, destination]);
        return { ...grant, owner_token: 'never-share', playlist_name: 'private' }; },
    });
    const { state } = mock.envelope();
    const ask = { type: 'codec.aux.library.grant-request', state, fingerprint: 'song' };
    mock.send({ ...ask, fingerprint: 'other' }); mock.send(ask, 'https://attacker.example');
    mock.send(ask); mock.send(ask); // Repeated taps reuse one in-flight authorization.
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(calls).toEqual([['song', 'https://personal.example']]);
    expect(mock.messages).toEqual([{ target: 'https://personal.example', value: {
      type: 'codec.aux.library.grant-result', state, grant,
    } }]);
    mock.send({ type: 'codec.aux.library.result', state, result: { type: 'cancelled' } });
    expect(await promise).toEqual({ type: 'cancelled' });
  } finally { mock.restore(); }
});

test('source denial and popup cancellation never report an absent or saved personal copy', async () => {
  const mock = fakeBridgeWindow();
  try {
    const controller = new AbortController();
    const promise = openAuxLibraryBridge('https://personal.example', { ...request, kind: 'save', fingerprint: 'song' }, {
      signal: controller.signal, requestGrant: async () => { throw new Error('sensitive backend diagnostic'); },
    });
    const caught = promise.catch((error) => error);
    const { state } = mock.envelope();
    mock.send({ type: 'codec.aux.library.grant-request', state, fingerprint: 'song' });
    await new Promise((resolve) => setTimeout(resolve, 0));
    const message = mock.messages[0].value as { error: string; grant?: unknown };
    expect(message.error).toContain('could not be authorized');
    expect(message.error).not.toContain('sensitive'); expect(message.grant).toBeUndefined();
    controller.abort();
    expect((await caught).name).toBe('AbortError'); expect(mock.popup.closed).toBe(true);
  } finally { mock.restore(); }
});
