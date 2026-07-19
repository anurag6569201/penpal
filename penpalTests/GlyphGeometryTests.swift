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

    // MARK: - Part-aware measurement (ScaleConsensus)

    /// Multi-zone letters must vote with their BODY part: in a synthetic "bo"
    /// where b's bowl tops at ~1.0 but its stem reaches 1.65, ScaleConsensus
    /// must (a) produce an observation for b at all — before part-aware
    /// measurement it was skipped entirely — and (b) read b's body near the
    /// x-height, not let the stem drag it toward ascender height.
    func testPartLettersVoteWithTheirBody() {
        func ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat,
                     n: Int = 48) -> [CGPoint] {
            (0...n).map { i in
                let a = CGFloat(i) / CGFloat(n) * 2 * .pi
                return CGPoint(x: cx + rx * cos(a), y: cy + ry * sin(a))
            }
        }
        func vline(x: CGFloat, from y0: CGFloat, to y1: CGFloat,
                   n: Int = 24) -> [CGPoint] {
            (0...n).map { i in
                CGPoint(x: x, y: y0 + (y1 - y0) * CGFloat(i) / CGFloat(n))
            }
        }

        // b: stem on the left up to 1.65 + bowl topping at 1.0.
        // o: plain ring topping at 1.0, to the right.
        let g = make([
            vline(x: 0.04, from: 0, to: 1.65),
            ellipse(cx: 0.3, cy: 0.5, rx: 0.28, ry: 0.5),
            ellipse(cx: 0.95, cy: 0.5, rx: 0.25, ry: 0.5),
        ])

        let obs = ScaleConsensus.letterHeights(word: "bo", glyph: g)
        XCTAssertTrue(obs.contains { $0.0 == "b" },
                      "part letter b produced no body observation")
        XCTAssertTrue(obs.contains { $0.0 == "o" })
        for (ch, h) in obs {
            XCTAssertLessThan(h, 1.45, "\(ch) body read as stem/ascender height")
            XCTAssertGreaterThan(h, 0.5, "\(ch) body reading implausibly small")
        }
    }

    // MARK: - Sizing dispersion (the "some words big, some small" metric)

    /// The dispersion metric must catch exactly the bug it exists for: a
    /// corpus where one capture is 35% larger must read clearly less even
    /// than a uniform corpus, and a uniform corpus must read near zero.
    func testSizingDispersionDetectsMixedScales() {
        func ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat,
                     n: Int = 48) -> [CGPoint] {
            (0...n).map { i in
                let a = CGFloat(i) / CGFloat(n) * 2 * .pi
                return CGPoint(x: cx + rx * cos(a), y: cy + ry * sin(a))
            }
        }
        // "oo": two rings whose bodies top at 1.0 — clean x-body evidence.
        let base = make([
            ellipse(cx: 0.3, cy: 0.5, rx: 0.28, ry: 0.5),
            ellipse(cx: 0.95, cy: 0.5, rx: 0.25, ry: 0.5),
        ])
        let big = ScaleConsensus.apply(1.35, to: base)

        guard let h = ScaleConsensus.bodyHeight(word: "oo", glyph: base),
              let hBig = ScaleConsensus.bodyHeight(word: "oo", glyph: big) else {
            return XCTFail("body height unmeasurable on synthetic rings")
        }

        let uniform: [CGFloat] = [h, h, h, h, h]
        let mixed: [CGFloat] = [h, h, h, h, hBig]

        guard let cvUniform = ScaleConsensus.coefficientOfVariation(uniform),
              let cvMixed = ScaleConsensus.coefficientOfVariation(mixed) else {
            return XCTFail("dispersion unmeasurable")
        }
        XCTAssertLessThan(cvUniform, 0.02, "uniform corpus must read even")
        XCTAssertGreaterThan(cvMixed, 0.08,
                             "a 35% outlier must be clearly visible in the metric")
        XCTAssertGreaterThan(cvMixed, cvUniform)
    }

    // MARK: - Capitals seat on the baseline

    /// Capital G/J/P/Q/Y were classified through `lowercased()` and inherited
    /// their lowercase twin's descender class — snapBaseline then seated them
    /// with ~38% of their ink below the line, hanging toward the descender
    /// line. A capital drawn between the baseline and the cap line must stay
    /// seated ON the baseline.
    func testCapitalsAreNotSeatedAsDescenders() {
        func ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat,
                     n: Int = 48) -> [CGPoint] {
            (0...n).map { i in
                let a = CGFloat(i) / CGFloat(n) * 2 * .pi
                return CGPoint(x: cx + rx * cos(a), y: cy + ry * sin(a))
            }
        }
        for ch: Character in ["G", "J", "P", "Q", "Y"] {
            // Cap body: baseline 0 up to ~1.64 (cap height), nothing below.
            let raw = make([ellipse(cx: 0.4, cy: 0.82, rx: 0.35, ry: 0.82)])
            let g = GlyphAlign.normalize(raw, forChar: ch)
            let lo = g.strokes.flatMap { $0 }.map(\.y).min() ?? 0
            XCTAssertGreaterThan(lo, -0.15,
                "capital \(ch) hung below the baseline like a descender")
        }
        // And the lowercase twins must still be allowed their tails: a "g"
        // with real ink below the line keeps a below-baseline floor.
        let tail = make([
            ellipse(cx: 0.3, cy: 0.5, rx: 0.28, ry: 0.5),
            (0...24).map { i in
                CGPoint(x: 0.55, y: 0.9 - 1.5 * CGFloat(i) / 24)
            },
        ])
        let g = GlyphAlign.normalize(tail, forChar: "g")
        let lo = g.strokes.flatMap { $0 }.map(\.y).min() ?? 0
        XCTAssertLessThan(lo, -0.2, "lowercase g lost its descender tail")
    }

    // MARK: - Cursive fragment cropping (the "theat" bug)

    /// In a cursive hand one stroke spans the whole word, and stroke-level
    /// crop selection made every fragment carry its donor word's ENTIRE ink —
    /// stitched words then rendered with the donors' letters spliced in
    /// ("the"+"at" → "theat"). A slice cropped from a one-stroke word must
    /// contain only the ink inside its window.
    func testCropCutsCursiveStrokesAtSliceBoundary() {
        // One continuous stroke sweeping x 0→1.2 (a fully connected "word"),
        // plus a neighbor letter's stem just past the slice boundary that
        // leans a few points into the window — the source of stray marks
        // ("ab.out") when kept.
        let sweep: [CGPoint] = (0...120).map { i in
            let t = CGFloat(i) / 120
            return CGPoint(x: t * 1.2, y: 0.5 + 0.45 * sin(t * 6 * .pi))
        }
        let neighborStem: [CGPoint] = (0...24).map { i in
            let t = CGFloat(i) / 24
            return CGPoint(x: 0.585 + t * 0.06, y: t * 1.4)
        }
        let word = make([sweep, neighborStem])

        guard let piece = FragmentBank.crop(word, fromX: 0, toX: 0.6) else {
            return XCTFail("crop returned nothing for a valid slice")
        }
        XCTAssertEqual(piece.strokes.count, 1,
            "neighbor-letter sliver at the window edge must be rejected")
        let xs = piece.strokes.flatMap { $0 }.map(\.x)
        let maxX = xs.max() ?? 0
        // Rebased to 0; everything must sit inside the 0.6-wide window
        // (small pad allowed). The old centroid rule kept all 1.2 units.
        XCTAssertLessThan(maxX, 0.68,
            "fragment carries ink beyond its slice — donor letters will splice into stitched words")
        XCTAssertLessThan(piece.width, 0.68)
        XCTAssertGreaterThan(maxX, 0.4, "fragment lost most of its own slice")

        // Parallel per-point rows must stay aligned with the cut strokes.
        if let ws = piece.widths {
            for (si, s) in piece.strokes.enumerated() where si < ws.count {
                XCTAssertEqual(ws[si].count, s.count, "widths row desynced from cut stroke")
            }
        }
    }

    // MARK: - Critic feature parity (the "Looks like you? 0%" bug)

    /// The critic's distribution is built from captured glyphs (unit space)
    /// while episodes are scored from laid-out view-space ink. The SAME ink
    /// measured through both paths must produce comparable features —
    /// widthUnits used to be per-glyph on one side and whole-reply span on
    /// the other, a ~40 z-score that pinned every reply at 0%.
    func testCriticFeaturesAgreeAcrossCaptureAndLayout() {
        // A 5-letter "word": five bumps, 3 units wide, one stroke each.
        var unitStrokes: [[CGPoint]] = []
        for k in 0..<5 {
            let x0 = CGFloat(k) * 0.6
            unitStrokes.append((0...20).map { i in
                let t = CGFloat(i) / 20
                return CGPoint(x: x0 + t * 0.5, y: 0.5 + 0.45 * sin(t * .pi))
            })
        }
        let glyph = make(unitStrokes)
        let real = HandFeatures.extract(from: glyph, letterCount: 5)

        // The same ink laid out at xHeight 20 (view space: y grows DOWN).
        let xHeight: CGFloat = 20
        let laidOut: [InkStroke] = glyph.strokes.map { pts in
            InkStroke(points: pts.map { CGPoint(x: $0.x * xHeight,
                                                y: -$0.y * xHeight) },
                      widths: Array(repeating: 2.4, count: pts.count),
                      duration: 0.3)
        }
        let episode = HandFeatures.extract(from: laidOut, xHeight: xHeight,
                                           letterCount: 5)

        // Per-letter width must agree closely — this is the feature that
        // broke. Both sides should read ~0.6 x-heights per letter.
        XCTAssertEqual(Double(real.widthUnits), Double(episode.widthUnits),
                       accuracy: 0.15,
                       "widthUnits diverged between capture and layout paths")
        XCTAssertLessThan(real.widthUnits, 1.5,
                          "capture-side widthUnits is not per-letter")
        // Shape features measured on identical geometry must match closely.
        XCTAssertEqual(Double(real.slantMean), Double(episode.slantMean),
                       accuracy: 0.1)
        XCTAssertEqual(Double(real.curvature), Double(episode.curvature),
                       accuracy: 0.2)
        XCTAssertEqual(Double(real.strokesPerLetter),
                       Double(episode.strokesPerLetter), accuracy: 0.01)
    }
}
