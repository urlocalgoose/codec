import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol LoudTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: LoudTransport {}

/// Client for the Loud sync server (`loud-sync-server`).
///
/// Speaks the plain v1 API with optional shared-token auth: when the server
/// is started with `LOUD_AUTH_TOKEN`, every request carries
/// `Authorization: Bearer <token>`.
public struct LoudClient: Sendable {
    public let baseURL: URL
    public let token: String?
    private let transport: LoudTransport
    private let decoder = JSONDecoder()

    public init(baseURL: URL, token: String? = nil, transport: LoudTransport = URLSession.shared) {
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

    public func health() async throws -> LoudHealth {
        try await send(request(method: "GET", path: "/health"), as: LoudHealth.self)
    }

    public func library() async throws -> LoudLibrary {
        try await send(request(method: "GET", path: "/api/v1/library"), as: LoudLibrary.self)
    }

    /// Canonical audio URL for a track, used for both streaming and downloads.
    /// Prefers the URL the server embedded in the library payload and falls
    /// back to building one from the fingerprint.
    public func audioURL(for track: LoudTrack) -> URL? {
        track.audioURL ?? mediaURL(fingerprint: track.fingerprint, kind: "audio")
    }

    public func artworkURL(for track: LoudTrack) -> URL? {
        track.artworkURL ?? mediaURL(fingerprint: track.fingerprint, kind: "artwork")
    }

    public func mediaURL(fingerprint: String, kind: String) -> URL? {
        guard let encoded = fingerprint.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            return nil
        }
        return try? endpointURL(path: "/api/v1/tracks/\(encoded)/\(kind)", encodedPath: true)
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

    private func endpointURL(path: String, encodedPath: Bool) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme != nil,
              components.host != nil
        else {
            throw LoudClientError.invalidBaseURL
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
            throw LoudClientError.invalidBaseURL
        }
        return url
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LoudClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LoudClientError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try decoder.decode(type, from: data)
    }
}

public enum LoudClientError: Error, Equatable, LocalizedError {
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
