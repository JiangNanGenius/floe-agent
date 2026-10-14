// FloeAppTests — production personal-tool pagination seam.
//
// Exercises the exact functions the calendar/reminder handlers call: trusted
// owner binding derived from ToolContext (durable conversation across runs,
// environment contradictions rejected), the store ownership/expiry/error
// contract, and the handler-rendered pagination output. EventKit permission
// and real event data remain simulator/device acceptance (primary-owned).

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTools
@testable import FloeApp

@Suite("FloeApp.PersonalToolPagination")
struct PersonalToolPaginationTests {

    private func context(
        conversationID: UUID?,
        environmentID: String? = nil
    ) -> ToolContext {
        ToolContext(
            runID: UUID(),
            cancellation: CancellationToken(),
            environmentID: environmentID,
            conversationID: conversationID
        )
    }

    @Test("ToolContext maps to the trusted owner identity")
    func ownerIdentityMapsFromContext() {
        let conversation = UUID()
        let context = ToolContext(
            runID: UUID(),
            cancellation: CancellationToken(),
            environmentID: "env-1",
            conversationID: conversation
        )
        let owner = PersonalToolOwnerID(context: context)
        #expect(owner.conversationID == conversation)
        #expect(owner.environmentID == "env-1")
        #expect(owner.fallbackRunID == context.runID)
    }

