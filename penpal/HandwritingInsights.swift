//
//  HandwritingInsights.swift
//  penpal
//
//  PEN-24 — show the user their own hand.
//
//  We already model this person's handwriting in some detail: slant, its
//  variance, pressure, speed, curvature, letter width, connectedness. All of
//  it exists to *imitate* them. None of it is ever shown to them, and it is
//  genuinely interesting — most people have never seen a measurement of their
//  own writing.
//
//  The framing decision, from the backlog and kept: this is OBSERVATION, not
//  correction. An app that critiques your handwriting unprompted is
//  unpleasant, faintly insulting, and would poison the relationship with a
//  product whose whole premise is "this is *your* hand, and it's good". So:
//
//    * opt-in, never surfaced unless asked for
//    * describes, does not grade — no scores out of ten, no "needs work"
//    * consistency is framed neutrally: a steady hand and a varied one are
//      both described, neither is called better
//    * requires enough samples to be honest, and says so when it doesn't
//      have them rather than inventing a reading
//

import CoreGraphics
import Foundation

@MainActor
enum HandwritingInsights {

    struct Insight: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let systemImage: String
    }

    /// Minimum trained words before any reading is offered. Below this the
    /// numbers are noise, and a confident-sounding wrong description of
    /// someone's handwriting is worse than no description.
    private static let minimumSamples = 8

    static var hasEnoughData: Bool {
        PersonalFontStore.shared.trainedWords.count >= minimumSamples
    }

    static var sampleCount: Int {
        PersonalFontStore.shared.trainedWords.count
    }

    /// Everything we can honestly say about this hand right now.
    static func current() -> [Insight] {
        guard hasEnoughData else { return [] }
        let profile = PersonalFontStore.shared.profile
        let metrics = HandMetrics.active
        var insights: [Insight] = []

        // Slant — described by direction, not judged.
        let slant = profile.slant
        insights.append(Insight(
            title: slantName(slant),
            detail: slantDetail(slant),
            systemImage: "italic"))

        // Connectedness — print vs cursive, again neutral.
        let joined = profile.connectedness
        insights.append(Insight(
            title: joined > 0.6 ? "Mostly joined-up"
                 : joined > 0.3 ? "A mix of joined and printed"
                                : "Mostly printed",
            detail: joined > 0.6
                ? "You keep the pen down across letters — Penpal copies those joins from your own writing, never invents them."
                : joined > 0.3
                ? "You join some letters and lift for others. That mix is part of what makes your hand recognisable."
                : "You lift the pen between most letters, which keeps each letterform distinct.",
            systemImage: "link"))

        // Letter proportions, from the user's own four-line system.
        insights.append(Insight(
            title: "Tall letters reach \(String(format: "%.1f", metrics.ascender))× your x-height",
            detail: "Typical handwriting sits between 1.4× and 1.9×. This is measured from your own ruled-line training, so it's how you actually write rather than a standard.",
            systemImage: "arrow.up.and.down"))

        // Consistency — the one people are curious about. Framed as a
        // characteristic, never as a fault.
        let variability = profile.accelerationCV
        insights.append(Insight(
            title: variability < 0.25 ? "A steady, even pace"
                 : variability < 0.5 ? "A naturally varied pace"
                                     : "A lively, fast-changing pace",
            detail: variability < 0.25
                ? "Your writing speed stays fairly constant. Penpal matches that evenness so replies don't look rushed next to your own work."
                : "Your speed rises and falls as you write. Penpal reproduces that rhythm — it's a large part of why replayed ink reads as human.",
            systemImage: "waveform.path"))

        // Word spacing.
        insights.append(Insight(
            title: "Word gaps around \(String(format: "%.2f", profile.wordGapUnits))× your x-height",
            detail: "Penpal uses this spacing when it writes, so a reply sits at your own rhythm on the line.",
            systemImage: "arrow.left.and.right"))

        return insights
    }

    // MARK: - Wording

    private static func slantName(_ slant: CGFloat) -> String {
        switch slant {
        case ..<(-0.12): return "A left-leaning hand"
        case ..<0.12:    return "An upright hand"
        case ..<0.4:     return "A gently right-leaning hand"
        default:         return "A strongly right-leaning hand"
        }
    }

    private static func slantDetail(_ slant: CGFloat) -> String {
        let degrees = Int((atan(Double(slant)) * 180 / .pi).rounded())
        if abs(slant) < 0.12 {
            return "Your letters stand close to vertical — about \(abs(degrees))° off upright."
        }
        return "Your letters lean about \(abs(degrees))° "
            + (slant > 0 ? "to the right" : "to the left")
            + ". Penpal writes at the same angle."
    }

    /// Shown when there isn't enough training to say anything honest.
    static var notEnoughDataMessage: String {
        let remaining = max(0, minimumSamples - sampleCount)
        return "Train \(remaining) more word\(remaining == 1 ? "" : "s") and I can show you what I've learned about your handwriting."
    }
}
