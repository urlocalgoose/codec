import SwiftUI

@main
struct LoudMobileApp: App {
    @State private var app = AppModel()
    @State private var player = PlayerController()
    @State private var downloads = DownloadStore()
    @State private var themeStore = ThemeStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(player)
                .environment(downloads)
                .environment(themeStore)
                .environment(\.loudTheme, themeStore.theme)
                .preferredColorScheme(themeStore.theme.isLight ? .light : .dark)
                .tint(themeStore.theme.accent)
                .task {
                    player.downloads = downloads
                    player.client = app.client
                    player.resolveTrack = { [weak app] reference in
                        app?.track(matching: reference)
                    }
                    if app.hasLibrary || !app.serverURLString.isEmpty {
                        await app.connect()
                        app.syncPlayer(player)
                    }
                }
        }
    }
}
