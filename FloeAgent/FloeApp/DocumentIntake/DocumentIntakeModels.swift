// SPDX-License-Identifier: MPL-2.0
//
// FloeApp — system document-open intake models (S5 P3).
//
// A system document open is an intake request, never authority to write back,
// replace an editor or start an agent run. This file owns only the value
// types; the staged copy, durable queue and real Notes/Canvas importers are in
// the sibling files. Every bound below mirrors an existing importer limit; the
// intake does not invent a wider writable-document claim.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import UniformTypeIdentifiers
import FloeCore
import FloeNotes

// MARK: - Kind

/// The finite set of document shapes this build can hand to an existing Floe
/// importer. `.floeCanvas` is canonical lower-case; `.floeCanvas` input file
/// names remain accepted (extension matching is case-insensitive).
enum DocumentIntakeKind: String, Codable, Sendable, CaseIterable {
    case floeNote
    case floeCanvas
    case pdf
    case text
    case office
    case image
    case engineering

    /// Safe fallback extension for the app-owned staged copy. The original
    /// extension is preserved where the real importer dispatches on it
    /// (Office/engineering/text), because a generated `.docx` name would make
    /// an `.xlsx` workbook open through the wrong engine.
    var canonicalExtension: String {
        switch self {
        case .floeNote: "floenote"
        case .floeCanvas: "floecanvas"
        case .pdf: "pdf"
        case .text: "txt"
        case .office: "docx"
        case .image: "img"
        case .engineering: "cad"
        }
    }

    /// Existing importer ceilings. Text matches `NoteFileImporter`'s 2,000,000
    /// byte UTF-8 read; per-resource imports match `NotesStore`'s 512 MiB;
    /// portable archives match `NotesArchive`'s 2 GiB total; canvas packages
    /// match `CanvasBackupPackage`'s file-backed 2 GiB ceiling.
    var maximumBytes: Int64 {
        switch self {
        case .floeNote, .floeCanvas: 2_147_483_648
        case .text: 2_000_000
        case .pdf, .office, .image, .engineering: 536_870_912
        }
    }

    /// Notes owns its own durable library, independent from task deletion.
    /// Canvas owns its own project files. The two editors never share state.
    var importsIntoNotes: Bool { self != .floeCanvas }
}

