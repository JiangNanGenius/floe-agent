// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeDocuments

/// File formats in Files > New > Document. These do not create new library kinds.
nonisolated enum PersonalOfficeFormat: String, Sendable, CaseIterable, Identifiable {
    case word = "docx", workbook = "xlsx", presentation = "pptx", plainText = "md"
    var id: String { rawValue }
}

/// Runs inside PersonalContentLibrary's unpublished staging directory. The
/// original belongs to the record, independently of a chat or a Notes resource.
nonisolated enum PersonalOfficeOriginalFactory {
    @discardableResult static func create(format: PersonalOfficeFormat, title: String, directory: URL) throws -> URL {
        let manager = FileManager.default
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let originals = directory.appendingPathComponent("Original", isDirectory: true)
        // Never replace an existing original or silently create a second one.
        guard !manager.fileExists(atPath: originals.path) else { throw CocoaError(.fileWriteFileExists) }
        try manager.createDirectory(at: originals, withIntermediateDirectories: false)
        let file = originals.appendingPathComponent("Document").appendingPathExtension(format.rawValue)
        switch format {
        case .word:
            try OfficeDocumentBuilder.createWord(at: file, title: title, paragraphs: [""])
        case .workbook:
            try OfficeDocumentBuilder.createWorkbook(at: file, sheets: [.init(name: "Sheet1", rows: [[]])])
        case .presentation:
            try OfficeDocumentBuilder.createPresentation(at: file, title: title, slides: [.init(title: title)])
        case .plainText:
            try Data(("# " + title + "\n\n").utf8).write(to: file, options: .atomic)
        }
        try verify(format: format, url: file)
        return file
    }

    static func verify(format: PersonalOfficeFormat, url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 0) > 0, url.pathExtension.lowercased() == format.rawValue else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if format != .plainText {
            let snapshot = try OfficeDocumentService.inspect(url: url)
            guard snapshot.kind.rawValue == format.rawValue else { throw CocoaError(.fileReadCorruptFile) }
        }
    }
}
