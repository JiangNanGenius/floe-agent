// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public enum GameBuildSourceTransportKind: String, Codable, Equatable, Sendable {
    case repositorySnapshot
    case existingArtifact
    case manualEditorArtifact
}

public struct GameBuildRepositoryReference: Codable, Equatable, Sendable {
    public let owner: String
    public let repository: String
    public let branch: String
    public init(owner: String, repository: String, branch: String) throws {
        try GameBuildTransportValidation.repository(owner: owner, repository: repository)
        guard GameBuildTransportValidation.safeBranch(branch) else {
            throw GameBuildTransportError.invalidRepository("branch")
        }
        self.owner = owner; self.repository = repository; self.branch = branch
    }
}

public enum GameBuildTransportError: Error, Equatable, Sendable {
    case invalidRepository(String)
    case invalidArtifact(String)
    case unsupportedTransport
    case staleDigest
    case staleRevision
    case artifactExpired
    case artifactMissing
    case artifactMismatch
    case credentialsForbidden
    case provenanceInvalid(String)
}

/// A commit published by the host's existing Git-data service. The commit is
/// the transport identity; the saved project revision remains a separate value
/// so CI provenance cannot silently substitute one for the other.
public struct GameBuildRepositorySnapshot: Codable, Equatable, Sendable {
    public let owner: String
    public let repository: String
    public let branch: String
    public let commitSHA: String
    public let treeSHA: String
    public let manifestDigest: String
    /// Saved project revision echoed into CI provenance; not a Git commit.
    public let revision: String
    /// Selected project-relative game root, or nil/empty for the project root.
    /// The published commit always contains the whole project; this value tells
    /// the workflow which subtree to build.
    public let gameRoot: String?
    /// Canonical digest of exactly that subtree, or nil/empty for the project
    /// root. It is verified again from the checked-out bytes by the workflow.
    public let selectedSourceDigest: String?

    public init(owner: String, repository: String, branch: String,
                commitSHA: String, treeSHA: String, manifestDigest: String,
                revision: String, gameRoot: String? = nil,
                selectedSourceDigest: String? = nil) throws {
        try GameBuildTransportValidation.repository(owner: owner, repository: repository)
        guard GameBuildTransportValidation.safeBranch(branch),
              GameBuildTransportValidation.safeValue(revision, maximum: 256),
              GameBuildTransportValidation.hex(commitSHA, lengths: [40, 64]),
              GameBuildTransportValidation.hex(treeSHA, lengths: [40, 64]),
              GameBuildTransportValidation.digest(manifestDigest),
              GameBuildSelectionSupport.validatePair(gameRoot: gameRoot,
                                                     selectedSourceDigest: selectedSourceDigest) else {
            throw GameBuildTransportError.invalidRepository("branch, commit, tree, digest or selected root")
        }
        self.owner = owner
        self.repository = repository
        self.branch = branch
        self.commitSHA = commitSHA.lowercased()
        self.treeSHA = treeSHA.lowercased()
        self.manifestDigest = manifestDigest.lowercased()
        self.revision = revision
        self.gameRoot = gameRoot?.isEmpty == true ? nil : gameRoot
        self.selectedSourceDigest = selectedSourceDigest
    }
}

/// An artifact produced by an explicitly identified prior run. It is never
/// discovered implicitly by guessing the newest run.
public struct GameBuildRemoteArtifactReference: Codable, Equatable, Sendable {
    public let owner: String
    public let repository: String
    public let runID: Int64
    public let artifactID: Int64
    public let name: String
    public let sha256: String
    public let bytes: Int
    public let revision: String?
    public let sourceDigest: String
    public let expired: Bool
    public let createdAt: Date?
    public let expiresAt: Date?
    /// Explicit selected root identity. An artifact built without a nested
    /// selection cannot satisfy a nested-root request and vice versa.
    public let gameRoot: String?
    public let selectedSourceDigest: String?

