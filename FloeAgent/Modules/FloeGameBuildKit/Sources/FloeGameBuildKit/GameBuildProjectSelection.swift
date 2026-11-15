// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// A selected nested game root whose authority remains the original captured
/// project context. This value never changes `GameProjectContext.rootURL`: the
/// whole project stays the workspace, owner, environment and revision scope,
/// while `gameRoot` names the exact subtree the engine build may act on.
///
/// The initializer validates the captured context and the selected root before
/// any build side effect. `validate(against:)` is the stale-context fence the
/// coordinator runs again immediately before staging and dispatch.
public enum GameBuildSelectionError: Error, Equatable, Sendable {
    case invalidContext
    case rootMissing(String)
    case rootNotDirectory(String)
    case symbolicLink(String)
    case outsideProject(String)
    case emptySelection(String)
    case engineNotRecognized(GameEngineID)
    case wrongEngine(expected: GameEngineID, actual: GameEngineID)
    case inspection(String)
    case staleContext(GameContextChange)
    case selectionChanged(String)
}

extension GameBuildSelectionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidContext:
            return "The captured game project context is invalid."
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
        case .wrongEngine(let expected, let actual):
            return "The build requested \(expected.rawValue) but the selected game root is \(actual.rawValue)."
        case .inspection(let detail):
            return "The selected game root could not be inspected: \(detail)"
        case .staleContext(let change):
            return "The captured game project changed (\(change.rawValue)); refresh the project before building."
        case .selectionChanged(let detail):
            return "The selected game root changed after it was captured: \(detail)"
        }
    }
}

public struct GameBuildProjectSelection: Equatable, Sendable {
    public let projectID: UUID
    public let owner: GameProjectOwner
    public let environmentID: String?
    /// The original whole-project workspace root. Never replaced with the game
    /// subtree: ownership, export and revision checks continue to use it.
    public let projectRootURL: URL
    public let revision: String
    public let engine: GameEngineID
    public let gameRoot: GameRelativePath?
    public let selectedRootURL: URL
    public let selectedRootDeviceID: UInt64?
    public let selectedRootFileID: UInt64?

    /// - Parameters:
    ///   - context: the host-captured original project context (not a
    ///     fabricated subtree context).
    ///   - engine: the engine chosen for this root.
    ///   - gameRoot: a project-relative nested root, or nil for the project
    ///     root. Nil means "project root", never "guess a nested root".
    public init(context: GameProjectContext, engine: GameEngineID,
                gameRoot: GameRelativePath?) throws {
        let root = try Self.requireProjectRoot(context.rootURL)
        let selected: URL
        if let gameRoot {
            guard !gameRoot.value.isEmpty else { throw GameBuildSelectionError.invalidContext }
            selected = try Self.resolve(root: root, gameRoot: gameRoot)
        } else {
            selected = root
        }
        let inspection: GameProjectInspection
        do {
            inspection = try GameProjectInspector().inspect(rootURL: selected)
        } catch {
            throw GameBuildSelectionError.inspection(String(describing: error))
        }
        guard inspection.candidates.contains(where: { $0.engine == engine }) else {
            throw GameBuildSelectionError.engineNotRecognized(engine)
        }
        let identity = GameBuildFileSupport.identity(at: selected)
        self.projectID = context.projectID
        self.owner = context.owner
        self.environmentID = context.environmentID
        self.projectRootURL = root
        self.revision = context.savedRevision
        self.engine = engine
        self.gameRoot = gameRoot
        self.selectedRootURL = selected
        self.selectedRootDeviceID = identity?.device
        self.selectedRootFileID = identity?.file
    }

    /// Revalidates identity, revision and the live path before any staging or
    /// dispatch. A replaced root (same path, new identity) and a symlink swap
    /// are both rejected.
    public func validate(against context: GameProjectContext) throws {
        let change: GameContextChange?
        if projectID != context.projectID { change = .project }
        else if owner != context.owner { change = .owner }
        else if projectRootURL != Self.canonical(context.rootURL) { change = .root }
        else if environmentID != context.environmentID { change = .environment }
        else if revision != context.savedRevision { change = .revision }
        else { change = nil }
        if let change { throw GameBuildSelectionError.staleContext(change) }
        let root = try Self.requireProjectRoot(context.rootURL)
        let current: URL
        if let gameRoot {
            current = try Self.resolve(root: root, gameRoot: gameRoot)
        } else {
            current = root
        }
        if let selectedRootDeviceID, let selectedRootFileID {
            guard let identity = GameBuildFileSupport.identity(at: current),
                  identity.device == selectedRootDeviceID,
                  identity.file == selectedRootFileID else {
                throw GameBuildSelectionError.selectionChanged(gameRoot?.value ?? ".")
            }
        }
        let inspection: GameProjectInspection
        do {
            inspection = try GameProjectInspector().inspect(rootURL: current)
        } catch {
            throw GameBuildSelectionError.inspection(String(describing: error))
        }
        guard inspection.candidates.contains(where: { $0.engine == engine }) else {
            throw GameBuildSelectionError.engineNotRecognized(engine)
        }
    }

