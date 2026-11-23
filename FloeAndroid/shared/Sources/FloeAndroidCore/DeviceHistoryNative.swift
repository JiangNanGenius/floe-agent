// SPDX-License-Identifier: MPL-2.0
//
// Device-history sync — trusted-host C ABI (`floe_device_history_*`).
//
// Bounded, epoch-fenced native entry for the App-owned device-history lane:
// the App lists shareable ordinary conversations (offers), exports the
// portable v1 bytes of one offered conversation, and explicitly imports
// verified peer bytes. Kotlin `DeviceHistoryNative` is the ONLY JVM caller;
// nothing here is a V3 command and no model route reaches these functions.
//
// Transport discipline (mirrors the reviewed run-output/staging lanes):
//  * the generic C bridge page is 64 KiB, so archive bytes NEVER cross in
//    one JNI array: export streams out and import streams in as <= 64 KiB
//    chunks over opaque positive-Int64 tickets;
//  * sessions are process-lifecycle owned by `DeviceHistoryBridgeFacade`:
//    one lock, epoch fencing against `G02NativeRootEpoch.readback()` on
//    EVERY stateful call, stale-generation + idle sweep, exactly-once
//    retire, counters-only stats;
//  * inputs are ONLY (epoch, conversation UUIDs, bounded chunks). No paths,
//    no URIs, no store handles, no receipts from the caller — the store is
//    resolved from the LIVE generation's own durable bundle;
//  * every store hop is a bounded semaphore wait (absolute deadline, spurious
//    wake retakes never extend the budget); a late hop releases its own
//    resources and never advertises a session;
//  * typed rejections are negative status codes — never a silent null and
//    never message bytes/titles/paths inside an error text.

import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence

// MARK: - Status / limits vocabulary

public enum DeviceHistoryBridgeStatus {
    public static let ok: Int32 = 0
    public static let invalidArguments: Int32 = -105   // shared shape rule
    public static let bufferTooSmall: Int32 = -106     // shared ASCII-copy rule
    public static let notInstalled: Int32 = -801       // no live root generation
    public static let generationFenced: Int32 = -802   // epoch belongs to another/retired generation
    public static let sessionUnknown: Int32 = -803
    public static let stateConflict: Int32 = -804      // closed/fenced session, or write after commit
    public static let conversationUnavailable: Int32 = -805
    public static let conflict: Int32 = -806           // same-id message differs; nothing imported
    public static let invalidArchive: Int32 = -807     // version/size/shape validation failed
    public static let tooLarge: Int32 = -808           // archive beyond the 32 MiB portable ceiling
    public static let identityMismatch: Int32 = -809   // decoded id != App-supplied task id
    public static let busy: Int32 = -810               // conversation has an active durable run
    public static let hopTimeout: Int32 = -811         // bounded store hop expired before admission
    public static let storeUnavailable: Int32 = -812   // durable read/write failed (never "empty")
    public static let saturated: Int32 = -813          // live session cap
    /// The import hop was ADMITTED into the durable writer but the bounded
    /// wait expired before its outcome resolved. The writer is UNRESOLVED:
    /// the import may or may not have landed, so the App must reconcile by
    /// reading (offers are idempotent; a re-import is append-if-absent) and
    /// must NEVER auto-retry on this status alone.
    public static let outcomeUnknown: Int32 = -814
    public static let cursorExpired: Int32 = -815
    public static let `internal`: Int32 = -899
}

public enum DeviceHistoryBridgeLimits {
    /// The frozen JNI chunk bound (identical to the source-host/gateway
    /// 64 KiB contract; JNI enforces it before Swift is ever called).
    public static let maximumChunkBytes = 65_536
    public static let maximumCursorBytes = 160
    /// The portable archive ceiling (fixed iOS donor contract).
    public static let maximumArchiveBytes = DeviceConversationHistory.maximumBytes
    /// One interactive surface at a time per direction; bytes are bounded
    /// (<= 32 MiB) per session.
    public static let maximumLiveSessions = 8
    /// Worst-case offer page: 200 offers x ~1 KiB redacted title + JSON
    /// framing fits this whole-page budget.
    public static let maximumOffersReplyBytes = 256 * 1024
    /// Store hops (list/export/verify/import) use bounded waits; a late hop
    /// cleans itself up and never advertises a session.
    public static let offersHopSeconds: TimeInterval = 30
    public static let exportHopSeconds: TimeInterval = 60
    public static let importHopSeconds: TimeInterval = 60
    /// Idle sessions are swept after this much inactivity (export sessions
    /// hold up to 32 MiB in RAM, so the sweep is part of lifecycle
    /// ownership, not a convenience).
    public static let sessionIdleSeconds: TimeInterval = 900
}

// MARK: - Hop result boxes

private struct DeviceHistoryExportOutcome: Sendable {
    var status: Int32 = DeviceHistoryBridgeStatus.internal
    var data: Data?
    var page: DeviceHistoryPageMetadata?
}

private struct DeviceHistoryPageMetadata: Sendable {
    let nextCursor: String?
    let through: Int64
    let hasMore: Bool
}

private struct DeviceHistoryPageRequest: Sendable {
    let after: String?
    let through: Int64?
}

private struct DeviceHistoryImportProgress: Sendable {
    let sourcePeerID: String
    let nextCursor: String?
}

private struct DeviceHistoryImportOutcome: Sendable {
    var status: Int32 = DeviceHistoryBridgeStatus.internal
    var receipt: DeviceConversationImport?
}

