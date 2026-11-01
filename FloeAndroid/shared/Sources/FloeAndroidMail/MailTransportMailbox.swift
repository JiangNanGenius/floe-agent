// SPDX-License-Identifier: MPL-2.0
//
// C06 mail transport mailbox (Swift-owned request side).
//
// Direction is the established trusted-host mailbox shape (cf. the Secret
// gateway and G07 diagnostics): Swift owns one bounded ticket table per bound
// Root epoch; the App-owned Kotlin lane claims exactly one ticket at a time,
// performs the real TCP/SSLSocket IO on an IO dispatcher, and settles the
// claim exactly once. There is no Swift -> JVM callback, no global JNI
// reference and no AttachCurrentThread.
//
// Security invariants enforced here, not by trust:
//   * a ticket can only settle the live claim; late/duplicate/stale settles
//     are typed rejections and never resume a waiter twice;
//   * no credential is ever placed in a descriptor or payload; only host,
//     port, TLS mode and protocol bytes cross this ABI;
//   * TLS/STARTTLS failure is terminal for that session; there is no
//     plaintext authentication fallback in the protocol layer;
//   * the lane is bound to the exact accepted Root epoch. Root retirement
//     closes the mailbox, cancels every session and waits for the lane's
//     close acknowledgement before reporting a drained old generation;
//   * all queues/session tables/payloads are bounded.

import Foundation

// MARK: - Status band

public enum MailTransportStatus {
    public static let ok: Int32 = 0
    public static let cancelled: Int32 = -1201
    public static let timedOut: Int32 = -1202
    public static let connectionFailed: Int32 = -1203
    public static let tlsFailed: Int32 = -1204
    public static let hostnameMismatch: Int32 = -1205
    public static let ioFailed: Int32 = -1206
    public static let closed: Int32 = -1207
    public static let tooLarge: Int32 = -1208
    public static let transportUnavailable: Int32 = -1209
    public static let protocolViolation: Int32 = -1210
    public static let internalFailure: Int32 = -1211
    public static let busy: Int32 = -1212
    public static let localNetworkPermissionRequired: Int32 = -1213

    public static func failure(_ status: Int32) -> MailFailure {
        if status == MailTransportStatus.cancelled { return .cancelled }
        if status == MailTransportStatus.timedOut { return .timedOut }
        if status == MailTransportStatus.tlsFailed
            || status == MailTransportStatus.hostnameMismatch { return .tlsFailed }
        if status == MailTransportStatus.tooLarge { return .responseTooLarge }
        if status == MailTransportStatus.transportUnavailable { return .transportUnavailable }
        if status == MailTransportStatus.protocolViolation { return .protocolRejected }
        if status == MailTransportStatus.busy { return .busy }
        if status == MailTransportStatus.localNetworkPermissionRequired {
            return .localNetworkPermissionRequired
        }
        return .connectionFailed
    }
}

// MARK: - Mailbox

public final class MailTransportMailbox: @unchecked Sendable {
    public static let shared = MailTransportMailbox()

    public enum Operation: String, Sendable {
        case open
        case upgrade
        case read
        case write
        case close
    }

    private final class Ticket {
        let claim: Int64
        let session: Int64
        let operation: Operation
        let payload: Data
        let maximumBytes: Int
        let deadline: Date
        var status: Int32 = MailTransportStatus.ok
        var result = Data()
        var claimed = false
        var settled = false
        init(
            claim: Int64,
            session: Int64,
            operation: Operation,
            payload: Data,
            maximumBytes: Int,
            deadline: Date
        ) {
            self.claim = claim
            self.session = session
            self.operation = operation
            self.payload = payload
            self.maximumBytes = maximumBytes
            self.deadline = deadline
        }
    }

    private final class Session {
        let id: Int64
        let host: String
        let port: Int
        let tls: MailTLSMode
        let createdAt = Date()
        var cancelled = false
        var currentClaim: Int64?
        var closed = false
        init(id: Int64, host: String, port: Int, tls: MailTLSMode) {
            self.id = id
            self.host = host
            self.port = port
            self.tls = tls
        }
    }

