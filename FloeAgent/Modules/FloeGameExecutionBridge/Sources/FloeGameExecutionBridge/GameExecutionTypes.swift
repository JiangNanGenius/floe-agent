// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameBuildKit
import FloeGameCore

/// Failures from the execution bridge. Every case is actionable and none is
/// converted into a fake success or a fake "ready" review state.
public enum GameExecutionError: Error, Equatable, Sendable, LocalizedError {
    case invalidConfiguration(String)
    case commandNotStarted(String)
    case commandBlocked(String)
    case commandFailed(String)
    case commandTimedOut(String)
    case outcomeUnknown(String)
    case artifactInvalid(String)
    case outputEscaped(String)
    case prerequisite(String)
    case unsupportedRoute(String)
    case selectionInvalid(String)
    /// A remote job's terminal state could not be confirmed. The owning
    /// service must retain its exact handle and expose a retry path.
    case cancellationUnconfirmed(String)
    /// The poll loop timed out or could not read a status while the remote job
    /// may still be running. This is not a terminal failure and not a cancel.
    case outcomeUnconfirmed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail):
            return "Game execution configuration is invalid: \(detail)"
        case .commandNotStarted(let detail):
            return "The game build command did not start: \(detail)"
        case .commandBlocked(let detail):
            return "The game build command was blocked by policy: \(detail)"
        case .commandFailed(let detail):
            return "The game build command failed: \(detail)"
        case .commandTimedOut(let detail):
            return "The game build command timed out: \(detail)"
        case .outcomeUnknown(let detail):
            return "The game build command outcome is unknown: \(detail)"
        case .artifactInvalid(let detail):
            return "The produced game artifact is invalid: \(detail)"
        case .outputEscaped(let detail):
            return "The game build output escaped its owned staging directory: \(detail)"
        case .prerequisite(let detail):
            return "The game build is not ready: \(detail)"
        case .unsupportedRoute(let detail):
            return "No supported execution route: \(detail)"
        case .selectionInvalid(let detail):
            return "The selected game root is invalid: \(detail)"
        case .cancellationUnconfirmed(let detail):
            return "The remote build has not confirmed stopping: \(detail)"
        case .outcomeUnconfirmed(let detail):
            return "The remote build outcome is unconfirmed: \(detail)"
        case .cancelled:
            return "The game build was cancelled."
        }
    }
}

/// One command for the host's existing execution service. Paths in `arguments`
/// are either plain values or guest-visible absolute paths; `cwd` is always
/// workspace-relative. This type never spawns a process itself.
public struct GameShellCommand: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let cwd: String
    public let environment: [String: String]
    public let stdin: String?

    public init(executable: String, arguments: [String] = [], cwd: String = ".",
                environment: [String: String] = [:], stdin: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
        self.environment = environment
        self.stdin = stdin
    }

    /// POSIX single-quote escaping for the host runner. The command text is
    /// assembled only by this package; user/model text is never interpreted as
    /// a shell program here.
    public var shellLine: String {
        ([executable] + arguments).map(Self.quote).joined(separator: " ")
    }

    public static func quote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        let safe = value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || "-._/:=@+,".unicodeScalars.contains(scalar)
        }
        if safe { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct GameShellResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public let truncated: Bool

    public init(exitCode: Int32, stdout: Data, stderr: Data, truncated: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.truncated = truncated
    }
}

/// The Main binding implements this over the existing `LocalShellService` and
/// `ToolEnvironmentRouting`. The implementation owns cancellation and the
/// actual environment lease; this bridge never resolves an environment.
public protocol GameShellRunning: Sendable {
    func run(_ command: GameShellCommand, context: GameShellContext) async throws -> GameShellResult
}


/// Trusted execution identity resolved by the Main binding from an actual saved
/// run and its `TaskExecutionBinding`. It is never synthesized from a project
/// ID, the current time or model output.
public struct GameExecutionAuthority: Sendable, Equatable {
    public let runID: UUID
    public let conversationID: UUID
    public let environmentID: String
    public let executionBindingGeneration: Int64?

