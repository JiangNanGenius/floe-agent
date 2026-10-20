// SPDX-License-Identifier: MPL-2.0
//
// RB2-REPAIR (job-ffa06be4f2d34ac4) — MC-R4 physical-lifetime tests driven
// through the ACTUAL SecretRequestMailbox + MailboxSecretGateway +
// SecretGatewayRegistry (Main-authorized additive physical API of the
// candidate mirror, MAIN_GATEWAY_PHYSICAL_LIFETIME_API_GAP_20261019.json).
//
// The TEST plays the trusted HOST role exactly like the gateway lane's own
// mailbox suite does (bind/awaitClaim/complete through the public mailbox
// API; the clock via configureForTesting like SecretGatewayMailboxTests) —
// the production store effect behind complete() is the Kotlin Keystore, out
// of this package's scope; the mailbox-side facts under test are exactly the
// ones Main cited: CLAIMED watchdog caller-settle while execution remains
// outstanding; late REAL completion releasing the owned record EXACTLY ONCE;
// queued-cancel handshake provable never-dispatch; rebind/old-generation
// completion surviving logical retirement; pre-queue refusals structurally
// never dispatched; and the rule that the same caller error VALUE produces
// DIFFERENT dispositions driven by the individual record, never by a
// statsJSON/global-count/durable-intent inference. No fake synchronous
// write-then-throw: every claim/watchdog/completion ordering is real mailbox
// state. AUTHORED ONLY: NOT compiled, NOT executed by this source package.

import XCTest
import Foundation
import GRDB
@testable import FloeAndroidCore
import FloeCore
import FloePersistence

final class RuntimeFacadeConfigPhysicalTests: XCTestCase {

