// FloeAppTests — independent ordinary-task Live Activities.
//
// These tests pin the product contract of the task Live Activity: the
// independent persisted switch (with a decoding migration that keeps every
// older choice), the truthful projection of real running work, and the
// coordinator's start/update/end lifecycle — coalescing, minimum update
// interval, generation fencing, orphan reconciliation and graceful behaviour
// when the system or the platform cannot show Live Activities.
//
// No App environment is constructed and no ActivityKit surface is touched:
// the real coordinator runs against a deterministic in-memory activity owner.

#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import FloeCore
import FloePersistence
@testable import FloeApp

// MARK: - Test doubles

private actor TaskActivitySettingsStore: SettingsStore {
    private var values: [String: String] = [:]

    func value(forKey key: String) async throws -> String? { values[key] }

    func setValue(_ json: String, forKey key: String) async throws {
        values[key] = json
    }

    func removeValue(forKey key: String) async throws {
        values[key] = nil
    }

    func allValues() async throws -> [String: String] { values }

    func seed(_ key: String, _ json: String) {
        values[key] = json
    }
}

/// Test-only clock. The throttle test advances it from the injected `sleep`
/// closure used by the coordinator's single trailing task; the
/// `@unchecked Sendable` marker documents the single-threaded test use.
private final class TaskActivityClock: @unchecked Sendable {
    var now: Date

    init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.now = now
    }

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

@MainActor
private final class RecordingActivity: TaskLiveActivityOwnedActivity {
    let id: String
    var lifecycle: TaskLiveActivityLifecycle = .active
    var updates: [FloeTaskActivitySnapshot] = []
    var endStates: [FloeTaskActivitySnapshot?] = []
    var endDismissals: [Bool] = []
    var gatesUpdate = false
    private var updateGate: CheckedContinuation<Void, Never>?

    init(id: String) {
        self.id = id
    }

    var isUpdateWaiting: Bool { updateGate != nil }

    func releaseUpdate() {
        updateGate?.resume()
        updateGate = nil
    }

    func update(_ state: FloeTaskActivitySnapshot, staleDate: Date) async {
        updates.append(state)
        if gatesUpdate {
            await withCheckedContinuation { continuation in
                updateGate = continuation
            }
        }
    }

    func end(_ state: FloeTaskActivitySnapshot?, immediate: Bool) async {
        endStates.append(state)
        endDismissals.append(immediate)
        lifecycle = .dismissed
    }
}

@MainActor
private final class RecordingControl: TaskLiveActivityControlling {
    var isSupported = true
    var areActivitiesEnabled = true
    var existing: [RecordingActivity] = []
    var requests: [(startDate: Date, state: FloeTaskActivitySnapshot)] = []
    var requestError: (any Error)?
    private var nextID = 0

    func existingActivities() -> [any TaskLiveActivityOwnedActivity] { existing }

    func request(
        startDate: Date,
        state: FloeTaskActivitySnapshot,
        staleDate: Date
    ) throws -> any TaskLiveActivityOwnedActivity {
        if let requestError { throw requestError }
        let activity = RecordingActivity(id: "activity-\(nextID)")
        nextID += 1
        requests.append((startDate, state))
        existing.append(activity)
        return activity
    }
}

@MainActor
private final class TaskActivityStateBox {
    var snapshot: FloeTaskActivitySnapshot
    var enabled: Bool

    init(snapshot: FloeTaskActivitySnapshot = .empty, enabled: Bool = true) {
        self.snapshot = snapshot
        self.enabled = enabled
    }
}

// MARK: - Helpers

private func makeCandidate(
    runID: UUID = UUID(),
    conversationID: UUID? = UUID(),
    title: String = "Task",
    stage: String = "正在运行",
    pendingApprovalToolName: String? = nil,
    isAwaitingUserAttention: Bool = false,
    startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
    publishesContent: Bool = true
) -> TaskLiveActivityProjection.Candidate {
    TaskLiveActivityProjection.Candidate(
        runID: runID,
        conversationID: conversationID,
        title: title,
        stage: stage,
        pendingApprovalToolName: pendingApprovalToolName,
        isAwaitingUserAttention: isAwaitingUserAttention,
        startedAt: startedAt,
        publishesContent: publishesContent
    )
}

private func oneTaskSnapshot(
    runID: UUID = UUID(),
    title: String = "Task",
    stage: String = "正在运行",
    startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
) -> FloeTaskActivitySnapshot {
    TaskLiveActivityProjection.snapshot(
        from: [
            makeCandidate(runID: runID, title: title, stage: stage, startedAt: startedAt)
        ]
    )
}

