// SPDX-License-Identifier: MPL-2.0
//
// Write-ahead restore journal and crash recovery.
//
// The journal is the durable intent record for a multi-component restore.
// Each component has a unique, verifiable marker/identity BEFORE its first
// live mutation, so a process death between a mutation and its receipt can
// still be rolled back without guessing a first project or scanning by title.
//
// Rollback is idempotent and reverse-ordered. A failed rollback is reported,
// never replaced with a success string; the journal stays incomplete so a
// later launch retries it.
import Foundation

public enum C07JournalKind: String, Codable, Sendable {
    case begin
    case intent
    case projectCreated
    case projectRenamed
    case filesWritten
    case notebookCreated
    case notebookRenamed
    case notesCreated
    case settingInserted
    case dataIntent
    case artifactsCommitted
    case dataCommitted
    case complete
    case failed
    case rolledBack
    case rollbackFailed
}

public enum C07JournalOperation: String, Codable, Sendable {
    case project
    case notebook
    case notes
    case setting
    case data
}

public struct C07JournalRecord: Codable, Sendable, Equatable {
    public var version: Int
    public var restoreID: UUID
    public var sequence: Int
    public var kind: C07JournalKind
    public var timestamp: Date
    public var operationID: UUID?
    public var operation: C07JournalOperation?
    public var projectID: UUID?
    public var marker: String?
    public var finalName: String?
    public var notebookID: UUID?
    public var documentIDs: [UUID]?
    public var settingKey: String?
    public var settingJSON: String?
    public var inserted: Bool?
    public var planFile: String?
    public var planSHA256: String?
    public var error: String?

    public init(restoreID: UUID, sequence: Int, kind: C07JournalKind,
                operationID: UUID? = nil, operation: C07JournalOperation? = nil,
                projectID: UUID? = nil, marker: String? = nil,
                finalName: String? = nil, notebookID: UUID? = nil,
                documentIDs: [UUID]? = nil,
                settingKey: String? = nil, settingJSON: String? = nil,
                inserted: Bool? = nil, planFile: String? = nil,
                planSHA256: String? = nil, error: String? = nil,
                timestamp: Date = Date()) {
        self.version = 1
        self.restoreID = restoreID
        self.sequence = sequence
        self.kind = kind
        self.timestamp = timestamp
        self.operationID = operationID
        self.operation = operation
        self.projectID = projectID
        self.marker = marker
        self.finalName = finalName
        self.notebookID = notebookID
        self.documentIDs = documentIDs
        self.settingKey = settingKey
        self.settingJSON = settingJSON
        self.inserted = inserted
        self.planFile = planFile
        self.planSHA256 = planSHA256
        self.error = error
    }
}

/// Single-owner append handle. The restore task owns one instance; recovery
/// uses the static reader. No shared mutable file handle crosses tasks.
public final class C07RestoreJournal {
    public let restoreID: UUID
    public let url: URL
    fileprivate var handle: FileHandle?
    private var sequence: Int = 0

    public init(root: URL, restoreID: UUID = UUID()) throws {
        self.restoreID = restoreID
        try C07FileSystem.ensureDirectory(root)
        self.url = root.appendingPathComponent("restore-\(restoreID.uuidString).jsonl")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw C07DataExchangeError.storageUnavailable("journalCreate")
        }
        do { self.handle = try FileHandle(forWritingTo: url) }
        catch { throw C07DataExchangeError.storageUnavailable("journalOpen") }
    }

    /// Reopens an existing journal for recovery. The append offset is the
    /// current end of file; the sequence continues from the highest record.
    public init?(existingURL url: URL) {
        let view = C07JournalReader.load(url)
        guard let restoreID = view.records.last?.restoreID else { return nil }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        do {
            try handle.seekToEnd()
            // A crash may leave a partial final line. Start the recovery
            // marker on a fresh line so it is actually readable; the partial
            // line is preserved for diagnostics rather than rewritten.
            if let data = try? Data(contentsOf: url), data.last != 0x0A {
                try handle.write(contentsOf: Data([0x0A]))
            }
        } catch { try? handle.close(); return nil }
        self.restoreID = restoreID
        self.url = url
        self.handle = handle
        self.sequence = view.records.map(\.sequence).max() ?? 0
    }

    deinit { try? handle?.close() }

    @discardableResult
    public func append(kind: C07JournalKind,
                       operationID: UUID? = nil,
                       operation: C07JournalOperation? = nil,
                       projectID: UUID? = nil,
                       marker: String? = nil,
                       finalName: String? = nil,
                       notebookID: UUID? = nil,
                       documentIDs: [UUID]? = nil,
                       settingKey: String? = nil,
                       settingJSON: String? = nil,
                       inserted: Bool? = nil,
                       planFile: String? = nil,
                       planSHA256: String? = nil,
                       error: String? = nil) throws -> C07JournalRecord {
        sequence += 1
        let record = C07JournalRecord(
            restoreID: restoreID, sequence: sequence, kind: kind,
            operationID: operationID, operation: operation,
            projectID: projectID, marker: marker, finalName: finalName,
            notebookID: notebookID, documentIDs: documentIDs,
            settingKey: settingKey, settingJSON: settingJSON,
            inserted: inserted, planFile: planFile, planSHA256: planSHA256,
            error: error)
        guard let handle else {
            throw C07DataExchangeError.storageUnavailable("journalClosed")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(record)
        data.append(0x0A)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            throw C07DataExchangeError.storageUnavailable("journalWrite")
        }
        return record
    }

    public func close() {
        try? handle?.close()
        handle = nil
    }

    public func synchronize() {
        try? handle?.synchronize()
    }
}

