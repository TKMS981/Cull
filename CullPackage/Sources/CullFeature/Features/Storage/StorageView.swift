import Photos
import SwiftUI

/// How much space the library takes: the total, a breakdown by kind, and the biggest
/// files. Every row leads straight into culling those items, biggest first.
struct StorageView: View {
    @Binding var path: [Route]

    @Environment(StorageModel.self) private var model
    @Environment(PhotoLibraryService.self) private var library
    @Environment(PaceMonitor.self) private var paceMonitor
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("includeKept") private var includeKept = false

    /// Thumbnails for the biggest-files list.
    @State private var assets: [String: PHAsset] = [:]

    var body: some View {
        List {
            if let progress = model.progress {
                progressSection(progress)
            }
            if let report = model.report {
                summarySection(report)
                categorySection(report)
                largestSection(report)
            } else if !model.isScanning {
                ContentUnavailableView {
                    Label("ストレージを分析", systemImage: "internaldrive")
                } description: {
                    Text("ライブラリ内の写真とビデオの容量を集計します。")
                } actions: {
                    Button("分析を開始") { model.scan() }
                        .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(Text("ストレージ"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("再計算", systemImage: "arrow.clockwise") { model.scan() }
                    .disabled(model.isScanning)
                    .accessibilityIdentifier("storageRescanButton")
            }
        }
        .onAppear {
            if model.needsScan { model.scan() }
        }
        // Leaving the screen or the app stops the scan at once; coming back picks it up
        // again, and everything measured so far comes from the cache.
        .onDisappear { model.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                if model.needsScan { model.scan() }
            } else {
                model.cancel()
            }
        }
        .onChange(of: model.isStale) { _, stale in
            if stale, scenePhase == .active { model.scan() }
        }
        .task(id: model.report?.largest.map(\.id)) {
            guard let ids = model.report?.largest.map(\.id) else { return }
            assets = library.assets(withIDs: ids)
        }
    }

    // MARK: Sections

    private func progressSection(_ progress: ScanProgress) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("容量を計算中…").font(.headline)
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
                Text("一度計算したサイズは保存され、次回からすばやく表示されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("storageProgress")
            Button("キャンセル", role: .cancel) { model.cancel() }
                .accessibilityIdentifier("storageCancelButton")
        }
    }

    private func summarySection(_ report: StorageReport) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ライブラリの合計")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(report.totalBytes, format: .byteCount(style: .file))
                        .font(.largeTitle.bold())
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("\(report.totalCount) 件")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("storageTotal")
                breakdownBar(report)
                if report.unknownCount > 0 {
                    Text("\(report.unknownCount) 件はサイズを取得できませんでした（iCloud のみにある項目など）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .opacity(model.isScanning ? 0.5 : 1)
        } footer: {
            Text("\(report.measuredAt, format: .dateTime.month().day().hour().minute()) 時点")
        }
    }

    /// One capsule split by category share.
    private func breakdownBar(_ report: StorageReport) -> some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(report.categories) { summary in
                    let width = proxy.size.width * report.fraction(of: summary)
                    if width >= 1 {
                        Rectangle()
                            .fill(summary.category.color.gradient)
                            .frame(width: max(width - 2, 1))
                    }
                }
                Spacer(minLength: 0)
            }
            .clipShape(.capsule)
        }
        .frame(height: 14)
        .background(.quaternary, in: .capsule)
        .accessibilityHidden(true)
    }

    private func categorySection(_ report: StorageReport) -> some View {
        Section {
            ForEach(report.categories) { summary in
                Button {
                    cull(summary.ids)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: summary.category.systemImage)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .dynamicTypeSize(...DynamicTypeSize.large)
                            .frame(width: 32, height: 32)
                            .background(summary.category.color.gradient, in: .rect(cornerRadius: 8))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.category.title)
                            Text("\(summary.count) 件")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(summary.bytes, format: .byteCount(style: .file))
                                .monospacedDigit()
                            Text(report.fraction(of: summary), format: .percent.precision(.fractionLength(0...1)))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        // Sizes never wrap ("11.4 / MB"); the name wraps instead.
                        .fixedSize(horizontal: true, vertical: false)
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint(Text("大きい順に整理を始めます"))
                .accessibilityIdentifier("storageCategory.\(summary.category.rawValue)")
            }
        } header: {
            Text("種類別")
        } footer: {
            Text("タップすると、その種類を容量が大きい順に整理できます。")
        }
    }

    private func largestSection(_ report: StorageReport) -> some View {
        Section {
            ForEach(Array(report.largest.enumerated()), id: \.element.id) { index, item in
                Button {
                    // From this item on down, so the next cards are the next-biggest.
                    cull(report.largest[index...].map(\.id))
                } label: {
                    largeRow(item, rank: index + 1)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("storageLargeItem")
            }
        } header: {
            HStack {
                Text("大きいファイル")
                Spacer()
                if !report.largest.isEmpty {
                    Button("まとめて整理") { cull(report.largest.map(\.id)) }
                        .font(.subheadline.weight(.semibold))
                        .textCase(nil)
                        .accessibilityIdentifier("storageLargestCullButton")
                }
            }
        } footer: {
            Text("上位 \(report.largest.count) 件。タップした項目から大きい順に整理を始めます。")
        }
    }

    private func largeRow(_ item: StorageItem, rank: Int) -> some View {
        HStack(spacing: 12) {
            Text(rank, format: .number)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)
            Group {
                if let asset = assets[item.id] {
                    AssetImageView(asset: asset, contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.category.title)
                    .font(.subheadline)
                if let asset = assets[item.id], let date = asset.creationDate {
                    Text(date, format: .dateTime.year().month().day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let bytes = item.bytes {
                Text(bytes, format: .byteCount(style: .file))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private func cull(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        path.append(.cullSelection(AssetSelection(ids: ids, includeKept: includeKept)))
    }
}
