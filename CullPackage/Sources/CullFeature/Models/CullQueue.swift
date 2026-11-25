import Foundation

public enum Decision: String, Codable, Sendable {
    case keep
    case trash
}

/// Pure queue + undo history for a cull session. Generic so it can be unit-tested
/// without PhotoKit objects.
public struct CullQueue<Element: Identifiable> where Element.ID == String {
    public struct Entry {
        public let element: Element
        public let decision: Decision
    }

    /// Upcoming items; `pending.first` is the card on screen.
    public private(set) var pending: [Element]
    /// Decided items, most recent last. Undo pops from here.
    public private(set) var history: [Entry] = []

    public init(_ elements: [Element]) {
        pending = elements
    }

    public var current: Element? { pending.first }
    public var remaining: Int { pending.count }
    public var canUndo: Bool { !history.isEmpty }

    /// Decides the current item and advances. Returns the decided element.
    @discardableResult
    public mutating func decide(_ decision: Decision) -> Element? {
        guard !pending.isEmpty else { return nil }
        let element = pending.removeFirst()
        history.append(Entry(element: element, decision: decision))
        return element
    }

    /// Reverts the last decision and puts that item back on screen.
    @discardableResult
    public mutating func undo() -> Entry? {
        guard let entry = history.popLast() else { return nil }
        pending.insert(entry.element, at: 0)
        return entry
    }

    /// Drops items that no longer exist (deleted outside the app or in Cull's trash).
    public mutating func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        pending.removeAll { ids.contains($0.id) }
        history.removeAll { ids.contains($0.element.id) }
    }

    /// Re-queues an item (e.g. restored from Cull's trash). Its old history entry is
    /// dropped so a later undo can't re-apply a decision the user already reversed.
    public mutating func requeue(_ element: Element) {
        history.removeAll { $0.element.id == element.id }
        guard !pending.contains(where: { $0.id == element.id }) else { return }
        pending.append(element)
    }

    public mutating func append(_ elements: [Element]) {
        let existing = Set(pending.map(\.id)).union(history.map(\.element.id))
        pending.append(contentsOf: elements.filter { !existing.contains($0.id) })
    }

    /// Swaps in refreshed copies (PHAsset objects are immutable snapshots).
    public mutating func replace(_ elements: [Element]) {
        let byID = Dictionary(elements.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        guard !byID.isEmpty else { return }
        for index in pending.indices {
            if let updated = byID[pending[index].id] { pending[index] = updated }
        }
        for index in history.indices {
            if let updated = byID[history[index].element.id] {
                history[index] = Entry(element: updated, decision: history[index].decision)
            }
        }
    }
}
