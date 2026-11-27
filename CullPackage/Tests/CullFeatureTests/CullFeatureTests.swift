import CoreGraphics
import Foundation
import Photos
import Testing
@testable import CullFeature

struct Item: Identifiable, Equatable {
    let id: String
}

@Suite("CullQueue")
struct CullQueueTests {
    private func queue(_ ids: String...) -> CullQueue<Item> {
        CullQueue(ids.map(Item.init))
    }

    @Test func decideAdvancesAndRecordsHistory() {
        var q = queue("a", "b", "c")
        #expect(q.decide(.keep)?.id == "a")
        #expect(q.current?.id == "b")
        #expect(q.remaining == 2)
        #expect(q.history.map(\.decision) == [.keep])
    }

    @Test func multipleUndosRestoreInReverseOrder() {
        var q = queue("a", "b", "c")
        q.decide(.keep)
        q.decide(.trash)
        #expect(q.undo()?.element.id == "b")
        #expect(q.current?.id == "b")
        #expect(q.undo()?.element.id == "a")
        #expect(q.current?.id == "a")
        #expect(q.undo() == nil)
        #expect(q.remaining == 3)
    }

    @Test func decisionCountsFollowUndoAndRequeue() {
        var q = queue("a", "b", "c")
        q.decide(.keep)
        q.decide(.trash)
        q.decide(.trash)
        #expect(q.count(of: .keep) == 1)
        #expect(q.count(of: .trash) == 2)
        q.undo()
        #expect(q.count(of: .trash) == 1)
        q.requeue(Item(id: "b"))   // restored from trash
        #expect(q.count(of: .trash) == 0)
        #expect(q.count(of: .keep) == 1)
    }

    @Test func decideOnEmptyIsNoOp() {
        var q = queue()
        #expect(q.decide(.keep) == nil)
        #expect(!q.canUndo)
    }

    @Test func removeDropsFromPendingAndHistory() {
        var q = queue("a", "b", "c")
        q.decide(.trash)
        q.remove(ids: ["a", "c"])
        #expect(q.pending.map(\.id) == ["b"])
        #expect(q.history.isEmpty)
    }

    @Test func requeueAppendsAndClearsStaleHistory() {
        var q = queue("a", "b")
        q.decide(.trash)
        q.requeue(Item(id: "a"))
        #expect(q.pending.map(\.id) == ["b", "a"])
        #expect(!q.canUndo)
        q.requeue(Item(id: "a"))
        #expect(q.pending.map(\.id) == ["b", "a"], "duplicates are ignored")
    }

    @Test func appendSkipsKnownItems() {
        var q = queue("a", "b")
        q.decide(.keep)
        q.append([Item(id: "a"), Item(id: "b"), Item(id: "c")])
        #expect(q.pending.map(\.id) == ["b", "c"])
    }
}

@Suite("CullFilter predicate")
struct CullFilterTests {
    @Test func defaultRestrictsToImagesAndVideos() {
        let format = CullFilter().predicate.predicateFormat
        #expect(format.contains("mediaType == \(PHAssetMediaType.image.rawValue)"))
        #expect(format.contains("mediaType == \(PHAssetMediaType.video.rawValue)"))
        #expect(!format.contains("creationDate"))
    }

    @Test func attributesAreOredAndAndedWithDates() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let filter = CullFilter(dateRange: start...start.addingTimeInterval(86_400 * 3), attributes: [.screenshot, .video])
        let predicate = try #require(filter.predicate as? NSCompoundPredicate)
        #expect(predicate.compoundPredicateType == .and)
        let parts = try #require(predicate.subpredicates as? [NSPredicate])
        #expect(parts.count == 3)
        #expect(parts[1].predicateFormat.contains("creationDate"))
        let attributes = try #require(parts[2] as? NSCompoundPredicate)
        #expect(attributes.compoundPredicateType == .or)
        #expect(attributes.subpredicates.count == 2)
    }

    @Test func dateRangeIsInclusiveOfEndDay() throws {
        let calendar = Calendar.current
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 15)))
        let compound = try #require(CullFilter(dateRange: day...day).predicate as? NSCompoundPredicate)
        let dateClause = try #require(compound.subpredicates[1] as? NSPredicate)
        let start = calendar.startOfDay(for: day)
        let nextDay = try #require(calendar.date(byAdding: .day, value: 1, to: start))
        #expect(dateClause.evaluate(with: ["creationDate": start]))
        #expect(dateClause.evaluate(with: ["creationDate": nextDay.addingTimeInterval(-1)]))
        #expect(!dateClause.evaluate(with: ["creationDate": nextDay]))
    }

    @Test(arguments: MediaAttribute.allCases)
    func everyAttributeHasPredicate(_ attribute: MediaAttribute) {
        #expect(!attribute.predicate.predicateFormat.isEmpty)
    }
}

