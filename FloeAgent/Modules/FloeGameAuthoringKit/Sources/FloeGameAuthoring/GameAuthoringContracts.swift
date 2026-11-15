// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public struct GameAuthoringDiagnostic: Codable, Equatable, Sendable {
    public enum Severity: String, Codable, Sendable { case information, warning, error }
    public let severity: Severity
    public let path: GameRelativePath?
    public let message: String
    public init(_ severity: Severity, path: GameRelativePath? = nil, message: String) {
        self.severity = severity; self.path = path; self.message = String(message.prefix(4_096))
    }
}

/// Existing App access/environment/storage services resolve this at each effect.
/// No imported file, model response or component creates a permission grant.
public protocol GameAuthoringContextHost: Sendable {
    func currentContext(for context: GameProjectContext) async throws -> GameProjectContext
    /// An existing save service may materialize a new immutable source root
    /// after its own commit. This explicit handoff must retain the same owner,
    /// project and environment; never follow another globally selected workspace.
    func contextAfterCommit(_ project: GameStoredProject, previous: GameProjectContext) async throws -> GameProjectContext
}
public extension GameAuthoringContextHost {
    func contextAfterCommit(_ project: GameStoredProject, previous: GameProjectContext) async throws -> GameProjectContext {
        let expected = try GameProjectContext(projectID: previous.projectID, owner: previous.owner,
            rootURL: previous.rootURL, savedRevision: project.revision, environmentID: previous.environmentID)
        try expected.validate(current: await currentContext(for: previous))
        return expected
    }
}

public struct GameAuthoringSource: Sendable {
    public let context: GameProjectContext
    public let project: GameStoredProject
    public let read: @Sendable (GameRelativePath) async throws -> Data
    public init(context: GameProjectContext, project: GameStoredProject,
                read: @escaping @Sendable (GameRelativePath) async throws -> Data) {
        self.context = context; self.project = project; self.read = read
    }
}

public protocol GameAuthoringValidator: Sendable {
    func validate(_ source: GameAuthoringSource) async throws -> [GameAuthoringDiagnostic]
}

public struct GameAuthoringPlaytest: Sendable {
    public let diagnostics: [GameAuthoringDiagnostic]
    public let logs: [String]
    public let screenshotPNG: Data?
    public let stateJSON: Data?
    public init(diagnostics: [GameAuthoringDiagnostic], logs: [String], screenshotPNG: Data? = nil, stateJSON: Data? = nil) throws {
        guard diagnostics.count <= 1_000, logs.count <= 200,
              screenshotPNG.map({ $0.count <= 8_388_608 }) ?? true,
              stateJSON.map({ $0.count <= 4_194_304 }) ?? true else { throw GameProjectError.limitExceeded("playtestObservation") }
        self.diagnostics = diagnostics; self.logs = logs.map { String($0.prefix(4_096)) }
        self.screenshotPNG = screenshotPNG; self.stateJSON = stateJSON
    }
}

/// Actual engine/build/playback services implement this port. No process launcher
/// or model-authored shell command runs inside the native authoring module.
public protocol GameAuthoringPlaytestHost: Sendable {
    func playtest(_ source: GameAuthoringSource) async throws -> GameAuthoringPlaytest
    func cancel(projectID: UUID) async
}

public struct GameAIEditRequest: Sendable {
    public let goal: String
    public let context: GameProjectContext
    public let files: [GameRelativePath: Data]
    public let diagnostics: [GameAuthoringDiagnostic]
    public let playtest: GameAuthoringPlaytest?
    public let repairAttempt: Int
}

public struct GameAIEditProposal: Sendable {
    public let baseRevision: String
    public let changes: [GameFileChange]
    public let summary: String
    public init(baseRevision: String, changes: [GameFileChange], summary: String) throws {
        guard !baseRevision.isEmpty, baseRevision.utf8.count <= 256, !changes.isEmpty,
              changes.count <= 256, summary.utf8.count <= 16_384 else { throw GameProjectError.invalidEdit }
        var seen = Set<GameRelativePath>(), total = 0
        for change in changes {
            let path: GameRelativePath
            switch change {
            case .write(let file, let data, _):
                path = file
                guard data.count <= 8_388_608, total <= 33_554_432 - data.count else { throw GameProjectError.limitExceeded("AIEditBytes") }
                total += data.count
            case .remove(let file): path = file
            }
            guard seen.insert(path).inserted else { throw GameProjectError.invalidEdit }
        }
        self.baseRevision = baseRevision; self.changes = changes; self.summary = summary
    }
}

/// Adapter for the user's existing configured model and ordinary task tool chain.
/// This package does not create a provider, model router or approval system.
public protocol GameAIEditProvider: Sendable {
    func propose(_ request: GameAIEditRequest) async throws -> GameAIEditProposal
}

public struct GameAuthoringDiff: Equatable, Sendable {
    public let path: GameRelativePath
    public let beforeSHA256: String?
    public let afterSHA256: String?
    public let beforeBytes: Int?
    public let afterBytes: Int?
}
public struct GameAuthoringRevision: Sendable {
    public let before: String
    public let after: String
    public let summary: String
    public let differences: [GameAuthoringDiff]
}
public struct GameAuthoringResult: Sendable {
    public let project: GameStoredProject
    public let context: GameProjectContext
    public let revisions: [GameAuthoringRevision]
    public let diagnostics: [GameAuthoringDiagnostic]
    public let playtest: GameAuthoringPlaytest?
    public var passed: Bool { !diagnostics.contains { $0.severity == .error } }
}

public enum GameAuthoringError: Error, Equatable, Sendable { case busy, staleSession, repairLimitReached, invalidSourceSelection }
