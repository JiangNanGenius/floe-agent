import Foundation

extension BuildingProjectRepository {
    /// Mark a working copy as having an in-flight save. The working directory and
    /// its Records connection stay unchanged. The baseline compare-and-swap and
    /// the current manifest are both checked, so a working copy based on an old
    /// generation cannot silently overwrite a newer publication.
    @discardableResult
    public func beginWorkingCopySave(
        _ copy: BuildingProjectWorkingCopy,
        expectedBaseGenerationID: String?,
        commitID: BuildingCommitID
    ) throws -> BuildingProjectWorkingCopy {
        try configuration.validate()
        return try withLock(exclusive: true) {
            let (directory, metadata) = try readWorkingCopyMetadata(copy)
            if let pending = metadata.pendingCommitID {
                if pending == commitID {
                    return try makeWorkingCopy(metadata: metadata, directory: directory)
                }
                throw BuildingProjectError.workingCopySaveInProgress(pending)
            }
            guard metadata.baseGenerationID == expectedBaseGenerationID else {
                throw BuildingProjectError.workingCopyBaseConflict(
                    expected: expectedBaseGenerationID,
                    actual: metadata.baseGenerationID
                )
            }
            let manifest = try readManifestUnderLock()
            guard manifest?.generationID == expectedBaseGenerationID else {
                throw BuildingProjectError.workingCopyBaseConflict(
                    expected: expectedBaseGenerationID,
                    actual: manifest?.generationID
                )
            }
            let updated = BuildingProjectWorkingCopyMetadata(
                schemaVersion: metadata.schemaVersion,
                workingCopyID: metadata.workingCopyID,
                baseGenerationID: metadata.baseGenerationID,
                baseProjectID: metadata.baseProjectID,
                baseRecordsRevision: metadata.baseRecordsRevision,
                pendingCommitID: commitID,
                lastAcknowledgedCommitID: metadata.lastAcknowledgedCommitID,
                createdAt: metadata.createdAt,
                updatedAt: normalizedNow()
            )
            try writeWorkingCopyMetadata(updated, to: directory)
            return try makeWorkingCopy(metadata: updated, directory: directory)
        }
    }

    /// Clear a save marker after a known failure. If the commit was in fact
    /// published (a crash between the manifest write and the UI acknowledgement),
    /// this method records the published baseline instead of pretending the save
    /// is still pending.
    @discardableResult
    public func cancelWorkingCopySave(
        _ copy: BuildingProjectWorkingCopy,
        commitID: BuildingCommitID
    ) throws -> BuildingProjectWorkingCopy {
        try configuration.validate()
        return try withLock(exclusive: true) {
            let (directory, metadata) = try readWorkingCopyMetadata(copy)
            guard let pending = metadata.pendingCommitID else {
                return try makeWorkingCopy(metadata: metadata, directory: directory)
            }
            guard pending == commitID else {
                throw BuildingProjectError.workingCopySaveInProgress(pending)
            }
            let manifest = try readManifestUnderLock()
            if let publishedID = try publishedGenerationID(
                for: commitID,
                manifest: manifest,
                requireCurrent: false
            ) {
                let matchingManifest = manifest?.generationID == publishedID ? manifest : nil
                let generation = try loadGeneration(
                    publishedID,
                    manifest: matchingManifest,
                    verify: true
                )
                let updated = try acknowledgedMetadata(
                    metadata,
                    generation: generation,
                    commitID: commitID
                )
                try writeWorkingCopyMetadata(updated, to: directory)
                return try makeWorkingCopy(metadata: updated, directory: directory)
            }
            let updated = BuildingProjectWorkingCopyMetadata(
                schemaVersion: metadata.schemaVersion,
                workingCopyID: metadata.workingCopyID,
                baseGenerationID: metadata.baseGenerationID,
                baseProjectID: metadata.baseProjectID,
                baseRecordsRevision: metadata.baseRecordsRevision,
                pendingCommitID: nil,
                lastAcknowledgedCommitID: metadata.lastAcknowledgedCommitID,
                createdAt: metadata.createdAt,
                updatedAt: normalizedNow()
            )
            try writeWorkingCopyMetadata(updated, to: directory)
            return try makeWorkingCopy(metadata: updated, directory: directory)
        }
    }