/// Admission control for one detached import hop. ALL state reads/writes
/// run through synchronized methods (Swift 6: no raw lock/unlock outside
/// them, no unsynchronized peeks). `admitted` flips at the exact point the
/// durable writer is invoked; the timeout cutoff fences an UNADMITTED hop
/// (it observes the fence and never touches the writer) and reports
/// `outcomeUnknown` for an admitted one — never a false "nothing changed"
/// for an unresolved writer, never an auto-retry. The producer records the
/// late completion counters itself (no second blocking cleaner).
private final class DeviceHistoryImportHopState: @unchecked Sendable {
    private let lock = NSLock()
    private var admittedState = false
    private var fencedState = false
    private var outcomeState: DeviceHistoryImportOutcome?
    /// Set by the cutoff once it returned outcomeUnknown for an admitted
    /// hop: the producer must then record the late counters itself.
    private var abandonedState = false

    /// Admission point: true when the hop may enter the durable writer.
    func beginAdmission() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fencedState { return false }
        admittedState = true
        return true
    }

    /// Cutoff: fences an UNADMITTED hop (returns true). An admitted hop
    /// cannot be fenced; returns false so the caller answers outcomeUnknown.
    func fenceUnadmitted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if admittedState { return false }
        fencedState = true
        return true
    }

    func peekOutcome() -> DeviceHistoryImportOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return outcomeState
    }

    /// Publishes the completion BEFORE the semaphore signal. Returns true
    /// when the caller already abandoned the wait — the producer then
    /// records the late counters itself.
    func publish(_ outcome: DeviceHistoryImportOutcome) -> Bool {
        lock.lock()
        outcomeState = outcome
        let abandoned = abandonedState
        lock.unlock()
        return abandoned
    }

    /// Marks the wait as abandoned (timeout with an admitted hop).
    func markAbandoned() {
        lock.lock()
        abandonedState = true
        lock.unlock()
    }
}

// MARK: - Facade

/// Process-lifecycle owner of the device-history native surface. Mirrors the
/// established `RunOutputBridgeFacade` pattern: synchronous thread-safe
/// session table under one lock, EVERY stateful call epoch-fenced against
/// the native root readback, opaque positive Int64 tickets, bounded retired
/// memory, and counters-only stats.
public final class DeviceHistoryBridgeFacade: @unchecked Sendable {
    public static let shared = DeviceHistoryBridgeFacade()

    /// One export session: the FULL bounded archive, owned until close/sweep.
    private final class ExportSession {
        let ticket: Int64
        let createdEpoch: UInt64
        let conversationID: UUID
        let data: Data
        let page: DeviceHistoryPageMetadata?
        let createdAt: Date
        var closed = false

        init(ticket: Int64, epoch: UInt64, conversationID: UUID, data: Data,
             page: DeviceHistoryPageMetadata?) {
            self.ticket = ticket
            self.createdEpoch = epoch
            self.conversationID = conversationID
            self.data = data
            self.page = page
            self.createdAt = Date()
        }
    }

    /// One import session: the App-selected task id plus the bounded byte
    /// accumulator. Bytes live ONLY here until commit decodes+imports them.
    private final class ImportSession {
        let ticket: Int64
        let createdEpoch: UInt64
        let expectedID: UUID
        let progress: DeviceHistoryImportProgress?
        var buffer: Data
        let createdAt: Date
        var closed = false

        init(ticket: Int64, epoch: UInt64, expectedID: UUID, progress: DeviceHistoryImportProgress?) {
            self.ticket = ticket
            self.createdEpoch = epoch
            self.expectedID = expectedID
            self.progress = progress
            self.buffer = Data()
            self.buffer.reserveCapacity(64 * 1024)
            self.createdAt = Date()
        }
    }

    private let lock = NSLock()
    private var counter: Int64 = 0
    private var exports: [Int64: ExportSession] = [:]
    private var imports: [Int64: ImportSession] = [:]
    private var retired: Set<Int64> = []
    private var retiredOrder: [Int64] = []
    private var counters = (offers: 0, exportOpens: 0, exportChunks: 0,
                            exportCloses: 0, importBegins: 0, importWrites: 0,
                            importCommits: 0, importAborts: 0, fenced: 0,
                            refused: 0, swept: 0, hopsTimedOut: 0,
                            conflicts: 0, busy: 0)

    /// Trusted fixture seams (same-module only). Production never writes
    /// these; no command/envelope/JSON field can reach this lane either way.
    internal var liveEpochOverrideForTesting: UInt64?
    internal var conversationStoreOverrideForTesting: (any ConversationStore)?
    internal var busyOverrideForTesting: (@Sendable (UUID) -> Bool)?

    public init() {}

    // MARK: Epoch truth (never the caller's claim)

    private func liveEpoch() -> UInt64? {
        if let override = liveEpochOverrideForTesting { return override }
        return G02NativeRootEpoch.readback()
    }

    /// The durable ordinary conversation store of the CURRENT trusted
    /// generation, resolved through the installed run domain — exactly the
    /// composition run-output cleanup already consults. A stale/foreign
    /// epoch, a retired root or a missing generation answers nil (typed
    /// refusal). A temporary bundle never supplies history.
    private func durableConversationStore(epoch: UInt64) -> (any ConversationStore)? {
        if let override = conversationStoreOverrideForTesting { return override }
        guard liveEpoch() == epoch,
              let (domain, _) = RunDomainFacade.current(epoch: epoch) else { return nil }
        let bundle = domain.components.durable
        guard bundle.identity == .ordinary else { return nil }
        return bundle.conversations
    }

    // MARK: Sweep (stale generation + idle ownership)

    private func sweepStaleLocked(live: UInt64?) {
        let now = Date()
        for (ticket, session) in exports
        where session.createdEpoch != live || now.timeIntervalSince(session.createdAt) > DeviceHistoryBridgeLimits.sessionIdleSeconds {
            session.closed = true
            exports.removeValue(forKey: ticket)
            retireLocked(ticket)
            counters.swept += 1
        }
        for (ticket, session) in imports
        where session.createdEpoch != live || now.timeIntervalSince(session.createdAt) > DeviceHistoryBridgeLimits.sessionIdleSeconds {
            session.closed = true
            imports.removeValue(forKey: ticket)
            retireLocked(ticket)
            counters.swept += 1
        }
    }

