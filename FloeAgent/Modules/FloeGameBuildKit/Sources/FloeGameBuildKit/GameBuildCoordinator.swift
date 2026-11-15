// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public enum GameBuildError: Error, Equatable, Sendable {
    case staleBinding(expected: String, actual: String)
    case prerequisiteMissing([String])
    case missingCI
    case missingHost
    case dispatchFailed(String)
    case staleResult(expectedDigest: String, actualDigest: String?)
    case artifactMissing(String)
    case artifactInvalid(String)
    case unsupportedTarget(String)
    case distribution(String)
    case buildActive
    case cancelled
    /// Cancellation was requested but the remote job did not reach a terminal
    /// state. The coordinator retains the exact handle for a retry.
    case cancellationUnconfirmed(String)
    /// A status read or poll timed out while the remote job may still be
    /// running. This is not a terminal failure.
    case outcomeUnconfirmed(String)
    case selectionInvalid(String)
    case io(String)
}

/// Confirmed vs. explicitly unconfirmed drain outcomes. A value with
/// `confirmed == false` always retains ownership of the exact job.
public enum GameBuildDrainState: String, Equatable, Sendable {
    case confirmed
    case unconfirmed
}

public struct GameBuildDrainReceipt: Equatable, Sendable {
    public let buildIDs: [UUID]
    public let state: GameBuildDrainState
    public let jobID: String?
    public let terminalState: GameCIJobState?
    public let detail: String

    public init(buildIDs: [UUID], state: GameBuildDrainState,
                jobID: String? = nil, terminalState: GameCIJobState? = nil,
                detail: String = "") {
        self.buildIDs = buildIDs
        self.state = state
        self.jobID = jobID
        self.terminalState = terminalState
        self.detail = detail
    }

    public var isConfirmed: Bool { state == .confirmed }

    public static func confirmed(buildIDs: [UUID] = [], jobID: String? = nil,
                                 terminalState: GameCIJobState? = nil,
                                 detail: String = "") -> GameBuildDrainReceipt {
        .init(buildIDs: buildIDs, state: .confirmed, jobID: jobID,
              terminalState: terminalState, detail: detail)
    }

    public static func unconfirmed(buildIDs: [UUID], jobID: String?,
                                   detail: String) -> GameBuildDrainReceipt {
        .init(buildIDs: buildIDs, state: .unconfirmed, jobID: jobID, detail: detail)
    }
}

public struct GameBuildBinding: Equatable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let revision: String
    /// sha256 over the canonical manifest of every HEAD file record.
    public let sourceDigest: String
    public let engine: GameEngineID
    public let engineVersion: String?
    public let sourceRoot: URL
    public let owner: GameProjectOwner
    public let environmentID: String?
    /// Selected nested game root relative to `sourceRoot`; nil is the project
    /// root and never an inferred subtree.
    public let gameRoot: GameRelativePath?
    /// Canonical digest of the selected subtree; nil for a project-root build.
    public let selectedSourceDigest: String?

    public init(id: UUID, projectID: UUID, revision: String, sourceDigest: String,
                engine: GameEngineID, engineVersion: String?, sourceRoot: URL,
                owner: GameProjectOwner, environmentID: String?,
                gameRoot: GameRelativePath? = nil,
                selectedSourceDigest: String? = nil) {
        self.id = id; self.projectID = projectID; self.revision = revision
        self.sourceDigest = sourceDigest; self.engine = engine
        self.engineVersion = engineVersion; self.sourceRoot = sourceRoot
        self.owner = owner; self.environmentID = environmentID
        self.gameRoot = gameRoot
        self.selectedSourceDigest = selectedSourceDigest
    }
}

public struct GameBuildArtifact: Equatable, Sendable {
    public let name: String
    public let sha256: String
    public let bytes: Int
    /// Present when a verified web bundle was sealed as a playable
    /// GameWebArtifactPackage bound to the original project context.
    public let sealed: GamePreparedArtifact?
    /// True when the CI provenance artifact attested this exact name/hash/size.
    public let provenanceAttested: Bool

    public init(name: String, sha256: String, bytes: Int,
                sealed: GamePreparedArtifact?, provenanceAttested: Bool = false) {
        self.name = name; self.sha256 = sha256; self.bytes = bytes
        self.sealed = sealed; self.provenanceAttested = provenanceAttested
    }
}

public enum GameBuildRecordState: String, Codable, Sendable {
    case bound, prepared, dispatched, verifying, succeeded, failed, cancelled
}

public struct GameBuildRecord: Codable, Equatable, Sendable {
    public let version: Int
    public let buildID: String
    public let projectID: String
    public let revision: String
    public let sourceDigest: String
    public let engine: String
    public let templateID: String
    public var state: GameBuildRecordState
    public var jobID: String?
    public var artifacts: [GameBuildArtifactRecord]
    public var error: String?
    public var sourceRoot: String?
    public var owner: GameProjectOwner?
    public var environmentID: String?
    public var transportKind: String?
    public var distributionProfileID: String?
    public var distributionReady: Bool?
    public var sourceArchive: GameBuildArtifactRecord?
    /// Requested atomic CI target ids; nil for legacy/host-exporter records.
    public var requestedTargets: [String]?
    /// Selected nested game root; nil for a project-root build. Old records
    /// decode this as nil and are distinguished by `selectionSchemaVersion`.
    public var gameRoot: String?
    public var selectedSourceDigest: String?
    /// `1` for records written after nested-root selection existed. Old
    /// records decode this as nil, so they are never relabelled as verified
    /// project-root or nested results.
    public var selectionSchemaVersion: Int?

    public init(version: Int, buildID: String, projectID: String, revision: String,
                sourceDigest: String, engine: String, templateID: String,
                state: GameBuildRecordState, jobID: String?,
                artifacts: [GameBuildArtifactRecord], error: String?,
                sourceRoot: String? = nil, owner: GameProjectOwner? = nil,
                environmentID: String? = nil, transportKind: String? = nil,
                distributionProfileID: String? = nil, distributionReady: Bool? = nil,
                sourceArchive: GameBuildArtifactRecord? = nil,
                requestedTargets: [String]? = nil,
                gameRoot: String? = nil, selectedSourceDigest: String? = nil,
                selectionSchemaVersion: Int? = nil) {
        self.version = version; self.buildID = buildID; self.projectID = projectID
        self.revision = revision; self.sourceDigest = sourceDigest; self.engine = engine
        self.templateID = templateID; self.state = state; self.jobID = jobID
        self.artifacts = artifacts; self.error = error; self.sourceRoot = sourceRoot
        self.owner = owner; self.environmentID = environmentID
        self.transportKind = transportKind
        self.distributionProfileID = distributionProfileID
        self.distributionReady = distributionReady; self.sourceArchive = sourceArchive
        self.requestedTargets = requestedTargets
        self.gameRoot = gameRoot
        self.selectedSourceDigest = selectedSourceDigest
        self.selectionSchemaVersion = selectionSchemaVersion
    }

