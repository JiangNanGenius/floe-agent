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
            runID: context.runID,
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
    /// Resolved per call so the report reflects the services connected right
    /// now (e.g. whether a generation model is configured), not launch state.
    let registryProvider: @MainActor @Sendable () -> DesignCapabilityRegistry
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let registry = await registryProvider()
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
            runID: context.runID,
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
            runID: context.runID,
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
            runID: context.runID,
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

private struct DesignProjectSpecTool: AgentTool {
    struct Arguments: Decodable, Sendable { var canvasID: String }
    static let name = "canvas.designGetProjectSpec"
    static let toolDescription = "Read the canvas-level design brief/spec authority (the payload every new design node inherits), with its full-payload identity and the nodes that currently carry it."
    static let parametersJSON = #"{"type":"object","properties":{"canvasID":{"type":"string"}},"required":["canvasID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    let service: DesignCanvasService
    func validate(_ args: Arguments) throws {
        _ = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let canvasID = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        try await service.requireAuthorization(runID: context.runID, canvasID: canvasID)
        guard let authority = try await service.projectAuthority(canvasID: canvasID) else {
            return DesignToolOutput.make(["configured": false])
        }
        var result: [String: Any] = [
            "configured": true,
            "contentSHA256": authority.contentSHA256,
            "inheritedNodeIDs": authority.inheritedNodeIDs,
            "updatedAt": ISO8601DateFormatter().string(from: authority.updatedAt)
        ]
        if let brief = authority.brief {
            result["brief"] = ["goal": brief.goal, "audience": brief.audience ?? "", "constraints": brief.constraints]
        }
        if let spec = authority.spec {
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
        return DesignToolOutput.make(result)
    }
}

private struct DesignSetProjectSpecTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var canvasID: String; var expectedRevision: Int64; var operationID: String
        var goal: String?; var audience: String?; var constraints: [String]?
        var palette: [String]?; var typography: String?; var layout: String?; var spacing: String?
        var brandAssetRefs: [String]?; var voice: String?; var prohibitions: [String]?
        var designMarkdown: String?
        var inheritToExistingNodes: Bool?
    }
    static let name = "canvas.designSetProjectSpec"
    static let toolDescription = "Set the canvas-level design brief/spec authority in ONE Canvas project CAS. Every existing design subdocument inherits the payload in the same commit (or only the authority is set when inheritToExistingNodes=false); new nodes inherit it when their design subdocument is created. Replaying the same operationID with a different payload is rejected; repeating the identical payload dedupes without a revision bump."
    static let parametersJSON = #"{"type":"object","properties":{"canvasID":{"type":"string"},"expectedRevision":{"type":"integer"},"operationID":{"type":"string"},"goal":{"type":"string"},"audience":{"type":"string"},"constraints":{"type":"array","items":{"type":"string"}},"palette":{"type":"array","items":{"type":"string"}},"typography":{"type":"string"},"layout":{"type":"string"},"spacing":{"type":"string"},"brandAssetRefs":{"type":"array","items":{"type":"string"}},"voice":{"type":"string"},"prohibitions":{"type":"string"},"designMarkdown":{"type":"string"},"inheritToExistingNodes":{"type":"boolean"}},"required":["canvasID","expectedRevision","operationID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let service: DesignCanvasService
    func validate(_ args: Arguments) throws {
        _ = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        guard !args.operationID.isEmpty else { throw FloeError.validationFailed("operationID is required") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let canvasID = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        let existing = try await service.projectAuthority(canvasID: canvasID)
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
                palette: args.palette ?? existing?.spec?.palette,
                typography: args.typography ?? existing?.spec?.typography,
                layout: args.layout ?? existing?.spec?.layout,
                spacing: args.spacing ?? existing?.spec?.spacing,
                brandAssetRefs: args.brandAssetRefs ?? existing?.spec?.brandAssetRefs,
                voice: args.voice ?? existing?.spec?.voice,
                prohibitions: args.prohibitions ?? existing?.spec?.prohibitions,
                rawMarkdown: existing?.spec?.rawMarkdown
            )
        }
        let brief: DesignBrief?
        if args.goal != nil || existing?.brief != nil {
            brief = DesignBrief(
                goal: args.goal ?? existing?.brief?.goal ?? "",
                audience: args.audience ?? existing?.brief?.audience,
                constraints: args.constraints ?? existing?.brief?.constraints ?? []
            )
        } else {
            brief = nil
        }
        let result = try await service.applyProjectAuthority(
            runID: context.runID,
            canvasID: canvasID,
            expectedRevision: args.expectedRevision,
            operationID: args.operationID,
            brief: brief,
            spec: spec,
            inheritToExistingNodes: args.inheritToExistingNodes ?? true
        )
        return DesignToolOutput.make([
            "configured": true,
            "operationReplayed": result.operationReplayed,
            "canvasRevision": result.canvasRevision,
            "contentSHA256": result.authority.contentSHA256,
            "updatedNodeCount": result.updatedNodeIDs.count,
            "skippedNodeCount": result.skippedNodeIDs.count
        ])
    }
}

private struct DesignUseCurrentNodeTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var canvasID: String; var nodeID: String; var expectedRevision: Int64; var operationID: String
        var displayName: String?
    }
    static let name = "canvas.designUseCurrentNode"
    static let toolDescription = "Freeze the content ALREADY on this Canvas node into a design revision: the node's text/markdown body, its retained asset bytes, or the CAD/Office workspace document it is bound to. No external export/reimport is required; the stored document files are read (never rewritten), so mutable editor state/drafts survive. When the node has no retained content the tool fails with the exact reason. Requires approval."
    static let parametersJSON = #"{"type":"object","properties":{"canvasID":{"type":"string"},"nodeID":{"type":"string"},"expectedRevision":{"type":"integer"},"operationID":{"type":"string"},"displayName":{"type":"string"}},"required":["canvasID","nodeID","expectedRevision","operationID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles, .persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let service: DesignCanvasService
    let adapters: DesignAdapterCenter
    let environment: AppEnvironment
    func validate(_ args: Arguments) throws {
        _ = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        _ = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        guard !args.operationID.isEmpty else { throw FloeError.validationFailed("operationID is required") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let outcome: DesignWorkflowActions.CurrentNodeOutcome
        do {
            outcome = try await DesignWorkflowActions.useCurrentNode(
                service: service,
                adapters: adapters,
                environment: environment,
                caller: .run(context.runID),
                canvasID: try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID"),
                nodeID: try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID"),
                expectedRevision: args.expectedRevision,
                operationID: args.operationID,
                displayName: args.displayName
            )
        } catch let unavailable as DesignWorkflowActions.CurrentNodeUnavailable {
            throw FloeError.validationFailed(unavailable.reason)
        }
        return DesignToolOutput.make([
            "usedCurrentNode": true,
            "operationReplayed": outcome.replayed,
            "artifactID": outcome.artifactID,
            "revisionID": outcome.revisionID,
            "format": outcome.format,
            "byteCount": outcome.byteCount,
            "contentSHA256": outcome.contentSHA256,
            "state": DesignToolOutput.state(outcome.snapshot)
        ])
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
            runID: context.runID,
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
            runID: context.runID,
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
        var artifactID: String; var baseRevisionID: String?
        /// App-storage relative path of the proposed bytes. The tool reads
        /// and hashes these bytes itself; a model-supplied hash alone is
        /// never a candidate.
        var payloadRelativePath: String
        /// Optional caller-provided digest, rejected when it disagrees with
        /// the bytes actually read.
        var proposedContentSHA256: String?
        var summary: String; var diff: [String]?; var feedbackIDs: [String]?
    }
    static let name = "canvas.designPropose"
    static let toolDescription = "Propose a revision-bound candidate from real app-storage bytes: ownership is validated first, the payload is published under the exact proposed revision identity BEFORE one Canvas CAS commit binds candidate + payload pointer + frozen run inputs; replay returns the recorded candidate and changed arguments are rejected. It never applies until the user adopts it with a user grant."
    static let parametersJSON = #"{"type":"object","properties":{"canvasID":{"type":"string"},"nodeID":{"type":"string"},"expectedRevision":{"type":"integer"},"operationID":{"type":"string"},"artifactID":{"type":"string"},"baseRevisionID":{"type":"string"},"payloadRelativePath":{"type":"string"},"proposedContentSHA256":{"type":"string"},"summary":{"type":"string"},"diff":{"type":"array","items":{"type":"string"}},"feedbackIDs":{"type":"array","items":{"type":"string"}}},"required":["canvasID","nodeID","expectedRevision","operationID","artifactID","payloadRelativePath","summary"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles, .persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let service: DesignCanvasService
    let adapters: DesignAdapterCenter
    func validate(_ args: Arguments) throws {
        _ = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        _ = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        guard !args.operationID.isEmpty else { throw FloeError.validationFailed("operationID is required") }
        guard !args.payloadRelativePath.isEmpty else {
            throw FloeError.validationFailed("payloadRelativePath is required; proposals must point at real bytes")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let canvasID = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        let nodeID = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        // 1. Ownership/authorization BEFORE reading the source bytes.
        let preRead = try await service.snapshot(runID: context.runID, canvasID: canvasID, nodeID: nodeID)
        // Replay: return the recorded candidate; a changed request reusing
        // the operationID is rejected before any side effect.
        if preRead.design?.hasApplied(operationID: args.operationID) == true {
            guard let recorded = preRead.design?.candidates.first(where: {
                $0.artifactID == args.artifactID && $0.baseRevisionID == (args.baseRevisionID ?? $0.baseRevisionID)
            }), recorded.status == .pending else {
                throw FloeError.validationFailed("operationID '\(args.operationID)' was already applied to a different request")
            }
            let recordedSHA = preRead.design?.artifact(recorded.artifactID)
                .flatMap { artifact in artifact.revision(recorded.proposedRevisionID) }?
                .contentSHA256
            guard let recordedSHA else {
                throw FloeError.validationFailed("operationID '\(args.operationID)' replay lost the recorded revision")
            }
            if let claimed = args.proposedContentSHA256, claimed != recordedSHA {
                throw FloeError.validationFailed("operationID '\(args.operationID)' was reused with different payload content")
            }
            return DesignToolOutput.make(DesignToolOutput.state(preRead))
        }
        // 2. Resolve + hash the real bytes (the model's hash alone is never
        // trusted). VNC screen content is not a design payload source.
        let url = try FloeArtifactStore.resolve(
            args.payloadRelativePath,
            allowed: DesignImportSourceTool.allowedSourceNamespaces,
            maxBytes: 64 * 1_024 * 1_024
        )
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let verifiedSHA = FloeDigest.sha256Hex(data)
        if let claimed = args.proposedContentSHA256, claimed != verifiedSHA {
            throw FloeError.validationFailed("proposedContentSHA256 does not match the payload bytes")
        }
        let format = (args.payloadRelativePath as NSString).pathExtension.lowercased()
        guard !format.isEmpty else {
            throw FloeError.validationFailed("payloadRelativePath must carry a format extension")
        }
        // 3. Publish the immutable payload under the EXACT proposed revision
        // identity BEFORE the CAS, so a crash never leaves a candidate whose
        // revision points at missing bytes.
        let proposedRevisionID = UUID().uuidString.lowercased()
        let staged = try await adapters.stageRevisionPayload(
            canvasID: canvasID, nodeID: nodeID, artifactID: args.artifactID,
            revisionID: proposedRevisionID, bytes: data, expectedContentSHA256: verifiedSHA
        )
        try await adapters.commitRevisionPayload(staged)
        // 4. ONE Canvas CAS commit: candidate + payload pointer + frozen run
        //    (spec hash + input/target revisions) in the same revision.
        let snapshot: DesignCanvasService.Snapshot
        do {
            snapshot = try await service.mutate(
                runID: context.runID,
                canvasID: canvasID,
                nodeID: nodeID,
                expectedRevision: args.expectedRevision,
                operationID: args.operationID
            ) { design in
                let artifact = design.artifact(args.artifactID)
                let candidate = try DesignWorkflowEngine.proposeCandidate(
                    in: &design,
                    artifactID: args.artifactID,
                    baseRevisionID: args.baseRevisionID,
                    proposedContentSHA256: verifiedSHA,
                    summary: args.summary,
                    diff: args.diff ?? [],
                    feedbackIDs: args.feedbackIDs ?? [],
                    proposedRevisionID: proposedRevisionID,
                    payloadRelativePath: staged.relativePath,
                    payloadFormat: format,
                    originConversationID: context.conversationID?.uuidString.lowercased(),
                    originEnvironmentID: context.environmentID
                )
                DesignWorkflowEngine.freezeRun(
                    operationID: args.operationID,
                    in: &design,
                    inputRevisionID: candidate.baseRevisionID,
                    targetRevisionID: artifact?.currentRevisionID
                )
            }
        } catch {
            // The CAS failed: remove only this call's exact orphan payload.
            try? await adapters.removeRevisionPayload(
                canvasID: canvasID, nodeID: nodeID, artifactID: args.artifactID,
                revisionID: proposedRevisionID
            )
            throw error
        }
        return DesignToolOutput.make(DesignToolOutput.state(snapshot))
    }
}

private struct DesignImportSourceTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var canvasID: String; var nodeID: String; var expectedRevision: Int64; var operationID: String
        var sourceRelativePath: String
        var artifactID: String?
        var displayName: String?
    }
    static let name = "canvas.designImportSource"
    static let toolDescription = "Import a source file as a verified revision of a design artifact on a canvas node: run ownership is validated first, the source bytes are validated by the content adapter and staged into the revision payload store, then ONE Canvas CAS commit records the revision with its full payload pointer. Replaying the same operationID returns the recorded result; the same operationID with different bytes is rejected."
    static let parametersJSON = #"{"type":"object","properties":{"canvasID":{"type":"string"},"nodeID":{"type":"string"},"expectedRevision":{"type":"integer"},"operationID":{"type":"string"},"sourceRelativePath":{"type":"string"},"artifactID":{"type":"string"},"displayName":{"type":"string"}},"required":["canvasID","nodeID","expectedRevision","operationID","sourceRelativePath"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles, .persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    /// Tool-output namespaces a design import may read (VNC excluded).
    static let allowedSourceNamespaces: Set<ArtifactNamespace> = [
        .attachments, .generatedImages, .browser, .presentation, .change, .jobDownloads, .designRevisions
    ]
    let service: DesignCanvasService
    let adapters: DesignAdapterCenter
    func validate(_ args: Arguments) throws {
        _ = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        _ = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        guard !args.operationID.isEmpty else { throw FloeError.validationFailed("operationID is required") }
        guard !args.sourceRelativePath.isEmpty else { throw FloeError.validationFailed("sourceRelativePath is required") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let canvasID = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        let nodeID = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        // 1. Authorize run -> canvas BEFORE touching the source file.
        let design = try await service.snapshot(runID: context.runID, canvasID: canvasID, nodeID: nodeID)
        let contentType = design.design?.contentType
            ?? DesignContentTypeMapper.contentType(for: design.nodeKind)
        guard let adapter = await adapters.adapter(for: contentType) else {
            throw FloeError.validationFailed("No design adapter is connected for \(contentType.rawValue)")
        }
        // 2. Explicit unknown artifactID is an error, never a silent replace.
        if let supplied = args.artifactID, design.design?.artifact(supplied) == nil {
            throw FloeError.validationFailed("Unknown artifactID \(supplied) for this design subdocument")
        }
        // 3. Resolve + size-cap through the scoped artifact authority.
        let sourceURL = try FloeArtifactStore.resolve(
            args.sourceRelativePath,
            allowed: Self.allowedSourceNamespaces,
            maxBytes: 64 * 1_024 * 1_024
        )
        // 4. Replay fingerprint BEFORE any side effect (no adapter import, no
        // asset ingestion, no payload publish): hash the exact source bytes
        // and return the recorded import for the identical request; reject a
        // changed request reusing the operationID.
        let sourceData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        let sourceDigest = FloeDigest.sha256Hex(sourceData)
        if design.design?.hasApplied(operationID: args.operationID) == true {
            if let recorded = Self.recordedRevision(matching: sourceDigest, in: design.design) {
                return DesignToolOutput.make([
                    "imported": true, "operationReplayed": true,
                    "artifactID": recorded.artifactID, "revisionID": recorded.revisionID,
                    "contentSHA256": sourceDigest,
                    "format": (args.sourceRelativePath as NSString).pathExtension.lowercased(),
                    "byteCount": sourceData.count
                ])
            }
            throw FloeError.validationFailed("operationID '\(args.operationID)' was already applied with different content; idempotency replay requires the identical request")
        }
        // 5. Adapter validation with the real editor boundary + digest.
        let imported = try await adapter.importSource(fileURL: sourceURL, canvasID: canvasID, nodeID: nodeID)
        // The adapter's verified bytes are the recorded payload. For
        // byte-preserving adapters they equal the source digest; format
        // adapters (PDF gate) re-report their validated bytes.
        let digest = FloeDigest.sha256Hex(imported.bytes)
        let artifactID = args.artifactID ?? UUID().uuidString.lowercased()
        let revisionID = UUID().uuidString.lowercased()
        // 6. Stage then PUBLISH the immutable payload BEFORE the CAS, so an
        // interrupted run never leaves a committed revision pointing at
        // missing bytes. Revision paths are UUID-unique, so the publish can
        // only collide with our own replay (identical bytes = no-op).
        let staged = try await adapters.stageRevisionPayload(
            canvasID: canvasID, nodeID: nodeID, artifactID: artifactID,
            revisionID: revisionID, bytes: imported.bytes, expectedContentSHA256: digest
        )
        try await adapters.commitRevisionPayload(staged)
        // 6. ONE Canvas CAS commit carrying the full payload pointer.
        let snapshot: DesignCanvasService.Snapshot
        do {
            snapshot = try await service.mutate(
                runID: context.runID,
                canvasID: canvasID,
                nodeID: nodeID,
                expectedRevision: args.expectedRevision,
                operationID: args.operationID
            ) { project in
                if project.artifact(artifactID) == nil {
                    let artifact = DesignArtifact(
                        id: artifactID,
                        contentType: contentType,
                        canvasNodeID: nodeID.uuidString.lowercased(),
                        identity: DesignArtifactIdentity(
                            name: args.displayName ?? sourceURL.lastPathComponent,
                            positionX: 0, positionY: 0, width: 0, height: 0
                        )
                    )
                    DesignWorkflowEngine.addArtifact(artifact, to: &project)
                }
                _ = try DesignWorkflowEngine.registerRevision(
                    in: &project,
                    artifactID: artifactID,
                    contentSHA256: digest,
                    origin: .importFile,
                    payloadRelativePath: staged.relativePath,
                    payloadFormat: imported.format,
                    revisionID: revisionID
                )
            }
        } catch {
            // The CAS failed: remove only the exact orphan payload this call
            // published (UUID-unique path, unreferenced because the CAS never
            // recorded it). A payload published by an earlier successful run
            // is never touched.
            try? await adapters.removeRevisionPayload(
                canvasID: canvasID, nodeID: nodeID, artifactID: artifactID, revisionID: revisionID
            )
            throw error
        }
        if snapshot.operationReplayed {
            // Replay: our publish duplicated an existing identical payload
            // (no-op) or this operation raced its original; the recorded
            // revision's payload is reference-shared — never removed.
            if let recorded = Self.recordedRevision(matching: digest, in: snapshot.design) {
                return DesignToolOutput.make([
                    "imported": true, "operationReplayed": true,
                    "artifactID": recorded.artifactID, "revisionID": recorded.revisionID,
                    "contentSHA256": digest, "format": imported.format,
                    "byteCount": imported.bytes.count
                ])
            }
            throw FloeError.validationFailed("operationID '\(args.operationID)' was already applied with different content; idempotency replay requires the identical request")
        }
        return DesignToolOutput.make([
            "imported": true, "operationReplayed": false,
            "artifactID": artifactID, "revisionID": revisionID,
            "contentSHA256": digest, "format": imported.format,
            "byteCount": imported.bytes.count,
            "canvasRevision": snapshot.canvasRevision
        ])
    }

    /// The recorded IMPORT revision for a replayed operation: digest match,
    /// payload retained, and import origin (proposed `.generate` revisions
    /// never satisfy an import replay — same bytes, different operation).
    private static func recordedRevision(matching digest: String, in design: DesignProject?) -> (artifactID: String, revisionID: String)? {
        guard let design else { return nil }
        for artifact in design.artifacts {
            for revision in artifact.revisions where revision.contentSHA256 == digest
                && revision.payloadRelativePath != nil && revision.origin == .importFile {
                return (artifact.id, revision.id)
            }
        }
        return nil
    }
}

