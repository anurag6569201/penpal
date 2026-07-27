//
//  IllustrationPlotter.swift
//  penpal
//
//  PEN-36 — maps the brain's clean, normalised line-art plan into the same
//  slightly imperfect InkStroke geometry used by graphs and handwriting.
//

import CoreGraphics
import Foundation

enum IllustrationPlotter {

    private struct Candidate {
        var role: String
        var points: [CGPoint]
        let sourceIndex: Int
    }

    /// Use the available note width while preserving the source canvas shape.
    /// Tall art grows down the scrollable page instead of being squeezed square.
    static func drawingFrame(
        origin: CGPoint,
        maxWidth: CGFloat,
        aspectRatio: CGFloat
    ) -> CGRect {
        let width = max(0, maxWidth)
        let safeRatio = aspectRatio.isFinite
            ? min(4, max(0.25, aspectRatio))
            : 1
        return CGRect(
            x: origin.x,
            y: origin.y,
            width: width,
            height: width / safeRatio
        )
    }

    static func strokes(
        from planned: [PenpalAPI.Illustration.Stroke],
        in frame: CGRect,
        baseWidth: CGFloat = 1.5
    ) -> [InkStroke] {
        guard frame.width > 40, frame.height > 40 else { return [] }

        let candidates = planned.enumerated().compactMap { index, stroke -> Candidate? in
            let projected = stroke.points.compactMap { pair -> CGPoint? in
                guard pair.count == 2,
                      pair[0].isFinite, pair[1].isFinite,
                      0...1 ~= pair[0], 0...1 ~= pair[1] else { return nil }
                return CGPoint(
                    x: frame.minX + CGFloat(pair[0]) * frame.width,
                    y: frame.minY + CGFloat(pair[1]) * frame.height
                )
            }
            guard projected.count > 1 else { return nil }
            return Candidate(role: stroke.role, points: projected, sourceIndex: index)
        }

        let ordered = humanOrder(candidates)
        var result: [InkStroke] = []
        var previousEnd: CGPoint?
        var previousRole: String?

        for (index, candidate) in ordered.enumerated() {
            let dense = densify(candidate.points, maximumStep: 9)
            let seed = Double(candidate.sourceIndex) * 1.618 + 0.37
            let points = humanized(dense, seed: seed)
            guard points.count > 1 else { continue }

            var ink = InkStroke(
                points: points,
                widths: pressureProfile(points, baseWidth: baseWidth, seed: seed)
            )
            ink.duration = drawingDuration(points, role: candidate.role)
            ink.pauseBefore = naturalPause(
                from: previousEnd,
                to: points.first,
                changedRole: previousRole != nil && previousRole != candidate.role,
                seed: seed
            )
            ink.source = .letters
            ink.confidence = candidate.role == "outline" ? 0.95 : 0.88
            result.append(ink)
            previousEnd = points.last
            previousRole = candidate.role
        }
        return result
    }

    /// Preserve the model's outline-before-detail intent, but draw each group
    /// like a hand: choose the nearest next path and reverse it when its far end
    /// is closer. The visible pen no longer teleports around the illustration.
    private static func humanOrder(_ candidates: [Candidate]) -> [Candidate] {
        let outlines = candidates.filter { $0.role == "outline" }
        let details = candidates.filter { $0.role != "outline" }
        let orderedOutlines = nearestOrder(outlines, startingAt: nil)
        return orderedOutlines + nearestOrder(
            details,
            startingAt: orderedOutlines.last?.points.last
        )
    }

    private static func nearestOrder(
        _ input: [Candidate],
        startingAt start: CGPoint?
    ) -> [Candidate] {
        guard !input.isEmpty else { return [] }
        var pending = input
        var ordered: [Candidate] = []
        var cursor = start

        while !pending.isEmpty {
            if cursor == nil {
                let first = pending.removeFirst()
                ordered.append(first)
                cursor = first.points.last
                continue
            }
            guard let current = cursor else { break }

            var bestIndex = 0
            var reverse = false
            var bestDistance = CGFloat.greatestFiniteMagnitude
            for (index, candidate) in pending.enumerated() {
                guard let first = candidate.points.first,
                      let last = candidate.points.last else { continue }
                let toFirst = distance(current, first)
                let toLast = distance(current, last)
                if min(toFirst, toLast) < bestDistance {
                    bestDistance = min(toFirst, toLast)
                    bestIndex = index
                    reverse = toLast < toFirst
                }
            }

            var next = pending.remove(at: bestIndex)
            if reverse { next.points.reverse() }
            ordered.append(next)
            cursor = next.points.last
        }
        return ordered
    }

