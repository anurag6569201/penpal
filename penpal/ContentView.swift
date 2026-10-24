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
import UIKit

final class PaperProxy {
    weak var view: MagicPaperView?
}

struct MagicPaper: UIViewRepresentable {
    let proxy: PaperProxy
    var settings: HandwritingSettings
    var penpalEnabled: Bool
    var pageWidth: CGFloat
    var onWritingStateChange: (Bool) -> Void
    var onThinkingChange: (Bool) -> Void
    var onReadingChange: (Bool) -> Void
    var onStatus: (String) -> Void
    var onInteractivePermissionRequest: (
        InteractivePermissionPrompt,
        @escaping (InteractivePermissionDecision) -> Void
    ) -> Void
    var onDrawingChange: (PKDrawing) -> Void
    var onUndoRedoChange: (Bool, Bool) -> Void
    var onTypedTextsChange: ([TypedNoteText]) -> Void
    var onReplyInksChange: ([ReplyInk]) -> Void
    var onCodeBlocksChange: ([CodeBlock]) -> Void
    var onRequestEditCodeBlock: (CodeBlock) -> Void
    var onPageEditModeChange: (Bool) -> Void
    var onMarkupOpened: () -> Void

    func makeUIView(context: Context) -> PaperViewport {
        let viewport = PaperViewport()
        viewport.pageWidth = pageWidth
        proxy.view = viewport.paperView
        apply(to: viewport.paperView)
        return viewport
    }

    func updateUIView(_ viewport: PaperViewport, context: Context) {
        viewport.pageWidth = pageWidth
        apply(to: viewport.paperView)
    }

    private func apply(to view: MagicPaperView) {
        view.settings = settings
        view.penpalEnabled = penpalEnabled
        view.onWritingStateChange = onWritingStateChange
        view.onThinkingChange = onThinkingChange
        view.onReadingChange = onReadingChange
        view.onStatus = onStatus
        view.onInteractivePermissionRequest = onInteractivePermissionRequest
        view.onDrawingChange = onDrawingChange
        view.onUndoRedoChange = onUndoRedoChange
        view.onTypedTextsChange = onTypedTextsChange
        view.onReplyInksChange = onReplyInksChange
        view.onCodeBlocksChange = onCodeBlocksChange
        view.onRequestEditCodeBlock = onRequestEditCodeBlock
        view.onPageEditModeChange = onPageEditModeChange
        view.onMarkupOpened = onMarkupOpened
    }
}

private struct PendingInteractivePermission: Identifiable {
    let prompt: InteractivePermissionPrompt
    let completion: (InteractivePermissionDecision) -> Void
    var id: UUID { prompt.id }
}

struct ContentView: View {
    @StateObject private var store = NotesStore.shared
    @StateObject private var settings = HandwritingSettings.shared
    @StateObject private var outbox = Outbox.shared
    @StateObject private var onboarding = GestureOnboarding.shared
    @StateObject private var voice = VoiceInput.shared
    @StateObject private var planner = StudyPlanner.shared
    /// The practice item awaiting a verdict, if one is on the page.
    @State private var practiceInProgress: (id: UUID, item: PenpalAPI.PracticeProblem)?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pageWidth: CGFloat = 768
    @State private var editorToolbarHeight: CGFloat = 56
    @State private var proxy = PaperProxy()
    @State private var navigationDrawerPresented = false
    @State private var toolsVisible = false
    @State private var penpalOn = false
    @State private var stickyHidden = true
    @State private var isWriting = false
    @State private var isThinking = false
    @State private var isReading = false
    @State private var canUndo = false
    @State private var canRedo = false
    @State private var showTraining = false
    @State private var showSettings = false
    @State private var showPrefer = false
    @State private var showMathChips = false
    @State private var statusMessage = ""
    @State private var showStatus = false
    @State private var activePermission: PendingInteractivePermission?
    @State private var permissionQueue: [PendingInteractivePermission] = []
    @State private var showShare = false
    @State private var shareItems: [Any] = []
    @State private var isPreparingShare = false
    @State private var activeLoadingOperation: (id: UUID, message: String)?
    @State private var isGeneratingPractice = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotos = false
    /// PEN-35 — photo import uses its own picker binding, distinct from the
    /// plain photo attachment above: a selection here is READ and rebuilt as
    /// page content (ink + image blocks), not just dropped on as a picture.
    @State private var importPhotoItem: PhotosPickerItem?
    @State private var showImportPhotos = false
    /// PEN-39 — external visual input. Kept separate from PEN-35 because this
    /// asks a capability to respond; it does not rebuild the photo as a page.
    @State private var visionPhotoItem: PhotosPickerItem?
    @State private var showVisionPhotos = false
    @State private var showVisionCamera = false
    @State private var loadedNoteID: UUID?
    @State private var bodyText: String = ""
    @State private var titleText: String = ""
    /// Page edit mode: arrange/edit embedded code blocks (move/resize/edit).
    @State private var pageEditMode = false
    /// The code block currently being edited in the source sheet, if any.
    @State private var editingCodeBlock: CodeBlock?
    /// Whether the Block Studio is expanded to a full-screen cover. Off by
    /// default so editing stays a modal layered over the notes page.
    @State private var studioFullScreen = false

