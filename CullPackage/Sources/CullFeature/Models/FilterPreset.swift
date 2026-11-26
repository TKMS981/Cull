import Foundation

/// One-tap starting points on the setup screen. Each preset sets the whole filter
/// (whole library + attributes + optional date range), replacing what was there.
nonisolated public enum FilterPreset: String, CaseIterable, Identifiable, Sendable {
    case screenshots
    case thisMonth
    case lastMonth
    case videos
    case livePhotos
    case favorites

    public var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .screenshots: "スクリーンショット"
        case .thisMonth: "今月"
        case .lastMonth: "先月"
        case .videos: "ビデオ"
        case .livePhotos: "Live Photos"
        case .favorites: "お気に入り"
        }
    }

    var systemImage: String {
        switch self {
        case .screenshots: MediaAttribute.screenshot.systemImage
        case .thisMonth: "calendar"
        case .lastMonth: "calendar.badge.clock"
        case .videos: MediaAttribute.video.systemImage
        case .livePhotos: MediaAttribute.livePhoto.systemImage
        case .favorites: MediaAttribute.favorite.systemImage
        }
    }

    public var attributes: Set<MediaAttribute> {
        switch self {
        case .screenshots: [.screenshot]
        case .videos: [.video]
        case .livePhotos: [.livePhoto]
        case .favorites: [.favorite]
        case .thisMonth, .lastMonth: []
        }
    }

    /// Inclusive day range (as `CullFilter` reads it), or `nil` for "any date".
    public func dateRange(now: Date = .now, calendar: Calendar = .current) -> ClosedRange<Date>? {
        switch self {
        case .thisMonth:
            guard let month = calendar.dateInterval(of: .month, for: now) else { return nil }
            return month.start...now
        case .lastMonth:
            guard let thisMonth = calendar.dateInterval(of: .month, for: now),
                  let lastMonth = calendar.dateInterval(of: .month, for: thisMonth.start.addingTimeInterval(-1))
            else { return nil }
            // DateInterval.end is the first instant of this month; the range is inclusive of days.
            return lastMonth.start...lastMonth.end.addingTimeInterval(-1)
        default:
            return nil
        }
    }

    public func filter(now: Date = .now, calendar: Calendar = .current) -> CullFilter {
        CullFilter(albumID: nil, dateRange: dateRange(now: now, calendar: calendar), attributes: attributes)
    }

    /// Whether `filter` is what this preset would produce (dates compared by day).
    public func matches(_ filter: CullFilter, now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard filter.albumID == nil, filter.attributes == attributes else { return false }
        switch (filter.dateRange, dateRange(now: now, calendar: calendar)) {
        case (nil, nil):
            return true
        case let (actual?, expected?):
            return calendar.isDate(actual.lowerBound, inSameDayAs: expected.lowerBound)
                && calendar.isDate(actual.upperBound, inSameDayAs: expected.upperBound)
        default:
            return false
        }
    }
}
