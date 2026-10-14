// FloeTools — Canonical mutation leases for concurrent sibling execution.
//
// When several delegated children run in parallel inside one root task, their
// mutations must not interleave unpredictably. Every effectful child call
// acquires an exclusive lease over its canonical target keys before it runs:
//
// - a file/document write with a resolvable target takes the narrow
//   `file:<canonical path>` / `document:<id>` key, so siblings writing
//   DIFFERENT files may proceed concurrently;
// - a Shell/Python/unknown write is treated as potentially workspace-wide and
//   takes the wildcard `workspace:<canonical root>` key, which conflicts with
//   every other key in that workspace;
// - a target that cannot be resolved conservatively falls back to the
//   wildcard. Unknown tools are never assumed narrow.
//
// Leases are runtime state, not model data: the central child dispatcher
// acquires and releases them around real execution. The coordinator performs
// a bounded wait and fails the call with an explicit timeout instead of
// hanging forever behind a stuck sibling.

import Foundation
import FloeCore
import FloeModels

/// What a mutation key protects.
public enum MutationKeyFamily: String, Sendable, Hashable, Codable {
    /// Narrow, canonical file target.
    case file
    /// Wildcard: any write inside one canonical workspace root.
    case workspace
    /// Document/notes/canvas target identified by its stable id or path.
    case document
}

/// One exclusive target a mutation must own before it runs.
public struct MutationTargetKey: Sendable, Hashable {
    public var family: MutationKeyFamily
    /// Canonical identity: absolute resolved path, canonical workspace root,
    /// or a stable document/canvas identifier. "*" is the process-wide
    /// wildcard used when no workspace root is known.
    public var identity: String

    public init(family: MutationKeyFamily, identity: String) {
        self.family = family
        self.identity = identity
    }

    public static func file(_ canonicalPath: String) -> MutationTargetKey {
        MutationTargetKey(family: .file, identity: canonicalPath)
    }

    public static func workspace(_ canonicalRoot: String) -> MutationTargetKey {
        MutationTargetKey(family: .workspace, identity: canonicalRoot)
    }

    public static func document(_ stableID: String) -> MutationTargetKey {
        MutationTargetKey(family: .document, identity: stableID)
    }

    /// Two keys conflict when they may name the same underlying target.
    /// Deliberately conservative: a wildcard conflicts with everything it
    /// could cover, document targets conflict with any sibling mutation in
    /// the same process unless both are exactly the same file, and different
    /// file keys must be byte-identical to be considered disjoint.
    public func conflicts(with other: MutationTargetKey) -> Bool {
        if self == other { return true }
        switch (family, other.family) {
        case (.file, .file):
            // Different canonical files are disjoint.
            return false
        case (.workspace, .workspace):
            // Distinct canonical roots are disjoint; the "*" root covers all.
            return identity == "*" || other.identity == "*"
        case (.workspace, .file):
            return workspaceCoversFile(root: identity, path: other.identity)
        case (.file, .workspace):
            return workspaceCoversFile(root: other.identity, path: identity)
        case (.document, .document):
            return false
        case (.document, .file), (.file, .document):
            // A document write may rewrite an underlying file; never pretend
            // disjointness without proof.
            return true
        case (.document, .workspace), (.workspace, .document):
            return true
        }
    }

    private func workspaceCoversFile(root: String, path: String) -> Bool {
        if root == "*" { return true }
        if path == root { return true }
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

/// A held lease. Release is idempotent; the coordinator validates ownership.
public struct MutationLeaseToken: Sendable, Hashable {
    public var id: UUID
    public var keys: [MutationTargetKey]
    public var owner: String

    public init(id: UUID = UUID(), keys: [MutationTargetKey], owner: String) {
        self.id = id
        self.keys = keys
        self.owner = owner
    }
}

/// Serializes overlapping canonical mutation targets across concurrent
/// children (and any future parallel writer) with a bounded wait.
public actor MutationLeaseCoordinator {
    /// Poll interval for the bounded wait. Small enough to be invisible for
    /// real tool calls, large enough to avoid busy-waiting an actor.
    static let pollIntervalNanoseconds: UInt64 = 20_000_000

    private var active: [MutationLeaseToken] = []

    public init() {}

    /// Acquires an exclusive lease over ALL given keys. Overlapping existing
    /// leases block until released or the timeout elapses; the call then
    /// fails with an explicit error instead of proceeding unserialized.
    public func acquire(
        keys: [MutationTargetKey],
        owner: String,
        timeout: TimeInterval = 30
    ) async throws -> MutationLeaseToken {
        let normalized = Self.normalized(keys)
        let token = MutationLeaseToken(keys: normalized, owner: owner)
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            if canGrant(token) {
                active.append(token)
                return token
            }
            guard Date() < deadline else {
                throw FloeError.validationFailed(
                    "Timed out waiting for the workspace mutation lease held by "
                        + active.map(\.owner).joined(separator: ", ")
                )
            }
            try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
        }
    }

    /// Releases a held lease. Unknown tokens are ignored so a double release
    /// can never release another owner's lease.
    public func release(_ token: MutationLeaseToken) {
        active.removeAll { $0.id == token.id }
    }

    /// Runs `body` under the lease, releasing it on every exit path.
    public func withLease<T: Sendable>(
        keys: [MutationTargetKey],
        owner: String,
        timeout: TimeInterval = 30,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        let token = try await acquire(keys: keys, owner: owner, timeout: timeout)
        defer { release(token) }
        return try await body()
    }

    /// Test/audit introspection.
    public var heldLeases: [MutationLeaseToken] { active }

    public func isIdle() -> Bool { active.isEmpty }

    private func canGrant(_ candidate: MutationLeaseToken) -> Bool {
        for lease in active {
            for held in lease.keys where candidate.keys.contains(where: { $0.conflicts(with: held) }) {
                return false
            }
        }
        return true
    }

    private static func normalized(_ keys: [MutationTargetKey]) -> [MutationTargetKey] {
        var seen = Set<MutationTargetKey>()
        return keys.filter { seen.insert($0).inserted }.sorted {
            ($0.family.rawValue, $0.identity) < ($1.family.rawValue, $1.identity)
        }
    }
}

/// Resolves a tool call to its canonical mutation keys without reading model
/// intent. Unknown or unresolvable mutating targets conservatively return the
/// workspace wildcard; read-only/internal-state calls return no keys.
public enum MutationTargetResolver {
    /// Tools whose first argument names a workspace file target.
    static let workspaceFileTools: Set<String> = [
        "workspace.createFile", "workspace.writeFile", "workspace.applyPatch",
        "workspace.createDirectory", "workspace.moveFile", "workspace.deleteFile",
        "workspace.copyFile", "workspace.appendFile", "workspace.replaceText",
        "document.createMarkdown"
    ]

