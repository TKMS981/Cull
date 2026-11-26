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
