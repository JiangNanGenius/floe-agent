// SPDX-License-Identifier: MPL-2.0
//
// RB-1 runtime bootstrap — run-bound projection pump foundations
// (`floe.event-cursor/3`).
//
// Honesty rules (RB1 handoff + contract eventPump):
// * The DURABLE channel is the original append-only `RunStore.events`
//   (per-run monotonic sequence): correctness is durable pages + snapshot
//   re-read, NEVER a fabricated complete live sequence. Upstream channels do
//   not provide a complete unsequenced event stream.
// * The LIVE channel mirrors the original `HarnessEventChannel`
//   bufferingNewest(512) semantics: `HarnessEvent` carries NO sequence, so
//   live drops are possible and undetectable — correctness never depends on
//   it. Priority frames (approvalRequested / approvalResolved / terminal /
//   childRunChanged / stateChanged) are never silently dropped: priority
//   saturation DETACHES the consumer with explicit `resyncRequired` and the
//   underlying business run is NEVER cancelled. Droppable delta frames saturate
//   into `resyncRequired` + watermark.
// * Route/session epochs fence late callbacks: a consumer re-attaches at
//   generation+1; an old generation cannot mutate a newer projection.
// * Frame budget: pages carry <= 48 KiB of ACTUAL serialized UTF-8
//   (escape-aware) items inside the frozen 64 KiB envelope headroom; oversized
//   single items go through `FacadeContentReader` chunk handles or durable
//   pages, never silent truncation. Binary attachments/keys never JSON.
// * Activity/rotation/background is NOT consumer teardown; only explicit
//   detach/epoch teardown removes a live consumer.
//
// Synchronous JNI/binder threads use only the lock-guarded read/ingest paths.
// The durable-window REFRESH is the async side and runs on the cooperative
// pool (RB4 per-run track tasks will drive it; tests drive it directly).
// This source is NOT compiled/executed by the authoring package.
import Foundation
import FloeAgentRuntime
import FloePersistence
import FloeModels

/// Compact projection of one original `RunEventRecord` (no row content
/// leaves the store beyond the payload JSON already stored non-secret).
public struct RuntimeDurableEvent: Sendable, Equatable {
    public let runID: UUID
    public let sequence: Int
    public let kind: String
    public let payloadJSON: String
    public let createdAtEpochMillis: Int64

    public init(_ record: RunEventRecord) {
        self.runID = record.runID
        self.sequence = record.sequence
        self.kind = record.kind.rawValue
        self.payloadJSON = record.payloadJSON
        self.createdAtEpochMillis = Int64(record.createdAt.timeIntervalSince1970 * 1000)
    }

    public var jsonObject: [String: Any] {
        ["sequence": sequence, "kind": kind,
         "createdAt": createdAtEpochMillis, "payload": payloadJSON]
    }
}

// MARK: - Live consumer

/// One bounded live projection consumer for one run at one route epoch.
public struct RuntimeLiveConsumerToken: Sendable, Hashable {
    public let runID: UUID
    public let epoch: UInt64
    public init(runID: UUID, epoch: UInt64) {
        self.runID = runID
        self.epoch = epoch
    }
}

public enum RuntimeLiveIngestOutcome: Sendable, Equatable {
    case enqueued
    case droppedDeltas(resyncRequired: Bool)
    case detached
    case fencedByEpoch
    case noConsumer
}

private final class LiveConsumerState: @unchecked Sendable {
    struct Frame: Sendable {
        let liveSeq: Int
        let priority: Bool
        let payloadJSON: String
        var bytes: Int
    }
    let token: RuntimeLiveConsumerToken
    var frames: [Frame] = []
    var nextLiveSeq = 1
    var retainedBytes = 0
    var droppedDeltaCount = 0
    var resyncRequired = false
    var detached = false
    init(token: RuntimeLiveConsumerToken) { self.token = token }
}

// MARK: - Pump

public final class FacadeEventPump: @unchecked Sendable {