    private func newTicketLocked() -> Int64 {
        counter &+= 1
        return counter
    }

    private func retireLocked(_ ticket: Int64) {
        retired.insert(ticket)
        retiredOrder.append(ticket)
        while retiredOrder.count > 512 { retired.remove(retiredOrder.removeFirst()) }
    }

    private func liveSessionCountLocked() -> Int { exports.count + imports.count }

    private func statusForMissingSessionLocked(_ ticket: Int64) -> Int32 {
        retired.contains(ticket) ? DeviceHistoryBridgeStatus.generationFenced
                                 : DeviceHistoryBridgeStatus.sessionUnknown
    }

    // MARK: - Offers

    /// Bounded shareable-conversation page. Positive/zero return = copied
    /// JSON length into the caller buffer; negative = typed status.
    func offers(epoch: UInt64, buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        guard capacity > 0, capacity <= DeviceHistoryBridgeLimits.maximumOffersReplyBytes else {
            return DeviceHistoryBridgeStatus.invalidArguments
        }
        guard liveEpoch() == epoch else {
            lock.lock(); counters.fenced += 1; sweepStaleLocked(live: liveEpoch()); lock.unlock()
            return epoch == 0 ? DeviceHistoryBridgeStatus.notInstalled
                              : DeviceHistoryBridgeStatus.generationFenced
        }
        guard durableConversationStore(epoch: epoch) != nil else {
            return DeviceHistoryBridgeStatus.notInstalled
        }
        let box = DeviceHistoryHopBox<Result<[DeviceHistoryOffer], DeviceHistoryLaneError>>()
        let gate = DispatchSemaphore(value: 0)
        let storeRef = durableConversationStore(epoch: epoch)
        Task.detached(priority: .userInitiated) {
            let outcome: Result<[DeviceHistoryOffer], DeviceHistoryLaneError>
            if let store = storeRef {
                outcome = await DeviceHistoryStoreLane.result { try await DeviceHistoryStoreLane.offers(store: store) }
            } else {
                outcome = .failure(.fenced)
            }
            box.publish(outcome)
            gate.signal()
        }
        let deadline = DispatchTime.now() + .milliseconds(Int(DeviceHistoryBridgeLimits.offersHopSeconds * 1000))
        var woke = gate.wait(timeout: deadline)
        while box.value == nil, woke != .timedOut {
            woke = gate.wait(timeout: deadline)
        }
        guard let result = box.value else {
            lock.lock(); counters.hopsTimedOut += 1; lock.unlock()
            return DeviceHistoryBridgeStatus.hopTimeout
        }
        // Post-hop fence: a retire/rebind during the read invalidates the page.
        guard liveEpoch() == epoch, durableConversationStore(epoch: epoch) != nil else {
            lock.lock(); counters.fenced += 1; lock.unlock()
            return DeviceHistoryBridgeStatus.generationFenced
        }
        let offers: [DeviceHistoryOffer]
        switch result {
        case .success(let value):
            offers = value
        case .failure(let error):
            return Self.status(for: error)
        }
        let (ok, json) = DeviceHistoryStoreLane.offersJSON(offers, byteBudget: Int(capacity) - 1)
        guard ok else { return DeviceHistoryBridgeStatus.bufferTooSmall }
        lock.lock(); counters.offers += 1; lock.unlock()
        return Self.copy(json, buffer: buffer, capacity: capacity)
    }

    // MARK: - Export