@Suite("DecisionStore", .serialized)
struct DecisionStoreTests {
    private func makeStore() throws -> DecisionStore {
        DecisionStore(container: try DecisionStore.makeContainer(inMemory: true))
    }

    @Test func keepAndTrashAreTrackedSeparately() throws {
        let store = try makeStore()
        store.record(.keep, for: "a")
        store.record(.trash, for: "b")
        #expect(store.keptIDs == ["a"])
        #expect(store.trash.map(\.id) == ["b"])
    }

    @Test func redecidingOverwrites() throws {
        let store = try makeStore()
        store.record(.trash, for: "a")
        store.record(.keep, for: "a")
        #expect(store.keptIDs == ["a"])
        #expect(store.trash.isEmpty)
    }

    @Test func clearRemovesDecision() throws {
        let store = try makeStore()
        store.record(.trash, for: "a")
        store.clear(ids: ["a"])
        #expect(store.trash.isEmpty)
    }

    @Test func resetKeptLeavesTrashAlone() throws {
        let store = try makeStore()
        store.record(.keep, for: "a")
        store.record(.keep, for: "b")
        store.record(.trash, for: "c")
        store.resetKept()
        #expect(store.keptIDs.isEmpty)
        #expect(store.trash.map(\.id) == ["c"])
    }

    /// The in-place cache updates must match what a fresh load from the same store sees.
    @Test func cachesMatchAFreshReload() throws {
        let container = try DecisionStore.makeContainer(inMemory: true)
        let store = DecisionStore(container: container)
        store.record(.trash, for: "a")
        store.record(.keep, for: "b")
        store.record(.trash, for: "c")
        store.record(.keep, for: "a")      // trash → keep
        store.record(.trash, for: "b")     // keep → trash
        store.record(.trash, for: "d")
        store.clear(ids: ["c", "missing"])

        #expect(store.keptIDs == ["a"])
        #expect(store.trash.map(\.id) == ["d", "b"])   // newest first
        #expect(store.trashedIDs == ["b", "d"])

        let reloaded = DecisionStore(container: container)
        #expect(reloaded.keptIDs == store.keptIDs)
        #expect(reloaded.trash == store.trash)
        #expect(reloaded.trashedIDs == store.trashedIDs)
    }
}

@Suite("FilterPreset")
struct FilterPresetTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    @Test func thisMonthRunsFromTheFirstToNow() {
        let now = date(2026, 3, 15, 10, 30)
        let range = FilterPreset.thisMonth.dateRange(now: now, calendar: calendar)
        #expect(range == date(2026, 3, 1)...now)
    }

    @Test func lastMonthIsTheWholePreviousMonth() {
        let range = FilterPreset.lastMonth.dateRange(now: date(2026, 3, 15), calendar: calendar)
        #expect(range == date(2026, 2, 1)...date(2026, 2, 28, 23, 59, 59))
    }

    @Test func lastMonthCrossesTheYear() {
        let range = FilterPreset.lastMonth.dateRange(now: date(2026, 1, 10), calendar: calendar)
        #expect(range == date(2025, 12, 1)...date(2025, 12, 31, 23, 59, 59))
    }

    @Test func attributePresetsHaveNoDateRange() {
        #expect(FilterPreset.screenshots.filter() == CullFilter(attributes: [.screenshot]))
        #expect(FilterPreset.videos.dateRange() == nil)
    }

    @Test(arguments: FilterPreset.allCases)
    func presetMatchesItsOwnFilterOnly(_ preset: FilterPreset) {
        let now = date(2026, 3, 15, 10)
        let own = preset.filter(now: now, calendar: calendar)
        #expect(preset.matches(own, now: now, calendar: calendar))
        for other in FilterPreset.allCases where other != preset {
            #expect(!other.matches(own, now: now, calendar: calendar))
        }
        var inAlbum = own
        inAlbum.albumID = "album"
        #expect(!preset.matches(inAlbum, now: now, calendar: calendar))
    }

    @Test func matchingComparesDaysNotInstants() {
        let now = date(2026, 3, 15, 10)
        // The date pickers keep a time of day; a later time on the same days still matches.
        let filter = CullFilter(dateRange: date(2026, 3, 1, 9)...date(2026, 3, 15, 23))
        #expect(FilterPreset.thisMonth.matches(filter, now: now, calendar: calendar))
    }
}

@Suite("SwipeRules")
struct SwipeRulesTests {
    private let width: CGFloat = 400 // threshold = 152