    public init(runID: UUID, conversationID: UUID, environmentID: String,
                executionBindingGeneration: Int64?) {
        self.runID = runID
        self.conversationID = conversationID
        self.environmentID = environmentID
        self.executionBindingGeneration = executionBindingGeneration
    }
}

/// The Main/Root composition supplies a real saved run. A Space project must
/// resolve its existing project assistant/native-service run through the owned
/// services; `nil` or a fabricated run is not executable authority.
public typealias GameExecutionAuthorityProvider =
    @MainActor @Sendable (_ context: GameProjectContext) async throws -> GameExecutionAuthority

/// Resolves the real saved-run identity and workspace for one command. The Main
/// binding creates this from `currentContext()` and a validated run; bridges do
/// not cache a synthetic run UUID at construction time.
public typealias GameShellContextProvider = @Sendable () async throws -> GameShellContext

/// Minimal task/workspace identity needed by the Main shell runner. It carries
/// no access token and is not decoded from project metadata.
public struct GameShellContext: Sendable, Equatable {
    public let workspaceRoot: URL
    /// Guest mount of the workspace share. The Linux guest contract installs
    /// the task workspace at `/workspace`.
    public let guestWorkspaceRoot: String
    public let environmentID: String?
    public let conversationID: UUID
    public let runID: UUID
    public let executionBindingGeneration: Int64?

    public init(workspaceRoot: URL, guestWorkspaceRoot: String = "/workspace",
                environmentID: String?, conversationID: UUID, runID: UUID,
                executionBindingGeneration: Int64?) {
        self.workspaceRoot = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.guestWorkspaceRoot = guestWorkspaceRoot
        self.environmentID = environmentID
        self.conversationID = conversationID
        self.runID = runID
        self.executionBindingGeneration = executionBindingGeneration
    }
}

/// Bounded staging and output limits. They are applied before any file copy or
/// enumeration, and never become a permission.
public struct GameExecutionLimits: Sendable, Equatable {
    public let maximumEntries: Int
    public let maximumDepth: Int
    public let maximumFileBytes: Int
    public let maximumProjectBytes: Int
    public let maximumStageBytes: Int

    public init(maximumEntries: Int = 20_000,
                maximumDepth: Int = 32,
                maximumFileBytes: Int = 64 * 1_024 * 1_024,
                maximumProjectBytes: Int = 512 * 1_024 * 1_024,
                maximumStageBytes: Int = 2 * 1_024 * 1_024 * 1_024) throws {
        guard (1...100_000).contains(maximumEntries),
              (1...32).contains(maximumDepth),
              (1...256 * 1_024 * 1_024).contains(maximumFileBytes),
              maximumProjectBytes >= maximumFileBytes,
              maximumProjectBytes <= 1_024 * 1_024 * 1_024,
              maximumStageBytes >= maximumProjectBytes,
              maximumStageBytes <= 4 * 1_024 * 1_024 * 1_024 else {
            throw GameExecutionError.invalidConfiguration("execution limits")
        }
        self.maximumEntries = maximumEntries
        self.maximumDepth = maximumDepth
        self.maximumFileBytes = maximumFileBytes
        self.maximumProjectBytes = maximumProjectBytes
        self.maximumStageBytes = maximumStageBytes
    }

    public static let `default` = try! GameExecutionLimits()
}

/// Concrete route/executor identity used by the 20-engine closure matrix.
public enum GameExecutionMode: String, Codable, Equatable, Sendable {
    case staticWeb
    case runtimePackAssembly
    case portableAssembly
    case narrativeAssembly
    case externalBuild
    case guestRuntime
    case unavailable
}

public enum GameExecutionExecutor: String, Codable, Equatable, Sendable {
    /// Existing `LocalShellService` via `ToolEnvironmentRouting` (Linux guest).
    case mainLinuxShell
    /// Existing `GitHubActionsJobCenter` / `GitHubActionsClient` transport.
    case githubCI
    /// Byte-preserving on-device assembly with no process execution.
    case onDevice
    /// User-supplied official editor/runtime export; never bundled or faked.
    case userEditor
    /// Existing `GameBuildHostPort` exporter component.
    case hostExporter
}

