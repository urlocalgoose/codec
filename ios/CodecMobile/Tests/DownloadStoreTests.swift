import CryptoKit
import Foundation
import Network
import UIKit
import XCTest
@testable import Codec

@MainActor
final class DownloadStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codec-download-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func track(_ fingerprint: String = "isrc:offline-test") -> CodecTrack {
        CodecTrack(id: fingerprint, title: "Downloaded song", artist: "", album: "", fingerprint: fingerprint)
    }

    private func store(in directory: URL) -> DownloadStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let store = DownloadStore(directory: directory, configuration: configuration)
        addTeardownBlock { @MainActor in store.shutdown() }
        return store
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), "Download state did not reach the expected result")
    }

    func testStartupOnlyRestoresReadableNonemptyRegularAudioFiles() throws {
        let directory = try directory()
        let valid = directory.appendingPathComponent("isrc%3Aoffline-test.wav")
        try Data([1, 2, 3]).write(to: valid)
        try Data().write(to: directory.appendingPathComponent("empty.mp3"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("directory.flac"), withIntermediateDirectories: true)
        try Data([1]).write(to: directory.appendingPathComponent(".pending-incomplete.mp3"))
        try Data([1]).write(to: directory.appendingPathComponent("other.json"))
        let downloads = store(in: directory)
        XCTAssertEqual(downloads.downloadedCount, 1)
        XCTAssertEqual(downloads.localAudioURL(for: track()), valid)
        XCTAssertEqual(downloads.downloadedTracks(in: [track(), track("empty"), track("directory")]).map(\.fingerprint), [track().fingerprint])
    }

    func testRemovedFileClearsDownloadedStateAndCanBeDownloadedAgain() async throws {
        let directory = try directory()
        let file = directory.appendingPathComponent("isrc%3Aoffline-test.wav")
        try Data([1, 2, 3]).write(to: file)
        let downloads = store(in: directory)
        XCTAssertNotNil(downloads.localAudioURL(for: track()))
        try FileManager.default.removeItem(at: file)
        XCTAssertNil(downloads.localAudioURL(for: track()))
        XCTAssertFalse(downloads.isDownloaded(track()))
        let server = try await DownloadHTTPFixture.start(responses: [.audio])
        defer { server.stop() }
        downloads.download(track(), using: CodecClient(baseURL: server.baseURL))
        try await eventually { downloads.isDownloaded(self.track()) }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(downloads.localAudioURL(for: track()))), DownloadHTTPFixture.audioBytes)
        XCTAssertEqual(server.requestCount, 1)
    }

    func testTruncatedFileCannotRemainAvailableThroughCachedMetadata() throws {
        let directory = try directory()
        let file = directory.appendingPathComponent("isrc%3Aoffline-test.wav")
        try Data([1, 2, 3]).write(to: file)
        let downloads = store(in: directory)
        XCTAssertNotNil(downloads.localAudioURL(for: track()))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.close()
        XCTAssertNil(downloads.localAudioURL(for: track()))
        XCTAssertEqual(downloads.downloadedCount, 0)
    }

    func testDownloadIsDeduplicatedAndOriginalBytesSurviveStoreRelaunch() async throws {
        let directory = try directory()
        let downloads = store(in: directory)
        let server = try await DownloadHTTPFixture.start(responses: [.audio])
        defer { server.stop() }
        let client = CodecClient(baseURL: server.baseURL, token: "fixture-token")
        downloads.downloadAll([track(), track(), track()], using: client)
        try await eventually { downloads.isDownloaded(self.track()) }
        downloads.download(track(), using: client)
        XCTAssertEqual(server.requestCount, 1)
        XCTAssertTrue(server.requests.first?.contains("Authorization: Bearer fixture-token") ?? false)
        let file = try XCTUnwrap(downloads.localAudioURL(for: track()))
        XCTAssertEqual(file.pathExtension, "wav")
        XCTAssertEqual(try Data(contentsOf: file), DownloadHTTPFixture.audioBytes)
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        downloads.shutdown()
        let restored = store(in: directory)
        XCTAssertEqual(restored.localAudioURL(for: track()), file)
    }

    func testHTTPFailuresAndHTMLNeverBecomeDownloadedAudio() async throws {
        let server = try await DownloadHTTPFixture.start(responses: [
            .init(status: 401, mime: "application/json", body: Data("{}".utf8)),
            .init(status: 200, mime: "text/html", body: Data("<html>Sign in</html>".utf8)),
            .init(status: 200, mime: "audio/mpeg", body: Data())
        ])
        defer { server.stop() }
        let directory = try directory()
        let downloads = store(in: directory)
        for index in 0..<3 {
            let track = track("failed-\(index)")
            downloads.download(track, using: CodecClient(baseURL: server.baseURL))
            try await eventually { downloads.failures[track.fingerprint] != nil }
            XCTAssertFalse(downloads.isDownloaded(track))
            XCTAssertNil(downloads.state(for: track))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testCancelCannotRestoreAFileOrClobberNewTransfer() async throws {
        let server = try await DownloadHTTPFixture.start(responses: [
            .init(status: 200, mime: "audio/wav", body: Data([9, 9]), delay: 0.3), .audio
        ])
        defer { server.stop() }
        let directory = try directory()
        let downloads = store(in: directory)
        let client = CodecClient(baseURL: server.baseURL)
        downloads.download(track(), using: client)
        try await eventually { server.requestCount == 1 }
        downloads.remove(track())
        XCTAssertNil(downloads.state(for: track()))
        downloads.download(track(), using: client)
        try await eventually { downloads.isDownloaded(self.track()) }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(server.requestCount, 2)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(downloads.localAudioURL(for: track()))), DownloadHTTPFixture.audioBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    func testServerOutageQueuesRetryAndConnectivityRecoveryFinishesIt() async throws {
        let server = try await DownloadHTTPFixture.start(responses: [
            .init(status: 503, mime: "application/json", body: Data("{}".utf8)), .audio
        ])
        defer { server.stop() }
        let downloads = store(in: try directory())
        downloads.download(track(), using: CodecClient(baseURL: server.baseURL))
        try await eventually { downloads.failures[self.track().fingerprint] != nil }
        downloads.setNetworkAvailable(false)
        downloads.retryPendingDownloads()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.requestCount, 1)
        XCTAssertNotNil(downloads.state(for: track()))
        downloads.setNetworkAvailable(true)
        try await eventually { downloads.isDownloaded(self.track()) }
        XCTAssertEqual(server.requestCount, 2)
        XCTAssertNil(downloads.failures[track().fingerprint])
    }

    func testDownloadRequestedWithoutServiceWaitsUntilPathReturns() async throws {
        let server = try await DownloadHTTPFixture.start(responses: [.audio])
        defer { server.stop() }
        let downloads = store(in: try directory())
        downloads.setNetworkAvailable(false)
        downloads.download(track(), using: CodecClient(baseURL: server.baseURL))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.requestCount, 0)
        XCTAssertEqual(downloads.state(for: track()), .downloading(0))
        downloads.setNetworkAvailable(true)
        try await eventually { downloads.isDownloaded(self.track()) }
    }

    func testPinnedArtworkPreservesOriginalBytesAcrossCachePruningAndSharedRemoval() async throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let server = try await DownloadHTTPFixture.start(responses: [.init(status: 200, mime: "image/png", body: png)])
        defer { server.stop() }
        let directory = try directory()
        let cached = directory.appendingPathComponent("cache")
        let pinned = directory.appendingPathComponent("pinned")
        let loader = ArtworkLoader(cacheDirectory: cached, pinnedDirectory: pinned)
        let url = server.baseURL.appendingPathComponent("artwork")
        await loader.pinImage(for: url, headers: [:], fingerprint: "first")
        await loader.pinImage(for: url, headers: [:], fingerprint: "second")
        await loader.pruneDiskCache(keeping: 0)
        let images = try FileManager.default.contentsOfDirectory(at: pinned, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jpg" }
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(images.first)), png, "Original PNG bytes must survive without lossy re-encoding")
        XCTAssertEqual(server.requestCount, 1)
        let restored = ArtworkLoader(cacheDirectory: cached, pinnedDirectory: pinned)
        await restored.unpinImage(fingerprint: "first")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(images.first).path))
        await restored.unpinImage(fingerprint: "second")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(images.first).path))
    }

    func testArtworkLoadsFromPinnedFileWithoutAnyRequest() async throws {
        let server = try await DownloadHTTPFixture.start(responses: [])
        defer { server.stop() }
        let directory = try directory()
        let url = server.baseURL.appendingPathComponent("never-request-this")
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined().prefix(40)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { $0.fill(CGRect(x: 0, y: 0, width: 2, height: 2)) }
        try png.write(to: directory.appendingPathComponent("\(name).jpg"))
        let loader = ArtworkLoader(cacheDirectory: directory.appendingPathComponent("cache"), pinnedDirectory: directory)
        let image = await loader.image(for: url, headers: [:])
        XCTAssertNotNil(image)
        XCTAssertEqual(server.requestCount, 0)
    }

    func testArtworkVariantsShareOriginalRequestAndDecodeOffMainAtDisplayResolution() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 640), format: format).pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
        }
        let server = try await DownloadHTTPFixture.start(responses: [.init(status: 200, mime: "image/png", body: png, delay: 0.08)])
        defer { server.stop() }
        let directory = try directory()
        let probe = ArtworkDecodeProbe()
        let loader = ArtworkLoader(cacheDirectory: directory.appendingPathComponent("cache"), pinnedDirectory: directory.appendingPathComponent("pinned"), decode: { data, pixels in
            probe.record(pixels: pixels, onMain: Thread.isMainThread)
            return ArtworkLoader.prepareImage(data, pixelSize: pixels)
        })
        let url = server.baseURL.appendingPathComponent("shared-cover")
        async let first = loader.image(for: url, headers: [:], pixelSize: 144)
        async let duplicate = loader.image(for: url, headers: [:], pixelSize: 144)
        async let card = loader.image(for: url, headers: [:], pixelSize: 384)
        async let full = loader.image(for: url, headers: [:])
        let (rowImage, duplicateImage, cardImage, fullImage) = await (first, duplicate, card, full)
        let row = try XCTUnwrap(rowImage)
        XCTAssertTrue(row === duplicateImage)
        XCTAssertEqual(row.cgImage?.width, 144)
        XCTAssertEqual(cardImage?.cgImage?.width, 384)
        XCTAssertEqual(fullImage?.cgImage?.width, 640)
        XCTAssertEqual(server.requestCount, 1, "All display sizes must share the original-byte transfer")
        XCTAssertEqual(probe.events.count, 3, "Same-size concurrent callers must share one bitmap decode")
        XCTAssertTrue(probe.events.allSatisfy { !$0.onMain }, "Bitmap decompression must not run on the display thread")
        XCTAssertTrue(ArtworkLoader.cachedImage(for: url, pixelSize: 144) === row)
        await loader.pinImage(for: url, headers: [:], fingerprint: "downloaded")
        XCTAssertEqual(probe.events.count, 3, "Pinning original bytes must not decode another full-size image")
        XCTAssertEqual(server.requestCount, 1)
    }

    func testArtworkAspectFillKeepsEnoughPixelsAndNeverUpscalesOriginal() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 200), format: format).pngData { context in
            UIColor.purple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 200))
        }
        let cropped = try XCTUnwrap(ArtworkLoader.prepareImage(png, pixelSize: 144)?.cgImage)
        XCTAssertEqual(cropped.width, 432)
        XCTAssertEqual(cropped.height, 144, "A square aspect-fill crop must not stretch an undersized short edge")
        let large = try XCTUnwrap(ArtworkLoader.prepareImage(png, pixelSize: 900)?.cgImage)
        XCTAssertEqual(large.width, 600)
        XCTAssertEqual(large.height, 200)
        let full = try XCTUnwrap(ArtworkLoader.prepareImage(png, pixelSize: nil)?.cgImage)
        XCTAssertEqual(full.width, 600)
        XCTAssertEqual(full.height, 200)
    }

    func testArtworkAuthScopesDoNotShareBitmapsOrDiskFiles() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        func png(_ color: UIColor) -> Data {
            UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).pngData { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            }
        }
        let server = try await DownloadHTTPFixture.start(responses: [
            .init(status: 200, mime: "image/png", body: png(.orange)),
            .init(status: 200, mime: "image/png", body: png(.blue))
        ])
        defer { server.stop() }
        let directory = try directory()
        let cache = directory.appendingPathComponent("cache")
        let pinned = directory.appendingPathComponent("pinned")
        let loader = ArtworkLoader(cacheDirectory: cache, pinnedDirectory: pinned)
        let url = server.baseURL.appendingPathComponent("same-url")
        let firstHeaders = ["Authorization": "Bearer first-fixture"]
        let secondHeaders = ["Authorization": "Bearer second-fixture"]
        let first = await loader.image(for: url, headers: firstHeaders, pixelSize: 32)
        let second = await loader.image(for: url, headers: secondHeaders, pixelSize: 32)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertFalse(first === second)
        XCTAssertEqual(server.requestCount, 2)
        XCTAssertTrue(ArtworkLoader.cachedImage(for: url, headers: firstHeaders, pixelSize: 32) === first)
        XCTAssertTrue(ArtworkLoader.cachedImage(for: url, headers: secondHeaders, pixelSize: 32) === second)
        XCTAssertNil(ArtworkLoader.cachedImage(for: url, pixelSize: 32))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path).count, 2)
        let restored = ArtworkLoader(cacheDirectory: cache, pinnedDirectory: pinned)
        let restoredFirst = await restored.image(for: url, headers: firstHeaders, pixelSize: 48)
        XCTAssertNotNil(restoredFirst)
        XCTAssertEqual(server.requestCount, 2, "A new size must reuse only its authenticated original disk bytes")
    }

    func testLegacyPinnedArtworkBindsOnceAndRemainsOfflineAfterRelaunch() async throws {
        let server = try await DownloadHTTPFixture.start(responses: [])
        defer { server.stop() }
        let directory = try directory()
        let url = server.baseURL.appendingPathComponent("legacy-authenticated-cover")
        let legacyName = String(SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined().prefix(40)) + ".jpg"
        let png = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).pngData { $0.fill(CGRect(x: 0, y: 0, width: 32, height: 32)) }
        try png.write(to: directory.appendingPathComponent(legacyName))
        try JSONEncoder().encode(["legacy-track": legacyName]).write(to: directory.appendingPathComponent(".tracks.json"))
        let cache = directory.appendingPathComponent("cache")
        let headers = ["Authorization": "Bearer legacy-fixture-scope"]
        let loader = ArtworkLoader(cacheDirectory: cache, pinnedDirectory: directory)
        let bound = await loader.image(for: url, headers: headers, pixelSize: 16)
        XCTAssertNotNil(bound)
        XCTAssertEqual(server.requestCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(legacyName).path))
        let pins = try String(contentsOf: directory.appendingPathComponent(".tracks.json"), encoding: .utf8)
        XCTAssertFalse(pins.contains("legacy-fixture-scope"), "Persist only a digest, never the credential")
        let restored = ArtworkLoader(cacheDirectory: cache, pinnedDirectory: directory)
        let offline = await restored.image(for: url, headers: headers, pixelSize: 24)
        XCTAssertNotNil(offline)
        let pinned = await restored.hasPinnedImage(fingerprint: "legacy-track")
        XCTAssertTrue(pinned)
        XCTAssertEqual(server.requestCount, 0)
        let otherScope = await restored.image(for: url, headers: ["Authorization": "Bearer different-fixture-scope"], pixelSize: 16)
        XCTAssertNil(otherScope)
        XCTAssertEqual(server.requestCount, 1, "A different scope cannot reuse the migrated offline pin")
    }
}

