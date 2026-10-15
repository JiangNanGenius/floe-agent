// FloeWorkspace — Text reader models (TXT / document reading mode).
//
// SPDX-License-Identifier: MPL-2.0
//
// Shared, Foundation-only value types for the read-only text reader. Nothing
// in this file writes to a source file: reading mode is an alternate view of
// the original document, so every type here is a snapshot or a position and
// the only persistence is the reader position store (a preference).
//
// Byte offsets are always offsets in the ORIGINAL encoded file (or, for a
// Notes text document, in the UTF-8 encoding of its extracted text), never
// offsets into a decoded Swift string. That keeps positions, chapter jumps
// and find hits stable across encodings.

import Foundation

/// Which surface the reader opened.
public enum ReaderSourceKind: String, Codable, Sendable {
    /// A workspace file addressed by relative path (local, cloud, network).
    case workspaceFile
    /// A Notes text document: its own text content, read-only.
    case notesDocument

    public var storageLabel: String { rawValue }
}

/// How the encoding for one open was chosen.
///
/// `auto` keeps the original probe order (BOM → BOM-less UTF-16 → strict
/// UTF-8 → GB18030 with one UTF-8→GB18030 retry). `manual` validates the
/// WHOLE stream in exactly the user-picked encoding and never falls back to
/// another backend: a wrong or contradictory choice fails with a clear error
/// instead of silently decoding as something else.
public enum ReaderEncodingSelection: Hashable, Sendable {
    case auto
    case manual(ReaderTextEncoding)

    public var manualEncoding: ReaderTextEncoding? {
        if case .manual(let encoding) = self { return encoding }
        return nil
    }

    public var isManual: Bool { manualEncoding != nil }

    /// Encodings the UI may offer for manual selection, in display order.
    /// GB18030 is listed only when the runtime really has that codec, so the
    /// reader never advertises an encoding it cannot decode.
    public static func selectableEncodings(gb18030Available: Bool) -> [ReaderTextEncoding] {
        var encodings: [ReaderTextEncoding] = [.utf8, .utf16LittleEndian, .utf16BigEndian]
        if gb18030Available { encodings.append(.gb18030) }
        return encodings
    }
}

/// Opaque, revision-aware identity of one readable document.
///
/// `fingerprint` is supplied by the caller (for files: size + mtime + a
/// bounded content sample digest; for Notes: the digest of the extracted
/// text). A stored reading position is only restored when the fingerprint
/// still matches, so a position never crosses files or revisions blindly.
public struct ReaderDocumentIdentity: Hashable, Sendable {
    public var kind: ReaderSourceKind
    /// Stable owner id (workspace id / note document id).
    public var ownerID: String
    /// Relative path for workspace files; the document id string for notes.
    public var documentKey: String
    /// Display name: file name or note title.
    public var displayName: String
    /// Short format label for the UI: "txt", "md", "notes", …
    public var format: String
    /// Change-detection fingerprint; positions restore only on an exact match.
    public var fingerprint: String

    public init(
        kind: ReaderSourceKind,
        ownerID: String,
        documentKey: String,
        displayName: String,
        format: String,
        fingerprint: String
    ) {
        self.kind = kind
        self.ownerID = ownerID
        self.documentKey = documentKey
        self.displayName = displayName
        self.format = format
        self.fingerprint = fingerprint
    }

    /// Stable, separator-free preference key. The user-visible path is never
    /// used raw, so a rename cannot collide with another document.
    public var storageKey: String {
        let encodedKey = Data(documentKey.utf8).base64EncodedString()
        return "\(kind.storageLabel)|\(ownerID)|\(encodedKey)"
    }
}

