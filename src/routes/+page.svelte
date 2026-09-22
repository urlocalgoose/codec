<script lang="ts">
  import { onMount, tick } from "svelte";
  import { version } from "$app/environment";
  import { invoke } from "@tauri-apps/api/core";
  import { listen } from "@tauri-apps/api/event";
  import { open } from "@tauri-apps/plugin-dialog";
  import { AlertCircle, ChevronLeft, LoaderCircle, Palette, Radio, Search, X } from "lucide-svelte";
  import MobileSymbol from "$lib/components/MobileSymbol.svelte";
  import DownloadStatus from "$lib/components/DownloadStatus.svelte";
  import { downloadStatus } from "$lib/download-status";
  import { abortable } from "$lib/abortable";
  import VirtualRows from "$lib/components/VirtualRows.svelte";
  import MobileNewPlaylist from "$lib/components/MobileNewPlaylist.svelte";
  import MobileSettings from "$lib/components/MobileSettings.svelte";
  import MobilePalettes from "$lib/components/MobilePalettes.svelte";
  import MobileAux from "$lib/components/MobileAux.svelte";
  import MobilePlaylistMembership from "$lib/components/MobilePlaylistMembership.svelte";
  import { listDownloaded, downloadTrack as cacheDownload, downloadedTrackURL, removeDownload as deleteDownload } from "$lib/web-downloads";
  import AuxModal from "$lib/components/AuxModal.svelte";
  import BrowseGrid from "$lib/components/BrowseGrid.svelte";
  import PlayerBar from "$lib/components/PlayerBar.svelte";
  import MobileLibrary from "$lib/components/MobileLibrary.svelte";
  import MobilePlayer from "$lib/components/MobilePlayer.svelte";
  import ArtworkImage from "$lib/components/ArtworkImage.svelte";
  import { boundedVolume } from "$lib/volume-control";
  import MobileSheet from "$lib/components/MobileSheet.svelte";
  import MobileTabs from "$lib/components/MobileTabs.svelte";
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
  import SpectrumAppearance from "$lib/components/SpectrumAppearance.svelte";
  import { SpectroSampler } from "$lib/visualizer";
  import { mobileViewMotion } from "$lib/mobile-view-motion";
  import { readCachedLibrary, writeCachedLibrary } from "$lib/library-cache";
  import {
    artworkImportSummary,
    bundleImportSummary,
    syncTransferSummary,
    fingerprintFor,
    parseId3,
    type ImportManifestTrack
  } from "$lib/import";
  import { buildImportBundle } from "$lib/import-bundle";
  import PlaylistGrid from "$lib/components/PlaylistGrid.svelte";
  import { mediaErrorMessage } from "$lib/audio-errors";
  import { createPlaybackAudioSession } from "$lib/audio-session";
  import { playbackPositionChanged } from "$lib/playback-continuity";
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
    artistCovers,
    tracksForMobileCollection
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
    refreshSyncStreamToken,
    setSyncAuthToken,
    setTrackLiked,
    uploadPlaylistArtwork,
    uploadTrackArtwork,
    uploadTrackAudio,
    uploadTrackMetadata,
    createRemotePlaylist,
    addTrackToRemotePlaylist,
    removeTrackFromRemotePlaylist,
    renameRemotePlaylist,
    setRemotePlaylistTracks,
    resetPlaybackCommandQueue,
    libraryExportUrl,
    uploadBundle,
    fetchImportJob,
    type ImportJobStatus,
    sendPlaybackCommandV2,
    trackAudioUrl,
    updatePlaybackDevice,
    validateSyncServer
  } from "$lib/sync";
  import { shouldReconcileSync, syncEventStreamExpired, SYNC_PRESENCE_INTERVAL_MS } from "$lib/sync-refresh";
  import type {
    PlaybackCommandKindV2,
    PlaybackContextV2,
    PlaybackDevice,
    PlaybackEventV2,
    PlaybackStateV2
  } from "$lib/sync";
  import { DEFAULT_THEME, parseTheme, themes, type ThemeId, type ThemeOption } from "$lib/themes";
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
    ImportReport,
    SyncTransferReport,
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
  const PLAYBACK_DEVICE_POLL_MS = SYNC_PRESENCE_INTERVAL_MS;
  const DEFAULT_STATS: LibraryStats = {
    trackCount: 0,
    playlistCount: 0,
    likedCount: 0,
    artistCount: 0,
    albumCount: 0,
    durationSeconds: 0
  };

  type PlaybackSource = { url: string };

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  let library: MusicLibrary | null = null;
  let rootPath = "";
  let selectedView = "home";
  let mobileLayout = false;
  let queueRailVisible = false;
  let mobileTab = "home";
  let downloadedFingerprints = new Set<string>();
  let downloadingKeys = new Set<string>();
  let downloadScope = "";
  let downloadEpoch = 0;
  type DownloadRun = {
    server: string; token: string; controller: AbortController; tracks: Track[];
    fingerprints: Set<string>; next: number; saved: number; failure: string;
    progress: Map<string, number>;
  };
  let downloadRun: DownloadRun | null = null;
  let playlistHistory: Record<string, Record<string, number>> = {};
  let mobilePlaylistEditing = false;
  let addingSongs = false;
  let addSongQuery = "";
  let addingSongIDs = new Set<string>();
  let playlistWriteTail: Promise<void> = Promise.resolve();
  let pendingPlaylistWrites = 0;
  let playlistMutationEpoch = 0;
  let mobileSearchInput: HTMLInputElement;
  type MobileCollection = { title: string; artist?: string; kind: "album" | "artist" };
  let mobileCollection: MobileCollection | null = null;
  let contentEl: HTMLElement;
  const mobileTabStates = new Map<string, { view: string; query: string; sort: SortKey; collection: MobileCollection | null; scroll: number }>();
  const mobileRootScroll = new Map<string, number>();
  let newPlaylistOpen = false;
  let newPlaylistTitle = "";
  let newPlaylistTrack: Track | null = null;
  let creatingPlaylist = false;
  let createPlaylistError = "";
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
  let sourcePlaylistID: string | null = null;
  let playbackIndex = 0;
  let playHistory: Track[] = [];
  let isPlaying = false;
  let shuffle = false;
  let repeatMode: RepeatMode = "off";
  let volume = 0.86;
  let currentTime = 0;
  let audioDuration = 0;
  let theme: ThemeId = DEFAULT_THEME;
  let syncServerUrl = "";
  let syncServerDraft = "";
  let syncTokenDraft = "";
  let syncServerReady = false;
  let deviceId = "";
  let deviceName = "";
  let selectedPlaybackDeviceId = "";
  let playbackDevices: PlaybackDevice[] = [];
  let playbackStateV2: PlaybackStateV2 | null = null;
  let playbackClockOffsetMs = 0;
  let playbackPageVisible = true;
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
  let playbackEventActivityAt = 0;
  let syncReadGeneration = 0;
  let playbackRefresh: Promise<void> | null = null;
  let playbackReadController: AbortController | null = null;
  let playbackDeviceRefresh: Promise<void> | null = null;
  let playbackReconnect: Promise<void> | null = null;
  let lastPlaybackRefreshAt = 0;
  let lastLibraryRefreshAt = 0;
  let unlistenLibrary: (() => void) | null = null;
  // Media events are queued after play()/pause() return. Track our own
  // transitions so they cannot echo as headphone commands after sync finishes.
  let expectedAudioPlayEvents = 0;
  let expectedAudioPauseEvents = 0;
  let systemMediaTrackId = "";
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
  let playbackApplyGeneration = 0;
  let playbackConnectionGeneration = 0;
  let pendingPlaybackCommands = 0;
  let deferredPlaybackState: PlaybackStateV2 | null = null;
  let localPlaybackGeneration = 0;
  let remoteLibraryRefresh: Promise<void> | null = null;
  let remoteLibraryRefreshAgain = false;
  let lastRemoteLibrary: MusicLibrary | null = null;
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
  let activeTheme: ThemeOption = themes.find((option) => option.id === DEFAULT_THEME)!;
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
      selectedView === "library" ||
      selectedView === "search" ||
      selectedView === "playlists");
  $: userPlaylists = library?.playlists.filter((playlist) => !playlist.is_liked) ?? [];
  $: recentPlaylists = [...userPlaylists].sort((a,b) => (playlistHistory[syncServerUrl]?.[b.id] ?? 0) - (playlistHistory[syncServerUrl]?.[a.id] ?? 0));
  $: downloadedIDs = new Set((library?.tracks ?? []).filter(track => downloadedFingerprints.has(track.fingerprint)).map(track => track.id));
  $: downloadingIDs = new Set((library?.tracks ?? []).filter(track => downloadingKeys.has(downloadKey(syncServerUrl, track.fingerprint))).map(track => track.id));
  $: if (syncServerUrl !== downloadScope) { downloadScope = syncServerUrl; downloadedFingerprints = new Set(); void refreshDownloads(syncServerUrl); }
  $: if (downloadRun && (downloadRun.server !== syncServerUrl || downloadRun.token !== syncTokenDraft || guestMode)) {
    downloadRun.controller.abort();
    downloadStatus.set(null);
  }
  $: homeItems = homeRecentItems(library);
  $: mobileTrackIndex = new Map(library?.tracks.map((track) => [track.id, track]) ?? []);
  $: playlistArtwork = new Map((library?.playlists ?? []).map((playlist) => {
    const urls = new Set<string>();
    const albums = new Set<string>();
    for (const id of playlist.track_ids) {
      const track = mobileTrackIndex.get(id);
      const art = track?.artwork_url;
      if (!art || !track) continue;
      const identity = track.album ? `${track.album_artist || track.artist}\u0000${track.album}` : art;
      if (albums.has(identity)) continue;
      albums.add(identity);
      urls.add(art);
      if (urls.size === 4) break;
    }
    return [playlist.id, [...urls]] as const;
  }));
  $: homePlaylistCovers = new Map(
    userPlaylists.map((playlist) => {
      return [playlist.id, mobileTrackIndex.get(playlist.track_ids[0]) ?? null];
    })
  );
  $: playingPlaylist = currentTrack && sourcePlaylistID
    ? library?.playlists.find(playlist => playlist.id === sourcePlaylistID) ?? null : null;
  $: playingPlaylistCovers = playingPlaylist ? playlistArtwork.get(playingPlaylist.id) ?? [] : [];
  $: queue = playbackQueue(currentTrack, queuedTracks, playbackSource, playbackIndex);
  $: baseTracks = selectedView === "downloaded" ? (library?.tracks ?? []).filter(track => downloadedIDs.has(track.id)) : mobileCollection
    ? tracksForMobileCollection(library, mobileCollection)
    : selectedView === "search" && !searchActive ? [] : globalSearch
    ? (library?.tracks ?? [])
    : trackSourceForView(library, selectedView, selectedPlaylist, queue);
  $: visibleTracks = sortTracks(searchTracks(baseTracks, searchQuery), sortKey);
  $: stats = library?.stats ?? DEFAULT_STATS;
  $: artists = library?.artists ?? [];
  $: artistArt = artistCovers(library);
  $: albums = library?.albums ?? [];
  $: viewTitle = titleForView(selectedView, selectedPlaylist);
  $: mobileViewTitle = mobileCollection?.title ?? (selectedView === "all" ? "Songs" : selectedView === "downloaded" ? "Downloaded" : viewTitle);
  $: viewSubtitle = subtitleForView(library, selectedView, stats);
  $: listDurationSeconds = visibleTracks.reduce((sum, track) => sum + (track.duration_seconds ?? 0), 0);
  $: listMeta = metaForTrackList(selectedView, stats, visibleTracks, listDurationSeconds, queuedTracks);
  $: isEditingSelectedPlaylist = Boolean(
    selectedPlaylist && editingPlaylistId === selectedPlaylist.id
  );
  $: activeTheme = themes.find((option) => option.id === theme) ?? themes[0];
  $: if (typeof document !== "undefined") {
    document.documentElement.dataset.theme = theme;
    const background = getComputedStyle(document.documentElement).getPropertyValue("--color-bg").trim();
    document.querySelector('meta[name="theme-color"]')?.setAttribute("content", background);
  }
  $: playbackDeviceOptions = playbackDeviceChoices(playbackDevices, deviceId, deviceName, selectedPlaybackDeviceId);
  $: activePlaybackDeviceId =
    playbackStateV2?.active_device_id || selectedPlaybackDeviceId || deviceId;
  $: activePlaybackDeviceName =
    playbackDeviceOptions.find((device) => device.device_id === activePlaybackDeviceId)?.name ||
    deviceName ||
    "This device";
  $: updateSystemMediaSession(currentTrack, isPlaying, !syncServerReady ||
    (activePlaybackDeviceId === deviceId && (!selectedPlaybackDeviceId || selectedPlaybackDeviceId === deviceId)));
  $: if (audioEl) {
    // Web volume belongs to the device/browser. Do not retain invisible
    // attenuation from an old saved slider or another playback device.
    audioEl.volume = hasNativeBridge() ? boundedVolume(volume) : 1;
  }
  $: if (playbackSessionRestored) {
    void currentTrack;
    void queuedTracks;
    void playbackSource;
    void sourcePlaylistID;
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
    if (!("mediaSession" in navigator)) return;
    const actions: MediaSessionAction[] = ["play", "pause"];
    for (const action of actions) {
      try {
        navigator.mediaSession.setActionHandler(action, () => handleSystemPlayback(action === "play"));
      } catch { /* Some browsers implement only part of MediaSession. */ }
    }
    return () => {
      for (const action of actions) {
        try { navigator.mediaSession.setActionHandler(action, null); } catch { /* Unsupported action. */ }
      }
      navigator.mediaSession.playbackState = "none";
      navigator.mediaSession.metadata = null;
    };
  });

  onMount(() => {
    const query = window.matchMedia("(max-width: 980px)");
    const railQuery = window.matchMedia("(max-width: 1140px)");
    const update = () => { mobileLayout = query.matches; queueRailVisible = !railQuery.matches; };
    update();
    query.addEventListener("change", update);
    railQuery.addEventListener("change", update);
    return () => { query.removeEventListener("change", update); railQuery.removeEventListener("change", update); };
  });

  onMount(() => {
    // The version query makes every deploy a new service-worker URL, so
    // neither the browser nor a CDN can pin devices to a stale build.
    if ("serviceWorker" in navigator && !hasNativeBridge()) {
      navigator.serviceWorker
        .register(`/service-worker.js?v=${version}`, { updateViaCache: "none" })
        .catch(() => undefined);
    }

    theme = parseTheme(readStoredValue(THEME_STORAGE_KEY));
    const auxParam = new URLSearchParams(window.location.search).get("aux");
    if (auxParam && !hasNativeBridge()) {
      void joinAuxAsGuest(auxParam);
      return;
    }

    try { const saved = JSON.parse(localStorage.getItem("codec.playlistHistory") ?? "{}"); if (saved && typeof saved === "object" && !Array.isArray(saved)) playlistHistory = saved; } catch { /* Fresh recency state. */ }
    rootPath = readStoredValue(ROOT_STORAGE_KEY) ?? "";
    volume = boundedVolume(readStoredValue(VOLUME_STORAGE_KEY) ?? volume);
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
    // A first visit is a connect form, not a failed anonymous login. Saved
    // connections (including servers without auth) still reconnect at once.
    const hasSavedConnection = Boolean(readStoredValue(SYNC_SERVER_STORAGE_KEY) || syncTokenDraft || rootPath);

    if (rootPath && hasNativeBridge() && !isRemoteRoot(rootPath)) {
      void loadLibrary(rootPath, true);
    } else if (hasSavedConnection && syncServerUrl && (!hasNativeBridge() || rootPath === REMOTE_ROOT_PATH)) {
      // Hydrate from the local cache immediately while the network load
      // runs; whichever lands first paints, the network result wins.
      bootstrapping = true;
      void hydrateLibraryFromCache(syncServerUrl);
      void loadRemoteLibrary(true);
    }

    if (hasSavedConnection && syncServerUrl && rootPath !== REMOTE_ROOT_PATH) {
      void validatePlaybackSyncServer(true);
    }

    if (hasSavedConnection && syncServerUrl) {
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
        if (mobileLayout) {
          selectMobileTab("search");
          void tick().then(() => mobileSearchInput?.focus());
        } else topBar?.focusSearch();
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

      if (isTyping || event.defaultPrevented || target?.closest("button, select, dialog, [role='dialog']")) {
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
    playbackPageVisible = document.visibilityState !== "hidden";
    const persistWhenHidden = () => {
      playbackPageVisible = document.visibilityState !== "hidden";
      if (!playbackPageVisible) {
        savePlaybackSessionNow();
      } else {
        refreshPlaybackSyncOnForeground();
      }
    };

    window.addEventListener("pagehide", persistPlayback);
    window.addEventListener("beforeunload", persistPlayback);
    window.addEventListener("pageshow", refreshPlaybackSyncOnForeground);
    window.addEventListener("online", refreshPlaybackSyncOnForeground);
    document.addEventListener("visibilitychange", persistWhenHidden);

    return () => {
      savePlaybackSessionNow();
      downloadRun?.controller.abort();
      downloadStatus.set(null);
      document.removeEventListener("keydown", keyHandler);
      window.removeEventListener("pagehide", persistPlayback);
      window.removeEventListener("beforeunload", persistPlayback);
      window.removeEventListener("pageshow", refreshPlaybackSyncOnForeground);
      window.removeEventListener("online", refreshPlaybackSyncOnForeground);
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
      visualizerSampler?.stop();
      void audioGraphContext?.close().catch(() => undefined);
      playbackAudioSession.release();
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
      errorMessage = "Open the Codec desktop app to import a music bundle.";
      return;
    }

    if (!rootPath) {
      errorMessage = "Choose a music folder before importing a music bundle.";
      return;
    }

    const selected = await open({
      directory: false,
      multiple: false,
      title: "Choose loud-import.json or codec-import.json",
      filters: [{ name: "Codec music bundle manifest", extensions: ["json"] }]
    });

    if (typeof selected !== "string") {
      return;
    }

    importing = true;
    try {
      const report = await invoke<ImportReport>("import_library_manifest", {
        root_path: rootPath,
        manifest_path: selected
      });
      await loadLibrary(rootPath, true);
      const bits = [`${report.new_tracks} new`, `${report.existing_tracks} existing`];
      if (report.playlist_updates) bits.push(`${report.playlist_updates} playlist updates`);
      if (report.liked_updates) bits.push(`${report.liked_updates} liked`);
      if (report.skipped_tracks) bits.push(`${report.skipped_tracks} tracks skipped`);
      bits.push(...artworkImportSummary(report));
      syncMessage = `Import · ${bits.join(" · ")}`;
      const diagnostics = [...(report.failures ?? []), ...(report.artwork_failures ?? [])];
      if (diagnostics.length) errorMessage = diagnostics.slice(0, 3).map((item) => `${item.file}: ${item.reason}`).join(" · ");
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
      if (serverUrl !== syncServerUrl) return;
      lastRemoteLibrary = nextLibrary;
      lastLibraryRefreshAt = Date.now();
      syncServerReady = true;
      rootPath = nextLibrary.root_path || REMOTE_ROOT_PATH;
      writeStoredValue(ROOT_STORAGE_KEY, rootPath);
      syncLibrary(nextLibrary);
      void writeCachedLibrary(nextLibrary);
      startPlaybackDevicePolling();
      void restoreRemotePlaybackSession(nextLibrary);
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

  async function refreshRemoteLibraryState(forceApply = false, invalidated = true) {
    if (!usePlaybackSync() || !isRemoteRoot(rootPath) || pendingPlaylistWrites > 0) return;
    // Mutations may have optimistically changed or rolled back the UI while
    // an SSE refresh cached this same server snapshot. Reapply it on demand.
    if (forceApply) lastRemoteLibrary = null;
    if (remoteLibraryRefresh) {
      // A mutation/event during a read requires one more snapshot. Routine
      // foreground/poll reads can share the request already in flight.
      remoteLibraryRefreshAgain ||= invalidated;
      return remoteLibraryRefresh.catch(() => undefined);
    }
    const server = syncServerUrl;
    const token = syncTokenDraft;
    const generation = syncReadGeneration;
    const request = (async () => {
      await refreshSyncStreamToken(server);
      if (generation !== syncReadGeneration || server !== syncServerUrl || token !== syncTokenDraft) return;
      do {
        remoteLibraryRefreshAgain = false;
        const playlistEpoch = playlistMutationEpoch;
        const nextLibrary = await fetchRemoteLibrary(server);
        if (generation !== syncReadGeneration || server !== syncServerUrl || token !== syncTokenDraft) return;
        if (pendingPlaylistWrites > 0) return;
        if (playlistEpoch !== playlistMutationEpoch) { remoteLibraryRefreshAgain = true; continue; }
        lastLibraryRefreshAt = Date.now();
        if (nextLibrary !== lastRemoteLibrary) {
          lastRemoteLibrary = nextLibrary;
          syncLibrary(nextLibrary);
          void writeCachedLibrary(nextLibrary);
        }
      } while (remoteLibraryRefreshAgain);
    })();
    remoteLibraryRefresh = request;
    try {
      await request;
    } catch {
      // Keep the cached library readable; reconnect and the next poll retry.
      if (generation === syncReadGeneration && server === syncServerUrl && token === syncTokenDraft) {
        lastLibraryRefreshAt = 0;
      }
    } finally {
      if (remoteLibraryRefresh === request) remoteLibraryRefresh = null;
    }
  }

  function syncLibrary(nextLibrary: MusicLibrary) {
    const previousCurrent = currentTrack;
    nextLibrary = normalizeLibrary(nextLibrary, syncServerUrl);
    library = nextLibrary;

    // If shared playback state landed before the library did, its staleness
    // check couldn't see track durations — re-apply now that it can.
    if (playbackStateV2) {
      playbackSessionRestored = true;
      void applyPlaybackStateV2(playbackStateV2, true);
      return;
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
    sourcePlaylistID = typeof session.playlist_id === "string" ? session.playlist_id.trim() || null : null;
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
    if (!syncServerUrl || playbackStateV2) {
      return;
    }

    const server = syncServerUrl;
    const generation = syncReadGeneration;
    try {
      const remote = await fetchLatestPlaybackSession<PersistedPlaybackSession>(server);
      // This is a legacy fallback. Live state can arrive over SSE while the
      // saved session is loading; never replace that state with an old pause.
      if (playbackStateV2 || generation !== syncReadGeneration || server !== syncServerUrl || !remote || !validPlaybackSession(remote.session)) {
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
      playlist_id: sourcePlaylistID,
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
    // The element can retain an old song/position after transferring audio to
    // native. Remote pause/resume must use the owner's clock, not that buffer.
    if (usePlaybackSync() && playbackStateV2?.active_device_id && playbackStateV2.active_device_id !== deviceId) {
      return clampPlaybackTime(currentSyncedPlaybackPosition(), currentTrack);
    }
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
      sourcePlaylistID = null;
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
    if (!serverUrl || !library || !hasNativeBridge() || isRemoteRoot(rootPath)) {
      errorMessage = "Choose a local music folder in the desktop app to merge it into your server.";
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
        syncMessage = syncTransferSummary("Merged", report);
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
        syncMessage = syncTransferSummary("Downloaded", report);
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
    sourcePlaylistID = null;
    playbackApplyGeneration++;
    localPlaybackGeneration++;
    playbackConnectionGeneration++;
    pendingPlaybackCommands = 0;
    deferredPlaybackState = null;
    applyingRemotePlayback = false;
    lastRemoteLibrary = null;
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
      .then((state) => applyPlaybackStateV2(state))
      .catch((error) => {
        errorMessage = error instanceof Error ? error.message : String(error);
      });
  }

  function startPlaybackDevicePolling() {
    if (!syncServerUrl || !syncServerReady || playbackDevicePollTimer) {
      if (syncServerUrl && syncServerReady) {
        void startPlaybackEvents().catch(() => undefined);
      }
      return;
    }

    void publishPlaybackDeviceState(true);
    void refreshPlaybackDevices();
    void startPlaybackEvents().catch(() => undefined);
    playbackDevicePollTimer = window.setInterval(() => {
      void publishPlaybackDeviceState(true);
      const now = Date.now();
      const streamOpen = playbackEventSource?.readyState === 1 && !syncEventStreamExpired(playbackEventActivityAt, now);
      if (shouldReconcileSync(streamOpen, lastPlaybackRefreshAt, now)) void refreshPlaybackDevices();
      if (shouldReconcileSync(streamOpen, lastLibraryRefreshAt, now)) void refreshRemoteLibraryState(false, false);
      void startPlaybackEvents().catch(() => undefined);
    }, PLAYBACK_DEVICE_POLL_MS);
  }

  function refreshPlaybackSyncOnForeground() {
    if (!syncServerReady) {
      resumeLocalAudioGraphAfterForeground();
      // An offline launch never reaches the polling loop. Returning online
      // must reconnect the saved server before ordinary state reads can run.
      if (!syncServerUrl || !deviceId || loading || bootstrapping || playbackReconnect ||
          !(readStoredValue(SYNC_SERVER_STORAGE_KEY) || syncTokenDraft || rootPath)) return;
      const reconnect = hasNativeBridge() && !isRemoteRoot(rootPath)
        ? validatePlaybackSyncServer(true) : loadRemoteLibrary(true);
      const pending = reconnect.finally(() => {
        if (playbackReconnect === pending) playbackReconnect = null;
      });
      playbackReconnect = pending;
      return;
    }
    // Mobile browsers suspend sockets while backgrounded. Reconcile even an
    // unchanged revision and reopen SSE so buffered events cannot leave the
    // remote timeline behind after switching from the native player.
    // Applying a current local playback state also recovers its audio graph.
    // A cancelled/failed read must not resume from stale ownership here.
    void refreshPlaybackDevices(true);
    void publishPlaybackDeviceState(true);
    void refreshRemoteLibraryState(false, false);
    void startPlaybackEvents(true).catch(() => undefined);
  }

  function stopPlaybackDevicePolling() {
    syncReadGeneration++;
    resetPlaybackCommandQueue();
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
    playbackEventActivityAt = 0;
    playbackReadController?.abort();
    playbackReadController = null;
    playbackRefresh = null;
    playbackDeviceRefresh = null;
    remoteLibraryRefresh = null;
    remoteLibraryRefreshAgain = false;
    lastPlaybackRefreshAt = 0;
    lastLibraryRefreshAt = 0;
  }

  async function startPlaybackEvents(forceReconnect = false) {
    if (!syncServerUrl || !syncServerReady || typeof EventSource === "undefined") {
      return;
    }

    const server = syncServerUrl;
    const token = syncTokenDraft;
    const generation = syncReadGeneration;
    if (playbackEventSource && (forceReconnect || playbackEventSource.readyState === 2 || syncEventStreamExpired(playbackEventActivityAt, Date.now()))) {
      // An OPEN socket can silently stop delivering. A connection that never
      // received headers can also stall without an error callback.
      playbackEventSource.close();
      playbackEventSource = null;
      playbackEventSourceUrl = "";
    }
    await refreshSyncStreamToken(server);
    if (generation !== syncReadGeneration || server !== syncServerUrl || token !== syncTokenDraft || !syncServerReady) return;
    const nextUrl = playbackEventsV2Url(server);
    if (playbackEventSource && playbackEventSourceUrl === nextUrl) {
      return;
    }

    playbackEventSource?.close();
    playbackEventSourceUrl = nextUrl;
    const source = new EventSource(nextUrl);
    playbackEventSource = source;
    playbackEventActivityAt = Date.now();
    const stillConnected = () => playbackEventSource === source && server === syncServerUrl && token === syncTokenDraft;
    const handleCurrentEvent = (event: MessageEvent<string>) => {
      if (!stillConnected()) return;
      playbackEventActivityAt = Date.now();
      handlePlaybackEvent(event);
    };
    source.addEventListener("devices", handleCurrentEvent);
    source.addEventListener("device", handleCurrentEvent);
    source.addEventListener("playback_state", handleCurrentEvent);
    source.addEventListener("library", handleCurrentEvent);
    source.onopen = () => {
      if (!stillConnected()) return;
      playbackEventActivityAt = Date.now();
      // Reconcile missed changes on every reconnect, independent of cadence.
      void refreshPlaybackDevices();
      void refreshRemoteLibraryState();
    };
    source.onerror = () => {
      if (!stillConnected()) return;
      void refreshPlaybackDevices();
    };
  }

  function handlePlaybackEvent(event: MessageEvent<string>) {
    try {
      const payload = JSON.parse(event.data) as PlaybackEventV2;
      if (payload.type === "library") void refreshRemoteLibraryState();
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
    const previous = byId.get(nextDevice.device_id);
    if (!previous || nextDevice.updated_at >= previous.updated_at) byId.set(nextDevice.device_id, nextDevice);
    const sorted = [...byId.values()].sort((a, b) => b.updated_at - a.updated_at);
    // Presence events use server timestamps. Expire offline devices without
    // another GET, matching the server TTL even when the client clock differs.
    const cutoff = (sorted[0]?.updated_at ?? 0) - 2 * 60_000;
    return sorted.filter((device) => device.updated_at >= cutoff);
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

  async function refreshPlaybackDeviceList() {
    if (!syncServerUrl || !syncServerReady) return;
    if (playbackDeviceRefresh) return playbackDeviceRefresh;
    const server = syncServerUrl;
    const token = syncTokenDraft;
    const generation = syncReadGeneration;
    const request = (async () => {
      try {
        const devices = await fetchPlaybackDevices(server);
        if (generation === syncReadGeneration && server === syncServerUrl && token === syncTokenDraft && syncServerReady) {
          playbackDevices = devices;
        }
      } catch {
        // Discovery is advisory. A slow/offline presence endpoint must never
        // delay the current song, timeline or transport ownership.
      }
    })();
    playbackDeviceRefresh = request;
    try { await request; }
    finally { if (playbackDeviceRefresh === request) playbackDeviceRefresh = null; }
  }

  async function refreshPlaybackDevices(force = false) {
    if (!syncServerUrl || !syncServerReady) return;
    if (playbackRefresh) {
      if (!force) return playbackRefresh;
      // A fetch started before suspension can retain a dead connection.
      // Foreground/command recovery needs a new request, not a place in line.
      playbackReadController?.abort();
    }

    const serverUrl = syncServerUrl;
    const token = syncTokenDraft;
    const generation = syncReadGeneration;
    const controller = new AbortController();
    playbackReadController = controller;
    const current = () => !controller.signal.aborted && playbackReadController === controller &&
      generation === syncReadGeneration && serverUrl === syncServerUrl && token === syncTokenDraft && syncServerReady;
    const request = (async () => {
      try {
        void refreshPlaybackDeviceList();
        const state = await fetchPlaybackStateV2(serverUrl, undefined, controller.signal);
        if (!current()) return;
        if (state) {
          await applyPlaybackStateV2(state, force);
          if (!current()) return;
        } else {
          playbackStateV2 = null;
          stopPlaybackClock();
        }
        lastPlaybackRefreshAt = Date.now();
      } catch {
        // Superseding a stale read is expected. Its cancellation must not
        // erase the new connection's freshness or surface an offline error.
        if (current()) lastPlaybackRefreshAt = 0;
      }
    })();
    playbackRefresh = request;
    try { await request; }
    finally {
      if (playbackRefresh === request) playbackRefresh = null;
      if (playbackReadController === controller) playbackReadController = null;
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
    currentDeviceName: string,
    selectedDeviceId: string
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
    if (selectedDeviceId && !byId.has(selectedDeviceId)) {
      byId.set(selectedDeviceId, {
        ...playbackDeviceState(),
        device_id: selectedDeviceId,
        name: "Other device"
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
      await applyPlaybackStateV2(state);
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
      await applyPlaybackStateV2(state);
      schedulePlaybackDeviceUpdate(true);
    } catch {
      // Local controls should remain responsive if device sync drops.
    }
  }

  async function applyPlaybackStateV2(nextState: PlaybackStateV2, force = false) {
    if (pendingPlaybackCommands > 0) {
      if (!deferredPlaybackState || nextState.revision > deferredPlaybackState.revision) deferredPlaybackState = nextState;
      return;
    }
    if (playbackStateV2 && (nextState.revision < playbackStateV2.revision || (!force && nextState.revision === playbackStateV2.revision))) {
      return;
    }

    const previousState = playbackStateV2;
    const generation = ++playbackApplyGeneration;
    localPlaybackGeneration++;
    if (!playbackStateV2 || nextState.server_time_ms !== playbackStateV2.server_time_ms) {
      // Transport events can wait in Safari's suspended socket or behind a
      // pending command. That delay is not a change in the server clock.
      const offsetSample = nextState.server_time_ms - Date.now();
      playbackClockOffsetMs = playbackStateV2 ? Math.max(playbackClockOffsetMs, offsetSample) : offsetSample;
    }
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
      trackDuration <= 0 && clockTouchedMs > 0 && nextState.server_time_ms - clockTouchedMs > 30 * 60 * 1000;
    // Presence expires after two minutes and may be absent while iOS keeps
    // audio playing in the background. It is discovery data, not ownership.
    // Only the shared playback clock can identify an abandoned session.
    // Never call it stale while OUR audio element is audibly playing — a
    // long local listening session only refreshes the clock on track
    // changes, and the element is the truth here.
    const locallyAudible =
      nextState.active_device_id === deviceId && Boolean(audioEl) && !audioEl!.paused;
    const stalePlayback =
      nextState.state === "playing" &&
      (positionOverrun || clockAbandoned) &&
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
    currentTrack = targetTrack;
    if (stalePlayback) {
      stopPlaybackClock();
    } else {
      updatePlaybackClock();
    }

    if (targetTrack) {
      audioDuration = targetTrack.duration_seconds || audioDuration;
    } else if (nextState.track) {
      void refreshRemoteLibraryState();
    }

    applyingRemotePlayback = true;
    try {
      if (nextState.active_device_id === deviceId && targetTrack && !stalePlayback) {
        await syncLocalAudioToPlaybackState(nextState, targetTrack, generation, previousState);
      } else {
        pauseLocalAudio();
        // Even silent Web Audio can keep a browser audio session active.
        // Release it when native owns playback; opening the remote visualizer
        // must not compete with the phone app for audio focus.
        if (audioGraphContext?.state === "running") {
          const context = audioGraphContext;
          void context.suspend().then(() => {
            // A quick transfer back may have started local audio while the
            // asynchronous suspension was finishing. Do not leave it silent.
            if (context !== audioGraphContext) return;
            if (canControlLocalMedia() && audioEl && !audioEl.paused) {
              if (!playbackAudioSession.isInterrupted()) {
                playbackAudioSession.begin();
                return context.resume();
              }
              return;
            }
            playbackAudioSession.release();
          }).catch(() => undefined);
        } else {
          playbackAudioSession.release();
        }
      }
    } finally {
      if (generation === playbackApplyGeneration) applyingRemotePlayback = false;
    }

    if (generation === playbackApplyGeneration) schedulePlaybackDeviceUpdate(true);
  }

  function selectedPlaybackTargetDeviceId(): string {
    const candidate = selectedPlaybackDeviceId || playbackStateV2?.active_device_id || deviceId;
    if (candidate === deviceId) {
      return deviceId;
    }
    // A backgrounded native player can outlive its presence entry. Keep its
    // authoritative target; only an explicit transfer should take the audio.
    if (playbackStateV2?.active_device_id === candidate) return candidate;
    // A saved selection unrelated to the current session can still expire.
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

    const server = syncServerUrl;
    const sender = deviceId;
    const generation = playbackConnectionGeneration;
    playbackApplyGeneration++;
    localPlaybackGeneration++;
    applyingRemotePlayback = false;
    // Later actions must build on this command's context even when another
    // device is playing and its acknowledgement has not arrived yet.
    if (overrides.context) applyPlaybackContextV2({ context: overrides.context });
    pendingPlaybackCommands++;
    let failed = false;
    try {
      const state = await sendPlaybackCommandV2(server, {
        command_id: createPlaybackCommandId(kind),
        expectedRevision: overrides.context ? playbackStateV2?.revision : undefined,
        kind,
        device_id: sender,
        target_device_id: selectedPlaybackTargetDeviceId(),
        ...(kind === "volume" ? { volume } : {}),
        ...overrides
      });
      if (generation !== playbackConnectionGeneration || server !== syncServerUrl || sender !== deviceId || !syncServerReady) {
        throw new Error("The playback connection changed.");
      }
      return state;
    } catch (error) {
      failed = true;
      throw error;
    } finally {
      if (generation === playbackConnectionGeneration) {
        pendingPlaybackCommands--;
        if (pendingPlaybackCommands === 0 && deferredPlaybackState) {
          const latest = deferredPlaybackState;
          deferredPlaybackState = null;
          void applyPlaybackStateV2(latest);
        }
        if (failed && pendingPlaybackCommands === 0) void refreshPlaybackDevices(true);
      }
    }
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
    repeat = repeatMode,
    playlistID = sourcePlaylistID
  ): PlaybackContextV2 {
    return {
      playlist_id: playlistID,
      playback_source: sourceTracks.map(trackReference),
      playback_index: Math.max(0, Math.min(sourceIndex, Math.max(sourceTracks.length - 1, 0))),
      queued_tracks: queued.map(trackReference),
      play_history: history.map(trackReference),
      shuffle: shuffled,
      repeat
    };
  }

  function applyPlaybackContextV2(state: Pick<PlaybackStateV2, "context">) {
    sourcePlaylistID = typeof state.context.playlist_id === "string" ? state.context.playlist_id.trim() || null : null;
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

  async function syncLocalAudioToPlaybackState(state: PlaybackStateV2, track: Track, generation: number, previousState: PlaybackStateV2 | null) {
    if (!audioEl) {
      return;
    }

    const position = clampPlaybackTime(currentSyncedPlaybackPosition(), track);
    // Reconciliation must keep the active media resource stable. A download may
    // finish (or be removed) while this song plays; switch sources on the next
    // intentional start, never during a routine sync update.
    const source = loadedTrackId === track.id && loadedSource && !audioEl.error
      ? loadedSource : await playbackUrlForTrack(track);
    if (generation !== playbackApplyGeneration) return;
    if (audioSourceIdentity(loadedSource) !== audioSourceIdentity(source) || audioEl.error) {
      loadAudioSource(source, position, track.id);
      await waitForAudioMetadata();
    } else if (
      (playbackPositionChanged(previousState, state) || previousState?.state !== state.state) &&
      Math.abs((audioEl.currentTime || 0) - position) > 0.05
    ) {
      audioEl.currentTime = position;
      currentTime = position;
    }

    if (generation !== playbackApplyGeneration) return;
    if (state.state === "playing") {
      try {
        if (audioEl.paused) await playLocalAudio();
        if (generation !== playbackApplyGeneration) return;
        isPlaying = true;
        resumeLocalAudioGraphAfterForeground();
      } catch (error) {
        if (generation !== playbackApplyGeneration) return;
        // A browser's autoplay refusal is local, not a transport command.
        // Publishing a pause here can race a native transfer and stop the
        // phone's audio. Keep the shared state intact; a tap can resume here.
        isPlaying = false;
        console.warn("Playback needs a tap on this device", error);
      }
    } else {
      if (!audioEl.paused) pauseLocalAudio();
      isPlaying = false;
    }
    // The active speaker's progress follows its audio, including buffering;
    // routine sync must not make the progress thumb jump to a different clock.
    currentTime = audioEl.currentTime || 0;
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

  function selectedSourcePlaylistID(): string | null {
    if (globalSearch || mobileCollection) return null;
    return selectedPlaylist?.id ?? (selectedView === "liked"
      ? library?.playlists.find(playlist => playlist.is_liked)?.id ?? null : null);
  }

  async function playTrack(track: Track, sourceTracks = visibleTracks, shuffled = shuffle, playlistID: string | null = null) {
    if (usePlaybackSync()) {
      const nextSource = createQueue(sourceTracks, track.id, shuffled);
      const nextTrack = nextSource[0] ?? track;
      try {
        const local = selectedPlaybackTargetDeviceId() === deviceId;
        if (local) {
          playbackSource = nextSource;
          sourcePlaylistID = playlistID;
          playbackIndex = 0;
          playHistory = [];
          queuedTracks = [];
          currentTrack = nextTrack;
          currentTime = 0;
          isPlaying = true;
        }
        const [state] = await Promise.all([
          sendPlaybackCommand("play", {
            track: trackReference(nextTrack),
            context: playbackContextSnapshot(nextSource, 0, [], [], shuffled, repeatMode, playlistID),
            position_seconds: 0
          }),
          local ? startPlayback() : Promise.resolve()
        ]);
        await applyPlaybackStateV2(state);
      } catch (error) {
        errorMessage = error instanceof Error ? error.message : String(error);
      }
      return;
    }

    playbackSource = createQueue(sourceTracks, track.id, shuffled);
    sourcePlaylistID = playlistID;
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

    recordPlaylistPlay();
    await playTrack(track, visibleTracks, shuffle, selectedSourcePlaylistID());
  }

  async function playTrackSet(sourceTracks: Track[], shuffled = false, playlistID = selectedSourcePlaylistID()) {
    if (sourceTracks.length) recordPlaylistPlay();
    const nextSource = shuffled ? shuffleTracks(sourceTracks) : [...sourceTracks];
    const firstTrack = nextSource[0];

    if (!firstTrack) {
      return;
    }

    if (usePlaybackSync()) {
      try {
        const local = selectedPlaybackTargetDeviceId() === deviceId;
        if (local) {
          playbackSource = nextSource;
          sourcePlaylistID = playlistID;
          playbackIndex = 0;
          playHistory = [];
          queuedTracks = [];
          currentTrack = firstTrack;
          currentTime = 0;
          isPlaying = true;
        }
        const [state] = await Promise.all([
          sendPlaybackCommand("play", {
            track: trackReference(firstTrack),
            context: playbackContextSnapshot(nextSource, 0, [], [], shuffled, repeatMode, playlistID),
            position_seconds: 0
          }),
          local ? startPlayback() : Promise.resolve()
        ]);
        await applyPlaybackStateV2(state);
      } catch (error) {
        errorMessage = error instanceof Error ? error.message : String(error);
      }
      return;
    }

    playbackSource = nextSource;
    sourcePlaylistID = playlistID;
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
  const playbackAudioSession = createPlaybackAudioSession();

  function resumeLocalAudioGraphAfterForeground() {
    if (document.hidden || !isPlaying || !audioEl || audioEl.paused ||
        !canControlLocalMedia() || playbackAudioSession.isInterrupted() ||
        !audioGraphContext || audioGraphContext.state === "running" || audioGraphContext.state === "closed") return;
    playbackAudioSession.begin();
    // Resume the existing graph only. Never restart the element or seek on
    // foreground, and never override a real pause or another app's audio.
    void audioGraphContext.resume().catch(() => undefined);
  }

  // Retain the ring buffer between views and pauses. Hidden/remote clients
  // have no useful samples; stopping these frames must never stop local audio.
  $: if (visualizerSampler) {
    if (isPlaying && playbackPageVisible && (!syncServerReady || !playbackStateV2?.active_device_id || playbackStateV2.active_device_id === deviceId)) visualizerSampler.start();
    else visualizerSampler.stop();
  }

  function ensureAnalyser(): AnalyserNode | null {
    if (!audioEl || audioEl.paused || (usePlaybackSync() && !isActiveSyncDevice())) {
      return null;
    }

    if (!audioGraphContext) {
      try {
        playbackAudioSession.begin();
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

    playbackAudioSession.begin();
    void audioGraphContext.resume().catch(() => undefined);
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

  function publishQueueChange() {
    if (!usePlaybackSync()) return;
    void sendPlaybackCommand("set_queue", { context: playbackContextSnapshot() })
      .then((state) => applyPlaybackStateV2(state))
      .catch((error) => { errorMessage = error instanceof Error ? error.message : String(error); });
  }

  function clearQueuedTracks() {
    queuedTracks = [];
    publishQueueChange();
  }

  function removeQueuedTrackAt(queueIndex: number) {
    const manualIndex = queueIndex - 1;
    if (manualIndex < 0 || manualIndex >= queuedTracks.length) {
      return;
    }

    queuedTracks = queuedTracks.filter((_, index) => index !== manualIndex);
    publishQueueChange();
  }

  function queueTrackLast(track: Track) {
    queuedTracks = [...queuedTracks, track];
    publishQueueChange();
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
    publishQueueChange();
  }

  async function togglePlayback() {
    if (usePlaybackSync()) {
      const targetDeviceId = selectedPlaybackTargetDeviceId();
      const targetIsPlaying = isPlaying;
      const actingLocally = targetDeviceId === deviceId && Boolean(currentTrack) && Boolean(loadedSource);

      if (targetIsPlaying) {
        isPlaying = false;
        if (actingLocally) {
          pauseLocalAudio();
          isPlaying = false;
        }
        void sendPlaybackCommand("pause", {
          target_device_id: targetDeviceId,
          position_seconds: currentPlaybackTimeForSave()
        })
          .then((state) => applyPlaybackStateV2(state))
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
          context = playbackContextSnapshot(source, 0, [], [], shuffle, repeatMode, selectedSourcePlaylistID());
        }
      }
      if (!track) {
        return;
      }

      // Optimistic local play only when the element actually holds THIS
      // track — otherwise a session-restored source would play a different
      // song than the UI shows; the command round-trip loads the right one.
      if (actingLocally && currentTrack?.id === track.id && loadedTrackId === track.id) {
        void playLocalAudio().catch(() => undefined);
        isPlaying = true;
      }
      isPlaying = true;
      void sendPlaybackCommand("play", {
        target_device_id: targetDeviceId,
        track: playbackStateV2?.track?.fingerprint === track.fingerprint ? undefined : trackReference(track),
        context: playbackStateV2?.track?.fingerprint === track.fingerprint ? undefined : context,
        position_seconds: currentTrack?.id === track.id ? currentPlaybackTimeForSave() : 0
      })
        .then((state) => applyPlaybackStateV2(state))
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
        await playTrack(firstTrack, visibleTracks.length ? visibleTracks : library?.tracks ?? [], shuffle, selectedSourcePlaylistID());
      }
      return;
    }

    if (isPlaying) {
      pauseLocalAudio();
      isPlaying = false;
      return;
    }

    await startPlayback();
  }

  async function startPlayback() {
    const generation = ++localPlaybackGeneration;
    await tick();
    if (generation !== localPlaybackGeneration) return;

    if (!audioEl || !currentTrack || !rootPath) {
      isPlaying = false;
      errorMessage = "Local playback needs the Tauri app and a selected music folder.";
      return;
    }

    try {
      const source = await playbackUrlForTrack(currentTrack);
      if (generation !== localPlaybackGeneration) return;
      if (audioSourceIdentity(loadedSource) !== audioSourceIdentity(source) || audioEl.error) {
        loadAudioSource(source, currentTime, currentTrack.id);
        await waitForAudioMetadata();
      } else if (Math.abs((audioEl.currentTime || 0) - currentTime) > 1.5) {
        audioEl.currentTime = currentTime;
      }

      if (generation !== localPlaybackGeneration) return;
      applyPendingSeek();
      await playLocalAudio();
      if (generation !== localPlaybackGeneration) return;
      isPlaying = !audioEl.paused;
      errorMessage = "";
    } catch (error) {
      if (generation !== localPlaybackGeneration) return;
      isPlaying = false;
      errorMessage = mediaErrorMessage(error, audioEl?.error ?? null);
    }
  }

  async function playbackUrlForTrack(track: Track): Promise<string> {
    if (!hasNativeBridge() && syncServerUrl) {
      const local = await downloadedTrackURL(syncServerUrl, track.fingerprint).catch(() => null);
      if (local) return local;
    }
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

  function audioSourceIdentity(source: string): string {
    if (!source) return "";
    const url = new URL(source);
    url.searchParams.delete("access_token");
    return url.toString();
  }

  function loadAudioSource(source: string, seekTime = 0, trackId = "") {
    audioEl.src = source;
    pendingSeekTime = seekTime > 0 ? seekTime : null;
    audioEl.load();
    // load() discards pending media tasks and resets paused without emitting
    // a pause event. Expectations belong only to the previous resource.
    expectedAudioPlayEvents = 0;
    expectedAudioPauseEvents = 0;
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
        await applyPlaybackStateV2(state);
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
        await applyPlaybackStateV2(state);
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
        await applyPlaybackStateV2(state);
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
          .then((state) => applyPlaybackStateV2(state))
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
        const connectionGeneration = syncReadGeneration;
        const repeatedTrackId = currentTrack?.id;
        currentTime = 0;
        audioEl.currentTime = 0;
        await startPlayback();
        if (connectionGeneration !== syncReadGeneration || playbackStateV2?.active_device_id !== deviceId ||
            currentTrack?.id !== repeatedTrackId) return;
        playbackClockSuppressUntil = Date.now() + 1500;
        void sendPlaybackCommand("seek", { target_device_id: deviceId, position_seconds: 0 })
          .then((state) => applyPlaybackStateV2(state))
          .catch(() => undefined);
        return;
      }

      const beforeTrackId = currentTrack?.id ?? null;
      const connectionGeneration = syncReadGeneration;
      await localNextTrack();
      if (connectionGeneration !== syncReadGeneration || playbackStateV2?.active_device_id !== deviceId) return;
      notifyServerAfterLocalChange(beforeTrackId, "next");
      return;
    }

    if (repeatMode === "one") {
      currentTime = 0;
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
          : createQueue(sortTracks(playbackSource, "added"), currentTrack.id, false);
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
        .then((state) => applyPlaybackStateV2(state))
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

    // Changing pages must not replace the active playlist when shuffle ends.
    playbackSource = createQueue(sortTracks(playbackSource, "added"), currentTrack.id, false);
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
        .then((state) => applyPlaybackStateV2(state))
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
        .then((state) => applyPlaybackStateV2(state))
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

  function syncMediaVolume() {
    if (!audioEl || !hasNativeBridge() || !isActiveSyncDevice()) return;
    volume = boundedVolume(audioEl.volume);
    writeStoredValue(VOLUME_STORAGE_KEY, String(volume));
  }

  async function updateVolume(event: Event) {
    if (!hasNativeBridge()) return;
    volume = boundedVolume((event.currentTarget as HTMLInputElement).value);
    writeStoredValue(VOLUME_STORAGE_KEY, String(volume));

    if (usePlaybackSync()) {
      try {
        const state = await sendPlaybackCommand("volume", {
          volume,
          position_seconds: currentSyncedPlaybackPosition()
        });
        await applyPlaybackStateV2(state);
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
        .then((state) => applyPlaybackStateV2(state))
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
    if (usePlaybackSync() && !isActiveSyncDevice()) return;
    audioDuration = audioEl?.duration || currentTrack?.duration_seconds || 0;
    applyPendingSeek();
  }

  function handleAudioError() {
    if (usePlaybackSync() && !isActiveSyncDevice()) return;
    if (!currentTrack) {
      return;
    }

    isPlaying = false;
    errorMessage = mediaErrorMessage(
      `Could not load "${currentTrack.title}".`,
      audioEl?.error ?? null
    );
  }

  function playLocalAudio(): Promise<void> {
    if (!audioEl) return Promise.resolve();
    playbackAudioSession.begin();
    // A lock-screen play gesture must wake both the element and the existing
    // analyser graph; HTMLAudioElement.play() alone cannot wake Web Audio.
    if (audioGraphContext && audioGraphContext.state !== "running" && audioGraphContext.state !== "closed") {
      void audioGraphContext.resume().catch(() => undefined);
    }
    const wasPaused = audioEl.paused;
    const result = audioEl.play();
    if (wasPaused && !audioEl.paused) expectedAudioPlayEvents++;
    return result;
  }

  function pauseLocalAudio() {
    if (!audioEl) return;
    const wasPaused = audioEl.paused;
    audioEl.pause();
    if (!wasPaused && audioEl.paused) expectedAudioPauseEvents++;
  }

  function updateSystemMediaSession(track: Track | null, playing: boolean, local: boolean) {
    if (typeof navigator === "undefined" || !("mediaSession" in navigator)) return;
    navigator.mediaSession.playbackState = track && local ? (playing ? "playing" : "paused") : "none";
    const trackId = local ? track?.id ?? "" : "";
    if (trackId === systemMediaTrackId) return;
    systemMediaTrackId = trackId;
    navigator.mediaSession.metadata = track && local && typeof MediaMetadata !== "undefined"
      ? new MediaMetadata({ title: track.title, artist: track.artist ?? "", album: track.album ?? "" })
      : null;
  }

  function canControlLocalMedia(): boolean {
    // Selection changes before a transfer is acknowledged. Our own queued
    // commands can advance revision guards, so also honor that pending target.
    return !usePlaybackSync() || (isActiveSyncDevice() &&
      (!selectedPlaybackDeviceId || selectedPlaybackDeviceId === deviceId));
  }

  function publishLocalMediaState(playing: boolean) {
    if (!canControlLocalMedia() || isPlaying === playing) return;
    isPlaying = playing;
    currentTime = audioEl.currentTime || 0;
    if (usePlaybackSync()) {
      // System events belong to this speaker, never a selected remote device.
      // The revision guard rejects a stale event racing a transfer to a phone.
      void sendPlaybackCommand(playing ? "play" : "pause", {
        target_device_id: deviceId,
        expectedRevision: playbackStateV2?.revision,
        position_seconds: currentTime
      }).then((state) => applyPlaybackStateV2(state)).catch((error) => {
        errorMessage = error instanceof Error ? error.message : String(error);
      });
    } else {
      schedulePlaybackDeviceUpdate(true);
      void activateThisPlaybackDevice();
    }
  }

  function handleSystemPlayback(playing: boolean) {
    if (!audioEl || !currentTrack || loadedTrackId !== currentTrack.id || !canControlLocalMedia()) return;
    // Explicit desired state makes repeated hardware pause/play idempotent.
    // Perform the local operation in the user gesture before any network await.
    if (playing) {
      void playLocalAudio().catch(() => {
        if (isActiveSyncDevice() && audioEl.paused) isPlaying = false;
      });
    } else {
      pauseLocalAudio();
    }
    publishLocalMediaState(playing);
  }

  function handleAudioPause() {
    if (expectedAudioPauseEvents > 0) {
      expectedAudioPauseEvents--;
      return;
    }
    if (!canControlLocalMedia()) return;
    // End-of-track, failed resources and stale events have their own handling.
    if (!audioEl?.paused || audioEl.ended || audioEl.error || !currentTrack ||
        loadedTrackId !== currentTrack.id || audioEl.readyState === 0) return;
    publishLocalMediaState(false);
  }

  function handleAudioPlay() {
    const expected = expectedAudioPlayEvents > 0;
    if (expected) expectedAudioPlayEvents--;
    // A play promise can settle after ownership moved to native. Stop only
    // this stale element; it must not change or claim the remote session.
    if (!canControlLocalMedia()) {
      pauseLocalAudio();
      return;
    }
    // If the element is wired into the visualizer's audio graph and that
    // context is suspended (it was built without a user gesture), every
    // sample routes into a dead graph and playback is silent. Any real play
    // is a gesture, so wake the graph here.
    if (audioGraphContext && audioGraphContext.state !== "running") {
      playbackAudioSession.begin();
      void audioGraphContext.resume().catch(() => undefined);
    }
    // Build the graph on the first user-initiated play from any view, so
    // the visualizer records history in the background. Remote-initiated
    // play without any interaction skips this — an AudioContext created
    // without a gesture starts suspended and would silence the element.
    if (!visualizerAnalyser && (navigator.userActivation?.hasBeenActive ?? false)) {
      visualizerAnalyser = ensureAnalyser();
    }

    if (expected || audioEl?.paused || audioEl?.error ||
        !currentTrack || loadedTrackId !== currentTrack.id) return;
    publishLocalMediaState(true);
  }

  // ---------------------------------------------------------------------------
  // Views, themes, and playlist editing
  // ---------------------------------------------------------------------------

  async function joinAuxAsGuest(code: string, handoff = true) {
    const origin = handoff ? window.location.origin : (syncServerUrl || window.location.origin);
    // Hand off to the native app when it's installed; iOS switches apps and
    // hides this tab, otherwise the browser join below is the fallback.
    if (handoff && /iPhone|iPad|iPod/.test(navigator.userAgent)) {
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
    if (guestMode) { auxCode = ""; auxModalOpen = false; guestMode = false; disconnectSyncServer(); return; }
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
    if (mobileLayout && selectedView === mobileTab) mobileRootScroll.set(mobileTab, contentEl?.scrollTop ?? 0);
    cancelPlaylistRename();
    mobilePlaylistEditing = false;
    mobileCollection = null;
    selectedView = view;
    searchQuery = "";
    sortKey = "default";
    if (mobileLayout) void tick().then(() => contentEl?.scrollTo({ top: view === mobileTab ? mobileRootScroll.get(mobileTab) ?? 0 : 0 }));
  }

  function selectMobileTab(view: string) {
    mobilePlaylistEditing = false;
    if (view === mobileTab) { selectView(view); return; }
    mobileTabStates.set(mobileTab, { view: selectedView, query: searchQuery, sort: sortKey, collection: mobileCollection, scroll: contentEl?.scrollTop ?? 0 });
    mobileTab = view;
    const saved = mobileTabStates.get(view);
    if (saved) {
      cancelPlaylistRename();
      selectedView = saved.view;
      searchQuery = saved.query;
      sortKey = saved.sort;
      mobileCollection = saved.collection;
      void tick().then(() => contentEl?.scrollTo({ top: saved.scroll }));
    } else selectView(view);
  }

  function openMobileAlbum(album: AlbumSummary) {
    selectView("all");
    mobileCollection = { title: album.name, artist: album.artist, kind: "album" };
  }

  function openMobileArtist(artist: ArtistSummary) {
    selectView("all");
    mobileCollection = { title: artist.name, kind: "artist" };
  }

  async function createPlaylistFromLibrary() {
    const name = newPlaylistTitle.trim();
    if (!name || creatingPlaylist || !syncServerUrl || !isRemoteRoot(rootPath) || guestMode) return;
    const server = syncServerUrl;
    const token = syncTokenDraft;
    const root = rootPath;
    const stillConnected = () => server === syncServerUrl && token === syncTokenDraft && root === rootPath;
    creatingPlaylist = true;
    createPlaylistError = "";
    try {
      const playlist = await createRemotePlaylist(server, name);
      if (!stillConnected()) return;
      if (library) {
        const playlists = [...library.playlists.filter((existing) => existing.id !== playlist.id), playlist];
        syncLibrary({ ...library, playlists, stats: { ...library.stats, playlistCount: playlists.filter((item) => !item.is_liked).length } });
      }
      const trackToAdd = newPlaylistTrack;
      // Creation is committed now. A later membership failure must not leave
      // Create active and make the next attempt create a duplicate playlist.
      newPlaylistTrack = null;
      newPlaylistOpen = false;
      newPlaylistTitle = "";
      if (trackToAdd) await addTrackToRemotePlaylist(server, playlist.id, trackToAdd.fingerprint);
      else selectView(playlist.id);
      if (stillConnected()) await refreshRemoteLibraryState(true);
    } catch (error) {
      if (stillConnected()) {
        const message = error instanceof Error ? error.message : String(error);
        if (newPlaylistOpen) createPlaylistError = message;
        else errorMessage = message;
      }
    } finally { creatingPlaylist = false; }
  }

  function openFromBrowseGrid(query: string, albumArtist?: string) {
    if (mobileLayout && albumArtist !== undefined) {
      selectView("all");
      mobileCollection = { title: query, artist: albumArtist, kind: "album" };
      return;
    }
    mobileCollection = null;
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
    const playlist = selectedPlaylist;
    const root = rootPath;
    const server = syncServerUrl;
    const token = syncTokenDraft;
    const remote = isRemoteRoot(root);
    const stillConnected = () => root === rootPath && (!remote || (server === syncServerUrl && token === syncTokenDraft));
    try {
      if (remote) {
        await renameRemotePlaylist(server, playlist.id, name);
      } else {
        await invoke("rename_playlist", { root_path: root, playlist_id: playlist.id, name });
      }
      if (!stillConnected()) return;
      if (remote && library) {
        syncLibrary({ ...library, playlists: library.playlists.map((item) => item.id === playlist.id ? { ...item, name } : item) });
      }
      if (editingPlaylistId === playlist.id) cancelPlaylistRename();
      if (remote) await refreshRemoteLibraryState(true);
      else await loadLibrary(root, true);
    } catch (error) {
      if (stillConnected()) errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      renamingPlaylist = false;
    }
  }

  // Browser MP3 import: tags parsed client-side, identity derived exactly
  // like the desktop, then metadata + audio + artwork go straight to the
  // sync server through the existing upsert endpoints.
  async function importAudioFiles(files: File[]) {
    if (!syncServerUrl || files.length === 0 || importBusy) {
      return;
    }

    const importServer = syncServerUrl;
    const importToken = syncTokenDraft;
    const zipFiles = files.filter((file) => file.name.toLowerCase().endsWith(".zip"));
    const hasManifest = files.some((file) => file.name.toLowerCase().endsWith(".json"));
    importing = true;
    errorMessage = "";
    try {
      if (zipFiles.length) {
        if (zipFiles.length !== 1 || files.length !== 1) throw new Error("Select one bundle ZIP, or select its unpacked folder instead.");
        await importLoudZip(zipFiles[0]);
      } else if (hasManifest) {
        importPhase = "preparing";
        importUploadFraction = 0;
        const bundle = await buildImportBundle(files, (fraction) => { importUploadFraction = fraction; });
        if (syncServerUrl !== importServer || syncTokenDraft !== importToken) {
          throw new Error("The server connection changed while preparing the bundle. Select it again for the current server.");
        }
        await importLoudZip(bundle);
      } else {
        const audio = files.filter((file) => /\.mp3$/i.test(file.name));
        if (audio.length !== files.length) throw new Error("Select MP3 files, a bundle ZIP, or a manifest with its audio and artwork files.");
        await importPlainAudio(audio);
      }
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
      if (importPhase === "preparing") importPhase = "failed";
    } finally {
      importing = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Bundle import jobs: the zip goes to the server once, the server unpacks
  // and applies it in the background, and progress is polled by job id — so
  // the banner survives closing the modal, switching views, or a refresh.
  // ---------------------------------------------------------------------------

  const IMPORT_JOB_STORAGE_KEY = "codec.importJob";

  let importJob: ImportJobStatus | null = null;
  let importUploadFraction = 0;
  let importPhase: "idle" | "preparing" | "uploading" | "processing" | "done" | "failed" = "idle";
  let importJobTimer: number | null = null;
  $: importBusy = importing || importPhase === "preparing" || importPhase === "uploading" || importPhase === "processing";

  async function importLoudZip(zipFile: Blob) {
    if (!syncServerUrl) {
      return;
    }
    importPhase = "uploading";
    importUploadFraction = 0;
    importJob = null;
    try {
      const jobId = await uploadBundle(syncServerUrl, zipFile, (fraction) => {
        importUploadFraction = fraction;
      });
      writeStoredValue(IMPORT_JOB_STORAGE_KEY, jobId);
      importPhase = "processing";
      watchImportJob(jobId);
    } catch (error) {
      importPhase = "failed";
      errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  function watchImportJob(jobId: string) {
    stopWatchingImportJob();
    const poll = async () => {
      if (!syncServerUrl) {
        return;
      }
      try {
        const status = await fetchImportJob(syncServerUrl, jobId);
        if (!status) {
          // Server restarted mid-job; nothing to resume.
          importPhase = "failed";
          errorMessage = "The import job was lost (server restarted). Import the bundle again.";
          finishImportJob();
          return;
        }
        importJob = status;
        if (status.state === "running") {
          importPhase = "processing";
          return;
        }
        importPhase = status.state;
        if (status.state === "failed") {
          errorMessage = status.error ? `Import failed: ${status.error}` : "Import failed.";
        } else {
          await loadRemoteLibrary(true);
          syncMessage = bundleImportSummary(status);
          if (status.artwork_warnings?.length) errorMessage = status.artwork_warnings.slice(0, 3).join(" · ");
        }
        finishImportJob();
      } catch {
        // Transient; keep polling.
      }
    };
    void poll();
    importJobTimer = window.setInterval(() => void poll(), 1000);
  }

  function stopWatchingImportJob() {
    if (importJobTimer) {
      window.clearInterval(importJobTimer);
      importJobTimer = null;
    }
  }

  function finishImportJob() {
    stopWatchingImportJob();
    removeStoredValue(IMPORT_JOB_STORAGE_KEY);
  }

  function dismissImportBanner() {
    importPhase = "idle";
    importJob = null;
  }

  // A refresh mid-import picks the job back up.
  $: if (syncServerUrl && syncServerReady && importPhase === "idle" && !importJobTimer) {
    const pending = readStoredValue(IMPORT_JOB_STORAGE_KEY);
    if (pending) {
      importPhase = "processing";
      watchImportJob(pending);
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
      const trackIds = selectedIds.has(playlist.id)
        ? [...playlist.track_ids]
        : playlist.track_ids.filter((trackId) => !nextTrackIds.has(trackId));

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
    const track = library?.tracks.find((candidate) => candidate.fingerprint === playlistModalTrack?.fingerprint) ?? playlistModalTrack;
    const selectedPlaylistIds = [...playlistModalSelectionIds];
    const previousLibrary = library;

    if (!rootPath || !track || savingPlaylistMemberships) {
      return;
    }

    const root = rootPath;
    const server = syncServerUrl;
    const token = syncTokenDraft;
    const remote = isRemoteRoot(root);
    const stillConnected = () => root === rootPath && (!remote || (server === syncServerUrl && token === syncTokenDraft));
    savingPlaylistMemberships = true;
    errorMessage = "";
    applyLocalPlaylistMemberships(track, selectedPlaylistIds);
    closePlaylistMembershipModal();

    try {
      if (remote) {
        await enqueuePlaylistWrite(server, token, async () => {
          const desired = new Set(selectedPlaylistIds);
          for (const playlist of previousLibrary?.playlists ?? []) {
            if (!stillConnected()) return;
            const wasMember = playlist.is_liked ? track.is_liked : playlist.track_ids.includes(track.id);
            const isMember = desired.has(playlist.id);
            if (wasMember === isMember) continue;
            if (playlist.is_liked) await setTrackLiked(server, track.fingerprint, isMember);
            else if (isMember) await addTrackToRemotePlaylist(server, playlist.id, track.fingerprint);
            else await removeTrackFromRemotePlaylist(server, playlist.id, track.fingerprint);
          }
        }, true);
      } else {
        await invoke("set_track_playlist_memberships", { root_path: root, track_path: track.path, playlist_ids: selectedPlaylistIds });
        if (stillConnected()) await loadLibrary(root, true);
      }
    } catch (error) {
      if (!stillConnected()) return;
      errorMessage = error instanceof Error ? error.message : String(error);
      if (previousLibrary) {
        applyLocalPlaylistMemberships(track, playlistSelectionForTrack(track));
      }
      if (remote) await refreshRemoteLibraryState(true);
    } finally {
      savingPlaylistMemberships = false;
    }
  }
  function recordPlaylistPlay() {
    if (!selectedPlaylist || selectedPlaylist.is_liked || !syncServerUrl) return;
    playlistHistory = { ...playlistHistory, [syncServerUrl]: { ...playlistHistory[syncServerUrl], [selectedPlaylist.id]: Date.now() } };
    try { localStorage.setItem("codec.playlistHistory", JSON.stringify(playlistHistory)); } catch { /* Playback works if preferences storage is full. */ }
  }

  async function refreshDownloads(server: string) {
    const epoch = ++downloadEpoch;
    try {
      const saved = server ? await listDownloaded(server) : new Set<string>();
      if (syncServerUrl === server && epoch === downloadEpoch) downloadedFingerprints = saved;
    } catch { /* Keep known downloads when browser storage is temporarily unavailable. */ }
  }

  function downloadKey(server: string, fingerprint: string): string { return `${server}\u0000${fingerprint}`; }

  function showDownloadProgress(run: DownloadRun) {
    if (downloadRun !== run || run.controller.signal.aborted) return;
    const partial = [...run.progress.values()].reduce((sum, value) => sum + value, 0);
    downloadStatus.set({ state: "downloading", message: run.tracks.length === 1 ? "Downloading song" : `Downloading ${run.saved} of ${run.tracks.length}`,
      detail: run.tracks.length === 1 ? run.tracks[0].title : "Saved songs are available offline.",
      progress: (run.saved + partial) / run.tracks.length, cancel: () => run.controller.abort() });
  }

  async function startDownloads(tracks: Track[]) {
    if (!syncServerUrl || guestMode) return;
    const existing = downloadRun;
    const continuing = existing && !existing.controller.signal.aborted && existing.server === syncServerUrl && existing.token === syncTokenDraft;
    const run: DownloadRun = continuing ? existing : { server: syncServerUrl, token: syncTokenDraft,
      controller: new AbortController(), tracks: [], fingerprints: new Set(), next: 0, saved: 0, failure: "", progress: new Map() };
    for (const track of tracks) {
      if (!downloadedFingerprints.has(track.fingerprint) && !run.fingerprints.has(track.fingerprint)) {
        run.fingerprints.add(track.fingerprint); run.tracks.push(track);
      }
    }
    if (!run.tracks.length) return;
    downloadRun = run;
    downloadingKeys = new Set([...(continuing ? downloadingKeys : []), ...run.tracks.slice(run.next).map(track => downloadKey(run.server, track.fingerprint))]);
    showDownloadProgress(run);
    if (continuing) return;
    const stillConnected = () => downloadRun === run && run.server === syncServerUrl && run.token === syncTokenDraft && !guestMode;
    async function worker() {
      while (run.next < run.tracks.length && !run.controller.signal.aborted && stillConnected()) {
        const track = run.tracks[run.next++];
        try {
          let url = track.media_url;
          if (!url) {
            await abortable(refreshSyncStreamToken(run.server), run.controller.signal);
            if (!stillConnected() || run.controller.signal.aborted) return;
            url = trackAudioUrl(run.server, track.fingerprint);
          }
          await cacheDownload(run.server, track.fingerprint, url, { signal: run.controller.signal,
            onProgress: (loaded, total) => { run.progress.set(track.fingerprint, total ? Math.min(1, loaded / total) : 0); showDownloadProgress(run); } });
          run.saved++;
          if (stillConnected()) {
            ++downloadEpoch;
            downloadedFingerprints = new Set([...downloadedFingerprints, track.fingerprint]);
          }
        } catch (error) {
          if (!run.controller.signal.aborted) { run.failure = error instanceof Error ? error.message : String(error); run.controller.abort(); }
        } finally {
          run.progress.delete(track.fingerprint);
          if (downloadRun === run) downloadingKeys = new Set([...downloadingKeys].filter(key => key !== downloadKey(run.server, track.fingerprint)));
          showDownloadProgress(run);
        }
      }
    }
    // Two transfers keep collections moving without flooding a mobile connection.
    await Promise.all([worker(), worker()]);
    if (stillConnected()) {
      const canceled = run.controller.signal.aborted && !run.failure;
      downloadStatus.set({ state: run.failure ? "error" : "done",
        message: run.failure ? "Download stopped" : canceled ? "Download canceled" : run.saved === 1 ? "Song downloaded" : `${run.saved} songs downloaded`,
        detail: run.failure || (canceled ? `${run.saved} saved for offline listening.` : "Available in Library → Downloaded.") });
    }
    if (downloadRun === run) {
      downloadingKeys = new Set();
      downloadRun = null;
    }
  }

  function downloadSong(track: Track) { return startDownloads([track]); }

  async function removeDownloadedSong(track: Track) {
    const server = syncServerUrl, token = syncTokenDraft;
    try {
      await deleteDownload(server, track.fingerprint);
      if (syncServerUrl !== server || syncTokenDraft !== token) return;
      ++downloadEpoch;
      downloadedFingerprints = new Set([...downloadedFingerprints].filter(fp => fp !== track.fingerprint));
      downloadStatus.set({ state: "done", message: "Download removed", detail: track.title });
    } catch (error) {
      if (syncServerUrl === server && syncTokenDraft === token) downloadStatus.set({ state: "error", message: "Could not remove download", detail: error instanceof Error ? error.message : String(error) });
    }
  }

  function downloadVisibleSongs() { return startDownloads([...visibleTracks]); }

  function removeUpcoming(index: number) {
    const actual = playbackIndex + 1 + index;
    if (actual <= playbackIndex || actual >= playbackSource.length) return;
    playbackSource = playbackSource.filter((_, i) => i !== actual);
    publishQueueChange();
  }

  function moveUpcoming(index: number, target: number) {
    const start = playbackIndex + 1, next = [...playbackSource];
    if (index < 0 || target < 0 || start + index >= next.length || start + target >= next.length) return;
    const [moved] = next.splice(start + index,1); next.splice(start + target,0,moved);
    playbackSource = next; publishQueueChange();
  }

  function enqueuePlaylistWrite(server: string, token: string, action: () => Promise<void>, propagate = false): Promise<void> {
    const stillConnected = () => server === syncServerUrl && token === syncTokenDraft && !guestMode;
    pendingPlaylistWrites++;
    playlistMutationEpoch++;
    const write = playlistWriteTail.then(async () => {
      if (!stillConnected()) return;
      await action();
    }).catch(error => {
      if (stillConnected()) errorMessage = error instanceof Error ? error.message : String(error);
      if (propagate) throw error;
    }).finally(async () => {
      pendingPlaylistWrites--;
      // Reconcile once the full optimistic edit sequence has landed. An
      // intermediate snapshot must not undo later queued membership edits.
      if (pendingPlaylistWrites === 0 && stillConnected()) await refreshRemoteLibraryState(true);
    });
    playlistWriteTail = write.catch(() => undefined);
    return write;
  }

  function movePlaylistSong(from: number, to: number) {
    const playlist = selectedPlaylist, server = syncServerUrl, token = syncTokenDraft;
    if (!playlist || guestMode || !library || from === to || !visibleTracks[from] || !visibleTracks[to]) return;
    const ids = [...playlist.track_ids], original = ids.indexOf(visibleTracks[from].id), target = ids.indexOf(visibleTracks[to].id);
    if (original < 0 || target < 0) return;
    const [moved] = ids.splice(original,1); ids.splice(target,0,moved);
    syncLibrary({ ...library, playlists: library.playlists.map(p => p.id === playlist.id ? { ...p, track_ids:ids } : p) });
    void enqueuePlaylistWrite(server,token,() => setRemotePlaylistTracks(server,playlist.id,ids));
  }

  function removePlaylistSong(index: number) {
    const playlist = selectedPlaylist, track = visibleTracks[index], server = syncServerUrl, token = syncTokenDraft;
    if (!playlist || !track || guestMode || !library) return;
    syncLibrary({ ...library, playlists:library.playlists.map(p => p.id === playlist.id ? { ...p,track_ids:p.track_ids.filter(id => id !== track.id) } : p) });
    void enqueuePlaylistWrite(server,token,() => removeTrackFromRemotePlaylist(server,playlist.id,track.fingerprint));
  }

  async function addPlaylistSong(track: Track) {
    const playlist = selectedPlaylist, server = syncServerUrl, token = syncTokenDraft;
    if (!playlist || !library || guestMode || addingSongIDs.has(track.id) || playlist.track_ids.includes(track.id)) return;
    addingSongIDs = new Set([...addingSongIDs,track.id]);
    syncLibrary({ ...library, playlists: library.playlists.map(p => p.id === playlist.id ? { ...p,track_ids:[...p.track_ids,track.id] } : p) });
    try { await enqueuePlaylistWrite(server,token,() => addTrackToRemotePlaylist(server,playlist.id,track.fingerprint)); }
    finally { addingSongIDs = new Set([...addingSongIDs].filter(id => id !== track.id)); }
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
  <main class="app-shell" class:has-mobile-player={mobileLayout && Boolean(currentTrack)} class:mobile-empty-search={mobileLayout && selectedView === "search" && !searchActive} data-theme={theme} data-view={selectedView}>
    {#if visualizerSampler}
      <SpectrumAppearance sampler={visualizerSampler} {currentTrack} {theme} />
    {/if}
    <Sidebar
      {selectedView}
      {guestMode}
      {auxCode}
      onSelectView={selectView}
      onOpenSettings={() => (settingsModalOpen = true)}
      onShowAux={() => (auxModalOpen = true)}
    />

    <TopBar bind:this={topBar} bind:searchQuery />

    {#if mobileLayout}
      <header class="mobile-toolbar">
        {#if !["home", "search", "library", "visualizer"].includes(selectedView)}
          <button class="mobile-text-button" type="button" onclick={() => selectView(mobileTab)}><ChevronLeft size={22} />{titleForView(mobileTab, null)}</button>
          <ViewHeader viewTitle={mobileViewTitle} {viewSubtitle} {selectedPlaylist} isEditing={false} renaming={false} mobileToolbarOnly mobileSortKey={sortKey} onMobileSort={(value) => sortKey = value}
            playlistEditing={mobilePlaylistEditing} onTogglePlaylistEdit={!guestMode && selectedPlaylist && !selectedPlaylist.is_liked ? () => { mobilePlaylistEditing = !mobilePlaylistEditing; sortKey = "default"; } : undefined}
            onAddSongs={!guestMode && selectedPlaylist && !selectedPlaylist.is_liked ? () => { addingSongs = true; addSongQuery = ""; } : undefined}
            canEditCover={Boolean(syncServerUrl && !guestMode && selectedPlaylist && !selectedPlaylist.is_liked)} bind:playlistNameDraft onStartRename={startPlaylistRename} onCommitRename={() => void commitPlaylistRename()} onCancelRename={cancelPlaylistRename} onChangeCover={(file) => void changePlaylistCover(file)}/>
        {:else}<h1 class:codec-title={selectedView === "home"}>{selectedView === "home" ? "Codec" : titleForView(selectedView,null)}</h1>{/if}
        {#if selectedView === "home"}
          <div class="mobile-toolbar-actions">
            {#if auxCode}<button class="mobile-aux-chip" type="button" aria-label="Aux session" onclick={() => auxModalOpen = true}><Radio size={16}/>{auxCode}</button>{/if}
            <button class="mobile-icon-button" type="button" aria-label="Palettes" onclick={openThemeModal}><Palette size={24} /></button>
            <button class="mobile-icon-button" type="button" aria-label="Settings" onclick={() => { syncServerDraft = syncServerUrl; settingsModalOpen = true; }}><MobileSymbol name="settings" size={24} /></button>
          </div>
        {/if}
      </header>
      {#if selectedView === "search"}<div class="mobile-search-header"><label class="mobile-search-field"><Search size={19} /><input bind:this={mobileSearchInput} bind:value={searchQuery} type="search" aria-label="Search library" placeholder="Songs, artists, albums" />
        {#if searchQuery}<button class="mobile-icon-button" type="button" aria-label="Clear search" onclick={() => { searchQuery = ""; }}><X size={17} /></button>{/if}
      </label></div>{/if}
    {/if}

    <section class="content" class:mobile-visualizer={selectedView === "visualizer"} bind:this={contentEl} use:mobileViewMotion={{ view: selectedView, tab: mobileTab, enabled: mobileLayout }}>
      {#if importPhase !== "idle"}
        <section class="import-banner" class:done={importPhase === "done"} class:failed={importPhase === "failed"} aria-live="polite">
          <div class="import-banner-copy">
            {#if importPhase === "preparing" || importPhase === "uploading"}
              <strong>{importPhase === "preparing" ? "Preparing bundle" : "Uploading bundle"}</strong>
              <span>{Math.round(importUploadFraction * 100)}%</span>
            {:else if importPhase === "processing"}
              <strong>Importing{importJob?.total ? ` ${importJob.done}/${importJob.total}` : ""}</strong>
              <span>{importJob?.current ?? "Unpacking bundle…"}</span>
            {:else if importPhase === "done"}
              <strong>Import finished</strong>
              <span>{syncMessage}</span>
            {:else}
              <strong>Import failed</strong>
              <span>{errorMessage}</span>
            {/if}
          </div>
          {#if importPhase === "preparing" || importPhase === "uploading" || importPhase === "processing"}
            <div class="import-banner-bar" role="progressbar" aria-valuemin="0" aria-valuemax="100"
              aria-valuenow={(importPhase === "preparing" || importPhase === "uploading") ? Math.round(importUploadFraction * 100) : (importJob?.total ? Math.round((importJob.done / importJob.total) * 100) : 0)}>
              <i style={`width: ${(importPhase === "preparing" || importPhase === "uploading") ? importUploadFraction * 100 : (importJob?.total ? (importJob.done / importJob.total) * 100 : 0)}%`}></i>
            </div>
          {:else}
            <button class="ui-button compact" type="button" onclick={dismissImportBanner}>Dismiss</button>
          {/if}
        </section>
      {/if}

      {#if loading || (bootstrapping && !library)}
        <section class="loading-state">
          <LoaderCircle class="spin-icon" size={34} />
          <p>Reading music folder</p>
        </section>
      {:else if library}
        {#if !["home", "search", "library", "visualizer"].includes(selectedView) && !globalSearch}
          <ViewHeader
            viewTitle={mobileLayout ? mobileViewTitle : viewTitle}
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
            userPlaylists={mobileLayout ? recentPlaylists : userPlaylists}
            recentItems={homeItems}
            playlistCovers={homePlaylistCovers}
            {playingPlaylist} {playingPlaylistCovers} {isPlaying}
            currentTrackId={currentTrack?.id ?? null}
            onOpenPlaylist={selectView}
            onOpenAlbum={openFromBrowseGrid}
            onPlayTrack={(track) => void playTrackRow(track, 0)}
            {auxCode}
            onShowAux={() => { auxModalOpen = true; }}
          />
        {:else if selectedView === "library" && !globalSearch}
          <MobileLibrary
            playlists={userPlaylists} {playlistArtwork}
            songCount={stats.trackCount} likedCount={stats.likedCount} downloadedCount={downloadedIDs.size} onOpenDownloaded={() => selectView("downloaded")}
            albums={albums.filter((album) => album.trackCount >= 2)} {artists}
            canCreate={Boolean(syncServerUrl && syncServerReady && isRemoteRoot(rootPath) && !guestMode)}
            onOpen={selectView} onOpenAlbum={openMobileAlbum} onOpenArtist={openMobileArtist}
            onCreate={() => { newPlaylistTrack = null; newPlaylistOpen = true; createPlaylistError = ""; }}
          />
        {:else if selectedView === "visualizer"}
          <VisualizerView
            sampler={visualizerSampler}
            sampling={isPlaying && playbackPageVisible && (!syncServerReady || activePlaybackDeviceId === deviceId)}
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
            viewTitle={globalSearch || selectedView === "search" ? "Search" : viewTitle}
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
            onQueueNext={(track) => { queuedTracks = [track, ...queuedTracks]; publishQueueChange(); }}
            {downloadedIDs} {downloadingIDs} onDownloadTrack={!guestMode ? (track) => void downloadSong(track) : undefined} onRemoveDownload={(track) => void removeDownloadedSong(track)}
            onDownloadAll={!guestMode && selectedView !== "downloaded" ? () => void downloadVisibleSongs() : undefined}
            emptyTitle={selectedView === "search" ? "No Results" : selectedPlaylist && !selectedPlaylist.is_liked ? "No Songs" : "No Tracks"} emptyDescription={selectedView === "search" ? `No results for “${searchQuery}”.` : selectedPlaylist && !selectedPlaylist.is_liked ? "Add songs from your library." : undefined}
            playlistEditing={mobilePlaylistEditing} onMovePlaylistTrack={movePlaylistSong} onRemovePlaylistTrack={removePlaylistSong}
            onRemoveQueued={removeQueuedTrackAt}
            {guestMode}
            onEditPlaylists={openPlaylistMembershipModal}
            onToggleLike={(track) => void toggleLike(track)}
          />
        {/if}
      {/if}
    </section>

    {#if !mobileLayout}
    {#if queueRailVisible}
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
    {/if}

    <PlayerBar
      {currentTrack}
      {isPlaying}
      {shuffle}
      {repeatMode}
      {currentTime}
      {audioDuration}
      {volume}
      showVolumeControl={hasNativeBridge()}
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
    {/if}

    {#if mobileLayout}
      <div class="mobile-bottom-controls">
        {#if currentTrack}
          <MobilePlayer
            currentTrack={mobileTrackIndex.get(currentTrack.id) ?? currentTrack}
            {isPlaying} {shuffle} {repeatMode} {currentTime} {audioDuration}
            showDeviceControl={Boolean(syncServerUrl && syncServerReady && deviceId)}
            {playbackDeviceOptions} {activePlaybackDeviceId} {activePlaybackDeviceName} {deviceId}
            {theme} obscured={Boolean(playlistModalTrack)} downloadState={downloadingKeys.has(downloadKey(syncServerUrl, currentTrack.fingerprint)) ? "downloading" : downloadedFingerprints.has(currentTrack.fingerprint) ? "downloaded" : "none"}
            onDownload={!guestMode ? (track) => void downloadSong(track) : undefined} onRemoveDownload={(track) => void removeDownloadedSong(track)}
            airPlayAvailable={Boolean(audioEl && "webkitShowPlaybackTargetPicker" in audioEl)} onAirPlay={() => (audioEl as HTMLAudioElement & { webkitShowPlaybackTargetPicker?:()=>void })?.webkitShowPlaybackTargetPicker?.()}
            onRemoveUpcoming={removeUpcoming} onMoveUpcoming={moveUpcoming}
            {queue} queuedTracksCount={queuedTracks.length} {guestMode}
            onToggleShuffle={() => void toggleShuffle()} onPrevious={() => void previousTrack()}
            onTogglePlayback={() => void togglePlayback()} onNext={() => void nextTrack()}
            onToggleRepeat={() => void toggleRepeat()} onSeekInput={(event) => void setProgress(event)}
            onDeviceChange={handlePlaybackDeviceChange}
            onToggleLike={(track) => void toggleLike(track)} onEditPlaylists={openPlaylistMembershipModal}
            onPlayQueueTrack={(index) => void playQueueTrack(index)} onRemoveQueued={removeQueuedTrackAt}
            onMoveQueued={moveQueuedTrack} onClearQueue={clearQueuedTracks}
          />
        {/if}
        <MobileTabs selected={["home", "search", "library", "visualizer"].includes(selectedView) ? selectedView : mobileTab} onSelect={selectMobileTab} />
      </div>
    {/if}

    {#if newPlaylistOpen}
      <MobileNewPlaylist bind:name={newPlaylistTitle} busy={creatingPlaylist} error={createPlaylistError} onClose={() => { newPlaylistOpen = false; newPlaylistTrack = null; }} onCreate={() => void createPlaylistFromLibrary()}/>
    {/if}

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
      {#if mobileLayout}<MobilePlaylistMembership track={playlistModalTrack} playlists={library.playlists} bind:selectedIds={playlistModalSelectionIds} saving={savingPlaylistMemberships} onClose={closePlaylistMembershipModal} onSave={() => void savePlaylistMemberships()} onCreate={() => { newPlaylistTrack = playlistModalTrack; void savePlaylistMemberships(); newPlaylistOpen = true; }}/>
      {:else}<PlaylistModal
        track={playlistModalTrack}
        playlists={library.playlists}
        bind:selectedIds={playlistModalSelectionIds}
        saving={savingPlaylistMemberships}
        onClose={closePlaylistMembershipModal}
        onSave={() => void savePlaylistMemberships()}
      />{/if}
    {/if}

    {#if themeModalOpen}
      {#if mobileLayout}<MobilePalettes {theme} onSetTheme={setTheme} onClose={closeThemeModal}/>{:else}<ThemeModal
        {theme}
        activeThemeName={activeTheme.name}
        onSetTheme={setTheme}
        onClose={closeThemeModal}
      />{/if}
    {/if}

    {#if settingsModalOpen}
      {#if mobileLayout}<MobileSettings importing={importBusy} {syncMessage} onImportFiles={(files) => void importAudioFiles(files)} bind:server={syncServerDraft} bind:token={syncTokenDraft} connected={syncServerReady} {loading} error={errorMessage} {auxCode} {auxBusy} {guestMode}
        onClose={() => settingsModalOpen = false} onReconnect={() => { void loadRemoteLibrary(false).then(() => { if(syncServerReady) settingsModalOpen = false; }); }}
        onDisconnect={() => { settingsModalOpen = false; disconnectSyncServer(); }} onStartAux={() => { settingsModalOpen = false; void startAux(); }}
        onShowAux={() => { settingsModalOpen = false; auxModalOpen = true; }} onEndAux={() => void endAux()} onJoinAux={(code) => { settingsModalOpen = false; void joinAuxAsGuest(code,false); }}/>
      {:else}<SettingsModal
        activeThemeName={activeTheme.name}
        {syncing}
        canUpload={Boolean(library) && hasNativeBridge() && !isRemoteRoot(rootPath)}
        {syncMessage}
        importing={importBusy}
        importDisabled={!hasNativeBridge() || isRemoteRoot(rootPath)}
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
      />{/if}
    {/if}

    {#if auxModalOpen && auxCode}
      {#if mobileLayout}<MobileAux code={auxCode} link={auxLink()} {guestMode} onClose={() => auxModalOpen = false} onEnd={() => void endAux()}/>{:else}<AuxModal
        {auxCode}
        auxLink={auxLink()}
        onCopyLink={() => void copyAuxLink()}
        onEnd={() => void endAux()}
        onClose={() => (auxModalOpen = false)}
      />{/if}
    {/if}

    {#if addingSongs && selectedPlaylist && library}
      <MobileSheet full title="Add Songs" onClose={() => addingSongs = false}>
        <div class="native-add-songs"><label class="mobile-search-field"><Search size={19}/><input type="search" bind:value={addSongQuery} placeholder="Search songs" aria-label="Search songs to add"/></label>
          <VirtualRows items={searchTracks(library.tracks,addSongQuery)} rowHeight={86}>
            {#snippet children(track)}
              <button class="native-song-choice" type="button" disabled={selectedPlaylist?.track_ids.includes(track.id) || addingSongIDs.has(track.id)} onclick={() => void addPlaylistSong(track)}>
                {#if track.artwork_url}<ArtworkImage src={track.artwork_url} alt="" loading="lazy"/>{:else}<span class="native-song-art-placeholder">♪</span>{/if}
                <span class="native-song-copy"><strong>{track.title}</strong><small>{track.artist}</small></span>
                <span class="native-song-check" class:checked={selectedPlaylist?.track_ids.includes(track.id)}>{addingSongIDs.has(track.id) ? "…" : selectedPlaylist?.track_ids.includes(track.id) ? "✓" : "+"}</span>
              </button>
            {/snippet}
          </VirtualRows>
        </div>
      </MobileSheet>
    {/if}
    <DownloadStatus />
    <audio
      bind:this={audioEl}
      crossorigin="anonymous"
      onended={handleEnded}
      onerror={handleAudioError}
      onloadedmetadata={syncDuration}
      onpause={handleAudioPause}
      onplay={handleAudioPlay}
      ontimeupdate={syncTime}
      onvolumechange={syncMediaVolume}
    ></audio>
  </main>
{/if}
