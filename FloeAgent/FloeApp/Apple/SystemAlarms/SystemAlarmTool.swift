// FloeApp — `apple.alarm.*` tools: real system AlarmKit alarms/timers.
//
// SPDX-License-Identifier: MPL-2.0
//
// CODE-level create/list/cancel/status for genuine system alarms and timers
// through AlarmKit (iOS/iPadOS 26+). These tools NEVER claim that a system
// alarm automatically runs a model task — that is the separate, completed S4
// Agent scheduler. Here an alarm/timer is a real user-facing alert: it rings
// natively, presents a concise localized label with a real stop action, and
// does not start a run. Ownership is the caller's trusted task/run provenance
// (never a model-authored identity); list/cancel only ever touch alarms
// recorded for that provenance, and a foreign/unknown native id is refused,
// never adopted. The OS authorization prompt is not a blanket task-permission
// exemption: the temporary chat ceiling still denies every one of these
// tools, and the ordinary approval path governs the mutating calls.

#if canImport(UIKit) && canImport(AlarmKit)
import Foundation
import FloeCore
import FloeTools
import FloePersistence
import AlarmKit

// MARK: - Shared output

enum SystemAlarmOutput {
    static func make(_ summary: String, exitStatus: Int32? = 0) -> ToolExecutionOutput {
        ToolExecutionOutput(digesting: summary, exitStatus: exitStatus)
    }

    static func iso(_ date: Date) -> String { PersistenceCodec.encode(date) }

    /// Render one durable record as a bounded, privacy-safe line (opaque
    /// label digest, never the raw title).
    static func render(_ record: SystemAlarmRecord) -> String {
        var fields: [String] = []
        fields.append("id=\(record.id.uuidString)")
        fields.append("kind=\(record.kind.rawValue)")
        fields.append("state=\(record.state.rawValue)")
        if let nativeState = record.nativeState { fields.append("nativeState=\(nativeState)") }
        switch record.repeatRule {
        case .never:
            fields.append("tz=\(record.intendedTimezone)")
            if let fire = record.intendedFireDate { fields.append("fire=\(iso(fire))") }
            fields.append("repeat=never")
        case .weekly(let days):
            fields.append("tz=device")
            if let fire = record.intendedFireDate {
                let format = DateFormatter()
                format.locale = Locale(identifier: "en_US_POSIX")
                format.timeZone = TimeZone(identifier: record.intendedTimezone)
                format.dateFormat = "HH:mm"
                fields.append("wallTime=\(format.string(from: fire))")
            }
            fields.append("repeat=weekly:\(days.sorted().map(String.init).joined(separator: ","))")
        }
        if let duration = record.timerDuration {
            fields.append("duration=\(String(format: "%.0f", duration))s")
        }
        fields.append("receipt=\(record.operationReceiptID.uuidString)")
        fields.append("updated=\(iso(record.updatedAt))")
        return fields.joined(separator: " ")
    }
}

// MARK: - schedule (mutating)

