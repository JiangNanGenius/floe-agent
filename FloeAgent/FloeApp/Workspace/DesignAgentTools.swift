// FloeApp — Design workflow agent tools (Canvas-authority bound).
//
// Design state is a typed subdocument of a Canvas node; every tool requires an
// explicit canvasID + nodeID + expectedRevision, mutations require an
// operationID (idempotent by replay), and adoption additionally requires a
// single-use user grant (`canvas.designAdopt` cannot self-adopt). Input data
// can never grant permissions; approval policy gates side-effecting tools.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeTools

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

    static func state(_ snapshot: DesignCanvasService.Snapshot) -> [String: Any] {
        var result: [String: Any] = [
            "canvasID": snapshot.canvasID.uuidString.lowercased(),
            "nodeID": snapshot.nodeID.uuidString.lowercased(),
            "canvasRevision": snapshot.canvasRevision,
            "nodeKind": snapshot.nodeKind.rawValue
        ]
        guard let project = snapshot.design else {
            result["design"] = NSNull()
            return result
        }
        result["design"] = design(project)
        return result
    }

    static func design(_ project: DesignProject) -> [String: Any] {
        var result: [String: Any] = [
            "nodeID": project.nodeID,
            "contentType": project.contentType.rawValue,
            "schemaVersion": project.schemaVersion,
            "updatedAt": ISO8601DateFormatter().string(from: project.updatedAt),
            "appliedOperationCount": project.appliedOperationIDs.count
        ]
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

    static func requireUUID(_ value: String, field: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw FloeError.validationFailed("\(field) must be a UUID")
        }
        return uuid
    }
}

// MARK: - Tools

private struct DesignGetStateTool: AgentTool {
    struct Arguments: Decodable, Sendable { var canvasID: String; var nodeID: String }
    static let name = "canvas.designGetState"
    static let toolDescription = "Read the design subdocument (brief, spec, template, artifacts, revisions, feedback, candidates) bound to a canvas node."
    static let parametersJSON = #"{"type":"object","properties":{"canvasID":{"type":"string"},"nodeID":{"type":"string"}},"required":["canvasID","nodeID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    let service: DesignCanvasService
    func validate(_ args: Arguments) throws {
        _ = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        _ = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let snapshot = try await service.snapshot(
            canvasID: try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID"),
            nodeID: try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        )
        return DesignToolOutput.make(DesignToolOutput.state(snapshot))
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

private struct DesignCreateTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var canvasID: String
        var nodeID: String
        var expectedRevision: Int64
        var operationID: String
        var contentType: DesignContentType
        var goal: String
        var audience: String?
    }
    static let name = "canvas.designCreate"
    static let toolDescription = "Create the design subdocument (brief stage) on an existing canvas node, through the Canvas revision CAS."
    static let parametersJSON = #"{"type":"object","properties":{"canvasID":{"type":"string"},"nodeID":{"type":"string"},"expectedRevision":{"type":"integer"},"operationID":{"type":"string"},"contentType":{"type":"string","enum":["webpage","prototype","presentation","image","video","officeDocument","notes","pdf","cad"]},"goal":{"type":"string"},"audience":{"type":"string"}},"required":["canvasID","nodeID","expectedRevision","operationID","contentType","goal"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let service: DesignCanvasService
    func validate(_ args: Arguments) throws {
        _ = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        _ = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        guard !args.operationID.isEmpty else { throw FloeError.validationFailed("operationID is required") }
        guard !args.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("Design goal must not be empty")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let snapshot = try await service.mutate(
            canvasID: try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID"),
            nodeID: try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID"),
            expectedRevision: args.expectedRevision,
            operationID: args.operationID,
            contentType: args.contentType
        ) { design in
            DesignWorkflowEngine.updateBrief(
                DesignBrief(goal: args.goal, audience: args.audience, constraints: []),
                in: &design
            )
        }
        return DesignToolOutput.make(DesignToolOutput.state(snapshot))
    }
}

