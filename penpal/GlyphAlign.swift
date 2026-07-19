//
//  GlyphAlign.swift
//  penpal
//
//  Auto-align / deskew / size-normalize personal glyphs so training mistakes
//  (letter floating above the line, slight tilt, inconsistent x-height) don't
//  show up as "some words up, some down" when composing.
//
//  Natural messiness stays at LAYOUT time (gentle per-word drift). Identity
//  geometry is cleaned once at capture and again after VAE/unity morphs.
//

import Foundation
import CoreGraphics

enum GlyphAlign {

    private static let descenders: Set<Character> = ["g", "j", "p", "q", "y"]
    /// Marks drawn at full line height, like tall letters.
    private static let fullHeightMarks: Set<Character> = ["?", "!"]
    /// Small marks keep their drawn position and size — snapping a comma to
    /// the baseline or scaling an apostrophe to x-height mangles them.
    private static let smallMarks: Set<Character> = [".", ",", "'", "\"", ":", ";", "-"]
    /// Canonical vertical anchors for math symbols, in unit space
    /// (baseline 0, x-height 1). `center` is where the symbol's vertical
    /// midpoint belongs — the math axis for operators — and `height` its
    /// canonical ink height (nil = thin mark, anchor the center only).
    /// Mirrors StrokeFont's fallback glyphs so trained and synthetic symbols
    /// sit identically. THIS is the ruleset: operators are anchored by
    /// CENTER, never snapped to the baseline like letters — a trained "="
    /// or "-" must float at the axis, not lie on the line.
    static let mathAnchors: [Character: (center: CGFloat, height: CGFloat?)] = [
        "=": (0.55, 0.30), "+": (0.55, 0.50), "-": (0.52, nil),
        "*": (0.65, 0.40), "×": (0.55, 0.60), "÷": (0.55, 0.66),
        "/": (0.68, 1.33), "^": (1.27, 0.35), "<": (0.55, 0.70),
        ">": (0.55, 0.70), "%": (0.66, 1.28), "(": (0.65, 1.75),
        ")": (0.65, 1.75), "√": (0.75, 1.45), "≤": (0.56, 0.90),
        "≥": (0.56, 0.90), "≠": (0.55, 0.80), "±": (0.50, 0.76),
        "≈": (0.52, 0.50), "π": (0.52, 1.00), "θ": (0.78, 1.55),
        "°": (1.33, 0.26), "∫": (0.75, 1.60), "∞": (0.55, 0.50),
        "Δ": (0.75, 1.50), "·": (0.55, nil),
    ]

    // MARK: - Ownership model (PEN-06)
    //
    // ONE classifier, ONE owner of vertical placement and scale.
    //
    // BB-01 happened because `normalize` (capture time) and `reseat` (render
    // time) each decided for themselves what a character was, using separate
    // copies of the same if-chain. They disagreed: normalize left math symbols
    // alone, reseat baseline-snapped them. The glyph was placed correctly and
    // then moved somewhere else a few milliseconds before it was drawn, and
    // nothing in the codebase said which one was supposed to win.
    //
    // The fix is not a better if-chain — it is having only one. `GlyphRole`
    // is the single classifier; `place(_:as:)` is the single function allowed
    // to decide where a glyph sits and how big it is. Both entry points route
    // through it, so they cannot drift apart again.
    //
    // Anything else that moves ink (StrokeVAE morphs, FragmentBank stitching,
    // ScaleConsensus rescales) must hand the result back to `place` afterwards
    // rather than reasoning about placement itself.

    /// What kind of thing this glyph is, for placement purposes. This is the
    /// ONLY place a character is classified.
    enum GlyphRole {
        /// Operators and symbols: anchored by vertical CENTRE (the math axis),
        /// never seated on the baseline. An "=" floats; it does not sit.
        case mathSymbol(center: CGFloat, height: CGFloat?)
        /// Digits: baseline at 0, top at cap height. Canonical proportions.
        case digit
        /// Letters: LINE TRUST — the size the user trained is the size that
        /// renders. Seated onto the baseline, never rescaled, because relative
        /// size is personal style and "statistical fitting" ruined letterforms.
        case letter(Character?)
        /// Commas, apostrophes, quotes: left exactly as drawn. Snapping a
        /// comma to the baseline or scaling an apostrophe to x-height mangles it.
        case smallMark
    }

