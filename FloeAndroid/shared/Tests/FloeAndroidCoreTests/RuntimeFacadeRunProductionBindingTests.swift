// SPDX-License-Identifier: MPL-2.0
//
// RUN production-binding qualification (job-5c0981e3677f4393).
//
// This file EXECUTES the ACTUAL production seams the parent Run-domain
// qualification (job-e9482f8e79ff4310) compiled but never exercised:
//
//   1. `RunCredentialArgumentNormalizerAdapter` running over the REAL
//      same-root `AndroidCredentialVault` (the bootstrap-owned
//      `DatabaseManager`, the exact full root + owner token + typed epoch,
//      the vault's ONE metadata `CredentialStore`, and a SYNTHETIC
//      in-process physical secret gateway) through the ORIGINAL
//      `CredentialArgumentNormalizer` — inside a REAL facade launch on the
//      REAL `ConversationRunService`/`FloeAgentRuntime`, proving the raw
//      synthetic credential is captured/normalized BEFORE the original
//      approval dispatch and before the call ever reaches the executor, and
//      that the raw bytes never land in durable tool/approval/audit/
//      checkpoint surfaces. ONLY the model stream, the physical gateway and
//      one recording fixture tool are synthetic doubles at the external
//      edges (the same seams the existing suites inject); nothing here
//      substitutes TestNormalizer for the adapter.
//   2. The admitted `environmentID` reaching the ACTUAL assembled service:
//      observed on the REAL dispatch `ToolContext` inside tool execution
//      (service → runtime → executor → context) and on the REAL delegated
//      child path, where the ORIGINAL child-environment mismatch guard
//      (AgentRuntime.executeResolved, "deny:child-environment-binding")
//      refuses a retargeted delegated call BEFORE any effect, keeping the
//      parent/job/task identities unchanged while the run is live.
//
// Original intake semantics retained (NOT defects, asserted honestly):
// the runtime forwards the provider `.toolRequest` AgentEvent to the
// service BEFORE normalization, and the service persists a `toolRequest`
// timeline row whose "input" is the SecretRedactor-sanitized intake view —
// credential-shaped values are masked at that boundary by the ORIGINAL
// defense-in-depth redactor. The credential field never persists raw, and
// the normalized placeholder handle is retained on the surfaces the
// adapter actually feeds (the live approval card and the ORIGINAL
// pre-dispatch recovery checkpoint history).
//
// The temporary-run nil binding, the authority vocabulary and the honest
// `localLinuxGuestEnvironment == false` truth stay exactly as the original
// contracts define them. Nothing here fabricates a Linux backend or claims
// G03 capability. No real keys, accounts, devices or production gateways.

import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloePersistence
import FloeAgentRuntime
import FloeSecurity
@testable import FloeAndroidCore

/// Synthetic in-process PHYSICAL secret gateway (test-only double for the
/// Android Keystore lane — the same `AndroidSecretGateway` shape the
/// qualified vault suites use). Records every reference so the tests can
/// prove the raw bytes reached the physical layer ONLY through the real
/// vault's capture path.
final class RecordingPhysicalSecretGateway: AndroidSecretGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Data] = [:]
    private var writeReferences: [String] = []
    private var deleteReferences: [String] = []

    func read(reference: String) async throws -> Data? {
        withScopedLock(lock) { store[reference] }
    }
    func write(reference: String, value: Data) async throws {
        withScopedLock(lock) {
            store[reference] = value
            writeReferences.append(reference)
        }
    }
    func delete(reference: String) async throws {
        withScopedLock(lock) {
            store[reference] = nil
            deleteReferences.append(reference)
        }
    }
    var writes: [String] { withScopedLock(lock) { writeReferences } }
    var deletes: [String] { withScopedLock(lock) { deleteReferences } }
    var storedValueCount: Int { withScopedLock(lock) { store.count } }
    func storedValue(for reference: String) -> Data? {
        withScopedLock(lock) { store[reference] }
    }
    func allStoredValues() -> [Data] {
        withScopedLock(lock) { Array(store.values) }
    }
}

/// Witness for the REAL dispatch context at the executor edge.
final class ProbeWitness: @unchecked Sendable {
    static let attackerEnvironmentID = "env-retarget-attacker-000000000000"

    private let lock = NSLock()
    private var _contexts: [ToolContext] = []
    private var _messages: [String] = []
    private var _retargetResult: ToolResult?
    private var _retargetAttempted = false
    /// Test-owned hold at the child EXECUTOR edge: engaged only AFTER the
    /// ORIGINAL guard returned the typed refusal and the witness stored it,
    /// and BEFORE the recording executor returns. Keeps the run live at the
    /// exact post-refusal boundary so the ownership observation below is a
    /// genuine WHILE-LIVE read, never a race against terminal retirement.
    /// Cooperative cancellation (real producer teardown) also releases it.
    nonisolated(unsafe) var holdAfterRefusal: RunGateBox?

    var isHeld: Bool { holdAfterRefusal?.isWaiting == true }
    var hasRefusal: Bool { lock.lock(); defer { lock.unlock() }; return _retargetResult != nil }

    func holdExecutorEdgeIfNeeded() async {
        if let hold = holdAfterRefusal, hasRefusal {
            await hold.waitThroughCancellation()
        }
    }

    func releaseHolds() { holdAfterRefusal?.release() }

