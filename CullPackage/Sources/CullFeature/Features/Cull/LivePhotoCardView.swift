import Photos
import PhotosUI
import SwiftUI

/// Live Photo card: still image first, then a `PHLivePhotoView` that plays a short
/// hint when the card becomes active. Touch-and-hold plays the full Live Photo.
///
/// `PHLivePhotoView`'s own touch handling is switched off: as a UIKit view it
/// receives touches outside SwiftUI's gesture system and can hold up the card's
/// swipe. Touch-and-hold is a SwiftUI long press instead, which fails as soon as
/// the finger moves, so swiping always wins.
struct LivePhotoCardView: View {
    let asset: PHAsset
    let isActive: Bool
    let isMuted: Bool
    let highQuality: Bool

    @Environment(\.displayScale) private var displayScale
    @State private var livePhoto: PHLivePhoto?
    @State private var isHolding = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AssetImageView(asset: asset, highQuality: highQuality)
                if let livePhoto, isActive {
                    LivePhotoRepresentable(livePhoto: livePhoto, isMuted: isMuted, playsFully: isHolding)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
            .onLongPressGesture(minimumDuration: 0.3, maximumDistance: 10) {
                isHolding = true
            } onPressingChanged: { pressing in
                if !pressing { isHolding = false }
            }
            .task(id: isActive) {
                guard isActive else { return }
                let target = CGSize(width: proxy.size.width * displayScale, height: proxy.size.height * displayScale)
                for await next in ImageLoader.shared.livePhoto(for: asset, targetSize: target) {
                    livePhoto = next
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Label("LIVE", systemImage: "livephoto")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
                .padding(12)
                .accessibilityHidden(true)
        }
    }
}

/// `PHLivePhotoView` has no SwiftUI counterpart, so it's bridged here.
private struct LivePhotoRepresentable: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    let isMuted: Bool
    /// Full playback while the finger is held down; stops on release.
    let playsFully: Bool

    final class Coordinator {
        var isPlayingFully = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        // Touches go to the SwiftUI card (swipe, zoom, long press), never to this view.
        view.isUserInteractionEnabled = false
        view.contentMode = .scaleAspectFit
        view.livePhoto = livePhoto
        view.isMuted = isMuted
        // The enclosing card is a single accessibility element; keep the UIKit
        // subtree (and its internal views) out of the accessibility tree.
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.startPlayback(with: .hint)
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        if view.livePhoto !== livePhoto { view.livePhoto = livePhoto }
        view.isMuted = isMuted
        if playsFully != context.coordinator.isPlayingFully {
            context.coordinator.isPlayingFully = playsFully
            if playsFully { view.startPlayback(with: .full) } else { view.stopPlayback() }
        }
    }
}
