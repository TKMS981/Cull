import Photos
import SwiftUI

/// Cull's trash: grid of assets swiped right. Multi-select to restore them to the
/// queue or delete them for real (system confirmation → Recently Deleted).
struct TrashView: View {
    /// Called with restored IDs so an active session can re-queue them.
    var onRestore: (([String]) -> Void)?

    @Environment(DecisionStore.self) private var store
    @Environment(PhotoLibraryService.self) private var library

    @State private var assets: [String: PHAsset] = [:]
    @State private var selection: Set<String> = []
    @State private var isSelecting = false
    @State private var isDeleting = false
    @State private var errorMessage: String?
    /// Bytes per trashed asset, filled in off the main actor.
    @State private var sizes: [String: Int64] = [:]
    @State private var preview: PreviewItem?
    @Namespace private var previewNamespace

    private struct PreviewItem: Identifiable { let id: String }

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    private var entries: [TrashEntry] { store.trash.filter { assets[$0.id] != nil } }

    var body: some View {
        Group {
            if store.trash.isEmpty {
                ContentUnavailableView("ゴミ箱は空です", systemImage: "trash", description: Text("右にスワイプした写真がここに表示されます。"))
            } else {
                ScrollView {
                    sizeSummary
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(entries) { entry in
                            if let asset = assets[entry.id] {
                                cell(asset)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(isSelecting ? Text("\(selection.count) 件を選択") : Text("ゴミ箱"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task(id: store.trash) {
            assets = library.assets(withIDs: store.trash.map(\.id))
            selection.formIntersection(assets.keys)
            let missing = assets.keys.filter { sizes[$0] == nil }
            let measured = await AssetSizeReader.bytes(forIDs: Array(missing))
            sizes.merge(measured) { _, new in new }
        }
        .fullScreenCover(item: $preview) { item in
            if let asset = assets[item.id] {
                AssetPreviewView(
                    asset: asset,
                    size: sizes[item.id],
                    primary: .init(title: "元に戻す", systemImage: "arrow.uturn.backward", identifier: "previewRestoreButton") {
                        restore(ids: [item.id])
                    },
                    // Closes itself on success (see delete); stays open if the system dialog is cancelled.
                    secondary: .init(title: "削除", systemImage: "trash", role: .destructive, identifier: "previewDeleteButton",
                                     dismissesAfter: false) {
                        await delete(ids: [item.id])
                    },
                    identifier: "trashPreview"
                )
                .navigationTransition(.zoom(sourceID: item.id, in: previewNamespace))
            }
        }
        .alert("削除できませんでした", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func cell(_ asset: PHAsset) -> some View {
        let id = asset.localIdentifier
        let isSelected = selection.contains(id)
        return Button {
            if isSelecting {
                if isSelected { selection.remove(id) } else { selection.insert(id) }
            } else {
                preview = PreviewItem(id: id)
            }
        } label: {
            AssetGridThumbnail(asset: asset, isSelecting: isSelecting, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: id, in: previewNamespace)
        .accessibilityLabel(Text(asset.accessibilityKind))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("trashCell")
    }

    /// "About 12.3 MB can be freed": for the selection while selecting, else the whole trash.
    private var sizeSummary: some View {
        let ids = isSelecting && !selection.isEmpty ? Array(selection) : entries.map(\.id)
        let known = ids.compactMap { sizes[$0] }
        let total = known.reduce(0, +)
        let isMeasuring = known.count < ids.count && !ids.isEmpty
        return HStack(spacing: 12) {
            Image(systemName: "internaldrive")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if isSelecting && !selection.isEmpty {
                        Text("選択中：約 \(total.formatted(.byteCount(style: .file))) 削減可能")
                    } else {
                        Text("約 \(total.formatted(.byteCount(style: .file))) 削減可能")
                    }
                }
                .font(.headline)
                .contentTransition(.numericText())
                .animation(.smooth, value: total)
                Text("削除すると「最近削除した項目」に移動し、30日後に完全に削除されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isMeasuring {
                ProgressView().accessibilityLabel(Text("サイズを計算中…"))
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("trashSizeSummary")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !store.trash.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isSelecting.toggle()
                    if !isSelecting { selection.removeAll() }
                } label: {
                    isSelecting ? Text("完了") : Text("選択")
                }
                .accessibilityIdentifier("selectButton")
            }
        }
        if isSelecting {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    selection = selection.count == entries.count ? [] : Set(entries.map(\.id))
                } label: {
                    selection.count == entries.count ? Text("選択解除") : Text("すべて選択")
                }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("元に戻す", systemImage: "arrow.uturn.backward") { restore(ids: Array(selection)) }
                    .disabled(selection.isEmpty)
                    .accessibilityIdentifier("restoreButton")
            }
            ToolbarItem(placement: .bottomBar) {
                Button("削除", systemImage: "trash", role: .destructive) {
                    Task { await delete(ids: Array(selection)) }
                }
                .disabled(selection.isEmpty || isDeleting)
                .accessibilityIdentifier("deleteButton")
            }
        }
    }

    private func restore(ids: [String]) {
        store.clear(ids: ids)
        onRestore?(ids)
        selection.subtract(ids)
        if store.trash.isEmpty { isSelecting = false }
    }

    private func delete(ids: [String]) async {
        isDeleting = true
        defer { isDeleting = false }
        // Sizes have to be read before the delete: afterwards the assets are gone.
        let missing = ids.filter { sizes[$0] == nil }
        if !missing.isEmpty { sizes.merge(await AssetSizeReader.bytes(forIDs: missing)) { _, new in new } }
        let bytes = ids.compactMap { sizes[$0] }.reduce(0, +)
        switch await DeletionService.delete(ids: ids) {
        case .deleted:
            store.recordDeletion(count: ids.count, bytes: bytes)
            store.clear(ids: ids)
            selection.subtract(ids)
            if let preview, ids.contains(preview.id) { self.preview = nil }
            if store.trash.isEmpty { isSelecting = false }
        case .cancelled:
            break
        case .failed(let message):
            errorMessage = message
        }
    }
}
