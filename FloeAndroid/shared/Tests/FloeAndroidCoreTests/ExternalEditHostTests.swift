// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeCore
import FloeTools
import FloeWorkspace
@testable import FloeAndroidCore

final class ExternalEditHostTests: XCTestCase {
    private func message(_ action: String, epoch: UInt64 = 17, id: String? = nil,
                         receipt: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["operation": "externalEdit.host." + action, "epoch": NSNumber(value: epoch)]
        if let id { result["ticketID"] = id }
        if let receipt { result["receipt"] = receipt }
        return result
    }
    private func claim(_ mailbox: ExternalEditHostMailbox) async throws -> [String: Any] {
        for _ in 0..<100 {
            if let ticket = mailbox.handle(message("claim"))["ticket"] as? [String: Any] { return ticket }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "ExternalEditHostTests.claim", code: 1)
    }

    func testClaimedCancelWaitsForRealSettlementAndKeepsForeignEpochOut() async throws {
        let mailbox = ExternalEditHostMailbox(rootIsCurrent: { $0 > 0 })
        XCTAssertEqual(mailbox.handle(message("bind"))["ok"] as? Bool, true)
        let token = CancellationToken()
        let operation = Task { try await mailbox.submit(epoch: 17, request: Data("{}".utf8), cancellation: token) }
        let ticket = try await claim(mailbox)
        let id = try XCTUnwrap(ticket["id"] as? String)
        token.cancel()
        XCTAssertEqual(mailbox.handle(message("canCommit", id: id))["allowed"] as? Bool, false)
        XCTAssertEqual(mailbox.handle(message("close"))["drained"] as? Bool, false)
        XCTAssertEqual(mailbox.handle(message("bind", epoch: 18))["ok"] as? Bool, false)
        XCTAssertEqual(mailbox.handle(message("settle", epoch: 18, id: id, receipt: "{\"ok\":true}"))["ok"] as? Bool, false)
        let result = "{\"ok\":false,\"error\":\"cancelled\"}"
        XCTAssertEqual(mailbox.handle(message("settle", id: id, receipt: result))["ok"] as? Bool, true)
        let actual = try await operation.value
        XCTAssertEqual(String(decoding: actual, as: UTF8.self), result)
        XCTAssertEqual(mailbox.handle(message("close"))["drained"] as? Bool, true)
    }

    func testOwnerCancellationPreventsAClaimAndAcknowledgementCannotReplayIntent() async throws {
        let mailbox = ExternalEditHostMailbox(rootIsCurrent: { $0 == 17 })
        _ = mailbox.handle(message("bind"))
        let ownerCancellation = CancellationToken(); ownerCancellation.cancel()
        do {
            _ = try await mailbox.submit(epoch: 17, request: Data("{}".utf8),
                cancellation: CancellationToken(), ownerCancellation: ownerCancellation)
            XCTFail("Cancelled owner must not queue an Intent")
        } catch { }
        XCTAssertNil(mailbox.handle(message("claim"))["ticket"] as? [String: Any])
        let operation = Task { try await mailbox.submit(epoch: 17, request: Data("{}".utf8), cancellation: CancellationToken()) }
        let ticket = try await claim(mailbox)
        let id = try XCTUnwrap(ticket["id"] as? String)
        let receipt = "{\"ok\":true,\"state\":\"editing\",\"saved\":false}"
        XCTAssertEqual(mailbox.handle(message("settle", id: id, receipt: receipt))["ok"] as? Bool, true)
        _ = try await operation.value
        XCTAssertEqual(mailbox.handle(message("settle", id: id, receipt: receipt))["ok"] as? Bool, true)
        XCTAssertEqual(mailbox.handle(message("settle", id: id, receipt: "{\"ok\":true,\"saved\":true}"))["ok"] as? Bool, false)
        XCTAssertNil(mailbox.handle(message("claim"))["ticket"] as? [String: Any])
        XCTAssertEqual(mailbox.handle(["operation": "externalEdit.host.bind", "epoch": true])["ok"] as? Bool, false)
    }

