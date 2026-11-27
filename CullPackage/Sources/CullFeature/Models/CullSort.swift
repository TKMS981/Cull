import Foundation

/// The order cards come up in, chosen on the setup screen.
nonisolated public enum CullSort: String, CaseIterable, Identifiable, Sendable, Codable {
    case newest
    case oldest
    /// Biggest files first: what frees the most space soonest.
    case largest

    public var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .newest: "新しい順"
        case .oldest: "古い順"
        case .largest: "容量が大きい順"
        }
    }

    var systemImage: String {
        switch self {
        case .newest: "arrow.down"
        case .oldest: "arrow.up"
        case .largest: "internaldrive"
        }
    }

    /// The PhotoKit fetch order. Size isn't fetchable, so `.largest` fetches newest
    /// first (its tie-break) and is re-sorted by size afterwards.
    var fetchSortDescriptors: [NSSortDescriptor] {
        [NSSortDescriptor(key: "creationDate", ascending: self == .oldest)]
    }

    /// Indices that put `sizes` biggest first. Stable, so equal sizes keep their fetch
    /// order, and items whose size is unknown go last.
    static func largestFirst(_ sizes: [Int64?]) -> [Int] {
        sizes.indices.sorted { a, b in
            switch (sizes[a], sizes[b]) {
            case let (x?, y?): x != y ? x > y : a < b
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a < b
            }
        }
    }
}
