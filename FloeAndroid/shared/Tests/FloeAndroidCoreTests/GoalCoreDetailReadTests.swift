// SPDX-License-Identifier: MPL-2.0
//
// goal-core batch (job-7efd60bb51d14f02) — DEFERRED test source for the
// additive conversation.get detail read, the corrected UTF-8 prefix
// helpers, and the measured page-budget shrinkage. AUTHORED, NOT EXECUTED
// (the composed batch runs them on Main's build resource). All reads/writes
// go through the REAL original stores on a file-backed schema-46 database
// via the existing RB3 test bed — no mirrors of constants as proof.
import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime
import FloeTools
@testable import FloeAndroidCore

final class GoalCoreDetailReadTests: XCTestCase {

    private func makeBundle(name: String = #function) async throws -> RB3TestBed.DomainBundle {
        let stores = try await RB3TestBed.stores(name: name)
        return RB3TestBed.makeDomain(stores: stores, lifecycle: nil)
    }

    // MARK: - UTF-8 prefix body correction (Main integrity review)

    /// Both bounding helpers must return a VALID UTF-8 prefix of at most
    /// `maxBytes` bytes — never an orphan lead byte coerced into U+FFFD,
    /// never over the bound. The review's counterexamples are the anchors.
    func testUTF8PrefixHelpersWalkWholeSequences() {
        // 3-byte CJK: a 3-byte budget keeps exactly ONE whole character.
        XCTAssertEqual(ConversationTextBound.bound("中中", 3), "中")
        XCTAssertEqual(FacadeRunDomain.boundText("中中", 3), "中")
        // lead byte at the cut point must be DROPPED, not replacement-filled.
        XCTAssertEqual(ConversationTextBound.bound("aa中中", 3), "aa")
        XCTAssertEqual(FacadeRunDomain.boundText("aa中中", 3), "aa")
        // 2-byte sequence boundary.
        XCTAssertEqual(ConversationTextBound.bound("aéé", 2), "a")
        XCTAssertEqual(FacadeRunDomain.boundText("aéé", 3), "aé")
        // 4-byte emoji: budgets below one full sequence yield empty.
        XCTAssertEqual(ConversationTextBound.bound("😀x", 3), "")
        XCTAssertEqual(FacadeRunDomain.boundText("😀x", 4), "😀")
        XCTAssertEqual(FacadeRunDomain.boundText("😀x", 5), "😀x")
        // exact boundaries and ASCII are unchanged.
        XCTAssertEqual(FacadeRunDomain.boundText("abcdef", 6), "abcdef")
        XCTAssertEqual(ConversationTextBound.bound("abcdef", 5), "abcde")
        XCTAssertEqual(ConversationTextBound.bound("plain", 64), "plain")
        // zero boundary
        XCTAssertEqual(FacadeRunDomain.boundText("中", 0), "")
        // Every result: valid UTF-8 round-trip, no replacement char, size
        // within the promise.
        for probe in ["中中", "aa中中", "aéé", "😀😀😀", "ascii", "混mix😀ed"] {
            for budget in [1, 2, 3, 5, 7, 8, 13] {
                let a = ConversationTextBound.bound(probe, budget)
                let b = FacadeRunDomain.boundText(probe, budget)
                XCTAssertEqual(a, b, "both helpers must agree on \(probe)/\(budget)")
                XCTAssertFalse(a.unicodeScalars.contains { $0 == "\u{FFFD}" }, a)
                XCTAssertLessThanOrEqual(a.utf8.count, budget, a)
                // A truncated prefix must also be a PREFIX of the original.
                XCTAssertTrue(probe.hasPrefix(a) || a.isEmpty, a)
            }
        }
    }

    // MARK: - detail query grammar (closed, mixed-argument refusals)

    private func object(_ pairs: [String: SettingsDomainV1.JSONValue]) -> SettingsDomainV1.JSONValue {
        .object(pairs)
    }

