import Foundation
import Observation

/// Connection + library state for the whole app.
@MainActor
@Observable
final class AppModel {
    enum Connection: Equatable {
        case disconnected
        case connecting
        case connected
        case offline
    }

    private enum StorageKey {
        static let serverURL = "loud.serverURL"
        static let token = "loud.serverToken"
    }

    var serverURLString: String {
        didSet { UserDefaults.standard.set(serverURLString, forKey: StorageKey.serverURL) }
    }
    var token: String {
        didSet { UserDefaults.standard.set(token, forKey: StorageKey.token) }
    }

    var connection: Connection = .disconnected
    var library: CodecLibrary? {
        didSet { rebuildTrackIndexes() }
    }
    var errorMessage = ""

    /// O(1) lookups for resolving playback-context references; a 700-track
    /// context resolved by linear scans was enough to jank the main thread.
    private var tracksByID: [String: CodecTrack] = [:]
    private var tracksByFingerprint: [String: CodecTrack] = [:]
    /// Pre-lowercased "title artist album" per track so search does not
    /// re-lowercase the whole library on every keystroke.
    private var searchBlobs: [(blob: String, track: CodecTrack)] = []

    private func rebuildTrackIndexes() {
        let tracks = library?.tracks ?? []
        tracksByID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        tracksByFingerprint = Dictionary(tracks.map { ($0.fingerprint, $0) }, uniquingKeysWith: { first, _ in first })
        searchBlobs = tracks.map { ("\($0.title) \($0.artist) \($0.album)".lowercased(), $0) }
        rebuildCollections()
    }

    private(set) var client: CodecClient?

    init() {
        serverURLString = UserDefaults.standard.string(forKey: StorageKey.serverURL) ?? ""
        token = UserDefaults.standard.string(forKey: StorageKey.token) ?? ""
        if let cached = Self.readCachedLibrary() {
            library = cached
            connection = .offline
        }
        client = makeClient()
        // didSet does not fire during init; index the cached library.
        rebuildTrackIndexes()
    }

    var isConnected: Bool { connection == .connected }
    var hasLibrary: Bool { library != nil }

    func connect() async {
        errorMessage = ""
        serverURLString = normalizeServerURLString(serverURLString)
        guard let nextClient = makeClient() else {
            errorMessage = "Enter a server URL like http://192.168.1.20:8787."
            return
        }

        connection = .connecting
        do {
            let health = try await nextClient.health()
            let nextLibrary = try await nextClient.library()
            client = nextClient
            library = nextLibrary
            connection = .connected
            Self.writeCachedLibrary(nextLibrary)
            lastHealth = health
            await reprobeFastPath()
        } catch {
            connection = library != nil ? .offline : .disconnected
            errorMessage = friendlyMessage(for: error)
        }
    }

    /// The server advertises its LAN URLs; if one answers with the same
    /// identity, media streams go direct instead of through the tunnel.
    /// Re-run whenever the network may have changed (foreground, connect).
    private var lastHealth: CodecHealth?

    func reprobeFastPath() async {
        guard let client, let health = lastHealth else {
            return
        }
        await client.probeFastPath(serverID: health.serverID, lanURLs: health.lanURLs)
    }

    func refresh() async {
        guard let client else {
            return
        }
        do {
            let nextLibrary = try await client.library()
            library = nextLibrary
            connection = .connected
            Self.writeCachedLibrary(nextLibrary)
        } catch {
            connection = .offline
        }
    }

    func disconnect() {
        connection = .disconnected
        library = nil
        client = nil
        serverURLString = ""
        token = ""
        Self.deleteCachedLibrary()
    }

    private func makeClient() -> CodecClient? {
        let normalized = normalizeServerURLString(serverURLString)
        guard !normalized.isEmpty, let url = URL(string: normalized), url.host() != nil else {
            return nil
        }
        return CodecClient(baseURL: url, token: token)
    }

