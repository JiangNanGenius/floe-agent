// SPDX-License-Identifier: MPL-2.0
//
// RB-1 runtime bootstrap — bounded synchronous-JNI-to-async command mailbox.
//
// Rules (RB1 handoff + contract asyncJniDesign):
// * A synchronous native/binder call validates and enqueues bounded work and
//   returns PROMPTLY. It never awaits an actor, network or SQLite through a
//   semaphore, runBlocking or an attached JNI callback.
// * Baseline bounds: queued <= 64 AND active <= 16 command operations, plus
//   explicit queued-envelope byte bounds and the frozen 64 KiB per-envelope
//   bound. Breaching any bound is a typed rejection (`mailboxSaturated` /
//   `envelopeTooLarge`).
// * The immediate receipt is ONLY `correlationID + operationReceiptID` — no
//   conversation/run/environment/job ID before the real atomic preparation.
// * Exact-once cancellation and settlement: a queued entry can be cancelled
//   with provable no-effect; an already-started entry keeps its slot and its
//   accounting until the REAL completion arrives. No timer frees executing
//   capacity. Late/foreign settlements after close are classified, never
//   double-settled.
// * Command slots are SHORT-LIVED: a future run command releases its slot at
//   actual preparation/start; the run itself is owned by the separately
//   bounded run/service lifecycle (RB4 track tasks), not by this mailbox.
// * A dedicated drain thread dispatches at most `maximumActive` entries as
//   cooperative Tasks; results flow back ONLY through the effect pump / run
//   event channels. Kotlin never holds a Swift continuation.
//
// All mutable state is guarded by one NSCondition; continuations here are
// mailbox-internal Task closures resumed outside the lock. This source is
// NOT compiled/executed by the authoring package.
import Foundation
import FloeCore

// MARK: - Job and processor types

/// One validated v3 command (or one internal trusted-host lifecycle job).
/// `scope == nil` marks an internal host job which cannot be reached through
/// the BridgeV3 binder (v3 routes only closed scope+command handler keys).
public struct RuntimeCommandEnvelopeJob: Sendable {
    public let correlationID: String
    public let handlerKey: String
    public let command: String
    public let scope: BridgeV3.Scope?
    public let configurationScope: String?
    public let receipt: String
    public let envelope: Data

    public init(correlationID: String, handlerKey: String, command: String,
                scope: BridgeV3.Scope?, configurationScope: String?,
                receipt: String, envelope: Data) {
        self.correlationID = correlationID
        self.handlerKey = handlerKey
        self.command = command
        self.scope = scope
        self.configurationScope = configurationScope
        self.receipt = receipt
        self.envelope = envelope
    }

    public var isInternalHostJob: Bool { scope == nil }
}

/// Typed async outcome of one command operation. Carried back to the effect
/// pump as exactly one terminal `RuntimeEffectItem`.
///
/// Carrier integration (Main decision 2026-10-19): domain processors may
/// attach the completed typed page/value result to an outcome via `payload`
/// — an optional closed discriminated JSON document. `detail` stays
/// identifier-only per the frozen contract; page content is NEVER serialized
/// into strings. Settlement appends the payload atomically or, if it cannot
/// fit the ACTUAL effect frame, settles a small typed
/// `failed(frameBudgetExceeded)` recovery terminal instead (never a silent
/// drop, never a partial item).
public struct RuntimeCommandResult: Sendable {
    public let kind: RuntimeEffectItem.Kind
    public let code: RuntimeFacadeCode?
    public let detail: [String: String]?
    /// Optional typed completed value/result OBJECT document (JSON object).
    public let value: DesignJSONValue?
    /// Optional typed page OBJECT document (e.g. a completed bounded read).
    public let page: DesignJSONValue?

    public init(kind: RuntimeEffectItem.Kind, code: RuntimeFacadeCode? = nil,
                detail: [String: String]? = nil,
                value: DesignJSONValue? = nil,
                page: DesignJSONValue? = nil) {
        self.kind = kind
        self.code = code
        self.detail = detail
        self.value = value
        self.page = page
    }

