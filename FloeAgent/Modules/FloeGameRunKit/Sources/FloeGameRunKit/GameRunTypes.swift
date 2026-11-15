// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameWebKit
import FloeGamePortableKit

/// Bounded inputs for the run preparer. The limits apply to the selected
/// project root only; no host file outside that root is enumerated.
public struct GameRunPreparationLimits: Sendable, Equatable {
    public let maximumEntries: Int
    public let maximumDepth: Int
    public let maximumFileBytes: Int
    public let maximumProjectBytes: Int
    public let maximumIndexBytes: Int

    public init(maximumEntries: Int = 20_000, maximumDepth: Int = 32,
                maximumFileBytes: Int = 64 * 1_024 * 1_024,
                maximumProjectBytes: Int = 512 * 1_024 * 1_024,
                maximumIndexBytes: Int = 1 * 1_024 * 1_024) throws {
        guard (1...100_000).contains(maximumEntries),
              (1...32).contains(maximumDepth),
              (1...256 * 1_024 * 1_024).contains(maximumFileBytes),
              maximumProjectBytes >= maximumFileBytes,
              maximumProjectBytes <= 1_024 * 1_024 * 1_024,
              (1_024...4_194_304).contains(maximumIndexBytes) else {
            throw GameRunPreparationError.invalidConfiguration("limits")
        }
        self.maximumEntries = maximumEntries
        self.maximumDepth = maximumDepth
        self.maximumFileBytes = maximumFileBytes
        self.maximumProjectBytes = maximumProjectBytes
        self.maximumIndexBytes = maximumIndexBytes
    }

    public static let `default` = try! GameRunPreparationLimits()
}

/// A concrete thing the host must provide or judge before a route can run.
/// These values never grant a permission and are never decoded from imported
/// project metadata.
public enum GameRunPrerequisite: Equatable, Sendable {
    /// A reviewed, hash-verified data/resource directory (for example the
    /// prepared narrative runtimes or the official MIT MV CoreScript pack).
    case preparedResourcePack(id: String, detail: String)
    /// A pinned external toolchain/SDK that the host's existing jobs or CI
    /// service runs. The preparer itself never spawns it.
    case externalTool(id: String, detail: String)
    /// The host's typed job/build port is not configured for this route.
    case hostBuildProvider(id: String, detail: String)
    /// A non-Web engine runtime must be supplied by a guest/native environment.
    case guestRuntime(id: String, detail: String)
    /// The user/editor must supply a licensed engine runtime; Floe does not
    /// bundle or gate it on a developer account.
    case licensedRuntime(id: String, detail: String)
    /// The selected engine has no supported route for this project layout.
    case unsupportedRoute(id: String, detail: String)
}

public enum GameRunRouteAction: String, Codable, Equatable, Sendable {
    /// The selected root is already a complete offline Web project.
    case staticWeb
    /// An existing portable adapter assembles a Web artifact from source and
    /// an injected runtime/resource pack or host build port.
    case portableAssembly
    /// An existing narrative adapter builds a self-contained Web artifact.
    case narrativeAssembly
    /// An existing engine runtime pack is copied into the project tree.
    case runtimePackAssembly
    /// A typed host jobs/CI provider builds a real Web export.
    case externalBuild
    /// This engine has no Web route in this build; a guest runtime is required.
    case guestRuntime
    /// No supported route exists for the selected known engine.
    case unavailable
}

public struct GameRunRoutePlan: Equatable, Sendable {
    public let engine: GameEngineID
    public let action: GameRunRouteAction
    /// Stable internal route identity for diagnostics and host copy mapping.
    public let routeID: String
    /// The HTML entry the produced/ready artifact must expose, when known.
    public let entry: GameRelativePath?
    /// Requirements for this route. The list may include items that the host has
    /// already configured; `prepare` reports only the actually missing one.
    public let prerequisites: [GameRunPrerequisite]
    public let notes: [String]

    public init(engine: GameEngineID, action: GameRunRouteAction, routeID: String,
                entry: GameRelativePath?, prerequisites: [GameRunPrerequisite], notes: [String]) {
        self.engine = engine
        self.action = action
        self.routeID = routeID
        self.entry = entry
        self.prerequisites = prerequisites
        self.notes = notes
    }
}

