// FloeApp — Design workflow agent tools.
//
// These extend the existing Canvas tool family (same `canvas.` namespace and
// policy ceiling) with the approved design lifecycle: query brief/spec/
// artifacts/feedback, create a project, add anchored feedback, propose a
// revision-bound candidate, then confirm adopt/reject/restore. AI proposals are
// candidates only; adoption is side-effecting and approval-gated. Input content
// (tool results, imported documents, model text) can never grant permissions and
// never resolves feedback — only a real content change at the current revision
// does (enforced by `DesignWorkflowEngine`).

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeTools

/// Shared host for the design tools. Holds the file-backed project store rooted
/// under the app's artifact store so projects survive app upgrades and are never
/// written into a temporary directory.
actor DesignToolHost {
    let store: DesignProjectStore

    init(rootURL: URL? = nil) {
        let root = rootURL
            ?? (try? FloeArtifactStore.root())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("FloeAgent", isDirectory: true)
        self.store = DesignProjectStore(rootURL: root)
    }

    /// Create-if-missing; returns the stored project.
    func create(
        id: String?,
        canvasID: String?,
        contentType: DesignContentType,
        goal: String,
        audience: String?
    ) throws -> DesignProject {
        let projectID = id ?? UUID().uuidString.lowercased()
        if let existing = try? store.load(id: projectID) { return existing }
        let project = DesignWorkflowEngine.createProject(
            id: projectID,
            canvasID: canvasID,
            contentType: contentType,
            brief: DesignBrief(goal: goal, audience: audience)
        )
        try store.save(project)
        return project
    }
}

enum DesignToolOutput {
    static func make(_ dictionary: [String: Any], status: Int32 = 0) -> ToolExecutionOutput {
        let data = (try? JSONSerialization.data(
            withJSONObject: dictionary,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("{}".utf8)
        let text = String(decoding: data, as: UTF8.self)
        return ToolExecutionOutput(
            summary: text,
            fullOutputSHA256: FloeDigest.sha256Hex(data),
            exitStatus: status
        )
    }

    static func projectState(_ project: DesignProject) -> [String: Any] {
        var result: [String: Any] = [
            "projectID": project.id,
            "contentType": project.contentType.rawValue,
            "schemaVersion": project.schemaVersion,
            "updatedAt": ISO8601DateFormatter().string(from: project.updatedAt)
        ]
        if let canvasID = project.canvasID { result["canvasID"] = canvasID }
        if let brief = project.brief {
            result["brief"] = [
                "goal": brief.goal,
                "audience": brief.audience ?? "",
                "constraints": brief.constraints
            ]
        }
        if let spec = project.spec {
            result["spec"] = [
                "sha256": spec.sha256,
                "palette": spec.palette ?? [],
                "typography": spec.typography ?? "",
                "layout": spec.layout ?? "",
                "spacing": spec.spacing ?? "",
                "brandAssetRefs": spec.brandAssetRefs ?? [],
                "voice": spec.voice ?? "",
                "prohibitions": spec.prohibitions ?? [],
                "hasRawMarkdown": spec.rawMarkdown != nil
            ]
        }
        if let template = project.template {
            result["template"] = [
                "id": template.id,
                "name": template.name,
                "version": template.version,
                "contentSHA256": template.contentSHA256,
                "capabilities": template.capabilities,
                "inputs": template.inputs,
                "dependencies": template.dependencies,
                "outputFormats": template.outputFormats,
                "license": template.license,
                "source": template.source,
                "rollbackVersion": template.rollbackVersion ?? ""
            ]
        }
        if let frozen = project.frozenRun {
            result["frozenRun"] = [
                "operationID": frozen.operationID,
                "inputRevisionID": frozen.inputRevisionID ?? "",
                "specSHA256": frozen.specSHA256 ?? "",
                "targetRevisionID": frozen.targetRevisionID ?? ""
            ]
        }
        result["artifacts"] = project.artifacts.prefix(50).map { artifact -> [String: Any] in
            [
                "artifactID": artifact.id,
                "canvasNodeID": artifact.canvasNodeID ?? "",
                "currentRevisionID": artifact.currentRevisionID ?? "",
                "revisionCount": artifact.revisions.count,
                "name": artifact.identity.name,
                "origin": artifact.currentRevision.map { $0.origin.rawValue } ?? ""
            ]
        }
        result["feedback"] = project.feedback.prefix(100).map { item -> [String: Any] in
            [
                "feedbackID": item.id,
                "artifactID": item.artifactID,
                "revisionID": item.revisionID,
                "anchor": item.anchor.kind,
                "status": item.status.rawValue,
                "comment": String(item.comment.prefix(500))
            ]
        }
        result["candidates"] = project.candidates.prefix(50).map { candidate -> [String: Any] in
            [
                "candidateID": candidate.id,
                "artifactID": candidate.artifactID,
                "baseRevisionID": candidate.baseRevisionID,
                "proposedRevisionID": candidate.proposedRevisionID,
                "status": candidate.status.rawValue,
                "summary": String(candidate.summary.prefix(500)),
                "diff": Array(candidate.diff.prefix(100))
            ]
        }
        return result
    }
}

// MARK: - Tools

private struct DesignGetStateTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var projectID: String?
        var canvasID: String?
    }
    static let name = "canvas.designGetState"
    static let toolDescription = "Read a design project's brief, spec, template, artifacts, revisions, feedback and candidates."
    static let parametersJSON = #"{"type":"object","properties":{"projectID":{"type":"string"},"canvasID":{"type":"string"}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    let host: DesignToolHost

