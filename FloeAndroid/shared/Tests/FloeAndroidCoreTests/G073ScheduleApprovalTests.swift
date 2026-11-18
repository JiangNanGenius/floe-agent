// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import FloeModels
@testable import FloeAndroidCore

final class G073ScheduleApprovalTests: XCTestCase {
    func testCreateProjectionBindsRealTargetAndRejectsAmbiguousInputs() throws {
        let model = UUID(), project = UUID()
        let binding = G073TaskScheduleToolBinding(workspaceID: project, modelID: model,
            environmentID: "project-env", policy: DraftTaskPolicy(approvalMode: .ask))
        let args = G073TaskScheduleTool.Arguments(action: "create", title: "Reminder", prompt: "Inspect status",
            cadence: "interval", scheduledAt: "2030-01-02T03:04:05Z", intervalHours: 2)
        let details = try XCTUnwrap(G073ScheduleApproval.details(args: args, binding: binding))
        XCTAssertEqual(details["intervalSeconds"], .integer(7_200))
        XCTAssertEqual(details["scheduledAt"], .string("2030-01-02T03:04:05.000Z"))
        XCTAssertEqual(details["workspaceID"], .string(project.uuidString.lowercased()))
        XCTAssertEqual(details["modelID"], .string(model.uuidString.lowercased()))
        XCTAssertEqual(details["environmentID"], .string("project-env"))
        XCTAssertEqual(details["approvalMode"], .string("ask"))
        let changed = G073TaskScheduleToolBinding(workspaceID: project, modelID: UUID(),
            environmentID: "project-env", policy: DraftTaskPolicy(approvalMode: .ask))
        XCTAssertNotEqual(G073ScheduleApproval.digest(details),
                          G073ScheduleApproval.details(args: args, binding: changed).flatMap(G073ScheduleApproval.digest))
        XCTAssertNil(G073ScheduleApproval.details(args: .init(action: "create", prompt: "x", cadence: "once"), binding: binding))
        XCTAssertNil(G073ScheduleApproval.details(args: .init(action: "create", prompt: "x", cadence: "interval",
            scheduledAt: "2030-01-02T03:04:05Z", intervalHours: 2, intervalSeconds: 60), binding: binding))
        XCTAssertNil(G073ScheduleApproval.details(args: .init(action: "create", prompt: "x", cadence: "once",
            scheduledAt: "2030-01-02T03:04:05Z", enable: false), binding: binding))
        XCTAssertNil(G073ScheduleApproval.arguments(Data(#"{"action":"create","cadence":"once","extra":true}"#.utf8)))
    }

    func testManualGateIsOneShotAndRunScoped() {
        let gate = G073ScheduleApprovalGate()
        let run = UUID(), other = UUID(), grant = UUID(), siblingGrant = UUID()
        XCTAssertTrue(gate.stage(run: run, call: "c", grant: grant, digest: "reviewed"))
        XCTAssertFalse(gate.stage(run: run, call: "c", grant: grant, digest: "replacement"))
        XCTAssertNil(gate.take(run: other, call: "c", grant: grant))
        XCTAssertNil(gate.take(run: run, call: "c", grant: siblingGrant))
        XCTAssertEqual(gate.take(run: run, call: "c", grant: grant), "reviewed")
        XCTAssertNil(gate.take(run: run, call: "c", grant: grant))
        XCTAssertTrue(gate.stage(run: run, call: "c", grant: grant, digest: "new"))
        gate.retire(run: run)
        XCTAssertNil(gate.take(run: run, call: "c", grant: grant))
    }
}
