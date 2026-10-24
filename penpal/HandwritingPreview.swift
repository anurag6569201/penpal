import SwiftUI
import PencilKit

/// Uses the same layout, smoothing and PencilKit conversion as saved replies.
/// Color and weight changes reuse geometry instead of resynthesizing the hand.
struct HandwritingPreview: UIViewRepresentable {
    @ObservedObject var settings: HandwritingSettings
    var text: String = "Today is a good day."
    var handID: UUID?
    var width: CGFloat
    var height: CGFloat

    final class Coordinator {
        var geometryKey = ""
        var strokes: [InkStroke] = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.isUserInteractionEnabled = false
        canvas.isScrollEnabled = false
        canvas.backgroundColor = UIColor(Pen.paper)
        canvas.isOpaque = false
        canvas.accessibilityLabel = "Preview of Penpal reply handwriting"
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        let size = settings.resolvedSize(detected: 18)
        let key = "\(text)/\(handID?.uuidString ?? "default")/\(width)/\(height)/\(size)/\(settings.variation)/\(settings.penWidthScale)/\(settings.letterSpacingScale)/\(settings.wordSpacingScale)/\(settings.lineSpacingScale)"
        guard width > 40 else { return }
        if key != context.coordinator.geometryKey {
            context.coordinator.geometryKey = key
            context.coordinator.strokes = StrokeFont.layoutSequence(
                text: text,
                origin: CGPoint(x: 12, y: size * 1.8 + 10),
                xHeight: size, maxX: width - 16, lineGap: 32,
                maxY: height - 16, messiness: CGFloat(settings.variation / 10),
                useUserHand: true, settings: settings, allowSynthesis: false
            ).strokes
        }
        let baseWidth = ReplyInkStyle.baseWidth(xHeight: size, weight: settings.penWidthScale)
        let prepared = ReplyInkStyle.prepare(context.coordinator.strokes, baseWidth: baseWidth)
        let strokes = prepared.compactMap { stroke in
            ReplyInkStyle.pencilStroke(
                from: HandwritingRenderer.smoothed(stroke, amount: CGFloat(settings.smoothness)),
                baseWidth: baseWidth, color: settings.replyInkColor())
        }
        canvas.drawing = PKDrawing(strokes: strokes)
    }
}
