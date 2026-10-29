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

/// The full resolution of one mutating call: lease/authority keys (FIRST key
/// preserves every existing consumer mirror), the policy-visible mutable
/// targets (roles included), and whether the write extent stayed unresolved.
/// Built by `MutationTargetResolver.resolve` from the typed contract — the
/// single source of truth shared by mutation coordination, the
/// runtime-authority canonical target and the approval carve-out.
public struct MutationTargetResolution: Sendable {
    /// Exclusive lease/authority keys. The FIRST key is the runtime-authority
    /// canonical target: it keeps each existing consumer mirror intact
    /// (office/CAD `file:<path>`, media.project `workspace:<root>`).
    public var keys: [MutationTargetKey]
    /// Canonical absolute paths of every target that is genuinely MUTABLE
    /// (typed contract, or legacy file keys). Read-only inputs are never
    /// listed. Empty when nothing could be pinned.
    public var mutableTargets: [TypedMutableTarget]
    /// True when the call's specific write extent could NOT be pinned (the
    /// keys carry the workspace wildcard as a real unresolved extent, not as
    /// a mirror-preserving bound).
    public var hasUnresolvedExtent: Bool
    /// True when the typed contract declares this tool+action (its mutable
    /// outputs are typed). False for legacy-resolved families, whose file
    /// keys are still pinned conservatively but are NOT ordinary
    /// document-family coverage.
    public var contractCovered: Bool

    public init(
        keys: [MutationTargetKey],
        mutableTargets: [TypedMutableTarget],
        hasUnresolvedExtent: Bool,
        contractCovered: Bool = false
    ) {
        self.keys = keys
        self.mutableTargets = mutableTargets
        self.hasUnresolvedExtent = hasUnresolvedExtent
        self.contractCovered = contractCovered
    }
}

