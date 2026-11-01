// SPDX-License-Identifier: MPL-2.0
//
// G09-R1 — media project authority.
//
// Reuses the ported original `MediaProjectStore` (schema 1, 8 MiB cap,
// revision CAS, durable undo/redo) and adds only the trusted Android storage
// resolution around it:
//
// * A project's recorded `taskWorkspacePath`, `environmentID`, `ownerID` and
//   `ownerKind` are PROVENANCE, never permission. The media root is always
//   re-derived from the accepted root + an explicit appOwned layer or a real
//   workspace row in the accepted composition.
// * `standalone` (direct UI) projects live under
//   `<acceptedRoot>/FloeAgent/WorkbenchRoot/<projectID>`.
// * `workspace` projects must resolve a real app-private `privateTask`
//   workspace row; an unresolvable or malformed row fails closed.
// * A recorded path that disagrees with the trusted derivation is preserved
//   byte-for-byte and the project becomes read-only until explicitly
//   repaired; it is never normalized by an ordinary save.
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeAndroidWorkbench
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct G09MediaAssetImportReceipt: Codable, Sendable, Equatable {
    public var opID: String
    public var projectID: UUID
    public var asset: MediaAssetReference
    public var expectedRevision: Int64
    public var revision: Int64
    public var canUndo: Bool
    public var canRedo: Bool
    public var sessionDigest: String
    public var committedAt: Date

    public init(opID: String, projectID: UUID, asset: MediaAssetReference,
                expectedRevision: Int64, revision: Int64,
                canUndo: Bool, canRedo: Bool, sessionDigest: String,
                committedAt: Date = Date()) {
        self.opID = opID
        self.projectID = projectID
        self.asset = asset
        self.expectedRevision = expectedRevision
        self.revision = revision
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.sessionDigest = sessionDigest
        self.committedAt = committedAt
    }
}

/// Durable commit intent written BEFORE the project file changes. It records
/// the op identity, request fingerprint and the exact expected post-commit
/// revision/digest so a crash after the atomic project replace but before the
/// receipt can still be classified on restart/retry without re-applying.
public struct G09MediaCommitIntent: Codable, Sendable, Equatable {
    public var opID: String
    public var projectID: UUID
    public var kind: String
    public var fingerprint: String
    public var expectedRevision: Int64
    public var resultRevision: Int64
    public var resultDigest: String?
    public var deleted: Bool
    public var asset: MediaAssetReference?
    public var preparedAt: Date
    public var committedAt: Date?

    public init(opID: String, projectID: UUID, kind: String, fingerprint: String,
                expectedRevision: Int64, resultRevision: Int64,
                resultDigest: String?, deleted: Bool = false,
                asset: MediaAssetReference? = nil,
                preparedAt: Date = Date(), committedAt: Date? = nil) {
        self.opID = opID
        self.projectID = projectID
        self.kind = kind
        self.fingerprint = fingerprint
        self.expectedRevision = expectedRevision
        self.resultRevision = resultRevision
        self.resultDigest = resultDigest
        self.deleted = deleted
        self.asset = asset
        self.preparedAt = preparedAt
        self.committedAt = committedAt
    }
}

public struct G09MediaWriteReceipt: Codable, Sendable, Equatable {
    public var opID: String
    public var projectID: UUID
    public var sessionDigest: String
    public var expectedRevision: Int64
    public var revision: Int64
    public var canUndo: Bool
    public var canRedo: Bool
    public var committedAt: Date

    public init(opID: String, projectID: UUID, sessionDigest: String,
                expectedRevision: Int64, revision: Int64,
                canUndo: Bool = false, canRedo: Bool = false,
                committedAt: Date = Date()) {
        self.opID = opID
        self.projectID = projectID
        self.sessionDigest = sessionDigest
        self.expectedRevision = expectedRevision
        self.revision = revision
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.committedAt = committedAt
    }
}

public struct G09TrustedMediaStorage: Sendable {
    var storage: G09StorageLayerDTO
    var rootURL: URL
    var ownerKind: String
    var ownerID: UUID?
    var recordedPathMismatch: Bool
}

