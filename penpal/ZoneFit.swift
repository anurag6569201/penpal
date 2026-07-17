//
//  ZoneFit.swift
//  penpal
//
//  Final four-line enforcement — the render pipeline's exit contract.
//
//  Capture normalization, consensus scaling, fragment stitching and morphs
//  each try to keep proportions right, but any of them can leak (a squashed
//  "t", a shrunken "?"). Chasing every leak is a losing game. Instead, this
//  pass runs LAST, right before ink is composed, and guarantees the outcome
//  the same way font grid-fitting does:
//
//    line 4 (ascender)  — b d f h k l stems, caps, digits, ? !
//    line 3 (x-height)  — letter bodies (owned by ScaleConsensus, untouched)
//    line 2 (baseline)  — owned by snapBaseline/reseat
//    line 1 (descender) — g j p q y tails
//
//  Corrections are LOCAL: only the zone above the body (or below the
//  baseline) of the specific letter is stretched, with a raised-cosine
//  x-falloff so neighboring letters and connectors aren't disturbed. The
//  targets are the user's own learned HandMetrics, so this enforces THEIR
//  proportions — not a font's.
//

import CoreGraphics
import Foundation

enum ZoneFit {

    static let ascenders: Set<Character> = ["b", "d", "f", "h", "k", "l"]
    static let descenders: Set<Character> = ["g", "j", "p", "q", "y"]

    /// Ascender/descender zones start beyond these — the body in between is
    /// never touched, so bowls and arches keep their exact captured shape.
    private static let topHinge: CGFloat = 0.72
    private static let bottomHinge: CGFloat = -0.02

    // MARK: - Words

    /// Enforce the four lines letter by letter inside a resolved word glyph.
    static func enforce(word key: String, glyph: PersonalGlyph) -> PersonalGlyph {
        let m = HandMetrics.active
        let chars = Array(key.lowercased().filter(\.isLetter))
        guard !chars.isEmpty, glyph.width > 0.1,
              chars.contains(where: {
                  ascenders.contains($0) || descenders.contains($0) || $0 == "t"
              }) else { return glyph }

        var cum: [CGFloat] = [0]
        for ch in chars {
            cum.append(cum.last! + max(0.15, StrokeFont.glyph(for: ch).width))
        }
        let total = max(0.3, cum.last!)
        var g = glyph
        for (i, ch) in chars.enumerated() {
            let x0 = glyph.width * cum[i] / total
            let x1 = glyph.width * cum[i + 1] / total
            if ch == "t" {
                stretchTop(&g, x0: x0, x1: x1, target: m.tHeight)
            } else if ascenders.contains(ch) {
                stretchTop(&g, x0: x0, x1: x1, target: m.ascender)
            } else if descenders.contains(ch) {
                stretchBottom(&g, x0: x0, x1: x1, target: m.descender)
            }
        }
        return g
    }

    // MARK: - Single characters

    /// Enforcement for char-composed glyphs. Only classes with a hard line
    /// target are corrected; x-body letters belong to consensus sizing.
    static func enforce(char ch: Character, glyph: PersonalGlyph) -> PersonalGlyph {
        let m = HandMetrics.active
        let l = ch.lowercased().first ?? ch

        if ch.isLowercase, l == "t" {
            var g = glyph
            stretchTop(&g, x0: 0, x1: max(0.1, glyph.width), target: m.tHeight)
            return g
        }
        if ch.isLowercase, ascenders.contains(l) {
            var g = glyph
            stretchTop(&g, x0: 0, x1: max(0.1, glyph.width), target: m.ascender)
            return g
        }
        if ch.isLowercase, descenders.contains(l) {
            var g = glyph
            stretchBottom(&g, x0: 0, x1: max(0.1, glyph.width), target: m.descender)
            return g
        }
        // Full-height glyphs (no separate body zone) — uniform rescale.
        if ch.isUppercase || ch.isNumber || ch == "?" || ch == "!" {
            var top: CGFloat = 0
            for pts in glyph.strokes where pts.count >= 2 {
                for p in pts { top = max(top, p.y) }
            }
            guard top > 0.4 else { return glyph }
            let k = min(1.7, max(0.75, m.ascender / top))
            guard abs(k - 1) > 0.07 else { return glyph }
            return ScaleConsensus.apply(k, to: glyph)
        }
        return glyph
    }

    // MARK: - Zone stretches

    /// Scale the ink ABOVE the hinge so the letter's top lands on `target`.
    /// Everything at or below the hinge (the body) is untouched.
    private static func stretchTop(_ g: inout PersonalGlyph,
                                   x0: CGFloat, x1: CGFloat, target: CGFloat) {
        var top: CGFloat = 0
        for pts in g.strokes where pts.count >= 2 {
            for p in pts where p.x >= x0 && p.x < x1 {
                top = max(top, p.y)
            }
        }
        // Needs a visible stem to work with; can't invent ink from nothing.
        guard top > topHinge + 0.08 else { return }
        var k = (target - topHinge) / (top - topHinge)
        // Upper clamp allows recovering badly flattened stems (legacy data).
        k = min(3.0, max(0.72, k))
        guard abs(k - 1) > 0.06 else { return }
        for si in 0..<g.strokes.count where g.strokes[si].count >= 2 {
            for pi in 0..<g.strokes[si].count {
                let p = g.strokes[si][pi]
                guard p.y > topHinge else { continue }
                let w = xWeight(p.x, x0: x0, x1: x1)
                guard w > 0.01 else { continue }
                let stretched = topHinge + (p.y - topHinge) * k
                g.strokes[si][pi].y += (stretched - p.y) * w
            }
        }
    }

    /// Scale the ink BELOW the baseline so the tail reaches `target`.
    private static func stretchBottom(_ g: inout PersonalGlyph,
                                      x0: CGFloat, x1: CGFloat, target: CGFloat) {
        var bottom: CGFloat = 0
        for pts in g.strokes where pts.count >= 2 {
            for p in pts where p.x >= x0 && p.x < x1 {
                bottom = min(bottom, p.y)
            }
        }
        guard bottom < bottomHinge - 0.08 else { return }
        var k = (target - bottomHinge) / (bottom - bottomHinge)
        k = min(2.4, max(0.72, k))
        guard abs(k - 1) > 0.06 else { return }
        for si in 0..<g.strokes.count where g.strokes[si].count >= 2 {
            for pi in 0..<g.strokes[si].count {
                let p = g.strokes[si][pi]
                guard p.y < bottomHinge else { continue }
                let w = xWeight(p.x, x0: x0, x1: x1)
                guard w > 0.01 else { continue }
                let stretched = bottomHinge + (p.y - bottomHinge) * k
                g.strokes[si][pi].y += (stretched - p.y) * w
            }
        }
    }

    /// 1 inside the letter's window, cosine falloff just outside, 0 beyond —
    /// a swooping tail from the neighbor letter is left in peace.
    private static func xWeight(_ x: CGFloat, x0: CGFloat, x1: CGFloat) -> CGFloat {
        let pad = max(0.06, (x1 - x0) * 0.25)
        if x >= x0, x <= x1 { return 1 }
        if x < x0 - pad || x > x1 + pad { return 0 }
        let d = x < x0 ? (x0 - x) : (x - x1)
        return 0.5 * (1 + cos(.pi * d / pad))
    }
}
