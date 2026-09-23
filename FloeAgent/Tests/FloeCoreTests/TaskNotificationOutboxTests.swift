// FloeCoreTests — Build 222 durable terminal-event outbox.
//
// The first-authorization race is the bug this type closes: a terminal event
// resolved while authorization is notDetermined/denied (or before the answer
// arrives) must be queued and delivered later, never dropped. Diagnostics keep
// the authorization state the app acted on plus the last scheduling failure.

import Foundation
import Testing
@testable import FloeCore

private func makeEvent(
    id: String = "run.1.terminal",
    kind: TaskTerminalEventKind = .completed,
    title: String = "任务已完成",
    body: String = "打开任务查看结果。",
    conversationID: UUID? = UUID(),
    runID: UUID? = UUID()
) -> TaskTerminalEvent {
    TaskTerminalEvent(
        identifier: id,
        kind: kind,
        title: title,
        body: body,
        createdAt: Date(),
        deepLink: BackgroundWorkDeepLink(
            kind: .modelRun,
            conversationID: conversationID,
            runID: runID
        )
    )
}

@Suite("FloeCore.TaskNotificationOutbox")
struct TaskNotificationOutboxTests {

    @Test("Without authorization the event is queued, never dropped")
    func queuesWhenUnauthorized() {
        var outbox = TaskNotificationOutbox()
        let event = makeEvent()
        let disposition = outbox.enqueue(event, canPresent: false)
        #expect(disposition == .queuedForAuthorization)
        #expect(outbox.pendingCount == 1)
        #expect(outbox.pending.first?.identifier == event.identifier)
        // Still nothing may be presented.
        #expect(outbox.takePresentable(canPresent: false).isEmpty)
        #expect(outbox.pendingCount == 1)
    }

    @Test("With authorization the event is presented immediately, not queued")
    func presentsWhenAuthorized() {
        var outbox = TaskNotificationOutbox()
        #expect(outbox.enqueue(makeEvent(), canPresent: true) == .presentNow)
        #expect(outbox.pendingCount == 0)
        #expect(outbox.takePresentable(canPresent: true).isEmpty)
    }

    @Test("The queued event is delivered once authorization arrives")
    func flushesAfterAuthorization() {
        var outbox = TaskNotificationOutbox()
        let event = makeEvent()
        _ = outbox.enqueue(event, canPresent: false)
        let flush = outbox.takePresentable(canPresent: true)
        #expect(flush == [event])
        #expect(outbox.pendingCount == 0)
        // A second flush does not re-deliver.
        #expect(outbox.takePresentable(canPresent: true).isEmpty)
    }

    @Test("Re-publishing the same terminal state replaces the queued event")
    func replacesDuplicateIdentifier() {
        var outbox = TaskNotificationOutbox()
        _ = outbox.enqueue(makeEvent(body: "第一次"), canPresent: false)
        let replacement = makeEvent(body: "第二次")
        #expect(outbox.enqueue(replacement, canPresent: false) == .replacedQueuedEvent)
        #expect(outbox.pendingCount == 1)
        #expect(outbox.pending.first?.body == "第二次")
    }

    @Test("Completion, failure, cancellation and action-required are distinct kinds")
    func allTerminalKinds() {
        var outbox = TaskNotificationOutbox()
        for (index, kind) in TaskTerminalEventKind.allCases.enumerated() {
            _ = outbox.enqueue(
                makeEvent(id: "event.\(index)", kind: kind),
                canPresent: false
            )
        }
        #expect(outbox.pendingCount == 4)
        #expect(outbox.pending.map(\.kind) == TaskTerminalEventKind.allCases)
        #expect(TaskTerminalEventKind.completed.isTerminal)
        #expect(TaskTerminalEventKind.failed.isTerminal)
        #expect(TaskTerminalEventKind.cancelled.isTerminal)
        #expect(!TaskTerminalEventKind.actionRequired.isTerminal)
    }

    @Test("The gate maps the policy to the durable terminal kinds")
    func eventGate() {
        let gate = TaskNotificationEventGate(
            notifiesCompleted: true,
            notifiesFailed: true,
            notifiesCancelled: false,
            notifiesActionRequired: true
        )
        #expect(gate.allows(.completed))
        #expect(gate.allows(.failed))
        #expect(!gate.allows(.cancelled))
        #expect(gate.allows(.actionRequired))
        for kind in TaskTerminalEventKind.allCases {
            #expect(!TaskNotificationEventGate.silent.allows(kind))
        }
    }

