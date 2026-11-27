import AVFoundation
import Photos
import SwiftUI

/// Autoplaying looping video (muted until the user turns sound on). Shows the
/// poster frame until the player is ready. Playback state lives in `VideoPlayback`,
/// which the enclosing card owns so its seek bar can sit outside the zoom container.
struct VideoCardView: View {
    let asset: PHAsset
    let isActive: Bool
    @Bindable var playback: VideoPlayback
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            AssetImageView(asset: asset)
            if let player = playback.player, isActive {
                PlayerLayerView(player: player, isReady: $playback.isReady)
                    .opacity(playback.isReady ? 1 : 0)
            }
            if isActive, playback.isCloudOnly {
                CloudOnlyNote(text: "このビデオは iCloud にあるため再生できません")
            }
        }
        // The player only exists while this is the top card and the app is in front:
        // in the background it's released (position kept) instead of left paused.
        .task(id: PlayKey(isActive: isActive, isForeground: scenePhase == .active)) {
            guard isActive else { return playback.stop() }
            guard scenePhase == .active else { return playback.suspend() }
            await playback.start(asset: asset)
        }
        .onDisappear { playback.stop() }
    }
}

private struct PlayKey: Equatable {
    let isActive: Bool
    let isForeground: Bool
}

/// Bridges `AVPlayerLayer` because SwiftUI's `VideoPlayer` always installs
/// transport controls that swallow the card's swipe and zoom gestures.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    @Binding var isReady: Bool

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.isUserInteractionEnabled = false
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        context.coordinator.observe(view.playerLayer)
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(isReady: $isReady) }

    final class Coordinator {
        private var observation: NSKeyValueObservation?
        private let isReady: Binding<Bool>

        init(isReady: Binding<Bool>) { self.isReady = isReady }

        func observe(_ layer: AVPlayerLayer) {
            let binding = isReady
            observation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
                let ready = layer.isReadyForDisplay
                Task { @MainActor in binding.wrappedValue = ready }
            }
        }
    }

    final class PlayerUIView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
