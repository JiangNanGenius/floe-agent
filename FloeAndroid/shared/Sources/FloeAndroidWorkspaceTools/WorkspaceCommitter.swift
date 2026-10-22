// FloeAndroidWorkspaceTools — the effect executor for a planned commit.
//
// Android-owned (job-ade884c46eb84ec1). Ordering is causality-safe:
//   1. empty-directory creates and file replaces/creates (parents ensured
//      component-wise with non-following checks),
//   2. safe-link creates,
//   3. file/link deletions (deepest first),
//   4. directory rmdirs (deepest first; ENOTEMPTY keeps the directory and
//      every new descendant — reported as `directoryNotEmptyKept`).
//
// Every effect: fsynced journal INTENT line before the effect, journal RESULT
// line after. Multi-file atomicity is NOT promised; the journal plus the
// terminal index gives an exact, honest replay/inspection trail.
//
// CAS foundation (Main review 2026-10-22): each per-entry synchronous file
// transaction (parent checks, destination compare, staged verify, replace,
// delete, link create, rmdir) runs while holding the ORIGINAL
// `FloeCore.ManagedFileMutationLock.shared` — the same recursive lock the
// managed text/Office writers hold — instead of an independent actor or a
// bare allow bool. This serializes THIS lane's compare+replace with those
// original managed writers. Honest limitation carried from the original
// lock's contract: it is not a kernel-wide mandatory file lock; arbitrary
// external/SAF writers are not prevented, and post-baseline Core changes
// they cause surface as digest-CAS CONFLICTS (both versions preserved),
// never as a silent overwrite.

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

public final class WorkspaceCommitter: @unchecked Sendable {
    public let workspaceRoot: String
    public let budgets: WorkspaceTransferBudgets
    public let journal: WorkspaceJournal
    public let conflictsDirectory: String
    /// Synchronous currency probe (root epoch / run / ownership). Checked
    /// once before the first effect and every 256 effects afterwards; a
    /// false answer aborts the remaining plan and is journaled.
    public let revalidate: @Sendable () -> Bool
    public let gate: WorkspaceCommitGate
    public let isCancelled: @Sendable () -> Bool

    public init(workspaceRoot: String, budgets: WorkspaceTransferBudgets,
                journal: WorkspaceJournal, conflictsDirectory: String,
                revalidate: @escaping @Sendable () -> Bool,
                gate: WorkspaceCommitGate,
                isCancelled: @escaping @Sendable () -> Bool) {
        self.workspaceRoot = workspaceRoot
        self.budgets = budgets
        self.journal = journal
        self.conflictsDirectory = conflictsDirectory
        self.revalidate = revalidate
        self.gate = gate
        self.isCancelled = isCancelled
    }