    public init(owner: String, repository: String, runID: Int64, artifactID: Int64,
                name: String, sha256: String, bytes: Int, revision: String?,
                sourceDigest: String, expired: Bool = false,
                createdAt: Date? = nil, expiresAt: Date? = nil,
                gameRoot: String? = nil, selectedSourceDigest: String? = nil) throws {
        try GameBuildTransportValidation.repository(owner: owner, repository: repository)
        guard runID > 0, artifactID > 0, bytes > 0,
              GameBuildTransportValidation.safeName(name, maximum: 120),
              GameBuildTransportValidation.digest(sha256),
              GameBuildTransportValidation.digest(sourceDigest),
              GameBuildSelectionSupport.validatePair(gameRoot: gameRoot,
                                                     selectedSourceDigest: selectedSourceDigest) else {
            throw GameBuildTransportError.invalidArtifact("run, name, bytes, digest or selected root")
        }
        self.owner = owner
        self.repository = repository
        self.runID = runID
        self.artifactID = artifactID
        self.name = name
        self.sha256 = sha256.lowercased()
        self.bytes = bytes
        self.revision = revision
        self.sourceDigest = sourceDigest.lowercased()
        self.expired = expired
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.gameRoot = gameRoot?.isEmpty == true ? nil : gameRoot
        self.selectedSourceDigest = selectedSourceDigest
    }
}

public enum GameBuildSourceTransport: Equatable, Sendable {
    case repositorySnapshot(GameBuildRepositorySnapshot)
    case existingArtifact(GameBuildRemoteArtifactReference)
    case manualEditorArtifact(GameBuildRemoteArtifactReference)

    public var kind: GameBuildSourceTransportKind {
        switch self {
        case .repositorySnapshot(_): .repositorySnapshot
        case .existingArtifact(_): .existingArtifact
        case .manualEditorArtifact(_): .manualEditorArtifact
        }
    }

    public var digest: String {
        switch self {
        case .repositorySnapshot(let value): value.manifestDigest
        case .existingArtifact(let value), .manualEditorArtifact(let value): value.sha256
        }
    }

    public var revision: String? {
        switch self {
        case .repositorySnapshot(let value): value.revision
        case .existingArtifact(let value), .manualEditorArtifact(let value): value.revision
        }
    }

    public var commitSHA: String? {
        if case .repositorySnapshot(let value) = self { return value.commitSHA }
        return nil
    }

    /// Explicit selected game root, if this transport was bound to one.
    public var gameRoot: String? {
        switch self {
        case .repositorySnapshot(let value): return value.gameRoot
        case .existingArtifact(let value), .manualEditorArtifact(let value):
            return value.gameRoot
        }
    }

    /// Explicit selected subtree digest, if this transport was bound to one.
    public var selectedSourceDigest: String? {
        switch self {
        case .repositorySnapshot(let value): return value.selectedSourceDigest
        case .existingArtifact(let value), .manualEditorArtifact(let value):
            return value.selectedSourceDigest
        }
    }

    /// Values passed to `workflow_dispatch`. No token, URL or credential value
    /// is ever part of this dictionary. `targets` carries the resolved atomic
    /// target ids so jobs for unrequested platforms are skipped. `game_root`
    /// is always present (empty means the whole project) so a workflow never
    /// silently falls back to a guessed subtree.
    public func dispatchInputs(engine: GameEngineID, engineVersion: String?,
                               targets: GameCIWorkflowTargetSelection? = nil) -> [String: String] {
        var inputs: [String: String] = [
            "source_transport": kind == .repositorySnapshot ? "repository" : "artifact",
            "source_sha256": digest,
            "source_revision": revision ?? "",
            "engine": engine.rawValue,
            "artifact_prefix": engine.rawValue,
            "game_root": gameRoot ?? "",
            "selected_source_sha256": selectedSourceDigest ?? "",
        ]
        if let targets, !targets.isEmpty {
            inputs["targets"] = targets.dispatchValue
        }
        switch self {
        case .repositorySnapshot(let value):
            inputs["source_commit"] = value.commitSHA
            inputs["source_repository"] = "\(value.owner)/\(value.repository)"
        case .existingArtifact(let value), .manualEditorArtifact(let value):
            inputs["source_run_id"] = String(value.runID)
            inputs["source_artifact_name"] = value.name
            inputs["source_repository"] = "\(value.owner)/\(value.repository)"
        }
        if let engineVersion, !engineVersion.isEmpty {
            inputs["engine_version"] = engineVersion
        }
        return inputs
    }

