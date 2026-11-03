// SPDX-License-Identifier: MPL-2.0
//
// C08 — selected Notes resources -> real ordinary task launch -> staged
// task-workspace input.
//
// THE MISSING REACHABLE PATH THIS CLOSES
// `NotesResourceStagingService` (C08/B0) already knows how to copy one
// authorized Notes resource into a REAL task workspace with exact revision and
// content-addressed digest checks. It deliberately requires a persisted run
// and workspace. The product had no user-visible call site: the Notes assistant
// is a document-bound `purpose = notes` conversation with no task workspace,
// and the ordinary composer only knew about its own staged attachments.
//
// This file supplies the bounded, App-owned two-phase receipt between the
// user's explicit Notes selection and the ORIGINAL `run.start` lifecycle:
//
//   1. SELECTION (before any run): the user picks resources in Notes and the
//      App creates a REAL ordinary conversation through the ORIGINAL
//      `conversation.create` path, grants read access for exactly that
//      document through the ORIGINAL Notes grant service, and asks this file
//      to prepare an immutable receipt. Preparing validates the selected
//      document revision and every resource's exact Notes metadata/digest,
//      checks the real per-conversation read grant, and writes one bounded
//      receipt file under the accepted generation's app-private storage. It
//      creates no run, no model call, no phantom identity and no workspace
//      file.
//   2. COMMIT (inside the ORIGINAL launch): after the durable
//      `RunLaunchStore.prepare` commits the real run + canonical private-task
//      workspace, and BEFORE the run service/model is assembled, the launch
//      asks this file to consume the receipt and stage the exact bytes. The
//      launch's own exact `RuntimeOwnedWorkRegistry` `.conversation` lease is
//      used (it is already in the run ownership map, so conversation deletion
//      sees/drains it). A rejected/absent lease refuses BEFORE any filesystem
//      effect.
//
// The committed user task input contains the real task-relative destination
// path and the receipt identity. This file verifies that before staging, so the
// model/Linux baseline can never be told about a file that was not committed.
// If the user removed the manifest from the message, the receipt is discarded
// and the ordinary task proceeds without staging; a partially edited manifest
// is a typed refusal, never a silent half-stage.
//
// NOTES ORIGINALS / SHARED STATE
// This file never mutates a Notes document, revision, resource or the Notes
// assistant thread. It does not inherit a Notes-assistant conversation: the
// grant is the ORIGINAL `assistant_scopes` read grant for the REAL ordinary
// task conversation and the exact document. The editor session/undo state is
// unrelated and untouched. The receipt contains only Notes identities,
// digests, byte counts, display names and task-relative destinations.
//
// GUEST EXCHANGE (separately owned C01)
// Staging completes before the run service starts, therefore before any
// `exec.shell` call. When the first command opens a fresh workspace owner, the
// EXISTING `RuntimeWorkspaceSession.importBeforeLaunch` snapshots the task
// workspace and includes these files. A LIVE workspace owner/participant
// (`workspaceReuse`) deliberately skips a second import; that path needs a
// precise C01 incremental refresh/handoff, which this file does not fake.
//
// AUTHORED SOURCE ONLY: not compiled, not executed by this lane.

import Foundation
import Crypto
import FloeCore
import FloeTools
import FloeNotes

// MARK: - Selection / receipt models

public struct C08NotesTaskLaunchResource: Sendable, Equatable, Codable {
    public var resourceID: UUID
    public var sha256: String
    public var byteCount: Int64
    public var fileName: String
    public var mediaType: String

    public init(resourceID: UUID, sha256: String, byteCount: Int64,
                fileName: String, mediaType: String) {
        self.resourceID = resourceID
        self.sha256 = sha256
        self.byteCount = byteCount
        self.fileName = fileName
        self.mediaType = mediaType
    }
}

/// Immutable App-owned selection receipt. It exists before the run and is
/// keyed by the REAL ordinary conversation identity. No absolute path, file
/// content, credential or model text is stored here.
public struct C08NotesTaskLaunchSelection: Sendable, Equatable, Codable {
    public var receiptID: UUID
    public var notesEpoch: UInt64
    public var conversationID: UUID
    public var documentID: UUID
    public var documentRevision: Int
    public var resources: [C08NotesTaskLaunchResource]
    public var createdAtMillis: Int64
    public var expiresAtMillis: Int64

    public init(receiptID: UUID, notesEpoch: UInt64, conversationID: UUID,
                documentID: UUID, documentRevision: Int,
                resources: [C08NotesTaskLaunchResource],
                createdAtMillis: Int64, expiresAtMillis: Int64) {
        self.receiptID = receiptID
        self.notesEpoch = notesEpoch
        self.conversationID = conversationID
        self.documentID = documentID
        self.documentRevision = documentRevision
        self.resources = resources
        self.createdAtMillis = createdAtMillis
        self.expiresAtMillis = expiresAtMillis
    }
}

