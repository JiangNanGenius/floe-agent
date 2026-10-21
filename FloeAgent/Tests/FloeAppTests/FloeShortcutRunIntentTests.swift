// S3-C focused tests for the ACTUAL App Intent `perform()` entry points.
//
// The intents are constructed and executed exactly as Shortcuts would, but the
// service is injected through the DEBUG task-local seam: no launched App,
// preview bootstrap, real settings, user defaults, tasks or drafts are read or
// written, and no model is called. The seam is compiled out of Release.

#if canImport(AppIntents) && DEBUG
import AppIntents
import XCTest
@testable import FloeApp
import FloeCore
import FloeModels
import FloePersistence

final class FloeShortcutRunIntentTests: XCTestCase {

    private let conversationID = UUID(uuidString: "5C5C5C5C-0000-4000-8000-000000000001")!
    private let otherConversationID = UUID(uuidString: "6D6D6D6D-0000-4000-8000-000000000002")!
    private let runID = UUID(uuidString: "7E7E7E7E-0000-4000-8000-000000000003")!

    private struct StoredRow {
        var runID: UUID
        var conversationID: UUID
        var role: String
        var text: String
    }

    private final class World: @unchecked Sendable {
        var runs: [UUID: RunRecord] = [:]
        var conversations: [UUID: ConversationRecord] = [:]
        var events: [UUID: [RunEventRecord]] = [:]
        var rows: [UUID: StoredRow] = [:]
        var liveOwners: Set<UUID> = []
        var cancelCalls: [UUID] = []
        var startReceipt: FloeRunStartReceipt?
        var virtualTime: TimeInterval = 0
    }