public enum C07JournalReader {
    public struct View: Sendable {
        public var url: URL
        public var records: [C07JournalRecord]
        public var isComplete: Bool
        public var isRolledBack: Bool
        public var isCorrupt: Bool
    }

    public static func load(_ url: URL) -> View {
        let data = (try? Data(contentsOf: url)) ?? Data()
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [C07JournalRecord] = []
        var corrupt = false
        for (index, line) in lines.enumerated() {
            do {
                records.append(try decoder.decode(C07JournalRecord.self, from: Data(line)))
            } catch {
                // A crash may leave exactly the final line incomplete. Any
                // earlier undecodable record is a corrupt journal: recovery
                // still attempts the safe marker/identity rollback from the
                // records it did read, and reports the corruption.
                if index != lines.count - 1 { corrupt = true }
            }
        }
        let kinds = Set(records.map(\.kind))
        return View(url: url, records: records,
                    isComplete: kinds.contains(.complete),
                    isRolledBack: kinds.contains(.rolledBack),
                    isCorrupt: corrupt)
    }

    public static func pending(in root: URL) -> [View] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return items
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(load)
            .filter { !$0.isComplete && !$0.isRolledBack }
    }
}

// MARK: - Sink

public struct C07NoteImportReceipt: Sendable, Equatable {
    public var documentIDs: [UUID]
    public var resourceCount: Int
    public var warnings: [String]

    public init(documentIDs: [UUID], resourceCount: Int, warnings: [String] = []) {
        self.documentIDs = documentIDs
        self.resourceCount = resourceCount
        self.warnings = warnings
    }
}

/// All live mutations a restore may perform. Implementations own the trusted
/// root and must never accept a caller path. Each method is idempotent or is
/// paired with a journal marker that makes retry safe.
public protocol C07RestoreSink: Sendable {
    func createProject(markerName: String, origin: C07ProjectOrigin) async throws -> UUID
    func renameProject(id: UUID, to finalName: String) async throws
    func writeProjectFiles(projectID: UUID,
                           directories: [String],
                           files: [C07StagedProjectFile]) async throws
    func deleteProject(id: UUID) async throws
    func deleteProjects(markedName: String) async throws -> Int

    func createNotebook(markerTitle: String) async throws -> UUID
    func renameNotebook(id: UUID, to finalTitle: String) async throws
    func deleteEmptyNotebook(id: UUID) async throws
    func deleteEmptyNotebooks(markedTitle: String) async throws -> Int

    func importNoteArchive(_ archive: C07ParsedNoteArchive,
                           notebookID: UUID?) async throws -> C07NoteImportReceipt
    func removeNotes(documentIDs: [UUID]) async throws

    func insertSettingIfAbsent(key: String, json: String) async throws -> Bool
    func removeSettingIfExact(key: String, json: String) async throws

