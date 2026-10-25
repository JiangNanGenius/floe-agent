import Foundation
import GRDB
import Testing
import FloeCore
import FloeModels
import FloeTestSupport
@testable import FloePersistence

@Suite("Skill authoring durable ownership")
struct SkillAuthoringStoreTests {
    private struct Fixture: Sendable {
        let database: DatabaseManager
        let store: SQLiteSkillAuthoringStore
        let conversations: SQLiteConversationStore
        static func make() async throws -> Self {
            let database = try DatabaseManager.inMemory()
            try await database.migrate()
            return Self(database: database, store: SQLiteSkillAuthoringStore(database: database),
                        conversations: SQLiteConversationStore(database: database))
        }
        func draft(_ kind: SkillAuthoringKind = .creation, now: Date = Date()) async throws -> SkillAuthoringRecord {
            try await store.begin(kind: kind, title: "Synthetic skill", now: now).record
        }
        func start(_ record: SkillAuthoringRecord, binding: SkillAuthoringBinding = .init(),
                   now: Date = Date()) async throws -> SkillAuthoringRecord {
            try await store.startProcessing(id: record.id, expectedRevision: record.revision,
                                            inputRevision: record.inputRevision, binding: binding, now: now)
        }
        func run(conversationID: UUID, id: UUID = UUID(), providerID: UUID? = nil,
                 modelID: UUID? = nil, now: Date = Date()) async throws -> UUID {
            try await SQLiteRunStore(database: database).saveRun(RunRecord(
                id: id, conversationID: conversationID, state: "streamingModel", goal: "Synthetic work",
                startedAt: now, providerID: providerID, modelID: modelID))
            return id
        }
        func count(_ table: String) async throws -> Int {
            try await database.reader { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
        }
    }

    private static let prepared = SkillAuthoringPreparedSkill(
        skillID: "authored-test", version: "1.0.0", digest: String(repeating: "a", count: 64))

    @Test("Concurrent creation/import returns one owner and creates no orphan conversation")
    func singleForegroundSlot() async throws {
        let f = try await Fixture.make()
        let otherStore = SQLiteSkillAuthoringStore(database: f.database)
        async let a = f.store.begin(kind: .creation, title: "Create")
        async let b = otherStore.begin(kind: .importing, title: "Import")
        let results = try await [a, b]
        #expect(results.filter(\.created).count == 1)
        #expect(Set(results.map { $0.record.id }).count == 1)
        #expect(try await f.count("conversations") == 1)
        #expect(try await f.store.all().count == 1)
    }

    @Test("Closing and reopening retains the same draft references and occupied slot")
    func closeDoesNotRelease() async throws {
        let f = try await Fixture.make()
        let draft = try await f.draft()
        let attachment = UUID(), snapshot = UUID()
        let saved = try await f.store.saveDraftReferences(id: draft.id, expectedRevision: draft.revision,
            inputRevision: 4, attachmentIDs: [attachment], snapshotIDs: [snapshot])
        let reopened = SQLiteSkillAuthoringStore(database: f.database)
        let active = try #require(try await reopened.active())
        #expect(active == saved)
        #expect(active.sourceAttachmentIDs == [attachment])
        #expect(active.sourceSnapshotIDs == [snapshot])
        #expect(active.inputRevision == 4)
        let next = try await reopened.begin(kind: .importing, title: "A second entry")
        #expect(!next.created && next.record.id == draft.id)
    }

