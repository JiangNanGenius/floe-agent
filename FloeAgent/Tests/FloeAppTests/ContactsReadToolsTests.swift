// FloeAppTests — prepared behavior tests for `apple.contacts.list`.
//
// These use a fake Contacts directory and a local snapshot store. No
// CNContactStore, system authorization sheet, real address book or device is
// touched. They are registered only after the primary adds this file to the
// FloeAppTests source list and regenerates the project.

#if canImport(UIKit) && canImport(Contacts)
import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeApp

@Suite("FloeApp.ContactsReadTools")
struct ContactsReadToolsTests {
    private func context(
        conversation: UUID? = UUID(),
        environmentID: String? = nil,
        runID: UUID = UUID(),
        temporary: Bool = false,
        cancellation: CancellationToken = CancellationToken()
    ) -> ToolContext {
        ToolContext(
            runID: runID,
            cancellation: cancellation,
            environmentID: environmentID,
            conversationID: conversation,
            temporaryReadOnly: temporary
        )
    }

    private func tool(
        service: FakeContactsDirectory,
        monitor: FakeContactsEpoch = FakeContactsEpoch(),
        store: ContactsMediaSnapshotStore = ContactsMediaSnapshotStore(),
        foreground: Bool = true
    ) -> AppleContactsListTool {
        AppleContactsListTool(
            service: service,
            monitor: monitor,
            store: store,
            isForeground: { foreground }
        )
    }

    private func field(_ name: String, in output: String) -> String? {
        guard let firstLine = output.split(separator: "\n", maxSplits: 1).first else {
            return nil
        }
        for token in firstLine.split(separator: " ") where token.hasPrefix("\(name)=") {
            return String(token.dropFirst(name.count + 1))
        }
        return nil
    }

    private func rowIDs(_ output: String) -> [String] {
        output.split(separator: "\n").dropFirst().compactMap { line in
            guard let token = line.split(separator: " ").first(where: { $0.hasPrefix("id=") }) else {
                return nil
            }
            return String(token.dropFirst(3))
        }
    }

    private func record(_ index: Int) -> ContactsReadRecord {
        ContactsReadRecord(
            identifier: "contact-\(String(format: "%03d", index))",
            displayName: "Contact \(String(format: "%03d", index))",
            organization: "Org \(index)",
            phones: ["+61 400 000 \(index)"],
            emails: ["contact\(index)@example.test"]
        )
    }

    // MARK: - Authorization / empty states

    @Test("Denied is an explicit failure, not an empty list")
    func deniedIsExplicit() async throws {
        let service = FakeContactsDirectory()
        service.authorization = .denied
        let output = try await tool(service: service).execute(.init(), context: context())
        #expect(output.exitStatus == 77)
        #expect(output.summary.contains("status=authorizationDenied"))
        #expect(!output.summary.contains("status=ok"))
        #expect(!output.summary.contains("count=0"))
        #expect(service.scanCount == 0)
    }

