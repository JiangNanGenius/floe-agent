// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeChemistryCore
import FloeChemistryEngine

typealias ChemistryHostJSON = FloeChemistryCore.JSONValue

struct ChemistryHostEdit: Codable {
    enum Action: String, Codable { case importObject, replaceObject, editObject, addText, updateText, saveDocument, setEnvironment, restore }
    let action: Action
    var title: String?
    var kind: ChemicalKind?
    var format: String?
    var source: String?
    var deferPreparation: Bool?
    var objectID: UUID?
    var expectedObjectRevision: UInt64?
    var edits: ChemistryHostJSON?
    var text: String?
    var blockID: UUID?
    var expectedText: String?
    var blocks: [ChemistryBlock]?
    var environmentID: String?
    var historyRevision: UInt64?
    var historyDigest: String?
}
struct ChemistryNativeInput: Codable {
    var objectID: UUID?
    var runID: UUID?
    var expectedObjectRevision: UInt64?
    var method: String?
    var options: ChemistryHostJSON?
    var environmentID: String?
    var format: String?
    var offset: Int?
    var limit: Int?
    var resultKey: String?
    var expectedResultSHA256: String?
}
struct ChemistryRunReceipt: Encodable {
    let projectID: UUID
    let runID: UUID
    let objectID: UUID
    let inputRevision: UInt64
    let inputDigest: String
    let method: String
    let environmentID: String
    let engineVersion: String
    let status: ChemistryRunStatus
    let error: String?
    let result: ChemistryHostJSON
    let resultComplete: Bool
    let resultSHA256: String?
    let resultBytes: Int?
    let resultFields: [ChemistryResultData.Field]
    let openURL: String
    init(projectID: UUID, run: ChemistryRun) throws {
        self.projectID = projectID; runID = run.id; objectID = run.input.id; inputRevision = run.input.revision
        inputDigest = run.inputDigest; method = run.method; environmentID = run.environmentID
        engineVersion = run.engineVersion; status = run.status; error = run.error
        if let value = run.result {
            let snapshot = try ChemistryResultData.snapshot(value)
            result = snapshot.preview; resultComplete = snapshot.complete
            resultSHA256 = snapshot.sha256; resultBytes = snapshot.data.count; resultFields = snapshot.fields
        } else {
            result = .object([:]); resultComplete = false; resultSHA256 = nil; resultBytes = nil; resultFields = []
        }
        openURL = "floe://work/" + projectID.uuidString.lowercased()
    }
}
struct ChemistryStudioState: Encodable {
    let project: ChemistryProject
    let environments: [String: [String]]
    let nativeEngineVersion: String
}