public struct C08NotesTaskLaunchDestination: Sendable, Equatable, Codable {
    public var resourceID: UUID
    public var relativePath: String

    public init(resourceID: UUID, relativePath: String) {
        self.resourceID = resourceID
        self.relativePath = relativePath
    }
}

public struct C08NotesTaskLaunchPreparation: Sendable, Equatable, Codable {
    public var receiptID: UUID
    public var destinations: [C08NotesTaskLaunchDestination]
    public var totalBytes: Int64

    public init(receiptID: UUID, destinations: [C08NotesTaskLaunchDestination],
                totalBytes: Int64) {
        self.receiptID = receiptID
        self.destinations = destinations
        self.totalBytes = totalBytes
    }
}

public struct C08NotesTaskLaunchCommittedResult: Sendable, Equatable {
    public var receiptID: UUID
    public var destinations: [C08NotesTaskLaunchDestination]

    public init(receiptID: UUID, destinations: [C08NotesTaskLaunchDestination]) {
        self.receiptID = receiptID
        self.destinations = destinations
    }
}

// MARK: - Closed failures

public enum C08NotesTaskLaunchErrorCode: String, Sendable, Codable, CaseIterable {
    case invalidRequest
    case notesUnavailable
    case notesReadFailed
    case documentRevisionMismatch
    case resourceMetadataMismatch
    case resourceUnavailable
    case resourceAccessDenied
    case resourceDigestMismatch
    case resourceSizeMismatch
    case duplicateResource
    case duplicateDestination
    case receiptConflict
    case receiptUnavailable
    case inputManifestIncomplete
    case taskWorkspaceUnavailable
    case ownerAdmissionRefused
    case cancelled
    case stagingFailed
}

public struct C08NotesTaskLaunchError: Error, Sendable, Equatable, LocalizedError {
    public let code: C08NotesTaskLaunchErrorCode
    /// Closed bounded diagnostic (codes/numbers/digests/task-relative paths).
    /// Never Notes content, a credential or an absolute user path.
    public let detail: String?

    public init(_ code: C08NotesTaskLaunchErrorCode, _ detail: String? = nil) {
        self.code = code
        self.detail = detail.map { String($0.prefix(160)) }
    }

    public var errorDescription: String? {
        "notesTaskLaunch.\(code.rawValue)" + (detail.map { ": \($0)" } ?? "")
    }

    /// Map to the frozen run-domain vocabulary. No new wire code/reason is
    /// introduced: the launch returns an existing typed refusal and the App
    /// maps it through its ordinary run failure path.
    public var runError: RunDomainError {
        switch code {
        case .notesUnavailable, .ownerAdmissionRefused:
            return RunDomainError(.sessionFenced, .generationRetired)
        case .cancelled:
            return RunDomainError(.sessionFenced, .deletingGuarded)
        case .documentRevisionMismatch, .resourceDigestMismatch,
             .resourceMetadataMismatch, .resourceSizeMismatch:
            return RunDomainError(.staleRevision, .revisionMismatch)
        case .resourceAccessDenied, .resourceUnavailable, .duplicateResource:
            return RunDomainError(.invalidState, .payloadInvalid)
        case .inputManifestIncomplete, .invalidRequest,
             .receiptConflict, .receiptUnavailable,
             .duplicateDestination, .taskWorkspaceUnavailable:
            return RunDomainError(.invalidState, .payloadInvalid)
        case .notesReadFailed:
            return RunDomainError(.persistenceUnavailable, .storeReadFailed)
        case .stagingFailed:
            return RunDomainError(.persistenceUnavailable, .storeWriteFailed)
        }
    }
}

// MARK: - Bounded receipt store

public protocol C08NotesTaskLaunchReceiptStoring: Sendable {
    func prepare(_ selection: C08NotesTaskLaunchSelection,
                 receiptRoot: URL) throws -> C08NotesTaskLaunchPreparation
    func pending(forConversation conversationID: UUID,
                 receiptRoot: URL, now: Date) throws -> C08NotesTaskLaunchSelection?
    func complete(receiptID: UUID, receiptRoot: URL) throws
    @discardableResult
    func discard(receiptID: UUID, conversationID: UUID,
                 receiptRoot: URL) throws -> Bool
}

