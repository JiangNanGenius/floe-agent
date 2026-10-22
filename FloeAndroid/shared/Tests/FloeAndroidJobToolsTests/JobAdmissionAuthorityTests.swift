// SPDX-License-Identifier: MPL-2.0
//
// Authored-only focused suite: jobs.submit admission + ORIGINAL runtime
// authority through the mirrored tool (job-a16c9976985f40b2). The mirrored
// BackgroundJobTools must keep the ORIGINAL fail-closed provenance gate:
// the raw registered entry ONLY accepts runtime-issued call identity + the
// `jobs.submit`-bound origin, and the Android mirror must honestly refuse
// targets this platform never registers (no exec.localService, no legacy
// installers, no retired aliases, no media/document/video promises).
import XCTest
import Foundation
import FloeCore
import FloeTools
import FloePersistence
@testable import FloeAndroidJobTools

final class JobAdmissionAuthorityTests: XCTestCase {

    private func makeService(policy: NativeJobActionPolicy) async throws -> BackgroundJobService {
        let db = try DatabaseManager.inMemory()
        // DatabaseManager is an actor; the migration hop is awaited (Swift 6 isolation).
        try await db.migrate()
        return BackgroundJobService(store: BackgroundJobStore(database: db),
                                    registry: ToolRunnerRegistry(),
                                    policy: policy)
    }

    private var androidPolicy: NativeJobActionPolicy {
        NativeJobActionPolicy(handlers: [
            "exec.shell": NativeJobHandler(allowedActions: [NativeJobActionPolicy.anyAction]),
            "web.fetch": NativeJobHandler(allowedActions: [NativeJobActionPolicy.anyAction]),
        ])
    }

    // MARK: - Admitted set (J1): registered + policy, nothing else

    func testValidateRefusesTargetsAndroidNeverRegisters() async throws {
        let service = try await makeService(policy: androidPolicy)
        let tool = JobsSubmitTool(service: service, admittedTargets: ["exec.shell"])
        for target in ["exec.localService", "network.download", "video.edit",
                       "video.interpolate", "media.project", "document.office.edit",
                       "document.pdf.export", "web.fetch" /* not registered here */,
                       "exec.localPython", "python.exec"] {
            XCTAssertThrowsError(
                try tool.validate(.init(tool: target, arguments: "{\"command\":\"ls\"}")),
                "jobs.submit must refuse '\(target)' when it is not registered+admitted"
            ) { error in
                XCTAssertTrue(String(describing: error).contains("admitted in this build"),
                              "refusal must name the ACTUAL admitted set: \(error)")
            }
        }
    }

    func testValidateAcceptsTheAdmittedRegisteredTarget() async throws {
        let service = try await makeService(policy: androidPolicy)
        let tool = JobsSubmitTool(service: service, admittedTargets: ["exec.shell"])
        XCTAssertNoThrow(try tool.validate(.init(tool: "exec.shell",
                                                 arguments: "{\"command\":\"sleep 1\"}")))
        XCTAssertNoThrow(try tool.validate(.init(tool: "exec.shell",
                                                 arguments: "{}",
                                                 purpose: "long build", wait: false)))
    }

    func testValidateRefusesNonObjectArgumentsAndOverlongPurpose() async throws {
        let service = try await makeService(policy: androidPolicy)
        let tool = JobsSubmitTool(service: service, admittedTargets: ["exec.shell"])
        XCTAssertThrowsError(try tool.validate(.init(tool: "exec.shell", arguments: "[]")))
        XCTAssertThrowsError(try tool.validate(.init(tool: "exec.shell", arguments: "not json")))
        XCTAssertThrowsError(try tool.validate(.init(tool: "exec.shell",
                                                     arguments: "{}",
                                                     purpose: String(repeating: "x", count: 241))))
    }

    // MARK: - Static surface honesty (J1): the description must match the platform

