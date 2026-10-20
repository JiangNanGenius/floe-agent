// SPDX-License-Identifier: MPL-2.0
//
// Authored host tests for the P3 personalization adapter + shared
// content.read dispatcher (SOURCE ONLY — not executed by the authoring
// job). Vectors: behavioralTestDesign personalization.* positives/
// negatives + P3 checks (active-slot CAS, cursor digest, 48KiB actual-
// budget inline vs handle, 24k rejection, revisionsMeta paging, shared
// key scope dispatch).

import XCTest
import Foundation
import GRDB
import Crypto
import FloeCore
import FloePersistence
import FloeAgentRuntime
@testable import FloeAndroidCore

final class RuntimeFacadePersonalizationTests: XCTestCase {
    private var manager: DatabaseManager!
    private var url: URL!
    private var workspaces: SQLiteWorkspaceStore!
    private var port: SyntheticContentReaderPort!
    private var contentStore: FacadePersonalizationContentStore!
    private var adapter: FacadePersonalizationAdapter!

    override func setUp() async throws {
        let made = try await IntelligenceTestSupport.makeDatabase("per-\(UUID().uuidString.prefix(8))")
        manager = made.0
        url = made.1
        workspaces = SQLiteWorkspaceStore(database: manager)
        port = SyntheticContentReaderPort()
        contentStore = FacadePersonalizationContentStore(port: port)
        adapter = FacadePersonalizationAdapter(database: manager,
                                               workspaceStore: workspaces,
                                               contentStore: contentStore)
    }

    override func tearDown() async throws {
        IntelligenceTestSupport.cleanup(url)
    }

    private func getReply(kind: SettingsDomainV1.PersonalizationKind = .soul,
                          workspaceID: UUID? = nil,
                          cursor: Int = 0, limit: Int = 50) async throws
        -> SettingsDomainV1.PersonalizationGetReply
    {
        try await adapter.read(PersonalizationGetRequest(
            kind: kind, workspaceID: workspaceID,
            revisionsCursor: cursor, revisionsLimit: limit))
    }

    // MARK: - active slot vs latest revision (Main review issue 1)

    func testActiveSlotIsNotMaxRevision() async throws {
        _ = try await IntelligenceTestSupport.seedDocument(manager, kind: .soul,
                                                           content: "v1 active")
        _ = try await IntelligenceTestSupport.seedDocument(manager, kind: .soul,
                                                           content: "v2 active")
        _ = try await IntelligenceTestSupport.seedDocument(manager, kind: .soul,
                                                           content: "v3 active")
        // Two AUTOMATIC inactive drafts appended ABOVE the active row.
        _ = try await IntelligenceTestSupport.seedDocument(manager, kind: .soul,
                                                           content: "draft four",
                                                           source: .automatic,
                                                           isActive: false)
        _ = try await IntelligenceTestSupport.seedDocument(manager, kind: .soul,
                                                           content: "draft five",
                                                           source: .automatic,
                                                           isActive: false)
        let reply = try await getReply()
        XCTAssertEqual(reply.active?.revision, 3)
        XCTAssertEqual(reply.latestRevision, 5)
        XCTAssertTrue(reply.active?.isActive ?? false)
        let storedSlot = try await IntelligenceTestSupport.activeSlot(manager,
                                                                      kindRaw: "soul",
                                                                      workspaceID: nil)
        XCTAssertEqual(reply.revisionToken, storedSlot)
        XCTAssertEqual(reply.revisionsMeta.count, 5)
        XCTAssertEqual(reply.revisionsMeta.first?.revision, 5,
                       "metadata ordered revision DESC")
        XCTAssertFalse(reply.revisionsMeta.contains { $0.isActive
            && $0.revision != 3 })
    }

