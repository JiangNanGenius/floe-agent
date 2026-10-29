// SPDX-License-Identifier: MPL-2.0
//
// G04-R2 UI operation-scoped workspace grant admission — REAL C-ABI + REAL
// generation suite. AUTHORED, NOT RUN in this source lane (Main's grouped
// compile runs it, same discipline as JobsGrantDurableIdentityTests).
// PROPOSED LOCATION: shared/Tests/FloeAndroidCoreTests/
// WorkspaceOperationGrantAdmissionTests.swift
//
// Contract under test (the candidate-02 defect this package repairs — real
// terminal open reaches the pump and dies PUMP_GRANT→PUMP_START_EXCEPTION
// with NO PUMP_GRANT_READY because the ordinary mint requires a persisted
// run row that a UI action never has):
//  * a grant mints ONLY against a registered LIVE `beginG04WorkspaceOperation`
//    lease (real RuntimeOwnedWorkRegistry token + the domain's own
//    validateG04WorkspaceOperation), with the SAME open step's UI interaction
//    identity echoed; unregistered / foreign-UI-identity / lease-ended /
//    cancelled / cross-task bodies refuse with the EXISTING closed
//    `bindingUnavailable` (mint) or `bindingUnresolved` (open) codes;
//  * single-use consumption, the HMAC (operation scope binds `o=` ONLY when
//    present — ordinary run/job grant messages are byte-for-byte the
//    historical tuple) and the store-re-derived root/identity remain the ONLY
//    grant authority; a hand-built operation+job mixed scope is refused by
//    the strict binding parse;
//  * the ORDINARY run mint keeps refusing a never-persisted UI run identity
//    (the shipped behavior stays honest and unchanged) and keeps minting for
//    a seeded ACTIVE run (run lane must not regress);
//  * registrations follow the REAL lease: retire clears the exact mapping,
//    saturation reclaims ONLY proven-dead entries and refuses while every
//    entry is live (Main 2026-10-25 correction: live work never expires by
//    clock). All identities synthetic; no device, engine, provider key, model
//    call or private data.

import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif
import FloeModels
import FloePersistence
import FloeAndroidWorkspaceTools
@testable import FloeAndroidCore

final class WorkspaceOperationGrantAdmissionTests: XCTestCase {

    private enum TestError: Error { case bootstrap, mintReply, bootNotInstalled }

