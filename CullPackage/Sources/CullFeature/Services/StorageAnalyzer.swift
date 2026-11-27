import Foundation
import Observation
import Photos

/// Measures the whole library (photos and videos) for the storage screen.
enum StorageAnalyzer {
    /// Off the main actor; sizes come from `AssetSizeReader` (parallel, cached on disk,
    /// so a second run is quick). Returns `nil` if cancelled part-way.
    @concurrent
    nonisolated static func analyze(progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void) async -> StorageReport? {
        let result = CullFilter().fetchAssets(sort: .newest)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        progress(0, assets.count)
        let sizes = await AssetSizeReader.bytes(of: assets, progress: progress)
        guard !Task.isCancelled else { return nil }
        let items = zip(assets, sizes).map { asset, bytes in
            StorageItem(
                id: asset.localIdentifier,
                category: StorageCategory.classify(mediaType: asset.mediaType, subtypes: asset.mediaSubtypes),
                bytes: bytes
            )
        }
        return StorageReport.build(items)
    }
}

/// The storage screen's state, owned by the root view so the last report (and a scan
/// still running) survive leaving the screen and coming back.
@Observable
final class StorageModel {
    struct Progress: Equatable {
        var done: Int
        var total: Int
        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    private(set) var report: StorageReport?
    /// Non-nil while a scan runs.
    private(set) var progress: Progress?
    /// The library changed since `report` was made.
    private(set) var isStale = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UUID?

    var isScanning: Bool { progress != nil }

    func scan() {
        guard task == nil else { return }
        let generation = UUID()
        self.generation = generation
        progress = Progress(done: 0, total: 0)
        let update: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in
                guard let self, self.generation == generation, let current = self.progress else { return }
                // Workers report out of order; never step backwards.
                self.progress = Progress(done: max(done, current.done), total: total)
            }
        }
        task = Task {
            let report = await StorageAnalyzer.analyze(progress: update)
            // A cancelled (or superseded) run leaves the state to whoever replaced it.
            guard self.generation == generation else { return }
            if let report {
                self.report = report
                isStale = false
            }
            progress = nil
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation = nil
        progress = nil
    }

    func libraryDidChange() {
        if report != nil { isStale = true }
    }
}
