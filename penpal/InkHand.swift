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
        var version: Int? = 5
        var fragments: [String: [PersonalGlyph]]
        var connectors: [String: [ConnectorSample]]? = nil
    }

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ink_fragments.json")
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

        // Cumulative width prior per boundary, scaled to the captured width.
        var cum: [CGFloat] = [0]
        for ch in chars {
            cum.append(cum.last! + max(0.15, StrokeFont.glyph(for: ch).width))
        }
        let total = max(0.3, cum.last!)
        func boundary(_ i: Int) -> CGFloat { glyph.width * cum[i] / total }

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
        struct Path { var score: CGFloat; var parts: [PersonalGlyph]; var seams: [String] }
        var best = Array<Path?>(repeating: nil, count: chars.count + 1)
        best[0] = Path(score: 0, parts: [], seams: [])

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
                                             seams: prefix.seams + seam)
                    }
                }
            }
        }
        guard let path = best[chars.count], !path.parts.isEmpty else { return nil }
        if path.parts.count == 1 { return path.parts[0] }
        return join(path.parts, seams: path.seams, connectedness: connectedness)
    }

    private static func seamCost(_ a: PersonalGlyph, _ b: PersonalGlyph) -> CGFloat {
        guard let tail = a.strokes.last(where: { $0.count > 1 })?.last,
              let head = b.strokes.first(where: { $0.count > 1 })?.first else { return 0.4 }
        let vertical = abs(tail.y - head.y)
        let aw = a.widths?.last?.last ?? 0.12
        let bw = b.widths?.first?.first ?? 0.12
        return vertical + abs(aw - bw) * 1.5
    }

    private func join(_ parts: [PersonalGlyph], seams: [String],
                      connectedness: CGFloat) -> PersonalGlyph? {
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

            g.strokes.insert(pts, at: nextIdx)
            if g.widths != nil, nextIdx <= g.widths!.count {
                g.widths!.insert(connWidths, at: nextIdx)
            }
            if g.durations != nil, nextIdx <= g.durations!.count {
                g.durations!.insert(connDuration, at: nextIdx)
            }
            if g.gaps != nil, nextIdx <= g.gaps!.count {
                g.gaps!.insert(0, at: nextIdx)
                // The stroke after the connector follows with no pen lift.
                if nextIdx + 1 < g.gaps!.count { g.gaps![nextIdx + 1] = 0 }
            }
            if g.pointTimes != nil, nextIdx <= g.pointTimes!.count {
                g.pointTimes!.insert((0..<samples).map {
                    connDuration * Double($0) / Double(samples - 1)
                }, at: nextIdx)
            }
            if g.forces != nil, nextIdx <= g.forces!.count {
                g.forces!.insert(Array(repeating: 0, count: samples), at: nextIdx)
            }
            if g.altitudes != nil, nextIdx <= g.altitudes!.count {
                g.altitudes!.insert(Array(repeating: 0, count: samples), at: nextIdx)
            }
            if g.azimuths != nil, nextIdx <= g.azimuths!.count {
                g.azimuths!.insert(Array(repeating: 0, count: samples), at: nextIdx)
            }
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

    /// Keep strokes/points whose centroid x lies in [x0, x1), rebase to 0.
    private static func crop(_ g: PersonalGlyph, fromX x0: CGFloat, toX x1: CGFloat) -> PersonalGlyph? {
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
            let cx = pts.map(\.x).reduce(0, +) / CGFloat(pts.count)
            // Keep if center in range, or stroke overlaps the slice substantially.
            let minX = pts.map(\.x).min()!
            let maxX = pts.map(\.x).max()!
            let overlap = min(maxX, x1) - max(minX, x0)
            let keep = (cx >= x0 - pad && cx < x1 + pad) || overlap > (maxX - minX) * 0.45
            guard keep else { continue }

            // Clip points roughly to slice with a soft margin.
            let clipped = pts.map { CGPoint(x: $0.x - x0, y: $0.y) }
            strokes.append(clipped)
            if let ws = g.widths, si < ws.count {
                widths.append(ws[si])
            } else {
                widths.append(Array(repeating: 0.12, count: pts.count))
            }
            if let d = g.durations, si < d.count { durations.append(d[si]) }
            else { durations.append(0.06) }
            if gaps.isEmpty { gaps.append(0) }
            else if let gp = g.gaps, si < gp.count { gaps.append(gp[si]) }
            else { gaps.append(0.03) }
            pointTimes.append(g.pointTimes.flatMap { si < $0.count ? $0[si] : nil }
                ?? Array(repeating: 0, count: pts.count))
            forces.append(g.forces.flatMap { si < $0.count ? $0[si] : nil }
                ?? Array(repeating: 0, count: pts.count))
            altitudes.append(g.altitudes.flatMap { si < $0.count ? $0[si] : nil }
                ?? Array(repeating: 0, count: pts.count))
            azimuths.append(g.azimuths.flatMap { si < $0.count ? $0[si] : nil }
                ?? Array(repeating: 0, count: pts.count))
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
           (payload.version ?? 0) >= 4 {
            fragments = payload.fragments
            connectors = payload.connectors ?? [:]
        }
        // Older fragments were sliced at uniform letter widths — drop them;
        // PersonalFontStore.load() bootstraps a fresh harvest from the word bank.
    }
}
