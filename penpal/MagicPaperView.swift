//
//  MagicPaperView.swift
//  penpal
//
//  The magic page: paper + PencilKit canvas for the user's ink +
//  HandwritingRenderer overlay where the "invisible pen" writes back.
//  Watches for a pause in writing, detects where/how the user wrote,
//  and orchestrates the reply.
//
//  The canvas scrolls: paper grows automatically as ink or replies approach
//  the bottom (infinite pages), and the paper background supports ruled /
//  grid / dots / blank styles.
//

import UIKit
import PencilKit

// MARK: - Paper background

final class PaperBackgroundView: UIView {

    var style: String = "ruled" { didSet { setNeedsDisplay() } }
    var lineGap: CGFloat = 44
    var topInset: CGFloat = 40
    var leftMargin: CGFloat = 64

    /// Absolute y of this view's origin in scroll-content space. The view is
    /// only viewport-sized (a full-content layer's backing store grows with
    /// the page — hundreds of MB after a few pages); it gets repositioned
    /// while scrolling and draws its ruling in content coordinates.
    var contentOriginY: CGFloat = 0 {
        didSet { if oldValue != contentOriginY { setNeedsDisplay() } }
    }

    /// Local y of the first ruling at or below this view's top edge, for
    /// rulings that start at absolute `start` and repeat every `gap`.
    private func firstRulingY(start: CGFloat, gap: CGFloat) -> CGFloat {
        let k = max(0, ceil((contentOriginY - start) / gap))
        return start + k * gap - contentOriginY
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let rule = UIColor.separator.withAlphaComponent(0.5)
        let faint = UIColor.separator.withAlphaComponent(0.28)

        switch style {
        case "grid":
            ctx.setLineWidth(0.7)
            ctx.setStrokeColor(faint.cgColor)
            let cell = lineGap / 2
            var x: CGFloat = 12
            while x < bounds.width - 12 {
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: bounds.height))
                x += cell
            }
            var y = firstRulingY(start: topInset, gap: cell)
            while y < bounds.height {
                ctx.move(to: CGPoint(x: 12, y: y))
                ctx.addLine(to: CGPoint(x: bounds.width - 12, y: y))
                y += cell
            }
            ctx.strokePath()

        case "dots":
            ctx.setFillColor(UIColor.separator.withAlphaComponent(0.55).cgColor)
            let cell = lineGap / 2
            var y = firstRulingY(start: topInset, gap: cell)
            while y < bounds.height {
                var x: CGFloat = 16
                while x < bounds.width - 12 {
                    ctx.fillEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    x += cell
                }
                y += cell
            }

        case "blank":
            break

        default: // ruled
            ctx.setLineWidth(1)
            ctx.setStrokeColor(rule.cgColor)
            var y = firstRulingY(start: topInset + lineGap, gap: lineGap)
            while y < bounds.height {
                ctx.move(to: CGPoint(x: 12, y: y))
                ctx.addLine(to: CGPoint(x: bounds.width - 12, y: y))
                y += lineGap
            }
            ctx.strokePath()
        }
    }
}

// MARK: - Magic paper

final class MagicPaperView: UIView, PKCanvasViewDelegate, UIEditMenuInteractionDelegate, PKToolPickerObserver {

    // MARK: Tunables (set from SwiftUI)

    var settings: HandwritingSettings = .shared { didSet { applySettings() } }
    /// When false, ink is normal Notes drawing — no OCR / brain / reply.
    var penpalEnabled: Bool = false
    var autoReply: Bool { settings.autoReply && penpalEnabled }
    var showDetection: Bool { settings.diagnostics }
    var messiness: CGFloat { CGFloat(settings.variation / 10) }

    var onWritingStateChange: ((Bool) -> Void)?
    var onThinkingChange: ((Bool) -> Void)?
    /// True while ink is being OCR'd / math-parsed (the slow local read).
    var onReadingChange: ((Bool) -> Void)?
    var onStatus: ((String) -> Void)?
    var onDrawingChange: ((PKDrawing) -> Void)?
    var onUndoRedoChange: ((Bool, Bool) -> Void)?
    /// Fired whenever the typed (font-style) Penpal texts on this page change,
    /// so the store can persist them with the note.
    var onTypedTextsChange: (([TypedNoteText]) -> Void)?
    /// Fired whenever the AI hand-written replies on this page change,
    /// so the store can persist them with the note.
    var onReplyInksChange: (([ReplyInk]) -> Void)?

    // MARK: Layout constants

    private let lineGap: CGFloat = 44
    private let rulesTopInset: CGFloat = 40
    private let leftMargin: CGFloat = 64

    /// Reply writing size, derived from the RULED LINES — not from measuring
    /// the user's ink. Training guides put the ascender line at 2 x-heights,
    /// so 0.4 × lineGap makes ascenders span ~80% of a ruled gap and keeps
    /// lines single-spaced. Manual size still overrides.
    private var lineRelativeXHeight: CGFloat {
        settings.resolvedSize(detected: lineGap * 0.4)
    }

    // MARK: Subviews / state

    private let canvas = PKCanvasView()
    private let paper = PaperBackgroundView()
    private let renderer = HandwritingRenderer()
    private var idleTimer: Timer?
    /// The floating "5 × 5 — Solve" confirmation, when one is showing.
    private var intentChip: MathIntentChip?
    /// Delays the "Reading…" banner so short OCR doesn't flash chrome.
    private var readingBannerTask: Task<Void, Never>?
    private var lastReplyStrokeCount = 0
    private var lastReplyBottom: CGFloat = 0
    private var provider = HandAwareReplyProvider()
    private var typedLabels: [UILabel] = []
    /// Persisted models behind `typedLabels` (same order is not required).
    private var placedTexts: [TypedNoteText] = []
    /// Persisted AI replies already on this page (renderer strokes).
    private var placedInks: [ReplyInk] = []
    /// Hand-style reply strokes currently animating; once the animation ends
    /// (or is interrupted) they're persisted with the note as renderer ink —
    /// never converted to PencilKit strokes, which render differently and
    /// would visibly change the reply the moment it finished.
    private var pendingBake: (strokes: [InkStroke], baseWidth: CGFloat,
                              bottomY: CGFloat, color: UIColor)?

    /// Long-press deletion of Penpal content (the PencilKit eraser can't
    /// touch it — replies aren't canvas strokes).
    private enum PenpalHit { case reply(UUID), typed(Int) }
    private var pendingHit: PenpalHit?
    private var editMenu: UIEditMenuInteraction?

    /// Scrollable paper height; grows as needed (infinite pages).
    private var contentHeight: CGFloat = 0

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .systemBackground

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // .default (not .anyInput): only the default policy respects the
        // system "Draw with Finger" toggle in the tool picker's ⋯ menu.
        canvas.drawingPolicy = settings.pencilOnly ? .pencilOnly : .default
        canvas.tool = PKInkingTool(.pen, color: .label, width: 3)
        canvas.delegate = self
        canvas.alwaysBounceVertical = true
        addSubview(canvas)

        paper.lineGap = lineGap
        paper.topInset = rulesTopInset
        paper.leftMargin = leftMargin
        canvas.insertSubview(paper, at: 0)
        canvas.addSubview(renderer)

        // Long-press (finger) a Penpal reply → Delete menu. Finger-only so it
        // never fights Pencil drawing.
        let press = UILongPressGestureRecognizer(target: self,
                                                 action: #selector(handleInkLongPress(_:)))
        press.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        canvas.addGestureRecognizer(press)
        let menu = UIEditMenuInteraction(delegate: self)
        canvas.addInteraction(menu)
        editMenu = menu

        // Keep the undo/redo buttons in sync with the canvas's undo stack.
        for name in [NSNotification.Name.NSUndoManagerDidUndoChange,
                     .NSUndoManagerDidRedoChange,
                     .NSUndoManagerDidCloseUndoGroup] {
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(undoStateChanged),
                                                   name: name, object: nil)
        }

