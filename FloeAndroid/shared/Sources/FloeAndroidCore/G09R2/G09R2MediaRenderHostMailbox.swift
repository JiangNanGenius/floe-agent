// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — bounded MediaRenderHostMailbox (job-b72b2978320e484e).
//
// The dedicated IPC lane a later real Media3 consumer uses to claim and settle
// render tickets. It follows the reviewed `OfficeAIHostMailbox` discipline and
// the Main root-drain decision (`NATIVE_ROOT_DRAIN_REVIEW.json`):
//
//  * ONE NSLock-guarded bounded ticket table per accepted root epoch;
//  * max 2 live tickets, descriptor <= 64 KiB, reply <= 1 MiB;
//  * exactly-once settlement, claim token required by shouldStop/heartbeat/
//    complete/close, late/duplicate settlement classified and refused;
//  * a completed reply is accepted only after the NATIVE side re-verifies the
//    trusted output path/digest/size against the descriptor; a fabricated
//    receipt is refused, never published;
//  * root stop phase 1 refuses new work, cancels queued tickets and marks
//    claimed tickets cancel-requested; the generation is NOT drained until the
//    platform acknowledges each claim (or settles it) — Root must stay bound.
//
// It is IPC, not a project/task store: the R1 project host and its durable
// intents/receipts remain the only truth.
import Foundation
import FloeCore

public struct G09R2RenderDrainStatus: Sendable, Equatable {
    public let epoch: UInt64
    public let closed: Bool
    public let queued: Int
    public let claimed: Int
    public let settled: Int

    public var drained: Bool { queued == 0 && claimed == 0 }
}

public final class G09R2MediaRenderHostMailbox: @unchecked Sendable {
    public static let shared = G09R2MediaRenderHostMailbox()

    public static let claimLeaseSeconds: TimeInterval = 30
    public static let heartbeatExtensionSeconds: TimeInterval = 30
    public static let maximumSettledReplies = 32

    /// A real consumer heartbeat (from claim polling or a live ticket's
    /// heartbeat/settlement) refreshes this bounded lease. `bind` and `claim`
    /// alone are deliberately NOT proof: only an epoch-exact heartbeat does.
    public static let consumerLeaseSeconds: TimeInterval = 30

    private struct Settled {
        let reply: G09R2RenderTicketReplyDTO
        let epoch: UInt64
    }

    private final class Ticket {
        let descriptor: G09R2RenderTicketDescriptorDTO
        let descriptorData: Data
        let epoch: UInt64
        let createdAt: Date
        let hardDeadline: Date
        var state: Int = 0 // 0 queued, 1 claimed, 2 settled/removed
        var claimToken: String?
        var claimedAt: Date?
        var leaseExpiresAt: Date?
        var cancelRequested = false
        var leaseExpired = false
        var terminal: G09R2RenderTicketReplyDTO?
        var waiter: CheckedContinuation<G09R2RenderTicketReplyDTO?, Never>?
        var waiterGeneration: UInt64 = 0

        init(descriptor: G09R2RenderTicketDescriptorDTO, descriptorData: Data,
             epoch: UInt64, now: Date) {
            self.descriptor = descriptor
            self.descriptorData = descriptorData
            self.epoch = epoch
            self.createdAt = now
            self.hardDeadline = now.addingTimeInterval(600)
        }
    }

    private let condition = NSCondition()
    private var tickets: [String: Ticket] = [:]
    private var queue: [String] = []
    private var settled: [String: Settled] = [:]
    private var settledOrder: [String] = []
    private var epoch: UInt64 = 0
    private var closed = true
    private var waiterCounter: UInt64 = 0
    private var counters = (completed: 0, cancelled: 0, failed: 0,
                            lateSettle: 0, expired: 0, rejected: 0)
    private var lastErrorCode: String?
    private var consumerEpoch: UInt64 = 0
    private var consumerLeaseExpiresAt: Date = .distantPast
    private var consumerPolls: UInt64 = 0
    private var consumerRetired = false

    public init() {}

    // MARK: - Binding / root lifecycle

    public var boundEpoch: UInt64 {
        condition.lock(); defer { condition.unlock() }
        return epoch
    }

