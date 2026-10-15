// FloePersistence — RAM-only stores for the temporary chat session.
//
// One temporary conversation is hosted entirely in memory: conversation row,
// messages/parts/attachments, run headers/events/usage/errors, the running
// input queue, and the launch transaction. Nothing in this file touches
// GRDB, the filesystem, UserDefaults or the keychain.
//
// Each store carries an explicit promotion gateway so "Keep as a saved chat"
// can copy the buffered rows into the durable SQLite stores while a stream
// is still appending:
//   active → beginPromotion() → promoting → completePromotion(durable:) → forwarded
//                 ↓ abortPromotion()           (or closed by the center)
//              active   (RAM fully intact, retryable)
// While `.promoting`, mutations keep buffering in RAM. `completePromotion`
// forwards every buffered row to the durable store in original order and
// flips the gateway so later appends forward directly. All forwarding happens
// inside the store actor, serialized with the appends it interleaves with,
// which gives exactly-once visibility and original append order. Durable
// writes use the SQLite stores' own conflict handling (`ON CONFLICT ... DO
// UPDATE`), so a re-forwarded row is a semantic no-op, never a duplicate.
//
// In `.forwarded` mode every mutation ALSO updates the RAM mirror, so the
// live run service that kept its store references after "Keep as a saved
// chat" reads the current forwarded state (never a stale pre-Keep snapshot).
// The run store additionally tracks promotion forward progress so a
// mid-tail I/O failure resumes exactly where it stopped instead of
// re-forwarding (the durable store mints new event ids per append, so a
// blind re-forward would duplicate tail events).

import Foundation
import FloeCore
import FloeModels

/// Gateway shared by the ephemeral stores. Mutating call sites consult
/// `writesForwardDirectly` to decide between buffering and forwarding; the
/// gateway itself performs the forwarded write so every mutation funnels
/// through one serialized path.
private enum PromotionGate<Mutable: Sendable> {
    case active
    case promoting
    case forwarded(durable: Mutable)
    case closed
}

// MARK: - Conversation store

