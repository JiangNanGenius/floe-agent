// SPDX-License-Identifier: MPL-2.0
//
// RB-3 content authority — bounded handle binding + dual-scope content.read
// tests over the REAL original stores (private source candidate; AUTHORED,
// NOT executed by this package).
//
// Proves: owner binding (foreign conversation / expired generation / unknown
// handle denied with the SAME typed notFound), durable-row authority
// re-derivation (deleted row's handle dies with it), P0-helper inline-vs-
// handle decisions (no arbitrary caps), the shared-reader saturation path
// failing CLOSED (never a truncated inline labelled complete), the
// applicationConfiguration/conversations label branch, and the rule that
// this lane holds NO content bytes (bytes live only in the shared reader;
// the index is metadata-bounded).

import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime
@testable import FloeAndroidCore

final class RuntimeFacadeConversationContentTests: XCTestCase {

    private func giantText(approxBytes: Int) -> String {
        var text = ""
        while text.utf8.count < approxBytes {
            text += "段落\u{1F600} \"quoted\" \\ backslash 漢字 \n"
        }
        return text
    }

    private func handleOnFirstPage(_ bundle: RB3TestBed.DomainBundle,
                                   conversationID: UUID) async throws -> String {
        let page = try await bundle.domain.messagePage(conversationID: conversationID,
                                                       payload: nil)
        return try XCTUnwrap(page.rows.first?.contentHandle)
    }

    func testOversizeRowUsesOwnedHandleAndIndexHoldsNoBytes() async throws {
        let stores = try await RB3TestBed.stores()
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: nil)
        let record = try await RB3TestBed.seedOrdinary(stores, title: "big")
        let text = giantText(approxBytes: 120_000)
        try await RB3TestBed.seedMessage(stores, conversationID: record.id, content: text)