    public func isBound(to expectedEpoch: UInt64) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return !closed && epoch != 0 && epoch == expectedEpoch
    }

    public func isRootStopping(epoch expected: UInt64) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return epoch == expected && closed
    }

    /// Read-only preflight used BEFORE the creative domain switches cluster:
    /// a generation with live/claimed tickets can never be rebound underneath
    /// the platform, and a stale claim token can never retarget a newer Root.
    public func canBind(epoch newEpoch: UInt64) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return newEpoch > 0 && newEpoch > epoch && tickets.isEmpty
    }

    /// Strictly-newer positive epoch only. A generation with live/claimed
    /// tickets can never be rebound underneath the platform.
    @discardableResult
    public func bind(epoch newEpoch: UInt64) -> Bool {
        condition.lock()
        guard newEpoch > 0, newEpoch > epoch, tickets.isEmpty else {
            counters.rejected += 1
            condition.unlock()
            return false
        }
        epoch = newEpoch
        closed = false
        consumerEpoch = newEpoch
        consumerRetired = false
        // No lease yet: a later epoch-exact heartbeat proves the consumer.
        consumerLeaseExpiresAt = .distantPast
        condition.broadcast()
        condition.unlock()
        return true
    }

    /// Read-only consumer readiness lease check. TRUE only while this exact
    /// generation is still bound and the consumer has really heartbeated
    /// within the bounded lease.
    public func consumerReady(epoch expected: UInt64, now: Date = Date()) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return !closed && !consumerRetired && expected > 0 && expected == epoch &&
            consumerEpoch == expected && consumerLeaseExpiresAt > now
    }

    /// Host-only consumer heartbeat. Refreshes the readiness lease only for
    /// the CURRENTLY bound epoch; a stale epoch is refused.
    @discardableResult
    public func consumerHeartbeat(epoch expected: UInt64, now: Date = Date()) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !closed, !consumerRetired, expected > 0, expected == epoch else {
            return false
        }
        refreshConsumerLeaseLocked(now: now)
        return true
    }

    /// Platform-owner retirement: stop advertising a usable renderer for
    /// this epoch immediately. It never closes the mailbox or fabricates
    /// ticket settlement; real claimed work still drains with its tokens.
    @discardableResult
    public func consumerStop(epoch expected: UInt64) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !closed, expected > 0, expected == epoch else { return false }
        consumerRetired = true
        consumerLeaseExpiresAt = .distantPast
        return true
    }

    public func consumerStatus(epoch expected: UInt64, now: Date = Date())
        -> (ready: Bool, expiresAt: Date, polls: UInt64) {
        condition.lock(); defer { condition.unlock() }
        let ready = !closed && !consumerRetired && expected == epoch &&
            consumerEpoch == expected && consumerLeaseExpiresAt > now
        return (ready, consumerLeaseExpiresAt, consumerPolls)
    }

    /// Phase 1 of root stop. Returns TRUE only when nothing is still owned by
    /// the platform. Claimed tickets stay in the table (and keep their files)
    /// until the host acknowledges/settles them with the claim token.
    public func prepareRootStop(epoch closing: UInt64) -> Bool {
        condition.lock()
        guard closing != 0, closing == epoch else {
            condition.unlock()
            return true
        }
        guard !closed else {
            let drained = tickets.isEmpty
            condition.unlock()
            return drained
        }
        closed = true
        consumerRetired = true
        consumerLeaseExpiresAt = .distantPast
        var resumes: [CheckedContinuation<G09R2RenderTicketReplyDTO?, Never>] = []
        var unpins: [(leaseID: String, owner: String)] = []
        for token in queue {
            guard let ticket = tickets[token], ticket.state == 0 else { continue }
            let reply = reply(ticket: ticket, status: .cancelled,
                              errorCode: "renderCancelled", receipt: nil, now: Date())
            settleLocked(ticket, reply: reply, counter: .cancelled)
            unpins.append((ticket.descriptor.leaseID,
                           ticket.descriptor.ticketID))
            if let waiter = ticket.waiter {
                ticket.waiter = nil
                resumes.append(waiter)
            }
        }
        queue.removeAll()
        for ticket in tickets.values where ticket.state == 1 {
            ticket.cancelRequested = true
        }
        condition.broadcast()
        let drained = tickets.isEmpty
        condition.unlock()
        for (leaseID, owner) in unpins {
            G09R2SnapshotLeases.shared.unpin(leaseID: leaseID, owner: owner)
        }
        for waiter in resumes { waiter.resume(returning: nil) }
        return drained
    }

    public func drainStatus(epoch: UInt64) -> G09R2RenderDrainStatus {
        condition.lock(); defer { condition.unlock() }
        var queued = 0
        var claimed = 0
        if epoch == self.epoch {
            for ticket in tickets.values {
                if ticket.state == 0 { queued += 1 }
                if ticket.state == 1 { claimed += 1 }
            }
        }
        return G09R2RenderDrainStatus(
            epoch: epoch, closed: closed, queued: queued, claimed: claimed,
            settled: settled.count)
    }

    // MARK: - Ticket production (native only; no JVM submit path)

    public func submit(descriptor: G09R2RenderTicketDescriptorDTO,
                       descriptorData: Data, epoch: UInt64) throws {
        condition.lock()
        let now = Date()
        guard !closed, epoch != 0, epoch == self.epoch else {
            counters.rejected += 1
            lastErrorCode = "rendererUnavailable"
            condition.unlock()
            throw G09R2Error(.rendererUnavailable, detail: "transportUnbound")
        }
        guard descriptor.epoch == epoch,
              descriptor.descriptorVersion == 1,
              descriptor.expiresAt > now,
              descriptor.snapshotLeaseExpiresAt > now,
              descriptor.descriptorByteCount == descriptorData.count else {
            counters.rejected += 1
            condition.unlock()
            throw G09R2Error(.renderTicketExpired, detail: "descriptorInvalid")
        }
        guard descriptorData.count <= G09R2CreativeLimits.renderDescriptorBytes else {
            counters.rejected += 1
            condition.unlock()
            throw G09R2Error(.renderTicketExpired, detail: "descriptorTooLarge")
        }
        guard tickets[descriptor.ticketID] == nil else {
            counters.rejected += 1
            condition.unlock()
            throw G09R2Error(.renderTicketAlreadySettled, detail: "ticketCollision")
        }
        guard liveCountLocked() < G09R2CreativeLimits.maxLiveRenderTickets else {
            counters.rejected += 1
            lastErrorCode = "rendererUnavailable"
            condition.unlock()
            throw G09R2Error(.rendererUnavailable, detail: "ticketTableFull")
        }
        guard Self.safeRelative(descriptor.snapshotRelativePath,
                                prefix: "Workbench/Snapshots/"),
              Self.safeRelative(descriptor.outputRelativePath,
                                prefix: "Workbench/Exports/") else {
            counters.rejected += 1
            condition.unlock()
            throw G09R2Error(.renderTicketNotFound, detail: "descriptorPath")
        }
        let ticket = Ticket(descriptor: descriptor, descriptorData: descriptorData,
                            epoch: epoch, now: now)
        tickets[descriptor.ticketID] = ticket
        queue.append(descriptor.ticketID)
        condition.broadcast()
        condition.unlock()
    }

    // MARK: - Claim / inspect

    /// Blocking bounded claim used by the Kotlin IO worker. Returns the claimed
    /// envelope JSON (descriptor + claim token + timestamps), or nil on a
    /// bounded poll timeout / unbound generation.
    public func claim(timeoutMillis: Int32) -> Data? {
        let deadline = Date().addingTimeInterval(
            Double(max(0, min(Int(timeoutMillis), 5000))) / 1000)
        var resumes: [CheckedContinuation<G09R2RenderTicketReplyDTO?, Never>] = []
        var unpins: [(leaseID: String, owner: String)] = []
        defer {
            for (leaseID, owner) in unpins {
                G09R2SnapshotLeases.shared.unpin(leaseID: leaseID, owner: owner)
            }
            for waiter in resumes { waiter.resume(returning: nil) }
        }
        condition.lock()
        var claimed: ClaimedClaim?
        while true {
            if closed || epoch == 0 { break }
            expireStaleLocked(now: Date(), into: &resumes, unpins: &unpins)
            if let head = queue.first {
                queue.removeFirst()
                guard let ticket = tickets[head], ticket.state == 0 else { continue }
                let now = Date()
                guard ticket.descriptor.expiresAt > now, now < ticket.hardDeadline else {
                    let reply = reply(ticket: ticket, status: .timeout,
                                      errorCode: "renderTicketExpired",
                                      receipt: nil, now: now)
                    settleLocked(ticket, reply: reply, counter: .failed)
                    unpins.append((ticket.descriptor.leaseID,
                                   ticket.descriptor.ticketID))
                    if let waiter = ticket.waiter {
                        ticket.waiter = nil
                        resumes.append(waiter)
                    }
                    continue
                }
                let token = UUID().uuidString.lowercased()
                ticket.state = 1
                ticket.claimToken = token
                ticket.claimedAt = now
                ticket.leaseExpiresAt = min(
                    now.addingTimeInterval(Self.claimLeaseSeconds),
                    min(ticket.descriptor.expiresAt, ticket.hardDeadline))
                claimed = ClaimedClaim(ticket: ticket, token: token)
                break
            }
            if condition.wait(until: deadline) { continue }
            expireStaleLocked(now: Date(), into: &resumes, unpins: &unpins)
            break
        }
        condition.unlock()
        guard let claimed else { return nil }
        return claimedEnvelope(claimed.ticket, token: claimed.token)
    }

    public func describe(ticketID: String) -> Data? {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[ticketID], ticket.epoch == epoch, !closed else {
            return nil
        }
        return ticket.descriptorData
    }

    public func isLive(ticketID: String) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[ticketID], ticket.epoch == epoch, !closed else {
            return false
        }
        return ticket.state == 0 || ticket.state == 1
    }

    // MARK: - Claim lifecycle

    public func shouldStop(ticketID: String, claimToken: String) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[ticketID], ticket.state == 1,
              ticket.epoch == epoch else { return true }
        guard ticket.claimToken == claimToken else { return true }
        refreshConsumerLeaseLocked(now: Date())
        if closed || ticket.cancelRequested { return true }
        if let lease = ticket.leaseExpiresAt, lease <= Date() {
            ticket.cancelRequested = true
            ticket.leaseExpired = true
            return true
        }
        return Date() >= ticket.hardDeadline
    }

    /// Host-authority proof for an injected platform ticket: the presented
    /// descriptor must be byte-for-byte the native-issued one for a CURRENTLY
    /// claimed ticket with this exact claim token. Returns the native record.
    public func verifyClaim(
        ticketID: String, claimToken: String,
        descriptor: G09R2RenderTicketDescriptorDTO
    ) -> G09R2RenderTicketDescriptorDTO? {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[ticketID], ticket.state == 1,
              ticket.epoch == epoch, ticket.claimToken == claimToken,
              ticket.descriptor == descriptor else { return nil }
        return ticket.descriptor
    }

    public func heartbeat(ticketID: String, claimToken: String) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !closed, let ticket = tickets[ticketID], ticket.state == 1,
              ticket.epoch == epoch, ticket.claimToken == claimToken,
              !ticket.cancelRequested else { return false }
        refreshConsumerLeaseLocked(now: Date())
        let now = Date()
        guard now < ticket.hardDeadline, ticket.descriptor.expiresAt > now else {
            ticket.cancelRequested = true
            return false
        }
        let next = now.addingTimeInterval(Self.heartbeatExtensionSeconds)
        ticket.leaseExpiresAt = min(
            next, min(ticket.descriptor.expiresAt, ticket.hardDeadline))
        return true
    }

    /// Exactly-once settlement with the claim token. A duplicate/mismatched
    /// token returns `.claimMismatch` and never rewrites a receipt. A completed
    /// reply is verified against the trusted root/output/digest/size first; an
    /// unverifiable receipt is refused and the claim stays owned so the host
    /// can settle a truthful failure instead.
    @discardableResult
    public func complete(ticketID: String, claimToken: String,
                         replyData: Data) -> Int32 {
        guard replyData.count <= G09R2CreativeLimits.renderReplyBytes else {
            return Self.oversized
        }
        let decoded: G09R2RenderTicketReplyDTO
        do {
            decoded = try G09CreativeWire.decoder().decode(
                G09R2RenderTicketReplyDTO.self, from: replyData)
        } catch {
            return Self.invalidShape
        }
        condition.lock()
        guard let ticket = tickets[ticketID] else {
            if settled[ticketID] != nil {
                counters.lateSettle += 1
                condition.unlock()
                return Self.claimMismatch
            }
            condition.unlock()
            return Self.unknownTicket
        }
        guard ticket.state == 1 else {
            counters.lateSettle += 1
            condition.unlock()
            return Self.claimMismatch
        }
        guard ticket.epoch == epoch else {
            counters.lateSettle += 1
            condition.unlock()
            return Self.fenced
        }
        guard ticket.claimToken == claimToken else {
            condition.unlock()
            return Self.claimMismatch
        }
        refreshConsumerLeaseLocked(now: Date())
        guard ticket.terminal == nil else {
            counters.lateSettle += 1
            condition.unlock()
            return Self.claimMismatch
        }
        guard decoded.ticketID == ticketID,
              decoded.replyByteCount == replyData.count else {
            condition.unlock()
            return Self.invalidShape
        }
        switch decoded.status {
        case .completed:
            guard let receipt = decoded.receipt, decoded.errorCode == nil else {
                condition.unlock()
                return Self.invalidShape
            }
            guard verifyReceipt(receipt, ticket: ticket) else {
                lastErrorCode = "renderOutputUnverified"
                condition.unlock()
                return Self.outputUnverified
            }
        case .failed, .cancelled, .timeout, .unsupported:
            guard decoded.receipt == nil,
                  let code = decoded.errorCode,
                  Self.safeErrorCode(code) else {
                condition.unlock()
                return Self.invalidShape
            }
        }
        let terminal = decoded
        ticket.terminal = terminal
        ticket.state = 2
        if decoded.status == .completed {
            counters.completed += 1
        } else if decoded.status == .cancelled {
            counters.cancelled += 1
        } else {
            counters.failed += 1
            lastErrorCode = decoded.errorCode
        }
        let waiter = ticket.waiter
        ticket.waiter = nil
        let leaseID = ticket.descriptor.leaseID
        removeTicketLocked(ticketID, keepReply: terminal)
        condition.unlock()
        G09R2SnapshotLeases.shared.unpin(leaseID: leaseID, owner: ticketID)
        waiter?.resume(returning: terminal)
        return 0
    }

    /// Claimed close / root-drain acknowledgement. Settles the claim as
    /// cancelled exactly once; an already-settled ticket is an idempotent
    /// no-op (never a reclassification).
    @discardableResult
    public func close(ticketID: String, claimToken: String) -> Int32 {
        condition.lock()
        guard let ticket = tickets[ticketID] else {
            condition.unlock()
            return settled[ticketID] != nil ? 0 : Self.unknownTicket
        }
        guard ticket.state == 1 else {
            condition.unlock()
            return Self.claimMismatch
        }
        guard ticket.epoch == epoch else {
            condition.unlock()
            return Self.fenced
        }
        guard ticket.claimToken == claimToken else {
            condition.unlock()
            return Self.claimMismatch
        }
        refreshConsumerLeaseLocked(now: Date())
        let terminal = reply(ticket: ticket, status: .cancelled,
                             errorCode: "renderCancelled", receipt: nil, now: Date())
        ticket.terminal = terminal
        ticket.state = 2
        counters.cancelled += 1
        let waiter = ticket.waiter
        ticket.waiter = nil
        let leaseID = ticket.descriptor.leaseID
        removeTicketLocked(ticketID, keepReply: terminal)
        condition.unlock()
        G09R2SnapshotLeases.shared.unpin(leaseID: leaseID, owner: ticketID)
        waiter?.resume(returning: terminal)
        return 0
    }

    /// Native producer/root-stop cancellation. A queued ticket settles as
    /// cancelled immediately; a claimed ticket is marked cancel-requested so
    /// the real platform worker stops at its next heartbeat/shouldStop and
    /// still settles exactly once with its claim token. It never fabricates a
    /// terminal state for a live claim.
    @discardableResult
    public func cancelTicket(ticketID: String) -> Bool {
        condition.lock()
        guard let ticket = tickets[ticketID] else {
            let known = settled[ticketID] != nil
            condition.unlock()
            return known
        }
        if ticket.state == 1 {
            ticket.cancelRequested = true
            condition.broadcast()
            condition.unlock()
            return true
        }
        guard ticket.state == 0 else {
            condition.unlock()
            return true
        }
        let terminal = reply(ticket: ticket, status: .cancelled,
                             errorCode: "renderCancelled", receipt: nil,
                             now: Date())
        ticket.terminal = terminal
        ticket.state = 2
        counters.cancelled += 1
        let waiter = ticket.waiter
        ticket.waiter = nil
        let leaseID = ticket.descriptor.leaseID
        removeTicketLocked(ticketID, keepReply: terminal)
        condition.unlock()
        G09R2SnapshotLeases.shared.unpin(leaseID: leaseID, owner: ticketID)
        waiter?.resume(returning: terminal)
        return true
    }

    public func lastReply(ticketID: String) -> G09R2RenderTicketReplyDTO? {
        condition.lock(); defer { condition.unlock() }
        return settled[ticketID]?.reply
    }

    // MARK: - Await (native tool boundary, outside the creative exchange)

    /// Awaits the terminal reply for a bounded budget. Returns nil on timeout;
    /// the ticket remains owned and can still be awaited later.
    public func awaitReply(ticketID: String, timeoutMillis: Int) async throws
        -> G09R2RenderTicketReplyDTO? {
        let probe = awaitProbe(ticketID)
        if let existing = probe { return existing }
        waiterCounter &+= 1
        let generation = waiterCounter
        let deadline = Date().addingTimeInterval(
            Double(max(1, min(timeoutMillis, 60_000))) / 1000)
        return await withCheckedContinuation { continuation in
            installWaiter(ticketID: ticketID, generation: generation,
                          continuation: continuation)
            Task.detached { [weak self] in
                while Date() < deadline {
                    try? await Task.sleep(nanoseconds: 25_000_000)
                    if Task.isCancelled { return }
                }
                self?.timeoutWaiter(ticketID: ticketID, generation: generation)
            }
        }
    }

    /// Sync probe for an immediately-known terminal reply. Nil means the
    /// caller may install a waiter (or the ticket is unknown/unavailable).
    private func awaitProbe(_ ticketID: String) -> G09R2RenderTicketReplyDTO?? {
        condition.lock(); defer { condition.unlock() }
        if let existing = settled[ticketID]?.reply { return .some(existing) }
        guard let ticket = tickets[ticketID], ticket.epoch == epoch,
              ticket.waiter == nil else { return nil }
        if let terminal = ticket.terminal { return .some(terminal) }
        return nil
    }

    private func installWaiter(
        ticketID: String, generation: UInt64,
        continuation: CheckedContinuation<G09R2RenderTicketReplyDTO?, Never>
    ) {
        condition.lock()
        if let existing = settled[ticketID]?.reply {
            condition.unlock()
            continuation.resume(returning: existing)
            return
        }
        guard let ticket = tickets[ticketID] else {
            let reply = settled[ticketID]?.reply
            condition.unlock()
            continuation.resume(returning: reply)
            return
        }
        if let terminal = ticket.terminal {
            condition.unlock()
            continuation.resume(returning: terminal)
            return
        }
        guard ticket.waiter == nil else {
            condition.unlock()
            continuation.resume(returning: nil)
            return
        }
        ticket.waiter = continuation
        ticket.waiterGeneration = generation
        condition.unlock()
    }

    /// Drops a waiter that timed out without settling the ticket.
    public func timeoutWaiter(ticketID: String, generation: UInt64) {
        condition.lock()
        guard let ticket = tickets[ticketID],
              ticket.waiterGeneration == generation,
              let waiter = ticket.waiter else {
            condition.unlock()
            return
        }
        ticket.waiter = nil
        condition.unlock()
        waiter.resume(returning: nil)
    }

    // MARK: - Stats

    public func stats() -> G09R2RenderTicketStatsDTO {
        condition.lock(); defer { condition.unlock() }
        var claimed = 0
        for ticket in tickets.values where ticket.state == 1 { claimed += 1 }
        return G09R2RenderTicketStatsDTO(
            live: tickets.count,
            claimed: claimed,
            completed: counters.completed,
            cancelled: counters.cancelled,
            failed: counters.failed,
            maxLive: G09R2CreativeLimits.maxLiveRenderTickets,
            lastErrorCode: lastErrorCode)
    }

    // MARK: - Locked helpers

    private struct ClaimedClaim {
        let ticket: Ticket
        let token: String
    }

    private enum Counter { case completed, cancelled, failed }

    private func liveCountLocked() -> Int { tickets.count }

    private func reply(ticket: Ticket, status: G09R2RenderTicketReplyStatus,
                       errorCode: String?, receipt: G09R2MediaExportReceiptDTO?,
                       now: Date) -> G09R2RenderTicketReplyDTO {
        G09R2RenderTicketReplyDTO(
            ticketID: ticket.descriptor.ticketID, status: status,
            receipt: receipt, errorCode: errorCode, completedAt: now,
            replyByteCount: 0)
    }

    private func settleLocked(_ ticket: Ticket, reply: G09R2RenderTicketReplyDTO,
                              counter: Counter) {
        ticket.terminal = reply
        ticket.state = 2
        switch counter {
        case .completed: counters.completed += 1
        case .cancelled: counters.cancelled += 1
        case .failed: counters.failed += 1
        }
        removeTicketLocked(ticket.descriptor.ticketID, keepReply: reply)
    }

    private func refreshConsumerLeaseLocked(now: Date) {
        guard !closed, !consumerRetired, epoch != 0 else { return }
        consumerEpoch = epoch
        consumerLeaseExpiresAt = now.addingTimeInterval(Self.consumerLeaseSeconds)
        consumerPolls &+= 1
    }

    private func removeTicketLocked(_ ticketID: String,
                                    keepReply: G09R2RenderTicketReplyDTO) {
        tickets.removeValue(forKey: ticketID)
        queue.removeAll { $0 == ticketID }
        let stored = Settled(reply: keepReply, epoch: epoch)
        settled[ticketID] = stored
        settledOrder.append(ticketID)
        while settledOrder.count > Self.maximumSettledReplies {
            settled.removeValue(forKey: settledOrder.removeFirst())
        }
    }

    /// Queued tickets past their deadline retire as truthful timeouts; claimed
    /// tickets that miss their claim lease are marked cancel-requested but stay
    /// owned until the host acknowledges (root drain is never faked).
    private func expireStaleLocked(
        now: Date,
        into resumes: inout [CheckedContinuation<G09R2RenderTicketReplyDTO?, Never>],
        unpins: inout [(leaseID: String, owner: String)]
    ) {
        for token in queue {
            guard let ticket = tickets[token], ticket.state == 0 else { continue }
            guard ticket.descriptor.expiresAt <= now || now >= ticket.hardDeadline else {
                continue
            }
            let reply = reply(ticket: ticket, status: .timeout,
                              errorCode: "renderTicketExpired", receipt: nil, now: now)
            settleLocked(ticket, reply: reply, counter: .failed)
            unpins.append((ticket.descriptor.leaseID,
                           ticket.descriptor.ticketID))
            if let waiter = ticket.waiter {
                ticket.waiter = nil
                resumes.append(waiter)
            }
        }
        queue.removeAll { tickets[$0] == nil }
        for ticket in tickets.values where ticket.state == 1 {
            if let lease = ticket.leaseExpiresAt, lease <= now,
               !ticket.cancelRequested {
                ticket.cancelRequested = true
                ticket.leaseExpired = true
            }
        }
    }

    private func claimedEnvelope(_ ticket: Ticket, token: String) -> Data? {
        guard let descriptorObject = try? G09CreativeWire.object(ticket.descriptor) else {
            return nil
        }
        // The wire shape is {descriptor, claimToken, claimedAt, leaseExpiresAt}.
        let claimedAt = Self.iso(ticket.claimedAt ?? Date())
        let leaseExpiresAt = Self.iso(ticket.leaseExpiresAt ?? Date())
        let envelope: [String: Any] = [
            "descriptor": descriptorObject,
            "claimToken": token,
            "claimedAt": claimedAt,
            "leaseExpiresAt": leaseExpiresAt,
        ]
        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(
                withJSONObject: envelope, options: [.sortedKeys]) else { return nil }
        return data.count <= G09R2CreativeLimits.renderDescriptorBytes ? data : nil
    }

    /// Native verification of a platform "completed" receipt. The platform
    /// performed the real decode; native still refuses any path/digest/size/
    /// lease/revision mismatch or missing output bytes before publication.
    private func verifyReceipt(_ receipt: G09R2MediaExportReceiptDTO,
                               ticket: Ticket) -> Bool {
        let descriptor = ticket.descriptor
        guard receipt.binding.projectID == descriptor.projectID,
              receipt.binding.mediaRootPath == descriptor.mediaRootPath,
              receipt.binding.projectRevision == descriptor.projectRevision,
              receipt.binding.timelineDigest == descriptor.timelineDigest,
              receipt.binding.attemptID == descriptor.attemptID,
              receipt.kind == descriptor.kind,
              receipt.outputRelativePath == descriptor.outputRelativePath,
              receipt.mimeType.utf8.count <= 120,
              !receipt.mimeType.isEmpty,
              receipt.byteCount > 0,
              G09CreativeAssetHost.validDigest(receipt.sha256),
              receipt.verification.playable,
              receipt.verification.width > 0,
              receipt.verification.height > 0 else {
            return false
        }
        guard let url = G09R2MediaFoundation.containedURL(
            root: URL(fileURLWithPath: descriptor.mediaRootPath, isDirectory: true),
            relativePath: receipt.outputRelativePath) else {
            return false
        }
        guard receipt.outputRelativePath.hasPrefix("Workbench/Exports/") else {
            return false
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true,
              let size = values?.fileSize, Int64(size) == receipt.byteCount else {
            return false
        }
        guard let digest = try? FloeDigest.sha256Hex(ofFileAt: url),
              digest.caseInsensitiveCompare(receipt.sha256) == .orderedSame else {
            return false
        }
        return true
    }

    nonisolated static func safeRelative(_ value: String, prefix: String) -> Bool {
        guard G09CreativeAssetHost.safeRelativePath(value),
              value.hasPrefix(prefix) else { return false }
        let remainder = value.dropFirst(prefix.count)
        return !remainder.isEmpty && !remainder.contains("/")
    }

    nonisolated static func safeErrorCode(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 &&
            value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            }
    }

    nonisolated static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    // MARK: - Host ABI status values

    public static let ok: Int32 = 0
    public static let unknownTicket: Int32 = -101
    public static let fenced: Int32 = -102
    public static let invalidShape: Int32 = -105
    public static let bufferTooSmall: Int32 = -106
    public static let oversized: Int32 = -107
    public static let descriptorInvalid: Int32 = -108
    public static let claimMismatch: Int32 = -110
    public static let expired: Int32 = -111
    public static let outputUnverified: Int32 = -112
}

