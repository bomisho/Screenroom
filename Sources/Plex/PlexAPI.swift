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

    /// Asks the transcoder what it will do with a request. Also registers the session,
    /// as official clients do before requesting `start.m3u8`.
    func transcodeDecision(_ url: URL) async throws -> TranscodeDecision {
        let data = try await HTTP.data(url, token: server.token, extraHeaders: Self.streamingHeaders)
        return try JSONDecoder().decode(TranscodeDecisionResponse.self, from: data).container
    }

    /// The transcoder picks its output profile from X-Plex-Platform and has none for
    /// visionOS (it answers 400), so streaming requests identify as iOS. Headers win over
    /// the same values in the query string.
    static let streamingHeaders = ["X-Plex-Platform": "iOS"]

    /// Starts an HLS conversion and waits until the piece of video at `startAt` exists.
    /// Returns the media playlist URL to hand to AVPlayer.
    ///
    /// The server only begins converting once the media playlist is requested, and answers
    /// 404 for segments until the converter is running. AVPlayer treats those 404s as fatal
    /// (CoreMedia -12889 / -12927), so we do the warm-up ourselves.
    func prepareHLS(_ startURL: URL, startAt seconds: Double, timeout: TimeInterval = 60) async throws -> URL {
        func lines(_ data: Data) -> [String] {
            String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let master = lines(try await HTTP.data(startURL, token: server.token, extraHeaders: Self.streamingHeaders))
        guard let variantPath = master.first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
              let variant = URL(string: variantPath, relativeTo: startURL)?.absoluteURL
        else { throw PlexError.notPlayable }

        // Find the segment that covers the start position.
        var elapsed = 0.0, duration = 0.0
        var segmentPath: String?
        for line in lines(try await HTTP.data(variant, token: server.token, extraHeaders: Self.streamingHeaders)) {
            if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst(8).prefix { $0 != "," }) ?? 0
            } else if !line.isEmpty, !line.hasPrefix("#") {
                segmentPath = line
                if elapsed + duration > seconds { break }
                elapsed += duration
            }
        }
        guard let segmentPath, let segment = URL(string: segmentPath, relativeTo: variant)?.absoluteURL else { return variant }

        // Once the converter runs, a segment request waits until that segment is ready.
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: segment, timeoutInterval: 30)
            for (k, v) in PlexClientInfo.headers(token: server.token).merging(Self.streamingHeaders, uniquingKeysWith: { $1 }) {
                request.setValue(v, forHTTPHeaderField: k)
            }
            request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            if let (_, response) = try? await HTTP.session.data(for: request),
               let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) {
                return variant
            }
            guard Date() < deadline else { throw PlexError.transcoderTimeout }
            try await Task.sleep(for: .milliseconds(500))
        }
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

struct TranscodeDecisionResponse: Decodable {
    let container: TranscodeDecision
    enum CodingKeys: String, CodingKey { case container = "MediaContainer" }
}

/// The server's explanation of how (or whether) it can stream an item.
struct TranscodeDecision: Decodable {
    let generalDecisionCode: Int?
    let generalDecisionText: String?
    let transcodeDecisionCode: Int?
    let transcodeDecisionText: String?

    /// A human-readable reason, if the server reported a problem.
    var problem: String? {
        if let code = generalDecisionCode, code >= 2000 { return generalDecisionText }
        if let code = transcodeDecisionCode, code >= 2000 { return transcodeDecisionText }
        return nil
    }
}
