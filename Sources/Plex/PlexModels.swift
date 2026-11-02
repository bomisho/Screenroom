import Foundation

struct PlexResponse: Decodable {
    let container: MediaContainer
    enum CodingKeys: String, CodingKey { case container = "MediaContainer" }
}

struct MediaContainer: Decodable {
    var size: Int?
    var totalSize: Int?
    var metadata: [PlexMetadata]?
    var directories: [PlexDirectory]?
    var hubs: [PlexHub]?

    enum CodingKeys: String, CodingKey {
        case size, totalSize
        case metadata = "Metadata"
        case directories = "Directory"
        case hubs = "Hub"
    }
}

/// A library section (e.g. "Movies", "TV Shows").
struct PlexDirectory: Decodable, Identifiable, Hashable {
    let key: String
    let title: String
    let type: String?
    var id: String { key }

    var isVideoLibrary: Bool { type == "movie" || type == "show" }
    var systemImage: String { type == "show" ? "tv" : "film" }
}

struct PlexHub: Decodable, Identifiable {
    let hubIdentifier: String?
    let title: String
    let type: String?
    let metadata: [PlexMetadata]?
    var id: String { hubIdentifier ?? title }

    enum CodingKeys: String, CodingKey {
        case hubIdentifier, title, type
        case metadata = "Metadata"
    }
}

struct PlexTag: Decodable, Hashable {
    let tag: String
}

struct PlexRole: Decodable, Hashable, Identifiable {
    let tag: String
    let role: String?
    let thumb: String?
    var id: String { tag + (role ?? "") }
}

struct PlexStream: Decodable, Hashable, Identifiable {
    let id: Int
    let streamType: Int          // 1 video, 2 audio, 3 subtitle
    let codec: String?
    let index: Int?
    let displayTitle: String?
    let extendedDisplayTitle: String?
    let title: String?
    let language: String?
    let languageCode: String?
    let selected: Bool?
    let isDefault: Bool?
    let forced: Bool?
    let key: String?             // present for external (sidecar) subtitles
    let channels: Int?

    enum CodingKeys: String, CodingKey {
        case id, streamType, codec, index, displayTitle, extendedDisplayTitle, title
        case language, languageCode, selected, forced, key, channels
        case isDefault = "default"
    }

    var label: String { extendedDisplayTitle ?? displayTitle ?? title ?? language ?? "Track \(id)" }
}

struct PlexPart: Decodable, Hashable {
    let id: Int
    let key: String?
    let duration: Int?
    let file: String?
    let size: Int?
    let container: String?
    let streams: [PlexStream]?

    enum CodingKeys: String, CodingKey {
        case id, key, duration, file, size, container
        case streams = "Stream"
    }
}

struct PlexMedia: Decodable, Hashable {
    let id: Int
    let duration: Int?
    let bitrate: Int?
    let width: Int?
    let height: Int?
    let aspectRatio: Double?
    let audioChannels: Int?
    let audioCodec: String?
    let videoCodec: String?
    let videoResolution: String?
    let container: String?
    let parts: [PlexPart]?

    enum CodingKeys: String, CodingKey {
        case id, duration, bitrate, width, height, aspectRatio, audioChannels
        case audioCodec, videoCodec, videoResolution, container
        case parts = "Part"
    }
}

/// Any library item: movie, show, season, episode…
struct PlexMetadata: Decodable, Identifiable, Hashable {
    let ratingKey: String
    let key: String?
    let type: String?
    let title: String
    let titleSort: String?
    let summary: String?
    let tagline: String?
    let year: Int?
    let contentRating: String?
    let rating: Double?
    let audienceRating: Double?
    let studio: String?
    let originallyAvailableAt: String?

    let thumb: String?
    let art: String?
    let parentThumb: String?
    let grandparentThumb: String?
    let grandparentArt: String?

    let parentRatingKey: String?
    let grandparentRatingKey: String?
    let parentTitle: String?
    let grandparentTitle: String?
    let index: Int?
    let parentIndex: Int?

