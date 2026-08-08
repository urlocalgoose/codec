import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player

    @State private var showSettings = false

    private let grid = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if app.connection == .offline {
                        Label("Offline — playing downloads", systemImage: "wifi.slash")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                    }

                    if !app.userPlaylists.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Playlists")
                                .font(.title3)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 20)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(app.userPlaylists) { playlist in
                                        NavigationLink {
                                            TrackListView(title: playlist.name, tracks: app.tracks(in: playlist))
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
                        Text("Recently Added")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 20)

                        LazyVGrid(columns: grid, spacing: 18) {
                            ForEach(app.recentlyAdded) { track in
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
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .refreshable {
                await app.refresh()
            }
            .navigationTitle("Codec")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                ServerSettingsView()
            }
        }
    }
}

private struct PlaylistCard: View {
    let playlist: LoudPlaylist
    let cover: LoudTrack?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(track: cover, size: 128, cornerRadius: 10)

            Text(playlist.name)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)

            Text("\(playlist.trackIDs.count) songs")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 128, alignment: .leading)
    }
}

private struct RecentTile: View {
    @Environment(PlayerController.self) private var player

    let track: LoudTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                ArtworkView(track: track, size: proxy.size.width, cornerRadius: 10)
            }
            .aspectRatio(1, contentMode: .fit)

            HStack(spacing: 5) {
                if player.currentTrack?.id == track.id {
                    Image(systemName: "waveform")
                        .font(.caption2)
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.footnote)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
