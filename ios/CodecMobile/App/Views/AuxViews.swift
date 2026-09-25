import SwiftUI

struct AuxJoinView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(\.codecTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        @Bindable var aux = app.aux
        NavigationStack {
            Form {
                if let invitation = aux.invitation {
                    Section {
                        Label(invitation.hostName, systemImage: "person.wave.2")
                        Text(invitation.mode.title).font(.headline)
                        Text(invitation.mode == .sharedSpeaker ? "Music plays on the host’s selected speaker." : "Listen on your device with everyone in the session.")
                        Text("Everyone can pause, resume, skip, add songs, and rearrange the upcoming queue.")
                            .foregroundStyle(theme.muted)
                    }
                    Section {
                        TextField("Your name", text: $aux.displayName)
                            .textContentType(.nickname)
                        Button(invitation.mode == .listenTogether ? "Join and listen" : "Join Aux") {
                            Task { await aux.join(player: player) }
                        }
                        .disabled(aux.busy || aux.isActive)
                    } footer: {
                        Text("Your personal server connection stays separate. You can leave at any time.")
                    }
                } else if aux.busy { ProgressView("Checking invitation…") }
                if !aux.issue.isEmpty { Text(aux.issue).foregroundStyle(theme.danger) }
            }
            .scrollContentBackground(.hidden).background(theme.bg)
            .navigationTitle("Join Aux")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { aux.pendingInvitation = nil; dismiss() } } }
            .task { await aux.inspectInvitation() }
        }
    }
}

struct AuxCreateView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(\.codecTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var mode: AuxMode = .sharedSpeaker
    @State private var selected = Set<String>()
    @State private var allowSaves = false
    @State private var allowContributions = false
    @State private var search = ""
    private var visibleTracks: [CodecTrack] { app.tracks.filter { search.isEmpty || ($0.title + " " + $0.artist).localizedCaseInsensitiveContains(search) } }
    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    Picker("Mode", selection: $mode) { ForEach(AuxMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Text(mode == .sharedSpeaker ? "The current output keeps playing. Guests control that speaker." : "The current output keeps playing. Guests listen independently on their devices.")
                        .font(.footnote).foregroundStyle(theme.muted)
                }
                Section {
                    Toggle("Allow others to save songs I share", isOn: $allowSaves)
                    Toggle("Allow songs from personal servers", isOn: $allowContributions)
                } footer: { Text("Saving creates a permanent copy on a member’s own server. Each contributor chooses whether their songs can be saved.") }
                if !app.userPlaylists.isEmpty {
                    Section("Select a playlist") {
                        ForEach(app.userPlaylists) { playlist in
                            Button(playlist.name) { selected = Set(app.tracks(in: playlist).map(\.fingerprint)); includeCurrent() }
                        }
                    }
                }
                Section("Shared songs · \(selected.count)") {
                    TextField("Find a song", text: $search)
                    ForEach(visibleTracks) { track in
                        Button {
                            if selected.contains(track.fingerprint) { selected.remove(track.fingerprint) }
                            else { selected.insert(track.fingerprint) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) { Text(track.title).foregroundStyle(theme.text); Text(track.artist).font(.caption).foregroundStyle(theme.muted) }
                                Spacer()
                                Image(systemName: selected.contains(track.fingerprint) ? "checkmark.circle.fill" : "circle")
                            }
                        }
                        .disabled(track.fingerprint == player.currentTrack?.fingerprint)
                    }
                }
                if !app.aux.issue.isEmpty { Text(app.aux.issue).foregroundStyle(theme.danger) }
            }
            .scrollContentBackground(.hidden).background(theme.bg)
            .navigationTitle("Start Aux")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(app.aux.busy ? "Starting…" : "Start") {
                        guard let client = app.client else { return }
                        Task { await app.aux.create(personal: client, player: player, mode: mode, tracks: Array(selected), allowSaves: allowSaves, allowContributions: allowContributions) }
                    }.disabled(selected.isEmpty || selected.count > 500 || app.aux.busy)
                }
            }
            .onAppear { includeCurrent() }
        }
    }
    private func includeCurrent() { if let fingerprint = player.currentTrack?.fingerprint { selected.insert(fingerprint) } }
}

