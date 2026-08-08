import SwiftUI

struct SearchView: View {
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
            .overlay {
                if !query.isEmpty && results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, artists, albums")
        }
    }
}
