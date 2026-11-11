// SPDX-License-Identifier: MPL-2.0
//
// phone.act known-password input protection (n02-password-runtime72).
// Synthetic regressions over the REAL Android runtime/facade boundaries:
//   * exact fake-executor live bytes vs redacted durable event/checkpoint
//     and dispatch snapshot (ConversationRunService -> AgentRuntime ->
//     FileCheckpointStore -> ProviderDispatchRequestSnapshot);
//   * a pending sensitive input restored from a checkpoint is failed closed
//     and NEVER dispatched with redacted bytes (automatic resume and the
//     approval-parked case share this repair path);
//   * an ordinary phone action without text input keeps its prior behavior
//     (no blanket redaction, existing repair semantics);
//   * the facade live projection retains only scrubbed copies of
//     argument-carrying harness events.
// Synthetic fixtures only; no provider network, no device. AUTHORED, NOT
// EXECUTED — compilation and execution stay with the primary owner.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloePersistence
import FloeSecurity
import FloeTools
@testable import FloeAgentRuntime
@testable import FloeAndroidCore

// MARK: - Runtime-boundary regressions (direct AgentRuntime, real checkpoint store)

final class PhoneTextInputRuntimeRedactionTests: XCTestCase {
    private let secret = "Str0ng!Passw0rd-72"
    private var root: URL!
    private var checkpoints: FileCheckpointStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-redact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        checkpoints = FileCheckpointStore(directory: root.appendingPathComponent("checkpoints"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    private func phoneTextCall(id: String, secret: String) throws -> ToolCall {
        try ToolCall(
            id: id,
            toolName: "phone.act",
            argumentsJSON: Data(
                #"{"action":"setText","nodeRef":"n3","sensitiveText":"\#(secret)"}"#.utf8
            ),
            scope: .local
        )
    }

    private func makeRuntime(
        runID: UUID,
        provider: any ProviderAdapter,
        executor: RecordingExecutor,
        sink: RecordingSink
    ) -> FloeAgentRuntime {
        let profile = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://fixtures.invalid/v1")!
        )
        let model = ModelProfile(
            providerID: profile.id,
            remoteModelID: "phone-redaction-fixture",
            displayName: "Phone Redaction Fixture",
            limits: ModelLimits(contextTokens: 16_000, maxOutputTokens: 2_048),
            capabilities: [.text, .tools]
        )
        return FloeAgentRuntime(
            configuration: .init(
                conversationID: UUID(),
                provider: profile,
                model: model,
                maxProviderRetries: 0
            ),
            adapter: provider,
            policy: AllowAllPhonePolicy(),
            executor: executor,
            checkpointStore: checkpoints,
            sink: sink,
            runID: runID
        )
    }

    private func waitUntil(
        timeoutSeconds: Double = 6,
        _ predicate: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await predicate()
    }

    // MARK: 1. Live dispatch keeps exact bytes; durable records are redacted

    func testLiveDispatchKeepsExactBytesWhileCheckpointAndDispatchSnapshotAreRedacted() async throws {
        let runID = UUID()
        let callID = "call-live-1"
        let call = try phoneTextCall(id: callID, secret: secret)
        let liveArguments = String(decoding: call.argumentsJSON, as: UTF8.self)
        // Turn one requests the phone text input; turn two is gated so the
        // test can inspect the pre-dispatch recovery checkpoint that the
        // runtime writes between tool execution and the next provider call.
        let provider = GatedSecondRequestProvider(turnOne: [
            .toolRequest(call),
            .completed(.init(stopReason: .endTurn)),
        ])
        defer { provider.gate.release() }
        let executor = RecordingExecutor()
        let sink = RecordingSink()
        let runtime = makeRuntime(runID: runID, provider: provider,
                                  executor: executor, sink: sink)
        let run = Task { try await runtime.start(goal: "Type the known password") }

        // (a) The fake executor receives the EXACT authorized bytes.
        let store = try XCTUnwrap(checkpoints)
        let dispatched = await waitUntil {
            await executor.arguments(for: callID) != nil
        }
        XCTAssertTrue(dispatched, "the live tool dispatch must reach the executor")
        let liveBytes = try XCTUnwrap(executor.arguments(for: callID))
        XCTAssertEqual(String(decoding: liveBytes, as: UTF8.self), liveArguments)
        XCTAssertTrue(liveBytes.contains(Data(secret.utf8)),
                      "live dispatch must carry the exact input bytes")
        let secondRequestWaiting = await waitUntil { provider.gate.isWaiting }
        XCTAssertTrue(secondRequestWaiting, "observe the actual continuation boundary")

        // (b) The durable recovery checkpoint omits the input and marks the
        // call as non-replayable. (Read while turn two is still gated.)
        let checkpointSeen = await waitUntil(timeoutSeconds: 8) {
            guard let checkpoint = try? await store.load(runID: runID) else { return false }
            return checkpoint.pendingToolCalls.contains { $0.id == callID }
                && checkpoint.providerDispatchRequest?.pendingToolCalls.contains {
                    $0.id == callID
                } == true
        }
        XCTAssertTrue(checkpointSeen,
                      "the pre-dispatch recovery checkpoint must land before turn two")
        let loadedCheckpoint = try await store.load(runID: runID)
        let checkpoint = try XCTUnwrap(loadedCheckpoint)
        let durableCall = try XCTUnwrap(
            checkpoint.pendingToolCalls.first { $0.id == callID }
        )
        let durableArguments = String(decoding: durableCall.argumentsJSON, as: UTF8.self)
        XCTAssertFalse(durableArguments.contains(secret),
                       "the checkpoint must not contain the phone text input")
        XCTAssertTrue(durableArguments.contains("[redacted]"))
        // A fresh provider call using the old wire spelling is admitted as
        // the current catalog tool. Historical checkpoints below keep their
        // original phone.act names and still must never replay secrets.
        XCTAssertEqual(durableCall.toolName, "device.act")
        // Metadata needed for an honest tool card survives the scrub.
        XCTAssertTrue(durableArguments.contains("setText"))
        XCTAssertTrue(durableArguments.contains("n3"))
        XCTAssertEqual(checkpoint.sensitiveToolCallIDs, [callID])

        // (c) The durable dispatch snapshot carried inside the checkpoint is
        // redacted the same way.
        let snapshot = try XCTUnwrap(checkpoint.providerDispatchRequest)
        XCTAssertFalse(snapshot.pendingToolCalls.contains {
            String(decoding: $0.argumentsJSON, as: UTF8.self).contains(secret)
        })

        // (d) Live provider history keeps its original protocol bytes. Only
        // the durable copy above is scrubbed; changing the live call would
        // break the same exact-input contract exercised by the executor.
        provider.gate.release()
        try await run.value
        XCTAssertEqual(provider.requests.count, 2)
        let continuedCall = try XCTUnwrap(provider.requests.last?.pendingToolCalls.first {
            $0.id == callID
        })
        XCTAssertEqual(continuedCall.argumentsJSON, call.argumentsJSON)
        XCTAssertEqual(executor.executionCount, 1,
                       "the sensitive input must dispatch exactly once, live")
    }

    // MARK: 2. A pending sensitive input is never replayed from a checkpoint

    func testPendingSensitiveInputResumesWithoutRedactedDispatch() async throws {
        let runID = UUID()
        let callID = "call-resume-1"
        let call = try phoneTextCall(id: callID, secret: secret)
        // The durable record a pre-fix runtime would find after process
        // death: arguments already scrubbed, marker present.
        let redacted = ToolArgumentSanitizer.sanitizedForPersistence(call)
        XCTAssertFalse(String(decoding: redacted.argumentsJSON, as: UTF8.self)
            .contains(secret))
        let checkpoint = AgentCheckpoint(
            runID: runID,
            conversationID: UUID(),
            state: .preparing(.init(goal: "resume the parked password entry")),
            messages: [.init(role: "user", content: "Resume the parked password entry.")],
            pendingToolCalls: [redacted],
            toolLifecycleEntries: [.init(
                callID: callID, toolName: "phone.act",
                isSideEffecting: true, phase: .dispatched
            )],
            sensitiveToolCallIDs: [callID]
        )
        let provider = RecordingProvider()
        let executor = RecordingExecutor()
        let sink = RecordingSink()
        let runtime = makeRuntime(runID: runID, provider: provider,
                                  executor: executor, sink: sink)
        try await runtime.resume(from: checkpoint)

        XCTAssertEqual(executor.executionCount, 0,
                       "a redacted phone input must never reach the executor on resume")
        let capturedResult = await sink.result(callID: callID)
        let result = try XCTUnwrap(capturedResult)
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.outputSummary.contains("NOT replayed"),
                      "recovery must fail closed instead of replaying redacted bytes")
        XCTAssertFalse(result.outputSummary.contains(secret))
        XCTAssertEqual(provider.requests.count, 1,
                       "the continuation turn dispatches exactly one provider request")
        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertEqual(request.toolResults.first?.callID, callID)
        XCTAssertTrue(request.toolResults.first?.output.contains("NOT replayed") == true,
                      "the model is told the call was not replayed, not silently dropped")
        for pending in request.pendingToolCalls {
            XCTAssertFalse(String(decoding: pending.argumentsJSON, as: UTF8.self)
                .contains(secret))
        }
    }

