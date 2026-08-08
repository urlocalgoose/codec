import Foundation

/// Cross-device reference to a canonical track (`loud.playback.v2`).
public struct LoudTrackReference: Codable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let fingerprint: String

    public init(id: String, path: String, fingerprint: String) {
        self.id = id
        self.path = path
        self.fingerprint = fingerprint
    }

    public init(track: LoudTrack) {
        self.init(id: track.id, path: "loud://track/\(track.fingerprint)", fingerprint: track.fingerprint)
    }
}

public struct PlaybackContext: Codable, Equatable, Sendable {
    public var playbackSource: [LoudTrackReference]
    public var playbackIndex: Int
    public var queuedTracks: [LoudTrackReference]
    public var playHistory: [LoudTrackReference]
    public var shuffle: Bool
    public var repeatMode: String

    enum CodingKeys: String, CodingKey {
        case playbackSource = "playback_source"
        case playbackIndex = "playback_index"
        case queuedTracks = "queued_tracks"
        case playHistory = "play_history"
        case shuffle
        case repeatMode = "repeat"
    }

    public init(
        playbackSource: [LoudTrackReference] = [],
        playbackIndex: Int = 0,
        queuedTracks: [LoudTrackReference] = [],
        playHistory: [LoudTrackReference] = [],
        shuffle: Bool = false,
        repeatMode: String = "off"
    ) {
        self.playbackSource = playbackSource
        self.playbackIndex = playbackIndex
        self.queuedTracks = queuedTracks
        self.playHistory = playHistory
        self.shuffle = shuffle
        self.repeatMode = repeatMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playbackSource = try container.decodeIfPresent([LoudTrackReference].self, forKey: .playbackSource) ?? []
        playbackIndex = try container.decodeIfPresent(Int.self, forKey: .playbackIndex) ?? 0
        queuedTracks = try container.decodeIfPresent([LoudTrackReference].self, forKey: .queuedTracks) ?? []
        playHistory = try container.decodeIfPresent([LoudTrackReference].self, forKey: .playHistory) ?? []
        shuffle = try container.decodeIfPresent(Bool.self, forKey: .shuffle) ?? false
        repeatMode = try container.decodeIfPresent(String.self, forKey: .repeatMode) ?? "off"
    }
}

public struct PlaybackClock: Codable, Equatable, Sendable {
    public let positionSeconds: Double
    public let startedAtMS: Int64?
    public let stoppedAtMS: Int64?
    public let updatedAtMS: Int64

    enum CodingKeys: String, CodingKey {
        case positionSeconds = "position_seconds"
        case startedAtMS = "started_at_ms"
        case stoppedAtMS = "stopped_at_ms"
        case updatedAtMS = "updated_at_ms"
    }

    public init(positionSeconds: Double, startedAtMS: Int64?, stoppedAtMS: Int64?, updatedAtMS: Int64) {
        self.positionSeconds = positionSeconds
        self.startedAtMS = startedAtMS
        self.stoppedAtMS = stoppedAtMS
        self.updatedAtMS = updatedAtMS
    }
}

/// Shared playback state from `GET /api/v2/playback` and SSE events.
public struct PlaybackState: Codable, Equatable, Sendable {
    public let schema: String
    public let revision: Int64
    public let activeDeviceID: String?
    public let state: String
    public let track: LoudTrackReference?
    public let context: PlaybackContext
    public let clock: PlaybackClock
    public let volume: Double
    public let serverTimeMS: Int64

    enum CodingKeys: String, CodingKey {
        case schema
        case revision
        case activeDeviceID = "active_device_id"
        case state
        case track
        case context
        case clock
        case volume
        case serverTimeMS = "server_time_ms"
    }

    public var isPlaying: Bool { state == "playing" }

    /// Mirrors the web client's `derivedPlaybackPosition`: the clock keeps
    /// counting while the server says we are playing.
    public func position(atClientTimeMS nowMS: Int64, clockOffsetMS: Int64 = 0) -> Double {
        let base = max(0, clock.positionSeconds)
        guard state == "playing", let startedAtMS = clock.startedAtMS else {
            return base
        }
        let serverNowMS = nowMS + clockOffsetMS
        return max(0, base + Double(max(0, serverNowMS - startedAtMS)) / 1000)
    }
}

/// A device row from `GET /api/v1/playback/devices`; also the payload we
/// publish for this device's presence.
public struct LoudPlaybackDevice: Codable, Equatable, Sendable, Identifiable {
    public let deviceID: String
    public let name: String
    public let trackID: String?
    public let trackFingerprint: String?
    public let trackTitle: String?
    public let isPlaying: Bool
    public let positionSeconds: Double
    public let volume: Double
    public let updatedAt: Int64

    public var id: String { deviceID }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case name
        case trackID = "track_id"
        case trackFingerprint = "track_fingerprint"
        case trackTitle = "track_title"
        case isPlaying = "is_playing"
        case positionSeconds = "position_seconds"
        case volume
        case updatedAt = "updated_at"
    }

    public init(
        deviceID: String,
        name: String,
        trackID: String? = nil,
        trackFingerprint: String? = nil,
        trackTitle: String? = nil,
        isPlaying: Bool = false,
        positionSeconds: Double = 0,
        volume: Double = 1,
        updatedAt: Int64 = 0
    ) {
        self.deviceID = deviceID
        self.name = name
        self.trackID = trackID
        self.trackFingerprint = trackFingerprint
        self.trackTitle = trackTitle
        self.isPlaying = isPlaying
        self.positionSeconds = positionSeconds
        self.volume = volume
        self.updatedAt = updatedAt
    }
}

public struct PlaybackCommand: Encodable, Sendable {
    public let commandID: String
    public let kind: String
    public let deviceID: String
    public var targetDeviceID: String?
    public var track: LoudTrackReference?
    public var context: PlaybackContext?
    public var positionSeconds: Double?
    public var shuffle: Bool?
    public var repeatMode: String?

    enum CodingKeys: String, CodingKey {
        case commandID = "command_id"
        case kind
        case deviceID = "device_id"
        case targetDeviceID = "target_device_id"
        case track
        case context
        case positionSeconds = "position_seconds"
        case shuffle
        case repeatMode = "repeat"
    }

    public init(
        kind: String,
        deviceID: String,
        targetDeviceID: String? = nil,
        track: LoudTrackReference? = nil,
        context: PlaybackContext? = nil,
        positionSeconds: Double? = nil,
        shuffle: Bool? = nil,
        repeatMode: String? = nil
    ) {
        self.commandID = "\(deviceID)-\(kind)-\(UUID().uuidString)"
        self.kind = kind
        self.deviceID = deviceID
        self.targetDeviceID = targetDeviceID
        self.track = track
        self.context = context
        self.positionSeconds = positionSeconds
        self.shuffle = shuffle
        self.repeatMode = repeatMode
    }
}

/// One event from `GET /api/v2/playback/events` (SSE).
public struct PlaybackEventPayload: Decodable, Sendable {
    public let device: LoudPlaybackDevice?
    public let devices: [LoudPlaybackDevice]?
    public let playbackState: PlaybackState?

    enum CodingKeys: String, CodingKey {
        case device
        case devices
        case playbackState = "playback_state"
    }
}
