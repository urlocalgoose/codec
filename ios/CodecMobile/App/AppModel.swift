import Foundation
import Observation
import UIKit

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
        static let serverURL = "codec.serverURL"
        static let token = "codec.serverToken"
        static let auxCode = "codec.auxCode"
        static let auxIsGuest = "codec.auxIsGuest"
        static let tokenBeforeAuxJoin = "codec.tokenBeforeAuxJoin"
        static let serverBeforeAuxJoin = "codec.serverBeforeAuxJoin"
        static let playlistPlaybackOrder = "codec.playlistPlaybackOrder.v1"
        static let legacyServerURL = "loud.serverURL"
        static let legacyToken = "loud.serverToken"
        static let legacyAuxCode = "loud.auxCode"
        static let legacyAuxIsGuest = "loud.auxIsGuest"
        static let legacyTokenBeforeAuxJoin = "loud.tokenBeforeAuxJoin"
        static let legacyServerBeforeAuxJoin = "loud.serverBeforeAuxJoin"
    }

    var serverURLString: String {
        didSet { UserDefaults.standard.set(serverURLString, forKey: StorageKey.serverURL) }
    }
    var token: String {
        didSet { UserDefaults.standard.set(token, forKey: StorageKey.token) }
    }

    var connection: Connection = .disconnected
    private(set) var connectionIssue: ConnectionIssue?
    private(set) var networkAvailability: NetworkAvailability = .unknown
    private(set) var isReconnecting = false
    var library: CodecLibrary? {
        didSet { updateLibraryCollections(previous: oldValue) }
    }
    var errorMessage = ""
    var auxBusy = false
    var activeAuxCode: String {
        didSet { UserDefaults.standard.set(activeAuxCode, forKey: StorageKey.auxCode) }
    }
    var activeAuxIsGuest: Bool {
        didSet { UserDefaults.standard.set(activeAuxIsGuest, forKey: StorageKey.auxIsGuest) }
    }
    private var tokenBeforeAuxJoin: String {
        didSet { UserDefaults.standard.set(tokenBeforeAuxJoin, forKey: StorageKey.tokenBeforeAuxJoin) }
    }
    private var serverBeforeAuxJoin: String {
        didSet { UserDefaults.standard.set(serverBeforeAuxJoin, forKey: StorageKey.serverBeforeAuxJoin) }
    }

    /// O(1) lookups for resolving playback-context references; a 700-track
    /// context resolved by linear scans was enough to jank the main thread.
    private var tracksByID: [String: CodecTrack] = [:]
    private var tracksByFingerprint: [String: CodecTrack] = [:]
    @ObservationIgnored private var firstIDPositions: [String: Int] = [:]
    @ObservationIgnored private var firstFingerprintPositions: [String: Int] = [:]
    /// Pre-lowercased "title artist album" per track so search does not
    /// re-lowercase the whole library on every keystroke.
    private var searchBlobs: [(blob: String, track: CodecTrack)] = []
    @ObservationIgnored private var recentTrackOrder: [Int] = []
    @ObservationIgnored private var recentAlbumsByKey: [String: CodecAlbumSummary] = [:]

    /// Deterministic work counts for regression tests; not observable UI state.
    struct LibraryCollectionWork: Equatable {
        var fullIndexBuilds = 0
        var searchTextBuilds = 0
        var recentTrackSorts = 0
    }
    @ObservationIgnored private(set) var libraryCollectionWork = LibraryCollectionWork()

    private func updateLibraryCollections(previous: CodecLibrary?) {
        let nextTracks = library?.tracks ?? []
        let previousTracks = previous?.tracks ?? []
        let tracksChanged = nextTracks != previousTracks
        let albumsChanged = library?.albums != previous?.albums
        if tracksChanged {
            updateTrackIndexes(previous: previousTracks, next: nextTracks)
            tracks = nextTracks
            // Playlist memberships and likes change the track values, but not
            // their recent ordering. Reuse the sorted positions in that case.
            if nextTracks.count != previousTracks.count ||
                zip(nextTracks, previousTracks).contains(where: { $0.addedAt != $1.addedAt }) {
                recentTrackOrder = nextTracks.indices.sorted {
                    (nextTracks[$0].addedAt ?? 0) > (nextTracks[$1].addedAt ?? 0)
                }
                libraryCollectionWork.recentTrackSorts += 1
            }
        }
        if albumsChanged {
            recentAlbumsByKey = Dictionary(
                (library?.albums ?? []).map { (albumKey(artist: $0.artist, name: $0.name), $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        updateCollections(tracksChanged: tracksChanged, albumsChanged: albumsChanged)
    }

    private func updateTrackIndexes(previous: [CodecTrack], next: [CodecTrack]) {
        let sameIdentities = previous.count == next.count && zip(previous, next).allSatisfy {
            $0.id == $1.id && $0.fingerprint == $1.fingerprint
        }
        if !sameIdentities {
            tracksByID = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            tracksByFingerprint = Dictionary(next.map { ($0.fingerprint, $0) }, uniquingKeysWith: { first, _ in first })
            firstIDPositions = Dictionary(next.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: min)
            firstFingerprintPositions = Dictionary(next.enumerated().map { ($0.element.fingerprint, $0.offset) }, uniquingKeysWith: min)
            searchBlobs = next.map { (searchText(for: $0), $0) }
            libraryCollectionWork.fullIndexBuilds += 1
            return
        }
        // Keep all returned track metadata current, including playlistIDs,
        // without rebuilding dictionaries or lowercasing the whole library.
        for index in next.indices where next[index] != previous[index] {
            let track = next[index]
            let old = previous[index]
            if firstIDPositions[track.id] == index { tracksByID[track.id] = track }
            if firstFingerprintPositions[track.fingerprint] == index { tracksByFingerprint[track.fingerprint] = track }
            let textChanged = old.title != track.title || old.artist != track.artist || old.album != track.album
            searchBlobs[index] = (textChanged ? searchText(for: track) : searchBlobs[index].blob, track)
        }
    }

    private func searchText(for track: CodecTrack) -> String {
        libraryCollectionWork.searchTextBuilds += 1
        return "\(track.title) \(track.artist) \(track.album)".lowercased()
    }

    private(set) var client: CodecClient?
    @ObservationIgnored private let playlistHistoryDefaults: UserDefaults
    @ObservationIgnored private var playlistPlaybackOrder: [String: [String]]
    private var refreshTask: Task<Bool, Never>?
    private var refreshAgain = false
    private var lastLibraryRefresh: ContinuousClock.Instant?
    @ObservationIgnored private let connectivityMonitor = ConnectivityMonitor()
    @ObservationIgnored private var recoveryEnabled = false
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectClient: CodecClient?
    @ObservationIgnored private var connectionGeneration = 0
    @ObservationIgnored private var recoveryGeneration = 0
    @ObservationIgnored private var libraryCancellation: Task<Void, Never>?
    @ObservationIgnored private var issueBeforePathLoss: ConnectionIssue?
    @ObservationIgnored private let reconnectDelays: [Duration]
    @ObservationIgnored private let clientFactory: @Sendable (URL, String?) -> CodecClient
    private static let cacheQueue = DispatchQueue(label: "codec.library-cache", qos: .utility)

    init(client: CodecClient? = nil, playlistHistoryDefaults: UserDefaults = .standard,
         reconnectDelays: [Duration] = [.seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30)],
         clientFactory: @escaping @Sendable (URL, String?) -> CodecClient = { CodecClient(baseURL: $0, token: $1) }) {
        self.clientFactory = clientFactory
        self.reconnectDelays = reconnectDelays.isEmpty ? [.seconds(30)] : reconnectDelays
        self.playlistHistoryDefaults = playlistHistoryDefaults
        playlistPlaybackOrder = playlistHistoryDefaults.dictionary(forKey: StorageKey.playlistPlaybackOrder) as? [String: [String]] ?? [:]
        serverURLString = Self.storedString(StorageKey.serverURL, legacy: StorageKey.legacyServerURL)
        token = Self.storedString(StorageKey.token, legacy: StorageKey.legacyToken)
        activeAuxCode = Self.storedString(StorageKey.auxCode, legacy: StorageKey.legacyAuxCode)
        activeAuxIsGuest = Self.storedBool(StorageKey.auxIsGuest, legacy: StorageKey.legacyAuxIsGuest)
        tokenBeforeAuxJoin = Self.storedString(
            StorageKey.tokenBeforeAuxJoin,
            legacy: StorageKey.legacyTokenBeforeAuxJoin
        )
        serverBeforeAuxJoin = Self.storedString(
            StorageKey.serverBeforeAuxJoin,
            legacy: StorageKey.legacyServerBeforeAuxJoin
        )
        if client == nil, let cached = Self.readCachedLibrary() {
            library = cached
            connection = .offline
        }
        self.client = client ?? makeClient()
        // didSet does not fire during init; index the cached library.
        updateLibraryCollections(previous: nil)
    }

    private static func storedString(_ key: String, legacy: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? UserDefaults.standard.string(forKey: legacy) ?? ""
    }

    private static func storedBool(_ key: String, legacy: String) -> Bool {
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.bool(forKey: key)
        }
        return UserDefaults.standard.bool(forKey: legacy)
    }

    var isConnected: Bool { connection == .connected }
    var hasLibrary: Bool { library != nil }
    var canReachServer: Bool { isConnected && networkAvailability != .unavailable }
    var connectionStatusTitle: String {
        if connection == .connecting || isReconnecting { return "Reconnecting…" }
        return connectionIssue?.title ?? (isConnected ? "Connected" : "Offline")
    }

    func startConnectionMonitoring(observeSystemNetwork: Bool = true) {
        recoveryEnabled = true
        if observeSystemNetwork {
            connectivityMonitor.start { [weak self] status in self?.updateNetworkAvailability(status) }
        }
    }

    func updateNetworkAvailability(_ status: NetworkAvailability) {
        let previous = networkAvailability
        guard previous != status else { return }
        networkAvailability = status
        if status == .unavailable {
            cancelReconnect()
            connectionGeneration += 1
            refreshTask?.cancel()
            refreshTask = nil
            refreshAgain = false
            let current = client
            let candidate = reconnectClient
            libraryCancellation = Task {
                await current?.cancelPendingLibraryRequest()
                await candidate?.cancelPendingLibraryRequest()
            }
            issueBeforePathLoss = connectionIssue
            connectionIssue = .noNetwork
            connection = hasLibrary || client != nil ? .offline : .disconnected
        } else if previous == .unavailable {
            // A restored path triggers one immediate validation, even when an
            // older HTTP request succeeded shortly before the outage.
            lastLibraryRefresh = nil
            if connectionIssue == .noNetwork {
                connectionIssue = issueBeforePathLoss?.automaticallyRetries == false ? issueBeforePathLoss : .serverUnreachable
            }
            issueBeforePathLoss = nil
            scheduleReconnect(immediate: true)
        } else if connection != .connected && connection != .connecting {
            scheduleReconnect(immediate: true)
        }
    }

    /// Playback/SSE failures share the same recovery loop as library failures.
    /// Connectivity errors never become repeated toasts over local music.
    func reportSyncFailure(_ error: Error) {
        guard connection != .connecting, client != nil else { return }
        if let failure = error as? CodecClientError,
           case .httpStatus(let status, _) = failure, status == 409 { return }
        recordConnectionFailure(error)
    }

    func retryConnection() async {
        guard networkAvailability != .unavailable else { return }
        cancelReconnect()
        if reconnectClient != nil || connectionIssue?.automaticallyRetries == false || client == nil {
            await connect()
        } else {
            _ = await refresh()
        }
    }

    func connect() async {
        cancelPlaylistEdits()
        errorMessage = ""
        serverURLString = normalizeServerURLString(serverURLString)
        cancelReconnect()
        connectionGeneration += 1
        let generation = connectionGeneration
        refreshTask?.cancel()
        refreshTask = nil
        refreshAgain = false
        reconnectClient = nil
        guard let nextClient = makeClient() else {
            connectionIssue = .invalidServer
            connection = hasLibrary ? .offline : .disconnected
            errorMessage = "Enter the address of your Codec server."
            return
        }
        reconnectClient = nextClient
        guard networkAvailability != .unavailable else {
            connectionIssue = .noNetwork
            connection = hasLibrary ? .offline : .disconnected
            errorMessage = ConnectionIssue.noNetwork.title
            return
        }
        connectionIssue = nil
        connection = .connecting
        do {
            await libraryCancellation?.value
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            _ = try await nextClient.health()
            let nextLibrary = try await nextClient.library()
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            guard networkAvailability != .unavailable else { return }
            client = nextClient
            library = nextLibrary
            connection = .connected
            connectionIssue = nil
            reconnectClient = nil
            lastLibraryRefresh = .now
            Self.writeCachedLibrary(nextLibrary)
            await refreshAuxState()
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            recordConnectionFailure(error)
            errorMessage = connectionIssue?.title ?? friendlyMessage(for: error)
        }
    }


    /// Foreground activation is a freshness check, not a library-change event.
    /// Join an existing fetch without requesting another pass, and reuse the
    /// snapshot recently fetched by the background playback presence loop.
    func refreshIfNeeded(maxAge: Duration = .seconds(15)) async {
        guard networkAvailability != .unavailable else { return }
        guard connectionIssue?.automaticallyRetries != false else { return }
        if let refreshTask {
            _ = await refreshTask.value
            return
        }
        guard connection != .connecting else { return }
        if connection == .connected, let lastLibraryRefresh,
           lastLibraryRefresh.duration(to: .now) < maxAge {
            return
        }
        await refresh()
    }

    @discardableResult
    func refresh() async -> Bool {
        // A manually chosen replacement server owns its validation. An old
        // SSE/pull refresh must not mark the previous connection healthy again.
        guard connection != .connecting, reconnectClient == nil else { return false }
        guard let client else { return false }
        guard networkAvailability != .unavailable else { return false }
        // Pending membership changes own the visible playlist until their
        // writes finish. The queue schedules one fresh read when it drains.
        guard pendingPlaylistEdits.isEmpty else { return false }
        if let refreshTask {
            refreshAgain = true
            return await refreshTask.value
        }
        let generation = connectionGeneration
        let task = Task { [weak self] in
            guard let self else { return false }
            await libraryCancellation?.value
            repeat {
                refreshAgain = false
                do {
                    let editRevision = playlistEditRevision
                    let nextLibrary = try await client.library()
                    guard generation == connectionGeneration, !Task.isCancelled,
                          self.client?.baseURL == client.baseURL, self.client?.token == client.token,
                          networkAvailability != .unavailable else { return false }
                    guard pendingPlaylistEdits.isEmpty, editRevision == playlistEditRevision else {
                        // Discard a read begun before a local edit. If the
                        // queue already drained, fetch again after that write.
                        refreshAgain = pendingPlaylistEdits.isEmpty
                        continue
                    }
                    if nextLibrary != library {
                        library = nextLibrary
                        Self.writeCachedLibrary(nextLibrary)
                    }
                    connection = .connected
                    connectionIssue = nil
                    reconnectClient = nil
                    lastLibraryRefresh = .now
                } catch {
                    guard generation == connectionGeneration, !Task.isCancelled,
                          self.client?.baseURL == client.baseURL, self.client?.token == client.token else { return false }
                    recordConnectionFailure(error)
                    return false
                }
            } while refreshAgain && !Task.isCancelled
            return !Task.isCancelled
        }
        refreshTask = task
        let succeeded = await task.value
        if generation == connectionGeneration { refreshTask = nil }
        return succeeded
    }

    private func recordConnectionFailure(_ error: Error) {
        connectionIssue = ConnectionIssue.classify(error, network: networkAvailability)
        connection = hasLibrary || client != nil ? .offline : .disconnected
        lastLibraryRefresh = nil
        scheduleReconnect()
    }

    private func cancelReconnect() {
        recoveryGeneration += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
    }

    private func scheduleReconnect(immediate: Bool = false) {
        guard recoveryEnabled, networkAvailability != .unavailable,
              connectionIssue?.automaticallyRetries != false,
              let target = reconnectClient ?? client else { return }
        if immediate { cancelReconnect() }
        guard reconnectTask == nil else { return }
        let generation = recoveryGeneration
        let connectionID = connectionGeneration
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == recoveryGeneration {
                    reconnectTask = nil
                    isReconnecting = false
                }
            }
            var attempt = 0
            while !Task.isCancelled, generation == recoveryGeneration, connectionID == connectionGeneration,
                  networkAvailability != .unavailable, connectionIssue?.automaticallyRetries != false {
                if !(immediate && attempt == 0) {
                    do { try await Task.sleep(for: reconnectDelays[min(attempt, reconnectDelays.count - 1)]) }
                    catch { return }
                }
                guard !Task.isCancelled, generation == recoveryGeneration else { return }
                if connection == .connected { return }
                isReconnecting = true
                do {
                    await libraryCancellation?.value
                    guard !Task.isCancelled, generation == recoveryGeneration else { return }
                    let editRevision = playlistEditRevision
                    let nextLibrary = try await target.library()
                    guard !Task.isCancelled, generation == recoveryGeneration,
                          connectionID == connectionGeneration, networkAvailability != .unavailable else { return }
                    guard pendingPlaylistEdits.isEmpty, editRevision == playlistEditRevision else {
                        isReconnecting = false
                        attempt += 1
                        continue
                    }
                    client = target
                    if nextLibrary != library {
                        library = nextLibrary
                        Self.writeCachedLibrary(nextLibrary)
                    }
                    connection = .connected
                    connectionIssue = nil
                    reconnectClient = nil
                    errorMessage = ""
                    lastLibraryRefresh = .now
                    return
                } catch {
                    guard !Task.isCancelled, generation == recoveryGeneration else { return }
                    connectionIssue = ConnectionIssue.classify(error, network: networkAvailability)
                    connection = hasLibrary || client != nil ? .offline : .disconnected
                }
                isReconnecting = false
                attempt += 1
            }
        }
    }

    func setPlaylistCover(playlistID: String, imageData: Data) async {
        guard let client else {
            errorMessage = "Connect to the server to change playlist covers."
            return
        }
        guard let image = UIImage(data: imageData), let jpeg = Self.playlistCoverJPEG(from: image) else {
            errorMessage = "That image could not be read."
            return
        }
        do {
            try await client.setPlaylistArtwork(id: playlistID, imageData: jpeg)
            await refresh()
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    /// Covers upload as bounded JPEGs so HEIC photos stay browser-friendly
    /// and the blob stays small.
    private static func playlistCoverJPEG(from image: UIImage, maxDimension: CGFloat = 1024) -> Data? {
        let largest = max(image.size.width, image.size.height)
        let scale = min(1, maxDimension / max(largest, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return scaled.jpegData(compressionQuality: 0.85)
    }

    func disconnect() {
        cancelPlaylistEdits()
        cancelReconnect()
        connectionGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshAgain = false
        reconnectClient = nil
        connectionIssue = nil
        connection = .disconnected
        library = nil
        client = nil
        lastLibraryRefresh = nil
        serverURLString = ""
        token = ""
        activeAuxCode = ""
        activeAuxIsGuest = false
        tokenBeforeAuxJoin = ""
        serverBeforeAuxJoin = ""
        Self.deleteCachedLibrary()
    }

    private func makeClient() -> CodecClient? {
        let normalized = normalizeServerURLString(serverURLString)
        guard !normalized.isEmpty, let url = URL(string: normalized), url.host() != nil else {
            return nil
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let nextClient = clientFactory(url, token)
        if let client, client.baseURL == nextClient.baseURL, client.token == nextClient.token {
            return client
        }
        return nextClient
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

    // MARK: - Aux

    var auxLink: URL? {
        guard !activeAuxCode.isEmpty,
              let url = URL(string: normalizeServerURLString(serverURLString)),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "aux", value: activeAuxCode)]
        return components.url
    }

    func refreshAuxState() async {
        guard let client, !activeAuxIsGuest else {
            return
        }
        do {
            let sessions = try await client.listAuxSessions()
            activeAuxCode = sessions.first?.code ?? ""
            activeAuxIsGuest = false
        } catch {
            activeAuxCode = ""
        }
    }

    func startAux() async {
        guard let client else {
            errorMessage = "Connect to the server before starting an aux."
            return
        }
        auxBusy = true
        defer { auxBusy = false }

        do {
            let session = try await client.createAuxSession()
            activeAuxCode = session.code
            activeAuxIsGuest = false
            tokenBeforeAuxJoin = ""
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    func endAux() async {
        if activeAuxIsGuest {
            await leaveAux()
            return
        }
        guard let client, !activeAuxCode.isEmpty else {
            return
        }
        auxBusy = true
        defer { auxBusy = false }

        do {
            try await client.endAuxSession(code: activeAuxCode)
            activeAuxCode = ""
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    func joinAux(code rawCode: String, server rawServer: String? = nil) async {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty else {
            return
        }
        // A scanned link can point at a friend's server; remember home so
        // leaving the aux goes back there.
        let previousServer = serverURLString
        if let rawServer, !rawServer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            serverURLString = rawServer
        }
        serverURLString = normalizeServerURLString(serverURLString)
        guard let joiningClient = makeClient() else {
            errorMessage = "Enter the server URL before joining an aux."
            serverURLString = previousServer
            return
        }

        let previousConnection = connection
        let previousIssue = connectionIssue
        cancelPlaylistEdits()
        cancelReconnect()
        connectionGeneration += 1
        let generation = connectionGeneration
        refreshTask?.cancel()
        refreshTask = nil
        refreshAgain = false
        reconnectClient = nil
        connection = .connecting
        auxBusy = true
        defer { auxBusy = false }

        do {
            let session = try await joiningClient.joinAuxSession(code: code)
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            guard let guestToken = session.guestToken, !guestToken.isEmpty else {
                throw CodecClientError.invalidResponse
            }
            let guestClient = clientFactory(joiningClient.baseURL, guestToken)
            let nextLibrary = try await guestClient.library()
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            if !activeAuxIsGuest {
                tokenBeforeAuxJoin = token
                serverBeforeAuxJoin = previousServer
            }
            token = guestToken
            client = guestClient
            library = nextLibrary
            connection = .connected
            connectionIssue = nil
            lastLibraryRefresh = .now
            activeAuxCode = session.code
            activeAuxIsGuest = true
            Self.writeCachedLibrary(nextLibrary)
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            errorMessage = friendlyMessage(for: error)
            serverURLString = previousServer
            connection = previousConnection
            connectionIssue = previousIssue
            if connection != .connected { scheduleReconnect() }
        }
    }

    func leaveAux() async {
        guard activeAuxIsGuest else {
            return
        }
        cancelPlaylistEdits()
        auxBusy = true
        defer { auxBusy = false }

        activeAuxCode = ""
        activeAuxIsGuest = false
        token = tokenBeforeAuxJoin
        tokenBeforeAuxJoin = ""
        serverURLString = serverBeforeAuxJoin
        serverBeforeAuxJoin = ""
        client = makeClient()
        await connect()
    }

    /// Transient offline state must retain the reconnect and reconciliation
    /// loops. They restore both playback and library state when networking
    /// recovers; only an explicit disconnect stops synchronization.
    func syncPlayer(_ player: PlayerController) {
        configurePlaylistPlaybackTracking(player)
        // A server connection being validated must not tear down an existing
        // playback session. Switch clients only once the replacement is ready.
        guard connection != .connecting else { return }
        player.setSyncAvailable(canReachServer)
        if (connection == .connected || connection == .offline), let client {
            player.startSync(client: client)
        } else {
            player.stopSync()
            player.client = client
        }
    }

    /// Also installed before startup awaits, while the cached library is
    /// already usable and a fresh server connection is still pending.
    func configurePlaylistPlaybackTracking(_ player: PlayerController) {
        let playbackServerURL = client?.baseURL
        player.recordPlaylistPlayback = { [weak self] playlistID in
            // A delayed command from a previous connection must not reorder
            // an identically named playlist in the newly connected library.
            guard let playbackServerURL else { return }
            self?.recordPlaylistPlayback(playlistID: playlistID, from: playbackServerURL)
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

    /// Set from any track menu's "Add to Playlist"; RootView presents the
    /// playlist picker sheet for it.
    var playlistPickerTrack: CodecTrack?

    private enum PlaylistEdit {
        case add(CodecTrack)
        case remove(CodecTrack)
        case reorder([String])
        case delete

        func applying(to playlist: CodecPlaylist?) -> CodecPlaylist? {
            guard let playlist else { return nil }
            var ids = playlist.trackIDs
            switch self {
            case .add(let track):
                if !ids.contains(track.id) { ids.append(track.id) }
            case .remove(let track): ids.removeAll { $0 == track.id }
            case .reorder(let ordered):
                // A preceding failed membership edit must not be repeated by
                // a reorder that was queued against its optimistic result.
                let members = Set(ids)
                let order = Set(ordered)
                ids = ordered.filter { members.contains($0) } + ids.filter { !order.contains($0) }
            case .delete: return nil
            }
            return CodecPlaylist(id: playlist.id, name: playlist.name, trackIDs: ids,
                                 isLiked: playlist.isLiked, artworkURL: playlist.artworkURL)
        }
    }

    private struct PendingPlaylistEdit {
        let playlistID: String
        let edit: PlaylistEdit
    }

    private struct ConfirmedPlaylist {
        var playlist: CodecPlaylist?
        let index: Int
    }

    @ObservationIgnored private var pendingPlaylistEdits: [PendingPlaylistEdit] = []
    @ObservationIgnored private var confirmedPlaylists: [String: ConfirmedPlaylist] = [:]
    @ObservationIgnored private var playlistEditOrder: [String] = []
    @ObservationIgnored private var playlistEditTask: Task<Void, Never>?
    @ObservationIgnored private var playlistEditGeneration = 0
    @ObservationIgnored private var playlistEditRevision = 0

    func addTrack(_ track: CodecTrack, to playlist: CodecPlaylist) {
        guard let latest = editablePlaylist(playlist.id), !latest.trackIDs.contains(track.id) else { return }
        enqueuePlaylistEdit(.add(track), playlist: latest)
    }

    func removeTrack(_ track: CodecTrack, from playlist: CodecPlaylist) {
        removeTracks([track], from: playlist)
    }

    /// Use track identities, not positions or the view's potentially stale
    /// playlist snapshot. Multiple selected rows disappear in the same turn.
    func removeTracks(_ tracks: [CodecTrack], from playlist: CodecPlaylist) {
        guard editablePlaylist(playlist.id) != nil else { return }
        for track in tracks {
            guard let latest = self.playlist(withID: playlist.id), latest.trackIDs.contains(track.id) else { continue }
            enqueuePlaylistEdit(.remove(track), playlist: latest)
        }
    }

    func movePlaylistTracks(_ playlist: CodecPlaylist, from offsets: IndexSet, to destination: Int) {
        guard let latest = editablePlaylist(playlist.id) else { return }
        // SwiftUI offsets refer to visible tracks; unresolved references must
        // not shift those offsets or silently disappear from the playlist.
        var visible = tracks(in: latest).map(\.id)
        guard destination >= 0, destination <= visible.count,
              offsets.allSatisfy({ visible.indices.contains($0) }) else { return }
        visible.move(fromOffsets: offsets, toOffset: destination)
        var iterator = visible.makeIterator()
        let ordered = latest.trackIDs.map { tracksByID[$0] == nil ? $0 : iterator.next()! }
        guard ordered != latest.trackIDs else { return }
        enqueuePlaylistEdit(.reorder(ordered), playlist: latest)
    }

    func deletePlaylist(_ playlist: CodecPlaylist) {
        guard let latest = editablePlaylist(playlist.id) else { return }
        enqueuePlaylistEdit(.delete, playlist: latest)
    }

    private func editablePlaylist(_ id: String) -> CodecPlaylist? {
        guard !activeAuxIsGuest else {
            errorMessage = "Only the host can edit playlists during Aux."
            return nil
        }
        guard client != nil, library != nil, connection != .connecting,
              networkAvailability != .unavailable else {
            errorMessage = "Connect to the server to edit playlists."
            return nil
        }
        guard let playlist = playlist(withID: id), !playlist.isLiked else { return nil }
        return playlist
    }

    private func enqueuePlaylistEdit(_ edit: PlaylistEdit, playlist: CodecPlaylist) {
        guard let client, let current = library else { return }
        if playlistEditTask == nil { playlistEditOrder = current.playlists.map(\.id) }
        if !playlistEditOrder.contains(playlist.id) { playlistEditOrder.append(playlist.id) }
        if confirmedPlaylists[playlist.id] == nil {
            confirmedPlaylists[playlist.id] = ConfirmedPlaylist(
                playlist: playlist, index: playlistEditOrder.firstIndex(of: playlist.id) ?? 0
            )
        }
        pendingPlaylistEdits.append(PendingPlaylistEdit(playlistID: playlist.id, edit: edit))
        playlistEditRevision += 1
        library = current.replacingPlaylist(id: playlist.id, with: edit.applying(to: playlist))
        guard playlistEditTask == nil else { return }
        let generation = playlistEditGeneration
        playlistEditTask = Task { [weak self] in
            guard let self else { return }
            while let pending = pendingPlaylistEdits.first {
                guard generation == playlistEditGeneration, !Task.isCancelled else { return }
                let id = pending.playlistID
                let confirmed = confirmedPlaylists[id]?.playlist
                let next = pending.edit.applying(to: confirmed)
                do {
                    switch pending.edit {
                    case .add(let track): try await client.addToPlaylist(id: id, fingerprint: track.fingerprint)
                    case .remove(let track): try await client.removeFromPlaylist(id: id, fingerprint: track.fingerprint)
                    case .reorder: try await client.setPlaylistTracks(id: id, trackIDs: next?.trackIDs ?? [])
                    case .delete: try await client.deletePlaylist(id: id)
                    }
                    guard generation == playlistEditGeneration, !Task.isCancelled else { return }
                    confirmedPlaylists[id]?.playlist = next
                } catch {
                    guard generation == playlistEditGeneration, !Task.isCancelled else { return }
                    errorMessage = friendlyMessage(for: error)
                }
                pendingPlaylistEdits.removeFirst()
                // Roll back only this playlist, then replay later intentions.
                // Never replace the entire library with a pre-request copy.
                if let baseline = confirmedPlaylists[id] {
                    let visible = pendingPlaylistEdits.filter { $0.playlistID == id }
                        .reduce(baseline.playlist) { $1.edit.applying(to: $0) }
                    library = library?.replacingPlaylist(id: id, with: visible, at: playlistRestorationIndex(baseline))
                }
            }
            confirmedPlaylists.removeAll()
            playlistEditOrder.removeAll()
            playlistEditTask = nil
            if let library { Self.writeCachedLibrary(library) }
            // One conditional refresh for the whole burst, also reconciling
            // uncertain network failures and changes made on another device.
            await refresh()
        }
    }

    private func cancelPlaylistEdits() {
        playlistEditGeneration += 1
        playlistEditRevision += 1
        playlistEditTask?.cancel()
        playlistEditTask = nil
        for (id, baseline) in confirmedPlaylists.sorted(by: { $0.value.index < $1.value.index }) {
            library = library?.replacingPlaylist(id: id, with: baseline.playlist, at: playlistRestorationIndex(baseline))
        }
        pendingPlaylistEdits.removeAll()
        confirmedPlaylists.removeAll()
        playlistEditOrder.removeAll()
    }

    private func playlistRestorationIndex(_ baseline: ConfirmedPlaylist) -> Int {
        // Earlier playlists may also have been deleted in this burst. Restore
        // relative to the ones that remain, not their shifting array offsets.
        let predecessors = Set(playlistEditOrder.prefix(baseline.index))
        return library?.playlists.filter { predecessors.contains($0.id) }.count ?? 0
    }

    func createPlaylist(named name: String, adding track: CodecTrack? = nil) {
        guard !activeAuxIsGuest else {
            errorMessage = "Only the host can create playlists during Aux."
            return
        }
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
        if let track = tracksByID[reference.id] ?? tracksByFingerprint[reference.fingerprint] {
            return track
        }
        guard let url = reference.mediaURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return CodecTrack(
            id: reference.id, title: reference.title ?? "Shared track", artist: reference.artist ?? "From the aux",
            album: "", artworkURL: reference.artworkURL, audioURL: url, fingerprint: reference.fingerprint
        )
    }

    // MARK: - Library slices

    private(set) var tracks: [CodecTrack] = []

    // The Home/Library collections are cached and rebuilt once per library
    // change — as computed properties they re-sorted and re-grouped the
    // whole library on every SwiftUI render pass.
    private(set) var likedTracks: [CodecTrack] = []
    private(set) var userPlaylists: [CodecPlaylist] = []
    /// Home alone uses listening recency; Library keeps its existing order.
    private(set) var homePlaylists: [CodecPlaylist] = []
    private(set) var recentlyAdded: [CodecTrack] = []
    /// Albums we actually have, not one stray song tagged with an album name.
    private(set) var fullAlbums: [CodecAlbumSummary] = []
    private(set) var recentItems: [RecentItem] = []

    /// What the Home grid shows: newest first, grouped into album tiles when
    /// we have the album, single-track tiles otherwise, capped so "recently
    /// added" never means "the whole library".
    enum RecentItem: Identifiable, Equatable {
        case album(CodecAlbumSummary, cover: CodecTrack)
        case single(CodecTrack)

        var id: String {
            switch self {
            case .album(let album, _): return "album:\(album.id)"
            case .single(let track): return "track:\(track.id)"
            }
        }
    }

    private func updateCollections(tracksChanged: Bool, albumsChanged: Bool) {
        if tracksChanged {
            let liked = tracks.filter(\.isLiked)
            if liked != likedTracks { likedTracks = liked }
            let recent = recentTrackOrder.prefix(24).map { tracks[$0] }
            if recent != recentlyAdded { recentlyAdded = recent }
        }
        let playlists = library?.playlists.filter { !$0.isLiked } ?? []
        if playlists != userPlaylists { userPlaylists = playlists }
        rebuildHomePlaylists()
        if albumsChanged {
            let albums = library?.albums.filter { $0.trackCount >= 2 } ?? []
            if albums != fullAlbums { fullAlbums = albums }
        }
        guard tracksChanged || albumsChanged else { return }
        var seenAlbums = Set<String>()
        var items: [RecentItem] = []
        for index in recentTrackOrder {
            if items.count >= 12 {
                break
            }
            let track = tracks[index]
            let key = albumKey(artist: track.albumArtist ?? track.artist, name: track.album)
            if let album = recentAlbumsByKey[key], album.trackCount >= 2 {
                if seenAlbums.insert(key).inserted {
                    items.append(.album(album, cover: track))
                }
            } else {
                items.append(.single(track))
            }
        }
        if items != recentItems { recentItems = items }
    }

    /// Record an explicit playlist playback action, never a visit or a song
    /// that happens to belong to multiple playlists. The playback protocol
    /// does not identify playlists, so this history stays local to the device
    /// and is isolated by server rather than inferred from remote queues.
    func recordPlaylistPlayback(playlistID: String, from serverURL: URL? = nil) {
        if let serverURL, serverURL != client?.baseURL { return }
        guard let scope = playlistHistoryScope,
              let playlist = userPlaylists.first(where: { $0.id == playlistID }),
              !playlist.trackIDs.isEmpty else { return }
        var order = playlistPlaybackOrder[scope] ?? []
        guard order.first != playlistID else { return }
        let existingIDs = Set(userPlaylists.map(\.id))
        order.removeAll { $0 == playlistID || !existingIDs.contains($0) }
        order.insert(playlistID, at: 0)
        playlistPlaybackOrder[scope] = order
        playlistHistoryDefaults.set(playlistPlaybackOrder, forKey: StorageKey.playlistPlaybackOrder)
        rebuildHomePlaylists()
    }

    private var playlistHistoryScope: String? {
        guard let url = client?.baseURL else { return nil }
        // Server normalization already removes trailing slashes. Do not store
        // authorization tokens in a preferences key or playback history.
        return url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func rebuildHomePlaylists() {
        let order = playlistHistoryScope.flatMap { playlistPlaybackOrder[$0] } ?? []
        let ranks = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        let playlists = userPlaylists.enumerated().sorted { left, right in
            let leftRank = ranks[left.element.id] ?? Int.max
            let rightRank = ranks[right.element.id] ?? Int.max
            return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
        }.map(\.element)
        if playlists != homePlaylists { homePlaylists = playlists }
    }

    /// Playlist tracks in the playlist's own order - the order is the
    /// playlist, so edits and playback both follow it.
    func tracks(in playlist: CodecPlaylist) -> [CodecTrack] {
        playlist.trackIDs.compactMap { tracksByID[$0] }
    }

    /// Cover previews need only a handful of tracks, not a new copy of an
    /// entire playlist every time a row appears or its artwork updates.
    func firstTracks(in playlist: CodecPlaylist, limit: Int) -> [CodecTrack] {
        guard limit > 0 else { return [] }
        var result: [CodecTrack] = []
        result.reserveCapacity(min(limit, playlist.trackIDs.count))
        for id in playlist.trackIDs {
            guard let track = tracksByID[id] else { continue }
            result.append(track)
            if result.count == limit { break }
        }
        return result
    }

    func track(withID id: String) -> CodecTrack? { tracksByID[id] }

    func playlist(withID id: String) -> CodecPlaylist? {
        library?.playlists.first { $0.id == id }
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
        let url = cacheURL
        cacheQueue.async {
            guard let data = try? JSONEncoder().encode(library) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func deleteCachedLibrary() {
        let url = cacheURL
        cacheQueue.async { try? FileManager.default.removeItem(at: url) }
    }
}
