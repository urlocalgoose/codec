import Foundation
import CodecKit

struct Configuration: Decodable {
    let serverA: URL
    let serverB: URL
    let tokenA: String
    let tokenB: String
    let audioFile: String
    let artworkFile: String
    let phase: String
    let reportFile: String
    let allowAuxV1Retirement: Bool?
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

actor RecordingTransport: CodecTransport {
    private var statuses: [Int] = []
    private let session = URLSession(configuration: .ephemeral)

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let result = try await session.data(for: request)
        if let response = result.1 as? HTTPURLResponse { statuses.append(response.statusCode) }
        return result
    }

    func observed(_ status: Int) -> Bool { statuses.contains(status) }
}

@main @MainActor
struct CompatibilityRunner {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else { throw Failure("Expected a private configuration file") }
            let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            guard [config.serverA, config.serverB].allSatisfy({ $0.scheme == "http" && $0.host == "127.0.0.1" }),
                  config.serverA != config.serverB else { throw Failure("Only two distinct loopback servers are allowed") }
            var checks: [String] = []
            let recording = RecordingTransport()
            let a = CodecClient(baseURL: config.serverA, token: config.tokenA, transport: recording)
            let b = CodecClient(baseURL: config.serverB, token: config.tokenB)
            let audio = try Data(contentsOf: URL(fileURLWithPath: config.audioFile))
            let artwork = try Data(contentsOf: URL(fileURLWithPath: config.artworkFile))
            let libraryA = try await a.library()
            let libraryB = try await b.library()
            let expectedTracksA = config.phase == "after-restart" ? 3 : 2
            try require(libraryA.tracks.count == expectedTracksA && libraryB.tracks.count == 2, "Both isolated libraries decode in the shipped client")
            let tracksA = libraryA.tracks.sorted { $0.fingerprint < $1.fingerprint }
            let tracksB = libraryB.tracks.sorted { $0.fingerprint < $1.fingerprint }
            let first = tracksA[0]
            checks.append("unchanged build 7 client decodes both candidate libraries")

