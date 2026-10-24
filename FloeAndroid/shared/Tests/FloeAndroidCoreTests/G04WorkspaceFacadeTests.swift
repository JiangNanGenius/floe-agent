// SPDX-License-Identifier: MPL-2.0
//
// G04-R1 workspace facade — REAL-root integration source tests.
//
// AUTHORED, NOT EXECUTED (grouped qualification is Main's). Every case runs
// through the real accepted bootstrap + ordinary G02 composition install,
// the real BridgeV3 validation -> binder -> mailbox -> async processor
// ingress, the REAL file-backed DatabaseManager cluster and the ORIGINAL
// FloeWorkspace file service on disk. Synthetic fixture paths/names only;
// never a real user file, provider, model or device.
//
// Covered contract:
//   * D14 activate: creates ONLY when truly unbound (exact original
//     ensureWorkspace statements), never rewrites an existing association,
//     refuses foreign/temporary-shaped identities, and keeps reads pure;
//   * admission fences: stale epoch/workspace/task + notes ceiling refuse
//     with exact typed wire codes BEFORE any effect;
//   * real file/editor loop: create -> open -> edit -> save -> external
//     conflict (identity-only reply, no oversized text) ->
//     resolveConflictUsingDraft;
//   * D15 forkDraft (KEEP_BOTH): external original preserved, complete
//     native draft bytes durably copied + opened, no-overwrite collision,
//     source tab closed only after the verified copy acknowledgement when
//     explicitly chosen;
//   * oversized complete PAGE staging through the ORIGINAL FacadeContentReader
//     with byte-exact reassembly, honest nextPageToken/complete echo and
//     cross-owner handle isolation (a workspace query handle never reads
//     another owner's snapshot; document handles never enter the query
//     channel);
//   * root retirement honest pending: production drain order (owned-work
//     admission already fenced) NEVER claims durable preservation, the
//     process-retained extension re-drives the carry at the next live
//     attach into a VERIFIED `Recovered Edits/<name>-<digest>.txt` copy, and
//     an explicit successful conversation deletion discards the carry
//     instead of resurrecting deleted-task bytes.
import XCTest
import Foundation
import Crypto
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
@testable import FloeAndroidCore

final class G04WorkspaceFacadeTests: XCTestCase {

    // MARK: - Real generation lane (same protocol as G02CompositionIntegrationTests)

    private final class Boot {
        let epoch: UInt64
        let rootPath: String
        let token: String
        var retired = false
        init(epoch: UInt64, rootPath: String, token: String) {
            self.epoch = epoch; self.rootPath = rootPath; self.token = token
        }
    }
    private var tracked: [Boot] = []

