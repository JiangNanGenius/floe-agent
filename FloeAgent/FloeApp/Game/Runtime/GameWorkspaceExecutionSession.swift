// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeExecution
import FloeGit
import FloeGameBuildKit
import FloeGameCore
import FloeGameExecutionBridge
import FloeGameIDEBridge
import FloeGamePortableKit
import FloeGameRunKit
import FloeGameWebKit
import FloeGameWorkspaceHost
import FloePersistence
import FloeTools

public struct GameGitHubExecutionConfiguration: Sendable {
    public let repository: GameBuildRepositoryReference
    public let client: GitHubActionsClient
    public let credentials: GitHubCredentialStore
    public let service: GitHubService

    public init(owner: String, repository: String, baseBranch: String,
                client: GitHubActionsClient = .init(),
                credentials: GitHubCredentialStore = .init(),
                service: GitHubService = .init()) throws {
        self.repository = try GameBuildRepositoryReference(
            owner: owner, repository: repository, branch: baseBranch)
        self.client = client
        self.credentials = credentials
        self.service = service
    }
}

public struct GameWorkspaceExecutionConfiguration {
    public let projectID: UUID
    public let owner: GameProjectOwner
    public let rootURL: URL
    public let environmentID: String?
    public let supportDirectory: URL
    public let contexts: ExistingWorkspaceGameContexts
    public let repository: FileGameProjectRepository
    public let currentContext: @MainActor @Sendable () async throws -> GameProjectContext
    /// Resolves the real saved run (chat or Space project assistant/native
    /// service). It must throw when no such run exists; no UUID is generated.
    public let authority: @MainActor @Sendable (GameProjectContext) async throws -> GameExecutionAuthority
    public let shell: any GameShellRunning
    public let gitHub: GameGitHubExecutionConfiguration?
    public let portableResources: [GameEngineID: GamePortablePreparedResources]
    public let preparePortableResource: (@Sendable (GameEngineID) async throws -> GamePortablePreparedResources?)?
    public let renpySDK: URL?
    public let narrativeResources: URL?
    public let runtimePacks: (any GameRunRuntimePackProviding)?
    public let gdevelopSDKRoot: URL?
    public let gdevelopExportScript: URL?
    public let licensedDeployment: (any GameLicensedDeploymentRunning)?
    public let providedTools: Set<String>
    public let developerBridge: (@MainActor (GameIDEProjectRunRequest) throws -> GameDeveloperBridgeConfiguration?)?

    public init(projectID: UUID, owner: GameProjectOwner, rootURL: URL,
                environmentID: String?, supportDirectory: URL,
                contexts: ExistingWorkspaceGameContexts,
                repository: FileGameProjectRepository,
                currentContext: @escaping @MainActor @Sendable () async throws -> GameProjectContext,
                authority: @escaping @MainActor @Sendable (GameProjectContext) async throws -> GameExecutionAuthority,
                shell: any GameShellRunning,
                gitHub: GameGitHubExecutionConfiguration?,
                portableResources: [GameEngineID: GamePortablePreparedResources] = [:],
                preparePortableResource: (@Sendable (GameEngineID) async throws -> GamePortablePreparedResources?)? = nil,
                renpySDK: URL? = nil,
                narrativeResources: URL? = nil,
                runtimePacks: (any GameRunRuntimePackProviding)? = nil,
                gdevelopSDKRoot: URL? = nil,
                gdevelopExportScript: URL? = nil,
                licensedDeployment: (any GameLicensedDeploymentRunning)? = nil,
                providedTools: Set<String> = [],
                developerBridge: (@MainActor (GameIDEProjectRunRequest) throws -> GameDeveloperBridgeConfiguration?)? = nil) {
        self.projectID = projectID
        self.owner = owner
        self.rootURL = rootURL
        self.environmentID = environmentID
        self.supportDirectory = supportDirectory
        self.contexts = contexts
        self.repository = repository
        self.currentContext = currentContext
        self.authority = authority
        self.shell = shell
        self.gitHub = gitHub
        self.portableResources = portableResources
        self.preparePortableResource = preparePortableResource
        self.renpySDK = renpySDK
        self.narrativeResources = narrativeResources
        self.runtimePacks = runtimePacks
        self.gdevelopSDKRoot = gdevelopSDKRoot
        self.gdevelopExportScript = gdevelopExportScript
        self.licensedDeployment = licensedDeployment
        self.providedTools = providedTools
        self.developerBridge = developerBridge
    }
}

