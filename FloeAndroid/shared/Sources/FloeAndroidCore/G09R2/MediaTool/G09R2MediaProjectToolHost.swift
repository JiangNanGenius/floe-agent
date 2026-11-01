// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — real native `MediaProjectHost` for the portable original
// `media.project` tool (job-258c68e91e6840df).
//
// Authority split:
//  * the portable `FloeAndroidWorkbench` source owns argument decoding, the
//    revision-bound proposal gate, the trusted grant decision and runtime
//    authority consumption;
//  * THIS host owns the accepted-root project CAS (`G09MediaProjectHost`),
//    task/storage resolution, durable drafts, the queue of authoritative
//    applies, the real render-ticket submission/await path and the verified
//    receipt mapping.
//
// It never mints a project, root, storage layer, renderer, receipt or grant
// on its own. Every method re-resolves the caller's task identity and the
// exact accepted epoch before touching bytes.
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeAndroidWorkbench

// MARK: - Configuration

struct G09R2MediaToolHostConfig: Sendable {
    /// Bounded native wait for one render ticket settlement. The mailbox
    /// itself keeps its own hard 10-minute ticket deadline; this budget only
    /// decides when the TOOL reports an honest unknown outcome.
    var exportAwaitSeconds: TimeInterval = 660
    var exportPollMillis: Int = 1_000
    /// Bounded memory of `authorizeAccess -> load/persist/export` pairs.
    var accessLifetimeSeconds: TimeInterval = 600
    var maximumAccessSessions = 8
    var maximumMeasuredLayers = 64

    init(exportAwaitSeconds: TimeInterval = 660,
         exportPollMillis: Int = 1_000,
         accessLifetimeSeconds: TimeInterval = 600,
         maximumAccessSessions: Int = 8,
         maximumMeasuredLayers: Int = 64) {
        self.exportAwaitSeconds = exportAwaitSeconds
        self.exportPollMillis = exportPollMillis
        self.accessLifetimeSeconds = accessLifetimeSeconds
        self.maximumAccessSessions = maximumAccessSessions
        self.maximumMeasuredLayers = maximumMeasuredLayers
    }
}

// MARK: - Access registry

private final class G09R2MediaToolAccessRegistry: @unchecked Sendable {
    private struct Entry {
        let access: MediaProjectAccess
        let at: Date
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private let lifetime: TimeInterval
    private let maximum: Int

    init(lifetime: TimeInterval, maximum: Int) {
        self.lifetime = lifetime
        self.maximum = maximum
    }

    func put(_ projectID: UUID, access: MediaProjectAccess, now: Date = Date()) {
        lock.lock()
        entries[projectID] = Entry(access: access, at: now)
        order.removeAll { $0 == projectID }
        order.append(projectID)
        let cutoff = now.addingTimeInterval(-lifetime)
        for key in order where (entries[key]?.at ?? .distantPast) < cutoff {
            entries.removeValue(forKey: key)
        }
        var live = order.filter { entries[$0] != nil }
        while live.count > maximum, let first = live.first {
            entries.removeValue(forKey: first)
            live.removeFirst()
        }
        order = live
        lock.unlock()
    }

    func access(for projectID: UUID, now: Date = Date()) -> MediaProjectAccess? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[projectID],
              now.timeIntervalSince(entry.at) <= lifetime else {
            entries.removeValue(forKey: projectID)
            order.removeAll { $0 == projectID }
            return nil
        }
        return entry.access
    }
}


// MARK: - Immutable per-call context

/// Exact identity and approved arguments of ONE `media.project` invocation.
///
/// The registration wrapper constructs this ONCE from the real ToolContext
/// and the original argument bytes, then gives it to a fresh host instance.
/// Nothing here is read from model-authored fields: run/task/environment/
/// workspace/cancellation and the non-Codable runtime authority all come from
/// the runtime. The binding pin validates the runtime authority READ-ONLY
/// before it is later consumed by the original automatic apply path.
struct G09R2MediaToolCallContext: Sendable {
    let projectID: UUID
    let arguments: MediaProjectArguments
    let context: ToolContext
    /// Test seam; production always uses the process-wide issuing store.
    let authorityStore: RuntimeAuthorityStore

    init(projectID: UUID, arguments: MediaProjectArguments,
         context: ToolContext,
         authorityStore: RuntimeAuthorityStore = .shared) {
        self.projectID = projectID
        self.arguments = arguments
        self.context = context
        self.authorityStore = authorityStore
    }

    /// The exact access the original portable tool derives from this context.
    func matches(_ access: MediaProjectAccess) -> Bool {
        guard access.environmentID == context.environmentID,
              access.ownerID == context.conversationID,
              access.ownerKind == (context.conversationID == nil ? nil : "chat") else {
            return false
        }
        switch (access.workspacePath, context.workspaceRootURL) {
        case (nil, nil):
            return true
        case (let provided?, let root?):
            return G09R2MediaToolFile.pathsEquivalent(provided, root.path)
        default:
            return false
        }
    }

    /// Mirrors the original tool's canonical approved payload and target so
    /// the read-only pin validation compares exactly what the runtime minted.
    /// The original apply path still consumes the same authority itself; this
    /// helper never consumes or re-issues it.
    func runtimeAuthorityBinding() throws -> RuntimeAuthorityBinding {
        let payload = try Self.canonicalApprovedPayload(arguments)
        return context.runtimeAuthorityBinding(
            toolName: MediaProjectTool.name,
            operation: "apply",
            canonicalTarget: Self.canonicalTarget(context: context),
            baseRevision: RuntimeAuthorityDigest.baseRevision(in: payload),
            payloadDigest: RuntimeAuthorityDigest.payloadDigest(payload))
    }

