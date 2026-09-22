import SwiftUI
import UIKit
import XCTest
@testable import Codec

@MainActor
final class ArtworkAtmosphereTests: XCTestCase {
    func testPaletteUsesArtworkWarmCoolAndDeepColors() throws {
        let image = try makeImage { _, y in
            switch y {
            case 0..<16: return [240, 32, 16, 255]
            case 16..<32: return [16, 48, 224, 255]
            default: return [8, 8, 8, 255]
            }
        }
        let sample = try XCTUnwrap(ArtworkAtmosphere.make(image))
        assertColor(sample.warm, red: 240, green: 32, blue: 16)
        assertColor(sample.cool, red: 16, green: 48, blue: 224)
        assertColor(sample.deep, red: 8, green: 8, blue: 8)
        XCTAssertEqual(sample.blurred.cgImage?.width, 48)
        XCTAssertEqual(sample.blurred.cgImage?.height, 48)
    }

    func testSingleColorArtworkProducesMatchingPalette() throws {
        let image = try makeImage { _, _ in [48, 128, 208, 255] }
        let sample = try XCTUnwrap(ArtworkAtmosphere.make(image))
        for color in [sample.warm, sample.cool, sample.deep] {
            assertColor(color, red: 48, green: 128, blue: 208)
        }
        XCTAssertEqual(sample.spectrumSwatches, [[48, 128, 208].map { Double($0) / 255 }])
    }

    func testSpectrumSwatchesAreActualPixelsInsteadOfClusterMeansOrInventedHues() throws {
        let source: [[UInt8]] = [[228, 88, 20], [20, 116, 172], [36, 40, 44], [224, 200, 80]]
        let sample = try XCTUnwrap(ArtworkAtmosphere.make(try makeImage { x, _ in source[x / 12] + [255] }))
        XCTAssertEqual(sample.spectrumSwatches.count, 4)
        let actual = sample.spectrumSwatches.map { $0.map { Int(($0 * 255).rounded()) } }
        XCTAssertEqual(Set(actual), Set(source.map { $0.map(Int.init) }))
    }

    func testGrayAndTwoInkArtworkDoNotAcquireAdditionalColors() throws {
        let fixtures: [[[UInt8]]] = [[[92, 92, 92]], [[32, 72, 120], [224, 160, 48]]]
        for source in fixtures {
            let sample = try XCTUnwrap(ArtworkAtmosphere.make(try makeImage { x, _ in source[x * source.count / 48] + [255] }))
            XCTAssertEqual(sample.spectrumSwatches.count, source.count)
            XCTAssertEqual(Set(sample.spectrumSwatches.map { $0.map { Int(($0 * 255).rounded()) } }),
                           Set(source.map { $0.map(Int.init) }))
        }
    }

    func testHistogramRepresentativeUsesARealPixelAndDeterministicTieBreak() {
        let points = [[80, 80, 80], [92, 92, 92]].map { $0.map { Double($0) / 255 } }
        // Both pixels occupy the same 3-bit bin and are equally near its
        // invented mean (86,86,86). The lexicographically smaller pixel wins.
        XCTAssertEqual(ArtworkAtmosphere.extractSpectrumSwatches(from: points), [points[0]])
        XCTAssertEqual(ArtworkAtmosphere.extractSpectrumSwatches(from: Array(points.reversed())), [points[0]])
    }

    func testCloseCommonShadesDoNotHideASeparateLessCommonInk() {
        let source = [[127, 127, 96], [128, 127, 96], [127, 140, 96]].map { $0.map { Double($0) / 255 } }
        let points = Array(repeating: source[0], count: 100) + Array(repeating: source[1], count: 99)
            + Array(repeating: source[2], count: 2)
        let selected = ArtworkAtmosphere.extractSpectrumSwatches(from: points)
        XCTAssertEqual(selected, [source[0], source[2]])
    }

