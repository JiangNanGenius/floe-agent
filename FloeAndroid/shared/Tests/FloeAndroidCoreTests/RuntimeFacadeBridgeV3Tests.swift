// SPDX-License-Identifier: MPL-2.0
//
// RB-1 source tests — real BridgeV3 routing with the bootstrap binder
// installed. Requests go through the SAME `AndroidBridge.exchange` entry the
// JNI uses: v1/v2 stay byte-frozen, unbound domains keep their unchanged
// fail-closed refusals, and only the closed bootstrap vocabulary becomes
// executable. AUTHORED ONLY: not compiled or executed by this source
// package.
import XCTest
import Foundation
@testable import FloeAndroidCore

final class RuntimeFacadeBridgeV3Tests: XCTestCase {

    private var roots: [String] = []

    // This class is the RB1 bridge-vocabulary component fixture: it tests
    // the frozen RB1 ingress/refusal semantics (bootstrap vocabulary, honest
    // sync lifecycle facts, and domains staying fail-closed BEFORE any
    // domain package binds). The G02 ordinary composition installs the real
    // domain handlers by default, so the class runs under the INTERNAL
    // core-only composition mode — the same explicit component-fixture
    // boundary as the attachment bridge lane. The composed-positive reality
    // (ordinary domains served) is covered by
    // G02CompositionIntegrationTests; no assertion here is weakened.
    override func setUp() {
        super.setUp()
        G02RuntimeComposition.shared.setCompositionModeForTesting(.coreOnly)
        AndroidRuntimeBootstrap.resetForTesting()
        RuntimeRetiredEffectRegistry.shared.removeAllForTesting()
    }

    override func tearDown() {
        AndroidRuntimeBootstrap.resetForTesting()
        G02RuntimeComposition.shared.setCompositionModeForTesting(.ordinaryProduct)
        for root in roots { try? FileManager.default.removeItem(atPath: root) }
        roots.removeAll()
        super.tearDown()
    }