    public static func accepted(detail: [String: String]? = nil) -> RuntimeCommandResult {
        RuntimeCommandResult(kind: .accepted, detail: detail)
    }
    public static func accepted(detail: [String: String]? = nil,
                                value: DesignJSONValue) -> RuntimeCommandResult {
        RuntimeCommandResult(kind: .accepted, detail: detail, value: value)
    }
    public static func accepted(detail: [String: String]? = nil,
                                page: DesignJSONValue) -> RuntimeCommandResult {
        RuntimeCommandResult(kind: .accepted, detail: detail, page: page)
    }
    public static func rejected(_ code: RuntimeFacadeCode) -> RuntimeCommandResult {
        RuntimeCommandResult(kind: .rejected, code: code)
    }
    public static func failed(_ code: RuntimeFacadeCode) -> RuntimeCommandResult {
        RuntimeCommandResult(kind: .failed, code: code)
    }
    public static func failed(_ code: RuntimeFacadeCode,
                              detail: [String: String]?) -> RuntimeCommandResult {
        RuntimeCommandResult(kind: .failed, code: code, detail: detail)
    }
    public static var cancelled: RuntimeCommandResult {
        RuntimeCommandResult(kind: .cancelled, code: nil)
    }
}

/// One bounded async processor for one handler key. Processors run as
/// cooperative Tasks OUTSIDE the mailbox lock and MUST NOT block on it.
/// Host code registers these during bootstrap; model/tool/web data can never
/// register or replace a processor.
public struct RuntimeAsyncProcessor: Sendable {
    public let execute: @Sendable (RuntimeCommandEnvelopeJob) async -> RuntimeCommandResult

    public init(execute: @escaping @Sendable (RuntimeCommandEnvelopeJob) async -> RuntimeCommandResult) {
        self.execute = execute
    }
}

/// Lock-guarded handlerKey -> processor map. Empty at the wire stage; the
/// RB1 bootstrap registers EXACTLY the closed bootstrap set. Later RB
/// packages add their own keys — the fail-closed path for every unregistered
/// key is unchanged (`domainNotBound` / binder-level `runtimeUnavailable`).
public final class RuntimeDomainRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var processors: [String: RuntimeAsyncProcessor] = [:]
    /// Carrier integration (Main decision 2026-10-19): a SHARED binder key
    /// such as applicationConfiguration/content.read is owned by several
    /// domains distinguished by the frozen `configurationScope` label.
    /// Scoped registrations compose per label and never overwrite a sibling;
    /// an unregistered label on a key that HAS scoped owners fails closed.
    private var scopedProcessors: [String: [String: RuntimeAsyncProcessor]] = [:]

    public init() {}

    public func register(handlerKey: String, processor: RuntimeAsyncProcessor) {
        lock.lock(); processors[handlerKey] = processor; lock.unlock()
    }

    /// Register one CONFIGURATION-SCOPE owner under a shared handler key.
    /// The same label may be replaced by its own owner; sibling labels are
    /// untouched, so the last registration can never steal another domain's
    /// read (no last-register-wins).
    public func register(handlerKey: String, configurationScope: String,
                         processor: RuntimeAsyncProcessor) {
        guard !configurationScope.isEmpty else { return }
        lock.lock()
        var scopes = scopedProcessors[handlerKey] ?? [:]
        scopes[configurationScope] = processor
        scopedProcessors[handlerKey] = scopes
        lock.unlock()
    }

    @discardableResult
    public func unregister(handlerKey: String) -> Bool {
        lock.lock()
        let existed = processors.removeValue(forKey: handlerKey) != nil
            || scopedProcessors.removeValue(forKey: handlerKey) != nil
        lock.unlock(); return existed
    }

    @discardableResult
    public func unregister(handlerKey: String, configurationScope: String) -> Bool {
        lock.lock()
        var existed = false
        if var scopes = scopedProcessors[handlerKey] {
            existed = scopes.removeValue(forKey: configurationScope) != nil
            scopedProcessors[handlerKey] = scopes.isEmpty ? nil : scopes
        }
        lock.unlock(); return existed
    }

    public func processor(for handlerKey: String) -> RuntimeAsyncProcessor? {
        lock.lock(); defer { lock.unlock() }
        return processors[handlerKey]
    }

    /// Dispatch for one job. A key with scoped owners dispatches ONLY on the
    /// exact closed `configurationScope` (nil/mismatched label => fail
    /// closed); keys without scoped owners keep the plain single-handler
    /// semantics (system.* lifecycle keys).
    public func processor(for handlerKey: String,
                          configurationScope: String?) -> RuntimeAsyncProcessor? {
        lock.lock()
        let scopes = scopedProcessors[handlerKey]
        let plain = processors[handlerKey]
        lock.unlock()
        if let scopes, !scopes.isEmpty {
            guard let configurationScope, let scoped = scopes[configurationScope] else {
                return nil
            }
            return scoped
        }
        return plain
    }

    public var boundHandlerKeys: [String] {
        lock.lock(); defer { lock.unlock() }
        return Set(processors.keys).union(scopedProcessors.keys).sorted()
    }

    /// Sorted `handlerKey#configurationScope` view for diagnostics/tests.
    public var boundScopedKeys: [String] {
        lock.lock(); defer { lock.unlock() }
        return scopedProcessors.flatMap { key, scopes in
            scopes.keys.map { "\(key)#\($0)" }
        }.sorted()
    }
}

