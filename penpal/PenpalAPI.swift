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

    struct InteractiveBlockResponse: Decodable {
        let reply: String
        let title: String
        let html: String
        let preferred_height: Int
        let manifest: InteractiveManifest?
        let build_mode: String?
        let iterations: Int?
        // True when the model ran out of output room and the server closed up
        // a partial build rather than failing: the block runs, but it may be
        // missing later features, so offering a rebuild is reasonable.
        let salvaged: Bool?
        let diagnosis: String?
        let conversation_id: String?
        let model: String?
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

    static func shouldGenerateInteractive(message: String, capability: String) -> Bool {
        if capability == "interactive" { return true }
        let text = message
            .folding(options: [.caseInsensitive, .diacriticInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let explicitIntents = [
            "interactive", "simulate", "simulation", "animate", "animation",
            "visualization", "visualisation", "explorable", "playground",
            "build a quiz", "make a quiz", "create a quiz",
            "build a tool", "make a tool", "create a tool",
        ]
        return explicitIntents.contains { text.contains($0) }
    }

    static func interactive(
        message: String,
        conversationId: String,
        history: [ChatRequest.Turn],
        baseURL: String,
        capability: String,
        language: String,
        mathDetail: String
    ) async throws -> InteractiveBlockResponse {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/api/interactive/") else {
            throw APIError.badURL
        }

        struct Body: Encodable {
            let message: String
            let conversation_id: String
            let history: [ChatRequest.Turn]
            let capability: String
            let language: String
            let math_detail: String
        }
        struct ErrorBody: Decodable { let error: String? }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.setValue(conversationId, forHTTPHeaderField: "X-Conversation-Id")
        // Complex blocks may use a bounded build → review → repair loop.
        request.timeoutInterval = 180
        request.httpBody = try JSONEncoder().encode(Body(
            message: message,
            conversation_id: conversationId,
            history: history,
            capability: capability,
            language: language,
            math_detail: mathDetail
        ))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200...299).contains(code) {
            let parsed = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw APIError.http(
                code,
                parsed?.error ?? String(data: data, encoding: .utf8) ?? "no body"
            )
        }

        let parsed = try JSONDecoder().decode(InteractiveBlockResponse.self, from: data)
        guard !parsed.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.emptyReply
        }
        return parsed
    }

    /// PEN-40 — plan a whole page and build every section at once.
    ///
    /// Returns content and layout INTENT (roles, spans, anchors) but no
    /// geometry: only this device knows the page width and the user's
    /// handwriting size, so `PageComposer` solves the placement locally.
    static func arrange(
        message: String,
        conversationId: String,
        history: [ChatRequest.Turn],
        baseURL: String,
        language: String,
        mathDetail: String,
        illustrationQuality: String,
        pageWidth: CGFloat
    ) async throws -> ArrangedPageResponse {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/api/arrange/") else {
            throw APIError.badURL
        }

        struct Body: Encodable {
            let message: String
            let conversation_id: String
            let history: [ChatRequest.Turn]
            let language: String
            let math_detail: String
            let illustration_quality: String
            /// Writable width of the page, so the server can tell each
            /// specialist the size of the box it is building for.
            let page_width: Double
        }
        struct ErrorBody: Decodable { let error: String? }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.setValue(conversationId, forHTTPHeaderField: "X-Conversation-Id")
        // A page fans out to several specialists at once, so the wall-clock
        // cost is the slowest section — usually an interactive build — not
        // the sum. The ceiling still has to cover that slowest one.
        request.timeoutInterval = 240
        request.httpBody = try JSONEncoder().encode(Body(
            message: message,
            conversation_id: conversationId,
            history: history,
            language: language,
            math_detail: mathDetail,
            illustration_quality: illustrationQuality,
            page_width: Double(pageWidth)
        ))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200...299).contains(code) {
            let parsed = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw APIError.http(
                code,
                parsed?.error ?? String(data: data, encoding: .utf8) ?? "no body"
            )
        }

        let parsed = try JSONDecoder().decode(ArrangedPageResponse.self, from: data)
        guard !parsed.sections.isEmpty else { throw APIError.emptyReply }
        return parsed
    }

    static func repairInteractive(
        block: CodeBlock,
        diagnostics: [InteractiveRuntimeDiagnostic],
        baseURL: String
    ) async throws -> InteractiveBlockResponse {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/api/interactive/repair/") else {
            throw APIError.badURL
        }
        struct Body: Encodable {
            let title: String
            let html: String
            let manifest: InteractiveManifest
            let diagnostics: [InteractiveRuntimeDiagnostic]
        }
        struct ErrorBody: Decodable { let error: String? }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.timeoutInterval = 180
        request.httpBody = try JSONEncoder().encode(Body(
            title: block.runtime?.title ?? "Interactive Block",
            html: block.html,
            manifest: block.runtime?.manifest ?? .empty,
            diagnostics: Array(diagnostics.prefix(6))
        ))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.transport(error)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            let parsed = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw APIError.http(
                code,
                parsed?.error ?? String(data: data, encoding: .utf8) ?? "no body"
            )
        }
        let parsed = try JSONDecoder().decode(InteractiveBlockResponse.self, from: data)
        guard !parsed.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.emptyReply
        }
        return parsed
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

    // MARK: - Photo import (PEN-35)

    /// One piece of a photographed page. "text"/"math" carry transcribed
    /// content to be written as real ink; "image" carries a crop box for
    /// content that can't honestly become handwriting (a diagram, a table,
    /// a photo) — the app crops the ORIGINAL photo itself rather than
    /// trusting a server-side re-render, so what lands on the page is the
    /// real pixels the user photographed.
    struct ImportedBlock: Decodable {
        let type: String
        let content: String?
        let label: String?
        let box: WorksheetProblem.Box?

        var isText: Bool { type == "text" || type == "math" }
        var isImage: Bool { type == "image" }
    }

    private struct ImportPageResponse: Decodable {
        let blocks: [ImportedBlock]?
        let count: Int?
        let error: String?
    }

    /// Read an existing paper page and return it as ordered blocks.
    static func importPage(
        pngData: Data,
        baseURL: String
    ) async throws -> [ImportedBlock] {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/api/import-page/") else {
            throw APIError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        // A full page read is comparable in cost to worksheet solving.
        request.timeoutInterval = 180

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
        let parsed = try? JSONDecoder().decode(ImportPageResponse.self, from: data)
        if !(200...299).contains(code) {
            if let err = parsed?.error, !err.isEmpty {
                throw APIError.http(code, err)
            }
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "no body")
        }
        guard let blocks = parsed?.blocks, !blocks.isEmpty else {
            throw APIError.emptyReply
        }
        return blocks
    }

    // MARK: - Arranger (PEN-40)

    /// One generated section of a composed page. Carries content plus the
    /// layout INTENT the compositor needs — never geometry, which the device
    /// works out for itself.
    struct ArrangedPageSection: Decodable {
        let id: String
        let role: String
        let capability: String
        let block: String
        let span: String
        let priority: Int
        let anchor: String?
        let adjacency: String?

        /// Handwritten prose, maths, a table body or a checklist body.
        let text: String?
        /// Interactive block source.
        let html: String?
        let title: String?
        let caption: String?
        let preferred_height: Int?
        let manifest: InteractiveManifest?
        /// Illustrator output, in the same shape the illustrator endpoint uses.
        let strokes: [Illustration.Stroke]?
        let label: String?
        let aspect_ratio: Double?
        /// The region the server told this specialist to design for. Used to
        /// sanity-check a block that reports an implausible height.
        let box_width: Int?
        let box_height: Int?

        var resolvedBlock: SectionBlock {
            SectionBlock(rawValue: block) ?? .ink
        }
        var resolvedRole: SectionRole {
            SectionRole(rawValue: role) ?? .explanation
        }
        var resolvedSpan: SectionSpan {
            SectionSpan(rawValue: span) ?? .full
        }
        var resolvedAdjacency: SectionAdjacency? {
            guard let adjacency, !adjacency.isEmpty else { return nil }
            return SectionAdjacency(rawValue: adjacency)
        }
        /// Empty strings arrive from the server for "no anchor"; normalise
        /// them away so the compositor only ever sees a real id or nil.
        var resolvedAnchor: String? {
            guard let anchor, !anchor.isEmpty else { return nil }
            return anchor
        }

        /// Hand this section to the layout solver.
        func asArrangedSection() -> ArrangedSection {
            ArrangedSection(
                id: id,
                role: resolvedRole,
                block: resolvedBlock,
                span: resolvedSpan,
                priority: priority,
                anchor: resolvedAnchor,
                adjacency: resolvedAdjacency,
                text: text ?? "",
                html: html ?? "",
                preferredHeight: CGFloat(preferred_height ?? 0),
                aspectRatio: CGFloat(aspect_ratio ?? 1)
            )
        }
    }

    struct ArrangedPageResponse: Decodable {
        let title: String
        /// Layout family: modular-grid, cornell, two-column, path, radial,
        /// skyscraper.
        let template: String
        let reply: String
        let sections: [ArrangedPageSection]
        /// How many sections were planned vs how many survived, so the page
        /// can tell the user something quietly went missing.
        let planned: Int?
        let failed: Int?
        let conversation_id: String?
        let model: String?
        let capability: String?

        var resolvedTemplate: PageTemplate {
            PageTemplate(rawValue: template) ?? .modularGrid
        }
    }

    // MARK: - Illustrator (PEN-36)

    struct Illustration: Decodable {
        struct Stroke: Decodable {
            let role: String
            /// Normalised [x, y] pairs, top-left origin.
            let points: [[Double]]
        }

        /// "strokes" or "refusal".
        let kind: String
        let label: String?
        let message: String?
        let strokes: [Stroke]?
        let error: String?
        let quality: String?
        let pipeline: String?
        let aspect_ratio: Double?

        var isRefusal: Bool { kind == "refusal" }
    }

    /// Plan a line drawing (imaginative or educational/labelled). Unsafe
    /// requests return a structured refusal.
    static func illustrate(
        message: String,
        quality: String = "detailed",
        baseURL: String
    ) async throws -> Illustration {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/api/illustrate/") else {
            throw APIError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.timeoutInterval = quality == "detailed" ? 240 : 120

        struct Body: Encodable { let message: String; let quality: String }
        request.httpBody = try JSONEncoder().encode(
            Body(message: message, quality: quality)
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let parsed = try? JSONDecoder().decode(Illustration.self, from: data)
        if !(200...299).contains(code) {
            if let err = parsed?.error, !err.isEmpty {
                throw APIError.http(code, err)
            }
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "no body")
        }
        guard let illustration = parsed else { throw APIError.emptyReply }
        if illustration.isRefusal {
            guard illustration.message?.isEmpty == false else { throw APIError.emptyReply }
            return illustration
        }
        guard illustration.kind == "strokes",
              illustration.strokes?.isEmpty == false else {
            throw APIError.emptyReply
        }
        return illustration
    }

    /// Trace a user-provided image into ordered pen strokes (PEN-36, Goal B).
    /// The server runs pure computer vision — no model call — so the photo is
    /// never sent to Gemini. Reuses the `Illustration` contract, so the drawing
    /// path reveals a traced image exactly like a generated sketch. Returns a
    /// refusal when nothing traceable is found.
    static func traceImage(
        imageData: Data,
        label: String,
        quality: String = "detailed",
        baseURL: String
    ) async throws -> Illustration {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/api/trace-image/") else {
            throw APIError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.timeoutInterval = quality == "detailed" ? 120 : 60

        struct Body: Encodable {
            let image: String
            let label: String
            let quality: String
        }
        request.httpBody = try JSONEncoder().encode(
            Body(
                image: imageData.base64EncodedString(),
                label: label,
                quality: quality
            )
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let parsed = try? JSONDecoder().decode(Illustration.self, from: data)
        if !(200...299).contains(code) {
            if let err = parsed?.error, !err.isEmpty {
                throw APIError.http(code, err)
            }
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "no body")
        }
        guard let illustration = parsed else { throw APIError.emptyReply }
        if illustration.isRefusal {
            guard illustration.message?.isEmpty == false else { throw APIError.emptyReply }
            return illustration
        }
        guard illustration.kind == "strokes",
              illustration.strokes?.isEmpty == false else {
            throw APIError.emptyReply
        }
        return illustration
    }

    // MARK: - Language Partner (PEN-37)

    struct LanguageTurn: Decodable {
        struct Correction: Decodable {
            let found_error: Bool
            let reason: String
            let corrected: String
            let skill: String
            let confidence: Double

            var note: String {
                guard found_error else { return "" }
                return reason.isEmpty ? corrected : "\(reason)\nTry: \(corrected)"
            }
        }

        let reply: String
        let language: String
        let correction: Correction
        let error: String?
    }

    static func languageTurn(
        message: String,
        language: String,
        history: [ChatRequest.Turn],
        baseURL: String
    ) async throws -> LanguageTurn {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/api/language-turn/") else {
            throw APIError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.timeoutInterval = 90

        struct Body: Encodable {
            let message: String
            let language: String
            let history: [ChatRequest.Turn]
        }
        request.httpBody = try JSONEncoder().encode(
            Body(message: message, language: language, history: history)
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200...299).contains(code) {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = object["error"] as? String, !error.isEmpty {
                throw APIError.http(code, error)
            }
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "no body")
        }
        let turn = try JSONDecoder().decode(LanguageTurn.self, from: data)
        guard !turn.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.emptyReply
        }
        return turn
    }

    // MARK: - Debate Partner (PEN-38)

    struct DebateTurn: Decodable {
        let counterargument: String
        let question: String
        let trust: String
        let error: String?

        /// The label is part of the honesty boundary: this is another
        /// perspective, not a verified verdict on the writer.
        var inkText: String {
            let body = "Another view:\n\(counterargument)"
            return question.isEmpty ? body : "\(body)\n\(question)"
        }
    }

    static func debateTurn(
        message: String,
        history: [ChatRequest.Turn],
        baseURL: String
    ) async throws -> DebateTurn {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/api/debate-turn/") else {
            throw APIError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.timeoutInterval = 90

        struct Body: Encodable {
            let message: String
            let history: [ChatRequest.Turn]
        }
        request.httpBody = try JSONEncoder().encode(
            Body(message: message, history: history)
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200...299).contains(code) {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = object["error"] as? String, !error.isEmpty {
                throw APIError.http(code, error)
            }
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "no body")
        }
        let turn = try JSONDecoder().decode(DebateTurn.self, from: data)
        guard !turn.counterargument
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.emptyReply
        }
        return turn
    }

    // MARK: - Vision input (PEN-39)

    struct VisionTurn: Decodable {
        let kind: String
        let reply: String?
        let language: String?
        let correction: LanguageTurn.Correction?
        let counterargument: String?
        let question: String?
        let trust: String?
        let error: String?

        var inkText: String {
            switch kind {
            case "debate":
                let body = "Another view:\n\(counterargument ?? "")"
                guard let question, !question.isEmpty else { return body }
                return "\(body)\n\(question)"
            case "language":
                guard let correction, correction.found_error else {
                    return reply ?? ""
                }
                return "\(correction.note)\n\(reply ?? "")"
            default:
                return reply ?? ""
            }
        }
    }

    static func visionTurn(
        jpegData: Data,
        message: String = "",
        capability: String,
        language: String,
        mathDetail: String,
        history: [ChatRequest.Turn],
        baseURL: String
    ) async throws -> VisionTurn {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/api/vision-turn/") else {
            throw APIError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.timeoutInterval = 180

        struct Body: Encodable {
            let image: String
            let mime_type: String
            let message: String
            let capability: String
            let language: String
            let math_detail: String
            let history: [ChatRequest.Turn]
        }
        request.httpBody = try JSONEncoder().encode(Body(
            image: jpegData.base64EncodedString(),
            mime_type: "image/jpeg",
            message: message,
            capability: capability,
            language: language,
            math_detail: mathDetail,
            history: history
        ))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200...299).contains(code) {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = object["error"] as? String, !error.isEmpty {
                throw APIError.http(code, error)
            }
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "no body")
        }
        let turn = try JSONDecoder().decode(VisionTurn.self, from: data)
        guard !turn.inkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.emptyReply
        }
        return turn
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
                         domain: String = "math",
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
            let domain: String
        }
        request.httpBody = try JSONEncoder().encode(
            Body(topic: topic, mistake: mistake, difficulty: difficulty,
                 domain: domain))

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
