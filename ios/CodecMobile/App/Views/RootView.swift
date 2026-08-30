import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player

    @State private var showNowPlaying = false
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
            .overlay(alignment: .top) {
                if !app.errorMessage.isEmpty {
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
        if !app.hasLibrary {
            ConnectView()
        } else {
            TabView {
                HomeView()
                    .modifier(MiniPlayerInset(onOpen: openNowPlaying))
                    .tabItem {
                        Label("Home", systemImage: "house.fill")
                    }
                SearchView()
                    .modifier(MiniPlayerInset(onOpen: openNowPlaying))
                    .tabItem {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                LibraryView()
                    .modifier(MiniPlayerInset(onOpen: openNowPlaying))
                    .tabItem {
                        Label("Library", systemImage: "square.stack.fill")
                    }
            }
            .sheet(isPresented: $showNowPlaying) {
                NowPlayingView()
            }
        }
    }

    private func openNowPlaying() {
        showNowPlaying = true
    }

    #if DEBUG
    private var requestedScreenshotScenario: String? {
        let value = ProcessInfo.processInfo.environment["CODEC_SCREENSHOT"] ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    #endif
}

#if DEBUG
private struct ScreenshotScenarioHost: View {
    @Environment(\.codecTheme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(ThemeStore.self) private var themeStore

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
        }
    }

    @ViewBuilder
    private var scenarioView: some View {
        switch scenario {
        case "library":
            LibraryView()
                .modifier(MiniPlayerInset(onOpen: {}))
        case "liked":
            NavigationStack {
                TrackListView(title: "Liked Songs", tracks: app.likedTracks)
            }
            .modifier(MiniPlayerInset(onOpen: {}))
        case "songs":
            NavigationStack {
                TrackListView(title: "Songs", tracks: app.tracks)
            }
            .modifier(MiniPlayerInset(onOpen: {}))
        case "playlist":
            NavigationStack {
                if let playlist = app.userPlaylists.first {
                    PlaylistDetailView(playlistID: playlist.id)
                } else {
                    LibraryView()
                }
            }
            .modifier(MiniPlayerInset(onOpen: {}))
        case "search":
            ScreenshotSearchView(query: "warm", results: app.searchTracks("warm"))
                .modifier(MiniPlayerInset(onOpen: {}))
        case "player":
            NowPlayingView()
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
            HomeView()
                .modifier(MiniPlayerInset(onOpen: {}))
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

        if app.activeAuxCode.isEmpty {
            app.activeAuxCode = "8K2F"
            app.activeAuxIsGuest = false
        }

        let tracks = app.tracks
        guard let current = tracks.first(where: { $0.title == "Headroom" }) ?? tracks.first else {
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

/// Insets each tab's content with the mini player so it floats above the tab
/// bar instead of covering it.
private struct MiniPlayerInset: ViewModifier {
    @Environment(PlayerController.self) private var player

    let onOpen: () -> Void

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if player.currentTrack != nil {
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
            GeometryReader { proxy in
                Rectangle()
                    .fill(theme.accent)
                    .frame(width: max(proxy.size.width * progress, 0), height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .allowsHitTesting(false)
        }
        .shadow(color: theme.buttonShadow, radius: 12, x: 0, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    private var progress: Double {
        guard player.duration > 0 else {
            return 0
        }
        return min(max(player.currentTime / player.duration, 0), 1)
    }
}