    public func validated(for binding: GameBuildBinding,
                          allowed: Set<GameBuildSourceTransportKind>) throws {
        guard allowed.contains(kind) else { throw GameBuildTransportError.unsupportedTransport }
        guard digest == binding.sourceDigest else { throw GameBuildTransportError.staleDigest }
        let root = binding.gameRoot?.value
        guard gameRoot == root,
              selectedSourceDigest == binding.selectedSourceDigest else {
            throw GameBuildTransportError.provenanceInvalid(
                "source transport does not bind the selected game root")
        }
        switch self {
        case .repositorySnapshot(_):
            break
        case .existingArtifact(let value), .manualEditorArtifact(let value):
            guard !value.expired else { throw GameBuildTransportError.artifactExpired }
            guard value.sourceDigest == binding.sourceDigest else { throw GameBuildTransportError.staleDigest }
            if let revision = value.revision, revision != binding.revision {
                throw GameBuildTransportError.staleRevision
            }
            if binding.gameRoot != nil, value.revision != binding.revision {
                throw GameBuildTransportError.staleRevision
            }
        }
    }
}

enum GameBuildTransportValidation {
    static func repository(owner: String, repository: String) throws {
        guard safeName(owner, maximum: 100), safeName(repository, maximum: 100),
              !owner.contains("/"), !repository.contains("/") else {
            throw GameBuildTransportError.invalidRepository("owner/repository")
        }
    }

    static func safeName(_ value: String, maximum: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximum,
              !value.contains(".."), !value.contains("\\"), !value.contains("/") else {
            return false
        }
        return safeValue(value, maximum: maximum)
    }

    static func safeValue(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func safeBranch(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255,
              !value.contains(".."), !value.contains("\\"), !value.hasPrefix("/"),
              !value.hasSuffix("/"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return false
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty }
    }

    static func hex(_ value: String, lengths: [Int]) -> Bool {
        lengths.contains(value.utf8.count)
            && value.unicodeScalars.allSatisfy { scalar in
                (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
                    || (65...70).contains(scalar.value)
            }
    }

    static func digest(_ value: String) -> Bool {
        hex(value, lengths: [64])
    }
}

/// Everything the publisher needs. File bytes stay in the existing repository
/// export; the publisher copies them through the host's Git-data seam.
public struct GameBuildSourceSnapshot: Sendable {
    public let rootURL: URL
    /// Every file of the original project; the snapshot is never narrowed to
    /// the selected subtree.
    public let files: [GameProjectFile]
    public let directories: [GameRelativePath]
    public let digest: String
    public let revision: String
    public let engine: GameEngineID
    public let gameRoot: String?
    public let selectedSourceDigest: String?

    public init(rootURL: URL, files: [GameProjectFile], directories: [GameRelativePath],
                digest: String, revision: String, engine: GameEngineID,
                gameRoot: String? = nil, selectedSourceDigest: String? = nil) throws {
        guard rootURL.isFileURL, !files.isEmpty,
              GameBuildTransportValidation.digest(digest),
              GameBuildSelectionSupport.validatePair(gameRoot: gameRoot,
                                                     selectedSourceDigest: selectedSourceDigest) else {
            throw GameBuildTransportError.invalidRepository("source snapshot")
        }
        let canonicalRoot: GameRelativePath?
        do {
            canonicalRoot = try GameBuildSelectionSupport.canonicalRoot(gameRoot)
        } catch {
            throw GameBuildTransportError.invalidRepository("selected game root")
        }
        let computed: String?
        do {
            computed = try GameBuildSelectionSupport.digest(of: files, under: canonicalRoot)
        } catch {
            throw GameBuildTransportError.invalidRepository("selected source digest")
        }
        if canonicalRoot == nil {
            guard selectedSourceDigest == nil else {
                throw GameBuildTransportError.invalidRepository("selected digest without a game root")
            }
        } else {
            guard let selectedSourceDigest, computed == selectedSourceDigest else {
                throw GameBuildTransportError.invalidRepository("selected source digest")
            }
        }
        self.rootURL = rootURL.standardizedFileURL
        self.files = files.sorted { $0.path.value < $1.path.value }
        self.directories = directories.sorted { $0.value < $1.value }
        self.digest = digest
        self.revision = revision
        self.engine = engine
        self.gameRoot = canonicalRoot?.value
        self.selectedSourceDigest = selectedSourceDigest
    }
}

/// The host implements this over its existing Git-data commit/tree/blob
/// service. It is not a generic executor and receives no credential value.
public protocol GameBuildSourcePublisherPort: Sendable {
    func publish(_ snapshot: GameBuildSourceSnapshot,
                 owner: String, repository: String, branch: String) async throws -> GameBuildRepositorySnapshot
    func verifyExistingArtifact(_ reference: GameBuildRemoteArtifactReference) async throws -> GameBuildArtifactIdentity
}

public struct GameBuildArtifactIdentity: Equatable, Sendable {
    public let name: String
    public let sha256: String
    public let bytes: Int
    public let runID: Int64
    public let artifactID: Int64
    public let sourceDigest: String
    public let revision: String
    public let engine: String
    public let templateID: String
    public let expired: Bool
    public let gameRoot: String?
    public let selectedSourceDigest: String?

    public init(name: String, sha256: String, bytes: Int, runID: Int64, artifactID: Int64,
                sourceDigest: String, revision: String, engine: String, templateID: String,
                expired: Bool, gameRoot: String? = nil, selectedSourceDigest: String? = nil) {
        self.name = name; self.sha256 = sha256; self.bytes = bytes
        self.runID = runID; self.artifactID = artifactID
        self.sourceDigest = sourceDigest; self.revision = revision
        self.engine = engine; self.templateID = templateID; self.expired = expired
        self.gameRoot = gameRoot
        self.selectedSourceDigest = selectedSourceDigest
    }
}

public struct GameBuildProvenanceArtifact: Codable, Equatable, Sendable {
    public let sha256: String
    public let bytes: Int
    public init(sha256: String, bytes: Int) { self.sha256 = sha256; self.bytes = bytes }
}

public struct GameBuildProvenance: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sourceSHA256: String
    public let sourceRevision: String
    public let engine: String
    public let template: String
    public let sourceTransport: String
    /// Exact GitHub Actions run id echoed by schema-2 templates. Schema-1
    /// provenance predates job identity and remains readable but unverified.
    public let jobID: String
    /// Explicit selected-root provenance schema. `0` is a legacy record that
    /// never observed a nested root; it remains readable only for a truthful
    /// project-root build and must never be relabelled as a nested result.
    public let selectionSchemaVersion: Int
    public let gameRoot: String
    public let selectedSourceSHA256: String
    /// Requested atomic target ids echoed by target-aware templates. Empty for
    /// legacy provenance records, which remain readable.
    public let targets: [String]
    public let artifactPrefix: String
    public let artifacts: [String: GameBuildProvenanceArtifact]

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        sourceSHA256 = try values.decode(String.self, forKey: .sourceSHA256)
        sourceRevision = try values.decode(String.self, forKey: .sourceRevision)
        engine = try values.decode(String.self, forKey: .engine)
        template = try values.decode(String.self, forKey: .template)
        sourceTransport = try values.decodeIfPresent(String.self, forKey: .sourceTransport) ?? ""
        jobID = try values.decodeIfPresent(String.self, forKey: .jobID) ?? ""
        selectionSchemaVersion = try values.decodeIfPresent(Int.self, forKey: .selectionSchemaVersion) ?? 0
        gameRoot = try values.decodeIfPresent(String.self, forKey: .gameRoot) ?? ""
        selectedSourceSHA256 = try values.decodeIfPresent(String.self, forKey: .selectedSourceSHA256) ?? ""
        targets = try values.decodeIfPresent([String].self, forKey: .targets) ?? []
        artifactPrefix = try values.decodeIfPresent(String.self, forKey: .artifactPrefix) ?? ""
        artifacts = try values.decodeIfPresent([String: GameBuildProvenanceArtifact].self, forKey: .artifacts) ?? [:]
    }

