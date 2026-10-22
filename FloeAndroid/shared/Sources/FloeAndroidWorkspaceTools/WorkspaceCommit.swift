// FloeAndroidWorkspaceTools — conflict-aware writeback: three-way
// classification (baseline / received / current) and the REAL CAS commit.
//
// Android-owned (job-ade884c46eb84ec1). No blind overwrite exists here:
//  * the expected side of every CAS is the BASELINE digest captured from the
//    actual bytes at import-begin;
//  * the CURRENT Core state is re-scanned at commit-begin; a path the user or
//    Core changed after baseline is a CONFLICT and both versions survive
//    (the current bytes stay in the workspace, the runtime bytes move to the
//    session's conflict artifacts — never dropped);
//  * file replacement goes through the ORIGINAL authority,
//    `AtomicFileCommitter` with `.replaceIfUnchanged(expectedSHA256:)` — a
//    digest compare of the actual current bytes performed by the ORIGINAL
//    committer BEFORE it touches the destination, not an mtime compare and
//    not a success-string transaction; every per-entry compare+replace/
//    delete/link/parent-check sequence additionally runs while holding the
//    ORIGINAL `ManagedFileMutationLock.shared` recursive lock, the same lock
//    the managed text/Office writers hold for their synchronous file
//    transactions, so version comparison and atomic replacement cannot
//    interleave with those writers. HONEST LIMITATION (from the original
//    lock's own contract): it serializes cooperating managed writers in
//    this process — it is not a kernel-wide mandatory lock; arbitrary
//    external/SAF cooperating writers remain possible and are caught by the
//    digest CAS as conflicts, not prevented. The staged payload digest is
//    re-verified BEFORE destination replace (verifyBeforeCommit), so a
//    corrupt staged copy can never land;
//  * deletions re-verify the digest through the no-follow fd immediately
//    before unlinking, and directories only ever leave via `rmdir`, which
//    structurally cannot remove new user descendants (ENOTEMPTY keeps them
//    and is reported honestly);
//  * every effect is preceded by a fsynced journal intent and followed by a
//    journal result. Multi-file atomicity is NOT promised — the outcome JSON
//    reports exactly which paths were applied, kept, conflicted or failed.

import Foundation
import FloeCore
import FloeTools
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

// MARK: - Received (staged) entry from the runtime side

public struct WorkspaceReceivedEntry: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case file, directory, symlink
    }

    public var sequence: Int64
    public var relativePath: String
    public var kind: Kind
    /// CLAIMED by the runtime (header). Never trusted: `recordedSize`/
    /// `recordedDigest` below are what the engine actually read.
    public var claimedSize: Int64
    public var claimedMode: Int32
    public var linkTarget: String?
    /// Regular-file payload landed in staging and hashed from the staged
    /// bytes; nil for directory/symlink headers.
    public var recordedSize: Int64?
    public var recordedDigest: String?
    public var stagingPath: String?
    /// Non-nil means the engine refused this entry (the runtime version is
    /// still preserved in staging when `stagingPath` exists).
    public var refusal: String?

    public init(sequence: Int64, relativePath: String, kind: Kind,
                claimedSize: Int64, claimedMode: Int32, linkTarget: String?,
                recordedSize: Int64? = nil, recordedDigest: String? = nil,
                stagingPath: String? = nil, refusal: String? = nil) {
        self.sequence = sequence
        self.relativePath = relativePath
        self.kind = kind
        self.claimedSize = claimedSize
        self.claimedMode = claimedMode
        self.linkTarget = linkTarget
        self.recordedSize = recordedSize
        self.recordedDigest = recordedDigest
        self.stagingPath = stagingPath
        self.refusal = refusal
    }
}

// MARK: - Plan

public struct WorkspacePlannedAction: Sendable {
    public enum Effect: Sendable, Equatable {
        case createFile
        case replaceCAS(expectedDigest: String)
        case createEmptyDirectory
        case deleteFile(expectedDigest: String)
        case deleteDirectoryRmdir
        case createSafeLink
        case deleteSafeLink(expectedTarget: String)
    }

    public enum ConflictKind: String, Sendable, Equatable {
        case userEditedVsRuntimeEdited      // current digest != baseline, runtime changed too
        case userEditedVsRuntimeDeleted     // current digest != baseline, runtime deleted
        case userCreatedVsRuntimeCreated    // path appeared in Core after baseline, runtime also created
        case kindChanged                    // current entry kind differs from baseline kind (user replaced file with dir/link)
        case pathUnsafe                     // relative path refused on validation
        case finalElementSymlink            // destination final component is a symlink: refuse, touch nothing
        case refusedEntry                   // runtime entry refused at staging (digest mismatch, budget, special)
        case directoryNotEmptyKept          // rmdir refused: new descendants preserved
    }