    /// The single classifier. `nil` (whole words, morph output) is a letter.
    static func role(for ch: Character?) -> GlyphRole {
        guard let ch else { return .letter(nil) }
        if let anchor = mathAnchors[ch] {
            return .mathSymbol(center: anchor.center, height: anchor.height)
        }
        if ch.isNumber { return .digit }
        if smallMarks.contains(ch) { return .smallMark }
        return .letter(ch)
    }

    /// The single owner of vertical placement and scale. Every path that wants
    /// a glyph positioned goes through here; nothing else may decide.
    ///
    /// `settled` marks a glyph that has already been through the full capture
    /// pipeline and is only being re-seated after a morph — letters then get
    /// the gentler treatment rather than a fresh aggressive snap.
    static func place(_ glyph: PersonalGlyph, as role: GlyphRole,
                      settled: Bool = false) -> PersonalGlyph {
        switch role {
        case .mathSymbol(let center, let height):
            return anchorMathGlyph(glyph, center: center, height: height)
        case .digit:
            return anchorDigit(glyph)
        case .smallMark:
            return rebaseWidth(glyph)
        case .letter(let ch):
            return rebaseWidth(
                snapBaseline(glyph, char: ch, soft: settled,
                             deadBand: settled ? 0.02 : 0.15))
        }
    }

    /// Capture-time placement. See the ownership note above.
    static func normalize(_ glyph: PersonalGlyph, forChar ch: Character? = nil) -> PersonalGlyph {
        place(glyph, as: role(for: ch))
    }

    // MARK: Math anchoring

    /// Vertical extent of real ink (dots included — a symbol's dot is part of
    /// the symbol, unlike an i-tittle which is a diacritic).
    private static func inkExtent(_ glyph: PersonalGlyph) -> (lo: CGFloat, hi: CGFloat)? {
        let pts = glyph.strokes.flatMap { $0 }
        guard let lo = pts.map(\.y).min(), let hi = pts.map(\.y).max() else { return nil }
        return (lo, hi)
    }

    /// Places a math symbol at its canonical center and (when defined) scales
    /// it to its canonical ink height. Scale is clamped so a well-trained
    /// symbol is nudged, never redrawn; the shift is unclamped because a
    /// symbol at the wrong height is always wrong.
    static func anchorMathGlyph(_ glyph: PersonalGlyph,
                                center: CGFloat, height: CGFloat?) -> PersonalGlyph {
        guard let ext = inkExtent(glyph) else { return rebaseWidth(glyph) }
        var g = glyph
        let drawnHeight = ext.hi - ext.lo

        // 1. Scale to the canonical ink height, if this symbol defines one.
        // The clamp is wide on purpose. For LETTERS, relative size carries
        // personal style, so rescaling is destructive and tightly limited.
        // A math symbol has canonical proportions — a "+" is a "+" at any
        // size — so a badly captured one should be corrected all the way,
        // in ONE pass (a partial correction would also make the migration
        // non-idempotent, drifting a little further on each run).
        if let height, drawnHeight > 0.04 {
            // 4× covers the worst real captures (a "(" trained at a third of
            // its proper height, an "=" scribbled tiny). Anything beyond that
            // is measurement noise, and the `drawnHeight > 0.04` guard above
            // already rejects degenerate ink. The bound must be wide enough
            // to finish the correction in ONE pass: a clamped, partial fix
            // would leave the migration non-idempotent, drifting the bank a
            // little further every time it re-runs.
            let scale = min(4.0, max(0.25, height / drawnHeight))
            if abs(scale - 1) > 0.06 {
                g = scaleGlyph(g, by: scale)
            }
        }

        // 2. Shift so the symbol's vertical midpoint lands on its anchor.
        guard let ext2 = inkExtent(g) else { return rebaseWidth(g) }
        let mid = (ext2.lo + ext2.hi) / 2
        let shift = center - mid
        if abs(shift) > 0.02 {
            var strokes = g.strokes
            for si in 0..<strokes.count {
                for pi in 0..<strokes[si].count {
                    strokes[si][pi].y += shift
                }
            }
            g = replacingStrokes(g, strokes)
        }
        return rebaseWidth(g)
    }

