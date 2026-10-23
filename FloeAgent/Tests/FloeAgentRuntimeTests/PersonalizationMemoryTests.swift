import Foundation
import Testing
import GRDB
@testable import FloeAgentRuntime
@testable import FloePersistence

@Suite("FloeAgentRuntime.PersonalizationMemory")
struct PersonalizationMemoryTests {
    private struct FixedGenerator: PersonalizationGenerator {
        let content: String
        func generate(_ request: PersonalizationGenerationRequest) async throws
            -> PersonalizationGenerationResult {
            PersonalizationGenerationResult(content: content, evidenceDigest: "fixed")
        }
    }

    /// Suspends the generator after it captured the lane state, until the
    /// test performs an intervening manual save. Models the real race:
    /// generation in flight while the user edits.
    private actor GenerationGate {
        private var started = false
        private var manualSaveFinished = false
        func markStarted() { started = true }
        func awaitStarted() async {
            while !started { try? await Task.sleep(for: .milliseconds(2)) }
        }
        func waitForManualSave() async {
            while !manualSaveFinished { try? await Task.sleep(for: .milliseconds(2)) }
        }
        func finishManualSave() { manualSaveFinished = true }
    }

    private struct GatedGenerator: PersonalizationGenerator {
        let gate: GenerationGate
        let content: String
        func generate(_ request: PersonalizationGenerationRequest) async throws
            -> PersonalizationGenerationResult {
            await gate.markStarted()
            await gate.waitForManualSave()
            return PersonalizationGenerationResult(content: content, evidenceDigest: "gated")
        }
    }

    /// Deterministic execution fence: the test body parks the worker task
    /// until the harness has requested cancellation, so "live" and
    /// "cancelled" contexts never depend on wall-clock luck.
    private actor FenceFlag {
        private var entered = false
        private var released = false
        func markEntered() { entered = true }
        func awaitEntered() async {
            while !entered { try? await Task.sleep(for: .milliseconds(2)) }
        }
        func waitUntilReleased() async {
            while !released { try? await Task.sleep(for: .milliseconds(2)) }
        }
        func release() { released = true }
    }