    public init(sourceSHA256: String, sourceRevision: String, engine: String,
                template: String, sourceTransport: String,
                artifacts: [String: GameBuildProvenanceArtifact],
                targets: [String] = [], artifactPrefix: String = "",
                selectionSchemaVersion: Int = 1, gameRoot: String = "",
                selectedSourceSHA256: String = "", jobID: String = "",
                schemaVersion: Int = 1) {
        self.schemaVersion = schemaVersion
        self.sourceSHA256 = sourceSHA256
        self.sourceRevision = sourceRevision
        self.engine = engine
        self.template = template
        self.sourceTransport = sourceTransport
        self.selectionSchemaVersion = selectionSchemaVersion
        self.gameRoot = gameRoot
        self.selectedSourceSHA256 = selectedSourceSHA256
        self.jobID = jobID
        self.targets = targets
        self.artifactPrefix = artifactPrefix
        self.artifacts = artifacts
    }

    public func verify(against binding: GameBuildBinding) throws {
        try verify(sourceDigest: binding.sourceDigest, revision: binding.revision,
                   engine: binding.engine.rawValue,
                   gameRoot: binding.gameRoot?.value ?? "",
                   selectedSourceDigest: binding.selectedSourceDigest)
    }

    /// Verifies the exact original source, root and selection echo. Schema 0 is
    /// legacy provenance and can only attest a truthful project-root build.
    public func verify(sourceDigest: String, revision: String, engine: String,
                       gameRoot: String?, selectedSourceDigest: String?) throws {
        guard (1...2).contains(schemaVersion),
              sourceSHA256 == sourceDigest,
              sourceRevision == revision,
              self.engine == engine else {
            throw GameBuildTransportError.provenanceInvalid(
                "source digest/revision/engine mismatch")
        }
        let expectedRoot = gameRoot ?? ""
        let expectedSelected = selectedSourceDigest ?? ""
        if selectionSchemaVersion >= 1 {
            guard self.gameRoot == expectedRoot,
                  selectedSourceSHA256 == expectedSelected else {
                throw GameBuildTransportError.provenanceInvalid(
                    "selected game root or subtree digest mismatch")
            }
        } else {
            // Legacy provenance never observed a selection. It is compatible
            // only with a truthful project-root build.
            guard expectedRoot.isEmpty, expectedSelected.isEmpty,
                  self.gameRoot.isEmpty, selectedSourceSHA256.isEmpty else {
                throw GameBuildTransportError.provenanceInvalid(
                    "legacy provenance cannot attest a nested game root")
            }
        }
        if schemaVersion >= 2 {
            guard !jobID.isEmpty else {
                throw GameBuildTransportError.provenanceInvalid(
                    "schema-2 provenance has no job identity")
            }
        }
    }