/// Explicit reader bounds. Every bound is enforced by the reader core; the UI
/// never claims "the whole book is loaded" because it never is.
public struct ReaderLimits: Sendable, Equatable {
    /// Largest file the reader opens at all (bigger files fail with an
    /// explicit, localized message instead of a truncated silent display).
    public var maxFileBytes: Int64
    /// Raw bytes read per streaming step.
    public var chunkBytes: Int
    /// Raw bytes per rendered window (line-aligned; the window may be smaller
    /// when a single line is longer than this).
    public var windowBytes: Int
    /// Paragraph blocks per rendered window.
    public var maxBlocksPerWindow: Int
    /// Decoded characters per block before the block is split further.
    public var maxBlockCharacters: Int
    /// Raw bytes decoded per source line for display.
    public var maxDisplayLineBytes: Int
    /// Line starts retained in the index; beyond this the table is marked
    /// truncated and only byte offsets remain exact.
    public var maxIndexedLines: Int
    /// Chapter headings retained; beyond this the list is marked truncated.
    public var maxChapters: Int
    /// Longest line (characters) considered as a heading candidate.
    public var maxHeadingCharacters: Int
    /// Find results returned per query.
    public var findLimit: Int
    /// Total raw bytes the finder scans before stopping with `truncated`.
    public var maxFindScanBytes: Int64
    /// Characters of context stored per find hit.
    public var findSnippetCharacters: Int

    public init(
        maxFileBytes: Int64 = 64 * 1024 * 1024,
        chunkBytes: Int = 256 * 1024,
        windowBytes: Int = 64 * 1024,
        maxBlocksPerWindow: Int = 400,
        maxBlockCharacters: Int = 4_000,
        maxDisplayLineBytes: Int = 64 * 1024,
        maxIndexedLines: Int = 1_000_000,
        maxChapters: Int = 20_000,
        maxHeadingCharacters: Int = 120,
        findLimit: Int = 400,
        maxFindScanBytes: Int64 = 64 * 1024 * 1024,
        findSnippetCharacters: Int = 120
    ) {
        self.maxFileBytes = maxFileBytes
        self.chunkBytes = chunkBytes
        self.windowBytes = windowBytes
        self.maxBlocksPerWindow = maxBlocksPerWindow
        self.maxBlockCharacters = maxBlockCharacters
        self.maxDisplayLineBytes = maxDisplayLineBytes
        self.maxIndexedLines = maxIndexedLines
        self.maxChapters = maxChapters
        self.maxHeadingCharacters = maxHeadingCharacters
        self.findLimit = findLimit
        self.maxFindScanBytes = maxFindScanBytes
        self.findSnippetCharacters = findSnippetCharacters
    }

    public static let `default` = ReaderLimits()
}

/// Non-fatal facts about an opened document. The UI states them plainly
/// rather than pretending the index is complete when it was capped.
public enum ReaderNotice: String, Codable, Sendable, CaseIterable {
    /// The line table hit `maxIndexedLines`; line numbers beyond it are not
    /// available (byte offsets and windows still are).
    case lineTableTruncated
    /// The chapter list hit `maxChapters`.
    case chaptersTruncated
    /// The encoding was recovered heuristically (no BOM), not declared.
    case encodingRecovered
    /// The file starts with a BOM that is stripped from every displayed line.
    case byteOrderMarkStripped
    /// A display line exceeded `maxDisplayLineBytes` and was shortened for
    /// that block only; the source file was not modified.
    case displayLineShortened
}

/// A deterministic chapter/heading entry. Titles come from the document text
/// only — no model call and no network access is involved.
public struct ReaderChapterHeading: Sendable, Equatable, Identifiable, Codable {
    public var id: Int64 { byteOffset }
    public var title: String
    public var level: Int
    public var byteOffset: Int64
    public var lineNumber: Int
    public init(title: String, level: Int, byteOffset: Int64, lineNumber: Int) {
        self.title = title
        self.level = level
        self.byteOffset = byteOffset
        self.lineNumber = lineNumber
    }
}

