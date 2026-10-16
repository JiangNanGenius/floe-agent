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
import FloePersistence
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
    static let toolDescription = "Report which design operations are really connected for each content type, with reasons for unavailable ones. Includes a live layer (live.createGenerate) re-derived from the real services — connected sessions, installed images, configured models — so a capability is never reported ready from static wiring alone."
    static let parametersJSON = #"{"type":"object","additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    /// Resolved per call so the report reflects the services connected right
    /// now (e.g. whether a generation model is configured), not launch state.
    let registryProvider: @MainActor @Sendable () -> DesignCapabilityRegistry
    /// Live matrix over the real services; the create/generate row of every
    /// family is reported alongside the static wiring so the model sees the
    /// same readiness the UI shows.
    let liveMatrixProvider: (@MainActor @Sendable () -> DesignCapabilityMatrix)?
    init(
        registryProvider: @escaping @MainActor @Sendable () -> DesignCapabilityRegistry,
        liveMatrixProvider: (@MainActor @Sendable () -> DesignCapabilityMatrix)? = nil
    ) {
        self.registryProvider = registryProvider
        self.liveMatrixProvider = liveMatrixProvider
    }
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let registry = await registryProvider()
        let matrix: DesignCapabilityMatrix?
        if let liveMatrixProvider {
            matrix = await liveMatrixProvider()
        } else {
            matrix = nil
        }
        var payload: [String: Any] = [:]
        for type in DesignContentType.allCases {
            let capability = registry.capability(for: type)
            var entry: [String: Any] = [
                "available": capability.available.map(\.rawValue).sorted(),
                "unavailable": capability.unavailableReasons
                    .map { ["operation": $0.key.rawValue, "reason": $0.value] }
                    .sorted { $0["operation"] ?? "" < $1["operation"] ?? "" }
            ]
            if let matrix {
                let assessment = matrix.assess(DesignCapabilityQuery(
                    mode: .create, family: type, operation: .generate))
                var live: [String: Any] = ["available": assessment.available]
                if let reason = assessment.reason { live["reason"] = reason }
                if let recovery = assessment.recovery { live["recovery"] = recovery }
                if assessment.isCaptureOperation { live["capture"] = true }
                entry["live"] = live
            }
            payload[type.rawValue] = entry
        }
        // Truthful per-task execution surface: while THIS run owns frozen
        // design originals, arbitrary guest/native execution backends cannot
        // touch them — the capability report says so explicitly (with the
        // recovery) instead of letting the model discover it at dispatch.
        if let conversationID = context.conversationID {
            let frozen = DesignFreezeRegistry.shared.allProtections().contains {
                $0.conversationID == conversationID.uuidString.lowercased()
            }
            if frozen {
                payload["designFreeze"] = [
                    "active": true,
                    "restrictedBackends": ["exec.shell (mutating)", "shell.open/shell.exchange"],
                    "stillAvailable": ["read-only shell inspection", "design.propose candidate staging", "workspace reads/new files"],
                    "recovery": "stage changes with design.propose; the freeze lifts on verified adoption or last rejection",
                ]
            }
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
        // 3. The proposed bytes must be really reopenable by this content
        // type's connected reader BEFORE they are published as a revision:
        // later adoption/export may not be the first place invalid bytes are
        // detected (Office OOXML parse, CAD same-engine reparse, media
        // decoders).
        let proposedContentType = DesignContentTypeMapper.effectiveContentType(
            existing: preRead.design?.contentType,
            kind: preRead.nodeKind,
            metadata: preRead.nodeMetadata
        )
        guard let proposedAdapter = await adapters.adapter(for: proposedContentType) else {
            throw FloeError.validationFailed("No design adapter is connected for \(proposedContentType.rawValue)")
        }
        do {
            try await proposedAdapter.verifyExportReopen(bytes: data, format: format)
        } catch {
            throw FloeError.validationFailed("The proposed bytes are not a readable \(format) \(proposedContentType.rawValue) payload: \(error.localizedDescription)")
        }
        // 4. Publish the immutable payload under the EXACT proposed revision
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
        let contentType = DesignContentTypeMapper.effectiveContentType(
            existing: design.design?.contentType,
            kind: design.nodeKind,
            metadata: design.nodeMetadata
        )
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
        // replay/origin checks → payload/format pre-flight → ATOMIC grant
        // claim (exact candidate/base/proposed/mode, before the first side
        // effect) → durable intent (full fingerprint) BEFORE the CAS → ONE
        // content+metadata CAS → throwing durable ingress, ack only after
        // confirmed delivery.
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
            grant: DesignWorkflowActions.GrantGate { [grants] proposedRevisionID in
                await grants.claim(
                    id: args.grantID, canvasID: canvasID, nodeID: nodeID,
                    candidateID: args.candidateID,
                    baselineRevisionID: args.baselineRevisionID,
                    proposedRevisionID: proposedRevisionID,
                    mode: mode
                )
            }
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

// MARK: - Typed shared-target design tools (T5)
//
// These tools drive the SAME T3 shared services the panel uses:
// `DesignTargetService` for typed discovery and `DesignOwnerWorkflow` for the
// file / chat-attachment / creative cycle (revision-bound
// proposal/candidate/adopt/reject/restore/export + durable events). They do
// NOT keep design state and they NEVER send a canvas node to the generic
// workflow: `.canvasNode` keeps its single authority
// (`DesignCanvasService` + `DesignWorkflowActions`, reached through the
// legacy `canvas.design*` wrappers below), and a typed canvas mutation
// returns an explicit pointer to the compatible canvas tool instead of
// inventing a second path.

extension DesignToolOutput {
    /// Namespaces a typed design tool may read candidate/input bytes from —
    /// identical discipline to the canvas proposal tool.
    static let ownerPayloadNamespaces: Set<ArtifactNamespace> = [
        .attachments, .generatedImages, .browser, .presentation, .change, .jobDownloads, .designRevisions
    ]
    static let ownerPayloadMaxBytes = 64 * 1_024 * 1_024

    /// Reads and digest-verifies a tool-produced payload from the existing
    /// artifact authority. A model-supplied hash is never sufficient: it is
    /// checked against the bytes when present, never substituted for them.
    static func verifiedPayload(
        _ relativePath: String,
        claimedSHA256: String?
    ) throws -> (data: Data, format: String, sha256: String) {
        let url = try FloeArtifactStore.resolve(
            relativePath,
            allowed: ownerPayloadNamespaces,
            maxBytes: ownerPayloadMaxBytes
        )
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let sha = FloeDigest.sha256Hex(data)
        if let claimed = claimedSHA256, claimed.lowercased() != sha {
            throw FloeError.validationFailed("proposedContentSHA256 does not match the payload bytes")
        }
        let format = (relativePath as NSString).pathExtension.lowercased()
        guard !format.isEmpty else {
            throw FloeError.validationFailed("payloadRelativePath must carry a format extension")
        }
        return (data, format, sha)
    }

    static func target(_ target: DesignTarget) -> [String: Any] {
        var result: [String: Any] = [
            "kind": target.kind.rawValue,
            "ownerID": target.ownerID,
            "documentID": target.documentID,
            "sourceID": target.sourceID,
            "stableKey": target.stableKey
        ]
        if let environmentID = target.environmentID { result["environmentID"] = environmentID }
        if let revision = target.revision { result["revision"] = revision }
        if let origin = target.originConversationID { result["originConversationID"] = origin }
        if let requested = target.requestedOutputKind { result["requestedOutputKind"] = requested.rawValue }
        return result
    }

    static func resolved(_ source: DesignResolvedSource) -> [String: Any] {
        var result: [String: Any] = [
            "target": target(source.target),
            "displayName": source.displayName,
            "format": source.format,
            "contentType": source.contentType.rawValue,
            "contentSHA256": source.contentSHA256,
            "baseRevisionToken": source.baseRevisionToken,
            "allowsInPlaceUpdate": source.allowsInPlaceUpdate,
            "byteCount": source.data.count
        ]
        if let origin = source.originConversationID {
            result["originConversationID"] = origin
        }
        if let canvas = source.canvas {
            result["canvas"] = [
                "canvasID": canvas.canvasID.uuidString.lowercased(),
                "documentID": canvas.documentID?.uuidString.lowercased() ?? "",
                "nodeID": canvas.nodeID.uuidString.lowercased()
            ]
        }
        return result
    }

    static func owner(_ envelope: DesignOwnerEnvelope) -> [String: Any] {
        [
            "ownerRevision": envelope.revision,
            "schemaVersion": envelope.schemaVersion,
            "target": target(envelope.target),
            "updatedAt": ISO8601DateFormatter().string(from: envelope.updatedAt),
            "design": design(envelope.project)
        ]
    }

    static func comparison(_ comparison: DesignOwnerWorkflow.Comparison) -> [String: Any] {
        [
            "candidateID": comparison.candidateID,
            "baseSHA256": comparison.baseSHA256,
            "proposedSHA256": comparison.proposedSHA256,
            "changed": comparison.changed,
            "status": comparison.status.rawValue,
            "diff": Array(comparison.diff.prefix(200)),
            // C9: a bounded/fallback diff must be visible as such, never
            // presented as the complete change set.
            "diffTruncated": comparison.diffTruncated,
            "diffNote": comparison.diffNote ?? ""
        ]
    }

    static func decision(_ result: DesignOwnerWorkflow.DecisionResult) -> [String: Any] {
        var payload = owner(result.envelope)
        payload["operationReplayed"] = result.replayed
        if let token = result.committedRevisionToken {
            payload["committedRevisionToken"] = token
        }
        switch result.delivery {
        case .notRequired:
            payload["decisionDelivery"] = "notRequired"
        case .delivered:
            payload["decisionDelivery"] = "delivered"
        case .pending(let reason):
            payload["decisionDelivery"] = "pending"
            payload["decisionDeliveryPending"] = true
            payload["decisionDeliveryError"] = reason
        }
        switch result.publication {
        case .notRequired(let reason):
            payload["resultPublication"] = "notRequired"
            payload["resultPublicationNote"] = reason
        case .published(let receipt):
            payload["resultPublication"] = "published"
            payload["resultReceipt"] = [
                "identifier": receipt.identifier,
                "destination": receipt.destination,
                "contentSHA256": receipt.contentSHA256
            ]
        case .pending(let reason):
            // C15: publication.pending is honestly distinct from a
            // delivered notice / adopted metadata; the result is NOT
            // announced as returned while this is pending.
            payload["resultPublication"] = "pending"
            payload["resultPublicationPending"] = true
            payload["resultPublicationError"] = reason
        }
        return payload
    }

    /// Structured routing failure (nonzero status) instead of a thrown
    /// validation error: the request was well-formed but belongs to the
    /// retained Canvas authority or to a capability that is not connected.
    static func routingFailure(_ reason: String, compatibleTool: String? = nil) -> ToolExecutionOutput {
        var payload: [String: Any] = ["error": reason]
        if let compatibleTool {
            payload["compatibleTool"] = compatibleTool
            payload["migrationError"] = true
        }
        return make(payload, status: 2)
    }
}

/// Decodes/validates the shared typed-target argument block and builds the
/// frozen `DesignTarget`. The target is an opaque identity: this only checks
/// shape (enum raw values, non-empty ids); containment and permission are
/// re-derived live by the owner adapter on every service boundary.
private struct DesignToolTargetInput: Decodable, Sendable {
    var kind: String
    var ownerID: String
    var documentID: String?
    var sourceID: String
    var environmentID: String?
    var revision: String?
    var originConversationID: String?
    var requestedOutputKind: String?

    func makeTarget() throws -> DesignTarget {
        guard let kind = DesignTargetKind(rawValue: kind) else {
            throw FloeError.validationFailed(
                "target.kind must be one of canvasNode, fileDocument, chatAttachment, creativeDocument")
        }
        guard !ownerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("target.ownerID is required")
        }
        guard !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("target.sourceID is required")
        }
        // Origin is provenance. It must at least be a conversation identity
        // when supplied; it can never be the owner authority.
        if let origin = originConversationID, !origin.isEmpty {
            guard UUID(uuidString: origin) != nil else {
                throw FloeError.validationFailed("target.originConversationID must be a conversation UUID")
            }
        }
        var requestedKind: DesignContentType?
        if let requested = requestedOutputKind, !requested.isEmpty {
            guard let type = DesignContentType(rawValue: requested) else {
                throw FloeError.validationFailed("target.requestedOutputKind '\(requested)' is not a supported content type")
            }
            requestedKind = type
        }
        if kind != .creativeDocument, requestedKind != nil {
            throw FloeError.validationFailed("requestedOutputKind is valid only on a creativeDocument target")
        }
        return DesignTarget(
            kind: kind,
            ownerID: ownerID,
            documentID: documentID ?? "",
            sourceID: sourceID,
            environmentID: environmentID,
            revision: revision,
            originConversationID: originConversationID,
            requestedOutputKind: requestedKind
        )
    }
}