    @Test("Scheduling success and failure are recorded for diagnostics")
    func schedulingDiagnostics() {
        var outbox = TaskNotificationOutbox()
        let failure = TaskNotificationSchedulingFailure(
            identifier: "run.9.terminal",
            reason: "notifications are not authorized",
            at: Date(),
            wasAuthorizationBlocked: true
        )
        outbox.recordSchedulingFailure(
            identifier: failure.identifier,
            reason: failure.reason,
            at: failure.at,
            wasAuthorizationBlocked: true
        )
        #expect(outbox.lastSchedulingFailure == failure)

        let diagnostics = TaskNotificationDiagnostics.make(
            outbox: outbox,
            authorization: "notDetermined",
            canPresentAlert: false
        )
        #expect(diagnostics.pendingCount == 0)
        #expect(diagnostics.lastFailure?.wasAuthorizationBlocked == true)
        #expect(diagnostics.authorizationSummary.contains("notDetermined"))
        #expect(diagnostics.lastFailureSummary.contains("run.9.terminal"))

        outbox.recordSchedulingSuccess(identifier: "run.9.terminal")
        #expect(outbox.lastSchedulingFailure == nil)
        #expect(outbox.lastScheduledIdentifier == "run.9.terminal")
        #expect(outbox.lastScheduledAt != nil)
    }

    @Test("Queue overflow records a failure instead of silently vanishing")
    func capacityRecordsFailure() {
        var outbox = TaskNotificationOutbox(maximumPendingEvents: 2)
        _ = outbox.enqueue(makeEvent(id: "a"), canPresent: false)
        _ = outbox.enqueue(makeEvent(id: "b"), canPresent: false)
        _ = outbox.enqueue(makeEvent(id: "c"), canPresent: false)
        #expect(outbox.pendingCount == 2)
        #expect(outbox.droppedEventCount == 1)
        #expect(outbox.lastSchedulingFailure != nil)
        // An action-required event is the last thing to be evicted.
        _ = outbox.enqueue(makeEvent(id: "d", kind: .actionRequired), canPresent: false)
        #expect(outbox.pending.contains { $0.kind == .actionRequired })
    }

    @Test("Discarding a queued event after user action")
    func discardQueuedEvent() {
        var outbox = TaskNotificationOutbox()
        _ = outbox.enqueue(makeEvent(id: "a"), canPresent: false)
        outbox.discard(identifier: "a")
        #expect(outbox.pendingCount == 0)
    }

    @Test("The outbox and its deep links survive persistence")
    func persistenceRoundTrip() {
        let name = "floe.tests.notification.outbox.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let conversationID = UUID()
        let runID = UUID()
        var outbox = TaskNotificationOutbox()
        _ = outbox.enqueue(
            makeEvent(
                id: "run.\(runID.uuidString).terminal",
                kind: .failed,
                conversationID: conversationID,
                runID: runID
            ),
            canPresent: false
        )
        outbox.recordSchedulingFailure(
            identifier: "run.\(runID.uuidString).terminal",
            reason: "authorization denied",
            wasAuthorizationBlocked: true
        )
        TaskNotificationOutboxStore.save(outbox, to: defaults)

        let loaded = TaskNotificationOutboxStore.load(from: defaults)
        #expect(loaded.pendingCount == 1)
        #expect(loaded.lastSchedulingFailure?.wasAuthorizationBlocked == true)
        let event = loaded.pending[0]
        #expect(event.kind == .failed)
        #expect(event.deepLink.kind == .modelRun)
        #expect(event.deepLink.conversationID == conversationID)
        #expect(event.deepLink.runID == runID)
        // A Linux terminal event keeps its environment identity too.
        let link = BackgroundWorkDeepLink(kind: .linuxSession, environmentID: "env-7")
        #expect(BackgroundWorkDeepLink.parse(link.userInfo)?.environmentID == "env-7")
    }

    // MARK: - Persistent terminal-alert factories (Build 226+)

