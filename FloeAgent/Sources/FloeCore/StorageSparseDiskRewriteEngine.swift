// FloeCore — orchestration for one bounded sparse rewrite.
//
// The source inode is opened once and held for the whole job. Every phase
// rechecks that the exact identity did not change. The stage is always a
// sibling in the same directory, so a same-volume RENAME_SWAP is the only
// commit primitive; a filesystem that cannot perform it fails closed without
// touching the source bytes.
//
// No failure path deletes a path merely because its name looks job-related.
// Stage cleanup first proves the observed device/inode equals the recorded
// stage identity. After the swap, the old source is retired only after the
// original path has been re-opened and its complete logical byte stream and
// metadata fingerprint have been verified against the pre-swap journal.

#if canImport(Darwin)
import Foundation
import Darwin

enum StorageSparseDiskRewriteEngine {
    static func perform(
        _ request: StorageSparseDiskRewriteRequest,
        fence: StorageSparseDiskMaintenanceFence,
        hooks: StorageSparseDiskRewrite.TestHooks,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: (@Sendable (StorageSparseDiskRewriteProgress) -> Void)?
    ) throws -> StorageSparseDiskRewriteReport {
        try validateRequest(request)
        let rootPath = request.rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let jobID = request.jobID

        let rootFD = try StorageSparseDiskPOSIX.openDirectory(request.rootURL)
        defer { _ = Darwin.close(rootFD) }
        let resolved = try StorageSparseDiskPOSIX.openParent(
            rootFD: rootFD,
            relativePath: request.relativePath
        )
        defer {
            if resolved.ownsDirectory { _ = Darwin.close(resolved.directoryFD) }
        }
        let parentFD = resolved.directoryFD

        let sourceFD = try StorageSparseDiskPOSIX.openRegular(
            parentFD: parentFD,
            leaf: resolved.leaf,
            flags: O_RDONLY,
            purpose: .source
        )
        var sourceFDClosed = false
        defer {
            if !sourceFDClosed { _ = Darwin.close(sourceFD) }
        }

        let initial = try StorageSparseDiskPOSIX.identity(of: sourceFD)
        try StorageSparseDiskPOSIX.validateSourceShape(initial)
        try StorageSparseDiskPOSIX.requireExpectedIdentity(
            initial,
            expected: request.expectedSource,
            phase: "admission"
        )
        let parentIdentity = try StorageSparseDiskPOSIX.identity(of: parentFD)
        let metadata = try StorageSparseDiskPOSIX.captureMetadata(
            fd: sourceFD, metadataReadFault: hooks.metadataReadFault
        )
        let sourceAllocatedBefore = try StorageSparseDiskPOSIX.allocatedBytes(of: sourceFD)
        let volumeBefore = try StorageSparseDiskPOSIX.volumeSpace(
            directoryFD: parentFD,
            availableOverride: hooks.availableBytesOverride
        )
        let stageName = try StorageSparseDiskPOSIX.makeStageName(
            sourceLeaf: resolved.leaf,
            jobID: jobID
        )

        let journal = try StorageSparseDiskRewriteJournalHandle(
            directoryURL: request.journalDirectoryURL,
            jobID: jobID
        )
        defer { journal.close() }
        if try journal.read() != nil {
            throw StorageSparseDiskRewriteError.journalExists(jobID)
        }

        var record = StorageSparseDiskRewriteJournalRecord(
            jobID: jobID,
            maintenanceLeaseID: request.maintenanceLeaseID,
            holdGeneration: request.holdGeneration,
            jobGeneration: request.jobGeneration,
            rootPath: rootPath,
            relativePath: request.relativePath,
            parentDevice: parentIdentity.device,
            parentInode: parentIdentity.inode,
            source: initial,
            stageName: stageName,
            logicalBytes: initial.sizeBytes,
            requestedMode: request.mode,
            protectionClass: metadata.protectionClass,
            skippedXattrNames: metadata.skippedXattrNames,
            nowMilliseconds: StorageSparseDiskJournalCoding.nowMilliseconds()
        )
        try journal.create(record)

        var stageFD: Int32?
        var stageIdentity: StorageSparseDiskIdentity?
        let modeUsed: StorageSparseDiskRewriteMode = .cloneAndPunch
        let fallbackReason: String? = nil
        var punchedBytes: Int64 = 0
        var didSwap = false
        var didResolveSwapFailure = false
        var counting: StorageSparseDiskCountingResult?

        defer {
            if let stageFD { _ = Darwin.close(stageFD) }
        }

        do {
            try fence.assertExclusive()
            try checkCancelled(isCancelled)
            try crash(.afterIntent, hooks: hooks)

            let counted = try StorageSparseDiskPOSIX.countSource(
                fd: sourceFD,
                size: initial.sizeBytes,
                chunkBytes: request.chunkBytes,
                probeBytes: request.zeroProbeBytes,
                isCancelled: isCancelled,
                progress: progress
            )
            counting = counted
            try StorageSparseDiskPOSIX.requireSourceUnchanged(
                fd: sourceFD,
                expected: initial,
                phase: "counting"
            )
            record.phase = .counting
            record.sourceDigestSHA512 = counted.digestSHA512
            record.nonzeroBytes = counted.nonzeroBytes
            record.zeroBytes = counted.zeroBytes
            record.sourceAllocatedBytesBefore = sourceAllocatedBefore
            record.volumeAvailableBytesBefore = volumeBefore.availableBytes
            try journal.update(record)
            hooks.afterCounting?()
            try crash(.afterCounting, hooks: hooks)
            try fence.assertExclusive()
            try checkCancelled(isCancelled)
            // Do not clone or write from a source that changed while the
            // count checkpoint/journal update was being written.
            try StorageSparseDiskPOSIX.requireSourceUnchanged(
                fd: sourceFD,
                expected: initial,
                phase: "after-counting"
            )

            // This release supports only a metadata-verified APFS clone.
            // Historical fallback=true can never turn a failed primitive into copy.
            if hooks.forceCloneFailure {
                throw StorageSparseDiskRewriteError.cloneUnavailable(errno: ENOTSUP)
            }
            try StorageSparseDiskPOSIX.preflightSpace(
                directoryFD: parentFD,
                requiredBytes: request.safetyMarginBytes,
                hooksOverride: hooks.availableBytesOverride,
                phase: "clone-precheck"
            )
            let cloneResult = StorageSparseDiskPOSIX.cloneFile(
                sourceFD: sourceFD, directoryFD: parentFD, name: stageName
            )
            guard cloneResult == 0 else {
                throw StorageSparseDiskRewriteError.cloneUnavailable(errno: errno)
            }
            let observed = StorageSparseDiskPOSIX.observe(parentFD: parentFD, name: stageName)
            stageIdentity = observed.identity
            let fd = try StorageSparseDiskPOSIX.openStageForRewrite(
                parentFD: parentFD, name: stageName
            )
            stageFD = fd
            let clonedIdentity = try StorageSparseDiskPOSIX.identity(of: fd)
            guard let observedIdentity = observed.identity,
                  observedIdentity.matchesInode(clonedIdentity) else {
                throw StorageSparseDiskRewriteError.stageIdentityMismatch(phase: "clone-open")
            }
            try StorageSparseDiskPOSIX.validateStageInitial(clonedIdentity, source: initial)
            stageIdentity = clonedIdentity
            stageFD = fd

            record.stage = stageIdentity
            record.modeUsed = modeUsed
            record.fallbackReason = fallbackReason
            record.phase = .staging
            try journal.update(record)
            try crash(.afterStageCreated, hooks: hooks)
            try fence.assertExclusive()
            try checkCancelled(isCancelled)
            try StorageSparseDiskPOSIX.requireSourceUnchanged(
                fd: sourceFD,
                expected: initial,
                phase: "staging-start"
            )

            guard let activeStageFD = stageFD else {
                throw StorageSparseDiskRewriteError.stageIdentityMismatch(phase: "staging-open")
            }

            try StorageSparseDiskPOSIX.preflightSpace(
                directoryFD: parentFD,
                requiredBytes: request.safetyMarginBytes,
                hooksOverride: hooks.availableBytesOverride,
                phase: "punch-precheck"
            )
            let punch = try StorageSparseDiskPOSIX.punchZeroRuns(
                sourceFD: sourceFD,
                stageFD: activeStageFD,
                size: initial.sizeBytes,
                chunkBytes: request.chunkBytes,
                probeBytes: request.zeroProbeBytes,
                directoryFD: parentFD,
                hooks: hooks,
                isCancelled: isCancelled,
                progress: progress
            )
            if let unsupported = punch.unsupportedErrno {
                throw StorageSparseDiskRewriteError.punchUnsupported(errno: unsupported)
            }
            punchedBytes = punch.punchedBytes

            try StorageSparseDiskPOSIX.requireSourceUnchanged(
                fd: sourceFD,
                expected: initial,
                phase: "staging"
            )
            try crash(.afterStaging, hooks: hooks)

            guard let verifiedStageFD = stageFD else {
                throw StorageSparseDiskRewriteError.stageIdentityMismatch(phase: "verify-open")
            }
            try StorageSparseDiskPOSIX.truncate(fd: verifiedStageFD, size: initial.sizeBytes)
            try StorageSparseDiskPOSIX.applyMetadata(
                sourceFD: sourceFD,
                stageFD: verifiedStageFD,
                snapshot: metadata
            )
            try StorageSparseDiskPOSIX.fsyncFD(verifiedStageFD)

            let stageVerifiedIdentity = try StorageSparseDiskPOSIX.identity(of: verifiedStageFD)
            stageIdentity = stageVerifiedIdentity
            guard stageVerifiedIdentity.sizeBytes == initial.sizeBytes,
                  stageVerifiedIdentity.linkCount == 1,
                  stageVerifiedIdentity.device == initial.device
            else {
                throw StorageSparseDiskRewriteError.stageIdentityMismatch(phase: "verified-shape")
            }
            let sourceDigest = record.sourceDigestSHA512 ?? counting?.digestSHA512 ?? ""
            guard !sourceDigest.isEmpty else {
                throw StorageSparseDiskRewriteError.invalidRequest("digest")
            }
            let stageDigest = try StorageSparseDiskPOSIX.sha512(
                fd: verifiedStageFD,
                size: initial.sizeBytes,
                chunkBytes: request.chunkBytes,
                phase: .verifying,
                isSource: false,
                isCancelled: isCancelled,
                progress: progress
            )
            guard stageDigest == sourceDigest else {
                throw StorageSparseDiskRewriteError.verificationFailed(phase: "stage-digest")
            }
            let stageMetadata = try StorageSparseDiskPOSIX.captureMetadata(fd: verifiedStageFD)
            let expectedFingerprint = try StorageSparseDiskPOSIX.metadataFingerprint(metadata)
            let actualFingerprint = try StorageSparseDiskPOSIX.metadataFingerprint(stageMetadata)
            guard actualFingerprint == expectedFingerprint else {
                throw StorageSparseDiskRewriteError.metadataVerificationFailed(field: "stage")
            }
            let stageAllocated = try StorageSparseDiskPOSIX.allocatedBytes(of: verifiedStageFD)
            let volumeAtCommit = try StorageSparseDiskPOSIX.volumeSpace(
                directoryFD: parentFD,
                availableOverride: hooks.availableBytesOverride
            )
            record.phase = .verified
            record.stage = stageVerifiedIdentity
            record.stageDigestSHA512 = stageDigest
            record.metadataFingerprint = expectedFingerprint
            record.protectionClass = metadata.protectionClass
            record.skippedXattrNames = metadata.skippedXattrNames
            record.punchedBytes = punchedBytes
            record.stageAllocatedBytesAtVerification = stageAllocated
            record.volumeAvailableBytesAtCommit = volumeAtCommit.availableBytes
            try journal.update(record)
            try crash(.afterVerified, hooks: hooks)

            try requirePositiveGain(
                sourceAllocated: sourceAllocatedBefore,
                stageAllocated: stageAllocated,
                minimumReclaimBytes: request.minimumReclaimBytes
            )

            try fence.assertExclusive()
            try checkCancelled(isCancelled)
            try StorageSparseDiskPOSIX.requireSourceUnchanged(
                fd: sourceFD,
                expected: initial,
                phase: "swapIntent"
            )
            try StorageSparseDiskPOSIX.requireStageUnchanged(
                fd: verifiedStageFD,
                expected: stageVerifiedIdentity,
                phase: "swapIntent"
            )
            let sourceObservation = StorageSparseDiskPOSIX.observe(
                parentFD: parentFD,
                name: resolved.leaf
            )
            let stageObservation = StorageSparseDiskPOSIX.observe(
                parentFD: parentFD,
                name: stageName
            )
            guard sourceObservation.identity?.matchesStable(initial) == true,
                  stageObservation.identity?.matchesStable(stageVerifiedIdentity) == true
            else {
                throw StorageSparseDiskRewriteError.sourceChanged(phase: "swap-admission")
            }
            record.phase = .swapIntent
            try journal.update(record)
            try crash(.afterSwapIntent, hooks: hooks)
            if hooks.forceSwapUnsupported {
                throw StorageSparseDiskRewriteError.swapUnsupported(errno: ENOTSUP)
            }
            let swapResult = StorageSparseDiskPOSIX.renameSwap(
                directoryFD: parentFD,
                firstName: stageName,
                secondName: resolved.leaf
            )
            guard swapResult == 0 else {
                throw StorageSparseDiskRewriteError.swapUnsupported(errno: errno)
            }
            didSwap = true
            try StorageSparseDiskPOSIX.fsyncDirectory(parentFD)
            try crash(.afterSwap, hooks: hooks)
            record.phase = .swapped
            record.postSwapSource = stageVerifiedIdentity
            record.postSwapStage = initial
            try journal.update(record)
            try crash(.afterSwappedJournal, hooks: hooks)

            try fence.assertExclusive()
            let committedFD = try StorageSparseDiskPOSIX.openRegular(
                parentFD: parentFD,
                leaf: resolved.leaf,
                flags: O_RDONLY,
                purpose: .source
            )
            defer { _ = Darwin.close(committedFD) }
            let committedIdentity = try StorageSparseDiskPOSIX.identity(of: committedFD)
            guard committedIdentity.matchesStable(stageVerifiedIdentity) else {
                try rollbackAfterFailedCommit(
                    directoryFD: parentFD,
                    sourceName: resolved.leaf,
                    stageName: stageName,
                    sourceIdentity: initial,
                    stageIdentity: stageVerifiedIdentity,
                    journal: journal,
                    record: &record,
                    didResolve: &didResolveSwapFailure
                )
                throw StorageSparseDiskRewriteError.verificationFailed(phase: "committed-identity")
            }
            let committedDigest = try StorageSparseDiskPOSIX.sha512(
                fd: committedFD,
                size: initial.sizeBytes,
                chunkBytes: request.chunkBytes,
                phase: .committing,
                isSource: false,
                isCancelled: isCancelled,
                progress: progress
            )
            guard committedDigest == sourceDigest else {
                try rollbackAfterFailedCommit(
                    directoryFD: parentFD,
                    sourceName: resolved.leaf,
                    stageName: stageName,
                    sourceIdentity: initial,
                    stageIdentity: stageVerifiedIdentity,
                    journal: journal,
                    record: &record,
                    didResolve: &didResolveSwapFailure
                )
                throw StorageSparseDiskRewriteError.verificationFailed(phase: "committed-digest")
            }
            try checkCancelled(isCancelled)
            let committedMetadata = try StorageSparseDiskPOSIX.captureMetadata(fd: committedFD)
            let committedFingerprint = try StorageSparseDiskPOSIX.metadataFingerprint(committedMetadata)
            guard committedFingerprint == expectedFingerprint else {
                try rollbackAfterFailedCommit(
                    directoryFD: parentFD,
                    sourceName: resolved.leaf,
                    stageName: stageName,
                    sourceIdentity: initial,
                    stageIdentity: stageVerifiedIdentity,
                    journal: journal,
                    record: &record,
                    didResolve: &didResolveSwapFailure
                )
                throw StorageSparseDiskRewriteError.metadataVerificationFailed(field: "committed")
            }
            let committedVolume = try StorageSparseDiskPOSIX.volumeSpace(
                directoryFD: parentFD,
                availableOverride: hooks.availableBytesOverride
            )
            record.phase = .committed
            record.postSwapSource = committedIdentity
            record.volumeAvailableBytesAtCommit = committedVolume.availableBytes
            try journal.update(record)
            try crash(.afterCommitJournal, hooks: hooks)

            var oldFD: Int32? = try StorageSparseDiskPOSIX.openRegular(
                parentFD: parentFD,
                leaf: stageName,
                flags: O_RDONLY,
                purpose: .stageOpen
            )
            defer {
                if let oldFD { _ = Darwin.close(oldFD) }
            }
            guard let oldFDValue = oldFD else {
                throw StorageSparseDiskRewriteError.needsInspection("retire-open")
            }
            let oldIdentity = try StorageSparseDiskPOSIX.identity(of: oldFDValue)
            guard oldIdentity.matchesStable(initial),
                  oldIdentity.inode != committedIdentity.inode
            else {
                throw StorageSparseDiskRewriteError.needsInspection("retire-identity")
            }
            let retiredAllocated = try StorageSparseDiskPOSIX.allocatedBytes(of: oldFDValue)
            // The old source inode and its fd must be closed before measuring
            // the actual volume delta, otherwise its blocks cannot be returned
            // to the allocator and the observation would understate the delta.
            _ = Darwin.close(oldFDValue)
            oldFD = nil
            _ = Darwin.close(sourceFD)
            sourceFDClosed = true
            try crash(.beforeRetire, hooks: hooks)
            let unlinkResult = StorageSparseDiskPOSIX.unlinkName(
                directoryFD: parentFD,
                name: stageName
            )
            if unlinkResult != 0 && errno != ENOENT {
                throw StorageSparseDiskRewriteError.needsInspection("retire-unlink")
            }
            try StorageSparseDiskPOSIX.fsyncDirectory(parentFD)
            let volumeAfter = try StorageSparseDiskPOSIX.volumeSpace(
                directoryFD: parentFD,
                availableOverride: hooks.availableBytesOverride
            )
            record.phase = .retired
            record.stageRetired = true
            record.retiredSourceAllocatedBytes = retiredAllocated
            record.volumeAvailableBytesAfter = volumeAfter.availableBytes
            try journal.update(record)
            try crash(.afterRetire, hooks: hooks)

            let delta = volumeAfter.availableBytes >= volumeBefore.availableBytes
                ? volumeAfter.availableBytes - volumeBefore.availableBytes
                : -(volumeBefore.availableBytes - volumeAfter.availableBytes)
            return StorageSparseDiskRewriteReport(
                jobID: jobID,
                relativePath: request.relativePath,
                modeUsed: modeUsed,
                fallbackReason: fallbackReason,
                logicalBytes: initial.sizeBytes,
                sourceAllocatedBytesBefore: sourceAllocatedBefore,
                stageAllocatedBytesAtVerification: stageAllocated,
                retiredSourceAllocatedBytesBeforeUnlink: retiredAllocated,
                volumeAvailableBytesBefore: volumeBefore.availableBytes,
                volumeAvailableBytesAtCommit: committedVolume.availableBytes,
                volumeAvailableBytesAfter: volumeAfter.availableBytes,
                volumeAvailableDeltaBytes: delta,
                sourceDigestSHA512: sourceDigest,
                stageDigestSHA512: stageDigest,
                nonzeroBytes: counted.nonzeroBytes,
                zeroBytes: counted.zeroBytes,
                punchedBytes: punchedBytes,
                skippedXattrNames: metadata.skippedXattrNames,
                protectionClassPreserved: metadata.protectionClass != nil
                    && committedMetadata.protectionClass == metadata.protectionClass,
                stageRetired: true,
                journalPhase: record.phase.rawValue
            )
        } catch let error as StorageSparseDiskRewriteError {
            if case .crashInjected = error { throw error }
            if didSwap {
                if didResolveSwapFailure { throw error }
                persistSwappedIfPossible(
                    record: &record,
                    journal: journal,
                    stageIdentity: stageIdentity,
                    initial: initial
                )
                if case .cancelledAfterSwap = error { throw error }
                throw StorageSparseDiskRewriteError.recoveryRequired(
                    jobID: jobID,
                    phase: record.phase.rawValue
                )
            }
            let removed = abortStage(
                parentFD: parentFD,
                stageName: stageName,
                stageIdentity: stageIdentity,
                record: &record,
                journal: journal,
                lastError: error.code
            )
            if !removed {
                throw StorageSparseDiskRewriteError.needsInspection(
                    "stage-retained:\(error.code)"
                )
            }
            throw error
        } catch is CancellationError {
            if didSwap {
                if didResolveSwapFailure { throw CancellationError() }
                persistSwappedIfPossible(
                    record: &record,
                    journal: journal,
                    stageIdentity: stageIdentity,
                    initial: initial
                )
                throw StorageSparseDiskRewriteError.cancelledAfterSwap(jobID: jobID)
            }
            let removed = abortStage(
                parentFD: parentFD,
                stageName: stageName,
                stageIdentity: stageIdentity,
                record: &record,
                journal: journal,
                lastError: "cancelled"
            )
            if !removed {
                throw StorageSparseDiskRewriteError.needsInspection("stage-retained:cancelled")
            }
            throw CancellationError()
        } catch {
            if didSwap {
                if didResolveSwapFailure { throw error }
                persistSwappedIfPossible(
                    record: &record,
                    journal: journal,
                    stageIdentity: stageIdentity,
                    initial: initial
                )
                throw StorageSparseDiskRewriteError.recoveryRequired(
                    jobID: jobID,
                    phase: record.phase.rawValue
                )
            }
            let removed = abortStage(
                parentFD: parentFD,
                stageName: stageName,
                stageIdentity: stageIdentity,
                record: &record,
                journal: journal,
                lastError: "error"
            )
            if !removed {
                throw StorageSparseDiskRewriteError.needsInspection("stage-retained:error")
            }
            throw error
        }
    }