    /// The Studio is presented as a sheet unless the user asks for full view;
    /// these bindings route the same `editingCodeBlock` to whichever container
    /// is active so toggling `studioFullScreen` swaps between them in place.
    private var studioSheetItem: Binding<CodeBlock?> {
        Binding(
            get: { studioFullScreen ? nil : editingCodeBlock },
            set: { if $0 == nil { editingCodeBlock = nil; studioFullScreen = false } }
        )
    }

    private var studioFullScreenItem: Binding<CodeBlock?> {
        Binding(
            get: { studioFullScreen ? editingCodeBlock : nil },
            set: { if $0 == nil { editingCodeBlock = nil; studioFullScreen = false } }
        )
    }

    /// Persist a Studio edit to the page and keep `editingCodeBlock` in sync so
    /// swapping sheet ↔ full view carries the latest content across.
    private func studioSave(_ updated: CodeBlock) {
        proxy.view?.updateCodeBlock(updated)
        if editingCodeBlock?.id == updated.id { editingCodeBlock = updated }
    }
    @FocusState private var titleFocused: Bool
    @FocusState private var bodyFocused: Bool

    // Warm Paper: one accent for the whole app. The previous Notes-yellow
    // chrome made Penpal's indigo presence read as a third-party add-on
    // inside someone else's app; now the shell and the pen are one hand.
    private let accent = Pen.inkAccent
    private let editorToolbarTopInset: CGFloat = 8
    private let toolbarToStickyNoteGap: CGFloat = 16
    @State private var penpalDockHeight: CGFloat = 48
    private var penpalBarClearance: CGFloat { penpalDockHeight + 12 }
    private let stackedOverlayGap: CGFloat = 54

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let drawerWidth = min(380, max(280, geometry.size.width - 32))