    static func canonicalTarget(context: ToolContext) -> String {
        guard let root = context.workspaceRootURL else { return "workspace:*" }
        return "workspace:" + root.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func canonicalApprovedPayload(_ args: MediaProjectArguments) throws -> Data {
        var object: [String: Any] = ["action": args.action.rawValue]
        object["project_id"] = args.projectIDRaw ?? args.projectID.uuidString
        if let summary = args.summary { object["summary"] = summary }
        if let commands = args.commands {
            object["commands"] = commands.map { command in
                command.mapValues { jsonValue($0) }
            }
        }
        if let proposalID = args.proposalID {
            object["proposal_id"] = args.proposalIDRaw ?? proposalID.uuidString
        }
        if let grantID = args.grantID { object["grant_id"] = grantID }
        if let export = args.export { object["export"] = exportValue(export) }
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }

    private static func jsonValue(_ value: AnyCodableValue) -> Any {
        switch value {
        case .string(let text): return text
        case .number(let number): return number
        case .boolean(let flag): return flag
        case .object(let object): return object.mapValues { jsonValue($0) }
        case .array(let values): return values.map { jsonValue($0) }
        case .null: return NSNull()
        }
    }

    private static func exportValue(_ export: MediaExportArguments) -> [String: Any] {
        var object: [String: Any] = ["kind": export.kind, "file_name": export.fileName]
        if let format = export.format { object["format"] = format }
        if let width = export.width { object["width"] = width }
        if let height = export.height { object["height"] = height }
        if let quality = export.quality { object["quality"] = quality }
        if let preserve = export.preserveTransparency {
            object["preserve_transparency"] = preserve
        }
        if let strip = export.stripMetadata { object["strip_metadata"] = strip }
        if let codec = export.codec { object["codec"] = codec }
        if let frameRate = export.frameRate { object["frame_rate"] = frameRate }
        if let preset = export.preset { object["preset"] = preset }
        return object
    }
}

// MARK: - Real host

final class G09R2MediaProjectToolHost: MediaProjectHost, @unchecked Sendable {
    private let service: G09CreativeDomainService
    private let mailbox: G09R2MediaRenderHostMailbox
    private let proposals: G09R2MediaToolProposalStore
    private let grants: G09R2MediaToolGrants
    private let config: G09R2MediaToolHostConfig
    private let access: G09R2MediaToolAccessRegistry
    /// Non-nil only for a per-invocation registered call. It replaces the
    /// projectID-keyed access window: the identity is immutable for the whole
    /// call, so two tasks can never overwrite each other between awaits.
    private let scopedCall: G09R2MediaToolCallContext?
    private let scopedLock = NSLock()
    private var scopedSession: G09R2MediaToolSession?
    /// Exact proposal loaded by this host instance. The real `media.project`
    /// tool loads the proposal immediately before applying it; the registered
    /// per-call host also carries the same id in `scopedCall.arguments`. This
    /// identity is NEVER re-derived from an applied digest (UUID/Date values
    /// generated while applying are not reproducible).
    private var lastLoadedProposal: (projectID: UUID, proposalID: UUID,
                                     baseRevision: Int64)?

    init(service: G09CreativeDomainService,
         mailbox: G09R2MediaRenderHostMailbox = .shared,
         proposals: G09R2MediaToolProposalStore = .shared,
         grants: G09R2MediaToolGrants? = nil,
         config: G09R2MediaToolHostConfig = G09R2MediaToolHostConfig(),
         call: G09R2MediaToolCallContext? = nil) {
        self.service = service
        self.mailbox = mailbox
        self.proposals = proposals
        self.grants = grants ?? G09R2MediaToolGrants(
            service: service, mailbox: mailbox, proposals: proposals)
        self.config = config
        self.access = G09R2MediaToolAccessRegistry(
            lifetime: config.accessLifetimeSeconds,
            maximum: config.maximumAccessSessions)
        self.scopedCall = call
    }

    // MARK: Authorization

    func authorizeAccess(projectID: UUID, access value: MediaProjectAccess) async throws {
        if let call = scopedCall {
            guard call.projectID == projectID else {
                throw G09R2MediaToolFailure.projectChanged.floError
            }
            guard !call.context.temporaryReadOnly else {
                throw FloeError.unauthorized
            }
            guard call.matches(value) else { throw FloeError.unauthorized }
            let session: G09R2MediaToolSession
            do {
                if let bound = try await G09R2MediaTaskBindingCoordinator.authorizeBound(
                    service: service, mailbox: mailbox, call: call) {
                    session = bound
                } else {
                    session = try await resolve(projectID: projectID, access: value,
                                                requireWritable: true)
                }
            } catch {
                throw G09R2MediaToolAccess.floError(error)
            }
            storeScopedSession(session)
            return
        }
        _ = try await resolve(projectID: projectID, access: value,
                             requireWritable: false)
        access.put(projectID, access: value)
    }

    private func requireAccess(_ projectID: UUID) throws -> MediaProjectAccess {
        guard let stored = access.access(for: projectID) else {
            throw FloeError.unauthorized
        }
        return stored
    }

