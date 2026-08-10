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
                Button {
                    showAddSongs = true
                } label: {
                    Image(systemName: "plus")
                }
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