/// The production store: one small JSON file per receipt under the accepted
/// generation's app-private artifact root. Immutable by receipt identity,
/// bounded by count/size/expiry, never inside a user or guest workspace.
public final class C08NotesTaskLaunchFileReceiptStore:
    C08NotesTaskLaunchReceiptStoring, @unchecked Sendable {
    public static let maximumReceipts = 64
    public static let maximumReceiptBytes = 65_536
    public static let receiptLifetimeSeconds: TimeInterval = 7 * 24 * 60 * 60

    private static let lock = NSLock()

    public init() {}

    public func prepare(
        _ selection: C08NotesTaskLaunchSelection,
        receiptRoot: URL
    ) throws -> C08NotesTaskLaunchPreparation {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try C08NotesTaskLaunch.validate(selection)
        try FileManager.default.createDirectory(
            at: receiptRoot, withIntermediateDirectories: true)
        Self.sweepExpired(in: receiptRoot, now: Date())
        let entries = try Self.receiptFiles(in: receiptRoot)
        if entries.count >= Self.maximumReceipts,
           !entries.contains(where: { $0.lastPathComponent ==
                "\(selection.receiptID.uuidString).json" }) {
            throw C08NotesTaskLaunchError(.receiptUnavailable, "receiptLimit")
        }
        let destinations = try Self.destinations(for: selection)
        let preparation = C08NotesTaskLaunchPreparation(
            receiptID: selection.receiptID,
            destinations: destinations,
            totalBytes: selection.resources.reduce(0) { $0 + $1.byteCount })
        let encoder = Self.encoder()
        let data: Data
        do { data = try encoder.encode(selection) }
        catch { throw C08NotesTaskLaunchError(.invalidRequest, "receiptEncode") }
        guard data.count <= Self.maximumReceiptBytes else {
            throw C08NotesTaskLaunchError(.invalidRequest, "receiptTooLarge")
        }
        let final = Self.fileURL(selection.receiptID, in: receiptRoot)
        if let existing = Self.readBounded(final) {
            if existing == data { return preparation }
            throw C08NotesTaskLaunchError(.receiptConflict, "immutableReceipt")
        }
        let temporary = receiptRoot.appendingPathComponent(
            ".\(selection.receiptID.uuidString).\(UUID().uuidString).tmp",
            isDirectory: false)
        do {
            try data.write(to: temporary, options: [.atomic])
            try FileManager.default.moveItem(at: temporary, to: final)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw C08NotesTaskLaunchError(.stagingFailed, "receiptWrite")
        }
        // One pending selection per REAL task conversation: a newer explicit
        // selection replaces stale pending state, never leaks into another
        // task and never stages two selections into one first send.
        for entry in try Self.receiptFiles(in: receiptRoot)
        where entry.lastPathComponent != final.lastPathComponent {
            guard let other = Self.decode(entry),
                  other.conversationID == selection.conversationID else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
        return preparation
    }

    public func pending(
        forConversation conversationID: UUID,
        receiptRoot: URL, now: Date
    ) throws -> C08NotesTaskLaunchSelection? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.sweepExpired(in: receiptRoot, now: now)
        let nowMillis = Int64(now.timeIntervalSince1970 * 1_000)
        var candidates: [C08NotesTaskLaunchSelection] = []
        for entry in try Self.receiptFiles(in: receiptRoot) {
            guard let selection = Self.decode(entry),
                  selection.conversationID == conversationID,
                  selection.expiresAtMillis > nowMillis else { continue }
            candidates.append(selection)
        }
        candidates.sort { $0.createdAtMillis > $1.createdAtMillis }
        return candidates.first
    }

    public func complete(receiptID: UUID, receiptRoot: URL) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let url = Self.fileURL(receiptID, in: receiptRoot)
        if FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) }
            catch { throw C08NotesTaskLaunchError(.stagingFailed, "receiptComplete") }
        }
    }

    @discardableResult
    public func discard(
        receiptID: UUID, conversationID: UUID, receiptRoot: URL
    ) throws -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let url = Self.fileURL(receiptID, in: receiptRoot)
        guard let data = Self.readBounded(url),
              let selection = try? Self.decoder().decode(
                C08NotesTaskLaunchSelection.self, from: data),
              selection.conversationID == conversationID else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            throw C08NotesTaskLaunchError(.stagingFailed, "receiptDiscard")
        }
    }

    // MARK: file helpers

    static func fileURL(_ receiptID: UUID, in root: URL) -> URL {
        root.appendingPathComponent("\(receiptID.uuidString).json",
                                    isDirectory: false)
    }

    private static func receiptFiles(in root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else {
            throw C08NotesTaskLaunchError(.receiptUnavailable, "receiptList")
        }
        var entries: [URL] = []
        var visited = 0
        for case let entry as URL in enumerator {
            visited += 1
            guard visited <= maximumReceipts * 4 else {
                throw C08NotesTaskLaunchError(.receiptUnavailable, "receiptListLimit")
            }
            if entry.pathExtension.lowercased() == "json" {
                entries.append(entry)
                guard entries.count <= maximumReceipts else {
                    throw C08NotesTaskLaunchError(.receiptUnavailable, "receiptLimit")
                }
            }
        }
        return entries
    }

    private static func sweepExpired(in root: URL, now: Date) {
        let nowMillis = Int64(now.timeIntervalSince1970 * 1_000)
        guard let entries = try? receiptFiles(in: root) else { return }
        for entry in entries {
            guard let selection = decode(entry),
                  selection.expiresAtMillis <= nowMillis else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private static func readBounded(_ url: URL) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= maximumReceiptBytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumReceiptBytes + 1),
              data.count <= maximumReceiptBytes else { return nil }
        return data
    }

    private static func decode(_ url: URL) -> C08NotesTaskLaunchSelection? {
        guard let data = readBounded(url),
              let selection = try? decoder().decode(C08NotesTaskLaunchSelection.self, from: data),
              selection.receiptID.uuidString.lowercased() == url.deletingPathExtension().lastPathComponent.lowercased(),
              (try? C08NotesTaskLaunch.validate(selection)) != nil else { return nil }
        return selection
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder { JSONDecoder() }

    static func destinations(
        for selection: C08NotesTaskLaunchSelection
    ) throws -> [C08NotesTaskLaunchDestination] {
        var seenPaths: Set<String> = []
        var result: [C08NotesTaskLaunchDestination] = []
        for resource in selection.resources {
            let path = NotesResourceStagingService.destinationRelativePath(
                documentID: selection.documentID,
                fileName: resource.fileName,
                resourceID: resource.resourceID)
            guard seenPaths.insert(path).inserted else {
                throw C08NotesTaskLaunchError(.duplicateDestination,
                                              "resourceNameCollision")
            }
            result.append(C08NotesTaskLaunchDestination(
                resourceID: resource.resourceID, relativePath: path))
        }
        return result
    }
}

