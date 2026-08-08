import SwiftUI

struct LibraryView: View {
    @Environment(\.loudTheme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(DownloadStore.self) private var downloads

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        TrackListView(title: "Liked Songs", tracks: app.likedTracks)
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

                if !app.userPlaylists.isEmpty {
                    Section {
                        ForEach(app.userPlaylists) { playlist in
                            NavigationLink {
                                TrackListView(title: playlist.name, tracks: app.tracks(in: playlist))
                            } label: {
                                row(playlist.name, systemImage: "music.note.list", count: playlist.trackIDs.count)
                            }
                        }
                    } header: {
                        SectionLabel("Playlists")
                    }
                    .listRowBackground(theme.panel)
                }

                if let albums = app.library?.albums, !albums.isEmpty {
                    Section {
                        ForEach(albums) { album in
                            NavigationLink {
                                TrackListView(title: album.name, tracks: app.tracks(inAlbum: album))
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(album.name)
                                        .font(.system(size: 15, weight: .heavy))
                                        .foregroundStyle(theme.text)
                                        .lineLimit(1)
                                    Text(album.artist)
                                        .font(.footnote)
                                        .foregroundStyle(theme.muted)
                                        .lineLimit(1)
                                }
                            }
                        }
                    } header: {
                        SectionLabel("Albums")
                    }
                    .listRowBackground(theme.panel)
                }

                if let artists = app.library?.artists, !artists.isEmpty {
                    Section {
                        ForEach(artists) { artist in
                            NavigationLink {
                                TrackListView(title: artist.name, tracks: app.tracks(byArtist: artist))
                            } label: {
                                row(artist.name, systemImage: "music.mic", count: artist.trackCount)
                            }
                        }
                    } header: {
                        SectionLabel("Artists")
                    }
                    .listRowBackground(theme.panel)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            .navigationTitle("Library")
        }
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