    public func execute(_ actions: [WorkspacePlannedAction],
                        planDigest: String,
                        identity: (projectID: UUID, runID: UUID, rootEpoch: UInt64, sessionKey: String))
        -> WorkspaceCommitSummary
    {
        var summary = WorkspaceCommitSummary()
        let effects = actions.filter { $0.effect != nil }
        let conflicts = actions.compactMap { action -> WorkspacePlannedAction? in
            action.conflict != nil ? action : nil
        }
        guard !effects.isEmpty || !conflicts.isEmpty else {
            // Empty plan: nothing was required; `isFullySynced` (get-only)
            // already reflects zero conflicts/zero failures/no abort.
            return summary
        }
        // Gate FIRST, before any destination change. Absent gate was already
        // refused upstream; a refusing gate changes nothing.
        let request = WorkspaceCommitRequest(projectID: identity.projectID, runID: identity.runID,
                                             rootEpoch: identity.rootEpoch, sessionKey: identity.sessionKey,
                                             plannedEffects: effects.count, plannedConflicts: conflicts.count,
                                             planDigest: planDigest)
        guard gate.allow(request) else {
            recordConflictOnly(actions: actions, summary: &summary)
            summary.partialAbort = true
            try? journal.append(["record": "commitRefused", "reason": "gateRefused", "planDigest": planDigest])
            return summary
        }
        guard revalidate() else {
            recordConflictOnly(actions: actions, summary: &summary)
            summary.partialAbort = true
            try? journal.append(["record": "commitRefused", "reason": "currencyLost", "planDigest": planDigest])
            return summary
        }

        // Conflicts preserve BOTH sides up front: current bytes stay in the
        // workspace untouched; runtime bytes move into the session's
        // conflict artifacts so nothing is ever silently dropped.
        for action in conflicts {
            let artifact: String?
            ManagedFileMutationLock.shared.lock()
            defer { ManagedFileMutationLock.shared.unlock() }
            artifact = moveConflictArtifact(action)
            summary.conflicts.append((path: action.relativePath, kind: action.conflict ?? .refusedEntry,
                                      artifactRef: artifact))
            try? journal.append(["record": "conflict", "path": action.relativePath,
                                 "kind": (action.conflict ?? .refusedEntry).rawValue,
                                 "artifact": artifact ?? ""])
        }

        let writes = effects.filter { action in
            switch action.effect {
            case .createEmptyDirectory, .createFile, .replaceCAS, .createSafeLink: return true
            default: return false
            }
        }
        let deletions = effects.filter { action in
            switch action.effect {
            case .deleteFile, .deleteSafeLink: return true
            default: return false
            }
        }
        let rmdirs = effects.filter {
            if case .deleteDirectoryRmdir = $0.effect { return true } else { return false }
        }
        let orderedWrites = writes.sorted { ($0.depth, $0.relativePath) < ($1.depth, $1.relativePath) }
        let orderedDeletions = deletions.sorted { ($0.depth, $0.relativePath) > ($1.depth, $1.relativePath) }
        let orderedRmdirs = rmdirs.sorted { ($0.depth, $0.relativePath) > ($1.depth, $1.relativePath) }

        var processed = 0
        for action in orderedWrites + orderedDeletions + orderedRmdirs {
            if isCancelled() {
                summary.partialAbort = true
                try? journal.append(["record": "commitAborted", "reason": "cancelled", "processed": processed])
                break
            }
            processed += 1
            if processed % 256 == 0 {
                if !gate.allow(request) {
                    summary.partialAbort = true
                    try? journal.append(["record": "commitAborted", "reason": "gateLost", "processed": processed])
                    break
                }
                if !revalidate() {
                    summary.partialAbort = true
                    try? journal.append(["record": "commitAborted", "reason": "currencyLost", "processed": processed])
                    break
                }
            }
            apply(action, summary: &summary)
        }
        _ = WorkspaceNoFollow.fsyncDirectory(workspaceRoot)
        return summary
    }

    // MARK: - Single effects

