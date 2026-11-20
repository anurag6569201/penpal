//
//  SmartShapeEngine.swift
//  penpal
//
//  Hybrid Smart Shape recognizer & native PencilKit synthesizer.
//  Used in two modes:
//    1. Draw & Hold (always on): hold the pen still for ~0.45s at the end of a
//       stroke to snap it into a clean geometric shape without mode switching.
//    2. Smart Shapes Mode (1-tap toggle): every lifted stroke snaps immediately,
//       with magnetic vertex snapping and optional grid snapping for geometry.
//

import CoreGraphics
import Foundation
import PencilKit
import UIKit

enum SmartShapeEngine {

    /// Context passed from the live page so shapes can magnetically align to
    /// existing vertices and (on grid/dot paper) to grid intersections.
    struct SnapContext {
        var existingEndpoints: [CGPoint] = []
        var gridOrigin: CGPoint? = nil
        var gridSpacing: CGFloat = 0
        var endpointSnapRadius: CGFloat = 14
        var gridSnapRadius: CGFloat = 6.5

        static let none = SnapContext()
    }

    enum RecognizedShape: Equatable {
        case line(from: CGPoint, to: CGPoint)
        case arrow(from: CGPoint, to: CGPoint, headLength: CGFloat)
        case rightAngle(a: CGPoint, vertex: CGPoint, b: CGPoint)
        case circle(center: CGPoint, radius: CGFloat)
        case ellipse(center: CGPoint, rx: CGFloat, ry: CGFloat, angle: CGFloat)
        case square(center: CGPoint, side: CGFloat, angle: CGFloat)
        case rectangle(center: CGPoint, size: CGSize, angle: CGFloat)
        case triangle(CGPoint, CGPoint, CGPoint, isRight: Bool, isEquilateral: Bool)
        case polygon([CGPoint])
        case arc(p0: CGPoint, control: CGPoint, p1: CGPoint)

        var displayName: String {
            switch self {
            case .line: return "Straight Line"
            case .arrow: return "Arrow"
            case .rightAngle: return "Right Angle"
            case .circle: return "Perfect Circle"
            case .ellipse: return "Ellipse"
            case .square: return "Perfect Square"
            case .rectangle: return "Rectangle"
            case .triangle(_, _, _, let isRight, let isEq):
                if isEq { return "Equilateral Triangle" }
                if isRight { return "Right Triangle" }
                return "Triangle"
            case .polygon(let pts):
                switch pts.count {
                case 5: return "Pentagon"
                case 6: return "Hexagon"
                default: return "Polygon"
                }
            case .arc: return "Smooth Arc"
            }
        }

        var symbolName: String {
            switch self {
            case .line: return "line.diagonal"
            case .arrow: return "arrow.up.right"
            case .rightAngle: return "angle"
            case .circle: return "circle"
            case .ellipse: return "oval"
            case .square: return "square"
            case .rectangle: return "rectangle"
            case .triangle: return "triangle"
            case .polygon(let pts):
                return pts.count == 5 ? "pentagon" : "hexagon"
            case .arc: return "point.topleft.down.to.point.bottomright.curvepath"
            }
        }
    }

    // MARK: - Public Recognition Entry Points

    /// Recognizes a geometric shape from a completed PencilKit stroke.
    static func recognize(stroke: PKStroke, context: SnapContext = .none) -> RecognizedShape? {
        let pts = stroke.path.interpolatedPoints(by: .distance(3)).map(\.location)
        return recognize(points: pts, context: context)
    }

    /// Recognizes a geometric shape from a sequence of sampled points.
    /// Deliberately avoids false positives on tiny strokes (letters, digits, punctuation).
    static func recognize(points rawPoints: [CGPoint],
                          context: SnapContext = .none) -> RecognizedShape? {
        let pts = deduplicate(rawPoints, minDistance: 1.5)
        guard pts.count >= 4 else { return nil }
        let bounds = boundingRect(of: pts)
        let diag = hypot(bounds.width, bounds.height)
        guard diag >= 28 else { return nil }

        let totalLen = pathLength(of: pts)
        guard totalLen >= 30 else { return nil }

        // 1. Check open vs closed geometry.
        let endGap = hypot(pts[0].x - pts[pts.count - 1].x, pts[0].y - pts[pts.count - 1].y)
        let isClosed = totalLen >= 70
            && diag >= 26
            && endGap <= max(36, min(diag * 0.42, totalLen * 0.24))

        if isClosed {
            if let closed = recognizeClosedShape(pts: pts, bounds: bounds,
                                                 diag: diag, totalLen: totalLen,
                                                 context: context) {
                return closed
            }
        }

        // 2. Open shapes: straight line, arrow, right-angle L, smooth arc.
        if let line = recognizeLine(pts: pts, totalLen: totalLen, context: context) {
            return line
        }
        if let arrow = recognizeArrow(pts: pts, totalLen: totalLen, context: context) {
            return arrow
        }
        if let corner = recognizeRightAngle(pts: pts, diag: diag, context: context) {
            return corner
        }
        if let arc = recognizeArc(pts: pts, totalLen: totalLen, context: context) {
            return arc
        }
        return nil
    }

