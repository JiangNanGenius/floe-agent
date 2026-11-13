// FloeCore — crash recovery for one journaled sparse rewrite.
//
// Recovery is intentionally conservative:
//   * Every action first observes the exact source and stage path identities.
//   * The recorded source (S) and stage (T) inodes decide the state; filenames
//     and phase labels alone never authorize a delete.
//   * Any unknown identity combination preserves both paths and returns
//     `needsInspection` without touching either.
//   * A pre-swap stage is removed only when the source path still matches S
//     and the stage path still matches the recorded T.
//   * A post-swap state is committed only after the original path matches T's
//     stable identity, logical length, complete SHA-512 and metadata
//     fingerprint. Otherwise the original S is restored only when both path
//     identities still prove the exact S/T pair.
//
// Recovery may be called repeatedly; once the journal says `retired` and the
// source path matches T with no stage, it returns `alreadyCommitted`.

#if canImport(Darwin)
import Foundation
import Darwin

enum StorageSparseDiskRewriteRecovery {
    enum PersistencePoint: String, Sendable {
        case abortWithoutStage, abortStage, committed, committedStageAbsent
        case retired, rollbackIntent, rollbackSwap, rollbackComplete
    }

    struct TestHooks: Sendable {
        var beforeDirectorySync: (@Sendable (PersistencePoint) throws -> Void)?
        var beforeJournalUpdate: (@Sendable (PersistencePoint) throws -> Void)?
    }

