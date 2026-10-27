#if canImport(UIKit)
import Foundation
import CryptoKit
import FloeCore
import FloeExecution
import FloeTools
@preconcurrency import EventKit
@preconcurrency import MapKit
@preconcurrency import CoreLocation
@preconcurrency import HomeKit
@preconcurrency import WatchConnectivity
import UIKit
import FloeModels
import FloePersistence
import FloeWorkspace

enum AppleToolOutput {
    static func make(_ text: String, exitStatus: Int32 = 0) -> ToolExecutionOutput {
        return ToolExecutionOutput(digesting: text, exitStatus: exitStatus)
    }

    /// Explicit pagination failure. Never an empty success.
    static func cursorError(_ error: PersonalToolCursorError) -> ToolExecutionOutput {
        make(
            "status=error code=\(error.code) message=\(error.localizedDescription)",
            exitStatus: 1
        )
    }

    /// Downstream character budget for one page. The runtime prefixes tool
    /// summaries to 4096 characters without a JSON-aware marker, so the
    /// store slices rows under this budget BEFORE the cursor is chosen and
    /// the header reserve keeps the rendered page inside the boundary.
    static let paginationCharacterBudget = 4_000
    static let paginationHeaderReserve = 320

    /// Renders one stable snapshot page with the complete pagination contract.
    /// The page's rows were already sliced to the character budget, so the
    /// header counts and the cursor describe exactly these visible rows.
    static func page(_ page: PersonalToolPage, kind: String) -> ToolExecutionOutput {
        var header = "status=ok kind=\(kind) count=\(page.returnedCount) totalCount=\(page.totalCount)"
            + " hasMore=\(page.hasMore) nextCursor=\(page.nextCursor ?? "none")"
            + " pageCount=\(page.pageCount) snapshotTime=\(iso(page.snapshotTime))"
            + " completeness=\(page.completeness)"
        if page.truncatedRows > 0 {
            header += " truncatedRows=\(page.truncatedRows)"
        }
        guard !page.lines.isEmpty else { return make(header) }
        return make(header + "\n" + page.lines.joined(separator: "\n"))
    }

    static func date(_ value: String?) throws -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        let regular = ISO8601DateFormatter()
        guard let date = regular.date(from: value) else {
            throw FloeError.validationFailed("Date must use ISO 8601, for example 2026-08-22T09:00:00+10:00")
        }
        return date
    }

    static func iso(_ date: Date?) -> String {
        guard let date else { return "none" }
        return ISO8601DateFormatter().string(from: date)
    }
}

@MainActor
private func openSystemURL(_ url: URL) async -> Bool {
    await UIApplication.shared.open(url, options: [:])
}

@MainActor
private func openMapItem(_ args: AppleMapsOpenTool.Arguments) -> Bool {
    let item = MKMapItem(
        location: CLLocation(latitude: args.latitude, longitude: args.longitude),
        address: nil
    )
    item.name = args.name
    var options: [String: Any] = [:]
    if let mode = args.directionsMode {
        options[MKLaunchOptionsDirectionsModeKey] = switch mode {
        case "walking": MKLaunchOptionsDirectionsModeWalking
        case "transit": MKLaunchOptionsDirectionsModeTransit
        default: MKLaunchOptionsDirectionsModeDriving
        }
    }
    return item.openInMaps(launchOptions: options)
}

/// Trusted task identity for paginated personal listings: the durable
/// conversation (stable across runs of the same task) plus the environment
/// where one applies; conversation-less runs fall back to the run identity.
extension PersonalToolOwnerID {
    init(context: ToolContext) {
        // A temporary (ephemeral) run owns its snapshots PER RUN, never by
        // conversation id: the ephemeral conversation id can be reused by a
        // later temporary session epoch, so same-conversation matching would
        // let a replacement session page rows captured for a destroyed one.
        // `publicWebOnly` is set exclusively by the temporary run
        // configuration; ordinary runs keep the durable-conversation owner.
        let temporary = context.temporaryReadOnly || context.publicWebOnly
        self.init(
            conversationID: temporary ? nil : context.conversationID,
            environmentID: temporary ? nil : context.environmentID,
            fallbackRunID: context.runID
        )
    }
}

/// Production paging seam for the personal list tools. The handlers call these
/// exact functions, so App tests exercise the real owner binding and store
/// behaviour without EventKit permission.
enum ApplePersonalListPaging {
    static func begin(
        kind: String,
        filterKey: String,
        lines: [String],
        context: ToolContext,
        pageSize: Int
    ) async throws -> PersonalToolPage {
        try await PersonalToolCursorStore.shared.begin(
            kind: kind,
            filterKey: filterKey,
            lines: lines,
            owner: PersonalToolOwnerID(context: context),
            pageSize: pageSize,
            characterBudget: AppleToolOutput.paginationCharacterBudget,
            reservedHeaderCharacters: AppleToolOutput.paginationHeaderReserve
        )
    }

    static func next(
        cursor: String,
        context: ToolContext,
        kind: String,
        filterKey: String?,
        pageSize: Int
    ) async throws -> PersonalToolPage {
        try await PersonalToolCursorStore.shared.next(
            cursor: cursor,
            owner: PersonalToolOwnerID(context: context),
            kind: kind,
            filterKey: filterKey,
            pageSize: pageSize,
            characterBudget: AppleToolOutput.paginationCharacterBudget,
            reservedHeaderCharacters: AppleToolOutput.paginationHeaderReserve
        )
    }
}

