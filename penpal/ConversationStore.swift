import Foundation

/// Local conversation memory sent with each Gemini request.
///
/// PEN-30 — storage moved off `UserDefaults` (BB-11).
///
/// `UserDefaults` is a property list for small preferences: it is read into
/// memory in full at launch and rewritten in full on every change. That was
/// fine when a turn was a one-line note, but the Mathematician now returns up
/// to 8000 tokens of worked solution, and 24 of those is a few hundred
/// kilobytes of JSON being re-serialised every time the user asks anything.
///
/// It also silently competed with every other preference in the same store —
/// a corrupt write would have taken the user's settings with it.
///
/// This version keeps the same API and writes a single JSON file in
/// Application Support, off the main thread, debounced. The turn cap stays
/// (prompts must remain short for a handwriting medium), but the cap is now a
/// product decision rather than the thing holding storage together.
@MainActor
final class ConversationStore {
    static let shared = ConversationStore()

    struct Turn: Codable, Identifiable {
        let id: UUID
        let role: String   // "user" | "assistant"
        let content: String
        let createdAt: Date

        init(role: String, content: String) {
            self.id = UUID()
            self.role = role
            self.content = content
            self.createdAt = Date()
        }
    }

    private(set) var conversationId: String
    private(set) var turns: [Turn] = []
    /// Cap history so prompts stay short (handwriting medium + latency).
    private let maxTurns = 24

    private let idKey = "penpal.conversation.id"
    /// Legacy location — read once, then migrated and cleared.
    private let legacyTurnsKey = "penpal.conversation.turns"

    private struct Persisted: Codable {
        var version: Int = 1
        var turns: [Turn]
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        // Application Support isn't guaranteed to exist on a fresh install.
        try? FileManager.default.createDirectory(at: base,
                                                 withIntermediateDirectories: true)
        return base.appendingPathComponent("penpal_conversation.json")
    }

    private init() {
        if let existing = UserDefaults.standard.string(forKey: idKey), !existing.isEmpty {
            conversationId = existing
        } else {
            conversationId = UUID().uuidString
            UserDefaults.standard.set(conversationId, forKey: idKey)
        }
        load()
    }

    /// History for the API — excludes the message about to be sent.
    func historyForAPI() -> [PenpalAPI.ChatRequest.Turn] {
        turns.suffix(maxTurns).map {
            PenpalAPI.ChatRequest.Turn(role: $0.role, content: $0.content)
        }
    }

    func append(role: String, content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        turns.append(Turn(role: role, content: trimmed))
        if turns.count > maxTurns {
            turns = Array(turns.suffix(maxTurns))
        }
        persist()
    }

    func reset() {
        turns = []
        conversationId = UUID().uuidString
        UserDefaults.standard.set(conversationId, forKey: idKey)
        persist()
    }

    // MARK: - Persistence

    private let saver = DebouncedSaver()

    private func persist() {
        let snapshot = Persisted(turns: turns)
        let url = Self.fileURL
        saver.schedule {
            DebouncedSaver.write(snapshot, to: url, label: "ConversationStore")
        }
    }

    private func load() {
        // 1. Current format.
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            turns = Array(decoded.turns.suffix(maxTurns))
            return
        }
        // 2. One-time migration from UserDefaults, then reclaim the space.
        //    A failed migration costs conversation history, never settings —
        //    the old key is only cleared once the new file has been written.
        if let legacy = UserDefaults.standard.data(forKey: legacyTurnsKey),
           let decoded = try? JSONDecoder().decode([Turn].self, from: legacy) {
            turns = Array(decoded.suffix(maxTurns))
            // Written synchronously and checked, rather than via the debounced
            // saver: the old copy must not be dropped until the new one is
            // definitely on disk, or a crash mid-migration loses the history.
            do {
                let encoded = try JSONEncoder().encode(Persisted(turns: turns))
                try encoded.write(to: Self.fileURL, options: .atomic)
                UserDefaults.standard.removeObject(forKey: legacyTurnsKey)
            } catch {
                // Keep the legacy copy and try again next launch.
                print("ConversationStore migration deferred: \(error)")
            }
        }
    }
}
