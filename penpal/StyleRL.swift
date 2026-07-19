//
//  StyleRL.swift
//  penpal
//
//  Crazy technique: treat handwriting synthesis as a policy, scored by a critic.
//
//  1. Critic — online Gaussian over kinematic features extracted from YOUR real ink
//     (slant, pressure CV, speed, curvature, pauses). Naturalness = how close a
//     candidate sits to that distribution (Mahalanobis → soft score).
//
//  2. Policy — continuous style knobs (messiness, drift, joins, spacing, tempo).
//     Each reply is an "episode": we perturb θ with noise ε, write, then update
//     with REINFORCE: θ ← θ + α · reward · ε  (plus optional thumbs reward).
//
//  3. Bandit — Thompson sampling over glyph/word variants so the arm that looks
//     most like your hand gets drawn more often, instead of pure random.
//
//  No neural net needed on-device. The "ML" is a live feature model; the "RL"
//  is preference + self-supervised naturalness climbing your own hand manifold.
//

import Foundation
import CoreGraphics

// MARK: - Features

struct HandFeatures: Codable {
    /// Mean lateral slant of strokes (dx / |dy|), positive = lean right.
    var slantMean: CGFloat = 0
    var slantStd: CGFloat = 0
    /// Mean normalized pen width.
    var pressureMean: CGFloat = 0.12
    /// Coefficient of variation of pressure (humans wobble; fonts don't).
    var pressureCV: CGFloat = 0.15
    /// Path-length / duration in unit-space per second.
    var speedMean: CGFloat = 8
    /// Turning energy per unit length (real hands curve; stiff glyphs don't).
    var curvature: CGFloat = 0.4
    /// Ink width PER LETTER in x-heights — comparable across a single trained
    /// letter, a captured word, and a whole laid-out reply. (This was raw
    /// glyph/span width: a full reply line measured ~40 units against a
    /// trained-letter distribution centred near 0.6, the z-score exploded,
    /// and the critic pinned every reply at 0%.)
    var widthUnits: CGFloat = 0.6
    /// Strokes per letter — proxies connectedness.
    var strokesPerLetter: CGFloat = 1.2
    /// Mean pen-lift pause (seconds).
    var pauseMean: CGFloat = 0.05
    /// Within-stroke speed variation and pressure direction are strong personal cues.
    var accelerationCV: CGFloat = 0.2
    var pressureTrend: CGFloat = 0
    var wordPauseMean: CGFloat = 0.18

    static let dim = 12

    var vector: [CGFloat] {
        [slantMean, slantStd, pressureMean, pressureCV, speedMean,
         curvature, widthUnits, strokesPerLetter, pauseMean,
         accelerationCV, pressureTrend, wordPauseMean]
    }

    static func extract(from g: PersonalGlyph, letterCount: Int = 1) -> HandFeatures {
        var slants: [CGFloat] = []
        var pressures: [CGFloat] = []
        var speeds: [CGFloat] = []
        var curves: [CGFloat] = []
        var pauses: [CGFloat] = []
        var accelerations: [CGFloat] = []
        var pressureTrends: [CGFloat] = []

        for (i, pts) in g.strokes.enumerated() {
            if pts.count >= 2 {
                slants.append(Self.slant(pts))
                curves.append(Self.curvatureEnergy(pts))
                if let durs = g.durations, i < durs.count, durs[i] > 0.02 {
                    speeds.append(Self.pathLength(pts) / CGFloat(durs[i]))
                }
            }
            if let ws = g.widths, i < ws.count {
                pressures.append(contentsOf: ws[i])
                if let first = ws[i].first, let last = ws[i].last {
                    pressureTrends.append(last - first)
                }
            }
            if let times = g.pointTimes, i < times.count, times[i].count == pts.count {
                var localSpeeds: [CGFloat] = []
                for j in 1..<pts.count {
                    let dt = max(0.001, times[i][j] - times[i][j - 1])
                    localSpeeds.append(hypot(pts[j].x - pts[j - 1].x,
                                             pts[j].y - pts[j - 1].y) / CGFloat(dt))
                }
                if let m = Self.mean(localSpeeds), m > 0.001 {
                    accelerations.append((Self.std(localSpeeds) ?? 0) / m)
                }
            }
            if let gaps = g.gaps, i < gaps.count, i > 0 {
                pauses.append(CGFloat(gaps[i]))
            }
        }

        let pMean = Self.mean(pressures) ?? 0.12
        let pStd = Self.std(pressures) ?? 0
        let letters = max(1, CGFloat(letterCount))

        return HandFeatures(
            slantMean: Self.mean(slants) ?? 0,
            slantStd: Self.std(slants) ?? 0,
            pressureMean: pMean,
            pressureCV: pMean > 1e-4 ? pStd / pMean : 0,
            speedMean: Self.mean(speeds) ?? 8,
            curvature: Self.mean(curves) ?? 0.4,
            widthUnits: g.width / letters,
            strokesPerLetter: CGFloat(g.strokes.count) / letters,
            pauseMean: Self.mean(pauses) ?? 0.05,
            accelerationCV: Self.mean(accelerations) ?? 0.2,
            pressureTrend: Self.mean(pressureTrends) ?? 0,
            wordPauseMean: Self.mean(pauses.filter { $0 > 0.12 }) ?? 0.18
        )
    }

