import XCTest
@testable import penpal

final class VisionTurnTests: XCTestCase {

    func testDebatePhotoKeepsPerspectiveLabel() {
        let turn = PenpalAPI.VisionTurn(
            kind: "debate",
            reply: nil,
            language: nil,
            correction: nil,
            counterargument: "The visible claim assumes one policy fits everyone.",
            question: "Who bears the cost?",
            trust: "perspective",
            error: nil
        )

        XCTAssertTrue(turn.inkText.hasPrefix("Another view:"))
        XCTAssertFalse(turn.inkText.localizedCaseInsensitiveContains("verified"))
    }

    func testLanguagePhotoIncludesConfidentCorrection() {
        let correction = PenpalAPI.LanguageTurn.Correction(
            found_error: true,
            reason: "Use the feminine article.",
            corrected: "la mañana",
            skill: "Spanish noun gender",
            confidence: 0.95
        )
        let turn = PenpalAPI.VisionTurn(
            kind: "language",
            reply: "También me gusta caminar.",
            language: "Spanish",
            correction: correction,
            counterargument: nil,
            question: nil,
            trust: nil,
            error: nil
        )

        XCTAssertTrue(turn.inkText.contains("Try: la mañana"))
        XCTAssertTrue(turn.inkText.contains("También"))
    }

    func testMathPhotoUsesReplyTextDirectly() {
        let turn = PenpalAPI.VisionTurn(
            kind: "math",
            reply: "Reading as: 2 + 2\nAns: 4",
            language: nil,
            correction: nil,
            counterargument: nil,
            question: nil,
            trust: nil,
            error: nil
        )

        XCTAssertEqual(turn.inkText, "Reading as: 2 + 2\nAns: 4")
    }
}
