// SPDX-License-Identifier: MPL-2.0
//
// C06 — real Android CalendarProvider contract and ordinary calendar tools.
//
// The App host owns the real CalendarContract reads/writes, the permission
// prompts and the provider read-back. This Swift domain owns the closed wire
// vocabulary, occurrence identity, date/time/recurrence validation, stable
// paging and the exact model-facing tool behaviour. It never invents a
// provider row, never treats a configured account or an Intent as proof, and
// never silently chooses a writable calendar.
//
// The provider port is executed by the trusted App host over the additive
// `floe.calendar/13` mailbox. Model tools use the ORIGINAL ToolCatalog /
// ToolRunnerRegistry lifecycle and the ordinary task approval path.
import Foundation
import FloeCore
import FloeTools

// MARK: - Wire bounds

public enum C06CalendarWire {
    public static let version = 13
    public static let schema = "floe.calendar/13"
    public static let maximumRequestBytes = 65_536
    public static let maximumResponseBytes = 49_152
    public static let maximumRangeDays = 366
    public static let maximumRangeMillis: Int64 = Int64(maximumRangeDays) * 24 * 60 * 60 * 1_000
    public static let defaultEventLimit = 100
    public static let maximumEventLimit = 200
    public static let maximumCalendars = 64
    public static let maximumTitleBytes = 512
    public static let maximumNotesBytes = 8_192
    public static let maximumLocationBytes = 512
    public static let maximumQueryBytes = 256
    public static let maximumTimezoneBytes = 64
    public static let maximumRecurrenceBytes = 1_024
    public static let maximumCursorBytes = 512
    public static let cursorLifetime: TimeInterval = 600
    public static let maximumOwnerBytes = 128
    public static let maximumOccurrenceIdentifierBytes = 64
    public static let maximumPageCharacters = 3_800
    public static let pageHeaderReserve = 320
    public static let modelTools = true
    public static let modelToolNames: [String] = [
        "calendar.list",
        "calendar.update",
    ]
}

// MARK: - Errors

public enum C06CalendarErrorCode: String, Codable, Sendable, Equatable {
    case coreUnavailable
    case runtimeNotInstalled
    case staleEpoch
    case invalidRequest
    case unsupportedOperation
    case responseTooLarge
    case invalidOwner
    case temporaryOwnerCannotUseCalendar
    case permissionDenied
    case writePermissionDenied
    case providerAbsent
    case noCalendars
    case noWritableCalendar
    case calendarMissing
    case calendarNotWritable
    case eventNotFound
    case occurrenceNotFound
    case occurrenceAmbiguous
    case staleOccurrence
    case unsupportedRecurrence
    case unsupportedSpan
    case invalidRange
    case invalidDate
    case invalidAllDay
    case invalidTimezone
    case invalidRecurrence
    case invalidFields
    case cursorExpired
    case cursorMismatch
    case revisionConflict
    case notFound
    case todoNotFound
    case invalidTitle
    case invalidNotes
    case invalidDue
    case invalidReminder
    case schemaUnavailable
    case storageUnavailable
    case notificationsBlocked
    case exactAlarmUnavailable
    case armFailed
    case pageTruncated
    case readbackMismatch
    case mutationUnknown
    case providerRejected
    case providerUnavailable
    case hostUnavailable
    case timedOut
    case cancelled
    case busy
    case internalFailure
}

public struct C06CalendarError: Error, Sendable, Equatable {
    public let code: C06CalendarErrorCode
    public let reason: String
    public let retryable: Bool
    public let detail: String?
    public let stage: String?

    public init(
        _ code: C06CalendarErrorCode,
        _ reason: String? = nil,
        retryable: Bool = false,
        detail: String? = nil,
        stage: String? = nil
    ) {
        self.code = code
        self.reason = String((reason ?? code.rawValue).prefix(120))
        self.retryable = retryable
        self.detail = detail.map { String($0.prefix(240)) }
        self.stage = stage.map { String($0.prefix(32)) }
    }
}

// MARK: - Owner

public struct C06CalendarOwner: Sendable, Equatable {
    public let token: String
    public let nativeEpoch: UInt64
    public let taskID: UUID?
    public let temporary: Bool

    public init(
        token: String,
        nativeEpoch: UInt64,
        taskID: UUID? = nil,
        temporary: Bool = false
    ) throws {
        guard (8...C06CalendarWire.maximumOwnerBytes).contains(token.utf8.count),
              token.unicodeScalars.allSatisfy({
                  $0.value < 128
                      && !$0.properties.isWhitespace
                      && !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw C06CalendarError(.invalidOwner, "invalidOwnerToken")
        }
        guard nativeEpoch > 0 else {
            throw C06CalendarError(.invalidOwner, "invalidNativeEpoch")
        }
        if temporary {
            // Calendar and todo data are private personal data. Temporary
            // chat is text-only with a public-web tool ceiling.
            throw C06CalendarError(.temporaryOwnerCannotUseCalendar, "temporaryOwnerCannotUseCalendar")
        }
        self.token = token
        self.nativeEpoch = nativeEpoch
        self.taskID = taskID
        self.temporary = temporary
    }

    public static func parse(_ value: Any?) throws -> C06CalendarOwner {
        guard let object = value as? [String: Any],
              let token = c06CalString(object["token"], maxBytes: C06CalendarWire.maximumOwnerBytes),
              let epoch = c06CalUInt64(object["nativeEpoch"]) else {
            throw C06CalendarError(.invalidOwner, "invalidOwner")
        }
        let taskID = (object["taskID"] as? String).flatMap(UUID.init(uuidString:))
        let temporary = c06CalBool(object["temporary"]) ?? false
        return try C06CalendarOwner(
            token: token,
            nativeEpoch: epoch,
            taskID: taskID,
            temporary: temporary
        )
    }
}

// MARK: - Occurrence identity

/// One provider occurrence: the Events row identifier plus the exact instance
/// start. `CalendarContract.Instances` returns one row per occurrence; a
/// recurring series shares `eventID`, so the start is the only selector that
/// may reach a single occurrence write.
public struct C06CalendarOccurrence: Hashable, Sendable {
    public let eventID: Int64
    public let start: Date

    public init(eventID: Int64, start: Date) {
        self.eventID = eventID
        self.start = Self.canonicalStart(start)
    }

