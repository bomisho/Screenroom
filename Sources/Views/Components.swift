import SwiftUI

/// Artwork loaded from the Plex server (cached by URLCache).
struct PlexImage: View {
    let path: String?
    let width: Int
    let height: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        AsyncImage(url: model.api?.imageURL(path, width: width, height: height), transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Rectangle().fill(.quaternary)
            }
        }
    }
}

/// Portrait poster card used in grids and hubs.
struct PosterCard: View {
    let item: PlexMetadata
    var width: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlexImage(path: item.posterPath, width: 360, height: 540)
                .frame(width: width, height: width * 1.5)
                .clipShape(.rect(cornerRadius: 16))
                .overlay(alignment: .topTrailing) { WatchBadge(item: item).padding(8) }
                .overlay(alignment: .bottom) {
                    if let p = item.progress { ProgressBar(value: p).padding(10) }
                }
                .hoverEffect(.lift)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.cardTitle).font(.headline).lineLimit(1)
                if let sub = item.cardSubtitle {
                    Text(sub).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .contentShape(.rect)
    }
}

/// Wide card used for Continue Watching.
struct LandscapeCard: View {
    let item: PlexMetadata
    var width: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlexImage(path: item.landscapePath, width: 680, height: 382)
                .frame(width: width, height: width * 9 / 16)
                .clipShape(.rect(cornerRadius: 18))
                .overlay(alignment: .bottom) {
                    if let p = item.progress { ProgressBar(value: p).padding(12) }
                }
                .hoverEffect(.lift)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.cardTitle).font(.headline).lineLimit(1)
                if let sub = item.cardSubtitle {
                    Text(sub).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .contentShape(.rect)
    }
}

struct ProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.5))
                Capsule().fill(.tint).frame(width: geo.size.width * value)
            }
        }
        .frame(height: 5)
    }
}

struct WatchBadge: View {
    let item: PlexMetadata
    var body: some View {
        if let n = item.unwatchedCount, item.isShow || item.isSeason {
            Text("\(n)")
                .font(.caption.bold())
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.tint, in: .capsule)
                .foregroundStyle(.black)
        } else if item.isWatched {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.55))
        }
    }
}

/// A titled horizontal row of cards.
struct HubRow<Card: View>: View {
    let title: String
    let items: [PlexMetadata]
    @ViewBuilder var card: (PlexMetadata) -> Card

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.bold()).padding(.horizontal, 48)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 24) {
                    ForEach(items) { item in
                        NavigationLink(value: item) { card(item) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// Large backdrop that fades into the window's glass.
struct Backdrop: View {
    let path: String?
    var height: CGFloat = 460

    var body: some View {
        PlexImage(path: path, width: 1920, height: 1080)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipped()
            .mask {
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.55),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
    }
}

/// Button that opens the player window for an item.
struct PlayButton: View {
    let title: String
    let systemImage: String
    let request: PlayRequest
    var prominent = true

    @Environment(\.openWindow) private var openWindow
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var model

    var body: some View {
        if prominent {
            Button(action: play) { Label(title, systemImage: systemImage) }
                .buttonStyle(.borderedProminent)
        } else {
            Button(action: play) { Label(title, systemImage: systemImage) }
                .buttonStyle(.bordered)
        }
    }

    private func play() {
        if player.isWindowOpen, let api = model.api {
            // Reuse the open player window.
            Task { await player.load(request, api: api) }
        } else {
            openWindow(id: SceneID.player, value: request)
        }
    }
}
