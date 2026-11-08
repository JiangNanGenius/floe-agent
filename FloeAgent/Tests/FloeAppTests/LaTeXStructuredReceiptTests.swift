// SPDX-License-Identifier: MPL-2.0
import XCTest
import FloeCore
import FloeModels
import FloeTools
import FloeAgentRuntime
import FloeEnvironments
import FloeExecution
import FloePersistence
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

// This contract resolves real environment metadata but never launches a guest.
// Its isolated shell returns fixture text; actual PDF proof remains the opt-in
// ConversationRunService case on the retained project.
private actor LaTeXShellRoutingProbe {
    enum Change: Sendable { case none, missingEnvironment, wrongEnvironment, wrongTask, wrongGeneration }
    var change: Change = .none
    private(set) var routedNames = [String]()
    private(set) var ownerContexts = [ToolContext]()
    func setChange(_ value: Change) { change = value }
    func recordOwner(_ context: ToolContext) { ownerContexts.append(context) }
    func inspectRoute(_ original: ToolContext) -> ToolContext {
        routedNames.append(original.executionToolName ?? "missing")
        var context = original
        switch change {
        case .none: break
        case .missingEnvironment: context.environment = nil
        case .wrongEnvironment: context.environmentID = "another-environment"
        case .wrongTask: context.conversationID = UUID()
        case .wrongGeneration: context.executionBindingGeneration = 99
        }
        return context
    }
}

@MainActor private struct LaTeXShellRoutingFixture {
    let root: URL
    let host: LaTeXReceiptHost
    let registry: ToolRunnerRegistry
    let environments: EnvironmentRegistry
    let coordinator: EnvironmentExecutionCoordinator
    let routing: ToolEnvironmentRouting
    let jobs: BackgroundJobService
    let probe: LaTeXShellRoutingProbe
    let context: ToolContext
    let binding: RuntimeAuthorityBinding