    // MARK: 3. An ordinary phone action keeps its prior behavior

    func testOrdinaryPhoneActionResumeKeepsPriorRepairSemantics() async throws {
        let runID = UUID()
        let callID = "call-ordinary-1"
        let call = try ToolCall(
            id: callID,
            toolName: "phone.act",
            argumentsJSON: Data(#"{"action":"click","nodeRef":"n7"}"#.utf8),
            scope: .local
        )
        // No text input and no marker: a pre-marker checkpoint shape must
        // remain legal and behave exactly as before.
        let checkpoint = AgentCheckpoint(
            runID: runID,
            conversationID: UUID(),
            state: .preparing(.init(goal: "resume the parked click")),
            messages: [.init(role: "user", content: "Resume the parked click.")],
            pendingToolCalls: [call],
            toolLifecycleEntries: [.init(
                callID: callID, toolName: "phone.act",
                isSideEffecting: true, phase: .dispatched
            )]
        )
        XCTAssertNil(checkpoint.sensitiveToolCallIDs)
        let provider = RecordingProvider()
        let executor = RecordingExecutor()
        let sink = RecordingSink()
        let runtime = makeRuntime(runID: runID, provider: provider,
                                  executor: executor, sink: sink)
        try await runtime.resume(from: checkpoint)

        XCTAssertEqual(executor.executionCount, 0)
        let capturedResult = await sink.result(callID: callID)
        let result = try XCTUnwrap(capturedResult)
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.outputSummary.contains("interrupted after dispatch"),
                      "ordinary actions keep the existing unknown-outcome repair")
        XCTAssertEqual(provider.requests.count, 1)
        let request = try XCTUnwrap(provider.requests.first)
        let pending = try XCTUnwrap(request.pendingToolCalls.first { $0.id == callID })
        XCTAssertEqual(String(decoding: pending.argumentsJSON, as: UTF8.self),
                       #"{"action":"click","nodeRef":"n7"}"#,
                       "ordinary arguments must survive exactly — no blanket redaction")
    }

