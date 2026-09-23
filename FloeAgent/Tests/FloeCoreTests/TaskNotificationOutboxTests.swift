// FloeCoreTests — Build 222 durable terminal-event outbox.
//
// The first-authorization race is the bug this type closes: a terminal event
// resolved while authorization is notDetermined/denied (or before the answer
// arrives) must be queued and delivered later, never dropped. Diagnostics keep
// the authorization state the app acted on plus the last scheduling failure.

import Foundation
import Testing
@testable import FloeCore
import FloeModels

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

// MARK: - Notification deep-link target resolution and routing (H2)
//
// The pure decisions behind notification taps: how an authoritative
// existence/liveness answer maps to a route, and when a route may not proceed
// yet. Lives in FloeCoreTests because the terminal-event outbox it protects is
// FloeCore; the decision types themselves are FloeModels.

@Suite("FloeModels.TaskNotificationDeepLinkRouting")
struct TaskNotificationDeepLinkRoutingTests {

    private func resolve(
        persistenceReady: Bool = true,
        hasActiveScene: Bool = true,
        navigationSubscribersReady: Bool = true,
        isDuplicate: Bool = false,
        target: TaskDeepLinkTargetState
    ) -> TaskDeepLinkRouting {
        TaskNotificationDecision.resolveRouting(
            persistenceReady: persistenceReady,
            hasActiveScene: hasActiveScene,
            navigationSubscribersReady: navigationSubscribersReady,
            isDuplicate: isDuplicate,
            target: target
        )
    }

    @Test("A running target routes once every readiness gate is satisfied")
    func readyRunningTargetRoutes() {
        let state = TaskDeepLinkTargetState.linuxEnvironment(
            recordExists: true,
            ownedByRuntime: true,
            guestIsRunning: true
        )
        #expect(state == .exists)
        #expect(resolve(target: state) == .routeNow)
        #expect(resolve(target: .exists) == .routeNow)
    }

    @Test("Cold launch defers until persistence, scene and mounted subscribers are ready")
    func coldLaunchDefers() {
        #expect(resolve(persistenceReady: false, target: .exists) == .deferUntilReady)
        #expect(resolve(hasActiveScene: false, target: .exists) == .deferUntilReady)
        // The root view's deep-link subscribers are real evidence, not a
        // proxy: posting a route before they mount goes nowhere while
        // consuming the durable event.
        #expect(resolve(navigationSubscribersReady: false, target: .exists) == .deferUntilReady)
        #expect(!TaskDeepLinkRouting.deferUntilReady.consumesDurableEvent)
    }