// MARK: - Trusted-host C ABI (Kotlin MediaRenderNativeTransport only)
//
// Not a V3 command, not a model tool: only a bound, epoch-exact pump can claim
// tickets. Arguments are bounded ASCII/UTF-8 tokens; bodies are copied into
// caller buffers and a too-small buffer is refused (never truncated).

private func g09r2BoundedToken(_ pointer: UnsafePointer<CChar>?,
                               limit: Int) -> String? {
    guard let pointer else { return nil }
    let length = strnlen(pointer, limit + 1)
    guard length > 0, length <= limit else { return nil }
    let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
    guard let text = String(
        bytes: UnsafeBufferPointer(start: bytes, count: length), encoding: .utf8)
    else { return nil }
    return text
}

private func g09r2CopyOut(_ data: Data, buffer: UnsafeMutablePointer<CChar>?,
                          capacity: Int32) -> Int32 {
    guard let buffer, capacity > 0 else { return G09R2MediaRenderHostMailbox.bufferTooSmall }
    guard data.count + 1 <= Int(capacity) else {
        return G09R2MediaRenderHostMailbox.bufferTooSmall
    }
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        memcpy(buffer, base, data.count)
    }
    buffer[data.count] = 0
    return Int32(data.count)
}

@_cdecl("floe_media_render_bind")
public func floeMediaRenderBind(_ epoch: UInt64) -> Int32 {
    guard epoch > 0, G02NativeRootEpoch.readback() == epoch else { return -102 }
    return G09R2MediaRenderHostMailbox.shared.bind(epoch: epoch) ? 0 : -102
}

