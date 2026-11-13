// SPDX-License-Identifier: MPL-2.0
//
// N10 child-scope repair (job-598f14db64d64d18) — child execution scope and
// truthful partial outcomes.
//
// The native failure showed a delegate child that ran with the parent's
// environment (its two approved shell calls worked) but returned
// `unfinished: exec.shell <last-executed-call>` after its reserved wrap-up
// requested another tool. The last EXECUTED batch was incorrectly reused as
// "unfinished"; a wrap-up tool request was silently ignored. These fixtures
// pin:
//   1. the child tool context handed to the canonical dispatcher retains the
//      task/run, environment, workspace root, workspace file ceiling, scope
//      and runtime-issued child handoff;
//   2. an executed child batch is never reported unfinished;
//   3. a wrap-up tool request that was deliberately not executed IS reported
//      unfinished, and an empty wrap-up text is stated honestly.
//
// Authored in the source-only window; NOT executed here.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloeAgentRuntime

private final class N113CapturedChildContexts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ToolContext] = []

    func append(_ value: ToolContext) {
        lock.lock(); defer { lock.unlock() }
        values.append(value)
    }

    var all: [ToolContext] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class N113ProbeExecutor: ToolExecutor, @unchecked Sendable {
    let descriptors: [ToolCatalog.Descriptor]

    init(names: [String]) {
        descriptors = names.map {
            ToolCatalog.Descriptor(
                name: $0, toolDescription: "scope probe",
                riskLabels: [], isSideEffecting: false)
        }
    }

    func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        descriptors.first { $0.name == name }
    }

    var allDescriptors: [ToolCatalog.Descriptor] { descriptors }

    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        ToolResult(callID: call.id, status: .ok,
                   outputSummary: "probe-ok", outputDigest: "")
    }
}

final class SubagentChildScopeAndOutcome113Tests: XCTestCase {
    private let runID = UUID()
    private let conversationID = UUID()

    private func handoff(
        childID: UUID,
        captured: N113CapturedChildContexts
    ) -> ChildExecutionHandoff {
        ChildExecutionHandoff(
            identity: ChildExecutionIdentity(
                childID: childID, parentRunID: runID,
                rootTaskID: conversationID, delegateCallID: "delegate-call-1"),
            dispatcher: ChildToolDispatcher(
                descriptorProvider: { _ in nil },
                allDescriptors: { [] },
                dispatch: { call, context in
                    captured.append(context)
                    return ToolResult(callID: call.id, status: .ok,
                                      outputSummary: "dispatched", outputDigest: "")
                }),
            peers: PeerCollaborationHandle(
                register: { _ in },
                unregister: {},
                drain: { [] },
                peers: { _ in [] },
                send: { _, _, _ in SubagentPeerSendReceipt(accepted: false) }))
    }

