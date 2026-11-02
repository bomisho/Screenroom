import SwiftUI

/// Dark, low-contrast transport controls shown in an ornament under the video.
struct PlayerControls: View {
    var onClose: () -> Void
    var onInteract: () -> Void

    @Environment(PlayerModel.self) private var player
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    private let dim = Color.white.opacity(0.78)
    private let faint = Color.white.opacity(0.5)

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.title).font(.headline).foregroundStyle(dim).lineLimit(1)
                    if let sub = player.subtitle {
                        Text(sub).font(.subheadline).foregroundStyle(faint).lineLimit(1)
                    }
                }
                Spacer()
                if player.isTranscoding {
                    Text("Transcoding").font(.caption).foregroundStyle(faint)
                }
            }

            HStack(spacing: 14) {
                Text(Format.timecode(isScrubbing ? scrubValue : player.currentTime))
                    .monospacedDigit()
                    .frame(width: 84, alignment: .trailing)
                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubValue : player.currentTime },
                        set: { scrubValue = $0; onInteract() }
                    ),
                    in: 0...max(player.duration, 1),
                    onEditingChanged: { editing in
                        if editing {
                            scrubValue = player.currentTime
                            isScrubbing = true
                        } else {
                            player.seek(to: scrubValue)
                            isScrubbing = false
                        }
                    }
                )
                .tint(.white.opacity(0.55))
                Text("-" + Format.timecode(max(0, player.duration - (isScrubbing ? scrubValue : player.currentTime))))
                    .monospacedDigit()
                    .frame(width: 92, alignment: .leading)
            }
            .font(.callout)
            .foregroundStyle(faint)

            HStack(spacing: 28) {
                controlButton("gobackward.10") { player.skip(by: -10) }
                controlButton(player.isPlaying ? "pause.fill" : "play.fill", size: 34) { player.togglePlayPause() }
                controlButton("goforward.10") { player.skip(by: 10) }
                Spacer().frame(width: 40)
                audioMenu
                subtitleMenu
                controlButton(player.isRoomDimmed ? "lightbulb.slash.fill" : "lightbulb") {
                    Task { await toggleDimming() }
                }
                .accessibilityLabel(player.isRoomDimmed ? "Brighten room" : "Dim room")
                controlButton("xmark") { onClose() }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .frame(width: 900)
        .background(.black.opacity(0.62), in: .rect(cornerRadius: 32))
        .overlay(RoundedRectangle(cornerRadius: 32).strokeBorder(.white.opacity(0.08)))
    }

    // MARK: Tracks

    private var audioMenu: some View {
        Menu {
            Picker("Audio", selection: Binding(
                get: { player.selectedAudioID },
                set: { id in
                    onInteract()
                    if let id { Task { await player.selectAudio(id) } }
                }
            )) {
                ForEach(player.audioTracks) { track in
                    Text(track.label).tag(Optional(track.id))
                }
            }
            .pickerStyle(.inline)
            .onAppear { player.isTrackMenuOpen = true }
            .onDisappear { player.isTrackMenuOpen = false; onInteract() }
        } label: {
            menuLabel("speaker.wave.2")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(player.audioTracks.count < 2 || player.isSwitchingTracks)
        .accessibilityLabel("Audio")
    }

    private var subtitleMenu: some View {
        Menu {
            Picker("Subtitles", selection: Binding(
                get: { player.selectedSubtitleID },
                set: { id in
                    onInteract()
                    Task { await player.selectSubtitle(id) }
                }
            )) {
                Text("Off").tag(Int?.none)
                ForEach(player.subtitleTracks) { track in
                    Text(track.label).tag(Optional(track.id))
                }
            }
            .pickerStyle(.inline)
            .onAppear { player.isTrackMenuOpen = true }
            .onDisappear { player.isTrackMenuOpen = false; onInteract() }
        } label: {
            menuLabel(player.selectedSubtitleID == nil ? "captions.bubble" : "captions.bubble.fill")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(player.subtitleTracks.isEmpty || player.isSwitchingTracks)
        .accessibilityLabel("Subtitles")
    }

    private func menuLabel(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(dim)
            .frame(width: 60, height: 60)
            .contentShape(.circle)
            .hoverEffect(.highlight)
    }

    // MARK: Room

    private func toggleDimming() async {
        if player.isRoomDimmed {
            await dismissImmersiveSpace()
            player.isRoomDimmed = false
        } else if case .opened = await openImmersiveSpace(id: SceneID.theater) {
            player.isRoomDimmed = true
        }
    }

    private func controlButton(_ symbol: String, size: CGFloat = 24, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onInteract()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(dim)
                .frame(width: 60, height: 60)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .clipShape(.circle)
    }
}
