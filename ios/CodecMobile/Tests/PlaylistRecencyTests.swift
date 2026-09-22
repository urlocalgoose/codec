import AVFoundation
import Foundation
import XCTest
@testable import Codec

@MainActor
final class PlaylistRecencyTests: XCTestCase {
    private let track = CodecTrack(
        id: "shared-song", title: "Shared Song", artist: "", album: "",
        artworkURL: URL(fileURLWithPath: "/dev/null"),
        audioURL: URL(fileURLWithPath: "/dev/null"), fingerprint: "shared-song"
    )

    private func withPreferences(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "PlaylistRecencyTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        try body(preferences)
    }

    private func makeApp(_ preferences: UserDefaults, server: String = "https://history-tests.invalid") -> AppModel {
        let app = AppModel(
            client: CodecClient(baseURL: URL(string: server)!),
            playlistHistoryDefaults: preferences
        )
        app.library = library()
        return app
    }

    private func library(names: [String] = ["Alpha", "Bravo", "Charlie"]) -> CodecLibrary {
        CodecLibrary(
            rootPath: "", scannedAt: 0, stats: .empty, artists: [], albums: [],
            playlists: names.enumerated().map { index, name in
                CodecPlaylist(id: String(index), name: name, trackIDs: [track.id], isLiked: false)
            }, tracks: [track]
        )
    }

    private func player() -> PlayerController {
        let player = PlayerController(makePlayer: { _ in RecencyPlayerSpy() }, activateAudioSession: {})
        player.client = CodecClient(baseURL: URL(string: "https://history-tests.invalid")!)
        return player
    }

    func testMostRecentPlaybackMovesOnlyHomeWhileUnplayedOrderIsStable() {
        withPreferences { preferences in
            let app = makeApp(preferences)
            XCTAssertEqual(app.homePlaylists.map(\.id), ["0", "1", "2"])
            app.recordPlaylistPlayback(playlistID: "2")
            XCTAssertEqual(app.homePlaylists.map(\.id), ["2", "0", "1"])
            app.recordPlaylistPlayback(playlistID: "1")
            XCTAssertEqual(app.homePlaylists.map(\.id), ["1", "2", "0"])
            app.recordPlaylistPlayback(playlistID: "2")
            app.recordPlaylistPlayback(playlistID: "2")
            XCTAssertEqual(app.homePlaylists.map(\.id), ["2", "1", "0"])
            XCTAssertEqual(app.userPlaylists.map(\.id), ["0", "1", "2"])
        }
    }

    func testHistorySurvivesRelaunchAndIsIsolatedByServer() {
        withPreferences { preferences in
            makeApp(preferences).recordPlaylistPlayback(playlistID: "2")
            let relaunched = makeApp(preferences, server: "https://history-tests.invalid/")
            XCTAssertEqual(relaunched.homePlaylists.map(\.id), ["2", "0", "1"])
            let otherServer = makeApp(preferences, server: "https://another-library.invalid")
            XCTAssertEqual(otherServer.homePlaylists.map(\.id), ["0", "1", "2"])
            otherServer.recordPlaylistPlayback(playlistID: "1")
            XCTAssertEqual(makeApp(preferences).homePlaylists.map(\.id), ["2", "0", "1"])
        }
    }

    func testRefreshKeepsRecencyByIdentityAcrossRenameAndDeletion() {
        withPreferences { preferences in
            let app = makeApp(preferences)
            app.recordPlaylistPlayback(playlistID: "2")
            app.recordPlaylistPlayback(playlistID: "1")
            app.library = library(names: ["Renamed Alpha", "Renamed Bravo"])
            XCTAssertEqual(app.homePlaylists.map(\.name), ["Renamed Bravo", "Renamed Alpha"])
            app.recordPlaylistPlayback(playlistID: "0")
            XCTAssertEqual(app.homePlaylists.map(\.id), ["0", "1"])
        }
    }

    func testEmptyLikedAndUnknownPlaylistsDoNotBecomeRecent() {
        withPreferences { preferences in
            let app = makeApp(preferences)
            let original = app.library!
            app.library = CodecLibrary(
                rootPath: "", scannedAt: 0, stats: .empty, artists: [], albums: [],
                playlists: original.playlists + [
                    CodecPlaylist(id: "empty", name: "Empty", trackIDs: [], isLiked: false),
                    CodecPlaylist(id: "liked", name: "Liked", trackIDs: [track.id], isLiked: true)
                ], tracks: [track]
            )
            for id in ["empty", "liked", "missing"] { app.recordPlaylistPlayback(playlistID: id) }
            XCTAssertEqual(app.homePlaylists.map(\.id), ["0", "1", "2", "empty"])
            XCTAssertNil(preferences.object(forKey: "codec.playlistPlaybackOrder.v1"))
        }
    }

