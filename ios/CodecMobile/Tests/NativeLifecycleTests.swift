import Foundation
import SwiftUI
import XCTest
@testable import Codec

@MainActor
final class NativeLifecycleTests: XCTestCase {
    func testInitialActivationAndTemporaryInactivityDoNotRefreshPlayback() {
        var gate = PlaybackForegroundGate()
        XCTAssertFalse(gate.shouldRefresh(after: .active))
        for _ in 0..<5 {
            XCTAssertFalse(gate.shouldRefresh(after: .inactive))
            XCTAssertFalse(gate.shouldRefresh(after: .active))
        }
    }

    func testBackgroundReturnRefreshesOnceAcrossIntermediateInactiveState() {
        var gate = PlaybackForegroundGate()
        XCTAssertFalse(gate.shouldRefresh(after: .inactive))
        XCTAssertFalse(gate.shouldRefresh(after: .background))
        XCTAssertFalse(gate.shouldRefresh(after: .inactive))
        XCTAssertTrue(gate.shouldRefresh(after: .active))
        XCTAssertFalse(gate.shouldRefresh(after: .active))
        XCTAssertFalse(gate.shouldRefresh(after: .inactive))
        XCTAssertFalse(gate.shouldRefresh(after: .active))
        XCTAssertFalse(gate.shouldRefresh(after: .background))
        XCTAssertTrue(gate.shouldRefresh(after: .active))
    }

    func testForegroundReusesRecentlyRefreshedLibraryButExpiredSnapshotFetches() async {
        let fixture = ForegroundLibraryFixture()
        let app = AppModel(client: fixture.client)
        await app.refresh()
        await app.refreshIfNeeded()
        let freshRequests = await fixture.requests
        XCTAssertEqual(freshRequests, 1)

        await app.refreshIfNeeded(maxAge: .zero)
        let expiredRequests = await fixture.requests
        XCTAssertEqual(expiredRequests, 2)
    }

    func testConcurrentForegroundChecksJoinOneFetchWithoutSchedulingAnotherPass() async {
        let fixture = ForegroundLibraryFixture(delay: .milliseconds(100))
        let app = AppModel(client: fixture.client)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { await app.refreshIfNeeded() }
            }
        }
        let requests = await fixture.requests
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(app.connection, .connected)
    }

    func testLibraryChangeDuringForegroundFetchStillGetsAFreshFollowup() async throws {
        let fixture = ForegroundLibraryFixture(delay: .milliseconds(100))
        let app = AppModel(client: fixture.client)
        let foreground = Task { await app.refreshIfNeeded() }
        while await fixture.requests == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        // A mutation/SSE event needs a response fetched after the event. It
        // must retain the forced follow-up behavior that foreground skips.
        await app.refresh()
        await foreground.value
        let requests = await fixture.requests
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(app.library?.scannedAt, 2)
    }

    func testFailedRefreshRetriesImmediatelyDespiteRecentSuccessfulSnapshot() async {
        let fixture = ForegroundLibraryFixture()
        let app = AppModel(client: fixture.client)
        await app.refresh()
        await fixture.setOffline(true)
        await app.refresh()
        XCTAssertEqual(app.connection, .offline)

        await fixture.setOffline(false)
        await app.refreshIfNeeded()
        let requests = await fixture.requests
        XCTAssertEqual(requests, 3)
        XCTAssertEqual(app.connection, .connected)
    }

    func testValidatingConnectionDoesNotStopAnExistingPlaybackSession() {
        let fixture = ForegroundLibraryFixture()
        let app = AppModel(client: fixture.client)
        let player = PlayerController()
        defer { player.stopSync() }
        player.startSync(client: fixture.client)
        app.connection = .connecting
        app.syncPlayer(player)
        XCTAssertTrue(player.syncEnabled)
    }
}

private actor ForegroundLibraryFixture: CodecTransport {
    private(set) var requests = 0
    private var offline = false
    private let delay: Duration

    nonisolated var client: CodecClient {
        CodecClient(baseURL: URL(string: "https://foreground-tests.invalid")!, transport: self)
    }

    init(delay: Duration = .zero) { self.delay = delay }
    func setOffline(_ value: Bool) { offline = value }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests += 1
        if offline { throw URLError(.notConnectedToInternet) }
        let revision = requests
        if delay > .zero { try await Task.sleep(for: delay) }
        let data = Data("{\"scanned_at\":\(revision)}".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}
