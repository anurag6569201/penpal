//
//  GlyphGeometryTests.swift
//  penpalTests
//
//  PEN-01 — golden-file regression suite for glyph geometry.
//
//  WHY THIS EXISTS
//
//  BB-01 ("some symbols small, some large, some below the baseline") was three
//  separate defects that each looked fine in isolation and only compounded on a
//  real page:
//
//    1. capture-side: math symbols got no vertical or size normalization at all
//    2. render-side:  reseat() baseline-snapped symbols, undoing any fix
//    3. trainer-side: each symbol measured against its OWN bounding box
//
//  Any one of them alone would have been survivable. The reason they shipped is
//  that nothing asserted where a glyph is supposed to SIT. These tests do.
//
//  The contract, stated once:
//    * math operators are anchored by their vertical CENTRE (the math axis)
//    * digits sit ON the baseline and reach cap height
//    * letters keep the size the user trained (line trust) and are seated
//    * every rule is IDEMPOTENT, so the migration can be re-run safely
//
//  If a future change to GlyphAlign / ScaleConsensus / InkUnity moves ink, one
//  of these fails. That is the point — PEN-06 (single-owner geometry) is only
//  safe to attempt with this net underneath it.
//

import XCTest
import CoreGraphics
@testable import penpal

@MainActor
final class GlyphGeometryTests: XCTestCase {

    // MARK: - Builders

    /// A glyph from raw unit-space strokes (baseline y = 0, x-height y = 1).
    private func make(_ strokes: [[CGPoint]]) -> PersonalGlyph {
        let width = strokes.flatMap { $0 }.map(\.x).max() ?? 1
        return PersonalGlyph(
            width: max(0.2, width),
            strokes: strokes,
            widths: strokes.map { Array(repeating: 0.1, count: $0.count) },
            durations: strokes.map { _ in 0.3 },
            gaps: strokes.map { _ in 0 },
            refSize: 20,
            pointTimes: strokes.map { s in (0..<s.count).map { Double($0) * 0.05 } }
        )
    }

    private func extent(_ g: PersonalGlyph) -> (lo: CGFloat, hi: CGFloat) {
        let ys = g.strokes.flatMap { $0 }.map(\.y)
        return (ys.min() ?? 0, ys.max() ?? 0)
    }

    private func centre(_ g: PersonalGlyph) -> CGFloat {
        let e = extent(g)
        return (e.lo + e.hi) / 2
    }

    private func height(_ g: PersonalGlyph) -> CGFloat {
        let e = extent(g)
        return e.hi - e.lo
    }

    /// Two horizontal bars — an "=" drawn at an arbitrary place and size.
    private func equalsGlyph(centre c: CGFloat, height h: CGFloat) -> PersonalGlyph {
        make([[CGPoint(x: 0, y: c + h / 2), CGPoint(x: 0.5, y: c + h / 2)],
              [CGPoint(x: 0, y: c - h / 2), CGPoint(x: 0.5, y: c - h / 2)]])
    }

    /// A box — a digit drawn at an arbitrary place and size.
    private func digitGlyph(bottom: CGFloat, height h: CGFloat) -> PersonalGlyph {
        make([[CGPoint(x: 0, y: bottom), CGPoint(x: 0.5, y: bottom),
               CGPoint(x: 0.5, y: bottom + h), CGPoint(x: 0, y: bottom + h),
               CGPoint(x: 0, y: bottom)]])
    }

    // MARK: - Math operators are anchored by centre, not baseline

