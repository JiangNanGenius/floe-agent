// FloeSecurity — Runtime-resolved trusted execution context.
//
// The deterministic local approval carve-outs decide ONLY from values the
// running runtime resolved from its own frozen state: every MUTABLE target
// the typed contract pinned, whether the call's write extent could be pinned
// at all, the canonical workspace root, and the environment class derived
// from the frozen environment binding. A model writing `"safe":true`,
// `"local":true`, `"confirmed":true` or an approval-looking field creates
// nothing here, and an unresolved or unproven context always keeps the task's
// existing approval policy (fail closed).
//
// This is deliberately NOT a second approval system: the context only
// carries facts, and the existing ApprovalPolicy / ApprovalGrant flow remains
// the only thing that turns facts into permission.

import Foundation

/// Trusted class of the execution environment a call routes to.
public enum ApprovalEnvironmentClass: String, Sendable, Codable, Hashable {
    /// The run's execution environment resolves to a local Linux guest: the
    /// environment record is explicitly `executionBackend == .linuxVM` and
    /// not being deleted — exactly the predicate the guest backend applies
    /// when it routes `exec.shell` into the VM. The guest may be a per-task
    /// session container or a shared/project environment, so this class makes
    /// NO ownership, disposability or data-protection claim: environment
    /// ownership is enforced separately by the execution coordinator before
    /// any backend dispatch, and the user's reduced-review policy for this
    /// guest does not change deletion/reset or persistent-data safeguards.
    case localLinuxVM
    /// Any other local execution (native compatibility backend, or an
    /// environment the runtime could not classify as a guest).
    case localNative
    /// A remote target reached through a host-scoped call.
    case remote
    /// The runtime did not resolve an environment: no carve-out applies.
    case unknown
}

/// Whether a resolved target lies inside a Git worktree / repository.
public enum RepositoryBoundary: Sendable, Hashable, Codable {
    /// A `.git` ancestor proved the target is repository content: ordinary
    /// repository content keeps the existing write policy.
    case insideWorktree(rootPath: String)
    /// The walk reached the volume root without finding `.git` and without
    /// any unreadable/ambiguous metadata.
    case outsideWorktree
    /// No path was resolved, the ancestor bound was reached first, or the
    /// `.git` metadata could not be read/interpreted. Never treated as
    /// "outside": a carve-out must be positively proven.
    case undetermined
}

/// Bounded `.git` ancestry detection. Handles both the ordinary
/// `<root>/.git` DIRECTORY and the worktree/submodule `.git` FILE whose first
/// bytes declare `gitdir:`. Anything that cannot be positively decided —
/// bound exhausted, unreadable or non-gitfile `.git` metadata, a `.git` entry
/// that is neither a directory nor a regular file — is `.undetermined`, which
/// no carve-out accepts.
public enum RepositoryBoundaryDetector {
    public static let maximumAncestors = 64
    public static let maximumGitFileBytes = 4 * 1024

    private enum GitEntryState {
        case absent
        case directory
        case file
        case unknown
    }

    public static func classify(
        path: String?,
        fileManager: FileManager = .default
    ) -> RepositoryBoundary {
        guard let path,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .undetermined
        }
        var url = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            // Classify the containing directory for a file target; a
            // directory target (workspace root) is walked directly.
            url = url.deletingLastPathComponent()
        }
        var remaining = maximumAncestors
        while true {
            let gitEntry = url.appendingPathComponent(".git")
            switch gitEntryState(at: gitEntry) {
            case .directory:
                return .insideWorktree(rootPath: url.path)
            case .file:
                guard let data = try? Data(contentsOf: gitEntry, options: [.mappedIfSafe]),
                      let text = String(data: data.prefix(maximumGitFileBytes), encoding: .utf8),
                      text.lowercased().contains("gitdir:") else {
                    // A `.git` file we cannot read or that does not declare a
                    // gitdir is metadata we cannot interpret: unproven.
                    return .undetermined
                }
                return .insideWorktree(rootPath: url.path)
            case .unknown:
                return .undetermined
            case .absent:
                break
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path {
                // Reached the volume root without any `.git`: positively
                // outside a worktree.
                return .outsideWorktree
            }
            remaining -= 1
            if remaining <= 0 {
                // The bound was reached before the walk terminated: unproven.
                return .undetermined
            }
            url = parent
        }
    }

    private static func gitEntryState(at url: URL) -> GitEntryState {
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true { return .directory }
            if values.isRegularFile == true { return .file }
            return .unknown
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain,
               error.code == CocoaError.Code.fileReadNoSuchFile.rawValue {
                return .absent
            }
            if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) {
                return .absent
            }
            // Permission failures and any other IO error are unproven.
            return .unknown
        }
    }
}

