// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeEnvironments
import FloeExecution
import FloeTools
import FloeCanvasCore
import FloeChemistryCore
import FloeChemistryEngine

nonisolated struct ChemistryWorkerAttempt: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case probe, calculation }
    enum State: String, Codable, Sendable {
        case awaitingSubmission, submissionUnknown, running, cancelling, transferPending, succeeded, failed, cancelled, interrupted
        var terminal: Bool { [.succeeded, .failed, .cancelled, .interrupted].contains(self) }
    }
    let id: UUID
    let kind: Kind
    let projectID: UUID
    let chemistryRunID: UUID?
    let owner: ChemistryExecutionOwner
    let environmentID: String
    let bindingGeneration: Int64
    let runtimeGeneration: String?
    let workspaceRootPath: String
    let allowedWorkspacePaths: [String]
    let relativeDirectory: String
    let configurationDigest: String
    let inputSHA256: String
    let manifestSHA256: String
    let shellPayload: Data
    let nativeIntent: Bool
    var jobID: UUID?
    var state: State = .awaitingSubmission
    var error: String?
    var responseSHA256: String?
    var createdAt = Date()
    var updatedAt = Date()
}

/// What file deletion must do about one saved worker attempt. Decided from
/// the durable job store and the run record alone — never from the
/// historical execution context, whose binding may have expired long ago.
enum ChemistryDeletionStopPlan: Equatable, Sendable {
    /// Terminal attempts keep their record and need no action.
    case skip
    /// A completed processor still owes reconciled result files.
    case reconcileFirst
    /// No live job: record the reconciled cancellation and keep deleting.
    case reconcileStale
    /// The native UI's own live job: really stop it, then keep deleting.
    case stopOwnedJob
    /// An assistant-owned live job still belongs to its execution task.
    case refuseLiveForeignJob
    /// An assistant-owned attempt whose submit may still be in flight.
    case refuseUnfinishedSubmit
}

extension ChemistryWorkerAttempt {
    /// `hasLiveJob` comes from the durable jobs store; `owningRunEnded` is
    /// read straight from the run record. Local file-manager authority is
    /// separated from historical model-run lifetime, with no bypass of live
    /// worker ownership or stop proof.
    func deletionStopPlan(hasLiveJob: Bool, owningRunEnded: Bool) -> ChemistryDeletionStopPlan {
        if state.terminal { return .skip }
        if state == .transferPending { return .reconcileFirst }
        if hasLiveJob { return nativeIntent ? .stopOwnedJob : .refuseLiveForeignJob }
        if nativeIntent { return .reconcileStale }
        return owningRunEnded ? .reconcileStale : .refuseUnfinishedSubmit
    }
}

nonisolated struct ChemistryWorkerManifest: Codable, Sendable {
    var schema = "floe.chemistry.transport.v1"
    let kind: ChemistryWorkerAttempt.Kind
    let attemptID: UUID
    let projectID: UUID
    let taskID: UUID
    let hostRunID: UUID
    let environmentID: String
    let inputSHA256: String
    let configurationDigest: String
    let sourceDigests: [String: String]
}

nonisolated struct ChemistryWorkerReceipt: Decodable, Sendable {
    let schema: String
    let attemptID: UUID
    let projectID: UUID
    let taskID: UUID
    let hostRunID: UUID
    let environmentID: String
    let inputSHA256: String
    let configurationDigest: String
    let manifestSHA256: String
    let responseSHA256: String
    let responseBytes: Int
    let workerExitCode: Int
    let complete: Bool
}

nonisolated struct ChemistryJobsSubmitArguments: Encodable, Sendable {
    let tool = "exec.shell"
    let arguments: String
    let purpose: String
    let wait = true
}

nonisolated struct ChemistryWorkerJobHandoff: Encodable, Sendable {
    let tool: String
    let arguments: String
}

nonisolated struct ChemistryEnvironmentResult: Encodable, Sendable {
    let attemptID: UUID
    let projectID: UUID
    let chemistryRunID: UUID?
    let environmentID: String
    let state: ChemistryWorkerAttempt.State
    let jobID: UUID?
    let error: String?
    var methods: [String]?
    var engines: [String: String]?
    var unavailable: [String: String]?
    var pendingJobs: [ChemistryWorkerJobHandoff] = []
    var followUp: String?
}

/// Existing durable run metadata only. This prevents a native UI completion
/// from being injected as an unsolicited AI turn; it grants no permissions.
nonisolated struct ChemistryNativeRunMetadata: Codable, Sendable {
    var activity = "chemistryWorker"
    var version = 1
    var source = NativeJobSubmissionSource.nativeService
    let runID: UUID
    let conversationID: UUID
    let projectID: UUID
    let targetTool = "exec.shell"
    func payloadJSON() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
    static func matches(_ event: RunEventRecord, runID: UUID, conversationID: UUID, targetTool: String) -> Bool {
        guard event.kind == .status, event.runID == runID, targetTool == "exec.shell",
              let value = try? JSONDecoder().decode(Self.self, from: Data(event.payloadJSON.utf8)) else { return false }
        return value.activity == "chemistryWorker" && value.version == 1 && value.source == .nativeService
            && value.runID == runID && value.conversationID == conversationID
    }
}

/// One App-owned transport service. Core owns chemistry inputs/results. The
/// existing jobs service owns processors, cancellation and terminal state.
/// Nothing here invokes a host interpreter or submits an AI job implicitly.
@MainActor final class ChemistryEnvironmentJobAdapter {
    static let toolNames: Set<String> = ["studio.chemistry.environment"]
    private weak var environment: AppEnvironment?
    private let configuration: @MainActor (String) throws -> ChemistryWorkerConfiguration
    private var workers: [UUID: Task<Void, Never>] = [:]
    // A worker lease outlives submission. Deletion joins nativeSubmissions,
    // then stops the genuine job and joins its monitor before removing files.
    var nativeLeases: [UUID: WorkspaceCenter.TaskRootLease] = [:]
    let nativeSubmissions = ChemistrySubmissionTracker()
    private var preparing: Set<String> = []