                ZStack(alignment: .leading) {
                    editorDetail(
                        stickyNoteTop: geometry.safeAreaInsets.top
                            + editorToolbarTopInset
                            + editorToolbarHeight
                            + toolbarToStickyNoteGap
                    )

                    Color.black.opacity(navigationDrawerPresented ? 0.16 : 0)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { closeNavigationDrawer() }
                        .allowsHitTesting(navigationDrawerPresented)
                        .accessibilityHidden(true)

                    NavigationDrawerView(
                        store: store,
                        isPresented: navigationDrawerPresented,
                        onSelectNote: { noteID in
                            store.selectNote(noteID)
                            closeNavigationDrawer()
                        },
                        onNewNote: {
                            createNote()
                            closeNavigationDrawer()
                        },
                        onClose: closeNavigationDrawer
                    )
                    .frame(width: drawerWidth)
                    .padding(.leading, 12)
                    .padding(.vertical, 12)
                    .offset(x: navigationDrawerPresented ? 0 : -(drawerWidth + 24))
                    .opacity(navigationDrawerPresented ? 1 : 0.7)
                    .allowsHitTesting(navigationDrawerPresented)
                    .accessibilityHidden(!navigationDrawerPresented)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .tint(accent)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) {
            if store.selectedNote != nil && !navigationDrawerPresented {
                editorFloatingToolbar
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { height in
                        editorToolbarHeight = height
                    }
                    .padding(.top, editorToolbarTopInset)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .overlay(alignment: .topLeading) {
            if !navigationDrawerPresented && !store.isLoading {
                sidebarButton
                    .padding(.leading, 12)
                    .padding(.top, 8)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(3)
            }
        }
        .animation(reduceMotion ? nil : Pen.spring, value: navigationDrawerPresented)
        .animation(reduceMotion ? nil : Pen.spring, value: showPrefer)
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
            if on {
                proxy.view?.prepareForPenpalActivation()
                // PEN-33: offer the box hint only on an empty page, so it can
                // never talk over work the user is already doing.
                onboarding.offerIfAppropriate(
                    penpalOn: true,
                    usesBoxTrigger: usesBoxTrigger,
                    hasInk: !(store.selectedNote?.drawing.strokes.isEmpty ?? true))
            } else {
                showMathChips = false
                onboarding.dismiss()
            }
        }
        .onChange(of: settings.capability) { _, _ in
            showMathChips = false
            if penpalOn {
                onboarding.offerIfAppropriate(
                    penpalOn: true,
                    usesBoxTrigger: usesBoxTrigger,
                    hasInk: !(store.selectedNote?.drawing.strokes.isEmpty ?? true))
            }
        }
        .onChange(of: store.selectedNoteID) { _, _ in
            showMathChips = false
        }
        .onChange(of: photoItem) { _, item in
            Task { await importPhoto(item) }
        }
        .onChange(of: importPhotoItem) { _, item in
            Task { await importPageFromPhoto(item) }
        }
        .onChange(of: visionPhotoItem) { _, item in
            Task { await respondToVisionPhoto(item) }
        }
        .sheet(isPresented: $showTraining) {
            CalibrationView()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled(true)
                .presentationBackground(Pen.paper)
        }
        .sheet(isPresented: $showSettings) {
            PenpalSettingsView(settings: settings) { message in
                statusMessage = message
                showStatus = true
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(Pen.paper)
        }
        .sheet(isPresented: $showShare) {
            ActivityView(items: shareItems)
        }
        .sheet(item: $activePermission) { pending in
            InteractivePermissionView(prompt: pending.prompt) { decision in
                finishPermission(pending, decision: decision)
            }
        }
        .sheet(item: studioSheetItem) { block in
            BlockStudioView(block: block, expanded: $studioFullScreen, onSave: studioSave)
                .presentationBackground(Pen.paper)
        }
        .fullScreenCover(item: studioFullScreenItem) { block in
            BlockStudioView(block: block, expanded: $studioFullScreen, onSave: studioSave)
                .background(Pen.paper.ignoresSafeArea())
        }
        .fullScreenCover(isPresented: $showVisionCamera) {
            CameraCaptureView { image in
                showVisionCamera = false
                if let image {
                    proxy.view?.respondToExternalPhoto(image)
                }
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
        .photosPicker(isPresented: $showImportPhotos, selection: $importPhotoItem, matching: .images)
        .photosPicker(isPresented: $showVisionPhotos, selection: $visionPhotoItem, matching: .images)
        .alert("Penpal", isPresented: $showStatus) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(statusMessage)
        }
    }

    private func enqueuePermission(
        _ prompt: InteractivePermissionPrompt,
        completion: @escaping (InteractivePermissionDecision) -> Void
    ) {
        let pending = PendingInteractivePermission(
            prompt: prompt,
            completion: completion
        )
        if activePermission == nil {
            activePermission = pending
        } else {
            permissionQueue.append(pending)
        }
    }

    private func finishPermission(
        _ pending: PendingInteractivePermission,
        decision: InteractivePermissionDecision
    ) {
        guard activePermission?.id == pending.id else { return }
        activePermission = nil
        pending.completion(decision)
        guard !permissionQueue.isEmpty else { return }
        let next = permissionQueue.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            activePermission = next
        }
    }

    // MARK: - Editor detail

    private func editorDetail(stickyNoteTop: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            Pen.paper.ignoresSafeArea()

            if store.isLoading {
                notebookLoadingView
            } else if let note = store.selectedNote {
                if note.isCoded {
                    // Coded paper: the note is a rendered HTML page, not a canvas.
                    CodedPaperView(store: store)
                } else {
                    noteSurface(stickyNoteTop: stickyNoteTop)

                    if penpalOn {
                        PenpalControlBar(
                            settings: settings,
                            activityPhase: penpalActivityPhase,
                            statusText: penpalStatusText,
                            onAsk: { proxy.view?.replyNow() },
                            onVisionCamera: openVisionCamera,
                            onVisionPhoto: { showVisionPhotos = true },
                            onClose: {
                                withAnimation(reduceMotion ? nil : Pen.spring) { penpalOn = false }
                            }
                        )
                            .onGeometryChange(for: CGFloat.self) { geometry in
                                geometry.size.height
                            } action: { height in
                                penpalDockHeight = height
                            }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if mathChipsVisible {
                        mathFollowUpBar
                            .padding(.bottom, penpalBarClearance)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // PEN-33 — taught on the page, once, and only when there
                    // is nothing to interrupt.
                    if onboarding.isShowing {
                        BoxGestureHint(
                            sample: boxHintSample,
                            message: boxHintMessage,
                            accessibilityHint: boxHintAccessibility
                        ) { onboarding.dismiss() }
                            .padding(.bottom, penpalBarClearance + stackedOverlayGap)
                            .transition(.scale(scale: 0.94).combined(with: .opacity))
                    }

                    if showPrefer, settings.replyStyle == "hand", !isWriting, !isThinking {
                        preferenceBar
                            .padding(.bottom,
                                     (penpalOn ? penpalBarClearance : 28)
                                     + (mathChipsVisible ? stackedOverlayGap : 0))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            } else {
                noNoteSelectedView
            }
        }
        // The editor owns its top controls as a floating overlay so the ruled
        // page can scroll beneath them without reserving a navigation-bar row.
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .bottom) {
            if let activeLoadingOperation {
                operationProgress(activeLoadingOperation.message)
                    .padding(.bottom, penpalOn ? penpalBarClearance + 12 : 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(4)
            }
        }
        .animation(reduceMotion ? nil : Pen.spring, value: penpalOn)
        .animation(reduceMotion ? nil : Pen.spring, value: mathChipsVisible)
    }

    private var notebookLoadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(Pen.inkAccent)
            Text("Opening your notebook…")
                .font(Pen.sub)
                .foregroundStyle(Pen.inkFaded)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Opening your notebook")
    }

    private func operationProgress(_ message: String) -> some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Pen.inkPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Pen.paperRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Pen.inkPrimary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .allowsHitTesting(false)
    }

    private func beginLoadingOperation(_ message: String) -> UUID {
        let id = UUID()
        withAnimation(reduceMotion ? nil : Pen.spring) {
            activeLoadingOperation = (id, message)
        }
        return id
    }

    private func finishLoadingOperation(_ id: UUID) {
        guard activeLoadingOperation?.id == id else { return }
        withAnimation(reduceMotion ? nil : Pen.spring) {
            activeLoadingOperation = nil
        }
    }

    /// Keep the app navigable when a folder has no notes. The floating editor
    /// toolbar only exists while a note is selected, so this state needs its
    /// own route back to the library and a direct way to create a page.
    private var noNoteSelectedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "note.text")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(Pen.inkAccent)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("No note selected")
                    .font(Pen.titleSerif)
                    .foregroundStyle(Pen.inkPrimary)
                Text("Open the sidebar to choose a note, or start a new one in this folder.")
                    .font(Pen.sub)
                    .foregroundStyle(Pen.inkFaded)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                Button(action: createNote) {
                    Label("Create Note", systemImage: "square.and.pencil")
                }
                .buttonStyle(PenPrimaryButtonStyle())
            }
        }
        .padding(24)
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Ink-only toolbar actions don't apply when the note is a coded paper.
    private var selectedIsCoded: Bool { store.selectedNote?.isCoded == true }

    /// Keep note controls on the page; the sidebar control lives by itself in
    /// the top-left corner. Narrow windows retain the scrolling, full-size controls.
    private var editorFloatingToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                historyPill
                Spacer(minLength: 8)
                pageToolsPill
                Spacer(minLength: 8)
                documentPill
            }
            .padding(.horizontal, 12)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    historyPill
                    pageToolsPill
                    documentPill
                }
                .padding(.leading, 12)
                .padding(.trailing, 12)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
        .accessibilityLabel("Note tools")
        .frame(height: 56, alignment: .top)
        .padding(.leading, 64)
    }

    private var sidebarButton: some View {
        Button {
            if let note = store.selectedNote {
                store.selectedFolderID = note.folderID
            }
            withAnimation(reduceMotion ? nil : Pen.spring) {
                navigationDrawerPresented = true
            }
        } label: {
            Image(systemName: "sidebar.left")
                .foregroundStyle(Pen.inkPrimary)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(Pen.paperRaised, in: Circle())
        .overlay(Circle().strokeBorder(Pen.inkPrimary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.07), radius: 12, y: 4)
        .accessibilityLabel("Open Folders and Notes")
    }

    private var historyPill: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : Pen.spring) { stickyHidden.toggle() }
                if !stickyHidden { flushEditor() }
            } label: {
                Image(systemName: stickyHidden ? "note.text.badge.plus" : "chevron.up.circle")
                    .foregroundStyle(stickyHidden ? Pen.inkPrimary : Pen.inkAccent)
                    .frame(width: 44, height: 44)
            }
            .disabled(store.selectedNote == nil)
            .accessibilityLabel(stickyHidden ? "Show Sticky Note" : "Hide Sticky Note")

            Button { proxy.view?.undo() } label: {
                Image(systemName: "arrow.uturn.backward.circle")
                    .foregroundStyle(Pen.inkPrimary).frame(width: 44, height: 44)
            }
            .disabled(store.selectedNote == nil || selectedIsCoded || !canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .accessibilityLabel("Undo")

            Button { proxy.view?.redo() } label: {
                Image(systemName: "arrow.uturn.forward.circle")
                    .foregroundStyle(Pen.inkPrimary).frame(width: 44, height: 44)
            }
            .disabled(store.selectedNote == nil || selectedIsCoded || !canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .accessibilityLabel("Redo")
        }
        .buttonStyle(.plain)
        .frame(height: 48)
        .background(Pen.paperRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Pen.inkPrimary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.07), radius: 12, y: 4)
    }

    private var pageToolsPill: some View {
        HStack(spacing: 0) {
            Menu {
                Button("Import Page", systemImage: "doc.viewfinder") { showImportPhotos = true }
                Button("Add Attachment", systemImage: "paperclip") {
                    insertPageBlock(CodedPaper.attachmentBlockHTML, kind: .attachment, height: 280)
                }
                Divider()
                Button("Add Code Block", systemImage: "chevron.left.forwardslash.chevron.right") {
                    insertPageBlock(CodedPaper.blockStarterHTML, kind: .code, height: 300)
                }
                Button("Add Diagram", systemImage: "point.3.connected.trianglepath.dotted") {
                    insertPageBlock(CodedPaper.mermaidBlockHTML, kind: .mermaid, height: 300)
                }
                Button("Add Text Block", systemImage: "text.quote") {
                    insertPageBlock(CodedPaper.textBlockHTML, kind: .text, height: 180)
                }
                Button("Add Table Block", systemImage: "tablecells") {
                    insertPageBlock(CodedPaper.tableBlockHTML, kind: .table, height: 220)
                }
                Button("Add Checklist Block", systemImage: "checklist") {
                    insertPageBlock(CodedPaper.checklistBlockHTML, kind: .checklist, height: 210)
                }
            } label: {
                Image(systemName: "paperclip").foregroundStyle(Pen.inkPrimary)
                    .frame(width: 44, height: 44)
            }
            .disabled(store.selectedNote == nil || selectedIsCoded)
            .menuIndicator(.hidden)
            .accessibilityLabel("Insert on Page")

            Button {
                toolsVisible.toggle()
                proxy.view?.setToolsVisible(toolsVisible)
                if toolsVisible { bodyFocused = false }
            } label: {
                Image(systemName: toolsVisible ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                    .foregroundStyle(toolsVisible ? Pen.inkAccent : Pen.inkPrimary)
                    .frame(width: 44, height: 44)
            }
            .disabled(store.selectedNote == nil || selectedIsCoded)
            .accessibilityLabel(toolsVisible ? "Hide Markup" : "Show Markup")

            Button {
                pageEditMode.toggle()
                proxy.view?.setPageEditMode(pageEditMode)
                if pageEditMode {
                    penpalOn = false
                    toolsVisible = false
                    proxy.view?.setToolsVisible(false)
                    bodyFocused = false
                }
            } label: {
                Image(systemName: pageEditMode ? "square.dashed.inset.filled" : "square.dashed")
                    .foregroundStyle(pageEditMode ? Pen.inkAccent : Pen.inkPrimary)
                    .frame(width: 44, height: 44)
            }
            .disabled(store.selectedNote == nil || selectedIsCoded)
            .accessibilityLabel(pageEditMode ? "Stop Arranging" : "Arrange Page")

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
                    .foregroundStyle(penpalOn ? Pen.inkAccent : Pen.inkPrimary)
                    .frame(width: 44, height: 44)
            }
            .disabled(store.selectedNote == nil || selectedIsCoded)
            .accessibilityLabel(penpalOn ? "Turn Off Penpal Mode" : "Turn On Penpal Mode")
        }
        .buttonStyle(.plain)
        .frame(height: 48)
        .background(Pen.paperRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Pen.inkPrimary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.07), radius: 12, y: 4)
    }

    private var documentPill: some View {
        HStack(spacing: 0) {
            Button(action: shareCurrentNote) {
                Group {
                    if isPreparingShare {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 44, height: 44)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(Pen.inkPrimary)
                            .frame(width: 44, height: 44)
                    }
                }
            }
            .disabled(store.selectedNote == nil || isPreparingShare)
            .accessibilityLabel(isPreparingShare ? "Preparing Note to Share" : "Share Note")

            Menu {
                Button { createNote() } label: { Label("New Note", systemImage: "square.and.pencil") }
                Button { createCodedNote() } label: { Label("New Coded Paper", systemImage: "curlybraces.square") }
            } label: {
                Image(systemName: "square.and.pencil").foregroundStyle(Pen.inkPrimary)
                    .frame(width: 44, height: 44)
            } primaryAction: { createNote() }
            .menuIndicator(.hidden)
            .accessibilityLabel("New Note")

            Menu { moreActions } label: {
                Group {
                    if isGeneratingPractice {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 44, height: 44)
                    } else {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(Pen.inkPrimary)
                            .frame(width: 44, height: 44)
                    }
                }
            }
            .disabled(store.selectedNote == nil || isGeneratingPractice)
            .menuIndicator(.hidden)
            .accessibilityLabel(isGeneratingPractice ? "Preparing Practice Problem" : "More Note Actions")
        }
        .buttonStyle(.plain)
        .frame(height: 48)
        .background(Pen.paperRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Pen.inkPrimary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.07), radius: 12, y: 4)
    }

    private var isMathematician: Bool { settings.capability == "mathematician" }
    /// Boxing a question is an explicit send in every mode, matching Ask.
    private var usesBoxTrigger: Bool { true }
    private var isIllustrator: Bool { settings.capability == "illustrator" }
    private var isLanguagePartner: Bool { settings.capability == "language" }
    private var isDebatePartner: Bool { settings.capability == "debate" }

    private var boxHintSample: String {
        switch settings.capability {
        case "illustrator": "a red bicycle"
        case "interactive": "a bouncing ball"
        case "mathematician": "3x + 5 = 17"
        case "debate": "schools should start later"
        case "arranger": "a DC generator, explained"
        default: "what's on your mind?"
        }
    }

    private var boxHintMessage: String {
        switch settings.capability {
        case "illustrator":
            "Write what to draw, then tap Ask\nor box it."
        case "interactive":
            "Write a request, then tap Ask\nor box it."
        case "mathematician":
            "Write a problem, then tap Ask\nor box it."
        case "debate":
            "Write a claim, then tap Ask\nor box it."
        case "arranger":
            "Write a topic and Penpal will\nlay out the whole page."
        default:
            "Write a question, then tap Ask\nor box it."
        }
    }

    private var boxHintAccessibility: String {
        boxHintMessage.replacingOccurrences(of: "\n", with: " ")
    }

    private var targetLanguageTitle: String {
        PenpalControlOptions.languages.first { $0.tag == settings.targetLanguage }?.title
            ?? "language"
    }

    private var mathChipsVisible: Bool {
        penpalOn && isMathematician && showMathChips
            && !isWriting && !isThinking && !isReading
    }

    /// One-tap follow-ups after a math reply — the words the brain understands.
    private var mathFollowUpBar: some View {
        HStack(spacing: 8) {
            mathChip("Explain", icon: "questionmark.circle", send: "explain")
            mathChip("Another way", icon: "arrow.triangle.branch", send: "another way")
            mathChip("Harder", icon: "flame", send: "harder")
            Button {
                showMathChips = false
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Pen.inkFaded)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Pen.paperRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Pen.inkAccent.opacity(0.2), lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
    }

    private func mathChip(_ title: String, icon: String, send message: String) -> some View {
        Button {
            showMathChips = false
            proxy.view?.sendTextMessage(message)
        } label: {
            Label(title, systemImage: icon)
                .font(.footnote.weight(.medium))
                // PEN-32: cap growth rather than fixing the size. The chips
                // must scale for low vision, but unbounded growth breaks the
                // capsule row on a phone — accessibility sizes get the
                // ⋯ menu, which reflows properly.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(Pen.inkAccent)
        .accessibilityLabel(title)
        .accessibilityHint("Asks Penpal to \(title.lowercased()) the last answer")
    }

    private var penpalActivityPhase: InkThinkingIndicator.Phase? {
        if voice.isListening { return nil }
        if isReading { return .reading }
        if isThinking { return .thinking }
        if isWriting { return .writing }
        return nil
    }

    private var penpalStatusText: String? {
        if voice.isListening {
            return voice.transcript.isEmpty ? "Listening…" : voice.transcript
        }
        if isReading { return "Reading expression…" }
        if isThinking {
            if isMathematician { return "Solving & verifying…" }
            if isIllustrator {
                switch settings.illustratorQuality {
                case "quick": return "Planning a quick sketch…"
                case "balanced": return "Rendering the sketch…"
                default: return "Building a detailed sketch…"
                }
            }
            if isLanguagePartner { return "Thinking in \(targetLanguageTitle)…" }
            if isDebatePartner { return "Finding the strongest counterpoint…" }
            return "Penpal is thinking…"
        }
        if isWriting {
            if isIllustrator && settings.illustratorQuality == "detailed" {
                return "Penpal is drawing the details…"
            }
            return isIllustrator ? "Penpal is drawing…" : "Penpal is writing…"
        }
        // PEN-12 — say plainly that work is waiting, so "I'll answer as soon
        // as we're back" is visible state rather than a promise made once.
        if outbox.hasPending {
            let n = outbox.pending.count
            return outbox.isOnline
                ? "Sending \(n) saved \(n == 1 ? "note" : "notes")…"
                : "Offline — \(n) \(n == 1 ? "note" : "notes") saved for later"
        }
        return nil
    }

    private func noteSurface(stickyNoteTop: CGFloat) -> some View {
        // The page (handwriting canvas) fills everything; the heading/note
        // float on top as a compact, left-aligned sticky note that never
        // blocks writing below it.
        ZStack(alignment: .topLeading) {
            MagicPaper(
                proxy: proxy,
                settings: settings,
                penpalEnabled: penpalOn,
                pageWidth: pageWidth,
                onWritingStateChange: { writing in
                    isWriting = writing
                    if !writing, settings.replyStyle == "hand", penpalOn {
                        showPrefer = StyleRL.shared.hasCritic
                    }
                    // A finished math reply invites a follow-up.
                    if !writing, penpalOn, isMathematician {
                        showMathChips = true
                    }
                },
                onThinkingChange: { isThinking = $0 },
                onReadingChange: { isReading = $0 },
                onStatus: { message in
                    guard !message.isEmpty else { return }
                    statusMessage = message
                    showStatus = true
                    isThinking = false
                },
                onInteractivePermissionRequest: { prompt, completion in
                    enqueuePermission(prompt, completion: completion)
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
                },
                onCodeBlocksChange: { blocks in
                    store.updateSelectedCodeBlocks(blocks)
                },
                onRequestEditCodeBlock: { block in
                    editingCodeBlock = block
                },
                onPageEditModeChange: { on in
                    pageEditMode = on
                    // Match the Arrange button's side-effects so long-pressing a
                    // block into Arrange also parks writing/markup tools.
                    if on {
                        penpalOn = false
                        toolsVisible = false
                        proxy.view?.setToolsVisible(false)
                        bodyFocused = false
                    }
                },
                onMarkupOpened: {
                    // Photo import opens the markup tray itself so its ink
                    // paints — keep the toolbar button in sync.
                    toolsVisible = true
                    bodyFocused = false
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !stickyHidden {
                stickyNoteCard
                    .padding(.leading, 12)
                    .padding(.trailing, 20)
                    // Measure the floating toolbar and safe area so the card
                    // always starts below them after rotation and resizing.
                    .padding(.top, stickyNoteTop)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Pen.spring, value: stickyHidden)
    }

    private var stickyNoteCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "note.text")
                    .font(.caption2)
                Text(store.selectedNote?.modifiedAt.formatted(date: .abbreviated, time: .shortened) ?? "")
                    .font(.caption2)
            }
            .foregroundStyle(Pen.inkFaded)
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
        }
        .padding(14)
        .frame(maxWidth: 300, alignment: .leading)
        .background(Pen.paperRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 14, x: 0, y: 6)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Pen.inkPrimary.opacity(0.08), lineWidth: 0.5)
        )
        .foregroundStyle(Pen.inkPrimary)
    }

    // MARK: - Actions

    /// PEN-19 — writes the next due practice problem onto a fresh page.
    ///
    /// Deliberately lands on real paper rather than in a quiz UI: practice
    /// should be the same act as homework, in the same place, with the same
    /// pen. A separate quiz screen would make it feel like a different app.
    private func startPractice() {
        guard !isGeneratingPractice, let weakness = planner.due.first else { return }
        isGeneratingPractice = true
        let operationID = beginLoadingOperation("Preparing a practice problem…")
        Task { @MainActor in
            defer {
                isGeneratingPractice = false
                finishLoadingOperation(operationID)
            }
            do {
                let item = try await planner.practiceProblem(
                    for: weakness, baseURL: settings.apiBaseURL)
                createNote()
                titleText = "Practice — \(item.skill)"
                store.updateSelectedTitle(titleText)
                // The problem is written in the user's own hand, like anything
                // else Penpal writes.
                proxy.view?.writeReplyText(item.problem)
                practiceInProgress = (weakness.id, item)
                // Closing the loop: when this page gets marked, the verdict
                // updates the schedule instead of logging a fresh weakness.
                proxy.view?.onWorkMarked = { wasCorrect in
                    planner.recordPractice(weakness.id, wasCorrect: wasCorrect)
                    proxy.view?.onWorkMarked = nil
                    practiceInProgress = nil
                    statusMessage = wasCorrect
                        ? "Got it. I'll bring this back in a while to make sure it stuck."
                        : "No problem — I'll show you this one again tomorrow."
                    showStatus = true
                }
                statusMessage = "Work it through, then use Check My Working."
                showStatus = true
            } catch {
                statusMessage = PenpalError.message(for: error)
                showStatus = true
            }
        }
    }

    private func createNote() {
        flushEditor()
        _ = store.createNote(in: store.selectedFolderID)
        bodyFocused = false
    }

    private func createCodedNote() {
        flushEditor()
        penpalOn = false
        toolsVisible = false
        _ = store.createNote(in: store.selectedFolderID, kind: .coded)
        bodyFocused = false
    }

    private func closeNavigationDrawer() {
        withAnimation(reduceMotion ? nil : Pen.spring) {
            navigationDrawerPresented = false
        }
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
            pageWidth = note.resolvedPaperWidth
            // Switching notes always leaves the page's edit mode.
            pageEditMode = false
            if note.isCoded {
                // Coded paper renders in CodedPaperView — no canvas to load,
                // and ink-only modes make no sense here.
                penpalOn = false
                toolsVisible = false
                return
            }
            // Defer load until the representable has a view.
            DispatchQueue.main.async {
                self.proxy.view?.loadDrawing(note.drawing,
                                             typedTexts: note.typedTexts ?? [],
                                             replyInks: note.replyInks ?? [],
                                             codeBlocks: note.codeBlocks ?? [])
                if self.toolsVisible {
                    self.proxy.view?.setToolsVisible(true)
                }
            }
        }
    }

    private func flushEditor() {
        if let id = loadedNoteID, var note = store.notes.first(where: { $0.id == id }) {
            note.title = titleText
            note.body = bodyText
            // Coded papers have no canvas — and proxy.view may still hold the
            // previous ink note's content, which must not leak into this one.
            if !note.isCoded, let view = proxy.view {
                // If Penpal is mid-write, bake the reply into the drawing first
                // so it isn't lost when the note is saved/switched.
                view.finalizePendingWriting()
                note.paperWidth = pageWidth
                note.drawing = view.currentDrawing
                note.typedTexts = view.currentTypedTexts
                note.replyInks = view.currentReplyInks
                note.codeBlocks = view.currentCodeBlocks.isEmpty ? nil : view.currentCodeBlocks
            }
            store.updateNote(note)
        }
    }

    private func insertPageBlock(_ html: String, kind: PageBlockKind, height: CGFloat) {
        penpalOn = false
        toolsVisible = false
        proxy.view?.setToolsVisible(false)
        // Attachment blocks open with input fields, so they wake ready to use
        // instead of dropping into Arrange (which would make the fields inert).
        let activate = kind == .attachment
        proxy.view?.insertCodeBlock(html: html, kind: kind,
                                    preferredHeight: height, activateForInput: activate)
        pageEditMode = activate ? false : true
        bodyFocused = false
    }

    @discardableResult
    private func insertImageAttachment(_ data: Data) -> Bool {
        guard proxy.view?.insertImageBlock(imageData: data) == true else { return false }
        penpalOn = false
        toolsVisible = false
        proxy.view?.setToolsVisible(false)
        pageEditMode = true
        bodyFocused = false
        return true
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
        guard !isPreparingShare, let selectedNoteID = store.selectedNoteID else { return }
        isPreparingShare = true
        let operationID = beginLoadingOperation("Preparing share…")
        Task { @MainActor in
            defer {
                isPreparingShare = false
                finishLoadingOperation(operationID)
            }
            // Give SwiftUI a turn to display the spinner before saving the
            // current canvas and preparing potentially large share files.
            await Task.yield()
            guard store.selectedNoteID == selectedNoteID else { return }
            flushEditor()
            guard let note = store.selectedNote, note.id == selectedNoteID else { return }

            let text = [note.displayTitle, note.body]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
            let html = note.isCoded ? note.htmlContent : nil
            let drawingData = note.drawingData
            let title = note.displayTitle
            let paperStyle = settings.paperStyle
            let attachmentURLs = note.attachments.map { store.attachmentURL($0) }

            let drawingFiles = await Task.detached(priority: .userInitiated) {
                NoteExporter.shareFiles(
                    drawingData: drawingData,
                    title: title,
                    paperStyle: paperStyle
                )
            }.value

            var items: [Any] = []
            if !text.isEmpty { items.append(text) }
            if let html, !html.isEmpty { items.append(html) }
            if let pdf = drawingFiles.pdf { items.append(pdf) }
            if let image = drawingFiles.image { items.append(image) }
            items.append(contentsOf: attachmentURLs.filter {
                FileManager.default.fileExists(atPath: $0.path)
            })

            isPreparingShare = false
            guard !items.isEmpty else {
                statusMessage = drawingData.isEmpty
                    ? "Nothing to share yet."
                    : "Couldn't prepare this note to share."
                showStatus = true
                return
            }
            shareItems = items
            showShare = true
        }
    }

    @MainActor
    private func openVisionCamera() {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            showVisionCamera = true
        } else {
            // Simulator and camera-less devices still get the same flow.
            showVisionPhotos = true
        }
    }

    @MainActor
    private func respondToVisionPhoto(_ item: PhotosPickerItem?) async {
        guard let item, store.selectedNoteID != nil else { return }
        let operationID = beginLoadingOperation("Loading photo…")
        defer { finishLoadingOperation(operationID) }
        defer { visionPhotoItem = nil }
        let data: Data?
        if let loaded = try? await item.loadTransferable(type: Data.self) {
            data = loaded
        } else {
            data = try? await item.loadTransferable(type: PhotoData.self)?.data
        }
        guard let data, let image = UIImage(data: data) else {
            statusMessage = "Couldn't read that photo."
            showStatus = true
            return
        }
        proxy.view?.respondToExternalPhoto(image)
    }

    /// PEN-35 — read an existing paper page from a photo and rebuild its
    /// content on the live page, rather than dropping the photo in as a flat
    /// picture (that's `importPhoto`/`insertImageAttachment`, still separate).
    @MainActor
    private func importPageFromPhoto(_ item: PhotosPickerItem?) async {
        guard let item, store.selectedNoteID != nil else { return }
        let operationID = beginLoadingOperation("Reading page…")
        defer { finishLoadingOperation(operationID) }
        defer { importPhotoItem = nil }
        let data: Data?
        if let loaded = try? await item.loadTransferable(type: Data.self) {
            data = loaded
        } else {
            data = try? await item.loadTransferable(type: PhotoData.self)?.data
        }
        guard let data, let image = UIImage(data: data) else {
            statusMessage = "Couldn't read that photo."
            showStatus = true
            return
        }
        proxy.view?.importPhotoPage(image)
    }

    @MainActor
    private func importPhoto(_ item: PhotosPickerItem?) async {
        guard let item, store.selectedNoteID != nil else { return }
        let operationID = beginLoadingOperation("Adding photo…")
        defer { finishLoadingOperation(operationID) }
        defer { photoItem = nil }
        do {
            if let data = try await item.loadTransferable(type: Data.self) {
                if insertImageAttachment(data) { return }
            }
            statusMessage = "Couldn't add photo."
            showStatus = true
        } catch {
            // Fallback: try raw image data via Transferable image representation.
            if let data = try? await item.loadTransferable(type: PhotoData.self)?.data {
                if !insertImageAttachment(data) {
                    statusMessage = "Couldn't add photo."
                    showStatus = true
                }
            } else {
                statusMessage = "Couldn't add photo."
                showStatus = true
            }
        }
    }

    @ViewBuilder
    private var moreActions: some View {
        // PEN-19 — only offered when there's actually something due, so it
        // never nags. The reward is the list getting shorter, not a streak.
        if planner.hasWorkDue {
            Button("Practice (\(planner.due.count) due)", systemImage: "repeat") {
                startPractice()
            }
        }
        Button("Add Page", systemImage: "plus.rectangle.portrait") { proxy.view?.addPage() }
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

    private var preferenceBar: some View {
        HStack(spacing: 14) {
            Text("Looks like your writing?")
                .font(.footnote.weight(.medium))
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
                showTraining = true
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
            .foregroundStyle(Pen.inkFaded)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Pen.paperRaised, in: Capsule())
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

private struct CameraCaptureView: UIViewControllerRepresentable {
    let completion: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIImagePickerController,
        context: Context
    ) {}

    final class Coordinator: NSObject,
                             UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate {
        let completion: (UIImage?) -> Void

        init(completion: @escaping (UIImage?) -> Void) {
            self.completion = completion
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [
                UIImagePickerController.InfoKey: Any
            ]
        ) {
            completion(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            completion(nil)
        }
    }
}

#Preview {
    ContentView()
}
