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
        cache.persist()
        return sizes
    }

    /// Sizes for `assets`, in the same order (`nil` where PhotoKit doesn't report one).
    ///
    /// Built for 10k-item libraries: runs off the main actor on at most
    /// `ResourceGovernor.maxConcurrency` workers (half in Low Power Mode), pauses while
    /// the device is hot, reuses sizes measured before (on-disk cache, re-measured
    /// only for new or edited assets) and reports progress every `progressStride` items.
    @concurrent
    nonisolated static func bytes(
        of assets: [PHAsset],
        progressStride: Int = 250,
        progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) async -> [Int64?] {
        let total = assets.count
        guard total > 0 else { return [] }
        let box = AssetList(assets: assets)
        let limit = max(1, ResourceGovernor.concurrency(for: ResourceGovernor.currentPace))
        let workers = max(1, min(limit, total / 64 + 1))
        let chunk = (total + workers - 1) / workers
        let done = Atomic<Int>(0)

        return await withTaskGroup(of: (Int, [Int64?]).self) { group in
            for start in stride(from: 0, to: total, by: chunk) {
                let range = start..<min(start + chunk, total)
                group.addTask {
                    var sizes: [Int64?] = []
                    sizes.reserveCapacity(range.count)
                    for index in range {
                        // Check the device every so often (cheap); stop on cancel.
                        if index % 64 == 0, !(await ResourceGovernor.waitUntilAllowed()) { break }
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
            cache.persist()
            return result
        }
    }

    /// `PHAsset` is an immutable, thread-safe snapshot that isn't annotated `Sendable`.
    nonisolated private struct AssetList: @unchecked Sendable {
        let assets: [PHAsset]
    }

    /// `nil` bytes are cached too: "PhotoKit gives no size" needn't be asked again.
    nonisolated struct CachedSize: Codable, Sendable {
        let bytes: Int64?
    }

    nonisolated static let cache = DiskCache<CachedSize>(fileName: "AssetSizes.plist", capacity: 200_000)

    nonisolated static func cachedBytes(of asset: PHAsset) -> Int64? {
        let id = asset.localIdentifier
        let modified = asset.modificationDate
        if let hit = cache.value(for: id, modified: modified) { return hit.bytes }
        // Resource lookups create autoreleased objects; drain them per asset so a 10k
        // pass doesn't build up memory on a worker thread.
        let measured = autoreleasepool { bytes(of: asset) }
        cache.store(CachedSize(bytes: measured), for: id, modified: modified)
        return measured
    }

    /// Forget sizes of assets that are gone (after a pass over the whole library).
    nonisolated static func pruneCache(keeping ids: Set<String>) {
        cache.retain(only: ids)
        cache.persist()
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
