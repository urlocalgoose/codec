import SwiftUI

@main
struct LoudMobileApp: App {
    @State private var app = AppModel()
    @State private var player = PlayerController()
    @State private var downloads = DownloadStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(player)
                .environment(downloads)
                .preferredColorScheme(.dark)
                .tint(LoudColor.accent)
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
