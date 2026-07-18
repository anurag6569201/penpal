//
//  MathInkParser.swift
//  penpal
//
//  Reads handwritten MATH from strokes — not by asking a cloud model, but by:
//
//   1. Segmenting the ink into symbol clusters by geometry.
//   2. Classifying OPERATORS from stroke shape alone — a "/" is a straight
//      diagonal, "=" is two stacked bars, "+" is a cross, "^" is a caret.
//   3. Detecting SUPERSCRIPTS by layout — a smaller raised cluster after a
//      base (x², 2¹⁰) becomes "^" + exponent, the way Apple Notes does.
//   4. Matching remaining clusters against the user's trained math glyphs
//      (Teach it your hand → Math). Falls back to Apple Vision only on
//      digit runs when personal samples aren't enough.
//   5. Re-assembling the expression left to right, and detecting vertical
//      fractions (numerator / bar / denominator) as (a)/(b).
//
//  The result is offered as the top candidate to the calculator; plain
//  Vision sentence readings stay as fallbacks. Anything this parser can't
//  represent aborts rather than guessing — silently dropping a "^" would
//  turn 2^10 into a confidently wrong 210.
//
//  NOTE: PKStroke is a struct, so strokes are tracked by INDEX throughout.
//

import UIKit
import PencilKit

enum MathInkParser {

    // MARK: - Public

    @MainActor
    static func parse(strokes: [PKStroke], traits: UITraitCollection? = nil) async -> String? {
        let usable = strokes.filter { $0.renderBounds.width > 0.5 || $0.renderBounds.height > 0.5 }
        guard usable.count >= 2, usable.count <= 80 else { return nil }
        let unit = symbolUnit(usable)
        guard unit > 4 else { return nil }

        // Vertical fraction? A wide bar with ink above AND below it.
        if let stacked = await parseVerticalFraction(usable, unit: unit, traits: traits) {
            return stacked
        }
        return await parseInline(usable, unit: unit, traits: traits, requireOperator: true)
    }

    /// Left-to-right symbol clusters (same segmentation the parser uses).
    /// Used by correction→auto-train to align edited text to ink.
    static func symbolClusters(in strokes: [PKStroke]) -> [[PKStroke]] {
        let usable = strokes.filter { $0.renderBounds.width > 0.5 || $0.renderBounds.height > 0.5 }
        guard !usable.isEmpty else { return [] }
        let unit = symbolUnit(usable)
        guard unit > 2 else { return usable.map { [$0] } }
        var groups = cluster(usable, unit: unit)
        groups = splitOutSlashes(groups, in: usable, unit: unit)
        groups = splitOutSuperscripts(groups, in: usable, unit: unit)
        return groups.map { idxs in idxs.map { usable[$0] } }
    }

    /// True when stroke geometry looks like a trailing "=" (two stacked bars).
    /// Used to start the math highlight even if OCR dropped the equals mark.
    static func looksLikeEqualsAsk(_ strokes: [PKStroke]) -> Bool {
        let usable = strokes.filter { $0.renderBounds.width > 0.5 || $0.renderBounds.height > 0.5 }
        guard usable.count >= 2 else { return false }
        let unit = symbolUnit(usable)
        guard unit > 4 else { return false }
        let groups = cluster(usable, unit: unit)
        return groups.contains { operatorSymbol(for: $0, in: usable, unit: unit) == "=" }
    }

    /// Layout test used by unit tests — is `cur` a superscript of `base`?
    static func isSuperscriptRect(_ cur: CGRect, relativeTo base: CGRect,
                                  unit: CGFloat) -> Bool {
        guard unit > 1, !cur.isNull, !base.isNull else { return false }
        // Screen y grows downward: superscript sits higher (smaller y).
        let raised = cur.midY < base.midY - unit * 0.18
            && cur.maxY < base.maxY - unit * 0.18
        let compact = cur.height <= max(base.height * 0.9, unit * 0.85)
        let beside = cur.minX < base.maxX + unit * 0.9
            && cur.minX > base.minX - unit * 0.15
        return raised && compact && beside
    }