    func testDetailQueryGrammarIsClosed() throws {
        // Legacy absent/empty payload => nil (byte-identical legacy path).
        XCTAssertNil(try ConversationDetailQuery.parse(nil))
        XCTAssertNil(try ConversationDetailQuery.parse(.object([:])))
        XCTAssertNil(try ConversationDetailQuery.parse(.object(["anythingElse": .boolean(true)])))
        // Valid first page.
        let first = try ConversationDetailQuery.parse(.object([
            "detail": .object(["kind": .string("goal")]),
        ]))
        XCTAssertEqual(first?.kind, .goal)
        XCTAssertEqual(first?.offset, 0)
        XCTAssertEqual(first?.maxBytes, ConversationDetailQuery.defaultMaxBytes)
        // Unknown member / wrong kind / malformed identities refuse.
        XCTAssertThrowsError(try ConversationDetailQuery.parse(.object([
            "detail": .object(["kind": .string("goal"), "path": .string("/tmp/x")]),
        ])))
        XCTAssertThrowsError(try ConversationDetailQuery.parse(.object([
            "detail": .object(["kind": .string("unknownKind")]),
        ])))
        XCTAssertThrowsError(try ConversationDetailQuery.parse(.object([
            "detail": .object(["kind": .string("goal"), "id": .string("not-a-uuid")]),
        ])))
        XCTAssertThrowsError(try ConversationDetailQuery.parse(.object([
            "detail": .object(["kind": .string("goal"), "offset": .integer(-1)]),
        ])))
        XCTAssertThrowsError(try ConversationDetailQuery.parse(.object([
            "detail": .object(["kind": .string("plan"), "maxBytes": .integer(0)]),
        ])))
        XCTAssertThrowsError(try ConversationDetailQuery.parse(.object([
            "detail": .object(["kind": .string("plan"),
                               "maxBytes": .integer(40_000)]),
        ])))
        // Mixed legacy arguments: continuation offset without id+digest.
        XCTAssertThrowsError(try ConversationDetailQuery.parse(.object([
            "detail": .object(["kind": .string("goal"), "offset": .integer(64)]),
        ])))
        XCTAssertThrowsError(try ConversationDetailQuery.parse(.object([
            "detail": .object(["kind": .string("goal"),
                               "offset": .integer(64),
                               "id": .string(UUID().uuidString)]),
        ])))
        // digest without id.
        XCTAssertThrowsError(try ConversationDetailQuery.parse(.object([
            "detail": .object(["kind": .string("goal"),
                               "digest": .string(String(repeating: "a", count: 64))]),
        ])))
        // malformed digest hex.
        let id = UUID()
        XCTAssertThrowsError(try ConversationDetailQuery.parse(.object([
            "detail": .object(["kind": .string("goal"),
                               "id": .string(id.uuidString),
                               "offset": .integer(4),
                               "digest": .string("zzzz")]),
        ])))
        // Valid continuation parses.
        let continuation = try XCTUnwrap(try ConversationDetailQuery.parse(.object([
            "detail": .object(["kind": .string("goal"),
                               "id": .string(id.uuidString),
                               "offset": .integer(4),
                               "digest": .string(String(repeating: "a", count: 64))]),
        ])))
        XCTAssertEqual(continuation.offset, 4)
    }

    // MARK: - goal/plan detail paging over the real durable rows

    func testPresentDetailArgumentsRequireTheirDeclaredTypes() throws {
        let invalid: [(String, SettingsDomainV1.JSONValue)] = [
            ("id", .integer(1)), ("id", .null), ("id", .boolean(true)),
            ("offset", .string("4")), ("offset", .fractional(4)),
            ("offset", .null), ("offset", .boolean(false)),
            ("digest", .integer(1)), ("digest", .null),
            ("digest", .string(String(repeating: "١", count: 64))),
            ("maxBytes", .string("48")), ("maxBytes", .fractional(48)),
            ("maxBytes", .null),
        ]
        for (key, value) in invalid {
            XCTAssertThrowsError(try ConversationDetailQuery.parse(.object([
                "detail": .object(["kind": .string("goal"), key: value]),
            ])), "Provided \(key) must not silently become its default")
        }
        XCTAssertThrowsError(try ConversationDetailQuery.parse(.object([
            "detail": .object(["kind": .string("goal")]),
            "cursor": .integer(1),
        ])))
        let normalized = try ConversationDetailQuery.parse(.object([
            "detail": .object([
                "kind": .string("goal"), "id": .string(UUID().uuidString),
                "digest": .string(String(repeating: "A", count: 64)),
            ]),
        ]))
        XCTAssertEqual(normalized?.digest, String(repeating: "a", count: 64))
    }

