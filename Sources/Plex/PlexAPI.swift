import Foundation

/// A server we have successfully connected to.
struct PlexServer: Codable, Hashable {
    let id: String
    let name: String
    let baseURL: URL
    let token: String
    let isLocal: Bool
    let isRelay: Bool
}

/// Requests against one Plex Media Server.
struct PlexAPI {
    let server: PlexServer

    // MARK: URL building

    func url(_ path: String, _ query: [String: String] = [:], includeToken: Bool = false) -> URL {
        var base = server.baseURL.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        var components = URLComponents(string: base + (path.hasPrefix("/") ? path : "/" + path))!
        var items = components.queryItems ?? []
        for (k, v) in query.sorted(by: { $0.key < $1.key }) { items.append(URLQueryItem(name: k, value: v)) }
        if includeToken { items.append(URLQueryItem(name: "X-Plex-Token", value: server.token)) }
        components.queryItems = items.isEmpty ? nil : items
        // URLComponents leaves "+" alone; Plex would read it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// Resized artwork through the server's photo transcoder.
    func imageURL(_ path: String?, width: Int, height: Int) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return url("/photo/:/transcode", ["width": "\(width)", "height": "\(height)", "minSize": "1", "upscale": "1", "url": path], includeToken: true)
    }

    // MARK: Requests

    func container(_ path: String, _ query: [String: String] = [:]) async throws -> MediaContainer {
        let data = try await HTTP.data(url(path, query), token: server.token)
        return try JSONDecoder().decode(PlexResponse.self, from: data).container
    }

    func send(_ path: String, _ query: [String: String] = [:], method: String = "GET", extraHeaders: [String: String] = [:]) async throws {
        _ = try await HTTP.data(url(path, query), method: method, token: server.token, extraHeaders: extraHeaders)
    }

    // MARK: Library

    func libraries() async throws -> [PlexDirectory] {
        try await container("/library/sections").directories ?? []
    }

    func items(in library: PlexDirectory, start: Int, size: Int, sort: String = "titleSort") async throws -> (items: [PlexMetadata], total: Int) {
        let c = try await container("/library/sections/\(library.key)/all", [
            "sort": sort,
            "X-Plex-Container-Start": "\(start)",
            "X-Plex-Container-Size": "\(size)",
        ])
        let items = c.metadata ?? []
        return (items, c.totalSize ?? c.size ?? items.count)
    }

    func onDeck() async throws -> [PlexMetadata] {
        try await container("/library/onDeck", ["X-Plex-Container-Size": "30"]).metadata ?? []
    }

    func recentlyAdded(in library: PlexDirectory) async throws -> [PlexMetadata] {
        try await container("/library/sections/\(library.key)/recentlyAdded", [
            "X-Plex-Container-Start": "0",
            "X-Plex-Container-Size": "24",
        ]).metadata ?? []
    }

    func metadata(_ ratingKey: String) async throws -> PlexMetadata {
        guard let item = try await container("/library/metadata/\(ratingKey)").metadata?.first else {
            throw PlexError.badStatus(404)
        }
        return item
    }

    func children(_ ratingKey: String) async throws -> [PlexMetadata] {
        try await container("/library/metadata/\(ratingKey)/children").metadata ?? []
    }

    func search(_ query: String) async throws -> [PlexMetadata] {
        let hubs = try await container("/hubs/search", ["query": query, "limit": "20"]).hubs ?? []
        let wanted: Set<String> = ["movie", "show", "season", "episode"]
        return hubs.flatMap { $0.metadata ?? [] }.filter { wanted.contains($0.type ?? "") }
    }

    func setWatched(_ ratingKey: String, watched: Bool) async throws {
        try await send(watched ? "/:/scrobble" : "/:/unscrobble", [
            "key": ratingKey,
            "identifier": "com.plexapp.plugins.library",
        ])
    }

    /// Episode that follows `episode` in its show (crossing into the next season).
    func nextEpisode(after episode: PlexMetadata) async throws -> PlexMetadata? {
        guard episode.isEpisode, let seasonKey = episode.parentRatingKey else { return nil }
        let siblings = try await children(seasonKey)
        if let i = siblings.firstIndex(where: { $0.ratingKey == episode.ratingKey }), i + 1 < siblings.count {
            return siblings[i + 1]
        }
        guard let showKey = episode.grandparentRatingKey else { return nil }
        let seasons = try await children(showKey).filter { $0.isSeason }
        guard let s = seasons.firstIndex(where: { $0.ratingKey == seasonKey }), s + 1 < seasons.count else { return nil }
        return try await children(seasons[s + 1].ratingKey).first
    }

    // MARK: Playback reporting

    func timeline(ratingKey: String, state: String, timeMs: Int, durationMs: Int, session: String?) async throws {
        var headers: [String: String] = [:]
        if let session { headers["X-Plex-Session-Identifier"] = session }
        try await send("/:/timeline", [
            "ratingKey": ratingKey,
            "key": "/library/metadata/\(ratingKey)",
            "state": state,
            "time": "\(timeMs)",
            "duration": "\(durationMs)",
            "hasMDE": "1",
        ], extraHeaders: headers)
    }

    func stopTranscode(session: String) async throws {
        try await send("/video/:/transcode/universal/stop", ["session": session])
    }

    /// Persists the chosen audio/subtitle streams on the part (used by the transcoder).
    func selectStreams(partID: Int, audioStreamID: Int?, subtitleStreamID: Int?) async throws {
        var q: [String: String] = ["allParts": "1"]
        if let audioStreamID { q["audioStreamID"] = "\(audioStreamID)" }
        if let subtitleStreamID { q["subtitleStreamID"] = "\(subtitleStreamID)" }
        try await send("/library/parts/\(partID)", q, method: "PUT")
    }
}
