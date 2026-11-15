// SPDX-License-Identifier: MPL-2.0
#if canImport(FloeGit)
import Foundation
import FloeGit
import FloeGameBuildKit

/// Routes `GameBuildCoordinator` CI calls to the existing concrete
/// `GitHubActionsBuildCIAdapter`, one adapter per dispatched template/run.
/// The adapter is initialized with the exact target artifact set, so a Web-only
/// request never inherits unrelated native jobs.
public actor MainRoutingCIJobsPort: GameBuildCISourceJobsPort {
    private let transport: any GameBuildGitHubActionsTransport
    private let tokens: any GameBuildGitHubTokenProvider
    private let baseRepository: GameBuildRepositoryReference
    private var adapters: [String: GitHubActionsBuildCIAdapter] = [:]

    public init(transport: any GameBuildGitHubActionsTransport,
                tokens: any GameBuildGitHubTokenProvider,
                baseRepository: GameBuildRepositoryReference) {
        self.transport = transport
        self.tokens = tokens
        self.baseRepository = baseRepository
    }

    public func dispatch(template: GameCIWorkflowTemplate, sourceDigest: String,
                         revision: String, engineVersion: String?)
        async throws -> GameCIJobHandle {
        throw GameBuildError.dispatchFailed(
            "This host requires source-aware dispatch; a digest-only CI job is not accepted.")
    }

    public func dispatch(template: GameCIWorkflowTemplate,
                         source: GameBuildSourceTransport,
                         engineVersion: String?) async throws -> GameCIJobHandle {
        let inputs = source.dispatchInputs(engine: template.engine, engineVersion: engineVersion)
        let selection: GameCIWorkflowTargetSelection
        do {
            selection = try template.defaultSelection(inputs: inputs)
        } catch {
            throw GameBuildError.unsupportedTarget(String(describing: error))
        }
        return try await dispatch(template: template, source: source,
                                  engineVersion: engineVersion, targets: selection)
    }

    public func dispatch(template: GameCIWorkflowTemplate,
                         source: GameBuildSourceTransport,
                         engineVersion: String?,
                         targets: GameCIWorkflowTargetSelection)
        async throws -> GameCIJobHandle {
        // Dispatch the reviewed workflow from the configured base branch. The
        // immutable run commit remains the source transport; creating the run
        // ref must not remove the workflow file from the dispatch ref.
        let adapter = GitHubActionsBuildCIAdapter(
            transport: transport,
            tokens: tokens,
            repository: baseRepository,
            expectedArtifacts: targets.artifactNames,
            pollInterval: 3)
        let handle = try await adapter.dispatch(
            template: template, source: source,
            engineVersion: engineVersion, targets: targets)
        adapters[handle.jobID] = adapter
        return handle
    }

    public func status(_ handle: GameCIJobHandle) async throws -> GameCIJobStatus {
        guard let adapter = adapters[handle.jobID] else {
            throw GameBuildError.dispatchFailed(
                "CI run \(handle.jobID) is not owned by this process; inspect the durable record or re-dispatch.")
        }
        return try await adapter.status(handle)
    }

    public func artifact(_ handle: GameCIJobHandle, named: String) async throws -> Data {
        guard let adapter = adapters[handle.jobID] else {
            throw GameBuildError.artifactMissing(named)
        }
        return try await adapter.artifact(handle, named: named)
    }

    public func cancel(_ handle: GameCIJobHandle) async throws {
        guard let adapter = adapters[handle.jobID] else { return }
        try await adapter.cancel(handle)
        // Keep the adapter until the caller observes the terminal status; a
        // cancelAndDrain path still needs to query it. Session teardown drops
        // the whole port.
    }

    public func verifyExistingArtifact(_ reference: GameBuildRemoteArtifactReference)
        async throws -> GameBuildArtifactIdentity {
        let repository = try GameBuildRepositoryReference(
            owner: reference.owner, repository: reference.repository, branch: "source-verify")
        let adapter = GitHubActionsBuildCIAdapter(
            transport: transport, tokens: tokens, repository: repository,
            expectedArtifacts: [reference.name])
        return try await adapter.verifyExistingArtifact(reference)
    }

}
#endif
