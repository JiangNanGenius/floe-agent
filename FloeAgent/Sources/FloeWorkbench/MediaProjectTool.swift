// FloeWorkbench — media.project tool.
//
// One tool, four actions with explicit effect levels:
//   read      — read-only project summary
//   propose   — validates a command sequence against a revision, stores a
//               pending proposal (internal Floe draft state) and returns its
//               preview; changes nothing on disk
//   apply     — requires a trusted UI grant (MediaProposalGrantStore); a
//               fabricated grant id or changed revision is refused
//   export    — writes a verified image/video file (approval-gated)
//
// The tool never mints confirmation itself. Project/environment/task
// ownership is enforced by the injected `MediaProjectHost`, which the app
// supplies from the task workspace (ToolContext.workspaceRootURL) and owner.

import Foundation
import FloeCore
import FloeTools

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
public protocol MediaProjectHost: Sendable {
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
}

public struct MediaProjectTool: AgentTool {
    public typealias Arguments = MediaProjectArguments

    public static let name = "media.project"
    public static let toolDescription = """
    Read, propose changes to, apply confirmed proposals to, or export a Floe \
    unified image/video workbench project. Proposals bind a revision and take \
    effect only after the user accepts them in the workbench UI.
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
        "action": { "type": "string", "enum": ["read", "propose", "apply", "export"] },
        "project_id": { "type": "string", "format": "uuid", "description": "Stable project UUID (from media.project read / the workbench UI)." },
        "summary": { "type": "string", "maxLength": 2000, "description": "Human-readable summary shown to the user before acceptance (propose)." },
        "commands": {
          "type": "array",
          "description": "Edit commands (propose only). Each object requires type. Supported types and required fields: add_asset {kind: image|video|audio, relative_path}; relink_asset {asset_id, relative_path}; set_canvas {width, height, frame_rate?}; add_image_layer {kind: image|text|freehand, name?, asset_id?, transform?{center_x,center_y,scale,rotation_degrees}, opacity?, text?{text,font_size,color_hex}, freehand?{strokes:[{points:[{x,y}],width,color_hex}]}, crop?{x,y,width,height}}; update_layer {id, transform?, opacity?, is_hidden?, is_locked?, adjustment?{saturation,contrast,brightness,exposure_ev,blur_radius,sharpen_radius,mosaic_block_size,filter_id}, text?{text,font_size,color_hex}, crop?{x,y,width,height}|null}; reorder_layers {ordered_ids}; move_layer {id, to_index}; remove_layer {id}; set_canvas_adjustment {saturation?,contrast?,brightness?,exposure_ev?,blur_radius?,sharpen_radius?,mosaic_block_size?,filter_id?}; append_clip {asset_id, trim_start, trim_end, speed?, volume?, is_muted?, rotation_degrees?, crop?, leading_transition?: none|crossDissolve, transition_duration?}; update_clip {id, trim_start?, trim_end?, speed?, volume?, is_muted?, rotation_degrees?, crop?, leading_transition?, transition_duration?}; reorder_clips {ordered_ids}; split_clip {id, at_seconds}; remove_clip {id}; set_primary_audio {volume?, muted?}; add_music {asset_id, offset_seconds, trim_start?, length_seconds, volume?, fade_in_seconds?, fade_out_seconds?}; update_music {id, offset_seconds?, trim_start?, length_seconds?, volume?, fade_in_seconds?, fade_out_seconds?}; remove_music {id}; add_caption {start, end, text, source?: manual|transcription}; update_caption {id, start?, end?, text?}; remove_caption {id}; set_caption_style {font_size?, color_hex?, background_hex?, position_y?}. Unknown types are rejected.",
          "items": { "type": "object", "required": ["type"], "properties": { "type": { "type": "string" } } }
        },
        "proposal_id": { "type": "string", "format": "uuid", "description": "Proposal id returned by propose (apply only)." },
        "grant_id": { "type": "string", "description": "Opaque confirmation token issued by the workbench UI after user acceptance. The model cannot mint this." },
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
            "frame_rate": { "type": "number", "exclusiveMinimum": 0, "maximum": 240 }
          }
        }
      }
    }
    """#

    private let host: MediaProjectHost

    public init(host: MediaProjectHost) {
        self.host = host
    }