    public var rootSelectionState: GameBuildRecordRootState {
        guard let selectionSchemaVersion, selectionSchemaVersion >= 1 else {
            return .legacyUnverified
        }
        return gameRoot == nil || gameRoot?.isEmpty == true ? .projectRoot : .nestedRoot
    }
}

/// Honest interpretation of a durable record's selected root. A legacy record
/// has no selection bytes, so it is not silently treated as either root kind.
public enum GameBuildRecordRootState: String, Codable, Equatable, Sendable {
    case projectRoot
    case nestedRoot
    case legacyUnverified
}

public struct GameBuildArtifactRecord: Codable, Equatable, Sendable {
    public let name: String
    public let sha256: String
    public let bytes: Int
    public let sealedDigest: String?

    public init(name: String, sha256: String, bytes: Int, sealedDigest: String?) {
        self.name = name; self.sha256 = sha256; self.bytes = bytes; self.sealedDigest = sealedDigest
    }
}

public struct GameBuildDistributionRequest: Sendable {
    public let profileID: String
    public let mode: GameDistributionMode
    public let pairedProvider: (any GameDistributionPairedSourceProvider)?

    public init(profileID: String, mode: GameDistributionMode = .distribution,
                pairedProvider: (any GameDistributionPairedSourceProvider)? = nil) {
        self.profileID = profileID; self.mode = mode; self.pairedProvider = pairedProvider
    }
}

public struct GameBuildOutcome: Sendable {
    public let binding: GameBuildBinding
    public let job: GameCIJobHandle?
    public let artifacts: [GameBuildArtifact]
    /// True only when every expected output was returned and verified.
    public let ready: Bool
    public let record: GameBuildRecord
    public let sourceTransport: GameBuildSourceTransport?
    public let sourceArchive: GameBuildArtifact?
    public let distribution: GameDistributionReceipt?
    /// The exact selection bound to this outcome; nil is project-root only.
    public let selection: GameBuildProjectSelection?
}

