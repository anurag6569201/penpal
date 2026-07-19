//
//  InkHand.swift
//  penpal
//
//  Next-level handwriting coherence — NOT a crude 70/30 mix of "real" vs
//  "fake" words (that reads as patched). Three ideas instead:
//
//  1. Fragment bank — slice trained words into 2–4 letter n-grams of REAL ink.
//     Unseen words are stitched from those fragments (concatenative synthesis).
//
//  2. Sentence unity — one latent style code for the whole reply. Every word
//     (even perfect bank hits) gets a light morph toward it, so the line shares
//     one hand-energy and nothing looks surgically pasted next to synth ink.
//
//  3. Hand-aware replies — the system prefers vocabulary you actually trained,
//     so most of the page IS your ink without looking like a ransom note.
//

import Foundation
import CoreGraphics

// MARK: - Sentence unity

enum WordInkSource: String {
    case exact       // whole trained word
    case fragments   // stitched from real n-grams
    case vae         // letter pack + VAE morph
    case letters     // raw letter glyphs
}

final class InkUnity {

    static let shared = InkUnity()

    /// Shared latent for the current reply line.
    private(set) var sentenceZ: [Double]?

    func beginSentence() {
        sentenceZ = StrokeVAE.shared.sampleSessionLatent()
    }

    func endSentence() {
        sentenceZ = nil
    }

    /// Strength by source — exact words keep identity, still pick up session
    /// vibe. Kept LOW across the board: strong morphs polygonize curves and
    /// read as robotic. Real ink barely needs unifying — sizing consensus
    /// already does the heavy lifting.
    func strength(for source: WordInkSource) -> CGFloat {
        switch source {
        case .exact:     return 0.04   // preserve captured identity and timing
        case .fragments: return 0.20
        case .vae:       return 0.16   // already morphed heavily
        case .letters:   return 0.24
        }
    }

    func unify(_ glyph: PersonalGlyph, source: WordInkSource) -> PersonalGlyph {
        guard let z = sentenceZ else { return glyph }
        return StrokeVAE.shared.morphToward(glyph, targetZ: z, strength: strength(for: source))
            ?? glyph
    }
}

// MARK: - Fragment bank (concatenative ink)

final class FragmentBank {

    static let shared = FragmentBank()
    static let maxVariants = 3
    /// 1-grams too: a letter cropped from inside a trained word is REAL
    /// in-flow ink — the right size and energy, unlike isolated char training.
    private static let ngramRange = 1...4

    /// A real inter-letter connector cropped from a captured word: the ink
    /// that crosses a letter boundary, normalized to start at the origin.
    /// Users never train these — every trained word donates its own.
    struct ConnectorSample: Codable {
        var points: [CGPoint]
        var widths: [CGFloat]
    }

    private var fragments: [String: [PersonalGlyph]] = [:]
    /// Keyed by letter pair ("ay"), plus "*" as the any-pair fallback.
    private var connectors: [String: [ConnectorSample]] = [:]
    private struct Persist: Codable {
        // v4: width-prior slice boundaries (uniform-sliced fragments discarded).
        // v5: adds harvested connectors (optional — v4 files still load).
        // v6: point-level cropping — pre-v6 fragments harvested from cursive
        //     words carry their donor word's ENTIRE ink (the "theat" bug) and
        //     must be discarded; bootstrap re-harvests from the word bank.
        // v7: boundary hygiene — v6 fragments can still carry neighbor-letter
        //     slivers and edge dots at their window edges (stray marks in
        //     stitched words); re-harvest with the edge filters.
        // v8: ink-refined slice boundaries — priors alone land mid-letter on
        //     cursive words; boundaries now snap to thin connector points.
        var version: Int? = 8
        var fragments: [String: [PersonalGlyph]]
        var connectors: [String: [ConnectorSample]]? = nil
    }

    private var fileURL: URL {
        HandProfiles.fileURL("ink_fragments.json")   // PEN-20
    }

    var fragmentCount: Int { fragments.values.reduce(0) { $0 + $1.count } }
    var keyCount: Int { fragments.count }

