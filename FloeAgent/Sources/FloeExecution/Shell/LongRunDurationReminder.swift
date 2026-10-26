// FloeExecution — One-time long-run duration advisory monitor.
//
// New explicit human policy (2026-10-26): default long-running execution has
// NO application execution deadline. Instead the user receives ONE reminder
// when a run/job has been executing for 600 seconds of HOST MONOTONIC
// elapsed time, and the work simply continues (cancellable, durable).
//
// Contract:
//  * The monitor is observe-and-notify ONLY: firing, dropping or failing an
//    advisory can never mark work failed/cancelled/completed, release an
//    environment/slot, discard partial output, replay work, interrupt a
//    command, or fake success. Nothing here touches execution state.
//  * Timing is monotonic (`Task.sleep(for:)` on `ContinuousClock` via the
//    injectable sleeper). `Date` values are diagnostics/persistence only and
//    never decide firing, so host wall-clock changes cannot fire an advisory
//    early or late. There is no wall-clock re-arming after relaunch: an
//    in-process run/job that died is reconciled to a terminal state by its
//    owner, and a dead unit of work never re-arms.
//  * Exactly-once per ownership key per process lifetime: `begin` is
//    idempotent (an armed or already-fired key is never reset, so a
//    multi-phase native operation handing off to its next bound phase job
//    neither postpones the threshold nor duplicates the advisory), the fire
//    mark is set BEFORE the sink runs, and `end` clears the armed entry but
//    never un-fires a key. Distinct independent jobs use distinct keys and
//    stay distinct.
//  * DELIVERY FENCE (proven by test, not by comment): a fired advisory
//    becomes an ACTIVE delivery (`firing` set) and the sink receives a fence
//    closure it MUST check immediately before its durable enqueue. `end`
//    closes the fence synchronously on this actor, so a unit of work that
//    reaches its terminal state at any point before the sink's fence check
//    cancels the delivery — a foreground shell run whose tool call returned
//    while the sink task was still hopping can never alert afterwards.
//  * Ownership keys are runtime-issued identities, never model-supplied
//    aliases: `job.<jobUUID|advisoryGroupUUID>` (the group id only a trusted
//    native submission can bind) and `shell.<runID>.<clientScopedSessionToken>`
//    (the token is runtime-issued and bounded), so unrelated
//    commands/sessions cannot collide and one running job cannot multiply.
//  * Sink failures are contained: the sink is non-throwing by contract; the
//    fire path additionally guards its own bookkeeping, so a denied
//    notification permission or a storage failure can never fail the running
//    job/command. Delivery durability/idempotence lives in the existing
//    `TaskNotificationOutbox` under the stable identifier
//    `duration.advisory.<ownershipKey>` (replace-not-stack).

import Foundation

/// One fired advisory, handed to the app-side sink for liveness re-check and
/// durable delivery. Carries runtime-issued identities only.
public struct LongRunAdvisoryMilestone: Sendable, Equatable {
    /// Stable ownership identity (`job.<uuid>` / `shell.<runID>.<token>`).
    public var ownershipKey: String
    public var conversationID: UUID?
    public var runID: UUID?
    /// The representative member job (the first phase that armed a group, or
    /// the job itself when ungrouped). Nil for a foreground shell run.
    public var jobID: UUID?
    /// Trusted native parent-operation group (e.g. one MCP creation record
    /// across its bound build phases). Nil for ungrouped jobs and shell runs.
    public var advisoryGroupID: UUID?
    /// Diagnostics label (target tool name); never user-visible copy.
    public var label: String
    /// Host wall clock at arm time (diagnostics/persistence only).
    public var startedAt: Date
    /// Host wall clock when the monotonic threshold elapsed.
    public var firedAt: Date
    public var thresholdSeconds: TimeInterval

    public init(
        ownershipKey: String,
        conversationID: UUID?,
        runID: UUID?,
        jobID: UUID?,
        advisoryGroupID: UUID?,
        label: String,
        startedAt: Date,
        firedAt: Date,
        thresholdSeconds: TimeInterval
    ) {
        self.ownershipKey = ownershipKey
        self.conversationID = conversationID
        self.runID = runID
        self.jobID = jobID
        self.advisoryGroupID = advisoryGroupID
        self.label = label
        self.startedAt = startedAt
        self.firedAt = firedAt
        self.thresholdSeconds = thresholdSeconds
    }
}

