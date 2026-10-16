// FloeApp — Concrete owner adapters for the shared design workflow.
//
// These are FUNCTIONAL adapters over the existing storage and permission
// services — not placeholders:
//
// - AppWorkspaceFilePort resolves a workspace-scoped file through the
//   durable WorkspaceStore bookmark and the SAME WorkspacePathGuard /
//   WorkspaceFileService the workspace tools use (containment, secret-name
//   denial and size caps included).
// - AppChatAttachmentPort resolves the ORIGINAL task's attachment through
//   ConversationStore + FilesCenter (application-support staging or
//   security-scoped bookmark), verifies bytes against the recorded digest,
//   and never mutates or deletes the attachment.
// - AppCreativeDocumentPort resolves an existing creative creation target
//   through CreativeAssetStore and the shared artifact root.
// - AppCanvasDesignContentPort reads the real current node content (text,
//   built-in typed card, retained asset or bound CAD/Office document) for
//   the retained Canvas owner adapter.
// - ArtifactDesignOwnerStore is the owner-CAS for non-canvas design state,
//   persisted under the existing artifact authority (namespace
//   DesignRevisions/owners), content-keyed per target, with atomic
//   stage/replace and revision compare-and-swap.
//
// Composition (constructing these with AppEnvironment's existing services)
// is T6 wiring; this file invents no persistence, downloader, approval or
// runtime.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import UIKit
import UniformTypeIdentifiers
import FloeCore
import FloeTools
import FloeModels
import FloePersistence
import FloeWorkspace

// MARK: - Workspace files

struct AppWorkspaceFilePort: DesignWorkspaceFilePort {
    /// Upper bound for design-source reads. Matches the design proposal
    /// tool's 64 MiB source cap and is enforced BEFORE bytes are loaded, so
    /// a large media file can never be pulled whole into model context.
    static let maxSourceBytes = 64 * 1024 * 1024

    let workspaceStore: any WorkspaceStore
    /// Resolves the task a RUN belongs to. A run may only read files from
    /// the workspace linked to its task; unknown runs fail closed.
    var runTaskBinding: (@MainActor @Sendable (UUID) async -> UUID?)?

    func resolve(
        workspaceID: String,
        reference: String,
        environmentID: String?,
        runID: UUID?
    ) async throws -> DesignResolvedFile {
        let (record, root) = try await resolveWorkspace(workspaceID)
        try await requireRunWorkspace(runID: runID, workspaceID: record.id)
        let accessing = root.startAccessingSecurityScopedResource()
        defer { if accessing { root.stopAccessingSecurityScopedResource() } }
        let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
        let metadata = try service.metadata(reference)
        guard metadata.size <= Self.maxSourceBytes else {
            throw DesignTargetError.unverifiable(
                "Workspace file '\(reference)' is \(metadata.size) bytes; design sources are capped at \(Self.maxSourceBytes)"
            )
        }
        // Read through the same guard (size caps, secret denial,
        // containment). Binary-capable full read.
        let url = try WorkspacePathGuard(rootURL: root).resolve(reference)
        let data = try Data(floeContentsOf: url, options: [.mappedIfSafe])
        let actual = FloeDigest.sha256Hex(data)
        guard Int64(data.count) <= Self.maxSourceBytes else {
            throw DesignTargetError.unverifiable(
                "Workspace file '\(reference)' exceeds the \(Self.maxSourceBytes)-byte design source cap"
            )
        }
        guard actual == metadata.sha256.lowercased() else {
            throw DesignTargetError.unverifiable(
                "Workspace file '\(reference)' digest changed since its metadata was read"
            )
        }
        let format = (reference as NSString).pathExtension.lowercased()
        guard !format.isEmpty else {
            throw DesignTargetError.unverifiable("Workspace file '\(reference)' has no format extension")
        }
        return DesignResolvedFile(
            data: data,
            format: format,
            displayName: (reference as NSString).lastPathComponent,
            contentSHA256: actual,
            baseRevisionToken: "workspace:\(record.id.uuidString.lowercased()):sha:\(actual):mtime:\(Int64(metadata.mtime))",
            allowsInPlaceUpdate: true
        )
    }

    func isAuthorized(
        workspaceID: String,
        reference: String,
        environmentID: String?,
        runID: UUID?
    ) async -> Bool {
        guard let workspaceUUID = UUID(uuidString: workspaceID),
              let record = try? await workspaceStore.workspace(id: workspaceUUID),
              let root = try? Self.resolveRoot(record) else { return false }
        // LIVE run→task→workspace binding: a run may only touch files in
        // the workspace its own task owns. Fail closed when unknown.
        guard await runWorkspaceAllowed(runID: runID, workspaceID: record.id) else { return false }
        // The exact same containment/secret rules as workspace tools.
        let guardResolver = WorkspacePathGuard(rootURL: root)
        let accessing = root.startAccessingSecurityScopedResource()
        defer { if accessing { root.stopAccessingSecurityScopedResource() } }
        guard (try? guardResolver.resolve(reference)) != nil else { return false }
        return (try? serviceMetadata(root: root, reference: reference)) != nil
    }

    func exists(workspaceID: String, reference: String, environmentID: String?) async -> Bool {
        guard let (_, root) = try? await resolveWorkspace(workspaceID) else { return false }
        let accessing = root.startAccessingSecurityScopedResource()
        defer { if accessing { root.stopAccessingSecurityScopedResource() } }
        return (try? serviceMetadata(root: root, reference: reference)) != nil
    }

