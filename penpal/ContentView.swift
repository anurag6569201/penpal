//
//  ContentView.swift
//  penpal
//
//  Apple Notes–style shell. Penpal brain only runs when the Penpal pen
//  is selected in the markup tray.
//

import SwiftUI
import PhotosUI
import PencilKit
import UniformTypeIdentifiers

final class PaperProxy {
    weak var view: MagicPaperView?
}

struct MagicPaper: UIViewRepresentable {
    let proxy: PaperProxy
    var settings: HandwritingSettings
    var penpalEnabled: Bool
    var onWritingStateChange: (Bool) -> Void
    var onThinkingChange: (Bool) -> Void
    var onStatus: (String) -> Void
    var onDrawingChange: (PKDrawing) -> Void
    var onUndoRedoChange: (Bool, Bool) -> Void
    var onTypedTextsChange: ([TypedNoteText]) -> Void
    var onReplyInksChange: ([ReplyInk]) -> Void

    func makeUIView(context: Context) -> MagicPaperView {
        let view = MagicPaperView()
        proxy.view = view
        apply(to: view)
        return view
    }

    func updateUIView(_ view: MagicPaperView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: MagicPaperView) {
        view.settings = settings
        view.penpalEnabled = penpalEnabled
        view.onWritingStateChange = onWritingStateChange
        view.onThinkingChange = onThinkingChange
        view.onStatus = onStatus
        view.onDrawingChange = onDrawingChange
        view.onUndoRedoChange = onUndoRedoChange
        view.onTypedTextsChange = onTypedTextsChange
        view.onReplyInksChange = onReplyInksChange
    }
}

struct ContentView: View {
    @StateObject private var store = NotesStore.shared
    @StateObject private var settings = HandwritingSettings.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var proxy = PaperProxy()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var toolsVisible = false
    @State private var penpalOn = false
    @State private var stickyHidden = true
    @State private var isWriting = false
    @State private var isThinking = false
    @State private var canUndo = false
    @State private var canRedo = false
    @State private var showTraining = false
    @State private var showSettings = false
    @State private var showPrefer = false
    @State private var naturalness: Double = 0.5
    @State private var statusMessage = ""
    @State private var showStatus = false
    @State private var showFormat = false
    @State private var showMoveNote = false
    @State private var showShare = false
    @State private var shareItems: [Any] = []
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var findQuery = ""
    @State private var showFind = false
    @State private var loadedNoteID: UUID?
    @State private var bodyText: String = ""
    @State private var titleText: String = ""
    @FocusState private var titleFocused: Bool
    @FocusState private var bodyFocused: Bool

