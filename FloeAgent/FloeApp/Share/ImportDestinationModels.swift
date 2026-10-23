// SPDX-License-Identifier: MPL-2.0
//
// FloeApp — inbound import destination model + durable decision ledger.
//
// Ambiguous external entries (Share-extension envelopes and common-file
// "Open In") must offer an explicit choice between 导入手记 (Notes),
// 导入任务 (Task draft) and 导入画布 (Canvas materials). The requirement to
// ask lives durably in the staged record itself
// (`destinationChoiceRequired`, written atomically at intake) — never in a
// side journal — so a missing, corrupt or unready ledger entry can only
// HOLD the entry, never silently default it. The ledger then persists each
// explicit choice together with stable per-item identities BEFORE any copy
// runs, so a restart continues exactly the chosen destination: no duplicate
// Notes on retry, no duplicate materials (the material boundary is content
// hash addressed), no accidental Task duplication when interrupted after a
// commit, and never a navigation or empty canvas the user did not confirm.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation

// MARK: - Destination

enum ImportDestination: String, Codable, Sendable {
    case notes
    case task
    /// Files enter the durable material library through the EXISTING
    /// `CreativeAssetIngestionService` boundary and target-canvas insertion
    /// / creation runs through the injected `CanvasDestinationCommitting`
    /// seam. This chooser never mutates canvas editor state and never
    /// commits a new canvas before the files are proven importable.
    case canvas
}

enum ImportDestinationOrigin: Hashable, Sendable {
    /// A staged Share-extension envelope awaiting an explicit destination.
    case shareEnvelope(UUID)
    /// A durable DocumentIntake queue record from an ambiguous external open.
    case documentEvent(UUID)

    var identity: UUID {
        switch self {
        case .shareEnvelope(let id), .documentEvent(let id): return id
        }
    }

    fileprivate var ledgerPrefix: String {
        switch self {
        case .shareEnvelope: return "share"
        case .documentEvent: return "event"
        }
    }
}

extension ImportDestinationOrigin: Codable {
    private enum CodingKeys: String, CodingKey { case kind, id }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(String.self, forKey: .kind)
        let id = try values.decode(UUID.self, forKey: .id)
        switch kind {
        case "shareEnvelope": self = .shareEnvelope(id)
        case "documentEvent": self = .documentEvent(id)
        default: throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "unknown origin kind"
            )
        )
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .shareEnvelope(let id):
            try values.encode("shareEnvelope", forKey: .kind)
            try values.encode(id, forKey: .id)
        case .documentEvent(let id):
            try values.encode("documentEvent", forKey: .kind)
            try values.encode(id, forKey: .id)
        }
    }
}

/// The Canvas target confirmed in the compact picker. Persisted BEFORE any
/// copy. `newCanvas` only records intent; the canvas itself is committed by
/// the Canvas-owned committer after every file's import is proven (an
/// aborted or cancelled choice creates no canvas).
enum CanvasDestinationTarget: Hashable, Sendable {
    case existing(canvasID: UUID)
    case newCanvas

    var canvasID: UUID? {
        switch self {
        case .existing(let id): return id
        case .newCanvas: return nil
        }
    }
}

/// The Task target confirmed in the compact picker. `newTask` reuses the
/// existing deferred Home draft semantics (the reviewed share card applies
/// to the Home draft; no empty conversation is created before handoff).
/// `existing` names one persisted ordinary task: the merge runs through the
/// SAME durable `ComposerDraftStore.commitDurable` + envelope-bound receipt
/// primitive the Home adapter uses, preserving that task's draft text and
/// attachments and never sending or running. The identity is persisted
/// BEFORE any copy. Temporary sessions are RAM-only and never persisted
/// targets; the provider filter enforces this against the store as well.
enum TaskDestinationTarget: Hashable, Sendable {
    case newTask
    case existing(conversationID: UUID)

    var conversationID: UUID? {
        switch self {
        case .existing(let id): return id
        case .newTask: return nil
        }
    }
}

extension TaskDestinationTarget: Codable {
    private enum CodingKeys: String, CodingKey { case kind, conversationID }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(String.self, forKey: .kind)
        switch kind {
        case "newTask":
            self = .newTask
        case "existing":
            self = .existing(conversationID: try values.decode(UUID.self, forKey: .conversationID))
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown task target kind"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .newTask:
            try values.encode("newTask", forKey: .kind)
        case .existing(let conversationID):
            try values.encode("existing", forKey: .kind)
            try values.encode(conversationID, forKey: .conversationID)
        }
    }
}

extension CanvasDestinationTarget: Codable {
    private enum CodingKeys: String, CodingKey { case kind, canvasID }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(String.self, forKey: .kind)
        switch kind {
        case "existing":
            self = .existing(canvasID: try values.decode(UUID.self, forKey: .canvasID))
        case "newCanvas":
            self = .newCanvas
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown canvas target kind"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .existing(let canvasID):
            try values.encode("existing", forKey: .kind)
            try values.encode(canvasID, forKey: .canvasID)
        case .newCanvas:
            try values.encode("newCanvas", forKey: .kind)
        }
    }
}