    /// Top and bottom bar rects of a trailing geometric "=" — for the living
    /// equals animation. Nil when geometry doesn't see stacked bars.
    static func equalsBarRects(in strokes: [PKStroke]) -> (top: CGRect, bottom: CGRect)? {
        let usable = strokes.filter { $0.renderBounds.width > 0.5 || $0.renderBounds.height > 0.5 }
        guard usable.count >= 2 else { return nil }
        let unit = symbolUnit(usable)
        guard unit > 4 else { return nil }
        let groups = cluster(usable, unit: unit)
        guard let group = groups.last(where: {
            operatorSymbol(for: $0, in: usable, unit: unit) == "="
        }), group.count == 2 else { return nil }
        let a = usable[group[0]].renderBounds
        let b = usable[group[1]].renderBounds
        return a.midY < b.midY ? (a, b) : (b, a)
    }

    /// Hairline relationships: base↔superscript and numerator↔denominator.
    /// Points are in stroke/canvas space for filament overlays.
    static func structureLinks(in strokes: [PKStroke]) -> [(CGPoint, CGPoint)] {
        let usable = strokes.filter { $0.renderBounds.width > 0.5 || $0.renderBounds.height > 0.5 }
        guard usable.count >= 2 else { return [] }
        let unit = symbolUnit(usable)
        guard unit > 4 else { return [] }

        var links: [(CGPoint, CGPoint)] = []
        let clusters = symbolClusters(in: usable)
        let rects = clusters.map { group in
            group.reduce(CGRect.null) { $0.union($1.renderBounds) }
        }

        for i in 1..<rects.count {
            let prev = rects[i - 1], cur = rects[i]
            if isSuperscriptRect(cur, relativeTo: prev, unit: unit) {
                links.append((CGPoint(x: prev.maxX - prev.width * 0.15, y: prev.midY),
                              CGPoint(x: cur.minX + cur.width * 0.2, y: cur.midY)))
            }
        }

        // Vertical fraction: wide bar with ink above and below.
        if let barIndex = usable.indices.first(where: { i in
            let b = usable[i].renderBounds
            return isHorizontalBar(usable[i], unit: unit)
                && b.width > max(unit * 1.4, usable.reduce(CGRect.null) {
                    $0.union($1.renderBounds)
                }.width * 0.35)
        }) {
            let bar = usable[barIndex].renderBounds
            let margin = unit * 0.4
            var above = CGRect.null, below = CGRect.null
            for i in usable.indices where i != barIndex {
                let r = usable[i].renderBounds
                let spans = r.midX > bar.minX - margin && r.midX < bar.maxX + margin
                guard spans else { continue }
                if r.midY < bar.minY { above = above.union(r) }
                else if r.midY > bar.maxY { below = below.union(r) }
            }
            if !above.isNull, !below.isNull {
                links.append((CGPoint(x: above.midX, y: above.maxY),
                              CGPoint(x: bar.midX, y: bar.midY)))
                links.append((CGPoint(x: bar.midX, y: bar.midY),
                              CGPoint(x: below.midX, y: below.minY)))
            }
        }
        return links
    }

    /// 0…1 intensity of the "=" ask — Pencil force when available, else stroke
    /// width as a stand-in. Hard presses drive "show work" ghost steps.
    static func equalsAskIntensity(in strokes: [PKStroke]) -> CGFloat {
        let usable = strokes.filter { $0.renderBounds.width > 0.5 || $0.renderBounds.height > 0.5 }
        guard usable.count >= 2 else { return 0.35 }
        let unit = symbolUnit(usable)
        guard unit > 4 else { return 0.35 }
        let groups = cluster(usable, unit: unit)
        let equalsGroup = groups.last(where: {
            operatorSymbol(for: $0, in: usable, unit: unit) == "="
        }) ?? groups.suffix(1).flatMap { $0 }

        var forces: [CGFloat] = []
        var widths: [CGFloat] = []
        for idx in equalsGroup {
            for p in usable[idx].path.interpolatedPoints(by: .distance(1.5)) {
                forces.append(p.force)
                widths.append(p.size.width)
            }
        }
        guard !forces.isEmpty else { return 0.35 }

        let maxF = forces.max() ?? 0
        let minF = forces.min() ?? 0
        let meanF = forces.reduce(0, +) / CGFloat(forces.count)
        // Unsupported force is often 0 or a flat 1 — fall back to width.
        let forceUseful = maxF > 0.05 && (maxF - minF) > 0.04
        if forceUseful {
            return min(1, max(0, meanF * 0.65 + maxF * 0.35))
        }
        let meanW = widths.reduce(0, +) / CGFloat(widths.count)
        // Typical pencil widths land ~2–6; map into 0…1.
        return min(1, max(0, (meanW - 1.2) / 5.0))
    }

