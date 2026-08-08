import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(DownloadStore.self) private var downloads

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        TrackListView(title: "Liked Songs", tracks: app.likedTracks)
                    } label: {
                        row(icon: "heart.fill", title: "Liked Songs", detail: "\(app.likedTracks.count)")
                    }

                    NavigationLink {
                        TrackListView(title: "All Songs", tracks: app.tracks)
                    } label: {
                        row(icon: "music.note", title: "All Songs", detail: "\(app.tracks.count)")
                    }

                    NavigationLink {
                        TrackListView(
                            title: "Downloads",
                            tracks: downloads.downloadedTracks(in: app.tracks),
                            showsDownloadAll: false
                        )
                    } label: {
                        row(icon: "arrow.down.circle.fill", title: "Downloads", detail: "\(downloads.downloadedCount)")
                    }
                }
                .listRowBackground(LoudColor.panel)

                if !app.userPlaylists.isEmpty {
                    Section("Playlists") {
                        ForEach(app.userPlaylists) { playlist in
                            NavigationLink {
                                TrackListView(title: playlist.name, tracks: app.tracks(in: playlist))
                            } label: {
                                row(icon: "music.note.list", title: playlist.name, detail: "\(playlist.trackIDs.count)")
                            }
                        }
                    }
                    .listRowBackground(LoudColor.panel)
                }

                if let albums = app.library?.albums, !albums.isEmpty {
                    Section("Albums") {
                        ForEach(albums) { album in
                            NavigationLink {
                                TrackListView(title: album.name, tracks: app.tracks(inAlbum: album))
                            } label: {
                                row(icon: "opticaldisc", title: album.name, detail: album.artist)
                            }
                        }
                    }
                    .listRowBackground(LoudColor.panel)
                }

                if let artists = app.library?.artists, !artists.isEmpty {
                    Section("Artists") {
                        ForEach(artists) { artist in
                            NavigationLink {
                                TrackListView(title: artist.name, tracks: app.tracks(byArtist: artist))
                            } label: {
                                row(icon: "person.fill", title: artist.name, detail: "\(artist.trackCount)")
                            }
                        }
                    }
                    .listRowBackground(LoudColor.panel)
                }
            }
            .scrollContentBackground(.hidden)
            .background(LoudColor.bg)
            .navigationTitle("Library")
            .safeAreaPadding(.bottom, 60)
        }
    }

    private func row(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(LoudColor.accent)
                .frame(width: 26)

            Text(title)
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(LoudColor.text)
                .lineLimit(1)

            Spacer(minLength: 10)

            Text(detail)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LoudColor.subtle)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}