    private func freshRoot() throws -> String {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("floe-rb1-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        roots.append(base.path)
        return base.standardizedFileURL.path
    }

    private func exchange(_ request: String) -> [String: Any]? {
        let data = AndroidBridge.exchange(Data(request.utf8))
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A structurally VALID command.submit envelope for the closed matrix.
    /// A payload is OPTIONAL and additive only — the trusted root can never
    /// come from it (the handler never reads it).
    private func submitEnvelope(correlation: String, command: String,
                                payloadJSON: String? = nil) -> String {
        let payload = payloadJSON.map { "\"payload\":" + $0 + "," } ?? ""
        return """
            {"version":3,"operation":"command.submit","requestID":"\(correlation)",\
            "envelope":{"schema":"floe.command-envelope/3","scope":"applicationConfiguration",\
            \(payload)"configurationScope":"system","command":"\(command)",\
            "stateful":false,"correlationID":"\(correlation)"}}
            """
    }

    private func effectEnvelope(correlation: String, receipt: String,
                                sequence: Int) -> String {
        """
        {"version":3,"operation":"effect.poll","requestID":"\(correlation)","\
        envelope":{"schema":"floe.effect-cursor/3","scope":"applicationConfiguration",\
        "configurationScope":"system","command":"effect.poll","stateful":false,\
        "correlationID":"\(correlation)","\
        effect":{"operationReceiptID":"\(receipt)","sequence":\(sequence)}}}
        """
    }

    private func eventEnvelope(correlation: String, task: UUID, run: UUID,
                               sequence: Int) -> String {
        """
        {"version":3,"operation":"event.poll","requestID":"\(correlation)","\
        envelope":{"schema":"floe.event-cursor/3","scope":"taskExecution",\
        "command":"event.poll","stateful":false,\
        "owner":{"taskID":"\(task.uuidString)","runID":"\(run.uuidString)"},\
        "cursor":{"runID":"\(run.uuidString)","sequence":\(sequence)},\
        "correlationID":"\(correlation)"}}
        """
    }

    // MARK: Fail-closed before bootstrap exists

    func testUnboundCommandsRefuseBeforeAndAfterBootstrapInstall() throws {
        // No generation at all: the frozen wire package's refusal is intact.
        let before = try XCTUnwrap(exchange(submitEnvelope(correlation: "p1",
                                                           command: "system.bootstrap")))
        XCTAssertEqual(before["ok"] as? Bool, false)
        XCTAssertEqual(before["error"] as? String, "runtimeUnavailable")
        XCTAssertEqual(before["reason"] as? String, "commandBinderUnbound")
        // effect.poll/even.poll unbound too.
        let effectBefore = try XCTUnwrap(exchange(effectEnvelope(
            correlation: "p2", receipt: "op:v1:" + String(repeating: "11", count: 16),
            sequence: 0)))
        XCTAssertEqual(effectBefore["reason"] as? String, "effectPumpUnbound")
        let eventBefore = try XCTUnwrap(exchange(eventEnvelope(
            correlation: "p3", task: UUID(), run: UUID(), sequence: 0)))
        XCTAssertEqual(eventBefore["reason"] as? String, "eventPumpUnbound")
    }

    func testBootstrapVocabularyBindsAndDomainsStayRefused() async throws {
        let root = try freshRoot()
        guard case .accepted = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: String(repeating: "a", count: 32), epoch: 1)
        else { return XCTFail("start") }
        // Wait for the real store commit (no fake readiness).
        let deadline = Date().addingTimeInterval(20)
        while !AndroidRuntimeBootstrap.statusSnapshotJSON()
            .contains("\"ownedStoreReady\":true") {
            if Date() > deadline { return XCTFail("store never ready") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // Bound bootstrap command: immediate receipt ONLY.
        let submit = try XCTUnwrap(exchange(submitEnvelope(correlation: "live-1",
                                                           command: "system.bootstrap")))
        XCTAssertEqual(submit["ok"] as? Bool, true)
        XCTAssertEqual(submit["queued"] as? Bool, true)
        let receipt = try XCTUnwrap(submit["operationReceiptID"] as? String)
        XCTAssertTrue(RuntimeOperationReceipt.isValid(receipt))
        // The frozen v3 exchange stamp adds `version`/`requestID` to every
        // response; the handler object itself carries exactly the receipt
        // queue fields (no identity beyond correlation + receipt).
        XCTAssertEqual(Set(submit.keys).subtracting(["version", "requestID"]),
                       ["ok", "schema", "correlationID",
                        "queued", "operationReceiptID"])
        XCTAssertEqual(submit["version"] as? Int, 3)
        XCTAssertEqual(submit["requestID"] as? String, "live-1")
        // The confirm settles accepted without minting any identity.
        var terminal: [String: Any]?
        var attempt = 0
        while attempt < 400 {
            attempt += 1
            let page = try XCTUnwrap(exchange(effectEnvelope(correlation: "live-2-\(attempt)",
                                                             receipt: receipt, sequence: 0)))
            if let effects = page["effects"] as? [[String: Any]],
               let last = effects.last(where: {
                   ["accepted", "failed", "rejected", "cancelled", "replaced", "closed"]
                       .contains($0["kind"] as? String ?? "")
               }) {
                terminal = last
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(terminal?["kind"] as? String, "accepted")
        // Domain commands remain fail-closed even after bootstrap install.
        let providerSave = try XCTUnwrap(exchange(
            """
            {"version":3,"operation":"command.submit","requestID":"dom-1","\
            envelope":{"schema":"floe.command-envelope/3","scope":"applicationConfiguration",\
            "configurationScope":"providers","command":"config.provider.save",\
            "stateful":true,"revision":{"resourceID":"p1","version":"7"},\
            "correlationID":"dom-1"}}
            """))
        XCTAssertEqual(providerSave["ok"] as? Bool, false)
        XCTAssertEqual(providerSave["error"] as? String, "runtimeUnavailable")
        XCTAssertEqual(providerSave["reason"] as? String, "commandBinderUnbound")
        let skills = try XCTUnwrap(exchange(
            """
            {"version":3,"operation":"command.submit","requestID":"dom-2","\
            envelope":{"schema":"floe.command-envelope/3","scope":"applicationConfiguration",\
            "configurationScope":"skills","command":"skills.list",\
            "stateful":false,"correlationID":"dom-2"}}
            """))
        XCTAssertEqual(skills["reason"] as? String, "commandBinderUnbound")
    }

    // MARK: system.lifecycle immediate honest facts

    func testLifecycleAnswersSynchronouslyFromSnapshot() async throws {
        let root = try freshRoot()
        guard case .accepted = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: String(repeating: "b", count: 32), epoch: 1)
        else { return XCTFail("start") }
        let response = try XCTUnwrap(exchange(submitEnvelope(correlation: "life-1",
                                                             command: "system.lifecycle")))
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(response["correlationID"] as? String, "life-1")
        let lifecycle = try XCTUnwrap(response["lifecycle"] as? [String: Any])
        // Synchronous answer never claims domain readiness.
        XCTAssertEqual(lifecycle["domainRuntimeReady"] as? Bool, false)
        XCTAssertEqual(lifecycle["ordinaryRuntimeAdmission"] as? String, "blocked")
        let missing = try XCTUnwrap(lifecycle["missingBindings"] as? [String])
        XCTAssertTrue(missing.contains("credentialVaultAdapter"))
        XCTAssertTrue(missing.contains("credentialArgumentNormalizer"))
    }

    // MARK: effect.poll honesty on foreign receipts

    func testForeignReceiptResolvesTypedNotFoundNeverFabricated() async throws {
        let root = try freshRoot()
        guard case .accepted = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: String(repeating: "c", count: 32), epoch: 1)
        else { return XCTFail("start") }
        let response = try XCTUnwrap(exchange(effectEnvelope(
            correlation: "eff-1",
            receipt: "op:v1:" + String(repeating: "dd", count: 16), sequence: 0)))
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertEqual(response["reason"] as? String, "effectReceiptNotFound")
    }

    // MARK: event.poll: real run cursor, honest window absence

    func testEventPollForUnknownRunNeverInventsEvents() async throws {
        let root = try freshRoot()
        guard case .accepted = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: String(repeating: "d", count: 32), epoch: 1)
        else { return XCTFail("start") }
        let response = try XCTUnwrap(exchange(eventEnvelope(
            correlation: "evt-1", task: UUID(), run: UUID(), sequence: 0)))
        XCTAssertEqual(response["ok"] as? Bool, true)   // pump bound and answering
        let durable = try XCTUnwrap(response["durable"] as? [String: Any])
        XCTAssertEqual(durable["windowState"] as? String, "notAttached")
        let events = durable["events"] as? [Any]
        XCTAssertEqual(events?.count, 0)
        let live = try XCTUnwrap(response["live"] as? [String: Any])
        XCTAssertEqual(live["liveState"] as? String, "noConsumer")
    }

    // MARK: RB1-R1 — terminal routing through the ACTUAL v3 entry

    func testShutdownTerminalReadableThroughActualV3AfterDatabaseClose() async throws {
        let root = try freshRoot()
        let token = String(repeating: "a", count: 32)
        guard case .accepted = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: token, epoch: 1) else {
            return XCTFail("start")
        }
        await waitStoreReady()
        guard case .accepted(let control) = AndroidRuntimeBootstrap.shutdown(
            expectedEpoch: 1, ownerToken: token) else {
            return XCTFail("shutdown")
        }
        // This waits for the REAL close/release; the poll below therefore
        // exercises the retired route, not a direct pump reference.
        await waitGenerationGone()
        XCTAssertNil(AndroidRuntimeBootstrap.currentGenerationForTesting())
        let terminal = try await pollTerminalViaV3(receipt: control)
        XCTAssertEqual(terminal["kind"] as? String, "accepted")
        XCTAssertTrue(AndroidRuntimeBootstrap.statusSnapshotJSON()
            .contains("\"phase\":\"stopped\""))
        XCTAssertTrue(AndroidRuntimeBootstrap.statusSnapshotJSON()
            .contains("\"effectPollAvailable\":true"))
    }

    func testNewGenerationKeepsOldShutdownTerminalReadableWithoutRoutingIntoNewPump() async throws {
        let root = try freshRoot()
        let token = String(repeating: "b", count: 32)
        guard case .accepted = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: token, epoch: 1) else {
            return XCTFail("start one")
        }
        await waitStoreReady()
        guard case .accepted(let firstControl) = AndroidRuntimeBootstrap.shutdown(
            expectedEpoch: 1, ownerToken: token) else {
            return XCTFail("stop one")
        }
        await waitGenerationGone()
        let firstTerminal = try await pollTerminalViaV3(receipt: firstControl)
        XCTAssertEqual(firstTerminal["kind"] as? String, "accepted")
        guard case .accepted = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: token, epoch: 2) else {
            return XCTFail("start two")
        }
        await waitStoreReady()
        let gen2 = try XCTUnwrap(AndroidRuntimeBootstrap.currentGenerationForTesting())
        // The OLD receipt is answerable through the wire while the NEW pump
        // never sees it (no stale routing into the new generation).
        let oldAgain = try await pollTerminalViaV3(receipt: firstControl)
        XCTAssertEqual(oldAgain["kind"] as? String, "accepted")
        if case .notFound = gen2.effects.poll(receipt: firstControl, afterSequence: 0) {
            // expected: a new generation's pump is independent
        } else { XCTFail("old receipt must not enter the new pump") }
        let secondBootstrap = gen2.bootstrapReceipt
        let secondBootstrapTerminal = try await pollTerminalViaV3(receipt: secondBootstrap)
        XCTAssertEqual(secondBootstrapTerminal["kind"] as? String, "accepted")
        guard case .accepted(let secondControl) = AndroidRuntimeBootstrap.shutdown(
            expectedEpoch: 2, ownerToken: token) else {
            return XCTFail("stop two")
        }
        await waitGenerationGone()
        // Both retained generations remain readable (bounded two-generation
        // window), each from its own retired snapshot.
        let firstRetained = try await pollTerminalViaV3(receipt: firstControl)
        XCTAssertEqual(firstRetained["kind"] as? String, "accepted")
        let secondRetained = try await pollTerminalViaV3(receipt: secondControl)
        XCTAssertEqual(secondRetained["kind"] as? String, "accepted")
    }

    func testRetiredReceiptExpiryAndForeignReceiptAreTyped() async throws {
        let root = try freshRoot()
        let token = String(repeating: "c", count: 32)
        var firstReceipt: String?
        for epoch in 1...3 {
            guard case .accepted(let bootstrapReceipt) = AndroidRuntimeBootstrap.start(
                rootPath: root, ownerToken: token, epoch: UInt64(epoch)) else {
                return XCTFail("start \(epoch)")
            }
            if epoch == 1 { firstReceipt = bootstrapReceipt }
            await waitStoreReady()
            guard case .accepted = AndroidRuntimeBootstrap.shutdown(
                expectedEpoch: UInt64(epoch), ownerToken: token) else {
                return XCTFail("stop \(epoch)")
            }
            await waitGenerationGone()
        }
        let evicted = try XCTUnwrap(firstReceipt)
        let expired = try XCTUnwrap(exchange(effectEnvelope(
            correlation: "expired-1", receipt: evicted, sequence: 0)))
        XCTAssertEqual(expired["ok"] as? Bool, false)
        XCTAssertEqual(expired["reason"] as? String, "effectReceiptExpired")
        let foreign = try XCTUnwrap(exchange(effectEnvelope(
            correlation: "foreign-1",
            receipt: "op:v1:" + String(repeating: "dd", count: 16), sequence: 0)))
        XCTAssertEqual(foreign["ok"] as? Bool, false)
        XCTAssertEqual(foreign["reason"] as? String, "effectReceiptNotFound")
    }

    func testFailedBootstrapTerminalPollableThroughV3() async throws {
        let base = try freshRoot()
        let blocker = URL(fileURLWithPath: base).appendingPathComponent("file")
        FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
        let badRoot = blocker.appendingPathComponent("sub", isDirectory: true).path
        let token = String(repeating: "d", count: 32)
        guard case .accepted(let receipt) = AndroidRuntimeBootstrap.start(
            rootPath: badRoot, ownerToken: token, epoch: 1) else {
            return XCTFail("start")
        }
        await waitGenerationGone()
        XCTAssertTrue(AndroidRuntimeBootstrap.statusSnapshotJSON()
            .contains("\"phase\":\"failed\""))
        let terminal = try await pollTerminalViaV3(receipt: receipt)
        XCTAssertEqual(terminal["kind"] as? String, "failed")
        XCTAssertEqual(terminal["code"] as? String, "checkpointDirectoryFailed")
    }

    // MARK: RB1-R4 — public system.shutdown receipt is the real control

    func testPublicShutdownReceiptNotTerminalWhileOwnedWorkRuns() async throws {
        let root = try freshRoot()
        let token = String(repeating: "e", count: 32)
        guard case .accepted = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: token, epoch: 1) else {
            return XCTFail("start")
        }
        await waitStoreReady()
        let gen = try XCTUnwrap(AndroidRuntimeBootstrap.currentGenerationForTesting())
        let gate = V3BlockingGate()
        gen.registry.register(
            handlerKey: RuntimeFacadeBridge.systemBootstrapKey,
            processor: RuntimeAsyncProcessor { _ in
                gate.wait()
                return .accepted()
            })
        let blocker = try XCTUnwrap(exchange(submitEnvelope(
            correlation: "public-blocker", command: "system.bootstrap")))
        let blockerReceipt = try XCTUnwrap(blocker["operationReceiptID"] as? String)
        await waitForCondition { gen.mailbox.snapshotCountsForTesting().active >= 1 }
        let shutdown = try XCTUnwrap(exchange(submitEnvelope(
            correlation: "public-stop", command: "system.shutdown")))
        XCTAssertEqual(shutdown["ok"] as? Bool, true)
        XCTAssertEqual(shutdown["queued"] as? Bool, true)
        let shutdownReceipt = try XCTUnwrap(shutdown["operationReceiptID"] as? String)
        // Wait until the public job adopted the control (phase draining).
        var sawDraining = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if AndroidRuntimeBootstrap.statusSnapshotJSON()
                .contains("\"phase\":\"draining\"") {
                sawDraining = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(sawDraining)
        // The public receipt is NOT terminal while the DB is open and real
        // owned work still runs.
        let early = try XCTUnwrap(exchange(effectEnvelope(
            correlation: "public-early", receipt: shutdownReceipt, sequence: 0)))
        XCTAssertEqual(early["ok"] as? Bool, true)
        let earlyEffects = try XCTUnwrap(early["effects"] as? [[String: Any]])
        XCTAssertTrue(earlyEffects.filter { item in
            ["accepted", "failed", "rejected", "cancelled", "replaced", "closed"]
                .contains(item["kind"] as? String ?? "")
        }.isEmpty)
        XCTAssertNotNil(AndroidRuntimeBootstrap.currentGenerationForTesting())
        XCTAssertTrue(AndroidRuntimeBootstrap.statusSnapshotJSON()
            .contains("\"ownedStoreReady\":true"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: root).appendingPathComponent("floe.sqlite").path))
        // Release the real work: the ONE public receipt is the control and
        // settles accepted only after the drain + real DB close.
        gate.openNow()
        let terminal = try await pollTerminalViaV3(receipt: shutdownReceipt)
        XCTAssertEqual(terminal["kind"] as? String, "accepted")
        XCTAssertNil(AndroidRuntimeBootstrap.currentGenerationForTesting())
        let stopped = AndroidRuntimeBootstrap.statusSnapshotJSON()
        XCTAssertTrue(stopped.contains("\"phase\":\"stopped\""))
        XCTAssertTrue(stopped.contains("\"ownedStoreReady\":false"))
        _ = blockerReceipt
    }

    func testLifecyclePayloadRootOrOwnerFieldsRefused() async throws {
        let root = try freshRoot()
        let token = String(repeating: "f", count: 32)
        guard case .accepted = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: token, epoch: 1) else {
            return XCTFail("start")
        }
        await waitStoreReady()
        let bootstrap = try XCTUnwrap(exchange(submitEnvelope(
            correlation: "payload-1", command: "system.bootstrap",
            payloadJSON: "{\"rootPath\":\"/data/local/tmp/evil\"}")))
        XCTAssertEqual(bootstrap["ok"] as? Bool, false)
        XCTAssertEqual(bootstrap["error"] as? String, "invalidEnvelope")
        XCTAssertEqual(bootstrap["reason"] as? String, "invalidLifecyclePayload")
        let shutdown = try XCTUnwrap(exchange(submitEnvelope(
            correlation: "payload-2", command: "system.shutdown",
            payloadJSON: "{\"ownerEpoch\":1,\"root\":\"/x\"}")))
        XCTAssertEqual(shutdown["ok"] as? Bool, false)
        XCTAssertEqual(shutdown["reason"] as? String, "invalidLifecyclePayload")
        // No mutation/fake success: the current generation is untouched.
        let gen = try XCTUnwrap(AndroidRuntimeBootstrap.currentGenerationForTesting())
        XCTAssertEqual(gen.epoch, 1)
        XCTAssertTrue(AndroidRuntimeBootstrap.statusSnapshotJSON()
            .contains("\"ownedStoreReady\":true"))
    }

    func testBootstrapConfirmationRequiresCurrentCommittedGeneration() async throws {
        let root = try freshRoot()
        let token = String(repeating: "1", count: 32)
        guard case .accepted = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: token, epoch: 1) else {
            return XCTFail("start")
        }
        await waitStoreReady()
        let confirm = try XCTUnwrap(exchange(submitEnvelope(
            correlation: "confirm-1", command: "system.bootstrap")))
        let receipt = try XCTUnwrap(confirm["operationReceiptID"] as? String)
        let confirmTerminal = try await pollTerminalViaV3(receipt: receipt)
        XCTAssertEqual(confirmTerminal["kind"] as? String, "accepted")
        guard case .accepted = AndroidRuntimeBootstrap.shutdown(
            expectedEpoch: 1, ownerToken: token) else {
            return XCTFail("stop")
        }
        await waitGenerationGone()
        XCTAssertFalse(AndroidRuntimeBootstrap.confirmCommitted(expectedEpoch: 1))
        // After teardown the confirmation handler is unbound again.
        let after = try XCTUnwrap(exchange(submitEnvelope(
            correlation: "confirm-2", command: "system.bootstrap")))
        XCTAssertEqual(after["ok"] as? Bool, false)
        XCTAssertEqual(after["reason"] as? String, "commandBinderUnbound")
    }

    // MARK: Frozen compatibility stays intact

    func testV1HandshakeAndV2PathsUnchangedByBinderInstall() async throws {
        let root = try freshRoot()
        guard case .accepted = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: String(repeating: "e", count: 32), epoch: 1)
        else { return XCTFail("start") }
        // v1 handshake unchanged.
        let v1 = try XCTUnwrap(exchange(
            """
            {"version":1,"operation":"handshake","requestID":"h1"}
            """))
        XCTAssertEqual(v1["ok"] as? Bool, true)
        XCTAssertEqual(v1["core"] as? String, "FloeAndroidCore")
        // v2 unbound command keeps the frozen v2 refusal semantics.
        let v2Request = "{\"version\":2,\"operation\":\"command.submit\"," +
            "\"requestID\":\"v2-1\",\"envelope\":{" +
            "\"schema\":\"floe.command-envelope/2\",\"command\":\"chat.send\"," +
            "\"scope\":\"taskExecution\",\"stateful\":true,\"owner\":{" +
            "\"taskID\":\"\(UUID().uuidString)\",\"runID\":\"\(UUID().uuidString)\"," +
            "\"environmentID\":\"\(UUID().uuidString)\"," +
            "\"jobID\":\"\(UUID().uuidString)\"}," +
            "\"revision\":{\"resourceID\":\"t\",\"version\":\"1\"}," +
            "\"correlationID\":\"v2-1\"}}"
        let v2 = try XCTUnwrap(exchange(v2Request))
        XCTAssertEqual(v2["ok"] as? Bool, false, "v2 request=\(v2Request) response=\(v2)")
        XCTAssertEqual(v2["error"] as? String, "runtimeUnavailable", "request=\(v2Request.debugDescription) response=\(v2)")
        // v3 negotiation: the handshake's STAGED bound=false flag is the
        // wire package's static text; actual binding truth is the route
        // behaviour above, and businessCapabilities stays empty.
        let v3Handshake = try XCTUnwrap(exchange(
            """
            {"version":3,"operation":"handshake","requestID":"h3"}
            """))
        XCTAssertEqual((v3Handshake["businessCapabilities"] as? [Any])?.count, 0)
    }

    func testOversizedRequestRefusedAtFrozenBound() {
        let huge = String(repeating: "a", count: 70_000)
        let request = """
            {"version":3,"operation":"command.submit","requestID":"\(huge)",\
            "envelope":{"schema":"floe.command-envelope/3",\
            "scope":"applicationConfiguration","configurationScope":"system",\
            "command":"system.lifecycle","stateful":false,"correlationID":"\(huge)"}}
            """
        let response = exchange(request) ?? [:]
        XCTAssertEqual(response["error"] as? String, "requestTooLarge")
    }

    func testCorrelationMismatchNeverDispatches() throws {
        let request = """
            {"version":3,"operation":"command.submit","requestID":"right-1",\
            "envelope":{"schema":"floe.command-envelope/3",\
            "scope":"applicationConfiguration","configurationScope":"system",\
            "command":"system.lifecycle","stateful":false,"correlationID":"wrong-1"}}
            """
        let response = try XCTUnwrap(exchange(request))
        XCTAssertEqual(response["error"] as? String, "invalidEnvelope")
        XCTAssertEqual(response["reason"] as? String, "correlationMismatch")
    }
    // MARK: R1/R4 helpers

    private func waitStoreReady() async {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if AndroidRuntimeBootstrap.statusSnapshotJSON()
                .contains("\"ownedStoreReady\":true") { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("store never ready: \(AndroidRuntimeBootstrap.statusSnapshotJSON())")
    }

    private func waitGenerationGone() async {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if AndroidRuntimeBootstrap.currentGenerationForTesting() == nil { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("generation never retired")
    }

    private func waitForCondition(timeoutSeconds: TimeInterval = 5,
                                  _ predicate: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func pollTerminalViaV3(receipt: String) async throws -> [String: Any] {
        var attempts = 0
        var lastPage: [String: Any] = [:]
        var lastRequest = ""
        while attempts < 500 {
            attempts += 1
            let requestText = effectEnvelope(
                correlation: "ret-poll-\(attempts)", receipt: receipt, sequence: 0)
            let page = try XCTUnwrap(exchange(requestText))
            lastPage = page
            lastRequest = requestText
            if page["ok"] as? Bool == true,
               let effects = page["effects"] as? [[String: Any]],
               let terminal = effects.last(where: { item in
                   ["accepted", "failed", "rejected", "cancelled", "replaced", "closed"]
                       .contains(item["kind"] as? String ?? "")
               }) {
                return terminal
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let diagnostics = "retiredGenerations=\(RuntimeRetiredEffectRegistry.shared.retainedGenerationCount) direct=\(RuntimeRetiredEffectRegistry.shared.poll(receipt: receipt, afterSequence: 0)) status=\(AndroidRuntimeBootstrap.statusSnapshotJSON())"
        XCTFail("terminal never became readable for \(receipt); last page=\(lastPage) request=\(lastRequest) diagnostics=\(diagnostics)")
        return [:]
    }

}


/// Test-only gate for the public-shutdown test.
private final class V3BlockingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var open = false
    func wait() {
        condition.lock()
        while !open { condition.wait() }
        condition.unlock()
    }
    func openNow() {
        condition.lock()
        open = true
        condition.broadcast()
        condition.unlock()
    }
}
