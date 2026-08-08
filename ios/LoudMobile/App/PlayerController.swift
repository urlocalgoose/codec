import AVFoundation
import Foundation
import MediaPlayer
import Observation
import UIKit

enum RepeatMode: String, CaseIterable {
    case off
    case all
    case one
}

/// The playback engine: owns the AVPlayer, the queue, background audio,
/// and the lock-screen / Control Center integration.
@MainActor
@Observable
final class PlayerController {
    private(set) var currentTrack: LoudTrack?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    var shuffle = false
    var repeatMode: RepeatMode = .off

    /// The ordered source the current track came from (playlist, album, search…).
    private(set) var source: [LoudTrack] = []
    private(set) var sourceIndex = 0
    /// Tracks manually queued with "Play Next" — they win over the source.
    private(set) var manualQueue: [LoudTrack] = []
    private var history: [LoudTrack] = []

    var duration: Double {
        let mediaDuration = player?.currentItem?.duration.seconds ?? .nan
        if mediaDuration.isFinite, mediaDuration > 0 {
            return mediaDuration
        }
        return currentTrack?.durationSeconds ?? 0
    }

    /// What the queue screen shows: now playing, then the manual queue,
    /// then the rest of the source.
    var upNext: [LoudTrack] {
        var items: [LoudTrack] = []
        items.append(contentsOf: manualQueue)
        if sourceIndex + 1 < source.count {
            items.append(contentsOf: source[(sourceIndex + 1)...])
        }
        return items
    }

    var client: LoudClient?
    var downloads: DownloadStore?

    // MARK: Shared playback (loud.playback.v2) state

    /// Stable identity for this phone in the device list.
    let deviceID: String = {
        let key = "loud.playbackDeviceId"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let fresh = "device-\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()
    let deviceName = UIDevice.current.name

    private(set) var syncEnabled = false
    private(set) var syncState: PlaybackState?
    private(set) var playbackDevices: [LoudPlaybackDevice] = []
    /// Set by the app so context references resolve against the library.
    var resolveTrack: ((LoudTrackReference) -> LoudTrack?)?

    fileprivate var clockOffsetMS: Int64 = 0
    fileprivate var eventsTask: Task<Void, Never>?
    fileprivate var presenceTask: Task<Void, Never>?
    fileprivate var remoteClockTask: Task<Void, Never>?
    fileprivate var loadedFingerprint: String?

    /// True while another device is the one actually making sound.
    var remoteDeviceIsActive: Bool {
        guard syncEnabled, let active = syncState?.activeDeviceID else {
            return false
        }
        return active != deviceID
    }

    var activeDeviceName: String {
        guard let active = syncState?.activeDeviceID, active != deviceID else {
            return deviceName
        }
        return playbackDevices.first { $0.deviceID == active }?.name ?? "Other device"
    }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var remoteCommandsConfigured = false
    private var nowPlayingArtworkFingerprint = ""

    // MARK: - Starting playback

    func play(_ track: LoudTrack, from tracks: [LoudTrack]) {
        source = makeQueue(from: tracks.isEmpty ? [track] : tracks, startingAt: track, shuffled: shuffle)
        sourceIndex = 0
        manualQueue = []
        history = []
        currentTrack = source.first ?? track

        if syncEnabled {
            sendSyncCommand("play", track: currentTrack, position: 0)
            return
        }
        startPlayback(at: 0)
    }

    func playCollection(_ tracks: [LoudTrack], shuffled: Bool = false) {
        guard let first = shuffled ? tracks.randomElement() : tracks.first else {
            return
        }
        shuffle = shuffled
        play(first, from: tracks)
    }

    func playNext(_ track: LoudTrack) {
        manualQueue.append(track)
        if currentTrack == nil {
            advance()
        }
    }

    func removeFromQueue(at index: Int) {
        guard manualQueue.indices.contains(index) else {
            return
        }
        manualQueue.remove(at: index)
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        manualQueue.move(fromOffsets: source, toOffset: destination)
    }

    func clearQueue() {
        manualQueue = []
    }

    // MARK: - Transport

    func togglePlayback() {
        if syncEnabled {
            syncTogglePlayback()
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
            configureAudioSession()
            player.play()
            isPlaying = true
        }
        updateNowPlayingPlaybackState()
    }

    func next() {
        if syncEnabled {
            sendSyncCommand("next", position: syncedPosition())
            return
        }
        advance()
    }

    func previous() {
        if syncEnabled {
            sendSyncCommand("previous", position: syncedPosition())
            return
        }

        if currentTime > 4 {
            seek(to: 0)
            return
        }

        guard let previous = history.popLast() else {
            seek(to: 0)
            return
        }

        if let index = source.firstIndex(where: { $0.id == previous.id }) {
            sourceIndex = index
        }
        currentTrack = previous
        startPlayback(at: 0)
    }

    func seek(to seconds: Double) {
        if syncEnabled {
            currentTime = seconds
            sendSyncCommand("seek", position: seconds)
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
        let nextRepeat: RepeatMode
        switch repeatMode {
        case .off: nextRepeat = .all
        case .all: nextRepeat = .one
        case .one: nextRepeat = .off
        }

        if syncEnabled {
            sendSyncCommand("set_repeat", position: syncedPosition(), repeatMode: nextRepeat.rawValue)
            return
        }
        repeatMode = nextRepeat
    }

    // MARK: - Engine

    private func makeQueue(from tracks: [LoudTrack], startingAt track: LoudTrack, shuffled: Bool) -> [LoudTrack] {
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
            sourceIndex = 0
            currentTrack = source[0]
            startPlayback(at: 0)
            return
        }

        isPlaying = false
        updateNowPlayingPlaybackState()
    }

    private func handleTrackEnded() {
        if syncEnabled {
            guard syncState?.activeDeviceID == deviceID else {
                return
            }
            if repeatMode == .one {
                sendSyncCommand("seek", targetDeviceID: deviceID, position: 0)
            } else {
                sendSyncCommand("next", targetDeviceID: deviceID, position: syncedPosition())
            }
            return
        }

        if repeatMode == .one {
            seek(to: 0)
            player?.play()
            return
        }
        advance()
    }

    private func startPlayback(at position: Double) {
        guard let track = currentTrack, let url = playbackURL(for: track) else {
            isPlaying = false
            return
        }

        configureAudioSession()
        configureRemoteCommands()
        detachPlayerObservers()

        let asset: AVURLAsset
        if url.isFileURL || client?.authHeaders.isEmpty != false {
            asset = AVURLAsset(url: url)
        } else {
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": client?.authHeaders ?? [:]])
        }
        let item = AVPlayerItem(asset: asset)
        let nextPlayer = AVPlayer(playerItem: item)
        player = nextPlayer

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleTrackEnded()
            }
        }