// MARK: - Choice surface

/// One ambiguous inbound entry offered to the user. `fileNames` is display
/// metadata only (never a path).
struct ImportDestinationRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let origin: ImportDestinationOrigin
    let itemCount: Int
    let fileNames: [String]
    /// True when the entry also carries shared text.
    let includesText: Bool
    /// Source state time. A queue retry that reopens the same durable
    /// record advances it, which re-arms exactly one fresh choice.
    let sourceUpdated: Date
}

/// Outcome of an explicit destination choice, mapped to concise user copy
/// by the presenting surface. `.taskReady` / `.canvasReady` mean the
/// destination now owns the bytes and the scene MAY act on it; arrival
/// alone never does.
enum ImportDestinationResult: Equatable, Sendable {
    /// Notes choice for a document event: the existing staged import
    /// resumes under the queue's own recovery semantics.
    case notesQueued
    /// Notes choice for a share envelope: every planned document is proven
    /// committed and the envelope was acknowledged (or settles on a later
    /// pass after a proven commit).
    case notesImported(documentCount: Int)
    /// Task choice durable: for `.newTask` the envelope is (or already was)
    /// staged pending for the reviewed Home card (the scene may navigate);
    /// for `.existing` the confirmed task's durable draft slot already holds
    /// the merge (no navigation happens).
    case taskReady(target: TaskDestinationTarget)
    /// Canvas choice durable: every item is a proven material-library
    /// asset and the source envelope/queue record has been released.
    case canvasReady(itemCount: Int)
    /// Another share/import is in flight; nothing changed.
    case deferred
    /// The choice did not run; the source stays exactly as it was.
    case failed(message: String)
}

// MARK: - Durable decision

/// A per-origin explicit-choice record. For share→Notes imports `units`
/// carry the stable per-item identity (manifest storage name, or the single
/// joined "text" unit) plus the exact pre-allocated Notes document id,
/// persisted BEFORE any import attempt; after a crash the planned identity
/// is the only proof used (never title or content matching). For Canvas the
/// existing material boundary is content-hash idempotent, so the ledger
/// records the proven asset id after ingest and a retry returns the same
/// record. For documentEvent→Task the staged envelope id is persisted
/// before the envelope commit, so a restart proves the hand-off and never
/// stages a second envelope.
struct ImportDestinationDecision: Codable, Equatable {
    static let currentSchemaVersion = 1

    /// Written only by an explicit user choice.
    enum Status: String, Codable {
        case notes
        case task
        case canvas
    }

    struct Unit: Codable, Equatable {
        /// Stable identity within the envelope: an item's generated
        /// `storageName`, "text" for the joined text/URL unit, or "file"
        /// for the single staged document-event payload.
        var key: String
        /// Notes: exact pre-allocated destination document id.
        var plannedDocumentID: UUID?
        /// Canvas: exact pre-allocated node identity persisted BEFORE any
        /// copy. The Canvas-owned committer must insert by this id (or
        /// prove the same-id node already exists), so a retry after a CAS
        /// failure can never duplicate a node.
        var plannedNodeID: UUID?
        var committedAt: Date?
    }

    var schemaVersion: Int
    var origin: ImportDestinationOrigin
    var status: Status
    var chosenAt: Date?
    /// documentEvent + task: the exact envelope this decision staged.
    var envelopeID: UUID?
    /// shareEnvelope + notes: the pre-planned Notes identities.
    var units: [Unit]
    /// Canvas: the target confirmed in the picker, persisted before copy.
    var canvasTarget: CanvasDestinationTarget?
    /// Canvas: durable operation identity for this origin's commit. A retry
    /// after a Canvas CAS failure re-sends the SAME operationID, so the
    /// Canvas-owned committer can dedupe the whole attempt.
    var canvasOperationID: UUID?
    /// Canvas + New Canvas target: the exact planned canvas UUID persisted
    /// BEFORE the copy. Creation must use this id (or prove it already
    /// exists), so a retry can never create a second canvas.
    var plannedCanvasID: UUID?
    /// Task: the target confirmed in the picker, persisted before copy.
    var taskTarget: TaskDestinationTarget?
    var updatedAt: Date

    init(
        origin: ImportDestinationOrigin,
        status: ImportDestinationDecision.Status,
        chosenAt: Date?,
        envelopeID: UUID? = nil,
        units: [Unit] = [],
        canvasTarget: CanvasDestinationTarget? = nil,
        canvasOperationID: UUID? = nil,
        plannedCanvasID: UUID? = nil,
        taskTarget: TaskDestinationTarget? = nil,
        updatedAt: Date
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.origin = origin
        self.status = status
        self.chosenAt = chosenAt
        self.envelopeID = envelopeID
        self.units = units
        self.canvasTarget = canvasTarget
        self.canvasOperationID = canvasOperationID
        self.plannedCanvasID = plannedCanvasID
        self.taskTarget = taskTarget
        self.updatedAt = updatedAt
    }
}