    private func seedCJKGoal(conversationID: UUID, stores: RB3TestBed.Stores)
        async throws -> ConversationGoal {
        let goal = ConversationGoal(
            conversationID: conversationID,
            objective: "审计目标😀 with emoji and \"quotes\" and emoji 😀 to grow the row",
            acceptanceCriteria: [
                GoalCriterion(text: "准则一：所有字节必须有效", isSatisfied: true,
                              evidenceIDs: [UUID()]),
                GoalCriterion(text: "criterion deux avec accents ééé",
                              requiresUserConfirmation: true),
            ],
            steps: [
                GoalStep(title: "Advance goal", detail: "推进：步骤细节😀",
                         status: .inProgress, order: 0),
            ],
            status: .verifying)
        var stored = goal
        stored.revision = 3
        try await stores.intelligence.saveGoal(stored)
        return stored
    }

    func testGoalDetailPagesReassembleCanonicalJSONAndProveIdentity() async throws {
        let bundle = try await makeBundle()
        let record = try await RB3TestBed.seedOrdinary(bundle.stores, title: "detail")
        let goal = try await seedCJKGoal(conversationID: record.id, stores: bundle.stores)
        // The detail wire renders the ORIGINAL PERSISTED row: the store
        // normalizes persisted timestamps (whole-second ISO-8601), so the
        // expected canonical bytes come from the row actually read back —
        // never from the pre-save local model.
        let stored = try await unwrapAsync(await bundle.stores.intelligence.goal(id: goal.id))

        // First page, small preference: the pager returns WHOLE sequences,
        // an exact digest, and the REAL action-proof identity.
        let first = try await bundle.domain.conversationDetail(
            conversationID: record.id,
            query: ConversationDetailQuery(kind: .goal, id: goal.id, offset: 0,
                                           digest: nil, maxBytes: 48))
        XCTAssertEqual(first.id, goal.id)
        XCTAssertEqual(first.revision, 3)
        XCTAssertEqual(first.status, "verifying")
        XCTAssertEqual(first.revisionResourceID, "goal.\(goal.id.uuidString)")
        XCTAssertEqual(first.revisionVersion, "rev:3")
        XCTAssertEqual(first.encoding, "json-utf8")
        XCTAssertEqual(first.offset, 0)
        XCTAssertGreaterThan(first.totalBytes, 48) // proves paging is needed
        XCTAssertGreaterThan(first.nextOffset, first.offset, "cursor must progress")
        XCTAssertLessThanOrEqual(first.content.utf8.count, 48)
        XCTAssertTrue(first.truncated)

        // Walk the cursor to completion; byte-for-byte reassembly equals
        // the canonical JSON (the SAME digest the continuation must echo).
        var assembled = Data(first.content.utf8)
        var page = first
        var guardCount = 0
        while page.nextOffset < page.totalBytes {
            guardCount += 1
            XCTAssertLessThan(guardCount, 200, "runaway paging")
            page = try await bundle.domain.conversationDetail(
                conversationID: record.id,
                query: ConversationDetailQuery(kind: .goal, id: goal.id,
                                               offset: page.nextOffset,
                                               digest: first.digest, maxBytes: 48))
            XCTAssertEqual(page.digest, first.digest)
            XCTAssertEqual(page.offset, assembled.count, "cursor must be contiguous")
            XCTAssertGreaterThan(page.nextOffset, page.offset, "every page progresses")
            assembled.append(contentsOf: page.content.utf8)
        }
        XCTAssertFalse(page.truncated)
        let canonical = try FacadeConversationDomain.canonicalDetailJSON(stored)
        XCTAssertEqual(assembled, canonical, "chunk reassembly must be byte-exact")
        XCTAssertEqual(first.totalBytes, canonical.count)
        XCTAssertEqual(first.digest, FloeDigest.sha256Hex(canonical),
                       "the digest binds the canonical bytes")

        // The goal row never moved because of READS (detail is a pure read).
        let after = try await bundle.stores.intelligence.goal(id: goal.id)
        XCTAssertEqual(after?.revision, 3)
        XCTAssertEqual(try XCTUnwrap(after).updatedAt,
                       stored.updatedAt,
                       "reads return the exact persisted row (no renormalization)")
    }

