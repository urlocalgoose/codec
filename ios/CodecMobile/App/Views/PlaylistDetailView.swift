import PhotosUI
import SwiftUI

/// A user playlist you can actually edit: reorder with drag handles, swipe
/// or edit-mode delete to remove, and an Add Songs sheet fed by the full
/// library.
struct PlaylistDetailView: View {
    @Environment(\.codecTheme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player

    let playlistID: String

    @State private var showAddSongs = false
    @State private var coverItem: PhotosPickerItem?

    private var playlist: CodecPlaylist? {
        app.playlist(withID: playlistID)
    }

    private var tracks: [CodecTrack] {
        playlist.map { app.tracks(in: $0) } ?? []
    }

    var body: some View {
        List {
            CollectionActionHeader(tracks: tracks)

            ForEach(tracks) { track in
                PlayableTrackRow(track: track, collection: tracks)
            }
            .onMove { offsets, destination in
                if let playlist {
                    app.movePlaylistTracks(playlist, from: offsets, to: destination)
                }
            }
            .onDelete { offsets in
                guard let playlist else {
                    return
                }
                let current = tracks
                for index in offsets where index < current.count {
                    app.removeTrack(current[index], from: playlist)
                }
            }

            if tracks.isEmpty {
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
        .navigationTitle(playlist?.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
            ToolbarItem(placement: .topBarTrailing) {
                PhotosPicker(selection: $coverItem, matching: .images) {
                    Image(systemName: "photo")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSongs = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .onChange(of: coverItem) { _, item in
            guard let item else {
                return
            }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await app.setPlaylistCover(playlistID: playlistID, imageData: data)
                }
                coverItem = nil
            }
        }
        .sheet(isPresented: $showAddSongs) {
            AddSongsSheet(playlistID: playlistID)
        }
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
        NavigationStack {
            List(results) { track in
                HStack(spacing: 12) {
                    TrackRow(track: track, showsDownloadState: false)

                    if playlist?.trackIDs.contains(track.id) == true {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(theme.accent)
                    } else {
                        Button {
                            if let playlist {
                                app.addTrack(track, to: playlist)
                            }
                        } label: {
                            Image(systemName: "plus.circle")
                                .foregroundStyle(theme.subtle)
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
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
                        if isMember {
                            app.removeTrack(track, from: playlist)
                        } else {
                            app.addTrack(track, to: playlist)
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
                    app.createPlaylist(named: newPlaylistName, adding: track)
                    newPlaylistName = ""
                }
                Button("Cancel", role: .cancel) {
                    newPlaylistName = ""
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