    /// Collects start/end/corner anchor points from existing strokes for magnetic snapping.
    static func collectEndpoints(from strokes: [PKStroke], limit: Int = 80) -> [CGPoint] {
        var anchors: [CGPoint] = []
        for stroke in strokes.suffix(limit) {
            let path = stroke.path
            guard path.count >= 2 else { continue }
            anchors.append(path[0].location)
            anchors.append(path[path.count - 1].location)
            // Also sample sharp corners from multi-vertex shapes (squares, triangles, L-shapes).
            let pts = path.interpolatedPoints(by: .distance(6)).map(\.location)
            if pts.count >= 6 {
                let b = boundingRect(of: pts)
                let diag = hypot(b.width, b.height)
                if diag > 24 {
                    let simplified = douglasPeucker(pts, epsilon: max(8, diag * 0.06))
                    if simplified.count >= 3 && simplified.count <= 8 {
                        anchors.append(contentsOf: simplified.dropFirst().dropLast())
                    }
                }
            }
        }
        return anchors
    }

    // MARK: - Live Preview & Native PKStroke Synthesis

    /// Generates clean polyline groups (one or more subpaths) for rendering as a preview or PKStroke.
    static func polylines(for shape: RecognizedShape) -> [[CGPoint]] {
        switch shape {
        case .line(let a, let b):
            return [sampleSegment(from: a, to: b, step: 4)]

        case .arrow(let a, let b, let headLength):
            let shaft = sampleSegment(from: a, to: b, step: 4)
            let theta = atan2(b.y - a.y, b.x - a.x)
            let spread: CGFloat = .pi * 0.82 // ~32° wing back-angle
            let leftWing = CGPoint(x: b.x + cos(theta + spread) * headLength,
                                   y: b.y + sin(theta + spread) * headLength)
            let rightWing = CGPoint(x: b.x + cos(theta - spread) * headLength,
                                    y: b.y + sin(theta - spread) * headLength)
            // Continuous path: shaft → tip → left barb → tip → right barb (single stroke!).
            var full = shaft
            full.append(contentsOf: sampleSegment(from: b, to: leftWing, step: 3).dropFirst())
            full.append(contentsOf: sampleSegment(from: leftWing, to: b, step: 3).dropFirst())
            full.append(contentsOf: sampleSegment(from: b, to: rightWing, step: 3).dropFirst())
            return [full]

        case .rightAngle(let a, let v, let b):
            return [samplePolygon([a, v, b], closed: false)]

        case .circle(let center, let radius):
            let steps = max(48, min(96, Int((2 * .pi * radius) / 5)))
            let ring = (0...steps).map { i -> CGPoint in
                let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
                return CGPoint(x: center.x + cos(t) * radius,
                               y: center.y + sin(t) * radius)
            }
            return [ring]

        case .ellipse(let center, let rx, let ry, let angle):
            let approxPerimeter = .pi * (3 * (rx + ry) - sqrt((3 * rx + ry) * (rx + 3 * ry)))
            let steps = max(48, min(100, Int(approxPerimeter / 5)))
            let c = cos(angle), s = sin(angle)
            let ring = (0...steps).map { i -> CGPoint in
                let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
                let lx = cos(t) * rx
                let ly = sin(t) * ry
                return CGPoint(x: center.x + lx * c - ly * s,
                               y: center.y + lx * s + ly * c)
            }
            return [ring]

        case .square(let center, let side, let angle):
            let corners = orientedRectCorners(center: center, width: side, height: side, angle: angle)
            return [samplePolygon(corners, closed: true)]

        case .rectangle(let center, let size, let angle):
            let corners = orientedRectCorners(center: center, width: size.width, height: size.height, angle: angle)
            return [samplePolygon(corners, closed: true)]

        case .triangle(let a, let b, let c, _, _):
            return [samplePolygon([a, b, c], closed: true)]

        case .polygon(let verts):
            guard verts.count >= 3 else { return [] }
            return [samplePolygon(verts, closed: true)]

        case .arc(let p0, let ctrl, let p1):
            let approxLen = hypot(ctrl.x - p0.x, ctrl.y - p0.y) + hypot(p1.x - ctrl.x, p1.y - ctrl.y)
            let steps = max(24, min(72, Int(approxLen / 5)))
            let curve = (0...steps).map { i -> CGPoint in
                let t = CGFloat(i) / CGFloat(steps)
                let omt = 1 - t
                let x = omt * omt * p0.x + 2 * omt * t * ctrl.x + t * t * p1.x
                let y = omt * omt * p0.y + 2 * omt * t * ctrl.y + t * t * p1.y
                return CGPoint(x: x, y: y)
            }
            return [curve]
        }
    }

    /// Builds a `UIBezierPath` for live CAShapeLayer preview while holding the pen.
    static func previewPath(for shape: RecognizedShape) -> UIBezierPath {
        let path = UIBezierPath()
        for line in polylines(for: shape) where line.count >= 2 {
            path.move(to: line[0])
            for pt in line.dropFirst() { path.addLine(to: pt) }
        }
        return path
    }

