import Photos
import SwiftUI

/// Streams an asset's image from `PHCachingImageManager`: opportunistic for the card,
/// high quality when `highQuality` flips on (zoom). Keeps the previous image on screen
/// while the sharper one loads.
struct AssetImageView: View {
    let asset: PHAsset
    var highQuality = false
    var contentMode: ContentMode = .fit

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task(id: LoadKey(id: asset.localIdentifier, highQuality: highQuality, size: proxy.size)) {
                await load(size: proxy.size)
            }
        }
    }

    private struct LoadKey: Equatable {
        let id: String
        let highQuality: Bool
        let size: CGSize
    }

    private func load(size: CGSize) async {
        guard size.width > 0, size.height > 0 else { return }
        let target: CGSize
        if highQuality {
            // Full resolution, capped so a 48MP image doesn't blow memory.
            let cap: CGFloat = 4096
            let w = CGFloat(asset.pixelWidth), h = CGFloat(asset.pixelHeight)
            let factor = min(1, cap / max(w, h, 1))
            target = CGSize(width: w * factor, height: h * factor)
        } else {
            target = CGSize(width: size.width * displayScale, height: size.height * displayScale)
        }
        let mode: PHImageContentMode = contentMode == .fill ? .aspectFill : .aspectFit
        for await next in ImageLoader.shared.images(for: asset, targetSize: target, highQuality: highQuality, contentMode: mode) {
            image = next
        }
    }
}