    @Test func noLockBeforeLockDistance() {
        #expect(SwipeRules.lock(CGSize(width: 8, height: 5)) == nil)
        #expect(SwipeRules.lock(CGSize(width: 14, height: 3)) == .horizontal)
        #expect(SwipeRules.lock(CGSize(width: 3, height: -14)) == .vertical)
    }

    @Test func horizontalTracksFingerOneToOne() {
        let offset = SwipeRules.cardOffset(CGSize(width: -73, height: 10), axis: .horizontal)
        #expect(offset.width == -73)
        #expect(SwipeRules.cardOffset(CGSize(width: 30, height: -200), axis: .vertical).width == 0)
    }

    @Test func shortDragSpringsBack() {
        let outcome = SwipeRules.outcome(translation: CGSize(width: -100, height: 0), predicted: CGSize(width: -140, height: 0), axis: .horizontal, width: width)
        #expect(outcome == .cancel)
    }

    @Test func pastThresholdCommits() {
        #expect(SwipeRules.outcome(translation: CGSize(width: -160, height: 20), predicted: CGSize(width: -170, height: 20), axis: .horizontal, width: width) == .decide(.keep))
        #expect(SwipeRules.outcome(translation: CGSize(width: 160, height: 0), predicted: CGSize(width: 165, height: 0), axis: .horizontal, width: width) == .decide(.trash))
    }

    @Test func thrownBackDoesNotCommit() {
        let outcome = SwipeRules.outcome(translation: CGSize(width: 170, height: 0), predicted: CGSize(width: 40, height: 0), axis: .horizontal, width: width)
        #expect(outcome == .cancel)
    }

    @Test func fastFlickCommitsButTinyFlickDoesNot() {
        #expect(SwipeRules.outcome(translation: CGSize(width: 60, height: 0), predicted: CGSize(width: 420, height: 0), axis: .horizontal, width: width) == .decide(.trash))
        #expect(SwipeRules.outcome(translation: CGSize(width: 20, height: 0), predicted: CGSize(width: 420, height: 0), axis: .horizontal, width: width) == .cancel)
    }

    @Test func verticalLockNeverDecides() {
        // Far sideways, but the drag locked vertical first.
        let outcome = SwipeRules.outcome(translation: CGSize(width: 300, height: -20), predicted: CGSize(width: 600, height: -20), axis: .vertical, width: width)
        #expect(outcome == .cancel)
        #expect(SwipeRules.armed(CGSize(width: 300, height: 0), axis: .vertical, width: width) == nil)
    }

    @Test func swipeUpOpensInfo() {
        #expect(SwipeRules.outcome(translation: CGSize(width: 0, height: -70), predicted: CGSize(width: 0, height: -90), axis: .vertical, width: width) == .info)
        #expect(SwipeRules.outcome(translation: CGSize(width: 0, height: -30), predicted: CGSize(width: 0, height: -250), axis: .vertical, width: width) == .info)
        #expect(SwipeRules.outcome(translation: CGSize(width: 0, height: 80), predicted: CGSize(width: 0, height: 200), axis: .vertical, width: width) == .cancel)
    }

    @Test func releaseBeforeLockCancels() {
        #expect(SwipeRules.outcome(translation: CGSize(width: 9, height: 0), predicted: CGSize(width: 500, height: 0), axis: nil, width: width) == .cancel)
    }
}

/// Regression: during fast consecutive swipes a card could spin and sail up the screen.
@Suite("Deck throw & drag isolation")
struct DeckThrowTests {
    private let size = CGSize(width: 400, height: 640)

    @Test(arguments: [Decision.keep, .trash], [
        CGSize(width: -160, height: -90), CGSize(width: 220, height: -400), CGSize(width: 0, height: 0),
        CGSize(width: 30, height: 25), CGSize(width: -999, height: -999),
    ])
    func thrownCardNeverRisesAndLeansItsWay(_ decision: Decision, release: CGSize) {
        let pose = SwipeRules.throwPose(decision, release: release, size: size)
        #expect(pose.offset.height >= SwipeRules.throwDrop, "never ends above its resting place")
        let leftward = decision == .keep
        #expect((pose.offset.width < 0) == leftward)
        #expect((pose.degrees < 0) == leftward, "leans the way it travels, so the bottom-anchored tilt swings it down")
        #expect(abs(pose.degrees) <= SwipeRules.maxTilt)
        #expect(abs(pose.offset.width) >= size.width, "fully off screen")
    }

    @Test func tiltIsBoundedAndSafeForDegenerateWidths() {
        #expect(SwipeRules.tilt(offsetX: 200, width: 400) == 6)
        #expect(SwipeRules.tilt(offsetX: 10_000, width: 400) == SwipeRules.maxTilt)
        #expect(SwipeRules.tilt(offsetX: -10_000, width: 400) == -SwipeRules.maxTilt)
        // Before: a zero width turned 600 pt into 7,200°.
        #expect(SwipeRules.tilt(offsetX: 600, width: 0) == 0)
        #expect(SwipeRules.tilt(offsetX: .nan, width: 400) == 0)
    }

