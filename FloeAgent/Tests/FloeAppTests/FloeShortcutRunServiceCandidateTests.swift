// S3.2 candidate App-host tests for FloeShortcutRunService.
//
// Not registered by this lane (Tests/ and project.yml are root-owned). To
// register: copy into FloeAgent/Tests/FloeAppTests/ and add the file under the
// FloeAppTests target in project.yml, then regenerate with
// scripts/gen_project.sh. The service and DTOs are internal; @testable import
// FloeApp exposes them. These tests are deterministic (no DB, no provider, no
// network, no simulator UI): stores/clock/start/cancel are injected.
//
// The same scenarios already passed in this lane's focused harness
// (138/138 checks, real FloeCore/FloeModels/FloePersistence/FloeSecurity
// modules, Swift 6 strict concurrency, object + SIL compilation).

import XCTest
@testable import FloeApp
import FloeCore
import FloeModels
import FloePersistence

final class FloeShortcutRunServiceCandidateTests: XCTestCase {

    // MARK: Fixtures

    private let conversationID = UUID(uuidString: "3D3D3D3D-0000-4000-8000-000000000001")!
    private let runID = UUID(uuidString: "4E4E4E4E-0000-4000-8000-000000000001")!
    private let providerID = UUID(uuidString: "1B1B1B1B-0000-4000-8000-000000000001")!
    private let modelID = UUID(uuidString: "2C2C2C2C-0000-4000-8000-000000000002")!

    private func providerAndModel() -> (ProviderProfile, ModelProfile) {
        let provider = ProviderProfile(
            id: providerID,
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://example.invalid/v1")!,
            displayName: "Test Provider"
        )
        let model = ModelProfile(
            id: modelID,
            providerID: providerID,
            remoteModelID: "test-model",
            displayName: "Test Model",
            limits: ModelLimits(contextTokens: 8_000, maxOutputTokens: 1_000)
        )
        return (provider, model)
    }

    private func makeRun(state: String, ended: Bool = false) -> RunRecord {
        RunRecord(
            id: runID,
            conversationID: conversationID,
            state: state,
            goal: "Test goal",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: ended ? Date(timeIntervalSince1970: 1_700_000_100) : nil
        )
    }

    private func makeConversation(purpose: ConversationPurpose = .ordinary) -> ConversationRecord {
        ConversationRecord(
            id: conversationID,
            title: "Test Task",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            purpose: purpose
        )
    }

    private func terminal(_ stopReason: String, sequence: Int = 1_000) -> RunEventRecord {
        RunEventRecord(
            runID: runID,
            sequence: sequence,
            kind: .terminal,
            payloadJSON: "{\"stopReason\":\"\(stopReason)\"}"
        )
    }

    // MARK: Fake world

    private final class World: @unchecked Sendable {
        var runs: [UUID: RunRecord] = [:]
        var conversations: [UUID: ConversationRecord] = [:]
        var events: [UUID: [RunEventRecord]] = [:]
        var replies: [UUID: String] = [:]
        var liveOwners: Set<UUID> = []
        var ensureReadyCount = 0
        var startRequests: [FloeShortcutStartRequest] = []
        var cancelCalls: [UUID] = []
        var readerCalls: [UUID] = []
        var pauses: [TimeInterval] = []
        var virtualTime: TimeInterval = 0
        var capabilityEnabled = true
        var cancelSideEffect: ((UUID) -> Void)?
    }

    private func makeService(_ world: World) -> FloeShortcutRunService {
        let pair = providerAndModel()
        return FloeShortcutRunService(deps: FloeShortcutRunDeps(
            ensureReady: { world.ensureReadyCount += 1 },
            capabilityEnabled: { world.capabilityEnabled },
            defaultModel: { (provider: pair.0, model: pair.1) },
            startTask: { request in
                world.startRequests.append(request)
                return FloeRunStartReceipt(runID: UUID(), conversationID: UUID())
            },
            cancelRun: { runID in
                world.cancelCalls.append(runID)
                world.cancelSideEffect?(runID)
            },
            hasLiveOwner: { world.liveOwners.contains($0) },
            loadRun: { world.runs[$0] },
            loadConversation: { world.conversations[$0] },
            recentRunEvents: { runID, limit in
                Array((world.events[runID] ?? []).suffix(limit))
            },
            earlierRunEvents: { runID, sequence, limit in
                Array((world.events[runID] ?? []).filter { $0.sequence < sequence }.suffix(limit))
            },
            latestAssistantText: { runID, _ in
                world.readerCalls.append(runID)
                return world.replies[runID]
            },
            monotonicNow: { world.virtualTime },
            pause: { seconds in
                world.pauses.append(seconds)
                world.virtualTime += seconds
            }
        ))
    }

