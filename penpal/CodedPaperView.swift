//
//  CodedPaperView.swift
//  penpal
//
//  A "coded paper": the note is not an ink canvas but a rendered HTML page.
//  Whatever the web can do — CSS, JS, canvas, CDN libraries — can live on
//  this paper. Toggle between the rendered page and its source code.
//

import SwiftUI
import WebKit

// MARK: - Starter template

enum CodedPaper {

    /// Seed content for a freshly created coded paper. Shows that HTML, CSS
    /// and JS all work, styled to still feel like a sheet of paper.
    static let starterHTML = """
    <!-- Coded Paper: this page IS the note.
         Plain HTML + CSS + JS. You can load any library from a CDN,
         e.g. <script src="https://cdn.jsdelivr.net/npm/katex@0.16/dist/katex.min.js"></script> -->
    <style>
      h1 { margin: 0 0 6px; font-size: 28px; }
      .chip {
        display: inline-block; padding: 2px 12px; border-radius: 999px;
        background: rgba(255, 214, 10, 0.28); font-size: 13px; font-weight: 600;
      }
      button {
        font: inherit; padding: 8px 18px; border-radius: 10px;
        border: 1px solid rgba(99, 102, 241, 0.4);
        background: rgba(99, 102, 241, 0.12); color: inherit;
      }
      canvas { width: 100%; height: 120px; display: block; margin-top: 18px; }
    </style>

    <h1>Coded Paper</h1>
    <p><span class="chip">HTML + CSS + JS</span></p>
    <p>This sheet is a live web page. Tap the <strong>&lt;/&gt;</strong> toggle
       in the corner to edit its code — anything the web can do can live here.</p>
    <button id="tap">Tapped 0 times</button>
    <canvas id="wave"></canvas>

    <script>
      let n = 0;
      const b = document.getElementById('tap');
      b.addEventListener('click', () => { b.textContent = `Tapped ${++n} times`; });

      const c = document.getElementById('wave');
      const g = c.getContext('2d');
      c.width  = c.clientWidth  * devicePixelRatio;
      c.height = c.clientHeight * devicePixelRatio;
      g.strokeStyle = '#6366f1';
      g.lineWidth = 2 * devicePixelRatio;
      g.beginPath();
      for (let x = 0; x < c.width; x++) {
        const y = c.height / 2 + Math.sin(x / (18 * devicePixelRatio)) * c.height / 3;
        x === 0 ? g.moveTo(x, y) : g.lineTo(x, y);
      }
      g.stroke();
    </script>
    """

    /// Wraps a fragment in a minimal paper-styled document. If the source is
    /// already a full document (<html> / <!doctype>), it is used untouched.
    static func fullDocument(from source: String) -> String {
        let lowered = source.lowercased()
        if lowered.contains("<html") || lowered.contains("<!doctype") {
            return source
        }
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <style>
          :root { color-scheme: light dark; }
          html, body { margin: 0; background: transparent; }
          body {
            padding: 28px 32px 60px;
            font: 17px/1.65 -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif;
            color: #1c1c1e;
            -webkit-text-size-adjust: 100%;
          }
          @media (prefers-color-scheme: dark) { body { color: #ececf0; } }
        </style>
        </head>
        <body>
        \(source)
        </body>
        </html>
        """
    }
}

// MARK: - View

struct CodedPaperView: View {
    @ObservedObject var store: NotesStore

    private enum Mode: String, CaseIterable {
        case paper
        case code
    }

    @State private var mode: Mode = .paper
    @State private var html: String = ""
    @State private var renderedHTML: String = ""
    @State private var loadedNoteID: UUID?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(.systemBackground).ignoresSafeArea()

            switch mode {
            case .paper:
                WebPaper(html: renderedHTML)
                    .ignoresSafeArea(edges: .bottom)
            case .code:
                codeEditor
            }

            modeToggle
                .padding(.trailing, 16)
                .padding(.top, 10)
        }
        .onAppear { syncFromStore() }
        .onChange(of: store.selectedNoteID) { _, _ in syncFromStore() }
        .onChange(of: html) { _, value in scheduleSave(value) }
        .onChange(of: mode) { _, newMode in
            if newMode == .paper {
                commitNow()
                renderedHTML = CodedPaper.fullDocument(from: html)
            }
        }
        .onDisappear { commitNow() }
    }

    // MARK: Subviews

    private var modeToggle: some View {
        Picker("Mode", selection: $mode) {
            Image(systemName: "doc.richtext").tag(Mode.paper)
            Image(systemName: "chevron.left.forwardslash.chevron.right").tag(Mode.code)
        }
        .pickerStyle(.segmented)
        .frame(width: 130)
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }

    private var codeEditor: some View {
        TextEditor(text: $html)
            .font(.system(.footnote, design: .monospaced))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.asciiCapable)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 12)
            .padding(.top, 52)   // clear the floating toggle
            .background(Color(.secondarySystemBackground).ignoresSafeArea())
    }

    // MARK: Sync

    private func syncFromStore() {
        guard let note = store.selectedNote, note.isCoded else { return }
        guard loadedNoteID != note.id else { return }
        commitNow()   // don't lose pending edits of the previous coded paper
        loadedNoteID = note.id
        html = note.htmlContent ?? CodedPaper.starterHTML
        renderedHTML = CodedPaper.fullDocument(from: html)
        mode = .paper
    }

    private func scheduleSave(_ value: String) {
        guard let id = loadedNoteID else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            store.updateHTML(value, for: id)
        }
    }

    private func commitNow() {
        guard let id = loadedNoteID else { return }
        saveTask?.cancel()
        store.updateHTML(html, for: id)
    }
}

// MARK: - WKWebView wrapper

private struct WebPaper: UIViewRepresentable {
    let html: String

    final class Coordinator {
        var lastHTML = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: config)
        // Transparent so the page sits on the app's paper background —
        // the web content should feel like part of the note, not a browser.
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.contentInsetAdjustmentBehavior = .never
        #if DEBUG
        if #available(iOS 16.4, *) { web.isInspectable = true }
        #endif
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        web.loadHTMLString(html, baseURL: nil)
    }
}
