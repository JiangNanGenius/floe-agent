// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import FloeGameCore

public struct GameBuildCIWorkflowRef: Codable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let path: String
    public init(id: Int64, name: String, path: String) {
        self.id = id; self.name = name; self.path = path
    }
}

public struct GameBuildCIRun: Codable, Equatable, Sendable {
    public let id: Int64
    public let workflowID: Int64
    public let status: String
    public let conclusion: String?
    public let headSHA: String
    public let headBranch: String?
    public let event: String
    public let createdAt: Date
    public let htmlURL: URL?

    public init(id: Int64, workflowID: Int64, status: String, conclusion: String?,
                headSHA: String, headBranch: String?, event: String,
                createdAt: Date, htmlURL: URL?) {
        self.id = id; self.workflowID = workflowID; self.status = status
        self.conclusion = conclusion; self.headSHA = headSHA; self.headBranch = headBranch
        self.event = event; self.createdAt = createdAt; self.htmlURL = htmlURL
    }

    public var isTerminal: Bool { status == "completed" || conclusion != nil }
    public var succeeded: Bool { conclusion == "success" }
}

public struct GameBuildCIArtifact: Codable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let sizeInBytes: Int64
    public let expired: Bool
    /// API-attested digest (`sha256:<hex>`) when the server returns one.
    public let digest: String?

    public init(id: Int64, name: String, sizeInBytes: Int64, expired: Bool, digest: String? = nil) {
        self.id = id; self.name = name; self.sizeInBytes = sizeInBytes
        self.expired = expired; self.digest = digest
    }
}

public struct GameBuildCIDispatchBaseline: Equatable, Sendable {
    public let runIDs: Set<Int64>
    public let capturedAt: Date
    public init(runIDs: Set<Int64>, capturedAt: Date) {
        self.runIDs = runIDs; self.capturedAt = capturedAt
    }
}

public struct GameBuildCITrigger: Equatable, Sendable {
    public let runID: Int64?
    public let htmlURL: URL?
    public init(runID: Int64?, htmlURL: URL?) {
        self.runID = runID; self.htmlURL = htmlURL
    }
}

/// The host implements this over the existing GitHub Actions client/transport.
/// No credential value or access-bearing URL is stored in a plan.
public protocol GameBuildGitHubActionsTransport: Sendable {
    func workflows(owner: String, repository: String, token: String) async throws -> [GameBuildCIWorkflowRef]
    func workflowRuns(owner: String, repository: String, workflowID: Int64,
                      branch: String, event: String, token: String) async throws -> [GameBuildCIRun]
    func run(owner: String, repository: String, runID: Int64, token: String) async throws -> GameBuildCIRun
    func artifacts(owner: String, repository: String, runID: Int64, token: String) async throws -> [GameBuildCIArtifact]
    func downloadArtifact(owner: String, repository: String, runID: Int64,
                          artifactID: Int64, token: String, maximumBytes: Int) async throws -> Data
    func triggerDispatch(owner: String, repository: String, workflowID: Int64,
                         ref: String, inputs: [String: String], token: String) async throws -> GameBuildCITrigger
    func cancelRun(owner: String, repository: String, runID: Int64, token: String) async throws
}

public protocol GameBuildGitHubTokenProvider: Sendable {
    func token() async throws -> String?
}

/// Metadata only. The value lives in the existing credential store.
public struct GameBuildCredentialReference: Codable, Equatable, Sendable {
    public let service: String
    public let account: String
    public init(service: String, account: String) {
        self.service = service; self.account = account
    }
}

public enum GameBuildCIError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case transport(String)
    case http(Int)
    case association(String)
    case artifact(String)
    case provenance(String)
    case cancelled
    case unsupportedTransport
}

public enum GameBuildCILimits {
    public static let maximumArtifactBytes = 512 * 1024 * 1024
    public static let provenanceArtifactName = "floe-build-provenance"
    public static let maximumAttempts = 20
    public static let associationSkew: TimeInterval = 180
}

