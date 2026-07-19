import Foundation
// CGRect/CGFloat for WorksheetProblem.Box (PEN-15). Foundation does not
// re-export CoreGraphics under explicit modules, so this must be named.
import CoreGraphics

/// Talks to the Django + Gemini brain.
enum PenpalAPI {

    /// PEN-26 — access token for the brain. Empty in local dev (the server
    /// runs open with PENPAL_DEV=1); required once the server is deployed.
    /// Stored in the keychain-backed defaults rather than compiled in, so it
    /// can be rotated without shipping a build.
    static var accessToken: String {
        get { UserDefaults.standard.string(forKey: "penpal.accessToken") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "penpal.accessToken") }
    }

    /// Applies auth headers to every outgoing request.
    private static func authorize(_ request: inout URLRequest) {
        let token = accessToken.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
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
        authorize(&request)
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

    /// Boxed problems: send the ink image straight to the Mathematician —
    /// no OCR, no transcription. The model reads the notation as drawn.
    static func solveMathImage(
        pngData: Data,
        history: [ChatRequest.Turn],
        baseURL: String,
        mathDetail: String = "compact"
    ) async throws -> String {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/api/solve-math/") else {
            throw APIError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        // Full-page problems run solve + verify (+ maybe a correction pass).
        request.timeoutInterval = 120

        struct SolveMathRequest: Encodable {
            let image: String
            let history: [ChatRequest.Turn]
            let math_detail: String
        }
        let body = SolveMathRequest(
            image: pngData.base64EncodedString(),
            history: history,
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

    // MARK: - Worksheet mode (PEN-15)

    /// One problem found on a worksheet, with where it sits on the page.
    struct WorksheetProblem: Decodable {
        let label: String
        let reading: String
        let steps: [String]
        let answer: String
        let readable: Bool
        /// Position within the sent image, as fractions (0–1) from top-left.
        /// `nil` when the model wasn't confident — the caller then flows the
        /// answer down the page instead of risking the wrong question.
        let box: Box?

        struct Box: Decodable {
            let x: CGFloat
            let y: CGFloat
            let width: CGFloat
            let height: CGFloat

            /// Maps this normalised box back into the page rect the image
            /// was rendered from.
            func rect(in region: CGRect) -> CGRect {
                CGRect(x: region.minX + x * region.width,
                       y: region.minY + y * region.height,
                       width: width * region.width,
                       height: height * region.height)
            }
        }
    }

    private struct WorksheetResponse: Decodable {
        let problems: [WorksheetProblem]?
        let count: Int?
        let error: String?
    }

    /// Solve every problem on a page in one pass.
    static func solveWorksheet(
        pngData: Data,
        baseURL: String,
        mathDetail: String = "compact"
    ) async throws -> [WorksheetProblem] {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/api/worksheet/") else {
            throw APIError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        // A full page of problems is the slowest call the app makes.
        request.timeoutInterval = 180

        struct Body: Encodable {
            let image: String
            let math_detail: String
        }
        request.httpBody = try JSONEncoder().encode(
            Body(image: pngData.base64EncodedString(), math_detail: mathDetail))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let parsed = try? JSONDecoder().decode(WorksheetResponse.self, from: data)
        if !(200...299).contains(code) {
            if let err = parsed?.error, !err.isEmpty {
                throw APIError.http(code, err)
            }
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "no body")
        }
        guard let problems = parsed?.problems, !problems.isEmpty else {
            throw APIError.emptyReply
        }
        return problems
    }

    // MARK: - Show-your-work grading (PEN-16)

    /// The result of marking a student's own working.
    struct WorkMarking: Decodable {
        let problem: String
        /// "correct" | "error" | "unreadable"
        let verdict: String
        let line_number: Int?
        let line_text: String
        let box: WorksheetProblem.Box?
        let reason: String
        let correction: String
        let final_answer: String

        var foundError: Bool { verdict == "error" && !reason.isEmpty }

        /// What Penpal writes on the page. Speaks to the student, and never
        /// leads with a verdict on them — it points at a line.
        var note: String {
            switch verdict {
            case "error":
                return correction.isEmpty ? reason : "\(reason)\n\(correction)"
            case "correct":
                return final_answer.isEmpty
                    ? "This all checks out."
                    : "All correct — \(final_answer)"
            default:
                return "I couldn't read this working clearly."
            }
        }
    }

    static func checkWork(pngData: Data, baseURL: String) async throws -> WorkMarking {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/api/check-work/") else {
            throw APIError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.timeoutInterval = 120

        struct Body: Encodable { let image: String }
        request.httpBody = try JSONEncoder().encode(
            Body(image: pngData.base64EncodedString()))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200...299).contains(code) {
            if let parsed = try? JSONDecoder().decode(ChatResponse.self, from: data),
               let err = parsed.error, !err.isEmpty {
                throw APIError.http(code, err)
            }
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "no body")
        }
        return try JSONDecoder().decode(WorkMarking.self, from: data)
    }

    // MARK: - Streaming (PEN-28)

    /// One event from the streamed solve.
    enum SolveEvent {
        /// Provisional — show it, don't ink it.
        case draft(String)
        /// Checked and approved: safe to write.
        case final(String)
        /// The referee rejected the draft; this replaces it entirely.
        case corrected(String)
        case failed(String)
    }

    /// Streams a solution as server-sent events.
    ///
    /// The caller must treat `.draft` as provisional. Ink cannot be unwritten,
    /// so committing a draft that the referee later rejects would leave a
    /// wrong answer on the page — the whole reason the stream is separated
    /// into draft and confirmed phases.
    static func streamSolve(
        message: String,
        history: [ChatRequest.Turn],
        baseURL: String,
        mathDetail: String = "compact"
    ) -> AsyncThrowingStream<SolveEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let trimmed = baseURL.trimmingCharacters(
                    in: CharacterSet(charactersIn: "/"))
                guard let url = URL(string: trimmed + "/api/solve-stream/") else {
                    continuation.finish(throwing: APIError.badURL)
                    return
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json",
                                 forHTTPHeaderField: "Content-Type")
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                authorize(&request)
                request.timeoutInterval = 120

                struct Body: Encodable {
                    let message: String
                    let history: [ChatRequest.Turn]
                    let math_detail: String
                }
                do {
                    request.httpBody = try JSONEncoder().encode(
                        Body(message: message, history: history,
                             math_detail: mathDetail))

                    let (bytes, response) = try await URLSession.shared.bytes(
                        for: request)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200...299).contains(code) else {
                        continuation.finish(
                            throwing: APIError.http(code, "stream refused"))
                        return
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard let data = payload.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(
                                with: data) as? [String: Any],
                              let type = object["type"] as? String
                        else { continue }
                        let text = (object["text"] as? String) ?? ""
                        switch type {
                        case "draft":     continuation.yield(.draft(text))
                        case "final":     continuation.yield(.final(text))
                        case "corrected": continuation.yield(.corrected(text))
                        default:
                            continuation.yield(.failed(
                                (object["message"] as? String) ?? "Something went wrong."))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: APIError.transport(error))
                }
            }
        }
    }

    // MARK: - Practice (PEN-19)

    struct PracticeProblem: Decodable {
        let problem: String
        let answer: String
        let hint: String
        let skill: String
    }

    static func practice(topic: String, mistake: String, difficulty: String,
                         baseURL: String) async throws -> PracticeProblem {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/api/practice/") else {
            throw APIError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.timeoutInterval = 60

        struct Body: Encodable {
            let topic: String
            let mistake: String
            let difficulty: String
        }
        request.httpBody = try JSONEncoder().encode(
            Body(topic: topic, mistake: mistake, difficulty: difficulty))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.transport(error)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "no body")
        }
        return try JSONDecoder().decode(PracticeProblem.self, from: data)
    }

    // MARK: - Verification health (PEN-04)

    /// What the brain reports about its own correctness checking.
    struct VerificationHealth: Decodable {
        let status: String          // idle | healthy | degraded | unverified
        let verification_coverage: Double
        let solves: Int
        let verified: Int
        let failed_open: Int
        let caught_errors: Int
        let corrections_applied: Int
        let cas_hits: Int

        /// Honest one-liner for Settings. We say it plainly when answers are
        /// going out unchecked — a silent safety net is not a safety net.
        var summary: String {
            switch status {
            case "healthy":
                return caught_errors > 0
                    ? "Checking every answer — caught \(caught_errors) error\(caught_errors == 1 ? "" : "s") so far."
                    : "Checking every answer."
            case "degraded":
                return "Some answers went out unchecked (\(failed_open) of \(verified + failed_open))."
            case "unverified":
                return "Answers are NOT being checked right now."
            default:
                return "No problems solved yet."
            }
        }

        var isHealthy: Bool { status == "healthy" || status == "idle" }
    }

    private struct HealthResponse: Decodable {
        let ok: Bool
        let verification: VerificationHealth?
    }

    static func verificationHealth(baseURL: String) async -> VerificationHealth? {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/api/health/") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let parsed = try? JSONDecoder().decode(HealthResponse.self, from: data)
        else { return nil }
        return parsed.verification
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
