import Photos
import SwiftUI

/// Everything marked "keep": a grid to review it, with multi-select to un-keep items
/// (back to unsorted) or send them to Cull's trash. Filterable by attribute, and
/// the entry point for resetting kept history by attribute or album.
struct KeptView: View {
    @Environment(DecisionStore.self) private var store
    @Environment(PhotoLibraryService.self) private var library

    @State private var attribute: MediaAttribute?
    @State private var assets: [PHAsset] = []
    @State private var isLoading = true
    @State private var selection: Set<String> = []
    @State private var isSelecting = false
    @State private var preview: PreviewItem?
    @State private var showReset = false
    @Namespace private var previewNamespace

    private struct PreviewItem: Identifiable { let id: String }

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    var body: some View {
        Group {
            if store.keptIDs.isEmpty {
                ContentUnavailableView("保持した写真はありません", systemImage: "checkmark.circle",
                                       description: Text("左にスワイプした写真がここに表示されます。"))
            } else {
                ScrollView {
                    filterBar
                    if assets.isEmpty, !isLoading {
                        ContentUnavailableView("該当する写真はありません", systemImage: "line.3.horizontal.decrease.circle")
                            .padding(.top, 40)
                    }
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(assets, id: \.localIdentifier) { asset in
                            cell(asset)
                        }
                    }
                }
            }
        }
        .navigationTitle(isSelecting ? Text("\(selection.count) 件を選択") : Text("保持済み"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task(id: LoadKey(attribute: attribute, kept: store.keptIDs.count, trashed: store.trash.count)) {
            await load()
        }
        .task {
            for await _ in library.changes() { await load() }
        }
        .sheet(isPresented: $showReset) {
            KeptResetSheet()
        }
        .fullScreenCover(item: $preview) { item in
            if let asset = assets.first(where: { $0.localIdentifier == item.id }) {
                AssetPreviewView(
                    asset: asset,
                    size: nil,
                    primary: .init(title: "保持を解除", systemImage: "arrow.uturn.backward", identifier: "previewUnkeepButton") {
                        unkeep(ids: [item.id])
                    },
                    secondary: .init(title: "ゴミ箱へ", systemImage: "trash", role: .destructive, identifier: "previewTrashButton") {
                        moveToTrash(ids: [item.id])
                    },
                    identifier: "keptPreview"
                )
                .navigationTransition(.zoom(sourceID: item.id, in: previewNamespace))
            }
        }
    }

    private struct LoadKey: Hashable {
        let attribute: MediaAttribute?
        let kept: Int
        let trashed: Int
    }

    private func load() async {
        let attribute = attribute
        let loaded = await PhotoLibraryService.keptAssets(ids: store.keptIDs, attribute: attribute)
        guard !Task.isCancelled, attribute == self.attribute else { return }
        assets = loaded.assets
        selection.formIntersection(assets.map(\.localIdentifier))
        isLoading = false
    }

    // MARK: Filter

    private var filterBar: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    chip(Text("すべて"), systemImage: "square.grid.2x2", isActive: attribute == nil, id: "all") { attribute = nil }
                    ForEach(MediaAttribute.allCases) { item in
                        chip(Text(item.title), systemImage: item.systemImage, isActive: attribute == item, id: item.rawValue) {
                            attribute = item
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ title: Text, systemImage: String, isActive: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { title } icon: { Image(systemName: systemImage) }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isActive ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(isActive ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("keptFilter.\(id)")
    }

    // MARK: Grid

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
        .accessibilityIdentifier("keptCell")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !store.keptIDs.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isSelecting.toggle()
                    if !isSelecting { selection.removeAll() }
                } label: {
                    isSelecting ? Text("完了") : Text("選択")
                }
                .accessibilityIdentifier("keptSelectButton")
            }
            if !isSelecting {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("条件を指定してリセット", systemImage: "arrow.counterclockwise") { showReset = true }
                        .accessibilityIdentifier("keptResetButton")
                }
            }
        }
        if isSelecting {
            ToolbarItem(placement: .bottomBar) {
                let all = Set(assets.map(\.localIdentifier))
                Button {
                    selection = selection == all ? [] : all
                } label: {
                    selection == all ? Text("選択解除") : Text("すべて選択")
                }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("保持を解除", systemImage: "arrow.uturn.backward") { unkeep(ids: Array(selection)) }
                    .disabled(selection.isEmpty)
                    .accessibilityIdentifier("unkeepButton")
            }
            ToolbarItem(placement: .bottomBar) {
                Button("ゴミ箱へ", systemImage: "trash", role: .destructive) { moveToTrash(ids: Array(selection)) }
                    .disabled(selection.isEmpty)
                    .accessibilityIdentifier("keptToTrashButton")
            }
        }
    }

    // MARK: Actions

    /// Back to unsorted: the items show up in the next session.
    private func unkeep(ids: [String]) {
        store.clear(ids: ids)
        finishAction(ids)
    }

    private func moveToTrash(ids: [String]) {
        store.record(.trash, for: ids)
        finishAction(ids)
    }

    private func finishAction(_ ids: [String]) {
        let removed = Set(ids)
        assets.removeAll { removed.contains($0.localIdentifier) }
        selection.subtract(removed)
        if store.keptIDs.isEmpty { isSelecting = false }
    }
}

/// A square grid thumbnail with the video duration and selection badge (kept & trash grids).
struct AssetGridThumbnail: View {
    let asset: PHAsset
    var isSelecting = false
    var isSelected = false

    var body: some View {
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
}
