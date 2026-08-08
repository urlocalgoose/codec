import Foundation
import Observation
import UIKit

/// Shared artwork fetcher with an in-memory cache. Plain AsyncImage cannot
/// send the Authorization header, so all artwork goes through here.
actor ArtworkLoader {
    static let shared = ArtworkLoader()

    private let cache = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    func image(for url: URL, headers: [String: String]) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }

        if let task = inFlight[url] {
            return await task.value
        }

        let task = Task<UIImage?, Never> {
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
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            cache.setObject(image, forKey: url as NSURL)
        }
        return image
    }
}

/// Offline audio: downloads MP3s into Application Support and hands the
/// player local file URLs when they exist.
@MainActor
@Observable
final class DownloadStore {
    enum State: Equatable {
        case downloading
        case downloaded
    }

    private(set) var states: [String: State] = [:]

    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Loud", directoryHint: .isDirectory)
            .appending(path: "audio", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        directory = base
        loadExisting()
    }

    func state(for track: LoudTrack) -> State? {
        states[track.fingerprint]
    }

    func isDownloaded(_ track: LoudTrack) -> Bool {
        states[track.fingerprint] == .downloaded
    }

    var downloadedCount: Int {
        states.values.filter { $0 == .downloaded }.count
    }

    func downloadedTracks(in library: [LoudTrack]) -> [LoudTrack] {
        library.filter { states[$0.fingerprint] == .downloaded }
    }

    func localAudioURL(for track: LoudTrack) -> URL? {
        guard states[track.fingerprint] == .downloaded else {
            return nil
        }
        return fileURL(for: track.fingerprint)
    }

    func download(_ track: LoudTrack, using client: LoudClient) {
        guard states[track.fingerprint] == nil, let url = client.audioURL(for: track) else {
            return
        }

        states[track.fingerprint] = .downloading
        let destination = fileURL(for: track.fingerprint)
        let headers = client.authHeaders
        let fingerprint = track.fingerprint

        Task {
            var request = URLRequest(url: url)
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }

            do {
                let (temporary, response) = try await URLSession.shared.download(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    try? FileManager.default.removeItem(at: temporary)
                    states[fingerprint] = nil
                    return
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                states[fingerprint] = .downloaded
            } catch {
                states[fingerprint] = nil
            }
        }
    }

    func downloadAll(_ tracks: [LoudTrack], using client: LoudClient) {
        for track in tracks where states[track.fingerprint] == nil {
            download(track, using: client)
        }
    }

    func remove(_ track: LoudTrack) {
        try? FileManager.default.removeItem(at: fileURL(for: track.fingerprint))
        states[track.fingerprint] = nil
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
