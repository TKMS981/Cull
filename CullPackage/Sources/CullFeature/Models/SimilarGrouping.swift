import CoreGraphics
import Foundation

/// How alike two photos must look to count as similar: a cut-off on the Vision
/// feature-print distance (0 = identical; unrelated photos are typically 1.0 or more,
/// near-duplicates and burst frames well under 0.3).
nonisolated enum SimilarityLevel: String, CaseIterable, Identifiable, Sendable {
    /// Near-duplicates only.
    case strict
    case standard
    /// Also the same scene from a slightly different angle.
    case loose

    var id: String { rawValue }

    var threshold: Float {
        switch self {
        case .strict: 0.25
        case .standard: 0.45
        case .loose: 0.65
        }
    }

    /// The same cut-off for `ImageSignature.distance` (used where Vision can't run).
    var signatureThreshold: Float {
        switch self {
        case .strict: 0.05
        case .standard: 0.09
        case .loose: 0.12
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .strict: "ほぼ同じ写真のみ"
        case .standard: "標準"
        case .loose: "ゆるめ"
        }
    }
}

/// The pure parts of similar-photo detection: which pairs are worth comparing, how
/// matches join into groups, and which photo in a group to suggest keeping.
nonisolated enum SimilarGrouping {
    /// Photos taken more than this far apart are never compared.
    static let timeWindow: TimeInterval = 180
    /// Each photo is compared with at most this many earlier ones (bursts stay cheap).
    static let maxNeighbors = 8

    /// Index pairs `(earlier, later)` close enough in time to compare. `dates` must be
    /// in ascending order.
    static func candidatePairs(dates: [Date], window: TimeInterval = timeWindow, maxNeighbors: Int = maxNeighbors) -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        for later in dates.indices {
            var earlier = later - 1
            var compared = 0
            while earlier >= 0, compared < maxNeighbors, dates[later].timeIntervalSince(dates[earlier]) <= window {
                pairs.append((earlier, later))
                earlier -= 1
                compared += 1
            }
        }
        return pairs
    }

    /// Indices taking part in at least one pair: the only photos that need a feature print.
    static func indicesNeedingPrints(_ pairs: [(Int, Int)]) -> [Int] {
        var seen = Set<Int>()
        for (a, b) in pairs {
            seen.insert(a)
            seen.insert(b)
        }
        return seen.sorted()
    }

    /// Connected groups (size ≥ 2) of `count` items joined by `edges`, each sorted
    /// ascending, ordered by their first item.
    static func groups(count: Int, edges: [(Int, Int)]) -> [[Int]] {
        var parent = Array(0..<count)
        func root(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        for (a, b) in edges where a < count && b < count {
            let ra = root(a), rb = root(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }
        var members: [Int: [Int]] = [:]
        for index in 0..<count { members[root(index), default: []].append(index) }
        return members.values.filter { $0.count >= 2 }.sorted { $0[0] < $1[0] }
    }

    struct Candidate: Sendable, Equatable {
        var isFavorite = false
        var pixelCount = 0
        var bytes: Int64?
        var creationDate: Date?
    }

    /// The photo to suggest keeping: a favourite, else the most pixels, else the bigger
    /// file (more detail), else the newest (usually the last, steadiest frame).
    static func suggestedKeep(_ candidates: [Candidate]) -> Int? {
        candidates.indices.max { a, b in
            let x = candidates[a], y = candidates[b]
            if x.isFavorite != y.isFavorite { return !x.isFavorite }
            if x.pixelCount != y.pixelCount { return x.pixelCount < y.pixelCount }
            if (x.bytes ?? 0) != (y.bytes ?? 0) { return (x.bytes ?? 0) < (y.bytes ?? 0) }
            return (x.creationDate ?? .distantPast) < (y.creationDate ?? .distantPast)
        }
    }
}

/// A tiny colour thumbnail (16×16 RGB) compared pixel by pixel: the fallback when a
/// Vision feature print isn't available (e.g. the model can't run on this device).
/// Coarser than a feature print, but it reliably catches near-duplicates.
nonisolated struct ImageSignature: Sendable, Equatable {
    static let side = 16
    /// RGB values 0…1, row by row.
    let values: [Float]

    init(values: [Float]) {
        self.values = values
    }

    init?(image: CGImage) {
        let side = Self.side
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = buffer.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var values: [Float] = []
        values.reserveCapacity(side * side * 3)
        for pixel in 0..<(side * side) {
            for channel in 0..<3 { values.append(Float(buffer[pixel * 4 + channel]) / 255) }
        }
        self.values = values
    }

    /// Mean absolute difference, 0 (identical) … 1.
    func distance(to other: ImageSignature) -> Float {
        guard values.count == other.values.count, !values.isEmpty else { return 1 }
        return zip(values, other.values).reduce(0) { $0 + abs($1.0 - $1.1) } / Float(values.count)
    }
}

/// One group of look-alike photos found by a scan.
nonisolated struct SimilarGroup: Identifiable, Sendable, Hashable {
    /// Oldest first.
    let assetIDs: [String]
    let suggestedKeepID: String
    let startDate: Date?
    var id: String { assetIDs[0] }
}
