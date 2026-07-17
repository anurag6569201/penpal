//
//  InkRecognizer.swift
//  penpal
//
//  Reads the user's handwriting. Renders the freshly written PencilKit strokes
//  to a high-contrast image and runs Apple's Vision text recognizer on-device,
//  turning the ink into a plain string we can hand to the Gemini brain.
//
//  This is the missing link that lets Penpal *understand* what you wrote with
//  the pen (instead of only reacting to typed text): write -> recognize ->
//  Gemini -> reply on the next line.
//

import UIKit
import PencilKit
@preconcurrency import Vision
import CoreImage

enum InkRecognizer {

    /// Best-effort transcription of the given strokes. Returns "" when the ink
    /// can't be read (too little ink, scribbles, or Vision found nothing).
    @MainActor
    static func recognize(strokes: [PKStroke],
                          traits: UITraitCollection? = nil) async -> String {
        guard !strokes.isEmpty else { return "" }
        guard let cgImage = renderImage(strokes: strokes, traits: traits) else {
            return ""
        }
        return await transcribe(cgImage)
    }

    // MARK: - Rendering ink -> dark-on-light image

    /// Rasterizes the strokes as dark ink on a white background so Vision has the
    /// contrast it expects, regardless of the app's light/dark appearance.
    @MainActor
    private static func renderImage(strokes: [PKStroke],
                                    traits: UITraitCollection?) -> CGImage? {
        let drawing = PKDrawing(strokes: strokes)
        let bounds = drawing.bounds
        guard bounds.width > 2, bounds.height > 2 else { return nil }

        // Pad so ascenders/descenders aren't clipped and letters have breathing room.
        let pad = max(24, max(bounds.width, bounds.height) * 0.12)
        let rect = bounds.insetBy(dx: -pad, dy: -pad)

        // Scale up small handwriting so Vision sees crisp glyphs.
        let longest = max(rect.width, rect.height)
        let scale = min(8, max(2, 2000 / max(longest, 1)))

        // Resolve the ink color for the current appearance. In dark mode the pen
        // ink (.label) is light, so we composite over black then invert to get
        // dark-on-white either way.
        let resolved = UIColor.label.resolvedColor(with: traits ?? UITraitCollection.current)
        let inkIsLight = luminance(of: resolved) > 0.55

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: rect.size, format: format)

        let composed = renderer.image { ctx in
            (inkIsLight ? UIColor.black : UIColor.white).setFill()
            ctx.fill(CGRect(origin: .zero, size: rect.size))
            let ink = drawing.image(from: rect, scale: scale)
            ink.draw(in: CGRect(origin: .zero, size: rect.size))
        }

        guard var cg = composed.cgImage else { return nil }
        if inkIsLight, let inverted = invert(cg) {
            cg = inverted
        }
        return cg
    }

    private static func luminance(of color: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    private static func invert(_ image: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIColorInvert") else { return nil }
        filter.setValue(ci, forKey: kCIInputImageKey)
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: nil)
        return context.createCGImage(output, from: output.extent)
    }

    // MARK: - Vision transcription

    private static func transcribe(_ cgImage: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            // Build the request AND the handler inside the background block:
            // neither type is Sendable, so nothing may cross the isolation
            // boundary — only the (Sendable) continuation and image do.
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest { request, _ in
                    let observations = request.results as? [VNRecognizedTextObservation] ?? []
                    // Vision returns observations roughly top-to-bottom; join lines with spaces.
                    let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                    let text = lines.joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: text)
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["en-US"]

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }
}