    /// Strictly parses the exact `id@UTC-ISO8601` token emitted by
    /// `calendar.list`. Offsets and fractional seconds are rejected so the
    /// caller cannot invent a selector that the provider never returned.
    public init?(token: String) {
        guard token.utf8.count <= C06CalendarWire.maximumCursorBytes,
              let separator = token.lastIndex(of: "@") else { return nil }
        let identifier = String(token[..<separator])
        let datePart = String(token[token.index(after: separator)...])
        guard let eventID = Int64(identifier), eventID > 0,
              !datePart.isEmpty,
              let date = C06CalendarDate.parseUTCISO8601(datePart),
              C06CalendarDate.iso8601(date) == datePart else {
            return nil
        }
        self.init(eventID: eventID, start: date)
    }

    public var token: String {
        "\(eventID)@\(C06CalendarDate.iso8601(start))"
    }

    public var startISO8601: String {
        C06CalendarDate.iso8601(start)
    }

    public static func canonicalStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    public static func sameSecond(_ lhs: Date, _ rhs: Date) -> Bool {
        canonicalStart(lhs) == canonicalStart(rhs)
    }
}

// MARK: - Host DTOs (trusted App provider projection)

public struct C06CalendarSummary: Sendable, Equatable {
    public let id: Int64
    public let displayName: String
    public let accountName: String
    public let accountType: String
    public let ownerAccount: String
    public let timeZone: String
    public let color: Int
    public let accessLevel: Int
    public let writable: Bool
    public let visible: Bool
    public let isPrimary: Bool

    public init(
        id: Int64,
        displayName: String,
        accountName: String,
        accountType: String,
        ownerAccount: String,
        timeZone: String,
        color: Int,
        accessLevel: Int,
        writable: Bool,
        visible: Bool,
        isPrimary: Bool
    ) {
        self.id = id
        self.displayName = String(displayName.prefix(160))
        self.accountName = String(accountName.prefix(160))
        self.accountType = String(accountType.prefix(80))
        self.ownerAccount = String(ownerAccount.prefix(160))
        self.timeZone = String(timeZone.prefix(C06CalendarWire.maximumTimezoneBytes))
        self.color = color
        self.accessLevel = accessLevel
        self.writable = writable
        self.visible = visible
        self.isPrimary = isPrimary
    }
}

public struct C06CalendarSnapshot: Sendable, Equatable {
    public let providerAvailable: Bool
    public let readGranted: Bool
    public let writeGranted: Bool
    public let calendars: [C06CalendarSummary]
    public let revision: Int64

    public init(
        providerAvailable: Bool,
        readGranted: Bool,
        writeGranted: Bool,
        calendars: [C06CalendarSummary],
        revision: Int64
    ) {
        self.providerAvailable = providerAvailable
        self.readGranted = readGranted
        self.writeGranted = writeGranted
        self.calendars = Array(calendars.prefix(C06CalendarWire.maximumCalendars))
        self.revision = revision
    }

    public var writableCalendars: [C06CalendarSummary] {
        calendars.filter(\.writable)
    }
}

public struct C06CalendarEvent: Sendable, Equatable {
    public let eventID: Int64
    public let calendarID: Int64
    public let calendarName: String
    public let title: String
    public let start: Date
    public let end: Date
    public let allDay: Bool
    public let timeZone: String
    public let location: String?
    public let notes: String?
    public let recurrence: String?
    public let originalInstanceTime: Date?
    public let status: String?
    public let deleted: Bool

    public init(
        eventID: Int64,
        calendarID: Int64,
        calendarName: String,
        title: String,
        start: Date,
        end: Date,
        allDay: Bool,
        timeZone: String,
        location: String? = nil,
        notes: String? = nil,
        recurrence: String? = nil,
        originalInstanceTime: Date? = nil,
        status: String? = nil,
        deleted: Bool = false
    ) {
        self.eventID = eventID
        self.calendarID = calendarID
        self.calendarName = String(calendarName.prefix(160))
        self.title = String(title.prefix(512))
        self.start = start
        self.end = end
        self.allDay = allDay
        self.timeZone = String(timeZone.prefix(C06CalendarWire.maximumTimezoneBytes))
        self.location = location.map { String($0.prefix(C06CalendarWire.maximumLocationBytes)) }
        self.notes = notes.map { String($0.prefix(C06CalendarWire.maximumNotesBytes)) }
        self.recurrence = recurrence.map { String($0.prefix(C06CalendarWire.maximumRecurrenceBytes)) }
        self.originalInstanceTime = originalInstanceTime
        self.status = status.map { String($0.prefix(32)) }
        self.deleted = deleted
    }

    public var isRecurring: Bool {
        recurrence?.isEmpty == false || originalInstanceTime != nil
    }

    public var isDetached: Bool {
        originalInstanceTime != nil
    }

    public var occurrence: C06CalendarOccurrence {
        C06CalendarOccurrence(eventID: eventID, start: start)
    }
}

public struct C06CalendarHostPage: Sendable, Equatable {
    public let rows: [C06CalendarEvent]
    public let hasMore: Bool
    public let totalCount: Int

    public init(rows: [C06CalendarEvent], hasMore: Bool, totalCount: Int) {
        self.rows = Array(rows.prefix(C06CalendarWire.maximumEventLimit))
        self.hasMore = hasMore
        self.totalCount = max(totalCount, self.rows.count)
    }
}

public struct C06CalendarReceipt: Sendable, Equatable {
    public let action: String
    public let eventID: Int64
    public let calendarID: Int64
    public let occurrenceStart: Date?
    public let deleted: Bool
    public let readbackVerified: Bool
    public let verificationScope: String
    public let verifiedFields: [String]

    public init(
        action: String,
        eventID: Int64,
        calendarID: Int64,
        occurrenceStart: Date?,
        deleted: Bool,
        readbackVerified: Bool,
        verificationScope: String,
        verifiedFields: [String]
    ) {
        self.action = String(action.prefix(16))
        self.eventID = eventID
        self.calendarID = calendarID
        self.occurrenceStart = occurrenceStart
        self.deleted = deleted
        self.readbackVerified = readbackVerified
        self.verificationScope = String(verificationScope.prefix(32))
        self.verifiedFields = Array(verifiedFields.prefix(24))
    }
}

public struct C06CalendarEventPatch: Sendable, Equatable {
    public var title: String?
    public var start: Date?
    public var end: Date?
    public var notes: String?
    public var location: String?
    public var allDay: Bool?
    public var timeZone: String?
    public var recurrence: String?

    public init(
        title: String? = nil,
        start: Date? = nil,
        end: Date? = nil,
        notes: String? = nil,
        location: String? = nil,
        allDay: Bool? = nil,
        timeZone: String? = nil,
        recurrence: String? = nil
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.notes = notes
        self.location = location
        self.allDay = allDay
        self.timeZone = timeZone
        self.recurrence = recurrence
    }