    private func makeConfiguration() -> (ProviderProfile, ModelProfile) {
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://child-scope.invalid/v1")!)
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "child-scope-fixture",
            displayName: "Child Scope Fixture",
            limits: ModelLimits(contextTokens: 32_768, maxOutputTokens: 2_048),
            capabilities: [.text, .tools])
        return (provider, model)
    }

    private func call(_ id: String, tool: String) throws -> ToolCall {
        try ToolCall(
            id: id, toolName: tool,
            argumentsJSON: Data(#"{"value":"\#(id)"}"#.utf8),
            scope: .local)
    }

    private func context(
        root: URL,
        budget: ChildBudgetContext,
        handoff: ChildExecutionHandoff
    ) -> ToolContext {
        ToolContext(
            runID: runID,
            scope: .local,
            allowedToolNames: ["fixture.scopeA", "fixture.scopeB"],
            workspaceRootURL: root,
            allowedWorkspacePaths: ["reports"],
            cancellation: CancellationToken(),
            childBudget: budget,
            environmentID: "env-child-scope",
            conversationID: conversationID,
            childExecution: handoff,
            frozenEffectiveCatalogNames: ["fixture.scopeA", "fixture.scopeB"])
    }

    func testChildDispatcherReceivesTrustedTaskEnvironmentAndFileScope() async throws {
        let childID = UUID()
        let captured = N113CapturedChildContexts()
        let childHandoff = handoff(childID: childID, captured: captured)
        let probe = N113ProbeExecutor(names: ["fixture.scopeA"])
        let (provider, model) = makeConfiguration()
        let adapter = ScriptedRunAdapter(defaultScript: .init(events: []))
        adapter.enqueue(script: .init(events: [
            .toolRequest(try call("call-scope-a", tool: "fixture.scopeA")),
            .completed(.init(stopReason: .endTurn)),
        ]), forRequest: 0)
        adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "scope retained")),
            .completed(.init(stopReason: .endTurn)),
        ]), forRequest: 1)
        let runner = SubagentRunner(
            provider: provider, model: model, adapter: adapter,
            credentials: ProviderCredentials(), executor: probe)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("n113-child-scope-\(UUID().uuidString)", isDirectory: true)
        let parent = context(
            root: root,
            budget: ChildBudgetContext(maximumIterations: 3, reserve: { true }, finish: {}),
            handoff: childHandoff)

        let outcome = try await runner.runStructured(
            SubagentRequest(task: "capture the trusted child context",
                            maxIterations: 3, kind: .execute, runID: runID),
            context: parent)

        XCTAssertEqual(outcome.status, .completed)
        XCTAssertTrue(outcome.findings.contains("scope retained"))
        let child = try XCTUnwrap(captured.all.first)
        XCTAssertEqual(captured.all.count, 1, "the canonical dispatcher executes the one child call")
        XCTAssertEqual(child.runID, runID, "the child runs under the trusted parent run")
        XCTAssertEqual(child.conversationID, Optional(conversationID),
                       "the child retains the task/owner identity")
        XCTAssertEqual(child.environmentID, Optional("env-child-scope"),
                       "the child retains the resolved Linux environment")
        let childRoot = try XCTUnwrap(child.workspaceRootURL)
        XCTAssertEqual(childRoot.standardizedFileURL, root.standardizedFileURL,
                       "the child retains the resolved workspace root")
        XCTAssertEqual(child.allowedWorkspacePaths, ["reports"],
                       "the child retains the task file ceiling")
        XCTAssertEqual(child.scope, .local, "the child keeps the approved tool scope")
        XCTAssertEqual(child.childExecution?.identity.childID, Optional(childID),
                       "the runtime-issued child identity reaches the dispatcher")
        XCTAssertEqual(child.childExecution?.identity.parentRunID, Optional(runID))
        XCTAssertEqual(child.childExecution?.identity.rootTaskID, Optional(conversationID))
    }

    func testExecutedBatchIsNotUnfinishedAndWrapUpToolRequestIsReported() async throws {
        let captured = N113CapturedChildContexts()
        let childHandoff = handoff(childID: UUID(), captured: captured)
        let probe = N113ProbeExecutor(names: ["fixture.scopeA", "fixture.scopeB"])
        let (provider, model) = makeConfiguration()
        let adapter = ScriptedRunAdapter(defaultScript: .init(events: []))
        adapter.enqueue(script: .init(events: [
            .toolRequest(try call("call-executed", tool: "fixture.scopeA")),
            .completed(.init(stopReason: .endTurn)),
        ]), forRequest: 0)
        // Reserved wrap-up: the model requests another tool and emits no
        // final text. The call must NOT execute and must be the only
        // unfinished item.
        adapter.enqueue(script: .init(events: [
            .toolRequest(try call("call-not-executed", tool: "fixture.scopeB")),
            .completed(.init(stopReason: .endTurn)),
        ]), forRequest: 1)
        let runner = SubagentRunner(
            provider: provider, model: model, adapter: adapter,
            credentials: ProviderCredentials(), executor: probe)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("n113-child-outcome-\(UUID().uuidString)", isDirectory: true)
        let parent = context(
            root: root,
            budget: ChildBudgetContext(maximumIterations: 2, reserve: { true }, finish: {}),
            handoff: childHandoff)

        let outcome = try await runner.runStructured(
            SubagentRequest(task: "produce a bounded child receipt",
                            maxIterations: 2, kind: .execute, runID: runID),
            context: parent)

        XCTAssertEqual(outcome.status, .partial)
        XCTAssertEqual(outcome.iterationsUsed, 2)
        XCTAssertEqual(captured.all.count, 1,
                       "the wrap-up tool request must never be dispatched")
        XCTAssertTrue(outcome.evidence.contains { $0.hasPrefix("fixture.scopeA ") },
                      "the really executed call stays in evidence")
        XCTAssertFalse(outcome.unfinished.contains { $0.hasPrefix("fixture.scopeA ") },
                       "an executed call must never be reported unfinished")
        XCTAssertEqual(outcome.unfinished.count, 1)
        let unfinished = try XCTUnwrap(outcome.unfinished.first)
        XCTAssertTrue(unfinished.hasPrefix("fixture.scopeB "),
                      "only the wrap-up's unexecuted request is unfinished")
        XCTAssertTrue(outcome.findings.contains("reserved wrap-up produced no final text"),
                      "an empty wrap-up is stated honestly instead of presenting prior text as final")
    }

    func testWrapUpTextSettlesUnfinishedWorkAndNoExecutedRouteLeaks() async throws {
        let captured = N113CapturedChildContexts()
        let childHandoff = handoff(childID: UUID(), captured: captured)
        let probe = N113ProbeExecutor(names: ["fixture.scopeA"])
        let (provider, model) = makeConfiguration()
        let adapter = ScriptedRunAdapter(defaultScript: .init(events: []))
        adapter.enqueue(script: .init(events: [
            .toolRequest(try call("call-executed", tool: "fixture.scopeA")),
            .completed(.init(stopReason: .endTurn)),
        ]), forRequest: 0)
        adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "final child handoff")),
            .completed(.init(stopReason: .endTurn)),
        ]), forRequest: 1)
        let runner = SubagentRunner(
            provider: provider, model: model, adapter: adapter,
            credentials: ProviderCredentials(), executor: probe)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("n113-child-summary-\(UUID().uuidString)", isDirectory: true)
        let parent = context(
            root: root,
            budget: ChildBudgetContext(maximumIterations: 2, reserve: { true }, finish: {}),
            handoff: childHandoff)

        let outcome = try await runner.runStructured(
            SubagentRequest(task: "produce a bounded child receipt",
                            maxIterations: 2, kind: .execute, runID: runID),
            context: parent)

        XCTAssertEqual(outcome.status, .partial)
        XCTAssertTrue(outcome.findings.contains("final child handoff"))
        XCTAssertTrue(outcome.unfinished.isEmpty,
                      "a real wrap-up summary leaves no executed batch marked unfinished")
        XCTAssertEqual(captured.all.count, 1)
    }
}
