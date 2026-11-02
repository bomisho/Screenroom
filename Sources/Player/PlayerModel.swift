import AVFoundation
import Foundation
import Observation

/// What to play, passed to the player window.
struct PlayRequest: Codable, Hashable {
    var ratingKey: String
    var startMs: Int
}

/// Owns the AVPlayer, decides how to stream, and reports progress back to Plex.
@MainActor
@Observable
final class PlayerModel {
    enum Status: Equatable {
        case idle
        case loading
        case playing
        case failed(String)
    }

    let player = AVPlayer()

    private(set) var status: Status = .idle
    private(set) var item: PlexMetadata?
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var videoAspect: Double = 16.0 / 9.0
    private(set) var isTranscoding = false

    // Audio and subtitle tracks, as Plex describes them.
    private(set) var audioTracks: [PlexStream] = []
    private(set) var subtitleTracks: [PlexStream] = []
    private(set) var selectedAudioID: Int?
    /// `nil` means subtitles are off.
    private(set) var selectedSubtitleID: Int?
    private(set) var isSwitchingTracks = false
    /// While a track menu is showing, the controls stay up.
    var isTrackMenuOpen = false

    /// Room dimmed for the theater-style view.
    var isRoomDimmed = false

    /// Set by the player window so play buttons can reuse it.
    var isWindowOpen = false

    // Internal state
    private var api: PlexAPI?
    private var request: PlayRequest?
    private var transcodeSession: String?
    private var serverProblem: String?
    private var serverDecision: TranscodeDecision?
    private var directPlayFailed = false
    private var pendingStartSeconds: Double = 0
    private var didStartPlayback = false
    private var didScrobble = false
    private var lastReport = Date.distantPast
    private var reportedState = ""

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var observations: [NSKeyValueObservation] = []

