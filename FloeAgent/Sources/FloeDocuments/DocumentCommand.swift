// FloeDocuments — Semantic document commands (iOS-only target).
// See blazing-aurora-darwin.md §5.8. Commands are semantic mutations
// independent of editor screen coordinates; the LibreOffice/Collabora
// bridge implementation lands in M4.

import Foundation
import FloeCore
import FloeTools

/// Semantic document mutation commands exposed to the agent.
public enum DocumentCommand: Sendable, Codable, Hashable {
    case createDocument(kind: DocumentKind, name: String)
    case readText(range: TextRange?)
    case replaceText(range: TextRange, newText: String)
    case applyStyle(range: TextRange, style: StyleSpec)
    case insertTable(rows: Int, columns: Int, at: InsertPosition)
    case setCellFormula(table: Int, cell: CellAddress, formula: String)
    case insertImage(imageID: UUID, at: InsertPosition)
    case addComment(range: TextRange, text: String)
    case insertSlide(layout: SlideLayout, at: Int)
    case exportAs(format: ExportFormat, destination: String)

    public enum DocumentKind: String, Sendable, Codable, Hashable {
        case text, spreadsheet, presentation
    }

    /// Character-offset range within the document body.
    public struct TextRange: Sendable, Codable, Hashable {
        public var start: Int
        public var end: Int

        public init(start: Int, end: Int) {
            self.start = start
            self.end = end
        }
    }

    public struct StyleSpec: Sendable, Codable, Hashable {
        public var bold: Bool?
        public var italic: Bool?
        public var fontSize: Double?
        public var fontName: String?
        public var colorHex: String?

        public init(
            bold: Bool? = nil,
            italic: Bool? = nil,
            fontSize: Double? = nil,
            fontName: String? = nil,
            colorHex: String? = nil
        ) {
            self.bold = bold
            self.italic = italic
            self.fontSize = fontSize
            self.fontName = fontName
            self.colorHex = colorHex
        }
    }

    public struct InsertPosition: Sendable, Codable, Hashable {
        public var characterOffset: Int

        public init(characterOffset: Int) {
            self.characterOffset = characterOffset
        }
    }

    public struct CellAddress: Sendable, Codable, Hashable {
        public var row: Int
        public var column: Int

        public init(row: Int, column: Int) {
            self.row = row
            self.column = column
        }
    }

    public enum SlideLayout: String, Sendable, Codable, Hashable {
        case title, titleAndBody, sectionHeader, blank
    }

    public enum ExportFormat: String, Sendable, Codable, Hashable {
        case pdf, docx, xlsx, pptx, odt, ods, odp, markdown, html
    }

    /// Validates command parameters before they reach the bridge.
    public func validate() throws {
        switch self {
        case .createDocument(_, let name):
            guard !name.isEmpty, name.count <= 255 else {
                throw FloeError.validationFailed("Document name must be 1-255 characters")
            }
        case .readText(let range):
            if let range { try Self.validate(range) }
        case .replaceText(let range, let newText):
            try Self.validate(range)
            guard newText.utf8.count <= 1_048_576 else {
                throw FloeError.validationFailed("Replacement text exceeds 1 MiB")
            }
        case .applyStyle(let range, let style):
            try Self.validate(range)
            if let size = style.fontSize {
                guard (1...1000).contains(size) else {
                    throw FloeError.validationFailed("Font size out of range")
                }
            }
            if let hex = style.colorHex {
                guard hex.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil else {
                    throw FloeError.validationFailed("colorHex must be #RRGGBB")
                }
            }
        case .insertTable(let rows, let columns, let at):
            guard (1...1000).contains(rows), (1...100).contains(columns) else {
                throw FloeError.validationFailed("Table dimensions out of range")
            }
            guard at.characterOffset >= 0 else {
                throw FloeError.validationFailed("Insert position must be non-negative")
            }
        case .setCellFormula(let table, let cell, let formula):
            guard table >= 0, cell.row >= 0, cell.column >= 0 else {
                throw FloeError.validationFailed("Cell address must be non-negative")
            }
            guard formula.utf8.count <= 8192 else {
                throw FloeError.validationFailed("Formula exceeds 8 KiB")
            }
        case .insertImage(_, let at):
            guard at.characterOffset >= 0 else {
                throw FloeError.validationFailed("Insert position must be non-negative")
            }
        case .addComment(let range, let text):
            try Self.validate(range)
            guard text.utf8.count <= 16_384 else {
                throw FloeError.validationFailed("Comment exceeds 16 KiB")
            }
        case .insertSlide(_, let at):
            guard at >= 0, at <= 10_000 else {
                throw FloeError.validationFailed("Slide index out of range")
            }
        case .exportAs(_, let destination):
            guard !destination.isEmpty else {
                throw FloeError.validationFailed("Export destination required")
            }
        }
    }

    private static func validate(_ range: TextRange) throws {
        guard range.start >= 0, range.end >= range.start else {
            throw FloeError.validationFailed("Invalid text range \(range.start)..<\(range.end)")
        }
    }
}

/// Narrow bridge to the document engine (LibreOffice/Collabora core,
/// implemented in M4). The engine owns the document; the agent only sends
/// semantic commands.
public protocol DocumentEngineBridge: Sendable {
    /// Opens a document at `url` and returns an opaque handle.
    func open(url: URL) async throws -> DocumentHandle
    /// Executes one validated command on an open document.
    func execute(_ command: DocumentCommand, on handle: DocumentHandle) async throws -> DocumentCommandResult
    /// Closes the document, flushing pending mutations.
    func close(_ handle: DocumentHandle) async throws
}

/// Opaque reference to an open document.
public struct DocumentHandle: Sendable, Hashable {
    public var id: UUID
    public var url: URL

    public init(id: UUID = UUID(), url: URL) {
        self.id = id
        self.url = url
    }
}

/// Bounded result of one document command.
public struct DocumentCommandResult: Sendable, Hashable {
    public var summary: String
    public var charactersAffected: Int

    public init(summary: String, charactersAffected: Int = 0) {
        self.summary = String(summary.prefix(4096))
        self.charactersAffected = charactersAffected
    }
}

/// M1 stub bridge: every call fails with a structured "not available"
/// error until the M4 engine integration lands.
public struct StubDocumentEngineBridge: DocumentEngineBridge {
    public init() {}

    public func open(url: URL) async throws -> DocumentHandle {
        throw FloeError.internalError("Document engine bridge not available in M1")
    }

    public func execute(_ command: DocumentCommand, on handle: DocumentHandle) async throws -> DocumentCommandResult {
        throw FloeError.internalError("Document engine bridge not available in M1")
    }

    public func close(_ handle: DocumentHandle) async throws {}
}