    /// Update the persisted working-copy baseline to a published generation
    /// without touching any working file. The caller must still use the same
    /// working directory and Records connection; only WorkingCopy.json changes.
    @discardableResult
    public func rebaseWorkingCopy(
        _ copy: BuildingProjectWorkingCopy,
        to publishedGenerationID: String,
        expectedBaseGenerationID: String?,
        commitID: BuildingCommitID
    ) throws -> BuildingProjectWorkingCopy {
        try configuration.validate()
        return try withLock(exclusive: true) {
            let (directory, metadata) = try readWorkingCopyMetadata(copy)
            let manifest = try readManifestUnderLock()
            guard manifest?.generationID == publishedGenerationID else {
                throw BuildingProjectError.workingCopyBaseConflict(
                    expected: publishedGenerationID,
                    actual: manifest?.generationID
                )
            }
            let generation = try loadGeneration(publishedGenerationID, manifest: manifest, verify: true)
            if metadata.baseGenerationID == publishedGenerationID {
                if let pending = metadata.pendingCommitID, pending != commitID {
                    throw BuildingProjectError.workingCopySaveInProgress(pending)
                }
                let updated = try acknowledgedMetadata(
                    metadata,
                    generation: generation,
                    commitID: commitID
                )
                try writeWorkingCopyMetadata(updated, to: directory)
                return try makeWorkingCopy(metadata: updated, directory: directory)
            }
            if let pending = metadata.pendingCommitID, pending != commitID {
                throw BuildingProjectError.workingCopySaveInProgress(pending)
            }
            guard metadata.pendingCommitID == commitID else {
                throw BuildingProjectError.workingCopySaveNotStarted
            }
            guard metadata.baseGenerationID == expectedBaseGenerationID else {
                throw BuildingProjectError.workingCopyBaseConflict(
                    expected: expectedBaseGenerationID,
                    actual: metadata.baseGenerationID
                )
            }
            let updated = try acknowledgedMetadata(
                metadata,
                generation: generation,
                commitID: commitID
            )
            try writeWorkingCopyMetadata(updated, to: directory)
            return try makeWorkingCopy(metadata: updated, directory: directory)
        }
    }

    /// Alias for the acknowledgement name used by some callers.
    @discardableResult
    public func acknowledgeWorkingCopySave(
        _ copy: BuildingProjectWorkingCopy,
        publishedGenerationID: String,
        expectedBaseGenerationID: String?,
        commitID: BuildingCommitID
    ) throws -> BuildingProjectWorkingCopy {
        try rebaseWorkingCopy(
            copy,
            to: publishedGenerationID,
            expectedBaseGenerationID: expectedBaseGenerationID,
            commitID: commitID
        )
    }

    /// Reconcile persisted working-copy save markers with the manifest and
    /// journals. A pending save whose generation is already published is
    /// acknowledged; a save that is not published stays pending. This is how a
    /// process restart avoids showing an already-published save as unsaved.
    public func reconcileWorkingCopies() throws -> [BuildingWorkingCopyReconciliation] {
        try configuration.validate()
        return try withLock(exclusive: true) {
            let manifest = try readManifestUnderLock()
            return try reconcileWorkingCopiesUnderLock(manifest: manifest)
        }
    }

    // MARK: - Internal metadata handling

