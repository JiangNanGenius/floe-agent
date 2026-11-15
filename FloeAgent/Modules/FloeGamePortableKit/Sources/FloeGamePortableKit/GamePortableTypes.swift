// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameTouch

/// Portable-component failures are explicit and never turned into a fake
/// "ready" result. Engine runtime failures remain the host's service errors.
public enum GamePortableError: Error, Equatable, Sendable {
    case invalidResourceManifest(String)
    case resourceMismatch(String)
    case unsupportedEngine(GameEngineID)
    case templateMissing(String)
    case invalidInputDeclaration(String)
    case invalidArtifact(String)
    case destinationExists
    case io(String)
    case staleRevision(expected: String, actual: String)
    case limitExceeded(String)
    case unsupportedCapability(String)
    case contextMismatch
}

enum GamePortableValidation {
    static func identifier(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 256
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

public enum GamePortableReadiness: String, Codable, Equatable, Sendable {
    /// A complete Web entry exists and can be served by the host's artifact package.
    case webReady
    /// The source is preserved but the pinned engine tool/runtime must build it.
    case buildRequired
    /// Source is preserved; no supported Web route is claimed for this layout.
    case sourceOnly
    /// A concrete verified limitation prevents Web play (reported with warnings).
    case blocked
}

public enum GamePortableSupport: String, Codable, Equatable, Sendable {
    case supported
    case buildRequired
    /// The game can save inside its own engine/runtime, but the host cannot
    /// snapshot/restore that state through the Web bridge.
    case engineInternal
    case unsupported
    case unknown
}

public struct GamePortableCapabilities: Codable, Equatable, Sendable {
    public let readiness: GamePortableReadiness
    public let input: GamePortableSupport
    public let stateSnapshot: GamePortableSupport
    public let restart: GamePortableSupport
    public let save: GamePortableSupport
    public let choose: GamePortableSupport
    public init(readiness: GamePortableReadiness, input: GamePortableSupport,
                stateSnapshot: GamePortableSupport, restart: GamePortableSupport,
                save: GamePortableSupport, choose: GamePortableSupport) {
        self.readiness = readiness; self.input = input; self.stateSnapshot = stateSnapshot
        self.restart = restart; self.save = save; self.choose = choose
    }
}

public struct GamePortableWarning: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Equatable, Sendable {
        case missingEntry
        case missingRuntime
        case buildRequired
        case encryptedAssets
        case nativePlugin
        case multipleRoots
        case unknownInputs
        case licenseReview
        case hostSnapshotUnavailable
        case webBeta
        case customScripts
        case unsupportedPlatform
        case runtimeUnverified
        case importedProjectNotRewritten
    }
    public let code: Code
    public let message: String
    public let path: String?
    public init(code: Code, message: String, path: String? = nil) {
        self.code = code; self.message = message; self.path = path
    }
}

public struct GamePortableRuntimeIdentity: Codable, Equatable, Sendable {
    public let id: String
    public let version: String
    public let upstreamURL: String
    public let revision: String?
    public let license: String

    public init(id: String, version: String, upstreamURL: String, revision: String?, license: String) throws {
        guard GamePortableValidation.identifier(id), GamePortableValidation.identifier(version),
              URL(string: upstreamURL)?.scheme != nil, GamePortableValidation.identifier(license) else {
            throw GamePortableError.invalidResourceManifest("runtime identity")
        }
        self.id = id; self.version = version; self.upstreamURL = upstreamURL
        self.revision = revision; self.license = license
    }
}

public enum GamePortableSourceFormat: String, Codable, Equatable, Sendable {
    case rpgMakerMVProject
    case rpgMakerMVWeb
    case loveSource
    case lovePackage
    case loveJSWeb
    case renpyProject
    case renpyWeb
    case unknown
}

public struct GamePortableProfile: Codable, Equatable, Sendable {
    public let engine: GameEngineID
    public let sourceFormat: GamePortableSourceFormat
    public let entry: GameRelativePath?
    public let readiness: GamePortableReadiness
    public let capabilities: GamePortableCapabilities
    public let runtime: GamePortableRuntimeIdentity
    public let inputDeclaration: GamePortableInputDeclaration?
    /// Relative paths only. Absolute checkout roots stay in the host context.
    public let keyPaths: [GameRelativePath]
    public let warnings: [GamePortableWarning]

