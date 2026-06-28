import Foundation

/// One pending voice-edit instruction, persisted so an app-kill can resume it.
/// Text-only: image edits are not crash-persisted (the photos live in R2; a
/// rare interrupted image edit is re-spoken, not silently resumed).
struct PersistedEdit: Codable, Equatable {
    let id: String
    let text: String
    /// Which article (chip) the user was viewing when they spoke — so a resumed
    /// edit still targets the right one's line numbers. Optional: pre-existing
    /// saved queues lack the key and decode to nil (→ treated as 0).
    let articleIndex: Int?
}

/// Disk mirror of the per-article edit queue (UserDefaults, keyed by stem).
/// The server is the source of truth; this only survives the gap between
/// "user spoke" and "server acked", so a kill in that window still resumes.
enum EditQueueStore {
    private static func key(_ stem: String) -> String { "editQueue.\(stem)" }

    static func load(stem: String) -> [PersistedEdit] {
        guard let data = UserDefaults.standard.data(forKey: key(stem)),
              let items = try? JSONDecoder().decode([PersistedEdit].self, from: data) else { return [] }
        return items
    }

    static func save(_ items: [PersistedEdit], stem: String) {
        if items.isEmpty { clear(stem: stem); return }
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key(stem))
        }
    }

    static func clear(stem: String) {
        UserDefaults.standard.removeObject(forKey: key(stem))
    }
}