    public var isEmpty: Bool {
        title == nil && start == nil && end == nil && notes == nil
            && location == nil && allDay == nil && timeZone == nil && recurrence == nil
    }
}

// MARK: - Provider port

public protocol C06CalendarProviderPort: Sendable {
    func snapshot(owner: C06CalendarOwner) async throws -> C06CalendarSnapshot
    func instances(
        owner: C06CalendarOwner,
        start: Date,
        end: Date,
        calendarID: Int64?,
        query: String?,
        limit: Int,
        offset: Int
    ) async throws -> C06CalendarHostPage
    func event(id: Int64, owner: C06CalendarOwner) async throws -> C06CalendarEvent
    func create(
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
    ) async throws -> C06CalendarReceipt
    func update(
        owner: C06CalendarOwner,
        eventID: Int64,
        occurrenceStart: Date?,
        span: String,
        patch: C06CalendarEventPatch
    ) async throws -> C06CalendarReceipt
    func delete(
        owner: C06CalendarOwner,
        eventID: Int64,
        occurrenceStart: Date?,
        span: String
    ) async throws -> C06CalendarReceipt
}

// MARK: - Availability

public struct C06CalendarAvailabilitySnapshot: Sendable, Equatable {
    public var coreReady: Bool
    public var providerAvailable: Bool
    public var readGranted: Bool
    public var writeGranted: Bool
    public var calendarCount: Int
    public var writableCalendarCount: Int
    public var revision: Int64
    public var epoch: UInt64?

    public init(
        coreReady: Bool = false,
        providerAvailable: Bool = false,
        readGranted: Bool = false,
        writeGranted: Bool = false,
        calendarCount: Int = 0,
        writableCalendarCount: Int = 0,
        revision: Int64 = 0,
        epoch: UInt64? = nil
    ) {
        self.coreReady = coreReady
        self.providerAvailable = providerAvailable
        self.readGranted = readGranted
        self.writeGranted = writeGranted
        self.calendarCount = calendarCount
        self.writableCalendarCount = writableCalendarCount
        self.revision = revision
        self.epoch = epoch
    }

    /// Discovery requires the actual provider and the actual read grant.
    public var readAvailable: Bool {
        coreReady && providerAvailable && readGranted
    }

    /// A write additionally requires the actual write grant and at least one
    /// writable calendar. The concrete calendar is still chosen by the user.
    public var writeAvailable: Bool {
        readAvailable && writeGranted && writableCalendarCount > 0
    }
}

public final class C06CalendarAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var value = C06CalendarAvailabilitySnapshot()

    public init() {}

    public var snapshot: C06CalendarAvailabilitySnapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    @discardableResult
    public func update(
        coreReady: Bool,
        providerAvailable: Bool,
        readGranted: Bool,
        writeGranted: Bool,
        calendarCount: Int,
        writableCalendarCount: Int,
        revision: Int64,
        epoch: UInt64?
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // A genuinely newer host projection wins. Equal revisions are
        // idempotent; an older one never regresses live permission state.
        if value.epoch == epoch && revision < value.revision { return false }
        if revision == value.revision && value.coreReady && value.epoch == epoch {
            return true
        }
        value = C06CalendarAvailabilitySnapshot(
            coreReady: coreReady,
            providerAvailable: providerAvailable,
            readGranted: readGranted,
            writeGranted: writeGranted,
            calendarCount: max(0, calendarCount),
            writableCalendarCount: max(0, writableCalendarCount),
            revision: max(0, revision),
            epoch: epoch
        )
        return true
    }

    public func reset() {
        lock.lock(); value = C06CalendarAvailabilitySnapshot(); lock.unlock()
    }
}

// MARK: - Date / recurrence validation

public enum C06CalendarDate {
    public static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    public static func parseISO8601(_ raw: String) throws -> Date {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 64 else {
            throw C06CalendarError(.invalidDate, "invalidDate")
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: trimmed) { return date }
        let regular = ISO8601DateFormatter()
        regular.formatOptions = [.withInternetDateTime]
        if let date = regular.date(from: trimmed) { return date }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(secondsFromGMT: 0)
        day.dateFormat = "yyyy-MM-dd"
        if let date = day.date(from: trimmed) { return date }
        throw C06CalendarError(.invalidDate, "invalidDate")
    }