private struct DesignUpdateBriefTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var canvasID: String; var nodeID: String; var expectedRevision: Int64; var operationID: String
        var goal: String; var audience: String?; var constraints: [String]?
    }
    static let name = "canvas.designUpdateBrief"
    static let toolDescription = "Update the brief of the design subdocument bound to a canvas node."
    static let parametersJSON = #"{"type":"object","properties":{"canvasID":{"type":"string"},"nodeID":{"type":"string"},"expectedRevision":{"type":"integer"},"operationID":{"type":"string"},"goal":{"type":"string"},"audience":{"type":"string"},"constraints":{"type":"array","items":{"type":"string"}}},"required":["canvasID","nodeID","expectedRevision","operationID","goal"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let service: DesignCanvasService
    func validate(_ args: Arguments) throws {
        _ = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        _ = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        guard !args.operationID.isEmpty else { throw FloeError.validationFailed("operationID is required") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let snapshot = try await service.mutate(
            canvasID: try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID"),
            nodeID: try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID"),
            expectedRevision: args.expectedRevision,
            operationID: args.operationID
        ) { design in
            DesignWorkflowEngine.updateBrief(
                DesignBrief(goal: args.goal, audience: args.audience, constraints: args.constraints ?? []),
                in: &design
            )
        }
        return DesignToolOutput.make(DesignToolOutput.state(snapshot))
    }
}

private struct DesignUpdateSpecTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var canvasID: String; var nodeID: String; var expectedRevision: Int64; var operationID: String
        var palette: [String]?; var typography: String?; var layout: String?; var spacing: String?
        var brandAssetRefs: [String]?; var voice: String?; var prohibitions: [String]?
        var designMarkdown: String?
    }
    static let name = "canvas.designUpdateSpec"
    static let toolDescription = "Update the design spec (or import DESIGN.md, preserving unknown text) on a canvas node's design subdocument."
    static let parametersJSON = #"{"type":"object","properties":{"canvasID":{"type":"string"},"nodeID":{"type":"string"},"expectedRevision":{"type":"integer"},"operationID":{"type":"string"},"palette":{"type":"array","items":{"type":"string"}},"typography":{"type":"string"},"layout":{"type":"string"},"spacing":{"type":"string"},"brandAssetRefs":{"type":"array","items":{"type":"string"}},"voice":{"type":"string"},"prohibitions":{"type":"array","items":{"type":"string"}},"designMarkdown":{"type":"string"}},"required":["canvasID","nodeID","expectedRevision","operationID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let service: DesignCanvasService
    func validate(_ args: Arguments) throws {
        _ = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        _ = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        guard !args.operationID.isEmpty else { throw FloeError.validationFailed("operationID is required") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let snapshot = try await service.mutate(
            canvasID: try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID"),
            nodeID: try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID"),
            expectedRevision: args.expectedRevision,
            operationID: args.operationID
        ) { design in
            var spec: DesignSpec
            if let markdown = args.designMarkdown {
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
                    palette: args.palette ?? design.spec?.palette,
                    typography: args.typography ?? design.spec?.typography,
                    layout: args.layout ?? design.spec?.layout,
                    spacing: args.spacing ?? design.spec?.spacing,
                    brandAssetRefs: args.brandAssetRefs ?? design.spec?.brandAssetRefs,
                    voice: args.voice ?? design.spec?.voice,
                    prohibitions: args.prohibitions ?? design.spec?.prohibitions,
                    rawMarkdown: design.spec?.rawMarkdown
                )
            }
            DesignWorkflowEngine.updateSpec(spec, in: &design)
        }
        return DesignToolOutput.make(DesignToolOutput.state(snapshot))
    }
}

