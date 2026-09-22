import SwiftUI

struct SearchView: View {
    @Environment(\.codecTheme) private var theme
    @Environment(AppModel.self) private var app

    @State private var query = ""

    private var results: [CodecTrack] {
        app.searchTracks(query)
    }

    var body: some View {
        // Share one result snapshot with every lazy row. Resolving `results`
        // inside the row closure repeats the full search as rows scroll in.
        let matchingTracks = results
        NavigationStack {
            List {
                ForEach(matchingTracks) { track in
                    PlayableTrackRow(track: track, collection: matchingTracks)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            .overlay {
                if !query.isEmpty && matchingTracks.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .background(theme.bg)
                }
            }
            .modifier(MiniPlayerInset())
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ScreenHeader(title: "Search")
                // Retain the navigation title without a second centered label.
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1)
                        .accessibilityHidden(true)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, artists, albums")
            #if DEBUG
            .onAppear {
                if let search = ProcessInfo.processInfo.environment["CODEC_SCREENSHOT_SEARCH"] {
                    query = search
                }
            }
            #endif
        }
    }
}