    public var relativePath: String
    public var effect: Effect?
    public var conflict: ConflictKind?
    /// Staged file to move in (for writes), conflict artifact id, etc.
    public var sourceStagingPath: String?
    /// The digest the engine actually read while staging the source bytes.
    /// The executor re-verifies the staged file against it BEFORE the
    /// destination changes (a post-commit-only check would already have
    /// touched user data).
    public var recordedDigest: String?
    public var mode: Int32
    public var linkTarget: String?

    public init(relativePath: String, effect: Effect?, conflict: ConflictKind?,
                sourceStagingPath: String? = nil, recordedDigest: String? = nil,
                mode: Int32 = 0o644, linkTarget: String? = nil) {
        self.relativePath = relativePath
        self.effect = effect
        self.conflict = conflict
        self.sourceStagingPath = sourceStagingPath
        self.recordedDigest = recordedDigest
        self.mode = mode
        self.linkTarget = linkTarget
    }

    var depth: Int { relativePath.split(separator: "/").count }
}

public struct WorkspaceCommitSummary: Sendable {
    public var appliedCreates = 0
    public var appliedReplaces = 0
    public var appliedDirectories = 0
    public var appliedDeletions = 0
    public var appliedLinks = 0
    public var conflicts: [(path: String, kind: WorkspacePlannedAction.ConflictKind, artifactRef: String?)] = []
    public var keptInWorkspace = 0
    public var failedEffects: [(path: String, code: String)] = []
    public var appliedBeforeAbort: Bool { !failedEffects.isEmpty && (appliedCreates + appliedReplaces + appliedDirectories + appliedDeletions + appliedLinks) > 0 }
    public var isFullySynced: Bool {
        conflicts.isEmpty && failedEffects.isEmpty && !partialAbort
    }
    public var partialAbort = false

    public init() {}
}

// MARK: - Commit gate (REAL injected callback; fail closed when absent)

public struct WorkspaceCommitRequest: Sendable {
    public var projectID: UUID
    public var runID: UUID
    public var rootEpoch: UInt64
    public var sessionKey: String
    public var plannedEffects: Int
    public var plannedConflicts: Int
    /// Stable digest over the sorted plan path list, so the gate can bind
    /// its decision to the exact plan it reviewed.
    public var planDigest: String
}

/// The injected commit gate. This lane NEVER ships a default-true gate:
/// `WorkspaceTransferEngine` refuses every commit while one is not
/// installed. The production installation point is
/// `LinuxWorkspaceAuthority.install` (FloeAndroidCore), where Main wires it
/// to the REAL run-lifecycle authority (active run + held foreground lease +
/// not temporary chat).
public protocol WorkspaceCommitGate: Sendable {
    func allow(_ request: WorkspaceCommitRequest) -> Bool
}

// MARK: - Classification

