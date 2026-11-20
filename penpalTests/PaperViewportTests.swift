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

    func testShortenedAndNarrowWindowScalesBottomChromeInsetAndClampsScroll() throws {
        let viewport = PaperViewport()
        viewport.pageWidth = 768
        viewport.bottomChromeInset = 100
        resize(viewport, to: CGSize(width: 768, height: 1024))
        let canvas = try XCTUnwrap(viewport.paperView.subviews.compactMap { $0 as? PKCanvasView }.first)
        XCTAssertEqual(canvas.contentInset.bottom, 100, accuracy: 0.5)

        // Narrow & shorten the window (Stage Manager / Split View): scale = 384 / 768 = 0.5
        // So 100pt viewport bottom chrome becomes 200pt in page coordinates.
        resize(viewport, to: CGSize(width: 384, height: 340))
        XCTAssertEqual(viewport.paperView.bounds.width, 768, accuracy: 0.01)
        XCTAssertEqual(viewport.paperView.bounds.height, 680, accuracy: 0.01)
        XCTAssertEqual(canvas.contentInset.bottom, 200, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(canvas.contentOffset.y, 0)
    }

    func testDarkAndLightThumbnailsDoNotCollideInCache() throws {
        let points = [CGPoint(x: 20, y: 20), CGPoint(x: 120, y: 80)]
        let path = PKStrokePath(controlPoints: points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.05,
                          size: CGSize(width: 5, height: 5), opacity: 1,
                          force: 1, azimuth: 0, altitude: .pi / 2)
        }, creationDate: .now)
        let drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)])
        let data = drawing.dataRepresentation()
        let key = "theme-test-\(UUID().uuidString)"

        let lightThumb = try XCTUnwrap(Note.makeThumbnail(drawingData: data, cacheKey: key, userInterfaceStyle: .light))
        let darkThumb = try XCTUnwrap(Note.makeThumbnail(drawingData: data, cacheKey: key, userInterfaceStyle: .dark))
        // Separate cache entries must be produced for light vs dark appearances.
        XCTAssertFalse(lightThumb === darkThumb)
    }

    func testDarkModeAdaptsBlackTypedRepliesToBeLegible() throws {
        let viewport = PaperViewport()
        viewport.overrideUserInterfaceStyle = .dark
        resize(viewport, to: CGSize(width: 768, height: 1024))
        let darkText = TypedNoteText(text: "Answer: 42", x: 64, y: 120,
                                     xHeight: 18, maxX: 600, isUserMessage: false,
                                     fontName: "Georgia-Italic", colorHex: "#000000")
        viewport.paperView.loadDrawing(PKDrawing(), typedTexts: [darkText])
        let canvas = try XCTUnwrap(viewport.paperView.subviews.compactMap { $0 as? PKCanvasView }.first)
        let label = try XCTUnwrap(canvas.subviews.compactMap { $0 as? UILabel }.first)
        let color = try XCTUnwrap(label.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
        let darkResolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        let lightResolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var dr: CGFloat = 0, dg: CGFloat = 0, db: CGFloat = 0, da: CGFloat = 0
        var lr: CGFloat = 0, lg: CGFloat = 0, lb: CGFloat = 0, la: CGFloat = 0
        XCTAssertTrue(darkResolved.getRed(&dr, green: &dg, blue: &db, alpha: &da))
        XCTAssertTrue(lightResolved.getRed(&lr, green: &lg, blue: &lb, alpha: &la))
        // Pure black light-authored text stays dark in light mode and adapts to bright ink in dark mode.
        XCTAssertLessThan(0.2126 * lr + 0.7152 * lg + 0.0722 * lb, 0.2)
        XCTAssertGreaterThan(0.2126 * dr + 0.7152 * dg + 0.0722 * db, 0.5)
    }
}
