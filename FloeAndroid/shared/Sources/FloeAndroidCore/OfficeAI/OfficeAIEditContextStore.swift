// SPDX-License-Identifier: MPL-2.0
//
// G05-R2 Office AI (job-1db1a7a8d5da457a) — the trusted owned EDIT CONTEXT
// store. This is where the real engine-issued target handle lives: the model
// only ever sees the opaque `contextID`. The store enforces the capture /
// model-think / apply invariant structurally:
//
//  * a context binds conversationID + the exact captured document facts +
//    the engine target handle minted at READ time;
//  * `apply` must resolve THIS record (same session token, same native
//    generation) or it is refused BEFORE any dispatch — the workflow can
//    never silently mint a fresh capture at apply time;
//  * a content effect consumes the record exactly once, before dispatch;
//    later retries of the same seed hit the engine's duplicate-opId refusal
//    rather than a replayed effect;
//  * selection/navigation effects invalidate the old record and mint a
//    fresh capture-backed successor (honest recapture);
//  * records are bounded (count + TTL aligned with the engine's own handle
//    lifetime) and an epoch close retires every live record — late
//    callbacks against a dead generation cannot resolve anything.

import Foundation
import FloeCore
import FloeAndroidJobTools

public struct OfficeAIEditContextRecord: Sendable {
    public let contextID: String
    public let conversationID: UUID
    public let createdRunID: UUID
    /// The engine-minted single-use CONTENT handle. NEVER returned to any
    /// model surface; `description` redacts it.
    let targetHandle: String
    public let document: OfficeEditDocumentFacts
    public let capturedContext: OfficeEditQueryFacts
    public let capturedAtElapsedMillis: Int64
    /// True once a content/preparatory effect was DISPATCHED against this
    /// record (a dispatched-but-unknown effect still consumes the record:
    /// the effect may have happened; only a fresh read may open a successor).
    public var consumed = false

    public init(contextID: String, conversationID: UUID, createdRunID: UUID,
                targetHandle: String, document: OfficeEditDocumentFacts,
                capturedContext: OfficeEditQueryFacts, capturedAtElapsedMillis: Int64,
                consumed: Bool = false) {
        self.contextID = contextID
        self.conversationID = conversationID
        self.createdRunID = createdRunID
        self.targetHandle = targetHandle
        self.document = document
        self.capturedContext = capturedContext
        self.capturedAtElapsedMillis = capturedAtElapsedMillis
        self.consumed = consumed
    }

    public var description: String {
        "OfficeAIEditContext(id:\(contextID), conversation:\(conversationID.uuidString.prefix(8))…, "
            + "handle:redacted, consumed:\(consumed))"
    }
}

public final class OfficeAIEditContextStore: @unchecked Sendable {
    static let maximumLive = 16
    /// Aligned with the engine's own handle TTL (30 minutes).
    static let lifetimeMillis: Int64 = 30 * 60 * 1000

    private let lock = NSLock()
    private var records: [String: OfficeAIEditContextRecord] = [:]
    private let clock: @Sendable () -> Int64

    /// Monotonic elapsed milliseconds (DispatchTime uptime is the portable
    /// monotonic clock across the Darwin and Android/Linux builds).
    public init(clock: @escaping @Sendable () -> Int64 = {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }) {
        self.clock = clock
    }

    public var liveCount: Int { lock.lock(); defer { lock.unlock() }; return records.count }

    /// Insert a freshly captured context. Evicts the OLDEST expired record
    /// first when the table is full (never evicts a live unexpired one to
    /// make room — the capture refuses instead of dropping someone's target).
    @discardableResult
    public func insert(_ record: OfficeAIEditContextRecord) -> Bool {
        lock.lock(); defer { lock.unlock() }
        sweepExpiredLocked()
        if records.count >= Self.maximumLive {
            // Only expired records were swept above; a full live table means
            // honest saturation, not eviction of someone's reasoning target.
            return false
        }
        records[record.contextID] = record
        return true
    }

    /// Resolve a LIVE (unexpired, unconsumed, conversation-matching) record.
    public func liveRecord(contextID: String, conversationID: UUID) -> OfficeAIEditContextRecord? {
        lock.lock(); defer { lock.unlock() }
        guard let record = records[contextID] else { return nil }
        let now = clock()
        guard record.conversationID == conversationID, !record.consumed,
              now - record.capturedAtElapsedMillis < Self.lifetimeMillis else { return nil }
        return record
    }

    /// Read view of a record (may be consumed — used for honest diagnostics
    /// like `contextDocument` at job-prepare time, which must still answer
    /// while the context is live, and nil once consumed/expired/foreign).
    public func contextDocument(contextID: String, conversationID: UUID) -> OfficeEditDocumentFacts? {
        liveRecord(contextID: contextID, conversationID: conversationID)?.document
    }

    /// Amendment/2: the CAPTURED producer facts behind a live context (the
    /// actual logical part index the captured target lives on). Used only to
    /// persist bounded owned v2 target metadata into the durable outcome
    /// summary; grants nothing and never mints a fresh capture.
    public func capturedContext(contextID: String, conversationID: UUID) -> OfficeEditQueryFacts? {
        liveRecord(contextID: contextID, conversationID: conversationID)?.capturedContext
    }

    /// Consume exactly once. True for the first taker; every later attempt
    /// gets false (and must refuse before dispatch).
    public func consume(contextID: String, conversationID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var record = records[contextID], record.conversationID == conversationID,
              !record.consumed,
              clock() - record.capturedAtElapsedMillis < Self.lifetimeMillis else { return false }
        record.consumed = true
        records[contextID] = record
        return true
    }

    /// Supersede a record after an explicitly dispatched preparatory effect
    /// (the successor capture is already minted by the caller; the old id is
    /// removed so a retry cannot reuse it).
    public func supersede(oldContextID: String, conversationID: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let record = records[oldContextID], record.conversationID == conversationID else { return }
        records.removeValue(forKey: oldContextID)
    }

    /// Generation retirement: every record created under a closing lane is
    /// dropped; late callbacks can resolve nothing.
    public func retireAll() {
        lock.lock(); records.removeAll(); lock.unlock()
    }

    /// Stats: counts only (no ids, no handles, no conversations).
    public func statsJSON() -> String {
        lock.lock()
        let live = records.values.filter { clock() - $0.capturedAtElapsedMillis < Self.lifetimeMillis }
        let unconsumed = live.filter { !$0.consumed }.count
        lock.unlock()
        return "{\"liveRecords\":\(live.count),\"unconsumed\":\(unconsumed),\"capacity\":\(Self.maximumLive)}"
    }

    private func sweepExpiredLocked() {
        let now = clock()
        for (id, record) in records where now - record.capturedAtElapsedMillis >= Self.lifetimeMillis {
            records.removeValue(forKey: id)
        }
    }
}