    /// Features from laid-out view-space ink (used to score a synthesis episode).
    static func extract(from strokes: [InkStroke], xHeight: CGFloat, letterCount: Int) -> HandFeatures {
        guard xHeight > 1 else { return HandFeatures() }
        var slants: [CGFloat] = []
        var pressures: [CGFloat] = []
        var speeds: [CGFloat] = []
        var curves: [CGFloat] = []
        var pauses: [CGFloat] = []
        var accelerations: [CGFloat] = []
        var pressureTrends: [CGFloat] = []
        var wordPauses: [CGFloat] = []
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity

        for s in strokes where !s.isDot && s.points.count > 1 {
            // Flip Y so extract math matches unit-space (y grows up).
            let pts = s.points.map { CGPoint(x: $0.x / xHeight, y: -$0.y / xHeight) }
            for p in pts {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            slants.append(Self.slant(pts))
            curves.append(Self.curvatureEnergy(pts))
            if let d = s.duration, d > 0.02 {
                speeds.append(Self.pathLength(pts) / CGFloat(d))
            }
            if let w = s.widths { pressures.append(contentsOf: w.map { $0 / xHeight }) }
            if let p = s.pauseBefore { pauses.append(CGFloat(p)) }
            if s.isWordStart, let p = s.pauseBefore { wordPauses.append(CGFloat(p)) }
            if let w = s.widths, let first = w.first, let last = w.last {
                pressureTrends.append((last - first) / xHeight)
            }
            if let times = s.pointTimes, times.count == s.points.count {
                var local: [CGFloat] = []
                for i in 1..<s.points.count {
                    let dt = max(0.001, times[i] - times[i - 1])
                    local.append(hypot(s.points[i].x - s.points[i - 1].x,
                                       s.points[i].y - s.points[i - 1].y)
                                 / xHeight / CGFloat(dt))
                }
                if let m = Self.mean(local), m > 0.001 {
                    accelerations.append((Self.std(local) ?? 0) / m)
                }
            }
        }

        let pMean = Self.mean(pressures) ?? 0.12
        let pStd = Self.std(pressures) ?? 0
        let letters = max(1, CGFloat(letterCount))
        // Per-letter width, line-aware: the x-span is the WIDEST line, but
        // `letters` counts every line of the reply — divide by the letters
        // on one line, estimated from the vertical extent (one text line is
        // ~2 x-heights tall plus line gap).
        let widthPerLetter: CGFloat
        if maxX.isFinite, minX.isFinite {
            let ySpan = (maxY.isFinite && minY.isFinite) ? maxY - minY : 2
            let lineCount = max(1, ((ySpan + 0.8) / 2.6).rounded())
            let lettersPerLine = max(1, letters / lineCount)
            widthPerLetter = max(0.1, (maxX - minX) / lettersPerLine)
        } else {
            widthPerLetter = 0.6
        }

        return HandFeatures(
            slantMean: Self.mean(slants) ?? 0,
            slantStd: Self.std(slants) ?? 0,
            pressureMean: pMean,
            pressureCV: pMean > 1e-4 ? pStd / pMean : 0,
            speedMean: Self.mean(speeds) ?? 8,
            curvature: Self.mean(curves) ?? 0.4,
            widthUnits: widthPerLetter,
            strokesPerLetter: CGFloat(strokes.filter { !$0.isDot }.count) / letters,
            pauseMean: Self.mean(pauses) ?? 0.05,
            accelerationCV: Self.mean(accelerations) ?? 0.2,
            pressureTrend: Self.mean(pressureTrends) ?? 0,
            wordPauseMean: Self.mean(wordPauses) ?? 0.18
        )
    }

    // MARK: geometry helpers

    private static func pathLength(_ pts: [CGPoint]) -> CGFloat {
        var len: CGFloat = 0
        for i in 1..<pts.count {
            len += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
        }
        return max(1e-4, len)
    }

    private static func slant(_ pts: [CGPoint]) -> CGFloat {
        // dx / (|dy| + ε) along the stroke — positive leans right as it goes down.
        var sum: CGFloat = 0
        var w: CGFloat = 0
        for i in 1..<pts.count {
            let dx = pts[i].x - pts[i - 1].x
            let dy = pts[i].y - pts[i - 1].y
            let weight = abs(dy)
            sum += dx * weight
            w += weight
        }
        return w > 1e-4 ? sum / w : 0
    }

    private static func curvatureEnergy(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count > 2 else { return 0 }
        var turn: CGFloat = 0
        for i in 1..<(pts.count - 1) {
            let ax = pts[i].x - pts[i - 1].x, ay = pts[i].y - pts[i - 1].y
            let bx = pts[i + 1].x - pts[i].x, by = pts[i + 1].y - pts[i].y
            let la = hypot(ax, ay), lb = hypot(bx, by)
            guard la > 1e-4, lb > 1e-4 else { continue }
            let cos = max(-1, min(1, (ax * bx + ay * by) / (la * lb)))
            turn += acos(cos)
        }
        return turn / pathLength(pts)
    }

    private static func mean(_ v: [CGFloat]) -> CGFloat? {
        guard !v.isEmpty else { return nil }
        return v.reduce(0, +) / CGFloat(v.count)
    }

    private static func std(_ v: [CGFloat]) -> CGFloat? {
        guard v.count > 1, let m = mean(v) else { return v.isEmpty ? nil : 0 }
        let var_ = v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / CGFloat(v.count - 1)
        return sqrt(max(0, var_))
    }
}

// MARK: - Policy

struct StylePolicy: Codable {
    /// Multiplies user messiness slider.
    var messinessScale: CGFloat = 1.0
    /// Added to connectedness when deciding whether to draw joins.
    var joinBias: CGFloat = 0.0
    /// Multiplies line-drift amplitude.
    var driftScale: CGFloat = 1.0
    /// Multiplies inter-word / letter spacing.
    var spacingScale: CGFloat = 1.0
    /// Extra random tempo jitter (0…0.4).
    var tempoJitter: CGFloat = 0.08
    /// Scales captured pressure widths.
    var pressureGain: CGFloat = 1.0

