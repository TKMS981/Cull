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
