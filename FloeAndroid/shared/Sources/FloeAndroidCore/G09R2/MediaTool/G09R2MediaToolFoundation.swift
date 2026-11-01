// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — real native host foundation for the portable `media.project` tool
// (job-258c68e91e6840df).
//
// The portable original tool (FloeAndroidWorkbench) owns command decoding,
// proposal validation and both apply authorities. This file supplies the
// Android host side that the tool cannot own:
//
//  * one exact task/session/project/storage/write-layer resolution over the
//    ALREADY accepted creative generation (`G09CreativeDomainService`), the
//    real workspace/conversation stores and the real media project CAS;
//  * durable, bounded proposal envelopes so a revision-bound draft is not
//    resurrected for another task/environment/epoch;
//  * the trusted interactive grant (the original `MediaProposalGrantStore`
//    single-use/expiry semantics) bound to the same session;
//  * bounded no-follow file helpers shared by the export path.
//
// Recorded project provenance (`ownerKind`/`ownerID`/`environmentID`/
// `taskWorkspacePath`) is NOT permission. It is compared against the caller's
// REAL resolved conversation/workspace/environment and against the two
// legitimate trusted roots derived from the accepted root; a mismatch is a
// typed refusal, never a guessed storage layer.
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

// MARK: - Typed tool failures

/// One bounded, user-actionable media-project-tool refusal. Every case maps
/// to a `FloeError` at the protocol boundary so the model/user sees a short
/// message and no path, token or internal identifier.
enum G09R2MediaToolFailure: Error, Sendable, Equatable {
    case taskRequired
    case taskUnknown
    case environmentMismatch
    case projectNotOwnedByTask(String)
    case storageUnresolved
    case storageMismatch
    case consumerUnavailable
    case generationStopped
    case projectGone
    case projectChanged
    case proposalMissing
    case proposalBindingMismatch
    case proposalIdentityUnavailable
    case proposalIdentityAmbiguous
    case proposalLimit
    case proposalCollision
    case grantInvalid
    case exportUnsupported(String)
    case exportFailed(String)
    case exportOutcomeUnknown
    case measurementUnavailable(String)
    case rendererCompositeUnavailable(String)

    var message: String {
        switch self {
        case .taskRequired:
            return "media.project can only edit a project owned by the current task"
        case .taskUnknown:
            return "the current task workspace could not be resolved; reopen the task and try again"
        case .environmentMismatch:
            return "this media project belongs to a different task environment"
        case .projectNotOwnedByTask(let kind):
            return "this media project is owned by \(kind), not by the current task"
        case .storageUnresolved:
            return "this media project's storage layer does not match the current task; reopen the project and try again"
        case .storageMismatch:
            return "the requested workspace does not belong to the current task"
        case .consumerUnavailable:
            return "the media renderer is not running; reopen the workbench and try again"
        case .generationStopped:
            return "the workbench is stopping; media.project is unavailable until it reopens"
        case .projectGone:
            return "the media project no longer exists"
        case .projectChanged:
            return "the media project changed since it was loaded; reopen it and prepare the change again"
        case .proposalMissing:
            return "the pending media proposal no longer exists"
        case .proposalBindingMismatch:
            return "the pending media proposal belongs to a different task or project"
        case .proposalIdentityUnavailable:
            return "the applied media state does not match any pending proposal; reopen the project"
        case .proposalIdentityAmbiguous:
            return "more than one pending proposal matches this change; review the proposals first"
        case .proposalLimit:
            return "there are too many pending media proposals; apply or discard one first"
        case .proposalCollision:
            return "a different pending proposal already uses this identity"
        case .grantInvalid:
            return "the confirmation for this media proposal is not valid"
        case .exportUnsupported(let detail):
            return "this media export is not supported: \(detail)"
        case .exportFailed(let code):
            return "the media export failed (\(code))"
        case .exportOutcomeUnknown:
            return "the media export outcome is unknown; do not retry automatically"
        case .measurementUnavailable(let detail):
            return "layer alignment is unavailable for this layer: \(detail)"
        case .rendererCompositeUnavailable(let detail):
            return "the layer composite renderer is unavailable in this build: \(detail)"
        }
    }

