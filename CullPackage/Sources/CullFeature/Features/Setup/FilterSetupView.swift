import Photos
import SwiftUI

enum Route: Hashable {
    case cull(CullFilter, includeKept: Bool)
    case trash
}

/// Launch screen: choose what to cull, plus kept-history settings.
struct FilterSetupView: View {
    @Binding var path: [Route]

    @Environment(PhotoLibraryService.self) private var library
    @Environment(DecisionStore.self) private var store

    @AppStorage("includeKept") private var includeKept = false
    @State private var albumID: String?
    @State private var useDateRange = false
    @State private var startDate = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var endDate = Date.now
    @State private var attributes: Set<MediaAttribute> = []
    @State private var matchCount = 0
    @State private var confirmReset = false
    /// The large title has scrolled away, so the bar shows the compact wordmark.
    @State private var isTitleCollapsed = false

    private var filter: CullFilter {
        CullFilter(
            albumID: albumID,
            dateRange: useDateRange ? min(startDate, endDate)...max(startDate, endDate) : nil,
            attributes: attributes
        )
    }

    var body: some View {
        Form {
            if library.isLimited { limitedSection }
            quickStartSection
            albumSection
            dateSection
            attributeSection
            settingsSection
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            // Past roughly the large title's height, it has collapsed into the bar.
            geometry.contentOffset.y + geometry.contentInsets.top > Self.largeTitleCollapseOffset
        } action: { _, collapsed in
            withAnimation(.easeInOut(duration: 0.2)) { isTitleCollapsed = collapsed }
        }
        // The plain title still names the screen for VoiceOver and the back button. Both
        // visible spots use the script wordmark instead, on this screen only: large at the
        // top left before scrolling, compact in the centre of the bar once scrolled.
        .navigationTitle(Text(verbatim: "Cull"))
        .toolbar {
            ToolbarItem(placement: .largeTitle) { wordmark }
            ToolbarItem(placement: .principal) { compactWordmark }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    path.append(.trash)
                } label: {
                    Label("ゴミ箱", systemImage: "trash")
                }
                .badge(store.trash.count)
                .accessibilityIdentifier("setupTrashButton")
            }
        }
        .safeAreaInset(edge: .bottom) { startButton }
        .task { await library.loadAlbums() }
        .task(id: CountKey(filter: filter, includeKept: includeKept, kept: store.keptIDs.count, trashed: store.trash.count)) {
            await updateCount()
        }
        .task {
            for await _ in library.changes() {
                await library.loadAlbums()
                await updateCount()
            }
        }
        .confirmationDialog("整理済み履歴をリセットしますか？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("履歴をリセット", role: .destructive) { store.resetKept() }
        } message: {
            Text("「保持」にした \(store.keptIDs.count) 件が再び整理対象になります。ゴミ箱の内容は変わりません。")
        }
    }

    private struct CountKey: Hashable {
        let filter: CullFilter
        let includeKept: Bool
        let kept: Int
        let trashed: Int
    }

    private func updateCount() async {
        let filter = filter
        let excluded = includeKept ? store.trashedIDs : store.keptIDs.union(store.trashedIDs)
        let count = await PhotoLibraryService.count(matching: filter, excluding: excluded)
        // Drop the result if the filter changed (or the task was replaced) meanwhile.
        guard !Task.isCancelled, filter == self.filter else { return }
        matchCount = count
    }

    private var limitedSection: some View {
        Section {
            Label("一部の写真へのアクセスのみ許可されています", systemImage: "exclamationmark.triangle")
            Button("アクセスできる写真を管理") {
                Task { await library.presentLimitedLibraryPicker() }
            }
        }
    }

    /// One-tap presets; the active one is highlighted, and tapping it again clears the filter.
    static let largeTitleCollapseOffset: CGFloat = 40

    /// "Cull" in Snell Roundhand (built into iOS), the same in every language.
    /// Scales with Dynamic Type relative to the large title.
    private var wordmark: some View {
        Text(verbatim: "Cull")
            .font(.custom("SnellRoundhand-Bold", size: 44, relativeTo: .largeTitle))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("wordmark")
    }

    /// The same wordmark at inline-title size; fades in only once the large title has
    /// scrolled away (the principal slot would otherwise show above the large title too).
    private var compactWordmark: some View {
        Text(verbatim: "Cull")
            .font(.custom("SnellRoundhand-Bold", size: 26, relativeTo: .headline))
            .opacity(isTitleCollapsed ? 1 : 0)
            .accessibilityHidden(!isTitleCollapsed)
            .accessibilityIdentifier("compactWordmark")
    }

    private var quickStartSection: some View {
        Section {
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(FilterPreset.allCases) { preset in
                            presetChip(preset, isActive: preset.matches(filter))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
            .scrollIndicators(.hidden)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            Text("クイックスタート")
        } footer: {
            Text("よく使う条件をワンタップで設定します。もう一度タップすると解除します。")
        }
    }

    private func presetChip(_ preset: FilterPreset, isActive: Bool) -> some View {
        Button {
            apply(preset, clearing: isActive)
        } label: {
            Label { Text(preset.title) } icon: { Image(systemName: preset.systemImage) }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isActive ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(isActive ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("preset.\(preset.rawValue)")
    }

    private func apply(_ preset: FilterPreset, clearing: Bool) {
        withAnimation(.smooth) {
            albumID = nil
            if clearing {
                attributes = []
                useDateRange = false
                return
            }
            attributes = preset.attributes
            if let range = preset.dateRange() {
                startDate = range.lowerBound
                endDate = range.upperBound
                useDateRange = true
            } else {
                useDateRange = false
            }
        }
    }

    private var albumSection: some View {
        Section("アルバム") {
            Picker("対象", selection: $albumID) {
                Text("すべての写真").tag(String?.none)
                let smart = library.albums.filter(\.isSmartAlbum)
                if !smart.isEmpty {
                    Section("メディアタイプ") {
                        ForEach(smart) { album in
                            Text("\(album.title)（\(album.count)）").tag(Optional(album.id))
                        }
                    }
                }
                let user = library.albums.filter { !$0.isSmartAlbum }
                if !user.isEmpty {
                    Section("マイアルバム") {
                        ForEach(user) { album in
                            Text("\(album.title)（\(album.count)）").tag(Optional(album.id))
                        }
                    }
                }
            }
            .pickerStyle(.navigationLink)
        }
    }

    private var dateSection: some View {
        Section("撮影期間") {
            Toggle("期間で絞り込む", isOn: $useDateRange.animation())
                .accessibilityIdentifier("dateRangeToggle")
            if useDateRange {
                DatePicker("開始日", selection: $startDate, in: ...endDate, displayedComponents: .date)
                DatePicker("終了日", selection: $endDate, in: startDate..., displayedComponents: .date)
            }
        }
    }

    private var attributeSection: some View {
        Section {
            ForEach(MediaAttribute.allCases) { attribute in
                let isOn = attributes.contains(attribute)
                Button {
                    if isOn { attributes.remove(attribute) } else { attributes.insert(attribute) }
                } label: {
                    HStack {
                        Label { Text(attribute.title) } icon: { Image(systemName: attribute.systemImage) }
                        Spacer()
                        if isOn {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityIdentifier("attribute.\(attribute.rawValue)")
            }
        } header: {
            Text("属性")
        } footer: {
            Text("選択しない場合は写真・ビデオ・Live Photos すべてが対象です。複数選択するといずれかに当てはまるものが対象になります。")
        }
    }

    private var settingsSection: some View {
        Section {
            Toggle("整理済み（保持）の写真も再表示する", isOn: $includeKept)
                .accessibilityIdentifier("includeKeptToggle")
            Button("整理済み履歴をリセット", role: .destructive) { confirmReset = true }
                .disabled(store.keptIDs.isEmpty)
                .accessibilityIdentifier("resetKeptButton")
        } header: {
            Text("設定")
        } footer: {
            Text("保持済み: \(store.keptIDs.count) 件")
        }
    }

    private var startButton: some View {
        Button {
            path.append(.cull(filter, includeKept: includeKept))
        } label: {
            VStack(spacing: 2) {
                Text("整理を始める").font(.headline)
                Text("未整理 \(matchCount) 件").font(.caption).monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .disabled(matchCount == 0)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .accessibilityIdentifier("startButton")
    }
}