    public enum Limits {
        /// Original durable page limit (RunStore.events afterSequence:limit).
        public static let durablePageSize = 200
        /// In-memory sliding durable window per attached run.
        public static let maximumWindowEvents = 400
        /// Live ring caps mirrored from the original channel semantics.
        public static let liveRingEvents = 512
        public static let liveRingBytes = 262_144
        /// Priority sub-queue cap: saturation DETACHES (never drops).
        public static let priorityRingEvents = 128
        /// Bounded number of attached runs with live consumers.
        public static let maximumConsumers = 32
        /// Bounded attached durable windows.
        public static let maximumWindows = 32
    }

    /// Closed priority classification (contract eventPump.live.priority):
    /// approval/terminal/child/state frames are never dropped; deltas and
    /// liveness/usage frames are droppable with explicit resync.
    static func isPriority(_ event: HarnessEvent) -> Bool {
        switch event {
        case .approvalRequested, .approvalResolved, .terminal,
             .childRunChanged, .stateChanged:
            return true
        default:
            return false
        }
    }

    public enum DurableWindowStatus: String, Sendable {
        case attached
        case notAttached        // honestly: no window exists for this run yet
        case runGone            // attached and the durable owner is gone
    }

    /// Typed outcome of one durable-window refresh (C09 QREV-03b).
    /// `refreshed` carries the window watermark AFTER the merged page so a
    /// progress-driven materializer can tell a valid multi-page backlog
    /// apart from an IO anomaly; `failedRead` is the honest typed failure
    /// of the store read (previously a silent return). The result is
    /// internal Swift only — no wire member changed; the existing
    /// `@discardableResult` keeps every production track-task and existing
    /// pump test call site source-compatible.
    public enum DurableWindowRefreshOutcome: Sendable, Equatable {
        case refreshed(watermark: Int)
        case failedRead
    }

    public struct DurableWindowSnapshot: Sendable {
        public let runID: UUID
        public let status: DurableWindowStatus
        public let firstSequence: Int?
        public let watermark: Int
        public let events: [RuntimeDurableEvent]
    }

    private final class Window: @unchecked Sendable {
        let runID: UUID
        var events: [RuntimeDurableEvent] = []
        var watermark: Int = 0
        var runExists = true
        init(runID: UUID) { self.runID = runID }
    }

    private let lock = NSLock()
    private var windows: [UUID: Window] = [:]
    private var windowOrder: [UUID] = []
    private var consumers: [UUID: [LiveConsumerState]] = [:]   // runID -> per epoch
    private var effectSequences: [UUID: UInt64] = [:]          // per-run live epoch

    // MARK: Settle-publication degraded state (C09 QREV-03b / MAIN_ADDENDUM E)

    /// runID → the settle-fact sequence the window could NOT be verified
    /// against the journal (-1 = the append itself failed, so no sequence
    /// can be proven). Insertion-ordered and bounded by
    /// `Limits.maximumWindows`; internal Swift only — the signal rides the
    /// EXISTING frozen `resyncRequired` durable member, never a new schema.
    private var settleDegraded: [UUID: Int] = [:]
    private var settleDegradedOrder: [UUID] = []
    /// MAIN_ADDENDUM E: an overflow must never silently drop an unresolved
    /// target's sole recovery signal. Evicting an unresolved entry therefore
    /// latches a conservative pump-wide resync (bounded: one Bool) forcing
    /// `resyncRequired` on every subsequent durable poll until the pump /
    /// root generation resets. Consumers treat it as the existing once-per-
    /// watch authoritative reconcile — repairing from real pages is
    /// idempotent, so over-signal degrades cost, never correctness.
    private var settleOverflowResyncLatched = false

    public init() {}

    /// R7: synchronous lock helper. Async production entry points use this
    /// and never call `NSLock.lock()/unlock()` directly from an async context
    /// and never hold the lock across an await.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: Durable window refresh (async side)