    init() { load() }

    /// Carve n-grams out of a captured word by spatial letter slices.
    /// Slice boundaries follow per-letter width priors ("m" is ~4× "i"), not
    /// uniform division — uniform slicing cut through letters and every
    /// downstream stitch inherited the damage.
    func harvest(word: String, glyph: PersonalGlyph) {
        let key = word.lowercased().filter(\.isLetter)
        guard key.count >= 2, glyph.width > 0.1 else { return }
        let chars = Array(key)
        let n = chars.count

        // Cumulative width prior per boundary, scaled to the captured width —
        // then REFINED against the actual ink: a prior that lands mid-letter
        // poisons every fragment cut with it.
        var cum: [CGFloat] = [0]
        for ch in chars {
            cum.append(cum.last! + max(0.15, StrokeFont.glyph(for: ch).width))
        }
        let total = max(0.3, cum.last!)
        let priors = (0...n).map { glyph.width * cum[$0] / total }
        let bounds = Self.refineBoundaries(priors: priors, glyph: glyph)
        func boundary(_ i: Int) -> CGFloat { bounds[i] }

        for len in Self.ngramRange {
            guard len <= n else { continue }
            for start in 0...(n - len) {
                let slice = String(chars[start..<(start + len)])
                let x0 = boundary(start)
                let x1 = boundary(start + len)
                if let piece = Self.crop(glyph, fromX: x0, toX: x1) {
                    store(GlyphAlign.reseat(piece), for: slice)
                }
            }
        }
        harvestConnectors(chars: chars, glyph: glyph, boundary: boundary)
        save()
    }

    /// Width priors give only APPROXIMATE letter boundaries, and on a cursive
    /// word a boundary landing mid-letter means half an "o" travels with the
    /// "v" in every fragment cut from it. Refine each internal boundary to
    /// the nearest "thin" x — where a vertical line cuts the ink at most
    /// once (the connector between letters, or a pen lift) — searching ±35%
    /// of the narrower adjacent letter's width. This is classic cursive
    /// ligature detection; endpoints stay fixed and order stays monotone.
    static func refineBoundaries(priors: [CGFloat], glyph: PersonalGlyph) -> [CGFloat] {
        guard priors.count >= 3 else { return priors }
        var out = priors
        let segments: [(CGPoint, CGPoint)] = glyph.strokes.flatMap { pts -> [(CGPoint, CGPoint)] in
            guard pts.count >= 2 else { return [] }
            return (1..<pts.count).map { (pts[$0 - 1], pts[$0]) }
        }
        guard !segments.isEmpty else { return priors }

        for i in 1..<(priors.count - 1) {
            let leftW = priors[i] - priors[i - 1]
            let rightW = priors[i + 1] - priors[i]
            let radius = min(leftW, rightW) * 0.35
            guard radius > 0.02 else { continue }
            var bestX = priors[i]
            var bestScore = CGFloat.greatestFiniteMagnitude
            let steps = 16
            for s in 0...steps {
                let x = priors[i] - radius + 2 * radius * CGFloat(s) / CGFloat(steps)
                var crossings = 0
                var yLo = CGFloat.greatestFiniteMagnitude
                var yHi = -CGFloat.greatestFiniteMagnitude
                for (a, b) in segments where (a.x < x) != (b.x < x) {
                    crossings += 1
                    let t = (x - a.x) / (b.x - a.x)
                    let y = a.y + (b.y - a.y) * t
                    yLo = min(yLo, y)
                    yHi = max(yHi, y)
                }
                // 0 crossings = a pen lift (perfect cut); 1 = a clean
                // connector; more = we're slicing through a letter's loops.
                let spread = crossings > 0 ? max(0, yHi - yLo) : 0
                let score = CGFloat(crossings) + spread * 0.8
                    + abs(x - priors[i]) / max(radius, 0.01) * 0.25
                if score < bestScore {
                    bestScore = score
                    bestX = x
                }
            }
            out[i] = bestX
        }
        for i in 1..<out.count where out[i] < out[i - 1] + 0.05 {
            out[i] = out[i - 1] + 0.05
        }
        return out
    }

