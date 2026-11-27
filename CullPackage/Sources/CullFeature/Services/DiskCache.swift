import Foundation
import Synchronization

/// A small per-asset cache kept in the Caches directory, so work done once (file
/// sizes, similar-photo analysis) isn't redone on every scan or launch.
///
/// - Entries are keyed by `localIdentifier` and stamped with the asset's
///   modification date: an edited asset misses and is measured again, everything
///   else is reused (differential update).
/// - Loaded lazily on first use; written only when something changed, after a batch.
/// - Written with file protection and kept out of backups (Caches isn't backed up).
///   It holds identifiers and derived numbers only, never image data, paths or places.
nonisolated final class DiskCache<Value: Codable & Sendable>: Sendable {
    struct Entry: Codable, Sendable {
        var modified: Date?
        var value: Value
    }

    private struct State {
        var entries: [String: Entry]?
        var isDirty = false
    }

    let url: URL
    /// Most entries kept; beyond this, entries not seen in the latest full pass go first.
    let capacity: Int
    private let state = Mutex(State())

    init(fileName: String, capacity: Int, directory: URL = .cachesDirectory) {
        url = directory.appending(path: fileName)
        self.capacity = capacity
    }

    /// The cached value, if the asset hasn't been modified since.
    func value(for id: String, modified: Date?) -> Value? {
        state.withLock { state in
            loadIfNeeded(&state)
            guard let entry = state.entries?[id], entry.modified == modified else { return nil }
            return entry.value
        }
    }

    func store(_ value: Value, for id: String, modified: Date?) {
        state.withLock { state in
            loadIfNeeded(&state)
            state.entries?[id] = Entry(modified: modified, value: value)
            state.isDirty = true
        }
    }

    /// Drops entries for assets that no longer exist (after a full pass over them).
    func retain(only ids: Set<String>) {
        state.withLock { state in
            loadIfNeeded(&state)
            guard let entries = state.entries else { return }
            let kept = entries.filter { ids.contains($0.key) }
            if kept.count != entries.count {
                state.entries = kept
                state.isDirty = true
            }
        }
    }

    var count: Int { state.withLock { $0.entries?.count ?? 0 } }

    /// Writes pending changes (call after a batch, not per item).
    func persist() {
        let snapshot = state.withLock { state -> [String: Entry]? in
            guard state.isDirty, var entries = state.entries else { return nil }
            if entries.count > capacity {
                // Over capacity: keep an arbitrary but stable subset (sorted keys).
                let keep = Set(entries.keys.sorted().suffix(capacity))
                entries = entries.filter { keep.contains($0.key) }
                state.entries = entries
            }
            state.isDirty = false
            return entries
        }
        guard let snapshot else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Forgets everything, in memory and on disk.
    func removeAll() {
        state.withLock { $0 = State(entries: [:], isDirty: false) }
        try? FileManager.default.removeItem(at: url)
    }

    private func loadIfNeeded(_ state: inout State) {
        guard state.entries == nil else { return }
        guard let data = try? Data(contentsOf: url),
              let entries = try? PropertyListDecoder().decode([String: Entry].self, from: data)
        else {
            state.entries = [:]
            return
        }
        state.entries = entries
    }
}
