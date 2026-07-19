//
//  StrokeVAE.swift
//  penpal
//
//  Tiny on-device stroke VAE (linear): PCA over fixed-length ink signatures.
//
//  Trained words define a handwriting manifold in latent space. Unseen words
//  are built from letter glyphs, encoded, then pulled toward that manifold and
//  decoded as a displacement field — so identity stays (it's still "hello")
//  but the ink morphs into YOUR connected, pressured, slanted style instead
//  of glued calibration letters.
//
//  encode(x) = Uᵀ(x − μ)    decode(z) = μ + Uz     (classic linear VAE / PPCA)
//

import Foundation
import CoreGraphics

final class StrokeVAE {

    static let shared = StrokeVAE()

    static let sampleCount = 48          // points along the ink ribbon
    static let dims = sampleCount * 3    // x, y, pressure per sample
    static let latentDim = 10
    static let minCorpus = 4             // word samples before the manifold is usable

    private var mean = [Double](repeating: 0, count: dims)
    private var components = [[Double]]()   // latentDim × dims (row = principal axis)
    private var latentMean = [Double](repeating: 0, count: latentDim)
    private var latentStd = [Double](repeating: 0.15, count: latentDim)
    private var corpus = 0
    private var recentSignatures: [[Double]] = []
    private let recentCap = 48

    /// Cached word → latest signature latent (for neighbor style lookup).
    private var wordLatents: [String: [Double]] = [:]

    var isReady: Bool { corpus >= Self.minCorpus && components.count == Self.latentDim }
    var corpusSize: Int { corpus }

    private var fileURL: URL {
        HandProfiles.fileURL("stroke_vae.json")   // PEN-20
    }

    private struct Persist: Codable {
        var version: Int? = 3
        var mean: [Double]
        var components: [[Double]]
        var latentMean: [Double]
        var latentStd: [Double]
        var corpus: Int
        var recent: [[Double]]
        var wordLatents: [String: [Double]]
    }

    init() { load() }

    // MARK: - Public API

    /// Fold a captured word into the manifold (call from PersonalFontStore.addWord).
    func observe(word: String, glyph: PersonalGlyph) {
        let key = word.lowercased()
        guard let sig = signature(of: glyph) else { return }
        recentSignatures.append(sig)
        if recentSignatures.count > recentCap {
            recentSignatures.removeFirst(recentSignatures.count - recentCap)
        }
        corpus += 1
        if isReady, let z = encode(sig) {
            wordLatents[key] = z
        } else if let z = provisionalEncode(sig) {
            wordLatents[key] = z
        }
        refitIfNeeded()
        // Refresh this word's latent after a refit.
        if isReady, let z = encode(sig) {
            wordLatents[key] = z
        }
        save()
    }

    /// Rebuild from an existing word bank (first launch after update, etc.).
    func bootstrapIfNeeded(words: [String: [PersonalGlyph]]) {
        guard !isReady, !words.isEmpty else { return }
        for (w, list) in words {
            for g in list {
                observe(word: w, glyph: g)
            }
        }
    }

    func rebuild(words: [String: [PersonalGlyph]]) {
        mean = [Double](repeating: 0, count: Self.dims)
        components.removeAll()
        latentMean = [Double](repeating: 0, count: Self.latentDim)
        latentStd = [Double](repeating: 0.15, count: Self.latentDim)
        corpus = 0
        recentSignatures.removeAll()
        wordLatents.removeAll()
        for (word, variants) in words {
            for glyph in variants { observe(word: word, glyph: glyph) }
        }
        save()
    }

    /// Before PCA is fit, stash zeros so neighbor lookup still has keys.
    private func provisionalEncode(_ sig: [Double]) -> [Double]? {
        guard sig.count == Self.dims else { return nil }
        return [Double](repeating: 0, count: Self.latentDim)
    }

