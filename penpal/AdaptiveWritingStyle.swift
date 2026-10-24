import PencilKit

/// Per-reply measurements from the handwriting that prompted that reply.
/// The user's saved letter shapes remain the source of each glyph; these
/// measurements tune the size, slant and weight around those shapes.
struct AdaptiveWritingStyle {
    var xHeight: CGFloat
    var tipWidth: CGFloat
    /// Horizontal drift per vertical point in page coordinates.
    var slant: CGFloat

    static func measure(_ strokes: [PKStroke], fallbackXHeight: CGFloat) -> AdaptiveWritingStyle? {
        let visible = strokes.filter { $0.renderBounds.width > 1 || $0.renderBounds.height > 1 }
        let bounds = visible.reduce(CGRect.null) { $0.union($1.renderBounds) }
        guard visible.count >= 5, !bounds.isNull,
              bounds.width > max(30, bounds.height * 1.15), bounds.height > 8 else { return nil }

        let measured = InkAnalyzer.measureUserHand(
            from: visible, fallbackLine: bounds, fallbackXHeight: fallbackXHeight)
        // A prompt may contain tall capitals, descenders or a doodle. Blend
        // toward the page's actual line height and limit a single reply's jump.
        let bounded = min(fallbackXHeight * 1.25,
                          max(fallbackXHeight * 0.7, measured.xHeight))
        let xHeight = fallbackXHeight * 0.35 + bounded * 0.65

        var slopes: [CGFloat] = []
        for stroke in visible {
            let points = stroke.path.map(\.location)
            guard points.count >= 5 else { continue }
            for i in 1..<points.count {
                let dx = points[i].x - points[i - 1].x
                let dy = points[i].y - points[i - 1].y
                guard abs(dy) >= 1.5, abs(dx) <= abs(dy) * 0.8 else { continue }
                slopes.append(min(0.45, max(-0.45, dx / dy)))
            }
        }
        slopes.sort()
        let observedSlant = slopes.isEmpty ? 0 : slopes[slopes.count / 2]
        let slant = min(0.2, max(-0.2, observedSlant * 0.5))
        return AdaptiveWritingStyle(xHeight: xHeight, tipWidth: measured.tipWidth, slant: slant)
    }

    func apply(to strokes: [InkStroke], baseline: CGFloat) -> [InkStroke] {
        guard abs(slant) > 0.005 else { return strokes }
        return strokes.map { stroke in
            var result = stroke
            result.points = stroke.points.map { point in
                CGPoint(x: point.x + slant * (point.y - baseline), y: point.y)
            }
            return result
        }
    }
}