    func testRealDetailChunksPreserveExactMultibyteScalarEnds() async throws {
        let bundle = try await makeBundle()
        let record = try await RB3TestBed.seedOrdinary(bundle.stores, title: "scalar ends")
        let goal = try await seedCJKGoal(conversationID: record.id, stores: bundle.stores)
        let stored = try await bundle.stores.intelligence.goal(id: goal.id)
        let canonical = try FacadeConversationDomain.canonicalDetailJSON(XCTUnwrap(stored))
        let digest = FloeDigest.sha256Hex(canonical)
        for scalar in ["é", "😀", "审"] {
            let range = try XCTUnwrap(canonical.range(of: Data(scalar.utf8)))
            let start = range.lowerBound
            let page = try await bundle.domain.conversationDetail(
                conversationID: record.id,
                query: ConversationDetailQuery(kind: .goal, id: goal.id, offset: start,
                                               digest: digest, maxBytes: scalar.utf8.count))
            XCTAssertEqual(page.content, scalar)
            XCTAssertEqual(page.nextOffset, range.upperBound)
            XCTAssertEqual(Data(page.content.utf8), canonical[range])
            XCTAssertFalse(page.content.contains("\u{FFFD}"))
            do {
                _ = try await bundle.domain.conversationDetail(
                    conversationID: record.id,
                    query: ConversationDetailQuery(kind: .goal, id: goal.id, offset: start,
                                                   digest: digest, maxBytes: scalar.utf8.count - 1))
                XCTFail("A preference smaller than one scalar must refuse rather than stall or corrupt")
            } catch let error as ConversationDomainError {
                XCTAssertEqual(error, .payloadTooLarge(maxBytes: scalar.utf8.count - 1))
            }
        }
    }

