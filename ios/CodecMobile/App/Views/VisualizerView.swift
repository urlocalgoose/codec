import MetalKit
import SwiftUI

struct VisualizerView: View {
    @Environment(\.codecTheme) private var theme
    @Environment(PlayerController.self) private var player
    @Environment(\.scenePhase) private var scenePhase

    @Binding var isFullscreen: Bool
    var isActive = true
    var body: some View {
        ZStack {
            SpectrumSurface(history: player.spectrum, theme: theme, isActive: isActive && scenePhase == .active)
            if player.currentTrack == nil {
                Text("Play something to see it.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.subtle)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: isFullscreen ? 0 : 14, style: .continuous))
        .overlay {
            if !isFullscreen {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea(.container, edges: isFullscreen ? .all : [])
        .overlay(alignment: .topTrailing) {
            Button {
                isFullscreen.toggle()
            } label: {
                Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .frame(width: 44, height: 44)
                    .background(theme.bg.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFullscreen ? "Exit full screen" : "Full screen")
            .accessibilityIdentifier("visualizer.fullscreen")
            .keyboardShortcut(isFullscreen ? .escape : "f", modifiers: isFullscreen ? [] : .command)
            .padding(14)
        }
        .padding(.horizontal, isFullscreen ? 0 : 12)
        .padding(.vertical, isFullscreen ? 0 : 6)
        .background(theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(isFullscreen ? .hidden : .visible, for: .tabBar)
        .statusBarHidden(isFullscreen)
    }
}

/// Lives at the app root, so Home, sheets and tab remounts keep recording
/// the right song's colors even when there is no Metal view on screen.
struct SpectrumAppearanceObserver: View {
    @Environment(\.codecTheme) private var theme
    @Environment(PlayerController.self) private var player
    @Environment(AppModel.self) private var app
    @State private var loaded: SpectrumArtworkSample?

    private struct Identity: Hashable {
        let track: SpectrumTrackIdentity?
        let request: ArtworkRequest?
        let themeID: String
        let trackRevision: Int
    }

    private var identity: Identity {
        let track = player.currentTrack
        let url = track.flatMap { app.client?.artworkURL(for: $0) ?? $0.artworkURL }
        let request = url.map { ArtworkRequest(url: $0, authorization: app.client?.authHeaders(for: $0)["Authorization"]) }
        return Identity(track: track.map(SpectrumTrackIdentity.init), request: request,
                        themeID: theme.id, trackRevision: player.spectrumTrackRevision)
    }

    var body: some View {
        let requested = identity
        let requestedTheme = theme
        Color.clear.frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .task(id: requested) {
                guard !Task.isCancelled, identity == requested else { return }
                let history = player.spectrum
                let generation = history.beginAppearance(for: requested.track,
                    fallback: SpectrumPalette.make(theme: requestedTheme, atmosphere: nil))
                guard let request = requested.request else { loaded = nil; return }
                if let cached = loaded?.matching(request) {
                    history.completeAppearance(SpectrumPalette.make(theme: requestedTheme, atmosphere: cached), generation: generation)
                    return
                }
                loaded = nil
                let sample = await ArtworkAtmosphereCache.shared.sample(key: request.cacheKey) {
                    await ArtworkLoader.shared.image(for: request.url, headers: request.headers)
                }
                guard !Task.isCancelled, identity == requested, let sample else { return }
                if history.completeAppearance(SpectrumPalette.make(theme: requestedTheme, atmosphere: sample), generation: generation) {
                    loaded = SpectrumArtworkSample(request: request, atmosphere: sample)
                }
            }
    }
}

private struct SpectrumSurface: UIViewRepresentable {
    let history: SpectrumHistory
    let theme: CodecTheme
    let isActive: Bool

    func makeUIView(context: Context) -> SpectrumMetalView {
        let view = SpectrumMetalView(history: history, theme: theme)
        view.setActive(isActive)
        return view
    }

    func updateUIView(_ view: SpectrumMetalView, context: Context) {
        view.setActive(isActive)
    }

    static func dismantleUIView(_ view: SpectrumMetalView, coordinator: ()) {
        view.setActive(false)
    }
}

/// A mismatched identity never displays the previous song while loading.
struct SpectrumArtworkSample {
    let request: ArtworkRequest
    let atmosphere: ArtworkAtmosphere

    func matching(_ request: ArtworkRequest?) -> ArtworkAtmosphere? {
        self.request == request ? atmosphere : nil
    }
}

/// Bands use source colors verbatim. Brightness controls their order, never
/// their hue, saturation, or lightness; fewer source inks simply repeat.
extension SpectrumPalette {
    @MainActor static func make(theme: CodecTheme, atmosphere: ArtworkAtmosphere?) -> SpectrumPalette {
        func rgb(_ color: Color) -> [Double] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            return [Double(r), Double(g), Double(b)]
        }
        func vector(_ rgb: [Double]) -> SIMD4<Float> {
            SIMD4(Float(rgb[0]), Float(rgb[1]), Float(rgb[2]), 1)
        }
        func brightness(_ rgb: [Double]) -> Double {
            rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
        }
        let themeBG = vector(rgb(theme.bg))
        let bg = atmosphere.map { themeBG + (vector(rgb($0.deep)) - themeBG) * 0.16 } ?? themeBG
        let source: [[Double]]
        if let atmosphere {
            source = atmosphere.spectrumSwatches.isEmpty
                ? [rgb(atmosphere.deep), rgb(atmosphere.cool), rgb(atmosphere.warm)]
                : atmosphere.spectrumSwatches
        } else {
            source = [rgb(theme.accent), rgb(theme.text)]
        }
        var unique: [[Double]] = []
        for color in source where !unique.contains(color) { unique.append(color) }
        var ordered = unique.sorted {
            let left = brightness($0), right = brightness($1)
            return left == right ? $0.lexicographicallyPrecedes($1) : left < right
        }
        if theme.isLight { ordered.reverse() }
        let colors = (0..<4).map { index in
            vector(ordered[Int((Double(index * (ordered.count - 1)) / 3).rounded())])
        }
        return SpectrumPalette(bg: bg, cool: colors[0], mid: colors[1], warm: colors[2], hot: colors[3])
    }
}

final class SpectrumMetalView: MTKView, MTKViewDelegate {
    let history: SpectrumHistory
    private let commands: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let spectrum: MTLTexture
    private let appearances: MTLTexture
    private var uploaded = 0
    private var palette: SpectrumPalette
    private var themeID: String
    private var atmosphere: ArtworkAtmosphere?
    private var active = true
    /// Shared opacity lookup, independent of artwork and recorded columns.
    private static let opacities: [Float] = (0...255).map { pow(Float($0) / 255, Float(0.55)) }
    // Tab/view recreation must not compile the same shader again on the main
    // thread. Every spectrum surface uses this device and immutable pipeline.
    private static let resources: (MTLDevice, MTLRenderPipelineState) = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            preconditionFailure("Metal is required for the spectrum renderer")
        }
        let library = try! device.makeLibrary(source: shader, options: nil)
        let render = MTLRenderPipelineDescriptor()
        render.vertexFunction = library.makeFunction(name: "spectrumVertex")
        render.fragmentFunction = library.makeFunction(name: "spectrumFragment")
        render.colorAttachments[0].pixelFormat = .bgra8Unorm
        return (device, try! device.makeRenderPipelineState(descriptor: render))
    }()

    init(history: SpectrumHistory, theme: CodecTheme, atmosphere: ArtworkAtmosphere? = nil) {
        let (device, pipeline) = Self.resources
        guard let commands = device.makeCommandQueue() else {
            preconditionFailure("Metal is required for the spectrum renderer")
        }
        self.history = history
        self.commands = commands
        self.pipeline = pipeline
        let initialPalette = SpectrumPalette.make(theme: theme, atmosphere: atmosphere)
        self.palette = initialPalette
        history.bootstrapPalette(initialPalette)
        self.themeID = theme.id
        self.atmosphere = atmosphere
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
            width: SpectrumHistory.bands, height: history.capacity, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        spectrum = device.makeTexture(descriptor: descriptor)!
        let appearanceDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
            width: 5, height: history.capacity, mipmapped: false)
        appearanceDescriptor.storageMode = .shared
        appearanceDescriptor.usage = .shaderRead
        appearances = device.makeTexture(descriptor: appearanceDescriptor)!
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        autoResizeDrawable = true
        isOpaque = true
        delegate = self
        isPaused = true
    }

    required init(coder: NSCoder) { fatalError("Use init(history:theme:)") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateActivity()
        if let screen = window?.screen {
            contentScaleFactor = screen.scale
            preferredFramesPerSecond = screen.maximumFramesPerSecond
        }
    }

    func setActive(_ active: Bool) {
        self.active = active
        updateActivity()
    }

    private func updateActivity() {
        let visible = active && window != nil
        history.samplingFromView = visible
        isPaused = !visible
    }

    func setTheme(_ theme: CodecTheme) {
        setAppearance(theme, atmosphere: atmosphere, reduceMotion: true)
    }

    func setAppearance(_ theme: CodecTheme, atmosphere: ArtworkAtmosphere?, reduceMotion _: Bool) {
        palette = SpectrumPalette.make(theme: theme, atmosphere: atmosphere)
        history.setPalette(palette)
        themeID = theme.id
        self.atmosphere = atmosphere
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard active, window != nil else { return }
        history.sampleFrame()
        guard let drawable = currentDrawable, let pass = currentRenderPassDescriptor,
              let command = encode(pass: pass, size: drawableSize) else { return }
        command.present(drawable)
        command.commit()
    }

    func encode(pass: MTLRenderPassDescriptor, size: CGSize) -> MTLCommandBuffer? {
        let end = history.count
        let first = max(uploaded, history.oldestIndex)
        let pending = end - first
        if pending > 0 {
            let row = first % history.capacity
            let contiguous = min(pending, history.capacity - row)
            history.withUnsafeTextureBytes { data in
                spectrum.replace(region: MTLRegionMake2D(0, row, SpectrumHistory.bands, contiguous),
                    mipmapLevel: 0, withBytes: data.baseAddress!.advanced(by: row * SpectrumHistory.bands),
                    bytesPerRow: SpectrumHistory.bands)
                if contiguous < pending {
                    spectrum.replace(region: MTLRegionMake2D(0, 0, SpectrumHistory.bands, pending - contiguous),
                        mipmapLevel: 0, withBytes: data.baseAddress!, bytesPerRow: SpectrumHistory.bands)
                }
            }
            history.withUnsafeAppearanceBytes { data in
                let stride = 5 * MemoryLayout<SIMD4<Float>>.stride
                appearances.replace(region: MTLRegionMake2D(0, row, 5, contiguous), mipmapLevel: 0,
                    withBytes: data.baseAddress!.advanced(by: row * stride), bytesPerRow: stride)
                if contiguous < pending {
                    appearances.replace(region: MTLRegionMake2D(0, 0, 5, pending - contiguous), mipmapLevel: 0,
                        withBytes: data.baseAddress!, bytesPerRow: stride)
                }
            }
        }
        uploaded = end
        guard let command = commands.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        let step = max(2, Int((2.4 * contentScaleFactor).rounded()))
        let colors = history.currentPalette ?? palette
        var uniforms = SpectrumUniforms(bg: colors.bg,
            dimensions: SIMD4(UInt32(size.width), UInt32(size.height), UInt32(truncatingIfNeeded: end), UInt32(step)))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(spectrum, index: 0)
        encoder.setFragmentTexture(appearances, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SpectrumUniforms>.stride, index: 0)
        Self.opacities.withUnsafeBytes { data in
            encoder.setFragmentBytes(data.baseAddress!, length: data.count, index: 1)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return command
    }

    private struct SpectrumUniforms {
        var bg: SIMD4<Float>
        var dimensions: SIMD4<UInt32>
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Palette { float4 bg; uint4 dimensions; };
    vertex float4 spectrumVertex(uint id [[vertex_id]]) {
        const float2 vertices[] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
        return float4(vertices[id], 0, 1);
    }
    fragment float4 spectrumFragment(float4 pixel [[position]],
        texture2d<float, access::read> spectrum [[texture(0)]],
        texture2d<float, access::read> appearances [[texture(1)]], constant Palette &p [[buffer(0)]],
        constant float *opacities [[buffer(1)]]) {
        uint age = (p.dimensions.x - 1 - uint(pixel.x)) / p.dimensions.w;
        if (age >= min(p.dimensions.z, spectrum.get_height())) return p.bg;
        uint row = (p.dimensions.z - 1 - age) % spectrum.get_height();
        float4 background = appearances.read(uint2(0, row));
        float cell = float(p.dimensions.y) / 112.0;
        uint band = min(111u, uint((float(p.dimensions.y) - pixel.y) / cell));
        float value = spectrum.read(uint2(band, row)).r;
        if (value <= 0.02) return background;
        float gap = max(1.0, floor(cell * 0.22));
        float top = float(p.dimensions.y) - float(band + 1) * cell + gap / 2;
        float bottom = top + max(1.0, cell - gap);
        float coverage = clamp(min(pixel.y + 0.5, bottom) - max(pixel.y - 0.5, top), 0.0, 1.0);
        uint byte = uint(value * 255.0 + 0.5);
        uint inkIndex = byte < 64 ? 1 : byte < 128 ? 2 : byte < 204 ? 3 : 4;
        float4 ink = appearances.read(uint2(inkIndex, row));
        return float4(mix(background.rgb, ink.rgb, opacities[byte] * coverage), 1.0);
    }
    """
}