    private func serviceMetadata(root: URL, reference: String) throws -> WorkspaceFileMetadata {
        try WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)).metadata(reference)
    }

    private func requireRunWorkspace(runID: UUID?, workspaceID: UUID) async throws {
        guard await runWorkspaceAllowed(runID: runID, workspaceID: workspaceID) else {
            throw DesignTargetError.notAuthorized(
                "the run's task does not own this workspace"
            )
        }
    }

    /// True when trusted UI (nil run) or the run's task is linked to the
    /// workspace through the durable conversation↔workspace mapping.
    private func runWorkspaceAllowed(runID: UUID?, workspaceID: UUID) async -> Bool {
        guard let runID else { return true }
        guard let binding = runTaskBinding,
              let task = await binding(runID) else { return false }
        guard let linked = try? await workspaceStore.workspaceID(conversationID: task) else { return false }
        return linked.uuidString.caseInsensitiveCompare(workspaceID.uuidString) == .orderedSame
    }

    private func resolveWorkspace(_ workspaceID: String) async throws -> (WorkspaceRecord, URL) {
        guard let workspaceUUID = UUID(uuidString: workspaceID) else {
            throw DesignTargetError.invalidReference("workspace id is not a UUID: \(workspaceID)")
        }
        guard let record = try await workspaceStore.workspace(id: workspaceUUID) else {
            throw DesignTargetError.notFound("workspace \(workspaceID) does not exist")
        }
        return (record, try Self.resolveRoot(record))
    }

    static func resolveRoot(_ record: WorkspaceRecord, applicationSupportURL: URL? = nil) throws -> URL {
        if record.kind == .privateTask {
            guard let relative = record.internalRelativePath else {
                throw DesignTargetError.invalidReference("Missing private workspace path")
            }
            let components = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count == 2, components[0] == "PrivateTasks",
                  UUID(uuidString: String(components[1])) != nil else {
                throw DesignTargetError.invalidReference("Invalid private workspace path")
            }
            let support = try applicationSupportURL ?? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false)
            let base = support.resolvingSymlinksInPath()
                .appendingPathComponent("FloeAgent/PrivateTasks", isDirectory: true).standardizedFileURL
            let root = base.appendingPathComponent(String(components[1]), isDirectory: true)
            // Directory URL flags/trailing slashes can differ for a not-yet-
            // created task directory. Compare canonical filesystem paths.
            guard base.resolvingSymlinksInPath().path == base.path,
                  root.resolvingSymlinksInPath().path == root.path else {
                throw DesignTargetError.invalidReference("Invalid private workspace location")
            }
            return root
        }
        var isStale = false
        return try URL(
            resolvingBookmarkData: record.rootBookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }
}

// MARK: - Chat attachments

struct AppChatAttachmentPort: DesignChatAttachmentPort {
    let conversationStore: any ConversationStore
    /// Resolves an attachment reference to a readable file URL. Production
    /// wires `FilesCenter.resolveURL(for:)`; tests inject an inline resolver.
    let resolveURL: @MainActor @Sendable (AttachmentRef) throws -> URL
    /// Resolves the task a RUN belongs to through the existing run-context
    /// store (`CanvasRunContextStore`). When a run is present, the
    /// attachment's task must equal the run's task or the request fails
    /// closed. nil (trusted in-app UI / tests) skips only the run binding,
    /// never the attachment-ownership check.
    var runTaskBinding: (@MainActor @Sendable (UUID) async -> UUID?)?

    func resolveAttachment(
        conversationID: String,
        messageID: String,
        attachmentID: String,
        runID: UUID?
    ) async throws -> DesignChatAttachment {
        guard let conversationUUID = UUID(uuidString: conversationID) else {
            throw DesignTargetError.invalidReference("conversation id is not a UUID")
        }
        try await requireRunTaskBinding(runID: runID, conversationID: conversationUUID)
        let attachments = try await conversationStore.attachments(conversationID: conversationUUID)
        guard let attachment = attachments.first(where: { ref in
            ref.id.uuidString.caseInsensitiveCompare(attachmentID) == .orderedSame
        }) else {
            throw DesignTargetError.notFound("attachment \(attachmentID) is not attached to the original task")
        }
        if let recordedConversation = attachment.conversationID,
           recordedConversation.uuidString.caseInsensitiveCompare(conversationID) != .orderedSame {
            throw DesignTargetError.notAuthorized("attachment belongs to a different task")
        }
        if !messageID.isEmpty,
           let recordedMessage = attachment.messageID?.uuidString,
           recordedMessage.caseInsensitiveCompare(messageID) != .orderedSame {
            throw DesignTargetError.notAuthorized("attachment is bound to a different message")
        }
        let url = try await resolveURL(attachment)
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        // Enforce the source-size bound BEFORE loading, using the recorded
        // byte count and re-checking the actual read length.
        guard attachment.byteCount <= AppWorkspaceFilePort.maxSourceBytes else {
            throw DesignTargetError.unverifiable(
                "attachment \(attachmentID) exceeds the \(AppWorkspaceFilePort.maxSourceBytes)-byte design source cap"
            )
        }
        let data = try Data(floeContentsOf: url, options: [.mappedIfSafe])
        guard !data.isEmpty else {
            throw DesignTargetError.unverifiable("attachment \(attachmentID) is empty")
        }
        guard data.count <= AppWorkspaceFilePort.maxSourceBytes else {
            throw DesignTargetError.unverifiable(
                "attachment \(attachmentID) exceeds the \(AppWorkspaceFilePort.maxSourceBytes)-byte design source cap"
            )
        }
        let actual = FloeDigest.sha256Hex(data)
        if !attachment.sha256.isEmpty, actual != attachment.sha256.lowercased() {
            throw DesignTargetError.unverifiable("attachment digest changed on disk")
        }
        let format = (attachment.displayName as NSString).pathExtension.lowercased()
        guard !format.isEmpty else {
            throw DesignTargetError.unverifiable("attachment has no format extension")
        }
        return DesignChatAttachment(
            data: data,
            format: format,
            displayName: attachment.displayName,
            contentSHA256: actual,
            baseRevisionToken: "attachment:\(attachment.id.uuidString.lowercased()):sha:\(actual)",
            conversationID: attachment.conversationID?.uuidString ?? conversationID
        )
    }

    /// Metadata/ownership probe used by the live boundary authorization.
    func attachmentIsAccessible(
        conversationID: String,
        messageID: String,
        attachmentID: String,
        runID: UUID?
    ) async -> Bool {
        guard let conversationUUID = UUID(uuidString: conversationID) else { return false }
        do {
            try await requireRunTaskBinding(runID: runID, conversationID: conversationUUID)
        } catch {
            return false
        }
        guard let attachments = try? await conversationStore.attachments(conversationID: conversationUUID) else {
            return false
        }
        guard let attachment = attachments.first(where: {
            $0.id.uuidString.caseInsensitiveCompare(attachmentID) == .orderedSame
        }) else { return false }
        if let recordedConversation = attachment.conversationID,
           recordedConversation.uuidString.caseInsensitiveCompare(conversationID) != .orderedSame {
            return false
        }
        if !messageID.isEmpty,
           let recordedMessage = attachment.messageID?.uuidString,
           recordedMessage.caseInsensitiveCompare(messageID) != .orderedSame {
            return false
        }
        return true
    }

    private func requireRunTaskBinding(runID: UUID?, conversationID: UUID) async throws {
        guard let runID else { return } // Trusted in-app UI.
        guard let binding = runTaskBinding else {
            throw DesignTargetError.notAuthorized(
                "run task binding is not configured; refusing attachment access for run \(runID.uuidString.lowercased())"
            )
        }
        guard let task = await binding(runID) else {
            throw DesignTargetError.notAuthorized("run is not bound to any task")
        }
        guard task.uuidString.caseInsensitiveCompare(conversationID.uuidString) == .orderedSame else {
            throw DesignTargetError.notAuthorized(
                "run belongs to a different task than the attachment"
            )
        }
    }
}