// MARK: - Mailbox

public enum FacadeMailboxSubmit: Sendable, Equatable {
    case queued(receipt: String)
    case duplicate(receipt: String)
    case rejected(RuntimeFacadeCode)
}

public final class FacadeCommandMailbox: @unchecked Sendable {

    public enum Limits {
        public static let maximumQueued = 64
        public static let maximumActive = 16
        /// Explicit queued-envelope byte bound (host baseline): 64 queued
        /// envelopes may not exceed 1 MiB in aggregate.
        public static let maximumQueuedEnvelopeBytes = 1_048_576
        /// Frozen per-envelope bound (shared with v1/v2/v3 exchange).
        public static let maximumEnvelopeBytes = 65_536
        /// Retirement bookkeeping ring for exact-once late-settlement
        /// classification (mirrors the gateway mailbox precedent).
        public static let maximumRetired = 128
    }

    private enum EntryState: UInt8 {
        case queued
        case active
        case callerSettledOutstanding   // closed/replaced while executing
        case terminal
    }

    private final class Entry: @unchecked Sendable {
        let token: Int64
        let job: RuntimeCommandEnvelopeJob
        var state: EntryState = .queued
        var task: Task<Void, Never>?
        var cancelRequested = false
        var countedBytes: Int

        init(token: Int64, job: RuntimeCommandEnvelopeJob) {
            self.token = token
            self.job = job
            self.countedBytes = job.envelope.count
        }
    }

    private struct Counters {
        var saturated = 0
        var tooLarge = 0
        var duplicates = 0
        var droppedCancelled = 0
        var settledRejected = 0
        var settledTerminal = 0
        var lateSettleOutstanding = 0
        var replaced = 0
        var noProcessor = 0
        var tokenExhausted = 0
        /// Carrier integration: typed results that could not be delivered
        /// atomically within the ACTUAL effect frame and settled the small
        /// `failed(frameBudgetExceeded)` recovery terminal instead.
        var payloadTooLarge = 0
    }

