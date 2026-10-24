import XCTest
import PencilKit
@testable import penpal

@MainActor
final class ReplyAppearanceTests: XCTestCase {
    func testFixedReplyColorWinsOverSourceInk() {
        let settings = HandwritingSettings.shared
        let oldName = settings.inkColorName
        let oldTool = settings.activeToolColor
        defer { settings.inkColorName = oldName; settings.activeToolColor = oldTool }
        settings.inkColorName = "blue"
        settings.activeToolColor = .red
        XCTAssertEqual(settings.replyInkColor(matching: .green), UIColor.systemBlue.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))
        settings.inkColorName = "active"
        XCTAssertEqual(settings.replyInkColor(matching: .green), UIColor.red)
        settings.activeToolColor = nil
        XCTAssertEqual(settings.replyInkColor(matching: .green), UIColor.green)
    }

    func testPreparedInkPreservesPressureAndSavedColorAtEveryConfidence() throws {
        let points = [CGPoint(x: 20, y: 30), CGPoint(x: 40, y: 60), CGPoint(x: 60, y: 30)]
        let source = InkStroke(points: points, widths: [2, 4, 2], confidence: 0.1)
        let prepared = try XCTUnwrap(ReplyInkStyle.prepare([source], baseWidth: 4).first)
        let widths = try XCTUnwrap(prepared.widths)
        XCTAssertGreaterThan(widths[1], widths[0], "Captured pressure must not become a constant marker stroke")
        let color = UIColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 1)
        let saved = try XCTUnwrap(ReplyInkStyle.pencilStroke(from: prepared, baseWidth: 4, color: color))
        XCTAssertEqual(saved.ink.color.hexString, color.hexString)
        XCTAssertEqual(saved.ink.color.cgColor.alpha, 1, accuracy: 0.001)
        for (point, expectedWidth) in zip(saved.path, widths) {
            XCTAssertEqual(point.size.width, expectedWidth, accuracy: 0.0001)
            XCTAssertEqual(point.opacity, 1, accuracy: 0.01)
        }
    }

    func testNoVariationKeepsFallbackGeometryStable() {
        let settings = HandwritingSettings.shared
        func layout() -> [InkStroke] {
            StrokeFont.layoutSequence(text: "Today is a good day.", origin: CGPoint(x: 20, y: 60),
                                      xHeight: 18, maxX: 480, lineGap: 40, maxY: 200,
                                      messiness: 0, settings: settings).strokes
        }
        XCTAssertEqual(layout().map(\.points), layout().map(\.points))
    }

    func testTightLetterSpacingDoesNotShrinkGlyphAdvance() {
        let settings = HandwritingSettings.shared
        let old = settings.letterSpacingScale
        defer { settings.letterSpacingScale = old }
        settings.letterSpacingScale = 0.7
        let sequence = StrokeFont.layoutSequence(text: "mm", origin: CGPoint(x: 20, y: 60),
                                                xHeight: 20, maxX: 480, lineGap: 40, maxY: 200,
                                                messiness: 0, settings: settings)
        let first = sequence.strokes.filter { $0.letterIndex == 0 }.flatMap(\.points)
        let second = sequence.strokes.filter { $0.letterIndex == 1 }.flatMap(\.points)
        XCTAssertGreaterThanOrEqual(second.map(\.x).min()!, first.map(\.x).max()! - 1)
    }

    func testTypedReplyRetainsAppearanceAndDecodesLegacyNotes() throws {
        let text = TypedNoteText(text: "Hello", x: 20, y: 60, xHeight: 18, maxX: 400,
                                 isUserMessage: false, fontName: "Georgia-Italic", colorHex: "#224488")
        let data = try JSONEncoder().encode(text)
        let restored = try JSONDecoder().decode(TypedNoteText.self, from: data)
        XCTAssertEqual(restored.fontName, "Georgia-Italic")
        XCTAssertEqual(restored.colorHex, "#224488")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "fontName")
        legacy.removeValue(forKey: "colorHex")
        let decoded = try JSONDecoder().decode(TypedNoteText.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.fontName)
        XCTAssertNil(decoded.colorHex)
    }

    func testLegacyTypedAppearanceIsCapturedOnceOnLoad() throws {
        let settings = HandwritingSettings.shared
        let oldFont = settings.replyFontName
        let oldColor = settings.inkColorName
        defer { settings.replyFontName = oldFont; settings.inkColorName = oldColor }
        settings.replyFontName = "Georgia-Italic"
        settings.inkColorName = "blue"
        let view = MagicPaperView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let legacy = TypedNoteText(text: "Keep this style", x: 20, y: 80, xHeight: 18,
                                   maxX: 400, isUserMessage: false)
        view.loadDrawing(PKDrawing(), typedTexts: [legacy])
        let saved = try XCTUnwrap(view.currentTypedTexts.first)
        XCTAssertEqual(saved.fontName, "Georgia-Italic")
        XCTAssertEqual(saved.colorHex, settings.replyInkColor().hexString)
        settings.replyFontName = "AmericanTypewriter"
        settings.inkColorName = "green"
        view.loadDrawing(PKDrawing(), typedTexts: [saved])
        XCTAssertEqual(view.currentTypedTexts, [saved])
        let canvas = try XCTUnwrap(view.subviews.compactMap { $0 as? PKCanvasView }.first)
        let label = try XCTUnwrap(canvas.subviews.compactMap { $0 as? UILabel }.first)
        let attributes = try XCTUnwrap(label.attributedText?.attributes(at: 0, effectiveRange: nil))
        XCTAssertEqual((attributes[.font] as? UIFont)?.fontName, "Georgia-Italic")
        XCTAssertEqual((attributes[.foregroundColor] as? UIColor)?.hexString, saved.colorHex)
    }

    func testDotProducesVisiblePencilKitPixels() throws {
        let dot = InkStroke(points: [CGPoint(x: 16, y: 16)], isDot: true, dotRadius: 1.5)
        let stroke = try XCTUnwrap(ReplyInkStyle.pencilStroke(from: dot, baseWidth: 3, color: .black))
        let image = try XCTUnwrap(PKDrawing(strokes: [stroke]).image(from: CGRect(x: 0, y: 0, width: 32, height: 32), scale: 1).cgImage)
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let hasInk = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 32,
                                          bitsPerComponent: 8, bytesPerRow: 128,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 }
        }
        XCTAssertTrue(hasInk, "A full stop must leave actual visible pixels, not just an invisible path")
    }

    func testSavedTextColorRetainsOpacity() throws {
        let color = UIColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 0.6)
        let restored = try XCTUnwrap(UIColor(hex: color.hexStringIncludingAlpha))
        XCTAssertEqual(restored.cgColor.alpha, color.cgColor.alpha, accuracy: 1 / 255)
        XCTAssertEqual(restored.hexString, color.hexString)
    }

    func testWeightControlChangesEvenTheFinestVisibleInk() {
        let fine = ReplyInkStyle.baseWidth(xHeight: 18, weight: 0.55)
        let regular = ReplyInkStyle.baseWidth(xHeight: 18, weight: 1)
        let bold = ReplyInkStyle.baseWidth(xHeight: 18, weight: 1.8)
        XCTAssertGreaterThanOrEqual(fine, 3)
        XCTAssertGreaterThan(regular, fine)
        XCTAssertGreaterThan(bold, regular)
    }

    func testWritingAppearanceOnPaper() throws {
        let settings = HandwritingSettings.shared
        let frame = CGRect(x: 0, y: 0, width: 620, height: 420)
        let image = UIGraphicsImageRenderer(size: frame.size).image { context in
            UIColor(red: 247/255, green: 244/255, blue: 237/255, alpha: 1).setFill()
            context.fill(frame)
            for (index, weight) in [0.55, 1.0, 1.8].enumerated() {
                let baseline = CGFloat(index * 130 + 90)
                let sequence = StrokeFont.layoutSequence(
                    text: "Today is a good day.", origin: CGPoint(x: 24, y: baseline),
                    xHeight: 24, maxX: 596, lineGap: 40, maxY: baseline + 20,
                    messiness: 0, settings: settings)
                XCTAssertFalse(sequence.clipped)
                let width = ReplyInkStyle.baseWidth(xHeight: 24, weight: weight)
                let strokes = ReplyInkStyle.prepare(sequence.strokes, baseWidth: width).compactMap {
                    ReplyInkStyle.pencilStroke(from: HandwritingRenderer.smoothed($0, amount: 0.5),
                                              baseWidth: width, color: UIColor(red: 0.16, green: 0.22, blue: 0.45, alpha: 1))
                }
                XCTAssertFalse(strokes.isEmpty)
                let drawing = PKDrawing(strokes: strokes)
                drawing.image(from: frame, scale: 2).draw(in: frame)
                let title = ["Fine", "Regular", "Bold"][index]
                (title as NSString).draw(at: CGPoint(x: 24, y: baseline - 68),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.darkGray])
            }
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Penpal writing weights"
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("penpal-writing-preview.png")
        try image.pngData()?.write(to: url)
        print("WRITING_PREVIEW_PATH: \(url.path)")
    }

    func testRealCapturesAreNotMorphedBySentenceStyle() {
        let glyph = PersonalGlyph(width: 0.6, strokes: [[.zero, CGPoint(x: 0.3, y: 1), CGPoint(x: 0.6, y: 0)]])
        InkUnity.shared.beginSentence()
        defer { InkUnity.shared.endSentence() }
        for source in [WordInkSource.exact, .letters] {
            XCTAssertEqual(InkUnity.shared.unify(glyph, source: source).strokes, glyph.strokes)
        }
    }
}