/// Root's single service-owned game execution object. It composes the existing
/// run preparer/Web jobs with the new external-build/CI/build adapters and does
/// not create a second IDE, player, Git layer or file tree.
@MainActor
public final class GameWorkspaceExecutionSession {
    public let preparer: GameUnifiedRunPreparer
    public let webJobs: ExistingWorkspaceGameWebJobs
    private let configuration: GameWorkspaceExecutionConfiguration
    private let buildService: GameExecutionBuildService
    private let runCIExecutor: GameRunCIExecutor?
    private enum CloseState: Equatable { case open, closing, closed }
    private var closeState: CloseState = .open
    /// Once a run-controller drain times out, this execution object cannot
    /// prove that its old task stopped. It never claims a later confirmed close
    /// merely because the reused jobs map is now empty.
    private var runJobsUnconfirmed = false

    public init(configuration: GameWorkspaceExecutionConfiguration) throws {
        let artifacts = configuration.supportDirectory.appendingPathComponent("RunArtifacts", isDirectory: true)
        let records = configuration.supportDirectory.appendingPathComponent("BuildRecords", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)

        let currentContext = configuration.currentContext
        let authorityProvider = configuration.authority
        let provider: GameShellContextProvider = {
            let context = try await currentContext()
            let authority = try await authorityProvider(context)
            return GameShellContext(
                workspaceRoot: context.rootURL,
                guestWorkspaceRoot: "/workspace",
                environmentID: authority.environmentID,
                conversationID: authority.conversationID,
                runID: authority.runID,
                executionBindingGeneration: authority.executionBindingGeneration)
        }
        let contexts = configuration.contexts
        let repository = configuration.repository
        let liveContext: GameRunLiveContextResolver = { context in
            try await contexts.currentContext(for: context)
        }
        let projectInventory: GameRunProjectInventoryProvider = { context in
            let stored = try await repository.open(
                context.projectID, owner: context.owner)
            guard stored.revision == context.savedRevision else {
                throw GameRunPreparationError.selectionContextMismatch
            }
            return try GameRunProjectInventory(
                revision: stored.revision, directories: stored.directories,
                files: stored.files, workspaceRevision: stored.workspaceRevision)
        }
        let portableBridge = GamePortableBuildBridge(configuration: .init(
            shell: configuration.shell, shellContext: provider))
        let exporter = GameBuildExporterBridge(configuration: .init(
            shell: configuration.shell,
            shellContext: provider,
            narrativeResources: configuration.narrativeResources,
            gdevelopSDKRoot: configuration.gdevelopSDKRoot,
            gdevelopExportScript: configuration.gdevelopExportScript,
            portableResources: configuration.portableResources,
            renpySDK: configuration.renpySDK,
            licensedDeployment: configuration.licensedDeployment))

        let ciExecutor: GameRunCIExecutor?
        let sourcePublisher: MainGameBuildSourcePublisher?
        let routingCI: MainRoutingCIJobsPort?
        if let gitHub = configuration.gitHub {
            let transport = MainGitHubActionsTransport(client: gitHub.client)
            let tokens = MainGitHubTokenProvider(store: gitHub.credentials)
            let publisher = MainGameBuildSourcePublisher(
                client: gitHub.client, github: gitHub.service,
                credentials: gitHub.credentials, baseBranch: gitHub.repository.branch)
            ciExecutor = GameRunCIExecutor(configuration: .init(
                transport: transport, tokens: tokens, publisher: publisher,
                repository: gitHub.repository,
                currentContext: liveContext))
            sourcePublisher = publisher
            routingCI = MainRoutingCIJobsPort(
                transport: transport, tokens: tokens, baseRepository: gitHub.repository)
        } else {
            ciExecutor = nil
            sourcePublisher = nil
            routingCI = nil
        }

        let externalProvider = GameRunExternalBuildProvider(configuration: .init(
            shell: configuration.shell,
            authority: configuration.authority,
            godotExecutable: "godot",
            gdevelopSDKRoot: configuration.gdevelopSDKRoot,
            gdevelopExportScript: configuration.gdevelopExportScript,
            licensedDeployment: configuration.licensedDeployment,
            ci: ciExecutor,
            currentContext: liveContext))

        let host = GameBuildHostBridge(shell: configuration.shell, contextProvider: provider)
        self.runCIExecutor = ciExecutor
        self.buildService = try GameExecutionBuildService(configuration: .init(
            projectID: configuration.projectID,
            repository: configuration.repository,
            recordsDirectory: records,
            currentContext: configuration.currentContext,
            host: host as (any GameBuildHostPort)?,
            ci: routingCI.map { $0 as any GameBuildCIJobsPort },
            sourcePublisher: sourcePublisher.map { $0 as any GameBuildSourcePublisherPort },
            repositoryCoordinates: configuration.gitHub?.repository,
            exporter: exporter as (any GameBuildExporterPort)?))

        let runConfiguration = try GameRunPreparationConfiguration(
            artifactDirectory: artifacts,
            narrativeResources: configuration.narrativeResources,
            portableResources: configuration.portableResources,
            preparePortableResource: configuration.preparePortableResource,
            portableBuildPort: portableBridge,
            externalBuildProvider: externalProvider,
            runtimePacks: configuration.runtimePacks,
            contexts: configuration.contexts,
            projectInventory: projectInventory,
            renpySDK: configuration.renpySDK,
            title: "Floe game")
        let preparer = try GameUnifiedRunPreparer(configuration: runConfiguration)
        self.preparer = preparer
        self.webJobs = ExistingWorkspaceGameWebJobs(
            contexts: configuration.contexts,
            preparer: preparer,
            developerBridge: configuration.developerBridge)
        self.configuration = configuration
    }

