//
//  CodeBlockView.swift
//  penpal
//
//  An embedded "coded" asset that lives *inside* an ink page. It renders a
//  live HTML/CSS/JS block (a graph, a widget, anything the web can draw) and
//  sits behind the handwriting so ink and Penpal replies annotate on top.
//
//  It STAYS behind the ink even while being used: a finger tap makes it the
//  page's active block, and the canvas then redirects touches into it past
//  the ink layer. Nothing moves, so an annotation drawn across the block
//  remains visible while its buttons are being pressed. A pencil approaching
//  the block, or a tap elsewhere, stands it back down.
//
//  In normal mode it is chrome-less — no border, background or shadow — so it
//  reads as part of the page. In the page's *edit mode* it shows a dashed
//  outline plus corner handles and a small toolbar, and can be moved, resized,
//  edited (its code) and deleted. This is the "asset inside the page" model:
//  drop as many as you like and arrange them freely.
//

import UIKit
import WebKit
import SwiftUI

// MARK: - On-page asset (UIKit)

final class CodeBlockView: UIView, UIGestureRecognizerDelegate, WKNavigationDelegate {

    /// Documents loaded with `baseURL: nil` get a NULL origin: WebKit then
    /// refuses storage, denies resource loads ("Couldn't open … Permission
    /// denied") and disables anything needing a secure context. A block that
    /// renders a real simulation needs a real origin, and `https://localhost`
    /// gives it one without touching the network.
    static let contentBaseURL = URL(string: "https://localhost/")

    private(set) var block: CodeBlock

    private let webView: WKWebView
    private let outline = CAShapeLayer()
    /// Quiet "accepting input" ring shown while the block is active.
    private let activeRing = CAShapeLayer()
    private var handles: [UIView] = []
    private let toolbar = UIStackView()

    /// Fired when geometry changes (move/resize finished) so the note persists.
    var onChange: ((CodeBlock) -> Void)?
    /// Fired when the user taps the block's edit-code button.
    var onEditCode: ((CodeBlockView) -> Void)?
    /// Fired when the user taps the block's delete button.
    var onDelete: ((CodeBlockView) -> Void)?

    private var isEditing = false
    private let minSize = CGSize(width: 80, height: 60)
    private let handleSize: CGFloat = 24