    private func apply(_ action: WorkspacePlannedAction, summary: inout WorkspaceCommitSummary) {
        let absolute = workspaceRoot + "/" + action.relativePath
        guard let effect = action.effect else { return }
        // Journal first (intent), then ONE synchronous file transaction
        // under the ORIGINAL managed-writer mutation lock. The lock is
        // recursive (ManagedFileMutationLock contract) and held only for
        // this transaction — never across awaits or user/model input.
        try? journal.append(["record": "intent", "path": action.relativePath, "effect": describe(effect)])
        ManagedFileMutationLock.shared.lock()
        defer { ManagedFileMutationLock.shared.unlock() }
        switch effect {
        case .createEmptyDirectory:
            if ensureParentDirectories(action.relativePath, summary: &summary, path: action.relativePath) == false { return }
            if mkdir(absolute, mode_t(truncatingIfNeeded: action.mode & 0o7777)) != 0 {
                let code = errno
                if code == EEXIST {
                    switch WorkspaceNoFollow.kind(absolute) {
                    case .directory:
                        summary.appliedDirectories += 1
                        finishJournal(action.relativePath, "exists")
                    case .symlink:
                        summary.conflicts.append((action.relativePath, .finalElementSymlink, nil))
                        finishJournal(action.relativePath, "conflict")
                    default:
                        recordFailure(action.relativePath, "mkdirRace", summary: &summary)
                    }
                } else {
                    recordFailure(action.relativePath, "mkdir\(code)", summary: &summary)
                }
                return
            }
            summary.appliedDirectories += 1
            finishJournal(action.relativePath, "applied")
        case .createFile:
            applyFileReplacement(action, absolute: absolute, expected: nil, summary: &summary)
        case .replaceCAS(let expected):
            applyFileReplacement(action, absolute: absolute, expected: expected, summary: &summary)
        case .createSafeLink:
            guard let target = action.linkTarget else {
                recordFailure(action.relativePath, "linkTargetMissing", summary: &summary); return
            }
            if ensureParentDirectories(action.relativePath, summary: &summary, path: action.relativePath) == false { return }
            switch WorkspaceNoFollow.kind(absolute) {
            case .missing:
                break
            case .symlink:
                summary.conflicts.append((action.relativePath, .kindChanged, nil))
                finishJournal(action.relativePath, "conflict")
                return
            default:
                recordFailure(action.relativePath, "finalElementOccupied", summary: &summary)
                return
            }
            if symlink(target, absolute) != 0 {
                recordFailure(action.relativePath, "symlink\(errno)", summary: &summary)
                return
            }
            summary.appliedLinks += 1
            finishJournal(action.relativePath, "applied")
        case .deleteFile(let expectedDigest):
            switch WorkspaceNoFollow.openRegularNoFollow(absolute) {
            case .failure:
                // Gone or not a regular file anymore: kindChanged/absent.
                if WorkspaceNoFollow.kind(absolute) == .missing {
                    summary.appliedDeletions += 1
                    finishJournal(action.relativePath, "alreadyAbsent")
                } else {
                    summary.conflicts.append((action.relativePath, .kindChanged, nil))
                    finishJournal(action.relativePath, "conflict")
                }
                return
            case .success(let fd):
                let digestOutcome = WorkspaceDigest.sha256Hex(fromFd: fd, frameBytes: budgets.frameBytes,
                                                              isCancelled: isCancelled)
                close(fd)
                guard case let .success((digest, _)) = digestOutcome else {
                    if case .failure(.cancelled) = digestOutcome {
                        summary.partialAbort = true
                        finishJournal(action.relativePath, "aborted")
                    } else {
                        recordFailure(action.relativePath, "deleteVerifyIO", summary: &summary)
                    }
                    return
                }
                guard digest == expectedDigest else {
                    // User/Core edited the bytes the runtime deleted: the
                    // current version STAYS; the runtime intent is journaled.
                    summary.conflicts.append((action.relativePath, .userEditedVsRuntimeDeleted, nil))
                    summary.keptInWorkspace += 1
                    finishJournal(action.relativePath, "conflict")
                    return
                }
                if unlink(absolute) != 0, errno != ENOENT {
                    recordFailure(action.relativePath, "unlink\(errno)", summary: &summary)
                    return
                }
                summary.appliedDeletions += 1
                finishJournal(action.relativePath, "applied")
            }
        case .deleteDirectoryRmdir:
            if rmdir(absolute) == 0 {
                summary.appliedDeletions += 1
                finishJournal(action.relativePath, "applied")
            } else {
                switch errno {
                case ENOENT:
                    summary.appliedDeletions += 1
                    finishJournal(action.relativePath, "alreadyAbsent")
                case ENOTEMPTY:
                    // New user descendants win: the directory and everything
                    // in it are preserved.
                    summary.conflicts.append((action.relativePath, .directoryNotEmptyKept, nil))
                    summary.keptInWorkspace += 1
                    finishJournal(action.relativePath, "kept")
                default:
                    recordFailure(action.relativePath, "rmdir\(errno)", summary: &summary)
                }
            }
        case .deleteSafeLink(let expectedTarget):
            guard let actual = WorkspaceNoFollow.readlink(absolute, limit: budgets.maximumLinkTargetBytes) else {
                if WorkspaceNoFollow.kind(absolute) == .missing {
                    summary.appliedDeletions += 1
                    finishJournal(action.relativePath, "alreadyAbsent")
                } else {
                    summary.conflicts.append((action.relativePath, .kindChanged, nil))
                    finishJournal(action.relativePath, "conflict")
                }
                return
            }
            guard actual == expectedTarget else {
                summary.conflicts.append((action.relativePath, .kindChanged, nil))
                summary.keptInWorkspace += 1
                finishJournal(action.relativePath, "conflict")
                return
            }
            if unlink(absolute) != 0, errno != ENOENT {
                recordFailure(action.relativePath, "unlink\(errno)", summary: &summary)
                return
            }
            summary.appliedDeletions += 1
            finishJournal(action.relativePath, "applied")
        }
    }

