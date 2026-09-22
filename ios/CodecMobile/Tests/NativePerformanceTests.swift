import Foundation
import Observation
import XCTest
@testable import Codec

@MainActor
final class NativePerformanceTests: XCTestCase {
    private func track(_ id: String) -> CodecTrack {
        CodecTrack(id: id, title: id, artist: "", album: "", fingerprint: id)
    }

    func testIndexedPlaylistPreviewKeepsOrderSkipsMissingAndReflectsRefresh() {
        let app = AppModel(client: CodecClient(baseURL: URL(string: "https://performance-tests.invalid")!))
        let playlist = CodecPlaylist(id: "mix", name: "Mix", trackIDs: ["missing", "c", "a", "b"], isLiked: false)
        func library(_ tracks: [CodecTrack]) -> CodecLibrary {
            CodecLibrary(rootPath: "", scannedAt: 0, stats: .empty, artists: [], albums: [], playlists: [playlist], tracks: tracks)
        }
        app.library = library([track("a"), track("b"), track("c")])
        XCTAssertEqual(app.firstTracks(in: playlist, limit: 2).map(\.id), ["c", "a"])
        XCTAssertEqual(app.firstTracks(in: playlist, limit: 99).map(\.id), ["c", "a", "b"])
        XCTAssertTrue(app.firstTracks(in: playlist, limit: 0).isEmpty)
        XCTAssertTrue(app.firstTracks(in: playlist, limit: -1).isEmpty)
        XCTAssertEqual(app.track(withID: "c")?.id, "c")
        app.library = library([track("b")])
        XCTAssertEqual(app.firstTracks(in: playlist, limit: 2).map(\.id), ["b"])
        XCTAssertNil(app.track(withID: "c"))
    }

    func testPlaylistOnlyEditBurstDoesNoFullIndexSearchTextOrRecentSortWork() {
        let app = AppModel(client: CodecClient(baseURL: URL(string: "https://performance-tests.invalid")!))
        let tracks = (0..<1_888).map { index in
            CodecTrack(id: "song-\(index)", title: String(format: "Song %04d", index),
                       artist: "Artist \(index % 97)", album: "Album \(index % 96)",
                       playlistIDs: ["mix"], isLiked: index == 500, fingerprint: "fp-\(index)")
        }
        let ids = tracks.map(\.id)
        let playlist = CodecPlaylist(id: "mix", name: "Mix", trackIDs: ids, isLiked: false)
        let original = collection(tracks, playlists: [playlist])
        app.library = original
        let initialWork = app.libraryCollectionWork
        XCTAssertEqual(initialWork.fullIndexBuilds, 1)
        XCTAssertEqual(initialWork.searchTextBuilds, 1_888)
        XCTAssertEqual(initialWork.recentTrackSorts, 1)

        let unrelatedChanges = PerformanceObservationCount()
        withObservationTracking {
            _ = app.tracks
            _ = app.track(withID: "song-1870")
            _ = app.searchTracks("Song 1870")
            _ = app.likedTracks
            _ = app.fullAlbums
            _ = app.recentlyAdded
            _ = app.recentItems
        } onChange: { unrelatedChanges.increment() }

        // Name, cover and order edits don't change track values. Exercise the
        // same replacement API used by optimistic edits and their acknowledgments.
        for index in 0..<20 {
            let edited = CodecPlaylist(id: "mix", name: "Mix \(index)",
                                       trackIDs: index.isMultiple(of: 2) ? ids : Array(ids.reversed()),
                                       isLiked: false, artworkURL: "https://performance-tests.invalid/cover-\(index).jpg")
            app.library = original.replacingPlaylist(id: "mix", with: edited)
            let acknowledged = app.library
            app.library = acknowledged // An unchanged acknowledged snapshot.
            XCTAssertEqual(app.userPlaylists.first, edited)
            XCTAssertEqual(app.homePlaylists.first, edited)
        }
        XCTAssertEqual(unrelatedChanges.value, 0)
        XCTAssertEqual(app.libraryCollectionWork, initialWork)

        let collectionChanges = PerformanceObservationCount()
        withObservationTracking {
            _ = app.likedTracks
            _ = app.fullAlbums
            _ = app.recentlyAdded
            _ = app.recentItems
        } onChange: { collectionChanges.increment() }

        // Membership edits also update tracks[].playlistIDs. Keep those public
        // results fresh, while reusing search text, indexes and recent ordering.
        let changedTrack = tracks[1_870]
        for index in 0..<20 {
            let membership = index.isMultiple(of: 2) ? ids.filter { $0 != changedTrack.id } : ids
            let edited = CodecPlaylist(id: "mix", name: "Mix", trackIDs: membership, isLiked: false)
            app.library = app.library?.replacingPlaylist(id: "mix", with: edited)
            let expected = index.isMultiple(of: 2) ? [] : ["mix"]
            XCTAssertEqual(app.track(withID: changedTrack.id)?.playlistIDs, expected)
            XCTAssertEqual(app.searchTracks("Song 1870").first?.playlistIDs, expected)
            let acknowledged = app.library
            app.library = acknowledged
        }
        app.library = original // Rollback must also preserve the cached work.
        XCTAssertEqual(app.libraryCollectionWork, initialWork)
        XCTAssertEqual(collectionChanges.value, 0, "An edit outside these collections must not invalidate them")
        XCTAssertEqual(app.firstTracks(in: playlist, limit: 3), Array(tracks.prefix(3)))
    }

