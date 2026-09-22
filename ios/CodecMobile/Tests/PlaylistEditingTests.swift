import Foundation
import XCTest
@testable import Codec

@MainActor
final class PlaylistEditingTests: XCTestCase {
    private func makeApp(_ fixture: PlaylistEditingFixture) async throws -> AppModel {
        let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let savedPreferences = try UserDefaults.standard.persistentDomain(forName: domain).map {
            try PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0)
        }
        let suite = "PlaylistEditingTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let app = AppModel(client: fixture.client, playlistHistoryDefaults: preferences)
        app.activeAuxIsGuest = false
        app.connection = .connected
        app.library = await fixture.snapshot()
        addTeardownBlock { @MainActor in
            app.disconnect()
            preferences.removePersistentDomain(forName: suite)
            if let savedPreferences {
                let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: savedPreferences, format: nil) as? [String: Any])
                UserDefaults.standard.setPersistentDomain(values, forName: domain)
            } else {
                UserDefaults.standard.removePersistentDomain(forName: domain)
            }
        }
        return app
    }

    private func eventually(_ predicate: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard await predicate() else {
            XCTFail("Playlist operation did not reach the expected state")
            throw NSError(domain: "PlaylistEditingTests", code: 1)
        }
    }

    func testDeleteKeepsSongsLikesOtherMembershipAndDownloadedBytes() async throws {
        let fixture = PlaylistEditingFixture()
        let app = try await makeApp(fixture)
        let original = try XCTUnwrap(app.library)
        let playlist = try XCTUnwrap(app.playlist(withID: "mix"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("playlist-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("a.wav")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: audio)
        let downloads = DownloadStore(directory: directory, configuration: .ephemeral)
        defer { downloads.shutdown() }
        let first = try XCTUnwrap(original.tracks.first)
        XCTAssertEqual(downloads.localAudioURL(for: first), audio)

        app.deletePlaylist(playlist)

        XCTAssertNil(app.playlist(withID: "mix"))
        assertSongsPreserved(try XCTUnwrap(app.library?.tracks), from: original.tracks, removing: "mix")
        XCTAssertEqual(app.library?.stats.playlistCount, 1)
        XCTAssertEqual(app.library?.stats.trackCount, 3)
        XCTAssertEqual(app.library?.stats.likedCount, 1)
        XCTAssertEqual(app.playlist(withID: "other")?.trackIDs, ["track_a"])
        XCTAssertEqual(app.playlist(withID: "liked")?.trackIDs, ["track_b"])
        try await eventually { await fixture.completedMutations == 1 }
        await app.refresh()
        XCTAssertNil(app.playlist(withID: "mix"))
        assertSongsPreserved(try XCTUnwrap(app.library?.tracks), from: original.tracks, removing: "mix")
        XCTAssertEqual(app.library?.stats.playlistCount, 1)
        XCTAssertEqual(downloads.localAudioURL(for: first), audio)
        XCTAssertEqual(try Data(contentsOf: audio), bytes)
        let requests = await fixture.requests
        XCTAssertEqual(requests.filter { $0.httpMethod != "GET" }.map { $0.url!.path }, ["/api/v1/playlists/mix"])
        XCTAssertFalse(requests.contains { $0.url!.path.contains("/audio") })
    }

    private func assertSongsPreserved(_ actual: [CodecTrack], from original: [CodecTrack], removing playlistID: String) {
        XCTAssertEqual(actual.count, original.count)
        for (track, old) in zip(actual, original) {
            XCTAssertEqual(track.id, old.id)
            XCTAssertEqual(track.fingerprint, old.fingerprint)
            XCTAssertEqual(track.title, old.title)
            XCTAssertEqual(track.artist, old.artist)
            XCTAssertEqual(track.album, old.album)
            XCTAssertEqual(track.audioURL, old.audioURL)
            XCTAssertEqual(track.artworkURL, old.artworkURL)
            XCTAssertEqual(track.isLiked, old.isLiked)
            XCTAssertEqual(track.playlistIDs, old.playlistIDs.filter { $0 != playlistID })
        }
    }

    func testRapidRemovalsResolveCurrentMembershipAndSerializeRequests() async throws {
        let fixture = PlaylistEditingFixture()
        let app = try await makeApp(fixture)
        let stalePlaylist = try XCTUnwrap(app.playlist(withID: "mix"))
        let tracks = try XCTUnwrap(app.library?.tracks)
        await fixture.holdNextMutation()

        app.removeTrack(tracks[0], from: stalePlaylist)
        app.removeTrack(tracks[1], from: stalePlaylist)

        XCTAssertEqual(app.playlist(withID: "mix")?.trackIDs, ["track_c"])
        try await eventually { await fixture.mutationIsHeld }
        try await Task.sleep(for: .milliseconds(20))
        let pendingRequests = await fixture.mutationRequests
        XCTAssertEqual(pendingRequests.count, 1, "A second edit must wait for the first acknowledgement")
        await fixture.releaseMutation()
        try await eventually { await fixture.completedMutations == 2 }
        await app.refresh()
        XCTAssertEqual(app.playlist(withID: "mix")?.trackIDs, ["track_c"])
        let paths = await fixture.mutationRequests.map { $0.url!.path }
        XCTAssertEqual(paths, ["/api/v1/playlists/mix/tracks/a", "/api/v1/playlists/mix/tracks/b"])
    }

    func testAddThenRemoveWithStalePlaylistKeepsUserOrder() async throws {
        let fixture = PlaylistEditingFixture(membership: ["track_a"])
        let app = try await makeApp(fixture)
        let stalePlaylist = try XCTUnwrap(app.playlist(withID: "mix"))
        let added = try XCTUnwrap(app.library?.tracks.last)
        await fixture.holdNextMutation()

        app.addTrack(added, to: stalePlaylist)
        XCTAssertEqual(app.playlist(withID: "mix")?.trackIDs, ["track_a", "track_c"])
        app.removeTrack(added, from: stalePlaylist)
        XCTAssertEqual(app.playlist(withID: "mix")?.trackIDs, ["track_a"])
        try await eventually { await fixture.mutationIsHeld }
        await fixture.releaseMutation()
        try await eventually { await fixture.completedMutations == 2 }
        await app.refresh()
        XCTAssertEqual(app.playlist(withID: "mix")?.trackIDs, ["track_a"])
        let methods = await fixture.mutationRequests.map(\.httpMethod)
        XCTAssertEqual(methods, ["POST", "DELETE"])
    }

    func testDeleteFailureRestoresOnlyPlaylistAndPreservesUnrelatedChanges() async throws {
        let fixture = PlaylistEditingFixture()
        let app = try await makeApp(fixture)
        let playlist = try XCTUnwrap(app.playlist(withID: "mix"))
        await fixture.holdNextMutation()
        app.deletePlaylist(playlist)
        try await eventually { await fixture.mutationIsHeld }

        app.library = app.library?.settingLiked(fingerprint: "a", liked: true)
            .settingPlaylistTracks(playlistID: "other", trackIDs: ["track_c"])
        await fixture.setUnrelatedChanges()
        await fixture.releaseMutation(status: 500)
        try await eventually { !app.errorMessage.isEmpty && app.playlist(withID: "mix") != nil }

        XCTAssertEqual(app.playlist(withID: "mix")?.trackIDs, playlist.trackIDs)
        XCTAssertEqual(app.library?.stats.playlistCount, 2)
        XCTAssertEqual(app.playlist(withID: "other")?.trackIDs, ["track_c"])
        XCTAssertEqual(app.library?.tracks.first?.isLiked, true)
        XCTAssertEqual(Set(app.playlist(withID: "liked")?.trackIDs ?? []), Set(["track_a", "track_b"]))
    }

    func testFailedRemovalReplaysLaterRemovalWithoutRestoringItsSong() async throws {
        let fixture = PlaylistEditingFixture()
        let app = try await makeApp(fixture)
        let playlist = try XCTUnwrap(app.playlist(withID: "mix"))
        let tracks = try XCTUnwrap(app.library?.tracks)
        await fixture.holdNextMutation()
        app.removeTrack(tracks[0], from: playlist)
        app.removeTrack(tracks[1], from: playlist)
        XCTAssertEqual(app.playlist(withID: "mix")?.trackIDs, ["track_c"])
        try await eventually { await fixture.mutationIsHeld }
        await fixture.releaseMutation(status: 500)
        try await eventually { await fixture.completedMutations == 2 }
        await app.refresh()

        XCTAssertEqual(app.playlist(withID: "mix")?.trackIDs, ["track_a", "track_c"])
        XCTAssertFalse(app.errorMessage.isEmpty)
    }

    func testRefreshBeforeOrDuringEditsCannotResurrectRemovedContent() async throws {
        for refreshBeforeEdit in [true, false] {
            let fixture = PlaylistEditingFixture()
            let app = try await makeApp(fixture)
            let playlist = try XCTUnwrap(app.playlist(withID: "mix"))
            let first = try XCTUnwrap(app.library?.tracks.first)
            await fixture.holdNextMutation()
            await fixture.holdNextLibrary()
            var oldRefresh: Task<Bool, Never>?
            if refreshBeforeEdit {
                oldRefresh = Task { await app.refresh() }
                try await eventually { await fixture.libraryIsHeld }
                app.removeTrack(first, from: playlist)
            } else {
                app.deletePlaylist(playlist)
            }
            try await eventually { await fixture.mutationIsHeld }
            if !refreshBeforeEdit { oldRefresh = Task { await app.refresh() } }
            await fixture.releaseLibrary()
            _ = await oldRefresh?.value
            if refreshBeforeEdit {
                XCTAssertEqual(app.playlist(withID: "mix")?.trackIDs, ["track_b", "track_c"])
            } else {
                XCTAssertNil(app.playlist(withID: "mix"))
            }

            await fixture.releaseMutation()
            try await eventually { await fixture.completedMutations == 1 }
            await app.refresh()
            if refreshBeforeEdit {
                XCTAssertEqual(app.playlist(withID: "mix")?.trackIDs, ["track_b", "track_c"])
            } else {
                XCTAssertNil(app.playlist(withID: "mix"))
            }
        }
    }

    func testGuestsAndLikedPlaylistCannotSendPlaylistMutations() async throws {
        let fixture = PlaylistEditingFixture()
        let app = try await makeApp(fixture)
        let original = try XCTUnwrap(app.library)
        let playlist = try XCTUnwrap(app.playlist(withID: "mix"))
        let liked = try XCTUnwrap(app.playlist(withID: "liked"))
        let tracks = original.tracks
        app.activeAuxIsGuest = true
        app.deletePlaylist(playlist)
        app.removeTracks([tracks[0], tracks[1]], from: playlist)
        app.addTrack(tracks[2], to: playlist)
        app.movePlaylistTracks(playlist, from: IndexSet(integer: 0), to: 3)
        app.activeAuxIsGuest = false
        app.deletePlaylist(liked)
        app.removeTrack(tracks[1], from: liked)
        app.addTrack(tracks[0], to: liked)
        app.movePlaylistTracks(liked, from: IndexSet(integer: 0), to: 1)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(app.library, original)
        let requests = await fixture.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testLibraryResponseAfterAcknowledgementCannotBrieflyRestoreDeletedPlaylist() async throws {
        let fixture = PlaylistEditingFixture()
        let app = try await makeApp(fixture)
        let playlist = try XCTUnwrap(app.playlist(withID: "mix"))
        await fixture.holdNextLibrary()
        let oldRefresh = Task { await app.refresh() }
        try await eventually { await fixture.libraryIsHeld }

        app.deletePlaylist(playlist)
        try await eventually { await fixture.completedMutations == 1 }
        try await Task.sleep(for: .milliseconds(20))
        // Hold the correcting read too, so it cannot hide a transient
        // resurrection caused by accepting the obsolete response.
        await fixture.holdNextLibrary()
        await fixture.releaseLibrary(keepNextHold: true)
        try await eventually {
            let held = await fixture.libraryIsHeld
            let requests = await fixture.libraryRequestCount
            return held && requests == 2
        }
        XCTAssertNil(app.playlist(withID: "mix"))
        await fixture.releaseLibrary()
        _ = await oldRefresh.value
        XCTAssertNil(app.playlist(withID: "mix"))
    }

    func testDisconnectIgnoresLateMutationAndCancelsQueuedRequests() async throws {
        let fixture = PlaylistEditingFixture()
        let app = try await makeApp(fixture)
        let playlist = try XCTUnwrap(app.playlist(withID: "mix"))
        let tracks = try XCTUnwrap(app.library?.tracks)
        await fixture.holdNextMutation()
        app.removeTracks([tracks[0], tracks[1]], from: playlist)
        XCTAssertEqual(app.playlist(withID: "mix")?.trackIDs, ["track_c"])
        try await eventually { await fixture.mutationIsHeld }

        app.disconnect()
        await fixture.releaseMutation()
        try await eventually { await fixture.completedMutations == 1 }
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertNil(app.library)
        XCTAssertNil(app.client)
        XCTAssertEqual(app.connection, .disconnected)
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 1, "The queued edit and library refresh must be cancelled")
    }

    func testFailedAdjacentDeletesRestoreOrderAfterEarlierSuccessOrFailure() async throws {
        for firstStatus in [204, 500] {
            let fixture = PlaylistEditingFixture()
            let app = try await makeApp(fixture)
            let first = try XCTUnwrap(app.playlist(withID: "mix"))
            let second = try XCTUnwrap(app.playlist(withID: "other"))
            await fixture.holdNextMutation()
            await fixture.setMutationStatus(500, at: 1)
            await fixture.holdNextLibrary()

            app.deletePlaylist(first)
            app.deletePlaylist(second)
            XCTAssertTrue(app.userPlaylists.isEmpty)
            try await eventually { await fixture.mutationIsHeld }
            await fixture.releaseMutation(status: firstStatus)
            try await eventually { await fixture.libraryIsHeld }

            let expected = firstStatus == 204 ? ["other"] : ["mix", "other"]
            XCTAssertEqual(app.userPlaylists.map(\.id), expected,
                           "Rejected deletes must restore order before a refresh can repair it")
            XCTAssertEqual(app.library?.stats.playlistCount, expected.count)
            await fixture.releaseLibrary()
            await app.refresh()
            XCTAssertEqual(app.userPlaylists.map(\.id), expected)
        }
    }
}

private actor PlaylistEditingFixture: CodecTransport {
    private var library: CodecLibrary
    private var holdMutation = false
    private var holdLibrary = false
    private var mutationContinuation: CheckedContinuation<Int, Never>?
    private var libraryContinuation: CheckedContinuation<Void, Never>?
    private var mutationStatuses: [Int: Int] = [:]
    private(set) var requests: [URLRequest] = []
    private(set) var completedMutations = 0

    nonisolated var client: CodecClient {
        CodecClient(baseURL: URL(string: "https://playlist-editing.invalid")!, token: "fixture-token", transport: self)
    }

    init(membership: [String] = ["track_a", "track_b", "track_c"]) {
        library = CodecLibrary(
            rootPath: "fixture", scannedAt: 1,
            stats: CodecLibraryStats(trackCount: 3, playlistCount: 2, likedCount: 1, artistCount: 0, albumCount: 0, durationSeconds: 0),
            artists: [], albums: [],
            playlists: [
                CodecPlaylist(id: "mix", name: "Mix", trackIDs: membership, isLiked: false),
                CodecPlaylist(id: "other", name: "Other", trackIDs: ["track_a"], isLiked: false),
                CodecPlaylist(id: "liked", name: "Liked Songs", trackIDs: ["track_b"], isLiked: true)
            ],
            tracks: ["a", "b", "c"].map {
                CodecTrack(
                    id: "track_" + $0, title: $0, artist: "", album: "",
                    artworkURL: URL(string: "https://playlist-editing.invalid/art/\($0)"),
                    audioURL: URL(string: "https://playlist-editing.invalid/audio/\($0)"),
                    playlistIDs: (membership.contains("track_" + $0) ? ["mix"] : []) + ($0 == "a" ? ["other"] : $0 == "b" ? ["liked"] : []),
                    isLiked: $0 == "b", fingerprint: $0
                )
            }
        )
    }

    var mutationIsHeld: Bool { mutationContinuation != nil }
    var libraryIsHeld: Bool { libraryContinuation != nil }
    var libraryRequestCount: Int { requests.filter { $0.url!.path == "/api/v1/library" }.count }
    var mutationRequests: [URLRequest] { requests.filter { $0.httpMethod != "GET" } }
    func snapshot() -> CodecLibrary { library }
    func holdNextMutation() { holdMutation = true }
    func holdNextLibrary() { holdLibrary = true }
    func setMutationStatus(_ status: Int, at index: Int) { mutationStatuses[index] = status }
    func releaseMutation(status: Int = 204) {
        mutationContinuation?.resume(returning: status)
        mutationContinuation = nil
    }
    func releaseLibrary(keepNextHold: Bool = false) {
        if !keepNextHold { holdLibrary = false }
        libraryContinuation?.resume()
        libraryContinuation = nil
    }
    func setUnrelatedChanges() {
        library = library.settingLiked(fingerprint: "a", liked: true)
            .settingPlaylistTracks(playlistID: "other", trackIDs: ["track_c"])
        rebuildMembership()
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let path = request.url!.path
        if path == "/api/v1/library", request.httpMethod == "GET" {
            // Capture before suspension so an old response stays old even
            // when the mutation completes while it is in flight.
            let data = try JSONEncoder().encode(library)
            if holdLibrary {
                holdLibrary = false
                await withCheckedContinuation { libraryContinuation = $0 }
            }
            return response(request, status: 200, data: data)
        }
        guard path.hasPrefix("/api/v1/playlists/") else {
            return response(request, status: 404)
        }
        var status = mutationStatuses[mutationRequests.count - 1] ?? 204
        if holdMutation {
            holdMutation = false
            status = await withCheckedContinuation { mutationContinuation = $0 }
        }
        defer { completedMutations += 1 }
        guard status < 300 else { return response(request, status: status) }
        let parts = path.split(separator: "/").map(String.init)
        let id = parts[3]
        if parts.count == 4, request.httpMethod == "DELETE" {
            library = CodecLibrary(
                rootPath: library.rootPath, scannedAt: library.scannedAt, stats: library.stats,
                artists: library.artists, albums: library.albums,
                playlists: library.playlists.filter { $0.id != id }, tracks: library.tracks
            )
        } else if parts.count >= 5, parts[4] == "tracks" {
            let current = library.playlists.first { $0.id == id }?.trackIDs ?? []
            let next: [String]
            if request.httpMethod == "DELETE", parts.count == 6 {
                next = current.filter { $0 != "track_" + parts[5] }
            } else if request.httpMethod == "POST" {
                let body = try JSONDecoder().decode([String: String].self, from: request.httpBody!)
                let added = "track_" + body["fingerprint"]!
                next = current.contains(added) ? current : current + [added]
            } else if request.httpMethod == "PUT" {
                let body = try JSONDecoder().decode([String: [String]].self, from: request.httpBody!)
                next = body["track_ids"]!
            } else {
                return response(request, status: 405)
            }
            library = library.settingPlaylistTracks(playlistID: id, trackIDs: next)
        } else {
            return response(request, status: 404)
        }
        rebuildMembership()
        return response(request, status: status)
    }

    private func rebuildMembership() {
        let playlists = library.playlists
        let tracks = library.tracks.map { track in
            CodecTrack(
                id: track.id, title: track.title, artist: track.artist, album: track.album,
                albumArtist: track.albumArtist, trackNumber: track.trackNumber,
                durationSeconds: track.durationSeconds, artworkURL: track.artworkURL,
                audioURL: track.audioURL,
                playlistIDs: playlists.filter { $0.trackIDs.contains(track.id) }.map(\.id),
                addedAt: track.addedAt, isLiked: track.isLiked, fingerprint: track.fingerprint
            )
        }
        library = CodecLibrary(
            rootPath: library.rootPath, scannedAt: library.scannedAt,
            stats: CodecLibraryStats(
                trackCount: tracks.count, playlistCount: playlists.filter { !$0.isLiked }.count,
                likedCount: tracks.filter(\.isLiked).count, artistCount: 0, albumCount: 0, durationSeconds: 0
            ), artists: library.artists, albums: library.albums, playlists: playlists, tracks: tracks
        )
    }

    private func response(_ request: URLRequest, status: Int, data: Data = Data()) -> (Data, URLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