    // MARK: 4. The checkpoint marker round-trips through the durable file

    func testCheckpointMarkerRoundTripsThroughFileEncoding() async throws {
        let runID = UUID()
        let checkpoint = AgentCheckpoint(
            runID: runID,
            conversationID: UUID(),
            state: .preparing(.init(goal: "marker round trip")),
            messages: [.init(role: "user", content: "marker round trip")],
            sensitiveToolCallIDs: ["call-marker-1"]
        )
        try await checkpoints.save(checkpoint)
        let loadedCheckpoint = try await checkpoints.load(runID: runID)
        let decoded = try XCTUnwrap(loadedCheckpoint)
        XCTAssertEqual(decoded.sensitiveToolCallIDs, ["call-marker-1"])
        // The additive field decodes checkpoints written before it existed:
        // encode a current checkpoint, strip the key (an older writer),
        // and require the standard decoder to accept the bytes.
        let encoded = try checkpoint.encoded()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "sensitiveToolCallIDs")
        let legacyJSON = try XCTUnwrap(JSONSerialization.data(withJSONObject: object))
        let legacy = try AgentCheckpoint.decoded(from: legacyJSON)
        XCTAssertNil(legacy.sensitiveToolCallIDs)
    }
}

// MARK: - Facade-projection regressions (real service/facade/stores fixture)

