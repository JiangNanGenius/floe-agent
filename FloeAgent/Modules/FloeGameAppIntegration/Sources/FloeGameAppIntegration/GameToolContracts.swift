// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// Shared, bounded argument contracts for the game tools. They are compiled
/// schemas, not a second permission layer: the App tool still checks the real
/// task run, conversation→work binding, file grant and repository revision.
public enum GameToolContractError: Error, Equatable, LocalizedError {
    case invalidProjectID
    case invalidPath(String)
    case tooManyOperations(Int)
    case tooMuchText(Int)
    case invalidRevision
    case invalidPage(offset: Int, limit: Int)
    case invalidTitle
    case invalidEngine
    case invalidScene
    case invalidChord
    case invalidInputAction
    case tooManyHistoryEntries(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidProjectID:
            return "A saved game project is required."
        case .invalidPath(let value):
            return "The project-relative path is invalid: \(value)."
        case .tooManyOperations(let count):
            return "The edit contains \(count) operations; at most 64 are accepted per call."
        case .tooMuchText(let bytes):
            return "The edit contains \(bytes) text bytes; at most 2 MiB are accepted per call."
        case .invalidRevision:
            return "The exact expected revision is required."
        case .invalidPage(let offset, let limit):
            return "The page offset \(offset) or limit \(limit) is outside the supported range."
        case .invalidTitle:
            return "Enter a title between 1 and 160 characters."
        case .invalidEngine:
            return "Choose one of the twenty supported engines."
        case .invalidScene:
            return "Choose a Cocos scene UUID or project-relative .scene path (at most 512 UTF-8 bytes)."
        case .invalidChord:
            return "A key chord contains 1–8 valid key names, modifiers first."
        case .invalidInputAction:
            return "Use run, stop, logs, screenshot, chord, button, action or save."
        case .tooManyHistoryEntries(let count):
            return "At most 32 history entries can be requested at once (received \(count))."
        }
    }
}

public enum GameToolPathRule {
    public static func validate(_ value: String) throws -> GameRelativePath {
        do {
            let path = try GameRelativePath(value)
            guard path.value.utf8.count <= 1_024 else { throw GameToolContractError.invalidPath(value) }
            return path
        } catch let error as GameToolContractError {
            throw error
        } catch {
            throw GameToolContractError.invalidPath(value)
        }
    }

    public static func validateDirectory(_ value: String?) throws -> String? {
        guard let value, !value.isEmpty, value != "." else { return nil }
        return try validate(value).value
    }
}

public struct GameInspectArguments: Codable, Equatable, Sendable {
    public var projectID: UUID?
    public var root: String?
    public var includeFiles: Bool?
    public var offset: Int?
    public var limit: Int?

    public init(projectID: UUID? = nil, root: String? = nil, includeFiles: Bool? = nil,
                offset: Int? = nil, limit: Int? = nil) {
        self.projectID = projectID
        self.root = root
        self.includeFiles = includeFiles
        self.offset = offset
        self.limit = limit
    }

    public func validate() throws {
        _ = try GameToolPathRule.validateDirectory(root)
        let offset = offset ?? 0, limit = limit ?? 100
        guard offset >= 0, (1...200).contains(limit) else {
            throw GameToolContractError.invalidPage(offset: offset, limit: limit)
        }
    }
}

public struct GameReadArguments: Codable, Equatable, Sendable {
    public var projectID: UUID?
    public var path: String
    public var offset: Int?
    public var limit: Int?

    public init(projectID: UUID? = nil, path: String, offset: Int? = nil, limit: Int? = nil) {
        self.projectID = projectID
        self.path = path
        self.offset = offset
        self.limit = limit
    }

    public func validate() throws {
        _ = try GameToolPathRule.validate(path)
        let offset = offset ?? 0
        let limit = limit ?? 64 * 1_024
        guard offset >= 0, (1...128 * 1_024).contains(limit) else {
            throw GameToolContractError.invalidPage(offset: offset, limit: limit)
        }
    }
}