// MARK: - Creative creation target

struct AppCreativeDocumentPort: DesignCreativeDocumentPort {
    let assetStore: CreativeAssetStore
    /// Root for `CreativeAssetRecord.localRelativePath` resolution;
    /// production passes FloeArtifactStore.root().
    let artifactRoot: @MainActor @Sendable () throws -> URL
    /// Shared owner-envelope store holding the pre-material request and its
    /// bound first result (the SAME store the workflow uses; no parallel
    /// request store). nil disables the pending-request flow only.
    var envelopes: ArtifactDesignOwnerStore?
    /// Resolves the task a RUN belongs to through the durable run store. A run
    /// may only touch a creative request/asset linked to its own task: the
    /// request owner IS that task, or the shared owner envelope recorded that
    /// task as the request origin. Unknown runs and unknown linkage fail
    /// closed. Trusted UI (nil run) is the in-app user.
    var runTaskBinding: (@MainActor @Sendable (UUID) async -> UUID?)?
    /// Durable generation linkage: true only when the exact asset is the
    /// committed local result of a media job submitted by this run (or owned
    /// by the run's own task). This is a REAL stored job→asset link, never a
    /// claimed owner string.
    var generatedAssetLink: (@MainActor @Sendable (UUID, UUID, UUID) async -> Bool)?

    func resolve(
        ownerID: String,
        creationID: String,
        environmentID: String?,
        runID: UUID?
    ) async throws -> DesignResolvedFile {
        if let runID {
            // Material READ for a run requires a REAL stored link. A model
            // cannot present its own task as the owner and then read an
            // arbitrary foreign asset id: the owner claim alone proves
            // nothing about where the bytes came from.
            guard await materialIsLinked(
                ownerID: ownerID, reference: creationID,
                environmentID: environmentID, runID: runID) else {
                throw DesignTargetError.notAuthorized(
                    "the creative asset is not linked to the run's own task")
            }
        }
        return try await Self.resolveVerifiedAssetBytes(
            assetStore: assetStore, artifactRoot: artifactRoot,
            creationID: creationID)
    }

    func requestIsAuthorized(
        ownerID: String,
        requestID: String,
        environmentID: String?,
        runID: UUID?
    ) async -> Bool {
        // Trusted UI: the user acting in-app.
        guard let runID else { return true }
        guard let runTask = await runTask(for: runID) else { return false }
        // The explicitly approved owner-task namespace for a not-yet-
        // materialized request: the run may begin/continue a creative request
        // under its OWN task identity. It grants no access to existing bytes;
        // material reads/binds go through `materialIsLinked` below.
        if ownerID.caseInsensitiveCompare(runTask.uuidString) == .orderedSame {
            return true
        }
        return await envelopeLinksTask(
            reference: requestID, environmentID: environmentID, task: runTask)
    }

    /// The ONE ownership rule for existing creative material: the asset/
    /// request must be linked to the run's OWN durable task through a real
    /// record — a media generation job that produced/owns the asset, or a
    /// persisted owner envelope whose bound first result IS this reference
    /// and whose origin is the run's task. No private grant store, no blanket
    /// allow, no claimed owner string, and NOT the request's model-authored
    /// source identity (a run could otherwise name a foreign asset as its
    /// request source and read it circularly).
    private func materialIsLinked(
        ownerID: String,
        reference: String,
        environmentID: String?,
        runID: UUID
    ) async -> Bool {
        guard let runTask = await runTask(for: runID) else { return false }
        // 1) Durable job origin: the exact asset was committed as the local
        //    result of a job this run submitted (or one owned by the task).
        if let assetUUID = UUID(uuidString: reference),
           let assetLink = generatedAssetLink,
           await assetLink(assetUUID, runID, runTask) {
            return true
        }
        guard let envelopes else { return false }
        // 2) A REAL stored owner envelope whose STRICTLY BOUND first result is
        //    this exact reference, recorded under the run's own task. The
        //    request's `sourceID` is deliberately NOT accepted: it is
        //    model-authored at `creativeBegin` time, so trusting it would let
        //    a run read any existing asset it merely named.
        //
        //    The persisted binding is ALSO not proof by itself: bindings
        //    written before the first-result authority gate existed could
        //    have been authored by a model. Only trusted-UI provenance (an
        //    explicit in-app selection for THIS task) is accepted here, and
        //    its recorded digest must still match the live asset record. A
        //    job-linked binding was already accepted by the live check
        //    above; a revoked job fails closed here instead of falling back
        //    to the envelope.
        for envelope in await envelopes.envelopes(matchingReference: reference) {
            guard let request = envelope.project.creativeRequest,
                  let origin = request.originConversationID,
                  origin.caseInsensitiveCompare(runTask.uuidString) == .orderedSame,
                  request.state == .firstResultBound,
                  request.boundResultID == reference else { continue }
            guard envelope.creativeFirstResultProvenance == .trustedUIManualImport else { continue }
            guard let recorded = request.boundContentSHA256, !recorded.isEmpty,
                  await assetRecordDigest(reference) == recorded.lowercased() else { continue }
            return true
        }
        return false
    }

    /// The stored content hash for a creative asset id, without reading the
    /// (potentially large) file. The subsequent verified resolve re-checks
    /// the actual bytes against this record.
    private func assetRecordDigest(_ creationID: String) async -> String? {
        guard let uuid = UUID(uuidString: creationID),
              let record = try? await assetStore.asset(id: uuid) else { return nil }
        return record.contentHash.lowercased()
    }

    /// Pending-request linkage: a stored envelope records this task as the
    /// request origin (used by `requestIsAuthorized`). The identity fields are
    /// matched against what is STORED — never a guessed output kind.
    private func envelopeLinksTask(
        reference: String,
        environmentID: String?,
        task: UUID
    ) async -> Bool {
        guard let envelopes else { return false }
        for envelope in await envelopes.envelopes(matchingReference: reference) {
            guard let request = envelope.project.creativeRequest,
                  let origin = request.originConversationID,
                  origin.caseInsensitiveCompare(task.uuidString) == .orderedSame else { continue }
            guard request.state == .awaitingFirstResult
                    || request.boundResultID == reference
                    || envelope.target.sourceID == reference else { continue }
            return true
        }
        return false
    }

    private func runTask(for runID: UUID) async -> UUID? {
        guard let runTaskBinding else { return nil }
        return await runTaskBinding(runID)
    }

