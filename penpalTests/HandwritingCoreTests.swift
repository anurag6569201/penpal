import XCTest
import CoreGraphics
@testable import penpal

@MainActor
final class HandwritingCoreTests: XCTestCase {
    private func glyph(_ points: [CGPoint]) -> PersonalGlyph {
        PersonalGlyph(width: 0.7, strokes: [points],
                      widths: [Array(repeating: 0.1, count: points.count)],
                      durations: [0.4], gaps: [0], refSize: 20,
                      pointTimes: [[0, 0.2, 0.4]])
    }

    func testGlyphValidationRejectsMalformedData() {
        XCTAssertTrue(PersonalFontStore.isValid(
            glyph([CGPoint(x: 0, y: 0), CGPoint(x: 0.3, y: 1), CGPoint(x: 0.7, y: 0)])
        ))
        var invalid = glyph([.zero, CGPoint(x: 0.3, y: 1), CGPoint(x: 0.7, y: 0)])
        invalid.strokes[0][1].x = .infinity
        XCTAssertFalse(PersonalFontStore.isValid(invalid))
    }

    func testAlignmentSeatsNormalGlyphOnBaseline() {
        let floating = glyph([
            CGPoint(x: 0, y: 0.4), CGPoint(x: 0.3, y: 1.4), CGPoint(x: 0.7, y: 0.4)
        ])
        let aligned = GlyphAlign.normalize(floating, forChar: "a")
        let low = aligned.strokes.flatMap { $0 }.map(\.y).min() ?? 1
        XCTAssertLessThan(abs(low), 0.08)
        XCTAssertTrue(PersonalFontStore.isValid(aligned))
    }

    func testDetectedSizeUsesRobustPercentileAndClamp() {
        let lines = [
            DetectedLine(rect: CGRect(x: 0, y: 0, width: 100, height: 30)),
            DetectedLine(rect: CGRect(x: 0, y: 50, width: 100, height: 32)),
            DetectedLine(rect: CGRect(x: 0, y: 100, width: 100, height: 120)),
        ]
        let size = InkAnalyzer.estimateXHeight(lines: lines)
        XCTAssertGreaterThanOrEqual(size, 11)
        XCTAssertLessThanOrEqual(size, 26)
    }

    func testPolicyAlwaysClampsUnsafeUpdates() {
        let policy = StylePolicy(messinessScale: 20, joinBias: 4, driftScale: -2,
                                 spacingScale: 8, tempoJitter: 2, pressureGain: 9).clamped()
        XCTAssertEqual(policy.messinessScale, 2.2)
        XCTAssertEqual(policy.joinBias, 0.45)
        XCTAssertEqual(policy.driftScale, 0.2)
        XCTAssertEqual(policy.tempoJitter, 0.35)
    }

    func testStructuredLayoutMarksWordBoundariesAndFits() {
        let settings = HandwritingSettings.shared
        let oldLine = settings.lineSpacingScale
        defer { settings.lineSpacingScale = oldLine }
        settings.lineSpacingScale = 1
        let sequence = StrokeFont.layoutSequence(
            text: "hello world", origin: CGPoint(x: 20, y: 80), xHeight: 16,
            maxX: 500, lineGap: 44, maxY: 600, messiness: 0,
            settings: settings
        )
        XCTAssertFalse(sequence.clipped)
        XCTAssertFalse(sequence.strokes.isEmpty)
        XCTAssertTrue(sequence.strokes.contains(where: { $0.wordIndex == 1 && $0.isWordStart }))
    }

    func testVariableWidthOutlineHandlesPressureCurve() {
        let path = HandwritingRenderer.variableWidthOutline(
            points: [.zero, CGPoint(x: 10, y: 5), CGPoint(x: 20, y: 0)],
            widths: [1, 4, 1]
        )
        XCTAssertNotNil(path)
        XCTAssertFalse(path!.boundingBox.isEmpty)
    }

    // MARK: - Local calculator (no LLM)

    func testMathGlyphAsciiNormalization() {
        XCTAssertEqual(MathGlyphMatcher.ascii(for: "×"), "*")
        XCTAssertEqual(MathGlyphMatcher.ascii(for: "÷"), "/")
        XCTAssertEqual(MathGlyphMatcher.ascii(for: "√"), "sqrt")
        XCTAssertEqual(MathGlyphMatcher.ascii(for: "+"), "+")
        XCTAssertEqual(MathGlyphMatcher.ascii(for: "5"), "5")
        XCTAssertTrue(MathGlyphMatcher.isNumericToken("384"))
        XCTAssertTrue(MathGlyphMatcher.isNumericToken("3.14"))
        XCTAssertFalse(MathGlyphMatcher.isNumericToken("^"))
        XCTAssertFalse(MathGlyphMatcher.isNumericToken("sqrt"))
    }

    func testMathTrainingAlphabetCoversCalculatorOps() {
        let set = Set(CalibrationView.mathChars)
        for ch: Character in ["0", "9", "+", "-", "*", "/", "=", "^", "%", "!", "×", "÷", "√", "x", "y"] {
            XCTAssertTrue(set.contains(ch), "missing \(ch)")
        }
    }

    func testCorrectionTokenizer() {
        XCTAssertEqual(MathCorrectionTrainer.tokens(in: "5+5="),
                       Array("5+5"))
        XCTAssertEqual(MathCorrectionTrainer.tokens(in: "3x+5=17"),
                       Array("3x+5=17"))
        XCTAssertEqual(MathCorrectionTrainer.tokens(in: "sqrt(4)"),
                       Array("√(4)"))
        XCTAssertEqual(MathCorrectionTrainer.tokens(in: "S+S"),
                       nil) // S not in math alphabet — refuse unsafe train
        // No-op when unchanged
        XCTAssertEqual(MathCorrectionTrainer.tokens(in: "5+5"),
                       MathCorrectionTrainer.tokens(in: "5 + 5"))
    }