/// Durable per-build JSON records with atomic publication.
public actor GameBuildRecordStore {
    public let directory: URL

    public init(directory: URL) throws {
        guard directory.isFileURL else { throw GameBuildError.io("invalid record directory") }
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        try GameBuildFileSupport.makeDirectory(self.directory)
    }

    public func save(_ record: GameBuildRecord) throws {
        try GameBuildFileSupport.locked(root: directory, name: ".records.lock") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(record)
            try GameBuildFileSupport.replace(data, to: fileURL(record.buildID))
        }
    }

    public func load(buildID: String) throws -> GameBuildRecord? {
        let url = fileURL(buildID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(GameBuildRecord.self, from: Data(contentsOf: url))
    }

    public func list() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }

    public func delete(buildID: String) throws {
        try GameBuildFileSupport.locked(root: directory, name: ".records.lock") {
            let url = fileURL(buildID)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func fileURL(_ buildID: String) -> URL {
        directory.appendingPathComponent(buildID + ".json")
    }
}

/// Real build lifecycle over the existing services:
/// bind saved revision -> compute source digest -> check prerequisites ->
/// stage an export of HEAD -> optionally publish an explicit repository
/// snapshot -> dispatch through the CI jobs port -> poll -> verify returned
/// provenance digest/revision and artifact bytes -> recheck the saved revision
/// -> seal playable web bundles -> optionally build a source-accompanying
/// distribution bundle. Cancellation cancels the remote job and drains it.
public actor GameBuildCoordinator {
    private let host: GameBuildHostPort?
    private let ci: GameBuildCIJobsPort?
    private let records: GameBuildRecordStore
    private let exchange: GameArchiveExchange
    private let cancelDrainTimeout: Duration
    private struct ActiveBuild {
        let projectID: UUID
        var handle: GameCIJobHandle?
    }
    private struct RetainedBuild {
        let projectID: UUID
        let handle: GameCIJobHandle
        let ci: any GameBuildCIJobsPort
        let detail: String
    }
    private var cancelRequested: Set<UUID> = []
    private var generation: [UUID: Int] = [:]
    private var active: [UUID: ActiveBuild] = [:]
    /// Jobs whose terminal state was not confirmed. Their exact handle and CI
    /// port are retained even though the original run loop has exited.
    private var retained: [UUID: RetainedBuild] = [:]

    public init(hostPort: GameBuildHostPort?, ciPort: GameBuildCIJobsPort?,
                records: GameBuildRecordStore, exchange: GameArchiveExchange = .init(),
                cancelDrainTimeout: Duration = .seconds(60)) {
        self.host = hostPort
        self.ci = ciPort
        self.records = records
        self.exchange = exchange
        self.cancelDrainTimeout = cancelDrainTimeout
    }

    public func requestCancel(buildID: UUID) {
        cancelRequested.insert(buildID)
    }

    /// Fences every active or retained build for a project after a switch to a
    /// new plan or conversation. Late CI callbacks cannot write a previous
    /// build's state.
    @discardableResult
    public func beginReplacement(projectID: UUID) -> [UUID] {
        let ids = Array(activeBuilds(projectID: projectID))
        for id in ids {
            generation[id, default: 0] += 1
            cancelRequested.insert(id)
        }
        return ids
    }

    public func activeBuilds(projectID: UUID) -> Set<UUID> {
        Set(active.filter { $0.value.projectID == projectID }.keys)
            .union(retained.filter { $0.value.projectID == projectID }.keys)
    }

    /// A retained, unconfirmed remote job is still owned work. Deleting its
    /// record would lose the only handle that can retry Stop.
    public func retainedBuilds(projectID: UUID) -> Set<UUID> {
        Set(retained.filter { $0.value.projectID == projectID }.keys)
    }

    /// Delete a terminal build's record and task-owned artifact directories.
    /// An active or retained build is refused so a host cannot delete bytes
    /// still in use or lose an unconfirmed job handle.
    public func delete(buildID: UUID) async throws {
        guard active[buildID] == nil, retained[buildID] == nil else {
            throw GameBuildError.buildActive
        }
        let id = buildID.uuidString.lowercased()
        try await records.delete(buildID: id)
        for prefix in ["staging-", "artifacts-", "distribution-"] {
            let url = records.directory.appendingPathComponent(prefix + id)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        cancelRequested.remove(buildID)
        generation.removeValue(forKey: buildID)
    }

    public func run(plan: GameBuildCapabilityPlan,
                    source: GameProjectContext,
                    repository: FileGameProjectRepository,
                    provided configured: Set<String>,
                    sourceTransport: GameBuildSourceTransport? = nil,
                    repositoryCoordinates: GameBuildRepositoryReference? = nil,
                    sourcePublisher: (any GameBuildSourcePublisherPort)? = nil,
                    distribution: GameBuildDistributionRequest? = nil,
                    exporter: (any GameBuildExporterPort)? = nil,
                    selectedRouteIDs: Set<String>? = nil,
                    pollInterval: Duration = .milliseconds(200),
                    pollTimeout: Duration = .seconds(120),
                    selection: GameBuildProjectSelection? = nil,
                    buildID: UUID = UUID()) async throws -> GameBuildOutcome {
        // 0. Revalidate the captured selection before any durable or remote
        // side effect. A stale project/owner/environment/root/revision or a
        // replaced/symlinked root fails here, not after a dispatch.
        if let selection {
            do {
                try selection.validate(against: source)
                try selection.validate(engine: plan.engine)
            } catch let error as GameBuildSelectionError {
                throw GameBuildError.selectionInvalid(String(describing: error))
            }
        }
        // 1. Bind the authoritative saved revision.
        let stored = try await repository.open(source.projectID, owner: source.owner)
        guard stored.revision == source.savedRevision else {
            throw GameBuildError.staleBinding(expected: source.savedRevision, actual: stored.revision)
        }
        let selectedSourceDigest: String?
        if let selection {
            do {
                selectedSourceDigest = try selection.selectedSourceDigest(from: stored.files)
            } catch let error as GameBuildSelectionError {
                throw GameBuildError.selectionInvalid(String(describing: error))
            }
        } else {
            selectedSourceDigest = nil
        }
        if let selection, let gameRoot = selection.gameRoot,
           selectedSourceDigest == nil {
            throw GameBuildError.selectionInvalid("selected game root has no files: \(gameRoot.value)")
        }
        let binding = GameBuildBinding(id: buildID, projectID: source.projectID,
                                       revision: stored.revision, sourceDigest: Self.sourceDigest(of: stored),
                                       engine: plan.engine, engineVersion: plan.engineVersion,
                                       sourceRoot: source.rootURL, owner: source.owner,
                                       environmentID: source.environmentID,
                                       gameRoot: selection?.gameRoot,
                                       selectedSourceDigest: selectedSourceDigest)
        var record = GameBuildRecord(version: 1, buildID: binding.id.uuidString.lowercased(),
                                     projectID: binding.projectID.uuidString.lowercased(),
                                     revision: binding.revision, sourceDigest: binding.sourceDigest,
                                     engine: plan.engine.rawValue, templateID: plan.workflowTemplateID,
                                     state: .bound, jobID: nil, artifacts: [], error: nil,
                                     sourceRoot: source.rootURL.path, owner: source.owner,
                                     environmentID: source.environmentID,
                                     transportKind: sourceTransport?.kind.rawValue,
                                     gameRoot: binding.gameRoot?.value,
                                     selectedSourceDigest: binding.selectedSourceDigest,
                                     selectionSchemaVersion: 1)
        try await records.save(record)
        active[binding.id] = ActiveBuild(projectID: source.projectID, handle: nil)
        generation[binding.id] = 0
        var retainAfterExit = false
        var remoteHandle: GameCIJobHandle?
        defer {
            active.removeValue(forKey: binding.id)
            if !retainAfterExit {
                generation.removeValue(forKey: binding.id)
                if retained[binding.id] == nil {
                    cancelRequested.remove(binding.id)
                }
            }
        }

        let requestedRoutes = selectedOrDefaultRoutes(plan, selectedRouteIDs: selectedRouteIDs)
        do {
            // 2. Prepare: prerequisites are user-CI supplied; never fake
            // readiness. Only the tools required by the selected routes gate
            // this build, so a Web-only request does not require Android/native
            // SDKs or unrelated platform modules.
            let missing = plan.missingPrerequisites(
                configured: configured,
                selectedRouteIDs: Set(requestedRoutes.map(\.id)))
            guard missing.isEmpty else {
                throw GameBuildError.prerequisiteMissing(missing.map(\.tool.id))
            }
            // 3. Stage an export of HEAD as the dispatchable source snapshot.
            try ensureActive(binding.id)
            let stagingRoot = records.directory.appendingPathComponent("staging-\(record.buildID)")
            try GameBuildFileSupport.makeDirectory(stagingRoot)
            defer { try? FileManager.default.removeItem(at: stagingRoot) }
            let exported = stagingRoot.appendingPathComponent("source-folder")
            _ = try await repository.export(source.projectID, owner: source.owner,
                                            expectedRevision: binding.revision, to: exported)
            // The whole project remains the exported/dispatchable source. Only
            // the build cwd is the selected subtree, and it is verified against
            // both the selected digest and the actual engine marker bytes.
            let buildSourceRoot: URL
            if let selection {
                do {
                    buildSourceRoot = try selection.selectedRoot(in: exported)
                } catch let error as GameBuildSelectionError {
                    throw GameBuildError.selectionInvalid(String(describing: error))
                }
                let inspection: GameProjectInspection
                do {
                    inspection = try GameProjectInspector().inspect(rootURL: buildSourceRoot)
                } catch {
                    throw GameBuildError.selectionInvalid(
                        "selected game root could not be inspected after export: \(error)")
                }
                guard inspection.candidates.contains(where: { $0.engine == plan.engine }) else {
                    throw GameBuildError.selectionInvalid(
                        "engine \(plan.engine.rawValue) is not recognized in the exported selected game root")
                }
            } else {
                buildSourceRoot = exported
            }
            let stagedZIP = stagingRoot.appendingPathComponent("source.zip")
            let publication = try exchange.archive(directory: exported, to: stagedZIP)
            let verifiedStagedSHA = try exchange.verifyArchive(stagedZIP, expectFiles: publication.manifest.files,
                                                               expectDirectories: publication.manifest.directories)
            guard publication.sha256 == verifiedStagedSHA else {
                throw GameBuildError.artifactInvalid("staged source zip failed read-back")
            }
            if let host {
                let preflight = try await host.run(.init(executable: "unzip",
                                                         arguments: ["-tq", stagedZIP.path]))
                guard preflight.exitCode == 0 else {
                    throw GameBuildError.dispatchFailed("host archive preflight rejected the staged source")
                }
            }
            try ensureActive(binding.id)
            record.state = .prepared
            try await records.save(record)

            if let exporter, let route = selectedHostRoute(plan, selectedRouteIDs: selectedRouteIDs) {
                return try await runHostExport(route: route, exporter: exporter, plan: plan,
                                               source: source, repository: repository,
                                               binding: binding, record: &record,
                                               exported: exported, buildSourceRoot: buildSourceRoot,
                                               stagedZIP: stagedZIP,
                                               publication: publication, stagingRoot: stagingRoot,
                                               distribution: distribution,
                                               selection: selection)
            }

            guard let ci else { throw GameBuildError.missingCI }

            // 4. Resolve the explicit source transport. A repository snapshot is
            // published through the host's Git-data seam; an existing artifact
            // is verified by its exact run/artifact identity, never guessed.
            var transport = sourceTransport
            if let publisher = sourcePublisher, let coordinates = repositoryCoordinates {
                let snapshot = try GameBuildSourceSnapshot(
                    rootURL: exported, files: publication.manifest.files,
                    directories: publication.manifest.directories,
                    digest: binding.sourceDigest, revision: binding.revision, engine: plan.engine,
                    gameRoot: binding.gameRoot?.value,
                    selectedSourceDigest: binding.selectedSourceDigest)
                let published = try await publisher.publish(
                    snapshot, owner: coordinates.owner,
                    repository: coordinates.repository, branch: coordinates.branch)
                guard published.manifestDigest == binding.sourceDigest,
                      published.revision == binding.revision,
                      published.gameRoot == binding.gameRoot?.value,
                      published.selectedSourceDigest == binding.selectedSourceDigest else {
                    throw GameBuildError.selectionInvalid(
                        "the source publisher returned a different project or selected game root")
                }
                transport = .repositorySnapshot(published)
            }
            if let transport {
                try transport.validated(for: binding, allowed: Set(plan.sourceTransports))
                if let reference = artifactReference(of: transport) {
                    guard let publisher = sourcePublisher else {
                        throw GameBuildError.dispatchFailed("source artifact verification requires the host publisher port")
                    }
                    _ = try await publisher.verifyExistingArtifact(reference)
                }
            }
            if selection != nil, transport == nil {
                throw GameBuildError.selectionInvalid(
                    "a selected game root requires an explicit source transport; the legacy digest-only dispatch cannot carry it")
            }
            record.transportKind = transport?.kind.rawValue
            try await records.save(record)

            // 5. Dispatch through the existing CI jobs service. The selected
            // route outputs are resolved against the template's atomic target
            // contract; unsupported outputs fail before a job is dispatched.
            guard let template = GameCIWorkflowTemplates.template(for: plan.engine) else {
                throw GameBuildError.dispatchFailed("no workflow template for \(plan.engine.rawValue)")
            }
            let requested = requestedOutputs(plan, selectedRouteIDs: selectedRouteIDs)
            guard !requested.isEmpty else {
                throw GameBuildError.unsupportedTarget(
                    "no requested build target is available for \(plan.engine.rawValue)")
            }
            var targetSelection: GameCIWorkflowTargetSelection?
            if let transport {
                let inputs = transport.dispatchInputs(engine: plan.engine,
                                                      engineVersion: binding.engineVersion)
                do {
                    let resolvedTargets = try template.selection(
                        forRequestedArtifacts: Set(requested.map(\.artifactName)),
                        inputs: inputs)
                    targetSelection = resolvedTargets
                    record.requestedTargets = resolvedTargets.targetIDs
                } catch let error as GameCIWorkflowError {
                    if case .unsupportedTarget(let name) = error {
                        throw GameBuildError.unsupportedTarget(name)
                    }
                    throw GameBuildError.unsupportedTarget(String(describing: error))
                }
            }
            try ensureActive(binding.id)
            let handle: GameCIJobHandle
            do {
                if let transport, let sourceCI = ci as? GameBuildCISourceJobsPort {
                    guard let targetSelection else {
                        throw GameBuildError.unsupportedTarget("target selection was not resolved")
                    }
                    handle = try await sourceCI.dispatch(template: template, source: transport,
                                                         engineVersion: binding.engineVersion,
                                                         targets: targetSelection)
                } else if transport != nil {
                    throw GameBuildError.dispatchFailed("CI port does not accept an explicit source transport")
                } else {
                    handle = try await ci.dispatch(template: template, sourceDigest: binding.sourceDigest,
                                                   revision: binding.revision, engineVersion: binding.engineVersion)
                }
            } catch let error as GameBuildError {
                throw error
            } catch {
                throw GameBuildError.dispatchFailed(String(describing: error))
            }
            // Capture the exact handle before any fence check: a cancellation
            // that arrived while dispatch was awaiting must still drain this
            // remote job instead of pretending it never started.
            active[binding.id]?.handle = handle
            remoteHandle = handle
            try ensureActive(binding.id)
            record.state = .dispatched
            record.jobID = handle.jobID
            try await records.save(record)

            // 6. Poll to a terminal state, honoring cancellation. A running
            // status is never terminal merely because it carries a digest.
            let status = try await poll(ci: ci, handle: handle, binding: binding,
                                        buildID: binding.id, interval: pollInterval, timeout: pollTimeout)
            remoteHandle = nil
            active[binding.id]?.handle = nil
            guard case .succeeded = status.state else {
                if case .cancelled = status.state { throw GameBuildError.cancelled }
                if case .failed(let reason) = status.state { throw GameBuildError.dispatchFailed(reason) }
                throw GameBuildError.dispatchFailed("unexpected terminal state")
            }
            try ensureActive(binding.id)

            // 7. Reject stale results: provenance must echo this binding exactly.
            guard status.sourceDigest == binding.sourceDigest, status.revision == binding.revision else {
                record.state = .failed
                record.error = "stale result"
                try await records.save(record)
                throw GameBuildError.staleResult(expectedDigest: binding.sourceDigest,
                                                 actualDigest: status.sourceDigest)
            }
            var provenance: GameBuildProvenance?
            if transport != nil {
                do {
                    let data = try await ci.artifact(handle, named: GameBuildCILimits.provenanceArtifactName)
                    let decoded = try JSONDecoder().decode(GameBuildProvenance.self, from: data)
                    try decoded.verify(against: binding)
                    if let targetSelection {
                        try decoded.verifyArtifactSet(targetSelection.artifactSet)
                        try decoded.verifyTargets(targetSelection.targetIDSet)
                    }
                    provenance = decoded
                } catch {
                    record.state = .failed
                    record.error = "provenance missing or invalid"
                    try await records.save(record)
                    throw GameBuildError.artifactInvalid("CI build provenance missing or invalid")
                }
            }
            record.state = .verifying
            try await records.save(record)

            // 8. Download and verify every expected artifact's actual bytes.
            // `.sourceArchive` outputs describe the staged source snapshot that
            // this component already produced and verified; CI does not return
            // them and they are not counted as downloadable artifacts.
            var artifacts: [GameBuildArtifact] = []
            var artifactRecords: [GameBuildArtifactRecord] = []
            let artifactRoot = records.directory.appendingPathComponent("artifacts-\(record.buildID)")
            try GameBuildFileSupport.makeDirectory(artifactRoot)
            for output in requested {
                try ensureActive(binding.id)
                try Task.checkCancellation()
                let data: Data
                do {
                    data = try await ci.artifact(handle, named: output.artifactName)
                } catch {
                    record.state = .failed
                    record.error = "artifact missing: \(output.artifactName)"
                    try await records.save(record)
                    throw GameBuildError.artifactMissing(output.artifactName)
                }
                guard !data.isEmpty else {
                    record.state = .failed
                    record.error = "artifact empty: \(output.artifactName)"
                    try await records.save(record)
                    throw GameBuildError.artifactInvalid(output.artifactName)
                }
                do {
                    try GameArtifactValidator.validate(data: data, name: output.artifactName, rule: output.validation)
                } catch {
                    record.state = .failed
                    record.error = "artifact invalid: \(output.artifactName)"
                    try await records.save(record)
                    throw GameBuildError.artifactInvalid(output.artifactName)
                }
                let digest = GameDigest.sha256(data)
                if let provenance {
                    do {
                        try provenance.verifyArtifact(named: output.artifactName, sha256: digest, bytes: data.count)
                    } catch {
                        record.state = .failed
                        record.error = "artifact not attested: \(output.artifactName)"
                        try await records.save(record)
                        throw GameBuildError.artifactInvalid(output.artifactName)
                    }
                }
                try GameBuildFileSupport.publish(data, to: artifactRoot.appendingPathComponent(output.artifactName))
                var sealed: GamePreparedArtifact?
                var sealedDigest: String?
                if output.kind == .webBundle {
                    (sealed, sealedDigest) = try await sealWebBundle(data, name: output.artifactName,
                                                                     binding: binding, source: source,
                                                                     artifactRoot: artifactRoot)
                }
                artifacts.append(.init(name: output.artifactName, sha256: digest, bytes: data.count,
                                       sealed: sealed, provenanceAttested: provenance != nil))
                artifactRecords.append(.init(name: output.artifactName, sha256: digest,
                                             bytes: data.count, sealedDigest: sealedDigest))
            }

            // 9. After-save CAS: an edit during a long CI build must not let the
            // old artifact be sealed as the current revision.
            try ensureActive(binding.id)
            let current = try await repository.open(source.projectID, owner: source.owner)
            guard current.revision == binding.revision else {
                record.state = .failed
                record.error = "saved revision changed during build"
                try await records.save(record)
                throw GameBuildError.staleBinding(expected: binding.revision, actual: current.revision)
            }

            // 10. Preserve the exact staged source archive separately from CI
            // outputs; it is byte-verified and never presented as playable.
            let sourceOutput = plan.outputs.first(where: { $0.kind == .sourceArchive })
            let sourceName = sourceOutput?.artifactName ?? "\(plan.engine.rawValue)-source.zip"
            let sourceData = try Data(contentsOf: stagedZIP)
            try GameBuildFileSupport.publish(sourceData, to: artifactRoot.appendingPathComponent(sourceName))
            let sourceArtifact = GameBuildArtifact(name: sourceName,
                                                   sha256: GameDigest.sha256(sourceData),
                                                   bytes: sourceData.count, sealed: nil)
            record.sourceArchive = GameBuildArtifactRecord(name: sourceName,
                                                           sha256: sourceArtifact.sha256,
                                                           bytes: sourceArtifact.bytes,
                                                           sealedDigest: nil)

            // 11. Optionally bind the selected distribution profile and carry
            // notices, readable Floe source and paired corresponding source.
            var distributionReceipt: GameDistributionReceipt?
            if let distribution {
                do {
                    let profile = try GameDistributionProfileCatalog.profile(id: distribution.profileID)
                    let contentRoot = try distributionContentRoot(
                        artifacts: artifacts, artifactRoot: artifactRoot)
                    let receipt = try await GameDistributionBundle.build(
                        profile: profile, engine: plan.engine, contentRoot: contentRoot,
                        outputURL: records.directory.appendingPathComponent("distribution-\(record.buildID)"),
                        environment: .init(pairedProvider: distribution.pairedProvider,
                                           mode: distribution.mode))
                    distributionReceipt = receipt
                    record.distributionProfileID = distribution.profileID
                    record.distributionReady = receipt.distributionReady
                } catch let error as GameDistributionError {
                    record.state = .failed
                    record.error = "distribution: \(error)"
                    try await records.save(record)
                    throw GameBuildError.distribution(String(describing: error))
                }
            }

            try ensureActive(binding.id)
            record.state = .succeeded
            record.artifacts = artifactRecords
            try await records.save(record)
            return .init(binding: binding, job: handle, artifacts: artifacts,
                         ready: artifacts.count == requested.count,
                         record: record, sourceTransport: transport,
                         sourceArchive: sourceArtifact, distribution: distributionReceipt,
                         selection: selection)
        } catch let error as GameBuildError {
            switch error {
            case .cancelled:
                if let handle = remoteHandle, let ci {
                    let receipt = await Self.drainRemote(
                        ci: ci, handle: handle, interval: pollInterval,
                        timeout: min(pollTimeout, cancelDrainTimeout))
                    if receipt.isConfirmed {
                        record.state = .cancelled
                        record.error = receipt.terminalState == .succeeded
                            ? "stopped; the remote job completed before cancellation and its output was not adopted"
                            : "cancelled"
                        try? await records.save(record)
                        throw GameBuildError.cancelled
                    }
                    retainAfterExit = true
                    retained[binding.id] = RetainedBuild(
                        projectID: source.projectID, handle: handle, ci: ci,
                        detail: receipt.detail)
                    record.error = "cancellation unconfirmed: \(receipt.detail)"
                    try? await records.save(record)
                    throw GameBuildError.cancellationUnconfirmed(receipt.detail)
                }
                record.state = .cancelled
                record.error = "cancelled"
                try? await records.save(record)
                throw error
            case .cancellationUnconfirmed(let detail), .outcomeUnconfirmed(let detail):
                if let handle = remoteHandle, let ci {
                    retainAfterExit = true
                    retained[binding.id] = RetainedBuild(
                        projectID: source.projectID, handle: handle, ci: ci,
                        detail: detail)
                    record.error = "outcome unconfirmed: \(detail)"
                    record.state = .dispatched
                    try? await records.save(record)
                } else if record.state != .succeeded {
                    record.state = .failed
                    record.error = detail
                    try? await records.save(record)
                }
                throw error
            default:
                // Any failure after a real dispatch that was not observed
                // terminal retains the exact handle. It is not a fake cancel.
                if let handle = remoteHandle, let ci {
                    retainAfterExit = true
                    let detail = String(describing: error)
                    retained[binding.id] = RetainedBuild(
                        projectID: source.projectID, handle: handle, ci: ci,
                        detail: detail)
                    record.error = "outcome unconfirmed: \(detail)"
                    record.state = .dispatched
                    try? await records.save(record)
                    throw GameBuildError.outcomeUnconfirmed(detail)
                }
                if record.state != .failed, record.state != .cancelled,
                   record.state != .succeeded {
                    record.state = .failed
                    record.error = String(describing: error)
                    try? await records.save(record)
                }
                throw error
            }
        } catch is CancellationError {
            if let handle = remoteHandle, let ci {
                let receipt = await Self.drainRemote(
                    ci: ci, handle: handle, interval: pollInterval,
                    timeout: min(pollTimeout, cancelDrainTimeout))
                if receipt.isConfirmed {
                    record.state = .cancelled
                    record.error = receipt.terminalState == .succeeded
                        ? "stopped; the remote job completed before cancellation and its output was not adopted"
                        : "cancelled"
                    try? await records.save(record)
                    throw GameBuildError.cancelled
                }
                retainAfterExit = true
                retained[binding.id] = RetainedBuild(
                    projectID: source.projectID, handle: handle, ci: ci,
                    detail: receipt.detail)
                record.error = "cancellation unconfirmed: \(receipt.detail)"
                try? await records.save(record)
                throw GameBuildError.cancellationUnconfirmed(receipt.detail)
            }
            record.state = .cancelled
            record.error = "cancelled"
            try? await records.save(record)
            throw GameBuildError.cancelled
        } catch {
            if let handle = remoteHandle, let ci {
                retainAfterExit = true
                let detail = String(describing: error)
                retained[binding.id] = RetainedBuild(
                    projectID: source.projectID, handle: handle, ci: ci,
                    detail: detail)
                record.error = "outcome unconfirmed: \(detail)"
                record.state = .dispatched
                try? await records.save(record)
                throw GameBuildError.outcomeUnconfirmed(detail)
            }
            record.state = .failed
            record.error = String(describing: error)
            try? await records.save(record)
            throw GameBuildError.io(String(describing: error))
        }
    }

    /// Backwards-compatible handle-scoped drain used by hosts/tests. It returns
    /// only after the exact job is terminal; otherwise it throws unconfirmed.
    public func cancelAndDrain(buildID: UUID, handle: GameCIJobHandle,
                               pollInterval: Duration = .milliseconds(200),
                               pollTimeout: Duration = .seconds(60)) async throws {
        requestCancel(buildID: buildID)
        guard let ci else { throw GameBuildError.missingCI }
        let receipt = await Self.drainRemote(ci: ci, handle: handle,
                                             interval: pollInterval, timeout: pollTimeout)
        guard receipt.isConfirmed else {
            throw GameBuildError.cancellationUnconfirmed(receipt.detail)
        }
    }

    /// Cancel and drain one build by its durable id. This is the App/session
    /// path: it cancels the remote job, waits for the owned local run loop to
    /// leave `active`, and only then reports success. A retained handle is
    /// retried without fabricating a replacement.
    public func cancelAndDrain(buildID: UUID,
                               pollInterval: Duration = .milliseconds(200),
                               drainTimeout: Duration = .seconds(60)) async -> GameBuildDrainReceipt {
        requestCancel(buildID: buildID)
        let handle = active[buildID]?.handle ?? retained[buildID]?.handle
        let ciPort = ci ?? retained[buildID]?.ci
        if handle == nil, active[buildID] == nil, retained[buildID] == nil {
            // A durable dispatched record without an in-process handle is not
            // a confirmed cancellation. Never invent a replacement handle.
            if let record = try? await records.load(buildID: buildID.uuidString.lowercased()),
               record.state == .dispatched {
                let identity = record.jobID ?? "(no recorded job id)"
                return .unconfirmed(
                    buildIDs: [buildID], jobID: record.jobID,
                    detail: "the durable build record has no in-process handle; this process cannot confirm or cancel job \(identity)")
            }
            cancelRequested.remove(buildID)
            generation.removeValue(forKey: buildID)
            return .confirmed(buildIDs: [buildID],
                              detail: "no owned job exists in this process")
        }
        var terminal: GameCIJobState?
        var detail = ""
        if let handle, let ciPort {
            let remote = await Self.drainRemote(
                ci: ciPort, handle: handle, interval: pollInterval, timeout: drainTimeout)
            terminal = remote.terminalState
            detail = remote.detail
            guard remote.isConfirmed else {
                return .unconfirmed(buildIDs: [buildID], jobID: handle.jobID, detail: detail)
            }
        }
        let activeDrained = await waitForActiveExit(buildID: buildID,
                                                    interval: pollInterval,
                                                    timeout: drainTimeout)
        guard activeDrained else {
            return .unconfirmed(buildIDs: [buildID], jobID: handle?.jobID,
                                detail: "the local build did not drain after cancellation")
        }
        if let terminal {
            if let retainedEntry = retained.removeValue(forKey: buildID) {
                await finalizeRetained(buildID: buildID, terminal: terminal,
                                       detail: retainedEntry.detail)
            }
            cancelRequested.remove(buildID)
            generation.removeValue(forKey: buildID)
            return .confirmed(buildIDs: [buildID], jobID: handle?.jobID,
                              terminalState: terminal, detail: detail)
        }
        if let retainedEntry = retained[buildID] {
            return .unconfirmed(buildIDs: [buildID], jobID: retainedEntry.handle.jobID,
                                detail: retainedEntry.detail)
        }
        if handle == nil {
            cancelRequested.remove(buildID)
            generation.removeValue(forKey: buildID)
            return .confirmed(buildIDs: [buildID], detail: "cancelled before dispatch")
        }
        return .unconfirmed(buildIDs: [buildID], jobID: handle?.jobID,
                            detail: "the remote job state is unknown")
    }

    public func cancelAndDrain(projectID: UUID,
                               pollInterval: Duration = .milliseconds(200),
                               drainTimeout: Duration = .seconds(60)) async -> GameBuildDrainReceipt {
        let ids = Array(activeBuilds(projectID: projectID)).sorted {
            $0.uuidString < $1.uuidString
        }
        guard !ids.isEmpty else {
            return .confirmed(buildIDs: [], detail: "no owned build")
        }
        var confirmedIDs: [UUID] = []
        var failures: [GameBuildDrainReceipt] = []
        for id in ids {
            let receipt = await cancelAndDrain(
                buildID: id, pollInterval: pollInterval, drainTimeout: drainTimeout)
            if receipt.isConfirmed { confirmedIDs.append(id) } else { failures.append(receipt) }
        }
        if failures.isEmpty {
            return .confirmed(buildIDs: confirmedIDs)
        }
        let detail = failures.map(\.detail).filter { !$0.isEmpty }.joined(separator: "; ")
        return .unconfirmed(buildIDs: failures.flatMap(\.buildIDs),
                            jobID: failures.compactMap(\.jobID).first, detail: detail)
    }

    private func waitForActiveExit(buildID: UUID, interval: Duration,
                                   timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while active[buildID] != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: interval)
        }
        return active[buildID] == nil
    }

    private func finalizeRetained(buildID: UUID, terminal: GameCIJobState,
                                  detail: String) async {
        guard var record = try? await records.load(buildID: buildID.uuidString.lowercased()) else {
            return
        }
        guard record.state == .dispatched || record.state == .failed else { return }
        switch terminal {
        case .cancelled:
            record.state = .cancelled
            record.error = "cancelled after confirmed drain"
        case .failed(let reason):
            record.state = .failed
            record.error = reason
        case .succeeded:
            record.state = .cancelled
            record.error = "stopped after the remote job completed; its output was not adopted"
        case .queued, .running:
            return
        }
        if !detail.isEmpty, record.error == nil { record.error = detail }
        try? await records.save(record)
    }

    private static func drainRemote(ci: any GameBuildCIJobsPort,
                                    handle: GameCIJobHandle,
                                    interval: Duration,
                                    timeout: Duration) async
        -> (isConfirmed: Bool, terminalState: GameCIJobState?, detail: String) {
        var cancelError: String?
        do { try await ci.cancel(handle) }
        catch { cancelError = String(describing: error) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastState: GameCIJobState?
        var lastStatusError: String?
        while clock.now < deadline {
            do {
                let status = try await ci.status(handle)
                lastState = status.state
                switch status.state {
                case .succeeded, .failed, .cancelled:
                    return (isConfirmed: true, terminalState: status.state,
                            detail: "remote job \(handle.jobID) reached a terminal state")
                case .queued, .running:
                    break
                }
            } catch {
                lastStatusError = String(describing: error)
            }
            try? await Task.sleep(for: interval)
        }
        var parts: [String] = ["remote job \(handle.jobID) did not reach a terminal state"]
        if let cancelError { parts.append("cancel failed: \(cancelError)") }
        if let lastState { parts.append("last state: \(String(describing: lastState))") }
        if let lastStatusError { parts.append("last status error: \(lastStatusError)") }
        return (isConfirmed: false, terminalState: lastState,
                detail: parts.joined(separator: "; "))
    }

    private func poll(ci: any GameBuildCIJobsPort, handle: GameCIJobHandle,
                      binding: GameBuildBinding, buildID: UUID,
                      interval: Duration, timeout: Duration) async throws -> GameCIJobStatus {
        let started = ContinuousClock.now
        var lastStatusError: String?
        while true {
            if cancelRequested.contains(buildID) {
                // The cancellation path drains the exact remote job. A
                // running status with a non-nil digest is not terminal.
                let receipt = await Self.drainRemote(
                    ci: ci, handle: handle, interval: interval,
                    timeout: cancelDrainTimeout)
                guard receipt.isConfirmed else {
                    throw GameBuildError.cancellationUnconfirmed(receipt.detail)
                }
                cancelRequested.remove(buildID)
                switch receipt.terminalState {
                case .cancelled:
                    return .init(handle: handle, state: .cancelled)
                case .succeeded:
                    // The job completed before the cancel landed. Its output
                    // was not verified according to the request, so it is not
                    // adopted as a successful build.
                    return .init(handle: handle, state: .cancelled)
                case .failed(let reason):
                    return .init(handle: handle, state: .failed(reason))
                case .queued, .running, .none:
                    throw GameBuildError.cancellationUnconfirmed(receipt.detail)
                }
            }
            try ensureActive(buildID)
            let status: GameCIJobStatus
            do {
                status = try await ci.status(handle)
            } catch {
                lastStatusError = String(describing: error)
                guard ContinuousClock.now - started < timeout else {
                    throw GameBuildError.outcomeUnconfirmed(
                        "the CI status could not be read before the poll deadline: \(error)")
                }
                try await Task.sleep(for: interval)
                continue
            }
            switch status.state {
            case .succeeded, .failed, .cancelled:
                let wasCancelling = cancelRequested.remove(buildID) != nil
                if wasCancelling, case .succeeded = status.state {
                    // A cancel raced the terminal success. The output was not
                    // requested any more, so it is not adopted or sealed.
                    return .init(handle: handle, state: .cancelled)
                }
                return status
            case .queued, .running:
                break
            }
            guard ContinuousClock.now - started < timeout else {
                var detail = "the CI job did not reach a terminal state before the poll deadline"
                if let lastStatusError { detail += "; last status error: \(lastStatusError)" }
                throw GameBuildError.outcomeUnconfirmed(detail)
            }
            try await Task.sleep(for: interval)
        }
    }

    private func ensureActive(_ buildID: UUID) throws {
        if cancelRequested.contains(buildID) || (generation[buildID] ?? 0) > 0 {
            throw GameBuildError.cancelled
        }
        try Task.checkCancellation()
    }

    private func selectedHostRoute(_ plan: GameBuildCapabilityPlan,
                                   selectedRouteIDs: Set<String>?) -> GameBuildRoute? {
        plan.routes.first { route in
            guard route.producer == .hostExporter else { return false }
            guard selectedRouteIDs?.contains(route.id) ?? route.enabledByDefault else { return false }
            return true
        }
    }

    /// Routes explicitly selected by the host, or the catalog's default routes.
    /// Used for both the target-aware prerequisite gate and requested outputs.
    private func selectedOrDefaultRoutes(_ plan: GameBuildCapabilityPlan,
                                         selectedRouteIDs: Set<String>?) -> [GameBuildRoute] {
        if let selectedRouteIDs {
            return plan.routes.filter { selectedRouteIDs.contains($0.id) }
        }
        return plan.routes.filter(\.enabledByDefault)
    }

    /// Concrete CI outputs requested by the selected route set. Duplicate
    /// artifact names (for example a host-exporter and CI route producing the
    /// same Web bundle) count once. A route with no supported target is
    /// rejected later by the template selection instead of being skipped.
    private func requestedOutputs(_ plan: GameBuildCapabilityPlan,
                                  selectedRouteIDs: Set<String>?) -> [GameBuildOutput] {
        let routeIDs = Set(selectedOrDefaultRoutes(plan, selectedRouteIDs: selectedRouteIDs).map(\.id))
        var seen = Set<String>()
        return plan.outputs.filter { output in
            output.kind != .sourceArchive
                && routeIDs.contains(output.routeID)
                && seen.insert(output.artifactName).inserted
        }
    }

    /// Execute a typed host exporter (the actual narrative/portable/GDevelop/RPG
    /// components) without creating a CI job or a new executor.
    private func runHostExport(route: GameBuildRoute,
                               exporter: any GameBuildExporterPort,
                               plan: GameBuildCapabilityPlan,
                               source: GameProjectContext,
                               repository: FileGameProjectRepository,
                               binding: GameBuildBinding,
                               record: inout GameBuildRecord,
                               exported: URL,
                               buildSourceRoot: URL,
                               stagedZIP: URL,
                               publication: GameArchivePublication,
                               stagingRoot: URL,
                               distribution: GameBuildDistributionRequest?,
                               selection: GameBuildProjectSelection?) async throws -> GameBuildOutcome {
        try ensureActive(binding.id)
        let output = stagingRoot.appendingPathComponent("exporter-output")
        let request = GameBuildExporterRequest(
            engine: plan.engine, projectID: source.projectID, owner: source.owner,
            environmentID: source.environmentID, revision: binding.revision,
            sourceDigest: binding.sourceDigest, sourceRoot: buildSourceRoot, outputURL: output,
            component: route.component, entryPoint: route.entryPoint,
            engineVersion: binding.engineVersion, projectRoot: exported,
            gameRoot: binding.gameRoot,
            selectedSourceDigest: binding.selectedSourceDigest)
        do {
            try request.validateSelectionLayout()
        } catch let error as GameBuildSelectionError {
            throw GameBuildError.selectionInvalid(String(describing: error))
        }
        let result: GameBuildExporterResult
        do {
            result = try await exporter.export(request)
        } catch {
            throw GameBuildError.dispatchFailed("host exporter failed: \(error)")
        }
        try ensureActive(binding.id)
        guard result.engine == plan.engine,
              result.outputURL.isFileURL,
              FileManager.default.fileExists(atPath: result.outputURL.path),
              FileManager.default.fileExists(atPath: result.outputURL.appendingPathComponent(result.entry).path) else {
            throw GameBuildError.artifactInvalid("host exporter output is missing \(result.entry)")
        }
        let artifactRoot = records.directory.appendingPathComponent("artifacts-\(record.buildID)")
        try GameBuildFileSupport.makeDirectory(artifactRoot)
        let archiveURL = artifactRoot.appendingPathComponent(route.artifactName)
        _ = try exchange.archive(directory: result.outputURL, to: archiveURL)
        let data = try Data(contentsOf: archiveURL)
        try GameArtifactValidator.validate(data: data, name: route.artifactName, rule: route.validation)
        var sealed: GamePreparedArtifact?
        var sealedDigest: String?
        if route.kind == .webBundle {
            (sealed, sealedDigest) = try await sealWebBundle(data, name: route.artifactName,
                                                             binding: binding, source: source,
                                                             artifactRoot: artifactRoot)
        }
        try ensureActive(binding.id)
        let current = try await repository.open(source.projectID, owner: source.owner)
        guard current.revision == binding.revision else {
            throw GameBuildError.staleBinding(expected: binding.revision, actual: current.revision)
        }
        let sourceOutput = plan.outputs.first(where: { $0.kind == .sourceArchive })
        let sourceName = sourceOutput?.artifactName ?? "\(plan.engine.rawValue)-source.zip"
        let sourceData = try Data(contentsOf: stagedZIP)
        try GameBuildFileSupport.publish(sourceData, to: artifactRoot.appendingPathComponent(sourceName))
        let sourceArtifact = GameBuildArtifact(name: sourceName, sha256: GameDigest.sha256(sourceData),
                                               bytes: sourceData.count, sealed: nil)
        record.sourceArchive = GameBuildArtifactRecord(name: sourceName, sha256: sourceArtifact.sha256,
                                                       bytes: sourceArtifact.bytes, sealedDigest: nil)
        let artifact = GameBuildArtifact(name: route.artifactName, sha256: GameDigest.sha256(data),
                                         bytes: data.count, sealed: sealed)
        record.transportKind = "hostExporter"
        record.artifacts = [.init(name: artifact.name, sha256: artifact.sha256,
                                  bytes: artifact.bytes, sealedDigest: sealedDigest)]
        var distributionReceipt: GameDistributionReceipt?
        if let distribution {
            do {
                let profile = try GameDistributionProfileCatalog.profile(id: distribution.profileID)
                let receipt = try await GameDistributionBundle.build(
                    profile: profile, engine: plan.engine, contentRoot: result.outputURL,
                    outputURL: records.directory.appendingPathComponent("distribution-\(record.buildID)"),
                    environment: .init(pairedProvider: distribution.pairedProvider,
                                       mode: distribution.mode))
                distributionReceipt = receipt
                record.distributionProfileID = distribution.profileID
                record.distributionReady = receipt.distributionReady
            } catch let error as GameDistributionError {
                throw GameBuildError.distribution(String(describing: error))
            }
        }
        try ensureActive(binding.id)
        record.state = .succeeded
        try await records.save(record)
        return .init(binding: binding, job: nil, artifacts: [artifact], ready: true,
                     record: record, sourceTransport: nil, sourceArchive: sourceArtifact,
                     distribution: distributionReceipt, selection: selection)
    }

    private func artifactReference(of transport: GameBuildSourceTransport) -> GameBuildRemoteArtifactReference? {
        switch transport {
        case .repositorySnapshot(_): return nil
        case .existingArtifact(let value), .manualEditorArtifact(let value): return value
        }
    }

    private func distributionContentRoot(artifacts: [GameBuildArtifact],
                                         artifactRoot: URL) throws -> URL {
        if let web = artifacts.first(where: { $0.sealed != nil }) {
            let candidate = artifactRoot.appendingPathComponent("sealed-\(web.name)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        let directory = artifactRoot.appendingPathComponent("distribution-content")
        try GameBuildFileSupport.makeDirectory(directory)
        for artifact in artifacts {
            let source = artifactRoot.appendingPathComponent(artifact.name)
            let target = directory.appendingPathComponent(artifact.name)
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.copyItem(at: source, to: target)
            }
        }
        return directory
    }

    /// Seal a verified web bundle zip as a playable artifact directory bound
    /// to the original project context via the core artifact packager.
    private func sealWebBundle(_ data: Data, name: String, binding: GameBuildBinding,
                               source: GameProjectContext, artifactRoot: URL) async throws
        -> (GamePreparedArtifact?, String?) {
        let bundleDir = artifactRoot.appendingPathComponent("sealed-\(name)")
        let listing = try exchange.inspect(archive: artifactRoot.appendingPathComponent(name))
        guard listing.entries.contains(where: { $0.path.hasSuffix("index.html") }) else {
            throw GameBuildError.artifactInvalid("web bundle has no index.html")
        }
        _ = try exchange.extract(archive: artifactRoot.appendingPathComponent(name), to: bundleDir)
        guard let entry = try await shallowIndexHTML(under: bundleDir) else {
            throw GameBuildError.artifactInvalid("web bundle index.html unreadable")
        }
        let sealedDir = artifactRoot.appendingPathComponent("playable-\(name)")
        let package = try GameWebArtifactPackage.build(source: source, engine: binding.engine,
                                                       entry: entry, to: sealedDir, contentRoot: bundleDir)
        try package.verify()
        return (package.prepared, package.prepared.sha256)
    }

    private func shallowIndexHTML(under root: URL) async throws -> GameRelativePath? {
        let walker = try GameDirectoryTreeWalker(rootURL: root)
        let entries = try walker.walk(maximumEntries: 4_096, maximumDepth: 3)
        return entries.first(where: { !$0.directory && $0.path.value.hasSuffix("index.html") })
            .map(\.path)
    }

    static func sourceDigest(of project: GameStoredProject) -> String {
        let canonical = project.files
            .sorted { $0.path.value < $1.path.value }
            .map { "\($0.path.value):\($0.sha256):\($0.bytes):\($0.executable ? "1" : "0")" }
            .joined(separator: "\n")
        return GameDigest.sha256(Data(canonical.utf8))
    }
}