    @Test func newCardStartsFromAFreshDrag() {
        // A vertical-locked, fenced drag on "a" that SwiftUI cancelled without onEnded…
        var stale = DeckDrag.next(nil, itemID: "a", translation: CGSize(width: 2, height: -40), width: 400, fenced: false)
        stale = DeckDrag.next(stale, itemID: "a", translation: CGSize(width: 2, height: -60), width: 400, fenced: true)
        #expect(stale.axis == .vertical)
        #expect(stale.fenced)
        // …must not leak into the next card.
        let fresh = DeckDrag.next(stale, itemID: "b", translation: CGSize(width: -30, height: 2), width: 400, fenced: false)
        #expect(fresh.itemID == "b")
        #expect(fresh.axis == .horizontal)
        #expect(!fresh.fenced)
        #expect(fresh.offset.width == -30)
    }

    @Test func axisStaysLockedWithinOneDrag() {
        var drag = DeckDrag.next(nil, itemID: "a", translation: CGSize(width: 20, height: 1), width: 400, fenced: false)
        drag = DeckDrag.next(drag, itemID: "a", translation: CGSize(width: 20, height: -300), width: 400, fenced: false)
        #expect(drag.axis == .horizontal)
        #expect(drag.offset.height == -300 * 0.12, "only a little vertical give while horizontal")
    }

    @Test func fencedDragParksTheCardAndNeverArms() {
        var drag = DeckDrag.next(nil, itemID: "a", translation: CGSize(width: 200, height: 0), width: 400, fenced: false)
        #expect(drag.armed == .trash)
        drag = DeckDrag.next(drag, itemID: "a", translation: CGSize(width: 260, height: 0), width: 400, fenced: true)
        #expect(drag.offset == .zero)
        #expect(drag.armed == nil)
        // Stays fenced for the rest of that drag even after the pinch ends.
        drag = DeckDrag.next(drag, itemID: "a", translation: CGSize(width: 300, height: 0), width: 400, fenced: false)
        #expect(drag.fenced && drag.offset == .zero)
    }
}

@Suite("CullSort")
struct CullSortTests {
    @Test func dateOrdersMapToFetchDescriptors() throws {
        let newest = try #require(CullFilter().fetchOptions(sort: .newest).sortDescriptors?.first)
        #expect(newest.key == "creationDate" && !newest.ascending)
        let oldest = try #require(CullFilter().fetchOptions(sort: .oldest).sortDescriptors?.first)
        #expect(oldest.key == "creationDate" && oldest.ascending)
        // Largest fetches newest first as its tie-break, then re-sorts by size.
        #expect(CullSort.largest.fetchSortDescriptors.first?.ascending == false)
    }

    @Test func largestFirstIsStableWithUnknownSizesLast() {
        let sizes: [Int64?] = [10, nil, 300, 10, 50, nil]
        #expect(CullSort.largestFirst(sizes) == [2, 4, 0, 3, 1, 5])
        #expect(CullSort.largestFirst([]) == [])
    }

    @Test func largestFirstHandlesTenThousandItemsQuickly() {
        let sizes: [Int64?] = (0..<10_000).map { (i: Int) -> Int64? in
            guard i % 97 != 0 else { return nil }
            return Int64((i * 7919) % 100_003)
        }
        let clock = ContinuousClock()
        var order: [Int] = []
        let elapsed = clock.measure { order = CullSort.largestFirst(sizes) }
        #expect(order.count == sizes.count)
        #expect(Set(order).count == sizes.count)
        let known = order.compactMap { sizes[$0] }
        #expect(known == known.sorted(by: >))
        #expect(elapsed < .seconds(1))
    }
}

@Suite("Skip (not now)")
struct SkipTests {
    private let width: CGFloat = 400

    @Test func skipIsCountedButUndoable() {
        var q = CullQueue(["a", "b", "c"].map(Item.init))
        q.decide(.skip)
        q.decide(.keep)
        #expect(q.count(of: .skip) == 1)
        #expect(q.current?.id == "c")
        q.undo()
        #expect(q.undo()?.decision == .skip)
        #expect(q.current?.id == "a")
        #expect(q.count(of: .skip) == 0)
    }

    @Test func storeNeverPersistsSkip() throws {
        let container = try DecisionStore.makeContainer(inMemory: true)
        let store = DecisionStore(container: container)
        store.record(.keep, for: "a")
        store.record(.skip, for: "a")
        store.record(.skip, for: "b")
        #expect(store.keptIDs == ["a"], "skipping a kept item leaves it kept")
        #expect(store.decision(for: "b") == nil)
        #expect(DecisionStore(container: container).keptIDs == ["a"])
    }

