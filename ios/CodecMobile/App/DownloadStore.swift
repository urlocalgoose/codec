import CryptoKit
import Foundation
import ImageIO
import Observation
import UIKit

/// Original bytes stay on disk; display-ready bitmaps are cached at the actual
/// screen pixel size. Storage and decoding run on this actor, never on the UI.
actor ArtworkLoader {
    static let shared = ArtworkLoader()

    nonisolated(unsafe) private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()

    private var originalFlights: [ArtworkRequest: Task<Data?, Never>] = [:]
    private var imageFlights: [ArtworkRequest: Task<UIImage?, Never>] = [:]
    private let diskDirectory: URL
    private let pinnedDirectory: URL
    private let decode: @Sendable (Data, Int?) -> UIImage?
    private var storagePrepared = false
    private var pinnedTracks: [String: String] = [:]
    private var pinRequests: [String: UUID] = [:]

    init(
        cacheDirectory: URL? = nil,
        pinnedDirectory: URL? = nil,
        decode: @escaping @Sendable (Data, Int?) -> UIImage? = { ArtworkLoader.prepareImage($0, pixelSize: $1) }
    ) {
        diskDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "artwork", directoryHint: .isDirectory)
        self.pinnedDirectory = pinnedDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Codec/artwork", directoryHint: .isDirectory)
        self.decode = decode
        // Actor initialization can happen on the main thread. Defer all file
        // reads, directory creation, and backup attributes until actor entry.
    }

    private func prepareStorage() {
        guard !storagePrepared else { return }
        storagePrepared = true
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: pinnedDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: pinnedDirectory.appendingPathComponent(".tracks.json")),
           let tracks = try? JSONDecoder().decode([String: String].self, from: data) {
            pinnedTracks = tracks
        }
        var directory = pinnedDirectory
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try? directory.setResourceValues(attributes)
    }

    nonisolated private static func request(for url: URL, headers: [String: String], pixelSize: Int? = nil) -> ArtworkRequest {
        ArtworkRequest(
            url: url,
            authorization: headers.first { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }?.value,
            pixelSize: pixelSize.map { max(1, $0) }
        )
    }

    /// Thread-safe lookup only: no disk access or image decoding during a row's body.
    nonisolated static func cachedImage(for url: URL, headers: [String: String] = [:], pixelSize: Int? = nil) -> UIImage? {
        cache.object(forKey: request(for: url, headers: headers, pixelSize: pixelSize).cacheKey as NSString)
    }

    func image(for url: URL, headers: [String: String], pixelSize: Int? = nil) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let requested = Self.request(for: url, headers: headers, pixelSize: pixelSize)
        if let cached = Self.cache.object(forKey: requested.cacheKey as NSString) { return cached }
        if let task = imageFlights[requested] { return await task.value }

        let task = Task<UIImage?, Never> {
            guard let data = await originalData(for: requested.original, headers: headers) else { return nil }
            // This task inherits ArtworkLoader isolation, not the caller's UI
            // actor. ImageIO performs decompression before SwiftUI sees it.
            return decode(data, requested.pixelSize)
        }
        imageFlights[requested] = task
        let image = await task.value
        imageFlights[requested] = nil
        if let image {
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            Self.cache.setObject(image, forKey: requested.cacheKey as NSString, cost: cost)
        }
        return image
    }

    private func originalData(for requested: ArtworkRequest, headers: [String: String]) async -> Data? {
        prepareStorage()
        if let task = originalFlights[requested] { return await task.value }
        let task = Task<Data?, Never> { await loadOriginal(for: requested, headers: headers) }
        originalFlights[requested] = task
        let data = await task.value
        originalFlights[requested] = nil
        return data
    }

    private func loadOriginal(for requested: ArtworkRequest, headers: [String: String]) async -> Data? {
        let name = Self.fileName(for: requested)
        let pinned = pinnedDirectory.appendingPathComponent(name)
        let disk = diskDirectory.appendingPathComponent(name)
        for path in [pinned, disk] {
            if let data = try? Data(contentsOf: path), Self.isImage(data) { return data }
        }

        // Old pinned covers predate auth-scoped names. Bind a known offline pin
        // to its first authenticated request once, renaming to a scoped digest.
        // Other credentials can no longer reuse it, including after relaunch.
        let legacyName = Self.fileName(for: ArtworkRequest(url: requested.url, authorization: nil))
        if requested.authorization != nil, legacyName != name, pinnedTracks.values.contains(legacyName) {
            let legacy = pinnedDirectory.appendingPathComponent(legacyName)
            if let data = try? Data(contentsOf: legacy), Self.isImage(data) {
                do {
                    try FileManager.default.moveItem(at: legacy, to: pinned)
                    for fingerprint in Array(pinnedTracks.keys) where pinnedTracks[fingerprint] == legacyName {
                        pinnedTracks[fingerprint] = name
                    }
                    savePins()
                    return data
                } catch { /* Preserve the original pin if migration cannot finish. */ }
            }
        }

        var request = URLRequest(url: requested.url)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              Self.isImage(data) else { return nil }
        try? data.write(to: disk, options: .atomic)
        return data
    }

    nonisolated private static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return false }
        return CGImageSourceGetCount(source) > 0 && CGImageSourceGetStatus(source) == .statusComplete
    }

    /// Produce enough pixels for a square scaledToFill view at its display scale.
    /// Wide/tall originals use their SHORT edge when sizing, avoiding soft crops.
    /// A nil target retains the original resolution for fullscreen/lock-screen art.
    nonisolated static func prepareImage(_ data: Data, pixelSize: Int?) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        let longest = max(width.intValue, height.intValue)
        let shortest = min(width.intValue, height.intValue)
        guard shortest > 0 else { return nil }
        let target = pixelSize.map { min(longest, Int(ceil(Double(max(1, $0)) * Double(longest) / Double(shortest)))) } ?? longest
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: target
        ]
        guard let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: bitmap)
    }

    /// Pin original bytes without decoding a full-size bitmap just for storage.
    func pinImage(for url: URL, headers: [String: String], fingerprint: String) async {
        prepareStorage()
        let requestID = UUID()
        pinRequests[fingerprint] = requestID
        defer { if pinRequests[fingerprint] == requestID { pinRequests[fingerprint] = nil } }
        let requested = Self.request(for: url, headers: headers)
        let name = Self.fileName(for: requested)
        let pinned = pinnedDirectory.appendingPathComponent(name)
        guard let data = await originalData(for: requested, headers: headers),
              pinRequests[fingerprint] == requestID, !Task.isCancelled else { return }
        do {
            if !FileManager.default.fileExists(atPath: pinned.path) {
                try data.write(to: pinned, options: .atomic)
            }
        } catch { return }
        pinnedTracks[fingerprint] = name
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: pinned.path)
        savePins()
    }

    func unpinImage(fingerprint: String) {
        prepareStorage()
        pinRequests[fingerprint] = nil
        guard let name = pinnedTracks.removeValue(forKey: fingerprint) else { return }
        if !pinnedTracks.values.contains(name) {
            try? FileManager.default.removeItem(at: pinnedDirectory.appendingPathComponent(name))
        }
        savePins()
    }

    func hasPinnedImage(fingerprint: String) -> Bool {
        prepareStorage()
        guard let name = pinnedTracks[fingerprint] else { return false }
        return FileManager.default.fileExists(atPath: pinnedDirectory.appendingPathComponent(name).path)
    }

    private func savePins() {
        if let data = try? JSONEncoder().encode(pinnedTracks) {
            try? data.write(to: pinnedDirectory.appendingPathComponent(".tracks.json"), options: .atomic)
        }
    }

    func pruneDiskCache(keeping limit: Int = 1500) {
        prepareStorage()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: diskDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        guard files.count > limit else { return }
        // Fetch each date once, rather than perform filesystem lookups in the
        // sort comparator for every pair of entries.
        let dated = files.map { file in
            (file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 < $1.1 }
        for (file, _) in dated.prefix(files.count - max(0, limit)) { try? FileManager.default.removeItem(at: file) }
    }

    private nonisolated static func fileName(for requested: ArtworkRequest) -> String {
        let identity = requested.url.absoluteString + (requested.authorization.map { "\nAuthorization: " + $0 } ?? "")
        let digest = SHA256.hash(data: Data(identity.utf8))
        return "\(digest.map { String(format: "%02x", $0) }.joined().prefix(40)).jpg"
    }
}

