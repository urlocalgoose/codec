import AVFoundation
import Foundation
import XCTest
@testable import Codec

/// Uses actual local AVPlayer decoding and the app's processing tap. The
/// injected route events exercise controller decisions, not iPhone hardware
/// sleep, notification delivery, or audible interruption timing.
@MainActor
final class PlaybackEngineSmokeTests: XCTestCase {
    func testRealPlayerResumesNotificationBurstsWithTheSameItemAndContinuousPosition() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codec-interruption-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("silence.wav")
        try writeSilentWAV(to: audioURL)
        let track = CodecTrack(id: "interruption-smoke", title: "Notification playback regression", artist: "", album: "",
                               durationSeconds: 10, artworkURL: audioURL, audioURL: audioURL, fingerprint: "interruption-smoke")
        var engines: [AVPlayer] = []
        let controller = PlayerController(makePlayer: { item in
            let engine = AVPlayer(playerItem: item)
            engines.append(engine)
            return engine
        })
        controller.client = CodecClient(baseURL: directory)
        controller.resolveTrack = { $0.fingerprint == track.fingerprint ? track : nil }
        defer {
            controller.pausePlayback()
            controller.stopSync()
            engines.forEach { $0.replaceCurrentItem(with: nil) }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        controller.applySyncState(try playingSnapshot(track: track, deviceID: controller.deviceID))
        let engine = try XCTUnwrap(engines.first)
        let item = try XCTUnwrap(engine.currentItem)
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if engine.timeControlStatus == .playing, engine.currentTime().seconds >= 0.25, item.audioMix != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(engine.timeControlStatus, .playing)
        XCTAssertNotNil(item.audioMix)
        let start = engine.currentTime().seconds

        for _ in 0..<3 {
            let before = engine.currentTime().seconds
            NotificationCenter.default.post(
                name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
            )
            XCTAssertFalse(controller.isPlaying, "Interruption delivery must synchronously suspend controller playback")
            NotificationCenter.default.post(
                name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                           AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue]
            )
            XCTAssertTrue(controller.isPlaying)
            try await Task.sleep(for: .milliseconds(300))
            let after = engine.currentTime().seconds
            XCTAssertGreaterThan(after, before + 0.1)
            XCTAssertLessThan(after, before + 0.7, "Resuming must retain the local position rather than jumping to a remote clock")
            XCTAssertEqual(engines.count, 1)
            XCTAssertTrue(engine.currentItem === item)
            XCTAssertEqual(engine.timeControlStatus, .playing)
        }
        print("REAL AVPLAYER notification smoke: advanced \(engine.currentTime().seconds - start)s through three injected interruption pairs with the same player/item")
    }

    func testRealPlayerKeepsAdvancingAcrossHarmlessRouteEventsAndRepeatedSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codec-playback-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("silence.wav")
        try writeSilentWAV(to: audioURL)
        let track = CodecTrack(
            id: "engine-smoke", title: "Silent playback regression", artist: "", album: "",
            durationSeconds: 10, artworkURL: audioURL, audioURL: audioURL,
            fingerprint: "engine-smoke"
        )
        var engines: [AVPlayer] = []
        let controller = PlayerController(makePlayer: { item in
            let engine = AVPlayer(playerItem: item)
            engines.append(engine)
            return engine
        })
        // No sync connection is started, so media/artwork remain local and
        // the snapshot below is applied without polling or sending commands.
        controller.client = CodecClient(baseURL: directory)
        controller.resolveTrack = { $0.fingerprint == track.fingerprint ? track : nil }
        defer {
            controller.pausePlayback()
            controller.stopSync()
            engines.forEach { $0.replaceCurrentItem(with: nil) }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        let snapshot = try playingSnapshot(track: track, deviceID: controller.deviceID)
        controller.applySyncState(snapshot)
        let engine = try XCTUnwrap(engines.first)
        let item = try XCTUnwrap(engine.currentItem)

        // Initial decoding, audio-session activation and simulator scheduling
        // get a generous deadline; this is not a frame-pacing benchmark.
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < readyDeadline,
              engine.status != .failed, item.status != .failed {
            if engine.status == .readyToPlay, engine.timeControlStatus == .playing,
               engine.currentTime().seconds >= 0.25, item.audioMix != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(engine.status, .readyToPlay, engine.error?.localizedDescription ?? "Player failed to become ready")
        XCTAssertEqual(item.status, .readyToPlay, item.error?.localizedDescription ?? "WAV failed to decode")
        XCTAssertEqual(engine.timeControlStatus, .playing)
        XCTAssertNotNil(item.audioMix, "The real spectrum processing tap must be installed")
        guard engine.status == .readyToPlay, engine.timeControlStatus == .playing else { return }

        let startPosition = engine.currentTime().seconds
        XCTAssertGreaterThanOrEqual(startPosition, 0.25)
        var lastPosition = startPosition
        let reasons: [AVAudioSession.RouteChangeReason] = [.wakeFromSleep, .routeConfigurationChange, .categoryChange]
        for index in 0..<9 {
            controller.handleRouteChange(reasonValue: reasons[index % reasons.count].rawValue)
            controller.applySyncState(snapshot, force: true)
            controller.handlePlaybackTick(engine.currentTime(), from: engine)
            try await Task.sleep(for: .milliseconds(250))

            let position = engine.currentTime().seconds
            XCTAssertGreaterThanOrEqual(position, lastPosition - 0.05, "A harmless event must not rewind real media")
            XCTAssertEqual(engine.timeControlStatus, .playing, "A harmless event must not pause the engine")
            XCTAssertTrue(controller.isPlaying)
            XCTAssertEqual(engines.count, 1, "Repeated snapshots must retain the existing engine")
            XCTAssertTrue(engine.currentItem === item, "The loaded audio item must remain attached")
            lastPosition = position
        }
        XCTAssertGreaterThan(lastPosition - startPosition, 1,
                             "The actual media clock must keep advancing across the event sequence")
        print("REAL AVPLAYER smoke: advanced \(lastPosition - startPosition)s across nine route/snapshot events with the same player and item")
    }

    private func playingSnapshot(track: CodecTrack, deviceID: String) throws -> PlaybackState {
        let reference = ["id": track.id, "fingerprint": track.fingerprint, "path": "loud://track/\(track.fingerprint)"]
        let now = PlayerController.nowMS()
        let data = try JSONSerialization.data(withJSONObject: [
            "schema": "loud.playback.v2", "revision": 1,
            "active_device_id": deviceID, "state": "playing", "track": reference,
            "context": ["playback_source": [reference], "playback_index": 0],
            "clock": ["position_seconds": 0, "updated_at_ms": now, "started_at_ms": now],
            "volume": 1, "server_time_ms": now
        ])
        return try JSONDecoder().decode(PlaybackState.self, from: data)
    }

    private func writeSilentWAV(to url: URL) throws {
        let sampleRate: UInt32 = 48_000
        let byteCount: UInt32 = sampleRate * 10 * 2 // Ten seconds, mono signed 16-bit PCM.
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36) + byteCount)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1)) // Linear PCM.
        append(UInt16(1)) // One channel.
        append(sampleRate)
        append(sampleRate * 2)
        append(UInt16(2)) // Block alignment.
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(byteCount)
        data.append(Data(repeating: 0, count: Int(byteCount)))
        try data.write(to: url, options: .atomic)
    }
}