struct AppleCalendarListTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var start: String?; var end: String?; var query: String?
        var limit: Int?; var cursor: String?
    }
    static let name = "apple.calendar.list"
    static let toolDescription = "List Apple Calendar events in an ISO-8601 date range after system permission. Returns stable event identifiers and per-occurrence identities for later edits. Pages are stable snapshots: limit defaults to 100 (maximum 200); when hasMore is true, pass nextCursor back as cursor to continue the SAME snapshot. A cursor is owned by the task that started it and reports explicit errors when expired, revoked or given different filters."
    static let parametersJSON = #"{"type":"object","properties":{"start":{"type":"string"},"end":{"type":"string"},"query":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":200},"cursor":{"type":"string","maxLength":2048}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = false

    func validate(_ args: Arguments) throws {
        if let limit = args.limit, !(1...200).contains(limit) {
            throw FloeError.validationFailed("limit must be 1...200")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let limit = args.limit ?? 100
        guard (1...200).contains(limit) else {
            throw FloeError.validationFailed("limit must be 1...200")
        }
        let store = EKEventStore()
        if let cursor = args.cursor {
            // A cursor page still requires live calendar access: revocation
            // must be explicit, never served from cache.
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                return AppleToolOutput.make("status=permissionDenied capability=calendar", exitStatus: 77)
            }
            let filterKey = try Self.canonicalFilterKey(args, required: false)
            do {
                let page = try await ApplePersonalListPaging.next(
                    cursor: cursor,
                    context: context,
                    kind: "calendar",
                    filterKey: filterKey,
                    pageSize: limit
                )
                return AppleToolOutput.page(page, kind: "calendar")
            } catch let error as PersonalToolCursorError {
                return AppleToolOutput.cursorError(error)
            }
        }
        if context.temporaryReadOnly || context.publicWebOnly {
            // A temporary read uses existing access and never requests a
            // broader EventKit authorization as a side effect of reading.
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                return AppleToolOutput.make("status=permissionDenied capability=calendar", exitStatus: 77)
            }
        } else if !(try await store.requestFullAccessToEvents()) {
            return AppleToolOutput.make("status=permissionDenied capability=calendar", exitStatus: 77)
        }
        let start = try AppleToolOutput.date(args.start) ?? Date()
        let end = try AppleToolOutput.date(args.end) ?? start.addingTimeInterval(30 * 24 * 3600)
        guard end > start, end.timeIntervalSince(start) <= 366 * 24 * 3600 else {
            throw FloeError.validationFailed("Calendar range must be positive and no longer than 366 days")
        }
        let query = args.query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { query?.isEmpty != false || $0.title.lowercased().contains(query ?? "") }
            .sorted {
                if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
                if $0.endDate != $1.endDate { return $0.endDate < $1.endDate }
                let lhsID = $0.eventIdentifier ?? ""
                let rhsID = $1.eventIdentifier ?? ""
                if lhsID != rhsID { return lhsID < rhsID }
                return ($0.title ?? "") < ($1.title ?? "")
            }
        let lines = events.compactMap { event -> String? in
            // A stored occurrence must expose both the series identifier and
            // its start. Emitting a token with "unknown" would look editable
            // but could never resolve, so an incomplete row is omitted.
            guard let id = event.eventIdentifier, !id.isEmpty,
                  let startDate = event.startDate else { return nil }
            // Occurrence identity: a recurring series shares eventIdentifier,
            // so the occurrence start distinguishes instances across pages.
            // This exact token is the only selector that may reach a
            // recurring update/delete.
            let identity = CalendarOccurrenceIdentity(eventIdentifier: id, start: startDate)
            return "id=\(id) occurrence=\(identity.token) start=\(identity.startISO8601)"
                + " end=\(AppleToolOutput.iso(event.endDate)) allDay=\(event.isAllDay)"
                + " recurring=\(event.hasRecurrenceRules || event.isDetached)"
                + " detached=\(event.isDetached)"
                + " calendar=\(event.calendar.title) title=\(event.title ?? "")"
        }
        do {
            let page = try await ApplePersonalListPaging.begin(
                kind: "calendar",
                filterKey: try Self.canonicalFilterKey(args, required: true) ?? Self.emptyFilterKey,
                lines: lines,
                context: context,
                pageSize: limit
            )
            return AppleToolOutput.page(page, kind: "calendar")
        } catch let error as PersonalToolCursorError {
            return AppleToolOutput.cursorError(error)
        }
    }

    /// Canonical, secret-free filter identity for the snapshot. With
    /// `required == false` the key is only produced when the caller supplied
    /// at least one filter, so a bare cursor continuation stays valid.
    private static func canonicalFilterKey(_ args: Arguments, required: Bool) throws -> String? {
        let hasAny = args.start != nil || args.end != nil || args.query != nil
        guard hasAny else { return required ? Self.emptyFilterKey : nil }
        let start = try AppleToolOutput.date(args.start)
        let end = try AppleToolOutput.date(args.end)
        let query = args.query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return "start=\(AppleToolOutput.iso(start)) end=\(AppleToolOutput.iso(end)) query=\(query)"
    }

    private static let emptyFilterKey = "start=none end=none query="
}

private struct EventKitOccurrenceTarget: CalendarOccurrenceTarget {
    let event: EKEvent

    var occurrenceCandidate: CalendarOccurrenceCandidate {
        CalendarOccurrenceCandidate(
            eventIdentifier: event.eventIdentifier ?? "",
            start: event.startDate ?? .distantPast,
            hasRecurrenceRules: event.hasRecurrenceRules,
            isDetached: event.isDetached
        )
    }
}

private struct EventKitCalendarOccurrenceAdapter: CalendarOccurrenceWriting {
    typealias Target = EventKitOccurrenceTarget

    let store: EKEventStore
    let prepare: (EKEvent) throws -> Void

    func candidates(for identity: CalendarOccurrenceIdentity) throws -> [EventKitOccurrenceTarget] {
        // A two-second window around the listed start is enough to retrieve
        // the occurrence without scanning a large range. The resolver then
        // requires the exact identifier and whole-second start, so a nearby
        // series instance can never stand in for the requested one.
        let predicate = store.predicateForEvents(
            withStart: identity.start.addingTimeInterval(-2),
            end: identity.start.addingTimeInterval(2),
            calendars: nil
        )
        return store.events(matching: predicate).map {
            EventKitOccurrenceTarget(event: $0)
        }
    }

    func apply(
        _ operation: CalendarOccurrenceWriteOperation,
        span: CalendarWriteSpan,
        to target: EventKitOccurrenceTarget
    ) throws {
        switch operation {
        case .save:
            try prepare(target.event)
            try store.save(target.event, span: span.eventKitSpan, commit: true)
        case .remove:
            try store.remove(target.event, span: span.eventKitSpan, commit: true)
        }
    }
}

private struct AppleCalendarExpectedUpdate {
    let eventIdentifier: String
    let calendarItemIdentifier: String?
    let start: Date
    let end: Date?
    let title: String?
    let notes: String?
    let location: String?
    let isAllDay: Bool?
}

private enum AppleCalendarWriteReadback {
    /// Actual post-write read: reset the store cache, re-query the target
    /// start and require one identity match plus the content we wrote. A save
    /// alone is never reported as verified.
    static func updatedEvent(
        store: EKEventStore,
        expected: AppleCalendarExpectedUpdate
    ) -> EKEvent? {
        store.reset()
        let candidates = events(store: store, around: expected.start)
        let direct = candidates.filter { event in
            guard let identifier = event.eventIdentifier,
                  let start = event.startDate else { return false }
            return identifier == expected.eventIdentifier
                && CalendarOccurrenceIdentity.sameSecond(start, expected.start)
        }
        let matched: EKEvent?
        if direct.count == 1 {
            matched = direct[0]
        } else if direct.isEmpty, let itemIdentifier = expected.calendarItemIdentifier,
                  !itemIdentifier.isEmpty {
            // A thisEvent detach or futureEvents split may change the series
            // eventIdentifier. The occurrence item identifier plus the exact
            // start is a narrow alternate read-back binding.
            let indirect = candidates.filter { event in
                guard let start = event.startDate else { return false }
                return event.calendarItemIdentifier == itemIdentifier
                    && CalendarOccurrenceIdentity.sameSecond(start, expected.start)
            }
            matched = indirect.count == 1 ? indirect[0] : nil
        } else {
            matched = nil
        }
        guard let matched,
              let start = matched.startDate,
              CalendarOccurrenceIdentity.sameSecond(start, expected.start) else {
            return nil
        }
        if let title = expected.title, matched.title != title { return nil }
        if let notes = expected.notes, matched.notes != notes { return nil }
        if let location = expected.location, matched.location != location { return nil }
        if let isAllDay = expected.isAllDay, matched.isAllDay != isAllDay { return nil }
        if let end = expected.end {
            guard let actualEnd = matched.endDate,
                  CalendarOccurrenceIdentity.sameSecond(actualEnd, end) else {
                return nil
            }
        }
        return matched
    }

    static func occurrenceIsAbsent(
        store: EKEventStore,
        identity: CalendarOccurrenceIdentity
    ) -> Bool {
        store.reset()
        let candidates = events(store: store, around: identity.start)
        return !candidates.contains { event in
            guard let identifier = event.eventIdentifier,
                  let start = event.startDate else { return false }
            return identifier == identity.eventIdentifier
                && CalendarOccurrenceIdentity.sameSecond(start, identity.start)
        }
    }