final class PhoneTextInputFacadeProjectionTests: XCTestCase {
    private let secret = "Str0ng!Passw0rd-72"
    private var fixture: RunDomainFixture!

    /// The synthetic side-effecting phone text tool is registered into the
    /// GLOBAL static catalog exactly once per process (registration is
    /// name-keyed and idempotent); each fixture gets its own runner instance.
    private static let catalogRegistration: Void = {
        ToolCatalog.register(FixturePhoneTextTool.self)
    }()

    override func setUp() async throws {
        _ = Self.catalogRegistration
        fixture = try await RunDomainFixture.make()
        fixture.registry.register(FixturePhoneTextTool())
    }

    override func tearDown() async throws {
        RunDomainFacade.uninstall()
        await fixture?.tearDown()
        fixture = nil
    }

    func testToolRequestEventCheckpointAndLiveProjectionOmitPhoneTextInput() async throws {
        let fixture = try XCTUnwrap(self.fixture)
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let callID = "call-facade-1"
        let call = try ToolCall(
            id: callID,
            toolName: "phone.act",
            argumentsJSON: Data(
                #"{"action":"setText","nodeRef":"n3","sensitiveText":"\#(secret)"}"#.utf8
            ),
            scope: .local
        )
        let index = fixture.adapter.requestCount
        fixture.adapter.enqueue(script: .init(events: [
            .toolRequest(call),
            .completed(.init(stopReason: .endTurn)),
        ]), forRequest: index)
        let revision = try await fixture.revision(conversationID: conversationID)
        let receipt = "op:v1:" + String(repeating: "7", count: 32)
        let reply = await domain.start(
            envelope: fixture.launchEnvelope(
                conversationID: conversationID,
                payload: fixture.startPayload(goal: "Type the known password"),
                revisionVersion: revision,
                correlation: "corr-phone"),
            receipt: receipt,
            correlation: "corr-phone")
        guard case .mutationAccepted(let detail) = reply.outcome,
              let runID = UUID(uuidString: detail["runID"] ?? "") else {
            return XCTFail("phone run launch must be accepted")
        }

        // (a) The durable toolRequest event (the correctness path behind the
        // tool card) omits the input. The side-effecting call parks at a
        // real approval card.
        let store = fixture
        let durableSeen = await pollFor(timeoutSeconds: 8) {
            guard let events = try? await store.durableEvents(runID) else { return false }
            return events.contains { $0.kind == .toolRequest }
                && events.contains { $0.kind == .approval }
        }
        XCTAssertTrue(durableSeen, "the durable toolRequest and approval events must land")
        let events = try await fixture.durableEvents(runID)
        let toolRequestEvent = try XCTUnwrap(events.first { $0.kind == .toolRequest })
        XCTAssertFalse(toolRequestEvent.payloadJSON.contains(secret),
                       "the durable toolRequest event must not contain the phone text input")
        XCTAssertTrue(toolRequestEvent.payloadJSON.contains("[redacted]"))
        XCTAssertEqual(FixturePhoneTextTool.executionCount, 0,
                       "a parked approval must not dispatch the input")

        // (b) The live projection retains only a scrubbed COPY: the exact
        // production helper used before `ingestLive` never mutates the
        // original event, and the retained frame omits the secret.
        let requested: HarnessEvent = .toolLifecycle(.requested(call))
        let projectedRequested = FacadeRunDomain.sanitizedProjectionCopy(of: requested)
        guard case .toolLifecycle(.requested(let projectedCall))? = Optional(projectedRequested) else {
            return XCTFail("toolLifecycle projection keeps its shape")
        }
        XCTAssertFalse(String(decoding: projectedCall.argumentsJSON, as: UTF8.self)
            .contains(secret))
        if case .toolLifecycle(.requested(let originalCall)) = requested {
            XCTAssertTrue(String(decoding: originalCall.argumentsJSON, as: UTF8.self)
                .contains(secret), "the original event keeps the exact live bytes")
        }
        let approval: HarnessEvent = .approvalRequested(.init(
            toolCall: call, reason: "Type the known password into the focused field"))
        let projectedApproval = FacadeRunDomain.sanitizedProjectionCopy(of: approval)
        if case .approvalRequested(let snapshot) = projectedApproval {
            XCTAssertFalse(String(decoding: snapshot.toolCall.argumentsJSON, as: UTF8.self)
                .contains(secret))
        } else {
            XCTFail("approval projection keeps its shape")
        }

        // (c) Cancel while parked at the approval: the durable checkpoint
        // must contain the redacted pending call plus the non-replay marker.
        let capturedState = try await fixture.runState(runID)
        let parkedState = try XCTUnwrap(capturedState)
        _ = await domain.cancel(envelope: fixture.executionEnvelope(
            command: "run.cancel", conversationID: conversationID, runID: runID,
            payload: ["expectedState": parkedState],
            correlation: "corr-phone-cancel",
            revision: ["resourceID": RunWireRevision.runResourceID(runID),
                       "version": parkedState]))
        let terminal = await waitDurableTerminal(fixture: fixture, runID: runID)
        XCTAssertNotNil(terminal)
        let loadedCheckpoint = try await fixture.checkpoints.load(runID: runID)
        let checkpoint = try XCTUnwrap(loadedCheckpoint)
        let durableCall = try XCTUnwrap(
            checkpoint.pendingToolCalls.first { $0.id == callID }
        )
        XCTAssertFalse(String(decoding: durableCall.argumentsJSON, as: UTF8.self)
            .contains(secret))
        XCTAssertEqual(checkpoint.sensitiveToolCallIDs, [callID])

        // (d) Cancellation already committed a denied result for this call.
        // Resume must retain that receipt and never dispatch it again; it
        // must not invent another interrupted-call result for a settled pair.
        // Unpaired sensitive recovery is covered separately above.
        let cancelledInput = try XCTUnwrap(checkpoint.pendingToolResults.first {
            $0.callID == callID
        })
        XCTAssertEqual(cancelledInput.status, .denied)
        XCTAssertTrue(cancelledInput.outputSummary.contains("Cancelled"))
        // The facade must REALLY retire the cancelled run before a retry is
        // legal (durable terminal alone can precede ownership removal).
        let retired = await pollFor {
            await domain.ownership(runID: runID) == nil
        }
        XCTAssertTrue(retired, "the cancelled phone run must retire before retry")
        let retryReceipt = try XCTUnwrap(fixture.effects.register(correlationID: "corr-phone-retry"))
        let requestsBeforeRetry = fixture.adapter.requestCount
        let retry = await domain.retry(envelope: fixture.executionEnvelope(
            command: "run.retry", conversationID: conversationID, runID: runID,
            payload: ["expectedState": terminal ?? "cancelled"],
            correlation: "corr-phone-retry",
            revision: ["resourceID": RunWireRevision.runResourceID(runID),
                       "version": terminal ?? "cancelled"]),
            receipt: retryReceipt)
        guard case .mutationAccepted = retry.outcome else {
            return XCTFail("retry of the checkpointed phone run must be accepted")
        }
        let retryActivated = await pollFor {
            fixture.adapter.requestCount > requestsBeforeRetry
        }
        XCTAssertTrue(retryActivated, "observe a new activation before reading terminal state")
        let resumedTerminal = await waitDurableTerminal(fixture: fixture, runID: runID)
        XCTAssertNotNil(resumedTerminal)
        let finalEvents = try await fixture.durableEvents(runID)
        let resumedRequest = try XCTUnwrap(fixture.adapter.lastRequest)
        let retainedCancellation = try XCTUnwrap(resumedRequest.toolResults.first {
            $0.callID == callID
        })
        XCTAssertTrue(retainedCancellation.output.contains("Cancelled"),
                      "the committed cancellation receipt must reach the continuation")
        for event in finalEvents {
            XCTAssertFalse(event.payloadJSON.contains(secret),
                           "no durable event may contain the phone text input")
        }
        XCTAssertEqual(FixturePhoneTextTool.executionCount, 0,
                       "the sensitive input must never execute, even after resume")
    }
}