    var floError: FloeError {
        switch self {
        case .projectGone, .proposalMissing:
            return .notFound(message)
        case .taskRequired, .taskUnknown, .environmentMismatch,
             .projectNotOwnedByTask, .storageMismatch, .proposalBindingMismatch,
             .grantInvalid:
            return .unauthorized
        default:
            return .validationFailed(message)
        }
    }
}

// MARK: - Bounded file helpers

enum G09R2MediaToolFile {
    static let maximumProjectBytes = G09R2CreativeLimits.mediaProjectBytes
    static let maximumProposalBytes = 1024 * 1024
    static let maximumProposalFiles = 64
    static let maximumProposalDirectoryBytes = 8 * 1024 * 1024

    /// Absolute path must be a real regular file (no symlink, no directory,
    /// no special file). Returns its size after the lstat identity check.
    static func regularFileSize(_ path: String) -> Int64? {
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            return nil
        }
        return Int64(info.st_size)
    }

    static func isRealDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 &&
            (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
    }

    static func isSymlink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 &&
            (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK)
    }

    /// Resolves a relative path under `root` without following any symlink in
    /// the final component and without allowing traversal. The root itself is
    /// the caller's trusted, already validated absolute directory.
    static func containedURL(root: URL, relativePath: String) -> URL? {
        guard G09CreativeAssetHost.safeRelativePath(relativePath),
              !relativePath.isEmpty,
              !relativePath.hasPrefix("/") else { return nil }
        let base = root.standardizedFileURL
        let target = base.appendingPathComponent(relativePath).standardizedFileURL
        guard target.path.hasPrefix(base.path + "/") else { return nil }
        return target
    }

    /// Creates a directory chain under an already trusted root. Every existing
    /// component must be a real directory (never a symlink).
    static func ensureRealDirectory(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        if isRealDirectory(path) { return }
        if isSymlink(path) { throw FloeError.validationFailed("The media storage directory is not safe") }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard isRealDirectory(path) else {
            throw FloeError.validationFailed("The media storage directory could not be created")
        }
    }

    /// Creates/validates a chain of real directories below an accepted root.
    /// Every existing component is lstat-checked: a symlink anywhere in the
    /// chain is refused instead of being followed outside the root.
    static func ensureRealSubdirectories(root: URL, components: [String]) throws -> URL {
        guard !components.isEmpty else {
            throw FloeError.validationFailed("The media storage path is empty")
        }
        let base = root.standardizedFileURL
        guard isRealDirectory(base.path) else {
            throw FloeError.validationFailed("The media storage root is unavailable")
        }
        var current = base
        for component in components {
            guard !component.isEmpty, component != ".", component != "..",
                  !component.contains("/") else {
                throw FloeError.validationFailed("The media storage path is invalid")
            }
            let next = current.appendingPathComponent(component, isDirectory: true)
                .standardizedFileURL
            guard next.path.hasPrefix(base.path + "/") else {
                throw FloeError.validationFailed("The media storage path escapes the root")
            }
            if isSymlink(next.path) {
                throw FloeError.validationFailed("The media storage path is not safe")
            }
            if !FileManager.default.fileExists(atPath: next.path) {
                try FileManager.default.createDirectory(
                    at: next, withIntermediateDirectories: false)
            }
            guard isRealDirectory(next.path) else {
                throw FloeError.validationFailed("The media storage directory is not safe")
            }
            current = next
        }
        return current
    }

    /// Atomic replace inside one already verified directory. A brand-new file
    /// is never overwritten by a different byte body.
    static func writeAtomically(_ data: Data, to url: URL,
                                replaceExisting: Bool) throws {
        let directory = url.deletingLastPathComponent()
        try ensureRealDirectory(directory)
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: [.withoutOverwriting])
        try flushFile(temporary)
        if FileManager.default.fileExists(atPath: url.path) {
            guard replaceExisting else { throw FloeError.validationFailed("The file already exists") }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        try flushDirectory(directory)
    }

    static func flushFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw FloeError.validationFailed("The file could not be opened") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw FloeError.validationFailed("The file could not be flushed")
        }
    }

    static func flushDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = fsync(descriptor)
    }

    /// Bounded read of the exact regular file; a symlink or an oversized file
    /// is refused before any byte is returned.
    static func readBounded(_ url: URL, maximumBytes: Int) throws -> Data {
        guard let size = regularFileSize(url.path), size <= Int64(maximumBytes) else {
            throw FloeError.validationFailed("The media file is not readable")
        }
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw FloeError.validationFailed("The media file could not be read")
        }
    }

    static func digest(ofFileAt url: URL) throws -> String {
        guard regularFileSize(url.path) != nil else {
            throw FloeError.validationFailed("The media file is not a regular file")
        }
        do {
            return try FloeDigest.sha256Hex(ofFileAt: url)
        } catch {
            throw FloeError.validationFailed("The media file could not be hashed")
        }
    }

    static func normalizeAbsolutePath(_ raw: String) -> String? {
        guard raw.hasPrefix("/"), raw.utf8.count <= 4096,
              !raw.unicodeScalars.contains(where: { $0 == "\u{0}" }) else {
            return nil
        }
        return URL(fileURLWithPath: raw).standardizedFileURL.path
    }

    /// Same trusted path, tolerant only of symlink spelling (the App's tool
    /// context resolves symlinks; the host records standardized paths). It is
    /// never a directory-prefix or ancestor comparison.
    static func pathsEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        let left = URL(fileURLWithPath: lhs).standardizedFileURL
        let right = URL(fileURLWithPath: rhs).standardizedFileURL
        if left.path == right.path { return true }
        let leftResolved = left.resolvingSymlinksInPath().path
        let rightResolved = right.resolvingSymlinksInPath().path
        return leftResolved == rightResolved ||
            left.path == rightResolved ||
            leftResolved == right.path
    }
}

