import AVFoundation
import Foundation
import XCTest
@testable import Codec

/// Exercise the real controller and sync decisions without opening an audio
/// route, streaming media, or depending on a physical notification arriving.
@MainActor
final class PlaybackContinuityTests: XCTestCase {
    private let first = CodecTrack(
        id: "continuity-first", title: "First", artist: "", album: "",
        durationSeconds: 180, artworkURL: URL(fileURLWithPath: "/dev/null"),
        audioURL: URL(fileURLWithPath: "/dev/null"), fingerprint: "continuity-first"
    )
    private let second = CodecTrack(
        id: "continuity-second", title: "Second", artist: "", album: "",
        durationSeconds: 180, artworkURL: URL(fileURLWithPath: "/dev/null"),
        audioURL: URL(fileURLWithPath: "/dev/null"), fingerprint: "continuity-second"
    )

    private func makeController() -> (PlayerController, ContinuityProbe, ContinuityTransport) {
        let probe = ContinuityProbe()
        let transport = ContinuityTransport()
        let player = PlayerController(
            syncPollInterval: .seconds(3600),
            makePlayer: { _ in
                let spy = ContinuityPlayerSpy()
                probe.players.append(spy)
                return spy
            },
            activateAudioSession: {
                probe.activations += 1
                if probe.activationShouldFail {
                    throw NSError(domain: "PlaybackContinuityTests.AudioSession", code: 1)
                }
            }
        )
        let tracks = [first, second]
        player.resolveTrack = { reference in tracks.first { $0.fingerprint == reference.fingerprint } }
        player.startSync(client: CodecClient(
            baseURL: URL(string: "https://continuity-tests.invalid")!, transport: transport
        ))
        return (player, probe, transport)
    }

    private func snapshot(
        for player: PlayerController,
        revision: Int = 1,
        playing: Bool = true,
        activeDevice: String? = nil,
        position: Double = 10,
        serverTime: Int64 = 1000,
        repeatMode: String = "off",
        queued: [CodecTrack] = [],
        playlistID: String? = nil
    ) throws -> PlaybackState {
        func reference(_ track: CodecTrack) -> [String: String] {
            ["id": track.id, "fingerprint": track.fingerprint, "path": "loud://track/\(track.fingerprint)"]
        }
        var clock: [String: Any] = ["position_seconds": position, "updated_at_ms": serverTime]
        if playing { clock["started_at_ms"] = serverTime }
        else { clock["stopped_at_ms"] = serverTime }
        let data = try JSONSerialization.data(withJSONObject: [
            "schema": "loud.playback.v2", "revision": revision,
            "active_device_id": activeDevice ?? player.deviceID,
            "state": playing ? "playing" : "paused", "track": reference(first),
            "context": [
                "playback_source": [reference(first), reference(second)], "playback_index": 0,
                "queued_tracks": queued.map(reference), "play_history": [],
                "shuffle": false, "repeat": repeatMode,
                "playlist_id": playlistID as Any? ?? NSNull()
            ],
            "clock": clock, "volume": 1, "server_time_ms": serverTime
        ])
        return try JSONDecoder().decode(PlaybackState.self, from: data)
    }

    private func beginInterruption(_ player: PlayerController) {
        player.handleInterruption(typeValue: AVAudioSession.InterruptionType.began.rawValue, optionsValue: nil)
    }

    func testPlaylistOriginSyncChangesDoNotReloadSeekOrRestartAudio() throws {
        let (player, probe, _) = makeController()
        defer { player.pausePlayback(); player.stopSync() }
        player.applySyncState(try snapshot(for: player, playlistID: "first-playlist"))
        let engine = try XCTUnwrap(probe.players.first)
        let playCalls = engine.playCalls
        let pauseCalls = engine.pauseCalls
        let seeks = engine.seeks
        player.applySyncState(try snapshot(for: player, revision: 2, playlistID: "renamed-source"))
        XCTAssertEqual(player.sourcePlaylistID, "renamed-source")
        XCTAssertEqual(probe.players.count, 1)
        XCTAssertEqual(engine.playCalls, playCalls)
        XCTAssertEqual(engine.pauseCalls, pauseCalls)
        XCTAssertEqual(engine.seeks, seeks)
        // An authoritative context from an older client has no origin.
        player.applySyncState(try snapshot(for: player, revision: 3))
        XCTAssertNil(player.sourcePlaylistID)
        XCTAssertEqual(engine.playCalls, playCalls)
        XCTAssertEqual(engine.seeks, seeks)
    }

    func testPlaylistOriginFollowsPlaybackHandoff() throws {
        let (player, _, _) = makeController()
        defer { player.pausePlayback(); player.stopSync() }
        player.applySyncState(try snapshot(for: player, playlistID: "handoff-playlist"))
        player.applySyncState(try snapshot(for: player, revision: 2, activeDevice: "web-speaker", playlistID: "handoff-playlist"))
        XCTAssertEqual(player.sourcePlaylistID, "handoff-playlist")
        player.applySyncState(try snapshot(for: player, revision: 3, playing: false, playlistID: "handoff-playlist"))
        XCTAssertEqual(player.sourcePlaylistID, "handoff-playlist")
        XCTAssertFalse(player.isPlaying)
    }

    private func endInterruption(_ player: PlayerController, shouldResume: Bool = true) {
        player.handleInterruption(
            typeValue: AVAudioSession.InterruptionType.ended.rawValue,
            optionsValue: shouldResume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0
        )
    }

    private func eventually(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = await condition()
        XCTAssertTrue(result, "Playback ownership did not settle before the deadline")
    }

    private func assertStaleAutomaticWritePreservesWebOwner(
        kind: String, action: @MainActor (PlayerController) -> Void
    ) async throws {
        let (player, _, transport) = makeController()
        defer { player.stopSync() }
        // Web's transfer has reached the server, but not the phone's SSE
        // connection. This is the race between automatic iOS transport and
        // ownership changes, not a simulated explicit remote-control tap.
        try await transport.emulateOwnershipServer(
            state: snapshot(for: player, revision: 2, activeDevice: "web-speaker")
        )
        player.applySyncState(try snapshot(for: player, revision: 1))
        action(player)
        try await eventually { await transport.ownershipCommands.count == 1 }
        try await eventually { player.syncState?.revision == 2 }

        let commands = await transport.ownershipCommands
        XCTAssertEqual(commands.first?.kind, kind)
        XCTAssertEqual(commands.first?.expectedRevision, 1)
        XCTAssertEqual(commands.first?.status, 409)
        let state = try await transport.ownershipState()
        XCTAssertEqual(state.activeDeviceID, "web-speaker")
        XCTAssertEqual(state.revision, 2)
        XCTAssertTrue(state.isPlaying, "An automatic phone event must not pause the active browser")
        XCTAssertEqual(player.syncState?.activeDeviceID, "web-speaker")
    }