extension DocumentIntakeKind {
    static let officeExtensions: Set<String> = [
        "docx", "doc", "odt", "rtf", "xlsx", "xls", "ods", "pptx", "ppt", "odp",
    ]
    static let textExtensions: Set<String> = ["txt", "md", "markdown", "csv", "json"]
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp", "avif",
    ]

    static let floeNoteType = UTType(exportedAs: "org.floeagent.note", conformingTo: .data)
    static let floeCanvasType = UTType(exportedAs: "org.floeagent.canvas", conformingTo: .data)

    /// Classifies exactly the formats the existing Notes/Canvas importers
    /// already accept. Unknown types are rejected instead of being forced
    /// through an image fallback.
    static func classify(fileExtension: String, contentType: UTType?) -> DocumentIntakeKind? {
        let ext = fileExtension.lowercased()
        if ext == "floenote" || contentType?.identifier == floeNoteType.identifier {
            return .floeNote
        }
        if ext == "floecanvas" || contentType?.identifier == floeCanvasType.identifier {
            return .floeCanvas
        }
        if ext == "pdf" || contentType?.conforms(to: .pdf) == true {
            return .pdf
        }
        if officeExtensions.contains(ext) { return .office }
        if NoteDocument.supportedEngineeringFileExtensions.contains(ext) { return .engineering }
        if textExtensions.contains(ext) || contentType?.conforms(to: .plainText) == true {
            return .text
        }
        if imageExtensions.contains(ext) || contentType?.conforms(to: .image) == true {
            return .image
        }
        return nil
    }

    /// The staged name is generated, never a user path: `payload.` plus a
    /// lower-case ASCII extension selected from the real importer's format
    /// set. Office and engineering subtypes keep their exact extension.
    static func stagedExtension(for kind: DocumentIntakeKind, originalExtension: String) -> String {
        let ext = originalExtension.lowercased()
        switch kind {
        case .floeNote: return "floenote"
        case .floeCanvas: return "floecanvas"
        case .pdf: return "pdf"
        case .office: return officeExtensions.contains(ext) ? ext : "docx"
        case .engineering:
            return NoteDocument.supportedEngineeringFileExtensions.contains(ext) ? ext : "cad"
        case .text: return textExtensions.contains(ext) ? ext : "txt"
        case .image:
            let safe = !ext.isEmpty && ext.utf8.count <= 16
                && ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
            return safe ? ext : "img"
        }
    }

    static func stagedFileName(for kind: DocumentIntakeKind, originalExtension: String) -> String {
        "payload." + stagedExtension(for: kind, originalExtension: originalExtension)
    }

    static func isValidStagedFileName(_ name: String, kind: DocumentIntakeKind) -> Bool {
        let prefix = "payload."
        guard name.hasPrefix(prefix) else { return false }
        let ext = String(name.dropFirst(prefix.count))
        guard !ext.isEmpty, ext.utf8.count <= 16,
              ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              ext == ext.lowercased() else { return false }
        switch kind {
        case .floeNote: return ext == "floenote"
        case .floeCanvas: return ext == "floecanvas"
        case .pdf: return ext == "pdf"
        case .office: return officeExtensions.contains(ext)
        case .engineering: return NoteDocument.supportedEngineeringFileExtensions.contains(ext)
        case .text: return textExtensions.contains(ext)
        case .image:
            // The real image importer sniffs the bytes; the generated,
            // path-safe extension is only metadata.
            return true
        }
    }

    /// The original provider name is display metadata only: bounded, no path
    /// separators and no control characters. It is never used to build a path.
    static func displayName(from url: URL) -> String {
        let raw = url.lastPathComponent
        let replaced = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let cleaned = replaced.filter { character in
            !character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        let bounded = String(cleaned.prefix(240)).trimmingCharacters(in: .whitespacesAndNewlines)
        return bounded.isEmpty ? "Document" : bounded
    }
}

// MARK: - Limits

/// Explicit, injectable bounds. Production uses the product limits; focused
/// tests use much smaller values against a real temporary filesystem.
struct DocumentIntakeLimits: Sendable, Equatable {
    var maximumPendingEntries: Int
    var maximumQueuedBytes: Int64
    /// In-process duplicate callbacks are coalesced for this long; durable
    /// content-identity dedupe uses the same window while an entry is still
    /// pending/importing. A committed entry never suppresses a later reimport.
    var duplicateWindow: TimeInterval
    /// Failed/cancelled/needs-review inputs stay recoverable for this long.
    var recoverableLifetime: TimeInterval
    /// Committed receipts are retained (without their payload) for this long.
    var receiptLifetime: TimeInterval
    /// Incomplete staging directories are cleaned after this long.
    var incompleteStagingLifetime: TimeInterval
    var maximumRecordBytes: Int

    static let production = DocumentIntakeLimits(
        maximumPendingEntries: 12,
        maximumQueuedBytes: 4 * 1024 * 1024 * 1024,
        duplicateWindow: 300,
        recoverableLifetime: 7 * 86_400,
        receiptLifetime: 30 * 86_400,
        incompleteStagingLifetime: 7 * 86_400,
        maximumRecordBytes: 262_144
    )
}

// MARK: - Durable record

enum DocumentIntakeState: String, Codable, Sendable {
    /// Visible in the durable queue and eligible for one automatic attempt.
    case pending
    /// A live claim owns this entry. A live process holds the OS file lock.
    case importing
    /// An import was interrupted after the importer may have committed. This
    /// is never retried automatically: a second import must be user-chosen.
    case needsReview
    case committed
    /// Cancelled before commit. The staged input stays recoverable until the
    /// recoverable lifetime expires; the original is untouched.
    case cancelled
    /// A definite failure. The staged input stays recoverable for an explicit
    /// retry or discard.
    case failed
}

