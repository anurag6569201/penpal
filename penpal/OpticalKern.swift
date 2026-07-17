//
//  OpticalKern.swift
//  penpal
//
//  Classic optical pair kerning, the way font engines auto-kern: compare the
//  RIGHT edge profile of the previous glyph with the LEFT edge profile of the
//  next glyph across shared height bands, and tighten/loosen the advance so
//  the visual ink gap is even. A constant letterSpacing can't do this —
//  real hands tuck "r·y" much closer than "d·b".
//
//  Works in unit space (baseline 0, x-height 1). Uses the user's trained
//  letter when available, else the built-in stroke font geometry, so kerning
//  stays coherent even for mixed trained/fallback pairs.
//

import Foundation
import CoreGraphics

enum OpticalKern {

    private static var cache: [String: CGFloat] = [:]

    private static let bins = 12
    private static let yLo: CGFloat = -0.45
    private static let yHi: CGFloat = 1.55
    /// Target visual ink gap between letters, in x-heights.
    private static let targetGap: CGFloat = 0.12

    /// Call when letter training data changes.
    static func invalidateAll() { cache.removeAll() }

    /// Advance adjustment in x-height units (negative = tighten).
    static func kern(_ a: Character, _ b: Character) -> CGFloat {
        guard a.isLetter || a.isNumber, b.isLetter || b.isNumber else { return 0 }
        let key = String([a, b])
        if let hit = cache[key] { return hit }
        let value = compute(a, b)
        cache[key] = value
        return value
    }

    private static func compute(_ a: Character, _ b: Character) -> CGFloat {
        guard let inkA = unitInk(a), let inkB = unitInk(b) else { return 0 }

        var rightA = [CGFloat?](repeating: nil, count: bins)
        var leftB = [CGFloat?](repeating: nil, count: bins)

        func bin(_ y: CGFloat) -> Int? {
            let t = (y - yLo) / (yHi - yLo)
            guard t >= 0, t < 1 else { return nil }
            return Int(t * CGFloat(bins))
        }
        for p in inkA.points {
            guard let i = bin(p.y) else { continue }
            rightA[i] = max(rightA[i] ?? -.greatestFiniteMagnitude, p.x)
        }
        for p in inkB.points {
            guard let i = bin(p.y) else { continue }
            leftB[i] = min(leftB[i] ?? .greatestFiniteMagnitude, p.x)
        }

        // Minimum profile gap over bands where both glyphs have ink.
        var minGap = CGFloat.greatestFiniteMagnitude
        for i in 0..<bins {
            guard let r = rightA[i], let l = leftB[i] else { continue }
            minGap = min(minGap, (inkA.width - r) + l)
        }
        guard minGap < .greatestFiniteMagnitude else { return 0 }

        // Placed gap will be letterSpacing + minGap; kern the difference.
        let kern = targetGap - (StrokeFont.letterSpacing + minGap)
        return min(0.06, max(-0.14, kern))
    }

    /// Representative unit-space ink for a character.
    private static func unitInk(_ ch: Character) -> (width: CGFloat, points: [CGPoint])? {
        // Prefer the user's trained shape.
        let variants = PersonalFontStore.shared.variants(forChar: ch)
        if let g = variants.last {
            let pts = g.strokes.flatMap { $0 }
            guard !pts.isEmpty else { return nil }
            return (max(0.05, g.width), pts)
        }
        // Fall back to built-in glyph geometry.
        let g = StrokeFont.glyph(for: ch)
        var pts: [CGPoint] = []
        for element in g.strokes {
            switch element {
            case .poly(let ctrl):
                pts.append(contentsOf: ctrl)
            case .arc(let cx, let cy, let rx, let ry, let a0, let a1):
                let n = 12
                for i in 0...n {
                    let ang = (a0 + (a1 - a0) * CGFloat(i) / CGFloat(n)) * .pi / 180
                    pts.append(CGPoint(x: cx + rx * cos(ang), y: cy + ry * sin(ang)))
                }
            case .dot(let x, let y):
                pts.append(CGPoint(x: x, y: y))
            }
        }
        guard !pts.isEmpty else { return nil }
        return (max(0.05, g.width), pts)
    }
}
