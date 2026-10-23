//
//  NotebookBackup.swift
//  penpal
//
//  PEN-40 — a portable, versioned recovery path. Cloud sync is a replica of
//  the local notebook, never the only copy. This archive is intentionally
//  provider-neutral so the exact same data can be restored after a reinstall,
//  moved from iCloud to Google Drive, or kept somewhere entirely outside
//  Penpal.
//

import Foundation

nonisolated struct NotebookBackupContents: Codable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var exportedAt: Date
    var folders: [NoteFolder]
    var notes: [Note]
    var selectedFolderID: UUID?
    var selectedNoteID: UUID?

    init(folders: [NoteFolder],
         notes: [Note],
         selectedFolderID: UUID?,
         selectedNoteID: UUID?,
         exportedAt: Date = .now) {
        formatVersion = Self.currentFormatVersion
        self.exportedAt = exportedAt
        self.folders = folders
        self.notes = notes
        self.selectedFolderID = selectedFolderID
        self.selectedNoteID = selectedNoteID
    }
}

nonisolated struct NotebookBackupRestore {
    let contents: NotebookBackupContents
    let attachmentData: [String: Data]
}

nonisolated enum NotebookBackupError: LocalizedError, Equatable {
    case unsupportedFormat(Int)
    case missingManifest
    case invalidAttachmentName(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let version):
            return "This backup uses Penpal notebook format \(version), which this version of Penpal can’t restore."
        case .missingManifest:
            return "This file isn’t a Penpal notebook backup."
        case .invalidAttachmentName:
            return "This backup contains an unsafe attachment name."
        }
    }
}

nonisolated enum NotebookBackup {
    /// One file instead of a ZIP package. iOS has no Foundation ZIP writer,
    /// and a JSON envelope keeps a backup self-contained without shipping a
    /// third-party compression dependency into the note-taking hot path.
    private struct Archive: Codable {
        var contents: NotebookBackupContents
        var attachments: [String: Data]
    }

    static func write(_ contents: NotebookBackupContents,
                      attachmentsDirectory: URL) throws -> URL {
        let fm = FileManager.default
        var attachments: [String: Data] = [:]
        for attachment in contents.notes.flatMap(\.attachments) {
            try validateAttachmentName(attachment.filename)
            let source = attachmentsDirectory.appendingPathComponent(attachment.filename)
            guard fm.fileExists(atPath: source.path) else { continue }
            attachments[attachment.filename] = try Data(contentsOf: source)
        }

        let outputDirectory = try backupOutputDirectory()
        let output = outputDirectory.appendingPathComponent(filename(for: contents.exportedAt))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(Archive(contents: contents, attachments: attachments))
            .write(to: output, options: .atomic)
        return output
    }

    /// Decodes and validates an archive before anything touches the live
    /// library. Restoring is then a non-destructive merge in `NotesStore`.
    static func read(from archive: URL) throws -> NotebookBackupRestore {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            // Version 1 originally wrote ISO-8601 strings. Keep accepting
            // those archives while writing numeric timestamps so subsecond
            // Date precision survives a backup round trip.
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let value = try container.decode(String.self)
            for options: ISO8601DateFormatter.Options in [
                [.withInternetDateTime, .withFractionalSeconds],
                [.withInternetDateTime]
            ] {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = options
                if let date = formatter.date(from: value) {
                    return date
                }
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Backup contains an invalid ISO-8601 date."
            )
        }
        let decoded: Archive
        do {
            decoded = try decoder.decode(Archive.self, from: Data(contentsOf: archive))
        } catch {
            throw NotebookBackupError.missingManifest
        }
        guard decoded.contents.formatVersion == NotebookBackupContents.currentFormatVersion else {
            throw NotebookBackupError.unsupportedFormat(decoded.contents.formatVersion)
        }
        for attachment in decoded.contents.notes.flatMap(\.attachments) {
            try validateAttachmentName(attachment.filename)
        }
        for filename in decoded.attachments.keys {
            try validateAttachmentName(filename)
        }
        return NotebookBackupRestore(contents: decoded.contents,
                                     attachmentData: decoded.attachments)
    }

    private static func validateAttachmentName(_ name: String) throws {
        guard !name.isEmpty,
              name == URL(fileURLWithPath: name).lastPathComponent,
              !name.contains("..") else {
            throw NotebookBackupError.invalidAttachmentName(name)
        }
    }

    private static func backupOutputDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("PenpalBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func filename(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        let safeDate = formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
        return "Penpal-Notebook-\(safeDate).penpalbackup"
    }
}