/// Resolves a tool call to its canonical mutation keys without reading model
/// intent. Unknown or unresolvable mutating targets conservatively return the
/// workspace wildcard; read-only/internal-state calls return no keys.
///
/// Typed contract: the ordinary document/media families (PDF editors, office
/// apply/export, media.project, video/audio/image editors) resolve their REAL
/// mutable outputs through `TypedMutationContract` — see
/// TypedMutationTargets.swift for the single source of truth.
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
    /// canonicalize. Equivalent to `resolve(...).keys` with no service stores
    /// or staged document.
    public static func keys(
        for call: ToolCall,
        descriptor: ToolCatalog.Descriptor?,
        workspaceRootURL: URL?,
        fileManager: FileManager = .default
    ) -> [MutationTargetKey] {
        resolve(
            for: call,
            descriptor: descriptor,
            workspaceRootURL: workspaceRootURL,
            fileManager: fileManager
        ).keys
    }

    /// Full resolution shared by lease coordination, the runtime-authority
    /// canonical target and the approval policy.
    ///
    /// - `serviceStorePaths`: trusted service-owned store roots keyed by the
    ///   contract's store keys (e.g. the media project store). Model arguments
    ///   address records inside; they never mint authority.
    /// - `stagedDocument`: the run's explicitly authorized Canvas staged
    ///   document. When a `cad.document` call addresses exactly that document
    ///   (its exact relative path or the canonical absolute form), the target
    ///   is pinned to the STAGED DRAFT ROOT — never the broader task root and
    ///   never any other document under it (fail closed otherwise). This
    ///   mirrors the tool side, which derives its access from the same staged
    ///   binding.
    public static func resolve(
        for call: ToolCall,
        descriptor: ToolCatalog.Descriptor?,
        workspaceRootURL: URL?,
        serviceStorePaths: [String: String] = [:],
        stagedDocument: CanvasStagedDocumentAccess? = nil,
        fileManager: FileManager = .default
    ) -> MutationTargetResolution {
        guard let descriptor, descriptor.effect == .mutating else {
            return MutationTargetResolution(keys: [], mutableTargets: [], hasUnresolvedExtent: false)
        }
        let rootKey = workspaceWildcardKey(root: workspaceRootURL)
        let arguments = (try? JSONSerialization.jsonObject(with: call.argumentsJSON)) as? [String: Any]
        let name = call.toolName

        // J Canvas-staged contract: an authorized staged document addressed
        // by its exact relative path or canonical absolute form pins to the
        // staged draft root. Hoisted so the typed contract resolves this
        // call's relative paths against the SAME root the tool's
        // `access.workspacePath` uses; anything else under the draft root is
        // never covered by the staged binding (fail closed).
        let stagedTarget: String? = {
            guard name == "cad.document", let staged = stagedDocument,
                  let raw = arguments?["path"] as? String else { return nil }
            return stagedDocumentTarget(raw: raw, staged: staged, fileManager: fileManager)
        }()
        let effectiveRootURL: URL? = stagedTarget.map { _ in
            URL(fileURLWithPath: stagedDocument?.draftRootPath ?? "")
        }

        // Legacy branches, verbatim behavior, collected into a variable so the
        // typed contract can extend them without changing their first-key
        // semantics (the runtime-authority mirrors depend on it).
        let legacyKeys: [MutationTargetKey] = {
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
                if name == "cad.document", let key = arguments?["path"] as? String,
                   CanvasCADBindingKey.isCanvasOwned(key) {
                    guard let canonical = TypedMutationContract.canonicalCADCanvasDocumentPath(
                        key, serviceStorePaths: serviceStorePaths) else { return [rootKey] }
                    return [.file(canonical)]
                }
                if let stagedTarget {
                    return [.file(stagedTarget)]
                }
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
        }()

        // Typed contract (single source of truth). Only the ordinary
        // document/media families declare specs; every other tool keeps the
        // legacy behavior exactly.
        let specs = TypedMutationContract.specs(for: name, arguments: arguments ?? [:])
        if !specs.isEmpty {
            guard let mutable = TypedMutationContract.resolveMutableTargets(
                for: name,
                arguments: arguments ?? [:],
                workspaceRootURL: workspaceRootURL,
                serviceStorePaths: serviceStorePaths,
                effectiveRootURL: effectiveRootURL,
                fileManager: fileManager
            ) else {
                // A required target could not be pinned: the whole write
                // extent is unresolved — conservative wildcard, existing
                // policy. Never a partial classification.
                return MutationTargetResolution(keys: [rootKey], mutableTargets: [],
                                                hasUnresolvedExtent: true, contractCovered: true)
            }
            var keys = legacyKeys
            if !TypedMutationContract.keepsWorkspaceBounding(name) {
                // The typed targets fully bound the write set: drop the legacy
                // fallback wildcard so coordination and authority get the
                // narrow file keys.
                keys = keys.filter { $0.family != .workspace }
            } else {
                // media.project: the mirror-preserved workspace bound stays
                // FIRST, typed store/export keys follow.
                keys = [rootKey] + keys.filter { $0.family != .workspace }
            }
            for target in mutable where !keys.contains(.file(target.path)) {
                keys.append(.file(target.path))
            }
            return MutationTargetResolution(keys: keys, mutableTargets: mutable,
                                            hasUnresolvedExtent: false, contractCovered: true)
        }

        let legacyMutable = legacyKeys
            .filter { $0.family == .file }
            .map { TypedMutableTarget(path: $0.identity, role: .pinned) }
        let unresolved = legacyKeys.contains { $0.family == .workspace }
        return MutationTargetResolution(keys: legacyKeys, mutableTargets: legacyMutable, hasUnresolvedExtent: unresolved)
    }

    /// J Canvas-staged contract: `path` (trimmed, bounded) must equal the
    /// exact stagedRelativePath or the canonical absolute staged path.
    /// Returns the canonical absolute staged target on a match, nil otherwise
    /// (nil = ordinary resolution; the staged binding is never a fallback).
    static func stagedDocumentTarget(
        raw: String,
        staged: CanvasStagedDocumentAccess,
        fileManager: FileManager
    ) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 4096 else { return nil }
        let stagedRoot = URL(fileURLWithPath: staged.draftRootPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let stagedCanonical = stagedRoot
            .appendingPathComponent(staged.stagedRelativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        if trimmed == staged.stagedRelativePath {
            return stagedCanonical
        }
        // Canonical absolute form of the argument (if it is absolute) must
        // equal the canonical staged path byte-for-byte.
        guard trimmed.hasPrefix("/") else { return nil }
        let argumentCanonical = URL(fileURLWithPath: trimmed)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return argumentCanonical == stagedCanonical ? stagedCanonical : nil
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
