import Foundation
import Observation
import Photos
import Synchronization
import UIKit
import Vision

/// Finds groups of look-alike photos on device: photos taken close together in time
/// (`SimilarGrouping.candidatePairs`) are compared by Vision image feature prints
/// (falling back to a pixel signature where Vision can't produce one), and matches
/// are joined into groups. Only photos with a near neighbour in time are
/// ever analysed, which is what keeps a scan of a few thousand photos practical.
enum SimilarPhotoFinder {
    /// Photos (not videos) in `filter`, minus `excluded`, oldest first.
    @concurrent
    nonisolated static func photoCount(filter: CullFilter, excluding excluded: Set<String>) async -> Int {
        photos(filter: filter, excluding: excluded).count
    }

    /// Returns `nil` if cancelled part-way. `progress` counts analysed photos.
    @concurrent
    nonisolated static func scan(
        filter: CullFilter,
        excluding excluded: Set<String>,
        level: SimilarityLevel,
        progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void
    ) async -> [SimilarGroup]? {
        let assets = photos(filter: filter, excluding: excluded)
        let dates = assets.map { $0.creationDate ?? .distantPast }
        let pairs = SimilarGrouping.candidatePairs(dates: dates)
        let needed = SimilarGrouping.indicesNeedingPrints(pairs)
        progress(0, needed.count)

        let analyses = await analyze(needed, of: AssetBox(assets: assets), progress: progress)
        guard !Task.isCancelled else { return nil }

        let edges = pairs.filter { a, b in
            guard let x = analyses[a], let y = analyses[b] else { return false }
            return x.isSimilar(to: y, level: level)
        }
        return SimilarGrouping.groups(count: assets.count, edges: edges).map { indices in
            let members = indices.map { assets[$0] }
            let candidates = members.map { asset in
                SimilarGrouping.Candidate(
                    isFavorite: asset.isFavorite,
                    pixelCount: asset.pixelWidth * asset.pixelHeight,
                    bytes: AssetSizeReader.cachedBytes(of: asset),
                    creationDate: asset.creationDate
                )
            }
            let keep = SimilarGrouping.suggestedKeep(candidates) ?? 0
            return SimilarGroup(
                assetIDs: members.map(\.localIdentifier),
                suggestedKeepID: members[keep].localIdentifier,
                startDate: members.first?.creationDate
            )
        }
    }

    // MARK: Internals

    /// `PHAsset` is an immutable, thread-safe snapshot that isn't annotated `Sendable`.
    nonisolated private struct AssetBox: @unchecked Sendable {
        let assets: [PHAsset]
    }

    nonisolated private static func photos(filter: CullFilter, excluding excluded: Set<String>) -> [PHAsset] {
        var assets: [PHAsset] = []
        filter.fetchAssets(sort: .oldest).enumerateObjects { asset, _, _ in
            if asset.mediaType == .image, asset.creationDate != nil, !excluded.contains(asset.localIdentifier) {
                assets.append(asset)
            }
        }
        return assets
    }

