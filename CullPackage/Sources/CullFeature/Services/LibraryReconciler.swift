import Photos

/// Keeps Cull's own records in step with the library: assets deleted in the Photos
/// app (or anywhere else) are dropped from kept history, Cull's trash, similar-photo
/// results and the on-disk caches, so stale identifiers don't pile up.
enum LibraryReconciler {
    /// Only with full access can "not returned by PhotoKit" be read as "deleted":
    /// with limited access, unselected assets are just invisible and must be kept.
    nonisolated static func canPrune(_ status: PHAuthorizationStatus) -> Bool {
        status == .authorized
    }

    /// Which of `ids` no longer exist, given the ones PhotoKit still returns.
    nonisolated static func missing(_ ids: Set<String>, existing: Set<String>) -> Set<String> {
        ids.subtracting(existing)
    }

    /// Which of `ids` still exist, off the main actor (one identifier fetch).
    @concurrent
    nonisolated static func existing(among ids: Set<String>) async -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var found = Set<String>()
        found.reserveCapacity(ids.count)
        PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil).enumerateObjects { asset, _, _ in
            found.insert(asset.localIdentifier)
        }
        return found
    }

    /// Drops cache entries for assets that are gone. Run once per launch, at low priority.
    @concurrent
    nonisolated static func pruneCaches() async {
        for cache in [AssetSizeReader.cache.keyedPruner, SimilarPhotoFinder.cache.keyedPruner] {
            let keys = cache.keys()
            guard !keys.isEmpty, !Task.isCancelled else { continue }
            let alive = await existing(among: keys)
            cache.retain(alive)
        }
    }
}

/// Type-erased "list keys / keep these keys" access to a `DiskCache`.
nonisolated struct CachePruner: Sendable {
    let keys: @Sendable () -> Set<String>
    let retain: @Sendable (Set<String>) -> Void
}

extension DiskCache {
    nonisolated var keyedPruner: CachePruner {
        CachePruner(
            keys: { [self] in allKeys },
            retain: { [self] ids in
                retain(only: ids)
                persist()
            }
        )
    }
}
