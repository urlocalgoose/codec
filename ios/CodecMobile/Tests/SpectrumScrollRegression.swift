import AVFoundation
import XCTest
@testable import Codec

final class SpectrumScrollRegression: XCTestCase {
    @MainActor func testTrackChangesStampFallbackBeforeTasksAndRejectLateArtwork() {
        let history = SpectrumHistory(capacity: 7)
        func palette(_ ink: SIMD4<Float>) -> SpectrumPalette {
            SpectrumPalette(bg: ink * 0.1, cool: ink, mid: ink, warm: ink, hot: ink)
        }
        let fallback = palette(SIMD4(0.3,0.3,0.3,1))
        let red = palette(SIMD4(1,0,0,1)), blue = palette(SIMD4(0,0,1,1))
        let first = SpectrumTrackIdentity(CodecTrack(id: "a", title: "A", artist: "", album: "", fingerprint: "a"))
        let second = SpectrumTrackIdentity(CodecTrack(id: "b", title: "B", artist: "", album: "", fingerprint: "b"))
        let a = history.beginAppearance(for: first, fallback: fallback)
        XCTAssertTrue(history.completeAppearance(red, generation: a))
        history.append([1])
        // No renderer exists, and no async task has started for song B yet.
        history.beginTrack(second)
        history.append([1])
        XCTAssertEqual(history.palette(forColumn: 0), red)
        XCTAssertEqual(history.palette(forColumn: 1), fallback)
        XCTAssertFalse(history.completeAppearance(red, generation: a))
        let b = history.beginAppearance(for: second, fallback: fallback)
        XCTAssertTrue(history.completeAppearance(blue, generation: b))
        history.append([1])
        XCTAssertEqual(history.palette(forColumn: 2), blue)
        history.beginTrack(first)
        XCTAssertFalse(history.completeAppearance(red, generation: a), "A→B→A must reject the first visit's completion")
        history.append([1])
        XCTAssertEqual(history.palette(forColumn: 3), fallback)
        let nextA = history.beginAppearance(for: first, fallback: fallback)
        XCTAssertTrue(history.completeAppearance(red, generation: nextA))
        history.beginTrack(first)
        history.append([1])
        XCTAssertEqual(history.palette(forColumn: 4), red, "Same-identity metadata refresh preserves current artwork")
    }

    @MainActor func testPlayerTrackMutationInvalidatesAppearanceWithoutWaitingForAView() {
        let player = PlayerController(makePlayer: { _ in SpectrumPlaybackStub() }, activateAudioSession: {})
        let history = player.spectrum
        let fallback = SpectrumPalette(bg: .zero, cool: .zero, mid: .zero, warm: .zero, hot: .zero)
        let red = SpectrumPalette(bg: .zero, cool: SIMD4(1,0,0,1), mid: .zero, warm: .zero, hot: .zero)
        let track = CodecTrack(id: "new", title: "New", artist: "", album: "",
                               audioURL: URL(fileURLWithPath: "/dev/null"), fingerprint: "new")
        let generation = history.beginAppearance(for: nil, fallback: fallback)
        XCTAssertTrue(history.completeAppearance(red, generation: generation))
        player.play(track, from: [track])
        history.append([1])
        XCTAssertEqual(history.palette(forColumn: history.count - 1), fallback)
        XCTAssertFalse(history.completeAppearance(red, generation: generation))
        player.pausePlayback()
    }

    @MainActor func testDisplayFrameSampling() {
        let history = SpectrumHistory(capacity: 32)
        let source = SpectrumSource()
        history.activate(source)
        for frame in 1...120 {
            history.sampleFrame()
            XCTAssertTrue(history.count == frame, "Each display callback must record exactly one column")
        }
        XCTAssertTrue(history.oldestIndex == 88)
        var output = [Float](repeating: 1, count: 112)
        history.column(119, into: &output)
        XCTAssertTrue(output.allSatisfy { $0 == 0 })
        print("Display-frame sampling and retained-history boundaries passed")
    }
}

private final class SpectrumPlaybackStub: AVPlayer, @unchecked Sendable {
    nonisolated override func play() {}
    nonisolated override func pause() {}
}