    public func validate(engine requested: GameEngineID) throws {
        guard engine == requested else {
            throw GameBuildSelectionError.wrongEngine(expected: requested, actual: engine)
        }
    }

    /// Resolves the selected root inside a staged/exported whole-project tree.
    /// This is what makes the CI checkout and host exporter act on the same
    /// subtree that the coordinator bound in the record. The path is
    /// root-confined and every component is refused if it is a symlink.
    public func selectedRoot(in projectRoot: URL) throws -> URL {
        let root = try Self.requireProjectRoot(projectRoot)
        guard let gameRoot else { return root }
        return try Self.resolve(root: root, gameRoot: gameRoot)
    }

    /// Canonical digest of the selected subtree, matching the reviewed CI
    /// templates: `relative:sha256:bytes:executable`, sorted, joined with a
    /// newline, SHA-256. The project-root selection has no separate subtree
    /// digest; the whole-project digest already binds it.
    public func selectedSourceDigest(from files: [GameProjectFile]) throws -> String? {
        try GameBuildSelectionSupport.digest(of: files, under: gameRoot)
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func requireProjectRoot(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw GameBuildSelectionError.invalidContext }
        let root = canonical(url)
        switch GameBuildFileSupport.kind(at: root) {
        case .directory:
            break
        case .symbolicLink:
            throw GameBuildSelectionError.symbolicLink(".")
        case .regularFile, .other:
            throw GameBuildSelectionError.rootNotDirectory(".")
        case nil:
            throw GameBuildSelectionError.rootMissing(".")
        }
        guard root.resolvingSymlinksInPath().path == root.path else {
            throw GameBuildSelectionError.symbolicLink(".")
        }
        return root
    }

    private static func resolve(root: URL, gameRoot: GameRelativePath) throws -> URL {
        var current = root
        for component in gameRoot.value.split(separator: "/", omittingEmptySubsequences: false) {
            let name = String(component)
            guard !name.isEmpty, name != ".", name != "..", !name.contains("\\"),
                  !name.contains(":") else {
                throw GameBuildSelectionError.invalidContext
            }
            let next = current.appendingPathComponent(name)
            switch GameBuildFileSupport.kind(at: next) {
            case .directory:
                current = next
            case .symbolicLink:
                throw GameBuildSelectionError.symbolicLink(gameRoot.value)
            case .regularFile, .other:
                throw GameBuildSelectionError.rootNotDirectory(gameRoot.value)
            case nil:
                throw GameBuildSelectionError.rootMissing(gameRoot.value)
            }
        }
        let selected = current.standardizedFileURL
        let expected = root.appendingPathComponent(gameRoot.value).standardizedFileURL
        guard selected.path == expected.path else {
            throw GameBuildSelectionError.outsideProject(gameRoot.value)
        }
        guard selected.resolvingSymlinksInPath().path == selected.path else {
            throw GameBuildSelectionError.symbolicLink(gameRoot.value)
        }
        return selected
    }
}

/// The single canonical definition of a selected-subtree digest shared by the
/// transport, records and reviewed templates. Excluded directory names match
/// the CI template's `digest_tree` at every depth.
enum GameBuildSelectionSupport {
    static let excludedDirectoryNames: Set<String> = [".git", ".floe", "out"]

    static func canonicalRoot(_ raw: String?) throws -> GameRelativePath? {
        guard let raw else { return nil }
        guard !raw.isEmpty else { return nil }
        guard let path = try? GameRelativePath(raw) else {
            throw GameBuildSelectionError.invalidContext
        }
        return path
    }

    static func selectedFiles(_ files: [GameProjectFile],
                              under root: GameRelativePath) -> [GameProjectFile] {
        let prefix = root.value + "/"
        return files.filter { file in
            guard file.path.value.hasPrefix(prefix) else { return false }
            let relative = file.path.value.dropFirst(prefix.count)
            return !relative.split(separator: "/").contains {
                excludedDirectoryNames.contains(String($0))
            }
        }
    }

    static func digest(of files: [GameProjectFile], under root: GameRelativePath?) throws -> String? {
        guard let root else { return nil }
        let selected = selectedFiles(files, under: root)
        guard !selected.isEmpty else {
            throw GameBuildSelectionError.emptySelection(root.value)
        }
        let rows = selected.map { file -> String in
            let relative = String(file.path.value.dropFirst(root.value.count + 1))
            return "\(relative):\(file.sha256):\(file.bytes):\(file.executable ? "1" : "0")"
        }.sorted()
        return GameDigest.sha256(Data(rows.joined(separator: "\n").utf8))
    }

    /// A game root and its subtree digest are either both absent (project-root
    /// build) or both present. A lone value is never guessed.
    static func validatePair(gameRoot: String?, selectedSourceDigest: String?) -> Bool {
        let root: GameRelativePath?
        do {
            root = try canonicalRoot(gameRoot)
        } catch {
            return false
        }
        switch (root, selectedSourceDigest) {
        case (nil, nil):
            return gameRoot == nil || gameRoot?.isEmpty == true
        case (let root?, let digest?):
            return !root.value.isEmpty
                && digest.utf8.count == 64
                && digest.unicodeScalars.allSatisfy { scalar in
                    (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
                }
        default:
            return false
        }
    }
}