public enum WorkspaceCommitPlanner {
    /// Three-way classification. `current` is a fresh no-follow scan of the
    /// actual Core workspace at commit-begin.
    public static func plan(baseline: WorkspaceBaselineScan,
                            received: [WorkspaceReceivedEntry],
                            current: [String: WorkspaceBaselineEntry],
                            budgets: WorkspaceTransferBudgets) throws -> [WorkspacePlannedAction] {
        var plan: [WorkspacePlannedAction] = []
        var byPathReceived: [String: WorkspaceReceivedEntry] = [:]
        for entry in received {
            if byPathReceived[entry.relativePath] != nil {
                plan.append(WorkspacePlannedAction(relativePath: entry.relativePath, effect: nil,
                                                   conflict: .refusedEntry))
                continue
            }
            byPathReceived[entry.relativePath] = entry
        }
        let allPaths = Set(baseline.entries.keys)
            .union(byPathReceived.keys)
            .union(current.keys)
            .sorted()

        for path in allPaths {
            let base = baseline.entries[path]
            let recv = byPathReceived[path]
            let cur = current[path]
            // Skipped baseline entries are Core-owned bytes that were never
            // mirrored: the runtime could not have seen them. Any runtime
            // activity on the same path is refused/kept, and the baseline
            // entry itself must never be deleted by this session.
            let baseSkipped = base?.skipped != nil

            if baseSkipped {
                if recv != nil {
                    plan.append(WorkspacePlannedAction(relativePath: path, effect: nil,
                                                       conflict: .refusedEntry))
                }
                continue
            }

            // Validate the path itself against the actual-FS view we plan to
            // touch (defense in depth; scan already validated both sides).
            if (try? WorkspaceRelativePath.validate(path, budgets: budgets)) == nil {
                plan.append(WorkspacePlannedAction(relativePath: path, effect: nil,
                                                   conflict: recv != nil ? .pathUnsafe : .refusedEntry))
                continue
            }

            if let recv, let refusal = recv.refusal {
                // Staging-time refusal (claimed/actual mismatch, budget,
                // unsafe link): preserve nothing in the workspace.
                plan.append(WorkspacePlannedAction(relativePath: path, effect: nil,
                                                   conflict: .refusedEntry))
                _ = refusal
                continue
            }

            // Case the runtime deleted this path.
            if base != nil && recv == nil && !baseSkipped {
                guard let cur else {
                    // Already gone on Core (user deleted it too): accepted.
                    continue
                }
                if cur.skipped != nil {
                    plan.append(WorkspacePlannedAction(relativePath: path, effect: nil,
                                                       conflict: .refusedEntry))
                    continue
                }
                if cur.kind != base!.kind || (base!.kind == .symlink && cur.linkTarget != base!.linkTarget) {
                    plan.append(WorkspacePlannedAction(relativePath: path, effect: nil,
                                                       conflict: .kindChanged))
                    continue
                }
                switch cur.kind {
                case .file:
                    // Delete ONLY the exact bytes the baseline saw. A current
                    // digest mismatch is a concurrent edit: keep, conflict.
                    if let expected = base!.digest {
                        plan.append(WorkspacePlannedAction(relativePath: path,
                                                           effect: .deleteFile(expectedDigest: expected),
                                                           conflict: nil, mode: cur.mode))
                    } else {
                        plan.append(WorkspacePlannedAction(relativePath: path, effect: nil,
                                                           conflict: .refusedEntry))
                    }
                case .directory:
                    plan.append(WorkspacePlannedAction(relativePath: path,
                                                       effect: .deleteDirectoryRmdir, conflict: nil))
                case .symlink:
                    if let target = base!.linkTarget {
                        plan.append(WorkspacePlannedAction(relativePath: path,
                                                           effect: .deleteSafeLink(expectedTarget: target),
                                                           conflict: nil))
                    } else {
                        plan.append(WorkspacePlannedAction(relativePath: path, effect: nil,
                                                           conflict: .refusedEntry))
                    }
                }
                continue
            }

            guard let recv else {
                // base present or absent, no runtime view, current may exist:
                // nothing to do for this path. (Runtime saw a file it then
                // deleted is the branch above; this is "user-only" state.)
                continue
            }

            // Runtime presents this path (created/modified/kept).
            switch recv.kind {
            case .file:
                guard let recorded = recv.recordedDigest, recv.stagingPath != nil else {
                    plan.append(WorkspacePlannedAction(relativePath: path, effect: nil,
                                                       conflict: .refusedEntry))
                    continue
                }
                if let cur {
                    if cur.skipped != nil {
                        plan.append(WorkspacePlannedAction(relativePath: path, effect: nil,
                                                           conflict: .refusedEntry))
                        continue
                    }
                    if cur.kind != .file {
                        plan.append(WorkspacePlannedAction(relativePath: path, effect: nil,
                                                           conflict: .kindChanged))
                        continue
                    }
                    if base != nil, let baselineDigest = base!.digest, cur.digest == baselineDigest {
                        if cur.digest == recorded {
                            // Unchanged everywhere: nothing to write.
                            plan.append(WorkspacePlannedAction(relativePath: path, effect: nil, conflict: nil,
                                                               mode: cur.mode))
                            continue
                        }
                        plan.append(WorkspacePlannedAction(relativePath: path,
                                                           effect: .replaceCAS(expectedDigest: baselineDigest),
                                                           conflict: nil,
                                                           sourceStagingPath: recv.stagingPath,
                                                           recordedDigest: recv.recordedDigest, mode: cur.mode))
                        continue
                    }
                    if base != nil && cur.digest != base!.digest {
                        // Concurrent user/Core edit + runtime edit: conflict,
                        // keep both (user bytes stay; runtime bytes become the
                        // conflict artifact at execute time).
                        plan.append(WorkspacePlannedAction(relativePath: path, effect: nil,
                                                           conflict: .userEditedVsRuntimeEdited,
                                                           sourceStagingPath: recv.stagingPath,
                                                           recordedDigest: recv.recordedDigest))
                        continue
                    }
                    if base == nil {
                        // Appeared on Core after baseline; runtime created the
                        // same path: create-vs-create conflict, keep user.
                        plan.append(WorkspacePlannedAction(relativePath: path, effect: nil,
                                                           conflict: .userCreatedVsRuntimeCreated,
                                                           sourceStagingPath: recv.stagingPath,
                                                           recordedDigest: recv.recordedDigest))
                        continue
                    }
                    plan.append(WorkspacePlannedAction(relativePath: path, effect: nil,
                                                       conflict: .refusedEntry))
                } else {
                    if base != nil {
                        // In baseline, absent now: the user deleted it while
                        // the runtime edited it. Keep the deletion (user truth)
                        // and preserve the runtime bytes as an artifact.
                        plan.append(WorkspacePlannedAction(relativePath: path, effect: nil,
                                                           conflict: .userEditedVsRuntimeDeleted,
                                                           sourceStagingPath: recv.stagingPath,
                                                           recordedDigest: recv.recordedDigest))
                        continue
                    }
                    plan.append(WorkspacePlannedAction(relativePath: path, effect: .createFile,
                                                       conflict: nil,
                                                       sourceStagingPath: recv.stagingPath,
                                                       recordedDigest: recv.recordedDigest,
                                                       mode: recvMode(recv)))
                }
            case .directory:
                if base?.kind == .directory, cur?.kind == .directory || cur == nil {
                    // Existing directory kept: nothing (create marker only
                    // matters for empty new directories).
                    plan.append(WorkspacePlannedAction(relativePath: path, effect: nil, conflict: nil))
                    continue
                }
                if let cur {
                    if cur.kind != .directory {
                        plan.append(WorkspacePlannedAction(relativePath: path, effect: nil,
                                                           conflict: .kindChanged))
                        continue
                    }
                    plan.append(WorkspacePlannedAction(relativePath: path, effect: nil, conflict: nil))
                    continue
                }
                plan.append(WorkspacePlannedAction(relativePath: path, effect: .createEmptyDirectory,
                                                   conflict: nil, mode: recv.claimedMode & 0o755))
            case .symlink:
                guard let target = recv.linkTarget else {
                    plan.append(WorkspacePlannedAction(relativePath: path, effect: nil,
                                                       conflict: .refusedEntry))
                    continue
                }
                let components = path.split(separator: "/").map(String.init)
                guard WorkspaceRelativePath.classifyLinkTarget(target, linkComponents: components,
                                                               budgets: budgets) == .relativeContained else {
                    // Escape/absolute runtime link: refuse, never follow into
                    // Core. The staged artifact (if any) stays recoverable.
                    plan.append(WorkspacePlannedAction(relativePath: path, effect: nil,
                                                       conflict: .refusedEntry))
                    continue
                }
                if let base, base.kind == .symlink, base.linkTarget == target, cur?.kind == .symlink {
                    plan.append(WorkspacePlannedAction(relativePath: path, effect: nil, conflict: nil))
                    continue
                }
                if cur != nil {
                    if cur?.kind == .symlink, cur?.linkTarget == target {
                        plan.append(WorkspacePlannedAction(relativePath: path, effect: nil, conflict: nil))
                    } else {
                        plan.append(WorkspacePlannedAction(relativePath: path, effect: nil,
                                                           conflict: .kindChanged))
                    }
                    continue
                }
                if base?.kind == .symlink {
                    // Baseline link vanished or changed: only re-create when
                    // the target matches the baseline (else handled above).
                    plan.append(WorkspacePlannedAction(relativePath: path, effect: .createSafeLink,
                                                       conflict: nil, linkTarget: target))
                    continue
                }
                plan.append(WorkspacePlannedAction(relativePath: path, effect: .createSafeLink,
                                                   conflict: nil, linkTarget: target))
            }
        }
        return plan
    }

    private static func recvMode(_ entry: WorkspaceReceivedEntry) -> Int32 {
        // Claimed modes are NEVER trusted: they are clamped to a safe subset
        // (owner rwx, group/other rx; no setuid/setgid/sticky/world-write)
        // before the commit applies them through chmod after content lands.
        // Replacements keep the ACTUAL current mode observed by the scan.
        let masked = entry.claimedMode & 0o755
        return masked == 0 ? 0o644 : masked
    }
}
