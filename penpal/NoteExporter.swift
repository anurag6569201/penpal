//
//  NoteExporter.swift
//  penpal
//
//  PEN-21 — export with ink fidelity.
//
//  Worksheet mode (PEN-15) and grading (PEN-16) only pay off if the finished
//  page can leave the app: homework gets handed in, a parent gets sent a
//  photo, a tutor gets the working. Until now "share" produced
//  `drawing.image(from:scale:)`, which has two problems:
//
//   1. **Transparent background.** The ink is drawn on nothing. Pasted into
//      most apps that renders as ink on white by luck, or on black by
//      accident.
//   2. **Current appearance.** In dark mode the user's ink is near-white, so
//      the exported image is white-on-transparent — effectively blank. The
//      most common way to hit this is also the least likely to be noticed
//      before sending.
//
//  Both are fixed by rendering onto real paper in a forced light trait, the
//  same rule the vision-model export already follows.
//
//  PDF is the primary format: it is vector, so a handed-in page stays crisp
//  at any size, and it is what "print this" and "attach to an assignment"
//  both expect.
//

import PencilKit
import UIKit

nonisolated struct NoteDrawingShareFiles: Sendable {
    var pdf: URL?
    var image: URL?
}

nonisolated enum NoteExporter {

    /// Margin around the ink, in points.
    private static let margin: CGFloat = 48

    /// Where the ink and typed replies sit, padded, never smaller than a sensible page.
    private static func canvasRect(for drawing: PKDrawing,
                                   typedTexts: [TypedNoteText] = [],
                                   replyInks: [ReplyInk] = []) -> CGRect? {
        var bounds = drawing.bounds
        for ink in replyInks {
            for stroke in ink.strokes {
                for pt in stroke.inkStroke.points where pt.x.isFinite && pt.y.isFinite {
                    let ptRect = CGRect(x: pt.x - 2, y: pt.y - 2, width: 4, height: 4)
                    bounds = bounds.isNull ? ptRect : bounds.union(ptRect)
                }
            }
        }
        for item in typedTexts where !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let rect = typedTextBounds(item)
            if !rect.isNull {
                bounds = bounds.isNull ? rect : bounds.union(rect)
            }
        }
        guard !bounds.isNull, bounds.width > 1, bounds.height > 1 else { return nil }
        return bounds.insetBy(dx: -margin, dy: -margin).integral
    }

    private static func typedTextAttributes(for item: TypedNoteText) -> [NSAttributedString.Key: Any] {
        let fontSize = max(14, item.xHeight * 1.15)
        let fontName = item.fontName ?? "Georgia-Italic"
        let font = UIFont(name: fontName, size: fontSize)
            ?? UIFont.italicSystemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = max(4, item.xHeight * 0.35)
        // Force a legible dark ink on exported white paper even if the note was
        // authored in dark mode with near-white ink.
        var color = item.colorHex.flatMap { UIColor(hex: $0) }
            ?? (item.isUserMessage ? UIColor.darkGray : UIColor.black)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            if luminance > 0.78 {
                color = item.isUserMessage
                    ? UIColor(white: 0.32, alpha: max(0.75, a))
                    : UIColor(red: 26/255, green: 43/255, blue: 42/255, alpha: max(0.85, a))
            }
        }
        return [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
    }

    private static func typedTextBounds(_ item: TypedNoteText) -> CGRect {
        let display = item.isUserMessage ? "› \(item.text)" : item.text
        let maxWidth = max(120, item.maxX - item.x)
        let fontSize = max(14, item.xHeight * 1.15)
        let attrs = typedTextAttributes(for: item)
        let measured = (display as NSString).boundingRect(
            with: CGSize(width: maxWidth, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs,
            context: nil
        )
        let topY = item.y - fontSize * 0.85
        return CGRect(
            x: item.x,
            y: topY,
            width: min(maxWidth, ceil(measured.width) + 4),
            height: max(fontSize * 1.2, ceil(measured.height) + 4)
        )
    }

    /// Draws paper + ink + typed text into the current context. Shared by both
    /// formats so a PDF and a PNG of the same note can never disagree.
    private static func draw(_ drawing: PKDrawing,
                             typedTexts: [TypedNoteText] = [],
                             replyInks: [ReplyInk] = [],
                             in rect: CGRect,
                             paperStyle: String,
                             scale: CGFloat) {
        UIColor.white.setFill()
        UIBezierPath(rect: CGRect(origin: .zero, size: rect.size)).fill()

        drawPaper(paperStyle, in: rect.size)

        var allStrokes = drawing.strokes
        let fallbackColor = UIColor(red: 26/255, green: 43/255, blue: 42/255, alpha: 1)
        for ink in replyInks {
            let baseWidth = max(3, ink.baseWidth)
            let prepared = ReplyInkStyle.prepare(ink.strokes.map(\.inkStroke), baseWidth: baseWidth)
            for stroke in prepared {
                if let pk = ReplyInkStyle.pencilStroke(from: stroke, baseWidth: baseWidth, color: fallbackColor) {
                    allStrokes.append(pk)
                }
            }
        }
        let combinedDrawing = PKDrawing(strokes: allStrokes)
        if !combinedDrawing.strokes.isEmpty {
            // Force light so dark-mode ink exports as dark ink, not invisible ink.
            var image = UIImage()
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                image = combinedDrawing.image(from: rect, scale: scale)
            }
            image.draw(in: CGRect(origin: .zero, size: rect.size))
        }

        for item in typedTexts where !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let display = item.isUserMessage ? "› \(item.text)" : item.text
            let itemRect = typedTextBounds(item).offsetBy(dx: -rect.minX, dy: -rect.minY)
            let attrs = typedTextAttributes(for: item)
            (display as NSString).draw(
                with: itemRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs,
                context: nil
            )
        }
    }

    /// Reproduces the ruled/grid/dotted paper so an exported page looks like
    /// the page the user was writing on, not like ink floating in space.
    private static func drawPaper(_ style: String, in size: CGSize) {
        guard style != "blank",
              let ctx = UIGraphicsGetCurrentContext() else { return }
        let line = UIColor.systemGray4
        ctx.setStrokeColor(line.cgColor)
        ctx.setFillColor(line.cgColor)
        ctx.setLineWidth(0.6)
        let gap: CGFloat = 32

        switch style {
        case "grid":
            var x: CGFloat = 0
            while x < size.width {
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: size.height))
                x += gap
            }
            fallthrough
        case "ruled":
            var y: CGFloat = gap
            while y < size.height {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: size.width, y: y))
                y += gap
            }
            ctx.strokePath()
        case "dots":
            var y: CGFloat = gap
            while y < size.height {
                var x: CGFloat = gap
                while x < size.width {
                    ctx.fillEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    x += gap
                }
                y += gap
            }
        default:
            break
        }
    }

    // MARK: - Formats

    /// Produces shareable files from the persisted drawing data. This entry
    /// point is safe to run on a user-initiated background task so large pages
    /// don't freeze the editor while their PDF and preview are rendered.
    static func shareFiles(drawingData: Data,
                           typedTexts: [TypedNoteText] = [],
                           replyInks: [ReplyInk] = [],
                           title: String,
                           paperStyle: String) -> NoteDrawingShareFiles {
        let drawing = (try? PKDrawing(data: drawingData)) ?? PKDrawing()
        guard !drawing.strokes.isEmpty || !typedTexts.isEmpty || !replyInks.isEmpty else {
            return NoteDrawingShareFiles(pdf: nil, image: nil)
        }
        return NoteDrawingShareFiles(
            pdf: pdf(for: drawing, typedTexts: typedTexts, replyInks: replyInks,
                     title: title, paperStyle: paperStyle),
            image: imageFile(for: drawing, typedTexts: typedTexts, replyInks: replyInks,
                             title: title, paperStyle: paperStyle)
        )
    }

    /// A vector PDF of the note. Nil when there is no ink or typed text to export.
    static func pdf(for drawing: PKDrawing,
                    typedTexts: [TypedNoteText] = [],
                    replyInks: [ReplyInk] = [],
                    title: String,
                    paperStyle: String) -> URL? {
        guard let rect = canvasRect(for: drawing, typedTexts: typedTexts, replyInks: replyInks) else {
            return nil
        }

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: title.isEmpty ? "Penpal note" : title,
            kCGPDFContextCreator as String: "Penpal",
        ]
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: rect.size), format: format)

        let url = exportURL(title: title, fileExtension: "pdf")
        do {
            try renderer.writePDF(to: url) { context in
                context.beginPage()
                // 2× keeps the rasterised ink sharp when the PDF is zoomed or
                // printed; the page geometry itself stays vector.
                draw(drawing, typedTexts: typedTexts, replyInks: replyInks,
                     in: rect, paperStyle: paperStyle, scale: 2)
            }
            return url
        } catch {
            print("PDF export failed: \(error)")
            return nil
        }
    }

    /// A flattened PNG-backed image, for apps that won't take a PDF.
    static func image(for drawing: PKDrawing,
                      typedTexts: [TypedNoteText] = [],
                      replyInks: [ReplyInk] = [],
                      paperStyle: String) -> UIImage? {
        guard let rect = canvasRect(for: drawing, typedTexts: typedTexts, replyInks: replyInks) else {
            return nil
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            draw(drawing, typedTexts: typedTexts, replyInks: replyInks,
                 in: rect, paperStyle: paperStyle, scale: 2)
        }
    }

    /// Writes the flattened image directly to a temporary file. Returning a
    /// URL keeps the rendered bitmap off the main actor and avoids rebuilding
    /// a large `UIImage` when the share sheet asks for its preview.
    private static func imageFile(for drawing: PKDrawing,
                                  typedTexts: [TypedNoteText] = [],
                                  replyInks: [ReplyInk] = [],
                                  title: String,
                                  paperStyle: String) -> URL? {
        guard let data = image(for: drawing, typedTexts: typedTexts,
                               replyInks: replyInks, paperStyle: paperStyle)?.pngData() else {
            return nil
        }
        let url = exportURL(title: title, fileExtension: "png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            print("PNG export failed: \(error)")
            return nil
        }
    }

    private static func exportURL(title: String, fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeFilename(title))-\(UUID().uuidString).\(fileExtension)")
    }

    private static func safeFilename(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Penpal note" : trimmed
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(
            CharacterSet(charactersIn: "-_"))
        return String(base.unicodeScalars.filter { allowed.contains($0) })
            .prefix(60)
            .trimmingCharacters(in: .whitespaces)
    }
}
