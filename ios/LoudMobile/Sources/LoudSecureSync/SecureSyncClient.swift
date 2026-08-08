import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol SecureSyncTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: SecureSyncTransport {}

public struct SecureSyncHealth: Decodable, Equatable {
    public let ok: Bool
    public let schema: String
    public let playbackSchema: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case schema
        case playbackSchema = "playback_schema"
    }
}

public struct SecureSyncLibrary: Decodable, Equatable {
    public let rootPath: String
    public let scannedAt: Int64
    public let tracks: [SecureSyncTrack]

    enum CodingKeys: String, CodingKey {
        case rootPath = "root_path"
        case scannedAt = "scanned_at"
        case tracks
    }
}

public struct SecureSyncTrack: Decodable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let artist: String
    public let album: String
    public let durationSeconds: Double?
    public let artworkURL: URL?
    public let audioURL: URL?
    public let fingerprint: String

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case artist
        case album
        case durationSeconds = "duration_seconds"
        case artworkURL = "artwork_url"
        case audioURL = "audio_url"
        case fingerprint
    }
}

public struct DeviceEnrollmentRequest: Encodable, Equatable {
    public let deviceID: String
    public let name: String
    public let platform: String
    public let publicKeyJWK: [String: String]

    public init(deviceID: String, name: String, platform: String, publicKeyJWK: [String: String]) {
        self.deviceID = SecureSyncSigner.cleanDeviceID(deviceID)
        self.name = name
        self.platform = platform
        self.publicKeyJWK = publicKeyJWK
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case name
        case platform
        case publicKeyJWK = "public_key_jwk"
    }
}

public struct EnrolledDevice: Decodable, Equatable {
    public let deviceID: String
    public let name: String
    public let platform: String
    public let ownerEmail: String
    public let createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case name
        case platform
        case ownerEmail = "owner_email"
        case createdAt = "created_at"
    }
}

public struct SecureSyncClient {
    private let baseURL: URL
    private let signer: SecureSyncSigner?
    private let transport: SecureSyncTransport
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(baseURL: URL, signer: SecureSyncSigner? = nil, transport: SecureSyncTransport = URLSession.shared) {
        self.baseURL = baseURL
        self.signer = signer
        self.transport = transport
    }

    public func health() async throws -> SecureSyncHealth {
        let request = try makeUnsignedRequest(method: "GET", path: "/health")
        return try await send(request, as: SecureSyncHealth.self)
    }

    public func library() async throws -> SecureSyncLibrary {
        let request = try makeUnsignedRequest(method: "GET", path: "/api/v1/library")
        return try await send(request, as: SecureSyncLibrary.self)
    }

    public func enrollmentRequest(name: String, platform: String) throws -> DeviceEnrollmentRequest {
        guard let signer else {
            throw SecureSyncClientError.missingSigner
        }
        return try DeviceEnrollmentRequest(
            deviceID: signer.deviceID,
            name: name,
            platform: platform,
            publicKeyJWK: signer.publicKeyJWK()
        )
    }

    public func enrollDevice(_ enrollment: DeviceEnrollmentRequest, accessJWT: String) async throws -> EnrolledDevice {
        var request = try makeJSONRequest(
            method: "POST",
            path: "/api/v3/devices",
            body: enrollment,
            signed: false
        )
        request.setValue(accessJWT, forHTTPHeaderField: "Cf-Access-Jwt-Assertion")
        return try await send(request, as: EnrolledDevice.self)
    }

    public func makeUnsignedRequest(method: String, path: String, queryItems: [URLQueryItem] = []) throws -> URLRequest {
        let url = try endpointURL(path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        return request
    }

    public func makeSignedRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Data = Data(),
        contentType: String? = nil
    ) throws -> URLRequest {
        guard let signer else {
            throw SecureSyncClientError.missingSigner
        }

        let url = try endpointURL(path: path, queryItems: queryItems)
        let headers = try signer.signedHeaders(method: method, url: url, body: body)
        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        request.httpBody = body.isEmpty ? nil : body
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers.httpHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    public func makeJSONRequest<T: Encodable>(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: T,
        signed: Bool = true
    ) throws -> URLRequest {
        let bodyData = try encoder.encode(body)
        if signed {
            return try makeSignedRequest(
                method: method,
                path: path,
                queryItems: queryItems,
                body: bodyData,
                contentType: "application/json"
            )
        }

        var request = try makeUnsignedRequest(method: method, path: path, queryItems: queryItems)
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func endpointURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme != nil,
              components.host != nil
        else {
            throw SecureSyncClientError.invalidBaseURL
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, endpointPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw SecureSyncClientError.invalidBaseURL
        }
        return url
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SecureSyncClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SecureSyncClientError.httpStatus(http.statusCode, body)
        }
        return try decoder.decode(type, from: data)
    }
}

public enum SecureSyncClientError: Error, Equatable {
    case invalidBaseURL
    case missingSigner
    case invalidResponse
    case httpStatus(Int, String)
}