// MARK: - Test doubles (synthetic; never touch a network or device)

/// Records every provider request; turn one replays the scripted events,
/// every later request waits on the gate so tests can inspect the durable
/// boundary the runtime committed in between.
private final class GatedSecondRequestProvider: ProviderAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [ProviderStreamRequest] = []
    private let turnOne: [AgentEvent]
    let gate = RunGateBox()

    init(turnOne: [AgentEvent]) {
        self.turnOne = turnOne
    }

    var requests: [ProviderStreamRequest] { lock.withLock { captured } }

    var protocolKind: ModelProtocol { .openAIChatCompletions }

    func stream(request: ProviderStreamRequest, credentials: ProviderCredentials)
        -> AsyncThrowingStream<AgentEvent, Error> {
        let index = lock.withLock { () -> Int in
            captured.append(request)
            return captured.count - 1
        }
        return AsyncThrowingStream { continuation in
            Task {
                if index == 0 {
                    for event in self.turnOne {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } else {
                    await self.gate.waitThroughCancellation()
                    continuation.yield(.completed(.init(stopReason: .endTurn)))
                    continuation.finish()
                }
            }
        }
    }

    func listModels(provider: ProviderProfile, credentials: ProviderCredentials)
        async throws -> [ModelProfile] { [] }
}