    func testEqualsIsAnchoredRegardlessOfHowItWasTrained() {
        guard let anchor = GlyphAlign.mathAnchors["="] else {
            return XCTFail("no anchor defined for =")
        }
        // The same symbol trained four different (wrong) ways.
        let captures: [(String, PersonalGlyph)] = [
            ("floating high",  equalsGlyph(centre: 1.20, height: 0.25)),
            ("on the baseline", equalsGlyph(centre: 0.03, height: 0.15)),
            ("three times too big", equalsGlyph(centre: 0.65, height: 0.90)),
            ("far too small",  equalsGlyph(centre: 0.40, height: 0.08)),
        ]
        for (label, raw) in captures {
            let g = GlyphAlign.normalize(raw, forChar: "=")
            XCTAssertEqual(centre(g), anchor.center, accuracy: 0.03,
                           "= trained \(label) did not land on the math axis")
            if let want = anchor.height {
                XCTAssertEqual(height(g), want, accuracy: 0.04,
                               "= trained \(label) is the wrong size")
            }
        }
    }

    func testOperatorsAreNeverDraggedOntoTheBaseline() {
        // The specific regression: an "=" that sits ON the line looks broken.
        // Every centre-anchored operator must float above it.
        for symbol in ["=", "+", "-", "×", "÷", "≈", "±"] {
            guard let ch = symbol.first,
                  let anchor = GlyphAlign.mathAnchors[ch] else { continue }
            let g = GlyphAlign.normalize(
                equalsGlyph(centre: 0.0, height: 0.2), forChar: ch)
            XCTAssertGreaterThan(centre(g), 0.2,
                                 "\(symbol) was snapped to the baseline")
            XCTAssertEqual(centre(g), anchor.center, accuracy: 0.03, symbol)
        }
    }

    func testEveryAnchoredSymbolLandsOnItsAnchor() {
        for (ch, anchor) in GlyphAlign.mathAnchors {
            let g = GlyphAlign.normalize(
                equalsGlyph(centre: 0.9, height: 0.45), forChar: ch)
            XCTAssertEqual(centre(g), anchor.center, accuracy: 0.03,
                           "\(ch) missed its anchor")
            if let want = anchor.height {
                XCTAssertEqual(height(g), want, accuracy: 0.05,
                               "\(ch) is the wrong height")
            }
            XCTAssertTrue(PersonalFontStore.isValid(g), "\(ch) became invalid")
        }
    }

    // MARK: - Digits sit on the baseline at cap height

    func testDigitsAreSeatedAndSizedConsistently() {
        let cap = HandMetrics.active.ascender
        let captures: [(String, PersonalGlyph)] = [
            ("floating above the line", digitGlyph(bottom: 0.90, height: 1.00)),
            ("far too small",           digitGlyph(bottom: 0.00, height: 0.80)),
            ("sunk below the line",     digitGlyph(bottom: -0.45, height: 1.65)),
            ("enormous",                digitGlyph(bottom: 0.00, height: 3.20)),
        ]
        for digit: Character in ["0", "3", "5", "7", "9"] {
            for (label, raw) in captures {
                let g = GlyphAlign.normalize(raw, forChar: digit)
                XCTAssertEqual(extent(g).lo, 0, accuracy: 0.05,
                               "\(digit) \(label) is off the baseline")
                XCTAssertEqual(height(g), cap, accuracy: 0.06,
                               "\(digit) \(label) is not at cap height")
            }
        }
    }

    func testAllDigitsShareOneHeight() {
        // "some numbers big, some small" — every digit trained differently must
        // still render at one consistent size.
        let heights: [CGFloat] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
            .enumerated()
            .map { index, ch in
                let raw = digitGlyph(bottom: CGFloat(index) * 0.1 - 0.3,
                                     height: 0.6 + CGFloat(index) * 0.25)
                return height(GlyphAlign.normalize(raw, forChar: Character(ch)))
            }
        let spread = (heights.max() ?? 0) - (heights.min() ?? 0)
        XCTAssertLessThan(spread, 0.08,
                          "digit heights vary by \(spread) — sizing is inconsistent")
    }

    // MARK: - Idempotence (migration safety)