// MARK: - Ledger

/// Tiny atomic JSON files, one per origin, under the app-owned Application
/// Support root (same location family as the DocumentIntake queue). Writes
/// are durable-synced. Availability FAILS CLOSED: no temporary-directory
/// fallback, because these files are choice receipts, not scratch. When
/// unavailable the chooser reports an actionable unavailable state and the
/// queue gate keeps flagged records held with their staged input intact.
final class ImportDestinationDecisionStore: @unchecked Sendable {
    /// nil when durable Application Support storage is unavailable.
    static func production(
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> ImportDestinationDecisionStore? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let root = base
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("ImportDestinations", isDirectory: true)
        return ImportDestinationDecisionStore(root: root, now: now)
    }

    let root: URL
    let isAvailable: Bool
    private let io = NSLock()
    private let now: @Sendable () -> Date

    init(root: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        let manager = FileManager.default
        let canonical = root.standardizedFileURL
        self.root = canonical
        self.now = now
        var created = false
        do {
            try manager.createDirectory(at: canonical, withIntermediateDirectories: true)
            created = manager.fileExists(atPath: canonical.path)
        } catch {
            created = false
        }
        self.isAvailable = created
    }

    /// Queue-gate answer. A build without any ledger must still fail closed
    /// for records that durably carry the choice requirement; an unflagged
    /// record (legacy entry, own-format restore, explicit in-product
    /// importer) keeps its existing pipeline unchanged.
    static func autoImportIsCleared(
        for record: DocumentIntakeRecord,
        decision: ImportDestinationDecision?
    ) -> Bool {
        guard record.destinationChoiceRequired == true else { return true }
        return decision?.status == .notes
    }

    func autoImportIsCleared(for record: DocumentIntakeRecord) -> Bool {
        guard record.destinationChoiceRequired == true else { return true }
        return Self.autoImportIsCleared(for: record, decision: load(.documentEvent(record.id)))
    }

    private func fileURL(for origin: ImportDestinationOrigin) -> URL {
        root.appendingPathComponent(
            "\(origin.ledgerPrefix)-\(origin.identity.uuidString).json",
            isDirectory: false
        )
    }

    func load(_ origin: ImportDestinationOrigin) -> ImportDestinationDecision? {
        io.lock()
        defer { io.unlock() }
        let url = fileURL(for: origin)
        guard DocumentIntakeStorage.isRegularFileNotSymlink(url),
              let size = DocumentIntakeStorage.fileSize(url),
              size > 0, size <= 262_144,
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decision = try? decoder.decode(ImportDestinationDecision.self, from: data),
              decision.schemaVersion == ImportDestinationDecision.currentSchemaVersion,
              decision.origin == origin else { return nil }
        return decision
    }

    @discardableResult
    func save(_ decision: ImportDestinationDecision) throws -> ImportDestinationDecision {
        io.lock()
        defer { io.unlock() }
        guard isAvailable else { throw DocumentIntakeError.ioFailure }
        var copy = decision
        copy.updatedAt = now()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do { data = try encoder.encode(copy) } catch { throw DocumentIntakeError.ioFailure }
        guard data.count <= 262_144 else { throw DocumentIntakeError.ioFailure }
        try DocumentIntakeStorage.writeDurably(data, to: fileURL(for: decision.origin))
        try? DocumentIntakeStorage.syncDirectory(root)
        return copy
    }

    func remove(_ origin: ImportDestinationOrigin) {
        io.lock()
        defer { io.unlock() }
        let url = fileURL(for: origin)
        guard DocumentIntakeStorage.isRegularFileNotSymlink(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func all() -> [ImportDestinationDecision] {
        io.lock()
        defer { io.unlock() }
        let manager = FileManager.default
        let directories = (try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return directories.compactMap { url in
            guard url.pathExtension == "json",
                  DocumentIntakeStorage.isRegularFileNotSymlink(url),
                  let data = try? Data(contentsOf: url),
                  let decision = try? decoder.decode(ImportDestinationDecision.self, from: data),
                  decision.schemaVersion == ImportDestinationDecision.currentSchemaVersion else { return nil }
            return decision
        }
        .sorted { $0.updatedAt < $1.updatedAt }
    }
}

// MARK: - Kind policy

extension DocumentIntakeKind {
    /// Common external input formats whose destination is genuinely
    /// ambiguous. Own-format restores keep their existing unambiguous
    /// destination.
    var requiresDestinationChoice: Bool {
        switch self {
        case .pdf, .text, .office, .image, .engineering: return true
        case .floeNote, .floeCanvas: return false
        }
    }
}

extension ImportDestinationCenter {
    /// Extension-only classification used at the open-URL callback. An
    /// unsupported or unclassifiable name is NOT treated as ambiguous: the
    /// existing submit path already rejects it visibly.
    static func isAmbiguousExternalOpen(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        guard let kind = DocumentIntakeKind.classify(
            fileExtension: url.pathExtension,
            contentType: nil
        ) else { return false }
        return kind.requiresDestinationChoice
    }
}
#endif
