import SwiftUI

struct SearchView: View {
    @Environment(\.loudTheme) private var theme
    @Environment(AppModel.self) private var app

    @State private var query = ""

    private var results: [LoudTrack] {
        app.searchTracks(query)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(results) { track in
                    PlayableTrackRow(track: track, collection: results)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            .overlay {
                if !query.isEmpty && results.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .background(theme.bg)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, artists, albums")
        }
    }
}
