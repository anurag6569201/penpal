import XCTest
@testable import penpal

final class LanguagePartnerTests: XCTestCase {

    func testCorrectionNoteIsGentleAndActionable() {
        let correction = PenpalAPI.LanguageTurn.Correction(
            found_error: true,
            reason: "Use the feminine article with mañana.",
            corrected: "por la mañana",
            skill: "Spanish noun gender",
            confidence: 0.94
        )

        XCTAssertEqual(
            correction.note,
            "Use the feminine article with mañana.\nTry: por la mañana"
        )
    }

    func testNoErrorProducesNoMarginNote() {
        let correction = PenpalAPI.LanguageTurn.Correction(
            found_error: false,
            reason: "",
            corrected: "",
            skill: "",
            confidence: 0
        )

        XCTAssertTrue(correction.note.isEmpty)
    }
}