    @Test("A new run of the same conversation continues; other tasks are rejected")
    func productionPagingSeamOwnership() async throws {
        let conversation = UUID()
        let first = context(conversationID: conversation)
        let page = try await ApplePersonalListPaging.begin(
            kind: "calendar",
            filterKey: "start=x end=y query=",
            lines: ["row-1", "row-2", "row-3"],
            context: first,
            pageSize: 2
        )
        #expect(page.returnedCount == 2)
        #expect(page.hasMore)
        let cursor = try #require(page.nextCursor)

        // New run, same conversation: the continuation stays valid.
        let nextRun = context(conversationID: conversation)
        let continued = try await ApplePersonalListPaging.next(
            cursor: cursor,
            context: nextRun,
            kind: "calendar",
            filterKey: nil,
            pageSize: 2
        )
        #expect(continued.lines == ["row-3"])
        #expect(!continued.hasMore)

        // A different conversation is rejected explicitly.
        let other = context(conversationID: UUID())
        do {
            _ = try await ApplePersonalListPaging.next(
                cursor: cursor,
                context: other,
                kind: "calendar",
                filterKey: nil,
                pageSize: 2
            )
            Issue.record("another conversation must be rejected")
        } catch let error as PersonalToolCursorError {
            #expect(error == .notOwned)
        } catch {
            Issue.record("unexpected error \(error)")
        }

        // A different known environment is rejected.
        let environmentA = context(conversationID: conversation, environmentID: "env-a")
        let environmentB = context(conversationID: conversation, environmentID: "env-b")
        let envPage = try await ApplePersonalListPaging.begin(
            kind: "calendar",
            filterKey: "f",
            lines: ["a", "b"],
            context: environmentA,
            pageSize: 1
        )
        do {
            _ = try await ApplePersonalListPaging.next(
                cursor: try #require(envPage.nextCursor),
                context: environmentB,
                kind: "calendar",
                filterKey: nil,
                pageSize: 1
            )
            Issue.record("a different environment must be rejected")
        } catch let error as PersonalToolCursorError {
            #expect(error == .notOwned)
        } catch {
            Issue.record("unexpected error \(error)")
        }

        // Conversation-less runs fall back to the run identity.
        let runOnly = context(conversationID: nil)
        let runPage = try await ApplePersonalListPaging.begin(
            kind: "reminders",
            filterKey: "f",
            lines: ["a", "b"],
            context: runOnly,
            pageSize: 1
        )
        do {
            _ = try await ApplePersonalListPaging.next(
                cursor: try #require(runPage.nextCursor),
                context: context(conversationID: nil),
                kind: "reminders",
                filterKey: nil,
                pageSize: 1
            )
            Issue.record("a different run must be rejected")
        } catch let error as PersonalToolCursorError {
            #expect(error == .notOwned)
        } catch {
            Issue.record("unexpected error \(error)")
        }

        // Revocation by the owning task drops the snapshot explicitly.
        await PersonalToolCursorStore.shared.revoke(owner: PersonalToolOwnerID(context: first))
        do {
            _ = try await ApplePersonalListPaging.next(
                cursor: cursor,
                context: nextRun,
                kind: "calendar",
                filterKey: nil,
                pageSize: 2
            )
            Issue.record("revoked snapshot must be unavailable")
        } catch let error as PersonalToolCursorError {
            #expect(error == .unknown)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("Budget-shortened pages advance only past emitted rows, including one oversize row")
    func budgetShortenedPageNeverSkipsARow() async throws {
        let conversation = UUID()
        let context = context(conversationID: conversation)
        let owner = PersonalToolOwnerID(context: context)
        let store = PersonalToolCursorStore.shared

        // 7 rows of ~120 characters, budget 400, header reserve 100:
        // roughly two rows fit per page and the cursor must advance exactly.
        let lines = (0..<7).map { index in
            "id=row-\(index) occurrence=row-\(index)@2026-10-14T00:00:00Z title=" + String(repeating: "长", count: 100)
        }
        var page = try await store.begin(
            kind: "calendar",
            filterKey: "f",
            lines: lines,
            owner: owner,
            pageSize: 100,
            characterBudget: 400,
            reservedHeaderCharacters: 100,
            now: Date(timeIntervalSince1970: 0)
        )
        var seen: [String] = []
        var guardCount = 0
        while true {
            guardCount += 1
            #expect(guardCount < 20)
            #expect(page.returnedCount == page.lines.count)
            seen.append(contentsOf: page.lines)
            guard let cursor = page.nextCursor else { break }
            page = try await store.next(
                cursor: cursor,
                owner: owner,
                kind: "calendar",
                filterKey: nil,
                pageSize: 100,
                characterBudget: 400,
                reservedHeaderCharacters: 100,
                now: Date(timeIntervalSince1970: 0)
            )
        }
        #expect(seen.count == lines.count)
        #expect(seen == lines)

        // A single row larger than the budget is emitted truncated with its
        // stable head, reported, and the cursor advances past it.
        let huge = "id=huge occurrence=huge@2026-10-14T00:00:00Z title=" + String(repeating: "巨", count: 5_000)
        let single = try await store.begin(
            kind: "calendar",
            filterKey: "f",
            lines: [huge, "id=next occurrence=next@2026-10-14T00:00:00Z title=tail"],
            owner: owner,
            pageSize: 100,
            characterBudget: 400,
            reservedHeaderCharacters: 100,
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(single.returnedCount == 1)
        #expect(single.truncatedRows == 1)
        #expect(single.lines.first?.hasPrefix("id=huge occurrence=huge@") == true)
        #expect(single.lines.first?.hasSuffix("…[row truncated]") == true)
        #expect(single.nextCursor != nil)
    }

    @Test("Paging >200 realistic rows under the budget emits every ID exactly once")
    func pageThroughLongRowsEmitsEveryIDOnce() async throws {
        let conversation = UUID()
        let store = PersonalToolCursorStore.shared
        let lines = (0..<250).map { index in
            "id=row-\(index) occurrence=row-\(index)@2026-10-14T00:00:00Z title=" + String(repeating: "事件", count: 60)
        }
        // First page from run 1, later pages from new runs of the same
        // conversation: continuation must survive across runs.
        var page = try await ApplePersonalListPaging.begin(
            kind: "calendar",
            filterKey: "f",
            lines: lines,
            context: context(conversationID: conversation),
            pageSize: 100
        )
        var emitted: [String] = []
        var pages = 0
        while true {
            pages += 1
            #expect(pages < 60)
            emitted.append(contentsOf: page.lines)
            // The rendered page must survive the runtime 4096-character prefix.
            let output = AppleToolOutput.page(page, kind: "calendar")
            let result = ToolResult(
                callID: "call",
                status: .ok,
                outputSummary: output.summary,
                outputDigest: output.fullOutputSHA256,
                exitStatus: output.exitStatus
            )
            #expect(result.outputSummary == output.summary)
            #expect(output.summary.contains("count=\(page.returnedCount)"))
            guard let cursor = page.nextCursor else { break }
            page = try await ApplePersonalListPaging.next(
                cursor: cursor,
                context: context(conversationID: conversation),
                kind: "calendar",
                filterKey: nil,
                pageSize: 100
            )
        }
        #expect(emitted.count == 250)
        let ids = emitted.compactMap { line -> String? in
            guard let range = line.range(of: "id=") else { return nil }
            let rest = line[range.upperBound...]
            return String(rest.prefix(while: { $0 != " " }))
        }
        #expect(Set(ids).count == 250, "every row id exactly once")
        #expect(ids.count == 250, "no duplicate rows")
    }

    @Test("Handler rendering carries the complete pagination contract")
    func handlerOutputContract() throws {
        let page = PersonalToolPage(
            lines: ["id=1 occurrence=1@2026-10-14T00:00:00Z start=2026-10-14T00:00:00Z"],
            returnedCount: 1,
            totalCount: 3,
            hasMore: true,
            nextCursor: "ptc1.example",
            pageCount: 3,
            snapshotTime: Date(timeIntervalSince1970: 0),
            completeness: "complete"
        )
        let output = AppleToolOutput.page(page, kind: "calendar")
        for token in [
            "status=ok", "kind=calendar", "count=1", "totalCount=3",
            "hasMore=true", "nextCursor=ptc1.example", "pageCount=3",
            "snapshotTime=1970-01-01T00:00:00Z", "completeness=complete"
        ] {
            #expect(output.summary.contains(token), "missing \(token): \(output.summary)")
        }
        #expect(output.summary.contains("occurrence="))

        let error = AppleToolOutput.cursorError(.expired(snapshotTime: Date(timeIntervalSince1970: 0)))
        #expect(error.summary.contains("status=error"))
        #expect(error.summary.contains("code=cursorExpired"))
        #expect(error.exitStatus == 1)
    }

    @Test("Handler argument validation enforces the limit bounds")
    func handlerLimitValidation() throws {
        let calendar = AppleCalendarListTool()
        try calendar.validate(.init(start: nil, end: nil, query: nil, limit: 200, cursor: nil))
        do {
            try calendar.validate(.init(start: nil, end: nil, query: nil, limit: 201, cursor: nil))
            Issue.record("limit above 200 must be rejected")
        } catch {
            // Expected: handler validation failure.
        }
        let reminders = AppleReminderListTool()
        try reminders.validate(.init(includeCompleted: nil, query: nil, limit: 1, cursor: nil))
        do {
            try reminders.validate(.init(includeCompleted: nil, query: nil, limit: 0, cursor: nil))
            Issue.record("limit below 1 must be rejected")
        } catch {
            // Expected: handler validation failure.
        }
    }
}
#endif
