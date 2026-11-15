import Foundation
import FloeBuildingRecords

private enum BuildingStageOutcome {
    case alreadyPublished(BuildingProjectCommitResult)
    case staged(BuildingStagedCommit)
}

private struct BuildingStagedCommit {
    let commitID: BuildingCommitID
    let expectedGenerationID: String?
    let identity: BuildingStoredIdentity
    let record: BuildingGenerationRecord
    let stagingURL: URL
    let journal: BuildingProjectJournal
}

extension BuildingProjectRepository {
    /// Publish one immutable generation. The caller supplies a quiescent
    /// records snapshot, a saved native CAD directory, the frozen asset
    /// resource package (optional) and editor metadata. Staging happens under a
    /// shared lock; the manifest compare-and-swap and publication happen under
    /// the exclusive lock. The manifest is written last.
    public func publish(
        _ request: BuildingProjectCommitRequest,
        cancellation: BuildingProjectCancellation? = nil,
        progress: (@Sendable (BuildingProjectCommitProgress) -> Void)? = nil
    ) throws -> BuildingProjectCommitResult {
        try configuration.validate()
        if let cancellation { try cancellation.check() }
        try request.identity.validated()
        guard request.note.utf8.count <= 4096 else {
            throw BuildingProjectError.budgetExceeded("the commit note is longer than 4096 bytes")
        }
        if let expected = request.expectedGeneration.generationID,
           !BuildingStoredIdentity.isSHA256Hex(expected) {
            throw BuildingProjectError.generationExpectationConflict(
                expected: expected,
                actual: nil
            )
        }

        let snapshot = try request.recordsSnapshot.verifyIntegrity()
        guard snapshot.projectID == request.identity.recordsProjectID,
              snapshot.revision == request.identity.recordsRevision else {
            throw BuildingProjectError.recordsSnapshotMismatch(
                "the snapshot is project \(snapshot.projectID) revision \(snapshot.revision)"
            )
        }
        _ = try canonicalInputDirectory(snapshot.directoryURL, label: "records snapshot")
        let cadRoot = try canonicalInputDirectory(request.cadDirectoryURL, label: "CAD directory")
        let resourcesRoot: URL?
        if let assetResourcesDirectoryURL = request.assetResourcesDirectoryURL {
            let resolved = try canonicalInputDirectory(
                assetResourcesDirectoryURL,
                label: "asset resource directory"
            )
            guard !BuildingProjectPaths.isSameOrAncestor(cadRoot, of: resolved),
                  !BuildingProjectPaths.isSameOrAncestor(resolved, of: cadRoot) else {
                throw BuildingProjectError.ioFailure(
                    "the CAD and asset resource directories must not overlap"
                )
            }
            resourcesRoot = resolved
        } else {
            resourcesRoot = nil
        }
        let editorState = try validatedEditorState(request.editorState)

        let outcome: BuildingStageOutcome
        do {
            outcome = try withLock(exclusive: false) {
                try stageCommit(
                    request: request,
                    snapshot: snapshot,
                    cadRoot: cadRoot,
                    resourcesRoot: resourcesRoot,
                    editorState: editorState,
                    cancellation: cancellation,
                    progress: progress
                )
            }
        } catch let error as BuildingProjectError {
            throw error
        } catch {
            throw BuildingProjectError.ioFailure(String(describing: error))
        }

        switch outcome {
        case .alreadyPublished(let result):
            return result
        case .staged(let staged):
            do {
                return try withLock(exclusive: true) {
                    try finalizeCommit(
                        staged,
                        expected: request.expectedGeneration,
                        cancellation: cancellation
                    )
                }
            } catch let error as BuildingProjectError {
                throw error
            } catch {
                throw BuildingProjectError.ioFailure(String(describing: error))
            }
        }
    }

    // MARK: - Staging

