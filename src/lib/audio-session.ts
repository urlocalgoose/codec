type BrowserAudioSession = { type: string; readonly state?: string };

function browserAudioSession(): BrowserAudioSession | undefined {
  if (typeof navigator === "undefined") return undefined;
  return (navigator as Navigator & { audioSession?: BrowserAudioSession }).audioSession;
}

/** WebKit otherwise treats the visualizer's Web Audio output as ambient
 * sound, which can be silenced by screen lock or the ringer switch. Only the
 * local music player claims playback; a remote controller must stay inactive. */
export function createPlaybackAudioSession(readSession = browserAudioSession) {
  let ownedSession: BrowserAudioSession | undefined;
  let previousType: string | undefined;

  return {
    begin() {
      try {
        const session = readSession();
        if (!session) return;
        const prior = ownedSession === session ? previousType : session.type;
        if (session.type !== "playback") session.type = "playback";
        ownedSession = session;
        previousType = prior;
      } catch {
        // The API is optional. A missing/disabled implementation must not
        // prevent ordinary HTML audio from playing.
      }
    },
    release() {
      try {
        if (ownedSession?.type === "playback" && previousType !== undefined) {
          ownedSession.type = previousType;
        }
      } catch {
        // Playback is already stopped; teardown must remain safe.
      } finally {
        ownedSession = undefined;
        previousType = undefined;
      }
    },
    isInterrupted() {
      try { return readSession()?.state === "interrupted"; }
      catch { return false; }
    }
  };
}