    static func make(root: URL) async throws -> Self {
        let workspace = root.appendingPathComponent("Workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let taskID = UUID(), roots = EnvironmentRoots(rootURL: root.appendingPathComponent("Environments"))
        let environments = EnvironmentRegistry(roots: roots, baseRevision: "routing-fixture")
        let record = try await environments.ensureSessionContainer(conversationID: taskID.uuidString,
            workspaceID: FloeDigest.sha256Hex(Data(workspace.path.utf8)), workspaceRootPath: workspace.path,
            executionBackend: .linuxVM)
        let coordinator = EnvironmentExecutionCoordinator(roots: roots, registry: environments)
        let routing = ToolEnvironmentRouting(), probe = LaTeXShellRoutingProbe()
        routing.configure { context in
            let lease = try await coordinator.acquire(context)
            return ToolEnvironmentLease(context: await probe.inspectRoute(lease.context), finish: lease.finish)
        }
        let registry = ToolRunnerRegistry(), host = try LaTeXReceiptHost(root: root)
        LaTeXHostTools.register(host: host, registry: registry)
        registry.register(AnyAgentTool(descriptor: ToolCatalog.Descriptor(name: "exec.shell",
            toolDescription: "Isolated routing fixture; no process is launched", parametersJSON: #"{"type":"object"}"#,
            riskLabels: [], isSideEffecting: true), run: { _, _ in
                let summary = "Resolved fixture execution"
                return ToolExecutionOutput(summary: summary,
                    fullOutputSHA256: FloeDigest.sha256Hex(Data(summary.utf8)), exitStatus: 0)
            }, routing: routing))
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let jobs = BackgroundJobService(store: BackgroundJobStore(database: database), registry: registry)
        let caller = try XCTUnwrap(registry.runner(named: "latex.typeset"))
        let project = try await host.store.manifest()
        let raw = try JSONSerialization.data(withJSONObject: ["projectID": project.id.uuidString, "action": "prepare"], options: [.sortedKeys])
        let callID = UUID().uuidString, grant = UUID()
        var context = ToolContext(runID: UUID(), toolCallID: callID, toolIdempotencyKey: callID, approvalGrantID: grant,
            allowedToolNames: ["latex.typeset", "exec.shell"], workspaceRootURL: workspace,
            cancellation: CancellationToken(), environmentID: record.id, executionBindingGeneration: 7,
            conversationID: taskID, frozenEffectiveCatalogNames: ["latex.typeset", "exec.shell"])
        context.executionToolName = "latex.typeset"
        var call = try ToolCall(id: callID, toolName: "latex.typeset", argumentsJSON: raw, scope: .local)
        call.idempotencyKey = callID
        let binding = context.runtimeAuthorityBinding(toolName: call.toolName, operation: "apply",
            canonicalTarget: RuntimeAuthorityDigest.canonicalTarget(for: call, descriptor: caller.descriptor, workspaceRootURL: workspace),
            baseRevision: nil, payloadDigest: RuntimeAuthorityDigest.payloadDigest(raw))
        // A real in-memory authority token for synthetic identities, used only
        // to check preservation/revocation; this is not an App approval result.
        context.runtimeAuthority = await RuntimeAuthorityStore.shared.issue(.init(runID: context.runID, taskID: taskID,
            environmentBinding: binding.environmentBinding, canonicalTarget: binding.canonicalTarget,
            toolName: binding.toolName, operation: binding.operation, operationID: callID, idempotencyKey: callID,
            baseRevision: nil, payloadDigest: binding.payloadDigest, approvalGrantID: grant))
        return .init(root: root, host: host, registry: registry, environments: environments, coordinator: coordinator,
            routing: routing, jobs: jobs, probe: probe, context: context, binding: binding)
    }
    func transport(project: LaTeXHostProject, context override: ToolContext? = nil) async throws -> LaTeXShellTransport {
        let original = context
        return try await LaTeXShellTransport.create(context: override ?? original, binding: binding, jobs: jobs,
            environments: environments, lifetime: project, registry: registry, routing: routing, validateOwner: { [probe] actual in
                guard actual.executionToolName == original.executionToolName,
                      actual.toolCallID == original.toolCallID, actual.approvalGrantID == original.approvalGrantID,
                      actual.runtimeAuthority == original.runtimeAuthority,
                      actual.allowedToolNames == (override ?? original).allowedToolNames,
                      actual.frozenEffectiveCatalogNames == (override ?? original).frozenEffectiveCatalogNames else { throw FloeError.unauthorized }
                await probe.recordOwner(actual)
            })
    }
    func revoke() async {
        if let token = context.runtimeAuthority { await RuntimeAuthorityStore.shared.revoke(id: token.id) }
    }
}

@MainActor final class LaTeXShellEnvironmentRoutingTests: XCTestCase {
    func testModelCallerResolvesItsShellLayerAndRetainsExactApproval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await LaTeXShellRoutingFixture.make(root: root)
        do {
            XCTAssertNil(fixture.context.environment)
            XCTAssertEqual(CapabilityExecutionRouter.decision(for: "latex.typeset").backend, .nativeApple)
            let project = LaTeXHostProject(store: fixture.host.store)
            let transport = try await fixture.transport(project: project)
            XCTAssertEqual(transport.owner.environmentID, fixture.context.environmentID)
            XCTAssertEqual(transport.owner.runID, fixture.context.runID)
            XCTAssertEqual(transport.owner.taskID, fixture.context.conversationID)
            let output = try await transport.execute(script: "fixture", maximumOutputBytes: 1024)
            XCTAssertEqual(output.exitStatus, 0)
            XCTAssertEqual(output.stdout, "Resolved fixture execution")
            let leases = await fixture.coordinator.activeLeaseCount(environmentID: fixture.context.environmentID!)
            XCTAssertEqual(leases, 1, "The project must retain the real dependency lease")
            let routed = await fixture.probe.routedNames
            XCTAssertEqual(routed, ["exec.shell", "exec.shell"])
            let owners = await fixture.probe.ownerContexts
            XCTAssertFalse(owners.isEmpty)
            XCTAssertTrue(owners.allSatisfy { $0.executionToolName == "latex.typeset" && $0.runtimeAuthority == fixture.context.runtimeAuthority })
            let verdict = await RuntimeAuthorityStore.shared.validate(fixture.context.runtimeAuthority!, binding: fixture.binding)
            XCTAssertTrue(verdict.isValid)
        } catch { await fixture.revoke(); throw error }
        await fixture.revoke()
    }