    // MARK: - Helpers

    static func validateRequest(_ request: StorageSparseDiskRewriteRequest) throws {
        guard request.mode != .sparseCopy else {
            throw StorageSparseDiskRewriteError.unsupportedMode("sparse-copy-disabled")
        }
        try StorageSparseDiskPOSIX.validateJobID(request.jobID)
        _ = try StorageSparseDiskPOSIX.validateRelativePath(request.relativePath)
        guard !request.maintenanceLeaseID.isEmpty,
              request.maintenanceLeaseID.utf8.count <= 128
        else {
            throw StorageSparseDiskRewriteError.invalidRequest("lease-id")
        }
        guard request.chunkBytes >= 65_536,
              request.chunkBytes <= 4_194_304,
              request.chunkBytes % 4_096 == 0
        else {
            throw StorageSparseDiskRewriteError.invalidRequest("chunk-bytes")
        }
        guard request.zeroProbeBytes >= 4_096,
              request.zeroProbeBytes <= 1_048_576,
              request.zeroProbeBytes % 4_096 == 0,
              request.chunkBytes % request.zeroProbeBytes == 0
        else {
            throw StorageSparseDiskRewriteError.invalidRequest("zero-probe-bytes")
        }
        guard request.safetyMarginBytes >= 0,
              request.safetyMarginBytes <= 4 * 1_024 * 1_024 * 1_024
        else {
            throw StorageSparseDiskRewriteError.invalidRequest("safety-margin")
        }
        if let minimum = request.minimumReclaimBytes,
           minimum < 0 || minimum > StorageSparseDiskRewrite.maximumSourceBytes {
            throw StorageSparseDiskRewriteError.invalidRequest("minimum-reclaim")
        }
        guard request.expectedSource.sizeBytes > 0,
              request.expectedSource.sizeBytes <= StorageSparseDiskRewrite.maximumSourceBytes
        else {
            throw StorageSparseDiskRewriteError.oversizedSource(
                bytes: request.expectedSource.sizeBytes,
                limit: StorageSparseDiskRewrite.maximumSourceBytes
            )
        }
    }

