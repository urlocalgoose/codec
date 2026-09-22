import AVFoundation
import Darwin
import Network
import QuartzCore
import SwiftUI
import UIKit
import XCTest
@testable import Codec

/// Opt-in, app-hosted comparison harness. Uses only loopback fixture traffic,
/// isolated downloads, generated artwork and synthetic PCM. Simulator frame
/// cadence is evidence about this workload, not a physical iPhone FPS claim.
@MainActor
final class NativeScrollPerformanceTests: XCTestCase {
    func testLargeLibraryScrollingAndVisualizer() async throws {
        guard ProcessInfo.processInfo.environment["CODEC_RUN_SCROLL_PERFORMANCE"] == "1" else {
            throw XCTSkip("Opt in with CODEC_RUN_SCROLL_PERFORMANCE=1 on a dedicated simulator.")
        }
        let label = ProcessInfo.processInfo.environment["CODEC_PERF_LABEL"] ?? "unlabelled"
        let preferences = UserDefaults.standard
        let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let saved = preferences.persistentDomain(forName: domain)
        defer {
            if let saved { preferences.setPersistentDomain(saved, forName: domain) }
            else { preferences.removePersistentDomain(forName: domain) }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-scroll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try await ScrollArtworkServer.start(images: makeImages())
        defer { server.stop() }
        let audio = directory.appendingPathComponent("fixture.wav")
        try makeSilentWAV().write(to: audio)
        let tracks = (0..<1_888).map { index in
            CodecTrack(id: "perf-\(index)", title: String(format: "Song %04d", index),
                       artist: "Artist \(index % 97)", album: "Album \(index % 96)",
                       durationSeconds: 300,
                       artworkURL: server.baseURL.appendingPathComponent("art/\(index % 96).jpg"),
                       audioURL: index == 1_887 ? server.baseURL.appendingPathComponent("slow.wav") : audio,
                       fingerprint: "performance:\(index)")
        }
        let playlists = (0..<28).map { index in
            CodecPlaylist(id: "playlist-\(index)", name: "Playlist \(index + 1)",
                          trackIDs: index == 0 ? tracks.map(\.id) : tracks.enumerated().filter { $0.offset % 28 == index }.map { $0.element.id },
                          isLiked: false)
        }
        let app = AppModel(client: CodecClient(baseURL: server.baseURL))
        app.activeAuxIsGuest = false
        app.activeAuxCode = ""
        app.connection = .connected
        app.library = CodecLibrary(rootPath: "isolated-performance-fixture", scannedAt: 0, stats: .empty,
                                   artists: [], albums: [], playlists: playlists, tracks: tracks)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let downloads = DownloadStore(directory: directory.appendingPathComponent("downloads"), configuration: configuration)
        defer { downloads.shutdown() }
        let engine = ScrollPlayerStub()
        let player = PlayerController(makePlayer: { _ in engine }, activateAudioSession: {})
        player.client = app.client
        player.downloads = downloads
        player.play(tracks[0], from: tracks)
        defer { player.pausePlayback(); player.stopSync() }
        // Allow the real player's asynchronous tap setup to finish before the
        // fixture supplies its own live PCM source to the same history path.
        try await Task.sleep(for: .milliseconds(300))
        let pcm = ScrollPCMSource()
        player.spectrum.activate(pcm.source)
        pcm.start()
        defer { pcm.stop() }
        downloads.download(tracks[1_887], using: try XCTUnwrap(app.client))

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = .dark
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKeyAndVisible() }
        let scenarios: [(String, AnyView, Bool)] = [
            ("library", AnyView(LibraryView()), true),
            ("songs", AnyView(NavigationStack { TrackListView(title: "Songs", tracks: tracks) }), true),
            ("playlist", AnyView(NavigationStack { PlaylistDetailView(playlistID: "playlist-0") }), true),
            ("search", AnyView(SearchView()), true),
            ("home", AnyView(HomeView()), false),
            ("visualizer", AnyView(VisualizerView(isFullscreen: .constant(false))), false)
        ]
        var reports: [[String: Any]] = []
        for (name, content, mustScroll) in scenarios {
            let host = UIHostingController(rootView: content.environment(app).environment(player).environment(downloads)
                .environment(ThemeStore()).environment(\.codecTheme, CodecTheme.fallback)
                .environment(\.openNowPlaying, {}).environment(\.scenePhase, .active).preferredColorScheme(.dark))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(1_000))
            if name == "visualizer" {
                let renderer = try XCTUnwrap(descendants(in: host.view).compactMap { $0 as? SpectrumMetalView }.first)
                XCTAssertNotNil(renderer.window, "The actual Metal renderer must be mounted")
                XCTAssertFalse(renderer.isPaused, "Paused rendering is not a valid performance comparison")
            }
            let scrolls = scrollViews(in: host.view)
            let scroll = scrolls.filter { $0.bounds.height > 200 && $0.contentSize.height > $0.bounds.height + 100 }
                .max { $0.contentSize.height < $1.contentSize.height }
            if mustScroll { XCTAssertNotNil(scroll, "\(name) must exercise an actual scrollable native list") }
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "\(label)-\(name)-layout"
            attachment.lifetime = .keepAlways
            add(attachment)

            let startColumns = player.spectrum.count
            let recorder = ScrollFrameRecorder(scrollView: scroll) { elapsed in
                // The production controller receives this callback four times
                // per second. Keep identical clock pressure in both builds.
                player.handlePlaybackTick(CMTime(seconds: elapsed, preferredTimescale: 600), from: engine)
            }
            recorder.start()
            try await Task.sleep(for: .seconds(6))
            var report = recorder.stop()
            report["scenario"] = name
            report["label"] = label
            report["spectrum_columns"] = player.spectrum.count - startColumns
            report["artwork_requests_total"] = server.artworkRequests
            report["track_count"] = tracks.count
            report["playlist_count"] = playlists.count
            report["scroll_view_class"] = scroll.map { String(describing: type(of: $0)) } ?? "none"
            report["scroll_content_height"] = scroll?.contentSize.height ?? 0
            report["viewport_height"] = scroll?.bounds.height ?? 0
            reports.append(report)
            XCTAssertGreaterThan(recorder.frameCount, 30, "Display link must run for a meaningful sample")
            XCTAssertGreaterThan(player.spectrum.count, startColumns, "Synthetic PCM must exercise active spectrum history")
            if mustScroll { XCTAssertGreaterThan(recorder.distance, 500, "Real content must move during measurement") }
        }
        let result: [String: Any] = [
            "label": label, "platform": "iOS Simulator", "configuration": "Release -O; app-hosted XCTest",
            "limitations": "Programmatic native scroll; simulator cadence is not physical iPhone FPS. Generated 640px JPEGs use loopback HTTP. One slow download and active synthetic PCM run throughout. Main-thread CPU excludes background FFT/decode; process CPU includes it.",
            "reports": reports
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "\(label)-native-scroll-performance"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("NATIVE_SCROLL_PERFORMANCE_JSON " + String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func descendants(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants(in: $0) }
    }

    private func makeImages() -> [Data] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return (0..<96).map { index in
            UIGraphicsImageRenderer(size: CGSize(width: 640, height: 640), format: format).image { context in
                UIColor(hue: CGFloat(index) / 96, saturation: 0.75, brightness: 0.75, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
                for stripe in 0..<24 {
                    UIColor(white: CGFloat(stripe % 4) / 4, alpha: 0.3).setFill()
                    context.fill(CGRect(x: stripe * 28, y: 0, width: 13, height: 640))
                }
            }.jpegData(compressionQuality: 0.88)!
        }
    }

    private func makeSilentWAV() -> Data {
        let samples = Data(count: 16_000)
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + samples.count)); data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(8_000))
        append(UInt32(16_000)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: "data".utf8); append(UInt32(samples.count)); data.append(samples)
        return data
    }
}

