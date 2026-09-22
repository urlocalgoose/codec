import Foundation
import XCTest
@testable import Codec

@MainActor
final class ConnectionRecoveryTests: XCTestCase {
    private func makeApp(_ fixture: ConnectionFixture, delays: [Duration] = [.milliseconds(30), .milliseconds(60)]) -> AppModel {
        let app = AppModel(client: fixture.client, reconnectDelays: delays,
                           clientFactory: { url, token in CodecClient(baseURL: url, token: token, transport: fixture) })
        app.serverURLString = fixture.client.baseURL.absoluteString
        app.token = "test-token"
        return app
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate())
    }

    func testFailureClassificationDoesNotAssumeWiFiMeansServerDown() {
        XCTAssertEqual(ConnectionIssue.classify(URLError(.timedOut), network: .available), .serverUnreachable)
        XCTAssertEqual(ConnectionIssue.classify(URLError(.cannotFindHost), network: .available), .serverUnreachable)
        XCTAssertEqual(ConnectionIssue.classify(URLError(.timedOut), network: .unavailable), .noNetwork)
        XCTAssertEqual(ConnectionIssue.classify(CodecClientError.httpStatus(503, ""), network: .available), .serverUnavailable)
        XCTAssertEqual(ConnectionIssue.classify(CodecClientError.httpStatus(401, ""), network: .available), .authentication)
        XCTAssertEqual(ConnectionIssue.classify(URLError(.serverCertificateUntrusted), network: .available), .secureConnection)
    }

    func testNoPathKeepsCachedLibraryAndMakesNoRefreshRequests() async throws {
        let fixture = ConnectionFixture()
        let app = makeApp(fixture)
        defer { app.disconnect() }
        await app.refresh()
        app.startConnectionMonitoring(observeSystemNetwork: false)
        app.updateNetworkAvailability(.unavailable)
        await app.refreshIfNeeded(maxAge: .zero)
        let refreshed = await app.refresh()
        try await Task.sleep(for: .milliseconds(120))
        let count = await fixture.libraryRequests
        XCTAssertFalse(refreshed)
        XCTAssertEqual(count, 1)
        XCTAssertNotNil(app.library)
        XCTAssertEqual(app.connection, .offline)
        XCTAssertEqual(app.connectionIssue, .noNetwork)
    }

    func testRestoringPathValidatesImmediatelyInsteadOfWaitingForBackoff() async throws {
        let fixture = ConnectionFixture()
        let app = makeApp(fixture, delays: [.seconds(30)])
        defer { app.disconnect() }
        await app.refresh()
        app.startConnectionMonitoring(observeSystemNetwork: false)
        app.updateNetworkAvailability(.unavailable)
        await fixture.setStatus(200, version: 2)
        app.updateNetworkAvailability(.available)
        try await eventually { app.isConnected && app.library?.scannedAt == 2 }
        let count = await fixture.libraryRequests
        XCTAssertEqual(count, 2)
        XCTAssertNil(app.connectionIssue)
    }

    func testServerOutageRetriesAndRecoversWithBoundedTraffic() async throws {
        let fixture = ConnectionFixture()
        let app = makeApp(fixture)
        defer { app.disconnect() }
        await app.refresh()
        app.startConnectionMonitoring(observeSystemNetwork: false)
        app.updateNetworkAvailability(.available)
        await fixture.setStatus(503)
        await app.refresh()
        for _ in 0..<10 { app.reportSyncFailure(URLError(.cannotConnectToHost)) }
        try await Task.sleep(for: .milliseconds(100))
        let failures = await fixture.libraryRequests
        XCTAssertLessThanOrEqual(failures, 5, "Repeated failure reports must share one backoff loop")
        XCTAssertEqual(app.connectionIssue, .serverUnavailable)
        await fixture.setStatus(200, version: 3)
        try await eventually { app.isConnected && app.library?.scannedAt == 3 }
    }

    func testRejectedTokenDoesNotRetryOnTimerOrNetworkFlap() async throws {
        let fixture = ConnectionFixture()
        let app = makeApp(fixture)
        defer { app.disconnect() }
        await app.refresh()
        app.startConnectionMonitoring(observeSystemNetwork: false)
        await fixture.setStatus(401)
        await app.refresh()
        app.updateNetworkAvailability(.unavailable)
        app.updateNetworkAvailability(.available)
        await app.refreshIfNeeded(maxAge: .zero)
        try await Task.sleep(for: .milliseconds(130))
        let count = await fixture.libraryRequests
        XCTAssertEqual(count, 2)
        XCTAssertEqual(app.connectionIssue, .authentication)
        XCTAssertNotNil(app.library)
    }

    func testDisconnectCancelsRecoveryAndLateResponseCannotRestoreLibrary() async throws {
        let fixture = ConnectionFixture()
        let app = makeApp(fixture)
        await app.refresh()
        await fixture.holdNextLibrary()
        let refresh = Task { await app.refresh() }
        while !(await fixture.isHeld) { try await Task.sleep(for: .milliseconds(1)) }
        app.disconnect()
        await fixture.releaseLibrary()
        _ = await refresh.value
        XCTAssertEqual(app.connection, .disconnected)
        XCTAssertNil(app.client)
        XCTAssertNil(app.library)
    }

    func testOldRefreshCannotReplaceManuallyChosenServer() async throws {
        let fixture = ConnectionFixture()
        let app = makeApp(fixture)
        defer { app.disconnect() }
        await app.refresh()
        await fixture.holdNextLibrary()
        let old = Task { await app.refresh() }
        while !(await fixture.isHeld) { try await Task.sleep(for: .milliseconds(1)) }
        app.serverURLString = "https://second.invalid"
        await app.connect()
        await fixture.releaseLibrary()
        _ = await old.value
        XCTAssertEqual(app.client?.baseURL.host, "second.invalid")
        XCTAssertEqual(app.library?.rootPath, "second.invalid")
        XCTAssertEqual(app.connection, .connected)
    }

    func testFailedReplacementKeepsRetryingReplacementNotPreviousServer() async throws {
        let fixture = ConnectionFixture()
        let app = makeApp(fixture, delays: [.seconds(30)])
        defer { app.disconnect() }
        await app.refresh()
        await fixture.setSecondStatus(503)
        app.startConnectionMonitoring(observeSystemNetwork: false)
        app.serverURLString = "https://second.invalid"
        await app.connect()
        let count = await fixture.libraryRequests
        let refreshed = await app.refresh()
        XCTAssertFalse(refreshed)
        let after = await fixture.libraryRequests
        XCTAssertEqual(count, after)
        await fixture.setSecondStatus(200)
        await app.retryConnection()
        XCTAssertEqual(app.client?.baseURL.host, "second.invalid")
        XCTAssertEqual(app.connection, .connected)
    }

    func testFirstConnectLosingPathDoesNotLeaveDisabledConnectingScreen() async throws {
        let fixture = ConnectionFixture()
        let app = AppModel(reconnectDelays: [.milliseconds(10)], clientFactory: { url, token in CodecClient(baseURL: url, token: token, transport: fixture) })
        app.disconnect()
        app.serverURLString = "https://first.invalid"
        app.token = "test-token"
        app.startConnectionMonitoring(observeSystemNetwork: false)
        defer { app.disconnect() }
        await fixture.holdNextLibrary()
        let connect = Task { await app.connect() }
        while !(await fixture.isHeld) { try await Task.sleep(for: .milliseconds(1)) }
        app.updateNetworkAvailability(.unavailable)
        await fixture.releaseLibrary()
        await connect.value
        XCTAssertEqual(app.connection, .disconnected)
        XCTAssertEqual(app.connectionIssue, .noNetwork)
        app.updateNetworkAvailability(.available)
        try await eventually { app.isConnected }
    }

    func testInvalidManualAddressCancelsOldRecovery() async throws {
        let fixture = ConnectionFixture()
        let app = makeApp(fixture)
        defer { app.disconnect() }
        await app.refresh()
        app.startConnectionMonitoring(observeSystemNetwork: false)
        app.reportSyncFailure(URLError(.cannotConnectToHost))
        app.serverURLString = ""
        await app.connect()
        try await Task.sleep(for: .milliseconds(130))
        let count = await fixture.libraryRequests
        XCTAssertEqual(count, 1)
        XCTAssertEqual(app.connectionIssue, .invalidServer)
        XCTAssertFalse(app.isConnected)
    }
}

