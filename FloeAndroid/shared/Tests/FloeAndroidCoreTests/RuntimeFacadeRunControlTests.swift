// SPDX-License-Identifier: MPL-2.0
//
// RB-4 control-surface tests: cancel/retry-window semantics, running-input
// queue/steer/edit/remove/reorder ordering, approval resolve, policy
// update, skillcancel, plus WIRED dispatch through the reviewed mailbox +
// binder validation for every frozen matrix command. AUTHORED, NOT
// EXECUTED.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloePersistence
import FloeAgentRuntime
import FloeSecurity
import FloeTools
@testable import FloeAndroidCore

final class RuntimeFacadeRunControlTests: XCTestCase {
    private var fixture: RunDomainFixture!

    func testDeviceActionApprovalProjectionNeverIncludesInputAndRejectsAmbiguity() throws {
        let observation = UUID().uuidString.lowercased()
        func project(_ json: String) throws -> [String: SettingsDomainV1.JSONValue]? {
            let call = try ToolCall(id: "call", toolName: "device.act", argumentsJSON: Data(json.utf8), scope: .local)
            return DeviceActionApprovalPresentation.details(waiting: .init(toolCall: call, reason: "test"))
        }
        let secret = "synthetic-canary-credential"
        let input = try XCTUnwrap(project("{\"action\":\"setText\",\"observationId\":\"\(observation)\",\"nodeRef\":\"n3\",\"sensitiveText\":\"\(secret)\"}"))
        XCTAssertEqual(input["inputKind"], .string("sensitiveText"))
        XCTAssertEqual(input["direction"], .null)
        XCTAssertFalse(String(describing: input).contains(secret))
        let swipe = try XCTUnwrap(project("{\"action\":\"swipe\",\"observationId\":\"adbui-\(observation)\",\"nodeRef\":\"n3\",\"direction\":\"up\"}"))
        XCTAssertEqual(swipe["direction"], .string("up"))
        XCTAssertNil(try project("{\"action\":\"setText\",\"observationId\":\"\(observation)\",\"nodeRef\":\"n3\",\"text\":\"a\",\"sensitiveText\":\"b\"}"))
        XCTAssertNil(try project("{\"action\":\"click\",\"observationId\":\"\(observation)\",\"nodeRef\":\"n3\",\"extra\":true}"))
        XCTAssertNil(try project("{\"action\":\"click\",\"observationId\":\"foreign\",\"nodeRef\":\"n3\"}"))
        XCTAssertNil(try project("{\"action\":\"scroll\",\"observationId\":\"\(observation)\",\"nodeRef\":\"n3\",\"direction\":\"up\"}"))
    }

    func testWorkspaceApprovalReadbackRejectsTerminalAndUnknownStates() {
        XCTAssertTrue(LinuxWorkspaceAuthority.approvalWorkspaceStateAllowed("preparing"))
        XCTAssertTrue(LinuxWorkspaceAuthority.approvalWorkspaceStateAllowed("waitingApproval"))
        for state in ["failed", "interrupted", "checkpointed", "completed", "cancelling", "idle", "futureUnknown"] {
            XCTAssertFalse(LinuxWorkspaceAuthority.approvalWorkspaceStateAllowed(state), state)
        }
    }