    private func applyFileReplacement(_ action: WorkspacePlannedAction, absolute: String,
                                      expected: String?, summary: inout WorkspaceCommitSummary) {
        guard let staged = action.sourceStagingPath else {
            recordFailure(action.relativePath, "stagedMissing", summary: &summary)
            return
        }
        if ensureParentDirectories(action.relativePath, summary: &summary, path: action.relativePath) == false { return }
        // Refuse a final element that is a symlink: replacing THROUGH/FOR a
        // link could land bytes outside the workspace. Never followed.
        switch WorkspaceNoFollow.kind(absolute) {
        case .symlink:
            let artifact = moveConflictArtifact(action)
            summary.conflicts.append((action.relativePath, .finalElementSymlink, artifact))
            finishJournal(action.relativePath, "conflict")
            return
        case .unreadable:
            recordFailure(action.relativePath, "finalElementUnreadable", summary: &summary)
            return
        default:
            break
        }
        // `verifyBeforeCommit` runs inside the ORIGINAL committer AFTER its
        // destination conflict check and BEFORE any destination change: the
        // staged bytes are re-hashed here and must equal the digest the
        // engine recorded at staging. A corrupt/changed staged payload can
        // therefore never reach the destination.
        let recorded = action.recordedDigest
        let verifyStaged: @Sendable (URL) throws -> Void = { stagedURL in
            guard let recorded else { return }
            let actual = try FloeDigest.sha256Hex(ofFileAt: stagedURL)
            guard actual == recorded.lowercased() else {
                throw FloeError.validationFailed("Staged payload digest changed before commit")
            }
        }
        let policy: FileCommitPolicy
        // FileCommitPolicy caps in Int; budgets are Int64. Keep a BOUNDED
        // ceiling on 32-bit straddlers (never `nil`, which would mean
        // unlimited) instead of trusting representability.
        let entryCap: Int = Int(exactly: budgets.maximumEntryBytes) ?? .max
        if let expected {
            policy = FileCommitPolicy(conflict: .replaceIfUnchanged(expectedSHA256: expected,
                                                                    expectedMTime: nil, mtimeTolerance: 0),
                                      maxBytes: entryCap,
                                      verifyBeforeCommit: verifyStaged,
                                      checkCancellation: { [isCancelled] in
                if isCancelled() { throw WorkspaceTransferError.cancelled }
            })
        } else {
            policy = FileCommitPolicy(conflict: .failIfExists,
                                      maxBytes: entryCap,
                                      verifyBeforeCommit: verifyStaged,
                                      checkCancellation: { [isCancelled] in
                if isCancelled() { throw WorkspaceTransferError.cancelled }
            })
        }
        do {
            let receipt = try AtomicFileCommitter.commit(stagedFile: URL(fileURLWithPath: staged),
                                                         to: URL(fileURLWithPath: absolute),
                                                         policy: policy)
            // The ORIGINAL committer recomputes the destination digest for
            // its receipt; it must equal what the engine recorded at staging
            // (the pre-replace verification already ran; this closes the
            // post-commit audit with the same evidence, not a new trust).
            if let recorded = action.recordedDigest {
                guard receipt.sha256.lowercased() == recorded.lowercased() else {
                    recordFailure(action.relativePath, "postCommitDigestMismatch", summary: &summary)
                    return
                }
            }
            if action.mode & 0o7777 != 0 {
                chmod(absolute, mode_t(action.mode & 0o7777))
            }
            if expected != nil {
                summary.appliedReplaces += 1
            } else {
                summary.appliedCreates += 1
            }
            finishJournal(action.relativePath, "applied")
        } catch let error as WorkspaceTransferError {
            if case .cancelled = error {
                summary.partialAbort = true
                finishJournal(action.relativePath, "aborted")
                return
            }
            recordFailure(action.relativePath, error.wireCode, summary: &summary)
        } catch let error as FloeError {
            if case .validationFailed(let message) = error, message.contains("Write conflict") {
                // The CAS caught a race the plan could not see: keep the
                // current bytes, preserve the runtime bytes.
                let artifact = moveConflictArtifact(action)
                summary.conflicts.append((action.relativePath, .userEditedVsRuntimeEdited, artifact))
                summary.keptInWorkspace += 1
                finishJournal(action.relativePath, "conflict")
                return
            }
            if case .validationFailed(let message) = error, message.contains("already exists") {
                let artifact = moveConflictArtifact(action)
                summary.conflicts.append((action.relativePath, .userCreatedVsRuntimeCreated, artifact))
                summary.keptInWorkspace += 1
                finishJournal(action.relativePath, "conflict")
                return
            }
            recordFailure(action.relativePath, "commitFailed", summary: &summary)
        } catch {
            recordFailure(action.relativePath, "commitFailed", summary: &summary)
        }
    }

