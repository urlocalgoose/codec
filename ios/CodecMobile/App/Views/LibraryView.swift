import SwiftUI

struct LibraryView: View {
    @Environment(\.codecTheme) private var theme
    @Environment(AppModel.self) private var app

    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""
    @State private var playlistToDelete: CodecPlaylist?
    #if DEBUG
    @Environment(DownloadStore.self) private var captureDownloads
    @State private var showCaptureDownloads = false
    #endif

    var body: some View {
        NavigationStack {
            List {
                playlistSection

                LibraryCollectionsSection()
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            .modifier(MiniPlayerInset())
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            #if DEBUG
            .navigationDestination(isPresented: $showCaptureDownloads) {
                TrackListView(title: "Downloaded", tracks: captureDownloads.downloadedTracks(in: app.tracks),
                              showsDownloadAll: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("CodecCaptureDownloads"))) { event in
                guard ProcessInfo.processInfo.environment["CODEC_CAPTURE_CONTROL"] != nil else { return }
                showCaptureDownloads = event.object as? Bool ?? false
            }
            #endif
            .toolbar {
                ScreenHeader(title: "Library")
                // Keep "Library" as the back label on pushed collections.
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1)
                        .accessibilityHidden(true)
                }
            }
            .alert("New Playlist", isPresented: $showNewPlaylist) {
                TextField("Name", text: $newPlaylistName)
                Button("Create") {
                    guard !app.activeAuxIsGuest else { return }
                    app.createPlaylist(named: newPlaylistName)
                    newPlaylistName = ""
                }
                .disabled(app.activeAuxIsGuest || newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { newPlaylistName = "" }
            }
            .confirmationDialog("Delete Playlist?", isPresented: Binding(
                get: { playlistToDelete != nil },
                set: { if !$0 { playlistToDelete = nil } }
            ), titleVisibility: .visible, presenting: playlistToDelete) { playlist in
                Button("Delete Playlist", role: .destructive) {
                    defer { playlistToDelete = nil }
                    guard !app.activeAuxIsGuest, let current = app.playlist(withID: playlist.id) else { return }
                    app.deletePlaylist(current)
                }
                Button("Cancel", role: .cancel) { playlistToDelete = nil }
            } message: { playlist in
                Text("Delete “\(playlist.name)”? Its songs will stay in your library.")
            }
            .onChange(of: app.activeAuxIsGuest) { _, isGuest in
                if isGuest {
                    showNewPlaylist = false
                    newPlaylistName = ""
                    playlistToDelete = nil
                }
            }
        }
    }

    private var playlistSection: some View {
        Section {
            if app.userPlaylists.isEmpty {
                if app.activeAuxIsGuest {
                    Label("No playlists", systemImage: "music.note.list")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(theme.subtle)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .listRowBackground(theme.panel)
                } else {
                    Button {
                        showNewPlaylist = true
                    } label: {
                        Label("Make your first playlist", systemImage: "music.note.list")
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(theme.accent)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    }
                    .listRowBackground(theme.panel)
                }
            } else {
                ForEach(app.userPlaylists) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlistID: playlist.id)
                    } label: {
                        HStack(spacing: 12) {
                            PlaylistArtworkView(playlist: playlist, size: 44, cornerRadius: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                    .font(.system(size: 15, weight: .heavy))
                                    .foregroundStyle(theme.text)
                                    .lineLimit(1)
                                Text("\(playlist.trackIDs.count) \(playlist.trackIDs.count == 1 ? "song" : "songs")")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(theme.subtle)
                            }
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    .listRowBackground(theme.panel)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !app.activeAuxIsGuest {
                            // Confirmation owns the destructive action, so
                            // the row doesn't vanish before the user confirms.
                            Button {
                                playlistToDelete = playlist
                            } label: {
                                Label("Delete Playlist", systemImage: "trash")
                            }
                            .tint(theme.danger)
                        }
                    }
                    .contextMenu {
                        if !app.activeAuxIsGuest {
                            Button(role: .destructive) {
                                playlistToDelete = playlist
                            } label: {
                                Label("Delete Playlist", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        } header: {
            HStack {
                SectionLabel("Playlists")
                Spacer()
                if !app.activeAuxIsGuest {
                    Button {
                        showNewPlaylist = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(theme.accent)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New Playlist")
                }
            }
        }
    }
}

/// Download progress only invalidates these shortcuts, rather than rebuilding
/// every playlist row and its artwork in the parent Library view.
private struct LibraryCollectionsSection: View {
    @Environment(\.codecTheme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(DownloadStore.self) private var downloads

    var body: some View {
        Section {
            NavigationLink {
                TrackListView(title: "Liked Songs", tracks: app.likedTracks,
                              playlistID: app.library?.playlists.first(where: \.isLiked)?.id)
            } label: {
                row("Liked Songs", systemImage: "heart.fill", count: app.likedTracks.count)
            }
            NavigationLink {
                TrackListView(title: "Songs", tracks: app.tracks)
            } label: {
                row("Songs", systemImage: "music.note", count: app.tracks.count)
            }
            NavigationLink {
                TrackListView(
                    title: "Downloaded",
                    tracks: downloads.downloadedTracks(in: app.tracks),
                    showsDownloadAll: false
                )
            } label: {
                row("Downloaded", systemImage: "arrow.down.circle.fill", count: downloads.downloadedCount)
            }
        }
        .listRowBackground(theme.panel)
    }

    private func row(_ title: String, systemImage: String, count: Int) -> some View {
        HStack {
            Label {
                Text(title)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(theme.accent)
            }

            Spacer()

            Text("\(count)")
                .font(.footnote)
                .foregroundStyle(theme.subtle)
                .monospacedDigit()
        }
    }
}