    /// Digits: baseline at 0, top at cap height (the user's own ascender line).
    static func anchorDigit(_ glyph: PersonalGlyph) -> PersonalGlyph {
        guard let ext = inkExtent(glyph) else { return rebaseWidth(glyph) }
        var g = glyph
        let drawnHeight = ext.hi - ext.lo
        let target = HandMetrics.active.ascender

        if drawnHeight > 0.15 {
            // Wide enough that a digit captured at ~30% of cap height (a bad
            // Solve-chip cluster) still corrects in ONE pass. That matters
            // beyond tidiness: if capture leaves a digit short, render-time
            // reseat would scale it the rest of the way, and capture and
            // render would once again disagree about the same glyph — the
            // exact class of bug PEN-06 exists to make impossible.
            let scale = min(3.5, max(0.3, target / drawnHeight))
            if abs(scale - 1) > 0.08 {
                g = scaleGlyph(g, by: scale)
            }
        }
        // Sit the digit's floor on the baseline.
        guard let ext2 = inkExtent(g) else { return rebaseWidth(g) }
        if abs(ext2.lo) > 0.04 {
            var strokes = g.strokes
            for si in 0..<strokes.count {
                for pi in 0..<strokes[si].count {
                    strokes[si][pi].y -= ext2.lo
                }
            }
            g = replacingStrokes(g, strokes)
        }
        return rebaseWidth(g)
    }

    /// Uniform scale about the unit origin, carrying pen widths along.
    private static func scaleGlyph(_ glyph: PersonalGlyph, by scale: CGFloat) -> PersonalGlyph {
        var strokes = glyph.strokes
        for si in 0..<strokes.count {
            for pi in 0..<strokes[si].count {
                strokes[si][pi].x *= scale
                strokes[si][pi].y *= scale
            }
        }
        // PEN-31: `map` instead of force-unwrapped mutation. The old form was
        // guarded by `if widths != nil` and safe today, but the guard and the
        // unwrap were separate statements — one refactor apart from crashing
        // the app's only critical path.
        let widths = glyph.widths?.map { row in row.map { $0 * scale } }
        var g = replacingStrokes(glyph, strokes)
        g.widths = widths
        g.width = glyph.width * scale
        return g
    }

    private static func replacingStrokes(_ glyph: PersonalGlyph,
                                         _ strokes: [[CGPoint]]) -> PersonalGlyph {
        PersonalGlyph(width: glyph.width, strokes: strokes, widths: glyph.widths,
                      durations: glyph.durations, gaps: glyph.gaps, refSize: glyph.refSize,
                      pointTimes: glyph.pointTimes, forces: glyph.forces,
                      altitudes: glyph.altitudes, azimuths: glyph.azimuths,
                      inputSource: glyph.inputSource, quality: glyph.quality)
    }

    /// Render-time placement, after a VAE morph or fragment stitch has nudged
    /// the geometry. Routes through the SAME owner as `normalize`, differing
    /// only in `settled: true` — which softens the letter case and changes
    /// nothing for symbols or digits, whose anchors are absolute.
    ///
    /// This shared route is the actual PEN-06 fix. Previously this function
    /// had its own copy of the classification logic and quietly disagreed with
    /// `normalize` about math symbols, baseline-snapping them at render time
    /// and undoing their anchor (BB-01 defect #2).
    static func reseat(_ glyph: PersonalGlyph, forChar ch: Character? = nil) -> PersonalGlyph {
        place(glyph, as: role(for: ch), settled: true)
    }