    static let paramCount = 6

    func clamped() -> StylePolicy {
        StylePolicy(
            messinessScale: min(2.2, max(0.25, messinessScale)),
            joinBias: min(0.45, max(-0.45, joinBias)),
            driftScale: min(2.0, max(0.2, driftScale)),
            spacingScale: min(1.6, max(0.55, spacingScale)),
            tempoJitter: min(0.35, max(0, tempoJitter)),
            pressureGain: min(1.6, max(0.55, pressureGain))
        )
    }

    var vector: [CGFloat] {
        [messinessScale, joinBias, driftScale, spacingScale, tempoJitter, pressureGain]
    }

    static func from(vector v: [CGFloat]) -> StylePolicy {
        guard v.count >= 6 else { return StylePolicy() }
        return StylePolicy(
            messinessScale: v[0], joinBias: v[1], driftScale: v[2],
            spacingScale: v[3], tempoJitter: v[4], pressureGain: v[5]
        ).clamped()
    }

    func perturb(sigma: CGFloat = 0.08) -> (policy: StylePolicy, epsilon: [CGFloat]) {
        var eps: [CGFloat] = []
        var out = vector
        for i in 0..<out.count {
            let e = CGFloat.random(in: -1...1) * sigma
            eps.append(e)
            out[i] += e
        }
        return (StylePolicy.from(vector: out), eps)
    }

    mutating func reinforce(epsilon: [CGFloat], reward: CGFloat, alpha: CGFloat = 0.12) {
        var v = vector
        for i in 0..<min(v.count, epsilon.count) {
            v[i] += alpha * reward * epsilon[i]
        }
        self = StylePolicy.from(vector: v)
    }
}

// MARK: - Engine

final class StyleRL {

    static let shared = StyleRL()

    private(set) var policy = StylePolicy()
    /// Active (possibly perturbed) policy for the current reply episode.
    private(set) var active = StylePolicy()

    private var mean = Array(repeating: CGFloat(0), count: HandFeatures.dim)
    private var m2 = Array(repeating: CGFloat(0), count: HandFeatures.dim)
    private var n = 0

