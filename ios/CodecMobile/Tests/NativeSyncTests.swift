import Foundation
import XCTest
@testable import Codec

@MainActor
final class NativeSyncTests: XCTestCase {
    private let first = CodecTrack(id: "first", title: "First", artist: "", album: "", fingerprint: "first")
    private let second = CodecTrack(id: "second", title: "Second", artist: "", album: "", fingerprint: "second")
    private let third = CodecTrack(id: "third", title: "Third", artist: "", album: "", fingerprint: "third")

    private func makePlayer(_ server: PlaybackFixture) async -> PlayerController {
        let player = PlayerController(syncPollInterval: .milliseconds(25))
        let tracks = [first, second, third]
        player.resolveTrack = { ref in tracks.first { $0.id == ref.id } }
        player.startSync(client: server.client)
        player.applySyncState(await server.state())
        return player
    }

    private func eventually(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let passed = await condition()
        XCTAssertTrue(passed, "State did not recover before the deadline")
    }

    func testRapidQueueEditsUseAcknowledgedRevisions() async throws {
        let server = PlaybackFixture()
        let player = await makePlayer(server)
        defer { player.stopSync() }

        player.playLater(second)
        player.playLater(third)
        try await eventually { player.syncState?.revision == 3 }

        let requests = await server.commands
        XCTAssertEqual(requests.map(\.expectedRevision), [1, 2])
        XCTAssertEqual(player.manualQueue.map(\.id), ["second", "third"])
        XCTAssertEqual(requests.last?.queue, ["second", "third"])
    }

    func testQueuedContextRetainsPendingShuffleAndRepeatChanges() async throws {
        let server = PlaybackFixture()
        let player = await makePlayer(server)
        defer { player.stopSync() }

        player.toggleShuffle()
        player.cycleRepeat()
        player.playLater(second)
        try await eventually { player.syncState?.revision == 4 }

        XCTAssertTrue(player.shuffle)
        XCTAssertEqual(player.repeatMode, .all)
        XCTAssertEqual(player.manualQueue.map(\.id), ["second"])
        let requests = await server.commands
        XCTAssertEqual(requests.map(\.expectedRevision), [1, nil, 3])
    }

    func testExternalQueueEditBetweenOwnCommandsIsNotOverwritten() async throws {
        let server = PlaybackFixture(interference: .afterFirstCommand)
        let player = await makePlayer(server)
        defer { player.stopSync() }
        var errors: [String] = []
        player.reportSyncError = { errors.append($0) }

        player.playLater(second)
        player.playLater(third)
        try await eventually { !errors.isEmpty && player.manualQueue.map(\.id) == ["third"] }

        let requests = await server.commands
        XCTAssertEqual(requests.map(\.expectedRevision), [1, 2])
        XCTAssertEqual(requests.map(\.status), [200, 409])
        XCTAssertEqual(player.syncState?.revision, 3)
    }

    func testTransportAcknowledgementCannotHideExternalQueueEdit() async throws {
        let server = PlaybackFixture(interference: .beforeFirstCommand)
        let player = await makePlayer(server)
        defer { player.stopSync() }
        var errors: [String] = []
        player.reportSyncError = { errors.append($0) }

        player.sendSyncCommand("pause")
        player.playLater(second)
        try await eventually { !errors.isEmpty && player.manualQueue.map(\.id) == ["third"] }

        let requests = await server.commands
        XCTAssertEqual(requests.count, 1, "The stale context must never be sent after a revision jump")
        XCTAssertEqual(requests.first?.kind, "pause")
    }

    func testFailedCommandDoesNotAuthorizeItsDependentQueueSnapshot() async throws {
        let server = PlaybackFixture(interference: .failFirstCommand)
        let player = await makePlayer(server)
        defer { player.stopSync() }
        var errors: [String] = []
        player.reportSyncError = { errors.append($0) }

        player.playLater(second)
        player.playLater(third)
        try await eventually { !errors.isEmpty && player.manualQueue.isEmpty }
        let requests = await server.commands
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(player.syncState?.revision, 1)
    }

