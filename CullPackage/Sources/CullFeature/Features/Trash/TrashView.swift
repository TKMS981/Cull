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

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    private var entries: [TrashEntry] { store.trash.filter { assets[$0.id] != nil } }

    var body: some View {
        Group {
            if store.trash.isEmpty {
                ContentUnavailableView("ゴミ箱は空です", systemImage: "trash", description: Text("右にスワイプした写真がここに表示されます。"))
            } else {
                ScrollView {
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
        .navigationTitle(isSelecting ? "\(selection.count) 件を選択" : "ゴミ箱")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task(id: store.trash) {
            assets = library.assets(withIDs: store.trash.map(\.id))
            selection.formIntersection(assets.keys)
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
            if !isSelecting { isSelecting = true }
            if isSelected { selection.remove(id) } else { selection.insert(id) }
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { AssetImageView(asset: asset, contentMode: .fill) }
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    if asset.isVideo {
                        Text(Duration.seconds(asset.duration), format: .time(pattern: .minuteSecond))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                            .padding(4)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, isSelected ? Color.accentColor : .black.opacity(0.3))
                            .padding(6)
                    }
                }
                .opacity(isSelecting && !isSelected ? 0.75 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(asset.accessibilityKind))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("trashCell")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !store.trash.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSelecting ? "完了" : "選択") {
                    isSelecting.toggle()
                    if !isSelecting { selection.removeAll() }
                }
                .accessibilityIdentifier("selectButton")
            }
        }
        if isSelecting {
            ToolbarItem(placement: .bottomBar) {
                Button(selection.count == entries.count ? "選択解除" : "すべて選択") {
                    selection = selection.count == entries.count ? [] : Set(entries.map(\.id))
                }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("元に戻す", systemImage: "arrow.uturn.backward") { restore() }
                    .disabled(selection.isEmpty)
                    .accessibilityIdentifier("restoreButton")
            }
            ToolbarItem(placement: .bottomBar) {
                Button("削除", systemImage: "trash", role: .destructive) {
                    Task { await delete() }
                }
                .disabled(selection.isEmpty || isDeleting)
                .accessibilityIdentifier("deleteButton")
            }
        }
    }

    private func restore() {
        let ids = Array(selection)
        store.clear(ids: ids)
        onRestore?(ids)
        selection.removeAll()
        if store.trash.isEmpty { isSelecting = false }
    }

    private func delete() async {
        isDeleting = true
        defer { isDeleting = false }
        let ids = Array(selection)
        switch await DeletionService.delete(ids: ids) {
        case .deleted:
            store.clear(ids: ids)
            selection.removeAll()
            if store.trash.isEmpty { isSelecting = false }
        case .cancelled:
            break
        case .failed(let message):
            errorMessage = message
        }
    }
}
