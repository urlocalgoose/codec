import Accelerate
import AVFoundation
import Foundation
import MediaToolbox
import QuartzCore
import UIKit

struct SpectrumPalette: Equatable, Sendable {
    var bg: SIMD4<Float>
    var cool: SIMD4<Float>
    var mid: SIMD4<Float>
    var warm: SIMD4<Float>
    var hot: SIMD4<Float>
}

struct SpectrumTrackIdentity: Hashable {
    let id: String
    let fingerprint: String
    let artworkURL: URL?

    init(_ track: CodecTrack) {
        id = track.id
        fingerprint = track.fingerprint
        artworkURL = track.artworkURL
    }
}

@MainActor
final class SpectrumHistory {
    nonisolated static let bands = 112
    let capacity: Int
    private(set) var count = 0
    private var buffer: [Float]
    private var textureBytes: [UInt8]
    /// Five RGBA values per column: background, then the four energy inks.
    /// Stored beside the intensity ring so remounts never repaint old songs.
    private var appearances: [SIMD4<Float>]
    private var appearanceRecorded: [Bool]
    private(set) var currentPalette: SpectrumPalette?
    private var fallbackPalette: SpectrumPalette?
    private var trackIdentity: SpectrumTrackIdentity?
    private var appearanceGeneration = 0
    private var appearanceInitialized = false
    private var source: SpectrumSource?
    private var sampler: SpectrumSampler?
    private var clock: SpectrumFrameClock?
    private var sampledColumn = [Float](repeating: 0, count: bands)
    var samplingFromView = false

    init(capacity: Int = 1600) {
        self.capacity = capacity
        buffer = Array(repeating: 0, count: capacity * Self.bands)
        textureBytes = Array(repeating: 0, count: capacity * Self.bands)
        appearances = Array(repeating: .zero, count: capacity * 5)
        appearanceRecorded = Array(repeating: false, count: capacity)
    }

    var oldestIndex: Int { max(0, count - capacity) }

    func append(_ column: [Float]) {
        let row = count % capacity
        let offset = row * Self.bands
        for band in 0..<Self.bands {
            let value = band < column.count ? column[band] : 0
            buffer[offset + band] = value
            textureBytes[offset + band] = value.isFinite ? UInt8((min(1, max(0, value)) * 255).rounded()) : 0
        }
        if let currentPalette { record(currentPalette, at: row) }
        else { appearanceRecorded[row] = false }
        count += 1
    }

    /// Called synchronously with the player mutation, before SwiftUI tasks
    /// get a chance to load the next cover. Metadata-only refreshes do nothing.
    func beginTrack(_ identity: SpectrumTrackIdentity?) {
        guard trackIdentity != identity else { return }
        trackIdentity = identity
        appearanceGeneration += 1
        currentPalette = fallbackPalette
    }

    @discardableResult
    func beginAppearance(for identity: SpectrumTrackIdentity?, fallback: SpectrumPalette) -> Int {
        beginTrack(identity)
        appearanceGeneration += 1
        fallbackPalette = fallback
        setPalette(fallback)
        return appearanceGeneration
    }

    @discardableResult
    func completeAppearance(_ palette: SpectrumPalette, generation: Int) -> Bool {
        guard generation == appearanceGeneration else { return false }
        setPalette(palette)
        return true
    }

    /// Only future appends change. The sole bootstrap exception supports
    /// history recorded before any appearance observer or renderer existed.
    func setPalette(_ palette: SpectrumPalette) {
        currentPalette = palette
        if !appearanceInitialized {
            for index in oldestIndex..<count where !appearanceRecorded[index % capacity] {
                record(palette, at: index % capacity)
            }
            appearanceInitialized = true
        }
    }

    func bootstrapPalette(_ palette: SpectrumPalette) {
        guard currentPalette == nil else { return }
        fallbackPalette = palette
        setPalette(palette)
    }

    func palette(forColumn index: Int) -> SpectrumPalette? {
        guard index >= oldestIndex, index < count, appearanceRecorded[index % capacity] else { return nil }
        let start = (index % capacity) * 5
        return SpectrumPalette(bg: appearances[start], cool: appearances[start + 1], mid: appearances[start + 2],
                               warm: appearances[start + 3], hot: appearances[start + 4])
    }

    private func record(_ palette: SpectrumPalette, at row: Int) {
        let start = row * 5
        appearances[start] = palette.bg
        appearances[start + 1] = palette.cool
        appearances[start + 2] = palette.mid
        appearances[start + 3] = palette.warm
        appearances[start + 4] = palette.hot
        appearanceRecorded[row] = true
    }

    func column(_ index: Int, into out: inout [Float]) {
        let offset = (index % capacity) * Self.bands
        for band in 0..<Self.bands {
            out[band] = buffer[offset + band]
        }
    }