    static func requirePositiveGain(
        sourceAllocated: Int64,
        stageAllocated: Int64,
        minimumReclaimBytes: Int64?
    ) throws {
        let measured = sourceAllocated - stageAllocated
        let required = max(1, minimumReclaimBytes ?? 1)
        guard measured >= required else {
            throw StorageSparseDiskRewriteError.insufficientReclaim(
                measured: measured, minimum: required
            )
        }
    }

    static func parentURL(for request: StorageSparseDiskRewriteRequest) throws -> URL {
        let components = try StorageSparseDiskPOSIX.validateRelativePath(request.relativePath)
        guard components.count > 1 else { return request.rootURL }
        let relativeParent = components.dropLast().joined(separator: "/")
        return request.rootURL.appendingPathComponent(relativeParent, isDirectory: true)
    }

    static func checkCancelled(_ isCancelled: @escaping @Sendable () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
    }

    static func crash(
        _ point: StorageSparseDiskRewrite.CrashPoint,
        hooks: StorageSparseDiskRewrite.TestHooks
    ) throws {
        try hooks.crashAt?(point)
    }

    static func persistSwappedIfPossible(
        record: inout StorageSparseDiskRewriteJournalRecord,
        journal: StorageSparseDiskRewriteJournalHandle,
        stageIdentity: StorageSparseDiskIdentity?,
        initial: StorageSparseDiskIdentity
    ) {
        guard record.phase == .swapIntent || record.phase == .verified else { return }
        record.phase = .swapped
        record.postSwapSource = stageIdentity
        record.postSwapStage = initial
        try? journal.update(record)
    }

