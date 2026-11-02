import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [PlexMetadata] = []
    @State private var searching = false

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 28, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 36) {
                ForEach(results) { item in
                    NavigationLink(value: item) { PosterCard(item: item) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 24)
        }
        .overlay {
            if searching {
                ProgressView()
            } else if query.isEmpty {
                ContentUnavailableView("Search your library", systemImage: "magnifyingglass",
                                       description: Text("Find movies, shows and episodes."))
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Movies, shows, episodes")
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { results = []; searching = false; return }
            try? await Task.sleep(for: .milliseconds(350))   // debounce typing
            guard !Task.isCancelled, let api = model.api else { return }
            searching = true
            results = (try? await api.search(q)) ?? []
            if !Task.isCancelled { searching = false }
        }
    }
}