        let handle = try await handleOnFirstPage(bundle, conversationID: record.id)
        XCTAssertTrue(handle.hasPrefix("chunk:v1:"),
                      "handle comes from the shared reader's opaque namespace")
        // Bytes live ONLY inside the shared reader double; the authority
        // index kept metadata (one binding) and no second copy.
        let retained = await bundle.publisher.retainedBytes()
        XCTAssertEqual(retained, Data(text.utf8).count)
        let bindings = await bundle.content.bindingCount()
        XCTAssertEqual(bindings, 1)
    }

    func testByteExactReassemblyThroughSliceBudget() async throws {
        let stores = try await RB3TestBed.stores()
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: nil)
        let record = try await RB3TestBed.seedOrdinary(stores, title: "slices")
        let text = giantText(approxBytes: 60_000)
        try await RB3TestBed.seedMessage(stores, conversationID: record.id, content: text)
        let handle = try await handleOnFirstPage(bundle, conversationID: record.id)

        var offset = 0
        var assembled = Data()
        var lastReply: ConversationContentSliceReply?
        var iterations = 0
        while true {
            let reply = try await bundle.domain.readContent(
                conversationID: record.id,
                payload: .object([
                    "handle": .string(handle),
                    "offset": .integer(Int64(offset)),
                    "maxBytes": .integer(1_024),
                ]))
            lastReply = reply
            // The FULL encoded slice response must fit the normal 48 KiB
            // page through the accepted P0 helper — measured, not assumed.
            XCTAssertLessThanOrEqual(
                ConversationWireBudget.encodedObjectBytes(reply.wireObject),
                SettingsDomainV1.pageBudgetBytes)
            XCTAssertGreaterThanOrEqual(reply.chunk.chunk.utf8.count, 1,
                                        "non-terminal slices must make progress")
            assembled.append(Data(reply.chunk.chunk.utf8))
            guard let next = reply.chunk.nextOffset else {
                XCTAssertTrue(reply.chunk.done)
                break
            }
            XCTAssertGreaterThan(next, offset, "scalar-aligned cursor advances")
            offset = next
            iterations += 1
            XCTAssertLessThan(iterations, 400)
        }
        XCTAssertEqual(assembled, Data(text.utf8), "byte-exact reassembly")
        XCTAssertEqual(lastReply?.chunk.totalBytes ?? -1, text.utf8.count)
        XCTAssertEqual(lastReply?.contentDigest,
                       ConversationContentBinding.digest(of: text),
                       "digest is the staged content's real P0 canonical token")
    }

    func testForeignConversationAndUnknownHandleAreIdenticalNotFound() async throws {
        let stores = try await RB3TestBed.stores()
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: nil)
        let owner = try await RB3TestBed.seedOrdinary(stores, title: "owner")
        let intruder = try await RB3TestBed.seedOrdinary(stores, title: "intruder")
        try await RB3TestBed.seedMessage(stores, conversationID: owner.id,
                                         content: giantText(approxBytes: 70_000))
        let handle = try await handleOnFirstPage(bundle, conversationID: owner.id)

        func expectNotFound(_ block: () async throws -> ConversationContentSliceReply,
                             _ label: String) async {
            do {
                _ = try await block()
                XCTFail("\(label) must be denied")
            } catch let error as ConversationDomainError {
                XCTAssertEqual(error.wireCode, "notFound", label)
            } catch {
                // Qualifier repair (2026-10-19): exhaustive catch (Swift 6);
                // any other error domain is itself a failure.
                XCTFail("\(label) must surface ConversationDomainError, got \(error)")
            }
        }
        await expectNotFound({
            try await bundle.domain.readContent(
                conversationID: intruder.id,
                payload: .object(["handle": .string(handle),
                                  "offset": .integer(0), "maxBytes": .integer(128)]))
        }, "foreign conversation owner")
        await expectNotFound({
            try await bundle.domain.readContent(
                conversationID: owner.id,
                payload: .object(["handle": .string("chunk:v1:" + String(repeating: "f", count: 32)),
                                  "offset": .integer(0), "maxBytes": .integer(128)]))
        }, "unknown handle")
    }

    func testDeletedConversationHandleDiesAndOtherRowsSurvive() async throws {
        // NOTE: this test uses the UNBOUND lifecycle refusal for setup, then
        // proves handle release through the explicit release path exercised
        // by RuntimeFacadeConversationDeleteTests (bound lifecycle). Here we
        // verify the ROW-AUTHORITY half: the bound message disappears from
        // the durable store while the handle token still exists in the
        // reader (worst case), and the next read must deny anyway because
        // authority is re-derived from the ORIGINAL rows every time.
        let stores = try await RB3TestBed.stores()
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: nil)
        let record = try await RB3TestBed.seedOrdinary(stores, title: "row authority")
        let other = try await RB3TestBed.seedOrdinary(stores, title: "other")
        try await RB3TestBed.seedMessage(stores, conversationID: record.id,
                                         content: giantText(approxBytes: 70_000),
                                         id: RB3TestBed.deterministicUUID(1))
        let survivor = try await RB3TestBed.seedMessage(
            stores, conversationID: other.id,
            content: giantText(approxBytes: 70_000))
        let doomedMessage = try await stores.conversations
            .messages(conversationID: record.id)
        let handle = try await handleOnFirstPage(bundle, conversationID: record.id)
        _ = doomedMessage

        // Raw-delete just the message ROW (simulates its durable removal by
        // any owner path). The handle token itself is unknown to this check;
        // authority must consult the row, not the bytes.
        try await stores.database.writer { db in
            try db.execute(sql: "DELETE FROM messages WHERE conversation_id = ?",
                           arguments: [record.id.uuidString])
        }
        do {
            _ = try await bundle.domain.readContent(
                conversationID: record.id,
                payload: .object(["handle": .string(handle),
                                  "offset": .integer(0), "maxBytes": .integer(64)]))
            XCTFail("handle bound to a deleted row must be denied")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "notFound")
        }
        // The other conversation's staged bytes are untouched (release is
        // conversation-scoped).
        let survivorPage = try await bundle.domain.messagePage(
            conversationID: other.id, payload: nil)
        XCTAssertEqual(survivorPage.rows.first?.messageID, survivor.id)
    }

    func testGenerationRetirementDeniesOldHandles() async throws {
        let stores = try await RB3TestBed.stores()
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: nil, hostEpoch: 7)
        let record = try await RB3TestBed.seedOrdinary(stores, title: "epoch")
        try await RB3TestBed.seedMessage(stores, conversationID: record.id,
                                         content: giantText(approxBytes: 70_000))
        let handle = try await handleOnFirstPage(bundle, conversationID: record.id)

        // A NEW generation over the same durable rows knows no old handle:
        // typed notFound, no revival, no re-staging from bytes.
        let nextBundle = RB3TestBed.makeDomain(stores: stores, lifecycle: nil, hostEpoch: 8)
        do {
            _ = try await nextBundle.domain.readContent(
                conversationID: record.id,
                payload: .object(["handle": .string(handle),
                                  "offset": .integer(0), "maxBytes": .integer(64)]))
            XCTFail("old-generation handle must not survive into a new epoch")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "notFound")
        }
        // The new generation CAN re-publish from the durable row.
        let freshHandle = try await handleOnFirstPage(nextBundle, conversationID: record.id)
        XCTAssertNotEqual(freshHandle, handle)
    }

    func testSaturatedSharedReaderFailsClosedNeverTruncates() async throws {
        let stores = try await RB3TestBed.stores()
        // Publisher with ZERO retained bytes allowed: every oversize row
        // must make the PAGE refuse typed, inline with a false completeness
        // label is structurally impossible.
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: nil,
                                           publisherMaxTotalBytes: 0)
        let record = try await RB3TestBed.seedOrdinary(stores, title: "saturation")
        try await RB3TestBed.seedMessage(stores, conversationID: record.id,
                                         content: giantText(approxBytes: 60_000))
        do {
            _ = try await bundle.domain.messagePage(conversationID: record.id, payload: nil)
            XCTFail("saturated reader must refuse the page")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "runtimeUnavailable")
            XCTAssertEqual(error.wireReason, "contentReaderSaturated")
        }
        // Small content still pages inline without touching the reader.
        let small = try await RB3TestBed.seedOrdinary(stores, title: "small ok")
        try await RB3TestBed.seedMessage(stores, conversationID: small.id, content: "plain text")
        let page = try await bundle.domain.messagePage(conversationID: small.id, payload: nil)
        XCTAssertEqual(page.rows.first?.content, "plain text")
        XCTAssertTrue(page.rows.first?.contentInlineComplete ?? false)
        XCTAssertNil(page.rows.first?.contentHandle)
    }

    func testInlineDecisionUsesCompleteEncodedResponseNotRawLengthOnly() async throws {
        // 40 KiB of characters that JSON-escape roughly 6x ("\\", "\"",
        // control bytes): RAW text fits 48 KiB, the ENCODED row does not.
        // The adapter must go to the owned handle, proving the decision is
        // made on the actual escaped encoded response (P0 helper), not on
        // a raw character/byte count.
        let stores = try await RB3TestBed.stores()
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: nil)
        let record = try await RB3TestBed.seedOrdinary(stores, title: "escaping")
        var text = ""
        while text.utf8.count < 40_000 {
            text += "\u{0001}\u{001F}\"\\\\\n"
        }
        try await RB3TestBed.seedMessage(stores, conversationID: record.id, content: text)
        let encoded = ConversationWireBudget.encodedJSONStringBytes(text)
        XCTAssertGreaterThan(text.utf8.count, SettingsDomainV1.pageBudgetBytes / 2)
        XCTAssertGreaterThan(encoded, SettingsDomainV1.pageBudgetBytes,
                              "fixture must exceed the budget only after escaping")
        let page = try await bundle.domain.messagePage(conversationID: record.id, payload: nil)
        XCTAssertNil(page.rows.first?.content)
        XCTAssertNotNil(page.rows.first?.contentHandle)
        XCTAssertFalse(page.rows.first?.contentInlineComplete ?? true)
    }

    func testConfigurationLabelBranchComposesWithoutClaimingOtherLabels() async throws {
        let stores = try await RB3TestBed.stores()
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: nil)
        let record = try await RB3TestBed.seedOrdinary(stores, title: "config label")
        try await RB3TestBed.seedMessage(stores, conversationID: record.id,
                                         content: giantText(approxBytes: 70_000))
        let handle = try await handleOnFirstPage(bundle, conversationID: record.id)

        let reply = try await bundle.domain.readContentFromConversationsLabel(
            configurationScope: "conversations",
            payload: .object(["handle": .string(handle),
                              "offset": .integer(0), "maxBytes": .integer(256)]))
        XCTAssertFalse(reply.chunk.chunk.isEmpty)

        // The SAME handler key will later carry the personalization label:
        // this lane must refuse foreign labels instead of serving them.
        do {
            _ = try await bundle.domain.readContentFromConversationsLabel(
                configurationScope: "personalization",
                payload: .object(["handle": .string(handle),
                                  "offset": .integer(0), "maxBytes": .integer(256)]))
            XCTFail("foreign configuration label must be refused, not overwritten")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "invalidEnvelope")
            XCTAssertEqual(error.wireReason, "configurationScopeMismatch")
        }
        do {
            _ = try await bundle.domain.readContentFromConversationsLabel(
                configurationScope: nil,
                payload: .object(["handle": .string(handle),
                                  "offset": .integer(0), "maxBytes": .integer(256)]))
            XCTFail("missing label cannot default into this lane")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireReason, "configurationScopeMismatch")
        }
    }

    func testContentReadPayloadClosedShape() async throws {
        let stores = try await RB3TestBed.stores()
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: nil)
        let record = try await RB3TestBed.seedOrdinary(stores, title: "shape")
        func reject(_ payload: SettingsDomainV1.JSONValue, _ reason: String) async {
            do {
                _ = try await bundle.domain.readContent(
                    conversationID: record.id, payload: payload)
                XCTFail("must reject \(reason)")
            } catch let error as ConversationDomainError {
                XCTAssertEqual(error.wireCode, "invalidEnvelope", reason)
                if let expected = error.wireReason { XCTAssertTrue(expected.hasPrefix(reason) || expected == reason, "\(expected) vs \(reason)") }
            } catch {
                // Qualifier repair (2026-10-19): exhaustive catch (Swift 6);
                // any other error domain is itself a failure.
                XCTFail("must reject \(reason) via ConversationDomainError, got \(error)")
            }
        }
        await reject(.object(["offset": .integer(0), "maxBytes": .integer(64)]),
                     "missingPayloadField:handle")
        await reject(.object(["handle": .string("x"), "maxBytes": .integer(64)]),
                     "missingPayloadField:offset")
        await reject(.object(["handle": .string(""), "offset": .integer(0),
                              "maxBytes": .integer(64)]),
                     "invalidPayloadField:handle")
        await reject(.object(["handle": .string("chunk:v1:abc"), "offset": .integer(-3),
                              "maxBytes": .integer(64)]),
                     "contentOffsetInvalid")
        await reject(.object(["handle": .string("chunk:v1:abc"), "offset": .integer(0),
                              "maxBytes": .integer(0)]),
                     "invalidPayloadField:maxBytes")
        // Above the frozen P0 chunk clamp (32_768) is refused even though
        // the RB1 draft reader bound is larger: the SMALLER real bound wins.
        await reject(.object(["handle": .string("chunk:v1:abc"), "offset": .integer(0),
                              "maxBytes": .integer(Int64(SettingsDomainV1.maximumChunkBytes + 1))]),
                     "invalidPayloadField:maxBytes")
        await reject(.object(["handle": .string("chunk:v1:abc"), "offset": .integer(0),
                              "maxBytes": .integer(64), "path": .string("/etc/passwd")]),
                     "unknownContentReadField")
    }
}