    var contexts: [ToolContext] { lock.lock(); defer { lock.unlock() }; return _contexts }
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return _messages }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _contexts.count }
    var retargetAttempted: Bool { lock.lock(); defer { lock.unlock() }; return _retargetAttempted }
    var retargetResult: ToolResult? { lock.lock(); defer { lock.unlock() }; return _retargetResult }

    func record(context: ToolContext, message: String?) {
        withScopedLock(lock) {
            _contexts.append(context)
            _messages.append(message ?? "")
        }
    }

    /// ONE attempt, made from inside the REAL child dispatch using the REAL
    /// runtime-issued handoff dispatcher: re-dispatch the same approved tool
    /// through the parent's canonical dispatcher with a retargeted
    /// environment identity, so the ORIGINAL guard runs against the ACTUAL
    /// bound environment while the run is live.
    func performChildRetargetAttempt(with context: ToolContext) async {
        let dispatcher = context.childExecution?.dispatcher
        let shouldRun = withScopedLock(lock) { () -> Bool in
            if _retargetAttempted { return false }
            _retargetAttempted = true
            return true
        }
        guard shouldRun, let dispatcher else { return }
        var copiedContext = context
        copiedContext.environmentID = Self.attackerEnvironmentID
        let call = try? ToolCall(
            id: "call-retarget-" + UUID().uuidString.prefix(8),
            toolName: ProductionProbeTool.name,
            argumentsJSON: Data(#"{"message":"retarget-attempt"}"#.utf8),
            scope: .local)
        guard let call else { return }
        let result = await dispatcher.dispatch(call, copiedContext)
        withScopedLock(lock) { _retargetResult = result }
    }
}

/// One recording tool at the executor edge: it observes the REAL
/// runtime-issued `ToolContext` (environment binding, delegated-child
/// handoff, conversation/run identity) at actual dispatch time.
/// Non-side-effecting, so both the main path and the canonical child path
/// resolve it under the run's real approval policy.
struct ProductionProbeTool: AgentTool {
    struct Arguments: Decodable, Sendable { var message: String? }
    static let name = "fixture.envprobe"
    static let toolDescription = "Records the real dispatch context"
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false

    /// The live test's witness slot (test-only, replaced at test start).
    nonisolated(unsafe) static var witness: ProbeWitness?

    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        ProductionProbeTool.witness?.record(context: context, message: args.message)
        if context.childExecution != nil {
            await ProductionProbeTool.witness?.performChildRetargetAttempt(with: context)
            // Test-owned executor edge: engaged only after the ORIGINAL
            // refusal is stored (see ProbeWitness.holdExecutorEdgeIfNeeded).
            await ProductionProbeTool.witness?.holdExecutorEdgeIfNeeded()
        }
        let payload = "probe:" + (args.message ?? "x")
        return ToolExecutionOutput(
            summary: payload,
            fullOutputSHA256: RunWireDigest.sha256Hex(Data(payload.utf8)))
    }
}

final class RuntimeFacadeRunProductionBindingTests: XCTestCase {
    private var fixture: RunDomainFixture!

    override func setUp() async throws {
        fixture = try await RunDomainFixture.make()
        ToolCatalog.register(ProductionProbeTool.self)
        fixture.registry.register(ProductionProbeTool())
        ProductionProbeTool.witness = nil
    }

    override func tearDown() async throws {
        // Release any test-owned executor-edge hold BEFORE the real
        // generation drain, so a failed assertion can never leave the held
        // producer blocking retirement (Main lifecycle contract).
        ProductionProbeTool.witness?.releaseHolds()
        ProductionProbeTool.witness = nil
        RunDomainFacade.uninstall()
        await fixture?.tearDown()
        fixture = nil
    }

    // MARK: - Same-root real vault helpers

    /// The EXACT bootstrap-owned identity: the same normalized root, the
    /// same full owner token and the same admitted epoch as the fixture's
    /// live generation, over the fixture's ONE owned `DatabaseManager`.
    private func bootstrapIdentity() throws -> RuntimeOwnerIdentity {
        let root = try XCTUnwrap(
            RuntimeStorageRoot(
                validatingAbsoluteDirectory: fixture.root.standardizedFileURL.path))
        return try XCTUnwrap(RuntimeOwnerIdentity(
            root: root, token: fixture.bootstrapToken, epoch: fixture.epoch))
    }

    /// Joins the vault the way the admitted RB1 owner does, on the SAME
    /// bootstrap-owned manager/identity, with the PRODUCTION default owned
    /// work attachment (the REAL shared `RuntimeOwnedWorkRegistry` of the
    /// accepted generation) and the synthetic physical gateway.
    private func joinVault(gateway: RecordingPhysicalSecretGateway) throws
        -> AndroidCredentialVault {
        try AndroidCredentialVault.joinRuntimeOwnership(
            database: fixture.database,
            identity: bootstrapIdentity(),
            ownedWork: RuntimeOwnedWorkRegistryAttachment.shared,
            gateway: gateway)
    }

    /// The ORIGINAL durable schema requires credential owners to be REAL
    /// rows (credential_records has FK constraints on conversation_id /
    /// workspace_id). Creates one through the ORIGINAL atomic launch-store
    /// prepare and returns the exact conversation + workspace identities.
    private func seedOwnedTargets() async throws -> (conversationID: UUID,
                                                     workspaceID: UUID) {
        let prepared = try await fixture.launchStore.prepare(RunLaunchRequest(
            goal: "seed ownership",
            conversationMode: "chat",
            initialPolicy: DraftTaskPolicy(approvalMode: .ask),
            providerID: fixture.providerID,
            modelID: fixture.modelID))
        try await fixture.runStore.updateRunState(id: prepared.run.id,
                                                  state: "completed", endedAt: Date())
        return (prepared.conversation.id, prepared.workspace.id)
    }