    private static func events(store: EKEventStore, around start: Date) -> [EKEvent] {
        let predicate = store.predicateForEvents(
            withStart: start.addingTimeInterval(-2),
            end: start.addingTimeInterval(2),
            calendars: nil
        )
        return store.events(matching: predicate)
    }
}

private extension CalendarWriteSpan {
    var eventKitSpan: EKSpan {
        switch self {
        case .thisEvent: .thisEvent
        case .futureEvents: .futureEvents
        }
    }
}

struct AppleCalendarUpdateTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var action: String; var id: String?; var occurrence: String?; var span: String?
        var title: String?; var start: String?; var end: String?
        var notes: String?; var location: String?; var isAllDay: Bool?
    }
    static let name = "apple.calendar.update"
    static let toolDescription = "Create, update, or delete an Apple Calendar event. For update/delete, use the id and the exact occurrence token returned by apple.calendar.list. span selects thisEvent (default) or futureEvents for a recurring series. Recurring or detached events require occurrence; missing, stale or ambiguous occurrences fail without changing another instance. Read-back verifies the selected target occurrence (verificationScope=targetOccurrence); for futureEvents it does not enumerate every future instance."
    static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["create","update","delete"]},"id":{"type":"string"},"occurrence":{"type":"string","maxLength":2048},"span":{"type":"string","enum":["thisEvent","futureEvents"]},"title":{"type":"string"},"start":{"type":"string"},"end":{"type":"string"},"notes":{"type":"string"},"location":{"type":"string"},"isAllDay":{"type":"boolean"}},"required":["action"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    func validate(_ args: Arguments) throws {
        guard ["create", "update", "delete"].contains(args.action) else { throw FloeError.validationFailed("Unsupported calendar action") }
        if args.action == "create" {
            do {
                try CalendarOccurrenceResolver.validateCreate(
                    occurrenceToken: args.occurrence,
                    spanRaw: args.span
                )
            } catch let error as CalendarOccurrenceError {
                throw Self.occurrenceFailure(error)
            }
            if args.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                throw FloeError.validationFailed("title is required")
            }
            return
        }
        if args.id?.isEmpty != false { throw FloeError.validationFailed("id is required") }
        let id = args.id!
        let span = try Self.parsedSpan(args.span)
        if let occurrence = args.occurrence {
            _ = try Self.boundOccurrence(id: id, token: occurrence)
        } else if span == .futureEvents {
            throw Self.occurrenceFailure(.futureEventsRequiresOccurrence)
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard ["create", "update", "delete"].contains(args.action) else {
            throw FloeError.validationFailed("Unsupported calendar action")
        }
        if args.action != "create", args.id?.isEmpty != false {
            throw FloeError.validationFailed("id is required")
        }
        if args.action == "create",
           args.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw FloeError.validationFailed("title is required")
        }
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else { return AppleToolOutput.make("status=permissionDenied capability=calendar", exitStatus: 77) }
        let span = try Self.parsedSpan(args.span)
        if args.action == "create" {
            // validate() already enforces this; keep execute fail-closed when
            // it is invoked directly by a test or another caller.
            do {
                try CalendarOccurrenceResolver.validateCreate(
                    occurrenceToken: args.occurrence,
                    spanRaw: args.span
                )
            } catch let error as CalendarOccurrenceError {
                throw Self.occurrenceFailure(error)
            }
            let event = EKEvent(eventStore: store)
            event.calendar = store.defaultCalendarForNewEvents
            try Self.applyFields(args, to: event, isCreate: true)
            try store.save(event, span: .thisEvent, commit: true)
            return AppleToolOutput.make("status=ok action=create id=\(event.eventIdentifier ?? "unknown")")
        }
        if args.action == "delete" {
            return try Self.delete(args, span: span, store: store)
        }
        return try Self.update(args, span: span, store: store)
    }

    private static func update(
        _ args: Arguments,
        span: CalendarWriteSpan,
        store: EKEventStore
    ) throws -> ToolExecutionOutput {
        let id = args.id!
        if let token = args.occurrence {
            let identity = try Self.boundOccurrence(id: id, token: token)
            let requestedStart = try Self.requestedStart(args, fallback: identity.start)
            let writer = CalendarOccurrenceWriter(adapter: EventKitCalendarOccurrenceAdapter(
                store: store,
                prepare: { event in
                    try Self.applyFields(args, to: event, isCreate: false)
                }
            ))
            let target: EventKitOccurrenceTarget
            do {
                target = try writer.apply(identity: identity, span: span, operation: .save)
            } catch let error as CalendarOccurrenceError {
                throw Self.occurrenceFailure(error)
            }
            return try Self.finishUpdate(
                args: args,
                span: span,
                target: target,
                store: store,
                requestedStart: requestedStart
            )
        }
        guard let event = store.event(withIdentifier: id) else {
            throw FloeError.notFound("calendar event")
        }
        do {
            try CalendarOccurrenceResolver.validateLegacyWrite(
                hasRecurrenceRules: event.hasRecurrenceRules,
                isDetached: event.isDetached,
                span: span
            )
        } catch let error as CalendarOccurrenceError {
            throw Self.occurrenceFailure(error)
        }
        guard let legacyStartDate = event.startDate else {
            throw FloeError.notFound("calendar event")
        }
        let legacyStart = CalendarOccurrenceIdentity(
            eventIdentifier: id,
            start: legacyStartDate
        ).start
        let requestedStart = try Self.requestedStart(args, fallback: legacyStart)
        try Self.applyFields(args, to: event, isCreate: false)
        try store.save(event, span: .thisEvent, commit: true)
        return try Self.finishUpdate(
            args: args,
            span: .thisEvent,
            target: EventKitOccurrenceTarget(event: event),
            store: store,
            requestedStart: requestedStart
        )
    }

    private static func delete(
        _ args: Arguments,
        span: CalendarWriteSpan,
        store: EKEventStore
    ) throws -> ToolExecutionOutput {
        let id = args.id!
        if let token = args.occurrence {
            let identity = try Self.boundOccurrence(id: id, token: token)
            let writer = CalendarOccurrenceWriter(adapter: EventKitCalendarOccurrenceAdapter(
                store: store,
                prepare: { _ in }
            ))
            do {
                _ = try writer.apply(identity: identity, span: span, operation: .remove)
            } catch let error as CalendarOccurrenceError {
                throw Self.occurrenceFailure(error)
            }
            // Read-back proves the selected occurrence is gone. For
            // futureEvents it deliberately does not enumerate every later
            // instance; the response names the narrower scope.
            guard AppleCalendarWriteReadback.occurrenceIsAbsent(store: store, identity: identity) else {
                throw FloeError.validationFailed("Calendar occurrence is still present after delete; no success was claimed. Re-list the calendar before retrying.")
            }
            return AppleToolOutput.make(
                "status=ok action=delete id=\(identity.eventIdentifier)"
                    + " occurrence=\(identity.token) span=\(span.rawValue)"
                    + " verified=true readback=absent verificationScope=targetOccurrence"
            )
        }
        guard let event = store.event(withIdentifier: id) else {
            throw FloeError.notFound("calendar event")
        }
        do {
            try CalendarOccurrenceResolver.validateLegacyWrite(
                hasRecurrenceRules: event.hasRecurrenceRules,
                isDetached: event.isDetached,
                span: span
            )
        } catch let error as CalendarOccurrenceError {
            throw Self.occurrenceFailure(error)
        }
        guard let startDate = event.startDate else {
            throw FloeError.notFound("calendar event")
        }
        let identity = CalendarOccurrenceIdentity(eventIdentifier: id, start: startDate)
        try store.remove(event, span: .thisEvent, commit: true)
        guard AppleCalendarWriteReadback.occurrenceIsAbsent(store: store, identity: identity) else {
            throw FloeError.validationFailed("Calendar event is still present after delete; no success was claimed. Re-list the calendar before retrying.")
        }
        return AppleToolOutput.make(
            "status=ok action=delete id=\(identity.eventIdentifier)"
                + " occurrence=\(identity.token) span=thisEvent"
                + " verified=true readback=absent verificationScope=targetOccurrence"
        )
    }

    private static func finishUpdate(
        args: Arguments,
        span: CalendarWriteSpan,
        target: EventKitOccurrenceTarget,
        store: EKEventStore,
        requestedStart: Date
    ) throws -> ToolExecutionOutput {
        let event = target.event
        guard let finalID = event.eventIdentifier, !finalID.isEmpty,
              let finalStart = event.startDate else {
            throw FloeError.validationFailed("Calendar event has no readable identity after save; no content verification was possible.")
        }
        let finalIdentity = CalendarOccurrenceIdentity(eventIdentifier: finalID, start: finalStart)
        let expectedEnd = args.end == nil ? nil : try? AppleToolOutput.date(args.end)
        // The read-back is bound to the start requested by this call (or the
        // selected occurrence's start when start was not edited), not to
        // whatever start the engine may have produced after save. A moved or
        // normalized-away start therefore reports verified=false instead of
        // being silently accepted as the requested content.
        let expected = AppleCalendarExpectedUpdate(
            eventIdentifier: finalID,
            calendarItemIdentifier: event.calendarItemIdentifier,
            start: CalendarOccurrenceIdentity.canonicalStart(requestedStart),
            end: expectedEnd,
            title: args.title,
            notes: args.notes,
            location: args.location,
            isAllDay: args.isAllDay
        )
        // Future-series writes are saved with EventKit's span, but the
        // read-back can only prove the selected occurrence and its content.
        // The response therefore names targetOccurrence rather than implying
        // that every later instance was re-read.
        let readback = AppleCalendarWriteReadback.updatedEvent(store: store, expected: expected)
        let verified = readback != nil
        let responseID = readback?.eventIdentifier ?? finalID
        let responseStart = readback?.startDate ?? finalIdentity.start
        let responseIdentity = CalendarOccurrenceIdentity(
            eventIdentifier: responseID,
            start: responseStart
        )
        return AppleToolOutput.make(
            "status=ok action=update id=\(responseID)"
                + " occurrence=\(responseIdentity.token) span=\(span.rawValue)"
                + " verified=\(verified)"
                + " readback=\(verified ? "occurrence" : "unconfirmed")"
                + " verificationScope=targetOccurrence"
        )
    }

    private static func applyFields(
        _ args: Arguments,
        to event: EKEvent,
        isCreate: Bool
    ) throws {
        if let title = args.title { event.title = title }
        if let start = try AppleToolOutput.date(args.start) { event.startDate = start }
        if let end = try AppleToolOutput.date(args.end) { event.endDate = end }
        if isCreate, event.startDate == nil {
            throw FloeError.validationFailed("start is required")
        }
        if isCreate, event.endDate == nil {
            event.endDate = event.startDate.addingTimeInterval(3600)
        }
        if let start = event.startDate, let end = event.endDate, end < start {
            throw FloeError.validationFailed("end must not precede start")
        }
        if let notes = args.notes { event.notes = notes }
        if let location = args.location { event.location = location }
        if let isAllDay = args.isAllDay { event.isAllDay = isAllDay }
    }

    private static func parsedSpan(_ raw: String?) throws -> CalendarWriteSpan {
        do {
            return try CalendarOccurrenceResolver.parseSpan(raw)
        } catch let error as CalendarOccurrenceError {
            throw Self.occurrenceFailure(error)
        }
    }

    private static func boundOccurrence(
        id: String,
        token: String
    ) throws -> CalendarOccurrenceIdentity {
        do {
            return try CalendarOccurrenceResolver.bind(
                eventIdentifier: id,
                occurrenceToken: token
            )
        } catch let error as CalendarOccurrenceError {
            throw Self.occurrenceFailure(error)
        }
    }

    private static func requestedStart(_ args: Arguments, fallback: Date) throws -> Date {
        guard args.start != nil else {
            return CalendarOccurrenceIdentity.canonicalStart(fallback)
        }
        guard let parsed = try AppleToolOutput.date(args.start) else {
            return CalendarOccurrenceIdentity.canonicalStart(fallback)
        }
        return CalendarOccurrenceIdentity.canonicalStart(parsed)
    }

    private static func occurrenceFailure(_ error: CalendarOccurrenceError) -> FloeError {
        FloeError.validationFailed(error.errorDescription ?? "Invalid calendar occurrence")
    }
}

