import XCTest
import UIKit
import PencilKit
@testable import penpal

@MainActor
final class PaperViewportTests: XCTestCase {
    private func resize(_ viewport: PaperViewport, to size: CGSize) {
        viewport.frame = CGRect(origin: .zero, size: size)
        viewport.setNeedsLayout()
        viewport.layoutIfNeeded()
    }

    func testRotationKeepsInkAndTypedTextInOneCoordinateSystem() throws {
        let viewport = PaperViewport()
        viewport.pageWidth = 1200
        resize(viewport, to: CGSize(width: 1200, height: 800))
        let points = [CGPoint(x: 900, y: 100), CGPoint(x: 1100, y: 140)]
        let path = PKStrokePath(controlPoints: points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.1,
                          size: CGSize(width: 3, height: 3), opacity: 1,
                          force: 1, azimuth: 0, altitude: .pi / 2)
        }, creationDate: .now)
        let drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)])
        let text = TypedNoteText(text: "Aligned with ink", x: 900, y: 180,
                                 xHeight: 20, maxX: 1150, isUserMessage: false,
                                 fontName: "Georgia-Italic", colorHex: "#224488")
        viewport.paperView.loadDrawing(drawing, typedTexts: [text])
        let savedInk = viewport.paperView.currentDrawing.dataRepresentation()

        for size in [CGSize(width: 800, height: 1200),
                     CGSize(width: 400, height: 800),
                     CGSize(width: 1200, height: 800)] {
            resize(viewport, to: size)
            XCTAssertEqual(viewport.paperView.bounds.width, 1200)
            let displayed = viewport.paperView.convert(CGPoint(x: 1100, y: 140), to: viewport)
            XCTAssertEqual(displayed.x / size.width, 1100 / 1200.0, accuracy: 0.0001)
            XCTAssertEqual(displayed.y, 140 * size.width / 1200, accuracy: 0.0001)
            XCTAssertEqual(viewport.paperView.frame.width, size.width, accuracy: 0.001)
            XCTAssertEqual(viewport.paperView.frame.height, size.height, accuracy: 0.001)
            XCTAssertEqual(viewport.paperView.currentDrawing.dataRepresentation(), savedInk)
            XCTAssertEqual(viewport.paperView.currentTypedTexts, [text])
        }
    }

    func testRotationPreservesTopVisiblePageCoordinate() throws {
        let viewport = PaperViewport()
        resize(viewport, to: CGSize(width: 1024, height: 768))
        viewport.paperView.addPage()
        viewport.paperView.addPage()
        let canvas = try XCTUnwrap(viewport.paperView.subviews.compactMap { $0 as? PKCanvasView }.first)
        canvas.contentOffset = CGPoint(x: 0, y: 250)
        resize(viewport, to: CGSize(width: 768, height: 1024))
        XCTAssertEqual(canvas.contentOffset.y, 250, accuracy: 0.001)
        resize(viewport, to: CGSize(width: 1024, height: 768))
        XCTAssertEqual(canvas.contentOffset.y, 250, accuracy: 0.001)
    }

    func testLegacyWidthIncludesBlocksTextAndReplyInk() {
        let reply = ReplyInk(baseWidth: 2, strokes: [PersistedInkStroke(from:
            InkStroke(points: [CGPoint(x: 1300, y: 10), CGPoint(x: 1400, y: 20)]))])
        var note = Note(folderID: UUID(),
                        typedTexts: [TypedNoteText(text: "Wide", x: 800, y: 100,
                                                  xHeight: 20, maxX: 1000, isUserMessage: false)],
                        replyInks: [reply],
                        codeBlocks: [PageBlock(html: "<p>Wide block</p>", x: 900, y: 200,
                                               width: 400, height: 200)])
        XCTAssertEqual(note.resolvedPaperWidth, 1424)
        note.replyInks = []
        XCTAssertEqual(note.resolvedPaperWidth, 1324)
        note.codeBlocks = []
        XCTAssertEqual(note.resolvedPaperWidth, 1024)
        note.typedTexts = []
        XCTAssertEqual(note.resolvedPaperWidth, 768)
    }

    func testPageWidthSurvivesSavingAndLegacyNotesStillDecode() throws {
        let note = Note(folderID: UUID(), paperWidth: 1200)
        let data = try JSONEncoder().encode(note)
        XCTAssertEqual(try JSONDecoder().decode(Note.self, from: data).resolvedPaperWidth, 1200)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "paperWidth")
        let restored = try JSONDecoder().decode(Note.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(restored.paperWidth)
        XCTAssertEqual(restored.resolvedPaperWidth, 768)
    }
}