// MARK: - Manifest

public enum C08NotesTaskLaunchManifest {
    /// The exact task-input block. The destination paths are the REAL
    /// service-owned task-relative paths, never model- or caller-chosen. The
    /// block is part of the ordinary user message so the model receives the
    /// same identity the staging transaction verifies.
    public static func text(
        receiptID: UUID,
        destinations: [C08NotesTaskLaunchDestination]
    ) -> String {
        var lines = ["Attached from Notes (selection \(receiptID.uuidString)):"]
        for destination in destinations {
            lines.append("- \(destination.relativePath)")
        }
        return lines.joined(separator: "\n")
    }

    public static func combined(
        prompt: String,
        receiptID: UUID,
        destinations: [C08NotesTaskLaunchDestination]
    ) -> String {
        let body = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let manifest = text(receiptID: receiptID, destinations: destinations)
        return body.isEmpty ? manifest : body + "\n\n" + manifest
    }

    public enum Mention: Sendable, Equatable {
        case absent
        case partial
        case complete
    }

    public static func mention(
        in goal: String,
        receiptID: UUID,
        destinations: [C08NotesTaskLaunchDestination]
    ) -> Mention {
        guard goal.lowercased().contains(receiptID.uuidString.lowercased()) else {
            return .absent
        }
        for destination in destinations
        where !goal.contains(destination.relativePath) {
            return .partial
        }
        return .complete
    }
}

// MARK: - Launch cancellation bridge

/// Bridges the run actor's cancellation/deletion fence to the synchronous
/// staging checks. The owning launch constructs one per attempt; the watcher
/// is cancelled as soon as staging returns.
public struct C08NotesTaskLaunchCancellation: Sendable {
    public let probe: @Sendable () async -> Bool

    public init(probe: @escaping @Sendable () async -> Bool) {
        self.probe = probe
    }

    public static let never: C08NotesTaskLaunchCancellation =
        C08NotesTaskLaunchCancellation { false }
}

// MARK: - Notes-domain bridge

public enum C08NotesTaskLaunchActions {
    public static let prepare = "taskLaunch.prepare"
    public static let discard = "taskLaunch.discard"
    public static let status = "taskLaunch.status"

    public static let all: Set<String> = [prepare, discard, status]

    public static func handles(_ action: String) -> Bool {
        all.contains(action)
    }
}

public enum C08NotesTaskLaunch {
    public static let maximumResources = 16
    public static let maximumTotalBytes: Int64 = 536_870_912
    public static let maximumResourceBytes: Int64 = 536_870_912
    public static let maximumFileNameBytes = 512
    public static let maximumMediaTypeBytes = 256

    // MARK: Notes-domain command surface

