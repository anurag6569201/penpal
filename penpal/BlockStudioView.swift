//
//  BlockStudioView.swift
//  penpal
//
//  The focused, full-screen editor for a single page block — the "expand"
//  half of the two-tier block model. On the page a block shows a compact
//  in-web toolbar (Arrange mode); opening the Studio renders that same block
//  large, in "studio" mode, so its full app chrome (toolbars, colour pickers,
//  inspectors) has room to breathe. Editing is live: the web content commits
//  straight back through the same bridge the on-page block uses, so what you
//  build here is exactly what lands on the paper.
//
//  A Source tab exposes the raw HTML/CSS/JS for power users, mirroring the
//  paper/code toggle of CodedPaperView.
//

import SwiftUI
import WebKit

struct BlockStudioView: View {
    let block: CodeBlock
    let onSave: (CodeBlock) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Drives whether the host presents this as a modal sheet or a full-screen
    /// cover. Toggled by the expand button in the toolbar.
    @Binding var expanded: Bool
    @State private var html: String
    @State private var mode: Mode
    /// The content as it was when the Studio opened, so Cancel can revert.
    @State private var original: String
    @State private var autosaveTask: Task<Void, Never>?
    /// Sheet size when presented as a modal (ignored in full-screen). A normal
    /// medium card by default — the toolbar's expand button is there for when
    /// the user wants the roomy full-screen canvas.
    @State private var detent: PresentationDetent = .medium

    private enum Mode: String, CaseIterable { case design, source }

    init(block: CodeBlock, expanded: Binding<Bool>, onSave: @escaping (CodeBlock) -> Void) {
        self.block = block
        self.onSave = onSave
        _expanded = expanded
        _html = State(initialValue: block.html)
        _original = State(initialValue: block.html)
        // Kinds without live chrome yet still get a useful design surface
        // (editable content), so default everything to the live editor.
        _mode = State(initialValue: .design)
    }

    /// Persist the given content back to the block on the page.
    private func persist(_ value: String) {
        var updated = block
        updated.html = value
        if updated.kind == nil { updated.kind = updated.resolvedKind }
        onSave(updated)
    }

    /// Save-as-you-go: every edit is persisted shortly after it happens, so
    /// leaving the Studio — even without tapping Done — never loses work.
    private func scheduleAutosave(_ value: String) {
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            await MainActor.run { persist(value) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .design:
                    LiveBlockEditor(html: $html)
                        .background(Color(.systemBackground))
                case .source:
                    TextEditor(text: $html)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        .padding(.horizontal, 8)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: html) { _, value in scheduleAutosave(value) }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Mode", selection: $mode) {
                        Image(systemName: "wand.and.stars").tag(Mode.design)
                        Image(systemName: "chevron.left.forwardslash.chevron.right").tag(Mode.source)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
                ToolbarItem(placement: .cancellationAction) {
                    // Changes are auto-saved as you go, so Cancel explicitly
                    // reverts to how the block was when the Studio opened.
                    Button("Revert") {
                        autosaveTask?.cancel()
                        persist(original)
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    // Expand into (or collapse out of) full-screen. Flush the
                    // current content first so the swap carries the latest edits.
                    Button {
                        autosaveTask?.cancel()
                        persist(html)
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded
                              ? "arrow.down.right.and.arrow.up.left"
                              : "arrow.up.left.and.arrow.down.right")
                    }
                    .help(expanded ? "Collapse" : "Full view")

                    Button("Done") {
                        autosaveTask?.cancel()
                        persist(html)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }

    private var title: String {
        switch block.resolvedKind {
        case .text: "Text Studio"
        case .table: "Table Studio"
        case .checklist: "Checklist Studio"
        case .image: "Image Studio"
        case .mermaid: "Diagram Studio"
        case .web: "Web Studio"
        case .code: "Code Studio"
        case .attachment: "Attachment Studio"
        }
    }
}

// MARK: - Live editing web view

/// Renders a block in "studio" mode and streams every content change back
/// into `html`, reusing the exact same runtime and serialization as the
/// on-page `CodeBlockView` so the Studio and the page can never diverge.
private struct LiveBlockEditor: UIViewRepresentable {
    @Binding var html: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: LiveBlockEditor
        /// The document source we last loaded — compared against the binding so
        /// Source-tab edits reload but live commits from the web do not.
        var lastLoaded = ""
        /// A commit that originated in the web view; skip the next reload.
        var fromWeb = false

        init(_ parent: LiveBlockEditor) { self.parent = parent }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "penpalBlockChanged",
                  let body = message.body as? [String: Any],
                  let html = body["html"] as? String,
                  !html.isEmpty,
                  html != parent.html else { return }
            fromWeb = true
            parent.html = html
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript(
                "window.penpalSetMode && window.penpalSetMode('studio')",
                completionHandler: nil)
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.addUserScript(WKUserScript(
            source: CodeBlockView.editingBridgeJavaScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true))
        config.userContentController.add(context.coordinator, name: "penpalBlockChanged")

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.contentInsetAdjustmentBehavior = .never
        #if DEBUG
        if #available(iOS 16.4, *) { web.isInspectable = true }
        #endif
        context.coordinator.lastLoaded = html
        web.loadHTMLString(CodedPaper.blockDocument(from: html),
                           baseURL: CodeBlockView.contentBaseURL)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        // A change that came from the web view must not trigger a reload —
        // that would blow away the caret and the current selection.
        if context.coordinator.fromWeb {
            context.coordinator.fromWeb = false
            context.coordinator.lastLoaded = html
            return
        }
        guard context.coordinator.lastLoaded != html else { return }
        context.coordinator.lastLoaded = html
        web.loadHTMLString(CodedPaper.blockDocument(from: html),
                           baseURL: CodeBlockView.contentBaseURL)
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController
            .removeScriptMessageHandler(forName: "penpalBlockChanged")
    }
}