    /// Synthesize an unseen word in the user's latent style.
    /// Returns nil if the VAE isn't ready or letters are missing.
    func synthesizeWord(_ word: String,
                        letterGlyphs: [(Character, PersonalGlyph)],
                        connectedness: CGFloat) -> PersonalGlyph? {
        guard isReady, !letterGlyphs.isEmpty else { return nil }
        guard let packed = Self.packLetters(letterGlyphs, connectedness: connectedness),
              let refSig = signature(of: packed),
              let zRef = encode(refSig) else { return nil }

        let zStyle = styleLatent(for: word)
        // Pull composition toward the hand manifold; keep enough of zRef for legibility.
        let alpha = 0.58
        var z = zip(zRef, zStyle).map { (1 - alpha) * $0 + alpha * $1 }
        // Light stochastic decode — the VAE reparameterization trick.
        for i in 0..<z.count {
            z[i] += Double.random(in: -1...1) * latentStd[i] * 0.18
        }

        guard let targetSig = decode(z),
              let refDecode = decode(zRef) else { return nil }

        // Displacement field in signature space, applied back onto packed strokes.
        var delta = [Double](repeating: 0, count: Self.dims)
        for i in 0..<Self.dims { delta[i] = targetSig[i] - refDecode[i] }

        return Self.applyDisplacement(to: packed, delta: delta, strength: 0.85)
    }

    /// Sample a fresh session latent (mean style + controlled noise) for sentence unity.
    func sampleSessionLatent() -> [Double]? {
        guard isReady else { return nil }
        return (0..<Self.latentDim).map { i in
            latentMean[i] + Double.random(in: -1...1) * latentStd[i] * 0.55
        }
    }

    /// Pull an existing glyph toward a target latent without rebuilding topology.
    func morphToward(_ glyph: PersonalGlyph, targetZ: [Double], strength: CGFloat) -> PersonalGlyph? {
        guard isReady, strength > 0.01,
              let refSig = signature(of: glyph),
              let zRef = encode(refSig),
              targetZ.count == Self.latentDim else { return glyph }

        let a = Double(min(1, max(0, strength)))
        let z = zip(zRef, targetZ).map { (1 - a) * $0 + a * $1 }
        guard let targetSig = decode(z), let refDecode = decode(zRef) else { return glyph }

        var delta = [Double](repeating: 0, count: Self.dims)
        for i in 0..<Self.dims { delta[i] = targetSig[i] - refDecode[i] }
        return Self.applyDisplacement(to: glyph, delta: delta, strength: CGFloat(a))
    }

    // MARK: - Signature

    /// Arc-length ribbon through all strokes → fixed (x,y,pressure) vector, box-normalized.
    func signature(of g: PersonalGlyph) -> [Double]? {
        var ribbon: [(CGPoint, CGFloat)] = []
        for (i, pts) in g.strokes.enumerated() {
            guard pts.count >= 1 else { continue }
            let ws = (g.widths != nil && i < g.widths!.count) ? g.widths![i] : nil
            if pts.count == 1 {
                ribbon.append((pts[0], ws?.first ?? 0.12))
                continue
            }
            for j in 0..<pts.count {
                let w = ws.flatMap { j < $0.count ? $0[j] : nil } ?? 0.12
                ribbon.append((pts[j], w))
            }
        }
        guard ribbon.count >= 2 else { return nil }

        // Normalize: origin at minX / baseline-ish, scale by max(|y|, width).
        let xs = ribbon.map { $0.0.x }
        let ys = ribbon.map { $0.0.y }
        let minX = xs.min()!, maxX = xs.max()!
        let minY = ys.min()!, maxY = ys.max()!
        let sx = max(0.15, maxX - minX)
        let sy = max(0.4, maxY - minY)
        let scale = max(sx, sy)

        let normed: [(CGPoint, CGFloat)] = ribbon.map {
            (CGPoint(x: ($0.0.x - minX) / scale, y: ($0.0.y - minY) / scale),
             min(0.4, max(0.02, $0.1)))
        }

        // Arc-length resample to sampleCount.
        var lengths: [CGFloat] = [0]
        for i in 1..<normed.count {
            let d = hypot(normed[i].0.x - normed[i - 1].0.x,
                          normed[i].0.y - normed[i - 1].0.y)
            lengths.append(lengths[i - 1] + max(d, 1e-5))
        }
        let total = lengths.last!
        var out = [Double](repeating: 0, count: Self.dims)
        for s in 0..<Self.sampleCount {
            let t = CGFloat(s) / CGFloat(Self.sampleCount - 1) * total
            // binary-ish scan
            var idx = 0
            while idx + 1 < lengths.count, lengths[idx + 1] < t { idx += 1 }
            let i0 = idx, i1 = min(idx + 1, normed.count - 1)
            let seg = max(1e-5, lengths[i1] - lengths[i0])
            let u = CGFloat((t - lengths[i0]) / seg)
            let p = CGPoint(x: normed[i0].0.x + (normed[i1].0.x - normed[i0].0.x) * u,
                            y: normed[i0].0.y + (normed[i1].0.y - normed[i0].0.y) * u)
            let w = normed[i0].1 + (normed[i1].1 - normed[i0].1) * u
            out[s * 3]     = Double(p.x)
            out[s * 3 + 1] = Double(p.y)
            out[s * 3 + 2] = Double(w)
        }
        return out
    }