    /// TAP-ACTIVATE — "the Pencil writes, the hand operates — on request".
    ///
    /// A block can render a live thing: a simulation, a slider, a submit
    /// button. But it must never swallow touches while the user is just
    /// writing, and it usually sits BELOW the ink so annotations stay on top —
    /// which also puts its controls out of reach. So a block has two states:
    ///
    ///   * inactive (default) -> asleep below the ink and COMPLETELY
    ///                           transparent to touches: the Pencil inks over
    ///                           it like plain paper, and a finger tap is
    ///                           noticed by the page's own tap recognizer
    ///                           (MagicPaperView), which wakes the block.
    ///   * active             -> raised above the ink by the owner, and its
    ///                           web content receives touches, so its buttons
    ///                           and controls actually work. A pencil landing
    ///                           on it is caught by the page's pencil
    ///                           recognizer, which puts it back to sleep.
    ///
    /// Touch-type routing deliberately does NOT happen in `hitTest`:
    /// `event.allTouches` is unreliable at touch-down, and misreading a
    /// pencil as a finger made strokes that started on a block vanish.
    /// Gesture recognizers see the real `UITouch.type`, so the page-level
    /// recognizers decide; the block just claims all or nothing.
    ///
    /// While a finger is down on an ACTIVE block, `onFingerActive` suspends
    /// the canvas's drawing gesture — otherwise PencilKit claims the touch
    /// and draws a stroke instead of letting the button press land.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            applyInteractionState()
        }
    }

    /// Fired when a finger touch starts / ends on a live block, so the owner
    /// can stop the ink canvas competing for that touch.
    var onFingerActive: ((Bool) -> Void)?

    /// Zero-duration press used purely as a SIGNAL that a finger is on the
    /// block. It never consumes the touch (`cancelsTouchesInView = false`),
    /// so the web content still receives the full sequence.
    private lazy var fingerGuard: UILongPressGestureRecognizer = {
        let g = UILongPressGestureRecognizer(target: self,
                                             action: #selector(handleFingerGuard(_:)))
        g.minimumPressDuration = 0
        g.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        g.cancelsTouchesInView = false
        g.delaysTouchesBegan = false
        g.delaysTouchesEnded = false
        g.delegate = self
        return g
    }()

    private lazy var bodyPan: UIPanGestureRecognizer = {
        let p = UIPanGestureRecognizer(target: self, action: #selector(handleBodyPan(_:)))
        p.delegate = self
        return p
    }()

    // MARK: Init

    init(block: CodeBlock) {
        self.block = block
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        // A block is meant to RUN — be explicit rather than relying on the
        // default, which has changed across WebKit versions.
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: block.frame)
        setup()
        webView.navigationDelegate = self
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        backgroundColor = .clear
        clipsToBounds = false

        // Touch routing is decided in `hitTest` (see `isActive`), not by making
        // the web content permanently passive: in normal mode a finger may
        // operate it while the Pencil passes through to the ink canvas, and in
        // edit mode our own move/resize gestures win outright.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isUserInteractionEnabled = false
        webView.clipsToBounds = true
        webView.layer.cornerRadius = 6
        webView.layer.cornerCurve = .continuous
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif
        addSubview(webView)

        // Live ring (normal mode, active only). Below the ink visually, like
        // the block itself — it marks the block, it doesn't float over ink.
        activeRing.fillColor = UIColor.clear.cgColor
        activeRing.strokeColor = UIColor.tintColor.withAlphaComponent(0.55).cgColor
        activeRing.lineWidth = 2
        activeRing.isHidden = true
        layer.addSublayer(activeRing)

        // Dashed selection outline (edit mode only).
        outline.fillColor = UIColor.clear.cgColor
        outline.strokeColor = UIColor.tintColor.withAlphaComponent(0.9).cgColor
        outline.lineWidth = 1.5
        outline.lineDashPattern = [6, 4]
        outline.isHidden = true
        layer.addSublayer(outline)

        // Four corner resize handles (edit mode only).
        for corner in 0..<4 {
            let h = UIView()
            h.tag = corner
            h.backgroundColor = .systemBackground
            h.layer.borderColor = UIColor.tintColor.cgColor
            h.layer.borderWidth = 2
            h.layer.cornerRadius = handleSize / 2
            h.isHidden = true
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleResize(_:)))
            h.addGestureRecognizer(pan)
            addSubview(h)
            handles.append(h)
        }

        // Floating toolbar above the block (edit mode only).
        toolbar.axis = .horizontal
        toolbar.spacing = 8
        toolbar.alignment = .center
        toolbar.isLayoutMarginsRelativeArrangement = true
        toolbar.directionalLayoutMargins = .init(top: 6, leading: 10, bottom: 6, trailing: 10)
        toolbar.backgroundColor = UIColor.secondarySystemBackground
        toolbar.layer.cornerRadius = 16
        toolbar.layer.cornerCurve = .continuous
        toolbar.layer.shadowColor = UIColor.black.cgColor
        toolbar.layer.shadowOpacity = 0.12
        toolbar.layer.shadowRadius = 6
        toolbar.layer.shadowOffset = CGSize(width: 0, height: 2)
        toolbar.isHidden = true
        toolbar.addArrangedSubview(makeToolButton(system: "chevron.left.forwardslash.chevron.right",
                                                  action: #selector(tapEditCode)))
        toolbar.addArrangedSubview(makeToolButton(system: "trash",
                                                  action: #selector(tapDelete),
                                                  destructive: true))
        addSubview(toolbar)

        addGestureRecognizer(bodyPan)
        addGestureRecognizer(fingerGuard)
        // Safe default before the owner configures editing / live state:
        // no stray drags, no touch capture.
        applyInteractionState()
    }

    /// The web process can be killed under memory pressure (the device logs
    /// `WebProcessProxy::didBecomeUnresponsive` / `mach_vm_allocate failed`
    /// first). The block then renders its last frame but is DEAD — it looks
    /// perfectly fine and simply ignores every tap, which is indistinguishable
    /// from a touch-routing bug. Reload so it comes back by itself.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reload()
    }

    @objc private func handleFingerGuard(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            onFingerActive?(true)
        case .ended, .cancelled, .failed:
            onFingerActive?(false)
        default:
            break
        }
    }

    private func makeToolButton(system: String, action: Selector, destructive: Bool = false) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: system)
        config.baseForegroundColor = destructive ? .systemRed : .tintColor
        config.preferredSymbolConfigurationForImage =
            UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        config.contentInsets = .init(top: 4, leading: 6, bottom: 4, trailing: 6)
        let b = UIButton(configuration: config)
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    // MARK: Content

    func reload() {
        webView.loadHTMLString(CodedPaper.blockDocument(from: block.html),
                               baseURL: Self.contentBaseURL)
    }

    /// Apply an edited model (new code and/or geometry) and re-render.
    func apply(_ newBlock: CodeBlock) {
        let htmlChanged = newBlock.html != block.html
        block = newBlock
        frame = newBlock.frame
        setNeedsLayout()
        if htmlChanged { reload() }
    }

    // MARK: Edit mode

    func setEditing(_ editing: Bool) {
        isEditing = editing
        outline.isHidden = !editing
        toolbar.isHidden = !editing
        handles.forEach { $0.isHidden = !editing }
        applyInteractionState()
        setNeedsLayout()
    }

    /// Who may receive touches right now. The view itself always accepts them
    /// so `hitTest` can route by touch type; what changes is who is behind it.
    private func applyInteractionState() {
        isUserInteractionEnabled = true
        // Move/resize must not fire from a stray finger drag on a live block.
        bodyPan.isEnabled = isEditing
        // A finger operating the ACTIVE block suspends the canvas's drawing
        // gesture, so the touch never turns into a stray ink dot.
        fingerGuard.isEnabled = !isEditing && isActive
        // While editing, the block is an OBJECT being arranged, not a running
        // widget — the web content must not swallow the drag that moves it.
        // Inactive blocks are inert too: content only runs once activated.
        webView.isUserInteractionEnabled = !isEditing && isActive
        updateActiveHighlight()
    }

    /// "This block is live — a tap here presses IT, not the page."
    ///
    /// Deliberately NOT a lift shadow: an active block no longer rises above
    /// the ink (that would hide the very annotation drawn on it), so anything
    /// suggesting elevation would be a lie. A thin tinted ring reads as
    /// "focused / accepting input" without implying the block moved, and sits
    /// inside the bounds so it never overlaps neighbouring writing.
    private func updateActiveHighlight() {
        let live = isActive && !isEditing
        activeRing.isHidden = !live
        guard live else { return }
        activeRing.frame = bounds
        activeRing.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                       cornerRadius: 6).cgPath
    }

    // The toolbar sits above the block and the resize handles straddle the
    // corners — both extend outside `bounds`, where the default hit-test would
    // return nil. Extend the touch area to cover them while editing so the
    // edit-code / delete buttons and every handle are actually tappable.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, isUserInteractionEnabled else { return nil }

        if isEditing {
            if let hit = super.hitTest(point, with: event) { return hit }
            for sub in ([toolbar] as [UIView]) + handles where !sub.isHidden {
                let p = sub.convert(point, from: self)
                if let hit = sub.hitTest(p, with: event) { return hit }
            }
            return nil
        }

        // Normal mode the block is ALWAYS below the ink and never claims a
        // touch through the ordinary front-to-back hit-test — not even when
        // active. Raising it would hide the annotation drawn on top of it,
        // which is the whole point of a block living on a page.
        //
        // Touches reach an active block by REDIRECTION instead: the canvas
        // (see BlockRoutingCanvasView) sends touches landing inside the
        // active block's frame straight here, via `interactiveHit`.
        // Visual order and touch order are simply two different things.
        return nil
    }

    /// Entry point for the canvas's redirect: resolve a point (in this view's
    /// coordinates) to the web content, bypassing z-order entirely.
    func interactiveHit(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isActive, !isEditing, !isHidden else { return nil }
        guard bounds.contains(point) else { return nil }
        return webView.hitTest(convert(point, to: webView), with: event) ?? webView
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        guard isEditing else { return false }
        if !toolbar.isHidden, toolbar.frame.contains(point) { return true }
        for h in handles where !h.isHidden && h.frame.contains(point) { return true }
        return false
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        webView.frame = bounds
        outline.frame = bounds
        outline.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                                    cornerRadius: 6).cgPath
        updateActiveHighlight()

        let s = handleSize
        let positions = [
            CGPoint(x: 0, y: 0),                                  // TL
            CGPoint(x: bounds.width, y: 0),                       // TR
            CGPoint(x: 0, y: bounds.height),                      // BL
            CGPoint(x: bounds.width, y: bounds.height),           // BR
        ]
        for (i, h) in handles.enumerated() {
            h.frame = CGRect(x: positions[i].x - s / 2,
                             y: positions[i].y - s / 2,
                             width: s, height: s)
        }

        // Size the toolbar to its content so the buttons never clip.
        let fit = toolbar.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize,
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .fittingSizeLevel)
        let tw = max(fit.width, 72)
        let th = max(fit.height, 32)
        toolbar.frame = CGRect(x: 0, y: -(th + 8), width: tw, height: th)
    }

    // MARK: Gestures

    @objc private func handleBodyPan(_ g: UIPanGestureRecognizer) {
        guard isEditing else { return }
        let t = g.translation(in: superview)
        var f = frame
        f.origin.x += t.x
        f.origin.y = max(0, f.origin.y + t.y)
        f.origin.x = max(0, f.origin.x)
        frame = f
        g.setTranslation(.zero, in: superview)
        if g.state == .ended || g.state == .cancelled { commitGeometry() }
    }

    @objc private func handleResize(_ g: UIPanGestureRecognizer) {
        guard isEditing, let corner = g.view?.tag else { return }
        let t = g.translation(in: superview)
        var f = frame
        switch corner {
        case 0: // top-left
            f.origin.x += t.x; f.origin.y += t.y
            f.size.width -= t.x; f.size.height -= t.y
        case 1: // top-right
            f.origin.y += t.y
            f.size.width += t.x; f.size.height -= t.y
        case 2: // bottom-left
            f.origin.x += t.x
            f.size.width -= t.x; f.size.height += t.y
        default: // bottom-right
            f.size.width += t.x; f.size.height += t.y
        }
        // Enforce a minimum without letting the anchored edge drift.
        if f.size.width < minSize.width {
            if corner == 0 || corner == 2 { f.origin.x = frame.maxX - minSize.width }
            f.size.width = minSize.width
        }
        if f.size.height < minSize.height {
            if corner == 0 || corner == 1 { f.origin.y = frame.maxY - minSize.height }
            f.size.height = minSize.height
        }
        f.origin.x = max(0, f.origin.x)
        f.origin.y = max(0, f.origin.y)
        frame = f
        setNeedsLayout()
        g.setTranslation(.zero, in: superview)
        if g.state == .ended || g.state == .cancelled { commitGeometry() }
    }

    private func commitGeometry() {
        block.x = frame.origin.x
        block.y = frame.origin.y
        block.width = frame.size.width
        block.height = frame.size.height
        onChange?(block)
    }

    @objc private func tapEditCode() { onEditCode?(self) }
    @objc private func tapDelete() { onDelete?(self) }

    // Body pan must ignore touches that land on a handle or a control, so
    // resizing and the toolbar buttons win over dragging the whole block.
    /// The finger signal must never block the web content's own gestures —
    /// it only observes.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g == fingerGuard || other == fingerGuard
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if g == fingerGuard { return touch.type == .direct }
        guard g == bodyPan else { return true }
        if let v = touch.view {
            if handles.contains(v) { return false }
            if v is UIControl { return false }
            if v.isDescendant(of: toolbar) { return false }
        }
        return true
    }
}

// MARK: - Code editor sheet (SwiftUI)

/// Presented from the page's edit mode to edit a single block's source.
/// Mirrors `CodedPaperView`'s paper/code toggle: preview the rendered block
/// or edit its HTML/CSS/JS.
struct CodeBlockEditorView: View {
    let block: CodeBlock
    let onSave: (CodeBlock) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var html: String
    @State private var mode: Mode = .code

    private enum Mode: String, CaseIterable { case code, preview }

    init(block: CodeBlock, onSave: @escaping (CodeBlock) -> Void) {
        self.block = block
        self.onSave = onSave
        _html = State(initialValue: block.html)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .code:
                    TextEditor(text: $html)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        .padding(.horizontal, 8)
                case .preview:
                    BlockPreview(html: html)
                        .background(Color(.secondarySystemBackground))
                }
            }
            .navigationTitle("Code Block")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Mode", selection: $mode) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right").tag(Mode.code)
                        Image(systemName: "eye").tag(Mode.preview)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        var updated = block
                        updated.html = html
                        onSave(updated)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct BlockPreview: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastHTML = "" }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        web.loadHTMLString(CodedPaper.blockDocument(from: html),
                           baseURL: CodeBlockView.contentBaseURL)
    }
}