    @Test("An empty authorized result is successful but explicitly empty")
    func emptyAuthorizedIsNotDenied() async throws {
        let service = FakeContactsDirectory()
        service.authorization = .authorized
        service.records = []
        let output = try await tool(service: service).execute(.init(), context: context())
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("status=ok"))
        #expect(output.summary.contains("count=0"))
        #expect(output.summary.contains("totalCount=0"))
        #expect(output.summary.contains("emptyResult=true"))
        #expect(output.summary.contains("authorization=authorized"))
        #expect(!output.summary.contains("authorizationDenied"))
        #expect(!output.summary.contains("granted"))
    }

    @Test("Limited access is accepted and reported separately from full access")
    func limitedAccessIsExplicit() async throws {
        let service = FakeContactsDirectory()
        service.authorization = .limited
        service.records = [record(1)]
        let output = try await tool(service: service).execute(.init(), context: context())
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("authorization=limited"))
        #expect(output.summary.contains("limitedAccess=true"))
        #expect(!output.summary.contains("authorization=authorized"))
        #expect(rowIDs(output.summary) == ["contact-001"])
    }

    @Test("Limited access with an empty selection is distinct from denial")
    func limitedEmptySelection() async throws {
        let service = FakeContactsDirectory()
        service.authorization = .limited
        service.records = []
        let output = try await tool(service: service).execute(.init(), context: context())
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("status=ok"))
        #expect(output.summary.contains("authorization=limited"))
        #expect(output.summary.contains("limitedSelectionEmpty=true"))
        #expect(!output.summary.contains("authorizationDenied"))
    }

    @Test("Not-determined requests access once in the foreground")
    func notDeterminedRequestsOnce() async throws {
        let service = FakeContactsDirectory()
        service.authorization = .notDetermined
        service.requestOutcome = .authorized
        service.records = [record(2)]
        let output = try await tool(service: service).execute(.init(), context: context())
        #expect(output.exitStatus == 0)
        #expect(service.requestCount == 1)
        #expect(output.summary.contains("authorization=authorized"))
        #expect(rowIDs(output.summary) == ["contact-002"])
    }

    @Test("A cursor never triggers a system prompt")
    func cursorDoesNotPrompt() async throws {
        let service = FakeContactsDirectory()
        service.authorization = .notDetermined
        let output = try await tool(service: service).execute(
            .init(cursor: "cmc1.unknown"),
            context: context()
        )
        #expect(output.exitStatus == 77)
        #expect(output.summary.contains("status=authorizationRequired"))
        #expect(service.requestCount == 0)
        #expect(service.scanCount == 0)
    }

    @Test("Restricted and backgrounded calls are separate failures")
    func restrictedAndForeground() async throws {
        let restricted = FakeContactsDirectory()
        restricted.authorization = .restricted
        let restrictedOutput = try await tool(service: restricted).execute(.init(), context: context())
        #expect(restrictedOutput.exitStatus == 77)
        #expect(restrictedOutput.summary.contains("status=authorizationRestricted"))

        let background = FakeContactsDirectory()
        background.authorization = .authorized
        let backgroundOutput = try await tool(service: background, foreground: false)
            .execute(.init(), context: context())
        #expect(backgroundOutput.exitStatus == 75)
        #expect(backgroundOutput.summary.contains("status=foregroundRequired"))
        #expect(background.scanCount == 0)
    }

    @Test("Temporary chat has no Contacts capability")
    func temporaryChatUnavailable() async throws {
        let service = FakeContactsDirectory()
        service.authorization = .authorized
        let output = try await tool(service: service).execute(
            .init(),
            context: context(temporary: true)
        )
        #expect(output.exitStatus == 75)
        #expect(output.summary.contains("reason=temporaryChat"))
        #expect(service.scanCount == 0)
    }

    // MARK: - Pagination / ownership / bounds

    @Test("Pages are stable, unique and complete for the bounded snapshot")
    func paginationIsStable() async throws {
        let service = FakeContactsDirectory()
        service.authorization = .authorized
        service.records = (1...120).map(record)
        let store = ContactsMediaSnapshotStore()
        let monitor = FakeContactsEpoch()
        let tool = tool(service: service, monitor: monitor, store: store)
        let conversation = UUID()
        let firstContext = context(conversation: conversation)

        let first = try await tool.execute(.init(limit: 50), context: firstContext)
        #expect(field("totalCount", in: first.summary) == "120")
        #expect(field("hasMore", in: first.summary) == "true")
        #expect(!rowIDs(first.summary).isEmpty)

        // The library changes after the snapshot began; pages must still be
        // the original stable snapshot.
        service.records = (1...5).map(record)
        var ids = rowIDs(first.summary)
        var cursor = field("nextCursor", in: first.summary)
        var pages = 1
        while let next = cursor, next != "none", pages < 100 {
            let output = try await tool.execute(
                .init(limit: 50, cursor: next),
                context: context(conversation: conversation)
            )
            #expect(output.exitStatus == 0)
            #expect(field("totalCount", in: output.summary) == "120")
            ids.append(contentsOf: rowIDs(output.summary))
            cursor = field("nextCursor", in: output.summary)
            pages += 1
        }
        #expect(ids.count == 120)
        #expect(Set(ids).count == 120)
        #expect(pages > 1)
    }

    @Test("A cursor from another task is rejected after exact ownership check")
    func foreignCursorRejected() async throws {
        let service = FakeContactsDirectory()
        service.authorization = .authorized
        service.records = (1...20).map(record)
        let store = ContactsMediaSnapshotStore()
        let tool = tool(service: service, store: store)
        let ownerA = UUID()
        let first = try await tool.execute(.init(limit: 5), context: context(conversation: ownerA))
        guard let cursor = field("nextCursor", in: first.summary), cursor != "none" else {
            Issue.record("expected a cursor for the first page")
            return
        }
        let other = try await tool.execute(.init(cursor: cursor), context: context(conversation: UUID()))
        #expect(other.exitStatus == 1)
        #expect(other.summary.contains("code=cursorNotOwned"))
        #expect(rowIDs(other.summary).isEmpty)
    }

    @Test("An authorization-scope epoch invalidates the old cursor")
    func authorizationEpochInvalidatesCursor() async throws {
        let service = FakeContactsDirectory()
        service.authorization = .authorized
        service.records = (1...20).map(record)
        let store = ContactsMediaSnapshotStore()
        let monitor = FakeContactsEpoch()
        let tool = tool(service: service, monitor: monitor, store: store)
        let conversation = UUID()
        let first = try await tool.execute(.init(limit: 5), context: context(conversation: conversation))
        guard let cursor = field("nextCursor", in: first.summary), cursor != "none" else {
            Issue.record("expected a cursor for the first page")
            return
        }
        monitor.bump()
        service.authorization = .limited
        let next = try await tool.execute(.init(cursor: cursor), context: context(conversation: conversation))
        #expect(next.exitStatus == 1)
        #expect(next.summary.contains("code=cursorFilterMismatch"))
        #expect(rowIDs(next.summary).isEmpty)
    }

    @Test("The 500-contact scan cap is reported, not hidden")
    func scanCapReported() async throws {
        let service = FakeContactsDirectory()
        service.authorization = .authorized
        service.records = (1...500).map(record)
        service.scanTruncated = true
        let output = try await tool(service: service).execute(.init(limit: 50), context: context())
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("scanned=500"))
        #expect(output.summary.contains("scanTruncated=true"))
        #expect(output.summary.contains("completeness=truncated"))
    }

    @Test("No page exceeds the character budget or repeats a row")
    func pageBounds() async throws {
        let service = FakeContactsDirectory()
        service.authorization = .authorized
        service.records = (1...80).map(record)
        let output = try await tool(service: service).execute(.init(limit: 50), context: context())
        #expect(output.summary.count <= 4_096)
        #expect(rowIDs(output.summary).count <= 50)
        #expect(Set(rowIDs(output.summary)).count == rowIDs(output.summary).count)
    }

    // MARK: - Input / cancellation

    @Test("Queries are literal and bounded")
    func queryIsLiteralAndBounded() async throws {
        let service = FakeContactsDirectory()
        service.authorization = .authorized
        service.records = [record(3)]
        let literal = "*\" OR name == \"*"
        let output = try await tool(service: service).execute(
            .init(query: literal, field: "name"),
            context: context()
        )
        #expect(output.exitStatus == 0)
        #expect(service.lastQuery == literal)
        #expect(!output.summary.contains(literal))

        #expect(throws: (any Error).self) {
            try tool(service: service).validate(.init(query: String(repeating: "a", count: 121)))
        }
        #expect(throws: (any Error).self) {
            try tool(service: service).validate(.init(query: "a\nb"))
        }
        #expect(throws: (any Error).self) {
            try tool(service: service).validate(.init(field: "phone"))
        }
        #expect(throws: (any Error).self) {
            try tool(service: service).validate(.init(query: "a", cursor: "cmc1.x"))
        }
        #expect(throws: (any Error).self) {
            try tool(service: service).validate(.init(limit: 51))
        }
    }

    @Test("Cancellation during the scan is explicit and returns no rows")
    func cancelledScan() async throws {
        let service = FakeContactsDirectory()
        service.authorization = .authorized
        service.scanError = .cancelled
        let token = CancellationToken()
        let output = try await tool(service: service).execute(
            .init(),
            context: context(cancellation: token)
        )
        #expect(output.exitStatus == 130)
        #expect(output.summary.contains("status=cancelled"))
        #expect(rowIDs(output.summary).isEmpty)
    }

    @Test("A late authorization callback cannot resume a cancelled request twice")
    func lateCallbackIsDiscarded() async throws {
        let token = CancellationToken()
        let task = Task {
            try await ContactsMediaRequestRunner.run(
                cancellation: token,
                timeout: 5
            ) {
                try? await Task.sleep(nanoseconds: 120_000_000)
                return 7
            }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        token.cancel()
        await #expect(throws: ContactsMediaRequestError.self) {
            _ = try await task.value
        }
        // Let the late operation finish; the exactly-once gate consumes it
        // without a second resume.
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    @Test("Cursor tokens are opaque and malformed input is rejected")
    func malformedCursor() async throws {
        let service = FakeContactsDirectory()
        service.authorization = .authorized
        let output = try await tool(service: service).execute(
            .init(cursor: "not-a-cursor"),
            context: context()
        )
        #expect(output.exitStatus == 1)
        #expect(output.summary.contains("code=cursorMalformed"))
    }
}

