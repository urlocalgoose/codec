import Foundation
import Testing
@testable import CodecKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let stateJSON = #"""
{
  "schema": "loud.playback.v2",
  "revision": 7,
  "active_device_id": "device-mac",
  "state": "playing",
  "track": {"id": "track_1", "path": "loud://track/abc", "fingerprint": "abc"},
  "context": {
    "playback_source": [{"id": "track_1", "path": "loud://track/abc", "fingerprint": "abc"}],
    "playback_index": 0,
    "queued_tracks": [],
    "play_history": [],
    "shuffle": true,
    "repeat": "all"
  },
  "clock": {"position_seconds": 10, "started_at_ms": 1000, "stopped_at_ms": null, "updated_at_ms": 1000},
  "volume": 0.8,
  "server_time_ms": 1000
}
"""#

@Suite struct PlaybackModelTests {
    @Test func decodesPlaybackState() throws {
        let state = try JSONDecoder().decode(PlaybackState.self, from: Data(stateJSON.utf8))

        #expect(state.revision == 7)
        #expect(state.activeDeviceID == "device-mac")
        #expect(state.isPlaying)
        #expect(state.track?.fingerprint == "abc")
        #expect(state.context.shuffle)
        #expect(state.context.repeatMode == "all")
    }

    @Test func derivedPositionAdvancesWhilePlaying() throws {
        let state = try JSONDecoder().decode(PlaybackState.self, from: Data(stateJSON.utf8))

        // Clock started at server time 1000ms with 10s on the counter; 5s of
        // server time later the derived position is 15s.
        #expect(state.position(atClientTimeMS: 6000) == 15)
        // A client whose clock runs 2s ahead uses the offset to compensate.
        #expect(state.position(atClientTimeMS: 8000, clockOffsetMS: -2000) == 15)
    }

    @Test func derivedPositionFreezesWhenPaused() throws {
        let paused = stateJSON.replacingOccurrences(of: #""state": "playing""#, with: #""state": "paused""#)
        let state = try JSONDecoder().decode(PlaybackState.self, from: Data(paused.utf8))

        #expect(state.position(atClientTimeMS: 99000) == 10)
    }

    @Test func commandEncodesWireFieldNames() throws {
        let command = PlaybackCommand(
            kind: "play",
            deviceID: "device-phone",
            targetDeviceID: "device-mac",
            track: CodecTrackReference(id: "track_1", path: "loud://track/abc", fingerprint: "abc"),
            positionSeconds: 3.5
        )

        let data = try JSONEncoder().encode(command)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["kind"] as? String == "play")
        #expect(object["device_id"] as? String == "device-phone")
        #expect(object["target_device_id"] as? String == "device-mac")
        #expect(object["position_seconds"] as? Double == 3.5)
        #expect((object["command_id"] as? String)?.hasPrefix("device-phone-play-") == true)
        #expect(object["volume"] == nil, "iOS must not stomp other devices' volume")
    }
}

@Suite struct LikeTests {
    private func libraryFixture() throws -> CodecLibrary {
        let json = #"""
        {
          "root_path": "loud://sync-server", "scanned_at": 1,
          "stats": {"trackCount":2,"playlistCount":0,"likedCount":0,"artistCount":1,"albumCount":1,"durationSeconds":100},
          "artists": [], "albums": [],
          "playlists": [{"id":"playlist_liked","name":"Liked Songs","path":"","track_ids":[],"is_liked":true}],
          "tracks": [
            {"id":"track_1","title":"A","artist":"Ada","album":"X","playlist_ids":[],"is_liked":false,"fingerprint":"abc"},
            {"id":"track_2","title":"B","artist":"Ada","album":"X","playlist_ids":[],"is_liked":false,"fingerprint":"def"}
          ]
        }
        """#
        return try JSONDecoder().decode(CodecLibrary.self, from: Data(json.utf8))
    }

    @Test func settingLikedUpdatesTrackPlaylistAndStats() throws {
        let library = try libraryFixture()

        let liked = library.settingLiked(fingerprint: "abc", liked: true)
        #expect(liked.tracks[0].isLiked)
        #expect(!liked.tracks[1].isLiked)
        #expect(liked.playlists[0].trackIDs == ["track_1"])
        #expect(liked.stats.likedCount == 1)

        let unliked = liked.settingLiked(fingerprint: "abc", liked: false)
        #expect(!unliked.tracks[0].isLiked)
        #expect(unliked.playlists[0].trackIDs.isEmpty)
        #expect(unliked.stats.likedCount == 0)
    }

    @Test func setLikedSendsPutWithBody() async throws {
        let base = URL(string: "http://192.168.1.20:8787")!
        let transport = RecordingTransport()
        transport.responses = [(
            Data(#"{"fingerprint":"isrc:US/TEST","liked":true}"#.utf8),
            HTTPURLResponse(url: base, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        )]
        let client = CodecClient(baseURL: base, token: "secret", transport: transport)

        try await client.setLiked(fingerprint: "isrc:US/TEST", liked: true)

        let request = transport.requests[0]
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "http://192.168.1.20:8787/api/v1/tracks/isrc%3AUS%2FTEST/liked")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let body = try #require(request.httpBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"liked":true}"#)
    }
}