/// Single-conversation, memory-backed `ConversationStore`. Every access for
/// an identifier other than the hosted conversation fails closed with
/// `.notFound`, so an unrelated conversation can never be shadowed.
public actor EphemeralConversationStore: ConversationStore {
    public typealias Snapshot = (
        conversation: ConversationRecord,
        messages: [PersistedMessage],
        attachments: [AttachmentRef]
    )

    private var gate: PromotionGate<any ConversationStore> = .active
    private let hostedConversationID: UUID
    private var record: ConversationRecord
    private var messages: [PersistedMessage] = []
    private var attachmentsByID: [UUID: AttachmentRef] = [:]

    public init(record: ConversationRecord) {
        self.hostedConversationID = record.id
        self.record = record
    }

    public var isForwarded: Bool {
        if case .forwarded = gate { return true }
        return false
    }

    /// Buffered rows not yet visible in durable storage. Returned in append
    /// order; used by the promotion snapshot.
    public func bufferedSnapshot() -> Snapshot {
        var attachments: [AttachmentRef] = []
        var seen = Set<UUID>()
        for message in messages {
            for part in message.parts {
                if let id = part.attachmentID, let ref = attachmentsByID[id], seen.insert(id).inserted {
                    attachments.append(ref)
                }
            }
        }
        for (_, ref) in attachmentsByID where seen.insert(ref.id).inserted {
            attachments.append(ref)
        }
        return (record, messages, attachments)
    }

    // MARK: Promotion gateway

    /// Begins promotion: appends keep buffering in RAM until
    /// `completePromotion` or `abortPromotion`. Returns the FROZEN snapshot
    /// at the promotion watermark — the exact rows the transactional
    /// promoter must commit. Appends after this call are the tail that
    /// `completePromotion` forwards; using a later `bufferedSnapshot()` for
    /// the promoter would double-commit those rows.
    @discardableResult
    public func beginPromotion() throws -> Snapshot {
        guard case .active = gate else {
            throw FloeError.invalidConfiguration("Temporary conversation store is not in an active promotion state")
        }
        gate = .promoting
        return bufferedSnapshot()
    }

    /// Aborts an in-flight promotion. No durable write has observed the
    /// buffered rows through this store; the caller compensates any rows it
    /// wrote itself. RAM content is fully intact and promotion may retry.
    public func abortPromotion() {
        if case .promoting = gate { gate = .active }
    }

    /// Forwards every buffered row to the durable store in original order,
    /// then flips the gateway so later mutations forward directly. A row the
    /// promoter already persisted is re-applied through the durable store's
    /// idempotent upsert — semantic no-op, never a duplicate. The forwarded
    /// conversation record is rewritten to its durable projection: the schema
    /// CHECK only admits `ordinary`, while RAM truth stays `.temporary`.
    public func completePromotion(durable: any ConversationStore) async throws {
        guard case .promoting = gate else {
            throw FloeError.invalidConfiguration("Temporary conversation store is not promoting")
        }
        let snapshot = bufferedSnapshot()
        var durableRecord = snapshot.conversation
        durableRecord.purpose = .ordinary
        try await durable.saveConversation(durableRecord)
        for message in snapshot.messages {
            try await durable.appendMessage(message)
        }
        for attachment in snapshot.attachments {
            try await durable.saveAttachment(attachment)
        }
        // The session may have been destroyed (buffers closed) while the
        // durable writes above were in flight: never resurrect forwarding on
        // a closed store — late appends must fail closed after an actual
        // leave. The committed rows above stay ordinary truth.
        guard case .promoting = gate else {
            throw FloeError.notFound("Temporary conversation has ended")
        }
        gate = .forwarded(durable: durable)
    }

    /// Tears the store down after the session ended without promotion.
    public func close() {
        gate = .closed
        messages = []
        attachmentsByID = [:]
    }

    private func forwardOrBuffer<T>(
        _ body: (any ConversationStore) async throws -> T,
        buffer: () -> Void
    ) async throws -> T? {
        switch gate {
        case .active, .promoting:
            buffer()
            return nil
        case .forwarded(let durable):
            // Forward first; only a successful durable write updates the RAM
            // mirror, so an I/O failure leaves both sides consistent and the
            // retry idempotent (durable writes are upserts by id).
            let value = try await body(durable)
            buffer()
            return value
        case .closed:
            throw FloeError.notFound("Temporary conversation has ended")
        }
    }

    private func requireHosted(_ conversationID: UUID) throws {
        guard conversationID == hostedConversationID else {
            throw FloeError.notFound("conversation \(conversationID.uuidString)")
        }
    }

    // MARK: ConversationStore

    public func saveConversation(_ conversation: ConversationRecord) async throws {
        try requireHosted(conversation.id)
        try await forwardOrBuffer({ durable in
            try await durable.saveConversation(conversation)
        }, buffer: {
            self.record = conversation
        })
    }

    public func conversations() async throws -> [ConversationRecord] {
        [record]
    }

    public func conversation(id: UUID) async throws -> ConversationRecord? {
        try requireHosted(id)
        return record
    }

    public func renameConversation(id: UUID, title: String) async throws {
        try requireHosted(id)
        var updated = record
        updated.title = title
        // An explicit user rename is MANUAL truth: promotion must carry it
        // and the post-Keep ordinary auto-title must never overwrite it.
        updated.titleOrigin = .manual
        updated.updatedAt = Date()
        try await saveConversation(updated)
    }

    @discardableResult
    public func setAutomaticTitle(id: UUID, title: String) async throws -> Bool {
        try requireHosted(id)
        guard record.titleOrigin == .autoPending else { return false }
        var updated = record
        updated.title = title
        updated.updatedAt = Date()
        try await saveConversation(updated)
        return true
    }

    public func deleteConversation(id: UUID) async throws {
        try requireHosted(id)
        try await forwardOrBuffer({ durable in
            try await durable.deleteConversation(id: id)
        }, buffer: { [self] in
            messages = []
            attachmentsByID = [:]
        })
    }

    /// A temporary session never hosts a row that could be converted in
    /// place: the durable projection exists only after a promotion
    /// committed, and then the RAM session is already ordinary. Removing
    /// the durable row is only meaningful while forwarded; before that the
    /// operation must not silently drop anything, so it refuses.
    @discardableResult
    public func deleteConversationIfVerifiedEmpty(id: UUID) async throws -> Bool {
        try requireHosted(id)
        guard case .forwarded(let durable) = gate else { return false }
        return try await durable.deleteConversationIfVerifiedEmpty(id: id)
    }

    public func setArchived(id: UUID, archived: Bool) async throws {
        // Temporary conversations never enter the archive projection; keep
        // the operation a RAM-only no-op so callers stay simple.
        try requireHosted(id)
    }

    public func conversations(includeArchived: Bool) async throws -> [ConversationRecord] {
        [record]
    }

    public func appendMessage(_ message: PersistedMessage) async throws {
        try requireHosted(message.conversationID)
        try await forwardOrBuffer({ durable in
            try await durable.appendMessage(message)
        }, buffer: { [self] in
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = message
            } else {
                messages.append(message)
            }
            messages.sort { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
            record.updatedAt = Date()
        })
    }

    public func messages(conversationID: UUID) async throws -> [PersistedMessage] {
        try requireHosted(conversationID)
        return messages
    }

    public func recentMessages(conversationID: UUID, limit: Int) async throws -> [PersistedMessage] {
        try requireHosted(conversationID)
        return Array(messages.suffix(max(1, limit)))
    }

    public func messagePage(
        conversationID: UUID,
        before cursor: ConversationMessageCursor?,
        limit: Int
    ) async throws -> ConversationMessagePage {
        try requireHosted(conversationID)
        let ordered = messages
        let eligible = cursor.map { cursor in
            ordered.filter {
                ($0.createdAt, $0.id.uuidString) < (cursor.createdAt, cursor.messageID.uuidString)
            }
        } ?? ordered
        let bounded = max(1, limit)
        let page = Array(eligible.suffix(bounded))
        return ConversationMessagePage(
            messages: page,
            earlierCursor: page.first.map {
                ConversationMessageCursor(createdAt: $0.createdAt, messageID: $0.id)
            },
            hasEarlier: eligible.count > page.count
        )
    }

    public func parts(messageID: UUID) async throws -> [MessagePart] {
        guard let message = messages.first(where: { $0.id == messageID }) else {
            throw FloeError.notFound("message \(messageID.uuidString)")
        }
        return message.parts.sorted { $0.partIndex < $1.partIndex }
    }

    public func saveAttachment(_ attachment: AttachmentRef) async throws {
        if let conversationID = attachment.conversationID {
            try requireHosted(conversationID)
        }
        try await forwardOrBuffer({ durable in
            try await durable.saveAttachment(attachment)
        }, buffer: { [self] in
            attachmentsByID[attachment.id] = attachment
        })
    }

    public func attachment(id: UUID) async throws -> AttachmentRef? {
        attachmentsByID[id]
    }

    public func attachments(conversationID: UUID) async throws -> [AttachmentRef] {
        try requireHosted(conversationID)
        return attachmentsByID.values.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }
}

