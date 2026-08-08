import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player

    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if app.connection == .offline {
                        Label("Offline — playing downloads and cache", systemImage: "wifi.slash")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(LoudColor.accentText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(LoudColor.accent)
                            .clipShape(Capsule())
                            .padding(.horizontal, 16)
                    }

                    if !app.userPlaylists.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("Playlists")
                                .padding(.horizontal, 16)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(app.userPlaylists) { playlist in
                                        NavigationLink {
                                            TrackListView(title: playlist.name, tracks: app.tracks(in: playlist))
                                        } label: {
                                            VStack(alignment: .leading, spacing: 8) {
                                                Image(systemName: "music.note.list")
                                                    .font(.system(size: 18, weight: .bold))
                                                    .foregroundStyle(LoudColor.accent)
                                                Spacer(minLength: 0)
                                                Text(playlist.name)
                                                    .font(.system(size: 14, weight: .heavy))
                                                    .foregroundStyle(LoudColor.text)
                                                    .lineLimit(2)
                                                    .multilineTextAlignment(.leading)
                                                Text("\(playlist.trackIDs.count) tracks")
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundStyle(LoudColor.subtle)
                                            }
                                            .padding(12)
                                            .frame(width: 132, height: 116, alignment: .leading)
                                            .background(LoudColor.panel)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(LoudColor.line, lineWidth: 1)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel("Recently added")
                            .padding(.horizontal, 16)

                        LazyVStack(spacing: 0) {
                            ForEach(app.recentlyAdded) { track in
                                Button {
                                    if player.currentTrack?.id == track.id {
                                        player.togglePlayback()
                                    } else {
                                        player.play(track, from: app.recentlyAdded)
                                    }
                                } label: {
                                    TrackRow(track: track)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 130)
            }
            .background(LoudColor.bg)
            .navigationTitle("Loud")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "server.rack")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await app.refresh()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                ServerSettingsView()
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
                            player.client = app.client
                            dismiss()
                        }
                    }
                    Button("Disconnect", role: .destructive) {
                        app.disconnect()
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
        .preferredColorScheme(.dark)
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
