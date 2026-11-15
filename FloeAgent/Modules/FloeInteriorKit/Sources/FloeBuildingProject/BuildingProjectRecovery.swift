import Foundation

private struct BuildingRecoveryResult {
    let entry: BuildingProjectRecoveryEntry
    let manifest: BuildingProjectManifest?
}

extension BuildingProjectRepository {
    /// Inspect unfinished commits and optionally resume or abandon candidates.
    /// Recovery never overwrites a generation published by another commit. A
    /// journal file alone is not treated as success: the manifest and the
    /// generation file tree are verified first.
    public func recover(
        _ action: BuildingProjectRecoveryAction = .reportOnly
    ) throws -> BuildingProjectRecoveryReport {
        try configuration.validate()
        return try withLock(exclusive: true) {
            try recoverUnderLock(action)
        }
    }

    private func recoverUnderLock(
        _ action: BuildingProjectRecoveryAction
    ) throws -> BuildingProjectRecoveryReport {
        var currentManifest = try readManifestUnderLock()
        var entries: [BuildingProjectRecoveryEntry] = []
        var referencedStaging: Set<String> = []
        var hasUnreadableJournals = false

        var decodedJournals: [(journal: BuildingProjectJournal, url: URL)] = []
        let journalFiles = try journalURLs()
        for url in journalFiles {
            do {
                let journal = try readJournal(at: url)
                referencedStaging.insert(journal.stagingName)
                decodedJournals.append((journal, url))
            } catch {
                hasUnreadableJournals = true
                entries.append(BuildingProjectRecoveryEntry(
                    commitID: nil,
                    generationID: nil,
                    journalState: nil,
                    outcome: .corrupted,
                    message: "unreadable journal \(url.lastPathComponent)"
                ))
            }
        }
        if hasUnreadableJournals, action == .resumeUnpublished {
            throw BuildingProjectError.journalUnreadable(
                "refusing to publish a candidate while another journal is unreadable"
            )
        }
        decodedJournals.sort { $0.journal.createdAt < $1.journal.createdAt }

        for item in decodedJournals {
            let journal = item.journal
            switch journal.state {
            case .completed, .abandoned, .failed, .cancelled:
                continue
            case .conflict:
                if action == .abandonUnpublished,
                   let candidateID = journal.candidateGenerationID,
                   currentManifest?.generationID != candidateID {
                    let staging = stagingURL(for: journal.commitID)
                    let generation = BuildingProjectPaths.generationDirectoryURL(
                        root: rootURL,
                        generationID: candidateID
                    )
                    if BuildingProjectFileSystem.kind(of: staging) == .directory {
                        try? moveToAbandoned(staging, generationID: candidateID)
                    } else if BuildingProjectFileSystem.kind(of: generation) == .directory {
                        try? moveToAbandoned(generation, generationID: candidateID)
                    }
                    markJournal(
                        journal,
                        state: .abandoned,
                        candidateGenerationID: candidateID,
                        message: "conflict candidate moved to Abandoned"
                    )
                    entries.append(BuildingProjectRecoveryEntry(
                        commitID: journal.commitID,
                        generationID: candidateID,
                        journalState: journal.state,
                        outcome: .abandoned,
                        message: "the conflicting candidate was preserved in Abandoned"
                    ))
                } else {
                    entries.append(BuildingProjectRecoveryEntry(
                        commitID: journal.commitID,
                        generationID: journal.candidateGenerationID,
                        journalState: journal.state,
                        outcome: .conflict,
                        message: journal.message
                    ))
                }
                continue
            case .staging, .staged:
                break
            }

            let staging = stagingURL(for: journal.commitID)
            if let candidateID = journal.candidateGenerationID {
                let generation = BuildingProjectPaths.generationDirectoryURL(
                    root: rootURL,
                    generationID: candidateID
                )
                switch BuildingProjectFileSystem.kind(of: generation) {
                case .directory:
                    do {
                        let record = try readGenerationRecord(at: generation, expectedID: candidateID)
                        let result = try recoverCandidate(
                            journal: journal,
                            record: record,
                            candidateURL: generation,
                            candidateIsStaging: false,
                            manifest: currentManifest,
                            action: action
                        )
                        currentManifest = result.manifest
                        entries.append(result.entry)
                    } catch {
                        let isCurrent = currentManifest?.generationID == candidateID
                        if action == .abandonUnpublished, !isCurrent {
                            try? moveToAbandoned(generation, generationID: candidateID)
                            markJournal(
                                journal,
                                state: .abandoned,
                                candidateGenerationID: candidateID,
                                message: "corrupted candidate abandoned"
                            )
                            entries.append(BuildingProjectRecoveryEntry(
                                commitID: journal.commitID,
                                generationID: candidateID,
                                journalState: journal.state,
                                outcome: .abandoned,
                                message: recoveryMessage(error)
                            ))
                        } else {
                            entries.append(BuildingProjectRecoveryEntry(
                                commitID: journal.commitID,
                                generationID: candidateID,
                                journalState: journal.state,
                                outcome: .corrupted,
                                message: recoveryMessage(error)
                            ))
                        }
                    }
                    continue
                case .missing:
                    break
                case .symbolicLink, .regular, .other:
                    entries.append(BuildingProjectRecoveryEntry(
                        commitID: journal.commitID,
                        generationID: candidateID,
                        journalState: journal.state,
                        outcome: .corrupted,
                        message: "the candidate generation path is not a directory"
                    ))
                    continue
                }

                if BuildingProjectFileSystem.kind(of: staging) == .directory,
                   BuildingProjectFileSystem.kind(
                       of: staging.appendingPathComponent(
                           BuildingProjectPaths.generationFileName,
                           isDirectory: false
                       )
                   ) == .regular {
                    do {
                        let record = try readGenerationRecord(at: staging, expectedID: candidateID)
                        let result = try recoverCandidate(
                            journal: journal,
                            record: record,
                            candidateURL: staging,
                            candidateIsStaging: true,
                            manifest: currentManifest,
                            action: action
                        )
                        currentManifest = result.manifest
                        entries.append(result.entry)
                    } catch {
                        if action == .abandonUnpublished {
                            try? moveToAbandoned(staging, generationID: candidateID)
                            markJournal(
                                journal,
                                state: .abandoned,
                                candidateGenerationID: candidateID,
                                message: "corrupted staging abandoned"
                            )
                            entries.append(BuildingProjectRecoveryEntry(
                                commitID: journal.commitID,
                                generationID: candidateID,
                                journalState: journal.state,
                                outcome: .abandoned,
                                message: recoveryMessage(error)
                            ))
                        } else {
                            entries.append(BuildingProjectRecoveryEntry(
                                commitID: journal.commitID,
                                generationID: candidateID,
                                journalState: journal.state,
                                outcome: .corrupted,
                                message: recoveryMessage(error)
                            ))
                        }
                    }
                    continue
                }

                if action == .abandonUnpublished {
                    try? BuildingProjectFileSystem.removeTree(staging)
                    markJournal(
                        journal,
                        state: .abandoned,
                        candidateGenerationID: candidateID,
                        message: "candidate is missing"
                    )
                    entries.append(BuildingProjectRecoveryEntry(
                        commitID: journal.commitID,
                        generationID: candidateID,
                        journalState: journal.state,
                        outcome: .abandoned,
                        message: "candidate is missing"
                    ))
                } else {
                    entries.append(BuildingProjectRecoveryEntry(
                        commitID: journal.commitID,
                        generationID: candidateID,
                        journalState: journal.state,
                        outcome: .missing,
                        message: "the candidate generation is not present"
                    ))
                }
                continue
            }

            // A crash may happen after the staging directory received a complete
            // Generation.json but before the journal recorded its identifier.
            if BuildingProjectFileSystem.kind(of: staging) == .directory {
                let generationFile = staging.appendingPathComponent(
                    BuildingProjectPaths.generationFileName,
                    isDirectory: false
                )
                if BuildingProjectFileSystem.kind(of: generationFile) == .regular {
                    do {
                        let record = try readGenerationRecord(at: staging)
                        let result = try recoverCandidate(
                            journal: journal,
                            record: record,
                            candidateURL: staging,
                            candidateIsStaging: true,
                            manifest: currentManifest,
                            action: action
                        )
                        currentManifest = result.manifest
                        entries.append(result.entry)
                    } catch {
                        if action == .abandonUnpublished {
                            try? moveToAbandoned(
                                staging,
                                generationID: "unknown-\(journal.commitID.rawValue)"
                            )
                            markJournal(
                                journal,
                                state: .abandoned,
                                message: "corrupted staging abandoned"
                            )
                            entries.append(BuildingProjectRecoveryEntry(
                                commitID: journal.commitID,
                                generationID: nil,
                                journalState: journal.state,
                                outcome: .abandoned,
                                message: recoveryMessage(error)
                            ))
                        } else {
                            entries.append(BuildingProjectRecoveryEntry(
                                commitID: journal.commitID,
                                generationID: nil,
                                journalState: journal.state,
                                outcome: .corrupted,
                                message: recoveryMessage(error)
                            ))
                        }
                    }
                } else if action == .abandonUnpublished {
                    try? BuildingProjectFileSystem.removeTree(staging)
                    markJournal(
                        journal,
                        state: .abandoned,
                        message: "incomplete staging removed"
                    )
                    entries.append(BuildingProjectRecoveryEntry(
                        commitID: journal.commitID,
                        generationID: nil,
                        journalState: journal.state,
                        outcome: .abandoned,
                        message: "incomplete staging removed"
                    ))
                } else {
                    entries.append(BuildingProjectRecoveryEntry(
                        commitID: journal.commitID,
                        generationID: nil,
                        journalState: journal.state,
                        outcome: .incomplete,
                        message: "staging exists but has no complete Generation.json"
                    ))
                }
                continue
            }

            if action == .abandonUnpublished {
                markJournal(
                    journal,
                    state: .abandoned,
                    message: "no staging data"
                )
                entries.append(BuildingProjectRecoveryEntry(
                    commitID: journal.commitID,
                    generationID: nil,
                    journalState: journal.state,
                    outcome: .abandoned,
                    message: "no staging data"
                ))
            } else {
                entries.append(BuildingProjectRecoveryEntry(
                    commitID: journal.commitID,
                    generationID: nil,
                    journalState: journal.state,
                    outcome: .missing,
                    message: "no staging data"
                ))
            }
        }

        let stagingNames = try BuildingProjectFileSystem.listDirectoryNames(stagingRootURL)
        let orphanNames = stagingNames.filter { !referencedStaging.contains($0) }
        for name in orphanNames {
            let url = stagingRootURL.appendingPathComponent(name, isDirectory: true)
            if action == .abandonUnpublished,
               !hasUnreadableJournals,
               BuildingProjectFileSystem.kind(of: url) == .directory {
                try? BuildingProjectFileSystem.removeTree(url)
            }
            entries.append(BuildingProjectRecoveryEntry(
                commitID: nil,
                generationID: nil,
                journalState: nil,
                outcome: .orphanStaging,
                message: name
            ))
        }

        let workingCopies = try reconcileWorkingCopiesUnderLock(manifest: currentManifest)
        return BuildingProjectRecoveryReport(
            currentGenerationID: currentManifest?.generationID,
            entries: entries,
            orphanStagingNames: orphanNames,
            workingCopies: workingCopies
        )
    }

