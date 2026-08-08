import SwiftUI

struct HomeView: View {
    @Environment(\.loudTheme) private var theme
    @Environment(AppModel.self) private var app

    @State private var showSettings = false
    @State private var showThemePicker = false

    var body: some View {
        NavigationStack {
            List {
                // Faceplate badge: heaviest weight SF Pro ships, tightened
                // like a receiver logo.
                Text("Codec")
                    .font(.system(size: 42, weight: .black))
                    .tracking(-1)
                    .foregroundStyle(theme.text)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                if app.connection == .offline {
                    Label("Offline — playing downloads and cache", systemImage: "wifi.slash")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(theme.accentText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(theme.accent)
                        .clipShape(Capsule())
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                if !app.userPlaylists.isEmpty {
                    Section {
                        playlistRail
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } header: {
                        SectionLabel("Playlists")
                    }
                }

                Section {
                    ForEach(app.recentlyAdded) { track in
                        PlayableTrackRow(track: track, collection: app.recentlyAdded)
                    }
                } header: {
                    SectionLabel("Recently added")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
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

    private var playlistRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(app.userPlaylists) { playlist in
                    NavigationLink {
                        TrackListView(title: playlist.name, tracks: app.tracks(in: playlist))
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(theme.accent)
                            Spacer(minLength: 0)
                            Text(playlist.name)
                                .font(.system(size: 14, weight: .heavy))
                                .foregroundStyle(theme.text)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text("\(playlist.trackIDs.count) tracks")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.subtle)
                        }
                        .padding(12)
                        .frame(width: 132, height: 116, alignment: .leading)
                        .background(theme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(theme.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
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
