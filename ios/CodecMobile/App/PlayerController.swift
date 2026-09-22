import AVFoundation
import Foundation
import MediaPlayer
import Observation
import OSLog
import UIKit

enum RepeatMode: String, CaseIterable {
    case off
    case all
    case one
}

enum PlaybackStreamEvent {
    case connected
    case line(String)
}

typealias PlaybackEventConsumer = @MainActor (
    URLRequest, @escaping @MainActor (PlaybackStreamEvent) -> Void
) async throws -> Void

/// The playback engine: owns the AVPlayer, the queue, background audio,
/// and the lock-screen / Control Center integration.
@MainActor
@Observable
final class PlayerController {
    private(set) var currentTrack: CodecTrack? {
        didSet {
            let identity = currentTrack.map(SpectrumTrackIdentity.init)
            if oldValue.map(SpectrumTrackIdentity.init) != identity { spectrumTrackRevision &+= 1 }
            spectrum.beginTrack(identity)
        }
    }
    /// Ensures even an A→B→A change within one UI pass restarts palette loading.
    private(set) var spectrumTrackRevision = 0
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    var shuffle = false
    var repeatMode: RepeatMode = .off

    /// The ordered source the current track came from (playlist, album, search…).
    private(set) var source: [CodecTrack] = []
    private(set) var sourceIndex = 0
    /// Where this source was explicitly started; never inferred from membership.
    private(set) var sourcePlaylistID: String?
    /// Tracks manually queued with "Play Next" — they win over the source.
    private(set) var manualQueue: [CodecTrack] = []
    private var history: [CodecTrack] = []

    var duration: Double {
        let mediaDuration = player?.currentItem?.duration.seconds ?? .nan
        if mediaDuration.isFinite, mediaDuration > 0 {
            return mediaDuration
        }
        return currentTrack?.durationSeconds ?? 0
    }

    /// What the queue screen shows: now playing, then the manual queue,
    /// then the rest of the source.
    var upNext: [CodecTrack] {
        var items: [CodecTrack] = []
        items.append(contentsOf: manualQueue)
        if sourceIndex + 1 < source.count {
            items.append(contentsOf: source[(sourceIndex + 1)...])
        }
        return items
    }

    var client: CodecClient?
    var downloads: DownloadStore?

    // MARK: Shared playback (loud.playback.v2) state

