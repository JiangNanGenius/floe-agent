// SPDX-License-Identifier: MPL-2.0
//
// G07.3B focused deterministic tests for the real scheduled-task service.
//
// The tests use the REAL file-backed DatabaseManager migration chain and the
// REAL SQLiteTaskScheduleStore/TaskSchedulePlanner. Only the run launcher,
// environment authority metadata, model/workspace lookups and run state are
// test doubles. Nothing here is executed by the authoring lane; these are
// host-runnable XCTest sources for Main's combined freeze.
import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
@testable import FloeAndroidCore

// MARK: - Test doubles

private final class G073TestWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var workspacesStorage: [UUID: G073WorkspaceSummary] = [:]
    private var modelsStorage: [UUID: G073ModelSummary] = [:]
    private var defaultModelStorage: UUID?
    private var runStatesStorage: [UUID: String] = [:]
    private var stopReasonsStorage: [UUID: String] = [:]
    private var runConversationsStorage: [UUID: UUID] = [:]
    private var conversationWorkspacesStorage: [UUID: UUID] = [:]
    private var recentRunsStorage: [G073ScheduleRecentRun] = []

    func put(workspace: G073WorkspaceSummary) {
        lock.lock(); workspacesStorage[workspace.id] = workspace; lock.unlock()
    }
    func removeWorkspace(_ id: UUID) {
        lock.lock(); workspacesStorage[id] = nil; lock.unlock()
    }
    func workspace(_ id: UUID) -> G073WorkspaceSummary? {
        lock.lock(); defer { lock.unlock() }; return workspacesStorage[id]
    }
    func allWorkspaces() -> [G073WorkspaceSummary] {
        lock.lock(); defer { lock.unlock() }
        return workspacesStorage.values.sorted { $0.name < $1.name }
    }
    func put(model: G073ModelSummary) {
        lock.lock(); modelsStorage[model.id] = model; lock.unlock()
    }
    func removeModel(_ id: UUID) {
        lock.lock(); modelsStorage[id] = nil; lock.unlock()
    }
    func model(_ id: UUID) -> G073ModelSummary? {
        lock.lock(); defer { lock.unlock() }; return modelsStorage[id]
    }
    func allModels() -> [G073ModelSummary] {
        lock.lock(); defer { lock.unlock() }
        return modelsStorage.values.sorted { $0.displayName < $1.displayName }
    }
    func setDefaultModel(_ id: UUID?) {
        lock.lock(); defaultModelStorage = id; lock.unlock()
    }
    func defaultModel() -> UUID? {
        lock.lock(); defer { lock.unlock() }; return defaultModelStorage
    }
    func setRunState(_ id: UUID, _ state: String?) {
        lock.lock()
        if let state { runStatesStorage[id] = state } else { runStatesStorage[id] = nil }
        lock.unlock()
    }
    func runState(_ id: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }; return runStatesStorage[id]
    }
    func setStopReason(_ id: UUID, _ reason: String?) {
        lock.lock()
        if let reason { stopReasonsStorage[id] = reason } else { stopReasonsStorage[id] = nil }
        lock.unlock()
    }
    func stopReason(_ id: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }; return stopReasonsStorage[id]
    }
    func setRunConversation(_ runID: UUID, _ conversationID: UUID?) {
        lock.lock()
        runConversationsStorage[runID] = conversationID
        lock.unlock()
    }
    func runConversation(_ runID: UUID) -> UUID? {
        lock.lock(); defer { lock.unlock() }; return runConversationsStorage[runID]
    }
    func setConversationWorkspace(_ conversationID: UUID, _ workspaceID: UUID?) {
        lock.lock()
        conversationWorkspacesStorage[conversationID] = workspaceID
        lock.unlock()
    }
    func workspaceForConversation(_ conversationID: UUID) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return conversationWorkspacesStorage[conversationID]
    }
    func setRecentRuns(_ runs: [G073ScheduleRecentRun]) {
        lock.lock(); recentRunsStorage = runs; lock.unlock()
    }
    func recentRuns(_ limit: Int) -> [G073ScheduleRecentRun] {
        lock.lock(); defer { lock.unlock() }
        return Array(recentRunsStorage.prefix(max(0, limit)))
    }
}