    private func resolve(projectID: UUID, access value: MediaProjectAccess,
                         requireWritable: Bool) async throws -> G09R2MediaToolSession {
        do {
            return try await G09R2MediaToolAccess.authorize(
                service: service, mailbox: mailbox, access: value,
                projectID: projectID, requireWritable: requireWritable)
        } catch {
            throw G09R2MediaToolAccess.floError(error)
        }
    }

    /// Synchronous lock helpers: Swift 6 forbids NSLock.lock/unlock directly
    /// inside an async function. Only the immutable per-call session is stored.
    private func storeScopedSession(_ session: G09R2MediaToolSession?) {
        scopedLock.lock()
        scopedSession = session
        scopedLock.unlock()
    }

    private func currentScopedSession() -> G09R2MediaToolSession? {
        scopedLock.lock()
        defer { scopedLock.unlock() }
        return scopedSession
    }

    private func requireSession(projectID: UUID)
        async throws -> G09R2MediaToolSession {
        if scopedCall != nil {
            let session = currentScopedSession()
            guard let session, session.project.id == projectID else {
                throw FloeError.unauthorized
            }
            // Match the legacy host's per-method re-resolution: the original
            // apply path reopens the persisted revision after commit and must
            // not receive the authorize-time snapshot. Task/storage/origin are
            // immutable for this invocation; only the project bytes refresh.
            do {
                let loaded = try await session.media.load(
                    id: projectID, requested: session.storage,
                    origin: session.origin)
                guard loaded.writable else {
                    throw G09R2MediaToolFailure.storageUnresolved.floError
                }
                let refreshed = session.replacingProject(loaded.project)
                storeScopedSession(refreshed)
                return refreshed
            } catch {
                throw G09R2MediaToolAccess.floError(error)
            }
        }
        let value = try requireAccess(projectID)
        let session = try await resolve(projectID: projectID, access: value,
                                        requireWritable: true)
        access.put(projectID, access: value)
        return session
    }

    // MARK: MediaProjectHost — reads

    func loadProject(id: UUID) async throws -> MediaProject? {
        let session = try await requireSession(projectID: id)
        return session.project
    }

    // MARK: MediaProjectHost — proposals

    func storeProposal(_ proposal: MediaProposal) async throws {
        let session = try await requireSession(projectID: proposal.projectID)
        do {
            try await proposals.store(proposal, session: session)
        } catch {
            throw G09R2MediaToolAccess.floError(error)
        }
    }

    /// The portable tool calls `authorizeAccess(projectID:)` and
    /// `loadProject(projectID:)` before loading its proposal, so the live
    /// bounded access window names the exact project. A proposal is only
    /// returned when it is bound to THAT project's current task/epoch/storage.
    func loadProposal(id: UUID) async throws -> MediaProposal? {
        guard let projectID = scopedProjectID ?? access.currentProject() else {
            throw FloeError.unauthorized
        }
        let session = try await requireSession(projectID: projectID)
        let loaded = try await proposals.load(id: id, session: session)
        if let loaded {
            lastLoadedProposal = (session.project.id, id, loaded.baseRevision)
        }
        return loaded
    }

    func removeProposal(id: UUID) async throws {
        guard let projectID = scopedProjectID ?? access.currentProject() else {
            throw FloeError.unauthorized
        }
        let session = try await requireSession(projectID: projectID)
        do {
            try await proposals.remove(id: id, session: session)
        } catch {
            throw G09R2MediaToolAccess.floError(error)
        }
    }

    // MARK: MediaProjectHost — grants

    func consumeGrant(grantID: String, proposalID: UUID, projectID: UUID,
                      revision: Int64) async -> MediaGrantDecision {
        let session: G09R2MediaToolSession
        if scopedCall != nil {
            guard let current = try? await requireSession(projectID: projectID) else {
                return .unknownGrant
            }
            session = current
        } else {
            guard let value = try? requireAccess(projectID),
                  let resolved = try? await resolve(
                    projectID: projectID, access: value,
                    requireWritable: true) else {
                return .unknownGrant
            }
            access.put(projectID, access: value)
            session = resolved
        }
        guard let proposal = try? await proposals.load(
            id: proposalID, session: session),
              proposal.projectID == projectID else {
            return .unknownGrant
        }
        return await grants.consume(
            grantID: grantID, projectID: projectID,
            proposalID: proposalID, revision: revision)
    }

    // MARK: MediaProjectHost — durable apply

    func persistProject(_ project: MediaProject, expectedRevision: Int64?) async throws {
        let session = try await requireSession(projectID: project.id)
        guard let expectedRevision else {
            throw G09R2MediaToolFailure.proposalIdentityUnavailable.floError
        }
        // Exact per-call proposal identity. The applied project is persisted
        // as-is through the real CAS/receipt path: replaying its command list
        // would mint new UUID/Date values for add_layer/add_caption and would
        // not be the project the user authorized.
        let proposalID = scopedCall?.arguments.proposalID
            ?? lastLoadedProposal?.proposalID
        guard let proposalID,
              let proposal = try await proposals.load(id: proposalID, session: session),
              proposal.id == proposalID,
              proposal.projectID == project.id,
              proposal.baseRevision == expectedRevision else {
            throw G09R2MediaToolFailure.proposalIdentityUnavailable.floError
        }
        if project.revision == expectedRevision {
            // The authorized command sequence produced no state change; there
            // is no new revision and therefore no commit receipt.
            return
        }
        do {
            _ = try await session.media.commitApplied(
                project,
                expectedRevision: expectedRevision,
                sessionToken: "mt.\(session.accessProof.prefix(24))",
                storage: session.storage,
                origin: session.origin,
                opID: "mt-\(proposalID.uuidString.lowercased())")
        } catch {
            throw G09R2MediaToolAccess.floError(error)
        }
        if scopedCall == nil, let value = access.access(for: project.id) {
            access.put(project.id, access: value)
        }
    }

