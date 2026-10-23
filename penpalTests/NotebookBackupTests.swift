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
        let folder = NoteFolder(name: "Physics")
        let attachment = NoteAttachment(filename: "diagram.png")
        let note = Note(folderID: folder.id,
                        title: "Electric fields",
                        body: "Field lines point away from positive charge.",
                        attachments: [attachment])
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
}