    @Test func batchRecordMatchesAFreshReload() throws {
        let container = try DecisionStore.makeContainer(inMemory: true)
        let store = DecisionStore(container: container)
        store.record(.keep, for: ["a", "b", "c"])
        store.record(.trash, for: ["b", "d"])
        #expect(store.keptIDs == ["a", "c"])
        #expect(store.trashedIDs == ["b", "d"])
        let reloaded = DecisionStore(container: container)
        #expect(reloaded.keptIDs == store.keptIDs)
        #expect(reloaded.trashedIDs == store.trashedIDs)
    }

    @Test func swipeDownSkips() {
        #expect(SwipeRules.outcome(translation: CGSize(width: 4, height: 140), predicted: CGSize(width: 4, height: 160), axis: .vertical, width: width) == .decide(.skip))
        #expect(SwipeRules.outcome(translation: CGSize(width: 0, height: 50), predicted: CGSize(width: 0, height: 400), axis: .vertical, width: width) == .decide(.skip), "flick")
        #expect(SwipeRules.armed(CGSize(width: 0, height: 130), axis: .vertical, width: width) == .skip)
    }

    @Test func shortOrThrownBackDownDragDoesNotSkip() {
        #expect(SwipeRules.outcome(translation: CGSize(width: 0, height: 80), predicted: CGSize(width: 0, height: 200), axis: .vertical, width: width) == .cancel)
        #expect(SwipeRules.outcome(translation: CGSize(width: 0, height: 150), predicted: CGSize(width: 0, height: 60), axis: .vertical, width: width) == .cancel)
        #expect(SwipeRules.outcome(translation: CGSize(width: 0, height: 20), predicted: CGSize(width: 0, height: 500), axis: .vertical, width: width) == .cancel, "tiny flick")
        // Horizontal-locked drags never skip, however far down they drift.
        #expect(SwipeRules.outcome(translation: CGSize(width: 60, height: 300), predicted: CGSize(width: 70, height: 600), axis: .horizontal, width: width) == .cancel)
    }

    @Test func skipDropsStraightDownOutOfTheDeck() {
        let size = CGSize(width: 400, height: 640)
        let pose = SwipeRules.throwPose(.skip, release: CGSize(width: 0, height: 90), size: size)
        #expect(pose.offset.width == 0)
        #expect(pose.degrees == 0)
        #expect(pose.offset.height > size.height)
        #expect(SwipeRules.cardOffset(CGSize(width: 0, height: 100), axis: .vertical).height == 60)
    }
}

@Suite("Kept list actions", .serialized)
struct KeptActionTests {
    @Test func unkeepingASubsetLeavesTheRestKept() throws {
        let store = DecisionStore(container: try DecisionStore.makeContainer(inMemory: true))
        store.record(.keep, for: ["shot1", "shot2", "video1", "photo1"])
        store.record(.trash, for: "t")
        store.clear(ids: ["shot1", "shot2"])      // e.g. "screenshots only"
        #expect(store.keptIDs == ["video1", "photo1"])
        #expect(store.trashedIDs == ["t"], "trash untouched")
    }

    @Test func sendingKeptItemsToTrashMovesThem() throws {
        let store = DecisionStore(container: try DecisionStore.makeContainer(inMemory: true))
        store.record(.keep, for: ["a", "b", "c"])
        store.record(.trash, for: ["a", "c"])
        #expect(store.keptIDs == ["b"])
        #expect(Set(store.trash.map(\.id)) == ["a", "c"])
    }
}

/// Swift-side matching (used for identifier fetches) must agree with the fetch predicate.
@Suite("CullFilter Swift matching")
struct CullFilterMatchingTests {
    @Test func attributesMatchLikeThePredicate() {
        let live = PHAssetMediaSubtype.photoLive
        #expect(CullFilter(attributes: [.livePhoto]).matches(mediaType: .image, subtypes: live, isFavorite: false, creationDate: nil))
        #expect(!CullFilter(attributes: [.video]).matches(mediaType: .image, subtypes: live, isFavorite: false, creationDate: nil))
        #expect(CullFilter(attributes: [.video, .screenshot]).matches(mediaType: .video, subtypes: [], isFavorite: false, creationDate: nil))
        #expect(CullFilter(attributes: [.favorite]).matches(mediaType: .image, subtypes: [], isFavorite: true, creationDate: nil))
        #expect(CullFilter().matches(mediaType: .image, subtypes: [], isFavorite: false, creationDate: nil))
        #expect(!CullFilter().matches(mediaType: .audio, subtypes: [], isFavorite: false, creationDate: nil))
    }