    private enum FixtureEpoch {
        nonisolated(unsafe) static var lock = NSLock()
        nonisolated(unsafe) static var value: UInt64 =
            UInt64(DispatchTime.now().uptimeNanoseconds)
        static func allocate() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            let now = UInt64(DispatchTime.now().uptimeNanoseconds)
            value = Swift.max(value &+ 1, now)
            return value
        }
    }

    private final class Boot {
        let epoch: UInt64
        let receipt: String
        let rootPath: String
        let token: String
        var retired = false
        init(epoch: UInt64, receipt: String, rootPath: String, token: String) {
            self.epoch = epoch; self.receipt = receipt
            self.rootPath = rootPath; self.token = token
        }
    }

    private var tracked: [Boot] = []
    private var trackedOperations: [G04WorkspaceOwnedOperation] = []

    override func tearDown() async throws {
        // These leases were created directly by the test, outside a terminal
        // controller. The fixture must perform the owner's real release
        // before shutdown; cancellation alone deliberately does not detach.
        for operation in trackedOperations.reversed() {
            if let (domain, _) = RunDomainFacade.current(epoch: operation.token.epoch) {
                await domain.endG04WorkspaceOperation(operation)
            }
            LinuxWorkspaceAuthority.retireWorkspaceOperation(operationID: operation.operationID)
            XCTAssertFalse(RuntimeOwnedWorkRegistry.shared.isAttached(operation.token),
                           "the fixture must release its real operation receipt")
        }
        trackedOperations.removeAll()
        for boot in tracked.reversed() where !boot.retired {
            await shutdownAndAwaitClosed(boot)
        }
        tracked.removeAll()
        RunDomainFacade.clearForTesting()
        G02RuntimeComposition.shared.resetForTesting()
        AndroidRuntimeBootstrap.resetForTesting()
        try await super.tearDown()
    }

    /// Real accepted generation + ordinary graph + production run domain
    /// installed (the operation validator lives on the domain actor, so the
    /// lease path exercised here is the SAME object graph the app uses).
    private func bootInstalledGenerationWithRunDomain(
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> Boot {
        let root = NSTemporaryDirectory().appending("g04-operation-grant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let token = String((0..<16).map { _ in "01234789abcdef".randomElement()! })
        let epoch = FixtureEpoch.allocate()
        guard case .accepted(let receipt) = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: token, epoch: epoch) else {
            XCTFail("bootstrap not accepted", file: file, line: line); throw TestError.bootstrap
        }
        let boot = Boot(epoch: epoch, receipt: receipt, rootPath: root, token: token)
        tracked.append(boot)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            guard let gen = AndroidRuntimeBootstrap.currentGenerationForTesting(),
                  gen.epoch == epoch,
                  case .page(let effects, _, _, _) =
                    gen.effects.poll(receipt: receipt, afterSequence: 0),
                  let terminal = effects.first(where: { $0.isTerminal }) else {
                try await Task.sleep(nanoseconds: 10_000_000)
                continue
            }
            guard terminal.kind == .accepted else {
                XCTFail("bootstrap terminal not accepted", file: file, line: line)
                throw TestError.bootstrap
            }
            guard let installed = G02RuntimeComposition.shared.installedComposition,
                  installed.epoch == epoch else {
                try await Task.sleep(nanoseconds: 10_000_000)
                continue
            }
            XCTAssertTrue(LinuxWorkspaceAuthority.isInstalled,
                          "LinuxWorkspaceAuthority not installed for the booted root",
                          file: file, line: line)
            RunDomainFacade.install(components: installed.runComponents, registry: installed.registry)
            guard RunDomainFacade.current(epoch: epoch) != nil else {
                XCTFail("run domain missing after install", file: file, line: line)
                throw TestError.bootNotInstalled
            }
            return boot
        }
        XCTFail("bootstrap terminal did not settle", file: file, line: line)
        throw TestError.bootstrap
    }

    private func shutdownAndAwaitClosed(_ boot: Boot) async {
        guard !boot.retired else { return }
        defer { boot.retired = true }
        switch AndroidRuntimeBootstrap.shutdown(expectedEpoch: boot.epoch, ownerToken: boot.token) {
        case .accepted, .idempotent: break
        case .rejected(let code):
            if code == .notInstalled, AndroidRuntimeBootstrap.currentGenerationForTesting() == nil { return }
            return
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if AndroidRuntimeBootstrap.currentGenerationForTesting() == nil { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Seeds ONE ordinary conversation + canonical privateTask ownership.
    /// NO run row — exactly the real UI terminal shape.
    private func seedConversationOwnedWorkspace(
        title: String = "G04-R2 operation grant"
    ) async throws -> (conversationID: UUID, workspaceID: UUID) {
        let cluster = try XCTUnwrap(G02RuntimeComposition.shared.installedComposition).cluster
        let conversation = ConversationRecord(id: UUID(), title: title,
                                             createdAt: Date(), updatedAt: Date(),
                                             purpose: .ordinary)
        try await cluster.conversationStore.saveConversation(conversation)
        let workspace = WorkspaceRecord(
            name: "Chat", rootBookmark: Data(), kind: .privateTask,
            internalRelativePath: "PrivateTasks/\(conversation.id.uuidString)")
        try await cluster.workspaceStore.saveWorkspace(workspace)
        try await cluster.workspaceStore.assignConversation(
            workspaceID: workspace.id, conversationID: conversation.id)
        return (conversation.id, workspace.id)
    }

    /// Creates the REAL lease and registers it for a fresh UI identity, like
    /// `G04TerminalDomain.open` does. Returns (operation, uiRunID, grantID).
    private func beginAndRegisterOperation(conversationID: UUID, epoch: UInt64)
        async throws -> (operation: G04WorkspaceOwnedOperation, uiRunID: UUID, grantID: String) {
        let (domain, _) = try XCTUnwrap(RunDomainFacade.current(epoch: epoch))
        guard let operation = await domain.beginG04WorkspaceOperation(
            conversationID: conversationID, expectedEpoch: epoch) else {
            throw TestError.mintReply
        }
        trackedOperations.append(operation)
        let uiRunID = UUID()
        XCTAssertTrue(LinuxWorkspaceAuthority.registerWorkspaceOperation(operation, epoch: epoch,
                                                                         uiRunID: uiRunID),
                      "registration must succeed for a live lease under the accepted epoch")
        let grantID = String((0..<32).map { _ in "0123456789abcdef".randomElement()! })
        return (operation, uiRunID, grantID)
    }

    // MARK: - C-ABI helpers (the SAME public @_cdecl entries JNI invokes)

    private func callBindingForOperation(epoch: UInt64, operationID: String, runID: String,
                                         grantID: String) throws -> (code: Int32, body: Data) {
        var out = [CChar](repeating: 0, count: 65_537)
        let n = operationID.withCString { opPtr in
            runID.withCString { runPtr in
                grantID.withCString { grantPtr in
                    out.withUnsafeMutableBufferPointer { buffer in
                        floe_linux_workspace_binding_for_operation(epoch, opPtr, runPtr, grantPtr,
                                                                   buffer.baseAddress, Int32(buffer.count))
                    }
                }
            }
        }
        let body = out.withUnsafeBufferPointer { raw in
            Data(bytes: raw.baseAddress!, count: Int(max(n, 0)))
        }
        return (n, n > 0 ? body : Data())
    }

    private func callBinding(epoch: UInt64, runID: String, grantID: String) throws -> Data {
        var out = [CChar](repeating: 0, count: 65_537)
        let n = runID.withCString { runPtr in
            grantID.withCString { grantPtr in
                out.withUnsafeMutableBufferPointer { buffer in
                    floe_linux_workspace_binding(epoch, runPtr, grantPtr,
                                                 buffer.baseAddress, Int32(buffer.count))
                }
            }
        }
        return n > 0 ? Data(bytes: out.withUnsafeBufferPointer { $0.baseAddress! }, count: Int(n)) : Data()
    }

    private func callOpen(_ envelope: Data) throws -> (code: Int32, body: Data) {
        var out = [CChar](repeating: 0, count: 65_537)
        let n = envelope.withUnsafeBytes { raw in
            out.withUnsafeMutableBufferPointer { buffer in
                floe_linux_workspace_session_open(raw.bindMemory(to: CChar.self).baseAddress,
                                                  Int32(envelope.count),
                                                  buffer.baseAddress, Int32(buffer.count))
            }
        }
        let body = out.withUnsafeBufferPointer { raw in
            Data(bytes: raw.baseAddress!, count: Int(max(n, 0)))
        }
        return (n, n > 0 ? body : Data())
    }

    private func object(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws
        -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = value as? [String: Any] else {
            XCTFail("reply is not a JSON object", file: file, line: line)
            throw TestError.mintReply
        }
        return dictionary
    }

    private func closeSession(_ key: String) {
        _ = key.withCString { floe_linux_workspace_session_close($0) }
    }

    private func callExportBegin(_ key: String) throws -> (code: Int32, body: Data) {
        var out = [CChar](repeating: 0, count: 65_537)
        let n = key.withCString { pointer in
            out.withUnsafeMutableBufferPointer { buffer in
                floe_linux_workspace_export_begin(pointer, buffer.baseAddress, Int32(buffer.count))
            }
        }
        let body = out.withUnsafeBufferPointer { raw in
            Data(bytes: raw.baseAddress!, count: Int(max(n, 0)))
        }
        return (n, n > 0 ? body : Data())
    }

    // MARK: - Positive round trip

    func testLiveRegisteredOperationMintsOpensAndCloses() async throws {
        let boot = try await bootInstalledGenerationWithRunDomain()
        let seeded = try await seedConversationOwnedWorkspace()
        let prepared = try await beginAndRegisterOperation(conversationID: seeded.conversationID,
                                                           epoch: boot.epoch)
        let mint = try callBindingForOperation(epoch: boot.epoch,
                                               operationID: prepared.operation.operationID.uuidString,
                                               runID: prepared.uiRunID.uuidString,
                                               grantID: prepared.grantID)
        let reply = try object(mint.body)
        XCTAssertEqual(reply["ok"] as? Bool, true,
                       "a live registered lease must mint; got \(mint.body)")
        XCTAssertEqual(reply["operationID"] as? String, prepared.operation.operationID.uuidString)
        XCTAssertEqual(reply["runID"] as? String, prepared.uiRunID.uuidString)
        XCTAssertEqual((reply["rootEpoch"] as? NSNumber)?.uint64Value, boot.epoch)
        let open = try callOpen(mint.body)
        let opened = try object(open.body)
        XCTAssertEqual(opened["ok"] as? Bool, true, "operation open must succeed: \(open.body)")
        let sessionKey = try XCTUnwrap(opened["sessionKey"] as? String)
        closeSession(sessionKey)
        // Exact retire after settle: a fresh mint for the retired mapping fails.
        LinuxWorkspaceAuthority.retireWorkspaceOperation(operationID: prepared.operation.operationID)
        let (domain, _) = try XCTUnwrap(RunDomainFacade.current(epoch: boot.epoch))
        await domain.endG04WorkspaceOperation(prepared.operation)
        let after = try callBindingForOperation(epoch: boot.epoch,
                                                operationID: prepared.operation.operationID.uuidString,
                                                runID: prepared.uiRunID.uuidString,
                                                grantID: prepared.grantID)
        let afterReply = try object(after.body)
        XCTAssertEqual(afterReply["ok"] as? Bool, false)
        XCTAssertEqual(afterReply["code"] as? String, "bindingUnavailable")
    }

    /// THE manual-close disconfirmation (G06 workspace-sync31): the runtime's
    /// workspace export runs on the engine's asynchronous stop lane, AFTER
    /// `shell.cancel` was answered. If the UI operation lease is retired then,
    /// Core's grant-currency gate refuses the export and the user's guest file
    /// never reaches the native workspace. Pin that boundary with the REAL
    /// C ABI: the same call passes the currency gate on a live lease (and only
    /// refuses for the untouched session state), while a retired lease refuses
    /// at `runCurrency` BEFORE any staging.
    func testRetiredOperationLeaseRefusesTheWorkspaceExportCurrencyGate() async throws {
        let boot = try await bootInstalledGenerationWithRunDomain()
        let seeded = try await seedConversationOwnedWorkspace()
        let prepared = try await beginAndRegisterOperation(conversationID: seeded.conversationID,
                                                           epoch: boot.epoch)
        let mint = try callBindingForOperation(epoch: boot.epoch,
                                               operationID: prepared.operation.operationID.uuidString,
                                               runID: prepared.uiRunID.uuidString,
                                               grantID: prepared.grantID)
        let open = try callOpen(mint.body)
        let opened = try object(open.body)
        let sessionKey = try XCTUnwrap(opened["sessionKey"] as? String)
        defer { closeSession(sessionKey) }

        // Live lease: the currency gate PASSES; only the fixture's untouched
        // session state (no baseline) refuses, never a proof/runCurrency code.
        let liveReply = try callExportBegin(sessionKey)
        let live = try object(liveReply.body)
        XCTAssertEqual(live["ok"] as? Bool, false)
        XCTAssertEqual(live["code"] as? String, "workspaceMalformed",
                       "a live operation lease must pass the export currency gate: \(live)")

        // The buggy manual-close order: retire the operation lease while the
        // engine stop lane may still be exporting. The very first export
        // transaction is then refused at the real grant-currency gate.
        LinuxWorkspaceAuthority.retireWorkspaceOperation(operationID: prepared.operation.operationID)
        let (domain, _) = try XCTUnwrap(RunDomainFacade.current(epoch: boot.epoch))
        await domain.endG04WorkspaceOperation(prepared.operation)
        let refusedReply = try callExportBegin(sessionKey)
        let refused = try object(refusedReply.body)
        XCTAssertEqual(refused["ok"] as? Bool, false)
        XCTAssertEqual(refused["code"] as? String, "workspaceProofRefused:runCurrency",
                       "retiring the operation lease before export must refuse the export (the G06 loss): \(refused)")
    }

    // MARK: - Negative admissions (closed vocabulary, fail-closed)

    func testUnregisteredOperationRefusesWithBindingUnavailable() async throws {
        let boot = try await bootInstalledGenerationWithRunDomain()
        let reply = try object(callBindingForOperation(
            epoch: boot.epoch, operationID: UUID().uuidString, runID: UUID().uuidString,
            grantID: String((0..<32).map { _ in "0123456789abcdef".randomElement()! })).body)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["code"] as? String, "bindingUnavailable",
                       "unregistered operations reuse the EXISTING closed code")
    }

    func testForeignUIRunIdentityRefuses() async throws {
        let boot = try await bootInstalledGenerationWithRunDomain()
        let seeded = try await seedConversationOwnedWorkspace()
        let prepared = try await beginAndRegisterOperation(conversationID: seeded.conversationID,
                                                           epoch: boot.epoch)
        let reply = try object(callBindingForOperation(
            epoch: boot.epoch, operationID: prepared.operation.operationID.uuidString,
            runID: UUID().uuidString /* NOT the registered identity */,
            grantID: prepared.grantID).body)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["code"] as? String, "bindingUnavailable")
    }

    func testEndedLeaseRefusesMintAndOpen() async throws {
        let boot = try await bootInstalledGenerationWithRunDomain()
        let seeded = try await seedConversationOwnedWorkspace()
        let prepared = try await beginAndRegisterOperation(conversationID: seeded.conversationID,
                                                           epoch: boot.epoch)
        let mint = try callBindingForOperation(epoch: boot.epoch,
                                               operationID: prepared.operation.operationID.uuidString,
                                               runID: prepared.uiRunID.uuidString,
                                               grantID: prepared.grantID)
        XCTAssertEqual(try object(mint.body)["ok"] as? Bool, true)
        // The real lease ends between mint and open (user stopped the pane):
        let (domain, _) = try XCTUnwrap(RunDomainFacade.current(epoch: boot.epoch))
        await domain.endG04WorkspaceOperation(prepared.operation)
        let open = try object(callOpen(mint.body).body)
        XCTAssertEqual(open["ok"] as? Bool, false)
        XCTAssertEqual(open["code"] as? String, "bindingUnresolved",
                       "an ended lease opens NOTHING even with a freshly minted body")
    }

    func testCancellationRefusesMint() async throws {
        let boot = try await bootInstalledGenerationWithRunDomain()
        let seeded = try await seedConversationOwnedWorkspace()
        let prepared = try await beginAndRegisterOperation(conversationID: seeded.conversationID,
                                                           epoch: boot.epoch)
        prepared.operation.cancellation.cancel()
        let reply = try object(callBindingForOperation(
            epoch: boot.epoch, operationID: prepared.operation.operationID.uuidString,
            runID: prepared.uiRunID.uuidString, grantID: prepared.grantID).body)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["code"] as? String, "bindingUnavailable")
    }

    func testCrossGenerationEpochRefuses() async throws {
        let boot = try await bootInstalledGenerationWithRunDomain()
        let seeded = try await seedConversationOwnedWorkspace()
        let prepared = try await beginAndRegisterOperation(conversationID: seeded.conversationID,
                                                           epoch: boot.epoch)
        let reply = try object(callBindingForOperation(
            epoch: boot.epoch &+ 1, operationID: prepared.operation.operationID.uuidString,
            runID: prepared.uiRunID.uuidString, grantID: prepared.grantID).body)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["code"] as? String, "epochNotCurrent")
    }

    // MARK: - Single use + strict scope

    func testMintIsSingleUseForOperationScope() async throws {
        let boot = try await bootInstalledGenerationWithRunDomain()
        let seeded = try await seedConversationOwnedWorkspace()
        let prepared = try await beginAndRegisterOperation(conversationID: seeded.conversationID,
                                                           epoch: boot.epoch)
        let mint = try callBindingForOperation(epoch: boot.epoch,
                                               operationID: prepared.operation.operationID.uuidString,
                                               runID: prepared.uiRunID.uuidString,
                                               grantID: prepared.grantID)
        let first = try object(callOpen(mint.body).body)
        XCTAssertEqual(first["ok"] as? Bool, true)
        closeSession(try XCTUnwrap(first["sessionKey"] as? String))
        let replay = try object(callOpen(mint.body).body)
        XCTAssertEqual(replay["ok"] as? Bool, false)
        XCTAssertEqual(replay["code"] as? String, "grantNotMinted")
    }

    func testOperationPlusJobScopeIsRefusedByStrictParse() throws {
        // Hand-built widened body: a binding cannot carry BOTH the operation
        // scope and the durable-job scope — refused before anything consumes.
        var dictionary: [String: Any] = [
            "version": 1, "projectID": UUID().uuidString, "runID": UUID().uuidString,
            "workspaceID": UUID().uuidString, "rootEpoch": UInt64(1),
            "grantID": String(repeating: "a", count: 32),
            "workspaceFingerprint": String(repeating: "b", count: 12),
            "proof": String(repeating: "0", count: 64),
            "budgets": WorkspaceTransferBudgets.defaults.dictionaryValue,
            "conversationID": UUID().uuidString,
            "operationID": UUID().uuidString,
            "toolCallID": "jobs." + UUID().uuidString,
            "jobID": UUID().uuidString,
        ]
        XCTAssertNil(WorkspaceGrantBinding.from(dictionary: dictionary,
                                                workspaceRootPath: "/nonexistent-strict-parse-check"))
        // The SAME object WITHOUT the job members parses (operation scope is
        // an accepted optional member): proves the refusal is the MIX, not a
        // blanket rejection of the new member.
        dictionary.removeValue(forKey: "toolCallID")
        dictionary.removeValue(forKey: "jobID")
        XCTAssertNotNil(WorkspaceGrantBinding.from(dictionary: dictionary,
                                                   workspaceRootPath: "/nonexistent-strict-parse-check"))
    }

    func testOrdinaryRunAndJobProofMessagesAreByteIdenticalToHistory() throws {
        // Without operationID the message is the frozen FloeWorkspaceGrant.v1
        // tuple — no `o=` segment ever appears for run/job grants (Main must
        // NOT see historical grant proofs change under this patch).
        let secret = Data(repeating: 7, count: 32)
        let proof = WorkspaceGrantProof(secret: secret)
        let projectID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
        let runID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!
        let workspaceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D4")!
        let budgetsJSON = WorkspaceGrantProof.canonicalBudgets(.defaults)
        let historical = "FloeWorkspaceGrant.v1"
            + "\u{00}p=" + projectID.uuidString
            + "\u{00}r=" + runID.uuidString
            + "\u{00}c=" + conversationID.uuidString
            + "\u{00}w=" + workspaceID.uuidString
            + "\u{00}t=-"
            + "\u{00}j=" + UUID(uuidString: "00000000-0000-0000-0000-0000000000E5")!.uuidString
            + "\u{00}e=42"
            + "\u{00}g=abcdef0123456789abcdef0123456789"
            + "\u{00}b=" + budgetsJSON
            + "\u{00}s=/core/root/PrivateTasks/X"
        XCTAssertEqual(proof.message(projectID: projectID, runID: runID,
                                     conversationID: conversationID, workspaceID: workspaceID,
                                     toolCallID: nil,
                                     jobID: UUID(uuidString: "00000000-0000-0000-0000-0000000000E5")!,
                                     rootEpoch: 42,
                                     grantID: "abcdef0123456789abcdef0123456789",
                                     workspaceRootPath: "/core/root/PrivateTasks/X",
                                     budgetsJSON: budgetsJSON),
                       Data(historical.utf8))
        // With the operation scope ONLY the appended segment differs — every
        // earlier byte is unchanged (documented, additive `o=` rule).
        let scoped = proof.message(projectID: projectID, runID: runID,
                                   conversationID: conversationID, workspaceID: workspaceID,
                                   toolCallID: nil, jobID: nil,
                                   operationID: UUID(uuidString: "00000000-0000-0000-0000-0000000000F6")!,
                                   rootEpoch: 42,
                                   grantID: "abcdef0123456789abcdef0123456789",
                                   workspaceRootPath: "/core/root/PrivateTasks/X",
                                   budgetsJSON: budgetsJSON)
        XCTAssertTrue(String(decoding: scoped, as: UTF8.self).hasSuffix("\u{00}o="
                        + UUID(uuidString: "00000000-0000-0000-0000-0000000000F6")!.uuidString
                        + "\u{00}e=42" + "\u{00}g=abcdef0123456789abcdef0123456789"
                        + "\u{00}b=" + budgetsJSON + "\u{00}s=/core/root/PrivateTasks/X"))
    }

    // MARK: - Ordinary-lane non-regression (the shipped gates stay)

    func testOrdinaryMintStillRefusesNeverPersistedUIIdentity() async throws {
        // Documents the EXACT shipped defect gate: the ordinary in-run mint
        // must keep refusing a UI UUID (no run row). This patch does NOT
        // weaken it; the UI lane mints through the operation entry instead.
        let boot = try await bootInstalledGenerationWithRunDomain()
        let reply = try object(callBinding(epoch: boot.epoch, runID: UUID().uuidString,
                                           grantID: String((0..<32).map { _ in "0123456789abcdef".randomElement()! })))
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["code"] as? String, "bindingUnavailable")
    }

    func testActiveRunOrdinaryMintStillWorks() async throws {
        let boot = try await bootInstalledGenerationWithRunDomain()
        let cluster = try XCTUnwrap(G02RuntimeComposition.shared.installedComposition).cluster
        let seeded = try await seedConversationOwnedWorkspace()
        let runID = UUID()
        try await cluster.runStore.saveRun(RunRecord(id: runID,
                                                     conversationID: seeded.conversationID,
                                                     state: "preparing",
                                                     goal: "operation-grant-nonregression",
                                                     startedAt: Date()))
        let reply = try object(callBinding(epoch: boot.epoch, runID: runID.uuidString,
                                           grantID: String((0..<32).map { _ in "0123456789abcdef".randomElement()! })))
        XCTAssertEqual(reply["ok"] as? Bool, true,
                       "the ordinary ACTIVE-run mint (foreground/pre-flight lane) must not regress")
    }

    // MARK: - Saturation: live leases are never evicted (Main correction)

    func testSaturationRefusesWhileAllLeasesLiveAndReclaimsOnlyDead() async throws {
        let boot = try await bootInstalledGenerationWithRunDomain()
        let (domain, _) = try XCTUnwrap(RunDomainFacade.current(epoch: boot.epoch))
        var operations: [G04WorkspaceOwnedOperation] = []
        var uiRuns: [UUID] = []
        var filled = false
        // The private cap is 64 (documented in the authority). Drive past it.
        for _ in 0..<70 {
            let seeded = try await seedConversationOwnedWorkspace(title: "saturation-\(operations.count)")
            guard let operation = await domain.beginG04WorkspaceOperation(
                conversationID: seeded.conversationID, expectedEpoch: boot.epoch) else {
                throw TestError.mintReply
            }
            // Track even a refused registration: begin already attached a
            // real lease, so the fixture remains responsible for ending it.
            trackedOperations.append(operation)
            let uiRun = UUID()
            if LinuxWorkspaceAuthority.registerWorkspaceOperation(operation, epoch: boot.epoch,
                                                                  uiRunID: uiRun) {
                operations.append(operation); uiRuns.append(uiRun)
            } else {
                filled = true
                break
            }
        }
        XCTAssertTrue(filled, "registration must refuse when saturated by LIVE leases")
        // Reclaim one proven-dead lease (exact retire + real end) and a new
        // registration must then succeed.
        let doomed = try XCTUnwrap(operations.first)
        LinuxWorkspaceAuthority.retireWorkspaceOperation(operationID: doomed.operationID)
        await domain.endG04WorkspaceOperation(doomed)
        operations.removeFirst()
        uiRuns.removeFirst()
        let seeded = try await seedConversationOwnedWorkspace(title: "saturation-reclaim")
        guard let replacement = await domain.beginG04WorkspaceOperation(
            conversationID: seeded.conversationID, expectedEpoch: boot.epoch) else {
            throw TestError.mintReply
        }
        trackedOperations.append(replacement)
        XCTAssertTrue(LinuxWorkspaceAuthority.registerWorkspaceOperation(
            replacement, epoch: boot.epoch, uiRunID: UUID()),
            "a reclaimed slot must accept the next live lease")
        // Every still-live registration keeps working (none was silently
        // expired): mint against the FIRST surviving entry.
        if operations.count > 1 {
            let survivor = operations[1]
            let reply = try object(callBindingForOperation(
                epoch: boot.epoch, operationID: survivor.operationID.uuidString,
                runID: uiRuns[1].uuidString,
                grantID: String((0..<32).map { _ in "0123456789abcdef".randomElement()! })).body)
            XCTAssertEqual(reply["ok"] as? Bool, true,
                           "live leases must never be evicted to make room")
        }
    }
}