        applySettings()
        // Load math.js in the background so the first "=" answers instantly.
        MathEngine.shared.warmUp()
    }

    @objc private func undoStateChanged() {
        publishUndoRedo()
    }

    private func applySettings() {
        // Runs on every SwiftUI update — only touch UIKit when values changed.
        // .default respects the pen tray's "Draw with Finger" toggle;
        // .anyInput would silently ignore it (finger keeps drawing).
        let policy: PKCanvasViewDrawingPolicy = settings.pencilOnly ? .pencilOnly : .default
        if canvas.drawingPolicy != policy { canvas.drawingPolicy = policy }
        // Lock the live-writing color to the same light-resolved value used
        // when the stroke is baked into the canvas (see bakedInkColor).
        // Using the raw dynamic color here would let it track the device's
        // current light/dark appearance during animation, then jump to the
        // fixed light variant the instant the stroke lands on the canvas —
        // a visible color shift right as ink "gets into canvas".
        renderer.inkColor = bakedInkColor
        renderer.speed = 120 + CGFloat(settings.speedLevel) * 55
        renderer.widthScale = CGFloat(settings.penWidthScale)
        renderer.smoothness = CGFloat(settings.smoothness)
        if paper.style != settings.paperStyle {
            paper.style = settings.paperStyle
            layoutPaper()   // ruling period may differ per style
        }
    }

    // MARK: - Notes chrome API

    var currentDrawing: PKDrawing { canvas.drawing }
    var currentTypedTexts: [TypedNoteText] { placedTexts }
    var currentReplyInks: [ReplyInk] { placedInks }

    var canUndo: Bool { canvas.undoManager?.canUndo ?? false }
    var canRedo: Bool { canvas.undoManager?.canRedo ?? false }

    func loadDrawing(_ drawing: PKDrawing,
                     typedTexts: [TypedNoteText] = [],
                     replyInks: [ReplyInk] = [],
                     resetReplyCursor: Bool = true) {
        // A reply that was still animating belongs to the previous note —
        // stop it and drop it so it can't leak onto this one.
        pendingBake = nil
        bakedUpTo = 0
        renderer.cancelWriting()
        renderer.clearInk()
        dismissIntentChip()
        idleTimer?.invalidate()

        suppressChanges = true
        canvas.drawing = drawing
        lastReplyStrokeCount = drawing.strokes.count

        typedLabels.forEach { $0.removeFromSuperview() }
        typedLabels.removeAll()
        placedTexts = typedTexts
        var typedBottom: CGFloat = 0
        for text in typedTexts {
            let label = makeTypedLabel(text: text.text,
                                       origin: CGPoint(x: text.x, y: text.y),
                                       xHeight: text.xHeight,
                                       maxX: text.maxX,
                                       color: text.isUserMessage ? .secondaryLabel : settings.inkColor)
            canvas.addSubview(label)
            typedLabels.append(label)
            typedBottom = max(typedBottom, label.frame.maxY)
        }

        // Redraw saved AI replies exactly as they were written — same
        // renderer, same layers, no animation.
        placedInks = replyInks
        var replyBottom: CGFloat = 0
        for ink in replyInks {
            renderer.drawStatic(ink.strokes.map(\.inkStroke), baseWidth: ink.baseWidth)
            replyBottom = max(replyBottom, ink.bottomY)
        }

        if resetReplyCursor {
            let inkBottom = drawing.strokes.map { $0.renderBounds.maxY }.max() ?? 0
            lastReplyBottom = max(inkBottom, max(typedBottom, replyBottom))
            if lastReplyBottom > 0 { lastReplyBottom += lineGap }
        }
        // PKDrawing().bounds is CGRect.null for an empty drawing, whose maxY
        // is +inf — that would poison contentHeight (infinite layer sizes,
        // broken canvas). Only trust bounds when there are strokes.
        let inkMaxY = drawing.strokes.isEmpty ? 0 : drawing.bounds.maxY
        contentHeight = max(bounds.height, inkMaxY + lineGap * 4,
                            typedBottom + lineGap * 4, replyBottom + lineGap * 4,
                            lastReplyBottom + lineGap * 4)
        updateContentLayout()
        suppressChanges = false
        publishUndoRedo()
    }

    func setTool(_ tool: PKTool) {
        canvas.tool = tool
    }

    func setRulerActive(_ active: Bool) {
        canvas.isRulerActive = active
    }

    func setDrawingInteractionEnabled(_ enabled: Bool) {
        canvas.isUserInteractionEnabled = enabled
    }

    // MARK: Native tool picker (the real Apple Notes pen tray)

    private lazy var toolPicker: PKToolPicker = {
        let picker = PKToolPicker()
        picker.addObserver(canvas)
        picker.addObserver(self)
        return picker
    }()

    override var canBecomeFirstResponder: Bool { true }

    /// Shows / hides the system PKToolPicker floating palette, exactly like Notes.
    func setToolsVisible(_ visible: Bool) {
        toolPicker.setVisible(visible, forFirstResponder: canvas)
        if visible {
            canvas.becomeFirstResponder()
            syncActiveToolColor()
        } else {
            canvas.resignFirstResponder()
        }
    }

    var isToolPickerVisible: Bool { toolPicker.isVisible }

    /// Mirrors the color of whatever tool the user currently has selected in
    /// the system pen tray into `settings.activeToolColor`, so the "Active"
    /// ink swatch (write replies in whatever color I'm writing with) tracks
    /// it live instead of needing a manual color match.
    func toolPickerSelectedToolDidChange(_ toolPicker: PKToolPicker) {
        syncActiveToolColor()
    }

    private func syncActiveToolColor() {
        if let inking = toolPicker.selectedTool as? PKInkingTool {
            settings.activeToolColor = inking.color
        }
    }

    func undo() {
        canvas.undoManager?.undo()
        publishUndoRedo()
        onDrawingChange?(canvas.drawing)
    }

    func redo() {
        canvas.undoManager?.redo()
        publishUndoRedo()
        onDrawingChange?(canvas.drawing)
    }

    func clearDrawing() {
        pendingBake = nil
        bakedUpTo = 0
        renderer.cancelWriting()
        renderer.clearInk()
        suppressChanges = true
        canvas.drawing = PKDrawing()
        lastReplyStrokeCount = 0
        lastReplyBottom = 0
        typedLabels.forEach { $0.removeFromSuperview() }
        typedLabels.removeAll()
        placedTexts.removeAll()
        placedInks.removeAll()
        suppressChanges = false
        onDrawingChange?(canvas.drawing)
        onTypedTextsChange?(placedTexts)
        onReplyInksChange?(placedInks)
        publishUndoRedo()
    }

    /// Snapshot stroke count so existing ink isn't treated as new Penpal input
    /// when the Penpal pen is selected mid-note.
    func syncReplyBaselineToCurrentInk() {
        lastReplyStrokeCount = canvas.drawing.strokes.count
    }

    private func publishUndoRedo() {
        onUndoRedoChange?(canUndo, canRedo)
    }

    // MARK: - Writing AI ink into the canvas

    /// How many of the pending reply's strokes are already committed into
    /// `canvas.drawing`.
    private var bakedUpTo = 0

    /// Commits one reply stroke into the canvas drawing as a real PKStroke —
    /// erasable, lassoable, undoable, shared and saved exactly like the
    /// user's own ink. Called stroke-by-stroke as the animation finishes each
    /// one, so the pen appears to write directly onto the page.
    private func bakeStroke(_ raw: InkStroke, baseWidth: CGFloat, color: UIColor) {
        let smoothed = HandwritingRenderer.smoothed(raw, amount: CGFloat(settings.smoothness))
        guard let pk = Self.pkStroke(from: smoothed, baseWidth: baseWidth, color: color) else { return }
        suppressChanges = true
        var drawing = canvas.drawing
        // Insert at the reply baseline so strokes the user draws while the AI
        // is writing stay after it — they remain "new, unanswered input".
        let at = min(lastReplyStrokeCount, drawing.strokes.count)
        drawing.strokes.insert(pk, at: at)
        canvas.drawing = drawing
        lastReplyStrokeCount += 1
        suppressChanges = false
        onDrawingChange?(canvas.drawing)   // debounced persistence
    }

    /// Tip width + ink color from the user's expression (Pencil tip size along
    /// the path). Character height is measured separately via `measureUserHand`.
    private static func sampleUserInk(from strokes: [PKStroke]) -> (width: CGFloat, color: UIColor)? {
        guard !strokes.isEmpty else { return nil }
        let line = strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
        let hand = InkAnalyzer.measureUserHand(from: strokes, fallbackLine: line,
                                               fallbackXHeight: 16)
        let rawColor = strokes.last?.ink.color ?? .label
        let color = rawColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        return (hand.tipWidth, color)
    }

    /// PencilKit stores stroke colors as light-mode authored and auto-adjusts
    /// them in dark mode; resolving here keeps the color stable across saves.
    private var bakedInkColor: UIColor {
        settings.inkColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
    }

    /// Finishes an in-flight reply instantly: remaining strokes are committed
    /// to the canvas in one go. Used when the user starts writing over it or
    /// the note is being flushed/switched.
    private func completePendingReplyInstantly() {
        guard let pending = pendingBake else {
            if renderer.isWriting {
                renderer.cancelWriting()
                onWritingStateChange?(false)
            }
            return
        }
        pendingBake = nil
        renderer.abandonCurrentWrite()
        if bakedUpTo < pending.strokes.count {
            for stroke in pending.strokes[bakedUpTo...] {
                bakeStroke(stroke, baseWidth: pending.baseWidth, color: pending.color)
            }
        }
        bakedUpTo = 0
        lastReplyBottom = max(lastReplyBottom, pending.bottomY)
        onWritingStateChange?(false)
        publishUndoRedo()
    }

    /// Converts a reply stroke into a PencilKit stroke. PencilKit's `.pen`
    /// reads thinner/lighter than a stroked CAShapeLayer — but when we stamp
    /// absolute tip `widths` (matched to the user), only a tiny boost is
    /// needed so the bake doesn't look like a fade OR a marker blob.
    private static func pkStroke(from stroke: InkStroke,
                                 baseWidth: CGFloat,
                                 color: UIColor) -> PKStroke? {
        let hasWidths = stroke.widths?.count == stroke.points.count
        // Matched absolute widths ≈ user tip; bare baseWidth needs a bigger
        // PK compensation for the animation→canvas handoff.
        let boost: CGFloat = hasWidths ? 0.95 : 1.9
        let minWidth: CGFloat = hasWidths
            ? max(1.2, baseWidth * 0.78)
            : max(1.9, baseWidth * 0.9)

        func point(_ location: CGPoint, _ time: TimeInterval, _ width: CGFloat) -> PKStrokePoint {
            PKStrokePoint(location: location,
                          timeOffset: time,
                          size: CGSize(width: width, height: width),
                          opacity: 0.9,
                          force: 1,
                          azimuth: 0,
                          altitude: .pi / 2)
        }

        if stroke.isDot, let c = stroke.points.first {
            let w = max(minWidth, max(baseWidth * boost, stroke.dotRadius * 2.2))
            let path = PKStrokePath(controlPoints: [point(c, 0, w), point(c, 0.01, w)],
                                    creationDate: Date())
            return PKStroke(ink: PKInk(.pen, color: color), path: path)
        }
        guard stroke.points.count > 1 else { return nil }

        let hasTimes = stroke.pointTimes?.count == stroke.points.count
        var controls: [PKStrokePoint] = []
        controls.reserveCapacity(stroke.points.count)
        var lastTime = -1.0
        for (i, p) in stroke.points.enumerated() {
            let nominal = hasWidths ? stroke.widths![i] : baseWidth
            let w = max(minWidth, nominal * boost)
            // timeOffset must be strictly increasing or PencilKit misrenders.
            let raw = hasTimes ? stroke.pointTimes![i] : Double(i) * 0.004
            let t = max(raw, lastTime + 0.001)
            lastTime = t
            controls.append(point(p, t, w))
        }
        let path = PKStrokePath(controlPoints: controls, creationDate: Date())
        return PKStroke(ink: PKInk(.pen, color: color), path: path)
    }

    /// If a reply is mid-animation, finish + persist it instantly.
    /// Called before the note is flushed/switched so nothing is lost.
    func finalizePendingWriting() {
        completePendingReplyInstantly()
    }

    // MARK: - Deleting Penpal content

    /// Removes every Penpal reply and typed message from this page.
    func clearPenpalContent() {
        completePendingReplyInstantly()
        renderer.clearInk()
        typedLabels.forEach { $0.removeFromSuperview() }
        typedLabels.removeAll()
        let hadTexts = !placedTexts.isEmpty
        let hadInks = !placedInks.isEmpty
        placedTexts.removeAll()
        placedInks.removeAll()
        if hadTexts { onTypedTextsChange?(placedTexts) }
        if hadInks { onReplyInksChange?(placedInks) }
    }

    @objc private func handleInkLongPress(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began else { return }
        let pt = gr.location(in: canvas)
        pendingHit = penpalHit(at: pt)
        guard pendingHit != nil else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: pt)
        editMenu?.presentEditMenu(with: config)
    }

    private func penpalHit(at pt: CGPoint) -> PenpalHit? {
        // Typed labels first (they sit above the ink), newest first.
        for (i, label) in typedLabels.enumerated().reversed()
        where label.frame.insetBy(dx: -8, dy: -8).contains(pt) {
            return .typed(i)
        }
        for ink in placedInks.reversed()
        where ink.boundingRect.insetBy(dx: -14, dy: -14).contains(pt) {
            return .reply(ink.id)
        }
        return nil
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let hit = pendingHit else { return nil }
        let title: String
        switch hit {
        case .reply:
            title = "Delete Penpal Reply"
        case .typed(let i):
            title = placedTexts.indices.contains(i) && placedTexts[i].isUserMessage
                ? "Delete Message" : "Delete Penpal Reply"
        }
        let delete = UIAction(title: title,
                              image: UIImage(systemName: "trash"),
                              attributes: .destructive) { [weak self] _ in
            self?.deletePendingHit()
        }
        return UIMenu(children: [delete])
    }

    private func deletePendingHit() {
        guard let hit = pendingHit else { return }
        pendingHit = nil
        switch hit {
        case .reply(let id):
            completePendingReplyInstantly()
            placedInks.removeAll { $0.id == id }
            redrawPersistedReplyInk()
            onReplyInksChange?(placedInks)
        case .typed(let i):
            guard typedLabels.indices.contains(i), placedTexts.indices.contains(i) else { return }
            typedLabels[i].removeFromSuperview()
            typedLabels.remove(at: i)
            placedTexts.remove(at: i)
            onTypedTextsChange?(placedTexts)
        }
    }

    /// Rebuilds all persisted reply ink from scratch (after a deletion).
    private func redrawPersistedReplyInk() {
        renderer.clearInk()
        for ink in placedInks {
            renderer.drawStatic(ink.strokes.map(\.inkStroke), baseWidth: ink.baseWidth)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        if contentHeight < bounds.height {
            contentHeight = bounds.height
        }
        updateContentLayout()
    }

    private func updateContentLayout() {
        // Never let a non-finite or absurd height reach CALayer / contentSize.
        if !contentHeight.isFinite || contentHeight < 0 {
            contentHeight = max(400, bounds.height)
        }
        let size = CGSize(width: bounds.width, height: contentHeight)
        if canvas.contentSize != size { canvas.contentSize = size }
        layoutPaper()
        // The renderer is a plain layer container (no backing store), so a
        // full-content frame is fine.
        let frame = CGRect(origin: .zero, size: size)
        if renderer.frame != frame { renderer.frame = frame }
    }

    /// Keeps the viewport-sized paper under the visible region. Its origin is
    /// snapped to the ruling period, so while scrolling the drawn pattern is
    /// identical and redraws only happen once per period, not per frame.
    private func layoutPaper() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let period = max(8, settings.paperStyle == "ruled" ? lineGap : lineGap / 2)
        let pad = period * 2
        let snapped = floor((canvas.contentOffset.y - pad) / period) * period
        let originY = max(0, snapped)
        let frame = CGRect(x: 0, y: originY,
                           width: bounds.width, height: bounds.height + pad * 2)
        if paper.frame != frame {
            paper.frame = frame
            paper.contentOriginY = originY
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        layoutPaper()
        // The confirmation chip is anchored in view space, so scrolling
        // would drift it away from its expression — retire it instead.
        dismissIntentChip()
    }

    // MARK: Infinite pages

    /// Extend the paper by one screenful (snapped to the ruling).
    func addPage() {
        let page = max(400, bounds.height)
        contentHeight += lineGap * ceil(page / lineGap)
        updateContentLayout()
    }

    /// Make sure there's paper below `y`; grow if the pen is running out.
    private func ensureRoom(below y: CGFloat) {
        if y > contentHeight - max(120, lineGap * 3) {
            addPage()
        }
    }

    private func scrollToReveal(_ y: CGFloat) {
        let target = min(max(0, y - bounds.height * 0.35),
                         max(0, contentHeight - bounds.height))
        canvas.setContentOffset(CGPoint(x: 0, y: target), animated: true)
    }

    // MARK: PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !suppressChanges else { return }
        if renderer.isWriting {
            // The user started writing over the reply — complete it instantly
            // (identical ink, no animation) and persist it.
            completePendingReplyInstantly()
        }
        // New ink while the calculator was "pondering" / reading — drop that
        // answer; the extended expression will retrigger with the full picture.
        renderer.cancelPondering()
        renderer.cancelCelebrate()
        setReadingBanner(false)
        // Same for a pending confirmation: the expression just changed, so
        // the chip is stale. A fresh one appears at the next pause.
        dismissIntentChip()
        // Writing near the bottom edge? Grow the paper quietly.
        if let last = canvasView.drawing.strokes.last {
            ensureRoom(below: last.renderBounds.maxY + lineGap * 2)
        }
        onDrawingChange?(canvasView.drawing)
        publishUndoRedo()
        // Erasing or undoing can shrink the stroke list below our "already
        // seen" marker — clamp it or new ink would never trigger again.
        lastReplyStrokeCount = min(lastReplyStrokeCount, canvasView.drawing.strokes.count)
        idleTimer?.invalidate()
        // The idle check always runs: the instant calculator ("5+5=") works
        // in ANY mode, even with Penpal off. replyNow(auto:) decides what is
        // actually allowed to respond.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.replyNow(auto: true) }
        }
    }

    private var suppressChanges = false

    // MARK: Reply

    /// Place a typed user note on the page, ask Gemini, then write the reply.
    func sendTextMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        idleTimer?.invalidate()
        guard !renderer.isWriting else {
            onStatus?("Wait for the current reply to finish.")
            return
        }

        let originY = max(lastReplyBottom + lineGap * 1.2, rulesTopInset + lineGap)
        ensureRoom(below: originY + lineGap * 6)
        scrollToReveal(originY)

        // Show the user's text on the page (secondary color) so the paper feels like a letter.
        let userPlacement = ReplyPlacement(
            origin: CGPoint(x: leftMargin, y: originY),
            xHeight: lineRelativeXHeight,
            maxX: bounds.width - 24,
            maxY: contentHeight + bounds.height,
            newInkBounds: .zero,
            detectedLines: [],
            needsNewPage: false
        )
        let userBottom = writeTypedReply(trimmed, placement: userPlacement,
                                         color: .secondaryLabel, announceWriting: false,
                                         isUser: true)
        lastReplyBottom = userBottom
        lastReplyStrokeCount = canvas.drawing.strokes.count

        guard settings.useBrain else {
            // Offline canned path
            if case .text(let reply) = provider.reply(toNewInk: []) {
                writeReplyText(reply)
            }
            return
        }

        onThinkingChange?(true)
        onWritingStateChange?(true)
        onStatus?("")
        Task { @MainActor in
            let store = ConversationStore.shared
            let history = store.historyForAPI()
            do {
                let reply = try await PenpalAPI.chat(
                    message: trimmed,
                    conversationId: store.conversationId,
                    history: history,
                    baseURL: settings.apiBaseURL,
                    capability: settings.capability,
                    mood: settings.companionMood,
                    customMood: settings.customMoodText,
                    mathDetail: settings.mathDetail
                )
                store.append(role: "user", content: trimmed)
                store.append(role: "assistant", content: reply)
                onThinkingChange?(false)
                onWritingStateChange?(false)
                writeReplyText(reply)
            } catch {
                onThinkingChange?(false)
                onWritingStateChange?(false)
                onStatus?(error.localizedDescription)
            }
        }
    }

    /// Render AI (or fallback) reply text using hand or font style.
    func writeReplyText(_ text: String) {
        idleTimer?.invalidate()
        guard !renderer.isWriting else { return }

        let originY = max(lastReplyBottom + lineGap * 1.1, rulesTopInset + lineGap)
        let virtualBounds = CGRect(x: 0, y: 0,
                                   width: bounds.width,
                                   height: contentHeight + max(400, bounds.height))
        let placement = ReplyPlacement(
            origin: CGPoint(x: leftMargin, y: originY),
            xHeight: lineRelativeXHeight,
            maxX: bounds.width - 24,
            maxY: virtualBounds.maxY,
            newInkBounds: .zero,
            detectedLines: [],
            needsNewPage: false
        )

        if settings.replyStyle == "font" {
            let bottom = writeTypedReply(text, placement: placement)
            lastReplyBottom = bottom
            ensureRoom(below: bottom + lineGap * 2)
            scrollToReveal(placement.origin.y)
            return
        }

        PersonalFontStore.shared.clearVAECache()
        InkUnity.shared.beginSentence()
        StyleRL.shared.beginEpisode(explore: true)

        let sequence = StrokeFont.layoutSequence(text: text,
                                                 origin: placement.origin,
                                                 xHeight: placement.xHeight,
                                                 maxX: placement.maxX,
                                                 lineGap: lineGap,
                                                 maxY: placement.maxY,
                                                 messiness: messiness,
                                                 useUserHand: true,
                                                 settings: settings)
        if sequence.clipped {
            InkUnity.shared.endSentence()
            addPage()
            onStatus?("Added a page — send again.")
            return
        }
        if settings.diagnostics, sequence.confidence < 0.55 {
            onStatus?("This reply uses low-confidence fallback glyphs. Train its words for a closer match.")
        }
        let strokes = sequence.strokes
        let bottomY = sequence.bottomY

        let letters = text.filter { $0.isLetter || $0.isNumber }.count
        StyleRL.shared.endEpisode(strokes: strokes,
                                  xHeight: placement.xHeight,
                                  letterCount: max(1, letters))
        InkUnity.shared.endSentence()

        guard !strokes.isEmpty else { return }
        ensureRoom(below: bottomY + lineGap * 2)
        scrollToReveal(placement.origin.y)

        let baseWidth = max(1.2, placement.xHeight * 0.11 * CGFloat(settings.penWidthScale))
        let bakeColor = bakedInkColor
        onWritingStateChange?(true)
        pendingBake = (strokes, baseWidth, bottomY, bakeColor)
        bakedUpTo = 0

        let preRoll = showDetection ? 0.45 : 0.10
        DispatchQueue.main.asyncAfter(deadline: .now() + preRoll) { [weak self] in
            guard let self else { return }
            self.renderer.inkColor = bakeColor
            self.renderer.write(strokes, baseWidth: baseWidth, onStrokeFinished: { [weak self] i in
                // Each finished stroke becomes real canvas ink immediately.
                guard let self, let pending = self.pendingBake,
                      i < pending.strokes.count else { return }
                self.bakeStroke(pending.strokes[i], baseWidth: pending.baseWidth,
                                color: pending.color)
                self.bakedUpTo = i + 1
            }) { [weak self] in
                guard let self else { return }
                self.pendingBake = nil
                self.bakedUpTo = 0
                self.lastReplyBottom = bottomY
                self.onWritingStateChange?(false)
                self.publishUndoRedo()
            }
        }
    }

    /// Trigger rules, per mode:
    /// - On-device calculator: "=" when Penpal is off, or Penpal + Companion.
    ///   Penpal + Mathematician never uses it — "=" goes to the brain/LLM.
    /// - Boxing: only Penpal + Mathematician.
    /// - Penpal + Companion: replies after the writing pause (as before).
    /// `auto` is true when the idle timer fired; false for an explicit
    /// "reply now" request from the user.
    func replyNow(auto: Bool = false) {
        idleTimer?.invalidate()
        guard !renderer.isWriting else { return }

        let all = canvas.drawing.strokes
        guard all.count > lastReplyStrokeCount else { return }
        let newStart = lastReplyStrokeCount
        let newStrokes = Array(all[newStart...])
        lastReplyStrokeCount = all.count

        let mathematicianMode = penpalEnabled && settings.capability == "mathematician"

        // Boxed problem: Penpal + Mathematician only.
        if mathematicianMode,
           let box = InkAnalyzer.detectProblemBox(all: all, newStart: newStart) {
            solveBoxedProblem(box, all: all)
            return
        }

        // Offer one extra virtual page to the placer — pages are infinite,
        // so "page full" just means "grow".
        let virtualBounds = CGRect(x: 0, y: 0,
                                   width: bounds.width,
                                   height: contentHeight + max(400, bounds.height))
        // Size comes from the ruled lines (or manual setting) — never from
        // measuring the user's ink, which made reply size wander.
        guard let placement = InkAnalyzer.placement(newStrokes: newStrokes,
                                                    previousBottom: lastReplyBottom,
                                                    pageBounds: virtualBounds,
                                                    leftMargin: leftMargin,
                                                    lineGap: lineGap,
                                                    rulesTopInset: rulesTopInset,
                                                    occupiedStrokes: all,
                                                    preferredXHeight: lineRelativeXHeight) else {
            // Only nag when the user explicitly asked for a reply.
            if !auto { onStatus?("Write a little more before asking for a reply.") }
            return
        }

        if showDetection, penpalEnabled {
            renderer.flashDetection(bounds: placement.newInkBounds,
                                    lines: placement.detectedLines,
                                    baseline: placement.origin)
        }

        // Read the ink, then route. Highlight animation only for math with
        // "=" (or a boxed problem) — never for ordinary companion pauses.
        let inkToRead = newStrokes
        let traits = traitCollection

        Task { @MainActor in
            var analyzing = false
            // When a Solve chip is up we keep the analyze magic (living =,
            // filaments) until the chip dismisses or solves.
            var releaseAnalyzing = true
            defer {
                if analyzing && releaseAnalyzing {
                    self.renderer.endAnalyzing()
                    self.setReadingBanner(false)
                }
            }

            // Cheap OCR first (no highlight yet) — we need to know if there's
            // an "=" before spending the slow structured parse / animation.
            let candidates = await InkRecognizer.recognizeCandidates(strokes: inkToRead,
                                                                     traits: traits)
            let trimmed = (candidates.first ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let hasEquals = trimmed.contains("=")
                || MathInkParser.looksLikeEqualsAsk(inkToRead)

            if hasEquals {
                self.renderer.beginAnalyzing(strokes: inkToRead)
                self.setReadingBanner(true)
                analyzing = true
            }

            // Prefer a full-line reading when "=" is only in the latest stroke.
            var fullLineText: String?
            if hasEquals {
                let lastLineRect = (InkAnalyzer.clusterLines(inkToRead)
                    .max { $0.rect.maxY < $1.rect.maxY })?.rect
                    ?? inkToRead.reduce(CGRect.null) { $0.union($1.renderBounds) }
                if !lastLineRect.isNull {
                    let bandMinY = lastLineRect.minY - max(8, lastLineRect.height * 0.6)
                    let bandMaxY = lastLineRect.maxY + max(6, lastLineRect.height * 0.4)
                    let lineMates = all.filter { s in
                        let mid = s.renderBounds.midY
                        return mid >= bandMinY && mid <= bandMaxY
                    }
                    if lineMates.count > inkToRead.count {
                        let lineCandidates = await InkRecognizer.recognizeCandidates(
                            strokes: lineMates, traits: traits)
                        fullLineText = lineCandidates.first?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if mathematicianMode {
                            self.renderer.beginAnalyzing(strokes: lineMates)
                            analyzing = true
                            self.setReadingBanner(true)
                        }
                    }
                }
            }

            // Penpal + Mathematician: "=" is for the brain only — never the
            // local Solve chip / on-device calculator (that conflicted with LLM).
            if mathematicianMode {
                var bestText = (fullLineText?.isEmpty == false ? fullLineText! : trimmed)
                if hasEquals || bestText.contains("=") {
                    bestText = Self.ensureTrailingEquals(bestText)
                    guard self.settings.useBrain else {
                        self.onStatus?("Solving this needs the brain — enable it in Settings → Behavior.")
                        return
                    }
                    self.askBrain(bestText, placement: placement,
                                  capability: "mathematician", fallbackInk: nil)
                }
                return
            }

            // Local calculator — Companion, or Penpal off. Requires "=".
            let structured = hasEquals
                ? await MathInkParser.parse(strokes: inkToRead, traits: traits)
                : nil
            let mathCandidates = Self.withTrailingEquals(
                [structured].compactMap { $0 } + candidates, force: hasEquals)

            if hasEquals, let hit = Self.calculatorHit(in: mathCandidates) {
                if self.offerCalculation(expression: hit.expression, answer: hit.answer,
                                         placement: placement, strokes: inkToRead) {
                    releaseAnalyzing = false
                }
                return
            }

            if hasEquals, let full = fullLineText, !full.isEmpty {
                let lineCandidates = [full]
                let lineMath = Self.withTrailingEquals(lineCandidates, force: true)
                if let hit = Self.calculatorHit(in: lineMath) {
                    if self.offerCalculation(expression: hit.expression, answer: hit.answer,
                                             placement: placement, strokes: inkToRead) {
                        releaseAnalyzing = false
                    }
                    return
                }
            }

            if hasEquals {
                if let expr = Self.bestEqualsExpression(in: mathCandidates)
                    ?? (trimmed.isEmpty ? nil : Self.ensureTrailingEquals(trimmed)) {
                    if self.offerCalculation(expression: expr, answer: nil,
                                             placement: placement, strokes: inkToRead) {
                        releaseAnalyzing = false
                    }
                    return
                }
                if self.offerCalculation(expression: "=", answer: nil,
                                         placement: placement, strokes: inkToRead) {
                    releaseAnalyzing = false
                }
                return
            }

            // Companion (and other non-mathematician Penpal) below.
            guard self.penpalEnabled else { return }

            var bestText = (fullLineText?.isEmpty == false ? fullLineText! : trimmed)

            if bestText.hasSuffix("="), self.looksLikeMath(bestText),
               self.settings.useBrain {
                self.askBrain(bestText, placement: placement,
                              capability: "mathematician", fallbackInk: nil)
                return
            }

            guard !auto || self.settings.autoReply else { return }

            guard !trimmed.isEmpty else {
                self.renderLocalReply(placement: placement, newStrokes: inkToRead)
                return
            }
            guard self.settings.useBrain else {
                self.renderLocalReply(placement: placement, newStrokes: inkToRead)
                return
            }
            self.askBrain(trimmed, placement: placement,
                          capability: self.settings.capability, fallbackInk: inkToRead)
        }
    }

    /// OCR often drops the trailing "=". When geometry already saw one, put it back.
    private static func ensureTrailingEquals(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "=" }
        return t.hasSuffix("=") ? t : t + "="
    }

    private static func withTrailingEquals(_ candidates: [String], force: Bool) -> [String] {
        guard force else { return candidates }
        var seen = Set<String>()
        var out: [String] = []
        for c in candidates {
            let e = ensureTrailingEquals(c)
            guard !e.isEmpty, seen.insert(e).inserted else { continue }
            out.append(e)
        }
        return out
    }

    /// Prefer a candidate that looks like a real expression (not bare "=").
    private static func bestEqualsExpression(in candidates: [String]) -> String? {
        let usable = candidates
            .map { ensureTrailingEquals($0) }
            .filter { $0 != "=" && $0.count > 1 }
        return usable.first
    }

    /// Tries the calculator against every reading. The FIRST candidate is
    /// privileged — that's the structured stroke-geometry parse, which reads
    /// fractions and operators far more reliably than sentence OCR. The rest
    /// are tried most-math-looking first ("2^10" beats "210"), so one bad
    /// reading doesn't sink a solvable expression — or worse, silently
    /// compute the wrong one.
    private static func calculatorHit(in candidates: [String])
        -> (expression: String, answer: String)? {
        func mathScore(_ s: String) -> Int {
            s.reduce(0) { "^*/+-()%!".contains($1) ? $0 + 2 : ($1.isNumber ? $0 + 1 : $0) }
        }
        func attempt(_ candidate: String) -> (String, String)? {
            let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let answer = MathEvaluator.instantAnswer(for: text) else { return nil }
            return (text, answer)
        }
        if let first = candidates.first, let hit = attempt(first) { return hit }
        for candidate in candidates.dropFirst()
            .sorted(by: { mathScore($0) > mathScore($1) }) {
            if let hit = attempt(candidate) { return hit }
        }
        return nil
    }

    /// Sends recognized ink to the brain and writes the reply. `fallbackInk`
    /// non-nil means "keep the conversation alive with a local line on
    /// failure" (companion); nil means fail silently with a status (math).
    private func askBrain(_ message: String, placement: ReplyPlacement,
                          capability: String, fallbackInk: [PKStroke]?) {
        onThinkingChange?(true)
        onWritingStateChange?(true)
        onStatus?("")
        Task { @MainActor in
            let store = ConversationStore.shared
            let history = store.historyForAPI()
            do {
                let reply = try await PenpalAPI.chat(
                    message: message,
                    conversationId: store.conversationId,
                    history: history,
                    baseURL: self.settings.apiBaseURL,
                    capability: capability,
                    mood: self.settings.companionMood,
                    customMood: self.settings.customMoodText,
                    mathDetail: self.settings.mathDetail
                )
                store.append(role: "user", content: message)
                store.append(role: "assistant", content: reply)
                self.onThinkingChange?(false)
                self.onWritingStateChange?(false)
                self.renderReply(reply, placement: placement,
                                 matchStrokes: fallbackInk ?? [])
            } catch {
                self.onThinkingChange?(false)
                self.onWritingStateChange?(false)
                self.onStatus?(error.localizedDescription)
                if let ink = fallbackInk {
                    self.renderLocalReply(placement: placement, newStrokes: ink)
                }
            }
        }
    }

    // MARK: - Instant math + boxed problems

    /// Confirmation step: float a chip showing HOW the ink was parsed
    /// ("5 × 5") with a Solve button, so a misread never silently becomes a
    /// wrong answer. Tapping the expression lets the user correct it first.
    /// `answer` may be nil when we saw "=" but couldn't evaluate yet — the
    /// chip still appears so a pulse never ends in silence.
    /// Returns `true` when a chip is showing (caller should hold analyze FX).
    @discardableResult
    private func offerCalculation(expression: String,
                                  answer: String?,
                                  placement: ReplyPlacement,
                                  strokes: [PKStroke]) -> Bool {
        let query = Self.ensureTrailingEquals(expression)

        if !settings.confirmBeforeSolving, let answer {
            commitCalculation(expression: query, answer: answer,
                              placement: placement, sourceStrokes: strokes)
            return false
        }
        // Confirm off but no answer yet — try once more, else fall through
        // to the chip so the user can fix the reading.
        if !settings.confirmBeforeSolving {
            if let computed = MathEvaluator.instantAnswer(for: query) {
                commitCalculation(expression: query, answer: computed,
                                  placement: placement, sourceStrokes: strokes)
                return false
            }
        }

        dismissIntentChip()
        let body = query.hasSuffix("=") ? String(query.dropLast()) : query
        let shown = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsReview = answer == nil

        if needsReview {
            renderer.setAnalyzingUncertain(true)
        }

        let chip = MathIntentChip(expression: shown, needsReview: needsReview)
        chip.onSolve = { [weak self] edited in
            guard let self else { return }
            let learned = shown.isEmpty ? 0 : MathCorrectionTrainer.learn(
                from: strokes, original: shown, corrected: edited)
            if learned > 0 {
                let n = learned
                self.onStatus?(n == 1
                    ? "Learned 1 symbol from your correction"
                    : "Learned \(n) symbols from your correction")
            }
            let solveQuery = Self.ensureTrailingEquals(edited)
            guard let solved = MathEvaluator.instantAnswer(for: solveQuery) else {
                self.onStatus?("Couldn't solve \"\(edited)\" — check the expression.")
                return
            }
            let inline = self.inlineAnswerPlacement(answer: solved, from: placement,
                                                    sourceStrokes: strokes)
            let targetCanvas = CGPoint(x: inline.origin.x,
                                       y: inline.origin.y - inline.xHeight * 0.35)
            let target = self.canvas.convert(targetCanvas, to: self)
            self.intentChip = nil
            self.renderer.endAnalyzing()
            self.setReadingBanner(false)

            let corrected = edited.trimmingCharacters(in: .whitespacesAndNewlines) != shown
            let go = {
                chip.dismissToward(target) {
                    self.commitCalculation(expression: solveQuery, answer: solved,
                                           placement: placement, sourceStrokes: strokes)
                }
            }
            if corrected, !shown.isEmpty {
                // Wrong reading crumples away before the answer writes.
                self.renderer.crumple(strokes: strokes, completion: go)
            } else {
                go()
            }
        }
        chip.onDismiss = { [weak self] in
            self?.intentChip = nil
            self?.renderer.endAnalyzing()
            self?.setReadingBanner(false)
        }

        let inkRect = placement.detectedLines
            .max(by: { $0.rect.maxY < $1.rect.maxY })?.rect ?? placement.newInkBounds
        let anchor = canvas.convert(inkRect, to: self)
        chip.present(in: self, below: anchor, visibleRect: bounds)
        intentChip = chip
        return true
    }

    /// Banner only after a short delay — short OCR shouldn't flash chrome
    /// on top of the ink pulse.
    private func setReadingBanner(_ on: Bool) {
        readingBannerTask?.cancel()
        readingBannerTask = nil
        if on {
            readingBannerTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let self, !Task.isCancelled else { return }
                self.onReadingChange?(true)
            }
        } else {
            onReadingChange?(false)
        }
    }

    /// Same origin math as `writeInstantAnswer` — used to aim the chip dissolve.
    /// Character size + baseline come from measuring the user's question ink
    /// (symbol clusters + tip width), not the ruled-line default.
    private func inlineAnswerPlacement(answer: String,
                                       from placement: ReplyPlacement,
                                       sourceStrokes: [PKStroke] = []) -> ReplyPlacement {
        let line = placement.detectedLines
            .max(by: { $0.rect.maxY < $1.rect.maxY })?.rect
            ?? placement.newInkBounds
        let hand = InkAnalyzer.measureUserHand(
            from: sourceStrokes,
            fallbackLine: line,
            fallbackXHeight: placement.xHeight)
        var origin = CGPoint(x: hand.trailX + hand.xHeight * 0.4,
                             y: hand.baseline)
        let estimatedWidth = CGFloat(answer.count) * hand.xHeight * 0.7 + 20
        if origin.x + estimatedWidth > placement.maxX {
            // Not enough room on the line — fall back to the reply spot below,
            // still using the matched writing size.
            origin = placement.origin
        }
        var inline = placement
        inline.origin = origin
        inline.xHeight = hand.xHeight
        return inline
    }

    private func commitCalculation(expression: String, answer: String,
                                   placement: ReplyPlacement,
                                   sourceStrokes: [PKStroke] = []) {
        if penpalEnabled {
            // Keep it in history so "explain" follow-ups have context.
            let store = ConversationStore.shared
            store.append(role: "user", content: expression)
            store.append(role: "assistant", content: answer)
        }
        writeInstantAnswer(answer, placement: placement, expression: expression,
                           sourceStrokes: sourceStrokes)
    }

    func dismissIntentChip() {
        intentChip?.dismiss(animated: false, notify: false)
        intentChip = nil
    }

    /// Writes the locally computed answer right after the user's "=" — same
    /// baseline, their writing size — like Apple Notes' inline math results.
    /// Ponder → optional ghost scratch (hard "=" press) → answer, with ink
    /// dust morphing from the expression toward the result.
    private func writeInstantAnswer(_ answer: String, placement: ReplyPlacement,
                                    expression: String = "",
                                    sourceStrokes: [PKStroke] = []) {
        let inline = inlineAnswerPlacement(answer: answer, from: placement,
                                           sourceStrokes: sourceStrokes)
        let line = placement.detectedLines
            .max(by: { $0.rect.maxY < $1.rect.maxY })?.rect
            ?? placement.newInkBounds

        let thinkTime = min(1.3, 0.55 + Double(expression.count) * 0.03)
        let dotSpot = CGPoint(x: inline.origin.x + inline.xHeight * 0.3,
                              y: inline.origin.y - inline.xHeight * 0.4)

        // Hard press on "=" (or thick stroke) → show ghost scratch work.
        let intensity = sourceStrokes.isEmpty
            ? 0
            : MathInkParser.equalsAskIntensity(in: sourceStrokes)
        let showWork = intensity >= 0.48
        let ghostLines = showWork
            ? MathGhostWork.steps(for: expression, answer: answer)
            : []

        if !sourceStrokes.isEmpty {
            renderer.morphToward(dotSpot, from: sourceStrokes, duration: thinkTime * 0.9)
        }

        renderer.ponder(at: dotSpot, xHeight: placement.xHeight,
                        duration: thinkTime,
                        highlighting: line) { [weak self] in
            guard let self else { return }
            // Morph dust has landed — clear before ghost / answer ink.
            self.renderer.cancelCelebrate()
            let finish = {
                self.renderReply(answer, placement: inline, celebrate: true,
                                 matchStrokes: sourceStrokes)
            }
            guard !ghostLines.isEmpty else {
                finish()
                return
            }
            // Ghost steps sit just above the answer baseline.
            let ghostOrigin = CGPoint(x: inline.origin.x,
                                      y: inline.origin.y - inline.xHeight * 1.35)
            var stepStrokeGroups: [[InkStroke]] = []
            for lineText in ghostLines {
                let seq = StrokeFont.layoutSequence(
                    text: lineText,
                    origin: ghostOrigin,
                    xHeight: inline.xHeight * 0.85,
                    maxX: placement.maxX,
                    lineGap: self.lineGap,
                    maxY: placement.maxY,
                    messiness: self.messiness * 0.6,
                    useUserHand: true,
                    settings: self.settings)
                if !seq.strokes.isEmpty { stepStrokeGroups.append(seq.strokes) }
            }
            let baseWidth = max(1.0, inline.xHeight * 0.09 * CGFloat(self.settings.penWidthScale))
            self.renderer.playGhostSteps(stepStrokeGroups, baseWidth: baseWidth,
                                         hold: 0.4, completion: finish)
        }
    }

    /// Heuristic: does recognized text look like a math problem?
    private func looksLikeMath(_ text: String) -> Bool {
        if text.contains(where: { "0123456789=+−-×*/÷^√".contains($0) }) { return true }
        let mathWords = ["solve", "integr", "deriv", "equation", "simplif",
                        "factor", "fraction", "percent", "angle", "area", "volume"]
        let lower = text.lowercased()
        return mathWords.contains { lower.contains($0) }
    }

    /// The selection pipeline: the boxed region IS the question. The ink
    /// inside the box is rendered to an image and sent DIRECTLY to the
    /// model — no OCR, no transcription. The model sees stacked fractions,
    /// exponents, roots and matrices exactly as drawn, states its reading
    /// ("Reading as: ..."), solves, and the answer is written below the box.
    private func solveBoxedProblem(_ box: InkAnalyzer.ProblemBox, all: [PKStroke]) {
        let enclosed = box.enclosedIndices.map { all[$0] }
        let boxStrokes = box.boxStrokeIndices.map { all[$0] }
        let boxStroke = all[box.boxStrokeIndex]

        // Pulse the ink inside the box, and trace the box itself so the
        // user sees the gesture landed before anything else happens.
        renderer.beginAnalyzing(strokes: enclosed)
        boxStrokes.forEach { renderer.traceBox($0) }
        setReadingBanner(true)

        guard settings.useBrain else {
            renderer.endAnalyzing()
            setReadingBanner(false)
            onStatus?("Boxed problems need the brain — enable it in Settings → Behavior.")
            return
        }
        // The picture is a CROP of the boxed region — every stroke visible
        // inside the loop is in it (minus the loop itself), so nothing the
        // user boxed can go missing from the problem.
        let boxSet = Set(box.boxStrokeIndices)
        let content = all.indices.filter { !boxSet.contains($0) }.map { all[$0] }
        let region = box.rect.insetBy(dx: -10, dy: -10)
        guard !enclosed.isEmpty,
              let png = Self.renderInkImage(strokes: content, region: region) else {
            renderer.endAnalyzing()
            setReadingBanner(false)
            onStatus?("Nothing readable inside the box — write the problem, then box it.")
            return
        }
        onThinkingChange?(true)
        onWritingStateChange?(true)
        onStatus?("")

        Task { @MainActor in
            defer {
                self.renderer.endAnalyzing()
                self.setReadingBanner(false)
            }
            let store = ConversationStore.shared
            let history = store.historyForAPI()
            do {
                let reply = try await PenpalAPI.solveMathImage(
                    pngData: png,
                    history: history,
                    baseURL: self.settings.apiBaseURL,
                    mathDetail: self.settings.mathDetail
                )
                // The reply opens with "Reading as: ..." — that line carries
                // the problem into conversation history for follow-ups.
                store.append(role: "user", content: "(boxed handwritten problem, sent as image)")
                store.append(role: "assistant", content: reply)
                self.onThinkingChange?(false)
                self.onWritingStateChange?(false)
                // The box was an instruction, not content — dissolve it as
                // the answer starts writing, leaving only real work on the page.
                self.dissolveBoxStrokes(boxStrokes)
                self.writeBoxedReply(reply, boxStroke: boxStroke,
                                     boxRect: box.rect, all: all,
                                     matchStrokes: enclosed)
            } catch {
                self.onThinkingChange?(false)
                self.onWritingStateChange?(false)
                self.onStatus?(error.localizedDescription)
            }
        }
    }

    /// Renders strokes to a white-background PNG the vision model can read.
    /// Forces light appearance so dark-mode ink doesn't come out white-on-white.
    /// `region`: crop to this rect (the inside of the user's loop) instead of
    /// the strokes' own bounds — everything visible there makes the picture,
    /// including strokes that only pass through.
    static func renderInkImage(strokes: [PKStroke], region: CGRect? = nil) -> Data? {
        let drawing = PKDrawing(strokes: strokes)
        var rect = region ?? drawing.bounds.insetBy(dx: -16, dy: -16)
        guard !rect.isNull, rect.width > 4, rect.height > 4 else { return nil }
        // Cap the long side so the upload stays under the API limit, but keep
        // enough pixels that a half-page or full-page problem stays legible —
        // handwriting PNGs compress well, so 2560px is still a small file.
        let maxSide: CGFloat = 2560
        let scale = min(2, maxSide / max(rect.width, rect.height))
        rect = rect.integral

        var inkImage = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            inkImage = drawing.image(from: rect, scale: scale)
        }
        guard inkImage.size.width > 0, inkImage.size.height > 0 else { return nil }

        // Flatten onto white at full pixel resolution (rect points × scale).
        let pixelSize = CGSize(width: rect.width * scale, height: rect.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        let flattened = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: pixelSize))
            inkImage.draw(in: CGRect(origin: .zero, size: pixelSize))
        }
        return flattened.pngData()
    }

    /// Removes the box gesture stroke(s) from the canvas while the renderer
    /// fades ghosts of them — the gesture served its purpose; the page keeps
    /// only actual work. Handles boxes drawn as one loop or several segments.
    private func dissolveBoxStrokes(_ boxStrokes: [PKStroke]) {
        var strokes = canvas.drawing.strokes
        var removedAny = false
        for boxStroke in boxStrokes {
            guard let idx = strokes.firstIndex(where: {
                $0.renderBounds == boxStroke.renderBounds
            }) else { continue }
            let removed = strokes.remove(at: idx)
            renderer.dissolveStrokeGhost(removed)
            removedAny = true
        }
        guard removedAny else { return }
        suppressChanges = true
        canvas.drawing = PKDrawing(strokes: strokes)
        suppressChanges = false
        lastReplyStrokeCount = min(lastReplyStrokeCount, strokes.count)
        onDrawingChange?(canvas.drawing)
        publishUndoRedo()
    }

    /// Places a reply directly below the boxed problem, aligned to the box.
    private func writeBoxedReply(_ text: String, boxStroke: PKStroke,
                                 boxRect: CGRect, all: [PKStroke],
                                 matchStrokes: [PKStroke] = []) {
        let virtualBounds = CGRect(x: 0, y: 0,
                                   width: bounds.width,
                                   height: contentHeight + max(400, bounds.height))
        guard let placement = InkAnalyzer.placement(
            newStrokes: [boxStroke],
            previousBottom: max(lastReplyBottom, boxRect.maxY),
            pageBounds: virtualBounds,
            leftMargin: leftMargin,
            lineGap: lineGap,
            rulesTopInset: rulesTopInset,
            occupiedStrokes: all,
            preferredXHeight: lineRelativeXHeight) else { return }
        // Celebrate: the soft ink wash under the finished answer — the same
        // "newly inked" beat instant math gets.
        renderReply(text, placement: placement, celebrate: true,
                    matchStrokes: matchStrokes)
    }

    // MARK: - Reply rendering (shared by pencil + local paths)

    /// Picks a local canned line for the new ink and renders it.
    private func renderLocalReply(placement: ReplyPlacement, newStrokes: [PKStroke]) {
        guard case .text(let text) = provider.reply(toNewInk: newStrokes) else { return }
        renderReply(text, placement: placement, matchStrokes: newStrokes)
    }

    /// Writes `text` at `placement`, either as typeset font or drawn in the
    /// user's trained hand, then advances the reply baseline.
    /// `celebrate` adds a soft wash under the finished ink (instant math).
    /// `matchStrokes` — when set, answer width/color track the user's ink so
    /// the bake into PencilKit doesn't look thinner/fainter than what they wrote.
    private func renderReply(_ text: String, placement: ReplyPlacement,
                             celebrate: Bool = false,
                             matchStrokes: [PKStroke] = []) {
        let matched = Self.sampleUserInk(from: matchStrokes)
        let formulaWidth = max(1.2, placement.xHeight * 0.11 * CGFloat(settings.penWidthScale))
        // Tip tracks their Pencil width (slightly lighter); glyph height comes
        // from `placement.xHeight`, which instant math sets from their symbols.
        let baseWidth = matched.map { max(formulaWidth * 0.85, $0.width * 1.05) }
            ?? (formulaWidth * 0.9)
        let bakeColor = matched?.color ?? bakedInkColor

        // Typed-font replies bypass the stroke pipeline entirely.
        if settings.replyStyle == "font" {
            let bottom = writeTypedReply(text, placement: placement, color: bakeColor)
            lastReplyBottom = bottom
            ensureRoom(below: bottom + lineGap * 2)
            scrollToReveal(placement.origin.y)
            if celebrate {
                let w = CGFloat(text.count) * placement.xHeight * 0.55 + 8
                let rect = CGRect(x: placement.origin.x,
                                  y: placement.origin.y - placement.xHeight * 1.1,
                                  width: w, height: placement.xHeight * 1.35)
                renderer.celebrateAnswer(in: rect)
            }
            return
        }

        PersonalFontStore.shared.clearVAECache()
        InkUnity.shared.beginSentence()
        StyleRL.shared.beginEpisode(explore: true)

        let sequence = StrokeFont.layoutSequence(text: text,
                                                 origin: placement.origin,
                                                 xHeight: placement.xHeight,
                                                 maxX: placement.maxX,
                                                 lineGap: lineGap,
                                                 maxY: placement.maxY,
                                                 messiness: messiness,
                                                 useUserHand: true,
                                                 settings: settings)
        if sequence.clipped {
            InkUnity.shared.endSentence()
            addPage()
            onStatus?("Added a page — write again.")
            return
        }
        if settings.diagnostics, sequence.confidence < 0.55 {
            onStatus?("This reply uses low-confidence fallback glyphs. Train its words for a closer match.")
        }
        // Stamp constant tip width so the animation uses the opaque filled
        // outline path (same visual weight as real Pencil ink), not a thin stroke.
        let strokes: [InkStroke] = sequence.strokes.map { s in
            var copy = s
            if copy.isDot {
                copy.dotRadius = max(copy.dotRadius, baseWidth * 0.45)
            } else if copy.points.count > 1 {
                copy.widths = Array(repeating: baseWidth, count: copy.points.count)
            }
            return copy
        }
        let bottomY = sequence.bottomY

        let letters = text.filter { $0.isLetter || $0.isNumber }.count
        StyleRL.shared.endEpisode(strokes: strokes,
                                  xHeight: placement.xHeight,
                                  letterCount: max(1, letters))
        InkUnity.shared.endSentence()

        guard !strokes.isEmpty else { return }
        ensureRoom(below: bottomY + lineGap * 2)
        scrollToReveal(placement.origin.y)

        onWritingStateChange?(true)
        pendingBake = (strokes, baseWidth, bottomY, bakeColor)
        bakedUpTo = 0

        let celebrateRect: CGRect = {
            let union = strokes.reduce(CGRect.null) { partial, s in
                let pts = s.points
                guard let first = pts.first else { return partial }
                var r = CGRect(origin: first, size: .zero)
                for p in pts.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
                return partial.union(r.insetBy(dx: -2, dy: -placement.xHeight * 0.15))
            }
            return union.isNull
                ? CGRect(x: placement.origin.x,
                         y: placement.origin.y - placement.xHeight,
                         width: CGFloat(text.count) * placement.xHeight * 0.55,
                         height: placement.xHeight * 1.3)
                : union
        }()

        let preRoll = showDetection ? 0.45 : 0.10
        DispatchQueue.main.asyncAfter(deadline: .now() + preRoll) { [weak self] in
            guard let self else { return }
            // Match animation color to bake color (and to the user's ink).
            self.renderer.inkColor = bakeColor
            // widths are already absolute tip sizes — don't re-scale by pen slider.
            let savedScale = self.renderer.widthScale
            self.renderer.widthScale = 1
            self.renderer.write(strokes, baseWidth: baseWidth, onStrokeFinished: { [weak self] i in
                guard let self, let pending = self.pendingBake,
                      i < pending.strokes.count else { return }
                self.bakeStroke(pending.strokes[i], baseWidth: pending.baseWidth,
                                color: pending.color)
                self.bakedUpTo = i + 1
            }) { [weak self] in
                guard let self else { return }
                self.renderer.widthScale = savedScale
                self.pendingBake = nil
                self.bakedUpTo = 0
                self.lastReplyBottom = bottomY
                self.onWritingStateChange?(false)
                self.publishUndoRedo()
                if celebrate {
                    self.renderer.celebrateAnswer(in: celebrateRect)
                }
                if self.autoReply, self.canvas.drawing.strokes.count > self.lastReplyStrokeCount {
                    self.canvasViewDrawingDidChange(self.canvas)
                }
            }
        }
    }

    // MARK: Typed-font reply

    /// Builds a typed-reply label (shared by live writing and note restore).
    private func makeTypedLabel(text: String, origin: CGPoint, xHeight: CGFloat,
                                maxX: CGFloat, color: UIColor) -> UILabel {
        let base = UIFont(name: settings.replyFontName, size: 100)
            ?? UIFont.italicSystemFont(ofSize: 100)
        // Match the font's x-height to the detected writing size.
        let unit = max(10, base.xHeight)
        let fontSize = min(96, max(9, 100 * xHeight / unit))
        let font = base.withSize(fontSize)

        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineGap
        paragraph.maximumLineHeight = lineGap

        let label = UILabel()
        label.numberOfLines = 0
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: font,
            .paragraphStyle: paragraph,
            .foregroundColor: color,
        ])

        let width = max(80, maxX - origin.x)
        let measured = label.sizeThatFits(CGSize(width: width,
                                                 height: .greatestFiniteMagnitude))
        // With a fixed line height L, each baseline sits at the fragment
        // bottom minus the descender: first baseline = L - |descender|.
        let top = origin.y - (lineGap - abs(font.descender))
        label.frame = CGRect(x: origin.x, y: top,
                             width: width, height: ceil(measured.height))
        return label
    }

    /// Typesets the reply in the chosen font, first baseline on the reply
    /// line, wrapped to the page, and fades it in. Records it so it persists
    /// with the note. Returns the bottom y.
    private func writeTypedReply(_ text: String, placement: ReplyPlacement,
                                 color: UIColor? = nil,
                                 announceWriting: Bool = true,
                                 isUser: Bool = false) -> CGFloat {
        let label = makeTypedLabel(text: text,
                                   origin: placement.origin,
                                   xHeight: placement.xHeight,
                                   maxX: placement.maxX,
                                   color: color ?? settings.inkColor)
        label.alpha = 0
        label.transform = CGAffineTransform(translationX: 0, y: 4)
        canvas.addSubview(label)
        typedLabels.append(label)

        placedTexts.append(TypedNoteText(text: text,
                                         x: placement.origin.x,
                                         y: placement.origin.y,
                                         xHeight: placement.xHeight,
                                         maxX: placement.maxX,
                                         isUserMessage: isUser))
        onTypedTextsChange?(placedTexts)

        if announceWriting { onWritingStateChange?(true) }
        UIView.animate(withDuration: 0.7, delay: 0.1, options: [.curveEaseOut]) {
            label.alpha = 1
            label.transform = .identity
        } completion: { [weak self] _ in
            if announceWriting { self?.onWritingStateChange?(false) }
        }

        return label.frame.maxY
    }

}