    // MARK: - Encode / Decode

    func encode(_ sig: [Double]) -> [Double]? {
        guard isReady, sig.count == Self.dims else { return nil }
        var z = [Double](repeating: 0, count: Self.latentDim)
        for k in 0..<Self.latentDim {
            var sum = 0.0
            let c = components[k]
            for i in 0..<Self.dims {
                sum += (sig[i] - mean[i]) * c[i]
            }
            z[k] = sum
        }
        return z
    }

    func decode(_ z: [Double]) -> [Double]? {
        guard isReady, z.count == Self.latentDim else { return nil }
        var x = mean
        for k in 0..<Self.latentDim {
            let c = components[k]
            let zk = z[k]
            for i in 0..<Self.dims {
                x[i] += zk * c[i]
            }
        }
        return x
    }

    private func styleLatent(for word: String) -> [Double] {
        let target = Set(word.lowercased().filter(\.isLetter))
        var acc = [Double](repeating: 0, count: Self.latentDim)
        var wSum = 0.0

        for (w, z) in wordLatents {
            let letters = Set(w.filter(\.isLetter))
            guard !letters.isEmpty, !target.isEmpty else { continue }
            let inter = Double(letters.intersection(target).count)
            let uni = Double(letters.union(target).count)
            let jaccard = inter / max(uni, 1)
            let weight = jaccard + 0.08
            wSum += weight
            for i in 0..<Self.latentDim { acc[i] += z[i] * weight }
        }

        if wSum > 0.01 {
            return acc.map { $0 / wSum }
        }
        return latentMean
    }

    // MARK: - Pack letters → pseudo-word glyph

    static func packLetters(_ pairs: [(Character, PersonalGlyph)],
                            connectedness: CGFloat) -> PersonalGlyph? {
        guard !pairs.isEmpty else { return nil }
        // Seat every letter on the same baseline before concatenating —
        // this kills the "some letters float" look from uneven training.
        let aligned: [(Character, PersonalGlyph)] = pairs.map { ch, g in
            (ch, GlyphAlign.normalize(g, forChar: ch))
        }

        var strokes: [[CGPoint]] = []
        var widths: [[CGFloat]] = []
        var durations: [Double] = []
        var gaps: [Double] = []
        var pointTimes: [[Double]] = []
        var forces: [[CGFloat]] = []
        var altitudes: [[CGFloat]] = []
        var azimuths: [[CGFloat]] = []
        var x: CGFloat = 0
        let spacing = StrokeFont.letterSpacing * (1 - 0.55 * min(1, connectedness))
        var refSize: CGFloat?

        for (idx, (_, g)) in aligned.enumerated() {
            if refSize == nil { refSize = g.refSize }
            for (si, pts) in g.strokes.enumerated() {
                strokes.append(pts.map { CGPoint(x: $0.x + x, y: $0.y) })
                if let ws = g.widths, si < ws.count {
                    widths.append(ws[si])
                } else {
                    widths.append(Array(repeating: 0.12, count: pts.count))
                }
                if let d = g.durations, si < d.count {
                    durations.append(d[si])
                } else {
                    durations.append(0.08)
                }
                if idx == 0 && si == 0 {
                    gaps.append(0)
                } else if si == 0 {
                    gaps.append(max(0.0, 0.06 * (1 - Double(connectedness))))
                } else if let gaph = g.gaps, si < gaph.count {
                    gaps.append(gaph[si])
                } else {
                    gaps.append(0.04)
                }
                pointTimes.append(g.pointTimes.flatMap { si < $0.count ? $0[si] : nil }
                    ?? Array(repeating: 0, count: pts.count))
                forces.append(g.forces.flatMap { si < $0.count ? $0[si] : nil }
                    ?? Array(repeating: 0, count: pts.count))
                altitudes.append(g.altitudes.flatMap { si < $0.count ? $0[si] : nil }
                    ?? Array(repeating: 0, count: pts.count))
                azimuths.append(g.azimuths.flatMap { si < $0.count ? $0[si] : nil }
                    ?? Array(repeating: 0, count: pts.count))
            }
            x += g.width + spacing
        }

        let packed = PersonalGlyph(width: max(0.3, x - spacing),
                                   strokes: strokes,
                                   widths: widths,
                                   durations: durations,
                                   gaps: gaps,
                                   refSize: refSize,
                                   pointTimes: pointTimes, forces: forces,
                                   altitudes: altitudes, azimuths: azimuths,
                                   inputSource: aligned.compactMap { $0.1.inputSource }.first,
                                   quality: aligned.compactMap { $0.1.quality }.min())
        return GlyphAlign.reseat(packed)
    }

