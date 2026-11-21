import XCTest
import PencilKit
import UIKit
@testable import penpal

final class NotebookBackupTests: XCTestCase {

    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testRoundTripKeepsNotesFoldersAndAttachmentsTogether() throws {
        let testDate = Date(timeIntervalSince1970: 1_700_000_000)
        let folder = NoteFolder(name: "Physics")
        let attachment = NoteAttachment(filename: "diagram.png", createdAt: testDate)
        let note = Note(folderID: folder.id,
                        title: "Electric fields",
                        body: "Field lines point away from positive charge.",
                        attachments: [attachment],
                        createdAt: testDate,
                        modifiedAt: testDate)
        let sourceAttachments = temporaryDirectory.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceAttachments,
                                                withIntermediateDirectories: true)
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        try imageData.write(to: sourceAttachments.appendingPathComponent(attachment.filename))

        let contents = NotebookBackupContents(folders: [folder], notes: [note],
                                              selectedFolderID: folder.id,
                                              selectedNoteID: note.id,
                                              exportedAt: Date(timeIntervalSince1970: 0))
        let archiveURL = try NotebookBackup.write(contents, attachmentsDirectory: sourceAttachments)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let restored = try NotebookBackup.read(from: archiveURL)
        XCTAssertEqual(restored.contents.formatVersion, NotebookBackupContents.currentFormatVersion)
        XCTAssertEqual(restored.contents.folders, [folder])
        XCTAssertEqual(restored.contents.notes, [note])
        XCTAssertEqual(restored.contents.selectedFolderID, folder.id)
        XCTAssertEqual(restored.attachmentData[attachment.filename], imageData)
    }

    func testWriteRejectsUnsafeAttachmentFilename() throws {
        let folder = NoteFolder(name: "Physics")
        let note = Note(folderID: folder.id,
                        attachments: [NoteAttachment(filename: "../outside.png")])
        let contents = NotebookBackupContents(folders: [folder], notes: [note],
                                              selectedFolderID: nil, selectedNoteID: nil)

        XCTAssertThrowsError(try NotebookBackup.write(contents,
                                                      attachmentsDirectory: temporaryDirectory)) { error in
            XCTAssertEqual(error as? NotebookBackupError,
                           .invalidAttachmentName("../outside.png"))
        }
    }

    func testFolderIconAndColorSurviveBackupRoundTrip() throws {
        let testDate = Date(timeIntervalSince1970: 1_700_000_000)
        let folder = NoteFolder(name: "Calculus", iconName: "x.squareroot", colorName: "indigo")
        let note = Note(folderID: folder.id,
                        title: "",
                        body: "",
                        createdAt: testDate,
                        modifiedAt: testDate,
                        tags: ["Calculus", "Exam"],
                        isPinned: true,
                        handwritingTranscript: "Integration by parts\nu dv = uv - int v du")

        XCTAssertEqual(note.displayTitle, "Integration by parts")
        XCTAssertEqual(note.preview, "u dv = uv - int v du")
        XCTAssertTrue(note.matchesSearch("#exam"))
        XCTAssertTrue(note.matchesSearch("parts"))
        XCTAssertFalse(note.matchesSearch("#biology"))

        let contents = NotebookBackupContents(folders: [folder], notes: [note],
                                              selectedFolderID: folder.id,
                                              selectedNoteID: note.id,
                                              exportedAt: testDate)
        let archiveURL = try NotebookBackup.write(contents, attachmentsDirectory: temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let restored = try NotebookBackup.read(from: archiveURL)
        let restoredFolder = try XCTUnwrap(restored.contents.folders.first)
        XCTAssertEqual(restoredFolder.iconName, "x.squareroot")
        XCTAssertEqual(restoredFolder.colorName, "indigo")
        XCTAssertEqual(restoredFolder.resolvedIconName, "x.squareroot")
    }

    @MainActor
    func testNotesStoreManagementOperations() async {
        let store = NotesStore.shared
        await store.waitUntilLoaded()

        let parent = store.createFolder(named: "Maths Test Parent", iconName: "function", colorName: "blue")
        let child = store.createFolder(named: "Linear Algebra Test", parentID: parent.id)
        let n1 = store.createNote(in: parent.id)
        store.renameNote(n1.id, to: "Zeta")
        let n2 = store.createNote(in: child.id)
        store.renameNote(n2.id, to: "Alpha")
        store.updateTags(["Eigenvalues", "Exam"], for: n2.id)
        store.setPinned(true, for: n2.id)

        // Recursive count includes nested subfolder notes.
        XCTAssertEqual(store.recursiveNoteCount(for: parent), 2)
        // Parent cannot be moved inside its own descendant.
        let validParents = store.validParentFolders(for: parent.id).map(\.folder.id)
        XCTAssertFalse(validParents.contains(parent.id))
        XCTAssertFalse(validParents.contains(child.id))

        // Duplicate note creates a distinct, unpinned copy with its own ID.
        let copy = store.duplicateNote(n2.id)
        XCTAssertNotNil(copy)
        XCTAssertNotEqual(copy?.id, n2.id)
        XCTAssertEqual(copy?.pinned, false)
        XCTAssertEqual(copy?.folderID, child.id)

        // Tag filter + Title sorting.
        let prevSort = store.noteSortOption
        store.selectTagSmartView("Eigenvalues")
        store.noteSortOption = .titleAsc
        let tagged = store.visibleNotes()
        XCTAssertTrue(tagged.contains(where: { $0.id == n2.id }))
        XCTAssertFalse(tagged.contains(where: { $0.id == n1.id }))

        // Cleanup so tests leave shared store tidy.
        store.noteSortOption = prevSort
        store.selectedTagFilter = nil
        store.showPinnedOnly = false
        if let copyID = copy?.id { store.deleteNote(copyID, permanently: true) }
        store.deleteNote(n1.id, permanently: true)
        store.deleteNote(n2.id, permanently: true)
        store.deleteFolder(child.id)
        store.deleteFolder(parent.id)
    }

    @MainActor
    func testDuplicateFolderClonesAttachmentsAndResetsInteractiveBlockIdentity() async throws {
        let store = NotesStore.shared
        await store.waitUntilLoaded()

        let folder = store.createFolder(named: "Folder Dup Source", iconName: "atom", colorName: "amber")
        let note = store.createNote(in: folder.id)
        store.renameNote(note.id, to: "Lab Note")

        // Attach real image data and an interactive block with granted permissions.
        let att = try XCTUnwrap(store.addAttachment(imageData: Data([0x89, 0x50, 0x4E, 0x47]), to: note.id))
        let origBlockID = UUID()
        let block = CodeBlock(
            id: origBlockID,
            html: "<div data-penpal-kind=\"interactive\">Widget</div>",
            kind: .interactive,
            x: 20, y: 40, width: 320, height: 240,
            runtime: InteractiveRuntimeMetadata(
                title: "Widget",
                manifest: .empty,
                allowedDomains: ["cdn.jsdelivr.net"],
                allowedCapabilities: ["clipboard.write"],
                repairAttempts: 2,
                lastRepairSummary: "Fixed"
            )
        )
        store.updateSelectedCodeBlocks([block])

        let dupFolder = try XCTUnwrap(store.duplicateFolder(folder.id))
        XCTAssertEqual(dupFolder.iconName, "atom")
        XCTAssertEqual(dupFolder.colorName, "amber")

        let dupNote = try XCTUnwrap(store.notes.first(where: { $0.folderID == dupFolder.id }))
        let dupAtt = try XCTUnwrap(dupNote.attachments.first)
        XCTAssertNotEqual(dupAtt.filename, att.filename, "Duplicated folder note must copy attachment to a distinct file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.attachmentURL(dupAtt).path))

        let dupBlock = try XCTUnwrap(dupNote.codeBlocks?.first)
        XCTAssertNotEqual(dupBlock.id, origBlockID, "Duplicated folder note must assign a fresh CodeBlock ID")
        XCTAssertEqual(dupBlock.runtime?.allowedDomains, [])
        XCTAssertEqual(dupBlock.runtime?.allowedCapabilities, [])
        XCTAssertEqual(dupBlock.runtime?.repairAttempts, 0)
        XCTAssertNil(dupBlock.runtime?.lastRepairSummary)

        // Deleting the duplicated note permanently must NOT delete the original note's attachment file.
        store.deleteNote(dupNote.id, permanently: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.attachmentURL(att).path))

        // Cleanup
        store.deleteNote(note.id, permanently: true)
        store.deleteFolder(dupFolder.id)
        store.deleteFolder(folder.id)
    }

    func testNoteExporterExportsTypedTextOnlyAndCombinedNotes() throws {
        let typed = TypedNoteText(
            text: "¡Hola! Por la mañana.",
            x: 34, y: 120, xHeight: 18, maxX: 640,
            isUserMessage: false,
            fontName: "Georgia-Italic",
            colorHex: "#1A2B2A"
        )
        let files = NoteExporter.shareFiles(
            drawingData: Data(),
            typedTexts: [typed],
            replyInks: [],
            title: "Spanish Practice",
            paperStyle: "ruled"
        )
        let pdfURL = try XCTUnwrap(files.pdf)
        let imgURL = try XCTUnwrap(files.image)
        defer {
            try? FileManager.default.removeItem(at: pdfURL)
            try? FileManager.default.removeItem(at: imgURL)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdfURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imgURL.path))
        let rendered = try XCTUnwrap(NoteExporter.image(
            for: PKDrawing(),
            typedTexts: [typed],
            replyInks: [],
            paperStyle: "ruled"
        ))
        XCTAssertGreaterThan(rendered.size.width, 100)
        XCTAssertGreaterThan(rendered.size.height, 40)
    }
}