@MainActor
private final class ScrollFrameRecorder: NSObject {
    private weak var scrollView: UIScrollView?
    private let playbackTick: (Double) -> Void
    private var link: CADisplayLink?
    private var started: Double = 0
    private var lastFrame: Double?
    private var lastPlaybackTick = -Double.infinity
    private var intervals: [Double] = []
    private var callbacks: [Double] = []
    private var startCPU = 0.0
    private var startMainCPU = 0.0
    private var direction = 1.0
    private(set) var distance = 0.0
    var frameCount: Int { intervals.count }

    init(scrollView: UIScrollView?, playbackTick: @escaping (Double) -> Void) {
        self.scrollView = scrollView
        self.playbackTick = playbackTick
    }

    func start() {
        started = CACurrentMediaTime()
        startCPU = cpu(CLOCK_PROCESS_CPUTIME_ID)
        startMainCPU = cpu(CLOCK_THREAD_CPUTIME_ID)
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func frame(_ link: CADisplayLink) {
        let begin = CACurrentMediaTime()
        let elapsed = begin - started
        let delta = lastFrame.map { begin - $0 } ?? (1 / 60)
        if lastFrame != nil { intervals.append(delta * 1_000) }
        lastFrame = begin
        if let scrollView {
            let minimum = -scrollView.adjustedContentInset.top
            let maximum = max(minimum, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
            let previous = scrollView.contentOffset.y
            let proposed = previous + direction * 720 * min(delta, 0.1)
            let next = min(maximum, max(minimum, proposed))
            if next >= maximum { direction = -1 }
            else if next <= minimum { direction = 1 }
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: next), animated: false)
            distance += abs(next - previous)
        }
        if elapsed - lastPlaybackTick >= 0.25 {
            playbackTick(elapsed)
            lastPlaybackTick = elapsed
        }
        callbacks.append((CACurrentMediaTime() - begin) * 1_000)
    }