    func testIncrementalCollectionsReflectTrackReorderingLikesMetadataAndClearing() {
        let app = AppModel(client: CodecClient(baseURL: URL(string: "https://performance-tests.invalid")!))
        let a = track("a")
        let b = track("b")
        app.library = collection([a, b])
        app.library = collection([b, a])
        XCTAssertEqual(app.tracks.map(\.id), ["b", "a"])
        XCTAssertEqual(app.recentlyAdded.map(\.id), ["b", "a"], "Equal dates retain the source order")
        let unliked = app.library
        let beforeLike = app.libraryCollectionWork
        app.library = app.library?.settingLiked(fingerprint: "a", liked: true)
        XCTAssertTrue(app.isLiked(a))
        XCTAssertTrue(app.searchTracks("a").first?.isLiked ?? false)
        XCTAssertEqual(app.likedTracks.map(\.id), ["a"])
        XCTAssertEqual(app.libraryCollectionWork, beforeLike, "A like does not change searchable text or sort keys")
        app.library = unliked // Failed optimistic like: restore the exact prior state.
        XCTAssertFalse(app.isLiked(a))
        XCTAssertFalse(app.searchTracks("a").first?.isLiked ?? true)
        XCTAssertTrue(app.likedTracks.isEmpty)
        app.library = app.library?.settingLiked(fingerprint: "a", liked: true)

        let artwork = URL(string: "https://performance-tests.invalid/new-cover.jpg")!
        let changed = CodecTrack(id: "b", title: "New title", artist: "New artist", album: "New album",
                                 artworkURL: artwork, addedAt: 10, fingerprint: "b")
        let likedA = a.withLiked(true)
        app.library = collection([changed, likedA])
        XCTAssertEqual(app.searchTracks("New title"), [changed])
        XCTAssertEqual(app.track(withID: "b")?.artworkURL, artwork)
        XCTAssertEqual(app.recentlyAdded.first, changed)
        XCTAssertEqual(app.libraryCollectionWork.fullIndexBuilds, beforeLike.fullIndexBuilds)
        XCTAssertEqual(app.libraryCollectionWork.searchTextBuilds, beforeLike.searchTextBuilds + 1)
        XCTAssertEqual(app.libraryCollectionWork.recentTrackSorts, beforeLike.recentTrackSorts + 1)

        app.library = nil
        XCTAssertTrue(app.tracks.isEmpty)
        XCTAssertTrue(app.searchTracks("New").isEmpty)
        XCTAssertNil(app.track(withID: "b"))
        XCTAssertTrue(app.recentlyAdded.isEmpty)
        XCTAssertTrue(app.recentItems.isEmpty)
        XCTAssertTrue(app.likedTracks.isEmpty)
        app.library = collection([changed])
        XCTAssertEqual(app.track(withID: "b"), changed)
        XCTAssertEqual(app.searchTracks("New"), [changed])
        XCTAssertEqual(app.recentlyAdded, [changed])
    }

    func testIncrementalIndexesPreserveFirstMatchForDuplicateIDsAndFingerprints() {
        let app = AppModel(client: CodecClient(baseURL: URL(string: "https://performance-tests.invalid")!))
        let first = CodecTrack(id: "shared-id", title: "First", artist: "", album: "", fingerprint: "shared-fp")
        let sameID = CodecTrack(id: "shared-id", title: "Second", artist: "", album: "", fingerprint: "other-fp")
        let sameFingerprint = CodecTrack(id: "other-id", title: "Third", artist: "", album: "", fingerprint: "shared-fp")
        app.library = collection([first, sameID, sameFingerprint])
        let before = app.libraryCollectionWork
        app.library = collection([first, sameID.withLiked(true), sameFingerprint.withLiked(true)])
        XCTAssertEqual(app.track(withID: "shared-id"), first)
        XCTAssertTrue(app.isLiked(sameID), "The independent fingerprint index must update")
        XCTAssertFalse(app.isLiked(sameFingerprint), "The shared fingerprint keeps its first occurrence")
        XCTAssertTrue(app.track(withID: "other-id")?.isLiked ?? false)
        XCTAssertTrue(app.searchTracks("Third").first?.isLiked ?? false)
        XCTAssertEqual(app.libraryCollectionWork, before)
    }