    func testAnchoringIsIdempotent() {
        // realignStoredGlyphsIfNeeded may run more than once across versions.
        // A rule that converges only partially would drift the bank each pass.
        for (ch, _) in GlyphAlign.mathAnchors {
            let once = GlyphAlign.normalize(
                equalsGlyph(centre: 1.4, height: 0.7), forChar: ch)
            let twice = GlyphAlign.normalize(once, forChar: ch)
            XCTAssertEqual(centre(once), centre(twice), accuracy: 0.001,
                           "\(ch) drifted vertically on a second pass")
            XCTAssertEqual(height(once), height(twice), accuracy: 0.001,
                           "\(ch) changed size on a second pass")
        }
    }

    func testAnchoringIsExactForAnyRealisticCapture() {
        // "Realistic" = the capture is within the 4× scale clamp of its target.
        // Inside that band the correction must complete in ONE pass, which is
        // what makes the migration idempotent for real training data.
        for (ch, anchor) in GlyphAlign.mathAnchors {
            guard let target = anchor.height else { continue }
            for factor: CGFloat in [0.3, 0.5, 0.8, 1.0, 1.5, 2.5, 3.9] {
                let g = GlyphAlign.normalize(
                    equalsGlyph(centre: 0.9, height: target * factor), forChar: ch)
                XCTAssertEqual(height(g), target, accuracy: target * 0.06,
                               "\(ch) at \(factor)× target did not correct in one pass")
                XCTAssertEqual(centre(g), anchor.center, accuracy: 0.03, "\(ch)")
            }
        }
    }

    func testPathologicalCapturesConvergeWithoutOvershooting() {
        // Beyond the clamp a single pass can't finish, by design — the clamp
        // is what stops a garbage measurement producing a garbage scale.
        // The guarantee is then weaker but still safe: each pass moves
        // MONOTONICALLY toward the target and never crosses it, so re-running
        // the migration can only improve the bank, never oscillate or diverge.
        for (ch, anchor) in GlyphAlign.mathAnchors {
            guard let target = anchor.height else { continue }
            for probe in [equalsGlyph(centre: 0.4, height: 0.02),
                          equalsGlyph(centre: 2.0, height: 3.0),
                          equalsGlyph(centre: 0.0, height: 8.0)] {
                let startedAbove = height(probe) > target
                var g = probe
                var previousError = CGFloat.greatestFiniteMagnitude
                for pass in 1...10 {
                    g = GlyphAlign.normalize(g, forChar: ch)
                    let error = abs(height(g) - target)
                    XCTAssertLessThanOrEqual(error, previousError + 1e-6,
                                             "\(ch) moved away from target on pass \(pass)")
                    previousError = error
                    if startedAbove {
                        XCTAssertGreaterThanOrEqual(
                            height(g), target * 0.94 - 1e-6,
                            "\(ch) undershot past the target")
                    } else {
                        XCTAssertLessThanOrEqual(
                            height(g), target * 1.06 + 1e-6,
                            "\(ch) overshot past the target")
                    }
                }
            }
        }
    }

    func testRepeatedRenderingNeverDrifts() {
        // reseat() runs on EVERY render. It reads the stored glyph and the
        // result is never written back, so rendering the same glyph a hundred
        // times must produce one identical result — no accumulation.
        let stored = equalsGlyph(centre: 0.2, height: 0.5)
        let first = GlyphAlign.reseat(stored, forChar: "(")
        for _ in 0..<100 {
            let again = GlyphAlign.reseat(stored, forChar: "(")
            XCTAssertEqual(height(again), height(first), accuracy: 1e-9)
            XCTAssertEqual(centre(again), centre(first), accuracy: 1e-9)
        }
    }

    func testDigitAnchoringIsIdempotent() {
        let once = GlyphAlign.normalize(digitGlyph(bottom: 0.7, height: 2.4),
                                        forChar: "8")
        let twice = GlyphAlign.normalize(once, forChar: "8")
        XCTAssertEqual(extent(once).lo, extent(twice).lo, accuracy: 0.001)
        XCTAssertEqual(height(once), height(twice), accuracy: 0.001)
    }