    /// Reads ONE real append-only page through the RUN'S OWN store API and
    /// materializes it into the bounded window. Called by per-run track tasks
    /// (RB4) and by this package's tests; never from a synchronous binder.
    ///
    /// The store is the run's OWN persistence bundle: the ordinary SQLite
    /// store, or the temporary session's ORIGINAL `EphemeralRunStore` (whose
    /// per-run sequences are monotonic exactly like the SQLite counter).
    /// The pump contract (monotonic sequence, bounded window, explicit
    /// notAttached/runGone) is identical; no store is synthesized and the
    /// durable singleton is never substituted for a temporary run.
    @discardableResult
    public func refreshDurableWindow(runID: UUID, store: any RunStore) async
        -> DurableWindowRefreshOutcome {
        let page: [RunEventRecord]
        let run: RunRecord?
        do {
            let after = withLock { windows[runID]?.watermark ?? 0 }
            run = try await store.run(id: runID)
            page = try await store.events(runID: runID, afterSequence: after,
                                          limit: Limits.durablePageSize)
        } catch {
            // C09 QREV-03b: the failure is TYPED, never a silent return. The
            // queue-settle materializer distinguishes an IO failure from a
            // valid multi-page backlog; every other caller ignores the
            // result exactly like the previous Void return.
            return .failedRead
        }
        let watermark = withLock {
            let window: Window
            if let existing = windows[runID] {
                window = existing
            } else {
                window = Window(runID: runID)
                windows[runID] = window
                windowOrder.append(runID)
                while windowOrder.count > Limits.maximumWindows {
                    windows.removeValue(forKey: windowOrder.removeFirst())
                }
            }
            window.runExists = run != nil
            for record in page {
                window.events.append(RuntimeDurableEvent(record))
                window.watermark = max(window.watermark, record.sequence)
            }
            // Overlapping refreshes can append out of order (the DB read is
            // async and completes unordered). The window contract IS
            // monotonic native sequence order, so restore it deterministically
            // and drop any duplicate sequence from an overlapped page.
            window.events.sort { $0.sequence < $1.sequence }
            var seenSequences = Set<Int>()
            window.events.removeAll { !seenSequences.insert($0.sequence).inserted }
            while window.events.count > Limits.maximumWindowEvents {
                window.events.removeFirst()
            }
            // Auto-heal: once the verified tail of a degraded publication has
            // really materialized into the window, the per-run resync forcing
            // is removed (an append-failure entry uses the -1 sentinel and is
            // only cleared explicitly when the fact re-lands on another
            // anchor; the pump-wide overflow latch, once set, stays until the
            // pump / root generation resets — MAIN_ADDENDUM E).
            if let expected = settleDegraded[runID], expected >= 0,
               window.watermark >= expected {
                settleDegraded.removeValue(forKey: runID)
                settleDegradedOrder.removeAll { $0 == runID }
            }
            return window.watermark
        }
        return .refreshed(watermark: watermark)
    }

    /// Mark one run's durable window as UNVERIFIABLE against the journal for
    /// a settle publication (append throw: `expectedSequence == nil`, or the
    /// fact committed but never materialized: its sequence). The next
    /// `pollDurable` of this run answers with the existing `resyncRequired`
    /// member so the consumer reconciles from authoritative pages. Bounded
    /// by `Limits.maximumWindows`; overflow latches a conservative pump-wide
    /// resync instead of silently losing an unresolved target's signal.
    public func markSettlePublicationDegraded(runID: UUID, expectedSequence: Int?) {
        lock.lock()
        defer { lock.unlock() }
        if settleDegraded[runID] == nil {
            settleDegradedOrder.append(runID)
        }
        settleDegraded[runID] = expectedSequence ?? -1
        while settleDegradedOrder.count > Limits.maximumWindows {
            let evicted = settleDegradedOrder.removeFirst()
            settleDegraded.removeValue(forKey: evicted)
            // MAIN_ADDENDUM E: the evicted entry was UNRESOLVED — keep its
            // recovery signal alive through the bounded latch.
            settleOverflowResyncLatched = true
        }
    }

    /// Clear one run's per-run degraded forcing (the verified tail
    /// materialized). Does not touch the overflow latch (bounded, pump-
    /// lifetime conservative signal by design).
    public func clearSettlePublicationDegraded(runID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        settleDegraded.removeValue(forKey: runID)
        settleDegradedOrder.removeAll { $0 == runID }
    }