    func validate(_ args: Arguments) throws {}

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let (projects, corrupt) = await host.store.loadAll()
        var selected: [DesignProject] = projects
        if let projectID = args.projectID {
            selected = projects.filter { $0.id == projectID }
        } else if let canvasID = args.canvasID {
            selected = projects.filter { $0.canvasID == canvasID }
        }
        let states = selected.prefix(20).map(DesignToolOutput.projectState)
        var payload: [String: Any] = [
            "projects": states,
            "corruptProjectIDs": corrupt,
            "count": states.count
        ]
        if let first = states.first, states.count == 1 { payload["project"] = first }
        return DesignToolOutput.make(payload)
    }
}

private struct DesignCreateTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var projectID: String?
        var canvasID: String?
        var contentType: DesignContentType
        var goal: String
        var audience: String?
    }
    static let name = "canvas.designCreate"
    static let toolDescription = "Create a design project (brief stage) bound optionally to a canvas."
    static let parametersJSON = #"{"type":"object","properties":{"projectID":{"type":"string"},"canvasID":{"type":"string"},"contentType":{"type":"string","enum":["webpage","prototype","presentation","image","video","officeDocument","notes","pdf","cad"]},"goal":{"type":"string"},"audience":{"type":"string"}},"required":["contentType","goal"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let host: DesignToolHost

    func validate(_ args: Arguments) throws {
        guard !args.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("Design goal must not be empty")
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let project = try await host.create(
            id: args.projectID,
            canvasID: args.canvasID,
            contentType: args.contentType,
            goal: args.goal,
            audience: args.audience
        )
        return DesignToolOutput.make(DesignToolOutput.projectState(project))
    }
}

private struct DesignUpdateBriefTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var projectID: String
        var goal: String
        var audience: String?
        var constraints: [String]?
    }
    static let name = "canvas.designUpdateBrief"
    static let toolDescription = "Update a design project's brief."
    static let parametersJSON = #"{"type":"object","properties":{"projectID":{"type":"string"},"goal":{"type":"string"},"audience":{"type":"string"},"constraints":{"type":"array","items":{"type":"string"}}},"required":["projectID","goal"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let host: DesignToolHost
    func validate(_ args: Arguments) throws {}

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        var project = try await host.store.load(id: args.projectID)
        DesignWorkflowEngine.updateBrief(
            DesignBrief(
                goal: args.goal,
                audience: args.audience,
                constraints: args.constraints ?? []
            ),
            in: &project
        )
        try await host.store.save(project)
        return DesignToolOutput.make(DesignToolOutput.projectState(project))
    }
}