public enum GameRunPreparationError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidSelection(String)
    case selectionContextMismatch
    case duplicateRequest
    case missingPrerequisite(GameRunPrerequisite)
    case guestRuntimeRequired(GameRunPrerequisite)
    case unsupportedEngine(GameEngineID)
    case engineNotDetected(GameEngineID)
    case invalidProject(String)
    case invalidArtifact(String)
    case contextChanged(GameContextChange)
    case externalBuildFailed(String)
    case cancelled
}

extension GameRunPreparationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail):
            return "Run preparation configuration is invalid: \(detail)"
        case .invalidSelection(let detail):
            return "The selected game root is invalid: \(detail)"
        case .selectionContextMismatch:
            return "The selected game root belongs to a different project/revision. Select the root again."
        case .duplicateRequest:
            return "A preparation request with this identity is already running."
        case .missingPrerequisite(let prerequisite):
            return "Cannot prepare this game yet. \(prerequisite.detail)"
        case .guestRuntimeRequired(let prerequisite):
            return "This project needs a guest runtime and cannot run as a Web game. \(prerequisite.detail)"
        case .unsupportedEngine(let engine):
            return "The \(engine.rawValue) engine has no supported run route in this build."
        case .engineNotDetected(let engine):
            return "The selected root does not contain a \(engine.rawValue) project."
        case .invalidProject(let detail):
            return "The selected game project is invalid: \(detail)"
        case .invalidArtifact(let detail):
            return "The prepared game artifact is invalid: \(detail)"
        case .contextChanged(let change):
            return "The project changed (\(change.rawValue)) while it was being prepared. Run again from the saved revision."
        case .externalBuildFailed(let detail):
            return "The host build service could not prepare this game: \(detail)"
        case .cancelled:
            return "Game preparation was cancelled."
        }
    }
}

extension GameRunPrerequisite {
    /// Concise host-facing explanation. No provider, credential or user account
    /// is named as a gate.
    public var detail: String {
        switch self {
        case .preparedResourcePack(_, let detail),
             .externalTool(_, let detail),
             .hostBuildProvider(_, let detail),
             .guestRuntime(_, let detail),
             .licensedRuntime(_, let detail),
             .unsupportedRoute(_, let detail):
            return detail
        }
    }
}

/// A bounded selected root plus optional explicit HTML entry. The selection is
/// scoped to one host-resolved project owner and saved revision; it is not an
/// access token and cannot name a root outside the materialized project.
public struct GameRunSelection: Equatable, Sendable {
    public let projectID: UUID
    public let owner: GameProjectOwner
    public let savedRevision: String
    /// "." (repository root) or a relative directory. Validated again against
    /// the real directory components before use.
    public let root: String
    /// Optional HTML entry relative to `root`. Nil auto-detects index.html.
    public let entry: GameRelativePath?
    public let title: String?

    public init(context: GameProjectContext, root: String = ".", entry: GameRelativePath? = nil,
                title: String? = nil) throws {
        try Self.validate(root: root)
        if let entry {
            guard Self.isHTMLEntry(entry) else {
                throw GameRunPreparationError.invalidSelection("entry must be an .html or .htm file")
            }
        }
        if let title {
            guard GameRunIdentifier.valid(title, maximumBytes: 128) else {
                throw GameRunPreparationError.invalidSelection("title")
            }
        }
        self.projectID = context.projectID
        self.owner = context.owner
        self.savedRevision = context.savedRevision
        self.root = root
        self.entry = entry
        self.title = title
    }

    public func validate(context: GameProjectContext) throws {
        guard projectID == context.projectID, owner == context.owner,
              savedRevision == context.savedRevision else {
            throw GameRunPreparationError.selectionContextMismatch
        }
    }

    static func validate(root: String) throws {
        guard root == "." || GameRunIdentifier.valid(root, maximumBytes: 1_024) else {
            throw GameRunPreparationError.invalidSelection("root")
        }
        guard root == "." else {
            do {
                _ = try GameRelativePath(root)
            } catch {
                throw GameRunPreparationError.invalidSelection("root must be a relative directory path")
            }
            let components = root.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty, components.count <= 32 else {
                throw GameRunPreparationError.invalidSelection("root depth")
            }
            return
        }
    }

