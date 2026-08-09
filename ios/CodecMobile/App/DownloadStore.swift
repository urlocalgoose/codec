import CryptoKit
import Foundation
import Observation
import UIKit

/// Shared artwork fetcher with a two-tier cache: a thread-safe in-memory
/// NSCache for instant paints, and a disk layer under Caches so covers
/// survive relaunches and show offline.
actor ArtworkLoader {
    static let shared = ArtworkLoader()

    // NSCache is documented thread-safe; nonisolated(unsafe) declares that
    // guarantee so views can peek synchronously.
    nonisolated(unsafe) private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    private static let diskDirectory: URL = {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "artwork", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    nonisolated static func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL, headers: [String: String]) async -> UIImage? {
        if let cached = Self.cache.object(forKey: url as NSURL) {
            return cached
        }

        if let task = inFlight[url] {
            return await task.value
        }

        let task = Task<UIImage?, Never> {
            let diskPath = Self.diskPath(for: url)
            if let data = try? Data(contentsOf: diskPath), let image = UIImage(data: data) {
                return image
            }

            var request = URLRequest(url: url)
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let image = UIImage(data: data)
            else {
                return nil
            }
            try? data.write(to: diskPath, options: .atomic)
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            Self.cache.setObject(image, forKey: url as NSURL, cost: cost)
        }
        return image
    }

    /// Trims the disk layer to a sane size, oldest first. Called once at
    /// startup from the app.
    func pruneDiskCache(keeping limit: Int = 1500) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.diskDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        guard files.count > limit else {
            return
        }
        let sorted = files.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l < r
        }
        for file in sorted.prefix(files.count - limit) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private nonisolated static func diskPath(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined().prefix(40)
        return diskDirectory.appending(path: "\(name).jpg")
    }
}

/// Offline audio downloads on a background URLSession: transfers keep
/// running when the app is backgrounded or killed, and reattach when the
/// app returns.
@MainActor
@Observable
final class DownloadStore {
    static let shared = DownloadStore()

    enum State: Equatable {
        case downloading(Double)
        case downloaded
    }

    private(set) var states: [String: State] = [:]

    private let directory: URL
    private let coordinator: DownloadCoordinator
    private var session: URLSession!

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Loud", directoryHint: .isDirectory)
            .appending(path: "audio", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        directory = base
        coordinator = DownloadCoordinator(destinationDirectory: base)

        let configuration = URLSessionConfiguration.background(withIdentifier: "sh.codie.codec.downloads")
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        session = URLSession(configuration: configuration, delegate: coordinator, delegateQueue: nil)

        coordinator.store = self
        loadExisting()
        reattachRunningDownloads()
    }

    func state(for track: CodecTrack) -> State? {
        states[track.fingerprint]
    }

    func isDownloaded(_ track: CodecTrack) -> Bool {
        states[track.fingerprint] == .downloaded
    }

    var downloadedCount: Int {
        states.values.filter { $0 == .downloaded }.count
    }

    func downloadedTracks(in library: [CodecTrack]) -> [CodecTrack] {
        library.filter { states[$0.fingerprint] == .downloaded }
    }

    func localAudioURL(for track: CodecTrack) -> URL? {
        guard states[track.fingerprint] == .downloaded else {
            return nil
        }
        return fileURL(for: track.fingerprint)
    }

    func download(_ track: CodecTrack, using client: CodecClient) {
        guard states[track.fingerprint] == nil, let url = client.audioURL(for: track) else {
            return
        }
        start(fingerprint: track.fingerprint, url: url, headers: client.authHeaders)
    }

    /// The background session paces transfers itself; states are seeded up
    /// front so the UI reflects the whole batch immediately.
    func downloadAll(_ tracks: [CodecTrack], using client: CodecClient) {
        for track in tracks where states[track.fingerprint] == nil {
            guard let url = client.audioURL(for: track) else {
                continue
            }
            start(fingerprint: track.fingerprint, url: url, headers: client.authHeaders)
        }
    }

    func remove(_ track: CodecTrack) {
        try? FileManager.default.removeItem(at: fileURL(for: track.fingerprint))
        states[track.fingerprint] = nil
    }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        coordinator.backgroundCompletionHandler = handler
    }

    // MARK: - Coordinator callbacks (main actor)

    func downloadProgressed(fingerprint: String, progress: Double) {
        if case .downloaded = states[fingerprint] {
            return
        }
        states[fingerprint] = .downloading(progress)
    }

    func downloadFinished(fingerprint: String, success: Bool) {
        states[fingerprint] = success ? .downloaded : nil
    }

    // MARK: - Internals

    private func start(fingerprint: String, url: URL, headers: [String: String]) {
        states[fingerprint] = .downloading(0)
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let task = session.downloadTask(with: request)
        // The fingerprint rides on the task so transfers survive relaunches.
        task.taskDescription = fingerprint
        task.resume()
    }

    private func reattachRunningDownloads() {
        session.getAllTasks { tasks in
            let fingerprints = tasks.compactMap(\.taskDescription)
            Task { @MainActor [weak self] in
                for fingerprint in fingerprints where self?.states[fingerprint] == nil {
                    self?.states[fingerprint] = .downloading(0)
                }
            }
        }
    }

    private func fileURL(for fingerprint: String) -> URL {
        let safe = fingerprint.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "track"
        return directory.appending(path: "\(safe).mp3")
    }

    private func loadExisting() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.pathExtension == "mp3" {
            let name = file.deletingPathExtension().lastPathComponent
            if let fingerprint = name.removingPercentEncoding {
                states[fingerprint] = .downloaded
            }
        }
    }
}

/// Nonisolated URLSession delegate: moves finished files on the session
/// queue (the temp file is only valid inside the callback) and forwards
/// state to the store on the main actor.
final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var store: DownloadStore?
    /// Set by the app delegate when iOS relaunches us for background events.
    var backgroundCompletionHandler: (() -> Void)?

    private let destinationDirectory: URL

    init(destinationDirectory: URL) {
        self.destinationDirectory = destinationDirectory
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let fingerprint = downloadTask.taskDescription else {
            return
        }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        var success = (200..<300).contains(status)
        if success {
            let safe = fingerprint.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "track"
            let destination = destinationDirectory.appending(path: "\(safe).mp3")
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                success = false
            }
        }
        let finished = success
        Task { @MainActor [weak store] in
            store?.downloadFinished(fingerprint: fingerprint, success: finished)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let fingerprint = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else {
            return
        }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor [weak store] in
            store?.downloadProgressed(fingerprint: fingerprint, progress: progress)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil, let fingerprint = task.taskDescription else {
            return
        }
        Task { @MainActor [weak store] in
            store?.downloadFinished(fingerprint: fingerprint, success: false)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        Task { @MainActor in
            handler?()
        }
    }
}