/// One paragraph/heading block inside a window, anchored at its exact source
/// byte offset so scroll positions and window appends stay stable.
public struct ReaderTextBlock: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case body
        case heading(level: Int)
    }
    public var id: Int64 { byteOffset }
    public var byteOffset: Int64
    public var lineNumber: Int
    public var kind: Kind
    public var text: String
    /// True when this block's text continues directly after the previous
    /// block (an oversized single line split for bounded layout), with no
    /// line break in the source between them.
    public var continues: Bool
    public init(byteOffset: Int64, lineNumber: Int, kind: Kind, text: String, continues: Bool = false) {
        self.byteOffset = byteOffset
        self.lineNumber = lineNumber
        self.kind = kind
        self.text = text
        self.continues = continues
    }
}

/// A bounded, line-aligned slice of the document.
public struct ReaderWindow: Sendable, Equatable {
    public var startByte: Int64
    public var endByte: Int64
    public var blocks: [ReaderTextBlock]
    /// The document continues after `endByte`.
    public var hasMore: Bool
    /// The window stopped because it reached `windowBytes` (not EOF).
    public var truncatedAtLimit: Bool
    /// Line number of the first block (1-based); 0 when the line table is
    /// truncated past this point and the exact number is unknown.
    public var startLineNumber: Int
    /// Total line count from the index (0 when unknown).
    public var totalLines: Int
    public var notices: [ReaderNotice]
    /// Byte progress of `endByte` within the document, 0…1.
    public var progress: Double
    public init(
        startByte: Int64,
        endByte: Int64,
        blocks: [ReaderTextBlock],
        hasMore: Bool,
        truncatedAtLimit: Bool,
        startLineNumber: Int,
        totalLines: Int,
        notices: [ReaderNotice],
        progress: Double
    ) {
        self.startByte = startByte
        self.endByte = endByte
        self.blocks = blocks
        self.hasMore = hasMore
        self.truncatedAtLimit = truncatedAtLimit
        self.startLineNumber = startLineNumber
        self.totalLines = totalLines
        self.notices = notices
        self.progress = progress
    }
}

/// One find result, anchored at a verified source byte offset when the
/// encoding allows exact re-encoding; otherwise `exactOffset` is false and
/// the hit points at the start of its containing window.
public struct ReaderFindHit: Sendable, Equatable, Identifiable {
    public var id: Int64 { byteOffset }
    public var byteOffset: Int64
    /// Matched length in source bytes (0 when not exactly known).
    public var byteLength: Int
    /// False when the byte offset could only be resolved to the window start.
    public var exactOffset: Bool
    /// 1-based line number, 0 when unknown.
    public var lineNumber: Int
    /// Bounded context snippet around the match.
    public var snippet: String
    public init(byteOffset: Int64, byteLength: Int, exactOffset: Bool, lineNumber: Int, snippet: String) {
        self.byteOffset = byteOffset
        self.byteLength = byteLength
        self.exactOffset = exactOffset
        self.lineNumber = lineNumber
        self.snippet = snippet
    }
}

/// Outcome of one find pass.
public struct ReaderFindResult: Sendable, Equatable {
    public var hits: [ReaderFindHit]
    /// True when scanning stopped at `findLimit` or `maxFindScanBytes`.
    public var truncated: Bool
    public init(hits: [ReaderFindHit], truncated: Bool) {
        self.hits = hits
        self.truncated = truncated
    }
}

/// Durable reading position. Restored only when `fingerprint` matches the
/// currently opened revision and the encoding it was measured in still
/// matches. The schema version stays 1: `encodingRaw` is an optional addition,
/// so positions written before it decode with `encoding == nil` (those are
/// only restored for an automatic open).
public struct ReaderPosition: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Exact source byte offset of the leading visible block.
    public var anchorByte: Int64
    /// Progress 0…1 for a rough "how far" display.
    public var progress: Double
    /// Fingerprint of the revision this position belongs to.
    public var fingerprint: String
    /// Raw `ReaderTextEncoding` this anchor was measured in; nil for
    /// positions written before the reader tagged the encoding.
    public var encodingRaw: String?
    public var updatedAt: Date

    /// The encoding this anchor belongs to, when it was tagged.
    public var encoding: ReaderTextEncoding? {
        encodingRaw.flatMap(ReaderTextEncoding.init(rawValue:))
    }

    public init(
        anchorByte: Int64,
        progress: Double,
        fingerprint: String,
        encoding: ReaderTextEncoding? = nil,
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.anchorByte = anchorByte
        self.progress = progress.isFinite ? min(1, max(0, progress)) : 0
        self.fingerprint = fingerprint
        self.encodingRaw = encoding?.rawValue
        self.updatedAt = updatedAt
    }
}