    func testReseatDoesNotUndoAnchoring() {
        // BB-01 defect #2: reseat() ran at RENDER time and baseline-snapped
        // everything, silently defeating any capture-side fix.
        for symbol: Character in ["=", "+", "^", "√", "÷"] {
            guard let anchor = GlyphAlign.mathAnchors[symbol] else { continue }
            let anchored = GlyphAlign.normalize(
                equalsGlyph(centre: 0.9, height: 0.4), forChar: symbol)
            let reseated = GlyphAlign.reseat(anchored, forChar: symbol)
            XCTAssertEqual(centre(reseated), anchor.center, accuracy: 0.03,
                           "reseat() dragged \(symbol) off its anchor")
        }
    }

    // MARK: - Single-owner ownership model (PEN-06)

    func testCaptureAndRenderPlacementAgree() {
        // THE test that would have caught BB-01.
        //
        // `normalize` (capture) and `reseat` (render) used to hold separate
        // copies of the same classification logic, and disagreed about math
        // symbols: one anchored them, the other snapped them to the baseline.
        // A glyph was placed correctly and then moved somewhere else moments
        // before being drawn.
        //
        // Both now route through GlyphAlign.place, so for an already-placed
        // glyph the render pass must be a NO-OP for every character class.
        let samples: [Character] = ["=", "+", "-", "×", "÷", "√", "∫", "π", "^",
                                    "0", "5", "9", "a", "g", "M", ",", "'"]
        for ch in samples {
            let captured = GlyphAlign.normalize(
                equalsGlyph(centre: 0.8, height: 0.5), forChar: ch)
            let rendered = GlyphAlign.reseat(captured, forChar: ch)
            XCTAssertEqual(centre(rendered), centre(captured), accuracy: 0.02,
                           "capture and render disagree on where '\(ch)' sits")
            XCTAssertEqual(height(rendered), height(captured), accuracy: 0.02,
                           "capture and render disagree on how big '\(ch)' is")
        }
    }

    func testRoleClassificationIsExhaustiveAndStable() {
        // One classifier, so a character can never be two things at once.
        for ch in GlyphAlign.mathAnchors.keys {
            guard case .mathSymbol = GlyphAlign.role(for: ch) else {
                return XCTFail("'\(ch)' has an anchor but is not classed as a symbol")
            }
        }
        for ch: Character in ["0", "4", "9"] {
            guard case .digit = GlyphAlign.role(for: ch) else {
                return XCTFail("'\(ch)' is not classed as a digit")
            }
        }
        for ch: Character in ["a", "Z", "ß"] {
            guard case .letter = GlyphAlign.role(for: ch) else {
                return XCTFail("'\(ch)' is not classed as a letter")
            }
        }
        guard case .letter(nil) = GlyphAlign.role(for: nil) else {
            return XCTFail("whole words must classify as an unnamed letter")
        }
    }

    func testDigitsAreReseatedAsDigitsNotAsLetters() {
        // Regression: reseat() used to fall through to the letter branch for
        // digits, so a digit nudged by a morph was re-seated with lowercase
        // rules and lost its cap height.
        let cap = HandMetrics.active.ascender
        let morphed = digitGlyph(bottom: 0.22, height: cap * 0.7)
        let g = GlyphAlign.reseat(morphed, forChar: "7")
        XCTAssertEqual(extent(g).lo, 0, accuracy: 0.05)
        XCTAssertEqual(height(g), cap, accuracy: 0.06)
    }

    // MARK: - Letters keep their trained size (line trust)

    func testLettersAreSeatedButNotResized() {
        // Letters are NOT anchored: relative size is personal style, and
        // rescaling them is what "statistical fitting" used to get wrong.
        let raw = make([[CGPoint(x: 0, y: 0.35), CGPoint(x: 0.3, y: 1.25),
                         CGPoint(x: 0.6, y: 0.35)]])
        let g = GlyphAlign.normalize(raw, forChar: "a")
        XCTAssertEqual(height(g), height(raw), accuracy: 0.02,
                       "a trained letter was resized")
        XCTAssertLessThan(abs(extent(g).lo), 0.1, "letter is off the baseline")
    }