    private func seedCompleted(
        _ world: World,
        stopReason: String,
        reply: String?,
        prefixEvents: [RunEventRecord] = []
    ) {
        world.runs[runID] = makeRun(state: "completed", ended: true)
        world.conversations[conversationID] = makeConversation()
        world.events[runID] = prefixEvents + [terminal(stopReason)]
        world.replies[runID] = reply
    }

    // MARK: Start

    func testStartRejectsEmptyPromptAfterReadiness() async {
        let world = World()
        let service = makeService(world)
        do {
            _ = try await service.start(prompt: "  ", title: nil)
            XCTFail("empty prompt should throw")
        } catch let error as FloeShortcutRunError {
            XCTAssertEqual(error, .emptyTaskPrompt)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(world.ensureReadyCount, 1)
        XCTAssertTrue(world.startRequests.isEmpty)
    }

    func testStartKeepsPromptForCenterAndRedactsDerivedTitle() async throws {
        let world = World()
        let service = makeService(world)
        let prompt = "请把 password: hunter2xyz 改成新连接并总结"
        _ = try await service.start(prompt: prompt, title: nil)
        let request = try XCTUnwrap(world.startRequests.first)
        XCTAssertEqual(request.goal, prompt, "center owns secret ingress capture")
        XCTAssertTrue(request.goal.contains("hunter2xyz"))
        XCTAssertFalse(request.title.contains("hunter2xyz"), "title must not persist the secret")
        XCTAssertTrue(request.title.contains("⟨redacted⟩"))
        XCTAssertLessThanOrEqual(request.title.count, 40)
    }

    func testStartRedactsExplicitSensitiveTitle() async throws {
        let world = World()
        let service = makeService(world)
        _ = try await service.start(
            prompt: "Connect to the host",
            title: "Authorization: Bearer abcdef123456"
        )
        let title = try XCTUnwrap(world.startRequests.first?.title)
        XCTAssertFalse(title.contains("abcdef123456"))
    }

    func testStartRejectsWithoutDefaultModel() async {
        let world = World()
        let service = FloeShortcutRunService(deps: FloeShortcutRunDeps(
            ensureReady: {},
            capabilityEnabled: { true },
            defaultModel: { nil },
            startTask: { _ in throw FloeShortcutRunError.applicationStillStarting },
            cancelRun: { _ in },
            hasLiveOwner: { _ in false },
            loadRun: { _ in nil },
            loadConversation: { _ in nil },
            recentRunEvents: { _, _ in [] },
            earlierRunEvents: { _, _, _ in [] },
            latestAssistantText: { _, _ in nil },
            monotonicNow: { 0 },
            pause: { _ in }
        ))
        do {
            _ = try await service.start(prompt: "Do work", title: nil)
            XCTFail("missing model should throw")
        } catch let error as FloeShortcutRunError {
            XCTAssertEqual(error, .noDefaultModelConfigured)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testCapabilityDisabledBlocksBeforeReadiness() async {
        let world = World()
        world.capabilityEnabled = false
        let service = makeService(world)
        do {
            _ = try await service.status(runID: runID)
            XCTFail("disabled capability should throw")
        } catch let error as FloeShortcutRunError {
            XCTAssertEqual(error, .shortcutsCapabilityDisabled)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(world.ensureReadyCount, 0)
    }

    // MARK: Status / text

    func testCompletedEndTurnIsFullSuccess() async throws {
        let world = World()
        seedCompleted(world, stopReason: "endTurn", reply: "Final answer.")
        let service = makeService(world)
        let status = try await service.status(runID: runID)
        XCTAssertEqual(status.state, .completed)
        XCTAssertEqual(status.terminalStopReason, .endTurn)
        XCTAssertTrue(status.isFullSuccess)
        XCTAssertTrue(status.finishedPerDurableRecord)
        let result = try await service.textResult(runID: runID)
        XCTAssertEqual(result.text, "Final answer.")
        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(world.readerCalls, [runID])
    }

    func testMaxTokensIsNotFullSuccess() async throws {
        let world = World()
        seedCompleted(world, stopReason: "maxTokens", reply: "Cut short")
        let service = makeService(world)
        let status = try await service.status(runID: runID)
        XCTAssertEqual(status.state, .completed)
        XCTAssertFalse(status.isFullSuccess)
        let result = try await service.textResult(runID: runID)
        guard case .partial(let caveats) = result.completeness else {
            return XCTFail("expected partial")
        }
        XCTAssertEqual(caveats, [.tokenLimitReached])
    }

    func testCancelledTerminalIsCancelledWithPartialText() async throws {
        let world = World()
        seedCompleted(world, stopReason: "cancelled", reply: "Half an answer")
        let service = makeService(world)
        let status = try await service.status(runID: runID)
        XCTAssertEqual(status.state, .cancelled)
        let result = try await service.textResult(runID: runID)
        guard case .partial(let caveats) = result.completeness else {
            return XCTFail("expected partial")
        }
        XCTAssertEqual(caveats, [.cancelledMidRun])
    }

    func testMissingTerminalIsUnavailableAndNeverReadsText() async throws {
        let world = World()
        world.runs[runID] = makeRun(state: "completed", ended: true)
        world.conversations[conversationID] = makeConversation()
        world.replies[runID] = "Orphan"
        let service = makeService(world)
        let status = try await service.status(runID: runID)
        XCTAssertEqual(status.state, .unavailable)
        XCTAssertEqual(status.unavailableReason, .terminalMissingOrCorrupt)
        XCTAssertFalse(status.isFullSuccess)
        let result = try await service.textResult(runID: runID)
        if case .untrustworthy = result.completeness {} else {
            XCTFail("expected untrustworthy")
        }
        XCTAssertTrue(world.readerCalls.isEmpty)
    }

    func testNoFinalTextStepIsPartialNotFinal() async throws {
        let world = World()
        seedCompleted(
            world, stopReason: "endTurn", reply: "Tool step",
            prefixEvents: [RunEventRecord(
                runID: runID, sequence: 1, kind: .error,
                payloadJSON: "{\"message\":\"noFinalText\"}"
            )]
        )
        let service = makeService(world)
        let result = try await service.textResult(runID: runID)
        guard case .partial(let caveats) = result.completeness else {
            return XCTFail("expected partial")
        }
        XCTAssertEqual(caveats, [.stepsOnlyFinalMissing])
        XCTAssertEqual(result.text, "Tool step")
    }

    func testNotesConversationIsRejectedWithoutReading() async throws {
        let world = World()
        world.runs[runID] = makeRun(state: "completed", ended: true)
        world.conversations[conversationID] = makeConversation(purpose: .notes)
        world.replies[runID] = "Notes text"
        let service = makeService(world)
        let status = try await service.status(runID: runID)
        XCTAssertEqual(status.unavailableReason, .notesConversation)
        _ = try await service.textResult(runID: runID)
        XCTAssertTrue(world.readerCalls.isEmpty)
    }

    func testExactRunIsolationWithLaterRun() async throws {
        let laterRun = UUID()
        let world = World()
        seedCompleted(world, stopReason: "endTurn", reply: "First answer")
        world.runs[laterRun] = RunRecord(
            id: laterRun, conversationID: conversationID, state: "completed",
            goal: "Later goal", startedAt: Date(timeIntervalSince1970: 1_700_000_200),
            endedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        world.events[laterRun] = [
            RunEventRecord(
                runID: laterRun, sequence: 1, kind: .terminal,
                payloadJSON: "{\"stopReason\":\"endTurn\"}"
            )
        ]
        world.replies[laterRun] = "Later answer"
        let service = makeService(world)
        let first = try await service.textResult(runID: runID)
        XCTAssertEqual(first.text, "First answer")
        XCTAssertEqual(world.readerCalls, [runID])
        let later = try await service.textResult(runID: laterRun)
        XCTAssertEqual(later.text, "Later answer")
    }

    // MARK: Wait

    func testWaitReturnsImmediatelyOnTerminal() async throws {
        let world = World()
        seedCompleted(world, stopReason: "endTurn", reply: "Done")
        let service = makeService(world)
        let outcome = try await service.wait(runID: runID, timeout: 20)
        guard case .terminalReached(let status) = outcome else {
            return XCTFail("expected terminal")
        }
        XCTAssertEqual(status.state, .completed)
        XCTAssertTrue(world.pauses.isEmpty)
        XCTAssertTrue(world.cancelCalls.isEmpty)
    }

    func testWaitTimesOutWithoutCancelling() async throws {
        let world = World()
        world.runs[runID] = makeRun(state: "streamingModel")
        world.conversations[conversationID] = makeConversation()
        let service = makeService(world)
        let outcome = try await service.wait(runID: runID, timeout: nil)
        guard case .budgetExhausted(let status) = outcome else {
            return XCTFail("expected budget exhausted")
        }
        XCTAssertEqual(status.state, .running)
        XCTAssertTrue(world.cancelCalls.isEmpty)
        XCTAssertEqual(world.pauses.reduce(0, +), FloeShortcutRunService.defaultWaitBudget)
    }

    func testWaitReturnsPromptlyForApproval() async throws {
        let world = World()
        world.runs[runID] = makeRun(state: "waitingApproval")
        world.conversations[conversationID] = makeConversation()
        let service = makeService(world)
        let outcome = try await service.wait(runID: runID, timeout: 20)
        guard case .userActionRequired(let status) = outcome else {
            return XCTFail("expected user action")
        }
        XCTAssertTrue(status.requiresUserAction)
        XCTAssertTrue(world.pauses.isEmpty)
    }

    // MARK: Cancel

    func testCancelAlreadyFinishedDoesNotRequest() async throws {
        let world = World()
        seedCompleted(world, stopReason: "endTurn", reply: "Done")
        let service = makeService(world)
        let result = try await service.cancel(runID: runID)
        XCTAssertFalse(result.requested)
        XCTAssertTrue(result.alreadyFinished)
        XCTAssertEqual(result.confirmedTerminalState, .completed)
        XCTAssertTrue(world.cancelCalls.isEmpty)
    }

    func testCancelWithoutLiveOwnerDoesNotFabricate() async throws {
        let world = World()
        world.runs[runID] = makeRun(state: "checkpointed")
        world.conversations[conversationID] = makeConversation()
        let service = makeService(world)
        let result = try await service.cancel(runID: runID)
        XCTAssertFalse(result.requested)
        XCTAssertEqual(result.status.state, .checkpointed)
        XCTAssertTrue(world.cancelCalls.isEmpty)
    }

    func testCancelConfirmsCancelled() async throws {
        let world = World()
        world.runs[runID] = makeRun(state: "streamingModel")
        world.conversations[conversationID] = makeConversation()
        world.liveOwners.insert(runID)
        world.cancelSideEffect = { runID in
            world.runs[runID]?.state = "completed"
            world.events[runID] = [self.terminal("cancelled")]
        }
        let service = makeService(world)
        let result = try await service.cancel(runID: runID)
        XCTAssertTrue(result.requested)
        XCTAssertEqual(result.confirmedTerminalState, .cancelled)
    }

    func testCancelCompletionRaceReportsCompleted() async throws {
        let world = World()
        world.runs[runID] = makeRun(state: "executingTool")
        world.conversations[conversationID] = makeConversation()
        world.liveOwners.insert(runID)
        world.cancelSideEffect = { runID in
            world.runs[runID]?.state = "completed"
            world.events[runID] = [self.terminal("endTurn")]
        }
        let service = makeService(world)
        let result = try await service.cancel(runID: runID)
        XCTAssertTrue(result.requested)
        XCTAssertEqual(result.confirmedTerminalState, .completed)
    }
}
