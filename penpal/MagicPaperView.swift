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

final class MagicPaperView: UIView, PKCanvasViewDelegate, UIEditMenuInteractionDelegate {

    // MARK: Tunables (set from SwiftUI)

    var settings: HandwritingSettings = .shared { didSet { applySettings() } }
    /// When false, ink is normal Notes drawing — no OCR / brain / reply.
    var penpalEnabled: Bool = false
    var autoReply: Bool { settings.autoReply && penpalEnabled }
    var showDetection: Bool { settings.diagnostics }
    var messiness: CGFloat { CGFloat(settings.variation / 10) }

    var onWritingStateChange: ((Bool) -> Void)?
    var onThinkingChange: ((Bool) -> Void)?
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
    private var pendingBake: (strokes: [InkStroke], baseWidth: CGFloat, bottomY: CGFloat)?

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
        renderer.inkColor = settings.inkColor
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
        return picker
    }()

    override var canBecomeFirstResponder: Bool { true }

    /// Shows / hides the system PKToolPicker floating palette, exactly like Notes.
    func setToolsVisible(_ visible: Bool) {
        toolPicker.setVisible(visible, forFirstResponder: canvas)
        if visible {
            canvas.becomeFirstResponder()
        } else {
            canvas.resignFirstResponder()
        }
    }

    var isToolPickerVisible: Bool { toolPicker.isVisible }

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
    private func bakeStroke(_ raw: InkStroke, baseWidth: CGFloat) {
        let smoothed = HandwritingRenderer.smoothed(raw, amount: CGFloat(settings.smoothness))
        guard let pk = Self.pkStroke(from: smoothed, baseWidth: baseWidth, color: bakedInkColor) else { return }
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
                bakeStroke(stroke, baseWidth: pending.baseWidth)
            }
        }
        bakedUpTo = 0
        lastReplyBottom = max(lastReplyBottom, pending.bottomY)
        onWritingStateChange?(false)
        publishUndoRedo()
    }

    /// Converts a reply stroke into a PencilKit stroke. Width gets a small
    /// boost + floor because PencilKit's pen ink reads slightly thinner than
    /// the animation layer at equal nominal width (tune `boost`/`minWidth`
    /// if the handoff is ever visible).
    private static func pkStroke(from stroke: InkStroke,
                                 baseWidth: CGFloat,
                                 color: UIColor) -> PKStroke? {
        let boost: CGFloat = 1.25
        let minWidth: CGFloat = 1.8

        func point(_ location: CGPoint, _ time: TimeInterval, _ width: CGFloat) -> PKStrokePoint {
            PKStrokePoint(location: location,
                          timeOffset: time,
                          size: CGSize(width: width, height: width),
                          opacity: 1,
                          force: 1,
                          azimuth: 0,
                          altitude: .pi / 2)
        }

        if stroke.isDot, let c = stroke.points.first {
            let w = max(minWidth, max(baseWidth * boost, stroke.dotRadius * 2))
            let path = PKStrokePath(controlPoints: [point(c, 0, w), point(c, 0.01, w)],
                                    creationDate: Date())
            return PKStroke(ink: PKInk(.pen, color: color), path: path)
        }
        guard stroke.points.count > 1 else { return nil }

        let hasWidths = stroke.widths?.count == stroke.points.count
        let hasTimes = stroke.pointTimes?.count == stroke.points.count
        var controls: [PKStrokePoint] = []
        controls.reserveCapacity(stroke.points.count)
        var lastTime = -1.0
        for (i, p) in stroke.points.enumerated() {
            let w = max(minWidth, (hasWidths ? stroke.widths![i] : baseWidth) * boost)
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
        // Writing near the bottom edge? Grow the paper quietly.
        if let last = canvasView.drawing.strokes.last {
            ensureRoom(below: last.renderBounds.maxY + lineGap * 2)
        }
        onDrawingChange?(canvasView.drawing)
        publishUndoRedo()
        idleTimer?.invalidate()
        // Penpal replies only when the special Penpal pen is active.
        guard autoReply else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.replyNow() }
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
                    baseURL: settings.apiBaseURL
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
        onWritingStateChange?(true)
        pendingBake = (strokes, baseWidth, bottomY)
        bakedUpTo = 0

        let preRoll = showDetection ? 0.45 : 0.10
        DispatchQueue.main.asyncAfter(deadline: .now() + preRoll) { [weak self] in
            guard let self else { return }
            self.renderer.write(strokes, baseWidth: baseWidth, onStrokeFinished: { [weak self] i in
                // Each finished stroke becomes real canvas ink immediately.
                guard let self, let pending = self.pendingBake,
                      i < pending.strokes.count else { return }
                self.bakeStroke(pending.strokes[i], baseWidth: pending.baseWidth)
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

    func replyNow() {
        idleTimer?.invalidate()
        guard !renderer.isWriting else { return }

        let all = canvas.drawing.strokes
        guard all.count > lastReplyStrokeCount else { return }
        let newStrokes = Array(all[lastReplyStrokeCount...])
        lastReplyStrokeCount = all.count

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
            onStatus?("Write a little more before asking for a reply.")
            return
        }

        if showDetection {
            renderer.flashDetection(bounds: placement.newInkBounds,
                                    lines: placement.detectedLines,
                                    baseline: placement.origin)
        }

        // With the brain on, read the handwriting and let Gemini answer it —
        // exactly like the typed bar, but the "message" is your own ink.
        if settings.useBrain {
            onThinkingChange?(true)
            onWritingStateChange?(true)
            onStatus?("")
            let inkToRead = newStrokes
            let traits = traitCollection
            Task { @MainActor in
                let heard = await InkRecognizer.recognize(strokes: inkToRead, traits: traits)
                let trimmed = heard.trimmingCharacters(in: .whitespacesAndNewlines)

                guard !trimmed.isEmpty else {
                    // Couldn't read the ink — answer with a friendly local line
                    // so the page never goes silent.
                    self.onThinkingChange?(false)
                    self.onWritingStateChange?(false)
                    self.renderLocalReply(placement: placement, newStrokes: inkToRead)
                    return
                }

                let store = ConversationStore.shared
                let history = store.historyForAPI()
                do {
                    let reply = try await PenpalAPI.chat(
                        message: trimmed,
                        conversationId: store.conversationId,
                        history: history,
                        baseURL: self.settings.apiBaseURL
                    )
                    store.append(role: "user", content: trimmed)
                    store.append(role: "assistant", content: reply)
                    self.onThinkingChange?(false)
                    self.onWritingStateChange?(false)
                    self.renderReply(reply, placement: placement)
                } catch {
                    self.onThinkingChange?(false)
                    self.onWritingStateChange?(false)
                    self.onStatus?(error.localizedDescription)
                    // Keep the conversation flowing with a local line on failure.
                    self.renderLocalReply(placement: placement, newStrokes: inkToRead)
                }
            }
            return
        }

        // Brain off: reply with a local canned line.
        renderLocalReply(placement: placement, newStrokes: newStrokes)
    }

    // MARK: - Reply rendering (shared by pencil + local paths)

    /// Picks a local canned line for the new ink and renders it.
    private func renderLocalReply(placement: ReplyPlacement, newStrokes: [PKStroke]) {
        guard case .text(let text) = provider.reply(toNewInk: newStrokes) else { return }
        renderReply(text, placement: placement)
    }

    /// Writes `text` at `placement`, either as typeset font or drawn in the
    /// user's trained hand, then advances the reply baseline.
    private func renderReply(_ text: String, placement: ReplyPlacement) {
        // Typed-font replies bypass the stroke pipeline entirely.
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
            onStatus?("Added a page — write again.")
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
        onWritingStateChange?(true)
        pendingBake = (strokes, baseWidth, bottomY)
        bakedUpTo = 0

        let preRoll = showDetection ? 0.45 : 0.10
        DispatchQueue.main.asyncAfter(deadline: .now() + preRoll) { [weak self] in
            guard let self else { return }
            self.renderer.write(strokes, baseWidth: baseWidth, onStrokeFinished: { [weak self] i in
                // Each finished stroke becomes real canvas ink immediately.
                guard let self, let pending = self.pendingBake,
                      i < pending.strokes.count else { return }
                self.bakeStroke(pending.strokes[i], baseWidth: pending.baseWidth)
                self.bakedUpTo = i + 1
            }) { [weak self] in
                guard let self else { return }
                self.pendingBake = nil
                self.bakedUpTo = 0
                self.lastReplyBottom = bottomY
                self.onWritingStateChange?(false)
                self.publishUndoRedo()
                // If the user kept writing while we replied, answer that too.
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