    init(environment: AppEnvironment,
         configuration: @escaping @MainActor (String) throws -> ChemistryWorkerConfiguration = { _ in try .bundled() }) {
        self.environment = environment; self.configuration = configuration
    }
    private func app() throws -> AppEnvironment {
        guard let environment else { throw PersonalContentError.storageUnavailable }; return environment
    }
    private func jobs() throws -> BackgroundJobService {
        guard let value = try app().backgroundJobService else {
            throw FloeError.validationFailed("Background jobs are unavailable")
        }
        return value
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private func journal(_ projectRoot: URL) throws -> URL {
        let root = ChemistryWorkerFiles.canonical(projectRoot)
        let result = try ChemistryWorkerFiles.child("ChemistryJobs", root: root)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        guard try ChemistryWorkerFiles.child("ChemistryJobs", root: root).path == result.path else { throw FloeError.unauthorized }
        return result
    }
    private func save(_ attempt: ChemistryWorkerAttempt, root: URL) throws {
        var value = attempt; value.updatedAt = Date()
        try ChemistryWorkerFiles.write(try encode(value), path: value.id.uuidString + "/attempt.json",
                                       root: journal(root), limit: 256 * 1024)
    }
    func attempt(_ id: UUID, projectID: UUID, root: URL, context: ToolContext) throws -> ChemistryWorkerAttempt {
        let path = try ChemistryWorkerFiles.child(id.uuidString + "/attempt.json", root: journal(root))
        let value = try JSONDecoder().decode(ChemistryWorkerAttempt.self,
                                            from: ChemistryWorkerFiles.read(path, limit: 256 * 1024))
        guard value.id == id, value.projectID == projectID, value.owner.taskID == context.conversationID,
              value.environmentID == context.environmentID,
              value.workspaceRootPath == context.workspaceRootURL.map(ChemistryWorkerFiles.canonical)?.path,
              context.executionBindingGeneration == nil || context.executionBindingGeneration == value.bindingGeneration else {
            throw FloeError.unauthorized
        }
        try context.authorizeWorkspacePath(value.relativeDirectory)
        return value
    }

    /// Validate the actual registry + durable pin + routing lease. The caller
    /// cannot replace this with a label from model arguments or a source file.
    private func binding(_ context: ToolContext) async throws -> TaskExecutionBinding {
        try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
        let environment = try app()
        // Same-task parity for canonical children: the durable run→task
        // pairing, execution-binding pin, generation and backend identity
        // below come from the runtime-issued context and registry, which the
        // parent already validated per call.
        guard !context.temporaryReadOnly, !context.publicWebOnly,
              let taskID = context.conversationID, let id = context.environmentID,
              context.workspaceRootURL != nil,
              let run = try await environment.runStore.run(id: context.runID), run.conversationID == taskID,
              let pin = run.executionBinding, pin.conversationID == taskID, pin.target.environmentID == id,
              context.executionBindingGeneration == nil || pin.generation == context.executionBindingGeneration else {
            throw FloeError.validationFailed("Use this saved task's resolved execution environment")
        }
        try await environment.environmentRegistry.prepare()
        guard let record = await environment.environmentRegistry.record(id: id), record.state == .active,
              record.effectiveExecutionBackend.rawValue == pin.target.backend.rawValue else {
            throw FloeError.validationFailed("The selected execution environment is unavailable")
        }
        let lease = try await ToolEnvironmentRouting.shared.acquire(context)
        let routed = lease.context
        await lease.finish()
        guard routed.environmentID == id,
              routed.environment?.variables["FLOE_EXECUTION_BACKEND"] == pin.target.backend.rawValue else {
            throw FloeError.unauthorized
        }
        return pin
    }
    private func requireExecutionCeiling(_ context: ToolContext) throws {
        for name in ["jobs.submit", "exec.shell"] {
            guard context.allowedToolNames?.contains(name) != false,
                  context.frozenEffectiveCatalogNames?.contains(name) != false else {
                throw FloeError.validationFailed("This task does not offer the required background execution tools")
            }
        }
    }
    private func operationKey(_ context: ToolContext, kind: String) -> String {
        FloeDigest.sha256Hex(Data((context.runID.uuidString + ":" + (context.toolCallID ?? UUID().uuidString) + ":" + kind).utf8))
    }
    private nonisolated struct Pointer: Codable { let attemptID: UUID; let inputDigest: String }
    private func existing(key: String, digest: String, projectID: UUID, root: URL,
                          context: ToolContext) throws -> ChemistryWorkerAttempt? {
        let path = try ChemistryWorkerFiles.child("Calls/" + key + ".json", root: journal(root))
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let pointer = try JSONDecoder().decode(Pointer.self, from: ChemistryWorkerFiles.read(path, limit: 2048))
        guard pointer.inputDigest == digest else { throw FloeError.validationFailed("This approved call already prepared a different request") }
        return try attempt(pointer.attemptID, projectID: projectID, root: root, context: context)
    }
    private func point(key: String, digest: String, attempt: ChemistryWorkerAttempt, root: URL) throws {
        try ChemistryWorkerFiles.write(try encode(Pointer(attemptID: attempt.id, inputDigest: digest)),
            path: "Calls/" + key + ".json", root: journal(root), limit: 2048)
    }

    func prepareProbe(projectID: UUID, root: URL, context: ToolContext,
                      nativeIntent: Bool = false) async throws -> ChemistryEnvironmentResult {
        if !nativeIntent { try requireExecutionCeiling(context) }
        let pin = try await binding(context), config = try configuration(pin.target.environmentID)
        let key = operationKey(context, kind: "probe"), digest = config.fingerprint
        if let old = try existing(key: key, digest: digest, projectID: projectID, root: root, context: context) {
            return try result(old)
        }
        guard preparing.insert(key).inserted else { throw FloeError.validationFailed("This request is already preparing") }
        defer { preparing.remove(key) }
        let request = try encode(ChemistryRequest(operation: "capabilities", format: "", data: ""))
        let value = try stage(id: UUID(), kind: .probe, projectID: projectID, runID: nil, request: request,
            root: root, context: context, pin: pin, config: config, nativeIntent: nativeIntent)
        try point(key: key, digest: digest, attempt: value, root: root)
        return try result(value)
    }

    func prepareRun(service: ChemistryService, projectID: UUID, root: URL, objectID: UUID,
                    expectedRevision: UInt64, method: String, options: FloeChemistryCore.JSONValue,
                    context: ToolContext, nativeIntent: Bool = false) async throws -> ChemistryEnvironmentResult {
        if !nativeIntent { try requireExecutionCeiling(context) }
        let pin = try await binding(context), config = try configuration(pin.target.environmentID)
        let inputKey = try encode(PrepareInput(objectID: objectID, expectedRevision: expectedRevision, method: method, options: options))
        let digest = FloeDigest.sha256Hex(inputKey), key = operationKey(context, kind: "calculation")
        if let old = try existing(key: key, digest: digest, projectID: projectID, root: root, context: context) {
            return try result(old)
        }
        guard preparing.insert(key).inserted else { throw FloeError.validationFailed("This request is already preparing") }
        defer { preparing.remove(key) }
        try await restoreProbe(service: service, projectID: projectID, root: root, pin: pin, config: config, context: context)
        let before = try await service.project(projectID)
        guard before.objects.first(where: { $0.id == objectID })?.revision == expectedRevision else {
            throw FloeError.validationFailed("The structure changed; read it again before computing")
        }
        let owner = ChemistryExecutionOwner(taskID: pin.conversationID, hostRunID: context.runID)
        let prepared = try await service.prepareExternal(projectID, objectID: objectID, method: method,
            options: options, environmentID: pin.target.environmentID, owner: owner)
        do {
            guard prepared.identity.objectRevision == expectedRevision else {
                throw FloeError.validationFailed("The structure changed before preparation completed")
            }
            let value = try stage(id: prepared.identity.attemptID, kind: .calculation, projectID: projectID,
                runID: prepared.runID, request: prepared.requestData(), root: root, context: context,
                pin: pin, config: config, nativeIntent: nativeIntent)
            try point(key: key, digest: digest, attempt: value, root: root)
            return try result(value)
        } catch {
            _ = try? await service.terminateExternal(projectID, runID: prepared.runID, owner: owner,
                jobID: nil, status: .interrupted, error: String(error.localizedDescription.prefix(8000)))
            throw error
        }
    }
    private nonisolated struct PrepareInput: Encodable { let objectID: UUID; let expectedRevision: UInt64; let method: String; let options: FloeChemistryCore.JSONValue }

    private func stage(id: UUID, kind: ChemistryWorkerAttempt.Kind, projectID: UUID, runID: UUID?, request: Data,
                       root: URL, context: ToolContext, pin: TaskExecutionBinding,
                       config: ChemistryWorkerConfiguration, nativeIntent: Bool) throws -> ChemistryWorkerAttempt {
        guard let workspace = context.workspaceRootURL, request.count <= 16 * 1024 * 1024 else { throw FloeError.unauthorized }
        let relative = ".floe-chemistry/" + id.uuidString
        try context.authorizeWorkspacePath(relative)
        let directory = try ChemistryWorkerFiles.child(relative, root: workspace)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw FloeError.validationFailed("This calculation already has staged files; reconcile its original attempt")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let inputDigest = FloeDigest.sha256Hex(request)
        let manifest = ChemistryWorkerManifest(kind: kind, attemptID: id, projectID: projectID,
            taskID: pin.conversationID, hostRunID: context.runID, environmentID: pin.target.environmentID,
            inputSHA256: inputDigest, configurationDigest: config.fingerprint, sourceDigests: config.sourceDigests)
        let manifestBytes = try encode(manifest), manifestDigest = FloeDigest.sha256Hex(manifestBytes)
        for (name, bytes) in config.sources {
            try ChemistryWorkerFiles.write(bytes, path: name, root: directory, limit: 2 * 1024 * 1024)
        }
        try ChemistryWorkerFiles.write(Data(ChemistryWorkerResources.transport.utf8), path: "transport.py", root: directory, limit: 128 * 1024)
        try ChemistryWorkerFiles.write(request, path: "request.json", root: directory, limit: 16 * 1024 * 1024)
        try ChemistryWorkerFiles.write(manifestBytes, path: "manifest.json", root: directory, limit: 64 * 1024)
        let command = ChemistryWorkerResources.command(configuration: config, relativeDirectory: relative, manifestDigest: manifestDigest)
        let payload = try encode(LocalShellTool.Arguments(command: command, cwd: ".", maxOutputBytes: 32 * 1024))
        let value = ChemistryWorkerAttempt(id: id, kind: kind, projectID: projectID, chemistryRunID: runID,
            owner: .init(taskID: pin.conversationID, hostRunID: context.runID), environmentID: pin.target.environmentID,
            bindingGeneration: pin.generation, runtimeGeneration: pin.target.runtimeGeneration,
            workspaceRootPath: ChemistryWorkerFiles.canonical(workspace).path, allowedWorkspacePaths: context.allowedWorkspacePaths,
            relativeDirectory: relative, configurationDigest: config.fingerprint, inputSHA256: inputDigest,
            manifestSHA256: manifestDigest, shellPayload: payload, nativeIntent: nativeIntent)
        // Durable project-owned recovery survives task work-directory cleanup.
        let archive = try journal(root)
        try ChemistryWorkerFiles.write(request, path: id.uuidString + "/request.json", root: archive, limit: 16 * 1024 * 1024)
        try ChemistryWorkerFiles.write(manifestBytes, path: id.uuidString + "/manifest.json", root: archive, limit: 64 * 1024)
        try save(value, root: root)
        return value
    }

    private func verifiedJob(_ value: ChemistryWorkerAttempt, jobID: UUID) async throws -> BackgroundJob {
        let job = try await jobs().ownedJob(id: jobID, runID: value.owner.hostRunID)
        guard value.jobID == nil || value.jobID == jobID,
              job.id == jobID, job.kind == .tool, job.runID == value.owner.hostRunID,
              job.conversationID == value.owner.taskID, job.environmentID == value.environmentID,
              job.targetTool == "exec.shell", job.workspaceRootPath.map({ ChemistryWorkerFiles.canonical(URL(fileURLWithPath: $0)).path }) == value.workspaceRootPath,
              try JSONFidelity.parse(job.payloadJSON) == JSONFidelity.parse(value.shellPayload) else {
            throw FloeError.validationFailed("The job receipt does not match this exact task, environment and frozen calculation")
        }
        return job
    }

    /// Recovery resolves an exact unique receipt from the original durable
    /// run. It never chooses the first job or scans another task's records.
    private func discoverOriginalJob(_ value: ChemistryWorkerAttempt) async throws -> BackgroundJob? {
        let store = BackgroundJobStore(database: try app().database)
        let rows = try await store.jobs(runID: value.owner.hostRunID, limit: 200)
        guard rows.count < 200 else {
            throw FloeError.validationFailed("Provide this calculation's genuine jobID to reconcile its original receipt")
        }
        let exact = try rows.filter { job in
            guard job.runID == value.owner.hostRunID, job.conversationID == value.owner.taskID,
                  job.environmentID == value.environmentID, job.targetTool == "exec.shell" else { return false }
            return try JSONFidelity.parse(job.payloadJSON) == JSONFidelity.parse(value.shellPayload)
        }
        guard exact.count <= 1 else { throw FloeError.validationFailed("Multiple actual jobs have this payload. Inspect their receipts; the host will not choose or replay one.") }
        guard let found = exact.first else { return nil }
        return try await verifiedJob(value, jobID: found.id)
    }

    func adopt(_ id: UUID, jobID: UUID, service: ChemistryService, projectID: UUID,
               root: URL, context: ToolContext) async throws -> ChemistryEnvironmentResult {
        var value = try attempt(id, projectID: projectID, root: root, context: context)
        let job = try await verifiedJob(value, jobID: jobID)
        if let runID = value.chemistryRunID {
            let prepared = try await service.preparedExternal(projectID, runID: runID, owner: value.owner)
            guard FloeDigest.sha256Hex(try prepared.requestData()) == value.inputSHA256,
                  prepared.identity.attemptID == value.id else { throw FloeError.unauthorized }
            _ = try await service.adoptExternal(projectID, runID: runID, owner: value.owner, attemptID: id, jobID: jobID)
        }
        value.jobID = job.id
        if !value.state.terminal { value.state = .running }
        try save(value, root: root)
        return try await reconcile(value, service: service, root: root)
    }

    func status(_ id: UUID, service: ChemistryService, projectID: UUID,
                root: URL, context: ToolContext) async throws -> ChemistryEnvironmentResult {
        let value = try attempt(id, projectID: projectID, root: root, context: context)
        return try await reconcile(value, service: service, root: root)
    }

    private func reconcile(_ original: ChemistryWorkerAttempt, service: ChemistryService, root: URL) async throws -> ChemistryEnvironmentResult {
        var value = original
        if value.jobID == nil, !value.state.terminal, let recovered = try await discoverOriginalJob(value) {
            value.jobID = recovered.id; value.state = .running; try save(value, root: root)
        }
        guard let jobID = value.jobID else { return try result(value) }
        let job = try await verifiedJob(value, jobID: jobID)
        if let runID = value.chemistryRunID {
            let prepared = try await service.preparedExternal(value.projectID, runID: runID, owner: value.owner)
            guard prepared.identity.attemptID == value.id,
                  FloeDigest.sha256Hex(try prepared.requestData()) == value.inputSHA256 else { throw FloeError.unauthorized }
            // Recover the native submit -> receipt-save -> Core-adopt window.
            // This adopts the same verified original job and never submits it.
            _ = try await service.adoptExternal(value.projectID, runID: runID, owner: value.owner,
                attemptID: value.id, jobID: job.id)
        }
        guard job.state.isTerminal else {
            if value.state != .cancelling { value.state = .running }
            try save(value, root: root); return try result(value)
        }
        if value.state.terminal {
            var output = try result(value)
            if value.kind == .probe, value.state == .succeeded {
                let capabilities = try ChemistryWorkerCapabilities.decode(verifiedResponse(value, root: root, job: job))
                try await service.registerExternalWorker(environmentID: value.environmentID, capabilities: capabilities)
                output.methods = capabilities.methods.sorted(); output.engines = capabilities.engines
                output.unavailable = capabilities.unavailable.mapValues { String($0.prefix(1000)) }
            }
            return output
        }
        if job.state != .completed {
            let status: ChemistryRunStatus = job.state == .cancelled ? .cancelled : job.state == .interrupted ? .interrupted : .failed
            let message = String((job.lastError ?? "The background job did not complete. Inspect its saved output before retrying.").prefix(8000))
            if let runID = value.chemistryRunID {
                _ = try await service.terminateExternal(value.projectID, runID: runID, owner: value.owner,
                    jobID: job.id, status: status, error: message)
            }
            value.state = status == .cancelled ? .cancelled : status == .interrupted ? .interrupted : .failed
            value.error = message; try save(value, root: root)
            return try result(value)
        }
        let response: Data
        do { response = try verifiedResponse(value, root: root, job: job) }
        catch {
            // A completed processor with missing/changed transfer files may
            // still be recoverable. Keep its genuine job and never resubmit.
            value.state = .transferPending; value.error = String(error.localizedDescription.prefix(8000))
            try save(value, root: root); return try result(value)
        }
        do {
            value.responseSHA256 = FloeDigest.sha256Hex(response)
            if value.kind == .probe {
                let capabilities = try ChemistryWorkerCapabilities.decode(response)
                try await service.registerExternalWorker(environmentID: value.environmentID, capabilities: capabilities)
                value.state = .succeeded; value.error = nil
                try save(value, root: root)
                let pointer = ProbePointer(attemptID: value.id, configurationDigest: value.configurationDigest,
                    generation: value.bindingGeneration, runtimeGeneration: value.runtimeGeneration)
                try ChemistryWorkerFiles.write(try encode(pointer), path: probePath(value.environmentID), root: journal(root), limit: 4096)
                NotificationCenter.default.post(name: .floeStudioDocumentDidChange, object: value.projectID)
                var output = try result(value)
                output.methods = capabilities.methods.sorted(); output.engines = capabilities.engines
                output.unavailable = capabilities.unavailable.mapValues { String($0.prefix(1000)) }
                return output
            }
            guard let runID = value.chemistryRunID else { throw FloeError.unauthorized }
            let run = try await service.finishExternal(value.projectID, runID: runID, owner: value.owner, jobID: job.id, response: response)
            value.state = run.status == .succeeded ? .succeeded : run.status == .cancelled ? .cancelled : .failed
            value.error = run.error; try save(value, root: root)
            NotificationCenter.default.post(name: .floeStudioDocumentDidChange, object: value.projectID)
            return try result(value)
        } catch {
            // A complete but invalid bound response is a real failure, not a
            // missing transfer and never a successful calculation.
            let message = String(error.localizedDescription.prefix(8000))
            if let runID = value.chemistryRunID {
                _ = try await service.terminateExternal(value.projectID, runID: runID, owner: value.owner,
                    jobID: job.id, status: .failed, error: message)
            }
            value.state = .failed; value.error = message
            try save(value, root: root); return try result(value)
        }
    }

    private nonisolated struct Acknowledgement: Decodable {
        let chemistryTransport: String; let attemptID: UUID; let receiptSHA256: String
    }
    private func acknowledgedReceipt(_ job: BackgroundJob, attemptID: UUID) throws -> String {
        guard job.state == .completed, let path = job.outputPath,
              BackgroundJobOutputSpool.isCanonicalArtifactPath(path, jobID: job.id),
              let metadata = BackgroundJobOutputSpool.readMetadata(path: path, jobID: job.id),
              metadata.captureIntegrityKnown, !metadata.truncated, !metadata.captureTruncated,
              metadata.savedBytes >= 0, metadata.savedBytes <= BackgroundJobOutputSpool.maximumArtifactBytes else {
            throw FloeError.validationFailed("The background job has no complete verifiable transport receipt")
        }
        let bytes = try ChemistryWorkerFiles.read(URL(fileURLWithPath: path), limit: BackgroundJobOutputSpool.maximumArtifactBytes + 1024)
        guard bytes.count == job.outputBytes, bytes.count >= metadata.savedBytes else { throw FloeError.unauthorized }
        let payload = Data(bytes.prefix(metadata.savedBytes))
        guard FloeDigest.sha256Hex(payload) == job.resultDigest,
              let text = String(data: payload, encoding: .utf8), let start = text.range(of: "\n--- stdout ---\n") else {
            throw FloeError.validationFailed("The saved job output changed or is incomplete")
        }
        let suffix = String(text[start.upperBound...])
        let stdout = (suffix.components(separatedBy: "\n--- stderr ---\n").first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let acknowledgement = try JSONDecoder().decode(Acknowledgement.self, from: Data(stdout.utf8))
        guard acknowledgement.chemistryTransport == "complete", acknowledgement.attemptID == attemptID,
              acknowledgement.receiptSHA256.count == 64 else { throw FloeError.unauthorized }
        return acknowledgement.receiptSHA256
    }

    private func verifiedResponse(_ value: ChemistryWorkerAttempt, root: URL, job: BackgroundJob) throws -> Data {
        let acknowledgedSHA = try acknowledgedReceipt(job, attemptID: value.id)
        let archive = try journal(root), prefix = value.id.uuidString + "/"
        let archivedResponse = try ChemistryWorkerFiles.child(prefix + "response.json", root: archive)
        let archivedReceipt = try ChemistryWorkerFiles.child(prefix + "transportReceipt.json", root: archive)
        let workspace = URL(fileURLWithPath: value.workspaceRootPath, isDirectory: true)
        let usingArchive = FileManager.default.fileExists(atPath: archivedResponse.path) && FileManager.default.fileExists(atPath: archivedReceipt.path)
        let receiptURL = usingArchive ? archivedReceipt : try ChemistryWorkerFiles.child(value.relativeDirectory + "/transportReceipt.json", root: workspace)
        let responseURL = usingArchive ? archivedResponse : try ChemistryWorkerFiles.child(value.relativeDirectory + "/response.json", root: workspace)
        let receiptData = try ChemistryWorkerFiles.read(receiptURL, limit: 16 * 1024)
        guard FloeDigest.sha256Hex(receiptData) == acknowledgedSHA else {
            throw FloeError.validationFailed("The result receipt does not match the original job's saved output")
        }
        let receipt = try JSONDecoder().decode(ChemistryWorkerReceipt.self, from: receiptData)
        guard receipt.schema == "floe.chemistry.transport-receipt.v1", receipt.complete,
              receipt.attemptID == value.id, receipt.projectID == value.projectID,
              receipt.taskID == value.owner.taskID, receipt.hostRunID == value.owner.hostRunID,
              receipt.environmentID == value.environmentID, receipt.inputSHA256 == value.inputSHA256,
              receipt.configurationDigest == value.configurationDigest, receipt.manifestSHA256 == value.manifestSHA256,
              (1...64 * 1024 * 1024).contains(receipt.responseBytes) else { throw FloeError.unauthorized }
        let response = try ChemistryWorkerFiles.read(responseURL, limit: value.kind == .probe ? 1024 * 1024 : 64 * 1024 * 1024)
        guard response.count == receipt.responseBytes, FloeDigest.sha256Hex(response) == receipt.responseSHA256 else {
            throw FloeError.validationFailed("The saved chemistry result is incomplete or its checksum changed")
        }
        if !usingArchive {
            try ChemistryWorkerFiles.write(response, path: prefix + "response.json", root: archive, limit: 64 * 1024 * 1024)
            try ChemistryWorkerFiles.write(receiptData, path: prefix + "transportReceipt.json", root: archive, limit: 16 * 1024)
        }
        return response
    }

    private nonisolated struct ProbePointer: Codable { let attemptID: UUID; let configurationDigest: String; let generation: Int64; let runtimeGeneration: String? }
    private func probePath(_ environmentID: String) -> String { "Probes/" + FloeDigest.sha256Hex(Data(environmentID.utf8)) + ".json" }
    private func restoreProbe(service: ChemistryService, projectID: UUID, root: URL,
                              pin: TaskExecutionBinding, config: ChemistryWorkerConfiguration, context: ToolContext) async throws {
        let pointerURL = try ChemistryWorkerFiles.child(probePath(pin.target.environmentID), root: journal(root))
        guard FileManager.default.fileExists(atPath: pointerURL.path) else {
            throw FloeError.validationFailed("Check chemistry capabilities in this execution environment first")
        }
        let pointer = try JSONDecoder().decode(ProbePointer.self, from: ChemistryWorkerFiles.read(pointerURL, limit: 4096))
        guard pointer.configurationDigest == config.fingerprint, pointer.generation == pin.generation,
              pointer.runtimeGeneration == pin.target.runtimeGeneration else {
            throw FloeError.validationFailed("The execution environment changed; check its chemistry capabilities again")
        }
        let value = try attempt(pointer.attemptID, projectID: projectID, root: root, context: context)
        guard value.kind == .probe, value.state == .succeeded, let jobID = value.jobID else { throw FloeError.unauthorized }
        let job = try await verifiedJob(value, jobID: jobID)
        guard job.state == .completed else { throw FloeError.unauthorized }
        let response = try verifiedResponse(value, root: root, job: job)
        try await service.registerExternalWorker(environmentID: value.environmentID,
            capabilities: ChemistryWorkerCapabilities.decode(response))
    }

    /// AI cancel never borrows the studio call's authority to dispatch a job
    /// cancellation. It returns the real jobs.cancel call and awaits readback.
    func cancelHandoff(_ id: UUID, service: ChemistryService, projectID: UUID,
                       root: URL, context: ToolContext) async throws -> ChemistryEnvironmentResult {
        _ = try await status(id, service: service, projectID: projectID, root: root, context: context)
        var value = try attempt(id, projectID: projectID, root: root, context: context)
        if value.state.terminal { return try result(value) }
        if let jobID = value.jobID {
            let job = try await verifiedJob(value, jobID: jobID)
            if job.state.isTerminal { return try await reconcile(value, service: service, root: root) }
            guard context.allowedToolNames?.contains("jobs.cancel") != false,
                  context.frozenEffectiveCatalogNames?.contains("jobs.cancel") != false else { throw FloeError.unauthorized }
            var output = try result(value, includeSubmission: false)
            output.pendingJobs = [.init(tool: "jobs.cancel", arguments: String(decoding: try encode(["jobID": jobID]), as: UTF8.self))]
            output.followUp = "Call the real jobs.cancel, then status with this attemptID. Cancellation is final only after the actual processor stops."
            return output
        }
        guard value.state == .awaitingSubmission else {
            throw FloeError.validationFailed("Submission is not yet reconciled. Read the original jobs receipt before cancelling or retrying.")
        }
        if !value.nativeIntent {
            // The active original run may have a jobs.submit in flight. Do
            // not label it cancelled without a real receipt/processor stop.
            guard let originalRun = try await app().runStore.run(id: value.owner.hostRunID), originalRun.endedAt != nil,
                  try await discoverOriginalJob(value) == nil else {
                throw FloeError.validationFailed("Adopt the original jobs.submit receipt before cancelling. A submit may still be in flight.")
            }
        }
        if let runID = value.chemistryRunID {
            _ = try await service.terminateExternal(projectID, runID: runID, owner: value.owner, jobID: nil,
                status: .cancelled, error: "Cancelled before any background job was submitted")
        }
        value.state = .cancelled; try save(value, root: root); return try result(value)
    }

    private func result(_ value: ChemistryWorkerAttempt, includeSubmission: Bool = true) throws -> ChemistryEnvironmentResult {
        var output = ChemistryEnvironmentResult(attemptID: value.id, projectID: value.projectID,
            chemistryRunID: value.chemistryRunID, environmentID: value.environmentID,
            state: value.state, jobID: value.jobID, error: value.error)
        if includeSubmission, value.state == .awaitingSubmission, value.jobID == nil {
            let arguments = ChemistryJobsSubmitArguments(arguments: String(decoding: value.shellPayload, as: UTF8.self),
                purpose: value.kind == .probe ? "Check chemistry capabilities in the task's selected environment" : "Compute the saved structure's frozen chemistry input")
            output.pendingJobs = [.init(tool: "jobs.submit", arguments: String(decoding: try encode(arguments), as: UTF8.self))]
            output.followUp = "Submit these exact arguments with the ordinary jobs.submit tool. Then adopt with this attemptID and the genuine returned jobID. Never resend an existing attempt."
        }
        return output
    }

    // MARK: Explicit native UI intent. These are not registered AI entrypoints.

    func uiTask(for record: PersonalContentRecord) async throws -> UUID {
        guard record.kind.rawValue == "chemistry" else { throw PersonalContentError.invalidProject }
        try await PersonalContentService.shared.verify(record)
        let environment = try app(), authority = try environment.studioCoordinator.access.get()
        if let taskID = try await authority.assistant(projectID: record.id),
           let task = try await environment.conversationStore.conversation(id: taskID), task.purpose == .ordinary,
           try await authority.canAccess(conversationID: taskID, projectID: record.id, editing: true) {
            return taskID
        }
        return try await environment.studioCoordinator.assistant(for: record)
    }

    private func nativeContext(record: PersonalContentRecord) async throws -> (ToolContext, WorkspaceCenter.TaskRootLease) {
        let environment = try app(), taskID = try await uiTask(for: record)
        let workspace = try await SQLiteWorkspaceStore(database: environment.database)
            .ensureWorkspace(conversationID: taskID, title: record.title)
        let lease = try await environment.workspaceCenter.acquireTaskRoot(workspace, conversationID: taskID)
        do {
            let runID = UUID()
            let pin = try await environment.taskExecutionEnvironments.resolveBinding(conversationID: taskID,
                runID: runID, root: lease.url, workspace: workspace)
            let now = Date()
            try await environment.runStore.saveRun(RunRecord(id: runID, conversationID: taskID,
                state: "completed", goal: "Chemistry calculation", startedAt: now, endedAt: now, executionBinding: pin))
            try await environment.runStore.appendEvent(runID: runID, kind: .status,
                payloadJSON: ChemistryNativeRunMetadata(runID: runID, conversationID: taskID, projectID: record.id).payloadJSON())
            let context = ToolContext(runID: runID, scope: pin.target.remoteHostID.map(ToolScope.host) ?? .local,
                allowedToolNames: ["exec.shell"], workspaceRootURL: lease.url, cancellation: CancellationToken(),
                environmentID: pin.target.environmentID, executionBindingGeneration: pin.generation, conversationID: taskID)
            return (context, lease)
        } catch { lease.release(); throw error }
    }

    func startNativeProbe(record: PersonalContentRecord, root: URL, service: ChemistryService) async throws -> ChemistryEnvironmentResult {
        let (context, lease) = try await nativeContext(record: record)
        var preparedID: UUID?
        do {
            let prepared = try await prepareProbe(projectID: record.id, root: root, context: context, nativeIntent: true)
            preparedID = prepared.attemptID
            nativeLeases[prepared.attemptID] = lease
            return try await submitNative(prepared.attemptID, service: service, projectID: record.id, root: root, context: context)
        } catch {
            if let preparedID { nativeLeases.removeValue(forKey: preparedID)?.release() }
            else { lease.release() }
            throw error
        }
    }

    func startNativeRun(record: PersonalContentRecord, root: URL, service: ChemistryService, objectID: UUID,
                        expectedRevision: UInt64, method: String, options: FloeChemistryCore.JSONValue = .object([:]),
                        requiredEnvironmentID: String? = nil) async throws -> ChemistryEnvironmentResult {
        let (context, lease) = try await nativeContext(record: record)
        var preparedID: UUID?
        do {
            if let requiredEnvironmentID, context.environmentID != requiredEnvironmentID {
                throw FloeError.validationFailed("Choose this project's selected execution environment before computing")
            }
            let prepared = try await prepareRun(service: service, projectID: record.id, root: root, objectID: objectID,
                expectedRevision: expectedRevision, method: method, options: options, context: context, nativeIntent: true)
            preparedID = prepared.attemptID
            nativeLeases[prepared.attemptID] = lease
            return try await submitNative(prepared.attemptID, service: service, projectID: record.id, root: root, context: context)
        } catch {
            if let preparedID { nativeLeases.removeValue(forKey: preparedID)?.release() }
            else { lease.release() }
            throw error
        }
    }

    private func submitNative(_ id: UUID, service: ChemistryService, projectID: UUID, root: URL,
                              context: ToolContext) async throws -> ChemistryEnvironmentResult {
        var value = try attempt(id, projectID: projectID, root: root, context: context)
        guard value.nativeIntent, value.owner.hostRunID == context.runID,
              value.state == .awaitingSubmission, value.jobID == nil else { throw FloeError.unauthorized }
        return try await nativeSubmissions.perform(id) {
            _ = try await binding(context)
            try Task.checkCancellation()
            // Stop/delete may have changed the attempt while binding awaited.
            value = try attempt(id, projectID: projectID, root: root, context: context)
            guard value.state == .awaitingSubmission, value.jobID == nil else { throw CancellationError() }
            // Persist uncertainty BEFORE invoking the durable jobs API.
            value.state = .submissionUnknown; try save(value, root: root)
            do {
                let job = try await jobs().submit(runID: value.owner.hostRunID, toolCallID: nil,
                    targetTool: "exec.shell", payloadJSON: value.shellPayload, scope: context.scope,
                    workspaceRootURL: context.workspaceRootURL, allowedWorkspacePaths: value.allowedWorkspacePaths,
                    environmentID: value.environmentID, allowedToolNames: ["exec.shell"],
                    submissionSource: .nativeService, advisoryGroupID: value.id)
                value.jobID = job.id; value.state = .running; try save(value, root: root)
                let output = try await adopt(id, jobID: job.id, service: service, projectID: projectID, root: root, context: context)
                monitor(id, service: service, projectID: projectID, root: root, context: context)
                return output
            } catch {
                value.error = String(error.localizedDescription.prefix(8000)); try? save(value, root: root)
                throw error
            }
        }
    }

    private func monitor(_ id: UUID, service: ChemistryService, projectID: UUID, root: URL, context: ToolContext) {
        guard workers[id] == nil else { return }
        workers[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.workers[id] = nil
                self.nativeLeases.removeValue(forKey: id)?.release()
                Task { try? await self.jobs().releaseAdvisoryGroupLease(groupID: id) }
            }
            do {
                while !Task.isCancelled {
                    let output = try await self.status(id, service: service, projectID: projectID, root: root, context: context)
                    if output.state.terminal || output.state == .transferPending { return }
                    try await Task.sleep(for: .milliseconds(750))
                }
            } catch {
                // Keep original job/attempt for explicit status/reconciliation.
                // View disappearance does not cancel or replay any processor.
            }
        }
    }

    /// Reopening can reconcile a genuine original native job through its
    /// original durable owner, rather than creating a new execution run.
    private func recoveredNativeContext(_ id: UUID, record: PersonalContentRecord, root: URL) async throws -> (ToolContext, WorkspaceCenter.TaskRootLease) {
        let environment = try app()
        try await PersonalContentService.shared.verify(record)
        let file = try ChemistryWorkerFiles.child(id.uuidString + "/attempt.json", root: journal(root))
        let value = try JSONDecoder().decode(ChemistryWorkerAttempt.self, from: ChemistryWorkerFiles.read(file, limit: 256 * 1024))
        let taskID = value.owner.taskID
        guard value.id == id, value.projectID == record.id,
              let task = try await environment.conversationStore.conversation(id: taskID), task.purpose == .ordinary else { throw FloeError.unauthorized }
        let workspace = try await SQLiteWorkspaceStore(database: environment.database).ensureWorkspace(conversationID: taskID, title: task.title)
        let lease = try await environment.workspaceCenter.acquireTaskRoot(workspace, conversationID: taskID)
        do {
            guard value.id == id, value.projectID == record.id, value.owner.taskID == taskID,
                  let run = try await environment.runStore.run(id: value.owner.hostRunID), run.conversationID == taskID,
                  let pin = run.executionBinding, pin.generation == value.bindingGeneration,
                  pin.target.environmentID == value.environmentID,
                  value.workspaceRootPath == ChemistryWorkerFiles.canonical(lease.url).path else { throw FloeError.unauthorized }
            let context = ToolContext(runID: run.id, scope: pin.target.remoteHostID.map(ToolScope.host) ?? .local,
                allowedToolNames: ["exec.shell"], workspaceRootURL: lease.url,
                allowedWorkspacePaths: value.allowedWorkspacePaths, cancellation: CancellationToken(),
                environmentID: value.environmentID, executionBindingGeneration: pin.generation, conversationID: taskID)
            return (context, lease)
        } catch { lease.release(); throw error }
    }

    func statusNative(_ id: UUID, record: PersonalContentRecord, root: URL, service: ChemistryService) async throws -> ChemistryEnvironmentResult {
        let (context, lease) = try await recoveredNativeContext(id, record: record, root: root)
        defer { lease.release() }
        return try await status(id, service: service, projectID: record.id, root: root, context: context)
    }

    func cancelNative(_ id: UUID, record: PersonalContentRecord, root: URL, service: ChemistryService) async throws -> ChemistryEnvironmentResult {
        let (context, lease) = try await recoveredNativeContext(id, record: record, root: root)
        defer { lease.release() }
        var value = try attempt(id, projectID: record.id, root: root, context: context)
        guard value.nativeIntent else {
            throw FloeError.validationFailed("Cancel this assistant-owned job from its task")
        }
        if value.state.terminal { return try result(value) }
        guard let jobID = value.jobID else {
            return try await cancelHandoff(id, service: service, projectID: record.id, root: root, context: context)
        }
        let job = try await verifiedJob(value, jobID: jobID)
        if job.state.isTerminal { return try await reconcile(value, service: service, root: root) }
        value.state = .cancelling; try save(value, root: root)
        _ = try await jobs().cancel(id: jobID)
        let result = try await status(id, service: service, projectID: record.id, root: root, context: context)
        if !result.state.terminal {
            if nativeLeases[id] == nil {
                let extra = try await recoveredNativeContext(id, record: record, root: root)
                nativeLeases[id] = extra.1
            }
            monitor(id, service: service, projectID: record.id, root: root, context: context)
        }
        return result
    }

    func recent(projectID: UUID, root: URL) throws -> [ChemistryEnvironmentResult] {
        let archive = try journal(root)
        let paths = try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)
        guard paths.count <= 4096 else { throw FloeError.validationFailed("Open a specific saved calculation to read its status") }
        let values: [ChemistryWorkerAttempt] = paths.compactMap { url in
            guard let id = UUID(uuidString: url.lastPathComponent),
                  let file = try? ChemistryWorkerFiles.child(id.uuidString + "/attempt.json", root: archive),
                  let bytes = try? ChemistryWorkerFiles.read(file, limit: 256 * 1024),
                  let value = try? JSONDecoder().decode(ChemistryWorkerAttempt.self, from: bytes),
                  value.id == id, value.projectID == projectID else { return nil }
            return value
        }
        return try values.sorted { $0.createdAt > $1.createdAt }.prefix(24).map { try result($0, includeSubmission: false) }
    }