        timeObserver = nextPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                self.updateNowPlayingPlaybackState()
            }
        }

        if position > 0 {
            nextPlayer.seek(to: CMTime(seconds: position, preferredTimescale: 600))
        }
        currentTime = position
        nextPlayer.play()
        isPlaying = true
        loadedFingerprint = track.fingerprint
        updateNowPlayingMetadata(for: track)
        publishPresenceSoon()
    }

    private func playbackURL(for track: LoudTrack) -> URL? {
        if let local = downloads?.localAudioURL(for: track) {
            return local
        }
        return client?.audioURL(for: track)
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

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
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
                if self?.isPlaying == true {
                    self?.togglePlayback()
                }
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

    private func updateNowPlayingMetadata(for track: LoudTrack) {
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
                  let image = await ArtworkLoader.shared.image(for: url, headers: client.authHeaders)
            else {
                return
            }
            guard self.nowPlayingArtworkFingerprint == fingerprint else {
                return
            }
            var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            current[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = current
        }
    }

    private func updateNowPlayingPlaybackState() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

// MARK: - Shared playback sync (loud.playback.v2)
//
// Mirrors the desktop client: while a sync server is connected, every
// transport action becomes a server command, the server's state is the
// truth, and this phone only makes sound when it is the active device.

extension PlayerController {
    func startSync(client: LoudClient) {
        self.client = client
        syncEnabled = true

        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            await self?.runEventLoop()
        }

        presenceTask?.cancel()
        presenceTask = Task { [weak self] in
            await self?.runPresenceLoop()
        }
    }

    func stopSync() {
        syncEnabled = false
        eventsTask?.cancel()
        eventsTask = nil
        presenceTask?.cancel()
        presenceTask = nil
        remoteClockTask?.cancel()
        remoteClockTask = nil
        syncState = nil
        playbackDevices = []
    }

    func syncedPosition() -> Double {
        guard let syncState else {
            return currentTime
        }
        return syncState.position(atClientTimeMS: Self.nowMS(), clockOffsetMS: clockOffsetMS)
    }

    // MARK: Commands

    func syncTogglePlayback() {
        let target = syncState?.activeDeviceID ?? deviceID
        let targetIsPlaying = syncState?.isPlaying == true && syncState?.activeDeviceID == target

        if targetIsPlaying {
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
        sendSyncCommand("play", targetDeviceID: target, track: track, position: position)
    }

    func syncToggleShuffle() {
        let nextShuffle = !shuffle
        if let currentTrack {
            if nextShuffle {
                source = [currentTrack] + source.filter { $0.id != currentTrack.id }.shuffled()
            }
            sourceIndex = 0
        }
        sendSyncCommand("set_shuffle", position: syncedPosition(), shuffle: nextShuffle)
    }

    func transferPlayback(to targetDeviceID: String) {
        sendSyncCommand("transfer", targetDeviceID: targetDeviceID, position: syncedPosition())
    }

    func sendSyncCommand(
        _ kind: String,
        targetDeviceID: String? = nil,
        track: LoudTrack? = nil,
        position: Double? = nil,
        shuffle shuffleOverride: Bool? = nil,
        repeatMode repeatOverride: String? = nil
    ) {
        guard let client else {
            return
        }

        let command = PlaybackCommand(
            kind: kind,
            deviceID: deviceID,
            targetDeviceID: targetDeviceID ?? syncState?.activeDeviceID ?? deviceID,
            track: track.map(LoudTrackReference.init(track:)),
            context: contextSnapshot(shuffle: shuffleOverride, repeatMode: repeatOverride),
            positionSeconds: position,
            shuffle: shuffleOverride,
            repeatMode: repeatOverride
        )

        Task {
            do {
                let state = try await client.sendPlaybackCommand(command)
                applySyncState(state, force: true)
            } catch {
                // A dropped command should not brick local controls; the SSE
                // stream or the next poll repairs state.
            }
        }
    }

    private func contextSnapshot(shuffle shuffleOverride: Bool? = nil, repeatMode repeatOverride: String? = nil) -> PlaybackContext {
        PlaybackContext(
            playbackSource: source.map(LoudTrackReference.init(track:)),
            playbackIndex: max(0, min(sourceIndex, max(source.count - 1, 0))),
            queuedTracks: manualQueue.map(LoudTrackReference.init(track:)),
            playHistory: [],
            shuffle: shuffleOverride ?? shuffle,
            repeatMode: repeatOverride ?? repeatMode.rawValue
        )
    }

    // MARK: Applying server state

    func applySyncState(_ state: PlaybackState, force: Bool = false) {
        guard force || state.revision > (syncState?.revision ?? -1) else {
            return
        }

        clockOffsetMS = state.serverTimeMS - Self.nowMS()
        syncState = state
        shuffle = state.context.shuffle
        repeatMode = RepeatMode(rawValue: state.context.repeatMode) ?? .off

        if let resolveTrack {
            source = state.context.playbackSource.compactMap(resolveTrack)
            manualQueue = state.context.queuedTracks.compactMap(resolveTrack)
            sourceIndex = max(0, min(state.context.playbackIndex, max(source.count - 1, 0)))
            if let reference = state.track, let resolved = resolveTrack(reference) {
                currentTrack = resolved
            }
        }

        currentTime = state.position(atClientTimeMS: Self.nowMS(), clockOffsetMS: clockOffsetMS)

        if state.activeDeviceID == deviceID, let track = currentTrack {
            remoteClockTask?.cancel()
            remoteClockTask = nil
            syncLocalAudio(to: state, track: track)
        } else {
            player?.pause()
            isPlaying = state.isPlaying
            startRemoteClockIfNeeded()
        }
        publishPresenceSoon()
    }

    private func syncLocalAudio(to state: PlaybackState, track: LoudTrack) {
        let position = state.position(atClientTimeMS: Self.nowMS(), clockOffsetMS: clockOffsetMS)

        if loadedFingerprint != track.fingerprint || player == nil {
            startPlayback(at: position)
        } else if abs((player?.currentTime().seconds ?? 0) - position) > 0.75 {
            seekLocally(to: position)
        }

        if state.isPlaying {
            configureAudioSession()
            player?.play()
            isPlaying = true
        } else {
            player?.pause()
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
                self.currentTime = self.syncedPosition()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    // MARK: Event stream + presence

    private func runEventLoop() async {
        while !Task.isCancelled, syncEnabled {
            await consumeEventStream()
            if !Task.isCancelled, syncEnabled {
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func consumeEventStream() async {
        guard let client else {
            return
        }

        do {
            let request = try client.playbackEventsRequest()
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return
            }

            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else {
                    continue
                }
                let json = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                handleEventPayload(json)
            }
        } catch {
            // Connection dropped; the outer loop reconnects.
        }
    }

    private func handleEventPayload(_ json: String) {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(PlaybackEventPayload.self, from: data)
        else {
            return
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
            applySyncState(state)
        }
    }

    private func runPresenceLoop() async {
        while !Task.isCancelled, syncEnabled {
            await publishPresence()
            try? await Task.sleep(for: .seconds(10))
        }
    }

    func publishPresenceSoon() {
        guard syncEnabled else {
            return
        }
        Task { [weak self] in
            await self?.publishPresence()
        }
    }

    private func publishPresence() async {
        guard syncEnabled, let client else {
            return
        }

        let device = LoudPlaybackDevice(
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
        try? await client.publishPlaybackDevice(device)
    }

    /// Devices for the "Playing on" picker: this phone first, then the rest,
    /// freshest presence first.
    var deviceOptions: [LoudPlaybackDevice] {
        var options = playbackDevices.filter { $0.deviceID != deviceID }
        options.sort { $0.updatedAt > $1.updatedAt }
        let me = playbackDevices.first { $0.deviceID == deviceID }
            ?? LoudPlaybackDevice(deviceID: deviceID, name: deviceName)
        return [me] + options
    }

    static func nowMS() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