    func testPlaylistIdentityIsExplicitEvenWhenEveryPlaylistSharesTheSong() throws {
        // syncPlayer correctly puts an unconnected app into offline mode.
        // Exercise that path with a real local file rather than /dev/null.
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codec-recency-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try writeSilentWAV(to: audioURL)
        let localTrack = CodecTrack(
            id: track.id, title: track.title, artist: track.artist, album: track.album,
            artworkURL: track.artworkURL, audioURL: audioURL, fingerprint: track.fingerprint
        )
        withPreferences { preferences in
            let app = makeApp(preferences)
            let player = player()
            app.syncPlayer(player)
            XCTAssertFalse(player.isSyncAvailable)
            player.play(localTrack, from: [localTrack], playlistID: "2")
            XCTAssertEqual(app.homePlaylists.map(\.id), ["2", "0", "1"])
            player.play(localTrack, from: [localTrack])
            XCTAssertEqual(app.homePlaylists.map(\.id), ["2", "0", "1"])
            player.play(localTrack, from: [localTrack], playlistID: "1")
            XCTAssertEqual(app.homePlaylists.map(\.id), ["1", "2", "0"])
            player.pausePlayback()
        }
    }

    private func writeSilentWAV(to url: URL) throws {
        let sampleRate: UInt32 = 8_000
        let samples = Data(count: Int(sampleRate) * 2)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + samples.count))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(sampleRate)
        append(sampleRate * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(samples.count))
        data.append(samples)
        try data.write(to: url)
    }

    func testCachedLibraryPlaybackIsTrackedBeforeSyncStarts() {
        withPreferences { preferences in
            let app = makeApp(preferences)
            let player = player()
            app.configurePlaylistPlaybackTracking(player)
            XCTAssertFalse(player.syncEnabled)
            player.play(track, from: [track], playlistID: "2")
            XCTAssertEqual(app.homePlaylists.map(\.id), ["2", "0", "1"])
            player.pausePlayback()
        }
    }

    func testCollectionPlayAndShuffleRecordButEmptyCollectionDoesNot() {
        let player = player()
        var played: [String] = []
        player.recordPlaylistPlayback = { played.append($0) }
        player.playCollection([track], playlistID: "regular")
        player.playCollection([track], shuffled: true, playlistID: "shuffled")
        player.playCollection([], playlistID: "empty")
        XCTAssertEqual(played, ["regular", "shuffled"])
        player.pausePlayback()
    }

    func testPausingDoesNotRecordButExplicitPlaylistResumeDoes() {
        let player = player()
        var played: [String] = []
        player.recordPlaylistPlayback = { played.append($0) }
        player.play(track, from: [track], playlistID: "playlist")
        player.togglePlayback(playlistID: "playlist")
        XCTAssertEqual(played, ["playlist"])
        player.togglePlayback(playlistID: "playlist")
        XCTAssertEqual(played, ["playlist", "playlist"])
        player.pausePlayback()
        player.togglePlayback()
        XCTAssertEqual(played, ["playlist", "playlist"])
        player.pausePlayback()
    }

    func testExplicitPlaylistOriginSurvivesTransportAndQueueEdits() {
        let player = player()
        defer { player.pausePlayback() }
        let next = CodecTrack(id: "next", title: "Next", artist: "", album: "",
                              audioURL: track.audioURL, fingerprint: "next")
        player.play(track, from: [track, next], playlistID: "original")
        XCTAssertEqual(player.sourcePlaylistID, "original")
        player.playLater(next)
        player.next()
        XCTAssertEqual(player.sourcePlaylistID, "original", "Manual queue playback keeps its parent source")
        player.previous()
        player.previous()
        player.toggleShuffle()
        player.toggleShuffle()
        player.clearQueue()
        player.pausePlayback()
        XCTAssertEqual(player.sourcePlaylistID, "original")
        // A same-song pause/resume from another playlist does not replace
        // the source collection, so it must not relabel its origin either.
        player.togglePlayback(playlistID: "another")
        XCTAssertEqual(player.sourcePlaylistID, "original")
        player.playCollection([track, next], playlistID: "another")
        XCTAssertEqual(player.sourcePlaylistID, "another")
        player.play(next, from: [track, next])
        XCTAssertNil(player.sourcePlaylistID, "A new generic collection must clear the playlist origin")
    }

    func testCachedPlaylistOriginSurvivesStartingSyncWithSameServer() {
        let player = player()
        defer { player.pausePlayback(); player.stopSync() }
        player.play(track, from: [track], playlistID: "cached")
        player.startSync(client: player.client!)
        XCTAssertEqual(player.sourcePlaylistID, "cached")
        player.stopSync()
        XCTAssertNil(player.sourcePlaylistID, "Disconnect must not leak a playlist identity into another library")
    }

    private func remotePlayer() throws -> (PlayerController, RecencyCommandTransport) {
        let reference = CodecTrackReference(track: track)
        let data = try JSONSerialization.data(withJSONObject: [
            "schema": "loud.playback.v2", "revision": 1, "active_device_id": "another-speaker",
            "state": "paused", "track": ["id": reference.id, "path": reference.path, "fingerprint": reference.fingerprint],
            "context": [:], "clock": ["position_seconds": 0, "updated_at_ms": 1000],
            "volume": 1, "server_time_ms": 1000
        ])
        let transport = RecencyCommandTransport(initialState: data)
        let player = player()
        let track = self.track
        player.resolveTrack = { _ in track }
        player.startSync(client: CodecClient(baseURL: URL(string: "https://history-tests.invalid")!, transport: transport))
        player.applySyncState(try JSONDecoder().decode(PlaybackState.self, from: data))
        return (player, transport)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The playback acknowledgement did not arrive")
    }

    func testRemotePlayRecordsOnlyAfterSuccessfulAcknowledgement() async throws {
        let (player, _) = try remotePlayer()
        defer { player.stopSync() }
        var played: [String] = []
        player.recordPlaylistPlayback = { played.append($0) }
        player.play(track, from: [track], playlistID: "accepted")
        XCTAssertTrue(played.isEmpty)
        try await waitUntil { player.syncState?.revision == 2 }
        XCTAssertEqual(played, ["accepted"])
        XCTAssertEqual(player.syncState?.context.playlistID, "accepted")
        XCTAssertEqual(player.sourcePlaylistID, "accepted")
    }

    func testRejectedRemotePlayAndResumeNeverBecomeRecent() async throws {
        let (player, transport) = try remotePlayer()
        defer { player.stopSync() }
        await transport.rejectCommands()
        var rejections = 0
        var played: [String] = []
        player.reportSyncError = { _ in rejections += 1 }
        player.recordPlaylistPlayback = { played.append($0) }
        player.play(track, from: [track], playlistID: "rejected-play")
        XCTAssertTrue(played.isEmpty)
        try await waitUntil { rejections == 1 }
        XCTAssertTrue(played.isEmpty)
        player.togglePlayback(playlistID: "rejected-resume")
        XCTAssertTrue(played.isEmpty)
        try await waitUntil { rejections == 2 }
        XCTAssertTrue(played.isEmpty)
    }

    func testRemotePauseDoesNotRecordAndResumesFollowAcknowledgedOrder() async throws {
        let (player, _) = try remotePlayer()
        defer { player.stopSync() }
        var played: [String] = []
        player.recordPlaylistPlayback = { played.append($0) }
        player.togglePlayback(playlistID: "first")
        XCTAssertTrue(played.isEmpty)
        try await waitUntil { player.syncState?.revision == 2 }
        XCTAssertEqual(played, ["first"])
        player.togglePlayback(playlistID: "pause")
        try await waitUntil { player.syncState?.revision == 3 }
        XCTAssertEqual(played, ["first"])
        player.togglePlayback(playlistID: "second")
        XCTAssertEqual(played, ["first"])
        try await waitUntil { player.syncState?.revision == 4 }
        XCTAssertEqual(played, ["first", "second"])
    }

    func testPlaybackFromPreviousServerCannotReorderCurrentLibrary() {
        withPreferences { preferences in
            let app = makeApp(preferences, server: "https://new-library.invalid")
            app.recordPlaylistPlayback(playlistID: "2", from: URL(string: "https://history-tests.invalid")!)
            XCTAssertEqual(app.homePlaylists.map(\.id), ["0", "1", "2"])
            app.recordPlaylistPlayback(playlistID: "1", from: URL(string: "https://new-library.invalid")!)
            XCTAssertEqual(app.homePlaylists.map(\.id), ["1", "0", "2"])
        }
    }

    func testFailedAudioSessionDoesNotRecordAPlaylistStart() {
        let player = PlayerController(
            makePlayer: { _ in RecencyPlayerSpy() },
            activateAudioSession: { throw NSError(domain: "RecencyTests", code: 1) }
        )
        player.client = CodecClient(baseURL: URL(string: "https://history-tests.invalid")!)
        var played: [String] = []
        player.recordPlaylistPlayback = { played.append($0) }
        player.play(track, from: [track], playlistID: "playlist")
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(played.isEmpty)
    }
}