    func testCorrectionLearnRequiresAlignment() {
        XCTAssertEqual(
            MathCorrectionTrainer.learn(from: [], original: "S+S", corrected: "5+5"),
            0
        )
        XCTAssertEqual(
            MathCorrectionTrainer.learn(from: [], original: "5+5", corrected: "5+5"),
            0
        )
    }

    func testSuperscriptLayoutDetection() {
        let unit: CGFloat = 40
        let base = CGRect(x: 10, y: 50, width: 24, height: 40)
        let power = CGRect(x: 30, y: 28, width: 14, height: 18)
        XCTAssertTrue(MathInkParser.isSuperscriptRect(power, relativeTo: base, unit: unit))

        let beside = CGRect(x: 40, y: 50, width: 24, height: 40)
        XCTAssertFalse(MathInkParser.isSuperscriptRect(beside, relativeTo: base, unit: unit))

        let low = CGRect(x: 30, y: 70, width: 14, height: 18)
        XCTAssertFalse(MathInkParser.isSuperscriptRect(low, relativeTo: base, unit: unit))
    }

    func testGhostWorkNarratesEquationAndArithmetic() {
        let eq = MathGhostWork.steps(for: "3x+5=17=", answer: "x = 4")
        XCTAssertEqual(eq.count, 2)
        XCTAssertTrue(eq[0].contains("3x"))
        XCTAssertTrue(eq[1].contains("4"))

        let arith = MathGhostWork.steps(for: "2+3*4=", answer: "14")
        XCTAssertEqual(arith.count, 2)
        XCTAssertTrue(arith[0].contains("×") || arith[0].contains("*"))

        // Too simple — no ghost theater.
        XCTAssertTrue(MathGhostWork.steps(for: "2+2=", answer: "4").isEmpty)
    }

    func testPowerExpressionsEvaluate() {
        MathEngine.shared.warmUp()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if MathEngine.shared.solve("1+1") != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(MathEvaluator.instantAnswer(for: "2^10="), "1024")
        XCTAssertEqual(MathEvaluator.instantAnswer(for: "2^3="), "8")
        let roots = MathEvaluator.instantAnswer(for: "x^2=4=")
        let got = Set((roots ?? "").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        })
        XCTAssertEqual(got, Set(["x = 2", "x = -2"]))
        XCTAssertEqual(MathEvaluator.instantAnswer(for: "5²="), "25")
    }

    func testMatchCharReturnsNilWithoutTraining() {
        XCTAssertNil(MathGlyphMatcher.matchSymbol(strokes: [], unit: 20))
        XCTAssertFalse(PersonalFontStore.shared.hasTrained(anyOf: []))
    }

    func testInstantMathSheetBasicsWithoutCloud() {
        // Verification-sheet compute path — recognition is separate; these
        // confirm math.js answers once ASCII is known (brain off).
        MathEngine.shared.warmUp()
        // Give the JS engine a moment to load off-queue.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if MathEngine.shared.solve("1+1") != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let cases: [(String, String)] = [
            ("5+5=", "10"),
            ("120-45=", "75"),
            ("13*7=", "91"),
            ("144/12=", "12"),
            ("2+3*4=", "14"),
            ("(2+3)*4=", "20"),
            ("2^10=", "1024"),
            ("5!=", "120"),
            ("sin(30)=", "0.5"),
            ("sqrt(144)=", "12"),
            // Equations — must keep BOTH sides (not just the RHS).
            ("3x+5=17=", "x = 4"),
            ("2x-6=0=", "x = 3"),
            ("5x=45=", "x = 9"),
            ("x/2+3=7=", "x = 8"),
            ("2(x+3)=16=", "x = 5"),
            ("x^2-5x+6=0=", "x = 3, x = 2"),
            ("x^2=16=", "x = 4, x = -4"),
            ("2^x=8=", "x = 3"),
            // Tape chaining — continue after a prior equals.
            ("5+5=10+2=", "12"),
            ("7*3=21+4=", "25"),
        ]
        for (expr, expected) in cases {
            let answer = MathEvaluator.instantAnswer(for: expr)
            if expected.contains(", ") {
                // Root order can vary — compare as sets of "x = …" clauses.
                let got = Set((answer ?? "").split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                })
                let want = Set(expected.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                })
                XCTAssertEqual(got, want, "failed for \(expr) — got \(answer ?? "nil")")
            } else {
                XCTAssertEqual(answer, expected, "failed for \(expr)")
            }
        }
    }

    func testHasFreeVariableDetectsEquations() {
        XCTAssertTrue(MathEvaluator.hasFreeVariable("3x+5=17"))
        XCTAssertTrue(MathEvaluator.hasFreeVariable("sin(x)=0.5"))
        XCTAssertFalse(MathEvaluator.hasFreeVariable("5+5=10+2"))
        XCTAssertFalse(MathEvaluator.hasFreeVariable("sin(30)"))
        XCTAssertFalse(MathEvaluator.hasFreeVariable("2pi"))
    }

    func testNativeFallbackDoesNotTapeReduceEquations() {
        // Even if the JS engine were unavailable, never answer "17" for
        // "3x+5=17=" by taking only the RHS.
        // We can't unload MathEngine easily; assert the guard instead.
        XCTAssertTrue(MathEvaluator.hasFreeVariable("3x+5=17"))
        XCTAssertNil(
            MathEvaluator.instantAnswer(for: "17=")
        )
    }
}