    /// Plans the full owned-data graph (new identities, artifact roots and
    /// attachment paths) and writes the durable rollback plan BEFORE any
    /// live mutation. Read-only with respect to live storage.
    func prepareOwnedData(_ staged: C07StagedOwnedData,
                          projectMap: [UUID: UUID],
                          restoreID: UUID,
                          journalRoot: URL) async throws -> C07PreparedOwnedData
    /// Copies Canvas/media/attachment/private-task/receipt bytes into
    /// app-private destinations. The plan already lists every root for
    /// reverse cleanup.
    func commitArtifacts(_ prepared: C07PreparedOwnedData) async throws
        -> C07ArtifactCommitReceipt
    /// Inserts every live row in ONE GRDB writer transaction. Rows are
    /// already normalized for no-replay semantics and identity-remapped.
    func commitOwnedData(_ prepared: C07PreparedOwnedData,
                         artifacts: C07ArtifactCommitReceipt) async throws
        -> C07OwnedDataCommitReceipt
    /// Idempotent reverse cleanup: exact inserted identities and exact
    /// created artifact roots only.
    func rollbackOwnedData(planURL: URL, planSHA256: String) async throws
}

// MARK: - Engine

public struct C07RestoreReceipt: Sendable, Equatable {
    public var restoreID: UUID
    public var projectsRestored: Int
    public var projectsSkipped: Int
    public var notebooksRestored: Int
    public var noteDocumentsRestored: Int
    public var noteResourcesRestored: Int
    public var settingsInserted: Int
    public var settingsSkipped: Int
    public var conversationsRestored: Int
    public var messagesRestored: Int
    public var runsRestored: Int
    public var toolCallsRestored: Int
    public var workspacesRestored: Int
    public var schedulesRestored: Int
    public var providersRestored: Int
    public var canvasProjectsRestored: Int
    public var mediaProjectsRestored: Int
    public var mediaAssetsRestored: Int
    public var mailReceiptsRestored: Int
    public var evidenceRowsRestored: Int
    public var todosRestored: Int
    public var toolResultsRestored: Int
    public var appArtifactsRestored: Int
    public var captureFilesRestored: Int
    public var cadPreservedRestored: Int
    public var configSectionsRestored: Int
    // 2026-11-02 user-data expansion receipts.
    public var memoryEntriesRestored: Int = 0
    public var memoryCandidatesRestored: Int = 0
    public var personalizationDocumentsRestored: Int = 0
    public var personalizationCursorsRestored: Int = 0
    public var checklistRevisionsRestored: Int = 0
    public var skillsRestored: Int = 0
    public var modelPreferencesRestored: Int = 0
    public var partial: Bool
    public var omissions: Int
    public var warnings: [String]
    public var journalURL: URL
}

