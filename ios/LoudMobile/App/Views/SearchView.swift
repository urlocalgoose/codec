import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player

    @State private var query = ""

    private var results: [LoudTrack] {
        app.searchTracks(query)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { track in
                        Button {
                            if player.currentTrack?.id == track.id {
                                player.togglePlayback()
                            } else {
                                player.play(track, from: results)
                            }
                        } label: {
                            TrackRow(track: track)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                player.playNext(track)
                            } label: {
                                Label("Add to Queue", systemImage: "text.badge.plus")
                            }
                        }
                    }

                    if !query.isEmpty && results.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 30, weight: .bold))
                            Text("Nothing matches \"\(query)\".")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(LoudColor.subtle)
                        .padding(.top, 80)
                    }
                }
                .padding(.bottom, 130)
            }
            .background(LoudColor.bg)
            .navigationTitle("Search")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, artists, albums")
        }
    }
}
