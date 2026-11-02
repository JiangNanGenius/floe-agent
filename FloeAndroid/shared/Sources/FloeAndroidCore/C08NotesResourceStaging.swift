// SPDX-License-Identifier: MPL-2.0
//
// C08 B0 — Notes resource -> task workspace input staging (App side).
//
// USER-OBSERVABLE PATH THIS CLOSES
// A Notes document can own an immutable content-addressed resource (PDF,
// image, Office/engineering attachment). Task-Linux PDF/OCR/generic document
// processing needs those exact bytes inside the AUTHORIZED TASK workspace so
// the separately owned C01 guest exchange can expose them to `exec.shell`.
// Before this file there was no Notes -> task-workspace producer: workspace
// import was one-directional (workspace -> Notes), so the only "staging" was a
// user file picker or a chat attachment.
//
// AUTHORITY / IDENTITY
//   * Notes bytes are read through the ORIGINAL Notes authority only:
//     `resource.read` with `conversationID`+`documentID` runs the store's
//     `authorizeResourceRead` rule (an explicit Notes assistant grant for the
//     document is required; another note's resource is denied). The reader is
//     a protocol so tests can drive the SAME rule through a real NotesStore;
//     production uses `NotesDomainService`, never a second SQLite/store.
//   * The task workspace comes from the ORIGINAL
//     `LinuxWorkspaceAuthority.trustedWorkspaceRoot(runID:conversationID:)`,
//     which resolves the persisted run + conversation-owned workspace row and
//     the accepted native generation. A missing/unbound/temporary task is a
//     typed refusal; there is no first-project, App-root or temp-dir fallback
//     and no caller-supplied root.
//   * The destination is NOT model- or caller-chosen. It is
//     `NotesImports/<documentID>/<sanitized resource fileName>` inside that
//     task workspace. The stage itself is service-owned and lives under the
//     accepted generation's app-private artifact store, not under a user path.
//   * Document revision and resource digest are checked before any task write
//     and the document revision is re-checked immediately before commit. A
//     changed document, a digest/size mismatch, a revoked Notes grant, a
//     retired generation or a changed task root all refuse with typed codes.
//     The Notes original is read-only: no Notes mutation, revision bump,
//     deletion or re-import is performed here.
//
// COMMIT
// The existing `WorkspaceFileService.importUserFile` is reused unchanged:
// same-directory staging, no-overwrite atomic move, source size/mtime stability,
// SHA-256 verification and the existing workspace mutation lock. The design
// freeze mutation gate is applied just like ordinary agent writes. The service
// never overwrites an existing destination; an identical, already-committed
// destination is an idempotent receipt and a different one is a conflict.
// Cancellation before commit leaves the destination absent and removes the
// service-owned stage; cancellation during import is the service's existing
// CAS failure path (nothing is silently truncated).
//
// C01 BOUNDARY (separately owned)
// This file does NOT claim guest visibility or a "synced" qualification. It
// lands bytes in the Core task workspace only; C01 remains responsible for the
// real task-workspace <-> Linux guest exchange (`/workspace`), its baseline and
// writeback. The typed requirements Main needs from C01 are recorded in the
// package handoff, not faked here as a flag.

import Foundation
import Crypto
import FloeCore
import FloeNotes

// MARK: - Typed seam

/// The exact resource metadata an agent/file producer may rely on.
public struct NotesResourceStagingMetadata: Sendable, Equatable {
    public var resourceID: UUID
    /// Content-addressed CAS digest recorded by the Notes store.
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

/// One bounded read window of a Notes resource.
public struct NotesResourceStagingChunk: Sendable, Equatable {
    public var data: Data
    public var nextOffset: Int64
    public var totalBytes: Int64
    public var eof: Bool

    public init(data: Data, nextOffset: Int64, totalBytes: Int64, eof: Bool) {
        self.data = data
        self.nextOffset = nextOffset
        self.totalBytes = totalBytes
        self.eof = eof
    }
}

/// Read-only Notes resource access. Production uses `NotesDomainService`;
/// tests use a real `NotesStore` so the SAME `authorizeResourceRead` rule is
/// exercised. Implementations must never mutate Notes state.
public protocol NotesResourceReading: Sendable {
    func documentRevision(notesEpoch: UInt64, documentID: UUID) async throws -> Int
    func resourceMetadata(notesEpoch: UInt64, resourceID: UUID) async throws -> NotesResourceStagingMetadata
    func readResource(
        notesEpoch: UInt64,
        resourceID: UUID,
        conversationID: UUID,
        documentID: UUID,
        offset: Int64,
        maxBytes: Int
    ) async throws -> NotesResourceStagingChunk
}

// MARK: - Request / receipt

public struct NotesResourceStagingRequest: Sendable, Equatable {
    /// Accepted Notes generation the user is looking at.
    public var notesEpoch: UInt64
    /// A REAL existing task run (created by the original task-launch path).
    public var runID: UUID
    /// The conversation that owns that run and the Notes grant.
    public var conversationID: UUID
    public var documentID: UUID
    public var resourceID: UUID
    /// Revision the user selected. A changed document is a conflict.
    public var expectedDocumentRevision: Int
    /// Optional exact CAS digest from the selection; when present it must
    /// match the Notes record and the staged bytes.
    public var expectedResourceSHA256: String?