    private func stageCommit(
        request: BuildingProjectCommitRequest,
        snapshot: ProjectRecordsSnapshot,
        cadRoot: URL,
        resourcesRoot: URL?,
        editorState: Data,
        cancellation: BuildingProjectCancellation?,
        progress: (@Sendable (BuildingProjectCommitProgress) -> Void)?
    ) throws -> BuildingStageOutcome {
        if let cancellation { try cancellation.check() }
        let expectedID = request.expectedGeneration.generationID
        let journalFileURL = journalURL(for: request.commitID)
        let staging = stagingURL(for: request.commitID)

        if BuildingProjectFileSystem.kind(of: journalFileURL) != .missing {
            let existing = try readJournal(at: journalFileURL)
            guard existing.identity == request.identity,
                  existing.expectedGenerationID == expectedID else {
                throw BuildingProjectError.commitConflict(commitID: request.commitID)
            }
            switch existing.state {
            case .staging, .staged:
                throw BuildingProjectError.pendingRecovery([request.commitID.rawValue])
            case .completed:
                if let candidate = existing.candidateGenerationID,
                   let manifest = try readManifestUnderLock(),
                   manifest.generationID == candidate {
                    let generation = try loadGeneration(candidate, manifest: manifest, verify: true)
                    return .alreadyPublished(BuildingProjectCommitResult(
                        manifest: manifest,
                        generation: generation,
                        wasAlreadyPublished: true
                    ))
                }
                throw BuildingProjectError.commitConflict(commitID: request.commitID)
            case .conflict:
                throw BuildingProjectError.commitConflict(commitID: request.commitID)
            case .abandoned, .failed, .cancelled:
                break
            }
            if BuildingProjectFileSystem.kind(of: staging) != .missing {
                try BuildingProjectFileSystem.removeTree(staging)
            }
        }

        let now = normalizedNow()
        var journal = BuildingProjectJournal(
            commitID: request.commitID,
            expectedGenerationID: expectedID,
            stagingName: request.commitID.rawValue,
            identity: request.identity,
            createdAt: now,
            candidateGenerationID: nil,
            state: .staging,
            message: request.note,
            updatedAt: now
        )

        do {
            try writeJournal(journal)
            guard BuildingProjectFileSystem.kind(of: staging) == .missing else {
                throw BuildingProjectError.ioFailure("the staging directory already exists")
            }
            try BuildingProjectFileSystem.ensureDirectory(staging)
            try runFaultPoint(.afterPreparation)

            let cadEntries = try BuildingProjectFileSystem.inspectTree(
                root: cadRoot,
                section: .cad,
                limits: limits,
                isCancelled: { cancellation?.isCancelled ?? false }
            )
            let recordsEntries = try BuildingProjectFileSystem.inspectTree(
                root: snapshot.directoryURL,
                section: .records,
                limits: limits,
                isCancelled: { cancellation?.isCancelled ?? false }
            )
            let resourcesEntries: [BuildingInspectedFile]
            if let resourcesRoot {
                resourcesEntries = try BuildingProjectFileSystem.inspectTree(
                    root: resourcesRoot,
                    section: .assetResources,
                    limits: limits,
                    isCancelled: { cancellation?.isCancelled ?? false }
                )
            } else {
                resourcesEntries = []
            }

            guard recordsEntries.count == snapshot.fileCount,
                  recordsEntries.reduce(0, { $0 + $1.byteCount }) == snapshot.totalByteCount,
                  recordsEntries.contains(where: {
                      $0.relativePath == BuildingProjectPaths.recordsDatabaseRelativePath
                  }) else {
                throw BuildingProjectError.recordsSnapshotMismatch(
                    "the snapshot file counts changed before the commit was staged"
                )
            }
            for entry in recordsEntries
            where !BuildingProjectPaths.isRecordsPath(entry.relativePath) {
                throw BuildingProjectError.recordsSnapshotMismatch(
                    "unexpected records snapshot path \(entry.relativePath)"
                )
            }

            let totalFiles = cadEntries.count + recordsEntries.count + resourcesEntries.count + 1
            let cadBytes = cadEntries.reduce(0) { $0 + $1.byteCount }
            let recordsBytes = recordsEntries.reduce(0) { $0 + $1.byteCount }
            let resourcesBytes = resourcesEntries.reduce(0) { $0 + $1.byteCount }
            let totalBytes = cadBytes + recordsBytes + resourcesBytes + editorState.count
            guard totalFiles <= limits.maxFileCount else {
                throw BuildingProjectError.budgetExceeded(
                    "the generation has \(totalFiles) files; the limit is \(limits.maxFileCount)"
                )
            }
            guard totalBytes <= limits.maxTotalBytes else {
                throw BuildingProjectError.budgetExceeded(
                    "the generation is \(totalBytes) bytes; the limit is \(limits.maxTotalBytes)"
                )
            }
            progress?(BuildingProjectCommitProgress(
                phase: .inspecting,
                completedFiles: 0,
                totalFiles: totalFiles
            ))

            let cadCompletedBase = 0
            let cadRecords = try BuildingProjectFileSystem.copyTree(
                from: cadRoot,
                to: staging.appendingPathComponent(
                    BuildingProjectPaths.cadDirectoryName,
                    isDirectory: true
                ),
                section: .cad,
                inspected: cadEntries,
                limits: limits,
                isCancelled: { cancellation?.isCancelled ?? false },
                progress: { completed in
                    progress?(BuildingProjectCommitProgress(
                        phase: .copyingCAD,
                        completedFiles: cadCompletedBase + completed,
                        totalFiles: totalFiles
                    ))
                }
            )
            try runFaultPoint(.afterCADCopy)

            let recordsBase = cadEntries.count
            let recordsRecords = try BuildingProjectFileSystem.copyTree(
                from: snapshot.directoryURL,
                to: staging.appendingPathComponent(
                    BuildingProjectPaths.recordsDirectoryName,
                    isDirectory: true
                ),
                section: .records,
                inspected: recordsEntries,
                limits: limits,
                isCancelled: { cancellation?.isCancelled ?? false },
                progress: { completed in
                    progress?(BuildingProjectCommitProgress(
                        phase: .copyingRecords,
                        completedFiles: recordsBase + completed,
                        totalFiles: totalFiles
                    ))
                }
            )
            let recordsDigest = ProjectFileTreeDigest.digest(recordsRecords.map(\.digestValue))
            guard recordsDigest == snapshot.treeSHA256 else {
                throw BuildingProjectError.recordsSnapshotMismatch(
                    "the copied records tree does not match the captured snapshot digest"
                )
            }
            try runFaultPoint(.afterRecordsCopy)

            let resourcesDestination = staging.appendingPathComponent(
                BuildingProjectPaths.assetResourcesDirectoryName,
                isDirectory: true
            )
            let resourcesRecords: [BuildingFileRecord]
            if let resourcesRoot {
                let resourcesBase = cadEntries.count + recordsEntries.count
                resourcesRecords = try BuildingProjectFileSystem.copyTree(
                    from: resourcesRoot,
                    to: resourcesDestination,
                    section: .assetResources,
                    inspected: resourcesEntries,
                    limits: limits,
                    isCancelled: { cancellation?.isCancelled ?? false },
                    progress: { completed in
                        progress?(BuildingProjectCommitProgress(
                            phase: .copyingAssetResources,
                            completedFiles: resourcesBase + completed,
                            totalFiles: totalFiles
                        ))
                    }
                )
            } else {
                try BuildingProjectFileSystem.ensureDirectory(resourcesDestination)
                resourcesRecords = []
            }

            let editorDirectory = staging.appendingPathComponent(
                BuildingProjectPaths.editorStateDirectoryName,
                isDirectory: true
            )
            try BuildingProjectFileSystem.ensureDirectory(editorDirectory)
            let editorURL = editorDirectory.appendingPathComponent(
                BuildingProjectPaths.editorStateRelativePath,
                isDirectory: false
            )
            try BuildingProjectFileSystem.writeAtomically(editorState, to: editorURL)
            let editorReadback = try BuildingProjectFileSystem.readBounded(
                editorURL,
                maxBytes: limits.maxEditorStateBytes
            )
            guard editorReadback == editorState else {
                throw BuildingProjectError.ioFailure("the editor state did not read back with the same bytes")
            }
            let editorRecord = BuildingFileRecord(
                section: .editorState,
                relativePath: BuildingProjectPaths.editorStateRelativePath,
                byteCount: editorState.count,
                sha256: BuildingProjectFileSystem.sha256Hex(editorState)
            )
            progress?(BuildingProjectCommitProgress(
                phase: .copyingEditorState,
                completedFiles: totalFiles,
                totalFiles: totalFiles
            ))

            let recordsTreeDigest = recordsDigest
            let cadTreeDigest = ProjectFileTreeDigest.digest(cadRecords.map(\.digestValue))
            let assetResourcesTreeDigest = ProjectFileTreeDigest.digest(
                resourcesRecords.map(\.digestValue)
            )
            let allFiles = cadRecords + recordsRecords + resourcesRecords + [editorRecord]
            let record = generationRecord(
                identity: request.identity,
                commitID: request.commitID,
                createdAt: normalizedNow(),
                recordsTreeDigest: recordsTreeDigest,
                cadTreeDigest: cadTreeDigest,
                editorStateSHA256: editorRecord.sha256,
                editorStateByteCount: editorRecord.byteCount,
                assetResourcesTreeDigest: assetResourcesTreeDigest,
                files: allFiles
            )
            try record.validate(limits: limits)
            let generationData = try BuildingProjectJSON.encode(record)
            guard generationData.count <= limits.maxManifestBytes else {
                throw BuildingProjectError.budgetExceeded(
                    "Generation.json is \(generationData.count) bytes; the limit is \(limits.maxManifestBytes)"
                )
            }
            try BuildingProjectFileSystem.writeAtomically(
                generationData,
                to: staging.appendingPathComponent(
                    BuildingProjectPaths.generationFileName,
                    isDirectory: false
                )
            )
            journal.update(
                state: .staged,
                candidateGenerationID: record.generationID,
                message: request.note,
                at: normalizedNow()
            )
            try writeJournal(journal)

            if let manifest = try readManifestUnderLock(),
               manifest.generationID == record.generationID {
                guard manifestMatchesRecord(manifest, record: record) else {
                    throw BuildingProjectError.manifestCorrupted(
                        "the current manifest disagrees with the staged generation"
                    )
                }
                journal.update(
                    state: .completed,
                    candidateGenerationID: record.generationID,
                    message: "already published",
                    at: normalizedNow()
                )
                try writeJournal(journal)
                try BuildingProjectFileSystem.removeTree(staging)
                let generation = try loadGeneration(
                    record.generationID,
                    manifest: manifest,
                    verify: true
                )
                return .alreadyPublished(BuildingProjectCommitResult(
                    manifest: manifest,
                    generation: generation,
                    wasAlreadyPublished: true
                ))
            }

            let generationDirectory = BuildingProjectPaths.generationDirectoryURL(
                root: rootURL,
                generationID: record.generationID
            )
            if BuildingProjectFileSystem.kind(of: generationDirectory) == .directory {
                let existing = try loadGeneration(
                    record.generationID,
                    manifest: nil,
                    verify: true
                )
                guard recordMatchesContent(existing.record, record) else {
                    throw BuildingProjectError.generationAlreadyExists(record.generationID)
                }
                try BuildingProjectFileSystem.removeTree(staging)
                return .staged(BuildingStagedCommit(
                    commitID: request.commitID,
                    expectedGenerationID: expectedID,
                    identity: request.identity,
                    record: existing.record,
                    stagingURL: staging,
                    journal: journal
                ))
            } else if BuildingProjectFileSystem.kind(of: generationDirectory) != .missing {
                throw BuildingProjectError.generationAlreadyExists(record.generationID)
            }

            return .staged(BuildingStagedCommit(
                commitID: request.commitID,
                expectedGenerationID: expectedID,
                identity: request.identity,
                record: record,
                stagingURL: staging,
                journal: journal
            ))
        } catch let error as BuildingProjectError {
            if case .injectedFailure = error {
                throw error
            }
            journal.update(
                state: error == .cancelled ? .cancelled : .failed,
                message: truncatedMessage(error.errorDescription ?? String(describing: error)),
                at: normalizedNow()
            )
            try? writeJournal(journal)
            try? BuildingProjectFileSystem.removeTree(staging)
            throw error
        } catch {
            journal.update(
                state: .failed,
                message: truncatedMessage(String(describing: error)),
                at: normalizedNow()
            )
            try? writeJournal(journal)
            try? BuildingProjectFileSystem.removeTree(staging)
            throw BuildingProjectError.ioFailure(String(describing: error))
        }
    }