    private let condition = NSCondition()
    private let effects: FacadeEffectPump
    private let registry: RuntimeDomainRegistry
    private var queue: [Int64] = []
    private var entries: [Int64: Entry] = [:]
    private var byCorrelation: [String: Int64] = [:]
    private var retired: [Int64: Bool] = [:]   // token -> wasTerminalSettled
    private var retiredOrder: [Int64] = []
    private var nextToken: Int64 = 1
    private var activeCount = 0
    private var queuedBytes = 0
    private var closed = false
    /// False while draining: new submissions are refused, but ALREADY QUEUED
    /// work keeps executing — shutdown is a drain, not a discard.
    private var accepting = true
    private var closeReason: RuntimeEffectItem.Kind = .closed
    private var counters = Counters()
    private var drainThread: Thread?
    private var drainRunning = false
    /// RB1-R1/R3: internal one-shot-ish settlement observer. The bootstrap
    /// owner uses it to copy a retired generation's already-terminal streams
    /// into the process-level read-only receipt route after the real close.
    /// It is called OUTSIDE this mailbox's lock and never stores user data.
    private var terminalObserver: (@Sendable (String, String, RuntimeEffectItem.Kind) -> Void)?

    public init(effects: FacadeEffectPump, registry: RuntimeDomainRegistry) {
        self.effects = effects
        self.registry = registry
    }

    // MARK: Lifecycle

    /// Start the single bounded drain worker. Called once per generation by
    /// the bootstrap owner AFTER the internal processors are registered.
    public func startDrain() {
        condition.lock()
        guard !drainRunning, !closed else { condition.unlock(); return }
        drainRunning = true
        let thread = Thread { [weak self] in self?.runDrainLoop() }
        thread.name = "floe-runtime-mailbox-drain"
        drainThread = thread
        condition.broadcast()
        condition.unlock()
        thread.start()
    }

    /// Stop accepting NEW submissions while already-queued work continues to
    /// drain. The internal shutdown processor calls this BEFORE waiting for
    /// the full drain: shutdown is a drain, never a discard.
    public func beginDraining() {
        condition.lock()
        accepting = false
        condition.broadcast()
        condition.unlock()
    }

    /// Retire the mailbox for a FAILED/replaced generation. Queued entries
    /// settle exactly once with `replaced`/`closed`; ACTIVE entries have
    /// their caller settled exactly once while their slot and accounting stay
    /// until the real completion arrives (late-settlement classification
    /// below). Never waits on an actor or SQLite.
    public func close(reason: RuntimeEffectItem.Kind) {
        condition.lock()
        guard !closed else { condition.unlock(); return }
        closed = true
        accepting = false
        closeReason = reason
        for token in queue {
            guard let entry = entries[token], entry.state == .queued else { continue }
            finishLocked(entry, terminal: true)
            effects.append(receipt: entry.job.receipt, kind: reason,
                           code: reason == .cancelled ? nil : .mailboxClosed)
            counters.droppedCancelled += 1
        }
        for entry in entries.values where entry.state == .active {
            // Caller settled once here; the Task slot remains until its real
            // completion classifies as lateSettleOutstanding.
            entry.state = .callerSettledOutstanding
            effects.append(receipt: entry.job.receipt, kind: reason,
                           code: .mailboxClosed)
            counters.replaced += reason == .replaced ? 1 : 0
            byCorrelation[entry.job.correlationID] = nil
        }
        queue.removeAll()
        // Every correlation in this generation is settled exactly once (or
        // outstanding without a live caller); dedupe state must not outlive
        // the generation.
        byCorrelation.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    /// Host-visible drain checkpoint: true when the queue is empty AND every
    /// executing entry reached its real completion. NO timers: outstanding
    /// executing work is retained until it actually finishes.
    public func isFullyDrained() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return queue.isEmpty && activeCount == 0
            && !entries.values.contains { $0.state == .callerSettledOutstanding }
    }

