import Photos
import SwiftUI

/// A bottom-bar action in `AssetPreviewView`.
struct PreviewAction {
    var title: LocalizedStringKey
    var systemImage: String
    var role: ButtonRole?
    var identifier: String
    /// Close the preview once the action has run (otherwise the caller decides).
    var dismissesAfter: Bool
    var handler: () async -> Void

    init(title: LocalizedStringKey, systemImage: String, role: ButtonRole? = nil, identifier: String,
         dismissesAfter: Bool = true, handler: @escaping () async -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.identifier = identifier
        self.dismissesAfter = dismissesAfter
        self.handler = handler
    }
}

/// Full-screen look at one item, with two actions (trash: restore / delete;
/// kept: un-keep / move to trash). Reuses the culling card, so zoom, Live Photo,
/// video and its seek bar all work here too.
struct AssetPreviewView: View {
    let asset: PHAsset
    let size: Int64?
    let primary: PreviewAction
    let secondary: PreviewAction
    /// Accessibility identifier of the media element.
    let identifier: String

    @Environment(\.dismiss) private var dismiss
    @State private var isZoomed = false
    @State private var isMuted = true
    @State private var isBusy = false

    var body: some View {
        NavigationStack {
            MediaCardView(
                asset: asset,
                isActive: true,
                isZoomed: $isZoomed,
                isMuted: isMuted,
                onToggleMute: { isMuted.toggle() },
                accessibility: CardAccessibility(
                    label: Text(asset.accessibilityKind),
                    value: isZoomed ? "zoomed" : "fit",
                    identifier: identifier
                )
            )
            .padding(.horizontal, 8)
            .audioSessionAudible(!isMuted && asset.hasAudio)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                        .accessibilityIdentifier("previewCloseButton")
                }
                ToolbarItem(placement: .principal) { header }
                ToolbarItem(placement: .bottomBar) { button(primary) }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) { button(secondary) }
            }
        }
    }

    private func button(_ action: PreviewAction) -> some View {
        Button(action.title, systemImage: action.systemImage, role: action.role) {
            Task {
                isBusy = true
                await action.handler()
                isBusy = false
                if action.dismissesAfter { dismiss() }
            }
        }
        .disabled(isBusy)
        .accessibilityIdentifier(action.identifier)
    }

    private var header: some View {
        VStack(spacing: 2) {
            if let date = asset.creationDate {
                Text(date, format: .dateTime.year().month().day().hour().minute())
                    .font(.subheadline.weight(.semibold))
            }
            if let size {
                Text(size, format: .byteCount(style: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
