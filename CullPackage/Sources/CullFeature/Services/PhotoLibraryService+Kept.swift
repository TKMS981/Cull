import Photos

extension PhotoLibraryService {
    /// `PHAsset` snapshots are immutable and thread-safe but not annotated `Sendable`.
    nonisolated struct AssetList: @unchecked Sendable {
        let assets: [PHAsset]
    }

    /// Kept assets that still exist, newest first, optionally narrowed to one attribute.
    /// Off the main actor: kept history can run to thousands of items.
    @concurrent
    nonisolated static func keptAssets(ids: Set<String>, attribute: MediaAttribute?) async -> AssetList {
        guard !ids.isEmpty else { return AssetList(assets: []) }
        let filter = CullFilter(attributes: attribute.map { [$0] } ?? [])
        let options = PHFetchOptions()
        options.sortDescriptors = CullSort.newest.fetchSortDescriptors
        let result = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            if filter.matches(asset) { assets.append(asset) }
        }
        return AssetList(assets: assets)
    }

    /// Which of `ids` match `filter` (album, dates, attributes), off the main actor.
    /// The whole-library case fetches just those IDs and tests them in Swift (an
    /// identifier fetch doesn't reliably apply the subtype bitmask predicate); an
    /// album has to be walked and intersected.
    @concurrent
    nonisolated static func ids(matching filter: CullFilter, among ids: Set<String>) async -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var matched: Set<String> = []
        if filter.albumID == nil {
            PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
                .enumerateObjects { asset, _, _ in
                    if filter.matches(asset) { matched.insert(asset.localIdentifier) }
                }
        } else {
            filter.fetchAssets().enumerateObjects { asset, _, _ in
                if ids.contains(asset.localIdentifier) { matched.insert(asset.localIdentifier) }
            }
        }
        return matched
    }
}
