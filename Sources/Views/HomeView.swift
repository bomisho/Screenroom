import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model

    @State private var onDeck: [PlexMetadata] = []
    @State private var recent: [RecentRow] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                if let hero = onDeck.first ?? recent.first?.items.first {
                    HeroBanner(item: hero)
                }
                if !onDeck.isEmpty {
                    HubRow(title: "Continue Watching", items: onDeck) { LandscapeCard(item: $0) }
                }
                ForEach(recent) { row in
                    HubRow(title: "Recently Added in \(row.library.title)", items: row.items) { PosterCard(item: $0) }
                }
                if loaded && onDeck.isEmpty && recent.isEmpty {
                    ContentUnavailableView("Nothing here yet", systemImage: "film.stack",
                                           description: Text(error ?? "Add movies or shows to your Plex server to see them here."))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                }
            }
            .padding(.bottom, 48)
        }
        .overlay { if !loaded { ProgressView() } }
        .navigationTitle("Home")
        .toolbar(.hidden, for: .navigationBar)
        .task(id: model.libraryRevision) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            async let deck = api.onDeck()
            var rows: [RecentRow] = []
            for library in model.libraries {
                if let items = try? await api.recentlyAdded(in: library), !items.isEmpty {
                    rows.append(RecentRow(library: library, items: items))
                }
            }
            onDeck = try await deck
            recent = rows
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

struct RecentRow: Identifiable {
    let library: PlexDirectory
    let items: [PlexMetadata]
    var id: String { library.id }
}

/// Big featured banner at the top of Home.
private struct HeroBanner: View {
    let item: PlexMetadata

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Backdrop(path: item.backdropPath, height: 420)
            VStack(alignment: .leading, spacing: 12) {
                Text(item.cardTitle)
                    .font(.extraLargeTitle)
                    .lineLimit(2)
                if let sub = item.isEpisode ? item.cardSubtitle : item.tagline ?? item.summary {
                    Text(sub)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: 700, alignment: .leading)
                }
                HStack(spacing: 16) {
                    if item.isPlayable {
                        PlayButton(
                            title: item.progress != nil ? "Resume" : "Play",
                            systemImage: "play.fill",
                            request: PlayRequest(ratingKey: item.ratingKey, startMs: item.viewOffset ?? 0)
                        )
                    }
                    NavigationLink(value: item) {
                        Label("Details", systemImage: "info.circle")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 6)
            }
            .padding(48)
        }
    }
}
