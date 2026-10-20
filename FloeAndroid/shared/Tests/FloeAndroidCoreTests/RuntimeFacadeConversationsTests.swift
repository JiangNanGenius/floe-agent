// SPDX-License-Identifier: MPL-2.0
//
// RB-3 conversation domain — behavioral tests over the REAL original stores
// and a REAL file-backed schema-46 database (private source candidate;
// AUTHORED, NOT executed by this package — compiler/host execution is the
// later Main-qualified gate).
//
// Coverage (per acceptance): original file-backed DB + migrations + reopen,
// ordinary-vs-archived list equivalence to the native predicates, bounded
// SQL page/cursor progress, search delegation equivalence to
// SQLiteIntelligenceStore.search (filters/order/CJK contract preserved),
// cross-workspace ownership, real create commit + failure with NO fake
// identity, rename/archive single-writer CAS (concurrent attempts,
// same-stored-timestamp mutations, null/type/Unicode/delimiter digest
// sensitivity), invalid/stale/unknown zero effects, ordinary navigation
// NEVER cancels, paginated long CJK/emoji/quote content with byte-exact
// reassembly + scalar boundaries + cursor budget, honest role passthrough.

import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime
@testable import FloeAndroidCore

final class RuntimeFacadeConversationsTests: XCTestCase {

    private func makeBundle(name: String = #function) async throws -> RB3TestBed.DomainBundle {
        let stores = try await RB3TestBed.stores(name: name)
        return RB3TestBed.makeDomain(stores: stores, lifecycle: nil)
    }

    private func payload(_ pairs: [String: SettingsDomainV1.JSONValue]) -> SettingsDomainV1.JSONValue {
        .object(pairs)
    }

    // MARK: Schema / durability

    func testSchema46FileBackedReopenKeepsOrdinaryAndArchivedLists() async throws {
        let bundle = try await makeBundle()
        let stores = bundle.stores
        let __xctestHoist1 = try await stores.database.userVersion()
        XCTAssertEqual(__xctestHoist1, 46)

        let plain = try await RB3TestBed.seedOrdinary(stores, title: "Plain task")
        let archived = try await RB3TestBed.seedOrdinary(stores, title: "Old archived task")
        try await stores.conversations.setArchived(id: archived.id, archived: true)

        // Bounded page walk must cover the reopened DB identically after a
        // close+reopen through a SECOND manager on the SAME file.
        let reopened = try await RB3TestBed.reopen(stores)
        let reopenedBundle = RB3TestBed.makeDomain(stores: reopened, lifecycle: nil)
        let reply = try await reopenedBundle.domain.list(payload: .object([
            "includeArchived": .boolean(true), "limit": .integer(50),
        ]))
        let ids = Set(reply.rows.map(\.conversationID))
        XCTAssertEqual(ids, [plain.id, archived.id])
        XCTAssertTrue(reply.rows.contains { $0.archivedAtRaw != nil })
        XCTAssertTrue(reply.rows.contains { $0.archivedAtRaw == nil })
        XCTAssertEqual(reply.hasMore, false)
    }

    // MARK: list predicates/order + bounded mirror equivalence

    func testListOrdinaryVsArchivedEquivalenceWithNativeStores() async throws {
        let bundle = try await makeBundle()
        let stores = bundle.stores
        var seeded: [ConversationRecord] = []
        for index in 0..<7 {
            let record = try await RB3TestBed.seedOrdinary(
                stores, title: "Task \(index)",
                updatedAt: Date(timeIntervalSince1970: 1_000_000 + Double(index)))
            seeded.append(record)
            if index % 3 == 0 {
                try await stores.conversations.setArchived(id: record.id, archived: true)
            }
        }
        // Qualifier repair (2026-10-19): `stores.conversations` is the
        // native actor; its listing methods live ON that actor.
        let storeUnarchived = try await stores.conversations.conversations()
        let storeAll = try await stores.conversations.conversations(includeArchived: true)

        let pageUnarchived = try await bundle.domain.list(payload: .object([
            "limit": .integer(50)]))
        XCTAssertEqual(pageUnarchived.rows.map(\.conversationID),
                       storeUnarchived.map(\.id),
                       "bounded mirror must reproduce the native order exactly")
        let pageAll = try await bundle.domain.list(payload: .object([
            "includeArchived": .boolean(true), "limit": .integer(50)]))
        XCTAssertEqual(pageAll.rows.map(\.conversationID), storeAll.map(\.id))
        XCTAssertEqual(pageAll.rows.count, 7)
        XCTAssertEqual(pageUnarchived.rows.count, storeUnarchived.count)
    }

