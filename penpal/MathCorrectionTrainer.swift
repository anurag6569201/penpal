//
//  MathCorrectionTrainer.swift
//  penpal
//
//  When the user fixes the Solve chip ("S+S" → "5+5"), fold those ink
//  clusters into PersonalFontStore as Math samples — so the next pause
//  matches their hand without another Teach-it-your-hand pass.
//
//  Safety: only trains when we can 1:1 align corrected tokens to stroke
//  clusters (same count). Only positions that actually changed are saved,
//  so a single fixed digit doesn't rewrite the whole bank.
//

import UIKit
import PencilKit

enum MathCorrectionTrainer {

    /// Characters we will store from a correction (math alphabet + common vars).
    static var trainable: Set<Character> {
        Set(CalibrationView.mathChars)
    }

    /// Tokenize an expression into single trainable glyphs.
    /// "sqrt" → √, "×" stays × if trained that way, "*" stays *.
    /// Returns nil when the string has something we can't map 1:1 to ink.
    static func tokens(in raw: String) -> [Character]? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("=") { s = String(s.dropLast()) }
        var out: [Character] = []
        var i = s.startIndex
        while i < s.endIndex {
            if s[i].isWhitespace {
                i = s.index(after: i)
                continue
            }
            let rest = s[i...].lowercased()
            if rest.hasPrefix("sqrt") {
                out.append("√")
                i = s.index(i, offsetBy: 4, limitedBy: s.endIndex) ?? s.endIndex
                continue
            }
            let ch = s[i]
            let mapped: Character?
            switch ch {
            case "·", "∗", "✕": mapped = "*"
            case "−", "–", "—": mapped = "-"
            default:
                if trainable.contains(ch) {
                    mapped = ch
                } else {
                    let lower = Character(ch.lowercased())
                    mapped = trainable.contains(lower) ? lower : nil
                }
            }
            guard let mapped else { return nil }
            out.append(mapped)
            i = s.index(after: i)
        }
        return out.isEmpty ? nil : out
    }

    /// Learn from a chip correction. Returns how many new glyph samples were stored.
    @discardableResult
    @MainActor
    static func learn(from strokes: [PKStroke],
                      original: String,
                      corrected: String) -> Int {
        guard !strokes.isEmpty else { return 0 }
        guard let want = tokens(in: corrected),
              let had = tokens(in: original),
              want != had else { return 0 }

        let clusters = MathInkParser.symbolClusters(in: strokes)
        // Strict 1:1 — wrong length means we can't trust which ink is which glyph.
        guard clusters.count == want.count, clusters.count <= 40 else { return 0 }

        // LINE METRICS, not per-symbol metrics. Measuring each cluster against
        // its own bounding box is what made trained symbols inconsistent: a
        // "-" would report its baseline at the dash and an x-height of ~3pt,
        // so it normalized to a giant floating dash; a "+" and a "5" on the
        // same line would each claim a different x-height. Every symbol on one
        // handwritten line shares ONE baseline and ONE x-height — derive them
        // from the full-height glyphs (digits/letters) and apply to all.
        guard let metrics = lineMetrics(clusters: clusters, tokens: want) else { return 0 }

        var saved = 0
        let store = PersonalFontStore.shared
        for i in want.indices {
            let ch = want[i]
            // Only positions the user actually changed.
            if i < had.count, had[i] == ch { continue }
            guard trainable.contains(ch) else { continue }
            let cluster = clusters[i]
            guard !cluster.isEmpty else { continue }
            if store.addGlyph(from: cluster, for: ch,
                              baselineY: metrics.baselineY,
                              xHeight: metrics.xHeight) {
                saved += 1
            }
        }
        return saved
    }

    /// Baseline and x-height shared by every symbol on the written line.
    ///
    /// Full-height tokens (digits and letters) define the line: their bottoms
    /// mark the baseline and their heights the cap height. Operators like
    /// "-", "=", "+" are deliberately excluded from the measurement — they
    /// don't touch the baseline and would drag it upward.
    private static func lineMetrics(clusters: [[PKStroke]],
                                    tokens: [Character]) -> (baselineY: CGFloat,
                                                             xHeight: CGFloat)? {
        var bottoms: [CGFloat] = []
        var heights: [CGFloat] = []
        var allBounds = CGRect.null
        for (i, cluster) in clusters.enumerated() where !cluster.isEmpty {
            let b = cluster.reduce(CGRect.null) { $0.union($1.renderBounds) }
            guard !b.isNull else { continue }
            allBounds = allBounds.union(b)
            guard i < tokens.count else { continue }
            let ch = tokens[i]
            // Baseline-sitting, full-height glyphs only.
            guard ch.isNumber || ch.isLetter else { continue }
            bottoms.append(b.maxY)
            heights.append(b.height)
        }
        guard !allBounds.isNull else { return nil }

        // Median is robust to one stray cluster (a descender, a stray dot).
        func median(_ xs: [CGFloat]) -> CGFloat? {
            guard !xs.isEmpty else { return nil }
            let s = xs.sorted()
            return s.count % 2 == 1 ? s[s.count / 2]
                : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }

        // Fall back to the whole line's box when no digit/letter was written
        // (e.g. a correction that is purely operators).
        let baselineY = median(bottoms) ?? allBounds.maxY
        let capHeight = median(heights) ?? allBounds.height
        guard capHeight > 3 else { return nil }
        // Captured glyphs are stored in x-height units; digits are written at
        // cap height, which is HandMetrics.ascender x-heights tall.
        let xHeight = max(4, capHeight / max(1.1, HandMetrics.active.ascender))
        return (baselineY, xHeight)
    }
}