    @Test func datesUseTheSameInclusiveDays() throws {
        let calendar = Calendar.current
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 15)))
        let filter = CullFilter(dateRange: day...day)
        let start = calendar.startOfDay(for: day)
        let next = try #require(calendar.date(byAdding: .day, value: 1, to: start))
        #expect(filter.matches(mediaType: .image, subtypes: [], isFavorite: false, creationDate: start))
        #expect(filter.matches(mediaType: .image, subtypes: [], isFavorite: false, creationDate: next.addingTimeInterval(-1)))
        #expect(!filter.matches(mediaType: .image, subtypes: [], isFavorite: false, creationDate: next))
        #expect(!filter.matches(mediaType: .image, subtypes: [], isFavorite: false, creationDate: nil))
    }
}

@Suite("Storage report")
struct StorageReportTests {
    @Test func eachAssetHasOneCategory() {
        let examples: [(PHAssetMediaType, PHAssetMediaSubtype, StorageCategory)] = [
            (.video, .videoHighFrameRate, .video),
            (.image, .photoScreenshot, .screenshot),
            (.image, [.photoLive, .photoDepthEffect], .livePhoto),
            (.image, .photoDepthEffect, .portrait),
            (.image, .photoPanorama, .panorama),
            (.image, .photoHDR, .photo),
            (.image, [], .photo),
        ]
        for (type, subtypes, expected) in examples {
            #expect(StorageCategory.classify(mediaType: type, subtypes: subtypes) == expected)
        }
    }

    @Test func totalsBreakdownAndRanking() {
        let items = [
            StorageItem(id: "p1", category: .photo, bytes: 3_000_000),
            StorageItem(id: "v1", category: .video, bytes: 80_000_000),
            StorageItem(id: "p2", category: .photo, bytes: 5_000_000),
            StorageItem(id: "s1", category: .screenshot, bytes: 400_000),
            StorageItem(id: "v2", category: .video, bytes: nil),
            StorageItem(id: "v3", category: .video, bytes: 20_000_000),
        ]
        let report = StorageReport.build(items, topCount: 3)
        #expect(report.totalCount == 6)
        #expect(report.totalBytes == 108_400_000)
        #expect(report.unknownCount == 1)
        #expect(report.categories.map(\.category) == [.video, .photo, .screenshot], "biggest category first")
        let videos = report.categories[0]
        #expect(videos.count == 3)
        #expect(videos.bytes == 100_000_000)
        #expect(videos.ids == ["v1", "v3", "v2"], "biggest first, unknown size last")
        #expect(report.largest.map(\.id) == ["v1", "v3", "p2"])
        #expect(report.categories.map(\.bytes).reduce(0, +) == report.totalBytes, "categories add up to the total")
        #expect(abs(report.fraction(of: videos) - 100.0 / 108.4) < 0.0001)
    }

    @Test func emptyLibrary() {
        let report = StorageReport.build([])
        #expect(report.totalBytes == 0)
        #expect(report.categories.isEmpty)
        #expect(report.largest.isEmpty)
    }

    @Test func tenThousandItemsBuildQuickly() {
        let categories = StorageCategory.allCases
        let items = (0..<10_000).map { i in
            StorageItem(id: "\(i)", category: categories[i % categories.count], bytes: i % 97 == 0 ? nil : Int64((i * 7919) % 50_000_000))
        }
        let start = ContinuousClock.now
        let report = StorageReport.build(items)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(report.largest.count == StorageReport.topCount)
        #expect(zip(report.largest, report.largest.dropFirst()).allSatisfy { ($0.bytes ?? 0) >= ($1.bytes ?? 0) })
    }
}

