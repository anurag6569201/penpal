//
//  SigmaLognormal.swift
//  penpal
//
//  Kinematic retiming inspired by Plamondon's sigma-lognormal model
//  (kinematic theory of rapid human movements): a pen stroke's velocity
//  profile is a sum of lognormal-shaped primitives, one per ballistic
//  sub-movement, separated by velocity valleys.
//
//  This lightweight pass keeps the captured GEOMETRY exactly and reworks
//  only TIME per render:
//   1. smooth the captured velocity profile (removes sensor timing noise),
//   2. segment it at velocity valleys — each segment ≈ one primitive,
//   3. perturb each segment's duration by a lognormal factor, plus a small
//      whole-stroke tempo wobble, and rebuild the cumulative point times.
//
//  Result: replay never repeats exact timing, slow-in-curves / fast-on-
//  straights covariation survives, and animation reads as a human pen
//  rather than a recording.
//

import Foundation
import CoreGraphics

enum SigmaLognormal {

    /// Returns a copy of the glyph with humanized per-render timing.
    /// `variability` ~0.4…1.2 scales how far timing may wander.
    static func retime(_ g: PersonalGlyph, variability: CGFloat) -> PersonalGlyph {
        guard let allTimes = g.pointTimes, !allTimes.isEmpty else { return g }
        let vary = Double(min(1.4, max(0.1, variability)))

        var newTimes: [[Double]] = []
        var newDurations = g.durations
        var changed = false

        for (si, pts) in g.strokes.enumerated() {
            guard si < allTimes.count else {
                newTimes.append(si < allTimes.count ? allTimes[si] : [])
                continue
            }
            let times = allTimes[si]
            guard pts.count >= 6, times.count == pts.count,
                  (times.last ?? 0) - (times.first ?? 0) > 0.03 else {
                newTimes.append(times)
                continue
            }

            // Per-segment distances and captured dts.
            var dists: [Double] = []
            var dts: [Double] = []
            for j in 1..<pts.count {
                dists.append(Double(hypot(pts[j].x - pts[j - 1].x,
                                          pts[j].y - pts[j - 1].y)))
                dts.append(max(1e-4, times[j] - times[j - 1]))
            }

            // Velocity profile, then 3-tap smoothing.
            var speeds = zip(dists, dts).map { max(1e-4, $0 / $1) }
            if speeds.count >= 3 {
                var smoothed = speeds
                for j in 1..<(speeds.count - 1) {
                    smoothed[j] = (speeds[j - 1] + speeds[j] + speeds[j + 1]) / 3
                }
                speeds = smoothed
            }

            // Blend captured timing 30% toward the smoothed profile — keeps
            // the kinematics, drops the jitter.
            for j in 0..<dts.count {
                let smoothDt = dists[j] / speeds[j]
                dts[j] = dts[j] * 0.7 + smoothDt * 0.3
            }

            // Segment at velocity valleys (≈ lognormal primitive boundaries).
            var boundaries: [Int] = [0]
            if speeds.count >= 5 {
                for j in 2..<(speeds.count - 2) {
                    let isValley = speeds[j] <= speeds[j - 1]
                        && speeds[j] <= speeds[j + 1]
                        && speeds[j] < 0.75 * max(speeds[j - 2], speeds[j + 2])
                    if isValley, j - (boundaries.last ?? 0) >= 3 {
                        boundaries.append(j)
                    }
                }
            }
            boundaries.append(dts.count)

            // Lognormal duration perturbation per primitive + global tempo.
            let global = exp(randn() * 0.05 * vary)
            for k in 0..<(boundaries.count - 1) {
                let factor = exp(randn() * 0.09 * vary) * global
                for j in boundaries[k]..<boundaries[k + 1] {
                    dts[j] *= factor
                }
            }

            var t = 0.0
            var rebuilt: [Double] = [0]
            for dt in dts {
                t += dt
                rebuilt.append(t)
            }
            newTimes.append(rebuilt)
            if newDurations != nil, si < newDurations!.count {
                newDurations![si] = t
            }
            changed = true
        }

        guard changed else { return g }

        var result = g
        result.pointTimes = newTimes
        result.durations = newDurations
        // Pen-lift pauses breathe too (never below a plausible floor).
        if let gaps = g.gaps {
            result.gaps = gaps.map { gap in
                gap <= 0.001 ? gap
                    : min(2, max(0.01, gap * exp(randn() * 0.15 * vary)))
            }
        }
        return result
    }

    private static func randn() -> Double {
        let u1 = Double.random(in: 1e-12...1)
        let u2 = Double.random(in: 0...1)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}
