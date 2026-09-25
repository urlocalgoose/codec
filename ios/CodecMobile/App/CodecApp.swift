import SwiftUI

/// Receives the relaunch callback when background downloads finish while
/// the app is dead, and hands the completion handler to the session's
/// coordinator.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        DownloadStore.shared.setBackgroundCompletionHandler(completionHandler)
    }
}

@main
struct CodecApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @Environment(\.scenePhase) private var scenePhase
    @State private var app = AppModel()
    @State private var player = PlayerController()
    @State private var downloads: DownloadStore = {
        #if DEBUG
        // Simulator preview captures use the real downloader/coordinator, but
        // avoid background-daemon scheduling for their isolated loopback server.
        if ProcessInfo.processInfo.environment["CODEC_CAPTURE_CONTROL"] != nil {
            return DownloadStore(configuration: .default)
        }
        #endif
        return DownloadStore.shared
    }()
    @State private var themeStore = ThemeStore()
    @State private var foregroundGate = PlaybackForegroundGate()
    @State private var foregroundRefreshTask: Task<Void, Never>?

    var body: some Scene {
        WindowGroup {
            // Hosted unit tests construct their own models and fixtures. Keep
            // saved server settings from starting real network/audio work.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                Color.clear
            } else {
                RootView()
                    .environment(app)
                    .environment(player)
                    .environment(downloads)
                    .environment(themeStore)
                    .environment(\.codecTheme, themeStore.theme)
                    .preferredColorScheme(themeStore.theme.isLight ? .light : .dark)
                    .tint(themeStore.theme.accent)
                    .task {
                        player.downloads = downloads
                        player.client = app.client
                        player.resolveTrack = { [weak app] reference in
                            app?.track(matching: reference)
                        }
                        player.refreshLibrary = { [weak app] in await app?.refresh() ?? false }
                        player.reportSyncError = { [weak app] message in app?.errorMessage = message }
                        player.reportSyncFailure = { [weak app] error in app?.reportSyncFailure(error) }
                        app.configurePlaylistPlaybackTracking(player)
                        app.startConnectionMonitoring()
                        app.syncPlayer(player)
                        prepareDownloadedArtwork()
                        Task { await ArtworkLoader.shared.pruneDiskCache() }
                        if app.hasLibrary || !app.serverURLString.isEmpty {
                            await app.connect()
                            app.syncPlayer(player)
                        }
                        await app.aux.restore(personal: app.client, player: player)
                    }
                    .task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: player.auxDiscoveryPollInterval)
                            guard !Task.isCancelled else { return }
                            if app.aux.requiresRestore { await app.aux.restore(personal: app.client, player: player) }
                            else { await app.refreshAuthorizedHostSession(player: player) }
                        }
                    }
                    .onChange(of: app.aux.isActive) { app.syncPlayer(player) }
                    .onChange(of: app.canReachServer) {
                        app.syncPlayer(player)
                        if app.canReachServer {
                            downloads.retryPendingDownloads()
                            prepareDownloadedArtwork()
                        }
                    }
                    .onChange(of: app.networkAvailability) {
                        downloads.setNetworkAvailable(app.networkAvailability != .unavailable)
                    }
                    .onChange(of: app.library) { prepareDownloadedArtwork() }
                    .onChange(of: scenePhase) {
                        if foregroundGate.shouldRefresh(after: scenePhase), foregroundRefreshTask == nil {
                            foregroundRefreshTask = Task {
                                defer { foregroundRefreshTask = nil }
                                await app.refreshIfNeeded()
                                guard scenePhase == .active, !Task.isCancelled else { return }
                                app.syncPlayer(player)
                                await app.refreshAuthorizedHostSession(player: player)
                                if app.aux.isActive { await app.aux.refresh() }
                                else { await player.reconcilePlayback() }
                            }
                        }
                    }
                    .onOpenURL { url in
                        handleAuxLink(url)
                    }
            }
        }
    }

    private func prepareDownloadedArtwork() {
        guard let client = app.client, let library = app.library else { return }
        downloads.prepareArtwork(for: library.tracks, using: client)
    }

    /// Opening an invitation only presents the join screen. Joining requires
    /// an explicit action and never changes the saved personal connection.
    private func handleAuxLink(_ url: URL) {
        #if LOCAL_TEST
        let auxScheme = "codec-test"
        #else
        let auxScheme = "codec"
        #endif
        guard url.scheme == auxScheme else { return }
        guard url.host == "aux-v2",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let secret = components.queryItems?.first(where: { $0.name == "invite" })?.value,
              !secret.isEmpty,
              let address = components.queryItems?.first(where: { $0.name == "server" })?.value,
              let server = URL(string: address),
              ["https", "http"].contains(server.scheme?.lowercased() ?? ""),
              server.host != nil, server.user == nil, server.password == nil,
              server.query == nil, server.fragment == nil
        else {
            app.errorMessage = "Ask the host for a new Aux invitation. This link uses an unsupported version."
            return
        }
        app.aux.presentInvitation(server: server, secret: secret)
    }

}

/// Notification Center and system overlays temporarily make the scene inactive.
/// Audio and the sync loops keep running, so those transitions must not launch
/// another foreground refresh. Initial connection is owned by the root task.
struct PlaybackForegroundGate {
    private var hasEnteredBackground = false

    mutating func shouldRefresh(after phase: ScenePhase) -> Bool {
        switch phase {
        case .background:
            hasEnteredBackground = true
            return false
        case .active:
            defer { hasEnteredBackground = false }
            return hasEnteredBackground
        default:
            return false
        }
    }
}