    /// Adds a signature-space displacement back onto the glyph's native strokes.
    static func applyDisplacement(to glyph: PersonalGlyph,
                                  delta: [Double],
                                  strength: CGFloat) -> PersonalGlyph {
        // Build the same ribbon indexing as signature(), then scatter delta onto points.
        struct Node { var stroke: Int; var point: Int; var cum: CGFloat }
        var nodes: [Node] = []
        var cum: CGFloat = 0
        var last: CGPoint?

        for (si, pts) in glyph.strokes.enumerated() {
            for (pi, p) in pts.enumerated() {
                if let l = last {
                    cum += hypot(p.x - l.x, p.y - l.y)
                }
                nodes.append(Node(stroke: si, point: pi, cum: cum))
                last = p
            }
        }
        guard let total = nodes.last?.cum, total > 1e-4, !nodes.isEmpty else { return glyph }

        var newStrokes = glyph.strokes
        var newWidths = glyph.widths ?? glyph.strokes.map { Array(repeating: CGFloat(0.12), count: $0.count) }

        for node in nodes {
            let t = node.cum / total
            let f = t * CGFloat(sampleCount - 1)
            let i0 = Int(f)
            let i1 = min(i0 + 1, sampleCount - 1)
            let u = f - CGFloat(i0)

            func sampleDelta(_ channel: Int) -> CGFloat {
                let a = delta[i0 * 3 + channel]
                let b = delta[i1 * 3 + channel]
                return CGFloat(a + (b - a) * Double(u)) * strength
            }

            // Signature was box-normalized; scale displacement by glyph size.
            // Vertical channel is heavily damped — VAE style should not yank
            // letters off the baseline (that caused the up/down look).
            let scale = max(glyph.width, 1.0)
            let dx = max(-0.16, min(0.16, sampleDelta(0) * scale * 0.45))
            let dy = max(-0.07, min(0.07, sampleDelta(1) * scale * 0.14))
            let dw = max(-0.035, min(0.035, sampleDelta(2) * 0.28))

            var p = newStrokes[node.stroke][node.point]
            p.x += dx
            p.y += dy
            newStrokes[node.stroke][node.point] = p

            if node.point < newWidths[node.stroke].count {
                newWidths[node.stroke][node.point] = max(0.04, newWidths[node.stroke][node.point] + dw)
            }
        }

        // Mild slant morph from average dx/dy tendency in delta (extra style glue).
        var slantPush: CGFloat = 0
        for s in 0..<sampleCount {
            slantPush += CGFloat(delta[s * 3]) // x channel
        }
        slantPush = (slantPush / CGFloat(sampleCount)) * strength * 0.15
        if abs(slantPush) > 0.001 {
            for si in 0..<newStrokes.count {
                for pi in 0..<newStrokes[si].count {
                    newStrokes[si][pi].x += newStrokes[si][pi].y * slantPush
                }
            }
        }

        var width = glyph.width
        let allX = newStrokes.flatMap { $0.map(\.x) }
        if let minX = allX.min(), let maxX = allX.max() {
            // Re-base to x≥0 and update width.
            let shift = minX
            if abs(shift) > 0.001 {
                for si in 0..<newStrokes.count {
                    for pi in 0..<newStrokes[si].count {
                        newStrokes[si][pi].x -= shift
                    }
                }
            }
            width = max(0.25, maxX - minX)
        }

        let result = PersonalGlyph(width: width, strokes: newStrokes, widths: newWidths,
                                   durations: glyph.durations, gaps: glyph.gaps,
                                   refSize: glyph.refSize, pointTimes: glyph.pointTimes,
                                   forces: glyph.forces, altitudes: glyph.altitudes,
                                   azimuths: glyph.azimuths, inputSource: glyph.inputSource,
                                   quality: (glyph.quality ?? 0.6) * 0.95)
        guard PersonalFontStore.isValid(result) else { return glyph }
        return GlyphAlign.reseat(result)
    }

