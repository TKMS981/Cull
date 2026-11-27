import Photos
import SwiftUI

/// One full-bleed card: photo, Live Photo or video, inside the zoom container.
struct MediaCardView: View {
    let asset: PHAsset
    let isActive: Bool
    @Binding var isZoomed: Bool
    let isMuted: Bool
    var onToggleMute: () -> Void = {}
    var onPinchingChange: ((Bool) -> Void)? = nil

    @State private var playback = VideoPlayback()

    var body: some View {
        ZoomableContainer(
            isZoomed: $isZoomed,
            onSingleTap: asset.hasAudio ? onToggleMute : nil,
            onPinchingChange: onPinchingChange
        ) {
            content
        }
        .background(.black)
        .clipShape(.rect(cornerRadius: 24))
        .onChange(of: isMuted, initial: true) { _, muted in playback.isMuted = muted }
    }

    @ViewBuilder
    private var content: some View {
        if asset.mediaType == .video {
            VideoCardView(asset: asset, isActive: isActive, playback: playback)
        } else if asset.mediaSubtypes.contains(.photoLive) {
            LivePhotoCardView(asset: asset, isActive: isActive, isMuted: isMuted, highQuality: isZoomed)
        } else {
            AssetImageView(asset: asset, highQuality: isZoomed)
        }
    }
}

extension PHAsset {
    var isVideo: Bool { mediaType == .video }
    var isLivePhoto: Bool { mediaSubtypes.contains(.photoLive) }
    var hasAudio: Bool { isVideo || isLivePhoto }

    var accessibilityKind: String {
        if isVideo { return String(localized: "ビデオ") }
        if isLivePhoto { return String(localized: "Live Photo") }
        if mediaSubtypes.contains(.photoScreenshot) { return String(localized: "スクリーンショット") }
        return String(localized: "写真")
    }
}