    /// Called once when the existing sole session is created. No extra
    /// ChemistryService, editor state, undo stack or assistant is constructed.
    func installEditorHooks(_ session: ChemistryProjectSession) {
        Task { [weak self, weak session] in
            guard let self, let session else { return }
            await self.refreshDisplayNames(session)
        }
        session.editor.calculationHandler = { [weak self, weak session] objectID, method, options in
            guard let self, let session, !session.closing else { throw PersonalContentError.storageUnavailable }
            let project = try await session.service.project(session.projectID)
            if project.defaultEnvironmentID == "native.local" {
                return try await session.service.start(session.projectID, objectID: objectID,
                    method: method, options: options, environmentID: "native.local")
            }
            // EditorState.perform is already busy while invoking this hook.
            // Flush drafts directly; hasPendingEdits also includes that busy
            // flag and must not incorrectly reject every host calculation.
            await session.editor.flush()
            guard session.editor.drafts.isEmpty, !session.editor.sketchStatuses.values.contains(where: {
                switch $0 { case .editing, .saving, .failed: true; default: false }
            }) else { throw PersonalContentError.changedDocument }
            let current = try await session.service.project(session.projectID)
            guard current.defaultEnvironmentID == project.defaultEnvironmentID,
                  let object = current.objects.first(where: { $0.id == objectID }) else { throw PersonalContentError.changedDocument }
            let location = try await PersonalContentService.shared.library().resolve(session.projectID)
            guard ChemistryWorkerFiles.canonical(location.url) == ChemistryWorkerFiles.canonical(session.root) else {
                throw PersonalContentError.changedDocument
            }
            let output = try await self.startNativeRun(record: location.record, root: location.url,
                service: session.service, objectID: objectID, expectedRevision: object.revision,
                method: method, options: options, requiredEnvironmentID: project.defaultEnvironmentID)
            guard let runID = output.chemistryRunID else { throw PersonalContentError.invalidProject }
            return runID
        }
        session.editor.cancellationHandler = { [weak self, weak session] runID in
            guard let self, let session else { throw PersonalContentError.storageUnavailable }
            let project = try await session.service.project(session.projectID)
            guard let run = project.runs.first(where: { $0.id == runID }) else { throw PersonalContentError.missingDocument }
            guard let external = run.externalExecution else {
                try await session.service.cancel(session.projectID, runID: runID); return
            }
            let location = try await PersonalContentService.shared.library().resolve(session.projectID)
            _ = try await self.cancelNative(external.identity.attemptID, record: location.record,
                root: location.url, service: session.service)
        }
    }

