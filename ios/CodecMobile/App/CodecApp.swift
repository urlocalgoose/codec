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

    @State private var app = AppModel()
    @State private var player = PlayerController()
    @State private var downloads = DownloadStore.shared
    @State private var themeStore = ThemeStore()

    var body: some Scene {
        WindowGroup {
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
                    await ArtworkLoader.shared.pruneDiskCache()
                    if app.hasLibrary || !app.serverURLString.isEmpty {
                        await app.connect()
                        app.syncPlayer(player)
                    }
                }
        }
    }
}