    // MARK: - Helpers

    /// Walks the parent components with non-following checks, creating
    /// missing directories, refusing anything that is not a real directory.
    private func ensureParentDirectories(_ relative: String, summary: inout WorkspaceCommitSummary, path: String) -> Bool {
        let components = relative.split(separator: "/").dropLast()
        var prefix = workspaceRoot
        for component in components {
            prefix += "/" + component
            switch WorkspaceNoFollow.kind(prefix) {
            case .directory:
                continue
            case .missing:
                if mkdir(prefix, 0o755) != 0, errno != EEXIST {
                    recordFailure(path, "parentMkdir\(errno)", summary: &summary)
                    return false
                }
                continue
            default:
                // A symlink/file/special/unreadable component in the middle:
                // refuse; never follow, never touch.
                recordFailure(path, "parentNotDirectory", summary: &summary)
                return false
            }
        }
        return true
    }

    private func moveConflictArtifact(_ action: WorkspacePlannedAction) -> String? {
        guard let staged = action.sourceStagingPath else { return nil }
        let name = conflictArtifactName(for: action)
        let destination = conflictsDirectory + "/" + name
        if mkdir(conflictsDirectory, 0o700) != 0, errno != EEXIST {
            // Conflicts directory unavailable: the staged file stays in
            // place (recoverable), the outcome still says "preserved".
            return nil
        }
        if rename(staged, destination) != 0 {
            if errno == EXDEV {
                // Cross-device fallback (should not occur: same app storage):
                // copy then keep the staged original if the copy failed.
                try? FileManager.default.copyItem(atPath: staged, toPath: destination)
                return FileManager.default.fileExists(atPath: destination) ? name : nil
            }
            return nil
        }
        _ = WorkspaceNoFollow.fsyncDirectory(conflictsDirectory)
        return name
    }

    private func conflictArtifactName(for action: WorkspacePlannedAction) -> String {
        let base = (action.relativePath as NSString).lastPathComponent
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        var safe = String(String.UnicodeScalarView(base.unicodeScalars.map {
            allowed.contains($0) ? $0 : UnicodeScalar("_")
        }))
        if safe.isEmpty { safe = "file" }
        if safe.utf8.count > 64 { safe = String(safe.prefix(64)) }
        return "\(action.relativePath.floeStableHash.prefix(12))-\(safe)"
    }

    private func describe(_ effect: WorkspacePlannedAction.Effect) -> String {
        switch effect {
        case .createFile: return "createFile"
        case .replaceCAS: return "replaceCAS"
        case .createEmptyDirectory: return "createDirectory"
        case .deleteFile: return "deleteFile"
        case .deleteDirectoryRmdir: return "rmdir"
        case .createSafeLink: return "createLink"
        case .deleteSafeLink: return "deleteLink"
        }
    }

    private func finishJournal(_ path: String, _ state: String) {
        try? journal.append(["record": "effect", "path": path, "state": state])
    }

    private func recordFailure(_ path: String, _ code: String, summary: inout WorkspaceCommitSummary) {
        summary.failedEffects.append((path: path, code: String(code.prefix(48))))
        try? journal.append(["record": "effectFailed", "path": path, "code": code])
    }

    private func recordConflictOnly(actions: [WorkspacePlannedAction], summary: inout WorkspaceCommitSummary) {
        for action in actions where action.conflict != nil {
            let artifact = moveConflictArtifact(action)
            summary.conflicts.append((action.relativePath, action.conflict ?? .refusedEntry, artifact))
        }
    }
}

extension String {
    /// Stable short identity hash for artifact naming (path is the caller's
    /// own relative data; the hash only de-duplicates names deterministically).
    fileprivate var floeStableHash: String {
        FloeDigest.sha256Hex(Data(utf8))
    }
}
