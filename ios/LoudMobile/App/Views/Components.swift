import SwiftUI

/// Tape-deck toggle: while `isOn` the button stays pressed down, like the
/// play key on an old cassette deck. Momentary buttons use DeckButtonStyle.
struct DeckToggleButtonStyle: ButtonStyle {
    let isOn: Bool
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        let down = isOn || configuration.isPressed
        return configuration.label
            .foregroundStyle(primary ? LoudColor.accentText : (isOn ? LoudColor.text : LoudColor.muted))
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(primary ? LoudColor.accent : (down ? LoudColor.buttonPressed : LoudColor.button))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .shadow(color: down ? .clear : LoudColor.shadow, radius: 0, x: 0, y: 5)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(LoudColor.shadow)
                    .frame(height: down ? 1 : 0)
                    .opacity(down ? 1 : 0)
            }
            .offset(y: down ? 5 : 0)
            .animation(.easeOut(duration: 0.09), value: down)
    }
}

struct SectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(LoudColor.subtle)
    }
}

/// Artwork with auth headers and an in-memory cache.
struct ArtworkView: View {
    @Environment(AppModel.self) private var app

    let track: LoudTrack?
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 4

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            LoudColor.panel2
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(LoudColor.subtle)
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
                    .foregroundStyle(player.currentTrack?.id == track.id ? LoudColor.accent : LoudColor.text)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    if showsDownloadState, downloads.isDownloaded(track) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(LoudColor.accent)
                    }
                    Text(track.artist)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LoudColor.muted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Text(formatDuration(track.durationSeconds))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(LoudColor.subtle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .background(player.currentTrack?.id == track.id ? LoudColor.panel2 : Color.clear)
    }
}

/// One list of playable tracks with Play/Shuffle actions on top.
struct TrackListView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(DownloadStore.self) private var downloads

    let title: String
    let tracks: [LoudTrack]
    var showsDownloadAll = true

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
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
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                ForEach(tracks) { track in
                    Button {
                        if player.currentTrack?.id == track.id {
                            player.togglePlayback()
                        } else {
                            player.play(track, from: tracks)
                        }
                    } label: {
                        TrackRow(track: track)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        trackMenu(track)
                    }
                }

                if tracks.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "music.note")
                            .font(.system(size: 30, weight: .bold))
                        Text("No tracks here.")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(LoudColor.subtle)
                    .padding(.top, 60)
                }
            }
            .padding(.bottom, 130)
        }
        .background(LoudColor.bg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
    }

    @ViewBuilder
    private func trackMenu(_ track: LoudTrack) -> some View {
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

func formatDuration(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, seconds > 0 else {
        return "--:--"
    }
    let total = Int(seconds.rounded())
    return "\(total / 60):" + String(format: "%02d", total % 60)
}
