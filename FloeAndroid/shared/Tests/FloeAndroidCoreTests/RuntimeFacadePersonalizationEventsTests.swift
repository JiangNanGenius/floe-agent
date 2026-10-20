// SPDX-License-Identifier: MPL-2.0
//
// Authored host tests for the P8 runtime event handoff (SOURCE ONLY — not
// executed by the authoring job). Vectors: runtimeIntegrationHandoff
// negativeTests (events.temporaryDropped / failedRunNotCounted /
// duplicateDelivery / noHistoricalReplay / deletedConversationLateCallback
// / candidateFence / automaticDraftNeverActivates) + behavioralTestDesign
// runtime.events* + ownership.runtimeEventOwnership. The feed truth comes
// from the RB4 owner's persisted commit identity; these tests construct
// THAT identity directly on the original DB and call the handler — no
// timers, no scheduler, no invented producer.

import XCTest
import Foundation
import GRDB
import FloeCore
import FloePersistence
import FloeAgentRuntime
@testable import FloeAndroidCore

final class RuntimeFacadePersonalizationEventsTests: XCTestCase {
    private var manager: DatabaseManager!
    private var url: URL!
    private var intelligence: SQLiteIntelligenceStore!
    private var documents: SQLitePersonalizationStore!
    private var service: PersonalizationService!
    private var memoryAdapter: FacadeMemoryAdapter!
    private var fences: SyntheticFences!
    private var events: FacadePersonalizationEvents!
    private var adapterBox: SyntheticModelAdapter!

    private func makeFixture(mode: SyntheticRouteProvider.Mode? = nil,
                             cadence: PersonalizationUpdateCadence = PersonalizationUpdateCadence(),
                             leases: (any PersonalizationEventOwnedLeaseProviding)? = nil)
        async throws
    {
        let made = try await IntelligenceTestSupport.makeDatabase("evt-\(UUID().uuidString.prefix(8))")
        manager = made.0
        url = made.1
        intelligence = SQLiteIntelligenceStore(database: manager)
        documents = SQLitePersonalizationStore(database: manager)
        service = PersonalizationService(documents: documents, memories: intelligence,
                                         cadence: cadence)
        memoryAdapter = FacadeMemoryAdapter(database: manager,
                                            intelligenceStore: intelligence,
                                            workspaceStore: SQLiteWorkspaceStore(database: manager),
                                            conversationStore: SQLiteConversationStore(database: manager))
        fences = SyntheticFences()
        let syntheticAdapter = SyntheticModelAdapter(scripts: [
            SyntheticModelAdapter.Script(deltas: ["# automatic\n", "\n- small edit."]),
        ])
        adapterBox = syntheticAdapter
        let provider = ProviderProfile(kind: .openAI,
                                       wireProtocol: .openAIChatCompletions,
                                       baseURL: URL(string: "https://synthetic.invalid")!)
        let model = ModelProfile(providerID: provider.id, remoteModelID: "m",
                                 displayName: "M",
                                 limits: ModelLimits(contextTokens: 1_024,
                                                     maxOutputTokens: 512))
        let route = SyntheticRouteProvider(mode: mode ?? .resolved(
            adapter: syntheticAdapter, provider: provider, model: model))
        let generate = FacadePersonalizationGenerate(database: manager,
                                                     workspaceStore: SQLiteWorkspaceStore(database: manager),
                                                     route: route)
        events = FacadePersonalizationEvents(
            database: manager, personalizationService: service,
            generate: generate, memoryAdapter: memoryAdapter,
            cadence: cadence, fences: fences, ownedLeases: leases)
    }

    override func tearDown() async throws {
        IntelligenceTestSupport.cleanup(url)
    }