@Suite("Similar photo grouping")
struct SimilarGroupingTests {
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func onlyPhotosCloseInTimeAreCompared() {
        let dates = [0, 10, 20, 1_000, 5_000, 5_100].map { base.addingTimeInterval($0) }
        let pairs = SimilarGrouping.candidatePairs(dates: dates, window: 180).map { [$0.0, $0.1] }
        #expect(pairs == [[0, 1], [1, 2], [0, 2], [4, 5]])
        #expect(SimilarGrouping.indicesNeedingPrints(SimilarGrouping.candidatePairs(dates: dates, window: 180)) == [0, 1, 2, 4, 5],
                "a photo with no neighbour in time is never analysed")
    }

    @Test func neighboursAreCappedInABurst() {
        let burst = (0..<30).map { base.addingTimeInterval(Double($0) * 0.1) }
        let pairs = SimilarGrouping.candidatePairs(dates: burst, window: 180, maxNeighbors: 4)
        #expect(pairs.count == 0 + 1 + 2 + 3 + 4 * 26)
        #expect(pairs.allSatisfy { $0.1 - $0.0 <= 4 })
    }

    @Test func matchesJoinIntoGroups() {
        let groups = SimilarGrouping.groups(count: 7, edges: [(0, 1), (1, 2), (4, 5), (5, 4), (9, 1)])
        #expect(groups == [[0, 1, 2], [4, 5]], "chained matches join; singletons and out-of-range edges dropped")
        #expect(SimilarGrouping.groups(count: 3, edges: []).isEmpty)
    }

    @Test func suggestedKeepPrefersFavouriteThenResolution() {
        typealias C = SimilarGrouping.Candidate
        let early = base, late = base.addingTimeInterval(2)
        #expect(SimilarGrouping.suggestedKeep([C(pixelCount: 12), C(isFavorite: true, pixelCount: 1), C(pixelCount: 48)]) == 1)
        #expect(SimilarGrouping.suggestedKeep([C(pixelCount: 12), C(pixelCount: 48), C(pixelCount: 24)]) == 1)
        #expect(SimilarGrouping.suggestedKeep([C(pixelCount: 12, bytes: 1), C(pixelCount: 12, bytes: 9)]) == 1)
        #expect(SimilarGrouping.suggestedKeep([C(pixelCount: 12, creationDate: late), C(pixelCount: 12, creationDate: early)]) == 0)
        #expect(SimilarGrouping.suggestedKeep([]) == nil)
    }

    @Test func levelsAreOrdered() {
        #expect(SimilarityLevel.strict.threshold < SimilarityLevel.standard.threshold)
        #expect(SimilarityLevel.standard.threshold < SimilarityLevel.loose.threshold)
    }

    @Test func periodsEndNowAndNeverCoverEverything() throws {
        let now = base
        for period in SimilarPeriod.allCases where period != .custom {
            let range = try #require(period.range(endingAt: now))
            #expect(range.upperBound == now)
            #expect(now.timeIntervalSince(range.lowerBound) <= 366 * 86_400)
        }
        #expect(SimilarPeriod.custom.range(endingAt: now) == nil)
    }

    @Test func pruningDropsDecidedItemsAndTinyGroups() {
        let model = SimilarScanModel(groups: [
            SimilarGroup(assetIDs: ["a", "b", "c"], suggestedKeepID: "b", startDate: nil),
            SimilarGroup(assetIDs: ["d", "e"], suggestedKeepID: "d", startDate: nil),
        ])
        #expect(model.photoCount == 5)
        model.prune { !["b", "e"].contains($0) }
        #expect(model.groups.map(\.assetIDs) == [["a", "c"]], "a group left with one photo goes away")
        #expect(model.groups.first?.suggestedKeepID == "a", "suggestion moves off a decided photo")
        model.remove(model.groups[0])
        #expect(model.groups.isEmpty)
    }
}

@Suite("Space freed", .serialized)
struct SavingsTests {
    @Test func deletionsAddUpAndPersist() throws {
        let container = try DecisionStore.makeContainer(inMemory: true)
        let store = DecisionStore(container: container)
        #expect(store.deletedCount == 0)
        #expect(store.freedBytes == 0)
        store.recordDeletion(count: 3, bytes: 12_000_000)
        store.recordDeletion(count: 1, bytes: 500)
        store.recordDeletion(count: 0, bytes: 99)     // nothing deleted: ignored
        #expect(store.deletedCount == 4)
        #expect(store.freedBytes == 12_000_500)
        let reloaded = DecisionStore(container: container)
        #expect(reloaded.deletedCount == 4)
        #expect(reloaded.freedBytes == 12_000_500)
    }

    @Test func resettingKeptHistoryKeepsTheTotals() throws {
        let store = DecisionStore(container: try DecisionStore.makeContainer(inMemory: true))
        store.record(.keep, for: ["a"])
        store.recordDeletion(count: 2, bytes: 1_000)
        store.resetKept()
        store.clear(ids: ["a"])
        #expect(store.deletedCount == 2)
        #expect(store.freedBytes == 1_000)
    }
}

@Suite("Asset selection route")
struct AssetSelectionTests {
    @Test func selectionsCompareByIdentityNotContents() {
        let a = AssetSelection(ids: ["x", "y"], includeKept: false)
        let b = AssetSelection(ids: ["x", "y"], includeKept: false)
        #expect(a != b)
        #expect(a == a)
        #expect(Route.cullSelection(a) == Route.cullSelection(a))
    }
}

