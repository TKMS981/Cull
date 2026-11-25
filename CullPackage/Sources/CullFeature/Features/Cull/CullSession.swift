import Observation
import Photos
import UIKit

struct CullItem: Identifiable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
}

/// State for one swipe-culling run: the queue, undo history, pre-caching and
/// reconciliation with outside library changes.
@Observable
final class CullSession {
    enum Phase: Equatable { case loading, ready }

    private(set) var phase: Phase = .loading
    private(set) var queue = CullQueue<CullItem>([])
    private(set) var total = 0

    let filter: CullFilter
    let includeKept: Bool

    @ObservationIgnored private let library: PhotoLibraryService
    @ObservationIgnored private let store: DecisionStore
    @ObservationIgnored private let loader: ImageLoader
    @ObservationIgnored private var fetchResult: PHFetchResult<PHAsset>?
    @ObservationIgnored private var cached: [PHAsset] = []
    @ObservationIgnored var cacheTargetSize: CGSize = CGSize(width: 1200, height: 2400)

    static let prefetchAhead = 3
    static let keepBehind = 2

    init(filter: CullFilter, includeKept: Bool, library: PhotoLibraryService, store: DecisionStore, loader: ImageLoader = .shared) {
        self.filter = filter
        self.includeKept = includeKept
        self.library = library
        self.store = store
        self.loader = loader
    }

    var current: CullItem? { queue.current }
    var upNext: CullItem? { queue.pending.dropFirst().first }
    var remaining: Int { queue.remaining }
    var canUndo: Bool { queue.canUndo }
    var decidedCount: Int { max(total - remaining, 0) }

    // MARK: Loading

    /// Fetches and filters off the main actor so large libraries don't hitch the UI.
    func load() async {
        guard phase == .loading else { return }
        let loaded = await Self.fetchUndecided(filter: filter, skipping: skippedIDs)
        guard phase == .loading else { return }
        fetchResult = loaded.fetchResult
        queue = CullQueue(loaded.assets.map(CullItem.init))
        total = loaded.assets.count
        phase = .ready
        updateCache()
    }

    /// `PHFetchResult` and `PHAsset` are immutable, thread-safe PhotoKit snapshots
    /// that aren't annotated `Sendable`; this box carries them back to the main actor.
    nonisolated struct LoadedAssets: @unchecked Sendable {
        let fetchResult: PHFetchResult<PHAsset>
        let assets: [PHAsset]
    }

    @concurrent
    nonisolated static func fetchUndecided(filter: CullFilter, skipping skip: Set<String>) async -> LoadedAssets {
        let result = filter.fetchAssets()
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            if !skip.contains(asset.localIdentifier) { assets.append(asset) }
        }
        return LoadedAssets(fetchResult: result, assets: assets)
    }

    private var skippedIDs: Set<String> {
        includeKept ? store.trashedIDs : store.keptIDs.union(store.trashedIDs)
    }

    // MARK: Decisions

    func decide(_ decision: Decision) {
        guard let item = queue.decide(decision) else { return }
        store.record(decision, for: item.id)
        updateCache()
    }

    func undo() {
        guard let entry = queue.undo() else { return }
        store.clear(ids: [entry.element.id])
        updateCache()
    }

    /// Called after items are restored from Cull's trash: put the ones that belong
    /// to this session's filter back at the end of the queue.
    func requeue(ids: [String]) {
        guard let fetchResult else { return }
        let assets = library.assets(withIDs: ids)
        for id in ids {
            guard let asset = assets[id], fetchResult.contains(asset) else { continue }
            queue.requeue(CullItem(asset: asset))
            total += 1
        }
        updateCache()
    }

    // MARK: Library changes

    func apply(_ change: LibraryChange) {
        guard let fetchResult, let details = change.change.changeDetails(for: fetchResult) else { return }
        self.fetchResult = details.fetchResultAfterChanges

        let removed = Set(details.removedObjects.map(\.localIdentifier))
        if !removed.isEmpty {
            let before = queue.remaining
            queue.remove(ids: removed)
            total -= before - queue.remaining
        }
        if !details.changedObjects.isEmpty {
            queue.replace(details.changedObjects.map(CullItem.init))
        }
        let skip = skippedIDs
        let inserted = details.insertedObjects.filter { !skip.contains($0.localIdentifier) }.map(CullItem.init)
        if !inserted.isEmpty {
            let before = queue.remaining
            queue.append(inserted)
            total += queue.remaining - before
        }
        total = max(total, queue.remaining)
        updateCache()
    }

    // MARK: Caching

    /// Keeps the next few and previous few assets warm in `PHCachingImageManager`.
    private func updateCache() {
        let ahead = queue.pending.prefix(Self.prefetchAhead + 1).map(\.asset)
        let behind = queue.history.suffix(Self.keepBehind).map(\.element.asset)
        let wanted = ahead + behind
        let wantedIDs = Set(wanted.map(\.localIdentifier))
        let cachedIDs = Set(cached.map(\.localIdentifier))
        loader.stopCaching(cached.filter { !wantedIDs.contains($0.localIdentifier) }, targetSize: cacheTargetSize)
        loader.startCaching(wanted.filter { !cachedIDs.contains($0.localIdentifier) }, targetSize: cacheTargetSize)
        cached = wanted
    }

    /// Re-warms the cache after `tearDown()` (e.g. coming back from the trash screen).
    func resumeCaching() {
        guard phase == .ready else { return }
        cached = []
        updateCache()
    }

    func tearDown() {
        loader.stopCachingAll()
        cached = []
    }
}