// MARK: - Resolved tool session

/// Exact bound identity of ONE `media.project` call. Every protocol method
/// re-resolves it before touching project bytes.
struct G09R2MediaToolSession: Sendable {
    let epoch: UInt64
    let root: RuntimeStorageRoot
    let media: G09MediaProjectHost
    let project: MediaProject
    let storage: G09StorageLayerDTO
    let origin: G09CreativeOriginDTO
    let projectRoot: URL
    let conversationID: UUID
    let workspaceID: UUID?
    let taskDigest: String
    let accessProof: String
    /// The explicit trusted task/project association that authorized this
    /// session, or nil for the legacy exact-provenance path.
    let bindingID: UUID?

    init(
        epoch: UInt64,
        root: RuntimeStorageRoot,
        media: G09MediaProjectHost,
        project: MediaProject,
        storage: G09StorageLayerDTO,
        origin: G09CreativeOriginDTO,
        projectRoot: URL,
        conversationID: UUID,
        workspaceID: UUID?,
        taskDigest: String,
        accessProof: String,
        bindingID: UUID? = nil
    ) {
        self.epoch = epoch
        self.root = root
        self.media = media
        self.project = project
        self.storage = storage
        self.origin = origin
        self.projectRoot = projectRoot
        self.conversationID = conversationID
        self.workspaceID = workspaceID
        self.taskDigest = taskDigest
        self.accessProof = accessProof
        self.bindingID = bindingID
    }

    var storageKey: String {
        switch storage.kind {
        case .appOwned: return "appOwned"
        case .workspace: return "workspace:\(workspaceID?.uuidString.lowercased() ?? "")"
        }
    }

    /// Same immutable call/task/storage identity with a freshly REOPENED
    /// project snapshot. The access proof and task digest remain stable for
    /// this one invocation; the original tool's verified apply reloads the
    /// persisted revision through this value instead of seeing the stale
    /// authorize-time snapshot.
    func replacingProject(_ project: MediaProject) -> G09R2MediaToolSession {
        G09R2MediaToolSession(
            epoch: epoch,
            root: root,
            media: media,
            project: project,
            storage: storage,
            origin: origin,
            projectRoot: projectRoot,
            conversationID: conversationID,
            workspaceID: workspaceID,
            taskDigest: taskDigest,
            accessProof: accessProof,
            bindingID: bindingID)
    }
}

// MARK: - Access resolver

/// Recorded project provenance read from the accepted project record. It is
/// provenance, never permission; the trusted binding re-validates it and
/// derives storage from the accepted roots/rows.
struct G09R2MediaProjectProvenance: Sendable {
    var ownerKind: String
    var ownerID: UUID?
    var environmentID: String?
    var taskWorkspacePath: String?
}

