import AVFoundation
import Photos
import UIKit

/// Thin wrapper around `PHCachingImageManager`.
///
/// Every PhotoKit request lives in a `nonisolated` method on purpose: PhotoKit may
/// invoke result handlers off the main thread, and closures formed in a
/// MainActor-isolated context would trap on the runtime isolation check.
/// `PHCachingImageManager` itself is thread-safe.
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    nonisolated private let manager = PHCachingImageManager()

    nonisolated init() {}

    // MARK: Pre-caching

    nonisolated func startCaching(_ assets: [PHAsset], targetSize: CGSize) {
        guard !assets.isEmpty else { return }
        manager.startCachingImages(for: assets, targetSize: targetSize, contentMode: .aspectFit, options: Self.cardOptions)
    }

    nonisolated func stopCaching(_ assets: [PHAsset], targetSize: CGSize) {
        guard !assets.isEmpty else { return }
        manager.stopCachingImages(for: assets, targetSize: targetSize, contentMode: .aspectFit, options: Self.cardOptions)
    }

    nonisolated func stopCachingAll() {
        manager.stopCachingImagesForAllAssets()
    }

    // MARK: Images

    /// Opportunistic for the card (fast degraded image, then full), high quality when zoomed.
    /// The stream finishes once the final image arrives.
    nonisolated func images(for asset: PHAsset, targetSize: CGSize, highQuality: Bool = false, contentMode: PHImageContentMode = .aspectFit) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            let options = highQuality ? Self.zoomOptions : Self.cardOptions
            let requestID = manager.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode, options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let finished = !degraded
                    || (info?[PHImageCancelledKey] as? Bool) == true
                    || info?[PHImageErrorKey] != nil
                if let image { continuation.yield(image) }
                if finished { continuation.finish() }
            }
            let manager = manager
            continuation.onTermination = { _ in manager.cancelImageRequest(requestID) }
        }
    }

    nonisolated func livePhoto(for asset: PHAsset, targetSize: CGSize) -> AsyncStream<PHLivePhoto> {
        AsyncStream { continuation in
            let options = PHLivePhotoRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = Self.allowsICloudDownload
            let requestID = manager.requestLivePhoto(for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options) { livePhoto, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if let livePhoto { continuation.yield(livePhoto) }
                if !degraded || info?[PHImageErrorKey] != nil { continuation.finish() }
            }
            let manager = manager
            continuation.onTermination = { _ in manager.cancelImageRequest(requestID) }
        }
    }

    nonisolated func videoAsset(for asset: PHAsset) async -> AVAsset? {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = Self.allowsICloudDownload
        let box = await withCheckedContinuation { (continuation: CheckedContinuation<AVAssetBox, Never>) in
            manager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: AVAssetBox(asset: avAsset))
            }
        }
        return box.asset
    }

    /// PhotoKit creates the `AVAsset` on its own queue and hands it over without
    /// keeping a reference, so transferring it to the caller is safe.
    nonisolated private struct AVAssetBox: @unchecked Sendable {
        let asset: AVAsset?
    }

    /// Original image bytes, used for EXIF parsing and file size.
    nonisolated func imageData(for asset: PHAsset) async -> Data? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = Self.allowsICloudDownload
        options.version = .current
        return await withCheckedContinuation { continuation in
            manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: Options

    nonisolated static let iCloudDownloadKey = "allowICloudDownload"

    /// Whether PhotoKit may fetch originals from the user's iCloud Photos for display,
    /// playback and EXIF (on by default; the app itself never makes network requests).
    /// Analysis — sizes, similar photos — never downloads either way.
    nonisolated static var allowsICloudDownload: Bool {
        UserDefaults.standard.object(forKey: iCloudDownloadKey) as? Bool ?? true
    }

    nonisolated private static var cardOptions: PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = Self.allowsICloudDownload
        return options
    }

    nonisolated private static var zoomOptions: PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = Self.allowsICloudDownload
        return options
    }
}
