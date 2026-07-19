//
//  LigatureEngine.swift
//  penpal
//
//  Rule-based cursive joining — NO generative model, by design. The letters
//  on the page stay 100% the user's real ink; this engine only decides WHERE
//  two letters join and contributes the few millimeters of joiner between
//  them. That's what keeps a reply feeling like "I wrote this".
//
//  Three rule sources, in order of authority:
//
//  1. Measured habits — the user's trained words tell us, per letter pair,
//     whether THEY actually join it (a pen-down stroke crossing the letter
//     boundary). "th" joined 9/10 times → we join it ~90% of the time; never
//     joined after "s" → neither do we. The selectiveness IS the user's.
//  2. Hard rules — never join to/from capitals, digits or punctuation; skip
//     any joiner whose path would collide with existing letter ink.
//  3. Joiner shape priority — harvested real connector for the exact pair →
//     harvested connector of the same exit/entry height class → synthetic
//     curve as last resort.
//

import Foundation
import CoreGraphics

final class LigatureEngine {

    static let shared = LigatureEngine()

    // MARK: - Height classes (for connector fallback lookup)

    enum HeightClass: String {
        case low, mid, high
        init(unitY: CGFloat) {
            if unitY < 0.35 { self = .low }
            else if unitY < 0.75 { self = .mid }
            else { self = .high }
        }
    }

    /// Class key like "~low>mid": which band the joiner leaves from and lands
    /// in. An "o" exits high, an "a" exits at the baseline — their joiners
    /// are different animals even toward the same next letter.
    static func classKey(exitUnitY: CGFloat, entryUnitY: CGFloat) -> String {
        "~\(HeightClass(unitY: exitUnitY).rawValue)>\(HeightClass(unitY: entryUnitY).rawValue)"
    }

    // MARK: - Join statistics

    private struct Stats: Codable {
        var joined = 0
        var total = 0
    }
    private struct Persist: Codable {
        var version: Int? = 1
        var pairs: [String: Stats] = [:]
        /// Aggregate per first letter — catches "never joins after g/s/y"
        /// habits even for pairs we haven't seen enough of.
        var after: [String: Stats] = [:]
    }
    private var data = Persist()

    private var fileURL: URL {
        HandProfiles.fileURL("ligature_stats.json")   // PEN-20
    }

    init() { load() }

    /// Learn from one word capture: a boundary counts as joined when a single
    /// pen-down stroke crosses it.
    func observe(word: String, glyph: PersonalGlyph) {
        record(word: word, glyph: glyph)
        save()
    }

    func rebuild(words: [String: [PersonalGlyph]]) {
        data = Persist()
        for (word, variants) in words {
            for glyph in variants { record(word: word, glyph: glyph) }
        }
        save()
    }

    func bootstrap(words: [String: [PersonalGlyph]]) {
        guard data.pairs.isEmpty, !words.isEmpty else { return }
        rebuild(words: words)
    }

    private func record(word: String, glyph: PersonalGlyph) {
        let chars = Array(word.lowercased().filter(\.isLetter))
        guard chars.count >= 2, glyph.width > 0.1 else { return }
        var cum: [CGFloat] = [0]
        for ch in chars {
            cum.append(cum.last! + max(0.15, StrokeFont.glyph(for: ch).width))
        }
        let total = max(0.3, cum.last!)
        for i in 1..<chars.count {
            let b = glyph.width * cum[i] / total
            let crossed = glyph.strokes.contains { pts in
                pts.count >= 2 && (1..<pts.count).contains {
                    pts[$0 - 1].x <= b && pts[$0].x > b
                }
            }
            let pair = "\(chars[i - 1])\(chars[i])"
            data.pairs[pair, default: Stats()].total += 1
            data.after[String(chars[i - 1]), default: Stats()].total += 1
            if crossed {
                data.pairs[pair]?.joined += 1
                data.after[String(chars[i - 1])]?.joined += 1
            }
        }
    }

    // MARK: - Join decision

    /// Probability the user joins a→b. Pair evidence first, then the
    /// first-letter habit, then the global connectedness (shaped so printed
    /// hands stay printed instead of joining 30% of the time "randomly").
    func joinProbability(from a: Character, to b: Character,
                         connectedness: CGFloat) -> CGFloat {
        let pair = "\(a)\(b)"
        if let s = data.pairs[pair], s.total >= 3 {
            return CGFloat(s.joined) / CGFloat(s.total)
        }
        let shaped = min(1, max(0, (connectedness - 0.25) * 1.4))
        if let s = data.after[String(a)], s.total >= 5 {
            let rate = CGFloat(s.joined) / CGFloat(s.total)
            return (rate * 2 + shaped) / 3
        }
        return shaped
    }

    /// Hard rules + measured probability. Nil characters, capitals, digits
    /// and punctuation never join.
    func shouldJoin(from a: Character?, to b: Character?,
                    connectedness: CGFloat) -> Bool {
        guard let a, let b, a.isLetter, b.isLetter,
              !a.isUppercase, !b.isUppercase else { return false }
        guard let la = a.lowercased().first, let lb = b.lowercased().first else { return false }
        let p = joinProbability(from: la, to: lb, connectedness: connectedness)
        guard p > 0.12 else { return false }
        return CGFloat.random(in: 0...1) < min(0.96, p)
    }

    // MARK: - Collision guard

