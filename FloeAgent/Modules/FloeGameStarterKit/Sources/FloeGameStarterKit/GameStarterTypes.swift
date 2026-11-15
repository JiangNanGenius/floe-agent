// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameTouch

/// The truthful state of one starter. It describes what the source contains,
/// not whether an editor, engine or build has been run.
public enum GameStarterReadiness: String, Codable, Equatable, Sendable {
    /// Complete source exists; only a normal engine build/tool may be needed.
    case completeSource
    /// Source exists and a pinned build tool/runtime is required for an artifact.
    case sourceWithBuildTool
    /// Source exists and a licensed engine editor/runtime is required.
    case sourceWithEditor
    /// The starter source is complete but a pinned engine runtime pack is
    /// required before files can be written (it is verified byte-for-byte).
    case runtimePackRequired
}

public enum GameStarterTemplateKind: String, Codable, Equatable, Sendable {
    case `static`
    case delegated
    case runtimePack
}

public enum GameStarterPrerequisiteKind: String, Codable, Equatable, Sendable {
    case editor, runtime, buildTool, resourcePack, packageManager
}

public enum GameStarterPrerequisiteTarget: String, Codable, Equatable, Sendable {
    case edit, build, play
}

public struct GameStarterPrerequisite: Codable, Equatable, Sendable {
    public let kind: GameStarterPrerequisiteKind
    public let name: String
    public let version: String
    public let url: String
    public let notes: String
    public let requiredFor: [GameStarterPrerequisiteTarget]

    public init(kind: GameStarterPrerequisiteKind, name: String, version: String,
                url: String, notes: String, requiredFor: [GameStarterPrerequisiteTarget]) {
        self.kind = kind; self.name = name; self.version = version
        self.url = url; self.notes = notes; self.requiredFor = requiredFor
    }
}

public struct GameStarterTemplateFile: Codable, Equatable, Sendable {
    public let path: GameRelativePath
    public let sha256: String
    public let bytes: Int

    public init(path: GameRelativePath, sha256: String, bytes: Int) {
        self.path = path; self.sha256 = sha256; self.bytes = bytes
    }
}

public struct GameStarterRuntimeFile: Codable, Equatable, Sendable {
    public let path: GameRelativePath
    public let sha256: String
    public let bytes: Int

    public init(path: GameRelativePath, sha256: String, bytes: Int) {
        self.path = path; self.sha256 = sha256; self.bytes = bytes
    }
}

public struct GameStarterRuntimePack: Codable, Equatable, Sendable {
    public let id: String
    public let engineVersion: String
    public let license: String
    public let upstream: String
    public let sourceCommit: String?
    public let files: [GameStarterRuntimeFile]

    public init(id: String, engineVersion: String, license: String, upstream: String,
                sourceCommit: String?, files: [GameStarterRuntimeFile]) {
        self.id = id; self.engineVersion = engineVersion; self.license = license
        self.upstream = upstream; self.sourceCommit = sourceCommit; self.files = files
    }
}

/// A bounded, data-only keyboard declaration. It is encoded into the project's
/// `floe-inputs.json` and validated by the shared native touch validator.
public struct GameStarterInputDeclaration: Codable, Equatable, Sendable {
    public struct Movement: Codable, Equatable, Sendable {
        public let left: [String]
        public let right: [String]
        public let up: [String]
        public let down: [String]
        public init(left: [String] = [], right: [String] = [], up: [String] = [], down: [String] = []) {
            self.left = left; self.right = right; self.up = up; self.down = down
        }
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(left: try values.decodeIfPresent([String].self, forKey: .left) ?? [],
                      right: try values.decodeIfPresent([String].self, forKey: .right) ?? [],
                      up: try values.decodeIfPresent([String].self, forKey: .up) ?? [],
                      down: try values.decodeIfPresent([String].self, forKey: .down) ?? [])
        }
        private enum CodingKeys: String, CodingKey { case left, right, up, down }
    }

    public struct Button: Codable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let keys: [String]
        public init(id: String, label: String, keys: [String]) {
            self.id = id; self.label = label; self.keys = keys
        }
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(id: try values.decode(String.self, forKey: .id),
                      label: try values.decodeIfPresent(String.self, forKey: .label) ?? "",
                      keys: try values.decode([String].self, forKey: .keys))
        }
        private enum CodingKeys: String, CodingKey { case id, label, keys }
    }

    public let schemaVersion: Int
    public let engine: GameEngineID
    public let movement: Movement
    public let buttons: [Button]

    public init(schemaVersion: Int = 1, engine: GameEngineID,
                movement: Movement, buttons: [Button]) {
        self.schemaVersion = schemaVersion; self.engine = engine
        self.movement = movement; self.buttons = buttons
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, engine, movement, buttons }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(schemaVersion: try values.decode(Int.self, forKey: .schemaVersion),
                  engine: try values.decode(GameEngineID.self, forKey: .engine),
                  movement: try values.decodeIfPresent(Movement.self, forKey: .movement) ?? .init(),
                  buttons: try values.decodeIfPresent([Button].self, forKey: .buttons) ?? [])
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Uses the existing shared native touch declaration validator, including
    /// key vocabulary, chord limits, duplicate IDs and engine identity.
    public func validate() throws {
        let data = try encoded()
        guard data.count <= GameTouchProjectBindings.maximumDeclarationBytes else {
            throw GameStarterError.limitExceeded("floe-inputs.json")
        }
        _ = try GameTouchProjectBindings(json: data, engine: engine)
    }
}