// MARK: - Run store

/// Memory-backed `RunStore` hosting the runs of one temporary conversation.
/// Event sequences are per-run monotonic and mirror the SQLite counter, so a
/// promotion that snapshots N events sees the SQLite MAX(sequence) settle at
/// N and forwards the buffered tail at N+1… in original order.
public actor EphemeralRunStore: RunStore {
    public typealias Snapshot = (
        runs: [RunRecord],
        events: [UUID: [RunEventRecord]],
        usage: [UUID: [RunUsageRecord]],
        errors: [UUID: [RunErrorRecord]]
    )

    private var gate: PromotionGate<any RunStore> = .active
    private let hostedConversationID: UUID
    private var runsByID: [UUID: RunRecord] = [:]
    private var runOrder: [UUID] = []
    private var eventsByRun: [UUID: [RunEventRecord]] = [:]
    private var usageByRun: [UUID: [RunUsageRecord]] = [:]
    private var errorsByRun: [UUID: [RunErrorRecord]] = [:]
    private var checkpoints: [UUID: String] = [:]
    /// Promotion watermark: buffer sizes when `beginPromotion()` ran. The
    /// transactional promoter commits everything at or below the watermark
    /// inside the GRDB transaction; `completePromotion` forwards ONLY the
    /// tail beyond it. Re-forwarding watermark rows would duplicate run
    /// events (the durable store mints a NEW event id for every append).
    private var promotionWatermark: (runs: Int, events: Int, usage: Int, errors: Int)?
    /// Tail rows already forwarded by an earlier `completePromotion` attempt
    /// that failed mid-tail. Resuming skips them; the durable store mints
    /// new ids per append, so a blind re-forward would duplicate events.
    private var promotionForwardProgress: (events: Int, usage: Int, errors: Int)?

    public init(hostedConversationID: UUID) {
        self.hostedConversationID = hostedConversationID
    }

    public var isForwarded: Bool {
        if case .forwarded = gate { return true }
        return false
    }

    public func bufferedSnapshot() -> Snapshot {
        (runOrder.compactMap { runsByID[$0] }, eventsByRun, usageByRun, errorsByRun)
    }

    /// Begins promotion: appends keep buffering in RAM until
    /// `completePromotion` or `abortPromotion`. Returns the FROZEN snapshot
    /// at the promotion watermark — the exact rows the transactional
    /// promoter must commit. Later appends are the tail that
    /// `completePromotion` forwards with durable-minted identities.
    @discardableResult
    public func beginPromotion() throws -> Snapshot {
        guard case .active = gate else {
            throw FloeError.invalidConfiguration("Temporary run store is not in an active promotion state")
        }
        promotionWatermark = (
            runs: runOrder.count,
            events: eventsByRun.values.reduce(0) { $0 + $1.count },
            usage: usageByRun.values.reduce(0) { $0 + $1.count },
            errors: errorsByRun.values.reduce(0) { $0 + $1.count }
        )
        gate = .promoting
        return bufferedSnapshot()
    }

    public func abortPromotion() {
        if case .promoting = gate {
            gate = .active
            promotionWatermark = nil
            promotionForwardProgress = nil
        }
    }

    public func completePromotion(durable: any RunStore) async throws {
        guard case .promoting = gate else {
            throw FloeError.invalidConfiguration("Temporary run store is not promoting")
        }
        // Forward ONLY the post-watermark tail: rows at or below the
        // watermark were committed by the promoter's transaction (identical
        // ids/sequences, idempotent on retry). Re-forwarding them would
        // duplicate run events, because the durable store mints a NEW event
        // id for every append. A previous attempt's forwarded tail (progress
        // counters) resumes exactly after it — never re-forwarded.
        let watermark = promotionWatermark ?? (runs: 0, events: 0, usage: 0, errors: 0)
        var forwardedEvents = 0
        var forwardedUsage = 0
        var forwardedErrors = 0
        // Persist tail progress after every successful durable write: an
        // attempt that fails mid-tail resumes exactly after it (the durable
        // store mints new event ids per append, so a blind re-forward of an
        // already-forwarded tail row would duplicate it).
        promotionForwardProgress = promotionForwardProgress ?? (events: 0, usage: 0, errors: 0)
        for run in runOrder.compactMap({ runsByID[$0] }) {
            try await durable.saveRun(run)
        }
        for runID in runOrder {
            for event in eventsByRun[runID, default: []] {
                guard forwardedEvents >= watermark.events else {
                    forwardedEvents += 1
                    continue
                }
                guard promotionForwardProgress!.events <= forwardedEvents - watermark.events else {
                    forwardedEvents += 1
                    continue
                }
                _ = try await durable.appendEvent(
                    runID: runID,
                    kind: event.kind,
                    payloadJSON: event.payloadJSON
                )
                forwardedEvents += 1
                promotionForwardProgress!.events += 1
            }
            for usage in usageByRun[runID, default: []] {
                guard forwardedUsage >= watermark.usage else {
                    forwardedUsage += 1
                    continue
                }
                guard promotionForwardProgress!.usage <= forwardedUsage - watermark.usage else {
                    forwardedUsage += 1
                    continue
                }
                try await durable.recordUsage(usage)
                forwardedUsage += 1
                promotionForwardProgress!.usage += 1
            }
            for error in errorsByRun[runID, default: []] {
                guard forwardedErrors >= watermark.errors else {
                    forwardedErrors += 1
                    continue
                }
                guard promotionForwardProgress!.errors <= forwardedErrors - watermark.errors else {
                    forwardedErrors += 1
                    continue
                }
                try await durable.recordError(error)
                forwardedErrors += 1
                promotionForwardProgress!.errors += 1
            }
        }
        // Replace the RAM tail with the durable projection: forwarded rows
        // carry durable-minted identities (event ids/sequences), and the
        // live run service holding this store reference must read exactly
        // what SQLite now holds — never the pre-forward RAM projection.
        for runID in runOrder {
            if let events = try? await durable.events(runID: runID) {
                eventsByRun[runID] = events
            }
            if let usage = try? await durable.usage(runID: runID) {
                usageByRun[runID] = usage
            }
            if let errors = try? await durable.errors(runID: runID) {
                errorsByRun[runID] = errors
            }
        }
        promotionWatermark = nil
        promotionForwardProgress = nil
        // The session may have been destroyed (buffers closed) while the
        // tail forwarding above was in flight: never resurrect forwarding on
        // a closed store — late appends must fail closed after a leave. The
        // forwarded rows above stay ordinary truth.
        guard case .promoting = gate else {
            throw FloeError.notFound("Temporary conversation has ended")
        }
        gate = .forwarded(durable: durable)
    }

    public func close() {
        gate = .closed
        runsByID = [:]
        runOrder = []
        eventsByRun = [:]
        usageByRun = [:]
        errorsByRun = [:]
        checkpoints = [:]
    }

    private func forwardOrBuffer(
        _ body: (any RunStore) async throws -> Void,
        buffer: () -> Void
    ) async throws {
        switch gate {
        case .active, .promoting:
            buffer()
        case .forwarded(let durable):
            // Forward first; only a successful durable write updates the RAM
            // mirror, so the live run service never reads a stale snapshot
            // after "Keep as a saved chat".
            try await body(durable)
            buffer()
        case .closed:
            throw FloeError.notFound("Temporary conversation has ended")
        }
    }

    private func requireHosted(_ runID: UUID) throws {
        guard let run = runsByID[runID], run.conversationID == hostedConversationID else {
            // A run header may legitimately arrive before the launch store
            // created it here (defensive); only reads of unknown runs fail.
            throw FloeError.notFound("run \(runID.uuidString)")
        }
    }

    public func saveRun(_ run: RunRecord) async throws {
        guard run.conversationID == hostedConversationID else {
            throw FloeError.notFound("run \(run.id.uuidString)")
        }
        try await forwardOrBuffer({ durable in
            try await durable.saveRun(run)
        }, buffer: { [self] in
            if runsByID[run.id] == nil { runOrder.append(run.id) }
            runsByID[run.id] = run
        })
    }

    public func run(id: UUID) async throws -> RunRecord? {
        runsByID[id]
    }

    public func runs(conversationID: UUID) async throws -> [RunRecord] {
        guard conversationID == hostedConversationID else { return [] }
        return runOrder.compactMap { runsByID[$0] }
            .sorted { ($0.startedAt, $0.id.uuidString) > ($1.startedAt, $1.id.uuidString) }
    }

    public func recentRuns(conversationID: UUID, limit: Int) async throws -> [RunRecord] {
        Array(try await runs(conversationID: conversationID).prefix(max(1, limit)))
    }

    public func nonTerminalRuns() async throws -> [RunRecord] {
        runOrder.compactMap { runsByID[$0] }.filter {
            !["completed", "failed", "checkpointed", "interrupted"].contains($0.state)
        }
    }

    public func updateRunState(id: UUID, state: String, endedAt: Date?) async throws {
        try await forwardOrBuffer({ durable in
            try await durable.updateRunState(id: id, state: state, endedAt: endedAt)
        }, buffer: { [self] in
            guard var run = runsByID[id] else { return }
            run.state = state
            if let endedAt { run.endedAt = endedAt }
            runsByID[id] = run
        })
    }

    public func assignGoal(runID: UUID, goalID: UUID) async throws {
        try await forwardOrBuffer({ durable in
            try await durable.assignGoal(runID: runID, goalID: goalID)
        }, buffer: { [self] in
            guard var run = runsByID[runID] else { return }
            run.goalID = goalID
            runsByID[runID] = run
        })
    }

    @discardableResult
    public func appendEvent(runID: UUID, kind: RunEventRecord.Kind, payloadJSON: String) async throws -> RunEventRecord {
        try await requireHosted(runID)
        switch gate {
        case .active, .promoting:
            let record = RunEventRecord(
                runID: runID,
                sequence: (eventsByRun[runID]?.last?.sequence ?? 0) + 1,
                kind: kind,
                payloadJSON: payloadJSON
            )
            eventsByRun[runID, default: []].append(record)
            return record
        case .forwarded(let durable):
            // Mirror the DURABLE-minted record (new id, MAX(sequence)+1) so
            // RAM and SQLite stay identical for the live run service.
            let record = try await durable.appendEvent(
                runID: runID, kind: kind, payloadJSON: payloadJSON)
            eventsByRun[runID, default: []].append(record)
            return record
        case .closed:
            throw FloeError.notFound("Temporary conversation has ended")
        }
    }

    public func events(runID: UUID) async throws -> [RunEventRecord] {
        eventsByRun[runID] ?? []
    }

    public func recentEvents(runID: UUID, limit: Int) async throws -> [RunEventRecord] {
        Array((eventsByRun[runID] ?? []).suffix(max(1, limit)))
    }

    public func earlierEvents(runID: UUID, beforeSequence: Int, limit: Int) async throws -> [RunEventRecord] {
        Array((eventsByRun[runID] ?? []).filter { $0.sequence < beforeSequence }.suffix(max(1, limit)))
    }

    public func events(runID: UUID, afterSequence: Int, limit: Int) async throws -> [RunEventRecord] {
        Array((eventsByRun[runID] ?? []).filter { $0.sequence > afterSequence }.prefix(max(1, limit)))
    }

    public func recordUsage(_ usage: RunUsageRecord) async throws {
        try await forwardOrBuffer({ durable in
            try await durable.recordUsage(usage)
        }, buffer: { [self] in
            usageByRun[usage.runID, default: []].append(usage)
        })
    }

    public func usage(runID: UUID) async throws -> [RunUsageRecord] {
        usageByRun[runID] ?? []
    }

    public func recordError(_ error: RunErrorRecord) async throws {
        try await forwardOrBuffer({ durable in
            try await durable.recordError(error)
        }, buffer: { [self] in
            errorsByRun[error.runID, default: []].append(error)
        })
    }

    public func errors(runID: UUID) async throws -> [RunErrorRecord] {
        errorsByRun[runID] ?? []
    }

    public func saveCheckpoint(runID: UUID, conversationID: UUID, formatVersion: Int, state: String, bodyJSON: String) async throws {
        // The SQLite checkpoints table is dormant in production; keep the
        // payload in RAM so the temporary session never gains a durable copy.
        checkpoints[runID] = bodyJSON
    }

    public func checkpointBody(runID: UUID) async throws -> String? {
        checkpoints[runID]
    }

    public func deleteCheckpoint(runID: UUID) async throws {
        checkpoints.removeValue(forKey: runID)
    }

    public func usageStatistics() async throws -> UsageStatistics {
        // Numeric, content-free accounting of the temporary session only.
        var input = 0
        var output = 0
        var totalRuns = 0
        for records in usageByRun.values {
            for record in records {
                input += record.inputTokens
                output += record.outputTokens
            }
        }
        totalRuns = runsByID.count
        return UsageStatistics(
            totalInputTokens: input,
            totalOutputTokens: output,
            totalTokens: input + output,
            totalRuns: totalRuns,
            byDay: []
        )
    }
}