    /// Stable identity for this phone in the device list.
    let deviceID: String = {
        let key = "codec.playbackDeviceId"
        let legacyKey = "loud.playbackDeviceId"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        if let legacy = UserDefaults.standard.string(forKey: legacyKey) {
            UserDefaults.standard.set(legacy, forKey: key)
            return legacy
        }
        let fresh = "device-\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()
    let deviceName = UIDevice.current.name

    private(set) var syncEnabled = false
    private(set) var syncState: PlaybackState?
    private(set) var playbackDevices: [CodecPlaybackDevice] = []
    /// Set by the app so context references resolve against the library.
    var resolveTrack: ((CodecTrackReference) -> CodecTrack?)?
    var refreshLibrary: (() async -> Bool)?
    var reportSyncError: ((String) -> Void)?
    var reportSyncFailure: ((Error) -> Void)?
    private(set) var isSyncAvailable = true
    private(set) var hasOfflinePlaybackConflict = false
    var isOfflinePlayback: Bool { offlinePlayback != nil }
    var hasPendingOfflinePlayback: Bool { offlinePlayback != nil && !hasOfflinePlaybackConflict }
    private struct OfflinePlayback {
        var revision: Int64
        let mayPublish: Bool
        var hasLocalChanges = false
    }
    private var offlinePlayback: OfflinePlayback?
    private var offlineChangeSequence = 0
    private var recoveringOfflinePlayback = false
    /// Explicit playlist starts also update AppModel's local recency history.
    var recordPlaylistPlayback: ((String) -> Void)?
    private var commandTask: Task<Void, Never>?
    private var commandSequence = 0
    private var syncGeneration = 0
    private var pendingCommands = 0
    private var deferredSyncState: PlaybackState?
    /// Revision after this batch's own acknowledged writes. UI state stays
    /// deferred until the batch drains, so it cannot supply the next guard.
    /// nil invalidates queued snapshots after a failure or an external write.
    private var commandRevision: Int64?
    private var pendingLocalTransport = false
    private var acknowledgedLocalState: PlaybackState?
    private let syncPollInterval: Duration
    private let syncSafetyRefreshInterval: Duration
    private let eventStreamTimeout: Duration
    private let eventReconnectInterval: Duration
    @ObservationIgnored private let consumePlaybackEvents: PlaybackEventConsumer
    @ObservationIgnored private var lastEventStreamActivity: ContinuousClock.Instant?
    @ObservationIgnored private var eventStreamStartedAt: ContinuousClock.Instant?
    @ObservationIgnored private var lastSyncValidation: ContinuousClock.Instant?
    @ObservationIgnored private var eventStreamSequence = 0
    @ObservationIgnored private let makePlayer: @MainActor (AVPlayerItem) -> AVPlayer
    @ObservationIgnored private let activateAudioSession: @MainActor () throws -> Void

    init(
        syncPollInterval: Duration = .seconds(30),
        syncSafetyRefreshInterval: Duration = .seconds(300),
        eventStreamTimeout: Duration = .seconds(45),
        eventReconnectInterval: Duration = .seconds(3),
        consumePlaybackEvents: @escaping PlaybackEventConsumer = PlayerController.consumeSystemPlaybackEvents,
        makePlayer: @escaping @MainActor (AVPlayerItem) -> AVPlayer = { AVPlayer(playerItem: $0) },
        activateAudioSession: @escaping @MainActor () throws -> Void = PlayerController.activateSystemAudioSession
    ) {
        self.syncPollInterval = syncPollInterval
        self.syncSafetyRefreshInterval = syncSafetyRefreshInterval
        self.eventStreamTimeout = eventStreamTimeout
        self.eventReconnectInterval = eventReconnectInterval
        self.consumePlaybackEvents = consumePlaybackEvents
        self.makePlayer = makePlayer
        self.activateAudioSession = activateAudioSession
    }

    private static let previousDoubleTapWindowMS: Int64 = 3000
    private var lastPreviousTapMS: Int64 = 0
    /// While set in the future, remote clock ticks may not overwrite
    /// currentTime — prevents scrub rubber-banding until the server confirms.
    fileprivate var suppressClockUntilMS: Int64 = 0

    /// True when this phone is the device that should be making sound —
    /// which means transport taps can act locally first and sync after.
    var isActiveSyncDevice: Bool {
        offlinePlayback != nil || !syncEnabled || syncState?.activeDeviceID == deviceID || syncState?.activeDeviceID == nil
    }

    fileprivate var clockOffsetMS: Int64 = 0
    fileprivate var eventsTask: Task<Void, Never>?
    fileprivate var presenceTask: Task<Void, Never>?
    fileprivate var remoteClockTask: Task<Void, Never>?
    fileprivate var loadedFingerprint: String?
    private var preloadedItem: (fingerprint: String, url: URL, item: AVPlayerItem)?

    /// True while another device is the one actually making sound.
    var remoteDeviceIsActive: Bool {
        if offlinePlayback != nil { return false }
        guard syncEnabled, let active = syncState?.activeDeviceID else {
            return false
        }
        return active != deviceID
    }

    var activeDeviceName: String {
        if offlinePlayback != nil { return deviceName }
        guard let active = syncState?.activeDeviceID, active != deviceID else {
            return deviceName
        }
        return playbackDevices.first { $0.deviceID == active }?.name ?? "Other device"
    }

    private var player: AVPlayer?

    /// Frequency history for the Visualizer, fed by an audio tap on every
    /// item — recording from the first note, whatever screen is open.
    let spectrum = SpectrumHistory()
    @ObservationIgnored private lazy var spectrumAnalyzer = SpectrumAnalyzer(history: spectrum)
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var remoteCommandsConfigured = false
    private var nowPlayingArtworkFingerprint = ""
    private var audioSessionNeedsActivation = true
    private var isInterrupted = false
    private var resumeAfterInterruption = false
    private var interruptedPlaybackState: PlaybackState?
    private var lastPublishedRate: Double?
    private var lastPublishedDuration: Double?
    private static let audioLog = Logger(subsystem: "sh.codie.codec.mobile", category: "Playback")

    // MARK: - Starting playback

    func play(_ track: CodecTrack, from tracks: [CodecTrack], playlistID: String? = nil) {
        guard prepareExplicitPlayback(track) else { return }
        defer {
            if let playlistID, isPlaying, !remoteDeviceIsActive {
                recordPlaylistPlayback?(playlistID)
            }
        }
        source = makeQueue(from: tracks.isEmpty ? [track] : tracks, startingAt: track, shuffled: shuffle)
        sourceIndex = 0
        let trimmedPlaylistID = playlistID?.trimmingCharacters(in: .whitespacesAndNewlines)
        sourcePlaylistID = trimmedPlaylistID?.isEmpty == false ? trimmedPlaylistID : nil
        manualQueue = []
        history = []
        currentTrack = source.first ?? track

        if syncEnabled {
            if isActiveSyncDevice { startPlayback(at: 0) }
            sendSyncCommand("play", track: currentTrack, position: 0, locallyApplied: isActiveSyncDevice,
                            playlistID: remoteDeviceIsActive ? playlistID : nil)
            return
        }
        startPlayback(at: 0)
    }

    func playCollection(_ tracks: [CodecTrack], shuffled: Bool = false, playlistID: String? = nil) {
        let playable = isSyncAvailable ? tracks : tracks.filter { localPlaybackURL(for: $0) != nil }
        guard let first = shuffled ? playable.randomElement() : playable.first else {
            if !tracks.isEmpty { reportSyncError?("Download songs from this collection to play it offline.") }
            return
        }
        shuffle = shuffled
        play(first, from: tracks, playlistID: playlistID)
    }

    /// Jumps the line: plays right after the current track.
    func playNext(_ track: CodecTrack) {
        guard canEditCurrentPlayback else { return }
        manualQueue.insert(track, at: 0)
        if currentTrack == nil {
            next()
        } else if syncEnabled {
            sendSyncCommand("set_queue")
        }
    }

    /// Joins the end of the manual queue.
    func playLater(_ track: CodecTrack) {
        guard canEditCurrentPlayback else { return }
        manualQueue.append(track)
        if currentTrack == nil {
            next()
        } else if syncEnabled {
            sendSyncCommand("set_queue")
        }
    }

    func removeFromQueue(at index: Int) {
        guard canEditCurrentPlayback else { return }
        guard manualQueue.indices.contains(index) else {
            return
        }
        manualQueue.remove(at: index)
        if syncEnabled { sendSyncCommand("set_queue") }
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        guard canEditCurrentPlayback else { return }
        manualQueue.move(fromOffsets: source, toOffset: destination)
        if syncEnabled { sendSyncCommand("set_queue") }
    }

    func clearQueue() {
        guard canEditCurrentPlayback else { return }
        manualQueue = []
        if syncEnabled { sendSyncCommand("set_queue") }
    }

    /// A queue row with an identity that follows the TRACK, not its
    /// position. Positional ids made every row after a drop change identity,
    /// so SwiftUI rebuilt them all (and re-fetched their artwork) — that was
    /// the visible lag when releasing a drag.
    struct QueueEntry: Identifiable {
        let id: String
        let index: Int
        let track: CodecTrack
    }

    var manualQueueEntries: [QueueEntry] {
        Self.queueEntries(for: Array(manualQueue.enumerated()), prefix: "q")
    }

    /// Capped at what the queue screen shows; building the full tail of a
    /// large source on every render was wasted work.
    var upcomingEntries: [QueueEntry] {
        guard sourceIndex + 1 < source.count else {
            return []
        }
        let start = sourceIndex + 1
        let slice = source[start...].prefix(50).enumerated().map { (start + $0.offset, $0.element) }
        return Self.queueEntries(for: slice, prefix: "u")
    }

    /// Duplicate tracks get occurrence-numbered ids so identities stay
    /// unique and stable across reorders.
    private static func queueEntries(for indexed: [(Int, CodecTrack)], prefix: String) -> [QueueEntry] {
        var occurrences: [String: Int] = [:]
        return indexed.map { index, track in
            let occurrence = occurrences[track.id, default: 0]
            occurrences[track.id] = occurrence + 1
            return QueueEntry(id: "\(prefix)-\(track.id)-\(occurrence)", index: index, track: track)
        }
    }

    /// Tap a manual-queue entry: it plays now, everything queued before it
    /// is consumed.
    func jumpToManualQueue(at index: Int) {
        guard manualQueue.indices.contains(index) else {
            return
        }
        let track = manualQueue[index]
        guard prepareExplicitPlayback(track) else { return }
        manualQueue.removeSubrange(0...index)
        if let playing = currentTrack {
            history.append(playing)
        }
        currentTrack = track
        if syncEnabled {
            if isActiveSyncDevice { startPlayback(at: 0) }
            sendSyncCommand("play", track: track, position: 0, locallyApplied: isActiveSyncDevice)
        } else {
            startPlayback(at: 0)
        }
    }

    /// Tap an up-next entry: skip straight to it in the source; the manual
    /// queue keeps its place for afterwards.
    func jumpToUpcoming(sourceIndex index: Int) {
        guard source.indices.contains(index), index > sourceIndex else {
            return
        }
        guard prepareExplicitPlayback(source[index]) else { return }
        if let playing = currentTrack {
            history.append(playing)
        }
        sourceIndex = index
        currentTrack = source[index]
        if syncEnabled {
            if isActiveSyncDevice { startPlayback(at: 0) }
            sendSyncCommand("play", track: currentTrack, position: 0, locallyApplied: isActiveSyncDevice)
        } else {
            startPlayback(at: 0)
        }
    }

    func removeUpcoming(sourceIndex index: Int) {
        guard canEditCurrentPlayback else { return }
        guard source.indices.contains(index), index > sourceIndex else {
            return
        }
        source.remove(at: index)
        if syncEnabled { sendSyncCommand("set_queue") }
    }

    /// Reorders within the up-next slice; offsets are relative to the slice
    /// the queue screen displays (0 == the track right after the current one).
    func moveUpcoming(from offsets: IndexSet, to destination: Int) {
        guard canEditCurrentPlayback else { return }
        let base = sourceIndex + 1
        let translated = IndexSet(offsets.map { $0 + base })
        let target = destination + base
        guard translated.allSatisfy({ source.indices.contains($0) }), target <= source.count else {
            return
        }
        source.move(fromOffsets: translated, toOffset: target)
        if syncEnabled { sendSyncCommand("set_queue") }
    }

    // MARK: - Transport

    func togglePlayback(playlistID: String? = nil) {
        guard canEditCurrentPlayback else { return }
        let wasPlaying = isPlaying
        let canResumeLocally = isActiveSyncDevice && player != nil && currentTrack != nil
        defer {
            if !wasPlaying, isPlaying, canResumeLocally, let playlistID {
                recordPlaylistPlayback?(playlistID)
            }
        }
        if isInterrupted, isActiveSyncDevice {
            // An interruption is not guaranteed to deliver .ended. An
            // explicit Play can retry activation; iOS refuses it if a call
            // still owns the session.
            resumeAfterInterruption = true
            guard currentTrack != nil, player != nil else { return }
            do {
                try activateAudioSession()
            } catch {
                return
            }
            audioSessionNeedsActivation = false
            isInterrupted = false
            resumeAfterInterruption = false
            interruptedPlaybackState = nil
            player?.play()
            isPlaying = true
            updateNowPlayingPlaybackState()
            if syncEnabled { sendSyncCommand("play", position: currentTime, locallyApplied: true) }
            return
        }
        if syncEnabled {
            if isActiveSyncDevice, player == nil, let track = currentTrack {
                guard prepareExplicitPlayback(track) else { return }
                startPlayback(at: currentTime)
                sendSyncCommand("play", track: track, position: currentTime, locallyApplied: true)
                return
            }
            // Instant local flip when this phone is the speaker; the server
            // command follows in the background instead of gating the tap.
            if isActiveSyncDevice, player != nil, currentTrack != nil {
                let wasPlaying = isPlaying
                if wasPlaying {
                    player?.pause()
                    isPlaying = false
                } else {
                    guard configureAudioSession() else { return }
                    player?.play()
                    isPlaying = true
                }
                updateNowPlayingPlaybackState()
                sendSyncCommand(wasPlaying ? "pause" : "play", position: currentTime, locallyApplied: true)
                return
            }
            syncTogglePlayback(playlistID: playlistID)
            return
        }

        guard let player, currentTrack != nil else {
            if let first = manualQueue.first ?? source.first {
                play(first, from: source.isEmpty ? manualQueue : source)
            }
            return
        }

        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            guard configureAudioSession() else { return }
            player.play()
            isPlaying = true
        }
        updateNowPlayingPlaybackState()
    }