    public init(
        notesEpoch: UInt64,
        runID: UUID,
        conversationID: UUID,
        documentID: UUID,
        resourceID: UUID,
        expectedDocumentRevision: Int,
        expectedResourceSHA256: String? = nil
    ) {
        self.notesEpoch = notesEpoch
        self.runID = runID
        self.conversationID = conversationID
        self.documentID = documentID
        self.resourceID = resourceID
        self.expectedDocumentRevision = expectedDocumentRevision
        self.expectedResourceSHA256 = expectedResourceSHA256
    }
}

/// Proof of one real staging outcome. Contains the resource identity/digest,
/// the exact task owner and the exact task-relative destination. It carries no
/// absolute workspace path and no credential.
public struct NotesResourceStagingReceipt: Sendable, Equatable, Codable {
    public var documentID: UUID
    public var documentRevision: Int
    public var resourceID: UUID
    public var resourceSHA256: String
    public var byteCount: Int64
    /// Original Notes-supplied display name (reference only).
    public var resourceFileName: String
    /// Sanitized exact name committed under `NotesImports/<documentID>/`.
    public var fileName: String
    public var mediaType: String
    public var ownerConversationID: UUID
    public var ownerRunID: UUID
    public var notesEpoch: UInt64
    public var runtimeRootFingerprint: String
    public var workspaceRootFingerprint: String
    public var destinationRelativePath: String
    public var stagedSHA256: String
    public var stagedAt: Date
    /// True only when the exact same bytes were already committed at the
    /// destination and no second write occurred.
    public var idempotent: Bool

    public init(
        documentID: UUID, documentRevision: Int, resourceID: UUID,
        resourceSHA256: String, byteCount: Int64, resourceFileName: String,
        fileName: String, mediaType: String, ownerConversationID: UUID,
        ownerRunID: UUID, notesEpoch: UInt64, runtimeRootFingerprint: String,
        workspaceRootFingerprint: String, destinationRelativePath: String,
        stagedSHA256: String, stagedAt: Date, idempotent: Bool
    ) {
        self.documentID = documentID
        self.documentRevision = documentRevision
        self.resourceID = resourceID
        self.resourceSHA256 = resourceSHA256
        self.byteCount = byteCount
        self.resourceFileName = resourceFileName
        self.fileName = fileName
        self.mediaType = mediaType
        self.ownerConversationID = ownerConversationID
        self.ownerRunID = ownerRunID
        self.notesEpoch = notesEpoch
        self.runtimeRootFingerprint = runtimeRootFingerprint
        self.workspaceRootFingerprint = workspaceRootFingerprint
        self.destinationRelativePath = destinationRelativePath
        self.stagedSHA256 = stagedSHA256
        self.stagedAt = stagedAt
        self.idempotent = idempotent
    }
}

// MARK: - Errors

public enum NotesResourceStagingErrorCode: String, Sendable, Codable, CaseIterable {
    case invalidRequest
    case notesUnavailable
    case notesReadFailed
    case documentNotFound
    case documentRevisionMismatch
    case resourceUnavailable
    case resourceAccessDenied
    case resourceDigestMismatch
    case resourceSizeMismatch
    case resourceEmpty
    case resourceTooLarge
    case taskWorkspaceUnavailable
    case destinationConflict
    case stagingFailed
    /// The accepted epoch/owner fencing refused admission before any
    /// filesystem effect. This is a REAL production refusal, never a
    /// best-effort warning: staging may not continue without the lease.
    case ownerAdmissionRefused
    case cancelled
}

public struct NotesResourceStagingError: Error, Sendable, Equatable, LocalizedError {
    public let code: NotesResourceStagingErrorCode
    /// Closed, bounded diagnostic (codes/numbers/digests or a task-relative
    /// path). Never Notes content, a credential or an absolute user path.
    public let detail: String?

    public init(_ code: NotesResourceStagingErrorCode, _ detail: String? = nil) {
        self.code = code
        self.detail = detail.map { String($0.prefix(160)) }
    }

    public var errorDescription: String? {
        "notesStaging.\(code.rawValue)" + (detail.map { ": \($0)" } ?? "")
    }
}

// MARK: - Production Notes reader

/// Reads through the ONE process-wide Notes authority. `NotesDomainService`
/// owns the accepted epoch/store; this adapter contributes no caching, no
/// alternate store and no mutation.
public struct NotesDomainResourceReader: NotesResourceReading {
    public init() {}

