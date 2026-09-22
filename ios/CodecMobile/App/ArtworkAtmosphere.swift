import CoreImage
import SwiftUI
import UIKit

/// A small, immutable rendering input. Full-resolution artwork never participates
/// in the background animation or gets blurred on the display thread.
struct ArtworkAtmosphere: Sendable {
    let warm: Color
    let cool: Color
    let deep: Color
    let blurred: UIImage
    /// Actual sampled RGB pixels, independent of the background's averaged colors.
    let spectrumSwatches: [[Double]]

    init(warm: Color, cool: Color, deep: Color, blurred: UIImage, spectrumSwatches: [[Double]] = []) {
        self.warm = warm
        self.cool = cool
        self.deep = deep
        self.blurred = blurred
        self.spectrumSwatches = spectrumSwatches
    }

    private static let blurContext = CIContext(options: [.cacheIntermediates: false])

    nonisolated static func make(_ image: UIImage) -> ArtworkAtmosphere? {
        guard !Task.isCancelled, let original = image.cgImage else { return nil }
        let side = 48
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(original, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        var points: [[Double]] = []
        points.reserveCapacity(side * side)
        for index in stride(from: 0, to: side * side * 4, by: 4) {
            let alpha = Double(pixels[index + 3])
            // Transparent artwork should neither introduce a black palette nor
            // turn a translucent color into its dark, premultiplied counterpart.
            guard alpha > 0 else { continue }
            points.append([
                Double(pixels[index]) / alpha,
                Double(pixels[index + 1]) / alpha,
                Double(pixels[index + 2]) / alpha
            ])
        }
        guard !points.isEmpty else { return nil }

        // Retain the original study's deterministic six-color, ten-pass palette.
        // For opaque artwork these are the exact same 48 × 48 sample indices.
        var centers = [0, 200, 600, 1100, 1700, 2200].map {
            points[min(points.count - 1, $0 * points.count / (side * side))]
        }
        for _ in 0..<10 {
            guard !Task.isCancelled else { return nil }
            var sums = Array(repeating: [0.0, 0.0, 0.0], count: centers.count)
            var counts = Array(repeating: 0, count: centers.count)
            for point in points {
                let nearest = centers.indices.min {
                    distance(point, centers[$0]) < distance(point, centers[$1])
                }!
                for channel in 0..<3 { sums[nearest][channel] += point[channel] }
                counts[nearest] += 1
            }
            for index in centers.indices where counts[index] > 0 {
                centers[index] = sums[index].map { $0 / Double(counts[index]) }
            }
        }

        let warm = centers.max { ($0[0] - $0[2]) < ($1[0] - $1[2]) }!
        let cool = centers.max { ($0[2] - $0[0]) < ($1[2] - $1[0]) }!
        let deep = centers.min { $0.reduce(0, +) < $1.reduce(0, +) }!
        guard !Task.isCancelled, let tiny = context.makeImage() else { return nil }
        let source = CIImage(cgImage: tiny)
        let blurred = source.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 7.0])
            .cropped(to: source.extent)
        guard let blurImage = blurContext.createCGImage(blurred, from: source.extent) else { return nil }
        return ArtworkAtmosphere(
            warm: color(warm), cool: color(cool), deep: color(deep),
            blurred: UIImage(cgImage: blurImage), spectrumSwatches: extractSpectrumSwatches(from: points)
        )
    }

    /// Histogram means choose a representative pixel; they never become colors
    /// themselves. Thus a gray or single-ink cover cannot invent another hue.
    nonisolated static func extractSpectrumSwatches(from points: [[Double]]) -> [[Double]] {
        guard !points.isEmpty else { return [] }
        var bins: [Int: [[Int]]] = [:]
        for point in points {
            guard point.count >= 3, point.prefix(3).allSatisfy(\.isFinite) else { continue }
            let rgb = point.prefix(3).map { Int((min(1, max(0, $0)) * 255).rounded()) }
            let key = (rgb[0] >> 5) * 64 + (rgb[1] >> 5) * 8 + (rgb[2] >> 5)
            bins[key, default: []].append(rgb)
        }
        guard !bins.isEmpty else { return [] }
        func precedes(_ a: [Int], _ b: [Int]) -> Bool {
            a.lexicographicallyPrecedes(b)
        }
        let threshold = max(2, Int(ceil(Double(points.count) * 0.002)))
        let populated = bins.values.filter { $0.count >= threshold }
        let eligible = populated.isEmpty ? Array(bins.values) : populated
        var candidates = eligible.map { pixels -> (rgb: [Int], count: Int) in
            var mean = [Double](repeating: 0, count: 3)
            for rgb in pixels { for channel in 0..<3 { mean[channel] += Double(rgb[channel]) } }
            mean = mean.map { $0 / Double(pixels.count) }
            let representative = pixels.min { a, b in
                let left = distance(a.map(Double.init), mean)
                let right = distance(b.map(Double.init), mean)
                return left == right ? precedes(a, b) : left < right
            }!
            return (representative, pixels.count)
        }
        candidates.sort {
            $0.count == $1.count ? precedes($0.rgb, $1.rgb) : $0.count > $1.count
        }
        candidates = Array(candidates.prefix(128))
        let first = candidates.removeFirst()
        var chosen = [first.rgb]
        while chosen.count < 4 {
            var best: Int?
            var bestScore = -Double.infinity
            for (index, candidate) in candidates.enumerated() {
                let separation = chosen.map {
                    distance(candidate.rgb.map(Double.init), $0.map(Double.init)) / (255 * 255)
                }.min()!
                // Skip a close candidate instead of stopping before another,
                // less common but genuinely different source color is tried.
                guard separation >= 0.0025 else { continue }
                let score = separation
                if score > bestScore { best = index; bestScore = score }
            }
            guard let best else { break }
            chosen.append(candidates.remove(at: best).rgb)
        }
        return chosen.map { $0.map { Double($0) / 255 } }
    }

    nonisolated private static func distance(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
    }

    nonisolated private static func color(_ rgb: [Double]) -> Color {
        Color(.sRGB, red: rgb[0], green: rgb[1], blue: rgb[2], opacity: 1)
    }
}