    /// Verification/test accessor: this run's window carries an unresolved
    /// degraded settle publication (or the pump latched an overflow resync).
    public func isSettlePublicationDegraded(runID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return settleDegraded[runID] != nil || settleOverflowResyncLatched
    }

    /// Verification/test accessor for the MAIN_ADDENDUM E overflow latch.
    public var isSettleOverflowResyncLatched: Bool {
        lock.lock()
        defer { lock.unlock() }
        return settleOverflowResyncLatched
    }

    /// Directly attach a window (test seam for RB3/RB4 wiring and the
    /// deleted-owner path). Same bounded semantics as refresh.
    public func attachDurableWindow(runID: UUID, events: [RuntimeDurableEvent],
                                    runExists: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let window = windows[runID] ?? Window(runID: runID)
        if windows[runID] == nil {
            windows[runID] = window
            windowOrder.append(runID)
            while windowOrder.count > Limits.maximumWindows {
                windows.removeValue(forKey: windowOrder.removeFirst())
            }
        }
        window.events = events
        window.watermark = events.last?.sequence ?? 0
        window.runExists = runExists
    }

    /// Synchronous bounded page read for the event.poll binder handler.
    /// `afterSequence` must match the window start to be contiguous; if the
    /// window has moved past it, `resyncRequired` is returned explicitly and
    /// the caller walks from the window start (never a silent gap).
    public func pollDurable(runID: UUID, afterSequence: Int,
                           budgetBytes: Int) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        guard let window = windows[runID] else {
            // notAttached: a degraded settle publication for this run (or a
            // latched pump-wide overflow) still owes the consumer an
            // authoritative resync — the existing `resyncRequired` member
            // carries it; the window-state shape itself is unchanged.
            return ["windowState": DurableWindowStatus.notAttached.rawValue,
                    "events": [Any](), "hasMore": false,
                    "resyncRequired": settleDegraded[runID] != nil
                        || settleOverflowResyncLatched,
                    "nextSequence": afterSequence]
        }
        guard window.runExists else {
            return ["windowState": DurableWindowStatus.runGone.rawValue,
                    "events": [Any](), "hasMore": false,
                    "resyncRequired": true, "nextSequence": afterSequence]
        }
        let earliest = window.events.first?.sequence ?? 0
        var resync = false
        if afterSequence + 1 < earliest, !window.events.isEmpty {
            resync = true   // lagged behind the bounded window; explicit, not silent
        }
        // C09 QREV-03b: the window's durable tail could not be verified
        // against the journal for this run (degraded settle publication), or
        // the pump latched an overflow — the consumer must reconcile from
        // authoritative pages. Same existing wire member, no new schema.
        if settleDegraded[runID] != nil || settleOverflowResyncLatched {
            resync = true
        }
        let candidates = window.events.filter { $0.sequence > afterSequence }
        var included: [[String: Any]] = []
        var used = 0
        for event in candidates {
            let itemBytes = FacadeFrameBudget.serializedBytes(event.jsonObject)
            if used + itemBytes + 1 > budgetBytes { break }
            included.append(event.jsonObject)
            used += itemBytes + 1
        }
        let nextSequence = included.last.flatMap { ($0["sequence"] as? Int) } ?? afterSequence
        let hasMore = candidates.count > included.count
        return ["windowState": DurableWindowStatus.attached.rawValue,
                "events": included, "hasMore": hasMore,
                "resyncRequired": resync, "nextSequence": nextSequence,
                "watermark": window.watermark]
    }

    // MARK: Live consumers

    /// Attach (or re-attach) a live consumer for one run at a NEW route
    /// epoch. Rotation/background is never teardown; only `detach` is.
    @discardableResult
    public func attachConsumer(runID: UUID) -> RuntimeLiveConsumerToken {
        lock.lock()
        defer { lock.unlock() }
        var list = consumers[runID] ?? []
        // A re-attach fences every older generation: the old states STAY
        // (bounded) so late callbacks classify as detached instead of
        // silently vanishing into "noConsumer".
        for state in list { state.detached = true }
        while list.count >= 4 { list.removeFirst() }
        let epoch = (effectSequences[runID] ?? 0) + 1
        effectSequences[runID] = epoch
        let token = RuntimeLiveConsumerToken(runID: runID, epoch: epoch)
        list.append(LiveConsumerState(token: token))
        consumers[runID] = list
        // Bounded global footprint: only fully-fenced older runs may leave.
        var total = consumers.values.reduce(0) { $0 + $1.count }
        while total > Limits.maximumConsumers * 4 {
            guard let evictable = consumers.keys.first(where: { key in
                key != runID && consumers[key]?.last?.detached == true
            }) else { break }
            total -= consumers[evictable]?.count ?? 1
            consumers.removeValue(forKey: evictable)
        }
        return token
    }

    public func detachConsumer(_ token: RuntimeLiveConsumerToken) {
        lock.lock()
        defer { lock.unlock() }
        guard var states = consumers[token.runID] else { return }
        if let index = states.firstIndex(where: { $0.token == token }) {
            states[index].detached = true
            states.remove(at: index)
        }
        if states.isEmpty { consumers.removeValue(forKey: token.runID) }
        else { consumers[token.runID] = states }
    }

    /// Synchronous bounded live ingest (RB4 track task side). Returns the
    /// honest drop/detach classification — a priority overflow NEVER drops
    /// and NEVER cancels the underlying run; it detaches the consumer with
    /// an explicit resync signal.
    @discardableResult
    public func ingestLive(_ event: HarnessEvent, token: RuntimeLiveConsumerToken)
        -> RuntimeLiveIngestOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard let states = consumers[token.runID],
              let state = states.first(where: { $0.token == token }) else {
            return consumers[token.runID]?.contains(where: { $0.token == token }) == true
                ? .detached : .noConsumer
        }
        // Epoch fencing is a ROUTE-level truth and must be reported before
        // the (reattach/overflow) detach classification: an old-epoch token
        // is fenced even when its state was also marked detached.
        let currentEpoch = effectSequences[token.runID] ?? 0
        if token.epoch != currentEpoch { return .fencedByEpoch }
        if state.detached { return .detached }
        let priority = FacadeEventPump.isPriority(event)
        let payload: String
        if let data = try? JSONEncoder().encode(event),
           let string = String(data: data, encoding: .utf8) {
            payload = string
        } else {
            payload = "{\"unencodable\":true}"
        }
        let bytes = payload.utf8.count
        let frame = LiveConsumerState.Frame(liveSeq: state.nextLiveSeq,
                                            priority: priority,
                                            payloadJSON: payload,
                                            bytes: max(1, bytes))
        if priority {
            // Priority sub-queue: never silently dropped.
            let priorityCount = state.frames.filter { $0.priority }.count
            if priorityCount >= Limits.priorityRingEvents
                || state.frames.count >= Limits.liveRingEvents
                || state.retainedBytes + frame.bytes > Limits.liveRingBytes {
                state.detached = true
                state.resyncRequired = true
                return .detached
            }
        } else {
            // Deltas drop oldest with explicit resync, watermark preserved.
            while state.frames.count >= Limits.liveRingEvents
                    || state.retainedBytes + frame.bytes > Limits.liveRingBytes {
                guard let headIndex = state.frames.firstIndex(where: { !$0.priority })
                else {
                    // Only priority frames: saturation DETACHES, never drops them.
                    state.detached = true
                    state.resyncRequired = true
                    return .detached
                }
                let head = state.frames.remove(at: headIndex)
                state.retainedBytes -= head.bytes
                state.droppedDeltaCount += 1
                state.resyncRequired = true
            }
        }
        state.frames.append(frame)
        state.nextLiveSeq += 1
        state.retainedBytes += frame.bytes
        return priority ? .enqueued
            : (state.resyncRequired ? .droppedDeltas(resyncRequired: true) : .enqueued)
    }

    /// Synchronous bounded take for the event.poll handler. Live frames are
    /// ordered by liveSeq; the response reports resync explicitly.
    public func takeLive(token: RuntimeLiveConsumerToken, budgetBytes: Int)
        -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        guard let state = consumers[token.runID]?.first(where: { $0.token == token }) else {
            return ["liveState": "noConsumer", "frames": [Any](),
                    "resyncRequired": false]
        }
        if state.detached {
            return ["liveState": "detached", "frames": [Any](),
                    "resyncRequired": true]
        }
        var included: [[String: Any]] = []
        var used = 0
        while !state.frames.isEmpty {
            let head = state.frames[0]
            let item: [String: Any] = ["liveSeq": head.liveSeq,
                                       "priority": head.priority,
                                       "payload": head.payloadJSON]
            let itemBytes = FacadeFrameBudget.serializedBytes(item)
            if used + itemBytes + 1 > budgetBytes { break }
            included.append(item)
            used += itemBytes
            state.frames.removeFirst()
            state.retainedBytes -= head.bytes
        }
        let resync = state.resyncRequired
        state.resyncRequired = false
        return ["liveState": resync ? "resyncRequired" : "attached",
                "frames": included, "resyncRequired": resync,
                "droppedDeltas": state.droppedDeltaCount]
    }

    /// Take from the CURRENT (latest-epoch) consumer for a run without
    /// exposing tokens to synchronous binder callers. Honest `noConsumer`
    /// until a real run track task (RB4) attaches one — the projection
    /// never fabricates live frames.
    public func takeLatestLive(runID: UUID, budgetBytes: Int) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        guard let latest = consumers[runID]?.last else {
            return ["liveState": "noConsumer", "frames": [Any](),
                    "resyncRequired": false]
        }
        // Reuse takeLive semantics on the captured token (same lock is
        // already held; takeLive re-enters its own lock, so inline).
        return takeLiveLocked(token: latest.token, budgetBytes: budgetBytes)
    }

    private func takeLiveLocked(token: RuntimeLiveConsumerToken, budgetBytes: Int)
        -> [String: Any] {
        guard let state = consumers[token.runID]?.first(where: { $0.token == token }) else {
            return ["liveState": "noConsumer", "frames": [Any](),
                    "resyncRequired": false]
        }
        if state.detached {
            return ["liveState": "detached", "frames": [Any](),
                    "resyncRequired": true]
        }
        var included: [[String: Any]] = []
        var used = 0
        while !state.frames.isEmpty {
            let head = state.frames[0]
            let item: [String: Any] = ["liveSeq": head.liveSeq,
                                       "priority": head.priority,
                                       "payload": head.payloadJSON]
            let itemBytes = FacadeFrameBudget.serializedBytes(item)
            if used + itemBytes + 1 > budgetBytes { break }
            included.append(item)
            used += itemBytes + 1
            state.frames.removeFirst()
            state.retainedBytes -= head.bytes
        }
        let resync = state.resyncRequired
        state.resyncRequired = false
        return ["liveState": resync ? "resyncRequired" : "attached",
                "frames": included, "resyncRequired": resync,
                "droppedDeltas": state.droppedDeltaCount]
    }

    public var attachedConsumerCount: Int {
        lock.lock(); defer { lock.unlock() }
        return consumers.values.reduce(0) { $0 + $1.count }
    }

    public func statsSnapshot() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return [
            "windows": windows.count,
            "consumers": consumers.values.reduce(0) { $0 + $1.count },
            "watermarks": windows.values.reduce(into: [String: Int]()) {
                $0[$1.runID.uuidString] = $1.watermark
            }.count,
        ]
    }
}