    // MARK: - Inline expressions (everything on one baseline)

    @MainActor
    private static func parseInline(_ strokes: [PKStroke], unit: CGFloat,
                                    traits: UITraitCollection?,
                                    requireOperator: Bool) async -> String? {
        var groups = cluster(strokes, unit: unit)
        groups = splitOutSlashes(groups, in: strokes, unit: unit)
        groups = splitOutSuperscripts(groups, in: strokes, unit: unit)
        guard !groups.isEmpty, groups.count <= 40 else { return nil }

        var out = ""
        var sawOperator = false
        var sawDigit = false
        var pendingGroups: [[Int]] = []
        /// Last base symbol bounds — superscripts are measured against this.
        var lastBaseBounds: CGRect?
        /// After "^" (caret or first superscript), keep collecting raised digits.
        var inExponent = false

        func flushPending() async -> Bool {
            guard !pendingGroups.isEmpty else { return true }
            let batch = pendingGroups
            pendingGroups.removeAll()

            if let personal = MathGlyphMatcher.matchDigitRun(groups: batch, in: strokes,
                                                             unit: unit) {
                if personal.contains(where: \.isNumber) { sawDigit = true }
                out += personal
                return true
            }

            let runStrokes = batch.flatMap { group in group.map { strokes[$0] } }
            guard let text = await recognizeRun(runStrokes, traits: traits) else { return false }
            if text.contains(where: \.isNumber) { sawDigit = true }
            out += text
            return true
        }

        func noteBase(_ group: [Int]) {
            lastBaseBounds = bounds(of: group, in: strokes)
            inExponent = false
        }

        for group in groups {
            let gBounds = bounds(of: group, in: strokes)

            // Raised cluster after a base → power: x² / 2¹⁰ → insert "^".
            if let base = lastBaseBounds,
               isSuperscriptRect(gBounds, relativeTo: base, unit: unit) {
                guard await flushPending() else { return nil }
                if !inExponent {
                    out += "^"
                    sawOperator = true
                    inExponent = true
                }
                pendingGroups.append(group)
                continue
            }

            if let symbol = operatorSymbol(for: group, in: strokes, unit: unit) {
                guard await flushPending() else { return nil }
                if symbol != "=" { sawOperator = true }
                out += symbol
                if symbol == "^" {
                    inExponent = true
                } else if symbol == "=" || symbol == "+" || symbol == "-"
                            || symbol == "*" || symbol == "/" {
                    lastBaseBounds = gBounds
                    inExponent = false
                } else {
                    noteBase(group)
                }
                continue
            }

            // Personal glyph match — digits, ^, !, √, ×, x, y, etc.
            let clusterStrokes = group.map { strokes[$0] }
            if let ch = MathGlyphMatcher.matchSymbol(strokes: clusterStrokes, unit: unit) {
                let token = MathGlyphMatcher.ascii(for: ch)
                if token == "^" {
                    guard await flushPending() else { return nil }
                    out += "^"
                    sawOperator = true
                    inExponent = true
                    continue
                }
                if MathGlyphMatcher.isNumericToken(token) {
                    if let last = pendingGroups.last {
                        let gap = gBounds.minX - bounds(of: last, in: strokes).maxX
                        if gap > unit * 0.75 {
                            guard await flushPending() else { return nil }
                        }
                    }
                    pendingGroups.append(group)
                    if !inExponent { lastBaseBounds = gBounds }
                    continue
                }
                guard await flushPending() else { return nil }
                if token.contains(where: \.isNumber) { sawDigit = true }
                if token != "=" { sawOperator = true }
                out += token
                noteBase(group)
                continue
            }

            // Vision digit run.
            if inExponent {
                pendingGroups.append(group)
                continue
            }
            if let last = pendingGroups.last {
                let gap = gBounds.minX - bounds(of: last, in: strokes).maxX
                if gap > unit * 0.75 {
                    guard await flushPending() else { return nil }
                }
            }
            pendingGroups.append(group)
            lastBaseBounds = gBounds
        }
        guard await flushPending() else { return nil }

        let cleaned = out.trimmingCharacters(in: .whitespaces)
        guard sawDigit, cleaned.count >= 2 else { return nil }
        if requireOperator && !sawOperator { return nil }
        return cleaned
    }

