import Foundation
import Observation
import SwiftData

/// One persisted keep/trash decision per asset.
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

    init(container: ModelContainer) {
        context = ModelContext(container)
        reload()
    }

    static func makeContainer(inMemory: Bool) throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: AssetDecision.self, configurations: configuration)
    }

    func record(_ decision: Decision, for id: String) {
        let decidedAt = Date.now
        if let existing = fetch(id) {
            existing.decisionRaw = decision.rawValue
            existing.decidedAt = decidedAt
        } else {
            context.insert(AssetDecision(localIdentifier: id, decision: decision, decidedAt: decidedAt))
        }
        guard save() else { return }
        forget([id])
        switch decision {
        case .keep:
            keptIDs.insert(id)
        case .trash:
            trash.insert(TrashEntry(id: id, trashedAt: decidedAt), at: 0)
            trashedIDs.insert(id)
        }
    }

    func clear(ids: some Sequence<String>) {
        let ids = Set(ids)
        guard !ids.isEmpty else { return }
        for id in ids {
            if let existing = fetch(id) { context.delete(existing) }
        }
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

    private func fetch(_ id: String) -> AssetDecision? {
        var descriptor = FetchDescriptor<AssetDecision>(predicate: #Predicate { $0.localIdentifier == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
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
    }
}