// MARK: - Frame budget (shared, actual-UTF8, escape-aware)

/// Byte-exact serialization budget helpers. Every page item is measured by
/// its ACTUAL serialized UTF-8 size (JSON escaping included) — never by
/// `.count` of Swift characters.
public enum FacadeFrameBudget {
    /// Frozen bridge response bound (Bridge/AndroidBridge/BridgeV3 maximumBytes).
    public static let maximumSerializedBytes = 65_536
    /// Normal durable page budget INSIDE the envelope (48 KiB inclusive),
    /// leaving >=16 KiB headroom for envelope/framing (contract frameBudget).
    public static let pageBudgetBytes = 49_152

    public static func serializedBytes(_ object: Any) -> Int {
        guard JSONSerialization.isValidJSONObject(wrap(object)),
              let data = try? JSONSerialization.data(withJSONObject: wrap(object)) else {
            return Int.max   // never fit an unserializable item
        }
        return data.count
    }

    // MARK: Effect frame overhead (carrier integration, exact derivation)

    /// ACTUAL serialized size of the effect.poll handler frame wrapper with
    /// an EMPTY effects array for one concrete correlation/receipt pair,
    /// plus the outer `AndroidBridge.exchange` stamp (`"version"`,
    /// `"requestID"`) margin. `sequenceDigits` covers the worst-case cursor
    /// width (append time reserves headroom so the same item stays
    /// selectable later as digits grow).
    public static func effectFrameOverheadBytes(correlationID: String,
                                                receipt: String,
                                                sequenceDigits: Int) -> Int {
        let digits = min(19, max(1, sequenceDigits))
        let spacer = String(repeating: "9", count: digits)
        let wrapper: [String: Any] = [
            "ok": true,
            "schema": BridgeV3.effectSchema,
            "correlationID": correlationID,
            "cursor": ["operationReceiptID": receipt, "sequence": Int(spacer) ?? 0],
            "effects": [Any](),
            "hasMore": true,
            "resyncRequired": true,
        ]
        let base = serializedBytes(wrapper)
        let canonical = canonicalSerializedBytes(wrapper) ?? Int.max
        let effective = max(base, canonical)
        guard effective != Int.max else { return Int.max }
        // Outer exchange stamp: ,"requestID":"<correlation>","version":3
        // (worst case quoted correlation bytes + key punctuation).
        let outer = correlationID.utf8.count + 64
        let (sum, overflow) = effective.addingReportingOverflow(outer)
        return overflow ? Int.max : sum
    }

