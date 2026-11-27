import Foundation
import Observation
import SwiftData

/// One persisted keep/trash decision per asset (`.skip` is never stored).
@Model
final class AssetDecision {
    @Attribute(.unique) var localIdentifier: String
    var decisionRaw: String
    var decidedAt: Date

    init(localIdentifier: String, decision: Decision, decidedAt: Date = .now) {
        self.localIdentifier = localIdentifier
        self.decisionRaw = decision.rawValue
        self.decidedAt = decidedAt
    }

    var decision: Decision { Decision(rawValue: decisionRaw) ?? .keep }
}

/// One confirmed `deleteAssets` from Cull's trash: how many items, and how many bytes
/// they took up (sizes PhotoKit didn't report count as zero).
@Model
final class DeletionRecord {
    var deletedAt: Date
    var count: Int
    var bytes: Int64

    init(deletedAt: Date = .now, count: Int, bytes: Int64) {
        self.deletedAt = deletedAt
        self.count = count
        self.bytes = bytes
    }
}

struct TrashEntry: Identifiable, Hashable {
    let id: String
    let trashedAt: Date
}

/// SwiftData-backed record of kept IDs (skipped next time) and Cull's trash
/// (persists across launches). Exposes in-memory caches for fast lookups.
///
/// The caches are updated in place after each successful save rather than
/// re-fetched, so a decision costs the same with 10 or 10,000 rows stored.
@Observable
final class DecisionStore {
    private let context: ModelContext

    private(set) var keptIDs: Set<String> = []
    /// Newest first.
    private(set) var trash: [TrashEntry] = []
    private(set) var trashedIDs: Set<String> = []
    /// All-time totals of what was really deleted through Cull.
    private(set) var freedBytes: Int64 = 0
    private(set) var deletedCount = 0

    init(container: ModelContainer) {
        context = ModelContext(container)
        reload()
    }

    static func makeContainer(inMemory: Bool) throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: AssetDecision.self, DeletionRecord.self, configurations: configuration)
    }

    func record(_ decision: Decision, for id: String) {
        record(decision, for: [id])
    }

    /// Records one decision for many items with a single save. `.skip` is never
    /// persisted, so it's a no-op here.
    func record(_ decision: Decision, for ids: some Sequence<String>) {
        guard decision.isPersisted else { return }
        let ids = Array(Set(ids))
        guard !ids.isEmpty else { return }
        let decidedAt = Date.now
        let existing = fetch(ids)
        for id in ids {
            if let row = existing[id] {
                row.decisionRaw = decision.rawValue
                row.decidedAt = decidedAt
            } else {
                context.insert(AssetDecision(localIdentifier: id, decision: decision, decidedAt: decidedAt))
            }
        }
        guard save() else { return }
        let idSet = Set(ids)
        forget(idSet)
        switch decision {
        case .keep:
            keptIDs.formUnion(idSet)
        case .trash:
            trash.insert(contentsOf: ids.map { TrashEntry(id: $0, trashedAt: decidedAt) }, at: 0)
            trashedIDs.formUnion(idSet)
        case .skip:
            break
        }
    }

    /// The saved decision for `id`, from the in-memory caches.
    func decision(for id: String) -> Decision? {
        if keptIDs.contains(id) { return .keep }
        if trashedIDs.contains(id) { return .trash }
        return nil
    }

    func clear(ids: some Sequence<String>) {
        let ids = Set(ids)
        guard !ids.isEmpty else { return }
        for row in fetch(ids).values { context.delete(row) }
        guard save() else { return }
        forget(ids)
    }

    /// Forgets every "kept" decision so those assets show up again. Trash is untouched.
    func resetKept() {
        let keep = Decision.keep.rawValue
        do {
            try context.delete(model: AssetDecision.self, where: #Predicate { $0.decisionRaw == keep })
        } catch {
            assertionFailure("resetKept failed: \(error)")
            reload()
            return
        }
        guard save() else { return }
        keptIDs = []
    }

    /// Adds a confirmed deletion to the all-time totals.
    func recordDeletion(count: Int, bytes: Int64) {
        guard count > 0 else { return }
        let bytes = max(bytes, 0)
        context.insert(DeletionRecord(count: count, bytes: bytes))
        guard save() else { return }
        deletedCount += count
        freedBytes += bytes
    }

    /// Existing rows for `ids`, in one fetch (single-item and bulk changes alike).
    private func fetch(_ ids: some Collection<String>) -> [String: AssetDecision] {
        guard !ids.isEmpty else { return [:] }
        let wanted = Array(ids)
        let descriptor = FetchDescriptor<AssetDecision>(predicate: #Predicate { wanted.contains($0.localIdentifier) })
        let rows = (try? context.fetch(descriptor)) ?? []
        return Dictionary(rows.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Drops `ids` from the in-memory caches.
    private func forget(_ ids: Set<String>) {
        keptIDs.subtract(ids)
        let trashed = trashedIDs.intersection(ids)
        if !trashed.isEmpty {
            trash.removeAll { trashed.contains($0.id) }
            trashedIDs.subtract(trashed)
        }
    }

    /// Saves; on failure, rolls back and resyncs the caches from the store.
    @discardableResult
    private func save() -> Bool {
        do {
            try context.save()
            return true
        } catch {
            assertionFailure("DecisionStore save failed: \(error)")
            context.rollback()
            reload()
            return false
        }
    }

    private func reload() {
        let descriptor = FetchDescriptor<AssetDecision>(sortBy: [SortDescriptor(\.decidedAt, order: .reverse)])
        let all = (try? context.fetch(descriptor)) ?? []
        keptIDs = Set(all.lazy.filter { $0.decision == .keep }.map(\.localIdentifier))
        trash = all.filter { $0.decision == .trash }.map { TrashEntry(id: $0.localIdentifier, trashedAt: $0.decidedAt) }
        trashedIDs = Set(trash.map(\.id))
        let deletions = (try? context.fetch(FetchDescriptor<DeletionRecord>())) ?? []
        deletedCount = deletions.reduce(0) { $0 + $1.count }
        freedBytes = deletions.reduce(0) { $0 + $1.bytes }
    }
}