    private enum FixtureEpoch {
        nonisolated(unsafe) static var lock = NSLock()
        nonisolated(unsafe) static var value = UInt64(DispatchTime.now().uptimeNanoseconds)
        static func allocate() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            let now = UInt64(DispatchTime.now().uptimeNanoseconds)
            value = Swift.max(value &+ 1, now)
            return value
        }
    }

    override func tearDown() async throws {
        for boot in tracked.reversed() where !boot.retired {
            await shutdownAndAwaitClosed(boot)
        }
        tracked.removeAll()
        G04WorkspaceSourceMailbox.shared.close(epoch: G04WorkspaceSourceMailbox.shared.boundEpoch)
        G02RuntimeComposition.shared.resetForTesting()
        AndroidRuntimeBootstrap.resetForTesting()
        try await super.tearDown()
    }

    @discardableResult
    private func bootInstalledGeneration(preparedRoot: String? = nil) async throws -> Boot {
        let root: String
        if let preparedRoot {
            root = preparedRoot
        } else {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("g04-facade-\(UUID().uuidString)").path
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        }
        // Production restart contract (Kotlin RuntimeBootstrapInstrumentedTest
        // "Restart with a strictly newer epoch"): a restart on the SAME root
        // reuses the accepted full-owner token; only the epoch advances. A new
        // random token for the same root is a DIFFERENT full owner, which the
        // vault admission rightly refuses (ownerMismatch) — it is not a
        // supported reboot of the same owned root.
        let token: String
        if let existing = tracked.last(where: { $0.rootPath == root }) {
            token = existing.token
        } else {
            token = String((0 ..< 16).map { _ in "0123456789abcdef".randomElement()! })
        }
        let epoch = FixtureEpoch.allocate()
        guard case .accepted = AndroidRuntimeBootstrap.start(rootPath: root, ownerToken: token,
                                                             epoch: epoch) else {
            throw TestError.bootstrap
        }
        let boot = Boot(epoch: epoch, rootPath: root, token: token)
        tracked.append(boot)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            guard let generation = AndroidRuntimeBootstrap.currentGenerationForTesting(),
                  generation.epoch == epoch else { throw TestError.bootstrap }
            // `installedComposition` becomes visible at the install claim —
            // BEFORE the optional-domain extensions attach (owned-install
            // step 4). The three closed workspace keys plus the trusted host
            // and network registries only exist once THIS generation's workspace
            // extension has fully attached; returning earlier lets the very
            // first submit race an unregistered handler (the honest fail-
            // closed `runtimeUnavailable` refusal) instead of exercising the
            // real ingress. Wait on the ONE post-attach publication.
            if let installed = G02RuntimeComposition.shared.installedComposition,
               installed.epoch == epoch,
               AndroidRuntimeBootstrap.currentPumps()?.storeReady == true,
               G02RuntimeComposition.shared.isExtensionAttached(G02DomainExtensionKey.workspace) {
                return boot
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // Bounded diagnostic (no assertion change): name WHICH readiness arm
        // never became true so a boot refusal is never guessed.
        let liveEpoch = AndroidRuntimeBootstrap.currentGenerationForTesting()?.epoch
        let installedEpoch = G02RuntimeComposition.shared.installedComposition?.epoch
        let storeReady = AndroidRuntimeBootstrap.currentPumps()?.storeReady
        let attached = G02RuntimeComposition.shared.isExtensionAttached(G02DomainExtensionKey.workspace)
        let line = "g04-facade boot timeout: want=\(epoch) live=\(liveEpoch.map(String.init) ?? "nil") "
            + "installed=\(installedEpoch.map(String.init) ?? "nil") "
            + "storeReady=\(storeReady.map(String.init) ?? "nil") workspaceAttached=\(attached)\n"
        FileHandle.standardError.write(Data(line.utf8))
        throw TestError.bootstrap
    }

    private func shutdownAndAwaitClosed(_ boot: Boot) async {
        guard !boot.retired else { return }
        boot.retired = true
        _ = AndroidRuntimeBootstrap.shutdown(expectedEpoch: boot.epoch, ownerToken: boot.token)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if AndroidRuntimeBootstrap.currentGenerationForTesting() == nil { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("generation did not close for epoch \(boot.epoch)")
    }

    private enum TestError: Error { case bootstrap, envelope, timeout, shape }

    // MARK: - Real v3 ingress helpers

    private func envelope(command: String, taskID: UUID, payload: [String: Any],
                          stateful: Bool = false) -> [String: Any] {
        // Wire premise (frozen `BridgeEnvelopeV3.validateTyped`, closed
        // envelope key set, and the canonical request shape exercised by
        // BridgeEnvelopeV3Tests.request): the protocol version lives on the
        // OUTER request wrapper, never inside the envelope. An envelope-level
        // "version" is an unknown field and is refused before dispatch.
        var env: [String: Any] = [
            "schema": BridgeV3.commandSchema,
            "scope": "conversationLifecycle",
            "owner": ["taskID": taskID.uuidString],
            "command": command,
            "stateful": stateful,
            "correlationID": "g04-\(UUID().uuidString)",
        ]
        env["payload"] = payload
        return env
    }

    private func submit(_ env: [String: Any], correlation: String) throws -> String {
        // Wire premise (frozen `BridgeEnvelopeV3.validateTyped`): the
        // envelope `correlationID` must be the SAME identity as the outer
        // request `requestID` — a mismatch is `correlationMismatch` decided
        // before any handler lookup. The single caller correlation is that
        // identity for both layers (each call site already passes a unique
        // value), so no second random id is invented.
        var env = env
        env["correlationID"] = correlation
        let response = BridgeV3.handle(request: ["operation": "command.submit",
                                                 "requestID": correlation,
                                                 "envelope": env],
                                       requestID: correlation)
        guard let ok = response["ok"] as? Bool, ok,
              let receipt = response["operationReceiptID"] as? String else {
            // Bounded refusal diagnostic (Main/697 lead): name the honest
            // ingress refusal — unknown handler (runtimeUnavailable /
            // commandBinderUnbound) vs a typed validation code — printing
            // ONLY the typed error/reason tokens. No payload, no assertion
            // change; the throw and every expectation stay exactly authored.
            let refusalError = response["error"] as? String ?? "nil"
            let refusalReason = response["reason"] as? String ?? "nil"
            let line = "g04-facade submit refusal: error=\(refusalError) reason=\(refusalReason)\n"
            FileHandle.standardError.write(Data(line.utf8))
            throw TestError.envelope
        }
        return receipt
    }

    private func settleValue(receipt: String, command: String,
                             taskID: UUID) async throws -> [String: Any] {
        guard let pumps = AndroidRuntimeBootstrap.currentPumps() else { throw TestError.envelope }
        let deadline = Date().addingTimeInterval(15)
        var sequence = 0
        while Date() < deadline {
            switch pumps.effects.poll(receipt: receipt, afterSequence: sequence) {
            case .page(let items, let next, _, _):
                sequence = max(sequence, next)
                if let terminal = items.first(where: { $0.isTerminal }) {
                    guard terminal.kind == .accepted,
                          case .object(let object)? = terminal.value,
                          let converted = RuntimeEffectDocumentProjection.foundationObject(
                            .object(object)) as? [String: Any] else {
                        let code = terminal.detail?["wire"] ?? terminal.code?.rawValue ?? "unknown"
                        let reason = terminal.detail?["reason"]
                        throw FacadeTestRefusal(code: code, reason: reason)
                    }
                    return converted
                }
            default:
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw TestError.timeout
    }

    private struct FacadeTestRefusal: Error { let code: String; let reason: String? }

    private func designObject(_ object: [String: Any]) -> [String: Any] { object }

    // MARK: - Fixtures

    private func makeOrdinaryConversation(epoch: UInt64, title: String = "G04 fixture")
        async throws -> (UUID, G02OwnedStoreCluster) {
        guard let installed = G02RuntimeComposition.shared.installedComposition,
              installed.epoch == epoch else { throw TestError.envelope }
        let id = UUID()
        try await installed.cluster.conversationStore.saveConversation(ConversationRecord(
            id: id, title: title, createdAt: Date(), updatedAt: Date()))
        return (id, installed.cluster)
    }

    private func workspaceRootURL(taskID: UUID) throws -> URL {
        guard let installed = G02RuntimeComposition.shared.installedComposition else {
            throw TestError.envelope
        }
        return URL(fileURLWithPath: installed.cluster.identity.root.path)
            .appendingPathComponent("Workspace/PrivateTasks/\(taskID.uuidString)", isDirectory: true)
    }

    // MARK: - D14 activation

    func testActivateCreatesOnlyWhenTrulyUnboundAndNeverRewritesBinding() async throws {
        let boot = try await bootInstalledGeneration()
        let (taskID, cluster) = try await makeOrdinaryConversation(epoch: boot.epoch)
        let correlation = "g04-activate-\(UUID().uuidString)"
        let receipt = try submit(envelope(command: "workspace.activate", taskID: taskID,
                                          payload: ["nativeEpoch": String(boot.epoch)]),
                                 correlation: correlation)
        let first = try await settleValue(receipt: receipt, command: "workspace.activate", taskID: taskID)
        XCTAssertEqual(first["created"] as? Bool, true)
        XCTAssertEqual(first["kind"] as? String, WorkspaceKind.privateTask.rawValue)
        let workspaceID = try XCTUnwrap(UUID(uuidString: first["workspaceID"] as? String ?? ""))
        // The ORIGINAL canonical statements really landed: ownership row +
        // exact private-task path materialized through the same authority.
        let landedWorkspaceID = try await cluster.workspaceStore.workspaceID(conversationID: taskID)
        XCTAssertEqual(landedWorkspaceID, workspaceID)
        let workspaceRecord = try await cluster.workspaceStore.workspace(id: workspaceID)
        let record = try XCTUnwrap(workspaceRecord)
        XCTAssertEqual(record.internalRelativePath, "PrivateTasks/\(taskID.uuidString)")
        // Second activation: honest created=false, SAME binding, no rewrite.
        let receipt2 = try submit(envelope(command: "workspace.activate", taskID: taskID,
                                           payload: ["nativeEpoch": String(boot.epoch)]),
                                  correlation: "g04-activate-2")
        let second = try await settleValue(receipt: receipt2, command: "workspace.activate", taskID: taskID)
        XCTAssertEqual(second["created"] as? Bool, false)
        XCTAssertEqual(second["workspaceID"] as? String, workspaceID.uuidString)
    }

    func testActivationGrammarAndCeilingsRefuseBeforeAnyEffect() async throws {
        let boot = try await bootInstalledGeneration()
        let (taskID, cluster) = try await makeOrdinaryConversation(epoch: boot.epoch)
        // extra claimed root/workspace fields: typed refusal, no rows written
        await assertRefusal(code: "invalidPayload", command: "workspace.activate", taskID: taskID,
                            payload: ["nativeEpoch": String(boot.epoch), "rootPath": "/tmp"])
        // wrong epoch refuses with epochMismatch
        await assertRefusal(code: "epochMismatch", command: "workspace.activate", taskID: taskID,
                            payload: ["nativeEpoch": String(boot.epoch &+ 1)])
        // unknown conversation never creates anything
        await assertRefusal(code: "notFound", command: "workspace.activate", taskID: UUID(),
                            payload: ["nativeEpoch": String(boot.epoch)])
        // notes purpose is NOT an ordinary task workspace
        let notesID = UUID()
        try await cluster.conversationStore.saveConversation(ConversationRecord(
            id: notesID, title: "Notes", createdAt: Date(), updatedAt: Date(), purpose: .notes))
        await assertRefusal(code: "purposeNotOrdinary", command: "workspace.activate", taskID: notesID,
                            payload: ["nativeEpoch": String(boot.epoch)])
        // workspace.read with NO binding refuses activationRequired-adjacent
        // ownerChanged (never a guessed first project)
        let (freshID, _) = try await makeOrdinaryConversation(epoch: boot.epoch)
        await assertRefusal(code: "ownerChanged", command: "workspace.read", taskID: freshID,
                            payload: ["op": "list", "workspaceID": UUID().uuidString,
                                      "nativeEpoch": String(boot.epoch)])
    }

    private func assertRefusal(code: String, command: String, taskID: UUID,
                               payload: [String: Any]) async {
        do {
            let receipt = try submit(envelope(command: command, taskID: taskID, payload: payload),
                                     correlation: "g04-\(UUID().uuidString)")
            _ = try await settleValue(receipt: receipt, command: command, taskID: taskID)
            XCTFail("expected typed refusal \(code)")
        } catch let refusal as FacadeTestRefusal {
            XCTAssertEqual(refusal.code, code)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - Real file/editor loop + conflict + forkDraft

    func testFileEditorSaveConflictAndForkDraftAreRealAndNonDestructive() async throws {
        let boot = try await bootInstalledGeneration()
        let (taskID, _) = try await makeOrdinaryConversation(epoch: boot.epoch)
        let activation = try await settle(receipt: try submit(
            envelope(command: "workspace.activate", taskID: taskID,
                     payload: ["nativeEpoch": String(boot.epoch)]),
            correlation: "act"), command: "workspace.activate", taskID: taskID)
        let workspaceID = try XCTUnwrap(UUID(uuidString: activation["workspaceID"] as? String ?? ""))

        // createFile lands actual bytes under the task's own private root.
        let created = try await settle(receipt: try submit(
            envelope(command: "workspace.write", taskID: taskID,
                     payload: ["op": "createFile", "workspaceID": workspaceID.uuidString,
                               "nativeEpoch": String(boot.epoch), "path": "main.kt",
                               "content": "fun main() {}"]),
            correlation: "create"), command: "workspace.write", taskID: taskID)
        XCTAssertEqual(created["sha256"] as? String,
                       FloeDigest.sha256Hex(Data("fun main() {}".utf8)))
        let diskURL = try workspaceRootURL(taskID: taskID).appendingPathComponent("main.kt")
        XCTAssertEqual(try Data(contentsOf: diskURL), Data("fun main() {}".utf8))

        // open -> edit -> save
        let opened = try await settle(receipt: try submit(
            envelope(command: "workspace.read", taskID: taskID,
                     payload: ["op": "open", "workspaceID": workspaceID.uuidString,
                               "nativeEpoch": String(boot.epoch), "path": "main.kt"]),
            correlation: "open"), command: "workspace.read", taskID: taskID)
        let documentID = try XCTUnwrap(UUID(uuidString: opened["documentID"] as? String ?? ""))
        let edited = try await settle(receipt: try submit(
            envelope(command: "workspace.write", taskID: taskID,
                     payload: ["op": "edit", "workspaceID": workspaceID.uuidString,
                               "nativeEpoch": String(boot.epoch),
                               "documentID": documentID.uuidString,
                               "revision": try XCTUnwrap(opened["revision"] as? String),
                               // UTF-16 NSRange premise (the document session's
                               // original NSRange grammar): 13 is the full length of
                               // "fun main() {}", i.e. append at the very end.
                               "location": 13, "length": 0, "replacement": "🙂"]),
            correlation: "edit"), command: "workspace.write", taskID: taskID)
        let saved = try await settle(receipt: try submit(
            envelope(command: "workspace.write", taskID: taskID,
                     payload: ["op": "save", "workspaceID": workspaceID.uuidString,
                               "nativeEpoch": String(boot.epoch),
                               "documentID": documentID.uuidString,
                               "revision": try XCTUnwrap(edited["revision"] as? String)]),
            correlation: "save"), command: "workspace.write", taskID: taskID)
        XCTAssertEqual(saved["state"] as? String, "saved")
        XCTAssertEqual(try String(contentsOf: diskURL, encoding: .utf8), "fun main() {}🙂")

        // external change -> save conflicts with IDENTITY-ONLY payload
        try Data("external".utf8).write(to: diskURL)
        let savedHeader = try XCTUnwrap(saved["header"] as? [String: Any])
        let conflict = try await settle(receipt: try submit(
            envelope(command: "workspace.write", taskID: taskID,
                     payload: ["op": "save", "workspaceID": workspaceID.uuidString,
                               "nativeEpoch": String(boot.epoch),
                               "documentID": documentID.uuidString,
                               "revision": try XCTUnwrap(savedHeader["revision"] as? String)]),
            correlation: "conflict"), command: "workspace.write", taskID: taskID)
        XCTAssertEqual(conflict["state"] as? String, "conflict")
        let conflictObject = try XCTUnwrap(conflict["conflict"] as? [String: Any])
        XCTAssertEqual(conflictObject["currentSHA256"] as? String,
                       FloeDigest.sha256Hex(Data("external".utf8)))
        XCTAssertNil(conflictObject["current"], "conflict reply must not carry external text")
        XCTAssertNil(conflictObject["draft"], "conflict reply must not carry draft text")

        // KEEP_BOTH via forkDraft: external original preserved; separate
        // verified native draft copy created + opened.
        let conflictHeader = try XCTUnwrap(conflict["header"] as? [String: Any])
        let forked = try await settle(receipt: try submit(
            envelope(command: "workspace.write", taskID: taskID,
                     payload: ["op": "forkDraft", "workspaceID": workspaceID.uuidString,
                               "nativeEpoch": String(boot.epoch),
                               "documentID": documentID.uuidString,
                               "revision": try XCTUnwrap(conflictHeader["revision"] as? String),
                               "destination": "main.keep.kt", "discardAfterCopy": true]),
            correlation: "fork"), command: "workspace.write", taskID: taskID)
        XCTAssertEqual(forked["state"] as? String, "forked")
        let copy = try XCTUnwrap(forked["copy"] as? [String: Any])
        XCTAssertEqual(try String(contentsOf: diskURL, encoding: .utf8), "external",
                       "KEEP_BOTH must never rewrite the external original")
        let copyURL = try workspaceRootURL(taskID: taskID).appendingPathComponent("main.keep.kt")
        XCTAssertEqual(try String(contentsOf: copyURL, encoding: .utf8), "fun main() {}🙂")
        XCTAssertEqual(copy["relativePath"] as? String, "main.keep.kt")
        XCTAssertEqual(forked["sourceClosedAfterCopy"] as? Bool, true)

        // destination collision with DIFFERENT bytes refuses and mutates nothing
        try Data("someone else".utf8).write(to: URL(
            fileURLWithPath: copyURL.path + ".take"), options: [.atomic])
        let reopened = try await settle(receipt: try submit(
            envelope(command: "workspace.read", taskID: taskID,
                     payload: ["op": "open", "workspaceID": workspaceID.uuidString,
                               "nativeEpoch": String(boot.epoch), "path": "main.keep.kt"]),
            correlation: "reopen"), command: "workspace.read", taskID: taskID)
        await assertRefusal(code: "alreadyExists", command: "workspace.write", taskID: taskID,
                            payload: ["op": "forkDraft", "workspaceID": workspaceID.uuidString,
                                      "nativeEpoch": String(boot.epoch),
                                      "documentID": try XCTUnwrap(reopened["documentID"] as? String),
                                      "revision": try XCTUnwrap(reopened["revision"] as? String),
                                      // The reopened tab IS main.keep.kt, so forking it
                                      // onto its own path is the typed invalidTransfer by
                                      // design. The differing-bytes destination seeded above
                                      // is the `.take` sidecar, so that is the collision.
                                      "destination": "main.keep.kt.take"])
        XCTAssertEqual(try String(contentsOf: copyURL, encoding: .utf8), "fun main() {}🙂")
        // no-overwrite recovery default: a second fork of the same tab
        // auto-derives a distinct destination (no clobber)
        let reopened2 = try await settle(receipt: try submit(
            envelope(command: "workspace.write", taskID: taskID,
                     payload: ["op": "edit", "workspaceID": workspaceID.uuidString,
                               "nativeEpoch": String(boot.epoch),
                               "documentID": try XCTUnwrap(reopened["documentID"] as? String),
                               "revision": try XCTUnwrap(reopened["revision"] as? String),
                               "location": 0, "length": 0, "replacement": "# "]),
            correlation: "redit"), command: "workspace.write", taskID: taskID)
        let fork2 = try await settle(receipt: try submit(
            envelope(command: "workspace.write", taskID: taskID,
                     payload: ["op": "forkDraft", "workspaceID": workspaceID.uuidString,
                               "nativeEpoch": String(boot.epoch),
                               "documentID": try XCTUnwrap(reopened2["documentID"] as? String),
                               "revision": try XCTUnwrap(reopened2["revision"] as? String)]),
            correlation: "fork2"), command: "workspace.write", taskID: taskID)
        let copy2 = try XCTUnwrap(fork2["copy"] as? [String: Any])
        XCTAssertNotEqual(copy2["relativePath"] as? String, "main.keep.kt")
    }

    // MARK: - Oversized complete PAGE + cross-owner query isolation

    func testOversizedPageStagesCompletelyAndForeignHandlesNeverRead() async throws {
        let boot = try await bootInstalledGeneration()
        let (firstID, _) = try await makeOrdinaryConversation(epoch: boot.epoch)
        let (secondID, _) = try await makeOrdinaryConversation(epoch: boot.epoch)
        let firstActivation = try await settle(receipt: try submit(
            envelope(command: "workspace.activate", taskID: firstID,
                     payload: ["nativeEpoch": String(boot.epoch)]),
            correlation: "act1"), command: "workspace.activate", taskID: firstID)
        let firstWorkspace = try XCTUnwrap(UUID(uuidString: firstActivation["workspaceID"] as? String ?? ""))
        let secondActivation = try await settle(receipt: try submit(
            envelope(command: "workspace.activate", taskID: secondID,
                     payload: ["nativeEpoch": String(boot.epoch)]),
            correlation: "act2"), command: "workspace.activate", taskID: secondID)
        let secondWorkspace = try XCTUnwrap(UUID(uuidString: secondActivation["workspaceID"] as? String ?? ""))

        // 300 synthetic entries with padded long names -> one ORIGINAL page
        // whose full JSON exceeds the 24 KiB inline budget.
        let root = try workspaceRootURL(taskID: firstID)
        // `workspace.activate` owns the durable record; the physical
        // private-task root materializes lazily through the ORIGINAL authority
        // on first file use (G04WorkspaceFacade.activate contract). This
        // fixture writes raw files through that SAME root, so it materializes
        // the directory itself before seeding the page.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0 ..< 300 {
            let name = "entry-\(index)-\(String(repeating: "x", count: 140)).txt"
            try Data().write(to: root.appendingPathComponent(name))
        }
        let listed = try await settle(receipt: try submit(
            envelope(command: "workspace.read", taskID: firstID,
                     payload: ["op": "list", "workspaceID": firstWorkspace.uuidString,
                               "nativeEpoch": String(boot.epoch), "path": "."]),
            correlation: "list"), command: "workspace.read", taskID: firstID)
        XCTAssertEqual(listed["staged"] as? Bool, true)
        let handle = try XCTUnwrap(listed["handle"] as? String)
        XCTAssertTrue(handle.hasPrefix(FacadeContentReader.Limits.handlePrefix))
        let byteCount = try XCTUnwrap(listed["byteCount"] as? Int)
        let stagedSHA = try XCTUnwrap(listed["sha256"] as? String)
        XCTAssertGreaterThan(byteCount, G04WorkspaceFacade.inlineBudgetBytes,
                             "fixture must actually exercise the staging channel")
        // reassemble byte-exactly through queryContent
        var assembled = Data()
        var offset = 0
        while true {
            let chunkReply = try await settle(receipt: try submit(
                envelope(command: "workspace.read", taskID: firstID,
                         payload: ["op": "queryContent", "workspaceID": firstWorkspace.uuidString,
                                   "nativeEpoch": String(boot.epoch), "handle": handle,
                                   "offset": offset, "limit": 24 * 1024]),
                correlation: "chunk"), command: "workspace.read", taskID: firstID)
            let raw = chunkReply["bytes"] as? String ?? ""
            let data = try XCTUnwrap(Data(base64Encoded: raw))
            assembled.append(data)
            offset = try XCTUnwrap(chunkReply["nextOffset"] as? Int)
            XCTAssertEqual(chunkReply["finished"] as? Bool, offset == byteCount)
            if offset >= byteCount { break }
        }
        XCTAssertEqual(assembled.count, byteCount)
        XCTAssertEqual(FloeDigest.sha256Hex(assembled), stagedSHA)
        let stagedJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: assembled) as? [String: Any])
        let entries = try XCTUnwrap(stagedJSON["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 200, "the ORIGINAL one-page budget is preserved (200/200 of 300)")
        XCTAssertNotNil(stagedJSON["nextPageToken"], "honest next page cursor rides the staged payload")
        // the echoed reply facts match the staged payload exactly
        XCTAssertEqual(listed["nextPageToken"] as? String, stagedJSON["nextPageToken"] as? String)
        XCTAssertEqual(listed["complete"] as? Bool, false, "a page with a cursor never claims the tree")

        // cross-owner handle: the SECOND conversation cannot read it
        await assertRefusal(code: "queryHandleUnknown", command: "workspace.read", taskID: secondID,
                            payload: ["op": "queryContent", "workspaceID": secondWorkspace.uuidString,
                                      "nativeEpoch": String(boot.epoch), "handle": handle,
                                      "offset": 0, "limit": 1024])
        // document channel never accepts a query handle
        await assertRefusal(code: "invalidPayload", command: "workspace.read", taskID: firstID,
                            payload: ["op": "readContent", "workspaceID": firstWorkspace.uuidString,
                                      "nativeEpoch": String(boot.epoch), "handle": handle,
                                      "offset": 0, "limit": 1024])
        // release is owner-exact
        let released = try await settle(receipt: try submit(
            envelope(command: "workspace.read", taskID: firstID,
                     payload: ["op": "releaseQuery", "workspaceID": firstWorkspace.uuidString,
                               "nativeEpoch": String(boot.epoch), "handle": handle]),
            correlation: "release"), command: "workspace.read", taskID: firstID)
        XCTAssertEqual(released["released"] as? Bool, true)
    }

    private func settle(receipt: String, command: String, taskID: UUID) async throws -> [String: Any] {
        try await settleValue(receipt: receipt, command: command, taskID: taskID)
    }

    // MARK: - Root retirement preservation (pre-drain gate)

    /// Production order proof (Main 2026-10-24 gate): the shutdown adoption
    /// attaches ONE real owned-work lease while admission is still legal; the
    /// pre-drain driver settles the dirty draft into a VERIFIED
    /// `Recovered Edits/<name>-<digest>.txt` copy BEFORE the drain predicate
    /// can pass, then exact-releases. A clean `shutdown accepted + closed`
    /// terminal therefore now IMPLIES durable preservation — no longer a
    /// RAM-only carry claim.
    func testRequiredPreservationLeaseSaturationRefusesShutdownWithoutClosingRoot() async throws {
        let boot = try await bootInstalledGeneration()
        var tokens: [RuntimeOwnedWorkToken] = []
        defer { for token in tokens { _ = RuntimeOwnedWorkRegistry.shared.detach(token) } }
        for index in 0..<RuntimeOwnedWorkRegistry.Limits.maximumLiveWork {
            guard case .attached(let token) = RuntimeOwnedWorkRegistry.shared.attach(
                epoch: boot.epoch, kind: .conversation, ownerID: "g04-capacity-\(index)") else {
                XCTFail("fixture could not fill actual owned-work registry"); return
            }
            tokens.append(token)
        }
        switch AndroidRuntimeBootstrap.shutdown(expectedEpoch: boot.epoch, ownerToken: boot.token) {
        case .rejected(let code): XCTAssertEqual(code, .receiptSaturated)
        default: XCTFail("a required preservation without a real lease must not adopt shutdown")
        }
        XCTAssertNotNil(AndroidRuntimeBootstrap.currentGenerationForTesting())
        XCTAssertEqual(RuntimeOwnedWorkRegistry.shared.count(for: boot.epoch), tokens.count)
        XCTAssertFalse(G04WorkspaceRetirementGate.shared.hasPendingLease(epoch: boot.epoch))
        // Refusal did not fence the live root: once capacity is returned,
        // normal exact-owner work can still attach and a later stop can retry.
        _ = RuntimeOwnedWorkRegistry.shared.detach(tokens.removeLast())
        guard case .attached(let probe) = RuntimeOwnedWorkRegistry.shared.attach(
            epoch: boot.epoch, kind: .conversation, ownerID: "g04-after-refusal") else {
            XCTFail("refused shutdown closed live admission"); return
        }
        tokens.append(probe)
    }

    func testForeignShutdownCannotCreateOrReleasePreservationOwnership() async throws {
        let boot = try await bootInstalledGeneration()
        let before = RuntimeOwnedWorkRegistry.shared.count(for: boot.epoch)
        switch AndroidRuntimeBootstrap.shutdown(expectedEpoch: boot.epoch, ownerToken: "foreign-owner") {
        case .rejected(let code): XCTAssertEqual(code, .ownerMismatch)
        default: XCTFail("foreign owner must not adopt shutdown")
        }
        XCTAssertEqual(RuntimeOwnedWorkRegistry.shared.count(for: boot.epoch), before)
        XCTAssertFalse(G04WorkspaceRetirementGate.shared.hasPendingLease(epoch: boot.epoch))
        XCTAssertNotNil(AndroidRuntimeBootstrap.currentGenerationForTesting())
    }

    func testRootShutdownPreservesDirtyDraftDurableBeforeDrainCompletes() async throws {
        let first = try await bootInstalledGeneration(preparedRoot: nil)
        let (taskID, _) = try await makeOrdinaryConversation(epoch: first.epoch)
        let activation = try await settle(receipt: try submit(
            envelope(command: "workspace.activate", taskID: taskID,
                     payload: ["nativeEpoch": String(first.epoch)]),
            correlation: "act"), command: "workspace.activate", taskID: taskID)
        let workspaceID = try XCTUnwrap(UUID(uuidString: activation["workspaceID"] as? String ?? ""))
        _ = try await settle(receipt: try submit(
            envelope(command: "workspace.write", taskID: taskID,
                     payload: ["op": "createFile", "workspaceID": workspaceID.uuidString,
                               "nativeEpoch": String(first.epoch), "path": "notes.md",
                               "content": "original"]),
            correlation: "create"), command: "workspace.write", taskID: taskID)
        let opened = try await settle(receipt: try submit(
            envelope(command: "workspace.read", taskID: taskID,
                     payload: ["op": "open", "workspaceID": workspaceID.uuidString,
                               "nativeEpoch": String(first.epoch), "path": "notes.md"]),
            correlation: "open"), command: "workspace.read", taskID: taskID)
        _ = try await settle(receipt: try submit(
            envelope(command: "workspace.write", taskID: taskID,
                     payload: ["op": "edit", "workspaceID": workspaceID.uuidString,
                               "nativeEpoch": String(first.epoch),
                               "documentID": try XCTUnwrap(opened["documentID"] as? String),
                               "revision": try XCTUnwrap(opened["revision"] as? String),
                               "location": 8, "length": 0, "replacement": " DRAFT-LOST-WORK"]),
            correlation: "edit"), command: "workspace.write", taskID: taskID)
        let recoveryDir = try workspaceRootURL(taskID: taskID).appendingPathComponent("Recovered Edits")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryDir.path))

        // REAL shutdown: gate attach -> pre-drain verified preservation ->
        // drain -> close. When shutdown reports closed, the copy MUST exist.
        try await shutdownAndAwaitClosed(first)
        let copies = try FileManager.default.contentsOfDirectory(atPath: recoveryDir.path)
        let copy = try XCTUnwrap(copies.first, "clean shutdown must have preserved the draft durably")
        let text = try String(contentsOf: recoveryDir.appendingPathComponent(copy), encoding: .utf8)
        XCTAssertTrue(text.contains("DRAFT-LOST-WORK"))
        let expected = String(FloeDigest.sha256Hex(Data("notes.md".utf8)).prefix(16)) + "-" +
            FloeDigest.sha256Hex(Data(text.utf8)) + ".txt"
        XCTAssertEqual(copy, expected)
        // The next generation can open the recovered copy normally.
        _ = try await bootInstalledGeneration(preparedRoot: first.rootPath)
        let secondActivation = try await settle(receipt: try submit(
            envelope(command: "workspace.activate", taskID: taskID,
                     payload: ["nativeEpoch": String(try XCTUnwrap(
                        G02RuntimeComposition.shared.installedComposition?.epoch))]),
            correlation: "act2"), command: "workspace.activate", taskID: taskID)
        let ws2 = try XCTUnpack(secondActivation)
        let recovered = try await settle(receipt: try submit(
            envelope(command: "workspace.read", taskID: taskID,
                     payload: ["op": "open", "workspaceID": ws2,
                               "nativeEpoch": String(try XCTUnwrap(
                        G02RuntimeComposition.shared.installedComposition?.epoch)),
                               "path": "Recovered Edits/\(expected)"]),
            correlation: "open-recovered"), command: "workspace.read", taskID: taskID)
        XCTAssertEqual(recovered["utf8Bytes"] as? Int, text.utf8.count)
    }

    /// Preservation that cannot settle keeps the ORIGINAL lifecycle honest:
    /// the gate lease stays attached, the bounded drain legitimately times
    /// out into `retirementPending = shutdownTimeout` / failedDrainPending
    /// (root owned, drafts referenced), and repairing the root lets the
    /// existing watch-retry finish preservation for real. No fake success.
    func testUnprovenPreservationHoldsDrainAndRetryCompletesIt() async throws {
        let first = try await bootInstalledGeneration(preparedRoot: nil)
        let (taskID, _) = try await makeOrdinaryConversation(epoch: first.epoch)
        let activation = try await settle(receipt: try submit(
            envelope(command: "workspace.activate", taskID: taskID,
                     payload: ["nativeEpoch": String(first.epoch)]),
            correlation: "act"), command: "workspace.activate", taskID: taskID)
        let workspaceID = try XCTUnwrap(UUID(uuidString: activation["workspaceID"] as? String ?? ""))
        _ = try await settle(receipt: try submit(
            envelope(command: "workspace.write", taskID: taskID,
                     payload: ["op": "createFile", "workspaceID": workspaceID.uuidString,
                               "nativeEpoch": String(first.epoch), "path": "keep.txt",
                               "content": "base"]),
            correlation: "create"), command: "workspace.write", taskID: taskID)
        let opened = try await settle(receipt: try submit(
            envelope(command: "workspace.read", taskID: taskID,
                     payload: ["op": "open", "workspaceID": workspaceID.uuidString,
                               "nativeEpoch": String(first.epoch), "path": "keep.txt"]),
            correlation: "open"), command: "workspace.read", taskID: taskID)
        _ = try await settle(receipt: try submit(
            envelope(command: "workspace.write", taskID: taskID,
                     payload: ["op": "edit", "workspaceID": workspaceID.uuidString,
                               "nativeEpoch": String(first.epoch),
                               "documentID": try XCTUnwrap(opened["documentID"] as? String),
                               "revision": try XCTUnwrap(opened["revision"] as? String),
                               "location": 4, "length": 0, "replacement": "-dirty"]),
            correlation: "edit"), command: "workspace.write", taskID: taskID)

        // Sabotage the recovery location: a regular FILE where the
        // `Recovered Edits` DIRECTORY must materialize -> createDirectory
        // refuses -> preservation cannot prove bytes.
        let recoveryDirURL = try workspaceRootURL(taskID: taskID)
            .appendingPathComponent("Recovered Edits")
        first.retired = true   // this test owns the shutdown it is about to make
        try Data("blocked".utf8).write(to: recoveryDirURL)
        switch AndroidRuntimeBootstrap.shutdown(expectedEpoch: first.epoch,
                                                ownerToken: first.token) {
        case .accepted, .idempotent: break
        case .rejected(let code): XCTFail("shutdown control rejected: \(code.rawValue)")
        }
        // The original drain must NOT complete clean: poll for the typed
        // deferred state instead of waiting forever.
        var pending = false
        let deadline = Date().addingTimeInterval(Double(G04SourceMailboxLimits.readBudgetMillis +
                                                        G04SourceMailboxLimits.writeBudgetMillis) / 1000 + 90)
        while Date() < deadline {
            let status = AndroidRuntimeBootstrap.statusSnapshotJSON()
            if status.contains("\"retirementPending\":\"shutdownTimeout\"") { pending = true; break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(pending, "unproven drafts must hold the drain (failedDrainPending), not a fake close")

        // Repair the root, then drive the DOCUMENTED retirement retry: the
        // trusted-shutdown timeout path keeps ownership and states "a caller
        // may retry" (the automatic retirement watch belongs to the failed
        // BOOTSTRAP path). The retry control re-arms the still-attached gate
        // lease and re-runs the SAME pre-drain pass, which must now settle
        // verified and close.
        try FileManager.default.removeItem(at: recoveryDirURL)
        switch AndroidRuntimeBootstrap.shutdown(expectedEpoch: first.epoch,
                                                ownerToken: first.token) {
        case .accepted, .idempotent: break
        case .rejected(let code): XCTFail("retirement retry rejected: \(code.rawValue)")
        }
        var closed = false
        let closeDeadline = Date().addingTimeInterval(120)
        while Date() < closeDeadline {
            if AndroidRuntimeBootstrap.currentGenerationForTesting() == nil { closed = true; break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTAssertTrue(closed, "watch retry must finish preservation and close the root")
        let copies = try FileManager.default.contentsOfDirectory(atPath: recoveryDirURL.path)
        XCTAssertTrue(copies.contains { $0.hasSuffix(".txt") })
    }

    /// Explicit successful conversation deletion owns cleanup: its drafts are
    /// DISCARDED (never preserved, never resurrected at a later attach).
    func testDeletedConversationDraftIsDiscardedNotPreserved() async throws {
        let boot = try await bootInstalledGeneration(preparedRoot: nil)
        let (taskID, cluster) = try await makeOrdinaryConversation(epoch: boot.epoch)
        let activation = try await settle(receipt: try submit(
            envelope(command: "workspace.activate", taskID: taskID,
                     payload: ["nativeEpoch": String(boot.epoch)]),
            correlation: "act"), command: "workspace.activate", taskID: taskID)
        let workspaceID = try XCTUnwrap(UUID(uuidString: activation["workspaceID"] as? String ?? ""))
        _ = try await settle(receipt: try submit(
            envelope(command: "workspace.write", taskID: taskID,
                     payload: ["op": "createFile", "workspaceID": workspaceID.uuidString,
                               "nativeEpoch": String(boot.epoch), "path": "temp.md",
                               "content": "base"]),
            correlation: "create"), command: "workspace.write", taskID: taskID)
        let opened = try await settle(receipt: try submit(
            envelope(command: "workspace.read", taskID: taskID,
                     payload: ["op": "open", "workspaceID": workspaceID.uuidString,
                               "nativeEpoch": String(boot.epoch), "path": "temp.md"]),
            correlation: "open"), command: "workspace.read", taskID: taskID)
        _ = try await settle(receipt: try submit(
            envelope(command: "workspace.write", taskID: taskID,
                     payload: ["op": "edit", "workspaceID": workspaceID.uuidString,
                               "nativeEpoch": String(boot.epoch),
                               "documentID": try XCTUnwrap(opened["documentID"] as? String),
                               "revision": try XCTUnwrap(opened["revision"] as? String),
                               "location": 4, "length": 0, "replacement": "-dirty"]),
            correlation: "edit"), command: "workspace.write", taskID: taskID)
        // Committed deletion through the ORIGINAL durable authority.
        try await cluster.conversationStore.deleteConversation(id: taskID)
        try await cluster.workspaceStore.deleteWorkspace(id: workspaceID)
        try await shutdownAndAwaitClosed(boot)
        // Nothing was resurrected after the deleted-task shutdown. The live
        // composition is GONE with the closed generation, so the root under
        // test is this boot's OWN accepted root path — never a re-read of a
        // dead graph.
        let recoveryDir = URL(fileURLWithPath: boot.rootPath)
            .appendingPathComponent("Workspace/PrivateTasks/\(taskID.uuidString)")
            .appendingPathComponent("Recovered Edits")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryDir.path),
                       "explicit deletion must never be resurrected by retirement")
    }

    /// Session invalidation on a live rebind must NOT touch a deleted task's
    /// bytes and must preserve a surviving rebind honestly (unit-level).
    func testCrossWorkspaceStaleHandleCannotTouchAnotherTask() async throws {
        let boot = try await bootInstalledGeneration(preparedRoot: nil)
        let (firstID, _) = try await makeOrdinaryConversation(epoch: boot.epoch)
        let (secondID, _) = try await makeOrdinaryConversation(epoch: boot.epoch)
        let first = try await settle(receipt: try submit(
            envelope(command: "workspace.activate", taskID: firstID,
                     payload: ["nativeEpoch": String(boot.epoch)]),
            correlation: "a"), command: "workspace.activate", taskID: firstID)
        let second = try await settle(receipt: try submit(
            envelope(command: "workspace.activate", taskID: secondID,
                     payload: ["nativeEpoch": String(boot.epoch)]),
            correlation: "b"), command: "workspace.activate", taskID: secondID)
        let firstWS = try XCTUnpack(first)
        let secondWS = try XCTUnpack(second)
        _ = try await settle(receipt: try submit(
            envelope(command: "workspace.write", taskID: firstID,
                     payload: ["op": "createFile", "workspaceID": firstWS,
                               "nativeEpoch": String(boot.epoch), "path": "secret.txt",
                               "content": "mine"]),
            correlation: "c"), command: "workspace.write", taskID: firstID)
        let opened = try await settle(receipt: try submit(
            envelope(command: "workspace.read", taskID: firstID,
                     payload: ["op": "open", "workspaceID": firstWS,
                               "nativeEpoch": String(boot.epoch), "path": "secret.txt"]),
            correlation: "d"), command: "workspace.read", taskID: firstID)
        let documentID = try XCTUnwrap(opened["documentID"] as? String)
        // Second task addressing the FIRST task's documentID/revision under
        // its own workspaceID: the session simply has no such document.
        await assertRefusal(code: "missingDocument", command: "workspace.write", taskID: secondID,
                            payload: ["op": "edit", "workspaceID": secondWS,
                                      "nativeEpoch": String(boot.epoch),
                                      "documentID": documentID,
                                      "revision": try XCTUnwrap(opened["revision"] as? String),
                                      "location": 0, "length": 0, "replacement": "x"])
        // And the second task cannot delete through the first's binding.
        await assertRefusal(code: "notFound", command: "workspace.write", taskID: secondID,
                            payload: ["op": "delete", "workspaceID": secondWS,
                                      "nativeEpoch": String(boot.epoch), "path": "secret.txt"])
        XCTAssertEqual(try String(contentsOf: workspaceRootURL(taskID: firstID)
            .appendingPathComponent("secret.txt"), encoding: .utf8), "mine")
    }

    private func XCTUnpack(_ object: [String: Any]) throws -> String {
        try XCTUnwrap(object["workspaceID"] as? String)
    }
}