    private func canonicalDigest(_ project: MediaProject) throws -> Data {
        do {
            return try MediaProjectStore.canonicalContentData(project)
        } catch {
            throw FloeError.storageCorrupted("The media project could not be represented")
        }
    }

    // MARK: MediaProjectHost — export

    func exportVideo(project: MediaProject, options: VideoExportOptions,
                     relativeOutput: String,
                     cancellation: CancellationToken?)
        async throws -> WorkbenchVideoExportReceipt {
        let session = try await requireSession(projectID: project.id)
        try requireUnchanged(project, session: session)
        let settings = try Self.videoSettings(project: session.project, options: options)
        let prepared = try await G09R2MediaToolExport.prepare(
            session: session, kind: .video,
            outputRelativePath: relativeOutput,
            imageSettings: nil, videoSettings: settings,
            mailbox: mailbox)
        let reply: G09R2RenderTicketReplyDTO
        do {
            reply = try await G09R2MediaToolExport.awaitTerminal(
                prepared: prepared, mailbox: mailbox,
                cancellation: cancellation, config: config)
        } catch {
            G09R2MediaToolExport.abandon(prepared, mailbox: mailbox)
            throw G09R2MediaToolAccess.floError(error)
        }
        guard reply.status == .completed, let receipt = reply.receipt else {
            let code = reply.errorCode ?? reply.status.rawValue
            G09R2MediaToolExport.abandon(prepared, mailbox: mailbox)
            if reply.status == .cancelled {
                throw FloeError.cancelled
            }
            throw G09R2MediaToolFailure.exportFailed(code).floError
        }
        let url: URL
        do {
            url = try G09R2MediaToolExport.verify(
                receipt: receipt, descriptor: prepared.descriptor,
                expectedOwner: session.accessProof,
                expectedEpoch: session.epoch)
        } catch {
            G09R2MediaToolExport.abandon(prepared, mailbox: mailbox)
            throw G09R2MediaToolFailure.exportFailed("renderOutputUnverified").floError
        }
        G09R2MediaToolExport.finish(prepared, mailbox: mailbox)
        let duration = receipt.verification.decodedDurationSeconds ?? 0
        guard duration.isFinite, duration > 0 else {
            throw G09R2MediaToolFailure.exportFailed("renderUnverifiedDuration").floError
        }
        return WorkbenchVideoExportReceipt(
            url: url,
            durationSeconds: duration,
            width: receipt.verification.width,
            height: receipt.verification.height,
            frameRate: settings.frameRate,
            codec: settings.codecMime == "video/hevc" ? "hevc" : "h264",
            hasAudio: receipt.verification.audioTrackCount > 0,
            byteCount: receipt.byteCount)
    }

    func exportImage(project: MediaProject, options: ImageExportOptions,
                     relativeOutput: String)
        async throws -> WorkbenchImageExportReceipt {
        let session = try await requireSession(projectID: project.id)
        try requireUnchanged(project, session: session)
        let settings = try Self.imageSettings(project: session.project, options: options)
        let prepared = try await G09R2MediaToolExport.prepare(
            session: session, kind: .image,
            outputRelativePath: relativeOutput,
            imageSettings: settings, videoSettings: nil,
            mailbox: mailbox)
        let reply: G09R2RenderTicketReplyDTO
        do {
            reply = try await G09R2MediaToolExport.awaitTerminal(
                prepared: prepared, mailbox: mailbox,
                cancellation: nil, config: config)
        } catch {
            G09R2MediaToolExport.abandon(prepared, mailbox: mailbox)
            throw G09R2MediaToolAccess.floError(error)
        }
        guard reply.status == .completed, let receipt = reply.receipt else {
            let code = reply.errorCode ?? reply.status.rawValue
            G09R2MediaToolExport.abandon(prepared, mailbox: mailbox)
            if reply.status == .cancelled {
                throw FloeError.cancelled
            }
            throw G09R2MediaToolFailure.exportFailed(code).floError
        }
        let url: URL
        do {
            url = try G09R2MediaToolExport.verify(
                receipt: receipt, descriptor: prepared.descriptor,
                expectedOwner: session.accessProof,
                expectedEpoch: session.epoch)
        } catch {
            G09R2MediaToolExport.abandon(prepared, mailbox: mailbox)
            throw G09R2MediaToolFailure.exportFailed("renderOutputUnverified").floError
        }
        G09R2MediaToolExport.finish(prepared, mailbox: mailbox)
        return WorkbenchImageExportReceipt(
            url: url,
            width: receipt.verification.width,
            height: receipt.verification.height,
            format: settings.format.lowercased(),
            byteCount: receipt.byteCount)
    }

    private func requireUnchanged(_ project: MediaProject,
                                  session: G09R2MediaToolSession) throws {
        guard project.id == session.project.id,
              project.revision == session.project.revision,
              try canonicalDigest(project) == canonicalDigest(session.project) else {
            throw G09R2MediaToolFailure.projectChanged.floError
        }
    }

    // MARK: MediaCommandEnrichmentHost