    /// Crop the real ink that crosses each internal letter boundary — that IS
    /// the user's connector for that letter pair.
    private func harvestConnectors(chars: [Character], glyph: PersonalGlyph,
                                   boundary: (Int) -> CGFloat) {
        for i in 1..<chars.count {
            let b = boundary(i)
            for (si, pts) in glyph.strokes.enumerated() where pts.count >= 4 {
                // Rightward crossing of the boundary within one pen-down stroke.
                guard let cross = (1..<pts.count).first(where: {
                    pts[$0 - 1].x <= b && pts[$0].x > b
                }) else { continue }
                var lo = cross - 1, hi = cross
                while lo > 0, abs(pts[lo - 1].x - b) < 0.22 { lo -= 1 }
                while hi < pts.count - 1, abs(pts[hi + 1].x - b) < 0.22 { hi += 1 }
                guard hi - lo >= 2 else { break }
                let window = Array(pts[lo...hi])
                // Connectors live in the writing band — skip t-bars and flourishes.
                guard window.allSatisfy({ $0.y > -0.4 && $0.y < 1.3 }) else { break }
                let origin = window[0]
                let normalized = window.map {
                    CGPoint(x: $0.x - origin.x, y: $0.y - origin.y)
                }
                let ws: [CGFloat]
                if let stws = glyph.widths, si < stws.count, stws[si].count == pts.count {
                    ws = Array(stws[si][lo...hi])
                } else {
                    ws = Array(repeating: 0.1, count: normalized.count)
                }
                let sample = ConnectorSample(points: normalized, widths: ws)
                storeConnector(sample, for: "\(chars[i - 1])\(chars[i])", cap: 3)
                // Height-class pool: an o→x joiner can stand in for any
                // high-exit pair we never saw ("on" teaches "om").
                if let first = window.first, let last = window.last {
                    storeConnector(sample, for: LigatureEngine.classKey(
                        exitUnitY: first.y, entryUnitY: last.y), cap: 5)
                }
                storeConnector(sample, for: "*", cap: 8)
                break
            }
        }
    }

    private func storeConnector(_ sample: ConnectorSample, for key: String, cap: Int) {
        var list = connectors[key] ?? []
        list.append(sample)
        if list.count > cap { list.removeFirst(list.count - cap) }
        connectors[key] = list
    }

    /// Best harvested connector: exact pair → same height class → any pair.
    func connector(pair: String, classKey: String) -> ConnectorSample? {
        ((connectors[pair] ?? connectors[classKey]) ?? connectors["*"])?.randomElement()
    }

    /// A harvested connector for this letter pair (or class/any-pair pools),
    /// similarity-transformed so its endpoints land exactly on p0 → p1.
    /// Nil when nothing harvested fits — caller falls back to Hermite.
    private func realConnector(pair: String, classKey: String,
                               from p0: CGPoint, to p1: CGPoint) -> (points: [CGPoint], widths: [CGFloat])? {
        guard let sample = connector(pair: pair, classKey: classKey),
              sample.points.count >= 3,
              let s0 = sample.points.first, let s1 = sample.points.last else { return nil }
        let sv = CGPoint(x: s1.x - s0.x, y: s1.y - s0.y)
        let tv = CGPoint(x: p1.x - p0.x, y: p1.y - p0.y)
        let sLen = hypot(sv.x, sv.y)
        let tLen = hypot(tv.x, tv.y)
        guard sLen > 0.03, tLen > 0.02 else { return nil }
        let scale = tLen / sLen
        // A connector stretched or spun too far stops looking like the hand —
        // an 80°-rotated undercurve is just a diagonal stick.
        guard scale > 0.55, scale < 1.8 else { return nil }
        let rot = atan2(tv.y, tv.x) - atan2(sv.y, sv.x)
        guard abs(rot) < 0.6 else { return nil }
        let cosR = cos(rot) * scale
        let sinR = sin(rot) * scale
        let points = sample.points.map { p -> CGPoint in
            let dx = p.x - s0.x, dy = p.y - s0.y
            return CGPoint(x: p0.x + dx * cosR - dy * sinR,
                           y: p0.y + dx * sinR + dy * cosR)
        }
        return (points, sample.widths)
    }