    public static func parseUTCISO8601(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    public static func validateTimeZone(_ raw: String?) throws -> String {
        let value = (raw?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? TimeZone.current.identifier
        guard value.utf8.count <= C06CalendarWire.maximumTimezoneBytes,
              TimeZone(identifier: value) != nil else {
            throw C06CalendarError(.invalidTimezone, "invalidTimezone")
        }
        return value
    }
}

public enum C06CalendarRecurrence {
    /// CalendarContract stores an RFC-5545 RRULE without the leading
    /// `RRULE:` label. Only a bounded, deterministic subset is accepted here;
    /// BYSETPOS, RDATE/EXDATE, COUNT+UNTIL together and unknown keys fail
    /// closed instead of being persisted as a rule the provider may reject.
    public static func validate(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        guard value.utf8.count <= C06CalendarWire.maximumRecurrenceBytes else {
            throw C06CalendarError(.invalidRecurrence, "recurrenceTooLong")
        }
        if value.hasPrefix("RRULE:") {
            value = String(value.dropFirst("RRULE:".count))
        }
        let allowed: Set<String> = [
            "FREQ", "INTERVAL", "COUNT", "UNTIL", "BYDAY", "BYMONTHDAY", "BYMONTH", "WKST",
        ]
        var keys: [String: String] = [:]
        for part in value.split(separator: ";", omittingEmptySubsequences: true) {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else {
                throw C06CalendarError(.invalidRecurrence, "invalidRecurrencePart")
            }
            let key = String(pair[0]).uppercased()
            let item = String(pair[1]).uppercased()
            guard allowed.contains(key), !item.isEmpty else {
                throw C06CalendarError(.invalidRecurrence, "unsupportedRecurrenceKey")
            }
            guard keys[key] == nil else {
                throw C06CalendarError(.invalidRecurrence, "duplicateRecurrenceKey")
            }
            keys[key] = item
        }
        guard let frequency = keys["FREQ"],
              ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"].contains(frequency) else {
            throw C06CalendarError(.invalidRecurrence, "unsupportedFrequency")
        }
        if keys["COUNT"] != nil && keys["UNTIL"] != nil {
            throw C06CalendarError(.invalidRecurrence, "countAndUntil")
        }
        if let count = keys["COUNT"], Int(count).map({ $0 > 0 && $0 <= 10_000 }) != true {
            throw C06CalendarError(.invalidRecurrence, "invalidCount")
        }
        if let interval = keys["INTERVAL"], Int(interval).map({ $0 > 0 && $0 <= 366 }) != true {
            throw C06CalendarError(.invalidRecurrence, "invalidInterval")
        }
        if let until = keys["UNTIL"], until.utf8.count > 32 {
            throw C06CalendarError(.invalidRecurrence, "invalidUntil")
        }
        if let byDay = keys["BYDAY"] {
            for day in byDay.split(separator: ",") where day.utf8.count > 8 {
                throw C06CalendarError(.invalidRecurrence, "invalidByDay")
            }
        }
        if let day = keys["BYMONTHDAY"],
           !day.split(separator: ",").allSatisfy({ Int($0).map { v in v != 0 && abs(v) <= 31 } == true }) {
            throw C06CalendarError(.invalidRecurrence, "invalidByMonthDay")
        }
        if let month = keys["BYMONTH"],
           !month.split(separator: ",").allSatisfy({ Int($0).map { v in (1...12).contains(v) } == true }) {
            throw C06CalendarError(.invalidRecurrence, "invalidByMonth")
        }
        // Canonical key order keeps an identical intent byte-identical for
        // read-back comparison.
        let order = ["FREQ", "INTERVAL", "COUNT", "UNTIL", "BYDAY", "BYMONTHDAY", "BYMONTH", "WKST"]
        return order.compactMap { key in keys[key].map { "\(key)=\($0)" } }.joined(separator: ";")
    }
}

// MARK: - Cursor

private struct C06CalendarCursorPayload: Codable {
    var version: Int
    var offset: Int
    var filter: String
    var issuedAt: Int64
}

public enum C06CalendarCursor {
    public static func encode(offset: Int, filter: String, issuedAt: Date) -> String {
        let payload = C06CalendarCursorPayload(
            version: 1,
            offset: max(0, offset),
            filter: filter,
            issuedAt: Int64(issuedAt.timeIntervalSince1970)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return "" }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ raw: String) throws -> (offset: Int, filter: String, issuedAt: Date) {
        guard raw.utf8.count <= C06CalendarWire.maximumCursorBytes else {
            throw C06CalendarError(.invalidRequest, "cursorTooLong")
        }
        var base64 = raw
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONDecoder().decode(C06CalendarCursorPayload.self, from: data),
              payload.version == 1,
              payload.offset >= 0,
              payload.offset <= 10_000 else {
            throw C06CalendarError(.invalidRequest, "invalidCursor")
        }
        let issuedAt = Date(timeIntervalSince1970: TimeInterval(payload.issuedAt))
        guard issuedAt.addingTimeInterval(C06CalendarWire.cursorLifetime) > Date() else {
            throw C06CalendarError(.cursorExpired, "cursorExpired")
        }
        return (payload.offset, payload.filter, issuedAt)
    }
}

// MARK: - Domain

public actor C06CalendarDomain {
    public static let shared = C06CalendarDomain(
        provider: { epoch in try C06CalendarProductionWiring.port(epoch: epoch) },
        readiness: { C06CalendarProductionWiring.readiness() }
    )
    public static let availability = C06CalendarAvailability()

    private let provider: @Sendable (UInt64) async throws -> any C06CalendarProviderPort
    private let readiness: @Sendable () -> (ready: Bool, epoch: UInt64?)

    public init(
        provider: @escaping @Sendable (UInt64) async throws -> any C06CalendarProviderPort,
        readiness: @escaping @Sendable () -> (ready: Bool, epoch: UInt64?)
    ) {
        self.provider = provider
        self.readiness = readiness
    }

    private func port(for owner: C06CalendarOwner) async throws -> any C06CalendarProviderPort {
        let current = readiness()
        guard current.ready, let epoch = current.epoch else {
            throw C06CalendarError(.runtimeNotInstalled, "runtimeNotInstalled", retryable: true)
        }
        guard epoch == owner.nativeEpoch else {
            throw C06CalendarError(.staleEpoch, "staleNativeEpoch")
        }
        return try await provider(epoch)
    }

    public func applyHostAvailability(
        providerAvailable: Bool,
        readGranted: Bool,
        writeGranted: Bool,
        calendarCount: Int,
        writableCalendarCount: Int,
        revision: Int64,
        epoch: UInt64
    ) {
        C06CalendarDomain.availability.update(
            coreReady: true,
            providerAvailable: providerAvailable,
            readGranted: readGranted,
            writeGranted: writeGranted,
            calendarCount: calendarCount,
            writableCalendarCount: writableCalendarCount,
            revision: revision,
            epoch: epoch
        )
    }

    public func refreshAvailability(epoch: UInt64) async {
        guard readiness().epoch == epoch else {
            C06CalendarDomain.availability.reset()
            return
        }
        do {
            let owner = try C06CalendarOwner(token: "availability.host", nativeEpoch: epoch)
            let snapshot = try await port(for: owner).snapshot(owner: owner)
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
        } catch {
            C06CalendarDomain.availability.reset()
        }
    }

    // MARK: Calendar selection / capabilities

    public func listCalendars(owner: C06CalendarOwner) async throws -> [C06CalendarSummary] {
        let snapshot = try await port(for: owner).snapshot(owner: owner)
        guard snapshot.providerAvailable else {
            throw C06CalendarError(.providerAbsent, "calendarProviderAbsent")
        }
        guard snapshot.readGranted else {
            throw C06CalendarError(.permissionDenied, "calendarReadPermissionDenied")
        }
        return snapshot.calendars
    }

    // MARK: List

    public struct ListResult: Sendable, Equatable {
        public let lines: [String]
        public let totalCount: Int
        public let returnedCount: Int
        public let hasMore: Bool
        public let nextCursor: String?
        public let pageCount: Int
        public let snapshotTime: Date
        public let truncatedRows: Int
    }

    public func list(
        owner: C06CalendarOwner,
        start: Date,
        end: Date,
        calendarID: Int64?,
        query: String?,
        limit: Int,
        cursor: String?
    ) async throws -> ListResult {
        guard end > start else {
            throw C06CalendarError(.invalidRange, "calendarRangeMustBePositive")
        }
        guard end.timeIntervalSince(start) * 1_000 <= Double(C06CalendarWire.maximumRangeMillis) else {
            throw C06CalendarError(.invalidRange, "calendarRangeTooLong")
        }
        guard (1...C06CalendarWire.maximumEventLimit).contains(limit) else {
            throw C06CalendarError(.invalidRequest, "invalidLimit")
        }
        if let calendarID, calendarID <= 0 {
            throw C06CalendarError(.invalidRequest, "invalidCalendarID")
        }
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedQuery, trimmedQuery.utf8.count > C06CalendarWire.maximumQueryBytes {
            throw C06CalendarError(.invalidRequest, "queryTooLong")
        }
        let filter = Self.filterKey(start: start, end: end, calendarID: calendarID, query: trimmedQuery)
        var offset = 0
        if let cursor {
            let decoded = try C06CalendarCursor.decode(cursor)
            guard decoded.filter == filter else {
                throw C06CalendarError(.cursorMismatch, "cursorFilterMismatch")
            }
            offset = decoded.offset
        }
        let providerPort = try await port(for: owner)
        let snapshot = try await providerPort.snapshot(owner: owner)
        guard snapshot.providerAvailable else {
            throw C06CalendarError(.providerAbsent, "calendarProviderAbsent")
        }
        guard snapshot.readGranted else {
            throw C06CalendarError(.permissionDenied, "calendarReadPermissionDenied")
        }
        if snapshot.calendars.isEmpty {
            throw C06CalendarError(.noCalendars, "noCalendarAccountConfigured")
        }
        if let calendarID, !snapshot.calendars.contains(where: { $0.id == calendarID }) {
            throw C06CalendarError(.calendarMissing, "calendarMissing")
        }
        let page = try await providerPort.instances(
            owner: owner,
            start: start,
            end: end,
            calendarID: calendarID,
            query: trimmedQuery?.isEmpty == false ? trimmedQuery : nil,
            limit: limit,
            offset: offset
        )
        var rows = page.rows
        var lines: [String] = []
        var characters = 0
        var truncated = 0
        for row in rows {
            let line = Self.line(row)
            if characters + line.count > C06CalendarWire.maximumPageCharacters {
                truncated += 1
                break
            }
            lines.append(line)
            characters += line.count + 1
        }
        if truncated > 0 {
            rows = Array(rows.prefix(lines.count))
        }
        let returned = lines.count
        let nextOffset = offset + returned
        let hasMore = page.hasMore || nextOffset < page.totalCount
        let nextCursor = (hasMore && returned > 0)
            ? C06CalendarCursor.encode(offset: nextOffset, filter: filter, issuedAt: Date())
            : nil
        return ListResult(
            lines: lines,
            totalCount: page.totalCount,
            returnedCount: returned,
            hasMore: hasMore,
            nextCursor: nextCursor,
            pageCount: max(1, (offset / limit) + 1),
            snapshotTime: Date(),
            truncatedRows: truncated
        )
    }

    private static func filterKey(start: Date, end: Date, calendarID: Int64?, query: String?) -> String {
        "start=\(C06CalendarDate.iso8601(start)) end=\(C06CalendarDate.iso8601(end))"
            + " calendar=\(calendarID.map { String($0) } ?? "all") query=\(query ?? "")"
    }

    private static func line(_ row: C06CalendarEvent) -> String {
        let occurrence = row.occurrence
        var value = "id=\(row.eventID) occurrence=\(occurrence.token)"
            + " start=\(occurrence.startISO8601) end=\(C06CalendarDate.iso8601(row.end))"
            + " allDay=\(row.allDay) recurring=\(row.isRecurring) detached=\(row.isDetached)"
            + " calendar=\(row.calendarName) calendarID=\(row.calendarID)"
            + " title=\(row.title)"
        if let location = row.location, !location.isEmpty { value += " location=\(location)" }
        if let recurrence = row.recurrence, !recurrence.isEmpty { value += " recurrence=\(recurrence)" }
        return value
    }

    // MARK: Get

    public func event(id: Int64, owner: C06CalendarOwner) async throws -> C06CalendarEvent {
        guard id > 0 else { throw C06CalendarError(.invalidRequest, "invalidEventID") }
        return try await port(for: owner).event(id: id, owner: owner)
    }

    // MARK: Write

    public func create(
        owner: C06CalendarOwner,
        calendarID: Int64,
        title: String,
        start: Date,
        end: Date,
        allDay: Bool,
        timeZone: String?,
        notes: String?,
        location: String?,
        recurrence: String?
    ) async throws -> C06CalendarReceipt {
        guard calendarID > 0 else {
            // There is no default calendar. A missing explicit selection is a
            // refusal, never the first account/calendar on the device.
            throw C06CalendarError(.invalidRequest, "explicitCalendarRequired")
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, trimmedTitle.utf8.count <= C06CalendarWire.maximumTitleBytes else {
            throw C06CalendarError(.invalidFields, "titleRequired")
        }
        guard end > start else { throw C06CalendarError(.invalidRange, "calendarEndMustFollowStart") }
        if allDay {
            guard Self.isUTCMidnight(start), Self.isUTCMidnight(end) else {
                throw C06CalendarError(.invalidAllDay, "allDayStartMustBeUTCMidnight")
            }
        }
        let zone = try Self.writeTimeZone(allDay: allDay, requested: timeZone)
        let rule = try C06CalendarRecurrence.validate(recurrence)
        let snapshot = try await port(for: owner).snapshot(owner: owner)
        guard snapshot.providerAvailable else {
            throw C06CalendarError(.providerAbsent, "calendarProviderAbsent")
        }
        guard snapshot.writeGranted else {
            throw C06CalendarError(.writePermissionDenied, "calendarWritePermissionDenied")
        }
        guard let calendar = snapshot.calendars.first(where: { $0.id == calendarID }) else {
            throw C06CalendarError(.calendarMissing, "calendarMissing")
        }
        guard calendar.writable else {
            throw C06CalendarError(.calendarNotWritable, "calendarNotWritable")
        }
        let receipt = try await port(for: owner).create(
            owner: owner,
            calendarID: calendarID,
            title: trimmedTitle,
            start: start,
            end: end,
            allDay: allDay,
            timeZone: zone,
            notes: try Self.boundedOptional(notes, limit: C06CalendarWire.maximumNotesBytes,
                                            reason: "notesTooLong"),
            location: try Self.boundedOptional(location, limit: C06CalendarWire.maximumLocationBytes,
                                               reason: "locationTooLong"),
            recurrence: rule
        )
        try Self.requireVerified(receipt, action: "create")
        return receipt
    }

    public func update(
        owner: C06CalendarOwner,
        eventID: Int64,
        occurrenceToken: String?,
        spanRaw: String?,
        patch: C06CalendarEventPatch
    ) async throws -> C06CalendarReceipt {
        guard eventID > 0 else { throw C06CalendarError(.invalidRequest, "invalidEventID") }
        guard !patch.isEmpty else { throw C06CalendarError(.invalidFields, "noChanges") }
        let span = try Self.span(spanRaw)
        var occurrenceStart: Date?
        if let occurrenceToken {
            let occurrence = try Self.occurrence(token: occurrenceToken, eventID: eventID)
            occurrenceStart = occurrence.start
        } else if span == "futureEvents" {
            throw C06CalendarError(.unsupportedSpan, "futureEventsRequiresOccurrence")
        }
        var normalized = patch
        if normalized.title != nil {
            let title = normalized.title!.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.utf8.count <= C06CalendarWire.maximumTitleBytes else {
                throw C06CalendarError(.invalidFields, "titleRequired")
            }
            normalized.title = title
        }
        if let notes = normalized.notes {
            guard notes.utf8.count <= C06CalendarWire.maximumNotesBytes else {
                throw C06CalendarError(.invalidFields, "notesTooLong")
            }
        }
        if let location = normalized.location {
            guard location.utf8.count <= C06CalendarWire.maximumLocationBytes else {
                throw C06CalendarError(.invalidFields, "locationTooLong")
            }
        }
        if normalized.allDay == true {
            if let start = normalized.start, !Self.isUTCMidnight(start) {
                throw C06CalendarError(.invalidAllDay, "allDayStartMustBeUTCMidnight")
            }
            if let end = normalized.end, !Self.isUTCMidnight(end) {
                throw C06CalendarError(.invalidAllDay, "allDayStartMustBeUTCMidnight")
            }
        }
        if let start = normalized.start, let end = normalized.end, end <= start {
            throw C06CalendarError(.invalidRange, "calendarEndMustFollowStart")
        }
        if let zone = normalized.timeZone {
            _ = try C06CalendarDate.validateTimeZone(zone)
        }
        if normalized.allDay == true, let zone = normalized.timeZone,
           TimeZone(identifier: zone)?.secondsFromGMT() != 0 {
            throw C06CalendarError(.invalidTimezone, "allDayTimezoneMustBeUTC")
        }
        if let rule = normalized.recurrence {
            normalized.recurrence = try C06CalendarRecurrence.validate(rule)
        }
        let receipt = try await port(for: owner).update(
            owner: owner,
            eventID: eventID,
            occurrenceStart: occurrenceStart,
            span: span,
            patch: normalized
        )
        try Self.requireVerified(receipt, action: "update")
        return receipt
    }

    public func delete(
        owner: C06CalendarOwner,
        eventID: Int64,
        occurrenceToken: String?,
        spanRaw: String?
    ) async throws -> C06CalendarReceipt {
        guard eventID > 0 else { throw C06CalendarError(.invalidRequest, "invalidEventID") }
        let span = try Self.span(spanRaw)
        var occurrenceStart: Date?
        if let occurrenceToken {
            let occurrence = try Self.occurrence(token: occurrenceToken, eventID: eventID)
            occurrenceStart = occurrence.start
        } else if span == "futureEvents" {
            throw C06CalendarError(.unsupportedSpan, "futureEventsRequiresOccurrence")
        }
        let receipt = try await port(for: owner).delete(
            owner: owner,
            eventID: eventID,
            occurrenceStart: occurrenceStart,
            span: span
        )
        try Self.requireVerified(receipt, action: "delete")
        return receipt
    }

    private static func span(_ raw: String?) throws -> String {
        guard let raw, !raw.isEmpty else { return "thisEvent" }
        guard raw == "thisEvent" || raw == "futureEvents" else {
            throw C06CalendarError(.invalidRequest, "invalidSpan")
        }
        return raw
    }

    private static func occurrence(token: String, eventID: Int64) throws -> C06CalendarOccurrence {
        guard let occurrence = C06CalendarOccurrence(token: token) else {
            throw C06CalendarError(.invalidRequest, "malformedOccurrenceToken")
        }
        guard occurrence.eventID == eventID else {
            throw C06CalendarError(.invalidRequest, "occurrenceIdentifierMismatch")
        }
        return occurrence
    }

    private static func writeTimeZone(allDay: Bool, requested: String?) throws -> String {
        if allDay {
            if let requested, !requested.isEmpty,
               TimeZone(identifier: requested)?.secondsFromGMT() != 0 {
                throw C06CalendarError(.invalidTimezone, "allDayTimezoneMustBeUTC")
            }
            return "UTC"
        }
        return try C06CalendarDate.validateTimeZone(requested)
    }

    private static func boundedOptional(_ raw: String?, limit: Int,
                                        reason: String) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        guard value.utf8.count <= limit else {
            throw C06CalendarError(.invalidFields, reason)
        }
        return value
    }

    static func isUTCMidnight(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.rounded(.towardZero) == seconds
            && seconds.truncatingRemainder(dividingBy: 86_400) == 0
    }

    private static func requireVerified(_ receipt: C06CalendarReceipt, action: String) throws {
        guard receipt.readbackVerified,
              receipt.action == action,
              receipt.verifiedFields.contains(where: { $0 == "id" }) else {
            throw C06CalendarError(.readbackMismatch, "calendarReadbackMismatch")
        }
        if action == "delete" {
            guard receipt.deleted else {
                throw C06CalendarError(.readbackMismatch, "calendarDeleteNotVerified")
            }
            return
        }
        guard !receipt.deleted,
              receipt.verifiedFields.contains(where: { $0 == "start" }) else {
            throw C06CalendarError(.readbackMismatch, "calendarWriteNotVerified")
        }
    }
}

// MARK: - Production wiring

enum C06CalendarProductionWiring {
    static func readiness() -> (ready: Bool, epoch: UInt64?) {
        guard let composition = G02RuntimeComposition.shared.installedComposition else {
            return (false, nil)
        }
        return (true, composition.epoch)
    }