    /// Rows are chronological ring slots, each containing all 112 bands. A
    /// returning renderer can upload the retained history in at most two runs.
    func withUnsafeTextureBytes(_ body: (UnsafeRawBufferPointer) -> Void) {
        textureBytes.withUnsafeBytes(body)
    }

    func withUnsafeAppearanceBytes(_ body: (UnsafeRawBufferPointer) -> Void) {
        appearances.withUnsafeBytes(body)
    }

    func activate(_ source: SpectrumSource, analysisQueue: DispatchQueue? = nil) {
        self.source = source
        sampler = SpectrumSampler(source: source, queue: analysisQueue)
        for band in sampledColumn.indices { sampledColumn[band] = 0 }
        if clock == nil { clock = SpectrumFrameClock(history: self) }
    }

    func isActive(_ source: SpectrumSource) -> Bool { self.source === source }

    func sampleFrame() {
        guard let sampler else { return }
        // Always advance exactly once per display callback. Analysis finishes
        // independently; a busy worker retains the latest completed column.
        sampler.sample(into: &sampledColumn)
        append(sampledColumn)
    }
}

/// One in-flight analysis, with reusable buffers and no main/audio-thread wait.
/// The worker alone owns the FFT state; the short result handoff uses try-lock
/// on the display thread so a suspended worker cannot stall scrolling.
private final class SpectrumSampler: @unchecked Sendable {
    private let source: SpectrumSource
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending = false
    private var latest = [Float](repeating: 0, count: SpectrumHistory.bands)
    private var working = [Float](repeating: 0, count: SpectrumHistory.bands)

    init(source: SpectrumSource, queue: DispatchQueue?) {
        self.source = source
        self.queue = queue ?? DispatchQueue(label: "sh.codie.codec.spectrum-analysis", qos: .userInteractive)
    }

    func sample(into column: inout [Float]) {
        guard lock.try() else { return }
        for band in column.indices { column[band] = latest[band] }
        let shouldStart = !pending
        pending = true
        lock.unlock()
        guard shouldStart else { return }
        queue.async { [self] in
            source.frequencyBands(into: &working)
            lock.lock()
            swap(&latest, &working)
            pending = false
            lock.unlock()
        }
    }
}

@MainActor
private final class SpectrumFrameClock: NSObject {
    private weak var history: SpectrumHistory?
    private var link: CADisplayLink?

