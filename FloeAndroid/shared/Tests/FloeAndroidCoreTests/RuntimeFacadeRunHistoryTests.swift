// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import FloeModels
import FloePersistence
@testable import FloeAndroidCore

final class RuntimeFacadeRunHistoryTests: XCTestCase {
    private var fixture: RunDomainFixture!
    override func setUp() async throws { fixture = try await RunDomainFixture.make() }
    override func tearDown() async throws { await fixture?.tearDown(); fixture = nil }

    private func request(task: UUID, run: UUID, payload: [String: Any]) -> RunCommandEnvelope {
        RunCommandEnvelope(object: [
            "schema": BridgeV3.commandSchema, "scope": "taskExecution", "command": "run.events",
            "stateful": false, "correlationID": UUID().uuidString,
            "owner": ["taskID": task.uuidString, "runID": run.uuidString], "payload": payload,
        ])
    }

    private func seed() async throws -> (UUID, UUID, RunEventRecord) {
        let task = try await fixture.makeOrdinaryConversation()
        let run = UUID()
        try await fixture.runStore.saveRun(RunRecord(id: run, conversationID: task,
            state: "checkpointed", goal: "owned history fixture", startedAt: Date()))
        try await fixture.runStore.appendEvent(runID: run, kind: .notice, payloadJSON: "{\"message\":\"earlier\"}")
        let prefix = "{\"text\":\""
        let payload = prefix + String(repeating: "x", count: RunHistoryPayload.chunkBytes - prefix.utf8.count - 1)
            + "🙂" + String(repeating: "存档", count: 9_000) + "\"}"
        let row = try await fixture.runStore.appendEvent(runID: run, kind: .assistantText, payloadJSON: payload)
        return (task, run, row)
    }

    private func page(_ reply: RunDomainReply) throws -> (RunTypedPage, String?) {
        guard case .completedPage(let value, let cursor) = reply.outcome else {
            throw NSError(domain: "history-fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(reply.outcome)"])
        }
        XCTAssertLessThanOrEqual(value.pageBytes, RunDomainLimits.pageBudgetBytes)
        return (value, cursor)
    }

    private func wire(_ value: RunTypedPage) throws -> [String: Any] {
        // Exercise the actual JSON boundary; unwrap deliberately carries
        // Int64 values rather than Foundation's decoded NSNumber carrier.
        let bytes = try JSONSerialization.data(withJSONObject: FacadeRunDomain.unwrap(value.object))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    func testOversizeStoredEventHasRealEarlierCursorAndBoundedLosslessUtf8Continuation() async throws {
        let (task, run, row) = try await seed()
        let domain = fixture.makeDomain()
        let providerRequests = fixture.adapter.requestCount
        let first = try page(await domain.eventHistory(envelope: request(task: task, run: run, payload: ["limit": 100])))
        let root = try wire(first.0)
        let events = try XCTUnwrap(root["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(first.1, String(row.sequence))
        XCTAssertEqual(root["hasEarlier"] as? Bool, true)
        XCTAssertTrue(events[0]["payload"] is NSNull)
        let reference = try XCTUnwrap(events[0]["payloadReference"] as? [String: Any])
        let digest = try XCTUnwrap(reference["sha256"] as? String)
        var restored = Data()
        var offset = 0
        while offset < row.payloadJSON.utf8.count {
            let reply = await domain.eventHistory(envelope: request(task: task, run: run, payload: [
                "limit": 1, "payloadSequence": row.sequence, "payloadOffset": offset, "payloadDigest": digest,
            ]))
            let value = try page(reply)
            let object = try wire(value.0)
            let slice = try XCTUnwrap(object["payloadSlice"] as? [String: Any])
            XCTAssertEqual(slice["offset"] as? Int, restored.count)
            let encoded = try XCTUnwrap(slice["base64"] as? String)
                .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let bytes = try XCTUnwrap(Data(base64Encoded: encoded))
            if offset == 0 { XCTAssertNil(String(data: bytes, encoding: .utf8), "Fixture crosses a code point") }
            restored.append(bytes)
            if let next = slice["nextOffset"] as? Int { XCTAssertEqual(next, restored.count); offset = next }
            else { XCTAssertEqual(restored.count, row.payloadJSON.utf8.count); break }
        }
        XCTAssertTrue(String(data: restored, encoding: .utf8) == row.payloadJSON,
                      "The complete original UTF-8 payload must round trip exactly")
        let earlier = try page(await domain.eventHistory(envelope: request(task: task, run: run,
            payload: ["limit": 100, "beforeSequence": row.sequence])))
        XCTAssertNil(earlier.1)
        let state = try await fixture.runStore.run(id: run)?.state
        XCTAssertEqual(state, "checkpointed")
        XCTAssertEqual(fixture.adapter.requestCount, providerRequests)
    }

    func testSlicesRecheckOwnerDigestOffsetAndDeletionWithoutPublishingForeignRows() async throws {
        let (task, run, row) = try await seed()
        let domain = fixture.makeDomain()
        let digest = RunHistoryPayload.digest(Data(row.payloadJSON.utf8))
        let valid: [String: Any] = ["limit": 1, "payloadSequence": row.sequence,
            "payloadOffset": 0, "payloadDigest": digest]
        let foreign = try await fixture.makeOrdinaryConversation()
        let requests = [
            request(task: foreign, run: run, payload: valid),
            request(task: task, run: run, payload: valid.merging(["payloadDigest": String(repeating: "0", count: 64)]) { _, b in b }),
            request(task: task, run: run, payload: valid.merging(["payloadOffset": row.payloadJSON.utf8.count]) { _, b in b }),
            request(task: task, run: run, payload: valid.merging(["beforeSequence": row.sequence]) { _, b in b }),
        ]
        for envelope in requests {
            let reply = await domain.eventHistory(envelope: envelope)
            guard case .rejected = reply.outcome else { return XCTFail("Invalid slice must reject") }
        }
        try await fixture.conversationStore.deleteConversation(id: task)
        let deleted = await domain.eventHistory(envelope: request(task: task, run: run, payload: valid))
        guard case .rejected = deleted.outcome else { return XCTFail("Deleted task must not retain readable slices") }
    }
}
