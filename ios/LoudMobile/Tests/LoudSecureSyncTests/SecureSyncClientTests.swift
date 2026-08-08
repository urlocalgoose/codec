import CryptoKit
import Foundation
import Testing
@testable import LoudSecureSync

@Suite("Secure sync client")
struct SecureSyncClientTests {
    @Test
    func healthUsesUnsignedHealthEndpoint() async throws {
        let transport = RecordingTransport(
            data: Data(#"{"ok":true,"schema":"loud.sync.v3","playback_schema":"loud.playback.v2"}"#.utf8),
            statusCode: 200
        )
        let client = SecureSyncClient(baseURL: URL(string: "https://codec.example.com/base")!, transport: transport)

        let health = try await client.health()

        #expect(health.schema == "loud.sync.v3")
        #expect(health.playbackSchema == "loud.playback.v2")
        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].url?.absoluteString == "https://codec.example.com/base/health")
        #expect(transport.requests[0].value(forHTTPHeaderField: "x-loud-signature") == nil)
    }

    @Test
    func healthAllowsLocalServerWithoutPlaybackSchema() async throws {
        let transport = RecordingTransport(
            data: Data(#"{"ok":true,"schema":"loud.sync.v1"}"#.utf8),
            statusCode: 200
        )
        let client = SecureSyncClient(baseURL: URL(string: "http://192.168.1.20:8787")!, transport: transport)

        let health = try await client.health()

        #expect(health.ok)
        #expect(health.schema == "loud.sync.v1")
        #expect(health.playbackSchema == nil)
    }

    @Test
    func libraryUsesV1LibraryEndpoint() async throws {
        let transport = RecordingTransport(
            data: Data(
                #"{"root_path":"loud://sync-server","scanned_at":1786147875,"tracks":[{"id":"track_1","title":"Crystal Night","artist":"1986 OMEGA TRIBE","album":"Crystal Night","duration_seconds":273.144,"artwork_url":"http://192.168.1.20:8787/api/v1/tracks/abc/artwork","audio_url":"http://192.168.1.20:8787/api/v1/tracks/abc/audio","fingerprint":"abc"}]}"#.utf8
            ),
            statusCode: 200
        )
        let client = SecureSyncClient(baseURL: URL(string: "http://192.168.1.20:8787")!, transport: transport)

        let library = try await client.library()

        #expect(library.tracks.count == 1)
        #expect(library.tracks[0].title == "Crystal Night")
        #expect(library.tracks[0].audioURL?.absoluteString == "http://192.168.1.20:8787/api/v1/tracks/abc/audio")
        #expect(transport.requests[0].url?.absoluteString == "http://192.168.1.20:8787/api/v1/library")
    }

    @Test
    func signedJSONRequestAddsDeviceHeaders() throws {
        let signer = SecureSyncSigner(deviceID: "phone-1", privateKey: P256.Signing.PrivateKey())
        let client = SecureSyncClient(baseURL: URL(string: "https://codec.example.com")!, signer: signer)
        let enrollment = try client.enrollmentRequest(name: "iPhone", platform: "ios")
        let request = try client.makeJSONRequest(
            method: "PUT",
            path: "/api/v3/sync/push",
            queryItems: [URLQueryItem(name: "b", value: "2"), URLQueryItem(name: "a", value: "1")],
            body: enrollment
        )

        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://codec.example.com/api/v3/sync/push?b=2&a=1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "x-loud-device-id") == "phone-1")
        #expect(request.value(forHTTPHeaderField: "x-loud-timestamp")?.isEmpty == false)
        #expect(request.value(forHTTPHeaderField: "x-loud-nonce")?.isEmpty == false)
        #expect(request.value(forHTTPHeaderField: "x-loud-signature")?.isEmpty == false)
        #expect(request.httpBody?.isEmpty == false)
    }
}

private final class RecordingTransport: SecureSyncTransport {
    private(set) var requests: [URLRequest] = []
    private let data: Data
    private let statusCode: Int

    init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