    public init(engine: GameEngineID, sourceFormat: GamePortableSourceFormat,
                entry: GameRelativePath?, readiness: GamePortableReadiness,
                capabilities: GamePortableCapabilities, runtime: GamePortableRuntimeIdentity,
                inputDeclaration: GamePortableInputDeclaration?,
                keyPaths: [GameRelativePath], warnings: [GamePortableWarning]) {
        self.engine = engine; self.sourceFormat = sourceFormat; self.entry = entry
        self.readiness = readiness; self.capabilities = capabilities; self.runtime = runtime
        self.inputDeclaration = inputDeclaration; self.keyPaths = keyPaths; self.warnings = warnings
    }
}

/// A verified host-owned snapshot identity plus a bounded relative file list.
/// The host still holds the original-file lease and rechecks its context.
public struct GamePortableProjectDescriptor: Sendable {
    public let rootURL: URL
    public let projectID: UUID
    public let owner: GameProjectOwner
    public let revision: String
    public let context: GameProjectContext?
    public let files: [GameRelativePath]

    public init(rootURL: URL, projectID: UUID, owner: GameProjectOwner, revision: String,
                context: GameProjectContext?, files: [GameRelativePath]) throws {
        guard rootURL.isFileURL, GamePortableValidation.identifier(revision) else {
            throw GamePortableError.contextMismatch
        }
        if case .space(let recordID) = owner, recordID != projectID {
            throw GamePortableError.contextMismatch
        }
        if let context {
            guard context.projectID == projectID, context.owner == owner,
                  context.rootURL == rootURL.standardizedFileURL.resolvingSymlinksInPath(),
                  context.savedRevision == revision else { throw GamePortableError.contextMismatch }
        }
        let unique = Dictionary(files.map { ($0, true) }, uniquingKeysWith: { lhs, _ in lhs })
        guard unique.count == files.count, files.count <= 100_000 else {
            throw GamePortableError.invalidArtifact("duplicate or excessive file list")
        }
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.projectID = projectID; self.owner = owner; self.revision = revision
        self.context = context; self.files = files.sorted { $0.value < $1.value }
    }

    /// Read-only CLI/qualification convenience: enumerates the root without a
    /// repository identity. Production hosts use the repository-backed initializer.
    public init(rootURL: URL, revision: String = "cli-inspection") throws {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let entries = try GamePortableFileAccess.enumerate(root: root)
        let projectID = UUID()
        try self.init(rootURL: root, projectID: projectID, owner: .space(recordID: projectID),
                      revision: revision, context: nil,
                      files: entries.filter { !$0.directory }.map(\.path))
    }

    public init(project: GameStoredProject, rootURL: URL, context: GameProjectContext) throws {
        try self.init(rootURL: rootURL, projectID: project.projectID, owner: project.owner,
                      revision: project.revision, context: context,
                      files: project.files.map(\.path))
    }

    public func contains(_ path: String) -> Bool {
        guard let relative = try? GameRelativePath(path) else { return false }
        return files.contains(relative)
    }

    public func paths(withPrefix prefix: String) -> [GameRelativePath] {
        files.filter { $0.value.hasPrefix(prefix) }
    }

