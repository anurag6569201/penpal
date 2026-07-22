import XCTest
@testable import penpal

final class PageBlockTests: XCTestCase {
    func testLegacyBlockWithoutKindDecodesAndInfersTable() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "html": "<table><tr><td>Value</td></tr></table>",
          "x": 12,
          "y": 24,
          "width": 320,
          "height": 180,
          "createdAt": 0
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let block = try decoder.decode(CodeBlock.self, from: json)

        XCTAssertNil(block.kind)
        XCTAssertEqual(block.resolvedKind, .table)
        XCTAssertEqual(block.frame.origin.x, 12)
    }

    func testExplicitBlockKindRoundTrips() throws {
        let original = CodeBlock(
            html: CodedPaper.checklistBlockHTML,
            kind: .checklist,
            x: 20,
            y: 40,
            width: 360,
            height: 220
        )

        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(CodeBlock.self, from: data)

        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.resolvedKind, .checklist)
    }

    func testTemplatesHaveTypedEditableMarkup() {
        XCTAssertTrue(CodedPaper.tableBlockHTML.contains("data-penpal-kind=\"table\""))
        XCTAssertTrue(CodedPaper.textBlockHTML.contains("data-penpal-editable=\"true\""))
        XCTAssertTrue(CodedPaper.checklistBlockHTML.contains("penpal-item-text"))
        XCTAssertTrue(CodedPaper.imageBlockHTML(base64JPEG: "AA==")
            .contains("data-penpal-kind=\"image\""))
    }
}