    /// Beta(α,β) arms per key, one per variant slot.
    private struct Arm: Codable { var alpha: CGFloat = 1; var beta: CGFloat = 1 }
    private var arms: [String: [Arm]] = [:]

    private var lastEpsilon: [CGFloat]?
    /// Kept after endEpisode so thumbs-up/down can still credit the same noise.
    private var preferenceEpsilon: [CGFloat]?
    private var lastScore: CGFloat = 0.5
    private var episodeKeys: [(String, Int)] = []
    private var preferenceKeys: [(String, Int)] = []
    /// Same key always returns the same variant within one reply episode.
    private var pickCache: [String: Int] = [:]

    private struct Persist: Codable {
        // v4: widthUnits became per-letter — critic stats recorded with the
        //     raw-width definition are on a different scale and must be
        //     dropped (policy and bandit arms are unaffected and kept).
        var version: Int? = 4
        var policy: StylePolicy
        var mean: [CGFloat]
        var m2: [CGFloat]
        var n: Int
        var arms: [String: [Arm]]
    }

    private var fileURL: URL {
        HandProfiles.fileURL("style_rl.json")   // PEN-20
    }

    var hasCritic: Bool { n >= 3 }
    var sampleCount: Int { n }
    var lastNaturalness: CGFloat { lastScore }

    init() { load() }

    // MARK: Critic

    /// Fold a real handwriting sample into the naturalness distribution.
    func observeReal(_ glyph: PersonalGlyph, letterCount: Int) {
        let f = HandFeatures.extract(from: glyph, letterCount: letterCount)
        absorb(f.vector)
        save()
    }

    func rebuild(samples: [(glyph: PersonalGlyph, letterCount: Int)]) {
        mean = Array(repeating: 0, count: HandFeatures.dim)
        m2 = Array(repeating: 0, count: HandFeatures.dim)
        n = 0
        arms.removeAll()
        pickCache.removeAll()
        for sample in samples {
            absorb(HandFeatures.extract(from: sample.glyph,
                                        letterCount: sample.letterCount).vector)
        }
        active = policy
        save()
    }

    /// Soft naturalness in 0…1. Untrained critic returns a neutral 0.5.
    func score(_ features: HandFeatures) -> CGFloat {
        guard n >= 2 else { return 0.5 }
        let x = features.vector
        var d2: CGFloat = 0
        for i in 0..<HandFeatures.dim {
            let var_ = max(1e-4, m2[i] / CGFloat(n - 1))
            let z = (x[i] - mean[i]) / sqrt(var_)
            d2 += z * z
        }
        // χ²-ish → soft score. dim=9 → typical real samples land ~0.6–0.9.
        return CGFloat(exp(-Double(d2) / (2.0 * Double(HandFeatures.dim))))
    }

    private func absorb(_ x: [CGFloat]) {
        n += 1
        for i in 0..<HandFeatures.dim {
            let delta = x[i] - mean[i]
            mean[i] += delta / CGFloat(n)
            m2[i] += delta * (x[i] - mean[i])
        }
    }

    // MARK: Episodes (REINFORCE)

    /// Call once at the start of a reply layout. Returns the knobs to use.
    @discardableResult
    func beginEpisode(explore: Bool = true) -> StylePolicy {
        episodeKeys = []
        preferenceKeys = []
        preferenceEpsilon = nil
        pickCache = [:]
        if explore, n >= 8 {
            let (p, eps) = policy.perturb(sigma: 0.07)
            active = p
            lastEpsilon = eps
        } else {
            active = policy
            lastEpsilon = nil
        }
        return active
    }

    /// Score the ink we just synthesized and climb the policy.
    func endEpisode(strokes: [InkStroke], xHeight: CGFloat, letterCount: Int) {
        let f = HandFeatures.extract(from: strokes, xHeight: xHeight, letterCount: max(1, letterCount))
        let s = score(f)
        lastScore = s
        // Center reward around 0.55 so mediocre doesn't push randomly.
        let reward = (s - 0.55) * 2
        if let eps = lastEpsilon {
            policy.reinforce(epsilon: eps, reward: reward, alpha: 0.10)
            preferenceEpsilon = eps
        }
        preferenceKeys = episodeKeys
        for (key, idx) in episodeKeys {
            updateArm(key: key, index: idx, reward: s)
        }
        lastEpsilon = nil
        save()
    }