    func testSubmitDescriptionDoesNotAdvertiseUnregisteredTargets() {
        let description = JobsSubmitTool.toolDescription
        XCTAssertTrue(description.contains("exec.shell"))
        for unregistered in ["exec.localService", "video.edit", "media.project",
                             "document.office", "document.pdf", "network.download",
                             "exec.localPython", "python.packages"] {
            XCTAssertTrue(!description.contains(unregistered),
                          "the model-facing description must not promise '\(unregistered)' on Android")
        }
    }

    func testSubmitSchemaParsesAndRequiresToolArguments() throws {
        let object = try JSONSerialization.jsonObject(
            with: Data(JobsSubmitTool.parametersJSON.utf8)) as? [String: Any]
        XCTAssertNotNil(object?["properties"])
        XCTAssertEqual(object?["required"] as? [String], ["tool", "arguments"])
    }

    // MARK: - ORIGINAL runtime authority stays fail-closed (.runtime)

    func testRawRuntimeSubmissionWithoutProvenanceRefusesBeforePersistence() async throws {
        let service = try await makeService(policy: androidPolicy)
        let tool = JobsSubmitTool(service: service, admittedTargets: ["exec.shell"])
        let context = ToolContext(runID: UUID(),
                                  toolCallID: nil,          // no runtime call id
                                  scope: .local,
                                  workspaceRootURL: try JobTestRoot.make(),
                                  allowedWorkspacePaths: [],
                                  cancellation: CancellationToken())
        do {
            _ = try await tool.execute(.init(tool: "exec.shell",
                                             arguments: "{\"command\":\"sleep 1\"}"),
                                       context: context)
            XCTFail("the raw registered entry must never fall back to in-process submission")
        } catch {
            let text = String(describing: error)
            XCTAssertTrue(text.contains("no runtime provider call id") || text.contains("jobs.submit"),
                          "expected the ORIGINAL provenance refusal, got: \(text)")
        }
    }

    func testRetiredExecutionAliasesRefusedAtTheCallSite() async throws {
        let service = try await makeService(policy: androidPolicy)
        do {
            _ = try await service.submit(
                runID: UUID(), toolCallID: "call-1",
                targetTool: "exec.localPython",
                payloadJSON: Data("{}".utf8), scope: .local,
                workspaceRootURL: nil, allowedWorkspacePaths: [],
                submissionSource: .nativeService)
            XCTFail("retired aliases must never become jobs")
        } catch {
            XCTAssertTrue(String(describing: error).contains("exec.shell"),
                          "the refusal must redirect to the one real execution path")
        }
    }

    // MARK: - canonicalApprovedPayload shape (binding integrity)

    func testCanonicalApprovedPayloadOmitsAbsentOptionals() throws {
        let data = try JobsSubmitTool.canonicalApprovedPayload(
            .init(tool: "exec.shell", arguments: "{\"command\":\"ls\"}"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["tool"] as? String, "exec.shell")
        XCTAssertNotNil(object?["arguments"])
        XCTAssertNil(object?["purpose"], "absent optional fields must stay absent (digest identity)")
        XCTAssertNil(object?["wait"])

        let full = try JobsSubmitTool.canonicalApprovedPayload(
            .init(tool: "exec.shell", arguments: "{}", purpose: "p", wait: false))
        let fullObject = try JSONSerialization.jsonObject(with: full) as? [String: Any]
        XCTAssertEqual(fullObject?["purpose"] as? String, "p")
        XCTAssertEqual(fullObject?["wait"] as? Bool, false)
    }

    func testCanonicalTargetResolvesWorkspaceOrWildcard() throws {
        let root = try JobTestRoot.make()
        let context = ToolContext(runID: UUID(), scope: .local, workspaceRootURL: root,
                                  allowedWorkspacePaths: [], cancellation: CancellationToken())
        XCTAssertTrue(JobsSubmitTool.canonicalTarget(context: context).hasPrefix("workspace:"))
        let bare = ToolContext(runID: UUID(), scope: .local, allowedWorkspacePaths: [],
                               cancellation: CancellationToken())
        XCTAssertEqual(JobsSubmitTool.canonicalTarget(context: bare), "workspace:*")
    }
}