    static func recover(
        rootURL: URL,
        relativePath: String,
        journalDirectoryURL: URL,
        jobID: String,
        fence: StorageSparseDiskMaintenanceFence,
        recordedRootBinding: StorageSparseDiskRecoveryRootBinding? = nil,
        isCancelled: @escaping @Sendable () -> Bool,
        hooks: TestHooks = TestHooks()
    ) throws -> StorageSparseDiskRecoveryReport {
        try StorageSparseDiskPOSIX.validateJobID(jobID)
        let components = try StorageSparseDiskPOSIX.validateRelativePath(relativePath)
        let rootPath = rootURL.standardizedFileURL.resolvingSymlinksInPath().path

        let rootFD: Int32
        do {
            rootFD = try StorageSparseDiskPOSIX.openDirectory(rootURL)
        } catch {
            if case StorageSparseDiskRewriteError.directoryOpenFailed(let code) = error, code == ENOENT {
                return noJournal(jobID: jobID)
            }
            throw error
        }
        defer { _ = Darwin.close(rootFD) }
        let resolved = try StorageSparseDiskPOSIX.openParent(
            rootFD: rootFD,
            relativePath: relativePath
        )
        defer {
            if resolved.ownsDirectory { _ = Darwin.close(resolved.directoryFD) }
        }
        let parentFD = resolved.directoryFD
        let parentIdentity = try StorageSparseDiskPOSIX.identity(of: parentFD)

        let journal: StorageSparseDiskRewriteJournalHandle
        do {
            journal = try StorageSparseDiskRewriteJournalHandle(
                directoryURL: journalDirectoryURL,
                jobID: jobID
            )
        } catch {
            if case StorageSparseDiskRewriteError.directoryOpenFailed(let code) = error, code == ENOENT {
                return noJournal(jobID: jobID)
            }
            if case StorageSparseDiskRewriteError.journalOpenFailed(let code) = error, code == ENOENT {
                return noJournal(jobID: jobID)
            }
            throw error
        }
        defer { journal.close() }

        guard var record = try journal.read() else {
            return noJournal(jobID: jobID)
        }
        guard record.schemaVersion == 2,
              record.jobID == jobID,
              record.relativePath == relativePath
        else {
            throw StorageSparseDiskRewriteError.journalConflict("record")
        }
        if let binding = recordedRootBinding {
            // Old schema2 has no root inode. Only the owning native adapter's
            // durable closure/intent pair may supply it; never infer from UUID.
            guard binding.recordedRootPath == record.rootPath,
                  binding.recordedRootPath.hasPrefix("/"), binding.recordedRootPath.utf8.count <= 4_096,
                  !binding.recordedRootPath.utf8.contains(0),
                  !binding.recordedRootPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
                  binding.device != 0, binding.inode != 0 else {
                throw StorageSparseDiskRewriteError.journalConflict("root-binding")
            }
            let openedRoot = try StorageSparseDiskPOSIX.identity(of: rootFD)
            guard openedRoot.mode & UInt32(S_IFMT) == UInt32(S_IFDIR),
                  openedRoot.device == binding.device, openedRoot.inode == binding.inode else {
                throw StorageSparseDiskRewriteError.journalConflict("root-identity")
            }
        } else if record.rootPath != rootPath {
            throw StorageSparseDiskRewriteError.journalConflict("record-root")
        }
        guard parentIdentity.device == record.parentDevice,
              parentIdentity.inode == record.parentInode
        else {
            throw StorageSparseDiskRewriteError.journalConflict("parent")
        }
        guard record.requestedMode != .sparseCopy,
              record.stage == nil || record.modeUsed == .cloneAndPunch else {
            throw StorageSparseDiskRewriteError.journalConflict("unsupported-rewrite-mode")
        }
        if let stageName = record.stageName {
            try StorageSparseDiskPOSIX.validateSingleName(stageName, field: "stage-name")
        }
        guard components.last == resolved.leaf else {
            throw StorageSparseDiskRewriteError.journalConflict("leaf")
        }

        try fence.assertExclusive()
        try checkCancelled(isCancelled)

        let sourceObservation = StorageSparseDiskPOSIX.observe(
            parentFD: parentFD,
            name: resolved.leaf
        )
        let stageObservation: StorageSparseDiskPathObservation
        if let stageName = record.stageName {
            stageObservation = StorageSparseDiskPOSIX.observe(parentFD: parentFD, name: stageName)
        } else {
            stageObservation = StorageSparseDiskPathObservation(
                exists: false,
                identity: nil,
                isSymlink: false,
                errorErrno: nil
            )
        }

        if sourceObservation.errorErrno != nil || stageObservation.errorErrno != nil {
            return needsInspection(
                jobID: jobID,
                record: record,
                journal: journal,
                detail: "path-observation"
            )
        }
        if sourceObservation.isSymlink || stageObservation.isSymlink {
            return needsInspection(
                jobID: jobID,
                record: record,
                journal: journal,
                detail: "path-symlink"
            )
        }

        let sourceIsS = matches(sourceObservation.identity, record.source)
        let sourceIsT = matches(sourceObservation.identity, record.stage)
        let stageIsS = matches(stageObservation.identity, record.source)
        let stageIsJobInode = matchesInode(stageObservation.identity, record.stage)
        let preSwapPhases: Set<StorageSparseDiskRewritePhase> = [
            .intent, .counting, .staging, .verified, .swapIntent, .rollbackIntent, .aborted, .failed,
        ]

        // Source still untouched.
        if sourceIsS && !stageObservation.exists {
            if preSwapPhases.contains(record.phase) {
                let wasRollback = record.phase == .rollbackIntent
                record.phase = .aborted
                record.resolution = wasRollback ? "rolled-back-after-interruption" : "source-unchanged"
                record.lastError = nil
                try finishResolution(
                    parentFD: parentFD, record: record, journal: journal,
                    hooks: hooks, point: .abortWithoutStage
                )
                return StorageSparseDiskRecoveryReport(
                    jobID: jobID,
                    resolution: wasRollback ? .rolledBack : .abortedBeforeSwap,
                    phase: record.phase.rawValue,
                    stageRemoved: false,
                    sourceIdentityVerified: true,
                    detail: "source-unchanged"
                )
            }
            return needsInspection(
                jobID: jobID,
                record: record,
                journal: journal,
                detail: "source-unchanged-after-swap-phase"
            )
        }

        if sourceIsS && stageObservation.exists {
            // Before the swap the source inode is still the original. The
            // stage has legitimately changing mtime/size while it is being
            // written or punched, so only its exact inode binding is used to
            // prove it is this job's redundant copy.
            guard stageIsJobInode, let stageName = record.stageName else {
                return needsInspection(
                    jobID: jobID,
                    record: record,
                    journal: journal,
                    detail: "unknown-stage"
                )
            }
            guard preSwapPhases.contains(record.phase) else {
                return needsInspection(
                    jobID: jobID,
                    record: record,
                    journal: journal,
                    detail: "source-stage-after-swap-phase"
                )
            }
            try fence.assertExclusive()
            let unlinkResult = StorageSparseDiskPOSIX.unlinkName(
                directoryFD: parentFD,
                name: stageName
            )
            guard unlinkResult == 0 || errno == ENOENT else {
                return needsInspection(
                    jobID: jobID,
                    record: record,
                    journal: journal,
                    detail: "pre-swap-unlink"
                )
            }
            let wasRollback = record.phase == .rollbackIntent
            record.phase = .aborted
            record.resolution = wasRollback ? "rolled-back-after-interruption" : "aborted-before-swap"
            record.lastError = nil
            try finishResolution(
                parentFD: parentFD, record: record, journal: journal,
                hooks: hooks, point: .abortStage
            )
            return StorageSparseDiskRecoveryReport(
                jobID: jobID,
                resolution: wasRollback ? .rolledBack : .abortedBeforeSwap,
                phase: record.phase.rawValue,
                stageRemoved: true,
                sourceIdentityVerified: true,
                detail: "aborted-before-swap"
            )
        }

        // Swap observed: source path is T, stage path is S.
        if sourceIsT && stageIsS {
            guard record.phase != .aborted, record.phase != .failed else {
                return needsInspection(
                    jobID: jobID,
                    record: record,
                    journal: journal,
                    detail: "swapped-after-abort-phase"
                )
            }
            guard let stageName = record.stageName else {
                return needsInspection(
                    jobID: jobID,
                    record: record,
                    journal: journal,
                    detail: "swapped-without-stage-name"
                )
            }
            if record.phase == .rollbackIntent {
                return try rollback(
                    parentFD: parentFD, sourceName: resolved.leaf,
                    stageName: stageName, record: &record, journal: journal,
                    fence: fence, hooks: hooks
                )
            }
            let committedFD = try openOriginal(
                parentFD: parentFD,
                leaf: resolved.leaf,
                purpose: .source
            )
            defer { _ = Darwin.close(committedFD) }
            let committedIdentity = try StorageSparseDiskPOSIX.identity(of: committedFD)
            guard let recordedStage = record.stage,
                  committedIdentity.matchesStable(recordedStage)
            else {
                return needsInspection(
                    jobID: jobID,
                    record: record,
                    journal: journal,
                    detail: "committed-identity"
                )
            }
            let verified = try verifyCommitted(
                fd: committedFD,
                record: record,
                isCancelled: isCancelled
            )
            if verified {
                if record.phase != .committed && record.phase != .retired {
                    record.phase = .committed
                    record.postSwapSource = committedIdentity
                    record.resolution = "recovered-commit"
                    try finishResolution(
                        parentFD: parentFD, record: record, journal: journal,
                        hooks: hooks, point: .committed
                    )
                }
                let retired = try retireStage(
                    parentFD: parentFD,
                    stageName: stageName,
                    record: &record,
                    journal: journal,
                    sourceIdentity: committedIdentity,
                    fence: fence,
                    hooks: hooks
                )
                guard retired else {
                    return needsInspection(
                        jobID: jobID, record: record, journal: journal,
                        detail: "committed-stage-retained"
                    )
                }
                return StorageSparseDiskRecoveryReport(
                    jobID: jobID,
                    resolution: record.phase == .retired ? .alreadyCommitted : .committed,
                    phase: record.phase.rawValue,
                    stageRemoved: retired,
                    sourceIdentityVerified: true,
                    detail: retired ? "committed" : "committed-stage-retained"
                )
            }
            // Only pre-commit phases may roll back. A durable committed/retired
            // record is never reversed by recovery.
            guard record.phase != .committed, record.phase != .retired else {
                return needsInspection(
                    jobID: jobID,
                    record: record,
                    journal: journal,
                    detail: "committed-verification-failed"
                )
            }
            return try rollback(
                parentFD: parentFD,
                sourceName: resolved.leaf,
                stageName: stageName,
                record: &record,
                journal: journal,
                fence: fence,
                hooks: hooks
            )
        }

        // Source path is T and the old stage is gone.
        if sourceIsT && !stageObservation.exists {
            guard record.phase == .swapped
                || record.phase == .committed
                || record.phase == .retired
                || record.phase == .swapIntent
                || record.phase == .verified
            else {
                return needsInspection(
                    jobID: jobID,
                    record: record,
                    journal: journal,
                    detail: "committed-without-stage-phase"
                )
            }
            let committedFD = try openOriginal(
                parentFD: parentFD,
                leaf: resolved.leaf,
                purpose: .source
            )
            defer { _ = Darwin.close(committedFD) }
            guard let expectedStage = record.stage else {
                return needsInspection(
                    jobID: jobID,
                    record: record,
                    journal: journal,
                    detail: "committed-without-stage-identity"
                )
            }
            let identity = try StorageSparseDiskPOSIX.identity(of: committedFD)
            guard identity.matchesStable(expectedStage) else {
                return needsInspection(
                    jobID: jobID,
                    record: record,
                    journal: journal,
                    detail: "committed-missing-stage-identity"
                )
            }
            guard try verifyCommitted(fd: committedFD, record: record, isCancelled: isCancelled) else {
                return needsInspection(
                    jobID: jobID,
                    record: record,
                    journal: journal,
                    detail: "committed-missing-stage-digest"
                )
            }
            let alreadyRetired = record.phase == .retired
            record.phase = .retired
            record.stageRetired = true
            record.resolution = "recovered-commit"
            try finishResolution(
                parentFD: parentFD, record: record, journal: journal,
                hooks: hooks, point: .committedStageAbsent
            )
            return StorageSparseDiskRecoveryReport(
                jobID: jobID,
                resolution: alreadyRetired ? .alreadyCommitted : .committed,
                phase: record.phase.rawValue,
                stageRemoved: false,
                sourceIdentityVerified: true,
                detail: alreadyRetired ? "already-committed" : "committed-stage-missing"
            )
        }

        return needsInspection(
            jobID: jobID,
            record: record,
            journal: journal,
            detail: "unknown-combination"
        )
    }