struct AppleReminderListTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var includeCompleted: Bool?; var query: String?
        var limit: Int?; var cursor: String?
    }
    static let name = "apple.reminders.list"
    static let toolDescription = "List Apple Reminders after system permission. Returns stable identifiers for completion or edits. Pages are stable snapshots: limit defaults to 100 (maximum 200); when hasMore is true, pass nextCursor back as cursor to continue the SAME snapshot. A cursor is owned by the task that started it and reports explicit errors when expired, revoked or given different filters."
    static let parametersJSON = #"{"type":"object","properties":{"includeCompleted":{"type":"boolean"},"query":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":200},"cursor":{"type":"string","maxLength":2048}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = false
    func validate(_ args: Arguments) throws {
        if let limit = args.limit, !(1...200).contains(limit) {
            throw FloeError.validationFailed("limit must be 1...200")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let limit = args.limit ?? 100
        guard (1...200).contains(limit) else {
            throw FloeError.validationFailed("limit must be 1...200")
        }
        if let cursor = args.cursor {
            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                return AppleToolOutput.make("status=permissionDenied capability=reminders", exitStatus: 77)
            }
            let filterKey = Self.canonicalFilterKey(args, required: false)
            do {
                let page = try await ApplePersonalListPaging.next(
                    cursor: cursor,
                    context: context,
                    kind: "reminders",
                    filterKey: filterKey,
                    pageSize: limit
                )
                return AppleToolOutput.page(page, kind: "reminders")
            } catch let error as PersonalToolCursorError {
                return AppleToolOutput.cursorError(error)
            }
        }
        let store = EKEventStore()
        if context.temporaryReadOnly || context.publicWebOnly {
            // A temporary read uses existing access and never requests a
            // broader EventKit authorization as a side effect of reading.
            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                return AppleToolOutput.make("status=permissionDenied capability=reminders", exitStatus: 77)
            }
        } else if !(try await store.requestFullAccessToReminders()) {
            return AppleToolOutput.make("status=permissionDenied capability=reminders", exitStatus: 77)
        }
        let query = args.query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let includeCompleted = args.includeCompleted ?? false
        let predicate = store.predicateForReminders(in: nil)
        let lines: [String] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let values = (reminders ?? []).filter {
                    (includeCompleted || !$0.isCompleted)
                        && (query?.isEmpty != false || $0.title.lowercased().contains(query ?? ""))
                }.sorted { lhs, rhs in
                    if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
                    let lhsDue = lhs.dueDateComponents.flatMap(Calendar.current.date(from:))
                    let rhsDue = rhs.dueDateComponents.flatMap(Calendar.current.date(from:))
                    switch (lhsDue, rhsDue) {
                    case (nil, nil): break
                    case (nil, _): return false
                    case (_, nil): return true
                    case let (left?, right?):
                        if left != right { return left < right }
                    }
                    if lhs.title != rhs.title { return lhs.title < rhs.title }
                    return lhs.calendarItemIdentifier < rhs.calendarItemIdentifier
                }.map {
                    let due = $0.dueDateComponents.flatMap(Calendar.current.date(from:))
                    return "id=\($0.calendarItemIdentifier) completed=\($0.isCompleted) due=\(AppleToolOutput.iso(due)) list=\($0.calendar.title) title=\($0.title ?? "")"
                }
                continuation.resume(returning: values)
            }
        }
        do {
            let page = try await ApplePersonalListPaging.begin(
                kind: "reminders",
                filterKey: Self.canonicalFilterKey(args, required: true) ?? Self.emptyFilterKey,
                lines: lines,
                context: context,
                pageSize: limit
            )
            return AppleToolOutput.page(page, kind: "reminders")
        } catch let error as PersonalToolCursorError {
            return AppleToolOutput.cursorError(error)
        }
    }

    /// Canonical filter identity. With `required == false` the key is only
    /// produced when the caller supplied filters, so a bare cursor
    /// continuation stays valid.
    private static func canonicalFilterKey(_ args: Arguments, required: Bool) -> String? {
        let hasAny = args.query != nil || args.includeCompleted != nil
        guard hasAny else { return required ? emptyFilterKey : nil }
        let query = args.query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return "query=\(query) includeCompleted=\(args.includeCompleted ?? false)"
    }

    private static let emptyFilterKey = "query= includeCompleted=false"
}