    // MARK: - PCA fit (power iteration on covariance)

    private func refitIfNeeded() {
        guard recentSignatures.count >= Self.minCorpus else { return }
        let n = recentSignatures.count
        let d = Self.dims

        // Mean
        var mu = [Double](repeating: 0, count: d)
        for sig in recentSignatures {
            for i in 0..<d { mu[i] += sig[i] }
        }
        for i in 0..<d { mu[i] /= Double(n) }
        mean = mu

        // Centered data
        var centered = recentSignatures.map { sig -> [Double] in
            zip(sig, mu).map { $0 - $1 }
        }

        var comps: [[Double]] = []
        var variances: [Double] = []

        for _ in 0..<Self.latentDim {
            var v = (0..<d).map { _ in Double.random(in: -1...1) }
            normalize(&v)

            // Power iteration
            for _ in 0..<24 {
                var w = [Double](repeating: 0, count: d)
                for row in centered {
                    let dot = zip(row, v).reduce(0) { $0 + $1.0 * $1.1 }
                    for i in 0..<d { w[i] += row[i] * dot }
                }
                // Deflate against previous components
                for c in comps {
                    let proj = zip(w, c).reduce(0) { $0 + $1.0 * $1.1 }
                    for i in 0..<d { w[i] -= proj * c[i] }
                }
                normalize(&w)
                v = w
            }

            // Variance along v
            var varAcc = 0.0
            for row in centered {
                let dot = zip(row, v).reduce(0) { $0 + $1.0 * $1.1 }
                varAcc += dot * dot
            }
            varAcc /= Double(max(1, n - 1))
            comps.append(v)
            variances.append(max(1e-6, varAcc))

            // Deflate data
            centered = centered.map { row in
                let dot = zip(row, v).reduce(0) { $0 + $1.0 * $1.1 }
                return zip(row, v).map { $0 - dot * $1 }
            }
        }

        components = comps

        // Latent stats over corpus
        var zs: [[Double]] = []
        for sig in recentSignatures {
            var z = [Double](repeating: 0, count: Self.latentDim)
            for k in 0..<Self.latentDim {
                var sum = 0.0
                for i in 0..<d { sum += (sig[i] - mean[i]) * comps[k][i] }
                z[k] = sum
            }
            zs.append(z)
        }
        latentMean = [Double](repeating: 0, count: Self.latentDim)
        latentStd = [Double](repeating: 0.15, count: Self.latentDim)
        guard !zs.isEmpty else { return }
        for k in 0..<Self.latentDim {
            let col = zs.map { $0[k] }
            let m = col.reduce(0, +) / Double(col.count)
            latentMean[k] = m
            let v = col.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(max(1, col.count - 1))
            latentStd[k] = max(0.05, sqrt(v))
        }

        // Refresh word latents with new basis
        // (keep keys; values updated lazily on next observe — OK)
    }

    private func normalize(_ v: inout [Double]) {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        if norm > 1e-12 {
            for i in 0..<v.count { v[i] /= norm }
        }
    }

    // MARK: - Persistence

    private let saver = DebouncedSaver()

    private func save() {
        let payload = Persist(mean: mean, components: components,
                              latentMean: latentMean, latentStd: latentStd,
                              corpus: corpus, recent: recentSignatures,
                              wordLatents: wordLatents)
        let url = fileURL
        saver.schedule {
            DebouncedSaver.write(payload, to: url, label: "StrokeVAE")
        }
    }

    private func load() {
        guard let raw = try? Data(contentsOf: fileURL),
              let p = try? JSONDecoder().decode(Persist.self, from: raw) else { return }
        guard p.mean.count == Self.dims else { return }
        mean = p.mean
        components = p.components
        latentMean = p.latentMean
        latentStd = p.latentStd
        corpus = p.corpus
        recentSignatures = p.recent
        wordLatents = p.wordLatents
        if components.count != Self.latentDim || !isReady {
            refitIfNeeded()
        }
    }
}