/// Sampling runs on this actor, never the main actor. There are no suspension
/// points during extraction: duplicate requests reuse the finished cache entry,
/// and rapid track changes cannot launch many concurrent image-processing jobs.
actor ArtworkAtmosphereCache {
    static let shared = ArtworkAtmosphereCache()

    private struct Entry {
        let atmosphere: ArtworkAtmosphere?
    }

    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var recency: [String] = []

    init(capacity: Int = 12) {
        self.capacity = max(1, capacity)
    }

    /// Check the small processed cache before touching the original bitmap.
    /// Its lifetime is independent of the larger image cache: returning to a
    /// song should not fetch/decode its original merely to reuse this sample.
    func sample(key: String, loadImage: @Sendable () async -> UIImage?) async -> ArtworkAtmosphere? {
        guard !Task.isCancelled else { return nil }
        if let cached = entries[key] {
            touch(key)
            return cached.atmosphere
        }
        guard let image = await loadImage(), !Task.isCancelled else { return nil }
        // Another view may have populated the entry while loading suspended.
        // sample(for:key:) checks again before doing any image processing.
        return await sample(for: image, key: key)
    }

    func sample(for image: UIImage, key: String) async -> ArtworkAtmosphere? {
        guard !Task.isCancelled else { return nil }
        if let cached = entries[key] {
            touch(key)
            return cached.atmosphere
        }

        let atmosphere = ArtworkAtmosphere.make(image)
        guard !Task.isCancelled else { return nil }
        entries[key] = Entry(atmosphere: atmosphere)
        touch(key)
        if recency.count > capacity {
            entries.removeValue(forKey: recency.removeFirst())
        }
        return atmosphere
    }

    private func touch(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

/// Shared artwork identity for Now Playing and the spectrum palette.
struct ArtworkRequest: Hashable {
    let url: URL
    let authorization: String?
    var pixelSize: Int? = nil

    var original: ArtworkRequest { ArtworkRequest(url: url, authorization: authorization) }

    var headers: [String: String] {
        authorization.map { ["Authorization": $0] } ?? [:]
    }

    var cacheKey: String {
        // Scope derived images to this request without keeping credentials in
        // the derived-image cache key. The cache lives only for this process.
        var scope = Hasher()
        scope.combine(authorization)
        return url.absoluteString + "#" + String(scope.finalize()) + "@" + (pixelSize.map(String.init) ?? "original")
    }
}