    private struct Counters {
        var submitted = 0
        var claimed = 0
        var completed = 0
        var failed = 0
        var sessionsOpened = 0
        var sessionsClosed = 0
        var lastStatus: Int32 = 0
        var rejects = 0
    }

    private let condition = NSCondition()
    private var boundEpoch: UInt64 = 0
    private var bound = false
    private var laneReadyFlag = false
    private var closed = true
    private var sessions: [Int64: Session] = [:]
    private var tickets: [Int64: Ticket] = [:]
    private var queue: [Int64] = []
    private var nextClaim: Int64 = 1
    private var nextSession: Int64 = 1
    private var counters = Counters()
    private var retiredThroughEpoch: UInt64 = 0

    public init() {}

    // MARK: Public client surface used by MailNativeWire

    /// Binds the mailbox to one accepted Root epoch. A different live epoch is
    /// refused; root retirement must close the previous generation first.
    @discardableResult
    public func bind(epoch: UInt64) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard epoch > 0 else { return MailTransportStatus.transportUnavailable }
        if bound && !closed {
            return boundEpoch == epoch ? MailTransportStatus.ok : MailTransportStatus.busy
        }
        guard epoch > retiredThroughEpoch else {
            return MailTransportStatus.transportUnavailable
        }
        boundEpoch = epoch
        bound = true
        laneReadyFlag = false
        closed = false
        sessions.removeAll()
        tickets.removeAll()
        queue.removeAll()
        counters = Counters()
        return MailTransportStatus.ok
    }

    /// The App lane reports that its poller is live for this exact epoch.
    @discardableResult
    public func laneReady(epoch: UInt64) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard bound, !closed, boundEpoch == epoch else {
            return MailTransportStatus.transportUnavailable
        }
        laneReadyFlag = true
        condition.broadcast()
        return MailTransportStatus.ok
    }

    public var isReady: Bool {
        condition.lock(); defer { condition.unlock() }
        return bound && !closed && laneReadyFlag
    }

    public var epoch: UInt64? {
        condition.lock(); defer { condition.unlock() }
        return bound ? boundEpoch : nil
    }

    /// Opens one real TCP/TLS session in the App lane. For `.startTLS` the
    /// lane opens TCP only; `upgrade` performs the TLS handshake after the
    /// protocol-level STARTTLS/STLS response.
    public func open(
        host: String,
        port: Int,
        tls: MailTLSMode,
        deadline: Date,
        cancelled: @escaping @Sendable () -> Bool
    ) throws -> Int64 {
        try validateEndpoint(host: host, port: port)
        condition.lock()
        guard bound, !closed, laneReadyFlag else {
            condition.unlock()
            throw MailFailure.transportUnavailable
        }
        let sessionID = nextSession
        nextSession += 1
        let session = Session(id: sessionID, host: host, port: port, tls: tls)
        sessions[sessionID] = session
        let claim = enqueueLocked(
            session: session,
            operation: .open,
            payload: Data(),
            maximumBytes: 0,
            deadline: deadline
        )
        condition.unlock()
        let status = try wait(claim: claim, deadline: deadline, cancelled: cancelled)
        guard status == MailTransportStatus.ok else {
            removeSession(sessionID)
            throw MailTransportStatus.failure(status)
        }
        condition.lock()
        counters.sessionsOpened += 1
        condition.unlock()
        return sessionID
    }

    public func upgrade(
        session sessionID: Int64,
        deadline: Date,
        cancelled: @escaping @Sendable () -> Bool
    ) throws {
        let status = try submitChecked(
            session: sessionID,
            operation: .upgrade,
            payload: Data(),
            maximumBytes: 0,
            deadline: deadline,
            cancelled: cancelled
        )
        guard status == MailTransportStatus.ok else {
            throw MailTransportStatus.failure(status)
        }
    }

    public func readSome(
        session sessionID: Int64,
        maximumBytes: Int,
        deadline: Date,
        cancelled: @escaping @Sendable () -> Bool
    ) throws -> Data {
        let bounded = min(max(1, maximumBytes), 64 * 1024)
        condition.lock()
        guard let session = sessions[sessionID], !session.closed else {
            condition.unlock()
            throw MailFailure.connectionFailed
        }
        let claim = enqueueLocked(
            session: session,
            operation: .read,
            payload: Data(),
            maximumBytes: bounded,
            deadline: deadline
        )
        condition.unlock()
        let status = try wait(claim: claim, deadline: deadline, cancelled: cancelled)
        guard status == MailTransportStatus.ok else {
            throw MailTransportStatus.failure(status)
        }
        condition.lock()
        let result = tickets[claim]?.result ?? Data()
        tickets.removeValue(forKey: claim)
        condition.unlock()
        guard !result.isEmpty else { throw MailFailure.connectionFailed }
        guard result.count <= bounded else { throw MailFailure.responseTooLarge }
        return result
    }

    public func write(
        session sessionID: Int64,
        data: Data,
        deadline: Date,
        cancelled: @escaping @Sendable () -> Bool
    ) throws {
        guard !data.isEmpty, data.count <= 64 * 1024 else {
            throw MailFailure.invalidMessage
        }
        let status = try submitChecked(
            session: sessionID,
            operation: .write,
            payload: data,
            maximumBytes: 0,
            deadline: deadline,
            cancelled: cancelled
        )
        guard status == MailTransportStatus.ok else {
            throw MailTransportStatus.failure(status)
        }
    }

    /// Sends an explicit CLOSE and waits for the lane's acknowledgement. The
    /// return value is the acknowledgement fact, not an inferred state.
    @discardableResult
    public func close(session sessionID: Int64, timeout: TimeInterval) -> Bool {
        cancel(session: sessionID)
        let deadline = Date().addingTimeInterval(max(0.2, timeout))
        do {
            let status = try submitChecked(
                session: sessionID,
                operation: .close,
                payload: Data(),
                maximumBytes: 0,
                deadline: deadline,
                cancelled: { false }
            )
            removeSession(sessionID)
            return status == MailTransportStatus.ok
        } catch {
            removeSession(sessionID)
            return false
        }
    }

    public func cancel(session sessionID: Int64) {
        condition.lock(); defer { condition.unlock() }
        guard let session = sessions[sessionID] else { return }
        session.cancelled = true
        condition.broadcast()
    }

    /// Cancels every live session (an explicit user Cancel). The Root-stop
    /// path uses `closeAll` instead because it must also stop the lane.
    @discardableResult
    public func cancelAllSessions() -> Int {
        condition.lock(); defer { condition.unlock() }
        var count = 0
        for session in sessions.values where !session.cancelled && !session.closed {
            session.cancelled = true
            count += 1
        }
        condition.broadcast()
        return count
    }

    /// Root retirement: stop admitting work, cancel every live session, and
    /// wait for the App lane to prove it closed its sockets. The lane exits
    /// its poll loop, closes its session map in `finally`, and calls
    /// `laneClosed(epoch:)`; only then is the old generation drained.
    public func closeAll(timeout: TimeInterval) -> Bool {
        condition.lock()
        closed = true
        laneReadyFlag = false
        let epoch = boundEpoch
        retiredThroughEpoch = max(retiredThroughEpoch, epoch)
        for session in sessions.values {
            session.cancelled = true
        }
        for claim in queue {
            if let ticket = tickets[claim], !ticket.claimed, !ticket.settled {
                ticket.status = MailTransportStatus.cancelled
                ticket.settled = true
                if let session = sessions[ticket.session] {
                    session.currentClaim = nil
                    session.closed = true
                }
            }
        }
        queue.removeAll()
        condition.broadcast()
        let deadline = Date().addingTimeInterval(max(0.2, timeout))
        while Date() < deadline {
            if sessions.values.allSatisfy({ $0.closed && $0.currentClaim == nil }) {
                sessions.removeAll()
                condition.unlock()
                return true
            }
            _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.05)))
        }
        let drained = sessions.values.allSatisfy { $0.closed && $0.currentClaim == nil }
        if drained { sessions.removeAll() }
        condition.unlock()
        return drained
    }

    /// Called by the App lane from its `finally` after all sockets are closed.
    /// This is the actual acknowledgement root retirement waits for.
    @discardableResult
    public func laneClosed(epoch: UInt64) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard bound, boundEpoch == epoch else { return MailTransportStatus.transportUnavailable }
        laneReadyFlag = false
        closed = true
        for session in sessions.values {
            session.closed = true
            session.currentClaim = nil
            session.cancelled = true
        }
        for ticket in tickets.values where !ticket.settled {
            ticket.status = MailTransportStatus.cancelled
            ticket.settled = true
        }
        tickets.removeAll()
        queue.removeAll()
        condition.broadcast()
        return MailTransportStatus.ok
    }

    public func descriptor() -> [String: Any] {
        condition.lock(); defer { condition.unlock() }
        return [
            "bound": bound,
            "epoch": bound ? NSNumber(value: boundEpoch) : NSNull(),
            "laneReady": laneReadyFlag,
            "closed": closed,
            "sessions": sessions.count,
            "queued": queue.count,
            "tickets": tickets.count,
            "submitted": counters.submitted,
            "claimed": counters.claimed,
            "completed": counters.completed,
            "failed": counters.failed,
            "sessionsOpened": counters.sessionsOpened,
            "sessionsClosed": counters.sessionsClosed,
            "rejects": counters.rejects,
            "lastStatus": counters.lastStatus,
        ]
    }

    // MARK: App-lane C ABI (also used by host tests)

    public func nextClaim(timeout: TimeInterval) -> Int64 {
        condition.lock()
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while queue.isEmpty && !closed && Date() < deadline {
            _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.05)))
        }
        guard !closed, !queue.isEmpty else {
            condition.unlock()
            return closed ? -1 : 0
        }
        let claim = queue.removeFirst()
        guard let ticket = tickets[claim] else {
            condition.unlock()
            return 0
        }
        ticket.claimed = true
        counters.claimed += 1
        condition.unlock()
        return claim
    }

    /// JSON descriptor for one claimed ticket. Bounded to 1 KiB by construction.
    public func describe(claim: Int64) -> String? {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim], ticket.claimed, !ticket.settled,
              let session = sessions[ticket.session] else { return nil }
        let timeout = max(1, min(45_000, Int(ticket.deadline.timeIntervalSinceNow * 1000)))
        let value: [String: Any] = [
            "claim": NSNumber(value: claim),
            "session": NSNumber(value: ticket.session),
            "op": ticket.operation.rawValue,
            "host": session.host,
            "port": session.port,
            "tls": session.tls.rawValue,
            "maxBytes": ticket.maximumBytes,
            "writeLength": ticket.payload.count,
            "timeoutMillis": timeout,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func takeWrite(claim: Int64, into buffer: UnsafeMutablePointer<UInt8>, capacity: Int) -> Int {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim], ticket.claimed, !ticket.settled else { return -1 }
        guard ticket.payload.count <= capacity else { return -2 }
        ticket.payload.copyBytes(to: buffer, count: ticket.payload.count)
        return ticket.payload.count
    }

    public func complete(claim: Int64, status: Int32, data: Data) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim], ticket.claimed, !ticket.settled else {
            counters.rejects += 1
            return -1
        }
        guard data.count <= 64 * 1024 else {
            counters.rejects += 1
            return -2
        }
        ticket.status = status
        ticket.result = data
        ticket.settled = true
        if let session = sessions[ticket.session] {
            session.currentClaim = nil
            if status != MailTransportStatus.ok {
                session.cancelled = true
            }
        }
        counters.completed += 1
        counters.lastStatus = status
        if status != MailTransportStatus.ok { counters.failed += 1 }
        condition.broadcast()
        return 0
    }

    public func shouldStop(claim: Int64) -> Bool {
        condition.lock(); defer { condition.unlock() }
        if closed { return true }
        guard let ticket = tickets[claim], let session = sessions[ticket.session] else { return true }
        return session.cancelled || session.closed || ticket.settled
    }

    /// Test/lane diagnostic: mark one claimed ticket settled without a real
    /// socket. Only the app-lane ABI uses this via `complete`; tests may call
    /// it to prove waiter/cancel semantics.
    @discardableResult
    public func testComplete(claim: Int64, status: Int32, data: Data = Data()) -> Int32 {
        complete(claim: claim, status: status, data: data)
    }

    /// Test helper: return a claimed ticket's payload after `describe`.
    public func testPayload(claim: Int64) -> Data? {
        condition.lock(); defer { condition.unlock() }
        return tickets[claim]?.payload
    }

    // MARK: Internals

    private func enqueueLocked(
        session: Session,
        operation: Operation,
        payload: Data,
        maximumBytes: Int,
        deadline: Date
    ) -> Int64 {
        let claim = nextClaim
        nextClaim += 1
        let ticket = Ticket(
            claim: claim,
            session: session.id,
            operation: operation,
            payload: payload,
            maximumBytes: maximumBytes,
            deadline: deadline
        )
        tickets[claim] = ticket
        session.currentClaim = claim
        queue.append(claim)
        counters.submitted += 1
        condition.broadcast()
        return claim
    }

    private func submitChecked(
        session sessionID: Int64,
        operation: Operation,
        payload: Data,
        maximumBytes: Int,
        deadline: Date,
        cancelled: @escaping @Sendable () -> Bool
    ) throws -> Int32 {
        condition.lock()
        guard bound, !closed, laneReadyFlag else {
            condition.unlock()
            throw MailFailure.transportUnavailable
        }
        guard let session = sessions[sessionID], !session.closed else {
            condition.unlock()
            throw MailFailure.connectionFailed
        }
        guard session.currentClaim == nil else {
            condition.unlock()
            throw MailFailure.busy
        }
        let claim = enqueueLocked(
            session: session,
            operation: operation,
            payload: payload,
            maximumBytes: maximumBytes,
            deadline: deadline
        )
        condition.unlock()
        return try wait(claim: claim, deadline: deadline, cancelled: cancelled)
    }

    private func wait(
        claim: Int64,
        deadline: Date,
        cancelled: @escaping @Sendable () -> Bool
    ) throws -> Int32 {
        condition.lock()
        while true {
            guard let ticket = tickets[claim] else {
                condition.unlock()
                return MailTransportStatus.cancelled
            }
            if ticket.settled {
                let status = ticket.status
                condition.unlock()
                return status
            }
            if cancelled() {
                if let session = sessions[ticket.session] {
                    session.cancelled = true
                }
                condition.broadcast()
                // Give the lane a bounded chance to settle the claim so the
                // caller's close can be acknowledged; never hold the caller
                // past its own deadline.
                let grace = Date().addingTimeInterval(0.5)
                while !ticket.settled && Date() < grace {
                    _ = condition.wait(until: min(grace, Date().addingTimeInterval(0.05)))
                }
                condition.unlock()
                return MailTransportStatus.cancelled
            }
            if Date() >= deadline {
                if let session = sessions[ticket.session] {
                    session.cancelled = true
                }
                condition.broadcast()
                condition.unlock()
                return MailTransportStatus.timedOut
            }
            _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.05)))
        }
    }

    private func removeSession(_ id: Int64) {
        condition.lock(); defer { condition.unlock() }
        if sessions.removeValue(forKey: id) != nil {
            counters.sessionsClosed += 1
        }
        for claim in queue {
            if let ticket = tickets[claim], ticket.session == id {
                ticket.status = MailTransportStatus.closed
                ticket.settled = true
            }
        }
        condition.broadcast()
    }

    private func validateEndpoint(host: String, port: Int) throws {
        // Reuse the account model's exact host/port rules without ever
        // accepting a scheme, whitespace, CR/LF or control character.
        let probe = MailServer(host: host, port: port, tls: .implicitTLS, username: "x")
        try probe.validate()
    }
}

