// FloeWorkbench — media.project tool.
//
// One tool, four actions with explicit effect levels:
//   read      — read-only project summary
//   propose   — validates a command sequence against a revision, stores a
//               pending proposal (internal Floe draft state) and returns its
//               preview; changes nothing on disk and does NOT pause the run
//   apply     — two authority modes: for an already-authorized task the
//               runtime-issued authority for this exact approved call runs
//               the automatic transaction; a user-confirmed apply passes a
//               trusted single-use UI grant (MediaProposalGrantStore). A
//               fabricated grant id or changed revision is refused
//   export    — writes a verified image/video file to
//               Workbench/Exports/<file_name>.<ext>; never overwrites an
//               existing file with different bytes
//
// The tool never mints confirmation itself. Project/environment/task
// ownership is enforced by the injected `MediaProjectHost`, which the app
// supplies from the task workspace (ToolContext.workspaceRootURL) and owner.

import Foundation
import FloeCore
import FloeTools

/// S3-D run-output publication support for the Workbench/CAD verified export
/// boundaries. Snapshots live only in the core `RunOutputSnapshotStore`; this
/// applies the fixed failure policy: a bound-run publication failure throws an
/// observable tool error (exported originals are never touched), genuine
/// legacy direct and temporary contexts keep byte-identical legacy results,
/// and partially bound contexts fail rather than silently skipping. Export
/// receipts carry URL + size but no digest, so publication adds a post-write
/// streamed digest — the genuinely missing identity.
enum RunOutputWorkbenchPublication {
    enum State {
        case required
        case legacyDirect
        case temporaryExempt
        case partiallyBound
    }

    static func state(_ context: ToolContext) -> State {
        let hasCall = context.toolCallID?.isEmpty == false
        let hasTask = context.conversationID != nil
        if !hasCall && !hasTask { return .legacyDirect }
        if hasCall != hasTask { return .partiallyBound }
        if context.temporaryReadOnly { return .temporaryExempt }
        return .required
    }

    static var partialBindingFailure: FloeError {
        FloeError.validationFailed(
            "run output publication requires both the tool-call and task binding")
    }

    static func sourceUnavailable(_ detail: String = "source unavailable") -> FloeError {
        FloeError.validationFailed("run output publication failed (\(detail))")
    }

    static func publicationFailure(_ error: RunOutputSnapshotError) -> FloeError {
        switch error {
        case .bindingMissing: return FloeError.validationFailed("run output publication failed (unbound)")
        case .policyRefused: return FloeError.validationFailed("run output publication refused by policy")
        case .identityInvalid: return FloeError.validationFailed("run output publication failed (invalid identity)")
        case .sourceUnavailable: return FloeError.validationFailed("run output publication failed (source unavailable)")
        case .commitIdentityStale: return FloeError.validationFailed("run output publication failed (stale commit identity)")
        case .conflict(let name): return FloeError.validationFailed("run output publication failed (conflict: \(name))")
        case .overCap: return FloeError.validationFailed("run output publication failed (over cap)")
        case .snapshotAliased: return FloeError.validationFailed("run output publication failed (aliased snapshot)")
        case .ioFailure: return FloeError.storageCorrupted("run output publication failed (storage)")
        }
    }

    /// Publishes with a caller-supplied trusted commit digest, or measures a
    /// post-write streamed digest when `sha256` is nil (the Workbench export
    /// receipts do not carry one today).
    static func publish(
        summary: String,
        url: URL,
        sha256: String?,
        byteCount: Int?,
        producerTool: String,
        slot: String,
        mimeType: String,
        uti: String? = nil,
        exitStatus: Int32? = nil,
        using context: ToolContext
    ) throws -> ToolExecutionOutput {
        let digest: String
        let size: Int
        if let sha256, let byteCount {
            digest = sha256
            size = byteCount
        } else {
            digest = try FloeDigest.sha256Hex(ofFileAt: url,
                                              isCancelled: { context.cancellation.isCancelled })
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let measured = values.fileSize, measured >= 0 else {
                throw sourceUnavailable("output is not a regular file")
            }
            size = measured
        }
        do {
            let published = try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(
                    producerTool: producerTool,
                    slot: slot,
                    commit: RunOutputCommit(
                        sourceURL: url,
                        sha256: digest,
                        byteCount: size,
                        displayName: url.lastPathComponent,
                        mimeType: mimeType,
                        uti: uti
                    )
                ),
                using: context
            )
            return ToolExecutionOutput(digesting: summary, exitStatus: exitStatus, outputFiles: [published])
        } catch let error as RunOutputSnapshotError {
            throw publicationFailure(error)
        } catch {
            if (error as? FloeError) == .cancelled || error is CancellationError { throw error }
            throw sourceUnavailable("output could not be measured")
        }
    }
}