    func testRemoteAdvanceCannotAuthorizeAQueueSnapshotFromBeforeTheAdvance() async throws {
        let server = PlaybackFixture(initialQueue: ["second", "third"])
        let player = await makePlayer(server)
        defer { player.stopSync() }
        var errors: [String] = []
        player.reportSyncError = { errors.append($0) }

        player.next()
        player.playLater(second)
        try await eventually { !errors.isEmpty && player.manualQueue.map(\.id) == ["third"] }
        let requests = await server.commands
        XCTAssertEqual(requests.map(\.kind), ["next"], "The stale context must not undo the server-side advance")
    }

    func testForegroundFailureKeepsSyncAliveAndRecoversAutomatically() async throws {
        let server = PlaybackFixture()
        let app = AppModel(client: server.client, reconnectDelays: [.milliseconds(25)])
        app.startConnectionMonitoring(observeSystemNetwork: false)
        let player = PlayerController(syncPollInterval: .milliseconds(25))
        defer { player.stopSync() }
        player.refreshLibrary = { await app.refresh() }
        await app.refresh()
        app.syncPlayer(player)
        XCTAssertTrue(player.syncEnabled)

        await server.setOffline(true)
        await app.refresh()
        app.syncPlayer(player) // Exactly the foreground lifecycle sequence.
        XCTAssertEqual(app.connection, .offline)
        XCTAssertTrue(player.syncEnabled)

        await server.setOffline(false)
        try await eventually { app.isConnected }
        // Production observes canReachServer and resumes the preserved sync
        // identity only after the authorized library probe succeeds.
        app.syncPlayer(player)
        try await eventually { player.syncState?.revision == 1 }

        app.disconnect()
        app.syncPlayer(player)
        XCTAssertFalse(player.syncEnabled, "Explicit disconnect must still stop all sync loops")
    }

    func testAuxGuestCannotCreatePlaylistThroughAnotherEntryPoint() async throws {
        let server = PlaybackFixture()
        let app = AppModel(client: server.client)
        let previousGuestState = app.activeAuxIsGuest
        defer { app.activeAuxIsGuest = previousGuestState }
        app.activeAuxIsGuest = true

        app.createPlaylist(named: "Guest playlist", adding: first)
        XCTAssertTrue(app.errorMessage.contains("host"))
        // Allow any mistakenly scheduled mutation task to reach the fixture.
        try await Task.sleep(for: .milliseconds(50))
        let attempts = await server.playlistCreates
        XCTAssertEqual(attempts, 0)
    }

    private func makeEfficientPlayer(
        _ server: PlaybackFixture, stream: PlaybackStreamFixture,
        safetyInterval: Duration = .seconds(60), timeout: Duration = .seconds(1)
    ) -> PlayerController {
        let player = PlayerController(
            syncPollInterval: .milliseconds(25),
            syncSafetyRefreshInterval: safetyInterval,
            eventStreamTimeout: timeout,
            eventReconnectInterval: .milliseconds(10),
            consumePlaybackEvents: stream.consume
        )
        player.resolveTrack = { [first] _ in first }
        let app = AppModel(client: server.client)
        player.refreshLibrary = { await app.refresh() }
        player.startSync(client: server.client)
        return player
    }

    func testHealthyStreamKeepsPresenceButSkipsRedundantSnapshots() async throws {
        let server = PlaybackFixture()
        let stream = PlaybackStreamFixture()
        let player = makeEfficientPlayer(server, stream: stream)
        defer { player.stopSync() }
        try await eventually { await server.presenceWrites >= 2 }
        let baseline = await server.readCounts
        let presence = await server.presenceWrites
        try await eventually { await server.presenceWrites >= presence + 5 }

        let reads = await server.readCounts
        XCTAssertEqual(reads, baseline, "Healthy SSE must replace the three reads on each presence tick")
        XCTAssertEqual(stream.connections, 1)
    }

    func testLibraryAndPlaybackEventsRemainImmediateBetweenSafetyPolls() async throws {
        let server = PlaybackFixture()
        let stream = PlaybackStreamFixture()
        let player = makeEfficientPlayer(server, stream: stream)
        defer { player.stopSync() }
        try await eventually { await server.presenceWrites >= 2 }
        let baseline = await server.readCounts

        stream.send("data: {\"type\":\"library\"}")
        try await eventually { await server.readCounts.library == baseline.library + 1 }
        let notModified = await server.libraryNotModifiedResponses
        XCTAssertGreaterThan(notModified, 0, "An unchanged 304 must still finish library validation successfully")
        await server.setRevision(8)
        stream.send("data: \(await server.playbackEvent())")
        XCTAssertEqual(player.syncState?.revision, 8, "Push state must apply immediately without waiting for polling")
        let reads = await server.readCounts
        XCTAssertEqual(reads.playback, baseline.playback)
        XCTAssertEqual(reads.devices, baseline.devices)
    }