// MARK: - C ABI used by the App-owned Kotlin lane

private func mailTransportCopyString(
    _ value: String,
    into buffer: UnsafeMutablePointer<CChar>?,
    capacity: Int32
) -> Int32 {
    guard let buffer, capacity > 0 else { return -1 }
    let bytes = Array(value.utf8)
    guard bytes.count < Int(capacity) else { return Int32(bytes.count + 1) }
    for (index, byte) in bytes.enumerated() {
        buffer[index] = CChar(bitPattern: byte)
    }
    buffer[bytes.count] = 0
    return Int32(bytes.count)
}

private func mailTransportCopyData(
    _ data: Data,
    into buffer: UnsafeMutablePointer<UInt8>?,
    capacity: Int32
) -> Int32 {
    guard let buffer, capacity >= 0 else { return -1 }
    guard data.count <= Int(capacity) else { return -2 }
    data.withUnsafeBytes { raw in
        if let base = raw.baseAddress {
            buffer.update(from: base.assumingMemoryBound(to: UInt8.self), count: data.count)
        }
    }
    return Int32(data.count)
}

@_cdecl("floe_mail_transport_bind")
public func floeMailTransportBind(_ epoch: UInt64) -> Int32 {
    MailTransportMailbox.shared.bind(epoch: epoch)
}

