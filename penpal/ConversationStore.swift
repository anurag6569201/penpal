import Foundation

/// Local conversation memory sent with each Gemini request.
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
    private let turnsKey = "penpal.conversation.turns"

    private init() {
        if let existing = UserDefaults.standard.string(forKey: idKey), !existing.isEmpty {
            conversationId = existing
        } else {
            conversationId = UUID().uuidString
            UserDefaults.standard.set(conversationId, forKey: idKey)
        }
        if let data = UserDefaults.standard.data(forKey: turnsKey),
           let decoded = try? JSONDecoder().decode([Turn].self, from: data) {
            turns = decoded
        }
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

    private func persist() {
        if let data = try? JSONEncoder().encode(turns) {
            UserDefaults.standard.set(data, forKey: turnsKey)
        }
    }
}