    func receiveCursor(
        epoch: UInt64, peerID: String, conversationID: UUID,
        buffer: UnsafeMutablePointer<CChar>?, capacity: Int32
    ) -> Int32 {
        guard capacity > 0, capacity <= DeviceHistoryBridgeLimits.maximumOffersReplyBytes else {
            return DeviceHistoryBridgeStatus.invalidArguments
        }
        guard liveEpoch() == epoch else {
            return epoch == 0 ? DeviceHistoryBridgeStatus.notInstalled : DeviceHistoryBridgeStatus.generationFenced
        }
        guard let store = durableConversationStore(epoch: epoch) else {
            return DeviceHistoryBridgeStatus.notInstalled
        }
        let box = DeviceHistoryHopBox<Result<String?, DeviceHistoryLaneError>>()
        let gate = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            let result = await DeviceHistoryStoreLane.result {
                try await DeviceHistoryStoreLane.receiveCursor(
                    store: store, peerID: peerID, conversationID: conversationID)
            }
            box.publish(result)
            gate.signal()
        }
        let deadline = DispatchTime.now() + .milliseconds(Int(DeviceHistoryBridgeLimits.offersHopSeconds * 1000))
        _ = gate.wait(timeout: deadline)
        guard let result = box.value else {
            recordHopTimeout()
            return DeviceHistoryBridgeStatus.hopTimeout
        }
        guard liveEpoch() == epoch else { return DeviceHistoryBridgeStatus.generationFenced }
        switch result {
        case .success(let cursor):
            var reply: [String: Any] = ["ok": 1, "schema": "floe.device-history.cursor.v1"]
            if let cursor { reply["cursor"] = cursor }
            return Self.copy(Self.json(reply), buffer: buffer, capacity: capacity)
        case .failure(let error):
            return Self.status(for: error)
        }
    }

    /// Opens one owned export session: the FULL portable archive is produced
    /// inside ONE bounded store hop BEFORE the ticket is advertised.
    /// Positive = opaque ticket; negative = typed status.
    func exportOpen(epoch: UInt64, conversationID: UUID) -> Int64 {
        exportOpen(epoch: epoch, conversationID: conversationID, pageRequest: nil)
    }

    func exportPageOpen(epoch: UInt64, conversationID: UUID, after: String?, through: Int64?) -> Int64 {
        exportOpen(epoch: epoch, conversationID: conversationID, pageRequest: .init(after: after, through: through))
    }

    private func exportOpen(
        epoch: UInt64, conversationID: UUID, pageRequest: DeviceHistoryPageRequest?
    ) -> Int64 {
        guard liveEpoch() == epoch else {
            lock.lock(); counters.fenced += 1; sweepStaleLocked(live: liveEpoch()); lock.unlock()
            return Int64(epoch == 0 ? DeviceHistoryBridgeStatus.notInstalled
                                    : DeviceHistoryBridgeStatus.generationFenced)
        }
        guard durableConversationStore(epoch: epoch) != nil else {
            return Int64(DeviceHistoryBridgeStatus.notInstalled)
        }
        lock.lock()
        sweepStaleLocked(live: epoch)
        guard liveSessionCountLocked() < DeviceHistoryBridgeLimits.maximumLiveSessions else {
            counters.refused += 1
            lock.unlock()
            return Int64(DeviceHistoryBridgeStatus.saturated)
        }
        lock.unlock()

        let box = DeviceHistoryHopBox<DeviceHistoryExportOutcome>()
        let gate = DispatchSemaphore(value: 0)
        let storeRef = durableConversationStore(epoch: epoch)
        Task.detached(priority: .userInitiated) {
            var outcome = DeviceHistoryExportOutcome()
            if let store = storeRef {
                do {
                    if let pageRequest {
                        let page = try await DeviceHistoryStoreLane.exportPage(
                            store: store, conversationID: conversationID, after: pageRequest.after,
                            through: pageRequest.through)
                        outcome.data = page.archive
                        outcome.page = .init(nextCursor: page.nextCursor, through: page.through, hasMore: page.hasMore)
                    } else {
                        outcome.data = try await DeviceHistoryStoreLane.exportHistory(
                            store: store, conversationID: conversationID)
                    }
                    outcome.status = DeviceHistoryBridgeStatus.ok
                } catch let error as DeviceHistoryLaneError {
                    outcome.status = Self.status(for: error)
                } catch {
                    outcome.status = DeviceHistoryBridgeStatus.storeUnavailable
                }
            } else {
                outcome.status = DeviceHistoryBridgeStatus.generationFenced
            }
            box.publish(outcome)
            gate.signal()
        }
        let deadline = DispatchTime.now() + .milliseconds(Int(DeviceHistoryBridgeLimits.exportHopSeconds * 1000))
        var woke = gate.wait(timeout: deadline)
        while box.value == nil, woke != .timedOut {
            woke = gate.wait(timeout: deadline)
        }
        guard let outcome = box.value else {
            // The hop owns no session yet; nothing to release.
            lock.lock(); counters.hopsTimedOut += 1; lock.unlock()
            return Int64(DeviceHistoryBridgeStatus.hopTimeout)
        }
        // Post-hop fence: nothing mutated, so a superseded export is refused
        // rather than advertising bytes from a retired generation.
        guard outcome.status == DeviceHistoryBridgeStatus.ok, let data = outcome.data,
              liveEpoch() == epoch, durableConversationStore(epoch: epoch) != nil else {
            lock.lock()
            if outcome.status == DeviceHistoryBridgeStatus.ok { counters.fenced += 1 }
            lock.unlock()
            return Int64(outcome.status == DeviceHistoryBridgeStatus.ok
                         ? DeviceHistoryBridgeStatus.generationFenced
                         : outcome.status)
        }
        lock.lock()
        sweepStaleLocked(live: epoch)
        guard liveSessionCountLocked() < DeviceHistoryBridgeLimits.maximumLiveSessions else {
            counters.refused += 1
            lock.unlock()
            return Int64(DeviceHistoryBridgeStatus.saturated)
        }
        let ticket = newTicketLocked()
        exports[ticket] = ExportSession(ticket: ticket, epoch: epoch,
                                        conversationID: conversationID, data: data, page: outcome.page)
        counters.exportOpens += 1
        lock.unlock()
        return ticket
    }

    func exportPageInfo(_ ticket: Int64, buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        guard ticket > 0, capacity > 0, capacity <= DeviceHistoryBridgeLimits.maximumOffersReplyBytes else {
            return DeviceHistoryBridgeStatus.invalidArguments
        }
        let epoch = liveEpoch()
        lock.lock()
        defer { lock.unlock() }
        sweepStaleLocked(live: epoch)
        guard let session = exports[ticket] else { return statusForMissingSessionLocked(ticket) }
        guard session.createdEpoch == epoch, !session.closed, let page = session.page else {
            return DeviceHistoryBridgeStatus.stateConflict
        }
        var reply: [String: Any] = [
            "ok": 1, "schema": "floe.device-history.page.v1",
            "through": page.through, "hasMore": page.hasMore,
        ]
        if let nextCursor = page.nextCursor { reply["nextCursor"] = nextCursor }
        return Self.copy(Self.json(reply), buffer: buffer, capacity: capacity)
    }

    /// Copies up to `capacity` (<= 64 KiB) archive bytes at `offset` into the
    /// caller buffer. Returns copied length, 0 for a clean EOF, or a typed
    /// negative status. A read whose session was closed or superseded
    /// mid-call is fenced at the settle and NEVER reports success.
    func exportRead(_ ticket: Int64, offset: Int64,
                    buffer: UnsafeMutablePointer<UInt8>?, capacity: Int32) -> Int32 {
        guard ticket > 0, offset >= 0, capacity > 0,
              capacity <= DeviceHistoryBridgeLimits.maximumChunkBytes,
              let buffer else { return DeviceHistoryBridgeStatus.invalidArguments }
        lock.lock()
        guard let session = exports[ticket] else {
            let status = statusForMissingSessionLocked(ticket)
            lock.unlock()
            return status
        }
        guard !session.closed else {
            lock.unlock()
            return DeviceHistoryBridgeStatus.stateConflict
        }
        let data = session.data
        let createdEpoch = session.createdEpoch
        lock.unlock()

        let size = data.count
        guard offset < size else { return 0 } // clean EOF
        let start = Int(offset)
        let count = min(Int(capacity), size - start)
        data.copyBytes(to: buffer, from: start..<(start + count))

        // Settle: never report success for a session closed/superseded
        // during the copy.
        guard liveEpoch() == createdEpoch else {
            lock.lock(); counters.fenced += 1; lock.unlock()
            return DeviceHistoryBridgeStatus.generationFenced
        }
        lock.lock()
        guard exports[ticket] != nil, exports[ticket]?.closed == false else {
            lock.unlock()
            return DeviceHistoryBridgeStatus.stateConflict
        }
        counters.exportChunks += 1
        lock.unlock()
        return Int32(count)
    }

    /// Fences the session immediately (idempotent). Idempotent for an
    /// already-closed/retired/unknown session.
    func exportClose(_ ticket: Int64) -> Int32 {
        guard ticket > 0 else { return DeviceHistoryBridgeStatus.invalidArguments }
        lock.lock()
        if let session = exports[ticket] {
            session.closed = true
            exports.removeValue(forKey: ticket)
            retireLocked(ticket)
            counters.exportCloses += 1
        }
        lock.unlock()
        return DeviceHistoryBridgeStatus.ok
    }

    // MARK: - Import

    /// Opens one bounded import session bound to the App-supplied task id.
    /// Positive = opaque ticket; negative = typed status.
    func importBegin(epoch: UInt64, expectedID: UUID) -> Int64 {
        importBegin(epoch: epoch, expectedID: expectedID, progress: nil)
    }

    func importPageBegin(epoch: UInt64, expectedID: UUID, sourcePeerID: String, nextCursor: String?) -> Int64 {
        importBegin(epoch: epoch, expectedID: expectedID,
                    progress: .init(sourcePeerID: sourcePeerID, nextCursor: nextCursor))
    }

    private func importBegin(epoch: UInt64, expectedID: UUID, progress: DeviceHistoryImportProgress?) -> Int64 {
        guard liveEpoch() == epoch else {
            lock.lock(); counters.fenced += 1; sweepStaleLocked(live: liveEpoch()); lock.unlock()
            return Int64(epoch == 0 ? DeviceHistoryBridgeStatus.notInstalled
                                    : DeviceHistoryBridgeStatus.generationFenced)
        }
        guard durableConversationStore(epoch: epoch) != nil else {
            return Int64(DeviceHistoryBridgeStatus.notInstalled)
        }
        lock.lock()
        sweepStaleLocked(live: epoch)
        guard liveSessionCountLocked() < DeviceHistoryBridgeLimits.maximumLiveSessions else {
            counters.refused += 1
            lock.unlock()
            return Int64(DeviceHistoryBridgeStatus.saturated)
        }
        let ticket = newTicketLocked()
        imports[ticket] = ImportSession(ticket: ticket, epoch: epoch, expectedID: expectedID, progress: progress)
        counters.importBegins += 1
        lock.unlock()
        return ticket
    }

    /// Appends one bounded chunk (<= 64 KiB) to the session accumulator.
    /// The aggregate can never exceed the 32 MiB portable ceiling; a session
    /// that accepted bytes can still be aborted before commit.
    func importWrite(_ ticket: Int64, bytes: UnsafePointer<UInt8>?, length: Int32) -> Int32 {
        guard ticket > 0, length > 0, length <= DeviceHistoryBridgeLimits.maximumChunkBytes,
              let bytes else { return DeviceHistoryBridgeStatus.invalidArguments }
        lock.lock()
        guard let session = imports[ticket] else {
            let status = statusForMissingSessionLocked(ticket)
            lock.unlock()
            return status
        }
        guard !session.closed else {
            lock.unlock()
            return DeviceHistoryBridgeStatus.stateConflict
        }
        guard session.buffer.count + Int(length) <= DeviceHistoryBridgeLimits.maximumArchiveBytes else {
            counters.refused += 1
            lock.unlock()
            return DeviceHistoryBridgeStatus.tooLarge
        }
        session.buffer.append(bytes, count: Int(length))
        counters.importWrites += 1
        lock.unlock()
        return DeviceHistoryBridgeStatus.ok
    }

    /// Decodes + imports the accumulated bytes in ONE bounded store hop.
    /// The session is fenced BEFORE the hop, so commit runs exactly once per
    /// session; racing writes/aborts answer `stateConflict`/ok. The reply is
    /// the typed receipt JSON; a typed refusal carries no data.
    func importCommit(_ ticket: Int64, buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        guard capacity > 0, capacity <= DeviceHistoryBridgeLimits.maximumOffersReplyBytes,
              ticket > 0 else {
            return DeviceHistoryBridgeStatus.invalidArguments
        }
        lock.lock()
        guard let session = imports[ticket] else {
            let status = statusForMissingSessionLocked(ticket)
            lock.unlock()
            return status
        }
        guard !session.closed else {
            lock.unlock()
            return DeviceHistoryBridgeStatus.stateConflict
        }
        session.closed = true
        imports.removeValue(forKey: ticket)
        retireLocked(ticket)
        let bytes = session.buffer
        let expectedID = session.expectedID
        let createdEpoch = session.createdEpoch
        let progress = session.progress
        counters.importCommits += 1
        lock.unlock()

        let hopState = DeviceHistoryImportHopState()
        let gate = DispatchSemaphore(value: 0)
        let facade = self
        Task.detached(priority: .userInitiated) {
            var outcome = DeviceHistoryImportOutcome()
            if let store = facade.durableConversationStore(epoch: createdEpoch) {
                do {
                    // Decode + identity guard BEFORE admission: revocation-
                    // free, and a fenced hop stops here without touching the
                    // durable writer.
                    let history = try DeviceHistoryStoreLane.decodeHistory(bytes: bytes, expectedID: expectedID)
                    let hasLiveRun: @Sendable (Database) throws -> Bool
                    if let override = facade.busyOverrideForTesting {
                        hasLiveRun = { _ in override(expectedID) }
                    } else {
                        hasLiveRun = DeviceHistoryStoreLane.hasLiveRunForImport(conversationID: expectedID)
                    }
                    guard hopState.beginAdmission() else {
                        outcome.status = DeviceHistoryBridgeStatus.generationFenced
                        return facade.finishImportHop(outcome: outcome, state: hopState, gate: gate)
                    }
                    let receipt = try await DeviceHistoryStoreLane.importHistory(
                        store: store, history: history, sourcePeerID: progress?.sourcePeerID,
                        nextCursor: progress?.nextCursor, hasLiveRun: { database in
                            guard facade.liveEpoch() == createdEpoch else { throw DeviceHistoryLaneError.fenced }
                            return try hasLiveRun(database)
                        })
                    outcome.receipt = receipt
                    outcome.status = DeviceHistoryBridgeStatus.ok
                } catch let error as DeviceHistoryLaneError {
                    outcome.status = Self.status(for: error)
                } catch {
                    outcome.status = DeviceHistoryBridgeStatus.storeUnavailable
                }
            } else {
                outcome.status = DeviceHistoryBridgeStatus.generationFenced
            }
            facade.finishImportHop(outcome: outcome, state: hopState, gate: gate)
        }
        let deadline = DispatchTime.now() + .milliseconds(Int(DeviceHistoryBridgeLimits.importHopSeconds * 1000))
        var woke = gate.wait(timeout: deadline)
        var outcome = hopState.peekOutcome()
        while outcome == nil, woke != .timedOut {
            woke = gate.wait(timeout: deadline)
            outcome = hopState.peekOutcome()
        }
        if let outcome {
            guard outcome.status == DeviceHistoryBridgeStatus.ok, let receipt = outcome.receipt else {
                recordImportRefusal(outcome.status)
                return outcome.status
            }
            // Post-hop: the mutation (if any) already landed in the
            // generation's own store; retirement does not rewind SQLite, so
            // the honest receipt is returned rather than a misleading
            // fenced retry.
            let json = DeviceHistoryStoreLane.importJSON(receipt)
            return Self.copy(json, buffer: buffer, capacity: capacity)
        }
        // Cutoff: linearize against the hop's own admission point. An
        // UNADMITTED hop is fenced now and answers generationFenced WITHOUT
        // touching the writer — hopTimeout truthfully reports "nothing will
        // change". An ADMITTED hop is an unresolved durable writer: report
        // outcomeUnknown — never "nothing changed", never an auto-retry.
        recordHopTimeout()
        if hopState.fenceUnadmitted() {
            return DeviceHistoryBridgeStatus.hopTimeout
        }
        hopState.markAbandoned()
        return DeviceHistoryBridgeStatus.outcomeUnknown
    }

    /// Producer-side finish for one import hop: publishes BEFORE the signal
    /// and, when the caller already abandoned the wait, records the late
    /// counters itself — no second blocking cleaner.
    private func finishImportHop(outcome: DeviceHistoryImportOutcome,
                                 state: DeviceHistoryImportHopState,
                                 gate: DispatchSemaphore) {
        let abandoned = state.publish(outcome)
        if abandoned { recordLateImportCounters(outcome.status) }
        gate.signal()
    }

    /// Sync counter helpers (Swift 6: lock/unlock only inside synchronous
    /// methods, never raw in async closures).
    private func recordHopTimeout() {
        lock.lock(); counters.hopsTimedOut += 1; lock.unlock()
    }

    private func recordImportRefusal(_ status: Int32) {
        lock.lock()
        if status == DeviceHistoryBridgeStatus.conflict { counters.conflicts += 1 }
        if status == DeviceHistoryBridgeStatus.busy { counters.busy += 1 }
        lock.unlock()
    }

    private func recordLateImportCounters(_ status: Int32) {
        lock.lock()
        // `importCommits` already counted the admitted invocation; the late
        // path only records the typed completion the caller missed.
        if status == DeviceHistoryBridgeStatus.conflict { counters.conflicts += 1 }
        if status == DeviceHistoryBridgeStatus.busy { counters.busy += 1 }
        if status == DeviceHistoryBridgeStatus.generationFenced { counters.fenced += 1 }
        lock.unlock()
    }

    /// Aborts the session and discards its bytes (idempotent). Safe on every
    /// terminal path; commit-fenced sessions answer ok without touching the
    /// store.
    func importAbort(_ ticket: Int64) -> Int32 {
        guard ticket > 0 else { return DeviceHistoryBridgeStatus.invalidArguments }
        lock.lock()
        if let session = imports[ticket] {
            session.closed = true
            imports.removeValue(forKey: ticket)
            retireLocked(ticket)
            counters.importAborts += 1
        }
        lock.unlock()
        return DeviceHistoryBridgeStatus.ok
    }

    // MARK: - Stats / mapping

    func statsJSON() -> String {
        lock.lock()
        let value = counters
        lock.unlock()
        return Self.json([
            "ok": 1,
            "offers": value.offers, "exportOpens": value.exportOpens,
            "exportChunks": value.exportChunks, "exportCloses": value.exportCloses,
            "importBegins": value.importBegins, "importWrites": value.importWrites,
            "importCommits": value.importCommits, "importAborts": value.importAborts,
            "fenced": value.fenced, "refused": value.refused, "swept": value.swept,
            "hopsTimedOut": value.hopsTimedOut, "conflicts": value.conflicts,
            "busy": value.busy,
        ])
    }

    static func status(for error: DeviceHistoryLaneError) -> Int32 {
        switch error {
        case .unavailable: return DeviceHistoryBridgeStatus.notInstalled
        case .fenced: return DeviceHistoryBridgeStatus.generationFenced
        case .conversationUnavailable: return DeviceHistoryBridgeStatus.conversationUnavailable
        case .conflict: return DeviceHistoryBridgeStatus.conflict
        case .busy: return DeviceHistoryBridgeStatus.busy
        case .invalidArchive: return DeviceHistoryBridgeStatus.invalidArchive
        case .identityMismatch: return DeviceHistoryBridgeStatus.identityMismatch
        case .tooLarge: return DeviceHistoryBridgeStatus.tooLarge
        case .cursorExpired: return DeviceHistoryBridgeStatus.cursorExpired
        case .storeUnavailable: return DeviceHistoryBridgeStatus.storeUnavailable
        }
    }

    // MARK: - C ABI helpers (the reviewed source-host idioms)

    static func canonicalUUID(_ raw: String?) -> UUID? {
        guard let raw, !raw.isEmpty, let value = UUID(uuidString: raw) else { return nil }
        return value.uuidString.caseInsensitiveCompare(raw) == .orderedSame ? value : nil
    }

    static func json(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return DeviceHistoryNativeJSON.internalError
        }
        return text
    }

    static func copy(_ text: String, buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        let bytes = Array(text.utf8)
        guard bytes.count + 1 <= Int(capacity) else { return DeviceHistoryBridgeStatus.bufferTooSmall }
        guard let buffer else { return DeviceHistoryBridgeStatus.invalidArguments }
        for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
        buffer[bytes.count] = 0
        return Int32(bytes.count)
    }
}

