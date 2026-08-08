import SwiftUI

/// Artwork with auth headers and an in-memory cache.
struct ArtworkView: View {
    @Environment(AppModel.self) private var app

    let track: LoudTrack?
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 6

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.34, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
    @Environment(PlayerController.self) private var player
    @Environment(DownloadStore.self) private var downloads

    let track: LoudTrack
    var showsDownloadState = true

    private var isCurrent: Bool {
        player.currentTrack?.id == track.id
    }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(track: track)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if showsDownloadState, downloads.isDownloaded(track) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(track.artist)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            if isCurrent {
                Image(systemName: player.isPlaying ? "waveform" : "pause")
                    .font(.footnote)
                    .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
            } else {
                Text(formatDuration(track.durationSeconds))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// A track row wired for a List: tap to play, swipe right to queue, swipe
/// left to like or download, long-press for the full menu.
struct PlayableTrackRow: View {
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
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                player.playNext(track)
            } label: {
                Label("Queue", systemImage: "text.badge.plus")
            }
            .tint(.orange)
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
            .tint(.pink)

            if downloads.isDownloaded(track) {
                Button {
                    downloads.remove(track)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .tint(.red)
            } else if let client = app.client {
                Button {
                    downloads.download(track, using: client)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                }
                .tint(.gray)
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

/// One list of playable tracks with the Apple-Music-style capsule actions.
struct TrackListView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(DownloadStore.self) private var downloads

    let title: String
    let tracks: [LoudTrack]
    var showsDownloadAll = true

    var body: some View {
        List {
            HStack(spacing: 12) {
                capsuleButton("Play", systemImage: "play.fill") {
                    player.playCollection(tracks)
                }
                capsuleButton("Shuffle", systemImage: "shuffle") {
                    player.playCollection(tracks, shuffled: true)
                }
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 10, trailing: 20))
            .listRowSeparator(.hidden)

            ForEach(tracks) { track in
                PlayableTrackRow(track: track, collection: tracks)
            }

            if tracks.isEmpty {
                ContentUnavailableView("No Tracks", systemImage: "music.note")
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if showsDownloadAll, let client = app.client {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        downloads.downloadAll(tracks, using: client)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                }
            }
        }
    }

    private func capsuleButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .disabled(tracks.isEmpty)
    }
}

func formatDuration(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, seconds > 0 else {
        return "--:--"
    }
    let total = Int(seconds.rounded())
    return "\(total / 60):" + String(format: "%02d", total % 60)
}