public struct GameEditOperation: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case write, remove, move
    }
    public var kind: Kind
    public var path: String?
    public var newPath: String?
    public var text: String?

    public init(write path: String, text: String) {
        self.kind = .write
        self.path = path
        self.text = text
    }
    public init(remove path: String) {
        self.kind = .remove
        self.path = path
    }
    public init(move from: String, to: String) {
        self.kind = .move
        self.path = from
        self.newPath = to
    }
}

public struct GameEditArguments: Codable, Equatable, Sendable {
    public var projectID: UUID
    public var expectedRevision: String
    public var operations: [GameEditOperation]
    public var message: String?

    public init(projectID: UUID, expectedRevision: String,
                operations: [GameEditOperation], message: String? = nil) {
        self.projectID = projectID
        self.expectedRevision = expectedRevision
        self.operations = operations
        self.message = message
    }

    public func validate() throws {
        guard !expectedRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              expectedRevision.utf8.count <= 256 else { throw GameToolContractError.invalidRevision }
        guard (1...64).contains(operations.count) else {
            throw GameToolContractError.tooManyOperations(operations.count)
        }
        var total = 0
        var paths = Set<String>()
        for operation in operations {
            guard let path = operation.path else { throw GameToolContractError.invalidPath("") }
            let validated = try GameToolPathRule.validate(path)
            guard paths.insert(validated.value).inserted else {
                throw GameToolContractError.invalidPath(path)
            }
            switch operation.kind {
            case .write:
                guard let text = operation.text,
                      let data = text.data(using: .utf8) else {
                    throw GameToolContractError.invalidPath(path)
                }
                total += data.count
                guard total <= 2 * 1_024 * 1_024 else { throw GameToolContractError.tooMuchText(total) }
            case .remove:
                guard operation.text == nil, operation.newPath == nil else {
                    throw GameToolContractError.invalidPath(path)
                }
            case .move:
                guard let newPath = operation.newPath, operation.text == nil else {
                    throw GameToolContractError.invalidPath(path)
                }
                let target = try GameToolPathRule.validate(newPath)
                guard paths.insert(target.value).inserted else {
                    throw GameToolContractError.invalidPath(newPath)
                }
            }
        }
    }
}

public struct GameHistoryArguments: Codable, Equatable, Sendable {
    public var projectID: UUID
    public var limit: Int?

    public init(projectID: UUID, limit: Int? = nil) {
        self.projectID = projectID
        self.limit = limit
    }

    public func validate() throws {
        let value = limit ?? 16
        guard (1...32).contains(value) else { throw GameToolContractError.tooManyHistoryEntries(value) }
    }
}

public struct GameRollbackArguments: Codable, Equatable, Sendable {
    public var projectID: UUID
    public var expectedRevision: String
    public var historicalRevision: String
    public var paths: [String]?

    public init(projectID: UUID, expectedRevision: String,
                historicalRevision: String, paths: [String]? = nil) {
        self.projectID = projectID
        self.expectedRevision = expectedRevision
        self.historicalRevision = historicalRevision
        self.paths = paths
    }

    public func validate() throws {
        guard !expectedRevision.isEmpty, expectedRevision.utf8.count <= 256 else {
            throw GameToolContractError.invalidRevision
        }
        guard !historicalRevision.isEmpty, historicalRevision.utf8.count <= 256 else {
            throw GameToolContractError.invalidRevision
        }
        if let paths {
            guard paths.count <= 64 else { throw GameToolContractError.tooManyOperations(paths.count) }
            for path in paths { _ = try GameToolPathRule.validate(path) }
        }
    }
}

public struct GameCreateArguments: Codable, Equatable, Sendable {
    public var title: String
    public var engine: GameEngineID
    /// Optional user-visible note. It is not a path, owner or environment.
    public var note: String?

    public init(title: String, engine: GameEngineID, note: String? = nil) {
        self.title = title
        self.engine = engine
        self.note = note
    }

    public func validate() throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...160).contains(trimmed.count),
              !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw GameToolContractError.invalidTitle
        }
        guard GameEngineID.allCases.contains(engine) else { throw GameToolContractError.invalidEngine }
        if let note, note.utf8.count > 4_096 { throw GameToolContractError.invalidTitle }
    }
}