    public func documentRevision(notesEpoch: UInt64, documentID: UUID) async throws -> Int {
        let data = try await call(
            epoch: notesEpoch,
            action: "document.summary",
            payload: .object(["documentID": .string(documentID.uuidString)])
        )
        let envelope: DocumentEnvelope
        do { envelope = try JSONDecoder().decode(DocumentEnvelope.self, from: data) }
        catch { throw NotesResourceStagingError(.notesReadFailed, "documentSummaryDecode") }
        guard envelope.ok else { throw NotesResourceStagingError(.documentNotFound) }
        return envelope.document.revision
    }

    public func resourceMetadata(
        notesEpoch: UInt64,
        resourceID: UUID
    ) async throws -> NotesResourceStagingMetadata {
        let data = try await call(
            epoch: notesEpoch,
            action: "resource.metadata",
            payload: .object(["resourceID": .string(resourceID.uuidString)])
        )
        let envelope: ResourceMetadataEnvelope
        do { envelope = try JSONDecoder().decode(ResourceMetadataEnvelope.self, from: data) }
        catch { throw NotesResourceStagingError(.notesReadFailed, "resourceMetadataDecode") }
        guard envelope.ok else { throw NotesResourceStagingError(.resourceUnavailable) }
        let record = envelope.resource
        guard record.id == resourceID else {
            throw NotesResourceStagingError(.resourceUnavailable, "resourceIdentityMismatch")
        }
        return NotesResourceStagingMetadata(
            resourceID: record.id,
            sha256: record.hash,
            byteCount: record.byteCount,
            fileName: record.fileName,
            mediaType: record.mediaType
        )
    }

    public func readResource(
        notesEpoch: UInt64,
        resourceID: UUID,
        conversationID: UUID,
        documentID: UUID,
        offset: Int64,
        maxBytes: Int
    ) async throws -> NotesResourceStagingChunk {
        let data = try await call(
            epoch: notesEpoch,
            action: "resource.read",
            payload: .object([
                "resourceID": .string(resourceID.uuidString),
                "conversationID": .string(conversationID.uuidString),
                "documentID": .string(documentID.uuidString),
                "offset": .integer(Int(offset)),
                "maxBytes": .integer(maxBytes),
            ])
        )
        let envelope: ResourceReadEnvelope
        do { envelope = try JSONDecoder().decode(ResourceReadEnvelope.self, from: data) }
        catch { throw NotesResourceStagingError(.notesReadFailed, "resourceReadDecode") }
        guard envelope.ok,
              let bytes = Data(base64Encoded: envelope.dataBase64),
              bytes.count <= maxBytes else {
            throw NotesResourceStagingError(.notesReadFailed, "resourceReadPayload")
        }
        return NotesResourceStagingChunk(
            data: bytes,
            nextOffset: envelope.nextOffset,
            totalBytes: envelope.totalBytes,
            eof: envelope.eof
        )
    }

    private func call(epoch: UInt64, action: String, payload: NotesJSONValue) async throws -> Data {
        let requestID = "c08-notes-stage-" + UUID().uuidString
        do {
            return try await NotesDomainService.shared.handle(
                epoch: epoch,
                requestID: String(requestID.prefix(80)),
                action: action,
                payload: payload
            )
        } catch {
            throw Self.mapNotesError(error)
        }
    }

    private static func mapNotesError(_ error: Error) -> NotesResourceStagingError {
        if let error = error as? NotesDomainError {
            switch error {
            case .notBound, .staleGeneration, .storageUnavailable, .busy:
                return NotesResourceStagingError(.notesUnavailable)
            case .invalidPayload:
                return NotesResourceStagingError(.invalidRequest)
            case .unsupportedAction, .requestTooLarge, .responseTooLarge,
                 .stageNotFound, .stageExpired:
                return NotesResourceStagingError(.notesReadFailed)
            }
        }
        if let error = error as? NoteError {
            switch error {
            case .invalidOperation(let reason) where reason == "resourceAccessDenied":
                return NotesResourceStagingError(.resourceAccessDenied)
            case .resourceUnavailable:
                return NotesResourceStagingError(.resourceUnavailable)
            case .notFound:
                return NotesResourceStagingError(.documentNotFound)
            case .conflict:
                return NotesResourceStagingError(.documentRevisionMismatch)
            case .storageUnavailable, .invalidDocument:
                return NotesResourceStagingError(.notesReadFailed)
            }
        }
        return NotesResourceStagingError(.notesReadFailed)
    }

    private struct DocumentEnvelope: Decodable {
        let ok: Bool
        let document: Document
        struct Document: Decodable { let revision: Int }
    }

