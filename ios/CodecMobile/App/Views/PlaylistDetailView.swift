import PhotosUI
import SwiftUI

/// A user playlist you can actually edit: reorder with drag handles, swipe
/// or edit-mode delete to remove, and an Add Songs sheet fed by the full
/// library.
struct PlaylistDetailView: View {
    @Environment(\.codecTheme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss

    let playlistID: String

    @State private var showAddSongs = false
    @State private var coverItem: PhotosPickerItem?
    @State private var showCoverPicker = false
    @State private var showDeleteConfirmation = false
    @State private var editMode: EditMode = .inactive

    private var playlist: CodecPlaylist? {
        app.playlist(withID: playlistID)
    }

    private var canEdit: Bool {
        !app.activeAuxIsGuest && playlist?.isLiked == false
    }

    var body: some View {
        // Resolve playlist membership once for this render; each row shares
        // its ordered playback collection instead of rebuilding it on scroll.
        let displayedPlaylist = playlist
        let displayedTracks = displayedPlaylist.map { app.tracks(in: $0) } ?? []
        let allowsEditing = !app.activeAuxIsGuest && displayedPlaylist?.isLiked == false
        List {
            CollectionActionHeader(tracks: displayedTracks, playlistID: playlistID)

            ForEach(displayedTracks) { track in
                PlayableTrackRow(track: track, collection: displayedTracks, playlistID: playlistID,
                    onRemoveFromPlaylist: allowsEditing ? {
                        guard canEdit, let current = playlist else { return }
                        app.removeTracks([track], from: current)
                    } : nil)
                    .deleteDisabled(!allowsEditing)
                    .moveDisabled(!allowsEditing)
            }
            .onMove { offsets, destination in
                if canEdit, let playlist {
                    app.movePlaylistTracks(playlist, from: offsets, to: destination)
                }
            }
            .onDelete { offsets in
                guard canEdit, let playlist else {
                    return
                }
                let removed = offsets.compactMap { displayedTracks.indices.contains($0) ? displayedTracks[$0] : nil }
                app.removeTracks(removed, from: playlist)
            }

            if displayedTracks.isEmpty {
                ContentUnavailableView(
                    "No Songs",
                    systemImage: "music.note.list",
                    description: Text("Add songs from your library.")
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .modifier(MiniPlayerInset())
        .navigationTitle(displayedPlaylist?.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if allowsEditing {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showCoverPicker = true
                        } label: {
                            Label("Change Artwork", systemImage: "photo")
                        }
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete Playlist", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("Playlist options")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddSongs = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Songs")
                }
            }
        }
        .photosPicker(isPresented: $showCoverPicker, selection: $coverItem, matching: .images)
        .onChange(of: coverItem) { _, item in
            guard canEdit, let item else {
                return
            }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    guard canEdit, !Task.isCancelled else { return }
                    await app.setPlaylistCover(playlistID: playlistID, imageData: data)
                }
                coverItem = nil
            }
        }
        .sheet(isPresented: $showAddSongs) {
            AddSongsSheet(playlistID: playlistID)
        }
        .confirmationDialog("Delete Playlist?", isPresented: $showDeleteConfirmation,
                            titleVisibility: .visible, presenting: playlist) { playlist in
            Button("Delete Playlist", role: .destructive) {
                guard canEdit, let current = app.playlist(withID: playlist.id) else { return }
                app.deletePlaylist(current)
            }
            Button("Cancel", role: .cancel) {}
        } message: { playlist in
            Text("Delete “\(playlist.name)”? Its songs will stay in your library.")
        }
        .onChange(of: playlist == nil) { _, missing in
            if missing { dismiss() }
        }
        .onChange(of: app.activeAuxIsGuest) { _, isGuest in
            if isGuest {
                editMode = .inactive
                showAddSongs = false
                showCoverPicker = false
                showDeleteConfirmation = false
                coverItem = nil
            }
        }
        .environment(\.editMode, $editMode)
    }
}

/// Full library with search; tap the plus to drop a song into the playlist,
/// already-added songs show a checkmark.
struct AddSongsSheet: View {
    @Environment(\.codecTheme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let playlistID: String

    @State private var query = ""

    private var playlist: CodecPlaylist? {
        app.playlist(withID: playlistID)
    }

    private var results: [CodecTrack] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return app.tracks
        }
        return app.searchTracks(trimmed)
    }

    var body: some View {
        let matchingTracks = results
        let displayedPlaylist = playlist
        let memberTrackIDs = Set(displayedPlaylist?.trackIDs ?? [])
        let allowsAdding = !app.activeAuxIsGuest && displayedPlaylist != nil
        NavigationStack {
            List(matchingTracks) { track in
                HStack(spacing: 12) {
                    TrackRow(track: track, showsDownloadState: false)

                    if memberTrackIDs.contains(track.id) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(theme.accent)
                    } else {
                        Button {
                            if !app.activeAuxIsGuest, let playlist {
                                app.addTrack(track, to: playlist)
                            }
                        } label: {
                            Image(systemName: "plus.circle")
                                .foregroundStyle(theme.subtle)
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .disabled(!allowsAdding)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(theme.line)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            .searchable(text: $query, prompt: "Search your library")
            .navigationTitle("Add Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onChange(of: app.activeAuxIsGuest) { _, isGuest in
                if isGuest { dismiss() }
            }
            .onChange(of: playlist == nil) { _, missing in
                if missing { dismiss() }
            }
        }
    }
}

/// Song-first playlist picking (the Spotify move): while listening, pick
/// which playlists this track belongs to. Checkmarks toggle membership.
struct AddToPlaylistSheet: View {
    @Environment(\.codecTheme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let track: CodecTrack

    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""

    var body: some View {
        NavigationStack {
            List {
                Button {
                    showNewPlaylist = true
                } label: {
                    Label("New Playlist", systemImage: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                .listRowBackground(theme.panel)

                ForEach(app.userPlaylists) { playlist in
                    let isMember = playlist.trackIDs.contains(track.id)
                    Button {
                        guard !app.activeAuxIsGuest,
                              let current = app.playlist(withID: playlist.id) else { return }
                        if current.trackIDs.contains(track.id) {
                            app.removeTrack(track, from: current)
                        } else {
                            app.addTrack(track, to: current)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(theme.text)
                                Text("\(playlist.trackIDs.count) songs")
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.subtle)
                            }
                            Spacer()
                            Image(systemName: isMember ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isMember ? theme.accent : theme.subtle)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(theme.panel)
                }

                if app.userPlaylists.isEmpty {
                    Text("No playlists yet — make one.")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.subtle)
                        .listRowBackground(Color.clear)
                }
            }
            .disabled(app.activeAuxIsGuest)
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("New Playlist", isPresented: $showNewPlaylist) {
                TextField("Name", text: $newPlaylistName)
                Button("Create") {
                    guard !app.activeAuxIsGuest else { return }
                    app.createPlaylist(named: newPlaylistName, adding: track)
                    newPlaylistName = ""
                }
                .disabled(app.activeAuxIsGuest || newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {
                    newPlaylistName = ""
                }
            }
            .onChange(of: app.activeAuxIsGuest) { _, isGuest in
                if isGuest {
                    showNewPlaylist = false
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