    func testListKeysetPaginationCoversEveryRowOnceAcrossPages() async throws {
        let bundle = try await makeBundle()
        let stores = bundle.stores
        // Long CJK titles make the page budget bind quickly, forcing the
        // trim path; the walk must still visit every row exactly once.
        let longCJK = String(repeating: "项目草稿测试数据，包含引号\"与逗号,以及反斜杠\\。", count: 40)
        for index in 0..<60 {
            _ = try await RB3TestBed.seedOrdinary(
                stores, title: "\(longCJK)\(index)",
                updatedAt: Date(timeIntervalSince1970: 2_000_000 + Double(index)))
        }
        var cursor: SettingsDomainV1.JSONValue?
        var collected: [UUID] = []
        var pageCount = 0
        while true {
            var object: [String: SettingsDomainV1.JSONValue] = ["limit": .integer(50)]
            if let cursor { object["cursor"] = cursor }
            let reply = try await bundle.domain.list(payload: .object(object))
            pageCount += 1
            XCTAssertLessThanOrEqual(
                ConversationWireBudget.encodedObjectBytes(reply.wireObject),
                SettingsDomainV1.pageBudgetBytes,
                "each serialized page must fit the normal 48 KiB budget")
            collected.append(contentsOf: reply.rows.map(\.conversationID))
            guard reply.hasMore, let next = reply.nextCursor else { break }
            cursor = .string(next)
            XCTAssertLessThan(pageCount, 200, "cursor must make progress")
        }
        XCTAssertEqual(Set(collected).count, 60)
        XCTAssertEqual(collected.count, 60, "no duplicates and nothing unreachable")
        // The collected order is the native order across pages.
        let storeAll = try await stores.conversations.conversations(includeArchived: false)
        XCTAssertEqual(collected, storeAll.map(\.id))
    }

