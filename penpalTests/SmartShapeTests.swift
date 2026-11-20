//
//  SmartShapeTests.swift
//  penpalTests
//
//  Verifies SmartShapeEngine recognition, angle/endpoint/grid snapping,
//  sharp-corner PKStroke synthesis, live Draw & Hold adjustments, and
//  handwriting non-interference.
//

import XCTest
import CoreGraphics
import PencilKit
@testable import penpal

final class SmartShapeTests: XCTestCase {

    // MARK: - Helpers

    private func samplePolyline(_ vertices: [CGPoint], step: CGFloat = 4, jitter: CGFloat = 0) -> [CGPoint] {
        var pts: [CGPoint] = []
        var seed: UInt64 = 42
        func nextNoise() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1
            let u = CGFloat((seed >> 33) & 0xFFFF) / CGFloat(0xFFFF)
            return (u * 2 - 1) * jitter
        }
        for i in 0..<(vertices.count - 1) {
            let a = vertices[i], b = vertices[i + 1]
            let dist = hypot(b.x - a.x, b.y - a.y)
            let steps = max(2, Int(ceil(dist / step)))
            for s in 0..<steps {
                let t = CGFloat(s) / CGFloat(steps)
                pts.append(CGPoint(
                    x: a.x + (b.x - a.x) * t + nextNoise(),
                    y: a.y + (b.y - a.y) * t + nextNoise()
                ))
            }
        }
        if let last = vertices.last { pts.append(last) }
        return pts
    }

    private func sampleCircle(center: CGPoint, rx: CGFloat, ry: CGFloat,
                              angle: CGFloat = 0, count: Int = 72,
                              jitter: CGFloat = 0) -> [CGPoint] {
        var seed: UInt64 = 7
        func nextNoise() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1
            let u = CGFloat((seed >> 33) & 0xFFFF) / CGFloat(0xFFFF)
            return (u * 2 - 1) * jitter
        }
        let c = cos(angle), s = sin(angle)
        return (0...count).map { i in
            let t = CGFloat(i) / CGFloat(count) * 2 * .pi
            let lx = cos(t) * rx
            let ly = sin(t) * ry
            return CGPoint(
                x: center.x + lx * c - ly * s + nextNoise(),
                y: center.y + lx * s + ly * c + nextNoise()
            )
        }
    }

    private func makePKStroke(from points: [CGPoint], color: UIColor = .systemBlue, width: CGFloat = 3.5) -> PKStroke {
        let size = CGSize(width: width, height: width)
        let ctrl = points.enumerated().map { idx, pt in
            PKStrokePoint(location: pt, timeOffset: Double(idx) * 0.01,
                          size: size, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: color),
                        path: PKStrokePath(controlPoints: ctrl, creationDate: Date()))
    }

    // MARK: - Open Shapes

    func testRecognizesRoughHorizontalLineAndSnapsFlat() {
        // Slightly wobbly ~4° line should snap to exact horizontal.
        let pts = samplePolyline([CGPoint(x: 40, y: 120), CGPoint(x: 240, y: 132)], jitter: 2.0)
        guard case .line(let from, let to) = SmartShapeEngine.recognize(points: pts) else {
            return XCTFail("Expected .line")
        }
        XCTAssertEqual(from.y, to.y, accuracy: 0.5, "Nearly horizontal line should snap to 0°")
        XCTAssertGreaterThan(to.x - from.x, 180)
    }

    func testRecognizesDiagonal45DegreeLine() {
        // ~43° diagonal should snap to exact 45°.
        let pts = samplePolyline([CGPoint(x: 50, y: 50), CGPoint(x: 195, y: 185)], jitter: 1.5)
        guard case .line(let from, let to) = SmartShapeEngine.recognize(points: pts) else {
            return XCTFail("Expected .line")
        }
        XCTAssertEqual(abs(to.x - from.x), abs(to.y - from.y), accuracy: 1.5)
    }

    func testRecognizesSingleStrokeArrow() {
        // Long horizontal shaft + backward barb.
        let pts = samplePolyline([
            CGPoint(x: 60, y: 200),
            CGPoint(x: 240, y: 202),
            CGPoint(x: 215, y: 184)
        ], jitter: 1.2)
        guard case .arrow(let from, let to, let headLen) = SmartShapeEngine.recognize(points: pts) else {
            return XCTFail("Expected .arrow")
        }
        XCTAssertEqual(from.y, to.y, accuracy: 1.0)
        XCTAssertGreaterThan(headLen, 12)
    }

    func testRecognizesRightAngleCorner() {
        // L-shaped axis / right corner (~86° rough draw snaps to exact 90°).
        let pts = samplePolyline([
            CGPoint(x: 100, y: 80),
            CGPoint(x: 104, y: 220),
            CGPoint(x: 250, y: 226)
        ], jitter: 1.5)
        guard case .rightAngle(let a, let v, let b) = SmartShapeEngine.recognize(points: pts) else {
            return XCTFail("Expected .rightAngle")
        }
        let v1 = CGPoint(x: a.x - v.x, y: a.y - v.y)
        let v2 = CGPoint(x: b.x - v.x, y: b.y - v.y)
        let dot = (v1.x * v2.x + v1.y * v2.y) / (hypot(v1.x, v1.y) * hypot(v2.x, v2.y))
        XCTAssertEqual(dot, 0, accuracy: 0.05, "Snapped right angle should be perpendicular")
    }

    func testRecognizesSmoothArc() {
        // Gentle semicircular arc (open curve).
        let pts: [CGPoint] = (0...40).map { i in
            let t = CGFloat(i) / 40.0 * .pi * 0.75
            return CGPoint(x: 200 + cos(t) * 90, y: 200 + sin(t) * 90)
        }
        guard case .arc = SmartShapeEngine.recognize(points: pts) else {
            return XCTFail("Expected .arc")
        }
    }

    // MARK: - Closed Shapes

    func testRecognizesRoughCircleAsPerfectCircle() {
        let pts = sampleCircle(center: CGPoint(x: 200, y: 200), rx: 72, ry: 68, jitter: 2.2)
        guard case .circle(let center, let radius) = SmartShapeEngine.recognize(points: pts) else {
            return XCTFail("Expected .circle")
        }
        XCTAssertEqual(center.x, 200, accuracy: 6)
        XCTAssertEqual(center.y, 200, accuracy: 6)
        XCTAssertEqual(radius, 70, accuracy: 6)
    }

    func testRecognizesTiltedEllipse() {
        let pts = sampleCircle(center: CGPoint(x: 240, y: 220), rx: 110, ry: 52, angle: 0.35, jitter: 1.5)
        guard case .ellipse(let center, let rx, let ry, _) = SmartShapeEngine.recognize(points: pts) else {
            return XCTFail("Expected .ellipse")
        }
        XCTAssertEqual(center.x, 240, accuracy: 8)
        XCTAssertEqual(center.y, 220, accuracy: 8)
        XCTAssertGreaterThan(max(rx, ry) / min(rx, ry), 1.6)
    }

    func testRecognizesRoughSquareAsPerfectSquare() {
        let pts = samplePolyline([
            CGPoint(x: 100, y: 100),
            CGPoint(x: 224, y: 104),
            CGPoint(x: 220, y: 220),
            CGPoint(x: 98, y: 218),
            CGPoint(x: 102, y: 103)
        ], jitter: 1.8)
        guard case .square(_, let side, let angle) = SmartShapeEngine.recognize(points: pts) else {
            return XCTFail("Expected .square")
        }
        XCTAssertEqual(side, 120, accuracy: 12)
        XCTAssertEqual(angle, 0, accuracy: 0.1)
    }

    func testRecognizesRectangle() {
        let pts = samplePolyline([
            CGPoint(x: 60, y: 100),
            CGPoint(x: 280, y: 103),
            CGPoint(x: 278, y: 202),
            CGPoint(x: 62, y: 200),
            CGPoint(x: 61, y: 102)
        ], jitter: 1.5)
        guard case .rectangle(_, let size, _) = SmartShapeEngine.recognize(points: pts) else {
            return XCTFail("Expected .rectangle")
        }
        XCTAssertEqual(max(size.width, size.height), 218, accuracy: 16)
        XCTAssertEqual(min(size.width, size.height), 100, accuracy: 14)
    }

    func testRecognizesRightTriangleWithExact90DegreeVertex() {
        let pts = samplePolyline([
            CGPoint(x: 80, y: 80),
            CGPoint(x: 84, y: 230),
            CGPoint(x: 260, y: 226),
            CGPoint(x: 82, y: 82)
        ], jitter: 1.5)
        guard case .triangle(let a, let b, let c, let isRight, _) = SmartShapeEngine.recognize(points: pts) else {
            return XCTFail("Expected .triangle")
        }
        XCTAssertTrue(isRight, "Rough right triangle should snap to an exact 90° corner")
        // Verify at least one vertex is perpendicular.
        let triples = [(a, b, c), (b, c, a), (c, a, b)]
        let minDot = triples.map { p, v, q -> CGFloat in
            let u = CGPoint(x: p.x - v.x, y: p.y - v.y)
            let w = CGPoint(x: q.x - v.x, y: q.y - v.y)
            return abs((u.x * w.x + u.y * w.y) / (hypot(u.x, u.y) * hypot(w.x, w.y)))
        }.min() ?? 1
        XCTAssertLessThan(minDot, 0.04)
    }

    func testRecognizesEquilateralTriangle() {
        let r: CGFloat = 80
        let center = CGPoint(x: 200, y: 200)
        let verts = (0..<3).map { i -> CGPoint in
            let t = -CGFloat.pi / 2 + CGFloat(i) * (2 * .pi / 3)
            return CGPoint(x: center.x + cos(t) * r, y: center.y + sin(t) * r)
        }
        let pts = samplePolyline(verts + [verts[0]], jitter: 1.5)
        guard case .triangle(_, _, _, _, let isEq) = SmartShapeEngine.recognize(points: pts) else {
            return XCTFail("Expected .triangle")
        }
        XCTAssertTrue(isEq, "Near-equilateral triangle should snap to exact equilateral")
    }

    func testRecognizesHexagon() {
        let r: CGFloat = 75
        let center = CGPoint(x: 200, y: 200)
        let verts = (0..<6).map { i -> CGPoint in
            let t = CGFloat(i) * (2 * .pi / 6)
            return CGPoint(x: center.x + cos(t) * r, y: center.y + sin(t) * r)
        }
        let pts = samplePolyline(verts + [verts[0]], jitter: 1.0)
        guard case .polygon(let poly) = SmartShapeEngine.recognize(points: pts) else {
            return XCTFail("Expected .polygon")
        }
        XCTAssertEqual(poly.count, 6)
    }

    // MARK: - Magnetic Endpoint & Grid Snapping

    func testMagneticEndpointSnappingConnectsLinesToExistingVertices() {
        let anchor = CGPoint(x: 100, y: 150)
        let ctx = SmartShapeEngine.SnapContext(existingEndpoints: [anchor])
        let pts = samplePolyline([CGPoint(x: 106, y: 155), CGPoint(x: 250, y: 155)], jitter: 0.5)
        guard case .line(let from, _) = SmartShapeEngine.recognize(points: pts, context: ctx) else {
            return XCTFail("Expected .line")
        }
        XCTAssertEqual(from.x, anchor.x, accuracy: 0.01)
        XCTAssertEqual(from.y, anchor.y, accuracy: 0.01)
    }

    func testGridSnappingAlignsLineStartToGridIntersection() {
        let ctx = SmartShapeEngine.SnapContext(
            existingEndpoints: [],
            gridOrigin: CGPoint(x: 12, y: 40),
            gridSpacing: 22
        )
        // Nearest grid point to (102, 108) is (12 + 4*22 = 100, 40 + 3*22 = 106).
        let pts = samplePolyline([CGPoint(x: 102, y: 108), CGPoint(x: 232, y: 107)], jitter: 0.3)
        guard case .line(let from, _) = SmartShapeEngine.recognize(points: pts, context: ctx) else {
            return XCTFail("Expected .line")
        }
        XCTAssertEqual(from.x, 100, accuracy: 0.01)
        XCTAssertEqual(from.y, 106, accuracy: 0.01)
    }

    // MARK: - Live Adjustment & PKStroke Synthesis

    func testLiveAdjustmentUpdatesSnappedLineAndCircle() {
        let line = SmartShapeEngine.RecognizedShape.line(from: CGPoint(x: 50, y: 100),
                                                         to: CGPoint(x: 150, y: 100))
        let stretched = SmartShapeEngine.adjusted(line, draggingTo: CGPoint(x: 260, y: 105))
        guard case .line(let from, let to) = stretched else { return XCTFail("Expected .line") }
        XCTAssertEqual(from, CGPoint(x: 50, y: 100))
        XCTAssertEqual(to.x, 260, accuracy: 2)
        XCTAssertEqual(to.y, 100, accuracy: 1, "Dragged nearly-horizontal line should keep angle snap")

        let circle = SmartShapeEngine.RecognizedShape.circle(center: CGPoint(x: 200, y: 200), radius: 50)
        let resized = SmartShapeEngine.adjusted(circle, draggingTo: CGPoint(x: 310, y: 200))
        guard case .circle(let c, let r) = resized else { return XCTFail("Expected .circle") }
        XCTAssertEqual(c, CGPoint(x: 200, y: 200))
        XCTAssertEqual(r, 110, accuracy: 1)
    }

    func testMakeStrokePreservesInkAndProducesValidGeometry() {
        let pts = samplePolyline([
            CGPoint(x: 100, y: 100),
            CGPoint(x: 200, y: 100),
            CGPoint(x: 200, y: 200),
            CGPoint(x: 100, y: 200),
            CGPoint(x: 100, y: 100)
        ])
        let raw = makePKStroke(from: pts, color: .systemIndigo, width: 4.0)
        guard let shape = SmartShapeEngine.recognize(stroke: raw),
              let snapped = SmartShapeEngine.makeStroke(for: shape, matching: raw) else {
            return XCTFail("Expected recognized shape and synthesized PKStroke")
        }
        XCTAssertEqual(snapped.ink.inkType, raw.ink.inkType)
        XCTAssertGreaterThan(snapped.path.count, 40)
        XCTAssertFalse(snapped.renderBounds.isEmpty)
    }

    // MARK: - Handwriting Safety (Negative Tests)

    func testDoesNotSnapTinyHandwritingGlyphs() {
        // Small handwritten "o" (~14pt) and short "1" (~16pt) must NOT snap.
        let smallO = sampleCircle(center: CGPoint(x: 100, y: 100), rx: 7, ry: 8, count: 24)
        let smallOne = samplePolyline([CGPoint(x: 120, y: 92), CGPoint(x: 120, y: 108)])
        XCTAssertNil(SmartShapeEngine.recognize(points: smallO))
        XCTAssertNil(SmartShapeEngine.recognize(points: smallOne))
    }

    func testDoesNotSnapWavyScribbleOrSLetter() {
        // Sinusoidal S-like / scribble wave has inflection changes and must not snap.
        let wave: [CGPoint] = (0...40).map { i in
            let t = CGFloat(i) / 40.0
            return CGPoint(x: 80 + t * 140, y: 150 + sin(t * .pi * 3) * 28)
        }
        XCTAssertNil(SmartShapeEngine.recognize(points: wave))
    }
}
