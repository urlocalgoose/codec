import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player

    @State private var showNowPlaying = false
    @State private var newPlaylistName = ""
    @State private var toastDismissal: Task<Void, Never>?

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
    }

    @ViewBuilder
    private var content: some View {
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
