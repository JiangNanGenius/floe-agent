// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Failures while capturing the original project selection for one run-time
/// build. These values carry no environment or credential permission.
public enum GameRunSourceSelectionError: Error, Equatable, Sendable {
    case invalidInventory(String)
    case revisionMismatch(expected: String, actual: String)
    case staleContext(GameContextChange)
    case invalidRoot(String)
    case rootMissing(String)
    case rootNotDirectory(String)
    case symbolicLink(String)
    case outsideProject(String)
    case emptySelection(String)
    case engineNotRecognized(GameEngineID)
    case preparedSourceMismatch(String)
    case generatedSourceNotReproducible(String)
}

extension GameRunSourceSelectionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidInventory(let detail):
            return "The saved project inventory is invalid: \(detail)"
        case .revisionMismatch(let expected, let actual):
            return "The project inventory belongs to revision \(actual), not \(expected)."
        case .staleContext(let change):
            return "The game project changed (\(change.rawValue)) while the build was starting."
        case .invalidRoot(let detail):
            return "The selected game root is invalid: \(detail)"
        case .rootMissing(let root):
            return "The selected game root no longer exists: \(root)"
        case .rootNotDirectory(let root):
            return "The selected game root is not a directory: \(root)"
        case .symbolicLink(let root):
            return "The selected game root contains a symbolic link: \(root)"
        case .outsideProject(let root):
            return "The selected game root escapes the project workspace: \(root)"
        case .emptySelection(let root):
            return "The selected game root has no buildable files: \(root)"
        case .engineNotRecognized(let engine):
            return "The engine \(engine.rawValue) is not recognized at the selected game root."
        case .preparedSourceMismatch(let detail):
            return "The prepared source copy does not match the selected source: \(detail)"
        case .generatedSourceNotReproducible(let detail):
            return "The local generated source cannot be reproduced by the reviewed CI workflow: \(detail)"
        }
    }
}

/// Canonical digest shared by the run selection, the build transport and the
/// reviewed workflows: `relative:sha256:bytes:executable(1|0)`, sorted,
/// newline-joined, SHA-256.
public enum GameRunSourceDigest {
    public static let excludedDirectoryNames: Set<String> = [".git", ".floe", "out"]

    public static func digest(files: [GameProjectFile]) -> String {
        let rows = files.map {
            "\($0.path.value):\($0.sha256):\($0.bytes):\($0.executable ? "1" : "0")"
        }.sorted()
        return GameDigest.sha256(Data(rows.joined(separator: "\n").utf8))
    }

    /// Hashes a whole prepared tree without following links. Used to prove that
    /// the private prepared copy is byte-identical to the selected source.
    public static func manifest(rootURL: URL,
                                limits: GameRunPreparationLimits = .default) throws
        -> (files: [GameProjectFile], directories: [GameRelativePath], digest: String) {
        let reader: GameProjectReader
        do {
            reader = try GameProjectReader(rootURL: rootURL,
                                           maximumFileBytes: limits.maximumFileBytes)
        } catch {
            throw GameRunSourceSelectionError.invalidRoot(String(describing: error))
        }
        let entries: [(path: GameRelativePath, directory: Bool)]
        do {
            entries = try reader.tree(
                maximumEntries: limits.maximumEntries,
                maximumDepth: limits.maximumDepth,
                excludingNames: GameProjectReader.versionControlNames)
        } catch {
            throw GameRunSourceSelectionError.invalidRoot(String(describing: error))
        }
        var files: [GameProjectFile] = []
        var directories: [GameRelativePath] = []
        var total = 0
        for entry in entries {
            try Task.checkCancellation()
            if entry.directory {
                directories.append(entry.path)
                continue
            }
            let bytes: Data
            do {
                guard let value = try reader.read(entry.path) else {
                    throw GameRunSourceSelectionError.rootMissing(entry.path.value)
                }
                bytes = value
            } catch let error as GameRunSourceSelectionError {
                throw error
            } catch {
                throw GameRunSourceSelectionError.invalidRoot(entry.path.value)
            }
            guard total <= limits.maximumProjectBytes - bytes.count else {
                throw GameRunSourceSelectionError.invalidInventory("whole project exceeds its byte bound")
            }
            total += bytes.count
            let executable: Bool
            do { executable = try reader.isExecutable(entry.path) }
            catch { throw GameRunSourceSelectionError.invalidRoot(entry.path.value) }
            files.append(.init(path: entry.path, sha256: GameDigest.sha256(bytes),
                               bytes: bytes.count, executable: executable))
        }
        let digest = digest(files: files)
        return (files.sorted { $0.path.value < $1.path.value },
                directories.sorted { $0.value < $1.value }, digest)
    }
}

