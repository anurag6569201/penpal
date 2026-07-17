//
//  GlyphPDM.swift
//  penpal
//
//  Point Distribution Model (Cootes' Active Shape Model) over a letter's
//  trained variants. Instead of picking one of ≤3 stored shapes — which makes
//  repeated letters look cloned — we align the variants, extract their mean
//  shape and principal variation modes, and SAMPLE a fresh in-distribution
//  shape every render. Two samples already give continuous variation.
//
//  Variants are captured pre-aligned (shared baseline / x-height), so the
//  Procrustes step reduces to the index-based point correspondence below.
//

import Foundation
import CoreGraphics

final class GlyphPDM {

    static let shared = GlyphPDM()

    /// Correspondence points per (non-dot) stroke.
    private static let pointsPerStroke = 18
    /// How boldly to sample the modes; 0.5 stays well inside the training hull.
    private static let sampleSpread: CGFloat = 0.5

    private struct Model {
        var memberIndexes: [Int]      // variant indices sharing the topology
        var dotFlags: [Bool]          // per stroke: is it a single-point dot?
        var mean: [CGFloat]           // flattened non-dot coordinates
        var modes: [[CGFloat]]        // orthonormal variation modes
        var stds: [CGFloat]           // std of the training set along each mode
        var dotMeans: [CGPoint]       // mean position per dot stroke
    }

    /// `nil` cached means "these variants can't form a PDM" — don't retry.
    private var cache: [String: Model?] = [:]

    func invalidate(_ key: String) { cache.removeValue(forKey: key) }
    func invalidateAll() { cache.removeAll() }

    /// A freshly sampled variation of the letter, or nil to fall back to
    /// discrete variant picking.
    func sample(key: String, variants: [PersonalGlyph]) -> PersonalGlyph? {
        guard variants.count >= 2 else { return nil }
        let model: Model?
        if let cached = cache[key] {
            model = cached
        } else {
            model = Self.build(variants)
            cache[key] = model
        }
        guard let model else { return nil }
        return Self.generate(from: model, variants: variants)
    }

    // MARK: - Model fitting

    private static func build(_ variants: [PersonalGlyph]) -> Model? {
        // Largest group of variants sharing stroke count and dot layout.
        var groups: [Int: [Int]] = [:]
        for (i, g) in variants.enumerated() {
            groups[g.strokes.count, default: []].append(i)
        }
        guard let candidates = groups.values.max(by: { $0.count < $1.count }),
              candidates.count >= 2,
              let first = candidates.first else { return nil }

        let dotFlags = variants[first].strokes.map { $0.count == 1 }
        let members = candidates.filter { idx in
            variants[idx].strokes.map { $0.count == 1 } == dotFlags
        }
        guard members.count >= 2 else { return nil }

        // Flattened correspondence vectors.
        var vectors: [[CGFloat]] = []
        for idx in members {
            var v: [CGFloat] = []
            for (si, pts) in variants[idx].strokes.enumerated() where !dotFlags[si] {
                for p in resample(pts, to: pointsPerStroke) {
                    v.append(p.x)
                    v.append(p.y)
                }
            }
            vectors.append(v)
        }
        let dims = vectors[0].count
        guard dims > 0, vectors.allSatisfy({ $0.count == dims }) else { return nil }

        var mean = [CGFloat](repeating: 0, count: dims)
        for v in vectors {
            for i in 0..<dims { mean[i] += v[i] }
        }
        for i in 0..<dims { mean[i] /= CGFloat(vectors.count) }

        // With n ≤ 3 samples, Gram–Schmidt over the deviation vectors IS the
        // exact PCA basis (at most n−1 nonzero modes).
        var modes: [[CGFloat]] = []
        var stds: [CGFloat] = []
        for v in vectors {
            var dev = (0..<dims).map { v[$0] - mean[$0] }
            for m in modes {
                let proj = zip(dev, m).reduce(0) { $0 + $1.0 * $1.1 }
                for i in 0..<dims { dev[i] -= proj * m[i] }
            }
            let norm = sqrt(dev.reduce(0) { $0 + $1 * $1 })
            guard norm > 0.02, modes.count < 2 else { continue }
            modes.append(dev.map { $0 / norm })
            stds.append(norm / sqrt(CGFloat(max(1, vectors.count - 1))))
        }
        guard !modes.isEmpty else { return nil }

        var dotMeans: [CGPoint] = []
        for (si, isDot) in dotFlags.enumerated() where isDot {
            var cx: CGFloat = 0, cy: CGFloat = 0
            for idx in members {
                let p = variants[idx].strokes[si][0]
                cx += p.x
                cy += p.y
            }
            let n = CGFloat(members.count)
            dotMeans.append(CGPoint(x: cx / n, y: cy / n))
        }

        return Model(memberIndexes: members, dotFlags: dotFlags,
                     mean: mean, modes: modes, stds: stds, dotMeans: dotMeans)
    }