    func testHealthyStreamStillPerformsBoundedSafetyRefresh() async throws {
        let server = PlaybackFixture()
        let stream = PlaybackStreamFixture()
        let player = makeEfficientPlayer(server, stream: stream, safetyInterval: .milliseconds(120))
        defer { player.stopSync() }
        try await eventually { await server.readCounts.playback >= 1 }
        let baseline = await server.readCounts
        try await eventually {
            let reads = await server.readCounts
            return reads.playback > baseline.playback && reads.library > baseline.library && reads.devices > baseline.devices
        }
        let reads = await server.readCounts
        XCTAssertGreaterThan(reads.library, baseline.library)
        XCTAssertGreaterThan(reads.devices, baseline.devices)
        XCTAssertEqual(stream.connections, 1)
    }

    func testDroppedStreamReconnectsAndFetchesChangesMissedWhileOffline() async throws {
        let server = PlaybackFixture()
        let stream = PlaybackStreamFixture()
        let player = makeEfficientPlayer(server, stream: stream)
        defer { player.stopSync() }
        try await eventually { await server.presenceWrites >= 2 }
        let baseline = await server.readCounts
        await server.setRevision(9)
        stream.initialLines = ["data: \(await server.playbackEvent())"]
        stream.disconnect()

        try await eventually { stream.connections >= 2 && player.syncState?.revision == 9 }
        try await eventually { await server.readCounts.library > baseline.library }
    }

    func testSilentHalfOpenStreamResumesFallbackAndRestartsConnection() async throws {
        let server = PlaybackFixture()
        let stream = PlaybackStreamFixture()
        stream.sendsHeartbeats = false
        let player = makeEfficientPlayer(server, stream: stream, timeout: .milliseconds(80))
        defer { player.stopSync() }
        try await eventually { await server.readCounts.playback >= 1 }
        let baseline = await server.readCounts
        await server.setRevision(10)

        try await eventually { stream.connections >= 2 && player.syncState?.revision == 10 }
        try await eventually { await server.readCounts.library > baseline.library }
        let reads = await server.readCounts
        XCTAssertGreaterThan(reads.library, baseline.library)
        XCTAssertGreaterThan(reads.playback, baseline.playback)
        XCTAssertGreaterThan(reads.devices, baseline.devices)
    }

    func testConnectionThatNeverReceivesHeadersIsAlsoRestarted() async throws {
        let server = PlaybackFixture()
        let stream = PlaybackStreamFixture()
        stream.sendsConnected = false
        stream.sendsHeartbeats = false
        let player = makeEfficientPlayer(server, stream: stream, timeout: .milliseconds(80))
        defer { player.stopSync() }

        try await eventually { stream.connections >= 2 }
        let reads = await server.readCounts
        XCTAssertGreaterThan(reads.playback, 1, "An unavailable stream must retain 30s fallback cadence")
    }

    func testForegroundReconcileStillFetchesImmediatelyWithHealthyStream() async throws {
        let server = PlaybackFixture()
        let stream = PlaybackStreamFixture()
        let player = makeEfficientPlayer(server, stream: stream)
        defer { player.stopSync() }
        try await eventually { await server.presenceWrites >= 2 }
        let baseline = await server.readCounts
        await server.setRevision(11)

        await player.reconcilePlayback()
        XCTAssertEqual(player.syncState?.revision, 11)
        let reads = await server.readCounts
        XCTAssertEqual(reads.playback, baseline.playback + 1)
        XCTAssertEqual(reads.devices, baseline.devices + 1)
    }