private final class ArtworkDecodeProbe: @unchecked Sendable {
    struct Event { let pixels: Int?; let onMain: Bool }
    private let lock = NSLock()
    private var values: [Event] = []
    var events: [Event] { lock.withLock { values } }
    func record(pixels: Int?, onMain: Bool) { lock.withLock { values.append(Event(pixels: pixels, onMain: onMain)) } }
}

/// Real loopback HTTP makes URLSession's download/delegate lifecycle part of
/// the regression, including callback ordering around cancellation/retry.
private final class DownloadHTTPFixture: @unchecked Sendable {
    struct Response: Sendable {
        var status: Int
        var mime: String
        var body: Data
        var delay: TimeInterval = 0
        static let audio = Response(status: 200, mime: "audio/wav", body: DownloadHTTPFixture.audioBytes)
    }
    static let audioBytes = Data("RIFF-original-download-bytes-WAVE".utf8)
    private let listener: NWListener
    private let queue = DispatchQueue(label: "codec.tests.download-http")
    private let lock = NSLock()
    private var responses: [Response]
    private var received: [String] = []
    var requests: [String] { lock.withLock { received } }
    var requestCount: Int { lock.withLock { received.count } }
    var baseURL: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")! }

    private init(responses: [Response]) throws {
        self.responses = responses
        listener = try NWListener(using: .tcp, on: .any)
    }

    static func start(responses: [Response]) async throws -> DownloadHTTPFixture {
        let fixture = try DownloadHTTPFixture(responses: responses)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            fixture.listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    fixture.listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    fixture.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            fixture.listener.newConnectionHandler = { [weak fixture] connection in fixture?.respond(to: connection) }
            fixture.listener.start(queue: fixture.queue)
        }
        return fixture
    }

    func stop() { listener.cancel() }

    private func respond(to connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let response = self.lock.withLock {
                self.received.append(String(data: data ?? Data(), encoding: .utf8) ?? "")
                return self.responses.isEmpty ? Response(status: 500, mime: "text/plain", body: Data()) : self.responses.removeFirst()
            }
            self.queue.asyncAfter(deadline: .now() + response.delay) {
                let header = "HTTP/1.1 \(response.status) Test\r\nContent-Type: \(response.mime)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
