//
//  Outbox.swift
//  penpal
//
//  PEN-12 — offline queue and graceful retry.
//
//  Handwriting is slow and deliberate. A typed message lost to a dropped
//  connection costs a few seconds to retype; a page of worked-out algebra
//  lost the same way costs minutes and a lot of goodwill. That asymmetry is
//  the whole justification for this file.
//
//  Design:
//    * Only genuinely OFFLINE failures are queued. A 500 or a bad token will
//      fail identically on retry, so queueing them just delays honest news.
//    * Retries back off exponentially and give up after a bounded number of
//      attempts. An item that can never succeed must not retry forever.
//    * The queue survives relaunch, because "I'll answer as soon as we're
//      back" has to remain true if the app is closed in between.
//    * Sends are serialised. Two replies arriving at once would fight over
//      where to write on the page.
//

import Foundation
import Network
// @Published / ObservableObject — the banner observes pending state.
import Combine

@MainActor
final class Outbox: ObservableObject {

    static let shared = Outbox()

    /// One piece of work waiting to be sent.
    struct Item: Codable, Identifiable {
        enum Kind: String, Codable {
            case chat          // a typed or handwritten message
            case solveMath     // a boxed problem (image)
        }

        let id: UUID
        let kind: Kind
        let createdAt: Date
        /// Message text for `.chat`; base64 PNG for `.solveMath`.
        let payload: String
        let capability: String
        let mood: String
        let customMood: String
        let mathDetail: String
        var attempts: Int

        init(kind: Kind, payload: String, capability: String, mood: String,
             customMood: String, mathDetail: String) {
            self.id = UUID()
            self.kind = kind
            self.createdAt = Date()
            self.payload = payload
            self.capability = capability
            self.mood = mood
            self.customMood = customMood
            self.mathDetail = mathDetail
            self.attempts = 0
        }
    }

    /// Give up after this many tries — roughly 1s, 2s, 4s, 8s, 16s of backoff.
    private static let maxAttempts = 5

    @Published private(set) var pending: [Item] = []
    @Published private(set) var isOnline = true

    /// Called with the reply text when a queued item finally succeeds, so the
    /// page can write it. Set by MagicPaperView.
    var onReply: ((Item, String) -> Void)?
    var onGaveUp: ((Item) -> Void)?

    private let monitor = NWPathMonitor()
    private var isDraining = false
    private let storeKey = "penpal.outbox.v1"

    private init() {
        load()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let online = path.status == .satisfied
                let cameBack = online && !self.isOnline
                self.isOnline = online
                // Coming back online is the moment this whole file exists for.
                if cameBack { self.drain() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "penpal.outbox.network"))
    }

    var hasPending: Bool { !pending.isEmpty }

    // MARK: - Queueing

    /// Keeps work that failed because we were offline. Returns false when the
    /// failure wasn't a connectivity problem — the caller should then show the
    /// real error rather than promising to retry something that can't succeed.
    @discardableResult
    func enqueueIfOffline(_ item: Item, error: Error) -> Bool {
        guard PenpalError.isOffline(error) else { return false }
        enqueue(item)
        return true
    }

    func enqueue(_ item: Item) {
        // A page's worth of pending work is plenty; beyond that the oldest
        // items are stale enough that the user has moved on.
        pending.append(item)
        if pending.count > 20 { pending.removeFirst(pending.count - 20) }
        persist()
    }

    func clear() {
        pending.removeAll()
        persist()
    }

    // MARK: - Draining

    /// Try everything waiting, oldest first, one at a time.
    func drain(settings: HandwritingSettings = .shared) {
        guard !isDraining, isOnline, !pending.isEmpty else { return }
        isDraining = true

        Task { @MainActor in
            defer { isDraining = false }

            while let item = pending.first, isOnline {
                do {
                    let reply = try await send(item, settings: settings)
                    pending.removeFirst()
                    persist()
                    onReply?(item, reply)
                } catch {
                    var updated = item
                    updated.attempts += 1

                    // Permanent failures and exhausted retries leave the queue,
                    // so one bad item can't block everything behind it.
                    if !PenpalError.isTransient(error)
                        || updated.attempts >= Self.maxAttempts {
                        pending.removeFirst()
                        persist()
                        onGaveUp?(updated)
                        continue
                    }

                    pending[0] = updated
                    persist()
                    let delay = pow(2.0, Double(updated.attempts - 1))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
    }

    private func send(_ item: Item,
                      settings: HandwritingSettings) async throws -> String {
        let store = ConversationStore.shared
        switch item.kind {
        case .chat:
            let reply = try await PenpalAPI.chat(
                message: item.payload,
                conversationId: store.conversationId,
                history: store.historyForAPI(),
                baseURL: settings.apiBaseURL,
                capability: item.capability,
                mood: item.mood,
                customMood: item.customMood,
                mathDetail: item.mathDetail)
            store.append(role: "user", content: item.payload)
            store.append(role: "assistant", content: reply)
            return reply

        case .solveMath:
            guard let data = Data(base64Encoded: item.payload) else {
                throw PenpalAPI.APIError.emptyReply
            }
            return try await PenpalAPI.solveMathImage(
                pngData: data,
                history: store.historyForAPI(),
                baseURL: settings.apiBaseURL,
                mathDetail: item.mathDetail)
        }
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([Item].self, from: data)
        else { return }
        // Anything older than a day is no longer wanted — the user has long
        // since moved on, and writing a stale answer onto a new page is worse
        // than dropping it.
        let cutoff = Date().addingTimeInterval(-86_400)
        pending = decoded.filter { $0.createdAt > cutoff }
        if pending.count != decoded.count { persist() }
    }
}