extension ChemistryProjectSession {
    func applyAgentEdit(_ command: ChemistryHostEdit, expectedRevision: UInt64) async throws {
        try await requireReadyForAgentEdit(expectedRevision: expectedRevision)
        switch command.action {
        case .importObject:
            guard let title = command.title, let format = command.format, let source = command.source else { throw PersonalContentError.invalidProject }
            _ = try await service.importObject(projectID, title: title, kind: command.kind ?? .molecule,
                format: format, source: source, deferPreparation: command.deferPreparation ?? false)
        case .replaceObject:
            guard let objectID = command.objectID, let revision = command.expectedObjectRevision,
                  let format = command.format, let source = command.source else { throw PersonalContentError.invalidProject }
            _ = try await service.replaceObject(projectID, objectID: objectID, expectedObjectRevision: revision, format: format, source: source)
        case .editObject:
            guard let objectID = command.objectID, let revision = command.expectedObjectRevision, let edits = command.edits else { throw PersonalContentError.invalidProject }
            _ = try await service.editObject(projectID, objectID: objectID, expectedObjectRevision: revision, edits: edits)
        case .addText:
            guard let text = command.text else { throw PersonalContentError.invalidProject }
            _ = try await service.addText(projectID, text: text)
        case .updateText:
            guard let block = command.blockID, let expected = command.expectedText, let text = command.text else { throw PersonalContentError.invalidProject }
            _ = try await service.updateText(projectID, blockID: block, expectedText: expected, text: text)
        case .saveDocument:
            guard let blocks = command.blocks else { throw PersonalContentError.invalidProject }
            _ = try await service.saveDocument(projectID, blocks: blocks, expectedRevision: expectedRevision)
        case .setEnvironment:
            guard let environment = command.environmentID else { throw PersonalContentError.invalidProject }
            _ = try await service.setEnvironment(projectID, environmentID: environment)
        case .restore:
            let history = try await service.history(projectID)
            guard let revision = history.first(where: { $0.revision == command.historyRevision && $0.digest == command.historyDigest }) else { throw PersonalContentError.invalidProject }
            _ = try await service.restore(revision, expectedRevision: expectedRevision)
        }
        await refreshFromHost()
    }
    func nativeTool(action: String, inputJSON: String, context: ToolContext) async throws -> ToolExecutionOutput {
        guard !closing, inputJSON.utf8.count <= 256 * 1_024 else { throw PersonalContentError.invalidProject }
        let input = try JSONDecoder().decode(ChemistryNativeInput.self, from: Data(inputJSON.utf8))
        if action == "result" || (action == "export" && input.runID != nil) {
            let allowed: Set<String> = action == "result"
                ? ["runID", "resultKey", "offset", "limit", "expectedResultSHA256"]
                : ["runID", "resultKey", "format", "expectedResultSHA256"]
            guard let object = try JSONSerialization.jsonObject(with: Data(inputJSON.utf8)) as? [String: Any],
                  Set(object.keys).isSubset(of: allowed) else {
                throw FloeError.validationFailed("Use only this saved-result action's documented fields; no paths or environment overrides.")
            }
        }
        let project = try await service.project(projectID)
        switch action {
        case "capabilities":
            return try StudioToolOutput.make(ChemistryNativeCapabilities(projectID: projectID,
                defaultEnvironmentID: project.defaultEnvironmentID, environments: await service.capabilities(),
                nativeEngineVersion: NativeChemistryBackend().engineVersion))
        case "history":
            let offset = input.offset ?? 0, limit = input.limit ?? 50
            guard offset >= 0, (1...200).contains(limit) else { throw PersonalContentError.invalidProject }
            let history = try await service.history(projectID)
            guard offset <= history.count else { throw PersonalContentError.invalidProject }
            return try StudioToolOutput.make(ChemistryHistoryPage(projectID: projectID,
                revisions: Array(history.dropFirst(offset).prefix(limit)), nextOffset: offset + limit < history.count ? offset + limit : nil))
        case "calculate":
            try await requireReadyForAgentEdit()
            guard let objectID = input.objectID, let expected = input.expectedObjectRevision,
                  project.objects.first(where: { $0.id == objectID })?.revision == expected,
                  let method = input.method, NativeChemistryBackend().methods.contains(method) else { throw PersonalContentError.changedDocument }
            let executionEnvironment = input.environmentID ?? project.defaultEnvironmentID
            guard executionEnvironment == "native.local" else {
                throw FloeError.validationFailed("This tool runs fixed on-device chemistry. Use the configured environment adapter and real jobs.submit for external methods.")
            }
            try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
            let scoped = ChemistryToolSession(taskID: context.runID, service: service, authorizedProjectIDs: [projectID], canCreate: false)
            let started = try await scoped.invoke(name: "chemistry.run.start", arguments: .object([
                "projectID": .string(projectID.uuidString), "objectID": .string(objectID.uuidString),
                "method": .string(method), "options": input.options ?? .object([:]),
                "environmentID": .string(executionEnvironment)]))
            guard let text = started["runID"]?.string, let runID = UUID(uuidString: text) else { throw PersonalContentError.invalidProject }
            do { try recordOwner(runID: runID, context: context, environmentID: executionEnvironment) }
            catch { try? await service.cancel(projectID, runID: runID); _ = try? await service.wait(projectID, runID: runID); throw error }
            let cancellation = Task { [service, projectID] in
                while !Task.isCancelled {
                    if context.cancellation.isCancelled { try? await service.cancel(projectID, runID: runID); return }
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                }
            }
            defer { cancellation.cancel() }
            let run = try await withTaskCancellationHandler {
                try await service.wait(projectID, runID: runID)
            } onCancel: { [service, projectID] in Task { try? await service.cancel(projectID, runID: runID) } }
            try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
            await refreshFromHost()
            let receipt = try StudioToolOutput.data(try ChemistryRunReceipt(projectID: projectID, run: run))
            guard receipt.count <= 96 * 1_024 else { throw PersonalContentError.invalidProject }
            return .init(summary: String(decoding: receipt, as: UTF8.self), fullOutputSHA256: StudioToolOutput.hash(receipt),
                         exitStatus: run.status == .succeeded ? 0 : 1)
        case "status", "cancel":
            guard let runID = input.runID, project.runs.contains(where: { $0.id == runID }) else { throw PersonalContentError.invalidProject }
            if action == "cancel" { try await service.cancel(projectID, runID: runID); _ = try await service.wait(projectID, runID: runID) }
            guard let run = try await service.project(projectID).runs.first(where: { $0.id == runID }) else { throw PersonalContentError.invalidProject }
            await refreshFromHost()
            return try StudioToolOutput.make(try ChemistryRunReceipt(projectID: projectID, run: run))
        case "result":
            guard let runID = input.runID, let run = project.runs.first(where: { $0.id == runID }),
                  run.status == .succeeded, let value = run.result else { throw PersonalContentError.invalidProject }
            let page = try ChemistryResultData.page(value, resultKey: input.resultKey, offset: input.offset ?? 0,
                limit: input.limit ?? 200, expectedSHA256: input.expectedResultSHA256,
                checkCancellation: { try context.cancellation.throwIfCancelled(); try Task.checkCancellation() })
            return try StudioToolOutput.make(ChemistryResultPageReceipt(projectID: projectID, run: run, page: page, owner: savedRunOwner(run.id)))
        case "apply":
            try await requireReadyForAgentEdit()
            guard let runID = input.runID, let revision = input.expectedObjectRevision else { throw PersonalContentError.invalidProject }
            let object = try await service.apply(projectID, runID: runID, expectedObjectRevision: revision)
            await refreshFromHost()
            return try StudioToolOutput.make(ChemistryObjectReceipt(projectID: projectID, objectID: object.id, revision: object.revision, format: object.format))
        case "export":
            if let runID = input.runID {
                guard input.objectID == nil, let run = project.runs.first(where: { $0.id == runID }) else { throw PersonalContentError.invalidProject }
                return try await exportSavedResult(run, input: input, context: context)
            }
            guard let objectID = input.objectID, let format = input.format,
                  format.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$", options: .regularExpression) != nil else { throw PersonalContentError.invalidProject }
            let source = try await service.export(projectID, objectID: objectID, format: format)
            let bytes = Data(source.utf8)
            guard !bytes.isEmpty, bytes.count <= 64 * 1_024 * 1_024 else { throw PersonalContentError.invalidProject }
            let exports = root.appendingPathComponent("Exports", isDirectory: true)
            guard exports.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw PersonalContentError.outsideLibrary }
            try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
            let file = exports.appendingPathComponent("chemical-" + UUID().uuidString.lowercased()).appendingPathExtension(format.lowercased())
            try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
            try bytes.write(to: file, options: .atomic)
            return try StudioToolOutput.make(ChemistryExportReceipt(projectID: projectID, fileName: file.lastPathComponent,
                bytes: bytes.count, sha256: ChemistryProjectStore.digest(bytes), openURL: "floe://work/" + projectID.uuidString.lowercased()))
        default: throw PersonalContentError.invalidProject
        }
    }
}

