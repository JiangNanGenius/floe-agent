// SPDX-License-Identifier: MPL-2.0
//
// G09-R1 — Canvas project file authority.
//
// One canvas is one schema-version-7 JSON document at
// `<acceptedRoot>/FloeAgent/Canvases/<UUID>.json`. This actor owns the real
// compare-and-swap write path:
//
//   read (expected revision) → apply the original CanvasCommandService patch
//   → encode canonically → same-directory temp + fsync → atomic rename.
//
// Corrupt and newer-schema files are never overwritten. They stay byte
// identical and are reported as typed recovery states. A committed patch is
// journaled as an idempotent receipt before the response is returned, so a
// lost reply can be retried without applying the edit twice.
import Foundation
import FloeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct G09CanvasWriteReceipt: Codable, Sendable, Equatable {
    public var opID: String
    public var canvasID: UUID
    public var sessionDigest: String
    public var expectedRevision: Int64
    public var revision: Int64
    public var committedAt: Date

    public init(opID: String, canvasID: UUID, sessionDigest: String,
                expectedRevision: Int64, revision: Int64, committedAt: Date = Date()) {
        self.opID = opID
        self.canvasID = canvasID
        self.sessionDigest = sessionDigest
        self.expectedRevision = expectedRevision
        self.revision = revision
        self.committedAt = committedAt
    }
}

public struct G09CanvasCommitIntent: Codable, Sendable, Equatable {
    public var opID: String
    public var canvasID: UUID
    public var fingerprint: String
    public var expectedRevision: Int64
    public var resultRevision: Int64
    public var resultDigest: String
    public var preparedAt: Date
    public var committedAt: Date?
    /// Closed operation family. Older patch intents have no `kind` on disk and
    /// decode as nil, which is the same meaning as "patch".
    public var kind: String?
    /// The content-addressed asset an atomic source-create publishes. Patch
    /// intents leave this nil.
    public var asset: CanvasAssetReference?

    public init(opID: String, canvasID: UUID, fingerprint: String,
                expectedRevision: Int64, resultRevision: Int64,
                resultDigest: String, preparedAt: Date = Date(),
                committedAt: Date? = nil, kind: String? = nil,
                asset: CanvasAssetReference? = nil) {
        self.opID = opID
        self.canvasID = canvasID
        self.fingerprint = fingerprint
        self.expectedRevision = expectedRevision
        self.resultRevision = resultRevision
        self.resultDigest = resultDigest
        self.preparedAt = preparedAt
        self.committedAt = committedAt
        self.kind = kind
        self.asset = asset
    }
}

