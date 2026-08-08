<script lang="ts">
  import { onMount, tick } from "svelte";
  import { invoke } from "@tauri-apps/api/core";
  import { listen } from "@tauri-apps/api/event";
  import { open } from "@tauri-apps/plugin-dialog";
  import { AlertCircle, LoaderCircle } from "lucide-svelte";
  import BrowseGrid from "$lib/components/BrowseGrid.svelte";
  import PlayerBar from "$lib/components/PlayerBar.svelte";
  import PlaylistModal from "$lib/components/PlaylistModal.svelte";
  import SetupScreen from "$lib/components/SetupScreen.svelte";
  import Sidebar from "$lib/components/Sidebar.svelte";
  import SyncServerModal from "$lib/components/SyncServerModal.svelte";
  import ThemeModal from "$lib/components/ThemeModal.svelte";
  import TopBar from "$lib/components/TopBar.svelte";
  import TrackList from "$lib/components/TrackList.svelte";
  import ViewHeader from "$lib/components/ViewHeader.svelte";
  import { mediaErrorMessage } from "$lib/audio-errors";
  import {
    createQueue,
    findTrackByReference,
    formatCount,
    playbackQueue,
    searchTracks,
    shuffleTracks,
    sortTracks,
    trackReference,
    tracksFromReferences
  } from "$lib/library";
  import {
    clampIndex,
    clampPlaybackTime,
    parsePlaybackSession,
    validPlaybackSession,
    type PersistedPlaybackSession
  } from "$lib/playback-session";
  import {
    createDeviceId,
    defaultDeviceName,
    defaultSyncServerUrl,
    hasNativeBridge,
    isRemoteRoot,
    REMOTE_ROOT_PATH
  } from "$lib/platform";
  import {
    fetchLatestPlaybackSession,
    fetchPlaybackStateV2,
    fetchPlaybackDevices,
    fetchRemoteLibrary,
    derivedPlaybackPosition,
    normalizeServerUrl,
    normalizeLibrary,
    playbackEventsV2Url,
    pushLibrarySnapshot,
    sendPlaybackCommandV2,
    trackAudioUrl,
    updatePlaybackDevice,
    validateSyncServer
  } from "$lib/sync";
  import type {
    PlaybackCommandKindV2,
    PlaybackContextV2,
    PlaybackDevice,
    PlaybackEventV2,
    PlaybackStateV2
  } from "$lib/sync";
  import { parseTheme, themes, type ThemeId, type ThemeOption } from "$lib/themes";
  import {
    isKnownView,
    metaForTrackList,
    subtitleForView,
    titleForView,
    trackSourceForView
  } from "$lib/views";
  import type {
    AlbumSummary,
    ArtistSummary,
    Library as MusicLibrary,
    LibraryStats,
    Playlist,
    RepeatMode,
    SortKey,
    Track
  } from "$lib/types";

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------

  const ROOT_STORAGE_KEY = "loud.musicRoot";
  const VOLUME_STORAGE_KEY = "loud.volume";
  const SHUFFLE_STORAGE_KEY = "loud.shuffle";
  const REPEAT_STORAGE_KEY = "loud.repeat";
  const THEME_STORAGE_KEY = "loud.theme";
  const SYNC_SERVER_STORAGE_KEY = "loud.syncServer";
  const SYNC_DEVICE_ID_STORAGE_KEY = "loud.deviceId";
  const SYNC_DEVICE_NAME_STORAGE_KEY = "loud.deviceName";
  const SYNC_SELECTED_DEVICE_STORAGE_KEY = "loud.selectedPlaybackDevice";
  const PLAYBACK_SESSION_STORAGE_KEY = "loud.playbackSession";
  const DEFAULT_SYNC_SERVER_URL = "http://127.0.0.1:8787";
  const PLAYBACK_SAVE_DELAY_MS = 750;
  const PLAYBACK_DEVICE_SAVE_DELAY_MS = 220;
  const PLAYBACK_DEVICE_POLL_MS = 10000;
  const DEFAULT_STATS: LibraryStats = {
    trackCount: 0,
    playlistCount: 0,
    likedCount: 0,
    artistCount: 0,
    albumCount: 0,
    durationSeconds: 0
  };

  type PlaybackSource = { url: string };
  type SyncTransferReport = {
    tracks_uploaded?: number;
    tracks_downloaded?: number;
    tracks_skipped?: number;
    artwork_uploaded?: number;
    playlist_updates?: number;
    liked_updates?: number;
    failures?: { track: string; reason: string }[];
  };

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  let library: MusicLibrary | null = null;
  let rootPath = "";
  let selectedView = "home";
  let searchQuery = "";
  let sortKey: SortKey = "default";
  let loading = false;
  let importing = false;
  let syncing = false;
  let renamingPlaylist = false;
  let errorMessage = "";
  let syncMessage = "";

  let currentTrack: Track | null = null;
  let queue: Track[] = [];
  let queuedTracks: Track[] = [];
  let playbackSource: Track[] = [];
  let playbackIndex = 0;
  let playHistory: Track[] = [];
  let isPlaying = false;
  let shuffle = false;
  let repeatMode: RepeatMode = "off";
  let volume = 0.86;
  let currentTime = 0;
  let audioDuration = 0;
  let theme: ThemeId = "oxide";
  let syncServerUrl = "";
  let syncServerDraft = "";
  let syncServerReady = false;
  let deviceId = "";
  let deviceName = "";
  let selectedPlaybackDeviceId = "";
  let playbackDevices: PlaybackDevice[] = [];
  let playbackStateV2: PlaybackStateV2 | null = null;
  let playbackClockOffsetMs = 0;

  let audioEl: HTMLAudioElement;
  let topBar: TopBar | undefined;
  let refreshTimer: number | null = null;
  let playbackSaveTimer: number | null = null;
  let playbackDeviceSaveTimer: number | null = null;
  let playbackDevicePollTimer: number | null = null;
  let playbackClockTimer: number | null = null;
  let playbackEventSource: EventSource | null = null;
  let playbackEventSourceUrl = "";
  let unlistenLibrary: (() => void) | null = null;
  let loadedSource = "";
  let editingPlaylistId = "";
  let playlistNameDraft = "";
  let playlistModalTrack: Track | null = null;
  let playlistModalSelectionIds: string[] = [];
  let themeModalOpen = false;
  let syncServerModalOpen = false;
  let playbackSessionRestored = false;
  let lastSavedPlaybackSession = "";
  let lastPublishedPlaybackDevice = "";
  let lastAppliedPlaybackRevision = 0;
  let pendingSeekTime: number | null = null;
  let applyingRemotePlayback = false;
  let savingPlaylistMemberships = false;

  // ---------------------------------------------------------------------------
  // Derived state
  // ---------------------------------------------------------------------------

  let selectedPlaylist: Playlist | null = null;
  let userPlaylists: Playlist[] = [];
  let visibleTracks: Track[] = [];
  let baseTracks: Track[] = [];
  let stats = DEFAULT_STATS;
  let artists: ArtistSummary[] = [];
  let albums: AlbumSummary[] = [];
  let viewTitle = "Home";
  let viewSubtitle = "";
  let listDurationSeconds = 0;
  let listMeta = "";
  let isEditingSelectedPlaylist = false;
  let activeTheme: ThemeOption = themes[0];
  let playbackDeviceOptions: PlaybackDevice[] = [];
  let activePlaybackDeviceId = "";
  let activePlaybackDeviceName = "";

  $: selectedPlaylist =
    library?.playlists.find((playlist) => playlist.id === selectedView) ?? null;
  $: userPlaylists = library?.playlists.filter((playlist) => !playlist.is_liked) ?? [];
  $: queue = playbackQueue(currentTrack, queuedTracks, playbackSource, playbackIndex);
  $: baseTracks = trackSourceForView(library, selectedView, selectedPlaylist, queue);
  $: visibleTracks = sortTracks(searchTracks(baseTracks, searchQuery), sortKey);
  $: stats = library?.stats ?? DEFAULT_STATS;
  $: artists = library?.artists ?? [];
  $: albums = library?.albums ?? [];
  $: viewTitle = titleForView(selectedView, selectedPlaylist);
  $: viewSubtitle = subtitleForView(library, selectedView, stats);
  $: listDurationSeconds = visibleTracks.reduce((sum, track) => sum + (track.duration_seconds ?? 0), 0);
  $: listMeta = metaForTrackList(selectedView, stats, visibleTracks, listDurationSeconds, queuedTracks);
  $: isEditingSelectedPlaylist = Boolean(
    selectedPlaylist && editingPlaylistId === selectedPlaylist.id
  );
  $: activeTheme = themes.find((option) => option.id === theme) ?? themes[0];
  $: playbackDeviceOptions = playbackDeviceChoices(playbackDevices, deviceId, deviceName);
  $: activePlaybackDeviceId =
    playbackStateV2?.active_device_id || selectedPlaybackDeviceId || deviceId;
  $: activePlaybackDeviceName =
    playbackDeviceOptions.find((device) => device.device_id === activePlaybackDeviceId)?.name ||
    deviceName ||
    "This device";
  $: if (audioEl) {
    audioEl.volume = volume;
  }
  $: if (playbackSessionRestored) {
    void currentTrack;
    void queuedTracks;
    void playbackSource;
    void playbackIndex;
    void playHistory;
    void audioDuration;
    void selectedView;
    schedulePlaybackSessionSave();
  }
  $: if (playbackSessionRestored && !usePlaybackSync()) {
    void currentTime;
    schedulePlaybackSessionSave();
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  onMount(() => {
    rootPath = localStorage.getItem(ROOT_STORAGE_KEY) ?? "";
    volume = Number(localStorage.getItem(VOLUME_STORAGE_KEY) ?? volume);
    shuffle = localStorage.getItem(SHUFFLE_STORAGE_KEY) === "true";
    repeatMode = (localStorage.getItem(REPEAT_STORAGE_KEY) as RepeatMode | null) ?? "off";
    theme = parseTheme(localStorage.getItem(THEME_STORAGE_KEY));
    syncServerUrl = normalizeServerUrl(
      localStorage.getItem(SYNC_SERVER_STORAGE_KEY) ?? defaultSyncServerUrl(DEFAULT_SYNC_SERVER_URL)
    );
    syncServerDraft = syncServerUrl;
    deviceId = localStorage.getItem(SYNC_DEVICE_ID_STORAGE_KEY) ?? createDeviceId();
    deviceName = localStorage.getItem(SYNC_DEVICE_NAME_STORAGE_KEY) ?? defaultDeviceName();
    selectedPlaybackDeviceId = localStorage.getItem(SYNC_SELECTED_DEVICE_STORAGE_KEY) ?? "";
    localStorage.setItem(SYNC_DEVICE_ID_STORAGE_KEY, deviceId);
    localStorage.setItem(SYNC_DEVICE_NAME_STORAGE_KEY, deviceName);

    if (rootPath && hasNativeBridge() && !isRemoteRoot(rootPath)) {
      void loadLibrary(rootPath, true);
    } else if (syncServerUrl && (!hasNativeBridge() || rootPath === REMOTE_ROOT_PATH)) {
      void loadRemoteLibrary(true);
    }

    if (syncServerUrl && rootPath !== REMOTE_ROOT_PATH) {
      void validatePlaybackSyncServer(true);
    }

    if (hasNativeBridge()) {
      void listen<{ root_path: string }>("library-changed", (event) => {
        if (!rootPath || event.payload.root_path !== rootPath) {
          return;
        }
        scheduleRefresh();
      }).then((unlisten) => {
        unlistenLibrary = unlisten;
      });
    }

    const keyHandler = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement | null;
      const isTyping =
        target?.tagName === "INPUT" ||
        target?.tagName === "TEXTAREA" ||
        target?.isContentEditable;

      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "f") {
        event.preventDefault();
        topBar?.focusSearch();
        return;
      }

      if (event.key === "Escape") {
        if (playlistModalTrack) {
          event.preventDefault();
          closePlaylistMembershipModal();
          return;
        }

        if (themeModalOpen) {
          event.preventDefault();
          closeThemeModal();
          return;
        }

        if (syncServerModalOpen) {
          event.preventDefault();
          closeSyncServerModal();
          return;
        }
      }

      if (isTyping) {
        return;
      }

      if (event.code === "Space") {
        event.preventDefault();
        void togglePlayback();
      }

      if (event.key === "ArrowRight") {
        seekBy(10);
      }

      if (event.key === "ArrowLeft") {
        seekBy(-10);
      }
    };

    document.addEventListener("keydown", keyHandler);
    const persistPlayback = () => savePlaybackSessionNow();
    const persistWhenHidden = () => {
      if (document.visibilityState === "hidden") {
        savePlaybackSessionNow();
      }
    };

    window.addEventListener("pagehide", persistPlayback);
    window.addEventListener("beforeunload", persistPlayback);
    document.addEventListener("visibilitychange", persistWhenHidden);

    return () => {
      savePlaybackSessionNow();
      document.removeEventListener("keydown", keyHandler);
      window.removeEventListener("pagehide", persistPlayback);
      window.removeEventListener("beforeunload", persistPlayback);
      document.removeEventListener("visibilitychange", persistWhenHidden);
      unlistenLibrary?.();
      if (refreshTimer) {
        window.clearTimeout(refreshTimer);
      }
      if (playbackSaveTimer) {
        window.clearTimeout(playbackSaveTimer);
      }
      if (playbackDeviceSaveTimer) {
        window.clearTimeout(playbackDeviceSaveTimer);
      }
      if (playbackDevicePollTimer) {
        window.clearInterval(playbackDevicePollTimer);
      }
      if (playbackClockTimer) {
        window.clearInterval(playbackClockTimer);
      }
      playbackEventSource?.close();
      if (hasNativeBridge() && !isRemoteRoot(rootPath)) {
        void invoke("stop_library_watch").catch(() => undefined);
      }
    };
  });

  // ---------------------------------------------------------------------------
  // Library loading
  // ---------------------------------------------------------------------------

  async function chooseFolder() {
    errorMessage = "";
    if (!hasNativeBridge()) {
      errorMessage = "Open Codec in the Tauri app to choose a music folder.";
      return;
    }

    const selected = await open({
      directory: true,
      multiple: false,
      title: "Choose music folder"
    });

    if (typeof selected === "string") {
      rootPath = selected;
      await loadLibrary(selected);
    }
  }

  async function chooseImportManifest() {
    errorMessage = "";
    if (!hasNativeBridge()) {
      errorMessage = "Open Codec in the Tauri app to import a playlist manifest.";
      return;
    }

    if (!rootPath) {
      errorMessage = "Choose a music folder before importing a playlist manifest.";
      return;
    }

    const selected = await open({
      directory: false,
      multiple: false,
      title: "Import Codec playlist manifest",
      filters: [{ name: "Codec import manifest", extensions: ["json"] }]
    });

    if (typeof selected !== "string") {
      return;
    }

    importing = true;
    try {
      await invoke("import_library_manifest", {
        root_path: rootPath,
        manifest_path: selected
      });
      await loadLibrary(rootPath, true);
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      importing = false;
    }
  }

  async function loadLibrary(path: string, quiet = false) {
    loading = !quiet;
    errorMessage = "";
    if (!hasNativeBridge()) {
      loading = false;
      errorMessage = "Open Codec in the Tauri app to load your music folder.";
      return;
    }

    try {
      const nextLibrary = await invoke<MusicLibrary>("scan_library", { root_path: path });
      rootPath = nextLibrary.root_path;
      localStorage.setItem(ROOT_STORAGE_KEY, rootPath);
      syncLibrary(nextLibrary);
      await invoke("start_library_watch", { root_path: rootPath }).catch(() => undefined);
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      loading = false;
    }
  }

  async function loadRemoteLibrary(quiet = false) {
    syncMessage = "";
    loading = !quiet;
    errorMessage = "";

    const serverUrl = saveSyncServerUrl();
    if (!serverUrl) {
      loading = false;
      errorMessage = "Enter a sync server URL first.";
      return;
    }

    try {
      await validateSyncServer(serverUrl);
      const nextLibrary = await fetchRemoteLibrary(serverUrl);
      syncServerReady = true;
      rootPath = nextLibrary.root_path || REMOTE_ROOT_PATH;
      localStorage.setItem(ROOT_STORAGE_KEY, rootPath);
      syncLibrary(nextLibrary);
      await restoreRemotePlaybackSession(nextLibrary);
      startPlaybackDevicePolling();
      syncMessage = `Connected · ${formatCount(nextLibrary.tracks.length, "track")}`;
    } catch (error) {
      syncServerReady = false;
      stopPlaybackDevicePolling();
      errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      loading = false;
    }
  }

  function syncLibrary(nextLibrary: MusicLibrary) {
    const previousCurrent = currentTrack;
    nextLibrary = normalizeLibrary(nextLibrary);
    library = nextLibrary;

    if (!playbackSessionRestored) {
      playbackSessionRestored = true;
      if (restorePlaybackSession(nextLibrary)) {
        schedulePlaybackSessionSave();
        schedulePlaybackDeviceUpdate(true);
        return;
      }
    }

    if (previousCurrent) {
      currentTrack =
        nextLibrary.tracks.find((track) => track.path === previousCurrent.path) ??
        nextLibrary.tracks.find((track) => track.id === previousCurrent.id) ??
        nextLibrary.tracks.find((track) => track.fingerprint === previousCurrent.fingerprint) ??
        null;
    }

    queuedTracks = reconcileTrackList(nextLibrary, queuedTracks);
    playbackSource = reconcileTrackList(nextLibrary, playbackSource);
    playHistory = reconcileTrackList(nextLibrary, playHistory);

    if (currentTrack) {
      const nextIndex = playbackSource.findIndex((track) => track.id === currentTrack?.id);
      if (nextIndex >= 0) {
        playbackIndex = nextIndex;
      } else {
        playbackIndex = Math.min(playbackIndex, Math.max(playbackSource.length - 1, 0));
      }
    } else {
      playbackIndex = 0;
    }

    schedulePlaybackSessionSave();
    schedulePlaybackDeviceUpdate(true);
  }

  function reconcileTrackList(activeLibrary: MusicLibrary, tracks: Track[]): Track[] {
    return tracks
      .map((queuedTrack) => findTrack(activeLibrary, queuedTrack))
      .filter((track): track is Track => Boolean(track));
  }

  function findTrack(activeLibrary: MusicLibrary, target: Track): Track | null {
    return findTrackByReference(activeLibrary, trackReference(target));
  }

  function refreshActiveLibrary() {
    if (!rootPath) {
      return;
    }

    if (isRemoteRoot(rootPath)) {
      void loadRemoteLibrary(true);
    } else {
      void loadLibrary(rootPath, true);
    }
  }

  function scheduleRefresh() {
    if (refreshTimer) {
      window.clearTimeout(refreshTimer);
    }

    refreshTimer = window.setTimeout(() => {
      if (rootPath) {
        if (isRemoteRoot(rootPath)) {
          void loadRemoteLibrary(true);
        } else {
          void loadLibrary(rootPath, true);
        }
      }
    }, 650);
  }

  // ---------------------------------------------------------------------------
  // Playback session persistence (local restore across restarts)
  // ---------------------------------------------------------------------------

  function restorePlaybackSession(activeLibrary: MusicLibrary): boolean {
    const session = parsePlaybackSession(
      localStorage.getItem(PLAYBACK_SESSION_STORAGE_KEY),
      activeLibrary.root_path
    );
    if (!session) {
      return false;
    }

    return applyPlaybackSession(activeLibrary, session);
  }

  function applyPlaybackSession(
    activeLibrary: MusicLibrary,
    session: PersistedPlaybackSession
  ): boolean {
    const restoredCurrent = findTrackByReference(activeLibrary, session.current_track);
    currentTrack = restoredCurrent;
    queuedTracks = tracksFromReferences(activeLibrary, session.queued_tracks);
    playbackSource = tracksFromReferences(activeLibrary, session.playback_source);
    playHistory = tracksFromReferences(activeLibrary, session.play_history);
    playbackIndex = clampIndex(session.playback_index, playbackSource.length);
    currentTime = clampPlaybackTime(session.current_time, restoredCurrent);
    audioDuration = session.audio_duration || restoredCurrent?.duration_seconds || 0;
    isPlaying = false;
    loadedSource = "";
    pendingSeekTime = currentTime;

    if (session.selected_view && isKnownView(activeLibrary, session.selected_view)) {
      selectedView = session.selected_view;
    }

    if (currentTrack && playbackSource.length === 0) {
      playbackSource = [currentTrack];
      playbackIndex = 0;
    }

    return Boolean(
      currentTrack ||
        queuedTracks.length > 0 ||
        playbackSource.length > 0 ||
        playHistory.length > 0 ||
        session.selected_view
    );
  }

  async function restoreRemotePlaybackSession(activeLibrary: MusicLibrary) {
    if (!syncServerUrl) {
      return;
    }

    try {
      const remote = await fetchLatestPlaybackSession<PersistedPlaybackSession>(syncServerUrl);
      if (!remote || !validPlaybackSession(remote.session)) {
        return;
      }

      const localSession = parsePlaybackSession(
        localStorage.getItem(PLAYBACK_SESSION_STORAGE_KEY),
        activeLibrary.root_path
      );
      if (localSession && localSession.saved_at >= remote.session.saved_at) {
        return;
      }

      applyPlaybackSession(activeLibrary, {
        ...remote.session,
        root_path: activeLibrary.root_path
      });
      savePlaybackSessionNow();
    } catch {
      // Playback session sync is opportunistic; library sync should not fail because of it.
    }
  }

  function schedulePlaybackSessionSave() {
    if (!playbackSessionRestored || !rootPath) {
      return;
    }

    if (playbackSaveTimer) {
      return;
    }

    playbackSaveTimer = window.setTimeout(() => {
      playbackSaveTimer = null;
      savePlaybackSessionNow();
    }, PLAYBACK_SAVE_DELAY_MS);
  }

  function savePlaybackSessionNow() {
    if (playbackSaveTimer) {
      window.clearTimeout(playbackSaveTimer);
      playbackSaveTimer = null;
    }

    if (!playbackSessionRestored || !rootPath) {
      return;
    }

    const session: PersistedPlaybackSession = {
      schema: "loud.playback.v1",
      root_path: rootPath,
      saved_at: Date.now(),
      selected_view: selectedView,
      current_track: currentTrack ? trackReference(currentTrack) : null,
      queued_tracks: queuedTracks.map(trackReference),
      playback_source: playbackSource.map(trackReference),
      playback_index: playbackIndex,
      play_history: playHistory.map(trackReference),
      current_time: currentPlaybackTimeForSave(),
      audio_duration: audioDuration || currentTrack?.duration_seconds || 0
    };
    const serialized = JSON.stringify(session);
    if (serialized !== lastSavedPlaybackSession) {
      localStorage.setItem(PLAYBACK_SESSION_STORAGE_KEY, serialized);
      lastSavedPlaybackSession = serialized;
    }
  }

  function currentPlaybackTimeForSave(): number {
    const mediaTime = audioEl?.currentTime;
    if (Number.isFinite(mediaTime) && mediaTime > 0) {
      return mediaTime;
    }

    return Number.isFinite(currentTime) && currentTime > 0 ? currentTime : 0;
  }

  // ---------------------------------------------------------------------------
  // Sync server connection
  // ---------------------------------------------------------------------------

  function saveSyncServerUrl(): string {
    const previousUrl = syncServerUrl;
    const nextUrl = normalizeServerUrl(syncServerDraft);
    syncServerDraft = nextUrl;
    syncServerUrl = nextUrl;
    if (previousUrl !== nextUrl) {
      syncServerReady = false;
      stopPlaybackDevicePolling();
    }
    if (nextUrl) {
      localStorage.setItem(SYNC_SERVER_STORAGE_KEY, nextUrl);
    } else {
      localStorage.removeItem(SYNC_SERVER_STORAGE_KEY);
      stopPlaybackDevicePolling();
    }
    return nextUrl;
  }

  async function syncToServer() {
    const serverUrl = saveSyncServerUrl();
    if (!serverUrl || !library) {
      errorMessage = "Choose a library and enter a sync server URL first.";
      return;
    }

    syncing = true;
    syncMessage = "";
    errorMessage = "";
    try {
      await validateSyncServer(serverUrl);
      if (hasNativeBridge() && rootPath && !isRemoteRoot(rootPath)) {
        const report = await invoke<SyncTransferReport>("sync_library_to_server", {
          root_path: rootPath,
          server_url: serverUrl,
          device_id: deviceId
        });
        syncMessage = syncReportText("Uploaded", report);
      } else {
        const report = await pushLibrarySnapshot(serverUrl, deviceId, library);
        syncMessage = `Uploaded metadata · ${formatCount(report.tracks_upserted, "track")}`;
      }
      syncServerReady = true;
      startPlaybackDevicePolling();
    } catch (error) {
      syncServerReady = false;
      stopPlaybackDevicePolling();
      errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      syncing = false;
    }
  }

  async function syncFromServer() {
    const serverUrl = saveSyncServerUrl();
    if (!serverUrl) {
      errorMessage = "Enter a sync server URL first.";
      return;
    }

    syncing = true;
    syncMessage = "";
    errorMessage = "";
    try {
      await validateSyncServer(serverUrl);
      if (hasNativeBridge() && rootPath && !isRemoteRoot(rootPath)) {
        const report = await invoke<SyncTransferReport>("sync_library_from_server", {
          root_path: rootPath,
          server_url: serverUrl
        });
        syncMessage = syncReportText("Pulled", report);
        await loadLibrary(rootPath, true);
        syncServerReady = true;
        startPlaybackDevicePolling();
      } else {
        await loadRemoteLibrary(true);
      }
    } catch (error) {
      syncServerReady = false;
      stopPlaybackDevicePolling();
      errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      syncing = false;
    }
  }

  function syncReportText(action: string, report: SyncTransferReport): string {
    const moved = (report.tracks_uploaded ?? 0) + (report.tracks_downloaded ?? 0);
    const skipped = report.tracks_skipped ?? 0;
    const failures = report.failures?.length ?? 0;
    return `${action} · ${formatCount(moved, "track")} · ${formatCount(
      skipped,
      "already local",
      "already local"
    )}${
      failures ? ` · ${formatCount(failures, "failure")}` : ""
    }`;
  }

  async function validatePlaybackSyncServer(quiet = false) {
    if (!syncServerUrl) {
      return;
    }

    const serverUrl = syncServerUrl;
    try {
      await validateSyncServer(serverUrl);
      if (serverUrl !== syncServerUrl) {
        return;
      }
      syncServerReady = true;
      startPlaybackDevicePolling();
    } catch (error) {
      if (serverUrl !== syncServerUrl) {
        return;
      }
      syncServerReady = false;
      stopPlaybackDevicePolling();
      if (!quiet) {
        errorMessage = error instanceof Error ? error.message : String(error);
      }
    }
  }

  function openSyncServerModal() {
    syncServerDraft = syncServerUrl;
    syncServerModalOpen = true;
  }

  function closeSyncServerModal() {
    syncServerModalOpen = false;
  }

  async function applySyncServerChange() {
    const serverUrl = saveSyncServerUrl();
    if (!serverUrl) {
      errorMessage = "Enter a sync server URL first.";
      return;
    }

    closeSyncServerModal();
    await loadRemoteLibrary(false);
  }

  function disconnectSyncServer() {
    syncServerDraft = "";
    syncServerUrl = "";
    syncServerReady = false;
    localStorage.removeItem(SYNC_SERVER_STORAGE_KEY);
    localStorage.removeItem(SYNC_SELECTED_DEVICE_STORAGE_KEY);
    selectedPlaybackDeviceId = "";
    playbackStateV2 = null;
    stopPlaybackClock();
    stopPlaybackDevicePolling();
    closeSyncServerModal();
    syncMessage = "";
    errorMessage = "";

    if (isRemoteRoot(rootPath)) {
      rootPath = "";
      library = null;
      currentTrack = null;
      queuedTracks = [];
      playbackSource = [];
      playbackIndex = 0;
      playHistory = [];
      currentTime = 0;
      audioDuration = 0;
      loadedSource = "";
      playbackSessionRestored = false;
      localStorage.removeItem(ROOT_STORAGE_KEY);
    }
  }

  // ---------------------------------------------------------------------------
  // Playback devices + shared playback state (v2)
  // ---------------------------------------------------------------------------

  function usePlaybackSync(): boolean {
    return Boolean(syncServerUrl && syncServerReady && deviceId);
  }

  function startPlaybackDevicePolling() {
    if (!syncServerUrl || !syncServerReady || playbackDevicePollTimer) {
      if (syncServerUrl && syncServerReady) {
        startPlaybackEvents();
      }
      return;
    }

    void publishPlaybackDeviceState(true);
    void refreshPlaybackDevices();
    startPlaybackEvents();
    playbackDevicePollTimer = window.setInterval(() => {
      void publishPlaybackDeviceState();
      void refreshPlaybackDevices();
    }, PLAYBACK_DEVICE_POLL_MS);
  }

  function stopPlaybackDevicePolling() {
    if (playbackDevicePollTimer) {
      window.clearInterval(playbackDevicePollTimer);
      playbackDevicePollTimer = null;
    }
    if (playbackDeviceSaveTimer) {
      window.clearTimeout(playbackDeviceSaveTimer);
      playbackDeviceSaveTimer = null;
    }
    playbackDevices = [];
    playbackStateV2 = null;
    stopPlaybackClock();
    lastPublishedPlaybackDevice = "";
    playbackEventSource?.close();
    playbackEventSource = null;
    playbackEventSourceUrl = "";
  }

  function startPlaybackEvents() {
    if (!syncServerUrl || !syncServerReady || typeof EventSource === "undefined") {
      return;
    }

    const nextUrl = playbackEventsV2Url(syncServerUrl);
    if (playbackEventSource && playbackEventSourceUrl === nextUrl) {
      return;
    }

    playbackEventSource?.close();
    playbackEventSourceUrl = nextUrl;
    playbackEventSource = new EventSource(nextUrl);
    playbackEventSource.addEventListener("devices", handlePlaybackEvent);
    playbackEventSource.addEventListener("device", handlePlaybackEvent);
    playbackEventSource.addEventListener("playback_state", handlePlaybackEvent);
    playbackEventSource.onerror = () => {
      void refreshPlaybackDevices();
    };
  }

  function handlePlaybackEvent(event: MessageEvent<string>) {
    try {
      const payload = JSON.parse(event.data) as PlaybackEventV2;
      if (payload.devices) {
        playbackDevices = payload.devices;
      }
      if (payload.device) {
        playbackDevices = mergePlaybackDevice(playbackDevices, payload.device);
      }
      if (payload.playback_state) {
        void applyPlaybackStateV2(payload.playback_state);
      }
    } catch {
      // Ignore malformed stream events; the fallback poll will repair state.
    }
  }

  function mergePlaybackDevice(devices: PlaybackDevice[], nextDevice: PlaybackDevice): PlaybackDevice[] {
    const byId = new Map(devices.map((device) => [device.device_id, device]));
    byId.set(nextDevice.device_id, nextDevice);
    return [...byId.values()].sort((a, b) => b.updated_at - a.updated_at);
  }

  function schedulePlaybackDeviceUpdate(force = false) {
    if (!syncServerUrl || !syncServerReady || !deviceId) {
      return;
    }

    if (playbackDeviceSaveTimer && !force) {
      return;
    }

    if (playbackDeviceSaveTimer) {
      window.clearTimeout(playbackDeviceSaveTimer);
      playbackDeviceSaveTimer = null;
    }

    playbackDeviceSaveTimer = window.setTimeout(() => {
      playbackDeviceSaveTimer = null;
      void publishPlaybackDeviceState(force);
    }, force ? 0 : PLAYBACK_DEVICE_SAVE_DELAY_MS);
  }

  async function publishPlaybackDeviceState(force = false) {
    if (!syncServerUrl || !syncServerReady || !deviceId) {
      return;
    }

    const state = playbackDeviceState();
    const comparisonState = {
      ...state,
      updated_at: 0,
      position_seconds: 0
    };
    const serialized = JSON.stringify(comparisonState);
    if (!force && serialized === lastPublishedPlaybackDevice) {
      return;
    }

    try {
      await updatePlaybackDevice(syncServerUrl, state);
      lastPublishedPlaybackDevice = serialized;
    } catch {
      // Device presence is best-effort; a dead sync server should not break playback.
    }
  }

  async function refreshPlaybackDevices() {
    if (!syncServerUrl || !syncServerReady) {
      return;
    }

    const serverUrl = syncServerUrl;
    try {
      const [devices, state] = await Promise.all([
        fetchPlaybackDevices(serverUrl),
        fetchPlaybackStateV2(serverUrl)
      ]);
      if (serverUrl !== syncServerUrl) {
        return;
      }

      playbackDevices = devices;
      if (state) {
        await applyPlaybackStateV2(state);
      } else {
        playbackStateV2 = null;
        stopPlaybackClock();
      }
    } catch {
      // Polling should stay quiet; the connect/sync actions surface user-facing failures.
    }
  }

  function playbackDeviceState(): PlaybackDevice {
    return {
      device_id: deviceId,
      name: deviceName || "This device",
      track_id: currentTrack?.id ?? null,
      track_fingerprint: currentTrack?.fingerprint ?? null,
      track_title: currentTrack?.title ?? null,
      is_playing: playbackStateV2?.active_device_id === deviceId && playbackStateV2.state === "playing",
      position_seconds: 0,
      volume,
      updated_at: Date.now()
    };
  }

  function playbackDeviceChoices(
    devices: PlaybackDevice[],
    currentDeviceId: string,
    currentDeviceName: string
  ): PlaybackDevice[] {
    if (!currentDeviceId) {
      return devices;
    }

    const byId = new Map<string, PlaybackDevice>();
    for (const device of devices) {
      if (device.device_id) {
        byId.set(device.device_id, device);
      }
    }
    if (selectedPlaybackDeviceId && !byId.has(selectedPlaybackDeviceId)) {
      byId.set(selectedPlaybackDeviceId, {
        ...playbackDeviceState(),
        device_id: selectedPlaybackDeviceId,
        name: "Selected device"
      });
    }

    const current =
      byId.get(currentDeviceId) ??
      ({
        ...playbackDeviceState(),
        name: currentDeviceName || "This device"
      } satisfies PlaybackDevice);
    byId.delete(currentDeviceId);

    return [current, ...[...byId.values()].sort((a, b) => b.updated_at - a.updated_at)];
  }

  async function transferPlaybackToDevice(targetDeviceId: string) {
    if (!usePlaybackSync() || !targetDeviceId) {
      return;
    }

    selectedPlaybackDeviceId = targetDeviceId;
    localStorage.setItem(SYNC_SELECTED_DEVICE_STORAGE_KEY, targetDeviceId);
    try {
      const state = await sendPlaybackCommand("transfer", {
        target_device_id: targetDeviceId,
        position_seconds: currentSyncedPlaybackPosition()
      });
      await applyPlaybackStateV2(state, true);
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  function handlePlaybackDeviceChange(event: Event) {
    const target = event.currentTarget as HTMLSelectElement;
    void transferPlaybackToDevice(target.value);
  }

  async function activateThisPlaybackDevice() {
    if (!usePlaybackSync() || !deviceId || applyingRemotePlayback) {
      return;
    }

    try {
      const state = await sendPlaybackCommand("transfer", {
        target_device_id: deviceId,
        position_seconds: currentSyncedPlaybackPosition()
      });
      await applyPlaybackStateV2(state, true);
      schedulePlaybackDeviceUpdate(true);
    } catch {
      // Local controls should remain responsive if device sync drops.
    }
  }

  async function applyPlaybackStateV2(nextState: PlaybackStateV2, force = false) {
    if (!force && playbackStateV2 && nextState.revision <= playbackStateV2.revision) {
      return;
    }

    playbackClockOffsetMs = nextState.server_time_ms - Date.now();
    playbackStateV2 = nextState;
    lastAppliedPlaybackRevision = nextState.revision;

    if (nextState.active_device_id) {
      selectedPlaybackDeviceId = nextState.active_device_id;
      localStorage.setItem(SYNC_SELECTED_DEVICE_STORAGE_KEY, selectedPlaybackDeviceId);
    } else if (!selectedPlaybackDeviceId) {
      selectedPlaybackDeviceId = deviceId;
      localStorage.setItem(SYNC_SELECTED_DEVICE_STORAGE_KEY, selectedPlaybackDeviceId);
    }

    applyPlaybackContextV2(nextState);
    currentTime = currentSyncedPlaybackPosition();
    isPlaying = nextState.state === "playing";
    volume = Math.max(0, Math.min(nextState.volume, 1));
    localStorage.setItem(VOLUME_STORAGE_KEY, String(volume));
    updatePlaybackClock();

    const targetTrack = library && nextState.track ? findTrackByReference(library, nextState.track) : null;
    if (targetTrack) {
      currentTrack = targetTrack;
      audioDuration = targetTrack.duration_seconds || audioDuration;
    }

    applyingRemotePlayback = true;
    try {
      if (nextState.active_device_id === deviceId && targetTrack) {
        await syncLocalAudioToPlaybackState(nextState, targetTrack);
      } else {
        audioEl?.pause();
      }
    } finally {
      applyingRemotePlayback = false;
    }

    schedulePlaybackDeviceUpdate(true);
  }

  function selectedPlaybackTargetDeviceId(): string {
    return selectedPlaybackDeviceId || playbackStateV2?.active_device_id || deviceId;
  }

  async function sendPlaybackCommand(
    kind: PlaybackCommandKindV2,
    overrides: Partial<Parameters<typeof sendPlaybackCommandV2>[1]> = {}
  ): Promise<PlaybackStateV2> {
    if (!syncServerUrl || !deviceId) {
      throw new Error("Playback sync is not connected.");
    }

    return sendPlaybackCommandV2(syncServerUrl, {
      command_id: createPlaybackCommandId(kind),
      kind,
      device_id: deviceId,
      target_device_id: selectedPlaybackTargetDeviceId(),
      volume,
      ...overrides
    });
  }

  function createPlaybackCommandId(kind: string): string {
    const random =
      typeof crypto !== "undefined" && "randomUUID" in crypto
        ? crypto.randomUUID()
        : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    return `${deviceId || "device"}-${kind}-${random}`;
  }

  function playbackContextSnapshot(
    sourceTracks = playbackSource,
    sourceIndex = playbackIndex,
    queued = queuedTracks,
    history = playHistory,
    shuffled = shuffle,
    repeat = repeatMode
  ): PlaybackContextV2 {
    return {
      playback_source: sourceTracks.map(trackReference),
      playback_index: Math.max(0, Math.min(sourceIndex, Math.max(sourceTracks.length - 1, 0))),
      queued_tracks: queued.map(trackReference),
      play_history: history.map(trackReference),
      shuffle: shuffled,
      repeat
    };
  }

  function applyPlaybackContextV2(state: PlaybackStateV2) {
    if (!library) {
      return;
    }

    queuedTracks = tracksFromReferences(library, state.context.queued_tracks);
    playbackSource = tracksFromReferences(library, state.context.playback_source);
    playHistory = tracksFromReferences(library, state.context.play_history);
    playbackIndex = Math.max(0, Math.min(state.context.playback_index, Math.max(playbackSource.length - 1, 0)));
    shuffle = state.context.shuffle;
    repeatMode = state.context.repeat;
    localStorage.setItem(SHUFFLE_STORAGE_KEY, String(shuffle));
    localStorage.setItem(REPEAT_STORAGE_KEY, repeatMode);
  }

  async function syncLocalAudioToPlaybackState(state: PlaybackStateV2, track: Track) {
    if (!audioEl) {
      return;
    }

    const position = clampPlaybackTime(currentSyncedPlaybackPosition(), track);
    const source = await playbackUrlForTrack(track);
    if (loadedSource !== source) {
      loadAudioSource(source, position);
      await waitForAudioMetadata();
    } else if (Math.abs((audioEl.currentTime || 0) - position) > 0.75) {
      audioEl.currentTime = position;
      currentTime = position;
    }

    if (state.state === "playing") {
      await audioEl.play();
      isPlaying = true;
    } else {
      audioEl.pause();
      isPlaying = false;
    }
  }

  function currentSyncedPlaybackPosition(): number {
    if (!playbackStateV2) {
      return currentPlaybackTimeForSave();
    }
    return derivedPlaybackPosition(playbackStateV2, Date.now(), playbackClockOffsetMs);
  }

  function updatePlaybackClock() {
    if (!playbackStateV2) {
      stopPlaybackClock();
      return;
    }

    currentTime = clampPlaybackTime(currentSyncedPlaybackPosition(), currentTrack);
    if (playbackStateV2.state === "playing" && !playbackClockTimer) {
      playbackClockTimer = window.setInterval(updatePlaybackClock, 250);
    } else if (playbackStateV2.state !== "playing") {
      stopPlaybackClock();
    }
  }

  function stopPlaybackClock() {
    if (playbackClockTimer) {
      window.clearInterval(playbackClockTimer);
      playbackClockTimer = null;
    }
  }

  // ---------------------------------------------------------------------------
  // Playback engine (local audio element + shared-state commands)
  // ---------------------------------------------------------------------------

  async function playTrack(track: Track, sourceTracks = visibleTracks, shuffled = shuffle) {
    if (usePlaybackSync()) {
      const nextSource = createQueue(sourceTracks, track.id, shuffled);
      const nextTrack = nextSource[0] ?? track;
      try {
        const state = await sendPlaybackCommand("play", {
          track: trackReference(nextTrack),
          context: playbackContextSnapshot(nextSource, 0, [], [], shuffled, repeatMode),
          position_seconds: 0
        });
        await applyPlaybackStateV2(state, true);
      } catch (error) {
        errorMessage = error instanceof Error ? error.message : String(error);
      }
      return;
    }

    playbackSource = createQueue(sourceTracks, track.id, shuffled);
    playbackIndex = 0;
    playHistory = [];
    currentTrack = playbackSource[0] ?? track;
    currentTime = 0;
    await startPlayback();
  }

  async function playTrackRow(track: Track, index: number) {
    if (currentTrack?.id === track.id) {
      await togglePlayback();
      return;
    }

    if (selectedView === "queue") {
      await playQueueTrack(index);
      return;
    }

    await playTrack(track, visibleTracks);
  }

  async function playTrackSet(sourceTracks: Track[], shuffled = false) {
    const nextSource = shuffled ? shuffleTracks(sourceTracks) : [...sourceTracks];
    const firstTrack = nextSource[0];

    if (!firstTrack) {
      return;
    }

    if (usePlaybackSync()) {
      try {
        const state = await sendPlaybackCommand("play", {
          track: trackReference(firstTrack),
          context: playbackContextSnapshot(nextSource, 0, [], [], shuffled, repeatMode),
          position_seconds: 0
        });
        await applyPlaybackStateV2(state, true);
      } catch (error) {
        errorMessage = error instanceof Error ? error.message : String(error);
      }
      return;
    }

    playbackSource = nextSource;
    playbackIndex = 0;
    playHistory = [];
    currentTrack = firstTrack;
    currentTime = 0;
    await startPlayback();
  }

  function clearQueuedTracks() {
    queuedTracks = [];
  }

  function removeQueuedTrackAt(queueIndex: number) {
    const manualIndex = queueIndex - 1;
    if (manualIndex < 0 || manualIndex >= queuedTracks.length) {
      return;
    }

    queuedTracks = queuedTracks.filter((_, index) => index !== manualIndex);
  }

  async function togglePlayback() {
    if (usePlaybackSync()) {
      const targetDeviceId = selectedPlaybackTargetDeviceId();
      const targetIsPlaying =
        playbackStateV2?.state === "playing" && playbackStateV2.active_device_id === targetDeviceId;

      try {
        if (targetIsPlaying) {
          const state = await sendPlaybackCommand("pause", {
            target_device_id: targetDeviceId,
            position_seconds: currentSyncedPlaybackPosition()
          });
          await applyPlaybackStateV2(state, true);
          return;
        }

        let track = currentTrack;
        let context = playbackContextSnapshot();
        if (!track) {
          track = visibleTracks[0] ?? library?.tracks[0] ?? null;
          if (track) {
            const source = createQueue(visibleTracks.length ? visibleTracks : library?.tracks ?? [], track.id, shuffle);
            context = playbackContextSnapshot(source, 0, [], [], shuffle, repeatMode);
          }
        }
        if (!track) {
          return;
        }

        const state = await sendPlaybackCommand("play", {
          target_device_id: targetDeviceId,
          track: trackReference(track),
          context,
          position_seconds: currentTrack?.id === track.id ? currentSyncedPlaybackPosition() : 0
        });
        await applyPlaybackStateV2(state, true);
      } catch (error) {
        errorMessage = error instanceof Error ? error.message : String(error);
      }
      return;
    }

    if (!currentTrack) {
      if (queuedTracks.length > 0) {
        currentTrack = queuedTracks[0];
        queuedTracks = queuedTracks.slice(1);
        currentTime = 0;
        await startPlayback();
        return;
      }

      const firstTrack = visibleTracks[0] ?? library?.tracks[0];
      if (firstTrack) {
        await playTrack(firstTrack, visibleTracks.length ? visibleTracks : library?.tracks ?? []);
      }
      return;
    }

    if (isPlaying) {
      audioEl?.pause();
      isPlaying = false;
      return;
    }

    await startPlayback();
  }

  async function startPlayback() {
    await tick();

    if (!audioEl || !currentTrack || !rootPath) {
      isPlaying = false;
      errorMessage = "Local playback needs the Tauri app and a selected music folder.";
      return;
    }

    try {
      const source = await playbackUrlForTrack(currentTrack);
      if (loadedSource !== source) {
        loadAudioSource(source, currentTime);
        await waitForAudioMetadata();
      } else if (Math.abs((audioEl.currentTime || 0) - currentTime) > 1.5) {
        audioEl.currentTime = currentTime;
      }

      applyPendingSeek();
      await audioEl.play();
      errorMessage = "";
    } catch (error) {
      isPlaying = false;
      errorMessage = mediaErrorMessage(error, audioEl?.error ?? null);
    }
  }

  async function playbackUrlForTrack(track: Track): Promise<string> {
    if (isRemoteRoot(rootPath) || !hasNativeBridge()) {
      if (!syncServerUrl) {
        throw new Error("Remote playback needs a sync server URL.");
      }
      return trackAudioUrl(syncServerUrl, track.fingerprint);
    }

    const source = await invoke<PlaybackSource>("prepare_track_playback", {
      root_path: rootPath,
      track_path: track.path
    });
    return source.url;
  }

  function loadAudioSource(source: string, seekTime = 0) {
    audioEl.src = source;
    pendingSeekTime = seekTime > 0 ? seekTime : null;
    audioEl.load();
    loadedSource = source;
  }

  function waitForAudioMetadata(): Promise<void> {
    if (!audioEl || audioEl.readyState >= 1) {
      applyPendingSeek();
      return Promise.resolve();
    }

    return new Promise((resolve) => {
      let timeout = 0;
      const done = () => {
        window.clearTimeout(timeout);
        audioEl?.removeEventListener("loadedmetadata", done);
        audioEl?.removeEventListener("error", done);
        syncDuration();
        resolve();
      };

      timeout = window.setTimeout(done, 1500);
      audioEl.addEventListener("loadedmetadata", done, { once: true });
      audioEl.addEventListener("error", done, { once: true });
    });
  }

  function applyPendingSeek() {
    if (!audioEl || pendingSeekTime === null) {
      return;
    }

    const duration = Number.isFinite(audioEl.duration) && audioEl.duration > 0 ? audioEl.duration : null;
    const nextTime = duration ? Math.min(pendingSeekTime, Math.max(duration - 1, 0)) : pendingSeekTime;
    audioEl.currentTime = Math.max(0, nextTime);
    currentTime = audioEl.currentTime;
    pendingSeekTime = null;
  }

  async function playQueueTrack(index: number) {
    if (!queue[index]) {
      return;
    }

    if (usePlaybackSync()) {
      if (index === 0) {
        await togglePlayback();
        return;
      }

      const nextTrack = queue[index];
      let nextQueuedTracks = queuedTracks;
      let nextPlaybackSource = playbackSource;
      let nextPlaybackIndex = playbackIndex;
      const nextHistory = currentTrack ? [...playHistory, currentTrack] : playHistory;

      if (index <= queuedTracks.length) {
        const queuedIndex = index - 1;
        nextQueuedTracks = queuedTracks.slice(queuedIndex + 1);
      } else {
        nextPlaybackIndex = Math.max(
          0,
          Math.min(playbackIndex + index - queuedTracks.length, Math.max(playbackSource.length - 1, 0))
        );
        nextQueuedTracks = [];
      }

      if (!nextPlaybackSource.some((track) => track.id === nextTrack.id)) {
        nextPlaybackSource = [nextTrack, ...nextPlaybackSource];
        nextPlaybackIndex = 0;
      }

      try {
        const state = await sendPlaybackCommand("play", {
          track: trackReference(nextTrack),
          context: playbackContextSnapshot(
            nextPlaybackSource,
            nextPlaybackIndex,
            nextQueuedTracks,
            nextHistory,
            shuffle,
            repeatMode
          ),
          position_seconds: 0
        });
        await applyPlaybackStateV2(state, true);
      } catch (error) {
        errorMessage = error instanceof Error ? error.message : String(error);
      }
      return;
    }

    if (index === 0) {
      await togglePlayback();
      return;
    }

    if (currentTrack) {
      playHistory = [...playHistory, currentTrack];
    }

    if (index <= queuedTracks.length) {
      const queuedIndex = index - 1;
      currentTrack = queuedTracks[queuedIndex];
      queuedTracks = queuedTracks.slice(queuedIndex + 1);
    } else {
      const nextSourceIndex = playbackIndex + index - queuedTracks.length;
      playbackIndex = Math.min(nextSourceIndex, Math.max(playbackSource.length - 1, 0));
      currentTrack = playbackSource[playbackIndex] ?? queue[index];
      queuedTracks = [];
    }

    currentTime = 0;
    await startPlayback();
  }

  async function nextTrack() {
    if (usePlaybackSync()) {
      try {
        const state = await sendPlaybackCommand("next", {
          position_seconds: currentSyncedPlaybackPosition()
        });
        await applyPlaybackStateV2(state, true);
      } catch (error) {
        errorMessage = error instanceof Error ? error.message : String(error);
      }
      return;
    }

    if (!currentTrack && queue.length > 0) {
      currentTrack = queue[0];
      currentTime = 0;
      await startPlayback();
      return;
    }

    if (!currentTrack) {
      return;
    }

    if (queuedTracks.length > 0) {
      playHistory = [...playHistory, currentTrack];
      currentTrack = queuedTracks[0];
      queuedTracks = queuedTracks.slice(1);
      currentTime = 0;
      await startPlayback();
      return;
    }

    if (playbackIndex < playbackSource.length - 1) {
      playHistory = [...playHistory, currentTrack];
      playbackIndex += 1;
      currentTrack = playbackSource[playbackIndex];
      currentTime = 0;
      await startPlayback();
      return;
    }

    if (repeatMode === "all" && playbackSource.length > 0) {
      playHistory = [...playHistory, currentTrack];
      playbackIndex = 0;
      currentTrack = playbackSource[0];
      currentTime = 0;
      await startPlayback();
      return;
    }

    isPlaying = false;
  }

  async function previousTrack() {
    if (usePlaybackSync()) {
      try {
        const state = await sendPlaybackCommand("previous", {
          position_seconds: currentSyncedPlaybackPosition()
        });
        await applyPlaybackStateV2(state, true);
      } catch (error) {
        errorMessage = error instanceof Error ? error.message : String(error);
      }
      return;
    }

    if (audioEl && audioEl.currentTime > 4) {
      audioEl.currentTime = 0;
      currentTime = 0;
      return;
    }

    const previous = playHistory.at(-1);
    if (previous) {
      playHistory = playHistory.slice(0, -1);
      currentTrack = previous;

      const sourceIndex = playbackSource.findIndex((track) => track.id === previous.id);
      if (sourceIndex >= 0) {
        playbackIndex = sourceIndex;
      }

      currentTime = 0;
      await startPlayback();
    }
  }

  async function handleEnded() {
    if (usePlaybackSync()) {
      if (playbackStateV2?.active_device_id === deviceId) {
        try {
          const state =
            repeatMode === "one"
              ? await sendPlaybackCommand("seek", {
                  target_device_id: deviceId,
                  position_seconds: 0
                })
              : await sendPlaybackCommand("next", {
                  target_device_id: deviceId,
                  position_seconds: currentSyncedPlaybackPosition()
                });
          await applyPlaybackStateV2(state, true);
        } catch (error) {
          errorMessage = error instanceof Error ? error.message : String(error);
        }
      }
      return;
    }

    if (repeatMode === "one") {
      audioEl.currentTime = 0;
      await startPlayback();
      return;
    }

    await nextTrack();
  }

  async function toggleShuffle() {
    const nextShuffle = !shuffle;

    if (usePlaybackSync()) {
      let nextSource = playbackSource;
      let nextIndex = playbackIndex;
      if (currentTrack) {
        nextSource = nextShuffle
          ? [currentTrack, ...shuffleTracks(playbackSource.filter((track) => track.id !== currentTrack?.id))]
          : createQueue(visibleTracks.length ? visibleTracks : library?.tracks ?? [], currentTrack.id, false);
        nextIndex = 0;
      }

      try {
        const state = await sendPlaybackCommand("set_shuffle", {
          shuffle: nextShuffle,
          context: playbackContextSnapshot(nextSource, nextIndex, queuedTracks, playHistory, nextShuffle, repeatMode),
          position_seconds: currentSyncedPlaybackPosition()
        });
        await applyPlaybackStateV2(state, true);
      } catch (error) {
        errorMessage = error instanceof Error ? error.message : String(error);
      }
      return;
    }

    shuffle = nextShuffle;
    localStorage.setItem(SHUFFLE_STORAGE_KEY, String(shuffle));

    if (!currentTrack) {
      return;
    }

    if (shuffle) {
      playbackSource = [currentTrack, ...shuffleTracks(playbackSource.filter((track) => track.id !== currentTrack?.id))];
      playbackIndex = 0;
      return;
    }

    const source = visibleTracks.length ? visibleTracks : library?.tracks ?? [];
    playbackSource = createQueue(source, currentTrack.id, false);
    playbackIndex = 0;
  }

  async function toggleRepeat() {
    const nextRepeat: RepeatMode = repeatMode === "off" ? "all" : repeatMode === "all" ? "one" : "off";

    if (usePlaybackSync()) {
      try {
        const state = await sendPlaybackCommand("set_repeat", {
          repeat: nextRepeat,
          context: playbackContextSnapshot(playbackSource, playbackIndex, queuedTracks, playHistory, shuffle, nextRepeat),
          position_seconds: currentSyncedPlaybackPosition()
        });
        await applyPlaybackStateV2(state, true);
      } catch (error) {
        errorMessage = error instanceof Error ? error.message : String(error);
      }
      return;
    }

    repeatMode = nextRepeat;
    localStorage.setItem(REPEAT_STORAGE_KEY, repeatMode);
  }

  async function setProgress(event: Event) {
    const value = Number((event.currentTarget as HTMLInputElement).value);
    currentTime = value;

    if (usePlaybackSync()) {
      try {
        const state = await sendPlaybackCommand("seek", {
          position_seconds: value
        });
        await applyPlaybackStateV2(state, true);
      } catch (error) {
        errorMessage = error instanceof Error ? error.message : String(error);
      }
      return;
    }

    if (audioEl) {
      audioEl.currentTime = value;
    }
    schedulePlaybackDeviceUpdate(true);
  }

  async function updateVolume(event: Event) {
    volume = Number((event.currentTarget as HTMLInputElement).value);
    localStorage.setItem(VOLUME_STORAGE_KEY, String(volume));

    if (usePlaybackSync()) {
      try {
        const state = await sendPlaybackCommand("volume", {
          volume,
          position_seconds: currentSyncedPlaybackPosition()
        });
        await applyPlaybackStateV2(state, true);
      } catch (error) {
        errorMessage = error instanceof Error ? error.message : String(error);
      }
      return;
    }

    schedulePlaybackDeviceUpdate(true);
  }

  function seekBy(seconds: number) {
    if (usePlaybackSync()) {
      const duration = audioDuration || currentTrack?.duration_seconds || 0;
      const nextTime = Math.max(0, Math.min(duration || 0, currentSyncedPlaybackPosition() + seconds));
      currentTime = nextTime;
      void sendPlaybackCommand("seek", {
        position_seconds: nextTime
      })
        .then((state) => applyPlaybackStateV2(state, true))
        .catch((error) => {
          errorMessage = error instanceof Error ? error.message : String(error);
        });
      return;
    }

    if (!audioEl) {
      return;
    }

    const nextTime = Math.max(0, Math.min(audioEl.duration || 0, audioEl.currentTime + seconds));
    audioEl.currentTime = nextTime;
    currentTime = nextTime;
  }

  // ---------------------------------------------------------------------------
  // Audio element events
  // ---------------------------------------------------------------------------

  function syncTime() {
    if (usePlaybackSync()) {
      return;
    }
    currentTime = audioEl?.currentTime ?? 0;
    schedulePlaybackDeviceUpdate();
  }

  function syncDuration() {
    audioDuration = audioEl?.duration || currentTrack?.duration_seconds || 0;
    applyPendingSeek();
  }

  function handleAudioError() {
    if (!currentTrack) {
      return;
    }

    isPlaying = false;
    errorMessage = mediaErrorMessage(
      `Could not load "${currentTrack.title}".`,
      audioEl?.error ?? null
    );
  }

  function handleAudioPause() {
    if (applyingRemotePlayback) {
      return;
    }
    if (usePlaybackSync()) {
      isPlaying = playbackStateV2?.state === "playing";
      return;
    }

    isPlaying = false;
    schedulePlaybackDeviceUpdate(true);

    void activateThisPlaybackDevice();
  }

  function handleAudioPlay() {
    if (applyingRemotePlayback) {
      return;
    }
    if (usePlaybackSync()) {
      isPlaying = playbackStateV2?.state === "playing";
      return;
    }

    isPlaying = true;
    schedulePlaybackDeviceUpdate(true);

    void activateThisPlaybackDevice();
  }

  // ---------------------------------------------------------------------------
  // Views, themes, and playlist editing
  // ---------------------------------------------------------------------------

  function selectView(view: string) {
    cancelPlaylistRename();
    selectedView = view;
    searchQuery = "";
    sortKey = "default";
  }

  function openFromBrowseGrid(query: string) {
    selectedView = "all";
    searchQuery = query;
  }

  function setTableSort(nextSort: SortKey) {
    sortKey = sortKey === nextSort ? "default" : nextSort;
  }

  function setTheme(nextTheme: ThemeId) {
    theme = nextTheme;
    localStorage.setItem(THEME_STORAGE_KEY, nextTheme);
  }

  function openThemeModal() {
    themeModalOpen = true;
  }

  function closeThemeModal() {
    themeModalOpen = false;
  }

  function startPlaylistRename(playlist: Playlist) {
    editingPlaylistId = playlist.id;
    playlistNameDraft = playlist.name;
  }

  function cancelPlaylistRename() {
    editingPlaylistId = "";
    playlistNameDraft = "";
  }

  async function commitPlaylistRename() {
    if (!rootPath || !selectedPlaylist || renamingPlaylist) {
      return;
    }

    const name = playlistNameDraft.trim();
    if (!name) {
      errorMessage = "Playlist title cannot be empty.";
      return;
    }

    if (name === selectedPlaylist.name) {
      cancelPlaylistRename();
      return;
    }

    renamingPlaylist = true;
    errorMessage = "";
    try {
      await invoke("rename_playlist", {
        root_path: rootPath,
        playlist_id: selectedPlaylist.id,
        name
      });
      cancelPlaylistRename();
      await loadLibrary(rootPath, true);
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      renamingPlaylist = false;
    }
  }

  function playlistSelectionForTrack(track: Track) {
    const ids = new Set(track.playlist_ids);
    if (track.is_liked) {
      const likedPlaylist = library?.playlists.find((playlist) => playlist.is_liked);
      if (likedPlaylist) {
        ids.add(likedPlaylist.id);
      }
    }

    return [...ids];
  }

  function openPlaylistMembershipModal(track: Track) {
    playlistModalTrack = track;
    playlistModalSelectionIds = playlistSelectionForTrack(track);
  }

  function closePlaylistMembershipModal() {
    playlistModalTrack = null;
    playlistModalSelectionIds = [];
    savingPlaylistMemberships = false;
  }

  function applyLocalPlaylistMemberships(track: Track, selectedPlaylistIds: string[]) {
    if (!library) {
      return;
    }

    const activeLibrary = library;
    const selectedIds = new Set(selectedPlaylistIds);
    const targetFingerprint = track.fingerprint;
    const likedPlaylist = activeLibrary.playlists.find((playlist) => playlist.is_liked);
    const nextTrackIds = new Set<string>();

    const nextTracks = activeLibrary.tracks.map((candidate) => {
      if (candidate.fingerprint !== targetFingerprint) {
        return candidate;
      }

      nextTrackIds.add(candidate.id);
      return {
        ...candidate,
        is_liked: likedPlaylist ? selectedIds.has(likedPlaylist.id) : false,
        playlist_ids: activeLibrary.playlists
          .filter((playlist) => selectedIds.has(playlist.id))
          .map((playlist) => playlist.id)
      };
    });

    const nextPlaylists = activeLibrary.playlists.map((playlist) => {
      const trackIds = playlist.track_ids.filter((trackId) => !nextTrackIds.has(trackId));

      if (selectedIds.has(playlist.id)) {
        for (const trackId of nextTrackIds) {
          if (!trackIds.includes(trackId)) {
            trackIds.push(trackId);
          }
        }
      }

      return { ...playlist, track_ids: trackIds };
    });

    syncLibrary({
      ...activeLibrary,
      playlists: nextPlaylists,
      tracks: nextTracks,
      stats: {
        ...activeLibrary.stats,
        likedCount: nextTracks.filter((candidate) => candidate.is_liked).length
      }
    });
  }

  async function savePlaylistMemberships() {
    const track = playlistModalTrack;
    const selectedPlaylistIds = [...playlistModalSelectionIds];
    const previousLibrary = library;

    if (!rootPath || !track || savingPlaylistMemberships) {
      return;
    }

    savingPlaylistMemberships = true;
    errorMessage = "";
    applyLocalPlaylistMemberships(track, selectedPlaylistIds);
    closePlaylistMembershipModal();

    try {
      await invoke("set_track_playlist_memberships", {
        root_path: rootPath,
        track_path: track.path,
        playlist_ids: selectedPlaylistIds
      });
      void loadLibrary(rootPath, true);
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
      if (previousLibrary) {
        syncLibrary(previousLibrary);
      }
      savingPlaylistMemberships = false;
    }
  }
</script>

<svelte:head>
  <title>Codec</title>
</svelte:head>

{#if !library && !loading}
  <SetupScreen
    {theme}
    isNative={hasNativeBridge()}
    {loading}
    {errorMessage}
    bind:syncServerDraft
    onChooseFolder={() => void chooseFolder()}
    onConnect={() => void loadRemoteLibrary(false)}
  />
{:else}
  <main class="app-shell" data-theme={theme}>
    <Sidebar
      {selectedView}
      {userPlaylists}
      activeThemeName={activeTheme.name}
      {syncing}
      canUpload={Boolean(library)}
      {syncMessage}
      bind:syncServerDraft
      onSelectView={selectView}
      onOpenThemeModal={openThemeModal}
      onSyncToServer={() => void syncToServer()}
      onSyncFromServer={() => void syncFromServer()}
    />

    <section class="content">
      <TopBar
        bind:this={topBar}
        bind:searchQuery
        {importing}
        importDisabled={isRemoteRoot(rootPath)}
        onOpenSyncServerModal={openSyncServerModal}
        onImportManifest={() => void chooseImportManifest()}
        onRefresh={refreshActiveLibrary}
      />

      {#if loading}
        <section class="loading-state">
          <LoaderCircle class="spin-icon" size={34} />
          <p>Reading music folder</p>
        </section>
      {:else if library}
        <ViewHeader
          {viewTitle}
          {viewSubtitle}
          {selectedPlaylist}
          isEditing={isEditingSelectedPlaylist}
          renaming={renamingPlaylist}
          bind:playlistNameDraft
          onStartRename={startPlaylistRename}
          onCommitRename={() => void commitPlaylistRename()}
          onCancelRename={cancelPlaylistRename}
        />

        {#if errorMessage}
          <section class="error-strip"><AlertCircle size={17} /> {errorMessage}</section>
        {/if}

        {#if selectedView === "artists"}
          <BrowseGrid kind="artists" {artists} onOpen={openFromBrowseGrid} />
        {:else if selectedView === "albums"}
          <BrowseGrid kind="albums" {albums} onOpen={openFromBrowseGrid} />
        {:else}
          <TrackList
            {viewTitle}
            isQueueView={selectedView === "queue"}
            {listMeta}
            {visibleTracks}
            queuedTracksCount={queuedTracks.length}
            currentTrackId={currentTrack?.id ?? null}
            {isPlaying}
            {sortKey}
            onSetSort={setTableSort}
            onPlayAll={() => void playTrackSet(visibleTracks)}
            onShuffleAll={() => void playTrackSet(visibleTracks, true)}
            onClearQueue={clearQueuedTracks}
            onPlayRow={(track, index) => void playTrackRow(track, index)}
            onRemoveQueued={removeQueuedTrackAt}
            onEditPlaylists={openPlaylistMembershipModal}
          />
        {/if}
      {/if}
    </section>

    <PlayerBar
      {currentTrack}
      {isPlaying}
      {shuffle}
      {repeatMode}
      {currentTime}
      {audioDuration}
      {volume}
      showDeviceControl={Boolean(syncServerUrl && syncServerReady && deviceId)}
      {playbackDeviceOptions}
      {activePlaybackDeviceId}
      {activePlaybackDeviceName}
      {deviceId}
      onToggleShuffle={() => void toggleShuffle()}
      onPrevious={() => void previousTrack()}
      onTogglePlayback={() => void togglePlayback()}
      onNext={() => void nextTrack()}
      onToggleRepeat={() => void toggleRepeat()}
      onSeekInput={(event) => void setProgress(event)}
      onVolumeInput={(event) => void updateVolume(event)}
      onDeviceChange={handlePlaybackDeviceChange}
    />

    {#if syncServerModalOpen}
      <SyncServerModal
        {syncServerUrl}
        bind:syncServerDraft
        onClose={closeSyncServerModal}
        onDisconnect={disconnectSyncServer}
        onApply={() => void applySyncServerChange()}
      />
    {/if}

    {#if playlistModalTrack && library}
      <PlaylistModal
        track={playlistModalTrack}
        playlists={library.playlists}
        bind:selectedIds={playlistModalSelectionIds}
        saving={savingPlaylistMemberships}
        onClose={closePlaylistMembershipModal}
        onSave={() => void savePlaylistMemberships()}
      />
    {/if}

    {#if themeModalOpen}
      <ThemeModal
        {theme}
        activeThemeName={activeTheme.name}
        onSetTheme={setTheme}
        onClose={closeThemeModal}
      />
    {/if}

    <audio
      bind:this={audioEl}
      onended={handleEnded}
      onerror={handleAudioError}
      onloadedmetadata={syncDuration}
      onpause={handleAudioPause}
      onplay={handleAudioPlay}
      ontimeupdate={syncTime}
    ></audio>
  </main>
{/if}
