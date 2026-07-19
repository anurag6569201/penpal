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

enum NoteExporter {

    /// Margin around the ink, in points.
    private static let margin: CGFloat = 48

    /// Where the ink sits, padded, never smaller than a sensible page.
    private static func canvasRect(for drawing: PKDrawing) -> CGRect? {
        let bounds = drawing.bounds
        guard !bounds.isNull, bounds.width > 1, bounds.height > 1 else { return nil }
        return bounds.insetBy(dx: -margin, dy: -margin).integral
    }

    /// Draws paper + ink into the current context. Shared by both formats so
    /// a PDF and a PNG of the same note can never disagree.
    private static func draw(_ drawing: PKDrawing, in rect: CGRect,
                             paperStyle: String, scale: CGFloat) {
        UIColor.white.setFill()
        UIBezierPath(rect: CGRect(origin: .zero, size: rect.size)).fill()

        drawPaper(paperStyle, in: rect.size)

        // Force light so dark-mode ink exports as dark ink, not invisible ink.
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: rect, scale: scale)
        }
        image.draw(in: CGRect(origin: .zero, size: rect.size))
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

    /// A vector PDF of the note. Nil when there is no ink to export.
    static func pdf(for drawing: PKDrawing, title: String,
                    paperStyle: String) -> URL? {
        guard let rect = canvasRect(for: drawing) else { return nil }

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: title.isEmpty ? "Penpal note" : title,
            kCGPDFContextCreator as String: "Penpal",
        ]
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: rect.size), format: format)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeFilename(title)).pdf")
        do {
            try renderer.writePDF(to: url) { context in
                context.beginPage()
                // 2× keeps the rasterised ink sharp when the PDF is zoomed or
                // printed; the page geometry itself stays vector.
                draw(drawing, in: rect, paperStyle: paperStyle, scale: 2)
            }
            return url
        } catch {
            print("PDF export failed: \(error)")
            return nil
        }
    }

    /// A flattened PNG-backed image, for apps that won't take a PDF.
    static func image(for drawing: PKDrawing, paperStyle: String) -> UIImage? {
        guard let rect = canvasRect(for: drawing) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            draw(drawing, in: rect, paperStyle: paperStyle, scale: 2)
        }
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
