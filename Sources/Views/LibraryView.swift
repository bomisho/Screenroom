import SwiftUI

struct LibraryView: View {
    let library: PlexDirectory
    @Environment(AppModel.self) private var model

    @State private var items: [PlexMetadata] = []
    @State private var total = Int.max
    @State private var isLoading = false
    @State private var error: String?
    @State private var sort: SortOption = .title

    private let pageSize = 120
    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 28, alignment: .top)]

    enum SortOption: String, CaseIterable, Identifiable {
        case title = "titleSort"
        case added = "addedAt:desc"
        case released = "originallyAvailableAt:desc"
        case rating = "audienceRating:desc"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .title: "Title"
            case .added: "Date Added"
            case .released: "Release Date"
            case .rating: "Rating"
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 36) {
                ForEach(items) { item in
                    NavigationLink(value: item) { PosterCard(item: item) }
                        .buttonStyle(.plain)
                        .onAppear {
                            if item.id == items.last?.id { Task { await loadMore() } }
                        }
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 24)

            if isLoading { ProgressView().padding() }
        }
        .overlay {
            if let error, items.isEmpty {
                ContentUnavailableView("Couldn’t load \(library.title)", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if !isLoading, items.isEmpty, total == 0 {
                ContentUnavailableView("This library is empty", systemImage: library.systemImage)
            }
        }
        .navigationTitle(library.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort By", selection: $sort) {
                        ForEach(SortOption.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .task(id: "\(sort.rawValue)-\(model.libraryRevision)") { await reload() }
    }

    private func reload() async {
        items = []
        total = Int.max
        await loadMore()
    }

    private func loadMore() async {
        guard let api = model.api, !isLoading, items.count < total else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await api.items(in: library, start: items.count, size: pageSize, sort: sort.rawValue)
            let known = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !known.contains($0.id) })
            total = page.items.isEmpty ? items.count : page.total
            error = nil
        } catch {
            self.error = error.localizedDescription
            total = items.count
        }
    }
}
