import SwiftUI

/// Full-screen player: sleek bones (breathing artwork, clean layout) with
/// the deck's transport — latching keys, haptics, themed everything.
struct NowPlayingView: View {
    @Environment(\.loudTheme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(DownloadStore.self) private var downloads

    @State private var showQueue = false
    @State private var scrubTime: Double?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            ArtworkView(track: player.currentTrack, size: 320, cornerRadius: 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(theme.border, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 26, x: 0, y: 14)
                .scaleEffect(player.isPlaying ? 1 : 0.84)
                .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)

            Spacer(minLength: 26)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.currentTrack?.title ?? "Not Playing")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)

                    Text(player.currentTrack?.artist ?? "Pick a track")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let track = player.currentTrack {
                    Button {
                        app.toggleLike(track)
                    } label: {
                        Image(systemName: app.isLiked(track) ? "heart.fill" : "heart")
                            .font(.title3)
                            .foregroundStyle(app.isLiked(track) ? theme.accent : theme.subtle)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 26)

            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { scrubTime ?? player.currentTime },
                        set: { scrubTime = $0 }
                    ),
                    in: 0...max(player.duration, 1)
                ) { editing in
                    if !editing, let target = scrubTime {
                        player.seek(to: target)
                        scrubTime = nil
                    }
                }
                .tint(theme.accent)
                .disabled(player.currentTrack == nil)

                HStack {
                    // Tape-counter digits.
                    Text(formatDuration(scrubTime ?? player.currentTime))
                        .contentTransition(.numericText(countsDown: false))
                        .animation(.snappy(duration: 0.2), value: Int(scrubTime ?? player.currentTime))
                    Spacer()
                    Text(formatDuration(player.duration))
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(theme.subtle)
            }
            .padding(.horizontal, 26)
            .padding(.top, 12)

            // The deck: latching shuffle/play/repeat, momentary skips.
            HStack(spacing: 1) {
                Button {
                    player.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 16, weight: .heavy))
                }
                .buttonStyle(DeckToggleButtonStyle(isOn: player.shuffle))

                Button {
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 19, weight: .heavy))
                }
                .buttonStyle(DeckButtonStyle(leftRadius: false, rightRadius: false))

                Button {
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .heavy))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(DeckToggleButtonStyle(isOn: player.isPlaying))

                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 19, weight: .heavy))
                }
                .buttonStyle(DeckButtonStyle(leftRadius: false, rightRadius: false))

                Button {
                    player.cycleRepeat()
                } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .font(.system(size: 16, weight: .heavy))
                }
                .buttonStyle(DeckToggleButtonStyle(isOn: player.repeatMode != .off))
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Spacer(minLength: 12)

            HStack(spacing: 20) {
                if player.syncEnabled {
                    Menu {
                        ForEach(player.deviceOptions) { device in
                            Button {
                                player.transferPlayback(to: device.deviceID)
                            } label: {
                                if device.deviceID == player.deviceID {
                                    Label("\(device.name) (this iPhone)", systemImage: "iphone")
                                } else {
                                    Label(device.name, systemImage: "hifispeaker")
                                }
                            }
                        }
                    } label: {
                        Label(player.activeDeviceName, systemImage: player.remoteDeviceIsActive ? "hifispeaker.fill" : "iphone")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(player.remoteDeviceIsActive ? theme.accent : theme.subtle)
                    }
                }

                Spacer()

                AudioRoutePicker(tint: theme.subtle, activeTint: theme.accent)
                    .frame(width: 40, height: 40)

                if let track = player.currentTrack {
                    downloadButton(track)
                }

                Button {
                    showQueue = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.body)
                        .foregroundStyle(theme.subtle)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 22)
        }
        .background(theme.bg.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showQueue) {
            QueueView()
        }
    }

    @ViewBuilder
    private func downloadButton(_ track: LoudTrack) -> some View {
        switch downloads.state(for: track) {
        case .downloaded:
            Button {
                downloads.remove(track)
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.body)
                    .foregroundStyle(theme.accent)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
        case .downloading:
            ProgressView()
                .tint(theme.accent)
                .frame(width: 40, height: 40)
        case nil:
            Button {
                if let client = app.client {
                    downloads.download(track, using: client)
                }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.body)
                    .foregroundStyle(theme.subtle)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
        }
    }
}

struct QueueView: View {
    @Environment(\.loudTheme) private var theme
    @Environment(PlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let current = player.currentTrack {
                    Section("Now Playing") {
                        TrackRow(track: current, showsDownloadState: false)
                            .listRowBackground(theme.panel2)
                    }
                }

                if !player.manualQueue.isEmpty {
                    Section("In Queue") {
                        ForEach(Array(player.manualQueue.enumerated()), id: \.offset) { index, track in
                            Button {
                                player.jumpToManualQueue(at: index)
                            } label: {
                                TrackRow(track: track, showsDownloadState: false)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(theme.panel)
                            .swipeActions {
                                Button(role: .destructive) {
                                    player.removeFromQueue(at: index)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                        .onMove { source, destination in
                            player.moveInQueue(from: source, to: destination)
                        }
                    }
                }

                let upcoming = player.upcomingFromSource
                if !upcoming.isEmpty {
                    Section("Up Next") {
                        ForEach(upcoming.prefix(50), id: \.index) { entry in
                            Button {
                                player.jumpToUpcoming(sourceIndex: entry.index)
                            } label: {
                                TrackRow(track: entry.track, showsDownloadState: false)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(theme.panel)
                            .swipeActions {
                                Button(role: .destructive) {
                                    player.removeUpcoming(sourceIndex: entry.index)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !player.manualQueue.isEmpty {
                        Button("Clear") {
                            player.clearQueue()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
