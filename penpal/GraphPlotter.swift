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
        /// Hand-drawn tick marks, arrowheads, axis labels, equation title, and intercept dots.
        var annotations: [InkStroke] = []
        var labels: [(text: String, at: CGPoint)]
        /// Everything, in draw order: axes first, then ticks/labels, then the curve.
        var strokes: [InkStroke] { axes + annotations + curve }
    }

    /// Recognises "y = ...", "f(x) = ...", "plot ...", "graph ..." and returns the body.
    static func functionBody(in text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("=") {
            trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else { return nil }

        func stripLHS(_ candidate: String) -> String? {
            let lower = candidate.lowercased()
            for prefix in ["y =", "y=", "f(x) =", "f(x)="] where lower.hasPrefix(prefix) {
                return String(candidate.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
            }
            return nil
        }

        let lowered = trimmed.lowercased()
        for prefix in ["plot ", "graph ", "sketch "] where lowered.hasPrefix(prefix) {
            let rest = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            if let rhs = stripLHS(rest) {
                return rhs.isEmpty ? nil : rhs
            }
            return rest.isEmpty ? nil : rest
        }
        if let rhs = stripLHS(trimmed) {
            return rhs.isEmpty ? nil : rhs
        }
        return nil
    }

    /// Extracts a plottable `f(x)` body from an arbitrary math expression or equation:
    /// - `"y = sin(x)"` → `"sin(x)"`
    /// - `"x^2 - 4"` → `"x^2 - 4"`
    /// - `"x^2 - 5x + 6 = 0"` → `"x^2 - 5x + 6"`
    /// - `"x^2 = 16"` → `"(x^2) - (16)"`
    /// Returns nil when the expression does not depend on `x` (or has other free variables).
    static func plottableExpression(from raw: String) -> String? {
        if let body = functionBody(in: raw), isPlottableInX(body) {
            return body
        }
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("=") {
            trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else { return nil }

        // Equation in x: "lhs = rhs" → plot "lhs - rhs" (or just "lhs" when rhs is 0).
        let parts = trimmed.split(separator: "=", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let candidate: String
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
            if parts[1] == "0" {
                candidate = parts[0]
            } else if parts[0] == "0" {
                candidate = parts[1]
            } else {
                candidate = "(\(parts[0])) - (\(parts[1]))"
            }
        } else if parts.count == 1 {
            candidate = trimmed
        } else {
            return nil
        }
        return isPlottableInX(candidate) ? candidate : nil
    }

    private static func isPlottableInX(_ body: String) -> Bool {
        // Must actually contain a standalone variable x / X.
        guard body.range(of: #"(?<![a-zA-Z])[xX](?![a-zA-Z])"#,
                         options: .regularExpression) != nil else { return false }
        // Must not contain other unknown free variables (like y, a, b).
        let test = body.replacingOccurrences(
            of: #"(?<![a-zA-Z])[xX](?![a-zA-Z])"#,
            with: "(1)",
            options: .regularExpression
        )
        guard !MathEvaluator.hasFreeVariable(test) else { return false }
        // Quick sanity probe at a few points so invalid syntax never offers Graph.
        let probes: [Double] = [0, 1, -1, 2, 0.5]
        return probes.contains { x in
            if let y = value(of: body, at: x), y.isFinite { return true }
            return false
        }
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

        // 3. Axes + arrowheads, drawn with the same wobble as everything else.
        let originY = project(0, 0).y
        let originX = project(0, 0).x
        var axes: [InkStroke] = []
        var annotations: [InkStroke] = []
        let arrow: CGFloat = 6.5

        if frame.minY...frame.maxY ~= originY {
            axes.append(handDrawnLine(from: CGPoint(x: frame.minX, y: originY),
                                      to: CGPoint(x: frame.maxX, y: originY)))
            // +x arrowhead
            annotations.append(handDrawnLine(from: CGPoint(x: frame.maxX - arrow, y: originY - arrow * 0.65),
                                             to: CGPoint(x: frame.maxX, y: originY), duration: 0.08))
            annotations.append(handDrawnLine(from: CGPoint(x: frame.maxX - arrow, y: originY + arrow * 0.65),
                                             to: CGPoint(x: frame.maxX, y: originY), duration: 0.08))
            // x-axis ticks
            let xTickStep = niceStep(for: xRange.upperBound - xRange.lowerBound, targetTicks: 5)
            var tx = ceil(xRange.lowerBound / xTickStep) * xTickStep
            while tx <= xRange.upperBound + 1e-9 {
                if abs(tx) > xTickStep * 0.15 {
                    let px = project(tx, 0).x
                    if px > frame.minX + 12 && px < frame.maxX - 16 {
                        annotations.append(handDrawnLine(from: CGPoint(x: px, y: originY - 3.5),
                                                         to: CGPoint(x: px, y: originY + 3.5),
                                                         duration: 0.05))
                    }
                }
                tx += xTickStep
            }
            annotations.append(contentsOf: inkLabel("x", at: CGPoint(x: frame.maxX - 8, y: originY - 8), size: 9))
        }
        if frame.minX...frame.maxX ~= originX {
            axes.append(handDrawnLine(from: CGPoint(x: originX, y: frame.minY),
                                      to: CGPoint(x: originX, y: frame.maxY)))
            // +y arrowhead
            annotations.append(handDrawnLine(from: CGPoint(x: originX - arrow * 0.65, y: frame.minY + arrow),
                                             to: CGPoint(x: originX, y: frame.minY), duration: 0.08))
            annotations.append(handDrawnLine(from: CGPoint(x: originX + arrow * 0.65, y: frame.minY + arrow),
                                             to: CGPoint(x: originX, y: frame.minY), duration: 0.08))
            // y-axis ticks
            let yTickStep = niceStep(for: yMax - yMin, targetTicks: 4)
            var ty = ceil(yMin / yTickStep) * yTickStep
            while ty <= yMax + 1e-9 {
                if abs(ty) > yTickStep * 0.15 {
                    let py = project(0, ty).y
                    if py > frame.minY + 14 && py < frame.maxY - 12 {
                        annotations.append(handDrawnLine(from: CGPoint(x: originX - 3.5, y: py),
                                                         to: CGPoint(x: originX + 3.5, y: py),
                                                         duration: 0.05))
                    }
                }
                ty += yTickStep
            }
            annotations.append(contentsOf: inkLabel("y", at: CGPoint(x: originX + 9, y: frame.minY + 10), size: 9))
        }

        // Equation title in the top-left corner of the plot frame.
        let cleanTitle = "y = \(body.trimmingCharacters(in: .whitespaces))"
        if cleanTitle.count <= 26 {
            annotations.append(contentsOf: inkLabel(cleanTitle,
                                                    at: CGPoint(x: frame.minX + 6, y: frame.minY + 11),
                                                    size: 9))
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

        // 5. Key feature dots: y-intercept and x-intercepts (roots) inside the frame.
        if xRange.contains(0), let y0 = value(of: body, at: 0), y0.isFinite, y0 >= yMin, y0 <= yMax {
            let pt = project(0, y0)
            annotations.append(InkStroke(points: [pt], isDot: true, dotRadius: 2.6))
        }
        var rootDots = 0
        for segment in segments where rootDots < 4 {
            for i in 1..<segment.count where rootDots < 4 {
                let a = segment[i - 1], b = segment[i]
                if a.y == 0 || (a.y * b.y < 0) {
                    let frac = a.y == b.y ? 0 : (-a.y / (b.y - a.y))
                    let rx = a.x + (b.x - a.x) * frac
                    let pt = project(rx, 0)
                    if frame.contains(pt) {
                        annotations.append(InkStroke(points: [pt], isDot: true, dotRadius: 2.6))
                        rootDots += 1
                    }
                }
            }
        }

        let labels: [(String, CGPoint)] = [
            (format(xRange.upperBound), CGPoint(x: frame.maxX - 18, y: originY + 15)),
            (format(yMax), CGPoint(x: originX + 8, y: frame.minY + 22)),
        ]
        for (text, pt) in labels where frame.insetBy(dx: -4, dy: -20).contains(pt) {
            annotations.append(contentsOf: inkLabel(text, at: pt, size: 8.5))
        }
        return Plot(axes: axes, curve: curve, annotations: annotations, labels: labels)
    }

    /// Hand-drawn small stroke-font label for graph axes and scale values.
    private static func inkLabel(_ text: String, at origin: CGPoint, size: CGFloat) -> [InkStroke] {
        var x = origin.x
        var out: [InkStroke] = []
        for ch in text {
            if ch == " " {
                x += size * 0.45
                continue
            }
            let (glyphStrokes, adv) = StrokeFont.inkStrokes(for: ch,
                                                            originX: x,
                                                            baselineY: origin.y,
                                                            size: size,
                                                            messiness: 0.12)
            for var s in glyphStrokes {
                s.duration = 0.05
                out.append(s)
            }
            x += adv
        }
        return out
    }

    private static func niceStep(for span: Double, targetTicks: Int) -> Double {
        guard span > 0, targetTicks > 0 else { return 1 }
        let raw = span / Double(targetTicks)
        let mag = pow(10, floor(log10(raw)))
        let norm = raw / mag
        let nice: Double = norm < 1.5 ? 1 : norm < 3.5 ? 2 : norm < 7.5 ? 5 : 10
        return max(1e-6, nice * mag)
    }

    // MARK: - Helpers

    /// Evaluates the body with `x` substituted, via the on-device evaluator.
    private static func value(of body: String, at x: Double) -> Double? {
        // Bracket negatives so "x^2" at x = -3 doesn't parse as subtraction,
        // and only replace standalone variable `x` / `X` so `exp(x)` stays intact.
        let replacement = x < 0 ? "(\(x))" : "\(x)"
        let substituted = body.replacingOccurrences(
            of: #"(?<![a-zA-Z])[xX](?![a-zA-Z])"#,
            with: replacement,
            options: .regularExpression
        )
        return MathEvaluator.evaluate(
            MathEvaluator.normalize(substituted),
            trigInRadians: true
        )
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

    private static func handDrawnLine(from a: CGPoint, to b: CGPoint,
                                      duration: TimeInterval = 0.35) -> InkStroke {
        let steps = max(4, Int(hypot(b.x - a.x, b.y - a.y) / 12))
        let points = (0...steps).map { i -> CGPoint in
            let t = CGFloat(i) / CGFloat(steps)
            let drift = sin(Double(t) * 3.1) * 0.7
            return CGPoint(x: a.x + (b.x - a.x) * t,
                           y: a.y + (b.y - a.y) * t + CGFloat(drift))
        }
        var stroke = InkStroke(points: points)
        stroke.duration = duration
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