    func boundResult(
        targetKey: String,
        ownerID: String,
        requestID: String,
        environmentID: String?,
        runID: UUID?
    ) async throws -> DesignResolvedFile? {
        guard let envelopes,
              let envelope = try await envelopes.load(targetKey: targetKey),
              let request = envelope.project.creativeRequest,
              request.state == .firstResultBound,
              let boundID = request.boundResultID else { return nil }
        let resolved = try await Self.resolveVerifiedAssetBytes(
            assetStore: assetStore, artifactRoot: artifactRoot,
            creationID: boundID)
        // The retained bytes must still BE the recorded first result: a
        // binding whose recorded digest/format do not match the live asset
        // (e.g. a pre-gate model-authored record) fails closed here instead
        // of silently returning those bytes.
        guard let recorded = request.boundContentSHA256, !recorded.isEmpty,
              resolved.contentSHA256.caseInsensitiveCompare(recorded) == .orderedSame else {
            throw DesignTargetError.unverifiable(
                "the retained asset no longer matches the recorded first-result digest")
        }
        if let boundFormat = request.boundFormat, !boundFormat.isEmpty,
           boundFormat.caseInsensitiveCompare(resolved.format) != .orderedSame {
            throw DesignTargetError.unverifiable(
                "the retained asset format no longer matches the recorded first result")
        }
        if let runID {
            // A RUN needs verified provenance for its OWN task: trusted-UI
            // provenance or a LIVE durable job link. A legacy binding that
            // merely records a boundResultID is never authority, and a
            // revoked/foreign job loses it.
            guard let runTask = await runTask(for: runID) else {
                throw DesignTargetError.notAuthorized("run is not bound to any task")
            }
            let ownerMatches = ownerID.caseInsensitiveCompare(runTask.uuidString) == .orderedSame
            let originMatches = request.originConversationID?
                .caseInsensitiveCompare(runTask.uuidString) == .orderedSame
            guard ownerMatches || originMatches else {
                throw DesignTargetError.notAuthorized(
                    "the creative request belongs to a different task")
            }
            switch envelope.creativeFirstResultProvenance {
            case .trustedUIManualImport:
                break
            case .generationJob:
                guard let assetUUID = UUID(uuidString: boundID),
                      let generatedAssetLink,
                      await generatedAssetLink(assetUUID, runID, runTask) else {
                    throw DesignTargetError.notAuthorized(
                        "the bound result's durable generation link is no longer held by the run's task")
                }
            case nil:
                throw DesignTargetError.notAuthorized(
                    "the creative first-result binding has no verified provenance")
            }
        }
        return resolved
    }

    /// The ONE pre-effect verification for a creative first-result binding:
    /// the named result must resolve to the REAL retained asset (row +
    /// contained file, real on-disk cap before any read, digest verified),
    /// and the proposed payload must BE that asset. For a run the asset must
    /// also be linked to the run's own task through the durable media
    /// generation job→asset record — never a claimed owner string.
    func verifyFirstResultBinding(
        ownerID: String,
        requestID: String,
        environmentID: String?,
        boundResultID: String,
        bytes: Data,
        format: String,
        runID: UUID?
    ) async throws -> DesignCreativeResultProvenance {
        guard let assetUUID = UUID(uuidString: boundResultID) else {
            throw DesignTargetError.invalidReference(
                "boundResultID is not a creative asset UUID")
        }
        let resolved = try await Self.resolveVerifiedAssetBytes(
            assetStore: assetStore, artifactRoot: artifactRoot,
            creationID: boundResultID)
        // The proposed payload must BE the asset — not a different payload
        // that merely names it.
        guard resolved.data == bytes else {
            throw DesignTargetError.unverifiable(
                "the proposed first-result bytes are not the retained creative asset \(boundResultID)")
        }
        guard resolved.format.caseInsensitiveCompare(format) == .orderedSame else {
            throw DesignTargetError.unverifiable(
                "the proposed first-result format '\(format)' is not the retained asset format '\(resolved.format)'")
        }
        guard let runID else {
            // Trusted in-app UI: the user explicitly selected/imported this
            // REAL retained asset. The verification above is what makes the
            // recorded provenance authoritative.
            return .trustedUIManualImport
        }
        guard let runTask = await runTask(for: runID) else {
            throw DesignTargetError.notAuthorized("run is not bound to any task")
        }
        guard let generatedAssetLink else {
            throw DesignTargetError.notAuthorized(
                "no durable job→asset verification is connected")
        }
        guard await generatedAssetLink(assetUUID, runID, runTask) else {
            throw DesignTargetError.notAuthorized(
                "the bound creative asset is not the committed result of a durable job owned by the run's task")
        }
        return .generationJob
    }

    /// Resolves a creative asset's verified bytes through the existing
    /// content-addressed store. The encoded byte cap is enforced on the REAL
    /// on-disk file size BEFORE any read (a recorded `byteCount` may be stale
    /// or wrong), the path is contained under the artifact root, and the read
    /// bytes are digest-verified against the stored content hash.
    static func resolveVerifiedAssetBytes(
        assetStore: CreativeAssetStore,
        artifactRoot: @MainActor @Sendable () throws -> URL,
        creationID: String
    ) async throws -> DesignResolvedFile {
        guard let assetUUID = UUID(uuidString: creationID) else {
            throw DesignTargetError.invalidReference("creative creation id is not a UUID")
        }
        guard let record = try await assetStore.asset(id: assetUUID) else {
            throw DesignTargetError.notFound("creative asset \(creationID) does not exist")
        }
        guard let relative = record.localRelativePath, !relative.isEmpty else {
            throw DesignTargetError.notFound("creative asset \(creationID) has no local bytes (cloud-only)")
        }
        let root = try await artifactRoot()
        let components = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.contains(where: { $0 == ".." || $0 == "." }) else {
            throw DesignTargetError.unverifiable("creative asset path escapes the artifact root")
        }
        let containedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = components.reduce(containedRoot) { $0.appendingPathComponent($1) }
            .standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(containedRoot.path + "/") else {
            throw DesignTargetError.unverifiable("creative asset path is outside the artifact root")
        }
        // Enforce the source cap against the ACTUAL file before reading.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let fileSize = (attributes[.size] as? NSNumber)?.int64Value else {
            throw DesignTargetError.notFound("creative asset \(creationID) has no readable local file")
        }
        guard fileSize <= Int64(AppWorkspaceFilePort.maxSourceBytes) else {
            throw DesignTargetError.unverifiable(
                "creative asset \(creationID) exceeds the \(AppWorkspaceFilePort.maxSourceBytes)-byte design source cap"
            )
        }
        let data = try Data(floeContentsOf: url, options: [.mappedIfSafe])
        guard data.count <= AppWorkspaceFilePort.maxSourceBytes else {
            throw DesignTargetError.unverifiable(
                "creative asset \(creationID) exceeds the \(AppWorkspaceFilePort.maxSourceBytes)-byte design source cap"
            )
        }
        let actual = FloeDigest.sha256Hex(data)
        guard actual == record.contentHash.lowercased() else {
            throw DesignTargetError.unverifiable("creative asset bytes do not match their recorded content hash")
        }
        let format = (relative as NSString).pathExtension.lowercased()
        guard !format.isEmpty else {
            throw DesignTargetError.unverifiable("creative asset has no format extension")
        }
        return DesignResolvedFile(
            data: data,
            format: format,
            displayName: record.displayName,
            contentSHA256: actual,
            // Creative assets are content-addressed: the "revision" is the
            // asset id plus its content hash. A new edit is a NEW asset, so
            // in-place update stays false; the shared owner workflow adopts
            // by retaining its own revision and (T6 wiring) creating the
            // next creative asset version.
            baseRevisionToken: "creative:\(record.id.uuidString.lowercased()):sha:\(actual)",
            allowsInPlaceUpdate: false
        )
    }
}