    func testInterruptionResumeCannotTakePlaybackBackFromNewWebOwner() async throws {
        try await assertStaleAutomaticWritePreservesWebOwner(kind: "play") { player in
            beginInterruption(player)
            endInterruption(player)
        }
    }

    func testInterruptionPauseCannotStopNewWebOwner() async throws {
        try await assertStaleAutomaticWritePreservesWebOwner(kind: "pause") { player in
            beginInterruption(player)
            endInterruption(player, shouldResume: false)
        }
    }

    func testRouteLossPauseCannotStopNewWebOwner() async throws {
        try await assertStaleAutomaticWritePreservesWebOwner(kind: "pause") { player in
            player.handleRouteChange(reasonValue: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue)
        }
    }

    func testQueuedSystemPauseCannotUndoAnEarlierIntentionalTransfer() async throws {
        let (player, _, transport) = makeController()
        defer { player.stopSync() }
        let initial = try snapshot(for: player, revision: 1)
        try await transport.emulateOwnershipServer(state: initial, responseDelay: .milliseconds(40))
        player.applySyncState(initial)
        player.transferPlayback(to: "web-speaker")
        player.handleRouteChange(reasonValue: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue)
        try await eventually { player.syncState?.revision == 2 }
        let commands = await transport.ownershipCommands
        XCTAssertEqual(commands.map(\.kind), ["transfer"], "The queued local pause must be discarded before sending")
        let state = try await transport.ownershipState()
        XCTAssertEqual(state.activeDeviceID, "web-speaker")
        XCTAssertTrue(state.isPlaying)
    }

    func testExplicitRemotePauseAndIntentionalTransferRemainAvailable() async throws {
        let (player, _, transport) = makeController()
        defer { player.stopSync() }
        try await transport.emulateOwnershipServer(
            state: snapshot(for: player, revision: 2, activeDevice: "web-speaker")
        )
        player.applySyncState(try snapshot(for: player, revision: 1, activeDevice: "web-speaker"))
        player.togglePlayback()
        try await eventually { player.syncState?.revision == 3 }
        var state = try await transport.ownershipState()
        XCTAssertEqual(state.activeDeviceID, "web-speaker")
        XCTAssertFalse(state.isPlaying)

        player.transferPlayback(to: player.deviceID)
        try await eventually { player.syncState?.revision == 4 }
        state = try await transport.ownershipState()
        XCTAssertEqual(state.activeDeviceID, player.deviceID)
        let commands = await transport.ownershipCommands
        XCTAssertEqual(commands.map(\.kind), ["pause", "transfer"])
        XCTAssertEqual(commands.map(\.expectedRevision), [nil, nil], "Explicit remote control and transfer retain their intended behavior")
        XCTAssertTrue(commands.allSatisfy { $0.status == 200 })
    }

    func testQueueSnapshotPreservesPlayingAudioDespiteClockDrift() throws {
        let (player, probe, _) = makeController()
        defer { player.stopSync() }
        player.applySyncState(try snapshot(for: player))
        let engine = try XCTUnwrap(probe.players.last)
        // The audio engine is authoritative while this device is the speaker.
        // A stale/lagging server clock must not rewind it for a queue edit.
        engine.seconds = 43
        let seeks = engine.seeks.count
        let plays = engine.playCalls
        let activations = probe.activations

        player.applySyncState(try snapshot(
            for: player, revision: 2, position: 12, serverTime: 3000, queued: [second]
        ))

        XCTAssertEqual(player.manualQueue.map(\.id), [second.id])
        XCTAssertEqual(engine.seeks.count, seeks, "A clock rebase for a queue change is not a seek")
        XCTAssertEqual(engine.playCalls, plays)
        XCTAssertEqual(probe.activations, activations)
        XCTAssertEqual(engine.seconds, 43)
        XCTAssertTrue(player.isPlaying)
    }

    func testForcedUnchangedSnapshotDoesNotRestartOrSeekAudio() throws {
        let (player, probe, _) = makeController()
        defer { player.stopSync() }
        let state = try snapshot(for: player)
        player.applySyncState(state)
        let engine = try XCTUnwrap(probe.players.last)
        engine.seconds = 32
        let seeks = engine.seeks.count
        let plays = engine.playCalls
        let activations = probe.activations

        player.applySyncState(state, force: true)

        XCTAssertEqual(engine.seeks.count, seeks)
        XCTAssertEqual(engine.playCalls, plays)
        XCTAssertEqual(probe.activations, activations)
        XCTAssertEqual(probe.players.count, 1)
    }

    func testRealRemoteSeekStillMovesTheLocalPlayhead() throws {
        let (player, probe, _) = makeController()
        defer { player.stopSync() }
        player.applySyncState(try snapshot(for: player))
        let engine = try XCTUnwrap(probe.players.last)
        let seeks = engine.seeks.count

        player.applySyncState(try snapshot(for: player, revision: 2, position: 70, serverTime: 3000))

        XCTAssertEqual(engine.seeks.count, seeks + 1)
        XCTAssertEqual(try XCTUnwrap(engine.seeks.last), 70, accuracy: 0.15)
        XCTAssertTrue(player.isPlaying)
    }

    func testDelayedOwnPlayAcknowledgementCannotRewindOptimisticAudio() async throws {
        let (player, probe, transport) = makeController()
        defer { player.stopSync() }
        player.applySyncState(try snapshot(for: player))
        let acknowledgement = try snapshot(for: player, revision: 2, position: 0, serverTime: 2000)
        await transport.respondToNextCommand(with: try JSONEncoder().encode(acknowledgement))

        player.play(first, from: [first, second])
        let engine = try XCTUnwrap(probe.players.last)
        // Audio has already progressed while the command crosses a slow link.
        engine.seconds = 4
        let seeks = engine.seeks.count
        let plays = engine.playCalls
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while player.syncState?.revision != 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(player.syncState?.revision, 2, "The test must inspect the acknowledged state")
        XCTAssertEqual(engine.seeks.count, seeks)
        XCTAssertEqual(engine.playCalls, plays)
        XCTAssertEqual(engine.seconds, 4)
    }

