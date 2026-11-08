// SPDX-License-Identifier: MPL-2.0
import XCTest
import FloeCore
import FloeModels
import FloeTools
import FloeLaTeXCore
import FloeLaTeXEngine
import FloeLaTeXHostAdapter

private actor LaTeXReceiptFailureEngine: LaTeXEngineRunning {
    private(set) var timeLimits = [Int]()
    let log = String(repeating: "A long typesetting diagnostic: 中文 \\input{fixture}\n", count: 160)
    func capabilities() async -> [LaTeXEngineCapability] { [] }
    func run(_ request: LaTeXEngineRequest, progress: @escaping @Sendable (String) -> Void) async throws -> LaTeXEngineOutput {
        timeLimits.append(request.configuration.timeoutSeconds)
        throw LaTeXEngineFailure("Document time limit reached", messages: [log], workerStopped: true)
    }
}

@MainActor private final class LaTeXReceiptHost: LaTeXHostAccess {
    let store: LaTeXProjectStore
    let builds: LaTeXBuildService
    let engine = LaTeXReceiptFailureEngine()
    var acquired = 0
    init(root: URL) throws {
        store = try .create(root: root.appendingPathComponent("Project"), owner: .init(kind: .task, id: UUID()), title: "Receipt fixture", files: ["main.tex": Data("Original".utf8)])
        builds = try .init(cacheRoot: root.appendingPathComponent("Cache"))
    }
    func acquire(projectID: UUID, context: ToolContext, editing: Bool) async throws -> LaTeXHostProject {
        guard try await store.manifest().id == projectID else { throw LaTeXError.invalidProject }
        acquired += 1
        return .init(store: store)
    }
    func create(title: String, templateID: String, context: ToolContext) async throws -> LaTeXHostProject { throw LaTeXError.unavailable("Not a creation fixture") }
    func publish(file: URL, project: LaTeXHostProject, context: ToolContext) async throws -> ToolExecutionOutput { throw LaTeXError.unavailable("Not a publication fixture") }
    func prepareEngine(project: LaTeXHostProject, context: ToolContext, binding: RuntimeAuthorityBinding?) async throws -> (any LaTeXEngineRunning)? { engine }
}

@MainActor final class LaTeXStructuredReceiptTests: XCTestCase {
    func testLongFailedBuildRetainsValidJSONAndRealDiagnostic() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try LaTeXReceiptHost(root: root), registry = ToolRunnerRegistry()
        LaTeXHostTools.register(host: host, registry: registry)
        let runner = try XCTUnwrap(registry.runner(named: "latex.typeset"))
        let project = try await host.store.manifest()
        let result = try await invoke(runner, root: root, arguments: ["projectID": project.id.uuidString, "action": "start", "expectedRevision": project.revision])
        XCTAssertEqual(result.exitStatus, 1)
        XCTAssertFalse(result.outcomeUnknown)
        XCTAssertFalse(result.summaryTruncated)
        XCTAssertGreaterThan(result.summary.utf8.count, 4096)
        let data = Data(result.summary.utf8)
        XCTAssertEqual(LaTeXDigest.hash(data), result.fullOutputSHA256)
        let build = try JSONDecoder().decode(LaTeXBuildRecord.self, from: data)
        XCTAssertEqual(build.state, .failed)
        XCTAssertEqual(build.workerStopped, true)
        XCTAssertNil(build.pdfRelativePath)
        XCTAssertEqual(build.diagnostics.first?.message, "Document time limit reached")
        let log = await host.engine.log
        XCTAssertEqual(build.messages, [log])
        let limits = await host.engine.timeLimits
        XCTAssertEqual(limits, [600])
        let busy = await host.builds.isBusy(projectID: project.id)
        XCTAssertFalse(busy)
    }

    func testExplicitBudgetReachesEngineAndInvalidBudgetCannotOpenOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try LaTeXReceiptHost(root: root), registry = ToolRunnerRegistry()
        LaTeXHostTools.register(host: host, registry: registry)
        let runner = try XCTUnwrap(registry.runner(named: "latex.typeset"))
        let project = try await host.store.manifest()
        for invalid in [0, 601] {
            let raw = try JSONSerialization.data(withJSONObject: ["projectID": project.id.uuidString, "action": "start", "expectedRevision": project.revision, "timeoutSeconds": invalid])
            XCTAssertThrowsError(try runner.validateArguments(raw))
        }
        XCTAssertEqual(host.acquired, 0)
        _ = try await invoke(runner, root: root, arguments: ["projectID": project.id.uuidString, "action": "start", "expectedRevision": project.revision, "timeoutSeconds": 47])
        let limits = await host.engine.timeLimits
        XCTAssertEqual(limits, [47])
    }

    private func invoke(_ runner: AnyAgentTool, root: URL, arguments: [String: Any]) async throws -> ToolExecutionOutput {
        let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        try runner.validateArguments(data)
        let callID = UUID().uuidString
        var context = ToolContext(runID: UUID(), toolCallID: callID, toolIdempotencyKey: callID, approvalGrantID: UUID(), allowedToolNames: LaTeXHostTools.names.union(["exec.shell"]), workspaceRootURL: root, cancellation: CancellationToken(), conversationID: UUID(), frozenEffectiveCatalogNames: LaTeXHostTools.names.union(["exec.shell"]))
        context.executionToolName = "latex.typeset"
        var call = try ToolCall(id: callID, toolName: "latex.typeset", argumentsJSON: data, scope: .local)
        call.idempotencyKey = callID
        let binding = context.runtimeAuthorityBinding(toolName: call.toolName, operation: "apply", canonicalTarget: RuntimeAuthorityDigest.canonicalTarget(for: call, descriptor: runner.descriptor, workspaceRootURL: root), baseRevision: RuntimeAuthorityDigest.baseRevision(in: data), payloadDigest: RuntimeAuthorityDigest.payloadDigest(data))
        let authority = await RuntimeAuthorityStore.shared.issue(.init(runID: context.runID, taskID: context.conversationID, environmentBinding: binding.environmentBinding, canonicalTarget: binding.canonicalTarget, toolName: binding.toolName, operation: binding.operation, operationID: callID, idempotencyKey: callID, baseRevision: binding.baseRevision, payloadDigest: binding.payloadDigest, approvalGrantID: context.approvalGrantID!))
        context.runtimeAuthority = authority
        do {
            let output = try await runner.run(data, context)
            await RuntimeAuthorityStore.shared.revoke(id: authority.id)
            return output
        } catch {
            await RuntimeAuthorityStore.shared.revoke(id: authority.id)
            throw error
        }
    }
}
