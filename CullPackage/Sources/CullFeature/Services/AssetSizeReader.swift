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
            if let size = bytes(of: asset) { sizes[asset.localIdentifier] = size }
        }
        return sizes
    }

    /// Sizes for `assets`, in the same order (`nil` where PhotoKit doesn't report one).
    ///
    /// Built for 10k-item libraries: runs off the main actor, splits the work across
    /// the cores, reuses sizes measured earlier this launch (keyed by modification
    /// date, so an edited asset is measured again), and reports how many are done
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
            return result
        }
    }

    /// `PHAsset` is an immutable, thread-safe snapshot that isn't annotated `Sendable`.
    nonisolated private struct AssetList: @unchecked Sendable {
        let assets: [PHAsset]
    }

    private nonisolated struct CacheEntry {
        let modified: Date?
        let bytes: Int64?
    }

    private nonisolated static let cache = Mutex<[String: CacheEntry]>([:])

    nonisolated static func cachedBytes(of asset: PHAsset) -> Int64? {
        let id = asset.localIdentifier
        let modified = asset.modificationDate
        if let hit = cache.withLock({ $0[id] }), hit.modified == modified { return hit.bytes }
        let measured = bytes(of: asset)
        cache.withLock { $0[id] = CacheEntry(modified: modified, bytes: measured) }
        return measured
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