    init() {
        // allowsExternalPlayback / preventsDisplaySleepDuringVideoPlayback are
        // unavailable on visionOS; the system manages both there.
        // We choose tracks ourselves (from Plex's selection), so AVPlayer shouldn't override them.
        player.appliesMediaSelectionCriteriaAutomatically = false
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var title: String { item?.cardTitle ?? "" }
    var subtitle: String? { item?.isEpisode == true ? item?.cardSubtitle : item?.year.map(String.init) }

    // MARK: Loading

    func load(_ request: PlayRequest, api: PlexAPI) async {
        if self.request == request, status != .idle { return }
        await stop()

        self.api = api
        self.request = request
        status = .loading

        do {
            let item = try await api.metadata(request.ratingKey)
            self.item = item
            if let ms = item.media?.first?.duration ?? item.duration { duration = Double(ms) / 1000 }
            if let m = item.media?.first, let w = m.width, let h = m.height, w > 0, h > 0 {
                videoAspect = Double(w) / Double(h)
            }
            audioTracks = item.audioStreams
            subtitleTracks = item.subtitleStreams
            selectedAudioID = (audioTracks.first { $0.selected == true } ?? audioTracks.first)?.id
            selectedSubtitleID = subtitleTracks.first { $0.selected == true }?.id
            try await start(item: item, at: Double(request.startMs) / 1000, forceTranscode: false)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private var selectedSubtitle: PlexStream? {
        subtitleTracks.first { $0.id == selectedSubtitleID }
    }

    private func start(item: PlexMetadata, at seconds: Double, forceTranscode: Bool) async throws {
        guard let api else { return }
        let request = self.request
        teardownItemObservers()

        let route = try PlaybackDecider.route(for: item, api: api, subtitle: selectedSubtitle,
                                              forceTranscode: forceTranscode || directPlayFailed)
        let url: URL
        serverProblem = nil
        serverDecision = nil
        switch route {
        case .direct(let u):
            url = u
            isTranscoding = false
            transcodeSession = nil
        case .transcode(let u, let session, let decision):
            url = u
            isTranscoding = true
            transcodeSession = session
            // Registers the session and tells us why the server can't stream, if it can't.
            do {
                let d = try await api.transcodeDecision(decision)
                serverDecision = d
                serverProblem = d.problem
            } catch {
                serverProblem = "decision request failed: \(error.localizedDescription)"
            }
            guard self.request == request else { return }
        }

        // Send Plex identity + token on every request, including the HLS playlists and
        // segments the server links to with relative URLs (which drop our query string).
        var headers = PlexClientInfo.headers(token: api.server.token)
        headers["X-Plex-Platform"] = "iOS"
        headers.removeValue(forKey: "Accept")
        if let transcodeSession { headers["X-Plex-Session-Identifier"] = transcodeSession }
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 0
        pendingStartSeconds = seconds
        didStartPlayback = false
        observe(playerItem)
        player.replaceCurrentItem(with: playerItem)
        if seconds <= 0 { player.play() }
    }

    // MARK: Tracks

    func selectAudio(_ id: Int) async {
        guard id != selectedAudioID else { return }
        await changeTracks(audio: id, subtitle: selectedSubtitleID)
    }

    func selectSubtitle(_ id: Int?) async {
        guard id != selectedSubtitleID else { return }
        await changeTracks(audio: selectedAudioID, subtitle: id)
    }

    private func changeTracks(audio: Int?, subtitle: Int?) async {
        guard let item, let api, let part = item.firstPart else { return }
        let previous = (selectedAudioID, selectedSubtitleID)
        selectedAudioID = audio
        selectedSubtitleID = subtitle

        // Direct play: switch inside the file when AVPlayer can.
        let subtitleIsDirect = selectedSubtitle.map(PlaybackDecider.isDirectPlayable) ?? true
        if !isTranscoding, subtitleIsDirect, await applyDirectSelection() { return }

        // Otherwise save the choice on the server and restart through the transcoder,
        // which burns in subtitles and mixes the chosen audio track.
        isSwitchingTracks = true
        defer { isSwitchingTracks = false }
        do {
            try await api.selectStreams(partID: part.id, audioStreamID: audio, subtitleStreamID: subtitle ?? 0)
        } catch {
            (selectedAudioID, selectedSubtitleID) = previous
            return
        }
        let resumeAt = currentTime
        if let old = transcodeSession { try? await api.stopTranscode(session: old) }
        do {
            try await start(item: item, at: resumeAt, forceTranscode: true)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Selects the chosen tracks in the file AVPlayer is reading directly.
    /// Returns false when the file's tracks can't be matched to Plex's list.
    private func applyDirectSelection() async -> Bool {
        guard let playerItem = player.currentItem else { return false }
        let asset = playerItem.asset

        if audioTracks.count > 1, let audioID = selectedAudioID {
            guard let group = try? await asset.loadMediaSelectionGroup(for: .audible),
                  group.options.count == audioTracks.count,
                  let position = audioTracks.firstIndex(where: { $0.id == audioID })
            else { return false }
            playerItem.select(group.options[position], in: group)
        }

        let embedded = subtitleTracks.filter(PlaybackDecider.isDirectPlayable)
        let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
        if let subtitleID = selectedSubtitleID {
            guard let legible, legible.options.count == embedded.count,
                  let position = embedded.firstIndex(where: { $0.id == subtitleID })
            else { return false }
            playerItem.select(legible.options[position], in: legible)
        } else if let legible, legible.allowsEmptySelection {
            playerItem.select(nil, in: legible)
        }
        return true
    }

    // MARK: Transport

    func togglePlayPause() {
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(to seconds: Double) {
        let target = max(0, min(seconds, duration > 0 ? duration - 1 : seconds))
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(by delta: Double) { seek(to: currentTime + delta) }

    /// Stops playback, tells the server, and resets.
    func stop() async {
        guard let item, let api else { reset(); return }
        let time = currentTime, total = duration
        let session = transcodeSession
        player.pause()
        player.replaceCurrentItem(with: nil)

        try? await api.timeline(ratingKey: item.ratingKey, state: "stopped", timeMs: Int(time * 1000), durationMs: Int(total * 1000), session: session)
        if !didScrobble, total > 0, time / total > 0.9 {
            try? await api.setWatched(item.ratingKey, watched: true)
        }
        if let session { try? await api.stopTranscode(session: session) }
        reset()
    }

    private func reset() {
        teardownItemObservers()
        item = nil
        request = nil
        status = .idle
        isPlaying = false
        isBuffering = false
        currentTime = 0
        duration = 0
        transcodeSession = nil
        serverProblem = nil
        directPlayFailed = false
        audioTracks = []
        subtitleTracks = []
        selectedAudioID = nil
        selectedSubtitleID = nil
        isSwitchingTracks = false
        didScrobble = false
        reportedState = ""
        videoAspect = 16.0 / 9.0
    }

    // MARK: Observation

    private func observe(_ playerItem: AVPlayerItem) {
        observations.append(playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in self?.itemStatusChanged(item) }
        })
        observations.append(playerItem.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            let size = item.presentationSize
            guard size.width > 0, size.height > 0 else { return }
            Task { @MainActor in self?.videoAspect = Double(size.width / size.height) }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in self?.timeControlChanged(status) }
        })

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }

        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didReachEnd() }
        }

        // Some files fail mid-stream rather than up front.
        failObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: playerItem, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            MainActor.assumeIsolated { self?.playbackFailed(playerItem, error: error) }
        }
    }

    private func teardownItemObservers() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        failObserver = nil
    }

    private func itemStatusChanged(_ playerItem: AVPlayerItem) {
        switch playerItem.status {
        case .readyToPlay:
            if !didStartPlayback {
                didStartPlayback = true
                status = .playing
                if pendingStartSeconds > 0 {
                    let start = pendingStartSeconds
                    pendingStartSeconds = 0
                    player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        Task { @MainActor in self?.player.play() }
                    }
                    currentTime = start
                } else {
                    player.play()
                }
                if !isTranscoding {
                    Task { await applyInitialDirectSelection() }
                }
            }
        case .failed:
            playbackFailed(playerItem, error: playerItem.error)
        default:
            break
        }
    }

    /// Matches the file's tracks to Plex's selection; if a chosen subtitle can't be
    /// shown this way, switch to the transcoder so it gets burned in.
    private func applyInitialDirectSelection() async {
        if await applyDirectSelection() { return }
        guard selectedSubtitleID != nil, let item else { return }
        do { try await start(item: item, at: currentTime, forceTranscode: true) } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func playbackFailed(_ playerItem: AVPlayerItem, error: Error?) {
        guard playerItem === player.currentItem else { return }
        // Direct play can fail on files AVPlayer doesn't like; fall back to the transcoder once.
        if !isTranscoding, let item {
            directPlayFailed = true
            let resumeAt = max(currentTime, pendingStartSeconds)
            Task {
                do { try await start(item: item, at: resumeAt, forceTranscode: true) } catch {
                    status = .failed(error.localizedDescription)
                }
            }
            return
        }
        status = .failed(failureMessage(playerItem, error: error))
    }

    /// Plain-language reason plus the technical details that help diagnose a failure.
    private func failureMessage(_ playerItem: AVPlayerItem, error: Error?) -> String {
        var lines = ["This video couldn’t be played."]
        if let serverProblem { lines.append("Server: \(serverProblem)") }
        if let error = error ?? playerItem.error {
            let ns = error as NSError
            var detail = ns.localizedDescription
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                detail += " (\(underlying.domain) \(underlying.code))"
            } else {
                detail += " (\(ns.domain) \(ns.code))"
            }
            lines.append(detail)
        }
        if let event = playerItem.errorLog()?.events.last {
            var log = "Stream error \(event.errorStatusCode)"
            if let comment = event.errorComment { log += ": \(comment)" }
            // Which request failed (path only, never the token).
            if let uri = event.uri, let path = URLComponents(string: uri)?.path, !path.isEmpty {
                log += " [\(path.split(separator: "/").suffix(2).joined(separator: "/"))]"
            }
            lines.append(log)
        }
        if let access = playerItem.accessLog()?.events.last {
            let mb = Double(max(0, access.numberOfBytesTransferred)) / 1_000_000
            lines.append(String(format: "Received %.1f MB", mb))
        }
        var media: [String] = [isTranscoding ? "Converting" : "Direct play"]
        if let m = item?.media?.first {
            media += [m.container, m.videoCodec, m.audioCodec, m.videoResolution].compactMap { $0 }
        }
        if let text = serverDecision?.transcodeDecisionText ?? serverDecision?.generalDecisionText {
            media.append(text)
        }
        lines.append(media.joined(separator: " · "))
        return lines.joined(separator: "\n")
    }

    private func timeControlChanged(_ tc: AVPlayer.TimeControlStatus) {
        isPlaying = tc == .playing
        isBuffering = tc == .waitingToPlayAtSpecifiedRate
        if tc == .playing { report("playing", force: reportedState != "playing") }
        if tc == .paused, didStartPlayback { report("paused", force: reportedState != "paused") }
    }

    private func tick(_ time: CMTime) {
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        currentTime = seconds
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        if isPlaying { report("playing", force: false) }
    }

    private func didReachEnd() {
        guard let item, let api else { return }
        didScrobble = true
        let total = Int(duration * 1000)
        let session = transcodeSession
        Task {
            try? await api.timeline(ratingKey: item.ratingKey, state: "stopped", timeMs: total, durationMs: total, session: session)
            try? await api.setWatched(item.ratingKey, watched: true)
        }
        isPlaying = false
    }

    /// Sends `/:/timeline` every 10 s while playing, and immediately on state changes.
    private func report(_ state: String, force: Bool) {
        guard let item, let api else { return }
        guard force || Date().timeIntervalSince(lastReport) >= 10 else { return }
        lastReport = Date()
        reportedState = state
        let t = Int(currentTime * 1000), d = Int(duration * 1000), session = transcodeSession
        Task { try? await api.timeline(ratingKey: item.ratingKey, state: state, timeMs: t, durationMs: d, session: session) }
    }
}