    static func port(epoch: UInt64) throws -> any C06CalendarProviderPort {
        guard let composition = G02RuntimeComposition.shared.installedComposition else {
            throw C06CalendarError(.runtimeNotInstalled, "runtimeNotInstalled", retryable: true)
        }
        guard composition.epoch == epoch else {
            throw C06CalendarError(.staleEpoch, "staleNativeEpoch")
        }
        _ = try C06CalendarProductionWiring.ownedRoot(epoch: epoch)
        return C06CalendarHostMailboxPort(epoch: epoch)
    }

    static func ownedRoot(epoch: UInt64) throws -> URL {
        guard let composition = G02RuntimeComposition.shared.installedComposition else {
            throw C06CalendarError(.runtimeNotInstalled, "runtimeNotInstalled", retryable: true)
        }
        guard composition.epoch == epoch else {
            throw C06CalendarError(.staleEpoch, "staleNativeEpoch")
        }
        return composition.cluster.identity.root.artifactStoreURL
    }
}

// MARK: - JSON helpers (shared with bindings)

func c06CalString(_ value: Any?, maxBytes: Int) -> String? {
    guard let text = value as? String, !text.isEmpty,
          text.utf8.count <= maxBytes else { return nil }
    return text
}

func c06CalInt(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber else { return nil }
    let double = number.doubleValue
    guard double.isFinite, double.rounded(.towardZero) == double,
          double >= Double(Int32.min), double <= Double(Int32.max) else { return nil }
    return number.intValue
}

func c06CalInt64(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber else { return nil }
    let double = number.doubleValue
    guard double.isFinite, double.rounded(.towardZero) == double,
          double >= Double(Int64.min), double <= Double(Int64.max) else { return nil }
    return number.int64Value
}

func c06CalUInt64(_ value: Any?) -> UInt64? {
    guard let number = value as? NSNumber else { return nil }
    let double = number.doubleValue
    guard double.isFinite, double >= 0, double.rounded(.towardZero) == double else { return nil }
    return number.uint64Value
}

func c06CalBool(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber else { return nil }
    return number.boolValue
}

func c06CalDate(_ value: Any?) throws -> Date? {
    guard let text = value as? String, !text.isEmpty else { return nil }
    return try C06CalendarDate.parseISO8601(text)
}

// MARK: - calendar.list

public struct C06CalendarListTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var start: String?
        public var end: String?
        public var query: String?
        public var calendarID: Int64?
        public var limit: Int?
        public var cursor: String?

