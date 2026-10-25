// SPDX-License-Identifier: MPL-2.0
//
// PROPOSED regression source (authored, NOT compiled or run — Main batches
// all checks per the G04R2 source-first policy; integrate into the existing
// FloeAndroidCoreTests cohort).
//
// Queue-content repair (job-e577557dec254fc9) native-side coverage:
//  1. the CLOSED detail grammar now admits kind "pendingInput" and still
//     refuses unknown members;
//  2. PendingUserInputWire carries the ORIGINAL executionMode vocabulary +
//     the real contentBytes length (browser-handoff presentation truth);
//  3. PendingInputDetailProjection encodes the full editable body and the
//     exact CAS vocabulary `run.input.edit` proves (pendingInput.<UPPER
//     uuid> / updatedAt-derived inputVersion), deterministically byte-exact
//     under sorted-key canonical encoding (stable digest continuation).
// Domain-level gates (conversationDetail pendingInput resolution, snapshot
// previewComplete/contentBytes, two-consecutive-complete-page retirement is
// an App-side rule) run through the existing RuntimeFacade* fixtures when
// Main integrates the batch.

import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeModels

final class PendingInputQueueContentWireTests: XCTestCase {

    private func queuedRow(content: String, executionMode: String = "agent") -> PendingUserInput {
        PendingUserInput(
            conversationID: UUID(),
            content: content,
            mode: .queue,
            status: .queued,
            executionMode: executionMode
        )
    }

    // MARK: detail grammar

    func testPendingInputIsAClosedAdmittedDetailKind() throws {
        // First page with an explicit identity (the shape the App editor uses).
        let inputID = UUID()
        let first = try ConversationDetailQuery.parse(.object([
            "detail": .object([
                "kind": .string("pendingInput"),
                "id": .string(inputID.uuidString),
                "maxBytes": .integer(32_768),
            ]),
        ]))
        XCTAssertEqual(first?.kind, .pendingInput)
        XCTAssertEqual(first?.id, inputID)
        // Continuation still REQUIRES id + exact digest (unchanged rule).
        XCTAssertThrowsError(try ConversationDetailQuery.parse(.object([
            "detail": .object(["kind": .string("pendingInput"), "offset": .integer(10)]),
        ])))
        // Unknown members are still typed envelope refusals.
        XCTAssertThrowsError(try ConversationDetailQuery.parse(.object([
            "detail": .object(["kind": .string("pendingInput"), "path": .string("/tmp/x")]),
        ])))
    }

    // MARK: conversation-page wire

    func testConversationWireProjectsExecutionModeAndRealByteLength() {
        let body = "队列正文 ✓ 浏览器"
        let row = queuedRow(content: body, executionMode: "browserHandoff")
        let object = PendingUserInputWire(input: row).wireObject
        XCTAssertEqual(object["executionMode"] as? String, "browserHandoff")
        XCTAssertEqual(object["contentBytes"] as? Int, body.utf8.count)
        XCTAssertNil(object["content"]) // metadata lane: NO inline body ever
    }

    // MARK: detail projection (the full editable body lane)

    func testDetailProjectionCarriesBodyAndExactEditCASVocabulary() throws {
        let updatedAt = Date(timeIntervalSince1970: 1_761_000_000)
        let row = PendingUserInput(
            conversationID: UUID(),
            content: "完整可编辑正文（含 emoji 🚗 与多语言）",
            mode: .queue,
            status: .queued,
            executionMode: "agent",
            updatedAt: updatedAt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(PendingInputDetailProjection(input: row))
        let round = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(round["content"] as? String, row.content)
        XCTAssertEqual(round["status"] as? String, "queued")
        XCTAssertEqual(round["mode"] as? String, "queue")
        XCTAssertEqual(round["executionMode"] as? String, "agent")
        XCTAssertEqual(round["id"] as? String, row.id.uuidString)
        XCTAssertEqual(round["inputVersion"] as? String,
                       RunWireRevision.inputVersion(updatedAt: updatedAt))
        XCTAssertEqual(round["contentUTF8Bytes"] as? Int, row.content.utf8.count)
        XCTAssertNil(round["consumedRunID"]) // nil optionals are absent, not ""
        // Deterministic canonical bytes = a stable digest continuation proof.
        let again = try encoder.encode(PendingInputDetailProjection(input: row))
        XCTAssertEqual(data, again)
        // The resource identity is the SAME string `run.input.edit` proves.
        XCTAssertEqual(RunWireRevision.pendingInputResourceID(row.id),
                       "pendingInput.\(row.id.uuidString)")
    }
}