    func testFailedQueueEditAfterSuccessfulPlayCannotRewindAcknowledgedAudio() async throws {
        let (player, probe, transport) = makeController()
        defer { player.stopSync() }
        player.applySyncState(try snapshot(for: player))
        let acknowledgement = try snapshot(for: player, revision: 2, position: 0, serverTime: 2000)
        await transport.respondThenFailNextCommand(with: try JSONEncoder().encode(acknowledgement))
        player.play(first, from: [first, second])
        let engine = try XCTUnwrap(probe.players.last)
        engine.seconds = 4
        let seeks = engine.seeks.count
        player.playLater(second)

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while player.syncState?.revision != 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        let failedCommands = await transport.failedCommands
        XCTAssertEqual(failedCommands, 1, "The queue edit must actually fail before reconciliation")
        XCTAssertEqual(player.syncState?.revision, 2)
        XCTAssertEqual(engine.seeks.count, seeks)
        XCTAssertEqual(engine.seconds, 4)
        XCTAssertTrue(player.isPlaying)
    }

    func testRemoteSeekBetweenOwnAcknowledgementsStillReachesTheEngine() async throws {
        let (player, probe, transport) = makeController()
        defer { player.stopSync() }
        player.applySyncState(try snapshot(for: player))
        let ownPlay = try snapshot(for: player, revision: 2, position: 0, serverTime: 2000)
        // Revision 3 was an external seek. Our repeat change returns revision
        // 4 with that new clock, so it must not inherit optimistic protection.
        let afterRemoteSeek = try snapshot(
            for: player, revision: 4, position: 70, serverTime: 4000, repeatMode: "all"
        )
        await transport.respondToCommands(with: try [ownPlay, afterRemoteSeek].map { try JSONEncoder().encode($0) })
        player.play(first, from: [first, second])
        let engine = try XCTUnwrap(probe.players.last)
        engine.seconds = 4
        let seeks = engine.seeks.count
        player.cycleRepeat()

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while player.syncState?.revision != 4, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(player.syncState?.revision, 4)
        XCTAssertEqual(player.repeatMode, .all)
        XCTAssertEqual(engine.seeks.count, seeks + 1)
        XCTAssertEqual(engine.seconds, 70, accuracy: 0.15)
    }

    func testInterruptionCannotResumeAnAlreadyPausedTrack() throws {
        let (player, probe, _) = makeController()
        defer { player.stopSync() }
        player.applySyncState(try snapshot(for: player, playing: false))
        let engine = try XCTUnwrap(probe.players.last)
        let plays = engine.playCalls
        let activations = probe.activations

        beginInterruption(player)
        endInterruption(player)

        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(engine.playCalls, plays)
        XCTAssertEqual(probe.activations, activations)
    }

    func testManualPlayRetriesActivationWithoutWaitingForInterruptionEnd() throws {
        let (player, probe, _) = makeController()
        defer { player.stopSync() }
        player.applySyncState(try snapshot(for: player))
        let engine = try XCTUnwrap(probe.players.last)
        beginInterruption(player)
        let plays = engine.playCalls
        let activations = probe.activations
        probe.activationShouldFail = true

        player.togglePlayback()

        XCTAssertEqual(probe.activations, activations + 1)
        XCTAssertFalse(player.isPlaying, "Failed activation must leave the interrupted player silent")
        XCTAssertEqual(engine.playCalls, plays)
        XCTAssertEqual(engine.timeControlStatus, .paused)

        // Some interruptions never send .ended. Once the session can be
        // activated again, an explicit Play must work without that event.
        probe.activationShouldFail = false
        player.togglePlayback()

        XCTAssertEqual(probe.activations, activations + 2)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(engine.playCalls, plays + 1)
        XCTAssertEqual(engine.timeControlStatus, .playing)
    }

    func testInterruptionCannotResumeAudioOwnedByAnotherDevice() throws {
        let (player, probe, _) = makeController()
        defer { player.stopSync() }
        player.applySyncState(try snapshot(for: player))
        player.applySyncState(try snapshot(for: player, revision: 2, activeDevice: "other-device"))
        let engine = try XCTUnwrap(probe.players.last)
        let plays = engine.playCalls
        let activations = probe.activations

        beginInterruption(player)
        endInterruption(player)

        XCTAssertTrue(player.remoteDeviceIsActive)
        XCTAssertEqual(engine.timeControlStatus, .paused)
        XCTAssertEqual(engine.playCalls, plays)
        XCTAssertEqual(probe.activations, activations)
    }

    func testTransferBackToPhoneResumesTheRetainedPlayer() throws {
        let (player, probe, _) = makeController()
        defer { player.stopSync() }
        player.applySyncState(try snapshot(for: player))
        let engine = try XCTUnwrap(probe.players.last)
        player.applySyncState(try snapshot(for: player, revision: 2, activeDevice: "other-device"))
        XCTAssertEqual(engine.timeControlStatus, .paused)
        let plays = engine.playCalls

        player.applySyncState(try snapshot(for: player, revision: 3, position: 12, serverTime: 3000))

        XCTAssertEqual(probe.players.count, 1, "The same loaded track can reuse its player")
        XCTAssertEqual(engine.playCalls, plays + 1)
        XCTAssertEqual(engine.timeControlStatus, .playing)
        XCTAssertFalse(player.remoteDeviceIsActive)
        XCTAssertTrue(player.isPlaying)
    }

    func testTransferToPhoneDuringInterruptionLoadsTheTrackWhenInterruptionEnds() throws {
        let (player, probe, _) = makeController()
        defer { player.stopSync() }
        player.applySyncState(try snapshot(for: player, activeDevice: "other-device"))
        XCTAssertTrue(probe.players.isEmpty, "Remote playback must not instantiate a local audio engine")
        beginInterruption(player)
        player.applySyncState(try snapshot(for: player, revision: 2, position: 65, serverTime: 3000))
        XCTAssertTrue(probe.players.isEmpty, "The transferred track waits for the local interruption to end")
        XCTAssertFalse(player.isPlaying)

        endInterruption(player)

        let engine = try XCTUnwrap(probe.players.last)
        XCTAssertEqual(probe.players.count, 1)
        XCTAssertEqual(engine.seconds, 65, accuracy: 0.15)
        XCTAssertEqual(engine.playCalls, 1)
        XCTAssertEqual(engine.timeControlStatus, .playing)
        XCTAssertFalse(player.remoteDeviceIsActive)
        XCTAssertTrue(player.isPlaying)
    }