@_cdecl("floe_mail_transport_lane_ready")
public func floeMailTransportLaneReady(_ epoch: UInt64) -> Int32 {
    MailTransportMailbox.shared.laneReady(epoch: epoch)
}

@_cdecl("floe_mail_transport_next")
public func floeMailTransportNext(_ timeoutMillis: Int32) -> Int64 {
    MailTransportMailbox.shared.nextClaim(timeout: Double(max(0, min(5_000, timeoutMillis))) / 1000)
}

@_cdecl("floe_mail_transport_describe")
public func floeMailTransportDescribe(
    _ claim: Int64,
    _ buffer: UnsafeMutablePointer<CChar>?,
    _ capacity: Int32
) -> Int32 {
    guard let text = MailTransportMailbox.shared.describe(claim: claim) else { return -1 }
    return mailTransportCopyString(text, into: buffer, capacity: capacity)
}

@_cdecl("floe_mail_transport_take_write")
public func floeMailTransportTakeWrite(
    _ claim: Int64,
    _ buffer: UnsafeMutablePointer<UInt8>?,
    _ capacity: Int32
) -> Int32 {
    guard let buffer, capacity >= 0 else { return -1 }
    return Int32(MailTransportMailbox.shared.takeWrite(
        claim: claim, into: buffer, capacity: Int(capacity)))
}

