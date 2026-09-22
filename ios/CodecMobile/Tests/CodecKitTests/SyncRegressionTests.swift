import Foundation
import Testing
@testable import CodecKit

@Suite struct SyncRegressionTests {
    @Test func playbackPlaylistOriginIsOptionalAndRoundTrips() throws {
        let legacy = try JSONDecoder().decode(PlaybackContext.self, from: Data("{}".utf8))
        #expect(legacy.playlistID == nil)
        let legacyObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        #expect(legacyObject["playlist_id"] == nil)

        let context = PlaybackContext(playlistID: " drive-home ")
        let encoded = try JSONEncoder().encode(context)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["playlist_id"] as? String == "drive-home")
        #expect(try JSONDecoder().decode(PlaybackContext.self, from: encoded) == context)
        for json in [#"{"playlist_id":null}"#, #"{"playlist_id":"  "}"#] {
            #expect(try JSONDecoder().decode(PlaybackContext.self, from: Data(json.utf8)).playlistID == nil)
        }
    }

    @Test func foreignReferencesSurviveDecodingAndRequeueing() throws {
        let data = Data(#"{"id":"foreign","path":"aux://song","fingerprint":"song","title":"Shared song","artist":"Guest","media_url":"https://friend.test/audio?access_token=grant_test","artwork_url":"https://friend.test/artwork?access_token=grant_test"}"#.utf8)
        let reference = try JSONDecoder().decode(CodecTrackReference.self, from: data)
        let track = CodecTrack(
            id: reference.id, title: reference.title!, artist: reference.artist!, album: "",
            artworkURL: reference.artworkURL, audioURL: reference.mediaURL, fingerprint: reference.fingerprint
        )
        let queued = CodecTrackReference(track: track)
        #expect(queued.mediaURL == reference.mediaURL)
        #expect(queued.artworkURL == reference.artworkURL)
        #expect(queued.title == "Shared song")
        let encoded = try JSONEncoder().encode(queued)
        let decoded = try JSONDecoder().decode(CodecTrackReference.self, from: encoded)
        #expect(decoded == queued)
    }

    @Test func localReferencesStillUseTheOriginalWireShape() throws {
        let track = CodecTrack(id: "local", title: "Song", artist: "Artist", album: "Album", audioURL: URL(string: "https://home.test/audio"), fingerprint: "song")
        let reference = CodecTrackReference(track: track)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(reference)) as? [String: Any])
        #expect(object["media_url"] == nil)
        #expect(object["path"] as? String == "loud://track/song")
        let legacy = try JSONDecoder().decode(CodecTrackReference.self, from: Data(#"{"id":"local","path":"loud://track/song","fingerprint":"song"}"#.utf8))
        #expect(legacy.mediaURL == nil)
    }

    @Test func mediaCredentialsAreLimitedToTheServerOrigin() {
        let client = CodecClient(baseURL: URL(string: "https://home.test")!, token: "test-secret")
        #expect(client.authHeaders(for: URL(string: "https://home.test:443/audio")!)["Authorization"] == "Bearer test-secret")
        #expect(client.authHeaders(for: URL(string: "https://friend.test/audio?access_token=grant_test")!).isEmpty)
        #expect(client.authHeaders(for: URL(string: "http://home.test/audio")!).isEmpty)
        #expect(client.authHeaders(for: URL(string: "https://home.test:8443/audio")!).isEmpty)
        #expect(client.authHeaders(for: URL(fileURLWithPath: "/tmp/audio.wav")).isEmpty)
    }

    @Test func queueRevisionUsesAHeaderWithoutChangingTheCommandBody() async throws {
        let url = URL(string: "https://home.test")!
        let transport = RecordingTransport()
        let state = Data(#"{"schema":"loud.playback.v2","revision":8,"state":"paused","track":null,"active_device_id":null,"context":{},"clock":{"position_seconds":0,"started_at_ms":null,"stopped_at_ms":null,"updated_at_ms":1},"volume":1,"server_time_ms":1}"#.utf8)
        transport.responses = [(state, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)]
        let client = CodecClient(baseURL: url, transport: transport)
        var command = PlaybackCommand(kind: "set_queue", deviceID: "phone", context: PlaybackContext())
        command.expectedRevision = 7
        _ = try await client.sendPlaybackCommand(command)
        let request = transport.requests[0]
        #expect(request.value(forHTTPHeaderField: "If-Match") == "\"7\"")
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["expectedRevision"] == nil)
        #expect(object["kind"] as? String == "set_queue")
    }

    @Test func libraryEventsDecodeWithoutPlaybackState() throws {
        let payload = try JSONDecoder().decode(PlaybackEventPayload.self, from: Data(#"{"type":"library"}"#.utf8))
        #expect(payload.type == "library")
        #expect(payload.playbackState == nil)
    }
}