private struct DesignRegisterRevisionTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var canvasID: String; var nodeID: String; var expectedRevision: Int64; var operationID: String
        var artifactID: String; var contentSHA256: String; var origin: String
        var expectedArtifactRevisionID: String?; var payloadRelativePath: String?
    }
    static let name = "canvas.designRegisterRevision"
    static let toolDescription = "Record a new artifact revision (import/generate/edit result) written by the owning editor. Compare-and-swap against the revision the editor started from."
    static let parametersJSON = #"{"type":"object","properties":{"canvasID":{"type":"string"},"nodeID":{"type":"string"},"expectedRevision":{"type":"integer"},"operationID":{"type":"string"},"artifactID":{"type":"string"},"contentSHA256":{"type":"string"},"origin":{"type":"string","enum":["importFile","generate","edit"]},"expectedArtifactRevisionID":{"type":"string"},"payloadRelativePath":{"type":"string"}},"required":["canvasID","nodeID","expectedRevision","operationID","artifactID","contentSHA256","origin"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.writesFiles, .persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let service: DesignCanvasService
    func validate(_ args: Arguments) throws {
        _ = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        _ = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        guard !args.operationID.isEmpty else { throw FloeError.validationFailed("operationID is required") }
        guard args.contentSHA256.count == 64 else {
            throw FloeError.validationFailed("contentSHA256 must be a SHA-256 hex digest")
        }
        guard let origin = DesignRevisionOrigin(rawValue: args.origin),
              origin == .importFile || origin == .generate || origin == .edit else {
            throw FloeError.validationFailed("origin must be importFile, generate or edit")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let snapshot = try await service.mutate(
            canvasID: try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID"),
            nodeID: try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID"),
            expectedRevision: args.expectedRevision,
            operationID: args.operationID
        ) { design in
            _ = try DesignWorkflowEngine.registerRevision(
                in: &design,
                artifactID: args.artifactID,
                contentSHA256: args.contentSHA256,
                origin: DesignRevisionOrigin(rawValue: args.origin) ?? .edit,
                expectedRevisionID: args.expectedArtifactRevisionID,
                payloadRelativePath: args.payloadRelativePath
            )
        }
        return DesignToolOutput.make(DesignToolOutput.state(snapshot))
    }
}

private struct DesignAddFeedbackTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var canvasID: String; var nodeID: String; var expectedRevision: Int64; var operationID: String
        var artifactID: String; var revisionID: String?; var comment: String; var anchorKind: String
        var x: Double?; var y: Double?; var width: Double?; var height: Double?
        var seconds: Double?; var page: Int?; var objectID: String?
    }
    static let name = "canvas.designAddFeedback"
    static let toolDescription = "Add region/time/page/object-anchored feedback to a specific artifact revision of the node's design subdocument."
    static let parametersJSON = #"{"type":"object","properties":{"canvasID":{"type":"string"},"nodeID":{"type":"string"},"expectedRevision":{"type":"integer"},"operationID":{"type":"string"},"artifactID":{"type":"string"},"revisionID":{"type":"string"},"comment":{"type":"string"},"anchorKind":{"type":"string","enum":["region","time","page","object"]},"x":{"type":"number"},"y":{"type":"number"},"width":{"type":"number"},"height":{"type":"number"},"seconds":{"type":"number"},"page":{"type":"integer"},"objectID":{"type":"string"}},"required":["canvasID","nodeID","expectedRevision","operationID","artifactID","comment","anchorKind"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let service: DesignCanvasService
    func validate(_ args: Arguments) throws {
        _ = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        _ = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        guard !args.operationID.isEmpty else { throw FloeError.validationFailed("operationID is required") }
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
        let anchor: DesignFeedbackAnchor
        switch args.anchorKind {
        case "region": anchor = .region(x: args.x ?? 0, y: args.y ?? 0, width: args.width ?? 0, height: args.height ?? 0)
        case "time": anchor = .time(seconds: args.seconds ?? 0)
        case "page": anchor = .page(index: args.page ?? 0)
        default: anchor = .objectID(args.objectID ?? "")
        }
        let snapshot = try await service.mutate(
            canvasID: try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID"),
            nodeID: try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID"),
            expectedRevision: args.expectedRevision,
            operationID: args.operationID
        ) { design in
            _ = try DesignWorkflowEngine.addFeedback(
                in: &design,
                artifactID: args.artifactID,
                revisionID: args.revisionID,
                anchor: anchor,
                comment: args.comment,
                author: .ai
            )
        }
        return DesignToolOutput.make(DesignToolOutput.state(snapshot))
    }
}

