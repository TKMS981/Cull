import Photos
import SwiftUI

/// VoiceOver description of a card's media: one element with a label, value and
/// custom actions. Applied to the media only, so a video's seek bar stays its own control.
struct CardAccessibility {
    struct Action {
        let name: Text
        let handler: () -> Void
    }

    var label: Text
    var value: String
    var identifier: String
    var actions: [Action] = []
}

/// One full-bleed card: photo, Live Photo or video, inside the zoom container.
/// A playing video gets a seek bar along the bottom, outside the zoom container
/// so it doesn't scale with the image.
struct MediaCardView: View {
    let asset: PHAsset
    let isActive: Bool
    @Binding var isZoomed: Bool
    let isMuted: Bool
    var onToggleMute: () -> Void = {}
    var onPinchingChange: ((Bool) -> Void)? = nil
    /// Reports when the seek bar starts and stops scrubbing, so the deck can fence off the swipe.
    var onScrubbingChange: ((Bool) -> Void)? = nil
    var accessibility: CardAccessibility? = nil

    @State private var playback = VideoPlayback()

    var body: some View {
        ZStack(alignment: .bottom) {
            ZoomableContainer(
                isZoomed: $isZoomed,
                onSingleTap: asset.hasAudio ? onToggleMute : nil,
                onPinchingChange: onPinchingChange
            ) {
                content
            }
            .background(.black)
            .modifier(CardAccessibilityModifier(config: accessibility))

            if asset.isVideo, isActive, playback.player != nil {
                VideoSeekBar(playback: playback) { onScrubbingChange?($0) }
                    .transition(.opacity)
            }
        }
        .clipShape(.rect(cornerRadius: 24))
        .animation(.smooth(duration: 0.2), value: playback.player != nil)
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

private struct CardAccessibilityModifier: ViewModifier {
    let config: CardAccessibility?

    func body(content: Content) -> some View {
        if let config {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(config.label)
                .accessibilityValue(config.value)
                .accessibilityIdentifier(config.identifier)
                .accessibilityAddTraits(.isImage)
                .accessibilityActions {
                    ForEach(config.actions.indices, id: \.self) { index in
                        Button(action: config.actions[index].handler) { config.actions[index].name }
                    }
                }
        } else {
            content
        }
    }
}
