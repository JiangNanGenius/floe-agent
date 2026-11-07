// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeTools
import FloeChemistryCore
import FloeChemistryEngine

/// This prepares chemistry state and reconciles native receipts. Execution
/// still passes through the separately approved, real jobs.submit tool.
nonisolated struct ChemistryEnvironmentTool: AgentTool {
    enum Action: String, Decodable, Sendable { case probe, prepare, adopt, status, cancel }
    struct Arguments: Decodable, Sendable {
        let projectID: UUID
        let action: Action
        var objectID: UUID?
        var expectedObjectRevision: UInt64?
        var method: String?
        var optionsJSON: String?
        var attemptID: UUID?
        var jobID: UUID?
    }
    static let name = "studio.chemistry.environment"
    static let toolDescription = "Use an independent native chemistry project's real task execution environment. probe prepares an actual Python capability job; prepare freezes the selected saved structure/revision and returns canonical pendingJobs. Submit those exact arguments with real jobs.submit, then adopt the genuine returned jobID. status reconciles original owned jobs and verifies complete file output, identity and input digest before storing results. cancel returns real jobs.cancel arguments for an adopted job. Never resubmit an existing attempt. No interpreter path, shell, environment label, worker source or output can grant permission. Native chemistry uses studio.chemistry."
    static let parametersJSON = #"{"type":"object","properties":{"projectID":{"type":"string","format":"uuid"},"action":{"type":"string","enum":["probe","prepare","adopt","status","cancel"]},"objectID":{"type":"string","format":"uuid"},"expectedObjectRevision":{"type":"integer","minimum":0},"method":{"type":"string","minLength":1,"maxLength":128},"optionsJSON":{"type":"string","maxLength":32768},"attemptID":{"type":"string","format":"uuid"},"jobID":{"type":"string","format":"uuid"}},"required":["projectID","action"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles, .persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    static let executionBoundary: ToolExecutionBoundary = .mainRunOnly
    let environment: AppEnvironment
    let adapter: ChemistryEnvironmentJobAdapter

    func validate(_ args: Arguments) throws {
        if args.action == .prepare {
            guard args.objectID != nil, args.expectedObjectRevision != nil,
                  let method = args.method, !method.isEmpty, method.utf8.count <= 128,
                  method.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
                throw FloeError.validationFailed("Read a saved structure and provide its exact object revision and method")
            }
        }
        if [.adopt, .status, .cancel].contains(args.action), args.attemptID == nil {
            throw FloeError.validationFailed("Provide the original attemptID")
        }
        if args.action == .adopt, args.jobID == nil { throw FloeError.validationFailed("Provide the genuine returned jobID") }
        if let options = args.optionsJSON {
            guard options.utf8.count <= 32768,
                  case .object = try JSONDecoder().decode(FloeChemistryCore.JSONValue.self, from: Data(options.utf8)) else {
                throw FloeError.validationFailed("Calculation options must be a bounded JSON object")
            }
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await perform(args, context: context)
    }
    @MainActor private func perform(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard context.approvalGrantID != nil else { throw FloeError.unauthorized }
        let location = try await environment.studioCoordinator.location(args.projectID, context: context,
            editing: true, allowedNames: ChemistryEnvironmentJobAdapter.toolNames)
        guard location.record.kind.rawValue == "chemistry" else { throw PersonalContentError.invalidProject }
        let fileUse = try PersonalLibraryFileActions.acquireUse(id: location.record.id, directory: location.url)
        defer { fileUse.release() }
        let session = try await ChemistryProjectSession.open(id: location.record.id,
            directory: location.url, environment: environment)
        let output: ChemistryEnvironmentResult
        switch args.action {
        case .probe:
            guard context.toolCallID?.isEmpty == false else { throw FloeError.unauthorized }
            output = try await adapter.prepareProbe(projectID: args.projectID, root: location.url, context: context)
        case .prepare:
            guard context.toolCallID?.isEmpty == false else { throw FloeError.unauthorized }
            let options = try args.optionsJSON.map { try JSONDecoder().decode(FloeChemistryCore.JSONValue.self, from: Data($0.utf8)) } ?? .object([:])
            output = try await adapter.prepareRun(service: session.service, projectID: args.projectID,
                root: location.url, objectID: args.objectID!, expectedRevision: args.expectedObjectRevision!,
                method: args.method!, options: options, context: context)
        case .adopt:
            output = try await adapter.adopt(args.attemptID!, jobID: args.jobID!, service: session.service,
                projectID: args.projectID, root: location.url, context: context)
        case .status:
            output = try await adapter.status(args.attemptID!, service: session.service,
                projectID: args.projectID, root: location.url, context: context)
        case .cancel:
            output = try await adapter.cancelHandoff(args.attemptID!, service: session.service,
                projectID: args.projectID, root: location.url, context: context)
        }
        await session.refreshFromHost()
        await session.editor.refreshCapabilities()
        await adapter.refreshDisplayNames(session)
        return try StudioToolOutput.make(output)
    }
}

@MainActor func registerChemistryEnvironmentTool(environment: AppEnvironment,
                                               registry: ToolRunnerRegistry = .shared) {
    ToolCatalog.register(ChemistryEnvironmentTool.self)
    registry.register(ChemistryEnvironmentTool(environment: environment, adapter: environment.chemistryEnvironmentJobs))
}
#endif
