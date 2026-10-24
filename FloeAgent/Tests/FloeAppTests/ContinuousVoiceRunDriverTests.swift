// FloeAppTests — Continuous voice final-body delivery through the REAL run chain.
//
// Build 295 field regression: a completed run durably persisted assistantText,
// finalMessageID and terminal, yet the turn driver emitted an empty completed
// body. The coordinator consequently logged roundTextCompleted units=0 and
// silently returned to Listening. These tests deliberately use the real
// ConversationCenter, ConversationRunService, SQLite stores, turn driver,
// coordinator and continuous bridge. Only provider streaming and audio/mic
// hardware are faked. No network, credential, paid fallback or pre-fed
// VoiceConversationTurnEvent.completed fixture is involved.
//
// Acceptance procedure:
//   1. Apply this regression and its project.yml membership to UNPATCHED 295.
//      The success case must fail with zero synthesis / units=0, reproducing
//      the original production race instead of merely passing a fake body;
//      the no-final case must fail with the old silent units=0 → drained path.
//   2. Apply 01-production-finalization-fence.diff and rerun this suite plus
//      the existing coordinator/bridge/barge suites.
//
// The nil guard and the read-failure catch converge on the same
// `finalAnswer == nil` decision exercised by the real-runtime no-final case;
// a dedicated DB-close catch injection is intentionally omitted rather than
// adding a test-only production seam.
#if canImport(UIKit)
import Foundation
import Testing
import FloePersistence
import FloeTestSupport
@testable import FloeAgentRuntime
@testable import FloeCore
@testable import FloeModels
@testable import FloeProviders
@testable import FloeApp

@Suite("FloeApp.ContinuousVoiceRunDriver")
@MainActor
struct ContinuousVoiceRunDriverTests {
    private enum SynthesisMode {
        case success
        case failure
        case pending
    }

    @MainActor
    private final class Recorder {
        var synthesized: [String] = []
        var failures: [String] = []
    }

    private final class DiagnosticLog: VoiceConversationDiagnostics, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func voiceConversation(_ code: String, _ detail: String) {
            lock.withLock { storage.append([code, detail].joined(separator: " ")) }
        }