    public func read(_ path: String, maximumBytes: Int = 65_536) throws -> Data {
        guard contains(path) else { throw GamePortableError.invalidArtifact(path) }
        return try GamePortableFileAccess.read(root: rootURL, path: path, maximumBytes: maximumBytes)
    }
}

/// Project-owned keyboard declaration. It is data only: no command, evaluator,
/// native capability or permission is represented here.
public struct GamePortableInputDeclaration: Codable, Equatable, Sendable {
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
                movement: Movement, buttons: [Button]) throws {
        self.schemaVersion = schemaVersion; self.engine = engine
        self.movement = movement; self.buttons = buttons
        try validate()
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(schemaVersion: values.decode(Int.self, forKey: .schemaVersion),
                      engine: values.decode(GameEngineID.self, forKey: .engine),
                      movement: values.decodeIfPresent(Movement.self, forKey: .movement) ?? .init(),
                      buttons: values.decodeIfPresent([Button].self, forKey: .buttons) ?? [])
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, engine, movement, buttons }

    public static func decode(_ data: Data) throws -> Self {
        do {
            let value = try JSONDecoder().decode(Self.self, from: data)
            // Validate original bytes as well: decoding a typed model must not
            // hide unknown command-like fields before the shared validator.
            _ = try GameTouchProjectBindings(json: data, engine: value.engine)
            return value
        } catch let error as GamePortableError {
            throw error
        } catch {
            throw GamePortableError.invalidInputDeclaration("JSON or required fields")
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func validate() throws {
        // One contract across engine adapters and the native settings UI:
        // arrays are chords, at most 64 controls / 8 unique keys per chord.
        do { _ = try GameTouchProjectBindings(json: JSONEncoder().encode(self), engine: engine) }
        catch { throw GamePortableError.invalidInputDeclaration(String(describing: error)) }
    }
}

/// Keys accepted by the existing GameWebPlayer keyboard contract: fixed
/// `GameKeyboardKey` raw values or browser DOM codes. This is a vocabulary,
/// not a command language.
public enum GamePortableKeyboardVocabulary {
    public static let rawKeys: Set<String> = [
        "left", "right", "up", "down", "enter", "escape", "space", "tab", "backspace", "delete", "insert", "home", "end", "pageUp", "pageDown", "shift", "control", "alt", "meta", "rightShift", "rightControl", "rightAlt", "rightMeta", "capsLock", "numLock", "scrollLock", "printScreen", "pause", "contextMenu", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "minus", "equal", "leftBracket", "rightBracket", "backslash", "semicolon", "quote", "backquote", "comma", "period", "slash", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12", "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20", "f21", "f22", "f23", "f24", "numpad0", "numpad1", "numpad2", "numpad3", "numpad4", "numpad5", "numpad6", "numpad7", "numpad8", "numpad9", "numpadDecimal", "numpadEqual", "numpadDivide", "numpadMultiply", "numpadSubtract", "numpadAdd", "numpadEnter"
    ]
    private static let domCodePattern = #"^(Key[A-Z]|Digit[0-9]|F([1-9]|1[0-9]|2[0-4])|Arrow(Left|Right|Up|Down)|Numpad([0-9]|Decimal|Equal|Divide|Multiply|Subtract|Add|Enter)|Shift(Left|Right)|Control(Left|Right)|Alt(Left|Right)|Meta(Left|Right)|Backspace|Delete|Insert|Home|End|PageUp|PageDown|CapsLock|NumLock|ScrollLock|PrintScreen|Pause|ContextMenu|Semicolon|Quote|Comma|Period|Slash|Backquote|BracketLeft|BracketRight|Backslash|Minus|Equal|Space|Enter|Escape|Tab)$"#
    public static func isValid(_ key: String) -> Bool {
        guard !key.isEmpty, key.utf8.count <= 32,
              !key.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        if rawKeys.contains(key) { return true }
        return key.range(of: domCodePattern, options: .regularExpression) != nil
    }
}

public struct GamePortableFileRecord: Codable, Equatable, Sendable {
    public let path: GameRelativePath
    public let sha256: String
    public let bytes: Int
    public let executable: Bool
    public init(path: GameRelativePath, sha256: String, bytes: Int, executable: Bool = false) {
        self.path = path; self.sha256 = sha256; self.bytes = bytes; self.executable = executable
    }
}
