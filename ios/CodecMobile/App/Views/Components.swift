import AVKit
import AVFAudio
import MediaPlayer
import SwiftUI

/// A heading is text, rather than an adaptive toolbar action. Give it its
/// intrinsic width and omit iOS 26's shared button background so it cannot
/// collapse into an overflow control.
struct ScreenHeader: ToolbarContent {
    @Environment(\.codecTheme) private var theme
    let title: String
    var font: Font = .largeTitle.bold()
    var tracking: CGFloat = 0

    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarLeading) { heading }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) { heading }
        }
    }

    private var heading: some View {
        Text(title)
            .font(font)
            .tracking(tracking)
            .foregroundStyle(theme.text)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityAddTraits(.isHeader)
    }
}

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

/// Deck-style input slot: icon + field on a recessed themed well.
struct DeckField<Content: View>: View {
    @Environment(\.codecTheme) private var theme

    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(theme.subtle)
                .frame(width: 22)

            content
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(theme.text)
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(theme.bg.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(theme.line, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 0, x: 0, y: 2)
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
    @Environment(\.displayScale) private var displayScale
    @Environment(AppModel.self) private var app

    let track: CodecTrack?
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 6

    @State private var image: UIImage?

    private var request: ArtworkRequest? {
        guard let track, let client = app.client, let url = client.artworkURL(for: track) else { return nil }
        return ArtworkRequest(url: url, authorization: client.authHeaders(for: url)["Authorization"],
                              pixelSize: max(1, Int(ceil(size * displayScale))))
    }

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
        .task(id: request) {
            guard let request else {
                image = nil
                return
            }
            // Cached artwork paints synchronously — no placeholder flash
            // when rows are recycled or rebuilt.
            if let cached = ArtworkLoader.cachedImage(for: request.url, headers: request.headers, pixelSize: request.pixelSize) {
                image = cached
                return
            }
            image = nil
            let loaded = await ArtworkLoader.shared.image(for: request.url, headers: request.headers, pixelSize: request.pixelSize)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

/// Artwork straight from an absolute URL (playlist covers): same loader,
/// cache, and auth headers as track artwork.
struct RemoteArtworkView: View {
    @Environment(\.codecTheme) private var theme
    @Environment(\.displayScale) private var displayScale
    @Environment(AppModel.self) private var app

    let urlString: String?
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 6
    var placeholderSymbol: String = "music.note.list"

    @State private var image: UIImage?

    private var request: ArtworkRequest? {
        guard let urlString, let url = URL(string: urlString), let client = app.client else { return nil }
        return ArtworkRequest(url: url, authorization: client.authHeaders(for: url)["Authorization"],
                              pixelSize: max(1, Int(ceil(size * displayScale))))
    }

    var body: some View {
        ZStack {
            theme.panel2
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: placeholderSymbol)
                    .font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(theme.subtle)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: request) {
            guard let request else {
                image = nil
                return
            }
            if let cached = ArtworkLoader.cachedImage(for: request.url, headers: request.headers, pixelSize: request.pixelSize) {
                image = cached
                return
            }
            image = nil
            let loaded = await ArtworkLoader.shared.image(for: request.url, headers: request.headers, pixelSize: request.pixelSize)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

/// Playlist covers favor the chosen image, then an album-art mosaic. Reuse
/// the artwork loader so library cards share authenticated requests/cache.
struct PlaylistArtworkView: View {
    @Environment(\.codecTheme) private var theme
    @Environment(AppModel.self) private var app

    let playlist: CodecPlaylist
    var size: CGFloat = 128
    var cornerRadius: CGFloat = 10

    private var coverTracks: [CodecTrack] {
        guard playlist.artworkURL?.isEmpty ?? true else { return [] }
        var seen = Set<String>()
        var covers: [CodecTrack] = []
        for trackID in playlist.trackIDs {
            guard let track = app.track(withID: trackID) else { continue }
            guard let url = track.artworkURL else { continue }
            // Artwork URLs are track-specific even when an album shares a
            // cover. Prefer distinct albums over four copies of one sleeve.
            let album = track.album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let artist = (track.albumArtist ?? track.artist).lowercased()
            let identity = album.isEmpty || album == "unknown album" ? url.absoluteString : "\(artist)|\(album)"
            guard seen.insert(identity).inserted else { continue }
            covers.append(track)
            if covers.count == 4 { break }
        }
        return covers
    }

    var body: some View {
        let tracks = coverTracks
        Group {
            if let cover = playlist.artworkURL, !cover.isEmpty {
                RemoteArtworkView(urlString: cover, size: size, cornerRadius: cornerRadius)
            } else if tracks.count > 1 {
                VStack(spacing: 0) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<2, id: \.self) { column in
                                ArtworkView(
                                    track: tracks[(row * 2 + column) % tracks.count],
                                    size: size / 2,
                                    cornerRadius: 0
                                )
                            }
                        }
                    }
                }
            } else if let track = tracks.first {
                ArtworkView(track: track, size: size, cornerRadius: cornerRadius)
            } else {
                ZStack {
                    theme.panel2
                    Image(systemName: "music.note.list")
                        .font(.system(size: size * 0.3, weight: .semibold))
                        .foregroundStyle(theme.subtle)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke((theme.isLight ? Color.black : Color.white).opacity(0.1), lineWidth: 1)
        }
        .accessibilityHidden(true)
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
    var playlistID: String? = nil
    var onRemoveFromPlaylist: (() -> Void)? = nil

    var body: some View {
        Button {
            if player.currentTrack?.id == track.id {
                player.togglePlayback(playlistID: playlistID)
            } else {
                player.play(track, from: collection, playlistID: playlistID)
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
            if !app.activeAuxIsGuest {
                if let onRemoveFromPlaylist {
                    Button(role: .destructive) {
                        guard !app.activeAuxIsGuest else { return }
                        onRemoveFromPlaylist()
                    } label: {
                        Label("Remove from Playlist", systemImage: "minus.circle")
                    }
                    .tint(theme.danger)
                } else {
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
                            Label("Remove Download", systemImage: "trash")
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
            }
        }
        .contextMenu {
            trackMenu
        }
    }

    @ViewBuilder
    private var trackMenu: some View {
        if !app.activeAuxIsGuest {
            Button {
                app.toggleLike(track)
            } label: {
                Label(
                    app.isLiked(track) ? "Unlike" : "Like",
                    systemImage: app.isLiked(track) ? "heart.slash" : "heart"
                )
            }
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

        if !app.activeAuxIsGuest {
            Button {
                app.playlistPickerTrack = track
            } label: {
                Label("Add to Playlist", systemImage: "music.note.list")
            }

            if let onRemoveFromPlaylist {
                Button(role: .destructive) {
                    guard !app.activeAuxIsGuest else { return }
                    onRemoveFromPlaylist()
                } label: {
                    Label("Remove from Playlist", systemImage: "minus.circle")
                }
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
}

/// One list of playable tracks: sleek list bones, deck keys on top.
/// Visible tap reaction that works no matter how a List handles the press:
/// every fire of the trigger bounces the view with a spring.
struct TapBounce: ViewModifier {
    let trigger: Int

    @State private var pressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? 0.90 : 1)
            .onChange(of: trigger) {
                withAnimation(.spring(response: 0.12, dampingFraction: 0.6)) {
                    pressed = true
                }
                Task {
                    try? await Task.sleep(for: .milliseconds(120))
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.45)) {
                        pressed = false
                    }
                }
            }
    }
}

/// Play / Shuffle / Download-all header shared by track lists and playlists.
/// Every tap lands with a haptic, and the download button reflects real
/// state: idle, aggregate progress while transferring, checkmark when the
/// whole collection is offline.
struct CollectionActionHeader: View {
    @Environment(\.codecTheme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(DownloadStore.self) private var downloads

    let tracks: [CodecTrack]
    var showsDownloadAll = true
    var playlistID: String? = nil

    @State private var playTaps = 0
    @State private var shuffleTaps = 0
    @State private var downloadTaps = 0

    var body: some View {
        HStack(spacing: 10) {
            Button {
                playTaps += 1
                player.playCollection(tracks, playlistID: playlistID)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.accentText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .modifier(TapBounce(trigger: playTaps))
            .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.9), trigger: playTaps)

            Button {
                shuffleTaps += 1
                player.playCollection(tracks, shuffled: true, playlistID: playlistID)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .modifier(TapBounce(trigger: shuffleTaps))
            .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.7), trigger: shuffleTaps)

            if showsDownloadAll, let client = app.client, !tracks.isEmpty {
                downloadAllButton(client)
            }
        }
        .padding(.vertical, 6)
        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 10, trailing: 20))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func downloadAllButton(_ client: CodecClient) -> some View {
        let downloaded = tracks.filter { downloads.isDownloaded($0) }.count
        let transferring = tracks.contains { downloads.isDownloading($0) }

        if downloaded == tracks.count {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 50, height: 46)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if transferring {
            ProgressView(value: max(Double(downloaded) / Double(max(tracks.count, 1)), 0.03))
                .progressViewStyle(.circular)
                .tint(theme.accent)
                .scaleEffect(0.8)
                .frame(width: 50, height: 46)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            Button {
                downloadTaps += 1
                downloads.downloadAll(tracks, using: client)
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .frame(width: 50, height: 46)
                    .background(theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .modifier(TapBounce(trigger: downloadTaps))
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.8), trigger: downloadTaps)
        }
    }
}

struct TrackListView: View {
    @Environment(\.codecTheme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(DownloadStore.self) private var downloads

    let title: String
    let tracks: [CodecTrack]
    var showsDownloadAll = true
    var playlistID: String? = nil

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
        let collection = sortedTracks
        List {
            CollectionActionHeader(tracks: collection, showsDownloadAll: showsDownloadAll, playlistID: playlistID)

            ForEach(collection) { track in
                PlayableTrackRow(track: track, collection: collection, playlistID: playlistID)
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
        .modifier(MiniPlayerInset())
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

/// Embed the actual system-output control. Its displayed value, hardware-button
/// updates, and route capabilities all come from iOS rather than a second,
/// optimistic SwiftUI value that can drift from the phone's volume.
struct SystemVolumeSlider: UIViewRepresentable {
    let tint: Color

    func makeUIView(context: Context) -> MPVolumeView {
        let view = SystemVolumeView(frame: .zero)
        // Now Playing already provides AVRoutePickerView beside the queue.
        view.showsRouteButton = false
        view.showsVolumeSlider = true
        view.backgroundColor = .clear
        view.tintColor = UIColor(tint)
        view.accessibilityIdentifier = "nowPlaying.systemVolume"
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        // Theme updates must not replace the control or write volume back.
        view.tintColor = UIColor(tint)
    }
}

private final class SystemVolumeView: MPVolumeView {
    override func volumeSliderRect(forBounds bounds: CGRect) -> CGRect {
        let slider = super.volumeSliderRect(forBounds: bounds)
        // Match the existing 30pt row without depending on private subviews or
        // the system slider's version-specific vertical inset.
        return CGRect(x: slider.minX, y: bounds.midY - slider.height / 2,
                      width: slider.width, height: slider.height)
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