/// Offline audio downloads on a background URLSession. The disk file, rather
/// than a progress flag, is authoritative when playback asks for local audio.
@MainActor
@Observable
final class DownloadStore {
    static let shared = DownloadStore()

    enum State: Equatable {
        case downloading(Double)
        case downloaded
    }

    @ObservationIgnored private(set) var states: [String: State] = [:]
    @ObservationIgnored private var trackObservations: [String: TrackObservation] = [:]
    private var downloadedFingerprints: Set<String> = []

    @MainActor @Observable
    fileprivate final class TrackObservation {
        var value: State?
        var downloaded = false
        var downloading = false
    }

    private func observation(for fingerprint: String) -> TrackObservation {
        if let existing = trackObservations[fingerprint] { return existing }
        let observation = TrackObservation()
        trackObservations[fingerprint] = observation
        return observation
    }

    private func setState(_ state: State?, for fingerprint: String) {
        guard states[fingerprint] != state else { return }
        states[fingerprint] = state
        let observation = observation(for: fingerprint)
        observation.value = state
        let downloaded = state == .downloaded
        let downloading: Bool
        if case .downloading = state { downloading = true } else { downloading = false }
        if observation.downloaded != downloaded {
            observation.downloaded = downloaded
            if downloaded { downloadedFingerprints.insert(fingerprint) }
            else { downloadedFingerprints.remove(fingerprint) }
        }
        if observation.downloading != downloading {
            observation.downloading = downloading
        }
    }
    private(set) var failures: [String: String] = [:]
    private var localFiles: [String: URL] = [:]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "flac", "wav"]

    private struct Transfer {
        var request: URLRequest
        var task: URLSessionDownloadTask?
        var resumeData: Data?
        var attempts = 0
    }

    private let directory: URL
    private let coordinator: DownloadCoordinator
    private var session: URLSession!
    private var transfers: [String: Transfer] = [:]
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var artworkTasks: [String: Task<Void, Never>] = [:]
    private var pendingArtwork: [String: (url: URL, headers: [String: String])] = [:]
    private var preparedArtwork: Set<String> = []
    private var attemptedArtwork: Set<String> = []
    private var restoringTasks = true
    private var removedWhileRestoring: Set<String> = []
    private var networkAvailable = true
    private var backgroundCompletionHandler: (() -> Void)?

    /// Supplying a directory and a foreground session keeps file/network
    /// regression tests independent of the user's background download queue.
    init(directory: URL? = nil, configuration: URLSessionConfiguration? = nil) {
        let base: URL
        if let directory {
            base = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let legacyBase = support.appending(path: "Loud", directoryHint: .isDirectory)
            let codecBase = support.appending(path: "Codec", directoryHint: .isDirectory)
            if !FileManager.default.fileExists(atPath: codecBase.path()),
               FileManager.default.fileExists(atPath: legacyBase.path()) {
                try? FileManager.default.moveItem(at: legacyBase, to: codecBase)
            }
            base = codecBase.appending(path: "audio", directoryHint: .isDirectory)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        Self.prepareOfflineFile(base)
        self.directory = base
        coordinator = DownloadCoordinator(destinationDirectory: base)
        let config = configuration ?? URLSessionConfiguration.background(withIdentifier: "sh.codie.codec.downloads")
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        if config.identifier != nil { config.sessionSendsLaunchEvents = true }
        session = URLSession(configuration: config, delegate: coordinator, delegateQueue: nil)
        coordinator.store = self
        loadExisting()
        reattachRunningDownloads()
    }

    func state(for track: CodecTrack) -> State? { observation(for: track.fingerprint).value }
    func isDownloaded(_ track: CodecTrack) -> Bool { observation(for: track.fingerprint).downloaded }
    func isDownloading(_ track: CodecTrack) -> Bool { observation(for: track.fingerprint).downloading }
    var downloadedCount: Int { downloadedFingerprints.count }
    func downloadedTracks(in library: [CodecTrack]) -> [CodecTrack] {
        let fingerprints = downloadedFingerprints
        return library.filter { fingerprints.contains($0.fingerprint) }
    }

    func localAudioURL(for track: CodecTrack) -> URL? {
        guard let file = localFiles[track.fingerprint] else { return nil }
        guard Self.isUsableAudioFile(file) else {
            localFiles[track.fingerprint] = nil
            if states[track.fingerprint] == .downloaded { setState(nil, for: track.fingerprint) }
            return nil
        }
        return file
    }

    func download(_ track: CodecTrack, using client: CodecClient) {
        guard localAudioURL(for: track) == nil, transfers[track.fingerprint] == nil,
              let url = client.audioURL(for: track) else { return }
        var request = URLRequest(url: url)
        for (name, value) in client.authHeaders(for: url) { request.setValue(value, forHTTPHeaderField: name) }
        failures[track.fingerprint] = nil
        setState(.downloading(0), for: track.fingerprint)
        transfers[track.fingerprint] = Transfer(request: request)
        prepareArtwork(for: [track], using: client)
        if !restoringTasks { start(fingerprint: track.fingerprint) }
    }

    func downloadAll(_ tracks: [CodecTrack], using client: CodecClient) {
        for track in tracks { download(track, using: client) }
    }

    func remove(_ track: CodecTrack) {
        let fingerprint = track.fingerprint
        if restoringTasks { removedWhileRestoring.insert(fingerprint) }
        retryTasks.removeValue(forKey: fingerprint)?.cancel()
        artworkTasks.removeValue(forKey: fingerprint)?.cancel()
        pendingArtwork[fingerprint] = nil
        preparedArtwork.remove(fingerprint)
        attemptedArtwork.remove(fingerprint)
        Task { await ArtworkLoader.shared.unpinImage(fingerprint: fingerprint) }
        transfers.removeValue(forKey: fingerprint)?.task?.cancel()
        if let file = localFiles.removeValue(forKey: fingerprint) { try? FileManager.default.removeItem(at: file) }
        setState(nil, for: fingerprint)
        failures[fingerprint] = nil
    }

    /// No polling/retry storm in airplane mode. Background URLSession keeps
    /// its in-flight tasks and waits for a route; deferred failures resume
    /// promptly when connectivity or the server returns.
    func setNetworkAvailable(_ available: Bool) {
        guard available != networkAvailable else { return }
        networkAvailable = available
        if available {
            retryPendingDownloads()
        } else {
            retryTasks.values.forEach { $0.cancel() }
            retryTasks.removeAll()
        }
    }

    func retryPendingDownloads() {
        guard networkAvailable, !restoringTasks else { return }
        for fingerprint in Array(transfers.keys) where transfers[fingerprint]?.task == nil {
            retryTasks.removeValue(forKey: fingerprint)?.cancel()
            start(fingerprint: fingerprint)
        }
        attemptedArtwork.removeAll()
        startPendingArtwork()
    }

    /// Also called with cached library metadata after launch, so songs
    /// downloaded by an older version gain durable covers when reachable.
    func prepareArtwork(for tracks: [CodecTrack], using client: CodecClient) {
        for track in tracks where states[track.fingerprint] != nil && !preparedArtwork.contains(track.fingerprint) {
            guard let url = track.artworkURL else { continue }
            pendingArtwork[track.fingerprint] = (url, client.authHeaders(for: url))
        }
        startPendingArtwork()
    }

    private func startPendingArtwork() {
        guard networkAvailable else { return }
        // A bulk download should not flood the server with cover requests.
        for (fingerprint, request) in pendingArtwork where artworkTasks[fingerprint] == nil && !attemptedArtwork.contains(fingerprint) {
            guard artworkTasks.count < 4 else { break }
            attemptedArtwork.insert(fingerprint)
            artworkTasks[fingerprint] = Task { [weak self] in
                await ArtworkLoader.shared.pinImage(for: request.url, headers: request.headers, fingerprint: fingerprint)
                let pinned = await ArtworkLoader.shared.hasPinnedImage(fingerprint: fingerprint)
                guard !Task.isCancelled, let self else { return }
                self.artworkTasks[fingerprint] = nil
                if pinned {
                    self.pendingArtwork[fingerprint] = nil
                    self.preparedArtwork.insert(fingerprint)
                }
                self.startPendingArtwork()
                // Failed covers retry with server/path recovery, without
                // delaying playable audio or creating a tight retry loop.
            }
        }
    }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        backgroundCompletionHandler = handler
    }

    func backgroundEventsFinished() {
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        handler?()
    }

    /// Explicit lifecycle for isolated test stores; the shared app store
    /// remains alive so iOS can deliver background completion events.
    func shutdown() {
        retryTasks.values.forEach { $0.cancel() }
        retryTasks.removeAll()
        artworkTasks.values.forEach { $0.cancel() }
        artworkTasks.removeAll()
        pendingArtwork.removeAll()
        transfers.removeAll()
        restoringTasks = false
        session.invalidateAndCancel()
    }

    // MARK: - Session callbacks

    private func accepts(_ fingerprint: String, task: URLSessionDownloadTask) -> Bool {
        if let current = transfers[fingerprint]?.task { return current.taskIdentifier == task.taskIdentifier }
        // Events from a relaunched background transfer may precede getAllTasks.
        guard restoringTasks, !removedWhileRestoring.contains(fingerprint),
              let request = task.originalRequest else { return false }
        transfers[fingerprint] = Transfer(request: request, task: task)
        return true
    }

    func downloadProgressed(fingerprint: String, task: URLSessionDownloadTask, progress: Double) {
        guard accepts(fingerprint, task: task), states[fingerprint] != .downloaded else { return }
        setState(.downloading(min(1, max(0, progress))), for: fingerprint)
    }

    func downloadReceived(fingerprint: String, task: URLSessionDownloadTask, location: URL?, error: String?, retryable: Bool) {
        guard accepts(fingerprint, task: task) else {
            if let location { try? FileManager.default.removeItem(at: location) }
            return
        }
        guard let location else {
            downloadFailed(fingerprint: fingerprint, task: task, message: error ?? "Download failed.", retryable: retryable)
            return
        }
        defer { try? FileManager.default.removeItem(at: location) }
        let safe = fingerprint.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "track"
        let target = directory.appendingPathComponent("\(safe).\(location.pathExtension)")
        do {
            // Stale callbacks never replace another transfer's completed file.
            if !Self.isUsableAudioFile(target) {
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: location, to: target)
            }
            Self.prepareOfflineFile(target)
            localFiles[fingerprint] = target
            setState(.downloaded, for: fingerprint)
            failures[fingerprint] = nil
            transfers[fingerprint] = nil
            retryTasks.removeValue(forKey: fingerprint)?.cancel()
        } catch {
            downloadFailed(fingerprint: fingerprint, task: task, message: "Couldn’t save the download. Check available storage.", retryable: false)
        }
    }

    func downloadFailed(fingerprint: String, task: URLSessionDownloadTask, message: String, retryable: Bool, resumeData: Data? = nil) {
        guard accepts(fingerprint, task: task) else { return }
        failures[fingerprint] = message
        guard retryable else {
            transfers[fingerprint] = nil
            setState(nil, for: fingerprint)
            return
        }
        transfers[fingerprint]?.task = nil
        transfers[fingerprint]?.resumeData = resumeData
        transfers[fingerprint]?.attempts += 1
        scheduleRetry(fingerprint)
    }

    private func scheduleRetry(_ fingerprint: String) {
        guard networkAvailable, let transfer = transfers[fingerprint] else { return }
        retryTasks[fingerprint]?.cancel()
        let delay = min(60, 2 << min(transfer.attempts, 5))
        retryTasks[fingerprint] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.networkAvailable, !Task.isCancelled else { return }
            self.retryTasks[fingerprint] = nil
            self.start(fingerprint: fingerprint)
        }
    }

    private func start(fingerprint: String) {
        guard networkAvailable, let transfer = transfers[fingerprint], transfer.task == nil else { return }
        let task: URLSessionDownloadTask
        if let resumeData = transfer.resumeData { task = session.downloadTask(withResumeData: resumeData) }
        else { task = session.downloadTask(with: transfer.request) }
        transfers[fingerprint]?.resumeData = nil
        transfers[fingerprint]?.task = task
        task.taskDescription = fingerprint
        task.resume()
    }

    private func reattachRunningDownloads() {
        session.getAllTasks { [weak self] tasks in
            Task { @MainActor [weak self] in
                guard let self, self.restoringTasks else { return }
                for case let task as URLSessionDownloadTask in tasks {
                    guard let fingerprint = task.taskDescription, let request = task.originalRequest,
                          task.state != .completed, task.state != .canceling else { continue }
                    if self.removedWhileRestoring.contains(fingerprint) || self.states[fingerprint] == .downloaded {
                        task.cancel()
                    } else if let current = self.transfers[fingerprint]?.task, current.taskIdentifier != task.taskIdentifier {
                        task.cancel()
                    } else {
                        self.transfers[fingerprint] = Transfer(request: request, task: task)
                        self.setState(.downloading(0), for: fingerprint)
                    }
                }
                self.restoringTasks = false
                self.removedWhileRestoring.removeAll()
                self.retryPendingDownloads()
            }
        }
    }

    private func loadExisting() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where Self.audioExtensions.contains(file.pathExtension.lowercased()) {
            // Pending files are private handoff files, never playable downloads.
            guard !file.lastPathComponent.hasPrefix("."), Self.isUsableAudioFile(file),
                  let fingerprint = file.deletingPathExtension().lastPathComponent.removingPercentEncoding else { continue }
            Self.prepareOfflineFile(file)
            setState(.downloaded, for: fingerprint)
            localFiles[fingerprint] = file
        }
    }

    nonisolated static func isUsableAudioFile(_ url: URL) -> Bool {
        // FileManager performs a fresh stat; URL resource caches can retain
        // the old length after a file has been removed or truncated.
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              values[.type] as? FileAttributeType == .typeRegular,
              (values[.size] as? NSNumber)?.int64Value ?? 0 > 0 else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    nonisolated private static func prepareOfflineFile(_ url: URL) {
        // Downloaded songs are replaceable, potentially large, and must remain
        // readable while the screen is locked after the first device unlock.
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }
}