private struct DesignExportRevisionTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var canvasID: String; var nodeID: String
        var artifactID: String; var revisionID: String
        var format: String?
    }
    static let name = "canvas.designExportRevision"
    static let toolDescription = "Export one design artifact revision through the shared artifact authority: the payload must match the recorded revision hash, the copy is written under the recorded format extension, re-read, re-hashed, and reopened with the actual format parser before the export is reported as verified. Format conversion is not claimed."
    static let parametersJSON = #"{"type":"object","properties":{"canvasID":{"type":"string"},"nodeID":{"type":"string"},"artifactID":{"type":"string"},"revisionID":{"type":"string"},"format":{"type":"string"}},"required":["canvasID","nodeID","artifactID","revisionID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let service: DesignCanvasService
    let adapters: DesignAdapterCenter
    func validate(_ args: Arguments) throws {
        _ = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        _ = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let canvasID = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        let nodeID = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        let snapshot = try await service.snapshot(runID: context.runID, canvasID: canvasID, nodeID: nodeID)
        guard let artifact = snapshot.design?.artifact(args.artifactID),
              let revision = artifact.revision(args.revisionID) else {
            throw FloeError.validationFailed("Artifact or revision not found")
        }
        let export = try await adapters.exportVerifiedRevision(
            canvasID: canvasID, nodeID: nodeID, artifactID: artifact.id,
            revision: revision, artifact: artifact, requestedFormat: args.format
        )
        return DesignToolOutput.make([
            "exported": true,
            "path": export.url.path,
            "format": export.format,
            "byteCount": export.byteCount,
            "contentSHA256": export.contentSHA256,
            "verified": export.contentSHA256 == revision.contentSHA256
        ])
    }
}