/// Records every request and answers with an immediate end-of-turn.
private final class RecordingProvider: ProviderAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [ProviderStreamRequest] = []
    var requests: [ProviderStreamRequest] { lock.withLock { captured } }
    var protocolKind: ModelProtocol { .openAIChatCompletions }

    func stream(request: ProviderStreamRequest, credentials: ProviderCredentials)
        -> AsyncThrowingStream<AgentEvent, Error> {
        lock.withLock { captured.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed(.init(stopReason: .endTurn)))
            continuation.finish()
        }
    }

    func listModels(provider: ProviderProfile, credentials: ProviderCredentials)
        async throws -> [ModelProfile] { [] }
}

/// Captures the EXACT argument bytes of every dispatched call and answers
/// with a deterministic ok result.
private final class RecordingExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [ToolCall] = []
    init() {
        ToolCatalog.register(FixturePhoneTextTool.self)
    }
    var executionCount: Int { lock.withLock { captured.count } }

    func arguments(for callID: String) -> Data? {
        lock.withLock { captured.first { $0.id == callID }?.argumentsJSON }
    }

    var allDescriptors: [ToolCatalog.Descriptor] {
        [ToolCatalog.descriptor(named: FixturePhoneTextTool.name)].compactMap { $0 }
    }
    func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        let canonical = ToolAliasTable.canonical(name)
        return canonical == FixturePhoneTextTool.name ? ToolCatalog.descriptor(named: canonical) : nil
    }

    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        lock.withLock { captured.append(call) }
        return ToolResult(
            callID: call.id,
            status: .ok,
            outputSummary: #"{"accepted":true}"#,
            outputDigest: ""
        )
    }
}

private struct AllowAllPhonePolicy: ApprovalPolicy {
    var policyName: String { "phone-redaction-allow-all" }
    func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        .allow(scope: ApprovalScope(toolName: action.toolCall.toolName), expiresAt: nil)
    }
}

private actor RecordingSink: AgentEventSink {
    private var results: [ToolResult] = []
    func result(callID: String) -> ToolResult? {
        results.first { $0.callID == callID }
    }
    func agentRuntime(_ runtime: FloeAgentRuntime, didTransitionTo state: AgentState) async {}
    func agentRuntime(_ runtime: FloeAgentRuntime, didEmit event: AgentEvent) async {
        if case .toolResult(let result) = event {
            results.append(result)
        }
    }
}

/// Side-effecting synthetic phone text tool. Under the fixture approval
/// policy it parks at a REAL approval card; its execution counter must stay
/// at zero for every redaction regression.
private struct FixturePhoneTextTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var action: String?
        var nodeRef: String?
        var text: String?
        var sensitiveText: String?
    }

    static let name = "device.act"
    static let toolDescription = "Synthetic phone text entry (redaction regression)"
    static let riskLabels: Set<RiskLabel> = [.writesFiles]
    static let isSideEffecting = true

    private static let counter = Counter()
    static var executionCount: Int { counter.value }

    func validate(_ args: Arguments) throws {}

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        FixturePhoneTextTool.counter.mark()
        let payload = "typed"
        return ToolExecutionOutput(
            summary: payload,
            fullOutputSHA256: RunWireDigest.sha256Hex(Data(payload.utf8))
        )
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func mark() { lock.withLock { count += 1 } }
    }
}