private struct DesignProposeTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var canvasID: String; var nodeID: String; var expectedRevision: Int64; var operationID: String
        var artifactID: String; var baseRevisionID: String?; var proposedContentSHA256: String
        var summary: String; var diff: [String]?; var feedbackIDs: [String]?
    }
    static let name = "canvas.designPropose"
    static let toolDescription = "Propose a revision-bound candidate. It never applies until the user adopts it (which additionally needs a user grant)."
    static let parametersJSON = #"{"type":"object","properties":{"canvasID":{"type":"string"},"nodeID":{"type":"string"},"expectedRevision":{"type":"integer"},"operationID":{"type":"string"},"artifactID":{"type":"string"},"baseRevisionID":{"type":"string"},"proposedContentSHA256":{"type":"string"},"summary":{"type":"string"},"diff":{"type":"array","items":{"type":"string"}},"feedbackIDs":{"type":"array","items":{"type":"string"}}},"required":["canvasID","nodeID","expectedRevision","operationID","artifactID","proposedContentSHA256","summary"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let service: DesignCanvasService
    func validate(_ args: Arguments) throws {
        _ = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        _ = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        guard !args.operationID.isEmpty else { throw FloeError.validationFailed("operationID is required") }
        guard args.proposedContentSHA256.count == 64 else {
            throw FloeError.validationFailed("proposedContentSHA256 must be a SHA-256 hex digest")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let snapshot = try await service.mutate(
            canvasID: try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID"),
            nodeID: try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID"),
            expectedRevision: args.expectedRevision,
            operationID: args.operationID
        ) { design in
            _ = try DesignWorkflowEngine.proposeCandidate(
                in: &design,
                artifactID: args.artifactID,
                baseRevisionID: args.baseRevisionID,
                proposedContentSHA256: args.proposedContentSHA256,
                summary: args.summary,
                diff: args.diff ?? [],
                feedbackIDs: args.feedbackIDs ?? []
            )
        }
        return DesignToolOutput.make(DesignToolOutput.state(snapshot))
    }
}

private struct DesignAdoptTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var canvasID: String; var nodeID: String; var expectedRevision: Int64; var operationID: String
        var candidateID: String; var mode: String?; var expectedArtifactRevisionID: String?
        var grantID: String
    }
    static let name = "canvas.designAdopt"
    static let toolDescription = "Adopt a pending candidate using a user-issued single-use grant: update the original node (default) or create a variant branch. Requires approval."
    static let parametersJSON = #"{"type":"object","properties":{"canvasID":{"type":"string"},"nodeID":{"type":"string"},"expectedRevision":{"type":"integer"},"operationID":{"type":"string"},"candidateID":{"type":"string"},"mode":{"type":"string","enum":["updateOriginal","variant"]},"expectedArtifactRevisionID":{"type":"string"},"grantID":{"type":"string"}},"required":["canvasID","nodeID","expectedRevision","operationID","candidateID","grantID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.writesFiles, .persistsPersonalData]
    static let isSideEffecting = true
    let service: DesignCanvasService
    let grants: DesignAdoptionGrantStore
    func validate(_ args: Arguments) throws {
        _ = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        _ = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        guard !args.operationID.isEmpty else { throw FloeError.validationFailed("operationID is required") }
        guard !args.grantID.isEmpty else { throw FloeError.validationFailed("grantID is required") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let canvasID = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        let nodeID = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        guard await grants.consume(
            id: args.grantID, canvasID: canvasID, nodeID: nodeID, candidateID: args.candidateID
        ) else {
            throw FloeError.validationFailed("Adoption grant is missing, expired or bound to a different candidate")
        }
        let mode = DesignAdoptMode(rawValue: args.mode ?? "updateOriginal") ?? .updateOriginal
        let snapshot = try await service.mutate(
            canvasID: canvasID,
            nodeID: nodeID,
            expectedRevision: args.expectedRevision,
            operationID: args.operationID
        ) { design in
            _ = try DesignWorkflowEngine.adoptCandidate(
                in: &design,
                candidateID: args.candidateID,
                mode: mode,
                expectedRevisionID: args.expectedArtifactRevisionID
            )
        }
        return DesignToolOutput.make(DesignToolOutput.state(snapshot))
    }
}