    private struct ResourceMetadataEnvelope: Decodable {
        let ok: Bool
        let resource: NoteResourceRecord
    }

    private struct ResourceReadEnvelope: Decodable {
        let ok: Bool
        let nextOffset: Int64
        let totalBytes: Int64
        let eof: Bool
        let dataBase64: String
    }
}

// MARK: - Staging service

public struct NotesResourceStagingService: Sendable {
    /// Resolves the accepted generation's owned app-private storage root.
    public typealias RuntimeRootResolver = @Sendable (UInt64) -> RuntimeStorageRoot?
    /// Resolves the REAL task workspace for a run/conversation through the
    /// original workspace authority. Nil means "no real binding"; callers must
    /// fail closed.
    public typealias TaskWorkspaceResolver = @Sendable (UUID, UUID) async -> URL?
    /// Real owned-work admission for the whole staging transaction. The
    /// default is the process-wide registry; tests inject the same contract.
    public typealias OwnerAdmission = @Sendable (UInt64, UUID) -> RuntimeOwnedWorkAttachOutcome
    /// Releases an admission this service acquired. A caller-supplied lease
    /// (the run launch already registered it in its ownership map) is NEVER
    /// released here.
    public typealias OwnerRelease = @Sendable (RuntimeOwnedWorkToken) -> Void
    /// Exact-token liveness probe for a caller-supplied lease.
    public typealias OwnerAttachedProbe = @Sendable (RuntimeOwnedWorkToken) -> Bool
    /// Cooperative cancellation probe for the owning run/conversation. It is
    /// checked at the same phase boundaries as the token so deletion/cancel
    /// cannot begin a commit behind the caller's back.
    public typealias CancellationProbe = @Sendable () -> Bool

    public static let maximumResourceBytes: Int64 = 536_870_912
    public static let maximumChunkBytes = 1_048_576
    public static let maximumChunks = 1_024
    /// Only this service's own `*.part` files can be swept, and only after a
    /// conservative quiescence window.
    public static let staleStageLifetime: TimeInterval = 86_400
    public static let maximumSweptStages = 32

    private let notes: any NotesResourceReading
    private let runtimeRoot: RuntimeRootResolver
    private let taskWorkspace: TaskWorkspaceResolver
    private let ownerAdmission: OwnerAdmission
    private let ownerRelease: OwnerRelease
    private let ownerAttached: OwnerAttachedProbe

    public init(
        notes: any NotesResourceReading,
        runtimeRoot: @escaping RuntimeRootResolver,
        taskWorkspace: @escaping TaskWorkspaceResolver,
        ownerAdmission: @escaping OwnerAdmission = { epoch, conversationID in
            RuntimeOwnedWorkRegistry.shared.attach(
                epoch: epoch, kind: .conversation,
                ownerID: conversationID.uuidString)
        },
        ownerRelease: @escaping OwnerRelease = { token in
            _ = RuntimeOwnedWorkRegistry.shared.detach(token)
        },
        ownerAttached: @escaping OwnerAttachedProbe = { token in
            RuntimeOwnedWorkRegistry.shared.isAttached(token)
        }
    ) {
        self.notes = notes
        self.runtimeRoot = runtimeRoot
        self.taskWorkspace = taskWorkspace
        self.ownerAdmission = ownerAdmission
        self.ownerRelease = ownerRelease
        self.ownerAttached = ownerAttached
    }

    /// Production composition: the ONE Notes domain service and the ORIGINAL
    /// workspace/run authority.
    public static func live() -> NotesResourceStagingService {
        NotesResourceStagingService(
            notes: NotesDomainResourceReader(),
            runtimeRoot: { epoch in
                AndroidRuntimeBootstrap.notesBinding(epoch: epoch, ownerToken: nil)
            },
            taskWorkspace: { runID, conversationID in
                await LinuxWorkspaceAuthority.trustedWorkspaceRoot(
                    runID: runID, conversationID: conversationID)
            }
        )
    }

