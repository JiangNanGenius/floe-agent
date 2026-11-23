// SPDX-License-Identifier: MPL-2.0
//
// G03-R4 — closed App-host job channel (`floe.taskjobs/30`). AUTHORED, NOT
// EXECUTED here. These cases need no runtime: the bridge must fail typed
// BEFORE any store read for every malformed/foreign request.
import XCTest
import Foundation
import FloeAndroidJobTools
import FloePersistence
@testable import FloeAndroidCore

final class TaskJobsHostBridgeTests: XCTestCase {
    private let conversationID = UUID()

    private func request(_ object: [String: Any]) -> [String: Any] {
        let data = try! JSONSerialization.data(withJSONObject: object,
                                               options: [.sortedKeys])
        return TaskJobsHostBridge.handle(requestData: data,
                                         fallbackRequestID: "fallback")
    }

    private func valid(version: Int = 30, action: String = "jobs.list",
                       payload: [String: Any]? = nil,
                       epoch: Any? = 1) -> [String: Any] {
        var object: [String: Any] = [
            "version": version,
            "operation": "command",
            "requestID": "req-1",
            "action": action,
            "payload": payload ?? ["conversationID": conversationID.uuidString],
        ]
        if let epoch { object["epoch"] = epoch }
        return object
    }

    func testOversizedAndNonJSONRequestsFailTyped() {
        let huge = Data(repeating: 0x41, count: BridgeV30.maximumRequestBytes + 1)
        let tooLarge = TaskJobsHostBridge.handle(requestData: huge,
                                                fallbackRequestID: nil)
        XCTAssertEqual(tooLarge["error"] as? String, "requestTooLarge")
        let invalid = TaskJobsHostBridge.handle(requestData: Data("no".utf8),
                                                fallbackRequestID: nil)
        XCTAssertEqual(invalid["error"] as? String, "invalidJSON")
    }

    func testOnlyTheClosedVersionAndActionsAreAccepted() {
        XCTAssertEqual(request(valid(version: 31))["error"] as? String,
                       "unsupportedVersion")
        XCTAssertEqual(request(valid(action: "jobs.submit"))["error"] as? String,
                       "unsupportedAction")
        for action in [BridgeV30.cancelAction, BridgeV30.restartServiceAction,
                       BridgeV30.openServicePreviewAction] {
            XCTAssertEqual(request(valid(action: action))["error"] as? String, "invalidRequest")
            let fields: [String: Any] = ["conversationID": conversationID.uuidString,
                                        "runID": UUID().uuidString, "jobID": UUID().uuidString]
            XCTAssertEqual(request(valid(action: action, payload: fields, epoch: 1_000_000))["error"] as? String,
                           "staleEpoch")
        }
    }

    func testMalformedIdentityAndEpochFailBeforeAnyStoreAccess() {
        let malformed = request(valid(payload: ["conversationID": "not-a-uuid"]))
        XCTAssertEqual(malformed["error"] as? String, "invalidRequest")
        XCTAssertEqual(request(valid(epoch: nil))["error"] as? String,
                       "invalidRequest")
        XCTAssertEqual(request(valid(epoch: 0))["error"] as? String,
                       "invalidRequest")
        XCTAssertEqual(request(valid(epoch: -3))["error"] as? String,
                       "invalidRequest")
        // A structurally valid request can only reach the two typed
        // runtime-availability refusals here — it never succeeds and never
        // reads a store without a live composed generation.
        let validRequest = request(valid())
        let code = validRequest["error"] as? String
        XCTAssertTrue(code == "staleEpoch" || code == "runtimeUnavailable",
                      "unexpected valid-request outcome: \(String(describing: code))")
    }

    func testRestartIsLimitedToSettledAndroidManagedServices() {
        let declaration = Data(#"{"service":{"runtime":"python","entry":"server.py","port":49152}}"#.utf8)
        var job = BackgroundJob(conversationID: conversationID, runID: UUID(),
                                kind: .tool, targetTool: "exec.shell", payloadJSON: declaration,
                                state: .interrupted, workspaceRootPath: "/workspace", environmentID: "project")
        XCTAssertTrue(BackgroundJobService.canRestartLocalService(job))
        job.state = .running
        XCTAssertFalse(BackgroundJobService.canRestartLocalService(job))
        job.state = .failed
        job.environmentID = nil
        XCTAssertFalse(BackgroundJobService.canRestartLocalService(job))
        job.environmentID = "project"
        job.targetTool = "exec.localService"
        XCTAssertFalse(BackgroundJobService.canRestartLocalService(job))
        job.targetTool = "exec.shell"
        job.payloadJSON = Data(#"{"command":"true"}"#.utf8)
        XCTAssertFalse(BackgroundJobService.canRestartLocalService(job))
    }

    func testClosedTargetClassification() {
        XCTAssertEqual(TaskJobTargetKind.classify(
            targetTool: "exec.shell", payloadJSON: Data("{}".utf8)), .shell)
        XCTAssertEqual(TaskJobTargetKind.classify(
            targetTool: "web.fetch", payloadJSON: Data("{}".utf8)), .web)
        XCTAssertEqual(TaskJobTargetKind.classify(
            targetTool: "document.office.edit", payloadJSON: Data("{}".utf8)),
                       .officeEdit)
        XCTAssertEqual(TaskJobTargetKind.classify(
            targetTool: "exec.shell",
            payloadJSON: Data(#"{"service":{"entry":"main"}}"#.utf8)), .service)
        XCTAssertEqual(TaskJobTargetKind.classify(
            targetTool: "exec.localService", payloadJSON: Data("{}".utf8)),
                       .service)
        XCTAssertEqual(TaskJobTargetKind.classify(
            targetTool: "unknown.tool", payloadJSON: Data("{}".utf8)), .other)
    }
}