/// Synchronous result box for one bounded store hop. The producer publishes
/// BEFORE signalling the gate; every read is synchronized (no data race).
private final class DeviceHistoryHopBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: Value?

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func publish(_ value: Value) {
        lock.lock()
        state = value
        lock.unlock()
    }
}

extension DeviceHistoryStoreLane {
    /// Small helper that normalizes a throwing store call into the typed
    /// lane error so the hop closures stay uniform.
    static func result<T: Sendable>(_ operation: () async throws -> T) async -> Result<T, DeviceHistoryLaneError> {
        do {
            return .success(try await operation())
        } catch let error as DeviceHistoryLaneError {
            return .failure(error)
        } catch {
            return .failure(.storeUnavailable)
        }
    }
}

// MARK: - Trusted-host C ABI (`floe_device_history_*`; Kotlin JNI only)

private func deviceHistoryReadCString(_ pointer: UnsafePointer<CChar>?, limit: Int) -> String? {
    guard let pointer else { return nil }
    let length = strnlen(pointer, limit)
    guard length > 0, length < limit else { return nil }
    return String(decoding: UnsafeRawBufferPointer(start: pointer, count: length), as: UTF8.self)
}

private func deviceHistoryReadPeer(_ pointer: UnsafePointer<CChar>?) -> String? {
    guard let peer = deviceHistoryReadCString(pointer, limit: 129),
          peer.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else { return nil }
    return peer
}

