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

final class MagicPaperView: UIView, PKCanvasViewDelegate, UIEditMenuInteractionDelegate, PKToolPickerObserver, UIGestureRecognizerDelegate {

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
    /// Fired whenever the embedded code blocks change (added/moved/resized/
    /// edited/deleted), so the store can persist them with the note.
    var onCodeBlocksChange: (([CodeBlock]) -> Void)?
    /// Fired when a code block asks to edit its source — SwiftUI presents the
    /// editor sheet and calls back into `updateCodeBlock(_:)`.
    var onRequestEditCodeBlock: ((CodeBlock) -> Void)?
    /// Fired whenever Arrange (page edit) mode turns on/off from inside the
    /// canvas — e.g. a long-press on a block — so the toolbar button stays in
    /// sync with the actual state.
    var onPageEditModeChange: ((Bool) -> Void)?
    /// PEN-19 — set while a practice problem is on the page. Receives whether
    /// the student's working was correct, so the schedule can be updated.
    var onWorkMarked: ((Bool) -> Void)?

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

    private let canvas = BlockRoutingCanvasView()
    private let paper = PaperBackgroundView()
    private let renderer = HandwritingRenderer()
    private var idleTimer: Timer?
    /// The floating "5 × 5 — Solve" confirmation, when one is showing.
    private var intentChip: MathIntentChip?
    /// Delays the "Reading…" banner so short OCR doesn't flash chrome.
    private var readingBannerTask: Task<Void, Never>?
    private var lastReplyStrokeCount = 0
    private var lastReplyBottom: CGFloat = 0
    /// True while a brain request is IN FLIGHT (network await). The
    /// `renderer.isWriting` guard alone left a race: pause mid-sentence →
    /// request A departs → user writes more → idle fires again while A is
    /// still on the network → request B departs. B's write then tramples A's
    /// animation (orphaned first glyphs on the page) and B's placement
    /// aligns to just the continuation strokes (reply indented mid-page).
    private var brainBusy = false
    private var provider = HandAwareReplyProvider()
    private var typedLabels: [UILabel] = []
    /// Persisted models behind `typedLabels` (same order is not required).
    private var placedTexts: [TypedNoteText] = []
    /// Persisted AI replies already on this page (renderer strokes).
    private var placedInks: [ReplyInk] = []
    /// Embedded code-block assets on this page (behind the ink). Each view
    /// carries its own `CodeBlock` model.
    private var codeBlockViews: [CodeBlockView] = []
    private var persistedBlockSnapshot: [CodeBlock] = []
    /// The one block currently raised above the ink and taking finger input.
    /// Set by tapping a block; cleared by a pencil stroke, a tap elsewhere,
    /// or entering page-edit mode.
    private weak var activeCodeBlock: CodeBlockView?
    /// The page's edit mode: when on, blocks show chrome and can be moved /
    /// resized / edited, and ink drawing is suspended so gestures reach them.
    private(set) var isPageEditMode = false
    /// A SINGLE block in Arrange mode on its own (via long-press) while the
    /// rest of the page stays live — the focused counterpart to the page-wide
    /// Arrange button. Mutually exclusive with `isPageEditMode`.
    private weak var editingBlock: CodeBlockView?
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

        // PEN-12 — anything the outbox eventually delivers still gets written
        // on the page, exactly as if it had arrived first time.
        Outbox.shared.onReply = { [weak self] _, reply in
            guard let self else { return }
            self.onStatus?("")
            self.writeReplyText(reply)
        }
        Outbox.shared.onGaveUp = { [weak self] item in
            // Be honest rather than silently dropping it — the user was told
            // we'd kept this.
            self?.onStatus?(item.kind == .solveMath
                ? "I couldn't get that boxed problem through. Try boxing it again."
                : "I couldn't send that one — it's still on the page if you'd like to retry.")
        }
        // Deliver anything left over from a previous session.
        Outbox.shared.drain(settings: settings)