    func testCursorAbsentAndPresentTokens() async throws {
        let reply = try await getReply()
        XCTAssertEqual(reply.cursor.revision, "absent",
                       "no cursor row = literal 'absent' token (real default state)")
        XCTAssertTrue(reply.cursor.automaticUpdatesEnabled,
                      "original synthesis defaults (never persisted)")
        // Set automatic with expected 'absent' CREATES the row.
        let set = try await adapter.setAutomatic(
            expectedCursorToken: "absent",
            request: PersonalizationAutomaticRequest(kind: .soul, workspaceID: nil,
                                                     enabled: false))
        XCTAssertNotEqual(set.cursor.revision, "absent")
        XCTAssertFalse(set.cursor.automaticUpdatesEnabled)
        // Mismatch directions both staleRevision, nothing written.
        do {
            _ = try await adapter.setAutomatic(
                expectedCursorToken: "absent",
                request: PersonalizationAutomaticRequest(kind: .soul, workspaceID: nil,
                                                         enabled: true))
            XCTFail("expected absent but row exists")
        } catch let error as PersonalizationAdapterError {
            XCTAssertEqual(error.wireCode, "staleRevision")
        }
        // 'absent' expectation mismatch must NOT write: still enabled=false.
        let after = try await getReply()
        XCTAssertFalse(after.cursor.automaticUpdatesEnabled)
    }

    func testAutomaticTogglePreservesCountersAndRejectsSameSecond() async throws {
        _ = try await IntelligenceTestSupport.seedDocument(manager, kind: .soul,
                                                           content: "anchor")
        let documents = SQLitePersonalizationStore(database: manager)
        var cursor = PersonalizationUpdateCursor(kind: .soul,
                                                 automaticUpdatesEnabled: true,
                                                 lastGeneratedAt: Date().addingTimeInterval(-3_600),
                                                 completedRunsSinceUpdate: 4,
                                                 userMessagesSinceUpdate: 9)
        try await documents.saveCursor(cursor)
        let reply = try await getReply()
        let token = reply.cursor.revision
        XCTAssertNotEqual(token, reply.cursor.updatedAt,
                          "the CAS token is the 8-column digest, never the raw updated_at")
        let flipped = try await adapter.setAutomatic(expectedCursorToken: token,
            request: PersonalizationAutomaticRequest(kind: .soul, workspaceID: nil,
                                                     enabled: false))
        XCTAssertEqual(flipped.cursor.completedRunsSinceUpdate, 4)
        XCTAssertEqual(flipped.cursor.userMessagesSinceUpdate, 9)
        XCTAssertNotNil(flipped.cursor.lastGeneratedAt,
                        "toggle preserves lastGeneratedAt verbatim")
        XCTAssertNotEqual(flipped.cursor.revision, token)
        // Second writer with the OLD token (same second) → staleRevision:
        // no timestamp-only pass.
        do {
            _ = try await adapter.setAutomatic(expectedCursorToken: token,
                request: PersonalizationAutomaticRequest(kind: .soul, workspaceID: nil,
                                                         enabled: true))
            XCTFail("same-second collision must be caught by the full-row digest")
        } catch let error as PersonalizationAdapterError {
            XCTAssertEqual(error.wireCode, "staleRevision")
        }
        cursor.automaticUpdatesEnabled = true
    }

    // MARK: - save CAS matrix

    func testSaveCreateOverAbsentAndMaxPlusOneAboveDrafts() async throws {
        _ = try await IntelligenceTestSupport.seedDocument(manager, kind: .userProfile,
                                                           content: "active three")
        _ = try await IntelligenceTestSupport.seedDocument(manager, kind: .userProfile,
                                                           content: "draft four",
                                                           source: .automatic, isActive: false)
        _ = try await IntelligenceTestSupport.seedDocument(manager, kind: .userProfile,
                                                           content: "draft five",
                                                           source: .automatic, isActive: false)
        let reply = try await getReply(kind: .userProfile)
        let saved = try await adapter.save(
            expectedActiveToken: reply.revisionToken,
            request: PersonalizationSaveRequest(kind: .userProfile, workspaceID: nil,
                                                content: " manual six "))
        // The three seeded rows occupy revisions 1..3 (one active + two
        // drafts); MAX+1 over ALL rows (drafts included) is 4.
        XCTAssertEqual(saved.document.revision, 4, "MAX(revision)+1 over ALL rows incl. drafts")
        XCTAssertTrue(saved.document.isActive)
        XCTAssertEqual(saved.document.source, .manual)
        XCTAssertEqual(saved.latestRevision, 4)
        XCTAssertEqual(saved.revisionToken, "\(saved.document.id.uuidString).4")
        // The drafts stay inactive forever (never activated by editing).
        let after = try await getReply(kind: .userProfile)
        // The previous active becomes inactive too: three rows below the
        // new revision are inactive (1 + the two drafts) and only 4 is active.
        let inactiveBelow = after.revisionsMeta.filter { $0.revision < 4 && !$0.isActive }
        XCTAssertEqual(inactiveBelow.count, 3)
        XCTAssertFalse(after.revisionsMeta.contains { $0.isActive && $0.revision != 4 })
    }

