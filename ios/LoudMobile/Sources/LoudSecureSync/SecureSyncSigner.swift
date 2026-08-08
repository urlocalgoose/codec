import CryptoKit
import Foundation

public struct SignedRequestHeaders: Equatable {
    public let deviceID: String
    public let timestamp: Int64
    public let nonce: String
    public let signature: String

    public var httpHeaders: [String: String] {
        [
            "x-loud-device-id": deviceID,
            "x-loud-timestamp": String(timestamp),
            "x-loud-nonce": nonce,
            "x-loud-signature": signature
        ]
    }
}

public struct SecureSyncSigner {
    public let deviceID: String
    private let privateKey: P256.Signing.PrivateKey

    public init(deviceID: String, privateKey: P256.Signing.PrivateKey) {
        self.deviceID = Self.cleanDeviceID(deviceID)
        self.privateKey = privateKey
    }

    public func publicKeyJWK() throws -> [String: String] {
        let x963 = privateKey.publicKey.x963Representation
        guard x963.count == 65, x963[0] == 4 else {
            throw SecureSyncSignerError.invalidPublicKey
        }

        return [
            "kty": "EC",
            "crv": "P-256",
            "x": Self.base64URL(Data(x963[1..<33])),
            "y": Self.base64URL(Data(x963[33..<65]))
        ]
    }

    public func signedHeaders(
        method: String,
        url: URL,
        body: Data = Data(),
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        nonce: String = UUID().uuidString
    ) throws -> SignedRequestHeaders {
        let bodyHash = Self.sha256Base64URL(body)
        let message = Self.canonicalRequest(
            method: method,
            url: url,
            timestamp: timestamp,
            nonce: nonce,
            bodyHash: bodyHash
        )
        let signature = try privateKey.signature(for: Data(message.utf8))
        return SignedRequestHeaders(
            deviceID: deviceID,
            timestamp: timestamp,
            nonce: nonce,
            signature: Self.base64URL(signature.rawRepresentation)
        )
    }

    public static func canonicalRequest(
        method: String,
        url: URL,
        timestamp: Int64,
        nonce: String,
        bodyHash: String
    ) -> String {
        [
            method.uppercased(),
            url.path.isEmpty ? "/" : url.path,
            canonicalSearch(url: url),
            String(timestamp),
            nonce,
            bodyHash
        ].joined(separator: "\n")
    }

    public static func canonicalSearch(url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              !queryItems.isEmpty
        else {
            return ""
        }

        components.queryItems = queryItems.sorted {
            if $0.name == $1.name {
                return ($0.value ?? "") < ($1.value ?? "")
            }
            return $0.name < $1.name
        }

        guard let query = components.percentEncodedQuery, !query.isEmpty else {
            return ""
        }
        return "?\(query)"
    }

    public static func sha256Base64URL(_ data: Data) -> String {
        base64URL(Data(SHA256.hash(data: data)))
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func cleanDeviceID(_ value: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-")
        return String(value.trimmingCharacters(in: .whitespacesAndNewlines).map { allowed.contains($0) ? $0 : "_" }.prefix(96))
    }
}

public enum SecureSyncSignerError: Error, Equatable {
    case invalidPublicKey
}