    func bootstrap(words: [String: [PersonalGlyph]]) {
        // Re-harvest when either bank is missing (connectors arrived in v5 —
        // existing v4 fragment files have none yet).
        guard fragments.isEmpty || (connectors.isEmpty && !words.isEmpty) else { return }
        for (w, list) in words {
            for g in list { harvest(word: w, glyph: g) }
        }
    }

    func rebuild(words: [String: [PersonalGlyph]]) {
        fragments.removeAll(keepingCapacity: true)
        connectors.removeAll(keepingCapacity: true)
        for (word, variants) in words {
            for glyph in variants { harvest(word: word, glyph: glyph) }
        }
        save()
    }

    /// Dynamic-programming cover. It favors longer, high-quality real fragments
    /// while penalizing visible geometry/pressure seams.
    func stitch(_ word: String, connectedness: CGFloat) -> PersonalGlyph? {
        let key = word.lowercased().filter(\.isLetter)
        guard key.count >= 2 else { return nil }
        let chars = Array(key)
        struct Path {
            var score: CGFloat
            var parts: [PersonalGlyph]
            var subs: [String]
            var seams: [String]
        }
        var best = Array<Path?>(repeating: nil, count: chars.count + 1)
        best[0] = Path(score: 0, parts: [], subs: [], seams: [])

        for i in 0..<chars.count {
            guard let prefix = best[i] else { continue }
            for len in Self.ngramRange where i + len <= chars.count {
                let sub = String(chars[i..<(i + len)])
                guard let variants = fragments[sub] else { continue }
                for glyph in variants where PersonalFontStore.isValid(glyph) {
                    var score = prefix.score + CGFloat(len * len)
                        + (glyph.quality ?? 0.6)
                    if let previous = prefix.parts.last {
                        score -= Self.seamCost(previous, glyph) * 1.8
                    }
                    if best[i + len] == nil || score > best[i + len]!.score {
                        let seam = i > 0 ? ["\(chars[i - 1])\(chars[i])"] : []
                        best[i + len] = Path(score: score,
                                             parts: prefix.parts + [glyph],
                                             subs: prefix.subs + [sub],
                                             seams: prefix.seams + seam)
                    }
                }
            }
        }
        guard let path = best[chars.count], !path.parts.isEmpty else { return nil }
        let result: PersonalGlyph?
        if path.parts.count == 1 {
            result = path.parts[0]
        } else {
            result = join(path.parts, subs: path.subs, seams: path.seams,
                          connectedness: connectedness)
        }
        // SANITY GATE: a stitch whose width is far off the word's prior width
        // almost certainly carries donor ink or dropped letters. Rendering
        // the WRONG letters in the user's own hand is the worst failure this
        // system has — falling through to VAE/letters is always better.
        guard let g = result else { return nil }
        let expected = chars.reduce(CGFloat(0)) {
            $0 + max(0.15, StrokeFont.glyph(for: $1).width)
        }
        guard g.width < expected * 1.55, g.width > expected * 0.45 else { return nil }
        return g
    }

    private static func seamCost(_ a: PersonalGlyph, _ b: PersonalGlyph) -> CGFloat {
        guard let tail = a.strokes.last(where: { $0.count > 1 })?.last,
              let head = b.strokes.first(where: { $0.count > 1 })?.first else { return 0.4 }
        let vertical = abs(tail.y - head.y)
        let aw = a.widths?.last?.last ?? 0.12
        let bw = b.widths?.first?.first ?? 0.12
        return vertical + abs(aw - bw) * 1.5
    }

