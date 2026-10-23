// SPDX-License-Identifier: MPL-2.0
//
// G03-R3 durable-job grant admission identity — REAL C-ABI + REAL DB suite.
// AUTHORED, NOT RUN in this source lane (Main's grouped compile runs it,
// same discipline as WorkspaceGrantEnvelopeRoundTripTests).
//
// Contract under test (the deterministic R3 jobs-only grant admission defect
// this package repairs — candidate 07: ordinary jobs.submit(exec.shell)
// settled exit125 runtime_not_started with the pump log showing ONLY
// PUMP_REGISTER/PUMP_OWNED/PUMP_GRANT/PUMP_START_EXCEPTION, no GRANT_READY
// and no runtime dispatch):
//  * the session-open job fence compares the wire claim against the
//    ORIGINAL durable processor identity RE-DERIVED FROM THE PROVEN ROW
//    (`LinuxWorkspaceAuthority.durableJobCallID(rowID:)` — the exact
//    `jobs.<rowID uuidString>` grammar `BackgroundJobService.start` freezes
//    into the processor ToolContext), never against `row.toolCallID`, which
//    is the submitting `jobs.submit` PROVIDER call id (the store's
//    (runID, toolCallID) idempotency key). The two identity spaces never
//    coincide, so the pre-repair fence refused every model-submitted
//    exec.shell job grant with `jobCallMismatch`;
//  * the surrounding fences stay closed and unchanged: a non-durable claim
//    can never mint, a durable-shaped claim for a job with NO live ORIGINAL
//    ownership can never mint (no inferred job), an empty/NULL toolCall
//    keeps the ordinary in-run behavior byte-for-byte (the foreground lane
//    that PASSED on candidate 07 must not regress), and an unminted
//    hand-built job-shape body dies at the store-resolution fence
//    (`bindingUnresolved`) BEFORE any identity comparison or mint
//    consumption. Single-use consumption, the HMAC proof and the
//    store-re-derived root/identity remain the only grant authority;
//    nothing here fabricates ownership or weakens provenance.
//
// Lifecycle boundary: each booted test owns ONE monotonic generation over a
// synthetic trusted root, retires it through the real shutdown control in
// tearDown and relies on the composition reset chain, exactly like the
// envelope suite, so suite order is irrelevant. All identities are
// synthetic: the observed candidate-07 job row id and submitting provider
// call id are reused here as FIXED SYNTHETIC VALUES (identities, not
// credentials); no device, engine, provider key, model call or private data.

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
@testable import FloeAndroidCore

final class JobsGrantDurableIdentityTests: XCTestCase {

    private enum TestError: Error { case bootstrap, mintReply }