struct DocumentIntakeCommit: Codable, Sendable, Equatable {
    var rootDocumentID: UUID?
    var documentIDs: [UUID]
    var canvasID: UUID?
    var title: String?
    var committedAt: Date

    init(
        rootDocumentID: UUID? = nil,
        documentIDs: [UUID] = [],
        canvasID: UUID? = nil,
        title: String? = nil,
        committedAt: Date
    ) {
        self.rootDocumentID = rootDocumentID
        self.documentIDs = documentIDs
        self.canvasID = canvasID
        self.title = title
        self.committedAt = committedAt
    }
}

/// One durable intake event. `id` is the queue identity; `plannedRootDocumentID`
/// is the exact Notes identity pre-allocated before commit, so a restart can
/// prove a committed import without comparing titles or content.
struct DocumentIntakeRecord: Codable, Sendable, Equatable, Identifiable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: UUID
    var kind: DocumentIntakeKind
    var displayName: String
    var stagedFileName: String
    var byteCount: Int64
    var sha256: String
    var contentTypeIdentifier: String?
    var plannedRootDocumentID: UUID
    var createdAt: Date
    var updatedAt: Date
    var sceneID: String?
    var requestSequence: UInt64
    var state: DocumentIntakeState
    var attemptCount: Int
    var claimToken: String?
    var claimedAt: Date?
    var failureCode: String?
    var failureDetail: String?
    var commit: DocumentIntakeCommit?

    init(
        id: UUID,
        kind: DocumentIntakeKind,
        displayName: String,
        stagedFileName: String,
        byteCount: Int64,
        sha256: String,
        contentTypeIdentifier: String?,
        plannedRootDocumentID: UUID,
        createdAt: Date,
        sceneID: String?,
        requestSequence: UInt64
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.stagedFileName = stagedFileName
        self.byteCount = byteCount
        self.sha256 = sha256
        self.contentTypeIdentifier = contentTypeIdentifier
        self.plannedRootDocumentID = plannedRootDocumentID
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.sceneID = sceneID
        self.requestSequence = requestSequence
        self.state = .pending
        self.attemptCount = 0
        self.claimToken = nil
        self.claimedAt = nil
        self.failureCode = nil
        self.failureDetail = nil
        self.commit = nil
    }

    var failure: DocumentIntakeFailure? {
        failureCode.flatMap(DocumentIntakeFailure.init(rawValue:))
    }

    var receipt: DocumentIntakeReceipt? {
        guard state == .committed, let commit else { return nil }
        return DocumentIntakeReceipt(
            id: id,
            kind: kind,
            documentID: commit.rootDocumentID,
            canvasID: commit.canvasID,
            title: commit.title ?? displayName,
            originalName: displayName,
            committedAt: commit.committedAt
        )
    }
}

struct DocumentIntakeStagingRequest: Sendable, Equatable {
    var eventID: UUID
    var plannedRootDocumentID: UUID
    var sceneID: String?
    var requestSequence: UInt64
    var receivedAt: Date
}

struct DocumentIntakeStagedInput: Sendable {
    var record: DocumentIntakeRecord
    var directory: URL
    /// Held while the staging directory is private to this attempt. The queue
    /// closes it after the atomic rename (or after a duplicate/capacity
    /// refusal); maintenance treats a lockable `.active` file as abandoned.
    var activeLock: DocumentIntakeFileLock?

    var payloadURL: URL {
        directory.appendingPathComponent(record.stagedFileName, isDirectory: false)
    }
}

// MARK: - Queue snapshot / presentation

struct DocumentIntakeQueueSnapshot: Sendable {
    var records: [DocumentIntakeRecord]
    var corruptCount: Int
}

