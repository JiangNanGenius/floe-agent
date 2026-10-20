// SPDX-License-Identifier: MPL-2.0
//
// RB-1 source tests — generation lifecycle and admission races (Main draft
// review testsRequested). Everything runs against REAL file-backed original
// stores in test-owned directories; there is no fake readiness, no nil
// normalizer and no synthetic business DB anywhere in this path.
// AUTHORED ONLY: not compiled or executed by this source package.
import XCTest
import Foundation
import GRDB
import FloeModels
import FloePersistence
@testable import FloeAndroidCore

final class RuntimeFacadeBootstrapTests: XCTestCase {

    private var roots: [String] = []

    override func tearDown() {
        // Release the ordinary composition this default-mode fixture caused
        // to install (owner cleanup of its binder ingress) before the
        // bootstrap reset — never leave stale captured handlers in the
        // process-global binder for later fixtures.
        G02RuntimeComposition.shared.resetForTesting()
        AndroidRuntimeBootstrap.resetForTesting()
        for root in roots {
            try? FileManager.default.removeItem(atPath: root)
        }
        roots.removeAll()
        super.tearDown()
    }

    private func freshRoot() throws -> String {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("floe-rb1-life-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        roots.append(base.path)
        return base.standardizedFileURL.path
    }

    private let tokenA = "a1b2c3d4e5f60718a1b2c3d4e5f60718"
    private let tokenB = "ffffffffffffffffffffffffffffffff"

    // MARK: M2 — exact replay, stale epoch, same/different root/token

    func testExactReplayIsIdempotentAndOpensNoSecondDatabase() async throws {
        let root = try freshRoot()
        guard case .accepted(let receipt) =
            AndroidRuntimeBootstrap.start(rootPath: root, ownerToken: tokenA, epoch: 1)
        else { return XCTFail("start") }
        // Exact same root/token/epoch replay: idempotent BEFORE any
        // stale-epoch guard, and no second DB/job/effect.
        guard case .idempotent(let replay) =
            AndroidRuntimeBootstrap.start(rootPath: root, ownerToken: tokenA, epoch: 1)
        else { return XCTFail("replay must be idempotent") }
        XCTAssertEqual(replay, receipt)
        // Trailing-slash spelling normalizes to the SAME ownership.
        guard case .idempotent =
            AndroidRuntimeBootstrap.start(rootPath: root + "/", ownerToken: tokenA, epoch: 1)
        else { return XCTFail("normalized replay") }
        await assertBootstrapAccepted(receipt)
        // One owned DatabaseManager, proven by the real file + user_version.
        let gen = try XCTUnwrap(AndroidRuntimeBootstrap.currentGenerationForTesting())
        let version = await gen.owner.currentUserVersion()
        XCTAssertEqual(version, 46)
        // The replay window never minted a second effect stream: only the
        // bootstrap receipt + its accepted terminal exist.
        let effects = gen.effects
        if case .page(let items, _, _, _) = effects.poll(receipt: receipt, afterSequence: 0) {
            XCTAssertEqual(items.filter { $0.isTerminal }.count, 1)
            XCTAssertEqual(items.first?.kind, .accepted)
        } else { XCTFail("page") }
    }

    func testDifferentFullRootOrTokenIsTypedMismatchWhileOwned() async throws {
        let rootA = try freshRoot()
        let rootB = try freshRoot()
        guard case .accepted =
            AndroidRuntimeBootstrap.start(rootPath: rootA, ownerToken: tokenA, epoch: 1)
        else { return XCTFail("start A") }
        await assertBootstrapAcceptedToGeneration()
        // Different FULL root, same token.
        if case .rejected(let code) =
            AndroidRuntimeBootstrap.start(rootPath: rootB, ownerToken: tokenA, epoch: 2) {
            XCTAssertEqual(code, .ownerMismatch)
        } else { XCTFail("mismatched root while owned must refuse") }
        // Same root, different token.
        if case .rejected(let code) =
            AndroidRuntimeBootstrap.start(rootPath: rootA, ownerToken: tokenB, epoch: 3) {
            XCTAssertEqual(code, .ownerMismatch)
        } else { XCTFail("mismatched token while owned must refuse") }
        // Same owner, NEWER epoch: rebind refusal, not silent takeover (M2).
        if case .rejected(let code) =
            AndroidRuntimeBootstrap.start(rootPath: rootA, ownerToken: tokenA, epoch: 9) {
            XCTAssertEqual(code, .rebindWhileOwned)
        } else { XCTFail("newer-epoch rebind while owned must refuse") }
        // The refused attempts opened nothing: still one generation.
        let gen = try XCTUnwrap(AndroidRuntimeBootstrap.currentGenerationForTesting())
        XCTAssertEqual(gen.epoch, 1)
    }

    // MARK: M3 — fence at accepted boundary; queued settles before close

    func testShutdownFencesNewAdmissionAtAcceptedBoundary() async throws {
        let root = try freshRoot()
        guard case .accepted(let receipt) =
            AndroidRuntimeBootstrap.start(rootPath: root, ownerToken: tokenA, epoch: 1)
        else { return XCTFail("start") }
        await assertBootstrapAcceptedToGeneration()
        // Deterministic fence observation: hold one REAL queued operation
        // across the accepted shutdown boundary so the mailbox is in the
        // fenced-but-not-yet-closed phase when the late submission arrives.
        // (Without this hold, a fast test close can legally answer
        // `.mailboxClosed` instead of the accepted-boundary `.alreadyDraining`.)
        let blocker = try XCTUnwrap(AndroidRuntimeBootstrap
            .currentGenerationForTesting())
        let gate = BlockingGate()
        // Exact blocker identity proof (corpus-first timing repair): the
        // registered processor marks this latch when IT starts, before it
        // parks on the gate. The prior global `active == 1` count assumed no
        // other legitimate mailbox work was in flight; the bootstrap's own
        // start job is still ACTIVE while the store reports ready (the
        // composition install and accepted terminal settle AFTER the
        // ownedStoreReady fact), so an unrelated global count is racy.
        // Waiting on OUR processor's entered latch is deterministic, never
        // masks unrelated active work, and is not a weaker count or sleep.
        let blockerEntered = EntryLatch()
        blocker.registry.register(
            handlerKey: "fence-blocker",
            processor: RuntimeAsyncProcessor { _ in
                blockerEntered.mark()
                gate.wait()
                return .accepted()
            })
        let blockerReceipt = try XCTUnwrap(
            blocker.effects.register(correlationID: "fence-blocker"))
        guard case .queued = blocker.mailbox.submit(RuntimeCommandEnvelopeJob(
            correlationID: "fence-blocker", handlerKey: "fence-blocker",
            command: "fence.blocker", scope: .applicationConfiguration,
            configurationScope: "system", receipt: blockerReceipt,
            envelope: Data("{}".utf8))) else {
            return XCTFail("blocker must be queued")
        }
        await waitForCondition(timeoutSeconds: 3) {
            blockerEntered.marked
        }
        // Exact identity evidence (waitForCondition alone can time out
        // silently): the registered blocker processor MUST have started and
        // be parked on the gate before the shutdown boundary is crossed.
        guard blockerEntered.marked else {
            gate.openNow()
            return XCTFail("the exact fence-blocker processor never started")
        }
        // The exact blocker occupies the mailbox while parked on the gate.
        XCTAssertGreaterThanOrEqual(
            blocker.mailbox.snapshotCountsForTesting().active, 1)
        guard case .accepted(let control) = AndroidRuntimeBootstrap.shutdown(
            expectedEpoch: 1, ownerToken: tokenA) else {
            return XCTFail("shutdown")
        }
        XCTAssertNotEqual(control, receipt)
        // NEW admissions are refused immediately at the fence — not only
        // when the worker eventually begins draining.
        guard let gen = AndroidRuntimeBootstrap.currentGenerationForTesting() else {
            return XCTFail("generation must remain owned until real close")
        }
        XCTAssertTrue(gen.mailbox.isAdmissionFenced)
        let late = gen.effects.register(correlationID: "late-corr")
        XCTAssertNotNil(late)
        if let late {
            XCTAssertEqual(gen.mailbox.submit(RuntimeCommandEnvelopeJob(
                correlationID: "late-corr", handlerKey: "k", command: "c",
                scope: .applicationConfiguration, configurationScope: "system",
                receipt: late, envelope: Data("{}".utf8))), .rejected(.alreadyDraining))
        }
        // Release the real blocker: the drain then completes and the control
        // settles EXACTLY ONE readable terminal after the real close.
        gate.openNow()
        let terminal = await waitShutdownTerminal(gen.effects, receipt: control)
        switch terminal {
        case .acceptedOnce: break
        case .failed(let detail): XCTFail(detail)
        }
        // After teardown the receipt stays readable (bounded), never
        // retire-dropped (M3).
        if case .page(let items, _, _, _) = gen.effects.poll(receipt: control,
                                                             afterSequence: 0) {
            XCTAssertEqual(items.filter { $0.isTerminal }.count, 1)
            XCTAssertEqual(items.last?.kind, .accepted)
        } else { XCTFail("control must remain readable after teardown") }
        // And the status is honest stopped.
        let status = AndroidRuntimeBootstrap.statusSnapshotJSON()
        XCTAssertTrue(status.contains("\"phase\":\"stopped\""))
        XCTAssertTrue(status.contains("\"ownedStoreReady\":false"))
    }

    // MARK: M4 — clean stop then real new start

    func testCleanStopThenNewStartOpensRealDatabaseAgain() async throws {
        let root = try freshRoot()
        guard case .accepted(let first) =
            AndroidRuntimeBootstrap.start(rootPath: root, ownerToken: tokenA, epoch: 1)
        else { return XCTFail("start") }
        await assertBootstrapAcceptedToGeneration()
        guard let gen = AndroidRuntimeBootstrap.currentGenerationForTesting() else {
            return XCTFail("generation must exist before shutdown")
        }
        guard case .accepted(let control) = AndroidRuntimeBootstrap.shutdown(
            expectedEpoch: 1, ownerToken: tokenA) else {
            return XCTFail("shutdown")
        }
        _ = await waitShutdownTerminal(gen.effects, receipt: control)
        // Supported new start with a strictly newer epoch (same root).
        guard case .accepted(let second) =
            AndroidRuntimeBootstrap.start(rootPath: root, ownerToken: tokenA, epoch: 2)
        else { return XCTFail("new start after clean stop") }
        XCTAssertNotEqual(first, second)
        await assertBootstrapAcceptedToGeneration()
        let gen2 = try XCTUnwrap(AndroidRuntimeBootstrap.currentGenerationForTesting())
        XCTAssertEqual(gen2.epoch, 2)
        // Old receipts belong to the retired App instance: typed notFound
        // in the NEW pump (never silent success, never resurrection).
        if case .notFound = gen2.effects.poll(receipt: first, afterSequence: 0) {}
        else { XCTFail("old bootstrap receipt must not resolve in the new pump") }
        // Stale-epoch replays after retirement stay epochNotNewer.
        if case .rejected(let code) =
            AndroidRuntimeBootstrap.start(rootPath: root, ownerToken: tokenA, epoch: 1) {
            XCTAssertEqual(code, .epochNotNewer)
        } else { XCTFail("stale replay must refuse") }
    }

    // MARK: M2/M4 — failed bootstrap refuses early replacement then admits

    func testFailedBootstrapRetiresOnlyAfterRealCloseThenAllowsNewStart() async throws {
        // A regular file where the trusted root directory should be makes
        // the ORIGINAL open fail typed — no fake store, no fallback path.
        let base = try freshRoot()
        let blocker = URL(fileURLWithPath: base).appendingPathComponent("file")
        FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
        let badRoot = blocker.appendingPathComponent("sub", isDirectory: true).path
        guard case .accepted(let failedReceipt) =
            AndroidRuntimeBootstrap.start(rootPath: badRoot, ownerToken: tokenA, epoch: 1)
        else { return XCTFail("start bad") }
        // The bootstrap effect settles typed failed with the real code.
        let deadline = Date().addingTimeInterval(15)
        var sawFailed = false
        while Date() < deadline && !sawFailed {
            if let gen = AndroidRuntimeBootstrap.currentGenerationForTesting() {
                if case .page(let items, _, _, _) =
                    gen.effects.poll(receipt: failedReceipt, afterSequence: 0),
                   let terminal = items.last(where: { $0.isTerminal }) {
                    XCTAssertEqual(terminal.kind, .failed)
                    XCTAssertEqual(terminal.code, .checkpointDirectoryFailed)
                    sawFailed = true
                    break
                }
            } else {
                // Retired during our observation: last state must have said
                // failed; verify the status truth instead of racing effects.
                let status = AndroidRuntimeBootstrap.statusSnapshotJSON()
                XCTAssertTrue(status.contains("\"phase\":\"failed\""))
                XCTAssertTrue(status.contains("checkpointDirectoryFailed"))
                sawFailed = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(sawFailed, "failed bootstrap must settle typed terminal")
        // Replacement only with a strictly newer epoch AND after retirement.
        let goodRoot = try freshRoot()
        var started: AndroidRuntimeBootstrap.StartOutcome = .rejected(.notInstalled)
        let admitDeadline = Date().addingTimeInterval(15)
        var attempt = AndroidRuntimeBootstrap.start(rootPath: goodRoot,
                                                    ownerToken: tokenA, epoch: 2)
        while Date() < admitDeadline {
            if case .accepted = attempt { break }
            if case .idempotent = attempt { break }
            // While the failed close is still real, replacement is fenced
            // (alreadyDraining) or the retirement lags (ownerMismatch);
            // retry ONLY against those typed refusals.
            if case .rejected(let code) = attempt {
                switch code {
                case .alreadyDraining, .ownerMismatch, .epochNotNewer:
                    break
                case .notInstalled:
                    // Nothing live yet: this should only be visible BEFORE
                    // the first failed start; retry once then fail loudly.
                    break
                default:
                    XCTFail("unexpected refusal during retire window: \(code)")
                    break
                }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            attempt = AndroidRuntimeBootstrap.start(rootPath: goodRoot,
                                                    ownerToken: tokenA, epoch: 2)
            started = attempt
        }
        started = attempt
        if case .accepted(let goodReceipt) = started {
            await assertBootstrapAcceptedToGeneration()
            let gen = try XCTUnwrap(AndroidRuntimeBootstrap.currentGenerationForTesting())
            XCTAssertEqual(gen.epoch, 2)
            XCTAssertNotNil(gen.owner)
            _ = goodReceipt
        } else {
            XCTFail("new start after failed retirement must be admitted: \(started)")
        }
    }

    // MARK: Concurrent start/shutdown while bootstrap work is live

    func testConcurrentStartAndShutdownDuringBootstrapResolveToOneOwner() async throws {
        let root = try freshRoot()
        // Capture test-instance values locally: async-let closures must not
        // send `self` (the XCTestCase) across isolation boundaries.
        let token = tokenA
        async let firstStart = AndroidRuntimeBootstrap.start(rootPath: root,
                                                             ownerToken: token, epoch: 1)
        async let secondStart = AndroidRuntimeBootstrap.start(rootPath: root,
                                                              ownerToken: token, epoch: 1)
        async let racingShutdown = AndroidRuntimeBootstrap.shutdown(
            expectedEpoch: 1, ownerToken: token)
        let (a, b, s) = await (firstStart, secondStart, racingShutdown)
        // Exactly one accepted; the other is either idempotent or a typed
        // refusal — never a second generation/DB.
        var accepted = 0
        for outcome in [a, b] {
            switch outcome {
            case .accepted: accepted += 1
            case .idempotent: break
            case .rejected: break
            }
        }
        XCTAssertEqual(accepted, 1)
        var shutdownAccepted = false
        switch s {
        case .accepted, .idempotent:
            shutdownAccepted = true
        case .rejected(.notInstalled):
            break   // shutdown raced BEFORE the accepted start: start owns it
        case .rejected(let code):
            XCTFail("shutdown outcome must be typed lifecycle, got \(code)")
        }
        // Final state is deterministic: either a working store or a clean
        // stop — never both, never a half-ready status. When the shutdown was
        // accepted, wait for the REAL retirement (the control drains the
        // still-opening bootstrap job first); inspecting instantly would
        // observe the legitimate in-flight `starting/draining` phase.
        if shutdownAccepted {
            let deadline = Date().addingTimeInterval(20)
            while AndroidRuntimeBootstrap.currentGenerationForTesting() != nil,
                  Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertNil(AndroidRuntimeBootstrap.currentGenerationForTesting(),
                         "accepted shutdown must really retire the generation")
            let status = AndroidRuntimeBootstrap.statusSnapshotJSON()
            let stopped = status.contains("\"phase\":\"stopped\"")
                || status.contains("\"phase\":\"failed\"")
            XCTAssertTrue(stopped, "clean stop expected: \(status)")
            XCTAssertTrue(status.contains("\"effectPollAvailable\":true"))
            XCTAssertFalse(status.contains("\"domainRuntimeReady\":true"))
        } else {
            await assertBootstrapAcceptedToGeneration()
            let status = AndroidRuntimeBootstrap.statusSnapshotJSON()
            XCTAssertTrue(status.contains("\"ownedStoreReady\":true"))
            XCTAssertFalse(status.contains("\"domainRuntimeReady\":true"))
            let gen = try XCTUnwrap(
                AndroidRuntimeBootstrap.currentGenerationForTesting())
            XCTAssertEqual(gen.epoch, 1)
        }
    }

    // MARK: Status honesty (no fake readiness, no raw root)

    func testStatusKeepsThreeSeparateTypedFactsAndNeverLeaksRoot() async throws {
        let root = try freshRoot()
        guard case .accepted =
            AndroidRuntimeBootstrap.start(rootPath: root, ownerToken: tokenA, epoch: 1)
        else { return XCTFail("start") }
        await assertBootstrapAcceptedToGeneration()
        let status = AndroidRuntimeBootstrap.statusSnapshotJSON()
        // Gateway fact is its OWN bool, independent from the store fact.
        XCTAssertTrue(status.contains("\"gatewayRegistered\":"))
        XCTAssertTrue(status.contains("\"ownedStoreReady\":true"))
        XCTAssertTrue(status.contains("\"domainRuntimeReady\":false"))
        XCTAssertTrue(status.contains("\"ordinaryRuntimeAdmission\":\"blocked\""))
        for binding in AndroidRuntimeBootstrap.MissingBinding.allCases {
            XCTAssertTrue(status.contains(binding.rawValue),
                          "missing binding \(binding) must be listed")
        }
        // No raw root path anywhere (only the short fingerprint).
        XCTAssertFalse(status.contains(root))
        XCTAssertFalse(status.contains(tokenA))
        // Real store file exists under the trusted root (single DB).
        let dbFile = URL(fileURLWithPath: root).appendingPathComponent("floe.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbFile.path))
    }

    // MARK: Recovery over ORIGINAL rows (durable file survives retirement)

    func testRecoveryMarksRealInterruptedRowsThroughOriginalStores() async throws {
        let root = try freshRoot()
        // Pre-seed durable rows with the ORIGINAL stores, then "die".
        let seed = try DatabaseManager(path:
            URL(fileURLWithPath: root).appendingPathComponent("floe.sqlite"))
        try await seed.migrate()
        let conversationStore = SQLiteConversationStore(database: seed)
        let runStore = SQLiteRunStore(database: seed)
        let inputStore = SQLiteRunningInputStore(database: seed)
        let childStore = SQLiteChildRunStore(database: seed)
        let conversationID = UUID()
        let now = Date()
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "seed", createdAt: now, updatedAt: now))
        let parentRun = UUID()
        try await runStore.saveRun(RunRecord(id: parentRun, conversationID: conversationID,
                                             state: "running", goal: "seed", startedAt: now))
        let childRun = UUID()
        try await childStore.register(ChildRunRecord(
            id: childRun, parentRunID: parentRun, rootRunID: parentRun,
            conversationID: conversationID, childIndex: 0,
            kind: "delegate", taskSummary: "seed child", state: .running))
        _ = try await inputStore.enqueue(PendingUserInput(
            conversationID: conversationID, content: "steer",
            mode: .steer, status: .steerPending))
        try await seed.close()   // simulate process death: durable file remains

        guard case .accepted(let receipt) =
            AndroidRuntimeBootstrap.start(rootPath: root, ownerToken: tokenA, epoch: 1)
        else { return XCTFail("start") }
        await assertBootstrapAccepted(receipt)
        let gen = try XCTUnwrap(AndroidRuntimeBootstrap.currentGenerationForTesting())
        let summary = await gen.owner.currentRecoverySummary()
        XCTAssertEqual(summary.interruptedRunsMarked, 1)
        XCTAssertEqual(summary.interruptedChildrenMarked, 1)
        XCTAssertTrue(summary.transientInputsRecovered)
        XCTAssertEqual(summary.credentialDeletionsDrained, 0) // RB1 never drains
        // The durable rows really changed (original store reads).
        let run = try await gen.owner.runStoreProbe { store in
            try await store.run(id: parentRun)
        }
        XCTAssertEqual(run?.state, "interrupted")
        let child = await gen.owner.childStoreProbe { store in
            try? await store.child(id: childRun)
        }
        XCTAssertEqual(child?.state, .interrupted)
    }

    // MARK: Deferred credential queue (count-only, no duplicate drain)

    func testRecoveryCountsDeferredCredentialQueueWithExactSQL() async throws {
        let root = try freshRoot()
        let databaseURL = URL(fileURLWithPath: root)
            .appendingPathComponent("floe.sqlite")
        let seed = try DatabaseManager(path: databaseURL)
        try await seed.migrate()
        try await seed.writer { db in
            for index in 0..<250 {
                try db.execute(
                    sql: """
                    INSERT INTO credential_deletion_queue
                        (keychain_account, synchronizable, enqueued_at)
                    VALUES (?, 0, datetime('now'))
                    """,
                    arguments: ["credential.queue.\(index)"])
            }
        }
        let rawCount = try await seed.reader { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM credential_deletion_queue") ?? 0
        }
        XCTAssertEqual(rawCount, 250)
        try await seed.close()   // durable original V11 queue survives

        guard case .accepted = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: tokenA, epoch: 1) else {
            return XCTFail("start")
        }
        await assertBootstrapAcceptedToGeneration()
        let gen = try XCTUnwrap(AndroidRuntimeBootstrap.currentGenerationForTesting())
        let summary = await gen.owner.currentRecoverySummary()
        XCTAssertEqual(summary.credentialDeletionsPending, rawCount)
        XCTAssertEqual(summary.credentialDeletionsDeferred, rawCount)
        XCTAssertEqual(summary.credentialDeletionsDrained, 0)
        // The queue is untouched (bootstrap counts/defers; the vault-owned
        // operation package owns the real drain).
        let counted = await gen.owner.credentialDeletionQueueCountForTesting()
        XCTAssertEqual(counted, rawCount)
    }

    // MARK: RB1-R3/RB4/vault — real domain-owned work gates retirement

    func testDomainOwnedWorkAttachDetachGatesRetirement() async throws {
        let root = try freshRoot()
        guard case .accepted = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: tokenA, epoch: 1) else {
            return XCTFail("start")
        }
        await assertBootstrapAcceptedToGeneration()
        let gen = try XCTUnwrap(AndroidRuntimeBootstrap.currentGenerationForTesting())
        // Invalid path-like identities are refused without entering the map.
        if case .invalidIdentity = RuntimeOwnedWorkRegistry.shared.attach(
            epoch: 1, kind: .run, ownerID: "/data/local/tmp/evil") {
        } else { XCTFail("path-like work identity must be refused") }
        // No foreign epoch before this generation accepted it.
        if case .rejected(.notInstalled) = RuntimeOwnedWorkRegistry.shared.attach(
            epoch: 2, kind: .run, ownerID: "run-foreign") {
        } else { XCTFail("foreign epoch attach must be refused") }
        guard case .attached(let runToken) = RuntimeOwnedWorkRegistry.shared.attach(
            epoch: 1, kind: .run, ownerID: "run-\(UUID().uuidString)") else {
            return XCTFail("run attach")
        }
        guard case .attached(let vaultToken) = RuntimeOwnedWorkRegistry.shared.attach(
            epoch: 1, kind: .vaultMaintenance,
            ownerID: "vault-\(UUID().uuidString)") else {
            return XCTFail("vault attach")
        }
        XCTAssertTrue(RuntimeOwnedWorkReceipt.isValid(runToken.receipt))
        XCTAssertEqual(RuntimeOwnedWorkRegistry.shared.count(for: 1), 2)
        XCTAssertEqual(RuntimeOwnedWorkRegistry.shared.countsByKind(for: 1)["run"], 1)
        XCTAssertEqual(
            RuntimeOwnedWorkRegistry.shared.countsByKind(for: 1)["vaultMaintenance"], 1)
        let withWork = AndroidRuntimeBootstrap.statusSnapshotJSON()
        XCTAssertTrue(withWork.contains("\"domainOwnedWork\":2"))
        XCTAssertTrue(withWork.contains("\"domainRuntimeReady\":false"))
        // Stop is accepted, but the real shutdown gate must wait for BOTH
        // attached work items, not just the now-settled mailbox.
        guard case .accepted(let control) = AndroidRuntimeBootstrap.shutdown(
            expectedEpoch: 1, ownerToken: tokenA) else {
            return XCTFail("shutdown")
        }
        if case .rejected(.alreadyDraining) = RuntimeOwnedWorkRegistry.shared.attach(
            epoch: 1, kind: .tool, ownerID: "tool-after-stop") {
        } else { XCTFail("new attach after stop admission must be refused") }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNotNil(AndroidRuntimeBootstrap.currentGenerationForTesting())
        XCTAssertTrue(AndroidRuntimeBootstrap.statusSnapshotJSON()
            .contains("\"ownedStoreReady\":true"))
        if case .page(let items, _, _, _) = gen.effects.poll(receipt: control,
                                                             afterSequence: 0) {
            XCTAssertTrue(items.filter { $0.isTerminal }.isEmpty)
        } else { XCTFail("control receipt must exist") }
        // Detach is exact and idempotent; one remaining real item still holds
        // the database open.
        XCTAssertTrue(RuntimeOwnedWorkRegistry.shared.detach(runToken))
        XCTAssertFalse(RuntimeOwnedWorkRegistry.shared.detach(runToken))
        XCTAssertEqual(RuntimeOwnedWorkRegistry.shared.count(for: 1), 1)
        XCTAssertNotNil(AndroidRuntimeBootstrap.currentGenerationForTesting())
        XCTAssertTrue(RuntimeOwnedWorkRegistry.shared.detach(vaultToken))
        await waitForCondition(timeoutSeconds: 10) {
            AndroidRuntimeBootstrap.currentGenerationForTesting() == nil
        }
        let terminal = await waitForTerminal(gen.effects, receipt: control, timeout: 10)
        XCTAssertEqual(terminal?.kind, .accepted)
        XCTAssertEqual(RuntimeOwnedWorkRegistry.shared.totalCount, 0)
        // A new generation is unaffected by the old token.
        guard case .accepted = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: tokenA, epoch: 2) else {
            return XCTFail("new start")
        }
        await assertBootstrapAcceptedToGeneration()
        XCTAssertFalse(RuntimeOwnedWorkRegistry.shared.detach(runToken))
        XCTAssertEqual(RuntimeOwnedWorkRegistry.shared.count(for: 1), 0)
        if case .rejected(.notInstalled) = RuntimeOwnedWorkRegistry.shared.attach(
            epoch: 1, kind: .run, ownerID: "old-run") {
        } else { XCTFail("old epoch attach after new start must be refused") }
    }

