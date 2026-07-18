import Foundation

/// Talks to the Django + Gemini brain.
enum PenpalAPI {
    struct ChatRequest: Encodable {
        let message: String
        let conversation_id: String
        let history: [Turn]
        // Capability routing (see chat/prompts.py in the brain).
        let capability: String
        let mood: String
        let custom_mood: String
        let math_detail: String

        struct Turn: Encodable {
            let role: String
            let content: String
        }
    }

    struct ChatResponse: Decodable {
        let reply: String
        let conversation_id: String?
        let model: String?
        let error: String?
        let capability: String?
    }

    enum APIError: LocalizedError {
        case badURL
        case http(Int, String)
        case emptyReply
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid API base URL."
            case .http(let code, let body): return "Server error (\(code)): \(body)"
            case .emptyReply: return "Penpal returned an empty reply."
            case .transport(let err): return err.localizedDescription
            }
        }
    }

    static func chat(
        message: String,
        conversationId: String,
        history: [ChatRequest.Turn],
        baseURL: String,
        capability: String = "companion",
        mood: String = "warm",
        customMood: String = "",
        mathDetail: String = "compact"
    ) async throws -> String {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/api/chat/") else {
            throw APIError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(conversationId, forHTTPHeaderField: "X-Conversation-Id")
        request.timeoutInterval = 45

        let body = ChatRequest(
            message: message,
            conversation_id: conversationId,
            history: history,
            capability: capability,
            mood: mood,
            custom_mood: customMood,
            math_detail: mathDetail
        )
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200...299).contains(code) {
            let text = String(data: data, encoding: .utf8) ?? ""
            // Prefer JSON error field when present.
            if let parsed = try? JSONDecoder().decode(ChatResponse.self, from: data),
               let err = parsed.error, !err.isEmpty {
                throw APIError.http(code, err)
            }
            throw APIError.http(code, text.isEmpty ? "no body" : text)
        }

        let parsed = try JSONDecoder().decode(ChatResponse.self, from: data)
        let reply = parsed.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { throw APIError.emptyReply }
        return reply
    }

    static func health(baseURL: String) async -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/api/health/") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return false
            }
            return (String(data: data, encoding: .utf8) ?? "").contains("ok")
        } catch {
            return false
        }
    }
}