    func measureLayers(project: MediaProject, layerIDs: [UUID]) async throws
        -> [LayerNaturalSize] {
        let session = try await requireSession(projectID: project.id)
        let canvas = project.canvas
        guard let canvas, canvas.width >= 2, canvas.height >= 2 else {
            throw G09R2MediaToolFailure.measurementUnavailable("the project has no canvas")
                .floError
        }
        guard !layerIDs.isEmpty,
              layerIDs.count <= config.maximumMeasuredLayers else {
            throw G09R2MediaToolFailure.measurementUnavailable("invalid layer set").floError
        }
        var seen = Set<UUID>()
        var result: [LayerNaturalSize] = []
        for layerID in layerIDs where !seen.contains(layerID) {
            seen.insert(layerID)
            guard let layer = project.imageLayers.first(where: { $0.id == layerID }) else {
                throw G09R2MediaToolFailure.measurementUnavailable(
                    "a requested layer is not in this project").floError
            }
            let size: (Double, Double)
            switch layer.kind {
            case .text, .freehand, .fill:
                size = (Double(canvas.width), Double(canvas.height))
            case .image:
                guard let assetID = layer.assetID,
                      let asset = project.asset(assetID) else {
                    throw G09R2MediaToolFailure.measurementUnavailable(
                        "an image layer has no resolvable asset").floError
                }
                guard let url = G09R2MediaToolFile.containedURL(
                    root: session.projectRoot, relativePath: asset.relativePath),
                      G09R2MediaToolFile.regularFileSize(url.path) != nil else {
                    throw G09R2MediaToolFailure.measurementUnavailable(
                        "the layer asset is missing").floError
                }
                let dimensions = try G09R2MediaToolImageDimensions.read(url)
                let crop = layer.crop
                let left = Int(((crop?.x ?? 0) * Double(dimensions.width))
                    .rounded(.towardZero))
                let top = Int(((crop?.y ?? 0) * Double(dimensions.height))
                    .rounded(.towardZero))
                let cropWidth = max(1, min(dimensions.width - max(0, min(left, dimensions.width - 1)),
                    Int(((crop?.width ?? 1) * Double(dimensions.width))
                        .rounded(.towardZero))))
                let cropHeight = max(1, min(dimensions.height - max(0, min(top, dimensions.height - 1)),
                    Int(((crop?.height ?? 1) * Double(dimensions.height))
                        .rounded(.towardZero))))
                let scale = min(
                    Double(canvas.width) / Double(cropWidth),
                    Double(canvas.height) / Double(cropHeight))
                size = (Double(cropWidth) * scale, Double(cropHeight) * scale)
            @unknown default:
                throw G09R2MediaToolFailure.measurementUnavailable(
                    "unsupported layer kind").floError
            }
            guard size.0.isFinite, size.1.isFinite, size.0 > 0, size.1 > 0 else {
                throw G09R2MediaToolFailure.measurementUnavailable(
                    "the layer has no measurable bounds").floError
            }
            result.append(LayerNaturalSize(
                layerID: layerID, width: size.0, height: size.1))
        }
        return result
    }

    /// Renders ONLY the named visible layers through the SAME native image
    /// renderer/preview pipeline used by export, then registers the verified
    /// full-canvas PNG as a project asset for `mergeLayers`.
    ///
    /// The renderer input is an internal derived projection of the EXACT
    /// project revision/draft (same project id/canvas/assets; only the layer
    /// subset changes; no whole-canvas adjustment, matching the fixed iOS
    /// `renderMerge`). It is never published as a project export. The output
    /// ticket is the existing bounded IMAGE ticket; its bytes/dimensions/hash
    /// are verified before the asset is handed to the shared command engine.
    func renderMergeAsset(project: MediaProject, layerIDs: [UUID],
                          name: String?) async throws -> MergePreparation {
        guard project.kind == .image, let canvas = project.canvas else {
            throw G09R2MediaToolFailure.rendererCompositeUnavailable(
                "merge requires an initialized image project").floError
        }
        let ids = Set(layerIDs)
        guard ids.count >= 2, layerIDs.count == ids.count else {
            throw G09R2MediaToolFailure.rendererCompositeUnavailable(
                "merge requires at least two distinct layers").floError
        }
        guard layerIDs.allSatisfy({ id in
            project.imageLayers.contains { $0.id == id && !$0.isLocked }
        }) else {
            throw G09R2MediaToolFailure.rendererCompositeUnavailable(
                "a merge layer is missing or locked").floError
        }
        var rendered = project
        rendered.imageLayers = project.imageLayers.filter { ids.contains($0.id) }
        // iOS `renderMerge` deliberately does not apply the whole-canvas
        // adjustment; the result is exactly the selected layers' contribution.
        rendered.canvasAdjustment = CanvasAdjustment()
        return try await renderDerivedAsset(
            project: rendered,
            canvas: canvas,
            name: name ?? "Merged layers",
            suffix: "merge")
    }