    @Test("A repeat tap is suppressed before any other gate and keeps the in-flight route")
    func duplicateSuppressedFirst() {
        #expect(resolve(
            persistenceReady: false,
            navigationSubscribersReady: false,
            isDuplicate: true,
            target: .exists
        ) == .ignoreDuplicate)
        // The original in-flight request still owns and consumes the event.
        #expect(!TaskDeepLinkRouting.ignoreDuplicate.consumesDurableEvent)
    }

    @Test("A deleted Linux environment prompts instead of routing")
    func deletedEnvironmentPrompts() {
        let state = TaskDeepLinkTargetState.linuxEnvironment(
            recordExists: false,
            ownedByRuntime: false,
            guestIsRunning: false
        )
        #expect(state == .missing)
        #expect(resolve(target: state) == .promptMissingTarget)
        #expect(TaskDeepLinkRouting.promptMissingTarget.consumesDurableEvent)
    }

    @Test("A stopped existing environment is never reported as deleted")
    func stoppedExistingEnvironmentIsNotDeletion() {
        // The registry still holds the record and the runtime still owns the
        // environment; only the guest is not running.
        let state = TaskDeepLinkTargetState.linuxEnvironment(
            recordExists: true,
            ownedByRuntime: true,
            guestIsRunning: false
        )
        #expect(state == .existsStopped)
        let routing = resolve(target: state)
        #expect(routing == .promptStoppedTarget)
        #expect(routing != .promptMissingTarget)
        #expect(routing.promptedTargetState == .existsStopped)
        #expect(routing.consumesDurableEvent)
    }

    @Test("A service link shares the environment answer and keeps the list fallback")
    func serviceLinkSharesEnvironmentAnswer() {
        // A linuxService deep link addresses its session's environment, so the
        // same authoritative reads answer for both families.
        let serviceLink = BackgroundWorkDeepLink(
            kind: .linuxService,
            environmentID: "env-7",
            serviceJobID: UUID()
        )
        #expect(serviceLink.kind == .linuxService)
        #expect(serviceLink.environmentID == "env-7")
        let parsed = BackgroundWorkDeepLink.parse(serviceLink.userInfo)
        #expect(parsed?.kind == .linuxService)
        #expect(parsed?.environmentID == "env-7")
        #expect(parsed?.serviceJobID == serviceLink.serviceJobID)
        // Both Linux families can open the real environment list; the
        // model-run family has no task-list listener in this build.
        #expect(TaskNotificationDecision.hasSafeListFallback(kind: .linuxSession))
        #expect(TaskNotificationDecision.hasSafeListFallback(kind: .linuxService))
        #expect(!TaskNotificationDecision.hasSafeListFallback(kind: .modelRun))
        // A stopped service session still exists: prompt, never "deleted".
        let stopped = TaskDeepLinkTargetState.linuxEnvironment(
            recordExists: true,
            ownedByRuntime: true,
            guestIsRunning: false
        )
        #expect(resolve(target: stopped) == .promptStoppedTarget)
    }

    @Test("An unreadable registry reports unknown, never deletion")
    func unreadableRegistryIsUnknownNotDeleted() {
        let state = TaskDeepLinkTargetState.linuxEnvironment(
            recordExists: nil,
            ownedByRuntime: false,
            guestIsRunning: nil
        )
        #expect(state == .unknown)
        #expect(resolve(target: state) == .promptUnavailableTarget)
        #expect(TaskDeepLinkRouting.promptUnavailableTarget.consumesDurableEvent)
        #expect(TaskDeepLinkRouting.promptUnavailableTarget.promptedTargetState == .unknown)
    }

    @Test("A record with an unknown liveness is unknown, not running and not deleted")
    func recordPresentButRuntimeSilentIsUnknown() {
        let state = TaskDeepLinkTargetState.linuxEnvironment(
            recordExists: true,
            ownedByRuntime: nil,
            guestIsRunning: nil
        )
        #expect(state == .unknown)
    }

    @Test("A model-run link has no list listener, so its unreachable prompt stays banner-only")
    func modelRunPromptIsBannerOnly() {
        #expect(!TaskNotificationDecision.hasSafeListFallback(kind: .modelRun))
        #expect(resolve(target: .missing) == .promptMissingTarget)
    }

    @Test("Only navigating or prompting outcomes consume the durable event")
    func durableEventConsumption() {
        #expect(TaskDeepLinkRouting.routeNow.consumesDurableEvent)
        #expect(TaskDeepLinkRouting.promptMissingTarget.consumesDurableEvent)
        #expect(TaskDeepLinkRouting.promptStoppedTarget.consumesDurableEvent)
        #expect(TaskDeepLinkRouting.promptUnavailableTarget.consumesDurableEvent)
        #expect(!TaskDeepLinkRouting.deferUntilReady.consumesDurableEvent)
        #expect(!TaskDeepLinkRouting.ignoreDuplicate.consumesDurableEvent)
        #expect(TaskDeepLinkRouting.routeNow.promptedTargetState == nil)
    }

    @Test("An earlier tap completion cannot act after a newer request begins")
    func generationRejectsEarlierCompletion() {
        var request = TaskDeepLinkRouteRequest()
        let first = request.begin()
        #expect(request.accepts(generation: first))
        let second = request.begin()
        #expect(second > first)
        // The earlier tap's async existence check finishes late: it must not
        // navigate over the newer tap.
        #expect(!request.accepts(generation: first))
        #expect(request.accepts(generation: second))
        #expect(request.current == second)
    }

    @Test("A retry carries its originating generation and a newer tap makes it stale")
    func retryKeepsOriginatingGeneration() {
        var request = TaskDeepLinkRouteRequest()
        let tap = request.begin()
        // The retry path does not begin a new request: it dispatches under the
        // generation of the tap that deferred it, so the single durable event
        // is consumed exactly once.
        #expect(request.accepts(generation: tap))
        #expect(request.current == tap)
        // A genuine newer tap supersedes it: the originating generation can no
        // longer dispatch and a retry must not adopt the newer one.
        let newer = request.begin()
        #expect(newer > tap)
        #expect(!request.accepts(generation: tap))
        #expect(request.accepts(generation: newer))
        #expect(request.current == newer)
    }

    // MARK: - Pending-route ownership (H3)
    //
    // The deferred slot must remember which tap created it. These sequences
    // are the deterministic model of the coordinator's
    // `handleNotificationRoute` / `flushPendingNotificationRoute`: a genuine
    // new tap supersedes an older deferred route, a retry dispatches only
    // under its originating generation, and a not-ready flush changes nothing.
    // Mutating request calls are bound to locals outside `#expect`, which
    // cannot evaluate a mutating member on its captured copy.

    private func routeLink(_ environmentID: String) -> BackgroundWorkDeepLink {
        BackgroundWorkDeepLink(kind: .linuxSession, environmentID: environmentID)
    }

    @Test("Deferred A cannot replay under ready tap B's generation")
    func deferredRouteSupersededByNewerReadyTap() {
        var request = TaskDeepLinkRouteRequest()
        let aGeneration = request.begin()
        let deferredA = request.deferRoute(
            key: "A",
            link: routeLink("env-a"),
            identifier: "alert.A",
            generation: aGeneration
        )
        #expect(deferredA)
        #expect(request.pending?.key == "A")
        #expect(request.pending?.generation == aGeneration)

        // Tap B arrives while the app is ready: the genuine new tap begins a
        // newer generation, and the still-deferred A is dropped with it.
        let bGeneration = request.begin()
        #expect(bGeneration > aGeneration)
        #expect(request.pending == nil)
        // The later readiness flush has no stale A to replay under B.
        let flushAfterReadyB = request.takePendingForRetry(ready: true)
        #expect(flushAfterReadyB == nil)
        #expect(!request.accepts(generation: aGeneration))
        #expect(request.accepts(generation: bGeneration))
    }

    @Test("When both taps were deferred, the flush replays only the newest")
    func deferredRoutesRetryOnlyNewestGeneration() {
        var request = TaskDeepLinkRouteRequest()
        let aGeneration = request.begin()
        let deferredA = request.deferRoute(
            key: "A",
            link: routeLink("env-a"),
            identifier: "alert.A",
            generation: aGeneration
        )
        let bGeneration = request.begin()
        let deferredB = request.deferRoute(
            key: "B",
            link: routeLink("env-b"),
            identifier: "alert.B",
            generation: bGeneration
        )
        #expect(deferredA)
        #expect(deferredB)
        #expect(bGeneration > aGeneration)
        #expect(request.pending?.key == "B")
        #expect(!request.accepts(generation: aGeneration))

        let retried = request.takePendingForRetry(ready: true)
        #expect(retried?.key == "B")
        #expect(retried?.identifier == "alert.B")
        #expect(retried?.generation == bGeneration)
        #expect(request.pending == nil)
    }

    @Test("An inactive scene keeps a deferred route armed with its original generation")
    func inactiveSceneRetainsDeferredRoute() {
        var request = TaskDeepLinkRouteRequest()
        let tap = request.begin()
        let deferred = request.deferRoute(
            key: "B",
            link: routeLink("env-b"),
            identifier: "alert.B",
            generation: tap
        )
        #expect(deferred)
        // The scene is still inactive: a flush attempt must change nothing,
        // so the route survives for the next ready transition.
        let inactiveFlush = request.takePendingForRetry(ready: false)
        #expect(inactiveFlush == nil)
        #expect(request.pending?.key == "B")
        #expect(request.pending?.generation == tap)
        // The scene becomes active: the retry carries the originating
        // generation, not a freshly invented one.
        let readyFlush = request.takePendingForRetry(ready: true)
        #expect(readyFlush?.generation == tap)
        // If the retry has to defer again (a readiness race), it re-arms under
        // the same generation and stays retryable.
        let rearmed = request.deferRoute(
            key: "B",
            link: routeLink("env-b"),
            identifier: "alert.B",
            generation: tap
        )
        #expect(rearmed)
        #expect(request.pending?.generation == tap)
        let finalFlush = request.takePendingForRetry(ready: true)
        #expect(finalFlush?.key == "B")
    }

    @Test("A retry handoff captured before a newer tap is stale before dispatch")
    func retryHandoffRejectedAfterNewerTap() {
        var request = TaskDeepLinkRouteRequest()
        let aGeneration = request.begin()
        let deferredA = request.deferRoute(
            key: "A",
            link: routeLink("env-a"),
            identifier: "alert.A",
            generation: aGeneration
        )
        #expect(deferredA)
        // The ready flush hands A off under its originating generation.
        let handoff = request.takePendingForRetry(ready: true)
        #expect(handoff?.generation == aGeneration)
        // A newer genuine tap runs before the handoff dispatches.
        let bGeneration = request.begin()
        // The coordinator's retry guard (`accepts(generation:)`) rejects the
        // stale handoff before any dedup/readiness/target work...
        #expect(!request.accepts(generation: aGeneration))
        // ...and a late defer from the abandoned attempt cannot overwrite the
        // newer tap's ownership.
        let lateDefer = request.deferRoute(
            key: "A",
            link: routeLink("env-a"),
            identifier: "alert.A",
            generation: aGeneration
        )
        #expect(!lateDefer)
        #expect(request.pending == nil)
        #expect(request.accepts(generation: bGeneration))
    }

    @Test("A duplicate tap never begins a generation, so it cannot supersede the route")
    func duplicateTapCannotSupersedeGeneration() {
        // The coordinator's dedup gate returns `.ignoreDuplicate` before any
        // request work: the repeat tap neither routes nor consumes the durable
        // event, so the in-flight request keeps ownership.
        let duplicate = resolve(isDuplicate: true, target: .exists)
        #expect(duplicate == .ignoreDuplicate)
        #expect(!duplicate.consumesDurableEvent)
        // Because that gate runs before `begin()`, a deferred route keeps its
        // originating generation and remains retryable.
        var request = TaskDeepLinkRouteRequest()
        let tap = request.begin()
        let deferred = request.deferRoute(
            key: "A",
            link: routeLink("env-a"),
            identifier: "alert.A",
            generation: tap
        )
        #expect(deferred)
        #expect(request.current == tap)
        #expect(request.pending?.generation == tap)
        let retried = request.takePendingForRetry(ready: true)
        #expect(retried?.generation == tap)
    }
}
