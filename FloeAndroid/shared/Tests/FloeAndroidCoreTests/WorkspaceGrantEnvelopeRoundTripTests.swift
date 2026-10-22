// SPDX-License-Identifier: MPL-2.0
//
// G03-R3 workspace grant envelope round-trip — REAL C-ABI + REAL DB suite.
// AUTHORED, NOT RUN in this source lane (Main's grouped compile runs it).
//
// Contract under test (the deterministic R3 ordinary-grant admission defect
// this package repairs):
//  * the mint entries return the binding scope INSIDE the shared reply
//    envelope ({"ok":true, ...scope}); the trusted Kotlin host forwards
//    those EXACT bytes back to floe_linux_workspace_session_open;
//  * session_open separates the envelope BEFORE the strict binding-scope
//    parse — when present, the status member must be an ACTUAL boolean TRUE
//    (false, numeric, string and null markers are a malformed envelope,
//    never a silently accepted success), and a raw scope body without the
//    member stays accepted exactly as before. The pre-repair source passed
//    the still-enveloped dictionary to WorkspaceGrantBinding.from, whose
//    exact-field-set contract refused the envelope's own "ok" member, so
//    EVERY legitimately minted grant died as bindingUnresolved — the pump
//    then recorded the collapsed device stage token workspace_unresolved;
//  * real JSONSerialization scalar typing survives the strict gate: the
//    integer 1 (the binding `version`) and integer 0 parse as integers on
//    EVERY platform — a plain Swift `is Bool` check is NOT the boolean
//    discriminator, because Darwin Foundation answers it true for NSNumber-backed
//    zeros and ones; actual JSON booleans stay refused;
//  * the unchanged authority fences stay closed: single-use mint
//    consumption, foreign scope members, error bodies and foreign epochs
//    all still refuse; the HMAC proof, consumeMint and the
//    store-re-derived identity/root remain the only grant authority.
//    Nothing here fabricates qualification; the run row, ownership row and
//    workspace root are seeded through the ORIGINAL production stores on a
//    file-backed schema-46 database behind a REAL bootstrapped generation.
//
// Lifecycle boundary (Main Run-fixture protocol, same discipline as
// G02CompositionIntegrationTests): each test boots its OWN monotonic
// generation over a synthetic trusted root, retires it through the real
// shutdown control in tearDown and relies on the composition reset chain
// (composition -> authority -> engine resetInstallationForTesting) so the
// engine first-install slot never strands a later synthetic root — suite
// order is therefore irrelevant.
import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif
import FloeCore
import FloeModels
import FloePersistence
import FloeAndroidWorkspaceTools
@testable import FloeAndroidCore

final class WorkspaceGrantEnvelopeRoundTripTests: XCTestCase {

    // MARK: - Fixtures (real bootstrap + real stores)