    /// Called from the ORIGINAL `NotesDomainService.handle` Main patch. It
    /// uses the SAME Notes authority reader as the staging service, never a
    /// second store.
    static func handle(
        epoch: UInt64,
        action: String,
        payload: NotesJSONValue?
    ) async throws -> Data {
        switch action {
        case C08NotesTaskLaunchActions.prepare:
            let selection = try parseSelection(payload, epoch: epoch)
            guard let root = AndroidRuntimeBootstrap.notesBinding(
                epoch: epoch, ownerToken: nil) else {
                throw NotesDomainError.staleGeneration
            }
            let preparation = try await prepare(
                selection: selection,
                reading: NotesDomainResourceReader(),
                receiptRoot: receiptRoot(for: root.artifactStoreURL))
            return try response(preparation)
        case C08NotesTaskLaunchActions.discard:
            let object = try Self.object(payload)
            let receiptID = try Self.uuid(object, "receiptID")
            let conversationID = try Self.uuid(object, "conversationID")
            guard let root = AndroidRuntimeBootstrap.notesBinding(
                epoch: epoch, ownerToken: nil) else {
                throw NotesDomainError.staleGeneration
            }
            let removed = try C08NotesTaskLaunchFileReceiptStore().discard(
                receiptID: receiptID, conversationID: conversationID,
                receiptRoot: receiptRoot(for: root.artifactStoreURL))
            return try Self.response(["ok": true, "discarded": removed])
        case C08NotesTaskLaunchActions.status:
            let object = try Self.object(payload)
            let conversationID = try Self.uuid(object, "conversationID")
            guard let root = AndroidRuntimeBootstrap.notesBinding(
                epoch: epoch, ownerToken: nil) else {
                throw NotesDomainError.staleGeneration
            }
            let pending = try C08NotesTaskLaunchFileReceiptStore().pending(
                forConversation: conversationID,
                receiptRoot: receiptRoot(for: root.artifactStoreURL),
                now: Date())
            return try Self.response([
                "ok": true,
                "pending": pending != nil,
                "receiptID": pending?.receiptID.uuidString ?? NSNull(),
            ])
        default:
            throw NotesDomainError.unsupportedAction(action)
        }
    }

    // MARK: Prepare

    /// Revalidates the explicit selection against the REAL Notes authority
    /// and writes the immutable receipt. No run/workspace/model call.
    public static func prepare(
        selection: C08NotesTaskLaunchSelection,
        reading: any NotesResourceReading,
        receiptRoot: URL,
        store: any C08NotesTaskLaunchReceiptStoring =
            C08NotesTaskLaunchFileReceiptStore()
    ) async throws -> C08NotesTaskLaunchPreparation {
        try validate(selection)
        let revision: Int
        do {
            revision = try await reading.documentRevision(
                notesEpoch: selection.notesEpoch,
                documentID: selection.documentID)
        } catch let error as NotesResourceStagingError {
            throw mappedStaging(error)
        } catch let error as NoteError {
            throw mappedNote(error)
        } catch {
            throw C08NotesTaskLaunchError(.notesReadFailed, "revision")
        }
        guard revision == selection.documentRevision else {
            throw C08NotesTaskLaunchError(
                .documentRevisionMismatch,
                "expected=\(selection.documentRevision) actual=\(revision)")
        }
        for resource in selection.resources {
            let metadata: NotesResourceStagingMetadata
            do {
                metadata = try await reading.resourceMetadata(
                    notesEpoch: selection.notesEpoch,
                    resourceID: resource.resourceID)
            } catch let error as NotesResourceStagingError {
                throw mappedStaging(error)
            } catch let error as NoteError {
                throw mappedNote(error)
            } catch {
                throw C08NotesTaskLaunchError(.notesReadFailed, "metadata")
            }
            guard metadata.resourceID == resource.resourceID,
                  metadata.sha256.lowercased() == resource.sha256.lowercased(),
                  metadata.byteCount == resource.byteCount,
                  metadata.fileName == resource.fileName,
                  metadata.mediaType == resource.mediaType else {
                throw C08NotesTaskLaunchError(
                    .resourceMetadataMismatch, resource.resourceID.uuidString)
            }
            // ONE byte through the ORIGINAL resource-read authority proves
            // the document reference + the exact conversation grant without
            // reading the whole resource twice.
            do {
                let probe = try await reading.readResource(
                    notesEpoch: selection.notesEpoch,
                    resourceID: resource.resourceID,
                    conversationID: selection.conversationID,
                    documentID: selection.documentID,
                    offset: 0,
                    maxBytes: 1)
                guard probe.totalBytes == resource.byteCount else {
                    throw C08NotesTaskLaunchError(
                        .resourceSizeMismatch, "read=\(probe.totalBytes)")
                }
            } catch let error as NotesResourceStagingError {
                throw mappedStaging(error)
            } catch let error as NoteError {
                throw mappedNote(error)
            } catch let error as C08NotesTaskLaunchError {
                throw error
            } catch {
                throw C08NotesTaskLaunchError(.notesReadFailed, "resourceGrant")
            }
        }
        return try store.prepare(selection, receiptRoot: receiptRoot)
    }