    private func join(_ parts: [PersonalGlyph], subs: [String], seams: [String],
                      connectedness: CGFloat) -> PersonalGlyph? {
        // SIZE UNIFICATION. Fragments arrive at their donor words' scales, so
        // a piece cut from a large-written donor renders as a mid-word size
        // jump — reads as a stray capital ("loVely"). Pull every measurable
        // part toward the parts' median body height before packing. Parts
        // whose letters have no x-height body (an "ll" fragment is all stem)
        // are left alone: their stem height IS their size and comparing it
        // to bowl heights would shrink them wrongly.
        var parts = parts
        func measurableBody(_ sub: String, _ g: PersonalGlyph) -> CGFloat? {
            guard sub.contains(where: {
                ScaleConsensus.xBodyLetters.contains($0)
                    || ScaleConsensus.partBodyLetters.contains($0)
            }) else { return nil }
            if sub.count >= 2 {
                return ScaleConsensus.bodyHeight(word: sub, glyph: g)
                    ?? GlyphAlign.bodyHeight(g)
            }
            return GlyphAlign.bodyHeight(g)
        }
        let bodies: [CGFloat?] = parts.indices.map { i in
            i < subs.count ? measurableBody(subs[i], parts[i]) : nil
        }
        let valid = bodies.compactMap { $0 }.filter { $0 > 0.2 }
        if valid.count >= 2 {
            let sorted = valid.sorted()
            let target = sorted[sorted.count / 2]
            for i in parts.indices {
                guard let b = bodies[i], b > 0.2 else { continue }
                let s = min(1.3, max(0.75, 1 + (target / b - 1) * 0.85))
                if abs(s - 1) > 0.08 {
                    parts[i] = GlyphAlign.reseat(ScaleConsensus.apply(s, to: parts[i]))
                }
            }
        }

        var pairs: [(Character, PersonalGlyph)] = []
        for (i, part) in parts.enumerated() {
            pairs.append((Character(String(i % 10)), part))
        }
        guard var packed = StrokeVAE.packLetters(pairs, connectedness: connectedness) else {
            return nil
        }
        // Real ligature strokes across fragment seams — the user's own
        // harvested connectors when we have one for the pair, Hermite curves
        // otherwise. LigatureEngine decides per pair whether the user's hand
        // actually joins those letters at all.
        insertSeamConnectors(into: &packed,
                             partStrokeCounts: parts.map { $0.strokes.count },
                             seams: seams,
                             connectedness: connectedness)
        // A light seam blend keeps fragment boundaries from jumping without
        // changing the captured strokes themselves.
        for i in 1..<packed.strokes.count {
            guard let previous = packed.strokes[i - 1].last,
                  let first = packed.strokes[i].first else { continue }
            let dy = max(-0.12, min(0.12, previous.y - first.y))
            if abs(previous.x - first.x) < 0.3 {
                for j in packed.strokes[i].indices {
                    let fade = 1 - CGFloat(j) / CGFloat(max(1, packed.strokes[i].count - 1))
                    packed.strokes[i][j].y += dy * fade
                }
            }
        }
        return GlyphAlign.reseat(packed)
    }

