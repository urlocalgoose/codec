import AVFoundation
import XCTest
@testable import Codec

final class AudioSpectrumRegression: XCTestCase {
    @MainActor func testDisplaySamplingNeverWaitsForWorkerAndCoalescesPendingFrames() async throws {
        let queue = DispatchQueue(label: "spectrum.blocked-analysis-test")
        let acquired = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        queue.async {
            acquired.signal()
            _ = release.wait(timeout: .now() + 3)
        }
        XCTAssertEqual(acquired.wait(timeout: .now() + 2), .success)
        let source = SpectrumSource()
        source.prepare(format: monoFloatFormat)
        let history = SpectrumHistory(capacity: 256)
        history.activate(source, analysisQueue: queue)
        history.samplingFromView = true // This test explicitly supplies display callbacks.
        defer { release.signal(); history.samplingFromView = false }
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<120 { history.sampleFrame() }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5,
                          "A blocked analysis worker must not delay display callbacks")
        XCTAssertEqual(history.count, 120, "Display cadence continues while analysis is busy")

        var samples = sineSamples(count: 2048)
        feed(&samples, to: source)
        let reference = SpectrumSource()
        reference.prepare(format: monoFloatFormat)
        feed(&samples, to: reference)
        let once = reference.frequencyBands()
        release.signal()
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
        history.sampleFrame()
        var latest = [Float](repeating: 0, count: SpectrumHistory.bands)
        history.column(120, into: &latest)
        XCTAssertEqual(latest, once,
                       "120 busy display callbacks must enqueue one FFT, not a backlog of 120 smoothing steps")
        XCTAssertTrue(latest.contains { $0 > 0 })
    }

    @MainActor func testUnchangedPCMReusesTransformWithoutChangingSmoothingOrSilenceDecay() async throws {
        let cached = SpectrumSource(), repeated = SpectrumSource()
        cached.prepare(format: monoFloatFormat)
        repeated.prepare(format: monoFloatFormat)
        var samples = sineSamples(count: 2048)
        feed(&samples, to: cached)
        var first: [Float] = [], last: [Float] = []
        for frame in 0..<8 {
            feed(&samples, to: repeated)
            last = cached.frequencyBands()
            XCTAssertEqual(last, repeated.frequencyBands())
            if frame == 0 { first = last }
        }
        XCTAssertNotEqual(first, last, "Reusing the FFT must not freeze per-frame smoothing")
        try await Task.sleep(for: .milliseconds(150))
        for _ in 0..<40 { last = cached.frequencyBands() }
        XCTAssertTrue(last.allSatisfy { $0 == 0 }, "An old PCM window must decay after playback stops")
    }

    @MainActor func testAudioCallbackDoesNotWaitForDisplaySnapshot() {
        let snapshotLock = NSLock()
        let source = SpectrumSource(lock: snapshotLock)
        source.prepare(format: monoFloatFormat)
        var samples = sineSamples(count: 2048)
        let originalSamples = samples
        let acquired = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            snapshotLock.lock()
            acquired.signal()
            // Release eventually even if the regression makes process block,
            // so the test reports a failure instead of hanging the suite.
            _ = release.wait(timeout: .now() + 2)
            snapshotLock.unlock()
            finished.signal()
        }
        XCTAssertEqual(acquired.wait(timeout: .now() + 2), .success)
        let start = ProcessInfo.processInfo.systemUptime
        feed(&samples, to: source)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)

        XCTAssertLessThan(elapsed, 0.5, "A suspended display snapshot must never hold up the audio callback")
        XCTAssertEqual(samples, originalSamples, "Spectrum analysis must leave the actual playback PCM unchanged")
        XCTAssertTrue(source.frequencyBands().allSatisfy { $0 == 0 }, "A contended visual snapshot should be skipped")
        feed(&samples, to: source)
        XCTAssertTrue(source.frequencyBands().contains { $0 > 0 }, "Sampling must recover on the next audio callback")
    }

    @MainActor func testOversizedCallbackRetainsSameSpectrumAndSubsequentRingOrder() {
        let oversized = SpectrumSource()
        let latestWindow = SpectrumSource()
        oversized.prepare(format: monoFloatFormat)
        latestWindow.prepare(format: monoFloatFormat)
        var samples = sineSamples(count: 6145)
        var tail = Array(samples.suffix(2048))
        feed(&samples, to: oversized)
        feed(&tail, to: latestWindow)
        XCTAssertEqual(oversized.frequencyBands(), latestWindow.frequencyBands(),
                       "Discarded PCM would already have been overwritten in the FFT ring")

        // A non-window-sized update catches cursor/order changes hidden by
        // comparing only a single complete FFT window.
        var continuation = sineSamples(count: 317, start: samples.count)
        feed(&continuation, to: oversized)
        feed(&continuation, to: latestWindow)
        XCTAssertEqual(oversized.frequencyBands(), latestWindow.frequencyBands())
    }

    private var monoFloatFormat: AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    }

    private func sineSamples(count: Int, start: Int = 0) -> [Float] {
        (start..<(start + count)).map { Float(0.01 * sin(2 * Double.pi * 64 * Double($0) / 2048)) }
    }

    private func feed(_ samples: inout [Float], to source: SpectrumSource) {
        samples.withUnsafeMutableBytes { data in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1,
                mDataByteSize: UInt32(data.count), mData: data.baseAddress))
            source.process(&list, frames: data.count / MemoryLayout<Float>.size)
        }
    }

    @MainActor func testWebAudioScalingAndStereoDownmix() {
        let source = SpectrumSource()
        var format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        source.prepare(format: format)
        var samples = [Float](repeating: 0, count: 4096)
        for index in 0..<2048 {
            let value = Float(0.01 * sin(2 * Double.pi * 64 * Double(index) / 2048))
            samples[index * 2] = value
            samples[index * 2 + 1] = value
        }
        // A bin-centered sine through the browser's Blackman window has
        // magnitudes A * [0.02, 0.125, 0.21, 0.125, 0.02].
        var expectedBins = [Double](repeating: 0, count: 1024)
        for (offset, amplitude) in [0.02, 0.125, 0.21, 0.125, 0.02].enumerated() {
            expectedBins[62 + offset] = amplitude * 0.01
        }
        for frame in 1...5 {
            samples.withUnsafeMutableBytes { data in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2,
                    mDataByteSize: UInt32(data.count), mData: data.baseAddress))
                source.process(&list, frames: 2048)
            }
            let bands = source.frequencyBands()
            let gain = 1 - pow(0.72, Double(frame))
            let bytes = expectedBins.map { magnitude -> Double in
                min(255, max(0, floor(255 * (20 * log10(max(magnitude * gain, 1e-20)) + 100) / 70)))
            }
            for band in 0..<112 {
                let from = Int(pow(1023.0, Double(band) / 112))
                let to = max(from + 1, Int(pow(1023.0, Double(band + 1) / 112)))
                let expected = (bytes[from..<to].reduce(0, +) / Double(to - from)).rounded()
                XCTAssertTrue(abs(Double(bands[band]) * 255 - expected) <= 1.01,
                    "Web Audio mismatch at frame \(frame), band \(band)")
            }
        }
        let cancelled = SpectrumSource()
        cancelled.prepare(format: format)
        for index in 0..<2048 { samples[index * 2 + 1] = -samples[index * 2] }
        samples.withUnsafeMutableBytes { data in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2,
                mDataByteSize: UInt32(data.count), mData: data.baseAddress))
            cancelled.process(&list, frames: 2048)
        }
        XCTAssertTrue(cancelled.frequencyBands().allSatisfy { $0 == 0 }, "Stereo must downmix before analysis")
        format.mBitsPerChannel = 24
        cancelled.prepare(format: format)
        print("Web Audio scaling, smoothing, byte averaging, and stereo downmix passed")
    }
}