    func reconcileWorkingCopiesUnderLock(
        manifest: BuildingProjectManifest?
    ) throws -> [BuildingWorkingCopyReconciliation] {
        var results: [BuildingWorkingCopyReconciliation] = []
        let names = try BuildingProjectFileSystem.listDirectoryNames(workRootURL)
        for name in names {
            let directory = workRootURL.appendingPathComponent(name, isDirectory: true)
            guard BuildingProjectFileSystem.kind(of: directory) == .directory else {
                results.append(BuildingWorkingCopyReconciliation(
                    workingCopyID: name,
                    pendingCommitID: nil,
                    baseGenerationID: nil,
                    outcome: .invalidMetadata,
                    message: "the Work entry is not a directory"
                ))
                continue
            }
            let metadataURL = directory.appendingPathComponent(
                BuildingProjectPaths.workingCopyFileName,
                isDirectory: false
            )
            guard BuildingProjectFileSystem.kind(of: metadataURL) == .regular else {
                continue
            }
            let metadata: BuildingProjectWorkingCopyMetadata
            do {
                let data = try BuildingProjectFileSystem.readBounded(
                    metadataURL,
                    maxBytes: limits.maxManifestBytes
                )
                metadata = try BuildingProjectJSON.decode(
                    BuildingProjectWorkingCopyMetadata.self,
                    from: data
                )
                guard metadata.schemaVersion == 1,
                      metadata.workingCopyID == name else {
                    throw BuildingProjectError.invalidWorkingCopy("metadata identity mismatch")
                }
            } catch {
                results.append(BuildingWorkingCopyReconciliation(
                    workingCopyID: name,
                    pendingCommitID: nil,
                    baseGenerationID: nil,
                    outcome: .invalidMetadata,
                    message: "WorkingCopy.json is unreadable"
                ))
                continue
            }
            guard let pending = metadata.pendingCommitID else {
                if let base = metadata.baseGenerationID {
                    let baseURL = BuildingProjectPaths.generationDirectoryURL(
                        root: rootURL,
                        generationID: base
                    )
                    if BuildingProjectFileSystem.kind(of: baseURL) != .directory {
                        results.append(BuildingWorkingCopyReconciliation(
                            workingCopyID: metadata.workingCopyID,
                            pendingCommitID: nil,
                            baseGenerationID: base,
                            outcome: .orphanedBase,
                            message: "the working copy base generation is missing"
                        ))
                    }
                }
                continue
            }
            guard let publishedID = try publishedGenerationID(
                for: pending,
                manifest: manifest,
                requireCurrent: false
            ) else {
                results.append(BuildingWorkingCopyReconciliation(
                    workingCopyID: metadata.workingCopyID,
                    pendingCommitID: pending,
                    baseGenerationID: metadata.baseGenerationID,
                    outcome: .pending,
                    message: "the pending commit is not the current published generation"
                ))
                continue
            }
            do {
                let matchingManifest = manifest?.generationID == publishedID ? manifest : nil
                let generation = try loadGeneration(
                    publishedID,
                    manifest: matchingManifest,
                    verify: true
                )
                guard let baseProjectID = metadata.baseProjectID,
                      baseProjectID == generation.projectID else {
                    results.append(BuildingWorkingCopyReconciliation(
                        workingCopyID: metadata.workingCopyID,
                        pendingCommitID: pending,
                        baseGenerationID: metadata.baseGenerationID,
                        outcome: .invalidMetadata,
                        message: "the published generation belongs to a different project"
                    ))
                    continue
                }
                if let baseRevision = metadata.baseRecordsRevision,
                   generation.identity.recordsRevision < baseRevision {
                    results.append(BuildingWorkingCopyReconciliation(
                        workingCopyID: metadata.workingCopyID,
                        pendingCommitID: pending,
                        baseGenerationID: metadata.baseGenerationID,
                        outcome: .pending,
                        message: "the published records revision is older than the working baseline"
                    ))
                    continue
                }
                let updated = try acknowledgedMetadata(
                    metadata,
                    generation: generation,
                    commitID: pending
                )
                try writeWorkingCopyMetadata(updated, to: directory)
                let isCurrent = manifest?.generationID == publishedID
                results.append(BuildingWorkingCopyReconciliation(
                    workingCopyID: metadata.workingCopyID,
                    pendingCommitID: pending,
                    baseGenerationID: publishedID,
                    outcome: isCurrent ? .acknowledgedByManifest : .acknowledgedByJournal,
                    message: isCurrent
                        ? "the working copy baseline was advanced from the published manifest"
                        : "the working copy baseline was advanced from the completed commit journal"
                ))
            } catch {
                results.append(BuildingWorkingCopyReconciliation(
                    workingCopyID: metadata.workingCopyID,
                    pendingCommitID: pending,
                    baseGenerationID: metadata.baseGenerationID,
                    outcome: .invalidMetadata,
                    message: recoveryMessageForWorkingCopy(error)
                ))
            }
        }
        return results
    }

