//
//  ScaleConsensus.swift
//  penpal
//
//  Corpus-level size cross-calibration.
//
//  fitXHeight judges every capture ALONE, so its per-sample x-height estimate
//  is noisy and the wide word clamp lets that noise into storage — "was" and
//  "lovely" end up stored at different effective scales and the reply line
//  looks unevenly sized. But all samples come from ONE hand, so shared letters
//  give cross-constraints: the "o" in "more" must be the same size as the "o"
//  in "love". This solves per-sample scale factors jointly (Gauss–Seidel over
//  the bipartite sample↔letter-class graph) instead of trusting each sample's
//  own quantiles.
//
//  Also learns the isolated-letter gain: people draw a lone training "m" big
//  and careful but write it small and fast inside words. Words built from the
//  char bank apply this gain so both sources sit at one visual size.
//
//  Measurement is PART-AWARE: multi-zone letters vote with the part of them
//  that touches the x-height (b's bowl, h's arch, y's vee), not just the
//  letters that are all body. See partBodyLetters.
//

import CoreGraphics
import Foundation

/// The four ruled lines of the user's hand, in unit space (baseline = 0,
/// x-height = 1, y grows up). Line 1 = descender floor, line 2 = baseline,
/// line 3 = x-height, line 4 = ascender/cap top. Every glyph is positioned
/// and sized relative to these — ONE source of truth instead of magic
/// numbers scattered through normalization.
///
/// The ratios are learned from the user's own ink: how tall THEY draw an
/// "l" relative to their "o", how deep THEIR "y" dives. Starts at classic
/// prior proportions and personalizes as words are trained.
struct HandMetrics {
    /// Line 4: ascender/cap top (unit x-heights above baseline).
    var ascender: CGFloat = 1.65
    /// Line 1: descender floor (negative — below baseline).
    var descender: CGFloat = -0.6
    /// "t" gets its own line — most hands stop it short of the ascender,
    /// but by a personal amount. Learned from the user's t's when available.
    var tHeight: CGFloat = 1.46
    var samples: Int = 0

    /// Single global instance the geometry pipeline reads. Refreshed by
    /// PersonalFontStore whenever training data changes.
    static var active = HandMetrics()
}

enum ScaleConsensus {

    /// Learn the user's four-line proportions from word captures. Ascender
    /// letters teach line 4, descender letters teach line 1. Isolated char
    /// captures are excluded — they were normalized TO the old targets, so
    /// measuring them would be circular.
    static func handMetrics(words: [String: [PersonalGlyph]]) -> HandMetrics {
        let ascLetters: Set<Character> = ["b", "d", "f", "h", "k", "l"]
        let descLetters: Set<Character> = ["g", "j", "p", "q", "y"]
        var ascObs: [CGFloat] = []
        var descObs: [CGFloat] = []
        var tObs: [CGFloat] = []

        for (key, variants) in words {
            let chars = Array(key.lowercased().filter(\.isLetter))
            guard chars.count >= 2 else { continue }
            for glyph in variants where glyph.width > 0.1 {
                var cum: [CGFloat] = [0]
                for ch in chars {
                    cum.append(cum.last! + max(0.15, StrokeFont.glyph(for: ch).width))
                }
                let total = max(0.3, cum.last!)
                let points = GlyphAlign.measurablePoints(glyph)
                for (i, ch) in chars.enumerated() {
                    let x0 = glyph.width * cum[i] / total
                    let x1 = glyph.width * cum[i + 1] / total
                    let ys = points.filter { $0.x >= x0 && $0.x < x1 }.map(\.y)
                    if ascLetters.contains(ch) {
                        if let top = ys.max(), top > 1.15, top < 2.6 { ascObs.append(top) }
                    } else if descLetters.contains(ch) {
                        if let bottom = ys.min(), bottom < -0.15, bottom > -1.6 {
                            descObs.append(bottom)
                        }
                    } else if ch == "t" {
                        if let top = ys.max(), top > 1.05, top < 2.4 { tObs.append(top) }
                    }
                }
            }
        }

        var m = HandMetrics()
        // Shrink toward the priors — a couple of observations shouldn't yank
        // the ruled lines around; personalization fades in with data.
        let priorWeight: CGFloat = 4
        if !ascObs.isEmpty {
            m.ascender = (1.65 * priorWeight + ascObs.reduce(0, +))
                / (priorWeight + CGFloat(ascObs.count))
        }
        if !descObs.isEmpty {
            m.descender = (-0.6 * priorWeight + descObs.reduce(0, +))
                / (priorWeight + CGFloat(descObs.count))
        }
        m.ascender = min(2.2, max(1.25, m.ascender))
        m.descender = min(-0.3, max(-1.3, m.descender))
        if !tObs.isEmpty {
            m.tHeight = (1.46 * priorWeight + tObs.reduce(0, +))
                / (priorWeight + CGFloat(tObs.count))
        } else {
            m.tHeight = 0.55 + m.ascender * 0.55
        }
        m.tHeight = min(max(m.tHeight, 1.15), m.ascender + 0.15)
        m.samples = ascObs.count + descObs.count + tObs.count
        return m
    }

