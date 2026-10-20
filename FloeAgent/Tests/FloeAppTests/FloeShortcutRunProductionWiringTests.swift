// S3-C production-wiring acceptance for the exact-run App Intent service.
//
// Unlike the injected-service suites, this exercises the REAL
// `AppEnvironment.floeShortcutRunService()` factory and the production
// read/start readiness split against an isolated in-memory AppEnvironment:
// its own migrated database, stores and ConversationCenter. No launched App
// data, user defaults, model configuration, Keychain credential, provider or
// task is read or written. The isolated launch marker only skips shared
// launch maintenance; it does not replace the factory, stores or readiness
// methods under test.

#if canImport(UIKit) && DEBUG
import XCTest
@testable import FloeApp
import FloeCore
import FloeModels
import FloePersistence

@MainActor
final class FloeShortcutRunProductionWiringTests: XCTestCase {

    private func makeIsolatedEnvironment() async throws -> AppEnvironment {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        environment.markIsolatedLaunchReadyForTesting()
        return environment
    }

    private func seedCompletedRun(
        in environment: AppEnvironment,
        conversationID: UUID,
        runID: UUID,
        answer: String
    ) async throws {
        try await environment.conversationStore.saveConversation(.init(
            id: conversationID, title: "Isolated S3-C task",
            createdAt: Date(), updatedAt: Date()))
        try await environment.runStore.saveRun(.init(
            id: runID, conversationID: conversationID, state: "completed",
            goal: "Isolated S3-C goal", startedAt: Date(), endedAt: Date()))
        let messageID = UUID()
        try await environment.conversationStore.appendMessage(.init(
            id: messageID, conversationID: conversationID, role: "assistant",
            content: answer, createdAt: Date(), runID: runID))
        _ = try await environment.runStore.appendEvent(
            runID: runID, kind: .assistantText,
            payloadJSON: "{\"text\":\"\(answer)\"}")
        // The production runtime writes the terminal marker only after the
        // final row persisted, carrying that exact message id.
        _ = try await environment.runStore.appendEvent(
            runID: runID, kind: .terminal,
            payloadJSON: "{\"stopReason\":\"endTurn\",\"finalMessageID\":\"\(messageID.uuidString)\"}")
    }

    func testProductionFactoryReadsExactRunWithoutModelConfiguration() async throws {
        let environment = try await makeIsolatedEnvironment()
        let conversationID = UUID(), runID = UUID()
        try await seedCompletedRun(
            in: environment, conversationID: conversationID,
            runID: runID, answer: "Production-wired final answer")

        // This environment has no provider or model configuration. Reading an
        // existing run must still work through the production factory.
        let service = environment.floeShortcutRunService()
        let status = try await service.status(runID: runID)
        XCTAssertEqual(status.runID, Optional(runID))
        XCTAssertEqual(status.conversationID, Optional(conversationID))
        XCTAssertEqual(status.state, .completed)
        XCTAssertTrue(status.finalReplyProven)
        XCTAssertTrue(status.isFullSuccess)

        let result = try await service.textResult(runID: runID)
        XCTAssertEqual(result.text, "Production-wired final answer")
        XCTAssertEqual(result.completeness, .complete)
    }

    func testProductionBridgeReadsOwnershipFromTheEnvironmentStore() async throws {
        let environment = try await makeIsolatedEnvironment()
        let conversationID = UUID(), runID = UUID()
        try await seedCompletedRun(
            in: environment, conversationID: conversationID,
            runID: runID, answer: "Owned answer")

        let entity = try await FloeShortcutRunIntentBridge.snapshot(
            runID: runID,
            expectedConversationID: conversationID,
            environment: { environment })
        XCTAssertEqual(entity.runID, runID.uuidString)
        XCTAssertEqual(entity.conversationID, conversationID.uuidString)
        XCTAssertEqual(entity.state, .completed)

        do {
            _ = try await FloeShortcutRunIntentBridge.snapshot(
                runID: runID,
                expectedConversationID: UUID(),
                environment: { environment })
            XCTFail("a reference that cannot prove the durable owner must be rejected")
        } catch let error as FloeShortcutActionError {
            XCTAssertEqual(error.message, FloeL10n.l("shortcuts.run.error.ownership"))
        }
    }

    func testProductionFullStartReadinessIsSeparateFromReadAndCreatesNothing() async throws {
        let environment = try await makeIsolatedEnvironment()
        let service = environment.floeShortcutRunService()

        // A read performs only the durable read readiness and must not count
        // as the full start preparation.
        _ = try await service.status(runID: UUID())
        XCTAssertEqual(environment.externalAutomationExecutionCount, 0)

        // The legacy run entry (FloeShortcutsRuntime.run) still joins this
        // full start preparation before resolving a model or creating a task.
        // Calling it here proves the production layer runs on the isolated
        // graph without starting provider work or creating a task/run.
        try await environment.ensureReadyForExternalAutomation()
        XCTAssertEqual(environment.externalAutomationExecutionCount, 1)
        let conversations = try await environment.conversationStore.conversations()
        let nonTerminalRuns = try await environment.runStore.nonTerminalRuns()
        XCTAssertTrue(conversations.isEmpty)
        XCTAssertTrue(nonTerminalRuns.isEmpty)
    }
}
#endif