        // Long-press (finger) a Penpal reply → Delete menu. Finger-only so it
        // never fights Pencil drawing.
        let press = UILongPressGestureRecognizer(target: self,
                                                 action: #selector(handleInkLongPress(_:)))
        press.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        canvas.addGestureRecognizer(press)
        let menu = UIEditMenuInteraction(delegate: self)
        canvas.addInteraction(menu)
        editMenu = menu

        // One finger tap routes ALL code-block state changes: tap a sleeping
        // block → wake it; tap outside the active block → back to sleep.
        // Living at the canvas level (not on the blocks) means sleeping
        // blocks stay entirely out of hit-testing — cheap, and the recognizer
        // sees the REAL touch type, unlike `event.allTouches` in hitTest.
        // Non-cancelling and simultaneous with every other gesture, so
        // scrolling and drawing are unaffected.
        let blockTap = UITapGestureRecognizer(target: self,
                                              action: #selector(handleCanvasTap(_:)))
        blockTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        blockTap.cancelsTouchesInView = false
        blockTap.delegate = self
        canvas.addGestureRecognizer(blockTap)

        // The instant the Pencil touches down anywhere, the active block goes
        // back to sleep below the ink — "the pen wins". Zero-duration press,
        // pencil-only, purely an observer.
        let pencilDown = UILongPressGestureRecognizer(target: self,
                                                      action: #selector(handlePencilDown(_:)))
        pencilDown.minimumPressDuration = 0
        pencilDown.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        pencilDown.cancelsTouchesInView = false
        pencilDown.delaysTouchesBegan = false
        pencilDown.delaysTouchesEnded = false
        pencilDown.delegate = self
        canvas.addGestureRecognizer(pencilDown)

        // Keep the undo/redo buttons in sync with the canvas's undo stack.
        for name in [NSNotification.Name.NSUndoManagerDidUndoChange,
                     .NSUndoManagerDidRedoChange,
                     .NSUndoManagerDidCloseUndoGroup] {
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(undoStateChanged),
                                                   name: name, object: nil)
        }

        // PEN-22 — Apple Pencil hover. Shows where a reply will land before
        // the pen touches down, which removes a whole class of surprise about
        // ink appearing somewhere unexpected.
        let hover = UIHoverGestureRecognizer(target: self,
                                             action: #selector(handleHover(_:)))
        canvas.addGestureRecognizer(hover)

        applySettings()
        // Load math.js in the background so the first "=" answers instantly.
        MathEngine.shared.warmUp()
    }

    // MARK: - Pencil hover (PEN-22)

    /// Hovering near the end of written work previews the reply baseline.
    ///
    /// Deliberately quiet: a faint guide line, only in Penpal mode, only when
    /// there is ink to answer, and never while Penpal is already writing.
    /// Hover is ambient — anything louder would turn "resting your hand" into
    /// a flickering distraction.
    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        // The pen is APPROACHING the active block — writing posture. Stand the
        // block down NOW, before the tip lands, so the first stroke over it
        // inks normally instead of being swallowed by the widget.
        //
        // Scoped to the block's own frame on purpose: hover fires the whole
        // time the pencil is anywhere near the glass, and merely holding the
        // pen while tapping a calculator with the other hand must not keep
        // killing the block. Only an approach over the block itself counts.
        //
        // Deliberately ahead of the penpal / isWriting guards below: this is
        // input arbitration, not a Penpal feature.
        if gesture.state == .began || gesture.state == .changed,
           let active = activeCodeBlock,
           active.frame.insetBy(dx: -24, dy: -24).contains(gesture.location(in: canvas)) {
            setActiveCodeBlock(nil)
        }

        guard penpalEnabled, !renderer.isWriting else {
            renderer.clearReplyGuide()
            return
        }
        switch gesture.state {
        case .began, .changed:
            let point = gesture.location(in: canvas)
            let all = canvas.drawing.strokes
            guard !all.isEmpty else { return }
            let content = all.reduce(CGRect.null) { $0.union($1.renderBounds) }
            // Only hint when the pen is hovering BELOW the work, where a reply
            // would actually go — not when moving across existing writing.
            guard point.y > content.maxY - lineGap,
                  point.y < content.maxY + lineGap * 4 else {
                renderer.clearReplyGuide()
                return
            }
            let baseline = rulesTopInset
                + lineGap * ceil((content.maxY + lineRelativeXHeight * 0.8
                                  - rulesTopInset) / lineGap)
            renderer.showReplyGuide(at: baseline,
                                    from: max(leftMargin, content.minX),
                                    to: bounds.width - 24)
        default:
            renderer.clearReplyGuide()
        }
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
        // Blocks are tap-activated (see setActiveCodeBlock) — their
        // interactivity no longer tracks the pencil-only setting.
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
    var currentCodeBlocks: [CodeBlock] { codeBlockViews.map(\.block) }

    var canUndo: Bool { canvas.undoManager?.canUndo ?? false }
    var canRedo: Bool { canvas.undoManager?.canRedo ?? false }

    func loadDrawing(_ drawing: PKDrawing,
                     typedTexts: [TypedNoteText] = [],
                     replyInks: [ReplyInk] = [],
                     codeBlocks: [CodeBlock] = [],
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

        // Rebuild embedded code blocks behind the ink. A note switch always
        // drops edit mode — blocks belong to the note being loaded.
        codeBlockViews.forEach { $0.removeFromSuperview() }
        codeBlockViews.removeAll()
        // Never let a stale ref to the previous note's active block survive —
        // it would keep the canvas redirecting touches into a dead block.
        activeCodeBlock = nil
        canvas.activeBlock = nil
        editingBlock = nil
        isPageEditMode = false
        canvas.drawingGestureRecognizer.isEnabled = true
        var blockBottom: CGFloat = 0
        for block in codeBlocks {
            let view = makeCodeBlockView(block)
            canvas.addSubview(view)
            codeBlockViews.append(view)
            blockBottom = max(blockBottom, block.frame.maxY)
        }
        // One pass, so saved blocks keep their stored order under the ink
        // (inserting each one directly above the paper would reverse them).
        restackCodeBlocks()
        persistedBlockSnapshot = codeBlocks

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
                            blockBottom + lineGap * 4,
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

    // MARK: - Streamed solving (PEN-28)

    /// Solves with the answer forming visibly, then inks it once checked.
    ///
    /// The draft is rendered into the SAME ghost layer the live preview uses
    /// (PEN-11), which is what makes streaming safe on paper: the user sees
    /// the working appear immediately, but nothing is committed until the
    /// referee has approved it. If the draft is rejected, the ghost is simply
    /// replaced — there is never a wrong answer inked and then crossed out.
    func solveStreaming(_ expression: String, placement: ReplyPlacement,
                        sourceStrokes: [PKStroke]) {
        guard settings.useBrain else {
            onStatus?("Solving this needs the brain — enable it in Settings → Behavior.")
            return
        }
        let store = ConversationStore.shared
        let history = store.historyForAPI()
        onThinkingChange?(true)
        onStatus?("")

        Task { @MainActor in
            var lastDraft = ""
            do {
                let stream = PenpalAPI.streamSolve(
                    message: expression, history: history,
                    baseURL: settings.apiBaseURL,
                    mathDetail: settings.mathDetail)

                for try await event in stream {
                    switch event {
                    case .draft(let text):
                        lastDraft = text
                        self.showDraftGhost(text, placement: placement,
                                            sourceStrokes: sourceStrokes)

                    case .final(let text), .corrected(let text):
                        self.renderer.clearAnswerGhost()
                        self.onThinkingChange?(false)
                        store.append(role: "user", content: expression)
                        store.append(role: "assistant", content: text)
                        self.renderReply(text, placement: placement,
                                         celebrate: true,
                                         matchStrokes: sourceStrokes)
                        return

                    case .failed(let message):
                        self.renderer.clearAnswerGhost()
                        self.onThinkingChange?(false)
                        self.onStatus?(message)
                        return
                    }
                }
                // Stream ended without a verdict — never ink an unchecked
                // draft, but don't silently lose the work either.
                self.renderer.clearAnswerGhost()
                self.onThinkingChange?(false)
                if !lastDraft.isEmpty {
                    self.onStatus?("I lost my connection partway through. Ask again and I'll redo it.")
                }
            } catch {
                self.renderer.clearAnswerGhost()
                self.onThinkingChange?(false)
                self.onStatus?(PenpalError.message(for: error))
            }
        }
    }

    /// Lays the partial solution out as ghost ink.
    private func showDraftGhost(_ text: String, placement: ReplyPlacement,
                                sourceStrokes: [PKStroke]) {
        guard !text.isEmpty else { return }
        let sequence = StrokeFont.layoutSequence(
            text: text,
            origin: placement.origin,
            xHeight: placement.xHeight,
            maxX: placement.maxX,
            lineGap: lineGap,
            maxY: placement.maxY,
            messiness: messiness * 0.5,
            useUserHand: true,
            settings: settings,
            allowSynthesis: false)
        guard !sequence.strokes.isEmpty else { return }
        let matched = Self.sampleUserInk(from: sourceStrokes)
        renderer.inkColor = matched?.color ?? bakedInkColor
        renderer.showAnswerGhost(
            sequence.strokes,
            baseWidth: matched.map { max(1.2, $0.width * 0.9) }
                ?? max(1.2, placement.xHeight * 0.1))
    }

    // MARK: - Graphing (PEN-17)

    /// Draws a graph of `body` below the user's work, in ink.
    ///
    /// Rendered through the same stroke pipeline as handwriting — same pen,
    /// same slight imprecision — because a crisp vector chart would look
    /// pasted in and break the paper illusion. Fully on-device: plotting is
    /// interactive, and a network round trip would make it feel like a
    /// document loading rather than someone sketching.
    @discardableResult
    func drawGraph(of body: String) -> Bool {
        let all = canvas.drawing.strokes
        let content = all.reduce(CGRect.null) { $0.union($1.renderBounds) }
        let top = content.isNull ? rulesTopInset + lineGap
                                 : max(lastReplyBottom, content.maxY) + lineGap
        let size = min(bounds.width - leftMargin - 40, 360)
        let frame = CGRect(x: leftMargin, y: top, width: size, height: size * 0.75)

        ensureRoom(below: frame.maxY + lineGap * 2)
        guard let plot = GraphPlotter.plot(body, in: frame) else {
            onStatus?("I couldn't plot that one — try something like \"y = x^2\".")
            return false
        }

        let baseWidth = max(1.2, lineRelativeXHeight * 0.09
                            * CGFloat(settings.penWidthScale))
        renderer.inkColor = bakedInkColor
        beginUndoableAction("Draw Graph")          // PEN-14
        onWritingStateChange?(true)
        scrollToReveal(frame.minY)

        let strokes = plot.strokes
        renderer.write(strokes, baseWidth: baseWidth, onStrokeFinished: { [weak self] i in
            guard let self, i < strokes.count else { return }
            self.bakeStroke(strokes[i], baseWidth: baseWidth, color: self.bakedInkColor)
        }) { [weak self] in
            guard let self else { return }
            self.lastReplyBottom = frame.maxY
            self.endUndoableAction()               // PEN-14
            self.onWritingStateChange?(false)
            self.publishUndoRedo()
            self.flushWritingCompletions()         // PEN-09
        }
        // PEN-32 — the curve is invisible to VoiceOver, so say what it is.
        publishForVoiceOver("Graph of y = \(body)", isAnswer: false)
        return true
    }

    // MARK: - Live answer preview (PEN-11)

    /// Shows the on-device answer ghosted just past the user's "=", before
    /// they lift or pause. Lifting commits it through the normal Solve path;
    /// writing on dismisses it.
    ///
    /// Only fires when the expression is unambiguous locally — the aim is a
    /// preview that is right or absent, never a guess flickering under the
    /// pen. A wrong preview would be worse than none: the user reads it,
    /// believes it, and moves on.
    private func previewAnswer(expression: String, placement: ReplyPlacement,
                               sourceStrokes: [PKStroke]) {
        // No `useBrain` check on purpose: the preview is computed entirely
        // on device, so it works with the brain switched off or offline.
        guard !renderer.isWriting,
              let answer = MathEvaluator.instantAnswer(for: expression),
              !answer.isEmpty else {
            renderer.clearAnswerGhost()
            return
        }

        let matched = Self.sampleUserInk(from: sourceStrokes)
        let baseWidth = matched.map { max(1.2, $0.width * 0.9) }
            ?? max(1.2, placement.xHeight * 0.1)
        let sequence = StrokeFont.layoutSequence(
            text: answer,
            origin: placement.origin,
            xHeight: placement.xHeight,
            maxX: placement.maxX,
            lineGap: lineGap,
            maxY: placement.maxY,
            messiness: messiness * 0.5,
            useUserHand: true,
            settings: settings,
            allowSynthesis: false)          // math is never synthesised
        guard !sequence.strokes.isEmpty else { return }
        renderer.inkColor = matched?.color ?? bakedInkColor
        renderer.showAnswerGhost(sequence.strokes, baseWidth: baseWidth)
    }

    /// Any new ink means the user kept writing — the preview is stale.
    private func dismissAnswerPreviewIfNeeded() {
        guard renderer.isShowingAnswerGhost else { return }
        renderer.clearAnswerGhost()
    }

    // MARK: - Layout (PEN-10)

    /// Width the reply's LONGEST line will occupy, in points.
    ///
    /// Measured with the same `StrokeFont` metrics the renderer will use, so
    /// the space the placer reserves matches the space the ink takes. A reply
    /// wraps at line breaks, so only the widest line matters — estimating from
    /// total character count would make every multi-line answer look enormous
    /// and push it needlessly down the page.
    static func estimatedWidth(of text: String, xHeight: CGFloat) -> CGFloat {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let widest = lines.reduce(CGFloat(0)) { longest, line in
            max(longest, StrokeFont.wordWidth(line, size: xHeight))
        }
        return max(xHeight * 2, widest)
    }

    // MARK: - Choreography (PEN-09)

    /// Runs `body` once the pen has finished whatever it is currently writing.
    ///
    /// Perceived intelligence lives almost entirely in pacing: the same wait
    /// reads as attentive or broken depending on what fills it. Sequencing on
    /// the renderer's real state — rather than on a guessed delay — is what
    /// keeps that pacing honest when an answer runs long.
    private func afterWriting(_ body: @escaping () -> Void) {
        guard renderer.isWriting else { body(); return }
        writingCompletionQueue.append(body)
    }

    private var writingCompletionQueue: [() -> Void] = []

    /// Drains anything waiting on the pen. Called when writing finishes.
    private func flushWritingCompletions() {
        guard !writingCompletionQueue.isEmpty else { return }
        let waiting = writingCompletionQueue
        writingCompletionQueue.removeAll()
        waiting.forEach { $0() }
    }

    // MARK: - Intent-aware undo (PEN-14)
    //
    // PencilKit undoes STROKES. That is right for the user's own drawing and
    // wrong for everything Penpal does: a written reply is fifty strokes, so
    // undoing it meant fifty taps, and programmatic edits (dissolving a box,
    // deleting struck-through ink) went onto the canvas without registering
    // at all — they simply could not be undone.
    //
    // Now every Penpal-initiated change is wrapped as ONE named action that
    // restores the exact drawing that preceded it. One undo = one thing the
    // user would describe as one thing. This is also what makes the
    // strike-through gesture safe to ship: a mis-detected delete is always a
    // single undo away.

    /// Snapshot taken when an action opens; nil when none is in progress.
    private var actionSnapshot: PKDrawing?
    private var actionName: String?

    /// Wraps a Penpal-initiated change so it undoes as a single step.
    func performUndoable(_ name: String, _ body: () -> Void) {
        beginUndoableAction(name)
        body()
        endUndoableAction()
    }

    func beginUndoableAction(_ name: String) {
        // Nested actions keep the OUTERMOST snapshot: writing a reply bakes
        // many strokes, and the user means "undo the reply", not "undo the
        // last stroke of the reply".
        guard actionSnapshot == nil else { return }
        actionSnapshot = canvas.drawing
        actionName = name
    }

    func endUndoableAction() {
        guard let before = actionSnapshot, let name = actionName else { return }
        actionSnapshot = nil
        actionName = nil
        let after = canvas.drawing
        guard before.strokes.count != after.strokes.count
                || before.bounds != after.bounds else { return }
        registerUndo(name: name, restoring: before, redoing: after)
    }

    private func registerUndo(name: String, restoring before: PKDrawing,
                              redoing after: PKDrawing) {
        guard let manager = canvas.undoManager else { return }
        manager.registerUndo(withTarget: self) { view in
            // Registering the inverse from inside the undo makes redo work
            // for free, and keeps the pair symmetric however deep the stack.
            view.applyDrawing(before)
            view.registerUndo(name: name, restoring: after, redoing: before)
        }
        manager.setActionName(name)
        publishUndoRedo()
    }

    /// Replaces the drawing without re-entering the reply pipeline.
    private func applyDrawing(_ drawing: PKDrawing) {
        suppressChanges = true
        canvas.drawing = drawing
        suppressChanges = false
        lastReplyStrokeCount = min(lastReplyStrokeCount, drawing.strokes.count)
        onDrawingChange?(drawing)
        publishUndoRedo()
    }

    /// Commits one reply stroke into the canvas drawing as a real PKStroke —
    /// erasable, lassoable, undoable, shared and saved exactly like the
    /// user's own ink. Called stroke-by-stroke as the animation finishes each
    /// one, so the pen appears to write directly onto the page.
    /// Returns false when the stroke could not be converted — the CALLER must
    /// then keep the ink visible another way (the animation layer is removed
    /// the moment this returns, so a silent false meant vanishing ink).
    @discardableResult
    private func bakeStroke(_ raw: InkStroke, baseWidth: CGFloat, color: UIColor) -> Bool {
        let smoothed = HandwritingRenderer.smoothed(raw, amount: CGFloat(settings.smoothness))
        guard let pk = Self.pkStroke(from: smoothed, baseWidth: baseWidth, color: color) else { return false }
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
        return true
    }

    /// Tip width + ink color from the user's expression (Pencil tip size along
    /// the path). Character height is measured separately via `measureUserHand`.
    private static func sampleUserInk(from strokes: [PKStroke]) -> (width: CGFloat, color: UIColor)? {
        guard !strokes.isEmpty else { return nil }
        let line = strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
        let hand = InkAnalyzer.measureUserHand(from: strokes, fallbackLine: line,
                                               fallbackXHeight: 16)
        // Match the user's pen colour — but ONLY if that colour can actually
        // be seen on paper. This samples the LAST stroke, which may be a
        // highlighter (translucent), an eraser artefact, or a near-white pen;
        // copying it wrote the reply in invisible ink. Companion replies pass
        // no match strokes at all, so they always used the settings colour —
        // which is why this only ever showed up in Mathematician mode, where
        // the user's own expression ink is the match source.
        let rawColor = strokes.last?.ink.color ?? .label
        let color = rawColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        guard Self.isLegibleOnPaper(color) else { return (hand.tipWidth, .label) }
        return (hand.tipWidth, color)
    }

    /// Whether ink of this colour would actually be visible on the page:
    /// solid enough to see, and not so pale it disappears into the paper.
    private static func isLegibleOnPaper(_ color: UIColor) -> Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return false }
        guard a >= 0.55 else { return false }               // highlighter / faded
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance <= 0.82                            // near-white on cream
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
                if !bakeStroke(stroke, baseWidth: pending.baseWidth,
                               color: pending.color) {
                    // Keep failed bakes visible — see renderReply.
                    renderer.drawStatic([stroke], baseWidth: pending.baseWidth)
                }
            }
        }
        bakedUpTo = 0
        lastReplyBottom = max(lastReplyBottom, pending.bottomY)
        onWritingStateChange?(false)
        publishUndoRedo()
    }

    /// Fades ink toward the page in proportion to how sure we are the shape
    /// is really the user's. Full-strength at confidence ≥ 0.8 (captured or
    /// stitched from real ink); lightest at 0.72 alpha for fully synthesised
    /// glyphs. Bounded so low confidence never means hard to read.
    private static func confidenceAdjusted(_ color: UIColor,
                                           confidence: CGFloat) -> UIColor {
        let clamped = max(0, min(1, confidence))
        guard clamped < 0.8 else { return color }
        // 0.0 → 0.72, 0.8 → 1.0
        let alpha = 0.72 + (clamped / 0.8) * 0.28
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return color }
        return UIColor(red: r, green: g, blue: b, alpha: a * alpha)
    }

    /// Converts a reply stroke into a PencilKit stroke. PencilKit's `.pen`
    /// reads thinner/lighter than a stroked CAShapeLayer — but when we stamp
    /// absolute tip `widths` (matched to the user), only a tiny boost is
    /// needed so the bake doesn't look like a fade OR a marker blob.
    private static func pkStroke(from stroke: InkStroke,
                                 baseWidth: CGFloat,
                                 color: UIColor) -> PKStroke? {
        // PEN-05 — confidence, shown as ink weight.
        //
        // `InkStroke.confidence` has been populated all along (1.0 for a real
        // captured word, 0.52 for letters assembled from a char bank) and
        // nothing consumed it. Every reply looked equally certain, including
        // the ones built from shapes the user never wrote.
        //
        // Shown as slightly lighter ink rather than a badge, deliberately.
        // An icon says "error"; lighter ink says "not sure yet", which is
        // what is actually true. The range is narrow (0.72–1.0) so it reads
        // as pen pressure, never as illegibility — a reply must always be
        // readable first and honest second.
        let inkColor = Self.confidenceAdjusted(color, confidence: stroke.confidence)
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
            return PKStroke(ink: PKInk(.pen, color: inkColor), path: path)
        }
        guard stroke.points.count > 1 else { return nil }

        // PEN-31: bind the optionals once. The `hasWidths` / `hasTimes` flags
        // were computed several lines away from the force-unwraps they
        // guarded, which is exactly how such a pair drifts apart.
        let widths = stroke.widths?.count == stroke.points.count ? stroke.widths : nil
        let times = stroke.pointTimes?.count == stroke.points.count ? stroke.pointTimes : nil
        var controls: [PKStrokePoint] = []
        controls.reserveCapacity(stroke.points.count)
        var lastTime = -1.0
        for (i, p) in stroke.points.enumerated() {
            let nominal = widths?[i] ?? baseWidth
            let w = max(minWidth, nominal * boost)
            // timeOffset must be strictly increasing or PencilKit misrenders.
            let raw = times?[i] ?? Double(i) * 0.004
            let t = max(raw, lastTime + 0.001)
            lastTime = t
            controls.append(point(p, t, w))
        }
        let path = PKStrokePath(controlPoints: controls, creationDate: Date())
        return PKStroke(ink: PKInk(.pen, color: inkColor), path: path)
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

        // Long-press a code block → open THAT block in Arrange mode
        // (move/resize/edit), leaving the rest of the page live. The page-wide
        // Arrange button remains the way to arrange everything at once.
        if !isPageEditMode,
           let target = codeBlockViews.last(where: { !$0.isHidden && $0.frame.contains(pt) }) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            setEditingBlock(target)
            return
        }

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

    // MARK: - Embedded code blocks

    private func makeCodeBlockView(_ block: CodeBlock) -> CodeBlockView {
        let view = CodeBlockView(block: block)
        // "The Pencil writes, the hand operates." While a finger rests on a
        // live block, PencilKit's drawing gesture must stand down — otherwise
        // it claims the touch and draws a stroke instead of letting the block's
        // own buttons and controls receive it. The Pencil is unaffected: it
        // passes through the block (see CodeBlockView.hitTest) and still inks
        // straight over the top.
        view.onFingerActive = { [weak self] active in
            guard let self, !self.isPageEditMode else { return }
            self.canvas.drawingGestureRecognizer.isEnabled = !active
        }
        view.setEditing(isPageEditMode)
        view.onChange = { [weak self] _ in
            guard let self else { return }
            self.growForCodeBlocks()
            self.persistCodeBlocks()
        }
        view.onEditCode = { [weak self] v in
            self?.onRequestEditCodeBlock?(v.block)
        }
        view.onDelete = { [weak self] v in
            self?.removeCodeBlock(v)
        }
        view.onDuplicate = { [weak self] v in
            self?.duplicateCodeBlock(v)
        }
        view.onBringForward = { [weak self] v in
            self?.moveCodeBlockLayer(v, delta: 1)
        }
        view.onSendBackward = { [weak self] v in
            self?.moveCodeBlockLayer(v, delta: -1)
        }
        return view
    }

    /// Drop a new embedded block near the middle of the current viewport and
    /// enter edit mode so it can be positioned right away.
    func insertCodeBlock(html: String = CodedPaper.blockStarterHTML,
                         kind: PageBlockKind = .code,
                         preferredHeight: CGFloat = 300,
                         activateForInput: Bool = false) {
        let w = min(max(240, bounds.width - 48), 560)
        let h = min(max(100, preferredHeight), 520)
        let x = max(leftMargin, (bounds.width - w) / 2)
        let y = max(0, canvas.contentOffset.y + max(24, (bounds.height - h) / 2))
        let block = CodeBlock(html: html, kind: kind,
                              x: x, y: y, width: w, height: h)
        let view = makeCodeBlockView(block)
        canvas.addSubview(view)
        codeBlockViews.append(view)
        if activateForInput {
            // Blocks that greet the user with input fields (attachment) must be
            // immediately interactive — Arrange mode makes the web content
            // passive — so wake the block instead of entering Arrange.
            setPageEditMode(false)
            restackCodeBlocks()
            setActiveCodeBlock(view)
        } else {
            // setPageEditMode brings every block (incl. this one) to the front.
            setPageEditMode(true)
        }
        growForCodeBlocks()
        persistCodeBlocks()
    }

    /// Images use the same embedded-asset model as code/diagram blocks, so
    /// they live on the page and inherit Arrange mode's move/resize/delete UI.
    @discardableResult
    func insertImageBlock(imageData: Data) -> Bool {
        guard let image = UIImage(data: imageData),
              image.size.width > 0,
              let jpeg = image.jpegData(compressionQuality: 0.88) else { return false }
        let w = min(max(240, bounds.width - 48), 560)
        let ratio = image.size.height / image.size.width
        let h = min(max(140, w * ratio), 520)
        insertCodeBlock(
            html: CodedPaper.imageBlockHTML(base64JPEG: jpeg.base64EncodedString()),
            kind: .image,
            preferredHeight: h
        )
        return true
    }

    /// Make `target` the page's one interactive block: it rises above the ink
    /// so its controls are reachable, and its web content takes finger input.
    /// Pass nil to put every block back to sleep below the ink.
    private func setActiveCodeBlock(_ target: CodeBlockView?) {
        guard !isPageEditMode, activeCodeBlock !== target else { return }
        if let old = activeCodeBlock {
            old.isActive = false
        }
        activeCodeBlock = target
        target?.isActive = true
        // Touch routing, not z-order: the block stays under the ink so the
        // annotation drawn on it remains visible while it's being used.
        canvas.activeBlock = target
        restackCodeBlocks()
        // A block can be put to sleep WHILE a finger rests on it (pencil-down,
        // note switch, delete). Its fingerGuard is disabled in the same breath,
        // so the "finger lifted" callback may never arrive — without this the
        // canvas's drawing gesture would stay off and the page would go dead.
        if target == nil { canvas.drawingGestureRecognizer.isEnabled = true }
    }

    /// Rebuild the block z-order in one pass: blocks keep their stable
    /// creation order directly above the paper (so overlapping blocks never
    /// shuffle when one is woken), the active block is lifted above the ink,
    /// and the AI renderer stays on top of the ink layer.
    ///
    ///     paper → code blocks (stable order) → ink → renderer
    ///
    /// The ACTIVE block is not special here: it stays under the ink like every
    /// other, so annotations drawn over it stay visible while it's operated.
    /// Its touches arrive by redirection (see BlockRoutingCanvasView).
    private func restackCodeBlocks() {
        var below: UIView = paper
        for view in codeBlockViews {
            canvas.insertSubview(view, aboveSubview: below)
            below = view
        }
        canvas.bringSubviewToFront(renderer)
    }

    @objc private func handleCanvasTap(_ g: UITapGestureRecognizer) {
        guard !isPageEditMode else { return }
        let p = g.location(in: canvas)
        // A single block in Arrange mode: a tap outside it (allowing for the
        // corner handles/toolbar) commits and exits; taps within belong to the
        // block's own move/resize/edit chrome.
        if let editing = editingBlock {
            if !editing.frame.insetBy(dx: -28, dy: -28).contains(p) { setEditingBlock(nil) }
            return
        }
        // Taps ON the active block operate its content — leave it alone.
        if let active = activeCodeBlock {
            if active.frame.contains(p) { return }
            setActiveCodeBlock(nil)
        }
        // Wake the topmost sleeping block under the tap, if any — and drop the
        // caret where the finger landed so the same tap starts editing inline
        // (a table cell, a checklist label, a paragraph), no "edit" step.
        if let target = codeBlockViews.last(where: { !$0.isHidden && $0.frame.contains(p) }) {
            setActiveCodeBlock(target)
            target.beginInlineEdit(at: target.convert(p, from: canvas))
        }
    }

    @objc private func handlePencilDown(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        setActiveCodeBlock(nil)
        setEditingBlock(nil)   // the pen wins — drop single-block Arrange
    }

    /// Simultaneity for the block-tap and pencil-down observers (the only
    /// recognizers with this view as delegate) — they watch, never compete.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// The block tap observes every finger tap on the page — but a tap that
    /// floating chrome already claimed (an intent-chip button, a toolbar…)
    /// must not ALSO wake or sleep a block that happens to sit underneath.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer is UITapGestureRecognizer else { return true }
        var v = touch.view
        while let cur = v, cur !== canvas {
            if cur is UIControl || cur is MathIntentChip { return false }
            v = cur.superview
        }
        return true
    }

    /// Toggle the page's edit mode. In edit mode blocks show chrome, become
    /// interactive and rise above the ink; ink drawing is suspended. Out of
    /// edit mode they drop behind the ink and stop intercepting touches.
    /// Put ONE block into Arrange mode (move / resize / edit chrome) while
    /// everything else on the page stays live. Pass nil to exit. This is what
    /// a long-press on a block triggers — the page-wide Arrange button is a
    /// separate, all-blocks affordance.
    private func setEditingBlock(_ target: CodeBlockView?) {
        guard editingBlock !== target else { return }
        setActiveCodeBlock(nil)
        editingBlock?.setEditing(false)
        editingBlock = target
        if let target {
            target.setEditing(true)
            // Suspend ink so finger drags move/resize the block instead of
            // drawing, and lift just this block above the ink so its handles
            // and toolbar are reachable.
            canvas.drawingGestureRecognizer.isEnabled = false
            canvas.bringSubviewToFront(renderer)
            canvas.bringSubviewToFront(target)
        } else {
            canvas.drawingGestureRecognizer.isEnabled = true
            restackCodeBlocks()
        }
    }

    func setPageEditMode(_ on: Bool) {
        let changed = isPageEditMode != on
        // The page-wide button and single-block Arrange are exclusive.
        editingBlock?.setEditing(false)
        editingBlock = nil
        setActiveCodeBlock(nil)   // edit chrome and active state are exclusive
        isPageEditMode = on
        canvas.drawingGestureRecognizer.isEnabled = !on
        for view in codeBlockViews {
            view.setEditing(on)
        }
        if on {
            // Edit mode: every block is an object being arranged, so all of
            // them sit above the ink — in stable creation order.
            canvas.bringSubviewToFront(renderer)
            for view in codeBlockViews { canvas.bringSubviewToFront(view) }
        } else {
            restackCodeBlocks()
        }
        if changed { onPageEditModeChange?(on) }
    }

    /// Apply an edited block (new source/geometry) coming back from the sheet.
    func updateCodeBlock(_ block: CodeBlock) {
        guard let view = codeBlockViews.first(where: { $0.block.id == block.id }) else { return }
        view.apply(block)
        growForCodeBlocks()
        persistCodeBlocks()
    }

    private func removeCodeBlock(_ view: CodeBlockView) {
        if activeCodeBlock === view {
            activeCodeBlock = nil
            canvas.activeBlock = nil
            // The block may be deleted with a finger still on it — see
            // setActiveCodeBlock: don't leave the drawing gesture switched off.
            canvas.drawingGestureRecognizer.isEnabled = true
        }
        if editingBlock === view {
            editingBlock = nil
            canvas.drawingGestureRecognizer.isEnabled = true
        }
        view.removeFromSuperview()
        codeBlockViews.removeAll { $0 === view }
        persistCodeBlocks()
    }

    private func duplicateCodeBlock(_ view: CodeBlockView) {
        guard let index = codeBlockViews.firstIndex(where: { $0 === view }) else { return }
        var copy = view.block
        copy.id = UUID()
        copy.x += 24
        copy.y += 24
        copy.createdAt = .now
        let duplicate = makeCodeBlockView(copy)
        canvas.addSubview(duplicate)
        codeBlockViews.insert(duplicate, at: index + 1)
        applyBlockOrder()
        growForCodeBlocks()
        persistCodeBlocks()
    }

    private func moveCodeBlockLayer(_ view: CodeBlockView, delta: Int) {
        guard let index = codeBlockViews.firstIndex(where: { $0 === view }) else { return }
        let destination = min(max(0, index + delta), codeBlockViews.count - 1)
        guard destination != index else { return }
        codeBlockViews.swapAt(index, destination)
        applyBlockOrder()
        persistCodeBlocks()
    }

    private func applyBlockOrder() {
        if isPageEditMode {
            canvas.bringSubviewToFront(renderer)
            for view in codeBlockViews { canvas.bringSubviewToFront(view) }
        } else {
            restackCodeBlocks()
            // Keep a single-block Arrange session lifted above the ink so its
            // handles and toolbar stay reachable after a layer change.
            if let editingBlock {
                canvas.bringSubviewToFront(renderer)
                canvas.bringSubviewToFront(editingBlock)
            }
        }
    }

    private func persistCodeBlocks() {
        let blocks = currentCodeBlocks
        guard blocks != persistedBlockSnapshot else { return }
        let previous = persistedBlockSnapshot
        canvas.undoManager?.registerUndo(withTarget: self) { target in
            target.restoreCodeBlocks(previous)
        }
        canvas.undoManager?.setActionName("Edit Block")
        persistedBlockSnapshot = blocks
        onCodeBlocksChange?(blocks)
        publishUndoRedo()
    }

    private func restoreCodeBlocks(_ blocks: [CodeBlock]) {
        let redo = currentCodeBlocks
        canvas.undoManager?.registerUndo(withTarget: self) { target in
            target.restoreCodeBlocks(redo)
        }
        setActiveCodeBlock(nil)
        codeBlockViews.forEach { $0.removeFromSuperview() }
        codeBlockViews = blocks.map { block in
            let view = makeCodeBlockView(block)
            canvas.addSubview(view)
            return view
        }
        persistedBlockSnapshot = blocks
        applyBlockOrder()
        growForCodeBlocks()
        onCodeBlocksChange?(blocks)
        publishUndoRedo()
    }

    /// Grow the paper so the lowest block always has room below it.
    private func growForCodeBlocks() {
        let maxY = codeBlockViews.map { $0.frame.maxY }.max() ?? 0
        if maxY + lineGap * 2 > contentHeight {
            contentHeight = maxY + lineGap * 4
            updateContentLayout()
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

    /// The pen has touched down — writing wins. The active code block drops
    /// back below the ink layer automatically, so the stroke lands on top of
    /// it just like anywhere else on the page.
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        setActiveCodeBlock(nil)
    }

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
        // PEN-11: the user kept writing, so any live preview is now stale.
        // Dismissing on ANY new ink is the right default — a preview that
        // lingers past the expression it described is worse than none.
        dismissAnswerPreviewIfNeeded()
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
    /// Reply text published to VoiceOver (PEN-32).
    private var spokenReplies: [String] = []

    // MARK: Reply

    /// Place a typed user note on the page, ask Gemini, then write the reply.
    func sendTextMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // PEN-17 — "plot x^2" / "y = sin(x)" is drawn here, on device, rather
        // than sent to the brain. Instant, offline, and free.
        if let body = GraphPlotter.functionBody(in: trimmed), drawGraph(of: body) {
            return
        }
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
                // PEN-12: if we're simply offline, keep the message and say so
                // once — the outbox sends it when the connection returns.
                let item = Outbox.Item(
                    kind: .chat, payload: trimmed,
                    capability: settings.capability,
                    mood: settings.companionMood,
                    customMood: settings.customMoodText,
                    mathDetail: settings.mathDetail)
                _ = Outbox.shared.enqueueIfOffline(item, error: error)
                onStatus?(PenpalError.message(for: error))
            }
        }
    }

    /// Render AI (or fallback) reply text using hand or font style.
    func writeReplyText(_ text: String) {
        idleTimer?.invalidate()
        guard !renderer.isWriting else { return }
        publishForVoiceOver(text, isAnswer: true)   // PEN-32

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
                                                 settings: settings,
                                                 allowSynthesis: !looksLikeMath(text))
        if sequence.clipped {
            InkUnity.shared.endSentence()
            addPage()
            onStatus?("Added a page — send again.")
            return
        }
        if settings.diagnostics, sequence.confidence < 0.55 {
            onStatus?("This reply uses low-confidence fallback glyphs. Train its words for a closer match.")
        }
        // Non-finite geometry renders as a moving pen with no ink — drop it.
        let strokes = sequence.strokes.filter { s in
            s.points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
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

        let baseWidth = max(1.2, placement.xHeight * 0.11 * CGFloat(settings.penWidthScale))
        let bakeColor = bakedInkColor
        onWritingStateChange?(true)
        pendingBake = (strokes, baseWidth, bottomY, bakeColor)
        bakedUpTo = 0

        let preRoll = showDetection ? 0.45 : 0.10
        DispatchQueue.main.asyncAfter(deadline: .now() + preRoll) { [weak self] in
            guard let self else { return }
            self.renderer.inkColor = bakeColor
            self.beginUndoableAction("Penpal Reply")   // PEN-14
            self.renderer.write(strokes, baseWidth: baseWidth, onStrokeFinished: { [weak self] i in
                // Each finished stroke becomes real canvas ink immediately.
                guard let self, let pending = self.pendingBake,
                      i < pending.strokes.count else { return }
                if !self.bakeStroke(pending.strokes[i], baseWidth: pending.baseWidth,
                                    color: pending.color) {
                    // Keep failed bakes visible — see renderReply.
                    self.renderer.drawStatic([pending.strokes[i]],
                                             baseWidth: pending.baseWidth)
                }
                self.bakedUpTo = i + 1
            }) { [weak self] in
                guard let self else { return }
                self.pendingBake = nil
                self.bakedUpTo = 0
                self.lastReplyBottom = bottomY
                self.endUndoableAction()               // PEN-14
                self.onWritingStateChange?(false)
                self.publishUndoRedo()
                self.flushWritingCompletions()         // PEN-09
            }
        }
    }

    /// Trigger rules, per mode:
    /// - On-device calculator: "=" when Penpal is off, or Penpal + Companion.
    ///   Penpal + Mathematician never uses it — "=" goes to the brain/LLM.
    /// - Penpal + Mathematician: the BOX is the only automatic trigger.
    ///   Nothing else fires while the user is writing — no Solve chip, no
    ///   idle-pause send — because a problem in this mode is often written
    ///   across several pauses and interrupting it is worse than waiting.
    /// - Penpal + Companion: replies after the writing pause (as before).
    /// `auto` is true when the idle timer fired; false for an explicit
    /// "reply now" request from the user.
    func replyNow(auto: Bool = false) {
        idleTimer?.invalidate()
        // Busy = animating (isWriting), waiting to bake (pendingBake), or a
        // request already on the network (brainBusy). Returning BEFORE
        // consuming lastReplyStrokeCount means the fresh ink stays queued —
        // the user's next pen lift re-arms the idle timer and it gets its
        // reply then, as one message instead of a split one.
        guard !renderer.isWriting, pendingBake == nil, !brainBusy else { return }

        let all = canvas.drawing.strokes
        guard all.count > lastReplyStrokeCount else { return }
        let newStart = lastReplyStrokeCount
        let newStrokes = Array(all[newStart...])
        lastReplyStrokeCount = all.count

        let mathematicianMode = penpalEnabled && settings.capability == "mathematician"

        // Drawn intent (PEN-07) runs FIRST: a double underline is also two
        // long thin strokes, and would otherwise be read as something else.
        if penpalEnabled,
           let gesture = InkAnalyzer.detectGesture(all: all, newStart: newStart) {
            perform(gesture, all: all)
            return
        }

        // Boxed problem: Penpal + Mathematician only.
        if mathematicianMode,
           let box = InkAnalyzer.detectProblemBox(all: all, newStart: newStart) {
            solveBoxedProblem(box, all: all)
            return
        }

        // MATHEMATICIAN: THE BOX IS THE ONLY AUTOMATIC TRIGGER.
        //
        // Someone in this mode is writing a problem out — often over several
        // pauses, often with an "=" partway through. Every automatic trigger
        // here is an interruption of a question that isn't finished being
        // asked: the Solve chip pops over the working, or a half-written
        // problem gets sent to the brain. In this mode the user has ALREADY
        // told us they want the model, so there is nothing to infer — we just
        // need to know WHICH problem, and drawing a box says exactly that.
        //
        // Explicit requests (the send button, auto == false) still go through
        // to the brain below; only idle-timer firing is suppressed.
        if mathematicianMode, auto {
            // Nothing was consumed visually, but the stroke counter moved —
            // put it back so a later box (or explicit ask) still sees this
            // ink as new, unanswered input.
            lastReplyStrokeCount = newStart
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

            // "=" still drives the full-line reading below in every mode.
            // It does NOT reach the on-device calculator in Mathematician
            // mode: that path returns at the `mathematicianMode` block below,
            // before any Solve chip can appear.
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
                // PEN-11 — show the answer immediately, ghosted, while the
                // confirmation is still pending. The user sees the result the
                // moment it is known instead of after another interaction.
                if self.settings.confirmBeforeSolving {
                    self.previewAnswer(expression: hit.expression,
                                       placement: placement,
                                       sourceStrokes: inkToRead)
                }
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
        brainBusy = true
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
                // Safe to clear here: renderReply sets pendingBake
                // synchronously, so the replyNow guard stays closed until
                // the ink is fully baked.
                self.brainBusy = false
            } catch {
                self.brainBusy = false
                self.onThinkingChange?(false)
                self.onWritingStateChange?(false)
                self.onStatus?(PenpalError.message(for: error))
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
        // PEN-11: the real ink is about to be written in this exact spot —
        // drop the ghost first so the answer never renders twice.
        renderer.clearAnswerGhost()
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
        // PEN-11: the chip and the preview describe the same expression, so
        // they live and die together. Leaving a ghost after the chip is gone
        // would show an answer with no way to accept it.
        renderer.clearAnswerGhost()
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
                    settings: self.settings,
                    allowSynthesis: false)   // ghost steps are always math
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

        // PEN-33 — they drew a box. That is the lesson learned; the hint goes
        // away silently. No "well done" — the gesture doing something IS the
        // feedback, and congratulating someone for drawing a rectangle is
        // patronising.
        GestureOnboarding.shared.markLearned()

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
                // PEN-12: a boxed problem is expensive to redraw, so keep the
                // image itself — the box stays on the page until it's answered.
                let item = Outbox.Item(
                    kind: .solveMath, payload: png.base64EncodedString(),
                    capability: "mathematician",
                    mood: self.settings.companionMood,
                    customMood: self.settings.customMoodText,
                    mathDetail: self.settings.mathDetail)
                _ = Outbox.shared.enqueueIfOffline(item, error: error)
                self.onStatus?(PenpalError.message(for: error))
            }
        }
    }

    // MARK: - VoiceOver (PEN-32)

    /// PEN-32 — Penpal's replies are ink, which is invisible to VoiceOver.
    ///
    /// The whole page is one `PKCanvasView`: a screen reader sees a drawing
    /// canvas and nothing else, so a blind or low-vision user gets *no* access
    /// to the answer at all. But we know exactly what was written — it came
    /// back as text before it was ever drawn. Publishing it as an accessibility
    /// element costs nothing and turns silence into a readable reply.
    ///
    /// Announcing is deliberate too: an answer that appears while the user is
    /// looking elsewhere is silent for sighted users, who can glance down. A
    /// VoiceOver user has no equivalent, so the arrival is spoken.
    private func publishForVoiceOver(_ text: String, isAnswer: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // PEN-18 — same moment, same insight: the reply is text right now, so
        // index it for search before it becomes unsearchable ink.
        NotesStore.shared.recordReplyText(trimmed)
        spokenReplies.append(trimmed)
        if spokenReplies.count > 30 { spokenReplies.removeFirst() }

        // One element carrying the whole conversation, so VoiceOver users can
        // review earlier answers instead of only hearing the newest.
        let element = UIAccessibilityElement(accessibilityContainer: canvas)
        element.accessibilityLabel = "Penpal's reply"
        element.accessibilityValue = trimmed
        element.accessibilityTraits = .staticText
        element.accessibilityFrameInContainerSpace = canvas.bounds
        canvas.accessibilityElements = [element]
        canvas.isAccessibilityElement = false

        if isAnswer {
            UIAccessibility.post(notification: .announcement, argument: trimmed)
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

    // MARK: - Gesture actions (PEN-07)

    /// Carries out a drawn instruction. Every action here follows the same
    /// grammar the box gesture established: acknowledge the mark, do the
    /// thing, then dissolve the mark — the page keeps only real work.
    private func perform(_ gesture: InkAnalyzer.Gesture, all: [PKStroke]) {
        switch gesture {
        case .checkWork(let region, let strokeIndices):
            let marks = strokeIndices.map { all[$0] }
            marks.forEach { renderer.traceBox($0) }
            // The underline was an instruction, not content.
            dissolveBoxStrokes(marks)
            checkWorking(in: region, strokes: all.enumerated()
                .filter { !strokeIndices.contains($0.offset) }
                .map(\.element))

        case .strikeThrough(let targetIndices, let strokeIndex):
            let doomed = (targetIndices + [strokeIndex]).map { all[$0] }
            // One undo restores everything — a mis-detected strike must never
            // cost the user work they can't get back.
            dissolveBoxStrokes(doomed, actionName: "Delete Struck Text")
            onStatus?("")
        }
    }

    // MARK: - Show-your-work grading (PEN-16)

    /// Mark the student's own working: find the first wrong line, draw a
    /// gentle mark beside it, and write the note underneath.
    ///
    /// The tone is deliberate. This never says "wrong" — it points at a line
    /// and says what happened there. A student who feels caught out stops
    /// showing their working, which defeats the whole feature.
    /// Menu entry point: check everything on the page.
    func checkMyWorking() {
        let all = canvas.drawing.strokes
        let content = all.reduce(CGRect.null) { $0.union($1.renderBounds) }
        guard !content.isNull else {
            onStatus?("Write out your working first, then ask me to check it.")
            return
        }
        checkWorking(in: content, strokes: all)
    }

    /// Shared implementation — used by the menu and by the double-underline
    /// gesture, which passes only the working above the mark.
    func checkWorking(in content: CGRect, strokes all: [PKStroke]) {
        guard !content.isNull, !all.isEmpty else {
            onStatus?("Write out your working first, then ask me to check it.")
            return
        }
        guard settings.useBrain else {
            onStatus?("Checking working needs the brain — enable it in Settings → Behavior.")
            return
        }
        let region = content.insetBy(dx: -10, dy: -10)
        guard let png = Self.renderInkImage(strokes: all, region: region) else {
            onStatus?("Couldn't read that working.")
            return
        }

        renderer.beginAnalyzing(strokes: all)
        setReadingBanner(true)
        onThinkingChange?(true)
        onWritingStateChange?(true)
        onStatus?("")

        Task { @MainActor in
            defer {
                self.renderer.endAnalyzing()
                self.setReadingBanner(false)
            }
            do {
                let marking = try await PenpalAPI.checkWork(
                    pngData: png, baseURL: self.settings.apiBaseURL)
                self.onThinkingChange?(false)
                self.onWritingStateChange?(false)
                self.showMarking(marking, region: region, all: all)
            } catch {
                self.onThinkingChange?(false)
                self.onWritingStateChange?(false)
                self.onStatus?(PenpalError.message(for: error))
            }
        }
    }

    private func showMarking(_ marking: PenpalAPI.WorkMarking,
                             region: CGRect, all: [PKStroke]) {
        // PEN-19 — the grader just judged this student's own working, which is
        // a far better signal than self-reported difficulty. Two paths:
        //
        //  * marking a PRACTICE attempt closes the spaced-repetition loop
        //  * marking ordinary work adds a new weakness to the schedule
        //
        // `onMarked` is set by the view when a practice problem is on the page.
        if let onMarked = onWorkMarked {
            onMarked(!marking.foundError)
        } else if marking.foundError, !marking.problem.isEmpty {
            StudyPlanner.shared.recordMistake(topic: marking.problem,
                                              mistake: marking.reason)
        }
        let virtualBounds = CGRect(x: 0, y: 0, width: bounds.width,
                                   height: contentHeight + max(400, bounds.height))
        var origin: CGPoint
        if marking.foundError, let box = marking.box {
            // Mark the line itself, then write just beneath it.
            let rect = box.rect(in: region)
            renderer.markLine(rect)
            origin = CGPoint(x: min(rect.minX + lineRelativeXHeight,
                                    bounds.width - 140),
                             y: rect.maxY + lineGap * 0.85)
        } else {
            origin = CGPoint(x: leftMargin,
                             y: max(lastReplyBottom + lineGap * 1.2,
                                    region.maxY + lineGap))
        }
        ensureRoom(below: origin.y + lineGap * 3)

        let placement = ReplyPlacement(origin: origin,
                                       xHeight: lineRelativeXHeight,
                                       maxX: bounds.width - 24,
                                       maxY: virtualBounds.maxY,
                                       newInkBounds: .zero,
                                       detectedLines: [],
                                       needsNewPage: false)
        renderReply(marking.note, placement: placement,
                    celebrate: !marking.foundError, matchStrokes: [])
    }

    // MARK: - Worksheet mode (PEN-15)

    /// A boxed region containing several numbered problems: solve them all in
    /// one pass and write each answer beside its own question.
    ///
    /// This is the same image pipeline as a single boxed problem — the page is
    /// cropped and sent as a picture, no OCR — but the reply is structured per
    /// problem so each answer can be placed independently.
    /// Solve every problem currently on the page.
    func solveWholePageAsWorksheet() {
        let all = canvas.drawing.strokes
        let content = all.reduce(CGRect.null) { $0.union($1.renderBounds) }
        guard !content.isNull else {
            onStatus?("Write some problems first, then solve the page.")
            return
        }
        solveWorksheet(in: content)
    }

    func solveWorksheet(in region: CGRect) {
        let all = canvas.drawing.strokes
        guard !all.isEmpty else {
            onStatus?("Nothing to solve on this page yet.")
            return
        }
        guard settings.useBrain else {
            onStatus?("Worksheets need the brain — enable it in Settings → Behavior.")
            return
        }
        let padded = region.insetBy(dx: -10, dy: -10)
        guard let png = Self.renderInkImage(strokes: all, region: padded) else {
            onStatus?("Couldn't read that page.")
            return
        }

        let inside = all.filter { padded.intersects($0.renderBounds) }
        renderer.beginAnalyzing(strokes: inside)
        setReadingBanner(true)
        onThinkingChange?(true)
        onWritingStateChange?(true)
        onStatus?("")

        Task { @MainActor in
            defer {
                self.renderer.endAnalyzing()
                self.setReadingBanner(false)
            }
            do {
                let problems = try await PenpalAPI.solveWorksheet(
                    pngData: png,
                    baseURL: self.settings.apiBaseURL,
                    mathDetail: self.settings.mathDetail)
                self.onThinkingChange?(false)
                self.onWritingStateChange?(false)
                self.writeWorksheetAnswers(problems, region: padded, all: all)
            } catch {
                self.onThinkingChange?(false)
                self.onWritingStateChange?(false)
                self.onStatus?(PenpalError.message(for: error))
            }
        }
    }

    /// Writes each answer next to its problem, one after another so the pen
    /// visibly works down the page rather than everything appearing at once.
    ///
    /// PEN-09: chained on the renderer's completion rather than a fixed delay.
    /// The original 0.45s guess raced a long answer — a second answer could
    /// start while the first was still being written, and two pens fighting
    /// over the page is the one thing this animation must never do.
    private func writeWorksheetAnswers(_ problems: [PenpalAPI.WorksheetProblem],
                                       region: CGRect, all: [PKStroke]) {
        let unreadable = problems.filter { !$0.readable }
        let solved = problems.filter(\.readable)
        guard !solved.isEmpty else {
            onStatus?("I couldn't read any problems on that page.")
            return
        }

        // Top to bottom, so the page fills in the order a person would read it.
        let ordered = solved.sorted {
            ($0.box?.y ?? .greatestFiniteMagnitude)
                < ($1.box?.y ?? .greatestFiniteMagnitude)
        }

        var queue = ordered[...]
        func writeNext() {
            guard let problem = queue.first else {
                if !unreadable.isEmpty {
                    let labels = unreadable.map(\.label).joined(separator: ", ")
                    // Say so rather than silently skipping: an answer that
                    // never appears looks like the app simply missed it.
                    self.onStatus?("Couldn't read problem\(unreadable.count == 1 ? "" : "s") \(labels).")
                }
                return
            }
            queue = queue.dropFirst()
            let placement = self.worksheetPlacement(for: problem, region: region,
                                                    all: all)
            self.renderReply(problem.answer, placement: placement,
                             celebrate: true, matchStrokes: [])
            // Wait for the pen to actually finish, then take a beat before the
            // next problem — the pause is what makes it read as working down a
            // page rather than as a progress bar.
            self.afterWriting { [weak self] in
                guard self != nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { writeNext() }
            }
        }
        writeNext()
    }

    /// Where a worksheet answer goes: just below and slightly indented from
    /// its own problem when we know where that is, otherwise flowed down the
    /// page from the last reply — never guessed next to a neighbour.
    private func worksheetPlacement(for problem: PenpalAPI.WorksheetProblem,
                                    region: CGRect,
                                    all: [PKStroke]) -> ReplyPlacement {
        let virtualBounds = CGRect(x: 0, y: 0, width: bounds.width,
                                   height: contentHeight + max(400, bounds.height))
        if let box = problem.box {
            let rect = box.rect(in: region)
            let origin = CGPoint(x: min(rect.minX + lineRelativeXHeight * 1.2,
                                        bounds.width - 120),
                                 y: rect.maxY + lineGap * 0.9)
            ensureRoom(below: origin.y + lineGap * 2)
            return ReplyPlacement(origin: origin,
                                  xHeight: lineRelativeXHeight,
                                  maxX: bounds.width - 24,
                                  maxY: virtualBounds.maxY,
                                  newInkBounds: rect,
                                  detectedLines: [],
                                  needsNewPage: false)
        }
        let originY = max(lastReplyBottom + lineGap * 1.2,
                          region.maxY + lineGap)
        ensureRoom(below: originY + lineGap * 2)
        return ReplyPlacement(origin: CGPoint(x: leftMargin, y: originY),
                              xHeight: lineRelativeXHeight,
                              maxX: bounds.width - 24,
                              maxY: virtualBounds.maxY,
                              newInkBounds: .zero,
                              detectedLines: [],
                              needsNewPage: false)
    }

    /// Removes the box gesture stroke(s) from the canvas while the renderer
    /// fades ghosts of them — the gesture served its purpose; the page keeps
    /// only actual work. Handles boxes drawn as one loop or several segments.
    private func dissolveBoxStrokes(_ boxStrokes: [PKStroke],
                                    actionName: String = "Dissolve Box") {
        let before = canvas.drawing
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
        // PEN-14: one undo puts the ink back. Essential for strike-through,
        // where a false positive would otherwise silently eat the user's work.
        registerUndo(name: actionName, restoring: before, redoing: canvas.drawing)
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
            preferredXHeight: lineRelativeXHeight,
            // PEN-10: we know the answer here, so the placer can reserve the
            // width it actually needs — and put a short one in the margin
            // beside the problem rather than a line below it.
            estimatedWidth: Self.estimatedWidth(of: text,
                                                xHeight: lineRelativeXHeight)) else { return }
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
        // PEN-32: publish before drawing. Every reply reaches VoiceOver
        // regardless of which path produced it, and regardless of whether the
        // ink pipeline later clips or re-pages.
        publishForVoiceOver(text, isAnswer: true)
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

        // Math must never be SYNTHESIZED. A generated glyph is a plausible
        // invention — fine in prose, wrong in an equation.
        let sequence = StrokeFont.layoutSequence(text: text,
                                                 origin: placement.origin,
                                                 xHeight: placement.xHeight,
                                                 maxX: placement.maxX,
                                                 lineGap: lineGap,
                                                 maxY: placement.maxY,
                                                 messiness: messiness,
                                                 useUserHand: true,
                                                 settings: settings,
                                                 allowSynthesis: !looksLikeMath(text))
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
        // Non-finite geometry is dropped here: a NaN point makes CAShapeLayer
        // silently render nothing while the pen dot still animates — a moving
        // pen that deposits no ink. One bad glyph must not do that.
        let strokes: [InkStroke] = sequence.strokes.compactMap { s in
            guard s.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            var copy = s
            if copy.isDot {
                copy.dotRadius = max(copy.dotRadius, baseWidth * 0.45)
            } else if copy.points.count > 1 {
                copy.widths = Array(repeating: baseWidth, count: copy.points.count)
            }
            return copy
        }
        // DIAGNOSTIC (PEN-INK): "it animates but nothing lands on paper" has
        // exactly four possible causes, and they are indistinguishable by
        // eye. Report all four at once so one run identifies it:
        //   1. strokes never baked          -> baked count stays 0
        //   2. baked but transparent        -> alpha ~0
        //   3. baked but hairline           -> width ~0
        //   4. baked outside the page       -> bounds off-canvas
        let diagnoseInk: () -> Void = { [weak self] in
            guard let self, self.settings.diagnostics else { return }
            var alpha: CGFloat = -1
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            _ = bakeColor.getRed(&r, green: &g, blue: &b, alpha: &alpha)
            let inkBounds = strokes.reduce(CGRect.null) { partial, s in
                s.points.reduce(partial) { $0.union(CGRect(origin: $1, size: .zero)) }
            }
            let onPage = inkBounds.intersects(
                CGRect(x: 0, y: 0, width: self.canvas.bounds.width,
                       height: self.contentHeight))
            self.onStatus?(String(
                format: "ink: %d strokes · w %.2f · alpha %.2f · y %.0f–%.0f · onPage %@ · canvas %d",
                strokes.count, baseWidth, alpha,
                inkBounds.minY, inkBounds.maxY,
                onPage ? "YES" : "NO",
                self.canvas.drawing.strokes.count))
        }
        let bottomY = sequence.bottomY

        let letters = text.filter { $0.isLetter || $0.isNumber }.count
        // Score the PRE-stamped sequence: it still carries the captures'
        // real per-point widths and timing. The stamped copies above have
        // constant width, so scoring them told the critic every reply had
        // zero pressure variation — unlike any real hand.
        StyleRL.shared.endEpisode(strokes: sequence.strokes,
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
            // PEN-14: open one action around the whole reply. Fifty baked
            // strokes collapse to a single undo the user would call "the reply".
            self.beginUndoableAction("Penpal Reply")
            self.renderer.write(strokes, baseWidth: baseWidth, onStrokeFinished: { [weak self] i in
                guard let self, let pending = self.pendingBake,
                      i < pending.strokes.count else { return }
                if !self.bakeStroke(pending.strokes[i], baseWidth: pending.baseWidth,
                                    color: pending.color) {
                    // The animation layer is removed the moment this handler
                    // returns — redraw the stroke statically so a failed bake
                    // can never read as ink vanishing while Penpal writes.
                    self.renderer.drawStatic([pending.strokes[i]],
                                             baseWidth: pending.baseWidth)
                }
                self.bakedUpTo = i + 1
            }) { [weak self] in
                guard let self else { return }
                self.renderer.widthScale = savedScale
                self.pendingBake = nil
                self.bakedUpTo = 0
                self.lastReplyBottom = bottomY
                self.endUndoableAction()      // PEN-14
                self.onWritingStateChange?(false)
                self.publishUndoRedo()
                self.flushWritingCompletions()   // PEN-09
                diagnoseInk()
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

// MARK: - Canvas that routes touches to the active code block

/// The page's visual stack never changes in normal writing mode:
///
///     paper → code blocks → PencilKit ink → AI renderer
///
/// Blocks stay UNDER the ink permanently, so an annotation drawn across a
/// block is always visible on top of it — even while that block is being
/// operated. Raising the block instead (the obvious approach) hides the
/// annotation behind opaque web content, which defeats the point of a widget
/// that lives on a page you write on.
///
/// Interaction is therefore decoupled from z-order: exactly one block may be
/// "active" at a time, and while it is, finger touches landing inside its
/// frame are redirected past the ink layer straight into its web content.
///
/// The override is deliberately narrow — one nil check and one rect test —
/// so pages with no active block (the overwhelming majority of touch and
/// hover events, including every pencil stroke) pay nothing at all. An
/// earlier version walked the view hierarchy comparing class names on every
/// event and was measurably laggy.
final class BlockRoutingCanvasView: PKCanvasView {

    /// Set by `MagicPaperView` whenever the active block changes. Weak: the
    /// canvas must never keep a deleted block alive.
    weak var activeBlock: CodeBlockView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Fast path — nothing is active, so the page behaves exactly like a
        // plain PencilKit canvas.
        guard let block = activeBlock else { return super.hitTest(point, with: event) }
        let local = convert(point, to: block)
        guard let hit = block.interactiveHit(local, with: event) else {
            return super.hitTest(point, with: event)
        }
        return hit
    }
}