    /// Also accepts a lock-screen pause while an interruption has already
    /// made the local engine silent.
    func pausePlayback() {
        resumeAfterInterruption = false
        if isPlaying {
            togglePlayback()
        } else if isInterrupted, syncEnabled, isActiveSyncDevice {
            sendSyncCommand("pause", position: currentTime, locallyApplied: true)
        }
    }

    func next() {
        guard canEditCurrentPlayback else { return }
        if !isSyncAvailable { discardUnavailableUpcomingTracks() }
        if syncEnabled {
            guard isActiveSyncDevice else {
                sendSyncCommand("next", position: syncedPosition())
                return
            }
            // Advance locally for instant audio, then tell the server the
            // outcome as an explicit play (a bare "next" would advance the
            // server's copy a second time).
            if let next = peekNextTrack() {
                advance()
                sendSyncCommand("play", track: next, position: 0, locallyApplied: true)
            } else {
                advance()
                sendSyncCommand("next", position: currentTime, locallyApplied: true)
            }
            return
        }
        advance()
    }

    /// Tape-deck rewind semantics: the first press restarts the track; a
    /// second press within the window steps to the previous song (and keeps
    /// stepping back on further presses).
    func previous() {
        guard canEditCurrentPlayback else { return }
        let now = Self.nowMS()
        let steppingBack = now - lastPreviousTapMS < Self.previousDoubleTapWindowMS
        lastPreviousTapMS = now
        if !isSyncAvailable, steppingBack {
            while let previous = history.last, localPlaybackURL(for: previous) == nil { history.removeLast() }
        }

        if syncEnabled {
            guard isActiveSyncDevice else {
                sendSyncCommand(steppingBack ? "previous" : "seek", position: 0)
                return
            }

            if steppingBack, let previous = history.popLast() {
                if let index = source.firstIndex(where: { $0.id == previous.id }) {
                    sourceIndex = index
                }
                currentTrack = previous
                startPlayback(at: 0)
                sendSyncCommand("play", track: previous, position: 0, locallyApplied: true)
            } else {
                seekLocally(to: 0)
                sendSyncCommand("seek", position: 0, locallyApplied: true)
            }
            return
        }

        if steppingBack, let previous = history.popLast() {
            if let index = source.firstIndex(where: { $0.id == previous.id }) {
                sourceIndex = index
            }
            currentTrack = previous
            startPlayback(at: 0)
            return
        }

        seekLocally(to: 0)
    }

    func seek(to seconds: Double) {
        guard canEditCurrentPlayback else { return }
        if syncEnabled {
            if isActiveSyncDevice {
                seekLocally(to: seconds)
            } else {
                currentTime = seconds
            }
            // Hold the remote clock off the slider until the server confirms.
            suppressClockUntilMS = Self.nowMS() + 1500
            sendSyncCommand("seek", position: seconds, locallyApplied: isActiveSyncDevice)
            return
        }
        seekLocally(to: seconds)
    }

    func seekLocally(to seconds: Double) {
        currentTime = seconds
        player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        updateNowPlayingPlaybackState()
    }