    /// Argument names that carry a workspace-relative or absolute path.
    static let pathArgumentKeys = ["path", "file", "filePath", "source", "from", "to", "destination"]

    /// Tools whose target is a document/notes/canvas identity.
    static let documentToolPrefixes = [
        "document.", "office.", "notes.", "canvas.", "cad.", "preview."
    ]

    /// Argument names that carry a stable document identifier.
    static let documentIDArgumentKeys = ["documentID", "documentId", "docID", "docId", "canvasID", "noteID", "id"]

    /// Mutating tools that execute arbitrary code and therefore may write
    /// anywhere in the workspace.
    static let workspaceWildcardToolNames: Set<String> = [
        "exec.shell", "exec.localPython", "exec.javascript", "exec.wasm",
        "exec.localService", "shell.open", "shell.exchange", "shell.close", "shell.signal",
        "apt", "python.packages", "jobs.submit"
    ]

    static let workspaceWildcardPrefixes = ["network.", "ssh.", "vnc.", "github."]

    /// Returns the exclusive keys a child call must hold, or [] when the call
    /// is not a mutation. Never returns a narrow key for a target it cannot
    /// canonicalize.
    public static func keys(
        for call: ToolCall,
        descriptor: ToolCatalog.Descriptor?,
        workspaceRootURL: URL?,
        fileManager: FileManager = .default
    ) -> [MutationTargetKey] {
        guard let descriptor, descriptor.effect == .mutating else { return [] }
        let rootKey = workspaceWildcardKey(root: workspaceRootURL)
        let arguments = (try? JSONSerialization.jsonObject(with: call.argumentsJSON)) as? [String: Any]
        let name = call.toolName

        if workspaceWildcardToolNames.contains(name)
            || workspaceWildcardPrefixes.contains(where: { name.hasPrefix($0) }) {
            return [rootKey]
        }

        if workspaceFileTools.contains(name) {
            var keys: [MutationTargetKey] = []
            for key in pathArgumentKeys {
                if let raw = arguments?[key] as? String,
                   let resolved = canonicalFilePath(raw, root: workspaceRootURL, fileManager: fileManager) {
                    keys.append(.file(resolved))
                }
            }
            return keys.isEmpty ? [rootKey] : unique(keys)
        }

        if documentToolPrefixes.contains(where: { name.hasPrefix($0) }) {
            if let raw = arguments?["path"] as? String,
               let resolved = canonicalFilePath(raw, root: workspaceRootURL, fileManager: fileManager) {
                return [.file(resolved)]
            }
            for key in documentIDArgumentKeys {
                if let raw = arguments?[key] as? String, isPlausibleStableID(raw) {
                    return [.document("\(name.prefix(while: { $0 != "." })):\(raw)")]
                }
            }
            return [rootKey]
        }

        // Any other mutating tool: never assume it is narrow.
        return [rootKey]
    }

    static func workspaceWildcardKey(root: URL?) -> MutationTargetKey {
        guard let root else { return .workspace("*") }
        return .workspace(root.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    static func canonicalFilePath(_ raw: String, root: URL?, fileManager: FileManager) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 4096 else { return nil }
        let url: URL
        if trimmed.hasPrefix("/") {
            url = URL(fileURLWithPath: trimmed)
        } else if let root {
            url = root.appendingPathComponent(trimmed)
        } else {
            return nil
        }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Stable ids are opaque but bounded; reject obviously unbounded or empty
    /// values so a model cannot flood the key space.
    static func isPlausibleStableID(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 256 else { return false }
        return !trimmed.contains("\n")
    }

    private static func unique(_ keys: [MutationTargetKey]) -> [MutationTargetKey] {
        var seen = Set<MutationTargetKey>()
        return keys.filter { seen.insert($0).inserted }
    }
}
