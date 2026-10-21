// FloeApp — `apple.contacts.list`, a bounded read-only Contacts tool.
//
// SPDX-License-Identifier: MPL-2.0
//
// The tool owns validation, the foreground gate, authorization, bounded scan
// order, the task-owned snapshot cursor and output shaping. It has no save,
// delete, call, message or URL-execution path. Limited Contacts access is
// accepted and reported as limited; limited/denied/restricted/not-determined,
// an empty authorized result and cancellation are all distinct outcomes.

#if canImport(UIKit) && canImport(Contacts)
import Foundation
import FloeCore
import FloeTools

struct AppleContactsListTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var query: String?
        var field: String?
        var limit: Int?
        var cursor: String?

        init(
            query: String? = nil,
            field: String? = nil,
            limit: Int? = nil,
            cursor: String? = nil
        ) {
            self.query = query
            self.field = field
            self.limit = limit
            self.cursor = cursor
        }
    }

    static let name = "apple.contacts.list"
    static let toolDescription = """
    Search or list the user's contacts after iOS Contacts authorization. Returns only the contact identifier, \
    formatted name, organization, up to three phone numbers and up to three email addresses per row. Search is \
    literal text across name, organization, phone or email (no query language or predicate injection). The first \
    call performs a bounded scan of at most 500 contacts; when scanTruncated is true, some contacts beyond that bound \
    were not examined. Pages are stable, task-owned snapshots: limit defaults to 50 (maximum 50); pass nextCursor back \
    as cursor to continue the same snapshot. Limited access is reported as authorization=limited and only the \
    selected contacts are visible. An empty authorized result is not proof of denial, and a not-determined status is \
    never reported as granted. This tool never edits, deletes, exports, calls, messages or opens a URL.
    """
    static let parametersJSON = #"""
    {"type":"object","properties":{"query":{"type":"string","maxLength":120,"description":"Literal search text. Omit to list contacts."},"field":{"type":"string","enum":["any","name","organization","phone","email"],"description":"Field to match; defaults to any."},"limit":{"type":"integer","minimum":1,"maximum":50,"description":"Rows per page; defaults to 50."},"cursor":{"type":"string","maxLength":2048,"description":"Opaque nextCursor from a previous page of the same task."}},"additionalProperties":false}
    """#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly

    static let kindPrefix = "apple.contacts.list.v1"
    static let maxScan = 500

    private let service: any ContactsDirectoryProviding
    private let monitor: any ContactsAuthorizationEpochProviding
    private let store: ContactsMediaSnapshotStore
    private let isForeground: @Sendable () async -> Bool

    init(
        service: any ContactsDirectoryProviding,
        monitor: any ContactsAuthorizationEpochProviding,
        store: ContactsMediaSnapshotStore,
        isForeground: @escaping @Sendable () async -> Bool = {
            await ContactsMediaForeground.isActive
        }
    ) {
        self.service = service
        self.monitor = monitor
        self.store = store
        self.isForeground = isForeground
    }

    func validate(_ args: Arguments) throws {
        _ = try Self.plan(args)
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard !context.temporaryReadOnly, !context.publicWebOnly else {
            return ContactsMediaOutput.make(
                "status=unavailable capability=contacts reason=temporaryChat",
                exitStatus: 75
            )
        }
        let plan = try Self.plan(args)
        guard await isForeground() else {
            return Self.failure(.foregroundRequired)
        }
        guard service.isAvailable else {
            return Self.failure(.unavailable)
        }

        var authorization = service.authorization
        if authorization == .notDetermined, plan.cursor == nil {
            do {
                _ = try await service.requestAccess(cancellation: context.cancellation)
            } catch let error as ContactsReadError {
                await store.invalidateKindPrefix(Self.kindPrefix)
                return Self.failure(error)
            } catch {
                await store.invalidateKindPrefix(Self.kindPrefix)
                return Self.failure(.authorizationRequestRejected)
            }
            authorization = service.authorization
        }

        guard authorization.canRead else {
            await store.invalidateKindPrefix(Self.kindPrefix)
            return Self.failure(Self.authorizationFailure(authorization))
        }

        let epoch = monitor.epoch(for: authorization)
        let kind = "\(Self.kindPrefix).\(epoch)"
        let owner = PersonalToolOwnerID(context: context)

        if let cursor = plan.cursor {
            do {
                if context.cancellation.isCancelled { return Self.failure(.cancelled) }
                let page = try await store.next(
                    cursor: cursor,
                    owner: owner,
                    kind: kind,
                    filterKey: nil,
                    pageSize: plan.limit
                )
                return Self.output(
                    authorization: authorization,
                    page: page,
                    scan: nil,
                    plan: plan,
                    cursorPage: true
                )
            } catch let error as PersonalToolCursorError {
                await store.invalidateKindPrefix(Self.kindPrefix)
                return Self.cursorFailure(error)
            } catch {
                await store.invalidateKindPrefix(Self.kindPrefix)
                return ContactsMediaOutput.make(
                    "status=error capability=contacts message=The contact cursor could not be continued. Start a new listing.",
                    exitStatus: 1
                )
            }
        }

        do {
            if context.cancellation.isCancelled { return Self.failure(.cancelled) }
            let scan = try await service.scan(
                query: plan.query ?? "",
                field: plan.field,
                maxScan: Self.maxScan,
                cancellation: context.cancellation
            )
            try context.cancellation.throwIfCancelled()
            let lines = scan.records
                .sorted(by: Self.stableOrder)
                .map(Self.render)
            let page = try await store.begin(
                kind: kind,
                filterKey: Self.filterKey(plan),
                lines: lines,
                owner: owner,
                pageSize: plan.limit,
                truncated: scan.truncated
            )
            return Self.output(
                authorization: scan.authorization,
                page: page,
                scan: scan,
                plan: plan,
                cursorPage: false
            )
        } catch let error as ContactsReadError {
            await store.invalidateKindPrefix(Self.kindPrefix)
            return Self.failure(error)
        } catch let error as PersonalToolCursorError {
            await store.invalidateKindPrefix(Self.kindPrefix)
            return Self.cursorFailure(error)
        } catch {
            await store.invalidateKindPrefix(Self.kindPrefix)
            return ContactsMediaOutput.make(
                "status=queryFailed capability=contacts message=The contact scan failed.",
                exitStatus: 1
            )
        }
    }

    // MARK: - Output

    private static func output(
        authorization: ContactsReadAuthorization,
        page: PersonalToolPage,
        scan: ContactsReadScan?,
        plan: ContactsListPlan,
        cursorPage: Bool
    ) -> ToolExecutionOutput {
        var fields = [
            "status=ok",
            "kind=apple.contacts.list",
            "count=\(page.returnedCount)",
            "totalCount=\(page.totalCount)",
            "hasMore=\(page.hasMore)",
            "nextCursor=\(page.nextCursor ?? "none")",
            "pageCount=\(page.pageCount)",
            "snapshotTime=\(ContactsMediaOutput.iso(page.snapshotTime))",
            "completeness=\(page.completeness)",
            "authorization=\(authorization.rawValue)",
            "readOnly=true",
            "writeRequested=false",
            "fields=name,organization,phone,email",
            "scanCap=\(maxScan)",
            "cursorPage=\(cursorPage)"
        ]
        if let scan {
            fields.append("scanned=\(scan.scannedCount)")
            fields.append("scanTruncated=\(scan.truncated)")
        }
        if authorization.isLimited {
            fields.append("limitedAccess=true")
        }
        if page.totalCount == 0 {
            fields.append("emptyResult=true")
            if authorization.isLimited {
                fields.append("limitedSelectionEmpty=true")
            }
        }
        if page.truncatedRows > 0 {
            fields.append("truncatedRows=\(page.truncatedRows)")
        }
        if !cursorPage, let query = plan.query, !query.isEmpty {
            fields.append("field=\(plan.field.rawValue)")
        }
        return ContactsMediaOutput.page(
            header: fields.joined(separator: " "),
            page: page
        )
    }

    private static func failure(_ error: ContactsReadError) -> ToolExecutionOutput {
        ContactsMediaOutput.make(
            "status=\(error.status) capability=contacts message=\(error.errorDescription ?? error.status)",
            exitStatus: error.exitStatus
        )
    }

    private static func cursorFailure(_ error: PersonalToolCursorError) -> ToolExecutionOutput {
        ContactsMediaOutput.make(
            "status=error code=\(error.code) capability=contacts message=\(error.errorDescription ?? "cursor error")",
            exitStatus: 1
        )
    }

    private static func authorizationFailure(_ authorization: ContactsReadAuthorization) -> ContactsReadError {
        switch authorization {
        case .notDetermined: .authorizationRequired
        case .denied: .authorizationDenied
        case .restricted: .authorizationRestricted
        case .authorized, .limited: .authorizationChanged
        case .unavailable: .unavailable
        }
    }

    // MARK: - Rows

    private static func stableOrder(_ lhs: ContactsReadRecord, _ rhs: ContactsReadRecord) -> Bool {
        let left = normalized(lhs.displayName)
        let right = normalized(rhs.displayName)
        if left != right { return left < right }
        return lhs.identifier < rhs.identifier
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func render(_ record: ContactsReadRecord) -> String {
        let line = [
            "id=\(record.identifier)",
            "name=\(ContactsMediaText.quoted(record.displayName, limit: 120))",
            "organization=\(ContactsMediaText.quoted(record.organization, limit: 120))",
            "phones=\(ContactsMediaText.quotedList(record.phones, itemLimit: 40, totalLimit: 320))",
            "emails=\(ContactsMediaText.quotedList(record.emails, itemLimit: 120, totalLimit: 320))"
        ].joined(separator: " ")
        return ContactsMediaText.boundedRow(line, limit: 900)
    }

    // MARK: - Argument planning

    private struct ContactsListPlan {
        var query: String?
        var field: ContactsReadField
        var limit: Int
        var cursor: String?
    }

    private static func plan(_ args: Arguments) throws -> ContactsListPlan {
        let rawQuery = args.query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = rawQuery?.isEmpty == true ? nil : rawQuery
        if let query {
            guard query.count <= 120, query.utf8.count <= 480 else {
                throw FloeError.validationFailed("query must be at most 120 characters")
            }
            guard !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw FloeError.validationFailed("query must not contain control characters")
            }
        }
        let field: ContactsReadField
        if let rawField = args.field?.trimmingCharacters(in: .whitespacesAndNewlines), !rawField.isEmpty {
            guard let parsed = ContactsReadField(rawValue: rawField) else {
                throw FloeError.validationFailed(
                    "field must be one of: \(ContactsReadField.allCases.map(\.rawValue).joined(separator: ", "))"
                )
            }
            field = parsed
        } else {
            field = .any
        }
        let limit = args.limit ?? 50
        guard (1...50).contains(limit) else {
            throw FloeError.validationFailed("limit must be 1...50")
        }
        let rawCursor = args.cursor?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cursor = rawCursor?.isEmpty == true ? nil : rawCursor
        if let cursor {
            guard cursor.count <= 2_048 else {
                throw FloeError.validationFailed("cursor is too long")
            }
            guard query == nil, field == .any else {
                throw FloeError.validationFailed("cursor continues a snapshot; omit query and field")
            }
        } else if query == nil, field != .any {
            throw FloeError.validationFailed("field requires a query")
        }
        return ContactsListPlan(query: query, field: field, limit: limit, cursor: cursor)
    }

    private static func filterKey(_ plan: ContactsListPlan) -> String {
        "q=\(plan.query ?? "")|field=\(plan.field.rawValue)|scan=\(maxScan)"
    }
}
#endif