// MARK: - Device namespace rename: bounded legacy alias rule (n02-device-tool-names81)

/// The phone.* → device.* rename is carried by ONE closed 3-entry table.
/// These tests pin the exact compatibility boundary: canonicalisation of the
/// three pre-rename spellings, pass-through of every other name (unknown
/// phone.* can never become a universal alias), and symmetric ceiling
/// admission so persisted task policies written under either spelling keep
/// admitting the canonical device tools. Synthetic fixtures only.
final class DeviceToolNamesAliasTests: XCTestCase {
    func testLegacyNamesResolveThroughTheActualRunnerRegistryWithoutDuplicateDiscovery() throws {
        let registry = ToolRunnerRegistry()
        for name in ["device.observe", "device.act", "device.screenshot"] {
            let descriptor = ToolCatalog.Descriptor(
                name: name, toolDescription: "Synthetic device tool",
                parametersJSON: #"{"type":"object"}"#,
                riskLabels: [], isSideEffecting: name == "device.act",
                requiresHostScope: false)
            registry.register(AnyAgentTool(descriptor: descriptor, run: { _, _ in
                throw FloeError.validationFailed("Registry lookup fixture must not execute")
            }))
        }
        for (legacy, canonical) in ToolAliasTable.deviceInteractionRenames {
            XCTAssertEqual(try XCTUnwrap(registry.descriptor(named: legacy)).name, canonical)
            XCTAssertEqual(try XCTUnwrap(registry.descriptor(named: canonical)).name, canonical)
        }
        XCTAssertEqual(Set(registry.allDescriptors.map(\.name)), DeviceToolNames.interactionNames)
        XCTAssertNil(registry.descriptor(named: "phone.teleport"))
        XCTAssertNil(registry.descriptor(named: "phone.observe.extra"))
    }

    func testDeviceCeilingDoesNotExpandOtherToolRenameFamilies() {
        XCTAssertEqual(ToolAliasTable.canonical("task.readPlan"), "checklist.readPlan")
        XCTAssertFalse(DeviceToolNames.ceilingAllows(["task.readPlan"], name: "checklist.readPlan"))
        XCTAssertEqual(DeviceToolNames.canonical("task.readPlan"), "task.readPlan")
    }

    func testCanonicalMapsExactlyTheThreeLegacySpellings() {
        XCTAssertEqual(DeviceToolNames.canonical("phone.observe"), "device.observe")
        XCTAssertEqual(DeviceToolNames.canonical("phone.act"), "device.act")
        XCTAssertEqual(DeviceToolNames.canonical("phone.screenshot"), "device.screenshot")
        XCTAssertEqual(DeviceToolNames.canonical("device.observe"), "device.observe")
        XCTAssertEqual(DeviceToolNames.canonical("device.act"), "device.act")
        XCTAssertEqual(DeviceToolNames.canonical("device.screenshot"), "device.screenshot")
        // Unknown names pass through unchanged — never a family/prefix alias.
        XCTAssertEqual(DeviceToolNames.canonical("phone.teleport"), "phone.teleport")
        XCTAssertEqual(DeviceToolNames.canonical("phone."), "phone.")
        XCTAssertEqual(DeviceToolNames.canonical("phone.observe.extra"), "phone.observe.extra")
        XCTAssertEqual(DeviceToolNames.canonical("system.access.status"), "system.access.status")
        XCTAssertEqual(DeviceToolNames.canonical("workspace.readFile"), "workspace.readFile")
    }

    func testInteractionNameSetsAreClosedAndComplete() {
        XCTAssertEqual(DeviceToolNames.interactionNames,
                       ["device.observe", "device.act", "device.screenshot"])
        XCTAssertEqual(DeviceToolNames.legacyInteractionNames,
                       ["phone.observe", "phone.act", "phone.screenshot"])
        XCTAssertEqual(DeviceToolNames.allInteractionNames.count, 6)
        XCTAssertTrue(DeviceToolNames.allInteractionNames
            .isSuperset(of: DeviceToolNames.interactionNames))
        XCTAssertTrue(DeviceToolNames.allInteractionNames
            .isSuperset(of: DeviceToolNames.legacyInteractionNames))
    }

