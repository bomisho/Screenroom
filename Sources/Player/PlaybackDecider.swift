import Foundation

/// Chooses between direct play (AVPlayer reads the file as-is) and the
/// server's universal HLS transcoder.
enum PlaybackDecider {
    enum Route {
        case direct(URL)
        case transcode(URL, session: String)
    }

    private static let directContainers: Set<String> = ["mp4", "m4v", "mov"]
    private static let directVideo: Set<String> = ["h264", "hevc", "h265"]
    private static let directAudio: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac", "flac"]

    static func canDirectPlay(_ media: PlexMedia) -> Bool {
        guard let container = media.container?.lowercased(), directContainers.contains(container) else { return false }
        if let v = media.videoCodec?.lowercased(), !directVideo.contains(v) { return false }
        if let a = media.audioCodec?.lowercased(), !directAudio.contains(a) { return false }
        return media.parts?.first?.key != nil
    }

    static func route(for item: PlexMetadata, api: PlexAPI, forceTranscode: Bool = false) throws -> Route {
        guard let media = item.media?.first, let part = media.parts?.first else { throw PlexError.notPlayable }

        if !forceTranscode, canDirectPlay(media), let key = part.key {
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

        return .transcode(api.url("/video/:/transcode/universal/start.m3u8", q, includeToken: true), session: session)
    }
}