    func toggleShuffle() {
        guard canEditCurrentPlayback else { return }
        if syncEnabled {
            syncToggleShuffle()
            return
        }

        shuffle.toggle()
        guard let currentTrack else {
            return
        }

        if shuffle {
            let rest = source.filter { $0.id != currentTrack.id }.shuffled()
            source = [currentTrack] + rest
        } else {
            source = source.sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }
            if let index = source.firstIndex(where: { $0.id == currentTrack.id }) {
                source.move(fromOffsets: IndexSet(integer: index), toOffset: 0)
            }
        }
        sourceIndex = 0
    }

    func cycleRepeat() {
        guard canEditCurrentPlayback else { return }
        let nextRepeat: RepeatMode
        switch repeatMode {
        case .off: nextRepeat = .all
        case .all: nextRepeat = .one
        case .one: nextRepeat = .off
        }

        repeatMode = nextRepeat
        if syncEnabled {
            sendSyncCommand("set_repeat", position: syncedPosition(), repeatMode: nextRepeat.rawValue)
            return
        }
    }

    // MARK: - Engine

    private func makeQueue(from tracks: [CodecTrack], startingAt track: CodecTrack, shuffled: Bool) -> [CodecTrack] {
        if shuffled {
            let rest = tracks.filter { $0.id != track.id }.shuffled()
            return [track] + rest
        }
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else {
            return [track] + tracks
        }
        return Array(tracks[index...]) + Array(tracks[..<index])
    }

    private func advance() {
        guard let playing = currentTrack else {
            if let first = manualQueue.first {
                manualQueue.removeFirst()
                currentTrack = first
                startPlayback(at: 0)
            }
            return
        }

        history.append(playing)

        if let queued = manualQueue.first {
            manualQueue.removeFirst()
            currentTrack = queued
            startPlayback(at: 0)
            return
        }

        if sourceIndex + 1 < source.count {
            sourceIndex += 1
            currentTrack = source[sourceIndex]
            startPlayback(at: 0)
            return
        }

        if repeatMode == .all, !source.isEmpty {
            if let index = source.firstIndex(where: { isSyncAvailable || localPlaybackURL(for: $0) != nil }) {
                sourceIndex = index
                currentTrack = source[index]
                startPlayback(at: 0)
                return
            }
        }

        player?.pause()
        isPlaying = false
        updateNowPlayingPlaybackState()
    }

    func handleTrackEnded() {
        guard isPlaying, !isInterrupted, isActiveSyncDevice else { return }
        if syncEnabled {
            if repeatMode == .one {
                seekLocally(to: 0)
                player?.play()
                isPlaying = true
                sendSyncCommand("seek", targetDeviceID: deviceID, position: 0, locallyApplied: true)
            } else {
                next()
            }
            return
        }

        if repeatMode == .one {
            seek(to: 0)
            player?.play()
            return
        }
        next()
    }

    private func startPlayback(at position: Double, shouldPlay: Bool = true) {
        guard let track = currentTrack, let url = playbackURL(for: track) else {
            isPlaying = false
            return
        }

        if shouldPlay, isInterrupted {
            resumeAfterInterruption = true
            interruptedPlaybackState = nil
        }

        configureRemoteCommands()
        detachPlayerObservers()

        // Reuse the prepared next item. AVPlayer controls when media is
        // actually fetched; an unattached item is not a gapless buffer.
        let item: AVPlayerItem
        if let preloaded = preloadedItem, preloaded.fingerprint == track.fingerprint, preloaded.url == url {
            item = preloaded.item
            preloadedItem = nil
        } else {
            item = AVPlayerItem(asset: makeAsset(for: url))
        }
        spectrumAnalyzer.attach(to: item)
        // Buffer well ahead - everything streams through the tunnel, so a
        // deep buffer is what keeps playback smooth.
        item.preferredForwardBufferDuration = 30
        let nextPlayer = makePlayer(item)
        player = nextPlayer

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak nextPlayer] _ in
            Task { @MainActor in
                guard let self, let nextPlayer, self.player === nextPlayer else { return }
                self.handleTrackEnded()
            }
        }

        timeObserver = nextPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak nextPlayer] time in
            Task { @MainActor in
                guard let nextPlayer else { return }
                self?.handlePlaybackTick(time, from: nextPlayer)
            }
        }

        if position > 0 {
            nextPlayer.seek(to: CMTime(seconds: position, preferredTimescale: 600))
        }
        currentTime = position
        isPlaying = shouldPlay && !isInterrupted && configureAudioSession()
        if isPlaying { nextPlayer.play() }
        loadedFingerprint = track.fingerprint
        updateNowPlayingMetadata(for: track)
        publishPresenceSoon()
        preloadNextIfNeeded()
    }

    func handlePlaybackTick(_ time: CMTime, from observedPlayer: AVPlayer) {
        // Removing an observer cannot recall an already enqueued callback.
        // An old player's final paused tick must never stop the next song.
        guard player === observedPlayer else { return }
        currentTime = time.seconds.isFinite ? time.seconds : 0
        // AVPlayer can briefly report paused during startup and natural
        // completion. Only session/route/explicit transport events pause
        // shared playback, never this progress callback.
        updateNowPlayingPlaybackState(periodic: true)
    }

    private func makeAsset(for url: URL) -> AVURLAsset {
        let headers = client?.authHeaders(for: url) ?? [:]
        if url.isFileURL || headers.isEmpty {
            return AVURLAsset(url: url)
        }
        return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }

    private func peekNextTrack() -> CodecTrack? {
        if let queued = manualQueue.first {
            return queued
        }
        if sourceIndex + 1 < source.count {
            return source[sourceIndex + 1]
        }
        if repeatMode == .all, !source.isEmpty {
            return source.first { isSyncAvailable || localPlaybackURL(for: $0) != nil }
        }
        return nil
    }

    /// Prepares the next asset/item for reuse at the track boundary.
    private func preloadNextIfNeeded() {
        guard let next = peekNextTrack() else {
            preloadedItem = nil
            return
        }
        guard let url = playbackURL(for: next) else {
            preloadedItem = nil
            return
        }
        guard preloadedItem?.fingerprint != next.fingerprint || preloadedItem?.url != url else { return }
        let preloaded = AVPlayerItem(asset: makeAsset(for: url))
        preloadedItem = (next.fingerprint, url, preloaded)
    }

    private func localPlaybackURL(for track: CodecTrack) -> URL? {
        if let local = downloads?.localAudioURL(for: track) { return local }
        if let url = track.audioURL, url.isFileURL,
           let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey]),
           values.isRegularFile == true, values.isReadable == true, (values.fileSize ?? 0) > 0 {
            return url
        }
        return nil
    }

    private func playbackURL(for track: CodecTrack) -> URL? {
        if let local = localPlaybackURL(for: track) { return local }
        guard isSyncAvailable else { return nil }
        return client?.audioURL(for: track)
    }

    private var canEditCurrentPlayback: Bool {
        guard isSyncAvailable || isActiveSyncDevice else {
            reportSyncError?("The server is unavailable. Choose a downloaded song to play on this iPhone.")
            return false
        }
        return true
    }

    private func prepareExplicitPlayback(_ track: CodecTrack) -> Bool {
        guard !isSyncAvailable else { return true }
        guard localPlaybackURL(for: track) != nil else {
            reportSyncError?("This song isn't downloaded. Connect to play it or choose a downloaded song.")
            return false
        }
        beginOfflinePlayback()
        offlinePlayback?.hasLocalChanges = true
        return true
    }

    /// Keep queue order while skipping entries that cannot play offline.
    /// Explicit selection is checked before mutating the existing session.
    private func discardUnavailableUpcomingTracks() {
        while let next = manualQueue.first, localPlaybackURL(for: next) == nil { manualQueue.removeFirst() }
        guard manualQueue.isEmpty else { return }
        while sourceIndex + 1 < source.count, localPlaybackURL(for: source[sourceIndex + 1]) == nil {
            source.remove(at: sourceIndex + 1)
        }
    }

    private func detachPlayerObservers() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.pause()
    }

    static func activateSystemAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback || session.mode != .default {
            try session.setCategory(.playback, mode: .default)
        }
        try session.setActive(true)
    }

    @discardableResult
    private func configureAudioSession() -> Bool {
        guard !isInterrupted else { return false }
        configureSystemObservers()
        guard audioSessionNeedsActivation else { return true }
        do {
            try activateAudioSession()
            audioSessionNeedsActivation = false
            return true
        } catch {
            Self.audioLog.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - System interruptions

    /// Other apps taking the audio session (a video, a call, Siri) pause the
    /// player underneath us; without these observers the play button and
    /// clock keep pretending. State follows the system, always.
    private var systemObserversConfigured = false

    private func configureSystemObservers() {
        guard !systemObserversConfigured else {
            return
        }
        systemObserversConfigured = true

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            // This observer is already delivered on the main queue. An
            // extra Task lets a queued sync snapshot seek/restart audio
            // before the controller learns that iOS interrupted it.
            MainActor.assumeIsolated {
                self?.handleInterruption(typeValue: typeValue, optionsValue: optionsValue)
            }
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleRouteChange(reasonValue: reasonValue)
            }
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // The activation cache belongs to the old audio service.
                self?.audioSessionNeedsActivation = true
            }
        }
    }

    func handleInterruption(typeValue: UInt?, optionsValue: UInt?) {
        guard let typeValue,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else {
            return
        }

        switch type {
        case .began:
            guard !isInterrupted else { return }
            resumeAfterInterruption = isPlaying && isActiveSyncDevice && player != nil
            isInterrupted = true
            audioSessionNeedsActivation = true
            interruptedPlaybackState = nil
            guard isActiveSyncDevice else { return }
            let position = player?.currentTime().seconds ?? currentTime
            if position.isFinite { currentTime = position }
            player?.pause()
            isPlaying = false
            updateNowPlayingPlaybackState()
            // A short system interruption is local. Sending a shared pause
            // and play creates delayed echoes that can rewind or pause the
            // resumed engine. Publish the final position when it ends.
        case .ended:
            guard isInterrupted else { return }
            isInterrupted = false
            let shouldResume = resumeAfterInterruption &&
                AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0).contains(.shouldResume)
            resumeAfterInterruption = false
            let pendingState = interruptedPlaybackState
            interruptedPlaybackState = nil
            guard isActiveSyncDevice, let track = currentTrack else { return }
            if shouldResume, configureAudioSession() {
                if let pendingState {
                    syncLocalAudio(to: pendingState, track: track, previousState: nil)
                } else if let player {
                    player.play()
                    isPlaying = true
                }
                updateNowPlayingPlaybackState()
                publishPresenceSoon()
                if syncEnabled {
                    sendSyncCommand("play", position: currentTime, locallyApplied: true)
                }
            } else if syncEnabled, syncState?.isPlaying == true {
                sendSyncCommand("pause", position: currentTime, locallyApplied: true)
            }
        @unknown default:
            break
        }
    }

    func handleRouteChange(reasonValue: UInt?) {
        guard let reasonValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
              reason == .oldDeviceUnavailable
        else {
            return
        }
        // Headphones yanked: pause like every music app does.
        guard isActiveSyncDevice else { return }
        resumeAfterInterruption = false
        player?.pause()
        acceptSystemPause()
    }

    /// The system paused us (interruption, route loss, another app). Fold
    /// that into our state and tell the server so every device agrees.
    private func acceptSystemPause() {
        guard isPlaying else {
            return
        }
        isPlaying = false
        updateNowPlayingPlaybackState()
        publishPresenceSoon()
        if syncEnabled, isActiveSyncDevice {
            sendSyncCommand("pause", position: currentTime, locallyApplied: true)
        }
    }

    // MARK: - Lock screen / Control Center

    private func configureRemoteCommands() {
        guard !remoteCommandsConfigured else {
            return
        }
        remoteCommandsConfigured = true

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                if self?.isPlaying == false {
                    self?.togglePlayback()
                }
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.pausePlayback()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.togglePlayback()
            }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.next()
            }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.previous()
            }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = event.positionTime
            Task { @MainActor in
                self?.seek(to: position)
            }
            return .success
        }
    }

    private func updateNowPlayingMetadata(for track: CodecTrack) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let duration = track.durationSeconds {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        nowPlayingArtworkFingerprint = track.fingerprint
        let fingerprint = track.fingerprint
        Task { [weak self] in
            guard let self, let client = self.client,
                  let url = client.artworkURL(for: track),
                  let image = await ArtworkLoader.shared.image(for: url, headers: client.authHeaders(for: url))
            else {
                return
            }
            guard self.nowPlayingArtworkFingerprint == fingerprint else {
                return
            }
            var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            current[MPMediaItemPropertyArtwork] = Self.lockScreenArtwork(for: image)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = current
        }
    }

    /// MediaPlayer invokes the artwork request handler on its own queue, so
    /// the closure must be built OUTSIDE MainActor isolation — a MainActor
    /// closure there trips Swift 6's runtime isolation check the moment the
    /// lock screen renders artwork (SIGTRAP in dispatch_assert_queue).
    nonisolated private static func lockScreenArtwork(for image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    private func updateNowPlayingPlaybackState(periodic: Bool = false) {
        let rate = isPlaying && player?.timeControlStatus == .playing ? 1.0 : 0.0
        let mediaDuration = duration
        // iOS advances elapsed time from the published rate. Rebuilding
        // artwork/metadata four times a second just to tick its clock causes
        // needless lock-screen work, especially while the display wakes.
        if periodic, lastPublishedRate == rate, lastPublishedDuration == mediaDuration { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        if mediaDuration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = mediaDuration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        lastPublishedRate = rate
        lastPublishedDuration = mediaDuration
    }
}

// MARK: - Shared playback sync (loud.playback.v2)
//
// Mirrors the desktop client: while a sync server is connected, every
// transport action becomes a server command, the server's state is the
// truth, and this phone only makes sound when it is the active device.

extension PlayerController {
    /// Reachability is supplied by AppModel after authorized server validation.
    /// Losing that capability suspends control traffic, never the audio engine.
    func setSyncAvailable(_ available: Bool) {
        guard available != isSyncAvailable else { return }
        if !available, currentTrack != nil, player != nil, isActiveSyncDevice {
            beginOfflinePlayback()
        }
        isSyncAvailable = available
        syncGeneration += 1
        commandTask?.cancel()
        commandTask = nil
        pendingCommands = 0
        commandRevision = nil
        pendingLocalTransport = false
        acknowledgedLocalState = nil
        deferredSyncState = nil
        recoveringOfflinePlayback = false
        eventsTask?.cancel()
        eventsTask = nil
        presenceTask?.cancel()
        presenceTask = nil
        lastEventStreamActivity = nil
        eventStreamStartedAt = nil
        lastSyncValidation = nil
        eventStreamSequence += 1
        if available, syncEnabled { startSyncTasks() }
    }

    private func beginOfflinePlayback() {
        guard offlinePlayback == nil else { return }
        let baseline = acknowledgedLocalState ?? syncState
        if let acknowledgedLocalState { syncState = acknowledgedLocalState }
        offlinePlayback = OfflinePlayback(
            revision: baseline?.revision ?? 0,
            mayPublish: baseline?.activeDeviceID == nil || baseline?.activeDeviceID == deviceID,
            hasLocalChanges: pendingCommands > 0
        )
        hasOfflinePlaybackConflict = false
        offlineChangeSequence += 1
        remoteClockTask?.cancel()
        remoteClockTask = nil
    }

    func startSync(client: CodecClient) {
        if syncEnabled, self.client?.baseURL == client.baseURL, self.client?.token == client.token { return }
        let sameServer = self.client?.baseURL == client.baseURL && self.client?.token == client.token
        let localSession = sameServer && currentTrack != nil && player != nil && (offlinePlayback != nil || !syncEnabled)
        let savedOffline = offlinePlayback
        let savedState = syncState
        let savedPlaylistID = sourcePlaylistID
        stopSync()
        if localSession {
            syncState = savedState
            sourcePlaylistID = savedPlaylistID
            offlinePlayback = savedOffline
            beginOfflinePlayback()
        } else {
            player?.pause()
            loadedFingerprint = nil
            preloadedItem = nil
        }
        self.client = client
        syncEnabled = true
        if isSyncAvailable { startSyncTasks() }
    }

    private func startSyncTasks() {
        restartEventStream()
        presenceTask?.cancel()
        presenceTask = Task { [weak self] in
            await self?.runPresenceLoop()
        }
    }

    func stopSync() {
        syncGeneration += 1
        commandTask?.cancel()
        commandTask = nil
        pendingCommands = 0
        pendingLocalTransport = false
        acknowledgedLocalState = nil
        deferredSyncState = nil
        commandRevision = nil
        syncEnabled = false
        lastEventStreamActivity = nil
        eventStreamStartedAt = nil
        lastSyncValidation = nil
        eventStreamSequence += 1
        eventsTask?.cancel()
        eventsTask = nil
        presenceTask?.cancel()
        presenceTask = nil
        remoteClockTask?.cancel()
        remoteClockTask = nil
        syncState = nil
        sourcePlaylistID = nil
        playbackDevices = []
        offlinePlayback = nil
        hasOfflinePlaybackConflict = false
        recoveringOfflinePlayback = false
        offlineChangeSequence += 1
    }

    func syncedPosition() -> Double {
        if isActiveSyncDevice, let player, loadedFingerprint == currentTrack?.fingerprint {
            let position = player.currentTime().seconds
            if position.isFinite { return max(0, position) }
        }
        guard let syncState else {
            return currentTime
        }
        return syncState.position(atClientTimeMS: Self.nowMS(), clockOffsetMS: clockOffsetMS)
    }

    // MARK: Commands

    func syncTogglePlayback(playlistID: String? = nil) {
        let target = syncState?.activeDeviceID ?? deviceID
        let targetIsPlaying = isPlaying

        if targetIsPlaying {
            isPlaying = false
            sendSyncCommand("pause", targetDeviceID: target, position: syncedPosition())
            return
        }

        var track = currentTrack
        if track == nil {
            track = manualQueue.first ?? source.first
            if let track {
                source = makeQueue(from: source.isEmpty ? [track] : source, startingAt: track, shuffled: shuffle)
                sourceIndex = 0
                currentTrack = track
            }
        }
        guard let track else {
            return
        }

        let position = currentTrack?.fingerprint == track.fingerprint ? syncedPosition() : 0
        isPlaying = true
        sendSyncCommand("play", targetDeviceID: target, track: syncState?.track == nil ? track : nil, position: position,
                        playlistID: playlistID)
    }

    func syncToggleShuffle() {
        let nextShuffle = !shuffle
        shuffle = nextShuffle
        if let currentTrack {
            if nextShuffle {
                source = [currentTrack] + source.filter { $0.id != currentTrack.id }.shuffled()
            }
            sourceIndex = 0
        }
        sendSyncCommand("set_shuffle", position: syncedPosition(), shuffle: nextShuffle)
    }

    func transferPlayback(to targetDeviceID: String) {
        guard isSyncAvailable else {
            reportSyncError?("Connect to change playback devices.")
            return
        }
        if offlinePlayback != nil, let track = currentTrack {
            offlinePlayback = nil
            hasOfflinePlaybackConflict = false
            sendSyncCommand(isPlaying ? "play" : "load", targetDeviceID: targetDeviceID,
                            track: track, position: currentTime, locallyApplied: targetDeviceID == deviceID)
            return
        }
        sendSyncCommand("transfer", targetDeviceID: targetDeviceID, position: syncedPosition())
    }

    func sendSyncCommand(
        _ kind: String,
        targetDeviceID: String? = nil,
        track: CodecTrack? = nil,
        position: Double? = nil,
        shuffle shuffleOverride: Bool? = nil,
        repeatMode repeatOverride: String? = nil,
        locallyApplied: Bool = false,
        playlistID: String? = nil
    ) {
        guard let client else {
            return
        }

        if !isSyncAvailable || offlinePlayback != nil {
            guard isActiveSyncDevice else { return }
            beginOfflinePlayback()
            offlinePlayback?.hasLocalChanges = true
            offlineChangeSequence += 1
            return
        }

        var command = PlaybackCommand(
            kind: kind,
            deviceID: deviceID,
            targetDeviceID: targetDeviceID ?? syncState?.activeDeviceID ?? deviceID,
            track: track.map(CodecTrackReference.init(track:)),
            context: ["play", "load", "set_queue", "set_shuffle"].contains(kind) && (kind != "play" || track != nil) ? contextSnapshot(shuffle: shuffleOverride, repeatMode: repeatOverride) : nil,
            positionSeconds: position,
            shuffle: shuffleOverride,
            repeatMode: repeatOverride
        )

        if pendingCommands == 0 {
            commandRevision = syncState?.revision ?? 0
            pendingLocalTransport = false
            acknowledgedLocalState = nil
        }
        pendingLocalTransport = pendingLocalTransport || locallyApplied
        let previous = commandTask
        // Preserve the origin connection's callback. AppModel scopes this
        // callback to its server, even if a new library connects mid-command.
        let recordPlaylistPlayback = self.recordPlaylistPlayback
        let generation = syncGeneration
        commandSequence += 1
        let sequence = commandSequence
        pendingCommands += 1
        commandTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, generation == self.syncGeneration else { return }
            if offlinePlayback != nil {
                pendingCommands -= 1
                return
            }
            do {
                if command.context != nil || locallyApplied {
                    guard let commandRevision else {
                        throw CodecClientError.httpStatus(409, "Queued context is no longer current")
                    }
                    command.expectedRevision = commandRevision
                }
                if locallyApplied, command.context == nil,
                   let owner = (acknowledgedLocalState ?? syncState)?.activeDeviceID,
                   owner != deviceID {
                    // An earlier queued transfer may have succeeded before
                    // this system pause/resume runs. Do not take it back.
                    throw CodecClientError.httpStatus(409, "Local playback ownership changed")
                }
                let state = try await client.sendPlaybackCommand(command)
                guard generation == syncGeneration else { return }
                if let playlistID, state.isPlaying {
                    recordPlaylistPlayback?(playlistID)
                }
                // Only our own contiguous acknowledgements can advance the
                // guard. A transport-only command may succeed after another
                // device edited the queue; its newer revision must not grant
                // permission to overwrite that queue with an old snapshot.
                // Bare next/previous mutate context only on the server, so
                // queued local snapshots also cannot be rebased over them.
                if !["next", "previous"].contains(command.kind),
                   let commandRevision, state.revision == commandRevision + 1 {
                    self.commandRevision = state.revision
                } else {
                    commandRevision = nil
                }
                if pendingLocalTransport, commandRevision != nil {
                    acknowledgedLocalState = state
                } else {
                    acknowledgedLocalState = nil
                }
                pendingCommands -= 1
                if sequence == commandSequence {
                    let latest = deferredSyncState.flatMap { $0.revision > state.revision ? $0 : nil } ?? state
                    deferredSyncState = nil
                    let preserveLocalTransport = pendingLocalTransport && commandRevision != nil && latest.revision == state.revision
                    pendingLocalTransport = false
                    acknowledgedLocalState = nil
                    applySyncState(latest, preservingLocalTransport: preserveLocalTransport)
                }
            } catch {
                guard generation == syncGeneration else { return }
                commandRevision = nil
                if Self.isConnectionFailure(error) {
                    if isActiveSyncDevice, currentTrack != nil {
                        beginOfflinePlayback()
                        offlinePlayback?.hasLocalChanges = true
                    }
                    reportSyncFailure?(error)
                    guard generation == syncGeneration else { return }
                    pendingCommands -= 1
                    if sequence == commandSequence {
                        deferredSyncState = nil
                        pendingLocalTransport = false
                        acknowledgedLocalState = nil
                    }
                    return
                }
                if case CodecClientError.httpStatus(409, _) = error {
                    reportSyncError?("Playback changed on another device. Try the action again.")
                }
                pendingCommands -= 1
                if sequence == commandSequence {
                    deferredSyncState = nil
                    let acknowledged = locallyApplied ? nil : acknowledgedLocalState
                    acknowledgedLocalState = nil
                    pendingLocalTransport = false
                    await reconcilePlayback(force: true, preservingLocalState: acknowledged)
                }
            }
        }
    }

    private func contextSnapshot(shuffle shuffleOverride: Bool? = nil, repeatMode repeatOverride: String? = nil) -> PlaybackContext {
        PlaybackContext(
            playbackSource: source.map(CodecTrackReference.init(track:)),
            playbackIndex: max(0, min(sourceIndex, max(source.count - 1, 0))),
            queuedTracks: manualQueue.map(CodecTrackReference.init(track:)),
            playHistory: history.map(CodecTrackReference.init(track:)),
            shuffle: shuffleOverride ?? shuffle,
            repeatMode: repeatOverride ?? repeatMode.rawValue,
            playlistID: sourcePlaylistID
        )
    }

    // MARK: Applying server state

    func applySyncState(_ state: PlaybackState, force: Bool = false, preservingLocalTransport: Bool = false) {
        // The server still describes the session before connectivity was lost.
        // Keep the local song, queue and transport until guarded recovery wins.
        guard offlinePlayback == nil else { return }
        let revision = syncState?.revision ?? -1
        guard state.revision > revision || (force && state.revision == revision) else {
            return
        }

        let previousState = syncState
        if syncState?.serverTimeMS != state.serverTimeMS {
            clockOffsetMS = state.serverTimeMS - Self.nowMS()
        }
        syncState = state
        sourcePlaylistID = state.context.playlistID
        shuffle = state.context.shuffle
        repeatMode = RepeatMode(rawValue: state.context.repeatMode) ?? .off

        if let resolveTrack {
            source = state.context.playbackSource.compactMap(resolveTrack)
            manualQueue = state.context.queuedTracks.compactMap(resolveTrack)
            history = state.context.playHistory.compactMap(resolveTrack)
            sourceIndex = max(0, min(state.context.playbackIndex, max(source.count - 1, 0)))
            let resolved = state.track.flatMap(resolveTrack)
            // A transient library refresh must not evict an already loaded
            // song when the authoritative track has not changed.
            if resolved != nil || state.track?.fingerprint != currentTrack?.fingerprint {
                currentTrack = resolved
            }
        }

        if state.activeDeviceID != deviceID, Self.nowMS() >= suppressClockUntilMS {
            currentTime = state.position(atClientTimeMS: Self.nowMS(), clockOffsetMS: clockOffsetMS)
        }

        if state.track != nil && currentTrack == nil {
            player?.pause()
            isPlaying = false
            Task { [weak self] in
                _ = await self?.refreshLibrary?()
                guard let self, let latest = self.syncState,
                      let reference = latest.track, self.resolveTrack?(reference) != nil else { return }
                self.applySyncState(latest, force: true)
            }
            return
        }
        if state.activeDeviceID == deviceID, let track = currentTrack {
            remoteClockTask?.cancel()
            remoteClockTask = nil
            syncLocalAudio(to: state, track: track, previousState: previousState,
                           preservingLocalTransport: preservingLocalTransport)
        } else {
            resumeAfterInterruption = false
            player?.pause()
            isPlaying = state.isPlaying
            startRemoteClockIfNeeded()
        }
        publishPresenceSoon()
    }

    private static func isConnectionFailure(_ error: Error) -> Bool {
        if let error = error as? URLError { return error.code != .cancelled }
        if case CodecClientError.httpStatus(let status, _) = error {
            return status == 401 || status == 403 || status == 408 || status == 429 || status >= 500
        }
        return false
    }

    private func resolveOfflineConflict(with remote: PlaybackState?) {
        if let intent = offlinePlayback, !intent.hasLocalChanges,
           let remote, remote.revision >= intent.revision {
            // Merely continuing audio through an outage is not an instruction
            // to override an explicit pause/transfer from another device.
            offlinePlayback = nil
            deferredSyncState = nil
            hasOfflinePlaybackConflict = false
            applySyncState(remote, force: true)
            return
        }
        syncState = remote
        deferredSyncState = nil
        if !hasOfflinePlaybackConflict {
            hasOfflinePlaybackConflict = true
            reportSyncError?("Playback changed on another device. Your song and queue are still on this iPhone.")
        }
    }

    private func recoverOfflinePlayback(using snapshot: PlaybackState?) async -> Bool {
        guard let intent = offlinePlayback else { return true }
        guard !recoveringOfflinePlayback, isSyncAvailable, let client else { return false }
        let remote = deferredSyncState.flatMap { $0.revision > (snapshot?.revision ?? -1) ? $0 : nil } ?? snapshot
        let revision = remote?.revision ?? 0
        guard intent.mayPublish, !hasOfflinePlaybackConflict,
              revision == intent.revision || remote == nil,
              remote?.activeDeviceID == nil || remote?.activeDeviceID == deviceID else {
            resolveOfflineConflict(with: remote)
            return true
        }
        guard let track = currentTrack else { return true }
        let generation = syncGeneration
        let sequence = offlineChangeSequence
        let intendsToPlay = isPlaying || (isInterrupted && resumeAfterInterruption)
        var command = PlaybackCommand(
            kind: intendsToPlay ? "play" : "load", deviceID: deviceID, targetDeviceID: deviceID,
            track: CodecTrackReference(track: track), context: contextSnapshot(), positionSeconds: syncedPosition()
        )
        command.expectedRevision = revision
        recoveringOfflinePlayback = true
        defer { if generation == syncGeneration { recoveringOfflinePlayback = false } }
        do {
            let acknowledgement = try await client.sendPlaybackCommand(command)
            guard generation == syncGeneration, isSyncAvailable, !Task.isCancelled,
                  offlinePlayback != nil else { return false }
            if let deferredSyncState, deferredSyncState.revision > acknowledgement.revision {
                resolveOfflineConflict(with: deferredSyncState)
                return true
            }
            if sequence != offlineChangeSequence {
                // Local controls stayed live during the upload. Its accepted
                // revision authorizes a later upload of the latest local intent.
                offlinePlayback?.revision = acknowledgement.revision
                syncState = acknowledgement
                lastSyncValidation = nil
                Task { [weak self] in
                    guard let self, generation == self.syncGeneration else { return }
                    await self.reconcilePlayback()
                }
                return false
            }
            offlinePlayback = nil
            deferredSyncState = nil
            hasOfflinePlaybackConflict = false
            applySyncState(acknowledgement, force: true, preservingLocalTransport: true)
            return true
        } catch {
            guard generation == syncGeneration else { return false }
            if case CodecClientError.httpStatus(409, _) = error {
                hasOfflinePlaybackConflict = true
                reportSyncError?("Playback changed on another device. Your song and queue are still on this iPhone.")
            } else {
                reportSyncFailure?(error)
            }
            return false
        }
    }

    /// Context/volume commands rebase the server clock without seeking.
    /// Compare both trajectories at the same instant; receipt latency and
    /// AVPlayer's initial buffering are not reasons to skip audio.
    private static func changesPlaybackPosition(from previous: PlaybackState?, to state: PlaybackState) -> Bool {
        guard let previous, previous.activeDeviceID == state.activeDeviceID,
              previous.track?.fingerprint == state.track?.fingerprint else { return true }
        let before = previous.position(atClientTimeMS: state.clock.updatedAtMS)
        return abs(before - state.clock.positionSeconds) > 0.05
    }

    private func syncLocalAudio(to state: PlaybackState, track: CodecTrack,
                                previousState: PlaybackState?, preservingLocalTransport: Bool = false) {
        let position = state.position(atClientTimeMS: Self.nowMS(), clockOffsetMS: clockOffsetMS)
        let positionChanged = Self.changesPlaybackPosition(from: previousState, to: state)

        if isInterrupted {
            if !state.isPlaying {
                resumeAfterInterruption = false
            } else if previousState?.isPlaying == false || previousState?.activeDeviceID != deviceID {
                // A new remote Play supersedes an earlier remote Pause.
                resumeAfterInterruption = true
            }
            if !preservingLocalTransport,
               positionChanged || previousState?.isPlaying != state.isPlaying || interruptedPlaybackState != nil {
                interruptedPlaybackState = state
            }
            isPlaying = false
            return
        }

        if loadedFingerprint != track.fingerprint || player == nil {
            startPlayback(at: position, shouldPlay: state.isPlaying)
            return
        } else if !preservingLocalTransport,
                  positionChanged || previousState?.isPlaying != state.isPlaying,
                  abs((player?.currentTime().seconds ?? 0) - position) > 0.02 {
            seekLocally(to: position)
        }

        if state.isPlaying {
            if (!isPlaying || previousState?.activeDeviceID != deviceID), configureAudioSession() {
                player?.play()
                isPlaying = true
            }
        } else {
            if isPlaying { player?.pause() }
            isPlaying = false
        }
        updateNowPlayingPlaybackState()
    }

    /// While another device plays, tick the displayed position forward.
    private func startRemoteClockIfNeeded() {
        remoteClockTask?.cancel()
        guard remoteDeviceIsActive, syncState?.isPlaying == true else {
            remoteClockTask = nil
            return
        }

        remoteClockTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.remoteDeviceIsActive, self.syncState?.isPlaying == true else {
                    return
                }
                if Self.nowMS() >= self.suppressClockUntilMS {
                    self.currentTime = self.syncedPosition()
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    // MARK: Event stream + presence

    private func restartEventStream() {
        eventsTask?.cancel()
        lastEventStreamActivity = nil
        eventStreamStartedAt = nil
        eventStreamSequence += 1
        let sequence = eventStreamSequence
        let generation = syncGeneration
        eventsTask = Task { [weak self] in
            await self?.runEventLoop(generation: generation, sequence: sequence)
        }
    }

    private func runEventLoop(generation: Int, sequence: Int) async {
        while !Task.isCancelled, syncEnabled, isSyncAvailable,
              generation == syncGeneration, sequence == eventStreamSequence {
            await consumeEventStream(generation: generation, sequence: sequence)
            if !Task.isCancelled, syncEnabled, isSyncAvailable,
               generation == syncGeneration, sequence == eventStreamSequence {
                try? await Task.sleep(for: eventReconnectInterval)
            }
        }
    }

    static func consumeSystemPlaybackEvents(
        _ request: URLRequest, receive: @escaping @MainActor (PlaybackStreamEvent) -> Void
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw CodecClientError.invalidResponse }
        guard http.statusCode == 200 else { throw CodecClientError.httpStatus(http.statusCode, "") }
        try Task.checkCancellation()
        receive(.connected)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            receive(.line(line))
        }
    }

    private func consumeEventStream(generation: Int, sequence: Int) async {
        guard isSyncAvailable, let client else { return }
        eventStreamStartedAt = .now
        defer {
            // A cancelled stream must not clear the health of its replacement.
            if generation == syncGeneration, sequence == eventStreamSequence {
                lastEventStreamActivity = nil
                eventStreamStartedAt = nil
            }
        }
        do {
            let request = try client.playbackEventsRequest()
            try await consumePlaybackEvents(request) { [weak self] event in
                guard let self, !Task.isCancelled, generation == self.syncGeneration,
                      sequence == self.eventStreamSequence else { return }
                switch event {
                case .connected:
                    self.lastEventStreamActivity = .now
                    // The stream supplies fresh playback/devices snapshots.
                    // Library changes while disconnected still need one fetch.
                    self.refreshLibraryFromEvent(generation: generation)
                case .line(let line):
                    if line == ": heartbeat" {
                        self.lastEventStreamActivity = .now
                    } else if line.hasPrefix("data:") {
                        let json = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if self.handleEventPayload(json) { self.lastEventStreamActivity = .now }
                    }
                }
            }
            if !Task.isCancelled, generation == syncGeneration, sequence == eventStreamSequence {
                reportSyncFailure?(URLError(.networkConnectionLost))
            }
        } catch {
            // Connection dropped; the outer loop reconnects.
            if !Task.isCancelled, generation == syncGeneration, sequence == eventStreamSequence {
                reportSyncFailure?(error)
            }
        }
    }

    private func refreshLibraryFromEvent(generation: Int) {
        Task { [weak self] in
            guard let self, self.syncEnabled, self.isSyncAvailable, generation == self.syncGeneration else { return }
            let refreshed = await self.refreshLibrary?() ?? true
            guard self.syncEnabled, generation == self.syncGeneration else { return }
            if !refreshed { self.lastSyncValidation = nil }
        }
    }

    private func handleEventPayload(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(PlaybackEventPayload.self, from: data),
              let type = payload.type,
              ["library", "devices", "device", "playback_state"].contains(type)
        else {
            return false
        }

        if type == "library" {
            refreshLibraryFromEvent(generation: syncGeneration)
        }
        if let devices = payload.devices {
            playbackDevices = devices.sorted { $0.updatedAt > $1.updatedAt }
        }
        if let device = payload.device {
            var next = playbackDevices.filter { $0.deviceID != device.deviceID }
            next.append(device)
            playbackDevices = next.sorted { $0.updatedAt > $1.updatedAt }
        }
        if let state = payload.playbackState {
            if offlinePlayback != nil {
                if hasOfflinePlaybackConflict {
                    if state.revision > (syncState?.revision ?? -1) { syncState = state }
                } else if state.revision > (deferredSyncState?.revision ?? -1) {
                    deferredSyncState = state
                }
            } else if pendingCommands > 0 {
                if state.revision > (deferredSyncState?.revision ?? -1) { deferredSyncState = state }
            } else {
                applySyncState(state)
            }
        }
        return true
    }

    private func runPresenceLoop() async {
        let generation = syncGeneration
        while !Task.isCancelled, syncEnabled, isSyncAvailable, generation == syncGeneration {
            await publishPresence()
            guard !Task.isCancelled, generation == syncGeneration else { return }

            let now = ContinuousClock.now
            let streamHealthy = lastEventStreamActivity.map {
                $0.duration(to: now) < eventStreamTimeout
            } ?? false
            let validationDue = lastSyncValidation.map {
                $0.duration(to: now) >= syncSafetyRefreshInterval
            } ?? true

            if !streamHealthy || validationDue {
                // TCP can remain open after connectivity disappears. Recover
                // it when two 15s heartbeats have been missed, without touching
                // local audio. Failed/reconnecting streams retain 30s fallback.
                let connectionStalled = eventStreamStartedAt.map {
                    $0.duration(to: now) >= eventStreamTimeout
                } ?? false
                if !streamHealthy, lastEventStreamActivity != nil || connectionStalled {
                    restartEventStream()
                }
                let playbackValidated = await reconcilePlayback()
                guard !Task.isCancelled, generation == syncGeneration else { return }
                let libraryValidated = await refreshLibrary?() ?? true
                guard !Task.isCancelled, generation == syncGeneration else { return }
                // A live event connection does not guarantee that REST reads
                // succeeded. Failed safety reads must retry next presence tick.
                if playbackValidated && libraryValidated { lastSyncValidation = .now }
            }
            try? await Task.sleep(for: syncPollInterval)
        }
    }

    @discardableResult
    func reconcilePlayback(force: Bool = false, preservingLocalState: PlaybackState? = nil) async -> Bool {
        guard syncEnabled, isSyncAvailable, let client else { return false }
        let generation = syncGeneration
        do {
            async let devices = client.playbackDevices()
            async let state = client.playbackState()
            let (nextDevices, nextState) = try await (devices, state)
            guard generation == syncGeneration, !Task.isCancelled else { return false }
            playbackDevices = nextDevices
            if offlinePlayback != nil { return await recoverOfflinePlayback(using: nextState) }
            if pendingCommands == 0, let nextState {
                let preserve = preservingLocalState.map {
                    $0.isPlaying == nextState.isPlaying &&
                    !Self.changesPlaybackPosition(from: $0, to: nextState)
                } ?? false
                applySyncState(nextState, force: force, preservingLocalTransport: preserve)
            }
            return true
        } catch {
            // Presence polling and reconnect retry without interrupting local audio.
            if !Task.isCancelled, generation == syncGeneration { reportSyncFailure?(error) }
            return false
        }
    }

    func publishPresenceSoon() {
        guard syncEnabled, isSyncAvailable else {
            return
        }
        Task { [weak self] in
            await self?.publishPresence()
        }
    }

    private func publishPresence() async {
        guard syncEnabled, isSyncAvailable, let client else {
            return
        }
        let generation = syncGeneration

        let device = CodecPlaybackDevice(
            deviceID: deviceID,
            name: deviceName,
            trackID: currentTrack?.id,
            trackFingerprint: currentTrack?.fingerprint,
            trackTitle: currentTrack?.title,
            isPlaying: isPlaying && !remoteDeviceIsActive,
            positionSeconds: 0,
            volume: 1,
            updatedAt: Self.nowMS()
        )
        do {
            try await client.publishPlaybackDevice(device)
        } catch {
            if !Task.isCancelled, generation == syncGeneration { reportSyncFailure?(error) }
        }
    }

    /// Devices for the "Playing on" picker: this phone first, then the rest,
    /// freshest presence first.
    var deviceOptions: [CodecPlaybackDevice] {
        // Match the server's two-minute presence expiry without fetching its
        // entire device list on every heartbeat.
        let cutoff = Self.nowMS() + clockOffsetMS - 120_000
        var options = playbackDevices.filter { $0.deviceID != deviceID && $0.updatedAt > cutoff }
        options.sort { $0.updatedAt > $1.updatedAt }
        let me = playbackDevices.first { $0.deviceID == deviceID }
            ?? CodecPlaybackDevice(deviceID: deviceID, name: deviceName)
        return [me] + options
    }

    static func nowMS() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

#if DEBUG
extension PlayerController {
    func configureForScreenshot(current track: CodecTrack, source tracks: [CodecTrack], queued: [CodecTrack]) {
        detachPlayerObservers()
        eventsTask?.cancel()
        eventsTask = nil
        presenceTask?.cancel()
        presenceTask = nil
        remoteClockTask?.cancel()
        remoteClockTask = nil

        let sourceTracks = tracks.isEmpty ? [track] : tracks
        let safeIndex = sourceTracks.firstIndex { $0.id == track.id } ?? 0
        let duration = max(track.durationSeconds ?? 150, 1)
        let position = min(max(duration * 0.42, 18), max(duration - 5, 0))
        let now = Self.nowMS()
        let desktopDeviceID = "desktop-blog"

        syncEnabled = true
        playbackDevices = [
            CodecPlaybackDevice(
                deviceID: deviceID,
                name: "\(deviceName) (this iPhone)",
                trackID: track.id,
                trackFingerprint: track.fingerprint,
                trackTitle: track.title,
                isPlaying: false,
                positionSeconds: position,
                volume: 0.72,
                updatedAt: now
            ),
            CodecPlaybackDevice(
                deviceID: desktopDeviceID,
                name: "Studio Mac",
                trackID: track.id,
                trackFingerprint: track.fingerprint,
                trackTitle: track.title,
                isPlaying: true,
                positionSeconds: position,
                volume: 0.86,
                updatedAt: now
            )
        ]
        currentTrack = track
        source = sourceTracks
        sourceIndex = safeIndex
        manualQueue = queued
        history = Array(sourceTracks.prefix(safeIndex))
        shuffle = true
        repeatMode = .all
        currentTime = position
        isPlaying = true
        loadedFingerprint = track.fingerprint

        func reference(_ track: CodecTrack) -> [String: String] {
            [
                "id": track.id,
                "path": "loud://track/\(track.fingerprint)",
                "fingerprint": track.fingerprint
            ]
        }

        let payload: [String: Any] = [
            "schema": "loud.playback.v2",
            "revision": 1,
            "active_device_id": desktopDeviceID,
            "state": "playing",
            "track": reference(track),
            "context": [
                "playback_source": sourceTracks.map(reference),
                "playback_index": safeIndex,
                "queued_tracks": queued.map(reference),
                "play_history": history.map(reference),
                "shuffle": true,
                "repeat": RepeatMode.all.rawValue
            ],
            "clock": [
                "position_seconds": position,
                "started_at_ms": now,
                "updated_at_ms": now
            ],
            "volume": 0.86,
            "server_time_ms": now
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let state = try? JSONDecoder().decode(PlaybackState.self, from: data)
        else {
            return
        }
        applySyncState(state, force: true)
    }
}
#endif
