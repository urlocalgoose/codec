import Foundation
import Observation
import AVFoundation
import MediaPlayer

struct AuxPendingInvitation: Identifiable {
    let id = UUID()
    let server: URL
    let secret: String
}

/// Personal authority and session authority never share a client or credential slot.
@MainActor @Observable final class AuxController {
    private(set) var state: AuxState?
    private(set) var catalog: [AuxTrack] = []
    private(set) var busy = false
    private(set) var issue = ""
    private(set) var invitation: AuxInvitation?
    var pendingInvitation: AuxPendingInvitation?
    var showCreate = false
    var displayName = "Guest"
    var muted = false { didSet { audio?.isMuted = muted } }
    private(set) var listening = false
    private(set) var validating = false
    private(set) var hasSavedSession = UserDefaults.standard.data(forKey: "codec.aux.v2.identity") != nil
    private(set) var membership: [String: String] = [:]
    private(set) var saveMessages: [String: String] = [:]
    private(set) var sessionClient: AuxClient?
    private var inviteSecret = ""
    private var polling: Task<Void, Never>?
    private var audio: AVPlayer?
    private var audioFingerprint: String?
    private var receivedAt = ContinuousClock.now
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var interrupted = false
    private var generation = 0
    private struct SaveAttempt { let operationID: String; let grant: AuxGrantReference }
    private var operations: [String: SaveAttempt] = [:]
    private var saving = Set<String>()
    @ObservationIgnored weak var personalPlayer: PlayerController?