public enum C07RestoreEngine {
    public static func commit(plan: C07RestorePlan,
                              sink: C07RestoreSink,
                              journalRoot: URL,
                              progress: (@Sendable (Int, Int) -> Void)? = nil) async throws
        -> C07RestoreReceipt
    {
        let journal = try C07RestoreJournal(root: journalRoot)
        var warnings = plan.warnings
        do {
            try journal.append(kind: .begin,
                               error: "manifest=\(plan.manifestSHA256)")
            var projectsRestored = 0
            var projectsSkipped = 0
            var notebooksRestored = 0
            var noteDocumentsRestored = 0
            var noteResourcesRestored = 0
            var settingsInserted = 0
            var settingsSkipped = 0
            var ownedReceipt: C07OwnedDataCommitReceipt?
            var artifactReceipt: C07ArtifactCommitReceipt?

            let totalOps = plan.projects.count + plan.manifest.notes.notebooks.count
                + plan.notes.count + plan.settingsValues.count
                + (plan.ownedData == nil ? 0 : 2)
            var completedOps = 0
            progress?(0, totalOps)

            // Projects first: new UUID ownership makes every file destination
            // non-colliding with an existing live project.
            var projectMap: [UUID: UUID] = [:]
            for project in plan.projects {
                if project.restoreSkipped {
                    projectsSkipped += 1
                    warnings.append("projectNotRestored:\(project.record.name)")
                    completedOps += 1
                    progress?(completedOps, totalOps)
                    continue
                }
                let opID = UUID()
                let marker = markerName(prefix: "Floe restore", restoreID: journal.restoreID)
                try journal.append(kind: .intent, operationID: opID,
                                   operation: .project, marker: marker,
                                   finalName: project.record.name)
                let projectID = try await sink.createProject(
                    markerName: marker, origin: project.record.origin)
                try journal.append(kind: .projectCreated, operationID: opID,
                                   operation: .project, projectID: projectID,
                                   marker: marker, finalName: project.record.name)
                try await sink.renameProject(id: projectID, to: project.record.name)
                try journal.append(kind: .projectRenamed, operationID: opID,
                                   operation: .project, projectID: projectID,
                                   finalName: project.record.name)
                try await sink.writeProjectFiles(
                    projectID: projectID,
                    directories: project.record.directories,
                    files: project.files)
                try journal.append(kind: .filesWritten, operationID: opID,
                                   operation: .project, projectID: projectID)
                projectMap[project.record.projectID] = projectID
                projectsRestored += 1
                completedOps += 1
                progress?(completedOps, totalOps)
            }

            // Full owned-data graph. The durable plan names every new root
            // identity and artifact destination BEFORE the first mutation.
            if let owned = plan.ownedData {
                let prepared = try await sink.prepareOwnedData(
                    owned, projectMap: projectMap,
                    restoreID: journal.restoreID, journalRoot: journalRoot)
                try journal.append(
                    kind: .dataIntent, operation: .data,
                    planFile: prepared.planURL.lastPathComponent,
                    planSHA256: prepared.planSHA256)
                let artifacts = try await sink.commitArtifacts(prepared)
                artifactReceipt = artifacts
                try journal.append(
                    kind: .artifactsCommitted, operation: .data,
                    planFile: prepared.planURL.lastPathComponent,
                    planSHA256: prepared.planSHA256)
                let receipt = try await sink.commitOwnedData(
                    prepared, artifacts: artifacts)
                try journal.append(
                    kind: .dataCommitted, operation: .data,
                    planFile: prepared.planURL.lastPathComponent,
                    planSHA256: prepared.planSHA256)
                ownedReceipt = receipt
                warnings.append(contentsOf: artifacts.warnings)
                warnings.append(contentsOf: receipt.warnings)
                completedOps += 2
                progress?(completedOps, totalOps)
            }

            // Notebooks preserve the archived organization. A new notebook is
            // always created (restore never merges into an existing library).
            var notebookMap: [UUID: UUID] = [:]
            for notebook in plan.manifest.notes.notebooks {
                let opID = UUID()
                let marker = markerName(prefix: "Restored notes", restoreID: journal.restoreID)
                try journal.append(kind: .intent, operationID: opID,
                                   operation: .notebook, marker: marker,
                                   finalName: notebook.title)
                let id = try await sink.createNotebook(markerTitle: marker)
                try journal.append(kind: .notebookCreated, operationID: opID,
                                   operation: .notebook, marker: marker,
                                   finalName: notebook.title, notebookID: id)
                try await sink.renameNotebook(id: id, to: notebook.title)
                try journal.append(kind: .notebookRenamed, operationID: opID,
                                   operation: .notebook,
                                   finalName: notebook.title, notebookID: id)
                notebookMap[notebook.notebookID] = id
                notebooksRestored += 1
                completedOps += 1
                progress?(completedOps, totalOps)
            }

            // Notes documents: planned new identities are journaled BEFORE
            // NotesStore.createBundle, so recovery can delete them by exact id
            // even if the process dies before the receipt.
            for archive in plan.notes {
                let opID = UUID()
                let planned = archive.newDocumentIDs
                try journal.append(kind: .intent, operationID: opID,
                                   operation: .notes, documentIDs: planned)
                let notebookID = archive.documents.first?.original.notebookID
                    .flatMap { notebookMap[$0] }
                let receipt = try await sink.importNoteArchive(
                    archive, notebookID: notebookID)
                guard Set(receipt.documentIDs) == Set(planned) else {
                    throw C07DataExchangeError.notesArchive("identityMismatch")
                }
                try journal.append(kind: .notesCreated, operationID: opID,
                                   operation: .notes, documentIDs: receipt.documentIDs)
                noteDocumentsRestored += receipt.documentIDs.count
                noteResourcesRestored += receipt.resourceCount
                completedOps += 1
                progress?(completedOps, totalOps)
            }

            // Safe preferences are inserted only when the exact key is absent.
            for key in plan.settingsValues.keys.sorted() {
                let json = plan.settingsValues[key] ?? ""
                let opID = UUID()
                try journal.append(kind: .intent, operationID: opID,
                                   operation: .setting, settingKey: key,
                                   settingJSON: json)
                let inserted = try await sink.insertSettingIfAbsent(key: key, json: json)
                try journal.append(kind: .settingInserted, operationID: opID,
                                   operation: .setting, settingKey: key,
                                   settingJSON: json, inserted: inserted)
                if inserted { settingsInserted += 1 } else { settingsSkipped += 1 }
                completedOps += 1
                progress?(completedOps, totalOps)
            }

            try journal.append(kind: .complete)
            journal.close()
            return C07RestoreReceipt(
                restoreID: journal.restoreID,
                projectsRestored: projectsRestored,
                projectsSkipped: projectsSkipped,
                notebooksRestored: notebooksRestored,
                noteDocumentsRestored: noteDocumentsRestored,
                noteResourcesRestored: noteResourcesRestored,
                settingsInserted: settingsInserted,
                settingsSkipped: settingsSkipped,
                conversationsRestored: ownedReceipt?.conversations ?? 0,
                messagesRestored: ownedReceipt?.messages ?? 0,
                runsRestored: ownedReceipt?.runs ?? 0,
                toolCallsRestored: ownedReceipt?.toolCalls ?? 0,
                workspacesRestored: ownedReceipt?.workspaces ?? 0,
                schedulesRestored: ownedReceipt?.schedules ?? 0,
                providersRestored: ownedReceipt?.providers ?? 0,
                canvasProjectsRestored: artifactReceipt?.canvasProjects ?? 0,
                mediaProjectsRestored: artifactReceipt?.mediaProjects ?? 0,
                mediaAssetsRestored: artifactReceipt?.mediaAssets ?? 0,
                mailReceiptsRestored: artifactReceipt?.mailReceipts ?? 0,
                evidenceRowsRestored: artifactReceipt?.evidenceRows ?? 0,
                todosRestored: ownedReceipt?.todos ?? 0,
                toolResultsRestored: artifactReceipt?.toolResults ?? 0,
                appArtifactsRestored: artifactReceipt?.appArtifacts ?? 0,
                captureFilesRestored: artifactReceipt?.captureFiles ?? 0,
                cadPreservedRestored: artifactReceipt?.cadPreservedFiles ?? 0,
                configSectionsRestored: artifactReceipt?.configSections ?? 0,
                memoryEntriesRestored: ownedReceipt?.memoryEntries ?? 0,
                memoryCandidatesRestored: ownedReceipt?.memoryCandidates ?? 0,
                personalizationDocumentsRestored:
                    ownedReceipt?.personalizationDocuments ?? 0,
                personalizationCursorsRestored:
                    ownedReceipt?.personalizationCursors ?? 0,
                checklistRevisionsRestored: ownedReceipt?.checklistRevisions ?? 0,
                skillsRestored: ownedReceipt?.skills ?? 0,
                modelPreferencesRestored: ownedReceipt?.modelPreferences ?? 0,
                partial: ownedReceipt?.partial ?? false,
                omissions: ownedReceipt?.omissions ?? 0,
                warnings: warnings,
                journalURL: journal.url)
        } catch {
            let errorCode = (error as? C07DataExchangeError)?.code ?? "internal"
            try? journal.append(kind: .failed, error: errorCode)
            do {
                _ = try await C07RestoreRollback.rollback(
                    records: journalSnapshot(journal), sink: sink,
                    journalRoot: journalRoot)
                try? journal.append(kind: .rolledBack,
                                    error: "afterFailure:\(errorCode)")
            } catch {
                try? journal.append(kind: .rollbackFailed,
                                    error: "rollback")
                journal.close()
                throw C07DataExchangeError.rollbackFailed(errorCode)
            }
            journal.close()
            throw error
        }
    }

