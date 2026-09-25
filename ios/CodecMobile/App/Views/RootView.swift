import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var newPlaylistName = ""
    @State private var toastDismissal: Task<Void, Never>?

    #if DEBUG
    /// Screenshot harness: CODEC_UI_PREVIEW=settings|aux|join opens that
    /// surface at launch so simulator runs can capture it without taps.
    @State private var uiPreview: String?
    #endif

    private var playlistPickerShown: Binding<Bool> {
        Binding(
            get: { app.playlistPickerTrack != nil },
            set: { shown in
                if !shown {
                    app.playlistPickerTrack = nil
                }
            }
        )
    }

    private var newPlaylistPromptShown: Binding<Bool> {
        Binding(
            get: { app.pendingNewPlaylistTrack != nil },
            set: { shown in
                if !shown {
                    app.pendingNewPlaylistTrack = nil
                }
            }
        )
    }

    var body: some View {
        content
            .background { SpectrumAppearanceObserver() }
            .sheet(isPresented: Binding(get: { app.aux.pendingInvitation != nil }, set: { if !$0 { app.aux.pendingInvitation = nil } })) { AuxJoinView() }
            .sheet(isPresented: Binding(get: { app.aux.showCreate }, set: { app.aux.showCreate = $0 })) { AuxCreateView() }
            .overlay(alignment: .top) {
                if app.hasLibrary, !app.errorMessage.isEmpty {
                    ErrorToast(message: app.errorMessage)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: app.errorMessage)
            .onChange(of: app.errorMessage) {
                toastDismissal?.cancel()
                guard !app.errorMessage.isEmpty else {
                    return
                }
                toastDismissal = Task {
                    try? await Task.sleep(for: .seconds(4))
                    if !Task.isCancelled {
                        app.errorMessage = ""
                    }
                }
            }
            .sheet(isPresented: playlistPickerShown) {
                if let track = app.playlistPickerTrack {
                    AddToPlaylistSheet(track: track)
                }
            }
            .alert("New Playlist", isPresented: newPlaylistPromptShown) {
                TextField("Name", text: $newPlaylistName)
                Button("Create") {
                    app.createPlaylist(named: newPlaylistName, adding: app.pendingNewPlaylistTrack)
                    newPlaylistName = ""
                }
                Button("Cancel", role: .cancel) {
                    newPlaylistName = ""
                }
            }
            #if DEBUG
            .onAppear {
                guard let preview = ProcessInfo.processInfo.environment["CODEC_UI_PREVIEW"] else {
                    return
                }
                if app.serverURLString.isEmpty {
                    app.serverURLString = "https://codec.example.com"
                }
                if preview != "join", app.activeAuxCode.isEmpty {
                    app.activeAuxCode = "ZGDU"
                }
                uiPreview = preview
            }
            .sheet(
                isPresented: Binding(
                    get: { uiPreview != nil },
                    set: { shown in
                        if !shown {
                            uiPreview = nil
                        }
                    }
                )
            ) {
                switch uiPreview {
                case "aux":
                    AuxSessionSheet()
                default:
                    ServerSettingsView()
                }
            }
            #endif
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG
        if let scenario = requestedScreenshotScenario {
            ScreenshotScenarioHost(scenario: scenario)
        } else {
            mainContent
        }
        #else
        mainContent
        #endif
    }

    @ViewBuilder
    private var mainContent: some View {
        if app.aux.isActive || app.aux.requiresRestore {
            AuxSessionView()
        } else if !app.hasLibrary {
            ConnectView()
        } else {
            AppTabsView()
        }
    }

    #if DEBUG
    private var requestedScreenshotScenario: String? {
        let value = ProcessInfo.processInfo.environment["CODEC_SCREENSHOT"] ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    #endif
}

/// Shared by the app and screenshot harness, so previews include the actual
/// navigation and mini player rather than an isolated content screen.
private struct AppTabsView: View {
    @Environment(PlayerController.self) private var player
    @State private var selectedTab: String
    @State private var showNowPlaying = false
    @State private var visualizerFullscreen = false
    #if DEBUG
    @State private var showCapturePalettes = false
    @Environment(DownloadStore.self) private var captureDownloads
    #endif

    init(initialTab: String = "home", opensPlayer: Bool = false) {
        _selectedTab = State(initialValue: initialTab)
        _showNowPlaying = State(initialValue: opensPlayer)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag("home")
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag("search")
            LibraryView()
                .tabItem { Label("Library", systemImage: "square.stack.fill") }
                .tag("library")
            VisualizerView(isFullscreen: $visualizerFullscreen,
                           isActive: selectedTab == "visualizer" && !showNowPlaying)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !visualizerFullscreen, player.currentTrack != nil {
                        MiniPlayerBar(onOpen: openNowPlaying)
                    }
                }
                .tabItem { Label("Visualizer", systemImage: "waveform") }
                .tag("visualizer")
        }
        .environment(\.openNowPlaying, openNowPlaying)
        .sheet(isPresented: $showNowPlaying) { NowPlayingView() }
        #if DEBUG
        .sheet(isPresented: $showCapturePalettes) { ThemePickerView() }
        .task { await followCaptureNavigation() }
        #endif
    }

    private func openNowPlaying() { showNowPlaying = true }

    #if DEBUG
    /// Simulator capture tooling drives the same tabs, sheets and library
    /// destination as taps, without restarting playback between video scenes.
    private func followCaptureNavigation() async {
        guard let name = ProcessInfo.processInfo.environment["CODEC_CAPTURE_CONTROL"],
              name == URL(fileURLWithPath: name).lastPathComponent else { return }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let control = directory.appendingPathComponent(name)
        let status = directory.appendingPathComponent(name + ".status.json")
        var lastData: Data?
        while !Task.isCancelled {
            if let data = try? Data(contentsOf: control), data != lastData,
               let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let screen = request["screen"] as? String {
                lastData = data
                withAnimation(.easeInOut(duration: 0.25)) {
                    showNowPlaying = screen == "player"
                    showCapturePalettes = screen == "themes"
                    switch screen {
                    case "home", "library", "search", "visualizer": selectedTab = screen
                    case "downloaded": selectedTab = "library"
                    default: break
                    }
                }
                NotificationCenter.default.post(name: .init("CodecCaptureDownloads"), object: screen == "downloaded")
                let response: [String: Any] = [
                    "sequence": request["sequence"] ?? 0,
                    "screen": screen,
                    "positionSeconds": player.currentTime,
                    "playing": player.isPlaying,
                    "downloadedCount": captureDownloads.downloadedCount,
                    "timestamp": Date().timeIntervalSince1970
                ]
                if let bytes = try? JSONSerialization.data(withJSONObject: response, options: .sortedKeys) {
                    try? bytes.write(to: status, options: .atomic)
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    #endif
}

#if DEBUG
private struct ScreenshotScenarioHost: View {
    @Environment(\.codecTheme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(ThemeStore.self) private var themeStore
    @Environment(DownloadStore.self) private var downloads

    let scenario: String

    @State private var prepared = false

    var body: some View {
        Group {
            if app.hasLibrary {
                scenarioView
            } else {
                ProgressView()
                    .tint(theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.bg)
            }
        }
        .task {
            await prepare()
            if ProcessInfo.processInfo.environment["CODEC_SCREENSHOT_SCROLL"] == "bottom" {
                // Exercise the real scroll container, including its actual
                // adjusted safe-area insets, for native screenshot checks.
                for _ in 0..<3 {
                    try? await Task.sleep(for: .milliseconds(700))
                    guard !Task.isCancelled else { return }
                    scrollToBottom()
                }
            }
        }
    }

    private func scrollToBottom() {
        func scrollViews(in view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for scroll in windows.flatMap({ scrollViews(in: $0) }) where scroll.bounds.height > 200 {
            let bottom = max(-scroll.adjustedContentInset.top,
                             scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: bottom), animated: false)
        }
    }

    @ViewBuilder
    private var scenarioView: some View {
        switch scenario {
        case "library":
            AppTabsView(initialTab: "library")
        case "liked":
            NavigationStack {
                TrackListView(title: "Liked Songs", tracks: app.likedTracks)
            }
            .environment(\.openNowPlaying, {})
        case "songs":
            NavigationStack {
                TrackListView(title: "Songs", tracks: app.tracks)
            }
            .environment(\.openNowPlaying, {})
        case "playlist":
            NavigationStack {
                if let playlist = app.userPlaylists.first {
                    PlaylistDetailView(playlistID: playlist.id)
                } else {
                    LibraryView()
                }
            }
            .environment(\.openNowPlaying, {})
        case "search":
            AppTabsView(initialTab: "search")
        case "visualizer":
            AppTabsView(initialTab: "visualizer")
        case "player":
            AppTabsView(opensPlayer: true)
        case "queue":
            QueueView()
        case "add-to-playlist":
            if let track = player.currentTrack ?? app.tracks.first {
                AddToPlaylistSheet(track: track)
            } else {
                LibraryView()
            }
        case "themes":
            ThemePickerView()
        case "settings":
            ServerSettingsView()
        case "aux":
            AuxSessionSheet()
        default:
            AppTabsView(initialTab: "home")
        }
    }

    private func prepare() async {
        guard !prepared else {
            return
        }
        prepared = true

        let environment = ProcessInfo.processInfo.environment
        if let theme = environment["CODEC_SCREENSHOT_THEME"], !theme.isEmpty {
            themeStore.themeID = theme
        }
        if let server = environment["CODEC_SCREENSHOT_SERVER"], !server.isEmpty {
            app.serverURLString = server
        } else if app.serverURLString.isEmpty {
            app.serverURLString = "http://127.0.0.1:8899"
        }

        player.client = app.client
        player.resolveTrack = { [weak app] reference in
            app?.track(matching: reference)
        }
        if !app.hasLibrary || app.connection != .connected {
            await app.connect()
        }
        player.client = app.client
        app.syncPlayer(player)

        let usesRealPlayback = environment["CODEC_SCREENSHOT_PLAYBACK"] == "1"
        if !usesRealPlayback, app.activeAuxCode.isEmpty {
            app.activeAuxCode = "8K2F"
            app.activeAuxIsGuest = false
        }

        guard environment["CODEC_SCREENSHOT_PLAYER"] != "none" else { return }
        if usesRealPlayback, environment["CODEC_CAPTURE_CONTROL"] != nil {
            // Read the library only after startup has replaced a previous
            // fixture's cached media URLs with this capture server's URLs.
            try? await Task.sleep(for: .seconds(2))
            if app.connection != .connected { await app.connect() }
            player.client = app.client
            app.syncPlayer(player)
            _ = await player.reconcilePlayback(force: true)
        }
        let tracks = app.tracks
        let requestedTitle = environment["CODEC_SCREENSHOT_TRACK"] ?? "Headroom"
        guard let current = tracks.first(where: { $0.title == requestedTitle }) ?? tracks.first else {
            return
        }
        if usesRealPlayback {
            if environment["CODEC_CAPTURE_CONTROL"] != nil {
                if let client = app.client {
                    var albums: Set<String> = []
                    let selection = tracks.filter { albums.insert($0.album ?? "").inserted }.prefix(8)
                    for track in selection { downloads.remove(track) }
                    downloads.downloadAll(Array(selection), using: client)
                }
            }
            let playlist = app.userPlaylists.first { app.tracks(in: $0).contains(where: { $0.id == current.id }) }
            let source = playlist.map { app.tracks(in: $0) } ?? tracks
            player.play(current, from: source, playlistID: playlist?.id)
            player.transferPlayback(to: player.deviceID)
            return
        }
        let source = tracks.isEmpty ? [current] : tracks
        let queued = Array(source.filter { $0.id != current.id }.prefix(3))
        player.configureForScreenshot(current: current, source: source, queued: queued)
    }
}

private struct ScreenshotSearchView: View {
    @Environment(\.codecTheme) private var theme

    let query: String
    let results: [CodecTrack]

    var body: some View {
        NavigationStack {
            List {
                ForEach(results) { track in
                    PlayableTrackRow(track: track, collection: results)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            .navigationTitle("Search")
            .searchable(
                text: .constant(query),
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Songs, artists, albums"
            )
        }
    }
}
#endif

private struct OpenNowPlayingKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

extension EnvironmentValues {
    var openNowPlaying: (@MainActor () -> Void)? {
        get { self[OpenNowPlayingKey.self] }
        set { self[OpenNowPlayingKey.self] = newValue }
    }
}

/// Attach to the actual List/ScrollView inside the navigation stack. This
/// reserves the measured player height in the scrollable area, including on
/// pushed collections, while TabView supplies the system tab-bar safe area.
struct MiniPlayerInset: ViewModifier {
    @Environment(PlayerController.self) private var player
    @Environment(\.openNowPlaying) private var onOpen

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: player.currentTrack != nil && onOpen != nil ? 12 : 0) {
            if player.currentTrack != nil, let onOpen {
                MiniPlayerBar(onOpen: onOpen)
            }
        }
    }
}

/// Floating card with the deck's materials: theme panel, hairline border,
/// accent progress ticking along the bottom.
struct MiniPlayerBar: View {
    @Environment(\.codecTheme) private var theme
    @Environment(PlayerController.self) private var player

    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(track: player.currentTrack, size: 40, cornerRadius: 8)
                .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(player.currentTrack?.title ?? "")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text(player.currentTrack?.artist ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                player.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(theme.text)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .foregroundStyle(theme.text)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        }
        .overlay(alignment: .bottom) {
            MiniPlayerProgress()
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .allowsHitTesting(false)
        }
        .shadow(color: theme.buttonShadow, radius: 12, x: 0, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

}

/// Clock updates redraw just the thin progress strip while Library scrolls.
private struct MiniPlayerProgress: View {
    @Environment(\.codecTheme) private var theme
    @Environment(PlayerController.self) private var player

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(theme.accent)
                .frame(width: max(proxy.size.width * progress, 0), height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    private var progress: Double {
        guard player.duration > 0 else {
            return 0
        }
        return min(max(player.currentTime / player.duration, 0), 1)
    }
}