struct AppleAlarmScheduleTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        /// "alarm" (wall-clock) or "timer" (countdown).
        var kind: String?
        /// Absolute ISO-8601 fire time WITH explicit offset, in `timezone`.
        var fireAt: String?
        /// IANA timezone identifier for the intended wall-clock instant.
        var timezone: String?
        /// Timer duration in whole seconds (bounded, positive).
        var durationSeconds: Int?
        /// Repeat for an alarm: "never" or comma weekdays 1...7 (Mon=1).
        var `repeat`: String?
        /// Concise user-facing label (bounded; shown on the native alert).
        var label: String?

        init(
            kind: String? = nil,
            fireAt: String? = nil,
            timezone: String? = nil,
            durationSeconds: Int? = nil,
            repeat: String? = nil,
            label: String? = nil
        ) {
            self.kind = kind
            self.fireAt = fireAt
            self.timezone = timezone
            self.durationSeconds = durationSeconds
            self.repeat = `repeat`
            self.label = label
        }
    }

    static let name = "apple.alarm.schedule"
    static let toolDescription = """
    Schedule a real system alarm or timer through AlarmKit after OS authorization. \
    kind="alarm" rings at an absolute time; kind="timer" counts down a bounded duration. \
    This creates a genuine user-facing alert that rings natively (through silent/Focus) with \
    a concise label and a Stop action — it does NOT run a model task. fireAt must be an \
    absolute ISO-8601 time with an explicit numeric offset (e.g. 2026-10-22T07:30:00+08:00) \
    interpreted in the IANA `timezone`; a repeating alarm (repeat=1..7, Monday=1) fires \
    weekly on those device-calendar weekdays, and its repeat timezone follows the \
    device/system rules. Weekly requests must use the current device timezone and zero \
    seconds; their fireAt supplies the wall-clock time, not a deferred start date. \
    They begin on the next matching weekday. Query apple.alarm.status for deviceTimezone. \
    durationSeconds is a positive whole-second countdown (max 24h). \
    The alarm is owned by this task: only this conversation/run can list, query or cancel \
    it. Requires the app in the foreground for the first OS authorization. Authorization \
    denied/unavailable, a rejected request, a returned-but-unverified schedule, and an \
    unknown (crash) outcome are all distinct — a request result is never a scheduled alarm.
    """
    static let parametersJSON = #"""
    {"type":"object","properties":{"kind":{"type":"string","enum":["alarm","timer"],"description":"alarm = wall-clock, timer = countdown."},"fireAt":{"type":"string","maxLength":40,"description":"Absolute ISO-8601 with explicit offset. For weekly repeats only the HH:mm is used, starting at the next matching device weekday; not a deferred start date."},"timezone":{"type":"string","maxLength":64,"description":"IANA timezone id. Weekly repeats require the current deviceTimezone from apple.alarm.status."},"durationSeconds":{"type":"integer","minimum":1,"maximum":86400,"description":"Positive countdown duration in whole seconds (max 24h)."},"repeat":{"type":"string","maxLength":20,"description":"never (default) or comma weekdays 1..7, Monday=1 (e.g. 1,3,5)."},"label":{"type":"string","maxLength":64,"description":"Concise user-facing label shown on the alert."}},"additionalProperties":false}
    """#
    static let riskLabels: Set<RiskLabel> = [.changesAgentBehavior]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    static let maxTimerSeconds = 86_400 // 24h

    private let service: SystemAlarmService
    private let isForeground: @Sendable () async -> Bool

    init(service: SystemAlarmService, isForeground: @escaping @Sendable () async -> Bool) {
        self.service = service
        self.isForeground = isForeground
    }

    func validate(_ args: Arguments) throws {
        _ = try Self.plan(args)
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        // Temporary chat / public-web ceiling: effectful system alarms are
        // never available there (the runtime policy also denies them; this is
        // defense in depth consistent with the other apple tools).
        guard !context.temporaryReadOnly, !context.publicWebOnly else {
            return SystemAlarmOutput.make(
                "status=unavailable capability=alarm reason=temporaryChat", exitStatus: 75)
        }
        guard await isForeground() else {
            return SystemAlarmOutput.make(
                "status=foregroundRequired capability=alarm message=Bring the app to the foreground to authorize and schedule an alarm.",
                exitStatus: 77)
        }
        let plan = try Self.plan(args)
        let owner = SystemAlarmOwner(context: context)

        // OS authorization (the request result is not a scheduled alarm).
        let authorization = await service.authorization()
        guard authorization.canSchedule else {
            return SystemAlarmOutput.make(
                "status=authorization capability=alarm authorization=\(authorization.rawValue) message=AlarmKit authorization is \(authorization.rawValue); a granted request only permits scheduling, it is not an alarm.",
                exitStatus: 77)
        }

        do {
            let record = try await service.schedule(
                owner: owner,
                kind: plan.kind,
                intendedTimezone: plan.timezone.identifier,
                intendedFireDate: plan.fireDate,
                repeatRule: plan.repeatRule,
                timerDuration: plan.duration,
                label: plan.label,
                cancellation: context.cancellation
            )
            switch record.state {
            case .created:
                return SystemAlarmOutput.make(
                    "status=ok capability=alarm \(SystemAlarmOutput.render(record))")
            case .unknown:
                // Schedule returned but could not be verified; typed pending
                // verification, not a fabricated success.
                return SystemAlarmOutput.make(
                    "status=pendingVerification capability=alarm \(SystemAlarmOutput.render(record)) message=The schedule returned but its native state is unverified; query apple.alarm.status to reconcile before relying on it.",
                    exitStatus: 0)
            default:
                return SystemAlarmOutput.make(
                    "status=\(record.state.rawValue) capability=alarm \(SystemAlarmOutput.render(record))",
                    exitStatus: 0)
            }
        } catch let error as SystemAlarmError {
            return SystemAlarmOutput.make(
                "status=error capability=alarm code=\(error) message=The alarm could not be scheduled.",
                exitStatus: error.exitStatus)
        } catch {
            return SystemAlarmOutput.make(
                "status=error capability=alarm message=The alarm could not be scheduled.",
                exitStatus: 1)
        }
    }

    // MARK: Planning / validation

    struct Plan {
        var kind: SystemAlarmKind
        var timezone: TimeZone
        var fireDate: Date?
        var duration: TimeInterval?
        var repeatRule: SystemAlarmRepeat
        var label: String
    }

    static func plan(_ args: Arguments, deviceTimeZone: TimeZone = .current) throws -> Plan {
        let rawKind = (args.kind ?? "alarm").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let kind = SystemAlarmKind(rawValue: rawKind) else {
            throw FloeError.validationFailed("kind must be 'alarm' or 'timer'")
        }

        // Timezone is required so the intended wall clock is unambiguous.
        let tzIdentifier = (args.timezone ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tzIdentifier.isEmpty, let timezone = TimeZone(identifier: tzIdentifier) else {
            throw FloeError.validationFailed("timezone must be a valid IANA identifier")
        }

        let repeatRule = try parseRepeat(args.repeat)

        switch kind {
        case .timer:
            guard args.repeat == nil || repeatRule == .never else {
                throw FloeError.validationFailed("a timer cannot repeat")
            }
            guard let durationSeconds = args.durationSeconds else {
                throw FloeError.validationFailed("durationSeconds is required for a timer")
            }
            guard (1...maxTimerSeconds).contains(durationSeconds) else {
                throw FloeError.validationFailed("durationSeconds must be 1...\(maxTimerSeconds)")
            }
            return Plan(
                kind: .timer, timezone: timezone, fireDate: nil,
                duration: TimeInterval(durationSeconds), repeatRule: .never,
                label: try boundedLabel(args.label))
        case .alarm:
            guard let fireAt = args.fireAt?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !fireAt.isEmpty else {
                throw FloeError.validationFailed("fireAt is required for an alarm")
            }
            let fireDate = try parseAbsoluteISO8601(fireAt, timezone: timezone)
            if case .weekly = repeatRule {
                guard timezone.identifier == deviceTimeZone.identifier else {
                    throw FloeError.validationFailed("weekly alarms follow the device timezone; use \(deviceTimeZone.identifier) or a fixed one-shot alarm")
                }
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = deviceTimeZone
                let parts = calendar.dateComponents([.second, .nanosecond], from: fireDate)
                guard parts.second == 0, (parts.nanosecond ?? 0) < 1_000_000 else {
                    throw FloeError.validationFailed("weekly alarms support whole minutes")
                }
            }
            // For weekly alarms the date is a carrier for the documented
            // wall-clock time; the system starts at its next matching day.
            guard fireDate > Date() else {
                throw FloeError.validationFailed("fireAt must be a future time")
            }
            return Plan(
                kind: .alarm, timezone: timezone, fireDate: fireDate,
                duration: nil, repeatRule: repeatRule,
                label: try boundedLabel(args.label))
        }
    }

    /// Absolute ISO-8601 WITH an explicit numeric offset. The offset is
    /// authoritative for the instant; `timezone` records the intended wall
    /// clock. A time with no offset is rejected (ambiguous).
    static func parseAbsoluteISO8601(_ value: String, timezone: TimeZone) throws -> Date {
        // Require an explicit numeric offset (+hh:mm / -hh:mm / Z).
        guard value.contains("+") || value.hasSuffix("Z")
                || value.dropFirst(10).contains("-") else {
            throw FloeError.validationFailed(
                "fireAt must include an explicit numeric UTC offset (e.g. 2026-10-22T07:30:00+08:00)")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else {
            throw FloeError.validationFailed("fireAt is not a valid ISO-8601 time")
        }
        return date
    }

    static func parseRepeat(_ raw: String?) throws -> SystemAlarmRepeat {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty, trimmed != "never" else { return .never }
        let days = trimmed.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !days.isEmpty, days.count == trimmed.split(separator: ",").count,
              days.allSatisfy({ (1...7).contains($0) }),
              Set(days).count == days.count else {
            throw FloeError.validationFailed("repeat must be 'never' or unique weekdays 1...7 (Monday=1)")
        }
        return .weekly(days)
    }

    static func boundedLabel(_ raw: String?) throws -> String {
        let trimmed = (raw ?? "Floe Alarm").trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 64,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw FloeError.validationFailed("label must be at most 64 characters without control characters")
        }
        return trimmed.isEmpty ? "Floe Alarm" : trimmed
    }
}

// MARK: - list (read-only, owner-scoped)

struct AppleAlarmListTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        /// Optional max rows (bounded).
        var limit: Int?
        init(limit: Int? = nil) { self.limit = limit }
    }

    static let name = "apple.alarm.list"
    static let toolDescription = """
    List the system alarms/timers owned by THIS task (the current conversation/run only). \
    Returns each alarm's stable id, kind, state, intended timezone/fire time or duration, \
    repeat rule and durable operation receipt. An alarm created by a different task never \
    appears here, and a native alarm this app did not record is never adopted. Pass the \
    exact id to apple.alarm.status for a native readback or apple.alarm.cancel to cancel. \
    An empty result means this task owns no alarms — it is not evidence of a system error.
    """
    static let parametersJSON = #"""
    {"type":"object","properties":{"limit":{"type":"integer","minimum":1,"maximum":100,"description":"Maximum rows to return (default 50)."}},"additionalProperties":false}
    """#
    static let riskLabels: Set<RiskLabel> = [.readsFiles]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly

    private let service: SystemAlarmService

    init(service: SystemAlarmService) { self.service = service }

    func validate(_ args: Arguments) throws {
        if let limit = args.limit {
            guard (1...100).contains(limit) else {
                throw FloeError.validationFailed("limit must be 1...100")
            }
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard !context.temporaryReadOnly, !context.publicWebOnly else {
            return SystemAlarmOutput.make(
                "status=unavailable capability=alarm reason=temporaryChat", exitStatus: 75)
        }
        let limit = args.limit ?? 50
        let owner = SystemAlarmOwner(context: context)
        let records = try await service.list(owner: owner)
        let shown = Array(records.prefix(limit))
        var lines = [
            "status=ok capability=alarm kind=apple.alarm.list count=\(shown.count) ownerScope=thisTask"
        ]
        lines.append(contentsOf: shown.map(SystemAlarmOutput.render))
        return SystemAlarmOutput.make(lines.joined(separator: "\n"))
    }
}

// MARK: - cancel (mutating, owner-scoped)

struct AppleAlarmCancelTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        /// Exact stable alarm id from apple.alarm.schedule/list.
        var id: String
        init(id: String) { self.id = id }
    }

    static let name = "apple.alarm.cancel"
    static let toolDescription = """
    Cancel a system alarm/timer owned by THIS task, by its exact stable id. Only an alarm \
    recorded for the current conversation/run can be cancelled; a foreign or unknown id is \
    refused, never adopted. Cancelling an alarm that has not yet fired removes its future \
    repeats; a one-shot that already rang is already terminal. A cancel is reconciled \
    against the native manager (the id must actually disappear); a returned-but-still-present \
    cancel is reported unknown, not success. Cancelling before the native commit discards the \
    intent with no native side effect.
    """
    static let parametersJSON = #"""
    {"type":"object","properties":{"id":{"type":"string","maxLength":64,"description":"Exact stable alarm UUID from apple.alarm.schedule or apple.alarm.list."}},"required":["id"],"additionalProperties":false}
    """#
    static let riskLabels: Set<RiskLabel> = [.changesAgentBehavior]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    private let service: SystemAlarmService

    init(service: SystemAlarmService) { self.service = service }

    func validate(_ args: Arguments) throws {
        guard UUID(uuidString: args.id) != nil else {
            throw FloeError.validationFailed("id must be a valid alarm UUID")
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard !context.temporaryReadOnly, !context.publicWebOnly else {
            return SystemAlarmOutput.make(
                "status=unavailable capability=alarm reason=temporaryChat", exitStatus: 75)
        }
        guard let alarmID = UUID(uuidString: args.id) else {
            throw FloeError.validationFailed("id must be a valid alarm UUID")
        }
        let owner = SystemAlarmOwner(context: context)
        do {
            let record = try await service.cancel(owner: owner, alarmID: alarmID, cancellation: context.cancellation)
            return SystemAlarmOutput.make(
                "status=ok capability=alarm action=cancel \(SystemAlarmOutput.render(record))")
        } catch let error as SystemAlarmError {
            return SystemAlarmOutput.make(
                "status=error capability=alarm code=\(error) message=The alarm could not be cancelled.",
                exitStatus: error.exitStatus)
        } catch {
            return SystemAlarmOutput.make(
                "status=error capability=alarm message=The alarm could not be cancelled.",
                exitStatus: 1)
        }
    }
}

// MARK: - status (read-only native readback + reconcile)

struct AppleAlarmStatusTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        /// Optional exact stable alarm id to read back; omit to reconcile all
        /// of this task's unfinished alarms.
        var id: String?
        init(id: String? = nil) { self.id = id }
    }

    static let name = "apple.alarm.status"
    static let toolDescription = """
    Read the real native state of THIS task's alarms, reconciling any unfinished \
    (submitted/unknown) schedule or cancel against the actual AlarmManager state by exact \
    stable id. With an id, returns that alarm's durable state plus the native presence \
    verdict; without an id, reconciles all of this task's unfinished alarms. A native id \
    this app never recorded is reported foreign, never adopted. confirmedCreated means the \
    native manager still schedules the exact id; confirmedGone means it no longer does \
    (already rang or cancelled); readbackError means the native state could not be read and \
    the outcome stays unknown. This is an accurate snapshot, not ring evidence.
    """
    static let parametersJSON = #"""
    {"type":"object","properties":{"id":{"type":"string","maxLength":64,"description":"Exact stable alarm UUID to read back; omit to reconcile this task's unfinished alarms."}},"additionalProperties":false}
    """#
    static let riskLabels: Set<RiskLabel> = [.readsFiles]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly

    private let service: SystemAlarmService

    init(service: SystemAlarmService) { self.service = service }

    func validate(_ args: Arguments) throws {
        if let id = args.id {
            guard UUID(uuidString: id) != nil else {
                throw FloeError.validationFailed("id must be a valid alarm UUID")
            }
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard !context.temporaryReadOnly, !context.publicWebOnly else {
            return SystemAlarmOutput.make(
                "status=unavailable capability=alarm reason=temporaryChat", exitStatus: 75)
        }
        let owner = SystemAlarmOwner(context: context)

        if let id = args.id, let alarmID = UUID(uuidString: id) {
            let record = try await service.list(owner: owner).first { $0.id == alarmID }
            guard let record else {
                return SystemAlarmOutput.make(
                    "status=foreign capability=alarm id=\(alarmID.uuidString) message=No alarm with this id is owned by this task.",
                    exitStatus: 77)
            }
            let outcomes = try await service.reconcile(owner: owner)
            let verdict = outcomes.first { $0.0 == alarmID }?.1
            let refreshed = try await service.list(owner: owner).first { $0.id == alarmID } ?? record
            let status = verdict == .pendingVerification || verdict == .readbackError
                ? "pendingVerification" : "ok"
            var line = "status=\(status) capability=alarm deviceTimezone=\(TimeZone.current.identifier) \(SystemAlarmOutput.render(refreshed))"
            if let verdict { line += " reconcile=\(verdict.rawValue)" }
            return SystemAlarmOutput.make(line)
        }

        let outcomes = try await service.reconcile(owner: owner)
        let hasPending = outcomes.contains { $0.1 == .pendingVerification || $0.1 == .readbackError }
        var lines = [
            "status=\(hasPending ? "pendingVerification" : "ok") capability=alarm kind=apple.alarm.status deviceTimezone=\(TimeZone.current.identifier) count=\(outcomes.count) ownerScope=thisTask"
        ]
        for (alarmID, outcome) in outcomes {
            lines.append("id=\(alarmID.uuidString) reconcile=\(outcome.rawValue)")
        }
        return SystemAlarmOutput.make(lines.joined(separator: "\n"))
    }
}
#endif