/// The one-time duration advisory monitor. See the file header for the
/// full contract. Platform-independent: the app injects the delivery sink
/// (existing durable outbox) and tests inject a virtual sleeper.
public actor LongRunDurationReminder {
    /// The default human-policy threshold: one reminder at 600 seconds of
    /// host monotonic elapsed execution.
    public static let defaultThresholdSeconds: TimeInterval = 600

    /// Delivery fence: true ONLY while this key's fired advisory is still an
    /// active delivery (the unit of work has not ended since the fire). The
    /// sink must check it immediately before its durable enqueue; a false
    /// answer means the work ended mid-delivery and the advisory must drop.
    public typealias DeliveryFence = @Sendable () async -> Bool

    /// Receives a fired milestone plus its delivery fence. Non-throwing by
    /// contract: delivery, permission and storage failures are the sink's
    /// own diagnostics and can never propagate into execution.
    public typealias Sink = @Sendable (LongRunAdvisoryMilestone, @escaping DeliveryFence) async -> Void

    /// Sleeps `seconds` on the host monotonic clock. Returns false when the
    /// sleep was interrupted by cancellation (the armed task was ended).
    /// Tests inject a virtual-clock sleeper; production uses the default.
    public typealias Sleeper = @Sendable (TimeInterval) async -> Bool

    private struct Meta: Sendable {
        var conversationID: UUID?
        var runID: UUID?
        var jobID: UUID?
        var advisoryGroupID: UUID?
        var label: String
        var startedAt: Date
    }

    private struct Entry {
        var task: Task<Void, Never>
        var meta: Meta
    }

    private let threshold: TimeInterval
    private let sink: Sink
    private let sleeper: Sleeper
    private let now: @Sendable () -> Date
    private var armed: [String: Entry] = [:]
    // Work lifetime outlives the brief delivery call when an alert is queued.
    private var activeWorkKeys: Set<String> = []
    /// Keys whose fired advisory is an in-flight delivery (fence open).
    private var firing: Set<String> = []
    /// Insert-only per process lifetime: an advisory that fired once for a
    /// key can never fire again for it, so a late `begin` (next phase of one
    /// grouped operation, an idempotent tool-call replay) neither duplicates
    /// nor postpones anything. Cleared only by process exit — the entries are
    /// bounded strings.
    private var firedKeys: Set<String> = []

    public init(
        threshold: TimeInterval = LongRunDurationReminder.defaultThresholdSeconds,
        sink: @escaping Sink,
        sleeper: Sleeper? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        // The threshold itself must be a real finite positive duration; an
        // invalid configuration falls back to the policy default rather than
        // disabling or spamming advisories.
        self.threshold = (threshold.isFinite && threshold > 0)
            ? threshold
            : LongRunDurationReminder.defaultThresholdSeconds
        self.sink = sink
        self.sleeper = sleeper ?? { seconds in
            do {
                try await Task.sleep(for: .seconds(seconds))
                return true
            } catch {
                return false
            }
        }
        self.now = now
    }

    /// Arms the one-shot advisory for one ownership key. Idempotent: a key
    /// that is already armed keeps its ORIGINAL threshold (a phase handoff
    /// never resets the clock), and a key that already fired is never
    /// re-armed. Never throws, never touches execution state.
    public func begin(
        key: String,
        conversationID: UUID?,
        runID: UUID?,
        jobID: UUID?,
        advisoryGroupID: UUID? = nil,
        label: String
    ) {
        guard !firedKeys.contains(key), armed[key] == nil else { return }
        activeWorkKeys.insert(key)
        let meta = Meta(
            conversationID: conversationID,
            runID: runID,
            jobID: jobID,
            advisoryGroupID: advisoryGroupID,
            label: label,
            startedAt: now()
        )
        let task = Task { [weak self, threshold, sleeper] in
            guard await sleeper(threshold) else { return }
            guard !Task.isCancelled else { return }
            await self?.fire(key: key)
        }
        armed[key] = Entry(task: task, meta: meta)
    }

    /// Disarms a key when its unit of work reached a terminal state (or a
    /// foreground run returned), and CLOSES ITS DELIVERY FENCE: a fired
    /// advisory whose sink has not passed its fence check yet is cancelled
    /// here, so nothing alerts after the actual end. A fired key stays fired:
    /// `end` can never make a delivered advisory deliverable again. Calling
    /// `end` for an unknown key is a no-op.
    public func end(key: String) {
        activeWorkKeys.remove(key)
        if let entry = armed.removeValue(forKey: key) {
            entry.task.cancel()
        }
        firing.remove(key)
    }

    /// True while this key's fired advisory is still an active delivery.
    /// This is the fence the sink checks immediately before its durable
    /// enqueue.
    public func deliveryFenceOpen(key: String) -> Bool { firing.contains(key) }

    /// Authoritative foreground-command lifetime, including queued delivery.
    public func workIsActive(key: String) -> Bool { activeWorkKeys.contains(key) }

    /// True when the advisory already fired for this key in this process
    /// (test/introspection helper).
    public func hasFired(key: String) -> Bool { firedKeys.contains(key) }

    /// Number of currently armed one-shots (test/introspection helper).
    public var armedCount: Int { armed.count }

    /// Number of in-flight deliveries whose fence is still open
    /// (test/introspection helper).
    public var activeDeliveryCount: Int { firing.count }

    private func fire(key: String) {
        guard !Task.isCancelled else { return }
        // Exactly-once mark BEFORE anything leaves the actor: a concurrent
        // end/tick/re-fire can never produce a second sink call.
        guard let entry = armed.removeValue(forKey: key), !firedKeys.contains(key) else { return }
        firedKeys.insert(key)
        // Open the delivery fence: from this point an `end(key)` processed
        // before the sink's fence check cancels the delivery.
        firing.insert(key)
        let milestone = LongRunAdvisoryMilestone(
            ownershipKey: key,
            conversationID: entry.meta.conversationID,
            runID: entry.meta.runID,
            jobID: entry.meta.jobID,
            advisoryGroupID: entry.meta.advisoryGroupID,
            label: entry.meta.label,
            startedAt: entry.meta.startedAt,
            firedAt: now(),
            thresholdSeconds: threshold
        )
        let sink = self.sink
        // The sink is fire-and-forget from the monitor's perspective: it is
        // non-throwing, and the armed bookkeeping is already settled, so no
        // sink outcome can affect the running work or this monitor's state.
        Task { [weak self] in
            let fence: DeliveryFence = { [weak self] in
                guard let self else { return false }
                return await self.deliveryFenceOpen(key: key)
            }
            await sink(milestone, fence)
            await self?.finishDelivery(key: key)
        }
    }

    private func finishDelivery(key: String) {
        firing.remove(key)
    }
}