@_cdecl("floe_media_render_consumer_heartbeat")
public func floeMediaRenderConsumerHeartbeat(_ epoch: UInt64) -> Int32 {
    guard epoch > 0 else { return G09R2MediaRenderHostMailbox.invalidShape }
    return G09R2MediaRenderHostMailbox.shared.consumerHeartbeat(epoch: epoch)
        ? G09R2MediaRenderHostMailbox.ok
        : G09R2MediaRenderHostMailbox.fenced
}

@_cdecl("floe_media_render_consumer_stop")
public func floeMediaRenderConsumerStop(_ epoch: UInt64) -> Int32 {
    guard epoch > 0 else { return G09R2MediaRenderHostMailbox.invalidShape }
    return G09R2MediaRenderHostMailbox.shared.consumerStop(epoch: epoch)
        ? G09R2MediaRenderHostMailbox.ok
        : G09R2MediaRenderHostMailbox.fenced
}

@_cdecl("floe_media_render_claim")
public func floeMediaRenderClaim(_ timeoutMillis: Int32,
                                 _ buffer: UnsafeMutablePointer<CChar>?,
                                 _ capacity: Int32) -> Int32 {
    guard let data = G09R2MediaRenderHostMailbox.shared.claim(
        timeoutMillis: timeoutMillis) else { return 0 }
    return g09r2CopyOut(data, buffer: buffer, capacity: capacity)
}