private struct DesignBindDocumentTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var canvasID: String; var nodeID: String; var expectedRevision: Int64; var operationID: String
        /// Artifact-store relative path of the source document
        /// (docx/xlsx/pptx/dwg/dxf/floecad).
        var sourceRelativePath: String
        var format: String
    }
    static let name = "canvas.designBindDocument"
    static let toolDescription = "Bind an explicit Canvas-owned workspace document for office/presentation/CAD design work: the source bytes are copied into the per-canvas design workspace through a path guard and the binding is recorded in the design subdocument through ONE Canvas CAS commit. The existing OfficeCommandCenter/CadDocumentCenter services then address the bound document (verified export, editor reopen). Never binds outside the workspace."
    static let parametersJSON = #"{"type":"object","properties":{"canvasID":{"type":"string"},"nodeID":{"type":"string"},"expectedRevision":{"type":"integer"},"operationID":{"type":"string"},"sourceRelativePath":{"type":"string"},"format":{"type":"string"}},"required":["canvasID","nodeID","expectedRevision","operationID","sourceRelativePath","format"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles, .persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let service: DesignCanvasService
    func validate(_ args: Arguments) throws {
        _ = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        _ = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        guard !args.operationID.isEmpty else { throw FloeError.validationFailed("operationID is required") }
        guard ["docx", "xlsx", "pptx", "dwg", "dxf", "floecad"].contains(args.format.lowercased()) else {
            throw FloeError.validationFailed("format must be docx/xlsx/pptx/dwg/dxf/floecad")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let canvasID = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        let nodeID = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        // Ownership BEFORE touching the source.
        let preRead = try await service.snapshot(runID: context.runID, canvasID: canvasID, nodeID: nodeID)
        let format = args.format.lowercased()
        // Replay fingerprint BEFORE any file write: an identical recorded
        // binding returns the recorded state; changed arguments are rejected.
        if preRead.design?.hasApplied(operationID: args.operationID) == true {
            guard let recorded = preRead.design?.workspaceBinding,
                  recorded.format == format,
                  recorded.relativeDocumentPath == "docs/\(nodeID.uuidString.lowercased()).\(format)" else {
                throw FloeError.validationFailed("operationID '\(args.operationID)' was already applied to a different request")
            }
            return DesignToolOutput.make([
                "bound": true, "operationReplayed": true,
                "document": recorded.relativeDocumentPath,
                "format": recorded.format,
                "state": DesignToolOutput.state(preRead)
            ])
        }
        let source = try FloeArtifactStore.resolve(
            args.sourceRelativePath,
            allowed: DesignImportSourceTool.allowedSourceNamespaces,
            maxBytes: 64 * 1_024 * 1_024
        )
        let data = try Data(contentsOf: source, options: [.mappedIfSafe])
        // Content-addressed revision file first, fully verified on disk.
        // An existing manually-edited document at the stable path is never
        // touched before the idempotency/CAS checks.
        let revision = try DesignWorkspace.writeRevisionFile(
            bytes: data, canvasID: canvasID, nodeID: nodeID, format: format
        )
        let binding = DesignWorkspaceBinding(
            workspaceRootPath: DesignWorkspace.root(canvasID: canvasID)!.standardizedFileURL.path,
            relativeDocumentPath: revision.relativePath,
            format: format
        )
        let snapshot: DesignCanvasService.Snapshot
        do {
            snapshot = try await service.mutate(
                runID: context.runID,
                canvasID: canvasID,
                nodeID: nodeID,
                expectedRevision: args.expectedRevision,
                operationID: args.operationID
            ) { design in
                design.workspaceBinding = binding
            }
        } catch {
            // Only an orphan revision file remains; nothing referenced it.
            throw error
        }
        try DesignWorkspace.publishStableAlias(
            canvasID: canvasID, nodeID: nodeID, revision: revision, format: format
        )
        return DesignToolOutput.make([
            "bound": true, "operationReplayed": false,
            "document": binding.relativeDocumentPath,
            "format": binding.format,
            "state": DesignToolOutput.state(snapshot)
        ])
    }
}