    /// Letters whose body top IS the x-height (no ascender/descender/cap).
    /// These give the cleanest size observations.
    static let xBodyLetters: Set<Character> = ["a", "c", "e", "i", "m", "n", "o",
                                               "r", "s", "u", "v", "w", "x", "z"]

    /// PART-AWARE MEASUREMENT: multi-zone letters whose BODY still tops out
    /// at the x-height — the bowl of b/d/g/p/q, the arch of h, the vee of y.
    /// The column-top-envelope measure already resists the minority of
    /// columns a stem lifts (and descender tails only affect column BOTTOMS,
    /// which bodyHeight never reads), so their body part is x-height evidence
    /// too: "b tells you how big a should be" because both are measured
    /// against the same line. This nearly doubles the letters that vote, so
    /// almost every capture cross-constrains the joint solve.
    ///
    /// Excluded on purpose: k (its arm holds ascender height across the right
    /// half, defeating the quantile), and f/l/t/j (no x-height body at all).
    static let partBodyLetters: Set<Character> = ["b", "d", "g", "h", "p", "q", "y"]

    /// Reading point in the sorted column-top envelope for part letters —
    /// below the median so stem-lifted columns can't drag the body up.
    private static let partQuantile: CGFloat = 0.4

    /// A part-letter body reading this tall means the slice was dominated by
    /// its stem (windows are width-prior estimates, not true segmentation) —
    /// that's ascender evidence, not body evidence. Dropped, never clamped.
    private static let partBodyCeiling: CGFloat = 1.45

    // MARK: Observations

    /// Body height of each measurable letter inside a captured word,
    /// using the same width-prior slicing as FragmentBank.
    static func letterHeights(word key: String, glyph: PersonalGlyph) -> [(Character, CGFloat)] {
        let chars = Array(key.lowercased().filter(\.isLetter))
        guard chars.count >= 2, glyph.width > 0.1 else { return [] }

        var cum: [CGFloat] = [0]
        for ch in chars {
            cum.append(cum.last! + max(0.15, StrokeFont.glyph(for: ch).width))
        }
        let total = max(0.3, cum.last!)
        // Tittles excluded: an in-word "i" must measure by its stem, not its dot.
        let points = GlyphAlign.measurablePoints(glyph)

        var out: [(Character, CGFloat)] = []
        for (i, ch) in chars.enumerated() {
            let isPart = partBodyLetters.contains(ch)
            guard xBodyLetters.contains(ch) || isPart else { continue }
            let x0 = glyph.width * cum[i] / total
            let x1 = glyph.width * cum[i + 1] / total
            if let h = GlyphAlign.bodyHeight(points: points, minX: x0, maxX: x1,
                                             bodyQuantile: isPart ? partQuantile : 0.5) {
                if isPart && h > partBodyCeiling { continue }
                out.append((ch, h))
            }
        }
        return out
    }

    /// Body height of a WORD measured only from its x-body letters. The
    /// whole-glyph column median lies for ascender-heavy words ("tell" is
    /// 3/4 tall letters, so its median reads as ascender height and the word
    /// gets wrongly shrunk — the short-t bug). Nil when no x-body letters.
    static func bodyHeight(word key: String, glyph: PersonalGlyph) -> CGFloat? {
        let obs = letterHeights(word: key, glyph: glyph)
        guard !obs.isEmpty else { return nil }
        return median(obs.map(\.1))
    }

    // MARK: Class means

    /// Consensus body height per letter class, solved jointly with per-sample
    /// scales (two Gauss–Seidel sweeps are plenty for data this small).
    static func classMeans(words: [String: [PersonalGlyph]]) -> [Character: CGFloat] {
        // sample id → its letter observations
        var samples: [[(Character, CGFloat)]] = []
        for (key, variants) in words {
            for glyph in variants {
                let obs = letterHeights(word: key, glyph: glyph)
                if obs.count >= 1 { samples.append(obs) }
            }
        }
        guard !samples.isEmpty else { return [:] }

        var means = medianByClass(samples.flatMap { $0 })
        var scales = [CGFloat](repeating: 1, count: samples.count)

        for _ in 0..<2 {
            for (i, obs) in samples.enumerated() {
                let ratios = obs.compactMap { ch, h -> CGFloat? in
                    guard h > 0.15, let m = means[ch] else { return nil }
                    return m / h
                }
                if let s = median(ratios) {
                    scales[i] = min(1.6, max(0.6, s))
                }
            }
            var rescaled: [(Character, CGFloat)] = []
            for (i, obs) in samples.enumerated() {
                rescaled.append(contentsOf: obs.map { ($0.0, $0.1 * scales[i]) })
            }
            means = medianByClass(rescaled)
        }
        return means
    }