    /// Reads the current checkpoint-directory file contents (the ORIGINAL
    /// pre-dispatch recovery history surface).
    private func checkpointSnapshot() -> [String] {
        let dir = fixture.root.appendingPathComponent("checkpoints")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// Scans every durable surface that could carry the raw credential:
    /// the run's durable event payloads (toolRequest/toolResult/approval/…),
    /// the conversation's messages, the durable credential metadata rows,
    /// the child-run entries, and the checkpoint files on disk.
    private func assertNoRawSecret(_ secret: String, runID: UUID,
                                   conversationID: UUID) async throws {
        let blobs: [String] = try await fixture.database.reader { db in
            var found: [String] = []
            found += try String.fetchAll(
                db, sql: "SELECT payload_json FROM run_events WHERE run_id = ?",
                arguments: [runID.uuidString])
            found += try String.fetchAll(
                db, sql: "SELECT content FROM messages WHERE conversation_id = ?",
                arguments: [conversationID.uuidString])
            found += try String.fetchAll(
                db, sql: "SELECT label FROM credential_records")
            found += try String.fetchAll(
                db, sql: "SELECT COALESCE(origin, '') FROM credential_records")
            found += try String.fetchAll(
                db, sql: """
                    SELECT e.payload_json FROM child_run_entries e
                    JOIN child_runs c ON c.id = e.child_run_id
                    WHERE c.parent_run_id = ?
                    """, arguments: [runID.uuidString])
            return found
        }
        for blob in blobs {
            XCTAssertFalse(blob.contains(secret),
                           "raw synthetic secret leaked into a durable field")
        }
        for text in checkpointSnapshot() {
            XCTAssertFalse(text.contains(secret),
                           "raw synthetic secret leaked into a checkpoint file")
        }
    }

    /// Extracts the placeholder credential id embedded in a JSON string value.
    private func capturedID(from value: Any?) -> UUID? {
        (value as? String).flatMap { SecretIngressScanner.credentialID(from: $0) }
    }

    private struct LaunchOutcome {
        let runID: UUID
        let reply: RunDomainReply
    }

    @discardableResult
    private func launch(_ domain: FacadeRunDomain, conversationID: UUID,
                        goal: String, receipt: String, correlation: String,
                        extraPayload: [String: Any] = [:]) async throws
        -> LaunchOutcome {
        var payload = fixture.startPayload(goal: goal)
        for (key, value) in extraPayload { payload[key] = value }
        let reply = await domain.start(
            envelope: fixture.launchEnvelope(
                conversationID: conversationID, payload: payload,
                revisionVersion: try await fixture.revision(
                    conversationID: conversationID),
                correlation: correlation),
            receipt: receipt, correlation: correlation)
        guard case .mutationAccepted(let detail) = reply.outcome,
              let runID = UUID(uuidString: detail["runID"] ?? "") else {
            throw NSError(domain: "launch", code: 7,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "launch must be accepted, got \(reply.outcome)"])
        }
        return LaunchOutcome(runID: runID, reply: reply)
    }

    // MARK: - 1. ACTUAL adapter end-to-end: capture BEFORE approval, secret-free persistence

    func testActualNormalizerAdapterCapturesBeforeApprovalAndPersistsOnlyHandles()
        async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let gateway = RecordingPhysicalSecretGateway()
        let vault = try joinVault(gateway: gateway)
        // The PRODUCTION adapter — not TestNormalizer.
        let adapter = RunCredentialArgumentNormalizerAdapter.make(vault: vault)
        let domain = fixture.makeCustomDomain(fixture.components(normalizer: adapter))

        let rawSecret = "SYNTH-RAW-" + UUID().uuidString
        let argumentsJSON = Data(
            ("{\"host\":\"db.example.test\",\"port\":5432,"
             + "\"target\":\"notes.txt\",\"password\":\"" + rawSecret + "\"}").utf8)
        let originalScope = ToolScope.local
        // ORIGINAL scope-binding note: `RunApprovalScopeBinding.scope(for:)`
        // grants hostID nil, so a `.hostPath` call is honestly denied after
        // approval by the unchanged scope guard (hostID nil ≠ hostID set).
        // The positive EFFECT path therefore uses the `.local` scope (the
        // original rule: a nil-host grant permits local calls); the
        // credential capture is scope-independent either way.
        let sideCall = try ToolCall(
            id: "call-raw-1", toolName: FixtureSideEffectTool.name,
            argumentsJSON: argumentsJSON, scope: originalScope)
        let index = fixture.adapter.requestCount
        fixture.adapter.enqueue(script: .init(events: [
            .toolRequest(sideCall),
            .completed(.init(stopReason: .endTurn)),
        ]), forRequest: index)
        let receipt = try XCTUnwrap(fixture.effects.register(correlationID: "corr-actual-norm"))
        let outcome = try await launch(domain, conversationID: conversationID,
                                       goal: "modify a file with a credential",
                                       receipt: receipt, correlation: "corr-actual-norm")
        let runID = outcome.runID