public actor G09CanvasProjectRepository {
    public struct Loaded: Sendable {
        public var project: CanvasProject
        public var warnings: [String]
    }

    private let root: RuntimeStorageRoot
    private let fileManager = FileManager.default

    public init(root: RuntimeStorageRoot) {
        self.root = root
    }

    public nonisolated var canvasDirectoryPath: String {
        root.artifactStoreURL.appendingPathComponent("Canvases", isDirectory: true).path
    }

    public nonisolated var materialsDirectoryPath: String {
        root.artifactStoreURL.appendingPathComponent("Materials", isDirectory: true).path
    }

    public nonisolated var recoveryDirectoryPath: String {
        root.artifactStoreURL.appendingPathComponent("CanvasRecovery", isDirectory: true).path
    }

    private nonisolated var canvasDirectory: URL {
        URL(fileURLWithPath: canvasDirectoryPath, isDirectory: true)
    }

    private nonisolated var recoveryDirectory: URL {
        URL(fileURLWithPath: recoveryDirectoryPath, isDirectory: true)
    }

    private nonisolated var receiptsDirectory: URL {
        recoveryDirectory.appendingPathComponent("Receipts", isDirectory: true)
    }

    private nonisolated var deletedDirectory: URL {
        recoveryDirectory.appendingPathComponent("Deleted", isDirectory: true)
    }

    private nonisolated var intentDirectory: URL {
        recoveryDirectory.appendingPathComponent("Intents", isDirectory: true)
    }

    /// Test-only crash seam AFTER the atomic canvas replace and BEFORE the
    /// committed intent/receipt write. Production leaves this nil.
    internal var faultAfterCommit: (@Sendable () throws -> Void)?

    /// Test-only crash seam AFTER the durable source-create intent and its
    /// reference increment but BEFORE the project file is published.
    internal var faultBeforePublish: (@Sendable () throws -> Void)?

    internal func setFaultAfterCommit(_ closure: (@Sendable () throws -> Void)?) {
        faultAfterCommit = closure
    }

    internal func setFaultBeforePublish(_ closure: (@Sendable () throws -> Void)?) {
        faultBeforePublish = closure
    }

    public nonisolated func projectURL(id: UUID) -> URL {
        canvasDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - Read

    public func list() throws -> [G09CanvasSummaryDTO] {
        try ensureDirectory(canvasDirectory)
        let entries = try fileManager.contentsOfDirectory(
            at: canvasDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        var summaries: [G09CanvasSummaryDTO] = []
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension.lowercased() == "json" {
            guard summaries.count < G09CreativeLimits.libraryEntries else { break }
            let fallbackID = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
            guard let id = fallbackID else { continue }
            do {
                let loaded = try readProject(at: url, expectedID: id)
                summaries.append(G09CanvasSummaryDTO(
                    id: loaded.project.id,
                    name: loaded.project.name,
                    revision: loaded.project.revision,
                    updatedAt: loaded.project.updatedAt,
                    schemaVersion: loaded.project.schemaVersion,
                    documentCount: loaded.project.documents.count,
                    corrupt: false,
                    writable: loaded.warnings.isEmpty))
            } catch {
                // Keep the file exactly as found. The list surfaces a corrupt
                // entry instead of silently hiding or deleting user data.
                summaries.append(G09CanvasSummaryDTO(
                    id: id, name: "", revision: 0, updatedAt: Date(timeIntervalSince1970: 0),
                    schemaVersion: 0, documentCount: 0, corrupt: true, writable: false))
            }
        }
        return summaries.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    public func load(id: UUID) throws -> Loaded {
        try readProject(at: projectURL(id: id), expectedID: id)
    }

    private func readProject(at url: URL, expectedID: UUID) throws -> Loaded {
        guard fileManager.fileExists(atPath: url.path) else {
            throw G09CreativeError.canvasNotFound
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize, size > G09CreativeLimits.canvasProjectBytes {
            throw G09CreativeError.projectTooLarge
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw G09CreativeError.storageUnavailable
        }
        guard data.count <= G09CreativeLimits.canvasProjectBytes else {
            throw G09CreativeError.projectTooLarge
        }
        let project: CanvasProject
        do {
            project = try G09CreativeWire.decoder().decode(CanvasProject.self, from: data)
        } catch {
            throw G09CreativeError.corruptProject
        }
        guard project.schemaVersion <= CanvasProject.currentSchemaVersion else {
            throw G09CreativeError.unsupportedSchema
        }
        guard project.schemaVersion >= 1, !project.documents.isEmpty else {
            throw G09CreativeError.corruptProject
        }
        var id = project.id
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["id"] == nil {
            id = expectedID
        }
        guard id == expectedID else { throw G09CreativeError.corruptProject }
        var canonical = project
        canonical.id = expectedID
        canonical.schemaVersion = CanvasProject.currentSchemaVersion
        if !canonical.documents.contains(where: { $0.id == canonical.selectedDocumentID }),
           let first = canonical.documents.first {
            canonical.selectedDocumentID = first.id
        }
        var warnings: [String] = []
        let unsafeAssets = canonical.documents.flatMap(\.nodes).compactMap(\.asset)
            .filter { !G09CreativeAssetHost.safeRelativePath($0.localRelativePath) }
        if !unsafeAssets.isEmpty {
            warnings.append("unsafeAssetReference")
        }
        if canonical.designProjectAuthority != nil {
            // R1 preserves CAD/design metadata as opaque state. It never edits
            // geometry or forks a CAD-bound canvas (G10 owns that).
            warnings.append("cadMetadataReadOnly")
        }
        return Loaded(project: canonical, warnings: warnings)
    }

    // MARK: - Create / patch / rename

    public func create(name: String, workspaceID: UUID? = nil, now: Date = Date()) throws -> Loaded {
        let id = UUID()
        let document = CanvasDocument(name: name)
        let project = CanvasProject(
            id: id, workspaceID: workspaceID, name: name,
            documents: [document], selectedDocumentID: document.id,
            viewports: [document.id: .init()], revision: 1,
            createdAt: now, updatedAt: now)
        try write(project, expectedRevision: nil, requireAbsent: true)
        return Loaded(project: project, warnings: [])
    }

    // MARK: - Atomic source-import creation

    public struct SourceCreateOutcome: Sendable {
        public var loaded: Loaded
        public var idempotent: Bool
    }

    /// Publishes ONE new canvas whose initial document already references the
    /// ingested source asset. The project file appears only after the asset
    /// bytes exist and the durable pre-commit intent was written, so a failed
    /// or cancelled import can never leave an empty project behind.
    ///
    /// Identity is derived from `opID` by the caller, so a retry targets the
    /// same intended document. A matching committed intent is replayed (and
    /// its post-commit reference step completed idempotently); a changed
    /// fingerprint or a foreign file at the derived identity is refused.
    public func createFromSource(
        projectID: UUID,
        opID: String,
        referenceOpID: String,
        name: String,
        workspaceID: UUID?,
        sessionToken: String,
        fingerprint: String,
        nodeKind: CanvasNodeKind,
        displayName: String,
        ensureAsset: @Sendable (_ recorded: CanvasAssetReference?)
            async throws -> CanvasAssetReference,
        applyReference: @Sendable (_ assetID: UUID, _ referenceOpID: String)
            async throws -> Void
    ) async throws -> SourceCreateOutcome {
        guard G09CreativeWire.safeOperationID(opID),
              G09CreativeWire.safeOperationID(referenceOpID) else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        guard let cleanName = G09CreativeWire.sanitizedName(name) else {
            throw G09CreativeError.invalidPayload("invalidName")
        }
        let projectURL = projectURL(id: projectID)
        var preparedAt = Date()
        var recordedAsset: CanvasAssetReference?
        if let existing = try? readIntent(opID: opID) {
            // A closed family check keeps a patch/rename intent that happens
            // to share the opID from being mistaken for a create.
            guard existing.kind == "createFromStaged",
                  existing.canvasID == projectID,
                  existing.fingerprint == fingerprint else {
                throw G09CreativeError.invalidPayload("intentMismatch")
            }
            preparedAt = existing.preparedAt
            recordedAsset = existing.asset
            if fileManager.fileExists(atPath: projectURL.path) {
                let current = try load(id: projectID)
                let digest = FloeDigest.sha256Hex(try canonicalData(for: current.project))
                guard current.project.revision == existing.resultRevision,
                      digest == existing.resultDigest else {
                    throw G09CreativeError.outcomeUnknown
                }
                // The document is durable. Complete the reference increment
                // (its own store receipt makes the replay a no-op) and the
                // committed receipt, then return the known outcome. A missing
                // asset row cannot un-create the published document, so it is
                // reported as a recovery warning instead of a false failure.
                var warnings = current.warnings
                if let asset = try? await ensureAsset(recordedAsset) {
                    do {
                        try await applyReference(asset.id, referenceOpID)
                    } catch {
                        warnings.append("assetReferencePending")
                    }
                } else {
                    warnings.append("assetReferencePending")
                }
                if existing.committedAt == nil { markIntentCommitted(existing) }
                try? writeReceipt(G09CanvasWriteReceipt(
                    opID: opID, canvasID: projectID,
                    sessionDigest: G09CreativeAssetHost.sessionDigest(sessionToken),
                    expectedRevision: 0, revision: current.project.revision))
                return SourceCreateOutcome(
                    loaded: Loaded(project: current.project, warnings: warnings),
                    idempotent: true)
            }
        } else if fileManager.fileExists(atPath: projectURL.path) {
            // No durable record of our intent owns this identity: never
            // overwrite a canvas we did not create for this operation.
            throw G09CreativeError.invalidPayload("projectIdentityCollision")
        }

        let asset = try await ensureAsset(recordedAsset)
        let draft = sourceDraft(
            projectID: projectID, opID: opID, name: cleanName,
            workspaceID: workspaceID, nodeKind: nodeKind,
            displayName: displayName, asset: asset, now: preparedAt)
        let encoded = try canonicalData(for: draft)
        guard encoded.count <= G09CreativeLimits.canvasProjectBytes else {
            throw G09CreativeError.projectTooLarge
        }
        let digest = FloeDigest.sha256Hex(encoded)
        let intent = G09CanvasCommitIntent(
            opID: opID, canvasID: projectID, fingerprint: fingerprint,
            expectedRevision: 0, resultRevision: draft.revision,
            resultDigest: digest, preparedAt: preparedAt, committedAt: nil,
            kind: "createFromStaged", asset: asset)
        try writeIntent(intent)
        // Reference increment happens BEFORE publication and is idempotent on
        // retry: a crash can only over-retain bytes (deferred reclamation),
        // never publish a canvas that references an unaccounted asset.
        try await applyReference(asset.id, referenceOpID)
        try faultBeforePublish?()
        try publishInitial(draft, encoded: encoded)
        try faultAfterCommit?()
        markIntentCommitted(intent)
        try? writeReceipt(G09CanvasWriteReceipt(
            opID: opID, canvasID: projectID,
            sessionDigest: G09CreativeAssetHost.sessionDigest(sessionToken),
            expectedRevision: 0, revision: draft.revision))
        return SourceCreateOutcome(
            loaded: Loaded(project: draft, warnings: []), idempotent: false)
    }

    /// Initial non-empty draft: one document and one node that references the
    /// already-ingested asset. Node identity and timestamps are derived from
    /// the operation so an interrupted pre-commit retry assembles identical
    /// bytes (the recorded intent digest must match exactly).
    private func sourceDraft(
        projectID: UUID, opID: String, name: String, workspaceID: UUID?,
        nodeKind: CanvasNodeKind, displayName: String,
        asset: CanvasAssetReference, now: Date
    ) -> CanvasProject {
        let nodeID = G09SourceCreateIdentity.nodeID(domain: "canvas", opID: opID)
        let size: CanvasSize = switch nodeKind {
        case .image: CanvasSize(width: 320, height: 260)
        case .video: CanvasSize(width: 320, height: 220)
        case .audio: CanvasSize(width: 320, height: 170)
        default: CanvasSize(width: 320, height: 170)
        }
        let node = CanvasNode(
            id: nodeID, kind: nodeKind, text: displayName,
            position: CanvasPoint(x: 0, y: 0), size: size, zIndex: 1,
            asset: asset, metadata: ["artifactOrigin": "imported"])
        let document = CanvasDocument(
            name: name, nodes: [node], createdAt: now, updatedAt: now)
        return CanvasProject(
            id: projectID, workspaceID: workspaceID, name: name,
            documents: [document], selectedDocumentID: document.id,
            viewports: [document.id: .init()], revision: 1,
            createdAt: now, updatedAt: now)
    }

    /// Exclusive-create publish. The move-based atomic write fails if another
    /// writer appeared between the intent and this call.
    private func publishInitial(_ project: CanvasProject, encoded: Data) throws {
        let url = projectURL(id: project.id)
        guard !fileManager.fileExists(atPath: url.path) else {
            throw G09CreativeError.invalidPayload("projectIdentityCollision")
        }
        try ensureDirectory(canvasDirectory)
        try writeAtomically(encoded, to: url)
    }

    public func patch(_ request: G09CanvasPatchRequest, now: Date = Date()) throws -> G09CanvasOperationReceiptDTO {
        guard G09CreativeWire.safeOperationID(request.opID) else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        let sessionDigest = G09CreativeAssetHost.sessionDigest(request.sessionToken)
        if let receipt = try? readReceipt(opID: request.opID) {
            guard receipt.canvasID == request.canvasID else {
                throw G09CreativeError.invalidPayload("receiptCanvasMismatch")
            }
            // A retry of a committed edit returns the known durable outcome.
            // It never re-applies or rewrites the project.
            return G09CanvasOperationReceiptDTO(
                canvasID: receipt.canvasID, documentID: nil,
                previousRevision: receipt.expectedRevision,
                revision: receipt.revision, changedNodeIDs: [],
                changedConnectionIDs: [], undoToken: nil,
                opID: receipt.opID, idempotent: true)
        }
        let fingerprintInput = try G09CreativeWire.encoder().encode(request.patch)
        let intentFingerprint = FloeDigest.sha256Hex(
            Data("\(request.canvasID.uuidString.lowercased())|\(request.expectedRevision)|".utf8)
                + fingerprintInput)
        if let intent = try? readIntent(opID: request.opID) {
            guard intent.canvasID == request.canvasID,
                  intent.fingerprint == intentFingerprint else {
                throw G09CreativeError.invalidPayload("intentMismatch")
            }
            let current = try load(id: request.canvasID)
            let currentData = try canonicalData(for: current.project)
            let currentDigest = FloeDigest.sha256Hex(currentData)
            if current.project.revision == intent.resultRevision,
               currentDigest == intent.resultDigest {
                if intent.committedAt == nil { markIntentCommitted(intent) }
                return G09CanvasOperationReceiptDTO(
                    canvasID: request.canvasID,
                    documentID: current.project.selectedDocumentID,
                    previousRevision: intent.expectedRevision,
                    revision: intent.resultRevision, changedNodeIDs: [],
                    changedConnectionIDs: [], undoToken: nil,
                    opID: request.opID, idempotent: true)
            }
            guard current.project.revision == intent.expectedRevision else {
                throw G09CreativeError.outcomeUnknown
            }
        }
        let loaded = try load(id: request.canvasID)
        guard loaded.warnings.isEmpty || !loaded.warnings.contains("unsafeAssetReference") else {
            throw G09CreativeError.assetReferenceInvalid
        }
        guard request.patch.canvasID == request.canvasID else {
            throw G09CreativeError.invalidPayload("patchCanvasMismatch")
        }
        guard request.patch.expectedRevision == request.expectedRevision else {
            throw G09CreativeError.invalidPayload("patchRevisionMismatch")
        }
        guard request.patch.operations.count <= G09CreativeLimits.batchOperations else {
            throw G09CreativeError.invalidPayload("tooManyOperations")
        }
        try validatePatchAssets(request.patch)
        try validateCADReadOnly(request.patch, project: loaded.project)
        let updated: CanvasProject
        let result: CanvasOperationResult
        do {
            (updated, result) = try CanvasCommandService.applying(
                request.patch, to: loaded.project)
        } catch {
            throw G09CreativeError.map(error)
        }
        let encoded = try canonicalData(for: updated)
        let digest = FloeDigest.sha256Hex(encoded)
        let intent = G09CanvasCommitIntent(
            opID: request.opID, canvasID: request.canvasID,
            fingerprint: intentFingerprint,
            expectedRevision: request.expectedRevision,
            resultRevision: updated.revision, resultDigest: digest)
        try writeIntent(intent)
        try write(updated, expectedRevision: request.expectedRevision,
                  requireAbsent: false, encoded: encoded)
        try faultAfterCommit?()
        markIntentCommitted(intent)
        try? writeReceipt(G09CanvasWriteReceipt(
            opID: request.opID, canvasID: request.canvasID,
            sessionDigest: sessionDigest, expectedRevision: request.expectedRevision,
            revision: updated.revision, committedAt: now))
        return G09CanvasOperationReceiptDTO(
            canvasID: result.canvasID, documentID: result.documentID,
            previousRevision: result.previousRevision, revision: result.revision,
            changedNodeIDs: result.changedNodeIDs,
            changedConnectionIDs: result.changedConnectionIDs,
            undoToken: result.undoToken, opID: request.opID, idempotent: false)
    }

    public func rename(id: UUID, expectedRevision: Int64, name: String,
                       now: Date = Date()) throws -> Loaded {
        guard let clean = G09CreativeWire.sanitizedName(name) else {
            throw G09CreativeError.invalidPayload("invalidName")
        }
        let loaded = try load(id: id)
        guard loaded.project.revision == expectedRevision else {
            throw G09CreativeError.revisionConflict
        }
        guard !loaded.warnings.contains("unsafeAssetReference") else {
            throw G09CreativeError.assetReferenceInvalid
        }
        var project = loaded.project
        project.name = clean
        project.revision += 1
        project.updatedAt = now
        try write(project, expectedRevision: expectedRevision, requireAbsent: false)
        return Loaded(project: project, warnings: loaded.warnings)
    }

    public func delete(id: UUID, expectedRevision: Int64, now: Date = Date()) throws {
        let loaded = try load(id: id)
        guard loaded.project.revision == expectedRevision else {
            throw G09CreativeError.revisionConflict
        }
        try ensureDirectory(deletedDirectory)
        let stamp = ISO8601DateFormatter().string(from: now)
            .replacingOccurrences(of: ":", with: "-")
        let target = deletedDirectory.appendingPathComponent(
            "\(id.uuidString)-\(stamp)-\(UUID().uuidString).json")
        do {
            try fileManager.moveItem(at: projectURL(id: id), to: target)
        } catch {
            throw G09CreativeError.writeFailed
        }
    }

    // MARK: - Durable intents

    func readIntent(opID: String) throws -> G09CanvasCommitIntent {
        guard G09CreativeWire.safeOperationID(opID) else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        let url = intentDirectory.appendingPathComponent("\(opID).json")
        guard let data = try? Data(contentsOf: url),
              let intent = try? G09CreativeWire.decoder().decode(
                G09CanvasCommitIntent.self, from: data) else {
            throw G09CreativeError.canvasNotFound
        }
        return intent
    }

    func writeIntent(_ intent: G09CanvasCommitIntent) throws {
        try ensureDirectory(intentDirectory)
        let data = try G09CreativeWire.encoder().encode(intent)
        try writeAtomically(data, to:
            intentDirectory.appendingPathComponent("\(intent.opID).json"))
    }

    func markIntentCommitted(_ intent: G09CanvasCommitIntent) {
        var committed = intent
        committed.committedAt = Date()
        try? writeIntent(committed)
    }

    func canonicalData(for project: CanvasProject) throws -> Data {
        var canonical = project
        canonical.schemaVersion = CanvasProject.currentSchemaVersion
        return try G09CreativeWire.encoder().encode(canonical)
    }

    // MARK: - Receipts

    public func readReceipt(opID: String) throws -> G09CanvasWriteReceipt {
        guard G09CreativeWire.safeOperationID(opID) else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        let url = receiptsDirectory.appendingPathComponent("\(opID).json")
        guard let data = try? Data(contentsOf: url),
              let receipt = try? G09CreativeWire.decoder().decode(
                G09CanvasWriteReceipt.self, from: data) else {
            throw G09CreativeError.canvasNotFound
        }
        return receipt
    }

    func writeReceipt(_ receipt: G09CanvasWriteReceipt) throws {
        try ensureDirectory(receiptsDirectory)
        let url = receiptsDirectory.appendingPathComponent("\(receipt.opID).json")
        let data = try G09CreativeWire.encoder().encode(receipt)
        try writeAtomically(data, to: url)
        try pruneReceipts()
    }

    private func pruneReceipts() throws {
        let files = try fileManager.contentsOfDirectory(
            at: receiptsDirectory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        guard files.count > G09CreativeLimits.receiptCount else { return }
        let sorted = files.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return lhs < rhs
        }
        for url in sorted.prefix(files.count - G09CreativeLimits.receiptCount) {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - Validation / write

    /// R1 preserves CAD/design metadata but never edits a CAD-bound node.
    /// Connections may still reference it (the read-only node remains part of
    /// the graph); geometric/update/delete/group/fork operations are refused.
    private func validateCADReadOnly(_ patch: CanvasPatch,
                                     project: CanvasProject) throws {
        let nodes = project.documents.flatMap(\.nodes)
        for operation in patch.operations {
            switch operation.kind {
            case .update, .delete, .group, .ungroup, .arrange:
                var ids: [UUID] = []
                if let nodeID = operation.nodeID { ids.append(nodeID) }
                ids.append(contentsOf: operation.nodeIDs ?? [])
                for id in ids {
                    if let node = nodes.first(where: { $0.id == id }),
                       CADCanvasNodePlanner.isNativeCADNode(node) {
                        throw G09CreativeError.invalidPayload("cadReadOnly")
                    }
                }
            case .create, .connect, .disconnect:
                break
            }
        }
    }

    private func validatePatchAssets(_ patch: CanvasPatch) throws {
        for operation in patch.operations {
            if let asset = operation.asset {
                guard G09CreativeAssetHost.safeRelativePath(asset.localRelativePath) else {
                    throw G09CreativeError.assetReferenceInvalid
                }
                if let hash = asset.contentHash, hash.count != 64 {
                    throw G09CreativeError.assetReferenceInvalid
                }
            }
        }
    }

    private func write(_ project: CanvasProject, expectedRevision: Int64?,
                       requireAbsent: Bool, encoded: Data? = nil) throws {
        let url = projectURL(id: project.id)
        if requireAbsent && fileManager.fileExists(atPath: url.path) {
            throw G09CreativeError.writeFailed
        }
        if let expectedRevision {
            let onDisk = try load(id: project.id)
            guard onDisk.project.revision == expectedRevision else {
                throw G09CreativeError.revisionConflict
            }
        } else if !requireAbsent {
            let onDisk = try load(id: project.id)
            guard project.revision > onDisk.project.revision else {
                throw G09CreativeError.revisionConflict
            }
        }
        let data: Data
        do {
            data = try encoded ?? canonicalData(for: project)
        } catch {
            throw G09CreativeError.writeFailed
        }
        guard data.count <= G09CreativeLimits.canvasProjectBytes else {
            throw G09CreativeError.projectTooLarge
        }
        try ensureDirectory(canvasDirectory)
        try writeAtomically(data, to: url)
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try ensureDirectory(directory)
        let temporary = directory.appendingPathComponent(
            ".floe-canvas-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        do {
            try data.write(to: temporary, options: [])
            try fsyncFile(temporary)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
            try fsyncDirectory(directory)
        } catch let typed as G09CreativeError {
            throw typed
        } catch {
            throw G09CreativeError.writeFailed
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw G09CreativeError.storageUnavailable
        }
    }

    private func fsyncFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw G09CreativeError.writeFailed }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw G09CreativeError.writeFailed }
    }

    private func fsyncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw G09CreativeError.writeFailed }
        defer { close(descriptor) }
        // Directory fsync is best-effort on platforms that reject it; the
        // file contents and the rename itself already succeeded.
        _ = fsync(descriptor)
    }
}

extension G09CreativeWire {
    public static func sanitizedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= G09CreativeLimits.nameBytes,
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        return trimmed
    }

    public static func safeOperationID(_ raw: String) -> Bool {
        !raw.isEmpty && raw.utf8.count <= 128 &&
            raw.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "."
            }
    }
}