/// Resolves the caller's EXPLICIT task identity into the real project storage
/// and write layer. This type never creates a root, migration, fallback
/// storage or a second project store.
enum G09R2MediaToolAccess {
    static func authorize(
        service: G09CreativeDomainService,
        mailbox: G09R2MediaRenderHostMailbox,
        access: MediaProjectAccess,
        projectID: UUID,
        requireWritable: Bool
    ) async throws -> G09R2MediaToolSession {
        guard let cluster = await service.r2BoundCluster() else {
            throw G09R2MediaToolFailure.generationStopped
        }
        guard await service.r2IsGenerationLive(epoch: cluster.epoch),
              !mailbox.isRootStopping(epoch: cluster.epoch) else {
            throw G09R2MediaToolFailure.generationStopped
        }
        guard mailbox.isBound(to: cluster.epoch),
              mailbox.consumerReady(epoch: cluster.epoch) else {
            throw G09R2MediaToolFailure.consumerUnavailable
        }
        guard access.ownerKind == "chat", let conversationID = access.ownerID else {
            throw G09R2MediaToolFailure.taskRequired
        }
        guard let workspaceStore = await service.r2WorkspaceStore(),
              let conversationStore = await service.r2ConversationStore() else {
            throw G09R2MediaToolFailure.generationStopped
        }
        guard (try? await conversationStore.conversation(id: conversationID)) != nil else {
            throw G09R2MediaToolFailure.taskUnknown
        }

        // The caller's real workspace row (if any), resolved from the SAME
        // accepted root as the runtime's trusted workspace root.
        var workspaceID: UUID?
        var callerWorkspaceRoot: String?
        if let id = try? await workspaceStore.workspaceID(conversationID: conversationID),
           let record = try? await workspaceStore.workspace(id: id),
           record.kind == .privateTask || record.kind == .project,
           let relative = record.internalRelativePath,
           G09CreativeAssetHost.safeRelativePath(relative),
           !relative.isEmpty {
            let base = URL(fileURLWithPath: cluster.root.path, isDirectory: true)
                .appendingPathComponent("Workspace", isDirectory: true)
                .standardizedFileURL
            let root = base.appendingPathComponent(relative, isDirectory: true)
                .standardizedFileURL
            if root.path.hasPrefix(base.path + "/") {
                workspaceID = id
                callerWorkspaceRoot = root.path
            }
        }
        if let provided = access.workspacePath {
            guard let normalized = G09R2MediaToolFile.normalizeAbsolutePath(provided),
                  let expected = callerWorkspaceRoot,
                  G09R2MediaToolFile.pathsEquivalent(normalized, expected) else {
                throw G09R2MediaToolFailure.storageMismatch
            }
        }

        let provenance = try readProvenance(
            directory: cluster.media.projectDirectoryPath, projectID: projectID)
        guard provenance.environmentID == access.environmentID else {
            throw G09R2MediaToolFailure.environmentMismatch
        }
        switch provenance.ownerKind {
        case "chat":
            guard provenance.ownerID == conversationID else {
                throw G09R2MediaToolFailure.projectNotOwnedByTask("another task")
            }
        case "workspace":
            guard let workspaceID, provenance.ownerID == workspaceID else {
                throw G09R2MediaToolFailure.projectNotOwnedByTask("another workspace")
            }
        default:
            throw G09R2MediaToolFailure.projectNotOwnedByTask(provenance.ownerKind)
        }

        // Two legitimate roots only. The recorded path selects between them;
        // it never invents one.
        let appOwned = cluster.root.artifactStoreURL
            .appendingPathComponent("WorkbenchRoot", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .standardizedFileURL.path
        let recorded = provenance.taskWorkspacePath
            .flatMap(G09R2MediaToolFile.normalizeAbsolutePath)
        let storage: G09StorageLayerDTO
        if let recorded, G09R2MediaToolFile.pathsEquivalent(recorded, appOwned) {
            storage = G09StorageLayerDTO(kind: .appOwned)
        } else if let recorded, let callerWorkspaceRoot,
                  G09R2MediaToolFile.pathsEquivalent(recorded, callerWorkspaceRoot),
                  let workspaceID {
            storage = G09StorageLayerDTO(kind: .workspace, workspaceID: workspaceID)
        } else {
            throw G09R2MediaToolFailure.storageUnresolved
        }

        let origin: G09CreativeOriginDTO
        switch provenance.ownerKind {
        case "chat":
            origin = G09CreativeOriginDTO(
                kind: .chat, ownerID: conversationID,
                environmentID: provenance.environmentID)
        case "workspace":
            origin = G09CreativeOriginDTO(
                kind: .workspace, ownerID: provenance.ownerID,
                environmentID: provenance.environmentID)
        default:
            throw G09R2MediaToolFailure.projectNotOwnedByTask(provenance.ownerKind)
        }

        let loaded: G09MediaProjectHost.Loaded
        do {
            loaded = try await cluster.media.load(
                id: projectID, requested: storage, origin: origin)
        } catch {
            throw G09R2MediaToolAccess.floError(error)
        }
        if requireWritable, !loaded.writable {
            throw G09R2MediaToolFailure.storageUnresolved
        }
        let taskDigest = FloeDigest.sha256Hex(Data((
            "floe.g09.mediatool-task/1|\(cluster.epoch)|" +
            "\(conversationID.uuidString.lowercased())|" +
            "\(workspaceID?.uuidString.lowercased() ?? "")|" +
            "\(access.environmentID ?? "")").utf8))
        let storageProof = storage.kind == .appOwned
            ? "appOwned"
            : "workspace:\(workspaceID?.uuidString.lowercased() ?? "")"
        let accessProof = FloeDigest.sha256Hex(Data((
            "floe.g09.mediatool-access/1|\(cluster.epoch)|\(taskDigest)|" +
            "\(projectID.uuidString.lowercased())|\(storageProof)|" +
            "\(loaded.project.revision)").utf8))
        return G09R2MediaToolSession(
            epoch: cluster.epoch,
            root: cluster.root,
            media: cluster.media,
            project: loaded.project,
            storage: storage,
            origin: origin,
            projectRoot: loaded.storage.rootURL.standardizedFileURL,
            conversationID: conversationID,
            workspaceID: workspaceID,
            taskDigest: taskDigest,
            accessProof: accessProof)
    }

    static func readProvenance(directory: String, projectID: UUID)
        throws -> G09R2MediaProjectProvenance {
        let name = MediaProjectStore.projectFileName(id: projectID)
        let url = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(name)
        guard let size = G09R2MediaToolFile.regularFileSize(url.path),
              size > 0, size <= Int64(G09R2CreativeLimits.mediaProjectBytes) else {
            throw G09R2MediaToolFailure.projectGone
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw G09R2MediaToolFailure.projectGone
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let id = (root["id"] as? String).flatMap(UUID.init(uuidString:)),
              id == projectID,
              let ownerKind = root["ownerKind"] as? String else {
            throw G09R2MediaToolFailure.projectGone
        }
        return G09R2MediaProjectProvenance(
            ownerKind: ownerKind,
            ownerID: (root["ownerID"] as? String).flatMap(UUID.init(uuidString:)),
            environmentID: root["environmentID"] as? String,
            taskWorkspacePath: root["taskWorkspacePath"] as? String)
    }

    /// Every host boundary surfaces a `FloeError`; internal typed failures
    /// keep their exact actionable copy without leaking paths or codes beyond
    /// the bounded detail.
    static func floError(_ error: Error) -> FloeError {
        if let failure = error as? G09R2MediaToolFailure { return failure.floError }
        if let failure = error as? G09R2MediaTaskBindingFailure { return failure.floError }
        if let floe = error as? FloeError { return floe }
        if error is CancellationError { return .cancelled }
        if let typed = error as? G09CreativeError {
            switch typed {
            case .mediaProjectNotFound, .corruptProject:
                return G09R2MediaToolFailure.projectGone.floError
            case .revisionConflict:
                return G09R2MediaToolFailure.projectChanged.floError
            case .crossOwnerRefused, .untrustedOwner, .provenanceMismatch,
                 .invalidOrigin, .storageLayerRequired, .workspaceStorageUnavailable:
                return G09R2MediaToolFailure.projectNotOwnedByTask("another owner").floError
            case .staleGeneration, .acceptedRootNotLive, .runtimeUnavailable:
                return G09R2MediaToolFailure.generationStopped.floError
            default:
                return .validationFailed(
                    "The media project operation was refused (\(typed.code))")
            }
        }
        if let r2 = error as? G09R2Error {
            switch r2.wire {
            case .rendererUnavailable:
                return G09R2MediaToolFailure.consumerUnavailable.floError
            case .renderCancelled:
                return G09R2MediaToolFailure.generationStopped.floError
            default:
                return .validationFailed(
                    "The media project operation was refused (\(r2.code))")
            }
        }
        return .validationFailed("The media project operation could not be completed")
    }
}

// MARK: - Durable proposal envelopes

struct G09R2ProposalEnvelope: Codable, Sendable {
    var schemaVersion: Int
    var epoch: UInt64
    var taskDigest: String
    var environmentID: String?
    var storageKey: String
    var projectID: UUID
    var baseRevision: Int64
    var createdAt: Date
    var proposal: MediaProposal
}

struct G09R2StoredProposal: Sendable {
    var envelope: G09R2ProposalEnvelope
    var proposalID: UUID { envelope.proposal.id }
}

/// Bounded, durable pending-media-proposal store under the accepted root.
/// It is a draft table, not a second project/task database: the project CAS
/// in `G09MediaProjectHost` remains the only mutation authority, and a draft
/// is only usable by the exact epoch/task/project/storage tuple that stored
/// it. Expired/foreign drafts are invisible (never resurrected).
actor G09R2MediaToolProposalStore {
    static let shared = G09R2MediaToolProposalStore()

    struct LoadedHint: Sendable {
        let projectID: UUID
        let proposalID: UUID
        let at: Date
    }

    private var hints: [UUID: LoadedHint] = [:]
    private let hintLifetime: TimeInterval = 600

    init() {}

    private static func acceptedRoot(_ session: G09R2MediaToolSession) -> URL {
        URL(fileURLWithPath: session.root.path, isDirectory: true)
    }

    private func directory(root: URL) -> URL {
        root.appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("MediaTool", isDirectory: true)
            .appendingPathComponent("Proposals", isDirectory: true)
    }

    private func projectDirectory(root: URL, projectID: UUID) -> URL {
        directory(root: root)
            .appendingPathComponent(projectID.uuidString.lowercased(), isDirectory: true)
    }

    private func fileURL(root: URL, projectID: UUID, proposalID: UUID) -> URL {
        projectDirectory(root: root, projectID: projectID)
            .appendingPathComponent("\(proposalID.uuidString.lowercased()).json")
    }

    func store(_ proposal: MediaProposal, session: G09R2MediaToolSession) throws {
        guard proposal.projectID == session.project.id else {
            throw G09R2MediaToolFailure.proposalBindingMismatch
        }
        guard proposal.baseRevision == session.project.revision else {
            throw G09R2MediaToolFailure.projectChanged
        }
        guard !proposal.commands.isEmpty,
              proposal.commands.count <= G09R2CreativeLimits.mediaCommands,
              proposal.summary.count <= 2000 else {
            throw G09R2MediaToolFailure.proposalLimit
        }
        let envelope = G09R2ProposalEnvelope(
            schemaVersion: 1,
            epoch: session.epoch,
            taskDigest: session.taskDigest,
            environmentID: session.origin.environmentID,
            storageKey: session.storageKey,
            projectID: proposal.projectID,
            baseRevision: proposal.baseRevision,
            createdAt: proposal.createdAt,
            proposal: proposal)
        let data: Data
        do {
            data = try G09CreativeWire.encoder().encode(envelope)
        } catch {
            throw FloeError.storageCorrupted("The media proposal could not be encoded")
        }
        guard data.count <= G09R2MediaToolFile.maximumProposalBytes else {
            throw G09R2MediaToolFailure.proposalLimit
        }
        let directory = try G09R2MediaToolFile.ensureRealSubdirectories(
            root: Self.acceptedRoot(session),
            components: ["FloeAgent", "MediaTool", "Proposals",
                         proposal.projectID.uuidString.lowercased()])
        let url = directory.appendingPathComponent(
            "\(proposal.id.uuidString.lowercased()).json")
        if let existing = try? G09R2MediaToolFile.readBounded(
            url, maximumBytes: G09R2MediaToolFile.maximumProposalBytes) {
            if existing == data { return }
            throw G09R2MediaToolFailure.proposalCollision
        }
        try pruneIfNeeded(root: Self.acceptedRoot(session),
                          projectID: proposal.projectID, keeping: url)
        try G09R2MediaToolFile.writeAtomically(data, to: url, replaceExisting: false)
    }

    func load(id: UUID, session: G09R2MediaToolSession) throws -> MediaProposal? {
        let url = fileURL(root: Self.acceptedRoot(session),
                          projectID: session.project.id, proposalID: id)
        guard let data = try? G09R2MediaToolFile.readBounded(
            url, maximumBytes: G09R2MediaToolFile.maximumProposalBytes),
              let envelope = try? G09CreativeWire.decoder().decode(
                G09R2ProposalEnvelope.self, from: data),
              bindingMatches(envelope, session: session),
              envelope.proposal.id == id else {
            return nil
        }
        hints[session.project.id] = LoadedHint(
            projectID: session.project.id, proposalID: id, at: Date())
        return envelope.proposal
    }

    func remove(id: UUID, session: G09R2MediaToolSession) throws {
        let url = fileURL(root: Self.acceptedRoot(session),
                          projectID: session.project.id, proposalID: id)
        guard let data = try? G09R2MediaToolFile.readBounded(
            url, maximumBytes: G09R2MediaToolFile.maximumProposalBytes),
              let envelope = try? G09CreativeWire.decoder().decode(
                G09R2ProposalEnvelope.self, from: data) else {
            return
        }
        guard bindingMatches(envelope, session: session) else {
            throw G09R2MediaToolFailure.proposalBindingMismatch
        }
        try? FileManager.default.removeItem(at: url)
        if hints[session.project.id]?.proposalID == id {
            hints.removeValue(forKey: session.project.id)
        }
    }

    func recentProposalID(projectID: UUID, session: G09R2MediaToolSession) -> UUID? {
        guard let hint = hints[projectID],
              Date().timeIntervalSince(hint.at) <= hintLifetime else {
            return nil
        }
        return hint.proposalID
    }

    func pending(projectID: UUID, session: G09R2MediaToolSession) -> [G09R2StoredProposal] {
        let directory = projectDirectory(
            root: Self.acceptedRoot(session),
            projectID: projectID)
        guard G09R2MediaToolFile.isRealDirectory(directory.path),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else {
            return []
        }
        var result: [G09R2StoredProposal] = []
        var remaining = G09R2MediaToolFile.maximumProposalFiles
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard remaining > 0, url.pathExtension.lowercased() == "json" else { continue }
            remaining -= 1
            guard let data = try? G09R2MediaToolFile.readBounded(
                url, maximumBytes: G09R2MediaToolFile.maximumProposalBytes),
                  let envelope = try? G09CreativeWire.decoder().decode(
                    G09R2ProposalEnvelope.self, from: data),
                  bindingMatches(envelope, session: session),
                  envelope.projectID == projectID else {
                continue
            }
            result.append(G09R2StoredProposal(envelope: envelope))
        }
        return result.sorted {
            if $0.proposalID != $1.proposalID {
                return $0.proposalID.uuidString < $1.proposalID.uuidString
            }
            return $0.envelope.createdAt < $1.envelope.createdAt
        }
    }

    private func bindingMatches(_ envelope: G09R2ProposalEnvelope,
                                session: G09R2MediaToolSession) -> Bool {
        envelope.schemaVersion == 1 &&
            envelope.epoch == session.epoch &&
            envelope.taskDigest == session.taskDigest &&
            envelope.environmentID == session.origin.environmentID &&
            envelope.storageKey == session.storageKey &&
            envelope.projectID == session.project.id
    }

    /// Bounded prune by count and total bytes. The file being stored is kept.
    private func pruneIfNeeded(root: URL, projectID: UUID, keeping: URL) throws {
        let directory = projectDirectory(root: root, projectID: projectID)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        var files: [(url: URL, modified: Date, size: Int64)] = []
        for url in entries where url.pathExtension.lowercased() == "json" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            files.append((url, modified, G09R2MediaToolFile.regularFileSize(url.path) ?? 0))
        }
        files.sort { $0.modified < $1.modified }
        var count = files.count
        var bytes = files.reduce(Int64(0)) { $0 + $1.size }
        for file in files {
            if count <= G09R2MediaToolFile.maximumProposalFiles,
               bytes <= Int64(G09R2MediaToolFile.maximumProposalDirectoryBytes) {
                break
            }
            if file.url.standardizedFileURL == keeping.standardizedFileURL { continue }
            if (try? FileManager.default.removeItem(at: file.url)) != nil {
                count -= 1
                bytes -= file.size
            }
        }
        if count >= G09R2MediaToolFile.maximumProposalFiles {
            throw G09R2MediaToolFailure.proposalLimit
        }
    }
}

