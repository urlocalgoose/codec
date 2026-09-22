import SwiftUI
import MetalKit
import WebKit
import XCTest
@testable import Codec

final class WebVisualizerParityTests: XCTestCase {
    @MainActor private var renderTexture: MTLTexture?
    @MainActor private var browser: WKWebView?
    @MainActor private static var sample: ArtworkAtmosphere {
        ArtworkAtmosphere(warm: Color(.sRGB, red: 0.9, green: 0.12, blue: 0.08),
                          cool: Color(.sRGB, red: 0.08, green: 0.2, blue: 0.85),
                          deep: Color(.sRGB, red: 0.03, green: 0.04, blue: 0.09), blurred: UIImage(),
                          spectrumSwatches: [[26,34,44], [205,65,23], [235,196,65], [24,117,173]].map { $0.map { Double($0) / 255 } })
    }

    @MainActor private func rgba(_ color: Color) -> SIMD4<Float> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4(Float(r), Float(g), Float(b), 1)
    }

    @MainActor func testEveryThemePreservesSourceRGBIncludingGrayAndSingleInk() {
        let sources: [[[Double]]] = [
            [[0,0,0]], [[1,1,1]], [[92.0/255,92.0/255,92.0/255]],
            [[32.0/255,72.0/255,120.0/255], [224.0/255,160.0/255,48.0/255]],
            Self.sample.spectrumSwatches
        ]
        for theme in codecThemes {
            for source in sources {
                let sample = ArtworkAtmosphere(warm: .red, cool: .blue, deep: .black,
                                                blurred: UIImage(), spectrumSwatches: source)
                let palette = SpectrumPalette.make(theme: theme, atmosphere: sample)
                let colors = [palette.cool, palette.mid, palette.warm, palette.hot]
                let allowed = source.map { SIMD4<Float>(Float($0[0]), Float($0[1]), Float($0[2]), 1) }
                XCTAssertTrue(colors.allSatisfy { allowed.contains($0) }, "Never recolor artwork: \(theme.id)")
                let expectedCounts = source.count == 1 ? [4] : source.count == 2 ? [2,2] : [1,1,1,1]
                XCTAssertEqual(allowed.map { color in colors.filter { $0 == color }.count }.sorted(), expectedCounts)
                let levels = colors.map { $0.x * 0.2126 + $0.y * 0.7152 + $0.z * 0.0722 }
                XCTAssertEqual(levels, theme.isLight ? levels.sorted(by: >) : levels.sorted(), theme.id)
            }
            let fallback = SpectrumPalette.make(theme: theme, atmosphere: nil)
            let allowed = [rgba(theme.accent), rgba(theme.text)]
            XCTAssertTrue([fallback.cool, fallback.mid, fallback.warm, fallback.hot].allSatisfy { allowed.contains($0) })
        }
    }

    @MainActor func testLegacySamplesUseOnlyTheirOwnColorsAndPreserveBackgroundTint() throws {
        for theme in codecThemes {
            let sample = ArtworkAtmosphere(warm: Self.sample.warm, cool: Self.sample.cool,
                                           deep: Self.sample.deep, blurred: UIImage())
            let palette = SpectrumPalette.make(theme: theme, atmosphere: sample)
            let allowed = [rgba(sample.deep), rgba(sample.cool), rgba(sample.warm)]
            XCTAssertTrue([palette.cool, palette.mid, palette.warm, palette.hot].allSatisfy { allowed.contains($0) })
            let expected = rgba(theme.bg) + (rgba(sample.deep) - rgba(theme.bg)) * 0.16
            for channel in 0..<4 { XCTAssertEqual(palette.bg[channel], expected[channel], accuracy: 0.0001) }
        }
    }

    @MainActor func testArtworkIdentityNeverDisplaysThePreviousSongsSample() throws {
        let url = try XCTUnwrap(URL(string: "https://artwork.invalid/first.png"))
        let first = ArtworkRequest(url: url, authorization: nil)
        let loaded = SpectrumArtworkSample(request: first, atmosphere: Self.sample)
        XCTAssertNotNil(loaded.matching(first))
        XCTAssertNil(loaded.matching(nil))
        XCTAssertNil(loaded.matching(ArtworkRequest(url: url.appendingPathComponent("second.png"), authorization: nil)))
        XCTAssertNil(loaded.matching(ArtworkRequest(url: url, authorization: "other-scope")))
    }

    @MainActor func testRecordedArtworkColorsSurviveNewSongResizeAndRendererRemount() async throws {
        let history = Codec.SpectrumHistory(capacity: 32)
        let theme = codecThemes.first { !$0.isLight }!
        let red = ArtworkAtmosphere(warm: .red, cool: .red, deep: .red, blurred: UIImage(), spectrumSwatches: [[1,0,0]])
        let blue = ArtworkAtmosphere(warm: .blue, cool: .blue, deep: .blue, blurred: UIImage(), spectrumSwatches: [[0,0,1]])
        let view = SpectrumMetalView(history: history, theme: theme, atmosphere: red)
        view.contentScaleFactor = 2
        let column = Array(repeating: Float(1), count: Codec.SpectrumHistory.bands)
        for _ in 0..<32 { history.append(column) }
        let before = try await render(view, width: 83, height: 448)
        view.setAppearance(theme, atmosphere: blue, reduceMotion: false)
        let unchanged = try await render(view, width: 83, height: 448)
        XCTAssertEqual(unchanged, before, "Changing artwork cannot alter recorded inks or their background")
        history.append(column)
        let trail = try await render(view, width: 83, height: 448)
        XCTAssertEqual(Array(trail[(2 * 83 + 82) * 4..<(2 * 83 + 83) * 4]), [255,0,0,255], "Newest blue edge")
        XCTAssertEqual(Array(trail[(2 * 83 + 77) * 4..<(2 * 83 + 78) * 4]), [0,0,255,255], "Previous red trail")
        _ = try await render(view, width: 131, height: 512)
        let resizedBack = try await render(view, width: 83, height: 448)
        XCTAssertEqual(resizedBack, trail)
        let remounted = SpectrumMetalView(history: history, theme: codecThemes.first { $0.isLight }!)
        remounted.contentScaleFactor = 2
        let remountedPixels = try await render(remounted, width: 83, height: 448)
        XCTAssertEqual(remountedPixels, trail, "Tab/theme/fullscreen remount must upload the recorded appearances")
    }

    @MainActor func testPaletteTextureWrapsInStepWithIntensityAndSurvivesFreshRenderer() async throws {
        let history = Codec.SpectrumHistory(capacity: 7)
        let theme = codecThemes.first { !$0.isLight }!
        let view = SpectrumMetalView(history: history, theme: theme)
        view.contentScaleFactor = 2
        let inks: [SIMD4<Float>] = [SIMD4(1,0,0,1), SIMD4(0,0,1,1), SIMD4(0,1,0,1)]
        var expected: [SIMD4<Float>] = []
        var last: [UInt8] = []
        for group in 0..<5 {
            let ink = inks[group % inks.count]
            let palette = SpectrumPalette(bg: ink * 0.1, cool: ink, mid: ink, warm: ink, hot: ink)
            history.setPalette(palette)
            for _ in 0..<4 {
                history.append(Array(repeating: 1, count: Codec.SpectrumHistory.bands))
                expected.append(ink)
            }
            last = try await render(view, width: 35, height: 448)
            let retained = Array(expected.suffix(7))
            for (index, color) in retained.enumerated() {
                let x = 35 - (retained.count - index) * 5 + 2
                let offset = (2 * 35 + x) * 4
                XCTAssertEqual(Array(last[offset..<offset + 4]), [UInt8(color.z * 255), UInt8(color.y * 255), UInt8(color.x * 255), 255])
            }
        }
        let fresh = SpectrumMetalView(history: history, theme: theme)
        fresh.contentScaleFactor = 2
        let reconstructed = try await render(fresh, width: 35, height: 448)
        XCTAssertEqual(reconstructed, last)
    }

    @MainActor func testRootRecordsNewArtworkWhileHomeIsVisibleIncludingCoalescedTrackChanges() async throws {
        let theme = codecThemes.first { !$0.isLight }!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppModel(client: CodecClient(baseURL: URL(string: "https://spectrum-tests.invalid")!))
        let tracks = ["red", "blue"].map { name in
            CodecTrack(id: name, title: name, artist: "", album: "",
                       artworkURL: directory.appendingPathComponent("\(name).png"), fingerprint: name)
        }
        var samples: [ArtworkAtmosphere] = []
        for (index, track) in tracks.enumerated() {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48)).image { context in
                (index == 0 ? UIColor.red : UIColor.blue).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
            }
            try image.pngData()?.write(to: XCTUnwrap(track.artworkURL))
            let request = ArtworkRequest(url: try XCTUnwrap(track.artworkURL), authorization: nil)
            let sample = await ArtworkAtmosphereCache.shared.sample(for: image, key: request.cacheKey)
            samples.append(try XCTUnwrap(sample))
        }
        app.library = CodecLibrary(rootPath: "", scannedAt: 0, stats: .empty,
                                   artists: [], albums: [], playlists: [], tracks: tracks)
        app.connection = .connected
        let player = PlayerController()
        player.resolveTrack = { reference in tracks.first { $0.id == reference.id } }
        func snapshot(_ index: Int, revision: Int) throws -> PlaybackState {
            let reference = CodecTrackReference(track: tracks[index])
            let object: [String: Any] = [
                "schema": "loud.playback.v2", "revision": revision, "active_device_id": "remote",
                "state": "paused", "track": ["id": reference.id, "path": reference.path, "fingerprint": reference.fingerprint],
                "context": [:], "clock": ["position_seconds": 0, "updated_at_ms": 1], "volume": 1, "server_time_ms": 1
            ]
            return try JSONDecoder().decode(PlaybackState.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let configuration = URLSessionConfiguration.ephemeral
        let downloads = DownloadStore(directory: directory.appendingPathComponent("downloads"), configuration: configuration)
        defer { downloads.shutdown(); player.stopSync() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: RootView().environment(app).environment(player).environment(downloads)
            .environment(ThemeStore()).environment(\.codecTheme, theme).preferredColorScheme(.dark))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKeyAndVisible() }
        let history = player.spectrum
        let red = SpectrumPalette.make(theme: theme, atmosphere: samples[0])
        let blue = SpectrumPalette.make(theme: theme, atmosphere: samples[1])
        let fallback = SpectrumPalette.make(theme: theme, atmosphere: nil)
        func awaitPalette(_ palette: SpectrumPalette) async throws {
            for _ in 0..<200 {
                if history.currentPalette == palette { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTFail("Root appearance observer did not finish while Home was visible")
        }
        player.applySyncState(try snapshot(0, revision: 1))
        try await awaitPalette(red)
        history.append([1])
        player.applySyncState(try snapshot(1, revision: 2))
        XCTAssertEqual(history.currentPalette, fallback)
        history.append([1])
        try await awaitPalette(blue)
        history.append([1])
        // SwiftUI can coalesce these into one body pass ending on the same
        // identity. The transition revision must still restart its task.
        player.applySyncState(try snapshot(0, revision: 3))
        player.applySyncState(try snapshot(1, revision: 4))
        XCTAssertEqual(history.currentPalette, fallback)
        try await awaitPalette(blue)
        history.append([1])
        XCTAssertEqual(history.palette(forColumn: 0), red)
        XCTAssertEqual(history.palette(forColumn: 1), fallback)
        XCTAssertEqual(history.palette(forColumn: 2), blue)
        XCTAssertEqual(history.palette(forColumn: 3), blue)
    }

    @MainActor func testLiveDisplayCadence() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let history = Codec.SpectrumHistory()
        history.activate(Codec.SpectrumSource())
        let view = SpectrumMetalView(history: history, theme: codecThemes[0])
        controller.view = view
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(200))
        let start = ContinuousClock.now
        let before = history.count
        try await Task.sleep(for: .seconds(1))
        let frames = history.count - before
        print("LIVE NATIVE DISPLAY: \(frames) frames in \(start.duration(to: .now)), requested \(view.preferredFramesPerSecond) Hz")
        XCTAssertGreaterThanOrEqual(frames, 45)
        XCTAssertTrue(history.samplingFromView)
        view.setActive(false)
        let hiddenCount = history.count
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(view.isPaused, "An obscured surface must stop requesting Metal drawables")
        XCTAssertFalse(history.samplingFromView)
        XCTAssertGreaterThan(history.count, hiddenCount, "Browsing another tab retains spectrum history")
        view.setActive(true)
        let resumedCount = history.count
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(view.isPaused)
        XCTAssertTrue(history.samplingFromView)
        XCTAssertGreaterThan(history.count, resumedCount, "Reopening resumes the display without resetting history")
    }

    @MainActor func testNativePixelsMatchWebCanvas() async throws {
        for light in [false, true] {
            try await assertNativePixelsMatchWebCanvas(theme: codecThemes.first { $0.isLight == light }!, atmosphere: nil)
        }
    }

    @MainActor func testArtworkHeatmapMatchesWebCanvasInDarkAndLightThemes() async throws {
        let sample = Self.sample
        for light in [false, true] {
            try await assertNativePixelsMatchWebCanvas(theme: codecThemes.first { $0.isLight == light }!, atmosphere: sample)
        }
    }

    @MainActor private func assertNativePixelsMatchWebCanvas(theme: CodecTheme, atmosphere: ArtworkAtmosphere?) async throws {
        let history = Codec.SpectrumHistory(capacity: 32)
        var columns: [[UInt8]] = []
        // Start with a wrapped ring, as when returning to the visualizer after
        // browsing another tab. The following 12 frames wrap the upload again.
        for index in 0..<57 {
            let bytes = (0..<112).map { UInt8(($0 * 7 + index * 17) % 256) }
            columns.append(bytes)
            history.append(bytes.map { Float($0) / 255 })
        }
        let web = WKWebView()
        browser = web
        let ready = WebReady()
        try await ready.load(web)
        let view = SpectrumMetalView(history: history, theme: theme, atmosphere: atmosphere)
        view.contentScaleFactor = 2
        for pass in 0..<2 {
            if pass == 1 {
                let retainedCount = history.count
                view.setAppearance(theme, atmosphere: nil, reduceMotion: true)
                view.setAppearance(theme, atmosphere: atmosphere, reduceMotion: true)
                XCTAssertEqual(history.count, retainedCount, "Changing artwork must retain every spectrum column")
                for index in 0..<12 {
                    let bytes = (0..<112).map { UInt8(($0 * 11 + index * 23) % 256) }
                    columns.append(bytes)
                    history.append(bytes.map { Float($0) / 255 })
                }
            }
            let width = 83, height = 448
            let native = try await render(view, width: width, height: height)
            func rgb(_ color: Color) -> [Double] {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
                return [Double(r), Double(g), Double(b)]
            }
            let colorInput: [String: Any] = ["bg": rgb(theme.bg), "accent": rgb(theme.accent), "hot": rgb(theme.text), "light": theme.isLight,
                "sample": atmosphere.map { ["warm": rgb($0.warm), "cool": rgb($0.cool), "deep": rgb($0.deep), "spectrum": $0.spectrumSwatches] } as Any? ?? NSNull()]
            let colorsJSON = String(data: try JSONSerialization.data(withJSONObject: colorInput), encoding: .utf8)!
            let input = String(data: try JSONEncoder().encode(Array(columns.suffix(32))), encoding: .utf8)!
            let script = """
            (() => {
                const canvas = document.createElement('canvas'); canvas.width = \(width); canvas.height = \(height);
                const ctx = canvas.getContext('2d'); const SPECTRO_BANDS = 112; const stepPx = () => 5;
                const input = \(colorsJSON);
                const mix = (a,b,t) => a.map((channel,index)=>channel+(b[index]-channel)*t);
                const css = rgb => `rgb(${rgb.map(channel=>Math.round(Math.max(0,Math.min(1,channel))*255)).join(',')})`;
                const sample=input.sample;
                const brightness=rgb=>rgb[0]*.2126+rgb[1]*.7152+rgb[2]*.0722;
                const source=sample?(sample.spectrum.length?sample.spectrum:[sample.deep,sample.cool,sample.warm]):[input.accent,input.hot];
                const unique=[...new Map(source.map(rgb=>[rgb.join(','),rgb])).values()];
                unique.sort((a,b)=>brightness(a)-brightness(b)||a[0]-b[0]||a[1]-b[1]||a[2]-b[2]);
                if(input.light)unique.reverse();
                const bands=[0,1,2,3].map(i=>unique[Math.round(i*(unique.length-1)/3)]);
                const colors={bg:sample?mix(input.bg,sample.deep,.16):input.bg,
                    cool:bands[0],mid:bands[1],warm:bands[2],hot:bands[3]};
                colors.ink=value=>css(value<64/255?colors.cool:value<128/255?colors.mid:value<204/255?colors.warm:colors.hot);
                colors.bg=css(colors.bg);
                \(Self.webDrawColumn)
                const columns = \(input);
                ctx.fillStyle = colors.bg; ctx.fillRect(0,0,canvas.width,canvas.height);
                columns.forEach((column,index) => drawColumn(canvas.width-(columns.length-index)*5,column));
                return Array.from(ctx.getImageData(0,0,canvas.width,canvas.height).data);
            })()
            """
            let webResult = try await web.evaluateJavaScript(script)
            let expected = try XCTUnwrap(webResult as? [Int])
            XCTAssertEqual(expected.count, native.count)
            var maxError = 0
            var different = 0
            for offset in stride(from: 0, to: native.count, by: 4) {
                for (nativeChannel, webChannel) in [(0, 2), (1, 1), (2, 0), (3, 3)] {
                    let error = abs(Int(native[offset + nativeChannel]) - expected[offset + webChannel])
                    maxError = max(maxError, error)
                    if error > 2 { different += 1 }
                }
            }
            print("WEB/METAL pass \(pass): maximum byte error \(maxError), channels outside tolerance \(different)")
            XCTAssertEqual(different, 0)
        }
    }

    @MainActor func testNativeFramesAndCaptures() async throws {
        let history = Codec.SpectrumHistory()
        for index in 0..<400 {
            history.append((0..<112).map { Float(($0 * 3 + index) % 256) / 255 })
        }
        let theme = codecThemes.first { !$0.isLight }!
        let view = SpectrumMetalView(history: history, theme: theme)
        view.contentScaleFactor = 3
        let start = ContinuousClock.now
        for frame in 0..<120 {
            history.append((0..<112).map { Float(($0 * 7 + frame) % 256) / 255 })
            _ = try await render(view, width: 1206, height: 2622, readback: false)
        }
        print("NATIVE METAL 120 completed full-resolution frames: \(start.duration(to: .now))")
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for light in [false, true] {
            view.setTheme(codecThemes.first { $0.isLight == light }!)
            let bytes = try await render(view, width: 1206, height: 2622)
            let provider = CGDataProvider(data: Data(bytes) as CFData)!
            let image = CGImage(width: 1206, height: 2622, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 1206 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            try XCTUnwrap(UIImage(cgImage: image).pngData()).write(to: directory.appendingPathComponent("metal-\(light ? "light" : "dark").png"))
        }
    }

    @MainActor private func render(_ view: SpectrumMetalView, width: Int, height: Int, readback: Bool = true) async throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        if renderTexture?.width != width || renderTexture?.height != height {
            renderTexture = view.device?.makeTexture(descriptor: descriptor)
        }
        let texture = try XCTUnwrap(renderTexture)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(view.encode(pass: pass, size: CGSize(width: width, height: height)))
        await withCheckedContinuation { continuation in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        XCTAssertNil(command.error)
        guard readback else { return [] }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { data in
            texture.getBytes(data.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return bytes
    }

    // The web drawColumn function, with TypeScript annotations removed by Bun.
    private static let webDrawColumn = """
    function drawColumn(x, values) {
      const height = canvas.height;
      const step = stepPx();
      const cell = height / SPECTRO_BANDS;
      const gap = Math.max(1, Math.floor(cell * 0.22));
      ctx.fillStyle = colors.bg;
      ctx.fillRect(x, 0, step, height);
      for (let band = 0;band < SPECTRO_BANDS; band += 1) {
        const value = values[band] / 255;
        if (value <= 0.02) {
          continue;
        }
        const y = height - (band + 1) * cell;
        ctx.globalAlpha = Math.pow(value, 0.55);
        ctx.fillStyle = colors.ink(value);
        ctx.fillRect(x, y + gap / 2, step, Math.max(1, cell - gap));
      }
      ctx.globalAlpha = 1;
    }
    """
}

@MainActor
private final class WebReady: NSObject, WKNavigationDelegate {
    private var pending: CheckedContinuation<Void, Error>?
    func load(_ web: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            web.navigationDelegate = self
            web.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pending?.resume(); pending = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pending?.resume(throwing: error); pending = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pending?.resume(throwing: error); pending = nil
    }
}
