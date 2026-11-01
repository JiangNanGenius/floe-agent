// SPDX-License-Identifier: MPL-2.0
//
// C06 host bridge `floe.calendar/13`, the trusted App provider mailbox and
// the two ordinary calendar model tools.
//
// Two directions are deliberately separate:
//
//   * Kotlin -> Swift (`SwiftCore.exchange`, schema floe.calendar/13): the
//     App controller pushes the ACTUAL permission/provider/calendar state and
//     reads/writes App-local todos. Todos live in the one original database.
//   * Swift -> Kotlin (`C06CalendarHostMailbox`): a claimed JSON ticket table
//     implemented over an additive JNI translation unit. The App lane is the
//     only code that touches CalendarContract; every ticket carries bounded
//     JSON, no Intent, no provider URL and no model-chosen path.
//
// Neither direction is a V3 command, an approval bypass or a guest execution
// route.
import Foundation
import FloeCore
import FloeTools

public enum BridgeV13 {
    public static let version = C06CalendarWire.version
    public static let schema = C06CalendarWire.schema
    public static let maximumRequestBytes = C06CalendarWire.maximumRequestBytes
    public static let maximumResponseBytes = C06CalendarWire.maximumResponseBytes
    public static let modelTools = C06CalendarWire.modelTools
    public static let operations: [String] = [
        "handshake",
        "c06.capabilities",
        "c06.calendar.availability",
        "c06.todo.list",
        "c06.todo.get",
        "c06.todo.save",
        "c06.todo.complete",
        "c06.todo.delete",
        "c06.todo.reminderPlans",
        "c06.todo.reminderDue",
        "c06.todo.markReminderShown",
    ]
}

// MARK: - Tool environment / registration

public struct C06CalendarToolEnvironment: Sendable {
    public let domain: C06CalendarDomain
    public init(domain: C06CalendarDomain = .shared) {
        self.domain = domain
    }
}

public func registerC06CalendarTools(
    environment: C06CalendarToolEnvironment = C06CalendarToolEnvironment(),
    registry: ToolRunnerRegistry = .shared
) {
    ToolCatalog.register(C06CalendarListTool.self)
    registry.register(AnyAgentTool(C06CalendarListTool(environment: environment)).withAvailability {
        C06CalendarDomain.availability.snapshot.readAvailable
    })
    ToolCatalog.register(C06CalendarUpdateTool.self)
    registry.register(AnyAgentTool(C06CalendarUpdateTool(environment: environment)).withAvailability {
        C06CalendarDomain.availability.snapshot.writeAvailable
    })
}

public func unregisterC06CalendarTools(registry: ToolRunnerRegistry = .shared) {
    registry.unregister { C06CalendarWire.modelToolNames.contains($0) }
}

// MARK: - Host mailbox status

public enum C06CalendarHostStatus {
    public static let ok: Int32 = 0
    public static let staleClaim: Int32 = -101
    public static let generationFenced: Int32 = -102
    public static let shape: Int32 = -105
    public static let oversized: Int32 = -107
    public static let cancelled: Int32 = -109
    public static let notClaimed: Int32 = -110
}