// MARK: - Running input store

/// Memory-backed `RunningInputStore` mirroring the durable queue semantics
/// (positions, claim transitions, steer promotion) for one conversation.
///
/// The store carries the same promotion gateway as the conversation/run
/// stores so "Keep as a saved chat" is lossless for the queue: the frozen
/// watermark rows commit inside the promoter's single GRDB transaction, the
/// tail (rows enqueued or status changes during promotion) forwards through
/// `completePromotion`, and every later mutation forwards directly while
/// mirroring into RAM — the live run that kept this store reference reads
/// the current queue, never a stale pre-Keep snapshot.
public actor EphemeralRunningInputStore: RunningInputStore {
    public static let maximumPendingPerConversation = 100

    private var gate: PromotionGate<any RunningInputStore> = .active
    private let hostedConversationID: UUID
    private var inputs: [UUID: PendingUserInput] = [:]

    public init(hostedConversationID: UUID) {
        self.hostedConversationID = hostedConversationID
    }

    public var isForwarded: Bool {
        if case .forwarded = gate { return true }
        return false
    }

    // MARK: Promotion gateway

    /// Frozen watermark snapshot: every queued/steer row the promoter must
    /// commit inside its GRDB transaction. Status changes during promotion
    /// keep buffering in RAM and land through `completePromotion`.
    public func beginPromotion() throws -> [PendingUserInput] {
        guard case .active = gate else {
            throw FloeError.invalidConfiguration("Temporary input store is not in an active promotion state")
        }
        gate = .promoting
        return inputs.values
            .sorted { ($0.position, $0.createdAt, $0.id.uuidString) < ($1.position, $1.createdAt, $1.id.uuidString) }
    }

    public func abortPromotion() {
        if case .promoting = gate { gate = .active }
    }

    /// Forwards the whole RAM queue to the durable store (idempotent upsert
    /// by id — safe to re-run after a mid-tail failure) and flips the
    /// gateway so later mutations forward directly with a RAM mirror.
    public func completePromotion(durable: any RunningInputStore) async throws {
        guard case .promoting = gate else {
            throw FloeError.invalidConfiguration("Temporary input store is not promoting")
        }
        for input in inputs.values {
            try await durable.upsert(input)
        }
        // A destroyed session closes the buffers while these upserts are in
        // flight; never flip a closed store back to forwarding.
        guard case .promoting = gate else {
            throw FloeError.notFound("Temporary conversation has ended")
        }
        gate = .forwarded(durable: durable)
    }

    /// Tears the store down after the session ended without promotion.
    public func close() {
        gate = .closed
        inputs = [:]
    }

    private func requireHosted(_ conversationID: UUID) throws {
        guard conversationID == hostedConversationID else {
            throw FloeError.notFound("conversation \(conversationID.uuidString)")
        }
    }

    private func pendingOrdered(_ conversationID: UUID) -> [PendingUserInput] {
        inputs.values
            .filter { $0.conversationID == conversationID && $0.status.isPending }
            .sorted { ($0.position, $0.createdAt, $0.id.uuidString) < ($1.position, $1.createdAt, $1.id.uuidString) }
    }

    /// Forwards a single-row mutation to the durable store (once forwarded)
    /// and mirrors the authoritative durable row back into RAM, so reads
    /// never serve stale queue state. Before forwarding the mutation applies
    /// to RAM only.
    private func mutate(
        _ body: (any RunningInputStore) async throws -> Void,
        affected id: UUID,
        buffer: () throws -> Void
    ) async throws {
        switch gate {
        case .active, .promoting:
            try buffer()
        case .forwarded(let durable):
            try await body(durable)
            if let row = try? await durable.input(id: id) {
                inputs[id] = row
            }
        case .closed:
            throw FloeError.notFound("Temporary conversation has ended")
        }
    }

    /// Forwards a conversation-scoped mutation and re-syncs every pending
    /// row from the durable projection (positions/statuses are durable-
    /// authoritative once forwarded).
    private func mutateConversationScoped(
        _ body: (any RunningInputStore) async throws -> Void,
        conversationID: UUID,
        buffer: () throws -> Void
    ) async throws {
        switch gate {
        case .active, .promoting:
            try buffer()
        case .forwarded(let durable):
            try await body(durable)
            if let rows = try? await durable.pending(conversationID: conversationID) {
                for row in rows { inputs[row.id] = row }
            }
        case .closed:
            throw FloeError.notFound("Temporary conversation has ended")
        }
    }

    public func enqueue(_ input: PendingUserInput) async throws -> PendingUserInput {
        try requireHosted(input.conversationID)
        let trimmed = input.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FloeError.validationFailed("Input must not be empty")
        }
        guard pendingOrdered(input.conversationID).count < Self.maximumPendingPerConversation else {
            throw FloeError.validationFailed("The running-input queue is full")
        }
        switch gate {
        case .active, .promoting:
            var value = input
            value.content = trimmed
            value.position = (pendingOrdered(input.conversationID).last?.position ?? 0) + 1
            value.updatedAt = Date()
            inputs[value.id] = value
            return value
        case .forwarded(let durable):
            let value = try await durable.enqueue(input)
            inputs[value.id] = value
            return value
        case .closed:
            throw FloeError.notFound("Temporary conversation has ended")
        }
    }

    public func pending(conversationID: UUID) async throws -> [PendingUserInput] {
        try requireHosted(conversationID)
        return pendingOrdered(conversationID)
    }

    public func input(id: UUID) async throws -> PendingUserInput? {
        inputs[id]
    }

    /// By-id write with the exact identity (used by the promotion mirror).
    /// Before forwarding it is a local RAM write; once forwarded it upserts
    /// the durable row and mirrors it back.
    public func upsert(_ input: PendingUserInput) async throws {
        try requireHosted(input.conversationID)
        switch gate {
        case .active, .promoting:
            var value = input
            value.updatedAt = Date()
            inputs[value.id] = value
        case .forwarded(let durable):
            try await durable.upsert(input)
            if let row = try? await durable.input(id: input.id) {
                inputs[input.id] = row
            }
        case .closed:
            throw FloeError.notFound("Temporary conversation has ended")
        }
    }

    public func updateContent(id: UUID, content: String) async throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FloeError.validationFailed("Input must not be empty") }
        try await mutate({ durable in
            try await durable.updateContent(id: id, content: trimmed)
        }, affected: id) {
            guard var value = inputs[id], value.status == .queued else {
                throw FloeError.validationFailed("Only queued input can be edited")
            }
            value.content = trimmed
            value.updatedAt = Date()
            inputs[id] = value
        }
    }

    public func cancel(id: UUID) async throws {
        try await mutate({ durable in
            try await durable.cancel(id: id)
        }, affected: id) {
            guard var value = inputs[id], value.status == .queued else {
                throw FloeError.validationFailed("Only queued input can be removed")
            }
            value.status = .cancelled
            value.updatedAt = Date()
            inputs[id] = value
        }
    }

    public func reorder(conversationID: UUID, orderedIDs: [UUID]) async throws {
        try requireHosted(conversationID)
        try await mutateConversationScoped({ durable in
            try await durable.reorder(conversationID: conversationID, orderedIDs: orderedIDs)
        }, conversationID: conversationID) {
            let current = pendingOrdered(conversationID).filter { $0.status == .queued }.map(\.id)
            guard Set(current) == Set(orderedIDs), current.count == orderedIDs.count else {
                throw FloeError.validationFailed("Queue changed while it was being reordered")
            }
            for (index, id) in orderedIDs.enumerated() {
                inputs[id]?.position = Int64(index + 1)
                inputs[id]?.updatedAt = Date()
            }
        }
    }

    public func claimNextQueued(conversationID: UUID) async throws -> PendingUserInput? {
        try requireHosted(conversationID)
        switch gate {
        case .active, .promoting:
            guard var next = pendingOrdered(conversationID)
                .first(where: { $0.status == .queued && $0.executionMode != "browserHandoff" })
            else { return nil }
            next.status = .promoting
            next.updatedAt = Date()
            inputs[next.id] = next
            return next
        case .forwarded(let durable):
            guard let next = try await durable.claimNextQueued(conversationID: conversationID) else {
                return nil
            }
            inputs[next.id] = next
            return next
        case .closed:
            throw FloeError.notFound("Temporary conversation has ended")
        }
    }

    public func beginSteerPromotion(id: UUID, expectedRunID: UUID) async throws -> PendingUserInput? {
        switch gate {
        case .active, .promoting:
            guard var value = inputs[id], value.status == .queued else { return nil }
            guard value.targetRunID == expectedRunID else {
                throw FloeError.validationFailed("Input targets a different run")
            }
            value.status = .promoting
            value.mode = .steer
            value.updatedAt = Date()
            inputs[id] = value
            return value
        case .forwarded(let durable):
            guard let value = try await durable.beginSteerPromotion(
                id: id, expectedRunID: expectedRunID) else { return nil }
            inputs[id] = value
            return value
        case .closed:
            throw FloeError.notFound("Temporary conversation has ended")
        }
    }

    public func markSteerAccepted(id: UUID, runID: UUID) async throws {
        try await mutate({ durable in
            try await durable.markSteerAccepted(id: id, runID: runID)
        }, affected: id) {
            guard var value = inputs[id] else { throw FloeError.notFound("input \(id.uuidString)") }
            value.status = .steerPending
            value.targetRunID = runID
            value.updatedAt = Date()
            inputs[id] = value
        }
    }

    public func markConsumed(id: UUID, runID: UUID) async throws {
        try await mutate({ durable in
            try await durable.markConsumed(id: id, runID: runID)
        }, affected: id) {
            guard var value = inputs[id] else { throw FloeError.notFound("input \(id.uuidString)") }
            value.status = .consumed
            value.consumedRunID = runID
            value.consumedAt = Date()
            value.updatedAt = Date()
            inputs[id] = value
        }
    }

    /// Restores a withdrawn steer/claim to the queue. Mirrors the durable
    /// store's transition exactly: both `promoting` AND `steerPending` rows
    /// return to `.queued`, the steer target is cleared and the mode resets.
    public func restoreQueued(id: UUID) async throws {
        try await mutate({ durable in
            try await durable.restoreQueued(id: id)
        }, affected: id) {
            guard var value = inputs[id],
                  value.status == .promoting || value.status == .steerPending else {
                throw FloeError.validationFailed("Only a pending promotion can be restored")
            }
            value.status = .queued
            value.mode = .queue
            value.targetRunID = nil
            value.updatedAt = Date()
            inputs[id] = value
        }
    }

    public func recoverTransientInputs() async throws {
        switch gate {
        case .active, .promoting:
            // Nothing is durable; transient states die with the session by design.
            break
        case .forwarded(let durable):
            try await durable.recoverTransientInputs()
            // The durable projection is authoritative for recovered rows.
            if let rows = try? await durable.pending(conversationID: hostedConversationID) {
                for row in rows { inputs[row.id] = row }
            }
        case .closed:
            throw FloeError.notFound("Temporary conversation has ended")
        }
    }
}