/// Shared dependencies of the typed design tools.
private struct DesignOwnerToolDependencies: Sendable {
    let targets: DesignTargetService
    let workflow: DesignOwnerWorkflow
    let adapters: DesignAdapterCenter
    /// The SAME concrete confirmation service the app already uses for
    /// owner grants (`DesignOwnerAuthorization.shared`, over the existing
    /// `ApprovalGrantStore`). The panel mints an adoption confirmation;
    /// `design.adopt` atomically claims that exact grant inside the shared
    /// adoption transaction (`claimAuthorization` → `claimOwnerAdoption`)
    /// before its first side effect. There is no separate grant state and
    /// no validate-then-consume window.
    let grants: DesignOwnerAuthorization
    /// The SAME retained Canvas service the legacy tools use. Typed
    /// discovery (`design.resolveTarget`/`design.getState`) reads canvas
    /// state through it; typed canvas mutation is never offered.
    let canvasService: DesignCanvasService
    /// Live run→task(conversation) lookup over the DURABLE run store. Task
    /// authority is derived from this, never from model JSON.
    let runTask: @MainActor @Sendable (UUID) async -> UUID?
    /// App database access for design-freeze bookkeeping (the workspace
    /// store that resolves a file target's root URL).
    let database: @MainActor @Sendable () -> DatabaseManager?
}

/// Derives the AUTHORIZED target for a tool call BEFORE any service is
/// touched:
/// - `originConversationID` in the model JSON is provenance only. When the
///   run's live task is known it MUST equal that task; when it is unknown
///   the claimed origin is stripped (a model can never attach a foreign
///   task to a file/creative result to route a durable event elsewhere).
/// - A chat attachment's owner must be the run's own task.
/// - The frozen revision token is preserved but never treated as authority
///   (the adapter re-checks it against the live owner).
private func authorizedTarget(
    _ input: DesignToolTargetInput,
    context: ToolContext,
    dependencies: DesignOwnerToolDependencies
) async throws -> DesignTarget {
    let raw = try input.makeTarget()
    // An empty revision string from tool JSON is the same as an absent one:
    // it must never shadow a frozen base token recorded at freeze time.
    let revision = raw.revision?.isEmpty == false ? raw.revision : nil
    let liveTask = await dependencies.runTask(context.runID)
    // A supplied origin that contradicts the live run task is rejected
    // outright; it is never merged or preferred.
    if let claimed = raw.originConversationID, !claimed.isEmpty,
       let liveTask,
       claimed.caseInsensitiveCompare(liveTask.uuidString) != .orderedSame {
        throw FloeError.validationFailed(
            "target.originConversationID does not match the live run task; the model cannot widen the originating task")
    }
    if raw.kind == .chatAttachment {
        guard let liveTask else {
            throw FloeError.validationFailed(
                "chat attachment design targets require a run bound to their originating task")
        }
        // The owner IS the originating task; reject a foreign owner
        // explicitly. The opaque owner string is preserved verbatim (the
        // identity it participated in already verified equal), so the
        // stable key the UI used to mint the confirmation is unchanged.
        guard raw.ownerID.caseInsensitiveCompare(liveTask.uuidString) == .orderedSame else {
            throw FloeError.validationFailed(
                "a run can only use the original attachment of its own task")
        }
        return DesignTarget(
            kind: .chatAttachment, ownerID: raw.ownerID,
            documentID: raw.documentID, sourceID: raw.sourceID,
            environmentID: raw.environmentID ?? context.environmentID, revision: revision,
            originConversationID: liveTask.uuidString.lowercased(),
            requestedOutputKind: nil)
    }
    // Non-chat owners: provenance is DERIVED from the live run context (the
    // durable run→task mapping), never trusted from model JSON. An unknown
    // binding leaves nil: no invented task and therefore no cross-task
    // durable event.
    return DesignTarget(
        kind: raw.kind, ownerID: raw.ownerID,
        documentID: raw.documentID, sourceID: raw.sourceID,
        environmentID: raw.environmentID ?? context.environmentID,
        revision: revision,
        originConversationID: liveTask?.uuidString.lowercased(),
        requestedOutputKind: raw.requestedOutputKind)
}

/// A creative creation target pre-exists independently of any workspace or
/// canvas containment, so run→source containment alone cannot authorize it.
/// An agent call must present the RUNTIME approval for THIS exact call —
/// `ToolContext.approvalGrantID`, minted by the policy/human gate and
/// already validated against the tool descriptor's authorization identity
/// before execution. This composes the actual existing authority: there is
/// no private grant store and no blanket allow. Trusted in-app UI calls the
/// workflow directly with `runID == nil` and is unaffected.
private func requireRuntimeApprovalForCreative(
    _ context: ToolContext, action: String
) throws {
    guard context.approvalGrantID != nil else {
        throw FloeError.validationFailed(
            "\(action) requires the user-confirmed runtime approval for this exact call; none is attached to the run context")
    }
}