struct DocumentIntakeMaintenanceReport: Sendable, Equatable {
    var recoveredStaging: Int
    var removedIncompleteStaging: Int
    /// Valid staging copies superseded by an existing identical queue or
    /// receipt entry. Removing them prevents a later duplicate import.
    var removedDuplicateStaging: Int
    var removedExpiredRecords: Int
    var removedReceipts: Int
    var corruptRecords: Int
}

struct DocumentIntakeReceipt: Equatable, Sendable, Identifiable {
    let id: UUID
    let kind: DocumentIntakeKind
    let documentID: UUID?
    let canvasID: UUID?
    let title: String
    let originalName: String
    let committedAt: Date
}

struct DocumentIntakePresentation: Equatable, Sendable, Identifiable {
    let id: UUID
    let kind: DocumentIntakeKind
    let documentID: UUID?
    let canvasID: UUID?
    let title: String
    let sceneID: String?
}

struct DocumentIntakeNoteOpenRequest: Equatable, Sendable, Identifiable {
    /// Unique per request so a view's `.task(id:)` runs again even when the
    /// same imported document is requested twice.
    let id: UUID
    let eventID: UUID
    let documentID: UUID
    let title: String
    /// The originating scene. A Notes view in another window must not adopt
    /// the same import and move that window's selected note.
    let sceneID: String?
}

/// A committed result that was NOT auto-presented. The user keeps a real Open
/// action instead of the import stealing the current task or editor.
struct DocumentIntakeOpenOffer: Equatable, Sendable, Identifiable {
    enum Reason: String, Equatable, Sendable {
        /// The user navigated away from the origin selection while a long
        /// import ran; the routing fence retained the result.
        case userNavigated
        /// The target surface was busy (another canvas cover is open).
        case targetBusy
    }

    let id: UUID
    let eventID: UUID
    let kind: DocumentIntakeKind
    let documentID: UUID?
    let canvasID: UUID?
    let title: String
    /// The originating scene; the re-armed presentation keeps its once-only,
    /// scene-bound claim semantics.
    let sceneID: String?
    let reason: Reason
}

struct DocumentIntakeActivity: Equatable, Sendable, Identifiable {
    enum Phase: String, Sendable {
        case staging
        case importing
    }

    let id: UUID
    let phase: Phase
    let displayName: String
    let kind: DocumentIntakeKind?
}

struct DocumentIntakeNotice: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case success
        case failure
        case info
    }

    let id: UUID
    let kind: Kind
    let message: String
    let eventID: UUID?
    let canRetry: Bool
    let canDiscard: Bool
    /// The notice carries a retained committed result that the user can open
    /// explicitly (see `DocumentIntakeOpenOffer`).
    let canOpen: Bool

    init(
        id: UUID = UUID(),
        kind: Kind,
        message: String,
        eventID: UUID? = nil,
        canRetry: Bool = false,
        canDiscard: Bool = false,
        canOpen: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.message = message
        self.eventID = eventID
        self.canRetry = canRetry
        self.canDiscard = canDiscard
        self.canOpen = canOpen
    }
}

enum DocumentIntakeCancelOutcome: Equatable, Sendable {
    case cancelling
    case cancelled
    case alreadyCommitted(DocumentIntakeReceipt)
    case notFound
    case busy
}

// MARK: - Failures

enum DocumentIntakeFailure: String, Codable, Sendable, CaseIterable {
    case unsupported
    case notAFile
    case linkNotAllowed
    case emptyFile
    case tooLarge
    case accessDenied
    case damaged
    case importFailed
    case notesUnavailable
    case canvasUnavailable
    case queueFull
    case queueUnavailable
    case cancelled
    case interrupted
    case claimBusy
    case claimLost
    case corruptRecord
    case ioFailure