// MARK: - Launch store

/// Memory-backed `RunLaunchStore` for the temporary session. Mirrors the
/// SQLite launch's validation and produces a `PreparedRun` made purely of RAM
/// records: the conversation row (`.temporary`), a virtual private workspace
/// record (never written anywhere), the run header, the first user message
/// and its parts. Provider/model repair stays with the ordinary launch path —
/// temporary runs reuse the already-durable provider/model configuration.
public actor EphemeralRunLaunchStore: RunLaunchStore {
    private let hostedConversationID: UUID
    private let conversationStore: EphemeralConversationStore
    private let runStore: EphemeralRunStore

    /// The launch store applies the prepared records into the session's RAM
    /// stores — the mirror of what the SQLite launch transaction persists.
    public init(
        hostedConversationID: UUID,
        conversationStore: EphemeralConversationStore,
        runStore: EphemeralRunStore
    ) {
        self.hostedConversationID = hostedConversationID
        self.conversationStore = conversationStore
        self.runStore = runStore
    }

    public func prepare(_ request: RunLaunchRequest) async throws -> PreparedRun {
        guard request.conversationID == nil || request.newConversationID == nil else {
            throw FloeError.validationFailed("Choose an existing or a new conversation identity, not both")
        }
        guard request.conversationID == hostedConversationID
                || request.newConversationID == hostedConversationID else {
            throw FloeError.validationFailed("Launch identity does not match the temporary session")
        }
        let goal = request.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else {
            throw FloeError.validationFailed("Goal must not be empty")
        }
        guard ["chat", "plan", "goal"].contains(request.conversationMode) else {
            throw FloeError.validationFailed("Unknown conversation mode")
        }
        guard ["user", "goalContinuation"].contains(request.messageRole) else {
            throw FloeError.validationFailed("Unknown launch message role")
        }
        let now = request.startedAt
        let conversation = ConversationRecord(
            id: hostedConversationID,
            title: request.conversationTitle,
            createdAt: now,
            updatedAt: now,
            titleOrigin: .autoPending,
            purpose: .temporary
        )
        let workspace = WorkspaceRecord(
            id: request.workspaceID ?? UUID(),
            name: "Temporary",
            rootBookmark: Data(),
            kind: .privateTask,
            createdAt: now,
            updatedAt: now
        )
        let run = RunRecord(
            id: request.runID,
            conversationID: hostedConversationID,
            state: request.initialState,
            goal: goal,
            startedAt: now,
            providerID: request.providerID,
            modelID: request.modelID,
            providerName: request.providerName,
            modelName: request.modelName,
            conversationMode: request.conversationMode
        )
        let messageID = UUID()
        var parts: [MessagePart] = [MessagePart(
            messageID: messageID,
            partIndex: 0,
            kind: .text,
            text: goal,
            createdAt: now
        )]
        var normalizedAttachments: [AttachmentRef] = []
        for (offset, attachment) in request.attachments.enumerated() {
            var normalized = attachment
            normalized.conversationID = hostedConversationID
            normalized.messageID = messageID
            normalizedAttachments.append(normalized)
            parts.append(MessagePart(
                messageID: messageID,
                partIndex: offset + 1,
                kind: normalized.kind == .image ? .image : .file,
                attachmentID: normalized.id,
                metadata: ["name": normalized.displayName],
                createdAt: now
            ))
        }
        let userMessage = PersistedMessage(
            id: messageID,
            conversationID: hostedConversationID,
            role: request.messageRole,
            content: goal,
            createdAt: now,
            parts: parts,
            runID: run.id
        )
        // Apply into the session stores (RAM only), mirroring the durable
        // launch transaction's effect for later reads and runtime appends.
        if request.conversationID == nil {
            try await conversationStore.saveConversation(conversation)
        }
        try await runStore.saveRun(run)
        try await conversationStore.appendMessage(userMessage)
        for attachment in normalizedAttachments {
            try await conversationStore.saveAttachment(attachment)
        }
        // Preserve the same initial status event as SQLiteRunLaunchStore.
        // The stream and a later explicit promotion start at sequence 1.
        _ = try await runStore.appendEvent(
            runID: run.id,
            kind: .status,
            payloadJSON: #"{"state":"preparing"}"#
        )
        return PreparedRun(
            conversation: conversation,
            workspace: workspace,
            run: run,
            userMessage: userMessage,
            attachments: normalizedAttachments,
            createdConversation: request.conversationID == nil
        )
    }
}