    /// Stages exactly one Notes resource into the real task workspace.
    ///
    /// - Parameters:
    ///   - cancellation: cooperative token checked before every chunk/phase.
    ///   - isCancelled: trusted run/deletion probe from the owning launch.
    ///   - ownerLease: a REAL admission already attached by the run launch
    ///     and registered in that run's ownership map. When present the
    ///     service verifies the exact identity/liveness and NEVER detaches it;
    ///     the run launch owns the lease through its commit/drain. When absent
    ///     the service attaches its own `.conversation` lease and a rejected
    ///     admission is a typed refusal BEFORE any filesystem effect.
    public func stage(
        _ request: NotesResourceStagingRequest,
        cancellation: CancellationToken? = nil,
        isCancelled: CancellationProbe? = nil,
        ownerLease: RuntimeOwnedWorkToken? = nil
    ) async throws -> NotesResourceStagingReceipt {
        try Self.validate(request)
        try Self.checkCancelled(cancellation, isCancelled)

        // OWNER FENCE FIRST: no Notes read, staging directory or task write
        // may happen without a live exact-token admission. The previous
        // best-effort attach silently continued when the registry refused,
        // which could commit bytes while a retiring/deleting owner was closing
        // the very root underneath the transaction.
        let lease: RuntimeOwnedWorkToken
        let releaseLease: Bool
        if let ownerLease {
            let correctOwner = (ownerLease.kind == .conversation &&
                ownerLease.ownerID == request.conversationID.uuidString) ||
                (ownerLease.kind == .run && ownerLease.ownerID == request.runID.uuidString)
            guard ownerLease.epoch == request.notesEpoch,
                  correctOwner,
                  ownerAttached(ownerLease) else {
                throw NotesResourceStagingError(.ownerAdmissionRefused, "leaseIdentity")
            }
            lease = ownerLease
            releaseLease = false
        } else {
            switch ownerAdmission(request.notesEpoch, request.conversationID) {
            case .attached(let token):
                lease = token
                releaseLease = true
            case .rejected(let code):
                throw NotesResourceStagingError(
                    .ownerAdmissionRefused, "rejected:\(code.rawValue)")
            case .invalidIdentity:
                throw NotesResourceStagingError(.ownerAdmissionRefused, "invalidIdentity")
            }
        }
        defer {
            if releaseLease { ownerRelease(lease) }
        }

        // Resolve the REAL task only after admission: an unbound/temporary
        // task must not even cause a Notes read, and the root is never
        // caller-supplied.
        guard let initialTaskRoot = await taskWorkspace(request.runID, request.conversationID) else {
            throw NotesResourceStagingError(.taskWorkspaceUnavailable)
        }
        guard let acceptedRuntimeRoot = runtimeRoot(request.notesEpoch) else {
            throw NotesResourceStagingError(.notesUnavailable)
        }
        try Self.checkCancelled(cancellation, isCancelled)

        let stagingDirectory = acceptedRuntimeRoot.artifactStoreURL
            .appendingPathComponent("NotesImports", isDirectory: true)
            .appendingPathComponent("Staging", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: stagingDirectory, withIntermediateDirectories: true)
        } catch {
            throw NotesResourceStagingError(.stagingFailed, "stagingDirectory")
        }
        Self.sweepStaleStages(in: stagingDirectory)

