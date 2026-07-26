import XCTest
@testable import penpal

final class DebatePartnerTests: XCTestCase {

    func testInkTextLabelsPerspectiveInsteadOfVerdict() {
        let turn = PenpalAPI.DebateTurn(
            counterargument: "That assumes cost is the only measure of access.",
            question: "How would the policy affect people without alternatives?",
            trust: "perspective",
            error: nil
        )

        XCTAssertTrue(turn.inkText.hasPrefix("Another view:"))
        XCTAssertTrue(turn.inkText.contains(turn.counterargument))
        XCTAssertTrue(turn.inkText.contains(turn.question))
        XCTAssertFalse(turn.inkText.localizedCaseInsensitiveContains("verified"))
    }

    func testQuestionIsOptionalInInkText() {
        let turn = PenpalAPI.DebateTurn(
            counterargument: "A serious opposing case.",
            question: "",
            trust: "perspective",
            error: nil
        )

        XCTAssertEqual(
            turn.inkText,
            "Another view:\nA serious opposing case."
        )
    }
}