    /// True when a candidate joiner would run into existing letter ink.
    /// Obstacle points near the joiner's own endpoints don't count — the
    /// joiner legitimately touches the letters it connects.
    static func collides(_ path: [CGPoint], with obstacles: [CGPoint],
                         clearance: CGFloat) -> Bool {
        guard path.count > 4, !obstacles.isEmpty,
              let a = path.first, let b = path.last else { return false }
        let exclusion = clearance * 2.5
        let relevant = obstacles.filter {
            hypot($0.x - a.x, $0.y - a.y) > exclusion
                && hypot($0.x - b.x, $0.y - b.y) > exclusion
        }
        guard !relevant.isEmpty else { return false }
        for p in path.dropFirst(2).dropLast(2) {
            for o in relevant where hypot(p.x - o.x, p.y - o.y) < clearance {
                return true
            }
        }
        return false
    }

    // MARK: - Joiner construction (view space)

    /// Build the joining stroke from one letter's exit to the next letter's
    /// entry. Takes the trailing/leading RUNS of the neighbor strokes (not
    /// bare points) so the join leaves and lands tangent to the real ink —
    /// straight bridges are what read as robotic. Real harvested connector
    /// first (kept within tight rotation/stretch limits: a connector spun
    /// 80° is a stick, not a curve), tangent-matched Hermite otherwise; nil
    /// when geometry forbids it or the path would collide — the pen lifts,
    /// like a real hand skipping an awkward join.
    func joiner(fromTail exitTail: [CGPoint], toHead entryHead: [CGPoint],
                pair: (Character, Character),
                size: CGFloat, baselineY: CGFloat,
                inkWidth: CGFloat,
                obstacles: [CGPoint]) -> InkStroke? {
        guard let exit = exitTail.last, let entry = entryHead.first else { return nil }
        let dx = entry.x - exit.x
        let dy = entry.y - exit.y
        guard size > 1,
              dx > -size * 0.15, dx < size * 1.2,
              abs(dy) < size * 1.6 else { return nil }

        let pairKey = "\(pair.0)\(pair.1)".lowercased()
        let clsKey = Self.classKey(exitUnitY: (baselineY - exit.y) / size,
                                   entryUnitY: (baselineY - entry.y) / size)

        var path: [CGPoint]?
        if let sample = FragmentBank.shared.connector(pair: pairKey, classKey: clsKey),
           sample.points.count >= 3, let sEnd = sample.points.last {
            // Sample is unit space (y up), relative to its start. Map to view
            // space and similarity-transform its endpoints onto exit → entry.
            let sv = CGPoint(x: sEnd.x * size, y: -sEnd.y * size)
            let tv = CGPoint(x: dx, y: dy)
            let sLen = hypot(sv.x, sv.y)
            let tLen = hypot(tv.x, tv.y)
            if sLen > size * 0.02, tLen > size * 0.015 {
                let scale = tLen / sLen
                let rot = atan2(tv.y, tv.x) - atan2(sv.y, sv.x)
                if scale > 0.55, scale < 1.8, abs(rot) < 0.6 {
                    let cosR = cos(rot) * scale
                    let sinR = sin(rot) * scale
                    path = sample.points.map { p in
                        let vx = p.x * size
                        let vy = -p.y * size
                        return CGPoint(x: exit.x + vx * cosR - vy * sinR,
                                       y: exit.y + vx * sinR + vy * cosR)
                    }
                }
            }
        }
        if path == nil {
            // Tangent-continuous Hermite: leaves along the exit stroke's real
            // direction, lands along the entry stroke's — a curve, not a rod.
            func direction(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
                let len = hypot(b.x - a.x, b.y - a.y)
                guard len > 1e-4 else { return CGPoint(x: 1, y: 0) }
                return CGPoint(x: (b.x - a.x) / len, y: (b.y - a.y) / len)
            }
            let t0 = direction(exitTail.first ?? exit, exit)
            let t1 = direction(entry, entryHead.last ?? entry)
            let m = hypot(dx, dy)
            let n = 12
            var pts: [CGPoint] = []
            for s in 0..<n {
                let t = CGFloat(s) / CGFloat(n - 1)
                let t2 = t * t, t3 = t2 * t
                let h00 = 2 * t3 - 3 * t2 + 1
                let h10 = t3 - 2 * t2 + t
                let h01 = -2 * t3 + 3 * t2
                let h11 = t3 - t2
                pts.append(CGPoint(
                    x: h00 * exit.x + h10 * m * t0.x + h01 * entry.x + h11 * m * t1.x,
                    y: h00 * exit.y + h10 * m * t0.y + h01 * entry.y + h11 * m * t1.y))
            }
            path = pts
        }
        guard let pts = path, pts.count >= 3 else { return nil }
        if Self.collides(pts, with: obstacles, clearance: max(1.2, inkWidth * 0.9)) {
            return nil
        }
        // Taper: joins thin out mid-flight and thicken into the landing.
        let widths = (0..<pts.count).map { i -> CGFloat in
            let t = CGFloat(i) / CGFloat(max(1, pts.count - 1))
            let dip = 1 - 0.25 * sin(t * .pi)
            return max(1.0, inkWidth * dip)
        }
        var stroke = InkStroke(points: pts, widths: widths)
        stroke.pauseBefore = 0
        return stroke
    }

    // MARK: - Persistence

    private let saver = DebouncedSaver()

    private func save() {
        let snapshot = data
        let url = fileURL
        saver.schedule {
            DebouncedSaver.write(snapshot, to: url, label: "LigatureEngine")
        }
    }

    private func load() {
        guard let raw = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Persist.self, from: raw) else { return }
        data = decoded
    }
}
