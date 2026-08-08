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
                        row("Liked Songs", systemImage: "heart", count: app.likedTracks.count)
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
                        row("Downloaded", systemImage: "arrow.down.circle", count: downloads.downloadedCount)
                    }
                }

                if !app.userPlaylists.isEmpty {
                    Section("Playlists") {
                        ForEach(app.userPlaylists) { playlist in
                            NavigationLink {
                                TrackListView(title: playlist.name, tracks: app.tracks(in: playlist))
                            } label: {
                                row(playlist.name, systemImage: "music.note.list", count: playlist.trackIDs.count)
                            }
                        }
                    }
                }

                if let albums = app.library?.albums, !albums.isEmpty {
                    Section("Albums") {
                        ForEach(albums) { album in
                            NavigationLink {
                                TrackListView(title: album.name, tracks: app.tracks(inAlbum: album))
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(album.name)
                                        .lineLimit(1)
                                    Text(album.artist)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }

                if let artists = app.library?.artists, !artists.isEmpty {
                    Section("Artists") {
                        ForEach(artists) { artist in
                            NavigationLink {
                                TrackListView(title: artist.name, tracks: app.tracks(byArtist: artist))
                            } label: {
                                row(artist.name, systemImage: "music.mic", count: artist.trackCount)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Library")
        }
    }

    private func row(_ title: String, systemImage: String, count: Int) -> some View {
        HStack {
            Label {
                Text(title)
                    .lineLimit(1)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(count)")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }
}
