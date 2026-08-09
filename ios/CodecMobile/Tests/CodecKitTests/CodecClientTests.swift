import Foundation
import Testing
@testable import CodecKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class RecordingTransport: CodecTransport, @unchecked Sendable {
    var requests: [URLRequest] = []
    var responses: [(Data, URLResponse)] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw CodecClientError.invalidResponse
        }
        return responses.removeFirst()
    }
}

private func httpResponse(url: URL, status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
}

@Suite struct CodecClientTests {
    let base = URL(string: "http://192.168.1.20:8787")!

    @Test func healthHitsTheHealthEndpoint() async throws {
        let transport = RecordingTransport()
        transport.responses = [(
            Data(#"{"ok":true,"schema":"loud.sync.v1","playback_schema":"loud.playback.v2"}"#.utf8),
            httpResponse(url: base)
        )]
        let client = CodecClient(baseURL: base, transport: transport)

        let health = try await client.health()

        #expect(health.ok)
        #expect(health.schema == "loud.sync.v1")
        #expect(health.playbackSchema == "loud.playback.v2")
        #expect(transport.requests[0].url?.absoluteString == "http://192.168.1.20:8787/health")
        #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func tokenIsSentAsBearer() async throws {
        let transport = RecordingTransport()
        transport.responses = [(
            Data(#"{"ok":true,"schema":"loud.sync.v1","playback_schema":null}"#.utf8),
            httpResponse(url: base)
        )]
        let client = CodecClient(baseURL: base, token: "  secret-token \n", transport: transport)

        _ = try await client.health()

        #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
    }

    @Test func libraryDecodesTracksAndPlaylists() async throws {
        let json = #"""
        {
          "root_path": "loud://sync-server",
          "scanned_at": 1754500000,
          "stats": {"trackCount":1,"playlistCount":1,"likedCount":1,"artistCount":1,"albumCount":1,"durationSeconds":273.1},
          "artists": [{"name":"1986 OMEGA TRIBE","trackCount":1,"albumCount":1,"durationSeconds":273.1}],
          "albums": [{"name":"Crystal Night","artist":"1986 OMEGA TRIBE","trackCount":1,"durationSeconds":273.1,"artwork_url":null}],
          "playlists": [{"id":"playlist_liked","name":"Liked Songs","path":"","track_ids":["track_1"],"is_liked":true}],
          "tracks": [{
            "id":"track_1","path":"","file_name":"a.mp3","title":"Crystal Night","artist":"1986 OMEGA TRIBE",
            "album":"Crystal Night","album_artist":null,"genre":null,"year":null,"track_number":1,
            "duration_seconds":273.144,
            "artwork_url":"http://192.168.1.20:8787/api/v1/tracks/abc/artwork",
            "audio_url":"http://192.168.1.20:8787/api/v1/tracks/abc/audio",
            "playlist_ids":["playlist_liked"],"added_at":1,"size_bytes":10,"is_liked":true,"fingerprint":"abc"
          }]
        }
        """#
        let transport = RecordingTransport()
        transport.responses = [(Data(json.utf8), httpResponse(url: base))]
        let client = CodecClient(baseURL: base, transport: transport)

        let library = try await client.library()

        #expect(transport.requests[0].url?.absoluteString == "http://192.168.1.20:8787/api/v1/library")
        #expect(library.tracks.count == 1)
        #expect(library.tracks[0].title == "Crystal Night")
        #expect(library.tracks[0].isLiked)
        #expect(library.tracks[0].audioURL?.absoluteString == "http://192.168.1.20:8787/api/v1/tracks/abc/audio")
        #expect(library.playlists[0].isLiked)
        #expect(library.stats.trackCount == 1)
    }

    @Test func libraryToleratesNullArraysFromEmptyServer() async throws {
        let json = #"{"root_path":"loud://sync-server","scanned_at":1,"artists":null,"albums":null,"playlists":null,"tracks":null}"#
        let transport = RecordingTransport()
        transport.responses = [(Data(json.utf8), httpResponse(url: base))]
        let client = CodecClient(baseURL: base, transport: transport)

        let library = try await client.library()

        #expect(library.tracks.isEmpty)
        #expect(library.playlists.isEmpty)
        #expect(library.stats == .empty)
    }

    @Test func mediaURLEncodesFingerprints() {
        let client = CodecClient(baseURL: base)

        let url = client.mediaURL(fingerprint: "isrc:US/TEST", kind: "audio")

        #expect(url?.absoluteString == "http://192.168.1.20:8787/api/v1/tracks/isrc%3AUS%2FTEST/audio")
    }

    @Test func httpErrorsSurfaceStatusCodes() async {
        let transport = RecordingTransport()
        transport.responses = [(Data(), httpResponse(url: base, status: 401))]
        let client = CodecClient(baseURL: base, token: "wrong", transport: transport)

        do {
            _ = try await client.health()
            Issue.record("expected an error")
        } catch let error as CodecClientError {
            #expect(error == .httpStatus(401, ""))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func normalizesPastedServerURLs() {
        #expect(normalizeServerURLString(" 192.168.1.20:8787/ ") == "http://192.168.1.20:8787")
        #expect(normalizeServerURLString("https://loud.example.com///") == "https://loud.example.com")
        #expect(normalizeServerURLString("") == "")
    }
}
