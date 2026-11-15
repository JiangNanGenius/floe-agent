// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameBuildKit
import FloeGameCore
import FloeGameRunKit

/// CI transport settings for run-time external builds. The transport and token
/// provider are the existing `GameBuildGitHubActionsTransport` /
/// `GameBuildGitHubTokenProvider` seams; the Main binding implements the former
/// over `GitHubActionsClient`.
public struct GameCIExecutionConfiguration: Sendable {
    public let transport: any GameBuildGitHubActionsTransport
    public let tokens: any GameBuildGitHubTokenProvider
    public let publisher: any GameBuildSourcePublisherPort
    /// Owner/repository and the base branch used to create the per-run ref.
    public let repository: GameBuildRepositoryReference
    public let pollInterval: Duration
    public let pollTimeout: Duration
    /// Revalidates the original project/root/revision around publication and
    /// artifact retrieval. Nil is a direct component fixture, never production.
    public let currentContext: GameRunLiveContextResolver?

    public init(transport: any GameBuildGitHubActionsTransport,
                tokens: any GameBuildGitHubTokenProvider,
                publisher: any GameBuildSourcePublisherPort,
                repository: GameBuildRepositoryReference,
                pollInterval: Duration = .seconds(4),
                pollTimeout: Duration = .seconds(45 * 60),
                currentContext: GameRunLiveContextResolver? = nil) {
        self.transport = transport
        self.tokens = tokens
        self.publisher = publisher
        self.repository = repository
        self.pollInterval = pollInterval
        self.pollTimeout = pollTimeout
        self.currentContext = currentContext
    }
}

/// The exact CI artifact produced for each Web-capable engine. The values come
/// from `Resources/Catalog/build-routes.v1.json`; a template that cannot
/// produce the requested target fails before any job is dispatched.
public enum GameCIWebArtifact {
    public static func name(for engine: GameEngineID) -> String? {
        switch engine {
        case .unity: return "unity-web.zip"
        case .godot: return "godot-web.zip"
        case .cocosCreator: return "cocos-web.zip"
        case .gdevelop: return "gdevelop-web.zip"
        case .phaser: return "phaser-web.zip"
        case .kaplay: return "kaplay-web.zip"
        case .babylon: return "babylon-web.zip"
        case .playcanvas: return "playcanvas-web.zip"
        case .wasm4: return "wasm4-web.zip"
        case .rpgMakerMV: return "rpgmakermv-web.zip"
        case .rpgMakerMZ: return "rpgmakermz-web.zip"
        default: return nil
        }
    }

    public static func supportsCIWebBuild(_ engine: GameEngineID) -> Bool {
        switch engine {
        case .unity, .godot, .cocosCreator, .gdevelop, .phaser, .kaplay,
             .babylon, .playcanvas, .wasm4:
            return true
        default:
            return false
        }
    }
}

/// Verified result of one run-time CI build. The provenance came from the
/// reviewed workflow, not from local expectations.
public struct GameRunCIOutcome: Equatable, Sendable {
    public let evidence: [String]
    public let jobID: String
    public let provenance: GameBuildProvenance

    public init(evidence: [String], jobID: String, provenance: GameBuildProvenance) {
        self.evidence = evidence
        self.jobID = jobID
        self.provenance = provenance
    }
}