/// Concrete adapter over an injected host GitHub Actions transport. It performs
/// the real workflow resolution, baseline/trigger/association, provenance and
/// artifact verification, cross-run source-artifact identity check and cancel
/// logic. The only fakes in tests are the caller's transport/token seams.
public actor GitHubActionsBuildCIAdapter: GameBuildCISourceJobsPort {
    private let transport: any GameBuildGitHubActionsTransport
    private let tokens: any GameBuildGitHubTokenProvider
    private let repository: GameBuildRepositoryReference

    private struct Active {
        let runID: Int64
        let source: GameBuildSourceTransport
        let template: GameCIWorkflowTemplate
        let targets: GameCIWorkflowTargetSelection
        let expectedArtifacts: Set<String>
    }
    private var active: [String: Active] = [:]
    private let expectedArtifacts: Set<String>
    private let workflowPath: String?
    private let maximumAttempts: Int
    private let pollInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(transport: any GameBuildGitHubActionsTransport,
                tokens: any GameBuildGitHubTokenProvider,
                repository: GameBuildRepositoryReference,
                workflowPath: String? = nil,
                expectedArtifacts: [String],
                maximumAttempts: Int = GameBuildCILimits.maximumAttempts,
                pollInterval: TimeInterval = 3,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
                    guard seconds > 0 else { return }
                    try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                }) {
        self.transport = transport
        self.tokens = tokens
        self.repository = repository
        self.workflowPath = workflowPath
        self.expectedArtifacts = Set(expectedArtifacts + [GameBuildCILimits.provenanceArtifactName])
        self.maximumAttempts = max(maximumAttempts, 1)
        self.pollInterval = max(pollInterval, 0)
        self.now = now
        self.sleep = sleep
    }

    // MARK: Legacy digest-only dispatch

    public func dispatch(template: GameCIWorkflowTemplate, sourceDigest: String,
                         revision: String, engineVersion: String?) async throws -> GameCIJobHandle {
        throw GameBuildCIError.unsupportedTransport
    }

    // MARK: Source-aware dispatch

    public func dispatch(template: GameCIWorkflowTemplate,
                         source: GameBuildSourceTransport,
                         engineVersion: String?) async throws -> GameCIJobHandle {
        let inputs = source.dispatchInputs(engine: template.engine, engineVersion: engineVersion)
        let legacy = expectedArtifacts.subtracting([GameBuildCILimits.provenanceArtifactName])
        let selection: GameCIWorkflowTargetSelection
        do {
            let resolved = try resolvedConfiguredArtifacts(template: template, artifacts: legacy, inputs: inputs)
            if resolved.isEmpty {
                selection = try template.defaultSelection(inputs: inputs)
            } else {
                selection = try template.selection(forRequestedArtifacts: resolved, inputs: inputs)
            }
        } catch let error as GameCIWorkflowError {
            throw GameBuildCIError.invalidConfiguration("requested targets are not supported: \(error)")
        }
        return try await dispatch(template: template, source: source,
                                  engineVersion: engineVersion, targets: selection)
    }

    public func dispatch(template: GameCIWorkflowTemplate,
                         source: GameBuildSourceTransport,
                         engineVersion: String?,
                         targets: GameCIWorkflowTargetSelection) async throws -> GameCIJobHandle {
        guard template.sourceTransportKinds.contains(source.kind) else {
            throw GameBuildCIError.unsupportedTransport
        }
        guard !targets.isEmpty else {
            throw GameBuildCIError.invalidConfiguration("at least one requested target is required")
        }
        let known = Set(template.targets.map(\.id))
        guard targets.targetIDSet.isSubset(of: known) else {
            throw GameBuildCIError.invalidConfiguration("requested target is not declared by the template")
        }
        let baseInputs = source.dispatchInputs(engine: template.engine, engineVersion: engineVersion)
        var expected = Set<String>()
        for id in targets.targetIDs {
            guard let target = template.targets.first(where: { $0.id == id }) else {
                throw GameBuildCIError.invalidConfiguration("unknown target \(id)")
            }
            for raw in target.artifacts {
                do {
                    expected.insert(try template.resolvedArtifactName(raw, inputs: baseInputs))
                } catch {
                    throw GameBuildCIError.invalidConfiguration("unresolved target artifact \(raw)")
                }
            }
        }
        guard expected == targets.artifactSet else {
            throw GameBuildCIError.invalidConfiguration("target selection artifact set is inconsistent")
        }
        let legacy = expectedArtifacts.subtracting([GameBuildCILimits.provenanceArtifactName])
        let configured: GameCIWorkflowTargetSelection
        do {
            let resolved = try resolvedConfiguredArtifacts(template: template, artifacts: legacy, inputs: baseInputs)
            configured = try configuredTargets(template: template, artifacts: resolved, inputs: baseInputs)
        } catch {
            throw GameBuildCIError.invalidConfiguration("the adapter's configured artifacts do not match a target")
        }
        guard targets.targetIDSet.isSubset(of: configured.targetIDSet) else {
            throw GameBuildCIError.invalidConfiguration("target selection is outside the adapter's configured targets")
        }
        let token = try await requireToken()
        let workflow = try await resolveWorkflow(template: template, token: token)
        let baseline = try await dispatchBaseline(workflow: workflow, token: token)
        let inputs = source.dispatchInputs(engine: template.engine, engineVersion: engineVersion,
                                           targets: targets)
        let trigger: GameBuildCITrigger
        do {
            trigger = try await transport.triggerDispatch(
                owner: repository.owner, repository: repository.repository,
                workflowID: workflow.id, ref: repository.branch,
                inputs: inputs, token: token)
        } catch {
            throw GameBuildCIError.transport("workflow dispatch was not acknowledged")
        }
        let run = try await associateRun(template: template, workflow: workflow,
                                         trigger: trigger, baseline: baseline,
                                         source: source, token: token)
        let handle = GameCIJobHandle(jobID: String(run.id), runURL: run.htmlURL)
        active[handle.jobID] = .init(runID: run.id, source: source, template: template,
                                     targets: targets, expectedArtifacts: targets.artifactSet)
        return handle
    }

    public func status(_ handle: GameCIJobHandle) async throws -> GameCIJobStatus {
        guard let entry = active[handle.jobID] else {
            throw GameBuildCIError.invalidConfiguration("unknown run handle")
        }
        let token = try await requireToken()
        let run = try await fetchRun(runID: entry.runID, token: token)
        if run.conclusion == "cancelled" {
            return .init(handle: handle, state: .cancelled)
        }
        if run.isTerminal && !run.succeeded {
            return .init(handle: handle, state: .failed(run.conclusion ?? "failed"))
        }
        guard run.succeeded else {
            return .init(handle: handle, state: run.isTerminal ? .failed("unexpected state") : .running)
        }
        do {
            let provenance = try await fetchProvenance(runID: run.id, token: token)
            guard provenance.sourceSHA256 == entry.source.digest,
                  provenance.sourceRevision == (entry.source.revision ?? ""),
                  provenance.engine == entry.template.engine.rawValue,
                  provenance.template == entry.template.id else {
                return .init(handle: handle, state: .failed("stale provenance"), sourceDigest: provenance.sourceSHA256,
                             revision: provenance.sourceRevision)
            }
            do {
                try provenance.verifySelection(gameRoot: entry.source.gameRoot,
                                               selectedSourceDigest: entry.source.selectedSourceDigest)
                try provenance.verifyJob(jobID: String(entry.runID))
                try provenance.verifySourceTransport(
                    entry.source.kind == .repositorySnapshot ? "repository" : "artifact")
                try provenance.verifyArtifactSet(entry.expectedArtifacts)
                try provenance.verifyTargets(entry.targets.targetIDSet)
            } catch {
                return .init(handle: handle, state: .failed("provenance does not match the requested targets or selected game root"),
                             sourceDigest: provenance.sourceSHA256, revision: provenance.sourceRevision)
            }
            return .init(handle: handle, state: .succeeded,
                         sourceDigest: provenance.sourceSHA256, revision: provenance.sourceRevision)
        } catch {
            return .init(handle: handle, state: .failed("provenance missing or invalid"))
        }
    }

    public func artifact(_ handle: GameCIJobHandle, named: String) async throws -> Data {
        guard let entry = active[handle.jobID] else {
            throw GameBuildCIError.invalidConfiguration("unknown run handle")
        }
        guard entry.expectedArtifacts.contains(named)
                || named == GameBuildCILimits.provenanceArtifactName else {
            throw GameBuildCIError.artifact("artifact is not part of the requested target: \(named)")
        }
        let token = try await requireToken()
        let artifacts = try await transport.artifacts(
            owner: repository.owner, repository: repository.repository,
            runID: entry.runID, token: token)
        guard let artifact = artifacts.first(where: { $0.name == named }) else {
            throw GameBuildCIError.artifact("artifact not found: \(named)")
        }
        guard !artifact.expired, artifact.sizeInBytes > 0,
              artifact.sizeInBytes <= Int64(GameBuildCILimits.maximumArtifactBytes) else {
            throw GameBuildCIError.artifact("artifact is expired, empty or too large: \(named)")
        }
        let wrapper = try await transport.downloadArtifact(
            owner: repository.owner, repository: repository.repository,
            runID: entry.runID, artifactID: artifact.id, token: token,
            maximumBytes: min(GameBuildCILimits.maximumArtifactBytes, Int(artifact.sizeInBytes) + 1))
        guard wrapper.count == Int(artifact.sizeInBytes) else {
            throw GameBuildCIError.artifact("artifact size changed: \(named)")
        }
        if let attested = artifact.digest, attested.hasPrefix("sha256:") {
            let expected = String(attested.dropFirst("sha256:".count)).lowercased()
            guard GameDataDigest.hex(wrapper) == expected else {
                throw GameBuildCIError.artifact("artifact digest mismatch: \(named)")
            }
        }
        return try unwrapArtifactPayload(wrapper, expectedName: named)
    }

    public func cancel(_ handle: GameCIJobHandle) async throws {
        guard let entry = active[handle.jobID] else { return }
        let token = try await requireToken()
        do {
            try await transport.cancelRun(owner: repository.owner, repository: repository.repository,
                                          runID: entry.runID, token: token)
        } catch {
            throw GameBuildCIError.transport("cancel request failed")
        }
    }

    /// Cross-run source verification: the adapter lists the explicitly named
    /// run/artifact, checks size/expiry and (when the server attests) digest,
    /// then downloads and hashes the bytes. It never adopts the newest run.
    public func verifyExistingArtifact(_ reference: GameBuildRemoteArtifactReference) async throws -> GameBuildArtifactIdentity {
        let token = try await requireToken()
        let artifacts = try await transport.artifacts(
            owner: reference.owner, repository: reference.repository,
            runID: reference.runID, token: token)
        guard let artifact = artifacts.first(where: { $0.id == reference.artifactID && $0.name == reference.name }) else {
            throw GameBuildCIError.artifact("source artifact identity not found")
        }
        guard !artifact.expired, artifact.sizeInBytes > 0 else {
            throw GameBuildCIError.artifact("source artifact is expired or empty")
        }
        let wrapper = try await transport.downloadArtifact(
            owner: reference.owner, repository: reference.repository,
            runID: reference.runID, artifactID: artifact.id, token: token,
            maximumBytes: GameBuildCILimits.maximumArtifactBytes)
        let payload = try unwrapArtifactPayload(wrapper, expectedName: reference.name)
        let candidate = GameDataDigest.hex(payload) == reference.sha256 ? payload : wrapper
        guard candidate.count == reference.bytes,
              GameDataDigest.hex(candidate) == reference.sha256 else {
            throw GameBuildCIError.artifact("source artifact digest mismatch")
        }
        return .init(name: reference.name, sha256: reference.sha256, bytes: reference.bytes,
                     runID: reference.runID, artifactID: reference.artifactID,
                     sourceDigest: reference.sourceDigest, revision: reference.revision ?? "",
                     engine: "", templateID: "source-transport", expired: false,
                     gameRoot: reference.gameRoot,
                     selectedSourceDigest: reference.selectedSourceDigest)
    }

    // MARK: Resolution and association

    /// Resolve contract placeholders in the adapter's legacy configured
    /// artifact names so a host may pass the template's raw artifact list.
    private func resolvedConfiguredArtifacts(template: GameCIWorkflowTemplate,
                                             artifacts: Set<String>,
                                             inputs: [String: String]) throws -> Set<String> {
        var resolved = Set<String>()
        for name in artifacts {
            resolved.insert(try template.resolvedArtifactName(name, inputs: inputs))
        }
        return resolved
    }

    /// The targets covering the adapter's configured artifact allow-list. An
    /// explicit selection may narrow this set (Web-only) but may not add a
    /// target the host did not configure. Same-target extras (the Cocos native
    /// project plus APK) remain atomic and are permitted.
    private func configuredTargets(template: GameCIWorkflowTemplate,
                                   artifacts: Set<String>,
                                   inputs: [String: String]) throws -> GameCIWorkflowTargetSelection {
        if artifacts.isEmpty {
            return try template.defaultSelection(inputs: inputs)
        }
        return try template.selection(forRequestedArtifacts: artifacts, inputs: inputs)
    }

    private func resolveWorkflow(template: GameCIWorkflowTemplate, token: String) async throws -> GameBuildCIWorkflowRef {
        let workflows = try await transport.workflows(owner: repository.owner,
                                                     repository: repository.repository, token: token)
        if let workflowPath {
            guard let match = workflows.first(where: { $0.path == workflowPath }) else {
                throw GameBuildCIError.invalidConfiguration("workflow \(workflowPath) is not registered on the default branch")
            }
            return match
        }
        guard let match = workflows.first(where: { $0.path.hasSuffix("/" + template.fileName) }) else {
            throw GameBuildCIError.invalidConfiguration("workflow \(template.fileName) is not registered on the default branch")
        }
        return match
    }

    /// GitHub returns an artifact archive containing the uploaded path. The
    /// coordinator needs the actual uploaded file (web zip, APK, provenance or
    /// source zip), not the wrapper. This unwraps the wrapper through the
    /// reviewed archive exchange; a direct raw artifact is accepted only when
    /// it already has the expected shape.
    private func unwrapArtifactPayload(_ data: Data, expectedName: String) throws -> Data {
        guard data.starts(with: [0x50, 0x4b]) else { return data }
        let names = (try? GameZIPEntryReader.entryNames(in: data)) ?? []
        let hasExpected = names.contains { $0 == expectedName || $0.hasSuffix("/" + expectedName) }
        if !hasExpected {
            if expectedName.hasSuffix(".zip"),
               names.contains(where: { $0.hasSuffix(".html") || $0.hasSuffix("AndroidManifest.xml") || $0.hasSuffix("project.pbxproj") }) {
                return data
            }
            if names.contains(where: { $0.hasSuffix("/" + expectedName) || $0.hasSuffix(expectedName) }) {
                // fall through to extraction
            } else if !expectedName.contains(".") || expectedName == "floe-game-source" {
                // source artifact wrappers contain source.zip
            } else {
                return data
            }
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-ci-artifact-" + UUID().uuidString.lowercased())
        let archive = temporary.appendingPathComponent("artifact.zip")
        let payload = temporary.appendingPathComponent("payload")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            try data.write(to: archive)
            let limits = try? GameArchiveExchangeLimits(
                maximumFileBytes: 256 * 1_024 * 1_024,
                maximumProjectBytes: 256 * 1_024 * 1_024,
                maximumEntries: 20_000, maximumDepth: 48)
            _ = try GameArchiveExchange(limits: limits).extract(archive: archive, to: payload)
            let files = try FileManager.default.subpathsOfDirectory(atPath: payload.path)
                .map { payload.appendingPathComponent($0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .filter { url in
                    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else { return true }
                    return values.isDirectory != true
                }
            let candidate: URL?
            if let exact = files.first(where: { $0.lastPathComponent == expectedName }) {
                candidate = exact
            } else if expectedName == "floe-game-source" {
                let zips = files.filter { $0.pathExtension.lowercased() == "zip" }
                candidate = zips.count == 1 ? zips[0] : nil
            } else if expectedName == "floe-build-provenance" {
                candidate = files.first { $0.pathExtension.lowercased() == "json" }
            } else {
                candidate = nil
            }
            guard let candidate else {
                throw GameBuildCIError.artifact("artifact archive does not contain \(expectedName)")
            }
            return try Data(contentsOf: candidate)
        } catch let error as GameBuildCIError {
            throw error
        } catch {
            throw GameBuildCIError.artifact("artifact archive could not be read")
        }
    }

    private func dispatchBaseline(workflow: GameBuildCIWorkflowRef,
                                  token: String) async throws -> GameBuildCIDispatchBaseline {
        let runs = try await transport.workflowRuns(
            owner: repository.owner, repository: repository.repository,
            workflowID: workflow.id, branch: repository.branch,
            event: "workflow_dispatch", token: token)
        return .init(runIDs: Set(runs.map(\.id)), capturedAt: now())
    }

    private func associateRun(template: GameCIWorkflowTemplate, workflow: GameBuildCIWorkflowRef,
                              trigger: GameBuildCITrigger, baseline: GameBuildCIDispatchBaseline,
                              source: GameBuildSourceTransport, token: String) async throws -> GameBuildCIRun {
        if let runID = trigger.runID {
            let run = try await fetchRun(runID: runID, token: token)
            guard run.workflowID == workflow.id, run.event == "workflow_dispatch",
                  run.headBranch == repository.branch else {
                throw GameBuildCIError.association("returned run does not match this dispatch")
            }
            if let commit = source.commitSHA, run.headSHA != commit {
                throw GameBuildCIError.association("returned run does not carry the source commit")
            }
            return run
        }
        let cutoff = baseline.capturedAt.addingTimeInterval(-GameBuildCILimits.associationSkew)
        for attempt in 0..<maximumAttempts {
            if attempt > 0 { try await sleep(pollInterval) }
            let runs = try await transport.workflowRuns(
                owner: repository.owner, repository: repository.repository,
                workflowID: workflow.id, branch: repository.branch,
                event: "workflow_dispatch", token: token)
            let matches = runs.filter { run in
                !baseline.runIDs.contains(run.id)
                    && run.workflowID == workflow.id
                    && run.event == "workflow_dispatch"
                    && (run.headBranch == nil || run.headBranch == repository.branch)
                    && run.createdAt >= cutoff
                    && (source.commitSHA == nil || run.headSHA == source.commitSHA)
            }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 {
                throw GameBuildCIError.association("multiple runs matched this dispatch")
            }
        }
        throw GameBuildCIError.association("no run matched this dispatch within the bound")
    }

    private func fetchRun(runID: Int64, token: String) async throws -> GameBuildCIRun {
        do {
            return try await transport.run(owner: repository.owner,
                                           repository: repository.repository,
                                           runID: runID, token: token)
        } catch {
            throw GameBuildCIError.transport("run lookup failed")
        }
    }

    private func fetchProvenance(runID: Int64, token: String) async throws -> GameBuildProvenance {
        let artifacts = try await transport.artifacts(
            owner: repository.owner, repository: repository.repository,
            runID: runID, token: token)
        guard let provenance = artifacts.first(where: { $0.name == GameBuildCILimits.provenanceArtifactName }),
              !provenance.expired, provenance.sizeInBytes > 0,
              provenance.sizeInBytes <= 1_048_576 else {
            throw GameBuildCIError.provenance("provenance artifact missing")
        }
        let wrapper = try await transport.downloadArtifact(
            owner: repository.owner, repository: repository.repository,
            runID: runID, artifactID: provenance.id, token: token,
            maximumBytes: 1_048_576)
        let data = try unwrapArtifactPayload(wrapper, expectedName: "floe-build-provenance.json")
        return try JSONDecoder().decode(GameBuildProvenance.self, from: data)
    }

    private func requireToken() async throws -> String {
        guard let token = try await tokens.token(), !token.isEmpty else {
            throw GameBuildCIError.invalidConfiguration("connect GitHub in the existing credential settings")
        }
        return token
    }
}

/// A small digest helper kept local so the adapter has no dependency on a UI
/// or workspace module.
enum GameDataDigest {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