private struct DesignRejectTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var canvasID: String; var nodeID: String; var expectedRevision: Int64; var operationID: String
        var candidateID: String
    }
    static let name = "canvas.designReject"
    static let toolDescription = "Reject a pending candidate without changing the artifact."
    static let parametersJSON = #"{"type":"object","properties":{"canvasID":{"type":"string"},"nodeID":{"type":"string"},"expectedRevision":{"type":"integer"},"operationID":{"type":"string"},"candidateID":{"type":"string"}},"required":["canvasID","nodeID","expectedRevision","operationID","candidateID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let service: DesignCanvasService
    func validate(_ args: Arguments) throws {
        _ = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        _ = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        guard !args.operationID.isEmpty else { throw FloeError.validationFailed("operationID is required") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let snapshot = try await service.mutate(
            canvasID: try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID"),
            nodeID: try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID"),
            expectedRevision: args.expectedRevision,
            operationID: args.operationID
        ) { design in
            try DesignWorkflowEngine.rejectCandidate(in: &design, candidateID: args.candidateID)
        }
        return DesignToolOutput.make(DesignToolOutput.state(snapshot))
    }
}

private struct DesignRestoreTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var canvasID: String; var nodeID: String; var expectedRevision: Int64; var operationID: String
        var artifactID: String; var revisionID: String
    }
    static let name = "canvas.designRestore"
    static let toolDescription = "Restore a previous artifact revision from the subdocument history (recoverable). Requires approval."
    static let parametersJSON = #"{"type":"object","properties":{"canvasID":{"type":"string"},"nodeID":{"type":"string"},"expectedRevision":{"type":"integer"},"operationID":{"type":"string"},"artifactID":{"type":"string"},"revisionID":{"type":"string"}},"required":["canvasID","nodeID","expectedRevision","operationID","artifactID","revisionID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.writesFiles, .persistsPersonalData]
    static let isSideEffecting = true
    let service: DesignCanvasService
    func validate(_ args: Arguments) throws {
        _ = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        _ = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        guard !args.operationID.isEmpty else { throw FloeError.validationFailed("operationID is required") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let snapshot = try await service.mutate(
            canvasID: try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID"),
            nodeID: try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID"),
            expectedRevision: args.expectedRevision,
            operationID: args.operationID
        ) { design in
            _ = try DesignWorkflowEngine.restoreRevision(
                in: &design, artifactID: args.artifactID, revisionID: args.revisionID
            )
        }
        return DesignToolOutput.make(DesignToolOutput.state(snapshot))
    }
}

extension DesignCapabilityRegistry {
    /// Honest default for this build: revision registration, anchored feedback,
    /// revision-bound candidates, compare/adopt/reject and restore are really
    /// implemented and callable through the Canvas-bound tools. Every
    /// content-specific operation is not connected and says so.
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

/// Registers the design tool family against the shared Canvas authority.
func registerDesignAgentTools(
    capabilities: DesignCapabilityRegistry,
    service: DesignCanvasService = DesignCanvasService(),
    grants: DesignAdoptionGrantStore = .shared,
    registry: ToolRunnerRegistry = .shared
) {
    ToolCatalog.register(DesignGetStateTool.self); registry.register(DesignGetStateTool(service: service))
    ToolCatalog.register(DesignCapabilitiesTool.self); registry.register(DesignCapabilitiesTool(registry: capabilities))
    ToolCatalog.register(DesignCreateTool.self); registry.register(DesignCreateTool(service: service))
    ToolCatalog.register(DesignUpdateBriefTool.self); registry.register(DesignUpdateBriefTool(service: service))
    ToolCatalog.register(DesignUpdateSpecTool.self); registry.register(DesignUpdateSpecTool(service: service))
    ToolCatalog.register(DesignRegisterRevisionTool.self); registry.register(DesignRegisterRevisionTool(service: service))
    ToolCatalog.register(DesignAddFeedbackTool.self); registry.register(DesignAddFeedbackTool(service: service))
    ToolCatalog.register(DesignProposeTool.self); registry.register(DesignProposeTool(service: service))
    ToolCatalog.register(DesignAdoptTool.self); registry.register(DesignAdoptTool(service: service, grants: grants))
    ToolCatalog.register(DesignRejectTool.self); registry.register(DesignRejectTool(service: service))
    ToolCatalog.register(DesignRestoreTool.self); registry.register(DesignRestoreTool(service: service))
}
#endif