    func testTexturedMinorityAccentSurvivesDominantNeutralBackground() throws {
        var accent: [[UInt8]] = []
        for index in 0..<32 {
            let red = UInt8(160 + index)
            let green = UInt8(96 + (index * 7) % 32)
            let blue = UInt8(32 + (index * 11) % 32)
            accent.append([red, green, blue])
        }
        let sample = try XCTUnwrap(ArtworkAtmosphere.make(try makeImage { x, y in
            let index = y * 48 + x
            // The small textured accent occupies one 3-bit bin, but its
            // pixels spread among finer bins. It is real art, not noise.
            if index < accent.count { return accent[index] + [255] }
            let neutral = UInt8([16, 80, 192][y / 16])
            return [neutral, neutral, neutral, 255]
        }))
        let selected = sample.spectrumSwatches.map { $0.map { Int(($0 * 255).rounded()) } }
        XCTAssertEqual(selected.count, 4)
        XCTAssertTrue(selected.contains { candidate in accent.contains { $0.map(Int.init) == candidate } })
        XCTAssertTrue(selected.allSatisfy { candidate in
            accent.contains { $0.map(Int.init) == candidate } || [16, 80, 192].contains { candidate == [$0, $0, $0] }
        })
    }

    func testSmallArtworkUsesRarePixelsWhenNoBinHasTwoSamples() {
        let points = [[0.0, 0.0, 0.0], [1.0, 1.0, 1.0], [0.0, 0.0, 1.0]]
        XCTAssertEqual(Set(ArtworkAtmosphere.extractSpectrumSwatches(from: points)), Set(points))
    }

    func testTransparentPixelsDoNotAddBlackOrDarkenTranslucentColors() throws {
        let image = try makeImage { x, _ in
            // Half-transparent red is stored premultiplied in the bitmap.
            x < 24 ? [128, 0, 0, 128] : [0, 0, 0, 0]
        }
        let sample = try XCTUnwrap(ArtworkAtmosphere.make(image))
        for color in [sample.warm, sample.cool, sample.deep] {
            assertColor(color, red: 255, green: 0, blue: 0)
        }
        XCTAssertEqual(sample.spectrumSwatches, [[1, 0, 0]])
    }

    func testMissingAndFullyTransparentImagesFallBackWithoutSampling() throws {
        XCTAssertNil(ArtworkAtmosphere.make(UIImage()))
        XCTAssertNil(ArtworkAtmosphere.make(try makeImage { _, _ in [0, 0, 0, 0] }))
    }

    func testConcurrentRequestsReuseOneProcessedImage() async throws {
        let image = try makeImage { x, _ in x < 24 ? [220, 40, 20, 255] : [20, 40, 220, 255] }
        let cache = ArtworkAtmosphereCache()
        let samples = await withTaskGroup(of: ArtworkAtmosphere?.self) { group in
            for _ in 0..<12 {
                group.addTask { await cache.sample(for: image, key: "same-artwork") }
            }
            var results: [ArtworkAtmosphere] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }
        XCTAssertEqual(samples.count, 12)
        let first = try XCTUnwrap(samples.first)
        XCTAssertTrue(samples.allSatisfy { $0.blurred === first.blurred })
    }

    func testCacheEvictsLeastRecentlyUsedArtwork() async throws {
        let image = try makeImage { _, _ in [80, 120, 160, 255] }
        let cache = ArtworkAtmosphereCache(capacity: 2)
        let first = await cache.sample(for: image, key: "a")
        let second = await cache.sample(for: image, key: "b")
        let reusedFirst = await cache.sample(for: image, key: "a")
        XCTAssertTrue(try XCTUnwrap(first).blurred === XCTUnwrap(reusedFirst).blurred)
        _ = await cache.sample(for: image, key: "c")
        let retainedFirst = await cache.sample(for: image, key: "a")
        XCTAssertTrue(try XCTUnwrap(first).blurred === XCTUnwrap(retainedFirst).blurred)
        let newSecond = await cache.sample(for: image, key: "b")
        XCTAssertFalse(try XCTUnwrap(second).blurred === XCTUnwrap(newSecond).blurred)
    }