    // MARK: - Final publication

    private func finalizeCommit(
        _ staged: BuildingStagedCommit,
        expected: BuildingGenerationExpectation,
        cancellation: BuildingProjectCancellation?
    ) throws -> BuildingProjectCommitResult {
        if let cancellation { try cancellation.check() }
        let pending = try pendingJournalCommitIDs(excluding: staged.commitID)
        guard pending.isEmpty else {
            throw BuildingProjectError.pendingRecovery(pending)
        }
        let currentManifest = try readManifestUnderLock()

        if let currentManifest,
           currentManifest.generationID == staged.record.generationID {
            guard manifestMatchesRecord(currentManifest, record: staged.record) else {
                throw BuildingProjectError.manifestCorrupted(
                    "the current manifest disagrees with the staged generation"
                )
            }
            var journal = staged.journal
            journal.update(
                state: .completed,
                candidateGenerationID: staged.record.generationID,
                message: "already published",
                at: normalizedNow()
            )
            try writeJournal(journal)
            let generation = try loadGeneration(
                staged.record.generationID,
                manifest: currentManifest,
                verify: true
            )
            return BuildingProjectCommitResult(
                manifest: currentManifest,
                generation: generation,
                wasAlreadyPublished: true
            )
        }

        switch expected {
        case .emptyProject:
            guard currentManifest == nil else {
                let conflict = BuildingProjectError.generationExpectationConflict(
                    expected: nil,
                    actual: currentManifest?.generationID
                )
                markConflict(staged, message: conflict.errorDescription ?? "generation conflict")
                throw conflict
            }
        case .generation(let expectedID):
            guard currentManifest?.generationID == expectedID else {
                let conflict = BuildingProjectError.generationExpectationConflict(
                    expected: expectedID,
                    actual: currentManifest?.generationID
                )
                markConflict(staged, message: conflict.errorDescription ?? "generation conflict")
                throw conflict
            }
        }

        let generationDirectory = BuildingProjectPaths.generationDirectoryURL(
            root: rootURL,
            generationID: staged.record.generationID
        )
        let finalRecord: BuildingGenerationRecord
        switch BuildingProjectFileSystem.kind(of: generationDirectory) {
        case .directory:
            let existing = try loadGeneration(
                staged.record.generationID,
                manifest: nil,
                verify: true
            )
            guard recordMatchesContent(existing.record, staged.record) else {
                let conflict = BuildingProjectError.generationAlreadyExists(staged.record.generationID)
                markConflict(staged, message: conflict.errorDescription ?? "generation conflict")
                throw conflict
            }
            finalRecord = existing.record
            if BuildingProjectFileSystem.kind(of: staged.stagingURL) == .directory {
                try BuildingProjectFileSystem.removeTree(staged.stagingURL)
            }
        case .missing:
            guard BuildingProjectFileSystem.kind(of: staged.stagingURL) == .directory else {
                throw BuildingProjectError.generationNotFound(staged.record.generationID)
            }
            let stagedRecord = try readGenerationRecord(
                at: staged.stagingURL,
                expectedID: staged.record.generationID
            )
            guard recordMatchesContent(stagedRecord, staged.record) else {
                throw BuildingProjectError.generationCorrupted(
                    generationID: staged.record.generationID,
                    reason: "the staged generation no longer matches its descriptor"
                )
            }
            try verifyGenerationFiles(stagedRecord, directory: staged.stagingURL)
            try FileManager.default.moveItem(at: staged.stagingURL, to: generationDirectory)
            BuildingProjectFileSystem.fsyncDirectory(generationsRootURL)
            finalRecord = stagedRecord
        case .symbolicLink:
            throw BuildingProjectError.symbolicLinkRejected(generationDirectory.path)
        case .regular, .other:
            throw BuildingProjectError.generationAlreadyExists(staged.record.generationID)
        }

        if let currentManifest, currentManifest.projectID != finalRecord.projectID {
            let conflict = BuildingProjectError.workingCopyProjectMismatch
            markConflict(staged, message: conflict.errorDescription ?? "project identity conflict")
            throw conflict
        }

        try runFaultPoint(.beforeManifestPublish)
        if let cancellation { try cancellation.check() }

        let manifest = makeManifest(
            record: finalRecord,
            sequence: (currentManifest?.sequence ?? 0) + 1,
            previousGenerationID: currentManifest?.generationID,
            commitID: staged.commitID,
            publishedAt: normalizedNow()
        )
        try writeManifestAndVerify(manifest)
        try runFaultPoint(.afterManifestPublish)

        var journal = staged.journal
        journal.update(
            state: .completed,
            candidateGenerationID: finalRecord.generationID,
            message: "published",
            at: normalizedNow()
        )
        try writeJournal(journal)
        let generation = try loadGeneration(
            finalRecord.generationID,
            manifest: manifest,
            verify: true
        )
        return BuildingProjectCommitResult(
            manifest: manifest,
            generation: generation,
            wasAlreadyPublished: false
        )
    }