        let stageURL = stagingDirectory
            .appendingPathComponent("\(UUID().uuidString).part", isDirectory: false)
        guard FileManager.default.createFile(atPath: stageURL.path, contents: nil) else {
            throw NotesResourceStagingError(.stagingFailed, "stageCreate")
        }
        defer { try? FileManager.default.removeItem(at: stageURL) }

        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: stageURL) }
        catch {
            throw NotesResourceStagingError(.stagingFailed, "stageOpen")
        }

        var metadata: NotesResourceStagingMetadata?
        var totalBytes: Int64 = -1
        var written: Int64 = 0
        var offset: Int64 = 0
        var chunkCount = 0
        var hasher = SHA256()

        do {
            while true {
                try Self.checkCancelled(cancellation, isCancelled)
                let chunk: NotesResourceStagingChunk
                do {
                    chunk = try await notes.readResource(
                        notesEpoch: request.notesEpoch,
                        resourceID: request.resourceID,
                        conversationID: request.conversationID,
                        documentID: request.documentID,
                        offset: offset,
                        maxBytes: Self.maximumChunkBytes
                    )
                } catch let error as NotesResourceStagingError {
                    throw error
                } catch let error as NoteError {
                    throw Self.mapNoteError(error)
                } catch {
                    throw NotesResourceStagingError(.notesReadFailed)
                }

                if metadata == nil {
                    guard chunk.totalBytes > 0 else {
                        throw NotesResourceStagingError(.resourceEmpty)
                    }
                    guard chunk.totalBytes <= Self.maximumResourceBytes else {
                        throw NotesResourceStagingError(.resourceTooLarge)
                    }
                    totalBytes = chunk.totalBytes
                    let record: NotesResourceStagingMetadata
                    do {
                        record = try await notes.resourceMetadata(
                            notesEpoch: request.notesEpoch,
                            resourceID: request.resourceID)
                    } catch let error as NotesResourceStagingError {
                        throw error
                    } catch let error as NoteError {
                        throw Self.mapNoteError(error)
                    } catch {
                        throw NotesResourceStagingError(.notesReadFailed)
                    }
                    guard record.byteCount == totalBytes else {
                        throw NotesResourceStagingError(
                            .resourceSizeMismatch,
                            "record=\(record.byteCount) read=\(totalBytes)")
                    }
                    guard Self.isSHA256(record.sha256) else {
                        throw NotesResourceStagingError(.resourceDigestMismatch, "recordDigestShape")
                    }
                    if let expected = request.expectedResourceSHA256,
                       expected.lowercased() != record.sha256.lowercased() {
                        throw NotesResourceStagingError(
                            .resourceDigestMismatch,
                            "selected=\(expected.prefix(12)) record=\(record.sha256.prefix(12))")
                    }
                    let revision = try await documentRevision(request)
                    guard revision == request.expectedDocumentRevision else {
                        throw NotesResourceStagingError(
                            .documentRevisionMismatch,
                            "expected=\(request.expectedDocumentRevision) actual=\(revision)")
                    }
                    metadata = record
                }

                guard let metadata else {
                    throw NotesResourceStagingError(.notesReadFailed, "metadataUnavailable")
                }
                guard chunk.totalBytes == totalBytes else {
                    throw NotesResourceStagingError(
                        .resourceSizeMismatch, "totalBytesChanged=\(chunk.totalBytes)")
                }
                if !chunk.data.isEmpty {
                    do { try handle.write(contentsOf: chunk.data) }
                    catch {
                        throw NotesResourceStagingError(.stagingFailed, "stageWrite")
                    }
                    hasher.update(data: chunk.data)
                    written += Int64(chunk.data.count)
                    guard written <= metadata.byteCount else {
                        throw NotesResourceStagingError(.resourceSizeMismatch, "stageOverflow")
                    }
                }
                if chunk.eof { break }
                guard chunk.nextOffset > offset,
                      chunk.nextOffset <= totalBytes else {
                    throw NotesResourceStagingError(.notesReadFailed, "nonAdvancingChunk")
                }
                offset = chunk.nextOffset
                chunkCount += 1
                guard chunkCount <= Self.maximumChunks else {
                    throw NotesResourceStagingError(.resourceTooLarge)
                }
            }
            try handle.synchronize()
        } catch {
            try? handle.close()
            throw error
        }
        do { try handle.close() }
        catch { throw NotesResourceStagingError(.stagingFailed, "stageClose") }

        guard let metadata, totalBytes > 0 else {
            throw NotesResourceStagingError(.notesReadFailed, "emptyStage")
        }
        guard written == totalBytes,
              written == metadata.byteCount else {
            throw NotesResourceStagingError(
                .resourceSizeMismatch, "bytes=\(written) expected=\(metadata.byteCount)")
        }
        let stagedDigest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard stagedDigest == metadata.sha256.lowercased() else {
            throw NotesResourceStagingError(
                .resourceDigestMismatch,
                "staged=\(stagedDigest.prefix(12)) record=\(metadata.sha256.prefix(12))")
        }

        // A grant revoked during staging wins: the LAST read before commit
        // runs the same store authorization rule again (one byte at the final
        // offset, not a cached "authorized" boolean).
        try Self.checkCancelled(cancellation, isCancelled)
        do {
            _ = try await notes.readResource(
                notesEpoch: request.notesEpoch,
                resourceID: request.resourceID,
                conversationID: request.conversationID,
                documentID: request.documentID,
                offset: max(0, totalBytes - 1),
                maxBytes: 1
            )
        } catch let error as NotesResourceStagingError {
            throw error
        } catch let error as NoteError {
            throw Self.mapNoteError(error)
        } catch {
            throw NotesResourceStagingError(.notesReadFailed, "finalAuthorityProbe")
        }
        // A late Notes edit or document switch wins: the exact revision the
        // user selected must still be current immediately before commit.
        let finalRevision = try await documentRevision(request)
        guard finalRevision == request.expectedDocumentRevision else {
            throw NotesResourceStagingError(
                .documentRevisionMismatch,
                "expected=\(request.expectedDocumentRevision) actual=\(finalRevision)")
        }

        // A retired generation or a rebound task root must not receive bytes.
        guard let currentRuntime = runtimeRoot(request.notesEpoch),
              currentRuntime.path == acceptedRuntimeRoot.path else {
            throw NotesResourceStagingError(.notesUnavailable)
        }
        guard let finalTaskRoot = await taskWorkspace(request.runID, request.conversationID),
              Self.sameDirectory(finalTaskRoot, initialTaskRoot) else {
            throw NotesResourceStagingError(.taskWorkspaceUnavailable)
        }
        try Self.checkCancelled(cancellation, isCancelled)

        let fileName = Self.sanitizedFileName(metadata.fileName, resourceID: request.resourceID)
        let destination = Self.destinationRelativePath(
            documentID: request.documentID, fileName: fileName,
            resourceID: request.resourceID)
        let guardResolver = WorkspacePathGuard(rootURL: finalTaskRoot)
        let service = WorkspaceFileService(
            guard: guardResolver,
            mutationGuard: WorkspaceToolEnvironment.designFreezeGate())

        let stagedAt = Date()
        func receipt(idempotent: Bool) -> NotesResourceStagingReceipt {
            NotesResourceStagingReceipt(
                documentID: request.documentID,
                documentRevision: finalRevision,
                resourceID: request.resourceID,
                resourceSHA256: metadata.sha256,
                byteCount: metadata.byteCount,
                resourceFileName: metadata.fileName,
                fileName: fileName,
                mediaType: metadata.mediaType,
                ownerConversationID: request.conversationID,
                ownerRunID: request.runID,
                notesEpoch: request.notesEpoch,
                runtimeRootFingerprint: acceptedRuntimeRoot.fingerprint,
                workspaceRootFingerprint: Self.workspaceFingerprint(finalTaskRoot),
                destinationRelativePath: destination,
                stagedSHA256: stagedDigest,
                stagedAt: stagedAt,
                idempotent: idempotent
            )
        }

        // Exact re-staging is idempotent; anything else at the same path is a
        // conflict and is never overwritten.
        let existing: WorkspaceFileMetadata?
        do {
            existing = try service.metadata(destination)
        } catch let error as WorkspaceToolError {
            if case .notFound = error {
                existing = nil
            } else if case .tooLarge = error {
                throw NotesResourceStagingError(.destinationConflict, "existingUnreadable")
            } else {
                throw NotesResourceStagingError(.stagingFailed, "destinationInspect")
            }
        } catch {
            throw NotesResourceStagingError(.stagingFailed, "destinationInspect")
        }
        if let existing {
            guard !existing.isDirectory,
                  !existing.isSymlink,
                  existing.size == metadata.byteCount,
                  existing.sha256.lowercased() == stagedDigest else {
                throw NotesResourceStagingError(.destinationConflict, destination)
            }
            return receipt(idempotent: true)
        }

        do {
            let outcome = try service.importUserFile(
                from: stageURL,
                to: destination,
                expectedSHA256: stagedDigest,
                cancellation: cancellation
            )
            guard outcome.bytesWritten == Int(metadata.byteCount),
                  outcome.sha256.lowercased() == stagedDigest else {
                throw NotesResourceStagingError(.destinationConflict, "commitVerification")
            }
            return receipt(idempotent: false)
        } catch let error as NotesResourceStagingError {
            throw error
        } catch let error as WorkspaceToolError {
            switch error {
            case .alreadyExists, .alreadyExistsOverwritable:
                // A concurrent writer won the same path. Only identical bytes
                // are accepted; everything else is a conflict.
                if let current = try? service.metadata(destination),
                   !current.isDirectory, !current.isSymlink,
                   current.size == metadata.byteCount,
                   current.sha256.lowercased() == stagedDigest {
                    return receipt(idempotent: true)
                }
                throw NotesResourceStagingError(.destinationConflict, destination)
            case .notFound, .tooLarge, .isDirectory,
                 .escapesRoot, .secretFile, .conflict,
                 .invalidPatch, .invalidArguments, .unsupportedContent,
                 .unsupportedScope:
                throw NotesResourceStagingError(.stagingFailed, error.code)
            }
        } catch let error as FloeError {
            if error == .cancelled {
                throw NotesResourceStagingError(.cancelled)
            }
            throw NotesResourceStagingError(.stagingFailed)
        } catch {
            throw NotesResourceStagingError(.stagingFailed)
        }
    }

    // MARK: - Helpers

    /// The ONE deterministic destination for a selected Notes resource. This
    /// is shared by the two-phase launch receipt so the task input can name
    /// the real task-relative path before the run exists; it is never derived
    /// from model text or a caller-supplied path.
    public static func destinationRelativePath(
        documentID: UUID, fileName: String, resourceID: UUID
    ) -> String {
        let sanitized = sanitizedFileName(fileName, resourceID: resourceID)
        return "NotesImports/\(documentID.uuidString)/\(sanitized)"
    }

    private static func checkCancelled(
        _ cancellation: CancellationToken?,
        _ isCancelled: CancellationProbe?
    ) throws {
        if cancellation?.isCancelled == true || isCancelled?() == true {
            throw NotesResourceStagingError(.cancelled)
        }
    }

    private func documentRevision(_ request: NotesResourceStagingRequest) async throws -> Int {
        do {
            return try await notes.documentRevision(
                notesEpoch: request.notesEpoch, documentID: request.documentID)
        } catch let error as NotesResourceStagingError {
            throw error
        } catch let error as NoteError {
            throw Self.mapNoteError(error)
        } catch {
            throw NotesResourceStagingError(.notesReadFailed, "documentRevision")
        }
    }

    private static func mapNoteError(_ error: NoteError) -> NotesResourceStagingError {
        switch error {
        case .invalidOperation(let reason) where reason == "resourceAccessDenied":
            return NotesResourceStagingError(.resourceAccessDenied)
        case .resourceUnavailable:
            return NotesResourceStagingError(.resourceUnavailable)
        case .notFound:
            return NotesResourceStagingError(.documentNotFound)
        case .conflict:
            return NotesResourceStagingError(.documentRevisionMismatch)
        case .storageUnavailable, .invalidDocument:
            return NotesResourceStagingError(.notesReadFailed)
        }
    }

    private static func validate(_ request: NotesResourceStagingRequest) throws {
        guard request.notesEpoch > 0 else {
            throw NotesResourceStagingError(.invalidRequest, "epoch")
        }
        guard request.expectedDocumentRevision >= 0 else {
            throw NotesResourceStagingError(.invalidRequest, "revision")
        }
        if let digest = request.expectedResourceSHA256, !isSHA256(digest) {
            throw NotesResourceStagingError(.invalidRequest, "expectedDigestShape")
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func sameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path
            == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func workspaceFingerprint(_ root: URL) -> String {
        let path = root.standardizedFileURL.resolvingSymlinksInPath().path
        return String(FloeDigest.sha256Hex(Data(path.utf8)).prefix(12))
    }

    /// Bounded display-name sanitizer. Never returns a path component that can
    /// escape the `NotesImports/<documentID>/` directory.
    static func sanitizedFileName(_ raw: String, resourceID: UUID) -> String {
        var name = (raw as NSString).lastPathComponent
        var cleaned = String()
        for scalar in name.unicodeScalars {
            if scalar.value == 0 || scalar == "/" || scalar == "\\" || scalar == ":"
                || CharacterSet.controlCharacters.contains(scalar) {
                cleaned.append("_")
            } else {
                cleaned.unicodeScalars.append(scalar)
            }
        }
        name = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." {
            name = "resource-\(resourceID.uuidString.prefix(8))"
        }
        if name.hasPrefix(".") {
            name = "_" + String(name.dropFirst())
        }
        if name == "_" {
            name = "resource-\(resourceID.uuidString.prefix(8))"
        }
        // The destination lives in a new `NotesImports/<documentID>/`
        // directory, but the guard still applies its workspace-wide secret
        // denylist to the complete path. A user's Notes attachment is not a
        // credential; prefix a denylisted basename instead of failing a
        // legitimate document staging.
        if isSecretBasename(name) {
            name = "resource-" + name
        }
        let nsName = name as NSString
        var ext = nsName.pathExtension
        if ext.utf8.count > 32
            || ext.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            || secretExtensions.contains(ext.lowercased()) {
            ext = ext.isEmpty ? "" : "data"
        }
        var stem = ext.isEmpty ? name : nsName.deletingPathExtension
        let budget = 180 - (ext.isEmpty ? 0 : ext.utf8.count + 1)
        if stem.utf8.count > budget {
            var truncated = String()
            var bytes = 0
            for scalar in stem.unicodeScalars {
                let width = Utf8Encoding.width(scalar)
                if bytes + width > budget { break }
                truncated.unicodeScalars.append(scalar)
                bytes += width
            }
            stem = truncated
        }
        if stem.isEmpty || stem == "." || stem == ".." {
            stem = "resource-\(resourceID.uuidString.prefix(8))"
        }
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    private static let secretBasenames: Set<String> = [
        ".netrc", ".npmrc", ".pypirc", ".git-credentials", ".htpasswd"
    ]
    private static let secretPrefixes: [String] = [
        ".env", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".pgpass"
    ]
    private static let secretExtensions: Set<String> = [
        "pem", "key", "keystore", "p12", "pfx", "jks"
    ]

    private static func isSecretBasename(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if secretBasenames.contains(lowered) { return true }
        if secretPrefixes.contains(where: { lowered.hasPrefix($0) }) { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return !ext.isEmpty && secretExtensions.contains(ext)
    }

    /// Removes only this service's own stale `*.part` files. Bounded and
    /// best-effort: an unreachable directory never fails a staging request.
    static func sweepStaleStages(in directory: URL, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-staleStageLifetime)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]) else { return }
        var removed = 0
        for entry in entries {
            guard removed < maximumSweptStages,
                  entry.pathExtension == "part",
                  let values = try? entry.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            if (try? FileManager.default.removeItem(at: entry)) != nil { removed += 1 }
        }
    }
}

/// UTF-8 width helper for the bounded name sanitizer (no reliance on
/// platform-specific String length semantics).
private enum Utf8Encoding {
    static func width(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0...0x7F: return 1
        case 0x80...0x7FF: return 2
        case 0x800...0xFFFF: return 3
        default: return 4
        }
    }
}