    private static func densify(_ points: [CGPoint],
                                maximumStep: CGFloat) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var result = [first]
        for (a, b) in zip(points, points.dropFirst()) {
            let distance = hypot(b.x - a.x, b.y - a.y)
            let steps = max(1, Int(ceil(distance / maximumStep)))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                result.append(CGPoint(
                    x: a.x + (b.x - a.x) * t,
                    y: a.y + (b.y - a.y) * t
                ))
            }
        }
        return result
    }

    /// Smooth deterministic value noise rather than a repeating sine wobble.
    /// Endpoints stay fixed so separate planned strokes still meet.
    private static func humanized(_ points: [CGPoint],
                                  seed: Double) -> [CGPoint] {
        guard points.count > 3 else { return points }
        return points.enumerated().map { index, point in
            let before = points[max(0, index - 1)]
            let after = points[min(points.count - 1, index + 1)]
            let dx = after.x - before.x
            let dy = after.y - before.y
            let length = max(0.001, hypot(dx, dy))
            let t = Double(index) / Double(points.count - 1)
            let envelope = sin(t * .pi)
            let drift = smoothNoise(at: t * 6, seed: seed) * envelope * 0.65
            return CGPoint(
                x: point.x - dy / length * CGFloat(drift),
                y: point.y + dx / length * CGFloat(drift)
            )
        }
    }

    private static func drawingDuration(_ points: [CGPoint], role: String) -> Double {
        let length = zip(points, points.dropFirst()).reduce(CGFloat.zero) {
            $0 + distance($1.0, $1.1)
        }
        let turns = points.indices.dropFirst().dropLast().reduce(CGFloat.zero) {
            $0 + turnAngle(points[$1 - 1], points[$1], points[$1 + 1])
        }
        let averageTurn = turns / CGFloat(max(1, points.count - 2))
        let carefulness = 1 + Double(averageTurn / .pi) * 0.65
        let speed: Double = role == "outline" ? 610 : 500
        // Still time-lapsed for dense art, but details and bends receive enough
        // time for the pen tip to look deliberate instead of machine-plotted.
        return min(0.95, max(0.11, Double(length) / speed * carefulness))
    }

    private static func naturalPause(
        from previous: CGPoint?,
        to next: CGPoint?,
        changedRole: Bool,
        seed: Double
    ) -> Double {
        guard let previous, let next else { return 0 }
        let travel = distance(previous, next)
        let base: Double
        if travel < 5 {
            base = 0.018
        } else if travel < 30 {
            base = 0.035 + Double(travel) / 1_500
        } else {
            base = min(0.22, 0.075 + Double(travel) / 1_200)
        }
        let rolePause = changedRole ? 0.12 : 0
        let jitter = 0.88 + 0.24 * unitNoise(seed: seed, index: 17)
        return max(rolePause, base * jitter)
    }

    /// Subtle set-down/lift-off taper plus correlated pressure variation.
    private static func pressureProfile(
        _ points: [CGPoint],
        baseWidth: CGFloat,
        seed: Double
    ) -> [CGFloat] {
        let target = max(3.2, baseWidth * 1.9)
        return points.indices.map { index in
            let t = CGFloat(index) / CGFloat(max(1, points.count - 1))
            let edge = 0.82 + 0.18 * sin(t * .pi)
            let pressureNoise = 0.96 + 0.08 * CGFloat(
                smoothNoise(at: Double(t) * 5, seed: seed + 9.7)
            )
            let turn = index > 0 && index + 1 < points.count
                ? turnAngle(points[index - 1], points[index], points[index + 1])
                : 0
            let cornerRelease = 1 - min(0.08, turn / .pi * 0.08)
            return max(2.5, target * edge * pressureNoise * cornerRelease)
        }
    }

    private static func smoothNoise(at position: Double, seed: Double) -> Double {
        let lower = Int(floor(position))
        let fraction = position - Double(lower)
        let smooth = fraction * fraction * (3 - 2 * fraction)
        let a = unitNoise(seed: seed, index: lower) * 2 - 1
        let b = unitNoise(seed: seed, index: lower + 1) * 2 - 1
        return a + (b - a) * smooth
    }

    private static func unitNoise(seed: Double, index: Int) -> Double {
        let raw = sin(seed * 12.9898 + Double(index) * 78.233) * 43_758.5453
        return raw - floor(raw)
    }

    private static func turnAngle(
        _ a: CGPoint,
        _ b: CGPoint,
        _ c: CGPoint
    ) -> CGFloat {
        let ux = b.x - a.x, uy = b.y - a.y
        let vx = c.x - b.x, vy = c.y - b.y
        let lu = hypot(ux, uy), lv = hypot(vx, vy)
        guard lu > 0.0001, lv > 0.0001 else { return 0 }
        let dot = max(-1, min(1, (ux * vx + uy * vy) / (lu * lv)))
        return acos(dot)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }
}
