import SwiftUI

/// TV show page: backdrop, seasons, and the selected season's episodes.
struct ShowView: View {
    let ratingKey: String
    var initialSeasonKey: String? = nil

    @Environment(AppModel.self) private var model
    @State private var show: PlexMetadata?
    @State private var seasons: [PlexMetadata] = []
    @State private var selectedSeason: String?
    @State private var episodes: [PlexMetadata] = []
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let show {
                VStack(alignment: .leading, spacing: 32) {
                    header(show)
                    if seasons.count > 1 { seasonPicker }
                    episodeList
                }
                .padding(.bottom, 48)
            }
        }
        .overlay {
            if show == nil {
                if let error {
                    ContentUnavailableView("Couldn’t load this show", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView()
                }
            }
        }
        .navigationTitle(show?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.libraryRevision) { await loadShow() }
        .task(id: "\(selectedSeason ?? "")-\(model.libraryRevision)") { await loadEpisodes() }
    }

    // MARK: Sections

    private func header(_ show: PlexMetadata) -> some View {
        ZStack(alignment: .bottomLeading) {
            Backdrop(path: show.art ?? show.thumb, height: 440)
            VStack(alignment: .leading, spacing: 12) {
                Text(show.title).font(.extraLargeTitle2).lineLimit(2)
                Text([show.year.map(String.init), show.contentRating, show.childCount.map { "\($0) Seasons" }]
                    .compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.headline).foregroundStyle(.secondary)
                if let summary = show.summary, !summary.isEmpty {
                    Text(summary).font(.body).lineLimit(4).frame(maxWidth: 820, alignment: .leading)
                }
                if let next = nextUp {
                    PlayButton(
                        title: next.progress != nil ? "Resume \(next.episodeLabel ?? "")" : "Play \(next.episodeLabel ?? "")",
                        systemImage: "play.fill",
                        request: PlayRequest(ratingKey: next.ratingKey, startMs: next.viewOffset ?? 0)
                    )
                    .padding(.top, 8)
                }
            }
            .padding(48)
        }
    }

    private var seasonPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(seasons) { season in
                    let selected = season.ratingKey == selectedSeason
                    Button {
                        selectedSeason = season.ratingKey
                    } label: {
                        Text(season.title)
                            .font(.headline)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(selected ? AnyShapeStyle(.tint.opacity(0.35)) : AnyShapeStyle(.regularMaterial), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                }
            }
            .padding(.horizontal, 48)
        }
        .scrollIndicators(.hidden)
    }

    private var episodeList: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(episodes) { episode in
                NavigationLink(value: episode) { EpisodeRow(episode: episode) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 48)
    }

    /// First in-progress or unwatched episode of the loaded season.
    private var nextUp: PlexMetadata? {
        episodes.first(where: { $0.progress != nil }) ?? episodes.first(where: { !$0.isWatched }) ?? episodes.first
    }

    // MARK: Loading

    private func loadShow() async {
        guard let api = model.api else { return }
        do {
            async let s = api.metadata(ratingKey)
            async let c = api.children(ratingKey)
            show = try await s
            seasons = try await c.filter(\.isSeason)
            if selectedSeason == nil {
                selectedSeason = initialSeasonKey
                    ?? seasons.first(where: { !$0.isWatched && ($0.index ?? 0) > 0 })?.ratingKey
                    ?? seasons.first?.ratingKey
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadEpisodes() async {
        guard let api = model.api, let selectedSeason else { return }
        episodes = (try? await api.children(selectedSeason)) ?? []
    }
}

struct EpisodeRow: View {
    let episode: PlexMetadata

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            PlexImage(path: episode.thumb, width: 520, height: 292)
                .frame(width: 260, height: 146)
                .clipShape(.rect(cornerRadius: 14))
                .overlay(alignment: .bottom) {
                    if let p = episode.progress { ProgressBar(value: p).padding(8) }
                }
                .overlay(alignment: .topTrailing) {
                    if episode.isWatched { WatchBadge(item: episode).padding(6) }
                }

            VStack(alignment: .leading, spacing: 6) {
                Text(episode.episodeLabel ?? "")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(episode.title).font(.title3.bold()).lineLimit(1)
                if let summary = episode.summary {
                    Text(summary).font(.body).foregroundStyle(.secondary).lineLimit(3)
                }
                if let d = episode.duration {
                    Text(Format.runtime(ms: d)).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.regularMaterial.opacity(0.5), in: .rect(cornerRadius: 22))
        .contentShape(.hoverEffect, .rect(cornerRadius: 22))
        .hoverEffect(.highlight)
    }
}
