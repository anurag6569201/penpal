import PencilKit

/// Shared appearance for the preview, animated reply and saved PencilKit ink.
enum ReplyInkStyle {
    /// Map the weight control into PencilKit's visible range. Multiplying a
    /// 1–2 pt tip and then clamping it to 3 made most of the slider do nothing.
    static func baseWidth(xHeight: CGFloat, weight: Double, matching: CGFloat? = nil) -> CGFloat {
        let natural = max(3, matching ?? xHeight * 0.11)
        return natural + CGFloat(min(1.8, max(0.2, weight)) - 0.55) * 1.2
    }

    static func typeface(name: String, xHeight: CGFloat) -> UIFont {
        let base = UIFont(name: name, size: 100) ?? UIFont.italicSystemFont(ofSize: 100)
        return base.withSize(min(96, max(9, 100 * xHeight / max(10, base.xHeight))))
    }

    static func prepare(_ strokes: [InkStroke], baseWidth: CGFloat) -> [InkStroke] {
        let samples = strokes.flatMap { $0.widths ?? [] }.filter { $0.isFinite && $0 > 0 }.sorted()
        let median = samples.isEmpty ? 1 : samples[samples.count / 2]
        // Programmatic PencilKit pen strokes below 3 pt can disappear.
        // Apply the same floor before animation so committing ink doesn't
        // suddenly change its weight. Keep gentle captured pressure variation.
        let target = max(3, baseWidth)
        return strokes.compactMap { stroke in
            guard !stroke.points.isEmpty,
                  stroke.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  stroke.isDot || stroke.points.count > 1 else { return nil }
            var result = stroke
            result.opacity = min(stroke.opacity, min(1, max(0.7, baseWidth / 3)))
            if stroke.isDot {
                result.dotRadius = max(1.5, target / 2)
            } else {
                let widths = stroke.widths?.count == stroke.points.count ? stroke.widths : nil
                result.widths = stroke.points.indices.map { i in
                    let raw = widths?[i] ?? median
                    let relative = raw.isFinite && raw > 0 ? raw / median : 1
                    return max(3, target * min(1.2, max(0.85, relative)))
                }
            }
            return result
        }
    }

    static func pencilStroke(from stroke: InkStroke,
                                 baseWidth: CGFloat,
                                 color: UIColor) -> PKStroke? {
        let inkColor = color
        let hasWidths = stroke.widths?.count == stroke.points.count
        // Matched absolute widths ≈ user tip; bare baseWidth needs a bigger
        // PK compensation for the animation→canvas handoff.
        let boost: CGFloat = hasWidths ? 1 : 1.9
        // PencilKit's programmatic stroke renderer effectively quantizes tiny
        // point sizes: below ~3 pt a stroke can remain lasso-selectable while
        // rendering transparent or nearly transparent. Imported prose commonly
        // computes to 1.6–2 pt, so enforce the same practical floor as a real
        // PencilKit pen stroke.
        let minWidth = max(CGFloat(3), baseWidth * (hasWidths ? 0.78 : 0.9))

        func point(_ location: CGPoint, _ time: TimeInterval, _ width: CGFloat) -> PKStrokePoint {
            PKStrokePoint(location: location,
                          timeOffset: time,
                          size: CGSize(width: width, height: width),
                          opacity: min(1, max(0.7, stroke.opacity)),
                          force: 1,
                          azimuth: 0,
                          altitude: .pi / 2)
        }

        if stroke.isDot, let c = stroke.points.first {
            let w = max(minWidth, max(baseWidth, stroke.dotRadius * 2))
            // Two identical locations form a zero-length path, which
            // PencilKit can omit entirely (missing i-dots and full stops).
            let span = max(0.1, w * 0.04)
            let path = PKStrokePath(controlPoints: [
                point(CGPoint(x: c.x - span, y: c.y), 0, w),
                point(CGPoint(x: c.x + span, y: c.y), 0.01, w)
            ], creationDate: Date())
            return PKStroke(ink: PKInk(.pen, color: inkColor), path: path)
        }
        guard stroke.points.count > 1 else { return nil }

        // PEN-31: bind the optionals once. The `hasWidths` / `hasTimes` flags
        // were computed several lines away from the force-unwraps they
        // guarded, which is exactly how such a pair drifts apart.
        let widths = stroke.widths?.count == stroke.points.count ? stroke.widths : nil
        let times = stroke.pointTimes?.count == stroke.points.count ? stroke.pointTimes : nil
        var controls: [PKStrokePoint] = []
        controls.reserveCapacity(stroke.points.count)
        var lastTime = -1.0
        for (i, p) in stroke.points.enumerated() {
            let nominal = widths?[i] ?? baseWidth
            let w = max(minWidth, nominal * boost)
            // timeOffset must be strictly increasing or PencilKit misrenders.
            let raw = times?[i] ?? Double(i) * 0.004
            let t = max(raw, lastTime + 0.001)
            lastTime = t
            controls.append(point(p, t, w))
        }
        let path = PKStrokePath(controlPoints: controls, creationDate: Date())
        return PKStroke(ink: PKInk(.pen, color: inkColor), path: path)
    }

}