    func readWorkingCopyMetadata(
        _ copy: BuildingProjectWorkingCopy
    ) throws -> (directory: URL, metadata: BuildingProjectWorkingCopyMetadata) {
        let directory = copy.directoryURL.standardizedFileURL
        guard BuildingProjectPaths.isContained(root: workRootURL, url: directory) else {
            throw BuildingProjectError.invalidWorkingCopy("the working copy is outside the Work directory")
        }
        let (resolved, metadata) = try readWorkingCopyMetadata(at: directory)
        guard metadata.workingCopyID == copy.workingCopyID,
              resolved.lastPathComponent == copy.workingCopyID else {
            throw BuildingProjectError.invalidWorkingCopy("WorkingCopy.json does not match the requested working copy")
        }
        return (resolved, metadata)
    }

    func readWorkingCopyMetadata(
        at directory: URL
    ) throws -> (directory: URL, metadata: BuildingProjectWorkingCopyMetadata) {
        let resolved = directory.standardizedFileURL
        try BuildingProjectFileSystem.requireNoSymlinkComponents(root: rootURL, url: resolved)
        guard BuildingProjectFileSystem.kind(of: resolved) == .directory else {
            throw BuildingProjectError.workingCopyNotFound(resolved.lastPathComponent)
        }
        let metadataURL = resolved.appendingPathComponent(
            BuildingProjectPaths.workingCopyFileName,
            isDirectory: false
        )
        guard BuildingProjectFileSystem.kind(of: metadataURL) == .regular else {
            throw BuildingProjectError.invalidWorkingCopy("WorkingCopy.json is missing")
        }
        let data = try BuildingProjectFileSystem.readBounded(
            metadataURL,
            maxBytes: limits.maxManifestBytes
        )
        let metadata: BuildingProjectWorkingCopyMetadata
        do {
            metadata = try BuildingProjectJSON.decode(
                BuildingProjectWorkingCopyMetadata.self,
                from: data
            )
        } catch {
            throw BuildingProjectError.invalidWorkingCopy("WorkingCopy.json is unreadable")
        }
        guard metadata.schemaVersion == 1,
              resolved.lastPathComponent == metadata.workingCopyID else {
            throw BuildingProjectError.invalidWorkingCopy("WorkingCopy.json does not match the directory")
        }
        return (resolved, metadata)
    }

    /// List persisted working copies, including a copy whose first publication
    /// never completed and therefore has no current generation. This is the
    /// read-only route a host uses after a process restart to recover unfinished
    /// local work before deciding to publish or discard it.
    public func workingCopies() throws -> [BuildingProjectWorkingCopy] {
        try configuration.validate()
        return try withLock(exclusive: false) {
            var result: [BuildingProjectWorkingCopy] = []
            let names = try BuildingProjectFileSystem.listDirectoryNames(workRootURL)
            for name in names {
                guard UUID(uuidString: name) != nil else { continue }
                let directory = workRootURL.appendingPathComponent(name, isDirectory: true)
                guard BuildingProjectFileSystem.kind(of: directory) == .directory else { continue }
                do {
                    let (resolved, metadata) = try readWorkingCopyMetadata(at: directory)
                    guard metadata.workingCopyID == name else { continue }
                    result.append(try makeWorkingCopy(metadata: metadata, directory: resolved))
                } catch {
                    continue
                }
            }
            return result.sorted { $0.workingCopyID < $1.workingCopyID }
        }
    }

    /// Open one persisted working copy without requiring a published generation.
    /// The caller still opens its Records directory through the existing
    /// ProjectRecordsStore service; no working file is modified here.
    public func openWorkingCopy(_ workingCopyID: String) throws -> BuildingProjectWorkingCopy {
        try configuration.validate()
        guard let uuid = UUID(uuidString: workingCopyID) else {
            throw BuildingProjectError.invalidWorkingCopy("the working copy identifier is not a UUID")
        }
        let normalized = uuid.uuidString.lowercased()
        return try withLock(exclusive: false) {
            let directory = workRootURL.appendingPathComponent(normalized, isDirectory: true)
            guard BuildingProjectPaths.isContained(root: workRootURL, url: directory) else {
                throw BuildingProjectError.invalidWorkingCopy("the working copy is outside the Work directory")
            }
            let (resolved, metadata) = try readWorkingCopyMetadata(at: directory)
            guard metadata.workingCopyID == normalized else {
                throw BuildingProjectError.invalidWorkingCopy("WorkingCopy.json does not match the requested working copy")
            }
            return try makeWorkingCopy(metadata: metadata, directory: resolved)
        }
    }

