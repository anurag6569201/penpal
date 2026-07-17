//
//  InkAnalyzer.swift
//  penpal
//
//  Answers the three placement questions:
//  1. WHERE did the user write?   -> bounds + text-line clustering of new strokes
//  2. HOW BIG do they write?      -> x-height estimate from line heights
//  3. WHERE should we reply?      -> baseline below their ink, snapped to ruled lines,
//                                    aligned to their left margin, with page-full detection.
//

import PencilKit

struct DetectedLine {
    var rect: CGRect
}

struct ReplyPlacement {
    var origin: CGPoint          // pen start (x = left margin, y = baseline of first line)
    var xHeight: CGFloat         // reply writing size
    var maxX: CGFloat            // wrap edge
    var maxY: CGFloat            // last usable baseline
    var newInkBounds: CGRect     // what we detected (for debug overlay)
    var detectedLines: [DetectedLine]
    var needsNewPage: Bool
}

enum InkAnalyzer {

    /// Groups strokes into horizontal text lines by vertical overlap.
    static func clusterLines(_ strokes: [PKStroke]) -> [DetectedLine] {
        let rects = strokes.map { $0.renderBounds }.filter { $0.height > 1 }
        guard !rects.isEmpty else { return [] }
        let heights = rects.map(\.height).sorted()
        let medianHeight = heights[heights.count / 2]
        var lines: [CGRect] = []
        for r in rects.sorted(by: { $0.midY < $1.midY }) {
            if let last = lines.last,
               abs(r.midY - last.midY) < max(8, medianHeight * 0.72) {
                lines[lines.count - 1] = last.union(r)
            } else {
                lines.append(r)
            }
        }
        return lines.map { DetectedLine(rect: $0) }
    }

    /// Estimates the user's x-height from detected line heights.
    /// A written line of text is roughly 2.2x the x-height (ascender + descender).
    static func estimateXHeight(lines: [DetectedLine]) -> CGFloat {
        let heights = lines.map { $0.rect.height }.filter { $0 > 6 }.sorted()
        guard !heights.isEmpty else { return 14 }
        let h = heights[Int(CGFloat(heights.count - 1) * 0.6)]
        return min(26, max(11, h * 0.45))
    }

    static func placement(newStrokes: [PKStroke],
                          previousBottom: CGFloat,
                          pageBounds: CGRect,
                          leftMargin: CGFloat,
                          lineGap: CGFloat,
                          rulesTopInset: CGFloat,
                          occupiedStrokes: [PKStroke] = [],
                          preferredXHeight: CGFloat? = nil) -> ReplyPlacement? {
        guard !newStrokes.isEmpty else { return nil }

        let bounds = newStrokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
        let lines = clusterLines(newStrokes)
        let xHeight = preferredXHeight ?? estimateXHeight(lines: lines)

        // Baseline: the very next ruled line below the user's ink (and any
        // previous reply) — no blank line left between them.
        let contentBottom = max(bounds.maxY, previousBottom)
        let raw = contentBottom + xHeight * 0.8
        var baseline = rulesTopInset + lineGap * ceil((raw - rulesTopInset) / lineGap)

        // Align to the user's own left margin, but keep room for at least a few words.
        var x = max(leftMargin, min(bounds.minX, pageBounds.maxX - 220))

        let safe = pageBounds.insetBy(dx: 16, dy: max(12, lineGap * 0.35))
        let maxY = safe.maxY - lineGap * 0.25
        let occupied = occupiedStrokes.map { $0.renderBounds.insetBy(dx: -5, dy: -5) }
        let bandHeight = max(lineGap * 0.8, xHeight * 2.1)
        while baseline <= maxY {
            let candidate = CGRect(x: x, y: baseline - xHeight * 1.65,
                                   width: max(1, safe.maxX - x), height: bandHeight)
            if !occupied.contains(where: { $0.intersects(candidate) }) { break }
            baseline += lineGap
        }
        var newPage = false
        if baseline > maxY {
            newPage = true
            baseline = rulesTopInset + lineGap * 2
            x = leftMargin
        }

        return ReplyPlacement(origin: CGPoint(x: x, y: baseline),
                              xHeight: xHeight,
                              maxX: safe.maxX,
                              maxY: maxY,
                              newInkBounds: bounds,
                              detectedLines: lines,
                              needsNewPage: newPage)
    }

    /// Converts PencilKit strokes into replayable InkStrokes offset so the block's
    /// top-left lands at `target` (used by echo mode).
    static func echoStrokes(from strokes: [PKStroke], target: CGPoint) -> (strokes: [InkStroke], bottomY: CGFloat) {
        let bounds = strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
        guard !bounds.isNull else { return ([], target.y) }
        let dx = target.x - bounds.minX
        let dy = target.y - bounds.minY
        var out: [InkStroke] = []
        var previousEnd: Date?
        for stroke in strokes {
            var pts: [CGPoint] = []
            var ws: [CGFloat] = []
            var ts: [Double] = []
            var fs: [CGFloat] = []
            var alts: [CGFloat] = []
            var azs: [CGFloat] = []
            var lastOffset: TimeInterval = 0
            for point in stroke.path.interpolatedPoints(by: .distance(2.5)) {
                pts.append(CGPoint(x: point.location.x + dx, y: point.location.y + dy))
                ws.append(max(1.1, point.size.width))
                ts.append(point.timeOffset)
                fs.append(point.force)
                alts.append(point.altitude)
                azs.append(point.azimuth)
                lastOffset = max(lastOffset, point.timeOffset)
            }
            let started = stroke.path.creationDate
            let pause = previousEnd.map { max(0, started.timeIntervalSince($0)) }
            previousEnd = started.addingTimeInterval(lastOffset)

            if pts.count == 1 {
                out.append(InkStroke(points: pts, isDot: true, dotRadius: max(2, ws.first ?? 2),
                                     pauseBefore: pause))
            } else if pts.count > 1 {
                out.append(InkStroke(points: pts, widths: ws,
                                     duration: lastOffset > 0.01 ? lastOffset : nil,
                                     pauseBefore: pause, pointTimes: ts, forces: fs,
                                     altitudes: alts, azimuths: azs,
                                     source: .exact, confidence: 1))
            }
        }
        return (out, bounds.height + target.y)
    }
}
