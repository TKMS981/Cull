import Foundation
import Photos

/// Attribute filters offered on the setup screen. Multiple selections are OR-ed together.
nonisolated public enum MediaAttribute: String, CaseIterable, Identifiable, Sendable, Codable {
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

    /// The same test as `predicate`, evaluated on an asset already in hand. Used for
    /// identifier fetches, where PhotoKit doesn't reliably apply the subtype bitmask.
    func matches(mediaType: PHAssetMediaType, subtypes: PHAssetMediaSubtype, isFavorite: Bool) -> Bool {
        switch self {
        case .screenshot: subtypes.contains(.photoScreenshot)
        case .portrait: subtypes.contains(.photoDepthEffect)
        case .livePhoto: subtypes.contains(.photoLive)
        case .panorama: subtypes.contains(.photoPanorama)
        case .hdr: subtypes.contains(.photoHDR)
        case .video: mediaType == .video
        case .favorite: isFavorite
        }
    }

    private static func subtype(_ subtype: PHAssetMediaSubtype) -> NSPredicate {
        NSPredicate(format: "(mediaSubtypes & %d) != 0", subtype.rawValue)
    }
}

/// What the user chose to cull. Album and date range AND with the attribute group;
/// attributes OR with each other.
nonisolated public struct CullFilter: Hashable, Sendable {
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

    /// The date range as the half-open day interval the predicate uses.
    var dayInterval: Range<Date>? {
        guard let dateRange else { return nil }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: dateRange.lowerBound)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: dateRange.upperBound)) ?? dateRange.upperBound
        return start..<max(end, start)
    }

    /// Media type, date and attribute clauses evaluated in Swift (album membership is
    /// not checked). Mirrors `predicate`.
    public func matches(mediaType: PHAssetMediaType, subtypes: PHAssetMediaSubtype, isFavorite: Bool, creationDate: Date?) -> Bool {
        guard mediaType == .image || mediaType == .video else { return false }
        if let interval = dayInterval {
            guard let creationDate, interval.contains(creationDate) else { return false }
        }
        guard !attributes.isEmpty else { return true }
        return attributes.contains { $0.matches(mediaType: mediaType, subtypes: subtypes, isFavorite: isFavorite) }
    }

    public func matches(_ asset: PHAsset) -> Bool {
        matches(mediaType: asset.mediaType, subtypes: asset.mediaSubtypes, isFavorite: asset.isFavorite, creationDate: asset.creationDate)
    }

    /// Runs the fetch. Safe off the main actor: PhotoKit fetches are thread-safe.
    public func fetchAssets(sort: CullSort = .oldest) -> PHFetchResult<PHAsset> {
        let options = fetchOptions(sort: sort)
        if let albumID,
           let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject {
            return PHAsset.fetchAssets(in: collection, options: options)
        }
        return PHAsset.fetchAssets(with: options)
    }

    public func fetchOptions(sort: CullSort) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = predicate
        options.sortDescriptors = sort.fetchSortDescriptors
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        return options
    }
}