private actor ConnectionFixture: CodecTransport {
    private var status = 200
    private var secondStatus = 200
    private var version = 1
    private var shouldHold = false
    private var held: CheckedContinuation<Void, Never>?
    private(set) var libraryRequests = 0
    var isHeld: Bool { held != nil }
    nonisolated var client: CodecClient {
        CodecClient(baseURL: URL(string: "https://first.invalid")!, token: "test-token", transport: self)
    }
    func setStatus(_ value: Int, version: Int = 1) { status = value; self.version = version }
    func setSecondStatus(_ value: Int) { secondStatus = value }
    func holdNextLibrary() { shouldHold = true }
    func releaseLibrary() { held?.resume(); held = nil }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let isLibrary = request.url!.path == "/api/v1/library"
        let responseStatus = request.url!.host == "second.invalid" ? secondStatus : status
        let currentVersion = version
        if isLibrary {
            libraryRequests += 1
            if shouldHold {
                shouldHold = false
                await withCheckedContinuation { held = $0 }
            }
        }
        let body: String
        switch request.url!.path {
        case "/health": body = "{\"ok\":true,\"schema\":\"loud.sync.v1\"}"
        case "/api/v1/library": body = "{\"root_path\":\"\(request.url!.host!)\",\"scanned_at\":\(currentVersion)}"
        default: body = "[]"
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: responseStatus, httpVersion: nil, headerFields: nil)!)
    }
}