// MARK: - Canvas node content reader

/// Read-only port that produces the real current content of a Canvas node,
/// using the same source rules as `DesignWorkflowActions.useCurrentNode` but
/// never mutating anything: text/sticky body, typed built-in card
/// (markdown/html/svg), retained asset bytes, or the bound CAD/Office
/// workspace document.
struct AppCanvasDesignContentPort: DesignCanvasContentPort {
    func readNode(
        canvasID: UUID,
        nodeID: UUID,
        snapshot: DesignCanvasService.Snapshot
    ) async throws -> DesignResolvedFile {
        guard let node = snapshot.node else {
            throw DesignTargetError.notFound("canvas node is missing from the snapshot")
        }
        return try await Self.read(canvasID: canvasID, node: node, design: snapshot.design)
    }

    /// Pure read of the node's verified current bytes. Shared by the owner
    /// adapter; mirrors (does not replace) `useCurrentNode`'s source rules.
    static func read(
        canvasID: UUID,
        node: CanvasNode,
        design: DesignProject?
    ) async throws -> DesignResolvedFile {
        let builtinPlugin = node.metadata[DesignContentTypeMapper.builtinPluginMetadataKey]
        let isTextBodyBuiltin = builtinPlugin
            .map { DesignContentTypeMapper.textBodyBuiltinPlugins.contains($0) } ?? false
        let contentType = DesignContentTypeMapper.effectiveContentType(
            existing: design?.contentType, kind: node.kind, metadata: node.metadata
        )

        switch node.kind {
        case .text, .stickyNote:
            let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw DesignTargetError.notFound("node has no text content")
            }
            let format = contentType == .notes ? "md" : "txt"
            return file(Data(node.text.utf8), format: format, name: node.title ?? "node-text")
        case .card where isTextBodyBuiltin:
            let pluginID = builtinPlugin!
            let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw DesignTargetError.notFound("built-in \(pluginID) card is empty")
            }
            guard let format = DesignContentTypeMapper.builtinPluginFormat(pluginID),
                  DesignContentTypeMapper.builtinPluginContentType(pluginID) == contentType else {
                throw DesignTargetError.unavailable("unsupported built-in plugin '\(pluginID)'")
            }
            return file(Data(node.text.utf8), format: format, name: node.title ?? "builtin-\(pluginID)")
        case .image, .video, .file, .audio:
            if let result = try assetBytes(node: node) { return result }
            fallthrough
        case .scene3D, .card, .shape, .group, .generationTask:
            if let design,
               let binding = try DesignWorkspace.canonicalBinding(
                   design.workspaceBinding, canvasID: canvasID, nodeID: node.id
               ) {
                let url = URL(fileURLWithPath: binding.documentAbsolutePath)
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard !data.isEmpty else {
                    throw DesignTargetError.notFound("bound document is empty")
                }
                return file(data, format: binding.format, name: url.lastPathComponent)
            }
            throw DesignTargetError.notFound("node has no readable design source")
        }
    }

    private static func assetBytes(node: CanvasNode) throws -> DesignResolvedFile? {
        guard let asset = node.asset, let relative = asset.localRelativePath, !relative.isEmpty else {
            return nil
        }
        guard !relative.split(separator: "/").contains("..") else {
            throw DesignTargetError.unverifiable("asset path is unsafe")
        }
        if let recordedBytes = asset.byteCount,
           recordedBytes > Int64(AppWorkspaceFilePort.maxSourceBytes) {
            throw DesignTargetError.unverifiable(
                "node asset exceeds the \(AppWorkspaceFilePort.maxSourceBytes)-byte design source cap"
            )
        }
        let root = try FloeArtifactStore.root()
        let url = root.appendingPathComponent(relative)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard !data.isEmpty else { throw DesignTargetError.unverifiable("asset is empty") }
        guard data.count <= AppWorkspaceFilePort.maxSourceBytes else {
            throw DesignTargetError.unverifiable("node asset exceeds the design source cap on read")
        }
        if let expected = asset.contentHash, !expected.isEmpty {
            guard FloeDigest.sha256Hex(data) == expected.lowercased() else {
                throw DesignTargetError.unverifiable("asset digest mismatch")
            }
        }
        let ext = (relative as NSString).pathExtension.lowercased()
        let format = ext.isEmpty ? "bin" : ext
        return file(data, format: format, name: asset.sourceURL?.lastPathComponent ?? (node.title ?? "asset"))
    }

    private static func file(_ data: Data, format: String, name: String) -> DesignResolvedFile {
        DesignResolvedFile(
            data: data,
            format: format,
            displayName: name,
            contentSHA256: FloeDigest.sha256Hex(data),
            baseRevisionToken: "sha:\(FloeDigest.sha256Hex(data))",
            allowsInPlaceUpdate: true
        )
    }
}

// MARK: - Owner envelope store on the shared artifact authority

/// Revision payloads for non-canvas targets, under the EXISTING artifact
/// authority root at
/// `DesignRevisions/owners/<targetKey>/revisions/<revisionID>.payload`.
/// Same immutable, hash-verified discipline as
/// `DesignRevisionPayloadStore`; the owner key is always the target's
/// SHA-256 stable key (never an opaque workspace id or relative path).
final class ArtifactOwnerPayloadStore: DesignOwnerPayloadStore, @unchecked Sendable {
    private let root: URL
    private let lock = NSRecursiveLock()
    static let maxPayloadBytes = 256 * 1024 * 1024

