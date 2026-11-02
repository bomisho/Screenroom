import AVFoundation
import SwiftUI
import UIKit

/// The floating video window. Its shape follows the video's aspect ratio, so there are no black bars.
struct PlayerWindow: View {
    let request: PlayRequest?

    @Environment(AppModel.self) private var model
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(player: player.player)
            statusOverlay
        }
        .clipShape(.rect(cornerRadius: 28))
        .frame(minWidth: 480, idealWidth: 1600, maxWidth: 6000,
               minHeight: 480 / player.videoAspect, idealHeight: 1600 / player.videoAspect, maxHeight: 6000 / player.videoAspect)
        .aspectRatio(player.videoAspect, contentMode: .fit)
        .contentShape(.rect)
        .onTapGesture { showControls(toggle: true) }
        .ornament(visibility: controlsVisible ? .visible : .hidden,
                  attachmentAnchor: .scene(.bottom),
                  contentAlignment: .top) {
            PlayerControls(onClose: close, onInteract: { showControls(toggle: false) })
                .padding(.top, 24)
        }
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        .task(id: request) {
            guard let request, let api = model.api else { return }
            await player.load(request, api: api)
            scheduleHide()
        }
        .onAppear { player.isWindowOpen = true }
        .onDisappear {
            player.isWindowOpen = false
            hideTask?.cancel()
            Task {
                await player.stop()
                if player.isRoomDimmed {
                    await dismissImmersiveSpace()
                    player.isRoomDimmed = false
                }
            }
        }
        .onChange(of: player.isPlaying) { _, playing in
            if playing { scheduleHide() } else { showControls(toggle: false) }
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch player.status {
        case .loading:
            ProgressView().controlSize(.large).tint(.white)
        case .failed(let message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text(message).multilineTextAlignment(.center)
                Button("Close", action: close)
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(40)
        default:
            if player.isBuffering { ProgressView().controlSize(.large).tint(.white) }
        }
    }

    private func showControls(toggle: Bool) {
        if toggle && controlsVisible {
            controlsVisible = false
            hideTask?.cancel()
        } else {
            controlsVisible = true
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, player.isPlaying, !player.isTrackMenuOpen else { return }
            controlsVisible = false
        }
    }

    private func close() {
        dismissWindow(id: SceneID.player)
    }
}

/// AVPlayerLayer hosted in SwiftUI (we draw our own controls).
struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