@Suite("Image signature fallback")
struct ImageSignatureTests {
    /// A 64×64 image: solid `background` with a white square at `square`.
    private func image(background: (UInt8, UInt8, UInt8), square: CGRect) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: CGFloat(background.0) / 255, green: CGFloat(background.1) / 255, blue: CGFloat(background.2) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(square)
        return try #require(context.makeImage())
    }

    @Test func nearDuplicatesAreCloseAndDifferentScenesAreNot() throws {
        let a = try #require(ImageSignature(image: image(background: (120, 0, 160), square: CGRect(x: 16, y: 16, width: 24, height: 24))))
        let shifted = try #require(ImageSignature(image: image(background: (120, 0, 160), square: CGRect(x: 18, y: 17, width: 24, height: 24))))
        let other = try #require(ImageSignature(image: image(background: (10, 160, 40), square: CGRect(x: 40, y: 4, width: 20, height: 50))))
        #expect(a.values.count == ImageSignature.side * ImageSignature.side * 3)
        #expect(a.distance(to: a) == 0)
        #expect(a.distance(to: shifted) <= SimilarityLevel.strict.signatureThreshold)
        #expect(a.distance(to: other) > SimilarityLevel.loose.signatureThreshold)
        #expect(a.distance(to: shifted) == shifted.distance(to: a))
    }

    @Test func mismatchedSignaturesAreFarApart() {
        #expect(ImageSignature(values: [0, 0, 0]).distance(to: ImageSignature(values: [])) == 1)
    }
}

@Suite("Resource governor")
struct ResourceGovernorTests {
    @Test func paceFollowsPowerAndHeat() {
        #expect(ResourceGovernor.pace(lowPower: false, thermal: .nominal) == .normal)
        #expect(ResourceGovernor.pace(lowPower: true, thermal: .nominal) == .reduced)
        #expect(ResourceGovernor.pace(lowPower: false, thermal: .fair) == .reduced)
        #expect(ResourceGovernor.pace(lowPower: false, thermal: .serious) == .paused)
        #expect(ResourceGovernor.pace(lowPower: true, thermal: .critical) == .paused)
    }

    @Test func concurrencyIsCappedAndHalvedAndStopped() {
        #expect(ResourceGovernor.concurrency(for: .normal) == ResourceGovernor.maxConcurrency)
        #expect(ResourceGovernor.maxConcurrency <= 6)
        #expect(ResourceGovernor.concurrency(for: .reduced) == ResourceGovernor.maxConcurrency / 2)
        #expect(ResourceGovernor.concurrency(for: .reduced, limit: 1) == 1)
        #expect(ResourceGovernor.concurrency(for: .paused) == 0)
    }
}

@Suite("Disk cache")
struct DiskCacheTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "DiskCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func reusesUntilTheAssetIsModified() throws {
        let cache = DiskCache<Int>(fileName: "c.plist", capacity: 10, directory: try makeDirectory())
        let day1 = Date(timeIntervalSinceReferenceDate: 1), day2 = Date(timeIntervalSinceReferenceDate: 2)
        #expect(cache.value(for: "a", modified: day1) == nil)
        cache.store(42, for: "a", modified: day1)
        #expect(cache.value(for: "a", modified: day1) == 42)
        #expect(cache.value(for: "a", modified: day2) == nil, "edited since: measure again")
        cache.store(7, for: "b", modified: nil)
        #expect(cache.value(for: "b", modified: nil) == 7)
    }

    @Test func persistsAcrossInstancesAndPrunes() throws {
        let directory = try makeDirectory()
        let first = DiskCache<String>(fileName: "c.plist", capacity: 10, directory: directory)
        first.store("x", for: "a", modified: nil)
        first.store("y", for: "b", modified: nil)
        first.persist()
        let second = DiskCache<String>(fileName: "c.plist", capacity: 10, directory: directory)
        #expect(second.value(for: "a", modified: nil) == "x")
        second.retain(only: ["b"])
        second.persist()
        let third = DiskCache<String>(fileName: "c.plist", capacity: 10, directory: directory)
        #expect(third.value(for: "a", modified: nil) == nil, "deleted assets leave the cache")
        #expect(third.value(for: "b", modified: nil) == "y")
        third.removeAll()
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "c.plist").path()))
    }

    @Test func capacityIsEnforcedOnWrite() throws {
        let cache = DiskCache<Int>(fileName: "c.plist", capacity: 3, directory: try makeDirectory())
        for i in 0..<10 { cache.store(i, for: "id\(i)", modified: nil) }
        cache.persist()
        #expect(cache.count == 3)
    }

    @Test func signaturesRoundTrip() throws {
        let signature = ImageSignature(values: [0, 0.5, 1])
        let data = try PropertyListEncoder().encode(signature)
        #expect(try PropertyListDecoder().decode(ImageSignature.self, from: data) == signature)
    }
}