public actor G09MediaProjectHost {
    private let root: RuntimeStorageRoot
    private let workspaceStore: SQLiteWorkspaceStore
    private let conversationStore: SQLiteConversationStore
    private let store: MediaProjectStore
    private let fileManager = FileManager.default

    public init(root: RuntimeStorageRoot, workspaceStore: SQLiteWorkspaceStore,
                conversationStore: SQLiteConversationStore) {
        self.root = root
        self.workspaceStore = workspaceStore
        self.conversationStore = conversationStore
        let directory = root.artifactStoreURL
            .appendingPathComponent("MediaProjects", isDirectory: true)
        self.store = MediaProjectStore(
            directory: directory,
            limits: .init(
                maximumDocumentBytes: G09CreativeLimits.mediaProjectBytes,
                undoDepth: 100))
    }

    public nonisolated var projectDirectoryPath: String {
        root.artifactStoreURL.appendingPathComponent("MediaProjects", isDirectory: true).path
    }

    public nonisolated var mediaRecoveryPath: String {
        root.artifactStoreURL.appendingPathComponent("MediaRecovery", isDirectory: true).path
    }

    private nonisolated var receiptDirectory: URL {
        URL(fileURLWithPath: mediaRecoveryPath, isDirectory: true)
            .appendingPathComponent("Receipts", isDirectory: true)
    }

    private nonisolated var deletedDirectory: URL {
        URL(fileURLWithPath: mediaRecoveryPath, isDirectory: true)
            .appendingPathComponent("Deleted", isDirectory: true)
    }

    private nonisolated var intentDirectory: URL {
        URL(fileURLWithPath: mediaRecoveryPath, isDirectory: true)
            .appendingPathComponent("Intents", isDirectory: true)
    }

    /// Test-only crash seam AFTER the atomic project commit and BEFORE the
    /// committed intent/receipt write. Production leaves this nil.
    internal var faultAfterCommit: (@Sendable () throws -> Void)?

    /// Test-only crash seam AFTER the durable source-create intent and the
    /// copied asset but BEFORE the project file is published.
    internal var faultBeforePublish: (@Sendable () throws -> Void)?

    internal func setFaultAfterCommit(_ closure: (@Sendable () throws -> Void)?) {
        faultAfterCommit = closure
    }

    internal func setFaultBeforePublish(_ closure: (@Sendable () throws -> Void)?) {
        faultBeforePublish = closure
    }

    // MARK: - Library / load

    public func library() throws -> [G09MediaSummaryDTO] {
        let directory = URL(fileURLWithPath: projectDirectoryPath, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        var result: [G09MediaSummaryDTO] = []
        let prefix = "media-project-"
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.lastPathComponent.hasPrefix(prefix) && url.pathExtension.lowercased() == "json" {
            guard result.count < G09CreativeLimits.libraryEntries else { break }
            let stem = url.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: String(stem.dropFirst(prefix.count))) else {
                continue
            }
            do {
                let project = try readProject(at: url, expectedID: id)
                result.append(G09MediaSummaryDTO(
                    id: project.id, name: project.name, kind: project.kind.rawValue,
                    revision: project.revision, updatedAt: project.updatedAt,
                    ownerKind: project.ownerKind, ownerID: project.ownerID,
                    environmentID: project.environmentID,
                    assetCount: project.assets.count,
                    layerCount: project.imageLayers.count,
                    corrupt: false,
                    writable: Self.quicklyWritable(project),
                    provenanceWarning: Self.standaloneProvenanceWarning(
                        project, acceptedRoot: root.path)))
            } catch {
                // Preserve the file. The UI sees a corrupt entry, not an
                // invitation to overwrite or normalize it.
                result.append(G09MediaSummaryDTO(
                    id: id, name: "", kind: "image", revision: 0,
                    updatedAt: Date(timeIntervalSince1970: 0),
                    ownerKind: "", ownerID: nil, environmentID: nil,
                    assetCount: 0, layerCount: 0, corrupt: true,
                    writable: false, provenanceWarning: false))
            }
        }
        return result.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public struct Loaded: Sendable {
        public var project: MediaProject
        public var storage: G09TrustedMediaStorage
        public var writable: Bool
        public var warnings: [String]
    }

    public func load(id: UUID, requested: G09StorageLayerDTO?,
                     origin: G09CreativeOriginDTO? = nil) async throws -> Loaded {
        let decoded: MediaProject?
        do {
            decoded = try await store.loadProject(id: id)
        } catch let error as FloeError {
            if case .validationFailed(let detail) = error,
               detail.contains("exceeds") {
                throw G09CreativeError.projectTooLarge
            }
            throw G09CreativeError.corruptProject
        } catch {
            throw G09CreativeError.corruptProject
        }
        guard let project = decoded else {
            throw G09CreativeError.mediaProjectNotFound
        }
        guard project.id == id else { throw G09CreativeError.corruptProject }
        if origin == nil,
           ["files", "chat", "canvas"].contains(project.ownerKind) {
            // A recorded task/chat/canvas owner is untrusted metadata. It can
            // only be opened when the caller presents the REAL origin context
            // from the existing file/workspace route.
            throw G09CreativeError.invalidOrigin("originRequiredForOwner")
        }
        _ = try await validateOrigin(origin, projectID: id, existing: project)
        let storage = try await resolveStorage(
            ownerKind: project.ownerKind, ownerID: project.ownerID,
            requested: requested, projectID: id,
            recordedPath: project.taskWorkspacePath)
        var warnings = project.recoveryWarnings
        var blocking: [String] = []
        if project.schemaVersion > MediaProject.currentSchemaVersion {
            warnings.append("newerSchema")
            blocking.append("newerSchema")
        }
        if storage.recordedPathMismatch {
            warnings.append("storageProvenanceMismatch")
            blocking.append("storageProvenanceMismatch")
        }
        return Loaded(
            project: project, storage: storage,
            writable: blocking.isEmpty, warnings: warnings + blocking)
    }

    // MARK: - Create

    public func create(name: String, kind: MediaProjectKind, width: Int, height: Int,
                       frameRate: Double?, storage requested: G09StorageLayerDTO,
                       origin: G09CreativeOriginDTO,
                       now: Date = Date()) async throws -> Loaded {
        guard let clean = G09CreativeWire.sanitizedName(name) else {
            throw G09CreativeError.invalidPayload("invalidName")
        }
        guard (2...8192).contains(width), (2...8192).contains(height) else {
            throw G09CreativeError.invalidPayload("invalidCanvasSize")
        }
        if let frameRate {
            guard frameRate.isFinite, frameRate > 0, frameRate <= 240 else {
                throw G09CreativeError.invalidPayload("invalidFrameRate")
            }
        }
        let projectID = UUID()
        let normalized = try await validateOrigin(
            origin, projectID: projectID, existing: nil) ?? origin
        let storage = try await resolveStorage(
            ownerKind: normalized.kind.rawValue, ownerID: normalized.ownerID,
            requested: requested, projectID: projectID, recordedPath: nil)
        var project = MediaProject(
            id: projectID, kind: kind, name: clean,
            createdAt: now, updatedAt: now, revision: 0,
            canvas: MediaCanvas(width: width, height: height, frameRate: frameRate),
            ownerKind: normalized.kind.rawValue,
            ownerID: normalized.ownerID,
            environmentID: normalized.environmentID,
            taskWorkspacePath: storage.rootURL.path)
        project.recoveryWarnings = []
        do {
            _ = try await store.save(project, expectedRevision: nil)
        } catch {
            throw G09CreativeError.map(error)
        }
        return Loaded(project: project, storage: storage,
                      writable: true, warnings: [])
    }

    // MARK: - Atomic source-import creation

    /// Creates ONE non-empty media project from a staged source file.
    ///
    /// Ordering is the whole point: the asset is copied and the complete
    /// draft (asset + initial image layer or video clip) is assembled BEFORE
    /// any project file appears; the durable pre-commit intent records the
    /// exact expected post-commit revision/digest; only then does the project
    /// file get written. A failure or cancellation before that point publishes
    /// nothing, and a retry with the same opID either completes the identical
    /// intent or reports the committed project instead of creating a second
    /// one.
    public func createFromSource(
        _ request: G09MediaSourceCreateRequest,
        staging: URL?,
        projectID: UUID,
        now: Date = Date()
    ) async throws -> Loaded {
        guard G09CreativeWire.safeOperationID(request.opID) else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        guard let cleanName = G09CreativeWire.sanitizedName(request.name) else {
            throw G09CreativeError.invalidPayload("invalidName")
        }
        guard let kind = MediaProjectKind(rawValue: request.kind) else {
            throw G09CreativeError.invalidPayload("invalidProjectKind")
        }
        guard (2...8192).contains(request.width), (2...8192).contains(request.height) else {
            throw G09CreativeError.invalidPayload("invalidSourceDimensions")
        }
        let derivedKind = Self.mediaAssetKind(
            fileName: request.fileName, mimeType: request.mimeType)
        let declaredSource = request.sourceKind?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let declaredSource, !declaredSource.isEmpty {
            guard declaredSource == "image" || declaredSource == "video" else {
                throw G09CreativeError.invalidPayload("invalidSourceKind")
            }
            guard declaredSource == kind.rawValue else {
                throw G09CreativeError.invalidPayload("sourceKindMismatch")
            }
        }
        guard derivedKind.rawValue == kind.rawValue else {
            throw G09CreativeError.invalidPayload("sourceKindMismatch")
        }
        let duration: Double?
        switch kind {
        case .image:
            duration = nil
        case .video:
            guard let value = request.durationSeconds, value.isFinite,
                  value > 0, value <= 86_400 else {
                throw G09CreativeError.invalidPayload("invalidSourceDuration")
            }
            duration = value
        }
        if let frameRate = request.frameRate {
            guard frameRate.isFinite, frameRate >= 1, frameRate <= 240 else {
                throw G09CreativeError.invalidPayload("invalidSourceFrameRate")
            }
        }
        if let rotation = request.rotationDegrees {
            let allowed: [Double] = [0, 90, 180, 270, -90, -180, -270]
            guard allowed.contains(rotation) else {
                throw G09CreativeError.invalidPayload("invalidSourceRotation")
            }
        }
        if let environment = request.origin?.environmentID {
            guard !environment.isEmpty, environment.utf8.count <= 128,
                  !environment.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw G09CreativeError.invalidOrigin("invalidEnvironmentID")
            }
        }
        let fingerprint = fingerprint("create", projectID: projectID,
                                      expectedRevision: 0,
                                      extra: [
                                        request.kind, cleanName,
                                        request.fileName, request.mimeType ?? "",
                                        request.sha256.lowercased(),
                                        String(request.byteCount),
                                        request.sourceKind ?? "",
                                        String(request.width), String(request.height),
                                        duration.map { String($0) } ?? "",
                                        request.rotationDegrees.map { String($0) } ?? "",
                                        Self.storageFingerprint(request.storage),
                                        Self.originFingerprint(request.origin),
                                      ].joined(separator: "|"))

        let projectURL = URL(fileURLWithPath: projectDirectoryPath, isDirectory: true)
            .appendingPathComponent(MediaProjectStore.projectFileName(id: projectID))
        var preparedAt = now
        var recordedAsset: MediaAssetReference?
        if let intent = try? readIntent(request.opID) {
            guard intent.kind == "create",
                  intent.projectID == projectID,
                  intent.fingerprint == fingerprint else {
                throw G09CreativeError.invalidPayload("intentMismatch")
            }
            preparedAt = intent.preparedAt
            recordedAsset = intent.asset
            if fileManager.fileExists(atPath: projectURL.path) {
                let current = try await loadProjectForReplay(id: projectID)
                let digest = canonicalDigest(current)
                guard current.revision == intent.resultRevision,
                      digest == intent.resultDigest else {
                    throw G09CreativeError.outcomeUnknown
                }
                let storage = try await resolveStorage(
                    ownerKind: current.ownerKind, ownerID: current.ownerID,
                    requested: request.storage, projectID: projectID,
                    recordedPath: current.taskWorkspacePath)
                if intent.committedAt == nil { markIntentCommitted(intent) }
                try? writeReceipt(G09MediaWriteReceipt(
                    opID: request.opID, projectID: projectID,
                    sessionDigest: G09CreativeAssetHost.sessionDigest(request.sessionToken),
                    expectedRevision: 0, revision: current.revision,
                    canUndo: MediaTransactions.canUndo(current),
                    canRedo: MediaTransactions.canRedo(current)))
                return Loaded(project: current, storage: storage,
                              writable: true, warnings: current.recoveryWarnings)
            }
        } else if fileManager.fileExists(atPath: projectURL.path) {
            throw G09CreativeError.invalidPayload("projectIdentityCollision")
        }

        let origin = try await validateOrigin(
            request.origin ?? G09CreativeOriginDTO(kind: .standalone),
            projectID: projectID, existing: nil) ?? G09CreativeOriginDTO(kind: .standalone)
        let storage = try await resolveStorage(
            ownerKind: origin.kind.rawValue, ownerID: origin.ownerID,
            requested: request.storage, projectID: projectID, recordedPath: nil)
        let displayName = G09CreativeAssetHost.safeDisplayName(request.fileName)
        let assetID = G09SourceCreateIdentity.assetID(
            domain: "media", opID: request.opID)
        let relative = "Workbench/Assets/\(assetID.uuidString)-\(displayName)"
        guard let target = mediaURL(rootURL: storage.rootURL, relativePath: relative) else {
            throw G09CreativeError.assetStagingInvalid
        }
        let asset: MediaAssetReference
        var copiedTarget: URL?
        if let recordedAsset, recordedAsset.id == assetID,
           fileManager.fileExists(atPath: target.path),
           let digest = try? FloeDigest.sha256Hex(ofFileAt: target),
           digest.caseInsensitiveCompare(request.sha256) == .orderedSame {
            asset = recordedAsset
        } else {
            guard let staging else { throw G09CreativeError.assetStagingUnavailable }
            let digest = try G09CreativeAssetHost.verifiedStagingDigest(
                staging, byteCount: request.byteCount, sha256: request.sha256)
            let metadata = MediaAssetMetadata(
                width: request.width, height: request.height,
                durationSeconds: duration,
                frameRate: request.frameRate,
                rotationDegrees: request.rotationDegrees)
            asset = MediaAssetReference(
                id: assetID, kind: derivedKind, relativePath: relative,
                originalName: displayName, byteCount: request.byteCount,
                contentHash: digest, metadata: metadata)
            try? fileManager.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: target.path) {
                guard let existingDigest = try? FloeDigest.sha256Hex(ofFileAt: target),
                      existingDigest.caseInsensitiveCompare(digest) == .orderedSame else {
                    throw G09CreativeError.assetDigestMismatch
                }
            } else {
                try copyExclusive(from: staging, to: target)
                copiedTarget = target
            }
        }
        var project: MediaProject
        do {
            project = MediaProject(
                id: projectID, kind: kind, name: cleanName,
                createdAt: preparedAt, updatedAt: preparedAt, revision: 0,
                canvas: MediaCanvas(
                    width: request.width, height: request.height,
                    frameRate: kind == .video ? request.frameRate : nil),
                ownerKind: origin.kind.rawValue, ownerID: origin.ownerID,
                environmentID: origin.environmentID,
                taskWorkspacePath: storage.rootURL.path)
            try MediaTransactions.apply(.addAsset(asset), to: &project)
            if kind == .image {
                let layer = ImageLayer(
                    id: G09SourceCreateIdentity.childID(
                        domain: "media", opID: request.opID, tag: "layer"),
                    kind: .image, name: displayName, assetID: asset.id)
                try MediaTransactions.apply(.addImageLayer(layer), to: &project)
            } else {
                let clip = VideoClip(
                    id: G09SourceCreateIdentity.childID(
                        domain: "media", opID: request.opID, tag: "clip"),
                    assetID: asset.id, trimStart: 0, trimEnd: duration ?? 0)
                try MediaTransactions.apply(.appendClip(clip), to: &project)
            }
        } catch {
            if let copiedTarget { try? fileManager.removeItem(at: copiedTarget) }
            throw G09CreativeError.map(error)
        }
        // MediaTransactions stamps a wall-clock updatedAt; pin it to the
        // operation's prepared time so a pre-publish retry rebuilds exactly
        // the digest the recorded intent expects.
        project.updatedAt = preparedAt
        let digest = canonicalDigest(project)
        let intent = G09MediaCommitIntent(
            opID: request.opID, projectID: projectID, kind: "create",
            fingerprint: fingerprint, expectedRevision: 0,
            resultRevision: project.revision, resultDigest: digest,
            asset: asset, preparedAt: preparedAt, committedAt: nil)
        try writeIntent(intent)
        var committed = false
        do {
            try faultBeforePublish?()
            if fileManager.fileExists(atPath: projectURL.path) {
                throw G09CreativeError.invalidPayload("projectIdentityCollision")
            }
            _ = try await store.save(project, expectedRevision: nil)
            committed = true
            try faultAfterCommit?()
        } catch {
            if !committed, let copiedTarget {
                try? fileManager.removeItem(at: copiedTarget)
            }
            throw G09CreativeError.map(error)
        }
        markIntentCommitted(intent)
        try? writeReceipt(G09MediaWriteReceipt(
            opID: request.opID, projectID: projectID,
            sessionDigest: G09CreativeAssetHost.sessionDigest(request.sessionToken),
            expectedRevision: 0, revision: project.revision,
            canUndo: MediaTransactions.canUndo(project),
            canRedo: MediaTransactions.canRedo(project)))
        return Loaded(project: project, storage: storage,
                      writable: true, warnings: [])
    }

    private func loadProjectForReplay(id: UUID) async throws -> MediaProject {
        do {
            guard let project = try await store.loadProject(id: id) else {
                throw G09CreativeError.mediaProjectNotFound
            }
            return project
        } catch let typed as G09CreativeError {
            throw typed
        } catch {
            throw G09CreativeError.corruptProject
        }
    }

    private nonisolated static func storageFingerprint(_ storage: G09StorageLayerDTO) -> String {
        switch storage.kind {
        case .appOwned:
            return "appOwned"
        case .workspace:
            return "workspace:\(storage.workspaceID?.uuidString.lowercased() ?? "")"
        }
    }

    private nonisolated static func originFingerprint(_ origin: G09CreativeOriginDTO?) -> String {
        guard let origin else { return "standalone" }
        return [
            origin.kind.rawValue,
            origin.ownerID?.uuidString.lowercased() ?? "",
            origin.environmentID ?? "",
        ].joined(separator: ":")
    }

    // MARK: - Mutations

    public func apply(_ request: G09MediaApplyRequest) async throws -> Loaded {
        try await applyShared(
            projectID: request.projectID,
            expectedRevision: request.expectedRevision,
            sessionToken: request.sessionToken,
            storage: request.storage, origin: request.origin,
            opID: request.opID,
            commands: request.commands.map { $0.sharedCommand() })
    }

    /// G09-R2 additive entry point used by the typed video command decoder.
    ///
    /// It runs the SAME durable transaction as `apply(_:)`: one revision CAS,
    /// one undo step and one receipt per command batch. Only the command
    /// representation differs (already-decoded `MediaEditCommand` values from
    /// `G09R2VideoCommandWire.sharedCommand()`); no second edit engine, store
    /// or receipt format exists.
    public func applyShared(
        projectID: UUID,
        expectedRevision: Int64,
        sessionToken: String,
        storage: G09StorageLayerDTO?,
        origin: G09CreativeOriginDTO?,
        opID: String,
        commands: [MediaEditCommand]
    ) async throws -> Loaded {
        guard G09CreativeWire.safeOperationID(opID) else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        let commandData = try G09CreativeWire.encoder().encode(commands)
        let intentFingerprint = fingerprint(
            "apply", projectID: projectID,
            expectedRevision: expectedRevision,
            extra: FloeDigest.sha256Hex(commandData))
        if let intent = try? readIntent(opID) {
            guard intent.projectID == projectID,
                  intent.kind == "apply",
                  intent.fingerprint == intentFingerprint else {
                throw G09CreativeError.invalidPayload("intentMismatch")
            }
            let current = try await load(
                id: projectID, requested: storage, origin: origin)
            if let replayed = try replayCommittedIntent(intent, current: current) {
                return replayed
            }
        }
        if let receipt = try? readReceipt(opID) {
            guard receipt.projectID == projectID else {
                throw G09CreativeError.invalidPayload("receiptProjectMismatch")
            }
            // Known committed outcome: never re-apply. Return the CURRENT
            // durable state so a later edit is also represented truthfully.
            return try await load(id: projectID, requested: storage, origin: origin)
        }
        let loaded = try await load(
            id: projectID, requested: storage, origin: origin)
        _ = try await validateOrigin(origin, projectID: projectID,
                                     existing: loaded.project)
        guard loaded.writable else { throw G09CreativeError.provenanceMismatch }
        guard loaded.project.revision == expectedRevision else {
            throw G09CreativeError.revisionConflict
        }
        guard !commands.isEmpty,
              commands.count <= G09CreativeLimits.mediaCommands else {
            throw G09CreativeError.invalidPayload("invalidCommandCount")
        }
        var project = loaded.project
        do {
            try MediaTransactions.apply(commands, to: &project)
        } catch {
            throw G09CreativeError.map(error)
        }
        let resultDigest = canonicalDigest(project)
        let intent = G09MediaCommitIntent(
            opID: opID, projectID: project.id, kind: "apply",
            fingerprint: intentFingerprint,
            expectedRevision: expectedRevision,
            resultRevision: project.revision,
            resultDigest: resultDigest)
        try writeIntent(intent)
        do {
            _ = try await store.save(project, expectedRevision: expectedRevision)
        } catch {
            throw G09CreativeError.map(error)
        }
        try faultAfterCommit?()
        markIntentCommitted(intent)
        try? writeReceipt(G09MediaWriteReceipt(
            opID: opID, projectID: project.id,
            sessionDigest: G09CreativeAssetHost.sessionDigest(sessionToken),
            expectedRevision: expectedRevision,
            revision: project.revision,
            canUndo: MediaTransactions.canUndo(project),
            canRedo: MediaTransactions.canRedo(project)))
        return Loaded(project: project, storage: loaded.storage,
                      writable: true, warnings: loaded.warnings)
    }

    /// Persists the EXACT project value produced by one authorized proposal
    /// apply. The command sequence is deliberately NOT replayed here: applying
    /// it again would mint new UUID/Date identities for commands such as
    /// add_image_layer/add_caption and would not persist the project the user
    /// authorized. The caller (the media.project host) has already bound the
    /// exact proposal and applied it through the portable gate; this method
    /// owns only the durable intent/receipt and the real CAS store write.
    public func commitApplied(
        _ project: MediaProject,
        expectedRevision: Int64,
        sessionToken: String,
        storage: G09StorageLayerDTO,
        origin: G09CreativeOriginDTO?,
        opID: String
    ) async throws -> Loaded {
        guard G09CreativeWire.safeOperationID(opID) else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        guard let resultDigest = canonicalDigest(project) else {
            throw G09CreativeError.corruptProject
        }
        let intentFingerprint = fingerprint(
            "apply-exact", projectID: project.id,
            expectedRevision: expectedRevision, extra: resultDigest)
        if let receipt = try? readReceipt(opID) {
            guard receipt.projectID == project.id,
                  receipt.expectedRevision == expectedRevision,
                  receipt.revision == project.revision else {
                throw G09CreativeError.invalidPayload("receiptProjectMismatch")
            }
            let current = try await load(
                id: project.id, requested: storage, origin: origin)
            guard canonicalDigest(current.project) == resultDigest else {
                throw G09CreativeError.outcomeUnknown
            }
            return current
        }
        if let intent = try? readIntent(opID) {
            guard intent.projectID == project.id,
                  intent.kind == "apply-exact",
                  intent.fingerprint == intentFingerprint else {
                throw G09CreativeError.invalidPayload("intentMismatch")
            }
            let current = try await load(
                id: project.id, requested: storage, origin: origin)
            if let replayed = try replayCommittedIntent(intent, current: current) {
                return replayed
            }
        }
        let loaded = try await load(
            id: project.id, requested: storage, origin: origin)
        _ = try await validateOrigin(origin, projectID: project.id,
                                     existing: loaded.project)
        guard loaded.writable else { throw G09CreativeError.provenanceMismatch }
        guard loaded.project.revision == expectedRevision else {
            throw G09CreativeError.revisionConflict
        }
        guard project.revision == expectedRevision + 1 else {
            if project.revision == expectedRevision {
                // The authorized command sequence was a no-op (for example a
                // repeated identical slider commit): no durable receipt is
                // written and the existing project is returned unchanged.
                return loaded
            }
            throw G09CreativeError.invalidPayload("appliedRevisionMismatch")
        }
        let intent = G09MediaCommitIntent(
            opID: opID, projectID: project.id, kind: "apply-exact",
            fingerprint: intentFingerprint,
            expectedRevision: expectedRevision,
            resultRevision: project.revision,
            resultDigest: resultDigest)
        try writeIntent(intent)
        do {
            _ = try await store.save(project, expectedRevision: expectedRevision)
        } catch {
            throw G09CreativeError.map(error)
        }
        try faultAfterCommit?()
        markIntentCommitted(intent)
        try? writeReceipt(G09MediaWriteReceipt(
            opID: opID, projectID: project.id,
            sessionDigest: G09CreativeAssetHost.sessionDigest(sessionToken),
            expectedRevision: expectedRevision,
            revision: project.revision,
            canUndo: MediaTransactions.canUndo(project),
            canRedo: MediaTransactions.canRedo(project)))
        return Loaded(project: project, storage: loaded.storage,
                      writable: true, warnings: loaded.warnings)
    }

    public func undo(_ request: G09MediaUndoRedoRequest, now: Date = Date()) async throws -> Loaded {
        try await navigate(request, undo: true)
    }

    public func redo(_ request: G09MediaUndoRedoRequest, now: Date = Date()) async throws -> Loaded {
        try await navigate(request, undo: false)
    }

    private func navigate(_ request: G09MediaUndoRedoRequest,
                          undo: Bool) async throws -> Loaded {
        guard G09CreativeWire.safeOperationID(request.opID) else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        let kind = undo ? "undo" : "redo"
        let intentFingerprint = fingerprint(
            kind, projectID: request.projectID,
            expectedRevision: request.expectedRevision, extra: kind)
        if let intent = try? readIntent(request.opID) {
            guard intent.projectID == request.projectID,
                  intent.kind == kind,
                  intent.fingerprint == intentFingerprint else {
                throw G09CreativeError.invalidPayload("intentMismatch")
            }
            let current = try await load(
                id: request.projectID, requested: request.storage,
                origin: request.origin)
            if let replayed = try replayCommittedIntent(intent, current: current) {
                return replayed
            }
        }
        if let receipt = try? readReceipt(request.opID) {
            guard receipt.projectID == request.projectID else {
                throw G09CreativeError.invalidPayload("receiptProjectMismatch")
            }
            return try await load(id: request.projectID, requested: request.storage,
                                  origin: request.origin)
        }
        let loaded = try await load(
            id: request.projectID, requested: request.storage,
            origin: request.origin)
        _ = try await validateOrigin(request.origin, projectID: request.projectID,
                                     existing: loaded.project)
        guard loaded.writable else { throw G09CreativeError.provenanceMismatch }
        guard loaded.project.revision == request.expectedRevision else {
            throw G09CreativeError.revisionConflict
        }
        var project = loaded.project
        let changed = undo
            ? MediaTransactions.undo(&project)
            : MediaTransactions.redo(&project)
        guard changed else {
            throw G09CreativeError.invalidPayload(undo ? "nothingToUndo" : "nothingToRedo")
        }
        let resultDigest = canonicalDigest(project)
        let intent = G09MediaCommitIntent(
            opID: request.opID, projectID: project.id, kind: kind,
            fingerprint: intentFingerprint,
            expectedRevision: request.expectedRevision,
            resultRevision: project.revision,
            resultDigest: resultDigest)
        try writeIntent(intent)
        do {
            _ = try await store.save(project, expectedRevision: request.expectedRevision)
        } catch {
            throw G09CreativeError.map(error)
        }
        try faultAfterCommit?()
        markIntentCommitted(intent)
        try? writeReceipt(G09MediaWriteReceipt(
            opID: request.opID, projectID: project.id,
            sessionDigest: G09CreativeAssetHost.sessionDigest(request.sessionToken),
            expectedRevision: request.expectedRevision,
            revision: project.revision,
            canUndo: MediaTransactions.canUndo(project),
            canRedo: MediaTransactions.canRedo(project)))
        return Loaded(project: project, storage: loaded.storage,
                      writable: true, warnings: loaded.warnings)
    }

    public func rename(_ request: G09MediaRenameRequest, now: Date = Date()) async throws -> Loaded {
        if let opID = request.opID, !G09CreativeWire.safeOperationID(opID) {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        guard let clean = G09CreativeWire.sanitizedName(request.name) else {
            throw G09CreativeError.invalidPayload("invalidName")
        }
        let opID = request.opID
        let intentFingerprint = opID.map { _ in
            fingerprint("rename", projectID: request.projectID,
                        expectedRevision: request.expectedRevision, extra: clean)
        }
        if let opID, let intentFingerprint, let intent = try? readIntent(opID) {
            guard intent.projectID == request.projectID,
                  intent.kind == "rename",
                  intent.fingerprint == intentFingerprint else {
                throw G09CreativeError.invalidPayload("intentMismatch")
            }
            let current = try await load(
                id: request.projectID, requested: request.storage,
                origin: request.origin)
            if let replayed = try replayCommittedIntent(intent, current: current) {
                return replayed
            }
        }
        let loaded = try await load(
            id: request.projectID, requested: request.storage,
            origin: request.origin)
        _ = try await validateOrigin(request.origin, projectID: request.projectID,
                                     existing: loaded.project)
        guard loaded.writable else { throw G09CreativeError.provenanceMismatch }
        guard loaded.project.revision == request.expectedRevision else {
            throw G09CreativeError.revisionConflict
        }
        var project = loaded.project
        project.name = clean
        project.revision += 1
        project.updatedAt = now
        if let opID, G09CreativeWire.safeOperationID(opID), let intentFingerprint {
            let intent = G09MediaCommitIntent(
                opID: opID, projectID: project.id, kind: "rename",
                fingerprint: intentFingerprint,
                expectedRevision: request.expectedRevision,
                resultRevision: project.revision,
                resultDigest: canonicalDigest(project))
            try writeIntent(intent)
            do {
                _ = try await store.save(project, expectedRevision: request.expectedRevision)
            } catch {
                throw G09CreativeError.map(error)
            }
            try faultAfterCommit?()
            markIntentCommitted(intent)
            try? writeReceipt(G09MediaWriteReceipt(
                opID: opID, projectID: project.id,
                sessionDigest: G09CreativeAssetHost.sessionDigest(request.sessionToken),
                expectedRevision: request.expectedRevision,
                revision: project.revision,
                canUndo: MediaTransactions.canUndo(project),
                canRedo: MediaTransactions.canRedo(project),
                committedAt: now))
        } else {
            do {
                _ = try await store.save(project, expectedRevision: request.expectedRevision)
            } catch {
                throw G09CreativeError.map(error)
            }
        }
        return Loaded(project: project, storage: loaded.storage,
                      writable: true, warnings: loaded.warnings)
    }

    public func delete(_ request: G09MediaDeleteRequest, now: Date = Date()) async throws {
        if let opID = request.opID, !G09CreativeWire.safeOperationID(opID) {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        let opID = request.opID
        let intentFingerprint = opID.map { _ in
            fingerprint("delete", projectID: request.projectID,
                        expectedRevision: request.expectedRevision, extra: "delete")
        }
        let intent = opID.flatMap { value in
            intentFingerprint.map { fp in
                G09MediaCommitIntent(
                    opID: value, projectID: request.projectID, kind: "delete",
                    fingerprint: fp, expectedRevision: request.expectedRevision,
                    resultRevision: request.expectedRevision, resultDigest: nil,
                    deleted: true, preparedAt: now)
            }
        }
        if let intent, let existing = try? readIntent(intent.opID) {
            guard existing.projectID == request.projectID,
                  existing.kind == "delete",
                  existing.fingerprint == intent.fingerprint else {
                throw G09CreativeError.invalidPayload("intentMismatch")
            }
            let source = URL(fileURLWithPath: projectDirectoryPath, isDirectory: true)
                .appendingPathComponent(MediaProjectStore.projectFileName(id: request.projectID))
            if !fileManager.fileExists(atPath: source.path) {
                markIntentCommitted(existing)
                return
            }
            let current = try await load(
                id: request.projectID, requested: request.storage,
                origin: request.origin)
            guard current.project.revision == request.expectedRevision else {
                throw G09CreativeError.outcomeUnknown
            }
        }
        let loaded = try await load(
            id: request.projectID, requested: request.storage,
            origin: request.origin)
        _ = try await validateOrigin(request.origin, projectID: request.projectID,
                                     existing: loaded.project)
        guard loaded.writable else { throw G09CreativeError.provenanceMismatch }
        guard loaded.project.revision == request.expectedRevision else {
            throw G09CreativeError.revisionConflict
        }
        if let intent { try writeIntent(intent) }
        try? fileManager.createDirectory(at: deletedDirectory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: now)
            .replacingOccurrences(of: ":", with: "-")
        let source = URL(fileURLWithPath: projectDirectoryPath, isDirectory: true)
            .appendingPathComponent(MediaProjectStore.projectFileName(id: request.projectID))
        let target = deletedDirectory.appendingPathComponent(
            "media-project-\(request.projectID.uuidString.lowercased())-\(stamp)-\(UUID().uuidString).json")
        do {
            try fileManager.moveItem(at: source, to: target)
        } catch {
            throw G09CreativeError.writeFailed
        }
        try faultAfterCommit?()
        if let intent { markIntentCommitted(intent) }
        if let opID, G09CreativeWire.safeOperationID(opID) {
            try? writeReceipt(G09MediaWriteReceipt(
                opID: opID, projectID: request.projectID,
                sessionDigest: G09CreativeAssetHost.sessionDigest(request.sessionToken),
                expectedRevision: request.expectedRevision,
                revision: request.expectedRevision,
                canUndo: false, canRedo: false, committedAt: now))
        }
    }

    // MARK: - Assets

    public func importAsset(_ request: G09MediaAssetImportRequest,
                            staging: URL) async throws -> G09MediaAssetReceiptDTO {
        try await importAssetShared(
            request, staging: staging,
            maximumBytes: Int64(G09CreativeLimits.assetBytes))
    }

    /// G09-R2 additive large-asset import: the SAME durable intent/CAS/receipt
    /// path as `importAsset`, with the per-kind R2 ceiling supplied by the
    /// native large-import service. R1 keeps its unchanged 64 MiB cap.
    public func importAssetLarge(_ request: G09MediaAssetImportRequest,
                                 staging: URL,
                                 maximumBytes: Int64) async throws
        -> G09MediaAssetReceiptDTO {
        guard maximumBytes > 0 else { throw G09CreativeError.assetTooLarge }
        return try await importAssetShared(
            request, staging: staging, maximumBytes: maximumBytes)
    }

    private func importAssetShared(_ request: G09MediaAssetImportRequest,
                                   staging: URL,
                                   maximumBytes: Int64) async throws
        -> G09MediaAssetReceiptDTO {
        guard G09CreativeWire.safeOperationID(request.opID) else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        let intentFingerprint = fingerprint(
            "import", projectID: request.projectID,
            expectedRevision: request.expectedRevision,
            extra: "\(request.sha256)|\(request.fileName)|\(request.byteCount)")
        var preparedAsset: MediaAssetReference?
        if let intent = try? readIntent(request.opID) {
            guard intent.projectID == request.projectID,
                  intent.kind == "import",
                  intent.fingerprint == intentFingerprint else {
                throw G09CreativeError.invalidPayload("intentMismatch")
            }
            let current = try await load(
                id: request.projectID, requested: request.storage,
                origin: request.origin)
            if let replayed = try replayCommittedIntent(intent, current: current),
               let asset = intent.asset {
                return G09MediaAssetReceiptDTO(
                    projectID: current.project.id, asset: asset,
                    revision: current.project.revision,
                    canUndo: MediaTransactions.canUndo(current.project),
                    canRedo: MediaTransactions.canRedo(current.project),
                    opID: request.opID, idempotent: true)
            }
            preparedAsset = intent.asset
        }
        if let receipt = try? readAssetImportReceipt(request.opID) {
            guard receipt.projectID == request.projectID else {
                throw G09CreativeError.invalidPayload("receiptProjectMismatch")
            }
            return G09MediaAssetReceiptDTO(
                projectID: receipt.projectID, asset: receipt.asset,
                revision: receipt.revision, canUndo: receipt.canUndo,
                canRedo: receipt.canRedo, opID: receipt.opID, idempotent: true)
        }
        let loaded = try await load(
            id: request.projectID, requested: request.storage,
            origin: request.origin)
        _ = try await validateOrigin(request.origin, projectID: request.projectID,
                                     existing: loaded.project)
        guard loaded.writable else { throw G09CreativeError.provenanceMismatch }
        guard loaded.project.revision == request.expectedRevision else {
            throw G09CreativeError.revisionConflict
        }
        guard request.byteCount > 0 else { throw G09CreativeError.assetEmpty }
        guard request.byteCount <= maximumBytes else {
            throw G09CreativeError.assetTooLarge
        }
        guard G09CreativeAssetHost.validDigest(request.sha256),
              G09CreativeAssetHost.safeDisplayName(request.fileName).isEmpty == false else {
            throw G09CreativeError.assetStagingInvalid
        }
        guard let size = try? staging.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(size) == request.byteCount,
              let digest = try? FloeDigest.sha256Hex(ofFileAt: staging),
              digest.caseInsensitiveCompare(request.sha256) == .orderedSame else {
            throw G09CreativeError.assetDigestMismatch
        }
        let displayName = G09CreativeAssetHost.safeDisplayName(request.fileName)
        let assetID = preparedAsset?.id ?? UUID()
        let relative = preparedAsset?.relativePath
            ?? "Workbench/Assets/\(assetID.uuidString)-\(displayName)"
        guard let target = mediaURL(rootURL: loaded.storage.rootURL, relativePath: relative) else {
            throw G09CreativeError.assetStagingInvalid
        }
        let reference = MediaAssetReference(
            id: assetID,
            kind: Self.mediaAssetKind(fileName: displayName, mimeType: request.mimeType),
            relativePath: relative,
            originalName: displayName,
            byteCount: request.byteCount,
            contentHash: digest,
            metadata: nil)
        var project = loaded.project
        do {
            try MediaTransactions.apply(.addAsset(reference), to: &project)
        } catch {
            throw G09CreativeError.map(error)
        }
        let intent = G09MediaCommitIntent(
            opID: request.opID, projectID: project.id, kind: "import",
            fingerprint: intentFingerprint,
            expectedRevision: request.expectedRevision,
            resultRevision: project.revision,
            resultDigest: canonicalDigest(project),
            asset: reference)
        try writeIntent(intent)
        try? fileManager.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var committed = false
        do {
            if fileManager.fileExists(atPath: target.path) {
                guard let existingDigest = try? FloeDigest.sha256Hex(ofFileAt: target),
                      existingDigest.caseInsensitiveCompare(digest) == .orderedSame else {
                    throw G09CreativeError.assetDigestMismatch
                }
            } else {
                try copyExclusive(from: staging, to: target)
            }
            _ = try await store.save(project, expectedRevision: request.expectedRevision)
            committed = true
            try faultAfterCommit?()
        } catch {
            if !committed { try? fileManager.removeItem(at: target) }
            throw G09CreativeError.map(error)
        }
        markIntentCommitted(intent)
        let canUndo = MediaTransactions.canUndo(project)
        let canRedo = MediaTransactions.canRedo(project)
        try? writeAssetImportReceipt(G09MediaAssetImportReceipt(
            opID: request.opID, projectID: project.id, asset: reference,
            expectedRevision: request.expectedRevision,
            revision: project.revision, canUndo: canUndo, canRedo: canRedo,
            sessionDigest: G09CreativeAssetHost.sessionDigest(request.sessionToken)))
        return G09MediaAssetReceiptDTO(
            projectID: project.id, asset: reference, revision: project.revision,
            canUndo: canUndo, canRedo: canRedo,
            opID: request.opID, idempotent: false)
    }

    public func relink(_ request: G09MediaRelinkRequest) async throws -> Loaded {
        if let opID = request.opID, !G09CreativeWire.safeOperationID(opID) {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        let intentFingerprint = request.opID.map { _ in
            fingerprint("relink", projectID: request.projectID,
                        expectedRevision: request.expectedRevision,
                        extra: "\(request.assetID.uuidString)|\(request.relativePath)")
        }
        if let opID = request.opID, let intentFingerprint,
           let intent = try? readIntent(opID) {
            guard intent.projectID == request.projectID,
                  intent.kind == "relink",
                  intent.fingerprint == intentFingerprint else {
                throw G09CreativeError.invalidPayload("intentMismatch")
            }
            let current = try await load(
                id: request.projectID, requested: request.storage,
                origin: request.origin)
            if let replayed = try replayCommittedIntent(intent, current: current) {
                return replayed
            }
        }
        let loaded = try await load(
            id: request.projectID, requested: request.storage,
            origin: request.origin)
        _ = try await validateOrigin(request.origin, projectID: request.projectID,
                                     existing: loaded.project)
        guard loaded.writable else { throw G09CreativeError.provenanceMismatch }
        guard loaded.project.revision == request.expectedRevision else {
            throw G09CreativeError.revisionConflict
        }
        guard let target = mediaURL(rootURL: loaded.storage.rootURL,
                                    relativePath: request.relativePath),
              fileManager.fileExists(atPath: target.path) else {
            throw G09CreativeError.assetReferenceInvalid
        }
        guard loaded.project.assets.contains(where: { $0.id == request.assetID }) else {
            throw G09CreativeError.assetMissing
        }
        var project = loaded.project
        do {
            try MediaTransactions.apply(
                .relinkAsset(assetID: request.assetID,
                             relativePath: request.relativePath), to: &project)
        } catch {
            throw G09CreativeError.map(error)
        }
        let intent: G09MediaCommitIntent?
        if let opID = request.opID, let intentFingerprint,
           G09CreativeWire.safeOperationID(opID) {
            let value = G09MediaCommitIntent(
                opID: opID, projectID: project.id, kind: "relink",
                fingerprint: intentFingerprint,
                expectedRevision: request.expectedRevision,
                resultRevision: project.revision,
                resultDigest: canonicalDigest(project))
            try writeIntent(value)
            intent = value
        } else {
            intent = nil
        }
        do {
            _ = try await store.save(project, expectedRevision: request.expectedRevision)
        } catch {
            throw G09CreativeError.map(error)
        }
        try faultAfterCommit?()
        if let intent { markIntentCommitted(intent) }
        if let opID = request.opID, G09CreativeWire.safeOperationID(opID) {
            try? writeReceipt(G09MediaWriteReceipt(
                opID: opID, projectID: project.id,
                sessionDigest: G09CreativeAssetHost.sessionDigest(request.sessionToken),
                expectedRevision: request.expectedRevision,
                revision: project.revision,
                canUndo: MediaTransactions.canUndo(project),
                canRedo: MediaTransactions.canRedo(project)))
        }
        return Loaded(project: project, storage: loaded.storage,
                      writable: true, warnings: loaded.warnings)
    }

    // MARK: - Durable intents / receipts

    private func intentURL(_ opID: String) -> URL {
        intentDirectory.appendingPathComponent("\(opID).json")
    }

    private func readIntent(_ opID: String) throws -> G09MediaCommitIntent {
        guard G09CreativeWire.safeOperationID(opID) else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        guard let data = try? Data(contentsOf: intentURL(opID)),
              let intent = try? G09CreativeWire.decoder().decode(
                G09MediaCommitIntent.self, from: data) else {
            throw G09CreativeError.mediaProjectNotFound
        }
        return intent
    }

    private func writeIntent(_ intent: G09MediaCommitIntent) throws {
        try? fileManager.createDirectory(at: intentDirectory,
                                         withIntermediateDirectories: true)
        let data = try G09CreativeWire.encoder().encode(intent)
        try writeAtomically(data, to: intentURL(intent.opID))
        try? pruneIntents()
    }

    private func markIntentCommitted(_ intent: G09MediaCommitIntent) {
        var committed = intent
        committed.committedAt = Date()
        try? writeIntent(committed)
    }

    private func pruneIntents() throws {
        let files = try fileManager.contentsOfDirectory(
            at: intentDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
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

    private nonisolated func canonicalDigest(_ project: MediaProject) -> String? {
        guard let data = try? MediaProjectStore.canonicalContentData(project) else {
            return nil
        }
        return FloeDigest.sha256Hex(data)
    }

    private nonisolated func fingerprint(_ kind: String, projectID: UUID,
                                         expectedRevision: Int64,
                                         extra: String) -> String {
        FloeDigest.sha256Hex(Data(
            "\(kind)|\(projectID.uuidString.lowercased())|\(expectedRevision)|\(extra)".utf8))
    }

    private func replayCommittedIntent(_ intent: G09MediaCommitIntent,
                                       current: Loaded) throws -> Loaded? {
        if current.project.revision == intent.resultRevision {
            if intent.deleted { return current }
            if let expectedDigest = intent.resultDigest,
               canonicalDigest(current.project) == expectedDigest {
                if intent.committedAt == nil { markIntentCommitted(intent) }
                return current
            }
            if intent.resultDigest == nil { return current }
        }
        if current.project.revision == intent.expectedRevision {
            return nil
        }
        throw G09CreativeError.outcomeUnknown
    }

    public func readReceipt(_ opID: String) throws -> G09MediaWriteReceipt {
        guard G09CreativeWire.safeOperationID(opID) else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        let url = receiptDirectory.appendingPathComponent("\(opID).json")
        guard let data = try? Data(contentsOf: url),
              let receipt = try? G09CreativeWire.decoder().decode(
                G09MediaWriteReceipt.self, from: data) else {
            throw G09CreativeError.mediaProjectNotFound
        }
        return receipt
    }

    public func readAssetImportReceipt(_ opID: String) throws -> G09MediaAssetImportReceipt {
        guard G09CreativeWire.safeOperationID(opID) else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        let url = receiptDirectory.appendingPathComponent("asset-\(opID).json")
        guard let data = try? Data(contentsOf: url),
              let receipt = try? G09CreativeWire.decoder().decode(
                G09MediaAssetImportReceipt.self, from: data) else {
            throw G09CreativeError.mediaProjectNotFound
        }
        return receipt
    }

    private func writeAssetImportReceipt(_ receipt: G09MediaAssetImportReceipt) throws {
        try? fileManager.createDirectory(at: receiptDirectory, withIntermediateDirectories: true)
        let data = try G09CreativeWire.encoder().encode(receipt)
        let url = receiptDirectory.appendingPathComponent("asset-\(receipt.opID).json")
        try writeAtomically(data, to: url)
    }

    func writeReceipt(_ receipt: G09MediaWriteReceipt) throws {
        try? fileManager.createDirectory(at: receiptDirectory, withIntermediateDirectories: true)
        let data = try G09CreativeWire.encoder().encode(receipt)
        let url = receiptDirectory.appendingPathComponent("\(receipt.opID).json")
        try writeAtomically(data, to: url)
    }

    // MARK: - Trusted origin validation

    private func validateOrigin(_ origin: G09CreativeOriginDTO?, projectID: UUID,
                                existing: MediaProject?) async throws
        -> G09CreativeOriginDTO? {
        guard let origin else {
            if existing == nil {
                throw G09CreativeError.invalidOrigin("originRequired")
            }
            return nil
        }
        if let environment = origin.environmentID {
            guard !environment.isEmpty, environment.utf8.count <= 128,
                  !environment.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw G09CreativeError.invalidOrigin("invalidEnvironmentID")
            }
        }
        let normalized: G09CreativeOriginDTO
        switch origin.kind {
        case .standalone:
            guard origin.environmentID == nil else {
                throw G09CreativeError.invalidOrigin("standaloneEnvironment")
            }
            let id = origin.ownerID ?? projectID
            guard id == projectID else {
                throw G09CreativeError.invalidOrigin("standaloneOwner")
            }
            normalized = G09CreativeOriginDTO(kind: .standalone, ownerID: id)
        case .workspace:
            guard let id = origin.ownerID else {
                throw G09CreativeError.invalidOrigin("workspaceOwnerRequired")
            }
            guard let _ = try? await workspaceStore.workspace(id: id) else {
                throw G09CreativeError.invalidOrigin("workspaceUnknown")
            }
            normalized = origin
        case .canvas:
            guard let id = origin.ownerID else {
                throw G09CreativeError.invalidOrigin("canvasOwnerRequired")
            }
            let url = URL(fileURLWithPath: root.path, isDirectory: true)
                .appendingPathComponent("FloeAgent", isDirectory: true)
                .appendingPathComponent("Canvases", isDirectory: true)
                .appendingPathComponent("\(id.uuidString).json")
            guard fileManager.fileExists(atPath: url.path) else {
                throw G09CreativeError.invalidOrigin("canvasUnknown")
            }
            normalized = origin
        case .chat:
            guard let id = origin.ownerID else {
                throw G09CreativeError.invalidOrigin("chatOwnerRequired")
            }
            guard let _ = try? await conversationStore.conversation(id: id) else {
                throw G09CreativeError.invalidOrigin("conversationUnknown")
            }
            normalized = origin
        case .files:
            normalized = origin
        }
        if let existing {
            guard existing.ownerKind == normalized.kind.rawValue else {
                throw G09CreativeError.crossOwnerRefused
            }
            if normalized.kind == .standalone {
                // Older standalone projects may have no ownerID; the project
                // itself is the owner. Any other recorded ID is a mismatch.
                if let recordedOwner = existing.ownerID, recordedOwner != projectID {
                    throw G09CreativeError.crossOwnerRefused
                }
            } else if existing.ownerID != normalized.ownerID {
                throw G09CreativeError.crossOwnerRefused
            }
            if existing.environmentID != normalized.environmentID {
                throw G09CreativeError.crossOwnerRefused
            }
        }
        return normalized
    }

    // MARK: - Trusted storage resolution

    private func resolveStorage(ownerKind: String?, ownerID: UUID?,
                                requested: G09StorageLayerDTO?,
                                projectID: UUID? = nil,
                                recordedPath: String?) async throws
        -> G09TrustedMediaStorage {
        if let requested {
            switch requested.kind {
            case .appOwned:
                _ = try requested.validatedWorkspaceID()
                guard let id = projectID ?? ownerID else {
                    throw G09CreativeError.invalidOrigin("missingProjectIdentity")
                }
                return try appOwnedStorage(projectID: id,
                                           recordedPath: recordedPath)
            case .workspace:
                guard let workspaceID = try requested.validatedWorkspaceID() else {
                    throw G09CreativeError.invalidPayload("workspaceIDRequired")
                }
                return try await workspaceStorage(workspaceID: workspaceID,
                                                  recordedPath: recordedPath)
            }
        }
        guard let ownerKind else { throw G09CreativeError.untrustedOwner }
        switch ownerKind {
        case "standalone":
            guard let id = projectID ?? ownerID else {
                throw G09CreativeError.untrustedOwner
            }
            return try appOwnedStorage(projectID: id, recordedPath: recordedPath)
        case "workspace":
            guard let ownerID else { throw G09CreativeError.untrustedOwner }
            return try await workspaceStorage(workspaceID: ownerID,
                                              recordedPath: recordedPath)
        case "files", "canvas", "chat":
            // These owners are preserved metadata. Their storage must be an
            // explicit app-owned working copy or a real workspace; inferring
            // a root from the owner/environment is forbidden.
            throw G09CreativeError.storageLayerRequired
        default:
            throw G09CreativeError.untrustedOwner
        }
    }

    private func appOwnedStorage(projectID: UUID,
                                 recordedPath: String?) throws -> G09TrustedMediaStorage {
        let rootURL = root.artifactStoreURL
            .appendingPathComponent("WorkbenchRoot", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .standardizedFileURL
        let base = root.artifactStoreURL.appendingPathComponent("WorkbenchRoot", isDirectory: true)
            .standardizedFileURL.path
        guard rootURL.path.hasPrefix(base + "/") else {
            throw G09CreativeError.storageUnavailable
        }
        let mismatch = Self.mismatch(recordedPath, trusted: rootURL.path)
        return G09TrustedMediaStorage(
            storage: G09StorageLayerDTO(kind: .appOwned),
            rootURL: rootURL, ownerKind: "standalone", ownerID: projectID,
            recordedPathMismatch: mismatch)
    }

    private func workspaceStorage(workspaceID: UUID,
                                  recordedPath: String?) async throws
        -> G09TrustedMediaStorage {
        guard let record = try? await workspaceStore.workspace(id: workspaceID) else {
            throw G09CreativeError.workspaceStorageUnavailable
        }
        guard let relative = record.internalRelativePath,
              G09CreativeAssetHost.safeRelativePath(relative),
              !relative.isEmpty,
              record.kind == .privateTask || record.kind == .project else {
            // A security-scoped project bookmark with NO app-private working
            // copy cannot be resolved on Android. The caller must choose an
            // explicit app-owned import/edit copy instead.
            throw G09CreativeError.workspaceStorageUnavailable
        }
        let base = URL(fileURLWithPath: root.path, isDirectory: true)
            .appendingPathComponent("Workspace", isDirectory: true)
            .standardizedFileURL
        let rootURL = base.appendingPathComponent(relative, isDirectory: true).standardizedFileURL
        guard rootURL.path.hasPrefix(base.path + "/") else {
            throw G09CreativeError.workspaceStorageUnavailable
        }
        let mismatch = Self.mismatch(recordedPath, trusted: rootURL.path)
        return G09TrustedMediaStorage(
            storage: G09StorageLayerDTO(kind: .workspace, workspaceID: workspaceID),
            rootURL: rootURL, ownerKind: "workspace", ownerID: workspaceID,
            recordedPathMismatch: mismatch)
    }

    // MARK: - File helpers

    private func readProject(at url: URL, expectedID: UUID) throws -> MediaProject {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= G09CreativeLimits.mediaProjectBytes else {
            throw G09CreativeError.projectTooLarge
        }
        guard let data = try? Data(contentsOf: url),
              let project = try? G09CreativeWire.decoder().decode(
                MediaProject.self, from: data) else {
            throw G09CreativeError.corruptProject
        }
        guard project.id == expectedID else { throw G09CreativeError.corruptProject }
        return project
    }

    private nonisolated static func quicklyWritable(_ project: MediaProject) -> Bool {
        project.schemaVersion <= MediaProject.currentSchemaVersion &&
            ["standalone", "workspace"].contains(project.ownerKind)
    }

    private nonisolated static func standaloneProvenanceWarning(
        _ project: MediaProject, acceptedRoot: String
    ) -> Bool {
        guard project.ownerKind == "standalone",
              let recorded = project.taskWorkspacePath, !recorded.isEmpty else {
            return false
        }
        let expected = URL(fileURLWithPath: acceptedRoot, isDirectory: true)
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("WorkbenchRoot", isDirectory: true)
            .appendingPathComponent(project.id.uuidString, isDirectory: true)
            .standardizedFileURL.path
        return URL(fileURLWithPath: recorded).standardizedFileURL.path != expected
    }

    private nonisolated static func mismatch(_ recorded: String?, trusted: String) -> Bool {
        guard let recorded, !recorded.isEmpty else { return false }
        let normalized = URL(fileURLWithPath: recorded).standardizedFileURL.path
        return normalized != URL(fileURLWithPath: trusted).standardizedFileURL.path
    }

    private nonisolated func mediaURL(rootURL: URL, relativePath: String) -> URL? {
        guard G09CreativeAssetHost.safeRelativePath(relativePath),
              relativePath.hasPrefix("Workbench/Assets/") else { return nil }
        let base = rootURL.standardizedFileURL
        let target = base.appendingPathComponent(relativePath).standardizedFileURL
        guard target.path.hasPrefix(base.path + "/") else { return nil }
        return target
    }

    private nonisolated static func mediaAssetKind(fileName: String,
                                                   mimeType: String?) -> MediaAssetKind {
        let mime = (mimeType ?? "").lowercased()
        if mime.hasPrefix("video/") { return .video }
        if mime.hasPrefix("audio/") { return .audio }
        if mime.hasPrefix("image/") { return .image }
        switch (fileName as NSString).pathExtension.lowercased() {
        case "mp4", "mov", "m4v", "webm": return .video
        case "mp3", "m4a", "wav", "aac", "flac": return .audio
        default: return .image
        }
    }

    private func copyExclusive(from source: URL, to target: URL) throws {
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".floe-media-asset-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        do {
            try fileManager.copyItem(at: source, to: temporary)
            try fsyncFile(temporary)
            guard !fileManager.fileExists(atPath: target.path) else {
                throw G09CreativeError.assetReferenceInvalid
            }
            try fileManager.moveItem(at: temporary, to: target)
        } catch let typed as G09CreativeError {
            throw typed
        } catch {
            throw G09CreativeError.writeFailed
        }
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".floe-media-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        do {
            try data.write(to: temporary, options: [])
            try fsyncFile(temporary)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
        } catch {
            throw G09CreativeError.writeFailed
        }
    }

    private func fsyncFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw G09CreativeError.writeFailed }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw G09CreativeError.writeFailed }
    }
}
