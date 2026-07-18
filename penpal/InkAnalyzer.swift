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

    /// What we can measure from the user's handwritten question: where the
    /// line sits, how tall their symbols are, and how thick the pen tip is.
    struct UserHandMetrics {
        var baseline: CGFloat
        var xHeight: CGFloat
        var tipWidth: CGFloat
        var trailX: CGFloat
    }

    /// Baseline + character size + tip width for writing an answer in the
    /// user's hand. Ignores flat bars (`=`, `−`, fraction bars) so the lower
    /// equals stroke doesn't pull the answer off the digit line. Symbol
    /// *clusters* (a whole "2" or "x") drive height — raw stroke height
    /// under-sizes multi-stroke digits.
    static func measureUserHand(from strokes: [PKStroke],
                                fallbackLine: CGRect,
                                fallbackXHeight: CGFloat) -> UserHandMetrics {
        let usable = strokes.filter {
            $0.renderBounds.width > 0.5 || $0.renderBounds.height > 0.5
        }
        let unit = max(8, fallbackXHeight)
        func isFlatBar(_ s: PKStroke) -> Bool {
            let b = s.renderBounds
            return b.width > b.height * 2.6 && b.height < unit * 0.5
        }
        let body = usable.filter { !isFlatBar($0) }
        let sample = body.isEmpty ? usable : body

        let baseline: CGFloat
        if sample.isEmpty {
            baseline = fallbackLine.maxY - max(2, fallbackLine.height * 0.12)
        } else {
            let bottoms = sample.map { $0.renderBounds.maxY }.sorted()
            baseline = bottoms[bottoms.count / 2]
        }

        // Character size from single-symbol clusters. Reject wide unions (the
        // whole "2+2=" blob) — those made answers look huge vs the digits.
        let lineCap = fallbackLine.height > 6 ? fallbackLine.height * 0.72 : 28
        var symbolHeights: [CGFloat] = []
        if !usable.isEmpty {
            for group in MathInkParser.symbolClusters(in: usable) {
                let r = group.reduce(CGRect.null) { $0.union($1.renderBounds) }
                guard !r.isNull, r.height > 4, r.height <= lineCap * 1.15 else { continue }
                if r.width > r.height * 2.2 && r.height < unit * 0.55 { continue } // "="
                // One glyph is roughly square-ish; a merged run is much wider.
                if r.width > r.height * 1.65 { continue }
                symbolHeights.append(r.height)
            }
        }
        let strokeHeights = sample.map { $0.renderBounds.height }
            .filter { $0 > 4 && $0 <= lineCap * 1.15 }
        if symbolHeights.isEmpty { symbolHeights = strokeHeights }

        let xHeight: CGFloat
        if symbolHeights.isEmpty {
            xHeight = min(fallbackXHeight, lineCap)
        } else {
            let sorted = symbolHeights.sorted()
            let clusterMed = sorted[sorted.count / 2]
            // Don't let a tall outlier / loose PK bounds beat typical strokes.
            let strokeMed: CGFloat = {
                guard !strokeHeights.isEmpty else { return clusterMed }
                let s = strokeHeights.sorted()
                return s[s.count / 2]
            }()
            let raw = min(clusterMed, strokeMed * 1.2, lineCap)
            // Digits' ink bounds run a bit taller than StrokeFont's x-height.
            xHeight = min(22, max(10, raw * 0.78))
        }

        // Median Pencil tip size along the body strokes.
        var tipSamples: [CGFloat] = []
        for s in sample {
            for p in s.path.interpolatedPoints(by: .distance(2)) {
                let w = max(p.size.width, p.size.height)
                if w > 0.4 { tipSamples.append(w) }
            }
        }
        let tipWidth: CGFloat
        if tipSamples.isEmpty {
            tipWidth = max(1.4, xHeight * 0.11)
        } else {
            tipSamples.sort()
            tipWidth = min(12, max(1.2, tipSamples[tipSamples.count / 2]))
        }

        let bodyMaxX = sample.map { $0.renderBounds.maxX }.max() ?? fallbackLine.maxX
        let trail = max(bodyMaxX, fallbackLine.maxX)
        return UserHandMetrics(baseline: baseline, xHeight: xHeight,
                               tipWidth: tipWidth, trailX: trail)
    }

    /// Back-compat wrapper used by older call sites.
    static func inlineWritingMetrics(from strokes: [PKStroke],
                                     fallbackLine: CGRect,
                                     fallbackXHeight: CGFloat)
        -> (baseline: CGFloat, xHeight: CGFloat, maxX: CGFloat) {
        let m = measureUserHand(from: strokes, fallbackLine: fallbackLine,
                                fallbackXHeight: fallbackXHeight)
        return (m.baseline, m.xHeight, m.trailX)
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

    // MARK: - Problem box (draw a box/circle around a problem → ask the AI)

    /// A closed loop the user drew around some of their ink. The rect gives
    /// the AI a visual scope: "the question is HERE". Enclosed strokes are
    /// what gets read (and later, the region we could send as an image).
    struct ProblemBox {
        var rect: CGRect
        var boxStrokeIndex: Int      // index into the full drawing's strokes
        var enclosedIndices: [Int]   // indices of the ink inside the box
    }

    /// Scans the newly drawn strokes (tail of `all`, starting at `newStart`)
    /// for a box/circle enclosing OTHER ink. Newest first — the enclosure is
    /// usually the last thing drawn.
    static func detectProblemBox(all: [PKStroke], newStart: Int) -> ProblemBox? {
        guard newStart < all.count else { return nil }
        for idx in stride(from: all.count - 1, through: newStart, by: -1) {
            guard let rect = enclosureRect(of: all[idx]) else { continue }
            let inner = rect.insetBy(dx: -4, dy: -4)   // slight tolerance
            let enclosed = all.indices.filter { i in
                i != idx && inner.contains(all[i].renderBounds)
            }
            guard !enclosed.isEmpty else { continue }
            // The loop must be an OUTLINE around the ink, not ink that happens
            // to overlap: enclosed content should sit visibly inside.
            let contentBounds = enclosed.reduce(CGRect.null) { $0.union(all[$1].renderBounds) }
            guard contentBounds.width < rect.width * 0.96,
                  contentBounds.height < rect.height * 0.96 else { continue }
            return ProblemBox(rect: rect, boxStrokeIndex: idx, enclosedIndices: enclosed)
        }
        return nil
    }

    /// Is this stroke a deliberate closed enclosure (rectangle, circle,
    /// rounded box)? Returns its bounding rect if so.
    private static func enclosureRect(of stroke: PKStroke) -> CGRect? {
        let pts = stroke.path.interpolatedPoints(by: .distance(4)).map(\.location)
        guard pts.count >= 10 else { return nil }
        let b = stroke.renderBounds
        // Big enough to be "around a problem", not a letter (o, 0, box glyph).
        guard b.width > 70, b.height > 34 else { return nil }

        var length: CGFloat = 0
        for i in 1..<pts.count {
            length += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
        }
        // Closed: pen returned (nearly) to where it started.
        let gap = hypot(pts[0].x - pts[pts.count - 1].x, pts[0].y - pts[pts.count - 1].y)
        guard gap < max(24, length * 0.15) else { return nil }

        // One clean lap: path length ≈ bounds perimeter (rect ≈ 1.0×,
        // ellipse ≈ 0.8×). A scribble or spiral is much longer.
        let perimeter = 2 * (b.width + b.height)
        guard length > perimeter * 0.62, length < perimeter * 1.45 else { return nil }

        // The path hugs the border of its bounds (never cuts through the
        // middle, where the problem ink lives).
        let tolerance = max(16, min(b.width, b.height) * 0.26)
        var hugging = 0
        for p in pts {
            let edgeDistance = min(abs(p.x - b.minX), abs(p.x - b.maxX),
                                   abs(p.y - b.minY), abs(p.y - b.maxY))
            if edgeDistance < tolerance { hugging += 1 }
        }
        guard CGFloat(hugging) / CGFloat(pts.count) > 0.55 else { return nil }
        return b
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
