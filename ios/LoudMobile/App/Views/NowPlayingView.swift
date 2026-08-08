import SwiftUI

/// Full-screen player, Apple-Music style: big artwork that breathes with
/// playback, monochrome transport, one accent nowhere.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(DownloadStore.self) private var downloads

    @State private var showQueue = false
    @State private var scrubTime: Double?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            ArtworkView(track: player.currentTrack, size: 330, cornerRadius: 12)
                .shadow(color: .black.opacity(0.3), radius: 24, x: 0, y: 12)
                .scaleEffect(player.isPlaying ? 1 : 0.82)
                .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)

            Spacer(minLength: 28)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.currentTrack?.title ?? "Not Playing")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .lineLimit(1)

                    Text(player.currentTrack?.artist ?? "")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let track = player.currentTrack {
                    Button {
                        app.toggleLike(track)
                    } label: {
                        Image(systemName: app.isLiked(track) ? "heart.fill" : "heart")
                            .font(.title3)
                            .foregroundStyle(app.isLiked(track) ? .pink : .secondary)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 28)

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
                .disabled(player.currentTrack == nil)

                HStack {
                    Text(formatDuration(scrubTime ?? player.currentTime))
                        .contentTransition(.numericText(countsDown: false))
                        .animation(.snappy(duration: 0.2), value: Int(scrubTime ?? player.currentTime))
                    Spacer()
                    Text(formatDuration(player.duration))
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)

            HStack {
                Button {
                    player.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.body)
                        .foregroundStyle(player.shuffle ? .primary : .secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.title)
                        .frame(width: 56, height: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 42))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 72, height: 72)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title)
                        .frame(width: 56, height: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    player.cycleRepeat()
                } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .font(.body)
                        .foregroundStyle(player.repeatMode != .off ? .primary : .secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)

            Spacer(minLength: 12)

            HStack(spacing: 24) {
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
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let track = player.currentTrack {
                    downloadButton(track)
                }

                Button {
                    showQueue = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
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
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
        case .downloading:
            ProgressView()
                .frame(width: 40, height: 40)
        case nil:
            Button {
                if let client = app.client {
                    downloads.download(track, using: client)
                }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
        }
    }
}

struct QueueView: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let current = player.currentTrack {
                    Section("Now Playing") {
                        TrackRow(track: current, showsDownloadState: false)
                    }
                }

                if !player.manualQueue.isEmpty {
                    Section("In Queue") {
                        ForEach(Array(player.manualQueue.enumerated()), id: \.offset) { index, track in
                            TrackRow(track: track, showsDownloadState: false)
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

                let upcoming = player.upNext.dropFirst(player.manualQueue.count)
                if !upcoming.isEmpty {
                    Section("Up Next") {
                        ForEach(Array(upcoming.prefix(50).enumerated()), id: \.offset) { _, track in
                            TrackRow(track: track, showsDownloadState: false)
                        }
                    }
                }
            }
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