    /// Remove only a stage whose current path identity is proven to be this
    /// job's stage. A missing stage is fine; an unknown stage is preserved.
    @discardableResult
    static func abortStage(
        parentFD: Int32,
        stageName: String,
        stageIdentity: StorageSparseDiskIdentity?,
        record: inout StorageSparseDiskRewriteJournalRecord,
        journal: StorageSparseDiskRewriteJournalHandle,
        lastError: String
    ) -> Bool {
        var removed = true
        let observation = StorageSparseDiskPOSIX.observe(parentFD: parentFD, name: stageName)
        if observation.exists {
            if let expected = stageIdentity,
               let actual = observation.identity,
               actual.matchesInode(expected) {
                let result = StorageSparseDiskPOSIX.unlinkName(
                    directoryFD: parentFD,
                    name: stageName
                )
                if result != 0 && errno != ENOENT {
                    removed = false
                }
            } else {
                // Unknown/replaced stage: never guessed away.
                removed = false
            }
        }
        if removed {
            do {
                try StorageSparseDiskPOSIX.fsyncDirectory(parentFD)
            } catch {
                // The unlink is visible, but its directory entry is not
                // proven durable. Keep the conservative needs-inspection
                // outcome rather than claiming a clean abort.
                removed = false
            }
        }
        record.phase = .failed
        record.stageRetained = !removed
        record.lastError = lastError
        do {
            try journal.update(record)
        } catch {
            removed = false
        }
        return removed
    }