    private enum TestError: Error { case bootstrap, mintReply, openReply }

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
        // Releases authority + engine together (the pairing added by this
        // package): the next class' or method' synthetic root installs fresh.
        G02RuntimeComposition.shared.resetForTesting()
        AndroidRuntimeBootstrap.resetForTesting()
        try await super.tearDown()
    }

    /// Boots one REAL generation over a synthetic trusted root and returns
    /// only after the accepted bootstrap terminal settled AND the ordinary
    /// graph installed (same proven pattern as G02CompositionIntegrationTests).
    @discardableResult
    private func bootInstalledGeneration(file: StaticString = #filePath, line: UInt = #line)
        async throws -> Boot {
        let root = androidTestFixtureDirectory
            .appendingPathComponent("g03-grant-envelope-\(UUID().uuidString)", isDirectory: true)
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
            // The harness guard for THIS suite: the generation's build binds
            // the authority + engine together; a stranded slot here would
            // fake a bindingUnavailable failure unrelated to the contract.
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

    /// Seeds ONE ordinary conversation + its canonical privateTask ownership
    /// + ONE non-terminal run through the ORIGINAL cluster stores — the same
    /// statement shapes the real C1 activation writes.
    private func seedActiveRun() async throws -> (runID: UUID, conversationID: UUID, workspaceID: UUID) {
        let cluster = try XCTUnwrap(G02RuntimeComposition.shared.installedComposition).cluster
        let conversation = ConversationRecord(id: UUID(), title: "R3 grant envelope",
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
        // The REAL first-use phase: the grant mint runs while the committed
        // launch is still "preparing" (makeService preflight hook).
        try await cluster.runStore.saveRun(RunRecord(id: runID,
                                                     conversationID: conversation.id,
                                                     state: "preparing",
                                                     goal: "roundtrip",
                                                     startedAt: Date()))
        return (runID, conversation.id, workspace.id)
    }

    // MARK: - C-ABI helpers (the SAME public @_cdecl entries JNI invokes)

    private static func randomGrantID() -> String {
        String((0..<32).map { _ in "0123456789abcdef".randomElement()! })
    }

    private func callBinding(epoch: UInt64, runID: String,
                             grantID: String) throws -> (code: Int32, body: Data) {
        var out = [CChar](repeating: 0, count: 65_537)
        let n = runID.withCString { runPtr in
            grantID.withCString { grantPtr in
                out.withUnsafeMutableBufferPointer { buffer in
                    floe_linux_workspace_binding(epoch, runPtr, grantPtr,
                                                 buffer.baseAddress, Int32(buffer.count))
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

    // MARK: - The definitive round trip

    /// A mint over the REAL envelope + REAL serialized bytes opens a REAL
    /// session. Pre-repair, session_open refused its own envelope's "ok"
    /// member as bindingUnresolved (== the device's collapsed
    /// workspace_unresolved stage), so this test fails on the old source
    /// and passes on the repaired source.
    func testMintedEnvelopeOpensSessionEndToEnd() async throws {
        let boot = try await bootInstalledGeneration()
        let seeded = try await seedActiveRun()
        let grantID = Self.randomGrantID()

        let mint = try callBinding(epoch: boot.epoch, runID: seeded.runID.uuidString, grantID: grantID)
        XCTAssertGreaterThan(mint.code, 0)
        let envelope = try object(mint.body)
        XCTAssertEqual(envelope["ok"] as? Bool, true,
                       "mint refused: \(envelope["code"] ?? "?")")
        // Real serialized scalars: the strict parse on the OTHER side of
        // this same envelope must see the integer version/epoch unchanged.
        XCTAssertEqual(envelope["version"] as? Int, 1)
        XCTAssertEqual(envelope["runID"] as? String, seeded.runID.uuidString)
        XCTAssertEqual(envelope["grantID"] as? String, grantID)
        XCTAssertNotNil((envelope["proof"] as? String)?.range(
            of: "^[0-9a-f]{64}$", options: .regularExpression))

        // THE round trip of the EXACT envelope bytes (never dictionaryValue).
        let opened = try callOpen(mint.body)
        XCTAssertGreaterThan(opened.code, 0)
        let reply = try object(opened.body)
        XCTAssertEqual(reply["ok"] as? Bool, true,
                       "session_open refused its own mint envelope: \(reply["code"] ?? "?")")
        let sessionKey = try XCTUnwrap(reply["sessionKey"] as? String)
        XCTAssertNotNil(sessionKey.range(of: "^[0-9a-f]{32}$", options: .regularExpression))

        // Not an echo: the ORIGINAL engine table holds the live binding with
        // the store-re-derived identities and the materialized canonical root.
        let live = try XCTUnwrap(WorkspaceTransferEngine.shared.binding(forSessionKey: sessionKey))
        XCTAssertEqual(live.runID, seeded.runID)
        XCTAssertEqual(live.conversationID, seeded.conversationID)
        XCTAssertEqual(live.workspaceID, seeded.workspaceID)
        XCTAssertEqual(live.rootEpoch, boot.epoch)
        XCTAssertTrue(live.workspaceRootPath
            .hasSuffix("/Workspace/PrivateTasks/\(seeded.conversationID.uuidString)"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.workspaceRootPath))
        closeSession(sessionKey)
    }

    /// The unchanged fences stay closed AFTER separation: a foreign scope
    /// member still fails the exact field set, and a mint opens AT MOST one
    /// session (single-use consumption).
    func testForeignScopeMemberRefusedAndMintIsSingleUse() async throws {
        let boot = try await bootInstalledGeneration()
        let seeded = try await seedActiveRun()
        let grantID = Self.randomGrantID()
        let mint = try callBinding(epoch: boot.epoch, runID: seeded.runID.uuidString, grantID: grantID)
        let envelope = try object(mint.body)
        XCTAssertEqual(envelope["ok"] as? Bool, true,
                       "mint refused: \(envelope["code"] ?? "?")")

        var foreign = envelope
        foreign["extra"] = 1
        let tampered = try callOpen(dictionary: foreign)
        let tamperedReply = try object(tampered.body)
        XCTAssertEqual(tamperedReply["ok"] as? Bool, false)
        XCTAssertEqual(tamperedReply["code"] as? String, "bindingUnresolved",
                       "a foreign scope member must still be refused by the exact field set")

        let first = try callOpen(mint.body)
        let firstReply = try object(first.body)
        XCTAssertEqual(firstReply["ok"] as? Bool, true,
                       "session_open refused its own mint envelope: \(firstReply["code"] ?? "?")")
        let replay = try callOpen(mint.body)
        let replayReply = try object(replay.body)
        XCTAssertEqual(replayReply["ok"] as? Bool, false)
        XCTAssertEqual(replayReply["code"] as? String, "grantNotMinted",
                       "a consumed mint must never reopen a session")
        if let key = firstReply["sessionKey"] as? String { closeSession(key) }
    }

    /// Status-shape fences BEFORE separation: false / numeric / null markers
    /// are a malformed envelope, never a silently accepted success; a raw
    /// binding-scope body (the pre-envelope form the entry already accepted)
    /// stays supported; the mint entries keep refusing foreign generations.
    func testEnvelopeStatusShapeAndEpochFencesStayClosed() async throws {
        let boot = try await bootInstalledGeneration()
        let seeded = try await seedActiveRun()
        let grantID = Self.randomGrantID()
        let mint = try callBinding(epoch: boot.epoch, runID: seeded.runID.uuidString, grantID: grantID)
        let envelope = try object(mint.body)
        XCTAssertEqual(envelope["ok"] as? Bool, true,
                       "mint refused: \(envelope["code"] ?? "?")")

        for marker: Any in [false, 1, "true", NSNull()] {
            var tampered = envelope
            tampered["ok"] = marker
            let reply = try object(try callOpen(dictionary: tampered).body)
            XCTAssertEqual(reply["ok"] as? Bool, false,
                           "status marker \(marker) must never be accepted as success")
            XCTAssertEqual(reply["code"] as? String, "bindingMalformed")
        }
        // The error-body shape is likewise refused (it carries no scope at all).
        let errorBody = try object(try callOpen(dictionary: ["ok": false, "code": "bindingUnavailable"]).body)
        XCTAssertEqual(errorBody["ok"] as? Bool, false)
        XCTAssertEqual(errorBody["code"] as? String, "bindingMalformed")

        // A foreign epoch never mints (unchanged fence, still closed after
        // this package: the accepted generation owns the grant).
        let foreign = try callBinding(epoch: boot.epoch &+ 1, runID: seeded.runID.uuidString,
                                      grantID: Self.randomGrantID())
        let foreignReply = try object(foreign.body)
        XCTAssertEqual(foreignReply["code"] as? String, "epochNotCurrent")

        // Raw scope WITHOUT the status member stays supported — and the
        // still-unconsumed mint above settles through it (the refused
        // markers never consumed it).
        var raw = envelope
        raw.removeValue(forKey: "ok")
        let opened = try object(try callOpen(dictionary: raw).body)
        XCTAssertEqual(opened["ok"] as? Bool, true,
                       "raw-scope support must not regress: \(opened["code"] ?? "?")")
        if let key = opened["sessionKey"] as? String { closeSession(key) }
    }

    // MARK: - Real JSONSerialization scalar typing (no boot required)

    /// The strict scalar gate classifies booleans EXACTLY: real JSON true/
    /// false refuse, while integers — including 0 and 1 — pass on REAL
    /// serialized round trips. Darwin Foundation answers the plain Swift
    /// Bool check for NSNumber-backed zeros and ones, so the old blanket `value is Bool`
    /// rejection refused the legitimate integer `1`; the CF-type based
    /// transport classification is the discriminator on every toolchain.
    func testRealSerializedScalarsKeepExactBooleanTyping() async throws {
        let source: [String: Any] = ["version": 1, "zero": 0, "big": 46, "t": true, "f": false]
        let data = try JSONSerialization.data(withJSONObject: source, options: [.sortedKeys])
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(WorkspaceStrict.integer(parsed["version"], min: 1, max: 1), 1,
                       "the binding version integer was refused as a boolean")
        XCTAssertEqual(WorkspaceStrict.integer(parsed["zero"], min: 0, max: 8_300_000_000), 0,
                       "integer 0 was refused as a boolean")
        XCTAssertEqual(WorkspaceStrict.integer(parsed["big"], min: 1, max: 100), 46)
        XCTAssertNil(WorkspaceStrict.integer(parsed["t"], min: 0, max: 1),
                     "a real JSON boolean must NEVER pass as an integer")
        XCTAssertNil(WorkspaceStrict.integer(parsed["f"], min: 0, max: 1),
                     "a real JSON boolean must NEVER pass as an integer")
        XCTAssertEqual(WorkspaceStrict.boolean(parsed["t"]), true)
        XCTAssertEqual(WorkspaceStrict.boolean(parsed["f"]), false)
        XCTAssertNil(WorkspaceStrict.boolean(parsed["version"]),
                     "integer 1 is not a boolean marker")
        XCTAssertNil(WorkspaceStrict.boolean(parsed["zero"]),
                     "integer 0 is not a boolean marker")
        // Non-scalars refuse as both.
        XCTAssertNil(WorkspaceStrict.boolean("true"))
        XCTAssertNil(WorkspaceStrict.boolean(nil))
        // Native Swift values (hand-built dictionaries, e.g. tests and
        // in-process callers) classify identically to serialized bytes.
        XCTAssertEqual(WorkspaceStrict.integer(1, min: 1, max: 1), 1)
        XCTAssertNil(WorkspaceStrict.integer(true, min: 0, max: 1))
        XCTAssertNil(WorkspaceStrict.integer(NSNumber(value: true), min: 0, max: 1))
        XCTAssertEqual(WorkspaceStrict.boolean(true), true)
    }

    /// The binding-scope contract itself is UNCHANGED: the exact-field-set
    /// parser keeps refusing envelope/foreign members. Envelope separation
    /// happens at the entry (the only site that receives mint bytes), so no
    /// "ok" member was ever added to the scope vocabulary.
    func testScopeParserKeepsItsExactFieldSetContract() throws {
        let binding = WorkspaceGrantBinding(
            projectID: UUID(), runID: UUID(), conversationID: UUID(), workspaceID: UUID(),
            rootEpoch: 7, grantID: Self.randomGrantID(),
            workspaceRootPath: "/synthetic/root",
            workspaceFingerprint: String(repeating: "a", count: 12),
            proof: String(repeating: "0", count: 64),
            budgets: .defaults)
        // Bare scope parses (both hand-built and REAL serialized round trips).
        XCTAssertNotNil(WorkspaceGrantBinding.from(dictionary: binding.dictionaryValue,
                                                   workspaceRootPath: "/synthetic/root"))
        let data = try JSONSerialization.data(withJSONObject: binding.dictionaryValue,
                                              options: [.sortedKeys])
        let roundTrip = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(WorkspaceGrantBinding.from(dictionary: roundTrip,
                                                   workspaceRootPath: "/synthetic/root"))
        // The response envelope member is NOT scope: the parser must keep
        // refusing it (this is exactly what session_open now separates
        // before invoking this contract).
        var enveloped = binding.dictionaryValue
        enveloped["ok"] = true
        XCTAssertNil(WorkspaceGrantBinding.from(dictionary: enveloped,
                                                workspaceRootPath: "/synthetic/root"))
        var foreign = binding.dictionaryValue
        foreign["extra"] = "member"
        XCTAssertNil(WorkspaceGrantBinding.from(dictionary: foreign,
                                                workspaceRootPath: "/synthetic/root"))
    }
}
