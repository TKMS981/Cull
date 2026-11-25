import Photos
import PhotosUI
import SwiftUI

/// Live Photo card: still image first, then a `PHLivePhotoView` that plays a short
/// hint when the card becomes active. Touch-and-hold plays the full Live Photo
/// (built into `PHLivePhotoView`).
struct LivePhotoCardView: View {
    let asset: PHAsset
    let isActive: Bool
    let isMuted: Bool
    let highQuality: Bool

    @Environment(\.displayScale) private var displayScale
    @State private var livePhoto: PHLivePhoto?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AssetImageView(asset: asset, highQuality: highQuality)
                if let livePhoto, isActive {
                    LivePhotoRepresentable(livePhoto: livePhoto, isMuted: isMuted)
                }
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

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        view.livePhoto = livePhoto
        view.isMuted = isMuted
        view.startPlayback(with: .hint)
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        if view.livePhoto !== livePhoto { view.livePhoto = livePhoto }
        view.isMuted = isMuted
    }
}