/// Resolves the saved whole-project inventory from the host repository. The
/// provider must throw when the owner/project/revision cannot be resolved; it
/// never substitutes a sibling root or a newer working tree.
public typealias GameRunProjectInventoryProvider =
    @Sendable (GameProjectContext) async throws -> GameRunProjectInventory

/// The saved whole-project inventory. This is the authority for the original
/// workspace digest; it is never narrowed to the selected engine subtree.
public struct GameRunProjectInventory: Equatable, Sendable {
    public let revision: String
    public let directories: [GameRelativePath]
    public let files: [GameProjectFile]
    public let workspaceRevision: String?

    public init(revision: String, directories: [GameRelativePath],
                files: [GameProjectFile], workspaceRevision: String? = nil) throws {
        guard GameRunIdentifier.valid(revision, maximumBytes: 256) else {
            throw GameRunSourceSelectionError.invalidInventory("revision")
        }
        var seen = Set<String>()
        for file in files {
            guard seen.insert(file.path.value).inserted else {
                throw GameRunSourceSelectionError.invalidInventory(
                    "duplicate file \(file.path.value)")
            }
            guard file.bytes >= 0,
                  file.sha256.utf8.count == 64,
                  file.sha256.unicodeScalars.allSatisfy({ scalar in
                      (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
                  }) else {
                throw GameRunSourceSelectionError.invalidInventory(
                    "unsafe file record \(file.path.value)")
            }
            let components = file.path.value.split(separator: "/").map(String.init)
            if components.contains(where: { GameRunSourceDigest.excludedDirectoryNames.contains($0) }) {
                throw GameRunSourceSelectionError.invalidInventory(
                    "the project contains generated '.git', '.floe' or 'out' content at \(file.path.value); remove or relocate it before a CI build")
            }
        }
        self.revision = revision
        self.directories = directories.sorted { $0.value < $1.value }
        self.files = files.sorted { $0.path.value < $1.path.value }
        self.workspaceRevision = workspaceRevision
    }

    public var wholeProjectDigest: String {
        GameRunSourceDigest.digest(files: files)
    }

    public func selectedFiles(gameRoot: GameRelativePath?) -> [GameProjectFile] {
        guard let gameRoot else { return files }
        let prefix = gameRoot.value + "/"
        return files.filter { $0.path.value.hasPrefix(prefix) }
    }

    /// Nil for a project-root run; the whole-project digest already binds it.
    public func selectedSourceDigest(gameRoot: GameRelativePath?) throws -> String? {
        guard let gameRoot else { return nil }
        let selected = selectedFiles(gameRoot: gameRoot)
        guard !selected.isEmpty else {
            throw GameRunSourceSelectionError.emptySelection(gameRoot.value)
        }
        let rows = selected.map { file -> String in
            let relative = String(file.path.value.dropFirst(gameRoot.value.count + 1))
            return "\(relative):\(file.sha256):\(file.bytes):\(file.executable ? "1" : "0")"
        }.sorted()
        return GameDigest.sha256(Data(rows.joined(separator: "\n").utf8))
    }

    /// Bounded fallback for qualification callers that do not have a saved
    /// repository port. Production supplies the repository inventory so the
    /// saved revision is authoritative.
    public static func scan(context: GameProjectContext,
                            limits: GameRunPreparationLimits = .default) throws
        -> GameRunProjectInventory {
        let manifest = try GameRunSourceDigest.manifest(rootURL: context.rootURL, limits: limits)
        return try .init(revision: context.savedRevision, directories: manifest.directories,
                         files: manifest.files)
    }
}

/// Whether the prepared bytes are provably the selected bytes or a documented
/// local transform. A generated copy can run locally but must not be presented
/// to CI as the original source.
public enum GameRunPreparedSourceTransform: String, Codable, Equatable, Sendable {
    case byteIdenticalCopy
    case generated
}

public struct GameRunPreparedSource: Equatable, Sendable {
    public let digest: String
    public let transform: GameRunPreparedSourceTransform
    public let transformID: String?
    /// Free-form but required relation for a generated copy. A byte-identical
    /// copy uses `equals-selected-source`.
    public let relation: String