private func c06CalCopyString(
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

// MARK: - Mailbox

/// Bounded JSON ticket table for Swift -> App CalendarProvider operations.
/// One ticket is one closed operation; Kotlin claims it, performs the real
/// provider/resolver work, and completes it once.
public final class C06CalendarHostMailbox: @unchecked Sendable {
    public static let shared = C06CalendarHostMailbox()

    public static let maximumTicketBytes = 16 * 1024
    public static let maximumReplyBytes = 48 * 1024

    private final class Ticket {
        let claim: Int64
        let request: Data
        let deadline: Date
        var claimed = false
        var settled = false
        var status: Int32 = 0
        var result = Data()
        init(claim: Int64, request: Data, deadline: Date) {
            self.claim = claim
            self.request = request
            self.deadline = deadline
        }
    }

    private struct Counters {
        var submitted = 0
        var claimed = 0
        var completed = 0
        var failed = 0
        var rejects = 0
        var timeouts = 0
        var disarms = 0
    }

    private let condition = NSCondition()
    private var boundEpoch: UInt64 = 0
    private var bound = false
    private var laneReadyFlag = false
    private var closed = true
    private var tickets: [Int64: Ticket] = [:]
    private var queue: [Int64] = []
    private var nextClaim: Int64 = 1
    private var counters = Counters()
    private var retiredThroughEpoch: UInt64 = 0
    private var acknowledgedEpoch: UInt64 = 0

    public init() {}

    // MARK: Lane C ABI

    @discardableResult
    public func bind(epoch: UInt64) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard epoch > 0 else { return C06CalendarHostStatus.shape }
        if bound && !closed {
            return boundEpoch == epoch ? C06CalendarHostStatus.ok : C06CalendarHostStatus.generationFenced
        }
        guard epoch > retiredThroughEpoch else { return C06CalendarHostStatus.generationFenced }
        boundEpoch = epoch
        bound = true
        laneReadyFlag = false
        closed = false
        tickets.removeAll()
        queue.removeAll()
        counters = Counters()
        return C06CalendarHostStatus.ok
    }

    @discardableResult
    public func laneReady(epoch: UInt64) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard bound, !closed, boundEpoch == epoch else {
            return C06CalendarHostStatus.generationFenced
        }
        laneReadyFlag = true
        condition.broadcast()
        return C06CalendarHostStatus.ok
    }

    public var isReady: Bool {
        condition.lock(); defer { condition.unlock() }
        return bound && !closed && laneReadyFlag
    }

    public var epoch: UInt64? {
        condition.lock(); defer { condition.unlock() }
        return bound ? boundEpoch : nil
    }

    public func nextClaim(timeout: TimeInterval) -> Int64 {
        condition.lock()
        let deadline = Date().addingTimeInterval(max(0, min(5, timeout)))
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

    public func describe(claim: Int64) -> String? {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim], ticket.claimed, !ticket.settled else { return nil }
        return String(decoding: ticket.request, as: UTF8.self)
    }

    public func complete(claim: Int64, status: Int32, data: Data) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim], ticket.claimed, !ticket.settled else {
            counters.rejects += 1
            return Int32(C06CalendarHostStatus.notClaimed)
        }
        guard data.count <= C06CalendarHostMailbox.maximumReplyBytes else {
            counters.rejects += 1
            return Int32(C06CalendarHostStatus.oversized)
        }
        ticket.status = status
        ticket.result = data
        ticket.settled = true
        counters.completed += 1
        if status != C06CalendarHostStatus.ok { counters.failed += 1 }
        condition.broadcast()
        return 0
    }

    public func shouldStop(claim: Int64) -> Bool {
        condition.lock(); defer { condition.unlock() }
        if closed { return true }
        guard let ticket = tickets[claim], ticket.claimed else { return true }
        return ticket.settled || Date() >= ticket.deadline
    }

    /// Root retirement: stop admission and settle every queued ticket as
    /// cancelled, then wait for the lane's `laneClosed(epoch)` acknowledgement.
    public func closeAll(timeout: TimeInterval) -> Bool {
        condition.lock()
        let laneWasReady = laneReadyFlag
        closed = true
        laneReadyFlag = false
        let epoch = boundEpoch
        retiredThroughEpoch = max(retiredThroughEpoch, epoch)
        for claim in queue {
            if let ticket = tickets[claim], !ticket.settled {
                ticket.status = C06CalendarHostStatus.cancelled
                ticket.settled = true
            }
        }
        queue.removeAll()
        condition.broadcast()
        let deadline = Date().addingTimeInterval(max(0.2, timeout))
        while laneWasReady && Date() < deadline && acknowledgedEpoch < epoch {
            _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.05)))
        }
        let drained = !laneWasReady || acknowledgedEpoch >= epoch
        condition.unlock()
        return drained
    }

    @discardableResult
    public func laneClosed(epoch: UInt64) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard bound, boundEpoch == epoch else { return C06CalendarHostStatus.generationFenced }
        laneReadyFlag = false
        closed = true
        for ticket in tickets.values where !ticket.settled {
            ticket.status = C06CalendarHostStatus.cancelled
            ticket.settled = true
        }
        tickets.removeAll()
        queue.removeAll()
        acknowledgedEpoch = max(acknowledgedEpoch, epoch)
        condition.broadcast()
        return C06CalendarHostStatus.ok
    }

    public func descriptor() -> [String: Any] {
        condition.lock(); defer { condition.unlock() }
        return [
            "bound": bound,
            "epoch": bound ? NSNumber(value: boundEpoch) : NSNull(),
            "laneReady": laneReadyFlag,
            "closed": closed,
            "queued": queue.count,
            "tickets": tickets.count,
            "submitted": counters.submitted,
            "claimed": counters.claimed,
            "completed": counters.completed,
            "failed": counters.failed,
            "rejects": counters.rejects,
            "timeouts": counters.timeouts,
            "disarms": counters.disarms,
            "acknowledgedEpoch": NSNumber(value: acknowledgedEpoch),
        ]
    }

    // MARK: Submit

    private func enqueueLocked(operation: String, fields: [String: Any],
                               deadline: Date) throws -> Int64 {
        guard bound, !closed, laneReadyFlag else {
            throw C06CalendarError(.hostUnavailable, "calendarHostLaneUnavailable", retryable: true)
        }
        var request = fields
        request["operation"] = operation
        request["claimEpoch"] = NSNumber(value: boundEpoch)
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        guard data.count <= C06CalendarHostMailbox.maximumTicketBytes else {
            throw C06CalendarError(.invalidRequest, "providerRequestTooLarge")
        }
        let claim = nextClaim
        nextClaim += 1
        tickets[claim] = Ticket(claim: claim, request: data, deadline: deadline)
        queue.append(claim)
        counters.submitted += 1
        condition.broadcast()
        return claim
    }

    func submit(
        operation: String,
        fields: [String: Any],
        timeout: TimeInterval
    ) async throws -> [String: Any] {
        condition.lock()
        let deadline = Date().addingTimeInterval(max(0.2, min(timeout, 60)))
        let claim: Int64
        do {
            claim = try enqueueLocked(operation: operation, fields: fields, deadline: deadline)
        } catch {
            condition.unlock()
            throw error
        }
        let epoch = boundEpoch
        condition.unlock()

        while true {
            if Task.isCancelled {
                condition.lock()
                if let ticket = tickets[claim], !ticket.settled {
                    ticket.settled = true
                    ticket.status = C06CalendarHostStatus.cancelled
                }
                tickets.removeValue(forKey: claim)
                queue.removeAll { $0 == claim }
                condition.unlock()
                throw CancellationError()
            }
            condition.lock()
            if let ticket = tickets[claim], ticket.settled {
                let status = ticket.status
                let result = ticket.result
                tickets.removeValue(forKey: claim)
                condition.unlock()
                if status != C06CalendarHostStatus.ok {
                    throw C06CalendarError(
                        status == C06CalendarHostStatus.cancelled ? .cancelled : .hostUnavailable,
                        "calendarHostOperationStopped"
                    )
                }
                guard let object = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any] else {
                    throw C06CalendarError(.internalFailure, "invalidHostReply")
                }
                if c06CalBool(object["ok"]) == false {
                    throw Self.providerError(object)
                }
                return object
            }
            let now = Date()
            if closed || now >= deadline || (bound && boundEpoch != epoch) {
                let timedOut = now >= deadline
                if let ticket = tickets[claim], !ticket.settled {
                    ticket.settled = true
                    ticket.status = timedOut ? C06CalendarHostStatus.cancelled : C06CalendarHostStatus.generationFenced
                }
                tickets.removeValue(forKey: claim)
                queue.removeAll { $0 == claim }
                if timedOut { counters.timeouts += 1 }
                condition.unlock()
                if timedOut {
                    throw C06CalendarError(.timedOut, "calendarHostTimedOut", retryable: false)
                }
                throw C06CalendarError(.hostUnavailable, "calendarHostUnavailable",
                                       retryable: true)
            }
            condition.unlock()
            try await Task.sleep(nanoseconds: 8_000_000)
        }
    }

    private static func providerError(_ object: [String: Any]) -> C06CalendarError {
        let raw = c06CalString(object["code"], maxBytes: 64) ?? "providerRejected"
        let code = C06CalendarErrorCode(rawValue: raw) ?? .providerRejected
        return C06CalendarError(
            code,
            c06CalString(object["reason"], maxBytes: 120) ?? raw,
            retryable: c06CalBool(object["retryable"]) ?? false,
            detail: c06CalString(object["detail"], maxBytes: 240)
        )
    }

    // MARK: Reminder operations

    func armTodo(plan: C06TodoPlan, owner: C06TodoOwner) async throws -> C06TodoReminderArmResult {
        let reply = try await submit(
            operation: "armReminder",
            fields: [
                "ownerEpoch": NSNumber(value: owner.nativeEpoch),
                "todoID": plan.todoID.uuidString.lowercased(),
                "reminderAtMillis": NSNumber(value: Int64((plan.reminderAt.timeIntervalSince1970 * 1000).rounded())),
                "dueAtMillis": NSNumber(value: Int64((plan.dueAt.timeIntervalSince1970 * 1000).rounded())),
                "occurrenceKey": plan.occurrenceKey,
                "allDay": plan.allDay,
                "timeZone": plan.timeZone,
            ],
            timeout: 10
        )
        return C06TodoReminderArmResult(
            scheduled: c06CalBool(reply["scheduled"]) ?? false,
            state: c06CalString(reply["state"], maxBytes: 32) ?? "armFailed",
            reason: c06CalString(reply["reason"], maxBytes: 120)
        )
    }

    func disarmTodo(todoID: UUID, owner: C06TodoOwner) async throws {
        _ = try await submit(
            operation: "disarmReminder",
            fields: [
                "ownerEpoch": NSNumber(value: owner.nativeEpoch),
                "todoID": todoID.uuidString.lowercased(),
            ],
            timeout: 5
        )
    }

    /// The actual occurrence stamp is recorded in the original todo store by
    /// `C06TodoDomain.markReminderShown`; this hook only updates diagnostics.
    func noteReminderShown(todoID: UUID, occurrenceKey: String, epoch: UInt64) {
        // The durable occurrence stamp lives in the original todo store. This
        // mailbox only exists for the OS wake transport.
    }
}