// MARK: - Fakes

final class FakeContactsDirectory: ContactsDirectoryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _authorization: ContactsReadAuthorization = .authorized
    private var _records: [ContactsReadRecord] = []
    private var _requestCount = 0
    private var _scanCount = 0
    private var _lastQuery = ""
    private var _scanTruncated = false
    private var _scanError: ContactsReadError?
    private var _requestOutcome: ContactsReadAuthorization = .authorized
    private var _requestError: ContactsReadError?

    var authorization: ContactsReadAuthorization {
        get { lock.lock(); defer { lock.unlock() }; return _authorization }
        set { lock.lock(); _authorization = newValue; lock.unlock() }
    }

    var records: [ContactsReadRecord] {
        get { lock.lock(); defer { lock.unlock() }; return _records }
        set { lock.lock(); _records = newValue; lock.unlock() }
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }; return _requestCount
    }

    var scanCount: Int {
        lock.lock(); defer { lock.unlock() }; return _scanCount
    }

    var lastQuery: String {
        lock.lock(); defer { lock.unlock() }; return _lastQuery
    }

    var scanTruncated: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _scanTruncated }
        set { lock.lock(); _scanTruncated = newValue; lock.unlock() }
    }

    var scanError: ContactsReadError? {
        get { lock.lock(); defer { lock.unlock() }; return _scanError }
        set { lock.lock(); _scanError = newValue; lock.unlock() }
    }

    var requestOutcome: ContactsReadAuthorization {
        get { lock.lock(); defer { lock.unlock() }; return _requestOutcome }
        set { lock.lock(); _requestOutcome = newValue; lock.unlock() }
    }

    var requestError: ContactsReadError? {
        get { lock.lock(); defer { lock.unlock() }; return _requestError }
        set { lock.lock(); _requestError = newValue; lock.unlock() }
    }

    var isAvailable: Bool { true }

    func requestAccess(cancellation: CancellationToken) async throws -> ContactsReadAuthorization {
        let (outcome, error) = lock.withLock {
            _requestCount += 1
            return (_requestOutcome, _requestError)
        }
        if cancellation.isCancelled { throw ContactsReadError.cancelled }
        if let error { throw error }
        lock.withLock { _authorization = outcome }
        return outcome
    }

    func scan(
        query: String,
        field: ContactsReadField,
        maxScan: Int,
        cancellation: CancellationToken
    ) async throws -> ContactsReadScan {
        let (error, records, truncated, authorization) = lock.withLock {
            _scanCount += 1
            _lastQuery = query
            return (_scanError, _records, _scanTruncated, _authorization)
        }
        if cancellation.isCancelled { throw ContactsReadError.cancelled }
        if let error { throw error }
        return ContactsReadScan(
            records: records,
            scannedCount: records.count,
            truncated: truncated,
            authorization: authorization
        )
    }
}

final class FakeContactsEpoch: ContactsAuthorizationEpochProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1

    func epoch(for authorization: ContactsReadAuthorization) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func bump() {
        lock.lock()
        value &+= 1
        lock.unlock()
    }
}
#endif
