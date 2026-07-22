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

final class CodeBlockView: UIView, UIGestureRecognizerDelegate, WKNavigationDelegate,
                           WKScriptMessageHandler {

    /// Documents loaded with `baseURL: nil` get a NULL origin: WebKit then
    /// refuses storage, denies resource loads ("Couldn't open … Permission
    /// denied") and disables anything needing a secure context. A block that
    /// renders a real simulation needs a real origin, and `https://localhost`
    /// gives it one without touching the network.
    static let contentBaseURL = URL(string: "https://localhost/")

    private static let editingBridgeJavaScript = """
    (() => {
      let timer = null;
      let selectedCell = null;
      const editable = () => {
        document.querySelectorAll(
          '[data-penpal-editable], td, th, .penpal-item-text'
        ).forEach(el => {
          el.setAttribute('contenteditable', 'true');
          el.style.webkitUserSelect = 'text';
          el.style.userSelect = 'text';
        });
      };
      const commit = () => {
        clearTimeout(timer);
        timer = setTimeout(() => {
          window.webkit.messageHandlers.penpalBlockChanged.postMessage({
            html: document.body.innerHTML
          });
        }, 180);
      };
      const immediateCommit = () => {
        clearTimeout(timer);
        window.webkit.messageHandlers.penpalBlockChanged.postMessage({
          html: document.body.innerHTML
        });
      };
      document.addEventListener('focusin', event => {
        if (event.target.matches('td,th')) selectedCell = event.target;
      }, true);
      document.addEventListener('input', commit, true);
      document.addEventListener('change', event => {
        if (event.target.matches('input[type=checkbox]')) {
          event.target.toggleAttribute('checked', event.target.checked);
        }
        immediateCommit();
      }, true);

      window.penpalBlockCommand = command => {
        const [kind, operation] = command.split(':');
        if (kind === 'table') {
          const table = document.querySelector('table');
          if (!table) return;
          const rows = Array.from(table.rows);
          const columnCount = Math.max(1, ...rows.map(row => row.cells.length));
          if (operation === 'addRow') {
            const body = table.tBodies[0] || table.createTBody();
            const selectedRow = selectedCell?.closest('tr');
            const insertAt = selectedRow?.parentElement === body
              ? selectedRow.sectionRowIndex + 1 : body.rows.length;
            const row = body.insertRow(insertAt);
            for (let index = 0; index < columnCount; index++) {
              row.insertCell().textContent = '';
            }
          } else if (operation === 'removeRow') {
            const body = table.tBodies[0];
            if (body && body.rows.length > 1) {
              const selectedRow = selectedCell?.closest('tr');
              const index = selectedRow?.parentElement === body
                ? selectedRow.sectionRowIndex : body.rows.length - 1;
              body.deleteRow(index);
              selectedCell = null;
            }
          } else if (operation === 'addColumn') {
            const selectedIndex = selectedCell?.cellIndex ?? columnCount - 1;
            rows.forEach(row => {
              const cell = row.parentElement?.tagName === 'THEAD'
                ? document.createElement('th') : document.createElement('td');
              cell.textContent = '';
              row.insertBefore(cell, row.cells[selectedIndex + 1] || null);
            });
          } else if (operation === 'removeColumn') {
            const selectedIndex = selectedCell?.cellIndex ?? columnCount - 1;
            if (columnCount > 1) rows.forEach(row => {
              if (row.cells[selectedIndex]) row.deleteCell(selectedIndex);
            });
            selectedCell = null;
          } else if (operation === 'toggleHeader') {
            let head = table.tHead;
            if (head) {
              const old = head.rows[0];
              const replacement = document.createElement('tr');
              Array.from(old.cells).forEach(cell => {
                const next = document.createElement('td');
                next.innerHTML = cell.innerHTML;
                replacement.appendChild(next);
              });
              table.tBodies[0].insertBefore(replacement, table.tBodies[0].firstChild);
              head.remove();
            } else {
              const body = table.tBodies[0];
              const old = body?.rows[0];
              if (old) {
                head = table.createTHead();
                const replacement = document.createElement('tr');
                Array.from(old.cells).forEach(cell => {
                  const next = document.createElement('th');
                  next.innerHTML = cell.innerHTML;
                  replacement.appendChild(next);
                });
                head.appendChild(replacement);
                old.remove();
              }
            }
          } else if (operation.startsWith('align')) {
            const alignment = operation.replace('align', '').toLowerCase();
            (selectedCell ? [selectedCell] : Array.from(table.querySelectorAll('td,th')))
              .forEach(cell => cell.style.textAlign = alignment);
          } else if (operation === 'merge' && selectedCell) {
            const next = selectedCell.nextElementSibling;
            if (next) {
              selectedCell.colSpan = (selectedCell.colSpan || 1) + (next.colSpan || 1);
              selectedCell.innerHTML += next.innerHTML ? ' ' + next.innerHTML : '';
              next.remove();
            }
          } else if (operation === 'split' && selectedCell && selectedCell.colSpan > 1) {
            selectedCell.colSpan -= 1;
            selectedCell.parentElement.insertBefore(
              document.createElement(selectedCell.tagName.toLowerCase()),
              selectedCell.nextSibling
            );
          } else if (operation === 'clear') {
            table.querySelectorAll('td,th').forEach(cell => cell.textContent = '');
          }
        } else if (kind === 'checklist') {
          const list = document.querySelector('.list');
          if (!list) return;
          if (operation === 'add') {
            const label = document.createElement('label');
            label.innerHTML =
              '<input type="checkbox"><span class="penpal-item-text" contenteditable="true">New item</span>';
            list.appendChild(label);
          } else if (operation === 'remove' && list.lastElementChild) {
            list.lastElementChild.remove();
          } else if (operation === 'clearCompleted') {
            list.querySelectorAll('input:checked').forEach(input => input.closest('label')?.remove());
          } else if (operation === 'uncheck') {
            list.querySelectorAll('input').forEach(input => {
              input.checked = false; input.removeAttribute('checked');
            });
          }
        } else if (kind === 'text') {
          const text = document.querySelector('[data-penpal-editable]');
          if (!text) return;
          if (operation === 'body') text.style.fontSize = '16px';
          if (operation === 'heading') text.style.fontSize = '24px';
          if (operation === 'callout') {
            text.style.borderLeft = '4px solid #4A4E9E';
            text.style.paddingLeft = '14px';
          }
          if (operation === 'left') text.style.textAlign = 'left';
          if (operation === 'center') text.style.textAlign = 'center';
        } else if (kind === 'image') {
          const image = document.querySelector('img');
          if (!image) return;
          if (operation === 'fit') image.style.objectFit = 'contain';
          if (operation === 'fill') image.style.objectFit = 'cover';
          const current = Number(image.dataset.rotation || 0);
          if (operation === 'rotateLeft') image.dataset.rotation = current - 90;
          if (operation === 'rotateRight') image.dataset.rotation = current + 90;
          image.style.transform = `rotate(${image.dataset.rotation || current}deg)`;
        }
        editable();
        immediateCommit();
      };
      editable();
    })();
    """

    private(set) var block: CodeBlock

    private let webView: WKWebView
    private let outline = CAShapeLayer()
    /// Quiet "accepting input" ring shown while the block is active.
    private let activeRing = CAShapeLayer()
    private var handles: [UIView] = []
    private let toolbar = UIStackView()
    private lazy var contextButton = makeMenuButton(
        system: block.resolvedKind.toolbarIcon,
        menu: makeContextMenu()
    )

    /// Fired when geometry changes (move/resize finished) so the note persists.
    var onChange: ((CodeBlock) -> Void)?
    /// Fired when the user taps the block's edit-code button.
    var onEditCode: ((CodeBlockView) -> Void)?
    /// Fired when the user taps the block's delete button.
    var onDelete: ((CodeBlockView) -> Void)?
    var onDuplicate: ((CodeBlockView) -> Void)?
    var onBringForward: ((CodeBlockView) -> Void)?
    var onSendBackward: ((CodeBlockView) -> Void)?

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
        config.userContentController.addUserScript(WKUserScript(
            source: Self.editingBridgeJavaScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: block.frame)
        config.userContentController.add(self, name: "penpalBlockChanged")
        setup()
        webView.navigationDelegate = self
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "penpalBlockChanged")
    }

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
        toolbar.addArrangedSubview(contextButton)
        toolbar.addArrangedSubview(makeToolButton(system: "pencil",
                                                  action: #selector(tapEditCode)))
        toolbar.addArrangedSubview(makeToolButton(system: "plus.square.on.square",
                                                  action: #selector(tapDuplicate)))
        toolbar.addArrangedSubview(makeMenuButton(
            system: "square.2.layers.3d",
            menu: UIMenu(children: [
                UIAction(title: "Bring Forward", image: UIImage(systemName: "square.2.layers.3d.top.filled")) {
                    [weak self] _ in guard let self else { return }; self.onBringForward?(self)
                },
                UIAction(title: "Send Backward", image: UIImage(systemName: "square.2.layers.3d.bottom.filled")) {
                    [weak self] _ in guard let self else { return }; self.onSendBackward?(self)
                },
            ])
        ))
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

    private func makeMenuButton(system: String, menu: UIMenu) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: system)
        config.baseForegroundColor = .tintColor
        config.preferredSymbolConfigurationForImage =
            UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        config.contentInsets = .init(top: 4, leading: 6, bottom: 4, trailing: 6)
        let button = UIButton(configuration: config)
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
        return button
    }

    private func action(_ title: String, system: String,
                        command: String) -> UIAction {
        UIAction(title: title, image: UIImage(systemName: system)) { [weak self] _ in
            self?.runBlockCommand(command)
        }
    }

    private func makeContextMenu() -> UIMenu {
        switch block.resolvedKind {
        case .table:
            return UIMenu(title: "Table", children: [
                action("Add Row", system: "rectangle.split.1x2", command: "table:addRow"),
                action("Remove Row", system: "minus.rectangle", command: "table:removeRow"),
                action("Add Column", system: "rectangle.split.2x1", command: "table:addColumn"),
                action("Remove Column", system: "minus.rectangle", command: "table:removeColumn"),
                action("Toggle Header", system: "bold", command: "table:toggleHeader"),
                UIMenu(title: "Cell Alignment", image: UIImage(systemName: "text.alignleft"),
                       children: [
                        action("Left", system: "text.alignleft", command: "table:alignLeft"),
                        action("Center", system: "text.aligncenter", command: "table:alignCenter"),
                        action("Right", system: "text.alignright", command: "table:alignRight"),
                       ]),
                action("Merge With Next Cell", system: "rectangle.2.swap", command: "table:merge"),
                action("Split Cell", system: "rectangle.split.2x1", command: "table:split"),
                action("Clear Table", system: "eraser", command: "table:clear"),
            ])
        case .checklist:
            return UIMenu(title: "Checklist", children: [
                action("Add Item", system: "plus", command: "checklist:add"),
                action("Remove Last Item", system: "minus", command: "checklist:remove"),
                action("Clear Completed", system: "checkmark.circle", command: "checklist:clearCompleted"),
                action("Uncheck All", system: "circle", command: "checklist:uncheck"),
            ])
        case .text:
            return UIMenu(title: "Text", children: [
                action("Body Style", system: "textformat", command: "text:body"),
                action("Heading Style", system: "textformat.size.larger", command: "text:heading"),
                action("Callout Style", system: "quote.bubble", command: "text:callout"),
                action("Align Left", system: "text.alignleft", command: "text:left"),
                action("Align Center", system: "text.aligncenter", command: "text:center"),
            ])
        case .image:
            return UIMenu(title: "Image", children: [
                action("Fit", system: "arrow.down.right.and.arrow.up.left", command: "image:fit"),
                action("Fill", system: "arrow.up.left.and.arrow.down.right", command: "image:fill"),
                action("Rotate Left", system: "rotate.left", command: "image:rotateLeft"),
                action("Rotate Right", system: "rotate.right", command: "image:rotateRight"),
            ])
        case .mermaid:
            return UIMenu(title: "Diagram", children: [
                UIAction(title: "Edit Mermaid Source", image: UIImage(systemName: "pencil")) {
                    [weak self] _ in guard let self else { return }; self.onEditCode?(self)
                },
                UIAction(title: "Reload Diagram", image: UIImage(systemName: "arrow.clockwise")) {
                    [weak self] _ in self?.reload()
                },
            ])
        case .web:
            return UIMenu(title: "Web Block", children: [
                UIAction(title: "Edit Source", image: UIImage(systemName: "pencil")) {
                    [weak self] _ in guard let self else { return }; self.onEditCode?(self)
                },
                UIAction(title: "Reload", image: UIImage(systemName: "arrow.clockwise")) {
                    [weak self] _ in self?.reload()
                },
            ])
        case .code:
            return UIMenu(title: "Code Block", children: [
                UIAction(title: "Edit Source", image: UIImage(systemName: "pencil")) {
                    [weak self] _ in guard let self else { return }; self.onEditCode?(self)
                },
                UIAction(title: "Run / Reload", image: UIImage(systemName: "play")) {
                    [weak self] _ in self?.reload()
                },
            ])
        }
    }

    // MARK: Content

    func reload() {
        webView.loadHTMLString(CodedPaper.blockDocument(from: block.html),
                               baseURL: Self.contentBaseURL)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "penpalBlockChanged",
              let body = message.body as? [String: Any],
              let html = body["html"] as? String,
              !html.isEmpty,
              html != block.html else { return }
        block.html = html
        if block.kind == nil { block.kind = block.resolvedKind }
        onChange?(block)
    }

    private func runBlockCommand(_ command: String) {
        webView.evaluateJavaScript("window.penpalBlockCommand('\(command)')") {
            [weak self] _, error in
            if error != nil { self?.reload() }
        }
    }

    /// Apply an edited model (new code and/or geometry) and re-render.
    func apply(_ newBlock: CodeBlock) {
        let htmlChanged = newBlock.html != block.html
        let kindChanged = newBlock.resolvedKind != block.resolvedKind
        block = newBlock
        frame = newBlock.frame
        if kindChanged {
            contextButton.configuration?.image = UIImage(systemName: block.resolvedKind.toolbarIcon)
            contextButton.menu = makeContextMenu()
        }
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
    @objc private func tapDuplicate() { onDuplicate?(self) }
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

private extension PageBlockKind {
    var toolbarIcon: String {
        switch self {
        case .code: "chevron.left.forwardslash.chevron.right"
        case .mermaid: "point.3.connected.trianglepath.dotted"
        case .text: "text.quote"
        case .table: "tablecells"
        case .checklist: "checklist"
        case .image: "photo"
        case .web: "globe"
        }
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
