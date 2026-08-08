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

    func clearQueue() {
        manualQueue = []
    }

    // MARK: - Transport

    func togglePlayback() {
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
        advance()
    }

    func previous() {
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
        currentTime = seconds
        player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        updateNowPlayingPlaybackState()
    }

    func toggleShuffle() {
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
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
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
        updateNowPlayingMetadata(for: track)
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
