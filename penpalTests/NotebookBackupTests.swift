import XCTest
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
}