    @Test("Owner/record/slot insertion rolls back together when metadata fails")
    func creationRollback() async throws {
        let f = try await Fixture.make()
        try await f.database.writer { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_authoring_begin BEFORE INSERT ON app_settings
                WHEN NEW.key LIKE 'skills.authoring.record.%'
                BEGIN SELECT RAISE(ABORT, 'synthetic authoring write failure'); END
                """)
        }
        await #expect(throws: (any Error).self) { _ = try await f.draft() }
        #expect(try await f.count("conversations") == 0)
        #expect(try await f.store.active() == nil)
        #expect(try await f.store.all().isEmpty)
    }

    @Test("Auxiliary model IDs and exact run ownership are frozen before processing")
    func frozenRouteAndRunOwnership() async throws {
        let f = try await Fixture.make(), draft = try await f.draft()
        let provider = TestFixtures.localhostProvider()
        let model = TestFixtures.testModel(providerID: provider.id)
        let config = ModelConfigurationStore(database: f.database)
        try await config.saveProvider(provider); try await config.saveModel(model)
        let runID = try await f.run(conversationID: draft.id, providerID: provider.id, modelID: model.id)
        let binding = SkillAuthoringBinding(runID: runID, providerID: provider.id, modelID: model.id,
            workspaceID: UUID(), environmentID: "owned-environment", workspaceWriteLayer: "session", requiresExecution: true)
        let running = try await f.start(draft, binding: binding)
        #expect(running.attempt?.binding == binding)
        let paused = try await f.store.setProcessingPhase(try #require(running.attempt?.token), phase: .needsUser)
        #expect(paused.attempt?.binding == binding)
        await #expect(throws: SkillAuthoringStoreError.invalidBinding) {
            _ = try await f.store.startProcessing(id: UUID(), expectedRevision: 0, inputRevision: 0,
                binding: .init(providerID: provider.id, modelID: model.id))
        }
    }

    @Test("Foreign runs and ambiguous execution bindings cannot start an attempt")
    func invalidRunBinding() async throws {
        let f = try await Fixture.make(), draft = try await f.draft()
        let other = ConversationRecord(id: UUID(), title: "Other", createdAt: Date(), updatedAt: Date())
        try await f.conversations.saveConversation(other)
        let foreignRun = try await f.run(conversationID: other.id)
        await #expect(throws: SkillAuthoringStoreError.ownerMismatch) {
            _ = try await f.start(draft, binding: .init(runID: foreignRun))
        }
        await #expect(throws: SkillAuthoringStoreError.invalidBinding) {
            _ = try await f.start(draft, binding: .init(requiresExecution: true))
        }
        #expect(try await f.store.record(id: draft.id)?.phase == .draft)
        #expect(try await f.store.active()?.id == draft.id)
    }

    @Test("Only active processing counts, cumulative samples replay safely, 90 seconds does not convert")
    func activeDurationAndAdvisory() async throws {
        let f = try await Fixture.make(), running = try await f.start(try await f.draft())
        let token = try #require(running.attempt?.token)
        let before = try await f.store.recordActiveProcessing(token, attemptTotalMilliseconds: 89_000)
        #expect(!before.isAdvisoryEligible)
        let waiting = try await f.store.setProcessingPhase(token, phase: .needsUser)
        await #expect(throws: SkillAuthoringStoreError.invalidTransition) {
            _ = try await f.store.recordActiveProcessing(token, attemptTotalMilliseconds: 200_000)
        }
        #expect(try await f.store.record(id: running.id)?.activeProcessingMilliseconds == 89_000)
        _ = try await f.store.setProcessingPhase(token, phase: .running)
        let eligible = try await f.store.recordActiveProcessing(token, attemptTotalMilliseconds: 90_000)
        let replayed = try await f.store.recordActiveProcessing(token, attemptTotalMilliseconds: 90_000)
        #expect(eligible == replayed)
        #expect(eligible.isAdvisoryEligible && !eligible.isPromoted)
        #expect(eligible.phase == .running)
        #expect(try await f.conversations.conversations().isEmpty)
        #expect(waiting.attempt?.binding == eligible.attempt?.binding)
    }

    @Test("Keep waiting is persisted once across store reconstruction and never reoffers")
    func keepWaitingSurvivesReopen() async throws {
        let f = try await Fixture.make(), running = try await f.start(try await f.draft())
        let token = try #require(running.attempt?.token)
        let eligible = try await f.store.recordActiveProcessing(token, attemptTotalMilliseconds: 90_000)
        let chosen = try await f.store.chooseAdvisory(id: running.id, expectedRevision: eligible.revision, choice: .keepWaiting)
        let reopened = SQLiteSkillAuthoringStore(database: f.database)
        let later = try await reopened.recordActiveProcessing(token, attemptTotalMilliseconds: 900_000)
        #expect(later.advisoryDecision == .keepWaiting && !later.isAdvisoryEligible)
        #expect(try await reopened.active()?.id == chosen.id)
        await #expect(throws: SkillAuthoringStoreError.invalidTransition) {
            _ = try await reopened.chooseAdvisory(id: later.id, expectedRevision: later.revision, choice: .convertToTask)
        }
    }

    @Test("Cancellation keeps the slot until owned work has actually settled")
    func cancellationIsTwoPhase() async throws {
        let f = try await Fixture.make(), running = try await f.start(try await f.draft())
        let token = try #require(running.attempt?.token)
        let cancelling = try await f.store.requestCancellation(id: running.id, expectedRevision: running.revision)
        #expect(cancelling.phase == .cancelling)
        let another = try await f.store.begin(kind: .importing, title: "Not yet")
        #expect(!another.created && another.record.id == running.id)
        let stopped = try await f.store.settleCancellation(token)
        #expect(stopped.phase == .stopped)
        #expect(try await f.store.active() == nil)
        #expect(try await f.store.begin(kind: .importing, title: "Now available").created)
        #expect(try await f.store.record(id: stopped.id) != nil)
    }

    @Test("Successful completion suppresses a pending suggestion and never means installed")
    func terminalStateWins() async throws {
        let f = try await Fixture.make(), running = try await f.start(try await f.draft())
        let token = try #require(running.attempt?.token)
        _ = try await f.store.recordActiveProcessing(token, attemptTotalMilliseconds: 90_000)
        let artifacts = [UUID()]
        let ready = try await f.store.finishReady(token, skill: Self.prepared, artifactIDs: artifacts)
        #expect(try await f.store.finishReady(token, skill: Self.prepared, artifactIDs: artifacts) == ready)
        #expect(ready.phase == .ready && ready.installationReceipt == nil)
        #expect(!ready.isAdvisoryEligible)
        #expect(try await f.store.active() == nil)
        await #expect(throws: SkillAuthoringStoreError.invalidTransition) {
            _ = try await f.store.chooseAdvisory(id: ready.id, expectedRevision: ready.revision, choice: .convertToTask)
        }
        await #expect(throws: SkillAuthoringStoreError.installationMismatch) {
            _ = try await f.store.confirmInstalled(id: ready.id, expectedRevision: ready.revision)
        }
    }

    @Test("Conversion changes only visibility, once, on the same conversation/run/files")
    func conversionPreservesOwner() async throws {
        let f = try await Fixture.make(), draft = try await f.draft()
        let snapshot = UUID()
        let input = try await f.store.saveDraftReferences(id: draft.id, expectedRevision: draft.revision,
            inputRevision: 3, attachmentIDs: [], snapshotIDs: [snapshot])
        let runID = try await f.run(conversationID: draft.id)
        let message = PersistedMessage(id: UUID(), conversationID: draft.id, role: "user", content: "Create it", createdAt: Date())
        try await f.conversations.appendMessage(message)
        let running = try await f.start(input, binding: .init(runID: runID))
        let token = try #require(running.attempt?.token)
        let eligible = try await f.store.recordActiveProcessing(token, attemptTotalMilliseconds: 90_000)
        let requested = try await f.store.chooseAdvisory(id: running.id, expectedRevision: eligible.revision, choice: .convertToTask)
        #expect(try await f.store.active()?.id == running.id)
        let promoted = try await f.store.commitPromotion(id: running.id, expectedRevision: requested.revision)
        let repeated = try await f.store.commitPromotion(id: running.id, expectedRevision: requested.revision)
        #expect(promoted == repeated)
        #expect(promoted.phase == .running && promoted.isPromoted)
        #expect(promoted.attempt?.token == token && promoted.sourceSnapshotIDs == [snapshot])
        #expect(try await f.count("conversations") == 1)
        #expect(try await f.count("runs") == 1)
        #expect(try await f.conversations.messages(conversationID: draft.id).map(\.id) == [message.id])
        #expect(try await f.conversations.conversations().map(\.id) == [draft.id])
        #expect(try await f.store.active() == nil)
        let next = try await f.store.begin(kind: .importing, title: "Independent next import")
        #expect(next.created)
        let ready = try await f.store.finishReady(token, skill: Self.prepared, artifactIDs: [])
        #expect(ready.isPromoted && ready.phase == .ready)
        #expect(try await f.store.active()?.id == next.record.id)
    }

    @Test("A failing promotion transaction preserves visibility, chosen decision and the slot")
    func conversionRollback() async throws {
        for failAtSlotRemoval in [false, true] {
            let f = try await Fixture.make(), running = try await f.start(try await f.draft())
            let token = try #require(running.attempt?.token)
            let eligible = try await f.store.recordActiveProcessing(token, attemptTotalMilliseconds: 90_000)
            let requested = try await f.store.chooseAdvisory(id: running.id, expectedRevision: eligible.revision, choice: .convertToTask)
            try await f.database.writer { db in
                if failAtSlotRemoval {
                    try db.execute(sql: """
                        CREATE TRIGGER fail_authoring_conversion BEFORE DELETE ON app_settings
                        WHEN OLD.key = 'skills.authoring.active'
                        BEGIN SELECT RAISE(ABORT, 'synthetic slot failure'); END
                        """)
                } else {
                    try db.execute(sql: """
                        CREATE TRIGGER fail_authoring_conversion BEFORE UPDATE ON app_settings
                        WHEN NEW.key LIKE 'skills.authoring.record.%' AND json_extract(NEW.value_json, '$.advisoryDecision') = 'converted'
                        BEGIN SELECT RAISE(ABORT, 'synthetic metadata failure'); END
                        """)
                }
            }
            await #expect(throws: (any Error).self) {
                _ = try await f.store.commitPromotion(id: running.id, expectedRevision: requested.revision)
            }
            let retained = try #require(try await f.store.record(id: running.id))
            #expect(retained == requested && retained.advisoryDecision == .convertRequested)
            #expect(!retained.isAdvisoryEligible && !retained.isPromoted)
            #expect(try await f.store.active()?.id == running.id)
            #expect(try await f.conversations.conversation(id: running.id)?.visibility == .skillAuthoring)
            try await f.database.writer { db in try db.execute(sql: "DROP TRIGGER fail_authoring_conversion") }
            #expect(try await f.store.commitPromotion(id: running.id, expectedRevision: requested.revision).isPromoted)
        }
    }

    @Test("Late callbacks and old conversion revisions cannot mutate a restarted attempt")
    func staleAttemptAndConversion() async throws {
        let f = try await Fixture.make(), running = try await f.start(try await f.draft())
        let old = try #require(running.attempt?.token)
        let eligible = try await f.store.recordActiveProcessing(old, attemptTotalMilliseconds: 90_000)
        let requested = try await f.store.chooseAdvisory(id: running.id, expectedRevision: eligible.revision, choice: .convertToTask)
        let failed = try await f.store.finishFailed(old, message: "Synthetic interruption")
        let next = try await f.start(failed)
        let new = try #require(next.attempt?.token)
        #expect(old.attemptID != new.attemptID)
        await #expect(throws: SkillAuthoringStoreError.staleAttempt) {
            _ = try await f.store.finishReady(old, skill: Self.prepared, artifactIDs: [])
        }
        await #expect(throws: SkillAuthoringStoreError.staleRevision) {
            _ = try await f.store.commitPromotion(id: next.id, expectedRevision: requested.revision)
        }
        #expect(try await f.store.record(id: next.id)?.attempt?.token == new)
    }

    @Test("An attempt ID cannot be recycled to make old callbacks current again")
    func rejectsReusedAttemptID() async throws {
        let f = try await Fixture.make(), running = try await f.start(try await f.draft())
        let token = try #require(running.attempt?.token)
        let failed = try await f.store.finishFailed(token, message: "Failed")
        await #expect(throws: SkillAuthoringStoreError.staleAttempt) {
            _ = try await f.store.startProcessing(id: failed.id, expectedRevision: failed.revision,
                inputRevision: failed.inputRevision, binding: .init(), attemptID: token.attemptID)
        }
        // Even if a caller mistakenly reuses the UUID after clearing the
        // draft attempt, the persisted monotonic generation fences it.
        let draft = try await f.store.saveDraftReferences(id: failed.id, expectedRevision: failed.revision,
            inputRevision: failed.inputRevision, attachmentIDs: [], snapshotIDs: [])
        let restarted = try await f.store.startProcessing(id: draft.id, expectedRevision: draft.revision,
            inputRevision: draft.inputRevision, binding: .init(), attemptID: token.attemptID)
        #expect(restarted.attempt?.token.generation != token.generation)
        await #expect(throws: SkillAuthoringStoreError.staleAttempt) {
            _ = try await f.store.finishReady(token, skill: Self.prepared, artifactIDs: [])
        }
    }

    @Test("Relaunch marks lost work interrupted without replaying it or counting dead time")
    func lostAttemptRecovery() async throws {
        let f = try await Fixture.make()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let running = try await f.start(try await f.draft(now: old), now: old)
        let token = try #require(running.attempt?.token)
        _ = try await f.store.recordActiveProcessing(token, attemptTotalMilliseconds: 40_000, now: old)
        let reopened = SQLiteSkillAuthoringStore(database: f.database)
        let recovered = try await reopened.reconcileLostAttempts(startedBefore: old.addingTimeInterval(1), liveRunIDs: [], now: old.addingTimeInterval(10_000))
        #expect(recovered.count == 1 && recovered[0].phase == .interrupted)
        #expect(recovered[0].activeProcessingMilliseconds == 40_000)
        #expect(recovered[0].attempt?.token == token)
        #expect(try await reopened.active() == nil)
        #expect(try await reopened.reconcileLostAttempts(startedBefore: Date(), liveRunIDs: []).isEmpty)
        #expect(try await f.count("runs") == 0)
    }

    @Test("Known live/current-process attempts are not falsely interrupted")
    func recoveryPreservesLiveAttempt() async throws {
        let f = try await Fixture.make(), draft = try await f.draft()
        let runID = try await f.run(conversationID: draft.id)
        let running = try await f.start(draft, binding: .init(runID: runID))
        #expect(try await f.store.reconcileLostAttempts(startedBefore: Date().addingTimeInterval(1), liveRunIDs: [runID]).isEmpty)
        #expect(try await f.store.reconcileLostAttempts(startedBefore: running.attempt!.startedAt, liveRunIDs: []).isEmpty)
        #expect(try await f.store.active()?.id == running.id)
    }

    @Test("Only an exact committed skill row produces the installation receipt")
    func installationReceipt() async throws {
        let f = try await Fixture.make(), running = try await f.start(try await f.draft())
        let ready = try await f.store.finishReady(try #require(running.attempt?.token), skill: Self.prepared, artifactIDs: [])
        let skills = SQLiteSkillStore(database: f.database)
        let row = PersistedSkill(id: Self.prepared.skillID, name: "Authored", version: "wrong-version",
            skillMarkdown: "Test", manifestJSON: "{}", rewrittenDigest: Self.prepared.digest)
        try await skills.save(row)
        await #expect(throws: SkillAuthoringStoreError.installationMismatch) {
            _ = try await f.store.confirmInstalled(id: ready.id, expectedRevision: ready.revision)
        }
        var correct = row; correct.version = Self.prepared.version
        try await skills.save(correct)
        let installed = try await f.store.confirmInstalled(id: ready.id, expectedRevision: ready.revision)
        #expect(installed.phase == .installed && installed.installationReceipt?.skill == Self.prepared)
        #expect(try await f.store.confirmInstalled(id: ready.id, expectedRevision: ready.revision) == installed)
    }

    @Test("Default title refresh does not expose a lightweight conversation or delete it as an empty chat")
    func visibilityIsStable() async throws {
        let f = try await Fixture.make(), draft = try await f.draft()
        let refreshed = ConversationRecord(id: draft.id, title: "Updated", createdAt: Date(), updatedAt: Date())
        try await f.conversations.saveConversation(refreshed)
        #expect(try await f.conversations.conversation(id: draft.id)?.visibility == .skillAuthoring)
        #expect(try await f.conversations.conversations().isEmpty)
        #expect(try await f.store.all().map(\.id) == [draft.id])
        #expect(try await f.conversations.deleteConversationIfVerifiedEmpty(id: draft.id) == false)
    }

    @Test("Explicit owner deletion removes only its metadata and frees its slot in the same transaction")
    func ownerDeletionCleanup() async throws {
        let f = try await Fixture.make(), draft = try await f.draft()
        try await f.conversations.deleteConversation(id: draft.id)
        #expect(try await f.store.active() == nil)
        #expect(try await f.store.all().isEmpty)
        #expect(try await f.store.record(id: draft.id) == nil)
        #expect(try await f.store.begin(kind: .importing, title: "Next").created)
    }

    @Test("A launch reservation persists identity before RunStore creates the actual run")
    func prelaunchReservation() async throws {
        let f = try await Fixture.make(), draft = try await f.draft()
        let runID = UUID()
        let reserved = try await f.store.reserveAttempt(id: draft.id, expectedRevision: draft.revision,
            inputRevision: draft.inputRevision, binding: .init(runID: runID))
        let token = try #require(reserved.attempt?.token)
        #expect(reserved.phase == .preparing && token.runID == runID)
        #expect(try await f.count("runs") == 0)
        await #expect(throws: SkillAuthoringStoreError.ownerMissing) {
            _ = try await f.store.activateAttempt(token)
        }
        #expect(try await f.store.active()?.phase == .preparing)
        _ = try await f.run(conversationID: draft.id, id: runID)
        #expect(try await f.store.activateAttempt(token).phase == .running)
        #expect(try await f.count("runs") == 1)
    }

    @Test("A reserved run ID that already belongs elsewhere is rejected without changing the draft")
    func prelaunchIdentityCollision() async throws {
        let f = try await Fixture.make(), draft = try await f.draft()
        let other = ConversationRecord(id: UUID(), title: "Other", createdAt: Date(), updatedAt: Date())
        try await f.conversations.saveConversation(other)
        let runID = try await f.run(conversationID: other.id)
        await #expect(throws: SkillAuthoringStoreError.ownerMismatch) {
            _ = try await f.store.reserveAttempt(id: draft.id, expectedRevision: draft.revision,
                inputRevision: draft.inputRevision, binding: .init(runID: runID))
        }
        #expect(try await f.store.record(id: draft.id) == draft)
    }

    @Test("Cancellation during the launch gap holds the slot and late activation cannot revive it")
    func cancellationDuringReservation() async throws {
        let f = try await Fixture.make(), draft = try await f.draft()
        let runID = UUID()
        let reserved = try await f.store.reserveAttempt(id: draft.id, expectedRevision: draft.revision,
            inputRevision: draft.inputRevision, binding: .init(runID: runID))
        let token = try #require(reserved.attempt?.token)
        _ = try await f.store.requestCancellation(id: draft.id, expectedRevision: reserved.revision)
        #expect(try await f.store.active()?.phase == .cancelling)
        #expect(try await f.store.begin(kind: .creation, title: "No duplicate").created == false)
        _ = try await f.run(conversationID: draft.id, id: runID)
        #expect(try await f.store.activateAttempt(token).phase == .cancelling)
        #expect(try await f.store.settleCancellation(token).phase == .stopped)
        #expect(try await f.store.active() == nil)
    }

    @Test("A crash before the run row exists preserves the reservation as interrupted")
    func recoverReservationWithoutRunRow() async throws {
        let f = try await Fixture.make()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let draft = try await f.draft(now: old)
        let reserved = try await f.store.reserveAttempt(id: draft.id, expectedRevision: draft.revision,
            inputRevision: draft.inputRevision, binding: .init(runID: UUID()), now: old)
        let recovered = try await f.store.reconcileLostAttempts(startedBefore: old.addingTimeInterval(1), liveRunIDs: [])
        #expect(recovered.count == 1 && recovered[0].phase == .interrupted)
        #expect(recovered[0].attempt == reserved.attempt)
        #expect(try await f.count("runs") == 0)
        #expect(try await f.store.active() == nil)
    }

    @Test("A fast completed result before activation remains terminal when the launch receipt arrives")
    func completionBeforeActivation() async throws {
        let f = try await Fixture.make(), draft = try await f.draft()
        let runID = UUID()
        let reserved = try await f.store.reserveAttempt(id: draft.id, expectedRevision: draft.revision,
            inputRevision: draft.inputRevision, binding: .init(runID: runID))
        let token = try #require(reserved.attempt?.token)
        _ = try await f.run(conversationID: draft.id, id: runID)
        let ready = try await f.store.finishReady(token, skill: Self.prepared, artifactIDs: [])
        #expect(try await f.store.activateAttempt(token) == ready)
        #expect(try await f.store.active() == nil)
    }

    @Test("An input revision change fences old result callbacks and stale draft writes")
    func inputRevisionFence() async throws {
        let f = try await Fixture.make(), running = try await f.start(try await f.draft())
        let old = try #require(running.attempt?.token)
        let failed = try await f.store.finishFailed(old, message: "Stopped attempt")
        let revised = try await f.store.saveDraftReferences(id: failed.id, expectedRevision: failed.revision,
            inputRevision: failed.inputRevision + 1, attachmentIDs: [], snapshotIDs: [UUID()])
        await #expect(throws: SkillAuthoringStoreError.staleAttempt) {
            _ = try await f.store.finishReady(old, skill: Self.prepared, artifactIDs: [])
        }
        await #expect(throws: SkillAuthoringStoreError.staleRevision) {
            _ = try await f.store.saveDraftReferences(id: revised.id, expectedRevision: failed.revision,
                inputRevision: revised.inputRevision + 1, attachmentIDs: [], snapshotIDs: [])
        }
        #expect(try await f.store.record(id: revised.id) == revised)
    }

    @Test("Completion after a chosen conversion request wins without exposing a finished lightweight result")
    func terminalWinsChosenConversion() async throws {
        let f = try await Fixture.make(), running = try await f.start(try await f.draft())
        let token = try #require(running.attempt?.token)
        let eligible = try await f.store.recordActiveProcessing(token, attemptTotalMilliseconds: 90_000)
        _ = try await f.store.chooseAdvisory(id: running.id, expectedRevision: eligible.revision, choice: .convertToTask)
        let ready = try await f.store.finishReady(token, skill: Self.prepared, artifactIDs: [])
        await #expect(throws: SkillAuthoringStoreError.invalidTransition) {
            _ = try await f.store.commitPromotion(id: ready.id, expectedRevision: ready.revision)
        }
        #expect(try await f.conversations.conversation(id: ready.id)?.visibility == .skillAuthoring)
        #expect(try await f.store.active() == nil)
    }


    @Test("A converted metadata-only owner is not an empty placeholder eligible for temporary replacement")
    func promotedOwnerIsNotEmpty() async throws {
        let f = try await Fixture.make()
        let draft = try await f.store.begin(kind: .importing, title: "").record
        let running = try await f.start(draft)
        let token = try #require(running.attempt?.token)
        let eligible = try await f.store.recordActiveProcessing(token, attemptTotalMilliseconds: 90_000)
        let requested = try await f.store.chooseAdvisory(id: running.id, expectedRevision: eligible.revision, choice: .convertToTask)
        _ = try await f.store.commitPromotion(id: running.id, expectedRevision: requested.revision)
        #expect(try await f.count("runs") == 0)
        #expect(try await f.count("messages") == 0)
        #expect(try await f.conversations.deleteConversationIfVerifiedEmpty(id: draft.id) == false)
        #expect(try await f.store.record(id: draft.id)?.isPromoted == true)
    }


    @Test("Retrying an acknowledged failure makes the ongoing operation visible again")
    func acknowledgedRetryIsVisible() async throws {
        let f = try await Fixture.make(), running = try await f.start(try await f.draft())
        let failed = try await f.store.finishFailed(try #require(running.attempt?.token), message: "Failed")
        let acknowledged = try await f.store.acknowledge(id: failed.id, expectedRevision: failed.revision)
        #expect(try await f.store.all(includeAcknowledged: false).isEmpty)
        let retry = try await f.start(acknowledged)
        #expect(!retry.acknowledged)
        #expect(try await f.store.all(includeAcknowledged: false).map(\.id) == [retry.id])
    }


    @Test("Explicit adaptation starts a new input revision on the same owner and preserves original outputs")
    func readyPackageBeginsExplicitRevision() async throws {
        let f = try await Fixture.make(), draft = try await f.draft(.importing)
        let originalSnapshot = UUID(), packageSnapshot = UUID(), newAttachment = UUID()
        let input = try await f.store.saveDraftReferences(id: draft.id, expectedRevision: draft.revision,
            inputRevision: 1, attachmentIDs: [], snapshotIDs: [originalSnapshot])
        let running = try await f.start(input)
        let oldToken = try #require(running.attempt?.token)
        let outputs = [UUID(), UUID()]
        let ready = try await f.store.finishReady(oldToken, skill: Self.prepared, artifactIDs: outputs)
        let revised = try await f.store.beginRevision(id: ready.id, expectedRevision: ready.revision,
            inputRevision: 2, attachmentIDs: [newAttachment], sourceSnapshotIDs: [originalSnapshot, packageSnapshot])
        #expect(revised.id == ready.id && revised.conversationID == ready.conversationID)
        #expect(revised.phase == .draft && revised.inputRevision == 2)
        #expect(revised.generatedArtifactIDs == outputs)
        #expect(revised.sourceAttachmentIDs == [newAttachment])
        #expect(revised.sourceSnapshotIDs == [originalSnapshot, packageSnapshot])
        #expect(revised.preparedSkill == nil && revised.installationReceipt == nil && revised.attempt == nil)
        #expect(try await f.store.active()?.id == ready.id)
        #expect(try await f.count("conversations") == 1)
        await #expect(throws: SkillAuthoringStoreError.staleAttempt) {
            _ = try await f.store.finishReady(oldToken, skill: Self.prepared, artifactIDs: outputs)
        }
    }

    @Test("A different occupied foreground slot leaves the ready package and both owners unchanged")
    func revisionCannotStealForegroundSlot() async throws {
        let f = try await Fixture.make(), running = try await f.start(try await f.draft(.importing))
        let ready = try await f.store.finishReady(try #require(running.attempt?.token), skill: Self.prepared, artifactIDs: [UUID()])
        let other = try await f.store.begin(kind: .creation, title: "Current foreground operation").record
        await #expect(throws: SkillAuthoringStoreError.foregroundOccupied(other.id)) {
            _ = try await f.store.beginRevision(id: ready.id, expectedRevision: ready.revision,
                inputRevision: ready.inputRevision + 1, attachmentIDs: [], sourceSnapshotIDs: [UUID()])
        }
        #expect(try await f.store.record(id: ready.id) == ready)
        #expect(try await f.store.active() == other)
        #expect(try await f.count("conversations") == 2)
    }

    @Test("Adaptation rejects stale metadata and non-increasing input revisions without acquiring a slot")
    func revisionRequiresCurrentIncreasingInput() async throws {
        let f = try await Fixture.make(), running = try await f.start(try await f.draft(.importing))
        let ready = try await f.store.finishReady(try #require(running.attempt?.token), skill: Self.prepared, artifactIDs: [])
        await #expect(throws: SkillAuthoringStoreError.staleRevision) {
            _ = try await f.store.beginRevision(id: ready.id, expectedRevision: ready.revision - 1,
                inputRevision: ready.inputRevision + 1, attachmentIDs: [], sourceSnapshotIDs: [])
        }
        await #expect(throws: SkillAuthoringStoreError.invalidTransition) {
            _ = try await f.store.beginRevision(id: ready.id, expectedRevision: ready.revision,
                inputRevision: ready.inputRevision, attachmentIDs: [], sourceSnapshotIDs: [])
        }
        #expect(try await f.store.record(id: ready.id) == ready)
        #expect(try await f.store.active() == nil)
    }

    @Test("Installed and promoted results cannot be reopened as lightweight adaptation drafts")
    func revisionRejectsInstalledOrPromoted() async throws {
        let installedFixture = try await Fixture.make()
        let running = try await installedFixture.start(try await installedFixture.draft(.importing))
        let ready = try await installedFixture.store.finishReady(try #require(running.attempt?.token), skill: Self.prepared, artifactIDs: [])
        try await SQLiteSkillStore(database: installedFixture.database).save(PersistedSkill(
            id: Self.prepared.skillID, name: "Installed", version: Self.prepared.version,
            skillMarkdown: "Test", manifestJSON: "{}", rewrittenDigest: Self.prepared.digest))
        let installed = try await installedFixture.store.confirmInstalled(id: ready.id, expectedRevision: ready.revision)
        await #expect(throws: SkillAuthoringStoreError.invalidTransition) {
            _ = try await installedFixture.store.beginRevision(id: installed.id, expectedRevision: installed.revision,
                inputRevision: installed.inputRevision + 1, attachmentIDs: [], sourceSnapshotIDs: [])
        }
        #expect(try await installedFixture.store.record(id: installed.id) == installed)
        #expect(try await installedFixture.store.active() == nil)

        let promotedFixture = try await Fixture.make()
        let work = try await promotedFixture.start(try await promotedFixture.draft(.importing))
        let token = try #require(work.attempt?.token)
        let eligible = try await promotedFixture.store.recordActiveProcessing(token, attemptTotalMilliseconds: 90_000)
        let requested = try await promotedFixture.store.chooseAdvisory(id: work.id, expectedRevision: eligible.revision, choice: .convertToTask)
        _ = try await promotedFixture.store.commitPromotion(id: work.id, expectedRevision: requested.revision)
        let promotedReady = try await promotedFixture.store.finishReady(token, skill: Self.prepared, artifactIDs: [])
        await #expect(throws: SkillAuthoringStoreError.invalidTransition) {
            _ = try await promotedFixture.store.beginRevision(id: work.id, expectedRevision: promotedReady.revision,
                inputRevision: promotedReady.inputRevision + 1, attachmentIDs: [], sourceSnapshotIDs: [])
        }
        #expect(try await promotedFixture.store.record(id: work.id) == promotedReady)
        #expect(try await promotedFixture.store.active() == nil)
    }

    @Test("An explicit adaptation revision preserves the once-only keep-waiting decision and actual active time")
    func revisionPreservesKeepWaiting() async throws {
        let f = try await Fixture.make(), running = try await f.start(try await f.draft(.importing))
        let token = try #require(running.attempt?.token)
        let eligible = try await f.store.recordActiveProcessing(token, attemptTotalMilliseconds: 90_000)
        _ = try await f.store.chooseAdvisory(id: running.id, expectedRevision: eligible.revision, choice: .keepWaiting)
        let ready = try await f.store.finishReady(token, skill: Self.prepared, artifactIDs: [UUID()])
        let revised = try await f.store.beginRevision(id: ready.id, expectedRevision: ready.revision,
            inputRevision: ready.inputRevision + 1, attachmentIDs: [], sourceSnapshotIDs: [UUID()])
        #expect(revised.advisoryDecision == .keepWaiting)
        #expect(revised.activeProcessingMilliseconds == 90_000)
        let next = try await f.start(revised)
        let later = try await f.store.recordActiveProcessing(try #require(next.attempt?.token), attemptTotalMilliseconds: 5_000)
        #expect(later.activeProcessingMilliseconds == 95_000)
        #expect(!later.isAdvisoryEligible && later.advisoryDecision == .keepWaiting)
        let reopened = SQLiteSkillAuthoringStore(database: f.database)
        #expect(try await reopened.record(id: later.id)?.advisoryDecision == .keepWaiting)
    }


    @Test("A completed clarification can continue at a new revision on the same owner")
    func completedQuestionBeginsRevision() async throws {
        let f = try await Fixture.make(), draft = try await f.draft()
        let snapshot = UUID()
        let input = try await f.store.saveDraftReferences(id: draft.id, expectedRevision: draft.revision,
            inputRevision: 1, attachmentIDs: [], snapshotIDs: [snapshot])
        let runID = try await f.run(conversationID: draft.id)
        let running = try await f.start(input, binding: .init(runID: runID))
        let token = try #require(running.attempt?.token)
        try await SQLiteRunStore(database: f.database).updateRunState(id: runID, state: "completed", endedAt: Date())
        let question = try await f.store.setProcessingPhase(token, phase: .needsUser)
        #expect(try await f.store.active()?.id == question.id)
        let answered = try await f.store.beginRevision(id: question.id, expectedRevision: question.revision,
            inputRevision: 2, attachmentIDs: [], sourceSnapshotIDs: [])
        #expect(answered.id == question.id && answered.inputRevision == 2 && answered.phase == .draft)
        #expect(answered.sourceSnapshotIDs == [snapshot])
        #expect(answered.attempt == nil)
        #expect(try await f.count("conversations") == 1)
        #expect(try await f.store.active()?.id == question.id)
        await #expect(throws: SkillAuthoringStoreError.staleAttempt) {
            _ = try await f.store.finishReady(token, skill: Self.prepared, artifactIDs: [])
        }
        // The new input revision can start only a fresh attempt/run; no prior
        // provider request was copied or resumed by beginRevision itself.
        let nextRun = try await f.run(conversationID: answered.id)
        let next = try await f.start(answered, binding: .init(runID: nextRun))
        #expect(next.attempt?.token.runID == nextRun)
        #expect(next.attempt?.token.inputRevision == 2)
    }

    @Test("Live approval waits or incomplete terminal rows cannot be reopened as new revisions")
    func liveQuestionCannotRestart() async throws {
        let states: [(String, Date?)] = [("streamingModel", nil), ("completed", nil), ("waitingApproval", Date())]
        for (state, endedAt) in states {
            let f = try await Fixture.make(), draft = try await f.draft()
            let runID = try await f.run(conversationID: draft.id)
            let running = try await f.start(draft, binding: .init(runID: runID))
            let question = try await f.store.setProcessingPhase(try #require(running.attempt?.token), phase: .needsUser)
            try await SQLiteRunStore(database: f.database).updateRunState(id: runID, state: state, endedAt: endedAt)
            await #expect(throws: SkillAuthoringStoreError.invalidTransition) {
                _ = try await f.store.beginRevision(id: question.id, expectedRevision: question.revision,
                    inputRevision: question.inputRevision + 1, attachmentIDs: [], sourceSnapshotIDs: [])
            }
            #expect(try await f.store.record(id: question.id) == question)
            #expect(try await f.store.active() == question)
        }
    }

    @Test("Clarification revision requires a real same-owner run and the frozen route")
    func questionRevisionRejectsInvalidRunIdentity() async throws {
        for mode in ["missing", "foreign", "route", "nilRun"] {
            let f = try await Fixture.make(), draft = try await f.draft()
            let runID: UUID?
            if mode == "nilRun" { runID = nil }
            else { runID = try await f.run(conversationID: draft.id) }
            let running = try await f.start(draft, binding: .init(runID: runID))
            let question = try await f.store.setProcessingPhase(try #require(running.attempt?.token), phase: .needsUser)
            if let runID {
                try await SQLiteRunStore(database: f.database).updateRunState(id: runID, state: "completed", endedAt: Date())
                if mode == "foreign" {
                    let other = ConversationRecord(id: UUID(), title: "Other", createdAt: Date(), updatedAt: Date())
                    try await f.conversations.saveConversation(other)
                    try await f.database.writer { db in
                        try db.execute(sql: "UPDATE runs SET conversation_id = ? WHERE id = ?", arguments: [other.id.uuidString, runID.uuidString])
                    }
                } else if mode == "missing" {
                    try await f.database.writer { db in try db.execute(sql: "DELETE FROM runs WHERE id = ?", arguments: [runID.uuidString]) }
                } else {
                    try await f.database.writer { db in
                        try db.execute(sql: "UPDATE runs SET model_id = ? WHERE id = ?", arguments: [UUID().uuidString, runID.uuidString])
                    }
                }
            }
            await #expect(throws: SkillAuthoringStoreError.self) {
                _ = try await f.store.beginRevision(id: question.id, expectedRevision: question.revision,
                    inputRevision: question.inputRevision + 1, attachmentIDs: [], sourceSnapshotIDs: [])
            }
            #expect(try await f.store.record(id: question.id) == question)
            #expect(try await f.store.active() == question)
        }
    }

    @Test("Cancellation retains verified output references and settles idempotently")
    func cancelledSnapshotsRemainRecoverable() async throws {
        let f = try await Fixture.make()
        let draft = try await f.draft()
        let running = try await f.start(draft)
        let token = try #require(running.attempt?.token)
        _ = try await f.store.requestCancellation(id: running.id, expectedRevision: running.revision)
        let snapshot = UUID()
        let stopped = try await f.store.settleCancellation(token, artifactIDs: [snapshot])
        #expect(stopped.phase == .stopped)
        #expect(stopped.generatedArtifactIDs == [snapshot])
        #expect(try await f.store.active() == nil)
        let restored = SQLiteSkillAuthoringStore(database: f.database)
        #expect(try await restored.record(id: running.id) == stopped)
        #expect(try await restored.settleCancellation(token, artifactIDs: [snapshot]) == stopped)
    }

}