private struct DesignUpdateSpecTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var projectID: String
        var palette: [String]?
        var typography: String?
        var layout: String?
        var spacing: String?
        var brandAssetRefs: [String]?
        var voice: String?
        var prohibitions: [String]?
        var designMarkdown: String?
    }
    static let name = "canvas.designUpdateSpec"
    static let toolDescription = "Update the optional design spec (palette/type/layout/spacing/brand/voice/prohibitions) or import raw DESIGN.md text preserved verbatim."
    static let parametersJSON = #"{"type":"object","properties":{"projectID":{"type":"string"},"palette":{"type":"array","items":{"type":"string"}},"typography":{"type":"string"},"layout":{"type":"string"},"spacing":{"type":"string"},"brandAssetRefs":{"type":"array","items":{"type":"string"}},"voice":{"type":"string"},"prohibitions":{"type":"array","items":{"type":"string"}},"designMarkdown":{"type":"string"}},"required":["projectID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let host: DesignToolHost
    func validate(_ args: Arguments) throws {}

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        var project = try await host.store.load(id: args.projectID)
        var spec: DesignSpec
        if let markdown = args.designMarkdown {
            // Importing DESIGN.md preserves all unknown/raw text.
            spec = DesignMDCodec.parse(markdown)
            spec.palette = args.palette ?? spec.palette
            spec.typography = args.typography ?? spec.typography
            spec.layout = args.layout ?? spec.layout
            spec.spacing = args.spacing ?? spec.spacing
            spec.brandAssetRefs = args.brandAssetRefs ?? spec.brandAssetRefs
            spec.voice = args.voice ?? spec.voice
            spec.prohibitions = args.prohibitions ?? spec.prohibitions
        } else {
            spec = DesignSpec(
                palette: args.palette,
                typography: args.typography,
                layout: args.layout,
                spacing: args.spacing,
                brandAssetRefs: args.brandAssetRefs,
                voice: args.voice,
                prohibitions: args.prohibitions,
                rawMarkdown: project.spec?.rawMarkdown
            )
        }
        DesignWorkflowEngine.updateSpec(spec, in: &project)
        try await host.store.save(project)
        return DesignToolOutput.make(DesignToolOutput.projectState(project))
    }
}

private struct DesignRegisterRevisionTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var projectID: String
        var artifactID: String
        var contentSHA256: String
        var origin: String
        var expectedRevisionID: String?
        var payloadRelativePath: String?
    }
    static let name = "canvas.designRegisterRevision"
    static let toolDescription = "Record a new artifact revision (import/generate/edit result) after the content was written by the owning editor. Compare-and-swap against the revision the editor started from."
    static let parametersJSON = #"{"type":"object","properties":{"projectID":{"type":"string"},"artifactID":{"type":"string"},"contentSHA256":{"type":"string"},"origin":{"type":"string","enum":["importFile","generate","edit"]},"expectedRevisionID":{"type":"string"},"payloadRelativePath":{"type":"string"}},"required":["projectID","artifactID","contentSHA256","origin"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.writesFiles, .persistsPersonalData]
    static let isSideEffecting = true
    let host: DesignToolHost
    func validate(_ args: Arguments) throws {
        guard args.contentSHA256.count == 64 else {
            throw FloeError.validationFailed("contentSHA256 must be a SHA-256 hex digest")
        }
        guard DesignRevisionOrigin(rawValue: args.origin) != nil, args.origin != "adopt",
              args.origin != "restore", args.origin != "variant" else {
            throw FloeError.validationFailed("origin must be importFile, generate or edit")
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        var project = try await host.store.load(id: args.projectID)
        let revision = try DesignWorkflowEngine.registerRevision(
            in: &project,
            artifactID: args.artifactID,
            contentSHA256: args.contentSHA256,
            origin: DesignRevisionOrigin(rawValue: args.origin) ?? .edit,
            expectedRevisionID: args.expectedRevisionID,
            payloadRelativePath: args.payloadRelativePath
        )
        try await host.store.save(project)
        return DesignToolOutput.make([
            "artifactID": args.artifactID,
            "revisionID": revision.id,
            "number": revision.number,
            "currentRevisionID": project.artifact(args.artifactID)?.currentRevisionID ?? ""
        ])
    }
}