    /// Available effect-BODY budget (items + separators) for one poll frame
    /// at the 48 KiB page target. The hard 64 KiB serialized response bound
    /// is still enforced by `RuntimeFacadeBridge.finalize` + the frozen
    /// exchange check; this budget is what the pump selection and append
    /// acceptance share, so accepted items are never un-selectable later.
    public static func effectBodyBudgetBytes(correlationID: String,
                                             receipt: String,
                                             sequenceDigits: Int) -> Int {
        let overhead = effectFrameOverheadBytes(correlationID: correlationID,
                                                receipt: receipt,
                                                sequenceDigits: sequenceDigits)
        guard overhead != Int.max, overhead < pageBudgetBytes else { return 0 }
        return pageBudgetBytes - overhead
    }

    /// Serialize once, fail closed (no opportunistic partial JSON).
    public static func encode(_ object: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(wrap(object)) else { return nil }
        return try? JSONSerialization.data(withJSONObject: wrap(object),
                                           options: [.sortedKeys])
    }

    private static func wrap(_ object: Any) -> [String: Any] {
        if let dict = object as? [String: Any] { return dict }
        if let array = object as? [Any] { return ["v": array] }
        return ["v": [""]]
    }

    /// Canonical JSON byte count equivalent to kotlinx-serialization's
    /// `JsonObject.toString()` after it has parsed the ACTUAL Foundation
    /// wire (the RB1 Kotlin consumer's `pageBytes` / `valueBytes`
    /// derivation). Lexeme rules pinned by the cross-language corpus:
    ///  * compact punctuation, no whitespace; object keys sorted;
    ///  * strings follow kotlinx escaping: `"` → `\"`, `\` → `\\`,
    ///    \b \t \n \f \r short escapes, other characters below U+0020
    ///    → lowercase `\u00xx`; `/` is NOT escaped (Foundation's
    ///    JSONSerialization DOES escape it, which is why the wire size and
    ///    the Kotlin re-encoded size may differ);
    ///  * CJK, emoji, DEL/C1, U+2028/U+2029 stay raw UTF-8;
    ///  * NUMBERS keep the exact token Foundation emits. kotlinx preserves
    ///    the numeric lexeme it parsed, so `NSNumber(1.0)` is the wire token
    ///    `1` (NOT a Swift `Double.toString` imitation `1.0`), `1e-6` is
    ///    `9.9999999999999995e-07`, and NSDecimalNumber/UInt64 text is taken
    ///    verbatim from the same encoder that writes the frame. Nonfinite
    ///    values (which Foundation refuses to encode) return nil.
    /// Returns nil for a non-JSON value (never a zero that would undercount).
    public static func canonicalSerializedBytes(_ object: Any) -> Int? {
        var total = 0
        guard appendCanonical(object, into: &total) else { return nil }
        return total
    }