    func testConcurrentManualSavesOneWins() async throws {
        _ = try await IntelligenceTestSupport.seedDocument(manager, kind: .soul,
                                                           content: "base")
        let reply = try await getReply()
        let token = reply.revisionToken
        func attempt(_ content: String) async -> Bool {
            do {
                _ = try await adapter.save(
                    expectedActiveToken: token,
                    request: PersonalizationSaveRequest(kind: .soul, workspaceID: nil,
                                                        content: content))
                return true
            } catch {
                return false
            }
        }
        let first = await attempt("writer one")
        let second = await attempt("writer two")
        XCTAssertTrue(first)
        XCTAssertFalse(second, "the second save over the consumed slot is staleRevision")
        let after = try await getReply()
        XCTAssertEqual(after.active?.content, "writer one")
    }

    func testDraftAppendNeverContendsWithEditing() async throws {
        _ = try await IntelligenceTestSupport.seedDocument(manager, kind: .soul,
                                                           content: "active one")
        let reply = try await getReply()
        // An inactive automatic draft appends (isActive=0 commit style).
        _ = try await IntelligenceTestSupport.seedDocument(manager, kind: .soul,
                                                           content: "silent draft",
                                                           source: .automatic,
                                                           isActive: false)
        let saved = try await adapter.save(
            expectedActiveToken: reply.revisionToken,
            request: PersonalizationSaveRequest(kind: .soul, workspaceID: nil,
                                                content: "user edit wins"))
        XCTAssertEqual(saved.document.revision, 3)
        XCTAssertTrue(saved.document.isActive)
        let after = try await getReply()
        XCTAssertFalse(after.revisionsMeta.first(where: { $0.revision == 2 })?.isActive ?? true,
                       "the draft stays inactive; the edit activated nothing else")
    }

    func testSaveOversizeAndEmptyRejectedBeforeMutation() async throws {
        let big = String(repeating: "あ", count: 24_001)
        do {
            _ = try PersonalizationSaveRequest.parse(.object([
                "kind": .string("soul"),
                "content": .string(big),
            ]))
            XCTFail("oversize must be rejected at parse BEFORE any transaction")
        } catch let error as PersonalizationAdapterError {
            guard case .payloadTooLarge(let maxChars) = error else {
                return XCTFail("expected payloadTooLarge")
            }
            XCTAssertEqual(maxChars, 24_000)
        }
        do {
            _ = try PersonalizationSaveRequest.parse(.object([
                "kind": .string("soul"),
                "content": .string("   \n  "),
            ]))
            XCTFail("empty must be rejected")
        } catch let error as PersonalizationAdapterError {
            XCTAssertEqual(error.wireCode, "invalidEnvelope")
            XCTAssertEqual(error.wireReason, "documentEmpty")
        }
        let reply = try await getReply()
        XCTAssertNil(reply.active, "no document row exists: rejects happened before mutation")
    }

    // MARK: - rollback

