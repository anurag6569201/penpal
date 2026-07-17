import XCTest
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
}

