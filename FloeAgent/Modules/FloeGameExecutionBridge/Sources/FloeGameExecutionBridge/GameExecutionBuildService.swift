// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameBuildKit
import FloeGameCore
import FloeGameRunKit

/// Composes the existing `GameBuildDistributionRequest` from the explicit
/// profile and the captured exact-source provider. Nil profile keeps the
/// ordinary build path; a provider without a profile is intentionally ignored.
enum GameExecutionDistributionComposition {
    static func request(profileID: String?,
                        pairedProvider: (any GameDistributionPairedSourceProvider)?)
        -> GameBuildDistributionRequest? {
        guard let profileID else { return nil }
        return .init(profileID: profileID, mode: .distribution,
                     pairedProvider: pairedProvider)
    }
}

/// The stable build entry point for Root's project session. It composes the
/// existing `GameBuildCoordinator` with the concrete host/CI/source/exporter
/// adapters and keeps the durable records in the project-owned support folder.
public actor GameExecutionBuildService {
    public struct Configuration: Sendable {
        public let projectID: UUID
        public let repository: FileGameProjectRepository
        public let recordsDirectory: URL
        public let currentContext: @MainActor @Sendable () async throws -> GameProjectContext
        public let host: (any GameBuildHostPort)?
        public let ci: (any GameBuildCIJobsPort)?
        public let sourcePublisher: (any GameBuildSourcePublisherPort)?
        public let repositoryCoordinates: GameBuildRepositoryReference?
        public let exporter: (any GameBuildExporterPort)?

        public init(projectID: UUID,
                    repository: FileGameProjectRepository,
                    recordsDirectory: URL,
                    currentContext: @escaping @MainActor @Sendable () async throws -> GameProjectContext,
                    host: (any GameBuildHostPort)?,
                    ci: (any GameBuildCIJobsPort)?,
                    sourcePublisher: (any GameBuildSourcePublisherPort)?,
                    repositoryCoordinates: GameBuildRepositoryReference?,
                    exporter: (any GameBuildExporterPort)?) {
            self.projectID = projectID
            self.repository = repository
            self.recordsDirectory = recordsDirectory
            self.currentContext = currentContext
            self.host = host
            self.ci = ci
            self.sourcePublisher = sourcePublisher
            self.repositoryCoordinates = repositoryCoordinates
            self.exporter = exporter
        }
    }

    private let configuration: Configuration
    private let records: GameBuildRecordStore
    private let coordinator: GameBuildCoordinator
    /// Begin-close fences new work before the first await. In-flight tasks are
    /// those actually started, not a view's intent to build.
    private var closed = false
    private var inFlight: [UUID: Task<GameBuildOutcome, Error>] = [:]

    public init(configuration: Configuration) throws {
        self.configuration = configuration
        self.records = try GameBuildRecordStore(directory: configuration.recordsDirectory)
        self.coordinator = GameBuildCoordinator(
            hostPort: configuration.host,
            ciPort: configuration.ci,
            records: records)
    }

    /// Additive target-aware planning. `selection` defaults to nil so existing
    /// callers keep the truthful project-root plan. Root passes a selection
    /// constructed from its freshly refreshed `requireRunSelection()` and the
    /// same saved context.
    public func capabilityPlan(engine: GameEngineID,
                               selection: GameBuildProjectSelection? = nil) async throws -> GameBuildCapabilityPlan {
        let context = try await configuration.currentContext()
        return try plan(context: context, engine: engine, selection: selection)
    }

    private func plan(context: GameProjectContext, engine: GameEngineID,
                      selection: GameBuildProjectSelection?) throws -> GameBuildCapabilityPlan {
        if let selection {
            do {
                try selection.validate(against: context)
                try selection.validate(engine: engine)
            } catch let error as GameBuildSelectionError {
                throw GameExecutionError.selectionInvalid(String(describing: error))
            }
            // Inspect exactly the selected root, but never replace the
            // authoritative context that is later exported and bound.
            let selectedProbe = try GameProjectInspector().inspect(rootURL: selection.selectedRootURL)
            let prefix = selection.gameRoot.map { $0.value + "/" } ?? ""
            let candidates = try selectedProbe.candidates.map { candidate in
                GameEngineCandidate(engine: candidate.engine, evidence: try candidate.evidence.map { evidence in
                    GameEngineEvidence(path: try GameRelativePath(prefix + evidence.path.value),
                        kind: evidence.kind, versionHint: evidence.versionHint)
                })
            }
            let inspection = GameProjectInspection(rootURL: context.rootURL, context: context,
                candidates: candidates, inspectedPaths: try selectedProbe.inspectedPaths.map {
                    try GameRelativePath(prefix + $0.value)
                })
            guard inspection.candidates.contains(where: { $0.engine == engine }) else {
                throw GameExecutionError.selectionInvalid(
                    "engine \(engine.rawValue) is not recognized at the selected game root")
            }
            return try GameBuildCapabilityRegistry.plan(for: engine, inspection: inspection)
        }
        let inspection = try GameProjectInspector().inspect(context: context)
        return try GameBuildCapabilityRegistry.plan(for: engine, inspection: inspection)
    }

    /// Additive captured paired-source argument. `GameExecutionBuildRequest`
    /// stays Equatable and never synthesizes provider equality; the provider is
    /// meaningful only with an explicit distribution profile.
    public func build(_ request: GameExecutionBuildRequest,
                      pairedProvider: (any GameDistributionPairedSourceProvider)? = nil) async throws -> GameBuildOutcome {
        guard !closed else { throw GameExecutionError.cancelled }
        let context = try await configuration.currentContext()
        guard !closed else { throw GameExecutionError.cancelled }
        let capabilityPlan = try plan(context: context, engine: request.engine,
                                      selection: request.selection)
        guard !closed else { throw GameExecutionError.cancelled }
        let distribution = GameExecutionDistributionComposition.request(
            profileID: request.distributionProfileID, pairedProvider: pairedProvider)
        let buildID = UUID()
        let coordinator = self.coordinator
        let repository = configuration.repository
        let repositoryCoordinates = configuration.repositoryCoordinates
        let sourcePublisher = configuration.sourcePublisher
        let exporter = configuration.exporter
        let task = Task {
            try await coordinator.run(
                plan: capabilityPlan,
                source: context,
                repository: repository,
                provided: request.providedTools,
                sourceTransport: nil,
                repositoryCoordinates: repositoryCoordinates,
                sourcePublisher: sourcePublisher,
                distribution: distribution,
                exporter: exporter,
                selectedRouteIDs: request.selectedRouteIDs,
                selection: request.selection,
                buildID: buildID)
        }
        inFlight[buildID] = task
        defer { inFlight.removeValue(forKey: buildID) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Compatibility wrapper for callers that still request a stop without
    /// awaiting the drain. It now uses the exact same confirmed-drain path.
    public func cancel(_ buildID: UUID) async {
        _ = await cancelAndDrain(buildID)
    }

    public func cancelAll() async {
        _ = await coordinator.beginReplacement(projectID: configuration.projectID)
        _ = await cancelAndDrainAll(fenceNewBuilds: false)
    }

    /// Requests cancellation immediately; UI may use this for a fast state
    /// change, but closure must await the drain API below.
    public func requestCancel(_ buildID: UUID) async {
        await coordinator.requestCancel(buildID: buildID)
    }

    /// Cancels one build and waits for its exact local task and remote job. The
    /// result is explicit; an unconfirmed state retains the coordinator handle.
    public func cancelAndDrain(_ buildID: UUID,
                               pollInterval: Duration = .milliseconds(200),
                               drainTimeout: Duration = .seconds(60)) async
        -> GameExecutionDrainSummary {
        if let task = inFlight[buildID] { task.cancel() }
        await coordinator.requestCancel(buildID: buildID)
        let receipt = await coordinator.cancelAndDrain(
            buildID: buildID, pollInterval: pollInterval, drainTimeout: drainTimeout)
        let drained = await waitForInFlight([buildID], timeout: drainTimeout)
        guard receipt.isConfirmed, drained else {
            let detail = receipt.isConfirmed
                ? "the local build task did not finish after cancellation"
                : receipt.detail
            return .unconfirmed(ids: ["build:\(buildID.uuidString.lowercased())"],
                                detail: detail)
        }
        return .confirmed
    }

    /// Begin-close: fence every new build, cancel all owned local tasks and
    /// drain each exact remote handle. A nil/empty project still returns a
    /// confirmed result only when no task or retained handle remains.
    public func cancelAndDrainAll(pollInterval: Duration = .milliseconds(200),
                                  drainTimeout: Duration = .seconds(60),
                                  fenceNewBuilds: Bool = false) async
        -> GameExecutionDrainSummary {
        if fenceNewBuilds { closed = true }
        var ids = await coordinator.activeBuilds(projectID: configuration.projectID)
        for id in Array(inFlight.keys) { ids.insert(id) }
        for id in ids {
            inFlight[id]?.cancel()
            await coordinator.requestCancel(buildID: id)
        }
        let receipt = await coordinator.cancelAndDrain(
            projectID: configuration.projectID,
            pollInterval: pollInterval, drainTimeout: drainTimeout)
        let drained = await waitForInFlight(Array(ids), timeout: drainTimeout)
        let durableUnresolved = await durableDispatchedBuildIDs()
        guard receipt.isConfirmed, drained, durableUnresolved.isEmpty else {
            var operationIDs = receipt.buildIDs.isEmpty
                ? ids.sorted { $0.uuidString < $1.uuidString }
                    .map { "build:\($0.uuidString.lowercased())" }
                : receipt.buildIDs.sorted { $0.uuidString < $1.uuidString }
                    .map { "build:\($0.uuidString.lowercased())" }
            operationIDs.append(contentsOf: durableUnresolved
                .sorted { $0.uuidString < $1.uuidString }
                .map { "build:\($0.uuidString.lowercased())" })
            var detail = receipt.isConfirmed
                ? "the local build task did not finish after cancellation"
                : receipt.detail
            if !durableUnresolved.isEmpty {
                let suffix = "durable dispatched builds have no in-process handle; this process cannot confirm their remote jobs"
                detail = detail.isEmpty ? suffix : detail + "; " + suffix
            }
            return .unconfirmed(ids: operationIDs, detail: detail)
        }
        return .confirmed
    }

    /// Retained builds are the retry path after an unconfirmed Stop.
    public func retainedBuilds() async -> Set<UUID> {
        await coordinator.retainedBuilds(projectID: configuration.projectID)
    }

    public func activeBuilds() async -> Set<UUID> {
        await coordinator.activeBuilds(projectID: configuration.projectID)
    }

    private func durableDispatchedBuildIDs() async -> [UUID] {
        guard let ids = try? await records.list() else { return [] }
        var result: [UUID] = []
        for id in ids {
            guard let uuid = UUID(uuidString: id),
                  let record = try? await records.load(buildID: id),
                  record.projectID == configuration.projectID.uuidString.lowercased(),
                  record.state == .dispatched else { continue }
            result.append(uuid)
        }
        return result
    }

    private func waitForInFlight(_ ids: [UUID], timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let remaining = ids.filter { inFlight[$0] != nil }
            if remaining.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return ids.allSatisfy { inFlight[$0] == nil }
    }

    public func delete(_ buildID: UUID) async throws {
        try await coordinator.delete(buildID: buildID)
    }

    /// Durable records for this project in deterministic build-id order. A corrupt/unreadable
    /// record is left on disk and surfaced by the store's own behavior rather
    /// than silently dropped.
    public func restoredRecords() async throws -> [GameBuildRecord] {
        let ids = try await records.list()
        var result: [GameBuildRecord] = []
        for id in ids {
            try Task.checkCancellation()
            guard let record = try await records.load(buildID: id),
                  record.projectID == configuration.projectID.uuidString.lowercased() else {
                continue
            }
            result.append(record)
        }
        return result.sorted { lhs, rhs in
            (lhs.buildID, lhs.revision) > (rhs.buildID, rhs.revision)
        }
    }
}