    func testRollbackAppendsActiveCopyAndNeverMutatesTarget() async throws {
        // active rev 3 + automatic drafts 4,5 (Main review issue 1 fixture).
        _ = try await IntelligenceTestSupport.seedDocument(manager, kind: .soul,
                                                           content: "soul one")
        _ = try await IntelligenceTestSupport.seedDocument(manager, kind: .soul,
                                                           content: "soul two")
        _ = try await IntelligenceTestSupport.seedDocument(manager, kind: .soul,
                                                           content: "soul three")
        _ = try await IntelligenceTestSupport.seedDocument(manager, kind: .soul,
                                                           content: "draft four",
                                                           source: .automatic, isActive: false)
        _ = try await IntelligenceTestSupport.seedDocument(manager, kind: .soul,
                                                           content: "draft five",
                                                           source: .automatic, isActive: false)
        let reply = try await getReply()
        XCTAssertEqual(reply.active?.revision, 3)
        XCTAssertEqual(reply.latestRevision, 5)
        // Native "confirm and enable": rollback ACTIVATES draft revision 4
        // by APPENDING an active rollback copy — the draft row stays.
        let rolled = try await adapter.rollback(
            expectedActiveToken: reply.revisionToken,
            request: PersonalizationRollbackRequest(kind: .soul, workspaceID: nil,
                                                    targetRevision: 4))
        XCTAssertEqual(rolled.document.revision, 6)
        XCTAssertEqual(rolled.document.source, .rollback)
        XCTAssertTrue(rolled.document.isActive)
        // History intact + target unchanged (append-only, non-destructive).
        let rows: [(revision: Int64, active: Int64, content: String)] =
            try await manager.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT revision, is_active, content FROM personalization_documents
                WHERE kind = 'soul' AND workspace_id IS NULL ORDER BY revision
                """).map { row in
                let revision: Int64 = row["revision"]
                let activeValue: DatabaseValue = row["is_active"]
                var active: Int64 = 0
                if case .int64(let raw) = activeValue.storage { active = raw }
                let content: String = row["content"]
                return (revision: revision, active: active, content: content)
            }
        }
        XCTAssertEqual(rows.count, 6)
        let draft4 = try XCTUnwrap(rows.first { $0.revision == 4 })
        XCTAssertEqual(draft4.active, 0,
                       "the rolled-back draft remains inactive forever")
        XCTAssertEqual(draft4.content, "draft four")
        let copy6 = try XCTUnwrap(rows.first { $0.revision == 6 })
        XCTAssertEqual(copy6.content, "draft four",
                       "the active copy is content-equal to the target")
        // Missing target + stale slot vectors.
        do {
            _ = try await adapter.rollback(
                expectedActiveToken: rolled.revisionToken,
                request: PersonalizationRollbackRequest(kind: .soul, workspaceID: nil,
                                                        targetRevision: 99))
            XCTFail("missing revision")
        } catch let error as PersonalizationAdapterError {
            XCTAssertEqual(error.wireReason, "revisionMissing")
        }
        do {
            _ = try await adapter.rollback(
                expectedActiveToken: reply.revisionToken,
                request: PersonalizationRollbackRequest(kind: .soul, workspaceID: nil,
                                                        targetRevision: 1))
            XCTFail("stale slot after the successful rollback")
        } catch let error as PersonalizationAdapterError {
            XCTAssertEqual(error.wireCode, "staleRevision")
        }
    }

    // MARK: - revisionsMeta paging + inline vs handle (Q10)

    func testRevisionsMetaDefaultPageFiftyWithNextCursor() async throws {
        _ = try await IntelligenceTestSupport.seedDocument(manager, kind: .soul,
                                                           content: "root")
        for index in 0..<55 {
            _ = try await IntelligenceTestSupport.seedDocument(
                manager, kind: .soul, content: "revision \(index)",
                source: .automatic, isActive: false)
        }
        let page1 = try await getReply(limit: 50)
        XCTAssertEqual(page1.revisionsMeta.count, 50)
        XCTAssertNotNil(page1.revisionsNextCursor)
        let page2 = try await getReply(cursor: try XCTUnwrap(page1.revisionsNextCursor.flatMap(Int.init)))
        XCTAssertEqual(page2.revisionsMeta.count, 6)
        XCTAssertNil(page2.revisionsNextCursor)
        for meta in page1.revisionsMeta {
            // metadata NEVER carries content — only bytes + digest.
            // Revisions: root=1, then "revision 0".. => content index =
            // revision - 2.
            let expected = "sha256:" + SHA256.hash(
                data: Data(("revision " + String(meta.revision - 2)).utf8))
                .map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(meta.contentDigest, expected)
            XCTAssertGreaterThan(meta.contentBytes, 0)
        }
    }

    func testInlineOnlyWhenCompleteEncodedResponseFitsOtherwiseHandle() async throws {
        // ASCII 10k doc → inline. CJK 24k doc (≈72KiB UTF-8) → handle.
        let ascii = String(repeating: "a", count: 10_000)
        _ = try await IntelligenceTestSupport.seedDocument(manager, kind: .soul,
                                                           content: ascii)
        let small = try await getReply()
        XCTAssertEqual(small.active?.content, ascii)
        XCTAssertNil(small.active?.contentHandle)
        let cjk = String(repeating: "文", count: 24_000)
        _ = try await IntelligenceTestSupport.seedDocument(manager, kind: .userProfile,
                                                           content: cjk)
        let big = try await getReply(kind: .userProfile)
        XCTAssertNil(big.active?.content, "never inline alongside a handle")
        let handle = try XCTUnwrap(big.active?.contentHandle)
        XCTAssertEqual(handle.bytes, cjk.utf8.count)
        // Handle content reads byte-exactly through the shared dispatcher.
        let dispatcher = RuntimeFacadeContentReader(contentStore: contentStore,
                                                   conversations: nil)
        var received = ""
        var offset = 0
        var guardCounter = 0
        while true {
            guardCounter += 1
            XCTAssertLessThan(guardCounter, 200, "chunking must terminate")
            let outcome = try await dispatcher.read(
                configurationScope: "personalization",
                payload: .object([
                    "handle": .string(handle.handle),
                    "offsetBytes": .integer(Int64(offset)),
                    "maxBytes": .integer(32_768),
                ]))
            guard case .personalizationChunk(let chunk) = outcome else {
                return XCTFail("personalization scope must yield a chunk")
            }
            // The 48KiB actual-byte rule with CJK: every encoded response
            // fits the page budget (escape-aware measurement).
            XCTAssertLessThanOrEqual(
                SettingsDomainV1.ContentBudget.encodedChunkResponseBytes(chunk),
                SettingsDomainV1.pageBudgetBytes)
            received += chunk.chunk
            offset = chunk.nextOffset ?? chunk.totalBytes
            if chunk.done { break }
        }
        XCTAssertEqual(received, cjk, "byte-exact reassembly on scalar boundaries")
        XCTAssertEqual(offset, cjk.utf8.count)
    }

    func testDispatcherRejectsUnknownScopeBeforeAnyRead() async throws {
        let dispatcher = RuntimeFacadeContentReader(contentStore: contentStore,
                                                   conversations: nil)
        do {
            _ = try await dispatcher.read(
                configurationScope: "credentials",
                payload: .object([
                    "handle": .string("chunk:v1:x"),
                    "offsetBytes": .integer(0),
                    "maxBytes": .integer(16),
                ]))
            XCTFail("unknown configurationScope must be rejected")
        } catch let error as ContentReadDispatchError {
            XCTAssertEqual(error.wireCode, "invalidEnvelope")
            XCTAssertEqual(error.wireReason, "configurationScopeMismatch")
        }
        // conversations scope without the RB3 authority bound: fail closed,
        // never fake.
        do {
            _ = try await dispatcher.read(
                configurationScope: "conversations",
                payload: .object([
                    "handle": .string("chunk:v1:x"),
                    "offsetBytes": .integer(0),
                    "maxBytes": .integer(16),
                ]))
            XCTFail("unbound conversations reader must fail typed")
        } catch let error as ContentReadDispatchError {
            XCTAssertEqual(error.wireCode, "unsupportedOperation")
        }
    }

    func testWorkspaceMissingTypedOnReadAndSave() async throws {
        do {
            _ = try await getReply(workspaceID: UUID())
            XCTFail("missing workspace")
        } catch let error as PersonalizationAdapterError {
            XCTAssertEqual(error.wireReason, "workspaceMissing")
        }
        let made = try await IntelligenceTestSupport.seedWorkspace(manager)
        _ = made
        try await IntelligenceTestSupport.deleteWorkspace(manager, id: made)
        do {
            _ = try await adapter.save(
                expectedActiveToken: "absent",
                request: PersonalizationSaveRequest(kind: .soul, workspaceID: made,
                                                    content: "deleted project soul"))
            XCTFail("workspace must be gone")
        } catch let error as PersonalizationAdapterError {
            XCTAssertEqual(error.wireReason, "workspaceMissing")
        }
    }

    func testHandleSaturatedFailsClosedNeverTruncates() async throws {
        await port.setSaturate(true)
        let cjk = String(repeating: "文", count: 24_000)
        _ = try await IntelligenceTestSupport.seedDocument(manager, kind: .soul,
                                                           content: cjk)
        do {
            _ = try await getReply()
            XCTFail("staging saturation must fail closed typed")
        } catch let error as PersonalizationAdapterError {
            XCTAssertEqual(error.wireCode, "persistenceUnavailable")
            XCTAssertEqual(error.wireReason, "contentHandleSaturated")
        }
    }
}