private final class G073NowBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Date
    init(_ date: Date) { storage = date }
    var value: Date {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

private actor G073LaunchRecorder: G073ScheduledRunLaunching {
    private(set) var requests: [G073ScheduledLaunchRequest] = []
    private var result = G073ScheduledLaunchResult.accepted()

    func setResult(_ value: G073ScheduledLaunchResult) { result = value }
    func requestCount() -> Int { requests.count }
    func request(at index: Int) -> G073ScheduledLaunchRequest? {
        guard requests.indices.contains(index) else { return nil }
        return requests[index]
    }

    func launchScheduled(_ request: G073ScheduledLaunchRequest) async
        -> G073ScheduledLaunchResult {
        requests.append(request)
        return result
    }
}

// MARK: - Tests

final class G073TaskScheduleTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!
    private var store: SQLiteTaskScheduleStore!
    private var world: G073TestWorld!
    private var launcher: G073LaunchRecorder!
    private var ownership: G073ScheduleEnvironmentOwnership!
    private var nowBox: G073NowBox!
    private var service: G073TaskScheduleService!

    private let workspaceID = UUID()
    private let otherWorkspaceID = UUID()
    private let modelID = UUID()
    private let providerID = UUID()
    private let environmentID = "g073-project-env"
    private let conversationID = UUID()

    private var fixedNow: Date { nowBox.value }

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("g073-schedule-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try DatabaseManager(path: directory.appendingPathComponent("db.sqlite"))
        try await database.migrate()
        // The real store enforces the workspaces FK. Seed the two project rows
        // this fixture freezes so schedule saves exercise the real schema.
        let workspaceIDs = [workspaceID, otherWorkspaceID]
        try await database.writer { db in
            for id in workspaceIDs {
                try db.execute(sql: """
                    INSERT INTO workspaces (id, name, root_bookmark, created_at, updated_at)
                    VALUES (?, 'fixture-project', ?, '2026-10-31T00:00:00.000Z',
                            '2026-10-31T00:00:00.000Z')
                    """, arguments: [id.uuidString, Data([0x01])])
            }
        }
        store = SQLiteTaskScheduleStore(database: database)
        world = G073TestWorld()
        launcher = G073LaunchRecorder()
        nowBox = G073NowBox(Date(timeIntervalSince1970: 1_700_000_000))
        world.put(workspace: G073WorkspaceSummary(
            id: workspaceID, name: "Project", kind: .project))
        world.put(workspace: G073WorkspaceSummary(
            id: otherWorkspaceID, name: "Other", kind: .project))
        world.put(model: G073ModelSummary(
            id: modelID, providerID: providerID,
            displayName: "Fixture model", providerName: "Fixture", supportsChat: true))
        world.setDefaultModel(modelID)

        ownership = G073ScheduleEnvironmentOwnership { [workspaceID] _ in
            workspaceID
        }
        ownership.registerHostMetadata([
            G073EnvironmentMetadata(
                id: environmentID, kind: .project, ownerID: workspaceID.uuidString,
                name: "Project environment", state: "active", requiresRebuild: false,
                executionBackend: G073EnvironmentMetadata.requiredExecutionBackend),
        ], at: fixedNow)

        let world = self.world!
        let launcher = self.launcher!
        let ownership = self.ownership!
        let store = self.store!
        let nowBox = self.nowBox!
        service = G073TaskScheduleService(
            epoch: 7,
            store: store,
            dependencies: G073TaskScheduleDependencies(
                launch: launcher,
                workspaceForConversation: { world.workspaceForConversation($0) },
                workspace: { world.workspace($0) },
                workspaces: { world.allWorkspaces() },
                model: { world.model($0) },
                models: { world.allModels() },
                defaultModelID: { world.defaultModel() },
                runState: { world.runState($0) },
                terminalStopReason: { world.stopReason($0) },
                claimedOccurrences: {
                    let rows = (try? await store.recentOccurrences(limit: 200)) ?? []
                    return rows.filter { $0.state == .claimed || $0.state == .running }
                        .map {
                            G073ClaimedOccurrence(
                                id: $0.id, scheduleID: $0.scheduleID,
                                scheduledFor: $0.scheduledFor, runID: $0.runID)
                        }
                },
                environmentSource: nil,
                environmentOwnership: ownership,
                now: { nowBox.value },
                recentRunChoices: { limit in world.recentRuns(limit) },
                runConversation: { world.runConversation($0) }))
    }

    override func tearDown() async throws {
        if let database { try? await database.close() }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    // MARK: Helpers

    private func draft(
        cadence: TaskScheduleCadence = .once,
        scheduledAt: Date? = nil,
        workspace: UUID? = nil,
        environment: String? = nil,
        upstream: UUID? = nil,
        intervalSeconds: Int? = nil
    ) -> G073ScheduleDraft {
        G073ScheduleDraft(
            title: "Scheduled fixture",
            prompt: "Summarize the project status.",
            cadence: cadence,
            scheduledAt: scheduledAt ?? fixedNow.addingTimeInterval(3_600),
            weekday: cadence == .weekly
                ? Calendar(identifier: .gregorian).component(.weekday, from: fixedNow + 3_600)
                : nil,
            intervalSeconds: intervalSeconds,
            anchorTimezone: "UTC",
            upstreamRunID: upstream,
            workspaceID: workspace,
            modelID: modelID,
            environmentID: environment,
            policy: DraftTaskPolicy(approvalMode: .automatic))
    }

    private func dispatchExact(_ id: UUID) async -> G073ScheduleDispatchOutcome {
        await service.dispatch(.init(
            scheduleID: id,
            trigger: .exact,
            exactAlarmAllowed: true,
            flexibleChosen: false))
    }

    private func occurrences(_ id: UUID) async -> [TaskScheduleOccurrence] {
        (try? await store.occurrences(scheduleID: id, limit: 50)) ?? []
    }

    private func launchCount() async -> Int { await launcher.requestCount() }

    // MARK: CRUD + revision

    func testCreateListDetailAndRevisionGuardedUpdate() async {
        let created = await service.create(draft(scheduledAt: fixedNow + 3_600))
        guard created.accepted, let detail = created.detail else {
            return XCTFail("create refused: \(String(describing: created.code))")
        }
        XCTAssertEqual(detail.summary.title, "Scheduled fixture")
        XCTAssertEqual(detail.summary.modelID, modelID)
        XCTAssertFalse(detail.summary.revision.isEmpty)
        let listed = await service.list()
        XCTAssertEqual(listed.count, 1)

        var changed = draft(scheduledAt: fixedNow + 7_200)
        changed.title = "Changed"
        let stale = await service.update(id: detail.summary.id, draft: changed,
                                         expectedRevision: "stale")
        XCTAssertFalse(stale.accepted)
        XCTAssertEqual(stale.code, .revisionMismatch)

        let updated = await service.update(id: detail.summary.id, draft: changed,
                                           expectedRevision: detail.summary.revision)
        XCTAssertTrue(updated.accepted)
        XCTAssertEqual(updated.detail?.summary.title, "Changed")

        let disabled = await service.setEnabled(
            id: detail.summary.id, enabled: false,
            expectedRevision: updated.detail?.summary.revision ?? "")
        XCTAssertTrue(disabled.accepted)
        XCTAssertEqual(disabled.detail?.summary.isEnabled, false)

        let deleted = await service.delete(
            id: detail.summary.id,
            expectedRevision: disabled.detail?.summary.revision ?? "")
        XCTAssertTrue(deleted.accepted)
        let gone = await service.detail(id: detail.summary.id)
        XCTAssertNil(gone)
    }

    func testAllFiveCadencesUseTheRealPlanner() async throws {
        let onceAnchor = fixedNow.addingTimeInterval(7_200)
        let once = await service.create(draft(cadence: .once, scheduledAt: onceAnchor))
        XCTAssertEqual(once.detail?.summary.nextFireAt, onceAnchor)

        let daily = await service.create(draft(cadence: .daily, scheduledAt: fixedNow))
        let dailyNext = try XCTUnwrap(daily.detail?.summary.nextFireAt)
        XCTAssertEqual(dailyNext.timeIntervalSince(fixedNow), 86_400, accuracy: 1)

        let weekly = await service.create(draft(cadence: .weekly, scheduledAt: fixedNow))
        let weeklyNext = try XCTUnwrap(weekly.detail?.summary.nextFireAt)
        XCTAssertEqual(weeklyNext.timeIntervalSince(fixedNow), 604_800, accuracy: 1)

        let interval = await service.create(draft(
            cadence: .interval, scheduledAt: fixedNow, intervalSeconds: 3_600))
        let intervalNext = try XCTUnwrap(interval.detail?.summary.nextFireAt)
        XCTAssertEqual(intervalNext.timeIntervalSince(fixedNow), 3_600, accuracy: 1)

        let upstreamRun = UUID()
        world.setRunState(upstreamRun, "streaming")
        let afterSuccess = await service.create(draft(
            cadence: .afterSuccess, upstream: upstreamRun))
        XCTAssertTrue(afterSuccess.accepted)
        XCTAssertNil(afterSuccess.detail?.summary.nextFireAt)
        XCTAssertEqual(afterSuccess.detail?.summary.cadence, .afterSuccess)
    }

    func testIntervalAndAfterSuccessValidationRefusesInvalidBindings() async {
        let tooShort = await service.create(draft(
            cadence: .interval, scheduledAt: fixedNow, intervalSeconds: 30))
        XCTAssertFalse(tooShort.accepted)

        let missingUpstream = await service.create(draft(cadence: .afterSuccess))
        XCTAssertFalse(missingUpstream.accepted)

        let terminalUpstream = UUID()
        world.setRunState(terminalUpstream, "completed")
        let deadBinding = await service.create(draft(
            cadence: .afterSuccess, upstream: terminalUpstream))
        XCTAssertFalse(deadBinding.accepted)
    }

    // MARK: After-success run choices (real run-store projection)

    func testOptionsExposeBoundedLiveRunChoicesAndSkipSettledRuns() async {
        var rows: [G073ScheduleRecentRun] = []
        // A completed run is projected first but can never precede success.
        let settled = UUID()
        world.setRunState(settled, "completed")
        rows.append(G073ScheduleRecentRun(
            id: settled, conversationID: UUID(), conversationTitle: "Finished",
            state: "completed", startedAt: fixedNow))
        for index in 0..<(G073ScheduleLimits.maximumRunChoices + 5) {
            let runID = UUID()
            let conversationID = UUID()
            world.setRunState(runID, "streamingModel")
            world.setRunConversation(runID, conversationID)
            world.setConversationWorkspace(conversationID, workspaceID)
            rows.append(G073ScheduleRecentRun(
                id: runID, conversationID: conversationID,
                conversationTitle: "Active task \(index)",
                state: "streamingModel",
                startedAt: fixedNow.addingTimeInterval(TimeInterval(-index))))
        }
        world.setRecentRuns(rows)

        let options = await service.options()
        XCTAssertEqual(options.upstreamRunChoices.count,
                       G073ScheduleLimits.maximumRunChoices)
        XCTAssertFalse(options.upstreamRunChoices.contains { $0.runID == settled })
        let first = options.upstreamRunChoices.first
        XCTAssertEqual(first?.runID, rows[1].id)
        XCTAssertEqual(first?.label, "Active task 0")
        XCTAssertEqual(first?.workspaceID, workspaceID)
        XCTAssertEqual(first?.conversationID, rows[1].conversationID)
    }

    func testAfterSuccessRequiresAnUpstreamRunInTheBoundProject() async {
        // The run exists and is live, but its conversation belongs to a
        // DIFFERENT project: freezing this schedule would follow an
        // unrelated task, so it must be refused.
        let foreignRun = UUID()
        let foreignConversation = UUID()
        world.setRunState(foreignRun, "streamingModel")
        world.setRunConversation(foreignRun, foreignConversation)
        world.setConversationWorkspace(foreignConversation, otherWorkspaceID)
        let foreign = await service.create(draft(
            cadence: .afterSuccess, workspace: workspaceID, upstream: foreignRun))
        XCTAssertFalse(foreign.accepted)

        // No durable conversation binding: the project proof fails closed.
        let unboundRun = UUID()
        world.setRunState(unboundRun, "streamingModel")
        let unbound = await service.create(draft(
            cadence: .afterSuccess, workspace: workspaceID, upstream: unboundRun))
        XCTAssertFalse(unbound.accepted)

        // Same project: accepted and frozen.
        let matchingRun = UUID()
        let matchingConversation = UUID()
        world.setRunState(matchingRun, "streamingModel")
        world.setRunConversation(matchingRun, matchingConversation)
        world.setConversationWorkspace(matchingConversation, workspaceID)
        let accepted = await service.create(draft(
            cadence: .afterSuccess, workspace: workspaceID, upstream: matchingRun))
        XCTAssertTrue(accepted.accepted,
                      "code=\(accepted.code?.rawValue ?? "nil") reason=\(accepted.reason ?? "")")
        XCTAssertEqual(accepted.detail?.summary.upstreamRunID, matchingRun)
        XCTAssertEqual(accepted.detail?.summary.workspaceID, workspaceID)

        // A new independent workspace per occurrence has no frozen project,
        // so only the live top-level run requirement applies.
        let newWorkspaceRun = UUID()
        world.setRunState(newWorkspaceRun, "streamingModel")
        let newWorkspace = await service.create(draft(
            cadence: .afterSuccess, upstream: newWorkspaceRun))
        XCTAssertTrue(newWorkspace.accepted)
        XCTAssertNil(newWorkspace.detail?.summary.workspaceID)
    }

    // MARK: Bounded frame contract (actual UTF-8, escaping-aware)

    private func wireSummary(_ title: String,
                             id: UUID = UUID()) -> G073ScheduleSummary {
        G073ScheduleSummary(
            id: id, title: title, promptPreview: title, cadence: .once,
            isEnabled: true, scheduledAt: fixedNow, weekday: nil,
            intervalSeconds: nil, anchorTimezone: "UTC",
            nextFireAt: fixedNow, lastStartedAt: nil,
            modelID: modelID, modelName: title,
            environmentID: environmentID, environmentName: title,
            workspaceID: workspaceID, workspaceName: title,
            policy: DraftTaskPolicy(), upstreamRunID: nil, revision: "rev",
            lastOccurrence: nil, needsAttention: false)
    }

    private func hostileLabel() -> String {
        // Quotes/backslashes/control characters escape, and multibyte
        // Unicode is counted by BYTES, not characters.
        "\"\\\u{0001}中" + String(repeating: "定", count: 40)
    }

    func testOptionsValueAlwaysFitsTheFrameWithWholeRowsOnly() {
        let label = hostileLabel()
        let workspaces = (0..<50).map {
            G073ScheduleOptions.Workspace(id: UUID(), name: label + "\($0)")
        }
        let models = (0..<100).map {
            G073ScheduleOptions.Model(id: UUID(), providerID: UUID(),
                                      displayName: label + "\($0)",
                                      providerName: label + "p\($0)")
        }
        let environments = (0..<50).map {
            G073ScheduleOptions.Environment(id: "env-\($0)-" + UUID().uuidString,
                                            name: label)
        }
        let choices = (0..<20).map {
            G073ScheduleOptions.RunChoice(
                runID: UUID(), conversationID: UUID(),
                label: label + "\($0)", state: "streamingModel",
                startedAt: fixedNow, workspaceID: workspaceID)
        }
        let options = G073ScheduleOptions(
            workspaces: workspaces, models: models, environments: environments,
            upstreamRunChoices: choices, defaultModelID: modelID,
            currentTimezone: "UTC", environmentSelectionAvailable: true)
        let value = G073WireValue.options(options)
        XCTAssertLessThanOrEqual(G073WireValue.serializedBytes(value),
                                 G073WireValue.maximumValueBytes)
        guard case .object(let root) = value,
              case .array(let visibleEnvironments)? = root["environments"],
              case .array(let visibleModels)? = root["models"],
              case .array(let visibleWorkspaces)? = root["workspaces"],
              case .array(let visibleChoices)? = root["runChoices"],
              case .object(let counts)? = root["counts"],
              case .bool(let truncated)? = root["truncated"] else {
            return XCTFail("bounded options must stay an object document")
        }
        XCTAssertEqual(counts["workspaces"],
                       DesignJSONValue.integer(Int64(workspaces.count)))
        XCTAssertEqual(counts["models"],
                       DesignJSONValue.integer(Int64(models.count)))
        XCTAssertEqual(counts["environments"],
                       DesignJSONValue.integer(Int64(environments.count)))
        XCTAssertEqual(counts["runChoices"],
                       DesignJSONValue.integer(Int64(choices.count)))
        XCTAssertEqual(truncated,
                       visibleWorkspaces.count < workspaces.count ||
                       visibleModels.count < models.count ||
                       visibleEnvironments.count < environments.count ||
                       visibleChoices.count < choices.count)
        // No identifier is ever shortened: every visible environment id is a
        // whole source id.
        let sourceIDs = Set(environments.map(\.id))
        for row in visibleEnvironments {
            guard case .object(let fields) = row,
                  case .string(let id)? = fields["id"] else {
                return XCTFail("environment row must carry a whole id")
            }
            XCTAssertTrue(sourceIDs.contains(id))
        }
    }

    func testSummaryPageBudgetKeepsWholeRecordsAndHonestTruncation() {
        let summaries = (0..<50).map { wireSummary(hostileLabel() + "\($0)") }
        let bounded = G073WireValue.boundedItems(
            summaries, capBytes: 34 * 1024, encode: G073WireValue.summary)
        let document = DesignJSONValue.object([
            "schedules": .array(bounded.items),
            "count": .integer(Int64(bounded.items.count)),
            "totalCount": .integer(Int64(summaries.count)),
            "truncated": .bool(bounded.truncated),
        ])
        XCTAssertLessThanOrEqual(G073WireValue.serializedBytes(document),
                                 G073WireValue.maximumValueBytes)
        XCTAssertEqual(bounded.truncated,
                       bounded.items.count < summaries.count)
        let sourceIDs = Set(summaries.map { $0.id.uuidString })
        for item in bounded.items {
            guard case .object(let fields) = item,
                  case .string(let id)? = fields["id"] else {
                return XCTFail("summary must be a whole record")
            }
            XCTAssertTrue(sourceIDs.contains(id))
        }
    }

    func testOversizedMutationReportsSuccessWithBoundedSummaryProjection() {
        let summary = wireSummary("Committed schedule")
        let huge = String(repeating: "\"\\\u{0001}", count: 6_000)
        let detail = G073ScheduleDetail(
            summary: summary, prompt: huge, createdAt: fixedNow,
            updatedAt: fixedNow,
            policyJSON: G073SchedulePolicyCodec.encode(DraftTaskPolicy()))
        let mutation = G073ScheduleMutationResult(
            accepted: true, detail: detail, revision: "rev")
        let value = G073WireValue.mutation(mutation, scheduleID: summary.id)
        XCTAssertLessThanOrEqual(G073WireValue.serializedBytes(value),
                                 G073WireValue.maximumValueBytes)
        guard case .object(let root) = value,
              case .string(let projection)? = root["projection"],
              case .object(let schedule)? = root["schedule"] else {
            return XCTFail("oversized mutation must degrade to a summary")
        }
        XCTAssertEqual(projection, "summary")
        XCTAssertNil(schedule["prompt"])
        XCTAssertEqual(schedule["id"],
                       DesignJSONValue.string(summary.id.uuidString))
    }

    // MARK: Explicit run now → single foreground-admitted dispatcher

    func testRunNowQueuesWithoutLaunchingUntilTheDispatcherClaimsIt() async throws {
        let created = await service.create(draft(
            cadence: .daily, scheduledAt: fixedNow.addingTimeInterval(3_600)))
        let detail = try XCTUnwrap(created.detail)
        let before = await launchCount()
        XCTAssertEqual(before, 0)

        let queued = await service.runNow(
            id: detail.summary.id, expectedRevision: detail.summary.revision)
        XCTAssertEqual(queued.state, .queued)
        let occurrenceID = try XCTUnwrap(queued.occurrenceID)
        XCTAssertNil(queued.runID)
        XCTAssertNil(queued.conversationID)
        let launchesAfterRunNow = await launchCount()
        XCTAssertEqual(launchesAfterRunNow, 0,
                       "runNow must never launch an Agent itself")

        let storedOccurrence = try await store.occurrence(id: occurrenceID)
        let stored = try XCTUnwrap(storedOccurrence)
        XCTAssertEqual(stored.state, .pending)
        XCTAssertTrue(stored.dedupeKey.hasPrefix("manual:"))

        // The App-owned dispatch worker is the ONE claim/launch path and
        // reaches the ordinary foreground binding, not this command.
        let dispatched = await service.dispatchPending(limit: 3)
        XCTAssertEqual(dispatched.count, 1)
        XCTAssertEqual(dispatched.first?.state, .launched)
        let runID = try XCTUnwrap(dispatched.first?.runID)
        let recordedRequest = await launcher.request(at: 0)
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.occurrenceID, occurrenceID)
        XCTAssertEqual(request.runID,
                       G073ScheduleIdentity.runID(occurrenceID: occurrenceID))
        XCTAssertEqual(request.conversationID,
                       G073ScheduleIdentity.conversationID(occurrenceID: occurrenceID))
        XCTAssertNotEqual(runID, detail.summary.upstreamRunID)
        let launchesAfterDispatch = await launchCount()
        XCTAssertEqual(launchesAfterDispatch, 1)

        // A duplicate worker wake after the claim cannot launch a second run.
        let duplicate = await service.dispatchPending(limit: 3)
        XCTAssertFalse(duplicate.contains { $0.state == .launched })
        let launchesAfterDuplicate = await launchCount()
        XCTAssertEqual(launchesAfterDuplicate, 1)
    }

    func testStopPendingCancelsTheQueuedOccurrenceDurablyAndKeepsCadence() async throws {
        let created = await service.create(draft(
            cadence: .daily, scheduledAt: fixedNow.addingTimeInterval(3_600)))
        let detail = try XCTUnwrap(created.detail)
        let queued = await service.runNow(
            id: detail.summary.id, expectedRevision: detail.summary.revision)
        let occurrenceID = try XCTUnwrap(queued.occurrenceID)
        let launchesBefore = await launchCount()
        XCTAssertEqual(launchesBefore, 0)

        // Mirror the Kotlin pre-submit Stop wire path (same command).
        let stopped = await service.dispatch(.init(
            scheduleID: detail.summary.id, trigger: .pending,
            exactAlarmAllowed: true, flexibleChosen: false,
            stopPending: true))
        XCTAssertEqual(stopped.state, .cancelled)
        XCTAssertEqual(stopped.occurrenceID, occurrenceID)
        let storedOccurrence = try await store.occurrence(id: occurrenceID)
        let stored = try XCTUnwrap(storedOccurrence)
        XCTAssertEqual(stored.state, .cancelled)

        // The observer/dispatcher can never resurrect that row.
        let dispatched = await service.dispatchPending(limit: 3)
        XCTAssertFalse(dispatched.contains { $0.state == .launched })
        let launchesAfterStop = await launchCount()
        XCTAssertEqual(launchesAfterStop, 0)

        // The SCHEDULE and its future cadence are preserved (only the one
        // explicit pending occurrence was cancelled).
        let afterStopDetail = await service.detail(id: detail.summary.id)
        let afterStop = try XCTUnwrap(afterStopDetail)
        XCTAssertTrue(afterStop.summary.isEnabled)
        XCTAssertNotNil(afterStop.summary.nextFireAt)

        // A later explicit run request still works.
        let again = await service.runNow(
            id: detail.summary.id, expectedRevision: afterStop.summary.revision)
        XCTAssertEqual(again.state, .queued)
        let launched = await service.dispatchPending(limit: 3)
        XCTAssertEqual(launched.filter { $0.state == .launched }.count, 1)
        let launchesFinal = await launchCount()
        XCTAssertEqual(launchesFinal, 1)
    }

    func testStopPendingWithoutAPendingOccurrenceIsANoOp() async {
        let created = await service.create(draft(
            cadence: .daily, scheduledAt: fixedNow.addingTimeInterval(3_600)))
        guard let detail = created.detail else { return XCTFail("create refused") }
        let stopped = await service.cancelPendingOccurrence(
            scheduleID: detail.summary.id)
        XCTAssertEqual(stopped.state, .cancelled)
        XCTAssertNil(stopped.occurrenceID)
        let launches = await launchCount()
        XCTAssertEqual(launches, 0)
        let listed = await service.list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertTrue(listed[0].isEnabled)
    }

    func testRunNowMultipleExplicitRequestsEachGetOneIndependentOccurrence() async throws {
        let created = await service.create(draft(
            cadence: .daily, scheduledAt: fixedNow.addingTimeInterval(3_600)))
        let detail = try XCTUnwrap(created.detail)

        let first = await service.runNow(
            id: detail.summary.id, expectedRevision: detail.summary.revision)
        let second = await service.runNow(
            id: detail.summary.id, expectedRevision: detail.summary.revision)
        XCTAssertEqual(first.state, .queued)
        XCTAssertEqual(second.state, .queued)
        XCTAssertNotEqual(first.occurrenceID, second.occurrenceID)

        let firstDispatch = await service.dispatchPending(limit: 1)
        let secondDispatch = await service.dispatchPending(limit: 1)
        XCTAssertEqual(firstDispatch.first?.state, .launched)
        XCTAssertEqual(secondDispatch.first?.state, .launched)
        XCTAssertNotEqual(firstDispatch.first?.runID, secondDispatch.first?.runID)
        let launches = await launchCount()
        XCTAssertEqual(launches, 2)
    }

    func testDispatchLaunchesOneIndependentTaskAndDuplicateWakeCollapses() async throws {
        let created = await service.create(draft(
            cadence: .daily, scheduledAt: fixedNow.addingTimeInterval(-60)))
        let id = try XCTUnwrap(created.detail?.summary.id)

        let first = await dispatchExact(id)
        XCTAssertEqual(first.state, .launched)
        let firstOccurrenceID = try XCTUnwrap(first.occurrenceID)
        let storedOccurrence = try await store.occurrence(id: firstOccurrenceID)
        let occurrence = try XCTUnwrap(storedOccurrence)
        XCTAssertEqual(occurrence.state, .running)
        XCTAssertEqual(occurrence.conversationID, first.conversationID)
        XCTAssertEqual(occurrence.runID, first.runID)
        let countAfterFirst = await launchCount()
        XCTAssertEqual(countAfterFirst, 1)

        let recordedRequest = await launcher.request(at: 0)
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.occurrenceID, occurrence.id)
        XCTAssertEqual(request.conversationID,
                       G073ScheduleIdentity.conversationID(occurrenceID: occurrence.id))
        XCTAssertEqual(request.runID,
                       G073ScheduleIdentity.runID(occurrenceID: occurrence.id))
        XCTAssertNil(request.workspaceID) // new independent workspace per occurrence
        XCTAssertEqual(request.prompt, "Summarize the project status.")
        XCTAssertEqual(request.policy.approvalMode, .automatic)

        let second = await dispatchExact(id)
        XCTAssertEqual(second.state, .alreadyHandled)
        let countAfterSecond = await launchCount()
        XCTAssertEqual(countAfterSecond, 1)
    }

    func testUpstreamSuccessEnqueuesAfterSuccessExactlyOnce() async throws {
        let created = await service.create(draft(
            cadence: .once, scheduledAt: fixedNow.addingTimeInterval(-60)))
        let id = try XCTUnwrap(created.detail?.summary.id)
        let launched = await dispatchExact(id)
        let runID = try XCTUnwrap(launched.runID)

        world.setRunState(runID, "streaming")
        world.setStopReason(runID, "endTurn")
        let dependent = await service.create(draft(
            cadence: .afterSuccess, upstream: runID))
        let dependentID = try XCTUnwrap(dependent.detail?.summary.id)

        let enqueued = await service.recordCompletion(
            runID: runID, succeeded: true, cancelled: false,
            summary: nil, at: fixedNow.addingTimeInterval(10))
        XCTAssertEqual(enqueued.count, 1)
        let boundStored = try await store.occurrence(runID: runID)
        let bound = try XCTUnwrap(boundStored)
        XCTAssertEqual(bound.state, .completed)

        // A replayed completion callback cannot duplicate the dependent.
        let replay = await service.recordCompletion(
            runID: runID, succeeded: true, cancelled: false,
            summary: nil, at: fixedNow.addingTimeInterval(11))
        XCTAssertTrue(replay.isEmpty)

        let pending = (try? await store.pendingOccurrences(limit: 10)) ?? []
        XCTAssertEqual(pending.map(\.scheduleID), [dependentID])

        let drained = await service.dispatchPending(limit: 3)
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained.first?.state, .launched)
        let launchesAfterDependent = await launchCount()
        XCTAssertEqual(launchesAfterDependent, 2)

        let dependentRows = (try? await store.occurrences(
            scheduleID: dependentID, limit: 5)) ?? []
        let dependentOccurrence = try XCTUnwrap(dependentRows.first)
        XCTAssertEqual(dependentOccurrence.state, .running)
        XCTAssertNotEqual(dependentOccurrence.runID, runID)
    }

    func testCancelledUpstreamNeverFiresAfterSuccess() async throws {
        let created = await service.create(draft(
            cadence: .once, scheduledAt: fixedNow.addingTimeInterval(-60)))
        let id = try XCTUnwrap(created.detail?.summary.id)
        let launched = await dispatchExact(id)
        let runID = try XCTUnwrap(launched.runID)
        world.setRunState(runID, "streaming")
        let dependent = await service.create(draft(
            cadence: .afterSuccess, upstream: runID))
        XCTAssertTrue(dependent.accepted)

        world.setStopReason(runID, "cancelled")
        let enqueued = await service.recordCompletion(
            runID: runID, succeeded: true, cancelled: false,
            summary: nil, at: fixedNow.addingTimeInterval(20))
        XCTAssertTrue(enqueued.isEmpty)
        let storedOccurrence = try await store.occurrence(runID: runID)
        let occurrence = try XCTUnwrap(storedOccurrence)
        XCTAssertEqual(occurrence.state, .cancelled)
        let pending = (try? await store.pendingOccurrences(limit: 10)) ?? []
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: Crash / recovery ordering

    func testColdReconcileSettlesCompletedRunBeforeInterruptingLeftovers() async throws {
        let created = await service.create(draft(
            cadence: .once, scheduledAt: fixedNow.addingTimeInterval(-60)))
        let id = try XCTUnwrap(created.detail?.summary.id)
        let launched = await dispatchExact(id)
        let runID = try XCTUnwrap(launched.runID)
        world.setRunState(runID, "completed")
        world.setStopReason(runID, "endTurn")

        let settled = await service.reconcileColdStart(
            now: fixedNow.addingTimeInterval(30))
        XCTAssertGreaterThanOrEqual(settled, 1)
        let storedOccurrence = try await store.occurrence(runID: runID)
        let occurrence = try XCTUnwrap(storedOccurrence)
        XCTAssertEqual(occurrence.state, .completed)
    }

    func testClaimWithoutDurableRunIsInterruptedAndOnceRetryIsSafe() async throws {
        let created = await service.create(draft(
            cadence: .once, scheduledAt: fixedNow.addingTimeInterval(-60)))
        let id = try XCTUnwrap(created.detail?.summary.id)
        let scheduledRecord = try await store.schedule(id: id)
        let record = try XCTUnwrap(scheduledRecord)
        let key = TaskSchedulePlanner.dedupeKey(
            for: fixedNow.addingTimeInterval(-60), record: record)
        let occurrenceID = TaskScheduleOccurrence.stableID(scheduleID: id, dedupeKey: key)
        let occurrence = TaskScheduleOccurrence(
            id: occurrenceID, scheduleID: id,
            scheduledFor: fixedNow.addingTimeInterval(-60),
            dedupeKey: key)
        _ = try await store.enqueueOccurrence(occurrence)
        let claimed = try await store.claimOccurrence(id: occurrenceID, at: fixedNow)
        XCTAssertTrue(claimed)

        _ = await service.reconcileColdStart(now: fixedNow.addingTimeInterval(5))
        let storedInterrupted = try await store.occurrence(id: occurrenceID)
        let interrupted = try XCTUnwrap(storedInterrupted)
        XCTAssertEqual(interrupted.state, .interrupted)
        let launchCountBefore = await launchCount()

        let retried = await dispatchExact(id)
        XCTAssertEqual(retried.state, .launched)
        let launchesAfterRetry = await launchCount()
        XCTAssertEqual(launchesAfterRetry, launchCountBefore + 1)
        XCTAssertNotEqual(retried.occurrenceID, occurrenceID)
    }

    func testInFlightOccurrenceIsNeverStolen() async throws {
        let created = await service.create(draft(
            cadence: .daily, scheduledAt: fixedNow.addingTimeInterval(-60)))
        let id = try XCTUnwrap(created.detail?.summary.id)
        let first = await dispatchExact(id)
        XCTAssertEqual(first.state, .launched)
        // No durable run state is visible (a live/unknown executor).
        let second = await dispatchExact(id)
        XCTAssertEqual(second.state, .alreadyHandled)
        XCTAssertEqual(second.code, .occurrenceInFlight)
        let launches = await launchCount()
        XCTAssertEqual(launches, 1)
    }

    // MARK: Preflight failures

    func testMissingModelFailsTheOccurrenceWithoutSubstitution() async throws {
        let created = await service.create(draft(
            cadence: .daily, scheduledAt: fixedNow.addingTimeInterval(-60)))
        let id = try XCTUnwrap(created.detail?.summary.id)
        world.removeModel(modelID)
        let outcome = await dispatchExact(id)
        XCTAssertEqual(outcome.state, .failed)
        XCTAssertEqual(outcome.code, .modelUnavailable)
        let launches = await launchCount()
        XCTAssertEqual(launches, 0)
        let rows = (try? await store.occurrences(scheduleID: id, limit: 5)) ?? []
        let occurrence = try XCTUnwrap(rows.first)
        XCTAssertEqual(occurrence.state, .failed)
        XCTAssertTrue(occurrence.errorText?.contains("model") == true)
        // The schedule remains visible and needs attention.
        let summary = await service.list().first
        XCTAssertTrue(summary?.needsAttention == true)
    }

    func testEnvironmentOwnerMismatchFailsClosed() async throws {
        let created = await service.create(draft(
            cadence: .daily, scheduledAt: fixedNow.addingTimeInterval(-60),
            workspace: workspaceID, environment: environmentID))
        XCTAssertNotNil(created.detail,
                        "code=\(created.code?.rawValue ?? "nil") reason=\(created.reason ?? "")")
        let id = try XCTUnwrap(created.detail?.summary.id)
        let wrongOwner = G073EnvironmentMetadata(
            id: environmentID, kind: .project,
            ownerID: otherWorkspaceID.uuidString, name: "Wrong",
            state: "active", requiresRebuild: false,
            executionBackend: G073EnvironmentMetadata.requiredExecutionBackend)
        let outcome = await service.dispatch(.init(
            scheduleID: id, trigger: .exact,
            exactAlarmAllowed: true, flexibleChosen: false,
            environmentMetadata: [wrongOwner]))
        XCTAssertEqual(outcome.state, .failed)
        XCTAssertEqual(outcome.code, .environmentUnavailable)
        let launches = await launchCount()
        XCTAssertEqual(launches, 0)
    }

    func testMalformedStoredPolicyIsNotReplacedWithADefault() async throws {
        var record = TaskScheduleRecord(
            title: "Policy fixture",
            prompt: "Do work",
            cadence: .daily,
            scheduledAt: fixedNow.addingTimeInterval(-60),
            anchorTimezone: "UTC",
            modelID: modelID,
            permissionJSON: #"{"approvalMode":"ask","recoveryPolicy":"safePoint","notificationPolicy":"stages","tools":["exec.shell"]}"#)
        record.nextExpectedAt = fixedNow.addingTimeInterval(-60)
        try await store.save(record)
        let outcome = await dispatchExact(record.id)
        XCTAssertEqual(outcome.state, .failed)
        XCTAssertEqual(outcome.code, .policyInvalid)
        let launches = await launchCount()
        XCTAssertEqual(launches, 0)
    }

    func testRefusedLaunchMarksOccurrenceFailedAndAdvances() async throws {
        let created = await service.create(draft(
            cadence: .daily, scheduledAt: fixedNow.addingTimeInterval(-60)))
        let id = try XCTUnwrap(created.detail?.summary.id)
        await launcher.setResult(.refused(
            code: "transportUnavailable:transportNotQualified",
            reason: "Provider transport is unavailable"))
        let outcome = await dispatchExact(id)
        XCTAssertEqual(outcome.state, .failed)
        XCTAssertEqual(outcome.code, .launchRefused)
        let rows = (try? await store.occurrences(scheduleID: id, limit: 5)) ?? []
        let occurrence = try XCTUnwrap(rows.first)
        XCTAssertEqual(occurrence.state, .failed)
        let storedSchedule = try await store.schedule(id: id)
        let schedule = try XCTUnwrap(storedSchedule)
        XCTAssertNotNil(schedule.lastStartedAt)
        XCTAssertTrue(schedule.isEnabled)
    }

    // MARK: Policy codec

    func testPolicyCodecAcceptsOnlyTheThreeDraftFields() {
        let policy = DraftTaskPolicy(approvalMode: .fullAccess,
                                     recoveryPolicy: .alwaysRetry,
                                     notificationPolicy: .off)
        let encoded = G073SchedulePolicyCodec.encode(policy)
        let decoded = try? XCTUnwrap(G073SchedulePolicyCodec.decode(encoded))
        XCTAssertEqual(decoded, policy)
        XCTAssertNil(G073SchedulePolicyCodec.decode(
            #"{"approvalMode":"ask","recoveryPolicy":"safePoint","notificationPolicy":"stages","allowedTools":[]}"#))
        XCTAssertNil(G073SchedulePolicyCodec.decode(#"{"approvalMode":"ask"}"#))
        XCTAssertEqual(G073SchedulePolicyCodec.decode(nil), DraftTaskPolicy())
    }

    // MARK: Environment ownership

    func testProjectEnvironmentRequiresExactOwnerAndExecutableBackend() async {
        let good = G073EnvironmentMetadata(
            id: "env", kind: .project, ownerID: workspaceID.uuidString,
            state: "active", requiresRebuild: false,
            executionBackend: "linuxPRoot")
        let goodOwned = await ownership.proveScheduledEnvironment(
            "env", workspaceID: workspaceID, metadata: good, epoch: 1)
        XCTAssertTrue(goodOwned)
        let wrongWorkspace = await ownership.proveScheduledEnvironment(
            "env", workspaceID: otherWorkspaceID, metadata: good, epoch: 1)
        XCTAssertFalse(wrongWorkspace)

        var stopped = good
        stopped.state = "stopped"
        let stoppedResult = await ownership.proveScheduledEnvironment(
            "env", workspaceID: workspaceID, metadata: stopped, epoch: 1)
        XCTAssertFalse(stoppedResult)

        var rebuild = good
        rebuild.requiresRebuild = true
        let rebuildResult = await ownership.proveScheduledEnvironment(
            "env", workspaceID: workspaceID, metadata: rebuild, epoch: 1)
        XCTAssertFalse(rebuildResult)

        var wrongBackend = good
        wrongBackend.executionBackend = "linuxVM"
        let backendResult = await ownership.proveScheduledEnvironment(
            "env", workspaceID: workspaceID, metadata: wrongBackend, epoch: 1)
        XCTAssertFalse(backendResult)
    }

    func testSessionEnvironmentIsBoundToItsOwnConversationOnly() async {
        let session = G073EnvironmentMetadata(
            id: "session", kind: .session, ownerID: conversationID.uuidString,
            state: "active", requiresRebuild: false,
            executionBackend: "linuxPRoot", parentID: "project")
        let project = G073EnvironmentMetadata(
            id: "project", kind: .project, ownerID: workspaceID.uuidString,
            state: "active", requiresRebuild: false,
            executionBackend: "linuxPRoot")
        // proveEnvironment uses the ownership's default wall-clock freshness;
        // register this fixture near now, not the schedule's frozen clock.
        ownership.registerHostMetadata([session, project], at: Date())

        let ownSession = await ownership.proveEnvironment(
            "session", conversationID: conversationID, epoch: 1)
        XCTAssertTrue(ownSession)
        let foreignSession = await ownership.proveEnvironment(
            "session", conversationID: UUID(), epoch: 1)
        XCTAssertFalse(foreignSession)
        // A NEW scheduled conversation can never borrow a session container.
        let scheduledSession = await ownership.proveScheduledEnvironment(
            "session", workspaceID: workspaceID, metadata: session, epoch: 1)
        XCTAssertFalse(scheduledSession)
    }

    func testStaleAuthoritySnapshotFailsClosed() async {
        let metadata = G073EnvironmentMetadata(
            id: "env", kind: .project, ownerID: workspaceID.uuidString,
            state: "active", requiresRebuild: false,
            executionBackend: "linuxPRoot")
        ownership.registerHostMetadata([metadata], at: fixedNow)
        XCTAssertNotNil(ownership.metadata(
            id: "env", now: fixedNow.addingTimeInterval(10)))
        XCTAssertNil(ownership.metadata(
            id: "env", now: fixedNow.addingTimeInterval(
                G073ScheduleEnvironmentOwnership.maximumSnapshotAge + 1)))
    }
}

private extension Date {
    static func + (lhs: Date, rhs: TimeInterval) -> Date {
        lhs.addingTimeInterval(rhs)
    }
}