    func writeWorkingCopyMetadata(
        _ metadata: BuildingProjectWorkingCopyMetadata,
        to directory: URL
    ) throws {
        let data = try BuildingProjectJSON.encode(metadata)
        guard data.count <= limits.maxManifestBytes else {
            throw BuildingProjectError.budgetExceeded("WorkingCopy.json is over budget")
        }
        try BuildingProjectFileSystem.writeAtomically(
            data,
            to: directory.appendingPathComponent(
                BuildingProjectPaths.workingCopyFileName,
                isDirectory: false
            )
        )
    }

    func makeWorkingCopy(
        metadata: BuildingProjectWorkingCopyMetadata,
        directory: URL
    ) throws -> BuildingProjectWorkingCopy {
        BuildingProjectWorkingCopy(
            metadata: metadata,
            directoryURL: directory,
            recordsDirectoryURL: directory.appendingPathComponent(
                BuildingProjectPaths.recordsDirectoryName,
                isDirectory: true
            ),
            cadDirectoryURL: directory.appendingPathComponent(
                BuildingProjectPaths.cadDirectoryName,
                isDirectory: true
            ),
            editorStateURL: directory
                .appendingPathComponent(BuildingProjectPaths.editorStateDirectoryName, isDirectory: true)
                .appendingPathComponent(BuildingProjectPaths.editorStateRelativePath, isDirectory: false),
            assetResourcesDirectoryURL: directory.appendingPathComponent(
                BuildingProjectPaths.assetResourcesDirectoryName,
                isDirectory: true
            )
        )
    }

    func acknowledgedMetadata(
        _ metadata: BuildingProjectWorkingCopyMetadata,
        generation: BuildingProjectGeneration,
        commitID: BuildingCommitID
    ) throws -> BuildingProjectWorkingCopyMetadata {
        guard let baseProjectID = metadata.baseProjectID else {
            throw BuildingProjectError.invalidWorkingCopy("the working copy has no base project identity")
        }
        guard baseProjectID == generation.projectID else {
            throw BuildingProjectError.workingCopyProjectMismatch
        }
        if let baseRevision = metadata.baseRecordsRevision,
           generation.identity.recordsRevision < baseRevision {
            throw BuildingProjectError.workingCopyRevisionRegression(
                previous: baseRevision,
                target: generation.identity.recordsRevision
            )
        }
        return BuildingProjectWorkingCopyMetadata(
            schemaVersion: metadata.schemaVersion,
            workingCopyID: metadata.workingCopyID,
            baseGenerationID: generation.generationID,
            baseProjectID: generation.projectID,
            baseRecordsRevision: generation.identity.recordsRevision,
            pendingCommitID: nil,
            lastAcknowledgedCommitID: commitID,
            createdAt: metadata.createdAt,
            updatedAt: normalizedNow()
        )
    }

    func publishedGenerationID(
        for commitID: BuildingCommitID,
        manifest: BuildingProjectManifest?,
        requireCurrent: Bool
    ) throws -> String? {
        if let manifest, manifest.commitID == commitID {
            return manifest.generationID
        }
        let journalURL = journalURL(for: commitID)
        guard BuildingProjectFileSystem.kind(of: journalURL) == .regular,
              let journal = try? readJournal(at: journalURL),
              let candidate = journal.candidateGenerationID else {
            return nil
        }
        if journal.state == .completed {
            if requireCurrent, manifest?.generationID != candidate {
                return nil
            }
            return candidate
        }
        if journal.state == .staged, manifest?.generationID == candidate {
            return candidate
        }
        return nil
    }

    private func recoveryMessageForWorkingCopy(_ error: Error) -> String {
        if let buildingError = error as? BuildingProjectError,
           let description = buildingError.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