    func testFailedSafetyReadsRetryNextPresenceTickDespiteHealthyStream() async throws {
        // Exercise both halves of validation through the real AppModel and
        // client cache: REST can fail independently of a healthy SSE socket.
        for failedPath in ["/api/v2/playback", "/api/v1/library"] {
            let server = PlaybackFixture()
            let stream = PlaybackStreamFixture()
            let player = makeEfficientPlayer(server, stream: stream, safetyInterval: .seconds(1))
            defer { player.stopSync() }
            try await eventually { await server.presenceWrites >= 2 }
            let initialAttempts = await server.attempts(for: failedPath)
            await server.setFailure(for: failedPath, enabled: true)
            try await eventually { await server.attempts(for: failedPath) > initialAttempts }
            let failedAttempts = await server.attempts(for: failedPath)
            await server.setFailure(for: failedPath, enabled: false)
            let presence = await server.presenceWrites
            try await eventually { await server.presenceWrites >= presence + 3 }

            let recoveredAttempts = await server.attempts(for: failedPath)
            XCTAssertGreaterThan(recoveredAttempts, failedAttempts,
                "\(failedPath) must retry on the next 30s presence tick, not wait another five minutes")
            XCTAssertEqual(stream.connections, 1)
            let recoveredReads = await server.readCounts
            let recoveredPresence = await server.presenceWrites
            try await eventually { await server.presenceWrites >= recoveredPresence + 3 }
            let stableReads = await server.readCounts
            XCTAssertEqual(stableReads, recoveredReads,
                "Successful recovery, including a library 304, must restore the efficient cadence")
        }
    }

    func testFailedLibraryEventRefreshRetriesWithoutWaitingForSafetyInterval() async throws {
        let server = PlaybackFixture()
        let stream = PlaybackStreamFixture()
        let player = makeEfficientPlayer(server, stream: stream)
        defer { player.stopSync() }
        try await eventually { await server.presenceWrites >= 2 }
        let baseline = await server.attempts(for: "/api/v1/library")
        await server.setFailure(for: "/api/v1/library", enabled: true)
        stream.send("data: {\"type\":\"library\"}")
        try await eventually { await server.attempts(for: "/api/v1/library") > baseline }
        let failedAttempts = await server.attempts(for: "/api/v1/library")
        await server.setFailure(for: "/api/v1/library", enabled: false)
        let presence = await server.presenceWrites
        try await eventually { await server.presenceWrites >= presence + 3 }

        let recoveredAttempts = await server.attempts(for: "/api/v1/library")
        XCTAssertGreaterThan(recoveredAttempts, failedAttempts)
        XCTAssertEqual(stream.connections, 1)
    }
}

/// Drives the same callbacks as URLSession's SSE reader, including stream
/// completion and connections that remain open but stop delivering bytes.
@MainActor
private final class PlaybackStreamFixture {
    private(set) var connections = 0
    var sendsConnected = true
    var sendsHeartbeats = true
    var initialLines: [String] = []
    private var receiver: (@MainActor (PlaybackStreamEvent) -> Void)?
    private var disconnectedConnection = 0

