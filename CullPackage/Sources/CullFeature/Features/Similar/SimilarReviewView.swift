import Photos
import SwiftUI

/// One similar group at a time, side by side. Each photo is marked keep or trash
/// (the suggested best starts as keep, the rest as trash); tapping flips it. Applying
/// records the marks and moves on to the next group.
struct SimilarReviewView: View {
    let startGroupID: String

    @Environment(SimilarScanModel.self) private var model
    @Environment(DecisionStore.self) private var store
    @Environment(PhotoLibraryService.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var currentID: String?
    /// Overrides of the default marks, by asset ID.
    @State private var marks: [String: Decision] = [:]
    @State private var assets: [String: PHAsset] = [:]
    @State private var sizes: [String: Int64] = [:]
    @State private var preview: PreviewItem?
    @State private var applied = 0

    private struct PreviewItem: Identifiable { let id: String }

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    private var index: Int? {
        model.groups.firstIndex { $0.id == (currentID ?? startGroupID) }
    }

    private var group: SimilarGroup? { index.map { model.groups[$0] } }

    var body: some View {
        Group {
            if let group {
                content(group)
            } else {
                ContentUnavailableView("すべて確認しました", systemImage: "checkmark.circle",
                                       description: Text("似た写真のグループはもうありません。"))
                    .accessibilityIdentifier("similarDone")
            }
        }
        .navigationTitle(titleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task(id: group?.assetIDs) {
            guard let ids = group?.assetIDs else { return }
            assets = library.assets(withIDs: ids)
            let missing = ids.filter { sizes[$0] == nil }
            sizes.merge(await AssetSizeReader.bytes(forIDs: missing)) { _, new in new }
        }
        .sensoryFeedback(.success, trigger: applied)
        .fullScreenCover(item: $preview) { item in
            if let asset = assets[item.id] {
                AssetPreviewView(
                    asset: asset,
                    size: sizes[item.id],
                    primary: .init(title: "残す", systemImage: "checkmark.circle", identifier: "previewMarkKeepButton") {
                        marks[item.id] = .keep
                    },
                    secondary: .init(title: "ゴミ箱へ", systemImage: "trash", role: .destructive, identifier: "previewMarkTrashButton") {
                        marks[item.id] = .trash
                    },
                    identifier: "similarPreview"
                )
            }
        }
    }

    private var titleText: Text {
        if let index { Text("グループ \(index + 1) / \(model.groups.count)") } else { Text("似た写真") }
    }

    private func mark(for id: String, in group: SimilarGroup) -> Decision {
        marks[id] ?? (id == group.suggestedKeepID ? .keep : .trash)
    }

    private func content(_ group: SimilarGroup) -> some View {
        ScrollView {
            Text("タップで「残す」と「ゴミ箱」を切り替えます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 8)
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(group.assetIDs, id: \.self) { id in
                    tile(id: id, group: group)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom) { applyBar(group) }
        .id(group.id)
    }

    private func tile(id: String, group: SimilarGroup) -> some View {
        let decision = mark(for: id, in: group)
        let isKeep = decision == .keep
        let tint: Color = isKeep ? .green : .red
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { marks[id] = isKeep ? .trash : .keep }
            } label: {
                Color.black.opacity(0.06)
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .overlay {
                        if let asset = assets[id] {
                            AssetImageView(asset: asset, contentMode: .fit)
                        }
                    }
                    .clipShape(.rect(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(tint, lineWidth: 3)
                    }
                    .overlay(alignment: .bottom) {
                        Label(isKeep ? "残す" : "ゴミ箱", systemImage: isKeep ? "checkmark.circle.fill" : "trash.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(tint.gradient, in: .capsule)
                            .padding(8)
                    }
                    .overlay(alignment: .topLeading) {
                        if id == group.suggestedKeepID {
                            Label("おすすめ", systemImage: "star.fill")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .glassEffect(.regular, in: .capsule)
                                .padding(8)
                        }
                    }
                    .opacity(isKeep ? 1 : 0.8)
                    .contentShape(.rect(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(assets[id]?.accessibilityKind ?? ""))
            .accessibilityValue(isKeep ? Text("残す") : Text("ゴミ箱"))
            .accessibilityHint(Text("ダブルタップで切り替え"))
            .accessibilityAction(named: Text("拡大して見る")) { preview = PreviewItem(id: id) }
            .accessibilityIdentifier("similarTile")
            .overlay(alignment: .topTrailing) {
                Button {
                    preview = PreviewItem(id: id)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.footnote.weight(.semibold))
                        .padding(8)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .padding(6)
                .accessibilityLabel(Text("拡大して見る"))
                .accessibilityIdentifier("similarExpandButton")
            }
            details(id: id)
        }
    }

    private func details(id: String) -> some View {
        HStack(spacing: 6) {
            if let asset = assets[id] {
                if let date = asset.creationDate {
                    Text(date, format: .dateTime.hour().minute().second())
                }
                Text(verbatim: "\(asset.pixelWidth)×\(asset.pixelHeight)")
            }
            Spacer(minLength: 0)
            if let size = sizes[id] {
                Text(size, format: .byteCount(style: .file))
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private func applyBar(_ group: SimilarGroup) -> some View {
        let trashCount = group.assetIDs.count { mark(for: $0, in: group) == .trash }
        let keepCount = group.assetIDs.count - trashCount
        return VStack(spacing: 8) {
            Button {
                apply(group)
            } label: {
                VStack(spacing: 2) {
                    Text("この内容で整理").font(.headline)
                    Text("残す \(keepCount) 枚・ゴミ箱 \(trashCount) 枚")
                        .font(.caption)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .accessibilityIdentifier("similarApplyButton")
            Button("このグループをスキップ") { advance(from: group) }
                .font(.subheadline)
                .accessibilityIdentifier("similarSkipButton")
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let group {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("すべて残す", systemImage: "checkmark.circle") {
                        withAnimation(.snappy) { for id in group.assetIDs { marks[id] = .keep } }
                    }
                    .accessibilityIdentifier("similarKeepAllButton")
                    Button("おすすめ以外をゴミ箱", systemImage: "star") {
                        withAnimation(.snappy) { for id in group.assetIDs { marks[id] = nil } }
                    }
                } label: {
                    Label("一括", systemImage: "ellipsis")
                }
                .accessibilityIdentifier("similarMarksMenu")
            }
        }
    }

    // MARK: Actions

    private func apply(_ group: SimilarGroup) {
        let keep = group.assetIDs.filter { mark(for: $0, in: group) == .keep }
        let trash = group.assetIDs.filter { mark(for: $0, in: group) == .trash }
        store.record(.keep, for: keep)
        store.record(.trash, for: trash)
        applied += 1
        advance(from: group, removing: true)
    }

    /// To the next group (wrapping round); back to the list once there are none.
    private func advance(from group: SimilarGroup, removing: Bool = false) {
        guard let position = model.groups.firstIndex(where: { $0.id == group.id }) else { return }
        for id in group.assetIDs { marks[id] = nil }
        if removing { model.remove(group) }
        let remaining = model.groups
        let others = remaining.filter { $0.id != group.id }
        guard !others.isEmpty else {
            if removing { dismiss() }
            return
        }
        let nextPosition = removing ? position : position + 1
        withAnimation(.smooth) {
            currentID = remaining[nextPosition % remaining.count].id
        }
    }
}