    // MARK: Commit

    /// Called inside the ORIGINAL run launch after the durable prepare created
    /// the REAL run/workspace and BEFORE the run service/model starts.
    ///
    /// The caller passes the launch's exact `.conversation` lease. This
    /// function never attaches a second/parallel lifetime registry: the lease
    /// is already in the run ownership map, so conversation deletion sees it
    /// and waits for the real staging transaction to drain.
    ///
    /// Returns nil when the task has no pending Notes selection, or when the
    /// exact manifest was removed from the user's message (the receipt is
    /// discarded and the ordinary task proceeds). A partially edited manifest
    /// refuses the launch before any filesystem effect.
    public static func stagePendingCommittedLaunch(
        conversationID: UUID,
        runID: UUID,
        goal: String,
        ownerLease: RuntimeOwnedWorkToken,
        cancellation: C08NotesTaskLaunchCancellation = .never,
        serviceFactory: @escaping @Sendable () -> NotesResourceStagingService = {
            NotesResourceStagingService.live()
        },
        store: any C08NotesTaskLaunchReceiptStoring =
            C08NotesTaskLaunchFileReceiptStore()
    ) async throws -> C08NotesTaskLaunchCommittedResult? {
        let correctOwner = (ownerLease.kind == .conversation &&
            ownerLease.ownerID == conversationID.uuidString) ||
            (ownerLease.kind == .run && ownerLease.ownerID == runID.uuidString)
        guard correctOwner, RuntimeOwnedWorkRegistry.shared.isAttached(ownerLease) else {
            throw C08NotesTaskLaunchError(.ownerAdmissionRefused, "leaseIdentity")
        }
        guard let root = AndroidRuntimeBootstrap.notesBinding(
            epoch: ownerLease.epoch, ownerToken: nil) else {
            throw C08NotesTaskLaunchError(.notesUnavailable)
        }
        let rootURL = receiptRoot(for: root.artifactStoreURL)
        guard let selection = try store.pending(
            forConversation: conversationID,
            receiptRoot: rootURL, now: Date()) else { return nil }
        guard selection.conversationID == conversationID,
              selection.notesEpoch == ownerLease.epoch else {
            throw C08NotesTaskLaunchError(.receiptUnavailable, "ownerMismatch")
        }
        let destinations = try C08NotesTaskLaunchFileReceiptStore
            .destinations(for: selection)
        switch C08NotesTaskLaunchManifest.mention(
            in: goal, receiptID: selection.receiptID,
            destinations: destinations) {
        case .absent:
            // The user removed the exact manifest from the message. The task
            // is an ordinary task; the selection is consumed, never staged
            // later behind the user's back.
            try store.discard(receiptID: selection.receiptID,
                              conversationID: conversationID,
                              receiptRoot: rootURL)
            return nil
        case .partial:
            throw C08NotesTaskLaunchError(.inputManifestIncomplete)
        case .complete:
            break
        }

        let token = CancellationToken()
        let probe = cancellation.probe
        let watcher = Task {
            while !Task.isCancelled {
                if await probe() {
                    token.cancel()
                    return
                }
                try? await Task.sleep(nanoseconds: 75_000_000)
            }
        }
        defer { watcher.cancel() }
        if await probe() {
            token.cancel()
            throw C08NotesTaskLaunchError(.cancelled)
        }

        let service = serviceFactory()
        var staged: [C08NotesTaskLaunchDestination] = []
        for resource in selection.resources {
            if token.isCancelled { throw C08NotesTaskLaunchError(.cancelled) }
            let expected = destinations.first {
                $0.resourceID == resource.resourceID
            }?.relativePath
            guard let expected else {
                throw C08NotesTaskLaunchError(.duplicateResource,
                                              resource.resourceID.uuidString)
            }
            let request = NotesResourceStagingRequest(
                notesEpoch: selection.notesEpoch,
                runID: runID,
                conversationID: selection.conversationID,
                documentID: selection.documentID,
                resourceID: resource.resourceID,
                expectedDocumentRevision: selection.documentRevision,
                expectedResourceSHA256: resource.sha256)
            let receipt: NotesResourceStagingReceipt
            do {
                receipt = try await service.stage(
                    request, cancellation: token,
                    isCancelled: { token.isCancelled },
                    ownerLease: ownerLease)
            } catch let error as NotesResourceStagingError {
                throw mappedStaging(error)
            } catch {
                throw C08NotesTaskLaunchError(.stagingFailed)
            }
            guard receipt.destinationRelativePath == expected,
                  receipt.resourceSHA256.lowercased()
                    == resource.sha256.lowercased(),
                  receipt.byteCount == resource.byteCount else {
                throw C08NotesTaskLaunchError(
                    .stagingFailed, "receiptMismatch")
            }
            staged.append(C08NotesTaskLaunchDestination(
                resourceID: resource.resourceID,
                relativePath: receipt.destinationRelativePath))
        }
        return C08NotesTaskLaunchCommittedResult(
            receiptID: selection.receiptID, destinations: staged)
    }