struct AppleReminderUpdateTool: AgentTool {
    struct Arguments: Decodable, Sendable { var action: String; var id: String?; var title: String?; var due: String?; var notes: String?; var completed: Bool? }
    static let name = "apple.reminders.update"
    static let toolDescription = "Create, update, complete, or delete an Apple Reminder. Use an id returned by apple.reminders.list."
    static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["create","update","delete"]},"id":{"type":"string"},"title":{"type":"string"},"due":{"type":"string"},"notes":{"type":"string"},"completed":{"type":"boolean"}},"required":["action"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    func validate(_ args: Arguments) throws {
        guard ["create", "update", "delete"].contains(args.action) else { throw FloeError.validationFailed("Unsupported reminder action") }
        if args.action != "create", args.id?.isEmpty != false { throw FloeError.validationFailed("id is required") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else { return AppleToolOutput.make("status=permissionDenied capability=reminders", exitStatus: 77) }
        if args.action == "delete" {
            guard let item = store.calendarItem(withIdentifier: args.id!) as? EKReminder else { throw FloeError.notFound("reminder") }
            try store.remove(item, commit: true)
            return AppleToolOutput.make("status=ok action=delete id=\(args.id!)")
        }
        let reminder: EKReminder
        if args.action == "update" {
            guard let item = store.calendarItem(withIdentifier: args.id!) as? EKReminder else { throw FloeError.notFound("reminder") }
            reminder = item
        } else {
            reminder = EKReminder(eventStore: store)
            reminder.calendar = store.defaultCalendarForNewReminders()
        }
        if let title = args.title { reminder.title = title }
        if args.action == "create", reminder.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw FloeError.validationFailed("title is required") }
        if let due = try AppleToolOutput.date(args.due) { reminder.dueDateComponents = Calendar.current.dateComponents(in: .current, from: due) }
        if let notes = args.notes { reminder.notes = notes }
        if let completed = args.completed { reminder.isCompleted = completed; reminder.completionDate = completed ? Date() : nil }
        try store.save(reminder, commit: true)
        return AppleToolOutput.make("status=ok action=\(args.action) id=\(reminder.calendarItemIdentifier)")
    }
}

struct AppleMapsSearchTool: AgentTool {
    struct Arguments: Decodable, Sendable { var query: String; var latitude: Double?; var longitude: Double? }
    static let name = "apple.maps.search"
    static let toolDescription = "Search places with Apple MapKit and return structured names, addresses, and coordinates."
    static let parametersJSON = #"{"type":"object","properties":{"query":{"type":"string"},"latitude":{"type":"number"},"longitude":{"type":"number"}},"required":["query"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.networkAccess]
    static let isSideEffecting = false
    func validate(_ args: Arguments) throws { if args.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw FloeError.validationFailed("query is required") } }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = args.query
        if let lat = args.latitude, let lon = args.longitude {
            request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon), latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        let response = try await MKLocalSearch(request: request).start()
        let lines = response.mapItems.prefix(20).map { item in
            let coordinate = item.location.coordinate
            return "name=\(item.name ?? "") address=\(item.addressRepresentations?.fullAddress(includingRegion: true, singleLine: true) ?? "") latitude=\(coordinate.latitude) longitude=\(coordinate.longitude)"
        }
        return AppleToolOutput.make("status=ok count=\(lines.count)\n" + lines.joined(separator: "\n"))
    }
}

struct AppleMapsOpenTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var name: String?
        var latitude: Double
        var longitude: Double
        var directionsMode: String?
    }
    static let name = "apple.maps.open"
    static let toolDescription = "Open a place or route in Apple Maps. This only presents system UI; the user remains in control."
    static let parametersJSON = #"{"type":"object","properties":{"name":{"type":"string"},"latitude":{"type":"number"},"longitude":{"type":"number"},"directionsMode":{"type":"string","enum":["driving","walking","transit"]}},"required":["latitude","longitude"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    func validate(_ args: Arguments) throws {
        guard (-90...90).contains(args.latitude), (-180...180).contains(args.longitude) else {
            throw FloeError.validationFailed("Invalid map coordinates")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let opened = await openMapItem(args)
        return AppleToolOutput.make("status=\(opened ? "presented" : "unavailable") userConfirmationRequired=true")
    }
}

struct AppleMailComposeTool: AgentTool {
    struct Arguments: Decodable, Sendable { var to: [String]?; var cc: [String]?; var subject: String?; var body: String? }
    static let name = "apple.mail.compose"
    static let toolDescription = "Open Apple's mail compose UI with a draft. This tool does not send mail; the user must review and tap Send. For configured generic SMTP accounts, use mail.send after approval."
    static let parametersJSON = #"{"type":"object","properties":{"to":{"type":"array","items":{"type":"string"}},"cc":{"type":"array","items":{"type":"string"}},"subject":{"type":"string"},"body":{"type":"string"}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    func validate(_ args: Arguments) throws {
        let all = (args.to ?? []) + (args.cc ?? [])
        guard all.allSatisfy({ $0.count <= 320 && !$0.contains("\n") && !$0.contains("\r") }) else {
            throw FloeError.validationFailed("Invalid mail recipient")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = (args.to ?? []).joined(separator: ",")
        var items: [URLQueryItem] = []
        if let cc = args.cc, !cc.isEmpty { items.append(URLQueryItem(name: "cc", value: cc.joined(separator: ","))) }
        if let subject = args.subject { items.append(URLQueryItem(name: "subject", value: String(subject.prefix(998)))) }
        if let body = args.body { items.append(URLQueryItem(name: "body", value: String(body.prefix(20_000)))) }
        components.queryItems = items
        guard let url = components.url else { throw FloeError.validationFailed("Unable to create mail draft URL") }
        let opened = await openSystemURL(url)
        return AppleToolOutput.make("status=\(opened ? "presented" : "unavailable") sent=false userConfirmationRequired=true")
    }
}