    /// Reads back the just-written lines. The writer handle is still open, so
    /// reopen the path rather than holding bytes in memory.
    private static func journalSnapshot(_ journal: C07RestoreJournal) -> [C07JournalRecord] {
        journal.synchronize()
        return C07JournalReader.load(journal.url).records
    }

    private static func markerName(prefix: String, restoreID: UUID) -> String {
        let short = restoreID.uuidString.prefix(8)
        return "\(prefix) \(short)"
    }
}

// MARK: - Rollback and recovery

public struct C07RecoveryReport: Sendable, Equatable {
    public var recoveredJournals: Int
    public var failedJournals: Int
    public var details: [String]
}

public enum C07RestoreRollback {
    /// Reverse-order, idempotent rollback from the durable records. Marker
    /// deletion covers an intent whose receipt never landed; exact receipts
    /// cover the normal case.
    public static func rollback(records: [C07JournalRecord],
                                sink: C07RestoreSink,
                                journalRoot: URL) async throws -> Int {
        var actions = 0
        var failures: [String] = []
        var seenNotes = Set<UUID>()
        var seenProjects = Set<UUID>()
        var seenNotebooks = Set<UUID>()
        var seenSettings = Set<String>()
        var seenDataPlans = Set<String>()

        for record in records.sorted(by: { $0.sequence > $1.sequence }) {
            do {
                switch record.operation {
                case .project:
                    if let id = record.projectID, seenProjects.insert(id).inserted {
                        try await sink.deleteProject(id: id)
                        actions += 1
                    } else if record.kind == .intent, let marker = record.marker {
                        actions += try await sink.deleteProjects(markedName: marker)
                    }
                case .notebook:
                    if let id = record.notebookID, seenNotebooks.insert(id).inserted {
                        try await sink.deleteEmptyNotebook(id: id)
                        actions += 1
                    } else if record.kind == .intent, let marker = record.marker {
                        actions += try await sink.deleteEmptyNotebooks(markedTitle: marker)
                    }
                case .notes:
                    if let ids = record.documentIDs {
                        let fresh = ids.filter { seenNotes.insert($0).inserted }
                        if !fresh.isEmpty {
                            try await sink.removeNotes(documentIDs: fresh)
                            actions += fresh.count
                        }
                    }
                case .setting:
                    // Only a confirmed insertion is removed. An unconfirmed
                    // intent may be a pre-existing equal value; deleting it
                    // would be worse than leaving a safe preference.
                    if record.kind == .settingInserted,
                       record.inserted == true,
                       let key = record.settingKey,
                       let json = record.settingJSON,
                       seenSettings.insert(key).inserted {
                        try await sink.removeSettingIfExact(key: key, json: json)
                        actions += 1
                    }
                case .data:
                    if let planFile = record.planFile,
                       seenDataPlans.insert(planFile).inserted {
                        let url = journalRoot.appendingPathComponent(planFile)
                        if let sha = record.planSHA256 {
                            try await sink.rollbackOwnedData(
                                planURL: url, planSHA256: sha)
                            actions += 1
                        }
                    }
                case .none:
                    break
                }
            } catch {
                failures.append(record.kind.rawValue)
            }
        }
        if !failures.isEmpty {
            throw C07DataExchangeError.rollbackFailed(failures.prefix(4).joined(separator: ","))
        }
        return actions
    }
}