private struct DesignAddFeedbackTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var projectID: String
        var artifactID: String
        var revisionID: String?
        var comment: String
        var anchorKind: String
        var x: Double?; var y: Double?; var width: Double?; var height: Double?
        var seconds: Double?
        var page: Int?
        var objectID: String?
    }
    static let name = "canvas.designAddFeedback"
    static let toolDescription = "Add region/time/page/object-anchored feedback to a specific artifact revision."
    static let parametersJSON = #"{"type":"object","properties":{"projectID":{"type":"string"},"artifactID":{"type":"string"},"revisionID":{"type":"string"},"comment":{"type":"string"},"anchorKind":{"type":"string","enum":["region","time","page","object"]},"x":{"type":"number"},"y":{"type":"number"},"width":{"type":"number"},"height":{"type":"number"},"seconds":{"type":"number"},"page":{"type":"integer"},"objectID":{"type":"string"}},"required":["projectID","artifactID","comment","anchorKind"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let host: DesignToolHost
    func validate(_ args: Arguments) throws {
        switch args.anchorKind {
        case "region":
            guard let w = args.width, let h = args.height, w > 0, h > 0 else {
                throw FloeError.validationFailed("Region feedback requires positive width and height")
            }
        case "time":
            guard args.seconds != nil else { throw FloeError.validationFailed("Time feedback requires seconds") }
        case "page":
            guard args.page != nil else { throw FloeError.validationFailed("Page feedback requires a page index") }
        case "object":
            guard let id = args.objectID, !id.isEmpty else {
                throw FloeError.validationFailed("Object feedback requires a stable object ID")
            }
        default:
            throw FloeError.validationFailed("Unknown anchor kind")
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        var project = try await host.store.load(id: args.projectID)
        let anchor: DesignFeedbackAnchor
        switch args.anchorKind {
        case "region":
            anchor = .region(x: args.x ?? 0, y: args.y ?? 0, width: args.width ?? 0, height: args.height ?? 0)
        case "time":
            anchor = .time(seconds: args.seconds ?? 0)
        case "page":
            anchor = .page(index: args.page ?? 0)
        default:
            anchor = .objectID(args.objectID ?? "")
        }
        let feedback = try DesignWorkflowEngine.addFeedback(
            in: &project,
            artifactID: args.artifactID,
            revisionID: args.revisionID,
            anchor: anchor,
            comment: args.comment,
            author: .ai
        )
        try await host.store.save(project)
        return DesignToolOutput.make([
            "feedbackID": feedback.id,
            "status": feedback.status.rawValue,
            "revisionID": feedback.revisionID
        ])
    }
}