    func consume(_ request: URLRequest, receive: @escaping @MainActor (PlaybackStreamEvent) -> Void) async throws {
        connections += 1
        let connection = connections
        receiver = receive
        defer { if connection == connections { receiver = nil } }
        if sendsConnected { receive(.connected) }
        for line in initialLines { receive(.line(line)) }
        while !Task.isCancelled, disconnectedConnection != connection {
            if sendsHeartbeats { receive(.line(": heartbeat")) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func send(_ line: String) { receiver?(.line(line)) }
    func disconnect() { disconnectedConnection = connections }
}

/// An isolated in-memory server with the real revision/If-Match semantics.
/// It never reads user credentials or contacts a running sync server.
private actor PlaybackFixture: CodecTransport {
    enum Interference: Sendable {
        case none, afterFirstCommand, beforeFirstCommand, failFirstCommand
    }
    struct Command: Sendable {
        let kind: String
        let expectedRevision: Int64?
        let queue: [String]
        let status: Int
    }
    private let interference: Interference
    private var revision: Int64 = 1
    private var queue: [String] = []
    private var shuffle = false
    private var repeatMode = "off"
    private var offline = false
    private var failedPaths: Set<String> = []
    private var requestAttempts: [String: Int] = [:]
    private(set) var commands: [Command] = []
    private(set) var playlistCreates = 0
    struct ReadCounts: Equatable {
        var library = 0
        var playback = 0
        var devices = 0
    }
    private(set) var readCounts = ReadCounts()
    private(set) var presenceWrites = 0
    private(set) var libraryNotModifiedResponses = 0
    nonisolated var client: CodecClient {
        CodecClient(baseURL: URL(string: "https://native-tests.invalid")!, transport: self)
    }

    init(interference: Interference = .none, initialQueue: [String] = []) {
        self.interference = interference
        queue = initialQueue
    }
    func setOffline(_ value: Bool) { offline = value }
    func setRevision(_ value: Int64) { revision = value }
    func setFailure(for path: String, enabled: Bool) {
        if enabled { failedPaths.insert(path) } else { failedPaths.remove(path) }
    }
    func attempts(for path: String) -> Int { requestAttempts[path, default: 0] }

    func playbackEvent() -> String {
        "{\"type\":\"playback_state\",\"playback_state\":\(String(decoding: try! stateData(), as: UTF8.self))}"
    }

    private func stateData() throws -> Data {
        func reference(_ id: String) -> [String: String] {
            ["id": id, "path": "loud://track/\(id)", "fingerprint": id]
        }
        return try JSONSerialization.data(withJSONObject: [
            "schema": "loud.playback.v2", "revision": revision, "state": "paused",
            "active_device_id": "another-device", "track": reference("first"),
            "context": ["playback_source": [reference("first")], "playback_index": 0,
                        "queued_tracks": queue.map(reference), "play_history": [], "shuffle": shuffle, "repeat": repeatMode],
            "clock": ["position_seconds": 0, "updated_at_ms": 1], "volume": 1, "server_time_ms": 1
        ])
    }

    func state() -> PlaybackState {
        try! JSONDecoder().decode(PlaybackState.self, from: stateData())
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url!.path
        requestAttempts[path, default: 0] += 1
        if offline || failedPaths.contains(path) { throw URLError(.notConnectedToInternet) }
        var status = 200
        var data = Data()
        var headers: [String: String] = [:]
        if path == "/api/v2/playback/commands" {
            // Suspend the first request so the next UI action is queued while
            // its predecessor is still in flight, as on a real mobile link.
            try await Task.sleep(for: .milliseconds(50))
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let kind = body["kind"] as! String
            let context = body["context"] as? [String: Any]
            let requestedQueue = (context?["queued_tracks"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
            let expected = request.value(forHTTPHeaderField: "If-Match").flatMap { Int64($0.replacingOccurrences(of: "\"", with: "")) }
            if commands.isEmpty, interference == .beforeFirstCommand {
                revision += 1
                queue = ["third"]
            }
            if commands.isEmpty, interference == .failFirstCommand {
                status = 503
            } else if let expected, expected != revision {
                status = 409
            } else {
                if context != nil { queue = requestedQueue }
                if let value = context?["shuffle"] as? Bool { shuffle = value }
                if let value = context?["repeat"] as? String { repeatMode = value }
                if kind == "set_repeat", let value = body["repeat"] as? String { repeatMode = value }
                if kind == "next", !queue.isEmpty { queue.removeFirst() }
                revision += 1
                data = try stateData()
            }
            commands.append(Command(kind: kind, expectedRevision: expected, queue: requestedQueue, status: status))
            if commands.count == 1, interference == .afterFirstCommand {
                revision += 1
                queue = ["third"]
            }
        } else if path == "/api/v2/playback" {
            readCounts.playback += 1
            data = try stateData()
        } else if path == "/api/v1/playback/devices" {
            readCounts.devices += 1
            data = Data("[]".utf8)
        } else if path.hasPrefix("/api/v1/playback/devices/"), request.httpMethod == "PUT" {
            presenceWrites += 1
        } else if path == "/api/v1/library" {
            readCounts.library += 1
            headers["ETag"] = "\"fixture-library\""
            if request.value(forHTTPHeaderField: "If-None-Match") == headers["ETag"] {
                status = 304
                libraryNotModifiedResponses += 1
            } else {
                data = Data(#"{"tracks":[],"playlists":[]}"#.utf8)
            }
        } else if path == "/api/v1/playlists", request.httpMethod == "POST" {
            playlistCreates += 1
            data = Data(#"{"id":"new","name":"Guest playlist","track_ids":[]}"#.utf8)
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}