// MARK: - Provider port over the mailbox

public struct C06CalendarHostMailboxPort: C06CalendarProviderPort {
    public let epoch: UInt64
    public init(epoch: UInt64) {
        self.epoch = epoch
    }

    private func mailbox() throws -> C06CalendarHostMailbox {
        let mailbox = C06CalendarHostMailbox.shared
        guard mailbox.epoch == epoch else {
            throw C06CalendarError(.staleEpoch, "staleNativeEpoch")
        }
        guard mailbox.isReady else {
            throw C06CalendarError(.hostUnavailable, "calendarHostLaneUnavailable", retryable: true)
        }
        return mailbox
    }

    public func snapshot(owner: C06CalendarOwner) async throws -> C06CalendarSnapshot {
        let reply = try await mailbox().submit(
            operation: "calendars",
            fields: ["ownerEpoch": NSNumber(value: owner.nativeEpoch)],
            timeout: 15
        )
        let snapshot = try Self.snapshot(reply)
        C06CalendarDomain.availability.update(
            coreReady: true,
            providerAvailable: snapshot.providerAvailable,
            readGranted: snapshot.readGranted,
            writeGranted: snapshot.writeGranted,
            calendarCount: snapshot.calendars.count,
            writableCalendarCount: snapshot.writableCalendars.count,
            revision: snapshot.revision,
            epoch: epoch
        )
        return snapshot
    }

    public func instances(
        owner: C06CalendarOwner,
        start: Date,
        end: Date,
        calendarID: Int64?,
        query: String?,
        limit: Int,
        offset: Int
    ) async throws -> C06CalendarHostPage {
        var fields: [String: Any] = [
            "ownerEpoch": NSNumber(value: owner.nativeEpoch),
            "startMillis": NSNumber(value: Int64((start.timeIntervalSince1970 * 1000).rounded())),
            "endMillis": NSNumber(value: Int64((end.timeIntervalSince1970 * 1000).rounded())),
            "limit": limit,
            "offset": offset,
        ]
        if let calendarID { fields["calendarID"] = NSNumber(value: calendarID) }
        if let query, !query.isEmpty { fields["query"] = query }
        let reply = try await mailbox().submit(operation: "instances", fields: fields, timeout: 20)
        return try Self.page(reply)
    }

    public func event(id: Int64, owner: C06CalendarOwner) async throws -> C06CalendarEvent {
        let reply = try await mailbox().submit(
            operation: "event",
            fields: [
                "ownerEpoch": NSNumber(value: owner.nativeEpoch),
                "eventID": NSNumber(value: id),
            ],
            timeout: 15
        )
        guard let object = reply["event"] as? [String: Any] else {
            throw C06CalendarError(.invalidRequest, "missingEvent")
        }
        return try Self.event(object)
    }

