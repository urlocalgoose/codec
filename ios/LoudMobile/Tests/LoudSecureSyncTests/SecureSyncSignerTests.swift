import CryptoKit
import Foundation
import Testing
@testable import LoudSecureSync

@Suite("Secure sync signer")
struct SecureSyncSignerTests {
    @Test
    func canonicalRequestMatchesWorkerFormat() {
        let url = URL(string: "https://codec.example.com/api/v3/library?z=2&a=2&a=1")!
        let bodyHash = SecureSyncSigner.sha256Base64URL(Data("body".utf8))
        let message = SecureSyncSigner.canonicalRequest(
            method: "post",
            url: url,
            timestamp: 123,
            nonce: "nonce",
            bodyHash: bodyHash
        )

        #expect(SecureSyncSigner.canonicalSearch(url: url) == "?a=1&a=2&z=2")
        #expect(message == "POST\n/api/v3/library\n?a=1&a=2&z=2\n123\nnonce\n\(bodyHash)")
    }

    @Test
    func signerProducesRawP256SignatureAndJWK() throws {
        let signer = SecureSyncSigner(deviceID: " phone 1 / weird ", privateKey: P256.Signing.PrivateKey())
        let url = URL(string: "https://codec.example.com/api/v3/library")!
        let headers = try signer.signedHeaders(method: "GET", url: url, timestamp: 123, nonce: "nonce")
        let jwk = try signer.publicKeyJWK()

        #expect(headers.deviceID == "phone_1___weird")
        #expect(headers.httpHeaders["x-loud-signature"] == headers.signature)
        #expect(Data(base64URLEncoded: headers.signature)?.count == 64)
        #expect(jwk["kty"] == "EC")
        #expect(jwk["crv"] == "P-256")
        #expect(jwk["x"]?.isEmpty == false)
        #expect(jwk["y"]?.isEmpty == false)
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var padded = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder > 0 {
            padded += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: padded)
    }
}
