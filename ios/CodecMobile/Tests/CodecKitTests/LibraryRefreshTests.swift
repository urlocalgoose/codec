import Foundation
import Testing
@testable import CodecKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite struct LibraryRefreshTests {
    let base = URL(string: "https://library.test")!

    func response(_ status: Int, etag: String? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: base, statusCode: status, httpVersion: nil,
                        headerFields: etag.map { ["ETag": $0] })!
    }

    @Test func unchangedLibraryReusesDecodedSnapshotAndNewVersionReplacesIt() async throws {
        let transport = RecordingTransport()
        transport.responses = [
            (Data(#"{"scanned_at":1}"#.utf8), response(200, etag: "\"one\"")),
            (Data(), response(304)),
            (Data(#"{"scanned_at":2}"#.utf8), response(200, etag: "\"two\"")),
            (Data(), response(304))
        ]
        let client = CodecClient(baseURL: base, token: "test", transport: transport)
        #expect(try await client.library().scannedAt == 1)
        #expect(try await client.library().scannedAt == 1)
        #expect(try await client.library().scannedAt == 2)
        #expect(try await client.library().scannedAt == 2)
        #expect(transport.requests.map { $0.value(forHTTPHeaderField: "If-None-Match") } == [nil, "\"one\"", "\"one\"", "\"two\""])
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test" })
    }

    @Test func errorsDoNotReturnCachedDataOrPreventRetry() async throws {
        let transport = RecordingTransport()
        transport.responses = [
            (Data("{}".utf8), response(200, etag: "\"one\"")),
            (Data(), response(401)),
            (Data("invalid".utf8), response(200, etag: "\"bad\"")),
            (Data(), response(304))
        ]
        let client = CodecClient(baseURL: base, transport: transport)
        _ = try await client.library()
        await #expect(throws: CodecClientError.httpStatus(401, "")) { try await client.library() }
        await #expect(throws: (any Error).self) { try await client.library() }
        _ = try await client.library()
        #expect(transport.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"one\"")
    }

    @Test func newClientsDoNotShareValidatorsAndMissingETagsClearOldOnes() async throws {
        let transport = RecordingTransport()
        transport.responses = [
            (Data("{}".utf8), response(200, etag: "\"one\"")),
            (Data("{}".utf8), response(200)),
            (Data("{}".utf8), response(200)),
            (Data(), response(304))
        ]
        let client = CodecClient(baseURL: base, token: "host", transport: transport)
        _ = try await client.library()
        _ = try await client.library()
        _ = try await client.library()
        let guest = CodecClient(baseURL: base, token: "guest", transport: transport)
        await #expect(throws: CodecClientError.httpStatus(304, "")) { try await guest.library() }
        #expect(transport.requests.map { $0.value(forHTTPHeaderField: "If-None-Match") } == [nil, "\"one\"", nil, nil])
    }

    @Test func overlappingRefreshesUseOneRequest() async throws {
        let transport = SlowLibraryTransport()
        let client = CodecClient(baseURL: base, transport: transport)
        try await withThrowingTaskGroup(of: CodecLibrary.self) { group in
            for _ in 0..<20 { group.addTask { try await client.library() } }
            for try await library in group { #expect(library.tracks.isEmpty) }
        }
        #expect(await transport.requests == 1)
    }

    @Test(arguments: [false, true])
    func cancellingAnOldPathPreservesValidatorsAndDoesNotClearItsReplacement(lateFailure: Bool) async throws {
        let transport = SuspendedLibraryTransport()
        let client = CodecClient(baseURL: base, transport: transport)
        #expect(try await client.library().scannedAt == 1)

        // This transport deliberately ignores cancellation, like a response
        // that has already left URLSession and is waiting to be delivered.
        let oldRequest = Task { try await client.library() }
        try await waitForRequests(2, transport: transport)
        await client.cancelPendingLibraryRequest()

        let replacement = Task { try await client.library() }
        try await waitForRequests(3, transport: transport)
        #expect(await transport.validators == [nil, "\"one\"", "\"one\""])

        // Finish the obsolete request while its replacement is still waiting.
        // Neither a late success nor a late failure may clear that new task.
        await transport.finishOldRequest(failing: lateFailure)
        await #expect(throws: CancellationError.self) { try await oldRequest.value }

        let releaseReplacement = Task {
            try await Task.sleep(for: .milliseconds(100))
            await transport.finishReplacement()
        }
        let joined = try await client.library()
        #expect(joined.scannedAt == 2)
        #expect(try await replacement.value.scannedAt == 2)
        try await releaseReplacement.value
        #expect(await transport.requests.count == 3)

        // An idle cancellation must also preserve the newly validated cache.
        await client.cancelPendingLibraryRequest()
        #expect(try await client.library().scannedAt == 2)
        #expect(await transport.validators == [nil, "\"one\"", "\"one\"", "\"two\""])
    }

    private func waitForRequests(_ count: Int, transport: SuspendedLibraryTransport) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await transport.requests.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await transport.requests.count >= count, "A replacement request must start without waiting for the obsolete response")
    }
}

private actor SuspendedLibraryTransport: CodecTransport {
    private(set) var requests: [URLRequest] = []
    private var suspended: [Int: CheckedContinuation<(Data, URLResponse), any Error>] = [:]

    var validators: [String?] { requests.map { $0.value(forHTTPHeaderField: "If-None-Match") } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let index = requests.count
        requests.append(request)
        if index == 0 { return response(for: request, scannedAt: 1, etag: "\"one\"") }
        if index == 1 || index == 2 {
            return try await withCheckedThrowingContinuation { suspended[index] = $0 }
        }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: nil, headerFields: nil)!)
    }

    func finishOldRequest(failing: Bool) {
        guard let continuation = suspended.removeValue(forKey: 1) else {
            Issue.record("The obsolete request was not suspended")
            return
        }
        if failing {
            continuation.resume(throwing: URLError(.networkConnectionLost))
        } else {
            continuation.resume(returning: response(for: requests[1], scannedAt: 99, etag: "\"obsolete\""))
        }
    }

    func finishReplacement() {
        guard let continuation = suspended.removeValue(forKey: 2) else {
            Issue.record("The replacement request was not suspended")
            return
        }
        continuation.resume(returning: response(for: requests[2], scannedAt: 2, etag: "\"two\""))
    }

    private func response(for request: URLRequest, scannedAt: Int, etag: String) -> (Data, URLResponse) {
        (Data("{\"scanned_at\":\(scannedAt)}".utf8),
         HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["ETag": etag])!)
    }
}

private actor SlowLibraryTransport: CodecTransport {
    private(set) var requests = 0
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests += 1
        try await Task.sleep(for: .milliseconds(100))
        return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"one\""])!)
    }
}