@MainActor
private final class HomeAccessBroker: NSObject {
    static let shared = HomeAccessBroker()
    private let manager = HMHomeManager()
    override init() { super.init(); manager.delegate = self }

    func snapshot() async -> String {
        if manager.homes.isEmpty { try? await Task.sleep(for: .seconds(1)) }
        var lines: [String] = []
        for home in manager.homes {
            for accessory in home.accessories {
                for service in accessory.services {
                    for characteristic in service.characteristics where characteristic.properties.contains(HMCharacteristicPropertyReadable) {
                        lines.append("home=\(home.name) room=\(accessory.room?.name ?? "") accessory=\(accessory.name) accessoryID=\(accessory.uniqueIdentifier.uuidString) service=\(service.name) characteristic=\(characteristic.localizedDescription) characteristicID=\(characteristic.uniqueIdentifier.uuidString) value=\(String(describing: characteristic.value)) writable=\(characteristic.properties.contains(HMCharacteristicPropertyWritable))")
                        if lines.count >= 400 { break }
                    }
                    if lines.count >= 400 { break }
                }
                if lines.count >= 400 { break }
            }
            if lines.count >= 400 { break }
        }
        let status = manager.homes.isEmpty ? "emptyOrUnauthorized" : "ok"
        return "status=\(status) homes=\(manager.homes.count)\n" + lines.joined(separator: "\n")
    }

    func write(accessoryID: String, characteristicID: String, rawValue: String) async throws {
        if manager.homes.isEmpty { try? await Task.sleep(for: .seconds(1)) }
        let characteristic = manager.homes.lazy.flatMap(\.accessories)
            .first(where: { $0.uniqueIdentifier.uuidString == accessoryID })?
            .services.lazy.flatMap(\.characteristics)
            .first(where: { $0.uniqueIdentifier.uuidString == characteristicID })
        guard let characteristic, characteristic.properties.contains(HMCharacteristicPropertyWritable) else {
            throw FloeError.notFound("writable HomeKit characteristic")
        }
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: Any = if ["true", "on", "yes", "1"].contains(raw.lowercased()) { true }
        else if ["false", "off", "no", "0"].contains(raw.lowercased()) { false }
        else if let number = Double(raw) { number }
        else { raw }
        try await characteristic.writeValue(value)
    }

}

extension HomeAccessBroker: @preconcurrency HMHomeManagerDelegate {
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        // HMHomeManager owns the latest snapshot. Tools read it on demand.
    }
}

struct AppleHomeListTool: AgentTool {
    struct Arguments: Decodable, Sendable {}
    static let name = "apple.home.list"
    static let toolDescription = "List HomeKit homes, rooms, accessories, services, and readable characteristics after system authorization."
    static let parametersJSON = #"{"type":"object","additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = false
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        return AppleToolOutput.make(await HomeAccessBroker.shared.snapshot())
    }
}

struct AppleHomeControlTool: AgentTool {
    struct Arguments: Decodable, Sendable { var accessoryID: String; var characteristicID: String; var value: String }
    static let name = "apple.home.control"
    static let toolDescription = "Write one explicitly identified writable HomeKit characteristic. List Home first; never guess identifiers."
    static let parametersJSON = #"{"type":"object","properties":{"accessoryID":{"type":"string"},"characteristicID":{"type":"string"},"value":{"type":"string"}},"required":["accessoryID","characteristicID","value"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI, .persistsPersonalData]
    static let isSideEffecting = true
    func validate(_ args: Arguments) throws {
        guard UUID(uuidString: args.accessoryID) != nil, UUID(uuidString: args.characteristicID) != nil else {
            throw FloeError.validationFailed("Home identifiers must come from apple.home.list")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try await HomeAccessBroker.shared.write(
            accessoryID: args.accessoryID,
            characteristicID: args.characteristicID,
            rawValue: args.value
        )
        return AppleToolOutput.make("status=ok characteristicID=\(args.characteristicID)")
    }
}

@MainActor
private final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()
    private let session: WCSession? = WCSession.isSupported() ? .default : nil
    override init() { super.init(); session?.delegate = self; session?.activate() }
    func status() -> String {
        guard let session else { return "supported=false" }
        return "supported=true paired=\(session.isPaired) appInstalled=\(session.isWatchAppInstalled) reachable=\(session.isReachable) state=\(session.activationState.rawValue)"
    }
    func send(title: String, status: String) async throws {
        guard let session, session.isPaired, session.isWatchAppInstalled else { throw FloeError.validationFailed("Floe Watch app is not installed") }
        let payload = ["title": String(title.prefix(200)), "status": String(status.prefix(1_000)), "sentAt": Date().timeIntervalSince1970] as [String: Any]
        if session.isReachable {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.sendMessage(payload, replyHandler: { _ in continuation.resume() }, errorHandler: { continuation.resume(throwing: $0) })
            }
        } else {
            try session.updateApplicationContext(payload)
        }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}

struct AppleWatchStatusTool: AgentTool {
    struct Arguments: Decodable, Sendable {}
    static let name = "apple.watch.status"
    static let toolDescription = "Report whether a paired Apple Watch and the Floe Watch companion are available."
    static let parametersJSON = #"{"type":"object","additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        AppleToolOutput.make("status=ok " + (await WatchBridge.shared.status()))
    }
}

struct AppleWatchUpdateTool: AgentTool {
    struct Arguments: Decodable, Sendable { var title: String; var status: String }
    static let name = "apple.watch.update"
    static let toolDescription = "Send a bounded task status update to the paired Floe Watch companion, or queue the latest status when unreachable."
    static let parametersJSON = #"{"type":"object","properties":{"title":{"type":"string"},"status":{"type":"string"}},"required":["title","status"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    func validate(_ args: Arguments) throws { if args.title.isEmpty { throw FloeError.validationFailed("title is required") } }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await WatchBridge.shared.send(title: args.title, status: args.status)
        return AppleToolOutput.make("status=queuedOrDelivered")
    }
}

/// One-shot fix for an explicit weather/nearby step in a real task.
///
/// The shared `LocationServicesCenter` owns authorization, request identity,
/// timeouts and the optional background assist; this tool keeps its identity,
/// schema and output shape unchanged. A fix may complete while the app is in
/// the background when an eligible run prepared the session in the foreground
/// and the existing weather/search tools then return the result to the same
/// task.
struct AppleCurrentLocationTool: AgentTool {
    struct Arguments: Decodable, Sendable {}
    private let locationService: LocationServicesCenter?
    init(locationService: LocationServicesCenter? = nil) {
        self.locationService = locationService
    }
    static let name = "apple.location.current"
    static let toolDescription = "Request one current location fix through Core Location. The system owns permission and may deny it."
    static let parametersJSON = #"{"type":"object","additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        // Temporary (ephemeral) conversations use only the EXISTING
        // authorization answer: they never consume the single system prompt.
        // Ordinary runs keep the established request-on-first-use behavior.
        let value = try await currentLocation(
            allowsAuthorizationRequest: !(context.temporaryReadOnly || context.publicWebOnly))
        // A run cancelled while the fix was in flight must not expose a
        // location it just received.
        try context.cancellation.throwIfCancelled()
        return AppleToolOutput.make("status=ok latitude=\(value.latitude) longitude=\(value.longitude) accuracyMeters=\(value.accuracy) timestamp=\(AppleToolOutput.iso(value.timestamp))")
    }
}

