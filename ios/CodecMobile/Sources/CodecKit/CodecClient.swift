import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol CodecTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: CodecTransport {}

/// Client for the Codec sync server (`loud-sync-server`).
///
/// Speaks the plain v1 API with optional shared-token auth: when the server
/// is started with `LOUD_AUTH_TOKEN`, every request carries
/// `Authorization: Bearer <token>`.
/// Shared media route: when the phone can reach the server directly on the
/// LAN, media streams skip the tunnel. Probed by the app, consulted by every
/// media URL builder; nil means "use the configured base URL".
public final class MediaRoute: @unchecked Sendable {
    public static let shared = MediaRoute()

    private let lock = NSLock()
    private var url: URL?

    public var fastBaseURL: URL? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return url
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            url = newValue
        }
    }
}

public struct CodecClient: Sendable {
    public let baseURL: URL
    public let token: String?
    private let transport: CodecTransport
    private let decoder = JSONDecoder()

    public init(baseURL: URL, token: String? = nil, transport: CodecTransport = URLSession.shared) {
        self.baseURL = baseURL
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.transport = transport
    }

    /// Headers that authenticated media loaders (AVPlayer, artwork fetches)
    /// must attach to requests against this server.
    public var authHeaders: [String: String] {
        guard let token else {
            return [:]
        }
        return ["Authorization": "Bearer \(token)"]
    }

    public func health() async throws -> CodecHealth {
        try await send(request(method: "GET", path: "/health"), as: CodecHealth.self)
    }

    public func library() async throws -> CodecLibrary {
        try await send(request(method: "GET", path: "/api/v1/library"), as: CodecLibrary.self)
    }

    /// Canonical audio URL for a track, used for both streaming and downloads.
    /// When a LAN fast path is active it wins; otherwise the URL the server
    /// embedded in the library payload, then one built from the fingerprint.
    public func audioURL(for track: CodecTrack) -> URL? {
        if MediaRoute.shared.fastBaseURL != nil {
            return mediaURL(fingerprint: track.fingerprint, kind: "audio")
        }
        return track.audioURL ?? mediaURL(fingerprint: track.fingerprint, kind: "audio")
    }

    public func artworkURL(for track: CodecTrack) -> URL? {
        if MediaRoute.shared.fastBaseURL != nil {
            return mediaURL(fingerprint: track.fingerprint, kind: "artwork")
        }
        return track.artworkURL ?? mediaURL(fingerprint: track.fingerprint, kind: "artwork")
    }