    private func retainedRowCount(_ database: DatabaseManager, kind: PersonalizationDocumentKind,
                                  workspaceID: UUID? = nil) async throws -> Int {
        try await database.reader { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM personalization_documents
                WHERE kind = ? AND workspace_id IS ?
                """, arguments: [kind.rawValue, workspaceID?.uuidString]) ?? -1
        }
    }

    @Test("Live personalization follows active workspace overrides, restore and removal")
    func liveSnapshotTracksActiveRevisions() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLitePersonalizationStore(database: database)
        let workspace = UUID()
        try await SQLiteWorkspaceStore(database: database).saveWorkspace(.init(id: workspace, name: "Preferences fixture", rootBookmark: Data()))
        _ = try await store.applyCurrent(kind: .soul, workspaceID: nil, content: "global-style",
            source: .manual, evidenceDigest: "", expectedRevision: nil, now: Date())
        _ = try await store.applyCurrent(kind: .userProfile, workspaceID: nil, content: "global-profile",
            source: .manual, evidenceDigest: "", expectedRevision: nil, now: Date())
        _ = try await store.applyCurrent(kind: .soul, workspaceID: workspace, content: "project-style",
            source: .manual, evidenceDigest: "", expectedRevision: nil, now: Date())
        #expect(try await store.liveSnapshot(workspaceID: workspace) == .init(soul: "project-style", profile: "global-profile"))
        #expect(try await store.liveSnapshot(workspaceID: UUID()) == .init(soul: "global-style", profile: "global-profile"))
        _ = try await store.applyCurrent(kind: .userProfile, workspaceID: nil, content: "updated-profile",
            source: .manual, evidenceDigest: "", expectedRevision: nil, now: Date())
        #expect(try await store.liveSnapshot(workspaceID: workspace).profile == "updated-profile")
        try await database.writer { db in
            try db.execute(sql: "DELETE FROM personalization_documents WHERE workspace_id = ?", arguments: [workspace.uuidString])
        }
        #expect(try await store.liveSnapshot(workspaceID: workspace).soul == "global-style")
        try await database.writer { db in try db.execute(sql: "DELETE FROM personalization_documents") }
        #expect(try await store.liveSnapshot(workspaceID: workspace) == .init(soul: nil, profile: nil))
    }

    @Test("cosine similarity rejects incompatible spaces")
    func vectorMath() {
        #expect(MemoryVectorMath.cosineSimilarity([1, 0], [1, 0]) == 1)
        #expect(MemoryVectorMath.cosineSimilarity([1, 0], [0, 1]) == 0)
        #expect(MemoryVectorMath.cosineSimilarity([1], [1, 2]) == nil)
        #expect(MemoryVectorMath.cosineSimilarity([], []) == nil)
    }

    @Test("low-frequency cadence requires both elapsed time and activity")
    func cadence() {
        let cadence = PersonalizationUpdateCadence()
        let now = Date(timeIntervalSince1970: 2_000_000)
        var cursor = PersonalizationUpdateCursor(kind: .userProfile,
            lastGeneratedAt: now.addingTimeInterval(-8 * 86_400),
            completedRunsSinceUpdate: 9, userMessagesSinceUpdate: 29)
        #expect(!cadence.isDue(cursor, now: now))
        cursor.completedRunsSinceUpdate = 10
        #expect(cadence.isDue(cursor, now: now))
        cursor.lastGeneratedAt = now.addingTimeInterval(-86_400)
        #expect(!cadence.isDue(cursor, now: now))
    }

    @Test("each lane retains at most current plus one activated backup across rotations")
    func boundedRetentionRotatesAndTrims() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let documentStore = SQLitePersonalizationStore(database: database)
        let first = try await documentStore.applyCurrent(kind: .soul, workspaceID: nil,
            content: "first", source: .manual, evidenceDigest: "",
            expectedRevision: nil, now: Date())
        let second = try await documentStore.applyCurrent(kind: .soul, workspaceID: nil,
            content: "second", source: .manual, evidenceDigest: "",
            expectedRevision: nil, now: Date())
        let third = try await documentStore.applyCurrent(kind: .soul, workspaceID: nil,
            content: "third", source: .oneClick, evidenceDigest: "",
            expectedRevision: nil, now: Date())
        let revisions: [Int] = [first.document.revision, second.document.revision, third.document.revision]
        #expect(revisions == [1, 2, 3])

        var retention = try await documentStore.retention(kind: .soul, workspaceID: nil)
        #expect(retention.current?.content == "third")
        #expect(retention.previous?.content == "second")
        // The superseded backup ("first") is pruned: exactly two rows remain.
        #expect(try await retainedRowCount(database, kind: .soul) == 2)

        // Restoring applies the backup content as a FRESH monotonic revision
        // (never reactivating the old row/token) and keeps the replaced
        // current as the single backup.
        let restored = try await documentStore.restorePrevious(kind: .soul, workspaceID: nil)
        #expect(restored.content == "second")
        #expect(restored.revision == 4)
        #expect(restored.source == .rollback)
        retention = try await documentStore.retention(kind: .soul, workspaceID: nil)
        #expect(retention.current?.content == "second")
        #expect(retention.current?.revision == 4)
        #expect(retention.previous?.content == "third")
        #expect(retention.previous?.revision == 3)
        #expect(try await retainedRowCount(database, kind: .soul) == 2)

        // The allocator is monotonic across the restore: the next revision
        // keeps increasing above every number ever handed out.
        let fourth = try await documentStore.applyCurrent(kind: .soul, workspaceID: nil,
            content: "fourth", source: .manual, evidenceDigest: "",
            expectedRevision: nil, now: Date())
        #expect(fourth.document.revision == 5)
        #expect(fourth.didCreateRevision)
        retention = try await documentStore.retention(kind: .soul, workspaceID: nil)
        #expect(retention.current?.content == "fourth")
        #expect(retention.previous?.content == "second")
        #expect(try await retainedRowCount(database, kind: .soul) == 2)
    }

    @Test("update then restore cannot reopen a stale editor's CAS window")
    func staleEditorFencedAcrossUpdateAndRestore() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let documentStore = SQLitePersonalizationStore(database: database)
        let memoryStore = SQLiteIntelligenceStore(database: database)
        let service = PersonalizationService(documents: documentStore, memories: memoryStore)
        // The editor loads revision 1 and starts typing.
        _ = try await service.saveManual(kind: .soul, content: "v1", expectedRevision: 0)
        // A silent automatic update rotates the lane…
        _ = try await documentStore.applyCurrent(kind: .soul, workspaceID: nil,
            content: "automatic-v2", source: .automatic, evidenceDigest: "",
            expectedRevision: nil, now: Date())
        // …and a restore then brings v1's CONTENT back under a NEW revision.
        let restored = try await service.restorePrevious(kind: .soul)
        #expect(restored.content == "v1")
        #expect(restored.revision == 3)
        // The stale editor still holds revision 1 — reactivated content must
        // not make its old token valid again.
        await #expect(throws: PersonalizationLifecycleFailure.revisionConflict(currentRevision: 3)) {
            _ = try await service.saveManual(kind: .soul, content: "stale-editor-text",
                expectedRevision: 1)
        }
        let retention = try await documentStore.retention(kind: .soul, workspaceID: nil)
        #expect(retention.current?.content == "v1")
        #expect(retention.current?.revision == 3)
        #expect(retention.previous?.content == "automatic-v2")
    }

    @Test("restoring into an emptied lane mints a fresh current; equal content is a no-op")
    func restoreEdgeCases() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let documentStore = SQLitePersonalizationStore(database: database)
        _ = try await documentStore.applyCurrent(kind: .soul, workspaceID: nil, content: "solo",
            source: .manual, evidenceDigest: "", expectedRevision: nil, now: Date())
        _ = try await documentStore.applyCurrent(kind: .soul, workspaceID: nil, content: "next",
            source: .manual, evidenceDigest: "", expectedRevision: nil, now: Date())
        // Remove the current row externally (legacy/empty-lane shape).
        try await database.writer { db in
            try db.execute(sql: """
                DELETE FROM personalization_documents WHERE lifecycle = 'current'
                """)
        }
        let revived = try await documentStore.restorePrevious(kind: .soul, workspaceID: nil)
        #expect(revived.content == "solo")
        #expect(revived.revision == 3)
        let revivedRetention = try await documentStore.retention(kind: .soul, workspaceID: nil)
        #expect(revivedRetention.current?.id == revived.id)
        #expect(revivedRetention.previous == nil)
        // Force the backup to equal the current content: restore is a no-op
        // that keeps the live revision token untouched.
        _ = try await documentStore.applyCurrent(kind: .soul, workspaceID: nil, content: "solo-x",
            source: .manual, evidenceDigest: "", expectedRevision: 3, now: Date())
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE personalization_documents SET content = 'solo-x'
                WHERE lifecycle = 'previous'
                """)
        }
        let unchanged = try await documentStore.restorePrevious(kind: .soul, workspaceID: nil)
        #expect(unchanged.revision == 4)
        #expect(unchanged.content == "solo-x")
        let lastRevision = try await database.reader { db in
            try Int.fetchOne(db, sql: """
                SELECT last_revision FROM personalization_revision_sequences
                WHERE kind = 'soul' AND workspace_key = ''
                """) ?? -1
        }
        #expect(lastRevision == 4)
    }

    @Test("identical content creates no new revision and keeps both slots")
    func sameContentCreatesNoHistory() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let documentStore = SQLitePersonalizationStore(database: database)
        let first = try await documentStore.applyCurrent(kind: .soul, workspaceID: nil,
            content: "stable text", source: .manual, evidenceDigest: "",
            expectedRevision: nil, now: Date())
        let repeated = try await documentStore.applyCurrent(kind: .soul, workspaceID: nil,
            content: "  stable text \n", source: .manual, evidenceDigest: "",
            expectedRevision: nil, now: Date())
        #expect(first.didCreateRevision)
        #expect(!repeated.didCreateRevision)
        #expect(repeated.document.id == first.document.id)
        #expect(try await retainedRowCount(database, kind: .soul) == 1)
        let retention = try await documentStore.retention(kind: .soul, workspaceID: nil)
        #expect(retention.current?.content == "stable text")
        #expect(retention.previous == nil)
    }

    @Test("a stale manual save is fenced by revision CAS without touching the lane")
    func manualEditCASRejectsStaleWrite() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let documentStore = SQLitePersonalizationStore(database: database)
        let memoryStore = SQLiteIntelligenceStore(database: database)
        let service = PersonalizationService(documents: documentStore, memories: memoryStore)
        _ = try await service.saveManual(kind: .soul, content: "v1", expectedRevision: 0)
        _ = try await service.saveManual(kind: .soul, content: "v2", expectedRevision: 1)
        // The editor still holds v1's revision; the write must not clobber v2.
        await #expect(throws: PersonalizationLifecycleFailure.revisionConflict(currentRevision: 2)) {
            _ = try await service.saveManual(kind: .soul, content: "stale-editor-draft",
                expectedRevision: 1)
        }
        let retention = try await documentStore.retention(kind: .soul, workspaceID: nil)
        #expect(retention.current?.content == "v2")
        #expect(retention.previous?.content == "v1")
        // A fresh CAS still succeeds.
        _ = try await service.saveManual(kind: .soul, content: "v3", expectedRevision: 2)
        #expect(try await documentStore.activeDocument(kind: .soul, workspaceID: nil)?.content == "v3")
    }

    @Test("manual save into a lane that appeared since first load conflicts at revision 0")
    func manualSaveFromEmptyLaneUsesRevisionZero() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let documentStore = SQLitePersonalizationStore(database: database)
        _ = try await documentStore.applyCurrent(kind: .soul, workspaceID: nil, content: "auto",
            source: .automatic, evidenceDigest: "", expectedRevision: nil, now: Date())
        await #expect(throws: PersonalizationLifecycleFailure.revisionConflict(currentRevision: 1)) {
            try await documentStore.applyCurrent(kind: .soul, workspaceID: nil,
                content: "typed-into-empty-editor", source: .manual, evidenceDigest: "",
                expectedRevision: 0, now: Date())
        }
        #expect(try await documentStore.activeDocument(kind: .soul, workspaceID: nil)?.content == "auto")
    }

    @Test("explicit generation cannot overwrite a manual save that landed while the model ran")
    func lateGenerationCannotReplaceManualEdit() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let documentStore = SQLitePersonalizationStore(database: database)
        let memoryStore = SQLiteIntelligenceStore(database: database)
        let service = PersonalizationService(documents: documentStore, memories: memoryStore)
        let gate = GenerationGate()
        let generation = Task {
            try await service.generateNow(kind: .soul,
                generator: GatedGenerator(gate: gate, content: "late-generation-output"))
        }
        await gate.awaitStarted()
        _ = try await service.saveManual(kind: .soul, content: "manual-first", expectedRevision: 0)
        await gate.finishManualSave()
        await #expect(throws: PersonalizationLifecycleFailure.revisionConflict(currentRevision: 1)) {
            _ = try await generation.value
        }
        let retention = try await documentStore.retention(kind: .soul, workspaceID: nil)
        #expect(retention.current?.content == "manual-first")
        #expect(retention.previous == nil)
    }

    @Test("background cadence update applies silently over the current document")
    func substantialAutomaticUpdateAppliesSilently() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let documentStore = SQLitePersonalizationStore(database: database)
        let memoryStore = SQLiteIntelligenceStore(database: database)
        let service = PersonalizationService(documents: documentStore, memories: memoryStore)
        let original = try await service.saveManual(kind: .userProfile, content: "# Profile\n- concise")
        try await service.recordActivity(completedRuns: 10)
        let rewrite = String(repeating: "new profile detail\n", count: 80)
        // The store normalizes surrounding whitespace for manual and generated
        // content alike; the silent application contract concerns that content.
        let expectedContent = rewrite.trimmingCharacters(in: .whitespacesAndNewlines)
        let applied = try #require(await service.generateIfDue(kind: .userProfile,
            generator: FixedGenerator(content: rewrite)))
        // No review step: the rewrite is now the live current document.
        #expect(applied.content == expectedContent)
        #expect(applied.source == .automatic)
        let retention = try await documentStore.retention(kind: .userProfile, workspaceID: nil)
        #expect(retention.current?.id == applied.id)
        #expect(retention.previous?.id == original.id)
        #expect(try await retainedRowCount(database, kind: .userProfile) == 2)
        #expect(try await documentStore.liveSnapshot(workspaceID: nil).profile == expectedContent)
    }

    @Test("intervening manual edit makes the due background update skip without a proposal")
    func lateCadenceUpdateSkipsOnConflict() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let documentStore = SQLitePersonalizationStore(database: database)
        let memoryStore = SQLiteIntelligenceStore(database: database)
        let service = PersonalizationService(documents: documentStore, memories: memoryStore)
        _ = try await service.saveManual(kind: .userProfile, content: "base", expectedRevision: 0)
        try await service.recordActivity(completedRuns: 10)
        let gate = GenerationGate()
        let generation = Task {
            try await service.generateIfDue(kind: .userProfile,
                generator: GatedGenerator(gate: gate, content: String(repeating: "silent auto\n", count: 60)))
        }
        await gate.awaitStarted()
        _ = try await service.saveManual(kind: .userProfile, content: "user-edit", expectedRevision: 1)
        await gate.finishManualSave()
        let skipped = try await generation.value
        #expect(skipped == nil)
        let retention = try await documentStore.retention(kind: .userProfile, workspaceID: nil)
        #expect(retention.current?.content == "user-edit")
        #expect(retention.previous?.content == "base")
        // The cadence window is consumed so the next attempt regenerates over
        // the newer current instead of retrying every activity tick.
        let cursor = try await documentStore.cursor(kind: .userProfile, workspaceID: nil)
        #expect(cursor.lastGeneratedAt != nil)
        #expect(cursor.completedRunsSinceUpdate == 0)
    }

    @Test("oversized automatic output is dropped without touching the lane")
    func overLimitAutomaticUpdateKeepsCurrent() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let documentStore = SQLitePersonalizationStore(database: database)
        let memoryStore = SQLiteIntelligenceStore(database: database)
        let service = PersonalizationService(documents: documentStore, memories: memoryStore)
        _ = try await service.saveManual(kind: .userProfile, content: "keep me", expectedRevision: 0)
        try await service.recordActivity(completedRuns: 10)
        let oversized = try await service.generateIfDue(kind: .userProfile,
            generator: FixedGenerator(content: String(repeating: "x", count: 24_001)))
        #expect(oversized == nil)
        #expect(try await documentStore.activeDocument(kind: .userProfile, workspaceID: nil)?.content == "keep me")
        #expect(try await retainedRowCount(database, kind: .userProfile) == 1)
    }

    @Test("manual saves keep exactly 24000 characters and reject more instead of truncating")
    func manualSaveLengthIsExplicit() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let documentStore = SQLitePersonalizationStore(database: database)
        let memoryStore = SQLiteIntelligenceStore(database: database)
        let service = PersonalizationService(documents: documentStore, memories: memoryStore)
        let atLimit = String(repeating: "字", count: PersonalizationDocument.maxContentCharacters)
        let saved = try await service.saveManual(kind: .soul, content: atLimit, expectedRevision: 0)
        #expect(saved.content.count == PersonalizationDocument.maxContentCharacters)
        await #expect(throws: PersonalizationLifecycleFailure
            .contentTooLong(characterLimit: PersonalizationDocument.maxContentCharacters)) {
            try await service.saveManual(kind: .soul,
                content: atLimit + "overflow", expectedRevision: 1)
        }
        // The rejection left the full valid document intact — no silent prefix loss.
        let retention = try await documentStore.retention(kind: .soul, workspaceID: nil)
        #expect(retention.current?.content == atLimit)
        #expect(try await retainedRowCount(database, kind: .soul) == 1)
    }

    @Test("workspace and global lanes retain, rotate and allocate independently")
    func workspaceLaneIsolation() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let documentStore = SQLitePersonalizationStore(database: database)
        let workspace = UUID()
        try await SQLiteWorkspaceStore(database: database)
            .saveWorkspace(.init(id: workspace, name: "Isolation fixture", rootBookmark: Data()))
        _ = try await documentStore.applyCurrent(kind: .soul, workspaceID: nil, content: "global-a",
            source: .manual, evidenceDigest: "", expectedRevision: nil, now: Date())
        let workspaceFirst = try await documentStore.applyCurrent(kind: .soul, workspaceID: workspace,
            content: "workspace-a", source: .manual, evidenceDigest: "",
            expectedRevision: nil, now: Date())
        // Fresh workspace lane starts its own allocator at revision 1.
        #expect(workspaceFirst.document.revision == 1)
        _ = try await documentStore.applyCurrent(kind: .soul, workspaceID: nil, content: "global-b",
            source: .manual, evidenceDigest: "", expectedRevision: 1, now: Date())
        _ = try await documentStore.applyCurrent(kind: .soul, workspaceID: nil, content: "global-c",
            source: .manual, evidenceDigest: "", expectedRevision: 2, now: Date())
        let global = try await documentStore.retention(kind: .soul, workspaceID: nil)
        let local = try await documentStore.retention(kind: .soul, workspaceID: workspace)
        #expect(global.current?.content == "global-c")
        #expect(global.previous?.content == "global-b")
        #expect(local.current?.content == "workspace-a")
        #expect(local.previous == nil)
        await #expect(throws: PersonalizationLifecycleFailure.noPrevious) {
            try await documentStore.restorePrevious(kind: .soul, workspaceID: workspace)
        }
        #expect(try await retainedRowCount(database, kind: .soul) == 2)
        #expect(try await retainedRowCount(database, kind: .soul, workspaceID: workspace) == 1)
    }

    @Test("a failed rotation transaction keeps the last good pair untouched")
    func failedRotationRollsBackAtomically() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let documentStore = SQLitePersonalizationStore(database: database)
        _ = try await documentStore.applyCurrent(kind: .soul, workspaceID: nil, content: "x1",
            source: .manual, evidenceDigest: "", expectedRevision: nil, now: Date())
        _ = try await documentStore.applyCurrent(kind: .soul, workspaceID: nil, content: "x2",
            source: .manual, evidenceDigest: "", expectedRevision: nil, now: Date())
        _ = try await documentStore.applyCurrent(kind: .soul, workspaceID: nil, content: "x3",
            source: .manual, evidenceDigest: "", expectedRevision: nil, now: Date())
        // Plant an invisible (unclassified) row that occupies the next
        // revision number, so the rotation's INSERT fails on the (kind,
        // revision) unique index after its delete/demote statements ran.
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO personalization_documents (
                    id, kind, workspace_id, revision, content, source_kind,
                    evidence_digest, is_active, created_at, lifecycle
                ) VALUES ('plant', 'soul', NULL, 4, 'ghost', 'manual', '', 0,
                          '2026-01-01T00:00:00Z', NULL)
                """)
        }
        await #expect(throws: DatabaseError.self) {
            try await documentStore.applyCurrent(kind: .soul, workspaceID: nil, content: "x4",
                source: .manual, evidenceDigest: "", expectedRevision: 3, now: Date())
        }
        let retention = try await documentStore.retention(kind: .soul, workspaceID: nil)
        #expect(retention.current?.content == "x3")
        #expect(retention.previous?.content == "x2")
        #expect(try await documentStore.activeDocument(kind: .soul, workspaceID: nil)?.content == "x3")
        // After clearing the collision the lane continues monotonically.
        try await database.writer { db in
            try db.execute(sql: "DELETE FROM personalization_documents WHERE id = 'plant'")
        }
        let recovered = try await documentStore.applyCurrent(kind: .soul, workspaceID: nil,
            content: "x4", source: .manual, evidenceDigest: "", expectedRevision: 3, now: Date())
        #expect(recovered.document.revision == 4)
    }

    @Test("cancellation is CancellationError or a cancelled caller, never a hidden genuine DB failure")
    func cancellationClassification() async throws {
        // Normal cooperative cancellation always classifies as cancellation.
        #expect(PersonalizationCancellation.isCancellation(CancellationError()))
        // A genuine abort/interrupt/busy observed by a live, uncancelled
        // caller stays visible (it is not blanket-hidden).
        #expect(!PersonalizationCancellation.isCancellation(
            DatabaseError(resultCode: .SQLITE_INTERRUPT, message: "interrupted", sql: nil)))
        #expect(!PersonalizationCancellation.isCancellation(
            DatabaseError(resultCode: .SQLITE_ABORT, message: "aborted", sql: nil)))
        #expect(!PersonalizationCancellation.isCancellation(
            DatabaseError(resultCode: .SQLITE_BUSY, message: "busy", sql: nil)))
        // Once the caller's Task is cancelled, its fenced operation must not
        // surface anything; the next live attempt re-reads the true state.
        let flag = FenceFlag()
        let task = Task { () -> Bool in
            await flag.markEntered()
            await flag.waitUntilReleased()
            return PersonalizationCancellation.isCancellation(
                DatabaseError(resultCode: .SQLITE_BUSY, message: "busy", sql: nil))
        }
        await flag.awaitEntered()
        task.cancel()
        await flag.release()
        #expect(await task.value)
    }

    @Test("a retention read launched from a cancelled fence is classified as cancellation")
    func storeReadCancellationIsClassifiable() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLitePersonalizationStore(database: database)
        _ = try await store.applyCurrent(kind: .soul, workspaceID: nil, content: "keep",
            source: .manual, evidenceDigest: "", expectedRevision: nil, now: Date())
        let flag = FenceFlag()
        let task = Task { () -> Bool in
            await flag.markEntered()
            await flag.waitUntilReleased()
            do {
                _ = try await store.retention(kind: .soul, workspaceID: nil)
                return false // would mean the cancelled read silently succeeded
            } catch {
                return PersonalizationCancellation.isCancellation(error)
            }
        }
        await flag.awaitEntered()
        task.cancel()
        await flag.release()
        #expect(await task.value)
        // The cancellation neither damaged nor replaced the stored data.
        #expect(try await store.activeDocument(kind: .soul, workspaceID: nil)?.content == "keep")
    }

    @Test("one-click profile uses reviewed active memories and resets cadence")
    func oneClickProfile() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let documentStore = SQLitePersonalizationStore(database: database)
        let memoryStore = SQLiteIntelligenceStore(database: database)
        try await memoryStore.saveMemory(MemoryEntry(scope: .userProfile, status: .active,
            content: "Prefers concise Chinese answers", confidence: 1, importance: 1,
            sourceKind: .explicitUserRequest), evidence: [])
        let service = PersonalizationService(documents: documentStore, memories: memoryStore)
        try await service.recordActivity(completedRuns: 12, userMessages: 40)
        let document = try await service.generateNow(kind: .userProfile)
        #expect(document.content.contains("Prefers concise Chinese answers"))
        let cursor = try await documentStore.cursor(kind: .userProfile, workspaceID: nil)
        #expect(cursor.completedRunsSinceUpdate == 0)
        #expect(cursor.userMessagesSinceUpdate == 0)
        #expect(cursor.lastGeneratedAt != nil)
    }

    @Test("hybrid recall combines lexical and semantic results")
    func hybridRecall() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteIntelligenceStore(database: database)
        let apple = MemoryEntry(scope: .userProfile, status: .active,
            content: "apple fruit preference", confidence: 1, importance: 0.7,
            sourceKind: .explicitUserRequest)
        let banana = MemoryEntry(scope: .userProfile, status: .active,
            content: "banana smoothie", confidence: 1, importance: 0.7,
            sourceKind: .explicitUserRequest)
        try await store.saveMemory(apple, evidence: [])
        try await store.saveMemory(banana, evidence: [])
        try await store.saveEmbedding(MemoryEmbedding(memoryID: apple.id, modality: .text,
            modelIdentifier: "test", modelRevision: "1", values: [1, 0], contentDigest: "a"))
        try await store.saveEmbedding(MemoryEmbedding(memoryID: banana.id, modality: .text,
            modelIdentifier: "test", modelRevision: "1", values: [0, 1], contentDigest: "b"))
        let results = try await store.hybridRecall(HybridMemoryRecallRequest(
            query: "banana", queryEmbedding: [1, 0], modelIdentifier: "test",
            modelRevision: "1", limit: 2
        ))
        #expect(results.count == 2)
        #expect(Set(results.map(\.id)) == Set([apple.id, banana.id]))
        #expect(results.contains { $0.id == banana.id && $0.lexicalRank != nil })
        #expect(results.contains { $0.id == apple.id && $0.semanticRank != nil })
    }

    @Test("Deleted-task memory keeps ownership, crosses tasks, and is reinforced on recall")
    func deletedTaskMemoryLifecycle() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let store = SQLiteIntelligenceStore(database: database)
        let sourceTaskID = UUID()
        let otherTaskID = UUID()
        try await conversations.saveConversation(.init(
            id: sourceTaskID,
            title: "Source research",
            createdAt: Date(),
            updatedAt: Date()
        ))
        let memory = MemoryEntry(
            scope: .task(sourceTaskID),
            status: .active,
            content: "Use the violet release checklist",
            confidence: 1,
            importance: 0.7,
            sourceKind: .explicitUserRequest
        )
        try await store.saveMemory(memory, evidence: [])
        try await store.preserveMemoriesBeforeConversationDeletion(
            conversationID: sourceTaskID,
            ownerLabel: "Source research"
        )
        try await conversations.deleteConversation(id: sourceTaskID)

        let owned = try await store.memories(scope: .task(sourceTaskID), status: .active)
        #expect(owned.map(\.id) == [memory.id])
        let recalled = try await store.hybridRecall(.init(
            query: "violet release",
            conversationID: otherTaskID,
            limit: 6
        ))
        #expect(recalled.contains { $0.id == memory.id })
        let reinforcement: (Int, String?) = try await database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT recall_count, last_recalled_at FROM memory_entries WHERE id = ?",
                arguments: [memory.id.uuidString]
            ) else { return (-1, nil) }
            return (row["recall_count"], row["last_recalled_at"])
        }
        #expect(reinforcement.0 == 1)
        #expect(reinforcement.1 != nil)
    }

    @Test("Cross-task memory retains its originating task ID independently of scope")
    func globalMemoryTaskProvenance() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteIntelligenceStore(database: database)
        let taskID = UUID()
        let memory = MemoryEntry(
            scope: .userProfile,
            status: .active,
            content: "Prefer concise release evidence",
            confidence: 1,
            importance: 0.8,
            sourceKind: .automaticTurnReview,
            originConversationID: taskID
        )
        try await store.saveMemory(memory, evidence: [])

        let restored = try #require(
            try await store.memories(scope: .userProfile, status: .active).first
        )
        #expect(restored.originConversationID == taskID)
        let storedOrigin: String? = try await database.reader { db in
            try String.fetchOne(
                db,
                sql: "SELECT origin_conversation_id FROM memory_entries WHERE id = ?",
                arguments: [memory.id.uuidString]
            )
        }
        #expect(storedOrigin == taskID.uuidString)
    }

    @Test("Live task and workspace memories are not evicted by size")
    func liveOwnerMemoryCapacity() {
        let policy = MemoryCapacityPolicy(
            userProfileCharacters: 10,
            agentGlobalCharacters: 10,
            workspaceCharacters: 10,
            taskCharacters: 10
        )
        #expect(policy.activeCharacterLimit(for: .workspace(UUID())) == Int.max)
        #expect(policy.activeCharacterLimit(for: .task(UUID())) == Int.max)
        #expect(policy.activeCharacterLimit(for: .userProfile) == 10)
    }

    @Test("Batch memory deletion records every tombstone in one operation")
    func batchMemoryDeletion() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteIntelligenceStore(database: database)
        let first = MemoryEntry(scope: .userProfile, status: .active,
            content: "First batch memory", confidence: 1, importance: 0.5,
            sourceKind: .explicitUserRequest)
        let second = MemoryEntry(scope: .userProfile, status: .active,
            content: "Second batch memory", confidence: 1, importance: 0.5,
            sourceKind: .explicitUserRequest)
        try await store.saveMemory(first, evidence: [])
        try await store.saveMemory(second, evidence: [])

        try await store.deleteMemories(ids: [first.id, second.id], syncRevision: 7)

        #expect(try await store.memories(scope: .userProfile, status: .active).isEmpty)
        let tombstones = try await database.reader { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM memory_tombstones
                WHERE sync_revision = 7 AND memory_id IN (?, ?)
                """, arguments: [first.id.uuidString, second.id.uuidString]) ?? 0
        }
        #expect(tombstones == 2)
    }

    @Test("A stale delete cannot lower a memory tombstone revision")
    func tombstoneRevisionIsMonotonic() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteIntelligenceStore(database: database)
        let memory = MemoryEntry(
            scope: .userProfile, status: .active, content: "Delete monotonically",
            confidence: 1, importance: 0.5, sourceKind: .explicitUserRequest
        )
        try await store.saveMemory(memory, evidence: [])
        try await store.deleteMemory(id: memory.id, syncRevision: 9)
        try await store.deleteMemory(id: memory.id, syncRevision: 3)

        let revision = try await database.reader { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT sync_revision FROM memory_tombstones WHERE memory_id = ?",
                arguments: [memory.id.uuidString]
            )
        }
        #expect(revision == 9)
    }

    @Test("Saving a newer fact replaces the old slot and writes a tombstone")
    func factSlotReplacement() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteIntelligenceStore(database: database)
        let identity = MemoryFactIdentity(subjectKey: "host:hk4h4g", attributeKey: "agent-version")
        let old = MemoryEntry(
            scope: .agentGlobal, status: .active, content: "Agent version is 1.2.0",
            confidence: 1, importance: 0.8, sourceKind: .explicitUserRequest,
            factIdentity: identity
        )
        let current = MemoryEntry(
            scope: .agentGlobal, status: .active, content: "Agent version is 1.4.1",
            confidence: 1, importance: 0.8, sourceKind: .explicitUserRequest,
            factIdentity: identity
        )
        try await store.saveMemory(old, evidence: [])
        try await store.saveMemory(current, evidence: [])

        let stored = try await store.memories(factIdentity: identity, scope: .agentGlobal)
        #expect(stored.map(\.id) == [current.id])
        #expect(stored.map(\.content) == ["Agent version is 1.4.1"])
        let tombstoneCount = try await database.reader { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM memory_tombstones WHERE memory_id = ?",
                arguments: [old.id.uuidString]
            ) ?? 0
        }
        #expect(tombstoneCount == 1)
        let tombstoneRevision = try await database.reader { db in
            try Int64.fetchOne(
                db, sql: "SELECT sync_revision FROM memory_tombstones WHERE memory_id = ?",
                arguments: [old.id.uuidString]
            ) ?? 0
        }
        #expect(tombstoneRevision > 0)
    }

    @Test("Organization preview never auto-applies one fact slot across scopes")
    func organizationPreviewKeepsScopeBoundary() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteIntelligenceStore(database: database)
        let identity = MemoryFactIdentity(subjectKey: "host:shared", attributeKey: "address")
        try await store.saveMemory(MemoryEntry(
            scope: .agentGlobal, status: .active, content: "Global address is 10.0.0.1",
            confidence: 1, importance: 0.8, sourceKind: .explicitUserRequest,
            factIdentity: identity
        ), evidence: [])
        try await store.saveMemory(MemoryEntry(
            scope: .userProfile, status: .active, content: "Profile address is 10.0.0.2",
            confidence: 1, importance: 0.8, sourceKind: .explicitUserRequest,
            factIdentity: identity
        ), evidence: [])

        let proposal = try await store.organizationPreview(limit: 100)
        let suggestion = try #require(proposal.suggestions.first {
            $0.kind == .sameFactReplacement
        })
        #expect(!suggestion.canApplyAutomatically)
    }

    @Test("Maintenance batch rolls back every operation when one item is stale")
    func maintenanceBatchRollback() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteIntelligenceStore(database: database)
        let memory = MemoryEntry(
            scope: .userProfile, status: .active, content: "Keep this entry",
            confidence: 1, importance: 0.5, sourceKind: .explicitUserRequest
        )
        try await store.saveMemory(memory, evidence: [])
        let batch = MemoryMaintenanceBatch(
            operations: [.delete(memoryID: memory.id), .delete(memoryID: UUID())],
            syncRevision: 42
        )

        await #expect(throws: (any Error).self) {
            try await store.applyMaintenanceBatch(batch)
        }
        #expect(try await store.memory(id: memory.id) != nil)
        let tombstones = try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_tombstones") ?? 0
        }
        #expect(tombstones == 0)
    }

    @Test("Maintenance batch is idempotent by stable batch ID")
    func maintenanceBatchIdempotency() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteIntelligenceStore(database: database)
        let memory = MemoryEntry(
            scope: .agentGlobal, status: .active, content: "Remove once",
            confidence: 1, importance: 0.5, sourceKind: .explicitUserRequest
        )
        try await store.saveMemory(memory, evidence: [])
        let batch = MemoryMaintenanceBatch(
            id: UUID(), operations: [.delete(memoryID: memory.id)], syncRevision: 43
        )
        let first = try await store.applyMaintenanceBatch(batch)
        let repeated = try await store.applyMaintenanceBatch(batch)
        #expect(first.deletedCount == 1)
        #expect(repeated.wasAlreadyApplied)
        #expect(repeated.appliedCount == 0)
    }

    @Test("sensitive and conflicting candidates require confirmation")
    func candidateReview() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let documents = SQLitePersonalizationStore(database: database)
        let memories = SQLiteIntelligenceStore(database: database)
        let pipeline = MemoryCandidatePipeline(documents: documents, memories: memories)
        let candidate = MemoryCandidate(scope: .userProfile, content: "User lives in Sydney",
            confidence: 1, stability: 1, importance: 1, sensitivity: .personal,
            origin: .automaticTurnReview,
            evidence: [MemoryEvidenceReference(messageID: UUID(), excerpt: "I live in Sydney")])
        let record = try await pipeline.submit(candidate)
        #expect(record.status == .pending)
        #expect(try await documents.candidates(status: .pending).map(\.id) == [candidate.id])
    }

    @Test("only explicit user image attachments can become candidates")
    func imageGate() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let documents = SQLitePersonalizationStore(database: database)
        let memories = SQLiteIntelligenceStore(database: database)
        let pipeline = MemoryCandidatePipeline(documents: documents, memories: memories)
        let input = UserAttachedImageMemoryInput(attachmentID: UUID(), mimeType: "image/jpeg",
            extractedText: "", proposedMemory: "A preference", wasAttachedByUser: false)
        await #expect(throws: (any Error).self) {
            try await pipeline.submitUserAttachedImage(input, scope: .userProfile,
                evidenceMessageID: UUID(), sensitivity: .none,
                confidence: 1, stability: 1, importance: 1)
        }
    }
}