private func deviceHistoryReadCursor(_ bytes: UnsafePointer<UInt8>?, _ length: Int32) throws -> String? {
    if length == 0 && bytes == nil { return nil }
    guard let bytes, length > 0, length <= DeviceHistoryBridgeLimits.maximumCursorBytes,
          let value = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(length)), encoding: .utf8)
    else { throw DeviceHistoryLaneError.invalidArchive }
    return value
}

/// Bounded shareable-conversation page. Positive/zero return = copied JSON
/// length into the caller buffer; negative = typed status. Never
/// model-reachable; JNI host only.
@_cdecl("floe_device_history_offers")
public func floeDeviceHistoryOffers(_ epoch: UInt64,
                                    _ buffer: UnsafeMutablePointer<CChar>?,
                                    _ capacity: Int32) -> Int32 {
    DeviceHistoryBridgeFacade.shared.offers(epoch: epoch, buffer: buffer, capacity: capacity)
}

/// Opens one owned export session (full archive produced inside ONE bounded
/// store hop before the ticket is advertised). Positive = opaque ticket;
/// negative = typed status.
@_cdecl("floe_device_history_export_open")
public func floeDeviceHistoryExportOpen(_ epoch: UInt64,
                                        _ taskHex: UnsafePointer<CChar>?) -> Int64 {
    guard let conversation = DeviceHistoryBridgeFacade.canonicalUUID(
        deviceHistoryReadCString(taskHex, limit: 64)) else {
        return Int64(DeviceHistoryBridgeStatus.invalidArguments)
    }
    return DeviceHistoryBridgeFacade.shared.exportOpen(epoch: epoch, conversationID: conversation)
}