    private actor Access: G04WorkspaceAccessPort {
        let root: URL
        private(set) var releases = 0
        private(set) var owners: [G04WorkspaceOwner] = []
        init(root: URL) { self.root = root }
        func acquire(owner: G04WorkspaceOwner, intent: G04WorkspaceIntent,
                     relativePath: String?) async throws -> G04WorkspaceAccessLease {
            owners.append(owner)
            return G04WorkspaceAccessLease(service: WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)),
                cancellation: CancellationToken(), release: { await self.release() })
        }
        private func release() { releases += 1 }
        func snapshot() -> (Int, [G04WorkspaceOwner]) { (releases, owners) }
    }

    func testActualToolDispatchCarriesOnlyTrustedOwnerAndDoesNotReportOpenAsSaved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("empty.txt"))
        let owner = G04WorkspaceOwner(epoch: 17, taskID: UUID(), workspaceID: UUID())
        let access = Access(root: root)
        let mailbox = ExternalEditHostMailbox(rootIsCurrent: { $0 == 17 })
        let routing = G04ExternalEditRouting(epoch: 17, isLive: { true },
            resolveOwner: { $0 == owner.taskID ? owner : nil }, access: access, mailbox: mailbox)
        let registry = ToolRunnerRegistry()
        G04ExternalEditTool.install(routing: routing, registry: registry)
        XCTAssertNil(registry.runner(named: G04ExternalEditTool.name))
        _ = mailbox.handle(message("bind"))
        let runner = try XCTUnwrap(registry.runner(named: G04ExternalEditTool.name))
        let runID = UUID()
        var context = ToolContext(runID: runID, workspaceRootURL: root, cancellation: CancellationToken(),
            conversationID: owner.taskID)
        context.toolCallID = "external-editor-open-once"
        let dispatchContext = context
        let dispatch = Task { try await runner.execute(argumentsJSON: Data(#"{"action":"open","path":"empty.txt"}"#.utf8), context: dispatchContext) }
        let ticket = try await claim(mailbox)
        let requestText = try XCTUnwrap(ticket["request"] as? String)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(requestText.utf8)) as? [String: Any])
        XCTAssertEqual(request["taskID"] as? String, owner.taskID.uuidString.lowercased())
        XCTAssertEqual(request["workspaceID"] as? String, owner.workspaceID.uuidString.lowercased())
        XCTAssertEqual(request["runID"] as? String, runID.uuidString.lowercased())
        XCTAssertEqual(request["path"] as? String, "empty.txt")
        XCTAssertNil(request["root"]); XCTAssertNil(request["uri"]); XCTAssertNil(request["environmentID"])
        let id = try XCTUnwrap(ticket["id"] as? String)
        let receipt = #"{"ok":true,"sessionID":"00000000-0000-0000-0000-000000000001","state":"editing","saved":false,"completed":false}"#
        _ = mailbox.handle(message("settle", id: id, receipt: receipt))
        let output = try await dispatch.value
        XCTAssertEqual(output.summary, receipt)
        let (releases, owners) = await access.snapshot()
        XCTAssertEqual(releases, 1); XCTAssertEqual(owners, [owner])
    }

    func testWrongRootTemporaryAndPathCeilingNeverReachHost() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = G04WorkspaceOwner(epoch: 17, taskID: UUID(), workspaceID: UUID())
        let access = Access(root: root)
        let mailbox = ExternalEditHostMailbox(rootIsCurrent: { $0 == 17 })
        _ = mailbox.handle(message("bind"))
        let tool = G04ExternalEditTool(routing: G04ExternalEditRouting(epoch: 17, isLive: { true },
            resolveOwner: { $0 == owner.taskID ? owner : nil }, access: access, mailbox: mailbox))
        var context = ToolContext(runID: UUID(), workspaceRootURL: root, allowedWorkspacePaths: ["allowed.txt"],
            cancellation: CancellationToken(), conversationID: owner.taskID)
        context.toolCallID = "blocked-editor"
        let args = G04ExternalEditTool.Arguments(action: "open", path: "other.txt", sessionID: nil, chooseApplication: nil)
        do { _ = try await tool.execute(args, context: context); XCTFail("Path ceiling must apply") } catch { }
        context.allowedWorkspacePaths = []
        context.workspaceRootURL = root.appendingPathComponent("another-project")
        do { _ = try await tool.execute(args, context: context); XCTFail("Foreign root must be refused") } catch { }
        context.workspaceRootURL = root; context.temporaryReadOnly = true
        do { _ = try await tool.execute(args, context: context); XCTFail("Temporary context must be refused") } catch { }
        XCTAssertNil(mailbox.handle(message("claim"))["ticket"] as? [String: Any])
        let (releases, owners) = await access.snapshot()
        XCTAssertEqual(releases, 1); XCTAssertEqual(owners, [owner])
    }
}