    func testWarmAtmosphereSkipsOriginalLoadingAndPreservesColors() async throws {
        let image = try makeImage { _, _ in [80, 120, 160, 255] }
        let cache = ArtworkAtmosphereCache()
        let counter = ImageLoadCounter()
        let first = await cache.sample(key: "artwork-v1") {
            await counter.record()
            return image
        }
        // Simulate original bitmap eviction or unavailable network. The small
        // processed sample must still work without calling the original loader.
        let reused = await cache.sample(key: "artwork-v1") {
            await counter.record()
            return nil
        }
        let loads = await counter.count
        XCTAssertEqual(loads, 1)
        XCTAssertTrue(try XCTUnwrap(first).blurred === XCTUnwrap(reused).blurred)
        assertColor(try XCTUnwrap(reused).warm, red: 80, green: 120, blue: 160)
        _ = await cache.sample(key: "artwork-v2") {
            await counter.record()
            return image
        }
        let changedLoads = await counter.count
        XCTAssertEqual(changedLoads, 2, "Changed artwork must load the new version")
    }

    func testTransparentCachedSampleDoesNotReloadOriginal() async throws {
        let transparent = try makeImage { _, _ in [0, 0, 0, 0] }
        let cache = ArtworkAtmosphereCache()
        let counter = ImageLoadCounter()
        for _ in 0..<3 {
            let result = await cache.sample(key: "transparent") {
                await counter.record()
                return transparent
            }
            XCTAssertNil(result)
        }
        let loads = await counter.count
        XCTAssertEqual(loads, 1, "A cached empty palette is distinct from a cache miss")
    }

    func testFailedOriginalLoadRemainsRetryable() async throws {
        let image = try makeImage { _, _ in [80, 120, 160, 255] }
        let cache = ArtworkAtmosphereCache()
        let unavailable = await cache.sample(key: "artwork") { nil }
        XCTAssertNil(unavailable)
        let recovered = await cache.sample(key: "artwork") { image }
        XCTAssertNotNil(recovered)
    }

    func testCancellationDuringOriginalLoadDoesNotPopulateCache() async throws {
        let oldImage = try makeImage { _, _ in [200, 40, 20, 255] }
        let newImage = try makeImage { _, _ in [20, 40, 200, 255] }
        let cache = ArtworkAtmosphereCache()
        let cancelled = Task {
            await cache.sample(key: "artwork") {
                withUnsafeCurrentTask { $0?.cancel() }
                return oldImage
            }
        }
        let result = await cancelled.value
        XCTAssertNil(result)
        let fresh = await cache.sample(key: "artwork") { newImage }
        assertColor(try XCTUnwrap(fresh).warm, red: 20, green: 40, blue: 200)
    }

    func testCancelledRequestDoesNotProcessOrPoisonCache() async throws {
        let image = try makeImage { _, _ in [80, 120, 160, 255] }
        let cache = ArtworkAtmosphereCache()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cache.sample(for: image, key: "artwork")
        }
        let cancelledResult = await cancelled.value
        XCTAssertNil(cancelledResult)
        let nextResult = await cache.sample(for: image, key: "artwork")
        XCTAssertNotNil(nextResult)
    }

    private func makeImage(pixel: (Int, Int) -> [UInt8]) throws -> UIImage {
        let side = 48
        var bytes: [UInt8] = []
        for y in 0..<side {
            for x in 0..<side { bytes.append(contentsOf: pixel(x, y)) }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        return UIImage(cgImage: image)
    }

    private func assertColor(
        _ color: Color, red: Double, green: Double, blue: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var actualRed: CGFloat = 0
        var actualGreen: CGFloat = 0
        var actualBlue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(UIColor(color).getRed(&actualRed, green: &actualGreen, blue: &actualBlue, alpha: &alpha), file: file, line: line)
        XCTAssertEqual(Double(actualRed), red / 255, accuracy: 0.005, file: file, line: line)
        XCTAssertEqual(Double(actualGreen), green / 255, accuracy: 0.005, file: file, line: line)
        XCTAssertEqual(Double(actualBlue), blue / 255, accuracy: 0.005, file: file, line: line)
        XCTAssertEqual(alpha, 1, file: file, line: line)
    }
}

private actor ImageLoadCounter {
    private(set) var count = 0
    func record() { count += 1 }
}