    private func counters(kindRaw: String, workspaceKey: String = "") async throws
        -> (runs: Int64, messages: Int64)?
    {
        try await manager.reader { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT completed_runs_since_update, user_messages_since_update
                FROM personalization_update_cursors
                WHERE kind = ? AND workspace_key = ?
                """, arguments: [kindRaw, workspaceKey]) else { return nil }
            let runs: Int64 = row["completed_runs_since_update"]
            let messages: Int64 = row["user_messages_since_update"]
            return (runs, messages)
        }
    }

    // MARK: - happy path (persisted truth + real owner workspace)

    func testOrdinaryUserMessageCountsAndEvaluates() async throws {
        try await makeFixture()
        let conversation = try await IntelligenceTestSupport.seedOrdinaryConversation(manager)
        let workspace = try await IntelligenceTestSupport.seedWorkspace(manager)
        try await IntelligenceTestSupport.seedWorkspaceOwnership(
            manager, conversationID: conversation, workspaceID: workspace)
        let message = try await IntelligenceTestSupport.seedUserMessage(
            manager, conversationID: conversation)
        let disposition = await events.handleOrdinaryUserMessage(
            PersonalizationOrdinaryUserMessageEvent(
                messageID: message, conversationID: conversation, rootEpoch: 1,
                temporaryAtStart: false, temporaryAtCommit: false))
        switch disposition {
        case .countedCadenceNotDue(let key, let owner):
            XCTAssertEqual(key, "personalization.activity.msg.\(message.uuidString)")
            XCTAssertEqual(owner, workspace,
                           "workspace ownership from the REAL ownership row at event time")
        case .counted(let key, let owner, let due):
            XCTAssertEqual(key, "personalization.activity.msg.\(message.uuidString)")
            XCTAssertEqual(owner, workspace)
            XCTAssertFalse(due.values.contains(true), "1/30 messages is not due")
        default:
            XCTFail("expected a counted disposition, got \(disposition)")
        }
        // Counters persisted on BOTH kinds by the ORIGINAL recordActivity,
        // keyed by the EVENT workspace (the native cursor key).
        let soul = try await counters(kindRaw: "soul",
                                      workspaceKey: workspace.uuidString)
        XCTAssertEqual(soul?.messages, 1,
                       "the native hook keys the cursor by the event workspace")
        let profile = try await counters(kindRaw: "userProfile")
        // recordActivity(workspaceID:) is passed the owner id: the default
        // (nil) cursor is what the GLOBAL documents share — the original
        // actor writes per (kind, workspace key), so check either path
        // exists; assert at least one cursor advanced exactly 1 message.
        let anyCursor = try await manager.reader { db in
            try Int64.fetchOne(db, sql: """
                SELECT MAX(user_messages_since_update) FROM personalization_update_cursors
                """) ?? 0
        }
        XCTAssertEqual(anyCursor, 1,
                       "exactly one message counted; NO timer, NO queue")
        _ = profile
    }

    func testCompletedSuccessfulRunCountsOnce() async throws {
        try await makeFixture()
        let conversation = try await IntelligenceTestSupport.seedOrdinaryConversation(manager)
        let run = try await IntelligenceTestSupport.seedCompletedRun(
            manager, conversationID: conversation)
        let disposition = await events.handleOrdinaryRunCompleted(
            PersonalizationOrdinaryRunCompletedEvent(
                runID: run, conversationID: conversation, rootEpoch: 1,
                temporaryAtStart: false, frozenTemporaryRun: false,
                ordinarySurface: true, succeeded: true))
        let countedKey: String
        switch disposition {
        case .counted(let key, _, _), .countedCadenceNotDue(let key, _):
            countedKey = key
        default:
            return XCTFail("expected a counted disposition, got \(disposition)")
        }
        XCTAssertEqual(countedKey, "personalization.activity.run.\(run.uuidString)")
        let runs = try await manager.reader { db in
            try Int64.fetchOne(db, sql: """
                SELECT MAX(completed_runs_since_update) FROM personalization_update_cursors
                """) ?? 0
        }
        XCTAssertEqual(runs, 1)
    }

    // MARK: - negatives (contract negativeTests, all seven)

    func testTemporaryNeverCountsAtStartCommitOrHandling() async throws {
        try await makeFixture()
        let conversation = try await IntelligenceTestSupport.seedOrdinaryConversation(manager)
        let message = try await IntelligenceTestSupport.seedUserMessage(
            manager, conversationID: conversation)
        let base = PersonalizationOrdinaryUserMessageEvent(
            messageID: message, conversationID: conversation, rootEpoch: 1,
            temporaryAtStart: false, temporaryAtCommit: false)
        // at start:
        let droppedStart = await events.handleOrdinaryUserMessage(
            PersonalizationOrdinaryUserMessageEvent(
                messageID: message, conversationID: conversation, rootEpoch: 1,
                temporaryAtStart: true, temporaryAtCommit: false))
        XCTAssertEqual(droppedStart, .dropped(reason: .temporaryAtStart))
        // at commit:
        let droppedCommit = await events.handleOrdinaryUserMessage(
            PersonalizationOrdinaryUserMessageEvent(
                messageID: message, conversationID: conversation, rootEpoch: 1,
                temporaryAtStart: false, temporaryAtCommit: true))
        XCTAssertEqual(droppedCommit, .dropped(reason: .temporaryAtCommit))
        // at handling (runtime now says temporary):
        await fences.setTemporary(conversation)
        let droppedHandling = await events.handleOrdinaryUserMessage(base)
        XCTAssertEqual(droppedHandling, .dropped(reason: .temporaryAtHandling))
        // NO counter, NO candidate, NO document, NO evidence, NO cursor row.
        let cursors = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM personalization_update_cursors")
        }
        XCTAssertEqual(cursors, 0, "temporary content never touches the durable cadence")
        let docs = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM personalization_documents")
        }
        XCTAssertEqual(docs, 0)
    }

    func testFailedOrNonOrdinaryRunsNeverCount() async throws {
        try await makeFixture()
        let conversation = try await IntelligenceTestSupport.seedOrdinaryConversation(manager)
        let run = try await IntelligenceTestSupport.seedCompletedRun(
            manager, conversationID: conversation)
        let failed = await events.handleOrdinaryRunCompleted(
            PersonalizationOrdinaryRunCompletedEvent(
                runID: run, conversationID: conversation, rootEpoch: 1,
                temporaryAtStart: false, frozenTemporaryRun: false,
                ordinarySurface: true, succeeded: false))
        XCTAssertEqual(failed, .dropped(reason: .failedOrNonSuccessRun))
        let special = await events.handleOrdinaryRunCompleted(
            PersonalizationOrdinaryRunCompletedEvent(
                runID: run, conversationID: conversation, rootEpoch: 1,
                temporaryAtStart: false, frozenTemporaryRun: false,
                ordinarySurface: false, succeeded: true))
        XCTAssertEqual(special, .dropped(reason: .nonOrdinarySurface))
        // The durable row says failed even if the event claims success:
        try await IntelligenceTestSupport.rawMemoryUpdate(
            manager, "UPDATE runs SET state = 'failed' WHERE id = ?", [run.uuidString])
        let liar = await events.handleOrdinaryRunCompleted(
            PersonalizationOrdinaryRunCompletedEvent(
                runID: run, conversationID: conversation, rootEpoch: 1,
                temporaryAtStart: false, frozenTemporaryRun: false,
                ordinarySurface: true, succeeded: true))
        XCTAssertEqual(liar, .dropped(reason: .sourceRowInvalid),
                       "authoritative original-DB readback outranks the event")
        let cursors = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM personalization_update_cursors")
        }
        XCTAssertEqual(cursors, 0)
    }

    func testInProcessDuplicateDeliversOnce() async throws {
        try await makeFixture()
        let conversation = try await IntelligenceTestSupport.seedOrdinaryConversation(manager)
        let message = try await IntelligenceTestSupport.seedUserMessage(
            manager, conversationID: conversation)
        let event = PersonalizationOrdinaryUserMessageEvent(
            messageID: message, conversationID: conversation, rootEpoch: 1,
            temporaryAtStart: false, temporaryAtCommit: false)
        let first = await events.handleOrdinaryUserMessage(event)
        let second = await events.handleOrdinaryUserMessage(event)
        switch first {
        case .counted, .countedCadenceNotDue, .countedWithAutomaticGeneration:
            break
        default:
            return XCTFail("first must count, got \(first)")
        }
        XCTAssertEqual(second, .duplicate(dedupeKey:
            "personalization.activity.msg.\(message.uuidString)"))
        let maxMessages = try await manager.reader { db in
            try Int64.fetchOne(db, sql: """
                SELECT MAX(user_messages_since_update) FROM personalization_update_cursors
                """) ?? 0
        }
        XCTAssertEqual(maxMessages, 1, "one increment; suppression needs NO new table")
    }

    func testNoHistoricalReplayAfterRestart() async throws {
        try await makeFixture()
        let conversation = try await IntelligenceTestSupport.seedOrdinaryConversation(manager)
        _ = try await IntelligenceTestSupport.seedUserMessage(
            manager, conversationID: conversation)
        _ = try await IntelligenceTestSupport.seedCompletedRun(
            manager, conversationID: conversation)
        // "Restart": a NEW processor over the same DB has no ledger to
        // replay and exposes no catch-up entry point — construction alone
        // must never advance counters.
        let restarted = FacadePersonalizationEvents(
            database: manager, personalizationService: service,
            generate: FacadePersonalizationGenerate(
                database: manager, workspaceStore: SQLiteWorkspaceStore(database: manager),
                route: SyntheticRouteProvider(mode: .noUsableTextModel)),
            memoryAdapter: memoryAdapter,
            cadence: PersonalizationUpdateCadence(), fences: fences)
        _ = restarted
        let cursors = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM personalization_update_cursors")
        }
        XCTAssertEqual(cursors, 0, "there is no durable event log and no catch-up")
    }

    func testLateCallbackAfterDeleteCannotTouchReusedIdentity() async throws {
        try await makeFixture()
        let oldConversation = try await IntelligenceTestSupport.seedOrdinaryConversation(manager)
        let oldMessage = try await IntelligenceTestSupport.seedUserMessage(
            manager, conversationID: oldConversation)
        // The conversation is deleted (rows gone via FK cascade).
        try await manager.writer { db in
            try db.execute(sql: "DELETE FROM conversations WHERE id = ?",
                           arguments: [oldConversation.uuidString])
        }
        let late = await events.handleOrdinaryUserMessage(
            PersonalizationOrdinaryUserMessageEvent(
                messageID: oldMessage, conversationID: oldConversation, rootEpoch: 1,
                temporaryAtStart: false, temporaryAtCommit: false))
        XCTAssertEqual(late, .dropped(reason: .sourceRowInvalid))
        // Root change: a late OLD-owner callback with the stale epoch is
        // dropped before any read (cannot write into a new root/reused id).
        await fences.setEpoch(99)
        let conversation2 = try await IntelligenceTestSupport.seedOrdinaryConversation(manager)
        let message2 = try await IntelligenceTestSupport.seedUserMessage(
            manager, conversationID: conversation2)
        let staleRoot = await events.handleOrdinaryUserMessage(
            PersonalizationOrdinaryUserMessageEvent(
                messageID: message2, conversationID: conversation2, rootEpoch: 1,
                temporaryAtStart: false, temporaryAtCommit: false))
        XCTAssertEqual(staleRoot, .dropped(reason: .staleRootOwnerEpoch))
        // History-clear fencing drops a live-but-fenced conversation.
        await fences.setEpoch(1)
        await fences.setDeletionPending(conversation2)
        let fenced = await events.handleOrdinaryUserMessage(
            PersonalizationOrdinaryUserMessageEvent(
                messageID: message2, conversationID: conversation2, rootEpoch: 1,
                temporaryAtStart: false, temporaryAtCommit: false))
        XCTAssertEqual(fenced, .dropped(reason: .deletedOrFencedConversation))
        let cursors = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM personalization_update_cursors")
        }
        XCTAssertEqual(cursors, 0)
    }

    func testCandidateEventFencedAndCounterSilent() async throws {
        try await makeFixture()
        // A real candidate row exists (future producer writes it through
        // the real pipeline); the event only refreshes projection state.
        let candidate = try await IntelligenceTestSupport.seedCandidate(
            manager, content: "fenced candidate fact")
        let conversation = try await IntelligenceTestSupport.seedOrdinaryConversation(manager)
        let disposition = await events.handleCandidateActivity(
            PersonalizationCandidateActivityEvent(
                candidateID: candidate.id, conversationID: conversation,
                workspaceID: nil, rootEpoch: 1, temporaryAtStart: false),
            status: .pending)
        guard case .candidateProjectionRefreshed(let id, let pending) = disposition else {
            return XCTFail("expected projection refresh, got \(disposition)")
        }
        XCTAssertEqual(id, candidate.id)
        XCTAssertEqual(pending, 1, "the REAL pending row; nothing invented")
        let cursors = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM personalization_update_cursors")
        }
        XCTAssertEqual(cursors, 0, "candidate activity never changes cadence counters")
        // Temporary-conversation candidate events are fenced at creation.
        let dropped = await events.handleCandidateActivity(
            PersonalizationCandidateActivityEvent(
                candidateID: candidate.id, conversationID: conversation,
                workspaceID: nil, rootEpoch: 1, temporaryAtStart: true),
            status: .pending)
        XCTAssertEqual(dropped, .dropped(reason: .temporaryAtStart))
    }

    func testAutomaticDraftNeverActivatesOverChangedSource() async throws {
        // Cadence dialed to due with a small message threshold.
        try await makeFixture(cadence: PersonalizationUpdateCadence(
            minimumInterval: 60, minimumCompletedRuns: 1,
            minimumUserMessages: 1))
        // No current active document: generateIfDue policy REQUIRES review
        // (current == nil) → exactly one INACTIVE automatic draft, never an
        // active overwrite, even though slot+source match.
        _ = try await IntelligenceTestSupport.seedMemory(
            manager, content: "seeded reviewed memory for cadence pass")
        let conversation = try await IntelligenceTestSupport.seedOrdinaryConversation(manager)
        let message = try await IntelligenceTestSupport.seedUserMessage(
            manager, conversationID: conversation)
        let disposition = await events.handleOrdinaryUserMessage(
            PersonalizationOrdinaryUserMessageEvent(
                messageID: message, conversationID: conversation, rootEpoch: 1,
                temporaryAtStart: false, temporaryAtCommit: false))
        guard case .countedWithAutomaticGeneration(_, _, let outcomes) = disposition else {
            return XCTFail("expected automatic generation pass, got \(disposition)")
        }
        for (_, outcome) in outcomes {
            switch outcome {
            case .draftStoredSubstantial, .draftStored:
                break // required: current == nil → review draft
            case .activeCommitted:
                XCTFail("a fresh document with NO current active must never auto-activate")
            default:
                break
            }
        }
        let rows: [(source: String, active: Int64)] = try await manager.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT source_kind, is_active FROM personalization_documents
                """).map { row in
                let source: String = row["source_kind"]
                let activeValue: DatabaseValue = row["is_active"]
                var active: Int64 = 0
                if case .int64(let raw) = activeValue.storage { active = raw }
                return (source: source, active: active)
            }
        }
        let automatic = rows.filter { $0.source == "automatic" }
        XCTAssertFalse(automatic.isEmpty, "the automatic draft really persisted")
        for row in automatic {
            XCTAssertEqual(row.active, 0, "automatic drafts are NEVER active here")
        }
    }

    func testOrdinaryRunNotCancelledByProjectionTeardown() async throws {
        try await makeFixture()
        let conversation = try await IntelligenceTestSupport.seedOrdinaryConversation(manager)
        let run = try await IntelligenceTestSupport.seedCompletedRun(
            manager, conversationID: conversation, state: "running", ended: false)
        // Projection refresh (candidate event) runs while an ordinary run
        // row is live: it must not touch run state (no cancellation, no
        // accounting ownership).
        let candidate = try await IntelligenceTestSupport.seedCandidate(
            manager, content: "projection during live run")
        _ = await events.handleCandidateActivity(
            PersonalizationCandidateActivityEvent(
                candidateID: candidate.id, conversationID: conversation,
                workspaceID: nil, rootEpoch: 1, temporaryAtStart: false),
            status: .pending)
        let state = try await manager.reader { db in
            try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?",
                                arguments: [run.uuidString])
        }
        XCTAssertEqual(state, "running",
                       "the underlying ordinary run is not cancelled by projection teardown")
    }

    // MARK: - MEM-P8-LIFETIME typed feed-lease seam (integration 2026-10-20)

    private actor SyntheticLeaseValidator: PersonalizationEventOwnedLeaseProviding {
        private var validTokens: Set<String>
        private(set) var validationCount = 0

        init(validTokens: Set<String>) { self.validTokens = validTokens }

        func invalidate(_ token: String) { validTokens.remove(token) }

        func isEventOperationLeaseValid(_ lease: PersonalizationEventOperationLease) async -> Bool {
            validationCount += 1
            return validTokens.contains(lease.token)
        }
    }

    /// A feed-provided lease is validated immediately before the first DB
    /// mutation; a valid lease keeps the exact counted path.
    func testFeedHeldLeaseIsValidatedBeforeCounting() async throws {
        let validator = SyntheticLeaseValidator(validTokens: ["lease-a"])
        try await makeFixture(leases: validator)
        let conversation = try await IntelligenceTestSupport.seedOrdinaryConversation(manager)
        let message = try await IntelligenceTestSupport.seedUserMessage(
            manager, conversationID: conversation)
        let lease = PersonalizationEventOperationLease(token: "lease-a",
                                                       conversationID: conversation,
                                                       rootEpoch: 1)
        let disposition = await events.handleOrdinaryUserMessage(
            PersonalizationOrdinaryUserMessageEvent(
                messageID: message, conversationID: conversation, rootEpoch: 1,
                temporaryAtStart: false, temporaryAtCommit: false,
                operationLease: lease))
        switch disposition {
        case .counted, .countedCadenceNotDue, .countedWithAutomaticGeneration:
            break
        default:
            return XCTFail("a valid feed-held lease counts, got \(disposition)")
        }
        let validations = await validator.validationCount
        XCTAssertEqual(validations, 1, "exactly one pre-mutation lease check")
        let messages = try await manager.reader { db in
            try Int64.fetchOne(db, sql: """
                SELECT MAX(user_messages_since_update) FROM personalization_update_cursors
                """) ?? 0
        }
        XCTAssertEqual(messages, 1)
    }

    /// A lease revoked between acquisition and handling must drop the event
    /// with the delete/clear fence reason and perform NO counter mutation.
    func testInvalidatedLeaseDropsWithoutCounting() async throws {
        let validator = SyntheticLeaseValidator(validTokens: ["lease-b"])
        try await makeFixture(leases: validator)
        let conversation = try await IntelligenceTestSupport.seedOrdinaryConversation(manager)
        let message = try await IntelligenceTestSupport.seedUserMessage(
            manager, conversationID: conversation)
        let lease = PersonalizationEventOperationLease(token: "lease-b",
                                                       conversationID: conversation,
                                                       rootEpoch: 1)
        // The same conversation's delete drain started: the feed revoked
        // the token before our pre-mutation check.
        await validator.invalidate("lease-b")
        let disposition = await events.handleOrdinaryUserMessage(
            PersonalizationOrdinaryUserMessageEvent(
                messageID: message, conversationID: conversation, rootEpoch: 1,
                temporaryAtStart: false, temporaryAtCommit: false,
                operationLease: lease))
        XCTAssertEqual(disposition, .dropped(reason: .deletedOrFencedConversation))
        let rows = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM personalization_update_cursors")
        }
        XCTAssertEqual(rows, 0, "no cursor row/counter was written")
    }

    /// A lease that no trusted owner can validate is never trusted: the
    /// handler fails closed instead of pretending the lifetime was fenced.
    func testLeaseWithoutValidatingOwnerFailsClosed() async throws {
        try await makeFixture() // no ownedLeases bound
        let conversation = try await IntelligenceTestSupport.seedOrdinaryConversation(manager)
        let message = try await IntelligenceTestSupport.seedUserMessage(
            manager, conversationID: conversation)
        let lease = PersonalizationEventOperationLease(token: "lease-c",
                                                       conversationID: conversation,
                                                       rootEpoch: 1)
        let disposition = await events.handleOrdinaryUserMessage(
            PersonalizationOrdinaryUserMessageEvent(
                messageID: message, conversationID: conversation, rootEpoch: 1,
                temporaryAtStart: false, temporaryAtCommit: false,
                operationLease: lease))
        XCTAssertEqual(disposition, .dropped(reason: .deletedOrFencedConversation))
        let rows = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM personalization_update_cursors")
        }
        XCTAssertEqual(rows, 0)
    }

    /// The lease must name THIS conversation and THIS root epoch; a
    /// foreign/older lease can never authorize a write into a reused
    /// identity.
    func testForeignOrStaleLeaseIdentityIsRefused() async throws {
        let validator = SyntheticLeaseValidator(validTokens: ["lease-d", "lease-e"])
        try await makeFixture(leases: validator)
        let conversation = try await IntelligenceTestSupport.seedOrdinaryConversation(manager)
        let other = try await IntelligenceTestSupport.seedOrdinaryConversation(manager)
        let message = try await IntelligenceTestSupport.seedUserMessage(
            manager, conversationID: conversation)
        let foreign = PersonalizationEventOperationLease(token: "lease-d",
                                                         conversationID: other,
                                                         rootEpoch: 1)
        let foreignDisposition = await events.handleOrdinaryUserMessage(
            PersonalizationOrdinaryUserMessageEvent(
                messageID: message, conversationID: conversation, rootEpoch: 1,
                temporaryAtStart: false, temporaryAtCommit: false,
                operationLease: foreign))
        XCTAssertEqual(foreignDisposition, .dropped(reason: .deletedOrFencedConversation))
        let stale = PersonalizationEventOperationLease(token: "lease-e",
                                                       conversationID: conversation,
                                                       rootEpoch: 1)
        let staleDisposition = await events.handleOrdinaryUserMessage(
            PersonalizationOrdinaryUserMessageEvent(
                messageID: message, conversationID: conversation, rootEpoch: 2,
                temporaryAtStart: false, temporaryAtCommit: false,
                operationLease: stale))
        XCTAssertEqual(staleDisposition, .dropped(reason: .staleRootOwnerEpoch))
        let validations = await validator.validationCount
        XCTAssertEqual(validations, 0, "foreign/stale leases never reach a data mutation")
        let rows = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM personalization_update_cursors")
        }
        XCTAssertEqual(rows, 0)
    }
}
