import SwiftUI

/// Full-screen player. The transport is a tape deck: play latches down while
/// playing, skip keys are momentary.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(DownloadStore.self) private var downloads
    @Environment(\.dismiss) private var dismiss

    @State private var showQueue = false
    @State private var scrubTime: Double?

    var body: some View {
        VStack(spacing: 24) {
            Capsule()
                .fill(LoudColor.surface)
                .frame(width: 44, height: 5)
                .padding(.top, 10)

            Spacer(minLength: 0)

            ArtworkView(track: player.currentTrack, size: 290, cornerRadius: 8)
                .shadow(color: Color.black.opacity(0.5), radius: 30, x: 0, y: 18)

            VStack(spacing: 6) {
                Text(player.currentTrack?.title ?? "Nothing playing")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(LoudColor.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                HStack(spacing: 6) {
                    if let track = player.currentTrack, track.isLiked {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(LoudColor.accent)
                    }
                    Text(player.currentTrack?.artist ?? "Pick a track")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LoudColor.muted)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 24)

            VStack(spacing: 6) {
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
                .tint(LoudColor.accent)
                .disabled(player.currentTrack == nil)

                HStack {
                    Text(formatDuration(scrubTime ?? player.currentTime))
                    Spacer()
                    Text(formatDuration(player.duration))
                }
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(LoudColor.subtle)
            }
            .padding(.horizontal, 24)

            // The deck. Shuffle and repeat latch; play latches while playing.
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
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 24)

            HStack(spacing: 18) {
                Button {
                    showQueue = true
                } label: {
                    Label("Queue", systemImage: "list.triangle")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(LoudColor.muted)
                }

                Spacer()

                if let track = player.currentTrack {
                    downloadButton(track)
                }
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 20)
        }
        .background(LoudColor.bg.ignoresSafeArea())
        .presentationDragIndicator(.hidden)
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
                Label("Downloaded", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(LoudColor.accent)
            }
        case .downloading:
            HStack(spacing: 6) {
                ProgressView()
                    .tint(LoudColor.accent)
                Text("Downloading")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(LoudColor.muted)
            }
        case nil:
            Button {
                if let client = app.client {
                    downloads.download(track, using: client)
                }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(LoudColor.muted)
            }
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
                    Section("Now playing") {
                        TrackRow(track: current, showsDownloadState: false)
                            .listRowInsets(EdgeInsets())
                    }
                    .listRowBackground(LoudColor.panel2)
                }

                if !player.manualQueue.isEmpty {
                    Section("In queue") {
                        ForEach(Array(player.manualQueue.enumerated()), id: \.offset) { index, track in
                            TrackRow(track: track, showsDownloadState: false)
                                .listRowInsets(EdgeInsets())
                                .swipeActions {
                                    Button(role: .destructive) {
                                        player.removeFromQueue(at: index)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listRowBackground(LoudColor.panel)
                }

                let upcoming = player.upNext.dropFirst(player.manualQueue.count)
                if !upcoming.isEmpty {
                    Section("Up next") {
                        ForEach(Array(upcoming.prefix(50).enumerated()), id: \.offset) { _, track in
                            TrackRow(track: track, showsDownloadState: false)
                                .listRowInsets(EdgeInsets())
                        }
                    }
                    .listRowBackground(LoudColor.panel)
                }
            }
            .scrollContentBackground(.hidden)
            .background(LoudColor.bg)
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
        .preferredColorScheme(.dark)
    }
}