struct AuxSessionView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(\.codecTheme) private var theme
    @State private var showPicker = false
    @State private var saveTrack: AuxTrack?
    @State private var showPersonalConnection = false
    var body: some View {
        @Bindable var aux = app.aux
        NavigationStack {
            List {
                if let state = aux.state {
                    Section {
                        Text(state.hostName).font(.subheadline).foregroundStyle(theme.muted)
                        Text(state.mode.title).font(.headline)
                        if let current = state.current {
                            HStack(spacing: 14) {
                                AuxArtworkView(track: current.track, size: 72)
                                VStack(alignment: .leading, spacing: 5) { Text(current.track.title).font(.title3.bold()); Text(current.track.artist).foregroundStyle(theme.muted) }
                                Spacer()
                                saveButton(current.track)
                            }
                        } else { Text("Add a song to get started.").foregroundStyle(theme.muted) }
                        HStack(spacing: 28) {
                            Button { Task { await aux.command(state.status == "playing" ? "pause" : "resume") } } label: {
                                Label(state.status == "playing" ? "Pause for everyone" : "Resume for everyone", systemImage: state.status == "playing" ? "pause.fill" : "play.fill")
                            }
                            Button { Task { await aux.command("next") } } label: { Label("Skip", systemImage: "forward.end.fill") }
                        }.buttonStyle(.borderless).disabled(aux.busy)
                    }
                    if state.mode == .listenTogether || state.hostDeviceID == player.deviceID {
                        Section("On this device") {
                            if aux.listening {
                                Toggle("Mute this device", isOn: $aux.muted)
                                HStack(spacing: 12) {
                                    Image(systemName: "speaker.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(theme.subtle)
                                    SystemVolumeSlider(tint: theme.accent)
                                        .frame(height: 30)
                                    Image(systemName: "speaker.wave.3.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(theme.subtle)
                                }
                                Button("Stop listening on this device") { aux.stopListening() }
                            } else { Button("Listen on this device") { aux.listen() } }
                        }
                    }
                    Section {
                        ForEach(state.queue) { entry in
                            HStack {
                                AuxArtworkView(track: entry.track, size: 42)
                                VStack(alignment: .leading) { Text(entry.track.title); Text(entry.track.artist).font(.caption).foregroundStyle(theme.muted) }
                                Spacer()
                                saveButton(entry.track)
                                if state.role == "host" || entry.participantID == state.participantID {
                                    Button { Task { await aux.command("remove", entryID: entry.id) } } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.borderless).accessibilityLabel("Remove \(entry.track.title) from queue")
                                }
                            }
                        }
                        .onMove { offsets, destination in
                            var ids = state.queue.map(\.id); ids.move(fromOffsets: offsets, toOffset: destination)
                            Task { await aux.command("reorder", entryIDs: ids) }
                        }
                        Button { showPicker = true } label: { Label("Add songs", systemImage: "plus") }
                    } header: { HStack { Text("Up next"); Spacer(); EditButton() } }
                    if state.role == "host" {
                        Section("Invitation") {
                            if let link = aux.link {
                                ShareLink(item: link) { Label("Share invitation", systemImage: "square.and.arrow.up") }
                                Button("Revoke invitation", role: .destructive) { Task { await aux.revokeInvite() } }
                            } else { Text("No active invitation").foregroundStyle(theme.muted) }
                            Button("Create a new invitation") { Task { await aux.renewInvite() } }
                        }
                        Section("Participants") {
                            ForEach(state.members ?? []) { member in
                                HStack { Text(member.displayName); Spacer(); Button("Remove", role: .destructive) { Task { await aux.remove(member) } }.buttonStyle(.borderless) }
                            }
                        }
                    }
                    if !aux.issue.isEmpty { Text(aux.issue).foregroundStyle(theme.danger) }
                    Section { Button(aux.isGuest ? "Leave Aux" : "End Aux", role: .destructive) { Task { await aux.leaveOrEnd(); app.syncPlayer(player) } } }
                } else if aux.requiresRestore {
                    Section {
                        Text("Reconnecting to Aux").font(.headline)
                        Text(aux.issue.isEmpty ? "Checking your saved participation before resuming." : aux.issue)
                        Button("Retry") { Task { await aux.restore(personal: app.client, player: player) } }.disabled(aux.validating)
                        Button("Leave Aux", role: .destructive) { Task { await aux.leaveOrEnd(); app.syncPlayer(player) } }
                    }
                }
            }
            .scrollContentBackground(.hidden).background(theme.bg)
            .navigationTitle("Aux")
            .sheet(isPresented: $showPicker) { AuxSongPicker() }
            .sheet(item: $saveTrack) { AuxSaveView(track: $0) }
            .sheet(isPresented: $showPersonalConnection) { NavigationStack { ConnectView().toolbar { Button("Done") { showPersonalConnection = false } } } }
        }
    }
    private func saveButton(_ track: AuxTrack) -> some View {
        Button {
            if app.client == nil { showPersonalConnection = true }
            else { saveTrack = track }
        } label: { Image(systemName: app.aux.membership[track.fingerprint] == "present" ? "checkmark.circle" : "plus.circle") }
            .buttonStyle(.borderless)
            .accessibilityLabel(app.aux.membership[track.fingerprint] == "present" ? "In your library. Add \(track.title) to a playlist" : "Save \(track.title) to your library")
            .task(id: track.fingerprint) { await app.aux.checkMembership(track, personal: app.client) }
    }
}