/// Launch-binding coherence for a bound conversation: when this run's
/// conversation carries a durable design launch binding, a creative tool
/// must address EXACTLY the bound target identity (ownerID + sourceID). The
/// requested output kind is chosen at creativeBegin from the user's request
/// (a brand-new natural creation binds a kind-less target), so the kind is
/// NOT compared; the owner/document/source identity is. An unbound
/// conversation is unchanged (trusted UI calls the workflow directly with
/// runID == nil and no binding store entry).
private func requireMatchingLaunchBinding(
    _ target: DesignTarget,
    context: ToolContext,
    action: String
) throws {
    guard target.kind == .creativeDocument,
          let conversationID = context.conversationID,
          let binding = DesignLaunchBindingStore.load(conversationID: conversationID)
    else { return }
    let bound = binding.target
    guard bound.kind == .creativeDocument,
          bound.ownerID == target.ownerID,
          bound.sourceID == target.sourceID else {
        throw FloeError.validationFailed(
            "\(action) must address the launch-bound creative target (ownerID=\(bound.ownerID) sourceID=\(bound.sourceID)); a run cannot create a different or parallel creative request")
    }
}

/// Canvas keeps ONE mutable authority. Typed mutations are not offered for
/// canvas (mutation schemas exclude `canvasNode`); this defense-in-depth
/// guard returns the explicit compatible tool pointer if one is attempted.
private enum DesignCanvasCompatibility {
    static func compatibleTool(for action: String) -> String? {
        switch action {
        case "updateBrief": return "canvas.designUpdateBrief"
        case "updateSpec": return "canvas.designUpdateSpec"
        case "freezeInput": return "canvas.designUseCurrentNode"
        case "registerEdit": return "canvas.designRegisterRevision"
        case "addFeedback", "resolveFeedback", "relocateFeedback": return "canvas.designAddFeedback"
        case "propose": return "canvas.designPropose"
        case "adopt": return "canvas.designAdopt"
        case "reject": return "canvas.designReject"
        case "restore": return "canvas.designRestore"
        case "exportVerified": return "canvas.designExportRevision"
        default: return nil
        }
    }

    static func routeCanvasMutation(
        _ target: DesignTarget, action: String
    ) -> ToolExecutionOutput? {
        guard target.kind == .canvasNode, let tool = compatibleTool(for: action) else {
            return nil
        }
        return DesignToolOutput.routingFailure(
            "Canvas-node design \(action) uses the single Canvas authority; call the compatible tool with the canvas integer revision",
            compatibleTool: tool)
    }
}

// MARK: Discovery / reads

private struct DesignResolveTargetTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var target: DesignToolTargetInput
    }
    static let name = "design.resolveTarget"
    static let toolDescription = "Resolve a typed design target (canvas node, workspace file, original chat attachment, or creative creation target) to verified metadata: real format/content family, current base revision token, editability, originating task and capability. Never returns arbitrary path contents; permission and containment are re-derived from the live run context."
    static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"object","properties":{"kind":{"type":"string","enum":["canvasNode","fileDocument","chatAttachment","creativeDocument"]},"ownerID":{"type":"string"},"documentID":{"type":"string"},"sourceID":{"type":"string"},"environmentID":{"type":"string"},"revision":{"type":"string"},"originConversationID":{"type":"string"},"requestedOutputKind":{"type":"string","enum":["webpage","prototype","presentation","image","video","officeDocument","notes","pdf","cad"]}},"required":["kind","ownerID","sourceID"],"additionalProperties":false}},"required":["target"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles]
    static let isSideEffecting = false
    let dependencies: DesignOwnerToolDependencies?
    func validate(_ args: Arguments) throws { _ = try args.target.makeTarget() }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let dependencies else {
            return DesignToolOutput.routingFailure("the shared design target service is not connected")
        }
        let target = try await authorizedTarget(args.target, context: context, dependencies: dependencies)
        // Cheap live probe first: it never loads bytes for non-canvas kinds.
        let contains = await dependencies.targets.contains(target, runID: context.runID)
        let exists = await dependencies.targets.exists(target)
        let currentToken = await dependencies.targets.currentRevisionToken(target, runID: context.runID)
        guard contains else {
            return DesignToolOutput.make([
                "target": DesignToolOutput.target(target),
                "contains": false,
                "exists": exists,
                "currentRevisionToken": currentToken ?? "",
                "unavailableReason": "the live run context is not authorized for this target or it is outside the permitted containment"
            ], status: 2)
        }
        // The resolve returns verified bytes metadata (bytes themselves are
        // not exposed to the model here; freeze/propose consume them).
        let resolved: DesignResolvedSource
        do {
            resolved = try await dependencies.targets.resolve(target, runID: context.runID)
        } catch let error as DesignTargetError {
            return DesignToolOutput.make([
                "target": DesignToolOutput.target(target),
                "contains": contains,
                "exists": false,
                "currentRevisionToken": currentToken ?? "",
                "unavailableReason": String(describing: error)
            ], status: 2)
        }
        var payload = DesignToolOutput.resolved(resolved)
        payload["contains"] = true
        payload["exists"] = true
        return DesignToolOutput.make(payload)
    }
}

private struct DesignGetOwnerStateTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var target: DesignToolTargetInput
    }
    static let name = "design.getState"
    static let toolDescription = "Read the shared design state (brief, spec, frozen input, artifacts, revisions, feedback, candidates) for a typed target. Canvas nodes are read through the single Canvas authority (same state as canvas.designGetState); canvas mutations use the canvas.design* tools."
    static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"object","properties":{"kind":{"type":"string","enum":["canvasNode","fileDocument","chatAttachment","creativeDocument"]},"ownerID":{"type":"string"},"documentID":{"type":"string"},"sourceID":{"type":"string"},"environmentID":{"type":"string"},"revision":{"type":"string"},"originConversationID":{"type":"string"},"requestedOutputKind":{"type":"string","enum":["webpage","prototype","presentation","image","video","officeDocument","notes","pdf","cad"]}},"required":["kind","ownerID","sourceID"],"additionalProperties":false}},"required":["target"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles]
    static let isSideEffecting = false
    let dependencies: DesignOwnerToolDependencies?
    func validate(_ args: Arguments) throws { _ = try args.target.makeTarget() }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let dependencies else {
            return DesignToolOutput.routingFailure("the shared design owner workflow is not connected")
        }
        let target = try await authorizedTarget(args.target, context: context, dependencies: dependencies)
        if target.kind == .canvasNode {
            // ONE canvas authority: typed read goes through the SAME
            // DesignCanvasService snapshot the legacy wrapper uses, with
            // the same live run→canvas authorization.
            let canvasID = try DesignTargetValidation.uuid(target.ownerID, field: "ownerID")
            let nodeID = try DesignTargetValidation.uuid(target.sourceID, field: "sourceID")
            let snapshot = try await dependencies.canvasService.snapshot(
                runID: context.runID, canvasID: canvasID, nodeID: nodeID)
            return DesignToolOutput.make(DesignToolOutput.state(snapshot))
        }
        guard let envelope = try await dependencies.workflow.state(target, runID: context.runID) else {
            return DesignToolOutput.make([
                "target": DesignToolOutput.target(target),
                "design": NSNull(),
                "ownerRevision": 0,
                "unavailableReason": "no shared design state exists yet; freeze the input or save a brief first"
            ])
        }
        return DesignToolOutput.make(DesignToolOutput.owner(envelope))
    }
}

// MARK: - Brief / spec

private struct DesignOwnerUpdateBriefTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var target: DesignToolTargetInput
        var operationID: String
        var expectedOwnerRevision: Int64?
        var goal: String
        var audience: String?
        var constraints: [String]?
    }
    static let name = "design.updateBrief"
    static let toolDescription = "Create or update the brief on a typed non-canvas design target through the shared owner workflow. Requires operationID (idempotent replay) and the current owner revision."
    static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"object","properties":{"kind":{"type":"string","enum":["fileDocument","chatAttachment","creativeDocument"]},"ownerID":{"type":"string"},"documentID":{"type":"string"},"sourceID":{"type":"string"},"environmentID":{"type":"string"},"revision":{"type":"string"},"originConversationID":{"type":"string"},"requestedOutputKind":{"type":"string","enum":["webpage","prototype","presentation","image","video","officeDocument","notes","pdf","cad"]}},"required":["kind","ownerID","sourceID"],"additionalProperties":false},"operationID":{"type":"string"},"expectedOwnerRevision":{"type":"integer"},"goal":{"type":"string"},"audience":{"type":"string"},"constraints":{"type":"array","items":{"type":"string"}}},"required":["target","operationID","goal"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let dependencies: DesignOwnerToolDependencies?
    func validate(_ args: Arguments) throws {
        _ = try args.target.makeTarget()
        guard !args.operationID.isEmpty else { throw FloeError.validationFailed("operationID is required") }
        guard !args.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("goal must not be empty")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let dependencies else {
            return DesignToolOutput.routingFailure("the shared design owner workflow is not connected")
        }
        let target = try await authorizedTarget(args.target, context: context, dependencies: dependencies)
        if let routed = DesignCanvasCompatibility.routeCanvasMutation(target, action: "updateBrief") { return routed }
        let envelope = try await dependencies.workflow.updateBrief(
            target: target, operationID: args.operationID,
            expectedOwnerRevision: args.expectedOwnerRevision,
            brief: DesignBrief(goal: args.goal, audience: args.audience,
                               constraints: args.constraints ?? []),
            runID: context.runID)
        return DesignToolOutput.make(DesignToolOutput.owner(envelope))
    }
}

private struct DesignOwnerUpdateSpecTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var target: DesignToolTargetInput
        var operationID: String
        var expectedOwnerRevision: Int64?
        var designMarkdown: String?
        var palette: [String]?
        var typography: String?
        var layout: String?
        var spacing: String?
        var brandAssetRefs: [String]?
        var voice: String?
        var prohibitions: [String]?
    }
    static let name = "design.updateSpec"
    static let toolDescription = "Create or update the design spec (DESIGN.md import supported) on a typed non-canvas target through the shared owner workflow."
    static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"object","properties":{"kind":{"type":"string","enum":["fileDocument","chatAttachment","creativeDocument"]},"ownerID":{"type":"string"},"documentID":{"type":"string"},"sourceID":{"type":"string"},"environmentID":{"type":"string"},"revision":{"type":"string"},"originConversationID":{"type":"string"},"requestedOutputKind":{"type":"string","enum":["webpage","prototype","presentation","image","video","officeDocument","notes","pdf","cad"]}},"required":["kind","ownerID","sourceID"],"additionalProperties":false},"operationID":{"type":"string"},"expectedOwnerRevision":{"type":"integer"},"designMarkdown":{"type":"string"},"palette":{"type":"array","items":{"type":"string"}},"typography":{"type":"string"},"layout":{"type":"string"},"spacing":{"type":"string"},"brandAssetRefs":{"type":"array","items":{"type":"string"}},"voice":{"type":"string"},"prohibitions":{"type":"array","items":{"type":"string"}}},"required":["target","operationID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let dependencies: DesignOwnerToolDependencies?
    func validate(_ args: Arguments) throws {
        _ = try args.target.makeTarget()
        guard !args.operationID.isEmpty else { throw FloeError.validationFailed("operationID is required") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let dependencies else {
            return DesignToolOutput.routingFailure("the shared design owner workflow is not connected")
        }
        let target = try await authorizedTarget(args.target, context: context, dependencies: dependencies)
        if let routed = DesignCanvasCompatibility.routeCanvasMutation(target, action: "updateSpec") { return routed }
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
                palette: args.palette, typography: args.typography, layout: args.layout,
                spacing: args.spacing, brandAssetRefs: args.brandAssetRefs, voice: args.voice,
                prohibitions: args.prohibitions)
        }
        let envelope = try await dependencies.workflow.updateSpec(
            target: target, operationID: args.operationID,
            expectedOwnerRevision: args.expectedOwnerRevision, spec: spec, runID: context.runID)
        return DesignToolOutput.make(DesignToolOutput.owner(envelope))
    }
}

// MARK: - Freeze / edits

private struct DesignFreezeInputTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var target: DesignToolTargetInput
        var operationID: String
        var expectedOwnerRevision: Int64?
        var artifactID: String?
        var displayName: String?
    }
    static let name = "design.freezeInput"
    static let toolDescription = "Freeze the resolved source of a typed target as the base input revision (source re-resolved live; deleted/changed sources fail). Idempotent by operationID. Canvas nodes use canvas.designUseCurrentNode."
    static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"object","properties":{"kind":{"type":"string","enum":["fileDocument","chatAttachment","creativeDocument"]},"ownerID":{"type":"string"},"documentID":{"type":"string"},"sourceID":{"type":"string"},"environmentID":{"type":"string"},"revision":{"type":"string"},"originConversationID":{"type":"string"},"requestedOutputKind":{"type":"string","enum":["webpage","prototype","presentation","image","video","officeDocument","notes","pdf","cad"]}},"required":["kind","ownerID","sourceID"],"additionalProperties":false},"operationID":{"type":"string"},"expectedOwnerRevision":{"type":"integer"},"artifactID":{"type":"string"},"displayName":{"type":"string"}},"required":["target","operationID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles, .persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let dependencies: DesignOwnerToolDependencies?
    func validate(_ args: Arguments) throws {
        _ = try args.target.makeTarget()
        guard !args.operationID.isEmpty else { throw FloeError.validationFailed("operationID is required") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let dependencies else {
            return DesignToolOutput.routingFailure("the shared design owner workflow is not connected")
        }
        let target = try await authorizedTarget(args.target, context: context, dependencies: dependencies)
        if let routed = DesignCanvasCompatibility.routeCanvasMutation(target, action: "freezeInput") { return routed }
        let outcome = try await dependencies.workflow.freezeInput(
            target: target, operationID: args.operationID,
            expectedOwnerRevision: args.expectedOwnerRevision,
            artifactID: args.artifactID, displayName: args.displayName,
            runID: context.runID)
        var payload = DesignToolOutput.owner(outcome.envelope)
        payload["inputRevisionID"] = outcome.revision.id
        payload["source"] = DesignToolOutput.resolved(outcome.source)
        return DesignToolOutput.make(payload)
    }
}

private struct DesignRegisterEditTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var target: DesignToolTargetInput
        var operationID: String
        var expectedOwnerRevision: Int64?
        var artifactID: String
        var payloadRelativePath: String
        var proposedContentSHA256: String?
        var origin: String?
        var expectedArtifactRevisionID: String?
    }
    static let name = "design.registerEdit"
    static let toolDescription = "Record a manual/generated editor save as a new revision of a typed target's artifact. Bytes are read and hashed from the app artifact authority (the hash argument only verifies); compare-and-swap against the editor's base revision."
    static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"object","properties":{"kind":{"type":"string","enum":["fileDocument","chatAttachment","creativeDocument"]},"ownerID":{"type":"string"},"documentID":{"type":"string"},"sourceID":{"type":"string"},"environmentID":{"type":"string"},"revision":{"type":"string"},"originConversationID":{"type":"string"},"requestedOutputKind":{"type":"string","enum":["webpage","prototype","presentation","image","video","officeDocument","notes","pdf","cad"]}},"required":["kind","ownerID","sourceID"],"additionalProperties":false},"operationID":{"type":"string"},"expectedOwnerRevision":{"type":"integer"},"artifactID":{"type":"string"},"payloadRelativePath":{"type":"string"},"proposedContentSHA256":{"type":"string"},"origin":{"type":"string","enum":["importFile","generate","edit"]},"expectedArtifactRevisionID":{"type":"string"}},"required":["target","operationID","artifactID","payloadRelativePath"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles, .persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let dependencies: DesignOwnerToolDependencies?
    func validate(_ args: Arguments) throws {
        _ = try args.target.makeTarget()
        guard !args.operationID.isEmpty else { throw FloeError.validationFailed("operationID is required") }
        guard !args.payloadRelativePath.isEmpty else {
            throw FloeError.validationFailed("payloadRelativePath is required")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let dependencies else {
            return DesignToolOutput.routingFailure("the shared design owner workflow is not connected")
        }
        let target = try await authorizedTarget(args.target, context: context, dependencies: dependencies)
        if let routed = DesignCanvasCompatibility.routeCanvasMutation(target, action: "registerEdit") { return routed }
        let origin = args.origin.flatMap(DesignRevisionOrigin.init(rawValue:)) ?? .edit
        let payload = try DesignToolOutput.verifiedPayload(
            args.payloadRelativePath, claimedSHA256: args.proposedContentSHA256)
        let outcome = try await dependencies.workflow.registerEdit(
            target: target, operationID: args.operationID,
            expectedOwnerRevision: args.expectedOwnerRevision,
            artifactID: args.artifactID, bytes: payload.data, format: payload.format,
            origin: origin, expectedArtifactRevisionID: args.expectedArtifactRevisionID,
            runID: context.runID)
        var result = DesignToolOutput.owner(outcome.envelope)
        result["revisionID"] = outcome.revision.id
        result["contentSHA256"] = outcome.revision.contentSHA256
        return DesignToolOutput.make(result)
    }
}

// MARK: - Feedback

private struct DesignOwnerAddFeedbackTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var target: DesignToolTargetInput
        var operationID: String
        var expectedOwnerRevision: Int64?
        var artifactID: String
        var revisionID: String?
        var comment: String
        var anchorKind: String
        var x: Double?; var y: Double?; var width: Double?; var height: Double?
        var seconds: Double?; var page: Int?; var objectID: String?
    }
    static let name = "design.addFeedback"
    static let toolDescription = "Add region/time/page/object-anchored feedback to a typed target's artifact revision. It resolves only against a verified changing revision (design.resolveFeedback), never from model text."
    static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"object","properties":{"kind":{"type":"string","enum":["fileDocument","chatAttachment","creativeDocument"]},"ownerID":{"type":"string"},"documentID":{"type":"string"},"sourceID":{"type":"string"},"environmentID":{"type":"string"},"revision":{"type":"string"},"originConversationID":{"type":"string"},"requestedOutputKind":{"type":"string","enum":["webpage","prototype","presentation","image","video","officeDocument","notes","pdf","cad"]}},"required":["kind","ownerID","sourceID"],"additionalProperties":false},"operationID":{"type":"string"},"expectedOwnerRevision":{"type":"integer"},"artifactID":{"type":"string"},"revisionID":{"type":"string"},"comment":{"type":"string"},"anchorKind":{"type":"string","enum":["region","time","page","object"]},"x":{"type":"number"},"y":{"type":"number"},"width":{"type":"number"},"height":{"type":"number"},"seconds":{"type":"number"},"page":{"type":"integer"},"objectID":{"type":"string"}},"required":["target","operationID","artifactID","comment","anchorKind"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let dependencies: DesignOwnerToolDependencies?
    func validate(_ args: Arguments) throws {
        _ = try args.target.makeTarget()
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
        guard let dependencies else {
            return DesignToolOutput.routingFailure("the shared design owner workflow is not connected")
        }
        let target = try await authorizedTarget(args.target, context: context, dependencies: dependencies)
        if let routed = DesignCanvasCompatibility.routeCanvasMutation(target, action: "addFeedback") { return routed }
        let anchor: DesignFeedbackAnchor
        switch args.anchorKind {
        case "region": anchor = .region(x: args.x ?? 0, y: args.y ?? 0, width: args.width ?? 0, height: args.height ?? 0)
        case "time": anchor = .time(seconds: args.seconds ?? 0)
        case "page": anchor = .page(index: args.page ?? 0)
        default: anchor = .objectID(args.objectID ?? "")
        }
        let outcome = try await dependencies.workflow.addFeedback(
            target: target, operationID: args.operationID,
            expectedOwnerRevision: args.expectedOwnerRevision,
            artifactID: args.artifactID, revisionID: args.revisionID,
            anchor: anchor, comment: args.comment, author: .ai, runID: context.runID)
        var payload = DesignToolOutput.owner(outcome.envelope)
        payload["feedbackID"] = outcome.feedback.id
        payload["feedbackStatus"] = outcome.feedback.status.rawValue
        return DesignToolOutput.make(payload)
    }
}

