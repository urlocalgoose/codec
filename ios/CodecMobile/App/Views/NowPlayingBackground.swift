import SwiftUI

/// The original Halo → Color wash → Immersive artwork study, applied only to
/// the Now Playing background. The sharp cover and transport stay independent.
struct NowPlayingBackground: View {
    @Environment(\.codecTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let track: CodecTrack?
    let client: CodecClient?
    var isVisible = true

    @State private var atmosphere: ArtworkAtmosphere?
    @State private var generation = 0
    @State private var stage = 0
    @State private var blend = 0.0
    @State private var fadeDeadline: ContinuousClock.Instant?

    private let styles = ["halo", "wash", "immersive"]
    private var motionAllowed: Bool {
        atmosphere != nil && isVisible && scenePhase == .active && !reduceMotion
    }
    private var animationIdentity: String { "\(generation)-\(motionAllowed)-\(theme.id)" }
    private var request: ArtworkRequest? {
        guard let track, let url = client?.artworkURL(for: track) ?? track.artworkURL else { return nil }
        return ArtworkRequest(url: url, authorization: client?.authHeaders(for: url)["Authorization"])
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                theme.bg
                if let atmosphere {
                    surface(atmosphere, size: geo.size, style: styles[reduceMotion ? 0 : stage])
                    if !reduceMotion {
                        surface(atmosphere, size: geo.size, style: styles[(stage + 1) % styles.count])
                            .opacity(blend)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: request) {
            // Check after loading/sampling: an old request must never
            // replace the current song's colors after a rapid skip.
            let requested = request
            guard let requested else { replaceAtmosphere(nil); return }
            guard !Task.isCancelled else { return }
            let sample = await ArtworkAtmosphereCache.shared.sample(key: requested.cacheKey) {
                await ArtworkLoader.shared.image(for: requested.url, headers: requested.headers)
            }
            guard !Task.isCancelled else { return }
            replaceAtmosphere(sample)
        }
        .task(id: animationIdentity) {
            guard motionAllowed else { return }
            do {
                while !Task.isCancelled {
                    // A brief inactive interval can leave a fade in flight.
                    // Finish its remaining time before swapping layers, rather
                    // than restarting at Halo when a notification disappears.
                    if let deadline = fadeDeadline {
                        try await ContinuousClock().sleep(until: deadline)
                        try Task.checkCancellation()
                        withoutAnimation {
                            stage = (stage + 1) % styles.count
                            blend = 0
                            fadeDeadline = nil
                        }
                    }
                    try await Task.sleep(for: .seconds(2))
                    try Task.checkCancellation()
                    fadeDeadline = .now.advanced(by: .seconds(6))
                    withAnimation(.easeInOut(duration: 6)) { blend = 1 }
                }
            } catch { /* Task lifetime follows visibility, scene, and artwork. */ }
        }
    }

    private func replaceAtmosphere(_ sample: ArtworkAtmosphere?) {
        withoutAnimation {
            atmosphere = sample
            generation += 1
            stage = 0
            blend = 0
            fadeDeadline = nil
        }
    }

    private func withoutAnimation(_ update: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, update)
    }

    private func surface(_ sample: ArtworkAtmosphere, size: CGSize, style: String) -> some View {
        ZStack {
            // Composite each treatment over an opaque theme base BEFORE the
            // incoming opacity, so the midpoint never dips in brightness.
            theme.bg
            treatment(sample, size: size, variant: style)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .compositingGroup()
    }

    @ViewBuilder
    private func treatment(_ sample: ArtworkAtmosphere, size: CGSize, variant: String) -> some View {
        switch variant {
        case "halo":
            ZStack {
                RadialGradient(colors: [sample.warm.opacity(theme.isLight ? 0.58 : 0.7), .clear],
                               center: UnitPoint(x: 0.12, y: 0.19), startRadius: 12, endRadius: size.width * 0.95)
                RadialGradient(colors: [sample.cool.opacity(theme.isLight ? 0.40 : 0.75), .clear],
                               center: UnitPoint(x: 0.90, y: 0.39), startRadius: 8, endRadius: size.width * 0.85)
            }
            .mask(LinearGradient(stops: [.init(color: .white.opacity(0.3), location: 0),
                                        .init(color: .white, location: 0.16),
                                        .init(color: .white, location: 0.42),
                                        .init(color: .clear, location: 0.63)],
                                 startPoint: .top, endPoint: .bottom))
        case "wash":
            LinearGradient(stops: [.init(color: sample.warm, location: 0),
                                   .init(color: sample.warm, location: 0.13),
                                   .init(color: sample.cool, location: 0.49),
                                   .init(color: sample.deep, location: 1)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            .opacity(theme.isLight ? 0.46 : 0.66)
            LinearGradient(stops: [.init(color: theme.bg.opacity(0.03), location: 0),
                                   .init(color: theme.bg.opacity(0.12), location: 0.32),
                                   .init(color: theme.bg.opacity(theme.isLight ? 0.88 : 0.72), location: 0.53),
                                   .init(color: theme.bg, location: theme.isLight ? 0.63 : 0.70)],
                           startPoint: .top, endPoint: .bottom)
        case "immersive":
            Image(uiImage: sample.blurred)
                .resizable().scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
                .opacity(theme.isLight ? 0.64 : 0.84)
            LinearGradient(stops: [.init(color: theme.bg.opacity(theme.isLight ? 0.06 : 0.16), location: 0),
                                   .init(color: theme.bg.opacity(0.10), location: 0.29),
                                   .init(color: theme.bg.opacity(theme.isLight ? 0.88 : 0.62), location: 0.53),
                                   .init(color: theme.bg, location: theme.isLight ? 0.63 : 0.71)],
                           startPoint: .top, endPoint: .bottom)
        default:
            EmptyView()
        }
    }
}