struct AuxSongPicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var personal = false
    @State private var search = ""
    @State private var allowCopy = false
    var body: some View {
        NavigationStack {
            List {
                Picker("Catalog", selection: $personal) { Text("Aux").tag(false); Text("Your library").tag(true) }.pickerStyle(.segmented)
                if personal {
                    if app.client == nil { Text("Connect your own server from a song’s library button to share your songs.") }
                    else if app.aux.state?.allowContributions != true { Text("The host hasn’t enabled songs from personal servers.") }
                    else {
                        Toggle("Allow others to save songs I share", isOn: $allowCopy)
                        ForEach(app.tracks.filter { search.isEmpty || ($0.title + " " + $0.artist).localizedCaseInsensitiveContains(search) }) { track in
                            Button { if let client = app.client { Task { await app.aux.contribute(track, personal: client, allowCopy: allowCopy) } } } label: { song(track.title, artist: track.artist) }
                        }
                    }
                } else {
                    ForEach(app.aux.catalog.filter { search.isEmpty || ($0.title + " " + $0.artist).localizedCaseInsensitiveContains(search) }) { track in
                        Button { Task { await app.aux.command("append", fingerprint: track.fingerprint) } } label: { song(track.title, artist: track.artist) }
                    }
                }
                if !app.aux.issue.isEmpty { Text(app.aux.issue) }
            }
            .disabled(app.aux.busy)
            .searchable(text: $search).navigationTitle("Add songs")
            .toolbar { Button("Done") { dismiss() } }
            .task { await app.aux.refreshCatalog() }
        }
    }
    private func song(_ title: String, artist: String) -> some View {
        HStack { VStack(alignment: .leading) { Text(title); Text(artist).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "text.badge.plus") }
    }
}

struct AuxSaveView: View {
    let track: AuxTrack
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(track.title).font(.headline)
                    Text("Destination: \(app.client?.baseURL.host ?? "your server")").font(.footnote).foregroundStyle(.secondary)
                    Text(status)
                    if let message = app.aux.saveMessages[track.fingerprint] { Text(message) }
                }
                if let client = app.client {
                    Section {
                        Button(app.aux.membership[track.fingerprint] == "present" ? "In your library" : "Save to your library") { Task { await app.aux.save(track, personal: client, playlistID: nil) } }
                            .disabled(app.aux.membership[track.fingerprint] == "present" || !canSave)
                        if !canSave { Button("Check your library") { Task { await app.aux.checkMembership(track, personal: client) } } }
                    }
                    Section("Add to your playlist") {
                        ForEach(app.userPlaylists.filter { !$0.isLiked }) { playlist in
                            Button(playlist.name) { Task { await app.aux.save(track, personal: client, playlistID: playlist.id) } }.disabled(!canSave)
                        }
                    }
                }
            }
            .navigationTitle("Your library")
            .toolbar { Button("Done") { dismiss() } }
            .task { await app.aux.checkMembership(track, personal: app.client) }
        }
    }
    private var canSave: Bool { ["present", "absent", "repair"].contains(app.aux.membership[track.fingerprint] ?? "") && app.aux.saveMessages[track.fingerprint] != "Saving…" }
    private var status: String {
        switch app.aux.membership[track.fingerprint] {
        case "present": return "In your library"
        case "absent": return "Not in your library. Saving requires the source owner’s permission."
        case "repair": return "Your library has this song but needs its audio restored."
        default: return "Your library’s status is unknown. Check the connection before saving."
        }
    }
}


private struct AuxArtworkView: View {
    let track: AuxTrack
    let size: CGFloat
    @Environment(AppModel.self) private var app
    @Environment(\.codecTheme) private var theme
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?
    private var request: ArtworkRequest? {
        guard let state = app.aux.state, let client = app.aux.sessionClient,
              let url = client.mediaURL(track.artworkURL ?? "", sessionID: state.sessionID) else { return nil }
        let credential = state.mediaToken ?? client.token
        return ArtworkRequest(url: url, authorization: credential.map { "Bearer \($0)" }, pixelSize: Int(size * scale))
    }
    var body: some View {
        ZStack {
            theme.panel2
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "music.note").foregroundStyle(theme.muted) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
        .task(id: request) {
            image = nil
            guard let request else { return }
            let loaded = await ArtworkLoader.shared.image(for: request.url, headers: request.headers, pixelSize: request.pixelSize)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