    // MARK: - Clustering (indices into the stroke array)

    private static func symbolUnit(_ strokes: [PKStroke]) -> CGFloat {
        let heights = strokes.map { $0.renderBounds.height }.filter { $0 > 2 }.sorted()
        guard !heights.isEmpty else { return 0 }
        return heights[min(heights.count - 1, Int(Double(heights.count) * 0.7))]
    }

    private static func bounds(of group: [Int], in strokes: [PKStroke]) -> CGRect {
        group.reduce(CGRect.null) { $0.union(strokes[$1].renderBounds) }
    }

    private static func cluster(_ strokes: [PKStroke], unit: CGFloat) -> [[Int]] {
        let order = strokes.indices.sorted {
            strokes[$0].renderBounds.minX < strokes[$1].renderBounds.minX
        }
        var groups: [[Int]] = []
        var groupBounds: [CGRect] = []
        let gapLimit = unit * 0.22

        for index in order {
            let b = strokes[index].renderBounds
            if let last = groupBounds.last {
                let overlap = min(last.maxX, b.maxX) - max(last.minX, b.minX)
                let gap = b.minX - last.maxX
                if overlap > min(last.width, b.width) * 0.35 || gap < gapLimit {
                    groups[groups.count - 1].append(index)
                    groupBounds[groupBounds.count - 1] = last.union(b)
                    continue
                }
            }
            groups.append([index])
            groupBounds.append(b)
        }
        return groups
    }

    private static func splitOutSlashes(_ groups: [[Int]], in strokes: [PKStroke],
                                        unit: CGFloat) -> [[Int]] {
        var out: [[Int]] = []
        for group in groups {
            guard group.count > 1,
                  let slash = group.first(where: { isSlash(strokes[$0], unit: unit) }) else {
                out.append(group)
                continue
            }
            let mid = strokes[slash].renderBounds.midX
            let left = group.filter { $0 != slash && strokes[$0].renderBounds.midX < mid }
            let right = group.filter { $0 != slash && strokes[$0].renderBounds.midX >= mid }
            if !left.isEmpty { out.append(left) }
            out.append([slash])
            if !right.isEmpty { out.append(right) }
        }
        return out
    }

    /// Peel raised small strokes off a merged base+superscript cluster.
    private static func splitOutSuperscripts(_ groups: [[Int]], in strokes: [PKStroke],
                                             unit: CGFloat) -> [[Int]] {
        var out: [[Int]] = []
        for group in groups {
            guard group.count > 1 else {
                out.append(group)
                continue
            }
            let tall = group.filter { strokes[$0].renderBounds.height >= unit * 0.55 }
            let short = group.filter { strokes[$0].renderBounds.height < unit * 0.55 }
            guard !tall.isEmpty, !short.isEmpty else {
                out.append(group)
                continue
            }
            let baseBounds = bounds(of: tall, in: strokes)
            var base = tall
            var raised: [Int] = []
            for idx in short {
                let b = strokes[idx].renderBounds
                if isSuperscriptRect(b, relativeTo: baseBounds, unit: unit) {
                    raised.append(idx)
                } else {
                    base.append(idx)
                }
            }
            guard !raised.isEmpty else {
                out.append(group)
                continue
            }
            let baseSorted = base.sorted {
                strokes[$0].renderBounds.minX < strokes[$1].renderBounds.minX
            }
            let raisedSorted = raised.sorted {
                strokes[$0].renderBounds.minX < strokes[$1].renderBounds.minX
            }
            out.append(baseSorted)
            out.append(raisedSorted)
        }
        return out
    }