struct ChemistryNativeCapabilities: Encodable {
    let projectID: UUID
    let defaultEnvironmentID: String
    let environments: [String: [String]]
    let nativeEngineVersion: String
}
struct ChemistryHistoryPage: Encodable { let projectID: UUID; let revisions: [ChemistryRevision]; let nextOffset: Int? }
struct ChemistryObjectReceipt: Encodable { let projectID: UUID; let objectID: UUID; let revision: UInt64; let format: String }
struct ChemistryExportReceipt: Encodable { let projectID: UUID; let fileName: String; let bytes: Int; let sha256: String; let openURL: String }

struct StudioChemistryTool: AgentTool {
    struct Arguments: Decodable, Sendable { let projectID: UUID; let action: String; let inputJSON: String? }
    static let name = "studio.chemistry"
    static let toolDescription = "Use the actual chemistry original and fixed on-device engine. Read studio.read first for project/object revisions and methods. actions: capabilities, history, calculate, status, result, cancel, apply, export. calculate inputJSON requires objectID, expectedObjectRevision, method, optional options/environmentID (native.local only). status/cancel use runID. calculate/status include complete small results or explicit resultComplete=false plus resultFields/resultSHA256; result reads runID+optional exact resultKey/offset/limit (1...1000), with expectedResultSHA256 required for continuation. apply uses runID+expectedObjectRevision and refuses stale structures. export uses objectID+format for the original, or runID+format=json for the complete saved successful result, or runID+format=csv+resultKey for a real numeric table and a provenance sidecar. Result exports return verified run-owned outputFiles; no strings/nested CSV coercion or new calculation. Failed/cancelled calculations retain their actual status and never masquerade as success. External jobs are handled by the separately configured environment adapter, never by this tool."
    static let parametersJSON = #"{"type":"object","properties":{"projectID":{"type":"string","format":"uuid"},"action":{"type":"string","enum":["capabilities","history","calculate","status","result","cancel","apply","export"]},"inputJSON":{"type":"string","maxLength":262144}},"required":["projectID","action"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let coordinator: StudioCoordinator
    func validate(_ args: Arguments) throws {
        guard ["capabilities", "history", "calculate", "status", "result", "cancel", "apply", "export"].contains(args.action),
              (args.inputJSON?.utf8.count ?? 0) <= 256 * 1_024 else { throw PersonalContentError.invalidProject }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await coordinator.chemistry(id: args.projectID, action: args.action, inputJSON: args.inputJSON ?? "{}", context: context)
    }
}

@MainActor func registerChemistryAgentTools(environment: AppEnvironment, registry: ToolRunnerRegistry = .shared) {
    ToolCatalog.register(StudioChemistryTool.self)
    registry.register(StudioChemistryTool(coordinator: environment.studioCoordinator))
}
#endif
