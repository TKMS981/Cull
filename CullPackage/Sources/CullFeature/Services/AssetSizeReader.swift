import Photos

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
