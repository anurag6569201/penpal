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

        var saved = 0
        let store = PersonalFontStore.shared
        for i in want.indices {
            let ch = want[i]
            // Only positions the user actually changed.
            if i < had.count, had[i] == ch { continue }
            guard trainable.contains(ch) else { continue }
            let cluster = clusters[i]
            guard !cluster.isEmpty else { continue }
            let bounds = cluster.reduce(CGRect.null) { $0.union($1.renderBounds) }
            guard !bounds.isNull else { continue }
            let unit = max(bounds.height, 8)
            let xHeight = max(unit * 0.55, 4)
            let baselineY = bounds.maxY
            if store.addGlyph(from: cluster, for: ch,
                              baselineY: baselineY, xHeight: xHeight) {
                saved += 1
            }
        }
        return saved
    }
}
