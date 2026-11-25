import AVFoundation
import CoreLocation
import Foundation
import ImageIO
import Photos

/// Everything the info sheet shows. Plain values only, so it's `Sendable`.
struct AssetInfo: Sendable, Equatable {
    enum Kind: Sendable { case photo, livePhoto, video, screenshot, portrait, panorama }

    var kind: Kind
    var creationDate: Date?
    var fileName: String?
    var pixelWidth: Int
    var pixelHeight: Int
    var duration: TimeInterval?
    var fileSize: Int64?
    var coordinate: CLLocationCoordinate2D?
    var isFavorite: Bool

    // From EXIF/TIFF (photos only)
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var fNumber: Double?
    var exposureTime: Double?
    var iso: Int?
    var focalLength35mm: Int?
    var uniformType: String?

    var megapixels: Double { Double(pixelWidth * pixelHeight) / 1_000_000 }

    var cameraName: String? {
        switch (cameraMake, cameraModel) {
        case let (make?, model?) where model.hasPrefix(make): model
        case let (make?, model?): "\(make) \(model)"
        case let (nil, model?): model
        case let (make?, nil): make
        default: nil
        }
    }

    static func == (lhs: AssetInfo, rhs: AssetInfo) -> Bool {
        lhs.creationDate == rhs.creationDate && lhs.fileName == rhs.fileName
            && lhs.fileSize == rhs.fileSize && lhs.cameraModel == rhs.cameraModel
    }
}

enum MetadataReader {
    /// Builds the basic info synchronously from `PHAsset` (cheap), then fills in
    /// EXIF / file size from the original data, parsed off the main actor.
    static func info(for asset: PHAsset, loader: ImageLoader = .shared) async -> AssetInfo {
        var info = basicInfo(for: asset)
        switch asset.mediaType {
        case .video:
            if let avAsset = await loader.videoAsset(for: asset), let urlAsset = avAsset as? AVURLAsset {
                info.fileSize = await fileSize(at: urlAsset.url)
                if let duration = try? await urlAsset.load(.duration) {
                    info.duration = duration.seconds
                }
            }
        default:
            if let data = await loader.imageData(for: asset) {
                let exif = await parseImageProperties(data)
                info.fileSize = Int64(data.count)
                info.cameraMake = exif.make
                info.cameraModel = exif.model
                info.lensModel = exif.lens
                info.fNumber = exif.fNumber
                info.exposureTime = exif.exposure
                info.iso = exif.iso
                info.focalLength35mm = exif.focal35
                info.uniformType = exif.uti
            }
        }
        return info
    }

    static func basicInfo(for asset: PHAsset) -> AssetInfo {
        let subtypes = asset.mediaSubtypes
        let kind: AssetInfo.Kind =
            if asset.mediaType == .video { .video }
            else if subtypes.contains(.photoLive) { .livePhoto }
            else if subtypes.contains(.photoScreenshot) { .screenshot }
            else if subtypes.contains(.photoDepthEffect) { .portrait }
            else if subtypes.contains(.photoPanorama) { .panorama }
            else { .photo }
        let resources = PHAssetResource.assetResources(for: asset)
        let primary = resources.first { $0.type == .photo || $0.type == .video } ?? resources.first
        return AssetInfo(
            kind: kind,
            creationDate: asset.creationDate,
            fileName: primary?.filename,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.mediaType == .video ? asset.duration : nil,
            coordinate: asset.location?.coordinate,
            isFavorite: asset.isFavorite
        )
    }

    struct ImageProperties: Sendable {
        var make: String?
        var model: String?
        var lens: String?
        var fNumber: Double?
        var exposure: Double?
        var iso: Int?
        var focal35: Int?
        var uti: String?
    }

    @concurrent
    static func parseImageProperties(_ data: Data) async -> ImageProperties {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return ImageProperties() }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        return ImageProperties(
            make: (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces),
            model: (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces),
            lens: exif[kCGImagePropertyExifLensModel] as? String,
            fNumber: exif[kCGImagePropertyExifFNumber] as? Double,
            exposure: exif[kCGImagePropertyExifExposureTime] as? Double,
            iso: (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first,
            focal35: exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int,
            uti: CGImageSourceGetType(source) as String?
        )
    }

    @concurrent
    static func fileSize(at url: URL) async -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }
}