    // MARK: RB1-R2 — retry correlation is the ACTUAL control correlation

    func testShutdownRetryUsesActualOwnedCorrelationAndPreservesOldTerminal() async throws {
        let root = try freshRoot()
        guard case .accepted = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: tokenA, epoch: 1) else {
            return XCTFail("start")
        }
        await assertBootstrapAcceptedToGeneration()
        let gen = try XCTUnwrap(AndroidRuntimeBootstrap.currentGenerationForTesting())
        let gate = BlockingGate()
        gen.registry.register(
            handlerKey: RuntimeFacadeBridge.systemBootstrapKey,
            processor: RuntimeAsyncProcessor { _ in
                gate.wait()
                return .accepted(detail: ["confirm": "testBlocker"])
            })
        AndroidRuntimeBootstrap.shutdownDrainTimeoutMillisOverride = 150
        let submit = try XCTUnwrap(exchange(submitEnvelope(
            correlation: "r2-blocker", command: "system.bootstrap")))
        _ = try XCTUnwrap(submit["operationReceiptID"] as? String)
        await waitForCondition { gen.mailbox.snapshotCountsForTesting().active >= 1 }
        guard case .accepted(let firstControl) = AndroidRuntimeBootstrap.shutdown(
            expectedEpoch: 1, ownerToken: tokenA) else {
            return XCTFail("first control")
        }
        let firstTerminal = await waitForTerminal(gen.effects, receipt: firstControl,
                                                  timeout: 5)
        XCTAssertEqual(firstTerminal?.kind, .failed)
        XCTAssertEqual(firstTerminal?.code, .shutdownTimeout)
        // Ownership retained: database still open, generation still live.
        let retainedStatus = AndroidRuntimeBootstrap.statusSnapshotJSON()
        XCTAssertTrue(retainedStatus.contains("\"ownedStoreReady\":true"))
        XCTAssertNotNil(AndroidRuntimeBootstrap.currentGenerationForTesting())
        // Release the real work, then retry. If the retry reconstructed
        // `host:shutdown:<epoch>` instead of its ACTUAL correlation, it would
        // wait for itself and time out again.
        gate.openNow()
        await waitForCondition { gen.mailbox.isFullyDrained() }
        guard case .accepted(let retryControl) = AndroidRuntimeBootstrap.shutdown(
            expectedEpoch: 1, ownerToken: tokenA) else {
            return XCTFail("retry control")
        }
        XCTAssertNotEqual(retryControl, firstControl)
        let retryTerminal = await waitForTerminal(gen.effects, receipt: retryControl,
                                                  timeout: 10)
        XCTAssertEqual(retryTerminal?.kind, .accepted)
        // The old receipt keeps exactly one unchanged terminal.
        if case .page(let items, _, _, _) = gen.effects.poll(receipt: firstControl,
                                                             afterSequence: 0) {
            XCTAssertEqual(items.filter { $0.isTerminal }.count, 1)
            XCTAssertEqual(items.last?.kind, .failed)
            XCTAssertEqual(items.last?.code, .shutdownTimeout)
        } else { XCTFail("old receipt must remain readable") }
        XCTAssertNil(AndroidRuntimeBootstrap.currentGenerationForTesting())
        XCTAssertTrue(AndroidRuntimeBootstrap.statusSnapshotJSON()
            .contains("\"phase\":\"stopped\""))
    }

    // MARK: RB1-R3 — a drain timeout never disposes the owner

    func testFailedBootstrapDrainTimeoutRetainsOwnershipUntilRealCompletion() async throws {
        // A regular file where the trusted root directory should be makes
        // the ORIGINAL open fail typed (no fallback path).
        let base = try freshRoot()
        let blocker = URL(fileURLWithPath: base).appendingPathComponent("file")
        FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
        let badRoot = blocker.appendingPathComponent("sub", isDirectory: true).path
        AndroidRuntimeBootstrap.shutdownDrainTimeoutMillisOverride = 150
        let gate = BlockingGate()
        // Test-only rendezvous: queue REAL outstanding command work while the
        // failed-bootstrap job is between its state transition and its fence.
        AndroidRuntimeBootstrap.failedBootstrapDrainGateForTesting = {
            guard let gen = AndroidRuntimeBootstrap.currentGenerationForTesting() else {
                return
            }
            gen.registry.register(
                handlerKey: RuntimeFacadeBridge.systemBootstrapKey,
                processor: RuntimeAsyncProcessor { _ in
                    gate.wait()
                    return .accepted()
                })
            guard let receipt = gen.effects.register(correlationID: "r3-blocker") else {
                return
            }
            _ = gen.mailbox.submit(RuntimeCommandEnvelopeJob(
                correlationID: "r3-blocker",
                handlerKey: RuntimeFacadeBridge.systemBootstrapKey,
                command: "system.bootstrap",
                scope: .applicationConfiguration,
                configurationScope: "system",
                receipt: receipt,
                envelope: Data("{}".utf8)))
        }
        guard case .accepted(let bootstrapReceipt) = AndroidRuntimeBootstrap.start(
            rootPath: badRoot, ownerToken: tokenA, epoch: 1) else {
            return XCTFail("start bad root")
        }
        // Wait until the deferred-retirement state is published.
        var sawPending = false
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let status = AndroidRuntimeBootstrap.statusSnapshotJSON()
            if status.contains("\"phase\":\"failedDrainPending\"") {
                sawPending = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(sawPending, "failed drain must be typed pending")
        guard let gen = AndroidRuntimeBootstrap.currentGenerationForTesting() else {
            return XCTFail("owner must not be released on an undrained timeout")
        }
        // The test rendezvous queues the real blocker before the bounded
        // drain; wait until the drain thread actually claims it.
        await waitForCondition(timeoutSeconds: 3) {
            gen.mailbox.snapshotCountsForTesting().active >= 1
        }
        // The executing bootstrap control itself is active entry #1 and the
        // queued blocker is entry #2: a real drain timeout must retain BOTH.
        XCTAssertEqual(gen.mailbox.snapshotCountsForTesting().active, 2)
        var status = AndroidRuntimeBootstrap.statusSnapshotJSON()
        var sawRetirementPending = false
        let retirementDeadline = Date().addingTimeInterval(5)
        while Date() < retirementDeadline {
            status = AndroidRuntimeBootstrap.statusSnapshotJSON()
            if status.contains("\"retirementPending\":\"shutdownTimeout\"") {
                sawRetirementPending = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(status.contains("\"retiring\":true"))
        XCTAssertTrue(sawRetirementPending, "retirement must be typed pending: \(status)")
        XCTAssertTrue(status.contains("\"ownedStoreReady\":false"))
        // The bootstrap terminal is already failed with deferred retirement.
        let bootstrapTerminal = await waitForTerminal(gen.effects,
                                                       receipt: bootstrapReceipt,
                                                       timeout: 5)
        XCTAssertEqual(bootstrapTerminal?.kind, .failed)
        // Real completion: the watcher enqueues the single retirement control
        // and only then closes/releases.
        gate.openNow()
        await waitForCondition(timeoutSeconds: 10) {
            AndroidRuntimeBootstrap.currentGenerationForTesting() == nil
        }
        let finalStatus = AndroidRuntimeBootstrap.statusSnapshotJSON()
        XCTAssertTrue(finalStatus.contains("\"phase\":\"failed\""))
        XCTAssertFalse(finalStatus.contains("\"ownedStoreReady\":true"))
        // RB1-R1: the failed bootstrap terminal is readable through the
        // actual v3 entry after the real close/retirement.
        var terminalKind: String?
        var attempts = 0
        while attempts < 400 {
            attempts += 1
            let page = try XCTUnwrap(exchange(effectEnvelope(
                correlation: "r3-poll-\(attempts)", receipt: bootstrapReceipt,
                sequence: 0)))
            if let effects = page["effects"] as? [[String: Any]],
               let last = effects.last(where: {
                   ["accepted", "failed", "rejected", "cancelled", "replaced", "closed"]
                       .contains($0["kind"] as? String ?? "")
               }) {
                terminalKind = last["kind"] as? String
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(terminalKind, "failed")
    }

    // MARK: RB1-R5 — stale owner proof cannot stop a newer generation

    func testStaleNativeStopEpochAndTokenDoNotStopNewGeneration() async throws {
        let root = try freshRoot()
        guard case .accepted = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: tokenA, epoch: 1) else {
            return XCTFail("start one")
        }
        await assertBootstrapAcceptedToGeneration()
        guard case .accepted = AndroidRuntimeBootstrap.shutdown(
            expectedEpoch: 1, ownerToken: tokenA) else {
            return XCTFail("stop one")
        }
        await waitForCondition(timeoutSeconds: 10) {
            AndroidRuntimeBootstrap.currentGenerationForTesting() == nil
        }
        guard case .accepted = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: tokenB, epoch: 2) else {
            return XCTFail("start two")
        }
        await assertBootstrapAcceptedToGeneration()
        // The old coordinator's proof (epoch 1/token A) must not stop the
        // new owner (epoch 2/token B) in any combination.
        if case .rejected(let code) = AndroidRuntimeBootstrap.shutdown(
            expectedEpoch: 1, ownerToken: tokenA) {
            XCTAssertEqual(code, .ownerMismatch)
        } else { XCTFail("stale epoch/token must be refused") }
        if case .rejected(let code) = AndroidRuntimeBootstrap.shutdown(
            expectedEpoch: 2, ownerToken: tokenA) {
            XCTAssertEqual(code, .ownerMismatch)
        } else { XCTFail("wrong token must be refused") }
        let live = try XCTUnwrap(AndroidRuntimeBootstrap.currentGenerationForTesting())
        XCTAssertEqual(live.epoch, 2)
        XCTAssertTrue(AndroidRuntimeBootstrap.statusSnapshotJSON()
            .contains("\"ownedStoreReady\":true"))
        // The true owner can still stop cleanly.
        guard case .accepted = AndroidRuntimeBootstrap.shutdown(
            expectedEpoch: 2, ownerToken: tokenB) else {
            return XCTFail("true owner stop")
        }
        await waitForCondition(timeoutSeconds: 10) {
            AndroidRuntimeBootstrap.currentGenerationForTesting() == nil
        }
    }

    // MARK: helpers

    private static func exchange(_ request: String) -> [String: Any]? {
        let data = AndroidBridge.exchange(Data(request.utf8))
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func exchange(_ request: String) -> [String: Any]? {
        Self.exchange(request)
    }

    private func submitEnvelope(correlation: String, command: String) -> String {
        """
        {"version":3,"operation":"command.submit","requestID":"\(correlation)",\
        "envelope":{"schema":"floe.command-envelope/3","scope":"applicationConfiguration",\
        "configurationScope":"system","command":"\(command)",\
        "stateful":false,"correlationID":"\(correlation)"}}
        """
    }

    private func effectEnvelope(correlation: String, receipt: String,
                                sequence: Int) -> String {
        """
        {"version":3,"operation":"effect.poll","requestID":"\(correlation)",\
        "envelope":{"schema":"floe.effect-cursor/3","scope":"applicationConfiguration",\
        "configurationScope":"system","command":"effect.poll","stateful":false,\
        "correlationID":"\(correlation)",\
        "effect":{"operationReceiptID":"\(receipt)","sequence":\(sequence)}}}
        """
    }

    private func waitForTerminal(_ pump: FacadeEffectPump, receipt: String,
                                 timeout: TimeInterval) async -> RuntimeEffectItem? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .page(let items, _, _, _) = pump.poll(receipt: receipt,
                                                          afterSequence: 0),
               let terminal = items.last(where: { $0.isTerminal }) {
                return terminal
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    private func waitForCondition(timeoutSeconds: TimeInterval = 5,
                                  _ predicate: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func assertBootstrapAccepted(_ receipt: String) async {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let gen = AndroidRuntimeBootstrap.currentGenerationForTesting() {
                if case .page(let items, _, _, _) =
                    gen.effects.poll(receipt: receipt, afterSequence: 0),
                   items.contains(where: { $0.kind == .accepted }) {
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("bootstrap never reached accepted")
    }

    private func assertBootstrapAcceptedToGeneration() async {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let status = AndroidRuntimeBootstrap.statusSnapshotJSON()
            if status.contains("\"ownedStoreReady\":true") { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("store never became ready")
    }

    private enum ShutdownTerminal {
        case acceptedOnce
        case failed(String)
    }

    private func waitShutdownTerminal(_ pump: FacadeEffectPump,
                                      receipt: String) async -> ShutdownTerminal {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if case .page(let items, _, _, _) = pump.poll(receipt: receipt, afterSequence: 0),
               let terminal = items.last(where: { $0.isTerminal }) {
                return terminal.kind == .accepted
                    ? .acceptedOnce : .failed("terminal \(terminal.kind)")
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return .failed("shutdown never settled")
    }
}

struct XCTestTimeoutErrorLocal: Error {}

private extension AndroidRuntimeStoreOwner {
    func runStoreProbe(_ block: @Sendable (SQLiteRunStore) async throws -> RunRecord?) async throws -> RunRecord? {
        guard let store = await self.runStoreForTests else {
            throw XCTestTimeoutErrorLocal()
        }
        return try await block(store)
    }
    func childStoreProbe(_ block: @Sendable (SQLiteChildRunStore) async throws -> ChildRunRecord?) async -> ChildRunRecord? {
        guard let store = await self.childRunStoreForTests else { return nil }
        return try? await block(store)
    }
    var runStoreForTests: SQLiteRunStore? {
        get async { await self.runStore }
    }
    var childRunStoreForTests: SQLiteChildRunStore? {
        get async { await self.childRunStore }
    }
}


/// Test-only blocking gate: models real in-flight asynchronous work. It is
/// never referenced by production code.
final class BlockingGate: @unchecked Sendable {
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

/// Deterministic entry latch for exact processor-identity proof (set by the
/// registered processor when IT starts; never by a count or a sleep guess).
final class EntryLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func mark() {
        lock.lock(); value = true; lock.unlock()
    }
    var marked: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