    /// Human preference — the RLHF button. Stronger than self-score.
    func prefer(liked: Bool) {
        let reward: CGFloat = liked ? 1.0 : -1.0
        if let eps = preferenceEpsilon {
            policy.reinforce(epsilon: eps, reward: reward, alpha: 0.22)
        } else {
            // No live perturbation — nudge toward / away from last active.
            let baseline = StylePolicy()
            let delta = zip(active.vector, baseline.vector).map { $0 - $1 }
            policy.reinforce(epsilon: delta, reward: reward, alpha: 0.08)
        }
        for (key, idx) in preferenceKeys {
            updateArm(key: key, index: idx, reward: liked ? 0.95 : 0.1)
        }
        lastScore = liked ? min(1, lastScore + 0.15) : max(0, lastScore - 0.2)
        preferenceEpsilon = nil
        preferenceKeys = []
        save()
    }

    // MARK: Variant bandit

    /// Thompson-sample a variant. Preference for arms whose glyphs sit near your hand.
    func pickVariantIndex(key: String, glyphs: [PersonalGlyph], letterCount: Int) -> Int {
        guard !glyphs.isEmpty else { return 0 }
        if let cached = pickCache[key], cached < glyphs.count {
            return cached
        }
        ensureArms(key: key, count: glyphs.count)

        var best = 0
        var bestSample: CGFloat = -1
        for i in 0..<glyphs.count {
            // Prior pull toward critic agreement.
            let prior = score(HandFeatures.extract(from: glyphs[i], letterCount: letterCount))
            let arm = arms[key]![i]
            // Soft-blend prior into Beta so brand-new variants aren't ignored.
            let a = arm.alpha + prior * 2
            let b = arm.beta + (1 - prior) * 2
            let sample = Self.betaSample(alpha: a, beta: b)
            if sample > bestSample {
                bestSample = sample
                best = i
            }
        }
        pickCache[key] = best
        episodeKeys.append((key, best))
        return best
    }

    private func ensureArms(key: String, count: Int) {
        var list = arms[key] ?? []
        while list.count < count { list.append(Arm()) }
        if list.count > count { list = Array(list.prefix(count)) }
        arms[key] = list
    }

    private func updateArm(key: String, index: Int, reward: CGFloat) {
        guard var list = arms[key], index < list.count else { return }
        // reward in 0…1 → pseudo-count update
        let r = min(1, max(0, reward))
        list[index].alpha += r
        list[index].beta += (1 - r)
        arms[key] = list
    }

    /// Gamma(shape,1) via Marsaglia — good enough for Beta sampling on-device.
    private static func betaSample(alpha: CGFloat, beta: CGFloat) -> CGFloat {
        let x = gammaSample(Double(alpha))
        let y = gammaSample(Double(beta))
        let s = x + y
        return s > 0 ? CGFloat(x / s) : 0.5
    }

    private static func gammaSample(_ shape: Double) -> Double {
        if shape < 1 {
            return gammaSample(shape + 1) * pow(Double.random(in: 0...1), 1 / max(shape, 1e-6))
        }
        let d = shape - 1.0 / 3.0
        let c = 1 / sqrt(9 * d)
        while true {
            var x = 0.0, v = 0.0
            repeat {
                x = Self.randn()
                v = 1 + c * x
            } while v <= 0
            v = v * v * v
            let u = Double.random(in: 0...1)
            if u < 1 - 0.0331 * (x * x) * (x * x) { return d * v }
            if log(u) < 0.5 * x * x + d * (1 - v + log(v)) { return d * v }
        }
    }

    private static func randn() -> Double {
        // Box-Muller
        let u1 = Double.random(in: 1e-12...1)
        let u2 = Double.random(in: 0...1)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }

    // MARK: Persistence

    private let saver = DebouncedSaver()

    private func save() {
        let payload = Persist(policy: policy, mean: mean, m2: m2, n: n, arms: arms)
        let url = fileURL
        saver.schedule {
            DebouncedSaver.write(payload, to: url, label: "StyleRL")
        }
    }

    private func load() {
        guard let raw = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Persist.self, from: raw) else { return }
        policy = decoded.policy.clamped()
        active = policy
        arms = decoded.arms
        // Critic stats from before the per-letter widthUnits definition are
        // on the wrong scale — start fresh; PersonalFontStore's rebuild path
        // re-absorbs every stored sample with the new features.
        guard (decoded.version ?? 0) >= 4 else { return }
        if decoded.mean.count == HandFeatures.dim { mean = decoded.mean }
        if decoded.m2.count == HandFeatures.dim { m2 = decoded.m2 }
        n = decoded.n
    }
}