public struct GameInputArguments: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Equatable, Sendable {
        case chord, button, action
    }
    public var projectID: UUID
    /// One simultaneous chord. A single-element array is a normal key press;
    /// alternatives are never encoded as a chord by this contract.
    public var keys: [String]?
    public var buttonID: String?
    public var action: Action
    public var actionName: String?
    public var durationMilliseconds: Int?

    public init(projectID: UUID, action: Action, keys: [String]? = nil,
                buttonID: String? = nil, actionName: String? = nil,
                durationMilliseconds: Int? = nil) {
        self.projectID = projectID
        self.action = action
        self.keys = keys
        self.buttonID = buttonID
        self.actionName = actionName
        self.durationMilliseconds = durationMilliseconds
    }

    public func validate() throws {
        guard GameEngineID.allCases.count == 20 else { throw GameToolContractError.invalidEngine }
        let duration = durationMilliseconds ?? 80
        guard (16...2_000).contains(duration) else { throw GameToolContractError.invalidInputAction }
        switch action {
        case .chord:
            guard let keys, (1...8).contains(keys.count), buttonID == nil, actionName == nil else {
                throw GameToolContractError.invalidChord
            }
            for key in keys {
                let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, value.utf8.count <= 32,
                      value.unicodeScalars.allSatisfy({ scalar in
                          CharacterSet.alphanumerics.contains(scalar)
                              || "_-=+[];,./'\\`".unicodeScalars.contains(scalar)
                              || scalar == " "
                      }) else { throw GameToolContractError.invalidChord }
            }
        case .button:
            guard let buttonID, !buttonID.isEmpty, buttonID.utf8.count <= 64,
                  keys == nil, actionName == nil,
                  buttonID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }) else {
                throw GameToolContractError.invalidInputAction
            }
        case .action:
            guard let actionName,
                  ["down", "left", "right", "up", "a", "b", "c", "x", "y", "z", "l", "r",
                   "shift", "control", "alt", "confirm", "cancel", "menu"].contains(actionName),
                  keys == nil, buttonID == nil else {
                throw GameToolContractError.invalidInputAction
            }
        }
    }
}

public struct GameRunArguments: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Equatable, Sendable {
        case run, stop, logs, screenshot, save, saveAndStop
    }
    public var projectID: UUID
    public var action: Action
    public var offset: Int?
    public var limit: Int?

    public init(projectID: UUID, action: Action, offset: Int? = nil, limit: Int? = nil) {
        self.projectID = projectID
        self.action = action
        self.offset = offset
        self.limit = limit
    }

    public func validate() throws {
        let offset = offset ?? 0
        let limit = limit ?? 8 * 1_024
        guard offset >= 0, (1...64 * 1_024).contains(limit) else {
            throw GameToolContractError.invalidPage(offset: offset, limit: limit)
        }
    }
}

public struct GameBuildArguments: Codable, Equatable, Sendable {
    public enum Output: String, Codable, Equatable, Sendable {
        case web, source, nativeProject, nativeInstaller
    }
    public var projectID: UUID
    public var engine: GameEngineID
    public var output: Output
    public var routeIDs: [String]?
    public var distributionProfileID: String?

    public init(projectID: UUID, engine: GameEngineID, output: Output,
                routeIDs: [String]? = nil, distributionProfileID: String? = nil) {
        self.projectID = projectID
        self.engine = engine
        self.output = output
        self.routeIDs = routeIDs
        self.distributionProfileID = distributionProfileID
    }

    public func validate() throws {
        guard GameEngineID.allCases.contains(engine) else { throw GameToolContractError.invalidEngine }
        if let routeIDs {
            guard (1...16).contains(routeIDs.count),
                  routeIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
                throw GameToolContractError.invalidInputAction
            }
        }
        if let distributionProfileID {
            guard !distributionProfileID.isEmpty, distributionProfileID.utf8.count <= 128 else {
                throw GameToolContractError.invalidInputAction
            }
        }
    }
}

