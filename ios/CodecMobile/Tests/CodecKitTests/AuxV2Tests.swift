import Foundation
import Testing
@testable import CodecKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite struct AuxV2Tests {
    let base = URL(string: "https://aux.example")!
    private var stateJSON: String {
        #"{"schema":"codec.aux.v2","session_id":"session-1","mode":"listen_together","host_name":"Host","role":"guest","participant_id":"person-1","expires_at":2000000000,"revision":4,"server_time_ms":1700000000000,"status":"playing","position_seconds":20,"anchor_time_ms":1700000000000,"current":{"entry_id":"entry-1","participant_id":"host","track":{"fingerprint":"song","title":"Song","artist":"Artist","album":"Album","duration_seconds":30,"media_url":"/api/v2/aux/sessions/session-1/tracks/song/audio","artwork_url":""}},"queue":[],"allow_saves":false,"allow_contributions":false}"#
    }
    private func response(_ text: String, status: Int = 200) -> (Data, URLResponse) {
        (Data(text.utf8), HTTPURLResponse(url: base, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    @Test func invitationAndJoinCannotForwardPersonalCredential() async throws {
        let transport = RecordingTransport()
        transport.responses = [response(#"{"schema":"codec.aux.v2","host_name":"Host","mode":"listen_together","expires_at":2000000000}"#), response("{\"session_id\":\"session-1\",\"participant_id\":\"person-1\",\"participant_token\":\"guest-secret\",\"state\":\(stateJSON)}")]
        let client = AuxClient(baseURL: base, token: "personal-secret", transport: transport)
        _ = try await client.invitation(secret: "invite-secret")
        let joined = try await client.join(secret: "invite-secret", name: "Guest")
        #expect(joined.participantToken == "guest-secret")
        #expect(transport.requests.count == 2)
        for request in transport.requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.url?.query == nil)
            #expect(request.url?.absoluteString.contains("secret") == false)
        }
    }
    @Test func sessionCommandsCarryOnlySessionAuthorityAndRequiredRevision() async throws {
        let transport = RecordingTransport(); transport.responses = [response(stateJSON)]
        let client = AuxClient(baseURL: base, token: "participant-secret", transport: transport)
        _ = try await client.command("session-1", kind: "reorder", revision: 4, entryIDs: ["two", "one"])
        let request = try #require(transport.requests.first)
        #expect(request.url?.path == "/api/v2/aux/sessions/session-1/commands")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer participant-secret")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(Set(body.keys) == ["command_id", "kind", "expected_revision", "entry_ids"])
        #expect(body["expected_revision"] as? Int == 4)
    }
    @Test func mediaCredentialsCannotEscapeOriginOrSession() {
        let client = AuxClient(baseURL: base, token: "secret")
        #expect(client.mediaURL("/api/v2/aux/sessions/session-1/tracks/song/audio", sessionID: "session-1") != nil)
        for invalid in ["https://attacker.example/api/v2/aux/sessions/session-1/tracks/song/audio", "/api/v1/tracks/song/audio", "/api/v2/aux/sessions/other/tracks/song/audio", "//attacker.example/audio", "file:///audio", "/api/v2/aux/sessions/session-1/tracks/song/audio?token=secret", "https://name:password@aux.example/api/v2/aux/sessions/session-1/tracks/song/audio"] {
            #expect(client.mediaURL(invalid, sessionID: "session-1") == nil)
        }
    }
    @Test func timelineAdvancesOnlyWhilePlayingAndClampsAtDuration() throws {
        let state = try JSONDecoder().decode(AuxState.self, from: Data(stateJSON.utf8))
        #expect(state.position(elapsed: 2.5) == 22.5)
        #expect(state.position(elapsed: 100) == 30)
        #expect(state.position(elapsed: -10) == 20)
        let paused = try JSONDecoder().decode(AuxState.self, from: Data(stateJSON.replacingOccurrences(of: #""status":"playing""#, with: #""status":"paused""#).utf8))
        #expect(paused.position(elapsed: 100) == 20)
    }
    @Test func rejectedGuestRequestSurfacesFailureWithoutReturningCachedState() async throws {
        let transport = RecordingTransport(); transport.responses = [response("{}", status: 403)]
        let client = AuxClient(baseURL: base, token: "revoked", transport: transport)
        do { _ = try await client.state("session-1"); Issue.record("Revocation must fail") }
        catch CodecClientError.httpStatus(let code, _) { #expect(code == 403) }
    }
    @Test func ownerSourcePermissionIsExplicitAndDefaultsAreNotInferred() async throws {
        let transport = RecordingTransport(); transport.responses = [response(#"{"source_origin":"https://aux.example","token":"limited-grant"}"#)]
        let client = AuxClient(baseURL: base, token: "owner-secret", transport: transport)
        _ = try await client.grant(fingerprint: "one-song", sessionID: "session-1", sessionOrigin: "https://host.example", allowCopy: false)
        let request = try #require(transport.requests.first)
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["allow_copy"] as? Bool == false)
        #expect(body["fingerprint"] as? String == "one-song")
        #expect(body["session_origin"] as? String == "https://host.example")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer owner-secret")
    }
    @Test func exactMembershipIsCheckedOnlyAgainstThePersonalDestination() async throws {
        let transport = RecordingTransport(); transport.responses = [response(#"{"fingerprint":"exact-song","status":"repair","track_id":"local-123"}"#)]
        let destination = AuxClient(baseURL: URL(string: "https://personal.example")!, token: "personal-secret", transport: transport)
        let membership = try await destination.membership("exact-song")
        #expect(membership.status == "repair")
        #expect(transport.requests.first?.url?.host == "personal.example")
        #expect(transport.requests.first?.url?.path == "/api/v2/aux/membership/exact-song")
    }
    @Test func ownerMediaUsesLimitedBearerAndRejectsForeignSourceURLs() throws {
        let state = try JSONDecoder().decode(AuxState.self, from: Data(stateJSON.utf8))
        let track = try #require(state.current?.track)
        let client = AuxClient(baseURL: base, token: "owner-secret")
        let media = try #require(client.mediaRequest(for: track, sessionID: "session-1", mediaToken: "media-only-secret"))
        #expect(media.value(forHTTPHeaderField: "Authorization") == "Bearer media-only-secret")
        #expect(media.url?.query == nil)
        let foreign = try JSONDecoder().decode(AuxState.self, from: Data(stateJSON.replacingOccurrences(of: "/api/v2/aux/sessions/session-1/tracks/song/audio", with: "https://foreign.example/api/v2/aux/grants/media/song/audio?access_token=limited").utf8))
        #expect(client.mediaRequest(for: try #require(foreign.current?.track), sessionID: "session-1") == nil)
    }

}