    func testSyncRefreshDuringInterruptionCannotSeekOrRestartThePlayer() throws {
        let (player, probe, _) = makeController()
        defer { player.stopSync() }
        player.applySyncState(try snapshot(for: player))
        let engine = try XCTUnwrap(probe.players.last)
        beginInterruption(player)
        let plays = engine.playCalls
        let seeks = engine.seeks.count
        let activations = probe.activations

        player.applySyncState(try snapshot(for: player, revision: 2, position: 70, serverTime: 3000))

        XCTAssertEqual(engine.playCalls, plays)
        XCTAssertEqual(engine.seeks.count, seeks)
        XCTAssertEqual(probe.activations, activations)
        XCTAssertEqual(engine.timeControlStatus, .paused)
    }

    func testDeliveredInterruptionBlocksTheNextSyncSnapshotImmediately() throws {
        let (player, probe, _) = makeController()
        defer { player.stopSync() }
        player.applySyncState(try snapshot(for: player))
        let engine = try XCTUnwrap(probe.players.last)
        let seeks = engine.seeks.count
        let plays = engine.playCalls

        // iOS delivers this observer on the main queue. Another main-actor
        // task (an SSE snapshot, for example) can run before a separately
        // scheduled Task handles the notification, despite arriving later.
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        player.applySyncState(try snapshot(for: player, revision: 2, position: 70, serverTime: 3000))

        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(engine.timeControlStatus, .paused)
        XCTAssertEqual(engine.seeks.count, seeks, "An already-delivered interruption must block an immediate sync seek")
        XCTAssertEqual(engine.playCalls, plays)
    }

    func testRemotePauseThenPlayDuringInterruptionUsesLatestIntent() throws {
        let (player, probe, _) = makeController()
        defer { player.stopSync() }
        player.applySyncState(try snapshot(for: player))
        let engine = try XCTUnwrap(probe.players.last)
        beginInterruption(player)
        let plays = engine.playCalls
        player.applySyncState(try snapshot(for: player, revision: 2, playing: false, serverTime: 2000))
        player.applySyncState(try snapshot(for: player, revision: 3, position: 55, serverTime: 3000))
        XCTAssertEqual(engine.playCalls, plays, "Remote play must wait until the interruption ends")

        endInterruption(player)

        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(engine.playCalls, plays + 1)
        XCTAssertEqual(engine.seconds, 55, accuracy: 0.15)
    }

    func testPlayingInterruptionResumesLocallyWithoutSeekingOrWaitingForServer() throws {
        let (player, probe, _) = makeController()
        defer { player.stopSync() }
        player.applySyncState(try snapshot(for: player))
        let engine = try XCTUnwrap(probe.players.last)
        engine.seconds = 25
        beginInterruption(player)
        let seeks = engine.seeks.count
        let plays = engine.playCalls

        endInterruption(player)

        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(engine.timeControlStatus, .playing)
        XCTAssertEqual(engine.playCalls, plays + 1)
        XCTAssertEqual(engine.seeks.count, seeks)
        XCTAssertEqual(engine.seconds, 25)
    }

    func testInterruptionWithoutResumeRecommendationStaysPaused() throws {
        let (player, probe, _) = makeController()
        defer { player.stopSync() }
        player.applySyncState(try snapshot(for: player))
        let engine = try XCTUnwrap(probe.players.last)
        beginInterruption(player)
        let plays = engine.playCalls

        endInterruption(player, shouldResume: false)

        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(engine.timeControlStatus, .paused)
        XCTAssertEqual(engine.playCalls, plays)
    }

    func testRouteDisconnectCancelsInterruptionResumeIntent() throws {
        let (player, probe, _) = makeController()
        defer { player.stopSync() }
        player.applySyncState(try snapshot(for: player))
        let engine = try XCTUnwrap(probe.players.last)
        beginInterruption(player)
        player.handleRouteChange(reasonValue: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue)
        let plays = engine.playCalls

        endInterruption(player)

        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(engine.playCalls, plays)
    }

    func testExplicitPauseDuringInterruptionCancelsAutomaticResume() throws {
        let (player, probe, _) = makeController()
        defer { player.stopSync() }
        player.applySyncState(try snapshot(for: player))
        let engine = try XCTUnwrap(probe.players.last)
        beginInterruption(player)
        player.pausePlayback()
        let plays = engine.playCalls

        endInterruption(player)

        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(engine.timeControlStatus, .paused)
        XCTAssertEqual(engine.playCalls, plays)
    }

    func testWakeAndRouteConfigurationChangesKeepPlaying() throws {
        let (player, probe, _) = makeController()
        defer { player.stopSync() }
        player.applySyncState(try snapshot(for: player))
        let engine = try XCTUnwrap(probe.players.last)
        let pauses = engine.pauseCalls
        let plays = engine.playCalls
        let activations = probe.activations

        for reason in [AVAudioSession.RouteChangeReason.wakeFromSleep, .routeConfigurationChange, .categoryChange] {
            player.handleRouteChange(reasonValue: reason.rawValue)
        }

        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(engine.pauseCalls, pauses)
        XCTAssertEqual(engine.playCalls, plays)
        XCTAssertEqual(probe.activations, activations)
    }

    func testCallbackFromReplacedPlayerCannotPauseOrRewindNewTrack() throws {
        let (player, probe, _) = makeController()
        defer { player.stopSync() }
        player.applySyncState(try snapshot(for: player))
        let previousEngine = try XCTUnwrap(probe.players.last)
        player.next()
        let currentEngine = try XCTUnwrap(probe.players.last)
        XCTAssertFalse(previousEngine === currentEngine)
        let currentTime = player.currentTime
        let pauses = currentEngine.pauseCalls

        player.handlePlaybackTick(CMTime(seconds: 120, preferredTimescale: 600), from: previousEngine)

        XCTAssertEqual(player.currentTrack?.id, second.id)
        XCTAssertEqual(player.currentTime, currentTime)
        XCTAssertEqual(currentEngine.pauseCalls, pauses)
        XCTAssertTrue(player.isPlaying)
    }

    func testAutomaticNextStartsLocallyBeforeServerAcknowledgement() throws {
        let (player, probe, _) = makeController()
        defer { player.stopSync() }
        player.applySyncState(try snapshot(for: player))

        player.handleTrackEnded()

        XCTAssertEqual(player.currentTrack?.id, second.id)
        XCTAssertEqual(probe.players.count, 2)
        XCTAssertEqual(probe.players.last?.timeControlStatus, .playing)
        XCTAssertTrue(player.isPlaying)
    }

    func testNextAtEndOfQueueStopsTheCurrentEngineImmediately() throws {
        let (player, probe, _) = makeController()
        defer { player.stopSync() }
        player.applySyncState(try snapshot(for: player))
        player.next()
        let engine = try XCTUnwrap(probe.players.last)
        XCTAssertEqual(player.currentTrack?.id, second.id)

        player.next()

        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(engine.timeControlStatus, .paused)
        XCTAssertEqual(probe.players.count, 2)
    }