    public func create(
        owner: C06CalendarOwner,
        calendarID: Int64,
        title: String,
        start: Date,
        end: Date,
        allDay: Bool,
        timeZone: String,
        notes: String?,
        location: String?,
        recurrence: String?
    ) async throws -> C06CalendarReceipt {
        var fields: [String: Any] = [
            "ownerEpoch": NSNumber(value: owner.nativeEpoch),
            "calendarID": NSNumber(value: calendarID),
            "title": title,
            "startMillis": NSNumber(value: Int64((start.timeIntervalSince1970 * 1000).rounded())),
            "endMillis": NSNumber(value: Int64((end.timeIntervalSince1970 * 1000).rounded())),
            "allDay": allDay,
            "timeZone": timeZone,
        ]
        if let notes { fields["notes"] = notes }
        if let location { fields["location"] = location }
        if let recurrence { fields["recurrence"] = recurrence }
        do {
            let reply = try await mailbox().submit(operation: "create", fields: fields, timeout: 30)
            return try Self.receipt(reply)
        } catch let error as C06CalendarError where error.code == .timedOut {
            throw C06CalendarError(.mutationUnknown, "calendarCreateOutcomeUnknown", retryable: false)
        }
    }

    public func update(
        owner: C06CalendarOwner,
        eventID: Int64,
        occurrenceStart: Date?,
        span: String,
        patch: C06CalendarEventPatch
    ) async throws -> C06CalendarReceipt {
        var fields: [String: Any] = [
            "ownerEpoch": NSNumber(value: owner.nativeEpoch),
            "eventID": NSNumber(value: eventID),
            "span": span,
        ]
        if let occurrenceStart {
            fields["occurrenceStartMillis"] = NSNumber(
                value: Int64((occurrenceStart.timeIntervalSince1970 * 1000).rounded()))
        }
        if let title = patch.title { fields["title"] = title }
        if let start = patch.start {
            fields["startMillis"] = NSNumber(value: Int64((start.timeIntervalSince1970 * 1000).rounded()))
        }
        if let end = patch.end {
            fields["endMillis"] = NSNumber(value: Int64((end.timeIntervalSince1970 * 1000).rounded()))
        }
        if let notes = patch.notes { fields["notes"] = notes }
        if let location = patch.location { fields["location"] = location }
        if let allDay = patch.allDay { fields["allDay"] = allDay }
        if let timeZone = patch.timeZone { fields["timeZone"] = timeZone }
        if let recurrence = patch.recurrence { fields["recurrence"] = recurrence }
        do {
            let reply = try await mailbox().submit(operation: "update", fields: fields, timeout: 30)
            return try Self.receipt(reply)
        } catch let error as C06CalendarError where error.code == .timedOut {
            throw C06CalendarError(.mutationUnknown, "calendarUpdateOutcomeUnknown", retryable: false)
        }
    }

    public func delete(
        owner: C06CalendarOwner,
        eventID: Int64,
        occurrenceStart: Date?,
        span: String
    ) async throws -> C06CalendarReceipt {
        var fields: [String: Any] = [
            "ownerEpoch": NSNumber(value: owner.nativeEpoch),
            "eventID": NSNumber(value: eventID),
            "span": span,
        ]
        if let occurrenceStart {
            fields["occurrenceStartMillis"] = NSNumber(
                value: Int64((occurrenceStart.timeIntervalSince1970 * 1000).rounded()))
        }
        do {
            let reply = try await mailbox().submit(operation: "delete", fields: fields, timeout: 30)
            return try Self.receipt(reply)
        } catch let error as C06CalendarError where error.code == .timedOut {
            throw C06CalendarError(.mutationUnknown, "calendarDeleteOutcomeUnknown", retryable: false)
        }
    }

    // MARK: Reply parsing

    private static func snapshot(_ object: [String: Any]) throws -> C06CalendarSnapshot {
        let calendars: [C06CalendarSummary] = (object["calendars"] as? [[String: Any]] ?? []).compactMap {
            row in
            guard let id = c06CalInt64(row["id"]),
                  let displayName = c06CalString(row["displayName"], maxBytes: 160) else {
                return nil
            }
            return C06CalendarSummary(
                id: id,
                displayName: displayName,
                accountName: c06CalString(row["accountName"], maxBytes: 160) ?? "",
                accountType: c06CalString(row["accountType"], maxBytes: 80) ?? "",
                ownerAccount: c06CalString(row["ownerAccount"], maxBytes: 160) ?? "",
                timeZone: c06CalString(row["timeZone"], maxBytes: 64) ?? "UTC",
                color: c06CalInt(row["color"]) ?? 0,
                accessLevel: c06CalInt(row["accessLevel"]) ?? 0,
                writable: c06CalBool(row["writable"]) ?? false,
                visible: c06CalBool(row["visible"]) ?? true,
                isPrimary: c06CalBool(row["isPrimary"]) ?? false
            )
        }
        guard let providerAvailable = c06CalBool(object["providerAvailable"]),
              let readGranted = c06CalBool(object["readGranted"]),
              let writeGranted = c06CalBool(object["writeGranted"]) else {
            throw C06CalendarError(.internalFailure, "invalidCalendarSnapshot")
        }
        return C06CalendarSnapshot(
            providerAvailable: providerAvailable,
            readGranted: readGranted,
            writeGranted: writeGranted,
            calendars: calendars,
            revision: c06CalInt64(object["revision"]) ?? 0
        )
    }

    private static func event(_ object: [String: Any]) throws -> C06CalendarEvent {
        guard let eventID = c06CalInt64(object["eventID"]),
              let calendarID = c06CalInt64(object["calendarID"]),
              let title = c06CalString(object["title"], maxBytes: 512),
              let startMillis = c06CalInt64(object["startMillis"]),
              let endMillis = c06CalInt64(object["endMillis"]) else {
            throw C06CalendarError(.internalFailure, "invalidCalendarEvent")
        }
        return C06CalendarEvent(
            eventID: eventID,
            calendarID: calendarID,
            calendarName: c06CalString(object["calendarName"], maxBytes: 160) ?? "",
            title: title,
            start: Date(timeIntervalSince1970: TimeInterval(startMillis) / 1000),
            end: Date(timeIntervalSince1970: TimeInterval(endMillis) / 1000),
            allDay: c06CalBool(object["allDay"]) ?? false,
            timeZone: c06CalString(object["timeZone"], maxBytes: 64) ?? "UTC",
            location: c06CalString(object["location"], maxBytes: 512),
            notes: c06CalString(object["notes"], maxBytes: 8192),
            recurrence: c06CalString(object["recurrence"], maxBytes: 1024),
            originalInstanceTime: c06CalInt64(object["originalInstanceTimeMillis"]).map {
                Date(timeIntervalSince1970: TimeInterval($0) / 1000)
            },
            status: c06CalString(object["status"], maxBytes: 32),
            deleted: c06CalBool(object["deleted"]) ?? false
        )
    }