    var message: String {
        switch self {
        case .unsupported:
            FloeL10n.l("document.intake.unsupported")
        case .notAFile:
            FloeL10n.l("document.intake.not_a_file")
        case .linkNotAllowed:
            FloeL10n.l("document.intake.link_not_allowed")
        case .emptyFile:
            FloeL10n.l("document.intake.empty")
        case .tooLarge:
            FloeL10n.l("document.intake.too_large")
        case .accessDenied:
            FloeL10n.l("document.intake.access_denied")
        case .damaged:
            FloeL10n.l("document.intake.damaged")
        case .importFailed:
            FloeL10n.l("document.intake.import_failed")
        case .notesUnavailable:
            FloeL10n.l("document.intake.notes_unavailable")
        case .canvasUnavailable:
            FloeL10n.l("document.intake.canvas_unavailable")
        case .queueFull:
            FloeL10n.l("document.intake.queue_full")
        case .queueUnavailable:
            FloeL10n.l("document.intake.queue_unavailable")
        case .cancelled:
            FloeL10n.l("document.intake.cancelled")
        case .interrupted:
            FloeL10n.l("document.intake.interrupted")
        case .claimBusy, .claimLost:
            FloeL10n.l("document.intake.import_failed")
        case .ioFailure:
            FloeL10n.l("document.intake.io_failed")
        case .corruptRecord:
            FloeL10n.l("document.intake.queue_unavailable")
        }
    }
}

enum DocumentIntakeError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedType
    case notAFile
    case linkNotAllowed
    case emptyFile
    case tooLarge(Int64)
    case accessDenied
    case damaged
    case queueFull
    case queueUnavailable
    case importFailed
    case notesUnavailable
    case canvasUnavailable
    case cancelled
    case claimBusy
    case claimLost
    case corruptRecord
    case ioFailure

    var failure: DocumentIntakeFailure {
        switch self {
        case .unsupportedType: .unsupported
        case .notAFile: .notAFile
        case .linkNotAllowed: .linkNotAllowed
        case .emptyFile: .emptyFile
        case .tooLarge: .tooLarge
        case .accessDenied: .accessDenied
        case .damaged: .damaged
        case .queueFull: .queueFull
        case .queueUnavailable: .queueUnavailable
        case .importFailed: .importFailed
        case .notesUnavailable: .notesUnavailable
        case .canvasUnavailable: .canvasUnavailable
        case .cancelled: .cancelled
        case .claimBusy: .claimBusy
        case .claimLost: .claimLost
        case .corruptRecord: .corruptRecord
        case .ioFailure: .ioFailure
        }
    }

    var errorDescription: String? { failure.message }
}

/// A bounded, user-facing failure. The internal code is for diagnostics only;
/// normal copy never includes a queue identity or filesystem path.
struct DocumentIntakeFailureNotice: Equatable, Sendable {
    let code: DocumentIntakeFailure
    let detail: String?

    var message: String { detail ?? code.message }

    static func map(_ error: Error) -> DocumentIntakeFailureNotice {
        if let value = error as? DocumentIntakeError {
            return DocumentIntakeFailureNotice(code: value.failure, detail: nil)
        }
        if let value = error as? NoteError {
            return DocumentIntakeFailureNotice(
                code: .importFailed,
                detail: Self.bounded(value.localizedDescription)
            )
        }
        return DocumentIntakeFailureNotice(code: .importFailed, detail: nil)
    }

    private static func bounded(_ value: String) -> String? {
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let bounded = String(collapsed.prefix(240))
        return bounded.isEmpty ? nil : bounded
    }
}

// MARK: - Route bridge

extension DocumentIntakeCenter {
    /// The primary App entry calls this after `FloeAppEntryRoute.parse`.
    /// Only `.externalFile` reaches file intake; every other route keeps the
    /// router's existing navigation behavior.
    @discardableResult
    func handleEntryRoute(_ route: FloeAppEntryRoute, sceneID: String?) -> Bool {
        guard case .externalFile(let url) = route else { return false }
        submit(url, sceneID: sceneID)
        return true
    }
}
#endif