    func testDelayedTrackEndAfterExplicitPauseCannotStartTheNextTrack() throws {
        let (player, probe, _) = makeController()
        defer { player.stopSync() }
        player.applySyncState(try snapshot(for: player))
        player.pausePlayback()

        player.handleTrackEnded()

        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTrack?.id, first.id)
        XCTAssertEqual(probe.players.count, 1)
    }

    func testDelayedTrackEndDuringInterruptionCannotStartTheNextTrack() throws {
        let (player, probe, _) = makeController()
        defer { player.stopSync() }
        player.applySyncState(try snapshot(for: player))
        beginInterruption(player)

        player.handleTrackEnded()

        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTrack?.id, first.id)
        XCTAssertEqual(probe.players.count, 1)
    }

    func testRepeatOneRestartsLocallyBeforeServerAcknowledgement() throws {
        let (player, probe, _) = makeController()
        defer { player.stopSync() }
        player.applySyncState(try snapshot(for: player, repeatMode: "one"))
        let engine = try XCTUnwrap(probe.players.last)
        engine.seconds = 180
        engine.pause()
        let seeks = engine.seeks.count

        player.handleTrackEnded()

        XCTAssertEqual(player.currentTrack?.id, first.id)
        XCTAssertEqual(probe.players.count, 1)
        XCTAssertEqual(engine.seeks.count, seeks + 1)
        XCTAssertEqual(try XCTUnwrap(engine.seeks.last), 0, accuracy: 0.001)
        XCTAssertEqual(engine.timeControlStatus, .playing)
        XCTAssertTrue(player.isPlaying)
    }
}

@MainActor
private final class ContinuityProbe {
    var players: [ContinuityPlayerSpy] = []
    var items: [AVPlayerItem] = []
    var activations = 0
    var activationShouldFail = false
}

@MainActor
final class OfflinePlaybackTests: XCTestCase {
    private func eventually(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = await condition()
        XCTAssertTrue(result, "Offline playback did not settle before the deadline")
    }

    func testDownloadedTransportAndQueueNeverWaitForOrContactServerOffline() async throws {
        let h = try OfflinePlaybackHarness()
        defer { h.close() }
        h.player.play(h.first, from: [h.first, h.missing, h.second])
        XCTAssertTrue(h.player.isPlaying)
        XCTAssertTrue(h.player.isOfflinePlayback)
        XCTAssertEqual((h.probe.items.last?.asset as? AVURLAsset)?.url, h.file(for: h.first))
        h.player.togglePlayback()
        XCTAssertFalse(h.player.isPlaying)
        h.player.togglePlayback()
        h.player.seek(to: 23)
        XCTAssertEqual(h.probe.players.last?.seconds, 23)
        h.player.playLater(h.first)
        h.player.next()
        XCTAssertEqual(h.player.currentTrack?.id, h.first.id)
        h.player.handleTrackEnded()
        XCTAssertEqual(h.player.currentTrack?.id, h.second.id, "Automatic advancement skips unavailable songs")
        XCTAssertTrue(h.player.isPlaying)
        XCTAssertTrue(h.probe.items.allSatisfy { ($0.asset as? AVURLAsset)?.url.isFileURL == true })
        let requests = await h.server.requests
        XCTAssertEqual(requests, 0, "Offline transport must not issue token, control, or streaming requests")
    }

    func testUnavailableExplicitSelectionLeavesCurrentDownloadedSongAndQueueIntact() throws {
        let h = try OfflinePlaybackHarness()
        defer { h.close() }
        h.player.play(h.first, from: [h.first, h.second])
        let source = h.player.source
        let count = h.probe.players.count
        h.player.play(h.missing, from: [h.missing])
        XCTAssertEqual(h.player.currentTrack?.id, h.first.id)
        XCTAssertEqual(h.player.source, source)
        XCTAssertEqual(h.probe.players.count, count)
        XCTAssertTrue(h.player.isPlaying)
        XCTAssertTrue(h.errors.last?.contains("isn't downloaded") == true)
    }

    func testNaturalCompletionWithoutSyncAlsoSkipsUnavailableSongs() throws {
        let h = try OfflinePlaybackHarness(startSync: false)
        defer { h.close() }
        h.player.play(h.first, from: [h.first, h.missing, h.second])
        h.player.handleTrackEnded()
        XCTAssertEqual(h.player.currentTrack?.id, h.second.id)
        XCTAssertTrue(h.player.isPlaying)
    }

    func testCompletedDownloadWinsOverAnAlreadyPreloadedRemoteAsset() throws {
        let h = try OfflinePlaybackHarness(startSync: false)
        defer { h.close() }
        h.player.setSyncAvailable(true)
        h.player.play(h.first, from: [h.first, h.missing])
        try h.addDownload(h.missing)
        h.player.next()
        XCTAssertEqual((h.probe.items.last?.asset as? AVURLAsset)?.url, h.file(for: h.missing))
        XCTAssertTrue(h.player.isPlaying)
    }