    // MARK: - Geometric operator classification

    private static func operatorSymbol(for group: [Int], in strokes: [PKStroke],
                                       unit: CGFloat) -> String? {
        let b = bounds(of: group, in: strokes)

        if group.count == 1, b.width < unit * 0.30, b.height < unit * 0.30 {
            return "."
        }
        if group.count == 2,
           group.allSatisfy({ isHorizontalBar(strokes[$0], unit: unit) }) {
            let a = strokes[group[0]].renderBounds
            let d = strokes[group[1]].renderBounds
            if abs(a.midY - d.midY) > unit * 0.12,
               min(a.width, d.width) > max(a.width, d.width) * 0.45 {
                return "="
            }
        }
        if isCaret(group, in: strokes, unit: unit) { return "^" }
        if group.count == 2, group.allSatisfy({ isStraight(strokes[$0]) }) {
            let s1 = angle(of: strokes[group[0]])
            let s2 = angle(of: strokes[group[1]])
            if min(abs(s1), abs(s2)) < 0.35, max(abs(s1), abs(s2)) > 1.2 { return "+" }
            if s1 * s2 < 0, abs(s1) > 0.45, abs(s2) > 0.45 { return "*" }
        }
        if group.count == 1 {
            let s = strokes[group[0]]
            if isSlash(s, unit: unit) { return "/" }
            if isHorizontalBar(s, unit: unit), b.width > unit * 0.35 { return "-" }
        }
        return nil
    }

    /// Caret "^": peak near top-center with both ends lower.
    private static func isCaret(_ group: [Int], in strokes: [PKStroke],
                                unit: CGFloat) -> Bool {
        let b = bounds(of: group, in: strokes)
        guard b.height > unit * 0.25, b.height < unit * 1.1,
              b.width > unit * 0.2, b.width < unit * 1.3 else { return false }

        if group.count == 1 {
            let pts = points(strokes[group[0]])
            guard pts.count >= 4 else { return false }
            guard let peak = pts.min(by: { $0.y < $1.y }) else { return false }
            let first = pts[0], last = pts[pts.count - 1]
            let peakCentered = abs(peak.x - b.midX) < b.width * 0.35
            let endsLower = first.y > peak.y + b.height * 0.35
                && last.y > peak.y + b.height * 0.35
            let endsApart = abs(first.x - last.x) > b.width * 0.45
            return peakCentered && endsLower && endsApart
        }

        if group.count == 2, group.allSatisfy({ isStraight(strokes[$0]) }) {
            let a0 = angle(of: strokes[group[0]])
            let a1 = angle(of: strokes[group[1]])
            guard a0 * a1 < 0, abs(a0) > 0.35, abs(a1) > 0.35,
                  abs(a0) < 1.35, abs(a1) < 1.35 else { return false }
            let t0 = strokes[group[0]].renderBounds
            let t1 = strokes[group[1]].renderBounds
            let topsClose = abs(t0.minY - t1.minY) < unit * 0.35
            let meetHigh = min(t0.minY, t1.minY) < b.midY - b.height * 0.1
            let compact = b.height < unit * 0.95
            return topsClose && meetHigh && compact
        }
        return false
    }

    private static func points(_ s: PKStroke) -> [CGPoint] {
        Array(s.path.interpolatedPoints(by: .distance(max(1.5, s.renderBounds.height / 12))))
            .map(\.location)
    }

    private static func isStraight(_ s: PKStroke) -> Bool {
        let pts = points(s)
        guard pts.count >= 2, let first = pts.first, let last = pts.last else { return false }
        var length: CGFloat = 0
        for i in 1..<pts.count {
            length += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
        }
        let direct = hypot(last.x - first.x, last.y - first.y)
        guard direct > 1 else { return false }
        return length / direct < 1.22
    }

    private static func angle(of s: PKStroke) -> CGFloat {
        let pts = points(s)
        guard let first = pts.first, let last = pts.last else { return 0 }
        let dx = last.x - first.x
        let dy = -(last.y - first.y)
        guard abs(dx) > 0.001 || abs(dy) > 0.001 else { return 0 }
        var a = atan2(dy, dx)
        if a < 0 { a += .pi }
        if a > .pi / 2 { a -= .pi }
        return a
    }

