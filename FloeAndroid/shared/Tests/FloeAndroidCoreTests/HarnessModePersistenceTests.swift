// SPDX-License-Identifier: MPL-2.0
//
// Mode-boundary tests for the G02 Harness registration lane. AUTHORED, NOT
// EXECUTED here (no shared Swift/Gradle build in this task).
//
// The explicit Agent/Chat split is now persisted ADDITIVELY: the original
// `RunLaunchMode`/`ConversationMode` contract keeps chat|plan|goal, while
// `runs.explicit_execution_mode` / `pending_user_inputs.explicit_execution_mode`
// / `AgentCheckpoint.explicitExecutionMode` carry the composer's real
// agent|chat|plan|goal selection when the caller provided one. Agent/Chat are
// NOT permission tiers: ordinary Chat and Agent share the persisted task tool
// chain (the previous empty Chat `toolCeiling` is gone), and a missing value is
// never relabelled as Agent. See `ExplicitExecutionModeTests` for the
// persistence/wire contract.
//
// What this file DOES pin is the safe part that must not regress:
//   * Plan may perform only the three exact registered memory writes;
//   * forged memory descriptors never inherit the Plan exception;
//   * the temporary ceiling never admits memory/history tools;
//   * the visible-task spawn tool stays main-run only and is not registered
//     without its real producer.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeAgentRuntime

final class HarnessModePersistenceTests: XCTestCase {