    // MARK: - Helpers

    func runFaultPoint(_ point: BuildingProjectFaultPoint) throws {
        guard let hooks = configuration.faultHooks else { return }
        do {
            try hooks.onPoint(point)
        } catch {
            throw BuildingProjectError.injectedFailure(point)
        }
    }

    func manifestMatchesRecord(
        _ manifest: BuildingProjectManifest,
        record: BuildingGenerationRecord
    ) -> Bool {
        manifest.projectID == record.projectID
            && manifest.generationID == record.generationID
            && manifest.identity == record.identity
            && manifest.recordsTreeDigest == record.recordsTreeDigest
            && manifest.cadTreeDigest == record.cadTreeDigest
            && manifest.editorStateSHA256 == record.editorStateSHA256
            && manifest.editorStateByteCount == record.editorStateByteCount
            && manifest.assetResourcesTreeDigest == record.assetResourcesTreeDigest
    }

    private func markConflict(_ staged: BuildingStagedCommit, message: String) {
        var journal = staged.journal
        journal.update(
            state: .conflict,
            candidateGenerationID: staged.record.generationID,
            message: truncatedMessage(message),
            at: normalizedNow()
        )
        try? writeJournal(journal)
    }

    private func truncatedMessage(_ value: String) -> String {
        let limit = max(1, min(4096, limits.maxJournalBytes / 2))
        guard value.utf8.count > limit else { return value }
        return String(value.prefix(limit))
    }
}
