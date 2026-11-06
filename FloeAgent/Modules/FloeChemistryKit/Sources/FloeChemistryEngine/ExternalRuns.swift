import Foundation
import FloeChemistryCore

public extension ChemistryService {
    /// Host-only registration after a real capability probe. Existing runs keep their frozen identity.
    func registerExternalWorker(environmentID: String, capabilities: ChemistryWorkerCapabilities) throws {
        guard !environmentID.isEmpty, environmentID.utf8.count <= 4096, environmentID != "native.local",
              backends[environmentID] == nil || backends[environmentID]?.executionMode == .externalJob else {
            throw ChemistryError.invalid("Cannot replace this execution environment with an external worker.")
        }
        backends[environmentID] = ConfiguredChemistryBackend(environmentID: environmentID,
            engineVersion: capabilities.engineVersion, methods: capabilities.methods, executionMode: .externalJob) { _ in
                throw ChemistryError.unavailable("Use the execution task's background jobs for this environment.")
            }
    }

    func removeExternalWorker(environmentID: String) throws {
        guard backends[environmentID] == nil || backends[environmentID]?.executionMode == .externalJob else {
            throw ChemistryError.invalid("The native execution environment cannot be removed here.")
        }
        backends.removeValue(forKey: environmentID)
    }

    /// Freezes and saves a calculation before the host requests real jobs.submit authorization.
    /// It never starts a process, submits a job, or expands the task's execution authority.
    func prepareExternal(_ id: UUID, objectID: UUID, method: String, options: JSONValue = .object([:]),
                         environmentID: String? = nil, owner: ChemistryExecutionOwner) async throws -> ChemistryPreparedRun {
        try await access(id, .read)
        let project = try await store.load(id), env = environmentID ?? project.defaultEnvironmentID
        guard let backend = backends[env], backend.executionMode == .externalJob, backend.methods.contains(method) else {
            throw ChemistryError.unavailable("Probe a configured chemistry worker that supports this method.")
        }
        try await access(id, .compute, env)
        guard let input = project.objects.first(where: { $0.id == objectID }) else { throw ChemistryError.invalid("Object not found.") }
        guard case .object = options else { throw ChemistryError.invalid("Calculation options must be an object.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let inputEncoder = JSONEncoder(); inputEncoder.outputFormatting = [.sortedKeys]
        var run = ChemistryRun(input: input, inputDigest: ChemistryProjectStore.digest(try inputEncoder.encode(input)),
            method: method, options: options, environmentID: env, engineVersion: backend.engineVersion)
        let request = ChemistryRequest(operation: method, format: input.format, data: input.source, options: options)
        let requestJSON = String(decoding: try encoder.encode(request), as: UTF8.self)
        let execution = ChemistryExternalExecution(identity: .init(projectID: id, run: run, owner: owner),
            requestJSON: requestJSON, requestDigest: ChemistryProjectStore.digest(Data(requestJSON.utf8)))
        let prepared = ChemistryPreparedRun(execution)
        _ = try prepared.requestData()
        run.externalExecution = execution
        let savedRun = run
        _ = try await mutate(id) { project in
            guard project.objects.first(where: { $0.id == objectID }) == input else { throw ChemistryError.invalid("Input changed before execution.") }
            project.runs.append(savedRun)
        }
        return prepared
    }

    /// Recovery/readback only. The host reconciles the original job, never automatically replays it.
    func preparedExternal(_ id: UUID, runID: UUID, owner: ChemistryExecutionOwner) async throws -> ChemistryPreparedRun {
        let run = try await externalRun(id, runID: runID, owner: owner)
        return try frozenExternal(run, projectID: id, owner: owner)
    }

    /// App must first verify the genuine job's owner, environment, exec.shell target and exact payload.
    @discardableResult
    func adoptExternal(_ id: UUID, runID: UUID, owner: ChemistryExecutionOwner, attemptID: UUID, jobID: UUID) async throws -> ChemistryRun {
        let expected = try await externalRun(id, runID: runID, owner: owner).externalExecution
        let project = try await mutate(id) { project in
            guard let i = project.runs.firstIndex(where: { $0.id == runID }),
                  var execution = project.runs[i].externalExecution,
                  execution == expected, execution.identity.owner == owner, execution.identity.attemptID == attemptID else {
                throw ChemistryError.invalid("Job receipt belongs to a different calculation or task.")
            }
            if let existing = execution.jobID {
                guard existing == jobID else { throw ChemistryError.invalid("This calculation already has a different background job.") }
                return
            }
            guard project.runs[i].status == .queued else { throw ChemistryError.invalid("This calculation is no longer awaiting a job.") }
            execution.jobID = jobID; project.runs[i].externalExecution = execution
            project.runs[i].status = .running
        }
        return project.runs.first { $0.id == runID }!
    }

    /// Only complete, input-bound worker output may become a chemistry success.
    @discardableResult
    func finishExternal(_ id: UUID, runID: UUID, owner: ChemistryExecutionOwner, jobID: UUID,
                        response: Data) async throws -> ChemistryRun {
        let run = try await externalRun(id, runID: runID, owner: owner)
        let prepared = try frozenExternal(run, projectID: id, owner: owner)
        guard run.externalExecution?.jobID == jobID else { throw ChemistryError.invalid("Worker result has no matching adopted job.") }
        let value = try ChemistryWorkerResponse.decode(response, for: prepared)
        return try await updateExternal(id, runID: runID, owner: owner, jobID: jobID,
            expected: run.externalExecution, status: value.ok ? .succeeded : .failed,
            result: value.ok ? value.result : nil, error: value.ok ? nil : value.error)
    }

    /// Host-only terminal recording after genuine job failure/cancellation/reconciliation.
    /// The host stops/reaps the actual job before recording cancellation here.
    @discardableResult
    func terminateExternal(_ id: UUID, runID: UUID, owner: ChemistryExecutionOwner, jobID: UUID?,
                           status: ChemistryRunStatus, error: String) async throws -> ChemistryRun {
        guard [.failed, .cancelled, .interrupted].contains(status), !error.isEmpty, error.utf8.count <= 16 * 1024 else {
            throw ChemistryError.invalid("Invalid external calculation termination.")
        }
        let run = try await externalRun(id, runID: runID, owner: owner)
        return try await updateExternal(id, runID: runID, owner: owner, jobID: jobID,
            expected: run.externalExecution, status: status, result: nil, error: error)
    }
}

private extension ChemistryService {
    func externalRun(_ id: UUID, runID: UUID, owner: ChemistryExecutionOwner) async throws -> ChemistryRun {
        try await access(id, .read)
        guard let run = try await store.load(id).runs.first(where: { $0.id == runID }),
              run.externalExecution?.identity.owner == owner else { throw ChemistryError.unavailable("Calculation is outside this execution task.") }
        try await access(id, .compute, run.environmentID)
        _ = try frozenExternal(run, projectID: id, owner: owner)
        return run
    }

    func frozenExternal(_ run: ChemistryRun, projectID: UUID, owner: ChemistryExecutionOwner) throws -> ChemistryPreparedRun {
        guard let execution = run.externalExecution,
              execution.identity.projectID == projectID, execution.identity.runID == run.id,
              execution.identity.owner == owner else { throw ChemistryError.invalid("Invalid external calculation identity.") }
        let request = try JSONDecoder().decode(ChemistryRequest.self, from: Data(execution.requestJSON.utf8))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard execution.identity.inputDigest == run.inputDigest,
              run.inputDigest == ChemistryProjectStore.digest(try encoder.encode(run.input)),
              request == ChemistryRequest(operation: run.method, format: run.input.format, data: run.input.source, options: run.options) else {
            throw ChemistryError.corrupt("Frozen calculation request does not match its saved input.")
        }
        let prepared = ChemistryPreparedRun(execution)
        _ = try prepared.requestData()
        return prepared
    }

    func updateExternal(_ id: UUID, runID: UUID, owner: ChemistryExecutionOwner, jobID: UUID?,
                        expected: ChemistryExternalExecution?, status: ChemistryRunStatus,
                        result: JSONValue?, error: String?) async throws -> ChemistryRun {
        let project = try await mutate(id) { project in
            guard let i = project.runs.firstIndex(where: { $0.id == runID }),
                  let execution = project.runs[i].externalExecution,
                  execution == expected, execution.identity.owner == owner, execution.jobID == jobID else {
                throw ChemistryError.invalid("Background job does not match this calculation.")
            }
            guard [.queued, .running].contains(project.runs[i].status) else { return }
            project.runs[i].status = status; project.runs[i].result = result
            project.runs[i].error = error; project.runs[i].finishedAt = Date()
        }
        return project.runs.first { $0.id == runID }!
    }
}