    func testDetailStaleDigestForeignAndMidByteBoundaryRefuse() async throws {
        let bundle = try await makeBundle()
        let mine = try await RB3TestBed.seedOrdinary(bundle.stores, title: "mine")
        let theirs = try await RB3TestBed.seedOrdinary(bundle.stores, title: "theirs")
        let goal = try await seedCJKGoal(conversationID: mine.id, stores: bundle.stores)
        let first = try await bundle.domain.conversationDetail(
            conversationID: mine.id,
            query: ConversationDetailQuery(kind: .goal, id: goal.id, offset: 0,
                                           digest: nil, maxBytes: 48))
        // Stale digest after a real durable advance (goal.confirm CAS shape:
        // the SAME revision+row advancing).
        var advanced = goal
        advanced.status = .completed
        advanced.updatedAt = Date(timeInterval: 5, since: goal.updatedAt)
        let saved = try await bundle.stores.intelligence
            .saveGoalIfRevisionMatches(advanced, expectedRevision: 3)
        XCTAssertTrue(saved)
        do {
            _ = try await bundle.domain.conversationDetail(
                conversationID: mine.id,
                query: ConversationDetailQuery(kind: .goal, id: goal.id,
                                               offset: 12, digest: first.digest,
                                               maxBytes: 48))
            XCTFail("stale digest must refuse")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error, .staleRevision)
        }
        // Foreign goal identity answers EXACTLY like a nonexistent one
        // (no cross-conversation existence leak).
        let foreign = try await bundle.stores.intelligence.goal(id: goal.id)
        XCTAssertNotNil(foreign) // it exists — yet addressed from another conversation:
        do {
            _ = try await bundle.domain.conversationDetail(
                conversationID: theirs.id,
                query: ConversationDetailQuery(kind: .goal, id: goal.id, offset: 0,
                                               digest: nil, maxBytes: 48))
            XCTFail("foreign id must refuse")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error, .notFound)
        }
        do {
            _ = try await bundle.domain.conversationDetail(
                conversationID: mine.id,
                query: ConversationDetailQuery(kind: .goal, id: UUID(), offset: 0,
                                               digest: nil, maxBytes: 48))
            XCTFail("nonexistent id must refuse")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error, .notFound) // SAME error as the foreign case
        }
        // Mid-sequence offset boundary is a typed envelope refusal: find a
        // real continuation byte position from the CURRENT persisted bytes.
        // The earlier advance legitimately moved the row, so the probe must
        // carry the CURRENT digest — otherwise the stale-digest rule (which
        // is decided first) would mask the boundary refusal.
        let current = try await unwrapAsync(await bundle.stores.intelligence.goal(id: goal.id))
        let canonical = try FacadeConversationDomain.canonicalDetailJSON(current)
        let currentDigest = FloeDigest.sha256Hex(canonical)
        let bytes = Array(canonical)
        var mid = -1
        for index in 1..<bytes.count where (bytes[index] & 0xC0) == 0x80 {
            mid = index; break
        }
        XCTAssertGreaterThan(mid, 0)
        do {
            _ = try await bundle.domain.conversationDetail(
                conversationID: mine.id,
                query: ConversationDetailQuery(kind: .goal, id: goal.id, offset: mid,
                                               digest: currentDigest, maxBytes: 48))
            XCTFail("mid-sequence offset must refuse")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error, .invalidEnvelope("detailOffsetBoundary"))
        }
        // kind=plan on a conversation without plans: honest typed notFound
        do {
            _ = try await bundle.domain.conversationDetail(
                conversationID: mine.id,
                query: ConversationDetailQuery(kind: .plan, id: nil, offset: 0,
                                               digest: nil, maxBytes: 48))
            XCTFail("absent plan must refuse")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testPlanDetailCarriesActionIdentityAndSummaryAvailability() async throws {
        let bundle = try await makeBundle()
        let record = try await RB3TestBed.seedOrdinary(bundle.stores, title: "plan")
        let plan = PlanDraft(
            conversationID: record.id,
            revision: 2,
            status: .ready,
            title: "季度计划",
            summary: "summary",
            sections: [PlanSection(title: "收集", body: "内容", order: 0)],
            acceptanceCriteria: [PlanCriterion(text: "c", verification: "v")],
            executionRecommendation: .goal,
            digest: "digest-abc")
        try await bundle.stores.intelligence.savePlanRevision(plan)

        let page = try await bundle.domain.conversationDetail(
            conversationID: record.id,
            query: ConversationDetailQuery(kind: .plan, id: plan.id, offset: 0,
                                           digest: nil, maxBytes: 4_096))
        XCTAssertEqual(page.revision, 2)
        XCTAssertEqual(page.planDigest, "digest-abc")
        XCTAssertEqual(page.isDecisionComplete, true)
        XCTAssertEqual(page.status, "ready")

        // Summary availability flags distinguish projected vs absent (this
        // conversation has a plan row but NO goal row).
        let withRows = try await bundle.domain.get(conversationID: record.id)
        XCTAssertEqual(withRows.planAvailability, "projected")
        XCTAssertNotNil(withRows.plan)
        XCTAssertEqual(withRows.goalAvailability, "absent")
        XCTAssertNil(withRows.goal)
    }

    func testFittingDetailPageKeepsMeasuredBudgetAndProgress() async throws {
        let bundle = try await makeBundle()
        let record = try await RB3TestBed.seedOrdinary(bundle.stores, title: "budget")
        _ = try await seedCJKGoal(conversationID: record.id, stores: bundle.stores)
        let base = ["conversationID": record.id.uuidString,
                    "revision": "r", "title": "budget"]
        let canonical = Data("{ \"data\": \"中😀\" }".utf8)
        let wire = ConversationDetailWire(
            kind: "goal", id: UUID(), status: "verifying", revision: 1,
            digest: "d", encoding: "json-utf8",
            offset: 0, nextOffset: canonical.count, totalBytes: canonical.count,
            truncated: false,
            content: String(decoding: canonical, as: UTF8.self),
            revisionResourceID: nil, revisionVersion: nil,
            planDigest: nil, isDecisionComplete: nil)
        let fitted = try bundle.domain.fittingDetailPage(baseObject: base, wire: wire)
        XCTAssertLessThanOrEqual(
            ConversationWireBudget.encodedObjectBytes(["detail": fitted.wireObject]),
            SettingsDomainV1.pageBudgetBytes)
        // The (possibly shrunk) content stays a valid UTF-8 prefix with no
        // replacement characters, and the cursor never stalls while bytes
        // remain.
        XCTAssertFalse(fitted.content.unicodeScalars.contains { $0 == "\u{FFFD}" })
        XCTAssertTrue(fitted.nextOffset > fitted.offset || fitted.nextOffset == fitted.totalBytes,
                      "never a zero-progress cursor while more bytes remain")
    }

    func testForcedPageShrinkRetainsAnExactOriginalUTF8Prefix() async throws {
        let bundle = try await makeBundle()
        let canonical = try JSONSerialization.data(
            withJSONObject: ["data": String(repeating: "中😀\"\\\n", count: 8_000)],
            options: [.sortedKeys])
        let content = ConversationTextBound.bound(String(decoding: canonical, as: UTF8.self), 32_768)
        let padding = String(repeating: "b", count: 32_000)
        let wire = ConversationDetailWire(
            kind: "goal", id: UUID(), status: "verifying", revision: 1,
            digest: FloeDigest.sha256Hex(canonical), encoding: "json-utf8",
            offset: 0, nextOffset: content.utf8.count, totalBytes: canonical.count,
            truncated: true, content: content,
            revisionResourceID: nil, revisionVersion: nil,
            planDigest: nil, isDecisionComplete: nil)
        XCTAssertGreaterThan(ConversationWireBudget.encodedObjectBytes([
            "pad": padding, "detail": wire.wireObject,
        ]), SettingsDomainV1.pageBudgetBytes, "The test must actually force the shrink branch")
        let fitted = try bundle.domain.fittingDetailPage(baseObject: ["pad": padding], wire: wire)
        XCTAssertLessThan(fitted.nextOffset, wire.nextOffset)
        XCTAssertGreaterThan(fitted.nextOffset, 0)
        XCTAssertEqual(Data(fitted.content.utf8), canonical.prefix(fitted.nextOffset))
        XCTAssertEqual(fitted.content.utf8.count, fitted.nextOffset)
        XCTAssertFalse(fitted.content.contains("\u{FFFD}"))
        XCTAssertLessThanOrEqual(ConversationWireBudget.encodedObjectBytes([
            "pad": padding, "detail": fitted.wireObject,
        ]), SettingsDomainV1.pageBudgetBytes)
    }

    func testOriginalChecklistToolsReadThroughSameStoreWithoutGoalPromotion() async throws {
        let bundle = try await makeBundle()
        let record = try await RB3TestBed.seedOrdinary(bundle.stores, title: "checklist")
        let runID = UUID()
        try await RB3TestBed.seedRun(bundle.stores.database, conversationID: record.id,
                                    id: runID, state: "running")
        let store = TaskChecklistStore(database: bundle.stores.database)
        let registry = ToolRunnerRegistry()
        registerTaskChecklistTools(store: store, registry: registry)
        XCTAssertNotNil(registry.runner(named: TaskReadPlanTool.name))
        XCTAssertNotNil(registry.runner(named: TaskUpdatePlanTool.name))
        let update = TaskChecklistUpdate(title: "真实步骤😀", steps: [
            .init(id: "read", title: "读取", status: .completed, evidence: ["tool:read"]),
            .init(id: "write", title: "写入", status: .cancelled),
        ])
        let context = ToolContext(runID: runID, toolCallID: "same-tool-call",
                                  cancellation: CancellationToken(), conversationID: record.id)
        let tool = TaskUpdatePlanTool(store: store)
        _ = try await tool.execute(update, context: context)
        _ = try await tool.execute(update, context: context) // same operation is idempotent
        let stored = try await store.latest(conversationID: record.id)
        let checklist = try XCTUnwrap(stored)
        XCTAssertEqual(checklist.revision, 1)
        XCTAssertEqual(checklist.completedCount, 1)
        XCTAssertEqual(checklist.cancelledCount, 1)
        let parsed = try XCTUnwrap(try ConversationDetailQuery.parse(.object([
            "detail": .object(["kind": .string("checklist")]),
        ])))
        let detail = try await bundle.domain.conversationDetail(conversationID: record.id, query: parsed)
        XCTAssertEqual(detail.id, runID)
        XCTAssertEqual(detail.revision, 1)
        XCTAssertEqual(detail.status, "finished") // cancelled is not reported completed
        XCTAssertNil(detail.revisionResourceID)
        XCTAssertNil(detail.revisionVersion)
        let canonical = try FacadeConversationDomain.canonicalDetailJSON(checklist)
        XCTAssertEqual(Data(detail.content.utf8), canonical)
        XCTAssertEqual(detail.digest, FloeDigest.sha256Hex(canonical))
        let goals = try await bundle.stores.intelligence.goals(conversationID: record.id)
        XCTAssertTrue(goals.isEmpty, "Progress is not authorization to create or complete a Goal")
    }

    func testChecklistDetailRejectsChangedRevisionAndForeignOwner() async throws {
        let bundle = try await makeBundle()
        let mine = try await RB3TestBed.seedOrdinary(bundle.stores, title: "mine")
        let other = try await RB3TestBed.seedOrdinary(bundle.stores, title: "other")
        let runID = UUID()
        try await RB3TestBed.seedRun(bundle.stores.database, conversationID: mine.id,
                                    id: runID, state: "running")
        let store = TaskChecklistStore(database: bundle.stores.database)
        _ = try await store.update(.init(title: "work", steps: [
            .init(id: "one", title: "first", status: .inProgress),
        ]), runID: runID, operationID: "first")
        let first = try await bundle.domain.conversationDetail(
            conversationID: mine.id,
            query: .init(kind: .checklist, id: nil, offset: 0, digest: nil, maxBytes: 48))
        _ = try await store.update(.init(expectedRevision: 1, title: "work", steps: [
            .init(id: "one", title: "first", status: .completed, evidence: ["tool:result"]),
        ]), runID: runID, operationID: "second")
        do {
            _ = try await bundle.domain.conversationDetail(
                conversationID: mine.id,
                query: .init(kind: .checklist, id: runID, offset: first.nextOffset,
                             digest: first.digest, maxBytes: 48))
            XCTFail("A newer checklist revision must not join the old chunks")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error, .staleRevision)
        }
        for foreign in [runID, UUID()] {
            do {
                _ = try await bundle.domain.conversationDetail(
                    conversationID: other.id,
                    query: .init(kind: .checklist, id: foreign, offset: 0, digest: nil, maxBytes: 48))
                XCTFail("Foreign and missing checklists must refuse identically")
            } catch let error as ConversationDomainError {
                XCTAssertEqual(error, .notFound)
            }
        }
    }
}

