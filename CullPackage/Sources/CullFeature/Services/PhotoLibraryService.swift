import Foundation
import Observation
import Photos
import UIKit

/// `PHChange` is an immutable snapshot that PhotoKit hands us on a background queue;
/// it isn't annotated `Sendable`, so we box it to hop to the main actor.
struct LibraryChange: @unchecked Sendable {
    let change: PHChange
}

nonisolated struct AlbumInfo: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let count: Int
    let isSmartAlbum: Bool
}

/// Authorization, album/asset fetching and change fan-out.
@Observable
final class PhotoLibraryService {
    private(set) var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var albums: [AlbumInfo] = []

    @ObservationIgnored private var subscribers: [UUID: AsyncStream<LibraryChange>.Continuation] = [:]
    @ObservationIgnored private var observer: ChangeObserver?

    var hasAccess: Bool { status == .authorized || status == .limited }
    var isLimited: Bool { status == .limited }

    init() {
        if hasAccess { startObserving() }
    }

    func requestAuthorization() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if hasAccess { startObserving() }
    }

    func refreshStatus() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if hasAccess { startObserving() }
    }

    /// Lets a `.limited` user add more photos. Needs a presenting `UIViewController`
    /// because PhotoKit has no SwiftUI entry point for this picker.
    func presentLimitedLibraryPicker() async {
        guard let presenter = UIApplication.shared.topViewController else { return }
        _ = await PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter)
    }

    // MARK: Fetching

    func loadAlbums() async {
        albums = await Self.fetchAlbums()
    }

    /// Album enumeration + per-album counts, off the main actor.
    @concurrent
    nonisolated static func fetchAlbums() async -> [AlbumInfo] {
        var result: [AlbumInfo] = []
        let assetOptions = PHFetchOptions()
        assetOptions.predicate = CullFilter().predicate

        let smartSubtypes: [PHAssetCollectionSubtype] = [
            .smartAlbumFavorites, .smartAlbumRecentlyAdded, .smartAlbumScreenshots,
            .smartAlbumSelfPortraits, .smartAlbumDepthEffect, .smartAlbumLivePhotos,
            .smartAlbumVideos, .smartAlbumPanoramas, .smartAlbumBursts,
        ]
        for subtype in smartSubtypes {
            PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
                .enumerateObjects { collection, _, _ in
                    let count = PHAsset.fetchAssets(in: collection, options: assetOptions).count
                    guard count > 0 else { return }
                    result.append(AlbumInfo(id: collection.localIdentifier, title: collection.localizedTitle ?? "", count: count, isSmartAlbum: true))
                }
        }

        let userOptions = PHFetchOptions()
        userOptions.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: userOptions)
            .enumerateObjects { collection, _, _ in
                let count = PHAsset.fetchAssets(in: collection, options: assetOptions).count
                guard count > 0 else { return }
                result.append(AlbumInfo(id: collection.localIdentifier, title: collection.localizedTitle ?? "", count: count, isSmartAlbum: false))
            }
        return result
    }

    /// Matches for `filter` minus the given IDs (kept/trashed), off the main actor.
    /// The library case walks only the excluded IDs, so it never enumerates the whole
    /// library; an album still has to be walked.
    @concurrent
    nonisolated static func count(matching filter: CullFilter, excluding excluded: Set<String>) async -> Int {
        let total = filter.fetchAssets()
        guard !excluded.isEmpty, total.count > 0 else { return total.count }
        if filter.albumID == nil {
            // Only the excluded IDs are walked, tested in Swift: an identifier fetch
            // doesn't reliably apply the subtype bitmask predicate.
            var overlap = 0
            PHAsset.fetchAssets(withLocalIdentifiers: Array(excluded), options: nil).enumerateObjects { asset, _, _ in
                if filter.matches(asset) { overlap += 1 }
            }
            return max(total.count - overlap, 0)
        }
        var count = 0
        total.enumerateObjects { asset, _, _ in
            if !excluded.contains(asset.localIdentifier) { count += 1 }
        }
        return count
    }

    func assets(withIDs ids: [String]) -> [String: PHAsset] {
        guard !ids.isEmpty else { return [:] }
        var map: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            map[asset.localIdentifier] = asset
        }
        return map
    }

    // MARK: Changes

    /// A stream of library changes, delivered on the main actor. Ends when the consuming task is cancelled.
    func changes() -> AsyncStream<LibraryChange> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<LibraryChange>.makeStream(bufferingPolicy: .unbounded)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers[id] = nil }
        }
        return stream
    }

    private func startObserving() {
        guard observer == nil else { return }
        let observer = ChangeObserver { [weak self] change in
            self?.broadcast(change)
        }
        PHPhotoLibrary.shared().register(observer)
        self.observer = observer
    }

    private func broadcast(_ change: LibraryChange) {
        for continuation in subscribers.values { continuation.yield(change) }
    }
}

/// PhotoKit calls `photoLibraryDidChange` on a private background queue, so this
/// type is nonisolated and hops to the main actor before touching app state.
private final class ChangeObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    private let handler: @MainActor @Sendable (LibraryChange) -> Void

    init(handler: @escaping @MainActor @Sendable (LibraryChange) -> Void) {
        self.handler = handler
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        let boxed = LibraryChange(change: changeInstance)
        let handler = handler
        Task { @MainActor in handler(boxed) }
    }
}

extension UIApplication {
    var topViewController: UIViewController? {
        let scene = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? connectedScenes.first as? UIWindowScene
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
