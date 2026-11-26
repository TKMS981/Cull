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