/// Uses the controller's actual start/resume paths without opening an audio
/// route or requesting network media.
private final class RecencyPlayerSpy: AVPlayer, @unchecked Sendable {
    nonisolated override func play() {}
    nonisolated override func pause() {}
}

/// Delayed responses make premature recency writes observable. All playback
/// HTTP requests stay in this fixture; no real server state is changed.
private actor RecencyCommandTransport: CodecTransport {
    private var state: Data
    private var rejects = false

    init(initialState: Data) { state = initialState }
    func rejectCommands() { rejects = true }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        var status = 200
        let data: Data
        switch request.url?.path {
        case "/api/v2/playback/commands":
            try await Task.sleep(for: .milliseconds(40))
            if rejects {
                status = 409
                data = Data("Playback changed".utf8)
            } else {
                let command = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                var snapshot = try JSONSerialization.jsonObject(with: state) as! [String: Any]
                snapshot["revision"] = (snapshot["revision"] as! Int) + 1
                snapshot["state"] = (command["kind"] as? String) == "pause" ? "paused" : "playing"
                if let track = command["track"] { snapshot["track"] = track }
                if let context = command["context"] { snapshot["context"] = context }
                state = try JSONSerialization.data(withJSONObject: snapshot)
                data = state
            }
        case "/api/v2/playback": data = state
        case "/api/v1/playback/devices": data = Data("[]".utf8)
        default: data = Data("{}".utf8)
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