    func testMatchingReconnectUploadsLatestLocalContextWithoutPausingSeekingOrReplacingPlayer() async throws {
        let h = try OfflinePlaybackHarness()
        defer { h.close() }
        let baseline = try h.snapshot(owner: h.player.deviceID, revision: 4)
        h.player.applySyncState(baseline)
        h.player.play(h.second, from: [h.second, h.first])
        h.player.playLater(h.first)
        let engine = try XCTUnwrap(h.probe.players.last)
        engine.seconds = 31
        let pauses = engine.pauseCalls, seeks = engine.seeks.count, players = h.probe.players.count
        try await h.server.setState(baseline)

        h.player.setSyncAvailable(true)
        try await eventually { !h.player.isOfflinePlayback }

        XCTAssertEqual(h.player.currentTrack?.id, h.second.id)
        XCTAssertEqual(h.player.manualQueue.map(\.id), [h.first.id])
        XCTAssertEqual(h.probe.players.count, players)
        XCTAssertEqual(engine.pauseCalls, pauses)
        XCTAssertEqual(engine.seeks.count, seeks)
        XCTAssertEqual(engine.seconds, 31)
        XCTAssertTrue(h.player.isPlaying)
        let commands = await h.server.commands
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.kind, "play")
        XCTAssertEqual(commands.first?.position, 31)
        XCTAssertEqual(commands.first?.expectedRevision, 4)
        XCTAssertEqual(commands.first?.trackID, h.second.id)
    }

    func testOfflinePauseRecoversAsPausedWithoutBrieflyPlaying() async throws {
        let h = try OfflinePlaybackHarness()
        defer { h.close() }
        let baseline = try h.snapshot(owner: h.player.deviceID, revision: 4)
        h.player.applySyncState(baseline)
        h.player.pausePlayback()
        let engine = try XCTUnwrap(h.probe.players.last)
        let plays = engine.playCalls
        try await h.server.setState(baseline)
        h.player.setSyncAvailable(true)
        try await eventually { !h.player.isOfflinePlayback }
        XCTAssertFalse(h.player.isPlaying)
        XCTAssertEqual(engine.playCalls, plays)
        let commands = await h.server.commands
        XCTAssertEqual(commands.first?.kind, "load")
    }

    func testRemoteOwnerIsNotHijackedByOfflineControlsOrReconnect() async throws {
        let h = try OfflinePlaybackHarness()
        defer { h.close() }
        let remote = try h.snapshot(owner: "another-device", revision: 7)
        h.player.applySyncState(remote)
        h.player.next()
        h.player.togglePlayback()
        XCTAssertTrue(h.probe.players.isEmpty)
        XCTAssertEqual(h.player.currentTrack?.id, h.first.id)

        // An explicit downloaded-song selection can start an independent
        // local session, but reconnect cannot take the other speaker over.
        h.player.play(h.second, from: [h.second, h.first])
        let engine = try XCTUnwrap(h.probe.players.last)
        let pauses = engine.pauseCalls
        try await h.server.setState(remote)
        h.player.setSyncAvailable(true)
        try await eventually { h.player.hasOfflinePlaybackConflict }
        XCTAssertTrue(h.player.isPlaying)
        XCTAssertEqual(h.player.currentTrack?.id, h.second.id)
        XCTAssertEqual(engine.pauseCalls, pauses)
        let commands = await h.server.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func testChangedRevisionPreservesOfflineQueueRatherThanOverwritingAnotherDevice() async throws {
        let h = try OfflinePlaybackHarness()
        defer { h.close() }
        h.player.applySyncState(try h.snapshot(owner: h.player.deviceID, revision: 4))
        h.player.playLater(h.second)
        try await h.server.setState(h.snapshot(owner: h.player.deviceID, revision: 5))
        h.player.setSyncAvailable(true)
        try await eventually { h.player.hasOfflinePlaybackConflict }
        XCTAssertEqual(h.player.manualQueue.map(\.id), [h.second.id])
        XCTAssertTrue(h.player.isPlaying)
        let commands = await h.server.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func testColdOfflineSelectionSurvivesOldServerPlaybackWhenConnectionReturns() async throws {
        let h = try OfflinePlaybackHarness()
        defer { h.close() }
        h.player.play(h.second, from: [h.second])
        try await h.server.setState(h.snapshot(owner: h.player.deviceID, revision: 20))
        h.player.setSyncAvailable(true)
        try await eventually { h.player.hasOfflinePlaybackConflict }
        XCTAssertEqual(h.player.currentTrack?.id, h.second.id)
        XCTAssertTrue(h.player.isPlaying)
    }

    func testControlsDuringRecoveryUploadConvergeOnLatestLocalIntent() async throws {
        let h = try OfflinePlaybackHarness()
        defer { h.close() }
        let baseline = try h.snapshot(owner: h.player.deviceID, revision: 4)
        h.player.applySyncState(baseline)
        h.player.seek(to: 5)
        try await h.server.setState(baseline)
        await h.server.setCommandDelay(.milliseconds(100))
        h.player.setSyncAvailable(true)
        try await eventually { await h.server.commandAttempts > 0 }
        h.player.next()
        h.player.playLater(h.first)
        try await eventually { !h.player.isOfflinePlayback }
        XCTAssertEqual(h.player.currentTrack?.id, h.second.id)
        XCTAssertEqual(h.player.manualQueue.map(\.id), [h.first.id])
        let commands = await h.server.commands
        XCTAssertEqual(commands.map(\.expectedRevision), [4, 5])
        XCTAssertEqual(commands.last?.trackID, h.second.id)
    }

    func testReconnectDuringSystemInterruptionPreservesResumeIntent() async throws {
        let h = try OfflinePlaybackHarness()
        defer { h.close() }
        let baseline = try h.snapshot(owner: h.player.deviceID, revision: 4)
        h.player.applySyncState(baseline)
        h.player.seek(to: 15)
        h.player.handleInterruption(typeValue: AVAudioSession.InterruptionType.began.rawValue, optionsValue: nil)
        XCTAssertFalse(h.player.isPlaying)
        try await h.server.setState(baseline)
        h.player.setSyncAvailable(true)
        try await eventually { !h.player.isOfflinePlayback }
        XCTAssertFalse(h.player.isPlaying, "Reconnection must not play through a system interruption")
        let commands = await h.server.commands
        XCTAssertEqual(commands.first?.kind, "play", "Temporary interruption must not become an explicit shared pause")
        h.player.handleInterruption(typeValue: AVAudioSession.InterruptionType.ended.rawValue,
                                   optionsValue: AVAudioSession.InterruptionOptions.shouldResume.rawValue)
        XCTAssertTrue(h.player.isPlaying)
    }

    func testServerFailureAfterLocalPlayCannotRestoreOldSongOrBlockDownloadedAudio() async throws {
        let h = try OfflinePlaybackHarness()
        defer { h.close() }
        let baseline = try h.snapshot(owner: h.player.deviceID, revision: 4)
        h.player.applySyncState(baseline)
        try await h.server.setState(baseline)
        h.player.setSyncAvailable(true)
        await h.player.reconcilePlayback()
        await h.server.failNextCommand()
        h.player.reportSyncFailure = { [weak player = h.player] _ in player?.setSyncAvailable(false) }
        h.player.play(h.second, from: [h.second, h.first])
        XCTAssertEqual(h.player.currentTrack?.id, h.second.id)
        XCTAssertTrue(h.player.isPlaying, "The downloaded song starts before the control request completes")
        try await eventually { !h.player.isSyncAvailable }
        h.player.applySyncState(baseline, force: true)
        XCTAssertEqual(h.player.currentTrack?.id, h.second.id)
        XCTAssertTrue(h.player.isPlaying)
        XCTAssertTrue(h.player.isOfflinePlayback)
    }

    func testRemotePauseAfterAnOutageStillAppliesWhenThereWereNoLocalEdits() async throws {
        let h = try OfflinePlaybackHarness()
        defer { h.close() }
        let baseline = try h.snapshot(owner: h.player.deviceID, revision: 4)
        h.player.applySyncState(baseline)
        h.player.setSyncAvailable(true)
        h.player.setSyncAvailable(false)
        XCTAssertTrue(h.player.isOfflinePlayback)
        try await h.server.setState(h.snapshot(owner: h.player.deviceID, revision: 5, playing: false))
        h.player.setSyncAvailable(true)
        try await eventually { !h.player.isOfflinePlayback }
        XCTAssertFalse(h.player.isPlaying)
        XCTAssertFalse(h.player.hasOfflinePlaybackConflict)
        let commands = await h.server.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func testNewerEventDuringRecoveryResponseIsRetainedAsAConflict() async throws {
        let h = try OfflinePlaybackHarness()
        defer { h.close() }
        let baseline = try h.snapshot(owner: h.player.deviceID, revision: 4)
        h.player.applySyncState(baseline)
        h.player.play(h.second, from: [h.second, h.first])
        try await h.server.setState(baseline)
        await h.server.setResponseDelay(.milliseconds(100))
        h.player.setSyncAvailable(true)
        try await eventually { await h.server.commands.count == 1 }
        let external = try h.snapshot(owner: "another-device", revision: 6)
        try await h.server.setState(external)
        try h.events.send(external)
        try await eventually { h.player.hasOfflinePlaybackConflict }
        XCTAssertEqual(h.player.currentTrack?.id, h.second.id)
        XCTAssertTrue(h.player.isPlaying)
        XCTAssertEqual(h.player.syncState?.revision, 6)
    }

    func testPathLossWithAnUnacknowledgedLocalPlayPreservesThatIntent() async throws {
        let h = try OfflinePlaybackHarness()
        defer { h.close() }
        h.player.applySyncState(try h.snapshot(owner: h.player.deviceID, revision: 4))
        h.player.setSyncAvailable(true)
        h.player.play(h.second, from: [h.second, h.first])
        // Connectivity changes before the scheduled control request can run.
        h.player.setSyncAvailable(false)
        try await h.server.setState(h.snapshot(owner: h.player.deviceID, revision: 5, playing: false))
        h.player.setSyncAvailable(true)
        try await eventually { h.player.hasOfflinePlaybackConflict }
        XCTAssertEqual(h.player.currentTrack?.id, h.second.id)
        XCTAssertTrue(h.player.isPlaying)
    }
}

@MainActor
private final class OfflinePlaybackHarness {
    let directory: URL
    let first: CodecTrack
    let second: CodecTrack
    let missing: CodecTrack
    var downloads: DownloadStore
    let server = OfflinePlaybackServer()
    let probe = ContinuityProbe()
    let events = OfflinePlaybackEvents()
    let player: PlayerController
    var errors: [String] = []

    init(startSync: Bool = true) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codec-offline-\(UUID().uuidString)")
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func track(_ id: String) -> CodecTrack {
            CodecTrack(id: id, title: id, artist: "", album: "", durationSeconds: 180,
                       artworkURL: directory.appendingPathComponent("\(id).wav"),
                       audioURL: URL(string: "https://offline-playback-tests.invalid/audio/\(id)")!, fingerprint: id)
        }
        first = track("offline-first")
        second = track("offline-second")
        missing = track("offline-missing")
        for track in [first, second] {
            try Data(repeating: 0, count: 128).write(to: directory.appendingPathComponent("\(track.fingerprint).wav"))
        }
        downloads = DownloadStore(directory: directory, configuration: .ephemeral)
        let probe = self.probe
        let events = self.events
        player = PlayerController(
            syncPollInterval: .seconds(3600),
            consumePlaybackEvents: events.consume,
            makePlayer: { item in
                let engine = ContinuityPlayerSpy()
                probe.players.append(engine)
                probe.items.append(item)
                return engine
            }, activateAudioSession: {}
        )
        let tracks = [first, second, missing]
        player.client = server.client
        player.downloads = downloads
        player.resolveTrack = { ref in tracks.first { $0.fingerprint == ref.fingerprint } }
        player.reportSyncError = { [weak self] message in self?.errors.append(message) }
        player.setSyncAvailable(false)
        if startSync { player.startSync(client: server.client) }
    }

    func file(for track: CodecTrack) -> URL { directory.appendingPathComponent("\(track.fingerprint).wav") }

    func addDownload(_ track: CodecTrack) throws {
        try Data(repeating: 0, count: 128).write(to: file(for: track))
        downloads.shutdown()
        downloads = DownloadStore(directory: directory, configuration: .ephemeral)
        player.downloads = downloads
    }

    func close() {
        player.stopSync()
        probe.players.forEach { $0.pause() }
        downloads.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }

    func snapshot(owner: String, revision: Int, playing: Bool = true) throws -> PlaybackState {
        func ref(_ track: CodecTrack) -> [String: String] { ["id":track.id,"fingerprint":track.fingerprint,"path":"loud://track/\(track.fingerprint)"] }
        let now = PlayerController.nowMS()
        let data = try JSONSerialization.data(withJSONObject: [
            "schema":"loud.playback.v2", "revision":revision, "state":playing ? "playing" : "paused", "active_device_id":owner,
            "track":ref(first), "context":["playback_source":[ref(first),ref(second)],"playback_index":0],
            "clock":["position_seconds":10,"updated_at_ms":now,"started_at_ms":now], "volume":1,"server_time_ms":now
        ])
        return try JSONDecoder().decode(PlaybackState.self, from:data)
    }
}

@MainActor
private final class OfflinePlaybackEvents {
    private var receive: ((PlaybackStreamEvent) -> Void)?
    func consume(_ request: URLRequest, receive: @escaping @MainActor (PlaybackStreamEvent) -> Void) async throws {
        self.receive = receive
        receive(.connected)
        while !Task.isCancelled { try await Task.sleep(for: .seconds(15)); receive(.line(": heartbeat")) }
    }
    func send(_ state: PlaybackState) throws {
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        receive?(.line("data: {\"type\":\"playback_state\",\"playback_state\":\(json)}"))
    }
}

private actor OfflinePlaybackServer: CodecTransport {
    struct Command: Sendable {
        let kind: String
        let trackID: String?
        let position: Double?
        let expectedRevision: Int64?
    }
    private var stateData = Data("null".utf8)
    private var commandDelay: Duration = .zero
    private var responseDelay: Duration = .zero
    private var shouldFailNextCommand = false
    private(set) var requests = 0
    private(set) var commandAttempts = 0
    private(set) var commands: [Command] = []
    nonisolated var client: CodecClient { CodecClient(baseURL: URL(string:"https://offline-playback-tests.invalid")!, transport:self) }
    func setState(_ state: PlaybackState) throws { stateData = try JSONEncoder().encode(state) }
    func setCommandDelay(_ delay: Duration) { commandDelay = delay }
    func setResponseDelay(_ delay: Duration) { responseDelay = delay }
    func failNextCommand() { shouldFailNextCommand = true }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests += 1
        var status = 200
        var data = Data()
        switch request.url?.path {
        case "/api/v2/playback": data = stateData
        case "/api/v1/playback/devices": data = Data("[]".utf8)
        case "/api/v2/playback/commands":
            commandAttempts += 1
            if shouldFailNextCommand {
                shouldFailNextCommand = false
                throw URLError(.notConnectedToInternet)
            }
            if commandDelay > .zero { try await Task.sleep(for: commandDelay) }
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            var current = (try? JSONSerialization.jsonObject(with: stateData)) as? [String: Any] ?? [:]
            let revision = (current["revision"] as? Int64) ?? 0
            let expected = request.value(forHTTPHeaderField:"If-Match").flatMap { Int64($0.replacingOccurrences(of:"\"",with:"")) }
            if expected != nil && expected != revision { status = 409; break }
            let kind = body["kind"] as! String
            let track = body["track"] as? [String: Any]
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            current["schema"] = "loud.playback.v2"
            current["revision"] = revision + 1
            current["state"] = kind == "load" ? "paused" : "playing"
            current["active_device_id"] = body["target_device_id"]
            current["track"] = track
            current["context"] = body["context"]
            current["clock"] = ["position_seconds":body["position_seconds"] ?? 0,"updated_at_ms":now,
                                kind == "load" ? "stopped_at_ms" : "started_at_ms":now]
            current["volume"] = 1
            current["server_time_ms"] = now
            stateData = try JSONSerialization.data(withJSONObject: current)
            data = stateData
            commands.append(Command(kind:kind,trackID:track?["id"] as? String,
                                    position:body["position_seconds"] as? Double,expectedRevision:expected))
            if responseDelay > .zero { try await Task.sleep(for: responseDelay) }
        default: break
        }
        return (data, HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!)
    }
}