    func testSmallMarksKeepTheirDrawnPosition() {
        // Snapping a comma to the baseline or scaling an apostrophe to
        // x-height mangles it — these keep whatever the user drew.
        let comma = make([[CGPoint(x: 0.1, y: 0.12), CGPoint(x: 0.04, y: -0.22)]])
        let g = GlyphAlign.normalize(comma, forChar: ",")
        XCTAssertEqual(extent(g).lo, extent(comma).lo, accuracy: 0.02)
        XCTAssertEqual(height(g), height(comma), accuracy: 0.02)
    }

    // MARK: - Anchors agree with the built-in font

    func testAnchorsMatchStrokeFontFallbacks() {
        // Trained and synthetic symbols must be interchangeable: a reply that
        // mixes a trained "=" with a fallback "+" should sit on one axis.
        for (ch, anchor) in GlyphAlign.mathAnchors {
            let builtIn = StrokeFont.glyph(for: ch)
            let points = builtIn.strokes.flatMap { stroke -> [CGPoint] in
                switch stroke {
                case .poly(let pts):
                    return pts
                case .dot(let x, let y):
                    return [CGPoint(x: x, y: y)]
                case .arc(let cx, let cy, let rx, let ry, _, _):
                    return [CGPoint(x: cx, y: cy - ry), CGPoint(x: cx, y: cy + ry),
                            CGPoint(x: cx - rx, y: cy), CGPoint(x: cx + rx, y: cy)]
                }
            }
            guard let lo = points.map(\.y).min(),
                  let hi = points.map(\.y).max(), hi > lo else { continue }
            XCTAssertEqual((lo + hi) / 2, anchor.center, accuracy: 0.12,
                           "anchor for \(ch) disagrees with the built-in glyph")
        }
    }

    // MARK: - Nothing is destroyed

    func testNormalizationNeverProducesInvalidGeometry() {
        let awkward: [PersonalGlyph] = [
            equalsGlyph(centre: 0, height: 0.001),
            equalsGlyph(centre: 8, height: 6),
            digitGlyph(bottom: -3, height: 0.05),
            make([[CGPoint(x: 0, y: 0)]]),                       // single point
            make([[CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0)]]),  // zero extent
        ]
        for g in awkward {
            for ch: Character in ["=", "5", "a", "√", ","] {
                let out = GlyphAlign.normalize(g, forChar: ch)
                XCTAssertFalse(out.strokes.flatMap { $0 }.contains {
                    !$0.x.isFinite || !$0.y.isFinite
                }, "normalize(\(ch)) produced non-finite geometry")
            }
        }
    }

    func testStrokeCountAndOrderAreNeverChanged() {
        // Anchoring may translate and scale. It must never add, drop or
        // reorder strokes — that would change the letterform itself.
        let raw = equalsGlyph(centre: 1.1, height: 0.6)
        for ch: Character in ["=", "+", "5", "a"] {
            let g = GlyphAlign.normalize(raw, forChar: ch)
            XCTAssertEqual(g.strokes.count, raw.strokes.count, "\(ch)")
            for (before, after) in zip(raw.strokes, g.strokes) {
                XCTAssertEqual(before.count, after.count, "\(ch) point count")
            }
        }
    }

    func testTimingMetadataSurvivesAnchoring() {
        // Pen timing is what makes replayed ink look human. Geometry fixes
        // must not silently drop it.
        let raw = equalsGlyph(centre: 1.1, height: 0.6)
        let g = GlyphAlign.normalize(raw, forChar: "=")
        XCTAssertEqual(g.durations?.count, raw.durations?.count)
        XCTAssertEqual(g.pointTimes?.count, raw.pointTimes?.count)
        XCTAssertEqual(g.refSize, raw.refSize)
    }
}
