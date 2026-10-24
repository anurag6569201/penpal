//
//  NotesStore.swift
//  penpal
//
//  Local Notes-style folders + notes. No iCloud — Documents folder only.
//

import Foundation
import Combine
import PencilKit
import SwiftUI
import UIKit

// MARK: - Models

// The model structs are nonisolated: they're pure value types that get
// JSON-encoded on a background queue (DebouncedSaver), so they must not
// inherit the project's default MainActor isolation.
nonisolated struct NoteFolder: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var parentID: UUID?
    var isExpanded: Bool
    var sortOrder: Int
    var systemKind: SystemFolderKind?

    enum SystemFolderKind: String, Codable {
        case quickNotes
        case shared
        case allNotes
        case notes
        case recentlyDeleted
    }

    init(id: UUID = UUID(),
         name: String,
         parentID: UUID? = nil,
         isExpanded: Bool = true,
         sortOrder: Int = 0,
         systemKind: SystemFolderKind? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.isExpanded = isExpanded
        self.sortOrder = sortOrder
        self.systemKind = systemKind
    }
}

nonisolated struct NoteAttachment: Identifiable, Codable, Hashable {
    var id: UUID
    var filename: String
    var createdAt: Date

    init(id: UUID = UUID(), filename: String, createdAt: Date = .now) {
        self.id = id
        self.filename = filename
        self.createdAt = createdAt
    }
}

/// A typed (font-style) Penpal message placed on the page — the user's typed
/// text or an AI reply rendered as a label. Persisted so chats survive
/// closing/reopening the note.
nonisolated struct TypedNoteText: Identifiable, Codable, Hashable {
    var id: UUID
    var text: String
    var x: CGFloat
    var y: CGFloat
    var xHeight: CGFloat
    var maxX: CGFloat
    var isUserMessage: Bool
    var createdAt: Date
    var fontName: String?
    var colorHex: String?

    init(id: UUID = UUID(),
         text: String,
         x: CGFloat,
         y: CGFloat,
         xHeight: CGFloat,
         maxX: CGFloat,
         isUserMessage: Bool,
         createdAt: Date = .now,
         fontName: String? = nil,
         colorHex: String? = nil) {
        self.id = id
        self.text = text
        self.x = x
        self.y = y
        self.xHeight = xHeight
        self.maxX = maxX
        self.isUserMessage = isUserMessage
        self.createdAt = createdAt
        self.fontName = fontName
        self.colorHex = colorHex
    }
}

/// One stroke of an AI reply, persisted exactly as the renderer drew it —
/// same geometry and pressure widths, so reloading a note reproduces the
/// reply pixel-for-pixel (no conversion to PencilKit ink, which renders
/// differently and would change the look after writing finished).
nonisolated struct PersistedInkStroke: Codable, Hashable {
    /// Interleaved x,y coordinates (CGPoint isn't Hashable).
    var pts: [CGFloat]
    var widths: [CGFloat]?
    var isDot: Bool
    var dotRadius: CGFloat

    init(from stroke: InkStroke) {
        pts = stroke.points.flatMap { [$0.x, $0.y] }
        widths = stroke.widths
        isDot = stroke.isDot
        dotRadius = stroke.dotRadius
    }

    var inkStroke: InkStroke {
        var points: [CGPoint] = []
        points.reserveCapacity(pts.count / 2)
        var i = 0
        while i + 1 < pts.count {
            points.append(CGPoint(x: pts[i], y: pts[i + 1]))
            i += 2
        }
        return InkStroke(points: points, isDot: isDot, dotRadius: dotRadius, widths: widths)
    }
}

