import Foundation
import Photos
import SwiftUI

/// What an asset counts as in the storage breakdown. Each asset lands in exactly one
/// category (checked in this order), so the categories add up to the library total.
nonisolated enum StorageCategory: String, CaseIterable, Identifiable, Sendable, Codable {
    case video
    case screenshot
    case livePhoto
    case portrait
    case panorama
    /// Every other still photo.
    case photo

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .video: "ビデオ"
        case .screenshot: "スクリーンショット"
        case .livePhoto: "Live Photos"
        case .portrait: "ポートレート"
        case .panorama: "パノラマ"
        case .photo: "その他の写真"
        }
    }

    var systemImage: String {
        switch self {
        case .video: "video"
        case .screenshot: "camera.viewfinder"
        case .livePhoto: "livephoto"
        case .portrait: "cube"
        case .panorama: "pano"
        case .photo: "photo"
        }
    }

    var color: Color {
        switch self {
        case .video: .pink
        case .screenshot: .teal
        case .livePhoto: .orange
        case .portrait: .purple
        case .panorama: .green
        case .photo: .blue
        }
    }

    static func classify(mediaType: PHAssetMediaType, subtypes: PHAssetMediaSubtype) -> StorageCategory {
        if mediaType == .video { return .video }
        if subtypes.contains(.photoScreenshot) { return .screenshot }
        if subtypes.contains(.photoLive) { return .livePhoto }
        if subtypes.contains(.photoDepthEffect) { return .portrait }
        if subtypes.contains(.photoPanorama) { return .panorama }
        return .photo
    }
}

/// One measured asset, reduced to what the report needs (Sendable, no PhotoKit object).
nonisolated struct StorageItem: Sendable, Hashable {
    let id: String
    let category: StorageCategory
    /// `nil` when PhotoKit doesn't report a size (e.g. some iCloud-only items).
    let bytes: Int64?
}

/// The storage screen's numbers: library total, per-category breakdown and the
/// biggest files.
nonisolated struct StorageReport: Sendable, Equatable {
    struct CategorySummary: Sendable, Equatable, Identifiable {
        let category: StorageCategory
        let count: Int
        let bytes: Int64
        /// Biggest first, unknown sizes last: the order culling this category uses.
        let ids: [String]
        var id: StorageCategory { category }
    }

    let totalBytes: Int64
    let totalCount: Int
    /// Items PhotoKit gave no size for (counted, but not in the byte totals).
    let unknownCount: Int
    /// Non-empty categories, biggest first.
    let categories: [CategorySummary]
    /// The biggest files across the library, biggest first.
    let largest: [StorageItem]
    let measuredAt: Date

    static let topCount = 50

    static func build(_ items: [StorageItem], topCount: Int = topCount, measuredAt: Date = .now) -> StorageReport {
        let order = CullSort.largestFirst(items.map(\.bytes))
        let sorted = order.map { items[$0] }
        var byCategory: [StorageCategory: [StorageItem]] = [:]
        for item in sorted { byCategory[item.category, default: []].append(item) }
        let categories = byCategory.map { category, items in
            CategorySummary(
                category: category,
                count: items.count,
                bytes: items.reduce(0) { $0 + ($1.bytes ?? 0) },
                ids: items.map(\.id)
            )
        }
        .sorted { a, b in
            a.bytes != b.bytes ? a.bytes > b.bytes
                : (StorageCategory.allCases.firstIndex(of: a.category) ?? 0) < (StorageCategory.allCases.firstIndex(of: b.category) ?? 0)
        }
        return StorageReport(
            totalBytes: items.reduce(0) { $0 + ($1.bytes ?? 0) },
            totalCount: items.count,
            unknownCount: items.count { $0.bytes == nil },
            categories: categories,
            largest: Array(sorted.lazy.filter { $0.bytes != nil }.prefix(topCount)),
            measuredAt: measuredAt
        )
    }

    /// Share of the total, 0…1.
    func fraction(of summary: CategorySummary) -> Double {
        totalBytes > 0 ? Double(summary.bytes) / Double(totalBytes) : 0
    }
}