/// Result shapes returned by the App tools. They contain no host path, token
/// or imported authority; projectID/owner are the host-resolved values.
public struct GameProjectSummary: Codable, Equatable, Sendable {
    public let projectID: UUID
    public let title: String
    public let engine: String?
    public let recordedEngine: String?
    public let revision: String
    public let selectedRoot: String?
    public let engineCandidates: [String]
    public let rootCandidates: [String]
    public let fileCount: Int
    public let directoryCount: Int
    public let hasFiles: Bool
    public let requiresExplicitChoice: Bool
    public let inputDeclarationPath: String?
    public let sourceLicense: String?
    public let enginePrerequisites: [String]
    public let status: String
    public let files: GameFileListResult?

    public init(projectID: UUID, title: String, engine: String?, recordedEngine: String?,
                revision: String, selectedRoot: String?, engineCandidates: [String],
                rootCandidates: [String], fileCount: Int, directoryCount: Int, hasFiles: Bool,
                requiresExplicitChoice: Bool, inputDeclarationPath: String?, sourceLicense: String?,
                enginePrerequisites: [String], status: String, files: GameFileListResult? = nil) {
        self.projectID = projectID
        self.title = title
        self.engine = engine
        self.recordedEngine = recordedEngine
        self.revision = revision
        self.selectedRoot = selectedRoot
        self.engineCandidates = engineCandidates
        self.rootCandidates = rootCandidates
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.hasFiles = hasFiles
        self.requiresExplicitChoice = requiresExplicitChoice
        self.inputDeclarationPath = inputDeclarationPath
        self.sourceLicense = sourceLicense
        self.enginePrerequisites = enginePrerequisites
        self.status = status
        self.files = files
    }
}

public struct GameFileListResult: Codable, Equatable, Sendable {
    public let revision: String
    public let directory: String
    public let entries: [GameProjectEntry]
    public let offset: Int
    public let nextOffset: Int?
    public let totalEntries: Int

    public init(revision: String, directory: String, entries: [GameProjectEntry],
                offset: Int, nextOffset: Int?, totalEntries: Int) {
        self.revision = revision
        self.directory = directory
        self.entries = entries
        self.offset = offset
        self.nextOffset = nextOffset
        self.totalEntries = totalEntries
    }
}

public struct GameFileReadResult: Codable, Equatable, Sendable {
    public let projectID: UUID
    public let path: String
    public let revision: String
    public let sha256: String
    public let totalBytes: Int
    public let offset: Int
    public let nextOffset: Int?
    public let text: String

    public init(projectID: UUID, path: String, revision: String, sha256: String, totalBytes: Int,
                offset: Int, nextOffset: Int?, text: String) {
        self.projectID = projectID
        self.path = path
        self.revision = revision
        self.sha256 = sha256
        self.totalBytes = totalBytes
        self.offset = offset
        self.nextOffset = nextOffset
        self.text = text
    }
}

public struct GameEditReceipt: Codable, Equatable, Sendable {
    public let projectID: UUID
    public let previousRevision: String
    public let revision: String
    public let changedPaths: [String]
    public let fileCount: Int
    public let directoryCount: Int

    public init(projectID: UUID, previousRevision: String, revision: String, changedPaths: [String],
                fileCount: Int, directoryCount: Int) {
        self.projectID = projectID
        self.previousRevision = previousRevision
        self.revision = revision
        self.changedPaths = changedPaths
        self.fileCount = fileCount
        self.directoryCount = directoryCount
    }
}

public struct GameHistoryResult: Codable, Equatable, Sendable {
    public let projectID: UUID
    public let revisions: [GameRevisionSummary]

    public init(projectID: UUID, revisions: [GameRevisionSummary]) {
        self.projectID = projectID
        self.revisions = revisions
    }
}

public struct GameRunReceipt: Codable, Equatable, Sendable {
    public let projectID: UUID
    public let runID: UUID?
    public let action: String
    public let phase: String
    public let stopConfirmed: Bool?
    public let automaticSave: String?
    public let screenshotSHA256: String?
    public let logs: String?
    public let diagnostic: String?

