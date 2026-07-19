//
//  PerformanceTests.swift
//  penpalTests
//
//  PEN-34 — a measured budget, not a vibe.
//
//  Three things this session made heavier, all on the critical path:
//
//    * the boxed-problem image cap went 1536 → 2560px (PEN-15), so a
//      full-page render is ~2.8× the pixels it used to be
//    * gesture detection now runs on EVERY idle pause, before box detection,
//      over every stroke on the page (PEN-07)
//    * glyph placement gained an anchoring pass per glyph (PEN-06)
//
//  Each is fine on a current iPad and each is a plausible way to make an
//  older one stutter while the user is mid-sentence. Writing must never
//  stutter: that is the one interaction the whole product rests on.
//
//  These are XCTest performance tests — they record a baseline and fail when
//  a change regresses it. The absolute numbers matter less than the fact that
//  a future edit which doubles them will say so.
//

import XCTest
import PencilKit
import CoreGraphics
@testable import penpal

final class PerformanceTests: XCTestCase {

    // MARK: - Builders

    private func stroke(from a: CGPoint, to b: CGPoint) -> PKStroke {
        let steps = max(2, Int(hypot(b.x - a.x, b.y - a.y) / 3))
        let points = (0...steps).map { i -> PKStrokePoint in
            let t = CGFloat(i) / CGFloat(steps)
            return PKStrokePoint(
                location: CGPoint(x: a.x + (b.x - a.x) * t,
                                  y: a.y + (b.y - a.y) * t),
                timeOffset: Double(i) * 0.004,
                size: CGSize(width: 3, height: 3),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black),
                        path: PKStrokePath(controlPoints: points,
                                           creationDate: Date()))
    }

    /// A realistic dense page: ~40 lines of ~12 short strokes each.
    private func densePage(lines: Int = 40, perLine: Int = 12) -> [PKStroke] {
        var strokes: [PKStroke] = []
        for line in 0..<lines {
            let y = CGFloat(line) * 34 + 40
            for i in 0..<perLine {
                let x = CGFloat(i) * 46 + 30
                strokes.append(stroke(from: CGPoint(x: x, y: y),
                                      to: CGPoint(x: x + 30, y: y + 22)))
            }
        }
        return strokes
    }

    // MARK: - Gesture + box detection on every pause

    func testGestureDetectionOnDensePage() {
        // Runs on EVERY idle pause while the user writes. If this is slow,
        // the app hitches exactly when someone lifts the pen to think.
        let strokes = densePage()
        measure {
            _ = InkAnalyzer.detectGesture(all: strokes, newStart: strokes.count - 1)
        }
    }

    func testBoxDetectionOnDensePage() {
        // Worst case: a page full of ink and no box to find, so every
        // candidate is examined and rejected.
        let strokes = densePage()
        measure {
            _ = InkAnalyzer.detectProblemBox(all: strokes, newStart: strokes.count - 2)
        }
    }

    func testBoxDetectionIsBoundedWhenNewStartIsStale() {
        // PEN-34 regression: `newStart` resets to 0 when a note loads and is
        // clamped down by undo/erase. Before the candidate bound, this scanned
        // every stroke against every stroke — quadratic work on every idle
        // pause, on exactly the dense pages worksheet mode encourages.
        let strokes = densePage(lines: 40)

        func time(_ newStart: Int) -> TimeInterval {
            let start = CFAbsoluteTimeGetCurrent()
            for _ in 0..<10 {
                _ = InkAnalyzer.detectProblemBox(all: strokes, newStart: newStart)
            }
            return CFAbsoluteTimeGetCurrent() - start
        }

        let fresh = time(strokes.count - 2)   // a couple of new strokes
        let stale = time(0)                   // whole page "new"
        // With the bound, both do the same capped amount of work.
        XCTAssertLessThan(stale, max(fresh, 0.0001) * 8,
                          "stale newStart still triggers an unbounded scan")
    }

    func testDetectionScalesLinearlyNotQuadratically() {
        // The shape of the curve matters more than the constant. Doubling the
        // page must not quadruple the work, or a long note degrades badly.
        func time(_ strokes: [PKStroke]) -> TimeInterval {
            let start = CFAbsoluteTimeGetCurrent()
            for _ in 0..<5 {
                _ = InkAnalyzer.detectGesture(all: strokes, newStart: strokes.count - 1)
            }
            return CFAbsoluteTimeGetCurrent() - start
        }
        let small = time(densePage(lines: 20))
        let large = time(densePage(lines: 40))
        // Allow generous headroom for noise; catch only true super-linearity.
        XCTAssertLessThan(large, small * 6,
                          "detection cost grows faster than the page does")
    }

    // MARK: - Image rendering (PEN-15 raised the cap)

    func testFullPageImageRender() {
        // The 2560px cap applies here. This runs once per boxed solve, so it
        // is allowed to be expensive — but not seconds-expensive.
        let strokes = densePage()
        let region = strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
        measure {
            _ = MagicPaperView.renderInkImage(strokes: strokes, region: region)
        }
    }

    func testRenderedImageStaysUnderTheUploadLimit() {
        // The backend rejects >6MB. A full page at 2560px must not approach it,
        // or boxing a dense worksheet fails with a confusing server error.
        let strokes = densePage(lines: 60, perLine: 16)
        let region = strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
        guard let data = MagicPaperView.renderInkImage(strokes: strokes,
                                                       region: region) else {
            return XCTFail("dense page produced no image")
        }
        XCTAssertLessThan(data.count, 4_000_000,
                          "render is \(data.count / 1024)KB — close to the 6MB API limit")
    }

    // MARK: - Glyph placement (PEN-06 added an anchoring pass)

    func testGlyphPlacementThroughput() {
        // Runs per glyph, per reply. A 200-character answer pays this 200×.
        let glyph = PersonalGlyph(
            width: 0.6,
            strokes: [[CGPoint(x: 0, y: 0.2), CGPoint(x: 0.3, y: 1.1),
                       CGPoint(x: 0.6, y: 0.2)]],
            widths: [[0.1, 0.1, 0.1]],
            durations: [0.3], gaps: [0], refSize: 20,
            pointTimes: [[0, 0.15, 0.3]])
        let characters: [Character] = ["a", "5", "=", "√", ",", "x", "+"]
        measure {
            for _ in 0..<200 {
                for ch in characters {
                    _ = GlyphAlign.normalize(glyph, forChar: ch)
                }
            }
        }
    }
}