        func contains(_ expected: String) -> Bool {
            lock.withLock { storage.contains { $0 == expected } }
        }
    }

    private final class Fixture {
        let environment: AppEnvironment
        let center: ConversationCenter
        let stack: VoiceTestStack
        let driver: VoiceConversationRunDriver
        let coordinator: VoiceConversationCoordinator
        let bridge: ContinuousVoiceSpeechBridge
        let log: VoiceEventLog
        let recorder: Recorder
        let diagnostics: DiagnosticLog

        init(
            environment: AppEnvironment,
            center: ConversationCenter,
            stack: VoiceTestStack,
            driver: VoiceConversationRunDriver,
            coordinator: VoiceConversationCoordinator,
            bridge: ContinuousVoiceSpeechBridge,
            log: VoiceEventLog,
            recorder: Recorder,
            diagnostics: DiagnosticLog
        ) {
            self.environment = environment
            self.center = center
            self.stack = stack
            self.driver = driver
            self.coordinator = coordinator
            self.bridge = bridge
            self.log = log
            self.recorder = recorder
            self.diagnostics = diagnostics
        }

        func stop() {
            bridge.stop()
            coordinator.end()
            center.providerAdapterTestOverride = nil
        }
    }

    private func makeFixture(
        finalBody: String,
        synthesisMode: SynthesisMode,
        emitsFinalBody: Bool = true
    ) async throws -> Fixture {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let center = ConversationCenter(environment: environment)
        let configuration = ModelConfigurationStore(database: environment.database)
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://offline.invalid/v1")!
        )
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "scripted-final-body",
            displayName: "Scripted final body",
            limits: .init(contextTokens: 4_096, maxOutputTokens: 1_024),
            capabilities: [.text]
        )
        try await configuration.saveProvider(provider)
        try await configuration.saveModel(model)
        await center.reload()

        let adapter = MockAdapter()
        if emitsFinalBody {
            let split = min(4, finalBody.count)
            adapter.script = [[
                .textDelta(.init(text: String(finalBody.prefix(split)))),
                .textDelta(.init(text: String(finalBody.dropFirst(split)))),
                .completed(.init(stopReason: .endTurn)),
            ]]
        } else {
            // Real runtime no-final path: the provider ends the turn with no
            // visible text, so the service persists `noFinalText` and a
            // terminal WITHOUT finalMessageID — the run still reports
            // `completed`. `FinalAnswerSpeech.answer` correctly returns nil.
            adapter.script = [[.completed(.init(stopReason: .endTurn))]]
        }
        center.providerAdapterTestOverride = { _, _ in adapter }

        let conversation = try await center.createConversation(title: "Continuous voice driver")
        _ = try await WorkspaceCenter.ensureReviewConversationWorkspace(
            conversationID: conversation.id,
            workspaceID: nil,
            title: "Continuous voice driver",
            store: SQLiteWorkspaceStore(database: environment.database)
        )

        let recorder = Recorder()
        let diagnostics = DiagnosticLog()
        let stack = VoiceTestStack()
        let driver = VoiceConversationRunDriver(
            center: center,
            existingConversationID: conversation.id,
            resolveModel: { (provider, model) },
            diagnostics: diagnostics
        )
        let coordinator = VoiceConversationCoordinator(
            authorization: VoiceTestAuth(),
            makeStack: { stack },
            driving: driver,
            clock: VoiceTestClock(),
            diagnostics: diagnostics,
            speechNormalizer: { AnswerSpeechText.plainText($0) }
        )
        let log = VoiceEventLog()
        log.start(coordinator.speechEvents)
        let bridge = ContinuousVoiceSpeechBridge(
            output: coordinator,
            synthesize: { unit in
                recorder.synthesized.append(unit.text)
                return Self.makeStream(mode: synthesisMode, unit: unit)
            },
            onFailure: { error in
                recorder.failures.append(SpeechFailureCopy.key(for: error))
                // Match ContinuousVoiceScreenSession's production failure wiring.
                coordinator.pauseForScene(.inactive)
            }
        )
        bridge.connect()
        return Fixture(
            environment: environment,
            center: center,
            stack: stack,
            driver: driver,
            coordinator: coordinator,
            bridge: bridge,
            log: log,
            recorder: recorder,
            diagnostics: diagnostics
        )
    }

    private static func makeStream(
        mode: SynthesisMode,
        unit: VoiceConversationSpeechUnit
    ) -> TTSConfiguredStream {
        let (stream, sender) = TTSAudioChunkStream.make()
        switch mode {
        case .success:
            // 240 s16le mono frames at 24 kHz: enough for non-zero output-frame
            // accounting in the real coordinator and VoiceTestStack.
            let chunk = TTSAudioChunk(
                sessionID: unit.token.id,
                segmentIndex: unit.index,
                sequence: 0,
                pcm: Data(repeating: 0, count: 480),
                sampleRate: 24_000,
                isFinal: true
            )
            sender.attach(Task {
                do {
                    try await sender.send(chunk)
                    sender.finish()
                } catch {
                    sender.finish(throwing: error)
                }
            })
        case .failure:
            sender.finish(throwing: TTSSynthesisError.streamTruncated(provider: .volcengine))
        case .pending:
            break
        }
        return TTSConfiguredStream(stream: stream, close: { sender.finish() })
    }

    private func pollUntil(
        timeout: TimeInterval = 8,
        _ condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    @discardableResult
    private func launch(_ fixture: Fixture) async throws -> UUID {
        await fixture.coordinator.start()
        #expect(fixture.coordinator.state == .listening)
        #expect(await fixture.coordinator.submitText("请给出最终回答"))
        let launched = await pollUntil { fixture.driver.activeRunID != nil }
        #expect(launched, "The real center did not launch the scripted run")
        return try #require(fixture.driver.activeRunID)
    }

    @Test("Durable final body reaches Volcengine-shaped synthesis before Listening")
    func completedRunSpeaksBeforeListening() async throws {
        let finalBody = "这是已经持久化的最终回答。"
        let fixture = try await makeFixture(finalBody: finalBody, synthesisMode: .success)
        defer { fixture.stop() }
        let runID = try await launch(fixture)

        let queued = await pollUntil {
            fixture.stack.outputFrameSnapshot.scheduled > 0
        }
        #expect(queued, "A durable final must queue actual PCM before the round can finish")
        #expect(fixture.stack.outputFrameSnapshot.played == 0)
        #expect(fixture.coordinator.state == .answering)
        #expect(!fixture.log.drained, "No played-frame receipt has been delivered")

        let settled = await pollUntil {
            if fixture.coordinator.state == .listening { return true }
            // Advance only REAL coordinator accepted playback. Repeated steps
            // are harmless while the bridge appends its bounded PCM stream.
            fixture.stack.stepPlayed(frames: 1_000_000)
            return false
        }
        #expect(settled, "The real round did not settle")
        let logged = await pollUntil {
            fixture.log.roundTextCompleted != nil && fixture.log.drained
        }
        #expect(logged, "Speech events did not reach a real drained completion")

        // UNPATCHED 295 FAILS HERE: the terminal body exists in SQLite, but a
        // duplicate terminal watcher cancels the active finalizer, so these
        // values remain [] / 0 and Listening arrives without any output.
        #expect(fixture.recorder.synthesized == [finalBody])
        #expect(fixture.log.roundTextCompleted == 1)
        #expect(fixture.recorder.failures.isEmpty)
        #expect(fixture.coordinator.turnErrorMessage == nil)
        #expect(fixture.diagnostics.contains("roundTextCompleted units=1"))
        #expect(fixture.diagnostics.contains("roundFinished drained"))
        #expect(!fixture.diagnostics.contains("finalAnswerUnconfirmed events"))

        // The test does not infer success from a fabricated event: prove the
        // actual runtime persisted the same final body and terminal identity.
        let events = try await fixture.environment.runStore.events(runID: runID)
        let assistant = try #require(events.last { $0.kind == .assistantText })
        let assistantPayload = try JSONDecoder().decode(
            [String: String].self, from: Data(assistant.payloadJSON.utf8))
        #expect(assistantPayload["text"] == finalBody)
        let terminal = try #require(events.last { $0.kind == .terminal })
        let terminalPayload = try JSONDecoder().decode(
            [String: String].self, from: Data(terminal.payloadJSON.utf8))
        #expect(terminalPayload["stopReason"] == "endTurn")
        #expect(terminalPayload["finalMessageID"] != nil)
    }

    @Test("A completed run with no confirmed final is actionable, never silent zero-unit speech")
    func unconfirmedFinalFailsVisibly() async throws {
        // UNPATCHED 295 FAILS HERE with the identical user-visible defect:
        // `.completed(fullText: "")` → roundTextCompleted units=0 →
        // roundFinished drained → Listening with no audio and no error.
        let fixture = try await makeFixture(
            finalBody: "", synthesisMode: .success, emitsFinalBody: false)
        defer { fixture.stop() }
        let runID = try await launch(fixture)

        let settled = await pollUntil(timeout: 12) {
            fixture.driver.activeRunID == nil
                && (fixture.coordinator.state == .listening
                    || fixture.coordinator.state == .paused)
        }
        #expect(settled, "The no-final run did not settle")

        #expect(fixture.coordinator.turnErrorMessage == "voice.error.turn")
        #expect(fixture.recorder.synthesized.isEmpty)
        #expect(fixture.recorder.failures.isEmpty)
        #expect(fixture.log.roundTextCompleted == nil)
        #expect(!fixture.log.drained)
        #expect(!fixture.diagnostics.contains("roundTextCompleted units=0"))
        #expect(fixture.diagnostics.contains("roundFinished roundFailed"))

        // The durable truth is unchanged by the fix: the run completed with
        // the honest no-final surface and no fabricated final identity.
        let events = try await fixture.environment.runStore.events(runID: runID)
        #expect(!events.contains { $0.kind == .assistantText })
        let terminal = try #require(events.last { $0.kind == .terminal })
        let terminalPayload = try JSONDecoder().decode(
            [String: String].self, from: Data(terminal.payloadJSON.utf8))
        #expect(terminalPayload["finalMessageID"] == nil)
    }

    @Test("Synthesis failure is visibly paused, never a silent next Listening")
    func synthesisFailureRemainsActionable() async throws {
        let finalBody = "这次合成会失败。"
        let fixture = try await makeFixture(finalBody: finalBody, synthesisMode: .failure)
        defer { fixture.stop() }
        _ = try await launch(fixture)

        let settled = await pollUntil {
            if fixture.coordinator.state == .paused { return true }
            // Also observe the original defect immediately instead of waiting
            // for a successful-playback timeout that can never occur.
            return fixture.driver.activeRunID == nil && fixture.coordinator.state == .listening
        }
        #expect(settled)
        #expect(fixture.recorder.synthesized == [finalBody])
        #expect(fixture.recorder.failures == ["voice.error.playback"])
        #expect(fixture.coordinator.state == .paused)
        #expect(fixture.coordinator.pausedReason == .interrupted)
        #expect(!fixture.log.drained)
    }

    @Test("A genuine user interrupt keeps its explicit cancellation semantics")
    func manualInterruptStillCancelsTheRound() async throws {
        let finalBody = "等待用户主动中断。"
        let fixture = try await makeFixture(finalBody: finalBody, synthesisMode: .success)
        defer { fixture.stop() }
        _ = try await launch(fixture)
        let queued = await pollUntil {
            fixture.recorder.synthesized == [finalBody] && fixture.log.roundTextCompleted == 1
        }
        #expect(queued)
        #expect(fixture.coordinator.state == .answering)

        fixture.coordinator.interruptNow()
        let stopped = await pollUntil {
            let eventSeen = fixture.log.events.contains {
                if case .outputStopped(_, let reason) = $0 {
                    return reason == .manualInterrupt
                }
                return false
            }
            return eventSeen && fixture.coordinator.state == .listening
        }
        #expect(stopped)
        #expect(fixture.recorder.synthesized == [finalBody])
        #expect(fixture.diagnostics.contains("roundFinished manualInterrupt"))
        #expect(fixture.coordinator.turnErrorMessage == nil)
        #expect(!fixture.log.drained)
    }
}
#endif