    private enum FixtureEpoch {
        nonisolated(unsafe) static var lock = NSLock()
        /// Dominates BOTH epoch bases other fixtures use (Date-based
        /// milliseconds AND uptime nanoseconds); strictly monotonic.
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
            self.epoch = epoch
            self.receipt = receipt
            self.rootPath = rootPath
            self.token = token
        }
    }

    private var tracked: [Boot] = []

    override func tearDown() async throws {
        for boot in tracked.reversed() where !boot.retired {
            await shutdownAndAwaitClosed(boot)
        }
        tracked.removeAll()
        G02RuntimeComposition.shared.resetForTesting()
        AndroidRuntimeBootstrap.resetForTesting()
        try await super.tearDown()
    }

    @discardableResult
    private func bootInstalledGeneration(file: StaticString = #filePath, line: UInt = #line)
        async throws -> Boot {
        let root = androidTestFixtureDirectory
            .appendingPathComponent("g03-jobs-grant-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(atPath: root.path, withIntermediateDirectories: true)
        let token = String((0..<16).map { _ in "0123456789abcdef".randomElement()! })
        let epoch = FixtureEpoch.allocate()
        guard case .accepted(let receipt) = AndroidRuntimeBootstrap.start(
            rootPath: root.path, ownerToken: token, epoch: epoch) else {
            XCTFail("bootstrap not accepted (root preserved: \(root.path))", file: file, line: line)
            throw TestError.bootstrap
        }
        let boot = Boot(epoch: epoch, receipt: receipt, rootPath: root.path, token: token)
        tracked.append(boot)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            guard let gen = AndroidRuntimeBootstrap.currentGenerationForTesting(),
                  gen.epoch == epoch else {
                XCTFail("generation vanished before its accepted terminal: "
                            + AndroidRuntimeBootstrap.statusSnapshotJSON(),
                        file: file, line: line)
                throw TestError.bootstrap
            }
            guard case .page(let effects, _, _, _) =
                    gen.effects.poll(receipt: receipt, afterSequence: 0),
                  let terminal = effects.first(where: { $0.isTerminal }) else {
                try await Task.sleep(nanoseconds: 10_000_000)
                continue
            }
            guard terminal.kind == .accepted else {
                XCTFail("bootstrap terminal not accepted: \(terminal.kind)", file: file, line: line)
                throw TestError.bootstrap
            }
            guard let installed = G02RuntimeComposition.shared.installedComposition,
                  installed.epoch == epoch else {
                XCTFail("ordinary graph not installed for the accepted bootstrap (epoch \(epoch))",
                        file: file, line: line)
                throw TestError.bootstrap
            }
            XCTAssertTrue(LinuxWorkspaceAuthority.isInstalled,
                          "LinuxWorkspaceAuthority not installed for the booted root",
                          file: file, line: line)
            return boot
        }
        XCTFail("bootstrap terminal did not settle", file: file, line: line)
        throw TestError.bootstrap
    }

    private func shutdownAndAwaitClosed(_ boot: Boot,
                                        file: StaticString = #filePath, line: UInt = #line) async {
        guard !boot.retired else { return }
        defer { boot.retired = true }
        switch AndroidRuntimeBootstrap.shutdown(
            expectedEpoch: boot.epoch, ownerToken: boot.token) {
        case .accepted, .idempotent:
            break
        case .rejected(let code):
            if code == .notInstalled,
               AndroidRuntimeBootstrap.currentGenerationForTesting() == nil {
                return
            }
            XCTFail("shutdown not accepted for epoch \(boot.epoch): \(code.rawValue)",
                    file: file, line: line)
            return
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if AndroidRuntimeBootstrap.currentGenerationForTesting() == nil {
                let status = AndroidRuntimeBootstrap.statusSnapshotJSON()
                if status.contains("\"ownedStorePhase\":\"closed\"")
                    || !status.contains("\"generation\"") {
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("generation did not reach closed/gone for epoch \(boot.epoch)",
                file: file, line: line)
    }

    /// Seeds ONE ordinary ACTIVE conversation + its canonical privateTask
    /// ownership + ONE non-terminal run through the ORIGINAL cluster stores
    /// (the same shapes the envelope suite seeds; the parent run stays
    /// non-terminal so the ordinary mint branch is exercised exactly like
    /// the candidate-07 foreground success).
    private func seedActiveRun() async throws -> (runID: UUID, conversationID: UUID, workspaceID: UUID) {
        let cluster = try XCTUnwrap(G02RuntimeComposition.shared.installedComposition).cluster
        let conversation = ConversationRecord(id: UUID(), title: "R3 jobs grant identity",
                                             createdAt: Date(), updatedAt: Date(),
                                             purpose: .ordinary)
        try await cluster.conversationStore.saveConversation(conversation)
        let workspace = WorkspaceRecord(
            name: "Chat", rootBookmark: Data(), kind: .privateTask,
            internalRelativePath: "PrivateTasks/\(conversation.id.uuidString)")
        try await cluster.workspaceStore.saveWorkspace(workspace)
        try await cluster.workspaceStore.assignConversation(
            workspaceID: workspace.id, conversationID: conversation.id)
        let runID = UUID()
        try await cluster.runStore.saveRun(RunRecord(id: runID,
                                                     conversationID: conversation.id,
                                                     state: "preparing",
                                                     goal: "jobs-grant-identity",
                                                     startedAt: Date()))
        return (runID, conversation.id, workspace.id)
    }

    // MARK: - C-ABI helpers (the SAME public @_cdecl entries JNI invokes)

    private static func randomGrantID() -> String {
        String((0..<32).map { _ in "0123456789abcdef".randomElement()! })
    }

    private func callBindingForCall(epoch: UInt64, runID: String, toolCallID: String,
                                    grantID: String) throws -> (code: Int32, body: Data) {
        var out = [CChar](repeating: 0, count: 65_537)
        let n = runID.withCString { runPtr in
            toolCallID.withCString { callPtr in
                grantID.withCString { grantPtr in
                    out.withUnsafeMutableBufferPointer { buffer in
                        floe_linux_workspace_binding_for_call(epoch, runPtr, callPtr, grantPtr,
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

    private func callOpen(dictionary: [String: Any]) throws -> (code: Int32, body: Data) {
        try callOpen(try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]))
    }

    private func object(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws
        -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = value as? [String: Any] else {
            XCTFail("reply is not a JSON object: \(String(decoding: data, as: UTF8.self))",
                    file: file, line: line)
            throw TestError.mintReply
        }
        return dictionary
    }

    private func closeSession(_ key: String) {
        _ = key.withCString { floe_linux_workspace_session_close($0) }
    }

    // MARK: - The repaired identity contract

    /// The fence's expected value is the ROW-DERIVED durable processor
    /// identity, canonical uppercase, exactly the grammar the ORIGINAL
    /// service freezes for the processor ToolContext. Synthetic copies of
    /// the observed candidate-07 failure identities prove the identity-space
    /// split that made the pre-repair fence unsatisfiable: the submitting
    /// provider call id (`row.toolCallID`) can never equal the durable
    /// claim, while the row-derived identity equals it by construction.
    func testDurableJobCallIDIsTheRowDerivedCanonicalIdentity() throws {
        let rowID = try XCTUnwrap(UUID(uuidString: "DB8FFC71-B37D-4D1D-879C-06A1D6852164"))
        let submittedProviderCallID = "call_r3c_2c3a3161fd_000001"
        XCTAssertEqual(LinuxWorkspaceAuthority.durableJobCallID(rowID: rowID),
                       "jobs.DB8FFC71-B37D-4D1D-879C-06A1D6852164")
        // THE CAUSAL REGRESSION: pre-repair, session_open compared the
        // durable claim against `row.toolCallID` (this provider-call-id
        // space), so EVERY model-submitted job grant died at
        // `jobCallMismatch` before GRANT_READY.
        XCTAssertNotEqual(LinuxWorkspaceAuthority.durableJobCallID(rowID: rowID),
                          submittedProviderCallID)
        // Canonical uppercase rides UNCHANGED; a lowercase echo is NOT the
        // durable identity (it still refuses at the fence, as before).
        XCTAssertNotEqual(LinuxWorkspaceAuthority.durableJobCallID(rowID: rowID),
                          "jobs.db8ffc71-b37d-4d1d-879c-06a1d6852164")
        let other = UUID()
        XCTAssertNotEqual(LinuxWorkspaceAuthority.durableJobCallID(rowID: other),
                          LinuxWorkspaceAuthority.durableJobCallID(rowID: rowID))
    }

    /// The mint-side fences stay closed and unchanged: a SUBMIT-call-shaped
    /// claim (the identity the OLD fence wrongly expected) can never mint a
    /// durable grant, and a durable-SHAPED claim for a job the ORIGINAL
    /// service does not actually own never mints either — no inferred job,
    /// no fabricated ownership.
    func testForeignAndUnownedClaimsNeverMint() async throws {
        let boot = try await bootInstalledGeneration()
        let seeded = try await seedActiveRun()

        let providerShaped = try callBindingForCall(
            epoch: boot.epoch, runID: seeded.runID.uuidString,
            toolCallID: "call_r3c_2c3a3161fd_000001", grantID: Self.randomGrantID())
        let providerReply = try object(providerShaped.body)
        XCTAssertEqual(providerReply["ok"] as? Bool, false)
        XCTAssertEqual(providerReply["code"] as? String, "bindingUnavailable",
                       "a non-durable claim must never mint a durable grant")

        let unownedJob = try callBindingForCall(
            epoch: boot.epoch, runID: seeded.runID.uuidString,
            toolCallID: LinuxWorkspaceAuthority.durableJobCallID(rowID: UUID()),
            grantID: Self.randomGrantID())
        let unownedReply = try object(unownedJob.body)
        XCTAssertEqual(unownedReply["ok"] as? Bool, false)
        XCTAssertEqual(unownedReply["code"] as? String, "bindingUnavailable",
                       "a durable claim without ORIGINAL live job ownership must fail closed")

        // Neither refusal produced a mint: forwarding the error bodies to
        // session_open stays a malformed-envelope refusal (no scope, no
        // session, no consumption) — unchanged envelope discipline.
        for body in [providerShaped.body, unownedJob.body] {
            let reply = try object(try callOpen(body).body)
            XCTAssertEqual(reply["ok"] as? Bool, false)
            XCTAssertEqual(reply["code"] as? String, "bindingMalformed")
        }
    }

    /// NULL/empty toolCall keeps the ordinary in-run behavior byte-for-byte
    /// (the candidate-07 foreground exec.shell success path): the mint
    /// carries NO `toolCallID`/`jobID` members and opens through the
    /// active-parent rule, exactly like `floe_linux_workspace_binding`.
    func testEmptyClaimMintsOrdinaryGrantAndOpensUnchanged() async throws {
        let boot = try await bootInstalledGeneration()
        let seeded = try await seedActiveRun()

        let empty = try callBindingForCall(
            epoch: boot.epoch, runID: seeded.runID.uuidString,
            toolCallID: "", grantID: Self.randomGrantID())
        XCTAssertGreaterThan(empty.code, 0)
        let envelope = try object(empty.body)
        XCTAssertEqual(envelope["ok"] as? Bool, true,
                       "empty-claim mint refused: \(envelope["code"] ?? "?")")
        XCTAssertNil(envelope["toolCallID"], "an ordinary grant carries no durable job claim")
        XCTAssertNil(envelope["jobID"])

        let opened = try object(try callOpen(empty.body).body)
        XCTAssertEqual(opened["ok"] as? Bool, true,
                       "ordinary envelope must still open unchanged: \(opened["code"] ?? "?")")
        let sessionKey = try XCTUnwrap(opened["sessionKey"] as? String)
        XCTAssertNotNil(sessionKey.range(of: "^[0-9a-f]{32}$", options: .regularExpression))

        // Single-use stays single-use on the empty-claim route too.
        let replay = try object(try callOpen(empty.body).body)
        XCTAssertEqual(replay["ok"] as? Bool, false)
        XCTAssertEqual(replay["code"] as? String, "grantNotMinted")
        closeSession(sessionKey)
    }

    /// A hand-built job-shape body never reaches the identity fence and
    /// never consumes a mint: the store-resolution fence (run row + live
    /// ORIGINAL job ownership) refuses FIRST, fail closed, with
    /// `bindingUnresolved` — for a foreign run AND for a live seeded run
    /// paired with an unowned job id. The repair therefore widens NOTHING:
    /// real ownership remains the only path to the job branch.
    func testUnmintedJobShapeEnvelopeRefusesAtOwnershipBeforeAnyConsumption() async throws {
        let boot = try await bootInstalledGeneration()
        let seeded = try await seedActiveRun()

        func jobShapedBody(runID: UUID, jobID: UUID) -> [String: Any] {
            [
                "ok": true,
                "version": 1,
                "projectID": UUID().uuidString,
                "runID": runID.uuidString,
                "conversationID": seeded.conversationID.uuidString,
                "workspaceID": seeded.workspaceID.uuidString,
                "rootEpoch": boot.epoch,
                "grantID": Self.randomGrantID(),
                "workspaceFingerprint": String(repeating: "a", count: 12),
                "proof": String(repeating: "0", count: 64),
                "toolCallID": LinuxWorkspaceAuthority.durableJobCallID(rowID: jobID),
                "jobID": jobID.uuidString,
            ]
        }

        let foreignRun = try object(try callOpen(dictionary:
            jobShapedBody(runID: UUID(), jobID: UUID())).body)
        XCTAssertEqual(foreignRun["ok"] as? Bool, false)
        XCTAssertEqual(foreignRun["code"] as? String, "bindingUnresolved",
                       "a foreign run must die at the ORIGINAL store resolution")

        let unownedJob = try object(try callOpen(dictionary:
            jobShapedBody(runID: seeded.runID, jobID: UUID())).body)
        XCTAssertEqual(unownedJob["ok"] as? Bool, false)
        XCTAssertEqual(unownedJob["code"] as? String, "bindingUnresolved",
                       "a job id with no ORIGINAL live ownership must die at the store fence")
    }
}