    /// If post-swap verification fails, restore the original source only when
    /// both path identities are still exactly S/T. The restored source is the
    /// untouched original; the stage is then the verified-but-rejected T.
    static func rollbackAfterFailedCommit(
        directoryFD: Int32,
        sourceName: String,
        stageName: String,
        sourceIdentity: StorageSparseDiskIdentity,
        stageIdentity: StorageSparseDiskIdentity,
        journal: StorageSparseDiskRewriteJournalHandle,
        record: inout StorageSparseDiskRewriteJournalRecord,
        didResolve: inout Bool
    ) throws {
        let sourceObservation = StorageSparseDiskPOSIX.observe(parentFD: directoryFD, name: sourceName)
        let stageObservation = StorageSparseDiskPOSIX.observe(parentFD: directoryFD, name: stageName)
        guard sourceObservation.identity?.matchesStable(stageIdentity) == true,
              stageObservation.identity?.matchesStable(sourceIdentity) == true else {
            didResolve = true
            throw StorageSparseDiskRewriteError.needsInspection("rollback-observation")
        }
        // Persist before swapping back: a crash or failed final update must not
        // strand source=S under an old `swapped` phase that recovery rejects.
        record.phase = .rollbackIntent
        try journal.update(record)
        guard StorageSparseDiskPOSIX.renameSwap(
            directoryFD: directoryFD, firstName: stageName, secondName: sourceName
        ) == 0 else {
            throw StorageSparseDiskRewriteError.recoveryRequired(
                jobID: record.jobID, phase: "rollback-swap"
            )
        }
        try StorageSparseDiskPOSIX.fsyncDirectory(directoryFD)
        let restored = StorageSparseDiskPOSIX.observe(parentFD: directoryFD, name: sourceName)
        guard restored.identity?.matchesStable(sourceIdentity) == true else {
            throw StorageSparseDiskRewriteError.needsInspection("rollback-restore")
        }
        let restoredStage = StorageSparseDiskPOSIX.observe(
            parentFD: directoryFD, name: stageName
        )
        if restoredStage.exists {
            guard restoredStage.identity?.matchesStable(stageIdentity) == true else {
                throw StorageSparseDiskRewriteError.needsInspection("rollback-stage")
            }
            let result = StorageSparseDiskPOSIX.unlinkName(directoryFD: directoryFD, name: stageName)
            guard result == 0 || errno == ENOENT else {
                throw StorageSparseDiskRewriteError.recoveryRequired(
                    jobID: record.jobID, phase: "rollback-unlink"
                )
            }
            try StorageSparseDiskPOSIX.fsyncDirectory(directoryFD)
        }
        record.phase = .aborted
        record.resolution = "rolled-back-after-swap"
        record.lastError = "verification-failed"
        try journal.update(record)
        didResolve = true
    }
}

#endif