    /// Monotonic bounded wait used by lifecycle checks that hold NO slot.
    /// Polls the drained predicate with cooperative suspension; it never
    /// parks a cooperative thread on a semaphore. `DispatchTime` is
    /// monotonic, so wall-clock changes cannot extend or shorten the bound.
    public func waitForFullDrain(timeoutMillis: Int) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(max(0, timeoutMillis)) &* 1_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if isFullyDrained() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
            if Task.isCancelled { return isFullyDrained() }
        }
        return isFullyDrained()
    }

    /// RB1-M3: the shutdown CONTROL job runs AS the last entry, so it waits
    /// for everything ELSE to settle while ignoring exactly its own slot.
    /// No other active or caller-settled-outstanding entry may remain before
    /// the database close may begin.
    public func isIdleIgnoringSelf(correlation: String) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard queue.isEmpty else { return false }
        for entry in entries.values {
            guard entry.job.correlationID != correlation else { continue }
            if entry.state == .active || entry.state == .callerSettledOutstanding {
                return false
            }
        }
        return true
    }

    public func waitForIdleIgnoringSelf(correlation: String,
                                        timeoutMillis: Int) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(max(0, timeoutMillis)) &* 1_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if isIdleIgnoringSelf(correlation: correlation) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
            if Task.isCancelled {
                return isIdleIgnoringSelf(correlation: correlation)
            }
        }
        return isIdleIgnoringSelf(correlation: correlation)
    }

    /// Internal settlement observer for lifecycle bookkeeping. The callback
    /// runs after the mailbox lock is released; it must be non-blocking and
    /// must not call back into this mailbox. Production installs one for the
    /// generation's control/anchor receipt; tests may install their own.
    public func setTerminalObserver(
        _ observer: (@Sendable (String, String, RuntimeEffectItem.Kind) -> Void)?
    ) {
        condition.lock()
        terminalObserver = observer
        condition.unlock()
    }

    /// Submit for the bootstrap's OWN lifecycle control job only (the failed-
    /// bootstrap retire and the shutdown retry path). Bypasses the admission
    /// fence but not the closed check or the bounds; correlation-based dedupe
    /// still applies. Production command traffic NEVER uses this path.
    public func submitControl(_ job: RuntimeCommandEnvelopeJob) -> FacadeMailboxSubmit {
        guard job.envelope.count <= Limits.maximumEnvelopeBytes else {
            return .rejected(.envelopeTooLarge)
        }
        condition.lock()
        if closed {
            condition.unlock()
            settleSubmitRejection(job, .mailboxClosed)
            return .rejected(.mailboxClosed)
        }
        if let existing = byCorrelation[job.correlationID],
           let entry = entries[existing],
           entry.state == .queued || entry.state == .active {
            let receipt = entry.job.receipt
            counters.duplicates += 1
            condition.unlock()
            effects.append(receipt: job.receipt, kind: .rejected,
                           code: .duplicateCorrelation)
            return .duplicate(receipt: receipt)
        }
        if queue.count >= Limits.maximumQueued
                || queuedBytes + job.envelope.count > Limits.maximumQueuedEnvelopeBytes {
            counters.saturated += 1
            condition.unlock()
            settleSubmitRejection(job, .mailboxSaturated)
            return .rejected(.mailboxSaturated)
        }
        let token = allocateTokenLocked()
        guard token != 0 else {
            condition.unlock()
            settleSubmitRejection(job, .internal)
            return .rejected(.internal)
        }
        let entry = Entry(token: token, job: job)
        entries[token] = entry
        byCorrelation[job.correlationID] = token
        queue.append(token)
        queuedBytes += entry.countedBytes
        condition.broadcast()
        condition.unlock()
        return .queued(receipt: job.receipt)
    }

    private func allocateTokenLocked() -> Int64 {
        if nextToken == Int64.max { counters.tokenExhausted += 1; return 0 }
        let token = nextToken
        nextToken += 1
        return token
    }

    /// RB1-M3/RB1-M4: retire the queue AFTER the real drain without touching
    /// the shutdown CONTROL entry (identified by correlation). Remaining
    /// queued entries (defensive: there should be none) settle exactly once;
    /// any OTHER active entry is caller-settled with `closed` while its slot
    /// remains until its real completion. The excluded control entry stays
    /// fully active and settles its single readable terminal AFTER the actual
    /// database close. Never waits on an actor or SQLite.
    public func retireAfterDrain(excludingCorrelation: String?) {
        condition.lock()
        guard !closed else { condition.unlock(); return }
        accepting = false
        for token in queue {
            guard let entry = entries[token], entry.state == .queued else { continue }
            finishLocked(entry, terminal: true)
            effects.append(receipt: entry.job.receipt, kind: .closed,
                           code: .mailboxClosed)
            counters.droppedCancelled += 1
        }
        queue.removeAll()
        for entry in entries.values where entry.state == .active {
            if let excluding = excludingCorrelation,
               entry.job.correlationID == excluding {
                continue   // the live control job settles its own terminal
            }
            entry.state = .callerSettledOutstanding
            effects.append(receipt: entry.job.receipt, kind: .closed,
                           code: .mailboxClosed)
            byCorrelation[entry.job.correlationID] = nil
        }
        closed = true
        byCorrelation.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    // MARK: Submit (synchronous; JNI/binder safe)

    /// Validate + enqueue bounded work and return promptly. The receipt was
    /// already registered by the caller through the effect pump; a rejection
    /// settles it with a typed terminal `rejected` effect so no stream can
    /// leak, and the response JSON carries no receipt.
    public func submit(_ job: RuntimeCommandEnvelopeJob) -> FacadeMailboxSubmit {
        guard job.envelope.count <= Limits.maximumEnvelopeBytes else {
            settleSubmitRejection(job, .envelopeTooLarge)
            condition.lock(); counters.tooLarge += 1; condition.unlock()
            return .rejected(.envelopeTooLarge)
        }
        condition.lock()
        if closed {
            condition.unlock()
            settleSubmitRejection(job, .mailboxClosed)
            return .rejected(.mailboxClosed)
        }
        if !accepting {
            condition.unlock()
            settleSubmitRejection(job, .alreadyDraining)
            return .rejected(.alreadyDraining)
        }
        if let existing = byCorrelation[job.correlationID],
           let entry = entries[existing],
           entry.state == .queued || entry.state == .active {
            let receipt = entry.job.receipt
            counters.duplicates += 1
            condition.unlock()
            // The duplicate's own pre-registered stream is terminalised with
            // the dedupe code so the caller can see why nothing ran twice.
            effects.append(receipt: job.receipt, kind: .rejected, code: .duplicateCorrelation)
            return .duplicate(receipt: receipt)
        }
        if nextToken == Int64.max {
            counters.tokenExhausted += 1
            condition.unlock()
            settleSubmitRejection(job, .internal)
            return .rejected(.internal)
        }
        if queue.count >= Limits.maximumQueued
                || queuedBytes + job.envelope.count > Limits.maximumQueuedEnvelopeBytes {
            counters.saturated += 1
            condition.unlock()
            settleSubmitRejection(job, .mailboxSaturated)
            return .rejected(.mailboxSaturated)
        }
        let token = nextToken
        nextToken += 1
        let entry = Entry(token: token, job: job)
        entries[token] = entry
        byCorrelation[job.correlationID] = token
        queue.append(token)
        queuedBytes += entry.countedBytes
        condition.broadcast()
        condition.unlock()
        return .queued(receipt: job.receipt)
    }

    private func settleSubmitRejection(_ job: RuntimeCommandEnvelopeJob,
                                       _ code: RuntimeFacadeCode) {
        effects.append(receipt: job.receipt, kind: .rejected, code: code)
        condition.lock(); counters.settledRejected += 1; condition.unlock()
    }

    // MARK: Cancellation

    /// Cancel by correlation. A queued entry is removed with provable
    /// no-effect (`cancelled` effect exactly once). An ACTIVE entry is only
    /// flagged + its Task cancelled; the slot and accounting live until the
    /// real completion settles.
    @discardableResult
    public func cancel(correlationID: String) -> Bool {
        var removed = false
        condition.lock()
        if let token = byCorrelation[correlationID], let entry = entries[token] {
            switch entry.state {
            case .queued:
                if let index = queue.firstIndex(of: token) { queue.remove(at: index) }
                queuedBytes -= entry.countedBytes
                if queuedBytes < 0 { queuedBytes = 0 }
                finishLocked(entry, terminal: true)
                effects.append(receipt: entry.job.receipt, kind: .cancelled)
                byCorrelation[correlationID] = nil
                counters.droppedCancelled += 1
                removed = true
            case .active:
                entry.cancelRequested = true
                entry.task?.cancel()
                removed = false   // requested, not proven-cancelled
            case .callerSettledOutstanding, .terminal:
                removed = false
            }
        }
        condition.broadcast()
        condition.unlock()
        return removed
    }

    // MARK: Drain loop (dedicated thread)

    private func runDrainLoop() {
        condition.lock()
        while true {
            if drainStopRequestedLocked() { break }
            // Claim while under capacity.
            var claimed: [Entry] = []
            while activeCount < Limits.maximumActive, !queue.isEmpty {
                let token = queue.removeFirst()
                guard let entry = entries[token], entry.state == .queued else { continue }
                queuedBytes -= entry.countedBytes
                if queuedBytes < 0 { queuedBytes = 0 }
                entry.state = .active
                activeCount += 1
                claimed.append(entry)
            }
            if claimed.isEmpty {
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
                continue
            }
            condition.unlock()
            for entry in claimed { dispatch(entry) }
            condition.lock()
        }
        drainRunning = false
        condition.broadcast()
        condition.unlock()
    }

    private func drainStopRequestedLocked() -> Bool {
        if closed && queue.isEmpty { return true }
        return false
    }

    private func dispatch(_ entry: Entry) {
        let token = entry.token
        guard let processor = registry.processor(for: entry.job.handlerKey,
                                                 configurationScope: entry.job.configurationScope) else {
            condition.lock()
            activeCount = max(0, activeCount - 1)
            finishLocked(entry, terminal: true)
            effects.append(receipt: entry.job.receipt, kind: .failed, code: .domainNotBound)
            counters.noProcessor += 1
            condition.broadcast()
            condition.unlock()
            return
        }
        let job = entry.job
        // STRONG self for the settlement hop: the owning generation releases
        // the mailbox at retirement (`generation = nil`) BEFORE this Task
        // resumes with its terminal, so a weak capture could silently drop
        // the one readable terminal of a shutdown control (RB1-R1/R4). The
        // entry/task cycle is broken by `settle` (entry.task = nil and the
        // entry is removed), so this is a bounded, intentional retention.
        let task = Task(priority: .medium) { [self] in
            let result = await processor.execute(job)
            settle(token: token, result: result)
        }
        entry.task = task
    }

    // MARK: Settlement (exactly once)

    /// The single terminal settlement path for a claimed entry. A late
    /// settlement after close/replacement is classified `lateSettle` (its
    /// effect stream is already terminal) while the slot is released only
    /// HERE — never by a timer.
    public func settle(token: Int64, result: RuntimeCommandResult) {
        var notification: (String, String, RuntimeEffectItem.Kind)?
        var observer: (@Sendable (String, String, RuntimeEffectItem.Kind) -> Void)?
        condition.lock()
        guard let entry = entries[token] else {
            if retired[token] == nil {
                retired[token] = false
                retiredOrder.append(token)
                while retiredOrder.count > Limits.maximumRetired {
                    retired.removeValue(forKey: retiredOrder.removeFirst())
                }
            }
            condition.unlock()
            return
        }
        switch entry.state {
        case .active:
            entry.task = nil
            activeCount = max(0, activeCount - 1)
            finishLocked(entry, terminal: true)
            var kind = result.kind
            if entry.cancelRequested, kind == .failed, result.code == .internal {
                kind = .cancelled
            }
            var settledKind = kind
            let outcome = effects.append(receipt: entry.job.receipt, kind: kind,
                                         code: result.code, detail: result.detail,
                                         page: result.page, value: result.value)
            if case .refused(.payloadTooLarge) = outcome {
                // Carrier integration: an atomic result that cannot fit the
                // ACTUAL effect frame settles a small typed recoverable
                // terminal (the domain re-stages through content reader
                // handles / durable pages). Nothing half-stored, nothing
                // silently dropped.
                counters.payloadTooLarge += 1
                effects.append(receipt: entry.job.receipt, kind: .failed,
                               code: .frameBudgetExceeded,
                               detail: ["carrier": "payloadTooLarge",
                                        "originalKind": kind.rawValue])
                settledKind = .failed
            }
            byCorrelation[entry.job.correlationID] = nil
            counters.settledTerminal += 1
            notification = (entry.job.correlationID, entry.job.receipt, settledKind)
        case .callerSettledOutstanding:
            // The caller was already settled at close/replacement. The real
            // completion releases the slot exactly here (never by a timer)
            // and is classified WITHOUT double-settling the stream.
            entry.task = nil
            activeCount = max(0, activeCount - 1)
            counters.lateSettleOutstanding += 1
            entries.removeValue(forKey: token)
            addRetiredLocked(token)
        case .queued, .terminal:
            counters.lateSettleOutstanding += 1
        }
        observer = terminalObserver
        condition.broadcast()
        condition.unlock()
        if let notification, let observer {
            observer(notification.0, notification.1, notification.2)
        }
    }

    private func finishLocked(_ entry: Entry, terminal: Bool) {
        entry.state = terminal ? .terminal : .callerSettledOutstanding
        if entry.state == .terminal {
            entries.removeValue(forKey: entry.token)
            addRetiredLocked(entry.token)
        }
    }

    private func addRetiredLocked(_ token: Int64) {
        retired[token] = true
        retiredOrder.append(token)
        while retiredOrder.count > Limits.maximumRetired {
            retired.removeValue(forKey: retiredOrder.removeFirst())
        }
    }

    // MARK: Diagnostics (typed counters only; never envelope content)

    public func statsJSON() -> String {
        condition.lock()
        let object: [String: Any] = [
            "queued": queue.count,
            "active": activeCount,
            "queuedEnvelopeBytes": max(0, queuedBytes),
            "closed": closed,
            "drainRunning": drainRunning,
            "counters": [
                "saturated": counters.saturated,
                "tooLarge": counters.tooLarge,
                "duplicates": counters.duplicates,
                "droppedCancelled": counters.droppedCancelled,
                "settledRejected": counters.settledRejected,
                "settledTerminal": counters.settledTerminal,
                "lateSettleOutstanding": counters.lateSettleOutstanding,
                "replaced": counters.replaced,
                "noProcessor": counters.noProcessor,
                "tokenExhausted": counters.tokenExhausted,
            ],
        ]
        condition.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"stats_encoding\"}"
        }
        return string
    }

    /// True when new command admissions are fenced (draining or closed).
    /// The binder handler checks this BEFORE minting a receipt so refused
    /// work cannot leak receipt streams.
    public var isAdmissionFenced: Bool {
        condition.lock()
        defer { condition.unlock() }
        return closed || !accepting
    }

    /// True when the mailbox has been fully retired.
    public var isClosedForCommandAdmission: Bool {
        condition.lock()
        defer { condition.unlock() }
        return closed
    }

    /// Live correlation->receipt view for the binder dedupe response path.
    public func liveReceipt(correlationID: String) -> String? {
        condition.lock(); defer { condition.unlock() }
        guard closed == false,
              let token = byCorrelation[correlationID],
              let entry = entries[token],
              entry.state == .queued || entry.state == .active else { return nil }
        return entry.job.receipt
    }

    // MARK: Test observation (contracts, not internals: counts only)

    internal func snapshotCountsForTesting() -> (queued: Int, active: Int, bytes: Int) {
        condition.lock()
        defer { condition.unlock() }
        return (queue.count, activeCount, max(0, queuedBytes))
    }
}