/// The runtime-derived facts a deterministic carve-out may rely on. Every
/// field is resolved by the canonical runtime path from the run's frozen
/// configuration, the approved call and the descriptor — never from model
/// arguments or model-authored confirmation.
public struct TrustedExecutionContext: Sendable, Hashable, Codable {
    public var environmentClass: ApprovalEnvironmentClass
    /// Canonical absolute paths of EVERY target the typed mutable-target
    /// contract pinned as MUTABLE for this call (sorted, deduplicated).
    /// READ-ONLY inputs are never listed — a PDF `inputPath`, an office
    /// `imagePath`, a video/audio `input` or `mixPath` read from repository
    /// content does NOT make the call a repository write — and the source of
    /// an authorized copy/edit is listed only when the tool itself rewrites
    /// it in place. An empty list can never satisfy a document carve-out.
    public var mutableTargetPaths: [String]
    /// True when the call's specific write extent could NOT be pinned (a
    /// required output missing/unresolvable, or a legacy wildcard extent):
    /// the call may write anywhere in the workspace, so a document carve-out
    /// must not pretend it was resolved.
    public var hasUnresolvedExtent: Bool
    /// True when the runtime's typed mutable-target contract declares this
    /// tool+action and its real outputs were resolved from the contract
    /// (false = a legacy-resolved or unknown family, which is not ordinary
    /// document-family coverage). Runtime-resolved classification, never
    /// model data.
    public var typedContractCovered: Bool
    /// Canonical workspace root this call's effects are bounded by, when
    /// known. Used only by the guest-command tier as the bounding context.
    public var workspaceRootPath: String?

    /// Canonical native CAD document identity from the runtime's typed
    /// resolver, including a verified Canvas staged-document mapping. This
    /// cannot be reconstructed from a relative path against the task root.
    public var nativeCADDocumentPath: String?

    /// The context attached when nothing was resolved: every carve-out fails
    /// closed to the task's existing approval policy.
    public static let unresolved = TrustedExecutionContext()

    public init(
        environmentClass: ApprovalEnvironmentClass = .unknown,
        mutableTargetPaths: [String] = [],
        hasUnresolvedExtent: Bool = false,
        typedContractCovered: Bool = false,
        workspaceRootPath: String? = nil,
        nativeCADDocumentPath: String? = nil
    ) {
        self.environmentClass = environmentClass
        self.mutableTargetPaths = mutableTargetPaths
        self.hasUnresolvedExtent = hasUnresolvedExtent
        self.typedContractCovered = typedContractCovered
        self.workspaceRootPath = workspaceRootPath
        self.nativeCADDocumentPath = nativeCADDocumentPath
    }

    /// True only when at least one MUTABLE target was pinned and EVERY pinned
    /// target is positively outside a Git worktree. One repository target —
    /// or one undetermined target — fails the whole call.
    public var targetsAllOutsideRepository: Bool {
        guard !mutableTargetPaths.isEmpty else { return false }
        return mutableTargetPaths.allSatisfy {
            RepositoryBoundaryDetector.classify(path: $0) == .outsideWorktree
        }
    }

    /// True only when the canonical workspace root is known and positively
    /// outside a Git worktree.
    public var workspaceRootOutsideRepository: Bool {
        guard let workspaceRootPath else { return false }
        return RepositoryBoundaryDetector.classify(path: workspaceRootPath) == .outsideWorktree
    }
}