    private static func page(_ object: [String: Any]) throws -> C06CalendarHostPage {
        let rows = try (object["rows"] as? [[String: Any]] ?? []).map { try event($0) }
        return C06CalendarHostPage(
            rows: rows,
            hasMore: c06CalBool(object["hasMore"]) ?? false,
            totalCount: c06CalInt(object["totalCount"]) ?? rows.count
        )
    }

    private static func receipt(_ object: [String: Any]) throws -> C06CalendarReceipt {
        guard let receipt = object["receipt"] as? [String: Any],
              let action = c06CalString(receipt["action"], maxBytes: 16),
              let eventID = c06CalInt64(receipt["eventID"]),
              let calendarID = c06CalInt64(receipt["calendarID"]),
              let verified = c06CalBool(receipt["readbackVerified"]) else {
            throw C06CalendarError(.internalFailure, "invalidCalendarReceipt")
        }
        let fields = (receipt["verifiedFields"] as? [String] ?? [])
            .compactMap { c06CalString($0, maxBytes: 48) }
        return C06CalendarReceipt(
            action: action,
            eventID: eventID,
            calendarID: calendarID,
            occurrenceStart: c06CalInt64(receipt["occurrenceStartMillis"]).map {
                Date(timeIntervalSince1970: TimeInterval($0) / 1000)
            },
            deleted: c06CalBool(receipt["deleted"]) ?? false,
            readbackVerified: verified,
            verificationScope: c06CalString(receipt["verificationScope"], maxBytes: 32) ?? "targetOccurrence",
            verifiedFields: fields
        )
    }
}

// MARK: - Kotlin -> Swift bridge

public enum C06CalendarBridge {
    public static func handle(requestData: Data, fallbackRequestID: String?) -> [String: Any] {
        var requestID = fallbackRequestID
        func fail(_ error: C06CalendarError, operation: String?) -> [String: Any] {
            var value = failure(error, operation: operation)
            if let requestID { value["requestID"] = requestID }
            return value
        }
        guard requestData.count <= C06CalendarWire.maximumRequestBytes else {
            return fail(C06CalendarError(.invalidRequest, "requestTooLarge"), operation: nil)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any],
              let version = c06CalInt(object["version"]),
              version == BridgeV13.version,
              let operation = c06CalString(object["operation"], maxBytes: 64) else {
            return fail(C06CalendarError(.invalidRequest, "invalidRequest"), operation: nil)
        }
        requestID = c06CalString(object["requestID"], maxBytes: 256) ?? requestID

        do {
            switch operation {
            case "handshake", "c06.capabilities":
                return reply(
                    capabilitiesJSON(),
                    operation: operation,
                    requestID: requestID
                )

            case "c06.calendar.availability":
                return reply(try handleAvailability(object), operation: operation, requestID: requestID)

            case "c06.todo.list":
                return reply(try bridgeResult(todoList(object), operation: operation),
                             operation: operation, requestID: requestID)
            case "c06.todo.get":
                return reply(try bridgeResult(todoGet(object), operation: operation),
                             operation: operation, requestID: requestID)
            case "c06.todo.save":
                return reply(try bridgeResult(todoSave(object), operation: operation),
                             operation: operation, requestID: requestID)
            case "c06.todo.complete":
                return reply(try bridgeResult(todoComplete(object), operation: operation),
                             operation: operation, requestID: requestID)
            case "c06.todo.delete":
                return reply(try bridgeResult(todoDelete(object), operation: operation),
                             operation: operation, requestID: requestID)
            case "c06.todo.reminderPlans":
                return reply(try bridgeResult(todoReminderPlans(object), operation: operation),
                             operation: operation, requestID: requestID)
            case "c06.todo.reminderDue":
                return reply(try bridgeResult(todoReminderDue(object), operation: operation),
                             operation: operation, requestID: requestID)
            case "c06.todo.markReminderShown":
                return reply(try bridgeResult(todoMarkReminderShown(object), operation: operation),
                             operation: operation, requestID: requestID)

            default:
                throw C06CalendarError(.unsupportedOperation, "unsupportedOperation")
            }
        } catch let error as C06CalendarError {
            return fail(error, operation: operation)
        } catch let error as C06TodoError {
            return fail(
                C06CalendarError(
                    C06CalendarErrorCode(rawValue: error.code.rawValue) ?? .internalFailure,
                    error.reason,
                    retryable: error.retryable
                ),
                operation: operation
            )
        } catch {
            return fail(C06CalendarError(.internalFailure, "calendarBridgeFailed"), operation: operation)
        }
    }

    private static func capabilitiesJSON() -> [String: Any] {
        let availability = C06CalendarDomain.availability.snapshot
        let todos = C06TodoDomain.availability.snapshot
        return [
            "ok": true,
            "schema": C06CalendarWire.schema,
            "version": BridgeV13.version,
            "calendar": [
                "readAvailable": availability.readAvailable,
                "writeAvailable": availability.writeAvailable,
                "providerAvailable": availability.providerAvailable,
                "readGranted": availability.readGranted,
                "writeGranted": availability.writeGranted,
                "calendarCount": availability.calendarCount,
                "writableCalendarCount": availability.writableCalendarCount,
                "revision": availability.revision,
                "epoch": availability.epoch.map { NSNumber(value: $0) } ?? NSNull(),
            ],
            "todos": [
                "available": todos.available,
                "count": todos.count,
                "epoch": todos.epoch.map { NSNumber(value: $0) } ?? NSNull(),
            ],
            "limits": [
                "maximumRangeDays": C06CalendarWire.maximumRangeDays,
                "maximumEventLimit": C06CalendarWire.maximumEventLimit,
                "maximumTitleBytes": C06CalendarWire.maximumTitleBytes,
                "maximumNotesBytes": C06CalendarWire.maximumNotesBytes,
                "maximumTodoList": C06TodoWire.maximumList,
            ],
            "modelTools": C06CalendarWire.modelTools,
        ]
    }

