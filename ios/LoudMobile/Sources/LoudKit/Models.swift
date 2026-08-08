import Foundation

/// Response from `GET /health`.
public struct LoudHealth: Decodable, Equatable, Sendable {
    public let ok: Bool
    public let schema: String
    public let playbackSchema: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case schema
        case playbackSchema = "playback_schema"
    }
}

/// The `Library` payload from `GET /api/v1/library`, matching the Go server
/// and the web app's `src/lib/types.ts`.
public struct LoudLibrary: Codable, Equatable, Sendable {
    public let rootPath: String
    public let scannedAt: Int64
    public let stats: LoudLibraryStats
    public let artists: [LoudArtistSummary]
    public let albums: [LoudAlbumSummary]
    public let playlists: [LoudPlaylist]
    public let tracks: [LoudTrack]

    enum CodingKeys: String, CodingKey {
        case rootPath = "root_path"
        case scannedAt = "scanned_at"
        case stats
        case artists
        case albums
        case playlists
        case tracks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rootPath = try container.decodeIfPresent(String.self, forKey: .rootPath) ?? ""
        scannedAt = try container.decodeIfPresent(Int64.self, forKey: .scannedAt) ?? 0
        stats = try container.decodeIfPresent(LoudLibraryStats.self, forKey: .stats) ?? .empty
        artists = try container.decodeIfPresent([LoudArtistSummary].self, forKey: .artists) ?? []
        albums = try container.decodeIfPresent([LoudAlbumSummary].self, forKey: .albums) ?? []
        playlists = try container.decodeIfPresent([LoudPlaylist].self, forKey: .playlists) ?? []
        tracks = try container.decodeIfPresent([LoudTrack].self, forKey: .tracks) ?? []
    }
}

public struct LoudLibraryStats: Codable, Equatable, Sendable {
    public let trackCount: Int
    public let playlistCount: Int
    public let likedCount: Int
    public let artistCount: Int
    public let albumCount: Int
    public let durationSeconds: Double

    public static let empty = LoudLibraryStats(
        trackCount: 0, playlistCount: 0, likedCount: 0,
        artistCount: 0, albumCount: 0, durationSeconds: 0
    )

    public init(
        trackCount: Int, playlistCount: Int, likedCount: Int,
        artistCount: Int, albumCount: Int, durationSeconds: Double
    ) {
        self.trackCount = trackCount
        self.playlistCount = playlistCount
        self.likedCount = likedCount
        self.artistCount = artistCount
        self.albumCount = albumCount
        self.durationSeconds = durationSeconds
    }
}

public struct LoudArtistSummary: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let trackCount: Int
    public let albumCount: Int
    public let durationSeconds: Double

    public var id: String { name }
}

public struct LoudAlbumSummary: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let artist: String
    public let trackCount: Int
    public let durationSeconds: Double
    public let artworkURL: URL?

    public var id: String { "\(artist)|\(name)" }

    enum CodingKeys: String, CodingKey {
        case name
        case artist
        case trackCount
        case durationSeconds
        case artworkURL = "artwork_url"
    }
}

public struct LoudPlaylist: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let trackIDs: [String]
    public let isLiked: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case trackIDs = "track_ids"
        case isLiked = "is_liked"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        trackIDs = try container.decodeIfPresent([String].self, forKey: .trackIDs) ?? []
        isLiked = try container.decodeIfPresent(Bool.self, forKey: .isLiked) ?? false
    }
}

public struct LoudTrack: Codable, Equatable, Sendable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let artist: String
    public let album: String
    public let albumArtist: String?
    public let trackNumber: Int?
    public let durationSeconds: Double?
    public let artworkURL: URL?
    public let audioURL: URL?
    public let playlistIDs: [String]
    public let addedAt: Int64?
    public let isLiked: Bool
    public let fingerprint: String

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case artist
        case album
        case albumArtist = "album_artist"
        case trackNumber = "track_number"
        case durationSeconds = "duration_seconds"
        case artworkURL = "artwork_url"
        case audioURL = "audio_url"
        case playlistIDs = "playlist_ids"
        case addedAt = "added_at"
        case isLiked = "is_liked"
        case fingerprint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? "Unknown Artist"
        album = try container.decodeIfPresent(String.self, forKey: .album) ?? "Unknown Album"
        albumArtist = try container.decodeIfPresent(String.self, forKey: .albumArtist)
        trackNumber = try container.decodeIfPresent(Int.self, forKey: .trackNumber)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        artworkURL = try? container.decodeIfPresent(URL.self, forKey: .artworkURL)
        audioURL = try? container.decodeIfPresent(URL.self, forKey: .audioURL)
        playlistIDs = try container.decodeIfPresent([String].self, forKey: .playlistIDs) ?? []
        addedAt = try container.decodeIfPresent(Int64.self, forKey: .addedAt)
        isLiked = try container.decodeIfPresent(Bool.self, forKey: .isLiked) ?? false
        fingerprint = try container.decode(String.self, forKey: .fingerprint)
    }
}