    private static func appendCanonical(_ object: Any, into total: inout Int) -> Bool {
        if object is NSNull {
            total += 4
            return true
        }
        if let string = object as? String {
            return appendCanonicalString(string, into: &total)
        }
        if let number = object as? NSNumber {
            return appendCanonicalNumber(number, into: &total)
        }
        if let array = object as? [Any] {
            total += 2
            for (index, item) in array.enumerated() {
                if index > 0 { total += 1 }
                guard appendCanonical(item, into: &total) else { return false }
            }
            return true
        }
        if let dictionary = object as? [String: Any] {
            total += 2
            for (index, key) in dictionary.keys.sorted().enumerated() {
                if index > 0 { total += 1 }
                guard appendCanonicalString(key, into: &total) else { return false }
                total += 1   // ':'
                guard appendCanonical(dictionary[key] ?? NSNull(), into: &total) else {
                    return false
                }
            }
            return true
        }
        return false
    }

    /// Count the EXACT numeric token the frame encoder writes. This is the
    /// only way to stay byte-identical to the consumer: kotlinx parses the
    /// Foundation token and re-emits that same lexeme, so a hand-written
    /// `Double.toString`/objCType guess is wrong for integral doubles,
    /// exponent thresholds, negative zero, NSDecimalNumber and large UInt64.
    /// JSONSerialization throws an Objective-C exception for nonfinite
    /// NSNumber values, so refuse them before touching the encoder.
    private static func appendCanonicalNumber(_ number: NSNumber,
                                              into total: inout Int) -> Bool {
        guard number.doubleValue.isFinite else { return false }
        let wrapper: [Any] = [number]
        guard JSONSerialization.isValidJSONObject(wrapper),
              let data = try? JSONSerialization.data(withJSONObject: wrapper),
              data.count >= 2,
              data.first == UInt8(ascii: "["),
              data.last == UInt8(ascii: "]") else {
            return false
        }
        total += data.count - 2   // strip the wrapper brackets
        return true
    }

