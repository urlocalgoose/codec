<script lang="ts">
  import { onMount, tick } from "svelte";
  import { version } from "$app/environment";
  import { invoke } from "@tauri-apps/api/core";
  import { listen } from "@tauri-apps/api/event";
  import { open } from "@tauri-apps/plugin-dialog";
  import { AlertCircle, LoaderCircle } from "lucide-svelte";
  import AuxModal from "$lib/components/AuxModal.svelte";
  import BrowseGrid from "$lib/components/BrowseGrid.svelte";
  import PlayerBar from "$lib/components/PlayerBar.svelte";
  import PlaylistModal from "$lib/components/PlaylistModal.svelte";
  import QueueRail from "$lib/components/QueueRail.svelte";
  import SettingsModal from "$lib/components/SettingsModal.svelte";
  import SetupScreen from "$lib/components/SetupScreen.svelte";
  import Sidebar from "$lib/components/Sidebar.svelte";
  import SyncServerModal from "$lib/components/SyncServerModal.svelte";
  import ThemeModal from "$lib/components/ThemeModal.svelte";
  import TopBar from "$lib/components/TopBar.svelte";
  import HomeView from "$lib/components/HomeView.svelte";
  import TrackList from "$lib/components/TrackList.svelte";
  import ViewHeader from "$lib/components/ViewHeader.svelte";
  import VisualizerView from "$lib/components/VisualizerView.svelte";
  import { SpectroSampler } from "$lib/visualizer";
  import { readCachedLibrary, writeCachedLibrary } from "$lib/library-cache";
  import {
    baseName,
    fingerprintFor,
    identityForImportTrack,
    identityForPlaylistRef,
    IMPORT_SCHEMA,
    parseId3,
    type ImportManifest,
    type ImportManifestTrack
  } from "$lib/import";
  import PlaylistGrid from "$lib/components/PlaylistGrid.svelte";
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
    tracksFromReferences,
    homeRecentItems,
    artistCovers
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
    LEGACY_DEFAULT_DEVICE_NAMES,
    defaultSyncServerUrl,
    hasNativeBridge,
    isRemoteRoot,
    REMOTE_ROOT_PATH
  } from "$lib/platform";
  import {
    listAuxSessions,
    joinAuxSession,
    endAuxSession,
    createAuxSession,
    fetchLatestPlaybackSession,
    fetchPlaybackStateV2,
    fetchPlaybackDevices,
    fetchRemoteLibrary,
    derivedPlaybackPosition,
    normalizeServerUrl,
    normalizeLibrary,
    playbackEventsV2Url,
    pushLibrarySnapshot,
    refreshSyncStreamToken,
    setSyncAuthToken,
    setTrackLiked,
    uploadPlaylistArtwork,
    uploadTrackArtwork,
    uploadTrackAudio,
    uploadTrackMetadata,
    createRemotePlaylist,
    addTrackToRemotePlaylist,
    libraryExportUrl,
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

  const ROOT_STORAGE_KEY = "codec.musicRoot";
  const VOLUME_STORAGE_KEY = "codec.volume";
  const SHUFFLE_STORAGE_KEY = "codec.shuffle";
  const REPEAT_STORAGE_KEY = "codec.repeat";
  const THEME_STORAGE_KEY = "codec.theme";
  const SYNC_SERVER_STORAGE_KEY = "codec.syncServer";
  const SYNC_TOKEN_STORAGE_KEY = "codec.syncToken";
  const SYNC_DEVICE_ID_STORAGE_KEY = "codec.deviceId";
  const SYNC_DEVICE_NAME_STORAGE_KEY = "codec.deviceName";
  const SYNC_SELECTED_DEVICE_STORAGE_KEY = "codec.selectedPlaybackDevice";
  const PLAYBACK_SESSION_STORAGE_KEY = "codec.playbackSession";
  const LEGACY_STORAGE_KEYS: Record<string, string> = {
    [ROOT_STORAGE_KEY]: "loud.musicRoot",
    [VOLUME_STORAGE_KEY]: "loud.volume",
    [SHUFFLE_STORAGE_KEY]: "loud.shuffle",
    [REPEAT_STORAGE_KEY]: "loud.repeat",
    [THEME_STORAGE_KEY]: "loud.theme",
    [SYNC_SERVER_STORAGE_KEY]: "loud.syncServer",
    [SYNC_TOKEN_STORAGE_KEY]: "loud.syncToken",
    [SYNC_DEVICE_ID_STORAGE_KEY]: "loud.deviceId",
    [SYNC_DEVICE_NAME_STORAGE_KEY]: "loud.deviceName",
    [SYNC_SELECTED_DEVICE_STORAGE_KEY]: "loud.selectedPlaybackDevice",
    [PLAYBACK_SESSION_STORAGE_KEY]: "loud.playbackSession"
  };
  const DEFAULT_SYNC_SERVER_URL = "http://127.0.0.1:8787";
  const PLAYBACK_SAVE_DELAY_MS = 750;
  const PLAYBACK_DEVICE_SAVE_DELAY_MS = 220;
  const PLAYBACK_DEVICE_POLL_MS = 30000;
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
  let guestMode = false;
  let auxCode = "";
  let auxBusy = false;
  let auxModalOpen = false;
  let settingsModalOpen = false;
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
  let syncTokenDraft = "";
  let syncServerReady = false;
  let deviceId = "";
  let deviceName = "";
  let selectedPlaybackDeviceId = "";
  let playbackDevices: PlaybackDevice[] = [];
  let playbackDevicesEvaluatedRevision = -1;
  let playbackStateV2: PlaybackStateV2 | null = null;
  let playbackClockOffsetMs = 0;
  // While in the future, the derived server clock may not overwrite
  // currentTime — prevents scrub rubber-banding until the server confirms.
  let playbackClockSuppressUntil = 0;

  let audioEl: HTMLAudioElement;
  let topBar: TopBar | undefined;

  function readStoredValue(key: string): string | null {
    return localStorage.getItem(key) ?? localStorage.getItem(LEGACY_STORAGE_KEYS[key] ?? "");
  }

  function writeStoredValue(key: string, value: string): void {
    localStorage.setItem(key, value);
    const legacyKey = LEGACY_STORAGE_KEYS[key];
    if (legacyKey) {
      localStorage.removeItem(legacyKey);
    }
  }

  function removeStoredValue(key: string): void {
    localStorage.removeItem(key);
    const legacyKey = LEGACY_STORAGE_KEYS[key];
    if (legacyKey) {
      localStorage.removeItem(legacyKey);
    }
  }
  let refreshTimer: number | null = null;
  let playbackSaveTimer: number | null = null;
  let playbackDeviceSaveTimer: number | null = null;
  let playbackDevicePollTimer: number | null = null;
  let playbackClockTimer: number | null = null;
  let playbackEventSource: EventSource | null = null;
  let playbackEventSourceUrl = "";
  let unlistenLibrary: (() => void) | null = null;
  let loadedSource = "";
  // Which track the audio element actually holds — the UI's currentTrack can
  // move (session restore vs server state) without the element following.
  let loadedTrackId = "";
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
  // A non-empty search works from anywhere: on browse-style views it becomes
  // a library-wide result list instead of silently doing nothing.
  $: searchActive = searchQuery.trim().length > 0;
  $: globalSearch =
    searchActive &&
    (selectedView === "home" ||
      selectedView === "artists" ||
      selectedView === "albums" ||
      selectedView === "playlists");
  $: userPlaylists = library?.playlists.filter((playlist) => !playlist.is_liked) ?? [];
  $: homeItems = homeRecentItems(library);
  $: homePlaylistCovers = new Map(
    userPlaylists.map((playlist) => {
      const trackIds = new Set(playlist.track_ids);
      return [playlist.id, library?.tracks.find((track) => trackIds.has(track.id)) ?? null];
    })
  );
  $: queue = playbackQueue(currentTrack, queuedTracks, playbackSource, playbackIndex);
  $: baseTracks = globalSearch
    ? (library?.tracks ?? [])
    : trackSourceForView(library, selectedView, selectedPlaylist, queue);
  $: visibleTracks = sortTracks(searchTracks(baseTracks, searchQuery), sortKey);
  $: stats = library?.stats ?? DEFAULT_STATS;
  $: artists = library?.artists ?? [];
  $: artistArt = artistCovers(library);
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
    // The version query makes every deploy a new service-worker URL, so
    // neither the browser nor a CDN can pin devices to a stale build.
    if ("serviceWorker" in navigator && !hasNativeBridge()) {
      navigator.serviceWorker
        .register(`/service-worker.js?v=${version}`, { updateViaCache: "none" })
        .catch(() => undefined);
    }

    const auxParam = new URLSearchParams(window.location.search).get("aux");
    if (auxParam && !hasNativeBridge()) {
      void joinAuxAsGuest(auxParam);
      return;
    }

    rootPath = readStoredValue(ROOT_STORAGE_KEY) ?? "";
    volume = Number(readStoredValue(VOLUME_STORAGE_KEY) ?? volume);
    shuffle = readStoredValue(SHUFFLE_STORAGE_KEY) === "true";
    repeatMode = (readStoredValue(REPEAT_STORAGE_KEY) as RepeatMode | null) ?? "off";
    theme = parseTheme(readStoredValue(THEME_STORAGE_KEY));
    syncServerUrl = normalizeServerUrl(
      readStoredValue(SYNC_SERVER_STORAGE_KEY) ?? defaultSyncServerUrl(DEFAULT_SYNC_SERVER_URL)
    );
    // Heal stored http:// servers on https pages: those calls are mixed
    // content and silently blocked, so the library can never load.
    if (window.location.protocol === "https:" && syncServerUrl.startsWith("http://")) {
      syncServerUrl = `https://${syncServerUrl.slice("http://".length)}`;
      writeStoredValue(SYNC_SERVER_STORAGE_KEY, syncServerUrl);
    }
    syncServerDraft = syncServerUrl;
    syncTokenDraft = readStoredValue(SYNC_TOKEN_STORAGE_KEY) ?? "";
    setSyncAuthToken(syncTokenDraft);
    deviceId = readStoredValue(SYNC_DEVICE_ID_STORAGE_KEY) ?? createDeviceId();
    {
      const storedName = readStoredValue(SYNC_DEVICE_NAME_STORAGE_KEY);
      // Old generic defaults ("Mac Web") collide across browsers; migrate
      // them to the platform+browser default. Custom names stay.
      deviceName =
        storedName && !LEGACY_DEFAULT_DEVICE_NAMES.has(storedName)
          ? storedName
          : defaultDeviceName();
    }
    selectedPlaybackDeviceId = readStoredValue(SYNC_SELECTED_DEVICE_STORAGE_KEY) ?? "";
    writeStoredValue(SYNC_DEVICE_ID_STORAGE_KEY, deviceId);
    writeStoredValue(SYNC_DEVICE_NAME_STORAGE_KEY, deviceName);

    if (rootPath && hasNativeBridge() && !isRemoteRoot(rootPath)) {
      void loadLibrary(rootPath, true);
    } else if (syncServerUrl && (!hasNativeBridge() || rootPath === REMOTE_ROOT_PATH)) {
      // Hydrate from the local cache immediately while the network load
      // runs; whichever lands first paints, the network result wins.
      bootstrapping = true;
      void hydrateLibraryFromCache(syncServerUrl);
      void loadRemoteLibrary(true);
    }

    if (syncServerUrl && rootPath !== REMOTE_ROOT_PATH) {
      void validatePlaybackSyncServer(true);
    }

    if (syncServerUrl) {
      void refreshAuxState();
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
      writeStoredValue(ROOT_STORAGE_KEY, rootPath);
      syncLibrary(nextLibrary);
      await invoke("start_library_watch", { root_path: rootPath }).catch(() => undefined);
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      loading = false;
    }
  }

  let bootstrapping = false;

  async function hydrateLibraryFromCache(serverUrl: string) {
    try {
      const cached = await readCachedLibrary();
      if (!cached || library) {
        return;
      }
      // Fresh stream token first so cached artwork URLs authenticate;
      // offline that fails and we hydrate anyway — a readable library
      // beats a blank screen.
      try {
        await refreshSyncStreamToken(serverUrl);
      } catch {
        // Offline or unreachable — proceed with what we have.
      }
      if (library) {
        return;
      }
      syncLibrary(cached);
    } catch {
      // The cache is best-effort; the network load is still running.
    } finally {
      if (library) {
        bootstrapping = false;
      }
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
      await refreshSyncStreamToken(serverUrl);
      const nextLibrary = await fetchRemoteLibrary(serverUrl);
      syncServerReady = true;
      rootPath = nextLibrary.root_path || REMOTE_ROOT_PATH;
      writeStoredValue(ROOT_STORAGE_KEY, rootPath);
      syncLibrary(nextLibrary);
      void writeCachedLibrary(nextLibrary);
      await restoreRemotePlaybackSession(nextLibrary);
      startPlaybackDevicePolling();
      syncMessage = `Connected · ${formatCount(nextLibrary.tracks.length, "track")}`;
    } catch (error) {
      syncServerReady = false;
      stopPlaybackDevicePolling();
      errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      loading = false;
      bootstrapping = false;
    }
  }

  function syncLibrary(nextLibrary: MusicLibrary) {
    const previousCurrent = currentTrack;
    nextLibrary = normalizeLibrary(nextLibrary);
    library = nextLibrary;

    // If shared playback state landed before the library did, its staleness
    // check couldn't see track durations — re-apply now that it can.
    if (playbackStateV2) {
      void applyPlaybackStateV2(playbackStateV2, true);
    }

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
      readStoredValue(PLAYBACK_SESSION_STORAGE_KEY),
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
    loadedTrackId = "";
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
        readStoredValue(PLAYBACK_SESSION_STORAGE_KEY),
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
      writeStoredValue(PLAYBACK_SESSION_STORAGE_KEY, serialized);
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
      writeStoredValue(SYNC_SERVER_STORAGE_KEY, nextUrl);
    } else {
      removeStoredValue(SYNC_SERVER_STORAGE_KEY);
      stopPlaybackDevicePolling();
    }

    syncTokenDraft = syncTokenDraft.trim();
    setSyncAuthToken(syncTokenDraft);
    if (syncTokenDraft) {
      writeStoredValue(SYNC_TOKEN_STORAGE_KEY, syncTokenDraft);
    } else {
      removeStoredValue(SYNC_TOKEN_STORAGE_KEY);
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
      await refreshSyncStreamToken(serverUrl);
      if (hasNativeBridge() && rootPath && !isRemoteRoot(rootPath)) {
        const report = await invoke<SyncTransferReport>("sync_library_to_server", {
          root_path: rootPath,
          server_url: serverUrl,
          device_id: deviceId,
          auth_token: syncTokenDraft
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
      await refreshSyncStreamToken(serverUrl);
      if (hasNativeBridge() && rootPath && !isRemoteRoot(rootPath)) {
        const report = await invoke<SyncTransferReport>("sync_library_from_server", {
          root_path: rootPath,
          server_url: serverUrl,
          auth_token: syncTokenDraft
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
      await refreshSyncStreamToken(serverUrl);
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
    syncTokenDraft = "";
    setSyncAuthToken("");
    removeStoredValue(SYNC_TOKEN_STORAGE_KEY);
    removeStoredValue(SYNC_SERVER_STORAGE_KEY);
    removeStoredValue(SYNC_SELECTED_DEVICE_STORAGE_KEY);
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
      loadedTrackId = "";
      playbackSessionRestored = false;
      removeStoredValue(ROOT_STORAGE_KEY);
    }
  }

  // ---------------------------------------------------------------------------
  // Playback devices + shared playback state (v2)
  // ---------------------------------------------------------------------------

  function usePlaybackSync(): boolean {
    return Boolean(syncServerUrl && syncServerReady && deviceId);
  }

  // True when this desktop is the device that should be making sound, which
  // means transport actions can apply locally first and sync afterwards
  // instead of waiting a network round-trip before the audio reacts.
  function isActiveSyncDevice(): boolean {
    if (!usePlaybackSync()) {
      return true;
    }
    const active = playbackStateV2?.active_device_id;
    return !active || active === deviceId;
  }

  // After a locally-applied track change, tell the server the outcome as an
  // explicit play (a bare next/previous would advance the server's copy a
  // second time, since commands replace server context before applying).
  function notifyServerAfterLocalChange(beforeTrackId: string | null, fallbackKind: PlaybackCommandKindV2) {
    if (!usePlaybackSync()) {
      return;
    }

    const command =
      currentTrack && currentTrack.id !== beforeTrackId
        ? sendPlaybackCommand("play", {
            track: trackReference(currentTrack),
            context: playbackContextSnapshot(),
            position_seconds: 0
          })
        : sendPlaybackCommand(fallbackKind, {
            position_seconds: currentPlaybackTimeForSave()
          });

    command
      .then((state) => applyPlaybackStateV2(state, true))
      .catch((error) => {
        errorMessage = error instanceof Error ? error.message : String(error);
      });
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

  async function startPlaybackEvents() {
    if (!syncServerUrl || !syncServerReady || typeof EventSource === "undefined") {
      return;
    }

    await refreshSyncStreamToken(syncServerUrl);
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
        // Re-evaluate once per revision after the devices list lands: the
        // ghost-device check inside apply can only judge with devices known.
        const reevaluate =
          playbackStateV2 !== null &&
          state.revision === playbackStateV2.revision &&
          playbackDevicesEvaluatedRevision !== state.revision;
        await applyPlaybackStateV2(state, reevaluate);
        playbackDevicesEvaluatedRevision = state.revision;
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
    writeStoredValue(SYNC_SELECTED_DEVICE_STORAGE_KEY, targetDeviceId);
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

    const targetTrack = library && nextState.track ? findTrackByReference(library, nextState.track) : null;

    // A "playing" state whose derived position has run far past the end of
    // the track — or whose clock nobody has touched in ages — is a corpse:
    // whatever device owned it went away without pausing. Don't mirror it as
    // playing, and don't keep aiming commands at the dead device — otherwise
    // a fresh page click sends play to a phone that left days ago and
    // nothing audible happens here.
    const trackDuration = targetTrack?.duration_seconds ?? 0;
    const positionOverrun =
      trackDuration > 0 &&
      derivedPlaybackPosition(nextState, Date.now(), playbackClockOffsetMs) > trackDuration + 8;
    const clockTouchedMs = Math.max(
      nextState.clock.started_at_ms ?? 0,
      nextState.clock.updated_at_ms || 0
    );
    const clockAbandoned =
      clockTouchedMs > 0 && nextState.server_time_ms - clockTouchedMs > 30 * 60 * 1000;
    // "Playing" on a device that isn't registered anymore is a ghost — the
    // phone closed the app without pausing. (Only judged once the devices
    // list has actually loaded.)
    const remoteGhost =
      nextState.state === "playing" &&
      Boolean(nextState.active_device_id) &&
      nextState.active_device_id !== deviceId &&
      playbackDevices.length > 0 &&
      !playbackDevices.some((device) => device.device_id === nextState.active_device_id);
    // Never call it stale while OUR audio element is audibly playing — a
    // long local listening session only refreshes the clock on track
    // changes, and the element is the truth here.
    const locallyAudible =
      nextState.active_device_id === deviceId && Boolean(audioEl) && !audioEl!.paused;
    const stalePlayback =
      nextState.state === "playing" &&
      (positionOverrun || clockAbandoned || remoteGhost) &&
      !locallyAudible;

    if (stalePlayback) {
      selectedPlaybackDeviceId = deviceId;
      writeStoredValue(SYNC_SELECTED_DEVICE_STORAGE_KEY, selectedPlaybackDeviceId);
    } else if (nextState.active_device_id) {
      selectedPlaybackDeviceId = nextState.active_device_id;
      writeStoredValue(SYNC_SELECTED_DEVICE_STORAGE_KEY, selectedPlaybackDeviceId);
    } else if (!selectedPlaybackDeviceId) {
      selectedPlaybackDeviceId = deviceId;
      writeStoredValue(SYNC_SELECTED_DEVICE_STORAGE_KEY, selectedPlaybackDeviceId);
    }

    applyPlaybackContextV2(nextState);
    currentTime = clampPlaybackTime(currentSyncedPlaybackPosition(), targetTrack ?? currentTrack);
    isPlaying = nextState.state === "playing" && !stalePlayback;
    volume = Math.max(0, Math.min(nextState.volume, 1));
    writeStoredValue(VOLUME_STORAGE_KEY, String(volume));
    if (stalePlayback) {
      stopPlaybackClock();
    } else {
      updatePlaybackClock();
    }

    if (targetTrack) {
      currentTrack = targetTrack;
      audioDuration = targetTrack.duration_seconds || audioDuration;
    }

    applyingRemotePlayback = true;
    try {
      if (nextState.active_device_id === deviceId && targetTrack && !stalePlayback) {
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
    const candidate = selectedPlaybackDeviceId || playbackStateV2?.active_device_id || deviceId;
    if (candidate === deviceId) {
      return deviceId;
    }
    // Never aim commands at a device that isn't actually registered right
    // now — a phone that closed the app stays "active" in old state, and
    // sending play there means silence here. Local playback is the safe
    // fallback; the user can always re-pick a live target.
    const live = playbackDevices.some((device) => device.device_id === candidate);
    return live ? candidate : deviceId;
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
    writeStoredValue(SHUFFLE_STORAGE_KEY, String(shuffle));
    writeStoredValue(REPEAT_STORAGE_KEY, repeatMode);
  }

  async function syncLocalAudioToPlaybackState(state: PlaybackStateV2, track: Track) {
    if (!audioEl) {
      return;
    }

    const position = clampPlaybackTime(currentSyncedPlaybackPosition(), track);
    const source = await playbackUrlForTrack(track);
    if (loadedSource !== source) {
      loadAudioSource(source, position, track.id);
      await waitForAudioMetadata();
    } else if (Math.abs((audioEl.currentTime || 0) - position) > 0.75) {
      audioEl.currentTime = position;
      currentTime = position;
    }

    if (state.state === "playing") {
      try {
        await audioEl.play();
        isPlaying = true;
      } catch (error) {
        // Autoplay policy: without a user gesture (a fresh page load), the
        // browser refuses play(). Reflect reality — pause the shared state
        // at the current position so the play button resumes cleanly on the
        // first press instead of fighting a "playing" server state.
        isPlaying = false;
        console.warn("resume blocked by autoplay policy; pausing shared state", error);
        void sendPlaybackCommand("pause", {
          target_device_id: deviceId,
          position_seconds: position
        })
          .then((paused) => applyPlaybackStateV2(paused, true))
          .catch(() => undefined);
      }
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

    // When this desktop is the one playing, the audio element is the truth
    // (syncTime feeds currentTime); the derived clock is for mirroring
    // remote devices, and stays quiet right after a local seek.
    const audioIsTruth = isActiveSyncDevice() && Boolean(loadedSource);
    if (!audioIsTruth && Date.now() >= playbackClockSuppressUntil) {
      currentTime = clampPlaybackTime(currentSyncedPlaybackPosition(), currentTrack);
    }
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

  // Web Audio tap for the visualizer. Built lazily on first open (an
  // AudioContext needs a user gesture) and kept for the session — a media
  // element can only be wired into a graph once.
  let audioGraphContext: AudioContext | null = null;
  let visualizerAnalyser: AnalyserNode | null = null;
  let visualizerSampler: SpectroSampler | null = null;

  function ensureAnalyser(): AnalyserNode | null {
    if (!audioEl) {
      return null;
    }

    if (!audioGraphContext) {
      try {
        audioGraphContext = new AudioContext();
        const source = audioGraphContext.createMediaElementSource(audioEl);
        const analyser = audioGraphContext.createAnalyser();
        analyser.fftSize = 2048;
        analyser.smoothingTimeConstant = 0.72;
        source.connect(analyser);
        analyser.connect(audioGraphContext.destination);
        visualizerAnalyser = analyser;
        // Record from the moment the graph exists, whatever view is open,
        // so the Visualizer never arrives blank mid-song.
        visualizerSampler = new SpectroSampler(analyser);
      } catch (error) {
        console.warn("visualizer: audio graph unavailable", error);
        return null;
      }
    }

    void audioGraphContext.resume();
    return visualizerAnalyser;
  }

  // Only build the graph once the user has interacted — created without a
  // gesture, the context starts suspended and silences the audio element.
  $: if (
    selectedView === "visualizer" &&
    audioEl &&
    !visualizerAnalyser &&
    (navigator.userActivation?.hasBeenActive ?? true)
  ) {
    visualizerAnalyser = ensureAnalyser();
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

  function queueTrackLast(track: Track) {
    queuedTracks = [...queuedTracks, track];
  }

  function moveQueuedTrack(queueIndex: number, targetQueueIndex: number) {
    const from = queueIndex - 1;
    const to = targetQueueIndex - 1;
    if (
      from < 0 ||
      from >= queuedTracks.length ||
      to < 0 ||
      to >= queuedTracks.length ||
      from === to
    ) {
      return;
    }

    const next = [...queuedTracks];
    const [moved] = next.splice(from, 1);
    next.splice(to, 0, moved);
    queuedTracks = next;
  }

  async function togglePlayback() {
    if (usePlaybackSync()) {
      const targetDeviceId = selectedPlaybackTargetDeviceId();
      const targetIsPlaying =
        playbackStateV2?.state === "playing" && playbackStateV2.active_device_id === targetDeviceId;
      const actingLocally = targetDeviceId === deviceId && Boolean(currentTrack) && Boolean(loadedSource);

      if (targetIsPlaying) {
        if (actingLocally) {
          audioEl?.pause();
          isPlaying = false;
        }
        void sendPlaybackCommand("pause", {
          target_device_id: targetDeviceId,
          position_seconds: currentPlaybackTimeForSave()
        })
          .then((state) => applyPlaybackStateV2(state, true))
          .catch((error) => {
            errorMessage = error instanceof Error ? error.message : String(error);
          });
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

      // Optimistic local play only when the element actually holds THIS
      // track — otherwise a session-restored source would play a different
      // song than the UI shows; the command round-trip loads the right one.
      if (actingLocally && currentTrack?.id === track.id && loadedTrackId === track.id) {
        void audioEl?.play().catch(() => undefined);
        isPlaying = true;
      }
      void sendPlaybackCommand("play", {
        target_device_id: targetDeviceId,
        track: trackReference(track),
        context,
        position_seconds: currentTrack?.id === track.id ? currentPlaybackTimeForSave() : 0
      })
        .then((state) => applyPlaybackStateV2(state, true))
        .catch((error) => {
          errorMessage = error instanceof Error ? error.message : String(error);
        });
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
        loadAudioSource(source, currentTime, currentTrack.id);
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
    if (track.media_url) {
      return track.media_url;
    }
    if (isRemoteRoot(rootPath) || !hasNativeBridge()) {
      if (!syncServerUrl) {
        throw new Error("Remote playback needs a sync server URL.");
      }
      await refreshSyncStreamToken(syncServerUrl);
      return trackAudioUrl(syncServerUrl, track.fingerprint);
    }

    const source = await invoke<PlaybackSource>("prepare_track_playback", {
      root_path: rootPath,
      track_path: track.path
    });
    return source.url;
  }

  function loadAudioSource(source: string, seekTime = 0, trackId = "") {
    audioEl.src = source;
    pendingSeekTime = seekTime > 0 ? seekTime : null;
    audioEl.load();
    loadedSource = source;
    loadedTrackId = trackId;
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
    if (usePlaybackSync() && !isActiveSyncDevice()) {
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

    const beforeTrackId = currentTrack?.id ?? null;
    await localNextTrack();
    notifyServerAfterLocalChange(beforeTrackId, "next");
  }

  async function localNextTrack() {
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
    if (usePlaybackSync() && !isActiveSyncDevice()) {
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

    const beforeTrackId = currentTrack?.id ?? null;

    if (audioEl && audioEl.currentTime > 4) {
      audioEl.currentTime = 0;
      currentTime = 0;
      if (usePlaybackSync()) {
        playbackClockSuppressUntil = Date.now() + 1500;
        void sendPlaybackCommand("seek", { position_seconds: 0 })
          .then((state) => applyPlaybackStateV2(state, true))
          .catch(() => undefined);
      }
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
    notifyServerAfterLocalChange(beforeTrackId, "previous");
  }

  async function handleEnded() {
    if (usePlaybackSync()) {
      if (playbackStateV2?.active_device_id !== deviceId) {
        return;
      }

      // Start the next song immediately; a network wait here is an audible
      // gap between every track.
      if (repeatMode === "one") {
        audioEl.currentTime = 0;
        await startPlayback();
        playbackClockSuppressUntil = Date.now() + 1500;
        void sendPlaybackCommand("seek", { target_device_id: deviceId, position_seconds: 0 })
          .then((state) => applyPlaybackStateV2(state, true))
          .catch(() => undefined);
        return;
      }

      const beforeTrackId = currentTrack?.id ?? null;
      await localNextTrack();
      notifyServerAfterLocalChange(beforeTrackId, "next");
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

      // Flip locally right away; the server confirmation reconciles.
      shuffle = nextShuffle;
      playbackSource = nextSource;
      playbackIndex = nextIndex;
      writeStoredValue(SHUFFLE_STORAGE_KEY, String(shuffle));

      void sendPlaybackCommand("set_shuffle", {
        shuffle: nextShuffle,
        context: playbackContextSnapshot(nextSource, nextIndex, queuedTracks, playHistory, nextShuffle, repeatMode),
        position_seconds: currentPlaybackTimeForSave()
      })
        .then((state) => applyPlaybackStateV2(state, true))
        .catch((error) => {
          errorMessage = error instanceof Error ? error.message : String(error);
        });
      return;
    }

    shuffle = nextShuffle;
    writeStoredValue(SHUFFLE_STORAGE_KEY, String(shuffle));

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
    repeatMode = nextRepeat;
    writeStoredValue(REPEAT_STORAGE_KEY, repeatMode);

    if (usePlaybackSync()) {
      void sendPlaybackCommand("set_repeat", {
        repeat: nextRepeat,
        context: playbackContextSnapshot(playbackSource, playbackIndex, queuedTracks, playHistory, shuffle, nextRepeat),
        position_seconds: currentPlaybackTimeForSave()
      })
        .then((state) => applyPlaybackStateV2(state, true))
        .catch((error) => {
          errorMessage = error instanceof Error ? error.message : String(error);
        });
    }
  }

  async function setProgress(event: Event) {
    const value = Number((event.currentTarget as HTMLInputElement).value);
    currentTime = value;

    if (usePlaybackSync()) {
      if (isActiveSyncDevice() && audioEl) {
        audioEl.currentTime = value;
      }
      playbackClockSuppressUntil = Date.now() + 1500;
      void sendPlaybackCommand("seek", { position_seconds: value })
        .then((state) => applyPlaybackStateV2(state, true))
        .catch((error) => {
          errorMessage = error instanceof Error ? error.message : String(error);
        });
      return;
    }

    if (audioEl) {
      audioEl.currentTime = value;
    }
    schedulePlaybackDeviceUpdate(true);
  }

  async function updateVolume(event: Event) {
    volume = Number((event.currentTarget as HTMLInputElement).value);
    writeStoredValue(VOLUME_STORAGE_KEY, String(volume));

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
      const base = isActiveSyncDevice() && audioEl ? audioEl.currentTime : currentSyncedPlaybackPosition();
      const nextTime = Math.max(0, Math.min(duration || 0, base + seconds));
      currentTime = nextTime;
      if (isActiveSyncDevice() && audioEl) {
        audioEl.currentTime = nextTime;
      }
      playbackClockSuppressUntil = Date.now() + 1500;
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
      if (isActiveSyncDevice() && loadedSource) {
        currentTime = audioEl?.currentTime ?? 0;
      }
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
      // When this desktop is the speaker, the audio element is the truth —
      // mirroring the server here would undo optimistic pause taps until
      // the confirmation round-trip lands.
      isPlaying = isActiveSyncDevice() ? false : playbackStateV2?.state === "playing";
      return;
    }

    isPlaying = false;
    schedulePlaybackDeviceUpdate(true);

    void activateThisPlaybackDevice();
  }

  function handleAudioPlay() {
    // If the element is wired into the visualizer's audio graph and that
    // context is suspended (it was built without a user gesture), every
    // sample routes into a dead graph and playback is silent. Any real play
    // is a gesture, so wake the graph here.
    if (audioGraphContext && audioGraphContext.state !== "running") {
      void audioGraphContext.resume();
    }
    // Build the graph on the first user-initiated play from any view, so
    // the visualizer records history in the background. Remote-initiated
    // play without any interaction skips this — an AudioContext created
    // without a gesture starts suspended and would silence the element.
    if (!visualizerAnalyser && (navigator.userActivation?.hasBeenActive ?? false)) {
      visualizerAnalyser = ensureAnalyser();
    }

    if (applyingRemotePlayback) {
      return;
    }
    if (usePlaybackSync()) {
      isPlaying = isActiveSyncDevice() ? true : playbackStateV2?.state === "playing";
      return;
    }

    isPlaying = true;
    schedulePlaybackDeviceUpdate(true);

    void activateThisPlaybackDevice();
  }

  // ---------------------------------------------------------------------------
  // Views, themes, and playlist editing
  // ---------------------------------------------------------------------------

  async function joinAuxAsGuest(code: string) {
    const origin = window.location.origin;
    // Hand off to the native app when it's installed; iOS switches apps and
    // hides this tab, otherwise the browser join below is the fallback.
    if (/iPhone|iPad|iPod/.test(navigator.userAgent)) {
      window.location.href = `codec://aux?server=${encodeURIComponent(origin)}&code=${encodeURIComponent(code)}`;
      await new Promise((resolve) => setTimeout(resolve, 1500));
      if (document.hidden) {
        return;
      }
    }
    try {
      const session = await joinAuxSession(origin, code);
      guestMode = true;
      auxCode = session.code;
      syncServerUrl = normalizeServerUrl(origin);
      syncServerDraft = syncServerUrl;
      syncTokenDraft = session.guest_token ?? "";
      setSyncAuthToken(session.guest_token ?? "");
      deviceId = createDeviceId();
      deviceName = "Aux guest";
      rootPath = REMOTE_ROOT_PATH;
      await loadRemoteLibrary(false);
      void validatePlaybackSyncServer(true);
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  async function startAux() {
    if (auxBusy || !syncServerUrl) {
      return;
    }
    auxBusy = true;
    errorMessage = "";
    try {
      const session = await createAuxSession(syncServerUrl);
      auxCode = session.code;
      auxModalOpen = true;
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      auxBusy = false;
    }
  }

  async function endAux() {
    if (auxBusy || !auxCode) {
      return;
    }
    auxBusy = true;
    try {
      await endAuxSession(syncServerUrl, auxCode);
      auxCode = "";
      auxModalOpen = false;
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      auxBusy = false;
    }
  }

  function auxLink(): string {
    return `${normalizeServerUrl(syncServerUrl)}/?aux=${auxCode}`;
  }

  async function copyAuxLink() {
    try {
      await navigator.clipboard.writeText(auxLink());
      syncMessage = "Aux link copied";
    } catch {
      syncMessage = auxLink();
    }
  }

  async function refreshAuxState() {
    try {
      const sessions = await listAuxSessions(syncServerUrl);
      auxCode = sessions[0]?.code ?? "";
    } catch {
      // not connected or not the host - fine
    }
  }

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
    writeStoredValue(THEME_STORAGE_KEY, nextTheme);
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

  // Browser MP3 import: tags parsed client-side, identity derived exactly
  // like the desktop, then metadata + audio + artwork go straight to the
  // sync server through the existing upsert endpoints.
  async function importAudioFiles(files: File[]) {
    if (!syncServerUrl || files.length === 0 || importing) {
      return;
    }

    const manifestFile = files.find((file) => file.name.toLowerCase().endsWith(".json"));
    const audioFiles = files.filter((file) => file !== manifestFile);

    importing = true;
    errorMessage = "";
    try {
      if (manifestFile) {
        await importManifestBundle(manifestFile, audioFiles);
      } else {
        await importPlainAudio(audioFiles);
      }
    } finally {
      importing = false;
    }
  }

  async function importPlainAudio(files: File[]) {
    let imported = 0;
    const failures: string[] = [];
    for (const [index, file] of files.entries()) {
      syncMessage = `Importing ${index + 1}/${files.length}: ${file.name}`;
      try {
        await importSingleAudioFile(file);
        imported += 1;
      } catch (error) {
        console.warn("import failed", file.name, error);
        failures.push(file.name);
      }
    }
    await loadRemoteLibrary(true);
    syncMessage =
      failures.length > 0
        ? `Imported ${formatCount(imported, "track")} · failed: ${failures.join(", ")}`
        : `Imported ${formatCount(imported, "track")}`;
  }

  /** loud.import.v1 in the browser: pick the manifest together with its
   * audio files. Identity, dedupe, liked flags, and playlist refs follow
   * docs/codec-import-v1.md — everything lands on the sync server. */
  async function importManifestBundle(manifestFile: File, audioFiles: File[]) {
    let manifest: ImportManifest;
    try {
      manifest = JSON.parse(await manifestFile.text()) as ImportManifest;
    } catch {
      errorMessage = `${manifestFile.name} is not valid JSON.`;
      return;
    }
    if (manifest.schema && manifest.schema !== IMPORT_SCHEMA) {
      errorMessage = `Unsupported import schema ${manifest.schema} (expected ${IMPORT_SCHEMA}).`;
      return;
    }

    const manifestTracks = manifest.tracks ?? [];
    const filesByBase = new Map(audioFiles.map((file) => [file.name.toLowerCase(), file]));
    const known = new Set(library?.tracks.map((track) => track.fingerprint) ?? []);
    const identityByFile = new Map<string, string>();
    const likedTargets: string[] = [];
    let added = 0;
    let existing = 0;
    let likedUpdates = 0;
    let playlistAdds = 0;
    const skipped: string[] = [];

    for (const [index, entry] of manifestTracks.entries()) {
      syncMessage = `Importing ${index + 1}/${manifestTracks.length}${entry.title ? `: ${entry.title}` : ""}`;
      const identity = identityForImportTrack(entry);
      if (entry.file) {
        identityByFile.set(entry.file, identity);
      }

      if (known.has(identity)) {
        existing += 1;
      } else {
        const file = entry.file ? filesByBase.get(baseName(entry.file).toLowerCase()) : undefined;
        if (!file) {
          skipped.push(entry.file ?? entry.title ?? "unnamed track");
          continue;
        }
        try {
          await importSingleAudioFile(file, entry, identity);
          known.add(identity);
          added += 1;
        } catch (error) {
          console.warn("manifest import failed", entry.file, error);
          skipped.push(entry.file ?? entry.title ?? "unnamed track");
          continue;
        }
      }

      if (entry.liked) {
        likedTargets.push(identity);
      }
    }

    for (const identity of likedTargets) {
      try {
        await setTrackLiked(syncServerUrl, identity, true);
        likedUpdates += 1;
      } catch (error) {
        console.warn("liked update failed", identity, error);
      }
    }

    // Playlist membership: track-level names plus the playlists section.
    const wanted = new Map<string, Set<string>>();
    const want = (name: string | undefined, identity: string | null) => {
      const key = name?.trim();
      if (!key || !identity) {
        return;
      }
      if (!wanted.has(key)) {
        wanted.set(key, new Set());
      }
      wanted.get(key)!.add(identity);
    };
    for (const entry of manifestTracks) {
      for (const name of entry.playlists ?? []) {
        want(name, identityForImportTrack(entry));
      }
    }
    for (const playlist of manifest.playlists ?? []) {
      for (const ref of playlist.tracks ?? []) {
        want(playlist.name, identityForPlaylistRef(ref, identityByFile));
      }
    }

    for (const [name, identities] of wanted) {
      try {
        const target =
          library?.playlists.find(
            (playlist) => !playlist.is_liked && playlist.name.toLowerCase() === name.toLowerCase()
          ) ?? null;
        const have = new Set(target?.track_ids ?? []);
        const targetId = target?.id ?? (await createRemotePlaylist(syncServerUrl, name)).id;
        for (const identity of identities) {
          if (have.has(`track_${identity}`)) {
            continue;
          }
          await addTrackToRemotePlaylist(syncServerUrl, targetId, identity);
          playlistAdds += 1;
        }
      } catch (error) {
        console.warn("playlist import failed", name, error);
      }
    }

    await loadRemoteLibrary(true);
    const bits = [`${added} new`, `${existing} existing`];
    if (playlistAdds > 0) {
      bits.push(`${playlistAdds} playlist adds`);
    }
    if (likedUpdates > 0) {
      bits.push(`${likedUpdates} liked`);
    }
    if (skipped.length > 0) {
      bits.push(`skipped ${skipped.length}: ${skipped.slice(0, 3).join(", ")}${skipped.length > 3 ? "…" : ""}`);
    }
    syncMessage = `Import · ${bits.join(" · ")}`;
  }

  async function importSingleAudioFile(
    file: File,
    manifestEntry?: ImportManifestTrack,
    identityOverride?: string
  ) {
    const tags = parseId3(await file.arrayBuffer());
    const title = manifestEntry?.title || tags.title || file.name.replace(/\.[^.]+$/, "");
    const artist = manifestEntry?.artist || tags.artist || "Unknown Artist";
    const album = manifestEntry?.album || tags.album || "Unknown Album";
    const fingerprint = identityOverride ?? fingerprintFor(title, artist, album);
    const manifestDuration =
      manifestEntry?.duration_ms && manifestEntry.duration_ms > 0
        ? manifestEntry.duration_ms / 1000
        : null;

    const track: Track = {
      id: `track_${fingerprint}`,
      path: `loud://import/${fingerprint}/${file.name}`,
      file_name: file.name,
      title,
      artist,
      album,
      album_artist: manifestEntry?.album_artist ?? tags.albumArtist ?? null,
      genre: manifestEntry?.genre ?? tags.genre ?? null,
      year: manifestEntry?.year ?? tags.year ?? null,
      track_number: manifestEntry?.track_number ?? tags.trackNumber ?? null,
      duration_seconds: manifestDuration ?? (await readAudioDuration(file)),
      artwork_url: null,
      playlist_ids: [],
      added_at: Math.floor(Date.now() / 1000),
      size_bytes: file.size,
      is_liked: false,
      fingerprint
    };

    const payload = {
      ...track,
      ...(manifestEntry?.identifiers ? { identifiers: manifestEntry.identifiers } : {}),
      ...(manifestEntry?.source_urls ? { source_urls: manifestEntry.source_urls } : {})
    } as Track;

    await uploadTrackMetadata(syncServerUrl, payload);
    await uploadTrackAudio(syncServerUrl, fingerprint, file);
    if (tags.artwork) {
      await uploadTrackArtwork(
        syncServerUrl,
        fingerprint,
        new Blob([tags.artwork.data.slice()], { type: tags.artwork.mime })
      );
    }
  }

  /** The browser's own demuxer reads the duration — no decoding needed. */
  function readAudioDuration(file: File): Promise<number | null> {
    return new Promise((resolve) => {
      const url = URL.createObjectURL(file);
      const probe = new Audio();
      probe.preload = "metadata";
      const done = (value: number | null) => {
        URL.revokeObjectURL(url);
        resolve(value);
      };
      probe.onloadedmetadata = () =>
        done(Number.isFinite(probe.duration) && probe.duration > 0 ? probe.duration : null);
      probe.onerror = () => done(null);
      probe.src = url;
    });
  }

  /** Download the whole library as a loud.import.v1 zip — hand it to a
   * friend, their import dedupes what they already have. */
  async function shareLibrary() {
    if (!syncServerUrl) {
      return;
    }
    try {
      await refreshSyncStreamToken(syncServerUrl);
    } catch {
      // A stale token still falls back to the main auth token in the URL.
    }
    window.location.assign(libraryExportUrl(syncServerUrl));
  }

  async function changePlaylistCover(file: File) {
    if (!selectedPlaylist || !syncServerUrl) {
      return;
    }

    errorMessage = "";
    try {
      await uploadPlaylistArtwork(syncServerUrl, selectedPlaylist.id, file);
      await loadRemoteLibrary(true);
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  function applyLocalLikeState(track: Track, liked: boolean) {
    if (!library) {
      return;
    }

    const activeLibrary = library;
    const targetIds = new Set(
      activeLibrary.tracks
        .filter((candidate) => candidate.fingerprint === track.fingerprint)
        .map((candidate) => candidate.id)
    );
    const nextTracks = activeLibrary.tracks.map((candidate) =>
      targetIds.has(candidate.id) ? { ...candidate, is_liked: liked } : candidate
    );
    const nextPlaylists = activeLibrary.playlists.map((playlist) => {
      if (!playlist.is_liked) {
        return playlist;
      }

      const trackIds = playlist.track_ids.filter((trackId) => !targetIds.has(trackId));
      if (liked) {
        trackIds.push(...targetIds);
      }
      return { ...playlist, track_ids: trackIds };
    });

    syncLibrary({
      ...activeLibrary,
      tracks: nextTracks,
      playlists: nextPlaylists,
      stats: {
        ...activeLibrary.stats,
        likedCount: nextTracks.filter((candidate) => candidate.is_liked).length
      }
    });
  }

  async function toggleLike(track: Track) {
    if (!rootPath || !library) {
      return;
    }

    const previousLibrary = library;
    const nextLiked = !track.is_liked;
    applyLocalLikeState(track, nextLiked);

    try {
      if (isRemoteRoot(rootPath)) {
        await setTrackLiked(syncServerUrl, track.fingerprint, nextLiked);
      } else if (nextLiked) {
        await invoke("copy_track_to_liked", { root_path: rootPath, track_path: track.path });
      } else {
        await invoke("remove_liked_track", { root_path: rootPath, track_path: track.path });
      }
      refreshActiveLibrary();
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
      syncLibrary(previousLibrary);
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

{#if !library && !loading && !bootstrapping}
  <SetupScreen
    {theme}
    isNative={hasNativeBridge()}
    {loading}
    {errorMessage}
    bind:syncServerDraft
    bind:syncTokenDraft
    onChooseFolder={() => void chooseFolder()}
    onConnect={() => void loadRemoteLibrary(false)}
  />
{:else}
  <main class="app-shell" data-theme={theme}>
    <Sidebar
      {selectedView}
      {guestMode}
      {auxCode}
      onSelectView={selectView}
      onOpenSettings={() => (settingsModalOpen = true)}
      onShowAux={() => (auxModalOpen = true)}
    />

    <TopBar bind:this={topBar} bind:searchQuery />

    <section class="content">
      {#if loading || (bootstrapping && !library)}
        <section class="loading-state">
          <LoaderCircle class="spin-icon" size={34} />
          <p>Reading music folder</p>
        </section>
      {:else if library}
        {#if selectedView !== "home" && selectedView !== "visualizer" && !globalSearch}
          <ViewHeader
            {viewTitle}
            {viewSubtitle}
            {selectedPlaylist}
            isEditing={isEditingSelectedPlaylist}
            renaming={renamingPlaylist}
            canEditCover={Boolean(syncServerUrl) &&
              !guestMode &&
              (!hasNativeBridge() || isRemoteRoot(rootPath))}
            bind:playlistNameDraft
            onStartRename={startPlaylistRename}
            onCommitRename={() => void commitPlaylistRename()}
            onCancelRename={cancelPlaylistRename}
            onChangeCover={(file) => void changePlaylistCover(file)}
          />
        {/if}

        {#if errorMessage}
          <section class="error-strip"><AlertCircle size={17} /> {errorMessage}</section>
        {/if}

        {#if selectedView === "home" && !globalSearch}
          <HomeView
            {userPlaylists}
            recentItems={homeItems}
            playlistCovers={homePlaylistCovers}
            currentTrackId={currentTrack?.id ?? null}
            onOpenPlaylist={selectView}
            onOpenAlbum={openFromBrowseGrid}
            onPlayTrack={(track) => void playTrackRow(track, 0)}
          />
        {:else if selectedView === "visualizer"}
          <VisualizerView
            sampler={visualizerSampler}
            {currentTrack}
            {theme}
          />
        {:else if selectedView === "artists" && !globalSearch}
          <BrowseGrid kind="artists" {artists} {artistArt} onOpen={openFromBrowseGrid} />
        {:else if selectedView === "albums" && !globalSearch}
          <BrowseGrid kind="albums" {albums} onOpen={openFromBrowseGrid} />
        {:else if selectedView === "playlists" && !globalSearch}
          <PlaylistGrid
            playlists={userPlaylists}
            playlistCovers={homePlaylistCovers}
            onOpen={selectView}
          />
        {:else}
          <TrackList
            viewTitle={globalSearch ? "Search" : viewTitle}
            isQueueView={selectedView === "queue"}
            listMeta={globalSearch ? formatCount(visibleTracks.length, "result") : listMeta}
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
            onQueueTrack={queueTrackLast}
            onRemoveQueued={removeQueuedTrackAt}
            {guestMode}
            onEditPlaylists={openPlaylistMembershipModal}
            onToggleLike={(track) => void toggleLike(track)}
          />
        {/if}
      {/if}
    </section>

    <QueueRail
      {queue}
      queuedTracksCount={queuedTracks.length}
      currentTrackId={currentTrack?.id ?? null}
      {isPlaying}
      onPlayQueueTrack={(index) => void playQueueTrack(index)}
      onRemoveQueued={removeQueuedTrackAt}
      onMoveQueued={moveQueuedTrack}
      onClearQueue={clearQueuedTracks}
    />

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
        bind:syncTokenDraft
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

    {#if settingsModalOpen}
      <SettingsModal
        activeThemeName={activeTheme.name}
        {syncing}
        canUpload={Boolean(library)}
        {syncMessage}
        {importing}
        importDisabled={isRemoteRoot(rootPath)}
        {auxCode}
        {auxBusy}
        onOpenThemeModal={() => {
          settingsModalOpen = false;
          openThemeModal();
        }}
        onOpenSyncServerModal={() => {
          settingsModalOpen = false;
          openSyncServerModal();
        }}
        onSyncToServer={() => void syncToServer()}
        onSyncFromServer={() => void syncFromServer()}
        onImportManifest={() => void chooseImportManifest()}
        onImportFiles={(files) => void importAudioFiles(files)}
        canShare={Boolean(syncServerUrl) && syncServerReady}
        onShareLibrary={() => void shareLibrary()}
        onRefresh={refreshActiveLibrary}
        onStartAux={() => void startAux()}
        onShowAux={() => {
          settingsModalOpen = false;
          auxModalOpen = true;
        }}
        onEndAux={() => void endAux()}
        onClose={() => (settingsModalOpen = false)}
      />
    {/if}

    {#if auxModalOpen && auxCode}
      <AuxModal
        {auxCode}
        auxLink={auxLink()}
        onCopyLink={() => void copyAuxLink()}
        onEnd={() => void endAux()}
        onClose={() => (auxModalOpen = false)}
      />
    {/if}

    <audio
      bind:this={audioEl}
      crossorigin="anonymous"
      onended={handleEnded}
      onerror={handleAudioError}
      onloadedmetadata={syncDuration}
      onpause={handleAudioPause}
      onplay={handleAudioPlay}
      ontimeupdate={syncTime}
    ></audio>
  </main>
{/if}