/// A complete AI hand-written reply on a note page.
nonisolated struct ReplyInk: Identifiable, Codable, Hashable {
    var id: UUID
    var baseWidth: CGFloat
    var strokes: [PersistedInkStroke]
    var createdAt: Date

    init(id: UUID = UUID(),
         baseWidth: CGFloat,
         strokes: [PersistedInkStroke],
         createdAt: Date = .now) {
        self.id = id
        self.baseWidth = baseWidth
        self.strokes = strokes
        self.createdAt = createdAt
    }

    var bottomY: CGFloat {
        var bottom: CGFloat = 0
        for s in strokes {
            var i = 1
            while i < s.pts.count {
                bottom = max(bottom, s.pts[i])
                i += 2
            }
        }
        return bottom
    }

    /// Bounding box of the whole reply in page coordinates (for hit-testing).
    var boundingRect: CGRect {
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for s in strokes {
            var i = 0
            while i + 1 < s.pts.count {
                minX = min(minX, s.pts[i]); maxX = max(maxX, s.pts[i])
                minY = min(minY, s.pts[i + 1]); maxY = max(maxY, s.pts[i + 1])
                i += 2
            }
        }
        guard minX <= maxX, minY <= maxY else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// An embedded "coded" asset placed on an ink page — a live HTML/CSS/JS
/// block (a graph, a widget, anything the web can render). It sits *behind*
/// the ink so handwriting and Penpal replies annotate on top of it. In the
/// page's edit mode it can be moved, resized, edited and deleted; in normal
/// mode it has no border, background or shadow — it's just part of the page.
nonisolated enum PageBlockKind: String, Codable, Hashable {
    case code
    case interactive
    case mermaid
    case text
    case table
    case checklist
    case image
    case web
    /// A flexible media card: an uploaded image/video/audio, or an embedded
    /// URL (YouTube, a live image, a video/audio link, or any web link).
    case attachment
}

nonisolated struct PageBlock: Identifiable, Codable, Hashable {
    var id: UUID
    var html: String
    /// Optional for backward compatibility. Legacy blocks infer their kind
    /// from their HTML and become explicitly typed the next time they change.
    var kind: PageBlockKind?
    /// Geometry in canvas *content* coordinates (same space as ink strokes).
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var createdAt: Date
    /// Browser authority belongs to this block only. Missing metadata means
    /// the legacy offline runtime with no grants.
    var runtime: InteractiveRuntimeMetadata?

    init(id: UUID = UUID(),
         html: String,
         kind: PageBlockKind? = .code,
         x: CGFloat,
         y: CGFloat,
         width: CGFloat,
         height: CGFloat,
         runtime: InteractiveRuntimeMetadata? = nil,
         createdAt: Date = .now) {
        self.id = id
        self.html = html
        self.kind = kind
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.runtime = runtime
        self.createdAt = createdAt
    }

    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    var resolvedKind: PageBlockKind {
        if let kind { return kind }
        let source = html.lowercased()
        if source.contains("data-penpal-kind=\"interactive\"") {
            return .interactive
        }
        if source.contains("data-penpal-kind=\"attachment\"") {
            return .attachment
        }
        if source.contains("data-penpal-kind=\"table\"") || source.contains("<table") {
            return .table
        }
        if source.contains("data-penpal-kind=\"checklist\"") || source.contains("type=\"checkbox\"") {
            return .checklist
        }
        if source.contains("data-penpal-kind=\"mermaid\"") || source.contains("class=\"mermaid\"") {
            return .mermaid
        }
        if source.contains("data:image/") { return .image }
        if source.contains("data-penpal-kind=\"text\"") { return .text }
        return .code
    }
}

/// Source compatibility while the rest of the editor transitions from the
/// original code-only name to the typed page-block model.
typealias CodeBlock = PageBlock

/// What kind of paper a note is. `.ink` is the classic PencilKit canvas;
/// `.coded` renders the note's HTML in a web view — the page IS the paper.
nonisolated enum NoteKind: String, Codable, Hashable {
    case ink
    case coded
}

nonisolated struct Note: Identifiable, Codable, Hashable {
    var id: UUID
    var folderID: UUID
    var title: String
    var body: String
    var drawingData: Data
    /// Stable canvas width; absent on notes created before proportional layout.
    var paperWidth: CGFloat?
    var attachments: [NoteAttachment]
    /// Typed Penpal chat texts placed on the page (optional for backward
    /// compatibility with notes saved before this existed).
    var typedTexts: [TypedNoteText]?
    /// AI hand-written replies, stored as renderer strokes (optional for
    /// backward compatibility).
    var replyInks: [ReplyInk]?
    /// Embedded coded assets (graphs/widgets) placed on an ink page, behind
    /// the ink (optional for backward compatibility).
    var codeBlocks: [CodeBlock]?
    /// Paper kind (optional for backward compatibility — nil means .ink).
    var kind: NoteKind?
    /// Source of a coded paper (HTML/CSS/JS). Only used when kind == .coded.
    var htmlContent: String?
    var createdAt: Date
    var modifiedAt: Date
    var deletedAt: Date?
    /// Optional for backward compatibility with local libraries written before
    /// PEN-46. Tags are notebook metadata, not hidden text inserted onto paper.
    var tags: [String]?
    /// Optional for the same migration reason. Pinned notes remain in their
    /// folders; pinning changes retrieval, never ownership.
    var isPinned: Bool?
    /// PEN-18 — text of Penpal's written replies, kept for search.
    /// The reply is known as text before it is drawn, so indexing it is free.
    /// Optional for backward compatibility with notes saved before this.
    var replyTranscript: [String]?
    /// A local Vision transcript of the user's ink. This is an index for
    /// search and accessibility, never a replacement for the original strokes.
    /// Optional so pre-existing note libraries migrate without a rewrite.
    var handwritingTranscript: String?

    init(id: UUID = UUID(),
         folderID: UUID,
         title: String = "",
         body: String = "",
         drawingData: Data = Data(),
         paperWidth: CGFloat? = nil,
         attachments: [NoteAttachment] = [],
         typedTexts: [TypedNoteText]? = nil,
         replyInks: [ReplyInk]? = nil,
         codeBlocks: [CodeBlock]? = nil,
         kind: NoteKind? = nil,
         htmlContent: String? = nil,
         createdAt: Date = .now,
         modifiedAt: Date = .now,
         deletedAt: Date? = nil,
         tags: [String]? = nil,
         isPinned: Bool? = nil,
         handwritingTranscript: String? = nil) {
        self.id = id
        self.folderID = folderID
        self.title = title
        self.body = body
        self.drawingData = drawingData
        self.paperWidth = paperWidth
        self.attachments = attachments
        self.typedTexts = typedTexts
        self.replyInks = replyInks
        self.codeBlocks = codeBlocks
        self.kind = kind
        self.htmlContent = htmlContent
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.deletedAt = deletedAt
        self.tags = tags
        self.isPinned = isPinned
        self.handwritingTranscript = handwritingTranscript
    }

    /// Legacy notes have no recorded viewport width. Include every saved
    /// content type when choosing a page wide enough to preserve their layout.
    var resolvedPaperWidth: CGFloat {
        if let paperWidth, paperWidth.isFinite, paperWidth >= 320 {
            return paperWidth
        }
        let ink = drawing
        var rightEdges: [CGFloat] = [768 - 24]
        if !ink.strokes.isEmpty { rightEdges.append(ink.bounds.maxX) }
        rightEdges += (typedTexts ?? []).map(\.maxX)
        rightEdges += (replyInks ?? []).compactMap { ink in
            let rect = ink.boundingRect
            return rect.isNull ? nil : rect.maxX
        }
        rightEdges += (codeBlocks ?? []).map { $0.frame.maxX }
        return (rightEdges.filter { $0.isFinite && $0 >= 0 }.max() ?? 744) + 24
    }

    var isDeleted: Bool { deletedAt != nil }

    var isCoded: Bool { kind == .coded }

    var normalizedTags: [String] { tags ?? [] }
    var pinned: Bool { isPinned == true }

    /// Search each persisted text field directly. Joining all page content
    /// first copies potentially large HTML blocks into a temporary string on
    /// every query, even when the title or body already matches.
    func matchesSearch(_ query: String) -> Bool {
        if displayTitle.localizedCaseInsensitiveContains(query)
            || body.localizedCaseInsensitiveContains(query)
            || normalizedTags.contains(where: { $0.localizedCaseInsensitiveContains(query) })
            || (typedTexts ?? []).contains(where: { $0.text.localizedCaseInsensitiveContains(query) })
            || (replyTranscript ?? []).contains(where: { $0.localizedCaseInsensitiveContains(query) })
            || (handwritingTranscript?.localizedCaseInsensitiveContains(query) ?? false)
            || (htmlContent?.localizedCaseInsensitiveContains(query) ?? false)
            || (codeBlocks ?? []).contains(where: { $0.html.localizedCaseInsensitiveContains(query) }) {
            return true
        }
        return false
    }

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let firstLine = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !firstLine.isEmpty { return firstLine }
        if isCoded { return "Coded paper" }
        if !drawingData.isEmpty || !(replyInks ?? []).isEmpty { return "Handwritten note" }
        if let first = typedTexts?.first?.text.trimmingCharacters(in: .whitespacesAndNewlines),
           !first.isEmpty {
            return String(first.prefix(60))
        }
        return "New Note"
    }

    var preview: String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(120)
                .description
        }
        if isCoded { return "Coded paper — HTML page" }
        if !drawingData.isEmpty || !(replyInks ?? []).isEmpty { return "Handwritten note" }
        if let texts = typedTexts, !texts.isEmpty {
            return texts.map(\.text).joined(separator: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(120)
                .description
        }
        return "No additional text"
    }

    var drawing: PKDrawing {
        get { (try? PKDrawing(data: drawingData)) ?? PKDrawing() }
        set { drawingData = newValue.dataRepresentation() }
    }

    // NSCache is documented thread-safe; safe to share without isolation.
    nonisolated(unsafe) private static let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 96
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    nonisolated static func makeThumbnail(drawingData: Data, cacheKey: String) -> UIImage? {
        guard !drawingData.isEmpty else { return nil }
        let key = cacheKey as NSString
        if let hit = Self.thumbnailCache.object(forKey: key) { return hit }
        let d = (try? PKDrawing(data: drawingData)) ?? PKDrawing()
        guard !d.strokes.isEmpty else { return nil }
        var bounds = d.bounds.insetBy(dx: -20, dy: -20)
        guard bounds.width > 1, bounds.height > 1,
              bounds.width.isFinite, bounds.height.isFinite else { return nil }
        // A note can contain many infinite-paper pages. The sidebar and
        // gallery only need a cover preview, so cap the rasterized region to
        // one page instead of allocating an image as tall as the whole note.
        bounds.size.width = min(bounds.width, 1_024)
        let coverHeight = bounds.width / 0.78
        bounds.size.height = min(bounds.height, coverHeight)
        let maxPixels: CGFloat = 384
        let scale = min(1.5, maxPixels / max(bounds.width, bounds.height))
        let image = d.image(from: bounds, scale: scale)
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        Self.thumbnailCache.setObject(image, forKey: key, cost: cost)
        return image
    }
}

