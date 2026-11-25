import Foundation
import Photos

/// Attribute filters offered on the setup screen. Multiple selections are OR-ed together.
public enum MediaAttribute: String, CaseIterable, Identifiable, Sendable, Codable {
    case screenshot
    case portrait
    case livePhoto
    case video
    case favorite
    case panorama
    case hdr

    public var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .screenshot: "スクリーンショット"
        case .portrait: "ポートレート"
        case .livePhoto: "Live Photos"
        case .video: "ビデオ"
        case .favorite: "お気に入り"
        case .panorama: "パノラマ"
        case .hdr: "HDR"
        }
    }

    var systemImage: String {
        switch self {
        case .screenshot: "camera.viewfinder"
        case .portrait: "cube"
        case .livePhoto: "livephoto"
        case .video: "video"
        case .favorite: "heart"
        case .panorama: "pano"
        case .hdr: "camera.filters"
        }
    }

    /// A single-attribute predicate for `PHFetchOptions`.
    var predicate: NSPredicate {
        switch self {
        case .screenshot: Self.subtype(.photoScreenshot)
        case .portrait: Self.subtype(.photoDepthEffect)
        case .livePhoto: Self.subtype(.photoLive)
        case .panorama: Self.subtype(.photoPanorama)
        case .hdr: Self.subtype(.photoHDR)
        case .video: NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        case .favorite: NSPredicate(format: "favorite == YES")
        }
    }

    private static func subtype(_ subtype: PHAssetMediaSubtype) -> NSPredicate {
        NSPredicate(format: "(mediaSubtypes & %d) != 0", subtype.rawValue)
    }
}

/// What the user chose to cull. Album and date range AND with the attribute group;
/// attributes OR with each other.
public struct CullFilter: Hashable, Sendable {
    /// `PHAssetCollection.localIdentifier`, or `nil` for the whole library.
    public var albumID: String?
    public var dateRange: ClosedRange<Date>?
    public var attributes: Set<MediaAttribute> = []

    public init(albumID: String? = nil, dateRange: ClosedRange<Date>? = nil, attributes: Set<MediaAttribute> = []) {
        self.albumID = albumID
        self.dateRange = dateRange
        self.attributes = attributes
    }

    /// The compound predicate used for the fetch. Always restricts to photos and videos.
    public var predicate: NSPredicate {
        var parts: [NSPredicate] = [
            NSPredicate(
                format: "mediaType == %d || mediaType == %d",
                PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
            ),
        ]
        if let dateRange {
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: dateRange.lowerBound)
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: dateRange.upperBound)) ?? dateRange.upperBound
            parts.append(NSPredicate(format: "creationDate >= %@ && creationDate < %@", start as NSDate, end as NSDate))
        }
        if !attributes.isEmpty {
            let ordered = MediaAttribute.allCases.filter(attributes.contains)
            parts.append(NSCompoundPredicate(orPredicateWithSubpredicates: ordered.map(\.predicate)))
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    public var fetchOptions: PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = predicate
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        return options
    }
}
