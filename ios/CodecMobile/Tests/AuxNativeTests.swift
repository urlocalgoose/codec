import AVFoundation
import Foundation
import XCTest
@testable import Codec

@MainActor final class AuxNativeTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "codec.aux.v2.identity")
        CredentialStore.write("", account: "aux-participant")
        super.tearDown()
    }
    func testScopedCachesSeparateServerAndPrincipalWithoutEmbeddingCredentials() {
        let a = CredentialStore.cacheScope(server: "https://a.invalid", principal: "secret-a")
        let b = CredentialStore.cacheScope(server: "https://b.invalid", principal: "secret-a")
        let guest = CredentialStore.cacheScope(server: "https://a.invalid", principal: "secret-guest")
        XCTAssertNotEqual(a, b); XCTAssertNotEqual(a, guest)
        XCTAssertEqual(a.count, 64); XCTAssertFalse(a.contains("secret"))
    }
    func testKeychainMigrationRemovesThePlaintextValueOnlyAfterSaving() {
        let key = "codec.test.secret.\(UUID().uuidString)"
        UserDefaults.standard.set("test-only-secret", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key); CredentialStore.write("", account: key) }
        XCTAssertEqual(CredentialStore.migrate(account: key, legacyKeys: [key]), "test-only-secret")
        XCTAssertEqual(CredentialStore.read(key), "test-only-secret")
        XCTAssertNil(UserDefaults.standard.string(forKey: key))
    }
    func testOpeningInvitationDoesNotJoinAndSharedSpeakerJoinNeverCreatesLocalAudio() async throws {
        let transport = AuxNativeTransport()
        let aux = AuxController { url, token in AuxClient(baseURL: url, token: token, transport: transport) }
        var playersCreated = 0
        let player = PlayerController(makePlayer: { item in playersCreated += 1; return AVPlayer(playerItem: item) })
        aux.presentInvitation(server: transport.base, secret: "invitation")
        await aux.inspectInvitation()
        XCTAssertNil(aux.state)
        let previewPaths = await transport.paths
        XCTAssertEqual(previewPaths, ["/api/v2/aux/invitation"])
        await aux.join(player: player)
        XCTAssertTrue(aux.isGuest); XCTAssertFalse(aux.listening)
        XCTAssertEqual(playersCreated, 0); XCTAssertFalse(player.syncEnabled)
        XCTAssertEqual(CredentialStore.read("aux-participant"), "participant-test-secret")
        XCTAssertNil(UserDefaults.standard.string(forKey: "participant-test-secret"))
        aux.muted = true; aux.stopListening()
        let paths = await transport.paths
        XCTAssertFalse(paths.contains { $0.contains("playback") || $0.contains("commands") })
        await aux.leaveOrEnd()
        XCTAssertNil(aux.state); XCTAssertNil(CredentialStore.read("aux-participant"))
        XCTAssertNil(player.auxTransport)
    }
    func testRestoredGuestRoleIsValidatedAndRevocationDropsOnlySessionAuthority() async throws {
        let transport = AuxNativeTransport()
        let factory: @Sendable (URL, String?) -> AuxClient = { url, token in AuxClient(baseURL: url, token: token, transport: transport) }
        let first = AuxController(makeClient: factory)
        let player = PlayerController()
        first.presentInvitation(server: transport.base, secret: "invitation")
        await first.inspectInvitation(); await first.join(player: player)
        let restored = AuxController(makeClient: factory)
        let owner = CodecClient(baseURL: URL(string: "https://personal.invalid")!, token: "personal-test-secret")
        await restored.restore(personal: owner, player: player)
        XCTAssertEqual(restored.state?.role, "guest")
        XCTAssertEqual(restored.sessionClient?.token, "participant-test-secret")
        XCTAssertEqual(owner.token, "personal-test-secret")
        await transport.revoke()
        await restored.refresh()
        XCTAssertNil(restored.state); XCTAssertNil(CredentialStore.read("aux-participant"))
        XCTAssertEqual(owner.token, "personal-test-secret")
        await first.leaveOrEnd()
    }
    func testSelectedHostHandoffRetainsTheAudioEngineAndDoesNotPauseIt() throws {
        let engine = AuxHandoffPlayer()
        let controller = PlayerController(makePlayer: { _ in engine }, activateAudioSession: {})
        let media = FileManager.default.temporaryDirectory.appendingPathComponent("codec-aux-\(UUID().uuidString).wav")
        try Data([0]).write(to: media)
        defer { try? FileManager.default.removeItem(at: media) }
        let track = CodecTrack(id: "one", title: "One", artist: "", album: "", durationSeconds: 200,
                               audioURL: media, fingerprint: "one")
        controller.play(track, from: [track])
        let pauseCalls = engine.pauseCalls
        let handed = try XCTUnwrap(controller.detachForAux(preserveAudio: true))
        XCTAssertTrue(handed.player === engine)
        XCTAssertEqual(handed.fingerprint, "one")
        XCTAssertEqual(engine.pauseCalls, pauseCalls)
        XCTAssertFalse(controller.syncEnabled)
        var commands: [String] = []
        controller.auxTransport = { commands.append($0) }
        controller.pausePlayback(); controller.next(); controller.previous(); controller.seek(to: 40)
        XCTAssertEqual(commands, ["pause", "next"])
        controller.handleInterruption(typeValue: AVAudioSession.InterruptionType.began.rawValue, optionsValue: nil)
        controller.handleRouteChange(reasonValue: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue)
        XCTAssertEqual(commands, ["pause", "next"], "Local lifecycle cannot send a shared pause")
        controller.auxTransport = nil
        engine.pause()
    }
}

@MainActor private final class AuxHandoffPlayer: AVPlayer {
    nonisolated(unsafe) var pauseCalls = 0
    override func play() { }
    override func pause() { pauseCalls += 1 }
}

private actor AuxNativeTransport: CodecTransport {
    nonisolated let base = URL(string: "https://aux-native.invalid")!
    private(set) var paths: [String] = []
    private var revoked = false
    func revoke() { revoked = true }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url!.path; paths.append(path)
        let body: String
        var status = 200
        switch path {
        case "/api/v2/aux/invitation": body = #"{"schema":"codec.aux.v2","host_name":"Fixture host","mode":"shared_speaker","expires_at":2000000000}"#
        case "/api/v2/aux/join": body = "{\"session_id\":\"fixture\",\"participant_id\":\"participant\",\"participant_token\":\"participant-test-secret\",\"state\":\(state)}"
        case "/api/v2/aux/sessions/fixture/catalog": body = #"{"schema":"codec.aux.v2","tracks":[]}"#
        case "/api/v2/aux/sessions/fixture/state": body = revoked ? "{}" : state; status = revoked ? 403 : 200
        case "/api/v2/aux/sessions/fixture/members/participant": body = ""; status = 204
        default: body = "{}"; status = 404
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    private var state: String {
        #"{"schema":"codec.aux.v2","session_id":"fixture","mode":"shared_speaker","host_name":"Fixture host","role":"guest","participant_id":"participant","expires_at":2000000000,"revision":1,"server_time_ms":1700000000000,"status":"paused","position_seconds":0,"anchor_time_ms":1700000000000,"current":null,"queue":[],"allow_saves":false,"allow_contributions":false}"#
    }
}