    // MARK: Deskew

    /// Rotate around centroid to cancel mild pen tilt (clamped).
    static func deskew(_ glyph: PersonalGlyph, maxDegrees: CGFloat) -> PersonalGlyph {
        let body = bodyPoints(glyph)
        guard body.count >= 4 else { return glyph }

        // Covariance → principal axis angle.
        let cx = body.map(\.x).reduce(0, +) / CGFloat(body.count)
        let cy = body.map(\.y).reduce(0, +) / CGFloat(body.count)
        var sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
        for p in body {
            let dx = p.x - cx, dy = p.y - cy
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        // Angle of major axis; for handwriting we want verticals upright,
        // so rotate by the deviation of the minor-ish slant from vertical.
        let angle = 0.5 * atan2(2 * sxy, sxx - syy) // radians
        // Only undo small tilts — big angles are intentional style.
        let deg = angle * 180 / .pi
        let clamped = max(-maxDegrees, min(maxDegrees, deg))
        // Prefer correcting near-horizontal shear of upright strokes: if |deg| tiny, skip.
        guard abs(clamped) > 1.2 else { return glyph }

        let a = -clamped * .pi / 180
        let cosA = cos(a), sinA = sin(a)

        var strokes = glyph.strokes
        for si in 0..<strokes.count {
            for pi in 0..<strokes[si].count {
                let p = strokes[si][pi]
                let dx = p.x - cx, dy = p.y - cy
                strokes[si][pi] = CGPoint(x: cx + dx * cosA - dy * sinA,
                                          y: cy + dx * sinA + dy * cosA)
            }
        }
        return PersonalGlyph(width: glyph.width, strokes: strokes, widths: glyph.widths,
                             durations: glyph.durations, gaps: glyph.gaps, refSize: glyph.refSize,
                             pointTimes: glyph.pointTimes, forces: glyph.forces,
                             altitudes: glyph.altitudes, azimuths: glyph.azimuths,
                             inputSource: glyph.inputSource, quality: glyph.quality)
    }

    // MARK: Baseline

    /// Shift so the writing sits on y = 0 (unit baseline). `deadBand` is how
    /// far off the line the ink may sit before we touch it at all — captures
    /// made against visible guides get a generous band so near-correct
    /// training stays exactly as drawn.
    static func snapBaseline(_ glyph: PersonalGlyph, char: Character?, soft: Bool = false,
                             deadBand: CGFloat = 0.02) -> PersonalGlyph {
        let body = bodyPoints(glyph)
        guard !body.isEmpty else { return glyph }

        let ys = body.map(\.y).sorted()
        let hasDescender: Bool = {
            if let ch = char?.lowercased().first, descenders.contains(ch) { return true }
            // Auto-detect: significant ink below the main body cluster.
            let q15 = quantile(ys, 0.15)
            let q50 = quantile(ys, 0.50)
            return (q50 - q15) > 0.55 && q15 < -0.15
        }()

        // Sitting line: low percentile for normal letters; higher if descenders
        // pull the absolute floor down.
        let baseline: CGFloat
        if hasDescender {
            // Body sits near the upper part of the lower half.
            baseline = quantile(ys, soft ? 0.42 : 0.38)
        } else {
            baseline = quantile(ys, soft ? 0.14 : 0.10)
        }

        guard abs(baseline) > deadBand else { return glyph }

        var strokes = glyph.strokes
        for si in 0..<strokes.count {
            for pi in 0..<strokes[si].count {
                strokes[si][pi].y -= baseline
            }
        }
        return PersonalGlyph(width: glyph.width, strokes: strokes, widths: glyph.widths,
                             durations: glyph.durations, gaps: glyph.gaps, refSize: glyph.refSize,
                             pointTimes: glyph.pointTimes, forces: glyph.forces,
                             altitudes: glyph.altitudes, azimuths: glyph.azimuths,
                             inputSource: glyph.inputSource, quality: glyph.quality)
    }

    // MARK: X-height

    /// Scale so the main body reaches ~1.0 (x-height), with sane clamps.
    static func fitXHeight(_ glyph: PersonalGlyph, char: Character?) -> PersonalGlyph {
        let body = bodyPoints(glyph)
        guard body.count >= 2 else { return glyph }

        let ys = body.map(\.y).sorted()
        // Ignore extreme ascender tips for scale (use ~90th percentile of body).
        var top = quantile(ys, 0.90)
        // Dots / tittles sit high — exclude points well above the body mass.
        let bodyCore = body.filter { $0.y < top + 0.15 }
        if bodyCore.count >= 2 {
            top = quantile(bodyCore.map(\.y).sorted(), 0.92)
        }

        // Tall letters are normalized by the feature that defines their size
        // CONSISTENCY, not by their tallest pixel:
        // - bowl ascenders (b d h k): the bowl/arch is the body — scale it to
        //   x-height so it matches a/o/e bowls; the stem keeps the user's own
        //   height (identity). Scaling by the stem made bowl size depend on
        //   stem height → "small-circled b next to big d".
        // - stem letters (l f, t shorter): the stem IS the letter — scale to
        //   the ascender line.
        // - capitals & digits: cap height ≈ ascender line. (They previously
        //   fell into the x-height branch and were squashed toward
        //   lowercase height.)
        // Targets come from the user's own four-line system (HandMetrics):
        // line 2 = baseline 0, line 3 = x-height 1, line 4 = ascender.
        let metrics = HandMetrics.active
        let lower = char?.lowercased().first
        let target: CGFloat
        if let ch = char, ch.isLowercase, let l = lower,
           ["b", "d", "h", "k"].contains(l) {
            top = quantile(ys, 0.70)   // bowl/arch top, stem excluded
            target = 1.0
        } else if let ch = char, ch.isLowercase, let l = lower,
                  ["l", "f", "t"].contains(l) {
            target = l == "t" ? metrics.tHeight : metrics.ascender
        } else if let ch = char, ch.isUppercase || ch.isNumber {
            target = metrics.ascender
        } else if let ch = char, fullHeightMarks.contains(ch) {
            // ? and ! reach the ascender line — the previous fall-through to
            // x-height is why question marks rendered tiny.
            target = metrics.ascender
        } else {
            target = 1.0
        }

        guard top > 0.25 else { return glyph }
        var scale = target / top
        // Don't over-correct single letters — near-correct training stays put.
        // Words get a much wider band: users often write one word big and the
        // next small, and a tight clamp preserved that inconsistency, which
        // showed up as "one word small, one word big" in replies.
        if char == nil {
            scale = min(1.9, max(0.55, scale))
        } else {
            scale = min(1.35, max(0.72, scale))
        }
        // Line trust: the user wrote against visible ruled lines — if the
        // ink sits near them, keep it EXACTLY as drawn. Resizing from ink
        // statistics is itself a bug source; it only earns its keep when a
        // capture clearly ignored the guides.
        if abs(scale - 1) < 0.12 { return glyph }

        var strokes = glyph.strokes
        for si in 0..<strokes.count {
            for pi in 0..<strokes[si].count {
                strokes[si][pi].x *= scale
                strokes[si][pi].y *= scale
            }
        }
        let widths = glyph.widths?.map { row in row.map { $0 * scale } }   // PEN-31
        return PersonalGlyph(width: glyph.width * scale, strokes: strokes, widths: widths,
                             durations: glyph.durations, gaps: glyph.gaps, refSize: glyph.refSize,
                             pointTimes: glyph.pointTimes, forces: glyph.forces,
                             altitudes: glyph.altitudes, azimuths: glyph.azimuths,
                             inputSource: glyph.inputSource, quality: glyph.quality)
    }

    // MARK: Width rebase

    static func rebaseWidth(_ glyph: PersonalGlyph) -> PersonalGlyph {
        let all = glyph.strokes.flatMap { $0 }
        guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max() else { return glyph }
        var strokes = glyph.strokes
        if abs(minX) > 0.001 {
            for si in 0..<strokes.count {
                for pi in 0..<strokes[si].count {
                    strokes[si][pi].x -= minX
                }
            }
        }
        return PersonalGlyph(width: max(0.15, maxX - minX),
                             strokes: strokes,
                             widths: glyph.widths,
                             durations: glyph.durations,
                             gaps: glyph.gaps,
                             refSize: glyph.refSize,
                             pointTimes: glyph.pointTimes, forces: glyph.forces,
                             altitudes: glyph.altitudes, azimuths: glyph.azimuths,
                             inputSource: glyph.inputSource, quality: glyph.quality)
    }

    /// Align each letter onto a shared baseline before packing into a word.
    static func alignForPacking(_ glyphs: [PersonalGlyph]) -> [PersonalGlyph] {
        glyphs.map { reseat(normalize($0, forChar: nil)) }
    }

    // MARK: Body height (rendered x-height)

    /// Robust rendered x-height of a glyph in unit space: the median of the
    /// per-column top envelope. Ascenders and dots lift only a minority of
    /// columns, so the median tracks the letter BODY, not the tallest stroke.
    /// This is what "size" means to the eye — two words look the same size
    /// when their bodies match, regardless of ascender reach.
    static func bodyHeight(_ glyph: PersonalGlyph) -> CGFloat? {
        let pts = bodyPoints(glyph)
        guard glyph.width > 0.05 else { return nil }
        return bodyHeight(points: pts, minX: 0, maxX: glyph.width)
    }

    /// Same measure restricted to a horizontal window (a letter slice).
    static func bodyHeight(points: [CGPoint], minX: CGFloat, maxX: CGFloat) -> CGFloat? {
        let span = maxX - minX
        guard span > 0.04 else { return nil }
        let columns = max(4, min(48, Int(span * 12)))
        var tops = [CGFloat](repeating: -.greatestFiniteMagnitude, count: columns)
        for p in points {
            guard p.x >= minX, p.x < maxX, p.y > -0.05 else { continue }
            let c = min(columns - 1, max(0, Int((p.x - minX) / span * CGFloat(columns))))
            tops[c] = max(tops[c], p.y)
        }
        let filled = tops.filter { $0 > 0.08 }.sorted()
        guard filled.count >= 3 else { return nil }
        return max(0.2, quantile(filled, 0.5))
    }

    // MARK: Helpers

    /// Ink that counts for MEASUREMENT. Floating tittles and small marks
    /// hovering above the body (i-dots, j-dots, accents) are position, not
    /// size — including them made "i" measure taller than "a" and get
    /// wrongly shrunk. They still render exactly where they were drawn;
    /// they just don't vote on how big the letter is.
    static func measurablePoints(_ glyph: PersonalGlyph) -> [CGPoint] {
        var out: [CGPoint] = []
        for pts in glyph.strokes where pts.count >= 2 {
            if let lo = pts.map(\.y).min(), let hi = pts.map(\.y).max(),
               lo > 0.9, hi - lo < 0.45 {
                continue   // detached mark floating above the body
            }
            out.append(contentsOf: pts)
        }
        // If everything was dots/marks, fall back to all points.
        if out.isEmpty {
            out = glyph.strokes.flatMap { $0 }
        }
        return out
    }

    private static func bodyPoints(_ glyph: PersonalGlyph) -> [CGPoint] {
        measurablePoints(glyph)
    }

    private static func quantile(_ sorted: [CGFloat], _ q: CGFloat) -> CGFloat {
        guard !sorted.isEmpty else { return 0 }
        let t = min(1, max(0, q)) * CGFloat(sorted.count - 1)
        let i = Int(t)
        let f = t - CGFloat(i)
        if i + 1 < sorted.count {
            return sorted[i] * (1 - f) + sorted[i + 1] * f
        }
        return sorted[i]
    }
}
