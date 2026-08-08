import SwiftUI

struct RootView: View {
    @Environment(\.loudTheme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player

    @State private var showNowPlaying = false

    var body: some View {
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
            .background(theme.bg)
        }
    }

    private func openNowPlaying() {
        showNowPlaying = true
    }
}

/// Insets each tab's content with the mini player so it sits above the tab
/// bar instead of covering it (a bottom inset on the TabView itself would
/// draw over the bar).
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

/// The always-visible strip above the tab bar: tap for the full player.
struct MiniPlayerBar: View {
    @Environment(\.loudTheme) private var theme
    @Environment(PlayerController.self) private var player

    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(track: player.currentTrack, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentTrack?.title ?? "")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text(player.currentTrack?.artist ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Button {
                player.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(theme.text)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.panel)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.line)
                .frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(theme.accent)
                .frame(height: 2)
        }
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