/// Explicit ownership context a tool call must present for project access.
/// The host refuses a project whose recorded environment/task workspace does
/// not match the caller's, so `media.project` can never reach a project that
/// belongs to another environment or task.
public struct MediaProjectAccess: Sendable, Hashable {
    public var environmentID: String?
    public var workspacePath: String?
    public var ownerKind: String?
    public var ownerID: UUID?

    public init(environmentID: String? = nil, workspacePath: String? = nil,
                ownerKind: String? = nil, ownerID: UUID? = nil) {
        self.environmentID = environmentID
        self.workspacePath = workspacePath
        self.ownerKind = ownerKind
        self.ownerID = ownerID
    }
}

/// Host boundary implemented by the app, where workspace ownership,
/// credentials and renderers live.
public protocol MediaProjectHost: Sendable, MediaCommandEnrichmentHost {
    /// Refuses access when the project's recorded environment/task ownership
    /// does not match the caller. Called before every load/propose/apply and
    /// before an export is started.
    func authorizeAccess(projectID: UUID, access: MediaProjectAccess) async throws
    func loadProject(id: UUID) async throws -> MediaProject?
    func persistProject(_ project: MediaProject, expectedRevision: Int64?) async throws
    func storeProposal(_ proposal: MediaProposal) async throws
    func loadProposal(id: UUID) async throws -> MediaProposal?
    func removeProposal(id: UUID) async throws
    func consumeGrant(grantID: String, proposalID: UUID, projectID: UUID,
                      revision: Int64) async -> MediaGrantDecision
    func exportVideo(project: MediaProject, options: VideoExportOptions,
                     relativeOutput: String, cancellation: CancellationToken?) async throws -> WorkbenchVideoExportReceipt
    func exportImage(project: MediaProject, options: ImageExportOptions,
                     relativeOutput: String) async throws -> WorkbenchImageExportReceipt

    /// Measures untransformed rendered layer sizes in canvas pixels so edge/
    /// center alignment can use real rendered bounds (the pure model has no
    /// asset bytes). Default unsupported; the app implements it.
    func measureLayers(project: MediaProject, layerIDs: [UUID]) async throws -> [LayerNaturalSize]

    /// Renders ONLY the named layers to a transparent full-canvas image via the
    /// real pipeline and stages it as a new image asset file on disk. The tool
    /// prepends an `add_asset` command for it to the proposal, so the project
    /// is not mutated until an authorized apply. Never a screen capture.
    func renderMergeAsset(project: MediaProject, layerIDs: [UUID], name: String?) async throws -> MergePreparation
}

public struct MergePreparation: Sendable {
    /// Staged asset to add (via `add_asset`) immediately before the merge.
    public var asset: MediaAssetReference
    public var raster: MergedLayerRaster
    public init(asset: MediaAssetReference, raster: MergedLayerRaster) {
        self.asset = asset; self.raster = raster
    }
}

public extension MediaProjectHost {
    func measureLayers(project: MediaProject, layerIDs: [UUID]) async throws -> [LayerNaturalSize] {
        throw FloeError.validationFailed("layer alignment requires the app image renderer")
    }
    func renderMergeAsset(project: MediaProject, layerIDs: [UUID], name: String?) async throws -> MergePreparation {
        throw FloeError.validationFailed("layer merge requires the app image renderer")
    }
}

public struct MediaProjectTool: AgentTool {
    public typealias Arguments = MediaProjectArguments