@_cdecl("floe_device_history_receive_cursor")
public func floeDeviceHistoryReceiveCursor(
    _ epoch: UInt64, _ peer: UnsafePointer<CChar>?, _ task: UnsafePointer<CChar>?,
    _ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32
) -> Int32 {
    guard let peerID = deviceHistoryReadPeer(peer),
          let conversationID = DeviceHistoryBridgeFacade.canonicalUUID(
            deviceHistoryReadCString(task, limit: 64)) else { return DeviceHistoryBridgeStatus.invalidArguments }
    return DeviceHistoryBridgeFacade.shared.receiveCursor(
        epoch: epoch, peerID: peerID, conversationID: conversationID, buffer: buffer, capacity: capacity)
}

@_cdecl("floe_device_history_export_page_open")
public func floeDeviceHistoryExportPageOpen(
    _ epoch: UInt64, _ task: UnsafePointer<CChar>?, _ after: UnsafePointer<UInt8>?,
    _ afterLength: Int32, _ through: Int64
) -> Int64 {
    guard through >= -1,
          let conversationID = DeviceHistoryBridgeFacade.canonicalUUID(
            deviceHistoryReadCString(task, limit: 64)) else { return Int64(DeviceHistoryBridgeStatus.invalidArguments) }
    do {
        return DeviceHistoryBridgeFacade.shared.exportPageOpen(
            epoch: epoch, conversationID: conversationID, after: try deviceHistoryReadCursor(after, afterLength),
            through: through == -1 ? nil : through)
    } catch {
        return Int64(DeviceHistoryBridgeStatus.invalidArguments)
    }
}

