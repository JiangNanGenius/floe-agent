// S3-C focused tests for the exact-run App Intent service.
//
// These tests inject deterministic stores/clock/start/cancel so the service's
// ownership, terminal-state, bounded-wait and cancellation semantics are
// exercised without a provider, network, database or Simulator UI. The real
// persistence/runtime path is covered by the companion SQLite-backed suite.

import XCTest
@testable import FloeApp
import FloeCore
import FloeModels
import FloePersistence

final class FloeShortcutRunServiceTests: XCTestCase {

    // MARK: Fixtures

    private let conversationID = UUID(uuidString: "3D3D3D3D-0000-4000-8000-000000000001")!
    private let runID = UUID(uuidString: "4E4E4E4E-0000-4000-8000-000000000001")!
    private let providerID = UUID(uuidString: "1B1B1B1B-0000-4000-8000-000000000001")!
    private let modelID = UUID(uuidString: "2C2C2C2C-0000-4000-8000-000000000002")!

    private func providerAndModel() -> (provider: ProviderProfile, model: ModelProfile) {
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

    private func makeConversation(
        purpose: ConversationPurpose = .ordinary
    ) -> ConversationRecord {
        ConversationRecord(
            id: conversationID,
            title: "Test Task",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            purpose: purpose
        )
    }

    /// Production-shape terminal marker. The runtime only ever adds
    /// `finalMessageID` after the referenced assistant row actually persisted
    /// (normal save) or a real verification CONFIRM bound the sealed draft.
    private func terminal(
        _ stopReason: String,
        sequence: Int = 1_000,
        forRun targetRun: UUID? = nil,
        finalMessageID: UUID? = nil
    ) -> RunEventRecord {
        let payload: String
        if let finalMessageID {
            payload = "{\"stopReason\":\"\(stopReason)\",\"finalMessageID\":\"\(finalMessageID.uuidString)\"}"
        } else {
            payload = "{\"stopReason\":\"\(stopReason)\"}"
        }
        return RunEventRecord(
            runID: targetRun ?? runID,
            sequence: sequence,
            kind: .terminal,
            payloadJSON: payload
        )
    }

    /// A persisted assistant row keyed by its message id, mirroring the
    /// production reader's run + owner + role predicate.
    private struct StoredRow {
        var runID: UUID
        var conversationID: UUID
        var role: String
        var text: String
    }

    // MARK: Fake world

    private final class World: @unchecked Sendable {
        var runs: [UUID: RunRecord] = [:]
        var conversations: [UUID: ConversationRecord] = [:]
        var events: [UUID: [RunEventRecord]] = [:]
        /// Rows keyed by message id, exactly like the production reader's
        /// `WHERE id = ? AND run_id = ? AND conversation_id = ? AND role =
        /// 'assistant'` predicate. There is no "latest reply per run" table:
        /// consumers must present a proven id.
        var rows: [UUID: StoredRow] = [:]
        var liveOwners: Set<UUID> = []
        var readiness: [FloeShortcutAccess] = []
        var defaultModelCalls = 0
        var startRequests: [FloeShortcutStartRequest] = []
        var cancelCalls: [UUID] = []
        var readerCalls: [(runID: UUID, messageID: UUID)] = []
        var pauses: [TimeInterval] = []
        var virtualTime: TimeInterval = 0
        var pauseDelay: Duration?
        var capabilityEnabled = true
        var cancelSideEffect: ((UUID) -> Void)?
    }

    private func makeService(_ world: World, modelAvailable: Bool = true) -> FloeShortcutRunService {
        let pair = providerAndModel()
        return FloeShortcutRunService(deps: FloeShortcutRunDeps(
            ensureReady: { access in world.readiness.append(access) },
            capabilityEnabled: { world.capabilityEnabled },
            defaultModel: {
                world.defaultModelCalls += 1
                return modelAvailable ? (provider: pair.provider, model: pair.model) : nil
            },
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
            provenFinalReplyText: { runID, conversationID, messageID in
                world.readerCalls.append((runID, messageID))
                guard let row = world.rows[messageID],
                      row.runID == runID,
                      row.conversationID == conversationID,
                      row.role == "assistant" else { return nil }
                return row.text
            },
            monotonicNow: { world.virtualTime },
            pause: { seconds in
                world.pauses.append(seconds)
                world.virtualTime += seconds
                if let delay = world.pauseDelay {
                    try? await Task.sleep(for: delay)
                } else {
                    await Task.yield()
                }
            }
        ))
    }

    /// Seeds a completed run exactly as the production completion path does:
    /// the final assistant row persists first, then the terminal marker
    /// carries that row's exact message id. `provesFinalReply: false` models a
    /// legacy/corrupt terminal without the identity field.
    @discardableResult
    private func seedCompleted(
        _ world: World,
        stopReason: String,
        reply: String?,
        prefixEvents: [RunEventRecord] = [],
        provesFinalReply: Bool = true
    ) -> UUID? {
        world.runs[runID] = makeRun(state: "completed", ended: true)
        world.conversations[conversationID] = makeConversation()
        var events = prefixEvents
        var finalMessageID: UUID?
        if let reply {
            let messageID = UUID()
            finalMessageID = messageID
            world.rows[messageID] = StoredRow(
                runID: runID, conversationID: conversationID, role: "assistant", text: reply)
            events.append(RunEventRecord(
                runID: runID, sequence: 999, kind: .assistantText,
                payloadJSON: "{\"text\":\"\(reply)\"}"))
        }
        world.events[runID] = events + [
            terminal(stopReason, finalMessageID: provesFinalReply ? finalMessageID : nil)
        ]
        return finalMessageID
    }

    /// Seeds a persisted assistant row that carries NO terminal proof; the
    /// reader must never touch it without a proven id.
    @discardableResult
    private func seedUnprovenRow(
        _ world: World,
        run: UUID? = nil,
        text: String,
        role: String = "assistant"
    ) -> UUID {
        let messageID = UUID()
        world.rows[messageID] = StoredRow(
            runID: run ?? runID,
            conversationID: conversationID,
            role: role,
            text: text
        )
        return messageID
    }

    // MARK: Readiness

    func testReadPathsDoNotRequireModelConfiguration() async throws {
        let world = World()
        seedCompleted(world, stopReason: "endTurn", reply: "Final answer.")
        let service = makeService(world, modelAvailable: false)

        let status = try await service.status(runID: runID)
        XCTAssertEqual(status.state, .completed)
        let text = try await service.textResult(runID: runID)
        XCTAssertEqual(text.text, "Final answer.")
        _ = try await service.wait(runID: runID, timeout: 1)
        _ = try await service.cancel(runID: runID)

        XCTAssertEqual(world.readiness, [.read, .read, .read, .read])
        XCTAssertEqual(world.defaultModelCalls, 0,
            "read/status/wait/cancel must not require a usable model configuration")
    }

    func testStartUsesStartReadinessAndRejectsWithoutModel() async {
        let world = World()
        let service = makeService(world, modelAvailable: false)
        do {
            _ = try await service.start(prompt: "Do work", title: nil)
            XCTFail("missing model should throw")
        } catch let error as FloeShortcutRunError {
            XCTAssertEqual(error, .noDefaultModelConfigured)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(world.readiness, [.start])
        XCTAssertEqual(world.defaultModelCalls, 1)
        XCTAssertTrue(world.startRequests.isEmpty)
    }

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
        XCTAssertEqual(world.readiness, [.start])
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
        XCTAssertTrue(world.readiness.isEmpty)
        XCTAssertEqual(world.defaultModelCalls, 0)
    }

    // MARK: Status / text

    func testCompletedEndTurnIsFullSuccess() async throws {
        let world = World()
        let finalID = seedCompleted(world, stopReason: "endTurn", reply: "Final answer.")
        let service = makeService(world)
        let status = try await service.status(runID: runID)
        XCTAssertEqual(status.state, .completed)
        XCTAssertEqual(status.terminalStopReason, .endTurn)
        XCTAssertTrue(status.isFullSuccess)
        XCTAssertTrue(status.finishedPerDurableRecord)
        XCTAssertTrue(status.finalReplyProven)
        let result = try await service.textResult(runID: runID)
        XCTAssertEqual(result.text, "Final answer.")
        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(world.readerCalls.map(\.runID), [runID])
        XCTAssertEqual(world.readerCalls.map(\.messageID), [try XCTUnwrap(finalID)],
            "the read must resolve exactly the marker's proven message id")
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
        seedUnprovenRow(world, text: "Orphan")
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

    /// The production runtime writes `noFinalText` (completion-critical) after
    /// persisting any pre-tool step and before the terminal marker. Even when
    /// an "I will check" step row exists, it is never returned as the result.
    func testNoFinalTextStepIsNeverReturnedAsFinal() async throws {
        let world = World()
        seedCompleted(
            world, stopReason: "endTurn", reply: "I will check",
            prefixEvents: [RunEventRecord(
                runID: runID, sequence: 900, kind: .error,
                payloadJSON: "{\"message\":\"noFinalText\"}"
            )]
        )
        let service = makeService(world)
        let result = try await service.textResult(runID: runID)
        XCTAssertNil(result.text)
        XCTAssertEqual(result.completeness, .absent(.noFinalText))
        XCTAssertTrue(world.readerCalls.isEmpty,
            "an explicit no-final-text run must not fall back to a step row")
        let status = try await service.status(runID: runID)
        XCTAssertTrue(status.hasNoFinalTextError)
        XCTAssertFalse(status.isFullSuccess)
    }

    /// Even a completed header can lack the `noFinalText` marker when a
    /// corrupt/legacy run ended. If the newest flushed text precedes a tool
    /// event, that row is a pre-tool step ("I will check"), not the answer.
    func testCompletedRunWithOnlyPreToolStepIsNotText() async throws {
        let world = World()
        world.runs[runID] = makeRun(state: "completed", ended: true)
        world.conversations[conversationID] = makeConversation()
        seedUnprovenRow(world, text: "I will check")
        world.events[runID] = [
            RunEventRecord(runID: runID, sequence: 900, kind: .assistantText,
                           payloadJSON: "{\"text\":\"I will check\"}"),
            RunEventRecord(runID: runID, sequence: 901, kind: .toolRequest,
                           payloadJSON: "{}"),
            RunEventRecord(runID: runID, sequence: 902, kind: .toolResult,
                           payloadJSON: "{}"),
            terminal("endTurn")
        ]
        let service = makeService(world)
        let status = try await service.status(runID: runID)
        XCTAssertEqual(status.state, .completed)
        XCTAssertFalse(status.finalReplyProven)
        let result = try await service.textResult(runID: runID)
        XCTAssertNil(result.text)
        XCTAssertEqual(result.completeness, .absent(.finalReplyUnproven))
        XCTAssertTrue(world.readerCalls.isEmpty)
    }

    func testNotesConversationIsRejectedWithoutReading() async throws {
        let world = World()
        world.runs[runID] = makeRun(state: "completed", ended: true)
        world.conversations[conversationID] = makeConversation(purpose: .notes)
        seedUnprovenRow(world, text: "Notes text")
        let service = makeService(world)
        let status = try await service.status(runID: runID)
        XCTAssertEqual(status.unavailableReason, .notesConversation)
        _ = try await service.textResult(runID: runID)
        XCTAssertTrue(world.readerCalls.isEmpty)
    }

    func testTemporaryConversationIsRejectedWithoutReading() async throws {
        let world = World()
        world.runs[runID] = makeRun(state: "completed", ended: true)
        world.conversations[conversationID] = makeConversation(purpose: .temporary)
        seedUnprovenRow(world, text: "Temporary text")
        let service = makeService(world)
        let status = try await service.status(runID: runID)
        XCTAssertEqual(status.unavailableReason, .temporaryConversation)
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
        let laterRow = seedUnprovenRow(world, run: laterRun, text: "Later answer")
        world.events[laterRun] = [
            RunEventRecord(
                runID: laterRun, sequence: 1, kind: .assistantText,
                payloadJSON: "{\"text\":\"Later answer\"}"
            ),
            terminal("endTurn", sequence: 2, forRun: laterRun, finalMessageID: laterRow)
        ]
        let service = makeService(world)
        let first = try await service.textResult(runID: runID)
        XCTAssertEqual(first.text, "First answer")
        XCTAssertEqual(world.readerCalls.map(\.runID), [runID])
        let later = try await service.textResult(runID: laterRun)
        XCTAssertEqual(later.text, "Later answer")
        XCTAssertEqual(Set(world.readerCalls.map(\.runID)), [runID, laterRun],
            "each run's read resolves only its own proven message id")
    }

    func testInterruptedRunReportsRecoveredStateWithoutExportingStepText() async throws {
        let world = World()
        world.runs[runID] = makeRun(state: "interrupted", ended: true)
        world.conversations[conversationID] = makeConversation()
        seedUnprovenRow(world, text: "I will check")
        let service = makeService(world)
        let status = try await service.status(runID: runID)
        XCTAssertEqual(status.state, .interrupted)
        XCTAssertTrue(status.finishedPerDurableRecord)
        XCTAssertFalse(status.isFullSuccess)
        let result = try await service.textResult(runID: runID)
        XCTAssertNil(result.text)
        XCTAssertEqual(result.completeness, .absent(.finalReplyNotPersisted))
        XCTAssertTrue(world.readerCalls.isEmpty,
            "a recovery terminal has no final-reply proof; a step row is not exported")
    }

    func testFailedRunAfterToolStepExportsNoIntermediateText() async throws {
        let world = World()
        world.runs[runID] = makeRun(state: "failed", ended: true)
        world.conversations[conversationID] = makeConversation()
        seedUnprovenRow(world, text: "I will check")
        let service = makeService(world)
        let status = try await service.status(runID: runID)
        XCTAssertEqual(status.state, .failed)
        XCTAssertFalse(status.finalReplyProven)
        let result = try await service.textResult(runID: runID)
        XCTAssertNil(result.text)
        XCTAssertEqual(result.completeness, .absent(.finalReplyNotPersisted))
        XCTAssertTrue(world.readerCalls.isEmpty)
    }

    func testCancelledRunWithoutCompletionProofExportsNoStepText() async throws {
        let world = World()
        world.runs[runID] = makeRun(state: "cancelled", ended: true)
        world.conversations[conversationID] = makeConversation()
        seedUnprovenRow(world, text: "I will check")
        let service = makeService(world)
        let result = try await service.textResult(runID: runID)
        XCTAssertNil(result.text)
        XCTAssertEqual(result.completeness, .absent(.finalReplyNotPersisted))
    }

    /// A completed header whose terminal marker carries no final-message
    /// identity (legacy/corrupt producer) is an honest absence even when an
    /// assistant row exists — the reader never falls back to "latest row".
    func testCompletedTerminalWithoutIdentityMarkerIsUnproven() async throws {
        let world = World()
        seedCompleted(
            world, stopReason: "endTurn", reply: "Maybe the answer",
            provesFinalReply: false
        )
        let service = makeService(world)
        let status = try await service.status(runID: runID)
        XCTAssertEqual(status.state, .completed)
        XCTAssertFalse(status.finalReplyProven)
        XCTAssertFalse(status.isFullSuccess)
        let result = try await service.textResult(runID: runID)
        XCTAssertNil(result.text)
        XCTAssertEqual(result.completeness, .absent(.finalReplyUnproven))
        XCTAssertTrue(world.readerCalls.isEmpty,
            "no proof means no read at all; the latest row is never a substitute")
    }

    /// A terminal marker whose id resolves outside this run's assistant rows
    /// (a forged or cross-run id) must yield an absence, not the other row.
    func testMarkerPointingToAnotherRowsContentIsNeverSubstituted() async throws {
        let otherRun = UUID()
        let world = World()
        let foreignRow = seedUnprovenRow(world, run: otherRun, text: "Another run's answer")
        world.runs[runID] = makeRun(state: "completed", ended: true)
        world.conversations[conversationID] = makeConversation()
        seedUnprovenRow(world, text: "I will check")
        world.events[runID] = [
            RunEventRecord(runID: runID, sequence: 999, kind: .assistantText,
                           payloadJSON: "{\"text\":\"I will check\"}"),
            terminal("endTurn", finalMessageID: foreignRow)
        ]
        let service = makeService(world)
        let result = try await service.textResult(runID: runID)
        XCTAssertNil(result.text)
        XCTAssertEqual(result.completeness, .absent(.finalReplyUnproven),
            "the proven id must resolve inside this exact run and owner")
        XCTAssertEqual(world.readerCalls.count, 1)
        XCTAssertEqual(world.readerCalls.first?.runID, runID)
        XCTAssertEqual(world.readerCalls.first?.messageID, foreignRow)
    }

    /// Defense in depth: even a (hypothetically) well-formed marker is
    /// rejected when the flushed final text sits behind later tool events —
    /// chronology may only veto a proof, never create one.
    func testMarkerBehindToolEventsIsRejected() async throws {
        let world = World()
        let row = seedUnprovenRow(world, text: "Pre-tool claim")
        world.runs[runID] = makeRun(state: "completed", ended: true)
        world.conversations[conversationID] = makeConversation()
        world.events[runID] = [
            RunEventRecord(runID: runID, sequence: 900, kind: .assistantText,
                           payloadJSON: "{\"text\":\"Pre-tool claim\"}"),
            RunEventRecord(runID: runID, sequence: 901, kind: .toolRequest,
                           payloadJSON: "{}"),
            RunEventRecord(runID: runID, sequence: 902, kind: .toolResult,
                           payloadJSON: "{}"),
            terminal("endTurn", finalMessageID: row)
        ]
        let service = makeService(world)
        let status = try await service.status(runID: runID)
        XCTAssertFalse(status.finalReplyProven)
        let result = try await service.textResult(runID: runID)
        XCTAssertEqual(result.completeness, .absent(.finalReplyUnproven))
        XCTAssertTrue(world.readerCalls.isEmpty)
    }

    /// A marker that resolves to a persisted-but-empty assistant row is an
    /// explicit empty absence; earlier non-empty steps never fill in.
    func testProvenMarkerOnEmptyRowIsAbsentNotEarlierStep() async throws {
        let world = World()
        seedUnprovenRow(world, text: "I will check")
        let emptyRow = seedUnprovenRow(world, text: "")
        world.runs[runID] = makeRun(state: "completed", ended: true)
        world.conversations[conversationID] = makeConversation()
        world.events[runID] = [
            RunEventRecord(runID: runID, sequence: 999, kind: .assistantText,
                           payloadJSON: "{\"text\":\"Final flush\"}"),
            terminal("endTurn", finalMessageID: emptyRow)
        ]
        let service = makeService(world)
        let result = try await service.textResult(runID: runID)
        XCTAssertNil(result.text)
        XCTAssertEqual(result.completeness, .absent(.noAssistantTextPersisted))
        XCTAssertEqual(world.readerCalls.count, 1)
    }

    /// A malformed (non-UUID) finalMessageID value proves nothing.
    func testGarbledIdentityValueIsUnproven() async throws {
        let world = World()
        world.runs[runID] = makeRun(state: "completed", ended: true)
        world.conversations[conversationID] = makeConversation()
        seedUnprovenRow(world, text: "I will check")
        world.events[runID] = [
            RunEventRecord(runID: runID, sequence: 999, kind: .assistantText,
                           payloadJSON: "{\"text\":\"I will check\"}"),
            RunEventRecord(
                runID: runID, sequence: 1_000, kind: .terminal,
                payloadJSON: "{\"stopReason\":\"endTurn\",\"finalMessageID\":\"not-a-uuid\"}")
        ]
        let service = makeService(world)
        let status = try await service.status(runID: runID)
        XCTAssertEqual(status.state, .completed)
        XCTAssertFalse(status.finalReplyProven)
        let result = try await service.textResult(runID: runID)
        XCTAssertNil(result.text)
        XCTAssertEqual(result.completeness, .absent(.finalReplyUnproven))
        XCTAssertTrue(world.readerCalls.isEmpty)
    }

    /// A verification-CONFIRM shape: the marker proves an EARLIER draft row
    /// while a newer flushed step text also exists; the proven draft is
    /// returned exactly, and the later/other rows are never inferred.
    func testConfirmedDraftMarkerWinsOverLatestRow() async throws {
        let world = World()
        let draftRow = seedUnprovenRow(world, text: "Sealed draft answer")
        seedUnprovenRow(world, text: "I will check")
        world.runs[runID] = makeRun(state: "completed", ended: true)
        world.conversations[conversationID] = makeConversation()
        world.events[runID] = [
            RunEventRecord(runID: runID, sequence: 900, kind: .assistantText,
                           payloadJSON: "{\"text\":\"I will check\"}"),
            RunEventRecord(runID: runID, sequence: 910, kind: .toolRequest,
                           payloadJSON: "{}"),
            RunEventRecord(runID: runID, sequence: 911, kind: .toolResult,
                           payloadJSON: "{}"),
            RunEventRecord(runID: runID, sequence: 920, kind: .assistantText,
                           payloadJSON: "{\"text\":\"Sealed draft answer\"}"),
            terminal("endTurn", finalMessageID: draftRow)
        ]
        let service = makeService(world)
        let result = try await service.textResult(runID: runID)
        XCTAssertEqual(result.text, "Sealed draft answer")
        XCTAssertEqual(result.completeness, .complete)
        XCTAssertTrue(result.status.finalReplyProven)
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

    func testWaitClampsTimeoutToBounds() async throws {
        let world = World()
        world.runs[runID] = makeRun(state: "streamingModel")
        world.conversations[conversationID] = makeConversation()
        let service = makeService(world)
        _ = try await service.wait(runID: runID, timeout: 0.01)
        XCTAssertEqual(world.pauses.reduce(0, +), FloeShortcutRunService.minimumWaitBudget)

        let upperWorld = World()
        upperWorld.runs[runID] = makeRun(state: "streamingModel")
        upperWorld.conversations[conversationID] = makeConversation()
        let upperService = makeService(upperWorld)
        _ = try await upperService.wait(runID: runID, timeout: 300)
        XCTAssertEqual(upperWorld.pauses.reduce(0, +), FloeShortcutRunService.maximumWaitBudget)
    }

    func testWaitCallerCancellationEndsWaitWithoutCancellingRun() async throws {
        let world = World()
        world.runs[runID] = makeRun(state: "streamingModel")
        world.conversations[conversationID] = makeConversation()
        let service = makeService(world)
        world.pauseDelay = .seconds(5)
        let task = Task { try await service.wait(runID: runID, timeout: 30) }
        for _ in 0..<10_000 where world.pauses.isEmpty {
            await Task.yield()
        }
        XCTAssertFalse(world.pauses.isEmpty, "wait should be polling before cancellation")
        task.cancel()
        let outcome = try await task.value
        guard case .waitCancelled(let status) = outcome else {
            return XCTFail("expected waitCancelled, got \(outcome)")
        }
        XCTAssertEqual(status.state, .running)
        XCTAssertTrue(world.cancelCalls.isEmpty,
            "cancelling the wait must never cancel the target run")
    }

    func testAlreadyCancelledWaitPollsNothingAndDoesNotCancelRun() async throws {
        let world = World()
        world.runs[runID] = makeRun(state: "streamingModel")
        world.conversations[conversationID] = makeConversation()
        let service = makeService(world)
        let outcome = await Task { () -> FloeRunWaitOutcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return (try? await service.wait(runID: runID, timeout: 30))
                ?? .budgetExhausted(.unavailable(runID: runID, reason: .stateUnrecognized))
        }.value
        guard case .waitCancelled = outcome else {
            return XCTFail("expected waitCancelled, got \(outcome)")
        }
        XCTAssertTrue(world.pauses.isEmpty)
        XCTAssertTrue(world.cancelCalls.isEmpty)
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

    func testCancelTargetsOnlyRequestedRun() async throws {
        let laterRun = UUID()
        let world = World()
        world.runs[runID] = makeRun(state: "streamingModel")
        world.conversations[conversationID] = makeConversation()
        world.liveOwners.insert(runID)
        world.runs[laterRun] = RunRecord(
            id: laterRun, conversationID: conversationID, state: "streamingModel",
            goal: "Later run", startedAt: Date(), endedAt: nil
        )
        world.liveOwners.insert(laterRun)
        world.cancelSideEffect = { runID in
            world.runs[runID]?.state = "completed"
            world.events[runID] = [self.terminal("cancelled")]
        }
        let service = makeService(world)
        let result = try await service.cancel(runID: runID)
        XCTAssertTrue(result.requested)
        XCTAssertEqual(world.cancelCalls, [runID])
        XCTAssertEqual(world.runs[laterRun]?.state, "streamingModel")
    }
}