    /// Existing IDE host callbacks route here. The caller has already saved the
    /// IDE/visual surfaces and validated the workspace/revision.
    public func launch(_ request: GameIDEProjectRunRequest) async throws {
        guard closeState == .open else { throw GameIDEBridgeError.workspaceChanged }
        try await webJobs.launch(request)
    }

    public func stop(_ requestID: UUID) async {
        await webJobs.stop(requestID: requestID)
    }

    public func controller(for requestID: UUID) -> GameProjectRunController? {
        webJobs.controller(for: requestID)
    }

    /// Root passes the validated nested-root selection here and to `build`.
    /// Nil is the unchanged project-root plan; the bridge never guesses.
    public func capabilityPlan(engine: GameEngineID,
                               selection: GameBuildProjectSelection? = nil) async throws -> GameBuildCapabilityPlan {
        try await buildService.capabilityPlan(engine: engine, selection: selection)
    }

    /// The captured paired provider is forwarded separately from the Equatable
    /// build request and is retained by the coordinator/export until done.
    /// Stop/cancel drops the build's own reference, not another build's.
    public func build(_ request: GameExecutionBuildRequest,
                      pairedProvider: (any GameDistributionPairedSourceProvider)? = nil) async throws -> GameBuildOutcome {
        guard closeState == .open else { throw GameIDEBridgeError.workspaceChanged }
        var effective = request
        if effective.providedTools.isEmpty {
            effective = GameExecutionBuildRequest(
                engine: effective.engine,
                selectedRouteIDs: effective.selectedRouteIDs,
                distributionProfileID: effective.distributionProfileID,
                providedTools: configuration.providedTools,
                selection: effective.selection)
        }
        return try await buildService.build(effective, pairedProvider: pairedProvider)
    }