    private func descriptor(
        name: String,
        toolDescription: String = "mode boundary fixture",
        riskLabels: Set<RiskLabel>,
        isSideEffecting: Bool,
        effect: ToolEffect,
        requiresHostScope: Bool = false,
        boundary: ToolExecutionBoundary = .any
    ) -> ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: name,
            toolDescription: toolDescription,
            parametersJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#,
            riskLabels: riskLabels,
            isSideEffecting: isSideEffecting,
            effect: effect,
            requiresHostScope: requiresHostScope,
            executionBoundary: boundary
        )
    }

    private func memoryWriteDescriptor(
        _ name: String,
        riskLabels: Set<RiskLabel> = [.persistsPersonalData],
        isSideEffecting: Bool = true,
        effect: ToolEffect = .internalState,
        boundary: ToolExecutionBoundary = .any
    ) -> ToolCatalog.Descriptor {
        descriptor(
            name: name,
            riskLabels: riskLabels,
            isSideEffecting: isSideEffecting,
            effect: effect,
            boundary: boundary
        )
    }

    func testPlanAllowsOnlyTheExactRegisteredMemoryWrites() {
        let policy = PlanToolPolicy()
        for name in [
            MemoryRememberTool.name, MemoryUpdateTool.name, MemoryForgetTool.name,
        ] {
            if case .failure(let error) = policy.decision(for: memoryWriteDescriptor(name)) {
                XCTFail("\(name) should keep its exact Plan exception: \(error)")
            }
        }
        // Same names with a broader authority never inherit the exception.
        if case .success = policy.decision(for: memoryWriteDescriptor(
            MemoryRememberTool.name,
            riskLabels: [.persistsPersonalData, .writesFiles]
        )) {
            XCTFail("A memory write carrying an extra risk label must not pass Plan")
        }
        if case .success = policy.decision(for: memoryWriteDescriptor(
            MemoryRememberTool.name, isSideEffecting: false
        )) {
            XCTFail("A memory write that denies its side effect must not pass Plan")
        }
        if case .success = policy.decision(for: memoryWriteDescriptor(
            MemoryRememberTool.name, effect: .mutating
        )) {
            XCTFail("A memory write relabelled as external mutation must not pass Plan")
        }
        // Read-only memory lookups stay inside Plan's ordinary read contract.
        for name in [MemorySearchTool.name, MemoryRecallTool.name, MemoryListTool.name] {
            if case .failure(let error) = policy.decision(for: descriptor(
                name: name,
                riskLabels: [],
                isSideEffecting: false,
                effect: .readOnly
            )) {
                XCTFail("\(name) should remain a Plan read: \(error)")
            }
        }
    }

    func testPlanDoesNotAdmitTheSideEffectingConversationSpawn() {
        let spawn = descriptor(
            name: ConversationSpawnTool.name,
            riskLabels: [.persistsPersonalData],
            isSideEffecting: true,
            effect: .internalState,
            boundary: .mainRunOnly
        )
        guard case .failure(let error) = PlanToolPolicy().decision(for: spawn) else {
            return XCTFail("conversation.spawn must never execute in Plan")
        }
        XCTAssertEqual(error.reason, .internalStateNotModelCallable)
    }

    func testTemporaryCeilingNeverAdmitsMemoryOrConversationHistory() {
        let memoryRead = descriptor(
            name: MemoryRecallTool.name,
            riskLabels: [],
            isSideEffecting: false,
            effect: .readOnly
        )
        let memoryWrite = memoryWriteDescriptor(MemoryRememberTool.name)
        let historyRead = descriptor(
            name: ConversationReadTool.name,
            riskLabels: [.persistsPersonalData],
            isSideEffecting: false,
            effect: .readOnly
        )
        let spawn = descriptor(
            name: ConversationSpawnTool.name,
            riskLabels: [.persistsPersonalData],
            isSideEffecting: true,
            effect: .internalState,
            boundary: .mainRunOnly
        )
        for candidate in [memoryRead, memoryWrite, historyRead, spawn] {
            XCTAssertNil(TemporaryChatToolPolicy.readOnlyDescriptor(candidate),
                         "temporary chat must refuse \(candidate.name)")
        }
        // The public web pair is still the one admitted family: this pins that
        // the check above is not simply refusing everything.
        let fetch = descriptor(
            name: "web.fetch",
            riskLabels: [.networkAccess],
            isSideEffecting: false,
            effect: .readOnly
        )
        XCTAssertNotNil(TemporaryChatToolPolicy.readOnlyDescriptor(fetch))
    }

    func testSpawnIsMainRunOnlyAndRefusesChildOrForgedContexts() async throws {
        XCTAssertEqual(ConversationSpawnTool.executionBoundary, .mainRunOnly)
        XCTAssertEqual(ConversationSearchTool.toolEffect, .readOnly)
        XCTAssertFalse(ConversationSearchTool.isSideEffecting)
        XCTAssertEqual(ConversationReadTool.toolEffect, .readOnly)
        XCTAssertEqual(ConversationListTool.toolEffect, .readOnly)
        XCTAssertEqual(ConversationSpawnTool.toolEffect, .internalState)
        XCTAssertTrue(ConversationSpawnTool.isSideEffecting)

        let conversationID = UUID()
        let workspaceID = UUID()
        let tool = ConversationSpawnTool(
            authorize: { context, target in
                guard context.conversationID == conversationID,
                      target == nil || target == conversationID else { return nil }
                return ConversationHistoryScope(
                    conversationID: conversationID, workspaceID: workspaceID)
            },
            hasExplicitUserAuthority: { _ in true },
            spawner: { request in
                ConversationSpawnResult(
                    conversationID: UUID(),
                    title: request.title,
                    workspaceID: request.workspaceID,
                    wasCreated: false
                )
            }
        )
        let runID = UUID()
        let arguments = ConversationSpawnTool.Arguments(title: "new task", objective: "objective")

        let childBudget = ChildBudgetContext(
            maximumIterations: 1,
            reserve: { true },
            finish: {}
        )
        let childContext = ToolContext(
            runID: runID,
            cancellation: CancellationToken(),
            conversationID: conversationID,
            childBudget: childBudget
        )
        do {
            _ = try await tool.execute(arguments, context: childContext)
            XCTFail("A delegated child must never spawn a user-visible task")
        } catch let error as FloeError {
            XCTAssertTrue(error.reason.contains("main-run only"))
        }

        // A main-run-shaped context still needs the runtime-issued call origin;
        // metadata alone (`childBudget == nil`) cannot authorize the side effect.
        let forgedMainContext = ToolContext(
            runID: runID,
            cancellation: CancellationToken(),
            conversationID: conversationID
        )
        do {
            _ = try await tool.execute(arguments, context: forgedMainContext)
            XCTFail("A reconstructed context without a call origin must be refused")
        } catch let error as FloeError {
            XCTAssertTrue(error.reason.contains("main-run only"))
        }
    }

    func testSpawnWithoutAProducerIsNotRegistered() {
        let reader = EmptyHistoryReader()
        let registry = ToolRunnerRegistry()
        registerConversationTools(
            registry: registry,
            reader: reader,
            authorize: { _, _ in nil as ConversationHistoryScope? }
        )
        XCTAssertNil(registry.descriptor(named: ConversationSpawnTool.name))
        XCTAssertNil(registry.runner(named: ConversationSpawnTool.name))
    }
}

private struct EmptyHistoryReader: ConversationHistoryReader {
    func search(_ request: ConversationSearchRequest) async throws -> [ConversationSearchHit] { [] }
    func read(_ request: ConversationPageRequest) async throws -> ConversationHistoryPage {
        ConversationHistoryPage(conversationID: request.conversationID, messages: [])
    }
    func readMessages(ids: [UUID]) async throws -> [ConversationHistoryMessage] { [] }
    func list(_ request: ConversationListRequest) async throws -> [ConversationListEntry] { [] }
}