    func stop() -> [String: Any] {
        link?.invalidate(); link = nil
        let elapsed = CACurrentMediaTime() - started
        let mainCPU = cpu(CLOCK_THREAD_CPUTIME_ID) - startMainCPU
        let processCPU = cpu(CLOCK_PROCESS_CPUTIME_ID) - startCPU
        return [
            "duration_seconds": elapsed, "frames": intervals.count, "cadence_hz": Double(intervals.count) / elapsed,
            "frame_p50_ms": percentile(intervals, 0.5), "frame_p95_ms": percentile(intervals, 0.95),
            "frame_max_ms": intervals.max() ?? 0, "intervals_over_33ms": intervals.filter { $0 > 33.34 }.count,
            "intervals_over_50ms": intervals.filter { $0 > 50 }.count,
            "main_thread_cpu_ms": mainCPU * 1_000, "main_thread_cpu_percent_one_core": mainCPU / elapsed * 100,
            "process_cpu_ms": processCPU * 1_000, "process_cpu_percent_one_core": processCPU / elapsed * 100,
            "driver_callback_p95_ms": percentile(callbacks, 0.95), "scroll_distance_points": distance
        ]
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }

    private func cpu(_ clock: clockid_t) -> Double {
        precondition(Thread.isMainThread)
        var value = timespec()
        precondition(clock_gettime(clock, &value) == 0)
        return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
    }
}

private final class ScrollPlayerStub: AVPlayer, @unchecked Sendable {
    nonisolated override func play() {}
    nonisolated override func pause() {}
}

private final class ScrollPCMSource: @unchecked Sendable {
    let source = SpectrumSource()
    private let queue = DispatchQueue(label: "codec.performance.pcm", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var samples = (0..<2_048).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000) * 0.6) }

    init() {
        source.prepare(format: AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0))
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.samples.withUnsafeMutableBytes { data in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(data.count), mData: data.baseAddress))
                self.source.process(&list, frames: 2_048)
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() { timer?.cancel(); timer = nil }
}

private final class ScrollArtworkServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "codec.performance.http")
    private let images: [Data]
    private let lock = NSLock()
    private var count = 0
    private var connections: [NWConnection] = []
    var artworkRequests: Int { lock.withLock { count } }
    var baseURL: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")! }

    private init(images: [Data]) throws {
        self.images = images
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start(images: [Data]) async throws -> ScrollArtworkServer {
        let fixture = try ScrollArtworkServer(images: images)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            fixture.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: fixture.listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): fixture.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            fixture.listener.newConnectionHandler = { [weak fixture] in fixture?.respond(to: $0) }
            fixture.listener.start(queue: fixture.queue)
        }
        return fixture
    }

    func stop() {
        listener.cancel()
        queue.async { self.connections.forEach { $0.cancel() }; self.connections.removeAll() }
    }

    private func respond(to connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            if path.contains("slow.wav") {
                let length = 256 * 1_024 * 1_024
                let header = "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
                    if error == nil { self?.sendSlowChunk(connection, remaining: length) }
                })
            } else {
                self.lock.withLock { self.count += 1 }
                let index = Int(path.split(separator: "/").last?.split(separator: ".").first ?? "0") ?? 0
                let body = self.images[index % self.images.count]
                let header = "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func sendSlowChunk(_ connection: NWConnection, remaining: Int) {
        guard remaining > 0 else { connection.cancel(); return }
        let size = min(16_384, remaining)
        connection.send(content: Data(repeating: 1, count: size), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return }
            self.queue.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
                self?.sendSlowChunk(connection, remaining: remaining - size)
            }
        })
    }
}