private struct DesignResolveFeedbackTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var target: DesignToolTargetInput
        var operationID: String
        var expectedOwnerRevision: Int64?
        var feedbackID: String
        var resolvedByRevisionID: String
    }
    static let name = "design.resolveFeedback"
    static let toolDescription = "Resolve anchored feedback only against a verified changing revision of a typed target. A model statement never closes feedback."
    static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"object","properties":{"kind":{"type":"string","enum":["fileDocument","chatAttachment","creativeDocument"]},"ownerID":{"type":"string"},"documentID":{"type":"string"},"sourceID":{"type":"string"},"environmentID":{"type":"string"},"revision":{"type":"string"},"originConversationID":{"type":"string"},"requestedOutputKind":{"type":"string","enum":["webpage","prototype","presentation","image","video","officeDocument","notes","pdf","cad"]}},"required":["kind","ownerID","sourceID"],"additionalProperties":false},"operationID":{"type":"string"},"expectedOwnerRevision":{"type":"integer"},"feedbackID":{"type":"string"},"resolvedByRevisionID":{"type":"string"}},"required":["target","operationID","feedbackID","resolvedByRevisionID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let dependencies: DesignOwnerToolDependencies?
    func validate(_ args: Arguments) throws {
        _ = try args.target.makeTarget()
        guard !args.operationID.isEmpty, !args.feedbackID.isEmpty, !args.resolvedByRevisionID.isEmpty else {
            throw FloeError.validationFailed("operationID, feedbackID and resolvedByRevisionID are required")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let dependencies else {
            return DesignToolOutput.routingFailure("the shared design owner workflow is not connected")
        }
        let target = try await authorizedTarget(args.target, context: context, dependencies: dependencies)
        if let routed = DesignCanvasCompatibility.routeCanvasMutation(target, action: "resolveFeedback") { return routed }
        let envelope = try await dependencies.workflow.resolveFeedback(
            target: target, operationID: args.operationID,
            expectedOwnerRevision: args.expectedOwnerRevision,
            feedbackID: args.feedbackID, resolvedByRevisionID: args.resolvedByRevisionID,
            runID: context.runID)
        return DesignToolOutput.make(DesignToolOutput.owner(envelope))
    }
}

// MARK: - Creative start

private struct DesignCreativeBeginTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var target: DesignToolTargetInput
        var operationID: String
        var expectedOwnerRevision: Int64?
        var goal: String
        var audience: String?
        var designMarkdown: String?
    }
    static let name = "design.creativeBegin"
    static let toolDescription = "Persist a creative START request (requested output kind + brief/spec) for a creativeDocument target BEFORE any material exists. The run must present the runtime's approval for THIS call (the user/policy decision attached to the run context) and a creation target linked to the run's own task; a private grant store or a blanket allow is never accepted. No canvas or workspace is created; the first real generated result is bound later with design.creativeBindFirstResult."
    static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"object","properties":{"kind":{"type":"string","enum":["creativeDocument"]},"ownerID":{"type":"string"},"documentID":{"type":"string"},"sourceID":{"type":"string"},"environmentID":{"type":"string"},"revision":{"type":"string"},"originConversationID":{"type":"string"},"requestedOutputKind":{"type":"string","enum":["webpage","prototype","presentation","image","video","officeDocument","notes","pdf","cad"]}},"required":["kind","ownerID","sourceID","requestedOutputKind"],"additionalProperties":false},"operationID":{"type":"string"},"expectedOwnerRevision":{"type":"integer"},"goal":{"type":"string"},"audience":{"type":"string"},"designMarkdown":{"type":"string"}},"required":["target","operationID","goal"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let dependencies: DesignOwnerToolDependencies?
    func validate(_ args: Arguments) throws {
        let target = try args.target.makeTarget()
        guard target.kind == .creativeDocument, target.requestedOutputKind != nil else {
            throw FloeError.validationFailed(
                "design.creativeBegin requires a creativeDocument target with requestedOutputKind")
        }
        guard !args.operationID.isEmpty else { throw FloeError.validationFailed("operationID is required") }
        guard !args.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("goal must not be empty")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let dependencies else {
            return DesignToolOutput.routingFailure("the shared design owner workflow is not connected")
        }
        try requireRuntimeApprovalForCreative(context, action: Self.name)
        let target = try await authorizedTarget(args.target, context: context, dependencies: dependencies)
        try requireMatchingLaunchBinding(target, context: context, action: Self.name)
        let spec = args.designMarkdown.map { DesignMDCodec.parse($0) }
        let outcome = try await dependencies.workflow.beginCreativeRequest(
            target: target, operationID: args.operationID,
            expectedOwnerRevision: args.expectedOwnerRevision,
            brief: DesignBrief(goal: args.goal, audience: args.audience, constraints: []),
            spec: spec, runID: context.runID)
        var payload = DesignToolOutput.owner(outcome.envelope)
        payload["creativeState"] = outcome.request.state.rawValue
        payload["requestedOutputKind"] = outcome.request.requestedKind.rawValue
        // Recency bookkeeping for the natural-language entry: the durable
        // request lives in the owner envelope; this keeps the Creative home
        // "recent request" row pointing at the same identity.
        DesignCreativeRequestStore.remember(target)
        return DesignToolOutput.make(payload)
    }
}

private struct DesignCreativeBindFirstResultTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var target: DesignToolTargetInput
        var operationID: String
        var expectedOwnerRevision: Int64
        var boundResultID: String
        var payloadRelativePath: String
        var displayName: String?
        var proposedContentSHA256: String?
    }
    static let name = "design.creativeBindFirstResult"
    static let toolDescription = "Bind the FIRST real generated result to an awaiting creative request: first revision registered, run frozen, request becomes firstResultBound. The run must present the runtime's approval for THIS call; payloadRelativePath bytes must BE the real retained creative asset named by boundResultID (identical bytes and format), and for a run that asset must be the committed local result of a durable media generation job owned by the run's own task. A mismatched, foreign or unverifiable binding is refused BEFORE any payload or owner revision is written. A second different bind is rejected; later edits use design.registerEdit/design.propose."
    static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"object","properties":{"kind":{"type":"string","enum":["creativeDocument"]},"ownerID":{"type":"string"},"documentID":{"type":"string"},"sourceID":{"type":"string"},"environmentID":{"type":"string"},"revision":{"type":"string"},"originConversationID":{"type":"string"},"requestedOutputKind":{"type":"string","enum":["webpage","prototype","presentation","image","video","officeDocument","notes","pdf","cad"]}},"required":["kind","ownerID","sourceID","requestedOutputKind"],"additionalProperties":false},"operationID":{"type":"string"},"expectedOwnerRevision":{"type":"integer"},"boundResultID":{"type":"string"},"payloadRelativePath":{"type":"string"},"displayName":{"type":"string"},"proposedContentSHA256":{"type":"string"}},"required":["target","operationID","expectedOwnerRevision","boundResultID","payloadRelativePath"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles, .persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let dependencies: DesignOwnerToolDependencies?
    func validate(_ args: Arguments) throws {
        let target = try args.target.makeTarget()
        guard target.kind == .creativeDocument, target.requestedOutputKind != nil else {
            throw FloeError.validationFailed(
                "design.creativeBindFirstResult requires a creativeDocument target with requestedOutputKind")
        }
        guard !args.operationID.isEmpty, !args.boundResultID.isEmpty, !args.payloadRelativePath.isEmpty else {
            throw FloeError.validationFailed("operationID, boundResultID and payloadRelativePath are required")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let dependencies else {
            return DesignToolOutput.routingFailure("the shared design owner workflow is not connected")
        }
        try requireRuntimeApprovalForCreative(context, action: Self.name)
        let target = try await authorizedTarget(args.target, context: context, dependencies: dependencies)
        try requireMatchingLaunchBinding(target, context: context, action: Self.name)
        let payload = try DesignToolOutput.verifiedPayload(
            args.payloadRelativePath, claimedSHA256: args.proposedContentSHA256)
        let outcome = try await dependencies.workflow.bindFirstResult(
            target: target, operationID: args.operationID,
            expectedOwnerRevision: args.expectedOwnerRevision,
            bytes: payload.data, format: payload.format,
            displayName: args.displayName ?? (args.payloadRelativePath as NSString).lastPathComponent,
            boundResultID: args.boundResultID, runID: context.runID)
        var result = DesignToolOutput.owner(outcome.envelope)
        result["revisionID"] = outcome.revision.id
        result["contentSHA256"] = outcome.revision.contentSHA256
        return DesignToolOutput.make(result)
    }
}

// MARK: - Propose / compare / decide

private struct DesignProposeOwnerTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var target: DesignToolTargetInput
        var operationID: String
        var expectedOwnerRevision: Int64?
        var artifactID: String
        var baseRevisionID: String?
        var payloadRelativePath: String
        var proposedContentSHA256: String?
        var summary: String
        var diff: [String]?
        var feedbackIDs: [String]?
    }
    static let name = "design.propose"
    static let toolDescription = "Propose a revision-bound candidate for a typed target from real app-storage bytes read and verified by the tool itself. The candidate stays pending until a user-confirmed grant adopts it; replay returns the recorded candidate and changed arguments under the same operationID are rejected. Canvas nodes use canvas.designPropose."
    static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"object","properties":{"kind":{"type":"string","enum":["fileDocument","chatAttachment","creativeDocument"]},"ownerID":{"type":"string"},"documentID":{"type":"string"},"sourceID":{"type":"string"},"environmentID":{"type":"string"},"revision":{"type":"string"},"originConversationID":{"type":"string"},"requestedOutputKind":{"type":"string","enum":["webpage","prototype","presentation","image","video","officeDocument","notes","pdf","cad"]}},"required":["kind","ownerID","sourceID"],"additionalProperties":false},"operationID":{"type":"string"},"expectedOwnerRevision":{"type":"integer"},"artifactID":{"type":"string"},"baseRevisionID":{"type":"string"},"payloadRelativePath":{"type":"string"},"proposedContentSHA256":{"type":"string"},"summary":{"type":"string"},"diff":{"type":"array","items":{"type":"string"}},"feedbackIDs":{"type":"array","items":{"type":"string"}}},"required":["target","operationID","artifactID","payloadRelativePath","summary"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles, .persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let dependencies: DesignOwnerToolDependencies?
    func validate(_ args: Arguments) throws {
        _ = try args.target.makeTarget()
        guard !args.operationID.isEmpty else { throw FloeError.validationFailed("operationID is required") }
        guard !args.payloadRelativePath.isEmpty else {
            throw FloeError.validationFailed("payloadRelativePath is required; proposals must point at real bytes")
        }
        guard !args.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("summary must not be empty")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let dependencies else {
            return DesignToolOutput.routingFailure("the shared design owner workflow is not connected")
        }
        let target = try await authorizedTarget(args.target, context: context, dependencies: dependencies)
        if let routed = DesignCanvasCompatibility.routeCanvasMutation(target, action: "propose") { return routed }
        let payload = try DesignToolOutput.verifiedPayload(
            args.payloadRelativePath, claimedSHA256: args.proposedContentSHA256)
        // Replay and exact-input verification live INSIDE the shared
        // `DesignOwnerWorkflow.propose` (operation → candidate record in the
        // same envelope CAS): a repeated operationID returns the recorded
        // candidate and its payload without staging anything, and any
        // changed semantic input is refused there. The tool does not carry a
        // second replay policy.
        //
        // Work mode comes from the TRUSTED FROZEN LAUNCH BINDING, never from
        // model text (the tool schema intentionally has no mode field): a
        // model cannot downgrade an active 重构 to 修改 by omitting or
        // changing a field. A 重构 additionally burns the single-use
        // preservation claim through the trusted authority handler before
        // any bytes are staged; the frozen operation identity must match the
        // confirmed one exactly.
        let workIntent: DesignWorkIntent?
        let restructureAuthority: DesignRestructureAuthorityHandler?
        let boundWorkMode: DesignWorkMode?
        if let binding = context.conversationID.flatMap(DesignLaunchBindingStore.load(conversationID:)) {
            boundWorkMode = binding.workMode
            let operationID: String
            if binding.workMode == .restructure {
                guard let frozen = binding.frozenRestructureOperationID, !frozen.isEmpty else {
                    throw FloeError.validationFailed(
                        "design.propose: this task is bound to a 重构, but no confirmed preservation operation exists; the user must confirm the preservation requirements in the design page first")
                }
                guard frozen == args.operationID else {
                    throw FloeError.validationFailed(
                        "design.propose: 重构 operationID does not match the confirmed preservation operation; proposals cannot rebind a confirmed restructure to a different operation")
                }
                operationID = frozen
            } else {
                operationID = args.operationID
            }
            workIntent = binding.makeWorkIntent(
                actualDesiredFormat: payload.format, operationID: operationID)
            restructureAuthority = binding.workMode == .restructure
                ? await DesignRestructureAuthorization.shared.makeAuthorityHandler()
                : nil
        } else {
            workIntent = nil
            restructureAuthority = nil
            boundWorkMode = nil
        }
        let proposal = try await dependencies.workflow.propose(
            target: target, operationID: args.operationID,
            expectedOwnerRevision: args.expectedOwnerRevision,
            artifactID: args.artifactID, baseRevisionID: args.baseRevisionID,
            bytes: payload.data, format: payload.format, summary: args.summary,
            diff: args.diff ?? [], feedbackIDs: args.feedbackIDs ?? [],
            runID: context.runID, workIntent: workIntent,
            restructureAuthority: restructureAuthority)
        // A pending candidate now exists: freeze the original source so
        // ordinary writes cannot overwrite it before adoption. Idempotent
        // for replays (protect replaces the same entry). The protection is
        // keyed to the real originating conversation — a missing context
        // conversation never mints an orphaned random-owner freeze.
        let freezeConversationID = context.conversationID
            ?? target.originConversationID.flatMap(UUID.init(uuidString:))
        if let freezeConversationID {
            await DesignFreezeProtectionCoordinator.establish(
                binding: DesignLaunchBinding(
                    target: target, workMode: boundWorkMode ?? .modify,
                    originalConversationID: target.originConversationID),
                conversationID: freezeConversationID,
                workspaceStore: dependencies.database().map { SQLiteWorkspaceStore(database: $0) })
        }
        var result = DesignToolOutput.owner(proposal.envelope)
        result["candidateID"] = proposal.candidate.id
        result["candidateStatus"] = proposal.candidate.status.rawValue
        result["baseRevisionID"] = proposal.candidate.baseRevisionID
        result["proposedRevisionID"] = proposal.candidate.proposedRevisionID
        result["payloadRelativePath"] = proposal.payloadRelativePath
        result["operationReplayed"] = proposal.replayed
        return DesignToolOutput.make(result)
    }
}

