//
//  GestureTests.swift
//  penpalTests
//
//  PEN-07 — the drawn-intent vocabulary.
//
//  These gestures act on the user's page without asking. A false positive
//  therefore rewrites their work uninvited, which is far worse than a gesture
//  that occasionally needs a second try. Every test below is really asking the
//  same question: does this fire ONLY when the user clearly meant it?
//
//  The negative cases matter more than the positive ones. Most of this file is
//  things that must NOT be mistaken for a gesture.
//

import XCTest
import PencilKit
@testable import penpal

final class GestureTests: XCTestCase {

    // MARK: - Builders

    /// A stroke along a straight line, sampled densely enough to survive
    /// `interpolatedPoints(by: .distance(4))`.
    private func stroke(from a: CGPoint, to b: CGPoint) -> PKStroke {
        let steps = max(2, Int(hypot(b.x - a.x, b.y - a.y) / 2))
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

    /// A blob of ink standing in for a written word.
    private func word(x: CGFloat, y: CGFloat,
                      width: CGFloat = 90, height: CGFloat = 24) -> PKStroke {
        var points: [PKStrokePoint] = []
        let steps = 40
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            points.append(PKStrokePoint(
                location: CGPoint(x: x + width * t,
                                  y: y + height * (i % 2 == 0 ? 0 : 1)),
                timeOffset: Double(i) * 0.004,
                size: CGSize(width: 3, height: 3),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
        }
        return PKStroke(ink: PKInk(.pen, color: .black),
                        path: PKStrokePath(controlPoints: points,
                                           creationDate: Date()))
    }

    private func rule(x: CGFloat, y: CGFloat, width: CGFloat = 200) -> PKStroke {
        stroke(from: CGPoint(x: x, y: y), to: CGPoint(x: x + width, y: y))
    }

    private func isCheckWork(_ g: InkAnalyzer.Gesture?) -> Bool {
        if case .checkWork = g { return true }
        return false
    }

    private func isStrike(_ g: InkAnalyzer.Gesture?) -> Bool {
        if case .strikeThrough = g { return true }
        return false
    }

    private func isScribble(_ g: InkAnalyzer.Gesture?) -> Bool {
        if case .scribbleErase = g { return true }
        return false
    }

    /// Dense zig-zag scribble covering `rect` (mimics scratching out a math digit/term).
    private func scribble(over rect: CGRect, passes: Int = 6) -> PKStroke {
        var pts: [CGPoint] = []
        for i in 0...passes {
            let t = CGFloat(i) / CGFloat(passes)
            let y = rect.minY + rect.height * t
            let x = i % 2 == 0 ? rect.minX : rect.maxX
            pts.append(CGPoint(x: x, y: y))
        }
        // Densify each segment so interpolatedPoints has plenty of samples.
        var dense: [PKStrokePoint] = []
        var time: Double = 0
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let steps = max(4, Int(hypot(b.x - a.x, b.y - a.y) / 2))
            for s in 0...steps {
                let f = CGFloat(s) / CGFloat(steps)
                dense.append(PKStrokePoint(
                    location: CGPoint(x: a.x + (b.x - a.x) * f,
                                      y: a.y + (b.y - a.y) * f),
                    timeOffset: time,
                    size: CGSize(width: 3, height: 3),
                    opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
                time += 0.004
            }
        }
        return PKStroke(ink: PKInk(.pen, color: .black),
                        path: PKStrokePath(controlPoints: dense, creationDate: Date()))
    }

    // MARK: - Double underline → check my working

    func testDoubleUnderlineUnderWorkingIsRecognised() {
        let strokes = [word(x: 20, y: 20), word(x: 20, y: 60), word(x: 20, y: 100),
                       rule(x: 20, y: 150), rule(x: 20, y: 160)]
        let gesture = InkAnalyzer.detectGesture(all: strokes, newStart: 3)
        XCTAssertTrue(isCheckWork(gesture))
        if case .checkWork(let region, let indices) = gesture {
            // The region is the working ABOVE the mark, not the mark itself.
            XCTAssertLessThan(region.maxY, 150)
            XCTAssertEqual(Set(indices), [3, 4])
        }
    }

    func testSingleUnderlineIsNotAGesture() {
        // One line under a word is ordinary emphasis. Acting on it would make
        // underlining anything unusable.
        let strokes = [word(x: 20, y: 20), rule(x: 20, y: 150)]
        XCTAssertNil(InkAnalyzer.detectGesture(all: strokes, newStart: 1))
    }

    func testTwoRulesFarApartAreNotAPair() {
        let strokes = [word(x: 20, y: 20), rule(x: 20, y: 150), rule(x: 20, y: 300)]
        XCTAssertFalse(isCheckWork(
            InkAnalyzer.detectGesture(all: strokes, newStart: 1)))
    }

    func testMismatchedRuleLengthsAreNotAPair() {
        let strokes = [word(x: 20, y: 20),
                       rule(x: 20, y: 150, width: 220),
                       rule(x: 20, y: 160, width: 60)]
        XCTAssertFalse(isCheckWork(
            InkAnalyzer.detectGesture(all: strokes, newStart: 1)))
    }

    func testHorizontallyOffsetRulesAreNotAPair() {
        let strokes = [word(x: 20, y: 20),
                       rule(x: 20, y: 150), rule(x: 320, y: 160)]
        XCTAssertFalse(isCheckWork(
            InkAnalyzer.detectGesture(all: strokes, newStart: 1)))
    }

    func testDoubleUnderlineWithNothingAboveDoesNothing() {
        // Nothing to check — must not fire on an empty page.
        let strokes = [rule(x: 20, y: 150), rule(x: 20, y: 160)]
        XCTAssertNil(InkAnalyzer.detectGesture(all: strokes, newStart: 0))
    }

    // MARK: - Strike-through → delete

    func testStrikeThroughOneWordIsRecognised() {
        let target = word(x: 20, y: 20, width: 90, height: 24)
        let line = rule(x: 15, y: 32, width: 100)
        let gesture = InkAnalyzer.detectGesture(all: [target, line], newStart: 1)
        XCTAssertTrue(isStrike(gesture))
        if case .strikeThrough(let targets, let index) = gesture {
            XCTAssertEqual(targets, [0])
            XCTAssertEqual(index, 1)
        }
    }

    func testStrikeThroughSeveralWords() {
        let strokes = [word(x: 20, y: 20), word(x: 120, y: 20), word(x: 220, y: 20),
                       rule(x: 15, y: 32, width: 300)]
        if case .strikeThrough(let targets, _) =
            InkAnalyzer.detectGesture(all: strokes, newStart: 3) {
            XCTAssertEqual(Set(targets), [0, 1, 2])
        } else {
            XCTFail("three struck words were not detected")
        }
    }

    func testLinePassingBelowInkIsNotAStrike() {
        // This is an underline. Deleting the word would be catastrophic.
        let strokes = [word(x: 20, y: 20, width: 90, height: 24),
                       rule(x: 15, y: 52, width: 100)]
        XCTAssertFalse(isStrike(
            InkAnalyzer.detectGesture(all: strokes, newStart: 1)))
    }

    func testLongLineClippingOneLetterIsNotAStrike() {
        // A ruled line drawn across the page happens to cross one character.
        let strokes = [word(x: 20, y: 20, width: 20, height: 24),
                       rule(x: 15, y: 32, width: 400)]
        XCTAssertFalse(isStrike(
            InkAnalyzer.detectGesture(all: strokes, newStart: 1)))
    }

    // MARK: - Ordering

    func testGestureDetectionPrecedesBoxDetection() {
        // A double underline is also two long thin strokes. If box detection
        // ran first it could claim them, and "check my working" would instead
        // solve something.
        let strokes = [word(x: 20, y: 20), word(x: 20, y: 60),
                       rule(x: 20, y: 150), rule(x: 20, y: 160)]
        XCTAssertTrue(isCheckWork(
            InkAnalyzer.detectGesture(all: strokes, newStart: 2)))
    }

    func testOrdinaryWritingIsNeverAGesture() {
        // The most important negative case: normal handwriting must never
        // trigger anything.
        let strokes = (0..<6).map { word(x: 20, y: CGFloat($0) * 40 + 20) }
        XCTAssertNil(InkAnalyzer.detectGesture(all: strokes, newStart: 0))
    }

    func testEmptyAndSingleStrokePagesAreSafe() {
        XCTAssertNil(InkAnalyzer.detectGesture(all: [], newStart: 0))
        XCTAssertNil(InkAnalyzer.detectGesture(all: [word(x: 20, y: 20)],
                                               newStart: 0))
    }

    // MARK: - Intent Precedence Classification

    func testIntentPrecedenceClassification() {
        // 1. Strike-through beats everything
        let strikeStrokes = [word(x: 20, y: 20), rule(x: 15, y: 32, width: 100)]
        let strikeIntent = InkAnalyzer.classifyDrawnIntent(all: strikeStrokes, newStart: 1)
        if case .strikeThrough = strikeIntent {
            // Success
        } else {
            XCTFail("Expected strikeThrough intent")
        }

        // 2. Double-underline check
        let underlineStrokes = [word(x: 20, y: 20), rule(x: 20, y: 150), rule(x: 20, y: 160)]
        let underlineIntent = InkAnalyzer.classifyDrawnIntent(all: underlineStrokes, newStart: 1)
        if case .checkWork = underlineIntent {
            // Success
        } else {
            XCTFail("Expected checkWork intent")
        }

        // 3. Theory text is passive, never treated as calculation
        let theoryIntent = InkAnalyzer.classifyDrawnIntent(all: [word(x: 20, y: 20)], newStart: 0, text: "Force F = ma")
        if case .passiveNote(let reason) = theoryIntent {
            XCTAssertTrue(reason.contains("Theory"))
        } else {
            XCTFail("Expected passiveNote for theory text")
        }

        // 4. Arithmetic ending in "=" is inlineMath
        let mathIntent = InkAnalyzer.classifyDrawnIntent(all: [word(x: 20, y: 20)], newStart: 0, text: "15 * 4 =")
        if case .inlineMath(let isTrailing) = mathIntent {
            XCTAssertTrue(isTrailing)
        } else {
            XCTFail("Expected inlineMath for arithmetic ending in =")
        }

        // 5. Unit conversions and percentages ending in "=" are inlineMath, not passive prose
        let pctIntent = InkAnalyzer.classifyDrawnIntent(all: [word(x: 20, y: 20)], newStart: 0, text: "15% of 80 =")
        if case .inlineMath = pctIntent {
        } else {
            XCTFail("Expected inlineMath for percentage expression")
        }
    }

    // MARK: - Scribble-to-erase (ideal for single digits & math terms)

    func testScribbleOverSingleDigitIsRecognised() {
        // A single tall digit ("7" or "5") that's too narrow for a 60pt strike-through.
        let digit = stroke(from: CGPoint(x: 50, y: 40), to: CGPoint(x: 68, y: 66))
        let scratch = scribble(over: CGRect(x: 46, y: 38, width: 28, height: 30), passes: 6)
        let gesture = InkAnalyzer.detectGesture(all: [digit, scratch], newStart: 1)
        XCTAssertTrue(isScribble(gesture))
        if case .scribbleErase(let targets, let index) = gesture {
            XCTAssertEqual(targets, [0])
            XCTAssertEqual(index, 1)
        }
    }

    func testScribbleOverMathTermErasesAllCoveredStrokes() {
        let digit = stroke(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 55, y: 64))
        let varX1 = stroke(from: CGPoint(x: 62, y: 44), to: CGPoint(x: 78, y: 64))
        let varX2 = stroke(from: CGPoint(x: 78, y: 44), to: CGPoint(x: 62, y: 64))
        let untouched = stroke(from: CGPoint(x: 160, y: 40), to: CGPoint(x: 175, y: 64))
        let scratch = scribble(over: CGRect(x: 38, y: 38, width: 44, height: 30), passes: 7)
        let gesture = InkAnalyzer.detectGesture(all: [digit, varX1, varX2, untouched, scratch], newStart: 4)
        if case .scribbleErase(let targets, let idx) = gesture {
            XCTAssertEqual(Set(targets), [0, 1, 2])
            XCTAssertEqual(idx, 4)
        } else {
            XCTFail("Expected scribbleErase covering 3x while sparing untouched stroke")
        }
    }

    func testScribbleInEmptySpaceDoesNothing() {
        let digit = stroke(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 55, y: 64))
        let emptyScratch = scribble(over: CGRect(x: 200, y: 200, width: 40, height: 30), passes: 6)
        XCTAssertFalse(isScribble(InkAnalyzer.detectGesture(all: [digit, emptyScratch], newStart: 1)))
    }

    func testCrossingPlusSignIsNotAScribble() {
        let horiz = stroke(from: CGPoint(x: 40, y: 52), to: CGPoint(x: 64, y: 52))
        let vert = stroke(from: CGPoint(x: 52, y: 40), to: CGPoint(x: 52, y: 64))
        XCTAssertNil(InkAnalyzer.detectGesture(all: [horiz, vert], newStart: 1))
    }
}