    func testMissingShellCeilingChangedLeaseAndRevocationCannotAcquireAuthority() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await LaTeXShellRoutingFixture.make(root: root)
        do {
            let project = LaTeXHostProject(store: fixture.host.store)
            for frozen in [false, true] {
                var denied = fixture.context
                if frozen { denied.frozenEffectiveCatalogNames = ["latex.typeset"] }
                else { denied.allowedToolNames = ["latex.typeset"] }
                do { _ = try await fixture.transport(project: project, context: denied); XCTFail("The shell ceiling must be checked before resolution") } catch {}
            }
            let before = await fixture.probe.routedNames
            XCTAssertTrue(before.isEmpty)
            for change in [LaTeXShellRoutingProbe.Change.missingEnvironment, .wrongEnvironment, .wrongTask, .wrongGeneration] {
                await fixture.probe.setChange(change)
                do { _ = try await fixture.transport(project: project); XCTFail("A changed or unresolved dependency lease must fail") } catch {}
                let count = await fixture.coordinator.activeLeaseCount(environmentID: fixture.context.environmentID!)
                XCTAssertEqual(count, 0, "Every rejected dependency lease must finish")
            }
            await fixture.probe.setChange(.none)
            await fixture.revoke()
            do { _ = try await fixture.transport(project: project); XCTFail("Resolving a layer must not revive revoked runtime authority") } catch {}
            let count = await fixture.coordinator.activeLeaseCount(environmentID: fixture.context.environmentID!)
            XCTAssertEqual(count, 0)
        } catch { await fixture.revoke(); throw error }
        await fixture.revoke()
    }
}

@MainActor final class LaTeXModelStructuredReceiptTests: XCTestCase {
    func testCatalogAndDurableResultsKeepBoundedLaTeXJSONComplete() async throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString, "state": "succeeded", "workerStopped": true,
            "messages": [String(repeating: "Package warning: 中文; \\ref{eq:fixture}\n", count: 900)],
            "pdfRelativePath": "Output/document.pdf", "synctexRelativePath": "Output/document.synctex.gz"
        ], options: [.sortedKeys])
        XCTAssertGreaterThan(data.count, 4096)
        XCTAssertLessThan(data.count, 96 * 1024)
        let json = String(decoding: data, as: UTF8.self)
        let output = ToolExecutionOutput(summary: json, fullOutputSHA256: LaTeXDigest.hash(data),
            exitStatus: 0, maximumSummaryCharacters: data.count)
        let registry = ToolRunnerRegistry(), routing = ToolEnvironmentRouting()
        let ordinary = "fixture.bounded-receipt"
        for name in LaTeXHostTools.names.union([ordinary]) {
            registry.register(AnyAgentTool(descriptor: .init(name: name, riskLabels: [], isSideEffecting: false),
                run: { _, _ in output }, routing: routing))
        }
        let executor = CatalogToolExecutor(runners: registry)
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken(), conversationID: UUID())
        for name in LaTeXHostTools.names.sorted() {
            let call = try ToolCall(id: UUID().uuidString, toolName: name, argumentsJSON: Data("{}".utf8), scope: .local)
            let result = try await executor.execute(call, context: context)
            XCTAssertEqual(result.status, .ok)
            XCTAssertEqual(result.outputDigest, output.fullOutputSHA256)
            XCTAssertEqual(result.outputSummary, json, "The LaTeX service already bounds this structured receipt")
            let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.outputSummary.utf8)) as? [String: Any])
            XCTAssertEqual(decoded["pdfRelativePath"] as? String, "Output/document.pdf")
            XCTAssertEqual(decoded["synctexRelativePath"] as? String, "Output/document.synctex.gz")
            let persisted = try JSONEncoder().encode(result)
            let reopened = try JSONDecoder().decode(ToolResult.self, from: persisted)
            XCTAssertEqual(reopened.outputSummary, json, "Checkpoint/replay must retain the bounded JSON allowance")
        }
        let plain = try ToolCall(id: UUID().uuidString, toolName: ordinary, argumentsJSON: Data("{}".utf8), scope: .local)
        let other = try await executor.execute(plain, context: context)
        XCTAssertEqual(other.outputSummary.count, 4096, "Other tools keep their existing default preview bound")
    }
}
