//
//  StudyPlanner.swift
//  penpal
//
//  PEN-19 — turn mistakes into practice, spaced over days.
//
//  This is the feature that changes what Penpal IS. Everything else improves
//  the moment a student is stuck; this one gives them a reason to open the app
//  when they are not. "Solve this for me" is a tool. "Here are the two things
//  you keep getting wrong" is a tutor.
//
//  The signal was already there and unused: PEN-16 grading tells us precisely
//  when a student got something wrong, and what the mistake was. That is a far
//  better input than self-reported difficulty — people are poor judges of what
//  they don't know, and a wrong line on their own page is not an opinion.
//
//  Scheduling is a simplified SM-2:
//
//    * a NEW weakness is reviewed tomorrow
//    * getting it right multiplies the interval (1 → 3 → 7 → 16 days …)
//    * getting it wrong resets to tomorrow and lowers the ease
//
//  Deliberately NOT a streak or a points system. Gamifying homework produces
//  people who optimise the game; the reward here is the honest one — the list
//  of things you get wrong gets shorter.
//

import Combine
import Foundation

@MainActor
final class StudyPlanner: ObservableObject {

    static let shared = StudyPlanner()

    struct Weakness: Codable, Identifiable, Equatable {
        let id: UUID
        /// What the student was doing, e.g. "solving linear equations".
        var topic: String
        /// The actual error, from the grader. This is what makes generated
        /// practice specific rather than generic.
        var mistake: String
        var timesSeen: Int
        var timesCorrect: Int
        var dueOn: Date
        var intervalDays: Double
        /// SM-2 ease. Lower = seen wrong more often = comes back sooner.
        var ease: Double
        var lastSeen: Date

        var isDue: Bool { dueOn <= Date() }

        /// Shown in the UI. Honest rather than encouraging: a student can
        /// tell when they are being managed.
        var summary: String {
            timesCorrect == 0
                ? "New — you got this wrong once"
                : "\(timesCorrect) of \(timesSeen) right since"
        }
    }

    @Published private(set) var weaknesses: [Weakness] = []

    private let storeKey = "penpal.study.weaknesses.v1"
    /// More than this and practice becomes a chore rather than a habit.
    private static let maxTracked = 30

    private init() { load() }

    var due: [Weakness] {
        weaknesses.filter(\.isDue).sorted { $0.dueOn < $1.dueOn }
    }

    var hasWorkDue: Bool { !due.isEmpty }

    // MARK: - Recording

    /// Called when the grader finds a mistake (PEN-16).
    ///
    /// Merges into an existing weakness when the topic matches, so repeatedly
    /// fumbling the same thing sharpens one entry rather than creating five.
    func recordMistake(topic: String, mistake: String) {
        let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return }

        if let index = weaknesses.firstIndex(where: {
            $0.topic.localizedCaseInsensitiveCompare(topic) == .orderedSame
        }) {
            weaknesses[index].timesSeen += 1
            weaknesses[index].mistake = mistake
            weaknesses[index].lastSeen = Date()
            // Got it wrong again: back to tomorrow, and harder to graduate.
            weaknesses[index].intervalDays = 1
            weaknesses[index].ease = max(1.3, weaknesses[index].ease - 0.2)
            weaknesses[index].dueOn = Date().addingTimeInterval(86_400)
        } else {
            weaknesses.append(Weakness(
                id: UUID(), topic: topic, mistake: mistake,
                timesSeen: 1, timesCorrect: 0,
                dueOn: Date().addingTimeInterval(86_400),
                intervalDays: 1, ease: 2.3, lastSeen: Date()))
        }
        trim()
        persist()
    }

    /// Called when a practice attempt is marked.
    func recordPractice(_ id: UUID, wasCorrect: Bool) {
        guard let index = weaknesses.firstIndex(where: { $0.id == id }) else { return }
        weaknesses[index].timesSeen += 1
        weaknesses[index].lastSeen = Date()

        if wasCorrect {
            weaknesses[index].timesCorrect += 1
            weaknesses[index].intervalDays = max(1, weaknesses[index].intervalDays)
                * weaknesses[index].ease
            weaknesses[index].ease = min(2.8, weaknesses[index].ease + 0.1)
            // Three clean reviews and a month's gap: it's learned. Keeping it
            // on the list would make the list meaningless.
            if weaknesses[index].timesCorrect >= 3,
               weaknesses[index].intervalDays > 30 {
                weaknesses.remove(at: index)
                persist()
                return
            }
        } else {
            weaknesses[index].intervalDays = 1
            weaknesses[index].ease = max(1.3, weaknesses[index].ease - 0.2)
        }
        weaknesses[index].dueOn = Date().addingTimeInterval(
            weaknesses[index].intervalDays * 86_400)
        persist()
    }

    func forget(_ id: UUID) {
        weaknesses.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Practice

    /// Asks the brain for a problem aimed at this specific weakness.
    func practiceProblem(for weakness: Weakness,
                         baseURL: String) async throws -> PenpalAPI.PracticeProblem {
        // A student who keeps missing something needs a win they can respect,
        // not a harder version of what already beat them.
        let difficulty = weakness.timesCorrect == 0 ? "easier" : "same"
        return try await PenpalAPI.practice(topic: weakness.topic,
                                            mistake: weakness.mistake,
                                            difficulty: difficulty,
                                            baseURL: baseURL)
    }

    // MARK: - Storage

    private func trim() {
        guard weaknesses.count > Self.maxTracked else { return }
        // Drop the ones handled longest ago — a stale weakness the student
        // has quietly outgrown shouldn't crowd out a live one.
        weaknesses.sort { $0.lastSeen > $1.lastSeen }
        weaknesses = Array(weaknesses.prefix(Self.maxTracked))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(weaknesses) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([Weakness].self, from: data)
        else { return }
        weaknesses = decoded
    }
}
