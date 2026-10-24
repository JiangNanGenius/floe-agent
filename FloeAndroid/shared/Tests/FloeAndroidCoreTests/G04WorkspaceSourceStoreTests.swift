// SPDX-License-Identifier: MPL-2.0
// Real original DB transactions and file-backed reopen; no model/network.
import Foundation
import Testing
import FloeModels
import FloePersistence

private func withG04SourceDatabase(
    _ body: @Sendable (DatabaseManager, URL, UUID) async throws -> Void
) async throws {
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let parent = ProcessInfo.processInfo.environment["FLOE_G04_TEST_ROOT"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    } ?? package.appendingPathComponent(".build/test-fixtures/g04-sources", isDirectory: true)
    let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let path = root.appendingPathComponent("original.sqlite")
    let database = try DatabaseManager(path: path)
    do {
        try await database.migrate()
        let workspaceID = UUID()
        try await SQLiteWorkspaceStore(database: database).saveWorkspace(
            WorkspaceRecord(id: workspaceID, name: "Synthetic source fixture", rootBookmark: Data()))
        try await body(database, path, workspaceID)
        try? await database.close()
        try FileManager.default.removeItem(at: root)
    } catch {
        try? await database.close()
        try? FileManager.default.removeItem(at: root)
        throw error
    }
}

private let g04OriginalSHA = String(repeating: "a", count: 64)
private let g04ReplacementSHA = String(repeating: "b", count: 64)

struct G04WorkspaceSourceStoreTests {
    @Test func durableReceiptReopensAndReadbackCommitsBindingAtomically() async throws {
        try await withG04SourceDatabase { database, path, workspaceID in
            let sourceID = UUID(), receiptID = UUID()
            let store = AndroidWorkspaceSourceStore(database: database)
            let source = try await store.bind(id: sourceID, workspaceID: workspaceID, logicalPath: "Imported/main.kt",
                kind: .saf, sourceReference: "content://example.fixture/tree/12/document/34",
                sourceDocumentID: "34", sourceSHA256: g04OriginalSHA)
            let prepared = try await store.prepareRecovery(id: receiptID, sourceID: source.id,
                expectedRevision: source.revision, backupRelativePath: "Recovery/owned-backup.bin",
                backupSHA256: g04OriginalSHA, replacementSHA256: g04ReplacementSHA)
            #expect(prepared.state == .prepared)
            let replay = try await store.prepareRecovery(id: receiptID, sourceID: source.id,
                expectedRevision: source.revision, backupRelativePath: "Recovery/owned-backup.bin",
                backupSHA256: g04OriginalSHA, replacementSHA256: g04ReplacementSHA)
            #expect(replay == prepared)
            try await database.close()
            let reopened = try DatabaseManager(path: path)
            do {
                try await reopened.migrate()
                #expect(try await reopened.userVersion() == DatabaseManager.currentSchemaVersion)
                let recoveredStore = AndroidWorkspaceSourceStore(database: reopened)
                #expect(try await recoveredStore.pendingRecovery(workspaceID: workspaceID) == [prepared])
                let claimed = try await recoveredStore.claimRecovery(id: receiptID, observedSourceSHA256: g04OriginalSHA)
                #expect(claimed.state == .writing)
                do {
                    _ = try await recoveredStore.claimRecovery(id: receiptID, observedSourceSHA256: g04OriginalSHA)
                    Issue.record("Same durable receipt issued a duplicate write permit")
                } catch AndroidWorkspaceSourceError.invalidTransition { }
                let committed = try await recoveredStore.finishRecovery(id: receiptID, requestedState: .committed,
                                                                         observedSHA256: g04ReplacementSHA)
                #expect(committed.state == .committed)
                let updated = try #require(try await recoveredStore.source(id: sourceID))
                #expect(updated.revision != source.revision && updated.sourceSHA256 == g04ReplacementSHA)
                #expect(try await recoveredStore.pendingRecovery(workspaceID: workspaceID).isEmpty)
                try await reopened.close()
            } catch { try? await reopened.close(); throw error }
        }
    }

