import Foundation
import Photos
import Synchronization

/// On-disk size of assets, summed over all their resources (photo, paired video,
/// edits): what deleting them would free.
enum AssetSizeReader {
    /// Sizes by local identifier, read off the main actor. Assets whose size PhotoKit
    /// doesn't report are left out.
    @concurrent
    nonisolated static func bytes(forIDs ids: [String]) async -> [String: Int64] {
        guard !ids.isEmpty else { return [:] }
        var sizes: [String: Int64] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            if let size = cachedBytes(of: asset) { sizes[asset.localIdentifier] = size }
        }
        persistCache()
        return sizes
    }

    /// Sizes for `assets`, in the same order (`nil` where PhotoKit doesn't report one).
    ///
    /// Built for 10k-item libraries: runs off the main actor, splits the work across
    /// the cores, reuses sizes measured before (this launch or, via the on-disk
    /// cache, an earlier one), and reports how many are done
    /// every `progressStride` items.
    @concurrent
    nonisolated static func bytes(
        of assets: [PHAsset],
        progressStride: Int = 250,
        progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) async -> [Int64?] {
        let total = assets.count
        guard total > 0 else { return [] }
        let box = AssetList(assets: assets)
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, total / 64 + 1))
        let chunk = (total + workers - 1) / workers
        let done = Atomic<Int>(0)

        return await withTaskGroup(of: (Int, [Int64?]).self) { group in
            for start in stride(from: 0, to: total, by: chunk) {
                let range = start..<min(start + chunk, total)
                group.addTask {
                    var sizes: [Int64?] = []
                    sizes.reserveCapacity(range.count)
                    for index in range {
                        if Task.isCancelled { break }
                        sizes.append(cachedBytes(of: box.assets[index]))
                        let finished = done.add(1, ordering: .relaxed).newValue
                        if finished % progressStride == 0 || finished == total { progress(finished, total) }
                    }
                    return (range.lowerBound, sizes)
                }
            }
            var result = [Int64?](repeating: nil, count: total)
            for await (start, sizes) in group {
                for (offset, size) in sizes.enumerated() { result[start + offset] = size }
            }
            persistCache()
            return result
        }
    }

    /// `PHAsset` is an immutable, thread-safe snapshot that isn't annotated `Sendable`.
    nonisolated private struct AssetList: @unchecked Sendable {
        let assets: [PHAsset]
    }

    private nonisolated struct CacheEntry: Codable {
        let modified: Date?
        let bytes: Int64?
    }

    /// Sizes measured before, kept across launches in the Caches directory (the OS may
    /// purge it; it's only a speed-up). Keyed by modification date, so an edited asset
    /// is measured again.
    private nonisolated struct SizeCache {
        var entries: [String: CacheEntry]?
        var isDirty = false
    }

    private nonisolated static let cache = Mutex(SizeCache())

    nonisolated static var cacheURL: URL {
        URL.cachesDirectory.appending(path: "AssetSizes.json")
    }

    nonisolated static func cachedBytes(of asset: PHAsset) -> Int64? {
        let id = asset.localIdentifier
        let modified = asset.modificationDate
        let hit = cache.withLock { cache -> CacheEntry? in
            if cache.entries == nil { cache.entries = loadCache() }
            return cache.entries?[id]
        }
        if let hit, hit.modified == modified { return hit.bytes }
        let measured = bytes(of: asset)
        cache.withLock {
            $0.entries?[id] = CacheEntry(modified: modified, bytes: measured)
            $0.isDirty = true
        }
        return measured
    }

    /// Writes new measurements to disk (after a bulk read, not per item).
    nonisolated static func persistCache() {
        let snapshot = cache.withLock { cache -> [String: CacheEntry]? in
            guard cache.isDirty else { return nil }
            cache.isDirty = false
            return cache.entries
        }
        guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private nonisolated static func loadCache() -> [String: CacheEntry] {
        guard let data = try? Data(contentsOf: cacheURL),
              let entries = try? JSONDecoder().decode([String: CacheEntry].self, from: data) else { return [:] }
        return entries
    }

    /// `PHAssetResource` has no public size API; `fileSize` is a KVC-readable property.
    /// Checked with `responds(to:)` first so a missing key can't raise.
    nonisolated static func bytes(of asset: PHAsset) -> Int64? {
        let sizes = PHAssetResource.assetResources(for: asset).compactMap { resource -> Int64? in
            guard resource.responds(to: NSSelectorFromString("fileSize")) else { return nil }
            return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
        }
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }
}
