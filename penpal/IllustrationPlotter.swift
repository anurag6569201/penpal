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

    static func strokes(
        from planned: [PenpalAPI.Illustration.Stroke],
        in frame: CGRect
    ) -> [InkStroke] {
        guard frame.width > 40, frame.height > 40 else { return [] }

        return planned.enumerated().compactMap { index, stroke in
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

            let dense = densify(projected, maximumStep: 12)
            let points = humanized(dense, phase: Double(index) * 1.618)
            guard points.count > 1 else { return nil }

            var ink = InkStroke(points: points)
            let length = zip(points, points.dropFirst()).reduce(CGFloat.zero) {
                $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)
            }
            // Deliberately time-lapsed: the tracing motion remains visible,
            // but a detailed sketch does not take several minutes.
            ink.duration = min(0.55, max(0.10, Double(length / 900)))
            ink.pauseBefore = index == 0 ? 0 : 0.025
            ink.source = .letters
            ink.confidence = stroke.role == "outline" ? 0.95 : 0.88
            return ink
        }
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

    /// A low-frequency perpendicular drift. Endpoints stay fixed so separate
    /// model-planned strokes still meet where intended.
    private static func humanized(_ points: [CGPoint],
                                  phase: Double) -> [CGPoint] {
        guard points.count > 3 else { return points }
        return points.enumerated().map { index, point in
            let before = points[max(0, index - 1)]
            let after = points[min(points.count - 1, index + 1)]
            let dx = after.x - before.x
            let dy = after.y - before.y
            let length = max(0.001, hypot(dx, dy))
            let t = Double(index) / Double(points.count - 1)
            let envelope = sin(t * .pi)
            let drift = sin(t * 5.5 * .pi + phase) * envelope * 0.7
            return CGPoint(
                x: point.x - dy / length * CGFloat(drift),
                y: point.y + dx / length * CGFloat(drift)
            )
        }
    }
}