    private func recoverCandidate(
        journal: BuildingProjectJournal,
        record: BuildingGenerationRecord,
        candidateURL: URL,
        candidateIsStaging: Bool,
        manifest: BuildingProjectManifest?,
        action: BuildingProjectRecoveryAction
    ) throws -> BuildingRecoveryResult {
        guard journal.identity == record.identity else {
            return BuildingRecoveryResult(
                entry: BuildingProjectRecoveryEntry(
                    commitID: journal.commitID,
                    generationID: record.generationID,
                    journalState: journal.state,
                    outcome: .corrupted,
                    message: "the journal identity does not match Generation.json"
                ),
                manifest: manifest
            )
        }
        if let manifest, manifest.projectID != record.projectID {
            markJournal(
                journal,
                state: .conflict,
                candidateGenerationID: record.generationID,
                message: "the candidate belongs to a different project"
            )
            return BuildingRecoveryResult(
                entry: BuildingProjectRecoveryEntry(
                    commitID: journal.commitID,
                    generationID: record.generationID,
                    journalState: journal.state,
                    outcome: .conflict,
                    message: "the candidate belongs to a different project"
                ),
                manifest: manifest
            )
        }
        do {
            if candidateIsStaging {
                try verifyGenerationFiles(record, directory: candidateURL)
            } else {
                let verified = try loadGeneration(
                    record.generationID,
                    manifest: nil,
                    verify: true
                )
                guard recordMatchesContent(verified.record, record) else {
                    throw BuildingProjectError.generationCorrupted(
                        generationID: record.generationID,
                        reason: "the generation changed during recovery"
                    )
                }
            }
        } catch {
            let isCurrent = manifest?.generationID == record.generationID
            if action == .abandonUnpublished, !isCurrent {
                try? moveToAbandoned(candidateURL, generationID: record.generationID)
                markJournal(
                    journal,
                    state: .abandoned,
                    candidateGenerationID: record.generationID,
                    message: "corrupted candidate abandoned"
                )
                return BuildingRecoveryResult(
                    entry: BuildingProjectRecoveryEntry(
                        commitID: journal.commitID,
                        generationID: record.generationID,
                        journalState: journal.state,
                        outcome: .abandoned,
                        message: recoveryMessage(error)
                    ),
                    manifest: manifest
                )
            }
            return BuildingRecoveryResult(
                entry: BuildingProjectRecoveryEntry(
                    commitID: journal.commitID,
                    generationID: record.generationID,
                    journalState: journal.state,
                    outcome: .corrupted,
                    message: recoveryMessage(error)
                ),
                manifest: manifest
            )
        }

        if let manifest, manifest.generationID == record.generationID {
            guard manifestMatchesRecord(manifest, record: record) else {
                return BuildingRecoveryResult(
                    entry: BuildingProjectRecoveryEntry(
                        commitID: journal.commitID,
                        generationID: record.generationID,
                        journalState: journal.state,
                        outcome: .corrupted,
                        message: "Manifest.json disagrees with the published generation"
                    ),
                    manifest: manifest
                )
            }
            if candidateIsStaging {
                do {
                    _ = try loadGeneration(record.generationID, manifest: manifest, verify: true)
                    try? BuildingProjectFileSystem.removeTree(candidateURL)
                } catch {
                    return BuildingRecoveryResult(
                        entry: BuildingProjectRecoveryEntry(
                            commitID: journal.commitID,
                            generationID: record.generationID,
                            journalState: journal.state,
                            outcome: .corrupted,
                            message: recoveryMessage(error)
                        ),
                        manifest: manifest
                    )
                }
            }
            markJournal(
                journal,
                state: .completed,
                candidateGenerationID: record.generationID,
                message: "manifest already points to this generation"
            )
            return BuildingRecoveryResult(
                entry: BuildingProjectRecoveryEntry(
                    commitID: journal.commitID,
                    generationID: record.generationID,
                    journalState: journal.state,
                    outcome: .completedAfterManifest,
                    message: "journal bookkeeping completed"
                ),
                manifest: manifest
            )
        }

        guard manifestMatchesExpected(manifest, expected: journal.expectedGenerationID) else {
            markJournal(
                journal,
                state: .conflict,
                candidateGenerationID: record.generationID,
                message: "another commit advanced the project"
            )
            return BuildingRecoveryResult(
                entry: BuildingProjectRecoveryEntry(
                    commitID: journal.commitID,
                    generationID: record.generationID,
                    journalState: journal.state,
                    outcome: .conflict,
                    message: "another commit advanced the project"
                ),
                manifest: manifest
            )
        }

        switch action {
        case .reportOnly:
            return BuildingRecoveryResult(
                entry: BuildingProjectRecoveryEntry(
                    commitID: journal.commitID,
                    generationID: record.generationID,
                    journalState: journal.state,
                    outcome: .readyToResume,
                    message: "the candidate is verified and can be published"
                ),
                manifest: manifest
            )
        case .resumeUnpublished:
            if candidateIsStaging {
                let generation = BuildingProjectPaths.generationDirectoryURL(
                    root: rootURL,
                    generationID: record.generationID
                )
                guard BuildingProjectFileSystem.kind(of: generation) == .missing else {
                    throw BuildingProjectError.generationAlreadyExists(record.generationID)
                }
                try FileManager.default.moveItem(at: candidateURL, to: generation)
                BuildingProjectFileSystem.fsyncDirectory(generationsRootURL)
            }
            let newManifest = makeManifest(
                record: record,
                sequence: (manifest?.sequence ?? 0) + 1,
                previousGenerationID: manifest?.generationID,
                commitID: journal.commitID,
                publishedAt: normalizedNow()
            )
            try writeManifestAndVerify(newManifest)
            markJournal(
                journal,
                state: .completed,
                candidateGenerationID: record.generationID,
                message: "resumed unpublished generation"
            )
            return BuildingRecoveryResult(
                entry: BuildingProjectRecoveryEntry(
                    commitID: journal.commitID,
                    generationID: record.generationID,
                    journalState: journal.state,
                    outcome: .resumed,
                    message: "the unpublished generation was published"
                ),
                manifest: newManifest
            )
        case .abandonUnpublished:
            try moveToAbandoned(candidateURL, generationID: record.generationID)
            markJournal(
                journal,
                state: .abandoned,
                candidateGenerationID: record.generationID,
                message: "abandoned by recovery"
            )
            return BuildingRecoveryResult(
                entry: BuildingProjectRecoveryEntry(
                    commitID: journal.commitID,
                    generationID: record.generationID,
                    journalState: journal.state,
                    outcome: .abandoned,
                    message: "the unpublished candidate was moved to Abandoned"
                ),
                manifest: manifest
            )
        }
    }