    public init(projectID: UUID, runID: UUID?, action: String, phase: String, stopConfirmed: Bool?,
                automaticSave: String?, screenshotSHA256: String?, logs: String?, diagnostic: String?) {
        self.projectID = projectID
        self.runID = runID
        self.action = action
        self.phase = phase
        self.stopConfirmed = stopConfirmed
        self.automaticSave = automaticSave
        self.screenshotSHA256 = screenshotSHA256
        self.logs = logs
        self.diagnostic = diagnostic
    }
}

public struct GameBuildReceipt: Codable, Equatable, Sendable {
    public let projectID: UUID
    public let buildID: UUID?
    public let engine: String
    public let revision: String
    public let ready: Bool
    public let outputKind: String
    public let artifactNames: [String]
    public let missingPrerequisites: [String]
    public let diagnostic: String?

    public init(projectID: UUID, buildID: UUID?, engine: String, revision: String, ready: Bool,
                outputKind: String, artifactNames: [String], missingPrerequisites: [String],
                diagnostic: String?) {
        self.projectID = projectID
        self.buildID = buildID
        self.engine = engine
        self.revision = revision
        self.ready = ready
        self.outputKind = outputKind
        self.artifactNames = artifactNames
        self.missingPrerequisites = missingPrerequisites
        self.diagnostic = diagnostic
    }
}

public enum GameToolOutput {
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

public struct GameInstrumentArguments: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Equatable, Sendable { case plan, apply }
    public var projectID: UUID
    public var engine: GameEngineID
    public var action: Action
    public var expectedRevision: String?
    /// Cocos Creator scene UUID or project-relative .scene path. Required only
    /// when the project has several scenes and no actual startScene metadata.
    public var scene: String?

    public init(projectID: UUID, engine: GameEngineID, action: Action,
                expectedRevision: String? = nil, scene: String? = nil) {
        self.projectID = projectID
        self.engine = engine
        self.action = action
        self.expectedRevision = expectedRevision
        self.scene = scene
    }

    public func validate() throws {
        guard GameEngineID.allCases.contains(engine) else { throw GameToolContractError.invalidEngine }
        if let scene {
            let trimmed = scene.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, scene.utf8.count <= 512,
                  !scene.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw GameToolContractError.invalidScene
            }
        }
        if action == .apply {
            guard let expectedRevision, !expectedRevision.isEmpty,
                  expectedRevision.utf8.count <= 256 else {
                throw GameToolContractError.invalidRevision
            }
        }
    }
}

public struct GameSaveToSpaceArguments: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Equatable, Sendable { case createNew, updateExisting }
    public var title: String
    public var projectID: UUID?
    public var destinationProjectID: UUID?
    public var mode: Mode

    public init(title: String, projectID: UUID? = nil,
                destinationProjectID: UUID? = nil, mode: Mode = .createNew) {
        self.title = title
        self.projectID = projectID
        self.destinationProjectID = destinationProjectID
        self.mode = mode
    }

    public func validate() throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...160).contains(trimmed.count),
              !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw GameToolContractError.invalidTitle
        }
        if mode == .updateExisting, destinationProjectID == nil {
            throw GameToolContractError.invalidProjectID
        }
    }
}

public struct GameSaveToSpaceReceipt: Codable, Equatable, Sendable {
    public let sourceProjectID: UUID
    public let destinationProjectID: UUID
    public let destinationRevision: String
    public let copiedRevision: String
    public let engineHint: String?
    public let requiresReopen: Bool
    public let cleanupPending: Bool

    public init(sourceProjectID: UUID, destinationProjectID: UUID, destinationRevision: String,
                copiedRevision: String, engineHint: String?, requiresReopen: Bool, cleanupPending: Bool) {
        self.sourceProjectID = sourceProjectID
        self.destinationProjectID = destinationProjectID
        self.destinationRevision = destinationRevision
        self.copiedRevision = copiedRevision
        self.engineHint = engineHint
        self.requiresReopen = requiresReopen
        self.cleanupPending = cleanupPending
    }
}
