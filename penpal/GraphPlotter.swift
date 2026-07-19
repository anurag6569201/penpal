//
//  GraphPlotter.swift
//  penpal
//
//  PEN-17 — graphing, drawn as ink.
//
//  The rule from the backlog, kept: a crisp vector plot would look pasted in
//  and break the paper illusion. A graph here is something Penpal DRAWS, with
//  the same pen, the same slight imprecision, and the same left-to-right
//  motion a person uses. So this produces `InkStroke`s for the existing
//  handwriting renderer rather than a chart view.
//
//  Everything is on-device (`MathEvaluator`). Plotting is interactive — the
//  curve should appear as fast as the pen can draw it, and a network round
//  trip would make it feel like a document loading instead of someone
//  sketching.
//

import CoreGraphics
import Foundation

enum GraphPlotter {

    /// A plotted function ready to be inked.
    struct Plot {
        var axes: [InkStroke]
        var curve: [InkStroke]
        var labels: [(text: String, at: CGPoint)]
        /// Everything, in draw order: axes first, then the curve.
        var strokes: [InkStroke] { axes + curve }
    }

    /// Recognises "y = ...", "plot ...", "graph ..." and returns the body.
    static func functionBody(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        for prefix in ["plot ", "graph ", "sketch "] where lowered.hasPrefix(prefix) {
            var body = String(trimmed.dropFirst(prefix.count))
            if body.lowercased().hasPrefix("y =") { body = String(body.dropFirst(3)) }
            else if body.lowercased().hasPrefix("y=") { body = String(body.dropFirst(2)) }
            return body.trimmingCharacters(in: .whitespaces)
        }
        if lowered.hasPrefix("y =") || lowered.hasPrefix("y=") {
            let body = trimmed.drop { $0 != "=" }.dropFirst()
            return body.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Samples `body` over `xRange` and lays out a hand-drawn plot inside
    /// `frame`. Returns nil when the expression never evaluates — better no
    /// graph than a misleading one.
    static func plot(_ body: String,
                     in frame: CGRect,
                     xRange: ClosedRange<Double> = -10...10,
                     samples: Int = 220) -> Plot? {
        guard frame.width > 40, frame.height > 40 else { return nil }

        // 1. Sample into segments. Two things break a segment:
        //
        //    a) the expression doesn't evaluate (log of a negative, √ of a
        //       negative) — the function simply isn't defined there;
        //    b) the value JUMPS. This is the one that matters and the one a
        //       naive plotter gets wrong: sample points never land exactly on
        //       a pole, so 1/x evaluates fine either side of zero (±22 at the
        //       nearest samples) and the curve gets drawn straight through the
        //       asymptote. That line is a drawn lie — it asserts the function
        //       passes through values it never takes. Detecting the jump is
        //       what makes the pen lift where a person's would.
        var segments: [[(x: Double, y: Double)]] = []
        var current: [(x: Double, y: Double)] = []
        let step = (xRange.upperBound - xRange.lowerBound) / Double(samples - 1)

        var raw: [(x: Double, y: Double)?] = []
        for i in 0..<samples {
            let x = xRange.lowerBound + Double(i) * step
            if let y = value(of: body, at: x), y.isFinite, abs(y) < 1e9 {
                raw.append((x, y))
            } else {
                raw.append(nil)
            }
        }

        // A "large" jump is relative to the function's own typical spread, so
        // this works for sin (range 2) and for x^2 (range 100) alike.
        let defined = raw.compactMap { $0?.y }.sorted()
        guard defined.count > 2 else { return nil }
        let spread = max(1e-9, quantile(defined, 0.9) - quantile(defined, 0.1))
        let jumpLimit = spread * 1.5

        for sample in raw {
            guard let sample else {
                if current.count > 1 { segments.append(current) }
                current = []
                continue
            }
            if let last = current.last, abs(sample.y - last.y) > jumpLimit {
                // Discontinuity: end the stroke here and start a new one.
                if current.count > 1 { segments.append(current) }
                current = [sample]
                continue
            }
            current.append(sample)
        }
        if current.count > 1 { segments.append(current) }
        guard !segments.isEmpty else { return nil }

        // 2. Vertical window: fit the data, but stay sane near an asymptote by
        //    using a central quantile rather than the extremes.
        let ys = segments.flatMap { $0.map(\.y) }.sorted()
        let lowY = quantile(ys, 0.02)
        let highY = quantile(ys, 0.98)
        var yMin = min(lowY, 0)
        var yMax = max(highY, 0)
        if yMax - yMin < 1e-6 { yMin -= 1; yMax += 1 }
        let pad = (yMax - yMin) * 0.1
        yMin -= pad
        yMax += pad

        func project(_ x: Double, _ y: Double) -> CGPoint {
            let tx = (x - xRange.lowerBound) / (xRange.upperBound - xRange.lowerBound)
            let ty = (y - yMin) / (yMax - yMin)
            return CGPoint(x: frame.minX + CGFloat(tx) * frame.width,
                           y: frame.maxY - CGFloat(ty) * frame.height)
        }

        // 3. Axes, drawn with the same wobble as everything else.
        let originY = project(0, 0).y
        let originX = project(0, 0).x
        var axes: [InkStroke] = []
        if frame.minY...frame.maxY ~= originY {
            axes.append(handDrawnLine(from: CGPoint(x: frame.minX, y: originY),
                                      to: CGPoint(x: frame.maxX, y: originY)))
        }
        if frame.minX...frame.maxX ~= originX {
            axes.append(handDrawnLine(from: CGPoint(x: originX, y: frame.minY),
                                      to: CGPoint(x: originX, y: frame.maxY)))
        }

        // 4. The curve. Each segment is one stroke, so the pen lifts at a
        //    discontinuity exactly as a person's would.
        let curve: [InkStroke] = segments.compactMap { segment in
            let points = segment.map { project($0.x, $0.y) }
                .filter { $0.y >= frame.minY - 40 && $0.y <= frame.maxY + 40 }
            guard points.count > 1 else { return nil }
            var stroke = InkStroke(points: wobble(points))
            // Drawn briskly, like a swept curve rather than careful lettering.
            stroke.duration = 0.5 + Double(points.count) * 0.002
            stroke.source = .letters
            stroke.confidence = 0.9
            return stroke
        }
        guard !curve.isEmpty else { return nil }

        let labels: [(String, CGPoint)] = [
            (format(xRange.upperBound), CGPoint(x: frame.maxX - 12, y: originY + 16)),
            (format(yMax), CGPoint(x: originX + 8, y: frame.minY + 12)),
        ]
        return Plot(axes: axes, curve: curve, labels: labels)
    }

    // MARK: - Helpers

    /// Evaluates the body with `x` substituted, via the on-device evaluator.
    private static func value(of body: String, at x: Double) -> Double? {
        // Bracket negatives so "x^2" at x = -3 doesn't parse as subtraction.
        let substituted = body.replacingOccurrences(
            of: "x", with: x < 0 ? "(\(x))" : "\(x)")
        return MathEvaluator.evaluate(MathEvaluator.normalize(substituted))
    }

    /// Slight, smooth deviation so the curve reads as drawn, not printed.
    /// Low-frequency (not per-point noise) — jitter would look like a shaky
    /// hand rather than a confident sweep.
    private static func wobble(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 3 else { return points }
        let amplitude: CGFloat = 0.9
        let phase = Double.random(in: 0...(2 * .pi))
        return points.enumerated().map { index, point in
            let t = Double(index) / Double(points.count)
            let offset = sin(t * 5.5 * .pi + phase) * Double(amplitude)
            return CGPoint(x: point.x, y: point.y + CGFloat(offset))
        }
    }

    private static func handDrawnLine(from a: CGPoint, to b: CGPoint) -> InkStroke {
        let steps = max(8, Int(hypot(b.x - a.x, b.y - a.y) / 12))
        let points = (0...steps).map { i -> CGPoint in
            let t = CGFloat(i) / CGFloat(steps)
            let drift = sin(Double(t) * 3.1) * 0.7
            return CGPoint(x: a.x + (b.x - a.x) * t,
                           y: a.y + (b.y - a.y) * t + CGFloat(drift))
        }
        var stroke = InkStroke(points: points)
        stroke.duration = 0.35
        stroke.source = .letters
        stroke.confidence = 0.9
        return stroke
    }

    private static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let t = min(1, max(0, q)) * Double(sorted.count - 1)
        let i = Int(t)
        let f = t - Double(i)
        return i + 1 < sorted.count ? sorted[i] * (1 - f) + sorted[i + 1] * f
                                    : sorted[i]
    }

    private static func format(_ value: Double) -> String {
        abs(value.rounded() - value) < 0.05
            ? String(Int(value.rounded()))
            : String(format: "%.1f", value)
    }
}