    /// Display-only native registry labels. IDs remain the sole execution key.
    func refreshDisplayNames(_ session: ChemistryProjectSession) async {
        guard let environment else { return }
        try? await environment.environmentRegistry.prepare()
        let records = await environment.environmentRegistry.all()
        let hosts = (try? await environment.remoteHostStore.hosts()) ?? []
        var names = ["native.local": IDELanguageRunText.t("本机", "On this device")]
        for record in records {
            if let hostID = record.remoteHostID, let host = hosts.first(where: { $0.id == hostID }) {
                names[record.id] = host.displayName
            } else if let name = record.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty, name != record.id, UUID(uuidString: name) == nil {
                names[record.id] = name
            } else {
                switch record.effectiveExecutionBackend {
                case .native: names[record.id] = IDELanguageRunText.t("本机", "On this device")
                case .linuxVM: names[record.id] = IDELanguageRunText.t("本机 Linux", "On-device Linux")
                case .macBridge: names[record.id] = "Mac"
                case .remoteSSH: names[record.id] = IDELanguageRunText.t("远端环境", "Remote environment")
                }
            }
        }
        session.editor.environmentDisplayNames = names
    }

    /// Stop native UI-owned probes/calculations before deleting their original.
    /// Deletion uses the current file owner's authority: job liveness is read
    /// from the durable jobs store and the owning run's end state from the
    /// run record, never by reviving a historical execution context that may
    /// have expired. Assistant-owned live work still belongs to its task.
    func prepareForDeletion(session: ChemistryProjectSession) async throws {
        let location = try await ChemistryProjectSession.resolveLibraryOriginal(id: session.projectID, directory: session.root)
        guard ChemistryWorkerFiles.canonical(location.url) == ChemistryWorkerFiles.canonical(session.root) else { throw PersonalContentError.changedDocument }
        let archive = try journal(location.url)
        let paths = try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)
        guard paths.count <= 4096 else { throw PersonalContentError.invalidProject }
        var attemptIDs: [UUID] = []
        for path in paths {
            guard let id = UUID(uuidString: path.lastPathComponent) else { continue }
            let value = try deletionAttempt(id, archive: archive, session: session)
            attemptIDs.append(id)
            try await stopAttemptForDeletion(value, root: location.url, service: session.service)
        }
        let project = try await session.service.project(session.projectID)
        guard !project.runs.contains(where: { $0.externalExecution != nil && [.queued, .running].contains($0.status) }) else {
            throw FloeError.validationFailed(IDELanguageRunText.t("先在所属任务中停止这个工程的外部计算，再删除它。", "Stop this project's external calculations in their owning task before deleting it."))
        }
        let monitors = attemptIDs.compactMap { workers[$0] }
        for monitor in monitors { monitor.cancel() }
        for monitor in monitors { await monitor.value }
        try Task.checkCancellation()
    }
    /// Focused lifecycle bounds; focused tests shorten them, production keeps
    /// the defaults. They bound waits that join an owning producer, never a
    /// blind sleep-then-assume.
    var deletionStopTimeout = TimeInterval(15)
    var deletionSubmitJoinTimeout = TimeInterval(15)
    var deletionStopPollInterval = TimeInterval(0.25)
    var deletionSubmitGraceAttempts = 6
    var deletionSubmitGraceInterval = TimeInterval(0.5)
    private func deletionAttempt(_ id: UUID, archive: URL, session: ChemistryProjectSession) throws -> ChemistryWorkerAttempt {
        let file = try ChemistryWorkerFiles.child(id.uuidString + "/attempt.json", root: archive)
        let value = try JSONDecoder().decode(ChemistryWorkerAttempt.self, from: ChemistryWorkerFiles.read(file, limit: 256 * 1024))
        guard value.projectID == session.projectID, value.id == id else { throw PersonalContentError.invalidProject }
        return value
    }
    private func owningRunEnded(_ value: ChemistryWorkerAttempt) async throws -> Bool {
        guard let run = try await app().runStore.run(id: value.owner.hostRunID) else { return true }
        return run.endedAt != nil
    }
    /// Cover the small window in which a native submit was persisted as
    /// uncertain but its genuine jobID has not been saved yet. The durable
    /// jobs store is authoritative for acceptance. Absence after this window
    /// alone is never proof: the submit producer/run must also be settled.
    private func discoverOriginalJobWithGrace(_ value: ChemistryWorkerAttempt) async throws -> BackgroundJob? {
        var last: Error?
        for _ in 0..<deletionSubmitGraceAttempts {
            do {
                if let job = try await discoverOriginalJob(value) { return job }
            } catch { last = error }
            try await Task.sleep(for: .milliseconds(deletionSubmitGraceInterval * 1000))
        }
        if let last { throw last }
        return nil
    }
    private func reloadAttemptForDeletion(_ id: UUID, root: URL) throws -> ChemistryWorkerAttempt? {
        let file = try ChemistryWorkerFiles.child(id.uuidString + "/attempt.json", root: journal(root))
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let value = try JSONDecoder().decode(ChemistryWorkerAttempt.self, from: ChemistryWorkerFiles.read(file, limit: 256 * 1024))
        guard value.id == id else { return nil }
        return value
    }
    func stopAttemptForDeletion(_ original: ChemistryWorkerAttempt, root: URL, service: ChemistryService) async throws {
        var value = original
        // Includes awaitingSubmission while binding() is suspended. A worker
        // lease is not a submit fence: it remains held while a job is running.
        if value.nativeIntent, nativeSubmissions.isSubmitting(value.id) {
            guard try await nativeSubmissions.waitUntilSettled(value.id, timeout: .seconds(deletionSubmitJoinTimeout)) else {
                throw FloeError.validationFailed(IDELanguageRunText.t("这次计算仍在提交，原件已保留；请稍后再试删除。", "This calculation is still submitting. Its original has been retained; try the deletion again shortly."))
            }
            guard let settled = try reloadAttemptForDeletion(value.id, root: root) else { return }
            value = settled
        }
        // Prevent a status read that started before cancellation from saving
        // an older running receipt after the deletion reconciliation.
        if let monitor = workers[value.id] {
            monitor.cancel()
            await monitor.value
            if let settled = try reloadAttemptForDeletion(value.id, root: root) { value = settled }
        }
        // Genuine terminal attempts never touch a potentially reaped job row.
        guard !value.state.terminal else { return }
        if value.jobID == nil, !value.state.terminal {
            let recovered = try await (value.state == .submissionUnknown
                ? discoverOriginalJobWithGrace(value) : discoverOriginalJob(value))
            if let recovered {
                value.jobID = recovered.id
                if !value.state.terminal { value.state = .running }
                try save(value, root: root)
            }
        }
        if let jobID = value.jobID {
            let job = try await verifiedJob(value, jobID: jobID)
            if job.state.isTerminal {
                // The durable processor already finished honestly: reconcile
                // the genuine result (or its transfer state) before deleting,
                // exactly like the user-visible status path and without the
                // historical execution context.
                let output = try await reconcile(value, service: service, root: root)
                if output.state == .transferPending {
                    throw FloeError.validationFailed(IDELanguageRunText.t("先完成对账保存的结果文件，再删除这个化学工程。", "Reconcile the saved result files before deleting this chemistry project."))
                }
                guard output.state.terminal else {
                    throw FloeError.validationFailed(IDELanguageRunText.t("计算仍在停止中，原件已保留；等它停止后再删除。", "The calculation is still stopping. Its original has been retained; delete it again after the calculation stops."))
                }
                return
            }
            // A live processor: only the native UI's own workers may be
            // stopped here; assistant-owned work stays in its execution task.
            guard value.nativeIntent else {
                throw FloeError.validationFailed(IDELanguageRunText.t("这份计算仍在运行。请先在发起它的任务中停止，再删除这个文件。", "This calculation is still running. Stop it in the task that started it, then delete this file."))
            }
            try await stopOwnedJobForDeletion(&value, root: root, service: service)
            return
        }
        // No genuine job was ever submitted: decide from the run record alone.
        // A last store read immediately before recording the cancellation
        // closes the gap after the bounded grace window.
        if value.state == .submissionUnknown, let late = try await discoverOriginalJob(value) {
            value.jobID = late.id
            if !value.state.terminal { value.state = .running }
            try save(value, root: root)
            try await stopAttemptForDeletion(value, root: root, service: service)
            return
        }
        switch value.deletionStopPlan(hasLiveJob: false, owningRunEnded: try await owningRunEnded(value)) {
        case .skip: return
        case .reconcileFirst, .stopOwnedJob, .refuseLiveForeignJob: return
        case .refuseUnfinishedSubmit:
            throw FloeError.validationFailed(IDELanguageRunText.t("这次计算所属的任务可能仍在提交。请先完成或停止那个任务，再删除这个文件。", "This calculation's task may still be submitting its job. Finish or stop that task before deleting this file."))
        case .reconcileStale:
            try await markAttemptCancelled(&value, root: root, service: service,
                error: IDELanguageRunText.t("随化学工程删除而对账为已停止。", "Reconciled as stopped when its chemistry project was deleted."))
        }
    }
    /// Really stop the user's own live worker: cancellation is a request, so
    /// deletion continues only after the durable processor is terminal. The
    /// honest result (or cancellation) is then reconciled like a normal stop;
    /// a stop that does not finish keeps the original and reports why.
    private func stopOwnedJobForDeletion(_ value: inout ChemistryWorkerAttempt, root: URL, service: ChemistryService) async throws {
        guard let jobID = value.jobID else { return }
        value.state = .cancelling; try save(value, root: root)
        _ = try await jobs().cancel(id: jobID)
        let deadline = Date().addingTimeInterval(deletionStopTimeout)
        var stopped = false
        while Date() < deadline, !stopped {
            let job = try await verifiedJob(value, jobID: jobID)
            stopped = job.state.isTerminal
            if !stopped { try await Task.sleep(for: .milliseconds(deletionStopPollInterval * 1000)) }
        }
        guard stopped else {
            throw FloeError.validationFailed(IDELanguageRunText.t("计算仍在停止中，原件已保留；等它停止后再删除。", "The calculation is still stopping. Its original has been retained; delete it again after the calculation stops."))
        }
        let output = try await reconcile(value, service: service, root: root)
        if output.state == .transferPending {
            throw FloeError.validationFailed(IDELanguageRunText.t("先完成对账保存的结果文件，再删除这个化学工程。", "Reconcile the saved result files before deleting this chemistry project."))
        }
        guard output.state.terminal else {
            throw FloeError.validationFailed(IDELanguageRunText.t("计算仍在停止中，原件已保留；等它停止后再删除。", "The calculation is still stopping. Its original has been retained; delete it again after the calculation stops."))
        }
    }
    private func markAttemptCancelled(_ value: inout ChemistryWorkerAttempt, root: URL, service: ChemistryService, error: String) async throws {
        if let runID = value.chemistryRunID {
            let executionJobID = try await service.project(value.projectID).runs
                .first(where: { $0.id == runID })?.externalExecution?.jobID
            _ = try await service.terminateExternal(value.projectID, runID: runID, owner: value.owner,
                jobID: executionJobID, status: .cancelled, error: error)
        }
        value.state = .cancelled; value.error = error
        try save(value, root: root)
    }
}
#endif
