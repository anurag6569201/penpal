import XCTest
import CoreGraphics
import PencilKit
@testable import penpal

@MainActor
final class HandwritingCoreTests: XCTestCase {
    private func glyph(_ points: [CGPoint]) -> PersonalGlyph {
        PersonalGlyph(width: 0.7, strokes: [points],
                      widths: [Array(repeating: 0.1, count: points.count)],
                      durations: [0.4], gaps: [0], refSize: 20,
                      pointTimes: [[0, 0.2, 0.4]])
    }

    func testLegacyReplyInkMigratesIntoCanvasDrawing() {
        let view = MagicPaperView(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
        let stroke = InkStroke(
            points: [CGPoint(x: 64, y: 80), CGPoint(x: 80, y: 96), CGPoint(x: 96, y: 82)],
            widths: [2, 2, 2],
            confidence: 1
        )
        let legacy = ReplyInk(baseWidth: 2, strokes: [PersistedInkStroke(from: stroke)])
        var persistedDrawing: PKDrawing?
        var persistedInks: [ReplyInk]?
        view.onDrawingChange = { persistedDrawing = $0 }
        view.onReplyInksChange = { persistedInks = $0 }

        view.loadDrawing(PKDrawing(), replyInks: [legacy])

        XCTAssertEqual(view.currentDrawing.strokes.count, 1)
        let bakedWidths = view.currentDrawing.strokes[0].path.map(\.size.width)
        XCTAssertGreaterThanOrEqual(bakedWidths.min() ?? 0, 3)
        XCTAssertTrue(view.currentReplyInks.isEmpty)
        XCTAssertEqual(persistedDrawing?.strokes.count, 1)
        XCTAssertEqual(persistedInks, [])
    }

    func testMalformedLegacyReplyRemainsOverlayWithoutPartialMigration() {
        let view = MagicPaperView(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
        let valid = InkStroke(
            points: [CGPoint(x: 64, y: 80), CGPoint(x: 96, y: 82)],
            widths: [2, 2]
        )
        let malformed = InkStroke(points: [CGPoint(x: 100, y: 100)])
        let legacy = ReplyInk(baseWidth: 2, strokes: [
            PersistedInkStroke(from: valid),
            PersistedInkStroke(from: malformed),
        ])

        view.loadDrawing(PKDrawing(), replyInks: [legacy])

        XCTAssertTrue(view.currentDrawing.strokes.isEmpty)
        XCTAssertEqual(view.currentReplyInks, [legacy])
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

    func testReplyWritingPaceResolvesDuration() {
        let settings = HandwritingSettings.shared
        let oldPace = settings.writingPace
        let oldSeconds = settings.timedWritingSeconds
        defer {
            settings.writingPace = oldPace
            settings.timedWritingSeconds = oldSeconds
        }

        settings.writingPace = .natural
        XCTAssertNil(settings.replyWritingDuration)
        settings.writingPace = .instant
        XCTAssertEqual(settings.replyWritingDuration, 0)
        settings.writingPace = .timed
        settings.timedWritingSeconds = 7
        XCTAssertEqual(settings.replyWritingDuration, 7)
    }

    func testInstantWritingCommitsEveryStrokeSynchronously() {
        let renderer = HandwritingRenderer()
        let strokes = [
            InkStroke(points: [.zero, CGPoint(x: 12, y: 8)]),
            InkStroke(points: [CGPoint(x: 20, y: 4)], isDot: true, dotRadius: 1),
        ]
        var finished: [Int] = []
        var completed = false

        renderer.write(
            strokes,
            baseWidth: 2,
            targetDuration: 0,
            onStrokeFinished: { finished.append($0) },
            completion: { completed = true }
        )

        XCTAssertEqual(finished, [0, 1])
        XCTAssertTrue(completed)
        XCTAssertFalse(renderer.isWriting)
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
        XCTAssertNil(MathEvaluator.instantAnswer(for: "17="))
    }

    func testTheoryAndProseDetection() {
        XCTAssertTrue(MathEvaluator.isTheoryOrProseContext("Force F = ma"))
        XCTAssertTrue(MathEvaluator.isTheoryOrProseContext("Let mass be m and acceleration be a"))
        XCTAssertTrue(MathEvaluator.isTheoryOrProseContext("We define energy E = mc^2"))
        XCTAssertTrue(MathEvaluator.isTheoryOrProseContext("Since velocity is v = ds/dt"))
        XCTAssertTrue(MathEvaluator.isTheoryOrProseContext("Assume x + y = 10"))

        XCTAssertFalse(MathEvaluator.isTheoryOrProseContext("2 + 2 ="))
        XCTAssertFalse(MathEvaluator.isTheoryOrProseContext("12 * 15 ="))
        XCTAssertFalse(MathEvaluator.isTheoryOrProseContext("sin(pi / 4) ="))
        XCTAssertFalse(MathEvaluator.isTheoryOrProseContext("sqrt(144) ="))
    }

    func testPlausibleArithmeticAttempt() {
        XCTAssertTrue(MathEvaluator.isPlausibleArithmeticAttempt("5 + 5 ="))
        XCTAssertTrue(MathEvaluator.isPlausibleArithmeticAttempt("12 * 45 ="))
        XCTAssertTrue(MathEvaluator.isPlausibleArithmeticAttempt("(10 + 2) / 4 ="))

        // Equations with variables or theory notes are NOT arithmetic attempts
        XCTAssertFalse(MathEvaluator.isPlausibleArithmeticAttempt("F = ma"))
        XCTAssertFalse(MathEvaluator.isPlausibleArithmeticAttempt("x + y = 10"))
        XCTAssertFalse(MathEvaluator.isPlausibleArithmeticAttempt("3x + 5 = 17"))
        XCTAssertFalse(MathEvaluator.isPlausibleArithmeticAttempt("Let mass be m"))
    }

    func testTrailingEqualsRejectsInternalFormulas() {
        let digit = makeTestStroke(from: CGPoint(x: 20, y: 40), to: CGPoint(x: 20, y: 65), height: 3)
        let topBar = makeTestStroke(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 80, y: 50), height: 3)
        let bottomBar = makeTestStroke(from: CGPoint(x: 50, y: 62), to: CGPoint(x: 80, y: 62), height: 3)

        // Trailing equals: "2 ="
        let trailingStrokes = [digit, topBar, bottomBar]
        let isTrailing = MathInkParser.isTrailingEquals(trailingStrokes)
        let looksLike = MathInkParser.looksLikeEqualsAsk(trailingStrokes)
        let barRects = MathInkParser.equalsBarRects(in: trailingStrokes)

        XCTAssertTrue(isTrailing, "isTrailing failed for trailingStrokes. bounds: \(trailingStrokes.map(\.renderBounds))")
        XCTAssertTrue(looksLike, "looksLikeEqualsAsk failed for trailingStrokes")
        XCTAssertNotNil(barRects, "equalsBarRects failed for trailingStrokes")

        // Internal equals: "2 = 4" (with substantial content following the equals sign)
        let trailingDigit = makeTestStroke(from: CGPoint(x: 100, y: 40), to: CGPoint(x: 100, y: 65), height: 3)
        let formulaStrokes = [digit, topBar, bottomBar, trailingDigit]

        XCTAssertFalse(MathInkParser.isTrailingEquals(formulaStrokes))
        XCTAssertFalse(MathInkParser.looksLikeEqualsAsk(formulaStrokes))
        XCTAssertNil(MathInkParser.equalsBarRects(in: formulaStrokes))
    }

    func testExtendedMathSheetUnitsAndSystems() {
        MathEngine.shared.warmUp()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if MathEngine.shared.solve("1+1") != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let cases: [(String, String)] = [
            ("120-45=", "75"),
            ("10-25=", "-15"),
            ("12 - 5=", "7"),
            ("√144=", "12"),
            ("√(9+16)=", "5"),
            ("log(1000)=", "3"),
            ("LOG(1000)=", "3"),
            ("log2(1024)=", "10"),
            ("log2(8^10)=", "30"),
            ("15% of 80=", "12"),
            ("50% of 50% of 200=", "50"),
            ("5 inch to cm=", "12.7 cm"),
            ("90 minute to hour=", "1.5 hour"),
            ("gcd(48,18)=", "6"),
            ("lcm(12,18)=", "36"),
            ("nCr(5,2)=", "10"),
            ("x+y=5 x-y=1=", "x = 3, y = 2"),
            ("2a+b=7, a-b=2=", "a = 3, b = 1"),
            ("x+y=5\nx-y=1=", "x = 3, y = 2"),
            ("integrate(sin(x))=", "-cos(x) + C"),
            ("5+5=10+2=", "12"),
            ("ans+8=", "20"),
        ]
        for (expr, expected) in cases {
            XCTAssertEqual(MathEvaluator.instantAnswer(for: expr), expected, "failed for \(expr)")
        }

        for refusal in ["1/0=", "sqrt(-4)=", "tan(90)=", "5="] {
            XCTAssertNil(MathEvaluator.instantAnswer(for: refusal), "should decline \(refusal)")
        }
    }

    func testCalculatorIdiomsNotMisclassifiedAsProse() {
        for expr in [
            "15% of 80=",
            "50% of 50% of 200=",
            "5 inch to cm=",
            "60 mi to km=",
            "90 minute to hour=",
            "10 cm to in=",
            "100 degC to degF=",
            "integrate(2x)=",
            "factor(x^2-5x+6)=",
            "simplify(2x+3x-x)=",
        ] {
            XCTAssertFalse(MathEvaluator.isTheoryOrProseContext(expr), "rejected calculator input: \(expr)")
        }

        for prose in ["Force F = ma", "Let mass be m", "Find the sum of x and y"] {
            XCTAssertTrue(MathEvaluator.isTheoryOrProseContext(prose), "missed prose: \(prose)")
        }

        for arithmetic in ["12 × 3 =", "144 ÷ 12 =", "√144 =", "sin(30) =", "log(1000) ="] {
            XCTAssertTrue(MathEvaluator.isPlausibleArithmeticAttempt(arithmetic), "rejected arithmetic: \(arithmetic)")
        }
    }

    func testCrossMultiplicationNotMistakenForCaret() {
        let diag1 = makeTestStroke(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 62, y: 62))
        let diag2 = makeTestStroke(from: CGPoint(x: 62, y: 40), to: CGPoint(x: 40, y: 62))
        XCTAssertEqual(MathInkParser.classifyOperator([diag1, diag2], unit: 24), "*")

        let caretLeft = makeTestStroke(from: CGPoint(x: 40, y: 58), to: CGPoint(x: 52, y: 42))
        let caretRight = makeTestStroke(from: CGPoint(x: 52, y: 42), to: CGPoint(x: 64, y: 58))
        XCTAssertEqual(MathInkParser.classifyOperator([caretLeft, caretRight], unit: 24), "^")
    }

    func testTightTrailingEqualsAndEqualsCluster() {
        let digit = makeTestStroke(from: CGPoint(x: 20, y: 40), to: CGPoint(x: 20, y: 66))
        let topBar = makeTestStroke(from: CGPoint(x: 24, y: 49), to: CGPoint(x: 48, y: 49))
        let bottomBar = makeTestStroke(from: CGPoint(x: 24, y: 59), to: CGPoint(x: 48, y: 59))
        let tight = [digit, topBar, bottomBar]
        XCTAssertTrue(MathInkParser.isTrailingEquals(tight))
        XCTAssertTrue(MathInkParser.looksLikeEqualsAsk(tight))
        XCTAssertNotNil(MathInkParser.equalsBarRects(in: tight))
        XCTAssertTrue(MathInkParser.isEqualsCluster([topBar, bottomBar], unit: 26))
    }

    func testGraphPlotterHandlesRadiansAndExp() throws {
        XCTAssertEqual(GraphPlotter.functionBody(in: "y = x^2"), "x^2")
        XCTAssertEqual(GraphPlotter.functionBody(in: "plot sin(x)"), "sin(x)")
        XCTAssertEqual(GraphPlotter.functionBody(in: "f(x) = 2x + 1 ="), "2x + 1")

        let frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        let sinPlot = try XCTUnwrap(GraphPlotter.plot("sin(x)", in: frame))
        XCTAssertEqual(sinPlot.curve.count, 1)
        // sin(x) spans [-1, 1] (width 2); with 10% span padding yMax is ~1.2.
        XCTAssertEqual(sinPlot.labels.last?.text, "1.2")

        XCTAssertNotNil(GraphPlotter.plot("exp(x)", in: frame))
        let reciprocal = try XCTUnwrap(GraphPlotter.plot("1/x", in: frame))
        XCTAssertEqual(reciprocal.curve.count, 2)
    }

    func testCorrectionTrainerHandlesTrailingEquals() {
        let digit1 = makeTestStroke(from: CGPoint(x: 10, y: 40), to: CGPoint(x: 20, y: 66))
        let plusH = makeTestStroke(from: CGPoint(x: 34, y: 53), to: CGPoint(x: 52, y: 53))
        let plusV = makeTestStroke(from: CGPoint(x: 43, y: 44), to: CGPoint(x: 43, y: 62))
        let digit2 = makeTestStroke(from: CGPoint(x: 72, y: 40), to: CGPoint(x: 72, y: 66))
        let eqTop = makeTestStroke(from: CGPoint(x: 92, y: 49), to: CGPoint(x: 114, y: 49))
        let eqBot = makeTestStroke(from: CGPoint(x: 92, y: 59), to: CGPoint(x: 114, y: 59))
        let strokes = [digit1, plusH, plusV, digit2, eqTop, eqBot]
        let clusters = MathInkParser.symbolClusters(in: strokes)
        XCTAssertEqual(clusters.count, 4)
        XCTAssertTrue(MathInkParser.isEqualsCluster(clusters[3], unit: 26))
        let beforeCount = PersonalFontStore.shared.variantCount(forChar: "3")
        XCTAssertEqual(
            MathCorrectionTrainer.learn(from: strokes, original: "8+2=", corrected: "3+2="),
            1
        )
        let afterCount = PersonalFontStore.shared.variantCount(forChar: "3")
        if afterCount > beforeCount {
            PersonalFontStore.shared.removeVariant(forChar: "3", at: afterCount - 1)
        }
    }

    func testPageLevelMathVariablesAndChaining() {
        MathEngine.shared.warmUp()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if MathEngine.shared.solve("1+1") != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let vars = MathEvaluator.extractVariables(from: [
            "r = 5",
            "a = 3 + 1",
            "b = 2a",
            "Force F = ma", // prose must be ignored
        ])
        XCTAssertEqual(vars["r"], 5)
        XCTAssertEqual(vars["a"], 4)
        XCTAssertEqual(vars["b"], 8)
        XCTAssertNil(vars["f"])

        XCTAssertEqual(MathEvaluator.instantAnswer(for: "3a + b =", variables: vars), "20")
        XCTAssertEqual(MathEvaluator.instantAnswer(for: "r = 5\nr^2 ="), "25")
        // Equation solving must still solve symbolically even if x is bound on the page.
        let solved = MathEvaluator.instantAnswer(for: "x^2 - 5x + 6 = 0 =", variables: ["x": 99])
        XCTAssertNotNil(solved)
        XCTAssertTrue(solved?.contains("2") == true && solved?.contains("3") == true)
    }

    func testDivisionSignAndRadicalGeometry() {
        // Division "÷": horizontal bar + dot above + dot below.
        let bar = makeTestStroke(from: CGPoint(x: 40, y: 52), to: CGPoint(x: 64, y: 52))
        let topDot = makeTestStroke(from: CGPoint(x: 52, y: 42), to: CGPoint(x: 53, y: 43))
        let botDot = makeTestStroke(from: CGPoint(x: 52, y: 62), to: CGPoint(x: 53, y: 63))
        XCTAssertEqual(MathInkParser.classifyOperator([bar, topDot, botDot], unit: 26), "/")

        // Handwritten √ stroke: left entry → bottom vertex → rising diagonal → right roof.
        let radicalPts: [CGPoint] = [
            CGPoint(x: 20, y: 56),
            CGPoint(x: 28, y: 74),
            CGPoint(x: 42, y: 36),
            CGPoint(x: 96, y: 36),
        ]
        var dense: [PKStrokePoint] = []
        var t: Double = 0
        for i in 1..<radicalPts.count {
            let a = radicalPts[i - 1], b = radicalPts[i]
            let steps = max(4, Int(hypot(b.x - a.x, b.y - a.y) / 2))
            for s in 0...steps {
                let f = CGFloat(s) / CGFloat(steps)
                dense.append(PKStrokePoint(
                    location: CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f),
                    timeOffset: t, size: CGSize(width: 3, height: 3),
                    opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
                t += 0.004
            }
        }
        let radStroke = PKStroke(ink: PKInk(.pen, color: .black),
                                 path: PKStrokePath(controlPoints: dense, creationDate: Date()))
        XCTAssertTrue(MathInkParser.isRadicalStroke(radStroke, unit: 24))
    }

    func testGraphPlotterExpressionsAndAnnotations() throws {
        XCTAssertEqual(GraphPlotter.plottableExpression(from: "x^2 - 4"), "x^2 - 4")
        XCTAssertEqual(GraphPlotter.plottableExpression(from: "x^2 - 5x + 6 = 0 ="), "x^2 - 5x + 6")
        XCTAssertEqual(GraphPlotter.plottableExpression(from: "y = sin(x)"), "sin(x)")
        XCTAssertNil(GraphPlotter.plottableExpression(from: "5 + 5 ="))

        let plot = try XCTUnwrap(GraphPlotter.plot("x^2 - 4", in: CGRect(x: 0, y: 0, width: 320, height: 220)))
        XCTAssertFalse(plot.annotations.isEmpty, "Plot should include ticks, arrowheads, labels, and intercepts")
        XCTAssertGreaterThan(plot.strokes.count, plot.axes.count + plot.curve.count)
    }

    func testExpandedMathGhostWorkSteps() {
        let quadSteps = MathGhostWork.steps(for: "x^2-5x+6=0=", answer: "x = 2, x = 3")
        XCTAssertEqual(quadSteps.count, 2)
        XCTAssertTrue(quadSteps[0].contains("D ="))

        let pctSteps = MathGhostWork.steps(for: "15% of 80=", answer: "12")
        XCTAssertEqual(pctSteps.first, "0.15 × 80")

        let fracSteps = MathGhostWork.steps(for: "3/4+1/6=", answer: "11/12")
        XCTAssertEqual(fracSteps.first, "(9 + 2) / 12")

        let parenSteps = MathGhostWork.steps(for: "(2+3)*4=", answer: "20")
        XCTAssertEqual(parenSteps.first, "2+3 = 5")
    }

    private func makeTestStroke(from a: CGPoint, to b: CGPoint, height: CGFloat = 3) -> PKStroke {
        let steps = max(2, Int(hypot(b.x - a.x, b.y - a.y) / 2))
        let points = (0...steps).map { i -> PKStrokePoint in
            let t = CGFloat(i) / CGFloat(steps)
            return PKStrokePoint(
                location: CGPoint(x: a.x + (b.x - a.x) * t,
                                  y: a.y + (b.y - a.y) * t),
                timeOffset: Double(i) * 0.004,
                size: CGSize(width: 3, height: height),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black),
                        path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }
}


// Indicator changes must never change the ink pipeline or leave stale chrome.
extension HandwritingCoreTests {
    private func indicatorStroke() -> InkStroke {
        InkStroke(points: [CGPoint(x: 40, y: 60), CGPoint(x: 80, y: 60)],
                  widths: [2, 2])
    }

    func testWritingIndicatorSwitchAndCancellation() throws {
        let renderer = HandwritingRenderer(frame: .zero)
        renderer.write([indicatorStroke()], baseWidth: 2)
        let nib = try XCTUnwrap(renderer.layer.sublayers?.first { $0.name == "penpal.nib" })
        XCTAssertFalse(nib.isHidden)
        XCTAssertTrue(renderer.penDot.isHidden)
        renderer.writingIndicator = .dot
        XCTAssertTrue(nib.isHidden)
        XCTAssertFalse(renderer.penDot.isHidden)
        renderer.writingIndicator = .none
        XCTAssertTrue(nib.isHidden)
        XCTAssertTrue(renderer.penDot.isHidden)
        renderer.cancelWriting()
        XCTAssertFalse(renderer.isWriting)
        XCTAssertTrue(nib.animationKeys()?.isEmpty ?? true)
        XCTAssertTrue(renderer.penDot.animationKeys()?.isEmpty ?? true)
    }

    func testInstantReplyDoesNotShowIndicatorAndCommitsInk() throws {
        let renderer = HandwritingRenderer(frame: .zero)
        var committed: [Int] = []
        var completed = false
        renderer.write([indicatorStroke()], baseWidth: 2, targetDuration: 0,
                       onStrokeFinished: { committed.append($0) },
                       completion: { completed = true })
        let nib = try XCTUnwrap(renderer.layer.sublayers?.first { $0.name == "penpal.nib" })
        XCTAssertEqual(committed, [0])
        XCTAssertTrue(completed)
        XCTAssertFalse(renderer.isWriting)
        XCTAssertTrue(nib.isHidden)
        XCTAssertTrue(renderer.penDot.isHidden)
    }

    func testCancelledIndicatorCannotCompleteAnOldReply() async {
        let renderer = HandwritingRenderer(frame: .zero)
        let staleCompletion = expectation(description: "Cancelled reply must not finish")
        staleCompletion.isInverted = true
        renderer.write([indicatorStroke()], baseWidth: 2, targetDuration: 0.02, completion: {
            staleCompletion.fulfill()
        })
        renderer.cancelWriting()
        await fulfillment(of: [staleCompletion], timeout: 0.25)
        XCTAssertFalse(renderer.isWriting)
    }

    func testWritingCompletionRetiresNibWithoutDelayingInk() async throws {
        let renderer = HandwritingRenderer(frame: .zero)
        let completed = expectation(description: "Ink completes")
        renderer.write([indicatorStroke()], baseWidth: 2, targetDuration: 0.02, completion: {
            completed.fulfill()
        })
        await fulfillment(of: [completed], timeout: 1)
        let nib = try XCTUnwrap(renderer.layer.sublayers?.first { $0.name == "penpal.nib" })
        XCTAssertFalse(renderer.isWriting)
        XCTAssertTrue(nib.isHidden || nib.opacity == 0)
        XCTAssertTrue(renderer.penDot.isHidden)
        renderer.cancelWriting()
    }
}
