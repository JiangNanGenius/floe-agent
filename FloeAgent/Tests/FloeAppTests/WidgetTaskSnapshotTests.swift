// FloeAppTests — Widget snapshot production and refresh coalescing.
//
// Defines the production contract without executing it in this phase:
//   * only actual non-terminal ordinary runs become rows;
//   * notes assistants, archived tasks, deleted conversations and the active
//     temporary session are excluded;
//   * a conversation appears once even after resume/retry;
//   * rows are bounded, recency-sorted and carry canonical exact-task links;
//   * an empty real state clears old rows;
//   * read/write failures are observable and leave the previous valid file;
//   * a change (including a deletion) that arrives during an in-flight write
//     triggers a second publish and the last result wins.

import Foundation
import Testing
import FloeCore
import FloePersistence
@testable import FloeApp

@Suite("FloeApp.Widget snapshot production")
@MainActor
struct WidgetTaskSnapshotTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    // MARK: - Producer

    @Test func publishesOnlyRealNonTerminalOrdinaryTasks() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let ids = (1...11).map(makeID)
        let runs = [
            run(ids[0], state: "streamingModel", startedAt: 900), // Alpha, newest
            run(ids[1], state: "waitingApproval", startedAt: 890), // Beta
            run(ids[2], state: "executingTool", startedAt: 910), // notes, excluded
            run(ids[3], state: "running", startedAt: 905), // archived, excluded
            run(ids[4], state: "running", startedAt: 895), // deleted, excluded
            run(ids[5], state: "executingTool", startedAt: 880), // Gamma newest row
            run(ids[5], state: "preparing", startedAt: 850), // Gamma older run
            run(ids[6], state: "verifying", startedAt: 800),
            run(ids[7], state: "committingResults", startedAt: 700),
            run(ids[8], state: "reconnecting", startedAt: 600),
            run(ids[9], state: "someFutureInternalState", startedAt: 500),
            run(ids[10], state: "running", startedAt: 999) // temporary session
        ]
        let conversations: [UUID: WidgetSnapshotConversation] = [
            ids[0]: conversation(ids[0], title: "  Alpha\nreport  ", updatedAt: 1_000, ordinary: true),
            ids[1]: conversation(ids[1], title: "Beta", updatedAt: 990, ordinary: true),
            ids[2]: conversation(ids[2], title: "Notes assistant", updatedAt: 1_010, ordinary: false),
            ids[3]: conversation(ids[3], title: "Archived", updatedAt: 1_005, ordinary: true, archived: true),
            ids[5]: conversation(ids[5], title: "Gamma", updatedAt: 980, ordinary: true),
            ids[6]: conversation(ids[6], title: "Delta", updatedAt: 970, ordinary: true),
            ids[7]: conversation(ids[7], title: "Epsilon", updatedAt: 960, ordinary: true),
            ids[8]: conversation(ids[8], title: "Zeta", updatedAt: 950, ordinary: true),
            ids[9]: conversation(ids[9], title: "Eta", updatedAt: 940, ordinary: true),
            ids[10]: conversation(ids[10], title: "Temporary", updatedAt: 1_020, ordinary: true)
        ]

        let producer = WidgetSnapshotProducer(
            store: store,
            runSource: FakeRunSource(runs: runs),
            conversationSource: FakeConversationSource(conversations: conversations)
        )
        let outcome = await producer.publish(
            now: now,
            excludingConversationIDs: [ids[10]]
        )
        guard case .published(let result) = outcome else {
            Issue.record("expected a published snapshot, got \(outcome)")
            return
        }
        #expect(result.taskCount == 5)

        guard case .fresh(let snapshot) = store.load(now: now) else {
            Issue.record("expected a fresh snapshot")
            return
        }
        #expect(snapshot.generatedAt == now)
        #expect(snapshot.tasks.map(\.id) == [ids[0], ids[1], ids[5], ids[6], ids[7]])
        #expect(snapshot.tasks[0].title == "Alpha report")
        #expect(snapshot.tasks[1].state == .waiting)
        #expect(snapshot.tasks[2].state == .running)
        #expect(snapshot.tasks[2].runID == run(ids[5], state: "executingTool", startedAt: 880).id)
        #expect(snapshot.tasks[4].state == .running)
        #expect(!snapshot.tasks.contains { $0.title.contains("\n") })

        for task in snapshot.tasks {
            #expect(task.taskURL.absoluteString == "floe://task/\(task.id.uuidString.lowercased())")
            #expect(try FloeAppEntryRoute.parse(task.taskURL) == .task(task.id))
        }
        #expect(try FloeAppEntryRoute.parse(WidgetTaskSnapshot.newTaskURL) == .newTask)
    }

    @Test func strayTerminalRowsNeverBecomeActiveWidgetTasks() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = makeID(1)
        let producer = WidgetSnapshotProducer(
            store: store,
            runSource: FakeRunSource(runs: [
                run(id, state: "completed", startedAt: 300),
                run(id, state: "cancelled", startedAt: 200)
            ]),
            conversationSource: FakeConversationSource(
                conversations: [id: conversation(id, title: "Finished", updatedAt: 300, ordinary: true)]
            )
        )
        let outcome = await producer.publish(now: now)
        #expect(outcome == .published(.init(publishedAt: now, taskCount: 0)))
        guard case .fresh(let snapshot) = store.load(now: now) else {
            Issue.record("expected an empty fresh snapshot")
            return
        }
        #expect(snapshot.tasks.isEmpty)
    }

    @Test func unavailableAppGroupIsAnObservableFailure() async {
        let producer = WidgetSnapshotProducer(
            store: nil,
            runSource: FakeRunSource(runs: []),
            conversationSource: FakeConversationSource(conversations: [:])
        )
        let outcome = await producer.publish(now: now)
        #expect(outcome == .failed(.writeFailed(.appGroupUnavailable)))
    }

    @Test func emptyActualStateClearsPreviouslyPublishedTasks() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = makeID(1)
        let conversations = [id: conversation(id, title: "Task", updatedAt: 100, ordinary: true)]

        let producer = WidgetSnapshotProducer(
            store: store,
            runSource: FakeRunSource(runs: [run(id, state: "running", startedAt: 100)]),
            conversationSource: FakeConversationSource(conversations: conversations)
        )
        _ = await producer.publish(now: now)

        let emptyProducer = WidgetSnapshotProducer(
            store: store,
            runSource: FakeRunSource(runs: []),
            conversationSource: FakeConversationSource(conversations: conversations)
        )
        let later = now.addingTimeInterval(60)
        let outcome = await emptyProducer.publish(now: later)
        #expect(outcome == .published(.init(publishedAt: later, taskCount: 0)))

        guard case .fresh(let snapshot) = store.load(now: later) else {
            Issue.record("expected the empty snapshot to replace the old rows")
            return
        }
        #expect(snapshot.tasks.isEmpty)
    }

    @Test func readFailureIsObservableAndKeepsPreviousSnapshot() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = makeID(1)
        let conversations = [id: conversation(id, title: "Task", updatedAt: 100, ordinary: true)]
        let good = WidgetSnapshotProducer(
            store: store,
            runSource: FakeRunSource(runs: [run(id, state: "running", startedAt: 100)]),
            conversationSource: FakeConversationSource(conversations: conversations)
        )
        _ = await good.publish(now: now)
        let previous = store.load(now: now)
        guard case .fresh = previous else {
            Issue.record("expected the first publish to be fresh")
            return
        }

        let failing = WidgetSnapshotProducer(
            store: store,
            runSource: FailingRunSource(),
            conversationSource: FakeConversationSource(conversations: conversations)
        )
        let outcome = await failing.publish(now: now.addingTimeInterval(10))
        #expect(outcome == .failed(.readFailed))
        #expect(store.load(now: now) == previous)
    }

    @Test func writeFailureIsObservableAndKeepsPreviousSnapshot() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = makeID(1)
        let conversations = [id: conversation(id, title: "Task", updatedAt: 100, ordinary: true)]
        let runs = [run(id, state: "running", startedAt: 100)]
        let good = WidgetSnapshotProducer(
            store: store,
            runSource: FakeRunSource(runs: runs),
            conversationSource: FakeConversationSource(conversations: conversations)
        )
        _ = await good.publish(now: now)
        let previous = store.load(now: now)

        let failing = WidgetSnapshotProducer(
            store: FailingStore(underlying: store),
            runSource: FakeRunSource(runs: runs),
            conversationSource: FakeConversationSource(conversations: conversations)
        )
        let outcome = await failing.publish(now: now.addingTimeInterval(10))
        #expect(outcome == .failed(.writeFailed(.writeFailed)))
        #expect(store.load(now: now) == previous)
    }

    // MARK: - Center coalescing

    @Test func repeatedStartIsIdempotentAndPublishesOnce() async {
        let publisher = CountingPublisher()
        let environment = AppEnvironment.preview()
        let conversationCenter = ConversationCenter(environment: environment)
        let center = WidgetSnapshotCenter(
            publisher: publisher,
            observesAppActivation: false,
            reloadWidgets: {}
        )

        center.start(observing: conversationCenter)
        center.start(observing: conversationCenter)
        await center.waitForIdleForTesting()

        let calls = await publisher.calls()
        #expect(calls == 1)
        #expect(center.lastError == nil)
        #expect(center.isPublishing == false)
        center.stop()
    }

    @Test func refreshDuringWriteRunsAgainWithTheLastResult() async {
        let firstDate = now
        let laterDate = now.addingTimeInterval(1)
        let publisher = GatedPublisher(
            first: .published(.init(publishedAt: firstDate, taskCount: 1)),
            later: .published(.init(publishedAt: laterDate, taskCount: 0))
        )
        let center = WidgetSnapshotCenter(publisher: publisher, reloadWidgets: {})
        center.refreshNow(reason: .runState)
        await publisher.waitUntilEntered()
        #expect(center.isPublishing)

        // Simulates a title/deletion/temporary event arriving while the JSON
        // write is in flight.
        center.refreshNow(reason: .conversationList)
        center.refreshNow(reason: .temporarySession)
        await publisher.releaseFirst()
        await center.waitForIdleForTesting()

        let calls = await publisher.calls()
        #expect(calls == 2)
        #expect(center.lastPublishedAt == laterDate)
        #expect(center.lastError == nil)
        #expect(center.isPublishing == false)
    }

    @Test func stoppedDrainCannotClearAReplacementDrain() async throws {
        let publisher = GatedPublisher(
            first: .published(.init(publishedAt: now, taskCount: 1)),
            later: .published(.init(publishedAt: now.addingTimeInterval(1), taskCount: 0)),
            holdLater: true
        )
        let center = WidgetSnapshotCenter(publisher: publisher, reloadWidgets: {})
        center.refreshNow()
        await publisher.waitUntilEntered()
        let stopped = try #require(center.stop())
        center.refreshNow()
        await publisher.waitUntilLaterEntered()
        await publisher.releaseFirst()
        await stopped.value
        #expect(center.isPublishing)
        // The old completion must leave the replacement drain registered,
        // including an event arriving while its write is still pending.
        center.refreshNow(reason: .conversationList)
        await publisher.releaseLater()
        await center.waitForIdleForTesting()
        #expect(await publisher.calls() == 3)
        #expect(center.lastPublishedAt == now.addingTimeInterval(1))
        #expect(!center.isPublishing)
    }

    @Test func failedPublishIsObservableAndSuccessClearsIt() async {
        let publishedAt = now.addingTimeInterval(5)
        let publisher = SequencePublisher([
            .failed(.readFailed),
            .published(.init(publishedAt: publishedAt, taskCount: 2))
        ])
        let center = WidgetSnapshotCenter(publisher: publisher, reloadWidgets: {})

        center.refreshNow()
        await center.waitForIdleForTesting()
        guard case .readFailed? = center.lastError else {
            Issue.record("expected the read failure to be observable")
            return
        }
        #expect(center.lastPublishedAt == nil)

        center.refreshNow()
        await center.waitForIdleForTesting()
        #expect(center.lastError == nil)
        #expect(center.lastPublishedAt == publishedAt)
    }

    // MARK: - Fixtures

    private func makeID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    private func run(_ conversationID: UUID, state: String, startedAt: TimeInterval) -> WidgetSnapshotRun {
        WidgetSnapshotRun(
            id: UUID(uuidString: String(format: "11111111-0000-0000-0000-%012d", Int(startedAt)))!,
            conversationID: conversationID,
            state: state,
            startedAt: Date(timeIntervalSince1970: startedAt)
        )
    }

    private func conversation(
        _ id: UUID,
        title: String,
        updatedAt: TimeInterval,
        ordinary: Bool,
        archived: Bool = false
    ) -> WidgetSnapshotConversation {
        WidgetSnapshotConversation(
            id: id,
            title: title,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            isArchived: archived,
            isOrdinary: ordinary
        )
    }

    private func makeStore() throws -> (WidgetTaskSnapshotStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeWidgetProduction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (WidgetTaskSnapshotStore(containerURL: root), root)
    }
}