public struct GameStarterDescriptor: Codable, Equatable, Sendable {
    public let engine: GameEngineID
    public let displayName: String
    public let starterVersion: String
    public let entry: GameRelativePath
    public let webEntry: GameRelativePath?
    public let readiness: GameStarterReadiness
    public let sourceLicense: String
    public let engineLicense: String
    public let templateKind: GameStarterTemplateKind
    public let templateRoot: String?
    public let provider: String?
    public let runtimePack: GameStarterRuntimePack?
    public let files: [GameStarterTemplateFile]
    public let expectedFiles: [GameRelativePath]
    public let prerequisites: [GameStarterPrerequisite]
    public let notes: [String]
    public let defaultInput: GameStarterInputDeclaration
    public let sourcePins: [String]

    public init(engine: GameEngineID, displayName: String, starterVersion: String,
                entry: GameRelativePath, webEntry: GameRelativePath?,
                readiness: GameStarterReadiness, sourceLicense: String,
                engineLicense: String, templateKind: GameStarterTemplateKind,
                templateRoot: String?, provider: String?,
                runtimePack: GameStarterRuntimePack?,
                files: [GameStarterTemplateFile], expectedFiles: [GameRelativePath],
                prerequisites: [GameStarterPrerequisite], notes: [String],
                defaultInput: GameStarterInputDeclaration, sourcePins: [String]) {
        self.engine = engine; self.displayName = displayName
        self.starterVersion = starterVersion; self.entry = entry; self.webEntry = webEntry
        self.readiness = readiness; self.sourceLicense = sourceLicense
        self.engineLicense = engineLicense; self.templateKind = templateKind
        self.templateRoot = templateRoot; self.provider = provider
        self.runtimePack = runtimePack; self.files = files
        self.expectedFiles = expectedFiles; self.prerequisites = prerequisites
        self.notes = notes; self.defaultInput = defaultInput; self.sourcePins = sourcePins
    }

    private enum CodingKeys: String, CodingKey {
        case engine, displayName, starterVersion, entry, webEntry, readiness
        case sourceLicense, engineLicense, templateKind, templateRoot, provider
        case runtimePack, files, expectedFiles, prerequisites, notes, defaultInput, sourcePins
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            engine: try values.decode(GameEngineID.self, forKey: .engine),
            displayName: try values.decode(String.self, forKey: .displayName),
            starterVersion: try values.decode(String.self, forKey: .starterVersion),
            entry: try values.decode(GameRelativePath.self, forKey: .entry),
            webEntry: try values.decodeIfPresent(GameRelativePath.self, forKey: .webEntry),
            readiness: try values.decode(GameStarterReadiness.self, forKey: .readiness),
            sourceLicense: try values.decode(String.self, forKey: .sourceLicense),
            engineLicense: try values.decode(String.self, forKey: .engineLicense),
            templateKind: try values.decode(GameStarterTemplateKind.self, forKey: .templateKind),
            templateRoot: try values.decodeIfPresent(String.self, forKey: .templateRoot),
            provider: try values.decodeIfPresent(String.self, forKey: .provider),
            runtimePack: try values.decodeIfPresent(GameStarterRuntimePack.self, forKey: .runtimePack),
            files: try values.decodeIfPresent([GameStarterTemplateFile].self, forKey: .files) ?? [],
            expectedFiles: try values.decode([GameRelativePath].self, forKey: .expectedFiles),
            prerequisites: try values.decode([GameStarterPrerequisite].self, forKey: .prerequisites),
            notes: try values.decode([String].self, forKey: .notes),
            defaultInput: try values.decode(GameStarterInputDeclaration.self, forKey: .defaultInput),
            sourcePins: try values.decodeIfPresent([String].self, forKey: .sourcePins) ?? []
        )
    }
}