            if config.phase == "after-restart" {
                guard let retained = libraryA.playlists.first(where: { $0.name == "Compatibility retained" }) else { throw Failure("Playlist did not survive restart") }
                try require(retained.trackIDs == [first.id] && first.isLiked, "Playlist membership and likes survive restart")
                guard let cover = retained.artworkURL.flatMap(URL.init(string:)) else { throw Failure("Playlist cover lost on restart") }
                let coverData = try await media(cover, client: a)
                try require(coverData.0 == artwork, "Playlist cover bytes survive restart")
                let state = try await a.playbackState()
                try require(state?.state == "paused" && state?.track?.fingerprint == first.fingerprint, "Playback survives restart")
                guard let granted = state?.context.queuedTracks.first?.mediaURL else { throw Failure("Cross-server grant disappeared on restart") }
                let grantedData = try await media(granted, client: a, range: "bytes=0-31")
                try require(grantedData.1.statusCode == 206 && grantedData.0 == audio.prefix(32), "Cross-server media grant survives restart")
                if config.allowAuxV1Retirement == true {
                    try await expectStatus(410) { _ = try await a.listAuxSessions() }
                    try await expectStatus(410) { _ = try await CodecClient(baseURL: config.serverA).joinAuxSession(code: "OLD1") }
                    checks.append("declared security exception: legacy Aux remains explicitly retired after restart")
                } else {
                    let sessions = try await a.listAuxSessions()
                    try require(sessions.isEmpty, "Ended Aux sessions remain ended after restart")
                    checks.append("ended Aux sessions remain revoked across restart")
                }
                checks += ["playlist, likes and exact cover bytes persist across server restart", "owner shared playback and cross-server media grants persist across restart"]
            } else {
                let healthA = try await a.health()
                let healthB = try await b.health()
                try require(healthA.ok && healthB.ok && healthA.schema == "loud.sync.v1" && healthA.playbackSchema == "loud.playback.v2", "Health schema changed")
                try require(healthA.serverID != nil && healthB.serverID != nil && healthA.serverID != healthB.serverID, "Server identities must be independent")
                try await expectStatus(401) { _ = try await CodecClient(baseURL: config.serverA).library() }
                try await expectStatus(401) { _ = try await CodecClient(baseURL: config.serverB, token: config.tokenA).library() }
                try await expectStatus(401) { _ = try await CodecClient(baseURL: config.serverA, token: config.tokenB).library() }
                try require(Set(tracksA.map(\.fingerprint)).isDisjoint(with: Set(tracksB.map(\.fingerprint))), "Track fixtures leaked between servers")
                checks.append("owner authentication, unique server identities and cross-server token isolation")

                let cached = try await a.library()
                let saw304 = await recording.observed(304)
                try require(cached == libraryA && saw304, "Shipped client conditional library cache must accept 304")
                checks.append("real ETag/304 revalidation through shipped LibraryCache")
                guard let audioURL = a.audioURL(for: first), let artURL = a.artworkURL(for: first) else { throw Failure("Missing media URLs") }
                try require(first.audioURL != nil && first.artworkURL != nil, "Library must carry track audio and artwork URLs")
                let full = try await media(audioURL, client: a)
                let part = try await media(audioURL, client: a, range: "bytes=0-31")
                let cover = try await media(artURL, client: a)
                try require(full.0 == audio && part.1.statusCode == 206 && part.0 == audio.prefix(32), "Streaming/download bytes or range broken")
                try require(part.1.value(forHTTPHeaderField: "Content-Range") == "bytes 0-31/\(audio.count)", "Incorrect Content-Range")
                try require(cover.0 == artwork && cover.1.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("image/png") == true, "Track cover bytes or MIME changed")
                checks.append("authenticated artwork, full downloads and exact HTTP byte ranges")

                let playlist = try await a.createPlaylist(named: "Compatibility retained")
                try await a.addToPlaylist(id: playlist.id, fingerprint: first.fingerprint)
                try await a.addToPlaylist(id: playlist.id, fingerprint: tracksA[1].fingerprint)
                try await a.setPlaylistTracks(id: playlist.id, trackIDs: [tracksA[1].id, first.id])
                var updated = try await a.library()
                try require(updated.playlists.first(where: { $0.id == playlist.id })?.trackIDs == [tracksA[1].id, first.id], "Playlist reorder failed")
                try await a.removeFromPlaylist(id: playlist.id, fingerprint: tracksA[1].fingerprint)
                try await a.setPlaylistArtwork(id: playlist.id, imageData: artwork, contentType: "image/png")
                try await a.setLiked(fingerprint: first.fingerprint, liked: true)
                updated = try await a.library()
                try require(updated.playlists.first(where: { $0.id == playlist.id })?.trackIDs == [first.id], "Playlist remove failed")
                try require(updated.tracks.first(where: { $0.id == first.id })?.isLiked == true && updated.stats.likedCount == 1, "Like did not persist")
                guard let playlistCover = updated.playlists.first(where: { $0.id == playlist.id })?.artworkURL.flatMap(URL.init(string:)) else { throw Failure("Missing playlist artwork URL") }
                let custom = try await media(playlistCover, client: a)
                try require(custom.0 == artwork, "Custom playlist artwork did not round-trip")
                try await a.setLiked(fingerprint: first.fingerprint, liked: false)
                let unliked = try await a.library()
                try require(unliked.tracks.first(where: { $0.id == first.id })?.isLiked == false, "Unlike failed")
                try await a.setLiked(fingerprint: first.fingerprint, liked: true)
                let disposable = try await a.createPlaylist(named: "Delete collection only")
                try await a.addToPlaylist(id: disposable.id, fingerprint: first.fingerprint)
                try await a.deletePlaylist(id: disposable.id)
                updated = try await a.library()
                try require(updated.tracks.count == 2 && updated.tracks.first(where: { $0.id == first.id })?.isLiked == true && !updated.playlists.contains(where: { $0.id == disposable.id }), "Deleting playlist must preserve music and likes")
                let unchangedB = try await b.library()
                try require(unchangedB == libraryB, "Mutating server A changed server B's library")
                checks += ["create/add/reorder/remove/delete playlist using shipped wire format", "like/unlike, cache invalidation and cover upload without losing music", "server B library remains unchanged while server A is edited"]

                let deviceID = "compat-ios-1.4-7"
                try await a.publishPlaybackDevice(CodecPlaybackDevice(deviceID: deviceID, name: "Compatibility test"))
                let devices = try await a.playbackDevices()
                try require(devices.contains(where: { $0.deviceID == deviceID }), "Published device missing")
                let context = PlaybackContext(playbackSource: tracksA.map(CodecTrackReference.init(track:)), playlistID: playlist.id)
                var play = PlaybackCommand(kind: "play", deviceID: deviceID, track: CodecTrackReference(track: first), context: context)
                play.expectedRevision = 0
                let playing = try await a.sendPlaybackCommand(play)
                let duplicate = try await a.sendPlaybackCommand(play)
                try require(playing.isPlaying && playing.revision == duplicate.revision && playing.context.playlistID == playlist.id, "Playback start, origin or command idempotency failed")
                var stale = PlaybackCommand(kind: "set_queue", deviceID: deviceID, context: context)
                stale.expectedRevision = 0
                try await expectStatus(409) { _ = try await a.sendPlaybackCommand(stale) }
                let idleB = try await b.playbackState()
                try require(idleB == nil, "Playback leaked to server B")
                checks.append("device presence, playback origin, revisions, duplicate commands and conflict protection")

                let eventSession = URLSession(configuration: .ephemeral)
                defer { eventSession.invalidateAndCancel() }
                let (bytes, eventResponse) = try await eventSession.bytes(for: a.playbackEventsRequest())
                try require((eventResponse as? HTTPURLResponse)?.statusCode == 200, "SSE rejected shipped event request")
                let events = Task { () throws -> (Bool, Bool) in
                    var sawInitial = false
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        let payload = try JSONDecoder().decode(PlaybackEventPayload.self, from: Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8))
                        if payload.playbackState?.revision == playing.revision { sawInitial = true }
                        if let state = payload.playbackState, state.revision > playing.revision, state.state == "paused" { return (sawInitial, true) }
                    }
                    throw Failure("SSE ended without a playback update")
                }
                let paused = try await a.sendPlaybackCommand(PlaybackCommand(kind: "pause", deviceID: deviceID, positionSeconds: 0.1))
                let stream = try await events.value
                try require(stream.0 && stream.1 && paused.revision > playing.revision, "Shipped SSE model failed initial snapshot or live event")
                eventSession.invalidateAndCancel()
                checks.append("live SSE initial state and subsequent playback event decode with shipped models")

                // The three CodecKit source files remain byte-for-byte frozen.
                // This opt-in harness policy declares the security cutoff rather
                // than making the unsafe old Aux behavior appear compatible.
                let retired = config.allowAuxV1Retirement == true
                var guest: CodecClient?
                var legacyCode: String?
                if retired {
                    try await expectStatus(410) { _ = try await a.createAuxSession() }
                    try await expectStatus(410) { _ = try await a.listAuxSessions() }
                    try await expectStatus(410) { _ = try await CodecClient(baseURL: config.serverA).joinAuxSession(code: "OLD1") }
                    checks.append("declared security exception: unchanged build 7 Aux create/list/join receive explicit HTTP 410")
                } else {
                    let aux = try await a.createAuxSession()
                    let listed = try await a.listAuxSessions()
                    try require(listed.contains(where: { $0.code == aux.code }), "Created Aux not listed")
                    let joined = try await CodecClient(baseURL: config.serverA).joinAuxSession(code: aux.code.lowercased())
                    guard let guestToken = joined.guestToken else { throw Failure("Aux join returned no credential") }
                    let joinedClient = CodecClient(baseURL: config.serverA, token: guestToken)
                    guest = joinedClient; legacyCode = aux.code
                    let guestLibrary = try await joinedClient.library()
                    try require(guestLibrary.tracks.count == 2, "Aux guest cannot browse")
                    _ = try await media(audioURL, client: joinedClient, range: "bytes=0-31")
                    try await expectStatus(403) { _ = try await joinedClient.createPlaylist(named: "Must be denied") }
                    try await expectStatus(403) { try await joinedClient.setLiked(fingerprint: first.fingerprint, liked: false) }
                    try await expectStatus(401) { _ = try await CodecClient(baseURL: config.serverB, token: guestToken).library() }
                    try await expectStatus(404) { _ = try await CodecClient(baseURL: config.serverB).joinAuxSession(code: aux.code) }
                }

                var grantRequest = try b.request(method: "POST", path: "/api/v1/media-grants")
                grantRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                grantRequest.httpBody = try JSONEncoder().encode(["fingerprints": [tracksB[0].fingerprint]])
                let (grantData, grantResponse) = try await URLSession.shared.data(for: grantRequest)
                struct Grant: Decodable { let token: String }
                try require((grantResponse as? HTTPURLResponse)?.statusCode == 201, "Media grant creation failed")
                let grant = try JSONDecoder().decode(Grant.self, from: grantData)
                var components = URLComponents(url: b.audioURL(for: tracksB[0])!, resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "access_token", value: grant.token)]
                let grantedURL = components.url!
                let foreign = CodecTrack(id: tracksB[0].id, title: tracksB[0].title, artist: tracksB[0].artist, album: tracksB[0].album, audioURL: grantedURL, fingerprint: tracksB[0].fingerprint)
                let reference = CodecTrackReference(track: foreign)
                try require(reference.mediaURL == grantedURL && a.authHeaders(for: grantedURL).isEmpty, "Cross-server track must retain grant without leaking owner authorization")
                var guestContext = paused.context
                guestContext.queuedTracks = [reference]
                var queue = PlaybackCommand(kind: "set_queue", deviceID: retired ? deviceID : "compat-aux-guest", context: guestContext)
                queue.expectedRevision = paused.revision
                let queued = try await (guest ?? a).sendPlaybackCommand(queue)
                let observed = try await a.playbackState()
                try require(queued.context.queuedTracks.first?.fingerprint == tracksB[0].fingerprint && observed?.revision == queued.revision, "Authorized cross-server queue did not reach host")
                let foreignAudio = try await media(grantedURL, client: a, range: "bytes=0-31")
                try require(foreignAudio.1.statusCode == 206 && foreignAudio.0 == audio.prefix(32), "Granted remote track is not streamable")
                var denied = components
                denied.path = b.audioURL(for: tracksB[1])!.path
                let (_, deniedResponse) = try await URLSession.shared.data(from: denied.url!)
                try require((deniedResponse as? HTTPURLResponse)?.statusCode == 401, "Media grant escaped its track scope")
                if let guest, let legacyCode {
                    try await a.endAuxSession(code: legacyCode)
                    try await expectStatus(401) { _ = try await guest.library() }
                    try await expectStatus(404) { _ = try await CodecClient(baseURL: config.serverA).joinAuxSession(code: legacyCode) }
                    checks += ["Aux host/create/join/list, guest playback access and forbidden library writes", "guest token and Aux code isolation", "ending Aux immediately revokes guest access and prevents rejoin"]
                }
                let isolatedB = try await b.playbackState()
                try require(isolatedB == nil, "Commands modified server B playback")
                checks += [retired ? "unchanged owner queue accepts scoped remote media grant without forwarding owner authorization" : "two-server Aux queue accepts scoped remote media grant without forwarding owner authorization", "playback and media-grant isolation across servers"]

                // Add music after this unchanged client has cached the library.
                // Verify the shipped SSE model and cache can discover it.
                let libraryEventsSession = URLSession(configuration: .ephemeral)
                defer { libraryEventsSession.invalidateAndCancel() }
                let (libraryBytes, _) = try await libraryEventsSession.bytes(for: a.playbackEventsRequest())
                let libraryEvent = Task { () throws -> Bool in
                    for try await line in libraryBytes.lines where line.hasPrefix("data:") {
                        let payload = try JSONDecoder().decode(PlaybackEventPayload.self, from: Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8))
                        if payload.type == "library" { return true }
                    }
                    throw Failure("SSE ended without a library update")
                }
                let newFingerprint = String(repeating: "f", count: 64)
                let newTrack = CodecTrack(id: "track_\(newFingerprint)", title: "Added after client connected", artist: "Generated fixture", album: "Protocol compatibility", fingerprint: newFingerprint)
                for (suffix, data, contentType) in [
                    ("", try JSONEncoder().encode(newTrack), "application/json"),
                    ("/audio", audio, "audio/wav"),
                    ("/artwork", artwork, "image/png"),
                ] {
                    var update = try a.request(method: "PUT", path: "/api/v1/tracks/\(newFingerprint)\(suffix)")
                    update.httpBody = data
                    update.setValue(contentType, forHTTPHeaderField: "Content-Type")
                    let (_, response) = try await URLSession.shared.data(for: update)
                    try require((response as? HTTPURLResponse)?.statusCode == 204, "Adding new fixture music failed")
                }
                let notified = try await libraryEvent.value
                let refreshed = try await a.library()
                guard let added = refreshed.tracks.first(where: { $0.fingerprint == newFingerprint }), let addedAudio = a.audioURL(for: added) else { throw Failure("Existing client could not discover new music") }
                let addedData = try await media(addedAudio, client: a, range: "bytes=0-31")
                try require(notified && refreshed.tracks.count == 3 && addedData.0 == audio.prefix(32), "New music must stream after live library refresh without replacing client")
                libraryEventsSession.invalidateAndCancel()
                checks.append("same installed-client code discovers and streams new music after live SSE library update")
            }
            let report: [String: Any] = ["phase": config.phase, "passed": true, "checks": checks, "legacyAuxCompatible": config.allowAuxV1Retirement != true, "compatibilityScope": config.allowAuxV1Retirement == true ? "owner APIs; explicit Aux v1 security retirement" : "full frozen contract"]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: config.reportFile))
            print("\(config.phase): \(checks.count) shipped-client compatibility checks passed")
        } catch {
            // Do not log HTTP bodies or request URLs: Aux/media URLs can contain credentials.
            let message: String
            if let failure = error as? Failure { message = failure.description }
            else if let failure = error as? CodecClientError { message = failure.localizedDescription }
            else if case DecodingError.keyNotFound(let key, let context) = error { message = "Missing JSON key: \((context.codingPath + [key]).map(\.stringValue).joined(separator: "."))" }
            else if case DecodingError.typeMismatch(_, let context) = error { message = "JSON type mismatch at: \(context.codingPath.map(\.stringValue).joined(separator: "."))" }
            else if case DecodingError.valueNotFound(_, let context) = error { message = "Missing JSON value at: \(context.codingPath.map(\.stringValue).joined(separator: "."))" }
            else { message = String(describing: type(of: error)) }
            FileHandle.standardError.write(Data("Compatibility failure: \(message)\n".utf8))
            exit(1)
        }
    }

    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message) }
    }

    static func expectStatus(_ expected: Int, operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch CodecClientError.httpStatus(let status, _) {
            try require(status == expected, "Expected HTTP \(expected), received \(status)")
            return
        }
        throw Failure("Expected HTTP \(expected), but operation succeeded")
    }

    static func media(_ url: URL, client: CodecClient, range: String? = nil) async throws -> (Data, HTTPURLResponse) {
        // Same origin-only header selection used by native media loading.
        guard url.scheme == "http", url.host == "127.0.0.1" else { throw Failure("Media request escaped loopback") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        for (key, value) in client.authHeaders(for: url) { request.setValue(value, forHTTPHeaderField: key) }
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw Failure("Authenticated media load failed") }
        return (data, http)
    }
}