        public init(
            start: String? = nil,
            end: String? = nil,
            query: String? = nil,
            calendarID: Int64? = nil,
            limit: Int? = nil,
            cursor: String? = nil
        ) {
            self.start = start
            self.end = end
            self.query = query
            self.calendarID = calendarID
            self.limit = limit
            self.cursor = cursor
        }
    }

    public static let name = "calendar.list"
    public static let toolDescription = """
    List Android system calendar events in an ISO-8601 date range after the user \
    granted calendar read access. Returns stable event IDs and per-occurrence \
    tokens for later edits. Pages are bounded snapshots: limit defaults to 100 \
    (maximum 200); when hasMore is true, pass nextCursor back as cursor with the \
    SAME start/end/query/calendarID. The cursor expires after 10 minutes and is \
    owned by the task that started it. A permission denial, missing provider and \
    no configured calendar account are distinct honest states.
    """
    public static let parametersJSON = #"{"type":"object","properties":{"start":{"type":"string","maxLength":64},"end":{"type":"string","maxLength":64},"query":{"type":"string","maxLength":256},"calendarID":{"type":"integer","minimum":1},"limit":{"type":"integer","minimum":1,"maximum":200},"cursor":{"type":"string","maxLength":512}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let environment: C06CalendarToolEnvironment
    public init(environment: C06CalendarToolEnvironment = C06CalendarToolEnvironment()) {
        self.environment = environment
    }

    public func validate(_ args: Arguments) throws {
        if let limit = args.limit, !(1...C06CalendarWire.maximumEventLimit).contains(limit) {
            throw FloeError.validationFailed("limit must be 1...200")
        }
        if let calendarID = args.calendarID, calendarID <= 0 {
            throw FloeError.validationFailed("calendarID must be positive")
        }
        if let cursor = args.cursor, cursor.isEmpty {
            throw FloeError.validationFailed("cursor must not be empty")
        }
        _ = try C06CalendarDate.parseISO8601(args.start ?? C06CalendarDate.iso8601(Date()))
        _ = try C06CalendarDate.parseISO8601(args.end ?? C06CalendarDate.iso8601(Date()))
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let owner = try c06CalendarToolOwner(context)
        let start = try args.start.map(C06CalendarDate.parseISO8601)
            ?? C06CalendarOccurrence.canonicalStart(Date())
        let end = try args.end.map(C06CalendarDate.parseISO8601)
            ?? start.addingTimeInterval(30 * 24 * 3600)
        do {
            let page = try await environment.domain.list(
                owner: owner,
                start: start,
                end: end,
                calendarID: args.calendarID,
                query: args.query,
                limit: args.limit ?? C06CalendarWire.defaultEventLimit,
                cursor: args.cursor
            )
            var header = "status=ok kind=calendar count=\(page.returnedCount)"
                + " totalCount=\(page.totalCount) hasMore=\(page.hasMore)"
                + " nextCursor=\(page.nextCursor ?? "none") pageCount=\(page.pageCount)"
                + " snapshotTime=\(C06CalendarDate.iso8601(page.snapshotTime))"
            if page.truncatedRows > 0 { header += " truncatedRows=\(page.truncatedRows)" }
            let body = page.lines.isEmpty ? header : header + "\n" + page.lines.joined(separator: "\n")
            return ToolExecutionOutput(digesting: body)
        } catch let error as C06CalendarError {
            return Self.failure(error)
        }
    }

    static func failure(_ error: C06CalendarError) -> ToolExecutionOutput {
        ToolExecutionOutput(
            digesting: "status=error code=\(error.code.rawValue) reason=\(error.reason)"
                + (error.detail.map { " detail=\($0)" } ?? ""),
            exitStatus: 1
        )
    }
}