/// Resolves the currently saved context for a long-running build without
/// creating a new run, workspace or permission. It must throw when the
/// owner/project/root/revision can no longer be resolved.
public typealias GameRunLiveContextResolver =
    @Sendable (GameProjectContext) async throws -> GameProjectContext

/// Bounded, explicit drain result returned to the App. `confirmed` means every
/// owned local task and remote job reached a terminal state; otherwise the
/// owning session must stay open and retain its library/environment leases.
public struct GameExecutionDrainSummary: Equatable, Sendable {
    public let isConfirmed: Bool
    /// Stable diagnostic ids: `build:<uuid>` or `ci:<run-id>`.
    public let unconfirmedOperationIDs: [String]
    public let detail: String

    public init(isConfirmed: Bool, unconfirmedOperationIDs: [String], detail: String) {
        self.isConfirmed = isConfirmed
        self.unconfirmedOperationIDs = unconfirmedOperationIDs
        self.detail = detail
    }

    public static let confirmed = GameExecutionDrainSummary(
        isConfirmed: true, unconfirmedOperationIDs: [], detail: "")

    public static func unconfirmed(ids: [String], detail: String) -> GameExecutionDrainSummary {
        .init(isConfirmed: false, unconfirmedOperationIDs: ids, detail: detail)
    }
}

/// The close result propagated from the execution session to the project
/// session, Registry and library mutation barrier.
public struct GameWorkspaceCloseOutcome: Equatable, Sendable {
    public let isConfirmed: Bool
    public let ownedOperations: [String]
    public let detail: String

    public init(isConfirmed: Bool, ownedOperations: [String] = [], detail: String = "") {
        self.isConfirmed = isConfirmed
        self.ownedOperations = ownedOperations
        self.detail = detail
    }

    public static let confirmed = GameWorkspaceCloseOutcome(isConfirmed: true)

    public static func unconfirmed(ids: [String], detail: String) -> GameWorkspaceCloseOutcome {
        .init(isConfirmed: false, ownedOperations: ids, detail: detail)
    }
}

public struct GameExecutionBuildRequest: Sendable, Equatable {
    public let engine: GameEngineID
    /// Nil selects the catalog's default routes. An explicit set narrows only;
    /// the coordinator still rejects an output no target can produce.
    public let selectedRouteIDs: Set<String>?
    public let distributionProfileID: String?
    public let providedTools: Set<String>
    /// Nil is a truthful project-root build. Root passes a validated
    /// `GameBuildProjectSelection` constructed from the freshly refreshed
    /// snapshot's `requireRunSelection()`; this type never guesses a subtree.
    public let selection: GameBuildProjectSelection?

    public init(engine: GameEngineID, selectedRouteIDs: Set<String>? = nil,
                distributionProfileID: String? = nil, providedTools: Set<String> = [],
                selection: GameBuildProjectSelection? = nil) {
        self.engine = engine
        self.selectedRouteIDs = selectedRouteIDs
        self.distributionProfileID = distributionProfileID
        self.providedTools = providedTools
        self.selection = selection
    }
}

/// A user-supplied licensed RPG Maker deployment tool. The bridge never
/// downloads or bundles MZ/MV runtime files; it only forwards the exact
/// source/output identity when the host has configured such a tool.
public struct GameLicensedDeploymentRequest: Sendable, Equatable {
    public let engine: GameEngineID
    public let sourceRoot: URL
    public let outputURL: URL
    public let entry: GameRelativePath
    public let engineVersion: String?
    public let revision: String

    public init(engine: GameEngineID, sourceRoot: URL, outputURL: URL,
                entry: GameRelativePath, engineVersion: String?, revision: String) {
        self.engine = engine
        self.sourceRoot = sourceRoot
        self.outputURL = outputURL
        self.entry = entry
        self.engineVersion = engineVersion
        self.revision = revision
    }
}

public protocol GameLicensedDeploymentRunning: Sendable {
    /// Returns host-provided evidence strings. Throws when the licensed tool is
    /// unavailable or the export failed; no success is inferred from a path.
    func run(_ request: GameLicensedDeploymentRequest) async throws -> [String]
}
