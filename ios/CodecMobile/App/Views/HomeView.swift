import SwiftUI

struct HomeView: View {
    @Environment(\.codecTheme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player

    @State private var showSettings = false
    @State private var showThemePicker = false

    private let grid = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Faceplate badge.
                    Text("Codec")
                        .font(.system(size: 40, weight: .black))
                        .tracking(-1)
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 20)

                    if app.connection == .offline {
                        Label("Offline — playing downloads and cache", systemImage: "wifi.slash")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(theme.accentText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(theme.accent)
                            .clipShape(Capsule())
                            .padding(.horizontal, 20)
                    }

                    if !app.userPlaylists.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("Playlists")
                                .padding(.horizontal, 20)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(app.userPlaylists) { playlist in
                                        NavigationLink {
                                            PlaylistDetailView(playlistID: playlist.id)
                                        } label: {
                                            PlaylistCard(
                                                playlist: playlist,
                                                cover: app.tracks(in: playlist).first
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("Recently added")
                            .padding(.horizontal, 20)

                        LazyVGrid(columns: grid, spacing: 18) {
                            ForEach(app.recentItems) { item in
                                switch item {
                                case .album(let album, let cover):
                                    NavigationLink {
                                        TrackListView(title: album.name, tracks: app.tracks(inAlbum: album))
                                    } label: {
                                        AlbumTile(album: album, cover: cover)
                                    }
                                    .buttonStyle(.plain)
                                case .single(let track):
                                    Button {
                                        if player.currentTrack?.id == track.id {
                                            player.togglePlayback()
                                        } else {
                                            player.play(track, from: app.recentlyAdded)
                                        }
                                    } label: {
                                        RecentTile(track: track)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .background(theme.bg)
            .refreshable {
                await app.refresh()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showThemePicker = true
                    } label: {
                        Image(systemName: "paintpalette")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "server.rack")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                ServerSettingsView()
            }
            .sheet(isPresented: $showThemePicker) {
                ThemePickerView()
            }
        }
    }
}

private struct PlaylistCard: View {
    @Environment(\.codecTheme) private var theme

    let playlist: CodecPlaylist
    let cover: CodecTrack?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(track: cover, size: 128, cornerRadius: 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(theme.border, lineWidth: 1)
                )

            Text(playlist.name)
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(theme.text)
                .lineLimit(1)

            Text("\(playlist.trackIDs.count) songs")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.subtle)
        }
        .frame(width: 128, alignment: .leading)
    }
}

private struct AlbumTile: View {
    @Environment(\.codecTheme) private var theme

    let album: CodecAlbumSummary
    let cover: CodecTrack?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                ArtworkView(track: cover, size: proxy.size.width, cornerRadius: 10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(theme.border, lineWidth: 1)
                    )
            }
            .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: 1) {
                Text(album.name)
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text("Album · \(album.artist)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }
        }
    }
}

private struct RecentTile: View {
    @Environment(\.codecTheme) private var theme
    @Environment(PlayerController.self) private var player

    let track: CodecTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                ArtworkView(track: track, size: proxy.size.width, cornerRadius: 10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(theme.border, lineWidth: 1)
                    )
            }
            .aspectRatio(1, contentMode: .fit)

            HStack(spacing: 5) {
                if player.currentTrack?.id == track.id {
                    Image(systemName: "waveform")
                        .font(.caption2)
                        .foregroundStyle(theme.accent)
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(player.currentTrack?.id == track.id ? theme.accent : theme.text)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct ServerSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var app = app

        NavigationStack {
            Form {
                Section("Sync server") {
                    TextField("http://192.168.1.20:8787", text: $app.serverURLString)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    SecureField("Auth token (optional)", text: $app.token)
                }

                Section {
                    Button("Reconnect") {
                        Task {
                            await app.connect()
                            app.syncPlayer(player)
                            dismiss()
                        }
                    }
                    Button("Disconnect", role: .destructive) {
                        app.disconnect()
                        app.syncPlayer(player)
                        dismiss()
                    }
                } footer: {
                    Text(app.errorMessage.isEmpty ? "Status: \(statusText)" : app.errorMessage)
                }
            }
            .navigationTitle("Server")
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

    private var statusText: String {
        switch app.connection {
        case .connected: return "connected"
        case .connecting: return "connecting…"
        case .offline: return "offline (cached library)"
        case .disconnected: return "not connected"
        }
    }
}
