import SwiftUI

struct SectionLabel: View {
    @Environment(\.loudTheme) private var theme
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(theme.subtle)
    }
}

/// Artwork with auth headers and an in-memory cache.
struct ArtworkView: View {
    @Environment(\.loudTheme) private var theme
    @Environment(AppModel.self) private var app

    let track: LoudTrack?
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 4

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            theme.panel2
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(theme.subtle)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: track?.fingerprint) {
            image = nil
            guard let track, let client = app.client, let url = client.artworkURL(for: track) else {
                return
            }
            image = await ArtworkLoader.shared.image(for: url, headers: client.authHeaders)
        }
    }
}

struct TrackRow: View {
    @Environment(\.loudTheme) private var theme
    @Environment(PlayerController.self) private var player
    @Environment(DownloadStore.self) private var downloads

    let track: LoudTrack
    var showsDownloadState = true

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(track: track)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(player.currentTrack?.id == track.id ? theme.accent : theme.text)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    if showsDownloadState, downloads.isDownloaded(track) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.accent)
                    }
                    Text(track.artist)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Text(formatDuration(track.durationSeconds))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.subtle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .background(player.currentTrack?.id == track.id ? theme.panel2 : Color.clear)
    }
}

/// A track row wired for a List: tap to play, swipe right to queue, swipe
/// left to like or download, long-press for the full menu.
struct PlayableTrackRow: View {
    @Environment(\.loudTheme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(DownloadStore.self) private var downloads

    let track: LoudTrack
    let collection: [LoudTrack]
    var showsDownloadState = true

    var body: some View {
        Button {
            if player.currentTrack?.id == track.id {
                player.togglePlayback()
            } else {
                player.play(track, from: collection)
            }
        } label: {
            TrackRow(track: track, showsDownloadState: showsDownloadState)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(theme.line)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                player.playNext(track)
            } label: {
                Label("Queue", systemImage: "text.badge.plus")
            }
            .tint(theme.accent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                app.toggleLike(track)
            } label: {
                Label(
                    app.isLiked(track) ? "Unlike" : "Like",
                    systemImage: app.isLiked(track) ? "heart.slash.fill" : "heart.fill"
                )
            }
            .tint(theme.accent)

            if downloads.isDownloaded(track) {
                Button {
                    downloads.remove(track)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .tint(theme.danger)
            } else if let client = app.client {
                Button {
                    downloads.download(track, using: client)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                }
                .tint(theme.subtle)
            }
        }
        .contextMenu {
            trackMenu
        }
    }

    @ViewBuilder
    private var trackMenu: some View {
        Button {
            app.toggleLike(track)
        } label: {
            Label(
                app.isLiked(track) ? "Unlike" : "Like",
                systemImage: app.isLiked(track) ? "heart.slash" : "heart"
            )
        }

        Button {
            player.playNext(track)
        } label: {
            Label("Add to Queue", systemImage: "text.badge.plus")
        }

        if downloads.isDownloaded(track) {
            Button(role: .destructive) {
                downloads.remove(track)
            } label: {
                Label("Remove Download", systemImage: "trash")
            }
        } else if let client = app.client {
            Button {
                downloads.download(track, using: client)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
    }
}

/// One list of playable tracks with Play/Shuffle actions on top.
struct TrackListView: View {
    @Environment(\.loudTheme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(DownloadStore.self) private var downloads

    let title: String
    let tracks: [LoudTrack]
    var showsDownloadAll = true

    var body: some View {
        List {
            HStack(spacing: 10) {
                Button {
                    player.playCollection(tracks)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "play.fill")
                        Text("Play")
                    }
                    .font(.system(size: 14, weight: .heavy))
                }
                .buttonStyle(DeckButtonStyle(primary: true))

                Button {
                    player.playCollection(tracks, shuffled: true)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "shuffle")
                        Text("Shuffle")
                    }
                    .font(.system(size: 14, weight: .heavy))
                }
                .buttonStyle(DeckButtonStyle())

                if showsDownloadAll, let client = app.client {
                    Button {
                        downloads.downloadAll(tracks, using: client)
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 15, weight: .heavy))
                    }
                    .buttonStyle(DeckButtonStyle())
                    .frame(width: 62)
                }
            }
            .padding(.vertical, 6)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            ForEach(tracks) { track in
                PlayableTrackRow(track: track, collection: tracks)
            }

            if tracks.isEmpty {
                ContentUnavailableView("No tracks here", systemImage: "music.note")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .foregroundStyle(theme.subtle)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
    }
}

func formatDuration(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, seconds > 0 else {
        return "--:--"
    }
    let total = Int(seconds.rounded())
    return "\(total / 60):" + String(format: "%02d", total % 60)
}