    init(root: URL? = nil) {
        let base = root ?? ((try? FloeArtifactStore.root()) ?? FileManager.default.temporaryDirectory)
        self.root = base
            .appendingPathComponent("DesignRevisions", isDirectory: true)
            .appendingPathComponent("owners", isDirectory: true)
    }

    private func revisionURL(ownerKey: String, revisionID: String) throws -> URL {
        guard ownerKey.count == 64, ownerKey.allSatisfy({ $0.isHexDigit }) else {
            throw FloeError.validationFailed("invalid design owner key")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard !revisionID.isEmpty, revisionID.count <= 64,
              revisionID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw FloeError.validationFailed("invalid revision id")
        }
        return root
            .appendingPathComponent(ownerKey, isDirectory: true)
            .appendingPathComponent("revisions", isDirectory: true)
            .appendingPathComponent("\(revisionID).payload")
    }

    func store(
        ownerKey: String,
        revisionID: String,
        bytes: Data,
        expectedContentSHA256: String
    ) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard bytes.count <= Self.maxPayloadBytes else {
            throw FloeError.validationFailed("payload exceeds the design owner cap")
        }
        let digest = FloeDigest.sha256Hex(bytes)
        guard digest == expectedContentSHA256.lowercased() else {
            throw FloeError.validationFailed("payload bytes do not match the recorded digest")
        }
        let target = try revisionURL(ownerKey: ownerKey, revisionID: revisionID)
        if FileManager.default.fileExists(atPath: target.path) {
            // Immutable replay: same bytes is a no-op; different bytes conflict.
            let existing = try FloeDigest.sha256Hex(ofFileAt: target)
            guard existing == digest else {
                throw FloeError.validationFailed("owner revision \(revisionID) already exists with different bytes")
            }
            return relativePath(ownerKey: ownerKey, revisionID: revisionID)
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString.lowercased()).staging")
        try bytes.write(to: staging, options: .atomic)
        guard (try? FloeDigest.sha256Hex(ofFileAt: staging)) == digest else {
            try? FileManager.default.removeItem(at: staging)
            throw FloeError.storageCorrupted("staged owner payload failed verification")
        }
        try FileManager.default.moveItem(at: staging, to: target)
        return relativePath(ownerKey: ownerKey, revisionID: revisionID)
    }

    func verifiedBytes(
        ownerKey: String,
        revisionID: String,
        expectedContentSHA256: String
    ) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let url = try revisionURL(ownerKey: ownerKey, revisionID: revisionID)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard FloeDigest.sha256Hex(data) == expectedContentSHA256.lowercased() else {
            throw FloeError.storageCorrupted("owner payload digest changed on disk")
        }
        return data
    }

    func abandon(ownerKey: String, revisionID: String) {
        try? lock.lock(); defer { lock.unlock() }
        guard let url = try? revisionURL(ownerKey: ownerKey, revisionID: revisionID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func relativePath(ownerKey: String, revisionID: String) -> String {
        "DesignRevisions/owners/\(ownerKey)/revisions/\(revisionID).payload"
    }
}

/// Commits adopted bytes back to an in-place workspace file through the
/// existing `WorkspaceFileService` optimistic-concurrency write (mtime/SHA
/// gate). Chat attachments and content-addressed creative assets are NOT
/// committed by design.
///
/// Failure classification is part of the contract: a gate failure BEFORE any
/// write throws `DesignOwnerCommitError.notWritten` (the durable intent may
/// be cancelled); an I/O failure or a failed post-write readback throws
/// `.unknown` (the bytes may have landed; the durable intent MUST be kept
/// for reconcile). The write is verified by re-reading the file from disk.
struct WorkspaceFileOwnerCommitPort: DesignOwnerCommitPort {
    let workspaceStore: any WorkspaceStore

    func canCommit(_ target: DesignTarget) -> Bool {
        target.kind == .fileDocument
    }

    /// Extracts the frozen SHA from a base token
    /// ("workspace:<id>:sha:<hex>:mtime:<…>").
    static func frozenSHA(from token: String) -> String? {
        let components = token.components(separatedBy: ":")
        guard let shaIndex = components.firstIndex(of: "sha"),
              shaIndex + 1 < components.count else { return nil }
        return components[shaIndex + 1]
    }

    private func resolveService(_ target: DesignTarget) async throws -> (uuid: UUID, root: URL, service: WorkspaceFileService) {
        guard target.kind == .fileDocument,
              let workspaceUUID = UUID(uuidString: target.ownerID),
              let record = try await workspaceStore.workspace(id: workspaceUUID) else {
            throw DesignOwnerCommitError.notWritten("the workspace source no longer exists")
        }
        let root = try AppWorkspaceFilePort.resolveRoot(record)
        return (record.id, root, WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)))
    }

    func commit(
        target: DesignTarget,
        reference: String,
        bytes: Data,
        format: String,
        baseRevisionToken: String
    ) async throws -> String {
        let (workspaceUUID, root, service) = try await resolveService(target)
        let accessing = root.startAccessingSecurityScopedResource()
        defer { if accessing { root.stopAccessingSecurityScopedResource() } }
        // Optimistic gate BEFORE any write: the file's current digest must
        // match the frozen base, OR already equal the proposed bytes
        // (a previous attempt committed the file but crashed before the
        // envelope CAS — retry must converge, never double-write or fail).
        // A token without a frozen digest fails closed (no ungated
        // overwrite). WorkspaceMutationLocks serializes writers per root,
        // so a concurrent manual edit cannot slip between the metadata read
        // and the atomic overwrite.
        guard let frozenSHA = Self.frozenSHA(from: baseRevisionToken) else {
            throw DesignOwnerCommitError.notWritten(
                "the frozen base token carries no workspace digest; refusing an ungated overwrite"
            )
        }
        let proposedDigest = FloeDigest.sha256Hex(bytes)
        guard let current = try? service.metadata(reference) else {
            throw DesignOwnerCommitError.notWritten("workspace file '\(reference)' moved or was deleted")
        }
        let currentDigest = current.sha256.lowercased()
        if currentDigest == proposedDigest {
            // Crash recovery: this exact adoption already wrote the file.
            return "workspace:\(workspaceUUID.uuidString.lowercased()):sha:\(currentDigest):mtime:\(Int64(current.mtime))"
        }
        guard currentDigest == frozenSHA.lowercased() else {
            throw DesignOwnerCommitError.notWritten(
                "workspace file '\(reference)' changed since the frozen base (frozen \(frozenSHA), now \(currentDigest))"
            )
        }
        let outcome: WriteOutcome
        do {
            outcome = try service.createBinaryFile(reference, data: bytes, overwrite: true)
        } catch {
            // The write may have partially landed: classify as unknown so the
            // durable intent stays pending for reconcile.
            throw DesignOwnerCommitError.unknown(
                "workspace write failed and may have landed: \(error.localizedDescription)"
            )
        }
        guard outcome.sha256.lowercased() == proposedDigest else {
            throw DesignOwnerCommitError.unknown(
                "workspace write reported a different digest than the proposed bytes"
            )
        }
        // READBACK: the bytes actually present at the path must verify before
        // this is reported as committed. Trusting the writer's claim alone is
        // not proof the file landed.
        guard let readback = try? service.metadata(reference),
              readback.sha256.lowercased() == proposedDigest else {
            throw DesignOwnerCommitError.unknown(
                "workspace file readback did not verify the proposed bytes"
            )
        }
        // Protection lifecycle is owned by the DECISION and RUN-END layers,
        // not by the commit port: the verified commit permits exactly these
        // bytes to land once — it never grants the calling run (or any other
        // writer) subsequent direct-write rights. The design.adopt tool and
        // the trusted panel re-establish the approved baseline or release
        // through DesignFreezeProtectionCoordinator, and ConversationCenter
        // lifts the freeze when a completed design run has nothing pending.
        return "workspace:\(workspaceUUID.uuidString.lowercased()):sha:\(readback.sha256.lowercased()):mtime:\(Int64(readback.mtime))"
    }

    /// Reads the CURRENT file (no write) and classifies it for adoption
    /// recovery. A file already carrying the proposed bytes must be
    /// reconciled to completion, never cancelled.
    func verify(
        target: DesignTarget,
        reference: String,
        proposedContentSHA256: String,
        baseRevisionToken: String
    ) async throws -> DesignCommitVerification {
        let (_, root, service) = try await resolveService(target)
        let accessing = root.startAccessingSecurityScopedResource()
        defer { if accessing { root.stopAccessingSecurityScopedResource() } }
        guard let current = try? service.metadata(reference) else { return .missing }
        let digest = current.sha256.lowercased()
        if digest == proposedContentSHA256.lowercased() { return .matchesProposed }
        if let frozen = Self.frozenSHA(from: baseRevisionToken), digest == frozen.lowercased() {
            return .matchesBase
        }
        return .diverged(actualSHA256: digest)
    }
}

