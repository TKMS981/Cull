import Photos
import SwiftUI

/// Full-screen look at one trashed item before restoring or deleting it.
/// Reuses the culling card, so pinch / double-tap zoom, Live Photo and video work here too.
struct TrashPreviewView: View {
    let asset: PHAsset
    let size: Int64?
    var onRestore: () -> Void
    var onDelete: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isZoomed = false
    @State private var isMuted = true
    @State private var isDeleting = false

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
                    identifier: "trashPreview"
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
                ToolbarItem(placement: .bottomBar) {
                    Button("元に戻す", systemImage: "arrow.uturn.backward") {
                        onRestore()
                        dismiss()
                    }
                    .accessibilityIdentifier("previewRestoreButton")
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button("削除", systemImage: "trash", role: .destructive) {
                        Task {
                            isDeleting = true
                            await onDelete()
                            isDeleting = false
                        }
                    }
                    .disabled(isDeleting)
                    .accessibilityIdentifier("previewDeleteButton")
                }
            }
        }
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