    private static func isHorizontalBar(_ s: PKStroke, unit: CGFloat) -> Bool {
        let b = s.renderBounds
        return isStraight(s) && b.width > b.height * 2.6 && b.height < unit * 0.45
    }

    private static func isSlash(_ s: PKStroke, unit: CGFloat) -> Bool {
        let b = s.renderBounds
        guard isStraight(s), b.height > unit * 0.55, b.width < b.height * 1.15 else {
            return false
        }
        let a = angle(of: s)
        return a > 0.6 && a < 1.45
    }

    // MARK: - Vision digit / exponent runs

    @MainActor
    private static func recognizeRun(_ strokes: [PKStroke],
                                     traits: UITraitCollection?) async -> String? {
        let candidates = await InkRecognizer.recognizeCandidates(strokes: strokes,
                                                                 traits: traits)
        for raw in candidates {
            if let cleaned = digitize(raw) { return cleaned }
        }
        return nil
    }

    private static func digitize(_ raw: String) -> String? {
        let map: [Character: Character] = [
            "S": "5", "s": "5", "O": "0", "o": "0", "Q": "0", "D": "0",
            "I": "1", "i": "1", "l": "1", "|": "1", "L": "1",
            "Z": "2", "z": "2", "G": "6", "b": "6", "g": "9", "q": "9",
            "B": "8", "A": "4", "T": "7", "J": "7",
        ]
        var out = ""
        for ch in raw {
            if ch.isNumber || ch == "." {
                out.append(ch)
            } else if ch == "²" {
                out += "^2"
            } else if ch == "³" {
                out += "^3"
            } else if ch == "^" {
                out.append("^")
            } else if let fixed = map[ch] {
                out.append(fixed)
            } else if ch == " " || ch == "," {
                continue
            } else {
                return nil
            }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Vertical fractions

    @MainActor
    private static func parseVerticalFraction(_ strokes: [PKStroke], unit: CGFloat,
                                              traits: UITraitCollection?) async -> String? {
        let all = strokes.indices.reduce(CGRect.null) { $0.union(strokes[$1].renderBounds) }
        guard let barIndex = strokes.indices.first(where: { i in
            let b = strokes[i].renderBounds
            return isHorizontalBar(strokes[i], unit: unit)
                && b.width > max(unit * 1.4, all.width * 0.35)
        }) else { return nil }

        let bar = strokes[barIndex].renderBounds
        let margin = unit * 0.4
        func spansBar(_ r: CGRect) -> Bool {
            r.midX > bar.minX - margin && r.midX < bar.maxX + margin
        }

        var above: [PKStroke] = [], below: [PKStroke] = []
        var left: [PKStroke] = [], right: [PKStroke] = []
        for i in strokes.indices where i != barIndex {
            let r = strokes[i].renderBounds
            if spansBar(r) {
                if r.midY < bar.minY { above.append(strokes[i]) }
                else if r.midY > bar.maxY { below.append(strokes[i]) }
            } else if r.maxX <= bar.minX {
                left.append(strokes[i])
            } else if r.minX >= bar.maxX {
                right.append(strokes[i])
            }
        }
        guard !above.isEmpty, !below.isEmpty else { return nil }
        guard let numerator = await subExpression(above, traits: traits),
              let denominator = await subExpression(below, traits: traits) else { return nil }

        var expression = "(\(numerator))/(\(denominator))"
        if !left.isEmpty {
            guard let lead = await subExpression(left, traits: traits) else { return nil }
            expression = lead + expression
        }
        if !right.isEmpty {
            guard let tail = await subExpression(right, traits: traits) else { return nil }
            expression += tail
        }
        return expression
    }

    @MainActor
    private static func subExpression(_ strokes: [PKStroke],
                                      traits: UITraitCollection?) async -> String? {
        guard !strokes.isEmpty else { return nil }
        let unit = symbolUnit(strokes)
        guard unit > 2 else { return nil }
        return await parseInline(strokes, unit: unit, traits: traits, requireOperator: false)
    }
}
