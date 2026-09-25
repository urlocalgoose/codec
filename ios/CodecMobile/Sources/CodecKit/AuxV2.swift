import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AuxMode: String, Codable, CaseIterable, Sendable {
    case sharedSpeaker = "shared_speaker", listenTogether = "listen_together"
    public var title: String { self == .sharedSpeaker ? "Shared speaker" : "Listen together" }
}

public struct AuxTrack: Codable, Equatable, Identifiable, Sendable {
    public var id: String { fingerprint }
    public let fingerprint: String
    public let title: String
    public let artist: String
    public let album: String
    public let durationSeconds: Double
    public let mediaURL: String
    public let artworkURL: String?
    enum CodingKeys: String, CodingKey {
        case fingerprint, title, artist, album
        case durationSeconds = "duration_seconds", mediaURL = "media_url", artworkURL = "artwork_url"
    }
}
public struct AuxEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String { entryID }
    public let entryID: String
    public let participantID: String
    public let track: AuxTrack
    enum CodingKeys: String, CodingKey { case entryID = "entry_id", participantID = "participant_id", track }
}
public struct AuxMember: Codable, Equatable, Identifiable, Sendable {
    public var id: String { participantID }
    public let participantID: String
    public let displayName: String
    enum CodingKeys: String, CodingKey { case participantID = "participant_id", displayName = "display_name" }
}
public struct AuxState: Codable, Equatable, Sendable {
    public let schema: String
    public let sessionID: String
    public let mode: AuxMode
    public let hostName: String
    public let role: String
    public let participantID: String
    public let expiresAt: Int64
    public let revision: Int64
    public let serverTimeMS: Int64
    public let status: String
    public let positionSeconds: Double
    public let anchorTimeMS: Int64
    public let current: AuxEntry?
    public let queue: [AuxEntry]
    public let allowSaves: Bool
    public let allowContributions: Bool
    public let hostDeviceID: String?
    public let members: [AuxMember]?
    public let mediaToken: String?
    enum CodingKeys: String, CodingKey {
        case schema, mode, role, revision, status, current, queue, members
        case mediaToken = "media_token"
        case sessionID = "session_id", hostName = "host_name", participantID = "participant_id", expiresAt = "expires_at"
        case serverTimeMS = "server_time_ms", positionSeconds = "position_seconds", anchorTimeMS = "anchor_time_ms"
        case allowSaves = "allow_saves", allowContributions = "allow_contributions", hostDeviceID = "host_device_id"
    }
    public func position(elapsed: Double) -> Double {
        let value = max(0, positionSeconds + (status == "playing" ? max(0, elapsed) : 0))
        if let duration = current?.track.durationSeconds, duration > 0 { return min(duration, value) }
        return value
    }
}
public struct AuxInvitation: Codable, Sendable {
    public let schema: String
    public let hostName: String
    public let mode: AuxMode
    public let expiresAt: Int64
    enum CodingKeys: String, CodingKey { case schema, mode, hostName = "host_name", expiresAt = "expires_at" }
}
public struct AuxJoinResult: Codable, Sendable {
    public let sessionID: String
    public let participantID: String
    public let participantToken: String
    public let state: AuxState
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", participantID = "participant_id", participantToken = "participant_token", state }
}
public struct AuxCreateResult: Codable, Sendable {
    public let sessionID: String
    public let inviteSecret: String
    public let state: AuxState
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", inviteSecret = "invite_secret", state }
}
public struct AuxGrantReference: Codable, Equatable, Sendable {
    public let sourceOrigin: String
    public let token: String
    public init(sourceOrigin: String, token: String) { self.sourceOrigin = sourceOrigin; self.token = token }
    enum CodingKeys: String, CodingKey { case sourceOrigin = "source_origin", token }
}
public struct AuxMembership: Decodable, Sendable {
    public let fingerprint: String
    public let status: String
    public let trackID: String?
    enum CodingKeys: String, CodingKey { case fingerprint, status, trackID = "track_id" }
}
public struct AuxTransferResult: Decodable, Sendable {
    public let status: String
    public let playlistAdded: Bool
    enum CodingKeys: String, CodingKey { case status, playlistAdded = "playlist_added" }
}