    private func makeService(_ world: World) -> FloeShortcutRunService {
        let provider = ProviderProfile(
            id: UUID(), kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://example.invalid/v1")!, displayName: "Test")
        let model = ModelProfile(
            id: UUID(), providerID: provider.id, remoteModelID: "test-model",
            displayName: "Test", limits: ModelLimits(contextTokens: 8_000, maxOutputTokens: 1_000))
        return FloeShortcutRunService(deps: FloeShortcutRunDeps(
            ensureReady: { _ in },
            capabilityEnabled: { true },
            defaultModel: { (provider: provider, model: model) },
            startTask: { _ in
                world.startReceipt ?? FloeRunStartReceipt(
                    runID: UUID(), conversationID: UUID())
            },
            cancelRun: { world.cancelCalls.append($0) },
            hasLiveOwner: { world.liveOwners.contains($0) },
            loadRun: { world.runs[$0] },
            loadConversation: { world.conversations[$0] },
            recentRunEvents: { runID, limit in
                Array((world.events[runID] ?? []).suffix(limit))
            },
            earlierRunEvents: { runID, sequence, limit in
                Array((world.events[runID] ?? []).filter { $0.sequence < sequence }.suffix(limit))
            },
            provenFinalReplyText: { runID, conversationID, messageID in
                guard let row = world.rows[messageID],
                      row.runID == runID,
                      row.conversationID == conversationID,
                      row.role == "assistant" else { return nil }
                return row.text
            },
            monotonicNow: { world.virtualTime },
            pause: { seconds in
                world.virtualTime += seconds
                await Task.yield()
            }
        ))
    }

    private func seedCompleted(
        _ world: World,
        answer: String?,
        state: String = "completed",
        stopReason: String = "endTurn",
        prefixEvents: [RunEventRecord] = []
    ) throws {
        world.runs[runID] = RunRecord(
            id: runID, conversationID: conversationID, state: state,
            goal: "Synthetic intent goal",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_100))
        world.conversations[conversationID] = ConversationRecord(
            id: conversationID, title: "Synthetic intent task",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100))
        var events = prefixEvents
        var finalMessageID: UUID?
        if let answer {
            let messageID = UUID()
            finalMessageID = messageID
            world.rows[messageID] = StoredRow(
                runID: runID, conversationID: conversationID, role: "assistant",
                text: answer)
            events.append(RunEventRecord(
                runID: runID, sequence: 999, kind: .assistantText,
                payloadJSON: String(decoding: try JSONSerialization.data(
                    withJSONObject: ["text": answer]), as: UTF8.self)))
        }
        // The production terminal marker carries the proven message id only
        // when that row really persisted (or a real CONFIRM bound it).
        var terminalPayload = ["stopReason": stopReason]
        if let finalMessageID {
            terminalPayload["finalMessageID"] = finalMessageID.uuidString
        }
        world.events[runID] = events + [
            RunEventRecord(runID: runID, sequence: 1_000, kind: .terminal,
                           payloadJSON: String(decoding: try JSONSerialization.data(
                            withJSONObject: terminalPayload), as: UTF8.self))
        ]
    }

    private func entity(
        conversationID: UUID? = nil,
        title: String = "Synthetic intent task"
    ) -> FloeShortcutRunEntity {
        FloeShortcutRunEntity(
            runID: runID, conversationID: conversationID ?? self.conversationID,
            title: title, state: .running, isFinished: false, isSuccessful: false,
            requiresUserAction: false)
    }

    // MARK: Status

    @MainActor
    func testStatusIntentReturnsTheExactRun() async throws {
        let world = World()
        try seedCompleted(world, answer: "Final answer")
        let service = makeService(world)
        var intent = GetFloeRunStatusIntent()
        intent.run = entity()

        let result = try await FloeShortcutRunIntentBridge.$debugService.withValue(service) {
            try await intent.perform()
        }
        let returned = try XCTUnwrap(result.value)
        XCTAssertEqual(returned.runID, runID.uuidString)
        XCTAssertEqual(returned.conversationID, conversationID.uuidString)
        XCTAssertEqual(returned.state, .completed)
        XCTAssertTrue(returned.isFinished)
        XCTAssertTrue(returned.isSuccessful)
    }

    @MainActor
    func testStatusIntentRejectsCrossTaskReference() async throws {
        let world = World()
        try seedCompleted(world, answer: "Final answer")
        let service = makeService(world)
        var intent = GetFloeRunStatusIntent()
        intent.run = entity(conversationID: otherConversationID)

        do {
            _ = try await FloeShortcutRunIntentBridge.$debugService.withValue(service) {
                try await intent.perform()
            }
            XCTFail("a reference to another task must be rejected")
        } catch let error as FloeShortcutActionError {
            XCTAssertEqual(error.message, FloeL10n.l("shortcuts.run.error.ownership"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    @MainActor
    func testStatusIntentRejectsMalformedTaskIdentifier() async throws {
        let world = World()
        try seedCompleted(world, answer: "Final answer")
        let service = makeService(world)
        var entity = entity()
        entity.conversationID = "not-a-uuid"
        var intent = GetFloeRunStatusIntent()
        intent.run = entity

        do {
            _ = try await FloeShortcutRunIntentBridge.$debugService.withValue(service) {
                try await intent.perform()
            }
            XCTFail("a non-empty malformed task identity must be rejected")
        } catch let error as FloeShortcutActionError {
            XCTAssertEqual(error.message, FloeL10n.l("shortcuts.run.error.invalid_id"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    @MainActor
    func testStatusIntentRejectsEmptyTaskIdentifier() async throws {
        let world = World()
        try seedCompleted(world, answer: "Final answer")
        let service = makeService(world)
        var entity = entity()
        entity.conversationID = ""
        var intent = GetFloeRunStatusIntent()
        intent.run = entity

        do {
            _ = try await FloeShortcutRunIntentBridge.$debugService.withValue(service) {
                try await intent.perform()
            }
            XCTFail("an action reference without its owning task must be rejected")
        } catch let error as FloeShortcutActionError {
            XCTAssertEqual(error.message, FloeL10n.l("shortcuts.run.error.invalid_id"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    @MainActor
    func testCancelIntentRejectsMalformedTaskIdentifierBeforeStopping() async throws {
        let world = World()
        world.runs[runID] = RunRecord(
            id: runID, conversationID: conversationID, state: "streamingModel",
            goal: "Synthetic running goal",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), endedAt: nil)
        world.conversations[conversationID] = ConversationRecord(
            id: conversationID, title: "Synthetic running task",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        world.liveOwners.insert(runID)
        let service = makeService(world)
        var entity = entity()
        entity.conversationID = "not-a-uuid"
        var intent = CancelFloeRunIntent()
        intent.run = entity

        do {
            _ = try await FloeShortcutRunIntentBridge.$debugService.withValue(service) {
                try await intent.perform()
            }
            XCTFail("a non-empty malformed task identity must not cancel")
        } catch let error as FloeShortcutActionError {
            XCTAssertEqual(error.message, FloeL10n.l("shortcuts.run.error.invalid_id"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(world.cancelCalls.isEmpty)
    }

    /// Rehydration silently skips identifiers that are not UUIDs and never
    /// falls back to a conversation's latest run.
    @MainActor
    func testEntityQuerySkipsMalformedRunIdentifiers() async throws {
        let query = FloeShortcutRunEntityQuery()
        let values = try await query.entities(for: ["not-a-uuid", ""])
        XCTAssertTrue(values.isEmpty)
    }

    // MARK: Text

    @MainActor
    func testTextIntentReturnsOnlyTheExactRunsFinalText() async throws {
        let world = World()
        try seedCompleted(world, answer: "Final answer for this run")
        let service = makeService(world)
        var intent = GetFloeRunTextIntent()
        intent.run = entity()
        intent.includePartial = false

        let result = try await FloeShortcutRunIntentBridge.$debugService.withValue(service) {
            try await intent.perform()
        }
        XCTAssertEqual(result.value, "Final answer for this run")
    }

    @MainActor
    func testTextIntentRefusesStepOnlyRun() async throws {
        let world = World()
        try seedCompleted(
            world, answer: "I will check",
            prefixEvents: [RunEventRecord(
                runID: runID, sequence: 900, kind: .error,
                payloadJSON: "{\"message\":\"noFinalText\"}")])
        let service = makeService(world)
        var intent = GetFloeRunTextIntent()
        intent.run = entity()
        intent.includePartial = true

        do {
            _ = try await FloeShortcutRunIntentBridge.$debugService.withValue(service) {
                try await intent.perform()
            }
            XCTFail("an intermediate step must never be returned as the result")
        } catch let error as FloeShortcutActionError {
            XCTAssertEqual(error.message, FloeL10n.l("shortcuts.run.error.no_reply"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: Wait

    @MainActor
    func testWaitIntentReportsTimedOutWithoutStoppingTheRun() async throws {
        let world = World()
        world.runs[runID] = RunRecord(
            id: runID, conversationID: conversationID, state: "streamingModel",
            goal: "Synthetic running goal",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), endedAt: nil)
        world.conversations[conversationID] = ConversationRecord(
            id: conversationID, title: "Synthetic running task",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let service = makeService(world)
        var intent = WaitForFloeRunIntent()
        intent.run = entity()
        intent.timeoutSeconds = 1

        let result = try await FloeShortcutRunIntentBridge.$debugService.withValue(service) {
            try await intent.perform()
        }
        let returned = try XCTUnwrap(result.value)
        XCTAssertTrue(returned.waitTimedOut)
        XCTAssertEqual(returned.state, .running)
        XCTAssertTrue(world.cancelCalls.isEmpty,
            "a timed-out wait must not cancel the target run")
    }

    // MARK: Cancel

    @MainActor
    func testCancelIntentRejectsCrossTaskReferenceBeforeStopping() async throws {
        let world = World()
        world.runs[runID] = RunRecord(
            id: runID, conversationID: conversationID, state: "streamingModel",
            goal: "Synthetic running goal",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), endedAt: nil)
        world.conversations[conversationID] = ConversationRecord(
            id: conversationID, title: "Synthetic running task",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        world.liveOwners.insert(runID)
        let service = makeService(world)
        var intent = CancelFloeRunIntent()
        intent.run = entity(conversationID: otherConversationID)

        do {
            _ = try await FloeShortcutRunIntentBridge.$debugService.withValue(service) {
                try await intent.perform()
            }
            XCTFail("a reference to another task must not cancel")
        } catch let error as FloeShortcutActionError {
            XCTAssertEqual(error.message, FloeL10n.l("shortcuts.run.error.ownership"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(world.cancelCalls.isEmpty)
        XCTAssertEqual(world.runs[runID]?.state, "streamingModel")
    }

    @MainActor
    func testCancelIntentOnFinishedRunReportsFinishedWithoutRequesting() async throws {
        let world = World()
        try seedCompleted(world, answer: "Final answer")
        let service = makeService(world)
        var intent = CancelFloeRunIntent()
        intent.run = entity()

        let result = try await FloeShortcutRunIntentBridge.$debugService.withValue(service) {
            try await intent.perform()
        }
        let returned = try XCTUnwrap(result.value)
        XCTAssertTrue(world.cancelCalls.isEmpty)
        XCTAssertTrue(returned.isFinished)
        XCTAssertFalse(returned.cancellationRequested)
    }

    // MARK: Start

    @MainActor
    func testStartIntentReturnsTheReceiptsExactRun() async throws {
        let world = World()
        let receipt = FloeRunStartReceipt(runID: runID, conversationID: conversationID)
        world.startReceipt = receipt
        world.runs[runID] = RunRecord(
            id: runID, conversationID: conversationID, state: "preparing",
            goal: "Synthetic start goal",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), endedAt: nil)
        world.conversations[conversationID] = ConversationRecord(
            id: conversationID, title: "Synthetic start task",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let service = makeService(world)
        var intent = StartFloeRunIntent()
        intent.prompt = "Do the thing"
        intent.taskTitle = nil

        let result = try await FloeShortcutRunIntentBridge.$debugService.withValue(service) {
            try await intent.perform()
        }
        let returned = try XCTUnwrap(result.value)
        XCTAssertEqual(returned.runID, runID.uuidString)
        XCTAssertEqual(returned.conversationID, conversationID.uuidString)
    }

    // MARK: Legacy compatibility

    /// Compile-time contract: the historical RunFloeTaskIntent continues to
    /// return its original String identifier. The closure is never called, so
    /// no real task/model/settings are touched.
    @MainActor
    func testLegacyRunIntentStillReturnsStringIdentifier() {
        let perform: @MainActor (RunFloeTaskIntent) async throws -> String = { intent in
            let result = try await intent.perform()
            return try XCTUnwrap(result.value)
        }
        _ = perform
    }

    // MARK: - Run Scheduled Task (S4 selected-schedule route)

    private let scheduleID = UUID(uuidString: "8F8F8F8F-0000-4000-8000-000000000004")!

    @MainActor
    func testRunScheduledTaskIntentReturnsTheReceiptsExactRun() async throws {
        let world = World()
        world.runs[runID] = RunRecord(
            id: runID, conversationID: conversationID, state: "preparing",
            goal: "Synthetic scheduled goal",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), endedAt: nil)
        world.conversations[conversationID] = ConversationRecord(
            id: conversationID, title: "Synthetic scheduled task",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let service = makeService(world)
        let receipt = BackgroundRunCoordinator.FloeSelectedScheduleRunReceipt(
            runID: runID, conversationID: conversationID, freshlyLaunched: true)
        var captured: UUID?
        let route: @MainActor (UUID) async throws -> BackgroundRunCoordinator.FloeSelectedScheduleRunReceipt = { id in
            captured = id
            return receipt
        }
        var intent = RunScheduledTaskIntent()
        intent.schedule = TaskScheduleEntity(id: scheduleID, title: "Daily report")

        let result = try await RunScheduledTaskIntent.$debugRoute.withValue(route) {
            try await FloeShortcutRunIntentBridge.$debugService.withValue(service) {
                try await intent.perform()
            }
        }
        XCTAssertEqual(captured, scheduleID)
        let returned = try XCTUnwrap(result.value)
        XCTAssertEqual(returned.runID, runID.uuidString)
        XCTAssertEqual(returned.conversationID, conversationID.uuidString)
        XCTAssertEqual(returned.state, .running)
    }

    @MainActor
    func testRunScheduledTaskIntentRejectsUnprovenReference() async throws {
        // The receipt claims a conversation the durable run does not belong
        // to: the shared ownership validation must refuse it (no broad
        // scheduled-run allow).
        let world = World()
        world.runs[runID] = RunRecord(
            id: runID, conversationID: otherConversationID, state: "preparing",
            goal: "Synthetic scheduled goal",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), endedAt: nil)
        world.conversations[otherConversationID] = ConversationRecord(
            id: otherConversationID, title: "Other conversation",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let service = makeService(world)
        let receipt = BackgroundRunCoordinator.FloeSelectedScheduleRunReceipt(
            runID: runID, conversationID: conversationID, freshlyLaunched: true)
        let route: @MainActor (UUID) async throws -> BackgroundRunCoordinator.FloeSelectedScheduleRunReceipt = { _ in
            receipt
        }
        var intent = RunScheduledTaskIntent()
        intent.schedule = TaskScheduleEntity(id: scheduleID, title: "Daily report")

        do {
            _ = try await RunScheduledTaskIntent.$debugRoute.withValue(route) {
                try await FloeShortcutRunIntentBridge.$debugService.withValue(service) {
                    try await intent.perform()
                }
            }
            XCTFail("a receipt that cannot prove the durable owner must be rejected")
        } catch let error as FloeShortcutActionError {
            XCTAssertEqual(error.message, FloeL10n.l("shortcuts.run.error.ownership"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// The selected-schedule receipt flows through the SAME production
    /// exact-run validation: a notes or temporary workspace stays invisible
    /// (`.unavailable`), never an answer, and never a broad scheduled-run
    /// allow.
    @MainActor
    func testRunScheduledTaskIntentKeepsNotesAndTemporaryFences() async throws {
        for purpose in [ConversationPurpose.notes, ConversationPurpose.temporary] {
            let world = World()
            world.runs[runID] = RunRecord(
                id: runID, conversationID: conversationID, state: "completed",
                goal: "Synthetic scheduled goal",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                endedAt: Date(timeIntervalSince1970: 1_700_000_100))
            world.conversations[conversationID] = ConversationRecord(
                id: conversationID, title: "Hidden workspace",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
                purpose: purpose)
            let service = makeService(world)
            let receipt = BackgroundRunCoordinator.FloeSelectedScheduleRunReceipt(
                runID: runID, conversationID: conversationID, freshlyLaunched: true)
            let route: @MainActor (UUID) async throws -> BackgroundRunCoordinator.FloeSelectedScheduleRunReceipt = { _ in
                receipt
            }
            var intent = RunScheduledTaskIntent()
            intent.schedule = TaskScheduleEntity(id: scheduleID, title: "Daily report")

            let result = try await RunScheduledTaskIntent.$debugRoute.withValue(route) {
                try await FloeShortcutRunIntentBridge.$debugService.withValue(service) {
                    try await intent.perform()
                }
            }
            XCTAssertEqual(result.value.state, .unavailable, "purpose \(purpose)")
        }
    }

    @MainActor
    func testRunScheduledTaskIntentMapsFailureCopy() async throws {
        let cases: [(BackgroundRunCoordinator.FloeSelectedScheduleFailure, String)] = [
            (.scheduleDeleted, "shortcuts.schedule.run.error.not_found"),
            (.scheduleDisabled, "shortcuts.schedule.run.error.schedule_disabled"),
            (.noDueOccurrence(eventDriven: false), "shortcuts.schedule.run.error.not_due"),
            (.noDueOccurrence(eventDriven: true), "shortcuts.schedule.run.error.event_driven"),
            (.concurrentlyClaimed, "shortcuts.schedule.run.error.claimed"),
            (.environmentUnavailable, "shortcuts.schedule.run.error.environment"),
            (.modelUnavailable, "shortcuts.schedule.run.error.model"),
            (.storageUnavailable, "shortcuts.run.error.storage"),
            (.launchFailed("detail stays internal"), "shortcuts.schedule.run.error.launch_failed"),
            (.runReferenceMismatch, "shortcuts.schedule.run.error.reference_mismatch"),
            (.permissionUnavailable, "shortcuts.schedule.run.error.permission"),
        ]
        for (failure, key) in cases {
            let route: @MainActor (UUID) async throws -> BackgroundRunCoordinator.FloeSelectedScheduleRunReceipt = { _ in
                throw failure
            }
            var intent = RunScheduledTaskIntent()
            intent.schedule = TaskScheduleEntity(id: scheduleID, title: "Daily report")
            do {
                _ = try await RunScheduledTaskIntent.$debugRoute.withValue(route) {
                    try await intent.perform()
                }
                XCTFail("failure \(failure) must throw")
            } catch let error as FloeShortcutActionError {
                XCTAssertEqual(error.message, FloeL10n.l(key), "copy for \(failure)")
            } catch {
                XCTFail("unexpected error \(error) for \(failure)")
            }
        }
    }

    @MainActor
    func testRunScheduledTaskIntentRejectsMalformedScheduleBeforeRouting() async throws {
        var called = false
        let route: @MainActor (UUID) async throws -> BackgroundRunCoordinator.FloeSelectedScheduleRunReceipt = { _ in
            called = true
            return BackgroundRunCoordinator.FloeSelectedScheduleRunReceipt(
                runID: runID, conversationID: conversationID, freshlyLaunched: true)
        }
        var entity = TaskScheduleEntity(id: scheduleID, title: "Daily report")
        entity.id = "not-a-uuid"
        var intent = RunScheduledTaskIntent()
        intent.schedule = entity

        do {
            _ = try await RunScheduledTaskIntent.$debugRoute.withValue(route) {
                try await intent.perform()
            }
            XCTFail("a malformed schedule identity must be rejected")
        } catch let error as FloeShortcutActionError {
            XCTAssertEqual(error.message, FloeL10n.l("shortcuts.run.error.invalid_id"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertFalse(called, "the route must never run for a malformed identity")
    }

    // MARK: TaskScheduleEntityQuery

    @MainActor
    func testScheduleEntityQueryRehydratesExplicitIDsOnly() async throws {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let enabled = TaskScheduleRecord(
            title: "Daily", prompt: "p", cadence: .daily,
            scheduledAt: Date().addingTimeInterval(-60))
        let disabled = TaskScheduleRecord(
            title: "Off", prompt: "p", cadence: .once,
            scheduledAt: Date().addingTimeInterval(-60), isEnabled: false)
        try await store.save(enabled)
        try await store.save(disabled)
        let query = TaskScheduleEntityQuery()
        let values = try await TaskScheduleEntityQuery.$debugEnvironment.withValue(environment) {
            try await query.entities(for: [
                enabled.id.uuidString,
                disabled.id.uuidString,
                UUID().uuidString,   // not found: skipped
                "not-a-uuid"         // malformed: skipped
            ])
        }
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0].id, enabled.id.uuidString)
        XCTAssertEqual(values[0].title, "Daily")
        XCTAssertEqual(values[1].id, disabled.id.uuidString)
    }

    @MainActor
    func testScheduleEntityQuerySuggestsEnabledSchedulesOnly() async throws {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let enabled = TaskScheduleRecord(
            title: "On", prompt: "p", cadence: .daily,
            scheduledAt: Date().addingTimeInterval(-60))
        try await store.save(enabled)
        try await store.save(TaskScheduleRecord(
            title: "Off", prompt: "p", cadence: .once,
            scheduledAt: Date().addingTimeInterval(-60), isEnabled: false))
        let query = TaskScheduleEntityQuery()
        let values = try await TaskScheduleEntityQuery.$debugEnvironment.withValue(environment) {
            try await query.suggestedEntities()
        }
        XCTAssertEqual(values.map(\.title), ["On"])
        // The stable ID stays an internal property; the display is title-only.
        XCTAssertEqual(values[0].id, enabled.id.uuidString)
    }
}
#endif