    @Test func simultaneousPreparesDoNotAdmitTwoWritersAndRebindCannotRacePermit() async throws {
        try await withG04SourceDatabase { database, _, workspaceID in
            let store = AndroidWorkspaceSourceStore(database: database)
            let source = try await store.bind(id: UUID(), workspaceID: workspaceID, logicalPath: "file.txt",
                kind: .webdav, sourceReference: UUID().uuidString, sourceSHA256: g04OriginalSHA)
            let winners = try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        do {
                            _ = try await store.prepareRecovery(id: UUID(), sourceID: source.id,
                                expectedRevision: source.revision, backupRelativePath: "Recovery/\(UUID().uuidString)",
                                backupSHA256: g04OriginalSHA, replacementSHA256: g04ReplacementSHA)
                            return true
                        } catch AndroidWorkspaceSourceError.invalidTransition { return false }
                    }
                }
                var result = 0
                for try await won in group { if won { result += 1 } }
                return result
            }
            #expect(winners == 1)
            do {
                _ = try await store.bind(id: source.id, workspaceID: workspaceID, logicalPath: source.logicalPath,
                    kind: .webdav, sourceReference: UUID().uuidString, sourceSHA256: g04OriginalSHA,
                    expectedRevision: source.revision)
                Issue.record("Rebind raced an outstanding write permit")
            } catch AndroidWorkspaceSourceError.invalidTransition { }
            let pending = try await store.pendingRecovery(workspaceID: workspaceID)
            #expect(pending.count == 1)
            let retained = try await store.finishRecovery(id: try #require(pending.first).id,
                                                          requestedState: .retained, observedSHA256: nil)
            #expect(retained.state == .retained)
            #expect(try await store.source(id: source.id) == source)
        }
    }

    @Test func mismatchAndInvalidMetadataCannotOverwriteSourceOrRecovery() async throws {
        try await withG04SourceDatabase { database, _, workspaceID in
            let store = AndroidWorkspaceSourceStore(database: database)
            let source = try await store.bind(id: UUID(), workspaceID: workspaceID, logicalPath: "safe.txt",
                kind: .saf, sourceReference: "content://example.fixture/document/34", sourceSHA256: g04OriginalSHA)
            let conflict = try await store.prepareRecovery(id: UUID(), sourceID: source.id,
                expectedRevision: source.revision, backupRelativePath: "Recovery/external-change.bin",
                backupSHA256: g04ReplacementSHA, replacementSHA256: g04ReplacementSHA)
            #expect(conflict.state == .conflict)
            do {
                _ = try await store.finishRecovery(id: conflict.id, requestedState: .committed,
                                                    observedSHA256: g04ReplacementSHA)
                Issue.record("Conflicting source obtained committed state")
            } catch AndroidWorkspaceSourceError.invalidTransition { }
            for path in ["../escape", "/absolute", "./alias", "double//alias"] {
                do {
                    _ = try await store.bind(id: UUID(), workspaceID: workspaceID, logicalPath: path,
                        kind: .smb, sourceReference: UUID().uuidString, sourceSHA256: g04OriginalSHA)
                    Issue.record("Noncanonical source path accepted")
                } catch AndroidWorkspaceSourceError.invalidMetadata { }
            }
            do {
                _ = try await store.bind(id: UUID(), workspaceID: workspaceID, logicalPath: "secret.txt",
                    kind: .webdav, sourceReference: "https://user:secret@example.invalid/file", sourceSHA256: g04OriginalSHA)
                Issue.record("Credential URL accepted instead of opaque connection reference")
            } catch AndroidWorkspaceSourceError.invalidMetadata { }
            #expect(try await store.source(id: source.id) == source)
            #expect(try await store.pendingRecovery(workspaceID: workspaceID) == [conflict])
            try await SQLiteWorkspaceStore(database: database).deleteWorkspace(id: workspaceID)
            #expect(try await store.source(id: source.id) == nil)
            #expect(try await store.pendingRecovery(workspaceID: workspaceID) == [conflict])
        }
    }
}