    // MARK: Per-sample scales

    /// Scale that brings one word capture into consensus with the corpus.
    /// Partial correction (90%) — dead-uniform sizing reads as a font.
    static func scale(forWord key: String, glyph: PersonalGlyph,
                      means: [Character: CGFloat]) -> CGFloat {
        let obs = letterHeights(word: key, glyph: glyph)
        let ratios = obs.compactMap { ch, h -> CGFloat? in
            guard h > 0.15, let m = means[ch] else { return nil }
            return m / h
        }
        guard ratios.count >= 1, let s = median(ratios) else { return 1 }
        // Line trust: near-consensus captures stay exactly as drawn.
        if abs(s - 1) < 0.1 { return 1 }
        return min(1.4, max(0.75, 1 + (s - 1) * 0.9))
    }

    /// How much bigger isolated char training is than the same letters in
    /// real word flow. Applied when composing words from the char bank.
    static func isolatedGain(means: [Character: CGFloat],
                             chars: [String: [PersonalGlyph]]) -> CGFloat {
        var ratios: [CGFloat] = []
        for (key, variants) in chars {
            guard key.count == 1, let ch = key.first,
                  xBodyLetters.contains(ch) || partBodyLetters.contains(ch),
                  let m = means[ch] else { continue }
            for glyph in variants {
                // Part letters: a stem-dominated reading is ascender
                // evidence, not body evidence — skip it (same rule as
                // letterHeights).
                if let h = GlyphAlign.bodyHeight(glyph), h > 0.2,
                   !(partBodyLetters.contains(ch) && h > partBodyCeiling) {
                    ratios.append(m / h)
                }
            }
        }
        guard ratios.count >= 4, let g = median(ratios) else { return 1 }
        return min(1.2, max(0.78, g))
    }

    // MARK: Full solve (one-shot migration / rebuild)

    struct Result {
        var wordScales: [String: [CGFloat]] = [:]
        var charScales: [String: [CGFloat]] = [:]
        var changed = false
    }

    /// Per-variant correction scales for the whole store. Words calibrate
    /// against the corpus consensus; char variants calibrate against their
    /// own class median (their absolute size is handled by isolatedGain).
    static func solve(words: [String: [PersonalGlyph]],
                      chars: [String: [PersonalGlyph]]) -> Result {
        var result = Result()
        let means = classMeans(words: words)
        guard !means.isEmpty else { return result }

        for (key, variants) in words {
            let scales = variants.map { scale(forWord: key, glyph: $0, means: means) }
            result.wordScales[key] = scales
            if scales.contains(where: { abs($0 - 1) > 0.04 }) { result.changed = true }
        }

        for (key, variants) in chars {
            guard variants.count >= 2 else { continue }
            let heights = variants.map { GlyphAlign.bodyHeight($0) ?? 0 }
            let valid = heights.filter { $0 > 0.2 }
            guard valid.count >= 2, let target = median(valid) else { continue }
            let scales = heights.map { h -> CGFloat in
                guard h > 0.2 else { return 1 }
                return min(1.25, max(0.8, 1 + (target / h - 1) * 0.85))
            }
            result.charScales[key] = scales
            if scales.contains(where: { abs($0 - 1) > 0.04 }) { result.changed = true }
        }
        return result
    }

    /// Uniformly rescale a glyph (geometry + ink width) around the baseline.
    static func apply(_ s: CGFloat, to glyph: PersonalGlyph) -> PersonalGlyph {
        guard abs(s - 1) > 0.02 else { return glyph }
        var g = glyph
        for si in 0..<g.strokes.count {
            for pi in 0..<g.strokes[si].count {
                g.strokes[si][pi].x *= s
                g.strokes[si][pi].y *= s
            }
        }
        g.widths = g.widths?.map { row in row.map { $0 * s } }   // PEN-31
        g.width *= s
        return g
    }

    // MARK: Dispersion

    /// Coefficient of variation (sd / mean) — THE number for "some letters
    /// big, some small". 0 means every measurement is identical. Computed
    /// over resolved word body heights by HandwritingInsights, and asserted
    /// in the regression suite so a sizing regression can't ship silently.
    static func coefficientOfVariation(_ values: [CGFloat]) -> CGFloat? {
        guard values.count >= 2 else { return nil }
        let mean = values.reduce(0, +) / CGFloat(values.count)
        guard mean > 0.01 else { return nil }
        let varSum = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return (varSum / CGFloat(values.count)).squareRoot() / mean
    }

    // MARK: Helpers

    private static func medianByClass(_ obs: [(Character, CGFloat)]) -> [Character: CGFloat] {
        var byClass: [Character: [CGFloat]] = [:]
        for (ch, h) in obs where h > 0.15 {
            byClass[ch, default: []].append(h)
        }
        var out: [Character: CGFloat] = [:]
        for (ch, hs) in byClass {
            if let m = median(hs) { out[ch] = m }
        }
        return out
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