    let duration: Int?
    let viewOffset: Int?
    let viewCount: Int?
    let leafCount: Int?
    let viewedLeafCount: Int?
    let childCount: Int?

    let genres: [PlexTag]?
    let directors: [PlexTag]?
    let roles: [PlexRole]?
    let media: [PlexMedia]?

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, type, title, titleSort, summary, tagline, year, contentRating
        case rating, audienceRating, studio, originallyAvailableAt
        case thumb, art, parentThumb, grandparentThumb, grandparentArt
        case parentRatingKey, grandparentRatingKey, parentTitle, grandparentTitle, index, parentIndex
        case duration, viewOffset, viewCount, leafCount, viewedLeafCount, childCount
        case genres = "Genre"
        case directors = "Director"
        case roles = "Role"
        case media = "Media"
    }

    var id: String { ratingKey }
    static func == (a: PlexMetadata, b: PlexMetadata) -> Bool { a.ratingKey == b.ratingKey }
    func hash(into hasher: inout Hasher) { hasher.combine(ratingKey) }
}

extension PlexMetadata {
    var isEpisode: Bool { type == "episode" }
    var isShow: Bool { type == "show" }
    var isSeason: Bool { type == "season" }
    var isPlayable: Bool { type == "movie" || type == "episode" || type == "clip" }

    /// Portrait artwork (shows use the series poster for episodes).
    var posterPath: String? {
        switch type {
        case "episode": grandparentThumb ?? parentThumb ?? thumb
        case "season": thumb ?? parentThumb
        default: thumb
        }
    }

    /// Wide artwork, for backdrops and "Continue Watching" cards.
    var backdropPath: String? {
        switch type {
        case "episode": grandparentArt ?? art ?? thumb
        default: art ?? thumb
        }
    }

    /// Episode still if available, otherwise the backdrop.
    var landscapePath: String? {
        isEpisode ? (thumb ?? backdropPath) : backdropPath
    }

    /// Main heading shown under a card (series name for episodes).
    var cardTitle: String {
        isEpisode ? (grandparentTitle ?? title) : (isSeason ? (parentTitle ?? title) : title)
    }

    var cardSubtitle: String? {
        switch type {
        case "episode": episodeLabel.map { "\($0) · \(title)" } ?? title
        case "season": title
        case "show": leafCount.map { "\($0) episodes" }
        default: year.map(String.init)
        }
    }

    var episodeLabel: String? {
        guard let index else { return nil }
        if let parentIndex { return "S\(parentIndex) · E\(index)" }
        return "E\(index)"
    }

    var progress: Double? {
        guard let viewOffset, let duration, duration > 0, viewOffset > 0 else { return nil }
        return min(1, Double(viewOffset) / Double(duration))
    }

    var isWatched: Bool {
        if let leafCount, let viewedLeafCount, leafCount > 0 { return viewedLeafCount >= leafCount }
        return (viewCount ?? 0) > 0
    }

    var unwatchedCount: Int? {
        guard let leafCount, let viewedLeafCount else { return nil }
        let n = leafCount - viewedLeafCount
        return n > 0 ? n : nil
    }

    var firstPart: PlexPart? { media?.first?.parts?.first }
    var streams: [PlexStream] { firstPart?.streams ?? [] }
    var audioStreams: [PlexStream] { streams.filter { $0.streamType == 2 } }
    var subtitleStreams: [PlexStream] { streams.filter { $0.streamType == 3 } }

    var metadataLine: String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        if let contentRating { parts.append(contentRating) }
        if let duration { parts.append(Format.runtime(ms: duration)) }
        if let res = media?.first?.videoResolution { parts.append(res.lowercased() == "4k" ? "4K" : res + "p") }
        return parts.joined(separator: "  ·  ")
    }
}

enum Format {
    static func runtime(ms: Int) -> String {
        let minutes = ms / 60_000
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