@_cdecl("floe_mail_transport_complete")
public func floeMailTransportComplete(
    _ claim: Int64,
    _ status: Int32,
    _ data: UnsafePointer<UInt8>?,
    _ length: Int32
) -> Int32 {
    let payload: Data
    if let data, length > 0 {
        guard length <= 64 * 1024 else { return -2 }
        payload = Data(bytes: data, count: Int(length))
    } else {
        payload = Data()
    }
    return MailTransportMailbox.shared.complete(claim: claim, status: status, data: payload)
}

@_cdecl("floe_mail_transport_should_stop")
public func floeMailTransportShouldStop(_ claim: Int64) -> Int32 {
    MailTransportMailbox.shared.shouldStop(claim: claim) ? 1 : 0
}

@_cdecl("floe_mail_transport_cancel_session")
public func floeMailTransportCancelSession(_ session: Int64) -> Int32 {
    MailTransportMailbox.shared.cancel(session: session)
    return 0
}

@_cdecl("floe_mail_transport_close_all")
public func floeMailTransportCloseAll(_ timeoutMillis: Int32) -> Int32 {
    MailTransportMailbox.shared.closeAll(
        timeout: Double(max(200, min(10_000, timeoutMillis))) / 1000
    ) ? 0 : 1
}

@_cdecl("floe_mail_transport_lane_closed")
public func floeMailTransportLaneClosed(_ epoch: UInt64) -> Int32 {
    MailTransportMailbox.shared.laneClosed(epoch: epoch)
}

@_cdecl("floe_mail_transport_stats")
public func floeMailTransportStats(
    _ buffer: UnsafeMutablePointer<CChar>?,
    _ capacity: Int32
) -> Int32 {
    let value = MailTransportMailbox.shared.descriptor()
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
        return -1
    }
    return mailTransportCopyString(String(decoding: data, as: UTF8.self), into: buffer, capacity: capacity)
}