    public static let name = "media.project"
    public static let toolDescription = """
    Read, inspect capabilities of, propose changes to, apply proposals to, or export a Floe \
    unified image/video workbench project. Workflow is discover -> read/capabilities -> propose (draft, \
    revision-bound) -> apply -> readback/export. propose stores a pending draft and returns without pausing. \
    apply has two authority modes: for an already-authorized task, call apply with the same project_id and \
    proposal_id and NO grant_id — the runtime authorizes this exact call, applies it as a verified automatic \
    transaction, reopens the persisted project and reports the verified revision digest with the source \
    assets unchanged; with grant_id (the user accepted this proposal in the workbench UI after explicitly \
    requesting review) it commits through the interactive path. A model cannot mint a grant or an \
    authorization, and cannot force an overwrite of original assets. Proposals never change the project \
    until an authorized apply; editing the current draft and making a variant are distinct: use the bound \
    project for the current draft, forks for variants.
    """
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false

    public static let parametersJSON = #"""
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["action", "project_id"],
      "properties": {
        "action": { "type": "string", "enum": ["capabilities", "read", "propose", "apply", "export"], "description": "capabilities/read are safe queries; propose stores a revision-bound draft (no change, no pause); apply without grant_id uses the runtime authority for this exact call (already-authorized tasks), with grant_id it commits a user-accepted proposal; export writes verified bytes under Workbench/Exports." },
        "project_id": { "type": "string", "format": "uuid", "description": "Stable project UUID (from media.project read / the workbench UI)." },
        "summary": { "type": "string", "maxLength": 2000, "description": "Human-readable summary shown to the user before acceptance (propose)." },
        "commands": {
          "type": "array",
          "description": "Edit commands (propose only). Each object requires type. Supported image commands: add_asset {kind: image|video|audio, relative_path}; relink_asset {asset_id, relative_path}; set_canvas {width, height, frame_rate?}; add_image_layer {kind: image|text|freehand|fill, name?, asset_id?, transform?{center_x,center_y,scale,rotation_degrees,flip_x?,flip_y?}, opacity?, is_hidden?, is_locked?, text?{text,font_size,color_hex,font_name?,tracking?,leading?,alignment?:left|center|right,stroke_color_hex?,stroke_width?,shadow?{color_hex,blur,offset_x,offset_y}}, freehand?{strokes:[{points:[{x,y,pressure?}],width,color_hex,hardness?,opacity?}]}, crop?, adjustment?, mask?{strokes:[{points,width,hardness?,restore}]}, selection_mask?, fill_color_hex?}; update_layer {id, transform?, opacity?, is_hidden?, is_locked?, adjustment?{saturation,contrast,brightness,exposure_ev,blur_radius,sharpen_radius,mosaic_block_size,filter_id,temperature,hue_degrees,levels?{black,white,gamma}}, text?, crop?|null}; add_freehand_stroke {id, points:[{x,y,pressure?}], width, color_hex, hardness?, opacity?}; set_canvas_adjustment {same adjustment fields applied once to the flattened result}; reorder_layers {ordered_ids}; move_layer {id, to_index}; duplicate_layer {id, name?}; remove_layer {id}; set_selection {selection:{shapes:[{kind:rectangle|ellipse|lasso,operation?:replace|add|subtract,points:[{x,y}]}],feather?,inverted?}}; clear_selection; set_layer_selection {id, selection:null|{...}}; add_mask_stroke {id, points:[{x,y}],width,hardness?,restore?}; clear_layer_mask {id}; flip_layer {id, horizontal?:true|false}; align_layers {ids:[uuid...], alignment:left|centerX|right|top|centerY|bottom} (renderer-measured bounds are filled in automatically); merge_layers {ids:[uuid...], name?} (raster-merges visible layers via the real renderer into one reversible image layer). Video commands: append_clip {asset_id, trim_start, trim_end, speed?, volume?, is_muted?, rotation_degrees?, crop?, leading_transition?, transition_duration?}; update_clip {...}; reorder_clips {ordered_ids}; split_clip {id, at_seconds}; duplicate_clip {id}; remove_clip {id}; set_cover {time?}; shift_captions {by_seconds}; set_primary_audio {volume?, muted?}; add_music {...}; update_music {...}; remove_music {id}; add_caption {start, end, text, source?}; update_caption {id, start?, end?, text?}; remove_caption {id}; set_caption_style {font_size?,color_hex?,background_hex?,position_y?,alignment?:leading|center|trailing,respects_safe_area?}. Unknown types are rejected. Discover workflow: call action=capabilities first, then read, then propose a batch; for an already-authorized editing task apply without grant_id, then verify the returned revision and the export receipt. Wait for UI adoption only when the user asked to review first or the runtime requires approval.",
          "items": { "type": "object", "required": ["type"], "properties": { "type": { "type": "string" } } }
        },
        "proposal_id": { "type": "string", "format": "uuid", "description": "Proposal id returned by propose (apply only). For apply, pass this id with the same project_id and no grant_id unless the user explicitly asked to review in the workbench UI." },
        "grant_id": { "type": "string", "description": "Opaque single-use confirmation token issued by the workbench UI after user acceptance — only when the user explicitly requested review. The model cannot mint this. OMIT for the ordinary already-authorized apply: the runtime authority for this exact call is the authorization." },
        "export": {
          "type": "object",
          "additionalProperties": false,
          "required": ["kind", "file_name"],
          "properties": {
            "kind": { "type": "string", "enum": ["image", "video"] },
            "file_name": { "type": "string", "maxLength": 200 },
            "format": { "type": "string", "enum": ["png", "jpeg", "heic"], "description": "image exports" },
            "width": { "type": "integer", "minimum": 2, "maximum": 16384 },
            "height": { "type": "integer", "minimum": 2, "maximum": 16384 },
            "quality": { "type": "number", "minimum": 0.01, "maximum": 1 },
            "preserve_transparency": { "type": "boolean", "description": "JPEG + transparency + alpha pixels is rejected, not flattened silently." },
            "strip_metadata": { "type": "boolean" },
            "codec": { "type": "string", "enum": ["h264", "hevc"], "description": "video exports" },
            "frame_rate": { "type": "number", "exclusiveMinimum": 0, "maximum": 240 },
            "preset": { "type": "string", "enum": ["landscape1080p", "portrait1080p", "square1080"], "description": "video export preset; sets concrete width/height (frame_rate still required unless the project canvas has one)." }
          }
        }
      }
    }
    """#

    private let host: MediaProjectHost

    public init(host: MediaProjectHost) {
        self.host = host
    }

    /// Canonical JSON of the DECODED approved arguments, in exactly the shape
    /// the runtime hashed when it minted this call's authority. Optional fields
    /// that were absent stay absent. Identifier strings keep the RAW approved
    /// spelling (`projectIDRaw`/`proposalIDRaw`): the runtime digests the raw
    /// arguments bytes, so the consumer binds the exact id string the tool
    /// printed and the model echoed — a call re-spelled in a different case is
    /// a different payload (mirrors the CAD applied-proposal contract).
    static func canonicalApprovedPayload(_ args: MediaProjectArguments) throws -> Data {
        var object: [String: Any] = ["action": args.action.rawValue]
        object["project_id"] = args.projectIDRaw ?? args.projectID.uuidString
        if let summary = args.summary { object["summary"] = summary }
        if let commands = args.commands { object["commands"] = commands.map { $0.mapValues(\.jsonValue) } }
        if let proposalID = args.proposalID {
            object["proposal_id"] = args.proposalIDRaw ?? proposalID.uuidString
        }
        if let grantID = args.grantID { object["grant_id"] = grantID }
        if let export = args.export { object["export"] = export.jsonValue }
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }

    /// Mirrors `RuntimeAuthorityDigest.canonicalTarget` for this tool: no
    /// mutation-key path argument, so the runtime resolves the workspace
    /// wildcard from the canonical root.
    static func canonicalTarget(context: ToolContext) -> String {
        guard let root = context.workspaceRootURL else { return "workspace:*" }
        return "workspace:" + root.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Builds the binding this apply call implies, exactly like the runtime
    /// minted it. Throws only when the approved arguments cannot be
    /// canonicalized (itself a refusal, never a bypass).
    static func runtimeAuthorityBinding(for args: MediaProjectArguments,
                                        context: ToolContext) throws -> RuntimeAuthorityBinding {
        let payload = try canonicalApprovedPayload(args)
        return context.runtimeAuthorityBinding(
            toolName: name,
            operation: "apply",
            canonicalTarget: canonicalTarget(context: context),
            baseRevision: RuntimeAuthorityDigest.baseRevision(in: payload),
            payloadDigest: RuntimeAuthorityDigest.payloadDigest(payload))
    }

    public func validate(_ args: Arguments) throws {
        switch args.action {
        case .capabilities, .read:
            break
        case .propose:
            guard let commands = args.commands, !commands.isEmpty else {
                throw FloeError.validationFailed("propose requires at least one command")
            }
            guard args.summary?.isEmpty == false else {
                throw FloeError.validationFailed("propose requires a human-readable summary")
            }
        case .apply:
            guard let proposalID = args.proposalID else {
                throw FloeError.validationFailed("apply requires proposal_id")
            }
            _ = proposalID
        case .export:
            guard let export = args.export else {
                throw FloeError.validationFailed("export requires an export specification")
            }
            try export.validate()
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        // Explicit ownership: the host refuses projects from another
        // environment/task before any read, proposal, apply or export.
        let access = MediaProjectAccess(environmentID: context.environmentID,
                                        workspacePath: context.workspaceRootURL?
                                            .resolvingSymlinksInPath().standardizedFileURL.path,
                                        ownerKind: context.conversationID == nil ? nil : "chat",
                                        ownerID: context.conversationID)
        try await host.authorizeAccess(projectID: args.projectID, access: access)
        guard let project = try await host.loadProject(id: args.projectID) else {
            throw FloeError.notFound("media project \(args.projectID.uuidString)")
        }
        switch args.action {
        case .capabilities:
            return ToolExecutionOutput(digesting: MediaProjectSummaries.capabilities(project))

        case .read:
            let summary = try MediaProjectSummaries.summary(project)
            return ToolExecutionOutput(digesting: summary)

        case .propose:
            let decoded = try MediaProjectCommandCoding.commands(from: args.commands ?? [])
            // Fill renderer-dependent payloads (edge alignment measurements,
            // raster merge asset) through the real app renderer before the
            // all-or-nothing dry run. The project is not mutated here.
            let commands = try await MediaCommandEnrichment.enrich(decoded, project: project, host: host)
            let proposal = MediaProposal(projectID: project.id, baseRevision: project.revision,
                                         summary: args.summary ?? "", commands: commands)
            // Full dry run validates every command on a draft; throws on the
            // first invalid command without touching the project.
            _ = try MediaProposalGate.dryRun(proposal, against: project)
            try await host.storeProposal(proposal)
            let preview = try MediaProjectSummaries.preview(proposal: proposal, project: project)
            // The revision-bound draft is stored and returned as a preview;
            // the run CONTINUES without a forced user-action checkpoint so
            // the ordinary document workflow (propose -> runtime-authorized
            // apply -> verified export) can close in one model turn. The
            // proposal stays pending and visible in the workbench UI, and
            // applying it still requires the user's single-use UI grant or
            // the runtime-approved call authority for that exact call — the
            // automatic apply path below verifies both. Mirrors the CAD
            // propose contract.
            return ToolExecutionOutput(digesting: preview, requiresUserAction: false)

        case .apply:
            guard let proposalID = args.proposalID else {
                throw FloeError.validationFailed("proposal_id is required")
            }
            guard let proposal = try await host.loadProposal(id: proposalID) else {
                throw FloeError.notFound("proposal \(proposalID.uuidString)")
            }
            guard var live = try await host.loadProject(id: project.id) else {
                throw FloeError.notFound("media project disappeared")
            }
            let grantText = (args.grantID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !grantText.isEmpty {
                // Interactive path: trusted, single-use, revision-bound grant.
                let decision = await host.consumeGrant(grantID: grantText, proposalID: proposal.id,
                                                       projectID: project.id, revision: live.revision)
                // Tool-supplied grant ids are not authority; the host owns grants.
                try MediaProposalGate.applyAuthorized(proposal, grant: decision, to: &live)
                try await host.persistProject(live, expectedRevision: project.revision)
                try await host.removeProposal(id: proposal.id)
                let summary = try MediaProjectSummaries.summary(live)
                return ToolExecutionOutput(digesting: "Proposal applied as revision \(live.revision).\n\(summary)")
            }
            // Automatic path: the ONLY authority is the runtime-issued task
            // authority for this exact approved call. A model-supplied
            // confirmed flag or grant-looking string is never consulted.
            let binding = try Self.runtimeAuthorityBinding(for: args, context: context)
            let verdict = await context.consumeRuntimeAuthority(binding: binding)
            guard verdict.isValid else {
                throw FloeError.validationFailed(
                    "automatic apply needs the runtime-approved call authority for this exact operation"
                        + (verdict.failureReason.map { " (\($0))" } ?? "")
                        + "; confirm the proposal in the workbench UI (grant_id), or send the apply call "
                        + "with canonical JSON arguments (omit optional fields instead of null).")
            }
            let beforeAssets = MediaAutomaticVerification.assetHashes(live)
            let proof = MediaAutomaticAuthorization(
                runID: context.runID,
                taskID: context.conversationID,
                operationID: context.toolCallID ?? "",
                idempotencyKey: context.toolIdempotencyKey,
                approvalGrantID: context.approvalGrantID,
                canonicalTarget: binding.canonicalTarget,
                baseRevision: live.revision,
                payloadDigest: binding.payloadDigest,
                commandsDigest: MediaProposalGate.commandsDigest(proposal.commands),
                proposalID: proposal.id)
            try MediaProposalGate.applyAutomatic(proposal, authorization: proof, to: &live)
            let appliedRevision = live.revision
            try await host.persistProject(live, expectedRevision: project.revision)
            try await host.removeProposal(id: proposal.id)
            // REOPEN the persisted project and verify the snapshot: the exact
            // revision is readable again, its canonical digest is recorded and
            // the referenced source assets are untouched.
            guard let reopened = try await host.loadProject(id: project.id) else {
                throw FloeError.validationFailed(
                    "the applied project could not be reopened; treat the revision as unverified")
            }
            guard reopened.revision == appliedRevision else {
                throw FloeError.validationFailed(
                    "the reopened project reports revision \(reopened.revision), expected \(appliedRevision)")
            }
            let reopenedAssets = MediaAutomaticVerification.assetHashes(reopened)
            guard reopenedAssets == beforeAssets else {
                throw FloeError.validationFailed(
                    "the apply changed referenced source assets; the revision is not a safe snapshot")
            }
            let digest = MediaAutomaticVerification.canonicalProjectDigest(reopened)
            let summary = try MediaProjectSummaries.summary(reopened)
            let receipt = """
            status=applied mode=automatic revision=\(reopened.revision) \
            projectDigest=\(digest) sourceAssetsUnchanged=true \
            authorization=\(proof.operationID)
            \(summary)
            """
            return ToolExecutionOutput(digesting: receipt)

        case .export:
            guard let spec = args.export else {
                throw FloeError.validationFailed("export specification is required")
            }
            if spec.kind == "video" {
                let options = try spec.videoOptions(project: project)
                // ONE derivation shared with the typed mutable-target
                // contract: `Workbench/Exports/<file_name>.mp4`.
                guard let output = MediaExportOutputContract.relativeOutput(
                    kind: spec.kind, fileName: options.fileName, format: nil
                ) else {
                    throw FloeError.validationFailed("invalid export file name")
                }
                let receipt = try await host.exportVideo(project: project, options: options,
                                                         relativeOutput: output,
                                                         cancellation: context.cancellation)
                // S3-D: the verified Workbench video export is a genuine user
                // file. Publication adds the post-write streamed digest the
                // host receipt does not carry; failures follow the fixed
                // observable policy and never touch the exported original.
                let summary = MediaProjectSummaries.receipt(receipt)
                switch RunOutputWorkbenchPublication.state(context) {
                case .legacyDirect, .temporaryExempt:
                    return ToolExecutionOutput(digesting: summary)
                case .partiallyBound:
                    throw RunOutputWorkbenchPublication.partialBindingFailure
                case .required:
                    return try RunOutputWorkbenchPublication.publish(
                        summary: summary,
                        url: receipt.url,
                        sha256: nil,
                        byteCount: nil,
                        producerTool: Self.name,
                        slot: "video",
                        mimeType: "video/mp4",
                        using: context)
                }
            } else {
                let options = try spec.imageOptions(project: project)
                // ONE derivation shared with the typed mutable-target
                // contract: `Workbench/Exports/<file_name>.<format extension>`
                // (png/jpeg/heic); an unsupported format fails closed.
                guard let output = MediaExportOutputContract.relativeOutput(
                    kind: spec.kind, fileName: options.fileName,
                    format: options.format.rawValue
                ) else {
                    throw FloeError.validationFailed("invalid export file name")
                }
                let receipt = try await host.exportImage(project: project, options: options,
                                                         relativeOutput: output)
                // S3-D: verified image export publishes with a post-write
                // streamed digest under the fixed failure policy.
                let summary = MediaProjectSummaries.receipt(receipt)
                let imageMIME: String
                let imageUTI: String?
                switch options.format.rawValue.lowercased() {
                case "png": imageMIME = "image/png"; imageUTI = "public.png"
                case "jpeg": imageMIME = "image/jpeg"; imageUTI = "public.jpeg"
                case "heic": imageMIME = "image/heic"; imageUTI = "public.heic"
                default: imageMIME = "application/octet-stream"; imageUTI = nil
                }
                switch RunOutputWorkbenchPublication.state(context) {
                case .legacyDirect, .temporaryExempt:
                    return ToolExecutionOutput(digesting: summary)
                case .partiallyBound:
                    throw RunOutputWorkbenchPublication.partialBindingFailure
                case .required:
                    return try RunOutputWorkbenchPublication.publish(
                        summary: summary,
                        url: receipt.url,
                        sha256: nil,
                        byteCount: nil,
                        producerTool: Self.name,
                        slot: "image",
                        mimeType: imageMIME,
                        uti: imageUTI,
                        using: context)
                }
            }
        }
    }
}

// MARK: - Arguments

public struct MediaProjectArguments: Decodable, Sendable {
    public let action: MediaProjectAction
    public let projectID: UUID
    /// Raw `project_id` spelling exactly as the approved call carried it. The
    /// runtime digests the RAW approved arguments; this consumer must derive
    /// its binding from the same bytes, so the canonical payload keeps the
    /// exact spelling the tool printed (and the model echoes). Nil when the
    /// arguments were constructed programmatically.
    public let projectIDRaw: String?
    public let summary: String?
    public let commands: [[String: AnyCodableValue]]?
    public let proposalID: UUID?
    /// Raw `proposal_id` spelling (see `projectIDRaw`).
    public let proposalIDRaw: String?
    public let grantID: String?
    public let export: MediaExportArguments?

    enum CodingKeys: String, CodingKey {
        case action
        case projectID = "project_id"
        case summary
        case commands
        case proposalID = "proposal_id"
        case grantID = "grant_id"
        case export
    }

    public init(action: MediaProjectAction, projectID: UUID, summary: String?,
                commands: [[String: AnyCodableValue]]?, proposalID: UUID?,
                grantID: String?, export: MediaExportArguments?) {
        self.action = action
        self.projectID = projectID
        self.projectIDRaw = nil
        self.summary = summary
        self.commands = commands
        self.proposalID = proposalID
        self.proposalIDRaw = nil
        self.grantID = grantID
        self.export = export
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(MediaProjectAction.self, forKey: .action)
        let rawProjectID = try container.decode(String.self, forKey: .projectID)
        guard let parsedProjectID = UUID(uuidString: rawProjectID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .projectID, in: container,
                debugDescription: "project_id must be a UUID string")
        }
        projectID = parsedProjectID
        projectIDRaw = rawProjectID
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        commands = try container.decodeIfPresent([[String: AnyCodableValue]].self, forKey: .commands)
        if let rawProposalID = try container.decodeIfPresent(String.self, forKey: .proposalID) {
            guard let parsedProposalID = UUID(uuidString: rawProposalID) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .proposalID, in: container,
                    debugDescription: "proposal_id must be a UUID string")
            }
            proposalID = parsedProposalID
            proposalIDRaw = rawProposalID
        } else {
            proposalID = nil
            proposalIDRaw = nil
        }
        grantID = try container.decodeIfPresent(String.self, forKey: .grantID)
        export = try container.decodeIfPresent(MediaExportArguments.self, forKey: .export)
    }
}

public enum MediaProjectAction: String, Decodable, Sendable {
    case capabilities, read, propose, apply, export
}

/// Loosely-typed JSON value used only at the tool argument boundary; command
/// decoding validates everything explicitly.
public enum AnyCodableValue: Decodable, Sendable, Hashable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case object([String: AnyCodableValue])
    case array([AnyCodableValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([AnyCodableValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: AnyCodableValue].self)) }
    }

    var jsonValue: Any {
        switch self {
        case .string(let v): v
        case .number(let v): v
        case .boolean(let v): v
        case .object(let v): v.mapValues(\.jsonValue)
        case .array(let v): v.map(\.jsonValue)
        case .null: NSNull()
        }
    }
}

public struct MediaExportArguments: Decodable, Sendable {
    public let kind: String
    public let fileName: String
    public let format: String?
    public let width: Int?
    public let height: Int?
    public let quality: Double?
    public let preserveTransparency: Bool?
    public let stripMetadata: Bool?
    public let codec: String?
    public let frameRate: Double?
    public let preset: String?

    enum CodingKeys: String, CodingKey {
        case kind, width, height, quality, format, codec, preset
        case fileName = "file_name"
        case preserveTransparency = "preserve_transparency"
        case stripMetadata = "strip_metadata"
        case frameRate = "frame_rate"
    }

    /// JSON-compatible canonical shape (for the approved-payload digest).
    var jsonValue: [String: Any] {
        var object: [String: Any] = ["kind": kind, "file_name": fileName]
        if let format { object["format"] = format }
        if let width { object["width"] = width }
        if let height { object["height"] = height }
        if let quality { object["quality"] = quality }
        if let preserveTransparency { object["preserve_transparency"] = preserveTransparency }
        if let stripMetadata { object["strip_metadata"] = stripMetadata }
        if let codec { object["codec"] = codec }
        if let frameRate { object["frame_rate"] = frameRate }
        if let preset { object["preset"] = preset }
        return object
    }

    func validate() throws {
        guard kind == "image" || kind == "video" else {
            throw FloeError.validationFailed("export.kind must be image or video")
        }
        guard MediaExportOutputContract.isValidFileName(fileName) else {
            throw FloeError.validationFailed("invalid export file name")
        }
    }

    func imageOptions(project: MediaProject) throws -> ImageExportOptions {
        guard let formatRaw = format, let format = ImageExportFormat(rawValue: formatRaw) else {
            throw FloeError.validationFailed("image export requires format png/jpeg/heic")
        }
        return ImageExportOptions(format: format, width: width, height: height,
                                  quality: quality ?? 0.95,
                                  preserveTransparency: preserveTransparency ?? true,
                                  stripMetadata: stripMetadata ?? true,
                                  fileName: fileName)
    }

    func videoOptions(project: MediaProject) throws -> VideoExportOptions {
        guard let codecRaw = codec, let codec = VideoExportCodec(rawValue: codecRaw) else {
            throw FloeError.validationFailed("video export requires codec h264/hevc")
        }
        if let presetRaw = preset {
            guard let preset = VideoExportPreset(rawValue: presetRaw) else {
                throw FloeError.validationFailed(
                    "video export preset must be landscape1080p/portrait1080p/square1080")
            }
            // Explicit width/height (if also supplied) must agree with the preset.
            if let width, width != preset.width {
                throw FloeError.validationFailed("width \(width) does not match preset \(presetRaw) (\(preset.width))")
            }
            if let height, height != preset.height {
                throw FloeError.validationFailed("height \(height) does not match preset \(presetRaw) (\(preset.height))")
            }
            let fps = frameRate ?? project.canvas?.frameRate ?? preset.defaultFrameRate
            return preset.options(frameRate: fps, codec: codec, fileName: fileName)
        }
        guard let canvas = project.canvas, let fps = frameRate ?? canvas.frameRate else {
            throw FloeError.validationFailed("video export requires explicit frame_rate")
        }
        let exportWidth = width ?? canvas.width
        let exportHeight = height ?? canvas.height
        return VideoExportOptions(codec: codec, width: exportWidth, height: exportHeight,
                                  frameRate: fps, quality: quality ?? 0.9, fileName: fileName)
    }
}