    /// Analyses run a few at a time (`ResourceGovernor`: 4, 2 in Low Power Mode, none
    /// while the device is hot), so memory stays flat and the device stays cool.
    nonisolated private static func analyze(
        _ indices: [Int],
        of box: AssetBox,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async -> [Int: Analysis] {
        let total = indices.count
        return await withTaskGroup(of: (Int, Analysis?).self) { group in
            var results: [Int: Analysis] = [:]
            var next = indices.makeIterator()
            var done = 0
            var inFlight = 0
            var exhausted = false
            while true {
                // Top up to what the device allows right now.
                while !exhausted, !Task.isCancelled {
                    let allowed = ResourceGovernor.concurrency(for: ResourceGovernor.currentPace)
                    if allowed == 0 {
                        if inFlight > 0 { break }      // let running work finish first
                        if !(await ResourceGovernor.waitUntilAllowed()) { exhausted = true }
                        continue
                    }
                    guard inFlight < allowed else { break }
                    guard let index = next.next() else {
                        exhausted = true
                        break
                    }
                    group.addTask(priority: .utility) { (index, await analysis(of: box.assets[index])) }
                    inFlight += 1
                }
                guard let (index, analysis) = await group.next() else { break }
                inFlight -= 1
                results[index] = analysis
                done += 1
                if done % 10 == 0 || done == total { progress(done, total) }
            }
            cache.persist()
            return results
        }
    }

    /// What one photo is compared by: its Vision feature print, plus a pixel signature
    /// used when either side has no usable print. Derived numbers only (no pixels).
    nonisolated struct Analysis: Codable, Sendable {
        let print: FeaturePrintObservation?
        let signature: ImageSignature

        func isSimilar(to other: Analysis, level: SimilarityLevel) -> Bool {
            if let a = print, let b = other.print, let distance = try? a.distance(to: b) {
                return Float(distance) <= level.threshold
            }
            return signature.distance(to: other.signature) <= level.signatureThreshold
        }
    }

    /// Analyses kept on disk, so a rescan (another level, an overlapping range, the
    /// next launch) only analyses new or edited photos.
    nonisolated static let cache = DiskCache<Analysis>(fileName: "SimilarAnalyses.plist", capacity: 20_000)

    /// Longest side of the thumbnail analysed. Vision scales its input down to a few
    /// hundred pixels anyway, so a full-resolution decode would only cost memory.
    nonisolated static let thumbnailSide: CGFloat = 300

    nonisolated static func analysis(of asset: PHAsset) async -> Analysis? {
        let id = asset.localIdentifier
        let modified = asset.modificationDate
        if let hit = cache.value(for: id, modified: modified) { return hit }
        // Decode and signature inside a pool: the UIImage and PhotoKit's temporaries
        // are released per photo instead of piling up across the scan.
        let prepared = autoreleasepool { () -> (CGImage, CGImagePropertyOrientation, ImageSignature)? in
            guard let (image, orientation) = thumbnail(for: asset), let signature = ImageSignature(image: image) else { return nil }
            return (image, orientation, signature)
        }
        guard let (image, orientation, signature) = prepared else { return nil }
        let print = try? await GenerateImageFeaturePrintRequest().perform(on: image, orientation: orientation)
        // No print where the model can't run (the simulator fails, or returns all
        // zeros, which would make every photo "identical"): use the signature instead.
        let usable = print.flatMap { $0.data.contains { $0 != 0 } ? $0 : nil }
        let analysis = Analysis(print: usable, signature: signature)
        cache.store(analysis, for: id, modified: modified)
        return analysis
    }

    /// A small local thumbnail (no iCloud download: an item that isn't on the device
    /// is simply left out of the comparison).
    nonisolated private static func thumbnail(for asset: PHAsset) -> (CGImage, CGImagePropertyOrientation)? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        let result = Mutex<UIImage?>(nil)
        PHImageManager.default().requestImage(
            for: asset, targetSize: CGSize(width: thumbnailSide, height: thumbnailSide), contentMode: .aspectFit, options: options
        ) { image, _ in
            result.withLock { $0 = image }
        }
        guard let image = result.withLock({ $0 }), let cgImage = image.cgImage else { return nil }
        return (cgImage, CGImagePropertyOrientation(image.imageOrientation))
    }
}

extension CGImagePropertyOrientation {
    nonisolated init(_ orientation: UIImage.Orientation) {
        self = switch orientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}

/// The similar-photos screen's state, owned by the root view so results survive
/// opening a group and coming back.
@Observable
final class SimilarScanModel {
    private(set) var groups: [SimilarGroup] = []
    private(set) var progress: ScanProgress?
    /// A scan has finished (so an empty `groups` means "none found").
    private(set) var hasResults = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UUID?

    init(groups: [SimilarGroup] = []) {
        self.groups = groups
        hasResults = !groups.isEmpty
    }

    var isScanning: Bool { progress != nil }
    var photoCount: Int { groups.reduce(0) { $0 + $1.assetIDs.count } }

    func scan(filter: CullFilter, excluding excluded: Set<String>, level: SimilarityLevel) {
        cancel()
        let generation = UUID()
        self.generation = generation
        progress = ScanProgress(done: 0, total: 0)
        let update: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in
                guard let self, self.generation == generation, let current = self.progress else { return }
                self.progress = ScanProgress(done: max(done, current.done), total: total)
            }
        }
        lastRequest = Request(filter: filter, excluded: excluded, level: level)
        task = Task(priority: .utility) {
            let found = await SimilarPhotoFinder.scan(filter: filter, excluding: excluded, level: level, progress: update)
            guard self.generation == generation else { return }
            if let found {
                groups = found
                hasResults = true
                lastRequest = nil
            }
            progress = nil
            task = nil
        }
    }

    private struct Request {
        let filter: CullFilter
        let excluded: Set<String>
        let level: SimilarityLevel
    }

    /// The scan in flight (cleared when it finishes), so one interrupted by leaving the
    /// app can pick up again; analysed photos come from the cache.
    @ObservationIgnored private var lastRequest: Request?

    /// The app went to the background: stop now, carry on when it's back.
    func suspend() {
        guard isScanning else { return }
        let request = lastRequest
        cancel()
        lastRequest = request
    }

    func resumeIfSuspended() {
        guard !isScanning, let request = lastRequest else { return }
        scan(filter: request.filter, excluding: request.excluded, level: request.level)
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation = nil
        progress = nil
        lastRequest = nil
    }

    /// Takes a group off the list once it's been sorted out (or items left the library).
    func remove(_ group: SimilarGroup) {
        groups.removeAll { $0.id == group.id }
    }

    /// Drops decided items; groups left with fewer than two photos go away.
    func prune(keeping isUndecided: (String) -> Bool) {
        groups = groups.compactMap { group in
            let ids = group.assetIDs.filter(isUndecided)
            guard ids.count >= 2 else { return nil }
            let keep = ids.contains(group.suggestedKeepID) ? group.suggestedKeepID : ids[0]
            return SimilarGroup(assetIDs: ids, suggestedKeepID: keep, startDate: group.startDate)
        }
    }
}