    // MARK: - Sampling

    private static func generate(from model: Model,
                                 variants: [PersonalGlyph]) -> PersonalGlyph? {
        // Shape = mean + Σ bₖ·φₖ with bₖ ~ N(0, σₖ)·spread, clamped in-hull.
        var x = model.mean
        for (k, mode) in model.modes.enumerated() {
            var b = CGFloat(randn()) * model.stds[k] * sampleSpread
            b = min(1.4 * model.stds[k], max(-1.4 * model.stds[k], b))
            for i in 0..<x.count { x[i] += b * mode[i] }
        }

        // Timing/pressure donor: a real variant from the topology group.
        guard let donorIdx = model.memberIndexes.randomElement() else { return nil }
        let donor = variants[donorIdx]
        let p = pointsPerStroke

        var strokes: [[CGPoint]] = []
        var widths: [[CGFloat]] = []
        var times: [[Double]] = []
        var cursor = 0
        var dotCursor = 0
        for (si, isDot) in model.dotFlags.enumerated() {
            if isDot {
                let c = model.dotMeans[dotCursor]
                dotCursor += 1
                strokes.append([CGPoint(x: c.x + CGFloat.random(in: -0.02...0.02),
                                        y: c.y + CGFloat.random(in: -0.02...0.02))])
                widths.append([donor.widths.flatMap {
                    si < $0.count ? $0[si].first : nil
                } ?? 0.12])
                times.append([donor.pointTimes.flatMap {
                    si < $0.count ? $0[si].last : nil
                } ?? 0])
                continue
            }
            var pts: [CGPoint] = []
            for _ in 0..<p {
                pts.append(CGPoint(x: x[cursor], y: x[cursor + 1]))
                cursor += 2
            }
            strokes.append(pts)
            let donorWidths = donor.widths.flatMap { si < $0.count ? $0[si] : nil }
                ?? [0.12]
            widths.append(resampleValues(donorWidths, to: p))
            let donorTimes = donor.pointTimes.flatMap { si < $0.count ? $0[si] : nil }
                ?? [0, 0.08]
            times.append(resampleValues(donorTimes.map { CGFloat($0) }, to: p)
                .map(Double.init))
        }

        let allX = strokes.flatMap { $0.map(\.x) }
        guard let lo = allX.min(), let hi = allX.max(), hi - lo > 0.03 else { return nil }

        let result = PersonalGlyph(width: hi - lo,
                                   strokes: strokes,
                                   widths: widths,
                                   durations: donor.durations,
                                   gaps: donor.gaps,
                                   refSize: donor.refSize,
                                   pointTimes: times,
                                   forces: nil, altitudes: nil, azimuths: nil,
                                   inputSource: donor.inputSource,
                                   quality: donor.quality)
        guard PersonalFontStore.isValid(result) else { return nil }
        return GlyphAlign.reseat(result)
    }

    // MARK: - Helpers

    /// Index-parameter linear resample (capture is distance-interpolated, so
    /// index ≈ arc length — good correspondence and it keeps time alignment).
    private static func resample(_ pts: [CGPoint], to count: Int) -> [CGPoint] {
        guard pts.count > 1 else {
            return Array(repeating: pts.first ?? .zero, count: count)
        }
        var out: [CGPoint] = []
        for i in 0..<count {
            let t = CGFloat(i) * CGFloat(pts.count - 1) / CGFloat(count - 1)
            let j = min(pts.count - 2, Int(t))
            let u = t - CGFloat(j)
            out.append(CGPoint(x: pts[j].x + (pts[j + 1].x - pts[j].x) * u,
                               y: pts[j].y + (pts[j + 1].y - pts[j].y) * u))
        }
        return out
    }

    private static func resampleValues(_ v: [CGFloat], to count: Int) -> [CGFloat] {
        guard v.count > 1 else {
            return Array(repeating: v.first ?? 0, count: count)
        }
        var out: [CGFloat] = []
        for i in 0..<count {
            let t = CGFloat(i) * CGFloat(v.count - 1) / CGFloat(count - 1)
            let j = min(v.count - 2, Int(t))
            let u = t - CGFloat(j)
            out.append(v[j] + (v[j + 1] - v[j]) * u)
        }
        return out
    }

    private static func randn() -> Double {
        let u1 = Double.random(in: 1e-12...1)
        let u2 = Double.random(in: 0...1)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}