@_cdecl("floe_device_history_export_page_info")
public func floeDeviceHistoryExportPageInfo(
    _ ticket: Int64, _ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32
) -> Int32 {
    DeviceHistoryBridgeFacade.shared.exportPageInfo(ticket, buffer: buffer, capacity: capacity)
}

/// Copies up to `capacity` (<= 64 KiB) archive bytes at `offset` from the
/// session's owned buffer. Returns copied length, 0 for a clean EOF, or a
/// typed negative status.
@_cdecl("floe_device_history_export_read")
public func floeDeviceHistoryExportRead(_ ticket: Int64,
                                        _ offset: Int64,
                                        _ buffer: UnsafeMutablePointer<UInt8>?,
                                        _ capacity: Int32) -> Int32 {
    DeviceHistoryBridgeFacade.shared.exportRead(ticket, offset: offset, buffer: buffer, capacity: capacity)
}

/// Fences the export session immediately (idempotent) and releases its
/// owned bytes.
@_cdecl("floe_device_history_export_close")
public func floeDeviceHistoryExportClose(_ ticket: Int64) -> Int32 {
    DeviceHistoryBridgeFacade.shared.exportClose(ticket)
}

/// Opens one bounded import session bound to the App-supplied task id.
/// Positive = opaque ticket; negative = typed status.
@_cdecl("floe_device_history_import_begin")
public func floeDeviceHistoryImportBegin(_ epoch: UInt64,
                                         _ expectedTaskHex: UnsafePointer<CChar>?) -> Int64 {
    guard let expectedID = DeviceHistoryBridgeFacade.canonicalUUID(
        deviceHistoryReadCString(expectedTaskHex, limit: 64)) else {
        return Int64(DeviceHistoryBridgeStatus.invalidArguments)
    }
    return DeviceHistoryBridgeFacade.shared.importBegin(epoch: epoch, expectedID: expectedID)
}

@_cdecl("floe_device_history_import_page_begin")
public func floeDeviceHistoryImportPageBegin(
    _ epoch: UInt64, _ task: UnsafePointer<CChar>?, _ peer: UnsafePointer<CChar>?,
    _ nextCursor: UnsafePointer<UInt8>?, _ cursorLength: Int32
) -> Int64 {
    guard let sourcePeerID = deviceHistoryReadPeer(peer),
          let conversationID = DeviceHistoryBridgeFacade.canonicalUUID(
            deviceHistoryReadCString(task, limit: 64)) else { return Int64(DeviceHistoryBridgeStatus.invalidArguments) }
    do {
        return DeviceHistoryBridgeFacade.shared.importPageBegin(
            epoch: epoch, expectedID: conversationID, sourcePeerID: sourcePeerID,
            nextCursor: try deviceHistoryReadCursor(nextCursor, cursorLength))
    } catch {
        return Int64(DeviceHistoryBridgeStatus.invalidArguments)
    }
}

/// Appends one bounded chunk (<= 64 KiB) to the session accumulator. The
/// aggregate can never exceed the 32 MiB portable ceiling.
@_cdecl("floe_device_history_import_write")
public func floeDeviceHistoryImportWrite(_ ticket: Int64,
                                         _ bytes: UnsafePointer<UInt8>?,
                                         _ length: Int32) -> Int32 {
    DeviceHistoryBridgeFacade.shared.importWrite(ticket, bytes: bytes, length: length)
}

/// Decodes + imports the accumulated bytes in ONE bounded store hop and
/// answers the typed receipt JSON. A typed refusal carries no data; a
/// conflicting message aborts the WHOLE import before any mutation.
@_cdecl("floe_device_history_import_commit")
public func floeDeviceHistoryImportCommit(_ ticket: Int64,
                                          _ buffer: UnsafeMutablePointer<CChar>?,
                                          _ capacity: Int32) -> Int32 {
    DeviceHistoryBridgeFacade.shared.importCommit(ticket, buffer: buffer, capacity: capacity)
}

/// Aborts the import session and discards its bytes (idempotent). MUST be
/// called on every terminal path that never reaches commit.
@_cdecl("floe_device_history_import_abort")
public func floeDeviceHistoryImportAbort(_ ticket: Int64) -> Int32 {
    DeviceHistoryBridgeFacade.shared.importAbort(ticket)
}

/// Typed counters JSON only (no titles, bytes or identities).
@_cdecl("floe_device_history_stats")
public func floeDeviceHistoryStats(_ buffer: UnsafeMutablePointer<CChar>?,
                                   _ capacity: Int32) -> Int32 {
    guard capacity > 0, capacity <= DeviceHistoryBridgeLimits.maximumOffersReplyBytes else {
        return DeviceHistoryBridgeStatus.invalidArguments
    }
    return DeviceHistoryBridgeFacade.copy(DeviceHistoryBridgeFacade.shared.statsJSON(),
                                          buffer: buffer, capacity: capacity)
}