// MARK: - Trusted interactive grants

/// The ORIGINAL `MediaProposalGrantStore` semantics (opaque id, single use,
/// bounded TTL, exact project/proposal/revision) owned by this process.
/// Only trusted UI/App code may issue; the model receives the opaque id.
final class G09R2MediaToolGrants: @unchecked Sendable {
    static let shared = G09R2MediaToolGrants(
        service: BridgeV5.service,
        mailbox: G09R2MediaRenderHostMailbox.shared,
        proposals: G09R2MediaToolProposalStore.shared)

    private let service: G09CreativeDomainService
    private let mailbox: G09R2MediaRenderHostMailbox
    private let proposals: G09R2MediaToolProposalStore
    private let store: MediaProposalGrantStore

    init(service: G09CreativeDomainService,
         mailbox: G09R2MediaRenderHostMailbox,
         proposals: G09R2MediaToolProposalStore,
         store: MediaProposalGrantStore = MediaProposalGrantStore()) {
        self.service = service
        self.mailbox = mailbox
        self.proposals = proposals
        self.store = store
    }

    /// Trusted interactive issuance. The caller must present the REAL task
    /// access of the UI that is showing the proposal; a stale revision or a
    /// foreign project/proposal is refused before a grant exists.
    func issue(access: MediaProjectAccess, projectID: UUID, proposalID: UUID,
               revision: Int64, now: Date = Date()) async throws -> String {
        let session: G09R2MediaToolSession
        do {
            session = try await G09R2MediaToolAccess.authorize(
                service: service, mailbox: mailbox, access: access,
                projectID: projectID, requireWritable: true)
        } catch {
            throw G09R2MediaToolAccess.floError(error)
        }
        guard session.project.revision == revision else {
            throw G09R2MediaToolFailure.projectChanged.floError
        }
        guard let proposal = try await proposals.load(id: proposalID, session: session),
              proposal.projectID == projectID,
              proposal.baseRevision == revision else {
            throw G09R2MediaToolFailure.proposalMissing.floError
        }
        let grant = await store.issueGrant(
            projectID: projectID, proposalID: proposalID, revision: revision,
            now: now)
        return grant.grantID
    }