// MARK: - Fakes

private struct FakeRunSource: WidgetSnapshotRunSource {
    var runs: [WidgetSnapshotRun]

    func nonTerminalRuns(limit: Int) async throws -> [WidgetSnapshotRun] {
        Array(runs.prefix(max(1, limit)))
    }
}

private struct FailingRunSource: WidgetSnapshotRunSource {
    func nonTerminalRuns(limit: Int) async throws -> [WidgetSnapshotRun] {
        throw FakeFailure.read
    }
}

private struct FakeConversationSource: WidgetSnapshotConversationSource {
    var conversations: [UUID: WidgetSnapshotConversation]

    func conversation(id: UUID) async throws -> WidgetSnapshotConversation? {
        conversations[id]
    }
}

private struct FailingStore: WidgetSnapshotStoring {
    let underlying: WidgetTaskSnapshotStore

    func write(_ snapshot: WidgetTaskSnapshot) throws {
        throw WidgetTaskSnapshotStoreError.writeFailed
    }

    func load(now: Date) -> WidgetTaskSnapshotLoadResult {
        underlying.load(now: now)
    }
}

private enum FakeFailure: Error {
    case read
}

private actor GatedPublisher: WidgetSnapshotPublishing {
    private let first: WidgetSnapshotPublishOutcome
    private let later: WidgetSnapshotPublishOutcome
    private var callCount = 0
    private var releaseRequested = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private let holdLater: Bool
    private var laterEnteredContinuation: CheckedContinuation<Void, Never>?
    private var laterReleaseContinuation: CheckedContinuation<Void, Never>?

    init(first: WidgetSnapshotPublishOutcome, later: WidgetSnapshotPublishOutcome, holdLater: Bool = false) {
        self.first = first
        self.later = later
        self.holdLater = holdLater
    }

    func publish(
        now: Date,
        excludingConversationIDs: Set<UUID>
    ) async -> WidgetSnapshotPublishOutcome {
        callCount += 1
        if callCount == 1 {
            enteredContinuation?.resume()
            enteredContinuation = nil
            if !releaseRequested {
                await withCheckedContinuation { releaseContinuation = $0 }
            }
            releaseRequested = false
            return first
        }
        if callCount == 2, holdLater {
            laterEnteredContinuation?.resume()
            laterEnteredContinuation = nil
            await withCheckedContinuation { laterReleaseContinuation = $0 }
        }
        return later
    }

    func waitUntilEntered() async {
        if callCount > 0 { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func releaseFirst() {
        if let continuation = releaseContinuation {
            releaseContinuation = nil
            continuation.resume()
        } else {
            releaseRequested = true
        }
    }

    func calls() -> Int {
        callCount
    }

    func waitUntilLaterEntered() async {
        if callCount >= 2 { return }
        await withCheckedContinuation { laterEnteredContinuation = $0 }
    }

    func releaseLater() {
        laterReleaseContinuation?.resume()
        laterReleaseContinuation = nil
    }
}

private actor CountingPublisher: WidgetSnapshotPublishing {
    private var callCount = 0

    func publish(
        now: Date,
        excludingConversationIDs: Set<UUID>
    ) async -> WidgetSnapshotPublishOutcome {
        callCount += 1
        return .published(.init(publishedAt: now, taskCount: 0))
    }

    func calls() -> Int {
        callCount
    }
}

private actor SequencePublisher: WidgetSnapshotPublishing {
    private var outcomes: [WidgetSnapshotPublishOutcome]

    init(_ outcomes: [WidgetSnapshotPublishOutcome]) {
        self.outcomes = outcomes
    }

    func publish(
        now: Date,
        excludingConversationIDs: Set<UUID>
    ) async -> WidgetSnapshotPublishOutcome {
        guard !outcomes.isEmpty else {
            return .published(.init(publishedAt: now, taskCount: 0))
        }
        return outcomes.removeFirst()
    }
}