    private static func handleAvailability(_ object: [String: Any]) throws -> [String: Any] {
        guard let owner = try? C06CalendarOwner.parse(object["owner"]),
              let revision = c06CalInt64(object["revision"]),
              let provider = c06CalBool(object["providerAvailable"]),
              let read = c06CalBool(object["readGranted"]),
              let write = c06CalBool(object["writeGranted"]),
              let calendarCount = c06CalInt(object["calendarCount"]),
              let writable = c06CalInt(object["writableCalendarCount"]) else {
            throw C06CalendarError(.invalidRequest, "invalidAvailability")
        }
        C06CalendarDomain.availability.update(
            coreReady: true,
            providerAvailable: provider,
            readGranted: read,
            writeGranted: write,
            calendarCount: calendarCount,
            writableCalendarCount: writable,
            revision: revision,
            epoch: owner.nativeEpoch
        )
        return [
            "ok": true,
            "schema": C06CalendarWire.schema,
            "revision": revision,
            "readAvailable": C06CalendarDomain.availability.snapshot.readAvailable,
            "writeAvailable": C06CalendarDomain.availability.snapshot.writeAvailable,
        ]
    }

    private static func reply(_ value: [String: Any], operation: String,
                              requestID: String?) -> [String: Any] {
        var object = value
        object["ok"] = object["ok"] ?? true
        object["operation"] = operation
        object["schema"] = C06CalendarWire.schema
        if let requestID { object["requestID"] = requestID }
        guard JSONSerialization.isValidJSONObject(object),
              let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              encoded.count <= C06CalendarWire.maximumResponseBytes else {
            return failure(C06CalendarError(.responseTooLarge, "responseTooLarge"), operation: operation)
        }
        return object
    }

    private static func failure(_ error: C06CalendarError, operation: String?) -> [String: Any] {
        var value: [String: Any] = [
            "ok": false,
            "code": error.code.rawValue,
            "reason": error.reason,
            "retryable": error.retryable,
            "schema": C06CalendarWire.schema,
        ]
        if let operation { value["operation"] = operation }
        if let detail = error.detail { value["detail"] = detail }
        return value
    }