@_cdecl("floe_media_render_describe")
public func floeMediaRenderDescribe(_ ticketID: UnsafePointer<CChar>?,
                                    _ buffer: UnsafeMutablePointer<CChar>?,
                                    _ capacity: Int32) -> Int32 {
    guard let ticketID = g09r2BoundedToken(ticketID, limit: 128) else {
        return G09R2MediaRenderHostMailbox.invalidShape
    }
    guard let data = G09R2MediaRenderHostMailbox.shared.describe(ticketID: ticketID) else {
        return G09R2MediaRenderHostMailbox.unknownTicket
    }
    return g09r2CopyOut(data, buffer: buffer, capacity: capacity)
}

@_cdecl("floe_media_render_is_live")
public func floeMediaRenderIsLive(_ ticketID: UnsafePointer<CChar>?) -> Int32 {
    guard let ticketID = g09r2BoundedToken(ticketID, limit: 128) else { return 0 }
    return G09R2MediaRenderHostMailbox.shared.isLive(ticketID: ticketID) ? 1 : 0
}

@_cdecl("floe_media_render_should_stop")
public func floeMediaRenderShouldStop(_ ticketID: UnsafePointer<CChar>?,
                                      _ claimToken: UnsafePointer<CChar>?) -> Int32 {
    guard let ticketID = g09r2BoundedToken(ticketID, limit: 128),
          let claimToken = g09r2BoundedToken(claimToken, limit: 128) else {
        return 1
    }
    return G09R2MediaRenderHostMailbox.shared.shouldStop(
        ticketID: ticketID, claimToken: claimToken) ? 1 : 0
}

