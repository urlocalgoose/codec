<script lang="ts">
  import { onMount, tick } from "svelte";
  import { invoke } from "@tauri-apps/api/core";
  import { listen } from "@tauri-apps/api/event";
  import { open } from "@tauri-apps/plugin-dialog";
  import {
    AlertCircle,
    Check,
    CloudDownload,
    CloudUpload,
    Disc3,
    FolderOpen,
    Home,
    Library,
    ListPlus,
    ListMusic,
    LoaderCircle,
    Music2,
    Palette,
    Pause,
    Pencil,
    Play,
    RefreshCw,
    Repeat,
    Repeat1,
    Search,
    Server,
    Shuffle,
    SkipBack,
    SkipForward,
    Upload,
    Users,
    Volume2,
    X
  } from "lucide-svelte";
  import {
    createQueue,
    findTrackByReference,
    formatCount,
    formatDuration,
    formatLongDuration,
    likedTracks,
    playbackQueue,
    playlistTracks,
    searchTracks,
    shuffleTracks,
    sortTracks,
    trackReference,
    tracksFromReferences
  } from "$lib/library";
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
  import type {
    AlbumSummary,
    ArtistSummary,
    Library as MusicLibrary,
    LibraryStats,
    Playlist,
    RepeatMode,
    SortKey,
    Track,
    TrackReference
  } from "$lib/types";

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
  const DEFAULT_DESKTOP_MUSIC_ROOT = "/path/to/Documents/Music";
  const DEFAULT_SYNC_SERVER_URL = "http://127.0.0.1:8787";
  const PLAYBACK_SAVE_DELAY_MS = 750;
  const PLAYBACK_DEVICE_SAVE_DELAY_MS = 220;
  const PLAYBACK_DEVICE_POLL_MS = 10000;
  const REMOTE_ROOT_PATH = "loud://sync-server";
  const DEFAULT_STATS: LibraryStats = {
    trackCount: 0,
    playlistCount: 0,
    likedCount: 0,
    artistCount: 0,
    albumCount: 0,
    durationSeconds: 0
  };

  const themes = [
    { id: "oxide", name: "Oxide", swatch: ["#f47b3f", "#242119", "#f5efe2"] },
    { id: "graphite", name: "Graphite", swatch: ["#9ba3a0", "#151817", "#eef2ed"] },
    { id: "cream", name: "Cream", swatch: ["#c56b35", "#eee0be", "#21190f"] },
    { id: "forest", name: "Forest", swatch: ["#72c28f", "#14291f", "#eef7df"] },
    { id: "ember", name: "Ember", swatch: ["#ff6a3d", "#24130f", "#fff0df"] },
    { id: "denim", name: "Denim", swatch: ["#73a7ff", "#101929", "#eef4ff"] },
    { id: "lagoon", name: "Lagoon", swatch: ["#54d4c5", "#0e2426", "#e8fff9"] },
    { id: "berry", name: "Berry", swatch: ["#f277b5", "#241321", "#fff0f8"] },
    { id: "solar", name: "Solar", swatch: ["#f4c542", "#211c0d", "#fff6d6"] },
    { id: "terminal", name: "Terminal", swatch: ["#7dff8a", "#07130b", "#e9ffe8"] },
    { id: "blueprint", name: "Blueprint", swatch: ["#8bb8ff", "#101728", "#f0f5ff"] },
    { id: "candy", name: "Candy", swatch: ["#ff8ac7", "#231522", "#fff3fb"] },
    { id: "coffee", name: "Coffee", swatch: ["#d19a62", "#1f1712", "#f6e8d4"] },
    { id: "orchid", name: "Orchid", swatch: ["#c79bff", "#1d1528", "#f7efff"] },
    { id: "marine", name: "Marine", swatch: ["#5cc8ff", "#0b1c27", "#eaf8ff"] },
    { id: "moss", name: "Moss", swatch: ["#aac96b", "#172112", "#f3f8df"] },
    { id: "ruby", name: "Ruby", swatch: ["#ff646f", "#251215", "#fff0f0"] },
    { id: "paper", name: "Paper", swatch: ["#2f7d5f", "#eee9dc", "#18140f"] },
    { id: "linen", name: "Linen", swatch: ["#466fd1", "#f6eedf", "#1d1912"] },
    { id: "daylight", name: "Daylight", swatch: ["#b46d1d", "#f7fbfd", "#12202a"] },
    { id: "sage-light", name: "Sage Light", swatch: ["#386e53", "#edf3e7", "#172015"] },
    { id: "blush-light", name: "Blush Light", swatch: ["#b94364", "#fff0f1", "#27181b"] },
    { id: "glacier", name: "Glacier", swatch: ["#18798f", "#eff8fa", "#102027"] },
    { id: "lavender-light", name: "Lavender", swatch: ["#7252b3", "#f4effb", "#20172b"] },
    { id: "peach-light", name: "Peach", swatch: ["#a9572f", "#fff0e1", "#24180f"] },
    { id: "mint-light", name: "Mint", swatch: ["#17826e", "#eff8f3", "#122018"] },
    { id: "mono-light", name: "Mono Light", swatch: ["#4b4c47", "#f0f0ea", "#181815"] },
    { id: "butter", name: "Butter", swatch: ["#2e6971", "#faf1ce", "#1f1a0e"] },
    { id: "noir", name: "Noir", swatch: ["#ded6c4", "#090908", "#f4eee2"] },
    { id: "skyline", name: "Skyline", swatch: ["#ffb45c", "#111b2c", "#eef5ff"] },
    { id: "acid", name: "Acid", swatch: ["#d7ff4a", "#111509", "#f6ffd9"] },
    { id: "mixtape", name: "Mixtape", swatch: ["#ff7f50", "#1b1822", "#f4f0ff"] },
    { id: "icebox", name: "Icebox", swatch: ["#76e2ff", "#102225", "#effcff"] }
  ] as const;

  type ThemeId = (typeof themes)[number]["id"];
  type ThemeOption = (typeof themes)[number];
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
  type PersistedPlaybackSession = {
    schema: "loud.playback.v1";
    root_path: string;
    saved_at: number;
    selected_view: string;
    current_track: TrackReference | null;
    queued_tracks: TrackReference[];
    playback_source: TrackReference[];
    playback_index: number;
    play_history: TrackReference[];
    current_time: number;
    audio_duration: number;
  };

  function hasNativeBridge() {
    return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
  }

  function defaultSyncServerUrl(): string {
    if (hasNativeBridge()) {
      return DEFAULT_SYNC_SERVER_URL;
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
  let searchInputEl: HTMLInputElement;
  let playlistNameInputEl: HTMLInputElement;
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
  $: viewSubtitle = subtitleForView(library, selectedView, stats, baseTracks, queue);
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

  onMount(() => {
    rootPath = localStorage.getItem(ROOT_STORAGE_KEY) ?? (hasNativeBridge() ? DEFAULT_DESKTOP_MUSIC_ROOT : "");
    volume = Number(localStorage.getItem(VOLUME_STORAGE_KEY) ?? volume);
    shuffle = localStorage.getItem(SHUFFLE_STORAGE_KEY) === "true";
    repeatMode = (localStorage.getItem(REPEAT_STORAGE_KEY) as RepeatMode | null) ?? "off";
    theme = parseTheme(localStorage.getItem(THEME_STORAGE_KEY));
    syncServerUrl = normalizeServerUrl(
      localStorage.getItem(SYNC_SERVER_STORAGE_KEY) ?? defaultSyncServerUrl()
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
        searchInputEl?.focus();
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

  async function chooseFolder() {
    errorMessage = "";
    if (!hasNativeBridge()) {
      errorMessage = "Open Loud in the Tauri app to choose a music folder.";
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
      errorMessage = "Open Loud in the Tauri app to import a playlist manifest.";
      return;
    }

    if (!rootPath) {
      errorMessage = "Choose a music folder before importing a playlist manifest.";
      return;
    }

    const selected = await open({
      directory: false,
      multiple: false,
      title: "Import Loud playlist manifest",
      filters: [{ name: "Loud import manifest", extensions: ["json"] }]
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
      errorMessage = "Open Loud in the Tauri app to load your music folder.";
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

  function restorePlaybackSession(activeLibrary: MusicLibrary): boolean {
    const session = readPlaybackSession(activeLibrary.root_path);
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

      const localSession = readPlaybackSession(activeLibrary.root_path);
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

  function readPlaybackSession(activeRootPath: string): PersistedPlaybackSession | null {
    const raw = localStorage.getItem(PLAYBACK_SESSION_STORAGE_KEY);
    if (!raw) {
      return null;
    }

    try {
      const session = JSON.parse(raw) as Partial<PersistedPlaybackSession>;
      if (session.schema !== "loud.playback.v1" || session.root_path !== activeRootPath) {
        return null;
      }

      return {
        schema: "loud.playback.v1",
        root_path: session.root_path,
        saved_at: Number(session.saved_at) || 0,
        selected_view: typeof session.selected_view === "string" ? session.selected_view : "home",
        current_track: validTrackReference(session.current_track) ? session.current_track : null,
        queued_tracks: validTrackReferences(session.queued_tracks),
        playback_source: validTrackReferences(session.playback_source),
        playback_index: Number(session.playback_index) || 0,
        play_history: validTrackReferences(session.play_history),
        current_time: Number(session.current_time) || 0,
        audio_duration: Number(session.audio_duration) || 0
      };
    } catch {
      return null;
    }
  }

  function validTrackReference(value: unknown): value is TrackReference {
    if (!value || typeof value !== "object") {
      return false;
    }

    const candidate = value as Record<string, unknown>;
    return (
      typeof candidate.id === "string" &&
      typeof candidate.path === "string" &&
      typeof candidate.fingerprint === "string"
    );
  }

  function validTrackReferences(value: unknown): TrackReference[] {
    return Array.isArray(value) ? value.filter(validTrackReference) : [];
  }

  function validPlaybackSession(value: unknown): value is PersistedPlaybackSession {
    if (!value || typeof value !== "object") {
      return false;
    }

    const candidate = value as Partial<PersistedPlaybackSession>;
    return candidate.schema === "loud.playback.v1" && typeof candidate.saved_at === "number";
  }

  function isKnownView(activeLibrary: MusicLibrary, view: string): boolean {
    return (
      ["home", "all", "liked", "artists", "albums", "queue"].includes(view) ||
      activeLibrary.playlists.some((playlist) => playlist.id === view)
    );
  }

  function clampIndex(index: number, length: number): number {
    if (length <= 0) {
      return 0;
    }

    return Math.max(0, Math.min(Math.trunc(index), length - 1));
  }

  function clampPlaybackTime(time: number, track: Track | null): number {
    const duration = track?.duration_seconds;
    const safeTime = Number.isFinite(time) && time > 0 ? time : 0;
    return duration && duration > 0 ? Math.min(safeTime, Math.max(duration - 1, 0)) : safeTime;
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

  function createDeviceId(): string {
    const random =
      typeof crypto !== "undefined" && "randomUUID" in crypto
        ? crypto.randomUUID()
        : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    return `device-${random}`;
  }

  function defaultDeviceName(): string {
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

  function isRemoteRoot(path: string): boolean {
    return path.startsWith("loud://");
  }

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

  function usePlaybackSync(): boolean {
    return Boolean(syncServerUrl && syncServerReady && deviceId);
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

  function selectView(view: string) {
    cancelPlaylistRename();
    selectedView = view;
    searchQuery = "";
    sortKey = "default";
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

  function openSyncServerModal() {
    syncServerDraft = syncServerUrl;
    syncServerModalOpen = true;
  }

  function closeSyncServerModal() {
    syncServerModalOpen = false;
  }

  function handleSyncServerModalBackdropClick(event: MouseEvent) {
    if (event.target === event.currentTarget) {
      closeSyncServerModal();
    }
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

  function handleThemeModalBackdropClick(event: MouseEvent) {
    if (event.target === event.currentTarget) {
      closeThemeModal();
    }
  }

  function parseTheme(value: string | null): ThemeId {
    return themes.some((option) => option.id === value) ? (value as ThemeId) : "oxide";
  }

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

  function handleTrackRowKeydown(event: KeyboardEvent, track: Track, index: number) {
    if (event.key !== "Enter" && event.key !== " ") {
      return;
    }

    event.preventDefault();
    void playTrackRow(track, index);
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

  function startPlaylistRename(playlist: Playlist) {
    editingPlaylistId = playlist.id;
    playlistNameDraft = playlist.name;

    void tick().then(() => {
      playlistNameInputEl?.focus();
      playlistNameInputEl?.select();
    });
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

  function handlePlaylistModalBackdropClick(event: MouseEvent) {
    if (event.target === event.currentTarget) {
      closePlaylistMembershipModal();
    }
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

  function handlePlaylistNameKeydown(event: KeyboardEvent) {
    if (event.key === "Enter") {
      event.preventDefault();
      void commitPlaylistRename();
    }

    if (event.key === "Escape") {
      event.preventDefault();
      cancelPlaylistRename();
    }
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

  function trackSourceForView(
    activeLibrary: MusicLibrary | null,
    activeView: string,
    activePlaylist: Playlist | null,
    activeQueue: Track[]
  ): Track[] {
    if (!activeLibrary) {
      return [];
    }

    if (activeView === "all") {
      return activeLibrary.tracks;
    }

    if (activeView === "liked") {
      return likedTracks(activeLibrary);
    }

    if (activeView === "queue") {
      return activeQueue;
    }

    if (activeView === "home") {
      return sortTracks(activeLibrary.tracks, "added").slice(0, 32);
    }

    if (activePlaylist) {
      return playlistTracks(activeLibrary, activePlaylist);
    }

    return activeLibrary.tracks;
  }

  function titleForView(activeView: string, activePlaylist: Playlist | null): string {
    if (activePlaylist) {
      return activePlaylist.name;
    }

    switch (activeView) {
      case "all":
        return "All Songs";
      case "liked":
        return "Liked Songs";
      case "artists":
        return "Artists";
      case "albums":
        return "Albums";
      case "queue":
        return "Queue";
      case "home":
      default:
        return "Home";
    }
  }

  function subtitleForView(
    activeLibrary: MusicLibrary | null,
    activeView: string,
    activeStats: LibraryStats,
    activeTracks: Track[],
    activeQueue: Track[]
  ): string {
    if (!activeLibrary) {
      return "";
    }

    if (activeView === "home") {
      return `${formatCount(activeStats.trackCount, "track")} across ${formatCount(
        activeStats.playlistCount,
        "playlist"
      )}`;
    }

    if (activeView === "queue") {
      return "";
    }

    return "";
  }

  function metaForTrackList(
    activeView: string,
    activeStats: LibraryStats,
    tracks: Track[],
    durationSeconds: number,
    manualQueue: Track[]
  ): string {
    if (activeView === "home") {
      return `${formatCount(activeStats.trackCount, "track")} · ${formatCount(
        activeStats.playlistCount,
        "playlist"
      )} · ${formatCount(activeStats.likedCount, "liked track")} · ${formatLongDuration(
        activeStats.durationSeconds
      )}`;
    }

    if (activeView === "queue") {
      return `${formatCount(tracks.length, "track")} · ${formatCount(
        manualQueue.length,
        "manual queue item"
      )}`;
    }

    return `${formatCount(tracks.length, "track")} · ${formatLongDuration(durationSeconds)}`;
  }

  function isUnsupportedMediaError(error: unknown, mediaError: MediaError | null): boolean {
    const message = error instanceof Error ? error.message : String(error);
    return mediaError?.code === MediaError.MEDIA_ERR_SRC_NOT_SUPPORTED || message.includes("not supported");
  }

  function mediaErrorMessage(error: unknown, mediaError: MediaError | null = null): string {
    const message = error instanceof Error ? error.message : String(error);

    if (isUnsupportedMediaError(error, mediaError)) {
      return "Could not play that file. The Rust media stream was rejected by the WebView.";
    }

    if (mediaError) {
      const details =
        mediaError.code === MediaError.MEDIA_ERR_ABORTED
          ? "Playback was aborted."
          : mediaError.code === MediaError.MEDIA_ERR_NETWORK
            ? "The local file could not be read."
            : mediaError.code === MediaError.MEDIA_ERR_DECODE
              ? "The MP3 could not be decoded."
              : "The media file is not supported.";
      return `${details} ${message}`;
    }

    return message;
  }
</script>

<svelte:head>
  <title>Loud</title>
</svelte:head>

{#if !library && !loading}
  <main class="setup-screen" data-theme={theme}>
    <section class="setup-panel" class:web-setup={!hasNativeBridge()} aria-labelledby="setup-title">
      <div class="brand-row">
        <span class="brand-mark"><Music2 size={32} /></span>
        <span>Loud</span>
      </div>
      {#if hasNativeBridge()}
        <span class="setup-mode">Desktop</span>
        <h1 id="setup-title">Local music, folder-first.</h1>
        <p>
          Pick a music folder, or connect to a Loud sync server to push and pull real MP3 files.
        </p>
      {:else}
        <span class="setup-mode">Mobile / Web</span>
        <h1 id="setup-title">Connect to Loud.</h1>
        <p>
          Use the same Loud app from the server that stores your library, playback, and queue.
        </p>
      {/if}
      {#if hasNativeBridge()}
        <div class="setup-actions">
          <button class="primary-action" type="button" onclick={chooseFolder}>
            <FolderOpen size={18} />
            Open Music Folder
          </button>
        </div>
      {/if}
      <div class="setup-sync-card">
        <div class="setup-sync-copy">
          <strong>Sync Server</strong>
          <span>{hasNativeBridge() ? "Use this desktop as a client or uploader." : "Paste the URL printed by the server."}</span>
        </div>
        <div class="setup-sync">
          <label class="sync-url-field">
            <Server size={17} />
            <input
              bind:value={syncServerDraft}
              placeholder="http://192.168.1.20:8787"
              type="url"
            />
          </label>
          <button class="primary-action" disabled={loading || !syncServerDraft.trim()} type="button" onclick={() => loadRemoteLibrary(false)}>
            {#if loading}
              <LoaderCircle class="spin-icon" size={18} />
            {:else}
              <CloudDownload size={18} />
            {/if}
            Connect
          </button>
        </div>
      </div>
      {#if errorMessage}
        <p class="setup-error"><AlertCircle size={16} /> {errorMessage}</p>
      {/if}
    </section>
  </main>
{:else}
  <main class="app-shell" data-theme={theme}>
    <aside class="sidebar" aria-label="Library navigation">
      <nav class="nav-stack" aria-label="Primary">
        <button aria-label="Home" class:active={selectedView === "home"} title="Home" type="button" onclick={() => selectView("home")}>
          <Home size={18} />
          <span>Home</span>
        </button>
        <button aria-label="All Songs" class:active={selectedView === "all"} title="All Songs" type="button" onclick={() => selectView("all")}>
          <Library size={18} />
          <span>All Songs</span>
        </button>
        <button aria-label="Liked Songs" class:active={selectedView === "liked"} title="Liked Songs" type="button" onclick={() => selectView("liked")}>
          <Check size={18} />
          <span>Liked Songs</span>
        </button>
        <button aria-label="Artists" class:active={selectedView === "artists"} title="Artists" type="button" onclick={() => selectView("artists")}>
          <Users size={18} />
          <span>Artists</span>
        </button>
        <button aria-label="Albums" class:active={selectedView === "albums"} title="Albums" type="button" onclick={() => selectView("albums")}>
          <Disc3 size={18} />
          <span>Albums</span>
        </button>
        <button aria-label="Queue" class:active={selectedView === "queue"} title="Queue" type="button" onclick={() => selectView("queue")}>
          <ListMusic size={18} />
          <span>Queue</span>
        </button>
      </nav>

      <section class="playlist-nav" aria-label="Playlists">
        <div class="section-label">
          <span>Playlists</span>
        </div>
        <div class="playlist-scroll">
          {#each userPlaylists as playlist (playlist.id)}
            <button
              class:active={selectedView === playlist.id}
              type="button"
              onclick={() => selectView(playlist.id)}
            >
              <span>{playlist.name}</span>
              <small>{playlist.track_ids.length}</small>
            </button>
          {/each}
        </div>
      </section>

      <section class="theme-nav" aria-label="Themes">
        <div class="section-label">
          <span>Theme</span>
        </div>
        <button class="theme-open-button" type="button" onclick={openThemeModal}>
          <Palette size={18} />
          <span>{activeTheme.name}</span>
        </button>
      </section>

      <section class="sync-nav" aria-label="Sync">
        <div class="section-label">
          <span>Sync</span>
        </div>
        <label class="sync-url-field compact">
          <Server size={16} />
          <input bind:value={syncServerDraft} placeholder="Server URL" type="url" />
        </label>
        <div class="sync-actions">
          <button
            class="ui-button compact"
            disabled={syncing || !library}
            title="Upload this library to the sync server"
            aria-label="Upload this library to the sync server"
            type="button"
            onclick={syncToServer}
          >
            {#if syncing}
              <LoaderCircle class="spin-icon" size={16} />
            {:else}
              <CloudUpload size={16} />
            {/if}
          </button>
          <button
            class="ui-button compact"
            disabled={syncing}
            title="Pull library from the sync server"
            aria-label="Pull library from the sync server"
            type="button"
            onclick={syncFromServer}
          >
            <CloudDownload size={16} />
          </button>
        </div>
        {#if syncMessage}
          <small class="sync-status">{syncMessage}</small>
        {/if}
      </section>
    </aside>

    <section class="content">
      <header class="topbar">
        <label class="search-box" aria-label="Search library">
          <Search size={18} />
          <input
            bind:this={searchInputEl}
            bind:value={searchQuery}
            placeholder="Search"
            type="search"
          />
          {#if searchQuery}
            <button title="Clear search" aria-label="Clear search" type="button" onclick={() => (searchQuery = "")}>
              <X size={16} />
            </button>
          {/if}
        </label>

        <div class="topbar-actions">
          <button title="Sync server" aria-label="Sync server" type="button" onclick={openSyncServerModal}>
            <Server size={18} />
          </button>
          <button
            disabled={importing || isRemoteRoot(rootPath)}
            title="Import playlist manifest"
            aria-label="Import playlist manifest"
            type="button"
            onclick={chooseImportManifest}
          >
            {#if importing}
              <LoaderCircle class="spin-icon" size={18} />
            {:else}
              <Upload size={18} />
            {/if}
          </button>
          <button title="Refresh library" aria-label="Refresh library" type="button" onclick={refreshActiveLibrary}>
            <RefreshCw size={18} />
          </button>
        </div>
      </header>

      {#if loading}
        <section class="loading-state">
          <LoaderCircle class="spin-icon" size={34} />
          <p>Reading music folder</p>
        </section>
      {:else if library}
        <section class="view-header">
          <div class="view-heading">
            {#if selectedPlaylist && isEditingSelectedPlaylist}
              <form
                class="title-edit"
                onsubmit={(event) => {
                  event.preventDefault();
                  void commitPlaylistRename();
                }}
              >
                <input
                  bind:this={playlistNameInputEl}
                  bind:value={playlistNameDraft}
                  class="playlist-title-input"
                  disabled={renamingPlaylist}
                  aria-label="Playlist title"
                  maxlength="96"
                  onkeydown={handlePlaylistNameKeydown}
                />
                <button
                  class="title-icon-button primary"
                  disabled={renamingPlaylist}
                  title="Save playlist title"
                  aria-label="Save playlist title"
                  type="submit"
                >
                  {#if renamingPlaylist}
                    <LoaderCircle class="spin-icon" size={17} />
                  {:else}
                    <Check size={18} />
                  {/if}
                </button>
                <button
                  class="title-icon-button"
                  disabled={renamingPlaylist}
                  title="Cancel rename"
                  aria-label="Cancel rename"
                  type="button"
                  onclick={cancelPlaylistRename}
                >
                  <X size={18} />
                </button>
              </form>
            {:else}
              <div class="title-row">
                <h1>{viewTitle}</h1>
                {#if selectedPlaylist && !selectedPlaylist.is_liked}
                  <button
                    class="title-icon-button"
                    title="Edit playlist title"
                    aria-label="Edit playlist title"
                    type="button"
                    onclick={() => startPlaylistRename(selectedPlaylist)}
                  >
                    <Pencil size={17} />
                  </button>
                {/if}
              </div>
            {/if}
            <p>{viewSubtitle}</p>
          </div>
        </section>

        {#if errorMessage}
          <section class="error-strip"><AlertCircle size={17} /> {errorMessage}</section>
        {/if}

        {#if selectedView === "artists"}
          <section class="summary-grid artists-grid" aria-label="Artists">
            {#each artists as artist (artist.name)}
              <button class="summary-card" type="button" onclick={() => { selectedView = "all"; searchQuery = artist.name; }}>
                <span class="summary-icon"><Users size={22} /></span>
                <strong>{artist.name}</strong>
                <span>{formatCount(artist.trackCount, "track")} · {formatCount(artist.albumCount, "album")}</span>
              </button>
            {/each}
          </section>
        {:else if selectedView === "albums"}
          <section class="summary-grid" aria-label="Albums">
            {#each albums as album (`${album.artist}-${album.name}`)}
              <button class="summary-card album-card" type="button" onclick={() => { selectedView = "all"; searchQuery = album.name; }}>
                {#if album.artwork_url}
                  <img class="summary-art" src={album.artwork_url} alt="" loading="lazy" decoding="async" />
                {:else}
                  <span class="summary-icon"><Disc3 size={24} /></span>
                {/if}
                <strong>{album.name}</strong>
                <span>{album.artist} · {formatCount(album.trackCount, "track")}</span>
              </button>
            {/each}
          </section>
        {/if}

        {#if selectedView !== "artists" && selectedView !== "albums"}
          <section class="track-surface" aria-label="Tracks">
            <div class="list-toolbar" aria-label={`${viewTitle} actions`}>
              <div class="list-meta">
                <span>{listMeta}</span>
              </div>
              <div class="list-actions">
                {#if selectedView === "queue"}
                  <button
                    class="ui-button compact"
                    disabled={queuedTracks.length === 0}
                    type="button"
                    onclick={clearQueuedTracks}
                  >
                    Clear
                  </button>
                {:else}
                  <button
                    class="ui-button primary compact"
                    disabled={visibleTracks.length === 0}
                    type="button"
                    onclick={() => playTrackSet(visibleTracks)}
                  >
                    <Play size={16} />
                    Play
                  </button>
                  <button
                    class="ui-button compact"
                    disabled={visibleTracks.length === 0}
                    type="button"
                    onclick={() => playTrackSet(visibleTracks, true)}
                  >
                    <Shuffle size={16} />
                    Shuffle
                  </button>
                {/if}
              </div>
            </div>
            {#if visibleTracks.length > 0}
              <div class="track-table">
                <div class="track-head">
                  <button
                    class:active={sortKey === "title"}
                    type="button"
                    onclick={() => setTableSort("title")}
                  >
                    Song
                  </button>
                  <button
                    class:active={sortKey === "album"}
                    type="button"
                    onclick={() => setTableSort("album")}
                  >
                    Album
                  </button>
                  <button
                    class:active={sortKey === "duration"}
                    type="button"
                    onclick={() => setTableSort("duration")}
                  >
                    Time
                  </button>
                  <span></span>
                </div>

                {#each visibleTracks as track, index (track.id)}
                  <div
                    class="track-row"
                    class:active={currentTrack?.id === track.id}
                    role="button"
                    tabindex="0"
                    aria-label={currentTrack?.id === track.id && isPlaying ? `Pause ${track.title}` : `Play ${track.title}`}
                    onclick={() => playTrackRow(track, index)}
                    onkeydown={(event) => handleTrackRowKeydown(event, track, index)}
                  >
                    <div class="track-title-cell">
                      {#if track.artwork_url}
                        <img class="artwork" src={track.artwork_url} alt="" loading="lazy" decoding="async" />
                      {:else}
                        <span class="artwork placeholder"><Music2 size={18} /></span>
                      {/if}
                      <div>
                        <strong>{track.title}</strong>
                        <span>{track.artist}</span>
                      </div>
                    </div>

                    <span class="table-album">{track.album}</span>
                    <span class="table-duration">{formatDuration(track.duration_seconds)}</span>
                    {#if selectedView === "queue"}
                      {#if index > 0 && index <= queuedTracks.length}
                        <button
                          class="queue-button"
                          title={`Remove ${track.title} from queue`}
                          aria-label={`Remove ${track.title} from queue`}
                          type="button"
                          onclick={(event) => {
                            event.stopPropagation();
                            removeQueuedTrackAt(index);
                          }}
                        >
                          <X size={17} />
                        </button>
                      {:else}
                        <span></span>
                      {/if}
                    {:else}
                      <button
                        class="queue-button"
                        title={`Edit playlists for ${track.title}`}
                        aria-label={`Edit playlists for ${track.title}`}
                        type="button"
                        onclick={(event) => {
                          event.stopPropagation();
                          openPlaylistMembershipModal(track);
                        }}
                      >
                        <ListPlus size={17} />
                      </button>
                    {/if}
                  </div>
                {/each}
              </div>
            {:else}
              <div class="empty-state">
                <Music2 size={32} />
                <p>No tracks here.</p>
              </div>
            {/if}
          </section>
        {/if}
      {/if}
    </section>

    <footer class="player" aria-label="Player">
      <div class="now-playing">
        {#if currentTrack}
          {#if currentTrack.artwork_url}
            <img class="player-art" src={currentTrack.artwork_url} alt="" />
          {:else}
            <span class="player-art placeholder"><Music2 size={20} /></span>
          {/if}
          <div>
            <strong>{currentTrack.title}</strong>
            <span>{currentTrack.artist}</span>
          </div>
        {:else}
          <span class="player-art placeholder"><Music2 size={20} /></span>
          <div>
            <strong>Nothing playing</strong>
            <span>Select a track</span>
          </div>
        {/if}
      </div>

      <div class="transport">
        <div class="transport-buttons">
          <button class:active={shuffle} title="Shuffle" aria-label="Shuffle" aria-pressed={shuffle} type="button" onclick={toggleShuffle}>
            <Shuffle size={17} />
          </button>
          <button title="Previous" aria-label="Previous" type="button" onclick={previousTrack}>
            <SkipBack size={20} />
          </button>
          <button class="play-button" class:active={isPlaying} title={isPlaying ? "Pause" : "Play"} aria-label={isPlaying ? "Pause" : "Play"} aria-pressed={isPlaying} type="button" onclick={togglePlayback}>
            {#if isPlaying}
              <Pause size={24} />
            {:else}
              <Play size={24} />
            {/if}
          </button>
          <button title="Next" aria-label="Next" type="button" onclick={nextTrack}>
            <SkipForward size={20} />
          </button>
          <button class:active={repeatMode !== "off"} title="Repeat" aria-label="Repeat" aria-pressed={repeatMode !== "off"} type="button" onclick={toggleRepeat}>
            {#if repeatMode === "one"}
              <Repeat1 size={17} />
            {:else}
              <Repeat size={17} />
            {/if}
          </button>
        </div>

        <div class="progress-row">
          <span>{formatDuration(currentTime)}</span>
          <input
            aria-label="Seek"
            disabled={!currentTrack}
            max={Math.max(audioDuration || currentTrack?.duration_seconds || 1, 1)}
            min="0"
            step="0.1"
            type="range"
            value={currentTime}
            oninput={setProgress}
          />
          <span>{formatDuration(audioDuration || currentTrack?.duration_seconds)}</span>
        </div>
      </div>

      <div class="player-side">
        <label class="volume-control" aria-label="Volume">
          <Volume2 size={18} />
          <input max="1" min="0" step="0.01" type="range" value={volume} oninput={updateVolume} />
        </label>

        {#if syncServerUrl && syncServerReady && deviceId}
          <label class="device-control" aria-label={`Playback device. Playing on ${activePlaybackDeviceName}`}>
            <span>Playing on</span>
            <select value={activePlaybackDeviceId} onchange={handlePlaybackDeviceChange}>
              {#each playbackDeviceOptions as device (device.device_id)}
                <option value={device.device_id}>
                  {device.device_id === deviceId ? `${device.name} (this)` : device.name}
                </option>
              {/each}
            </select>
          </label>
        {/if}
      </div>
    </footer>

    {#if syncServerModalOpen}
      <div
        class="modal-backdrop"
        role="presentation"
        onclick={handleSyncServerModalBackdropClick}
      >
        <div
          class="app-modal sync-server-modal"
          role="dialog"
          aria-label="Sync server"
          aria-modal="true"
        >
          <header class="modal-header">
            <div>
              <span>Sync</span>
              <h2>Sync Server</h2>
              <p>{syncServerUrl || "Not connected"}</p>
            </div>
            <button
              class="title-icon-button"
              title="Close"
              aria-label="Close sync server"
              type="button"
              onclick={closeSyncServerModal}
            >
              <X size={18} />
            </button>
          </header>

          <form
            class="sync-server-form"
            onsubmit={(event) => {
              event.preventDefault();
              void applySyncServerChange();
            }}
          >
            <label class="sync-url-field modal-field">
              <Server size={17} />
              <input
                bind:value={syncServerDraft}
                placeholder="http://192.168.1.20:8787"
                type="url"
              />
            </label>
            <p class="sync-server-help">
              On phone, use the network address printed by the sync server, not localhost.
            </p>

            <footer class="modal-actions">
              <button class="ui-button compact" type="button" onclick={disconnectSyncServer}>
                Disconnect
              </button>
              <button class="ui-button compact" type="button" onclick={closeSyncServerModal}>
                Cancel
              </button>
              <button class="ui-button primary compact" type="submit">
                Connect
              </button>
            </footer>
          </form>
        </div>
      </div>
    {/if}

    {#if playlistModalTrack && library}
      <div
        class="modal-backdrop"
        role="presentation"
        onclick={handlePlaylistModalBackdropClick}
      >
        <div
          class="app-modal playlist-modal"
          role="dialog"
          aria-label={`Edit playlists for ${playlistModalTrack.title}`}
          aria-modal="true"
        >
          <header class="modal-header">
            <div>
              <span>Playlists</span>
              <h2>{playlistModalTrack.title}</h2>
              <p>{playlistModalTrack.artist}</p>
            </div>
            <button
              class="title-icon-button"
              title="Close"
              aria-label="Close playlist editor"
              type="button"
              onclick={closePlaylistMembershipModal}
            >
              <X size={18} />
            </button>
          </header>

          <div class="playlist-choice-list">
            {#each library.playlists as playlist (playlist.id)}
              {@const playlistSelected = playlistModalSelectionIds.includes(playlist.id)}
              <label class="playlist-choice" class:active={playlistSelected}>
                <input
                  bind:group={playlistModalSelectionIds}
                  type="checkbox"
                  value={playlist.id}
                />
                <span class="choice-box">
                  {#if playlistSelected}
                    <Check size={15} />
                  {/if}
                </span>
                <span class="choice-copy">
                  <strong>{playlist.is_liked ? "Liked Songs" : playlist.name}</strong>
                  <small>{formatCount(playlist.track_ids.length, "track")}</small>
                </span>
              </label>
            {/each}
          </div>

          <footer class="modal-actions">
            <button class="ui-button compact" type="button" onclick={closePlaylistMembershipModal}>
              Cancel
            </button>
            <button
              class="ui-button primary compact"
              disabled={savingPlaylistMemberships}
              type="button"
              onclick={savePlaylistMemberships}
            >
              {savingPlaylistMemberships ? "Saving" : "Save"}
            </button>
          </footer>
        </div>
      </div>
    {/if}

    {#if themeModalOpen}
      <div
        class="modal-backdrop"
        role="presentation"
        onclick={handleThemeModalBackdropClick}
      >
        <div
          class="app-modal theme-modal"
          role="dialog"
          aria-label="Choose theme"
          aria-modal="true"
        >
          <header class="modal-header">
            <div>
              <span>Theme</span>
              <h2>Choose Theme</h2>
              <p>{activeTheme.name}</p>
            </div>
            <button
              class="title-icon-button"
              title="Close"
              aria-label="Close theme picker"
              type="button"
              onclick={closeThemeModal}
            >
              <X size={18} />
            </button>
          </header>

          <div class="theme-grid">
            {#each themes as option (option.id)}
              <button
                class="theme-choice"
                class:active={theme === option.id}
                type="button"
                aria-pressed={theme === option.id}
                onclick={() => setTheme(option.id)}
              >
                <span
                  class="theme-swatch"
                  style={`--a:${option.swatch[0]}; --b:${option.swatch[1]}; --c:${option.swatch[2]};`}
                ></span>
                <span>{option.name}</span>
                {#if theme === option.id}
                  <Check size={16} />
                {/if}
              </button>
            {/each}
          </div>

          <footer class="modal-actions">
            <button class="ui-button primary compact" type="button" onclick={closeThemeModal}>
              Done
            </button>
          </footer>
        </div>
      </div>
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

<style>
  :global(:root) {
    --font-app: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    --color-bg: #100f0c;
    --color-panel: #181610;
    --color-panel-2: #211e17;
    --color-surface: #2b271e;
    --color-surface-hover: #373226;
    --color-border: rgba(245, 239, 226, 0.08);
    --color-border-strong: rgba(245, 239, 226, 0.12);
    --color-line: rgba(245, 239, 226, 0.06);
    --color-line-strong: rgba(245, 239, 226, 0.1);
    --color-text: #f5efe2;
    --color-muted: #bbb3a2;
    --color-subtle: #8f8879;
    --color-accent: #f47b3f;
    --color-accent-hover: #ff9b61;
    --color-danger: #ff8065;
    --color-label: #ebe0c8;
    --color-accent-soft: color-mix(in srgb, var(--color-accent) 14%, transparent);
    --color-danger-soft: color-mix(in srgb, var(--color-danger) 14%, transparent);
    --color-glint: rgba(255, 255, 255, 0.04);
    --color-shadow-strong: rgba(0, 0, 0, 0.38);
    --button-bg: #242119;
    --button-bg-hover: #302c22;
    --button-bg-active: #3b3023;
    --button-shadow: rgba(0, 0, 0, 0.32);
    --button-shadow-rest:
      inset 0 -5px 0 var(--button-shadow),
      inset 0 1px 0 var(--color-glint);
    --button-shadow-pressed: inset 0 -1px 0 var(--button-shadow);
    --button-shadow-latched: inset 0 -1px 0 var(--button-shadow);
    --icon-inset-shadow:
      drop-shadow(0 -1px 0 rgba(0, 0, 0, 0.34))
      drop-shadow(0 1px 0 rgba(255, 255, 255, 0.08));
    --icon-inset-shadow-primary:
      drop-shadow(0 -1px 0 rgba(0, 0, 0, 0.3))
      drop-shadow(0 1px 0 rgba(255, 255, 255, 0.16));
    --button-hover-y: 1px;
    --button-press-y: 5px;
    --button-latched-y: 4px;
    --button-primary-text: #130f0a;
    --radius-sm: 3px;
    --radius-md: 4px;
    --radius-button: 3px;
    --control-h: 38px;
    --space-1: 4px;
    --space-2: 8px;
    --space-3: 12px;
    --space-4: 16px;
    --space-5: 20px;
  }

  :global([data-theme="graphite"]) {
    --color-bg: #101312;
    --color-panel: #151917;
    --color-panel-2: #1e2421;
    --color-surface: #2a312e;
    --color-surface-hover: #35403b;
    --color-border: rgba(238, 242, 237, 0.08);
    --color-border-strong: rgba(238, 242, 237, 0.13);
    --color-line: rgba(238, 242, 237, 0.06);
    --color-line-strong: rgba(238, 242, 237, 0.11);
    --color-text: #eef2ed;
    --color-muted: #b6beb8;
    --color-subtle: #7f8983;
    --color-accent: #a7b0aa;
    --color-accent-hover: #d6ddd8;
    --color-danger: #d6867b;
    --color-label: #dde4d8;
    --button-bg: #252b28;
    --button-bg-hover: #303835;
    --button-bg-active: #3b4640;
    --button-primary-text: #0e1110;
  }

  :global([data-theme="cream"]) {
    --color-bg: #20170f;
    --color-panel: #2a2117;
    --color-panel-2: #3a2b1c;
    --color-surface: #463524;
    --color-surface-hover: #57412b;
    --color-border: rgba(255, 242, 207, 0.1);
    --color-border-strong: rgba(255, 242, 207, 0.16);
    --color-line: rgba(255, 242, 207, 0.07);
    --color-line-strong: rgba(255, 242, 207, 0.12);
    --color-text: #fff2cf;
    --color-muted: #d8c59b;
    --color-subtle: #a89468;
    --color-accent: #c56b35;
    --color-accent-hover: #e18145;
    --color-danger: #a94435;
    --color-label: #fff2cf;
    --button-bg: #3c2e20;
    --button-bg-hover: #4c3927;
    --button-bg-active: #5d442d;
    --button-primary-text: #160d07;
  }

  :global([data-theme="forest"]) {
    --color-bg: #0f2018;
    --color-panel: #14291f;
    --color-panel-2: #1b3929;
    --color-surface: #284936;
    --color-surface-hover: #335b44;
    --color-border: rgba(238, 247, 223, 0.09);
    --color-border-strong: rgba(238, 247, 223, 0.14);
    --color-line: rgba(238, 247, 223, 0.065);
    --color-line-strong: rgba(238, 247, 223, 0.12);
    --color-text: #eef7df;
    --color-muted: #bbd1b1;
    --color-subtle: #83a17e;
    --color-accent: #72c28f;
    --color-accent-hover: #9ae1b0;
    --color-danger: #ff8f7f;
    --color-label: #e6f2ce;
    --button-bg: #213f2f;
    --button-bg-hover: #2b523d;
    --button-bg-active: #356848;
    --button-primary-text: #07150d;
  }

  :global([data-theme="ember"]) {
    --color-bg: #160d0a;
    --color-panel: #21130f;
    --color-panel-2: #2c1811;
    --color-surface: #3a2016;
    --color-surface-hover: #4b291c;
    --color-border: rgba(255, 240, 223, 0.09);
    --color-border-strong: rgba(255, 240, 223, 0.14);
    --color-line: rgba(255, 240, 223, 0.06);
    --color-line-strong: rgba(255, 240, 223, 0.11);
    --color-text: #fff0df;
    --color-muted: #d5b8a5;
    --color-subtle: #9f8070;
    --color-accent: #ff6a3d;
    --color-accent-hover: #ff966f;
    --color-danger: #ff756b;
    --color-label: #ffe2c7;
    --button-bg: #342016;
    --button-bg-hover: #44281b;
    --button-bg-active: #57301f;
    --button-primary-text: #180a05;
  }

  :global([data-theme="denim"]) {
    --color-bg: #0d1422;
    --color-panel: #101929;
    --color-panel-2: #17243a;
    --color-surface: #21334f;
    --color-surface-hover: #2b4265;
    --color-border: rgba(238, 244, 255, 0.09);
    --color-border-strong: rgba(238, 244, 255, 0.14);
    --color-line: rgba(238, 244, 255, 0.06);
    --color-line-strong: rgba(238, 244, 255, 0.11);
    --color-text: #eef4ff;
    --color-muted: #b8c8e5;
    --color-subtle: #8191b0;
    --color-accent: #73a7ff;
    --color-accent-hover: #9fc4ff;
    --color-danger: #ff8079;
    --color-label: #e8f1ff;
    --button-bg: #1d2c44;
    --button-bg-hover: #273a58;
    --button-bg-active: #33496b;
    --button-primary-text: #07101f;
  }

  :global([data-theme="lagoon"]) {
    --color-bg: #0a1819;
    --color-panel: #0e2426;
    --color-panel-2: #143235;
    --color-surface: #1d4548;
    --color-surface-hover: #28585d;
    --color-border: rgba(232, 255, 249, 0.09);
    --color-border-strong: rgba(232, 255, 249, 0.14);
    --color-line: rgba(232, 255, 249, 0.06);
    --color-line-strong: rgba(232, 255, 249, 0.11);
    --color-text: #e8fff9;
    --color-muted: #afd9d2;
    --color-subtle: #78a49e;
    --color-accent: #54d4c5;
    --color-accent-hover: #83f2e5;
    --color-danger: #ff857d;
    --color-label: #d9fff6;
    --button-bg: #193b3e;
    --button-bg-hover: #224e52;
    --button-bg-active: #2e6267;
    --button-primary-text: #041716;
  }

  :global([data-theme="berry"]) {
    --color-bg: #160d15;
    --color-panel: #241321;
    --color-panel-2: #311a2e;
    --color-surface: #43243d;
    --color-surface-hover: #572d50;
    --color-border: rgba(255, 240, 248, 0.09);
    --color-border-strong: rgba(255, 240, 248, 0.14);
    --color-line: rgba(255, 240, 248, 0.06);
    --color-line-strong: rgba(255, 240, 248, 0.11);
    --color-text: #fff0f8;
    --color-muted: #ddb8d0;
    --color-subtle: #a47a99;
    --color-accent: #f277b5;
    --color-accent-hover: #ff9fd0;
    --color-danger: #ff7d7d;
    --color-label: #ffe0f0;
    --button-bg: #392033;
    --button-bg-hover: #4a2843;
    --button-bg-active: #5f3355;
    --button-primary-text: #180714;
  }

  :global([data-theme="solar"]) {
    --color-bg: #171407;
    --color-panel: #211c0d;
    --color-panel-2: #2d2510;
    --color-surface: #403414;
    --color-surface-hover: #534419;
    --color-border: rgba(255, 246, 214, 0.1);
    --color-border-strong: rgba(255, 246, 214, 0.15);
    --color-line: rgba(255, 246, 214, 0.07);
    --color-line-strong: rgba(255, 246, 214, 0.12);
    --color-text: #fff6d6;
    --color-muted: #dbc888;
    --color-subtle: #a18e58;
    --color-accent: #f4c542;
    --color-accent-hover: #ffe06d;
    --color-danger: #ff785f;
    --color-label: #fff0b8;
    --button-bg: #362b12;
    --button-bg-hover: #483816;
    --button-bg-active: #5b471b;
    --button-primary-text: #171100;
  }

  :global([data-theme="terminal"]) {
    --color-bg: #050a06;
    --color-panel: #07130b;
    --color-panel-2: #0d1c10;
    --color-surface: #142b18;
    --color-surface-hover: #1b3a20;
    --color-border: rgba(233, 255, 232, 0.08);
    --color-border-strong: rgba(233, 255, 232, 0.13);
    --color-line: rgba(233, 255, 232, 0.055);
    --color-line-strong: rgba(233, 255, 232, 0.1);
    --color-text: #e9ffe8;
    --color-muted: #add9ae;
    --color-subtle: #72a776;
    --color-accent: #7dff8a;
    --color-accent-hover: #a9ffb1;
    --color-danger: #ff6f6f;
    --color-label: #d8ffd7;
    --button-bg: #102414;
    --button-bg-hover: #17331c;
    --button-bg-active: #204224;
    --button-primary-text: #041006;
  }

  :global([data-theme="blueprint"]) {
    --color-bg: #0d1322;
    --color-panel: #101728;
    --color-panel-2: #17213a;
    --color-surface: #202e50;
    --color-surface-hover: #2b3c68;
    --color-border: rgba(240, 245, 255, 0.09);
    --color-border-strong: rgba(240, 245, 255, 0.14);
    --color-line: rgba(240, 245, 255, 0.06);
    --color-line-strong: rgba(240, 245, 255, 0.11);
    --color-text: #f0f5ff;
    --color-muted: #b7c5e4;
    --color-subtle: #7f90b4;
    --color-accent: #8bb8ff;
    --color-accent-hover: #b1d0ff;
    --color-danger: #ff8276;
    --color-label: #e4edff;
    --button-bg: #1b2945;
    --button-bg-hover: #25375a;
    --button-bg-active: #304770;
    --button-primary-text: #071022;
  }

  :global([data-theme="candy"]) {
    --color-bg: #171019;
    --color-panel: #231522;
    --color-panel-2: #301d2f;
    --color-surface: #402740;
    --color-surface-hover: #523152;
    --color-border: rgba(255, 243, 251, 0.09);
    --color-border-strong: rgba(255, 243, 251, 0.14);
    --color-line: rgba(255, 243, 251, 0.06);
    --color-line-strong: rgba(255, 243, 251, 0.11);
    --color-text: #fff3fb;
    --color-muted: #dfbad1;
    --color-subtle: #aa819c;
    --color-accent: #ff8ac7;
    --color-accent-hover: #ffb0da;
    --color-danger: #ff806c;
    --color-label: #ffe0f3;
    --button-bg: #382238;
    --button-bg-hover: #492c49;
    --button-bg-active: #5d375d;
    --button-primary-text: #190712;
  }

  :global([data-theme="coffee"]) {
    --color-bg: #15100d;
    --color-panel: #1f1712;
    --color-panel-2: #2b1f18;
    --color-surface: #3b2a20;
    --color-surface-hover: #4d3628;
    --color-border: rgba(246, 232, 212, 0.09);
    --color-border-strong: rgba(246, 232, 212, 0.14);
    --color-line: rgba(246, 232, 212, 0.06);
    --color-line-strong: rgba(246, 232, 212, 0.11);
    --color-text: #f6e8d4;
    --color-muted: #d0b693;
    --color-subtle: #998062;
    --color-accent: #d19a62;
    --color-accent-hover: #efbd86;
    --color-danger: #e77c69;
    --color-label: #f1ddbf;
    --button-bg: #33251c;
    --button-bg-hover: #433025;
    --button-bg-active: #543c2d;
    --button-primary-text: #140b05;
  }

  :global([data-theme="orchid"]) {
    --color-bg: #120d1a;
    --color-panel: #1d1528;
    --color-panel-2: #291d38;
    --color-surface: #38294c;
    --color-surface-hover: #49345f;
    --color-border: rgba(247, 239, 255, 0.09);
    --color-border-strong: rgba(247, 239, 255, 0.14);
    --color-line: rgba(247, 239, 255, 0.06);
    --color-line-strong: rgba(247, 239, 255, 0.11);
    --color-text: #f7efff;
    --color-muted: #ccb8df;
    --color-subtle: #967fad;
    --color-accent: #c79bff;
    --color-accent-hover: #dabaff;
    --color-danger: #ff7d85;
    --color-label: #f0e0ff;
    --button-bg: #302340;
    --button-bg-hover: #3f2d55;
    --button-bg-active: #4f3869;
    --button-primary-text: #12051f;
  }

  :global([data-theme="marine"]) {
    --color-bg: #07131b;
    --color-panel: #0b1c27;
    --color-panel-2: #102838;
    --color-surface: #18394f;
    --color-surface-hover: #204b67;
    --color-border: rgba(234, 248, 255, 0.09);
    --color-border-strong: rgba(234, 248, 255, 0.14);
    --color-line: rgba(234, 248, 255, 0.06);
    --color-line-strong: rgba(234, 248, 255, 0.11);
    --color-text: #eaf8ff;
    --color-muted: #accbdd;
    --color-subtle: #7598ad;
    --color-accent: #5cc8ff;
    --color-accent-hover: #8ed9ff;
    --color-danger: #ff826f;
    --color-label: #dff5ff;
    --button-bg: #153044;
    --button-bg-hover: #1d4059;
    --button-bg-active: #27516e;
    --button-primary-text: #03111a;
  }

  :global([data-theme="moss"]) {
    --color-bg: #10160c;
    --color-panel: #172112;
    --color-panel-2: #202d19;
    --color-surface: #2c3d21;
    --color-surface-hover: #394f2a;
    --color-border: rgba(243, 248, 223, 0.09);
    --color-border-strong: rgba(243, 248, 223, 0.14);
    --color-line: rgba(243, 248, 223, 0.06);
    --color-line-strong: rgba(243, 248, 223, 0.11);
    --color-text: #f3f8df;
    --color-muted: #c2d39a;
    --color-subtle: #8fa164;
    --color-accent: #aac96b;
    --color-accent-hover: #c9e184;
    --color-danger: #ff816d;
    --color-label: #edf7c8;
    --button-bg: #26351d;
    --button-bg-hover: #324526;
    --button-bg-active: #3f562f;
    --button-primary-text: #0e1506;
  }

  :global([data-theme="ruby"]) {
    --color-bg: #170b0e;
    --color-panel: #251215;
    --color-panel-2: #33191d;
    --color-surface: #452229;
    --color-surface-hover: #5a2c34;
    --color-border: rgba(255, 240, 240, 0.09);
    --color-border-strong: rgba(255, 240, 240, 0.14);
    --color-line: rgba(255, 240, 240, 0.06);
    --color-line-strong: rgba(255, 240, 240, 0.11);
    --color-text: #fff0f0;
    --color-muted: #deb4b7;
    --color-subtle: #aa7a80;
    --color-accent: #ff646f;
    --color-accent-hover: #ff929a;
    --color-danger: #ff9c5c;
    --color-label: #ffd9dc;
    --button-bg: #3a1f24;
    --button-bg-hover: #4c2930;
    --button-bg-active: #61343c;
    --button-primary-text: #1a0508;
  }

  :global([data-theme="paper"]) {
    --color-bg: #e8e2d3;
    --color-panel: #eee9dc;
    --color-panel-2: #f7f2e6;
    --color-surface: #d7cebb;
    --color-surface-hover: #c9bea8;
    --color-border: rgba(24, 20, 15, 0.1);
    --color-border-strong: rgba(24, 20, 15, 0.16);
    --color-line: rgba(24, 20, 15, 0.08);
    --color-line-strong: rgba(24, 20, 15, 0.13);
    --color-text: #18140f;
    --color-muted: #5e5549;
    --color-subtle: #837766;
    --color-accent: #2f7d5f;
    --color-accent-hover: #3d9d79;
    --color-danger: #a7463d;
    --color-label: #fffaf0;
    --color-glint: rgba(255, 255, 255, 0.42);
    --color-shadow-strong: rgba(34, 25, 14, 0.2);
    --button-bg: #d8ceb9;
    --button-bg-hover: #c8bca5;
    --button-bg-active: #b8aa90;
    --button-shadow: rgba(57, 43, 25, 0.26);
    --button-primary-text: #fffaf0;
  }

  :global([data-theme="linen"]) {
    --color-bg: #ece3d2;
    --color-panel: #f6eedf;
    --color-panel-2: #fff7e8;
    --color-surface: #ded2bb;
    --color-surface-hover: #d0c2a9;
    --color-border: rgba(29, 25, 18, 0.1);
    --color-border-strong: rgba(29, 25, 18, 0.16);
    --color-line: rgba(29, 25, 18, 0.08);
    --color-line-strong: rgba(29, 25, 18, 0.13);
    --color-text: #1d1912;
    --color-muted: #615846;
    --color-subtle: #8b7c63;
    --color-accent: #466fd1;
    --color-accent-hover: #5b82e5;
    --color-danger: #a94a41;
    --color-label: #32446f;
    --button-bg: #d9cfb9;
    --button-bg-hover: #cbc0a7;
    --button-bg-active: #baad93;
    --button-primary-text: #fbf7ec;
  }

  :global([data-theme="daylight"]) {
    --color-bg: #edf3f7;
    --color-panel: #f7fbfd;
    --color-panel-2: #ffffff;
    --color-surface: #dce7ef;
    --color-surface-hover: #cedde8;
    --color-border: rgba(18, 32, 42, 0.1);
    --color-border-strong: rgba(18, 32, 42, 0.16);
    --color-line: rgba(18, 32, 42, 0.08);
    --color-line-strong: rgba(18, 32, 42, 0.13);
    --color-text: #12202a;
    --color-muted: #536675;
    --color-subtle: #788997;
    --color-accent: #b46d1d;
    --color-accent-hover: #cf812d;
    --color-danger: #aa413b;
    --color-label: #7a4d1f;
    --button-bg: #d8e3ea;
    --button-bg-hover: #c8d6e0;
    --button-bg-active: #b7c6d2;
    --button-primary-text: #fff7e8;
  }

  :global([data-theme="sage-light"]) {
    --color-bg: #dfe8d8;
    --color-panel: #edf3e7;
    --color-panel-2: #f7fbf2;
    --color-surface: #cad8bf;
    --color-surface-hover: #bccaaf;
    --color-border: rgba(23, 32, 21, 0.1);
    --color-border-strong: rgba(23, 32, 21, 0.16);
    --color-line: rgba(23, 32, 21, 0.08);
    --color-line-strong: rgba(23, 32, 21, 0.13);
    --color-text: #172015;
    --color-muted: #53614a;
    --color-subtle: #78866c;
    --color-accent: #386e53;
    --color-accent-hover: #488865;
    --color-danger: #9f483f;
    --color-label: #386e53;
    --button-bg: #c7d4bc;
    --button-bg-hover: #b8c7ab;
    --button-bg-active: #a8b899;
    --button-primary-text: #f7fff4;
  }

  :global([data-theme="blush-light"]) {
    --color-bg: #f1dee1;
    --color-panel: #fff0f1;
    --color-panel-2: #fff7f6;
    --color-surface: #e2c5cb;
    --color-surface-hover: #d5b4bc;
    --color-border: rgba(39, 24, 27, 0.1);
    --color-border-strong: rgba(39, 24, 27, 0.16);
    --color-line: rgba(39, 24, 27, 0.08);
    --color-line-strong: rgba(39, 24, 27, 0.13);
    --color-text: #27181b;
    --color-muted: #71555c;
    --color-subtle: #9a7680;
    --color-accent: #b94364;
    --color-accent-hover: #d15476;
    --color-danger: #9d4834;
    --color-label: #8d3750;
    --button-bg: #ddc2c8;
    --button-bg-hover: #cfb1ba;
    --button-bg-active: #bea0aa;
    --button-primary-text: #fff7f8;
  }

  :global([data-theme="glacier"]) {
    --color-bg: #dfecef;
    --color-panel: #eff8fa;
    --color-panel-2: #f8feff;
    --color-surface: #c7dce2;
    --color-surface-hover: #b7ccd4;
    --color-border: rgba(16, 32, 39, 0.1);
    --color-border-strong: rgba(16, 32, 39, 0.16);
    --color-line: rgba(16, 32, 39, 0.08);
    --color-line-strong: rgba(16, 32, 39, 0.13);
    --color-text: #102027;
    --color-muted: #4c6670;
    --color-subtle: #718a94;
    --color-accent: #18798f;
    --color-accent-hover: #2294ad;
    --color-danger: #a3493f;
    --color-label: #18798f;
    --button-bg: #c0d6dd;
    --button-bg-hover: #b0c8d0;
    --button-bg-active: #9fb8c2;
    --button-primary-text: #effcff;
  }

  :global([data-theme="lavender-light"]) {
    --color-bg: #e7e1f1;
    --color-panel: #f4effb;
    --color-panel-2: #fbf8ff;
    --color-surface: #d3c9e5;
    --color-surface-hover: #c4b6da;
    --color-border: rgba(32, 23, 43, 0.1);
    --color-border-strong: rgba(32, 23, 43, 0.16);
    --color-line: rgba(32, 23, 43, 0.08);
    --color-line-strong: rgba(32, 23, 43, 0.13);
    --color-text: #20172b;
    --color-muted: #625473;
    --color-subtle: #88799b;
    --color-accent: #7252b3;
    --color-accent-hover: #8665ca;
    --color-danger: #a64650;
    --color-label: #5c438f;
    --button-bg: #cec3df;
    --button-bg-hover: #beb0d4;
    --button-bg-active: #ad9dc6;
    --button-primary-text: #fbf8ff;
  }

  :global([data-theme="peach-light"]) {
    --color-bg: #f1dfd0;
    --color-panel: #fff0e1;
    --color-panel-2: #fff8ee;
    --color-surface: #e2c6ad;
    --color-surface-hover: #d5b79a;
    --color-border: rgba(36, 24, 15, 0.1);
    --color-border-strong: rgba(36, 24, 15, 0.16);
    --color-line: rgba(36, 24, 15, 0.08);
    --color-line-strong: rgba(36, 24, 15, 0.13);
    --color-text: #24180f;
    --color-muted: #735944;
    --color-subtle: #997b61;
    --color-accent: #a9572f;
    --color-accent-hover: #c66b3f;
    --color-danger: #9a3f3f;
    --color-label: #8e4626;
    --button-bg: #ddc0a5;
    --button-bg-hover: #d0ae91;
    --button-bg-active: #bf9c7d;
    --button-primary-text: #fff8ee;
  }

  :global([data-theme="mint-light"]) {
    --color-bg: #dcece3;
    --color-panel: #eff8f3;
    --color-panel-2: #f7fdf9;
    --color-surface: #c2d8cd;
    --color-surface-hover: #b1cabd;
    --color-border: rgba(18, 32, 24, 0.1);
    --color-border-strong: rgba(18, 32, 24, 0.16);
    --color-line: rgba(18, 32, 24, 0.08);
    --color-line-strong: rgba(18, 32, 24, 0.13);
    --color-text: #122018;
    --color-muted: #506354;
    --color-subtle: #738978;
    --color-accent: #17826e;
    --color-accent-hover: #239d86;
    --color-danger: #9f463d;
    --color-label: #176b5c;
    --button-bg: #bed4c8;
    --button-bg-hover: #adc7ba;
    --button-bg-active: #9bb8aa;
    --button-primary-text: #f7fffb;
  }

  :global([data-theme="mono-light"]) {
    --color-bg: #e5e5e0;
    --color-panel: #f0f0ea;
    --color-panel-2: #fafaf4;
    --color-surface: #d4d4cd;
    --color-surface-hover: #c7c7bf;
    --color-border: rgba(24, 24, 21, 0.1);
    --color-border-strong: rgba(24, 24, 21, 0.16);
    --color-line: rgba(24, 24, 21, 0.08);
    --color-line-strong: rgba(24, 24, 21, 0.13);
    --color-text: #181815;
    --color-muted: #595a54;
    --color-subtle: #7d7e77;
    --color-accent: #4b4c47;
    --color-accent-hover: #62635d;
    --color-danger: #97493f;
    --color-label: #4b4c47;
    --button-bg: #d0d0c8;
    --button-bg-hover: #c2c2b9;
    --button-bg-active: #b1b1a8;
    --button-primary-text: #fafaf4;
  }

  :global([data-theme="butter"]) {
    --color-bg: #eee6c7;
    --color-panel: #faf1ce;
    --color-panel-2: #fff9de;
    --color-surface: #ded3a8;
    --color-surface-hover: #d0c497;
    --color-border: rgba(31, 26, 14, 0.1);
    --color-border-strong: rgba(31, 26, 14, 0.16);
    --color-line: rgba(31, 26, 14, 0.08);
    --color-line-strong: rgba(31, 26, 14, 0.13);
    --color-text: #1f1a0e;
    --color-muted: #665d3f;
    --color-subtle: #8e8259;
    --color-accent: #2e6971;
    --color-accent-hover: #3c818a;
    --color-danger: #9e463b;
    --color-label: #2e6971;
    --button-bg: #d8cc9f;
    --button-bg-hover: #cabd8d;
    --button-bg-active: #baab7b;
    --button-primary-text: #f7fffb;
  }

  :global([data-theme="linen"]),
  :global([data-theme="daylight"]),
  :global([data-theme="sage-light"]),
  :global([data-theme="blush-light"]),
  :global([data-theme="glacier"]),
  :global([data-theme="lavender-light"]),
  :global([data-theme="peach-light"]),
  :global([data-theme="mint-light"]),
  :global([data-theme="mono-light"]),
  :global([data-theme="butter"]) {
    --color-glint: rgba(255, 255, 255, 0.46);
    --color-shadow-strong: rgba(34, 28, 20, 0.18);
    --button-shadow: rgba(42, 36, 28, 0.24);
  }

  :global([data-theme="noir"]) {
    --color-bg: #050504;
    --color-panel: #090908;
    --color-panel-2: #141310;
    --color-surface: #22201b;
    --color-surface-hover: #2d2a24;
    --color-border: rgba(244, 238, 226, 0.08);
    --color-border-strong: rgba(244, 238, 226, 0.13);
    --color-line: rgba(244, 238, 226, 0.055);
    --color-line-strong: rgba(244, 238, 226, 0.1);
    --color-text: #f4eee2;
    --color-muted: #bdb5a8;
    --color-subtle: #837c72;
    --color-accent: #ded6c4;
    --color-accent-hover: #fff6e9;
    --color-danger: #ff766b;
    --color-label: #ebe2d2;
    --button-bg: #1c1a17;
    --button-bg-hover: #282520;
    --button-bg-active: #343029;
    --button-primary-text: #080705;
  }

  :global([data-theme="skyline"]) {
    --color-bg: #0d1423;
    --color-panel: #111b2c;
    --color-panel-2: #19263b;
    --color-surface: #253652;
    --color-surface-hover: #304768;
    --color-border: rgba(238, 245, 255, 0.09);
    --color-border-strong: rgba(238, 245, 255, 0.14);
    --color-line: rgba(238, 245, 255, 0.06);
    --color-line-strong: rgba(238, 245, 255, 0.11);
    --color-text: #eef5ff;
    --color-muted: #b8c7dc;
    --color-subtle: #8392aa;
    --color-accent: #ffb45c;
    --color-accent-hover: #ffd08c;
    --color-danger: #ff7a75;
    --color-label: #e4efff;
    --button-bg: #202f49;
    --button-bg-hover: #2b3f60;
    --button-bg-active: #375079;
    --button-primary-text: #160c02;
  }

  :global([data-theme="acid"]) {
    --color-bg: #0c1006;
    --color-panel: #111509;
    --color-panel-2: #1b220d;
    --color-surface: #293314;
    --color-surface-hover: #38451b;
    --color-border: rgba(246, 255, 217, 0.09);
    --color-border-strong: rgba(246, 255, 217, 0.14);
    --color-line: rgba(246, 255, 217, 0.06);
    --color-line-strong: rgba(246, 255, 217, 0.11);
    --color-text: #f6ffd9;
    --color-muted: #c8dc82;
    --color-subtle: #92a854;
    --color-accent: #d7ff4a;
    --color-accent-hover: #e8ff79;
    --color-danger: #ff7a60;
    --color-label: #efffb9;
    --button-bg: #222b11;
    --button-bg-hover: #303b17;
    --button-bg-active: #3e4c1f;
    --button-primary-text: #101404;
  }

  :global([data-theme="mixtape"]) {
    --color-bg: #111019;
    --color-panel: #1b1822;
    --color-panel-2: #252130;
    --color-surface: #342e42;
    --color-surface-hover: #443b56;
    --color-border: rgba(244, 240, 255, 0.09);
    --color-border-strong: rgba(244, 240, 255, 0.14);
    --color-line: rgba(244, 240, 255, 0.06);
    --color-line-strong: rgba(244, 240, 255, 0.11);
    --color-text: #f4f0ff;
    --color-muted: #c7badb;
    --color-subtle: #9284a8;
    --color-accent: #ff7f50;
    --color-accent-hover: #ffa17b;
    --color-danger: #ff6f91;
    --color-label: #ebe0ff;
    --button-bg: #2d2838;
    --button-bg-hover: #3b3449;
    --button-bg-active: #4a415c;
    --button-primary-text: #180803;
  }

  :global([data-theme="icebox"]) {
    --color-bg: #0b191c;
    --color-panel: #102225;
    --color-panel-2: #183034;
    --color-surface: #224348;
    --color-surface-hover: #2d565d;
    --color-border: rgba(239, 252, 255, 0.09);
    --color-border-strong: rgba(239, 252, 255, 0.14);
    --color-line: rgba(239, 252, 255, 0.06);
    --color-line-strong: rgba(239, 252, 255, 0.11);
    --color-text: #effcff;
    --color-muted: #badbe0;
    --color-subtle: #85a8ae;
    --color-accent: #76e2ff;
    --color-accent-hover: #a5ecff;
    --color-danger: #ff8a7c;
    --color-label: #e0fbff;
    --button-bg: #1d3940;
    --button-bg-hover: #284b53;
    --button-bg-active: #335d67;
    --button-primary-text: #031317;
  }

  :global(*) {
    box-sizing: border-box;
  }

  :global(html),
  :global(body) {
    margin: 0;
    min-width: 320px;
    min-height: 100%;
    background: var(--color-bg);
    color: var(--color-text);
    font-family: var(--font-app);
  }

  :global(button),
  :global(input),
  :global(select) {
    font: inherit;
  }

  button {
    position: relative;
    color: inherit;
    line-height: 1;
  }

  :global(button:focus-visible) {
    outline: 0;
  }

  button :global(svg) {
    --icon-nudge-x: 0px;
    --icon-nudge-y: 0px;
    display: block;
    flex: 0 0 auto;
    transform: translate(var(--icon-nudge-x), var(--icon-nudge-y));
    transform-origin: center;
  }

  .ui-button,
  .primary-action,
  .topbar-actions button,
  .transport button,
  .queue-button,
  .title-icon-button,
  .summary-card,
  .track-head button,
  .search-box button {
    transition:
      transform 90ms ease,
      box-shadow 90ms ease,
      background 120ms ease,
      color 120ms ease;
  }

  .ui-button:hover:not(:disabled):not(:active),
  .primary-action:hover:not(:disabled):not(:active),
  .topbar-actions button:hover:not(:disabled):not(:active),
  .transport button:hover:not(:disabled):not(:active):not(.active),
  .queue-button:hover:not(:disabled):not(:active):not(.active),
  .title-icon-button:hover:not(:disabled):not(:active),
  .summary-card:hover:not(:disabled):not(:active),
  .track-head button:hover:not(:disabled):not(:active):not(.active),
  .search-box button:hover:not(:disabled):not(:active) {
    transform: translateY(var(--button-hover-y));
  }

  .ui-button:active,
  .primary-action:active,
  .topbar-actions button:active,
  .transport button:active,
  .queue-button:active,
  .title-icon-button:active,
  .summary-card:active,
  .track-head button:active,
  .search-box button:active {
    transform: translateY(var(--button-press-y));
  }

  .transport button.active,
  .track-head button.active {
    transform: translateY(var(--button-latched-y));
  }

  .transport button.active:active,
  .track-head button.active:active {
    transform: translateY(var(--button-press-y));
  }

  .transport-buttons button.active::after,
  .topbar-actions button:active::after,
  .list-actions .ui-button:active::after,
  .title-edit .title-icon-button:active::after {
    content: "";
    position: absolute;
    right: 0;
    bottom: var(--button-latched-y);
    left: 0;
    height: 2px;
    background: var(--button-shadow);
    pointer-events: none;
  }

  .transport-buttons button:active::after,
  .topbar-actions button:active::after,
  .list-actions .ui-button:active::after,
  .title-edit .title-icon-button:active::after {
    content: "";
    position: absolute;
    right: 0;
    bottom: var(--button-press-y);
    left: 0;
    height: 2px;
    background: var(--button-shadow);
    pointer-events: none;
  }

  .ui-button {
    min-height: 50px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: var(--space-2);
    border: 0;
    border-radius: var(--radius-button);
    padding: 0 var(--space-4);
    background: var(--button-bg);
    color: var(--color-text);
    cursor: pointer;
    font-weight: 800;
    box-shadow: var(--button-shadow-rest);
  }

  .ui-button :global(svg),
  .primary-action :global(svg),
  .topbar-actions button :global(svg),
  .transport button :global(svg),
  .title-icon-button :global(svg),
  .queue-button :global(svg) {
    filter: var(--icon-inset-shadow);
  }

  .ui-button.primary :global(svg),
  .primary-action :global(svg),
  .title-icon-button.primary :global(svg),
  .transport .play-button :global(svg) {
    filter: var(--icon-inset-shadow-primary);
  }

  .topbar-actions button > :global(svg),
  .transport button > :global(svg),
  .title-icon-button > :global(svg),
  .queue-button > :global(svg) {
    --icon-nudge-y: -1px;
  }

  .ui-button :global(.lucide-play),
  .transport .play-button :global(.lucide-play) {
    --icon-nudge-x: 1px;
  }

  .transport button :global(.lucide-skip-back) {
    --icon-nudge-x: -1px;
  }

  .transport button :global(.lucide-skip-forward) {
    --icon-nudge-x: 1px;
  }

  .ui-button:active {
    box-shadow: var(--button-shadow-pressed);
  }

  .ui-button.compact {
    min-height: 40px;
    border-radius: var(--radius-button);
    padding: 0 12px;
    font-size: 0.88rem;
  }

  .ui-button:disabled {
    cursor: not-allowed;
    opacity: 0.48;
    transform: none;
  }

  .ui-button.primary {
    background: var(--color-accent);
    color: var(--button-primary-text);
    box-shadow:
      inset 0 -5px 0 rgba(0, 0, 0, 0.28),
      inset 0 1px 0 rgba(255, 255, 255, 0.14);
  }

  .ui-button.primary:active,
  .primary-action:active,
  .transport .play-button:active {
    background: var(--color-accent);
    box-shadow: var(--button-shadow-pressed);
  }

  .setup-screen {
    min-height: 100vh;
    display: grid;
    place-items: center;
    padding: 24px;
    background: var(--color-bg);
  }

  .setup-panel {
    width: min(560px, 100%);
    border: 0;
    border-radius: var(--radius-md);
    background: var(--color-panel-2);
    padding: 32px;
    box-shadow:
      inset 0 0 0 1px var(--color-line),
      0 24px 80px var(--color-shadow-strong);
  }

  .setup-panel.web-setup {
    width: min(500px, 100%);
  }

  .brand-row {
    display: flex;
    align-items: center;
    gap: 10px;
    font-weight: 800;
    letter-spacing: 0;
  }

  .brand-mark {
    width: 52px;
    height: 52px;
    display: inline-grid;
    place-items: center;
    border-radius: var(--radius-md);
    background: var(--color-accent);
    color: var(--button-primary-text);
  }

  .setup-mode {
    display: inline-block;
    margin-top: 28px;
    color: var(--color-accent);
    font-size: 0.72rem;
    font-weight: 900;
    text-transform: uppercase;
  }

  .setup-panel h1 {
    margin: 8px 0 12px;
    font-size: clamp(2.1rem, 6vw, 4rem);
    line-height: 0.95;
    letter-spacing: 0;
  }

  .setup-panel p {
    max-width: 48ch;
    margin: 0;
    color: var(--color-muted);
    font-size: 1.02rem;
  }

  .setup-actions {
    margin-top: 28px;
    display: flex;
    gap: 12px;
    flex-wrap: wrap;
  }

  .setup-sync {
    display: grid;
    gap: 10px;
  }

  .setup-sync-card {
    display: grid;
    gap: 14px;
    margin-top: 28px;
    border-radius: var(--radius-button);
    padding: 14px;
    background: color-mix(in srgb, var(--color-panel) 64%, var(--color-bg) 36%);
    box-shadow:
      inset 0 0 0 1px var(--color-line),
      inset 0 -2px 0 rgba(0, 0, 0, 0.16);
  }

  .setup-sync-copy {
    display: grid;
    gap: 4px;
  }

  .setup-sync-copy strong {
    color: var(--color-text);
    font-size: 0.95rem;
  }

  .setup-sync-copy span {
    color: var(--color-muted);
    font-size: 0.9rem;
    line-height: 1.35;
  }

  .primary-action,
  .topbar-actions button,
  .transport button,
  .queue-button,
  .title-icon-button {
    border: 0;
    cursor: pointer;
  }

  .primary-action {
    display: inline-flex;
    align-items: center;
    gap: 10px;
    border-radius: var(--radius-md);
    padding: 12px 16px;
    background: var(--color-accent);
    color: var(--button-primary-text);
    font-weight: 800;
    box-shadow:
      inset 0 -4px 0 rgba(0, 0, 0, 0.26),
      inset 0 1px 0 rgba(255, 255, 255, 0.12);
  }

  .setup-error {
    margin-top: 18px !important;
    display: flex;
    align-items: center;
    gap: 8px;
    color: var(--color-danger) !important;
  }

  .app-shell {
    height: 100vh;
    display: grid;
    grid-template-columns: 238px minmax(0, 1fr);
    grid-template-rows: minmax(0, 1fr) 128px;
    background: var(--color-bg);
    overflow: hidden;
  }

  .sidebar {
    grid-row: 1 / 3;
    display: flex;
    flex-direction: column;
    gap: 22px;
    padding: 18px 14px;
    border-right: 0;
    background:
      linear-gradient(0deg, rgba(255, 255, 255, 0.025), rgba(255, 255, 255, 0.025)),
      var(--color-panel);
    box-shadow: inset -1px 0 0 var(--color-line);
    min-width: 0;
  }

  .nav-stack,
  .playlist-scroll {
    display: grid;
    gap: 4px;
  }

  .nav-stack button,
  .playlist-scroll button,
  .theme-open-button {
    width: 100%;
    min-height: 38px;
    border: 0;
    display: grid;
    grid-template-columns: 22px minmax(0, 1fr) auto;
    align-items: center;
    gap: 10px;
    border-radius: 8px;
    padding: 8px 10px;
    background: transparent;
    color: var(--color-muted);
    cursor: pointer;
    font-weight: 750;
    text-align: left;
    transition:
      background 120ms ease,
      color 120ms ease;
  }

  .playlist-scroll button {
    grid-template-columns: minmax(0, 1fr) auto;
  }

  .theme-open-button {
    grid-template-columns: 22px minmax(0, 1fr);
  }

  .nav-stack button > :global(svg),
  .theme-open-button > :global(svg) {
    justify-self: center;
    filter: var(--icon-inset-shadow);
  }

  .nav-stack button > span,
  .playlist-scroll button > span,
  .theme-open-button > span {
    min-width: 0;
    justify-self: start;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .playlist-scroll button > small {
    justify-self: end;
  }

  .nav-stack button:hover,
  .playlist-scroll button:hover,
  .theme-open-button:hover,
  .nav-stack button.active,
  .playlist-scroll button.active {
    background: var(--color-surface);
    color: var(--color-text);
  }

  .playlist-nav {
    min-height: 0;
    display: flex;
    flex-direction: column;
  }

  .section-label {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    margin-bottom: 8px;
    padding: 0 8px;
    color: var(--color-subtle);
    font-size: 0.77rem;
    font-weight: 800;
    text-transform: uppercase;
  }

  .topbar-actions button,
  .transport button,
  .queue-button,
  .title-icon-button {
    width: 54px;
    height: 54px;
    display: inline-grid;
    place-items: center;
    border: 0;
    border-radius: var(--radius-button);
    background: var(--button-bg);
    color: var(--color-muted);
    box-shadow: var(--button-shadow-rest);
  }

  .topbar-actions button:disabled,
  .transport button:disabled,
  .queue-button:disabled,
  .title-icon-button:disabled {
    cursor: not-allowed;
    opacity: 0.48;
    transform: none;
  }

  .topbar-actions button:active,
  .transport button:active,
  .queue-button:active,
  .title-icon-button:active {
    box-shadow: var(--button-shadow-pressed);
  }

  .transport button.active {
    box-shadow: var(--button-shadow-latched);
  }

  .transport button.active:active {
    box-shadow: var(--button-shadow-pressed);
  }

  .queue-button,
  .title-icon-button {
    width: 42px;
    height: 42px;
  }

  .queue-button {
    border-radius: var(--radius-button);
  }

  .playlist-scroll {
    overflow-x: hidden;
    overflow-y: auto;
    margin-left: 0;
    padding-left: 0;
    padding-right: 2px;
  }

  .playlist-scroll button {
    width: 100%;
  }

  .playlist-nav small {
    color: var(--color-subtle);
  }

  .theme-nav {
    display: grid;
    gap: var(--space-2);
  }

  .sync-nav {
    display: grid;
    gap: var(--space-2);
  }

  .sync-url-field {
    height: 44px;
    display: grid;
    grid-template-columns: 22px minmax(0, 1fr);
    align-items: center;
    gap: 10px;
    border-radius: var(--radius-button);
    padding: 0 10px;
    background: color-mix(in srgb, var(--color-bg) 72%, var(--color-panel) 28%);
    color: var(--color-subtle);
    box-shadow:
      inset 0 0 0 1px var(--color-line),
      inset 0 -1px 0 rgba(0, 0, 0, 0.16);
  }

  .sync-url-field.compact {
    height: 38px;
  }

  .sync-url-field :global(svg) {
    justify-self: center;
    filter: var(--icon-inset-shadow);
  }

  .sync-url-field input {
    min-width: 0;
    border: 0;
    outline: 0;
    background: transparent;
    color: var(--color-text);
    font-weight: 750;
  }

  .sync-url-field input::placeholder {
    color: var(--color-subtle);
    opacity: 1;
  }

  .sync-url-field:focus-within {
    background: color-mix(in srgb, var(--color-bg) 64%, var(--color-panel) 36%);
    box-shadow:
      inset 0 0 0 1px color-mix(in srgb, var(--color-accent) 28%, var(--color-line-strong)),
      inset 0 -1px 0 rgba(0, 0, 0, 0.18);
  }

  .sync-actions {
    display: flex;
    overflow: hidden;
    border-radius: var(--radius-button);
  }

  .sync-actions .ui-button {
    flex: 1;
    min-height: 38px;
    border-radius: 0;
    padding: 0;
  }

  .sync-actions .ui-button + .ui-button {
    box-shadow:
      inset 1px 0 0 var(--color-line),
      var(--button-shadow-rest);
  }

  .sync-actions .ui-button:first-child {
    border-radius: var(--radius-button) 0 0 var(--radius-button);
  }

  .sync-actions .ui-button:last-child {
    border-radius: 0 var(--radius-button) var(--radius-button) 0;
  }

  .sync-status {
    color: var(--color-subtle);
    font-size: 0.76rem;
    font-weight: 750;
    line-height: 1.35;
  }

  .content {
    min-width: 0;
    overflow: auto;
    padding: 0 22px 28px;
  }

  .topbar {
    position: sticky;
    top: 0;
    z-index: 20;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 14px;
    margin: 0 -22px;
    padding: 18px 22px 16px;
    background: var(--color-bg);
    box-shadow: 0 1px 0 var(--color-line);
  }

  .search-box {
    flex: 1;
    max-width: 680px;
    min-width: 180px;
    height: 42px;
    display: flex;
    align-items: center;
    gap: 10px;
    border: 0;
    border-radius: var(--radius-md);
    padding: 0 10px;
    background: color-mix(in srgb, var(--color-bg) 74%, var(--color-panel) 26%);
    color: var(--color-subtle);
    box-shadow:
      inset 0 0 0 1px var(--color-line),
      inset 0 -1px 0 rgba(0, 0, 0, 0.16);
  }

  .search-box:focus-within {
    background: color-mix(in srgb, var(--color-bg) 66%, var(--color-panel) 34%);
    box-shadow:
      inset 0 0 0 1px color-mix(in srgb, var(--color-accent) 28%, var(--color-line-strong)),
      inset 0 -1px 0 rgba(0, 0, 0, 0.18);
  }

  .search-box input {
    width: 100%;
    min-width: 0;
    border: 0;
    outline: 0;
    background: transparent;
    color: var(--color-text);
  }

  .search-box input::placeholder {
    color: var(--color-subtle);
    opacity: 1;
  }

  .search-box button {
    border: 0;
    background: transparent;
    color: var(--color-subtle);
    cursor: pointer;
  }

  .topbar-actions {
    display: flex;
    align-items: center;
    gap: 0;
    border-radius: var(--radius-button);
    overflow: hidden;
  }

  .topbar-actions button {
    border-radius: 0;
  }

  .topbar-actions button + button {
    box-shadow:
      inset 1px 0 0 var(--color-line),
      var(--button-shadow-rest);
  }

  .topbar-actions button:first-child {
    border-radius: var(--radius-button) 0 0 var(--radius-button);
  }

  .topbar-actions button:last-child {
    border-radius: 0 var(--radius-button) var(--radius-button) 0;
  }

  .topbar-actions button:only-child {
    border-radius: var(--radius-button);
  }

  :global(.spin-icon) {
    animation: spin 1s linear infinite;
  }

  .view-header {
    display: flex;
    align-items: end;
    justify-content: space-between;
    gap: 18px;
    margin: 8px 0 16px;
  }

  .view-heading {
    min-width: 0;
    flex: 1;
  }

  .title-row {
    min-width: 0;
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .view-header h1 {
    min-width: 0;
    margin: 5px 0 3px;
    padding-bottom: 0.08em;
    color: var(--color-text);
    font-size: clamp(2rem, 5vw, 3.9rem);
    line-height: 1.08;
    letter-spacing: 0;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .view-header p {
    margin: 0;
    color: var(--color-muted);
  }

  .title-edit {
    width: min(760px, 100%);
    display: flex;
    align-items: center;
    gap: 0;
    margin: 5px 0 7px;
    border-radius: var(--radius-button);
    overflow: hidden;
  }

  .playlist-title-input {
    min-width: 0;
    flex: 1;
    height: clamp(48px, 7vw, 68px);
    border: 0;
    border-radius: var(--radius-button) 0 0 var(--radius-button);
    outline: 0;
    padding: 0 14px;
    background: var(--color-panel-2);
    color: var(--color-text);
    box-shadow:
      inset 0 -3px 0 rgba(0, 0, 0, 0.2),
      inset 0 1px 0 var(--color-glint);
    font-size: clamp(2rem, 5vw, 3.9rem);
    font-weight: 850;
    line-height: 1.08;
  }

  .playlist-title-input:focus {
    background: var(--color-surface);
  }

  .title-edit .title-icon-button {
    width: 48px;
    height: clamp(48px, 7vw, 68px);
    border-radius: 0;
  }

  .title-edit .title-icon-button + .title-icon-button {
    box-shadow:
      inset 1px 0 0 var(--color-line),
      var(--button-shadow-rest);
  }

  .title-edit .title-icon-button:last-child {
    border-radius: 0 var(--radius-button) var(--radius-button) 0;
  }

  .title-icon-button.primary {
    background: var(--color-accent);
    color: var(--button-primary-text);
  }

  .error-strip {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 16px;
    border: 1px solid color-mix(in srgb, var(--color-danger) 42%, transparent);
    border-radius: var(--radius-button);
    padding: 10px 12px;
    background: var(--color-danger-soft);
    color: var(--color-danger);
  }

  .summary-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(164px, 1fr));
    gap: 10px;
    margin-bottom: 20px;
  }

  .summary-card {
    min-height: 178px;
    display: flex;
    flex-direction: column;
    justify-content: end;
    gap: 8px;
    border: 0;
    border-radius: var(--radius-button);
    padding: 12px;
    background: var(--color-panel-2);
    color: var(--color-text);
    text-align: left;
    cursor: pointer;
    overflow: hidden;
    box-shadow:
      inset 0 -3px 0 rgba(0, 0, 0, 0.2),
      inset 0 1px 0 rgba(255, 255, 255, 0.03);
  }

  .summary-card:active {
    box-shadow: var(--button-shadow-pressed);
  }

  .summary-art,
  .summary-icon {
    width: 84px;
    height: 84px;
    display: grid;
    place-items: center;
    border-radius: var(--radius-sm);
    background: var(--color-label);
    color: var(--button-primary-text);
    object-fit: cover;
  }

  .artists-grid .summary-card {
    min-height: 140px;
  }

  .summary-card strong {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .summary-card span:last-child {
    color: var(--color-muted);
    font-size: 0.86rem;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .track-surface {
    min-width: 0;
    margin-inline: -22px;
  }

  .list-toolbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    margin-bottom: 10px;
    padding-inline: 22px;
  }

  .list-meta {
    min-width: 0;
    display: flex;
    align-items: center;
    gap: 10px;
    color: var(--color-muted);
    font-size: 0.88rem;
    font-weight: 750;
  }

  .list-meta > span:last-child {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .list-actions {
    display: flex;
    flex: 0 0 auto;
    align-items: center;
    gap: 0;
    border-radius: var(--radius-button);
    overflow: hidden;
  }

  .list-actions .ui-button {
    border-radius: 0;
  }

  .list-actions .ui-button + .ui-button {
    box-shadow:
      inset 1px 0 0 var(--color-line),
      var(--button-shadow-rest);
  }

  .list-actions .ui-button:first-child {
    border-radius: var(--radius-button) 0 0 var(--radius-button);
  }

  .list-actions .ui-button:last-child {
    border-radius: 0 var(--radius-button) var(--radius-button) 0;
  }

  .list-actions .ui-button:only-child {
    border-radius: var(--radius-button);
  }

  .track-table {
    min-width: 640px;
    border-block: 0;
    border-inline: 0;
    border-radius: 0;
    overflow: hidden;
    background: var(--color-panel);
    box-shadow:
      inset 0 1px 0 var(--color-line),
      inset 0 -1px 0 var(--color-line);
  }

  .track-head,
  .track-row {
    display: grid;
    grid-template-columns: minmax(260px, 1.45fr) minmax(140px, 0.8fr) 72px 48px;
    align-items: center;
    gap: 10px;
  }

  .track-head {
    min-height: 36px;
    padding: 0 12px;
    background: var(--color-panel-2);
    color: var(--color-subtle);
    font-size: 0.78rem;
    text-transform: uppercase;
    box-shadow: inset 0 -1px 0 var(--color-line);
  }

  .track-head button {
    width: fit-content;
    border: 0;
    border-radius: var(--radius-sm);
    padding: 3px 8px;
    background: transparent;
    color: inherit;
    cursor: pointer;
    font: inherit;
    font-weight: 900;
    text-transform: uppercase;
  }

  .track-row {
    min-height: 68px;
    border-bottom: 0;
    padding: 7px 12px;
    color: var(--color-muted);
    cursor: pointer;
    box-shadow: inset 0 -1px 0 var(--color-line);
  }

  .track-row:hover,
  .track-row.active {
    background: color-mix(in srgb, var(--color-surface) 78%, var(--color-bg));
  }

  .track-row.active {
    color: var(--color-text);
    background: color-mix(in srgb, var(--color-accent) 12%, var(--color-surface));
    box-shadow:
      inset 0 0 0 1px color-mix(in srgb, var(--color-accent) 14%, transparent),
      inset 0 -1px 0 var(--color-line);
  }

  .track-row:focus-visible {
    outline: 0;
    box-shadow: inset 3px 0 0 color-mix(in srgb, var(--color-accent) 68%, transparent);
  }

  .track-title-cell,
  .now-playing {
    min-width: 0;
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .artwork,
  .player-art {
    width: 42px;
    height: 42px;
    flex: 0 0 auto;
    border-radius: var(--radius-sm);
    object-fit: cover;
  }

  .placeholder {
    display: inline-grid;
    place-items: center;
    background: var(--color-surface);
    color: var(--color-accent-hover);
  }

  .track-title-cell div,
  .now-playing div {
    min-width: 0;
    display: grid;
    gap: 2px;
  }

  .track-title-cell strong,
  .now-playing strong,
  .track-title-cell span,
  .now-playing span,
  .table-album,
  .table-duration {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .track-title-cell strong,
  .now-playing strong {
    color: var(--color-text);
  }

  .track-title-cell span,
  .now-playing span,
  .table-album,
  .table-duration {
    color: var(--color-subtle);
    font-size: 0.9rem;
  }

  .empty-state,
  .loading-state {
    min-height: 260px;
    display: grid;
    place-items: center;
    align-content: center;
    gap: 12px;
    color: var(--color-subtle);
  }

  .player {
    grid-column: 2;
    display: grid;
    grid-template-columns: minmax(220px, 1fr) minmax(360px, 1.25fr) minmax(190px, 0.75fr);
    align-items: center;
    gap: 18px;
    border-top: 0;
    padding: 14px 20px 16px;
    background:
      linear-gradient(0deg, rgba(255, 255, 255, 0.025), rgba(255, 255, 255, 0.025)),
      var(--color-panel);
    box-shadow: inset 0 1px 0 var(--color-line);
    min-width: 0;
  }

  .player-art {
    width: 54px;
    height: 54px;
  }

  .transport {
    min-width: 0;
    display: grid;
    align-content: center;
    gap: 10px;
  }

  .transport-buttons {
    width: max-content;
    max-width: 100%;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    justify-self: center;
    gap: 0;
    border-radius: var(--radius-button);
    overflow: hidden;
  }

  .transport-buttons button {
    width: 58px;
    height: 58px;
    border: 0;
    border-radius: 0;
    box-shadow: var(--button-shadow-rest);
  }

  .transport-buttons button + button {
    box-shadow:
      inset 1px 0 0 var(--color-line),
      var(--button-shadow-rest);
  }

  .transport-buttons button:first-child {
    border-radius: var(--radius-button) 0 0 var(--radius-button);
  }

  .transport-buttons button:last-child {
    border-radius: 0 var(--radius-button) var(--radius-button) 0;
  }

  .transport .play-button {
    width: 78px;
    height: 58px;
    border-radius: 0;
    background: var(--color-accent);
    color: var(--button-primary-text);
  }

  .transport .play-button.active {
    background: var(--color-accent);
    box-shadow: var(--button-shadow-latched);
  }

  .transport .play-button.active:active {
    box-shadow: var(--button-shadow-pressed);
  }

  .progress-row,
  .volume-control {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
  }

  .progress-row {
    width: min(860px, 100%);
    justify-self: center;
  }

  .progress-row span {
    width: 44px;
    color: var(--color-subtle);
    font-size: 0.78rem;
    text-align: center;
  }

  .progress-row input[type="range"],
  .volume-control input[type="range"] {
    width: 100%;
    min-width: 0;
    height: 30px;
    appearance: none;
    -webkit-appearance: none;
    background: transparent;
    cursor: pointer;
  }

  .progress-row input[type="range"]::-webkit-slider-runnable-track,
  .volume-control input[type="range"]::-webkit-slider-runnable-track {
    height: 20px;
    border-radius: var(--radius-sm);
    background:
      linear-gradient(90deg, var(--color-line), transparent),
      color-mix(in srgb, var(--color-bg) 82%, black);
    box-shadow:
      inset 0 2px 0 rgba(0, 0, 0, 0.45),
      inset 0 -1px 0 var(--color-line);
  }

  .progress-row input[type="range"]::-moz-range-track,
  .volume-control input[type="range"]::-moz-range-track {
    height: 20px;
    border-radius: var(--radius-sm);
    background: color-mix(in srgb, var(--color-bg) 82%, black);
    box-shadow:
      inset 0 2px 0 rgba(0, 0, 0, 0.45),
      inset 0 -1px 0 var(--color-line);
  }

  .progress-row input[type="range"]::-webkit-slider-thumb,
  .volume-control input[type="range"]::-webkit-slider-thumb {
    width: 16px;
    height: 30px;
    margin-top: -5px;
    border: 0;
    border-radius: var(--radius-sm);
    appearance: none;
    -webkit-appearance: none;
    background: var(--button-bg);
    box-shadow:
      inset 0 -4px 0 var(--button-shadow),
      inset 0 1px 0 var(--color-glint),
      0 0 0 1px rgba(0, 0, 0, 0.12);
  }

  .progress-row input[type="range"]::-moz-range-thumb,
  .volume-control input[type="range"]::-moz-range-thumb {
    width: 16px;
    height: 30px;
    border: 0;
    border-radius: var(--radius-sm);
    background: var(--button-bg);
    box-shadow:
      inset 0 -4px 0 var(--button-shadow),
      inset 0 1px 0 var(--color-glint),
      0 0 0 1px rgba(0, 0, 0, 0.12);
  }

  .progress-row input[type="range"]:disabled,
  .volume-control input[type="range"]:disabled {
    cursor: not-allowed;
    opacity: 0.48;
  }

  .volume-control {
    justify-self: end;
    width: min(210px, 100%);
    color: var(--color-muted);
  }

  .player-side {
    min-width: 0;
    width: min(230px, 100%);
    justify-self: end;
    display: grid;
    gap: 8px;
  }

  .volume-control > :global(svg) {
    width: 24px;
    height: 24px;
    padding: 0;
    background: transparent;
    color: var(--color-muted);
    border-radius: 0;
    box-shadow: none;
    filter: var(--icon-inset-shadow);
  }

  .device-control {
    min-width: 0;
    display: grid;
    gap: 4px;
  }

  .device-control span {
    color: var(--color-subtle);
    font-size: 0.66rem;
    font-weight: 900;
    letter-spacing: 0;
    line-height: 1;
    text-transform: uppercase;
  }

  .device-control select {
    width: 100%;
    min-width: 0;
    height: 36px;
    border: 0;
    border-radius: var(--radius-button);
    appearance: none;
    -webkit-appearance: none;
    padding: 0 30px 0 10px;
    background:
      linear-gradient(45deg, transparent 50%, var(--color-muted) 50%) right 14px center / 6px 6px no-repeat,
      linear-gradient(135deg, var(--color-muted) 50%, transparent 50%) right 10px center / 6px 6px no-repeat,
      var(--button-bg);
    color: var(--color-text);
    cursor: pointer;
    font: inherit;
    font-size: 0.82rem;
    font-weight: 850;
    box-shadow: var(--button-shadow-rest);
  }

  .device-control select:focus {
    outline: 0;
    box-shadow:
      var(--button-shadow-rest),
      0 0 0 2px color-mix(in srgb, var(--color-accent) 36%, transparent);
  }

  .modal-backdrop {
    position: fixed;
    inset: 0;
    z-index: 100;
    display: grid;
    place-items: center;
    padding: 24px;
    background: rgba(0, 0, 0, 0.54);
  }

  .app-modal {
    width: min(520px, 100%);
    max-height: min(680px, calc(100vh - 48px));
    display: grid;
    grid-template-rows: auto minmax(0, 1fr) auto;
    gap: 16px;
    border-radius: var(--radius-md);
    padding: 18px;
    background: var(--color-panel);
    box-shadow: 0 24px 80px var(--color-shadow-strong);
  }

  .theme-modal {
    width: min(620px, 100%);
  }

  .sync-server-modal {
    width: min(540px, 100%);
  }

  .sync-server-form {
    min-width: 0;
    display: grid;
    gap: 12px;
  }

  .sync-url-field.modal-field {
    height: 46px;
  }

  .sync-server-help {
    margin: 0;
    color: var(--color-muted);
    font-size: 0.9rem;
    line-height: 1.35;
  }

  .modal-header {
    display: flex;
    align-items: start;
    justify-content: space-between;
    gap: 16px;
  }

  .modal-header span {
    display: block;
    margin-bottom: 5px;
    color: var(--color-subtle);
    font-size: 0.72rem;
    font-weight: 900;
    text-transform: uppercase;
  }

  .modal-header h2,
  .modal-header p {
    margin: 0;
  }

  .modal-header h2 {
    max-width: 28ch;
    overflow: hidden;
    color: var(--color-text);
    font-size: 1.15rem;
    line-height: 1.15;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .modal-header p {
    margin-top: 4px;
    color: var(--color-muted);
    font-size: 0.92rem;
  }

  .playlist-choice-list {
    min-height: 0;
    display: grid;
    gap: 6px;
    overflow: auto;
  }

  .playlist-choice {
    width: 100%;
    min-height: 48px;
    display: grid;
    grid-template-columns: 30px minmax(0, 1fr);
    align-items: center;
    gap: 10px;
    border-radius: var(--radius-md);
    padding: 8px 10px;
    background: color-mix(in srgb, var(--color-panel-2) 76%, var(--color-bg) 24%);
    color: var(--color-muted);
    cursor: pointer;
    font: inherit;
    text-align: left;
    box-shadow: inset 0 0 0 1px var(--color-line);
  }

  .playlist-choice:hover {
    background: var(--color-surface);
    color: var(--color-text);
  }

  .playlist-choice input {
    position: absolute;
    width: 1px;
    height: 1px;
    opacity: 0;
    pointer-events: none;
  }

  .playlist-choice:has(input:focus-visible) {
    box-shadow:
      inset 0 0 0 1px color-mix(in srgb, var(--color-accent) 52%, var(--color-line-strong)),
      0 0 0 2px color-mix(in srgb, var(--color-accent) 24%, transparent);
  }

  .playlist-choice.active {
    background: color-mix(in srgb, var(--color-accent) 13%, var(--color-surface));
    color: var(--color-text);
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--color-accent) 34%, transparent);
  }

  .choice-box {
    width: 24px;
    height: 24px;
    display: grid;
    place-items: center;
    border-radius: var(--radius-sm);
    background: color-mix(in srgb, var(--color-bg) 72%, var(--color-panel) 28%);
    box-shadow:
      inset 0 0 0 1px var(--color-line-strong),
      inset 0 2px 4px rgba(0, 0, 0, 0.18);
  }

  .choice-box :global(svg) {
    color: var(--color-accent);
    filter: var(--icon-inset-shadow);
  }

  .choice-copy {
    min-width: 0;
    display: grid;
    gap: 3px;
  }

  .choice-copy strong,
  .choice-copy small {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .choice-copy strong {
    color: var(--color-text);
    font-size: 0.92rem;
  }

  .choice-copy small {
    color: var(--color-subtle);
    font-size: 0.78rem;
  }

  .theme-grid {
    min-height: 0;
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(138px, 1fr));
    gap: 8px;
    overflow: auto;
  }

  .theme-choice {
    min-height: 48px;
    border: 0;
    display: grid;
    grid-template-columns: 28px minmax(0, 1fr) 18px;
    align-items: center;
    gap: 10px;
    border-radius: var(--radius-md);
    padding: 8px 10px;
    background: color-mix(in srgb, var(--color-panel-2) 78%, var(--color-bg) 22%);
    color: var(--color-muted);
    cursor: pointer;
    font-weight: 800;
    text-align: left;
    box-shadow: inset 0 0 0 1px var(--color-line);
  }

  .theme-choice:hover,
  .theme-choice.active {
    background: var(--color-surface);
    color: var(--color-text);
  }

  .theme-choice.active {
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--color-accent) 42%, var(--color-line));
  }

  .theme-choice > span:not(.theme-swatch) {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .theme-choice > :global(svg) {
    justify-self: end;
    color: var(--color-accent);
    filter: var(--icon-inset-shadow);
  }

  .theme-swatch {
    width: 22px;
    height: 22px;
    border-radius: var(--radius-sm);
    background: linear-gradient(135deg, var(--a) 0 33%, var(--b) 34% 66%, var(--c) 67% 100%);
    box-shadow: inset 0 0 0 1px var(--color-line-strong);
  }

  .modal-actions {
    display: flex;
    justify-content: flex-end;
    gap: 0;
    overflow: hidden;
    border-radius: var(--radius-button);
  }

  .modal-actions .ui-button {
    border-radius: 0;
  }

  .modal-actions .ui-button + .ui-button {
    box-shadow:
      inset 1px 0 0 var(--color-line),
      var(--button-shadow-rest);
  }

  .modal-actions .ui-button:first-child {
    border-radius: var(--radius-button) 0 0 var(--radius-button);
  }

  .modal-actions .ui-button:last-child {
    border-radius: 0 var(--radius-button) var(--radius-button) 0;
  }

  audio {
    display: none;
  }

  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }

  @media (max-width: 980px) {
    .app-shell {
      grid-template-columns: 1fr;
      grid-template-rows: auto minmax(0, 1fr) auto;
    }

    .sidebar {
      grid-row: auto;
      display: grid;
      grid-template-columns: minmax(0, 1fr) minmax(180px, 260px);
      align-items: start;
      gap: 10px;
      overflow-x: auto;
      padding: 10px 12px;
      border-right: 0;
      border-bottom: 0;
      box-shadow: inset 0 -1px 0 var(--color-line);
    }

    .nav-stack {
      display: flex;
      min-width: 0;
      gap: 0;
      overflow-x: auto;
      border-radius: var(--radius-button);
    }

    .nav-stack button {
      width: max-content;
      min-height: 42px;
      border-radius: 0;
      grid-template-columns: 20px auto;
      white-space: nowrap;
      background: var(--button-bg);
      box-shadow: var(--button-shadow-rest);
    }

    .nav-stack button + button {
      box-shadow:
        inset 1px 0 0 var(--color-line),
        var(--button-shadow-rest);
    }

    .nav-stack button:first-child {
      border-radius: var(--radius-button) 0 0 var(--radius-button);
    }

    .nav-stack button:last-child {
      border-radius: 0 var(--radius-button) var(--radius-button) 0;
    }

    .playlist-nav {
      display: none;
    }

    .theme-nav {
      display: none;
    }

    .sync-nav {
      min-width: 0;
      grid-template-columns: minmax(0, 1fr) 84px;
      align-items: start;
    }

    .sync-nav .section-label,
    .sync-nav .sync-status {
      display: none;
    }

    .sync-actions .ui-button {
      height: 38px;
    }

    .player {
      grid-column: 1;
      grid-template-columns: 1fr;
      gap: 10px;
    }

    .player-side {
      width: 100%;
      justify-self: stretch;
      grid-template-columns: minmax(0, 1fr) minmax(180px, 240px);
      align-items: end;
    }

    .volume-control {
      justify-self: stretch;
      width: 100%;
    }
  }

  @media (max-width: 720px) {
    .setup-screen {
      min-height: 100dvh;
      place-items: stretch;
      padding: 0;
      background:
        linear-gradient(180deg, color-mix(in srgb, var(--color-panel) 55%, transparent), transparent 42%),
        var(--color-bg);
    }

    .setup-panel,
    .setup-panel.web-setup {
      width: 100%;
      min-height: 100dvh;
      display: flex;
      flex-direction: column;
      justify-content: flex-start;
      border-radius: 0;
      padding:
        max(20px, env(safe-area-inset-top))
        18px
        max(22px, env(safe-area-inset-bottom));
      background: transparent;
      box-shadow: none;
    }

    .brand-row {
      gap: 9px;
      margin-top: 4px;
      font-size: 1.05rem;
    }

    .brand-mark {
      width: 46px;
      height: 46px;
    }

    .setup-mode {
      margin-top: clamp(42px, 12vh, 82px);
    }

    .setup-panel h1 {
      width: min(100%, 360px);
      max-width: none;
      font-size: clamp(2.25rem, 10.8vw, 3.2rem);
      line-height: 0.98;
      overflow-wrap: normal;
    }

    .setup-panel p {
      max-width: 34ch;
      font-size: 1rem;
      line-height: 1.45;
    }

    .setup-actions,
    .setup-sync-card {
      margin-top: 22px;
    }

    .setup-sync-card {
      padding: 0;
      background: transparent;
      box-shadow: none;
    }

    .setup-sync-copy {
      display: none;
    }

    .setup-sync {
      gap: 12px;
    }

    .sync-url-field {
      height: 52px;
      grid-template-columns: 24px minmax(0, 1fr);
      padding: 0 12px;
      background: var(--color-panel);
    }

    .primary-action {
      width: 100%;
      min-height: 54px;
      justify-content: center;
      border-radius: var(--radius-button);
    }

    .setup-error {
      margin-top: 14px !important;
      line-height: 1.35;
    }

    .app-shell {
      height: 100dvh;
      grid-template-rows: auto minmax(0, 1fr) auto;
    }

    .sidebar {
      grid-template-columns: 1fr;
      gap: 8px;
      padding:
        max(8px, env(safe-area-inset-top))
        10px
        8px;
      overflow: hidden;
    }

    .nav-stack {
      width: 100%;
      display: grid;
      grid-template-columns: repeat(6, minmax(0, 1fr));
      scrollbar-width: none;
      overflow: hidden;
      box-shadow: 0 5px 0 var(--button-shadow);
    }

    .nav-stack::-webkit-scrollbar {
      display: none;
    }

    .nav-stack button {
      width: auto;
      min-width: 0;
      min-height: 46px;
      grid-template-columns: 1fr;
      justify-items: center;
      padding: 0;
      background: var(--button-bg);
      color: var(--color-muted);
      box-shadow: var(--button-shadow-rest);
      transition:
        transform 90ms ease,
        box-shadow 90ms ease,
        color 120ms ease;
    }

    .nav-stack button:hover:not(:active):not(.active) {
      transform: translateY(var(--button-hover-y));
    }

    .nav-stack button:active {
      transform: translateY(var(--button-press-y));
      box-shadow: var(--button-shadow-pressed);
    }

    .nav-stack button.active {
      transform: translateY(var(--button-latched-y));
      background: var(--button-bg);
      color: var(--color-text);
      box-shadow: var(--button-shadow-latched);
    }

    .nav-stack button.active:active {
      transform: translateY(var(--button-press-y));
      box-shadow: var(--button-shadow-pressed);
    }

    .nav-stack button > :global(svg) {
      width: 22px;
      height: 22px;
      filter: var(--icon-inset-shadow);
    }

    .nav-stack button > span {
      display: none;
    }

    .playlist-nav {
      display: flex;
      min-height: 0;
      overflow: hidden;
    }

    .playlist-nav .section-label,
    .theme-nav .section-label,
    .sync-nav .section-label,
    .sync-nav .sync-status {
      display: none;
    }

    .playlist-scroll {
      width: 100%;
      display: flex;
      gap: 0;
      overflow-x: auto;
      overflow-y: hidden;
      border-radius: var(--radius-button);
      box-shadow: 0 5px 0 var(--button-shadow);
      scrollbar-width: none;
    }

    .playlist-scroll::-webkit-scrollbar {
      display: none;
    }

    .playlist-scroll button {
      width: auto;
      max-width: 176px;
      min-height: 38px;
      flex: 0 0 auto;
      border-radius: 0;
      grid-template-columns: minmax(0, 1fr) auto;
      background: var(--button-bg);
      box-shadow: var(--button-shadow-rest);
    }

    .playlist-scroll button + button {
      box-shadow:
        inset 1px 0 0 var(--color-line),
        var(--button-shadow-rest);
    }

    .playlist-scroll button:first-child {
      border-radius: var(--radius-button) 0 0 var(--radius-button);
    }

    .playlist-scroll button:last-child {
      border-radius: 0 var(--radius-button) var(--radius-button) 0;
    }

    .theme-nav {
      display: grid;
    }

    .theme-open-button {
      min-height: 38px;
      border-radius: var(--radius-button);
      background: var(--button-bg);
      box-shadow: var(--button-shadow-rest);
    }

    .sync-nav {
      display: grid;
      grid-template-columns: minmax(0, 1fr) 86px;
      gap: 8px;
      align-items: start;
    }

    .content {
      padding: 0 12px 14px;
    }

    .topbar {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      align-items: center;
      gap: 8px;
      margin: 0 -12px;
      padding: 8px 12px;
    }

    .view-header {
      align-items: stretch;
      flex-direction: column;
    }

    .topbar-actions {
      align-self: center;
    }

    .topbar-actions button {
      width: 42px;
      height: 42px;
    }

    .search-box {
      max-width: none;
      width: 100%;
      min-width: 0;
      height: 40px;
      border-radius: var(--radius-button);
      background: color-mix(in srgb, var(--button-bg) 74%, var(--color-bg) 26%);
      box-shadow:
        inset 0 0 0 1px var(--color-line),
        inset 0 -2px 0 rgba(0, 0, 0, 0.18);
    }

    .search-box input {
      font-size: 0.95rem;
    }

    .view-header {
      gap: 8px;
      margin: 6px 0 12px;
    }

    .list-toolbar {
      align-items: stretch;
      flex-direction: column;
      padding-inline: 12px;
    }

    .list-actions {
      justify-content: flex-start;
    }

    .list-actions .ui-button {
      min-height: 42px;
    }

    .track-table {
      min-width: 0;
    }

    .track-surface {
      margin-inline: -12px;
    }

    .track-head {
      display: none;
    }

    .track-row {
      grid-template-columns: minmax(0, 1fr) 44px;
      gap: 8px;
      min-height: 62px;
      padding: 8px 12px;
    }

    .table-album,
    .table-duration {
      display: none;
    }

    .view-header h1 {
      font-size: clamp(2rem, 12vw, 2.7rem);
    }

    .player {
      padding: 10px 12px max(12px, env(safe-area-inset-bottom));
      gap: 8px;
    }

    .now-playing {
      min-height: 42px;
    }

    .player-art {
      width: 42px;
      height: 42px;
    }

    .transport-buttons button {
      width: 48px;
      height: 50px;
    }

    .transport .play-button {
      width: 62px;
      height: 50px;
    }

    .progress-row {
      gap: 6px;
    }

    .progress-row span {
      width: 36px;
      font-size: 0.72rem;
    }

    .volume-control {
      display: none;
    }

    .player-side {
      grid-template-columns: 1fr;
      gap: 0;
    }

    .device-control {
      width: 100%;
    }

    .device-control select {
      height: 34px;
    }
  }
</style>