    /// The exact copy-selection projection: one source layer, its own mask,
    /// adjustment and transform intact, the project selection kept on the
    /// project, and the canvas adjustment kept for the post-composite step.
    ///
    /// It deliberately does NOT append a region erase mask to the layer. That
    /// older shortcut applied the selection before the whole-canvas
    /// adjustment; the App UI and fixed iOS apply the canvas adjustment first
    /// and the complete selection last. The Kotlin renderer receives this
    /// projection through the bounded IMAGE ticket and runs the shared
    /// `renderCopySelection` pipeline.
    static func copySelectionProjection(
        project: MediaProject,
        sourceLayerID: UUID
    ) throws -> MediaProject {
        guard project.kind == .image, project.canvas != nil else {
            throw G09R2MediaToolFailure.rendererCompositeUnavailable(
                "copy requires an initialized image project").floError
        }
        guard let source = project.imageLayers.first(where: { $0.id == sourceLayerID }) else {
            throw G09R2MediaToolFailure.rendererCompositeUnavailable(
                "the copy source layer is missing").floError
        }
        guard !source.isLocked else {
            throw G09R2MediaToolFailure.rendererCompositeUnavailable(
                "the copy source layer is locked").floError
        }
        guard !source.isHidden, source.opacity > 0 else {
            throw G09R2MediaToolFailure.rendererCompositeUnavailable(
                "the copy source layer is hidden or fully transparent").floError
        }
        guard let selection = project.imageSelection, !selection.isEmpty,
              !selection.shapes.isEmpty else {
            throw G09R2MediaToolFailure.rendererCompositeUnavailable(
                "copy requires a non-empty shaped selection").floError
        }
        var rendered = project
        rendered.imageLayers = [source]
        return rendered
    }

    /// Renders ONE layer through the real pipeline and limits it to the
    /// project selection AFTER the whole-canvas adjustment, producing a
    /// full-canvas transparent asset for `copySelection`. The original layer,
    /// selection, masks and bytes are untouched.
    func renderCopySelectionAsset(project: MediaProject,
                                  sourceLayerID: UUID) async throws -> MergePreparation {
        guard let canvas = project.canvas else {
            throw G09R2MediaToolFailure.rendererCompositeUnavailable(
                "copy requires an initialized image project").floError
        }
        let rendered = try Self.copySelectionProjection(
            project: project, sourceLayerID: sourceLayerID)
        return try await renderDerivedAsset(
            project: rendered,
            canvas: canvas,
            name: "Selection Copy",
            suffix: "copy",
            copySelection: G09R2ImageCopySelectionDTO(sourceLayerID: sourceLayerID))
    }

    private func renderDerivedAsset(
        project: MediaProject,
        canvas: MediaCanvas,
        name: String,
        suffix: String,
        copySelection: G09R2ImageCopySelectionDTO? = nil
    ) async throws -> MergePreparation {
        guard let sourceSession = currentSession else {
            throw G09R2MediaToolFailure.generationStopped.floError
        }
        guard project.revision == sourceSession.project.revision,
              project.id == sourceSession.project.id else {
            throw G09R2MediaToolFailure.projectChanged.floError
        }
        let derivedSession = G09R2MediaToolSession(
            epoch: sourceSession.epoch,
            root: sourceSession.root,
            media: sourceSession.media,
            project: project,
            storage: sourceSession.storage,
            origin: sourceSession.origin,
            projectRoot: sourceSession.projectRoot,
            conversationID: sourceSession.conversationID,
            workspaceID: sourceSession.workspaceID,
            taskDigest: sourceSession.taskDigest,
            accessProof: sourceSession.accessProof,
            bindingID: sourceSession.bindingID)
        let attempt = "c03-\(suffix)-\(UUID().uuidString.prefix(8))"
        let outputRelative = "Workbench/Exports/\(attempt).png"
        let settings = G09R2ImageExportSettingsDTO(
            format: "png",
            width: canvas.width,
            height: canvas.height,
            quality: 1.0,
            preserveTransparency: true,
            stripMetadata: true,
            fileName: attempt)
        let prepared = try await G09R2MediaToolExport.prepare(
            session: derivedSession,
            kind: .image,
            outputRelativePath: outputRelative,
            imageSettings: settings,
            videoSettings: nil,
            copySelection: copySelection,
            mailbox: mailbox)
        var finished = false
        var publishedOutput: URL?
        do {
            let reply = try await G09R2MediaToolExport.awaitTerminal(
                prepared: prepared,
                mailbox: mailbox,
                cancellation: nil,
                config: config)
            guard reply.status == .completed, let receipt = reply.receipt else {
                throw G09R2MediaToolFailure.exportFailed(
                    reply.errorCode ?? "rendererCompositeUnavailable").floError
            }
            let output = try G09R2MediaToolExport.verify(
                receipt: receipt,
                descriptor: prepared.descriptor,
                expectedOwner: sourceSession.accessProof,
                expectedEpoch: sourceSession.epoch)
            G09R2MediaToolExport.finish(prepared, mailbox: mailbox)
            finished = true
            publishedOutput = output
            let preparation = try registerRenderedAsset(
                output: output,
                canvas: canvas,
                name: name,
                suffix: suffix,
                projectRoot: sourceSession.projectRoot)
            _ = try C03LayerRasterVerifier.verify(
                preparation, project: sourceSession.project, root: sourceSession.projectRoot)
            return preparation
        } catch {
            if !finished {
                G09R2MediaToolExport.abandon(prepared, mailbox: mailbox)
            } else if let publishedOutput {
                try? FileManager.default.removeItem(at: publishedOutput)
            }
            throw error
        }
    }