@_cdecl("floe_media_render_heartbeat")
public func floeMediaRenderHeartbeat(_ ticketID: UnsafePointer<CChar>?,
                                     _ claimToken: UnsafePointer<CChar>?) -> Int32 {
    guard let ticketID = g09r2BoundedToken(ticketID, limit: 128),
          let claimToken = g09r2BoundedToken(claimToken, limit: 128) else {
        return G09R2MediaRenderHostMailbox.invalidShape
    }
    return G09R2MediaRenderHostMailbox.shared.heartbeat(
        ticketID: ticketID, claimToken: claimToken) ? 0 : G09R2MediaRenderHostMailbox.expired
}

@_cdecl("floe_media_render_complete")
public func floeMediaRenderComplete(_ ticketID: UnsafePointer<CChar>?,
                                    _ claimToken: UnsafePointer<CChar>?,
                                    _ value: UnsafePointer<UInt8>?,
                                    _ valueLen: Int32) -> Int32 {
    guard let ticketID = g09r2BoundedToken(ticketID, limit: 128),
          let claimToken = g09r2BoundedToken(claimToken, limit: 128) else {
        return G09R2MediaRenderHostMailbox.invalidShape
    }
    guard valueLen >= 0, valueLen <= Int32(G09R2CreativeLimits.renderReplyBytes),
          valueLen == 0 || value != nil else {
        return G09R2MediaRenderHostMailbox.oversized
    }
    let data = valueLen == 0 ? Data() : Data(bytes: value!, count: Int(valueLen))
    return G09R2MediaRenderHostMailbox.shared.complete(
        ticketID: ticketID, claimToken: claimToken, replyData: data)
}

