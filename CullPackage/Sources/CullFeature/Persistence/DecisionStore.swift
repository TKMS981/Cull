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
@Observable
final class DecisionStore {
    private let context: ModelContext

    private(set) var keptIDs: Set<String> = []
    /// Newest first.
    private(set) var trash: [TrashEntry] = []

    var trashedIDs: Set<String> { Set(trash.map(\.id)) }

    init(container: ModelContainer) {
        context = ModelContext(container)
        reload()
    }

    static func makeContainer(inMemory: Bool) throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: AssetDecision.self, configurations: configuration)
    }

    func record(_ decision: Decision, for id: String) {
        if let existing = fetch(id) {
            existing.decisionRaw = decision.rawValue
            existing.decidedAt = .now
        } else {
            context.insert(AssetDecision(localIdentifier: id, decision: decision))
        }
        save()
    }

    func clear(ids: some Sequence<String>) {
        for id in ids {
            if let existing = fetch(id) { context.delete(existing) }
        }
        save()
    }

    /// Forgets every "kept" decision so those assets show up again. Trash is untouched.
    func resetKept() {
        let keep = Decision.keep.rawValue
        do {
            try context.delete(model: AssetDecision.self, where: #Predicate { $0.decisionRaw == keep })
        } catch {
            assertionFailure("resetKept failed: \(error)")
        }
        save()
    }

    private func fetch(_ id: String) -> AssetDecision? {
        var descriptor = FetchDescriptor<AssetDecision>(predicate: #Predicate { $0.localIdentifier == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func save() {
        do {
            try context.save()
        } catch {
            assertionFailure("DecisionStore save failed: \(error)")
        }
        reload()
    }

    private func reload() {
        let descriptor = FetchDescriptor<AssetDecision>(sortBy: [SortDescriptor(\.decidedAt, order: .reverse)])
        let all = (try? context.fetch(descriptor)) ?? []
        keptIDs = Set(all.lazy.filter { $0.decision == .keep }.map(\.localIdentifier))
        trash = all.filter { $0.decision == .trash }.map { TrashEntry(id: $0.localIdentifier, trashedAt: $0.decidedAt) }
    }
}