    public func mediaURL(fingerprint: String, kind: String) -> URL? {
        guard let encoded = fingerprint.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            return nil
        }
        let base = MediaRoute.shared.fastBaseURL ?? baseURL
        var basePath = base.path
        if basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.percentEncodedPath = basePath + "/api/v1/tracks/\(encoded)/\(kind)"
        return components.url
    }

    /// Probes the server-advertised LAN URLs and activates the first one that
    /// answers /health with the same server identity.
    public func probeFastPath(serverID: String?, lanURLs: [String]?) async {
        guard let serverID, let lanURLs, !lanURLs.isEmpty else {
            MediaRoute.shared.fastBaseURL = nil
            return
        }
        // Already talking to a direct URL? Nothing to gain.
        if let host = baseURL.host, lanURLs.contains(where: { URL(string: $0)?.host == host }) {
            MediaRoute.shared.fastBaseURL = nil
            return
        }
        for candidate in lanURLs {
            guard let url = URL(string: candidate) else {
                continue
            }
            var request = URLRequest(url: url.appending(path: "health"))
            request.timeoutInterval = 2
            for (name, value) in authHeaders {
                request.setValue(value, forHTTPHeaderField: name)
            }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let health = try? JSONDecoder().decode(CodecHealth.self, from: data),
                  health.serverID == serverID
            else {
                continue
            }
            MediaRoute.shared.fastBaseURL = url
            return
        }
        MediaRoute.shared.fastBaseURL = nil
    }

    // MARK: - Likes

    public func setLiked(fingerprint: String, liked: Bool) async throws {
        guard let encoded = fingerprint.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw CodecClientError.invalidBaseURL
        }
        var request = URLRequest(url: try endpointURL(path: "/api/v1/tracks/\(encoded)/liked", encodedPath: true))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["liked": liked])
        for (name, value) in authHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        _ = try await sendExpectingSuccess(request)
    }

    // MARK: - Playlists

    public func createPlaylist(named name: String) async throws -> CodecPlaylist {
        var request = try request(method: "POST", path: "/api/v1/playlists")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["name": name])
        let data = try await sendExpectingSuccess(request)
        return try decoder.decode(CodecPlaylist.self, from: data)
    }

    public func addToPlaylist(id: String, fingerprint: String) async throws {
        var request = URLRequest(url: try playlistURL(id: id, suffix: "/tracks"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["fingerprint": fingerprint])
        for (name, value) in authHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        _ = try await sendExpectingSuccess(request)
    }

    public func removeFromPlaylist(id: String, fingerprint: String) async throws {
        guard let encoded = fingerprint.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw CodecClientError.invalidBaseURL
        }
        var request = URLRequest(url: try playlistURL(id: id, suffix: "/tracks/\(encoded)"))
        request.httpMethod = "DELETE"
        for (name, value) in authHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        _ = try await sendExpectingSuccess(request)
    }

    private func playlistURL(id: String, suffix: String) throws -> URL {
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw CodecClientError.invalidBaseURL
        }
        return try endpointURL(path: "/api/v1/playlists/\(encoded)\(suffix)", encodedPath: true)
    }

    // MARK: - Shared playback (loud.playback.v2)

    public func playbackState() async throws -> PlaybackState? {
        let request = try request(method: "GET", path: "/api/v2/playback")
        let data = try await sendExpectingSuccess(request)
        guard !data.isEmpty, String(decoding: data, as: UTF8.self) != "null" else {
            return nil
        }
        return try decoder.decode(PlaybackState.self, from: data)
    }

    public func sendPlaybackCommand(_ command: PlaybackCommand) async throws -> PlaybackState {
        var request = try request(method: "POST", path: "/api/v2/playback/commands")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(command)
        let data = try await sendExpectingSuccess(request)
        return try decoder.decode(PlaybackState.self, from: data)
    }

    public func playbackDevices() async throws -> [CodecPlaybackDevice] {
        let request = try request(method: "GET", path: "/api/v1/playback/devices")
        let data = try await sendExpectingSuccess(request)
        return (try? decoder.decode([CodecPlaybackDevice].self, from: data)) ?? []
    }

    public func publishPlaybackDevice(_ device: CodecPlaybackDevice) async throws {
        guard let encoded = device.deviceID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw CodecClientError.invalidBaseURL
        }
        var request = URLRequest(url: try endpointURL(path: "/api/v1/playback/devices/\(encoded)", encodedPath: true))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(device)
        for (name, value) in authHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        _ = try await sendExpectingSuccess(request)
    }

    /// Request for the `loud.playback.v2` SSE stream; callers own the
    /// long-lived connection.
    public func playbackEventsRequest() throws -> URLRequest {
        var request = try request(method: "GET", path: "/api/v2/playback/events")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 3600
        return request
    }

    public func request(method: String, path: String) throws -> URLRequest {
        let url = try endpointURL(path: path, encodedPath: false)
        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        for (name, value) in authHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func sendExpectingSuccess(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CodecClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CodecClientError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func endpointURL(path: String, encodedPath: Bool) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme != nil,
              components.host != nil
        else {
            throw CodecClientError.invalidBaseURL
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let joined = "/" + [basePath, endpointPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        if encodedPath {
            components.percentEncodedPath = joined
        } else {
            components.path = joined
        }

        guard let url = components.url else {
            throw CodecClientError.invalidBaseURL
        }
        return url
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CodecClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CodecClientError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try decoder.decode(type, from: data)
    }
}

public enum CodecClientError: Error, Equatable, LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case httpStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Enter a server URL like http://192.168.1.20:8787."
        case .invalidResponse:
            return "The server sent an unreadable response."
        case .httpStatus(let status, _):
            if status == 401 {
                return "The server rejected the token. Check the auth token and try again."
            }
            return "The server answered with HTTP \(status)."
        }
    }
}

/// Normalizes what people actually paste: trims whitespace, strips trailing
/// slashes, and assumes http:// when no scheme is given.
public func normalizeServerURLString(_ raw: String) -> String {
    var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while trimmed.hasSuffix("/") {
        trimmed.removeLast()
    }
    if trimmed.isEmpty {
        return ""
    }
    if trimmed.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) == nil {
        return "http://\(trimmed)"
    }
    return trimmed
}