    @Test("The model-run factory carries the task name and result with a stable route")
    func modelRunTerminalFactory() {
        let runID = UUID()
        let conversationID = UUID()
        let first = TaskTerminalEvent.modelRunTerminal(
            runID: runID,
            conversationID: conversationID,
            taskName: "整理季度报表",
            kind: .completed,
            body: "已完成 · 共处理 42 行"
        )
        // The task name is the title; the outcome line is the body; the
        // identifier and deep link are the stable route.
        #expect(first.title == "整理季度报表")
        #expect(first.body == "已完成 · 共处理 42 行")
        #expect(first.identifier == "run.\(runID.uuidString).terminal")
        #expect(first.kind == .completed)
        #expect(first.deepLink.kind == .modelRun)
        #expect(first.deepLink.conversationID == conversationID)
        #expect(first.deepLink.runID == runID)
        // Re-publishing the same terminal state replaces instead of stacking.
        let second = TaskTerminalEvent.modelRunTerminal(
            runID: runID,
            conversationID: conversationID,
            taskName: "整理季度报表",
            kind: .completed,
            body: "已完成 · 共处理 43 行"
        )
        #expect(second.identifier == first.identifier)
        var outbox = TaskNotificationOutbox()
        _ = outbox.enqueue(first, canPresent: false)
        #expect(outbox.enqueue(second, canPresent: false) == .replacedQueuedEvent)
        #expect(outbox.pendingCount == 1)
        #expect(outbox.pending.first?.body == "已完成 · 共处理 43 行")
    }

    @Test("The Linux session factory scopes the identifier by launch generation")
    func linuxSessionTerminalFactoryScopesByGeneration() {
        let firstBoot = TaskTerminalEvent.linuxSessionTerminal(
            environmentID: "env-9",
            environmentTitle: "数据分析 VM",
            kind: .cancelled,
            body: "已取消 · 用户关闭了画中画",
            launchGeneration: 3
        )
        #expect(firstBoot.identifier == "linux.session.env-9.g3.terminal")
        #expect(firstBoot.title == "数据分析 VM")
        #expect(firstBoot.deepLink.environmentID == "env-9")
        // The same boot replaces its own alert…
        let sameBoot = TaskTerminalEvent.linuxSessionTerminal(
            environmentID: "env-9",
            environmentTitle: "数据分析 VM",
            kind: .cancelled,
            body: "已取消 · 停止完成",
            launchGeneration: 3
        )
        #expect(sameBoot.identifier == firstBoot.identifier)
        // …while a later restart is a distinct event, not a replacement.
        let secondBoot = TaskTerminalEvent.linuxSessionTerminal(
            environmentID: "env-9",
            environmentTitle: "数据分析 VM",
            kind: .cancelled,
            body: "已取消 · 用户关闭了画中画",
            launchGeneration: 4
        )
        #expect(secondBoot.identifier != firstBoot.identifier)
        // Unknown generation preserves the legacy identifier instead of
        // inventing one.
        let unknown = TaskTerminalEvent.linuxSessionTerminal(
            environmentID: "env-9",
            environmentTitle: "数据分析 VM",
            kind: .failed,
            body: "运行失败 · 服务异常退出"
        )
        #expect(unknown.identifier == "linux.session.env-9.terminal")
    }

    @Test("Content bounds normalize whitespace and cap length")
    func contentBoundsTruncateAndNormalize() {
        let longName = String(repeating: "很", count: 200)
        let event = TaskTerminalEvent.modelRunTerminal(
            runID: UUID(),
            conversationID: UUID(),
            taskName: longName,
            kind: .failed,
            body: String(repeating: "x", count: 500)
        )
        #expect(event.title.count == TaskNotificationContentBounds.maximumTitleCharacters)
        #expect(event.body.count == TaskNotificationContentBounds.maximumBodyCharacters)
        let messy = TaskNotificationContentBounds.truncating("  a\n\n b \t c  ", to: 80)
        #expect(messy == "a b c")
    }

    @Test("An alert older than the maximum age is classified expired")
    func expiredEventClassification() {
        let now = Date()
        let fresh = TaskTerminalEvent.modelRunTerminal(
            runID: UUID(),
            conversationID: UUID(),
            taskName: "t",
            kind: .completed,
            body: "已完成",
            createdAt: now.addingTimeInterval(-60)
        )
        #expect(!fresh.isExpired(now: now))
        let aged = TaskTerminalEvent.modelRunTerminal(
            runID: UUID(),
            conversationID: UUID(),
            taskName: "t",
            kind: .completed,
            body: "已完成",
            createdAt: now.addingTimeInterval(-TaskTerminalEvent.defaultMaximumAlertAge - 1)
        )
        #expect(aged.isExpired(now: now))
    }
}