    var isGuest: Bool { state?.role == "guest" }
    var isActive: Bool { state != nil }
    var requiresRestore: Bool { state == nil && hasSavedSession }
    var link: URL? {
        guard !inviteSecret.isEmpty, let sessionClient,
              var components = URLComponents(url: sessionClient.baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = "aux=" + inviteSecret
        return components.url
    }
    private struct SavedSession: Codable {
        let server: URL
        let sessionID: String
        let participantID: String
        let role: String
    }
    private let storageKey = "codec.aux.v2.identity"
    @ObservationIgnored private let makeClient: @Sendable (URL, String?) -> AuxClient
    init(makeClient: @escaping @Sendable (URL, String?) -> AuxClient = { AuxClient(baseURL: $0, token: $1) }) {
        self.makeClient = makeClient
    }

    func presentInvitation(server: URL, secret: String) {
        pendingInvitation = AuxPendingInvitation(server: server, secret: secret)
        invitation = nil; issue = ""
    }
    func inspectInvitation() async {
        guard let pendingInvitation else { return }
        busy = true; defer { busy = false }
        do { invitation = try await makeClient(pendingInvitation.server, nil).invitation(secret: pendingInvitation.secret) }
        catch { issue = "This invitation has expired or is unavailable. Ask the host for a new link." }
    }
    func join(player: PlayerController) async {
        guard let pendingInvitation, invitation != nil, !isActive else { return }
        busy = true; defer { busy = false }
        do {
            let result = try await makeClient(pendingInvitation.server, nil).join(secret: pendingInvitation.secret, name: displayName)
            guard CredentialStore.write(result.participantToken, account: "aux-participant") else { throw CodecClientError.invalidResponse }
            sessionClient = makeClient(pendingInvitation.server, result.participantToken)
            persist(SavedSession(server: pendingInvitation.server, sessionID: result.sessionID, participantID: result.participantID, role: "guest"))
            self.pendingInvitation = nil
            attach(result.state, player: player, explicitlyListen: result.state.mode == .listenTogether)
            await refreshCatalog()
        } catch { issue = "Couldn’t join Aux. Check the invitation and try again." }
    }
    func create(personal: CodecClient, player: PlayerController, mode: AuxMode, tracks: [String], allowSaves: Bool, allowContributions: Bool) async {
        guard !tracks.isEmpty, !isActive else { return }
        busy = true; defer { busy = false }
        do {
            let client = makeClient(personal.baseURL, personal.token)
            let output = player.syncState?.activeDeviceID ?? player.deviceID
            let result = try await client.create(mode: mode, deviceID: output, name: "Codec host", fingerprints: tracks, allowSaves: allowSaves, allowContributions: allowContributions)
            sessionClient = client
            inviteSecret = result.inviteSecret
            CredentialStore.write(inviteSecret, account: "aux-invitation")
            persist(SavedSession(server: personal.baseURL, sessionID: result.sessionID, participantID: "host", role: "host"))
            attach(result.state, player: player, explicitlyListen: false)
            showCreate = false
            await refreshCatalog()
        } catch { issue = "Couldn’t start Aux. Include the current song and keep the current output selected." }
    }
    func restore(personal: CodecClient?, player: PlayerController) async {
        guard !isActive, !validating else { return }
        validating = true; defer { validating = false }
        guard let data = UserDefaults.standard.data(forKey: storageKey), let saved = try? JSONDecoder().decode(SavedSession.self, from: data) else {
            validating = false
            await discover(personal: personal, player: player)
            return
        }
        let token: String?
        if saved.role == "guest" { token = CredentialStore.read("aux-participant") }
        else if personal?.baseURL == saved.server { token = personal?.token }
        else { return }
        guard let token else { clear(); return }
        let client = makeClient(saved.server, token)
        do {
            let next = try await client.state(saved.sessionID)
            guard next.role == saved.role, next.participantID == saved.participantID else { clear(); return }
            sessionClient = client
            inviteSecret = saved.role == "host" ? CredentialStore.read("aux-invitation") ?? "" : ""
            attach(next, player: player, explicitlyListen: false)
            await refreshCatalog()
        } catch { handle(error) }
    }
    func discover(personal: CodecClient?, player: PlayerController, isAuthorized: () -> Bool = { true }) async {
        guard isAuthorized(), !isActive, !hasSavedSession, !validating, let personal,
              player.client?.baseURL == personal.baseURL, player.client?.token == personal.token else { return }
        validating = true; defer { validating = false }
        let discoveryGeneration = generation
        let client = makeClient(personal.baseURL, personal.token)
        guard let sessions = try? await client.sessions(), let next = sessions.first,
              !Task.isCancelled, isAuthorized(), generation == discoveryGeneration, !isActive, !hasSavedSession,
              player.client?.baseURL == personal.baseURL, player.client?.token == personal.token,
              next.role == "host", next.participantID == "host" else { return }
        sessionClient = client
        persist(SavedSession(server: personal.baseURL, sessionID: next.sessionID, participantID: "host", role: "host"))
        attach(next, player: player, explicitlyListen: false)
        await refreshCatalog()
    }
    private func attach(_ next: AuxState, player: PlayerController, explicitlyListen: Bool) {
        personalPlayer = player
        let selectedHost = next.role == "host" && next.hostDeviceID == player.deviceID
        let inherited = player.detachForAux(preserveAudio: selectedHost)
        if selectedHost, inherited?.fingerprint == next.current?.track.fingerprint {
            audio = inherited?.player; audioFingerprint = inherited?.fingerprint
        } else { inherited?.player.pause() }
        listening = selectedHost || (next.mode == .listenTogether && explicitlyListen)
        player.auxTransport = { [weak self] kind in Task { await self?.command(kind) } }
        configureInterruptions()
        apply(next)
        generation += 1
        let currentGeneration = generation
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
                await self.refresh()
            }
        }
    }
    func refresh() async {
        guard let state, let sessionClient else { return }
        guard state.expiresAt > Int64(Date().timeIntervalSince1970) else { clear(); issue = "This Aux session has expired."; return }
        do { apply(try await sessionClient.state(state.sessionID)); issue = "" }
        catch { handle(error) }
    }
    func refreshCatalog() async {
        guard let state, let sessionClient else { return }
        do { catalog = try await sessionClient.catalog(state.sessionID) }
        catch { handle(error) }
    }
    func command(_ kind: String, fingerprint: String? = nil, entryID: String? = nil, entryIDs: [String]? = nil) async {
        guard !busy, let state, let sessionClient else { return }
        let kind = kind == "toggle" ? (state.status == "playing" ? "pause" : "resume") : kind
        busy = true; defer { busy = false }
        do {
            let revision = ["next", "reorder"].contains(kind) ? state.revision : nil
            apply(try await sessionClient.command(state.sessionID, kind: kind, revision: revision, fingerprint: fingerprint, entryID: entryID, entryIDs: entryIDs))
            issue = ""
        } catch {
            if case CodecClientError.httpStatus(409, _) = error {
                await refresh(); issue = "The queue changed. Review it and try your action again."
            } else { handle(error) }
        }
    }
    func leaveOrEnd() async {
        guard let state, let sessionClient else {
            if let data = UserDefaults.standard.data(forKey: storageKey), let saved = try? JSONDecoder().decode(SavedSession.self, from: data), saved.role == "guest" {
                let client = makeClient(saved.server, CredentialStore.read("aux-participant"))
                clear()
                try? await client.delete(saved.sessionID, suffix: "/members/\(saved.participantID)")
            } else { issue = "Reconnect to manage your hosted Aux session." }
            return
        }
        busy = true; defer { busy = false }
        do {
            try await sessionClient.delete(state.sessionID, suffix: isGuest ? "/members/\(state.participantID)" : "")
            clear()
        } catch {
            // Leaving locally always removes the credential and stops this listener.
            if isGuest { clear() } else { handle(error) }
        }
    }
    func remove(_ member: AuxMember) async {
        guard let state, let sessionClient else { return }
        do { try await sessionClient.delete(state.sessionID, suffix: "/members/\(member.id)"); await refresh() }
        catch { handle(error) }
    }
    func revokeInvite() async {
        guard let state, let sessionClient else { return }
        do { try await sessionClient.delete(state.sessionID, suffix: "/invite"); inviteSecret = ""; CredentialStore.write("", account: "aux-invitation") }
        catch { handle(error) }
    }
    func renewInvite() async {
        guard let state, let sessionClient else { return }
        do { inviteSecret = try await sessionClient.rotateInvite(state.sessionID); CredentialStore.write(inviteSecret, account: "aux-invitation") }
        catch { handle(error) }
    }
    func listen() {
        guard let state, state.mode == .listenTogether || state.hostDeviceID == personalPlayer?.deviceID else { return }
        interrupted = false; listening = true; syncAudio()
    }
    func stopListening() { listening = false; audio?.pause() }
    private func apply(_ next: AuxState) {
        guard next.schema == "codec.aux.v2" else { clear(); return }
        if let previous = state, previous.sessionID == next.sessionID {
            guard next.revision > previous.revision || (next.revision == previous.revision && next.serverTimeMS >= previous.serverTimeMS) else { return }
        }
        state = next; receivedAt = .now
        syncAudio()
    }
    private func syncAudio() {
        guard listening, !interrupted, let state, let sessionClient else { audio?.pause(); return }
        guard state.mode == .listenTogether || (state.role == "host" && state.hostDeviceID == personalPlayer?.deviceID) else { audio?.pause(); return }
        guard let current = state.current else { audio?.pause(); return }
        guard let mediaRequest = sessionClient.mediaRequest(for: current.track, sessionID: state.sessionID, mediaToken: state.mediaToken), let url = mediaRequest.url else { audio?.pause(); issue = "The shared media address is invalid."; return }
        do { try PlayerController.activateSystemAudioSession() } catch { audio?.pause(); return }
        if audioFingerprint != current.track.fingerprint || audio == nil {
            audio?.pause()
            let headers = mediaRequest.allHTTPHeaderFields ?? [:]
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            audio = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            audioFingerprint = current.track.fingerprint
        }
        audio?.isMuted = muted
        let elapsed = receivedAt.duration(to: .now).components
        let target = state.position(elapsed: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        let currentTime = audio?.currentTime().seconds ?? 0
        if !currentTime.isFinite || abs(currentTime - target) > 1.25 {
            audio?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if state.status == "playing" { audio?.play() } else { audio?.pause() }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: current.track.title, MPMediaItemPropertyArtist: current.track.artist, MPMediaItemPropertyPlaybackDuration: current.track.durationSeconds, MPNowPlayingInfoPropertyElapsedPlaybackTime: target, MPNowPlayingInfoPropertyPlaybackRate: state.status == "playing" ? 1.0 : 0.0]
    }
    private func configureInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.interrupted = true; self.audio?.pause()
                } else if type == AVAudioSession.InterruptionType.ended.rawValue {
                    self.interrupted = false
                    if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) { await self.refresh() }
                    else { self.stopListening() }
                }
            }
        }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let lost = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            if lost { Task { @MainActor in self?.stopListening() } }
        }
    }
    private func persist(_ saved: SavedSession) { UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: storageKey); hasSavedSession = true }
    private func handle(_ error: Error) {
        if case CodecClientError.httpStatus(let status, _) = error, [401, 403, 404, 410].contains(status) {
            clear(); issue = "This Aux session has ended or your access was removed."
        } else { issue = "Aux is reconnecting. Shared controls will be available when the connection returns." }
    }
    private func clear() {
        generation += 1; polling?.cancel(); polling = nil
        audio?.pause(); audio = nil; audioFingerprint = nil
        listening = false; state = nil; catalog = []; sessionClient = nil; inviteSecret = ""
        membership = [:]; saveMessages = [:]; operations = [:]
        personalPlayer?.auxTransport = nil
        UserDefaults.standard.removeObject(forKey: storageKey)
        hasSavedSession = false
        CredentialStore.write("", account: "aux-participant"); CredentialStore.write("", account: "aux-invitation")
    }
    func checkMembership(_ track: AuxTrack, personal: CodecClient?) async {
        guard let personal else { membership[track.fingerprint] = "disconnected"; return }
        do { membership[track.fingerprint] = try await makeClient(personal.baseURL, personal.token).membership(track.fingerprint).status }
        catch { membership[track.fingerprint] = "unknown" }
    }
    func contribute(_ track: CodecTrack, personal: CodecClient, allowCopy: Bool) async {
        guard let state, let sessionClient, state.allowContributions else { return }
        busy = true; defer { busy = false }
        do {
            let source = makeClient(personal.baseURL, personal.token)
            let grant = try await source.grant(fingerprint: track.fingerprint, sessionID: state.sessionID, sessionOrigin: sessionClient.origin, allowCopy: allowCopy)
            apply(try await sessionClient.command(state.sessionID, kind: "append", fingerprint: track.fingerprint, grant: grant))
            await refreshCatalog()
        } catch { issue = "Couldn’t share this song. Your library and the shared queue are unchanged." }
    }
    func save(_ track: AuxTrack, personal: CodecClient, playlistID: String?) async {
        guard let state, let sessionClient, !saving.contains(track.fingerprint) else { return }
        let key = personal.baseURL.absoluteString + ":" + track.fingerprint + ":" + (playlistID ?? "library")
        saving.insert(track.fingerprint); saveMessages[track.fingerprint] = "Saving…"
        defer { saving.remove(track.fingerprint) }
        do {
            let destination = makeClient(personal.baseURL, personal.token)
            let existing = try await destination.membership(track.fingerprint)
            if existing.status == "present" {
                if let playlistID { try await destination.addMembershipToPlaylist(fingerprint: track.fingerprint, playlistID: playlistID) }
            } else {
                let attempt: SaveAttempt
                if let existing = operations[key] { attempt = existing }
                else {
                    let grant = try await sessionClient.copyGrant(state.sessionID, fingerprint: track.fingerprint, destinationOrigin: destination.origin)
                    attempt = SaveAttempt(operationID: UUID().uuidString, grant: grant)
                    operations[key] = attempt
                }
                let result = try await destination.transfer(operationID: attempt.operationID, grant: attempt.grant, sessionID: state.sessionID, sessionOrigin: sessionClient.origin, playlistID: playlistID)
                guard result.status != "playlist_failed" else { throw CodecClientError.invalidResponse }
            }
            membership[track.fingerprint] = "present"
            saveMessages[track.fingerprint] = playlistID == nil ? "Saved to your library" : "Added to your playlist"
        } catch { saveMessages[track.fingerprint] = "Couldn’t save · Retry" }
    }
}