    /// Host-only issuance for the ONE pinned task/project association. The
    /// request names an existing stored proposal; the session has already
    /// re-authorized the real task/workspace/environment and is bound to the
    /// exact project/revision. The original single-use store remains the only
    /// grant authority; the model never reaches this method.
    func issue(session: G09R2MediaToolSession, proposalID: UUID,
               revision: Int64, now: Date = Date()) async throws -> String {
        guard session.bindingID != nil else {
            throw G09R2MediaTaskBindingFailure.bindingMissing.floError
        }
        guard session.project.revision == revision else {
            throw G09R2MediaTaskBindingFailure.projectChanged.floError
        }
        guard let proposal = try await proposals.load(id: proposalID, session: session),
              proposal.projectID == session.project.id,
              proposal.baseRevision == revision else {
            throw G09R2MediaTaskBindingFailure.proposalMissing.floError
        }
        let grant = await store.issueGrant(
            projectID: session.project.id, proposalID: proposalID,
            revision: revision, now: now)
        return grant.grantID
    }

    func consume(grantID: String, projectID: UUID, proposalID: UUID,
                 revision: Int64, now: Date = Date()) async -> MediaGrantDecision {
        await store.consume(grantID: grantID, projectID: projectID,
                            proposalID: proposalID, revision: revision, now: now)
    }
}
