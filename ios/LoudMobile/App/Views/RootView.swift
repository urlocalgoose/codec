import SwiftUI

struct RootView: View {
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
        }
    }

    private func openNowPlaying() {
        showNowPlaying = true
    }
}

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

/// Floating material card, Apple-Music style.
struct MiniPlayerBar: View {
    @Environment(PlayerController.self) private var player

    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(track: player.currentTrack, size: 40, cornerRadius: 8)
                .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1)

            Text(player.currentTrack?.title ?? "")
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                player.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
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
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}