/// Dispatches one Web-only CI build from the original whole-project source and
/// returns the downloaded, verified artifact directory.
///
/// The existing `GitHubActionsBuildCIAdapter` performs workflow resolution,
/// baseline/trigger/association, provenance verification, artifact download
/// and cancellation. This executor owns the selected-root source publication,
/// target resolution, provenance echo verification and zip extraction.
public actor GameRunCIExecutor {
    private let configuration: GameCIExecutionConfiguration
    private let limits: GameExecutionLimits
    private struct ActiveRun {
        let adapter: GitHubActionsBuildCIAdapter
        let handle: GameCIJobHandle
    }
    private struct RetainedRun {
        let adapter: GitHubActionsBuildCIAdapter
        let handle: GameCIJobHandle
        let detail: String
    }
    private var active: [String: ActiveRun] = [:]
    /// Jobs whose terminal state was not confirmed. The exact adapter/handle is
    /// retained so Stop can be retried without a replacement handle.
    private var retained: [String: RetainedRun] = [:]

    public init(configuration: GameCIExecutionConfiguration,
                limits: GameExecutionLimits = .default) {
        self.configuration = configuration
        self.limits = limits
    }

    public func build(engine: GameEngineID, sourceRoot: URL, revision: String,
                      engineVersion: String?, artifactName: String,
                      expectedEntry: GameRelativePath, outputDirectory: URL,
                      selection: GameRunSourceSelection? = nil) async throws -> GameRunCIOutcome {
        try Task.checkCancellation()
        guard GameCIWebArtifact.supportsCIWebBuild(engine),
              GameCIWebArtifact.name(for: engine) == artifactName else {
            throw GameExecutionError.prerequisite(
                "No reviewed CI Web target is declared for \(engine.rawValue); use its host exporter or editor path.")
        }
        guard let template = GameCIWorkflowTemplates.template(for: engine) else {
            throw GameExecutionError.prerequisite(
                "No reviewed CI workflow template exists for \(engine.rawValue).")
        }
        let sourceSnapshot: GameBuildSourceSnapshot
        if let selection {
            // A generated local copy is not the original source. Publishing it
            // with the original digest would be a false provenance claim.
            do { try selection.requireCIOriginalBytes() }
            catch {
                throw GameExecutionError.prerequisite(String(describing: error))
            }
            let current = try await liveContext(selection.context)
            do { try selection.validate(liveContext: current) }
            catch {
                throw GameExecutionError.prerequisite(String(describing: error))
            }
            do {
                sourceSnapshot = try GameBuildSourceSnapshot(
                    rootURL: selection.context.rootURL,
                    files: selection.inventory.files,
                    directories: selection.inventory.directories,
                    digest: selection.wholeProjectDigest,
                    revision: revision, engine: engine,
                    gameRoot: selection.gameRoot?.value,
                    selectedSourceDigest: selection.selectedSourceDigest)
            } catch {
                throw GameExecutionError.invalidConfiguration(
                    "original project source snapshot: \(error)")
            }
        } else {
            let manifest = try GameWorkspaceTree.manifest(rootURL: sourceRoot, limits: limits)
            guard !manifest.files.isEmpty else {
                throw GameExecutionError.invalidConfiguration("source snapshot is empty")
            }
            sourceSnapshot = try GameBuildSourceSnapshot(
                rootURL: sourceRoot, files: manifest.files, directories: manifest.directories,
                digest: manifest.digest, revision: revision, engine: engine)
        }

        let runIdentity = UUID().uuidString.lowercased()
        let runBranch = "floe-game-" + runIdentity
        let runReference: GameBuildRepositoryReference
        do {
            runReference = try GameBuildRepositoryReference(
                owner: configuration.repository.owner,
                repository: configuration.repository.repository,
                branch: runBranch)
        } catch {
            throw GameExecutionError.invalidConfiguration("run branch \(runBranch)")
        }

        // The publisher creates the immutable run ref from its configured base
        // branch. Never fabricate a branch/commit locally.
        let published = try await configuration.publisher.publish(
            sourceSnapshot, owner: runReference.owner,
            repository: runReference.repository, branch: runReference.branch)
        guard published.manifestDigest == sourceSnapshot.digest,
              published.revision == revision,
              published.gameRoot == sourceSnapshot.gameRoot,
              published.selectedSourceDigest == sourceSnapshot.selectedSourceDigest else {
            throw GameExecutionError.artifactInvalid(
                "source publisher returned a different project, revision or selected game root")
        }
        if let selection {
            try Task.checkCancellation()
            let current = try await liveContext(selection.context)
            do { try selection.validate(liveContext: current) }
            catch {
                throw GameExecutionError.prerequisite(String(describing: error))
            }
        }

        let transport = GameBuildSourceTransport.repositorySnapshot(published)
        let inputs = transport.dispatchInputs(engine: engine, engineVersion: engineVersion)
        let targetSelection: GameCIWorkflowTargetSelection
        do {
            targetSelection = try template.selection(
                forRequestedArtifacts: [artifactName], inputs: inputs)
        } catch {
            throw GameExecutionError.prerequisite(
                "The \(template.id) template cannot produce \(artifactName): \(error)")
        }
        // The workflow must be dispatched from the configured base branch;
        // the immutable run commit is still passed as the exact source.
        let adapter = GitHubActionsBuildCIAdapter(
            transport: configuration.transport,
            tokens: configuration.tokens,
            repository: configuration.repository,
            expectedArtifacts: [artifactName],
            pollInterval: Self.seconds(configuration.pollInterval))
        try Task.checkCancellation()
        let handle = try await adapter.dispatch(
            template: template,
            source: transport,
            engineVersion: engineVersion,
            targets: targetSelection)
        active[handle.jobID] = .init(adapter: adapter, handle: handle)

        do {
            let status = try await poll(adapter: adapter, handle: handle)
            guard case .succeeded = status.state else {
                throw GameExecutionError.commandFailed("CI did not report success for \(artifactName)")
            }
            try Task.checkCancellation()
            // Verify the exact workflow-returned provenance before downloading
            // any output: schema, source, selected root, job id, template,
            // source transport, target set and artifact set.
            let provenanceData = try await adapter.artifact(
                handle, named: GameBuildCILimits.provenanceArtifactName)
            let provenance: GameBuildProvenance
            do {
                provenance = try JSONDecoder().decode(GameBuildProvenance.self, from: provenanceData)
                try provenance.verify(
                    sourceDigest: sourceSnapshot.digest, revision: revision,
                    engine: engine.rawValue, gameRoot: sourceSnapshot.gameRoot,
                    selectedSourceDigest: sourceSnapshot.selectedSourceDigest)
                try provenance.verifyJob(jobID: handle.jobID)
                try provenance.verifySourceTransport("repository")
                try provenance.verifyTemplate(template.id)
                try provenance.verifyArtifactSet([artifactName])
                try provenance.verifyTargets(targetSelection.targetIDSet)
            } catch {
                throw GameExecutionError.artifactInvalid(
                    "CI provenance does not match the dispatched source, job or targets: \(error)")
            }
            try Task.checkCancellation()
            let data = try await adapter.artifact(handle, named: artifactName)
            try Task.checkCancellation()
            try await extractVerifiedWebBundle(
                data, name: artifactName, expectedEntry: expectedEntry,
                outputDirectory: outputDirectory)
            if let selection {
                let current = try await liveContext(selection.context)
                do { try selection.validate(liveContext: current) }
                catch {
                    throw GameExecutionError.prerequisite(String(describing: error))
                }
            }
            active.removeValue(forKey: handle.jobID)
            let rootValue = sourceSnapshot.gameRoot ?? ""
            let selectedValue = sourceSnapshot.selectedSourceDigest ?? ""
            return .init(
                evidence: [
                    "ci-run:\(handle.jobID)",
                    "ci-source:\(sourceSnapshot.digest)",
                    "ci-game-root:\(rootValue.isEmpty ? "." : rootValue)",
                    "ci-selected-source:\(selectedValue.isEmpty ? sourceSnapshot.digest : selectedValue)",
                    "ci-artifact:\(artifactName)"
                ],
                jobID: handle.jobID, provenance: provenance)
        } catch is CancellationError {
            let receipt = await drain(adapter: adapter, handle: handle,
                                      timeout: min(configuration.pollTimeout, .seconds(60)))
            if receipt.isConfirmed {
                active.removeValue(forKey: handle.jobID)
                retained.removeValue(forKey: handle.jobID)
                throw CancellationError()
            }
            active.removeValue(forKey: handle.jobID)
            retained[handle.jobID] = .init(adapter: adapter, handle: handle,
                                           detail: receipt.detail)
            throw GameExecutionError.cancellationUnconfirmed(receipt.detail)
        } catch let error as GameExecutionError {
            switch error {
            case .cancellationUnconfirmed(let detail), .outcomeUnconfirmed(let detail):
                active.removeValue(forKey: handle.jobID)
                retained[handle.jobID] = .init(adapter: adapter, handle: handle,
                                               detail: detail)
                throw error
            default:
                active.removeValue(forKey: handle.jobID)
                throw error
            }
        } catch {
            active.removeValue(forKey: handle.jobID)
            throw error
        }
    }

    /// Cancels and drains every run still owned by this executor. A job whose
    /// terminal state is not confirmed stays retained for a retry.
    public func cancelAndDrainAll(timeout: Duration? = nil) async -> GameExecutionDrainSummary {
        let handleTimeout = timeout ?? min(configuration.pollTimeout, .seconds(60))
        let ids = Set(active.keys).union(retained.keys).sorted()
        var failures: [String] = []
        var details: [String] = []
        for id in ids {
            let run: ActiveRun
            if let value = active[id] {
                run = value
            } else if let value = retained[id] {
                run = .init(adapter: value.adapter, handle: value.handle)
            } else {
                continue
            }
            let receipt = await drain(adapter: run.adapter, handle: run.handle,
                                      timeout: handleTimeout)
            if receipt.isConfirmed {
                active.removeValue(forKey: id)
                retained.removeValue(forKey: id)
            } else {
                active.removeValue(forKey: id)
                retained[id] = .init(adapter: run.adapter, handle: run.handle,
                                     detail: receipt.detail)
                failures.append("ci:\(id)")
                if !receipt.detail.isEmpty { details.append(receipt.detail) }
            }
        }
        if failures.isEmpty { return .confirmed }
        return .unconfirmed(ids: failures, detail: details.joined(separator: "; "))
    }

    public func retainedRunIDs() -> [String] { retained.keys.sorted() }

    private func poll(adapter: GitHubActionsBuildCIAdapter,
                      handle: GameCIJobHandle) async throws -> GameCIJobStatus {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: configuration.pollTimeout)
        var lastStatusError: String?
        while clock.now < deadline {
            try Task.checkCancellation()
            let status: GameCIJobStatus
            do {
                status = try await adapter.status(handle)
            } catch {
                lastStatusError = String(describing: error)
                try await Task.sleep(for: configuration.pollInterval)
                continue
            }
            switch status.state {
            case .succeeded, .failed, .cancelled:
                return status
            case .queued, .running:
                try await Task.sleep(for: configuration.pollInterval)
            }
        }
        _ = try? await adapter.cancel(handle)
        var detail = "CI build exceeded \(configuration.pollTimeout) without a terminal state"
        if let lastStatusError { detail += "; last status error: \(lastStatusError)" }
        throw GameExecutionError.outcomeUnconfirmed(detail)
    }

    private func drain(adapter: GitHubActionsBuildCIAdapter,
                       handle: GameCIJobHandle,
                       timeout: Duration) async
        -> (isConfirmed: Bool, terminalState: GameCIJobState?, detail: String) {
        var cancelError: String?
        do { try await adapter.cancel(handle) }
        catch { cancelError = String(describing: error) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastState: GameCIJobState?
        var lastStatusError: String?
        while clock.now < deadline {
            do {
                let status = try await adapter.status(handle)
                lastState = status.state
                switch status.state {
                case .succeeded, .failed, .cancelled:
                    return (true, status.state, "CI job \(handle.jobID) reached a terminal state")
                case .queued, .running:
                    break
                }
            } catch {
                lastStatusError = String(describing: error)
            }
            try? await Task.sleep(for: configuration.pollInterval)
        }
        var parts = ["CI job \(handle.jobID) did not reach a terminal state"]
        if let cancelError { parts.append("cancel failed: \(cancelError)") }
        if let lastState { parts.append("last state: \(String(describing: lastState))") }
        if let lastStatusError { parts.append("last status error: \(lastStatusError)") }
        return (false, lastState, parts.joined(separator: "; "))
    }

    private func liveContext(_ captured: GameProjectContext) async throws -> GameProjectContext {
        guard let currentContext = configuration.currentContext else { return captured }
        return try await currentContext(captured)
    }

    private func extractVerifiedWebBundle(_ data: Data, name: String,
                                          expectedEntry: GameRelativePath,
                                          outputDirectory: URL) async throws {
        guard !data.isEmpty else {
            throw GameExecutionError.artifactInvalid("CI artifact \(name) is empty")
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-game-ci-" + UUID().uuidString.lowercased(), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let archive = temporary.appendingPathComponent("artifact.zip")
        try data.write(to: archive, options: .withoutOverwriting)
        let unpacked = temporary.appendingPathComponent("unpacked", isDirectory: true)
        let exchange = GameArchiveExchange()
        _ = try exchange.extract(archive: archive, to: unpacked, rootChoice: .asIs)
        let manifest = try GameWorkspaceTree.manifest(
            rootURL: unpacked, limits: limits, excludedDirectoryNames: [])
        let indexes = manifest.files.filter {
            $0.path.value == expectedEntry.value || $0.path.value.hasSuffix("/" + expectedEntry.value)
        }
        guard !indexes.isEmpty else {
            throw GameExecutionError.artifactInvalid("CI artifact \(name) has no \(expectedEntry.value)")
        }
        let chosen = indexes.min { lhs, rhs in
            lhs.path.value.split(separator: "/").count < rhs.path.value.split(separator: "/").count
        }!
        let parentComponents = chosen.path.value.split(separator: "/").dropLast()
        let parent = parentComponents.reduce(unpacked) { url, component in
            url.appendingPathComponent(String(component))
        }
        try GameWorkspaceTree.publishContents(
            of: parent, to: outputDirectory, expectedEntry: expectedEntry, limits: limits)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