    /// Bridge fragment boundaries with the user's own harvested connector for
    /// that letter pair when available; otherwise a Hermite curve whose end
    /// tangents match the surrounding ink — the seam stops reading as "pasted".
    private func insertSeamConnectors(into g: inout PersonalGlyph,
                                      partStrokeCounts: [Int],
                                      seams: [String],
                                      connectedness: CGFloat) {
        var boundaries: [Int] = []
        var acc = 0
        for count in partStrokeCounts.dropLast() {
            acc += count
            boundaries.append(acc)
        }

        // Insert back-to-front so earlier boundary indices stay valid.
        for (bi, boundary) in boundaries.enumerated().reversed() {
            guard boundary > 0, boundary < g.strokes.count,
                  let prevIdx = (0..<boundary).reversed()
                      .first(where: { g.strokes[$0].count > 1 }),
                  let nextIdx = (boundary..<g.strokes.count)
                      .first(where: { g.strokes[$0].count > 1 }) else { continue }

            let prev = g.strokes[prevIdx]
            let next = g.strokes[nextIdx]
            guard let p0 = prev.last, let p1 = next.first else { continue }
            let dx = p1.x - p0.x
            let dy = p1.y - p0.y
            guard dx > 0.02, dx < 0.55, abs(dy) < 0.7 else { continue }

            // Per-pair habit: only join what the user's hand actually joins.
            let pair = bi < seams.count ? seams[bi] : "*"
            let pairChars = Array(pair)
            guard LigatureEngine.shared.shouldJoin(
                from: pairChars.count == 2 ? pairChars[0] : nil,
                to: pairChars.count == 2 ? pairChars[1] : nil,
                connectedness: connectedness) else { continue }

            let wOut = g.widths.flatMap { prevIdx < $0.count ? $0[prevIdx].last : nil } ?? 0.10
            let wIn = g.widths.flatMap { nextIdx < $0.count ? $0[nextIdx].first : nil } ?? 0.10
            let clsKey = LigatureEngine.classKey(exitUnitY: p0.y, entryUnitY: p1.y)

            var pts: [CGPoint]
            var connWidths: [CGFloat]
            if let real = realConnector(pair: pair, classKey: clsKey, from: p0, to: p1) {
                pts = real.points
                // Blend harvested pressure with the local seam pressure.
                connWidths = (0..<pts.count).map { s -> CGFloat in
                    let t = CGFloat(s) / CGFloat(max(1, pts.count - 1))
                    let local = wOut + (wIn - wOut) * t
                    let sampled = s < real.widths.count ? real.widths[s] : local
                    return max(0.03, (local + sampled) * 0.5 * 0.85)
                }
            } else {
                func direction(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
                    let len = hypot(b.x - a.x, b.y - a.y)
                    guard len > 1e-4 else { return CGPoint(x: 1, y: 0) }
                    return CGPoint(x: (b.x - a.x) / len, y: (b.y - a.y) / len)
                }
                let kPrev = min(3, prev.count - 1)
                let kNext = min(3, next.count - 1)
                let t0 = direction(prev[prev.count - 1 - kPrev], p0)   // exit
                let t1 = direction(p1, next[kNext])                    // entry

                // Hermite with tangent magnitude tied to the gap length.
                let m = hypot(dx, dy)
                let n = 9
                pts = []
                for s in 0..<n {
                    let t = CGFloat(s) / CGFloat(n - 1)
                    let t2 = t * t, t3 = t2 * t
                    let h00 = 2 * t3 - 3 * t2 + 1
                    let h10 = t3 - 2 * t2 + t
                    let h01 = -2 * t3 + 3 * t2
                    let h11 = t3 - t2
                    pts.append(CGPoint(
                        x: h00 * p0.x + h10 * m * t0.x + h01 * p1.x + h11 * m * t1.x,
                        y: h00 * p0.y + h10 * m * t0.y + h01 * p1.y + h11 * m * t1.y))
                }
                let count = pts.count
                connWidths = (0..<count).map { s -> CGFloat in
                    let t = CGFloat(s) / CGFloat(count - 1)
                    return max(0.03, (wOut + (wIn - wOut) * t) * 0.8)
                }
            }
            // Skip joins that would plow through letter ink — a real hand
            // lifts the pen instead.
            let obstacles = Array(prev.dropLast(3)) + Array(next.dropFirst(3))
            if LigatureEngine.collides(pts, with: obstacles, clearance: 0.09) { continue }

            let samples = pts.count
            let connDuration = 0.05

            // PEN-31: every one of these was `if x != nil { x!.insert(...) }`
            // — nine separate test-then-force-unwrap pairs in one block. Safe
            // as written, but nine chances for a later edit to separate the
            // guard from the unwrap. `insert(into:)` binds once instead.
            func insert<T>(_ value: T, into array: inout [T]?) {
                guard var existing = array, nextIdx <= existing.count else { return }
                existing.insert(value, at: nextIdx)
                array = existing
            }

            g.strokes.insert(pts, at: nextIdx)
            insert(connWidths, into: &g.widths)
            insert(connDuration, into: &g.durations)
            insert(0, into: &g.gaps)
            // The stroke after the connector follows with no pen lift.
            if var gaps = g.gaps, nextIdx + 1 < gaps.count {
                gaps[nextIdx + 1] = 0
                g.gaps = gaps
            }
            insert((0..<samples).map {
                connDuration * Double($0) / Double(samples - 1)
            }, into: &g.pointTimes)
            insert(Array(repeating: 0, count: samples), into: &g.forces)
            insert(Array(repeating: 0, count: samples), into: &g.altitudes)
            insert(Array(repeating: 0, count: samples), into: &g.azimuths)
        }
    }