nonisolated struct NotebookBackupRestoreSummary: Equatable {
    var importedNotes: Int
    var importedFolders: Int
    var skippedExistingNotes: Int
    var skippedMissingAttachments: Int
}

// MARK: - Store

@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    @Published var folders: [NoteFolder] = []
    @Published var notes: [Note] = []
    @Published var selectedFolderID: UUID?
    @Published var selectedNoteID: UUID?
    @Published var isEditingFolders = false
    @Published var searchQuery = ""
    @Published private(set) var isLoading = true

    private let saveURL: URL
    private let attachmentsDir: URL
    // The notebook snapshot is large. Serialize its writes on DebouncedSaver's
    // utility queue so two saves cannot race and an older snapshot cannot win.
    private let diskSaver = DebouncedSaver(delay: 0)
    private var saveTask: Task<Void, Never>?
    private var loadingContinuations: [CheckedContinuation<Void, Never>] = []

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        saveURL = docs.appendingPathComponent("notes_store.json")
        attachmentsDir = docs.appendingPathComponent("NoteAttachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)

        let url = saveURL
        Task { [weak self] in
            // Reading and decoding a notebook with many PencilKit drawings can
            // take long enough to freeze the welcome screen. Keep disk work
            // off the main actor, then publish the decoded value in one step.
            let snapshot = await Task.detached(priority: .userInitiated) {
                Self.readSnapshot(from: url)
            }.value
            guard let self else { return }
            if let snapshot {
                self.apply(snapshot)
            } else {
                self.seed()
            }
            self.finishLoading()
        }
    }

    func waitUntilLoaded() async {
        guard isLoading else { return }
        await withCheckedContinuation { continuation in
            loadingContinuations.append(continuation)
        }
    }

    private func finishLoading() {
        isLoading = false
        let continuations = loadingContinuations
        loadingContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    // MARK: Derived

    var selectedFolder: NoteFolder? {
        folders.first { $0.id == selectedFolderID }
    }

    var selectedNote: Note? {
        notes.first { $0.id == selectedNoteID }
    }

    var selectedNoteBinding: Binding<Note>? {
        guard let id = selectedNoteID,
              let idx = notes.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.notes[idx] },
            set: { self.notes[idx] = $0; self.scheduleSave() }
        )
    }

    func noteCount(for folder: NoteFolder) -> Int {
        switch folder.systemKind {
        case .allNotes:
            return notes.filter { !$0.isDeleted }.count
        case .recentlyDeleted:
            return notes.filter(\.isDeleted).count
        case .notes, .none, .quickNotes, .shared:
            return notes.filter { !$0.isDeleted && $0.folderID == folder.id }.count
        }
    }

    var recentlyDeletedSelected: Bool {
        selectedFolder?.systemKind == .recentlyDeleted
    }

    func visibleNotes() -> [Note] {
        let base: [Note]
        guard let folder = selectedFolder else {
            base = notes.filter { !$0.isDeleted }
            return filterSearch(base).sorted(by: Self.stableOrder)
        }
        switch folder.systemKind {
        case .allNotes:
            base = notes.filter { !$0.isDeleted }
        case .recentlyDeleted:
            base = notes.filter(\.isDeleted)
        case .notes, .none, .quickNotes, .shared:
            base = notes.filter { !$0.isDeleted && $0.folderID == folder.id }
        }
        return filterSearch(base).sorted(by: Self.stableOrder)
    }

    /// Newest-created first. Sorting by creation date (not last-edited) keeps
    /// a note's position stable — opening or editing a note no longer jumps
    /// it to the top of the list.
    private static func stableOrder(_ a: Note, _ b: Note) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return a.id.uuidString > b.id.uuidString   // deterministic tie-break
    }

    /// Folders a note can be moved into (real, writable folders only).
    func movableFolders() -> [NoteFolder] {
        let systems = folders.filter { $0.systemKind == .notes }
        let customs = folders.filter { $0.systemKind == nil }.sorted { $0.sortOrder < $1.sortOrder }
        return systems + customs
    }

    /// PEN-18 — search across what's actually ON the page, not just the
    /// title and the sticky note.
    ///
    /// Search covers typed page content, Penpal replies, tags and the local
    /// handwriting transcript generated after a quiet pause. The transcript
    /// is stored separately from the original ink and remains best-effort.
    private func filterSearch(_ notes: [Note]) -> [Note] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return notes }
        return notes.filter { $0.matchesSearch(q) }
    }

    func childFolders(of parentID: UUID?) -> [NoteFolder] {
        folders
            .filter { $0.parentID == parentID && $0.systemKind == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    func rootCustomFolders() -> [NoteFolder] {
        folders
            .filter { $0.parentID == nil && $0.systemKind == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    // MARK: Mutations

    func selectFolder(_ id: UUID) {
        selectedFolderID = id
        let visible = visibleNotes()
        if let current = selectedNoteID, visible.contains(where: { $0.id == current }) {
            return
        }
        selectedNoteID = visible.first?.id
    }

    func selectNote(_ id: UUID?) {
        selectedNoteID = id
    }

    @discardableResult
    func createNote(in folderID: UUID? = nil, kind: NoteKind = .ink) -> Note {
        let targetFolder = resolveWritableFolderID(folderID)
        var note = Note(folderID: targetFolder)
        note.title = ""
        if kind == .coded {
            note.kind = .coded
            note.htmlContent = CodedPaper.starterHTML
        }
        notes.insert(note, at: 0)
        selectedFolderID = targetFolder
        selectedNoteID = note.id
        // Prefer the concrete folder, not All Notes / Deleted.
        if let f = folders.first(where: { $0.id == targetFolder }) {
            selectedFolderID = f.id
        }
        scheduleSave()
        return note
    }

    private func resolveWritableFolderID(_ preferred: UUID?) -> UUID {
        if let preferred,
           let f = folders.first(where: { $0.id == preferred }),
           f.systemKind == nil || f.systemKind == .notes {
            return preferred
        }
        if let notesFolder = folders.first(where: { $0.systemKind == .notes }) {
            return notesFolder.id
        }
        return folders.first(where: { $0.systemKind == nil })?.id ?? folders.first?.id ?? UUID()
    }

    func updateNote(_ note: Note) {
        // flushEditor passes the full note including its current drawing —
        // any pending live-ink commit for it is superseded.
        if pendingDrawing?.id == note.id {
            pendingDrawing = nil
            drawingCommitTask?.cancel()
        }
        guard let idx = notes.firstIndex(where: { $0.id == note.id }) else { return }
        // Opening and closing a note used to bump modifiedAt even when
        // nothing changed. Only touch the note if content actually differs.
        let existing = notes[idx]
        if existing.title == note.title,
           existing.body == note.body,
           existing.drawingData == note.drawingData,
           existing.attachments == note.attachments,
           (existing.typedTexts ?? []) == (note.typedTexts ?? []),
           (existing.replyInks ?? []) == (note.replyInks ?? []),
           (existing.codeBlocks ?? []) == (note.codeBlocks ?? []),
           existing.kind == note.kind,
           existing.htmlContent == note.htmlContent,
           existing.normalizedTags == note.normalizedTags,
           existing.pinned == note.pinned,
           existing.folderID == note.folderID {
            // Layout migration should survive reopening without moving an
            // otherwise untouched note to the top of the recents list.
            if existing.paperWidth != note.paperWidth {
                notes[idx].paperWidth = note.paperWidth
                scheduleSave()
            }
            return
        }
        var updated = note
        // The editor does not own OCR. Preserve a completed index when it is
        // saving the same drawing, and invalidate/rebuild only when the ink
        // actually changed.
        if existing.drawingData == note.drawingData {
            updated.handwritingTranscript = existing.handwritingTranscript
        } else {
            updated.handwritingTranscript = nil
            scheduleHandwritingIndex(for: note.id, drawing: note.drawing)
        }
        updated.modifiedAt = .now
        notes[idx] = updated
        scheduleSave()
    }

    // Live ink updates arrive on every stroke. Serializing the PKDrawing and
    // publishing `notes` (which re-renders the whole list + thumbnails) per
    // stroke makes writing stutter — coalesce into one commit per pause.
    private var pendingDrawing: (id: UUID, drawing: PKDrawing, revision: UUID)?
    private var drawingCommitTask: Task<Void, Never>?
    private var handwritingIndexTasks: [UUID: Task<Void, Never>] = [:]
    private var handwritingIndexRevisions: [UUID: UUID] = [:]

    func updateSelectedDrawing(_ drawing: PKDrawing) {
        guard let id = selectedNoteID else { return }
        invalidateHandwritingIndex(for: id)
        let revision = UUID()
        pendingDrawing = (id, drawing, revision)
        drawingCommitTask?.cancel()
        drawingCommitTask = Task { [weak self] in
            // Coalesce pauses between strokes so an active writing session
            // does not repeatedly publish the full notes collection.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self,
                  let pending = self.pendingDrawing,
                  pending.revision == revision else { return }
            // PencilKit's archive grows with the page. Keep that work off the
            // main actor; the revision check below discards stale snapshots.
            let data = await Task.detached(priority: .utility) {
                pending.drawing.dataRepresentation()
            }.value
            guard !Task.isCancelled,
                  self.pendingDrawing?.revision == revision else { return }
            self.commitPendingDrawing(pending, data: data)
        }
    }

    private func commitPendingDrawing() {
        guard let pending = pendingDrawing else { return }
        commitPendingDrawing(pending, data: pending.drawing.dataRepresentation())
    }

    private func commitPendingDrawing(
        _ pending: (id: UUID, drawing: PKDrawing, revision: UUID),
        data: Data
    ) {
        guard pendingDrawing?.revision == pending.revision else { return }
        pendingDrawing = nil
        guard let idx = notes.firstIndex(where: { $0.id == pending.id }) else { return }
        guard notes[idx].drawingData != data else {
            if notes[idx].handwritingTranscript == nil {
                scheduleHandwritingIndex(for: pending.id, drawing: pending.drawing)
            }
            return
        }
        notes[idx].drawingData = data
        notes[idx].handwritingTranscript = nil
        notes[idx].modifiedAt = .now
        scheduleSave()
        scheduleHandwritingIndex(for: pending.id, drawing: pending.drawing)
    }

    /// OCR runs only after a quiet pause, locally, and on the exact drawing
    /// revision it saw. A later stroke cancels the older index task, so search
    /// can never show words from ink the user has subsequently erased.
    private func scheduleHandwritingIndex(for id: UUID, drawing: PKDrawing) {
        let revision = UUID()
        handwritingIndexRevisions[id] = revision
        handwritingIndexTasks[id]?.cancel()
        handwritingIndexTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            let transcript = await InkRecognizer.recognize(strokes: drawing.strokes)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !Task.isCancelled,
                  let self,
                  let idx = self.notes.firstIndex(where: { $0.id == id }),
                  self.handwritingIndexRevisions[id] == revision else { return }
            self.handwritingIndexTasks[id] = nil
            self.handwritingIndexRevisions[id] = nil
            guard self.notes[idx].handwritingTranscript != transcript else { return }
            self.notes[idx].handwritingTranscript = transcript.isEmpty ? nil : transcript
            self.scheduleSave()
        }
    }

    private func invalidateHandwritingIndex(for id: UUID) {
        handwritingIndexTasks[id]?.cancel()
        handwritingIndexTasks[id] = nil
        // This also invalidates OCR that's already running and cannot be
        // cancelled by Vision while the user is adding another stroke.
        handwritingIndexRevisions[id] = UUID()
    }

    /// AI hand-written replies for the selected note (persisted with it).
    /// PEN-18 — records a written reply's text so the page can be found later.
    /// Called as the reply is rendered, where the text is still known.
    func recordReplyText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let id = selectedNoteID,
              let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        var transcript = notes[idx].replyTranscript ?? []
        guard transcript.last != trimmed else { return }   // avoid re-renders
        transcript.append(trimmed)
        // Bounded: a long session shouldn't grow the note file without limit.
        if transcript.count > 100 { transcript.removeFirst(transcript.count - 100) }
        notes[idx].replyTranscript = transcript
        scheduleSave()
    }

    func updateSelectedReplyInks(_ inks: [ReplyInk]) {
        guard let id = selectedNoteID,
              let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        guard (notes[idx].replyInks ?? []) != inks else { return }
        notes[idx].replyInks = inks
        notes[idx].modifiedAt = .now
        scheduleSave()
    }

    /// Embedded coded assets (graphs/widgets) for the selected note.
    func updateSelectedCodeBlocks(_ blocks: [CodeBlock]) {
        guard let id = selectedNoteID,
              let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        guard (notes[idx].codeBlocks ?? []) != blocks else { return }
        notes[idx].codeBlocks = blocks.isEmpty ? nil : blocks
        notes[idx].modifiedAt = .now
        scheduleSave()
    }

    /// Typed Penpal chat texts for the selected note (persisted with it).
    func updateSelectedTypedTexts(_ texts: [TypedNoteText]) {
        guard let id = selectedNoteID,
              let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        guard (notes[idx].typedTexts ?? []) != texts else { return }
        notes[idx].typedTexts = texts
        notes[idx].modifiedAt = .now
        scheduleSave()
    }

    /// HTML source for a coded paper (persisted with it). Targets an explicit
    /// note ID — the selection may already have moved on when a debounced
    /// save from the editor lands.
    func updateHTML(_ html: String, for id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }),
              notes[idx].isCoded else { return }
        guard notes[idx].htmlContent != html else { return }
        notes[idx].htmlContent = html
        notes[idx].modifiedAt = .now
        scheduleSave()
    }

    func updateSelectedBody(_ body: String) {
        guard let id = selectedNoteID,
              let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        guard notes[idx].body != body else { return }
        notes[idx].body = body
        if notes[idx].title.isEmpty {
            let first = body.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            if first.count <= 60 { notes[idx].title = first }
        }
        notes[idx].modifiedAt = .now
        scheduleSave()
    }

    func updateSelectedTitle(_ title: String) {
        guard let id = selectedNoteID,
              let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        guard notes[idx].title != title else { return }
        notes[idx].title = title
        notes[idx].modifiedAt = .now
        scheduleSave()
    }

    func deleteNote(_ id: UUID, permanently: Bool = false) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        if permanently || notes[idx].isDeleted {
            let runtimeIDs = (notes[idx].codeBlocks ?? [])
                .filter { $0.resolvedKind == .interactive }
                .map(\.id)
            for att in notes[idx].attachments {
                try? FileManager.default.removeItem(at: attachmentsDir.appendingPathComponent(att.filename))
            }
            notes.remove(at: idx)
            InteractiveRuntimeStorage.remove(blockIDs: runtimeIDs)
        } else {
            notes[idx].deletedAt = .now
            notes[idx].modifiedAt = .now
        }
        if selectedNoteID == id {
            selectedNoteID = visibleNotes().first?.id
        }
        scheduleSave()
    }

    func restoreNote(_ id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[idx].deletedAt = nil
        notes[idx].modifiedAt = .now
        scheduleSave()
    }

    func moveNote(_ id: UUID, to folderID: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[idx].folderID = folderID
        notes[idx].deletedAt = nil
        notes[idx].modifiedAt = .now
        scheduleSave()
    }

    func renameNote(_ id: UUID, to title: String) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[idx].title = title
        notes[idx].modifiedAt = .now
        scheduleSave()
    }

    /// Tags are deliberately normalized at the storage boundary so search and
    /// future smart folders do not need to guess whether `Math`, `math`, and
    /// ` math ` are three different courses.
    func updateTags(_ rawTags: [String], for id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        var seen = Set<String>()
        let cleaned = rawTags.compactMap { raw -> String? in
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { return nil }
            let key = tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { return nil }
            return String(tag.prefix(40))
        }
        guard notes[idx].normalizedTags != cleaned else { return }
        notes[idx].tags = cleaned.isEmpty ? nil : cleaned
        notes[idx].modifiedAt = .now
        scheduleSave()
    }

    func setPinned(_ pinned: Bool, for id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }),
              notes[idx].pinned != pinned else { return }
        notes[idx].isPinned = pinned ? true : nil
        notes[idx].modifiedAt = .now
        scheduleSave()
    }

    // MARK: Batch operations (multi-select)

    func deleteNotes(_ ids: Set<UUID>, permanently: Bool = false) {
        for id in ids { deleteNote(id, permanently: permanently) }
    }

    func restoreNotes(_ ids: Set<UUID>) {
        for id in ids { restoreNote(id) }
    }

    func moveNotes(_ ids: Set<UUID>, to folderID: UUID) {
        for id in ids { moveNote(id, to: folderID) }
    }

    // MARK: Recently Deleted management

    func emptyRecentlyDeleted() {
        let deleted = notes.filter(\.isDeleted)
        let runtimeIDs = deleted.flatMap { note in
            (note.codeBlocks ?? [])
                .filter { $0.resolvedKind == .interactive }
                .map(\.id)
        }
        for note in deleted {
            for att in note.attachments {
                try? FileManager.default.removeItem(at: attachmentsDir.appendingPathComponent(att.filename))
            }
        }
        notes.removeAll { $0.isDeleted }
        InteractiveRuntimeStorage.remove(blockIDs: runtimeIDs)
        if let sel = selectedNoteID, !notes.contains(where: { $0.id == sel }) {
            selectedNoteID = visibleNotes().first?.id
        }
        scheduleSave()
    }

    func recoverAllDeleted() {
        for i in notes.indices where notes[i].isDeleted {
            notes[i].deletedAt = nil
            notes[i].modifiedAt = .now
        }
        scheduleSave()
    }

    @discardableResult
    func createFolder(named name: String, parentID: UUID? = nil) -> NoteFolder {
        let order = (folders.map(\.sortOrder).max() ?? 0) + 1
        let folder = NoteFolder(name: name, parentID: parentID, sortOrder: order)
        folders.append(folder)
        scheduleSave()
        return folder
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard let idx = folders.firstIndex(where: { $0.id == id }) else { return }
        guard folders[idx].systemKind == nil else { return }
        folders[idx].name = name
        scheduleSave()
    }

    func deleteFolder(_ id: UUID) {
        guard let folder = folders.first(where: { $0.id == id }),
              folder.systemKind == nil else { return }
        let fallback = resolveWritableFolderID(nil)
        for i in notes.indices where notes[i].folderID == id {
            notes[i].folderID = fallback
        }
        // Re-parent children to root
        for i in folders.indices where folders[i].parentID == id {
            folders[i].parentID = folder.parentID
        }
        folders.removeAll { $0.id == id }
        if selectedFolderID == id {
            selectFolder(fallback)
        }
        scheduleSave()
    }

    func toggleExpanded(_ id: UUID) {
        guard let idx = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[idx].isExpanded.toggle()
        scheduleSave()
    }

    func addAttachment(imageData: Data, to noteID: UUID) -> NoteAttachment? {
        guard let idx = notes.firstIndex(where: { $0.id == noteID }) else { return nil }
        let filename = "\(UUID().uuidString).jpg"
        let url = attachmentsDir.appendingPathComponent(filename)
        do {
            try imageData.write(to: url)
        } catch {
            return nil
        }
        let att = NoteAttachment(filename: filename)
        notes[idx].attachments.append(att)
        notes[idx].modifiedAt = .now
        scheduleSave()
        return att
    }

    func attachmentURL(_ attachment: NoteAttachment) -> URL {
        attachmentsDir.appendingPathComponent(attachment.filename)
    }

    func removeAttachment(_ attachmentID: UUID, from noteID: UUID) {
        guard let nIdx = notes.firstIndex(where: { $0.id == noteID }) else { return }
        guard let aIdx = notes[nIdx].attachments.firstIndex(where: { $0.id == attachmentID }) else { return }
        let filename = notes[nIdx].attachments[aIdx].filename
        try? FileManager.default.removeItem(at: attachmentsDir.appendingPathComponent(filename))
        notes[nIdx].attachments.remove(at: aIdx)
        notes[nIdx].modifiedAt = .now
        scheduleSave()
    }

    // MARK: Portable backup and recovery

    /// Creates a self-contained `.penpalbackup` archive. The archive includes
    /// the notebook metadata, PencilKit drawings and attachments; it is safe
    /// to keep in Files, iCloud Drive, Google Drive or an external disk.
    func exportNotebookBackup() throws -> URL {
        flushToDisk()
        let contents = NotebookBackupContents(
            folders: folders,
            notes: notes,
            selectedFolderID: selectedFolderID,
            selectedNoteID: selectedNoteID
        )
        return try NotebookBackup.write(contents, attachmentsDirectory: attachmentsDir)
    }

    /// Merges a backup rather than replacing the live library. This is the
    /// only safe default for recovery: an import must never erase a semester
    /// of newer local work. Existing note IDs win; a future conflict UI can
    /// offer side-by-side resolution for an intentionally restored revision.
    @discardableResult
    func restoreNotebookBackup(from archive: URL) throws -> NotebookBackupRestoreSummary {
        flushToDisk()
        let restore = try NotebookBackup.read(from: archive)

        let importedFolderIDs = Set(restore.contents.folders.map(\.id))
        let fallbackFolderID = resolveWritableFolderID(nil)
        var skippedExistingNotes = 0
        var skippedMissingAttachments = 0
        var copiedAttachmentURLs: [URL] = []
        var stagedNotes: [Note] = []

        do {
            for original in restore.contents.notes {
                guard !notes.contains(where: { $0.id == original.id }) else {
                    skippedExistingNotes += 1
                    continue
                }
                var note = original
                if !importedFolderIDs.contains(note.folderID)
                    && !folders.contains(where: { $0.id == note.folderID }) {
                    note.folderID = fallbackFolderID
                }

                var restoredAttachments: [NoteAttachment] = []
                for attachment in note.attachments {
                    guard let data = restore.attachmentData[attachment.filename] else {
                        skippedMissingAttachments += 1
                        continue
                    }
                    let ext = URL(fileURLWithPath: attachment.filename).pathExtension
                    let filename = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
                    let destination = attachmentsDir.appendingPathComponent(filename)
                    try data.write(to: destination, options: .atomic)
                    copiedAttachmentURLs.append(destination)
                    restoredAttachments.append(NoteAttachment(id: attachment.id,
                                                              filename: filename,
                                                              createdAt: attachment.createdAt))
                }
                note.attachments = restoredAttachments
                stagedNotes.append(note)
            }
        } catch {
            // A full disk or failed file write must not leave a half-restored
            // notebook behind. The live metadata has not changed yet, and
            // every attachment written by this import is ours to remove.
            for url in copiedAttachmentURLs { try? FileManager.default.removeItem(at: url) }
            throw error
        }

        var importedFolders = 0
        for folder in restore.contents.folders where !folders.contains(where: { $0.id == folder.id }) {
            folders.append(folder)
            importedFolders += 1
        }
        ensureSystemFolders()
        notes.append(contentsOf: stagedNotes)

        if selectedFolderID == nil { selectedFolderID = restore.contents.selectedFolderID }
        if selectedNoteID == nil { selectedNoteID = restore.contents.selectedNoteID }
        if selectedFolder == nil { selectedFolderID = fallbackFolderID }
        if selectedNote == nil { selectedNoteID = visibleNotes().first?.id }
        scheduleSave()
        return NotebookBackupRestoreSummary(
            importedNotes: stagedNotes.count,
            importedFolders: importedFolders,
            skippedExistingNotes: skippedExistingNotes,
            skippedMissingAttachments: skippedMissingAttachments
        )
    }

    // MARK: Persistence

    // nonisolated: encoded + written on a background queue by DebouncedSaver.
    nonisolated private struct Snapshot: Codable, @unchecked Sendable {
        var folders: [NoteFolder]
        var notes: [Note]
        var selectedFolderID: UUID?
        var selectedNoteID: UUID?
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    /// Commit any debounced work and write to disk immediately. Called when
    /// the app is backgrounded so nothing is lost if iOS kills it before the
    /// debounce timers fire.
    func flushToDisk() {
        guard !isLoading else { return }
        drawingCommitTask?.cancel()
        commitPendingDrawing()
        saveTask?.cancel()
        saveNow()
    }

    private func saveNow() {
        // Snapshot is a value type — encode + write on a background queue so
        // big drawings never block the pen.
        let snap = Snapshot(folders: folders, notes: notes,
                            selectedFolderID: selectedFolderID,
                            selectedNoteID: selectedNoteID)
        let url = saveURL
        diskSaver.schedule {
            DebouncedSaver.write(snap, to: url, label: "NotesStore")
        }
    }

    nonisolated private static func readSnapshot(from url: URL) -> Snapshot? {
        if let data = try? Data(contentsOf: url),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: data),
           !snap.folders.isEmpty {
            return snap
        }
        return nil
    }

    private func apply(_ snap: Snapshot) {
        folders = snap.folders
        notes = snap.notes
        migrateRemovingDeprecatedSystemFolders()
        selectedFolderID = snap.selectedFolderID ?? folders.first(where: { $0.systemKind == .notes })?.id
        selectedNoteID = snap.selectedNoteID
        ensureSystemFolders()
        if selectedFolder == nil {
            selectedFolderID = folders.first(where: { $0.systemKind == .notes })?.id
        }
        if selectedNoteID == nil {
            selectedNoteID = visibleNotes().first?.id
        }
    }

    /// Quick Notes + Shared are no longer used — strip them and rehome any notes.
    private func migrateRemovingDeprecatedSystemFolders() {
        let deprecated = folders.filter { $0.systemKind == .quickNotes || $0.systemKind == .shared }
        guard !deprecated.isEmpty else { return }
        let fallback = folders.first(where: { $0.systemKind == .notes })?.id
        let ids = Set(deprecated.map(\.id))
        if let fallback {
            for i in notes.indices where ids.contains(notes[i].folderID) {
                notes[i].folderID = fallback
            }
        }
        folders.removeAll { ids.contains($0.id) }
    }

    private func ensureSystemFolders() {
        let kinds: [NoteFolder.SystemFolderKind] = [.allNotes, .notes, .recentlyDeleted]
        for kind in kinds {
            if !folders.contains(where: { $0.systemKind == kind }) {
                folders.append(systemFolder(kind))
            }
        }
    }

    private func systemFolder(_ kind: NoteFolder.SystemFolderKind) -> NoteFolder {
        switch kind {
        case .allNotes:
            return NoteFolder(name: "All Notes", sortOrder: -30, systemKind: .allNotes)
        case .notes:
            return NoteFolder(name: "Notes", sortOrder: -20, systemKind: .notes)
        case .recentlyDeleted:
            return NoteFolder(name: "Recently Deleted", sortOrder: 9_999, systemKind: .recentlyDeleted)
        case .quickNotes, .shared:
            return NoteFolder(name: "", sortOrder: 0)
        }
    }

    private func seed() {
        let all = systemFolder(.allNotes)
        let notesFolder = systemFolder(.notes)
        let deleted = systemFolder(.recentlyDeleted)
        let designing = NoteFolder(name: "Designing", sortOrder: 1)
        let robot = NoteFolder(name: "Robot", sortOrder: 2)
        let college = NoteFolder(name: "College", isExpanded: true, sortOrder: 3)
        let lectures = NoteFolder(name: "Lectures", parentID: college.id, sortOrder: 4)
        let important = NoteFolder(name: "Important Notes", isExpanded: true, sortOrder: 5)
        let ideas = NoteFolder(name: "Ideas", parentID: important.id, sortOrder: 6)

        folders = [all, notesFolder, designing, robot, college, lectures, important, ideas, deleted]

        let welcome = Note(
            folderID: notesFolder.id,
            title: "Welcome to Penpal Notes",
            body: "Write freely with the system pen tray.\n\nTurn on Penpal mode (signature button) and it reads your handwriting and writes back.\n\nAll Penpal settings live under ⋯"
        )
        notes = [welcome]
        selectedFolderID = notesFolder.id
        selectedNoteID = welcome.id
        saveNow()
    }
}