/// AVPlayer's transport methods are nonisolated in the SDK. This test double
/// is only driven synchronously by the MainActor controller and these tests;
/// it never starts a media item or invokes AVFoundation's transport methods.
private final class ContinuityPlayerSpy: AVPlayer, @unchecked Sendable {
    nonisolated(unsafe) var seconds: Double = 0
    nonisolated(unsafe) var seeks: [Double] = []
    nonisolated(unsafe) var playCalls = 0
    nonisolated(unsafe) var pauseCalls = 0
    nonisolated(unsafe) private var simulatedRate: Float = 0

    nonisolated override var rate: Float {
        get { simulatedRate }
        set { simulatedRate = newValue }
    }
    nonisolated override var timeControlStatus: AVPlayer.TimeControlStatus {
        simulatedRate == 0 ? .paused : .playing
    }
    nonisolated override func play() {
        playCalls += 1
        simulatedRate = 1
    }
    nonisolated override func pause() {
        pauseCalls += 1
        simulatedRate = 0
    }
    nonisolated override func currentTime() -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
    nonisolated override func seek(to time: CMTime) {
        seconds = time.seconds
        seeks.append(time.seconds)
    }
    nonisolated override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) {
        seek(to: time)
    }
}

private actor ContinuityTransport: CodecTransport {
    struct OwnershipCommand: Sendable {
        let kind: String
        let expectedRevision: Int64?
        let status: Int
    }
    private var commandResponses: [Data] = []
    private var failNextCommandAfterResponse = false
    private var playbackStateData: Data?
    private(set) var failedCommands = 0
    private var ownershipServerData: Data?
    private var ownershipResponseDelay: Duration = .zero
    private(set) var ownershipCommands: [OwnershipCommand] = []

    func emulateOwnershipServer(state: PlaybackState, responseDelay: Duration = .zero) throws {
        ownershipServerData = try JSONEncoder().encode(state)
        ownershipResponseDelay = responseDelay
    }

    func ownershipState() throws -> PlaybackState {
        try JSONDecoder().decode(PlaybackState.self, from: ownershipServerData!)
    }

    func respondToNextCommand(with data: Data) { commandResponses = [data] }

    func respondToCommands(with data: [Data]) { commandResponses = data }

    func respondThenFailNextCommand(with data: Data) {
        commandResponses = [data]
        failNextCommandAfterResponse = true
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if request.url?.path == "/api/v2/playback/commands" {
            if let ownershipServerData {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let kind = body["kind"] as! String
                var state = try JSONSerialization.jsonObject(with: ownershipServerData) as! [String: Any]
                let revision = state["revision"] as! Int64
                let expected = request.value(forHTTPHeaderField: "If-Match").flatMap {
                    Int64($0.replacingOccurrences(of: "\"", with: ""))
                }
                let status = expected != nil && expected != revision ? 409 : 200
                ownershipCommands.append(OwnershipCommand(kind: kind, expectedRevision: expected, status: status))
                if status == 409 { return (Data(), response(for: request, status: status)) }
                // Match the real server: unguarded play/pause/seek commands
                // also replace active_device_id, even after another transfer.
                state["active_device_id"] = body["target_device_id"]
                state["revision"] = revision + 1
                if kind == "pause" { state["state"] = "paused" }
                if kind == "play" { state["state"] = "playing" }
                let data = try JSONSerialization.data(withJSONObject: state)
                self.ownershipServerData = data
                playbackStateData = data
                if ownershipResponseDelay > .zero { try await Task.sleep(for: ownershipResponseDelay) }
                return (data, response(for: request))
            }
            if !commandResponses.isEmpty {
                let data = commandResponses.removeFirst()
                try await Task.sleep(for: .milliseconds(40))
                playbackStateData = data
                return (data, response(for: request))
            }
            if failNextCommandAfterResponse {
                failNextCommandAfterResponse = false
                failedCommands += 1
                return (Data("Temporarily unavailable".utf8), response(for: request, status: 503))
            }
            // Automatic advance/resume must succeed before this returns.
            // stopSync cancels the controller task during each test's cleanup.
            try await Task.sleep(for: .seconds(30))
            throw URLError(.timedOut)
        }
        let data: Data
        switch request.url?.path {
        case "/api/v2/playback":
            // Hide the already-transferred server state until the first
            // command, modeling a delayed SSE/HTTP ownership notification.
            data = ownershipCommands.isEmpty ? (playbackStateData ?? Data("null".utf8)) : (ownershipServerData ?? playbackStateData ?? Data("null".utf8))
        case "/api/v1/playback/devices": data = Data("[]".utf8)
        default: data = Data()
        }
        return (data, response(for: request))
    }

    private func response(for request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}