extension AppleCurrentLocationTool {
    @MainActor
    private func currentLocation(allowsAuthorizationRequest: Bool) async throws -> SendableLocation {
        try await (locationService ?? LocationServicesCenter.shared)
            .currentLocation(allowsAuthorizationRequest: allowsAuthorizationRequest)
    }
}

struct AppleAutomationListTool: AgentTool {
    struct Arguments: Decodable, Sendable { var includeDisabled: Bool? }
    static let name = "apple.automation.list"
    static let toolDescription = "List Floe scheduled automations, including the next expected and last actual start times."
    static let parametersJSON = #"{"type":"object","properties":{"includeDisabled":{"type":"boolean"}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = false
    let store: SQLiteTaskScheduleStore
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let schedules = try await store.schedules().filter { (args.includeDisabled ?? false) || $0.isEnabled }
        let lines = schedules.prefix(200).map {
            "id=\($0.id.uuidString) enabled=\($0.isEnabled) cadence=\($0.cadence.rawValue) scheduled=\(AppleToolOutput.iso($0.scheduledAt)) next=\(AppleToolOutput.iso($0.nextExpectedAt)) lastStarted=\(AppleToolOutput.iso($0.lastStartedAt)) title=\($0.title)"
        }
        return AppleToolOutput.make("status=ok count=\(lines.count)\n" + lines.joined(separator: "\n"))
    }
}

struct AppleAutomationUpdateTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var action: String
        var id: String?
        var title: String?
        var prompt: String?
        var scheduledAt: String?
        var cadence: String?
        var enabled: Bool?
    }
    static let name = "apple.automation.update"
    static let toolDescription = "Create, update, enable/disable, or delete a Floe scheduled automation. iOS scheduling is best effort and does not promise minute-exact execution."
    static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["create","update","delete"]},"id":{"type":"string"},"title":{"type":"string"},"prompt":{"type":"string"},"scheduledAt":{"type":"string"},"cadence":{"type":"string","enum":["once","daily","weekly"]},"enabled":{"type":"boolean"}},"required":["action"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData, .changesAgentBehavior]
    static let isSideEffecting = true
    let store: SQLiteTaskScheduleStore
    /// The SAME trusted binding factory the `task.schedule` tool uses: a new
    /// automation freezes the model/project/environment/permission of the
    /// ACTUAL submitting run instead of leaving mutable nil bindings that a
    /// later settings change could quietly redefine. A build without the
    /// resolver refuses `create`.
    let bindingResolver: TaskScheduleBindingResolver?
    /// One real due pass after a successful create/enable, when the app can.
    let onScheduleDue: (@Sendable () async -> Void)?

    init(
        store: SQLiteTaskScheduleStore,
        bindingResolver: TaskScheduleBindingResolver? = nil,
        onScheduleDue: (@Sendable () async -> Void)? = nil
    ) {
        self.store = store
        self.bindingResolver = bindingResolver
        self.onScheduleDue = onScheduleDue
    }
    func validate(_ args: Arguments) throws {
        guard ["create", "update", "delete"].contains(args.action) else { throw FloeError.validationFailed("Unsupported automation action") }
        if args.action != "create", args.id.flatMap(UUID.init(uuidString:)) == nil { throw FloeError.validationFailed("A valid id is required") }
        if args.action == "create", args.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { throw FloeError.validationFailed("prompt is required") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        if args.action == "delete" {
            let id = UUID(uuidString: args.id!)!
            try await store.delete(id: id)
            return AppleToolOutput.make("status=ok action=delete id=\(id.uuidString)")
        }
        var record: TaskScheduleRecord
        if args.action == "update" {
            let id = UUID(uuidString: args.id!)!
            guard let current = try await store.schedules().first(where: { $0.id == id }) else { throw FloeError.notFound("automation") }
            record = current
        } else {
            let prompt = args.prompt!.trimmingCharacters(in: .whitespacesAndNewlines)
            let date = try AppleToolOutput.date(args.scheduledAt) ?? Date().addingTimeInterval(300)
            let cadence = args.cadence.flatMap(TaskScheduleCadence.init(rawValue:)) ?? .once
            // Trusted creation-time bindings from the ACTUAL submitting run
            // (same factory as `task.schedule`). Never nil-by-default: a
            // schedule created now must not silently follow a later model or
            // permission change.
            guard let resolver = bindingResolver,
                  let binding = await resolver(context) else {
                throw FloeError.validationFailed(
                    "Scheduled automations require the app's trusted binding resolver; no automation was created.")
            }
            record = TaskScheduleRecord(
                title: args.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? String(prompt.prefix(40)),
                prompt: prompt,
                workspaceID: binding.workspaceID,
                cadence: cadence,
                scheduledAt: date,
                weekday: cadence == .weekly ? Calendar.current.component(.weekday, from: date) : nil,
                isEnabled: args.enabled ?? true,
                anchorTimezone: binding.anchorTimezone ?? TimeZone.current.identifier,
                modelID: binding.modelID,
                environmentID: binding.environmentID,
                permissionJSON: binding.permissionJSON
            )
        }
        if let title = args.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { record.title = title }
        if let prompt = args.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty { record.prompt = prompt }
        if let date = try AppleToolOutput.date(args.scheduledAt) { record.scheduledAt = date; record.nextExpectedAt = date }
        if let cadence = args.cadence.flatMap(TaskScheduleCadence.init(rawValue:)) { record.cadence = cadence }
        if let enabled = args.enabled {
            record.isEnabled = enabled
            if enabled {
                record.nextExpectedAt = record.nextExpectedAt ?? record.scheduledAt
            }
        }
        record.weekday = record.cadence == .weekly ? Calendar.current.component(.weekday, from: record.scheduledAt) : nil
        record.updatedAt = Date()
        try await store.save(record)
        if record.isEnabled, let next = record.nextExpectedAt {
            await BackgroundPolicyRegistry.shared.scheduleRefresh(earliest: next)
        }
        if record.isEnabled, record.nextExpectedAt != nil {
            await onScheduleDue?()
        }
        return AppleToolOutput.make("status=ok action=\(args.action) id=\(record.id.uuidString) next=\(AppleToolOutput.iso(record.nextExpectedAt)) bestEffort=true")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Clipboard

struct AppleClipboardWriteTool: AgentTool {
    struct Arguments: Decodable, Sendable { var text: String }
    static let name = "apple.clipboard.write"
    static let toolDescription = "Copy text to the system clipboard. The clipboard is shared with every app, so only copy content the user asked to copy."
    static let parametersJSON = #"{"type":"object","properties":{"text":{"type":"string","maxLength":100000}},"required":["text"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    func validate(_ args: Arguments) throws {
        guard args.text.utf8.count <= 100_000 else {
            throw FloeError.validationFailed("clipboard text exceeds 100000 bytes")
        }
    }
    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        UIPasteboard.general.string = args.text
        return AppleToolOutput.make("status=ok characters=\(args.text.count)")
    }
}

struct AppleClipboardReadTool: AgentTool {
    struct Arguments: Decodable, Sendable {}
    static let name = "apple.clipboard.read"
    static let toolDescription = "Read text from the system clipboard. iOS notifies the user about clipboard access; read only when the user asked for clipboard content. Reports availability flags when no text is present."
    static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = false
    func validate(_ args: Arguments) throws {}
    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let pasteboard = UIPasteboard.general
        if let text = pasteboard.string {
            let clipped = text.count > 100_000 ? String(text.prefix(100_000)) : text
            return AppleToolOutput.make("status=ok truncated=\(clipped.count < text.count)\n\(clipped)")
        }
        return AppleToolOutput.make("status=empty hasStrings=\(pasteboard.hasStrings) hasURLs=\(pasteboard.hasURLs) hasImages=\(pasteboard.hasImages)")
    }
}