    private let accentYellow = Color(red: 0.98, green: 0.76, blue: 0.11)

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            FoldersSidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 360)
        } content: {
            NotesListView(
                store: store,
                folderTitle: store.selectedFolder?.name ?? "Notes",
                onNewNote: createNote
            )
            .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 400)
        } detail: {
            editorDetail
        }
        .navigationSplitViewStyle(.balanced)
        .tint(accentYellow)
        .animation(.easeOut(duration: 0.25), value: showPrefer)
        .onAppear {
            syncEditorFromStore(force: true)
        }
        .onChange(of: store.selectedNoteID) { _, _ in
            syncEditorFromStore(force: true)
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding could land inside the save-debounce window and
            // lose the latest strokes if iOS killed the app — flush now.
            if phase == .background || phase == .inactive {
                flushEditor()
                store.flushToDisk()
            }
        }
        .onChange(of: penpalOn) { _, on in
            if on { proxy.view?.syncReplyBaselineToCurrentInk() }
        }
        .onChange(of: photoItem) { _, item in
            Task { await importPhoto(item) }
        }
        .sheet(isPresented: $showTraining) {
            CalibrationView()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled(true)
        }
        .sheet(isPresented: $showSettings) {
            PenpalSettingsView(settings: settings) { message in
                statusMessage = message
                showStatus = true
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showFormat) {
            formatSheet
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showMoveNote) {
            moveNoteSheet
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showShare) {
            ActivityView(items: shareItems)
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
        .alert("Penpal", isPresented: $showStatus) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(statusMessage)
        }
        .alert("Find in Note", isPresented: $showFind) {
            TextField("Search", text: $findQuery)
            Button("Cancel", role: .cancel) {}
            Button("Find") { performFind() }
        }
    }

    // MARK: - Editor detail

    private var editorDetail: some View {
        ZStack(alignment: .bottom) {
            Color(.systemBackground).ignoresSafeArea()

            if store.selectedNote != nil {
                noteSurface

                if penpalOn {
                    penpalBanner
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if showPrefer, settings.replyStyle == "hand", !isWriting, !isThinking {
                    preferenceBar
                        .padding(.bottom, penpalOn ? 76 : 28)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            } else {
                ContentUnavailableView("No Note Selected", systemImage: "note.text",
                                       description: Text("Choose a note or create one."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { editorToolbar }
        .toolbarRole(.editor)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: penpalOn)
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
                }
            } label: {
                Image(systemName: columnVisibility == .detailOnly
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    stickyHidden.toggle()
                }
                if !stickyHidden { flushEditor() }
            } label: {
                Image(systemName: stickyHidden ? "note.text.badge.plus" : "chevron.up.circle")
            }
            .disabled(store.selectedNote == nil)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { proxy.view?.undo() } label: {
                Image(systemName: "arrow.uturn.backward.circle")
            }
            .disabled(store.selectedNote == nil || !canUndo)
            .keyboardShortcut("z", modifiers: .command)

            Button { proxy.view?.redo() } label: {
                Image(systemName: "arrow.uturn.forward.circle")
            }
            .disabled(store.selectedNote == nil || !canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])

            Button { showFormat = true } label: {
                Image(systemName: "textformat.size")
            }
            .disabled(store.selectedNote == nil)

            Button(action: insertChecklist) {
                Image(systemName: "checklist")
            }
            .disabled(store.selectedNote == nil)

            Button { showPhotos = true } label: {
                Image(systemName: "paperclip")
            }
            .disabled(store.selectedNote == nil)

            // Native Apple Notes pen tray (PKToolPicker)
            Button {
                toolsVisible.toggle()
                proxy.view?.setToolsVisible(toolsVisible)
                if toolsVisible { bodyFocused = false }
            } label: {
                Image(systemName: toolsVisible ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
            }
            .disabled(store.selectedNote == nil)

            // Penpal mode — the special mode; only this makes ink get a reply.
            Button {
                penpalOn.toggle()
                if penpalOn {
                    if !toolsVisible {
                        toolsVisible = true
                        proxy.view?.setToolsVisible(true)
                    }
                    bodyFocused = false
                }
            } label: {
                Image(systemName: "signature")
                    .foregroundStyle(penpalOn ? Color.indigo : Color.primary)
            }
            .disabled(store.selectedNote == nil)

            Button(action: shareCurrentNote) {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(store.selectedNote == nil)

            Menu {
                moreActions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(store.selectedNote == nil)

            Button(action: createNote) {
                Image(systemName: "square.and.pencil")
            }
        }
    }

    private var penpalBanner: some View {
        HStack(spacing: 8) {
            if isWriting || isThinking {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "signature").foregroundStyle(.indigo)
            }
            Text(isThinking ? "Penpal is thinking…"
                 : (isWriting ? "Penpal is writing…" : "Penpal is on — write and it replies"))
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            Button {
                penpalOn = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.indigo.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
    }

    private var noteSurface: some View {
        // The page (handwriting canvas) fills everything; the heading/note
        // float on top as a compact, left-aligned sticky note that never
        // blocks writing below it.
        ZStack(alignment: .topLeading) {
            MagicPaper(
                proxy: proxy,
                settings: settings,
                penpalEnabled: penpalOn,
                onWritingStateChange: { writing in
                    isWriting = writing
                    if !writing, settings.replyStyle == "hand", penpalOn {
                        naturalness = Double(StyleRL.shared.lastNaturalness)
                        showPrefer = StyleRL.shared.hasCritic
                    }
                },
                onThinkingChange: { isThinking = $0 },
                onStatus: { message in
                    guard !message.isEmpty else { return }
                    statusMessage = message
                    showStatus = true
                    isThinking = false
                },
                onDrawingChange: { drawing in
                    store.updateSelectedDrawing(drawing)
                },
                onUndoRedoChange: { u, r in
                    canUndo = u
                    canRedo = r
                },
                onTypedTextsChange: { texts in
                    store.updateSelectedTypedTexts(texts)
                },
                onReplyInksChange: { inks in
                    store.updateSelectedReplyInks(inks)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !stickyHidden {
                stickyNoteCard
                    .padding(.leading, 20)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: stickyHidden)
    }

    private var stickyNoteCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "note.text")
                    .font(.caption2)
                Text(store.selectedNote?.modifiedAt.formatted(date: .abbreviated, time: .shortened) ?? "")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)

            TextField("Title", text: $titleText)
                .font(.headline.weight(.bold))
                .textFieldStyle(.plain)
                .focused($titleFocused)
                .submitLabel(.done)
                .onChange(of: titleText) { _, value in
                    store.updateSelectedTitle(value)
                }

            Divider()
                .padding(.vertical, 6)

            TextField("Take a note…", text: $bodyText, axis: .vertical)
                .font(.subheadline)
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1...5)
                .focused($bodyFocused)
                .onChange(of: bodyText) { _, value in
                    store.updateSelectedBody(value)
                }

            attachmentsStrip
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 1.0, green: 0.95, blue: 0.62))
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
        )
        .foregroundStyle(.black)
    }

    @ViewBuilder
    private var attachmentsStrip: some View {
        if let note = store.selectedNote, !note.attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(note.attachments) { att in
                        if let ui = UIImage(contentsOfFile: store.attachmentURL(att).path) {
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: ui)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 88, height: 88)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                Button {
                                    store.removeAttachment(att.id, from: note.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.white, .black.opacity(0.55))
                                }
                                .offset(x: 4, y: -4)
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Actions

    private func createNote() {
        flushEditor()
        _ = store.createNote(in: store.selectedFolderID)
        bodyFocused = false
    }

    private func syncEditorFromStore(force: Bool) {
        guard let note = store.selectedNote else {
            titleText = ""
            bodyText = ""
            loadedNoteID = nil
            return
        }
        if force || loadedNoteID != note.id {
            flushEditor()
            titleText = note.title
            bodyText = note.body
            loadedNoteID = note.id
            // Defer load until the representable has a view.
            DispatchQueue.main.async {
                self.proxy.view?.loadDrawing(note.drawing,
                                             typedTexts: note.typedTexts ?? [],
                                             replyInks: note.replyInks ?? [])
                if self.toolsVisible {
                    self.proxy.view?.setToolsVisible(true)
                }
            }
        }
    }

    private func flushEditor() {
        if let id = loadedNoteID, var note = store.notes.first(where: { $0.id == id }) {
            // If Penpal is mid-write, bake the reply into the drawing first so
            // it isn't lost when the note is saved/switched.
            proxy.view?.finalizePendingWriting()
            note.title = titleText
            note.body = bodyText
            if let view = proxy.view {
                note.drawing = view.currentDrawing
                note.typedTexts = view.currentTypedTexts
                note.replyInks = view.currentReplyInks
            }
            store.updateNote(note)
        }
    }

    private func insertChecklist() {
        bodyFocused = true
        if bodyText.isEmpty || bodyText.hasSuffix("\n") {
            bodyText += "☐ "
        } else {
            bodyText += "\n☐ "
        }
        store.updateSelectedBody(bodyText)
    }

    private func insertTable() {
        bodyFocused = true
        let table = """

| Column 1 | Column 2 | Column 3 |
| --- | --- | --- |
|  |  |  |
|  |  |  |
"""
        bodyText += table
        store.updateSelectedBody(bodyText)
    }

    private func shareCurrentNote() {
        flushEditor()
        guard let note = store.selectedNote else { return }
        var items: [Any] = []
        let text = [note.displayTitle, note.body]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        if !text.isEmpty { items.append(text) }
        let drawing = note.drawing
        if !drawing.strokes.isEmpty {
            let bounds = drawing.bounds.insetBy(dx: -40, dy: -40)
            let image = drawing.image(from: bounds, scale: 2)
            items.append(image)
        }
        for att in note.attachments {
            if let img = UIImage(contentsOfFile: store.attachmentURL(att).path) {
                items.append(img)
            }
        }
        guard !items.isEmpty else {
            statusMessage = "Nothing to share yet."
            showStatus = true
            return
        }
        shareItems = items
        showShare = true
    }

    private func performFind() {
        let q = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if bodyText.localizedCaseInsensitiveContains(q) || titleText.localizedCaseInsensitiveContains(q) {
            bodyFocused = true
            statusMessage = "Found “\(q)” in this note."
        } else {
            statusMessage = "“\(q)” not found in this note."
        }
        showStatus = true
    }

    @MainActor
    private func importPhoto(_ item: PhotosPickerItem?) async {
        guard let item, let noteID = store.selectedNoteID else { return }
        defer { photoItem = nil }
        do {
            if let data = try await item.loadTransferable(type: Data.self) {
                _ = store.addAttachment(imageData: data, to: noteID)
                return
            }
            statusMessage = "Couldn't add photo."
            showStatus = true
        } catch {
            // Fallback: try raw image data via Transferable image representation.
            if let data = try? await item.loadTransferable(type: PhotoData.self)?.data {
                _ = store.addAttachment(imageData: data, to: noteID)
            } else {
                statusMessage = "Couldn't add photo."
                showStatus = true
            }
        }
    }

    @ViewBuilder
    private var moreActions: some View {
        Button("Find in Note", systemImage: "magnifyingglass") { showFind = true }
        Button("Move Note", systemImage: "folder") { showMoveNote = true }
        Button("Add Page", systemImage: "plus.rectangle.portrait") { proxy.view?.addPage() }
        Button("Erase Penpal Replies", systemImage: "eraser") { proxy.view?.clearPenpalContent() }
        Divider()
        Button("Train Handwriting", systemImage: "signature") { showTraining = true }
        Button("Penpal Settings", systemImage: "slider.horizontal.3") { showSettings = true }
        Divider()
        if let note = store.selectedNote {
            if note.isDeleted {
                Button("Recover Note", systemImage: "arrow.uturn.backward") { store.restoreNote(note.id) }
                Button("Delete Immediately", systemImage: "trash", role: .destructive) {
                    store.deleteNote(note.id, permanently: true)
                }
            } else {
                Button("Delete Note", systemImage: "trash", role: .destructive) {
                    store.deleteNote(note.id)
                }
            }
        }
    }

    private var formatSheet: some View {
        NavigationStack {
            Form {
                Section("Insert") {
                    Button("Heading", systemImage: "textformat.size.larger") { wrapBody(prefix: "# ", suffix: "") }
                    Button("Bold", systemImage: "bold") { wrapBody(prefix: "**", suffix: "**") }
                    Button("Italic", systemImage: "italic") { wrapBody(prefix: "_", suffix: "_") }
                    Button("Monospaced", systemImage: "chevron.left.forwardslash.chevron.right") { wrapBody(prefix: "`", suffix: "`") }
                }
                Section("Lists") {
                    Button("Bulleted list") {
                        bodyText += bodyText.isEmpty || bodyText.hasSuffix("\n") ? "• " : "\n• "
                        store.updateSelectedBody(bodyText)
                    }
                    Button("Numbered list") {
                        bodyText += bodyText.isEmpty || bodyText.hasSuffix("\n") ? "1. " : "\n1. "
                        store.updateSelectedBody(bodyText)
                    }
                    Button("Checklist") { insertChecklist() }
                }
                Section {
                    Toggle("Show drawing tools", isOn: Binding(
                        get: { toolsVisible },
                        set: { toolsVisible = $0; proxy.view?.setToolsVisible($0) }
                    ))
                    Toggle("Penpal mode", isOn: $penpalOn)
                } footer: {
                    Text("Drawing tools are the system pen tray. Penpal mode reads your writing and replies.")
                }
            }
            .navigationTitle("Format")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showFormat = false }
                }
            }
        }
    }

    private func wrapBody(prefix: String, suffix: String) {
        bodyFocused = true
        if bodyText.isEmpty {
            bodyText = prefix + suffix
        } else if bodyText.hasSuffix("\n") {
            bodyText += prefix + suffix
        } else {
            bodyText += "\n" + prefix + suffix
        }
        store.updateSelectedBody(bodyText)
    }

    private var moveNoteSheet: some View {
        NavigationStack {
            List {
                ForEach(store.movableFolders()) { folder in
                    Button {
                        if let id = store.selectedNoteID {
                            store.moveNote(id, to: folder.id)
                        }
                        showMoveNote = false
                    } label: {
                        Label(folder.name, systemImage: "folder")
                    }
                }
            }
            .navigationTitle("Move Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showMoveNote = false }
                }
            }
        }
    }

    private var preferenceBar: some View {
        HStack(spacing: 14) {
            Text("Looks like you?")
                .font(.footnote.weight(.medium))
            Text("\(Int(naturalness * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                StyleRL.shared.prefer(liked: true)
                showPrefer = false
            } label: {
                Image(systemName: "hand.thumbsup.fill")
            }
            .buttonStyle(.borderedProminent)
            Button {
                StyleRL.shared.prefer(liked: false)
                showPrefer = false
            } label: {
                Image(systemName: "hand.thumbsdown.fill")
            }
            .buttonStyle(.bordered)
            Button {
                showPrefer = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

// MARK: - Share sheet

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct PhotoData: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .jpeg) { data in
            PhotoData(data: data)
        }
        DataRepresentation(importedContentType: .png) { data in
            PhotoData(data: data)
        }
        DataRepresentation(importedContentType: .heic) { data in
            PhotoData(data: data)
        }
        DataRepresentation(importedContentType: .image) { data in
            PhotoData(data: data)
        }
    }
}

#Preview {
    ContentView()
}