    private func registerRenderedAsset(
        output: URL,
        canvas: MediaCanvas,
        name: String,
        suffix: String,
        projectRoot: URL
    ) throws -> MergePreparation {
        let assets = try G09R2MediaToolFile.ensureRealSubdirectories(
            root: projectRoot, components: ["Workbench", "Assets"])
        let fileName = "\(UUID().uuidString.prefix(8))-\(suffix).png"
        let target = assets.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw G09R2MediaToolFailure.exportFailed("stagedAssetExists").floError
        }
        do {
            try FileManager.default.moveItem(at: output, to: target)
        } catch {
            throw G09R2MediaToolFailure.exportFailed("stagedAssetMove").floError
        }
        guard let size = G09R2MediaToolFile.regularFileSize(target.path),
              size > 0,
              let hash = try? G09R2MediaToolFile.digest(ofFileAt: target) else {
            try? FileManager.default.removeItem(at: target)
            throw G09R2MediaToolFailure.exportFailed("stagedAssetUnverified").floError
        }
        let relative = "Workbench/Assets/\(fileName)"
        guard G09CreativeAssetHost.safeRelativePath(relative) else {
            try? FileManager.default.removeItem(at: target)
            throw G09R2MediaToolFailure.exportFailed("stagedAssetPath").floError
        }
        let assetID = UUID()
        let asset = MediaAssetReference(
            id: assetID,
            kind: .image,
            relativePath: relative,
            originalName: "\(name).png",
            byteCount: size,
            contentHash: hash)
        return MergePreparation(
            asset: asset,
            raster: MergedLayerRaster(
                assetID: assetID, width: canvas.width, height: canvas.height,
                contentHash: hash))
    }