public enum GameStarterSelectionSource: String, Codable, Equatable, Sendable {
    case user, aiSuggestion, projectMetadata
}

public struct GameStarterSuggestion: Equatable, Sendable {
    public let engine: GameEngineID
    public let source: GameStarterSelectionSource
    public let reason: String?
    public init(engine: GameEngineID, source: GameStarterSelectionSource, reason: String? = nil) {
        self.engine = engine; self.source = source; self.reason = reason
    }
}

/// Optional adapter for the existing AI/task layer. It only proposes an engine;
/// the user selection passed to the scaffolder is authoritative.
public protocol GameStarterEngineSuggester: Sendable {
    func suggestEngine(title: String, inspection: GameProjectInspection,
                       available: [GameEngineID]) async throws -> GameStarterSuggestion?
}

public enum GameStarterError: Error, Equatable, Sendable {
    case unsupportedEngine(GameEngineID)
    case missingRuntimePack(engine: GameEngineID, packID: String, expectedFiles: [String])
    case invalidCatalog(String)
    case invalidProjectState(String)
    case nonEmptyProject
    case wrongOwner
    case staleRevision(expected: String, actual: String)
    case contextChanged
    case engineMismatch(expected: GameEngineID, actual: GameEngineID?)
    case unsafePath(String)
    case limitExceeded(String)
    case invalidTemplate(String)
    case cancelled
    case busy
    case io(String)
}

public struct GameStarterLimits: Sendable {
    public static let standard = try! GameStarterLimits()

    public let maximumFiles: Int
    public let maximumFileBytes: Int
    public let maximumTotalBytes: Int
    public let maximumPathBytes: Int
    public let maximumEntries: Int

    public init(maximumFiles: Int = 4_096, maximumFileBytes: Int = 32 * 1_024 * 1_024,
                maximumTotalBytes: Int = 128 * 1_024 * 1_024,
                maximumPathBytes: Int = 1_024, maximumEntries: Int = 8_192) throws {
        guard (1...65_536).contains(maximumFiles),
              (1...256 * 1_024 * 1_024).contains(maximumFileBytes),
              maximumTotalBytes >= maximumFileBytes,
              maximumTotalBytes <= 512 * 1_024 * 1_024,
              (1...1_024).contains(maximumPathBytes),
              maximumEntries >= maximumFiles,
              maximumEntries <= 100_000 else { throw GameStarterError.limitExceeded("starterLimits") }
        self.maximumFiles = maximumFiles; self.maximumFileBytes = maximumFileBytes
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumPathBytes = maximumPathBytes; self.maximumEntries = maximumEntries
    }
}

public enum GameStarterTitle {
    /// Same bounded identity rules as the repository context. Control
    /// characters are rejected so an INI/YAML/JSON title cannot inject lines.
    public static func validate(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw GameStarterError.invalidTemplate("title")
        }
    }
}

public struct GameStarterInitialization: Sendable {
    public let project: GameStoredProject
    public let context: GameProjectContext
    public let descriptor: GameStarterDescriptor
    public let title: String
    public let files: [GameProjectFile]
    public let manifestSHA256: String
    public let stageFileCount: Int
    public let stageByteCount: Int

    public init(project: GameStoredProject, context: GameProjectContext,
                descriptor: GameStarterDescriptor, title: String,
                files: [GameProjectFile], manifestSHA256: String,
                stageFileCount: Int, stageByteCount: Int) {
        self.project = project; self.context = context
        self.descriptor = descriptor; self.title = title; self.files = files
        self.manifestSHA256 = manifestSHA256
        self.stageFileCount = stageFileCount; self.stageByteCount = stageByteCount
    }

    public var engine: GameEngineID { descriptor.engine }
    /// nil when the host created the blank project before choosing an engine.
    /// `floe-game.json` still records the selected engine for recognition.
    public var repositoryEngine: GameEngineID? { project.engine }
}