private struct DesignProposeTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var projectID: String
        var artifactID: String
        var baseRevisionID: String?
        var proposedContentSHA256: String
        var summary: String
        var diff: [String]?
        var feedbackIDs: [String]?
    }
    static let name = "canvas.designPropose"
    static let toolDescription = "Propose a revision-bound candidate for an artifact. The proposal never applies until the user adopts it."
    static let parametersJSON = #"{"type":"object","properties":{"projectID":{"type":"string"},"artifactID":{"type":"string"},"baseRevisionID":{"type":"string"},"proposedContentSHA256":{"type":"string"},"summary":{"type":"string"},"diff":{"type":"array","items":{"type":"string"}},"feedbackIDs":{"type":"array","items":{"type":"string"}}},"required":["projectID","artifactID","proposedContentSHA256","summary"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let host: DesignToolHost
    func validate(_ args: Arguments) throws {
        guard args.proposedContentSHA256.count == 64 else {
            throw FloeError.validationFailed("proposedContentSHA256 must be a SHA-256 hex digest")
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        var project = try await host.store.load(id: args.projectID)
        let candidate = try DesignWorkflowEngine.proposeCandidate(
            in: &project,
            artifactID: args.artifactID,
            baseRevisionID: args.baseRevisionID,
            proposedContentSHA256: args.proposedContentSHA256,
            summary: args.summary,
            diff: args.diff ?? [],
            feedbackIDs: args.feedbackIDs ?? []
        )
        try await host.store.save(project)
        return DesignToolOutput.make([
            "candidateID": candidate.id,
            "status": candidate.status.rawValue,
            "baseRevisionID": candidate.baseRevisionID,
            "proposedRevisionID": candidate.proposedRevisionID
        ])
    }
}

private struct DesignAdoptTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var projectID: String
        var candidateID: String
        var mode: String?
        var expectedRevisionID: String?
    }
    static let name = "canvas.designAdopt"
    static let toolDescription = "Adopt a pending candidate: update the original artifact (default) or create an explicit variant branch. Requires user approval."
    static let parametersJSON = #"{"type":"object","properties":{"projectID":{"type":"string"},"candidateID":{"type":"string"},"mode":{"type":"string","enum":["updateOriginal","variant"]},"expectedRevisionID":{"type":"string"}},"required":["projectID","candidateID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.writesFiles, .persistsPersonalData]
    static let isSideEffecting = true
    let host: DesignToolHost
    func validate(_ args: Arguments) throws {}

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        var project = try await host.store.load(id: args.projectID)
        let mode = DesignAdoptMode(rawValue: args.mode ?? "updateOriginal") ?? .updateOriginal
        let artifact = try DesignWorkflowEngine.adoptCandidate(
            in: &project,
            candidateID: args.candidateID,
            mode: mode,
            expectedRevisionID: args.expectedRevisionID
        )
        try await host.store.save(project)
        return DesignToolOutput.make([
            "artifactID": artifact.id,
            "currentRevisionID": artifact.currentRevisionID ?? "",
            "mode": mode.rawValue
        ])
    }
}

private struct DesignRejectTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var projectID: String
        var candidateID: String
    }
    static let name = "canvas.designReject"
    static let toolDescription = "Reject a pending candidate without changing the artifact."
    static let parametersJSON = #"{"type":"object","properties":{"projectID":{"type":"string"},"candidateID":{"type":"string"}},"required":["projectID","candidateID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let host: DesignToolHost
    func validate(_ args: Arguments) throws {}

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        var project = try await host.store.load(id: args.projectID)
        try DesignWorkflowEngine.rejectCandidate(in: &project, candidateID: args.candidateID)
        try await host.store.save(project)
        return DesignToolOutput.make(["candidateID": args.candidateID, "status": "rejected"])
    }
}

private struct DesignRestoreTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var projectID: String
        var artifactID: String
        var revisionID: String
    }
    static let name = "canvas.designRestore"
    static let toolDescription = "Restore a previous artifact revision from history (recoverable). Requires user approval."
    static let parametersJSON = #"{"type":"object","properties":{"projectID":{"type":"string"},"artifactID":{"type":"string"},"revisionID":{"type":"string"}},"required":["projectID","artifactID","revisionID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.writesFiles, .persistsPersonalData]
    static let isSideEffecting = true
    let host: DesignToolHost
    func validate(_ args: Arguments) throws {}

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        var project = try await host.store.load(id: args.projectID)
        let revision = try DesignWorkflowEngine.restoreRevision(
            in: &project, artifactID: args.artifactID, revisionID: args.revisionID
        )
        try await host.store.save(project)
        return DesignToolOutput.make([
            "artifactID": args.artifactID,
            "currentRevisionID": revision.id,
            "restoredFrom": args.revisionID
        ])
    }
}