@_cdecl("floe_media_render_close")
public func floeMediaRenderClose(_ ticketID: UnsafePointer<CChar>?,
                                 _ claimToken: UnsafePointer<CChar>?) -> Int32 {
    guard let ticketID = g09r2BoundedToken(ticketID, limit: 128),
          let claimToken = g09r2BoundedToken(claimToken, limit: 128) else {
        return G09R2MediaRenderHostMailbox.invalidShape
    }
    return G09R2MediaRenderHostMailbox.shared.close(
        ticketID: ticketID, claimToken: claimToken)
}

@_cdecl("floe_media_render_stats")
public func floeMediaRenderStats(_ buffer: UnsafeMutablePointer<CChar>?,
                                 _ capacity: Int32) -> Int32 {
    guard let object = try? G09CreativeWire.object(
        G09R2MediaRenderHostMailbox.shared.stats()),
          JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]) else {
        return G09R2MediaRenderHostMailbox.invalidShape
    }
    return g09r2CopyOut(data, buffer: buffer, capacity: capacity)
}

/// Phase-1 root stop. 0 = drained (safe to free Root), 1 = claimed work still
/// owned (host must cancel/ack; Root stays bound), negative = stale/refused.
@_cdecl("floe_media_render_root_stop")
public func floeMediaRenderRootStop(_ epoch: UInt64) -> Int32 {
    guard epoch > 0 else { return -105 }
    if G09R2MediaRenderHostMailbox.shared.boundEpoch != 0,
       G09R2MediaRenderHostMailbox.shared.boundEpoch != epoch {
        return 0
    }
    let drained = G09R2MediaRenderHostMailbox.shared.prepareRootStop(epoch: epoch)
    return drained ? 0 : 1
}

/// Pending owned claims for an epoch (0 = drained; -102 = generation fenced).
@_cdecl("floe_media_render_drain_pending")
public func floeMediaRenderDrainPending(_ epoch: UInt64) -> Int32 {
    guard epoch > 0,
          G09R2MediaRenderHostMailbox.shared.boundEpoch == epoch else { return 0 }
    let status = G09R2MediaRenderHostMailbox.shared.drainStatus(epoch: epoch)
    return Int32(status.queued + status.claimed)
}