private struct DesignCompareTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var target: DesignToolTargetInput
        var candidateID: String
    }
    static let name = "design.compare"
    static let toolDescription = "Compare a pending candidate against its base from retained verified bytes. Digest equality is the change proof; diff lines are a bounded, unified-style aid and diffTruncated/diffNote say when they are not the complete change set."
    static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"object","properties":{"kind":{"type":"string","enum":["fileDocument","chatAttachment","creativeDocument"]},"ownerID":{"type":"string"},"documentID":{"type":"string"},"sourceID":{"type":"string"},"environmentID":{"type":"string"},"revision":{"type":"string"},"originConversationID":{"type":"string"},"requestedOutputKind":{"type":"string","enum":["webpage","prototype","presentation","image","video","officeDocument","notes","pdf","cad"]}},"required":["kind","ownerID","sourceID"],"additionalProperties":false},"candidateID":{"type":"string"}},"required":["target","candidateID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles]
    static let isSideEffecting = false
    let dependencies: DesignOwnerToolDependencies?
    func validate(_ args: Arguments) throws {
        _ = try args.target.makeTarget()
        guard !args.candidateID.isEmpty else { throw FloeError.validationFailed("candidateID is required") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let dependencies else {
            return DesignToolOutput.routingFailure("the shared design owner workflow is not connected")
        }
        let target = try await authorizedTarget(args.target, context: context, dependencies: dependencies)
        if let routed = DesignCanvasCompatibility.routeCanvasMutation(target, action: "compare") { return routed }
        let comparison = try await dependencies.workflow.compare(
            target: target, candidateID: args.candidateID, runID: context.runID)
        return DesignToolOutput.make(DesignToolOutput.comparison(comparison))
    }
}

/// The conversation that owns a design freeze for a tool call, when one can
/// be determined honestly: the run's own conversation, else the target's
/// recorded origin. nil means no owner — callers must skip establishing
/// rather than mint an orphaned random-owner freeze.
private func freezeOwner(conversationID: UUID?, target: DesignTarget) -> UUID? {
    conversationID ?? target.originConversationID.flatMap(UUID.init(uuidString:))
}

private struct DesignAdoptOwnerTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var target: DesignToolTargetInput
        var operationID: String
        var expectedOwnerRevision: Int64
        var candidateID: String
        var mode: String?
        /// User-minted single-use grant id (trusted confirmation sheet).
        var grantID: String
    }
    static let name = "design.adopt"
    static let toolDescription = "Adopt a pending candidate on a typed target with a user-issued single-use grant bound to the exact source/candidate/base. File targets update the original authorized file in one verified transaction (variant branches instead); chat/creative results are RETURNED as a new attachment/asset through the existing stores (idempotent), with a durable accepted event to the ORIGINATING task only. Replay returns the recorded result and does not re-consume the grant."
    static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"object","properties":{"kind":{"type":"string","enum":["fileDocument","chatAttachment","creativeDocument"]},"ownerID":{"type":"string"},"documentID":{"type":"string"},"sourceID":{"type":"string"},"environmentID":{"type":"string"},"revision":{"type":"string"},"originConversationID":{"type":"string"},"requestedOutputKind":{"type":"string","enum":["webpage","prototype","presentation","image","video","officeDocument","notes","pdf","cad"]}},"required":["kind","ownerID","sourceID"],"additionalProperties":false},"operationID":{"type":"string"},"expectedOwnerRevision":{"type":"integer"},"candidateID":{"type":"string"},"mode":{"type":"string","enum":["updateOriginal","variant"]},"grantID":{"type":"string","description":"Single-use grant from the user's explicit confirmation; the model cannot mint one"}},"required":["target","operationID","expectedOwnerRevision","candidateID","grantID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.writesFiles, .persistsPersonalData]
    static let isSideEffecting = true
    let dependencies: DesignOwnerToolDependencies?
    func validate(_ args: Arguments) throws {
        _ = try args.target.makeTarget()
        guard !args.operationID.isEmpty else { throw FloeError.validationFailed("operationID is required") }
        guard !args.candidateID.isEmpty else { throw FloeError.validationFailed("candidateID is required") }
        guard !args.grantID.isEmpty else {
            throw FloeError.validationFailed(
                "grantID is required: adoption needs the user's explicit confirmation for this exact candidate and base revision")
        }
        if let mode = args.mode, DesignAdoptMode(rawValue: mode) == nil {
            throw FloeError.validationFailed("mode must be updateOriginal or variant")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let dependencies else {
            return DesignToolOutput.routingFailure("the shared design owner workflow is not connected")
        }
        let target = try await authorizedTarget(args.target, context: context, dependencies: dependencies)
        if let routed = DesignCanvasCompatibility.routeCanvasMutation(target, action: "adopt") { return routed }
        let mode = DesignAdoptMode(rawValue: args.mode ?? "updateOriginal") ?? .updateOriginal
        // Baseline + proposed revision = the candidate's exact change. Both
        // are loaded from the STORE (never from model text) and bound into
        // the confirmation check.
        let state = try await dependencies.workflow.state(target, runID: context.runID)
        guard let candidate = state?.project.candidate(args.candidateID) else {
            throw FloeError.validationFailed("Candidate \(args.candidateID) not found for this target")
        }
        let baselineRevisionID = candidate.baseRevisionID
        let proposedRevisionID = candidate.proposedRevisionID
        // The user's single-use confirmation is CLAIMED ATOMICALLY inside
        // the shared adoption transaction, immediately before its first
        // side effect (durable intent / owner write). A replay of an
        // already applied operation returns the recorded result without
        // touching the grant; a fresh adoption fails closed with zero side
        // effects unless the exact target/candidate/base/proposed/mode/
        // scope grant is live. A mismatched or already burned grant is
        // never re-armed: the user must confirm again.
        let result = try await dependencies.workflow.adopt(
            target: target, operationID: args.operationID,
            expectedOwnerRevision: args.expectedOwnerRevision,
            candidateID: args.candidateID, mode: mode, runID: context.runID,
            claimAuthorization: {
                guard await dependencies.grants.claimOwnerAdoption(
                    grantID: args.grantID, targetStableKey: target.stableKey,
                    candidateID: args.candidateID,
                    baselineRevisionID: baselineRevisionID,
                    proposedRevisionID: proposedRevisionID,
                    mode: mode, scope: .aiTool
                ) else {
                    throw FloeError.validationFailed(
                        "the adoption grant is missing, expired, already used, or bound to a different candidate/base/revision/mode; ask the user to confirm this exact change")
                }
            },
            // C10: a connected real-format verifier is mandatory.
            verifyReopen: await DesignOwnerWorkflowFactory.verifier(adapters: dependencies.adapters))
        // Run-lifecycle contract: a verified adoption permits ONLY the exact
        // approved commit — never arbitrary subsequent raw writes by this
        // still-active run. With no pending candidate the new bytes become
        // the re-frozen approved baseline; the freeze lifts only when the
        // run completes safely (ConversationCenter run-end hook) or the
        // user resolves the work in the trusted panel. A re-arm FAILURE
        // keeps the previous protection (fail closed: this run's next
        // ordinary write is still refused) and is reported in the tool
        // output — never an assumed-success void.
        var protectionRearmFailed = false
        if result.envelope.project.candidates.contains(where: { $0.status == .pending }) == false,
           let owner = context.conversationID
           ?? target.originConversationID.flatMap(UUID.init(uuidString:)) {
            let rearmed = await DesignFreezeProtectionCoordinator.establish(
                binding: DesignLaunchBinding(
                    target: target, workMode: .modify,
                    originalConversationID: target.originConversationID),
                conversationID: owner,
                workspaceStore: dependencies.database().map { SQLiteWorkspaceStore(database: $0) })
            protectionRearmFailed = !rearmed
        }
        var output = DesignToolOutput.decision(result)
        if protectionRearmFailed {
            output["protectionRearmFailed"] = "true"
            output["protectionRecovery"] = "the original stays frozen; the user can retry from the design page or restart the app"
        }
        return DesignToolOutput.make(output)
    }
}

private struct DesignRejectOwnerTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var target: DesignToolTargetInput
        var operationID: String
        var expectedOwnerRevision: Int64
        var candidateID: String
    }
    static let name = "design.reject"
    static let toolDescription = "Reject a pending candidate on a typed target without changing the artifact; a durable rejected event goes to the originating task only, idempotently."
    static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"object","properties":{"kind":{"type":"string","enum":["fileDocument","chatAttachment","creativeDocument"]},"ownerID":{"type":"string"},"documentID":{"type":"string"},"sourceID":{"type":"string"},"environmentID":{"type":"string"},"revision":{"type":"string"},"originConversationID":{"type":"string"},"requestedOutputKind":{"type":"string","enum":["webpage","prototype","presentation","image","video","officeDocument","notes","pdf","cad"]}},"required":["kind","ownerID","sourceID"],"additionalProperties":false},"operationID":{"type":"string"},"expectedOwnerRevision":{"type":"integer"},"candidateID":{"type":"string"}},"required":["target","operationID","expectedOwnerRevision","candidateID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let dependencies: DesignOwnerToolDependencies?
    func validate(_ args: Arguments) throws {
        _ = try args.target.makeTarget()
        guard !args.operationID.isEmpty, !args.candidateID.isEmpty else {
            throw FloeError.validationFailed("operationID and candidateID are required")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let dependencies else {
            return DesignToolOutput.routingFailure("the shared design owner workflow is not connected")
        }
        let target = try await authorizedTarget(args.target, context: context, dependencies: dependencies)
        if let routed = DesignCanvasCompatibility.routeCanvasMutation(target, action: "reject") { return routed }
        let result = try await dependencies.workflow.reject(
            target: target, operationID: args.operationID,
            expectedOwnerRevision: args.expectedOwnerRevision,
            candidateID: args.candidateID, runID: context.runID)
        // A model-controlled rejection NEVER lifts the original-write freeze:
        // with no pending candidate this same run could otherwise raw-write
        // the original and bypass the staged-adoption contract. The freeze
        // lifts only at the safe resolution points — the user rejecting in
        // the trusted panel with no active run, or a completed design run
        // with nothing pending.
        return DesignToolOutput.make(DesignToolOutput.decision(result))
    }
}

private struct DesignRestoreOwnerTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var target: DesignToolTargetInput
        var operationID: String
        var expectedOwnerRevision: Int64
        var artifactID: String
        var revisionID: String
    }
    static let name = "design.restore"
    static let toolDescription = "Restore a previous artifact revision as the current revision of a typed target; retained bytes are hash-verified first. Canvas nodes use canvas.designRestore."
    static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"object","properties":{"kind":{"type":"string","enum":["fileDocument","chatAttachment","creativeDocument"]},"ownerID":{"type":"string"},"documentID":{"type":"string"},"sourceID":{"type":"string"},"environmentID":{"type":"string"},"revision":{"type":"string"},"originConversationID":{"type":"string"},"requestedOutputKind":{"type":"string","enum":["webpage","prototype","presentation","image","video","officeDocument","notes","pdf","cad"]}},"required":["kind","ownerID","sourceID"],"additionalProperties":false},"operationID":{"type":"string"},"expectedOwnerRevision":{"type":"integer"},"artifactID":{"type":"string"},"revisionID":{"type":"string"}},"required":["target","operationID","expectedOwnerRevision","artifactID","revisionID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let dependencies: DesignOwnerToolDependencies?
    func validate(_ args: Arguments) throws {
        _ = try args.target.makeTarget()
        guard !args.operationID.isEmpty, !args.artifactID.isEmpty, !args.revisionID.isEmpty else {
            throw FloeError.validationFailed("operationID, artifactID and revisionID are required")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let dependencies else {
            return DesignToolOutput.routingFailure("the shared design owner workflow is not connected")
        }
        let target = try await authorizedTarget(args.target, context: context, dependencies: dependencies)
        if let routed = DesignCanvasCompatibility.routeCanvasMutation(target, action: "restore") { return routed }
        let envelope = try await dependencies.workflow.restore(
            target: target, operationID: args.operationID,
            expectedOwnerRevision: args.expectedOwnerRevision,
            artifactID: args.artifactID, revisionID: args.revisionID,
            runID: context.runID)
        return DesignToolOutput.make(DesignToolOutput.owner(envelope))
    }
}

private struct DesignExportVerifiedTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var target: DesignToolTargetInput
        var artifactID: String
        var revisionID: String
    }
    static let name = "design.exportVerified"
    static let toolDescription = "Export one verified revision of a typed target's artifact through the shared artifact authority: retained bytes are re-hashed and reopened with the real format parser, then written as a DesignRevisions export the model can reference. No format conversion is claimed."
    static let parametersJSON = #"{"type":"object","properties":{"target":{"type":"object","properties":{"kind":{"type":"string","enum":["fileDocument","chatAttachment","creativeDocument"]},"ownerID":{"type":"string"},"documentID":{"type":"string"},"sourceID":{"type":"string"},"environmentID":{"type":"string"},"revision":{"type":"string"},"originConversationID":{"type":"string"},"requestedOutputKind":{"type":"string","enum":["webpage","prototype","presentation","image","video","officeDocument","notes","pdf","cad"]}},"required":["kind","ownerID","sourceID"],"additionalProperties":false},"artifactID":{"type":"string"},"revisionID":{"type":"string"}},"required":["target","artifactID","revisionID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let dependencies: DesignOwnerToolDependencies?
    func validate(_ args: Arguments) throws {
        _ = try args.target.makeTarget()
        guard !args.artifactID.isEmpty, !args.revisionID.isEmpty else {
            throw FloeError.validationFailed("artifactID and revisionID are required")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let dependencies else {
            return DesignToolOutput.routingFailure("the shared design owner workflow is not connected")
        }
        let target = try await authorizedTarget(args.target, context: context, dependencies: dependencies)
        if let routed = DesignCanvasCompatibility.routeCanvasMutation(target, action: "exportVerified") { return routed }
        let bytes = try await dependencies.workflow.exportVerified(
            target: target, artifactID: args.artifactID, revisionID: args.revisionID,
            runID: context.runID,
            verifyReopen: await DesignOwnerWorkflowFactory.verifier(adapters: dependencies.adapters))
        // Publish into the existing artifact authority (tool-namespace),
        // atomically, content-named for replay convergence.
        let digest = FloeDigest.sha256Hex(bytes)
        let envelope = try await dependencies.workflow.state(target, runID: context.runID)
        let format = envelope?.project.artifact(args.artifactID)?
            .revision(args.revisionID)?.payloadFormat ?? "bin"
        let root = try FloeArtifactStore.root()
            .appendingPathComponent("DesignRevisions", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let relative = "DesignRevisions/exports/\(digest).\(format)"
        let destination = root.appendingPathComponent("\(digest).\(format)")
        if !FileManager.default.fileExists(atPath: destination.path) {
            let staging = root.appendingPathComponent(".\(digest).\(format).\(UUID().uuidString.lowercased()).staging")
            try bytes.write(to: staging, options: .atomic)
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        return DesignToolOutput.make([
            "exported": true,
            "path": relative,
            "format": format,
            "byteCount": bytes.count,
            "contentSHA256": digest,
            "verified": true
        ])
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
    targets: DesignTargetService? = nil,
    ownerWorkflow: DesignOwnerWorkflow? = nil,
    ownerAdoptionGrants: DesignOwnerAuthorization = .shared,
    canvasService: DesignCanvasService? = nil,
    runTask: (@MainActor @Sendable (UUID) async -> UUID?)? = nil,
    registry: ToolRunnerRegistry = .shared
) {
    // Creative destination routing: the model commits the destination
    // after reading real capabilities; the project path is created and
    // navigated here, idempotently. Ordinary Q&A never calls this.
    ToolCatalog.register(CreativeChooseDestinationTool.self)
    registry.register(CreativeChooseDestinationTool(environment: environment))
    let service = DesignCanvasService(repository: repository, authorize: authorize)
    ToolCatalog.register(DesignGetStateTool.self); registry.register(DesignGetStateTool(service: service))
    ToolCatalog.register(DesignCapabilitiesTool.self); registry.register(DesignCapabilitiesTool(
        registryProvider: capabilities,
        liveMatrixProvider: { [weak environment] in
            environment?.designCapabilityMatrix
                ?? DesignCapabilityMatrix(registry: .designCoreDefaults())
        }))
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

    // Typed shared-target family (T5). When the T3 composition is not wired
    // (nil), the tools still register and honestly report the capability as
    // unavailable — they never fabricate a second workflow.
    let effectiveRunTask: @MainActor @Sendable (UUID) async -> UUID? = runTask
        ?? { [database = environment.database] runID in
            // The durable run record is the existing authority for which
            // task a run executed in.
            let store = SQLiteRunStore(database: database)
            return (try? await store.run(id: runID))?.conversationID
        }
    let ownerDependencies: DesignOwnerToolDependencies?
    if let targets, let ownerWorkflow {
        ownerDependencies = DesignOwnerToolDependencies(
            targets: targets, workflow: ownerWorkflow,
            adapters: adapters, grants: ownerAdoptionGrants,
            canvasService: canvasService ?? service,
            runTask: effectiveRunTask,
            database: { [weak environment] in environment?.database })
    } else {
        ownerDependencies = nil
    }
    ToolCatalog.register(DesignResolveTargetTool.self)
    registry.register(AnyAgentTool(DesignResolveTargetTool(dependencies: ownerDependencies)))
    ToolCatalog.register(DesignGetOwnerStateTool.self)
    registry.register(AnyAgentTool(DesignGetOwnerStateTool(dependencies: ownerDependencies)))
    ToolCatalog.register(DesignOwnerUpdateBriefTool.self)
    registry.register(AnyAgentTool(DesignOwnerUpdateBriefTool(dependencies: ownerDependencies)))
    ToolCatalog.register(DesignOwnerUpdateSpecTool.self)
    registry.register(AnyAgentTool(DesignOwnerUpdateSpecTool(dependencies: ownerDependencies)))
    ToolCatalog.register(DesignFreezeInputTool.self)
    registry.register(AnyAgentTool(DesignFreezeInputTool(dependencies: ownerDependencies)))
    ToolCatalog.register(DesignRegisterEditTool.self)
    registry.register(AnyAgentTool(DesignRegisterEditTool(dependencies: ownerDependencies)))
    ToolCatalog.register(DesignOwnerAddFeedbackTool.self)
    registry.register(AnyAgentTool(DesignOwnerAddFeedbackTool(dependencies: ownerDependencies)))
    ToolCatalog.register(DesignResolveFeedbackTool.self)
    registry.register(AnyAgentTool(DesignResolveFeedbackTool(dependencies: ownerDependencies)))
    ToolCatalog.register(DesignCreativeBeginTool.self)
    registry.register(AnyAgentTool(DesignCreativeBeginTool(dependencies: ownerDependencies)))
    ToolCatalog.register(DesignCreativeBindFirstResultTool.self)
    registry.register(AnyAgentTool(DesignCreativeBindFirstResultTool(dependencies: ownerDependencies)))
    ToolCatalog.register(DesignProposeOwnerTool.self)
    registry.register(AnyAgentTool(DesignProposeOwnerTool(dependencies: ownerDependencies)))
    ToolCatalog.register(DesignCompareTool.self)
    registry.register(AnyAgentTool(DesignCompareTool(dependencies: ownerDependencies)))
    ToolCatalog.register(DesignAdoptOwnerTool.self)
    registry.register(AnyAgentTool(DesignAdoptOwnerTool(dependencies: ownerDependencies)))
    ToolCatalog.register(DesignRejectOwnerTool.self)
    registry.register(AnyAgentTool(DesignRejectOwnerTool(dependencies: ownerDependencies)))
    ToolCatalog.register(DesignRestoreOwnerTool.self)
    registry.register(AnyAgentTool(DesignRestoreOwnerTool(dependencies: ownerDependencies)))
    ToolCatalog.register(DesignExportVerifiedTool.self)
    registry.register(AnyAgentTool(DesignExportVerifiedTool(dependencies: ownerDependencies)))
}
#endif