    // MARK: - Helpers

    private static func matches(
        _ identity: StorageSparseDiskIdentity?,
        _ expected: StorageSparseDiskIdentity?
    ) -> Bool {
        guard let identity, let expected else { return false }
        return identity.matchesStable(expected)
    }

    private static func matchesInode(
        _ identity: StorageSparseDiskIdentity?,
        _ expected: StorageSparseDiskIdentity?
    ) -> Bool {
        guard let identity, let expected else { return false }
        return identity.matchesInode(expected)
    }

    private static func checkCancelled(_ isCancelled: @escaping @Sendable () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
    }

    private static func openOriginal(
        parentFD: Int32,
        leaf: String,
        purpose: StorageSparseDiskOpenPurpose
    ) throws -> Int32 {
        try StorageSparseDiskPOSIX.openRegular(
            parentFD: parentFD,
            leaf: leaf,
            flags: O_RDONLY,
            purpose: purpose
        )
    }

    private static func verifyCommitted(
        fd: Int32,
        record: StorageSparseDiskRewriteJournalRecord,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> Bool {
        guard record.logicalBytes > 0,
              let expectedDigest = record.sourceDigestSHA512,
              let expectedFingerprint = record.metadataFingerprint
        else { return false }
        let identity = try StorageSparseDiskPOSIX.identity(of: fd)
        guard identity.sizeBytes == record.logicalBytes else { return false }
        let digest = try StorageSparseDiskPOSIX.sha512(
            fd: fd,
            size: record.logicalBytes,
            chunkBytes: 1_048_576,
            phase: .committing,
            isSource: false,
            isCancelled: isCancelled,
            progress: nil
        )
        guard digest == expectedDigest else { return false }
        let metadata = try StorageSparseDiskPOSIX.captureMetadata(fd: fd)
        let fingerprint = try StorageSparseDiskPOSIX.metadataFingerprint(metadata)
        return fingerprint == expectedFingerprint
    }

    private static func retireStage(
        parentFD: Int32,
        stageName: String,
        record: inout StorageSparseDiskRewriteJournalRecord,
        journal: StorageSparseDiskRewriteJournalHandle,
        sourceIdentity: StorageSparseDiskIdentity,
        fence: StorageSparseDiskMaintenanceFence,
        hooks: TestHooks
    ) throws -> Bool {
        let observation = StorageSparseDiskPOSIX.observe(parentFD: parentFD, name: stageName)
        if !observation.exists {
            record.stageRetired = true
            record.phase = .retired
            record.resolution = "stage-already-absent"
            try finishResolution(
                parentFD: parentFD, record: record, journal: journal,
                hooks: hooks, point: .retired
            )
            return true
        }
        guard let actual = observation.identity,
              actual.matchesStable(record.source),
              actual.inode != sourceIdentity.inode
        else {
            return false
        }
        try fence.assertExclusive()
        let unlinkResult = StorageSparseDiskPOSIX.unlinkName(
            directoryFD: parentFD,
            name: stageName
        )
        guard unlinkResult == 0 || errno == ENOENT else { return false }
        record.stageRetired = true
        record.phase = .retired
        record.resolution = "retired"
        try finishResolution(
            parentFD: parentFD, record: record, journal: journal,
            hooks: hooks, point: .retired
        )
        return true
    }

    private static func rollback(
        parentFD: Int32,
        sourceName: String,
        stageName: String,
        record: inout StorageSparseDiskRewriteJournalRecord,
        journal: StorageSparseDiskRewriteJournalHandle,
        fence: StorageSparseDiskMaintenanceFence,
        hooks: TestHooks
    ) throws -> StorageSparseDiskRecoveryReport {
        let sourceObservation = StorageSparseDiskPOSIX.observe(parentFD: parentFD, name: sourceName)
        let stageObservation = StorageSparseDiskPOSIX.observe(parentFD: parentFD, name: stageName)
        let recordedSource = record.source
        guard let sourceIdentity = sourceObservation.identity,
              let stageIdentity = stageObservation.identity,
              let recordedStage = record.stage,
              sourceIdentity.matchesStable(recordedStage),
              stageIdentity.matchesStable(recordedSource)
        else {
            return needsInspection(
                jobID: record.jobID,
                record: record,
                journal: journal,
                detail: "rollback-observation"
            )
        }
        try fence.assertExclusive()
        record.phase = .rollbackIntent
        try persistRecord(record, journal: journal, hooks: hooks, point: .rollbackIntent)
        let swapResult = StorageSparseDiskPOSIX.renameSwap(
            directoryFD: parentFD,
            firstName: stageName,
            secondName: sourceName
        )
        guard swapResult == 0 else {
            return needsInspection(
                jobID: record.jobID,
                record: record,
                journal: journal,
                detail: "rollback-swap"
            )
        }
        do {
            try syncDirectory(
                parentFD, record: record, hooks: hooks, point: .rollbackSwap
            )
            let restored = StorageSparseDiskPOSIX.observe(parentFD: parentFD, name: sourceName)
            guard restored.identity?.matchesStable(recordedSource) == true else {
                return needsInspection(
                    jobID: record.jobID,
                    record: record,
                    journal: journal,
                    detail: "rollback-restore"
                )
            }
            let restoredStage = StorageSparseDiskPOSIX.observe(parentFD: parentFD, name: stageName)
            let stageRemoved = true
            if restoredStage.exists {
                guard let actual = restoredStage.identity,
                      actual.matchesStable(recordedStage)
                else {
                    return needsInspection(
                        jobID: record.jobID,
                        record: record,
                        journal: journal,
                        detail: "rollback-stage"
                    )
                }
                let unlinkResult = StorageSparseDiskPOSIX.unlinkName(
                    directoryFD: parentFD,
                    name: stageName
                )
                guard unlinkResult == 0 || errno == ENOENT else {
                    throw StorageSparseDiskRewriteError.recoveryRequired(
                        jobID: record.jobID, phase: "rollback-unlink"
                    )
                }
            }
            record.phase = .aborted
            record.resolution = "rolled-back-by-recovery"
            record.lastError = "verification-failed"
            try finishResolution(
                parentFD: parentFD, record: record, journal: journal,
                hooks: hooks, point: .rollbackComplete
            )
            return StorageSparseDiskRecoveryReport(
                jobID: record.jobID,
                resolution: .rolledBack,
                phase: record.phase.rawValue,
                stageRemoved: stageRemoved,
                sourceIdentityVerified: true,
                detail: stageRemoved ? "rolled-back" : "rolled-back-stage-retained"
            )
        } catch let error as StorageSparseDiskRewriteError {
            if case .recoveryRequired = error { throw error }
            return needsInspection(
                jobID: record.jobID,
                record: record,
                journal: journal,
                detail: "rollback-error"
            )
        } catch {
            throw StorageSparseDiskRewriteError.recoveryRequired(
                jobID: record.jobID, phase: "rollback-error"
            )
        }
    }

    private static func syncDirectory(
        _ parentFD: Int32,
        record: StorageSparseDiskRewriteJournalRecord,
        hooks: TestHooks,
        point: PersistencePoint
    ) throws {
        do {
            try hooks.beforeDirectorySync?(point)
            try StorageSparseDiskPOSIX.fsyncDirectory(parentFD)
        } catch {
            throw StorageSparseDiskRewriteError.recoveryRequired(
                jobID: record.jobID, phase: "recovery-sync-" + point.rawValue
            )
        }
    }

    private static func persistRecord(
        _ record: StorageSparseDiskRewriteJournalRecord,
        journal: StorageSparseDiskRewriteJournalHandle,
        hooks: TestHooks,
        point: PersistencePoint
    ) throws {
        do {
            try hooks.beforeJournalUpdate?(point)
            try journal.update(record)
        } catch {
            throw StorageSparseDiskRewriteError.recoveryRequired(
                jobID: record.jobID, phase: "recovery-journal-" + point.rawValue
            )
        }
    }

    private static func finishResolution(
        parentFD: Int32,
        record: StorageSparseDiskRewriteJournalRecord,
        journal: StorageSparseDiskRewriteJournalHandle,
        hooks: TestHooks,
        point: PersistencePoint
    ) throws {
        try syncDirectory(parentFD, record: record, hooks: hooks, point: point)
        try persistRecord(record, journal: journal, hooks: hooks, point: point)
    }

    private static func needsInspection(
        jobID: String,
        record: StorageSparseDiskRewriteJournalRecord,
        journal: StorageSparseDiskRewriteJournalHandle,
        detail: String
    ) -> StorageSparseDiskRecoveryReport {
        var updated = record
        updated.resolution = "needs-inspection:" + detail
        updated.lastError = detail
        try? journal.update(updated)
        return StorageSparseDiskRecoveryReport(
            jobID: jobID,
            resolution: .needsInspection,
            phase: updated.phase.rawValue,
            stageRemoved: false,
            sourceIdentityVerified: false,
            detail: detail
        )
    }

    private static func noJournal(jobID: String) -> StorageSparseDiskRecoveryReport {
        StorageSparseDiskRecoveryReport(
            jobID: jobID,
            resolution: .noJournal,
            phase: "none",
            stageRemoved: false,
            sourceIdentityVerified: false,
            detail: "no-journal"
        )
    }
}

#endif