    private static func appendCanonicalString(_ string: String, into total: inout Int) -> Bool {
        total += 2   // surrounding quotes
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": total += 2
            case "\\": total += 2
            case "\u{0008}": total += 2
            case "\u{0009}": total += 2
            case "\u{000A}": total += 2
            case "\u{000C}": total += 2
            case "\u{000D}": total += 2
            default:
                if scalar.value < 0x20 {
                    total += 6   // \u00xx
                } else {
                    total += scalar.utf8.count
                }
            }
        }
        return true
    }

    /// LEGACY diagnostic formatter retained for source compatibility. It is
    /// NOT used for wire byte accounting: the canonical size must follow the
    /// token Foundation actually emits (see `appendCanonicalNumber`), and
    /// kotlinx preserves that lexeme. Do not reintroduce this as the
    /// `pageBytes`/`valueBytes` source.
    public static func canonicalNumberText(_ value: Double) -> String {
        let raw = String(value)   // shortest round-trip decimal
        if let marker = raw.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            var mantissa = String(raw[raw.startIndex..<marker])
            var exponent = String(raw[raw.index(after: marker)...])
            if exponent.hasPrefix("+") { exponent.removeFirst() }
            var sign = ""
            if exponent.hasPrefix("-") { sign = "-"; exponent.removeFirst() }
            while exponent.count > 1 && exponent.hasPrefix("0") { exponent.removeFirst() }
            if !mantissa.contains(".") { mantissa += ".0" }
            return mantissa + "E" + sign + exponent
        }
        if !raw.contains(".") { return raw + ".0" }
        return raw
    }
}