    public init(digest: String, transform: GameRunPreparedSourceTransform,
                transformID: String?, relation: String) throws {
        guard digest.utf8.count == 64,
              digest.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
              }),
              GameRunIdentifier.valid(relation, maximumBytes: 256) else {
            throw GameRunSourceSelectionError.preparedSourceMismatch("digest or relation")
        }
        switch transform {
        case .byteIdenticalCopy:
            guard transformID == nil, relation == "equals-selected-source" else {
                throw GameRunSourceSelectionError.preparedSourceMismatch(
                    "a byte-identical copy cannot claim a transform")
            }
        case .generated:
            guard let transformID, GameRunIdentifier.valid(transformID, maximumBytes: 256),
                  relation != "equals-selected-source" else {
                throw GameRunSourceSelectionError.preparedSourceMismatch(
                    "a generated copy requires a transform id and a distinct relation")
            }
        }
        self.digest = digest
        self.transform = transform
        self.transformID = transformID
        self.relation = relation
    }

    public func validate(selectedSourceDigest: String?, wholeProjectDigest: String) throws {
        switch transform {
        case .byteIdenticalCopy:
            let expected = selectedSourceDigest ?? wholeProjectDigest
            guard digest == expected else {
                throw GameRunSourceSelectionError.preparedSourceMismatch(
                    "prepared \(digest) != selected \(expected)")
            }
        case .generated:
            guard let transformID, !transformID.isEmpty, relation != "equals-selected-source" else {
                throw GameRunSourceSelectionError.generatedSourceNotReproducible(
                    "documented transform identity is missing")
            }
        }
    }
}

/// Immutable run-time source identity. `context` remains the original owner,
/// project, environment, workspace root and saved revision; `gameRoot` names
/// the selected subtree and `inventory` retains the whole project.
public struct GameRunSourceSelection: Equatable, Sendable {
    public let context: GameProjectContext
    public let engine: GameEngineID
    public let gameRoot: GameRelativePath?
    public let selectedRootURL: URL
    public let selectedRootDeviceID: UInt64?
    public let selectedRootFileID: UInt64?
    public let inventory: GameRunProjectInventory
    public let wholeProjectDigest: String
    public let selectedSourceDigest: String?
    public let prepared: GameRunPreparedSource

    public init(context: GameProjectContext, engine: GameEngineID,
                gameRoot: GameRelativePath?, inventory: GameRunProjectInventory,
                prepared: GameRunPreparedSource) throws {
        guard inventory.revision == context.savedRevision else {
            throw GameRunSourceSelectionError.revisionMismatch(
                expected: context.savedRevision, actual: inventory.revision)
        }
        let selected = try GameRunSourceRoot.resolve(rootURL: context.rootURL,
                                                    gameRoot: gameRoot)
        let identity = try GameRunSourceRoot.identity(selected)
        let inspection: GameProjectInspection
        do { inspection = try GameProjectInspector().inspect(rootURL: selected) }
        catch {
            throw GameRunSourceSelectionError.invalidRoot(String(describing: error))
        }
        guard inspection.candidates.contains(where: { $0.engine == engine }) else {
            throw GameRunSourceSelectionError.engineNotRecognized(engine)
        }
        let whole = inventory.wholeProjectDigest
        let selectedDigest = try inventory.selectedSourceDigest(gameRoot: gameRoot)
        try prepared.validate(selectedSourceDigest: selectedDigest,
                              wholeProjectDigest: whole)
        self.context = context
        self.engine = engine
        self.gameRoot = gameRoot
        self.selectedRootURL = selected
        self.selectedRootDeviceID = identity.device
        self.selectedRootFileID = identity.file
        self.inventory = inventory
        self.wholeProjectDigest = whole
        self.selectedSourceDigest = selectedDigest
        self.prepared = prepared
    }

    /// Revalidates the original context and the live selected root around a
    /// suspension. A replaced path, a symlink swap, a changed owner/revision or
    /// a different engine fails before the build can publish or seal.
    public func validate(liveContext: GameProjectContext) throws {
        do {
            try context.validate(current: liveContext)
        } catch GameProjectError.contextChanged(let change) {
            throw GameRunSourceSelectionError.staleContext(change)
        } catch {
            throw GameRunSourceSelectionError.invalidRoot(String(describing: error))
        }
        guard inventory.revision == liveContext.savedRevision else {
            throw GameRunSourceSelectionError.revisionMismatch(
                expected: liveContext.savedRevision, actual: inventory.revision)
        }
        let selected = try GameRunSourceRoot.resolve(rootURL: liveContext.rootURL,
                                                    gameRoot: gameRoot)
        let identity = try GameRunSourceRoot.identity(selected)
        if let selectedRootDeviceID, let selectedRootFileID {
            guard identity.device == selectedRootDeviceID,
                  identity.file == selectedRootFileID else {
                throw GameRunSourceSelectionError.invalidRoot(
                    "the selected game root was replaced at the same path")
            }
        }
        let inspection: GameProjectInspection
        do { inspection = try GameProjectInspector().inspect(rootURL: selected) }
        catch {
            throw GameRunSourceSelectionError.invalidRoot(String(describing: error))
        }
        guard inspection.candidates.contains(where: { $0.engine == engine }) else {
            throw GameRunSourceSelectionError.engineNotRecognized(engine)
        }
        try prepared.validate(selectedSourceDigest: selectedSourceDigest,
                              wholeProjectDigest: wholeProjectDigest)
    }