/// Separate session transport. An invitation lookup/join never carries a saved
/// personal token. Media is constrained to this origin and this Aux session.
public struct AuxClient: Sendable {
    public let baseURL: URL
    public let token: String?
    private let transport: CodecTransport
    public init(baseURL: URL, token: String? = nil, transport: CodecTransport = URLSession.shared) {
        self.baseURL = baseURL; self.token = token; self.transport = transport
    }
    public var origin: String { baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    public func request(_ path: String, method: String = "GET", body: Data? = nil, authenticated: Bool = true) throws -> URLRequest {
        guard ["https", "http"].contains(baseURL.scheme?.lowercased() ?? ""), baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil else { throw CodecClientError.invalidBaseURL }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw CodecClientError.invalidBaseURL }
        components.percentEncodedPath = "/" + [components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")), path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))].filter { !$0.isEmpty }.joined(separator: "/")
        components.query = nil; components.fragment = nil
        guard let url = components.url else { throw CodecClientError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if authenticated, let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }
    private func send<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil, authenticated: Bool = true, as type: T.Type = T.self) async throws -> T {
        let data = try await raw(path, method: method, body: body, authenticated: authenticated)
        return try JSONDecoder().decode(T.self, from: data)
    }
    public func raw(_ path: String, method: String = "GET", body: [String: Any]? = nil, authenticated: Bool = true) async throws -> Data {
        let request = try request(path, method: method, body: body.map { try JSONSerialization.data(withJSONObject: $0) }, authenticated: authenticated)
        let (data, response) = try await transport.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CodecClientError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw CodecClientError.httpStatus(response.statusCode, "Aux request failed") }
        return data
    }
    public func invitation(secret: String) async throws -> AuxInvitation {
        try await send("/api/v2/aux/invitation", method: "POST", body: ["invite_secret": secret], authenticated: false)
    }
    public func join(secret: String, name: String) async throws -> AuxJoinResult {
        try await send("/api/v2/aux/join", method: "POST", body: ["invite_secret": secret, "display_name": name], authenticated: false)
    }
    public func create(mode: AuxMode, deviceID: String, name: String, fingerprints: [String], allowSaves: Bool, allowContributions: Bool) async throws -> AuxCreateResult {
        try await send("/api/v2/aux/sessions", method: "POST", body: ["mode": mode.rawValue, "host_device_id": deviceID, "host_name": name, "catalog_fingerprints": fingerprints, "allow_saves": allowSaves, "allow_contributions": allowContributions])
    }
    public func sessions() async throws -> [AuxState] {
        struct Result: Decodable { let sessions: [AuxState] }
        return try await send("/api/v2/aux/sessions", as: Result.self).sessions
    }
    public func state(_ id: String) async throws -> AuxState { try await send(sessionPath(id) + "/state") }
    public func catalog(_ id: String) async throws -> [AuxTrack] {
        struct Result: Decodable { let tracks: [AuxTrack] }
        return try await send(sessionPath(id) + "/catalog", as: Result.self).tracks
    }
    public func command(_ id: String, kind: String, revision: Int64? = nil, fingerprint: String? = nil, entryID: String? = nil, entryIDs: [String]? = nil, grant: AuxGrantReference? = nil) async throws -> AuxState {
        var body: [String: Any] = ["command_id": UUID().uuidString, "kind": kind]
        if let revision { body["expected_revision"] = revision }
        if let fingerprint { body["fingerprint"] = fingerprint }
        if let entryID { body["entry_id"] = entryID }
        if let entryIDs { body["entry_ids"] = entryIDs }
        if let grant { body["grant"] = ["source_origin": grant.sourceOrigin, "token": grant.token] }
        return try await send(sessionPath(id) + "/commands", method: "POST", body: body)
    }
    public func delete(_ id: String, suffix: String = "") async throws { _ = try await raw(sessionPath(id) + suffix, method: "DELETE") }
    public func rotateInvite(_ id: String) async throws -> String {
        struct Result: Decodable { let invite_secret: String }
        return try await send(sessionPath(id) + "/invite", method: "POST", body: [:], as: Result.self).invite_secret
    }
    public func mediaURL(_ path: String, sessionID: String) -> URL? {
        guard !path.isEmpty, let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.scheme == baseURL.scheme, url.host == baseURL.host, url.port == baseURL.port,
              url.user == nil, url.password == nil,
              url.path.hasPrefix("/api/v2/aux/sessions/\(sessionID)/tracks/"),
              url.query == nil, url.fragment == nil else { return nil }
        return url
    }
    public func mediaRequest(for track: AuxTrack, sessionID: String, mediaToken: String? = nil) -> URLRequest? {
        if let url = mediaURL(track.mediaURL, sessionID: sessionID) {
            var request = URLRequest(url: url)
            if let token = mediaToken ?? token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            return request
        }
        return nil
    }

    public func membership(_ fingerprint: String) async throws -> AuxMembership {
        try await send("/api/v2/aux/membership/" + encode(fingerprint))
    }
    public func addMembershipToPlaylist(fingerprint: String, playlistID: String) async throws {
        _ = try await raw("/api/v2/aux/membership/" + encode(fingerprint) + "/playlist", method: "POST", body: ["playlist_id": playlistID])
    }
    public func grant(fingerprint: String, sessionID: String, sessionOrigin: String, allowCopy: Bool) async throws -> AuxGrantReference {
        let data = try await raw("/api/v2/aux/grants", method: "POST", body: ["fingerprint": fingerprint, "session_id": sessionID, "session_origin": sessionOrigin, "destination_origin": sessionOrigin, "allow_copy": allowCopy])
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = object?["token"] as? String else { throw CodecClientError.invalidResponse }
        return AuxGrantReference(sourceOrigin: origin, token: token)
    }
    public func transfer(operationID: String, grant: AuxGrantReference, sessionID: String, sessionOrigin: String, playlistID: String?) async throws -> AuxTransferResult {
        var body: [String: Any] = ["operation_id": operationID, "grant": ["source_origin": grant.sourceOrigin, "token": grant.token], "session_id": sessionID, "session_origin": sessionOrigin]
        if let playlistID { body["playlist_id"] = playlistID }
        return try await send("/api/v2/aux/transfers", method: "POST", body: body)
    }
    public func copyGrant(_ id: String, fingerprint: String, destinationOrigin: String) async throws -> AuxGrantReference {
        try await send(sessionPath(id) + "/tracks/" + encode(fingerprint) + "/copy-grant", method: "POST", body: ["destination_origin": destinationOrigin])
    }
    private func sessionPath(_ id: String) -> String { "/api/v2/aux/sessions/" + encode(id) }
    private func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
}