    func testListRejectsMalformedCursorAndUnknownFieldsZeroWrites() async throws {
        let bundle = try await makeBundle()
        let digestBefore = try? await RB3TestBed.count(bundle.stores.database,
                                                       "SELECT COUNT(*) FROM conversations")
        do {
            _ = try await bundle.domain.list(payload: .object(["cursor": .string("nope")]))
            XCTFail("malformed cursor must be refused")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "invalidEnvelope")
        }
        do {
            _ = try await bundle.domain.list(payload: .object(["dropTable": .boolean(true)]))
            XCTFail("unknown field must be refused")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "invalidEnvelope")
        }
        let __xctestHoist2 = try await RB3TestBed.count(bundle.stores.database,
                                                  "SELECT COUNT(*) FROM conversations")
        XCTAssertEqual(__xctestHoist2,
                       digestBefore ?? 0)
    }

    func testListIncludeRevisionPublishesOnlyActualProducerReads() async throws {
        let bundle = try await makeBundle()
        let stores = bundle.stores
        let record = try await RB3TestBed.seedOrdinary(stores, title: "Rev read")
        let reply = try await bundle.domain.list(payload: .object([
            "includeRevision": .boolean(true)]))
        let row = try XCTUnwrap(reply.rows.first)
        let realDigest = try XCTUnwrap(row.revision)
        let viaGet = try await bundle.domain.get(conversationID: record.id)
        XCTAssertEqual(realDigest, viaGet.revision,
                       "list revision must equal the same-row digest the get producer returns")
        let withoutFlag = try await bundle.domain.list(payload: nil)
        XCTAssertNil(withoutFlag.rows.first?.revision,
                     "no cached/recomputed version may leak without an explicit read request")
    }

    // MARK: search delegation equivalence

    func testSearchDelegatesNativeFTSAndTitleAndArchiveSemantics() async throws {
        let bundle = try await makeBundle()
        let stores = bundle.stores
        let alpha = try await RB3TestBed.seedOrdinary(stores, title: "Quarterly budget review")
        try await RB3TestBed.seedMessage(stores, conversationID: alpha.id,
                                         role: "user",
                                         content: "Discuss the quarterly budget numbers today")
        let cjk = try await RB3TestBed.seedOrdinary(stores, title: "项目草稿归档")
        try await RB3TestBed.seedMessage(stores, conversationID: cjk.id,
                                         role: "user",
                                         content: "请把项目草稿整理为三个部分，谢谢")
        // Archived ordinary stays SEARCHABLE (native search does not filter
        // archived_at): prove it, do not silently "fix" the native scope.
        try await stores.conversations.setArchived(id: cjk.id, archived: true)
        // Notes purpose must never surface in the ordinary API.
        let notes = ConversationRecord(id: UUID(), title: "项目草稿 notes",
                                       createdAt: Date(), updatedAt: Date(),
                                       purpose: .notes)
        try await stores.conversations.saveConversation(notes)
        try await RB3TestBed.seedMessage(stores, conversationID: notes.id,
                                         role: "user", content: "notes 项目草稿 body")

        for query in ["quarterly budget", "项目草稿"] {
            let request = ConversationSearchRequest(query: query, limit: 20)
            let native = try await stores.intelligence.search(request)
            let adapterReply = try await bundle.domain.search(payload: .object([
                "query": .string(query), "limit": .integer(20)]))
            XCTAssertEqual(adapterReply.rows.map(\.messageID), native.map(\.messageID),
                           "adapter must reproduce the native hit ORDER for the same request")
            XCTAssertEqual(adapterReply.rows.map(\.snippet), native.map(\.snippet))
        }
        let adapterReply = try await bundle.domain.search(payload: .object([
            "query": .string("项目草稿")]))
        XCTAssertTrue(adapterReply.rows.contains { $0.conversationID == cjk.id },
                      "archived ordinary must remain reachable through the native scope")
        XCTAssertFalse(adapterReply.rows.contains { $0.conversationID == notes.id },
                       "purpose != ordinary never surfaces in the ordinary search")
    }

    func testSearchCrossWorkspaceOwnershipFilterIsHonest() async throws {
        let bundle = try await makeBundle()
        let stores = bundle.stores
        // Two conversations in DIFFERENT workspaces; searching with one
        // workspace filter must return only that one's body.
        let workspaceA = try await stores.workspaces.saveWorkspaceNamedForTest("A")
        let workspaceB = try await stores.workspaces.saveWorkspaceNamedForTest("B")
        let convA = try await RB3TestBed.seedOrdinary(stores, title: "alpha")
        try await RB3TestBed.seedMessage(stores, conversationID: convA.id,
                                         content: "workspace alpha marker \u{1F600}")
        try await stores.workspaces.assignConversation(workspaceID: workspaceA,
                                                       conversationID: convA.id)
        let convB = try await RB3TestBed.seedOrdinary(stores, title: "beta")
        try await RB3TestBed.seedMessage(stores, conversationID: convB.id,
                                         content: "workspace beta marker")
        try await stores.workspaces.assignConversation(workspaceID: workspaceB,
                                                       conversationID: convB.id)

        let onlyA = try await bundle.domain.search(payload: .object([
            "query": .string("marker"),
            "workspaceID": .string(workspaceA.uuidString)]))
        XCTAssertEqual(Set(onlyA.rows.map(\.conversationID)), [convA.id])
        let noneFilter = try await bundle.domain.search(payload: .object([
            "query": .string("marker")]))
        XCTAssertEqual(Set(noneFilter.rows.map(\.conversationID)), [convA.id, convB.id])
        // workspaceID on the reply carries the real bound workspace.
        let rowA = try XCTUnwrap(noneFilter.rows.first { $0.conversationID == convA.id })
        XCTAssertEqual(rowA.workspaceID, workspaceA,
                       "ownership must come from the durable ownership table")
    }

    // MARK: create

    func testCreateCommitsRealIdentityAndRefusesFabrication() async throws {
        let bundle = try await makeBundle()
        let reply = try await bundle.domain.create(payload: .object([
            "title": .string("项目草稿")]))
        let __xctestHoist3 = try await RB3TestBed.count(bundle.stores.database,
                                                  "SELECT COUNT(*) FROM conversations")
        XCTAssertEqual(__xctestHoist3, 1)
        let rowRaw = try await bundle.stores.conversations.conversation(id: reply.conversationID)
        let row = try XCTUnwrap(rowRaw)
        XCTAssertEqual(row.title, "项目草稿")
        XCTAssertEqual(row.purpose, .ordinary)
        XCTAssertEqual(row.titleOrigin, .autoPending,
                       "native creation defaults preserved (no forced manual)")
        let digestRaw = try await RB3TestBed.rawDigest(bundle.stores.database,
                                                       reply.conversationID)
        let digest = try XCTUnwrap(digestRaw)
        XCTAssertEqual(digest, reply.revision,
                       "reply revision is the ACTUAL committed row digest")
        // purpose is not a create field.
        do {
            _ = try await bundle.domain.create(payload: .object([
                "title": .string("x"), "purpose": .string("notes")]))
            XCTFail("purpose must not be accepted")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "invalidEnvelope")
        }
        // Empty title stays legal (native verified-empty contract partner).
        let blank = try await bundle.domain.create(payload: nil)
        XCTAssertEqual(blank.title, "")
        // Overlong title refused with ZERO rows added.
        do {
            _ = try await bundle.domain.create(payload: .object([
                "title": .string(String(repeating: "标", count: 121))]))
            XCTFail("120-character native title cap must bind")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "invalidEnvelope")
        }
        let __xctestHoist4 = try await RB3TestBed.count(bundle.stores.database,
                                                  "SELECT COUNT(*) FROM conversations")
        XCTAssertEqual(__xctestHoist4, 2)
    }

    func testCreateFaultInsideTransactionRollsBackWithNoFakeIdentity() async throws {
        let stores = try await RB3TestBed.stores()
        struct CommitFault: Error {}
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: nil,
                                           faultInjection: { step in
            if step == 1 { throw CommitFault() }
        })
        do {
            _ = try await bundle.domain.create(payload: .object([
                "title": .string("Never committed")]))
            XCTFail("fault must propagate")
        } catch is ConversationDomainError {
            XCTFail("raw fault must surface as its own error domain")
        } catch {
            // expected: the injected error escapes, transaction rolled back.
        }
        let remainingCount = try await RB3TestBed.count(
            stores.database, "SELECT COUNT(*) FROM conversations")
        XCTAssertEqual(remainingCount, 0,
                       "failed create must leave NO row and therefore no fake identity")
    }

    func testCreateDefaultWorkspaceUsesExplicitContextOnly() async throws {
        let stores = try await RB3TestBed.stores()
        // Host enables default binding but provides NO explicit context:
        // typed missing context BEFORE any write.
        let unbound = RB3TestBed.makeDomain(stores: stores, lifecycle: nil,
                                            bindsDefaultWorkspace: true,
                                            defaultWorkspaceID: nil)
        do {
            _ = try await unbound.domain.create(payload: nil)
            XCTFail("must fail closed on missing default workspace context")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "runtimeUnavailable")
            XCTAssertEqual(error.wireReason, "defaultWorkspaceContextMissing")
        }
        let __xctestHoist5 = try await RB3TestBed.count(stores.database,
                                                  "SELECT COUNT(*) FROM conversations")
        XCTAssertEqual(__xctestHoist5, 0)

        // Explicit trusted workspace that exists -> canonical ownership rows.
        let workspaceID = UUID()
        try await stores.workspaces.saveWorkspace(WorkspaceRecord(
            id: workspaceID, name: "Shared project", rootBookmark: Data([0x01]),
            kind: .project))
        let bound = RB3TestBed.makeDomain(stores: stores, lifecycle: nil,
                                          bindsDefaultWorkspace: true,
                                          defaultWorkspaceID: workspaceID)
        let created = try await bound.domain.create(payload: .object([
            "title": .string("Bound")]))
        let ownerRaw = try await RB3TestBed.workspaceIDColumn(
            stores.database, conversationID: created.conversationID)
        let owner = try XCTUnwrap(ownerRaw)
        XCTAssertEqual(owner, workspaceID.uuidString,
                       "explicit host default bound via the ORIGINAL statements")

        // A stale (deleted) trusted reference is refused, and there is NO
        // automatic "first workspace" fallback anywhere in the store.
        let ghost = UUID()
        let ghostBundle = RB3TestBed.makeDomain(stores: stores, lifecycle: nil,
                                                bindsDefaultWorkspace: true,
                                                defaultWorkspaceID: ghost)
        do {
            _ = try await ghostBundle.domain.create(payload: nil)
            XCTFail("ghost default workspace must be refused")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireReason, "trustedDefaultWorkspaceMissing")
        }
    }

    // MARK: rename/archive CAS

    func testRenameSingleWriterCASConcurrentTwoAttemptsOneWinner() async throws {
        let bundle = try await makeBundle()
        let stores = bundle.stores
        let record = try await RB3TestBed.seedOrdinary(stores, title: "before")
        let revision = try await RB3TestBed.revision(stores.database, record.id)

        // Qualifier repair (2026-10-19): exhaustive catch (Swift 6); only a
        // TYPED ConversationDomainError counts as a legitimate rejection.
        func attempt(_ title: String) async -> Result<String, Error> {
            do {
                let reply = try await bundle.domain.rename(
                    conversationID: record.id, revision: revision,
                    payload: .object(["title": .string(title)]))
                return .success(reply.revision)
            } catch {
                return .failure(error)
            }
        }
        async let first = attempt("Alpha")
        async let second = attempt("Beta")
        let results = await [try first, try second]
        let successes = results.compactMap { try? $0.get() }
        let rejections: [ConversationDomainError] = results.compactMap { result in
            if case .failure(let error) = result {
                return error as? ConversationDomainError
            }
            return nil
        }
        XCTAssertEqual(successes.count, 1, "exactly one concurrent rename may commit")
        let rejected = try XCTUnwrap(rejections.first,
                                     "the loser must be a TYPED domain rejection")
        let acceptableConflictCodes: [ConversationDomainError] = [.duplicateInFlight,
                                                                   .staleRevision]
        XCTAssertTrue(acceptableConflictCodes.contains(where: {
            $0.wireCode == rejected.wireCode
        }), "got \(rejected.wireCode)")
        let finalRaw = try await stores.conversations.conversation(id: record.id)
        let final = try XCTUnwrap(finalRaw)
        XCTAssertTrue(["Alpha", "Beta"].contains(final.title))
        XCTAssertEqual(final.titleOrigin, .manual, "native title_origin semantics preserved")
        // The OLD revision is now provably stale (zero-effect verified below).
        do {
            _ = try await bundle.domain.rename(conversationID: record.id, revision: revision,
                                               payload: .object(["title": .string("Gamma")]))
            XCTFail("old revision must be stale")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "staleRevision")
        }
        let unchangedRaw = try await stores.conversations.conversation(id: record.id)
        let unchanged = try XCTUnwrap(unchangedRaw)
        XCTAssertNotEqual(unchanged.title, "Gamma", "stale rename must apply zero changes")
    }

    func testRenameSameStoredTimestampDifferentTitleIsStaleNeverFalseOverwrite() async throws {
        // This is the exact case the Main row-digest decision exists for:
        // fixed clock => identical persisted updated_at strings, so an
        // updatedAt-only CAS would FALSELY accept the second writer.
        let stores = try await RB3TestBed.stores()
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let creator = RB3TestBed.makeDomain(stores: stores, lifecycle: nil,
                                             clock: { fixed })
        let created = try await creator.domain.create(payload: .object([
            "title": .string("initial")]))
        // Force both rows' created_at/updated_at to the SAME stored strings by
        // creating a second conversation also stamped at `fixed`.
        let baseRevision = BaseRevision(resourceID: created.resourceID,
                                        version: created.revision)
        let writerA = RB3TestBed.makeDomain(stores: stores, lifecycle: nil,
                                             clock: { fixed })
        let firstRename = try await writerA.domain.rename(
            conversationID: created.conversationID, revision: baseRevision,
            payload: .object(["title": .string("Alpha")]))
        XCTAssertNotEqual(firstRename.revision, baseRevision.version,
                          "title participates in the row digest")
        // Second writer holds the PRE-rename revision and renames with the
        // SAME clock: updated_at is byte-identical, only title differs.
        let writerB = RB3TestBed.makeDomain(stores: stores, lifecycle: nil,
                                             clock: { fixed })
        do {
            _ = try await writerB.domain.rename(
                conversationID: created.conversationID, revision: baseRevision,
                payload: .object(["title": .string("Beta")]))
            XCTFail("same-stored-timestamp mutation must be stale, not a false overwrite")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "staleRevision")
        }
        let storedRaw = try await stores.conversations.conversation(id: created.conversationID)
        let stored = try XCTUnwrap(storedRaw)
        XCTAssertEqual(stored.title, "Alpha", "the committed value survives the rejected write")
    }

    func testArchiveCASAndUnarchiveNullStampAndNavigationNeverCancels() async throws {
        let lifecycle = ScriptedLifecycle()
        let bundle = try await makeBundleWith(lifecycle: lifecycle)
        let stores = bundle.stores
        let record = try await RB3TestBed.seedOrdinary(stores, title: "archive me")
        var revision = try await RB3TestBed.revision(stores.database, record.id)

        let archivedReply = try await bundle.domain.archive(
            conversationID: record.id, revision: revision,
            payload: .object(["archived": .boolean(true)]))
        XCTAssertNotEqual(archivedReply.revision, revision.version)
        revision = BaseRevision(resourceID: revision.resourceID, version: archivedReply.revision)

        let rawArchived: String? = try await stores.database.reader { db in
            try String.fetchOne(db, sql: """
                SELECT archived_at FROM conversations WHERE id = ?
                """, arguments: [record.id.uuidString])
        }
        XCTAssertNotNil(rawArchived, "archive stamps the original codec value")

        // Stale CAS attempt: zero effect.
        do {
            _ = try await bundle.domain.archive(
                conversationID: record.id,
                revision: BaseRevision(resourceID: revision.resourceID, version: "sha256:" + String(repeating: "0", count: 64)),
                payload: .object(["archived": .boolean(false)]))
            XCTFail("stale archive must be refused")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "staleRevision")
        }
        let stillArchivedRaw = try await stores.conversations.conversation(id: record.id)
        let stillArchived = try XCTUnwrap(stillArchivedRaw)
        XCTAssertNotNil(stillArchived.archivedAt)

        // Unarchive stores NULL again.
        let unarchived = try await bundle.domain.archive(
            conversationID: record.id, revision: revision,
            payload: .object(["archived": .boolean(false)]))
        _ = unarchived
        let cleared: String? = try await stores.database.reader { db in
            try String.fetchOne(db, sql: """
                SELECT archived_at FROM conversations WHERE id = ?
                """, arguments: [record.id.uuidString])
        }
        XCTAssertNil(cleared)

        // ORDINARY navigation (list/get/messagePage/archive/rename) must not
        // have invoked the destructive lifecycle even once.
        _ = try await bundle.domain.list(payload: nil)
        _ = try await bundle.domain.get(conversationID: record.id)
        _ = try await bundle.domain.messagePage(conversationID: record.id, payload: nil)
        XCTAssertEqual(lifecycle.events.filter { $0.hasPrefix("begin:") }.count, 0)
        XCTAssertEqual(lifecycle.events.filter { $0.hasPrefix("drainStart:") }.count, 0)
        XCTAssertEqual(lifecycle.events.filter { $0.hasPrefix("abort:") }.count, 0)
        XCTAssertEqual(lifecycle.events.filter { $0.hasPrefix("commit:") }.count, 0)
    }

    // MARK: digest sensitivity

    func testRowDigestIsDeterministicAndSensitiveToNullTypeUnicodeAndDelimiters() async throws {
        let bundle = try await makeBundle()
        let stores = bundle.stores
        let sameClock = Date(timeIntervalSince1970: 1_500_000_000)
        let a = try await RB3TestBed.seedOrdinary(stores, title: "a\u{0000}b",
                                                  createdAt: sameClock, updatedAt: sameClock)
        let b = try await RB3TestBed.seedOrdinary(stores, title: "ab",
                                                  createdAt: sameClock, updatedAt: sameClock)
        let c = try await RB3TestBed.seedOrdinary(
            stores, title: "a\", \"archived_at\": null, \"x\": \"b",
            createdAt: sameClock, updatedAt: sameClock)
        let digestARaw = try await RB3TestBed.rawDigest(stores.database, a.id)
        let digestA = try XCTUnwrap(digestARaw)
        let digestBRaw = try await RB3TestBed.rawDigest(stores.database, b.id)
        let digestB = try XCTUnwrap(digestBRaw)
        let digestCRaw = try await RB3TestBed.rawDigest(stores.database, c.id)
        let digestC = try XCTUnwrap(digestCRaw)
        let __xctestHoist6 = try await RB3TestBed.rawDigest(stores.database, a.id)
        XCTAssertEqual(digestA,__xctestHoist6,
                       "deterministic per identical row")
        XCTAssertNotEqual(digestA, digestB, "embedded NUL cannot alias a shorter title")
        XCTAssertNotEqual(digestB, digestC, "JSON-shaped delimiter bait cannot alias plain text")

        // SQL NULL vs the TEXT "null" vs typed integers must differ.
        let d = try await RB3TestBed.seedOrdinary(stores, title: "nullish",
                                                  createdAt: sameClock, updatedAt: sameClock)
        try await stores.database.writer { db in
            try db.execute(sql: "UPDATE conversations SET archived_at = 'null' WHERE id = ?",
                           arguments: [d.id.uuidString])
        }
        let digestNullishRaw = try await RB3TestBed.rawDigest(stores.database, d.id)
        let digestNullish = try XCTUnwrap(digestNullishRaw)
        let digestPlainRaw = try await RB3TestBed.rawDigest(
            stores.database, try await RB3TestBed.seedOrdinary(stores, title: "nullish",
                                                               createdAt: sameClock,
                                                               updatedAt: sameClock).id)
        let digestPlain = try XCTUnwrap(digestPlainRaw)
        XCTAssertNotEqual(digestNullish, digestPlain,
                          "TEXT 'null' must not digest like SQL NULL")

        // is_searchable INTEGER storage-class participates (type tag, not text).
        let e = try await RB3TestBed.seedOrdinary(stores, title: "searchable",
                                                  createdAt: sameClock, updatedAt: sameClock)
        let beforeRaw = try await RB3TestBed.rawDigest(stores.database, e.id)
        let before = try XCTUnwrap(beforeRaw)
        try await stores.database.writer { db in
            try db.execute(sql: "UPDATE conversations SET is_searchable = 0 WHERE id = ?",
                           arguments: [e.id.uuidString])
        }
        let afterRaw = try await RB3TestBed.rawDigest(stores.database, e.id)
        let after = try XCTUnwrap(afterRaw)
        XCTAssertNotEqual(before, after,
                          "hidden/visible searchability is conversation metadata and must bind")
    }

    // MARK: message pages / roles

    func testRolesPassThroughVerbatimIncludingSystemAndGoalContinuation() async throws {
        let bundle = try await makeBundle()
        let stores = bundle.stores
        let record = try await RB3TestBed.seedOrdinary(stores, title: "roles")
        var expected: [(UUID, String)] = []
        for role in ["user", "assistant", "system", "goalContinuation", "toolOutputLike"] {
            let message = try await RB3TestBed.seedMessage(stores,
                                                           conversationID: record.id,
                                                           role: role,
                                                           content: "body for \(role)")
            expected.append((message.id, role))
        }
        let reply = try await bundle.domain.messagePage(conversationID: record.id, payload: nil)
        let byID = Dictionary(uniqueKeysWithValues: reply.rows.map { ($0.messageID, $0.role) })
        for (id, role) in expected {
            XCTAssertEqual(byID[id], role,
                           "stored roles are never renamed to assistant or dropped")
        }
    }

    func testMessagePageKeysetMatchesNativeStoreAcrossCursors() async throws {
        let bundle = try await makeBundle()
        let stores = bundle.stores
        let record = try await RB3TestBed.seedOrdinary(stores, title: "paged")
        var base = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<45 {
            try await RB3TestBed.seedMessage(stores, conversationID: record.id,
                                             content: "message \(index)",
                                             createdAt: base.addingTimeInterval(TimeInterval(index)))
            base = base.addingTimeInterval(1)
        }
        var collected: [UUID] = []
        var cursor: SettingsDomainV1.JSONValue?
        while true {
            var object: [String: SettingsDomainV1.JSONValue] = ["limit": .integer(20)]
            if let cursor { object["before"] = cursor }
            let reply = try await bundle.domain.messagePage(conversationID: record.id,
                                                            payload: .object(object))
            collected.insert(contentsOf: reply.rows.map(\.messageID), at: collected.startIndex)
            guard reply.hasEarlier, let earlier = reply.earlierCursor else { break }
            cursor = .string(earlier)
        }
        let native = try await stores.conversations.messages(conversationID: record.id)
        XCTAssertEqual(collected, native.map(\.id),
                       "full-history walk equals the native chronological order")
    }

    func testOversizeMessageUsesOwnedHandleAndReassemblesByteExact() async throws {
        let bundle = try await makeBundle()
        let stores = bundle.stores
        let record = try await RB3TestBed.seedOrdinary(stores, title: "huge")
        // 200K of mixed multibyte/quote/backslash/newline content.
        var giant = ""
        for index in 0..<20_000 {
            giant += "段落\u{1F600}\"\\n\u{1F1E8}\u{1F1F3}item\(index) line\n"
        }
        let message = try await RB3TestBed.seedMessage(stores, conversationID: record.id,
                                                       content: giant)
        let originalBytes = Data(giant.utf8)

        let page = try await bundle.domain.messagePage(conversationID: record.id, payload: nil)
        let row = try XCTUnwrap(page.rows.first)
        XCTAssertNil(row.content, "oversize content must NEVER be inline-truncated")
        XCTAssertFalse(row.contentInlineComplete)
        let handle = try XCTUnwrap(row.contentHandle)
        XCTAssertEqual(row.totalBytes, originalBytes.count,
                       "handle row declares the REAL full byte count")

        var offset = 0
        var assembled = Data()
        var slices = 0
        // Qualifier repair (2026-10-19): keep the final slice visible after
        // the loop (the loop-local `reply` cannot be read outside it).
        var lastReply: ConversationContentSliceReply?
        while true {
            let reply = try await bundle.domain.readContent(
                conversationID: record.id,
                payload: .object([
                    "handle": .string(handle),
                    "offset": .integer(Int64(offset)),
                    "maxBytes": .integer(4096),
                ]))
            XCTAssertLessThanOrEqual(
                ConversationWireBudget.encodedObjectBytes(reply.wireObject),
                SettingsDomainV1.pageBudgetBytes,
                "every slice response fits the normal page")
            lastReply = reply
            assembled.append(Data(reply.chunk.chunk.utf8))
            slices += 1
            XCTAssertNotNil(String(data: assembled, encoding: .utf8),
                            "each slice and the running assembly stay valid UTF-8")
            guard let next = reply.chunk.nextOffset, !reply.chunk.done else { break }
            XCTAssertGreaterThan(next, offset, "cursor must advance per slice")
            offset = next
            XCTAssertLessThan(slices, 400, "bounded progress")
        }
        XCTAssertEqual(assembled, originalBytes, "byte-exact reassembly")
        let finalReply = try XCTUnwrap(lastReply)
        XCTAssertEqual(finalReply.chunk.totalBytes, originalBytes.count)
        _ = message
    }

    func testScalarBoundaryAndForeignHandleRejections() async throws {
        let bundle = try await makeBundle()
        let stores = bundle.stores
        let record = try await RB3TestBed.seedOrdinary(stores, title: "boundary")
        let other = try await RB3TestBed.seedOrdinary(stores, title: "other")
        // Oversized content on `record`.
        let giant = String(repeating: "漢字 emoji \u{1F4A9} test", count: 6_000)
        try await RB3TestBed.seedMessage(stores, conversationID: record.id, content: giant)
        let page = try await bundle.domain.messagePage(conversationID: record.id, payload: nil)
        let handle = try XCTUnwrap(page.rows.first?.contentHandle)

        // Foreign conversation cannot read the handle.
        do {
            _ = try await bundle.domain.readContent(
                conversationID: other.id,
                payload: .object(["handle": .string(handle),
                                  "offset": .integer(0), "maxBytes": .integer(100)]))
            XCTFail("foreign owner must be denied")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "notFound")
        }
        // Unknown handle: identical typed denial (no probing oracle).
        do {
            _ = try await bundle.domain.readContent(
                conversationID: record.id,
                payload: .object(["handle": .string("chunk:v1:ffffffffffffffffffffffffffffffff"),
                                  "offset": .integer(0), "maxBytes": .integer(100)]))
            XCTFail("unknown handle must be denied")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "notFound")
        }
        // Offset on a continuation byte is refused via the reader contract.
        var bytes = [UInt8](giant.utf8)
        _ = bytes
        // Walk one byte INTO a multibyte scalar to force invalidOffset: scan
        // for the first 4-byte scalar (emoji) and target offset+1.
        var emojiStart: Int?
        var index = 0
        while index < bytes.count {
            if (bytes[index] & 0xF8) == 0xF0 { emojiStart = index; break }
            index += 1
        }
        if let start = emojiStart {
            do {
                _ = try await bundle.domain.readContent(
                    conversationID: record.id,
                    payload: .object(["handle": .string(handle),
                                      "offset": .integer(Int64(start + 1)),
                                      "maxBytes": .integer(64)]))
                XCTFail("continuation-byte offset must be refused")
            } catch let error as ConversationDomainError {
                XCTAssertEqual(error.wireCode, "invalidEnvelope")
                XCTAssertEqual(error.wireReason, "contentOffsetInvalid")
            }
        }
    }

    func testPageBudgetTrimKeepsEveryRowReachableAcrossCursors() async throws {
        let bundle = try await makeBundle()
        let stores = bundle.stores
        let record = try await RB3TestBed.seedOrdinary(stores, title: "trim walk")
        // 30 messages of ~2 KiB each; requesting 30 at once exceeds the
        // budget, so the adapter must trim while keeping the walk complete.
        var base = Date(timeIntervalSince1970: 3_000_000)
        for index in 0..<30 {
            let text = String(repeating: "内容\u{1F9A0}, \"q\"", count: 40) + "#\(index)"
            try await RB3TestBed.seedMessage(stores, conversationID: record.id,
                                             content: text,
                                             createdAt: base)
            base = base.addingTimeInterval(2)
        }
        var collected: [UUID] = []
        var cursor: SettingsDomainV1.JSONValue?
        var pages = 0
        while true {
            var object: [String: SettingsDomainV1.JSONValue] = ["limit": .integer(30)]
            if let cursor { object["before"] = cursor }
            let reply = try await bundle.domain.messagePage(conversationID: record.id,
                                                            payload: .object(object))
            XCTAssertFalse(reply.rows.isEmpty, "every page must keep progressing")
            XCTAssertLessThanOrEqual(
                ConversationWireBudget.encodedObjectBytes(reply.wireObject),
                SettingsDomainV1.pageBudgetBytes, "trimmed pages fit the budget")
            collected.append(contentsOf: reply.rows.map(\.messageID))
            guard reply.hasEarlier, let earlier = reply.earlierCursor else { break }
            cursor = .string(earlier)
            pages += 1
            XCTAssertLessThan(pages, 60)
        }
        let native = try await stores.conversations.messages(conversationID: record.id)
        XCTAssertEqual(Set(collected), Set(native.map(\.id)),
                       "trimming may delay content, never make it unreachable")
        XCTAssertEqual(collected.count, Set(collected).count, "no duplicates across the walk")
    }

    // MARK: unknown ids / zero effects

    func testUnknownAndForeignIdsAreTypedNotFoundWithZeroEffects() async throws {
        let bundle = try await makeBundle()
        let stores = bundle.stores
        _ = try await RB3TestBed.seedOrdinary(stores, title: "only one")
        let ghost = UUID()
        let revision = BaseRevision(resourceID: ConversationRowRevision.resourceID(conversationID: ghost),
                                    version: "sha256:" + String(repeating: "a", count: 64))
        do { _ = try await bundle.domain.get(conversationID: ghost); XCTFail() }
        catch let error as ConversationDomainError { XCTAssertEqual(error.wireCode, "notFound") }
        do { _ = try await bundle.domain.messagePage(conversationID: ghost, payload: nil); XCTFail() }
        catch let error as ConversationDomainError { XCTAssertEqual(error.wireCode, "notFound") }
        do {
            _ = try await bundle.domain.rename(conversationID: ghost, revision: revision,
                                               payload: .object(["title": .string("x")]))
            XCTFail()
        } catch let error as ConversationDomainError { XCTAssertEqual(error.wireCode, "notFound") }
        do {
            _ = try await bundle.domain.archive(conversationID: ghost, revision: revision,
                                                payload: .object(["archived": .boolean(true)]))
            XCTFail()
        } catch let error as ConversationDomainError { XCTAssertEqual(error.wireCode, "notFound") }
        do {
            _ = try await bundle.domain.delete(conversationID: ghost, revision: revision)
            XCTFail()
        } catch let error as ConversationDomainError {
            // Fail-closed FIRST on the missing lifecycle dependency; the
            // unknown id and the unregistered dependency are both typed,
            // both zero-effect. Which comes first is part of the documented
            // API: dependency check precedes the row read.
            XCTAssertEqual(error.wireCode, "runtimeUnavailable")
        }
        let __xctestHoist7 = try await RB3TestBed.count(stores.database,
                                                  "SELECT COUNT(*) FROM conversations")
        XCTAssertEqual(__xctestHoist7, 1)
    }

    func testRevisionResourceIDMustNameTheOwnerConversation() async throws {
        let bundle = try await makeBundle()
        let stores = bundle.stores
        let owner = try await RB3TestBed.seedOrdinary(stores, title: "owner")
        let other = try await RB3TestBed.seedOrdinary(stores, title: "other")
        let digestRaw = try await RB3TestBed.rawDigest(stores.database, owner.id)
        let digest = try XCTUnwrap(digestRaw)
        // TRUE digest for the row, but resourceID naming the OTHER conversation.
        let mismatched = BaseRevision(
            resourceID: ConversationRowRevision.resourceID(conversationID: other.id),
            version: digest)
        do {
            _ = try await bundle.domain.rename(conversationID: owner.id, revision: mismatched,
                                               payload: .object(["title": .string("hijack")]))
            XCTFail("cross-named revision must be refused")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "invalidEnvelope")
            XCTAssertEqual(error.wireReason, "revisionResourceMismatch")
        }
        let unchangedRaw = try await stores.conversations.conversation(id: owner.id)
        let unchanged = try XCTUnwrap(unchangedRaw)
        XCTAssertEqual(unchanged.title, "owner", "zero effects on the pairing failure")
    }

    // MARK: get snapshot honesty

    func testGetSnapshotFieldsCountsAndDefaultPolicyAreHonest() async throws {
        let bundle = try await makeBundle()
        let stores = bundle.stores
        let record = try await RB3TestBed.seedOrdinary(stores, title: "snapshot")
        var base = Date(timeIntervalSince1970: 4_000_000)
        for index in 0..<25 {
            try await RB3TestBed.seedMessage(stores, conversationID: record.id,
                                             content: "m\(index)",
                                             createdAt: base.addingTimeInterval(TimeInterval(index)))
        }
        for index in 0..<200 {
            try await RB3TestBed.seedRun(stores.database, conversationID: record.id,
                                         startedAt: Date(timeIntervalSince1970:
                                            5_000_000 + Double(index)))
        }
        try await RB3TestBed.seedPendingInput(stores, conversationID: record.id, content: "queued")

        let snapshot = try await bundle.domain.get(conversationID: record.id)
        XCTAssertEqual(snapshot.firstScreen.rows.count, 20, "native snapshot window")
        XCTAssertTrue(snapshot.firstScreen.hasEarlier)
        XCTAssertEqual(snapshot.messagesTotalCount, 25)
        XCTAssertEqual(snapshot.runsTotalCount, 200)
        XCTAssertEqual(snapshot.runs.count, 160, "the native snapshot window, not a new cap")
        XCTAssertTrue(snapshot.runsTruncated)
        XCTAssertEqual(snapshot.pendingInputsTotalCount, 1)
        XCTAssertEqual(snapshot.pendingInputs.count, 1)
        XCTAssertEqual(snapshot.titleOrigin, "autoPending")
        XCTAssertNil(snapshot.archivedAtRaw)
        XCTAssertEqual(snapshot.taskPolicy.resolvedApprovalMode, .ask,
                       "missing-row default preserved from the ORIGINAL store")
        let __xctestHoist8 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM runs WHERE conversation_id = ? AND state = 'completed'",
            StatementArguments([record.id.uuidString]))
        XCTAssertEqual(__xctestHoist8, 200)
        // Every run summary carries the REAL state string from the durable row.
        XCTAssertEqual(Set(snapshot.runs.map(\.state)), ["completed"])
        XCTAssertLessThanOrEqual(
            ConversationWireBudget.encodedObjectBytes(snapshot.wireObject),
            SettingsDomainV1.pageBudgetBytes)
        _ = base
    }

    private func makeBundleWith(lifecycle: ConversationDeletionLifecycle,
                                 name: String = #function) async throws
        -> RB3TestBed.DomainBundle
    {
        let stores = try await RB3TestBed.stores(name: name)
        return RB3TestBed.makeDomain(stores: stores, lifecycle: lifecycle)
    }
}

// MARK: - Workspace save helper for tests

extension SQLiteWorkspaceStore {
    /// Test-only convenience over the ORIGINAL public saveWorkspace; it
    /// adds no production surface.
    func saveWorkspaceNamedForTest(_ name: String) async throws -> UUID {
        let id = UUID()
        try await saveWorkspace(WorkspaceRecord(id: id, name: name, rootBookmark: Data([0x00]),
                                                kind: .project))
        return id
    }
}