    init(history: SpectrumHistory) {
        self.history = history
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        link.isPaused = UIApplication.shared.applicationState == .background
        self.link = link
        NotificationCenter.default.addObserver(self, selector: #selector(background),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foreground),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func background() { link?.isPaused = true }
    @objc private func foreground() { link?.isPaused = false }

    @objc private func tick() {
        guard let history else {
            link?.invalidate()
            link = nil
            return
        }
        // The visible Metal view samples in its own display callback; the
        // clock keeps history populated while other screens are open.
        if !history.samplingFromView { history.sampleFrame() }
    }
}

@MainActor
final class SpectrumAnalyzer {
    private let history: SpectrumHistory

    init(history: SpectrumHistory) { self.history = history }

    func attach(to item: AVPlayerItem) {
        let source = SpectrumSource()
        history.activate(source)
        let history = history
        Task { @MainActor in
            guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first,
                  history.isActive(source) else { return }
            let retained = Unmanaged.passRetained(source)
            var callbacks = MTAudioProcessingTapCallbacks(
                version: kMTAudioProcessingTapCallbacksVersion_0,
                clientInfo: retained.toOpaque(), init: tapInit, finalize: tapFinalize,
                prepare: tapPrepare, unprepare: nil, process: tapProcess
            )
            var tap: MTAudioProcessingTap?
            let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
            guard status == noErr, let tap else {
                retained.release()
                return
            }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            item.audioMix = mix
        }
    }
}

/// The audio callback never waits for the display thread. A busy snapshot is
/// skipped rather than delaying playback. The serial analysis worker owns FFT
/// state; the display thread only consumes the latest completed band values.
final class SpectrumSource {
    private let lock: NSLock
    private var pcm = [Float](repeating: 0, count: 2048)
    private var cursor = 0
    private var updatedAt = -Double.infinity
    private var generation: UInt64 = 0
    private var analysedGeneration: UInt64 = 0
    private var wasSilent = true
    private var format = AudioStreamBasicDescription()
    private var supported = false
    private let fft = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!
    private let window = (0..<2048).map { index in
        let phase = 2 * Double.pi * Double(index) / 2048
        return Float(0.42 - 0.5 * cos(phase) + 0.08 * cos(2 * phase))
    }
    private var real = [Float](repeating: 0, count: 2048)
    private var imaginary = [Float](repeating: 0, count: 2048)
    private var smoothed = [Float](repeating: 0, count: 1024)
    private var magnitudes = [Float](repeating: 0, count: 1024)
    private var bins = [UInt8](repeating: 0, count: 1024)
    private let ranges: [Range<Int>] = (0..<112).map { band in
        let from = Int(pow(1023.0, Double(band) / 112))
        return from..<max(from + 1, Int(pow(1023.0, Double(band + 1) / 112)))
    }

    init(lock: NSLock = NSLock()) { self.lock = lock }

    deinit { vDSP_destroy_fftsetup(fft) }

    func prepare(format: AudioStreamBasicDescription) {
        self.format = format
        let flags = format.mFormatFlags
        supported = format.mFormatID == kAudioFormatLinearPCM &&
            flags & kAudioFormatFlagIsBigEndian == 0 &&
            ((flags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32) ||
             (flags & kAudioFormatFlagIsSignedInteger != 0 && format.mBitsPerChannel == 16))
    }

    func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard supported, frames > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let floatPCM = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bytes = floatPCM ? 4 : 2
        // Screen wakes and notification UI can preempt the display thread
        // while it holds this lock. Audio must not wait for it to run again.
        guard lock.try() else { return }
        defer { lock.unlock() }
        // Only the most recent FFT window survives in the ring. Bound work
        // even when AVFoundation supplies an unusually large audio buffer.
        for frame in max(0, frames - pcm.count)..<frames {
            var sum: Float = 0
            var channels = 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mNumberChannels)
                guard (frame + 1) * count * bytes <= Int(buffer.mDataByteSize) else { continue }
                for channel in 0..<count {
                    let index = frame * count + channel
                    sum += floatPCM ? data.assumingMemoryBound(to: Float.self)[index]
                        : Float(data.assumingMemoryBound(to: Int16.self)[index]) / 32768
                }
                channels += count
            }
            pcm[cursor] = channels > 0 ? sum / Float(channels) : 0
            cursor = (cursor + 1) % 2048
        }
        updatedAt = CACurrentMediaTime()
        generation &+= 1
    }

    func frequencyBands() -> [Float] {
        var output = [Float](repeating: 0, count: 112)
        frequencyBands(into: &output)
        return output
    }

    /// Call from a single consumer. Reusing an unchanged PCM window preserves
    /// per-frame smoothing while avoiding a second FFT of identical samples.
    func frequencyBands(into output: inout [Float]) {
        lock.lock()
        let silent = CACurrentMediaTime() - updatedAt > 0.1
        let transform = !silent && (wasSilent || analysedGeneration != generation)
        if transform {
            for index in 0..<2048 { real[index] = pcm[(cursor + index) % 2048] }
        }
        analysedGeneration = generation
        lock.unlock()
        if transform {
            real.withUnsafeMutableBufferPointer { r in
                window.withUnsafeBufferPointer { w in
                    vDSP_vmul(r.baseAddress!, 1, w.baseAddress!, 1, r.baseAddress!, 1, 2048)
                }
                imaginary.withUnsafeMutableBufferPointer { i in
                    vDSP_vclr(i.baseAddress!, 1, 2048)
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    vDSP_fft_zip(fft, &split, 1, 11, FFTDirection(FFT_FORWARD))
                }
            }
            for bin in 0..<1024 { magnitudes[bin] = hypot(real[bin], imaginary[bin]) / 2048 }
        } else if silent && !wasSilent {
            vDSP_vclr(&magnitudes, 1, 1024)
        }
        wasSilent = silent
        // Match AnalyserNode: normalize FFT, smooth each linear bin, then
        // convert to byte dB values before the web sampler averages bands.
        for bin in 0..<1024 {
            smoothed[bin] = smoothed[bin] * 0.72 + magnitudes[bin] * 0.28
            if smoothed[bin] <= 1e-5 { bins[bin] = 0; continue }
            let db = 20 * log10(max(smoothed[bin], 1e-20))
            bins[bin] = UInt8(min(255, max(0, floor(255 * (db + 100) / 70))))
        }
        for (band, range) in ranges.enumerated() {
            let sum = range.reduce(0) { $0 + Int(bins[$1]) }
            output[band] = Float((Double(sum) / Double(range.count)).rounded()) / 255
        }
    }
}

private func tapInit(tap: MTAudioProcessingTap, clientInfo: UnsafeMutableRawPointer?, tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    tapStorageOut.pointee = clientInfo
}

private func tapPrepare(tap: MTAudioProcessingTap, maxFrames: CMItemCount, processingFormat: UnsafePointer<AudioStreamBasicDescription>) {
    Unmanaged<SpectrumSource>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format: processingFormat.pointee)
}

private func tapFinalize(tap: MTAudioProcessingTap) {
    Unmanaged<SpectrumSource>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private func tapProcess(tap: MTAudioProcessingTap, numberFrames: CMItemCount, flags: MTAudioProcessingTapFlags, bufferListInOut: UnsafeMutablePointer<AudioBufferList>, numberFramesOut: UnsafeMutablePointer<CMItemCount>, flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
    guard status == noErr else { return }
    Unmanaged<SpectrumSource>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().process(bufferListInOut, frames: Int(numberFramesOut.pointee))
}