private struct DesignCapabilitiesTool: AgentTool {
    struct Arguments: Decodable, Sendable {}
    static let name = "canvas.designCapabilities"
    static let toolDescription = "Report which design operations are really connected for each content type, with reasons for unavailable ones."
    static let parametersJSON = #"{"type":"object","additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    let registry: DesignCapabilityRegistry
    func validate(_ args: Arguments) throws {}

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        var payload: [String: Any] = [:]
        for type in DesignContentType.allCases {
            let capability = registry.capability(for: type)
            payload[type.rawValue] = [
                "available": capability.available.map(\.rawValue).sorted(),
                "unavailable": capability.unavailableReasons
                    .map { ["operation": $0.key.rawValue, "reason": $0.value] }
                    .sorted { $0["operation"] ?? "" < $1["operation"] ?? "" }
            ]
        }
        return DesignToolOutput.make(payload)
    }
}

extension DesignCapabilityRegistry {
    /// Honest default for this build. The design engine and its registered tools
    /// genuinely implement revision registration, anchored feedback,
    /// revision-bound candidates, compare/adopt/reject and restore for every
    /// content type (they are payload-agnostic and persisted to disk). Every
    /// content-specific operation (source import, generation, region editing,
    /// preview, source/verified export) is *not* connected yet and says so with
    /// a concrete reason — a stub is never presented as coverage.
    static func designCoreDefaults() -> DesignCapabilityRegistry {
        let core: Set<DesignOperation> = [.anchoredFeedback, .candidateRevision, .compareAdopt]
        var capabilities: [DesignContentType: DesignAdapterCapability] = [:]
        for type in DesignContentType.allCases {
            capabilities[type] = DesignAdapterCapability(
                contentType: type,
                available: core,
                unavailableReasons: [
                    .importSource: "Source import for \(type.rawValue) is not connected to the design flow yet",
                    .generate: "Generation for \(type.rawValue) is not connected to the design flow yet",
                    .editRegion: "Region editing for \(type.rawValue) is not connected to the design flow yet",
                    .preview: "Preview for \(type.rawValue) is not connected to the design flow yet",
                    .sourceExport: "Source export for \(type.rawValue) is not connected to the design flow yet",
                    .verifiedExport: "Verified export for \(type.rawValue) is not connected to the design flow yet"
                ]
            )
        }
        return DesignCapabilityRegistry(capabilities: capabilities)
    }
}

/// Registers the design tool family. The capability registry is passed in by the
/// app so availability reflects the actual services wired in this build.
func registerDesignAgentTools(
    capabilities: DesignCapabilityRegistry,
    registry: ToolRunnerRegistry = .shared
) {
    let host = DesignToolHost()
    ToolCatalog.register(DesignGetStateTool.self); registry.register(DesignGetStateTool(host: host))
    ToolCatalog.register(DesignCreateTool.self); registry.register(DesignCreateTool(host: host))
    ToolCatalog.register(DesignUpdateBriefTool.self); registry.register(DesignUpdateBriefTool(host: host))
    ToolCatalog.register(DesignUpdateSpecTool.self); registry.register(DesignUpdateSpecTool(host: host))
    ToolCatalog.register(DesignRegisterRevisionTool.self); registry.register(DesignRegisterRevisionTool(host: host))
    ToolCatalog.register(DesignAddFeedbackTool.self); registry.register(DesignAddFeedbackTool(host: host))
    ToolCatalog.register(DesignProposeTool.self); registry.register(DesignProposeTool(host: host))
    ToolCatalog.register(DesignAdoptTool.self); registry.register(DesignAdoptTool(host: host))
    ToolCatalog.register(DesignRejectTool.self); registry.register(DesignRejectTool(host: host))
    ToolCatalog.register(DesignRestoreTool.self); registry.register(DesignRestoreTool(host: host))
    ToolCatalog.register(DesignCapabilitiesTool.self); registry.register(DesignCapabilitiesTool(registry: capabilities))
}
#endif