    /// Synthesizes a native `PKStroke` matching the ink & stroke width of `template`
    /// with razor-sharp corners and clean PencilKit geometry.
    static func makeStroke(for shape: RecognizedShape, matching template: PKStroke) -> PKStroke? {
        guard let points = polylines(for: shape).first, points.count >= 2 else { return nil }
        let width = medianWidth(of: template)
        let size = CGSize(width: width, height: width)
        let strokePoints = points.enumerated().map { idx, loc in
            PKStrokePoint(
                location: loc,
                timeOffset: Double(idx) * 0.004,
                size: size,
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        return PKStroke(
            ink: template.ink,
            path: PKStrokePath(controlPoints: strokePoints, creationDate: template.path.creationDate)
        )
    }

    /// Live adjustment helper: when the user drags their pen *after* a line/circle/square
    /// snapped during Draw & Hold, smoothly updates the shape's end/size.
    static func adjusted(_ shape: RecognizedShape, draggingTo point: CGPoint,
                         context: SnapContext = .none) -> RecognizedShape {
        let snappedPt = snapPoint(point, context: context)
        switch shape {
        case .line(let from, _):
            let end = snapLineAngle(from: from, to: snappedPt)
            return .line(from: from, to: end)
        case .arrow(let from, _, let head):
            let end = snapLineAngle(from: from, to: snappedPt)
            let len = hypot(end.x - from.x, end.y - from.y)
            return .arrow(from: from, to: end, headLength: max(12, min(26, max(head, len * 0.14))))
        case .circle(let center, _):
            let r = max(14, hypot(snappedPt.x - center.x, snappedPt.y - center.y))
            return .circle(center: center, radius: r)
        case .square(let center, _, let angle):
            let dist = max(16, hypot(snappedPt.x - center.x, snappedPt.y - center.y))
            return .square(center: center, side: dist * sqrt(2), angle: angle)
        default:
            return shape
        }
    }

    // MARK: - Open Shape Classifiers

    private static func recognizeLine(pts: [CGPoint], totalLen: CGFloat,
                                      context: SnapContext) -> RecognizedShape? {
        let a = pts[0], b = pts[pts.count - 1]
        let chord = hypot(b.x - a.x, b.y - a.y)
        guard chord >= 26 else { return nil }
        guard totalLen / chord < 1.12 else { return nil }

        let maxDev = maxPerpendicularDistance(pts, from: a, to: b)
        guard maxDev < max(7.5, chord * 0.075) else { return nil }

        let start = snapPoint(a, context: context)
        let rawEnd = snapPoint(b, context: context)
        // Only angle-snap if the end wasn't already magnetically locked onto an existing vertex.
        let endLocked = rawEnd != b
        let end = endLocked ? rawEnd : snapLineAngle(from: start, to: rawEnd)
        return .line(from: start, to: end)
    }

    /// Recognizes a single-stroke arrow: a long straight shaft followed by a quick
    /// turnaround barb (or V-chevron) at the tip.
    private static func recognizeArrow(pts: [CGPoint], totalLen: CGFloat,
                                       context: SnapContext) -> RecognizedShape? {
        guard pts.count >= 8 else { return nil }
        let start = pts[0]
        // Find the point farthest from `start` — that's the candidate arrow tip.
        var tipIdx = 0
        var maxDist: CGFloat = 0
        for i in pts.indices {
            let d = hypot(pts[i].x - start.x, pts[i].y - start.y)
            if d > maxDist { maxDist = d; tipIdx = i }
        }
        guard tipIdx >= 4, tipIdx < pts.count - 2, maxDist >= 48 else { return nil }

        let shaftPts = Array(pts[0...tipIdx])
        let headPts = Array(pts[tipIdx...])
        let shaftLen = pathLength(of: shaftPts)
        let headLen = pathLength(of: headPts)
        // Shaft must be straight and clearly longer than the arrowhead tail.
        guard shaftLen / maxDist < 1.14,
              maxPerpendicularDistance(shaftPts, from: start, to: pts[tipIdx]) < max(8, maxDist * 0.08),
              headLen >= 10, headLen <= maxDist * 0.55 else { return nil }

        // Head must bend backward (dot product < -0.15 relative to shaft direction).
        let tip = pts[tipIdx]
        let sdx = (tip.x - start.x) / maxDist
        let sdy = (tip.y - start.y) / maxDist
        let hdx = headPts.last!.x - tip.x
        let hdy = headPts.last!.y - tip.y
        let hChord = hypot(hdx, hdy)
        guard hChord >= 8 else { return nil }
        let dot = (hdx * sdx + hdy * sdy) / hChord
        // Backward barb angle between ~15° and ~75° off reverse shaft.
        guard dot < -0.20, dot > -0.98 else { return nil }

        let snappedStart = snapPoint(start, context: context)
        let snappedTip = snapLineAngle(from: snappedStart, to: snapPoint(tip, context: context))
        let wingLen = max(13, min(24, maxDist * 0.16))
        return .arrow(from: snappedStart, to: snappedTip, headLength: wingLen)
    }

    /// Recognizes an L-shaped right angle (e.g. x/y coordinate axes or right corner).
    private static func recognizeRightAngle(pts: [CGPoint], diag: CGFloat,
                                            context: SnapContext) -> RecognizedShape? {
        let simplified = douglasPeucker(pts, epsilon: max(9, diag * 0.065))
        guard simplified.count == 3 else { return nil }
        let a = simplified[0], v = simplified[1], b = simplified[2]
        let len1 = hypot(v.x - a.x, v.y - a.y)
        let len2 = hypot(b.x - v.x, b.y - v.y)
        guard len1 >= 26, len2 >= 26 else { return nil }
        guard min(len1, len2) / max(len1, len2) > 0.25 else { return nil }

        let angle = interiorAngle(a: a, vertex: v, b: b)
        // Must be close to 90° (72°…108°).
        guard abs(angle - .pi / 2) < 0.32 else { return nil }

        // Verify original points hug the two legs tightly.
        let err = meanDistanceToPolyline(pts, vertices: [a, v, b], closed: false)
        guard err < max(7.5, diag * 0.055) else { return nil }

        let sv = snapPoint(v, context: context)
        let sa = snapLineAngle(from: sv, to: snapPoint(a, context: context))
        // Construct exact 90° second leg preserving user's handedness & length.
        let ux = (sa.x - sv.x) / max(1, hypot(sa.x - sv.x, sa.y - sv.y))
        let uy = (sa.y - sv.y) / max(1, hypot(sa.x - sv.x, sa.y - sv.y))
        let cross = ux * (b.y - v.y) - uy * (b.x - v.x)
        let sign: CGFloat = cross >= 0 ? 1 : -1
        let px = -uy * sign
        let py = ux * sign
        let sb = CGPoint(x: sv.x + px * len2, y: sv.y + py * len2)
        return .rightAngle(a: sa, vertex: sv, b: sb)
    }

    /// Recognizes a smooth single-bend arc (quadratic Bézier).
    private static func recognizeArc(pts: [CGPoint], totalLen: CGFloat,
                                     context: SnapContext) -> RecognizedShape? {
        let p0 = pts[0], p1 = pts[pts.count - 1]
        let chord = hypot(p1.x - p0.x, p1.y - p0.y)
        guard chord >= 36, totalLen / chord >= 1.06, totalLen / chord <= 1.75 else { return nil }

        // Find the point of maximum perpendicular deflection from chord.
        var peakIdx = 0
        var peakSigned: CGFloat = 0
        var minSigned: CGFloat = 0
        var maxSigned: CGFloat = 0
        let ux = (p1.x - p0.x) / chord
        let uy = (p1.y - p0.y) / chord
        for i in pts.indices {
            let signed = (pts[i].x - p0.x) * (-uy) + (pts[i].y - p0.y) * ux
            if signed < minSigned { minSigned = signed }
            if signed > maxSigned { maxSigned = signed }
            if abs(signed) > abs(peakSigned) { peakSigned = signed; peakIdx = i }
        }
        // Must bow consistently to ONE side (reject S-curves / waves / letters).
        let minorSide = min(abs(minSigned), abs(maxSigned))
        let majorSide = max(abs(minSigned), abs(maxSigned))
        guard majorSide >= max(10, chord * 0.11), minorSide < majorSide * 0.22 else { return nil }

        let peak = pts[peakIdx]
        // Quadratic Bézier passing through `peak` at t = 0.5 has control = 2*peak - 0.5*(p0+p1).
        let ctrl = CGPoint(x: 2 * peak.x - 0.5 * (p0.x + p1.x),
                           y: 2 * peak.y - 0.5 * (p0.y + p1.y))
        let sample = polylines(for: .arc(p0: p0, control: ctrl, p1: p1)).first ?? []
        let fitErr = meanDistanceToSample(pts, reference: sample)
        guard fitErr < max(6.5, chord * 0.055) else { return nil }

        let sp0 = snapPoint(p0, context: context)
        let sp1 = snapPoint(p1, context: context)
        return .arc(p0: sp0, control: ctrl, p1: sp1)
    }

    // MARK: - Closed Shape Classifiers

    private static func recognizeClosedShape(pts: [CGPoint], bounds: CGRect,
                                             diag: CGFloat, totalLen: CGFloat,
                                             context: SnapContext) -> RecognizedShape? {
        // Reject spirals / multi-lap loops (net rotation far beyond 360°).
        let turns = abs(totalTurningAngle(pts))
        guard turns > 1.2 * .pi, turns < 3.4 * .pi else { return nil }

        // Evaluate polygon fit (triangle / quad / 5-6 gon) AND ellipse/circle fit,
        // then pick the cleaner geometric match.
        let polyCandidate = fitClosedPolygon(pts: pts, diag: diag, context: context)
        let ellipseCandidate = fitEllipseOrCircle(pts: pts, bounds: bounds, diag: diag)

        switch (polyCandidate, ellipseCandidate) {
        case (let poly?, let ell?):
            // Polygons with crisp corners beat circles when corner sharpness is high
            // and polygon residual is lower than ellipse residual.
            return poly.error <= ell.error * 1.15 ? poly.shape : ell.shape
        case (let poly?, nil):
            return poly.shape
        case (nil, let ell?):
            return ell.shape
        case (nil, nil):
            return nil
        }
    }

    private static func fitEllipseOrCircle(pts: [CGPoint], bounds: CGRect,
                                           diag: CGFloat) -> (shape: RecognizedShape, error: CGFloat)? {
        guard bounds.width >= 18, bounds.height >= 18 else { return nil }
        // Centroid & PCA orientation.
        let cx = pts.reduce(0) { $0 + $1.x } / CGFloat(pts.count)
        let cy = pts.reduce(0) { $0 + $1.y } / CGFloat(pts.count)
        var sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
        for p in pts {
            let dx = p.x - cx, dy = p.y - cy
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        var angle = 0.5 * atan2(2 * sxy, sxx - syy)
        // Snap nearly axis-aligned ellipses cleanly to 0° / 90°.
        angle = snapCardinalAngle(angle, tolerance: 0.16)

        let c = cos(-angle), s = sin(-angle)
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for p in pts {
            let lx = (p.x - cx) * c - (p.y - cy) * s
            let ly = (p.x - cx) * s + (p.y - cy) * c
            minX = min(minX, lx); maxX = max(maxX, lx)
            minY = min(minY, ly); maxY = max(maxY, ly)
        }
        let rx = (maxX - minX) / 2
        let ry = (maxY - minY) / 2
        guard rx >= 10, ry >= 10 else { return nil }

        // Shift center to midpoint of rotated bounding box for cleaner fit.
        let localMidX = (minX + maxX) / 2
        let localMidY = (minY + maxY) / 2
        let cf = cos(angle), sf = sin(angle)
        let center = CGPoint(x: cx + localMidX * cf - localMidY * sf,
                             y: cy + localMidX * sf + localMidY * cf)

        // Radial fit error against the ellipse boundary.
        var errSum: CGFloat = 0
        var maxErr: CGFloat = 0
        for p in pts {
            let lx = (p.x - center.x) * c - (p.y - center.y) * s
            let ly = (p.x - center.x) * s + (p.y - center.y) * c
            let norm = hypot(lx / rx, ly / ry)
            let dist = abs(norm - 1) * min(rx, ry)
            errSum += dist
            maxErr = max(maxErr, dist)
        }
        let meanErr = errSum / CGFloat(pts.count)
        let allowedMean = max(6.5, min(rx, ry) * 0.16)
        guard meanErr < allowedMean, maxErr < max(16, min(rx, ry) * 0.36) else { return nil }

        // Check if it's actually a boxy rectangle masquerading as an ellipse:
        // a rectangle's points bulge into all 4 corners (norm ~ 1.35..1.41).
        let cornerHits = pts.filter { p in
            let lx = (p.x - center.x) * c - (p.y - center.y) * s
            let ly = (p.x - center.x) * s + (p.y - center.y) * c
            return hypot(lx / rx, ly / ry) > 1.18
        }.count
        if CGFloat(cornerHits) / CGFloat(pts.count) > 0.18 { return nil }

        let ratio = min(rx, ry) / max(rx, ry)
        if ratio >= 0.82 {
            let radius = (rx + ry) / 2
            return (.circle(center: center, radius: radius), meanErr)
        }
        return (.ellipse(center: center, rx: rx, ry: ry, angle: angle), meanErr)
    }

    private static func fitClosedPolygon(pts: [CGPoint], diag: CGFloat,
                                         context: SnapContext) -> (shape: RecognizedShape, error: CGFloat)? {
        // Close the loop for simplification, then strip duplicate closing vertex.
        let closedPts = pts + [pts[0]]
        var verts = douglasPeucker(closedPts, epsilon: max(9, diag * 0.065))
        if verts.count > 1, hypot(verts.first!.x - verts.last!.x, verts.first!.y - verts.last!.y) < max(18, diag * 0.14) {
            verts.removeLast()
        }
        verts = mergeNearCollinearVertices(verts, minEdgeLength: max(14, diag * 0.12))
        guard (3...6).contains(verts.count) else { return nil }

        // Ensure polygon encloses meaningful area (reject flat scribbles).
        let area = polygonArea(verts)
        guard area > diag * diag * 0.08 else { return nil }

        let meanErr = meanDistanceToPolyline(pts, vertices: verts, closed: true)
        guard meanErr < max(8.5, diag * 0.068) else { return nil }

        switch verts.count {
        case 3:
            let tri = refineTriangle(verts[0], verts[1], verts[2], context: context)
            return (tri, meanErr)

        case 4:
            if let rectOrSq = refineQuad(verts, diag: diag) {
                return (rectOrSq, meanErr)
            }
            return (.polygon(verts.map { snapPoint($0, context: context) }), meanErr)

        case 5, 6:
            // Promote to regular polygon if vertices sit cleanly around a circle.
            if let reg = regularizePolygonIfClose(verts) {
                return (.polygon(reg), meanErr)
            }
            return (.polygon(verts.map { snapPoint($0, context: context) }), meanErr)

        default:
            return nil
        }
    }

    private static func refineTriangle(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint,
                                       context: SnapContext) -> RecognizedShape {
        var v = [snapPoint(p0, context: context),
                 snapPoint(p1, context: context),
                 snapPoint(p2, context: context)]

        let d01 = hypot(v[1].x - v[0].x, v[1].y - v[0].y)
        let d12 = hypot(v[2].x - v[1].x, v[2].y - v[1].y)
        let d20 = hypot(v[0].x - v[2].x, v[0].y - v[2].y)
        let minSide = min(d01, min(d12, d20))
        let maxSide = max(d01, max(d12, d20))

        // 1. Equilateral triangle snapping (all sides within 15%).
        if maxSide > 0, minSide / maxSide >= 0.85 {
            let center = CGPoint(x: (v[0].x + v[1].x + v[2].x) / 3,
                                 y: (v[0].y + v[1].y + v[2].y) / 3)
            let radius = (hypot(v[0].x - center.x, v[0].y - center.y)
                          + hypot(v[1].x - center.x, v[1].y - center.y)
                          + hypot(v[2].x - center.x, v[2].y - center.y)) / 3
            // Align base horizontally if nearly level (peak pointing up or down).
            let rawTopAngle = atan2(v.min(by: { $0.y < $1.y })!.y - center.y,
                                    v.min(by: { $0.y < $1.y })!.x - center.x)
            let snappedAngle = abs(rawTopAngle + .pi / 2) < 0.25 ? -.pi / 2 : rawTopAngle
            let eq = (0..<3).map { i -> CGPoint in
                let a = snappedAngle + CGFloat(i) * (2 * .pi / 3)
                return CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
            }
            return .triangle(eq[0], eq[1], eq[2], isRight: false, isEquilateral: true)
        }

        // 2. Right triangle snapping (any interior angle within ±10° of 90°).
        for idx in 0..<3 {
            let prev = v[(idx + 2) % 3]
            let corner = v[idx]
            let next = v[(idx + 1) % 3]
            let ang = interiorAngle(a: prev, vertex: corner, b: next)
            if abs(ang - .pi / 2) < 0.18 {
                let leg1 = hypot(prev.x - corner.x, prev.y - corner.y)
                let leg2 = hypot(next.x - corner.x, next.y - corner.y)
                guard leg1 > 1, leg2 > 1 else { break }
                // Level first leg to horizontal/vertical if close.
                let snappedPrev = snapLineAngle(from: corner, to: prev)
                let ux = (snappedPrev.x - corner.x) / max(1, hypot(snappedPrev.x - corner.x, snappedPrev.y - corner.y))
                let uy = (snappedPrev.y - corner.y) / max(1, hypot(snappedPrev.x - corner.x, snappedPrev.y - corner.y))
                let cross = ux * (next.y - corner.y) - uy * (next.x - corner.x)
                let sign: CGFloat = cross >= 0 ? 1 : -1
                let snappedNext = CGPoint(x: corner.x - uy * sign * leg2,
                                          y: corner.y + ux * sign * leg2)
                v[(idx + 2) % 3] = snappedPrev
                v[(idx + 1) % 3] = snappedNext
                return .triangle(v[0], v[1], v[2], isRight: true, isEquilateral: false)
            }
        }

        // 3. Level a nearly horizontal base edge cleanly.
        for idx in 0..<3 {
            let j = (idx + 1) % 3
            if abs(v[idx].y - v[j].y) < hypot(v[idx].x - v[j].x, v[idx].y - v[j].y) * 0.12 {
                let midY = (v[idx].y + v[j].y) / 2
                v[idx].y = midY
                v[j].y = midY
                break
            }
        }
        return .triangle(v[0], v[1], v[2], isRight: false, isEquilateral: false)
    }

    private static func refineQuad(_ verts: [CGPoint], diag: CGFloat) -> RecognizedShape? {
        guard verts.count == 4 else { return nil }
        // Check that all 4 interior angles are roughly 90° (within ±26°).
        let angles = (0..<4).map { i in
            interiorAngle(a: verts[(i + 3) % 4], vertex: verts[i], b: verts[(i + 1) % 4])
        }
        guard angles.allSatisfy({ abs($0 - .pi / 2) < 0.45 }) else { return nil }

        // Dominant edge orientation (average of opposite edges mod 90°).
        let e0 = atan2(verts[1].y - verts[0].y, verts[1].x - verts[0].x)
        let angle = snapCardinalAngle(e0, tolerance: 0.20)

        let cx = verts.reduce(0) { $0 + $1.x } / 4
        let cy = verts.reduce(0) { $0 + $1.y } / 4
        let c = cos(-angle), s = sin(-angle)
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for p in verts {
            let lx = (p.x - cx) * c - (p.y - cy) * s
            let ly = (p.x - cx) * s + (p.y - cy) * c
            minX = min(minX, lx); maxX = max(maxX, lx)
            minY = min(minY, ly); maxY = max(maxY, ly)
        }
        let w = maxX - minX
        let h = maxY - minY
        guard w >= 18, h >= 18 else { return nil }

        let ratio = min(w, h) / max(w, h)
        let center = CGPoint(x: cx, y: cy)
        if ratio >= 0.84 {
            return .square(center: center, side: (w + h) / 2, angle: angle)
        }
        return .rectangle(center: center, size: CGSize(width: w, height: h), angle: angle)
    }

    private static func regularizePolygonIfClose(_ verts: [CGPoint]) -> [CGPoint]? {
        let n = verts.count
        guard n >= 5 else { return nil }
        let cx = verts.reduce(0) { $0 + $1.x } / CGFloat(n)
        let cy = verts.reduce(0) { $0 + $1.y } / CGFloat(n)
        let radii = verts.map { hypot($0.x - cx, $0.y - cy) }
        let meanR = radii.reduce(0, +) / CGFloat(n)
        guard meanR > 16 else { return nil }
        let maxRDev = radii.map { abs($0 - meanR) }.max() ?? .infinity
        guard maxRDev / meanR < 0.22 else { return nil }

        let startAngle = atan2(verts[0].y - cy, verts[0].x - cx)
        // Determine winding direction so vertex order matches the user's stroke.
        let a1 = atan2(verts[1].y - cy, verts[1].x - cx)
        var delta = a1 - startAngle
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        let dir: CGFloat = delta >= 0 ? 1 : -1

        return (0..<n).map { i in
            let a = startAngle + dir * CGFloat(i) * (2 * .pi / CGFloat(n))
            return CGPoint(x: cx + cos(a) * meanR, y: cy + sin(a) * meanR)
        }
    }

    // MARK: - Snapping Helpers

    private static func snapPoint(_ pt: CGPoint, context: SnapContext) -> CGPoint {
        // 1. Magnetic snap to existing nearby stroke endpoints/vertices first.
        var best = pt
        var bestDist = context.endpointSnapRadius
        for anchor in context.existingEndpoints {
            let d = hypot(anchor.x - pt.x, anchor.y - pt.y)
            if d < bestDist {
                bestDist = d
                best = anchor
            }
        }
        if best != pt { return best }

        // 2. Gentle snap to grid/dot intersections when active.
        if let origin = context.gridOrigin, context.gridSpacing >= 8 {
            let step = context.gridSpacing
            let gx = origin.x + round((pt.x - origin.x) / step) * step
            let gy = origin.y + round((pt.y - origin.y) / step) * step
            if hypot(gx - pt.x, gy - pt.y) <= context.gridSnapRadius {
                return CGPoint(x: gx, y: gy)
            }
        }
        return pt
    }

    /// Snaps a line segment's endpoint to 0°, 45°, 90°, 135°, 180° when within ±7.5°.
    private static func snapLineAngle(from a: CGPoint, to b: CGPoint,
                                      tolerance: CGFloat = 0.13) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 1 else { return b }
        let theta = atan2(dy, dx)
        let increment: CGFloat = .pi / 4 // 45°
        let nearest = round(theta / increment) * increment
        if abs(theta - nearest) <= tolerance {
            return CGPoint(x: a.x + cos(nearest) * len, y: a.y + sin(nearest) * len)
        }
        return b
    }

    /// Snaps an angle modulo 90° to 0° when within `tolerance` radians.
    private static func snapCardinalAngle(_ angle: CGFloat, tolerance: CGFloat) -> CGFloat {
        let halfPi = CGFloat.pi / 2
        let nearest = round(angle / halfPi) * halfPi
        return abs(angle - nearest) <= tolerance ? nearest : angle
    }

    // MARK: - Geometry Utilities

    private static func orientedRectCorners(center: CGPoint, width: CGFloat,
                                            height: CGFloat, angle: CGFloat) -> [CGPoint] {
        let hw = width / 2, hh = height / 2
        let c = cos(angle), s = sin(angle)
        let local = [CGPoint(x: -hw, y: -hh), CGPoint(x: hw, y: -hh),
                     CGPoint(x: hw, y: hh), CGPoint(x: -hw, y: hh)]
        return local.map { p in
            CGPoint(x: center.x + p.x * c - p.y * s,
                    y: center.y + p.x * s + p.y * c)
        }
    }

    private static func sampleSegment(from a: CGPoint, to b: CGPoint, step: CGFloat) -> [CGPoint] {
        let dist = hypot(b.x - a.x, b.y - a.y)
        let count = max(2, Int(ceil(dist / max(1, step))))
        return (0...count).map { i in
            let t = CGFloat(i) / CGFloat(count)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    /// Samples polygon edges densely with tight corner points so PencilKit's spline
    /// interpolation keeps every vertex razor-sharp instead of rounding corners.
    private static func samplePolygon(_ vertices: [CGPoint], closed: Bool) -> [CGPoint] {
        guard vertices.count >= 2 else { return vertices }
        var out: [CGPoint] = []
        let count = closed ? vertices.count : vertices.count - 1
        for i in 0..<count {
            let a = vertices[i]
            let b = vertices[(i + 1) % vertices.count]
            let seg = sampleSegment(from: a, to: b, step: 4)
            if out.isEmpty {
                out.append(contentsOf: seg)
            } else {
                // Anchor tight point right at the corner before leaving it.
                out.append(a)
                out.append(contentsOf: seg.dropFirst())
            }
        }
        return out
    }

    private static func deduplicate(_ pts: [CGPoint], minDistance: CGFloat) -> [CGPoint] {
        guard let first = pts.first else { return [] }
        var out = [first]
        for p in pts.dropFirst() {
            if hypot(p.x - out.last!.x, p.y - out.last!.y) >= minDistance {
                out.append(p)
            }
        }
        if let last = pts.last, out.last != last {
            out.append(last)
        }
        return out
    }

    private static func boundingRect(of pts: [CGPoint]) -> CGRect {
        var r = CGRect.null
        for p in pts { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }

    private static func pathLength(of pts: [CGPoint]) -> CGFloat {
        guard pts.count >= 2 else { return 0 }
        var len: CGFloat = 0
        for i in 1..<pts.count {
            len += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
        }
        return len
    }

    private static func perpendicularDistance(_ p: CGPoint, from a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let denom = hypot(dx, dy)
        guard denom > 0.0001 else { return hypot(p.x - a.x, p.y - a.y) }
        return abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / denom
    }

    private static func distanceToSegment(_ p: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0.0001 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private static func maxPerpendicularDistance(_ pts: [CGPoint], from a: CGPoint, to b: CGPoint) -> CGFloat {
        pts.map { perpendicularDistance($0, from: a, to: b) }.max() ?? 0
    }

    private static func meanDistanceToPolyline(_ pts: [CGPoint], vertices: [CGPoint], closed: Bool) -> CGFloat {
        guard !pts.isEmpty, vertices.count >= 2 else { return .infinity }
        let segCount = closed ? vertices.count : vertices.count - 1
        var sum: CGFloat = 0
        for p in pts {
            var best = CGFloat.infinity
            for i in 0..<segCount {
                let d = distanceToSegment(p, a: vertices[i], b: vertices[(i + 1) % vertices.count])
                if d < best { best = d }
            }
            sum += best
        }
        return sum / CGFloat(pts.count)
    }

    private static func meanDistanceToSample(_ pts: [CGPoint], reference: [CGPoint]) -> CGFloat {
        guard !pts.isEmpty, !reference.isEmpty else { return .infinity }
        var sum: CGFloat = 0
        for p in pts {
            var best = CGFloat.infinity
            for r in reference {
                let d = hypot(p.x - r.x, p.y - r.y)
                if d < best { best = d }
            }
            sum += best
        }
        return sum / CGFloat(pts.count)
    }

    private static func douglasPeucker(_ pts: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var maxDist: CGFloat = 0
        var index = 0
        let first = pts[0], last = pts[pts.count - 1]
        for i in 1..<(pts.count - 1) {
            let d = perpendicularDistance(pts[i], from: first, to: last)
            if d > maxDist { maxDist = d; index = i }
        }
        if maxDist > epsilon {
            let left = douglasPeucker(Array(pts[0...index]), epsilon: epsilon)
            let right = douglasPeucker(Array(pts[index...]), epsilon: epsilon)
            return Array(left.dropLast()) + right
        }
        return [first, last]
    }

    private static func mergeNearCollinearVertices(_ verts: [CGPoint],
                                                   minEdgeLength: CGFloat) -> [CGPoint] {
        var out = verts
        var changed = true
        while changed && out.count > 3 {
            changed = false
            for i in out.indices {
                let prev = out[(i + out.count - 1) % out.count]
                let cur = out[i]
                let next = out[(i + 1) % out.count]
                let edge1 = hypot(cur.x - prev.x, cur.y - prev.y)
                let edge2 = hypot(next.x - cur.x, next.y - cur.y)
                let angle = interiorAngle(a: prev, vertex: cur, b: next)
                // Remove redundant vertex on a nearly straight edge or tiny corner stub.
                if angle > .pi - 0.32 || min(edge1, edge2) < minEdgeLength {
                    out.remove(at: i)
                    changed = true
                    break
                }
            }
        }
        return out
    }

    private static func interiorAngle(a: CGPoint, vertex v: CGPoint, b: CGPoint) -> CGFloat {
        let u = CGPoint(x: a.x - v.x, y: a.y - v.y)
        let w = CGPoint(x: b.x - v.x, y: b.y - v.y)
        let mag = hypot(u.x, u.y) * hypot(w.x, w.y)
        guard mag > 0.0001 else { return .pi }
        let cosA = max(-1, min(1, (u.x * w.x + u.y * w.y) / mag))
        return acos(cosA)
    }

    private static func polygonArea(_ verts: [CGPoint]) -> CGFloat {
        guard verts.count >= 3 else { return 0 }
        var sum: CGFloat = 0
        for i in verts.indices {
            let p = verts[i], q = verts[(i + 1) % verts.count]
            sum += p.x * q.y - q.x * p.y
        }
        return abs(sum) / 2
    }

    private static func totalTurningAngle(_ pts: [CGPoint]) -> CGFloat {
        var turning: CGFloat = 0
        var lastHeading: CGFloat? = nil
        for i in 1..<pts.count {
            let dx = pts[i].x - pts[i - 1].x, dy = pts[i].y - pts[i - 1].y
            guard dx * dx + dy * dy > 1 else { continue }
            let heading = atan2(dy, dx)
            if let prev = lastHeading {
                var d = heading - prev
                while d > .pi { d -= 2 * .pi }
                while d < -.pi { d += 2 * .pi }
                turning += d
            }
            lastHeading = heading
        }
        return turning
    }

    private static func medianWidth(of stroke: PKStroke) -> CGFloat {
        var widths: [CGFloat] = []
        for pt in stroke.path.interpolatedPoints(by: .distance(4)) {
            let w = max(pt.size.width, pt.size.height)
            if w > 0.4 { widths.append(w) }
        }
        guard !widths.isEmpty else { return 3 }
        widths.sort()
        return min(24, max(1.2, widths[widths.count / 2]))
    }
}