        // The ORIGINAL approval card must arrive carrying ONLY the
        // normalized placeholder: capture ran before approval dispatch.
        let pending = await pollFor(timeoutSeconds: 8) {
            await domain.liveService(runID)?.snapshot().pendingApproval != nil
        }
        XCTAssertTrue(pending, "the engine must request approval for the side tool")
        let waiting = try unwrapAsync(
            await domain.liveService(runID)?.snapshot().pendingApproval)
        XCTAssertEqual(waiting.toolCall.id, "call-raw-1")
        XCTAssertEqual(waiting.toolCall.toolName, FixtureSideEffectTool.name)
        XCTAssertEqual(waiting.toolCall.scope, originalScope,
                       "only argumentsJSON may change across the seam")
        XCTAssertFalse(String(data: waiting.toolCall.argumentsJSON, encoding: .utf8)!
            .contains(rawSecret), "the approval dispatch must never see raw bytes")
        let cardArgs = try JSONSerialization.jsonObject(
            with: waiting.toolCall.argumentsJSON) as! [String: Any]
        let capturedHandleID = try XCTUnwrap(capturedID(from: cardArgs["password"]),
                                             "the card must carry the credential placeholder")
        // Untouched fields ride through byte-identical.
        XCTAssertEqual(cardArgs["target"] as? String, "notes.txt")
        XCTAssertEqual(cardArgs["host"] as? String, "db.example.test")

        // The SAME-root real vault: metadata in the ONE CredentialStore over
        // the bootstrap-owned manager; raw bytes ONLY in the synthetic
        // physical gateway.
        let record = try await unwrapAsync(await vault.records.record(id: capturedHandleID))
        XCTAssertEqual(record.owner, .conversation(conversationID),
                       "the assembly binds the exact conversation ownership")
        XCTAssertEqual(record.kind, .websitePassword)
        XCTAssertEqual(record.origin, "model-tool-call:fixture.side.password")
        XCTAssertTrue(record.label.contains("db.example.test"),
                      "semantic scope label is secret-free metadata")
        XCTAssertFalse(record.label.contains(rawSecret))
        let writes = gateway.writes
        XCTAssertEqual(writes.count, 1, "capture wrote exactly one physical value")
        let stored = try XCTUnwrap(gateway.storedValue(for: writes[0]))
        XCTAssertEqual(String(data: stored, encoding: .utf8), rawSecret,
                       "the raw bytes live ONLY behind the physical gateway")
        XCTAssertEqual(gateway.storedValueCount, 1)

        // Resolve the card with the real engine-bound approval flow.
        let requestVersion = RunWireRevision.approvalVersion(requestedAt: waiting.requestedAt)
        let right = await domain.resolveApproval(envelope: fixture.executionEnvelope(
            command: "run.approval.resolve", conversationID: conversationID, runID: runID,
            payload: ["callID": waiting.toolCall.id, "decision": "allow",
                      "expectedApprovalVersion": requestVersion],
            correlation: "corr-actual-norm-resolve",
            revision: ["resourceID": RunWireRevision.approvalResourceID(callID: waiting.toolCall.id),
                       "version": requestVersion]))
        guard case .mutationAccepted = right.outcome else {
            return XCTFail("the normalized call must still resolve its approval")
        }
        // While the side-effecting call awaits dispatch, the ORIGINAL
        // pre-dispatch recovery checkpoint (if written for this transition)
        // must already carry only the NORMALIZED history: never raw bytes.
        let liveCheckpointText = self.checkpointSnapshot().joined(separator: "\n")
        XCTAssertFalse(liveCheckpointText.contains(rawSecret),
                       "the ORIGINAL checkpoint history must never carry raw bytes")

        let terminal = await waitDurableTerminal(fixture: fixture, runID: runID)
        XCTAssertEqual(terminal, "completed")

        // Durable tool fields: the ORIGINAL intake timeline row is the
        // SecretRedactor-sanitized view (credential-shaped values masked at
        // that boundary by the original defense-in-depth). Raw must be
        // absent there and everywhere durable.
        let events = try await fixture.durableEvents(runID)
        XCTAssertTrue(events.contains { $0.kind == .toolResult },
                      "the real effect ran after normalization")
        let toolRequestEvents = events.filter { $0.kind == .toolRequest }
        XCTAssertEqual(toolRequestEvents.count, 1)
        let durablePayload = try XCTUnwrap(toolRequestEvents.first?.payloadJSON)
        XCTAssertFalse(durablePayload.contains(rawSecret),
                       "the durable toolRequest input must not carry raw bytes")
        let durableInput = try JSONSerialization.jsonObject(
            with: Data(durablePayload.utf8)) as! [String: Any]
        XCTAssertEqual(durableInput["id"] as? String, "call-raw-1",
                       "ToolCall identity is retained end-to-end")
        XCTAssertEqual(durableInput["tool"] as? String, FixtureSideEffectTool.name)
        // The ORIGINAL ongoing provider conversation carries the NORMALIZED
        // call with the exact retained handle identity: the raw bytes never
        // re-enter the model history after the seam (observed grammar of
        // the follow-up ProviderStreamRequest: pending pair + toolResults).
        let follow = try XCTUnwrap(fixture.adapter.lastRequest)
        let followCallText = (follow.pendingToolCalls + follow.replayedToolPairs.map(\.call))
            .map { String(data: $0.argumentsJSON, encoding: .utf8) ?? "" }
            .joined(separator: "\n")
        let followResultText = follow.toolResults.map { $0.callID + "|" + $0.output }
            .joined(separator: "\n")
        XCTAssertFalse(followCallText.isEmpty,
                       "the follow-up conversation must carry the staged call pair")
        XCTAssertFalse(followCallText.contains(rawSecret),
                       "the ongoing provider conversation must never receive raw bytes")
        XCTAssertTrue(followCallText.contains(
            CapturedSecret.placeholder(for: capturedHandleID)),
            "the exact handle placeholder is retained in the ongoing conversation")
        XCTAssertFalse(followResultText.contains(rawSecret))

        // No raw bytes anywhere durable.
        try await assertNoRawSecret(rawSecret, runID: runID, conversationID: conversationID)