    private func friendlyMessage(for error: Error) -> String {
        if let clientError = error as? CodecClientError {
            return clientError.errorDescription ?? String(describing: clientError)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == -1022 {
            return "iOS blocked this HTTP server. Use an HTTPS URL or rebuild the app."
        }
        return error.localizedDescription
    }

    /// Points the player at the current client and starts or stops shared
    /// playback sync to match the connection state.
    func syncPlayer(_ player: PlayerController) {
        player.client = client
        if isConnected, let client {
            player.startSync(client: client)
        } else {
            player.stopSync()
        }
    }

    // MARK: - Likes

    /// Reads like state from the library (not a stale track copy), so hearts
    /// update everywhere the moment a toggle lands.
    func isLiked(_ track: CodecTrack) -> Bool {
        tracksByFingerprint[track.fingerprint]?.isLiked ?? track.isLiked
    }

    /// Optimistic toggle: flip locally right away, tell the server, roll back
    /// if the server says no.
    func toggleLike(_ track: CodecTrack) {
        guard let client, let current = library else {
            errorMessage = "Connect to the server to like songs."
            return
        }

        let nextLiked = !isLiked(track)
        library = current.settingLiked(fingerprint: track.fingerprint, liked: nextLiked)

        Task {
            do {
                try await client.setLiked(fingerprint: track.fingerprint, liked: nextLiked)
                if let library {
                    Self.writeCachedLibrary(library)
                }
            } catch {
                library = current
                errorMessage = friendlyMessage(for: error)
            }
        }
    }

    // MARK: - Playlists

    /// Set when the user picks "New Playlist" from a track menu; RootView
    /// watches it to present the name prompt.
    var pendingNewPlaylistTrack: CodecTrack?

    func addTrack(_ track: CodecTrack, to playlist: CodecPlaylist) {
        guard let client else {
            errorMessage = "Connect to the server to edit playlists."
            return
        }
        Task {
            do {
                try await client.addToPlaylist(id: playlist.id, fingerprint: track.fingerprint)
                await refresh()
            } catch {
                errorMessage = friendlyMessage(for: error)
            }
        }
    }

    func removeTrack(_ track: CodecTrack, from playlist: CodecPlaylist) {
        guard let client else {
            errorMessage = "Connect to the server to edit playlists."
            return
        }
        Task {
            do {
                try await client.removeFromPlaylist(id: playlist.id, fingerprint: track.fingerprint)
                await refresh()
            } catch {
                errorMessage = friendlyMessage(for: error)
            }
        }
    }

    func createPlaylist(named name: String, adding track: CodecTrack? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        guard let client else {
            errorMessage = "Connect to the server to create playlists."
            return
        }
        Task {
            do {
                let playlist = try await client.createPlaylist(named: trimmed)
                if let track {
                    try await client.addToPlaylist(id: playlist.id, fingerprint: track.fingerprint)
                }
                await refresh()
            } catch {
                errorMessage = friendlyMessage(for: error)
            }
        }
    }

    /// Resolves a `loud.playback.v2` track reference against the library.
    func track(matching reference: CodecTrackReference) -> CodecTrack? {
        tracksByID[reference.id] ?? tracksByFingerprint[reference.fingerprint]
    }

    // MARK: - Library slices

    var tracks: [CodecTrack] { library?.tracks ?? [] }

    // The Home/Library collections are cached and rebuilt once per library
    // change — as computed properties they re-sorted and re-grouped the
    // whole library on every SwiftUI render pass.
    private(set) var likedTracks: [CodecTrack] = []
    private(set) var userPlaylists: [CodecPlaylist] = []
    private(set) var recentlyAdded: [CodecTrack] = []
    /// Albums we actually have, not one stray song tagged with an album name.
    private(set) var fullAlbums: [CodecAlbumSummary] = []
    private(set) var recentItems: [RecentItem] = []

    /// What the Home grid shows: newest first, grouped into album tiles when
    /// we have the album, single-track tiles otherwise, capped so "recently
    /// added" never means "the whole library".
    enum RecentItem: Identifiable {
        case album(CodecAlbumSummary, cover: CodecTrack)
        case single(CodecTrack)

        var id: String {
            switch self {
            case .album(let album, _): return "album:\(album.id)"
            case .single(let track): return "track:\(track.id)"
            }
        }
    }

    private func rebuildCollections() {
        let tracks = library?.tracks ?? []
        likedTracks = tracks.filter(\.isLiked)
        userPlaylists = library?.playlists.filter { !$0.isLiked } ?? []
        fullAlbums = library?.albums.filter { $0.trackCount >= 2 } ?? []

        let sorted = tracks.sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }
        recentlyAdded = Array(sorted.prefix(24))

        let albumsByKey = Dictionary(
            (library?.albums ?? []).map { (albumKey(artist: $0.artist, name: $0.name), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seenAlbums = Set<String>()
        var items: [RecentItem] = []
        for track in sorted {
            if items.count >= 12 {
                break
            }
            let key = albumKey(artist: track.albumArtist ?? track.artist, name: track.album)
            if let album = albumsByKey[key], album.trackCount >= 2 {
                if seenAlbums.insert(key).inserted {
                    items.append(.album(album, cover: track))
                }
            } else {
                items.append(.single(track))
            }
        }
        recentItems = items
    }

    func tracks(in playlist: CodecPlaylist) -> [CodecTrack] {
        let ids = Set(playlist.trackIDs)
        return tracks.filter { ids.contains($0.id) }
    }

    func tracks(inAlbum album: CodecAlbumSummary) -> [CodecTrack] {
        let key = albumKey(artist: album.artist, name: album.name)
        return tracks
            .filter { albumKey(artist: $0.albumArtist ?? $0.artist, name: $0.album) == key }
            .sorted { ($0.trackNumber ?? Int.max) < ($1.trackNumber ?? Int.max) }
    }

    /// Mirrors the server's album bucketing: album artist falls back to
    /// track artist, compared case-insensitively.
    private func albumKey(artist: String, name: String) -> String {
        "\(artist)|\(name)".lowercased()
    }

    func tracks(byArtist artist: CodecArtistSummary) -> [CodecTrack] {
        tracks.filter { $0.artist == artist.name }
    }

    func searchTracks(_ query: String) -> [CodecTrack] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            return []
        }
        return searchBlobs.compactMap { $0.blob.contains(needle) ? $0.track : nil }
    }

    // MARK: - Offline library cache

    private static var cacheURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Codec", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "library.json")
    }

    private static func readCachedLibrary() -> CodecLibrary? {
        guard let data = try? Data(contentsOf: cacheURL) else {
            return nil
        }
        return try? JSONDecoder().decode(CodecLibrary.self, from: data)
    }

    private static func writeCachedLibrary(_ library: CodecLibrary) {
        guard let data = try? JSONEncoder().encode(library) else {
            return
        }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static func deleteCachedLibrary() {
        try? FileManager.default.removeItem(at: cacheURL)
    }
}