// MARK: - Shortcuts

struct AppleShortcutsRunTool: AgentTool {
    struct Arguments: Decodable, Sendable { var name: String; var input: String? }
    static let name = "apple.shortcuts.run"
    static let toolDescription = "Open the Shortcuts app and run one of the user's own shortcuts by exact name, optionally passing text input. The Shortcuts app stays in control of execution and consent; Floe cannot observe the shortcut's output."
    static let parametersJSON = #"{"type":"object","properties":{"name":{"type":"string","maxLength":200},"input":{"type":"string","maxLength":10000}},"required":["name"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    func validate(_ args: Arguments) throws {
        let name = args.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("\n"), !name.contains("\r") else {
            throw FloeError.validationFailed("Shortcut name must be a single non-empty line")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        var items = [URLQueryItem(name: "name", value: args.name.trimmingCharacters(in: .whitespacesAndNewlines))]
        if let input = args.input {
            items.append(URLQueryItem(name: "input", value: "text"))
            items.append(URLQueryItem(name: "text", value: String(input.prefix(10_000))))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw FloeError.validationFailed("Unable to create Shortcuts URL")
        }
        let opened = await openSystemURL(url)
        return AppleToolOutput.make("status=\(opened ? "presented" : "unavailable") outputObservable=false userConfirmationRequired=true")
    }
}

// MARK: - Camera

@MainActor
private final class CameraCaptureCoordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    /// Strong self-retention for the duration of the system camera session;
    /// the picker only holds its delegate weakly.
    private static var active: CameraCaptureCoordinator?
    private var continuation: CheckedContinuation<UIImage?, Never>?

    func capture() async -> UIImage? {
        Self.active = self
        let image = await withCheckedContinuation { continuation in
            self.continuation = continuation
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.cameraCaptureMode = .photo
            picker.delegate = self
            Self.topViewController()?.present(picker, animated: true)
        }
        Self.active = nil
        return image
    }

    private func finish(_ image: UIImage?, afterDismissalOf picker: UIImagePickerController) {
        picker.dismiss(animated: true) { [weak self] in
            guard let self, let continuation = self.continuation else { return }
            self.continuation = nil
            continuation.resume(returning: image)
        }
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        finish(info[.originalImage] as? UIImage, afterDismissalOf: picker)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        finish(nil, afterDismissalOf: picker)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

struct AppleCameraCaptureTool: AgentTool {
    struct Arguments: Decodable, Sendable { var outputPath: String?; var quality: Double? }
    static let name = "apple.camera.capture"
    static let toolDescription = "Open the system camera so the user can take a photo for this task. The photo is only captured if the user takes it themselves in the system camera UI; it is then saved as a new workspace JPEG. Never claim a capture happened without a saved file path."
    static let parametersJSON = #"{"type":"object","properties":{"outputPath":{"type":"string","description":"Workspace-relative JPEG path; defaults to Camera/capture-<id>.jpg"},"quality":{"type":"number","description":"JPEG quality 0..1 (default 0.9)"}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI, .writesFiles]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    func validate(_ args: Arguments) throws {
        if let outputPath = args.outputPath {
            let path = outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"),
                  !path.split(separator: "/").contains("..") else {
                throw FloeError.validationFailed("outputPath must be workspace-relative")
            }
        }
        if let quality = args.quality, !(0.01...1).contains(quality) {
            throw FloeError.validationFailed("quality must be 0.01-1")
        }
    }
    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            return AppleToolOutput.make("status=unavailable reason=noCamera")
        }
        guard let root = context.workspaceRootURL else {
            return AppleToolOutput.make("status=error error=No task workspace is available", exitStatus: 2)
        }
        let relativePath: String
        if let outputPath = args.outputPath?.trimmingCharacters(in: .whitespacesAndNewlines), !outputPath.isEmpty {
            relativePath = outputPath
        } else {
            relativePath = "Camera/capture-\(UUID().uuidString).jpg"
        }
        guard let image = await CameraCaptureCoordinator().capture() else {
            return AppleToolOutput.make("status=cancelled userConfirmationRequired=true")
        }
        try context.cancellation.throwIfCancelled()
        guard let data = image.jpegData(compressionQuality: CGFloat(args.quality ?? 0.9)) else {
            throw FloeError.internalError("Captured photo could not be encoded as JPEG")
        }
        guard data.count <= 32 * 1_024 * 1_024 else {
            throw FloeError.validationFailed("Captured photo exceeds the 32 MB limit")
        }
        try context.authorizeWorkspacePath(relativePath)
        let guarder = WorkspacePathGuard(rootURL: root)
        let url = try guarder.resolve(relativePath)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw FloeError.validationFailed("Destination already exists: \(relativePath)")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        let digest = FloeDigest.sha256Hex(data)
        return AppleToolOutput.make("status=ok path=\(relativePath) bytes=\(data.count) sha256=\(digest)")
    }
}

func registerAppleSystemTools(
    database: DatabaseManager,
    registry: ToolRunnerRegistry = .shared,
    scheduleBindingResolver: TaskScheduleBindingResolver? = nil,
    onScheduleDue: (@Sendable () async -> Void)? = nil
) {
    ToolCatalog.register(AppleCalendarListTool.self); registry.register(AppleCalendarListTool())
    ToolCatalog.register(AppleCalendarUpdateTool.self); registry.register(AppleCalendarUpdateTool())
    ToolCatalog.register(AppleReminderListTool.self); registry.register(AppleReminderListTool())
    ToolCatalog.register(AppleReminderUpdateTool.self); registry.register(AppleReminderUpdateTool())
    ToolCatalog.register(AppleMapsSearchTool.self); registry.register(AppleMapsSearchTool())
    ToolCatalog.register(AppleMapsOpenTool.self); registry.register(AppleMapsOpenTool())
    ToolCatalog.register(AppleMailComposeTool.self); registry.register(AppleMailComposeTool())
    ToolCatalog.register(AppleHomeListTool.self); registry.register(AppleHomeListTool())
    ToolCatalog.register(AppleHomeControlTool.self); registry.register(AppleHomeControlTool())
    ToolCatalog.register(AppleCurrentLocationTool.self); registry.register(AppleCurrentLocationTool())
    let automationStore = SQLiteTaskScheduleStore(database: database)
    ToolCatalog.register(AppleAutomationListTool.self); registry.register(AppleAutomationListTool(store: automationStore))
    ToolCatalog.register(AppleAutomationUpdateTool.self)
    registry.register(AppleAutomationUpdateTool(
        store: automationStore,
        bindingResolver: scheduleBindingResolver,
        onScheduleDue: onScheduleDue))
    ToolCatalog.register(AppleClipboardWriteTool.self); registry.register(AppleClipboardWriteTool())
    ToolCatalog.register(AppleClipboardReadTool.self); registry.register(AppleClipboardReadTool())
    ToolCatalog.register(AppleShortcutsRunTool.self); registry.register(AppleShortcutsRunTool())
    ToolCatalog.register(AppleCameraCaptureTool.self); registry.register(AppleCameraCaptureTool())
}
#endif