        // The tool effect observed the non-credential field untouched: only
        // the credential value was replaced across the seam.
        let resultEvent = try XCTUnwrap(events.first { $0.kind == .toolResult })
        XCTAssertTrue(resultEvent.payloadJSON.contains("side:notes.txt"),
                      "the executor ran on the retained target field")
        try await vault.retireRuntimeOwnership()
    }

    // MARK: - 2. ACTUAL adapter identity preservation + exact owner scope mapping

    func testActualAdapterPreservesToolCallIdentityAndOwnerScopeMapping() async throws {
        let owned = try await seedOwnedTargets()
        let gateway = RecordingPhysicalSecretGateway()
        let vault = try joinVault(gateway: gateway)
        let adapter = RunCredentialArgumentNormalizerAdapter(vault: vault, authority: nil)
        let rawSecret = "SYNTH-CONV-" + UUID().uuidString

        var call = try ToolCall(
            id: "call-identity-1", toolName: "ssh.updateHost",
            argumentsJSON: Data(
                ("{\"host\":\"h.example.test\",\"credentialinput\":\""
                 + rawSecret + "\"}").utf8),
            scope: ToolScope.host(UUID()))
        call.idempotencyKey = "idem-preserved-42"

        let out = try await adapter.normalized(
            call: call, runOwner: RunCredentialOwner(scope: .conversation(owned.conversationID)))
        XCTAssertEqual(out.id, call.id, "the seam never re-mints the call id")
        XCTAssertEqual(out.toolName, call.toolName)
        XCTAssertEqual(out.scope, call.scope)
        XCTAssertEqual(out.idempotencyKey, "idem-preserved-42",
                       "idempotency material is retained byte-for-byte")
        XCTAssertNotEqual(out.argumentsJSON, call.argumentsJSON)
        let outJSON = try JSONSerialization.jsonObject(
            with: out.argumentsJSON) as! [String: Any]
        let convHandleID = try XCTUnwrap(capturedID(from: outJSON["credentialinput"]))
        XCTAssertFalse(String(data: out.argumentsJSON, encoding: .utf8)!.contains(rawSecret))

        // Owner mapping is the EXACT original scope identity, and the
        // original kind mapping is unchanged for this seam (ssh. tool +
        // non-key field → SSH password).
        let convRecord = try await unwrapAsync(await vault.records.record(id: convHandleID))
        XCTAssertEqual(convRecord.owner, .conversation(owned.conversationID))
        XCTAssertEqual(convRecord.kind, .sshPassword)
        XCTAssertEqual(convRecord.origin, "model-tool-call:ssh.updateHost.credentialinput")

        // .workspace maps to .workspace, never .vault.
        let rawWorkspace = "SYNTH-WS-" + UUID().uuidString
        let wsCall = try ToolCall(
            id: "call-identity-2", toolName: "web.fetch",
            argumentsJSON: Data(
                ("{\"url\":\"https://example.invalid\",\"token\":\""
                 + rawWorkspace + "\"}").utf8),
            scope: .local)
        let wsOut = try await adapter.normalized(
            call: wsCall, runOwner: RunCredentialOwner(scope: .workspace(owned.workspaceID)))
        let wsJSON = try JSONSerialization.jsonObject(
            with: wsOut.argumentsJSON) as! [String: Any]
        let wsHandleID = try XCTUnwrap(capturedID(from: wsJSON["token"]))
        let wsRecord = try await unwrapAsync(await vault.records.record(id: wsHandleID))
        XCTAssertEqual(wsRecord.owner, .workspace(owned.workspaceID),
                       "the workspace scope maps exactly, never to .vault")
        XCTAssertEqual(wsRecord.kind, .genericToken)
        XCTAssertEqual(wsOut.id, wsCall.id)
        XCTAssertEqual(wsOut.toolName, wsCall.toolName)
        XCTAssertEqual(wsOut.scope, wsCall.scope)

        // An already-placeholdered field is NEVER re-captured (the original
        // strict rule; no duplicate physical value or metadata row).
        let renormalized = try await adapter.normalized(
            call: wsOut, runOwner: RunCredentialOwner(scope: .workspace(owned.workspaceID)))
        XCTAssertEqual(renormalized.argumentsJSON, wsOut.argumentsJSON,
                       "re-normalizing a placeholder must be a no-op")
        let wsRecords = try await vault.records.records(owner: .workspace(owned.workspaceID))
        XCTAssertEqual(wsRecords.count, 1)
        // Both captures reached the physical gateway and only there.
        XCTAssertEqual(Set(gateway.writes).count, 2)
        let storedTexts = gateway.allStoredValues()
            .map { String(data: $0, encoding: .utf8) ?? "" }.sorted()
        XCTAssertEqual(storedTexts, [rawSecret, rawWorkspace].sorted())
        try await vault.retireRuntimeOwnership()
    }

    // MARK: - 3. ACTUAL adapter authority: typed refusal BEFORE any capture effect

    func testActualAdapterAuthorityRefusalStopsCaptureBeforeAnyEffect() async throws {
        let owned = try await seedOwnedTargets()
        let gateway = RecordingPhysicalSecretGateway()
        let vault = try joinVault(gateway: gateway)
        let rawSecret = "SYNTH-AUTH-" + UUID().uuidString
        let call = try ToolCall(
            id: "call-auth-1", toolName: "ssh.updateHost",
            argumentsJSON: Data(
                ("{\"host\":\"h.example.test\",\"password\":\"" + rawSecret + "\"}").utf8),
            scope: .local)

        // Authority bound to a DIFFERENT tool: typed refusal, nothing ran.
        let mismatched = RunCredentialArgumentNormalizerAdapter(
            vault: vault,
            authority: RunCredentialAuthority(
                runID: UUID(), toolName: "vnc.typeCredential",
                targetScope: .local, allowedFieldNames: ["password"]))
        do {
            _ = try await mismatched.normalized(
                call: call, runOwner: RunCredentialOwner(scope: .conversation(owned.conversationID)))
            return XCTFail("a mismatched authority must refuse through the adapter")
        } catch let error as FloeError {
            XCTAssertEqual(error, .unauthorized)
        }
        XCTAssertEqual(gateway.writes.count, 0,
                       "refusal must happen before the vault capture effect")
        let anyRecords = try await vault.records.records(owner: .conversation(owned.conversationID))
        XCTAssertTrue(anyRecords.isEmpty)

        // A field outside the authority: still zero effects.
        let wrongField = RunCredentialArgumentNormalizerAdapter(
            vault: vault,
            authority: RunCredentialAuthority(
                runID: UUID(), toolName: "ssh.updateHost",
                targetScope: .local, allowedFieldNames: ["token"]))
        do {
            _ = try await wrongField.normalized(
                call: call, runOwner: RunCredentialOwner(scope: .conversation(owned.conversationID)))
            return XCTFail("a field outside the authority must refuse")
        } catch let error as FloeError {
            XCTAssertEqual(error, .unauthorized)
        }
        XCTAssertEqual(gateway.writes.count, 0)

        // The MATCHING authority runs the exact original capture semantics.
        let matching = RunCredentialArgumentNormalizerAdapter(
            vault: vault,
            authority: RunCredentialAuthority(
                runID: UUID(), toolName: "ssh.updateHost",
                targetScope: .local, allowedFieldNames: ["password"]))
        let out = try await matching.normalized(
            call: call, runOwner: RunCredentialOwner(scope: .conversation(owned.conversationID)))
        let outJSON = try JSONSerialization.jsonObject(
            with: out.argumentsJSON) as! [String: Any]
        let handleID = try XCTUnwrap(capturedID(from: outJSON["password"]))
        let record = try await unwrapAsync(await vault.records.record(id: handleID))
        XCTAssertEqual(record.owner, .conversation(owned.conversationID))
        // ORIGINAL mapping: the ssh.-prefixed tool classifies credential
        // fields as SSH password (the tool-prefix branch precedes the
        // field-name branch — reviewed mirror, unchanged).
        XCTAssertEqual(record.kind, .sshPassword)
        XCTAssertEqual(gateway.writes.count, 1,
                       "only the permitted authority reaches the physical write")
        // A nil authority keeps the reviewed default capture behavior (the
        // original port default — never an invented grant).
        let nilAuthority = RunCredentialArgumentNormalizerAdapter(vault: vault)
        XCTAssertNil(nilAuthority.authority)
        try await vault.retireRuntimeOwnership()
    }

    // MARK: - 4. ACTUAL adapter refusal INSIDE the real run path

    func testActualAdapterRefusalInsideRealRunNeverReachesApprovalOrStores() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let gateway = RecordingPhysicalSecretGateway()
        let vault = try joinVault(gateway: gateway)
        // Authority for the WRONG tool: the real normalizer throws at the
        // .toolRequest intake inside the ACTUAL runtime, before the batch
        // can reach approval, staging or the executor.
        let adapter = RunCredentialArgumentNormalizerAdapter(
            vault: vault,
            authority: RunCredentialAuthority(
                runID: UUID(), toolName: "some.other.tool",
                targetScope: .local, allowedFieldNames: ["password"]))
        let domain = fixture.makeCustomDomain(fixture.components(normalizer: adapter))

        let rawSecret = "SYNTH-RUNREFUSE-" + UUID().uuidString
        let sideCall = try ToolCall(
            id: "call-refuse-1", toolName: FixtureSideEffectTool.name,
            argumentsJSON: Data(
                ("{\"host\":\"h.example.test\",\"target\":\"notes.txt\",\"password\":\""
                 + rawSecret + "\"}").utf8),
            scope: .local)
        let index = fixture.adapter.requestCount
        fixture.adapter.enqueue(script: .init(events: [
            .toolRequest(sideCall),
            .completed(.init(stopReason: .endTurn)),
        ]), forRequest: index)
        // The ORIGINAL runtime requests exactly one correction turn; the
        // scripted provider answers cleanly and the run settles.
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "corrected answer")),
            .completed(.init(stopReason: .endTurn)),
        ]), forRequest: index + 1)
        let receipt = try XCTUnwrap(fixture.effects.register(correlationID: "corr-norm-refuse"))
        let outcome = try await launch(domain, conversationID: conversationID,
                                       goal: "refuse path", receipt: receipt,
                                       correlation: "corr-norm-refuse")
        let runID = outcome.runID
        let terminal = await waitDurableTerminal(fixture: fixture, runID: runID)
        XCTAssertEqual(terminal, "completed",
                       "the correction turn must settle the run, got \(terminal ?? "nil")")

        // Nothing was captured, approved or executed.
        XCTAssertEqual(gateway.writes.count, 0,
                       "a refused normalization must never reach the vault effect")
        let records = try await vault.records.records(owner: .conversation(conversationID))
        XCTAssertTrue(records.isEmpty)
        let events = try await fixture.durableEvents(runID)
        // The ORIGINAL sanitized intake breadcrumb is legitimate: the runtime
        // forwards the provider event BEFORE normalization and the service
        // persists the SecretRedactor-masked timeline view. Assert its
        // actual grammar: masked value, retained identity, and NO raw or
        // placeholder bytes — while proving zero approval/effect dispatch.
        let intakeRows = events.filter { $0.kind == .toolRequest }
        XCTAssertEqual(intakeRows.count, 1)
        let intakePayload = try XCTUnwrap(intakeRows.first?.payloadJSON)
        XCTAssertFalse(intakePayload.contains(rawSecret),
                       "the intake timeline row must be sanitized")
        XCTAssertFalse(intakePayload.contains("⟨credential:"),
                       "a refused call has no handle and must not fake one")
        let intakeJSON = try JSONSerialization.jsonObject(
            with: Data(intakePayload.utf8)) as! [String: Any]
        XCTAssertEqual(intakeJSON["id"] as? String, "call-refuse-1",
                       "the breadcrumb keeps the honest call identity")
        XCTAssertTrue(((intakeJSON["input"] as? String) ?? "")
                      .contains(SecretRedactor.replacement),
                      "the credential value is masked at the ORIGINAL intake boundary")
        // Zero unauthorized approval or tool effect remains mandatory:
        XCTAssertFalse(events.contains { $0.kind == .approval },
                       "the refused call must never reach approval persistence")
        XCTAssertFalse(events.contains { $0.kind == .toolResult },
                       "the refused call must never reach the executor")
        let stillPending = await domain.liveService(runID)?.snapshot().pendingApproval
        XCTAssertNil(stillPending)
        try await assertNoRawSecret(rawSecret, runID: runID, conversationID: conversationID)
        let durableAssistantText = events.filter { $0.kind == .assistantText }
            .map(\.payloadJSON).joined(separator: "")
        XCTAssertTrue(durableAssistantText.contains("corrected"),
                      "the run continued through the original single-correction path")
        try await vault.retireRuntimeOwnership()
    }

    // MARK: - 5. Admitted environment reaches the ACTUAL service dispatch context

    func testAdmittedEnvironmentReachesActualServiceDispatch() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let environment = "env-" + UUID().uuidString
        let job = UUID().uuidString
        fixture.environmentProof.knownEnvironment = environment
        fixture.environmentProof.acceptAnyJob = true
        // The ordinary assembly requires a bound normalizer; bind the REAL
        // production adapter (this test's subject is the environment seam;
        // the honest assembly stays real either way).
        let gateway = RecordingPhysicalSecretGateway()
        let vault = try joinVault(gateway: gateway)
        let domain = fixture.makeCustomDomain(
            fixture.components(
                normalizer: RunCredentialArgumentNormalizerAdapter(vault: vault)))
        let witness = ProbeWitness()
        ProductionProbeTool.witness = witness

        let probeCall = try ToolCall(
            id: "call-env-1", toolName: ProductionProbeTool.name,
            argumentsJSON: Data(#"{"message":"main-env"}"#.utf8), scope: .local)
        let index = fixture.adapter.requestCount
        let gate = RunGateBox()
        fixture.adapter.enqueue(script: .init(events: [
            .toolRequest(probeCall),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: 1, gate: gate), forRequest: index)
        let outcome = try await launch(domain, conversationID: conversationID,
                                       goal: "env into real dispatch",
                                       receipt: "op:v1:" + String(repeating: "6", count: 32),
                                       correlation: "corr-env-real",
                                       extraPayload: ["environmentID": environment,
                                                      "jobID": job])
        let runID = outcome.runID
        // WHILE LIVE (before any terminal teardown), the admitted identities
        // must already be on the ownership record.
        let handed = await pollFor(timeoutSeconds: 8) {
            await domain.ownership(runID: runID)?.phase == .handedOff
        }
        XCTAssertTrue(handed, "the admitted launch must reach handoff")
        let boundLive = await domain.ownership(runID: runID)
        XCTAssertEqual(boundLive?.environmentID, environment,
                       "the admitted environment identity lives on the run while live")
        XCTAssertEqual(boundLive?.jobID, job, "the admitted job identity is retained")
        gate.release()
        let terminal = await waitDurableTerminal(fixture: fixture, runID: runID)
        XCTAssertEqual(terminal, "completed")

        // The admitted identity reached the ORIGINAL runtime's dispatch
        // context inside real tool execution (service → runtime → executor).
        XCTAssertEqual(witness.callCount, 1)
        let observed = try XCTUnwrap(witness.contexts.first)
        XCTAssertEqual(observed.environmentID, environment,
                       "the ACTUAL dispatch context carries the admitted environment")
        XCTAssertEqual(observed.runID, runID)
        XCTAssertEqual(observed.conversationID, conversationID,
                       "the task/conversation identity rides unchanged")
        XCTAssertNil(observed.childExecution)
        // Honest capability truth: G02 never marks the local Linux guest
        // (the configuration-level pin lives in
        // testRuntimeConfigurationCarriesAdmittedEnvironmentAndHonestLinuxTruth).
        try await vault.retireRuntimeOwnership()
    }

    // MARK: - 6. Real delegated child: binding passes through; retarget refused pre-effect

    func testAdmittedEnvironmentReachesRealDelegatedChildAndRetargetRefusedBeforeEffect()
        async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let environment = "env-" + UUID().uuidString
        fixture.environmentProof.knownEnvironment = environment
        let gateway = RecordingPhysicalSecretGateway()
        let vault = try joinVault(gateway: gateway)
        let domain = fixture.makeCustomDomain(
            fixture.components(
                normalizer: RunCredentialArgumentNormalizerAdapter(vault: vault)))
        let witness = ProbeWitness()
        let executorHold = RunGateBox()
        witness.holdAfterRefusal = executorHold
        ProductionProbeTool.witness = witness

        let delegateCall = try ToolCall(
            id: "call-delegate-1", toolName: DelegateTool.name,
            argumentsJSON: Data(#"{"task":"probe the bound environment","type":"explore"}"#.utf8),
            scope: .local)
        let childProbeCall = try ToolCall(
            id: "call-child-probe", toolName: ProductionProbeTool.name,
            argumentsJSON: Data(#"{"message":"child-legit"}"#.utf8), scope: .local)
        let index = fixture.adapter.requestCount
        fixture.adapter.enqueue(script: .init(events: [
            .toolRequest(delegateCall),
            .completed(.init(stopReason: .endTurn)),
        ]), forRequest: index)
        // The REAL SubagentRunner child loop streams on the SAME scripted
        // adapter (request index+1).
        fixture.adapter.enqueue(script: .init(events: [
            .toolRequest(childProbeCall),
            .completed(.init(stopReason: .endTurn)),
        ]), forRequest: index + 1)

        let receipt = try XCTUnwrap(fixture.effects.register(correlationID: "corr-env-child"))
        let outcome = try await launch(domain, conversationID: conversationID,
                                       goal: "delegate env-bound work",
                                       receipt: receipt, correlation: "corr-env-child",
                                       extraPayload: ["environmentID": environment])
        let runID = outcome.runID
        // `delegate` is side-effecting: the REAL engine asks approval.
        let pending = await pollFor(timeoutSeconds: 8) {
            await domain.liveService(runID)?.snapshot().pendingApproval != nil
        }
        XCTAssertTrue(pending, "the delegate call must escalate under ask")
        let waiting = try unwrapAsync(await domain.liveService(runID)?.snapshot().pendingApproval)
        let requestVersion = RunWireRevision.approvalVersion(requestedAt: waiting.requestedAt)
        let right = await domain.resolveApproval(envelope: fixture.executionEnvelope(
            command: "run.approval.resolve", conversationID: conversationID, runID: runID,
            payload: ["callID": waiting.toolCall.id, "decision": "allow",
                      "expectedApprovalVersion": requestVersion],
            correlation: "corr-env-child-approve",
            revision: ["resourceID": RunWireRevision.approvalResourceID(callID: waiting.toolCall.id),
                       "version": requestVersion]))
        guard case .mutationAccepted = right.outcome else {
            return XCTFail("the delegate approval must bind")
        }
        // WHILE LIVE: the child executor edge is held AFTER the ORIGINAL
        // guard returned the typed refusal and the witness stored it. The
        // ownership read below therefore happens deterministically inside
        // the still-live run (no race against terminal retirement).
        let heldAfterRefusal = await pollFor(timeoutSeconds: 10) {
            witness.hasRefusal && executorHold.isWaiting
        }
        XCTAssertTrue(heldAfterRefusal,
                      "the real child dispatch must hold the executor edge after the refusal")
        let boundLive = await domain.ownership(runID: runID)
        XCTAssertEqual(boundLive?.environmentID, environment,
                       "the refusal cannot retarget the bound live ownership")
        XCTAssertEqual(boundLive?.phase, .handedOff,
                       "the run is genuinely live while the ownership is observed")
        // Release the test-owned hold: the child executor really returns,
        // the delegate settles and the ORIGINAL terminal retires ownership.
        executorHold.release()
        let terminal = await waitDurableTerminal(fixture: fixture, runID: runID)
        XCTAssertEqual(terminal, "completed",
                       "the refused retarget must not fail the real run")

        // (a) The REAL child dispatch carried the admitted binding: the
        // probe ran EXACTLY ONCE, on the inherited environment, with the
        // runtime-issued child handoff.
        XCTAssertEqual(witness.callCount, 1,
                       "the refused retarget call must never reach the executor")
        let child = try XCTUnwrap(witness.contexts.first)
        XCTAssertEqual(child.environmentID, environment,
                       "the delegated child inherits the admitted environment")
        XCTAssertEqual(witness.messages, ["child-legit"])
        let handoff = try XCTUnwrap(child.childExecution,
                                    "the runtime seeds the real handoff on child calls")
        XCTAssertEqual(handoff.identity.parentRunID, runID,
                       "the identity is runtime-issued for THIS run")
        XCTAssertEqual(handoff.identity.depth, 1)
        XCTAssertEqual(child.conversationID, conversationID)

        // (b) The ORIGINAL guard ran through the REAL dispatcher closure and
        // refused the retarget BEFORE any effect.
        XCTAssertTrue(witness.retargetAttempted)
        let refused = try XCTUnwrap(witness.retargetResult)
        XCTAssertEqual(refused.status, .denied)
        XCTAssertTrue(refused.outputSummary.contains(ProbeWitness.attackerEnvironmentID),
                      "the typed refusal names the requested environment")
        XCTAssertTrue(refused.outputSummary.contains(environment),
                      "the typed refusal names the bound environment")

        // (c) The LIVE ownership record stayed bound through the refusal;
        // nothing durable about the refused call; identities intact.
        XCTAssertEqual(boundLive?.environmentID, environment,
                       "the refusal cannot retarget the bound live ownership")
        let events = try await fixture.durableEvents(runID)
        let allJSON = events.map(\.payloadJSON).joined(separator: "\n")
        XCTAssertFalse(allJSON.contains("retarget-attempt"),
                       "the refused child call never entered the durable thread")
        XCTAssertFalse(allJSON.contains(ProbeWitness.attackerEnvironmentID),
                       "the retarget attempt is not an effect the store records")
        XCTAssertTrue(events.contains { $0.kind == .toolResult },
                      "the parent's delegate batch settled with a real result")
        try await vault.retireRuntimeOwnership()
    }
}