    public func validate(_ args: Arguments) throws {
        switch args.action {
        case .read:
            break
        case .propose:
            guard let commands = args.commands, !commands.isEmpty else {
                throw FloeError.validationFailed("propose requires at least one command")
            }
            guard args.summary?.isEmpty == false else {
                throw FloeError.validationFailed("propose requires a human-readable summary")
            }
        case .apply:
            guard let proposalID = args.proposalID, let grantID = args.grantID,
                  !grantID.isEmpty else {
                throw FloeError.validationFailed("apply requires proposal_id and a UI-issued grant_id")
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
        case .read:
            let summary = try MediaProjectSummaries.summary(project)
            return ToolExecutionOutput(digesting: summary)

        case .propose:
            let commands = try MediaProjectCommandCoding.commands(from: args.commands ?? [])
            let proposal = MediaProposal(projectID: project.id, baseRevision: project.revision,
                                         summary: args.summary ?? "", commands: commands)
            // Full dry run validates every command on a draft; throws on the
            // first invalid command without touching the project.
            _ = try MediaProposalGate.dryRun(proposal, against: project)
            try await host.storeProposal(proposal)
            let preview = try MediaProjectSummaries.preview(proposal: proposal, project: project)
            return ToolExecutionOutput(digesting: preview, requiresUserAction: true)

        case .apply:
            guard let proposalID = args.proposalID, let grantID = args.grantID else {
                throw FloeError.validationFailed("proposal_id and grant_id are required")
            }
            guard let proposal = try await host.loadProposal(id: proposalID) else {
                throw FloeError.notFound("proposal \(proposalID.uuidString)")
            }
            guard var live = try await host.loadProject(id: project.id) else {
                throw FloeError.notFound("media project disappeared")
            }
            // Trusted, single-use, revision-bound grant.
            let decision = await host.consumeGrant(grantID: grantID, proposalID: proposal.id,
                                                   projectID: project.id, revision: live.revision)
            // Tool-supplied grant ids are not authority; the host owns grants.
            try MediaProposalGate.applyAuthorized(proposal, grant: decision, to: &live)
            try await host.persistProject(live, expectedRevision: project.revision)
            try await host.removeProposal(id: proposal.id)
            let summary = try MediaProjectSummaries.summary(live)
            return ToolExecutionOutput(digesting: "Proposal applied as revision \(live.revision).\n\(summary)")

        case .export:
            guard let spec = args.export else {
                throw FloeError.validationFailed("export specification is required")
            }
            if spec.kind == "video" {
                let options = try spec.videoOptions(project: project)
                let output = "Workbench/Exports/\(spec.fileName).mp4"
                let receipt = try await host.exportVideo(project: project, options: options,
                                                         relativeOutput: output,
                                                         cancellation: context.cancellation)
                return ToolExecutionOutput(digesting: MediaProjectSummaries.receipt(receipt))
            } else {
                let options = try spec.imageOptions(project: project)
                let output = "Workbench/Exports/\(options.fileName).\(options.format.fileExtension)"
                let receipt = try await host.exportImage(project: project, options: options,
                                                         relativeOutput: output)
                return ToolExecutionOutput(digesting: MediaProjectSummaries.receipt(receipt))
            }
        }
    }
}

// MARK: - Arguments

public struct MediaProjectArguments: Decodable, Sendable {
    public let action: MediaProjectAction
    public let projectID: UUID
    public let summary: String?
    public let commands: [[String: AnyCodableValue]]?
    public let proposalID: UUID?
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
}

public enum MediaProjectAction: String, Decodable, Sendable {
    case read, propose, apply, export
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

    enum CodingKeys: String, CodingKey {
        case kind, width, height, quality, format, codec
        case fileName = "file_name"
        case preserveTransparency = "preserve_transparency"
        case stripMetadata = "strip_metadata"
        case frameRate = "frame_rate"
    }

    func validate() throws {
        guard kind == "image" || kind == "video" else {
            throw FloeError.validationFailed("export.kind must be image or video")
        }
        guard fileName.range(of: #"^[A-Za-z0-9][A-Za-z0-9 _-]{0,199}$"#, options: .regularExpression) != nil else {
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
        guard let canvas = project.canvas, let fps = frameRate ?? canvas.frameRate else {
            throw FloeError.validationFailed("video export requires explicit frame_rate")
        }
        let exportWidth = width ?? canvas.width
        let exportHeight = height ?? canvas.height
        return VideoExportOptions(codec: codec, width: exportWidth, height: exportHeight,
                                  frameRate: fps, quality: quality ?? 0.9, fileName: fileName)
    }
}