private struct DesignAdoptTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var canvasID: String; var nodeID: String; var expectedRevision: Int64; var operationID: String
        var candidateID: String; var mode: String?; var expectedArtifactRevisionID: String?
        var baselineRevisionID: String; var grantID: String
    }
    static let name = "canvas.designAdopt"
    static let toolDescription = "Adopt a pending candidate using a user-issued single-use grant bound to its base revision. The adoption commits the design metadata AND the real Canvas node content (asset/text) in ONE Canvas CAS transaction, preserving layout/connections; variant mode creates an actual new node. Replaying the recorded operation returns the recorded result without re-consuming the grant."
    static let parametersJSON = #"{"type":"object","properties":{"canvasID":{"type":"string"},"nodeID":{"type":"string"},"expectedRevision":{"type":"integer"},"operationID":{"type":"string"},"candidateID":{"type":"string"},"mode":{"type":"string","enum":["updateOriginal","variant"]},"expectedArtifactRevisionID":{"type":"string"},"baselineRevisionID":{"type":"string"},"grantID":{"type":"string"}},"required":["canvasID","nodeID","expectedRevision","operationID","candidateID","baselineRevisionID","grantID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.writesFiles, .persistsPersonalData]
    static let isSideEffecting = true
    let service: DesignCanvasService
    let grants: DesignAdoptionAuthorization
    let adapters: DesignAdapterCenter
    let environment: AppEnvironment
    let decisionSink: @MainActor @Sendable (UUID, UUID, String, Int64?, String?) async throws -> Void
    let decisionOutbox: DesignDecisionOutbox
    func validate(_ args: Arguments) throws {
        _ = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        _ = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        guard !args.operationID.isEmpty else { throw FloeError.validationFailed("operationID is required") }
        guard !args.grantID.isEmpty else { throw FloeError.validationFailed("grantID is required") }
        guard !args.baselineRevisionID.isEmpty else {
            throw FloeError.validationFailed("baselineRevisionID is required")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let canvasID = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        let nodeID = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        let mode = DesignAdoptMode(rawValue: args.mode ?? "updateOriginal") ?? .updateOriginal
        // The single shared production transaction (same code as the panel):
        // replay/origin/grant checks → durable intent (full fingerprint)
        // BEFORE the CAS → ONE content+metadata CAS → grant consume →
        // throwing durable ingress, ack only after confirmed delivery.
        let outcome = await DesignWorkflowActions.adopt(
            service: service,
            adapters: adapters,
            environment: environment,
            caller: .run(context.runID),
            outbox: decisionOutbox,
            sink: decisionSink,
            canvasID: canvasID,
            nodeID: nodeID,
            expectedRevision: args.expectedRevision,
            operationID: args.operationID,
            candidateID: args.candidateID,
            mode: mode,
            expectedArtifactRevisionID: args.expectedArtifactRevisionID,
            grant: DesignWorkflowActions.GrantGate(
                validate: { [grants] in
                    await grants.validate(
                        id: args.grantID, canvasID: canvasID, nodeID: nodeID,
                        candidateID: args.candidateID, baselineRevisionID: args.baselineRevisionID
                    )
                },
                consume: { [grants] in
                    _ = await grants.consume(
                        id: args.grantID, canvasID: canvasID, nodeID: nodeID,
                        candidateID: args.candidateID, baselineRevisionID: args.baselineRevisionID
                    )
                }
            )
        )
        switch outcome {
        case .succeeded(let snapshot, _, _, let replayed, let deliveryError):
            // The decision intent is acknowledged ONLY after the durable
            // ingress persists; a delivery failure keeps it pending for
            // launch reconcile and is reported (never a false delivered).
            var payload = DesignToolOutput.state(snapshot)
            payload["operationReplayed"] = replayed
            payload["decisionDelivered"] = deliveryError == nil
            if let deliveryError {
                payload["decisionDeliveryPending"] = true
                payload["decisionDeliveryError"] = deliveryError
            }
            return DesignToolOutput.make(payload)
        case .failed(let error):
            throw error
        }
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
    let decisionSink: @MainActor @Sendable (UUID, UUID, String, Int64?, String?) async throws -> Void
    let decisionOutbox: DesignDecisionOutbox
    func validate(_ args: Arguments) throws {
        _ = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        _ = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        guard !args.operationID.isEmpty else { throw FloeError.validationFailed("operationID is required") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let canvasID = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        let nodeID = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        // The single shared reject transaction (same code as the panel).
        let snapshot = try await DesignWorkflowActions.reject(
            service: service,
            caller: .run(context.runID),
            outbox: decisionOutbox,
            sink: decisionSink,
            canvasID: canvasID,
            nodeID: nodeID,
            expectedRevision: args.expectedRevision,
            operationID: args.operationID,
            candidateID: args.candidateID
        )
        return DesignToolOutput.make(DesignToolOutput.state(snapshot))
    }
}

private struct DesignRestoreTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var canvasID: String; var nodeID: String; var expectedRevision: Int64; var operationID: String
        var artifactID: String; var revisionID: String
    }
    static let name = "canvas.designRestore"
    static let toolDescription = "Restore a previous artifact revision as the node's current content: the design metadata and the real Canvas node content (asset/text) commit in ONE Canvas CAS transaction, preserving layout. Requires approval."
    static let parametersJSON = #"{"type":"object","properties":{"canvasID":{"type":"string"},"nodeID":{"type":"string"},"expectedRevision":{"type":"integer"},"operationID":{"type":"string"},"artifactID":{"type":"string"},"revisionID":{"type":"string"}},"required":["canvasID","nodeID","expectedRevision","operationID","artifactID","revisionID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.writesFiles, .persistsPersonalData]
    static let isSideEffecting = true
    let service: DesignCanvasService
    let adapters: DesignAdapterCenter
    let environment: AppEnvironment
    func validate(_ args: Arguments) throws {
        _ = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        _ = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        guard !args.operationID.isEmpty else { throw FloeError.validationFailed("operationID is required") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let canvasID = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        let nodeID = try DesignToolOutput.requireUUID(args.nodeID, field: "nodeID")
        let preRead = try await service.snapshot(runID: context.runID, canvasID: canvasID, nodeID: nodeID)
        guard let artifact = preRead.design?.artifact(args.artifactID),
              let target = artifact.revision(args.revisionID) else {
            throw FloeError.validationFailed("Artifact or revision not found")
        }
        // Replay returns the recorded state without re-ingesting.
        if preRead.design?.hasApplied(operationID: args.operationID) == true {
            return DesignToolOutput.make(DesignToolOutput.state(preRead))
        }
        guard target.payloadRelativePath != nil else {
            throw FloeError.validationFailed("This revision has no retained payload to restore")
        }
        let snapshot = try await DesignWorkflowActions.restore(
            service: service,
            adapters: adapters,
            environment: environment,
            caller: .run(context.runID),
            canvasID: canvasID,
            nodeID: nodeID,
            expectedRevision: args.expectedRevision,
            operationID: args.operationID,
            artifactID: args.artifactID,
            revisionID: args.revisionID
        )
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

// MARK: - Durable decision notices
//
// Adopt/reject outcomes are recorded as durable, structured events on the
// ORIGINATING conversation only (the shared proposal-decision ingress used by
// the CAD/Notes flows), never on any other conversation. The content is a
// structured decision only; model-authored proposal text is never repeated.
// Delivery is the throwing, awaited sink inside DesignWorkflowActions; a
// failed sink keeps the outbox intent pending for launch-time reconcile.

/// Registers the design tool family against the shared Canvas authority. The
/// authorization closure resolves whether a run may touch a canvas (app wiring
/// uses the existing canvas run context), so an arbitrary UUID cannot reach
/// another canvas.
func registerDesignAgentTools(
    capabilities: @escaping @MainActor @Sendable () -> DesignCapabilityRegistry,
    adapters: DesignAdapterCenter,
    environment: AppEnvironment,
    authorize: @escaping DesignCanvasService.CanvasAuthorization,
    repository: CanvasDocumentRepository = FileCanvasDocumentRepository(),
    grants: DesignAdoptionAuthorization = .shared,
    decisionSink: @escaping @MainActor @Sendable (UUID, UUID, String, Int64?, String?) async throws -> Void = { _, _, _, _, _ in },
    decisionOutbox: DesignDecisionOutbox = .shared,
    registry: ToolRunnerRegistry = .shared
) {
    let service = DesignCanvasService(repository: repository, authorize: authorize)
    ToolCatalog.register(DesignGetStateTool.self); registry.register(DesignGetStateTool(service: service))
    ToolCatalog.register(DesignCapabilitiesTool.self); registry.register(DesignCapabilitiesTool(registryProvider: capabilities))
    ToolCatalog.register(DesignCreateTool.self); registry.register(DesignCreateTool(service: service))
    ToolCatalog.register(DesignUpdateBriefTool.self); registry.register(DesignUpdateBriefTool(service: service))
    ToolCatalog.register(DesignUpdateSpecTool.self); registry.register(DesignUpdateSpecTool(service: service))
    ToolCatalog.register(DesignProjectSpecTool.self); registry.register(DesignProjectSpecTool(service: service))
    ToolCatalog.register(DesignSetProjectSpecTool.self); registry.register(DesignSetProjectSpecTool(service: service))
    ToolCatalog.register(DesignRegisterRevisionTool.self); registry.register(DesignRegisterRevisionTool(service: service))
    ToolCatalog.register(DesignImportSourceTool.self); registry.register(DesignImportSourceTool(service: service, adapters: adapters))
    ToolCatalog.register(DesignUseCurrentNodeTool.self); registry.register(DesignUseCurrentNodeTool(service: service, adapters: adapters, environment: environment))
    ToolCatalog.register(DesignExportRevisionTool.self); registry.register(DesignExportRevisionTool(service: service, adapters: adapters))
    ToolCatalog.register(DesignAddFeedbackTool.self); registry.register(DesignAddFeedbackTool(service: service))
    ToolCatalog.register(DesignProposeTool.self); registry.register(DesignProposeTool(service: service, adapters: adapters))
    ToolCatalog.register(DesignBindDocumentTool.self); registry.register(DesignBindDocumentTool(service: service))
    ToolCatalog.register(DesignAdoptTool.self); registry.register(DesignAdoptTool(service: service, grants: grants, adapters: adapters, environment: environment, decisionSink: decisionSink, decisionOutbox: decisionOutbox))
    ToolCatalog.register(DesignRejectTool.self); registry.register(DesignRejectTool(service: service, decisionSink: decisionSink, decisionOutbox: decisionOutbox))
    ToolCatalog.register(DesignRestoreTool.self); registry.register(DesignRestoreTool(service: service, adapters: adapters, environment: environment))
}
#endif
