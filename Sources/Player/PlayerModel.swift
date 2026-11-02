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

    /// Set by the player window so play buttons can reuse it.
    var isWindowOpen = false

    // Internal state
    private var api: PlexAPI?
    private var request: PlayRequest?
    private var transcodeSession: String?
    private var pendingStartSeconds: Double = 0
    private var didStartPlayback = false
    private var didScrobble = false
    private var lastReport = Date.distantPast
    private var reportedState = ""

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var observations: [NSKeyValueObservation] = []

    init() {
        // allowsExternalPlayback / preventsDisplaySleepDuringVideoPlayback are
        // unavailable on visionOS; the system manages both there.
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
            try start(item: item, at: Double(request.startMs) / 1000, forceTranscode: false)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func start(item: PlexMetadata, at seconds: Double, forceTranscode: Bool) throws {
        guard let api else { return }
        teardownItemObservers()

        let route = try PlaybackDecider.route(for: item, api: api, forceTranscode: forceTranscode)
        let url: URL
        switch route {
        case .direct(let u):
            url = u
            isTranscoding = false
            transcodeSession = nil
        case .transcode(let u, let session):
            url = u
            isTranscoding = true
            transcodeSession = session
        }

        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 0
        pendingStartSeconds = seconds
        didStartPlayback = false
        observe(playerItem)
        player.replaceCurrentItem(with: playerItem)
        if seconds <= 0 { player.play() }
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
    }

    private func teardownItemObservers() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
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
            }
        case .failed:
            // Direct play can fail on files AVPlayer doesn't like; fall back to the transcoder once.
            if !isTranscoding, let item {
                let resumeAt = max(currentTime, pendingStartSeconds)
                do { try start(item: item, at: resumeAt, forceTranscode: true) } catch {
                    status = .failed(error.localizedDescription)
                }
            } else {
                status = .failed(playerItem.error?.localizedDescription ?? "Playback failed.")
            }
        default:
            break
        }
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
