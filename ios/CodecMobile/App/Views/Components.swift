import AVKit
import MediaPlayer
import SwiftUI

/// The system output picker: AirPods, Bluetooth speakers, AirPlay, CarPlay.
/// Wraps AVRoutePickerView since SwiftUI has no native equivalent.
struct AudioRoutePicker: UIViewRepresentable {
    var tint: Color
    var activeTint: Color

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {
        picker.tintColor = UIColor(tint)
        picker.activeTintColor = UIColor(activeTint)
    }
}

struct SectionLabel: View {
    @Environment(\.codecTheme) private var theme

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
    @Environment(\.codecTheme) private var theme
    @Environment(AppModel.self) private var app

    let track: CodecTrack?
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 6

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
                    .font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(theme.subtle)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: track?.fingerprint) {
            guard let track, let client = app.client, let url = client.artworkURL(for: track) else {
                image = nil
                return
            }
            // Cached artwork paints synchronously — no placeholder flash
            // when rows are recycled or rebuilt.
            if let cached = ArtworkLoader.cachedImage(for: url) {
                image = cached
                return
            }
            image = nil
            image = await ArtworkLoader.shared.image(for: url, headers: client.authHeaders)
        }
    }
}

struct TrackRow: View {
    @Environment(\.codecTheme) private var theme
    @Environment(PlayerController.self) private var player
    @Environment(DownloadStore.self) private var downloads

    let track: CodecTrack
    var showsDownloadState = true

    private var isCurrent: Bool {
        player.currentTrack?.id == track.id
    }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(track: track)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 15, weight: isCurrent ? .heavy : .semibold))
                    .foregroundStyle(isCurrent ? theme.accent : theme.text)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if showsDownloadState, downloads.isDownloaded(track) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(theme.accent)
                    }
                    Text(track.artist)
                        .font(.footnote)
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            if isCurrent {
                Image(systemName: player.isPlaying ? "waveform" : "pause")
                    .font(.footnote)
                    .foregroundStyle(theme.accent)
                    .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
            } else {
                Text(formatDuration(track.durationSeconds))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(theme.subtle)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// A track row wired for a List: tap to play, swipe right to queue, swipe
/// left to like or download, long-press for the full menu.
struct PlayableTrackRow: View {
    @Environment(\.codecTheme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(DownloadStore.self) private var downloads

    let track: CodecTrack
    let collection: [CodecTrack]
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
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(theme.line)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                player.playNext(track)
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .tint(theme.accent)

            Button {
                player.playLater(track)
            } label: {
                Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            .tint(theme.surfaceHover)
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
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            player.playLater(track)
        } label: {
            Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
        }

        Menu {
            ForEach(app.userPlaylists) { playlist in
                Button(playlist.name) {
                    app.addTrack(track, to: playlist)
                }
            }
            if !app.userPlaylists.isEmpty {
                Divider()
            }
            Button {
                app.pendingNewPlaylistTrack = track
            } label: {
                Label("New Playlist", systemImage: "plus")
            }
        } label: {
            Label("Add to Playlist", systemImage: "music.note.list")
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

/// One list of playable tracks: sleek list bones, deck keys on top.
struct TrackListView: View {
    @Environment(\.codecTheme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(DownloadStore.self) private var downloads

    let title: String
    let tracks: [CodecTrack]
    var showsDownloadAll = true

    enum TrackSort: String, CaseIterable, Identifiable {
        case standard = "Default"
        case title = "Title"
        case artist = "Artist"
        case newest = "Newest"

        var id: String { rawValue }
    }

    @State private var sort: TrackSort = .standard

    private var sortedTracks: [CodecTrack] {
        switch sort {
        case .standard:
            return tracks
        case .title:
            return tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            return tracks.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .newest:
            return tracks.sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }
        }
    }

    var body: some View {
        List {
            HStack(spacing: 10) {
                Button {
                    player.playCollection(sortedTracks)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: player.currentTrack?.id)

                Button {
                    player.playCollection(sortedTracks, shuffled: true)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                if showsDownloadAll, let client = app.client {
                    Button {
                        downloads.downloadAll(tracks, using: client)
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(theme.text)
                            .frame(width: 50)
                            .padding(.vertical, 12)
                            .background(theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 10, trailing: 20))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            ForEach(sortedTracks) { track in
                PlayableTrackRow(track: track, collection: sortedTracks)
            }

            if tracks.isEmpty {
                ContentUnavailableView("No Tracks", systemImage: "music.note")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(TrackSort.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
    }
}

/// System volume slider (the only sanctioned way to set device volume).
struct SystemVolumeSlider: UIViewRepresentable {
    let tint: Color

    func makeUIView(context: Context) -> MPVolumeView {
        MPVolumeView(frame: .zero)
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        view.tintColor = UIColor(tint)
    }
}

/// Brief top-of-screen banner for AppModel error messages.
struct ErrorToast: View {
    @Environment(\.codecTheme) private var theme

    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.text)
            .lineLimit(3)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(theme.danger.opacity(0.6), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 6)
            .padding(.horizontal, 24)
    }
}

func formatDuration(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, seconds > 0 else {
        return "--:--"
    }
    let total = Int(seconds.rounded())
    return "\(total / 60):" + String(format: "%02d", total % 60)
}