// MARK: - calendar.update

public struct C06CalendarUpdateTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var action: String
        public var id: Int64?
        public var occurrence: String?
        public var span: String?
        public var calendarID: Int64?
        public var title: String?
        public var start: String?
        public var end: String?
        public var notes: String?
        public var location: String?
        public var isAllDay: Bool?
        public var timezone: String?
        public var recurrence: String?

        public init(
            action: String,
            id: Int64? = nil,
            occurrence: String? = nil,
            span: String? = nil,
            calendarID: Int64? = nil,
            title: String? = nil,
            start: String? = nil,
            end: String? = nil,
            notes: String? = nil,
            location: String? = nil,
            isAllDay: Bool? = nil,
            timezone: String? = nil,
            recurrence: String? = nil
        ) {
            self.action = action
            self.id = id
            self.occurrence = occurrence
            self.span = span
            self.calendarID = calendarID
            self.title = title
            self.start = start
            self.end = end
            self.notes = notes
            self.location = location
            self.isAllDay = isAllDay
            self.timezone = timezone
            self.recurrence = recurrence
        }
    }

    public static let name = "calendar.update"
    public static let toolDescription = """
    Create, update, or delete an Android system calendar event after the user \
    granted calendar write access. create requires an explicit writable \
    calendarID chosen by the user; there is no default calendar. For update and \
    delete, use the id and exact occurrence token returned by calendar.list. \
    span selects thisEvent (default) or futureEvents for a recurring series. \
    Recurring or detached events require occurrence; a stale or ambiguous \
    occurrence fails without changing another instance. The App reads the \
    provider row back and verifies the written fields; a save call alone is \
    never reported as success. This requires ordinary task approval.
    """
    public static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["create","update","delete"]},"id":{"type":"integer","minimum":1},"occurrence":{"type":"string","maxLength":512},"span":{"type":"string","enum":["thisEvent","futureEvents"]},"calendarID":{"type":"integer","minimum":1},"title":{"type":"string","maxLength":512},"start":{"type":"string","maxLength":64},"end":{"type":"string","maxLength":64},"notes":{"type":"string","maxLength":8192},"location":{"type":"string","maxLength":512},"isAllDay":{"type":"boolean"},"timezone":{"type":"string","maxLength":64},"recurrence":{"type":"string","maxLength":1024}},"required":["action"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let environment: C06CalendarToolEnvironment
    public init(environment: C06CalendarToolEnvironment = C06CalendarToolEnvironment()) {
        self.environment = environment
    }

    public func validate(_ args: Arguments) throws {
        guard ["create", "update", "delete"].contains(args.action) else {
            throw FloeError.validationFailed("Unsupported calendar action")
        }
        if args.action == "create" {
            guard args.occurrence == nil else {
                throw FloeError.validationFailed("create does not accept occurrence")
            }
            guard args.span == nil else {
                throw FloeError.validationFailed("create does not accept span")
            }
            guard let calendarID = args.calendarID, calendarID > 0 else {
                throw FloeError.validationFailed("An explicit calendarID is required")
            }
            guard let title = args.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else {
                throw FloeError.validationFailed("title is required")
            }
        } else {
            guard let id = args.id, id > 0 else {
                throw FloeError.validationFailed("id is required")
            }
            if let occurrence = args.occurrence {
                _ = try C06CalendarDomain.occurrenceForTool(token: occurrence, eventID: id)
            } else if args.span == "futureEvents" {
                throw FloeError.validationFailed("span=futureEvents requires the exact occurrence token")
            }
        }
        if let recurrence = args.recurrence {
            _ = try C06CalendarRecurrence.validate(recurrence)
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        guard context.approvalGrantID != nil else {
            throw FloeError.validationFailed("Calendar changes require approval")
        }
        let owner = try c06CalendarToolOwner(context)
        do {
            switch args.action {
            case "create":
                let start = try args.start.map(C06CalendarDate.parseISO8601)
                    ?? C06CalendarDate.parseISO8601(C06CalendarDate.iso8601(Date()))
                let end: Date
                if let raw = args.end {
                    end = try C06CalendarDate.parseISO8601(raw)
                } else if args.isAllDay == true {
                    end = start.addingTimeInterval(24 * 3600)
                } else {
                    end = start.addingTimeInterval(3600)
                }
                let receipt = try await environment.domain.create(
                    owner: owner,
                    calendarID: args.calendarID ?? 0,
                    title: args.title ?? "",
                    start: start,
                    end: end,
                    allDay: args.isAllDay ?? false,
                    timeZone: args.timezone,
                    notes: args.notes,
                    location: args.location,
                    recurrence: args.recurrence
                )
                return Self.output("create", receipt)
            case "update":
                let patch = C06CalendarEventPatch(
                    title: args.title,
                    start: try args.start.map(C06CalendarDate.parseISO8601),
                    end: try args.end.map(C06CalendarDate.parseISO8601),
                    notes: args.notes,
                    location: args.location,
                    allDay: args.isAllDay,
                    timeZone: args.timezone,
                    recurrence: args.recurrence
                )
                let receipt = try await environment.domain.update(
                    owner: owner,
                    eventID: args.id ?? 0,
                    occurrenceToken: args.occurrence,
                    spanRaw: args.span,
                    patch: patch
                )
                return Self.output("update", receipt)
            default:
                let receipt = try await environment.domain.delete(
                    owner: owner,
                    eventID: args.id ?? 0,
                    occurrenceToken: args.occurrence,
                    spanRaw: args.span
                )
                return Self.output("delete", receipt)
            }
        } catch let error as C06CalendarError {
            return C06CalendarListTool.failure(error)
        }
    }

    private static func output(_ action: String, _ receipt: C06CalendarReceipt) -> ToolExecutionOutput {
        var value = "status=ok action=\(action) id=\(receipt.eventID)"
            + " calendarID=\(receipt.calendarID)"
            + " readback=verified scope=\(receipt.verificationScope)"
            + " fields=\(receipt.verifiedFields.joined(separator: ","))"
        if let start = receipt.occurrenceStart {
            value += " occurrence=\(C06CalendarOccurrence(eventID: receipt.eventID, start: start).token)"
        }
        if receipt.deleted { value += " deleted=true" }
        return ToolExecutionOutput(digesting: value)
    }
}

// MARK: - Tool owner

func c06CalendarToolOwner(_ context: ToolContext) throws -> C06CalendarOwner {
    guard !context.temporaryReadOnly else {
        throw FloeError.validationFailed("Temporary chat cannot use the calendar")
    }
    guard let epoch = C06CalendarDomain.availability.snapshot.epoch else {
        throw FloeError.validationFailed("Calendar runtime is not ready")
    }
    guard C06CalendarDomain.availability.snapshot.readAvailable else {
        throw FloeError.validationFailed("Calendar read access is not available")
    }
    return try C06CalendarOwner(
        token: "tool." + context.runID.uuidString,
        nativeEpoch: epoch,
        taskID: context.conversationID
    )
}

extension C06CalendarDomain {
    static func occurrenceForTool(token: String, eventID: Int64) throws -> C06CalendarOccurrence {
        guard let occurrence = C06CalendarOccurrence(token: token) else {
            throw FloeError.validationFailed("occurrence must be the exact id@start token returned by calendar.list")
        }
        guard occurrence.eventID == eventID else {
            throw FloeError.validationFailed("id and occurrence refer to different events")
        }
        return occurrence
    }
}