    func testCeilingAllowsAdmitsLegacyPolicyForCanonicalCallBothDirections() {
        // Old persisted task policy listing the phone.* spelling admits the
        // canonical device.* call.
        let legacyPolicy: Set<String> = ["phone.observe"]
        XCTAssertTrue(DeviceToolNames.ceilingAllows(legacyPolicy, name: "device.observe"))
        XCTAssertFalse(DeviceToolNames.ceilingAllows(legacyPolicy, name: "device.act"))
        XCTAssertFalse(DeviceToolNames.ceilingAllows(legacyPolicy, name: "system.files.read"))
        // New policy listing the canonical spelling admits a legacy-named
        // call (defensive path for callers that predate intake
        // canonicalisation).
        let canonicalPolicy: Set<String> = ["device.act"]
        XCTAssertTrue(DeviceToolNames.ceilingAllows(canonicalPolicy, name: "phone.act"))
        XCTAssertTrue(DeviceToolNames.ceilingAllows(canonicalPolicy, name: "device.act"))
        XCTAssertFalse(DeviceToolNames.ceilingAllows(canonicalPolicy, name: "phone.observe"))
        // Unknown phone.* entries in a policy never widen to device tools.
        let unknownPolicy: Set<String> = ["phone.teleport"]
        XCTAssertFalse(DeviceToolNames.ceilingAllows(unknownPolicy, name: "device.observe"))
        XCTAssertTrue(DeviceToolNames.ceilingAllows(unknownPolicy, name: "phone.teleport"))
    }

    func testSanitizerTreatsCanonicalAndLegacyActIdentically() {
        let secret = "canary-rename-secret"
        let canonical = Data(
            #"{"action":"setText","nodeRef":"n3","sensitiveText":"\#(secret)"}"#.utf8)
        let legacy = Data(
            #"{"action":"setText","nodeRef":"n3","sensitiveText":"\#(secret)"}"#.utf8)
        let canonicalScrubbed = ToolArgumentSanitizer.redactedArgumentsJSON(
            canonical, toolName: "device.act")
        let legacyScrubbed = ToolArgumentSanitizer.redactedArgumentsJSON(
            legacy, toolName: "phone.act")
        XCTAssertFalse(String(decoding: canonicalScrubbed, as: UTF8.self).contains(secret),
                       "the canonical device.act input is redacted")
        XCTAssertFalse(String(decoding: legacyScrubbed, as: UTF8.self).contains(secret),
                       "the legacy phone.act persisted input stays redacted")
        XCTAssertEqual(String(decoding: canonicalScrubbed, as: UTF8.self),
                       String(decoding: legacyScrubbed, as: UTF8.self),
                       "both spellings produce the identical durable record")
        XCTAssertTrue(String(decoding: canonicalScrubbed, as: UTF8.self).contains("[redacted]"))
        XCTAssertTrue(String(decoding: canonicalScrubbed, as: UTF8.self).contains("setText"))
        XCTAssertTrue(String(decoding: canonicalScrubbed, as: UTF8.self).contains("n3"))
        // Sensitivity detection matches for both spellings.
        XCTAssertTrue(ToolArgumentSanitizer.containsSensitiveValues(canonical, toolName: "device.act"))
        XCTAssertTrue(ToolArgumentSanitizer.containsSensitiveValues(legacy, toolName: "phone.act"))
        // The underscore alias is still normalised for the canonical name.
        XCTAssertTrue(ToolArgumentSanitizer.containsSensitiveValues(
            canonical, toolName: "device_act"))
        // Ordinary device actions without text stay replayable.
        let click = Data(#"{"action":"click","nodeRef":"n7"}"#.utf8)
        XCTAssertFalse(ToolArgumentSanitizer.containsSensitiveValues(click, toolName: "device.act"))
        XCTAssertEqual(String(decoding: ToolArgumentSanitizer.redactedArgumentsJSON(
            click, toolName: "device.act"), as: UTF8.self),
            #"{"action":"click","nodeRef":"n7"}"#)
        // Unknown phone.* tools are NOT redacted by this rule.
        let foreign = Data(#"{"text":"hello"}"#.utf8)
        XCTAssertFalse(ToolArgumentSanitizer.containsSensitiveValues(foreign, toolName: "phone.teleport"))
    }
}