    public func verifyJob(jobID: String) throws {
        guard !jobID.isEmpty else {
            throw GameBuildTransportError.provenanceInvalid("expected job id")
        }
        if schemaVersion >= 2 {
            guard self.jobID == jobID else {
                throw GameBuildTransportError.provenanceInvalid(
                    "provenance job id does not match the dispatched run")
            }
        } else if !self.jobID.isEmpty, self.jobID != jobID {
            throw GameBuildTransportError.provenanceInvalid(
                "provenance job id does not match the dispatched run")
        }
    }

    public func verifySourceTransport(_ expected: String) throws {
        guard sourceTransport == expected else {
            throw GameBuildTransportError.provenanceInvalid(
                "provenance source transport does not match the published source")
        }
    }

    public func verifyTemplate(_ expected: String) throws {
        guard template == expected else {
            throw GameBuildTransportError.provenanceInvalid(
                "provenance template does not match the dispatched workflow")
        }
    }

    /// Target-aware adapter check after decoding `floe-build-provenance`.
    public func verifySelection(gameRoot: String?, selectedSourceDigest: String?) throws {
        let expectedRoot = gameRoot ?? ""
        let expectedSelected = selectedSourceDigest ?? ""
        if selectionSchemaVersion >= 1 {
            guard self.gameRoot == expectedRoot,
                  self.selectedSourceSHA256 == expectedSelected else {
                throw GameBuildTransportError.provenanceInvalid(
                    "selected game root or subtree digest mismatch")
            }
        } else {
            guard expectedRoot.isEmpty, expectedSelected.isEmpty,
                  self.gameRoot.isEmpty, self.selectedSourceSHA256.isEmpty else {
                throw GameBuildTransportError.provenanceInvalid(
                    "legacy provenance cannot attest a nested game root")
            }
        }
    }

    public func verifyArtifact(named name: String, sha256: String, bytes: Int) throws {
        guard let record = artifacts[name],
              record.sha256 == sha256, record.bytes == bytes else {
            throw GameBuildTransportError.provenanceInvalid("artifact \(name) is not attested")
        }
    }

    /// A target-aware workflow must attest exactly the artifacts of the
    /// selected atomic targets: no missing target output and no unrequested
    /// platform artifact. Legacy provenance without targets remains readable.
    public func verifyArtifactSet(_ names: Set<String>) throws {
        guard Set(artifacts.keys) == names else {
            throw GameBuildTransportError.provenanceInvalid("provenance artifact set does not match the requested targets")
        }
    }

    public func verifyTargets(_ targetIDs: Set<String>) throws {
        if !targets.isEmpty, Set(targets) != targetIDs {
            throw GameBuildTransportError.provenanceInvalid("provenance targets do not match the requested targets")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sourceSHA256, sourceRevision, engine, template, sourceTransport
        case jobID, selectionSchemaVersion, gameRoot, selectedSourceSHA256
        case targets, artifactPrefix, artifacts
    }
}
