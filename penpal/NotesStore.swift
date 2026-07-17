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

    init(id: UUID = UUID(),
         text: String,
         x: CGFloat,
         y: CGFloat,
         xHeight: CGFloat,
         maxX: CGFloat,
         isUserMessage: Bool,
         createdAt: Date = .now) {
        self.id = id
        self.text = text
        self.x = x
        self.y = y
        self.xHeight = xHeight
        self.maxX = maxX
        self.isUserMessage = isUserMessage
        self.createdAt = createdAt
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

nonisolated struct Note: Identifiable, Codable, Hashable {
    var id: UUID
    var folderID: UUID
    var title: String
    var body: String
    var drawingData: Data
    var attachments: [NoteAttachment]
    /// Typed Penpal chat texts placed on the page (optional for backward
    /// compatibility with notes saved before this existed).
    var typedTexts: [TypedNoteText]?
    /// AI hand-written replies, stored as renderer strokes (optional for
    /// backward compatibility).
    var replyInks: [ReplyInk]?
    var createdAt: Date
    var modifiedAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(),
         folderID: UUID,
         title: String = "",
         body: String = "",
         drawingData: Data = Data(),
         attachments: [NoteAttachment] = [],
         typedTexts: [TypedNoteText]? = nil,
         replyInks: [ReplyInk]? = nil,
         createdAt: Date = .now,
         modifiedAt: Date = .now,
         deletedAt: Date? = nil) {
        self.id = id
        self.folderID = folderID
        self.title = title
        self.body = body
        self.drawingData = drawingData
        self.attachments = attachments
        self.typedTexts = typedTexts
        self.replyInks = replyInks
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.deletedAt = deletedAt
    }

    var isDeleted: Bool { deletedAt != nil }

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let firstLine = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !firstLine.isEmpty { return firstLine }
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
    nonisolated(unsafe) private static let thumbnailCache = NSCache<NSString, UIImage>()

    var thumbnail: UIImage? {
        guard !drawingData.isEmpty else { return nil }
        // Decoding the PKDrawing + rasterizing it is expensive; SwiftUI asks
        // for this on every list refresh, so cache by note id + revision.
        let key = "\(id.uuidString)-\(modifiedAt.timeIntervalSinceReferenceDate)-\(drawingData.count)" as NSString
        if let hit = Self.thumbnailCache.object(forKey: key) { return hit }
        let d = drawing
        guard !d.strokes.isEmpty else { return nil }
        let bounds = d.bounds.insetBy(dx: -20, dy: -20)
        guard bounds.width > 1, bounds.height > 1,
              bounds.width.isFinite, bounds.height.isFinite else { return nil }
        let image = d.image(from: bounds, scale: 1.5)
        Self.thumbnailCache.setObject(image, forKey: key)
        return image
    }
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

    private let saveURL: URL
    private let attachmentsDir: URL
    private var saveTask: Task<Void, Never>?

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        saveURL = docs.appendingPathComponent("notes_store.json")
        attachmentsDir = docs.appendingPathComponent("NoteAttachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
        loadOrSeed()
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

    private func filterSearch(_ notes: [Note]) -> [Note] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return notes }
        return notes.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(q)
                || $0.body.localizedCaseInsensitiveContains(q)
        }
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
    func createNote(in folderID: UUID? = nil) -> Note {
        let targetFolder = resolveWritableFolderID(folderID)
        var note = Note(folderID: targetFolder)
        note.title = ""
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
           existing.folderID == note.folderID {
            return
        }
        var updated = note
        updated.modifiedAt = .now
        notes[idx] = updated
        scheduleSave()
    }

    // Live ink updates arrive on every stroke. Serializing the PKDrawing and
    // publishing `notes` (which re-renders the whole list + thumbnails) per
    // stroke makes writing stutter — coalesce into one commit per pause.
    private var pendingDrawing: (id: UUID, drawing: PKDrawing)?
    private var drawingCommitTask: Task<Void, Never>?

    func updateSelectedDrawing(_ drawing: PKDrawing) {
        guard let id = selectedNoteID else { return }
        pendingDrawing = (id, drawing)
        drawingCommitTask?.cancel()
        drawingCommitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.commitPendingDrawing()
        }
    }

    private func commitPendingDrawing() {
        guard let pending = pendingDrawing else { return }
        pendingDrawing = nil
        guard let idx = notes.firstIndex(where: { $0.id == pending.id }) else { return }
        let newData = pending.drawing.dataRepresentation()
        guard notes[idx].drawingData != newData else { return }
        notes[idx].drawingData = newData
        notes[idx].modifiedAt = .now
        scheduleSave()
    }

    /// AI hand-written replies for the selected note (persisted with it).
    func updateSelectedReplyInks(_ inks: [ReplyInk]) {
        guard let id = selectedNoteID,
              let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        guard (notes[idx].replyInks ?? []) != inks else { return }
        notes[idx].replyInks = inks
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
            for att in notes[idx].attachments {
                try? FileManager.default.removeItem(at: attachmentsDir.appendingPathComponent(att.filename))
            }
            notes.remove(at: idx)
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
        for note in deleted {
            for att in note.attachments {
                try? FileManager.default.removeItem(at: attachmentsDir.appendingPathComponent(att.filename))
            }
        }
        notes.removeAll { $0.isDeleted }
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

    // MARK: Persistence

    // nonisolated: encoded + written on a background queue by DebouncedSaver.
    nonisolated private struct Snapshot: Codable {
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
        Task.detached(priority: .utility) {
            DebouncedSaver.write(snap, to: url, label: "NotesStore")
        }
    }

    private func loadOrSeed() {
        if let data = try? Data(contentsOf: saveURL),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: data),
           !snap.folders.isEmpty {
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
            return
        }
        seed()
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