    /// Coverage score 0…1 — how much of `word` can be built from fragments.
    func coverage(of word: String) -> CGFloat {
        let key = word.lowercased().filter(\.isLetter)
        guard !key.isEmpty else { return 0 }
        var covered = 0
        var i = key.startIndex
        while i < key.endIndex {
            var hit = 0
            for len in Self.ngramRange.reversed() {
                let j = key.index(i, offsetBy: len, limitedBy: key.endIndex) ?? key.endIndex
                guard key.distance(from: i, to: j) == len else { continue }
                if fragments[String(key[i..<j])] != nil { hit = len; break }
            }
            if hit == 0 {
                i = key.index(after: i)
            } else {
                covered += hit
                i = key.index(i, offsetBy: hit)
            }
        }
        return CGFloat(covered) / CGFloat(key.count)
    }

    private func store(_ g: PersonalGlyph, for key: String) {
        var list = fragments[key] ?? []
        list.append(g)
        if list.count > Self.maxVariants {
            list.removeFirst(list.count - Self.maxVariants)
        }
        fragments[key] = list
    }

    /// Cut a horizontal slice of real ink out of a captured word, rebased to 0.
    ///
    /// POINT-LEVEL clipping, not stroke-level selection. The old centroid rule
    /// ("keep whole strokes whose centre falls in the slice") was correct for
    /// printed hands, where the pen lifts between letters — but in a CURSIVE
    /// hand one stroke spans the whole word, so a "th" fragment cropped from
    /// "the" carried the ENTIRE word's ink, and stitched words rendered with
    /// their donors' letters spliced in ("the"+"at" → "theat", "da"+"ay" →
    /// "daay"). Strokes are now cut at the slice boundaries: each contiguous
    /// run of points inside [x0, x1) becomes its own stroke, with widths,
    /// timing and pencil telemetry sliced to the same run — so a fragment
    /// contains exactly the letters it names, printed or cursive.
    static func crop(_ g: PersonalGlyph, fromX x0: CGFloat, toX x1: CGFloat) -> PersonalGlyph? {
        var strokes: [[CGPoint]] = []
        var widths: [[CGFloat]] = []
        var durations: [Double] = []
        var gaps: [Double] = []
        var pointTimes: [[Double]] = []
        var forces: [[CGFloat]] = []
        var altitudes: [[CGFloat]] = []
        var azimuths: [[CGFloat]] = []
        let pad: CGFloat = 0.02

        for (si, pts) in g.strokes.enumerated() {
            guard !pts.isEmpty else { continue }

            // Contiguous runs of points inside the slice. A cursive stroke
            // that leaves and re-enters (an o-loop straddling the boundary)
            // yields multiple runs, each its own stroke.
            var runs: [Range<Int>] = []
            var runStart: Int?
            for (pi, p) in pts.enumerated() {
                if p.x >= x0 - pad && p.x < x1 + pad {
                    if runStart == nil { runStart = pi }
                } else if let s = runStart {
                    runs.append(s..<pi)
                    runStart = nil
                }
            }
            if let s = runStart { runs.append(s..<pts.count) }

            for run in runs {
                let count = run.count
                // Dots survive; sub-3-point slivers of a passing stroke don't.
                guard count >= (pts.count == 1 ? 1 : 3) else { continue }

                let runPts = Array(pts[run])
                if pts.count == 1 {
                    // Donor tittles/dots: keep only when clearly interior to
                    // this slice — an edge dot belongs to a neighbor letter
                    // and renders as a stray mark ("ab.out").
                    guard runPts[0].x > x0 + 0.05, runPts[0].x < x1 - 0.05 else { continue }
                } else {
                    // Near-zero-width run hugging a window edge is a NEIGHBOR
                    // letter's stroke clipped at the boundary — it renders as
                    // a stray stem or flick. A genuine stem (an "l" 1-gram)
                    // sits centered in its own slice and is kept.
                    let xs = runPts.map(\.x)
                    let span = (xs.max() ?? 0) - (xs.min() ?? 0)
                    if span < 0.05,
                       (xs.min() ?? 0) < x0 + 0.04 || (xs.max() ?? 0) > x1 - 0.04 {
                        continue
                    }
                }

                strokes.append(runPts.map { CGPoint(x: $0.x - x0, y: $0.y) })

                if let ws = g.widths, si < ws.count, ws[si].count == pts.count {
                    widths.append(Array(ws[si][run]))
                } else {
                    widths.append(Array(repeating: 0.12, count: count))
                }

                // Timing rebased so the run starts at 0; duration follows the
                // run's own span rather than the donor stroke's full length.
                let rowTimes: [Double]
                if let ts = g.pointTimes, si < ts.count, ts[si].count == pts.count {
                    let slice = Array(ts[si][run])
                    let t0 = slice.first ?? 0
                    rowTimes = slice.map { $0 - t0 }
                } else {
                    rowTimes = Array(repeating: 0, count: count)
                }
                pointTimes.append(rowTimes)
                durations.append(max(0.02, rowTimes.last ?? 0.06))

                if strokes.count == 1 {
                    gaps.append(0)
                } else if run.lowerBound == 0, let gp = g.gaps, si < gp.count {
                    // Run begins where the real stroke began — keep its pause.
                    gaps.append(gp[si])
                } else {
                    // Mid-stroke cut: the pen never lifted here.
                    gaps.append(0.02)
                }

                func row(_ arr: [[CGFloat]]?) -> [CGFloat] {
                    if let a = arr, si < a.count, a[si].count == pts.count {
                        return Array(a[si][run])
                    }
                    return Array(repeating: 0, count: count)
                }
                forces.append(row(g.forces))
                altitudes.append(row(g.altitudes))
                azimuths.append(row(g.azimuths))
            }
        }
        guard !strokes.isEmpty else { return nil }
        let allX = strokes.flatMap { $0.map(\.x) }
        guard let lo = allX.min(), let hi = allX.max(), hi - lo > 0.05 else { return nil }
        // Shift so min x = 0
        if abs(lo) > 0.001 {
            for si in 0..<strokes.count {
                for pi in 0..<strokes[si].count {
                    strokes[si][pi].x -= lo
                }
            }
        }
        return PersonalGlyph(width: max(0.2, hi - lo),
                             strokes: strokes,
                             widths: widths,
                             durations: durations,
                             gaps: gaps,
                             refSize: g.refSize,
                             pointTimes: pointTimes, forces: forces,
                             altitudes: altitudes, azimuths: azimuths,
                             inputSource: g.inputSource,
                             quality: (g.quality ?? 0.6) * 0.92)
    }

    private let saver = DebouncedSaver()

    private func save() {
        let snapshot = Persist(fragments: fragments, connectors: connectors)
        let url = fileURL
        saver.schedule {
            DebouncedSaver.write(snapshot, to: url, label: "FragmentBank")
        }
    }

    private func load() {
        guard let raw = try? Data(contentsOf: fileURL) else { return }
        if let payload = try? JSONDecoder().decode(Persist.self, from: raw),
           (payload.version ?? 0) >= 8 {
            fragments = payload.fragments
            connectors = payload.connectors ?? [:]
        }
        // Older fragments are poisoned (v<4: uniform slicing cut through
        // letters; v<6: whole-stroke crops from cursive words carry the donor
        // word's entire ink) — drop them; PersonalFontStore.load() bootstraps
        // a fresh harvest from the word bank.
    }
}