    private static func bridgeResult(_ operation: @escaping @Sendable () async throws -> [String: Any],
                                     operation name: String) throws -> [String: Any] {
        // Bridge calls originate on the JNI thread; the domain is an actor.
        // DispatchSemaphore mirrors the established C06 mail bridge and keeps
        // one bounded call per request.
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task {
            do {
                box.set(.success(try await operation()))
            } catch let error as C06CalendarError {
                box.set(.failure(error))
            } catch let error as C06TodoError {
                box.set(.failure(C06CalendarError(
                    C06CalendarErrorCode(rawValue: error.code.rawValue) ?? .internalFailure,
                    error.reason,
                    retryable: error.retryable
                )))
            } catch {
                box.set(.failure(C06CalendarError(.internalFailure, "operationFailed")))
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + .seconds(20)) == .timedOut {
            return failure(C06CalendarError(.timedOut, "operationTimedOut", retryable: false),
                           operation: name)
        }
        switch box.get() {
        case .success(let value):
            return value
        case .failure(let error):
            return failure(error, operation: name)
        case .none:
            return failure(C06CalendarError(.internalFailure, "missingOperationResult"),
                           operation: name)
        }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<[String: Any], C06CalendarError>?
        func set(_ result: Result<[String: Any], C06CalendarError>) {
            lock.lock(); value = result; lock.unlock()
        }
        func get() -> Result<[String: Any], C06CalendarError>? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    // MARK: Todo bridge helpers

    private static func todoOwner(_ object: [String: Any]) throws -> C06TodoOwner {
        guard let value = object["owner"] else {
            throw C06TodoError(.invalidOwner, "missingOwner")
        }
        return try C06TodoOwner.parse(value)
    }

    private static func todoList(_ object: [String: Any]) throws -> @Sendable () async throws -> [String: Any] {
        let owner = try todoOwner(object)
        let include = c06CalBool(object["includeCompleted"]) ?? false
        let limit = c06CalInt(object["limit"]) ?? 50
        let offset = c06CalInt(object["offset"]) ?? 0
        return {
            let page = try await C06TodoDomain.shared.list(
                owner: owner,
                includeCompleted: include,
                limit: limit,
                offset: offset
            )
            return todoListProjection(rows: page.rows, total: page.total,
                                      offset: offset, includeCompleted: include)
        }
    }

    /// Page by actual serialized bytes, not merely the requested row count.
    /// The host advances by emitted rows, keeping every retained todo reachable.
    static func todoListProjection(rows: [C06TodoRecord], total: Int, offset: Int,
                                   includeCompleted: Bool) -> [String: Any] {
        // Reserve the complete response envelope, correlation ID and version.
        let rowBudget = C06CalendarWire.maximumResponseBytes - 2_048
        var values: [[String: Any]] = []
        var bytes = 0
        for record in rows {
            let value = todoJSON(record, includeNotes: false, listRow: true)
            guard let encoded = try? JSONSerialization.data(withJSONObject: value,
                                                            options: [.sortedKeys]),
                  bytes + encoded.count + 1 <= rowBudget else { break }
            values.append(value)
            bytes += encoded.count + 1
        }
        let next = offset + values.count
        return [
            "todos": values,
            "total": total,
            "offset": offset,
            "includeCompleted": includeCompleted,
            "nextOffset": next < total && !values.isEmpty ? next as Any : NSNull(),
        ]
    }

    private static func todoGet(_ object: [String: Any]) throws -> @Sendable () async throws -> [String: Any] {
        let owner = try todoOwner(object)
        guard let raw = object["id"] as? String, let id = UUID(uuidString: raw) else {
            throw C06TodoError(.invalidRequest, "invalidTodoID")
        }
        return {
            let record = try await C06TodoDomain.shared.get(owner: owner, id: id)
            return ["todo": todoJSON(record)]
        }
    }

    private static func todoSave(_ object: [String: Any]) throws -> @Sendable () async throws -> [String: Any] {
        let owner = try todoOwner(object)
        let action = c06CalString(object["action"], maxBytes: 16) ?? "create"
        guard action == "create" || action == "update" else {
            throw C06TodoError(.invalidRequest, "invalidTodoAction")
        }
        let id: UUID?
        if let raw = object["id"] as? String {
            guard let parsed = UUID(uuidString: raw) else {
                throw C06TodoError(.invalidRequest, "invalidTodoID")
            }
            id = parsed
        } else {
            id = nil
        }
        if action == "update" && (id == nil || c06CalInt(object["expectedRevision"]) == nil) {
            throw C06TodoError(.invalidRequest, "updateRequiresIDAndRevision")
        }
        guard let title = c06CalString(object["title"], maxBytes: C06TodoWire.maximumTitleBytes) else {
            throw C06TodoError(.invalidTitle, "titleRequired")
        }
        if object["notes"] != nil && object["notes"] is String,
           ((object["notes"] as? String)?.utf8.count ?? 0) > C06TodoWire.maximumNotesBytes {
            throw C06TodoError(.invalidNotes, "notesTooLong")
        }
        let notes = c06CalString(object["notes"], maxBytes: C06TodoWire.maximumNotesBytes) ?? ""
        let due: Date?
        if let raw = object["dueAt"] as? String, !raw.isEmpty {
            due = try C06CalendarDate.parseISO8601(raw)
        } else {
            due = nil
        }
        let recurrenceRaw = c06CalString(object["recurrence"], maxBytes: 16) ?? "none"
        guard let kind = C06TodoRecurrenceKind(rawValue: recurrenceRaw) else {
            throw C06TodoError(.invalidRecurrence, "invalidRecurrenceKind")
        }
        let until: Date?
        if let raw = object["recurrenceUntil"] as? String, !raw.isEmpty {
            until = try C06CalendarDate.parseISO8601(raw)
        } else {
            until = nil
        }
        let recurrence = C06TodoRecurrence(
            kind: kind,
            interval: c06CalInt(object["recurrenceInterval"]) ?? 1,
            until: until
        )
        let allDay = c06CalBool(object["allDay"]) ?? false
        let zone = c06CalString(object["timezone"], maxBytes: 64)
        let reminder = c06CalInt(object["reminderMinutesBefore"])
        let expected = c06CalInt(object["expectedRevision"])
        return {
            let result = try await C06TodoDomain.shared.save(
                owner: owner,
                id: id,
                expectedRevision: expected,
                title: title,
                notes: notes,
                dueAt: due,
                allDay: allDay,
                timeZone: zone,
                recurrence: recurrence,
                reminderMinutesBefore: reminder
            )
            return [
                "todo": todoJSON(result.record),
                "plan": result.plan.map(planJSON) ?? NSNull(),
                "reminder": reminderJSON(result.reminder),
            ]
        }
    }

    private static func todoComplete(_ object: [String: Any]) throws -> @Sendable () async throws -> [String: Any] {
        let owner = try todoOwner(object)
        guard let raw = object["id"] as? String, let id = UUID(uuidString: raw),
              let revision = c06CalInt(object["expectedRevision"]) else {
            throw C06TodoError(.invalidRequest, "invalidTodoComplete")
        }
        let completed = c06CalBool(object["completed"]) ?? true
        return {
            let result = try await C06TodoDomain.shared.complete(
                owner: owner,
                id: id,
                expectedRevision: revision,
                completed: completed
            )
            return [
                "todo": todoJSON(result.record),
                "plan": result.plan.map(planJSON) ?? NSNull(),
                "reminder": reminderJSON(result.reminder),
            ]
        }
    }

    private static func todoDelete(_ object: [String: Any]) throws -> @Sendable () async throws -> [String: Any] {
        let owner = try todoOwner(object)
        guard let raw = object["id"] as? String, let id = UUID(uuidString: raw),
              let revision = c06CalInt(object["expectedRevision"]) else {
            throw C06TodoError(.invalidRequest, "invalidTodoDelete")
        }
        return {
            try await C06TodoDomain.shared.delete(
                owner: owner,
                id: id,
                expectedRevision: revision
            )
            return ["deleted": true, "id": id.uuidString.lowercased()]
        }
    }

    private static func todoReminderPlans(_ object: [String: Any]) throws -> @Sendable () async throws -> [String: Any] {
        let owner = try todoOwner(object)
        return {
            let plans = try await C06TodoDomain.shared.reminderPlans(owner: owner)
            return ["plans": plans.map(planJSON), "count": plans.count]
        }
    }

    private static func todoReminderDue(_ object: [String: Any]) throws -> @Sendable () async throws -> [String: Any] {
        let owner = try todoOwner(object)
        guard let raw = object["id"] as? String, let id = UUID(uuidString: raw),
              let occurrence = c06CalString(object["occurrenceKey"],
                                            maxBytes: C06TodoWire.maximumOccurrenceBytes) else {
            throw C06TodoError(.invalidRequest, "invalidReminderDue")
        }
        return {
            let due = try await C06TodoDomain.shared.reminderDue(
                owner: owner,
                id: id,
                occurrenceKey: occurrence
            )
            return [
                "todo": todoJSON(due.record),
                "plan": planJSON(due.plan),
            ]
        }
    }

    private static func todoMarkReminderShown(_ object: [String: Any]) throws -> @Sendable () async throws -> [String: Any] {
        let owner = try todoOwner(object)
        guard let raw = object["id"] as? String, let id = UUID(uuidString: raw),
              let occurrence = c06CalString(object["occurrenceKey"],
                                            maxBytes: C06TodoWire.maximumOccurrenceBytes) else {
            throw C06TodoError(.invalidRequest, "invalidReminderShown")
        }
        return {
            let shown = try await C06TodoDomain.shared.markReminderShown(
                owner: owner,
                id: id,
                occurrenceKey: occurrence
            )
            return ["shown": shown]
        }
    }

    // MARK: JSON shapes

    private static func todoJSON(_ record: C06TodoRecord,
                                 includeNotes: Bool = true,
                                 listRow: Bool = false) -> [String: Any] {
        var value: [String: Any] = [
            "id": record.id.uuidString.lowercased(),
            "title": listRow ? String(record.title.prefix(80)) : record.title,
            "dueTimeZone": record.dueTimeZone,
            "allDay": record.allDay,
            "recurrence": record.recurrence.kind.rawValue,
            "recurrenceInterval": record.recurrence.interval,
            "completed": record.completed,
            "revision": record.revision,
            "createdAt": C06CalendarDate.iso8601(record.createdAt),
            "updatedAt": C06CalendarDate.iso8601(record.updatedAt),
        ]
        if includeNotes { value["notes"] = record.notes }
        if let due = record.dueAt { value["dueAt"] = C06CalendarDate.iso8601(due) }
        if let until = record.recurrence.until {
            value["recurrenceUntil"] = C06CalendarDate.iso8601(until)
        }
        if let reminder = record.reminderMinutesBefore {
            value["reminderMinutesBefore"] = reminder
        }
        if let completed = record.completedAt {
            value["completedAt"] = C06CalendarDate.iso8601(completed)
        }
        if let conversation = record.ownerConversationID {
            value["ownerConversationID"] = conversation.uuidString.lowercased()
        }
        if let task = record.ownerTaskID { value["ownerTaskID"] = task.uuidString.lowercased() }
        if let environment = record.ownerEnvironmentID { value["ownerEnvironmentID"] = environment }
        if let last = record.lastReminderAt {
            value["lastReminderAt"] = C06CalendarDate.iso8601(last)
        }
        if let occurrence = record.lastReminderOccurrence {
            value["lastReminderOccurrence"] = occurrence
        }
        return value
    }

    private static func planJSON(_ plan: C06TodoPlan) -> [String: Any] {
        [
            "todoID": plan.todoID.uuidString.lowercased(),
            "dueAt": C06CalendarDate.iso8601(plan.dueAt),
            "reminderAt": C06CalendarDate.iso8601(plan.reminderAt),
            "occurrenceKey": plan.occurrenceKey,
            "allDay": plan.allDay,
            "timeZone": plan.timeZone,
        ]
    }

    private static func reminderJSON(_ result: C06TodoReminderArmResult) -> [String: Any] {
        var value: [String: Any] = [
            "scheduled": result.scheduled,
            "state": result.state,
        ]
        if let reason = result.reason { value["reason"] = reason }
        return value
    }
}

// MARK: - Exported C ABI

@_cdecl("floe_calendar_host_bind")
public func floeCalendarHostBind(_ epoch: UInt64) -> Int32 {
    C06CalendarHostMailbox.shared.bind(epoch: epoch)
}

@_cdecl("floe_calendar_host_lane_ready")
public func floeCalendarHostLaneReady(_ epoch: UInt64) -> Int32 {
    C06CalendarHostMailbox.shared.laneReady(epoch: epoch)
}

@_cdecl("floe_calendar_host_next")
public func floeCalendarHostNext(_ timeoutMillis: Int32) -> Int64 {
    C06CalendarHostMailbox.shared.nextClaim(
        timeout: Double(max(0, min(5_000, timeoutMillis))) / 1000
    )
}

@_cdecl("floe_calendar_host_describe")
public func floeCalendarHostDescribe(
    _ claim: Int64,
    _ buffer: UnsafeMutablePointer<CChar>?,
    _ capacity: Int32
) -> Int32 {
    guard let text = C06CalendarHostMailbox.shared.describe(claim: claim) else { return -1 }
    return c06CalCopyString(text, into: buffer, capacity: capacity)
}

@_cdecl("floe_calendar_host_complete")
public func floeCalendarHostComplete(
    _ claim: Int64,
    _ status: Int32,
    _ data: UnsafePointer<UInt8>?,
    _ length: Int32
) -> Int32 {
    let payload: Data
    if let data, length > 0 {
        guard length <= C06CalendarHostMailbox.maximumReplyBytes else { return -2 }
        payload = Data(bytes: data, count: Int(length))
    } else {
        payload = Data()
    }
    return C06CalendarHostMailbox.shared.complete(claim: claim, status: status, data: payload)
}

@_cdecl("floe_calendar_host_should_stop")
public func floeCalendarHostShouldStop(_ claim: Int64) -> Int32 {
    C06CalendarHostMailbox.shared.shouldStop(claim: claim) ? 1 : 0
}

@_cdecl("floe_calendar_host_close_all")
public func floeCalendarHostCloseAll(_ timeoutMillis: Int32) -> Int32 {
    C06CalendarHostMailbox.shared.closeAll(
        timeout: Double(max(200, min(10_000, timeoutMillis))) / 1000
    ) ? 0 : 1
}

@_cdecl("floe_calendar_host_lane_closed")
public func floeCalendarHostLaneClosed(_ epoch: UInt64) -> Int32 {
    C06CalendarHostMailbox.shared.laneClosed(epoch: epoch)
}

@_cdecl("floe_calendar_host_stats")
public func floeCalendarHostStats(
    _ buffer: UnsafeMutablePointer<CChar>?,
    _ capacity: Int32
) -> Int32 {
    let value = C06CalendarHostMailbox.shared.descriptor()
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
        return -1
    }
    return c06CalCopyString(
        String(decoding: data, as: UTF8.self),
        into: buffer,
        capacity: capacity
    )
}