    private func markJournal(
        _ journal: BuildingProjectJournal,
        state: BuildingProjectJournal.State,
        candidateGenerationID: String? = nil,
        message: String
    ) {
        var updated = journal
        updated.update(
            state: state,
            candidateGenerationID: candidateGenerationID,
            message: message,
            at: normalizedNow()
        )
        try? writeJournal(updated)
    }

    private func moveToAbandoned(_ url: URL, generationID: String) throws {
        guard BuildingProjectFileSystem.kind(of: url) == .directory else {
            throw BuildingProjectError.ioFailure("the abandoned candidate is not a directory")
        }
        let destination = abandonedRootURL.appendingPathComponent(
            "\(generationID)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        guard BuildingProjectFileSystem.kind(of: destination) == .missing else {
            throw BuildingProjectError.ioFailure("the abandoned destination already exists")
        }
        try FileManager.default.moveItem(at: url, to: destination)
        BuildingProjectFileSystem.fsyncDirectory(abandonedRootURL)
    }

    private func manifestMatchesExpected(
        _ manifest: BuildingProjectManifest?,
        expected: String?
    ) -> Bool {
        switch (manifest?.generationID, expected) {
        case (nil, nil):
            return true
        case let (actual?, wanted?):
            return actual == wanted
        default:
            return false
        }
    }

    private func recoveryMessage(_ error: Error) -> String {
        if let buildingError = error as? BuildingProjectError,
           let description = buildingError.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