    /// Removes the receipt only after the run service is actually live. A
    /// failed/abandoned launch keeps it for an honest retry (the destination
    /// import is no-overwrite/idempotent) until expiry.
    @discardableResult
    public static func completeCommittedLaunch(
        receiptID: UUID,
        notesEpoch: UInt64,
        store: any C08NotesTaskLaunchReceiptStoring =
            C08NotesTaskLaunchFileReceiptStore()
    ) -> Bool {
        guard let root = AndroidRuntimeBootstrap.notesBinding(
            epoch: notesEpoch, ownerToken: nil) else { return false }
        do {
            try store.complete(
                receiptID: receiptID,
                receiptRoot: receiptRoot(for: root.artifactStoreURL))
            return true
        } catch {
            return false
        }
    }

    // MARK: Validation / helpers

    fileprivate static func validate(_ selection: C08NotesTaskLaunchSelection) throws {
        guard selection.notesEpoch > 0,
              selection.documentRevision >= 0,
              !selection.resources.isEmpty,
              selection.resources.count <= maximumResources,
              selection.expiresAtMillis > selection.createdAtMillis else {
            throw C08NotesTaskLaunchError(.invalidRequest, "selectionShape")
        }
        var ids: Set<UUID> = []
        var total: Int64 = 0
        for resource in selection.resources {
            guard ids.insert(resource.resourceID).inserted else {
                throw C08NotesTaskLaunchError(.duplicateResource,
                                              resource.resourceID.uuidString)
            }
            guard isSHA256(resource.sha256),
                  resource.byteCount > 0,
                  resource.byteCount <= maximumResourceBytes,
                  !resource.fileName.isEmpty,
                  resource.fileName.utf8.count <= maximumFileNameBytes,
                  resource.fileName != ".",
                  resource.fileName != "..",
                  !resource.fileName.contains("\0"),
                  !resource.mediaType.isEmpty,
                  resource.mediaType.utf8.count <= maximumMediaTypeBytes else {
                throw C08NotesTaskLaunchError(.invalidRequest, "resourceShape")
            }
            total += resource.byteCount
            guard total <= maximumTotalBytes else {
                throw C08NotesTaskLaunchError(.invalidRequest, "totalBytes")
            }
        }
        _ = try C08NotesTaskLaunchFileReceiptStore.destinations(for: selection)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func mappedStaging(
        _ error: NotesResourceStagingError
    ) -> C08NotesTaskLaunchError {
        switch error.code {
        case .ownerAdmissionRefused:
            return C08NotesTaskLaunchError(.ownerAdmissionRefused, error.detail)
        case .cancelled:
            return C08NotesTaskLaunchError(.cancelled)
        case .notesUnavailable:
            return C08NotesTaskLaunchError(.notesUnavailable)
        case .documentRevisionMismatch:
            return C08NotesTaskLaunchError(.documentRevisionMismatch, error.detail)
        case .resourceAccessDenied:
            return C08NotesTaskLaunchError(.resourceAccessDenied, error.detail)
        case .resourceDigestMismatch:
            return C08NotesTaskLaunchError(.resourceDigestMismatch, error.detail)
        case .resourceSizeMismatch, .resourceTooLarge, .resourceEmpty:
            return C08NotesTaskLaunchError(.resourceSizeMismatch, error.detail)
        case .taskWorkspaceUnavailable:
            return C08NotesTaskLaunchError(.taskWorkspaceUnavailable, error.detail)
        case .resourceUnavailable, .documentNotFound:
            return C08NotesTaskLaunchError(.resourceUnavailable, error.detail)
        case .destinationConflict:
            return C08NotesTaskLaunchError(.receiptConflict, error.detail)
        case .invalidRequest:
            return C08NotesTaskLaunchError(.invalidRequest, error.detail)
        case .stagingFailed, .notesReadFailed:
            return C08NotesTaskLaunchError(.stagingFailed, error.detail)
        }
    }

    private static func mappedNote(_ error: NoteError) -> C08NotesTaskLaunchError {
        switch error {
        case .invalidOperation(let reason) where reason == "resourceAccessDenied":
            return C08NotesTaskLaunchError(.resourceAccessDenied)
        case .resourceUnavailable:
            return C08NotesTaskLaunchError(.resourceUnavailable)
        case .notFound:
            return C08NotesTaskLaunchError(.resourceUnavailable)
        case .conflict:
            return C08NotesTaskLaunchError(.documentRevisionMismatch)
        case .invalidOperation:
            return C08NotesTaskLaunchError(.stagingFailed)
        case .storageUnavailable, .invalidDocument:
            return C08NotesTaskLaunchError(.notesReadFailed)
        }
    }

    /// The one App-private receipt root for a generation. It is outside every
    /// task/guest workspace and is never a model/caller-supplied path.
    public static func receiptRoot(for artifactStoreURL: URL) -> URL {
        artifactStoreURL
            .appendingPathComponent("NotesImports", isDirectory: true)
            .appendingPathComponent("TaskLaunch", isDirectory: true)
    }

    // MARK: JSON plumbing

    private static func parseSelection(
        _ payload: NotesJSONValue?, epoch: UInt64
    ) throws -> C08NotesTaskLaunchSelection {
        let object = try Self.object(payload)
        let notesEpoch = try Self.uint64(object, "notesEpoch")
        guard notesEpoch == epoch else {
            throw C08NotesTaskLaunchError(.invalidRequest, "epochMismatch")
        }
        let rawResources = try Self.array(object, "resources")
        var resources: [C08NotesTaskLaunchResource] = []
        for value in rawResources {
            guard case .object(let resource) = value else {
                throw C08NotesTaskLaunchError(.invalidRequest, "resourceShape")
            }
            resources.append(C08NotesTaskLaunchResource(
                resourceID: try Self.uuid(resource, "resourceID"),
                sha256: try Self.string(resource, "sha256"),
                byteCount: try Self.int64(resource, "byteCount"),
                fileName: try Self.string(resource, "fileName"),
                mediaType: try Self.string(resource, "mediaType")))
        }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let lifetime = Int64(C08NotesTaskLaunchFileReceiptStore
            .receiptLifetimeSeconds * 1_000)
        return C08NotesTaskLaunchSelection(
            receiptID: try Self.uuid(object, "receiptID"),
            notesEpoch: notesEpoch,
            conversationID: try Self.uuid(object, "conversationID"),
            documentID: try Self.uuid(object, "documentID"),
            documentRevision: try Self.int(object, "documentRevision"),
            resources: resources,
            createdAtMillis: now,
            expiresAtMillis: now + lifetime)
    }

    private static func object(
        _ payload: NotesJSONValue?
    ) throws -> [String: NotesJSONValue] {
        guard let payload, case .object(let object) = payload else {
            throw C08NotesTaskLaunchError(.invalidRequest, "payload")
        }
        return object
    }

    private static func array(
        _ object: [String: NotesJSONValue], _ key: String
    ) throws -> [NotesJSONValue] {
        guard let value = object[key], case .array(let array) = value else {
            throw C08NotesTaskLaunchError(.invalidRequest, key)
        }
        return array
    }

    private static func string(
        _ object: [String: NotesJSONValue], _ key: String
    ) throws -> String {
        guard let value = object[key]?.stringValue, !value.isEmpty else {
            throw C08NotesTaskLaunchError(.invalidRequest, key)
        }
        return value
    }

    private static func uuid(
        _ object: [String: NotesJSONValue], _ key: String
    ) throws -> UUID {
        guard let value = object[key]?.stringValue,
              let uuid = UUID(uuidString: value) else {
            throw C08NotesTaskLaunchError(.invalidRequest, key)
        }
        return uuid
    }

    private static func int(
        _ object: [String: NotesJSONValue], _ key: String
    ) throws -> Int {
        guard let value = object[key]?.intValue else {
            throw C08NotesTaskLaunchError(.invalidRequest, key)
        }
        return value
    }

    private static func int64(
        _ object: [String: NotesJSONValue], _ key: String
    ) throws -> Int64 {
        guard let value = object[key]?.intValue else {
            throw C08NotesTaskLaunchError(.invalidRequest, key)
        }
        return Int64(value)
    }

    private static func uint64(
        _ object: [String: NotesJSONValue], _ key: String
    ) throws -> UInt64 {
        let value = try int64(object, key)
        guard value > 0 else {
            throw C08NotesTaskLaunchError(.invalidRequest, key)
        }
        return UInt64(value)
    }

    private static func response(
        _ preparation: C08NotesTaskLaunchPreparation
    ) throws -> Data {
        let destinations: [[String: Any]] = preparation.destinations.map {
            ["resourceID": $0.resourceID.uuidString,
             "relativePath": $0.relativePath]
        }
        return try response([
            "ok": true,
            "receiptID": preparation.receiptID.uuidString,
            "destinations": destinations,
            "totalBytes": preparation.totalBytes,
        ])
    }

    private static func response(_ object: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw C08NotesTaskLaunchError(.invalidRequest, "responseEncode")
        }
    }
}