/// The session delegate must move temporary files before returning. Stage
/// each completion separately; only the main-actor store can promote the
/// currently accepted transfer into the user's offline collection.
final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var store: DownloadStore?
    private let destinationDirectory: URL
    private let pendingCallbacks = DispatchGroup()
    init(destinationDirectory: URL) { self.destinationDirectory = destinationDirectory }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let fingerprint = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let mime = downloadTask.response?.mimeType?.lowercased()
        let validContentType = mime == nil || mime?.hasPrefix("audio/") == true || mime == "application/octet-stream"
        var destination: URL?
        var failureMessage: String?
        if (200..<300).contains(status), validContentType, DownloadStore.isUsableAudioFile(location) {
            let target = destinationDirectory.appendingPathComponent(".pending-\(UUID().uuidString).\(Self.fileExtension(forMIMEType: mime))")
            do {
                try FileManager.default.moveItem(at: location, to: target)
                destination = target
            } catch { failureMessage = "Couldn’t save the download. Check available storage." }
        } else if status == 401 || status == 403 {
            failureMessage = "Check the server’s auth token and try the download again."
        } else if status >= 500 || status == 408 || status == 429 {
            failureMessage = "The server is unavailable. The download will retry."
        } else {
            failureMessage = "The server didn’t return a usable audio file."
        }
        let finalURL = destination
        let message = failureMessage
        let callbacks = pendingCallbacks
        callbacks.enter()
        Task { @MainActor [weak store] in
            defer { callbacks.leave() }
            store?.downloadReceived(fingerprint: fingerprint, task: downloadTask, location: finalURL, error: message,
                                    retryable: status >= 500 || status == 408 || status == 429)
            if store == nil, let finalURL { try? FileManager.default.removeItem(at: finalURL) }
        }
    }

    private static func fileExtension(forMIMEType mimeType: String?) -> String {
        switch mimeType {
        case "audio/mp4", "audio/x-m4a", "audio/aac": "m4a"
        case "audio/flac", "audio/x-flac": "flac"
        case "audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave": "wav"
        default: "mp3"
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let fingerprint = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let callbacks = pendingCallbacks
        callbacks.enter()
        Task { @MainActor [weak store] in
            defer { callbacks.leave() }
            store?.downloadProgressed(fingerprint: fingerprint, task: downloadTask, progress: progress)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error as NSError?, let task = task as? URLSessionDownloadTask,
              let fingerprint = task.taskDescription else { return }
        let retryable = error.domain == NSURLErrorDomain && [
            NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
            NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed,
            NSURLErrorBackgroundSessionWasDisconnected, NSURLErrorBackgroundSessionInUseByAnotherProcess
        ].contains(error.code)
        let resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let callbacks = pendingCallbacks
        callbacks.enter()
        Task { @MainActor [weak store] in
            defer { callbacks.leave() }
            store?.downloadFailed(fingerprint: fingerprint, task: task, message: error.localizedDescription,
                                  retryable: retryable, resumeData: resumeData)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Telling iOS we're finished may suspend the app immediately. Wait
        // for every staged file/state callback to commit before doing so.
        let completionStore = store
        pendingCallbacks.notify(queue: .main) {
            Task { @MainActor in completionStore?.backgroundEventsFinished() }
        }
    }
}