// MARK: - Owner envelope store on the shared artifact authority (legacy section)

/// File-backed compare-and-swap store for non-canvas design state:
/// `<artifact root>/DesignRevisions/owners/<targetKey>/project.v<revision>.json`
/// plus `current.json`. The target key is the target's SHA-256 stable key,
/// so no opaque workspace id or relative path ever becomes a path component.
/// Writes are staged, hash-verified and atomically replaced; reads parse
/// through the same tolerant codec, quarantining nothing but refusing to
/// overwrite an unreadable envelope.
public final class ArtifactDesignOwnerStore: DesignOwnerProjectStore, @unchecked Sendable {
    private let root: URL
    private let manager = FileManager.default
    private let lock = NSRecursiveLock()

    public init(root: URL? = nil) {
        self.root = (root ?? ((try? FloeArtifactStore.root()) ?? FileManager.default.temporaryDirectory))
            .appendingPathComponent("DesignRevisions", isDirectory: true)
            .appendingPathComponent("owners", isDirectory: true)
    }

    private func directory(targetKey: String) throws -> URL {
        // targetKey is a SHA-256 hex string from DesignTarget.stableKey;
        // validate defensively.
        guard targetKey.count == 64,
              targetKey.allSatisfy({ $0.isHexDigit }) else {
            throw FloeError.validationFailed("invalid design owner target key")
        }
        return root.appendingPathComponent(targetKey, isDirectory: true)
    }

    private func currentURL(targetKey: String) throws -> URL {
        try directory(targetKey: targetKey).appendingPathComponent("current.json")
    }

    public func load(targetKey: String) async throws -> DesignOwnerEnvelope? {
        try lock.withLock {
            let url = try currentURL(targetKey: targetKey)
            guard manager.fileExists(atPath: url.path) else { return nil }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(DesignOwnerEnvelope.self, from: data)
        }
    }