@MainActor
private func makeCoordinator(
    control: RecordingControl,
    state: TaskActivityStateBox,
    clock: TaskActivityClock,
    minimumUpdateInterval: TimeInterval = 0,
    sleep: (@Sendable (TimeInterval) async -> Void)? = nil
) -> TaskLiveActivityCoordinator {
    let defaultSleep: @Sendable (TimeInterval) async -> Void = { _ in }
    return TaskLiveActivityCoordinator(
        snapshotProvider: { _ in state.snapshot },
        isEnabledProvider: { state.enabled },
        control: control,
        now: { clock.now },
        sleep: sleep ?? defaultSleep,
        minimumUpdateInterval: minimumUpdateInterval
    )
}

/// Lets main-actor work queued by fire-and-forget teardown tasks run.
@MainActor
private func settleMainActor() async {
    for _ in 0..<20 {
        await Task.yield()
    }
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<2_000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("condition not reached")
}

// MARK: - Persisted independent switch

@Suite("FloeApp.BackgroundExecutionOptions.LiveActivity")
struct TaskLiveActivityPreferenceTests {

    @Test("Older stored options gain the Live Activity default without losing a choice")
    func legacyOptionsDecodeWithDefaultOff() throws {
        let json = #"""
        {"enhancedBackgroundEnabled":true,"pictureInPictureEnabled":true,"screenFeedbackEnabled":false}
        """#
        let options = try JSONDecoder().decode(
            BackgroundExecutionOptions.self, from: Data(json.utf8)
        )
        #expect(options.taskLiveActivityEnabled == false)
        #expect(options.enhancedBackgroundEnabled)
        #expect(options.pictureInPictureEnabled)
        #expect(options.screenFeedbackEnabled == false)
    }

    @Test("A stored Live Activity choice survives a round trip")
    func optionsRoundTrip() throws {
        let options = BackgroundExecutionOptions(
            enhancedBackgroundEnabled: false,
            taskLiveActivityEnabled: true
        )
        let data = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(BackgroundExecutionOptions.self, from: data)
        #expect(decoded == options)
        #expect(decoded.taskLiveActivityEnabled)
        #expect(decoded.enhancedBackgroundEnabled == false)
        #expect(decoded.normalized == decoded)
    }

    @Test("The switch is independent of every other capability")
    func switchIsIndependent() {
        var options = BackgroundExecutionOptions()
        options.setTaskLiveActivityEnabled(true)
        #expect(options.taskLiveActivityEnabled)
        #expect(options.enhancedBackgroundEnabled)
        #expect(options.pictureInPictureEnabled == false)
        #expect(options.screenFeedbackEnabled == false)

        options.setTaskLiveActivityEnabled(false)
        #expect(options.taskLiveActivityEnabled == false)
        #expect(options.enhancedBackgroundEnabled)

        // The legacy enum never implies the new capability.
        #expect(BackgroundExecutionOptions(legacy: .screenShare).taskLiveActivityEnabled == false)
        #expect(BackgroundExecutionOptions(legacy: .pictureInPicture).taskLiveActivityEnabled == false)
    }

    @Test("The real repository migration keeps older choices and persists the new one")
    func repositoryMigration() async throws {
        let store = TaskActivitySettingsStore()
        await store.seed(
            AppSettingsKey.backgroundExecutionOptions,
            #"{"enhancedBackgroundEnabled":false,"pictureInPictureEnabled":true,"screenFeedbackEnabled":false}"#
        )
        var loaded = await BackgroundPreferencesRepository(store: store).loadOptions()
        #expect(loaded.taskLiveActivityEnabled == false)
        #expect(loaded.pictureInPictureEnabled)
        #expect(loaded.enhancedBackgroundEnabled == false)

        loaded.setTaskLiveActivityEnabled(true)
        try await BackgroundPreferencesRepository(store: store).saveOptions(loaded)
        let reloaded = await BackgroundPreferencesRepository(store: store).loadOptions()
        #expect(reloaded.taskLiveActivityEnabled)
        #expect(reloaded.pictureInPictureEnabled)
        #expect(reloaded.enhancedBackgroundEnabled == false)
    }
}

// MARK: - Bounded content contract

@Suite("FloeCore.TaskLiveActivitySnapshot")
struct TaskLiveActivitySnapshotTests {

    @Test("Rows sanitize text, cap length and derive only canonical task routes")
    func rowFactory() {
        let conversation = UUID()
        let row = FloeTaskActivitySnapshot.Row.task(
            runID: UUID(),
            conversationID: conversation,
            title: "  First\nSecond\tThird  ",
            state: .running,
            status: "Tool: " + String(repeating: "x", count: 120),
            startedAt: Date(timeIntervalSince1970: 10)
        )
        #expect(row.title == "First Second Third")
        #expect(row.status.count == FloeTaskActivitySnapshot.maximumStatusCharacters)
        #expect(!row.status.contains("\n"))
        #expect(row.route == FloeAppEntryRoute.task(conversation).url)

        let routeLess = FloeTaskActivitySnapshot.Row.task(
            runID: UUID(),
            conversationID: nil,
            title: "Media",
            state: .running,
            status: "",
            startedAt: Date(timeIntervalSince1970: 10)
        )
        #expect(routeLess.route == nil)
    }

    @Test("Validation refuses unbounded or non-navigation content")
    func validation() throws {
        let runID = UUID()
        let row = FloeTaskActivitySnapshot.Row.task(
            runID: runID,
            conversationID: UUID(),
            title: "Task",
            state: .running,
            status: "Running",
            startedAt: Date(timeIntervalSince1970: 10)
        )
        try FloeTaskActivitySnapshot(rows: [row], activeCount: 1).validate()

        do {
            try FloeTaskActivitySnapshot(rows: [row, row], activeCount: 2).validate()
            Issue.record("duplicate rows must fail validation")
        } catch let error as FloeTaskActivitySnapshotError {
            #expect(error == .duplicateRow)
        }

        let many = (0..<FloeTaskActivitySnapshot.maximumRows + 1).map { index in
            FloeTaskActivitySnapshot.Row.task(
                runID: UUID(),
                conversationID: UUID(),
                title: "Task \(index)",
                state: .running,
                status: "",
                startedAt: Date(timeIntervalSince1970: 10)
            )
        }
        do {
            try FloeTaskActivitySnapshot(rows: many, activeCount: many.count).validate()
            Issue.record("more rows than the card can show must fail validation")
        } catch let error as FloeTaskActivitySnapshotError {
            #expect(error == .tooManyRows)
        }

        let external = FloeTaskActivitySnapshot.Row(
            id: "run",
            title: "Task",
            state: .running,
            status: "",
            route: URL(string: "https://example.com/task"),
            startedAt: Date(timeIntervalSince1970: 10)
        )
        do {
            try FloeTaskActivitySnapshot(rows: [external], activeCount: 1).validate()
            Issue.record("a non-task route must fail validation")
        } catch let error as FloeTaskActivitySnapshotError {
            #expect(error == .invalidRoute)
        }
    }

    @Test("UTF-8 caps bound combining and multi-byte text at the factory and boundary")
    func unicodeByteBounds() throws {
        let combining = "e" + String(repeating: "\u{0301}", count: 4_000)
        let wide = String(repeating: "👩🏽‍💻", count: 200)
        let row = FloeTaskActivitySnapshot.Row.task(
            runID: UUID(),
            conversationID: UUID(),
            title: combining,
            state: .running,
            status: wide,
            startedAt: Date(timeIntervalSince1970: 10)
        )
        // A single combining grapheme is one Character but thousands of bytes.
        #expect(combining.count <= 2)
        #expect(combining.utf8.count > FloeTaskActivitySnapshot.maximumTitleBytes)
        #expect(row.title.count <= FloeTaskActivitySnapshot.maximumTitleCharacters)
        #expect(row.title.utf8.count <= FloeTaskActivitySnapshot.maximumTitleBytes)
        #expect(row.status.count <= FloeTaskActivitySnapshot.maximumStatusCharacters)
        #expect(row.status.utf8.count <= FloeTaskActivitySnapshot.maximumStatusBytes)
        #expect(!row.title.isEmpty)
        #expect(!row.status.isEmpty)
        try FloeTaskActivitySnapshot(rows: [row], activeCount: 1).validate()

        // The old .count-only gate accepted one over-budget grapheme; the
        // boundary validation must reject it even though Character count is 1.
        let oversized = FloeTaskActivitySnapshot.Row(
            id: UUID().uuidString,
            title: String(repeating: "\u{0301}", count: 400),
            state: .running,
            status: "",
            route: FloeAppEntryRoute.task(UUID()).url,
            startedAt: Date(timeIntervalSince1970: 10)
        )
        #expect(oversized.title.count == 1)
        #expect(oversized.title.utf8.count > FloeTaskActivitySnapshot.maximumTitleBytes)
        do {
            try FloeTaskActivitySnapshot(rows: [oversized], activeCount: 1).validate()
            Issue.record("an over-budget combining title must fail validation")
        } catch let error as FloeTaskActivitySnapshotError {
            #expect(error == .titleTooLong)
        }
    }

    @Test("Four maximal rows including routes stay below the ActivityKit payload ceiling")
    func maximumEncodedPayload() throws {
        let combining = "e" + String(repeating: "\u{0301}", count: 4_000)
        let wide = String(repeating: "👩🏽‍💻", count: 200)
        let rows = (0..<FloeTaskActivitySnapshot.maximumRows).map { _ in
            FloeTaskActivitySnapshot.Row.task(
                runID: UUID(),
                conversationID: UUID(),
                title: combining,
                state: .running,
                status: wide,
                startedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        }
        let snapshot = FloeTaskActivitySnapshot(
            rows: rows,
            activeCount: FloeTaskActivitySnapshot.maximumActiveCount
        )
        #expect(rows.count == 4)
        #expect(rows.allSatisfy { $0.route != nil })
        #expect(rows.allSatisfy {
            $0.title.utf8.count <= FloeTaskActivitySnapshot.maximumTitleBytes
        })
        #expect(rows.allSatisfy {
            $0.status.utf8.count <= FloeTaskActivitySnapshot.maximumStatusBytes
        })
        try snapshot.validate()
        let encoded = try JSONEncoder().encode(snapshot)
        #expect(encoded.count == snapshot.encodedByteCount)
        #expect(encoded.count <= FloeTaskActivitySnapshot.maximumEncodedBytes)
        let decoded = try JSONDecoder().decode(FloeTaskActivitySnapshot.self, from: encoded)
        #expect(decoded == snapshot)
    }
}

// MARK: - Real-work projection

@Suite("FloeApp.TaskLiveActivityProjection")
struct TaskLiveActivityProjectionTests {

    @Test("Temporary and route-less work is never projected")
    func filtersNonTasks() throws {
        let snapshot = TaskLiveActivityProjection.snapshot(
            from: [
                makeCandidate(publishesContent: false),
                makeCandidate(conversationID: nil),
                makeCandidate(title: "Real task")
            ]
        )
        #expect(snapshot.rows.count == 1)
        #expect(snapshot.rows.first?.title == "Real task")
        #expect(snapshot.activeCount == 1)
        try snapshot.validate()
    }

    @Test("Rows are newest-first and capped while the header counts all active work")
    func bounds() {
        let base = Date(timeIntervalSince1970: 1_000)
        let candidates = (0..<6).map { offset in
            makeCandidate(
                title: "Task \(offset)",
                startedAt: base.addingTimeInterval(Double(offset))
            )
        }
        let snapshot = TaskLiveActivityProjection.snapshot(from: candidates)
        #expect(snapshot.rows.count == FloeTaskActivitySnapshot.maximumRows)
        #expect(snapshot.activeCount == 6)
        #expect(snapshot.rows.map(\.title) == ["Task 5", "Task 4", "Task 3", "Task 2"])
        #expect(snapshot.rows.allSatisfy { $0.route != nil })
    }

    @Test("State and status follow the real task state")
    func stateMapping() throws {
        let snapshot = TaskLiveActivityProjection.snapshot(
            from: [
                makeCandidate(stage: "tool", pendingApprovalToolName: "shell"),
                makeCandidate(stage: "已暂停", isAwaitingUserAttention: true),
                makeCandidate(stage: "正在调用工具")
            ]
        )
        let byState = Dictionary(
            uniqueKeysWithValues: snapshot.rows.map { ($0.state, $0) }
        )
        #expect(byState[.waiting]?.status.isEmpty == false)
        #expect(byState[.paused]?.status == "已暂停")
        #expect(byState[.running]?.status == "正在调用工具")
        try snapshot.validate()
    }
}

// MARK: - Coordinator lifecycle

@Suite("FloeApp.TaskLiveActivityCoordinator")
@MainActor
struct TaskLiveActivityCoordinatorTests {

    @Test("Real work starts one activity and ends it immediately when idle")
    func startsAndEnds() async throws {
        let control = RecordingControl()
        let clock = TaskActivityClock()
        let state = TaskActivityStateBox()
        let coordinator = makeCoordinator(control: control, state: state, clock: clock)

        let startedAt = Date(timeIntervalSince1970: 1_800_000_100)
        let runID = UUID()
        state.snapshot = oneTaskSnapshot(
            runID: runID, title: "分析日志", stage: "正在运行", startedAt: startedAt
        )

        coordinator.noteTasksChanged(reason: "start")
        await coordinator.waitForIdleForTesting()

        #expect(control.requests.count == 1)
        let request = try #require(control.requests.first)
        #expect(request.startDate == startedAt)
        #expect(request.state.rows.first?.title == "分析日志")
        #expect(request.state.rows.first?.state == .running)
        #expect(coordinator.hasActivityForTesting)

        let activity = try #require(control.existing.first)
        #expect(activity.updates.isEmpty)

        clock.advance(5)
        state.snapshot = oneTaskSnapshot(
            runID: runID, title: "分析日志", stage: "正在调用工具", startedAt: startedAt
        )
        coordinator.noteTasksChanged(reason: "progress")
        await coordinator.waitForIdleForTesting()
        #expect(activity.updates.count == 1)
        #expect(activity.updates.first?.rows.first?.status == "正在调用工具")

        state.snapshot = .empty
        coordinator.noteTasksChanged(reason: "finish")
        await coordinator.waitForIdleForTesting()
        #expect(activity.endDismissals == [true])
        #expect(activity.endStates.first.flatMap { $0 } == FloeTaskActivitySnapshot.empty)
        #expect(!coordinator.hasActivityForTesting)
    }

    @Test("Unchanged state never reaches ActivityKit twice")
    func deduplicates() async throws {
        let control = RecordingControl()
        let clock = TaskActivityClock()
        let state = TaskActivityStateBox()
        let coordinator = makeCoordinator(control: control, state: state, clock: clock)
        let runID = UUID()

        state.snapshot = oneTaskSnapshot(runID: runID, stage: "正在运行")
        coordinator.noteTasksChanged(reason: "start")
        await coordinator.waitForIdleForTesting()

        let activity = try #require(control.existing.first)
        clock.advance(30)
        state.snapshot = oneTaskSnapshot(runID: runID, stage: "正在调用工具")
        coordinator.noteTasksChanged(reason: "progress")
        await coordinator.waitForIdleForTesting()
        #expect(activity.updates.count == 1)

        clock.advance(30)
        coordinator.noteTasksChanged(reason: "duplicate")
        await coordinator.waitForIdleForTesting()
        #expect(activity.updates.count == 1)
        #expect(control.requests.count == 1)
    }

    @Test("The disabled switch starts nothing and ends an activity at once")
    func switchGate() async throws {
        let control = RecordingControl()
        let clock = TaskActivityClock()
        let state = TaskActivityStateBox()
        let coordinator = makeCoordinator(control: control, state: state, clock: clock)

        state.enabled = false
        state.snapshot = oneTaskSnapshot()
        coordinator.noteTasksChanged(reason: "start")
        await coordinator.waitForIdleForTesting()
        #expect(control.requests.isEmpty)
        #expect(!coordinator.hasActivityForTesting)

        state.enabled = true
        coordinator.preferencesDidChange()
        await coordinator.waitForIdleForTesting()
        #expect(control.requests.count == 1)
        let activity = try #require(control.existing.first)

        clock.advance(5)
        state.enabled = false
        coordinator.preferencesDidChange()
        await settleMainActor()
        #expect(activity.endDismissals == [true])
        #expect(!coordinator.hasActivityForTesting)

        // Re-enabling only makes the next truthful state visible.
        state.enabled = true
        coordinator.noteTasksChanged(reason: "start")
        await coordinator.waitForIdleForTesting()
        #expect(control.requests.count == 2)
    }

    @Test("System-wide Live Activities disabled: no request and no false success")
    func systemDisabled() async throws {
        let control = RecordingControl()
        let clock = TaskActivityClock()
        let state = TaskActivityStateBox()
        let coordinator = makeCoordinator(control: control, state: state, clock: clock)

        control.areActivitiesEnabled = false
        state.snapshot = oneTaskSnapshot()
        coordinator.noteTasksChanged(reason: "start")
        await coordinator.waitForIdleForTesting()
        #expect(control.requests.isEmpty)
        #expect(!coordinator.hasActivityForTesting)

        // A card left over from before the system setting changed is removed.
        control.areActivitiesEnabled = true
        coordinator.noteTasksChanged(reason: "start")
        await coordinator.waitForIdleForTesting()
        #expect(control.requests.count == 1)
        let activity = try #require(control.existing.first)

        control.areActivitiesEnabled = false
        clock.advance(5)
        coordinator.noteTasksChanged(reason: "systemSetting")
        await coordinator.waitForIdleForTesting()
        #expect(activity.endDismissals == [true])
        #expect(!coordinator.hasActivityForTesting)
    }

    @Test("An unsupported platform is a quiet no-op")
    func unsupported() async throws {
        let control = RecordingControl()
        control.isSupported = false
        let coordinator = makeCoordinator(
            control: control, state: TaskActivityStateBox(snapshot: oneTaskSnapshot()),
            clock: TaskActivityClock()
        )
        coordinator.noteTasksChanged(reason: "start")
        await coordinator.waitForIdleForTesting()
        #expect(control.requests.isEmpty)
        #expect(!coordinator.hasActivityForTesting)

        coordinator.stop()
        await settleMainActor()
        #expect(control.requests.isEmpty)
    }

    @Test("Updates coalesce: one in-flight push, then the latest state exactly once")
    func coalesces() async throws {
        let control = RecordingControl()
        let clock = TaskActivityClock()
        let state = TaskActivityStateBox()
        let coordinator = makeCoordinator(control: control, state: state, clock: clock)
        let runID = UUID()

        state.snapshot = oneTaskSnapshot(runID: runID, stage: "阶段A")
        coordinator.noteTasksChanged(reason: "start")
        await coordinator.waitForIdleForTesting()
        let activity = try #require(control.existing.first)

        activity.gatesUpdate = true
        clock.advance(5)
        state.snapshot = oneTaskSnapshot(runID: runID, stage: "阶段B")
        coordinator.noteTasksChanged(reason: "progress")
        await waitUntil { activity.isUpdateWaiting }

        clock.advance(5)
        state.snapshot = oneTaskSnapshot(runID: runID, stage: "阶段C")
        coordinator.noteTasksChanged(reason: "progress")
        clock.advance(5)
        state.snapshot = oneTaskSnapshot(runID: runID, stage: "阶段D")
        coordinator.noteTasksChanged(reason: "progress")

        activity.gatesUpdate = false
        activity.releaseUpdate()
        await coordinator.waitForIdleForTesting()

        #expect(activity.updates.map { $0.rows.first?.status } == ["阶段B", "阶段D"])
        #expect(control.requests.count == 1)
    }

    @Test("A change inside the minimum interval is deferred and then pushed once")
    func throttle() async throws {
        let control = RecordingControl()
        let clock = TaskActivityClock()
        let state = TaskActivityStateBox()
        let coordinator = makeCoordinator(
            control: control,
            state: state,
            clock: clock,
            minimumUpdateInterval: 5,
            sleep: { interval in clock.advance(interval) }
        )
        let runID = UUID()

        state.snapshot = oneTaskSnapshot(runID: runID, stage: "阶段A")
        coordinator.noteTasksChanged(reason: "start")
        await coordinator.waitForIdleForTesting()
        let activity = try #require(control.existing.first)

        clock.advance(1)
        state.snapshot = oneTaskSnapshot(runID: runID, stage: "阶段B")
        coordinator.noteTasksChanged(reason: "progress")
        await coordinator.waitForIdleForTesting()

        #expect(activity.updates.count == 1)
        #expect(activity.updates.first?.rows.first?.status == "阶段B")
        #expect(control.requests.count == 1)
    }

    @Test("A stop fences an in-flight update so it cannot touch the teardown")
    func stopFences() async throws {
        let control = RecordingControl()
        let clock = TaskActivityClock()
        let state = TaskActivityStateBox()
        let coordinator = makeCoordinator(control: control, state: state, clock: clock)
        let runID = UUID()

        state.snapshot = oneTaskSnapshot(runID: runID, stage: "阶段A")
        coordinator.noteTasksChanged(reason: "start")
        await coordinator.waitForIdleForTesting()
        let activity = try #require(control.existing.first)

        activity.gatesUpdate = true
        clock.advance(5)
        state.snapshot = oneTaskSnapshot(runID: runID, stage: "阶段B")
        coordinator.noteTasksChanged(reason: "progress")
        await waitUntil { activity.isUpdateWaiting }

        coordinator.stop(reason: "switchOff")
        #expect(!coordinator.hasActivityForTesting)

        activity.gatesUpdate = false
        activity.releaseUpdate()
        await coordinator.waitForIdleForTesting()
        await settleMainActor()

        #expect(activity.endDismissals == [true])
        #expect(!coordinator.hasActivityForTesting)
        #expect(activity.updates.count == 1)
        #expect(coordinator.pushedStateForTesting == nil)
    }

    @Test("A stop releases the drain slot so re-enabling can start a fresh activity")
    func stopThenReenable() async throws {
        let control = RecordingControl()
        let clock = TaskActivityClock()
        let state = TaskActivityStateBox()
        let coordinator = makeCoordinator(control: control, state: state, clock: clock)
        let runID = UUID()

        state.snapshot = oneTaskSnapshot(runID: runID, stage: "阶段A")
        coordinator.noteTasksChanged(reason: "start")
        await coordinator.waitForIdleForTesting()
        let first = try #require(control.existing.first)

        // Freeze the coordinator inside a system update.
        first.gatesUpdate = true
        clock.advance(5)
        state.snapshot = oneTaskSnapshot(runID: runID, stage: "阶段B")
        coordinator.noteTasksChanged(reason: "progress")
        await waitUntil { first.isUpdateWaiting }

        coordinator.stop(reason: "switchOff")
        #expect(!coordinator.hasActivityForTesting)
        // Root cause guard: the slot must be released synchronously even
        // though the suspended drain cannot run its epilogue yet.
        #expect(!coordinator.hasDrainForTesting)

        // Re-enable while the old callback is still suspended. The stale drain
        // may not block this refresh.
        clock.advance(5)
        state.snapshot = oneTaskSnapshot(runID: runID, stage: "阶段C")
        coordinator.preferencesDidChange()
        await waitUntil { control.requests.count == 2 }
        let second = try #require(control.existing.last)
        #expect(second.id != first.id)
        #expect(coordinator.hasActivityForTesting)
        #expect(second.updates.isEmpty)

        // The old callback wakes after a newer owner exists. It must not end,
        // clear or overwrite that owner, and it must not release the newer
        // drain slot from under it.
        first.gatesUpdate = false
        first.releaseUpdate()
        await settleMainActor()
        #expect(coordinator.hasActivityForTesting)
        #expect(second.endDismissals.isEmpty)
        #expect(second.updates.isEmpty)

        // Later real work still reaches the new owner, so the slot is genuinely
        // available rather than merely looking free.
        clock.advance(5)
        state.snapshot = oneTaskSnapshot(runID: runID, stage: "阶段D")
        coordinator.noteTasksChanged(reason: "progress")
        await coordinator.waitForIdleForTesting()
        #expect(second.updates.map { $0.rows.first?.status } == ["阶段D"])
        #expect(first.endDismissals == [true])
    }

    @Test("A foreground reconcile requested during an active push is not lost")
    func foregroundDuringActivePass() async throws {
        let control = RecordingControl()
        let clock = TaskActivityClock()
        let state = TaskActivityStateBox()
        let coordinator = makeCoordinator(control: control, state: state, clock: clock)
        let runID = UUID()

        state.snapshot = oneTaskSnapshot(runID: runID, stage: "阶段A")
        coordinator.noteTasksChanged(reason: "start")
        await coordinator.waitForIdleForTesting()
        let activity = try #require(control.existing.first)

        let orphan = RecordingActivity(id: "orphan")
        control.existing.append(orphan)

        activity.gatesUpdate = true
        clock.advance(5)
        state.snapshot = oneTaskSnapshot(runID: runID, stage: "阶段B")
        coordinator.noteTasksChanged(reason: "progress")
        await waitUntil { activity.isUpdateWaiting }

        // The foreground reason must survive coalescing into the running drain
        // rather than being replaced by its initial "progress" reason.
        coordinator.reconcileForForeground()

        activity.gatesUpdate = false
        activity.releaseUpdate()
        await coordinator.waitForIdleForTesting()

        #expect(orphan.endDismissals == [true])
        #expect(activity.endDismissals.isEmpty)
        #expect(coordinator.hasActivityForTesting)
        #expect(activity.updates.map { $0.rows.first?.status } == ["阶段B"])
        #expect(!coordinator.hasDrainForTesting)
    }

    @Test("A queued foreground reconcile survives a pass that ends the activity")
    func foregroundDuringTerminalPass() async throws {
        let control = RecordingControl()
        let clock = TaskActivityClock()
        let state = TaskActivityStateBox()
        let coordinator = makeCoordinator(control: control, state: state, clock: clock)
        let runID = UUID()

        state.snapshot = oneTaskSnapshot(runID: runID, stage: "阶段A")
        coordinator.noteTasksChanged(reason: "start")
        await coordinator.waitForIdleForTesting()
        let activity = try #require(control.existing.first)

        let orphan = RecordingActivity(id: "orphan")
        control.existing.append(orphan)

        activity.gatesUpdate = true
        clock.advance(5)
        state.snapshot = oneTaskSnapshot(runID: runID, stage: "阶段B")
        coordinator.noteTasksChanged(reason: "progress")
        await waitUntil { activity.isUpdateWaiting }

        coordinator.reconcileForForeground()
        state.snapshot = .empty
        coordinator.noteTasksChanged(reason: "finish")
        activity.gatesUpdate = false
        activity.releaseUpdate()
        await coordinator.waitForIdleForTesting()

        // Ending the owned card bumps the generation; the queued reconcile is
        // still owed and must end the leftover activity.
        #expect(orphan.endDismissals == [true])
        #expect(activity.endDismissals == [true])
        #expect(!coordinator.hasActivityForTesting)
        #expect(control.requests.count == 1)
        #expect(!coordinator.hasDrainForTesting)
    }

    @Test("An over-budget unicode payload is refused before ActivityKit sees it")
    func oversizedUnicodeRefused() async throws {
        let control = RecordingControl()
        let clock = TaskActivityClock()
        let state = TaskActivityStateBox()
        let coordinator = makeCoordinator(control: control, state: state, clock: clock)

        let oversized = FloeTaskActivitySnapshot.Row(
            id: UUID().uuidString,
            title: String(repeating: "\u{0301}", count: 400),
            state: .running,
            status: "",
            route: FloeAppEntryRoute.task(UUID()).url,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        state.snapshot = FloeTaskActivitySnapshot(rows: [oversized], activeCount: 1)
        coordinator.noteTasksChanged(reason: "start")
        await coordinator.waitForIdleForTesting()

        #expect(control.requests.isEmpty)
        #expect(coordinator.lastErrorDescription == "title_too_long")
        #expect(!coordinator.hasActivityForTesting)
    }

    @Test("Foreground reconcile ends foreign activities and never resurrects work")
    func reconcileOrphansWithoutWork() async throws {
        let control = RecordingControl()
        let orphan = RecordingActivity(id: "orphan")
        control.existing = [orphan]
        let clock = TaskActivityClock()
        let state = TaskActivityStateBox()
        let coordinator = makeCoordinator(control: control, state: state, clock: clock)

        coordinator.reconcileForForeground()
        await coordinator.waitForIdleForTesting()

        #expect(orphan.endDismissals == [true])
        #expect(control.requests.isEmpty)
        #expect(!coordinator.hasActivityForTesting)
    }

    @Test("Foreground reconcile replaces a foreign activity only for real running work")
    func reconcileAdoptsTruth() async throws {
        let control = RecordingControl()
        let orphan = RecordingActivity(id: "orphan")
        control.existing = [orphan]
        let clock = TaskActivityClock()
        let state = TaskActivityStateBox(snapshot: oneTaskSnapshot(title: "真实任务"))
        let coordinator = makeCoordinator(control: control, state: state, clock: clock)

        coordinator.reconcileForForeground()
        await coordinator.waitForIdleForTesting()

        #expect(orphan.endDismissals == [true])
        #expect(control.requests.count == 1)
        #expect(control.requests.first?.state.rows.first?.title == "真实任务")
        #expect(coordinator.hasActivityForTesting)
    }

    @Test("A dismissed activity is replaced by a fresh one for real work")
    func dismissedHandleReplaced() async throws {
        let control = RecordingControl()
        let clock = TaskActivityClock()
        let state = TaskActivityStateBox()
        let coordinator = makeCoordinator(control: control, state: state, clock: clock)
        let runID = UUID()

        state.snapshot = oneTaskSnapshot(runID: runID, stage: "阶段A")
        coordinator.noteTasksChanged(reason: "start")
        await coordinator.waitForIdleForTesting()
        let activity = try #require(control.existing.first)
        activity.lifecycle = .dismissed

        clock.advance(5)
        state.snapshot = oneTaskSnapshot(runID: runID, stage: "阶段B")
        coordinator.noteTasksChanged(reason: "progress")
        await coordinator.waitForIdleForTesting()

        #expect(control.requests.count == 2)
        #expect(coordinator.hasActivityForTesting)
    }

    @Test("An invalid snapshot is refused instead of shown")
    func invalidSnapshotRefused() async throws {
        let control = RecordingControl()
        let clock = TaskActivityClock()
        let state = TaskActivityStateBox()
        let coordinator = makeCoordinator(control: control, state: state, clock: clock)

        let rows = (0..<FloeTaskActivitySnapshot.maximumRows + 1).map { index in
            FloeTaskActivitySnapshot.Row.task(
                runID: UUID(),
                conversationID: UUID(),
                title: "Task \(index)",
                state: .running,
                status: "",
                startedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        }
        state.snapshot = FloeTaskActivitySnapshot(
            rows: rows, activeCount: rows.count
        )
        coordinator.noteTasksChanged(reason: "start")
        await coordinator.waitForIdleForTesting()

        #expect(control.requests.isEmpty)
        #expect(coordinator.lastErrorDescription == "too_many_rows")
        #expect(!coordinator.hasActivityForTesting)
    }

    @Test("A failed request reports the failure and retries on the next real change")
    func requestFailureRetries() async throws {
        let control = RecordingControl()
        control.requestError = CocoaError(.fileWriteUnknown)
        let clock = TaskActivityClock()
        let state = TaskActivityStateBox(snapshot: oneTaskSnapshot())
        let coordinator = makeCoordinator(control: control, state: state, clock: clock)

        coordinator.noteTasksChanged(reason: "start")
        await coordinator.waitForIdleForTesting()
        #expect(control.requests.isEmpty)
        #expect(coordinator.lastErrorDescription == "request_failed")
        #expect(!coordinator.hasActivityForTesting)

        control.requestError = nil
        clock.advance(5)
        coordinator.noteTasksChanged(reason: "retry")
        await coordinator.waitForIdleForTesting()
        #expect(control.requests.count == 1)
        #expect(coordinator.hasActivityForTesting)
    }
}
#endif