    func discardStagedAsset(_ asset: MediaAssetReference) async {
        guard asset.kind == .image,
              asset.relativePath.hasPrefix("Workbench/Assets/"),
              let session = currentSession,
              let url = G09R2MediaToolFile.containedURL(
                root: session.projectRoot, relativePath: asset.relativePath),
              G09R2MediaToolFile.regularFileSize(url.path) != nil else {
            return
        }
        // Only an unreferenced staged merge/copy asset is removed; the
        // project's own assets are never deleted by this cleanup.
        guard !session.project.assets.contains(where: { $0.id == asset.id }) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Scoped helpers / capability (truthful subset)

    private var scopedProjectID: UUID? { scopedCall?.projectID }

    private var currentSession: G09R2MediaToolSession? {
        scopedLock.lock(); defer { scopedLock.unlock() }
        return scopedSession
    }

    /// The ONE truthful capability answer for this project. It replaces the
    /// portable tool's older prose instead of appending a second, partly
    /// contradictory list: merge/copy/fill/cut are real native operations,
    /// image exports are png/jpeg/heic, video exports are h264/hevc, and
    /// automatic apply uses the runtime authority for the exact task call (no
    /// mandatory per-edit UI prompt). The tool itself is only discoverable
    /// while `G09R2MediaToolAvailability` reports a live, epoch-exact renderer
    /// consumer; `G09R2MediaToolRegistration.capability` reports the same
    /// state instead of a fixed prose claim.
    func normalizedCapabilityText() -> String? {
        guard let session = currentSession else { return nil }
        return Self.capabilityText(project: session.project)
    }

    static func capabilityText(project: MediaProject) -> String {
        var lines: [String] = [
            "media_project_capabilities",
            "project_id: \(project.id.uuidString)",
            "kind: \(project.kind.rawValue)",
            "revision: \(project.revision)",
            "canvas_ready: \(project.canvas != nil)",
            "workflow: capabilities -> read -> propose -> apply -> verify_revision_or_export",
            "apply_authority: for an already-authorized task, apply without grant_id uses the runtime authority for this exact call; with grant_id it commits a user-reviewed proposal. A model cannot mint an authorization or reuse another call's authority.",
            "draft_vs_applied: propose stores a revision-bound draft; the project changes only after an authorized apply.",
            "modify_vs_variant: edit the bound project to modify the current draft; a forked project is a variant.",
            "actions: capabilities, read, propose, apply, export"
        ]
        if project.kind == .image {
            lines += [
                "image_commands: add_image_layer, update_layer, add_freehand_stroke, reorder_layers, move_layer, duplicate_layer, remove_layer, set_selection, clear_selection, set_layer_selection, add_mask_stroke, clear_layer_mask, flip_layer, align_layers, set_canvas_adjustment, add_asset, relink_asset, set_canvas, fill_selection, cut_selection",
                "merge_layers: renderer-backed via the bounded IMAGE ticket; only visible selected layers are composited into a registered full-canvas PNG",
                "copy_selection: renderer-backed via the bounded IMAGE ticket; the source layer is rendered, the whole-canvas adjustment is applied, then the complete selection mask (same order as the UI/iOS)",
                "fill_selection: native command; adds a real fill layer masked by the complete current selection",
                "cut_selection: native command; appends one reversible region mask stroke to the source layer",
                "image_export_formats: png, jpeg, heic (HEIC is 8-bit SDR via AndroidX HeifWriter 1.1.0; HDR sources are refused, never silently tone-mapped)",
                "selection: rectangle|ellipse|lasso with replace|add|subtract, feather 0..0.5, invert",
                "masks: non-destructive erase/restore strokes; original pixels are never destroyed",
                "typography: size, tracking, leading, alignment, stroke, shadow, named fonts",
                "adjustments: saturation, contrast, brightness, exposure, blur, sharpen, temperature, hue, levels, mosaic, filters"
            ]
        } else {
            lines += [
                "video_commands: append_clip, update_clip, reorder_clips, split_clip, duplicate_clip, remove_clip, set_primary_audio, set_cover, shift_captions, add_music, update_music, remove_music, add_caption, update_caption, remove_caption, set_caption_style",
                "tracks: one primary video track only (no multi-track/keyframes)",
                "video_export_codecs: h264, hevc",
                "time: exact HH:MM:SS:FF timecode, frame stepping, clip-edge snapping; trims retime captions",
                "audio: single music track with volume/fade visuals; per-clip volume and primary mix",
                "captions: batch style/alignment/safe-area and global time shift"
            ]
        }
        if !project.recoveryWarnings.isEmpty {
            lines.append("warnings: \(project.recoveryWarnings.joined(separator: " | "))")
        }
        return lines.joined(separator: "\n")
    }

    static let actions = ["capabilities", "read", "propose", "apply", "export"]
    static let imageFormats = ["png", "jpeg", "heic"]
    static let videoCodecs = ["h264", "hevc"]
    static let measurableImageFormats = ["png", "jpeg", "webp", "gif", "bmp"]

    static func capabilityLines(
        availability: G09R2MediaToolAvailability = .shared
    ) -> [String] {
        let snapshot = availability.snapshot()
        let rendererState = snapshot.available ? "supported" : "unavailable"
        var lines: [String] = [
            "host_export: image png/jpeg/heic (HEIC 8-bit SDR); video h264/hevc via the real platform renderer",
            "host_measure_layers: supported for text/freehand/fill and png/jpeg/webp/gif/bmp image assets",
            "host_merge_layers: \(rendererState) via the bounded IMAGE render ticket and the real platform image renderer",
            "host_copy_selection: \(rendererState) via the bounded IMAGE render ticket and the real platform image renderer",
        ]
        lines.append("host_renderer_ready: \(snapshot.available ? "true" : "false")")
        if let reason = snapshot.reason {
            lines.append("host_renderer_reason: \(reason)")
        }
        return lines
    }

    // MARK: Settings validation

    static func safeExportComponent(_ raw: String, maximum: Int = 96) -> Bool {
        guard !raw.isEmpty, raw.utf8.count <= maximum,
              raw != ".", raw != ".." else { return false }
        return raw.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) ||
                ($0.value >= 65 && $0.value <= 90) ||
                ($0.value >= 97 && $0.value <= 122) ||
                $0 == "." || $0 == "-" || $0 == "_"
        }
    }

    static func imageSettings(project: MediaProject,
                              options: ImageExportOptions) throws
        -> G09R2ImageExportSettingsDTO {
        guard project.kind == .image else {
            throw G09R2MediaToolFailure.exportUnsupported(
                "this is not an image project").floError
        }
        let format = options.format.rawValue.lowercased()
        guard imageFormats.contains(format) else {
            throw G09R2MediaToolFailure.exportUnsupported(
                "\(format.uppercased()) image output is unavailable; use PNG, JPEG or HEIC").floError
        }
        guard options.quality.isFinite, (0.01...1).contains(options.quality) else {
            throw G09R2MediaToolFailure.exportUnsupported(
                "export quality must be between 0.01 and 1").floError
        }
        if (options.width == nil) != (options.height == nil) {
            throw G09R2MediaToolFailure.exportUnsupported(
                "provide both export dimensions or neither").floError
        }
        if let width = options.width, let height = options.height {
            guard (2...8192).contains(width), (2...8192).contains(height) else {
                throw G09R2MediaToolFailure.exportUnsupported(
                    "image export dimensions must be 2...8192").floError
            }
        }
        guard safeExportComponent(options.fileName) else {
            throw G09R2MediaToolFailure.exportUnsupported(
                "file names may contain only letters, digits, dot, dash and underscore").floError
        }
        return G09R2ImageExportSettingsDTO(
            format: format,
            width: options.width, height: options.height,
            quality: options.quality,
            preserveTransparency: options.preserveTransparency,
            stripMetadata: options.stripMetadata,
            fileName: options.fileName)
    }

    static func videoSettings(project: MediaProject,
                              options: VideoExportOptions) throws
        -> G09R2VideoExportSettingsDTO {
        guard project.kind == .video else {
            throw G09R2MediaToolFailure.exportUnsupported(
                "this is not a video project").floError
        }
        guard (2...8192).contains(options.width),
              (2...8192).contains(options.height),
              options.width % 2 == 0, options.height % 2 == 0 else {
            throw G09R2MediaToolFailure.exportUnsupported(
                "video dimensions must be even and 2...8192").floError
        }
        guard options.frameRate.isFinite, options.frameRate >= 1,
              options.frameRate <= 240 else {
            throw G09R2MediaToolFailure.exportUnsupported(
                "frame rate must be between 1 and 240").floError
        }
        guard options.quality.isFinite, (0.01...1).contains(options.quality) else {
            throw G09R2MediaToolFailure.exportUnsupported(
                "export quality must be between 0.01 and 1").floError
        }
        guard safeExportComponent(options.fileName) else {
            throw G09R2MediaToolFailure.exportUnsupported(
                "file names may contain only letters, digits, dot, dash and underscore").floError
        }
        return G09R2VideoExportSettingsDTO(
            codecMime: options.codec == .h264 ? "video/avc" : "video/hevc",
            width: options.width, height: options.height,
            frameRate: options.frameRate, quality: options.quality,
            fileName: options.fileName)
    }
}

// MARK: - Access registry current project

private extension G09R2MediaToolAccessRegistry {
    /// Legacy direct-host path only (focused tests/diagnostics). Production
    /// registration constructs ONE fresh host per invocation with an
    /// immutable `G09R2MediaToolCallContext`, so this projectID-keyed window
    /// is never shared between callers.
    func currentProject() -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return order.last
    }
}