    static func isHTMLEntry(_ path: GameRelativePath) -> Bool {
        ["html", "htm"].contains((path.value as NSString).pathExtension.lowercased())
    }
}

enum GameRunIdentifier {
    static func valid(_ value: String, maximumBytes: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func sha256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

/// A prepared runtime pack supplied by the host. Files are verified read-only
/// against their declared hashes whenever they are used; this is data, not a
/// download or execution permission.
public struct GameRunRuntimeFile: Sendable, Equatable {
    public let source: GameRelativePath
    public let destination: GameRelativePath
    public let sha256: String
    public let bytes: Int

    public init(source: GameRelativePath, destination: GameRelativePath,
                sha256: String, bytes: Int) throws {
        guard GameRunIdentifier.sha256(sha256), bytes >= 0, bytes <= 256 * 1_024 * 1_024 else {
            throw GameRunPreparationError.invalidConfiguration("runtime file record")
        }
        self.source = source
        self.destination = destination
        self.sha256 = sha256
        self.bytes = bytes
    }
}

public struct GameRunRuntimePack: Sendable {
    public let engine: GameEngineID
    public let id: String
    public let version: String
    public let license: String
    public let directory: URL
    public let files: [GameRunRuntimeFile]

    public init(engine: GameEngineID, id: String, version: String, license: String,
                directory: URL, files: [GameRunRuntimeFile]) throws {
        guard GameRunIdentifier.valid(id, maximumBytes: 256),
              GameRunIdentifier.valid(version, maximumBytes: 256),
              GameRunIdentifier.valid(license, maximumBytes: 512),
              directory.isFileURL, !files.isEmpty, files.count <= 10_000 else {
            throw GameRunPreparationError.invalidConfiguration("runtime pack fields")
        }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        var sources = Set<String>(), destinations = Set<String>()
        var total = 0
        for file in files {
            guard sources.insert(file.source.value.lowercased()).inserted,
                  destinations.insert(file.destination.value.lowercased()).inserted,
                  total <= 1_024 * 1_024 * 1_024 - file.bytes else {
                throw GameRunPreparationError.invalidConfiguration("runtime pack file list")
            }
            total += file.bytes
            let bytes = try GameRunFileIO.read(root: root, path: file.source,
                maximumBytes: max(file.bytes + 1, 1))
            guard bytes.count == file.bytes,
                  GameDigest.sha256(bytes) == file.sha256 else {
                throw GameRunPreparationError.invalidConfiguration("runtime pack bytes \(file.source.value)")
            }
        }
        self.engine = engine
        self.id = id
        self.version = version
        self.license = license
        self.directory = root
        self.files = files
    }

    public func read(_ source: GameRelativePath) throws -> Data {
        guard let file = files.first(where: { $0.source == source }) else {
            throw GameRunPreparationError.invalidConfiguration("runtime pack file \(source.value)")
        }
        let bytes = try GameRunFileIO.read(root: directory, path: source,
            maximumBytes: max(file.bytes + 1, 1))
        guard bytes.count == file.bytes, GameDigest.sha256(bytes) == file.sha256 else {
            throw GameRunPreparationError.invalidConfiguration("runtime pack bytes \(source.value)")
        }
        return bytes
    }
}

public protocol GameRunRuntimePackProviding: Sendable {
    /// Nil means the pack is not prepared yet. Throwing means a present pack is
    /// unreadable or failed hash verification; that error must stay visible.
    func runtimePack(for engine: GameEngineID) async throws -> GameRunRuntimePack?
}

public enum GameRunExternalBuildKind: String, Codable, Equatable, Sendable {
    case godotWeb
    case unityWebGL
    case cocosWeb
    case webBundle
    case gdevelopWeb
    case rpgMakerMZWeb
    case rpgMakerMVDeployment
}

/// Immutable request to the host's existing jobs/CI service. The provider owns
/// environment selection, execution, cancellation and result validation; this
/// package defines no dispatch permission and no command executor.
public struct GameRunExternalBuildRequest: Sendable {
    public let engine: GameEngineID
    public let kind: GameRunExternalBuildKind
    public let context: GameProjectContext
    /// The prepared selected-subtree copy that local engine commands may read.
    /// CI never publishes this tree as the original project.
    public let sourceRoot: URL
    public let outputDirectory: URL
    public let expectedEntry: GameRelativePath
    public let requirement: GameRunPrerequisite
    /// Immutable original project/root/inventory provenance. Nil is only the
    /// legacy project-root request used by direct component fixtures; a nested
    /// request must carry the original selection or it fails closed.
    public let selection: GameRunSourceSelection?

    public init(engine: GameEngineID, kind: GameRunExternalBuildKind,
                context: GameProjectContext, sourceRoot: URL, outputDirectory: URL,
                expectedEntry: GameRelativePath, requirement: GameRunPrerequisite,
                selection: GameRunSourceSelection? = nil) throws {
        guard sourceRoot.isFileURL, outputDirectory.isFileURL,
              GameRunSelection.isHTMLEntry(expectedEntry) else {
            throw GameRunPreparationError.invalidConfiguration("external build request")
        }
        if let selection {
            guard selection.context == context, selection.engine == engine else {
                throw GameRunPreparationError.invalidSelection(
                    "the external build selection does not match its context or engine")
            }
        }
        self.engine = engine
        self.kind = kind
        self.context = context
        self.sourceRoot = sourceRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.expectedEntry = expectedEntry
        self.requirement = requirement
        self.selection = selection
    }

    /// The original whole-project root, never the prepared subtree.
    public var projectRootURL: URL { selection?.context.rootURL ?? context.rootURL }
    public var gameRoot: GameRelativePath? { selection?.gameRoot }
    public var wholeProjectDigest: String? { selection?.wholeProjectDigest }
    public var selectedSourceDigest: String? { selection?.selectedSourceDigest }
    public var preparedSourceDigest: String? { selection?.prepared.digest }
}

/// Honest provenance returned by the host build service. `nil` is a legacy
/// provider that did not observe the original selection; it cannot satisfy a
/// nested request.
public struct GameRunExternalBuildProvenance: Equatable, Sendable {
    public let schemaVersion: Int
    public let gameRoot: String
    public let selectedSourceDigest: String?
    public let wholeProjectDigest: String?
    public let preparedSourceDigest: String?
    public let preparedTransform: String?
    public let ciJobID: String?
    public let sourceTransport: String?

    public init(schemaVersion: Int, gameRoot: String,
                selectedSourceDigest: String?, wholeProjectDigest: String?,
                preparedSourceDigest: String?, preparedTransform: String?,
                ciJobID: String?, sourceTransport: String?) throws {
        guard schemaVersion == 1 else {
            throw GameRunPreparationError.invalidConfiguration("build provenance schema")
        }
        let selectedIsValid = selectedSourceDigest.map(GameRunIdentifier.sha256) ?? false
        let wholeIsValid = wholeProjectDigest.map(GameRunIdentifier.sha256) ?? false
        let preparedIsValid = preparedSourceDigest.map(GameRunIdentifier.sha256) ?? false
        guard selectedIsValid == !gameRoot.isEmpty,
              wholeIsValid, preparedIsValid,
              gameRoot.isEmpty || GameRunIdentifier.valid(gameRoot, maximumBytes: 1_024),
              let preparedTransform, GameRunIdentifier.valid(preparedTransform, maximumBytes: 64),
              let sourceTransport, GameRunIdentifier.valid(sourceTransport, maximumBytes: 64),
              ciJobID.map({ GameRunIdentifier.valid($0, maximumBytes: 256) }) ?? true else {
            throw GameRunPreparationError.invalidConfiguration("build provenance values")
        }
        self.schemaVersion = schemaVersion
        self.gameRoot = gameRoot
        self.selectedSourceDigest = selectedSourceDigest
        self.wholeProjectDigest = wholeProjectDigest
        self.preparedSourceDigest = preparedSourceDigest
        self.preparedTransform = preparedTransform
        self.ciJobID = ciJobID
        self.sourceTransport = sourceTransport
    }
}

public struct GameRunExternalBuildOutput: Sendable {
    public let directory: URL
    public let entry: GameRelativePath
    /// Host-provided relative evidence strings for diagnostics; never treated as
    /// proof of engine readiness or as a permission.
    public let evidence: [String]
    /// Nil is an old provider/fixture that did not report original selection.
    public let provenance: GameRunExternalBuildProvenance?

    public init(directory: URL, entry: GameRelativePath, evidence: [String] = [],
                provenance: GameRunExternalBuildProvenance? = nil) throws {
        guard directory.isFileURL, GameRunSelection.isHTMLEntry(entry),
              evidence.count <= 32,
              evidence.allSatisfy({ GameRunIdentifier.valid($0, maximumBytes: 512) }) else {
            throw GameRunPreparationError.invalidConfiguration("external build output")
        }
        self.directory = directory.standardizedFileURL
        self.entry = entry
        self.evidence = evidence
        self.provenance = provenance
    }
}

public protocol GameRunExternalBuildProviding: Sendable {
    func build(_ request: GameRunExternalBuildRequest) async throws -> GameRunExternalBuildOutput
}

public struct GameRunPreparationConfiguration: Sendable {
    public let artifactDirectory: URL
    public let narrativeResources: URL?
    public let portableResources: [GameEngineID: GamePortablePreparedResources]
    /// Host-owned portable build port: `FloeGamePortableKit` already defines the
    /// typed job/CI seam for LÖVE and Ren'Py. This package never executes a
    /// process, Node, Python or a shell command itself.
    public let portableBuildPort: (any GamePortableBuildPort)?
    public let externalBuildProvider: (any GameRunExternalBuildProviding)?
    public let runtimePacks: (any GameRunRuntimePackProviding)?
    /// Optional authoritative context fence. The controller performs the same
    /// check; supplying it here lets a long external build reject a stale
    /// revision before sealing any artifact.
    public let contexts: (any GameRunContextHost)?
    /// The saved-revision whole-project inventory. Production supplies this
    /// from the same repository/owner as the project; when absent, a bounded
    /// read-only scan of the original project root is used for qualification.
    public let projectInventory: GameRunProjectInventoryProvider?
    public let renpySDK: URL?
    public let title: String
    public let limits: GameRunPreparationLimits

    public init(artifactDirectory: URL,
                narrativeResources: URL? = nil,
                portableResources: [GameEngineID: GamePortablePreparedResources] = [:],
                portableBuildPort: (any GamePortableBuildPort)? = nil,
                externalBuildProvider: (any GameRunExternalBuildProviding)? = nil,
                runtimePacks: (any GameRunRuntimePackProviding)? = nil,
                contexts: (any GameRunContextHost)? = nil,
                projectInventory: GameRunProjectInventoryProvider? = nil,
                renpySDK: URL? = nil,
                title: String = "Floe game",
                limits: GameRunPreparationLimits = .default) throws {
        guard artifactDirectory.isFileURL, !artifactDirectory.lastPathComponent.isEmpty,
              artifactDirectory.path != "/" else {
            throw GameRunPreparationError.invalidConfiguration("artifact directory")
        }
        for url in [narrativeResources, renpySDK].compactMap({ $0 }) {
            guard url.isFileURL else {
                throw GameRunPreparationError.invalidConfiguration("resource URL")
            }
        }
        for (engine, resources) in portableResources where resources.engine != engine {
            throw GameRunPreparationError.invalidConfiguration("portable resource engine mismatch")
        }
        guard GameRunIdentifier.valid(title, maximumBytes: 128) else {
            throw GameRunPreparationError.invalidConfiguration("title")
        }
        self.artifactDirectory = artifactDirectory.standardizedFileURL
        self.narrativeResources = narrativeResources?.standardizedFileURL.resolvingSymlinksInPath()
        self.portableResources = portableResources
        self.portableBuildPort = portableBuildPort
        self.externalBuildProvider = externalBuildProvider
        self.runtimePacks = runtimePacks
        self.contexts = contexts
        self.projectInventory = projectInventory
        self.renpySDK = renpySDK?.standardizedFileURL.resolvingSymlinksInPath()
        self.title = title
        self.limits = limits
    }
}
