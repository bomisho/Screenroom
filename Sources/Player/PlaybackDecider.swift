import Foundation

/// Chooses between direct play (AVPlayer reads the file as-is) and the
/// server's universal HLS transcoder.
enum PlaybackDecider {
    enum Route {
        case direct(URL)
        /// `decision` asks the server what it will do (and why), with the same parameters.
        case transcode(URL, session: String, decision: URL)
    }

    private static let directContainers: Set<String> = ["mp4", "m4v", "mov"]
    private static let directVideo: Set<String> = ["h264", "hevc", "h265"]
    private static let directAudio: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac", "flac"]
    /// Subtitle formats AVPlayer can show itself when they are embedded in the file.
    static let directSubtitleCodecs: Set<String> = ["mov_text", "tx3g"]

    static func canDirectPlay(_ media: PlexMedia, subtitle: PlexStream?) -> Bool {
        guard let container = media.container?.lowercased(), directContainers.contains(container) else { return false }
        if let v = media.videoCodec?.lowercased(), !directVideo.contains(v) { return false }
        if let a = media.audioCodec?.lowercased(), !directAudio.contains(a) { return false }
        // Sidecar files and image-based subtitles (PGS, VobSub…) have to be burned in by the server.
        if let subtitle, !isDirectPlayable(subtitle) { return false }
        return media.parts?.first?.key != nil
    }

    static func isDirectPlayable(_ subtitle: PlexStream) -> Bool {
        subtitle.key == nil && directSubtitleCodecs.contains(subtitle.codec?.lowercased() ?? "")
    }

    static func route(for item: PlexMetadata, api: PlexAPI, subtitle: PlexStream?, forceTranscode: Bool = false) throws -> Route {
        guard let media = item.media?.first, let part = media.parts?.first else { throw PlexError.notPlayable }

        if !forceTranscode, canDirectPlay(media, subtitle: subtitle), let key = part.key {
            return .direct(api.url(key, includeToken: true))
        }

        let session = UUID().uuidString
        var q: [String: String] = [
            "path": "/library/metadata/\(item.ratingKey)",
            "mediaIndex": "0",
            "partIndex": "0",
            "protocol": "hls",
            "fastSeek": "1",
            "directPlay": "0",
            "directStream": "1",
            "directStreamAudio": "1",
            "videoQuality": "100",
            "maxVideoBitrate": api.server.isLocal ? "200000" : "20000",
            "videoResolution": "3840x2160",
            "subtitleSize": "100",
            "audioBoost": "100",
            "subtitles": "burn",
            "location": api.server.isLocal ? "lan" : "wan",
            "session": session,
            "offset": "0",
            "copyts": "1",
            "mediaBufferSize": "102400",
            "X-Plex-Session-Identifier": session,
        ]
        // Identify as an Apple client so the server uses an AVPlayer-friendly profile.
        for (k, v) in PlexClientInfo.baseHeaders where k.hasPrefix("X-Plex-") { q[k] = v }
        q["X-Plex-Platform"] = "iOS"

        return .transcode(
            api.url("/video/:/transcode/universal/start.m3u8", q, includeToken: true),
            session: session,
            decision: api.url("/video/:/transcode/universal/decision", q)
        )
    }
}
