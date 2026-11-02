import SwiftUI

/// Movie or episode detail page.
struct DetailView: View {
    let ratingKey: String
    @Environment(AppModel.self) private var model

    @State private var item: PlexMetadata?
    @State private var error: String?
    @State private var updatingWatched = false

    var body: some View {
        Group {
            if let item {
                content(item)
            } else if let error {
                ContentUnavailableView("Couldn’t load this title", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(item?.cardTitle ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.libraryRevision) { await load() }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            item = try await api.metadata(ratingKey)
        } catch {
            self.error = error.localizedDescription
        }
    }

    @ViewBuilder
    private func content(_ item: PlexMetadata) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    Backdrop(path: item.backdropPath, height: 480)
                    HStack(alignment: .bottom, spacing: 36) {
                        PlexImage(path: item.isEpisode ? item.thumb : item.posterPath,
                                  width: item.isEpisode ? 640 : 440,
                                  height: item.isEpisode ? 360 : 660)
                            .frame(width: item.isEpisode ? 320 : 220, height: item.isEpisode ? 180 : 330)
                            .clipShape(.rect(cornerRadius: 20))
                            .shadow(radius: 20)

                        VStack(alignment: .leading, spacing: 10) {
                            if item.isEpisode {
                                Text([item.grandparentTitle, item.episodeLabel].compactMap { $0 }.joined(separator: "  ·  "))
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                            Text(item.title)
                                .font(.extraLargeTitle2)
                                .lineLimit(2)
                            Text(item.metadataLine)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            actions(item).padding(.top, 10)
                        }
                    }
                    .padding(48)
                }

                VStack(alignment: .leading, spacing: 32) {
                    if let tagline = item.tagline, !tagline.isEmpty {
                        Text(tagline).font(.title3.italic()).foregroundStyle(.secondary)
                    }
                    if let summary = item.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.title3)
                            .frame(maxWidth: 900, alignment: .leading)
                    }
                    infoGrid(item)
                    if let roles = item.roles, !roles.isEmpty {
                        CastRow(roles: roles)
                    }
                }
                .padding(.horizontal, 48)
                .padding(.bottom, 48)
            }
        }
    }

    @ViewBuilder
    private func actions(_ item: PlexMetadata) -> some View {
        HStack(spacing: 16) {
            if let offset = item.viewOffset, offset > 0 {
                PlayButton(title: "Resume \(Format.timecode(Double(offset) / 1000))", systemImage: "play.fill",
                           request: PlayRequest(ratingKey: item.ratingKey, startMs: offset))
                PlayButton(title: "From Start", systemImage: "arrow.counterclockwise",
                           request: PlayRequest(ratingKey: item.ratingKey, startMs: 0), prominent: false)
            } else {
                PlayButton(title: "Play", systemImage: "play.fill",
                           request: PlayRequest(ratingKey: item.ratingKey, startMs: 0))
            }
            Button {
                Task { await toggleWatched(item) }
            } label: {
                Label(item.isWatched ? "Mark Unwatched" : "Mark Watched",
                      systemImage: item.isWatched ? "eye.slash" : "checkmark.circle")
            }
            .buttonStyle(.bordered)
            .disabled(updatingWatched)
        }
    }

    private func toggleWatched(_ item: PlexMetadata) async {
        guard let api = model.api else { return }
        updatingWatched = true
        defer { updatingWatched = false }
        do {
            try await api.setWatched(item.ratingKey, watched: !item.isWatched)
            model.libraryRevision += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    @ViewBuilder
    private func infoGrid(_ item: PlexMetadata) -> some View {
        let rows: [(String, String)] = [
            ("Genre", (item.genres ?? []).map(\.tag).prefix(4).joined(separator: ", ")),
            ("Director", (item.directors ?? []).map(\.tag).prefix(3).joined(separator: ", ")),
            ("Studio", item.studio ?? ""),
            ("Audio", item.audioStreams.first(where: { $0.selected == true })?.label ?? item.audioStreams.first?.label ?? ""),
        ].filter { !$0.1.isEmpty }

        if !rows.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                ForEach(rows.indices, id: \.self) { i in
                    GridRow {
                        Text(rows[i].0).foregroundStyle(.secondary)
                        Text(rows[i].1)
                    }
                }
            }
            .font(.body)
        }
    }
}

struct CastRow: View {
    let roles: [PlexRole]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cast").font(.title2.bold())
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 22) {
                    ForEach(roles.prefix(30)) { role in
                        VStack(spacing: 8) {
                            PlexImage(path: role.thumb, width: 240, height: 240)
                                .frame(width: 110, height: 110)
                                .clipShape(.circle)
                                .overlay {
                                    if role.thumb == nil {
                                        Image(systemName: "person.fill").font(.largeTitle).foregroundStyle(.secondary)
                                    }
                                }
                            Text(role.tag).font(.subheadline.bold()).lineLimit(1)
                            if let character = role.role {
                                Text(character).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(width: 130)
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
        }
    }
}