    private final class PhysicalClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 10_000
        var now: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ milliseconds: UInt64) { lock.lock(); value += milliseconds; lock.unlock() }
    }

    private var clock: PhysicalClock!
    private var databaseURL: URL!
    private var database: DatabaseManager!

    private let providerID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let routeToken = "route-physical"
    private let routeGeneration: UInt64 = 9
    private let syntheticSecret = Data("sk-physical-synthetic-0000000001".utf8)

    override func setUp() async throws {
        _ = floeSecretGatewayRemove()
        SecretGatewayRegistry.shared.unregister()
        SecretRequestMailbox.shared.resetForTesting()
        SecretSaveIntentVault.shared.resetForTesting()
        ProviderOperationCoordinatorRegistry.shared.removeAllForTesting()
        let testClock = PhysicalClock()
        clock = testClock
        SecretRequestMailbox.shared.configureForTesting(
            clock: { testClock.now },
            heartbeatStaleMillis: 60_000,
            watchdogStaleMillis: 30,
            watchdogTickMillis: 2,
            backendProgressWindowMillis: 10_000)
        XCTAssertEqual(floeSecretMailboxBind(1), 0)
        XCTAssertEqual(floeSecretGatewayInstall(), 0)
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-rb2-physical-\(UUID().uuidString).db")
        database = try DatabaseManager(path: databaseURL)
        try await database.migrate()
    }

    override func tearDown() async throws {
        _ = floeSecretGatewayRemove()
        SecretGatewayRegistry.shared.unregister()
        SecretRequestMailbox.shared.resetForTesting()
        SecretSaveIntentVault.shared.resetForTesting()
        ProviderOperationCoordinatorRegistry.shared.removeAllForTesting()
        try? await database.close()
        try? FileManager.default.removeItem(at: databaseURL)
    }

    // MARK: Host-role helpers

    /// Wait for a queued ticket and claim it AS THE HOST POLLER, returning
    /// the mailbox claim token (bounded real-clock polling; the injected
    /// business clock stays frozen so heartbeats/claims are deterministic).
    private func hostClaim(timeoutNanoseconds: UInt64 = 2_000_000_000) async -> Int64 {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let claim = SecretRequestMailbox.shared.awaitClaim(timeoutMillis: 0)
            if claim > 0 { return claim }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        _ = timeoutNanoseconds
        return 0
    }

    private func hostComplete(claim: Int64, status: Int32) -> Int32 {
        SecretRequestMailbox.shared.complete(claim: claim, status: status,
                                             value: nil, valueLen: 0)
    }

    private func queueDepth() -> Int {
        guard let data = SecretRequestMailbox.shared.statsJSON().data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let queue = object["queued"] as? Int else {
            return -1
        }
        return queue
    }

    // MARK: RB2 wiring (REAL gateway through the frozen registry)

    private func makeFacade(port: OwnedWorkRegistryPort = AlwaysAttachOwnedWorkPort())
        -> ModelConfigurationFacade
    {
        ModelConfigurationFacade(
            database: database,
            gateway: SecretGatewayRegistry.shared,
            catalogBytes: nil,
            transportAdmission: TransportAdmissionClosed(),
            routeContext: FixedRouteContext(token: routeToken, generation: routeGeneration),
            epochProvider: FixedEpochProvider(epoch: 1),
            ownedWorkRegistry: port)
    }

    private func candidateJSON(providerID: UUID? = nil) throws -> [String: Any] {
        let targetProviderID = providerID ?? self.providerID
        let capsData = try JSONEncoder().encode(ModelCapabilities.text)
        return [
            "id": targetProviderID.uuidString,
            "kind": ProviderKind.openAI.rawValue,
            "wireProtocol": ModelProtocol.openAIChatCompletions.rawValue,
            "baseURL": "https://api.example.invalid/v1",
            "displayName": "Physical Fixture",
            "syncEnabled": false,
            "selectedModels": [],
            "managedCapabilities": try JSONSerialization.jsonObject(
                with: capsData, options: [.fragmentsAllowed]),
            "serviceRoleIsConversation": true,
            "createIntent": true,
        ]
    }

    private func submitIntent(createIntent: Bool = true,
                              providerID: UUID? = nil) throws -> String {
        let targetProviderID = providerID ?? self.providerID
        var candidate = try candidateJSON(providerID: targetProviderID)
        candidate["createIntent"] = createIntent
        let intent: [String: Any] = [
            "subject": ["kind": SubjectKind.providerSave.rawValue, "id": targetProviderID.uuidString],
            "route": ["token": routeToken, "generation": routeGeneration],
            "intent": "set",
            "candidate": candidate,
        ]
        let data = try JSONSerialization.data(withJSONObject: intent, options: [.sortedKeys])
        var json = data
        json.append(0)
        var tokenBuffer = [CChar](repeating: 0, count: 64)
        var status: Int32 = -1
        json.withUnsafeBytes { jsonRaw in
            syntheticSecret.withUnsafeBytes { secretRaw in
                tokenBuffer.withUnsafeMutableBufferPointer { buffer in
                    status = floeSecretSaveIntentSubmit(
                        jsonRaw.bindMemory(to: CChar.self).baseAddress,
                        secretRaw.bindMemory(to: UInt8.self).baseAddress,
                        Int32(syntheticSecret.count), buffer.baseAddress, 40)
                }
            }
        }
        XCTAssertEqual(status, 0)
        return String(cString: tokenBuffer)
    }

    private func cleanup() -> ProviderSecretCleanup { ProviderSecretCleanup(database: database) }

    private final class PhysicalSnapshotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: PhysicalOperationSnapshot?
        var current: PhysicalOperationSnapshot? { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ snapshot: PhysicalOperationSnapshot) { lock.lock(); value = snapshot; lock.unlock() }
    }

    private static func referenceOf(account: String) -> String {
        SecretGatewayNaming.opaqueReference(namespace: "keychainAccount", account: account)
    }

    // MARK: - 1. CLAIMED watchdog vs late real completion (exactly-once)

    func testRealMailboxClaimedWatchdogParksOwnerAndLateCompletionReleasesExactlyOnce() async throws {
        let port = CountingOwnedWorkPort()
        let facade = makeFacade(port: port)
        let token = try submitIntent()
        let save = Task {
            await facade.saveProviderSet(ingressToken: token, envelopeRevision: nil)
        }
        let claim = await hostClaim()
        XCTAssertGreaterThan(claim, 0, "the create write reached the mailbox queue")
        // Caller still waits; NOW the poller goes silent and the heartbeat
        // ages past the watchdog window: the REAL watchdog resumes the caller
        // with dispatcherUnresponsive while state is
        // callerSettledExecutionOutstanding (permit + execution remain).
        clock.advance(100)
        let execution = await save.value
        guard case .failed(let failed) = execution, failed.pendingReconciliation else {
            return XCTFail("CLAIMED watchdog must park the owner: \(execution.failedDescriptionForTests)")
        }
        if case .outcomeUnknown? = failed.secretDisposition {
            // conservative unknown carried from the CLAIMED settle
        } else {
            XCTFail("expected outcomeUnknown disposition, got \(String(describing: failed.secretDisposition))")
        }
        XCTAssertEqual(failed.physicalSettlement, .executionOutstanding,
                       "MC-R4: the caller was resumed; the physical lifetime is NOT")
        // Gate + registry lease retained until the REAL completion.
        let coordinator = ProviderOperationCoordinatorRegistry.shared.coordinator(for: database)
        let pending = await coordinator.pendingRecord(providerID: providerID)
        XCTAssertNotNil(pending)
        // Main PRV-LIFETIME-2 correction (2026-10-19): the retained owner
        // must carry the EXPLICIT association — provider operation identity
        // ↔ the INDIVIDUAL mailbox claim ↔ epoch ↔ deterministic reference —
        // not merely protocol presence, durable intent or reference equality.
        // The later privacy (PrivacyProviderOperationOwning/PrivacySecret-
        // DeletionOrdering) and MCP/vault adapters consume this SAME
        // quadruple; this lane ships the generic API without editing them.
        if let pending {
            XCTAssertEqual(pending.ticket.providerID, providerID)
            XCTAssertEqual(pending.receipt?.claim, claim,
                           "the held claim IS the associated physical ticket")
            XCTAssertEqual(pending.receipt?.epoch, 1)
            XCTAssertEqual(pending.receipt?.reference,
                           Self.referenceOf(account: ConfigSecretIdentity.providerAccount(providerID: providerID)))
            XCTAssertEqual(pending.receipt?.kind, .write)
            // An OUTSTANDING record refuses resolution: the owner cannot
            // destroy its own settlement signal (mailbox resolve rule).
            XCTAssertFalse(MailboxSecretGateway.shared.resolvePhysical(claim: claim))
            let blockedAgain = await facade.reconcileProviderRecovery(providerID: providerID)
            XCTAssertEqual(blockedAgain, .stillPending(reason: "physicalOutstanding"))
        }
        XCTAssertEqual(port.counts().detached, 0, "no detach while outstanding")
        XCTAssertEqual(port.liveTokens().count, 1)
        // New intents are refused while pending (newer/drain blocked).
        var blockedCandidate = try candidateJSON()
        blockedCandidate["createIntent"] = false
        let blocked = await facade.saveProviderKeep(
            candidateJSON: try JSONSerialization.data(withJSONObject: blockedCandidate,
                                                      options: [.sortedKeys]),
            envelopeRevision: nil)
        guard case .failed(let blockedFailed) = blocked,
              blockedFailed.error.reason == "providerPendingReconciliation" else {
            return XCTFail("pending owner must refuse new operations")
        }
        // Reconcile before completion: honest still-pending (never a
        // re-read/timeout settlement).
        let early = await facade.reconcileProviderRecovery(providerID: providerID)
        XCTAssertEqual(early, .stillPending(reason: "physicalOutstanding"))
        // THE real host completion for THAT claim arrives late.
        XCTAssertEqual(hostComplete(claim: claim, status: 3), -103,
                       "caller-settled claims resolve with -103 exactly once")
        let release = await facade.reconcileProviderRecovery(providerID: providerID)
        guard case .settledNow(let reason) = release else {
            return XCTFail("settled truth must release: \(release)")
        }
        XCTAssertTrue(reason.hasPrefix("executionSettled.3"), reason)
        let gone = await coordinator.pendingRecord(providerID: providerID)
        XCTAssertNil(gone)
        XCTAssertEqual(port.counts().detached, 1, "released exactly once")
        // After consumption the terminal record is resolvable and gone; a
        // second completion for the same claim cannot re-signal.
        XCTAssertTrue(MailboxSecretGateway.shared.resolvePhysical(claim: claim))
        XCTAssertEqual(port.liveTokens().count, 0)
        // A duplicate late completion cannot re-settle (mailbox -100/record
        // already resolved): reconcile is a no-op now.
        let again = await facade.reconcileProviderRecovery(providerID: providerID)
        XCTAssertEqual(again, .nothingPending)
        // The durable create intent survived and now drains: row absent ⇒
        // bounded orphan delete driven by a NEW real claim/completion.
        let entries = try await cleanup().entries()
        XCTAssertEqual(entries.map(\.intent), [.secretWrite])
        let drain = Task { try await facade.drainProviderCleanup() }
        let deleteClaim = await hostClaim()
        XCTAssertGreaterThan(deleteClaim, 0)
        XCTAssertEqual(hostComplete(claim: deleteClaim, status: 4), 0)
        let drained = try await drain.value
        XCTAssertEqual(drained.outcomes[providerID], .secretRemoved)
        XCTAssertEqual(drained.entriesRemaining, 0)
    }

    // MARK: - 1b. Actual-settlement subscription (Main generic API)

    /// The awaited settlement subscription returns ONLY terminal individual
    /// truth: logical caller settlement (watchdog) does NOT wake it; the real
    /// host completion does; a consumed record reads `.notRecorded`.
    func testPhysicalSettlementSubscriptionReturnsOnlyTerminalTruth() async throws {
        let facade = makeFacade()
        let token = try submitIntent()
        let save = Task { await facade.saveProviderSet(ingressToken: token, envelopeRevision: nil) }
        let claim = await hostClaim()
        XCTAssertGreaterThan(claim, 0)
        let box = PhysicalSnapshotBox()
        let subscription = Task { () -> PhysicalOperationSnapshot in
            let value = await MailboxSecretGateway.shared.awaitPhysicalSettlement(claim: claim)
            box.set(value)
            return value
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertNil(box.current, "no terminal truth yet ⇒ the subscription must not return")
        // Watchdog settles the CALLER; the physical record stays outstanding.
        clock.advance(100)
        _ = await save.value
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertNil(box.current,
                     "caller settlement is NOT physical settlement (MC-R4)")
        let earlySnapshot = MailboxSecretGateway.shared.physicalSnapshot(claim: claim)
        XCTAssertEqual(earlySnapshot, .claimedOutstanding)
        // The REAL host completion arrives late: the subscription wakes with
        // the exact terminal status.
        XCTAssertEqual(hostComplete(claim: claim, status: 3), -103)
        let settled = await subscription.value
        XCTAssertEqual(settled, .settled(status: 3))
        XCTAssertEqual(box.current, .settled(status: 3))
        // Consumed terminal record ⇒ honest `.notRecorded` (non-evidence),
        // and a second completion cannot re-signal.
        XCTAssertTrue(MailboxSecretGateway.shared.resolvePhysical(claim: claim))
        let after = await MailboxSecretGateway.shared.awaitPhysicalSettlement(claim: claim)
        XCTAssertEqual(after, .notRecorded)
        XCTAssertEqual(hostComplete(claim: claim, status: 3), -101,
                       "same-epoch retired duplicate is -101, not a re-settle")
    }

    // MARK: - 1c. Immediate-terminal registration racing cancellation

    /// Main repair (job-059dc09dd7bd48f1): the immediate terminal (`settled`/
    /// `neverDispatched`) and `notRecorded` branches of
    /// `awaitPhysicalSettlement` must perform their subscription state
    /// transition UNDER the SAME lock that guards the cancellation handshake;
    /// only the continuation resume leaves the lock. A cancellation racing
    /// registration must never observe a stale `.pending` state and must
    /// never produce a second resume (which would trap the test process).
    /// The record is made terminal BEFORE the subscription starts, so the
    /// only nondeterminism is which side wins the lock — both orders must
    /// deliver exactly one honest snapshot.
    func testImmediateTerminalSettlementRegistrationRacingCancellationIsExactlyOnce() async throws {
        let account = "physical.immediate.\(UUID().uuidString)"
        let reference = Self.referenceOf(account: account)
        let capture = ReceiptCapture()
        let write = Task {
            try await MailboxSecretGateway.shared.writeObserved(
                reference: reference, value: Data("v".utf8)) { receipt in
                capture.set(receipt)
            }
        }
        let claim = await hostClaim()
        XCTAssertGreaterThan(claim, 0)
        XCTAssertEqual(hostComplete(claim: claim, status: 3), 0)
        try await write.value
        XCTAssertEqual(MailboxSecretGateway.shared.physicalSnapshot(claim: claim),
                       .settled(status: 3))

        // (a) Deterministic immediate terminal branch.
        let immediate = await MailboxSecretGateway.shared.awaitPhysicalSettlement(claim: claim)
        XCTAssertEqual(immediate, .settled(status: 3))

        // (b) Pre-cancelled task: cancellation wins the handshake before the
        // body runs; the body must still return the exact terminal snapshot.
        let preCancelled = Task { () -> PhysicalOperationSnapshot in
            await MailboxSecretGateway.shared.awaitPhysicalSettlement(claim: claim)
        }
        preCancelled.cancel()
        let preCancelledValue = await preCancelled.value
        XCTAssertEqual(preCancelledValue, .settled(status: 3))

        // (c) Controlled race: a sibling task cancels while the awaiting task
        // enters the registration critical section. Iterations exercise both
        // lock orders (terminal branch setting `.resumed` vs cancellation
        // setting `.cancelled`). Any state mutation outside the lock would
        // allow a lost or duplicated continuation resume.
        for iteration in 0..<128 {
            let awaiting = Task { () -> PhysicalOperationSnapshot in
                await MailboxSecretGateway.shared.awaitPhysicalSettlement(claim: claim)
            }
            let canceller = Task {
                await Task.yield()
                awaiting.cancel()
            }
            let value = await awaiting.value
            _ = await canceller.value
            XCTAssertEqual(value, .settled(status: 3), "iteration \(iteration)")
        }

        // Consumer acknowledgement ⇒ the same immediate branch now yields
        // `.notRecorded`; race it against cancellation as well.
        XCTAssertTrue(MailboxSecretGateway.shared.resolvePhysical(claim: claim))
        for iteration in 0..<64 {
            let awaiting = Task { () -> PhysicalOperationSnapshot in
                await MailboxSecretGateway.shared.awaitPhysicalSettlement(claim: claim)
            }
            if iteration % 2 == 0 { awaiting.cancel() }
            let value = await awaiting.value
            XCTAssertEqual(value, .notRecorded, "iteration \(iteration)")
        }
        XCTAssertEqual(hostComplete(claim: claim, status: 3), -101,
                       "same-epoch retired duplicate is -101, not a re-settle")
        XCTAssertEqual(MailboxSecretGateway.shared.physicalSnapshot(claim: claim),
                       .notRecorded)
    }

    // MARK: - 1d. Registry replacement is resolved per attempt

    /// Main requirement (2026-10-19): observation support must be resolved
    /// PER ATTEMPT, never from a mutable registry capability bit. After a
    /// non-observing gateway replaces the observing one, a nil receipt must
    /// classify as honest `.unobserved` with owner retention — never as
    /// `physicalNeverQueued`/`.neverExecuted` ("no dispatch" false proof).
    func testNonObservingRegistryReplacementNeverTurnsNilReceiptIntoNeverDispatched() async throws {
        XCTAssertTrue(SecretGatewayRegistry.shared.supportsPhysicalObservation,
                      "the real mailbox gateway is observing before replacement")
        let replacement = NonObservingFailingGateway(
            error: SecretBackendError.dispatcherUnresponsive)
        SecretGatewayRegistry.shared.register(replacement)
        XCTAssertFalse(SecretGatewayRegistry.shared.supportsPhysicalObservation)

        let facade = makeFacade()   // binds SecretGatewayRegistry.shared
        let token = try submitIntent()
        let execution = await facade.saveProviderSet(ingressToken: token,
                                                     envelopeRevision: nil)
        guard case .failed(let failed) = execution else {
            return XCTFail("ambiguous non-observing failure must fail typed")
        }
        XCTAssertEqual(failed.secretDisposition,
                       .outcomeUnknown(reason: "dispatcherUnresponsiveClaimed"))
        XCTAssertEqual(failed.physicalSettlement, .unobserved,
                       "nil receipt from a non-observing replacement proves NOTHING")
        XCTAssertNil(failed.physicalReceipt)
        XCTAssertTrue(failed.pendingReconciliation,
                      "an unobserved ambiguous outcome retains the owner")
        let entries = try await cleanup().entries()
        XCTAssertEqual(entries.map(\.intent), [.secretWrite],
                       "unknown effect keeps the durable intent (never faked absent)")
        let coordinator = ProviderOperationCoordinatorRegistry.shared.coordinator(for: database)
        let pending = await coordinator.pendingRecord(providerID: providerID)
        XCTAssertNotNil(pending, "the exact ticket/lease/receipt are retained")
        XCTAssertNil(pending?.witness,
                     "an UNOBSERVED attempt has no witness (honest non-evidence)")
        // Restore the real observing gateway; per-attempt resolution must
        // recover observation for the next attempt.
        XCTAssertEqual(floeSecretGatewayInstall(), 0)
        XCTAssertTrue(SecretGatewayRegistry.shared.supportsPhysicalObservation)
    }

    // MARK: - 1e. Pending owner settles through the ORIGINAL observer after
    // registry replacement (MC-OBSERVER-PENDING-OWNER)

    /// Main requirement (2026-10-19): a pending owner parked with an
    /// outstanding physical lifetime must reconcile through the EXACT
    /// observer captured at its attempt — a LATER non-observing registry
    /// replacement can neither observe nor acknowledge the original
    /// operation. The real completion still settles the owner exactly once,
    /// without the registry being re-installed or re-pointed back.
    func testPendingOwnerSettlesThroughOriginalWitnessAfterRegistryReplacement() async throws {
        let port = CountingOwnedWorkPort()
        let facade = makeFacade(port: port)
        let token = try submitIntent()
        let save = Task { await facade.saveProviderSet(ingressToken: token,
                                                       envelopeRevision: nil) }
        let claim = await hostClaim()
        XCTAssertGreaterThan(claim, 0)
        // Watchdog settles the CALLER while the execution stays outstanding:
        // the owner is parked with ticket + lease + receipt + witness.
        clock.advance(100)
        let execution = await save.value
        guard case .failed(let failed) = execution, failed.pendingReconciliation else {
            return XCTFail("outstanding physical lifetime must park the owner")
        }
        // The pending record captured the ORIGINAL observing mailbox object.
        let coordinator = ProviderOperationCoordinatorRegistry.shared.coordinator(for: database)
        let pendingOpt = try await coordinator.pendingRecord(providerID: providerID)
        let pending = try XCTUnwrap(pendingOpt)
        let witness = try XCTUnwrap(pending.witness as? MailboxSecretGateway)
        XCTAssertTrue(witness === MailboxSecretGateway.shared)
        // Replace the registry with a DIFFERENT, non-observing gateway: it
        // can never observe/ACK the original operation, and the pending
        // owner must not be drained through it.
        let replacement = NonObservingFailingGateway(error: SecretBackendError.storageFailure)
        SecretGatewayRegistry.shared.register(replacement)
        XCTAssertFalse(SecretGatewayRegistry.shared.supportsPhysicalObservation)
        // Before the real completion the owner stays pending — through the
        // witness, independent of the replacement.
        let early = await facade.reconcileProviderRecovery(providerID: providerID)
        XCTAssertEqual(early, .stillPending(reason: "physicalOutstanding"))
        // The late REAL completion on the original mailbox settles the
        // physical record; a NEW facade over the SAME database reconciles
        // via the retained witness and detaches the lease exactly once.
        XCTAssertEqual(hostComplete(claim: claim, status: 3), -103)
        let recreated = makeFacade(port: port)
        let release = await recreated.reconcileProviderRecovery(providerID: providerID)
        guard case .settledNow(let reason) = release else {
            return XCTFail("late completion must settle via the captured witness: \(release)")
        }
        XCTAssertTrue(reason.hasPrefix("executionSettled.3"), reason)
        XCTAssertEqual(port.counts().attached, 1)
        XCTAssertEqual(port.counts().detached, 1)
        // The terminal record was acknowledged through the ORIGINAL observer.
        XCTAssertEqual(MailboxSecretGateway.shared.physicalSnapshot(claim: claim),
                       .notRecorded)
        // Restore the real observing gateway for later tests.
        XCTAssertEqual(floeSecretGatewayInstall(), 0)
        XCTAssertTrue(SecretGatewayRegistry.shared.supportsPhysicalObservation)
    }

    // MARK: - 1f. Witness lifetime + missing-witness refusal

    /// Main requirement (2026-10-19): the transient per-provider witness slot
    /// is cleared by terminal flows (repeated completed distinct-provider
    /// operations do not retain old observer objects), while a parked pending
    /// record keeps the EXACT observer until real settlement and then
    /// releases it. A fresh delegating spy per flow makes the lifetimes
    /// observable through weak references.
    func testTransientWitnessReleasedOnTerminalFlowsAndRetainedOnlyByPending() async throws {
        // Two COMPLETED distinct-provider flows, each through a fresh spy.
        for index in 0..<2 {
            let pid = UUID(uuidString: String(format: "aaaaaaaa-0000-0000-0000-%012d", index))!
            var spy: WitnessSpy? = WitnessSpy()
            weak var weakSpy = spy
            SecretGatewayRegistry.shared.register(spy!)
            let facade = makeFacade()
            let token = try submitIntent(providerID: pid)
            let save = Task { await facade.saveProviderSet(ingressToken: token,
                                                           envelopeRevision: nil) }
            let claim = await hostClaim()
            XCTAssertGreaterThan(claim, 0)
            XCTAssertEqual(hostComplete(claim: claim, status: 3), 0)
            let execution = await save.value
            guard case .committed = execution else {
                return XCTFail("flow \(index) must commit: \(execution.failedDescriptionForTests)")
            }
            SecretGatewayRegistry.shared.unregister()
            spy = nil
            let deadline = Date().addingTimeInterval(2.0)
            while weakSpy != nil && Date() < deadline {
                await Task.yield()
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertNil(weakSpy,
                         "a completed distinct-provider flow must not retain its observer")
        }

        // One PENDING flow: the witness must survive registration removal and
        // be released exactly when the physical truth settles.
        let pendingProvider = UUID(uuidString: "bbbbbbbb-0000-0000-0000-000000000001")!
        var pendingSpy: WitnessSpy? = WitnessSpy()
        weak var weakPending = pendingSpy
        SecretGatewayRegistry.shared.register(pendingSpy!)
        let facade = makeFacade()
        let token = try submitIntent(providerID: pendingProvider)
        let save = Task { await facade.saveProviderSet(ingressToken: token,
                                                       envelopeRevision: nil) }
        let claim = await hostClaim()
        XCTAssertGreaterThan(claim, 0)
        clock.advance(100) // watchdog settles the caller; execution stays out
        let execution = await save.value
        guard case .failed(let failed) = execution, failed.pendingReconciliation else {
            return XCTFail("outstanding physical lifetime must park the owner")
        }
        SecretGatewayRegistry.shared.unregister()
        pendingSpy = nil
        XCTAssertNotNil(weakPending,
                        "the pending record must retain its exact original witness")
        // The real completion settles through that witness; the record is
        // removed and the observer released.
        XCTAssertEqual(hostComplete(claim: claim, status: 3), -103)
        let recreated = makeFacade()
        let release = await recreated.reconcileProviderRecovery(providerID: pendingProvider)
        guard case .settledNow = release else {
            return XCTFail("late completion must settle via the retained witness: \(release)")
        }
        let deadline = Date().addingTimeInterval(2.0)
        while weakPending != nil && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNil(weakPending,
                     "settled pending owner must release its witness")
    }

    /// Main requirement (2026-10-19): a receipt whose ORIGINAL witness is
    /// missing stays unobserved. It must never inspect or ACK the CURRENT
    /// registry, even when a replacement gateway answers for a colliding
    /// claim token; the lease is not released.
    func testMissingWitnessPendingRecordNeverInspectsReplacementGateway() async throws {
        let port = CountingOwnedWorkPort()
        let facade = makeFacade(port: port)
        let coordinator = ProviderOperationCoordinatorRegistry.shared.coordinator(for: database)
        guard case .attached(let ticket) = await coordinator.beginOperation(
            providerID: providerID, kind: .save) else {
            return XCTFail("the artificial pending reservation must attach")
        }
        let receipt = PhysicalOperationReceipt(
            claim: 424_242, epoch: 1,
            reference: Self.referenceOf(account: "collision.\(providerID.uuidString)"),
            kind: .write, tracked: true)
        let lifecycle = ConfigOwnedWorkLifecycle(registry: port,
                                                 epochProvider: FixedEpochProvider(epoch: 1))
        guard case .success(let lease) = lifecycle.begin(kind: .vaultMaintenance,
                                                         ownerID: providerID.uuidString) else {
            return XCTFail("owned-work lease must attach")
        }
        let parked = await coordinator.parkPending(ticket, intent: .secretWrite,
                                                   receipt: receipt, lease: lease,
                                                   witness: nil)
        XCTAssertTrue(parked)
        // A replacement that WOULD answer for claim 424242 if consulted.
        let replacement = CollisionObservingGateway()
        SecretGatewayRegistry.shared.register(replacement)
        let outcome = await facade.reconcileProviderRecovery(providerID: providerID)
        XCTAssertEqual(outcome, .stillPending(reason: "physicalOutstanding"))
        XCTAssertEqual(replacement.snapshotCalls, 0,
                       "missing witness must never query the replacement gateway")
        XCTAssertEqual(replacement.resolveCalls, 0,
                       "missing witness must never ACK through the replacement gateway")
        XCTAssertEqual(port.counts().detached, 0,
                       "the lease is retained (no settlement proof)")
        // Cleanup the artificial record without any gateway effect.
        let settled = await coordinator.settlePending(providerID: providerID, ticket: ticket)
        XCTAssertTrue(settled)
        lifecycle.settle(lease)
        SecretGatewayRegistry.shared.unregister()
    }

    // MARK: - 2. Queued cancel is provably never dispatched

    func testRealMailboxQueuedCancelProvesNeverDispatchedAndReleases() async throws {
        let port = CountingOwnedWorkPort()
        let facade = makeFacade(port: port)
        let token = try submitIntent()
        let save = Task {
            await facade.saveProviderSet(ingressToken: token, envelopeRevision: nil)
        }
        // Wait until the ticket is actually QUEUED (never claimed), then the
        // caller cancels: the atomic cancel handshake removes it.
        var queued = false
        for _ in 0..<400 {
            if queueDepth() >= 1 { queued = true; break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(queued, "the write ticket must have been queued")
        save.cancel()
        let execution = await save.value
        guard case .failed(let failed) = execution else {
            return XCTFail("cancelled write must fail typed: \(execution.failedDescriptionForTests)")
        }
        XCTAssertFalse(failed.pendingReconciliation,
                       "queued-cancel is structurally never dispatched ⇒ honest release")
        if case .neverExecuted(let reason)? = failed.physicalSettlement,
           reason == "cancelledBeforeClaim" {
            // exact individual truth
        } else {
            XCTFail("expected neverExecuted.cancelledBeforeClaim, got \(String(describing: failed.physicalSettlement))")
        }
        if case .effectAbsent(let reason)? = failed.secretDisposition {
            XCTAssertTrue(reason.hasPrefix("physicalNeverDispatched"), reason)
        } else {
            XCTFail("expected effectAbsent with never-dispatch proof")
        }
        let coordinator = ProviderOperationCoordinatorRegistry.shared.coordinator(for: database)
        let pending = await coordinator.pendingRecord(providerID: providerID)
        XCTAssertNil(pending)
        XCTAssertEqual(port.counts().attached, port.counts().detached,
                       "settled with zero outstanding")
        // MC-R3 honesty: no-effect from THIS attempt still does not fake
        // absence — the create intent entry remains for the drain.
        let entries = try await cleanup().entries()
        XCTAssertEqual(entries.map(\.intent), [.secretWrite])
    }

    // MARK: - 3. Pre-queue saturation is structurally never dispatched

    func testRealMailboxPreQueueSaturationIsProvableC0WithOwnerReleased() async throws {
        // Fill the queue WITHOUT any claim (the poller never runs), so the
        // mailbox itself refuses further publishes at the queue bound.
        let queueFullTasks = (0..<SecretGatewayLimits.maximumQueue).map { index in
            Task {
                try? await MailboxSecretGateway.shared.write(
                    reference: SecretGatewayNaming.opaqueReference(namespace: "keychainAccount",
                                                                   account: "provider.fill-\(index)"),
                    value: Data("x".utf8))
            }
        }
        var filled = false
        for _ in 0..<800 {
            if queueDepth() >= SecretGatewayLimits.maximumQueue { filled = true; break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(filled, "queue must reach the frozen bound")
        // RB2 delete on top of the saturated mailbox: refused BEFORE queue
        // ⇒ never dispatched, provable; the entry stays per MC-R3.
        try await ModelConfigurationStore(database: database).saveProvider(ProviderProfile(
            id: providerID, kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.example.invalid/v1")!,
            displayName: "Saturation fixture",
            secretRef: SecretReference(keychainAccount: ConfigSecretIdentity.providerAccount(providerID: providerID),
                                       synchronizable: false)))
        let facade = makeFacade()
        let result = try await facade.deleteProvider(
            revision: ConfigRevision.provider(id: providerID, syncRevision: 0))
        switch result.secretCleanup {
        case .queuedForRetry(let reason):
            XCTAssertTrue(reason.hasPrefix("attemptRejected."), reason)
        case .provablyAbsent, .removed:
            return XCTFail("saturation must not claim removal/absence: \(result.secretCleanup)")
        default:
            XCTFail("expected queuedForRetry, got \(result.secretCleanup)")
        }
        let row = try await ModelConfigurationStore(database: database).provider(id: providerID)
        XCTAssertNil(row, "the SQLite side of the delete DID happen (row gone, secret unknown)")
        let entries = try await cleanup().entries()
        XCTAssertEqual(entries.map(\.intent), [.providerDelete], "durable intent retained")
        let coordinator = ProviderOperationCoordinatorRegistry.shared.coordinator(for: database)
        let pending = await coordinator.pendingRecord(providerID: providerID)
        XCTAssertNil(pending, "pre-queue refusal releases the owner (never dispatched)")
        for task in queueFullTasks { task.cancel() }
    }

    // MARK: - 4. Rebind retires the ticket; the physical record survives

    func testRealMailboxRebindRetiresTicketButOldCompletionStillReleasesOwner() async throws {
        let port = CountingOwnedWorkPort()
        let facade = makeFacade(port: port)
        let token = try submitIntent()
        let save = Task { await facade.saveProviderSet(ingressToken: token, envelopeRevision: nil) }
        let claim = await hostClaim()
        XCTAssertGreaterThan(claim, 0)
        // Rebind (trusted host replacement): the CLAIMED caller is resumed
        // with dispatcherReplaced; the logical ticket is retired — the
        // Main-cited defect condition: retirement is NOT settlement.
        XCTAssertEqual(SecretRequestMailbox.shared.bind(epoch: 2), 0)
        let execution = await save.value
        guard case .failed(let failed) = execution, failed.pendingReconciliation,
              failed.physicalSettlement == .executionOutstanding else {
            return XCTFail("rebind-settled CLAIMED operation must park: \(execution.failedDescriptionForTests)")
        }
        let early = await facade.reconcileProviderRecovery(providerID: providerID)
        XCTAssertEqual(early, .stillPending(reason: "physicalOutstanding"),
                       "logical retirement must not manufacture physical absence")
        // The old generation's REAL completion arrives afterwards.
        XCTAssertEqual(hostComplete(claim: claim, status: 3), -102)
        let release = await facade.reconcileProviderRecovery(providerID: providerID)
        if case .settledNow(let reason) = release {
            XCTAssertTrue(reason.hasPrefix("executionSettled.3"), reason)
        } else {
            XCTFail("old-generation completion must release the owned record: \(release)")
        }
        XCTAssertEqual(port.counts().detached, 1)
        // New-generation work proceeds through a FRESH host bootstrap:
        // remove() destroys the mailbox, so bind again before install.
        XCTAssertEqual(floeSecretGatewayRemove(), 0)
        XCTAssertEqual(floeSecretMailboxBind(3), 0)
        XCTAssertEqual(floeSecretGatewayInstall(), 0)
    }

    // MARK: - 5. Abandoned status: settled execution, unknown effect

    func testRealMailboxAbandonedCompletionReleasesOwnerButKeepsEntry() async throws {
        let facade = makeFacade()
        let token = try submitIntent()
        let save = Task { await facade.saveProviderSet(ingressToken: token, envelopeRevision: nil) }
        let claim = await hostClaim()
        XCTAssertGreaterThan(claim, 0)
        clock.advance(100)
        let execution = await save.value
        guard case .failed(let failed) = execution, failed.pendingReconciliation else {
            return XCTFail("claimed watchdog settles the caller; owner parked")
        }
        // Host completion arrives with -14 (abandoned): EXECUTION settled,
        // EFFECT truth unknown. Caller outcome and physical settlement are
        // separate axes (Main requiredSemantics).
        XCTAssertEqual(hostComplete(claim: claim, status: -14), -103)
        let release = await facade.reconcileProviderRecovery(providerID: providerID)
        if case .settledNow(let reason) = release {
            XCTAssertTrue(reason.hasPrefix("executionSettled.-14"), reason)
        } else {
            XCTFail("settled abandonment still releases the OWNER gate: \(release)")
        }
        let entries = try await cleanup().entries()
        XCTAssertEqual(entries.map(\.intent), [.secretWrite],
                       "unknown EFFECT keeps the durable intent (never faked absent)")
    }

    // MARK: - 6. Two-facade shared coordination over the real mailbox path

    func testTwoPhysicalFacadesShareOneContextGateAndOneRejects() async throws {
        let facadeA = makeFacade()
        let facadeB = makeFacade()
        let tokenA = try submitIntent()
        let saveA = Task {
            await facadeA.saveProviderSet(ingressToken: tokenA, envelopeRevision: nil)
        }
        let claim = await hostClaim()
        XCTAssertGreaterThan(claim, 0)
        let tokenB = try submitIntent()
        let executionB = await facadeB.saveProviderSet(ingressToken: tokenB, envelopeRevision: nil)
        guard case .failed(let failedB) = executionB,
              failedB.error.code == .duplicateInFlight else {
            _ = await saveA.value
            return XCTFail("the second facade must coordinate-reject while A is in flight")
        }
        // A converges normally (host completion for the real claim).
        XCTAssertEqual(hostComplete(claim: claim, status: 3), 0)
        let executionA = await saveA.value
        guard case .committed = executionA else {
            return XCTFail("A must commit on real completion: \(executionA.failedDescriptionForTests)")
        }
        // B may now proceed (gate released at true settlement). C is an
        // EDIT of A's committed row, so its frozen draft must not request
        // another create (createIntent=true would be a typed createConflict).
        let tokenC = try submitIntent(createIntent: false)
        let saveC = Task {
            await facadeB.saveProviderSet(ingressToken: tokenC, envelopeRevision: nil)
        }
        let claimC = await hostClaim()
        XCTAssertGreaterThan(claimC, 0)
        XCTAssertEqual(hostComplete(claim: claimC, status: 3), 0)
        let executionC = await saveC.value
        guard case .committed(let committedC) = executionC else {
            return XCTFail("B must proceed after A settled: \(executionC.failedDescriptionForTests)")
        }
        XCTAssertEqual(committedC.providerRevision.version, "2",
                       "the second successful write advances again")
    }

    /// A distinct per-flow observing object that DELEGATES to the real
    /// mailbox gateway. Used to observe the witness lifetime with weak
    /// references (the mailbox singleton itself never deallocates).
    private final class WitnessSpy: AndroidSecretGateway,
                                    SecretGatewayServicing,
                                    PhysicalObservingSecretGateway,
                                    @unchecked Sendable {
        private let base = MailboxSecretGateway.shared
        var isRegistered: Bool { true } // the mailbox is bound in this suite
        func read(reference: String) async throws -> Data? {
            try await base.read(reference: reference)
        }
        func write(reference: String, value: Data) async throws {
            try await base.write(reference: reference, value: value)
        }
        func delete(reference: String) async throws {
            try await base.delete(reference: reference)
        }
        func readObserved(reference: String,
                          onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?)
            async throws -> Data? {
            try await base.readObserved(reference: reference, onQueued: onQueued)
        }
        func writeObserved(reference: String, value: Data,
                           onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?)
            async throws {
            try await base.writeObserved(reference: reference, value: value,
                                         onQueued: onQueued)
        }
        func deleteObserved(reference: String,
                            onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?)
            async throws {
            try await base.deleteObserved(reference: reference, onQueued: onQueued)
        }
        func physicalSnapshot(claim: Int64) -> PhysicalOperationSnapshot {
            base.physicalSnapshot(claim: claim)
        }
        func resolvePhysical(claim: Int64) -> Bool {
            base.resolvePhysical(claim: claim)
        }
        func awaitPhysicalSettlement(claim: Int64) async -> PhysicalOperationSnapshot {
            await base.awaitPhysicalSettlement(claim: claim)
        }
    }

    /// An OBSERVING replacement that would answer for a colliding claim if a
    /// pending record ever consulted the current registry. Counters prove it
    /// is never touched when the original witness is missing.
    private final class CollisionObservingGateway: AndroidSecretGateway,
                                                   SecretGatewayServicing,
                                                   PhysicalObservingSecretGateway,
                                                   @unchecked Sendable {
        private let lock = NSLock()
        private var snapshots = 0
        private var resolves = 0
        var snapshotCalls: Int { lock.withLock { snapshots } }
        var resolveCalls: Int { lock.withLock { resolves } }
        var isRegistered: Bool { true }
        func read(reference: String) async throws -> Data? { nil }
        func write(reference: String, value: Data) async throws {}
        func delete(reference: String) async throws {}
        func readObserved(reference: String,
                          onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?)
            async throws -> Data? {
            nil
        }
        func writeObserved(reference: String, value: Data,
                           onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?)
            async throws {}
        func deleteObserved(reference: String,
                            onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?)
            async throws {}
        func physicalSnapshot(claim: Int64) -> PhysicalOperationSnapshot {
            lock.withLock { snapshots += 1 }
            return .settled(status: 3)
        }
        func resolvePhysical(claim: Int64) -> Bool {
            lock.withLock { resolves += 1 }
            return true
        }
        func awaitPhysicalSettlement(claim: Int64) async -> PhysicalOperationSnapshot {
            .settled(status: 3)
        }
    }

    /// A gateway that can be registered in the REAL shared registry but has
    /// NO physical-observation conformance: CRUD fails with a scripted
    /// ambiguous error. Used to prove per-attempt observation resolution.
    private final class NonObservingFailingGateway: AndroidSecretGateway,
                                                    SecretGatewayServicing,
                                                    @unchecked Sendable {
        private let error: Error
        init(error: Error) { self.error = error }
        var isRegistered: Bool { true }
        func read(reference: String) async throws -> Data? { throw error }
        func write(reference: String, value: Data) async throws { throw error }
        func delete(reference: String) async throws { throw error }
    }
}