public enum C07RestoreRecovery {
    public static func pendingCount(journalRoot: URL) -> Int {
        C07JournalReader.pending(in: journalRoot).count
    }

    /// Called before any new restore. Every incomplete journal is rolled back
    /// with the same reverse-order rules; a journal that remains failed stays
    /// pending and is reported truthfully.
    public static func recover(journalRoot: URL,
                               sink: C07RestoreSink) async -> C07RecoveryReport {
        var recovered = 0
        var failed = 0
        var details: [String] = []
        for view in C07JournalReader.pending(in: journalRoot) {
            if view.isCorrupt { details.append("corruptJournal") }
            if view.records.isEmpty {
                // No durable intent was written, so no component can have
                // been created by this journal. Retain the bytes under a
                // non-active name instead of retrying forever.
                let abandoned = view.url.appendingPathExtension("abandoned")
                try? FileManager.default.moveItem(at: view.url, to: abandoned)
                recovered += 1
                continue
            }
            do {
                _ = try await C07RestoreRollback.rollback(
                    records: view.records, sink: sink,
                    journalRoot: journalRoot)
                if let journal = C07RestoreJournal(existingURL: view.url) {
                    try? journal.append(kind: .rolledBack, error: "recovery")
                    journal.close()
                }
                recovered += 1
            } catch {
                failed += 1
                details.append("rollbackFailed")
            }
        }
        return C07RecoveryReport(recoveredJournals: recovered,
                                 failedJournals: failed,
                                 details: details)
    }
}
