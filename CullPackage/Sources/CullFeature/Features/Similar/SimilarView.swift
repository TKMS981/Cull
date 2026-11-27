import Photos
import SwiftUI

/// The time span a similar-photo scan covers. A whole-library scan is deliberately
/// not offered: it's the slow case, and the recent photos are where duplicates pile up.
enum SimilarPeriod: String, CaseIterable, Identifiable {
    case week
    case month
    case threeMonths
    case year
    case custom

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .week: "直近1週間"
        case .month: "直近30日"
        case .threeMonths: "直近3か月"
        case .year: "直近1年"
        case .custom: "期間を指定"
        }
    }

    /// `nil` for `.custom` (the caller supplies the range).
    func range(endingAt now: Date = .now, calendar: Calendar = .current) -> ClosedRange<Date>? {
        let start: Date? = switch self {
        case .week: calendar.date(byAdding: .day, value: -6, to: now)
        case .month: calendar.date(byAdding: .day, value: -29, to: now)
        case .threeMonths: calendar.date(byAdding: .month, value: -3, to: now)
        case .year: calendar.date(byAdding: .year, value: -1, to: now)
        case .custom: nil
        }
        return start.map { $0...now }
    }
}

/// Look for groups of similar photos in a chosen period / album, then go through
/// them one group at a time.
struct SimilarView: View {
    @Environment(SimilarScanModel.self) private var model
    @Environment(PhotoLibraryService.self) private var library
    @Environment(DecisionStore.self) private var store
    @AppStorage("includeKept") private var includeKept = false
    @Environment(PaceMonitor.self) private var paceMonitor
    @Environment(\.scenePhase) private var scenePhase

    @State private var period: SimilarPeriod = .month
    @State private var startDate = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var endDate = Date.now
    @State private var albumID: String?
    @State private var level: SimilarityLevel = .standard
    @State private var photoCount: Int?
    @State private var reviewing: ReviewStart?
    /// Periods end "today" (whole days, like every date filter here); fixed while the
    /// screen is open so the filter, and the count task keyed on it, stay stable.
    @State private var today = Date.now

    private struct ReviewStart: Identifiable, Hashable { let id: String }

    private var filter: CullFilter {
        let range = period.range(endingAt: today) ?? min(startDate, endDate)...max(startDate, endDate)
        return CullFilter(albumID: albumID, dateRange: range)
    }

    private var excluded: Set<String> {
        includeKept ? store.trashedIDs : store.keptIDs.union(store.trashedIDs)
    }

    var body: some View {
        List {
            if let progress = model.progress {
                progressSection(progress)
            } else {
                scopeSection
                scanButtonSection
            }
            if model.hasResults, !model.isScanning {
                resultsSection
            }
        }
        .navigationTitle(Text("似た写真"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await library.loadAlbums() }
        .task(id: CountKey(filter: filter, excluded: excluded.count)) {
            let filter = filter
            photoCount = nil
            let count = await SimilarPhotoFinder.photoCount(filter: filter, excluding: excluded)
            guard !Task.isCancelled, filter == self.filter else { return }
            photoCount = count
        }
        // Closing the screen cancels the scan immediately. Going to the background
        // pauses it; it continues on return (analysed photos come from the cache).
        .onDisappear { model.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.resumeIfSuspended() } else { model.suspend() }
        }
        .onChange(of: excluded) { _, excluded in
            model.prune { !excluded.contains($0) }
        }
        .navigationDestination(item: $reviewing) { start in
            SimilarReviewView(startGroupID: start.id)
        }
    }

    private struct CountKey: Hashable {
        let filter: CullFilter
        let excluded: Int
    }

    // MARK: Scope

    private var scopeSection: some View {
        Section {
            Picker("期間", selection: $period.animation()) {
                ForEach(SimilarPeriod.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("similarPeriodPicker")
            if period == .custom {
                DatePicker("開始日", selection: $startDate, in: ...endDate, displayedComponents: .date)
                DatePicker("終了日", selection: $endDate, in: startDate..., displayedComponents: .date)
            }
            Picker("アルバム", selection: $albumID) {
                Text("すべての写真").tag(String?.none)
                ForEach(library.albums) { album in
                    Text("\(album.title)（\(album.count)）").tag(Optional(album.id))
                }
            }
            .pickerStyle(.navigationLink)
            Picker("判定", selection: $level) {
                ForEach(SimilarityLevel.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("similarLevelPicker")
        } header: {
            Text("解析する範囲")
        } footer: {
            Text("撮影時刻が近い写真どうしを、端末上で見た目を比べて判定します（写真は外部に送信されません）。未整理の写真のみが対象です。")
        }
    }

    private var scanButtonSection: some View {
        Section {
            Button {
                model.scan(filter: filter, excluding: excluded, level: level)
            } label: {
                HStack {
                    Label("似た写真を探す", systemImage: "square.on.square")
                        .font(.headline)
                    Spacer()
                    if let photoCount {
                        Text("写真 \(photoCount) 枚")
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
            }
            .disabled(photoCount == 0)
            .accessibilityIdentifier("similarScanButton")
        }
    }

    private func progressSection(_ progress: ScanProgress) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("写真を解析中…").font(.headline)
                    Spacer()
                    if progress.total > 0 {
                        Text("\(progress.done) / \(progress.total)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: progress.fraction)
                PaceNote(pace: paceMonitor.pace)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("similarProgress")
            Button("キャンセル", role: .cancel) { model.cancel() }
                .accessibilityIdentifier("similarCancelButton")
        }
    }

    // MARK: Results

    @ViewBuilder
    private var resultsSection: some View {
        if model.groups.isEmpty {
            Section {
                ContentUnavailableView("似た写真は見つかりませんでした", systemImage: "checkmark.seal",
                                       description: Text("期間を広げるか、判定をゆるめて試してください。"))
                    .accessibilityIdentifier("similarEmpty")
            }
        } else {
            Section {
                ForEach(model.groups) { group in
                    Button {
                        reviewing = ReviewStart(id: group.id)
                    } label: {
                        SimilarGroupRow(group: group)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("similarGroup")
                }
            } header: {
                Text("\(model.groups.count) グループ・\(model.photoCount) 枚")
                    .accessibilityIdentifier("similarSummary")
            } footer: {
                Text("グループを開いて、残す写真とゴミ箱に送る写真を選びます。")
            }
        }
    }
}

/// A row of thumbnails for one group.
private struct SimilarGroupRow: View {
    let group: SimilarGroup

    @Environment(PhotoLibraryService.self) private var library
    @State private var assets: [String: PHAsset] = [:]

    private static let shown = 4

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(group.assetIDs.prefix(Self.shown), id: \.self) { id in
                    Group {
                        if let asset = assets[id] {
                            AssetImageView(asset: asset, contentMode: .fill)
                        } else {
                            Color.secondary.opacity(0.2)
                        }
                    }
                    .frame(width: 54, height: 54)
                    .clipShape(.rect(cornerRadius: 8))
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(group.assetIDs.count) 枚")
                    .font(.headline)
                    .monospacedDigit()
                if let date = group.startDate {
                    Text(date, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .task(id: group.assetIDs) {
            assets = library.assets(withIDs: Array(group.assetIDs.prefix(Self.shown)))
        }
    }
}