/// Reader-side failures. Messages stay technical and content-free; the UI
/// maps each case to concise bilingual copy (and never to file content).
public enum ReaderError: Error, Sendable, Equatable {
    /// The file is larger than `ReaderLimits.maxFileBytes`.
    case fileTooLarge(limit: Int64)
    /// The source is empty.
    case emptyDocument
    /// No supported encoding could be validated over the whole stream.
    case unrecognizedEncoding
    /// A validated stream failed to decode at `byteOffset`.
    case corruptText(byteOffset: Int64)
    /// A manual encoding choice contradicts the file's own encoding mark
    /// (byte-order mark); the stream was not decoded with the wrong backend.
    case encodingConflict(ReaderTextEncoding)
    /// A manual encoding choice could not validate the whole stream (invalid
    /// code units, binary content, or no such codec in this runtime).
    case encodingInvalid(ReaderTextEncoding)
    /// The source could not be read (missing, permission, provider).
    case sourceUnavailable(String)
    /// The read was cancelled by the caller (document switch, dismissal).
    case cancelled
    /// A newer request superseded this one before it produced a result.
    case superseded
}

extension ReaderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileTooLarge(let limit):
            return "File is larger than the reader limit (\(limit / (1024 * 1024)) MiB)."
        case .emptyDocument:
            return "The document is empty."
        case .unrecognizedEncoding:
            return "The text encoding could not be recognized."
        case .corruptText(let offset):
            return "The text could not be decoded at byte \(offset)."
        case .encodingConflict(let chosen):
            return "The file's encoding mark contradicts the selected encoding (\(chosen.displayName))."
        case .encodingInvalid(let chosen):
            return "The selected encoding (\(chosen.displayName)) cannot decode this whole file."
        case .sourceUnavailable(let detail):
            return "The source is unavailable: \(detail)"
        case .cancelled:
            return "Reading was cancelled."
        case .superseded:
            return "A newer request superseded this one."
        }
    }
}

/// Result of opening a document: encoding, index summary and first window.
public struct ReaderOpenResult: Sendable {
    public var identity: ReaderDocumentIdentity
    public var encoding: ReaderTextEncoding
    /// Whether this encoding was detected (`auto`) or chosen by the user.
    public var encodingSelection: ReaderEncodingSelection
    public var byteLength: Int64
    public var totalLines: Int
    public var chapters: [ReaderChapterHeading]
    public var notices: [ReaderNotice]
    public var window: ReaderWindow
    /// Restored position when the stored fingerprint and encoding matched,
    /// else nil.
    public var restoredPosition: ReaderPosition?
    public init(
        identity: ReaderDocumentIdentity,
        encoding: ReaderTextEncoding,
        byteLength: Int64,
        totalLines: Int,
        chapters: [ReaderChapterHeading],
        notices: [ReaderNotice],
        window: ReaderWindow,
        restoredPosition: ReaderPosition?,
        encodingSelection: ReaderEncodingSelection = .auto
    ) {
        self.identity = identity
        self.encoding = encoding
        self.encodingSelection = encodingSelection
        self.byteLength = byteLength
        self.totalLines = totalLines
        self.chapters = chapters
        self.notices = notices
        self.window = window
        self.restoredPosition = restoredPosition
    }
}
