// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// A command described in a build plan. It is data for the host's existing
/// execution service; this package never spawns a process itself.
public struct GameHostCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String?

    public init(executable: String, arguments: [String], workingDirectory: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }
}

public struct GameHostResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Existing host execution (the resolved Linux guest / exec.shell adapter).
/// The coordinator only talks to this port; it implements no executor.
public protocol GameBuildHostPort: Sendable {
    func run(_ command: GameHostCommand) async throws -> GameHostResult
    func terminate(jobID: String) async throws
}

public struct GameCIJobHandle: Equatable, Sendable {
    public let jobID: String
    public let runURL: URL?
    public init(jobID: String, runURL: URL? = nil) {
        self.jobID = jobID
        self.runURL = runURL
    }
}

public enum GameCIJobState: Equatable, Sendable {
    case queued, running, succeeded, failed(String), cancelled
}

public struct GameCIJobStatus: Equatable, Sendable {
    public let handle: GameCIJobHandle
    public let state: GameCIJobState
    /// Values the CI job copied out of floe-build-provenance.json.
    public let sourceDigest: String?
    public let revision: String?

    public init(handle: GameCIJobHandle, state: GameCIJobState,
                sourceDigest: String? = nil, revision: String? = nil) {
        self.handle = handle
        self.state = state
        self.sourceDigest = sourceDigest
        self.revision = revision
    }
}

/// Existing GitHub jobs service. Dispatch/upload/download/cancel all happen on
/// the host; this port only carries typed values. No credential handling here.
public protocol GameBuildCIJobsPort: Sendable {
    func dispatch(template: GameCIWorkflowTemplate, sourceDigest: String,
                  revision: String, engineVersion: String?) async throws -> GameCIJobHandle
    func status(_ handle: GameCIJobHandle) async throws -> GameCIJobStatus
    func artifact(_ handle: GameCIJobHandle, named: String) async throws -> Data
    func cancel(_ handle: GameCIJobHandle) async throws
}

/// Source-aware extension over the existing GitHub jobs port. The coordinator
/// uses it when it has a real source transport; the legacy digest-only methods
/// remain for compatibility.
public protocol GameBuildCISourceJobsPort: GameBuildCIJobsPort {
    func dispatch(template: GameCIWorkflowTemplate,
                  source: GameBuildSourceTransport,
                  engineVersion: String?) async throws -> GameCIJobHandle
    /// Target-aware dispatch. The default implementation keeps older host
    /// adapters source-compatible for the unchanged default target set. A
    /// narrower selection requires an override so legacy dispatch cannot
    /// silently start jobs for platforms the user did not request.
    func dispatch(template: GameCIWorkflowTemplate,
                  source: GameBuildSourceTransport,
                  engineVersion: String?,
                  targets: GameCIWorkflowTargetSelection) async throws -> GameCIJobHandle
    func verifyExistingArtifact(_ reference: GameBuildRemoteArtifactReference) async throws -> GameBuildArtifactIdentity
}

public extension GameBuildCISourceJobsPort {
    func dispatch(template: GameCIWorkflowTemplate,
                  source: GameBuildSourceTransport,
                  engineVersion: String?,
                  targets: GameCIWorkflowTargetSelection) async throws -> GameCIJobHandle {
        let defaults = try template.defaultSelection(
            inputs: source.dispatchInputs(engine: template.engine, engineVersion: engineVersion))
        guard targets.targetIDSet == defaults.targetIDSet,
              targets.artifactSet == defaults.artifactSet else {
            throw GameBuildError.unsupportedTarget("This host adapter requires target-aware dispatch for the requested platforms")
        }
        return try await dispatch(template: template, source: source, engineVersion: engineVersion)
    }
}

/// Typed host-exporter seam. The host binds these requests to the existing
/// private component (Narrative/Portable/GDevelop/RPG) through the App's jobs
/// service; this package never spawns a process itself.
public struct GameBuildExporterRequest: Sendable {
    public let engine: GameEngineID
    public let projectID: UUID
    public let owner: GameProjectOwner
    public let environmentID: String?
    public let revision: String
    public let sourceDigest: String
    /// The actual build cwd for this export: the staged whole-project tree for
    /// a project-root selection, or that tree's selected subtree for a nested
    /// game root.
    public let sourceRoot: URL
    /// The unchanged staged whole-project tree. A nested selection never
    /// rewrites this to the subtree.
    public let projectRoot: URL
    public let gameRoot: GameRelativePath?
    public let selectedSourceDigest: String?
    public let outputURL: URL
    public let component: String?
    public let entryPoint: String?
    public let engineVersion: String?

    public init(engine: GameEngineID, projectID: UUID, owner: GameProjectOwner,
                environmentID: String?, revision: String, sourceDigest: String,
                sourceRoot: URL, outputURL: URL, component: String?,
                entryPoint: String?, engineVersion: String?,
                projectRoot: URL? = nil, gameRoot: GameRelativePath? = nil,
                selectedSourceDigest: String? = nil) {
        self.engine = engine; self.projectID = projectID; self.owner = owner
        self.environmentID = environmentID; self.revision = revision
        self.sourceDigest = sourceDigest
        self.sourceRoot = sourceRoot.standardizedFileURL
        self.projectRoot = (projectRoot ?? sourceRoot).standardizedFileURL
        self.gameRoot = gameRoot
        self.selectedSourceDigest = selectedSourceDigest
        self.outputURL = outputURL; self.component = component
        self.entryPoint = entryPoint; self.engineVersion = engineVersion
    }

    /// Refuses an export bound to a different subtree than its declared
    /// `gameRoot`. Callers cannot pass the whole project as the build cwd while
    /// claiming a nested selection (or the reverse).
    public func validateSelectionLayout() throws {
        guard sourceRoot.isFileURL, projectRoot.isFileURL else {
            throw GameBuildSelectionError.invalidContext
        }
        guard (gameRoot == nil) == (selectedSourceDigest == nil) else {
            throw GameBuildSelectionError.invalidContext
        }
        if let selectedSourceDigest {
            let valid = selectedSourceDigest.utf8.count == 64
                && selectedSourceDigest.unicodeScalars.allSatisfy { scalar in
                    (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
                }
            guard valid else {
                throw GameBuildSelectionError.invalidContext
            }
        }
        let expected: URL
        if let gameRoot {
            expected = projectRoot.appendingPathComponent(gameRoot.value).standardizedFileURL
        } else {
            expected = projectRoot
        }
        guard sourceRoot.standardizedFileURL.path == expected.path else {
            throw GameBuildSelectionError.selectionChanged(
                "exporter source cwd \(sourceRoot.lastPathComponent) is not the declared game root")
        }
    }
}

public struct GameBuildExporterResult: Sendable {
    public let engine: GameEngineID
    public let outputURL: URL
    public let entry: String
    public let producerID: String
    public init(engine: GameEngineID, outputURL: URL, entry: String, producerID: String) {
        self.engine = engine; self.outputURL = outputURL
        self.entry = entry; self.producerID = producerID
    }
}

public protocol GameBuildExporterPort: Sendable {
    func export(_ request: GameBuildExporterRequest) async throws -> GameBuildExporterResult
}