    func testWorkspacePresentationReceiptIsBoundOneShotAndExpires() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let proof = WorkspaceApprovalLaunchProof(workspaceID: UUID(), rootURL: root, allowedPaths: [],
            rootHandle: try XCTUnwrap(WorkspaceApprovalRootHandle(root: root)))
        let task = UUID(), run = UUID(), generation = UUID()
        let original = WorkspaceApprovalReceiptStore.Binding(epoch: 7, taskID: task, runID: run,
            callID: "call", generation: generation, descriptorIdentity: "descriptor", workspaceProof: proof, digest: "digest")
        let otherRun = WorkspaceApprovalReceiptStore.Binding(epoch: 7, taskID: task, runID: UUID(),
            callID: "call", generation: generation, descriptorIdentity: "descriptor", workspaceProof: proof, digest: "digest")
        let changedDetails = WorkspaceApprovalReceiptStore.Binding(epoch: 7, taskID: task, runID: run,
            callID: "call", generation: generation, descriptorIdentity: "descriptor", workspaceProof: proof, digest: "different")
        var store = WorkspaceApprovalReceiptStore()
        let wrongOwner = try XCTUnwrap(store.issue(original, now: 1))
        XCTAssertFalse(store.consume(wrongOwner, matching: otherRun, now: 2))
        XCTAssertFalse(store.consume(wrongOwner, matching: original, now: 2))
        let changed = try XCTUnwrap(store.issue(original, now: 2))
        XCTAssertFalse(store.consume(changed, matching: changedDetails, now: 3))
        let valid = try XCTUnwrap(store.issue(original, now: 3))
        XCTAssertTrue(store.matches(valid, binding: original, now: 4))
        XCTAssertTrue(store.matches(valid, binding: original, now: 4), "chunk reads do not consume the receipt")
        XCTAssertFalse(store.matches(valid, binding: otherRun, now: 4))
        XCTAssertFalse(store.matches(valid, binding: changedDetails, now: 4))
        XCTAssertFalse(store.matches(valid, binding: original, now: 603))
        XCTAssertTrue(store.consume(valid, matching: original, now: 4))
        XCTAssertFalse(store.consume(valid, matching: original, now: 4))
        let expired = try XCTUnwrap(store.issue(original, now: 4))
        XCTAssertFalse(store.consume(expired, matching: original, now: 604))
        let old = try XCTUnwrap(store.issue(original, now: 10))
        let replacement = try XCTUnwrap(store.issue(original, now: 11))
        XCTAssertFalse(store.consume(old, matching: original, now: 12))
        store.retire(runID: run)
        XCTAssertFalse(store.consume(replacement, matching: original, now: 12))
        let device = WorkspaceApprovalReceiptStore.Binding(epoch: 7, taskID: task, runID: run,
            callID: "device-call", generation: generation, descriptorIdentity: "descriptor",
            workspaceProof: nil, digest: "request", deviceTargetDigest: String(repeating: "a", count: 64))
        let changedTarget = WorkspaceApprovalReceiptStore.Binding(epoch: 7, taskID: task, runID: run,
            callID: "device-call", generation: generation, descriptorIdentity: "descriptor",
            workspaceProof: nil, digest: "request", deviceTargetDigest: String(repeating: "b", count: 64))
        let deviceToken = try XCTUnwrap(store.issue(device, now: 13))
        XCTAssertFalse(store.consume(deviceToken, matching: changedTarget, now: 14))
        XCTAssertFalse(store.consume(deviceToken, matching: device, now: 14))
    }

    func testWorkspaceApprovalDetailsRequireOriginalRootAndNeverIncludeContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationID = UUID(), workspaceID = UUID()
        let launch = WorkspaceApprovalLaunchProof(workspaceID: workspaceID, rootURL: root, allowedPaths: [],
            rootHandle: try XCTUnwrap(WorkspaceApprovalRootHandle(root: root)))
        let current = (workspaceID: workspaceID, conversationID: conversationID, rootURL: root)
        let candidate = WorkspaceApprovalLaunchCandidate(workspaceID: workspaceID, rootURL: root,
            allowedPaths: [], rootHandle: launch.rootHandle)
        XCTAssertNil(candidate.promote(current: nil, conversationID: conversationID),
                     "a terminal or absent run has no active workspace readback")
        XCTAssertNil(candidate.promote(current: current, conversationID: UUID()),
                     "another conversation cannot promote this root")
        XCTAssertNil(candidate.promote(current: (workspaceID: UUID(), conversationID: conversationID, rootURL: root),
                                       conversationID: conversationID),
                     "the same path cannot replace the workspace identity frozen at selection")
        XCTAssertNil(candidate.promote(current: (workspaceID: workspaceID, conversationID: conversationID,
                                                 rootURL: root.appendingPathComponent("other")),
                                       conversationID: conversationID),
                     "the same workspace ID cannot replace the root selected for the service")
        XCTAssertEqual(candidate.promote(current: current, conversationID: conversationID), launch)
        func details(_ tool: String, _ json: String, currentWorkspace: UUID? = nil) throws -> [String: SettingsDomainV1.JSONValue]? {
            let call = try ToolCall(id: "call", toolName: tool, argumentsJSON: Data(json.utf8), scope: .local)
            return WorkspaceApprovalPresentation.details(waiting: .init(toolCall: call, reason: "test"),
                launch: launch, current: (workspaceID: currentWorkspace ?? current.workspaceID,
                    conversationID: current.conversationID, rootURL: current.rootURL), conversationID: conversationID)
        }
        let create = try XCTUnwrap(details("workspace.createFile", #"{"path":"notes/a.txt","content":"synthetic-secret","overwrite":false}"#))
        XCTAssertEqual(create["target"], .string("notes/a.txt"))
        XCTAssertEqual(create["overwrite"], .string("forbidden"))
        XCTAssertFalse(String(describing: create).contains("synthetic-secret"))
        let write = try XCTUnwrap(details("workspace.writeFile", #"{"path":"report.txt","content":"synthetic-secret","expectedMtime":5}"#))
        XCTAssertEqual(write["overwrite"], .string("conditional"))
        XCTAssertEqual(write["precondition"], .string("mtime"))
        let draft = try XCTUnwrap(details("workspace.writeFile", "{\"path\":\"final.txt\",\"sourcePath\":\"draft.txt\",\"expectedSourceSHA256\":\"" + String(repeating: "a", count: 64) + "\"}"))
        XCTAssertEqual(draft["sourcePath"], .string("draft.txt"))
        XCTAssertEqual(draft["overwrite"], .string("forbidden"))
        let patch = try XCTUnwrap(details("workspace.applyPatch", #"{"path":"a.txt","patch":"synthetic-secret"}"#))
        XCTAssertEqual(patch["precondition"], .string("patchContext"))
        let append = try XCTUnwrap(details("workspace.appendFile", #"{"path":"a.txt","content":"synthetic-secret","expectedSHA256":"hash-value"}"#))
        XCTAssertEqual(append["precondition"], .string("fileExistsAndSha256"))
        XCTAssertFalse(String(describing: append).contains("synthetic-secret"))
        XCTAssertFalse(String(describing: append).contains("hash-value"))
        let replace = try XCTUnwrap(details("workspace.replaceText", #"{"path":"a.txt","oldText":"secret-old","newText":"secret-new","expectedOccurrences":2}"#))
        XCTAssertEqual(replace["expectedOccurrences"], .integer(2))
        XCTAssertEqual(replace["precondition"], .string("occurrences"))
        XCTAssertFalse(String(describing: replace).contains("secret-old"))
        let directory = try XCTUnwrap(details("workspace.createDirectory", #"{"path":"new/目录"}"#))
        XCTAssertEqual(directory["overwrite"], .string("forbidden"))
        for operation in ["moveFile", "copyFile"] {
            let transfer = try XCTUnwrap(details("workspace.\(operation)", #"{"from":"one.txt","to":"new/two.txt"}"#))
            XCTAssertEqual(transfer["sourcePath"], .string("one.txt"))
            XCTAssertEqual(transfer["target"], .string("new/two.txt"))
            XCTAssertEqual(transfer["sourcePrecondition"], .string("exists"))
            XCTAssertNil(try details("workspace.\(operation)", #"{"from":"one.txt","to":"../outside"}"#))
        }
        let deletion = try XCTUnwrap(details("workspace.deleteFile", #"{"path":"folder","recursive":true}"#))
        XCTAssertEqual(deletion["recursive"], .boolean(true))
        XCTAssertNil(try details("workspace.deleteFile", #"{"path":"folder","scope":"remote"}"#))
        XCTAssertFalse(String(describing: patch).contains("synthetic-secret"))
        let call = try ToolCall(id: "call", toolName: "workspace.createFile",
            argumentsJSON: Data(#"{"path":"a.txt","content":"first"}"#.utf8), scope: .local)
        let firstWaiting = AgentState.WaitingApproval(toolCall: call, reason: "test")
        var changedWaiting = firstWaiting
        changedWaiting.toolCall.argumentsJSON = Data(#"{"path":"a.txt","content":"second"}"#.utf8)
        XCTAssertNotEqual(WorkspaceApprovalPresentation.bindingDigest(waiting: firstWaiting, details: create),
                          WorkspaceApprovalPresentation.bindingDigest(waiting: changedWaiting, details: create))
        XCTAssertNil(try details("workspace.createFile", #"{"path":"Network/remote/a.txt","content":""}"#))
        XCTAssertNil(try details("workspace.createFile", #"{"path":"../escape","content":""}"#))
        XCTAssertNil(try details("workspace.createFile", #"{"path":".env","content":""}"#))
        let chinese = try XCTUnwrap(details("workspace.createFile", #"{"path":"文档/报告.txt","content":""}"#))
        XCTAssertEqual(chinese["target"], .string("文档/报告.txt"))
        XCTAssertNil(try details("workspace.createFile", "{\"path\":\"ab\u{202e}cd.txt\",\"content\":\"\"}"))
        XCTAssertNil(try details("workspace.createFile", #"{"path":"file.txt","content":""}"#, currentWorkspace: UUID()))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("real"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("real"))
        XCTAssertNil(try details("workspace.createFile", #"{"path":"link/file.txt","content":""}"#))
        let moved = root.deletingLastPathComponent().appendingPathComponent("old-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertNil(candidate.promote(current: current, conversationID: conversationID),
                     "a replacement directory is not the root passed to the service")
        XCTAssertNil(try details("workspace.createFile", #"{"path":"file.txt","content":""}"#))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
    }

    func testApprovalPresentationFailsClosedForUnknownOrSensitiveActions() throws {
        let descriptor = ToolCatalog.Descriptor(name: "device.act", riskLabels: [.controlsGUI], isSideEffecting: true)
        func project(_ json: String, descriptor: ToolCatalog.Descriptor?) throws -> SettingsDomainV1.JSONValue {
            let call = try ToolCall(id: "one", toolName: "device.act", argumentsJSON: Data(json.utf8), scope: .local)
            return RunSnapshotWireBuilder.approvalPresentation(.init(toolCall: call, reason: "test"), descriptor: descriptor)
        }
        let back = try project(#"{"action":"back","observationId":"00000000-0000-0000-0000-000000000001"}"#, descriptor: descriptor)
        guard case .object(let fields) = back else { return XCTFail("object expected") }
        XCTAssertEqual(fields["detailStatus"], .string("available"))
        XCTAssertEqual(fields["actionDetails"], .object(["action": .string("back")]))
        let launch = try project(#"{"action":"launch","packageName":"org.example.editor"}"#, descriptor: descriptor)
        guard case .object(let launchFields) = launch else { return XCTFail("object expected") }
        XCTAssertEqual(launchFields["detailStatus"], .string("available"))
        XCTAssertEqual(launchFields["actionDetails"], .object([
            "action": .string("launch"), "packageName": .string("org.example.editor")]))
        let secret = try project(#"{"action":"setText","sensitiveText":"synthetic-secret"}"#, descriptor: descriptor)
        guard case .object(let secretFields) = secret else { return XCTFail("object expected") }
        XCTAssertEqual(secretFields["detailStatus"], .string("unavailable"))
        XCTAssertNil(secretFields["actionDetails"])
        XCTAssertFalse(String(describing: secret).contains("synthetic-secret"))
        let unknown = try project(#"{"action":"home","observationId":"00000000-0000-0000-0000-000000000001"}"#, descriptor: nil)
        guard case .object(let unknownFields) = unknown else { return XCTFail("object expected") }
        XCTAssertEqual(unknownFields["status"], .string("unavailable"))
        XCTAssertNil(unknownFields["descriptorIdentity"])
    }

    override func setUp() async throws {
        fixture = try await RunDomainFixture.make()
    }

    override func tearDown() async throws {
        RunDomainFacade.uninstall()
        await fixture?.tearDown()
        fixture = nil
    }

    /// Launches a stalled run and returns its id. The stream never
    /// completes until the gate is released, so the run stays `.handedOff`.
    private func startStalledRun(_ domain: FacadeRunDomain,
                                 conversationID: UUID,
                                 goal: String) async throws -> (UUID, RunGateBox, String) {
        let gate = RunGateBox()
        let index = fixture.adapter.requestCount
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "mid stream")),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: 1, gate: gate), forRequest: index)
        let revision = try await fixture.revision(conversationID: conversationID)
        let envelope = fixture.launchEnvelope(
            conversationID: conversationID,
            payload: fixture.startPayload(goal: goal),
            revisionVersion: revision, correlation: "corr-\(goal)")
        let receipt = "op:v1:" + String(repeating: "9", count: 31) + String(index % 10)
        let reply = await domain.start(envelope: envelope, receipt: receipt,
                                       correlation: "corr-\(goal)")
        guard case .mutationAccepted(let detail) = reply.outcome,
              let runID = UUID(uuidString: detail["runID"] ?? "") else {
            throw NSError(domain: "fixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(reply.outcome)"])
        }
        // Wait until the projection is HANDED OFF (owner live).
        let live = await pollFor(timeoutSeconds: 6) {
            await domain.ownership(runID: runID)?.phase == .handedOff
        }
        XCTAssertTrue(live, "run \(runID) must reach handedOff")
        // Deterministic cancellation boundary: the ORIGINAL runtime must be
        // REALLY streaming before a cancel is meaningful (a cancel that
        // races the stream setup proves nothing about the producer).
        let streaming = await pollFor(timeoutSeconds: 6) {
            await domain.liveService(runID)?.snapshot().stateName == "streamingModel"
        }
        XCTAssertTrue(streaming, "run \(runID) must reach the real streaming boundary")
        return (runID, gate, receipt)
    }

    // MARK: - run.cancel windows

    func testCancelHandedOffRunClosesRealProducerNotJustPoller() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let (runID, gate, _) = try await startStalledRun(domain, conversationID: conversationID,
                                                          goal: "cancel me")
        // Precondition: the provider REALLY entered the held gate and the
        // first text was REALLY consumed through the live projection while
        // the gate stays closed (handedOff/requestCount alone is not proof).
        let providerParked = await pollFor(timeoutSeconds: 8) { gate.isWaiting }
        XCTAssertTrue(providerParked, "the provider must really enter the held gate")
        let textConsumed = await pollFor(timeoutSeconds: 8) {
            let text = await domain.liveService(runID)?.snapshot().streamedText ?? ""
            return !text.isEmpty
        }
        XCTAssertTrue(textConsumed, "the first delta must be really consumed before cancel")
        let state = try unwrapAsync(await fixture.runState(runID))
        let cancelEnvelope = fixture.executionEnvelope(
            command: "run.cancel", conversationID: conversationID, runID: runID,
            payload: ["expectedState": state], correlation: "corr-cancel",
            revision: ["resourceID": RunWireRevision.runResourceID(runID),
                       "version": state]) // canonical run resource proof
        let reply = await domain.cancel(envelope: cancelEnvelope)
        guard case .mutationAccepted = reply.outcome else {
            gate.release()
            return XCTFail("cancel must be accepted for a live run")
        }
        // PROOF the real producer terminated WITHOUT any manual release or
        // next delta: the ORIGINAL runtime's cancel cancels the live stream
        // task, whose termination cancels this provider stream (onTermination
        // -> producer cancel). The gate stays held for this whole window.
        let terminated = await pollFor(timeoutSeconds: 8) {
            self.fixture.adapter.streamTerminationCount >= 1
        }
        XCTAssertTrue(terminated,
                      "the held provider stream must really terminate on public cancel, before any release")
        let producerCancelled = await pollFor(timeoutSeconds: 8) {
            self.fixture.adapter.streamCancellationCount >= 1
        }
        XCTAssertTrue(producerCancelled,
                      "the held producer must really observe cancellation")
        // Cleanup only AFTER the termination assertions have passed.
        gate.release()
        let final = await waitDurableTerminal(fixture: fixture, runID: runID)
        XCTAssertNotNil(final)
        XCTAssertNotEqual(final, "completed")
        // Ownership retired with ZERO attached exact tokens (the terminal
        // P8 feed is an owned maintenance Task — observe the converged
        // zero, never a transient lease window).
        let clean = await pollFor { await domain.ownership(runID: runID) == nil }
        XCTAssertTrue(clean)
        let registryEpoch = fixture.epoch
        let drained = await pollFor {
            RuntimeOwnedWorkRegistry.shared.count(for: registryEpoch) == 0
        }
        XCTAssertTrue(drained)
        // Durable thread shows an honest terminal (cancelled/failed), never
        // a fake completion.
        // The ORIGINAL engine records cancel as a checkpointed (interrupted)
        // terminal on the harness channel, NOT a provider-completion
        // `.terminal` run row. The durable truth must therefore be the
        // honest non-completed state, never a fake completion.
        let durableEvents = try await fixture.durableEvents(runID)
        let lastStatusState: String? = durableEvents.last(where: { $0.kind == .status })
            .flatMap { record -> String? in
                guard let data = record.payloadJSON.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any] else { return nil }
                return object["state"] as? String
            }
        XCTAssertNotEqual(lastStatusState, "completed",
                          "a cancelled run must never record a completed durable status")
        XCTAssertTrue(["checkpointed", "cancelled", "failed"].contains(lastStatusState ?? ""),
                      "the durable thread must show the ORIGINAL interrupted truth, got \(lastStatusState ?? "nil")")
    }

    func testCancelDuringLiveToolAwaitUsesRuntimeCascade() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        // Script: delta -> fixture.block tool request -> (tool runs,
        // blocking) -> cancelled terminal comes from the cancel cascade.
        let index = fixture.adapter.requestCount
        let blockCall = try ToolCall(id: "call-block-1",
                                     toolName: FixtureBlockingTool.name,
                                     argumentsJSON: Data("{}".utf8),
                                     scope: .local)
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "using a tool")),
            .toolRequest(blockCall),
        ]), forRequest: index)
        let revision = try await fixture.revision(conversationID: conversationID)
        let envelope = fixture.launchEnvelope(
            conversationID: conversationID,
            payload: fixture.startPayload(goal: "run the blocking tool"),
            revisionVersion: revision, correlation: "corr-block")
        // Effects require a REGISTERED receipt stream.
        let receipt = try XCTUnwrap(fixture.effects.register(correlationID: "corr-block"))
        _ = await domain.start(envelope: envelope, receipt: receipt, correlation: "corr-block")
        let runID = try XCTUnwrap(
            pollEffects(fixture.effects, receipt: receipt)
                .first { $0.kind == .prepared }?.detail?["runID"]
                .flatMap(UUID.init(uuidString:)))
        // Tool start observed through the durable/live path.
        let toolStarted = await FixtureBlockingTool.started
        await toolStarted.waitThroughCancellation()
        // A .tool exact token must be attached while the worker really runs.
        let attachedDuringRun = await pollFor {
            await domain.ownership(runID: runID)?.ownedTokens.keys
                .contains { $0.hasPrefix("tool:") } ?? false
        }
        XCTAssertTrue(attachedDuringRun)
        let state = try unwrapAsync(await fixture.runState(runID))
        let cancel = fixture.executionEnvelope(
            command: "run.cancel", conversationID: conversationID, runID: runID,
            payload: ["expectedState": state], correlation: "corr-cancel2",
            revision: ["resourceID": RunWireRevision.runResourceID(runID), "version": state])
        _ = await domain.cancel(envelope: cancel)
        let final = await waitDurableTerminal(fixture: fixture, runID: runID)
        XCTAssertNotNil(final)
        let retired = await pollFor { await domain.ownership(runID: runID) == nil }
        XCTAssertTrue(retired, "tool token detaches only after the worker returned")
    }

    func testCancelLateFinalCallbackCannotResurrectOwnership() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let (runID, gate, _) = try await startStalledRun(domain, conversationID: conversationID,
                                                          goal: "late final")
        var state = try unwrapAsync(await fixture.runState(runID))
        _ = await domain.cancel(envelope: fixture.executionEnvelope(
            command: "run.cancel", conversationID: conversationID, runID: runID,
            payload: ["expectedState": state], correlation: "corr-late",
            revision: ["resourceID": RunWireRevision.runResourceID(runID), "version": state]))
        // Drain retirement first: ownership gone, tokens detached.
        gate.release()
        _ = await pollFor { await domain.ownership(runID: runID) == nil }
        // A late cancel attempt against a retired run answers honestly:
        // durable terminal + no owner; never a fake re-owning.
        state = try unwrapAsync(await fixture.runState(runID))
        let again = await domain.cancel(envelope: fixture.executionEnvelope(
            command: "run.cancel", conversationID: conversationID, runID: runID,
            payload: ["expectedState": state], correlation: "corr-late2",
            revision: ["resourceID": RunWireRevision.runResourceID(runID), "version": state]))
        guard case .mutationAccepted(let detail) = again.outcome else {
            return XCTFail("a retired, settled run must answer from its durable settlement")
        }
        // The earlier live Stop appended a typed settlement; a cold second
        // Stop reads that EXACT proof. The old `alreadyRequested` string alone
        // was never a settlement claim.
        XCTAssertEqual(detail["cancel"], "alreadySettled")
        XCTAssertEqual(detail["settled"], "true")
        XCTAssertEqual(detail["incarnation"]?.count, 64)
    }

    func testCancelBeforePrepareCommitProvesC0NoEffect() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        // Stall inside ingress by pointing at a gateway that answers
        // slowly? Instead use the C0 flag path directly through the
        // public cancel surface on an admitting ownership: simulate by
        // launching against an adapter whose first await is long…
        // Deterministic path: mark cancellation through a delete guard
        // (fence) BEFORE the launch and assert provable no-effect.
        let lifecycle = RunDomainDeletionLifecycle(domain: domain)
        let fence = try await lifecycle.beginDeletionFence(
            conversationID: conversationID, epoch: fixture.epoch,
            operationID: UUID())
        let reply = await startReplyViaDomain(domain, conversationID: conversationID,
                                              goal: "should never commit")
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("expected fenced refusal")
        }
        XCTAssertEqual(error.code, .sessionFenced)
        // C0: NO run row was created.
        let runs = try await fixture.runStore.runs(conversationID: conversationID)
        XCTAssertEqual(runs.count, 1)
        let settle = await lifecycle.abortDeletionFence(fence)
        XCTAssertEqual(settle, .released)
    }

    private func startReplyViaDomain(_ domain: FacadeRunDomain, conversationID: UUID,
                                     goal: String) async -> RunDomainReply {
        let revision = (try? await fixture.revision(conversationID: conversationID)) ?? ""
        let envelope = fixture.launchEnvelope(
            conversationID: conversationID, payload: fixture.startPayload(goal: goal),
            revisionVersion: revision, correlation: "corr-c0-\(goal)")
        return await domain.start(envelope: envelope,
                                  receipt: "op:v1:" + String(repeating: "5", count: 32),
                                  correlation: "corr-c0-\(goal)")
    }

    // MARK: - running input queue / steer / edit / remove / reorder

    func testQueueAcceptedIsNotApprovalOrRunStart() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let (runID, gate, _) = try await startStalledRun(domain, conversationID: conversationID,
                                                          goal: "queued target")
        let queue = fixture.executionEnvelope(
            command: "run.queue", conversationID: conversationID, runID: runID,
            payload: ["content": "queued follow-up", "mode": "queue"],
            correlation: "corr-queue",
            revision: ["resourceID": ConversationRowRevision.resourceID(conversationID: conversationID),
                       "version": try await fixture.revision(conversationID: conversationID)])
        let reply = await domain.queue(envelope: queue)
        guard case .mutationAccepted(let detail) = reply.outcome,
              let inputID = UUID(uuidString: detail["inputID"] ?? "") else {
            gate.release()
            return XCTFail("queue must accept")
        }
        let row = try unwrapAsync(await fixture.inputStore.input(id: inputID))
        XCTAssertEqual(row.status, .queued)
        XCTAssertNil(row.consumedRunID)
        // Still exactly one run on the conversation (queue started nothing).
        let runs = try await fixture.runStore.runs(conversationID: conversationID)
        XCTAssertEqual(runs.count, 2) // seed + live
        gate.release()
    }

    func testSteerPromotionExactlyOnceAndRaceTruthful() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        // TWO provider rounds: the steer is consumed exactly once at the
        // real step boundary between them (the ORIGINAL service writes
        // consumedRunID via its durable receipt path, not this facade).
        let gate = RunGateBox()
        let idx = fixture.adapter.requestCount
        let echoCall = try ToolCall(id: "call-echo-1",
                                    toolName: FixtureEchoTool.name,
                                    argumentsJSON: Data(#"{"message":"steer"}"#.utf8),
                                    scope: .local)
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "before steer")),
            .toolRequest(echoCall),
        ], stallAfter: 1, gate: gate), forRequest: idx)
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "after steer")),
            .completed(.init(stopReason: .endTurn)),
        ]), forRequest: idx + 1)
        let revision = try await fixture.revision(conversationID: conversationID)
        let receipt = "op:v1:" + String(repeating: "8", count: 32)
        let started = await domain.start(envelope: fixture.launchEnvelope(
            conversationID: conversationID,
            payload: fixture.startPayload(goal: "steer target"),
            revisionVersion: revision, correlation: "corr-steerlaunch"),
            receipt: receipt, correlation: "corr-steerlaunch")
        guard case .mutationAccepted(let d) = started.outcome,
              let runID = UUID(uuidString: d["runID"] ?? "") else {
            return XCTFail("launch must hand off")
        }
        _ = await pollFor { await domain.ownership(runID: runID)?.phase == .handedOff }
        // Enqueue through the wire path.
        _ = await domain.queue(envelope: fixture.executionEnvelope(
            command: "run.queue", conversationID: conversationID, runID: runID,
            payload: ["content": "steer me", "mode": "queue"],
            correlation: "corr-q2",
            revision: ["resourceID": ConversationRowRevision.resourceID(conversationID: conversationID),
                       "version": try await fixture.revision(conversationID: conversationID)]))
        let queued = try await fixture.inputStore.pending(conversationID: conversationID)
        let inputID = try XCTUnwrap(queued.first?.id)
        // Wait for the stalled run's durable state to settle (the runtime
        // writes streamingModel once, then it is stable while the gate is
        // held) so the envelope proof cannot race the state transition.
        let settled = await pollFor {
            (try? await self.fixture.runState(runID)) == "streamingModel"
        }
        XCTAssertTrue(settled, "the stalled run must settle into a stable durable state")
        let steer = fixture.executionEnvelope(
            command: "run.steer", conversationID: conversationID, runID: runID,
            payload: ["inputID": inputID.uuidString,
                      "expectedState": try unwrapAsync(await fixture.runState(runID))],
            correlation: "corr-steer",
            revision: ["resourceID": RunWireRevision.runResourceID(runID),
                       "version": try unwrapAsync(await fixture.runState(runID))])
        let first = await domain.steer(envelope: steer)
        guard case .mutationAccepted(let detail) = first.outcome else {
            gate.release()
            return XCTFail("steer must accept into the live run")
        }
        XCTAssertEqual(detail["accepted"], "true")
        // The row is steerPending with targetRunID set; consumedRunID stays
        // nil until the ORIGINAL service writes its exactly-once receipt.
        let row = try unwrapAsync(await fixture.inputStore.input(id: inputID))
        XCTAssertEqual(row.status, .steerPending)
        XCTAssertEqual(row.targetRunID, runID)
        XCTAssertNil(row.consumedRunID)
        // Replay with the SAME input id surfaces alreadyAccepted (runtime
        // ledger), never a double copy into context.
        let again = await domain.steer(envelope: fixture.executionEnvelope(
            command: "run.steer", conversationID: conversationID, runID: runID,
            payload: ["inputID": inputID.uuidString,
                      "expectedState": try unwrapAsync(await fixture.runState(runID))],
            correlation: "corr-steer2",
            revision: ["resourceID": RunWireRevision.runResourceID(runID),
                       "version": try unwrapAsync(await fixture.runState(runID))]))
        // The replay read above is safe: the run remains stalled in the
        // same stable state until the gate is released.
        guard case .mutationAccepted(let d2) = again.outcome else {
            gate.release()
            return XCTFail("expected alreadyAccepted surface")
        }
        XCTAssertEqual(d2["alreadyAccepted"], "true")
        // Let the run finish: the ORIGINAL handleConsumedSteer path writes
        // the consumed receipt exactly once.
        gate.release()
        let final = await waitDurableTerminal(fixture: fixture, runID: runID)
        XCTAssertEqual(final, "completed")
        let consumed = try unwrapAsync(await fixture.inputStore.input(id: inputID))
        XCTAssertEqual(consumed.status, .consumed)
        XCTAssertEqual(consumed.consumedRunID, runID)
        // The durable user-turn for the steer was written by the ORIGINAL
        // service exactly once (steerUserMessageBase), and the live
        // userInputConsumed frame reached the pump's durable window.
        let messages = try await fixture.conversationStore
            .messages(conversationID: conversationID)
        XCTAssertEqual(messages.filter { $0.id == inputID }.count, 1)
    }

    func testEditRemoveSteerPendingWithdrawsFirstThenMutates() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let (runID, gate, _) = try await startStalledRun(domain, conversationID: conversationID,
                                                          goal: "withdraw target")
        _ = await domain.queue(envelope: fixture.executionEnvelope(
            command: "run.queue", conversationID: conversationID, runID: runID,
            payload: ["content": "to withdraw", "mode": "queue"],
            correlation: "corr-q3",
            revision: ["resourceID": ConversationRowRevision.resourceID(conversationID: conversationID),
                       "version": try await fixture.revision(conversationID: conversationID)]))
        let queued = try await fixture.inputStore.pending(conversationID: conversationID)
        let inputID = try XCTUnwrap(queued.first?.id)
        let state = try unwrapAsync(await fixture.runState(runID))
        _ = await domain.steer(envelope: fixture.executionEnvelope(
            command: "run.steer", conversationID: conversationID, runID: runID,
            payload: ["inputID": inputID.uuidString, "expectedState": state],
            correlation: "corr-steer3",
            revision: ["resourceID": RunWireRevision.runResourceID(runID), "version": state]))
        // Now remove: withdrawal must restore queued FIRST, then cancel.
        let row = try unwrapAsync(await fixture.inputStore.input(id: inputID))
        let rowVersion = RunWireRevision.inputVersion(updatedAt: row.updatedAt)
        let remove = await domain.inputRemove(envelope: fixture.executionEnvelope(
            command: "run.input.remove", conversationID: conversationID, runID: runID,
            payload: ["inputID": inputID.uuidString,
                      "expectedInputVersion": rowVersion],
            correlation: "corr-rm",
            revision: ["resourceID": RunWireRevision.pendingInputResourceID(inputID),
                       "version": rowVersion]))
        gate.release()
        guard case .mutationAccepted = remove.outcome else {
            return XCTFail("remove must succeed after withdrawal")
        }
        let removed = try unwrapAsync(await fixture.inputStore.input(id: inputID))
        XCTAssertEqual(removed.status, .cancelled)
        XCTAssertNil(removed.consumedRunID, "withdrawal must not fake consumption")
    }

    func testReorderRequiresExactQueueVersionAndSet() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let (runID, gate, _) = try await startStalledRun(domain, conversationID: conversationID,
                                                          goal: "reorder host")
        for text in ["one", "two"] {
            _ = await domain.queue(envelope: fixture.executionEnvelope(
                command: "run.queue", conversationID: conversationID, runID: runID,
                payload: ["content": text, "mode": "queue"],
                correlation: "corr-\(text)",
                revision: ["resourceID": ConversationRowRevision.resourceID(conversationID: conversationID),
                           "version": try await fixture.revision(conversationID: conversationID)]))
        }
        let queueFixture: RunDomainFixture = fixture
        let queued = await pollFor {
            (try? await queueFixture.inputStore.pending(conversationID: conversationID))?
                .filter { $0.status == .queued }.count == 2
        }
        XCTAssertTrue(queued)
        let ids = try await fixture.inputStore.pending(conversationID: conversationID)
            .filter { $0.status == .queued }
            .map(\.id)
        let swapped = Array(ids.reversed())
        let bad = await domain.inputReorder(envelope: fixture.executionEnvelope(
            command: "run.input.reorder", conversationID: conversationID, runID: runID,
            payload: ["orderedIDs": swapped.map { $0.uuidString },
                      "expectedQueueVersion": "bogus"],
            correlation: "corr-bad-reorder",
            revision: ["resourceID": RunWireRevision.pendingQueueResourceID(conversationID),
                       "version": "bogus"]))
        gate.release()
        guard case .rejected(let error) = bad.outcome else {
            return XCTFail("bogus queue version must refuse")
        }
        XCTAssertEqual(error.code, .staleRevision)
        let good = await domain.inputReorder(envelope: fixture.executionEnvelope(
            command: "run.input.reorder", conversationID: conversationID, runID: runID,
            payload: ["orderedIDs": swapped.map { $0.uuidString },
                      "expectedQueueVersion": RunWireRevision.queueVersion(orderedIDs: ids)],
            correlation: "corr-good-reorder",
            revision: ["resourceID": RunWireRevision.pendingQueueResourceID(conversationID),
                       "version": RunWireRevision.queueVersion(orderedIDs: ids)]))
        guard case .mutationAccepted = good.outcome else {
            return XCTFail("exact set + version must succeed")
        }
        let after = try await fixture.inputStore.pending(conversationID: conversationID)
            .filter { $0.status == .queued }.map(\.id)
        XCTAssertEqual(after, swapped)
    }

    // MARK: - approval.resolve / policy.update / skillcancel

    func testBoundApprovalConsumesOnlyExactLiveGenerationAndCall() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let call = try ToolCall(
            id: "call-bound-generation", toolName: FixtureSideEffectTool.name,
            argumentsJSON: Data(#"{"target":"notes.txt"}"#.utf8),
            scope: .hostPath(hostID: UUID(), path: "notes.txt"))
        fixture.adapter.enqueue(script: .init(events: [
            .toolRequest(call), .completed(.init(stopReason: .endTurn)),
        ]), forRequest: fixture.adapter.requestCount)
        let revision = try await fixture.revision(conversationID: conversationID)
        let receipt = try XCTUnwrap(fixture.effects.register(correlationID: "corr-bound-generation"))
        _ = await domain.start(envelope: fixture.launchEnvelope(
            conversationID: conversationID, payload: fixture.startPayload(goal: "modify a file"),
            revisionVersion: revision, correlation: "corr-bound-generation"),
            receipt: receipt, correlation: "corr-bound-generation")
        let runID = try XCTUnwrap(pollEffects(fixture.effects, receipt: receipt)
            .first { $0.kind == .prepared }?.detail?["runID"].flatMap(UUID.init(uuidString:)))
        let pending = await pollFor(timeoutSeconds: 8) {
            await domain.liveService(runID)?.snapshot().pendingApproval != nil
        }
        XCTAssertTrue(pending)
        let service = try unwrapAsync(await domain.liveService(runID))
        let waiting = try unwrapAsync(await service.snapshot().pendingApproval)
        let deny = ApprovalDecision.deny(reason: "test decision")

        let newGeneration = AgentState.WaitingApproval(
            toolCall: waiting.toolCall, reason: waiting.reason,
            requestedAt: waiting.requestedAt, generation: UUID())
        var changedArguments = waiting
        changedArguments.toolCall.argumentsJSON = Data(#"{"target":"another.txt"}"#.utf8)
        var changedScope = waiting
        changedScope.toolCall.scope = .hostPath(hostID: UUID(), path: "another.txt")
        var changedTool = waiting
        changedTool.toolCall.toolName = "fixture.different"
        var changedReason = waiting
        changedReason.reason = "different reason"
        let changedTime = AgentState.WaitingApproval(
            toolCall: waiting.toolCall, reason: waiting.reason,
            requestedAt: waiting.requestedAt.addingTimeInterval(1), generation: waiting.generation)
        for mismatch in [newGeneration, changedArguments, changedScope, changedTool, changedReason, changedTime] {
            let accepted = await service.resolveApproval(deny, matching: mismatch)
            XCTAssertFalse(accepted, "a stale or modified exact request cannot consume the gate")
        }
        let stillWaiting = await service.snapshot().pendingApproval
        XCTAssertEqual(stillWaiting, waiting)
        let accepted = await service.resolveApproval(deny, matching: waiting)
        XCTAssertTrue(accepted)
        let repeated = await service.resolveApproval(deny, matching: waiting)
        XCTAssertFalse(repeated, "the bound decision can only consume once")
    }

    func testLegacyApprovalDecodingMintsAStableFreshGeneration() throws {
        let call = try ToolCall(id: "legacy-call", toolName: FixtureSideEffectTool.name,
            argumentsJSON: Data(#"{"target":"notes.txt"}"#.utf8), scope: .local)
        let original = AgentState.WaitingApproval(toolCall: call, reason: "needs approval")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let encoded = try encoder.encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "generation")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let recovered = try decoder.decode(AgentState.WaitingApproval.self, from: legacy)
        let anotherRecovery = try decoder.decode(AgentState.WaitingApproval.self, from: legacy)
        XCTAssertEqual(recovered.toolCall, original.toolCall)
        XCTAssertEqual(recovered.requestedAt, original.requestedAt)
        XCTAssertNotEqual(recovered.generation, anotherRecovery.generation)
        let roundTrip = try decoder.decode(AgentState.WaitingApproval.self, from: encoder.encode(recovered))
        XCTAssertEqual(roundTrip, recovered)
    }

    func testApprovalCardAppearsFromRealEngineAndResolveIsCallBound() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        // Human policy + side-effecting tool => real escalation.
        let index = fixture.adapter.requestCount
        let sideCall = try ToolCall(
            id: "call-side-1", toolName: FixtureSideEffectTool.name,
            argumentsJSON: Data(#"{"target":"notes.txt"}"#.utf8),
            scope: .hostPath(hostID: UUID(), path: "notes.txt"))
        fixture.adapter.enqueue(script: .init(events: [
            .toolRequest(sideCall),
            .completed(.init(stopReason: .endTurn)),
        ]), forRequest: index)
        let revision = try await fixture.revision(conversationID: conversationID)
        // Effects require a REGISTERED receipt stream (the ORIGINAL pump
        // refuses appends to unknown receipts).
        let receipt = try XCTUnwrap(fixture.effects.register(correlationID: "corr-appr"))
        _ = await domain.start(envelope: fixture.launchEnvelope(
            conversationID: conversationID,
            payload: fixture.startPayload(goal: "modify a file"),
            revisionVersion: revision, correlation: "corr-appr"),
            receipt: receipt, correlation: "corr-appr")
        let runID = try XCTUnwrap(
            pollEffects(fixture.effects, receipt: receipt)
                .first { $0.kind == .prepared }?.detail?["runID"]
                .flatMap(UUID.init(uuidString:)))
        let pending = await pollFor(timeoutSeconds: 8) {
            await domain.liveService(runID)?.snapshot().pendingApproval != nil
        }
        XCTAssertTrue(pending, "the ENGINE must request approval, not a synthesized card")
        let waiting = try unwrapAsync(await domain.liveService(runID)?.snapshot().pendingApproval)
        let requestVersion = RunWireRevision.approvalVersion(generation: waiting.generation)
        let snapshotReply = await domain.snapshot(envelope: fixture.executionEnvelope(
            command: "run.snapshot", conversationID: conversationID, runID: runID,
            payload: nil, correlation: "corr-approval-generation-snapshot"))
        guard case .completedPage(let page, _) = snapshotReply.outcome,
              case .object(let fields) = page.object,
              case .object(let pending) = fields["pendingApproval"],
              case .object(let revision) = fields["approvalRevision"] else {
            return XCTFail("a live approval must publish its exact generation")
        }
        XCTAssertEqual(pending["generation"], .string(waiting.generation.uuidString.lowercased()))
        XCTAssertEqual(pending["requestedAt"], .string(RunWireDate.encode(waiting.requestedAt)))
        XCTAssertEqual(revision["version"], .string(requestVersion))
        guard case .object(let presentation) = pending["presentation"] else {
            return XCTFail("the same live snapshot must carry its presentation")
        }
        XCTAssertEqual(presentation["generation"], pending["generation"])
        XCTAssertEqual(presentation["status"], .string("available"))
        XCTAssertEqual(presentation["detailStatus"], .string("unavailable"))
        XCTAssertEqual(presentation["workspaceVerified"], .boolean(false))
        let forgedPresentation = await domain.approvalPresentation(envelope: fixture.executionEnvelope(
            command: "run.approval.presentation", conversationID: conversationID, runID: runID,
            payload: ["approvalSchema": "generation-v1", "callID": waiting.toolCall.id,
                      "generation": waiting.generation.uuidString.lowercased(),
                      "expectedDescriptorIdentity": try XCTUnwrap(fixture.registry.descriptor(named: waiting.toolCall.toolName)).authorizationIdentity,
                      "target": "synthetic-secret"],
            correlation: "corr-forged-presentation",
            revision: ["resourceID": RunWireRevision.approvalResourceID(callID: waiting.toolCall.id),
                       "version": requestVersion]))
        guard case .rejected(let invalidPresentation) = forgedPresentation.outcome else {
            return XCTFail("a client cannot inject a displayed target")
        }
        XCTAssertEqual(invalidPresentation.reason, .payloadInvalid)
        XCTAssertFalse(String(describing: forgedPresentation.outcome).contains("synthetic-secret"))
        let mismatch = await domain.approvalPresentation(envelope: fixture.executionEnvelope(
            command: "run.approval.presentation", conversationID: conversationID, runID: runID,
            payload: ["approvalSchema": "generation-v1", "callID": waiting.toolCall.id,
                      "generation": waiting.generation.uuidString.lowercased(),
                      "expectedDescriptorIdentity": try XCTUnwrap(fixture.registry.descriptor(named: waiting.toolCall.toolName)).authorizationIdentity],
            correlation: "corr-presentation-stale",
            revision: ["resourceID": RunWireRevision.approvalResourceID(callID: waiting.toolCall.id),
                       "version": RunWireRevision.approvalVersion(generation: UUID())]))
        guard case .rejected(let stalePresentation) = mismatch.outcome else {
            return XCTFail("a stale revision cannot read an approval")
        }
        XCTAssertEqual(stalePresentation.code, .staleRevision)
        let legacy = await domain.resolveApproval(envelope: fixture.executionEnvelope(
            command: "run.approval.resolve", conversationID: conversationID, runID: runID,
            payload: ["callID": waiting.toolCall.id, "decision": "allow",
                      "expectedApprovalVersion": requestVersion],
            correlation: "corr-old-client-generation",
            revision: ["resourceID": RunWireRevision.approvalResourceID(callID: waiting.toolCall.id),
                       "version": requestVersion]))
        guard case .rejected = legacy.outcome else {
            return XCTFail("a client unaware of presentation schema must be rejected")
        }
        // Legacy timestamp revisions and a different generation must never
        // authorize the current request, even for the same call/time.
        for stale in [RunWireDate.encode(waiting.requestedAt),
                      RunWireRevision.approvalVersion(generation: UUID())] {
            let staleReply = await domain.resolveApproval(envelope: fixture.executionEnvelope(
                command: "run.approval.resolve", conversationID: conversationID, runID: runID,
                payload: ["callID": waiting.toolCall.id, "decision": "allow",
                          "approvalSchema": "generation-v1",
                          "expectedDescriptorIdentity": try XCTUnwrap(fixture.registry.descriptor(named: waiting.toolCall.toolName)).authorizationIdentity,
                          "expectedApprovalVersion": stale],
                correlation: "corr-stale-generation-\(UUID().uuidString)",
                revision: ["resourceID": RunWireRevision.approvalResourceID(callID: waiting.toolCall.id),
                           "version": stale]))
            guard case .rejected(let error) = staleReply.outcome else {
                return XCTFail("a stale approval revision must not resolve")
            }
            XCTAssertEqual(error, RunDomainError(.staleRevision, .revisionMismatch))
        }
        // Wrong callID can never resolve the pending request.
        let wrong = await domain.resolveApproval(envelope: fixture.executionEnvelope(
            command: "run.approval.resolve", conversationID: conversationID, runID: runID,
            payload: ["callID": "not-the-live-call", "decision": "allow",
                      "approvalSchema": "generation-v1",
                      "expectedDescriptorIdentity": try XCTUnwrap(fixture.registry.descriptor(named: waiting.toolCall.toolName)).authorizationIdentity,
                      "expectedApprovalVersion": requestVersion],
            correlation: "corr-wrong",
            revision: ["resourceID": RunWireRevision.approvalResourceID(callID: "not-the-live-call"),
                       "version": requestVersion]))
        guard case .rejected(let wrongError) = wrong.outcome else {
            return XCTFail("stale card must never resolve")
        }
        XCTAssertEqual(wrongError, RunDomainError(.invalidState, .approvalGenerationMismatch))
        // Correct resolve: the reply claims `bound`, NOT durable-recorded.
        let right = await domain.resolveApproval(envelope: fixture.executionEnvelope(
            command: "run.approval.resolve", conversationID: conversationID, runID: runID,
            payload: ["callID": waiting.toolCall.id, "decision": "allow",
                      "approvalSchema": "generation-v1",
                      "expectedDescriptorIdentity": try XCTUnwrap(fixture.registry.descriptor(named: waiting.toolCall.toolName)).authorizationIdentity,
                      "expectedApprovalVersion": requestVersion],
            correlation: "corr-right",
            revision: ["resourceID": RunWireRevision.approvalResourceID(callID: waiting.toolCall.id),
                       "version": requestVersion]))
        guard case .mutationAccepted(let detail) = right.outcome else {
            return XCTFail("correct approval must bind")
        }
        XCTAssertEqual(detail["bound"], "true")
        XCTAssertEqual(detail["awaitReceipt"], "approvalResolved")
        // The durable thread proves the run then proceeded: tool result +
        // approval receipt records exist only after the real engine acted.
        _ = await waitDurableTerminal(fixture: fixture, runID: runID)
        let events = try await fixture.durableEvents(runID)
        XCTAssertTrue(events.contains { $0.kind == .toolResult })
        // Live approvalResolved frame reached the pump consumer too.
        let live = fixture.events.pollDurable(runID: runID, afterSequence: 0,
                                              budgetBytes: FacadeFrameBudget.pageBudgetBytes)
        XCTAssertEqual(live["windowState"] as? String, "attached")
    }

    func testAllowScopeIsDerivedFromLiveCallNeverFromPayload() async throws {
        // Payload cannot smuggle a broader ApprovalScope: even if a hostile
        // payload carries extra keys, the closed parser rejects it.
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let envelope = fixture.executionEnvelope(
            command: "run.approval.resolve", conversationID: conversationID,
            runID: UUID(),
            payload: ["callID": "x", "decision": "allow",
                      "expectedApprovalVersion": RunWireDate.encode(Date()),
                      "scope": ["paths": ["/"], "hostID": UUID().uuidString]],
            correlation: "corr-scope-smuggle")
        let reply = await domain.resolveApproval(envelope: envelope)
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("scope smuggle must be a closed-key rejection")
        }
        XCTAssertEqual(error.reason, .payloadInvalid)
    }

    func testPolicyUpdatePersistsAndReachesLiveServiceUnderDynamicPolicy() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let (runID, gate, _) = try await startStalledRun(domain, conversationID: conversationID,
                                                          goal: "policy host")
        let policy = try await fixture.workspaceStore.taskPolicy(conversationID: conversationID)
        let update = await domain.policyUpdate(envelope: fixture.executionEnvelope(
            command: "run.policy.update", conversationID: conversationID, runID: runID,
            payload: ["approvalMode": "automatic",
                      "expectedPolicyVersion": RunWireRevision.taskPolicyVersion(
                          updatedAt: policy.updatedAt)],
            correlation: "corr-policy",
            revision: ["resourceID": RunWireRevision.taskPolicyResourceID(conversationID),
                       "version": RunWireRevision.taskPolicyVersion(updatedAt: policy.updatedAt)]))
        gate.release()
        guard case .mutationAccepted(let detail) = update.outcome else {
            return XCTFail("policy update must be accepted")
        }
        XCTAssertEqual(detail["appliedToLiveRun"], "true")
        let saved = try await fixture.workspaceStore.taskPolicy(conversationID: conversationID)
        XCTAssertEqual(saved.resolvedApprovalMode, .automatic)
    }

    func testPolicyUpdateStaleVersionRefused() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let update = await domain.policyUpdate(envelope: fixture.executionEnvelope(
            command: "run.policy.update", conversationID: conversationID,
            runID: UUID(),
            payload: ["approvalMode": "automatic",
                      "expectedPolicyVersion": "1970-01-01T00:00:00.000Z"],
            correlation: "corr-stale-policy",
            revision: ["resourceID": RunWireRevision.taskPolicyResourceID(conversationID),
                       "version": "1970-01-01T00:00:00.000Z"]))
        guard case .rejected(let error) = update.outcome else {
            return XCTFail("stale policy version must refuse")
        }
        XCTAssertEqual(error.code, .staleRevision)
    }

    func testSkillCancelUnboundIsTypedRefusalNeverInventedJob() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        var components = fixture.components()
        components.toolCancellation = nil
        let domain = fixture.makeCustomDomain(components)
        let (runID, gate, _) = try await startStalledRun(domain, conversationID: conversationID,
                                                          goal: "skill host")
        let state = try unwrapAsync(await fixture.runState(runID))
        let reply = await domain.skillCancel(envelope: fixture.executionEnvelope(
            command: "run.skillcancel", conversationID: conversationID, runID: runID,
            payload: ["callID": "some-tool-call", "expectedState": state],
            correlation: "corr-skill",
            revision: ["resourceID": RunWireRevision.runResourceID(runID), "version": state]))
        gate.release()
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("unbound cancellation port must refuse typed")
        }
        XCTAssertEqual(error, RunDomainError(.capabilityNotUsable, .skillCancellationUnbound))
    }

    func testSkillCancelDelegatesToBoundPort() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let (runID, gate, _) = try await startStalledRun(domain, conversationID: conversationID,
                                                          goal: "skill host 2")
        let state = try unwrapAsync(await fixture.runState(runID))
        let reply = await domain.skillCancel(envelope: fixture.executionEnvelope(
            command: "run.skillcancel", conversationID: conversationID, runID: runID,
            payload: ["expectedState": state], correlation: "corr-skill2",
            revision: ["resourceID": RunWireRevision.runResourceID(runID), "version": state]))
        gate.release()
        guard case .mutationAccepted = reply.outcome else {
            return XCTFail("bound port must accept")
        }
        XCTAssertEqual(fixture.cancellation.cancelled.first?.0, runID)
        XCTAssertNil(fixture.cancellation.cancelled.first?.1, "whole-run cancel has no call id")
    }

    // MARK: - WIRED mailbox dispatch + frozen matrix validation

    func testWiredDispatchThroughRealMailboxSettlesTerminalEffect() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let registry = RuntimeDomainRegistry()
        RunDomainFacade.install(components: fixture.components(), registry: registry)
        let mailbox = FacadeCommandMailbox(effects: fixture.effects, registry: registry)
        mailbox.startDrain()
        let correlation = "corr-wired-snapshot"
        let receipt = try XCTUnwrap(fixture.effects.register(correlationID: correlation))
        let missingRun = UUID()
        let envelopeObject: [String: Any] = [
            "schema": BridgeV3.commandSchema,
            "scope": BridgeV3.Scope.taskExecution.rawValue,
            "command": "run.snapshot",
            "stateful": false,
            "correlationID": correlation,
            "owner": ["taskID": conversationID.uuidString, "runID": missingRun.uuidString],
        ]
        let envelopeData = try JSONSerialization.data(withJSONObject: envelopeObject)
        let job = RuntimeCommandEnvelopeJob(
            correlationID: correlation,
            handlerKey: BridgeV3.handlerKey(scope: .taskExecution, command: "run.snapshot"),
            command: "run.snapshot", scope: .taskExecution, configurationScope: nil,
            receipt: receipt, envelope: envelopeData)
        XCTAssertEqual(mailbox.submit(job), .queued(receipt: receipt))
        let effectStore = fixture.effects
        let settled = await pollFor(timeoutSeconds: 8) {
            effectStore.isTerminal(receipt: receipt)
        }
        mailbox.close(reason: .closed)
        XCTAssertTrue(settled, "the reviewed mailbox must settle one terminal")
        let items = pollEffects(fixture.effects, receipt: receipt)
        XCTAssertEqual(items.filter { $0.isTerminal }.count, 1)
    }

    func testEveryMatrixCommandValidatesAndRoutesToItsHandlerKey() throws {
        // The frozen rules: all 18 plan keys (15 original + the three
        // goal-core batch controls) + event.poll exist and are computed with
        // the live helper.
        RunDomainFacade.install(components: fixture.components(),
                                registry: RuntimeDomainRegistry())
        let matrix = Dictionary(
            uniqueKeysWithValues: BridgeV3.commandRules
                .filter { $0.scope == .taskExecution || $0.scope == .launch
                            || $0.scope == .conversationLifecycle }
                .map { (BridgeV3.handlerKey(scope: $0.scope, command: $0.command), $0) })
        for binding in RunDomainHandlerPlan.bindings {
            XCTAssertNotNil(matrix[binding.handlerKey],
                            "planned key \(binding.handlerKey) missing from the frozen matrix")
            XCTAssertEqual(binding.handlerKey,
                           BridgeV3.handlerKey(scope: binding.scope, command: binding.command))
        }
        // Preserve the original 18 keys; cold history adds one read-only key.
        XCTAssertEqual(Set(RunDomainHandlerPlan.bindings.map(\.handlerKey)).count, 19)
        // event.poll stays SEPARATE (run cursor) from effect.poll.
        XCTAssertFalse(RunDomainHandlerPlan.bindings.contains { $0.command == "event.poll" },
                       "RB4 must not re-register the RB1 pump key")
        XCTAssertEqual(BridgeV3.handlerKey(scope: .taskExecution, command: "event.poll"),
                       "v3.command.taskExecution.event.poll")
        XCTAssertNotEqual(BridgeV3.runEventSchema, BridgeV3.effectSchema)
    }

    func testV3EnvelopeShapesForAllFifteenCommandsValidateStructurally() throws {
        // Exercise the FROZEN validator over synthetic well-formed envelopes
        // (validation only; no handler, no dispatch, no receipt).
        let task = UUID()
        let run = UUID()
        let cases: [(String, BridgeV3.Scope, [String: Any])] = [
            ("run.start", .launch, ["owner": ["taskID": task.uuidString],
                                    "revision": ["resourceID": "conversation.\(task)",
                                                 "version": "v"],
                                    "payload": fixture.startPayload(goal: "x"),
                                    "stateful": true]),
            ("run.startTask", .launch, ["createIntent": true,
                                        "payload": ["title": "t", "goal": "x", "mode": "chat",
                                                    "providerID": task.uuidString,
                                                    "modelID": run.uuidString,
                                                    "approvalMode": "ask"],
                                        "stateful": true]),
        ]
        for (command, scope, body) in cases {
            var envelope: [String: Any] = [
                "schema": BridgeV3.commandSchema,
                "scope": scope.rawValue,
                "command": command,
                "correlationID": "corr-struct-\(command)",
            ]
            for (key, value) in body { envelope[key] = value }
            let result = BridgeV3.validate(envelope: envelope,
                                           requestID: "corr-struct-\(command)",
                                           operation: .submit)
            XCTAssertTrue(result.isValid, "\(command): \(result.errorCode)/\(result.reason)")
        }
        // taskExecution stateful trio with revision + owner roles:
        for command in ["run.cancel", "run.retry", "run.approval.resolve", "run.approval.presentation", "run.policy.update",
                        "run.skillcancel"] {
            let envelope: [String: Any] = [
                "schema": BridgeV3.commandSchema,
                "scope": BridgeV3.Scope.taskExecution.rawValue,
                "command": command,
                "stateful": true,
                "correlationID": "corr-\(command)",
                "owner": ["taskID": task.uuidString, "runID": run.uuidString],
                "revision": ["resourceID": "run.\(run)", "version": "preparing"],
                "payload": ["expectedState": "preparing"],
            ]
            let result = BridgeV3.validate(envelope: envelope, requestID: "corr-\(command)",
                                           operation: .submit)
            XCTAssertTrue(result.isValid, "\(command): \(result.errorCode)/\(result.reason)")
        }
        // Reads WITHOUT revision under taskExecution:
        for command in ["run.snapshot", "run.events", "child.list"] {
            let envelope: [String: Any] = [
                "schema": BridgeV3.commandSchema,
                "scope": BridgeV3.Scope.taskExecution.rawValue,
                "command": command,
                "stateful": false,
                "correlationID": "corr-\(command)",
                "owner": ["taskID": task.uuidString, "runID": run.uuidString],
            ]
            XCTAssertTrue(BridgeV3.validate(envelope: envelope, requestID: "corr-\(command)",
                                            operation: .submit).isValid)
        }
        // event.poll requires the RUN cursor schema and matching run role.
        let eventEnvelope: [String: Any] = [
            "schema": BridgeV3.runEventSchema,
            "scope": BridgeV3.Scope.taskExecution.rawValue,
            "command": "event.poll",
            "stateful": false,
            "correlationID": "corr-events",
            "owner": ["taskID": task.uuidString, "runID": run.uuidString],
            "cursor": ["runID": run.uuidString, "sequence": 0],
        ]
        XCTAssertTrue(BridgeV3.validate(envelope: eventEnvelope, requestID: "corr-events",
                                        operation: .runEventPoll).isValid)
        // The EFFECT cursor schema cannot be used on the event channel — the
        // two stay separate (floe.event-cursor/3 vs floe.effect-cursor/3).
        let crossed = eventEnvelope.merging(["schema": BridgeV3.effectSchema]) { $1 }
        let crossedResult = BridgeV3.validate(envelope: crossed, requestID: "corr-events",
                                              operation: .runEventPoll)
        XCTAssertFalse(crossedResult.isValid)
        XCTAssertEqual(crossedResult.reason, "schemaRoleMismatch")
    }

    func testRelabelledScopeAndUnknownCommandRejected() throws {
        let task = UUID()
        let run = UUID()
        // run.snapshot moved to applicationConfiguration: never authority.
        let bad = [
            "schema": BridgeV3.commandSchema,
            "scope": BridgeV3.Scope.applicationConfiguration.rawValue,
            "configurationScope": "capabilities",
            "command": "run.snapshot",
            "stateful": false,
            "correlationID": "corr-relabel",
        ] as [String: Any]
        let result = BridgeV3.validate(envelope: bad, requestID: "corr-relabel",
                                       operation: .submit)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.reason, "commandScopeMismatch")
    }
}