    /// Every stored owner envelope whose creative request binds this exact
    /// reference as its first result or whose frozen source identity IS this
    /// reference. This reads the REAL persisted identity fields instead of
    /// guessing a requested output kind, and is bounded to the existing
    /// owners directory. Unreadable/corrupt records are skipped: callers
    /// require a positive hit, so a broken file can never widen access.
    public func envelopes(matchingReference reference: String) async -> [DesignOwnerEnvelope] {
        (try? lock.withLock {
            guard let entries = try? manager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
            var matches: [DesignOwnerEnvelope] = []
            for directory in entries.prefix(1024) {
                guard (try? directory.resourceValues(
                    forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let current = directory.appendingPathComponent("current.json")
                guard let data = try? Data(contentsOf: current, options: [.mappedIfSafe]) else { continue }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                guard let envelope = try? decoder.decode(
                    DesignOwnerEnvelope.self, from: data) else { continue }
                let bindsReference = envelope.project.creativeRequest?
                    .boundResultID == reference
                let isSource = envelope.target.sourceID == reference
                if bindsReference || isSource {
                    matches.append(envelope)
                }
            }
            return matches
        }) ?? []
    }

    @discardableResult
    public func save(
        _ envelope: DesignOwnerEnvelope,
        targetKey: String,
        expectedRevision: Int64?
    ) async throws -> Int64 {
        try lock.withLock {
            let directory = try directory(targetKey: targetKey)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let current = try currentURL(targetKey: targetKey)
            if manager.fileExists(atPath: current.path) {
                let data = try Data(contentsOf: current, options: [.mappedIfSafe])
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let existing = try decoder.decode(DesignOwnerEnvelope.self, from: data)
                guard existing.revision == (expectedRevision ?? existing.revision) else {
                    throw FloeError.validationFailed(
                        "Design owner revision conflict: expected \(expectedRevision.map(String.init) ?? "create"), current \(existing.revision)"
                    )
                }
            } else if let expectedRevision, expectedRevision != 0 {
                throw FloeError.validationFailed(
                    "Design owner create expected revision \(expectedRevision) but no envelope exists"
                )
            }
            var next = envelope
            next.revision = (expectedRevision ?? 0) + 1
            next.updatedAt = Date()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let payload = try encoder.encode(next)
            // Stage + verify + atomic replace.
            let staging = directory.appendingPathComponent(".project.\(UUID().uuidString.lowercased()).staging")
            try payload.write(to: staging, options: .atomic)
            let written = try Data(contentsOf: staging)
            guard FloeDigest.sha256Hex(written) == FloeDigest.sha256Hex(payload) else {
                try? manager.removeItem(at: staging)
                throw FloeError.storageCorrupted("Design owner envelope failed verification")
            }
            if manager.fileExists(atPath: current.path) {
                _ = try manager.replaceItemAt(current, withItemAt: staging)
            } else {
                try manager.moveItem(at: staging, to: current)
            }
            // Keep the revisioned copy for recovery/audit.
            let revisioned = directory.appendingPathComponent("project.v\(next.revision).json")
            if !manager.fileExists(atPath: revisioned.path) {
                try? payload.write(to: revisioned, options: .atomic)
            }
            return next.revision
        }
    }
}

private extension NSLocking {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

// MARK: - Composition factory (T6 calls this; it invents no persistence)

@MainActor
enum DesignOwnerWorkflowFactory {
    /// Builds the functional target service and full owner workflow over
    /// the environment's EXISTING services. `decisionSink` is the same
    /// durable ingress used by Canvas decisions, bound per originating
    /// task; pass nil for read-only tests.
    static func make(
        environment: AppEnvironment,
        canvasService: DesignCanvasService,
        adapters: DesignAdapterCenter,
        outbox: DesignDecisionOutbox = .shared,
        decisionSink: (@MainActor @Sendable (UUID, UUID, String, Int64?, String?) async throws -> Void)? = nil,
        publicationPort: (any DesignResultPublicationPort)? = nil,
        artifactRoot: URL? = nil
    ) -> (service: DesignTargetService, workflow: DesignOwnerWorkflow) {
        let canvasAdapter = DesignCanvasOwnerAdapter(
            service: canvasService,
            contentPort: AppCanvasDesignContentPort()
        )
        // Workspace records live in the same GRDB database as the rest of
        // the app; SQLiteWorkspaceStore is a cheap stateless facade over it
        // (mirrors WorkspaceCenter/SettingsCenter construction).
        let workspaceStore = SQLiteWorkspaceStore(database: environment.database)
        // The owner envelope + payload stores are shared by the workflow and
        // the creative port (ONE design state; no parallel request store).
        let payloadStore = ArtifactOwnerPayloadStore(root: artifactRoot)
        let envelopeStore = ArtifactDesignOwnerStore(root: artifactRoot)
        let runTaskBinding: @MainActor @Sendable (UUID) async -> UUID? = { [database = environment.database] runID in
            let store = SQLiteRunStore(database: database)
            return (try? await store.run(id: runID))?.conversationID
        }
        let filePort = AppWorkspaceFilePort(
            workspaceStore: workspaceStore,
            runTaskBinding: runTaskBinding
        )
        let fileAdapter = DesignFileOwnerAdapter(port: filePort)
        let chatAdapter = DesignChatAttachmentOwnerAdapter(
            port: AppChatAttachmentPort(
                conversationStore: environment.conversationStore,
                resolveURL: { [environment] attachment in
                    try environment.filesCenter.resolveURL(for: attachment)
                },
                runTaskBinding: { [database = environment.database] runID in
                    // The durable run record is the existing authority for
                    // which task a run executed in.
                    let store = SQLiteRunStore(database: database)
                    return (try? await store.run(id: runID))?.conversationID
                }
            )
        )
        let creativeAdapter = DesignCreativeOwnerAdapter(
            port: AppCreativeDocumentPort(
                assetStore: environment.creativeAssetStore,
                artifactRoot: { try FloeArtifactStore.root() },
                envelopes: envelopeStore,
                runTaskBinding: { [database = environment.database] runID in
                    // The durable run record is the existing authority for
                    // which task a run executed in.
                    let store = SQLiteRunStore(database: database)
                    return (try? await store.run(id: runID))?.conversationID
                },
                generatedAssetLink: { [database = environment.database] assetID, runID, taskID in
                    // A REAL durable job→asset link: the asset must be the
                    // committed local result of a media job this exact run
                    // submitted, or of a job owned by the run's own task.
                    let store = MediaGenerationJobStore(database: database)
                    guard let jobs = try? await store.jobs(localAssetID: assetID) else { return false }
                    return jobs.contains { owned in
                        guard owned.job.localAssetID == assetID else { return false }
                        if owned.originRunID == runID { return true }
                        return owned.owner.kind == .conversation && owned.owner.id == taskID
                    }
                }
            )
        )
        let service = DesignTargetService(adapters: [
            canvasAdapter, fileAdapter, chatAdapter, creativeAdapter
        ])
        // Configured default decision sink (the same durable ingress the
        // canvas decisions use, bound per originating conversation). When it
        // is nil, deliveries stay durably PENDING in the outbox — the
        // workflow never fabricates a delivered success.
        let configuredSink: DesignOwnerDecisionSink?
        if let decisionSink {
            configuredSink = { conversationID, candidateID, decision, revision, sha256 in
                try await decisionSink(conversationID, candidateID, decision, revision, sha256)
            }
        } else {
            configuredSink = nil
        }
        let workflow = DesignOwnerWorkflow(
            targets: service,
            store: envelopeStore,
            payloads: payloadStore,
            commitPorts: [.fileDocument: WorkspaceFileOwnerCommitPort(workspaceStore: workspaceStore)],
            outbox: outbox,
            defaultSink: configuredSink,
            // T6 wires its existing FilesCenter/ConversationStore/
            // CreativeAssetStore publication path here. While nil, an
            // immutable-owner adopt fails closed before any state change
            // (never a metadata-only success).
            defaultPublication: publicationPort
        )
        _ = adapters
        return (service, workflow)
    }

    /// The REQUIRED real-format reopen verifier for one content type, built
    /// from the connected `DesignAdapterCenter` parsers. An unconnected
    /// content type or an unsupported format throws, so the workflow can
    /// never report a verified adoption/export from a digest alone. Pass the
    /// result as `verifyReopen` on every `adopt`/`exportVerified` call.
    static func verifier(
        adapters: DesignAdapterCenter
    ) -> @Sendable (Data, String, DesignContentType) async throws -> Void {
        { @MainActor bytes, format, contentType in
            guard let adapter = adapters.adapter(for: contentType) else {
                throw FloeError.validationFailed(
                    "No adapter is connected for \(contentType.rawValue); refusing to claim a verified \(format) result"
                )
            }
            try await adapter.verifyExportReopen(bytes: bytes, format: format)
        }
    }
}
#endif