    /// Explicit per-build Stop. The returned outcome is confirmed only after
    /// the exact local task and remote job drained; otherwise the caller keeps
    /// the sheet/session and offers a retry.
    public func cancelBuild(_ buildID: UUID) async -> GameWorkspaceCloseOutcome {
        guard closeState != .closed else { return .confirmed }
        let summary = await buildService.cancelAndDrain(buildID)
        return summary.isConfirmed
            ? .confirmed
            : .unconfirmed(ids: summary.unconfirmedOperationIDs, detail: summary.detail)
    }

    /// Cancel every project build without closing the game session. Used by
    /// the Build sheet's explicit Cancel action.
    public func cancelAllBuilds() async -> GameWorkspaceCloseOutcome {
        let summary = await buildService.cancelAndDrainAll(fenceNewBuilds: false)
        return summary.isConfirmed
            ? .confirmed
            : .unconfirmed(ids: summary.unconfirmedOperationIDs, detail: summary.detail)
    }

    public func activeBuildIDs() async -> Set<UUID> {
        await buildService.activeBuilds()
    }

    public func restoreBuilds() async throws -> [GameBuildRecord] {
        try await buildService.restoredRecords()
    }

    public func deleteBuild(_ buildID: UUID) async throws {
        try await buildService.delete(buildID)
    }

    public func executionMatrix() throws -> [GameEngineExecutionMatrix.Entry] {
        try GameEngineExecutionMatrix.entries()
    }

    /// Begin-close fences new launches/builds before the first await, then
    /// drains owned run jobs, project builds and run-time CI. Any unconfirmed
    /// operation keeps the session open and its leases owned.
    public func close() async -> GameWorkspaceCloseOutcome {
        if closeState == .closed { return .confirmed }
        closeState = .closing
        let webDrained = await drainWebJobs(timeout: .seconds(30))
        if !webDrained { runJobsUnconfirmed = true }
        let buildSummary = await buildService.cancelAndDrainAll(
            fenceNewBuilds: true)
        let ciSummary: GameExecutionDrainSummary
        if let runCIExecutor {
            ciSummary = await runCIExecutor.cancelAndDrainAll()
        } else {
            ciSummary = .confirmed
        }
        guard webDrained, !runJobsUnconfirmed,
              buildSummary.isConfirmed, ciSummary.isConfirmed else {
            var ids = buildSummary.unconfirmedOperationIDs
            ids.append(contentsOf: ciSummary.unconfirmedOperationIDs)
            var details: [String] = []
            if !webDrained { details.append("the owned run controller did not drain") }
            else if runJobsUnconfirmed {
                details.append("a previously unconfirmed run-controller drain remains unresolved")
            }
            if !buildSummary.detail.isEmpty { details.append(buildSummary.detail) }
            if !ciSummary.detail.isEmpty { details.append(ciSummary.detail) }
            return .unconfirmed(ids: ids, detail: details.joined(separator: "; "))
        }
        closeState = .closed
        return .confirmed
    }

    /// Bounded because a run preparer may be waiting on a remote status or a
    /// local exporter that no longer observes cancellation. The exact CI
    /// executor retains its handle, so Close can still be retried.
    private func drainWebJobs(timeout: Duration) async -> Bool {
        let jobs = webJobs
        let task = Task { @MainActor in
            await jobs.close()
        }
        let timeoutTask = Task { try? await Task.sleep(for: timeout) }
        let drained = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await task.value; return true }
            group.addTask { _ = await timeoutTask.value; return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        timeoutTask.cancel()
        return drained
    }
}
#endif