    /// Validates a prepared copy's manifest digest against the captured
    /// relation. A byte-identical copy must match exactly; a generated copy is
    /// retained with its own documented identity.
    public func validatePreparedDigest(_ digest: String) throws {
        switch prepared.transform {
        case .byteIdenticalCopy:
            try prepared.validate(selectedSourceDigest: selectedSourceDigest,
                                  wholeProjectDigest: wholeProjectDigest)
            guard digest == prepared.digest else {
                throw GameRunSourceSelectionError.preparedSourceMismatch(
                    "prepared copy digest \(digest) != \(prepared.digest)")
            }
        case .generated:
            guard digest == prepared.digest else {
                throw GameRunSourceSelectionError.preparedSourceMismatch(
                    "generated prepared copy digest \(digest) != \(prepared.digest)")
            }
        }
    }

    /// A generated prepared copy is not the original source; CI must not claim
    /// the selected digest while building other bytes.
    public func requireCIOriginalBytes() throws {
        guard prepared.transform == .byteIdenticalCopy else {
            throw GameRunSourceSelectionError.generatedSourceNotReproducible(
                "the prepared source is generated locally (\(prepared.transformID ?? "unknown")); the reviewed workflow can only build the saved original bytes")
        }
    }
}

/// Descriptor-confined root resolution shared by the run selection.
enum GameRunSourceRoot {
    struct Identity: Equatable, Sendable {
        let device: UInt64
        let file: UInt64
    }

    static func projectRoot(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw GameRunSourceSelectionError.invalidRoot("URL") }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        switch kind(at: canonical) {
        case .directory: break
        case .symbolicLink: throw GameRunSourceSelectionError.symbolicLink(".")
        case .regularFile, .other: throw GameRunSourceSelectionError.rootNotDirectory(".")
        case nil: throw GameRunSourceSelectionError.rootMissing(".")
        }
        guard canonical.resolvingSymlinksInPath().path == canonical.path else {
            throw GameRunSourceSelectionError.symbolicLink(".")
        }
        return canonical
    }

    static func resolve(rootURL: URL, gameRoot: GameRelativePath?) throws -> URL {
        let root = try projectRoot(rootURL)
        guard let gameRoot else { return root }
        var current = root
        for component in gameRoot.value.split(separator: "/", omittingEmptySubsequences: false) {
            let name = String(component)
            guard !name.isEmpty, name != ".", name != "..",
                  !name.contains("\\"), !name.contains(":") else {
                throw GameRunSourceSelectionError.invalidRoot(gameRoot.value)
            }
            let next = current.appendingPathComponent(name)
            switch kind(at: next) {
            case .directory: current = next
            case .symbolicLink: throw GameRunSourceSelectionError.symbolicLink(gameRoot.value)
            case .regularFile, .other:
                throw GameRunSourceSelectionError.rootNotDirectory(gameRoot.value)
            case nil: throw GameRunSourceSelectionError.rootMissing(gameRoot.value)
            }
        }
        let selected = current.standardizedFileURL
        let expected = root.appendingPathComponent(gameRoot.value).standardizedFileURL
        guard selected.path == expected.path else {
            throw GameRunSourceSelectionError.outsideProject(gameRoot.value)
        }
        guard selected.resolvingSymlinksInPath().path == selected.path else {
            throw GameRunSourceSelectionError.symbolicLink(gameRoot.value)
        }
        return selected
    }

    static func identity(_ url: URL) throws -> Identity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw GameRunSourceSelectionError.rootMissing(url.lastPathComponent)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw GameRunSourceSelectionError.rootNotDirectory(url.lastPathComponent)
        }
        return .init(device: UInt64(info.st_dev), file: UInt64(info.st_ino))
    }

    private enum Kind { case directory, regularFile, symbolicLink, other }

    private static func kind(at url: URL) -> Kind? {
        guard url.isFileURL else { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .regularFile
        case S_IFLNK: return .symbolicLink
        default: return .other
        }
    }
}
