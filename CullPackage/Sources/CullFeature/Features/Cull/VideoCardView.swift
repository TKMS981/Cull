import AVFoundation
import Photos
import SwiftUI

/// Muted autoplay looping video. Shows the poster frame until the player is ready.
struct VideoCardView: View {
    let asset: PHAsset
    let isActive: Bool
    let isMuted: Bool

    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var isReady = false

    var body: some View {
        ZStack {
            AssetImageView(asset: asset)
            if let player, isActive {
                PlayerLayerView(player: player, isReady: $isReady)
                    .opacity(isReady ? 1 : 0)
            }
        }
        .task(id: isActive) {
            guard isActive else { return stop() }
            await start()
        }
        .onChange(of: isMuted) { _, muted in player?.isMuted = muted }
        .onDisappear { stop() }
    }

    private func start() async {
        guard player == nil, let avAsset = await ImageLoader.shared.videoAsset(for: asset), !Task.isCancelled else { return }
        let item = AVPlayerItem(asset: avAsset)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = isMuted
        looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        player = queuePlayer
        queuePlayer.play()
    }

    private func stop() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        isReady = false
    }
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