    func testAlbumOnlyRefreshUpdatesHomeGroupingWithoutReindexingTracks() throws {
        let app = AppModel(client: CodecClient(baseURL: URL(string: "https://performance-tests.invalid")!))
        let tracks = [CodecTrack(id: "a", title: "a", artist: "Artist", album: "Album", fingerprint: "a"),
                      CodecTrack(id: "b", title: "b", artist: "Artist", album: "Album", fingerprint: "b")]
        app.library = collection(tracks)
        let before = app.libraryCollectionWork
        XCTAssertEqual(app.recentItems.map(\.id), ["track:a", "track:b"])
        let album = try JSONDecoder().decode(CodecAlbumSummary.self, from: Data(
            #"{"name":"Album","artist":"Artist","trackCount":2,"durationSeconds":0}"#.utf8))
        app.library = collection(tracks, albums: [album])
        XCTAssertEqual(app.fullAlbums, [album])
        XCTAssertEqual(app.recentItems.map(\.id), ["album:\(album.id)"])
        XCTAssertEqual(app.libraryCollectionWork, before)
        app.library = collection(tracks)
        XCTAssertTrue(app.fullAlbums.isEmpty)
        XCTAssertEqual(app.recentItems.map(\.id), ["track:a", "track:b"])
    }

    private func collection(_ tracks: [CodecTrack], playlists: [CodecPlaylist] = [], albums: [CodecAlbumSummary] = []) -> CodecLibrary {
        CodecLibrary(rootPath: "", scannedAt: 0, stats: .empty, artists: [], albums: albums, playlists: playlists, tracks: tracks)
    }

    func testDownloadProgressOnlyInvalidatesItsOwnRow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloads = DownloadStore(directory: directory, configuration: .ephemeral)
        let session = URLSession(configuration: .ephemeral)
        defer {
            downloads.shutdown()
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: directory)
        }
        let first = track("first")
        let other = track("other")
        // Exercise the existing background-task restoration callback path.
        // The unresumed task never sends a request, and this synchronous test
        // cannot race the MainActor restoration completion.
        let task = session.downloadTask(with: URL(string: "https://performance-tests.invalid/song")!)
        downloads.downloadProgressed(fingerprint: first.fingerprint, task: task, progress: 0.1)
        let ownChanges = PerformanceObservationCount()
        let unrelatedChanges = PerformanceObservationCount()
        let categoryChanges = PerformanceObservationCount()
        withObservationTracking { _ = downloads.state(for: first) } onChange: { ownChanges.increment() }
        withObservationTracking { _ = downloads.state(for: other) } onChange: { unrelatedChanges.increment() }
        withObservationTracking {
            _ = downloads.isDownloaded(first)
            _ = downloads.isDownloading(first)
            _ = downloads.downloadedCount
            _ = downloads.downloadedTracks(in: [first, other])
        } onChange: { categoryChanges.increment() }

        downloads.downloadProgressed(fingerprint: first.fingerprint, task: task, progress: 0.4)
        XCTAssertEqual(downloads.state(for: first), .downloading(0.4))
        XCTAssertEqual(ownChanges.value, 1)
        XCTAssertEqual(unrelatedChanges.value, 0)
        XCTAssertEqual(categoryChanges.value, 0, "Fractional progress must not rebuild downloaded collections or action headers")

        let pending = directory.appendingPathComponent("pending.wav")
        try Data([1, 2, 3]).write(to: pending)
        downloads.downloadReceived(fingerprint: first.fingerprint, task: task, location: pending, error: nil, retryable: false)
        XCTAssertGreaterThan(categoryChanges.value, 0)
        XCTAssertEqual(downloads.downloadedCount, 1)
        XCTAssertTrue(downloads.isDownloaded(first))
        XCTAssertFalse(downloads.isDownloading(first))
        XCTAssertNotNil(downloads.localAudioURL(for: first))
        XCTAssertEqual(unrelatedChanges.value, 0)
        downloads.remove(first)
        XCTAssertEqual(downloads.downloadedCount, 0)
        XCTAssertFalse(downloads.isDownloaded(first))
        XCTAssertNil(downloads.state(for: first))
        XCTAssertNil(downloads.localAudioURL(for: first))
    }

    func testUnchangedProgressDoesNotInvalidateTheRowAgain() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloads = DownloadStore(directory: directory, configuration: .ephemeral)
        let session = URLSession(configuration: .ephemeral)
        defer {
            downloads.shutdown()
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: directory)
        }
        let track = track("unchanged")
        let task = session.downloadTask(with: URL(string: "https://performance-tests.invalid/song")!)
        downloads.downloadProgressed(fingerprint: track.fingerprint, task: task, progress: 0.5)
        let changes = PerformanceObservationCount()
        withObservationTracking { _ = downloads.state(for: track) } onChange: { changes.increment() }
        downloads.downloadProgressed(fingerprint: track.fingerprint, task: task, progress: 0.5)
        XCTAssertEqual(changes.value, 0)
        downloads.downloadFailed(fingerprint: track.fingerprint, task: task, message: "Fixture failure", retryable: false)
        XCTAssertEqual(changes.value, 1)
        XCTAssertNil(downloads.state(for: track))
        XCTAssertFalse(downloads.isDownloading(track))
    }
}

private final class PerformanceObservationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
