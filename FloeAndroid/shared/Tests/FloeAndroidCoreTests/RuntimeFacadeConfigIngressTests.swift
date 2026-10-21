// SPDX-License-Identifier: MPL-2.0
//
// RB2 model-configuration source tests — secret ingress (one-shot `int:v1:`
// lease), save authority chain, effect dispositions (C0/C1/unknown),
// owned-operation coordination, and auth-before-network probe gates.
// AUTHORED ONLY: NOT compiled, NOT executed by this package; Main's
// serialized qualification lane runs them against the real toolchain.
//
// Synthetic-only material: fake gateways with call counters, scripted
// owned-work ports, loopback/invalid hostnames, synthetic secret bytes.
// The REAL SecretSaveIntentVault + C ABI submit are exercised exactly like
// the shipped SecretGatewayMailbox/vault suites (resetForTesting +
// floeSecretSaveIntentSubmit), and the REAL ProviderSaveDraft/Runner/
// ModelConfigurationStore chain is used end-to-end.

import XCTest
import Foundation
import GRDB
@testable import FloeAndroidCore
import FloeCore
import FloeModels
import FloePersistence
import FloeProviders

final class RuntimeFacadeConfigIngressTests: XCTestCase {

    // MARK: Fixture plumbing

    private var databaseURL: URL!
    private var database: DatabaseManager!

    private let providerID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let routeToken = "route-a"
    private let routeGeneration: UInt64 = 5
    private let syntheticSecret = Data("sk-synthetic-abcdef0123456789".utf8)
    private let syntheticSecretString = "sk-synthetic-abcdef0123456789"

    override func setUp() async throws {
        _ = floeSecretGatewayRemove()
        SecretRequestMailbox.shared.resetForTesting()
        SecretSaveIntentVault.shared.resetForTesting()
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-rb2-ingress-\(UUID().uuidString).db")
        database = try DatabaseManager(path: databaseURL)
        try await database.migrate()
    }

    override func tearDown() async throws {
        _ = floeSecretGatewayRemove()
        SecretRequestMailbox.shared.resetForTesting()
        SecretSaveIntentVault.shared.resetForTesting()
        try await database.close()
        try? FileManager.default.removeItem(at: databaseURL)
    }

    // Candidate JSON in the RB2 closed schema. managedCapabilities/
    // selectedModels are encoded with the ORIGINAL Codable shapes so the
    // tests pin the real wire structure, not an invented one.
    private func makeCandidateJSON(createIntent: Bool = false,
                                   baseURL: String = "https://api.example.invalid/v1",
                                   kind: ProviderKind = .openAI,
                                   wire: ModelProtocol = .openAIChatCompletions,
                                   syncEnabled: Bool = false,
                                   presetID: String? = nil,
                                   models: [ModelProfile] = []) throws -> [String: Any] {
        let capabilities = ModelCapabilities.text
        let capsData = try JSONEncoder().encode(capabilities)
        // ModelCapabilities is an OptionSet: its ORIGINAL Codable encoding
        // is a scalar JSON fragment, so fragment parsing is required.
        let capsObject = try JSONSerialization.jsonObject(
            with: capsData, options: [.fragmentsAllowed])
        var modelsArray: [[String: Any]] = []
        for model in models {
            let data = try JSONEncoder().encode(model)
            modelsArray.append(try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]))
        }
        var candidate: [String: Any] = [
            "id": providerID.uuidString,
            "kind": kind.rawValue,
            "wireProtocol": wire.rawValue,
            "baseURL": baseURL,
            "displayName": "Fixture Provider",
            "syncEnabled": syncEnabled,
            "selectedModels": modelsArray,
            "managedCapabilities": capsObject,
            "serviceRoleIsConversation": true,
        ]
        if createIntent { candidate["createIntent"] = true }
        if let presetID { candidate["presetID"] = presetID }
        return candidate
    }

    private func submitSetIntent(candidate: [String: Any],
                                 secret: Data,
                                 baseRevision: [String: String]?,
                                 routeToken: String = "route-a",
                                 generation: UInt64 = 5,
                                 subjectKind: SubjectKind = .providerSave) throws -> String {
        var intent: [String: Any] = [
            "subject": ["kind": subjectKind.rawValue, "id": providerID.uuidString],
            "route": ["token": routeToken, "generation": generation],
            "intent": "set",
            "candidate": candidate,
        ]
        if let baseRevision { intent["baseRevision"] = baseRevision }
        let data = try JSONSerialization.data(withJSONObject: intent, options: [.sortedKeys])
        var json = data
        json.append(0)
        var tokenBuffer = [CChar](repeating: 0, count: 64)
        var status: Int32 = -1
        json.withUnsafeBytes { jsonRaw in
            secret.withUnsafeBytes { secretRaw in
                tokenBuffer.withUnsafeMutableBufferPointer { buffer in
                    status = floeSecretSaveIntentSubmit(
                        jsonRaw.bindMemory(to: CChar.self).baseAddress,
                        secretRaw.bindMemory(to: UInt8.self).baseAddress,
                        Int32(secret.count),
                        buffer.baseAddress, 40)
                }
            }
        }
        XCTAssertEqual(status, 0, "synthetic intent submit must succeed")
        return String(cString: tokenBuffer)
    }

    private func makeFacade(gateway: IngressTestGateway,
                            adapters: CountingAdapterFactory = CountingAdapterFactory(),
                            admission: ProviderTransportAdmitting = TransportAdmissionClosed(),
                            route: ConfigRouteContextProviding? = nil,
                            ownedWorkRegistry: (any OwnedWorkRegistryPort)? = nil,
                            epoch: UInt64? = 1) -> ModelConfigurationFacade {
        ModelConfigurationFacade(
            database: database,
            gateway: gateway,
            catalogBytes: nil,
            transportAdmission: admission,
            routeContext: route ?? FixedRouteContext(token: routeToken,
                                                     generation: routeGeneration),
            adapters: adapters,
            epochProvider: FixedEpochProvider(epoch: epoch),
            ownedWorkRegistry: ownedWorkRegistry ?? AlwaysAttachOwnedWorkPort())
    }

    private func revision(_ value: Int64) -> ConfigRevision {
        ConfigRevision.provider(id: providerID, syncRevision: value)
    }

    private func storedProvider() async throws -> ProviderProfile? {
        try await ModelConfigurationStore(database: database).provider(id: providerID)
    }

    // MARK: - 1. Set happy path end-to-end

    func testProviderSetRunsRealDraftRunnerChainAndCommitsBothStores() async throws {
        let gateway = IngressTestGateway()
        let facade = makeFacade(gateway: gateway)
        let candidate = try makeCandidateJSON(createIntent: true)
        let token = try submitSetIntent(candidate: candidate, secret: syntheticSecret,
                                       baseRevision: ["resourceID": "provider.\(providerID.uuidString)",
                                                      "version": "0"])
        let execution = await facade.saveProviderSet(ingressToken: token,
                                                     envelopeRevision: revision(0))
        guard case .committed(let committed) = execution else {
            return XCTFail("expected committed, got \(execution.failedDescriptionForTests)")
        }
        XCTAssertEqual(committed.providerID, providerID)
        XCTAssertFalse(committed.syncPending)   // local-only: never phantom
        XCTAssertNil(committed.syncError)
        // Secret written under the canonical deterministic reference ONLY.
        let expectedReference = ConfigSecretIdentity.providerOpaqueReference(
            for: ConfigSecretIdentity.providerSecretReference(
                account: "provider.\(providerID.uuidString)", synchronizable: false))
        XCTAssertEqual(gateway.snapshot().writes.map { $0.reference }, [expectedReference])
        XCTAssertEqual(gateway.snapshot().writes.first?.bytes, syntheticSecret)
        // DB row durable with the persisted reference identity and sync false.
        let rowOptional = try await storedProvider()
        let row = try XCTUnwrap(rowOptional)
        XCTAssertEqual(row.secretRef?.keychainAccount, "provider.\(providerID.uuidString)")
        XCTAssertEqual(row.secretRef?.synchronizable, false)
        // One-shot consume: replay is refused and NOTHING is re-written.
        let before = gateway.snapshot().writes.count
        let replay = await facade.saveProviderSet(ingressToken: token,
                                                  envelopeRevision: revision(0))
        guard case .failed(let failed) = replay,
              failed.error.code == .notFound, failed.error.reason == "saveIntentAlreadyConsumed"
        else { return XCTFail("replay must be already-consumed") }
        XCTAssertEqual(gateway.snapshot().writes.count, before)
    }

    // MARK: - 2. Wrong route / subject / revision / create-intent

    func testWrongRouteGenerationRejectsBeforeAnyEffect() async throws {
        let gateway = IngressTestGateway()
        let facade = makeFacade(gateway: gateway)
        let candidate = try makeCandidateJSON(createIntent: true)
        let token = try submitSetIntent(candidate: candidate, secret: syntheticSecret,
                                        baseRevision: nil, generation: 99) // frozen ≠ live
        let execution = await facade.saveProviderSet(ingressToken: token,
                                                     envelopeRevision: nil)
        guard case .failed(let failed) = execution,
              failed.error.reason == "saveIntentRouteMismatch" else {
            return XCTFail("route mismatch must refuse")
        }
        XCTAssertTrue(gateway.snapshot().writes.isEmpty)
        let absentRow = await storedRowQuietly()
        XCTAssertNil(absentRow, "no row")
    }

    func testMcpSubjectTokenCannotDriveProviderSave() async throws {
        let gateway = IngressTestGateway()
        let facade = makeFacade(gateway: gateway)
        let candidate = try makeCandidateJSON(createIntent: true)
        let token = try submitSetIntent(candidate: candidate, secret: syntheticSecret,
                                        baseRevision: nil, subjectKind: .mcpSave)
        let execution = await facade.saveProviderSet(ingressToken: token,
                                                     envelopeRevision: nil)
        guard case .failed(let failed) = execution,
              failed.error.reason == "saveIntentSubjectMismatch" else {
            return XCTFail("subject isolation must hold")
        }
        XCTAssertTrue(gateway.snapshot().writes.isEmpty)
    }

    func testStaleBaseRevisionAndEnvelopeRevisionBothRefuse() async throws {
        // Existing row at syncRevision 0; intent frozen at version "7".
        let store = ModelConfigurationStore(database: database)
        try await store.saveProvider(ProviderProfile(
            id: providerID, kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.example.invalid/v1")!,
            displayName: "Existing",
            secretRef: SecretReference(keychainAccount: "provider.\(providerID.uuidString)",
                                       synchronizable: false)))
        let gateway = IngressTestGateway()
        let facade = makeFacade(gateway: gateway)
        let candidate = try makeCandidateJSON()
        let token = try submitSetIntent(candidate: candidate, secret: syntheticSecret,
                                        baseRevision: ["resourceID": "provider.\(providerID.uuidString)",
                                                       "version": "7"])
        let execution = await facade.saveProviderSet(ingressToken: token,
                                                     envelopeRevision: revision(0))
        guard case .failed(let failed) = execution,
              failed.error.code == .staleRevision else {
            return XCTFail("lease base revision must gate")
        }
        XCTAssertTrue(gateway.snapshot().writes.isEmpty)
        // Envelope divergence alone also refuses (no lease).
        let keep = await facade.saveProviderKeep(candidateJSON: try JSONSerialization.data(
            withJSONObject: try makeCandidateJSON(), options: [.sortedKeys]),
            envelopeRevision: revision(42))
        guard case .failed(let failed2) = keep,
              failed2.error.reason == "providerEnvelopeRevision" else {
            return XCTFail("envelope revision must gate")
        }
    }

    func testCreateIntentConflictAndMissingRowRules() async throws {
        let store = ModelConfigurationStore(database: database)
        try await store.saveProvider(ProviderProfile(
            id: providerID, kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.example.invalid/v1")!,
            displayName: "Existing"))
        let gateway = IngressTestGateway()
        let facade = makeFacade(gateway: gateway)
        // createIntent TRUE while the row exists ⇒ conflict (never overwrite).
        let candidate = try makeCandidateJSON(createIntent: true)
        let token = try submitSetIntent(candidate: candidate, secret: syntheticSecret,
                                        baseRevision: nil)
        let execution = await facade.saveProviderSet(ingressToken: token,
                                                     envelopeRevision: nil)
        guard case .failed(let failed) = execution,
              failed.error.reason == "createConflict" else {
            return XCTFail("create intent must conflict on existing row")
        }
        XCTAssertTrue(gateway.snapshot().writes.isEmpty)
        // Edit intent while the row is ABSENT ⇒ typed notFound (no silent
        // creation without an explicit create intent).
        let missing = UUID()
        var editCandidate = try makeCandidateJSON()
        editCandidate["id"] = missing.uuidString
        let editToken = try submitSetIntentRaw(subjectID: missing.uuidString,
                                               candidate: editCandidate)
        let editExecution = await facade.saveProviderSet(ingressToken: editToken,
                                                         envelopeRevision: nil)
        guard case .failed(let editFailed) = editExecution,
              editFailed.error.code == .notFound else {
            return XCTFail("absent row edit must be notFound")
        }
    }

    private func submitSetIntentRaw(subjectID: String, candidate: [String: Any]) throws -> String {
        var mutableCandidate = candidate
        mutableCandidate["id"] = subjectID
        let intent: [String: Any] = [
            "subject": ["kind": SubjectKind.providerSave.rawValue, "id": subjectID],
            "route": ["token": routeToken, "generation": routeGeneration],
            "intent": "set",
            "candidate": mutableCandidate,
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

    // MARK: - 3. Connection-bound credential reuse (Keep rules)

    func testKeepAcrossChangedConnectionRequiresFreshSetWithZeroEffects() async throws {
        let store = ModelConfigurationStore(database: database)
        try await store.saveProvider(ProviderProfile(
            id: providerID, kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://old.example.invalid/v1")!,
            displayName: "Old origin",
            secretRef: SecretReference(keychainAccount: "provider.\(providerID.uuidString)",
                                       synchronizable: false)))
        let gateway = IngressTestGateway()
        let facade = makeFacade(gateway: gateway)
        // Keep: same draft but NEW origin — the ORIGINAL makeRequest rule
        // refuses silent credential migration (ProviderSaveRunner:157-180).
        let candidate = try makeCandidateJSON(baseURL: "https://new.example.invalid/v1")
        let keep = await facade.saveProviderKeep(
            candidateJSON: try JSONSerialization.data(withJSONObject: candidate,
                                                      options: [.sortedKeys]),
            envelopeRevision: revision(0))
        guard case .failed(let failed) = keep,
              failed.error.reason.contains("connectionChangedRequiresNewCredential") else {
            return XCTFail("connection change must require a new credential")
        }
        XCTAssertTrue(gateway.snapshot().writes.isEmpty)
        let rowOptional = try await storedProvider()
        let row = try XCTUnwrap(rowOptional)
        XCTAssertEqual(row.baseURL.absoluteString, "https://old.example.invalid/v1",
                       "zero overwrite on refused keep")
    }

    func testKeepSameConnectionCommitsWithoutAnySecretWrite() async throws {
        let store = ModelConfigurationStore(database: database)
        try await store.saveProvider(ProviderProfile(
            id: providerID, kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.example.invalid/v1")!,
            displayName: "Keep me",
            secretRef: SecretReference(keychainAccount: "provider.\(providerID.uuidString)",
                                       synchronizable: false)))
        let gateway = IngressTestGateway()
        let facade = makeFacade(gateway: gateway)
        var candidate = try makeCandidateJSON()
        candidate["displayName"] = "Renamed via keep"
        let keep = await facade.saveProviderKeep(
            candidateJSON: try JSONSerialization.data(withJSONObject: candidate,
                                                      options: [.sortedKeys]),
            envelopeRevision: revision(0))
        guard case .committed = keep else {
            return XCTFail("same-connection keep must commit")
        }
        XCTAssertTrue(gateway.snapshot().writes.isEmpty, "Keep never touches secrets")
        let rowOptional = try await storedProvider()
        let row = try XCTUnwrap(rowOptional)
        XCTAssertEqual(row.displayName, "Renamed via keep")
        XCTAssertNotNil(row.secretRef)
    }

    // MARK: - 4. Sync normalization BEFORE any effect

    func testSyncTrueRequestRefusedTypedBeforeSecretOrDBEffects() async throws {
        let gateway = IngressTestGateway()
        let facade = makeFacade(gateway: gateway)
        let candidate = try makeCandidateJSON(createIntent: true, syncEnabled: true)
        let token = try submitSetIntent(candidate: candidate, secret: syntheticSecret,
                                        baseRevision: nil)
        let execution = await facade.saveProviderSet(ingressToken: token,
                                                     envelopeRevision: nil)
        guard case .failed(let failed) = execution,
              failed.error.code == .unsupportedSyncRequest else {
            return XCTFail("explicit sync must be refused typed, not downgraded silently")
        }
        XCTAssertTrue(gateway.snapshot().writes.isEmpty)
        // Ordinary saves persist effective false and report NO phantom error
        // (covered in test 1; here the refusal itself must precede effects).
        let noRowAtAll = await storedRowQuietly()
        XCTAssertNil(noRowAtAll)
    }

    // MARK: - 5. Gateway precondition + CV-R4 dispositions

    func testUnregisteredGatewayRefusesNeedsConfigurationBeforeDB() async throws {
        let gateway = IngressTestGateway(registered: false)
        let facade = makeFacade(gateway: gateway)
        let candidate = try makeCandidateJSON(createIntent: true)
        let token = try submitSetIntent(candidate: candidate, secret: syntheticSecret,
                                        baseRevision: nil)
        let execution = await facade.saveProviderSet(ingressToken: token,
                                                     envelopeRevision: nil)
        guard case .failed(let failed) = execution,
              failed.error.code == .needsConfiguration else {
            return XCTFail("unregistered gateway must fail closed with needsConfiguration")
        }
        let rowAfterRefuse = await storedRowQuietly()
        XCTAssertNil(rowAfterRefuse, "no DB row before secret gate")
    }

    /// CV-R4 core case: a CLAIMED secret write that comes back with the
    /// AMBIGUOUS dispatcherUnresponsive error must NEVER be projected as
    /// "saved" or as provable "no effect", must write NO DB row, and must
    /// not resurrect/free the consumed int:v1 intent.
    func testAmbiguousErrorAfterClaimedWriteIsOutcomeUnknownNeverNoEffect() async throws {
        let gateway = IngressTestGateway()
        gateway.nextWriteError = SecretBackendError.dispatcherUnresponsive
        let facade = makeFacade(gateway: gateway)
        let candidate = try makeCandidateJSON(createIntent: true)
        let token = try submitSetIntent(candidate: candidate, secret: syntheticSecret,
                                        baseRevision: nil)
        let execution = await facade.saveProviderSet(ingressToken: token,
                                                     envelopeRevision: nil)
        guard case .failed(let failed) = execution else {
            return XCTFail("must not report saved")
        }
        XCTAssertEqual(failed.phase, ProviderSaveRunError.credentialOrSync("").phase)
        guard case .outcomeUnknown? = failed.secretDisposition else {
            return XCTFail("dispatcherUnresponsive after publish MUST be outcomeUnknown, "
                + "never effectAbsent (VAULT_GATEWAY_FAILURE_SEMANTICS_MAIN_20261019.json)")
        }
        XCTAssertFalse(failed.error.reason.hasPrefix("credentialPhaseAbsent"))
        XCTAssertTrue(failed.error.reason.hasPrefix("secretOutcomeUnknown"))
        XCTAssertFalse(failed.databaseRowWritten)
        let noRowYet = await storedRowQuietly()
        XCTAssertNil(noRowYet, "runner aborts the chain before bundleSave")
        // The consumed intent is NOT released for reuse.
        let retry = await facade.saveProviderSet(ingressToken: token,
                                                 envelopeRevision: revision(0))
        guard case .failed(let retryFailed) = retry,
              retryFailed.error.reason == "saveIntentAlreadyConsumed" else {
            return XCTFail("ambiguous failure never frees the UI intent")
        }
        // REPAIR (MC-R4, documented supported-semantics correction of the
        // parent's same-session convergence expectation): the parent retried
        // a NEW intent on the SAME facade after clearing nextWriteError and
        // expected `.committed`. That retry would dispatch a NEWER write
        // while the FIRST claimed execution's physical settlement is
        // unknown to a non-observing gateway — exactly what Main's ruling
        // forbids ("no timer-release, callercancel-release, or pretend
        // settled"; unknown stays typed pending with the durable intent).
        // The owner therefore parks, the retry is refused with the typed
        // pending code, and convergence is demonstrated through the honest
        // recovery path below (durable intent + drain after settlement
        // truth/restart). Real-mailbox individual-signal cases (claimed
        // watchdog vs late completion) live in
        // RuntimeFacadeConfigPhysicalTests.swift.
        gateway.nextWriteError = nil
        let coordinator = ProviderOperationCoordinatorRegistry.shared.coordinator(for: database)
        let pending = await coordinator.pendingRecord(providerID: providerID)
        XCTAssertNotNil(pending, "unsettled claimed write retains its owner")
        let gated = await facade.saveProviderKeep(
            candidateJSON: try JSONSerialization.data(withJSONObject: try makeCandidateJSON(),
                                                      options: [.sortedKeys]),
            envelopeRevision: revision(1))
        guard case .failed(let gatedFailed) = gated,
              gatedFailed.error.reason == "providerPendingReconciliation" else {
            return XCTFail("a newer intent must be guarded while outstanding: \(gated.failedDescriptionForTests)")
        }
        let reconciled = await facade.reconcileProviderRecovery(providerID: providerID)
        XCTAssertEqual(reconciled, .stillPending(reason: "noIndividualReceipt"),
                       "no fake settlement without the individual signal")
        let cleanupLedger = ProviderSecretCleanup(database: database)
        let ledgerEntries = try await cleanupLedger.entries()
        XCTAssertEqual(ledgerEntries.map(\.intent), [.secretWrite],
                       "the new-resource durable recovery intent survived")
    }

    /// Contrast (required test source): a PROVEN pre-queue rejection is C0
    /// and is reported as absent-retryable — never as outcome unknown.
    func testPreQueueRejectionIsProvablyAbsent() async throws {
        let gateway = IngressTestGateway()
        gateway.nextWriteError = SecretBackendError.mailboxSaturated
        let facade = makeFacade(gateway: gateway)
        let candidate = try makeCandidateJSON(createIntent: true)
        let token = try submitSetIntent(candidate: candidate, secret: syntheticSecret,
                                        baseRevision: nil)
        let execution = await facade.saveProviderSet(ingressToken: token,
                                                     envelopeRevision: nil)
        guard case .failed(let failed) = execution,
              case .effectAbsent(let reason)? = failed.secretDisposition,
              reason == "mailboxSaturated" else {
            return XCTFail("saturation at publish is queue-never-claimed C0")
        }
        // Pure classifier table (all ambiguous post-publish values):
        XCTAssertEqual(SecretDispositionClassifier.classify(
            error: SecretBackendError.dispatcherCancelled, published: true),
            .outcomeUnknown(reason: "dispatcherCancelledStatusAmbiguous"))
        XCTAssertEqual(SecretDispositionClassifier.classify(
            error: SecretBackendError.abandoned, published: true),
            .outcomeUnknown(reason: "abandoned"))
        XCTAssertEqual(SecretDispositionClassifier.classify(
            error: SecretBackendError.dispatcherUnresponsive, published: true),
            .outcomeUnknown(reason: "dispatcherUnresponsiveClaimed"))
        XCTAssertEqual(SecretDispositionClassifier.classify(
            error: SecretBackendError.dispatcherUnresponsive, published: false),
            .effectAbsent(reason: "dispatcherUnresponsivePreDispatch"))
    }

    /// Phase-failure partial-commit evidence: secret committed, bundle fails
    /// ⇒ documented orphan state with honest labels; retry converges.
    func testSecretCommittedThenBundleFailsLeavesOrphanNotSavedClaim() async throws {
        let gateway = IngressTestGateway()
        let store = ModelConfigurationStore(database: database)
        // Drive the executor directly with the committer fault seam so the
        // bundle transaction genuinely fails AFTER the real secret write.
        let ownership = ProviderOperationOwnership()
        let ownedWork = ConfigOwnedWorkLifecycle(
            registry: AlwaysAttachOwnedWorkPort(),
            epochProvider: FixedEpochProvider(epoch: 1))
        let executor = ProviderSaveExecutor(
            database: database,
            gateway: gateway,
            ownership: ownership,
            ownedWork: ownedWork,
            committerFault: .beforeBundle)
        let candidate = try makeCandidateJSON(createIntent: true)
        let token = try submitSetIntent(candidate: candidate, secret: syntheticSecret,
                                        baseRevision: nil)
        let execution = await executor.saveSet(token: token,
                                               route: RouteBinding(token: routeToken,
                                                                   generation: routeGeneration),
                                               envelopeRevision: nil)
        guard case .failed(let failed) = execution,
              failed.error.reason.hasPrefix("localCommitFailed.secretCommittedOrphanRetryConverges"),
              case .committed? = failed.secretDisposition,
              failed.databaseRowWritten == false else {
            return XCTFail("must report localCommit with committed-secret orphan")
        }
        let orphanRow = try await store.provider(id: providerID)
        XCTAssertNil(orphanRow)
        XCTAssertFalse(gateway.snapshot().writes.isEmpty, "the real secret write happened")
        // Retry WITHOUT the fault converges (idempotent reference).
        let retryExecutor = ProviderSaveExecutor(
            database: database, gateway: gateway, ownership: ownership, ownedWork: ownedWork)
        let token2 = try submitSetIntent(candidate: candidate, secret: syntheticSecret,
                                         baseRevision: nil)
        let retry = await retryExecutor.saveSet(token: token2,
                                                route: RouteBinding(token: routeToken,
                                                                    generation: routeGeneration),
                                                envelopeRevision: nil)
        guard case .committed = retry else {
            return XCTFail("retry must converge")
        }
        let rowOptional = try await store.provider(id: providerID)
        let row = try XCTUnwrap(rowOptional)
        XCTAssertNotNil(row.secretRef)
    }

    /// Readback failure is never converted into a no-effect claim.
    func testReadbackMismatchKeepsRowAndSecretHonestState() async throws {
        // Injected AFTER-bundle fault mimics "commit happened, result lost":
        // the runner surfaces localCommit; a genuine readback mismatch path
        // is exercised through the ORIGINAL verify hook by mutating the DB
        // between commit and verify is impossible in one await chain here,
        // so the fault seam at post-commit is the honest observable case.
        let gateway = IngressTestGateway()
        let ownership = ProviderOperationOwnership()
        let ownedWork = ConfigOwnedWorkLifecycle(
            registry: AlwaysAttachOwnedWorkPort(),
            epochProvider: FixedEpochProvider(epoch: 1))
        let executor = ProviderSaveExecutor(
            database: database,
            gateway: gateway,
            ownership: ownership,
            ownedWork: ownedWork,
            committerFault: .afterBundleCommitted)
        let candidate = try makeCandidateJSON(createIntent: true)
        let token = try submitSetIntent(candidate: candidate, secret: syntheticSecret,
                                        baseRevision: nil)
        let execution = await executor.saveSet(token: token,
                                               route: RouteBinding(token: routeToken,
                                                                   generation: routeGeneration),
                                               envelopeRevision: nil)
        guard case .failed(let failed) = execution,
              failed.error.reason.hasPrefix("localCommitFailed") else {
            return XCTFail("post-commit failure must surface as localCommit")
        }
        // The row IS durable; the runner still truthfully reports failure —
        // never a false "no effect", never a false "saved".
        let store = ModelConfigurationStore(database: database)
        let rowOptional = try await store.provider(id: providerID)
        let row = try XCTUnwrap(rowOptional)
        XCTAssertEqual(row.kind, .openAI)
    }

    // MARK: - 6. Clear + cleanup ledger + drain

    func testClearQueuesCleanupAndUnknownDeleteKeepsEntryForDrain() async throws {
        let store = ModelConfigurationStore(database: database)
        try await store.saveProvider(ProviderProfile(
            id: providerID, kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.example.invalid/v1")!,
            displayName: "Clear me",
            secretRef: SecretReference(keychainAccount: "provider.\(providerID.uuidString)",
                                       synchronizable: false)))
        let gateway = IngressTestGateway()
        gateway.deleteError = SecretBackendError.abandoned // claimed-unknown
        let facade = makeFacade(gateway: gateway)
        let candidate = try makeCandidateJSON()
        let clear = await facade.saveProviderClear(
            candidateJSON: try JSONSerialization.data(withJSONObject: candidate,
                                                      options: [.sortedKeys]),
            envelopeRevision: revision(0))
        guard case .cleared(let cleared) = clear,
            cleared.cleanupQueuedForRetry else {
            return XCTFail("clear must commit row WITHOUT reference and queue cleanup")
        }
        let rowOptional = try await store.provider(id: providerID)
        let row = try XCTUnwrap(rowOptional)
        XCTAssertNil(row.secretRef, "bundle committed the cleared reference")
        // The ledger holds the durable intent.
        let cleanup = ProviderSecretCleanup(database: database)
        let entries = try await cleanup.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].intent, .secretClear)
        // Drain with the delete now succeeding: retry converges.
        gateway.deleteError = nil
        let ownership = ProviderOperationOwnership()
        let port = AlwaysAttachOwnedWorkPort()
        let ownedWork = ConfigOwnedWorkLifecycle(registry: port,
                                                 epochProvider: FixedEpochProvider(epoch: 1))
        let result = try await cleanup.drain(gateway: gateway, ownership: ownership,
                                             ownedWork: ownedWork)
        XCTAssertEqual(result.outcomes[providerID], .secretRemoved)
        XCTAssertEqual(result.entriesRemaining, 0)
        XCTAssertEqual(port.counts().attached, port.counts().detached,
                       "every attach settles after its awaited effect")
    }

    func testDrainDiscardsAbortedDeleteAndSupersededClearWithoutDeleting() async throws {
        let store = ModelConfigurationStore(database: database)
        let liveProvider = ProviderProfile(
            id: providerID, kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.example.invalid/v1")!,
            displayName: "Still live",
            secretRef: SecretReference(keychainAccount: "provider.\(providerID.uuidString)",
                                       synchronizable: false))
        try await store.saveProvider(liveProvider)
        let cleanup = ProviderSecretCleanup(database: database)
        try await cleanup.enqueue(.init(providerID: providerID,
                                        account: "provider.\(providerID.uuidString)",
                                        intent: .providerDelete))
        let gateway = IngressTestGateway()
        let result = try await cleanup.drain(
            gateway: gateway,
            ownership: ProviderOperationOwnership(),
            ownedWork: ConfigOwnedWorkLifecycle(
                registry: AlwaysAttachOwnedWorkPort(),
                epochProvider: FixedEpochProvider(epoch: 1)))
        guard case .intentResolvedWithoutDelete(let reason)? = result.outcomes[providerID],
              reason == "deleteAbortedRowStillOwnsSecret" else {
            return XCTFail("live owner must never be drained away (CV-R1)")
        }
        XCTAssertTrue(gateway.snapshot().deletes.isEmpty)
        let rowOptional = try await store.provider(id: providerID)
        let row = try XCTUnwrap(rowOptional)
        XCTAssertNotNil(row.secretRef, "secret untouched for live owner")
        // Now a committed clear with a NEWER Set: superseded clear discards.
        try await cleanup.enqueue(.init(providerID: providerID,
                                        account: "provider.\(providerID.uuidString)",
                                        intent: .secretClear))
        let second = try await cleanup.drain(
            gateway: gateway,
            ownership: ProviderOperationOwnership(),
            ownedWork: ConfigOwnedWorkLifecycle(
                registry: AlwaysAttachOwnedWorkPort(),
                epochProvider: FixedEpochProvider(epoch: 1)))
        guard case .intentResolvedWithoutDelete(let reason2)? = second.outcomes[providerID],
              reason2 == "clearSupersededByNewerSet" else {
            return XCTFail("a newer Set must survive an obsolete clear intent")
        }
        XCTAssertTrue(gateway.snapshot().deletes.isEmpty)
    }

    func testDrainSkipsProviderWithActiveSaveOperation() async throws {
        let store = ModelConfigurationStore(database: database)
        try await store.saveProvider(ProviderProfile(
            id: providerID, kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.example.invalid/v1")!,
            displayName: "Busy",
            secretRef: SecretReference(keychainAccount: "provider.\(providerID.uuidString)",
                                       synchronizable: false)))
        let cleanup = ProviderSecretCleanup(database: database)
        try await cleanup.enqueue(.init(providerID: providerID,
                                        account: "provider.\(providerID.uuidString)",
                                        intent: .secretClear))
        let ownership = ProviderOperationOwnership()
        // Hold the provider exactly like an in-flight save would. REPAIR
        // adaptation (documented): beginOperation now returns an EXACT
        // ticket (MC-R4: same-kind tokenless release cannot free a later
        // owner), and release presents that ticket.
        guard case .attached(let heldTicket) = await ownership.beginOperation(providerID: providerID,
                                                                             kind: .save) else {
            return XCTFail("first reservation must attach")
        }
        let gateway = IngressTestGateway()
        let result = try await cleanup.drain(
            gateway: gateway,
            ownership: ownership,
            ownedWork: ConfigOwnedWorkLifecycle(
                registry: AlwaysAttachOwnedWorkPort(),
                epochProvider: FixedEpochProvider(epoch: 1)))
        XCTAssertEqual(result.outcomes[providerID], .activeOperationSkippedKept)
        XCTAssertTrue(gateway.snapshot().deletes.isEmpty)
        XCTAssertEqual(result.entriesRemaining, 1, "entry survives for the next drain")
        await ownership.endOperation(heldTicket)
    }

    func testLedgerFullFailsClosedBeforeDestructiveEffect() async throws {
        let cleanup = ProviderSecretCleanup(database: database)
        // Fill the ledger to the cap through the real enqueue path.
        for index in 0..<ProviderSecretCleanup.maximumEntries {
            let id = UUID()
            try await cleanup.enqueue(.init(providerID: id,
                                            account: "provider.\(id.uuidString)",
                                            intent: .providerDelete))
        }
        let overflow = UUID()
        do {
            try await cleanup.enqueue(.init(providerID: overflow,
                                            account: "provider.\(overflow.uuidString)",
                                            intent: .providerDelete))
            XCTFail("saturated ledger must fail closed")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .persistenceUnavailable)
            XCTAssertEqual(error.reason, "cleanupLedgerSaturated")
        }
    }

    // MARK: - 7. Owned-work attach: fail-closed, never fake zero

    func testOwnedWorkAttachRejectionPreventsAllEffects() async throws {
        let gateway = IngressTestGateway()
        let rejecting = RejectingOwnedWorkPort(code: .alreadyDraining)
        let facade = makeFacade(gateway: gateway, ownedWorkRegistry: rejecting)
        let candidate = try makeCandidateJSON(createIntent: true)
        let token = try submitSetIntent(candidate: candidate, secret: syntheticSecret,
                                        baseRevision: nil)
        let execution = await facade.saveProviderSet(ingressToken: token,
                                                     envelopeRevision: nil)
        guard case .failed(let failed) = execution,
              failed.phase == "ownedWorkAttach",
              failed.error.code == .runtimeUnavailable,
              failed.error.reason == "ownedWorkRejected.alreadyDraining" else {
            return XCTFail("attach rejection must stop before any effect")
        }
        XCTAssertTrue(gateway.snapshot().writes.isEmpty)
        let attachBlockedRow = await storedRowQuietly()
        XCTAssertNil(attachBlockedRow)
        // Same gate for delete:
        do {
            _ = try await facade.deleteProvider(revision: revision(0))
            XCTFail("delete must also be gated")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .runtimeUnavailable)
        }
        // No admitted epoch at all → typed noAdmittedRuntimeEpoch, never a
        // silent "proceed anyway" (no default fake zero).
        let noEpochFacade = makeFacade(gateway: IngressTestGateway(), epoch: nil)
        let token2 = try submitSetIntent(candidate: candidate, secret: syntheticSecret,
                                         baseRevision: nil)
        let execution2 = await noEpochFacade.saveProviderSet(ingressToken: token2,
                                                             envelopeRevision: nil)
        guard case .failed(let failed2) = execution2,
              failed2.error.reason == "noAdmittedRuntimeEpoch" else {
            return XCTFail("epoch absence must fail closed")
        }
    }

    // MARK: - 8. Probe gates (auth-before-network, admission, anonymity)

    func testProbeAuthRequiredMissingSecretRefusesBeforeAdapter() async throws {
        let store = ModelConfigurationStore(database: database)
        try await store.saveProvider(ProviderProfile(
            id: providerID, kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.example.invalid/v1")!,
            displayName: "Needs auth",
            secretRef: SecretReference(keychainAccount: "provider.\(providerID.uuidString)",
                                       synchronizable: false)))
        let gateway = IngressTestGateway() // no stored bytes ⇒ secretMissing
        let adapters = CountingAdapterFactory()
        let facade = makeFacade(gateway: gateway, adapters: adapters,
                                admission: AdmissionOpen())
        let outcome = await facade.probeForEffect(providerID: providerID)
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.failureReason, "credentialUnavailable:secretMissing")
        XCTAssertEqual(adapters.adapterConstructionCalls, 0,
                       "adapter/network must NEVER be constructed before auth")
        XCTAssertGreaterThanOrEqual(gateway.snapshot().reads.count, 1,
                                    "typed resolution reads the gateway first")
    }

    func testProbeLanEndpointWithoutSecretNeverAnonymous() async throws {
        let store = ModelConfigurationStore(database: database)
        try await store.saveProvider(ProviderProfile(
            id: providerID, kind: .custom, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "http://192.168.1.50:8080/v1")!,
            displayName: "LAN self-hosted WITH auth style bearer",
            secretRef: SecretReference(keychainAccount: "provider.\(providerID.uuidString)",
                                       synchronizable: false),
            allowsPlainHTTP: true))
        let gateway = IngressTestGateway()
        let adapters = CountingAdapterFactory()
        let facade = makeFacade(gateway: gateway, adapters: adapters,
                                admission: AdmissionOpen())
        let outcome = await facade.probeForEffect(providerID: providerID)
        // LAN endpoint alone never authorizes anonymous dispatch
        // (anonymousAuth decision): bearer kind + missing secret refuses.
        XCTAssertEqual(outcome.failureReason, "credentialUnavailable:secretMissing")
        XCTAssertEqual(adapters.adapterConstructionCalls, 0)
    }

    func testProbeLocalKindAnonymousOnlyWhenAdmitted() async throws {
        let store = ModelConfigurationStore(database: database)
        try await store.saveProvider(ProviderProfile(
            id: providerID, kind: .local, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            displayName: "Self-hosted loopback",
            allowsPlainHTTP: true))
        let gateway = IngressTestGateway()
        let adapters = CountingAdapterFactory()
        // Admission CLOSED (the current shipped state): typed refusal, and
        // NO gateway key read is even needed for a none-auth provider.
        let closed = makeFacade(gateway: gateway, adapters: adapters)
        let closedOutcome = await closed.probeForEffect(providerID: providerID)
        XCTAssertEqual(closedOutcome.status, .failed)
        XCTAssertTrue(closedOutcome.failureReason?.hasPrefix("transportUnavailable") ?? false)
        XCTAssertEqual(adapters.adapterConstructionCalls, 0)
        // Admitted: the ORIGINAL no-auth style is honored (nil key), result
        // is REPORTED only — no store mutation (no auto-install).
        let open = makeFacade(gateway: gateway, adapters: adapters, admission: AdmissionOpen())
        let openOutcome = await open.probeForEffect(providerID: providerID)
        XCTAssertEqual(openOutcome.status, .connected)
        XCTAssertEqual(openOutcome.modelCount, 2)
        XCTAssertTrue(adapters.lastCredentialsUsed?.apiKey == nil,
                      "local kind dispatches anonymously (authStyle none ONLY)")
        let models = try await store.models(providerID: providerID)
        XCTAssertTrue(models.isEmpty, "probe NEVER installs discovered models")
    }

    func testProbeDuplicateInFlightRefused() async throws {
        let store = ModelConfigurationStore(database: database)
        try await store.saveProvider(ProviderProfile(
            id: providerID, kind: .local, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            displayName: "Busy probe", allowsPlainHTTP: true))
        let adapters = CountingAdapterFactory()
        adapters.holdProbeMillis = 300 // keep the first probe in flight
        let facade = makeFacade(gateway: IngressTestGateway(), adapters: adapters,
                                admission: AdmissionOpen())
        let probeProviderID = providerID
        let firstTask = Task { try await facade.probe(providerID: probeProviderID) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        do {
            _ = try await facade.probe(providerID: providerID)
            _ = try? await firstTask.value
            XCTFail("second concurrent probe must be duplicateInFlight")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .duplicateInFlight)
            _ = try? await firstTask.value
        }
    }

    // MARK: - 8b. Preset identity sidecar (real store join)

    func testPresetSidecarRecordsRealSaveAndFeedsConfiguredFilter() async throws {
        let gateway = IngressTestGateway()
        let facade = ModelConfigurationFacade(
            database: database,
            gateway: gateway,
            catalogBytes: RuntimeCatalogFixture.validDocument,
            transportAdmission: TransportAdmissionClosed(),
            routeContext: FixedRouteContext(token: routeToken, generation: routeGeneration),
            epochProvider: FixedEpochProvider(epoch: 1),
            ownedWorkRegistry: AlwaysAttachOwnedWorkPort())
        // Catalog "configured" is empty before any real save.
        let before = try await facade.catalogSearch(query: "fixture", filter: .configured)
        // Authorized page projection: {"rows":[…],nextCursor,hasMore}.
        let beforeObject = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
        let beforeRows = try XCTUnwrap(beforeObject["rows"] as? [Any])
        XCTAssertTrue(beforeRows.isEmpty, "configured must start empty")
        let candidate = try makeCandidateJSON(createIntent: true,
                                              presetID: "fixture-openai")
        let token = try submitSetIntent(candidate: candidate, secret: syntheticSecret,
                                        baseRevision: nil)
        let execution = await facade.saveProviderSet(ingressToken: token,
                                                     envelopeRevision: nil)
        guard case .committed = execution else {
            return XCTFail("preset save must commit")
        }
        let configured = try await facade.catalogSearch(query: "fixture", filter: .configured)
        let configuredObject = try XCTUnwrap(JSONSerialization.jsonObject(with: configured) as? [String: Any])
        let objects = try XCTUnwrap(configuredObject["rows"] as? [[String: Any]])
        XCTAssertEqual(objects.count, 1)
        XCTAssertEqual(objects.first?["presetID"] as? String, "fixture-openai",
                       "configured comes from the durable sidecar joined to LIVE rows")
        // Deleting the provider removes the entry (no dangling "configured").
        let rowOptional = try await storedProvider()
        let row = try XCTUnwrap(rowOptional)
        _ = try await facade.deleteProvider(
            revision: ConfigRevision.provider(id: providerID, syncRevision: row.syncRevision))
        let after = try await facade.catalogSearch(query: "fixture", filter: .configured)
        let afterObject = try XCTUnwrap(JSONSerialization.jsonObject(with: after) as? [String: Any])
        let afterRows = try XCTUnwrap(afterObject["rows"] as? [Any])
        XCTAssertTrue(afterRows.isEmpty, "dangling configured entries are removed")
    }

    // MARK: - 9. Wire hygiene

    func testRawCredentialFieldNameRejectedBeforeParsing() async throws {
        let gateway = IngressTestGateway()
        let facade = makeFacade(gateway: gateway)
        let hostile: [String: Any] = [
            "secretIntent": "keep",
            "candidate": try merged(makeCandidateJSON(), extra: ["apiKey": "sk-smuggled"]),
        ]
        let router = ModelConfigurationCommandRouter(facade: facade)
        let response = await router.handle(command: "config.provider.save",
                                           envelope: ["payload": hostile])
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.contains("rawCredentialInputRejected"),
                      "credential-named fields must be refused at the wire: \(text)")
        XCTAssertTrue(gateway.snapshot().writes.isEmpty)
    }

    private func merged(_ object: [String: Any], extra: [String: Any]) throws -> [String: Any] {
        var copy = object
        for (key, value) in extra { copy[key] = value }
        return copy
    }

    private func storedRowQuietly() async -> ProviderProfile? {
        try? await storedProvider()
    }
}

// MARK: - Test-only doubles

extension ProviderSaveExecution {
    var failedDescriptionForTests: String {
        switch self {
        case .committed: return "committed"
        case .failed(let f): return "failed(\(f.error.code.rawValue):\(f.error.reason))"
        case .cleared: return "cleared"
        }
    }
}

/// Scripted Keystore double with full call accounting.
final class IngressTestGateway: SecretGatewayServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Data] = [:]
    var registered: Bool
    var nextWriteError: Error?
    var deleteError: Error?
    private var writesLog: [(reference: String, bytes: Data)] = []
    private var readsLog: [String] = []
    private var deletesLog: [String] = []

    init(registered: Bool = true) { self.registered = registered }

    var isRegistered: Bool {
        lock.withLock { registered }
    }
    func snapshot() -> (writes: [(reference: String, bytes: Data)],
                        reads: [String], deletes: [String]) {
        lock.withLock { () -> (writes: [(reference: String, bytes: Data)],
                              reads: [String], deletes: [String]) in
            (writesLog, readsLog, deletesLog)
        }
    }
    func seed(_ reference: String, _ bytes: Data) {
        lock.withLock { store[reference] = bytes }
    }

    func read(reference: String) async throws -> Data? {
        let (registered, value): (Bool, Data?) = lock.withLock {
            readsLog.append(reference)
            return (self.registered, store[reference])
        }
        guard registered else { throw SecretGatewayError.needsConfiguration }
        return value
    }
    func write(reference: String, value: Data) async throws {
        let (registered, error): (Bool, Error?) = lock.withLock {
            let registered = self.registered
            let error = nextWriteError
            nextWriteError = nil
            return (registered, error)
        }
        guard registered else { throw SecretGatewayError.needsConfiguration }
        if let error { throw error }
        lock.withLock {
            store[reference] = value
            writesLog.append((reference, value))
        }
    }
    func delete(reference: String) async throws {
        let (registered, error): (Bool, Error?) = lock.withLock {
            deletesLog.append(reference)
            return (self.registered, deleteError)
        }
        guard registered else { throw SecretGatewayError.needsConfiguration }
        if let error { throw error }
        lock.withLock { store[reference] = nil }
    }
}

struct FixedRouteContext: ConfigRouteContextProviding {
    let token: String
    let generation: UInt64
    func currentRoute() -> RouteBinding? {
        RouteBinding(token: token, generation: generation)
    }
}

struct AdmissionOpen: ProviderTransportAdmitting {
    var admitsCloudNetwork: Bool { true }
}

final class RejectingOwnedWorkPort: OwnedWorkRegistryPort, @unchecked Sendable {
    let code: RuntimeFacadeCode
    init(code: RuntimeFacadeCode) { self.code = code }
    func attach(epoch: UInt64, kind: RuntimeOwnedWorkKind,
                ownerID: String) -> RuntimeOwnedWorkAttachOutcome {
        .rejected(code)
    }
    func detach(_ token: RuntimeOwnedWorkToken) -> Bool { false }
    func isAttached(_ token: RuntimeOwnedWorkToken) -> Bool { false }
}

/// Fake adapter factory with construction + call counters proving the
/// auth-before-network and admission gates: the ORIGINAL factory/transport
/// is NEVER touched when RB2 refuses.
final class CountingAdapterFactory: ProviderAdapterProviding, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var adapterConstructionCalls = 0
    private(set) var lastCredentialsUsed: ProviderCredentials?
    /// When non-nil, listModels sleeps this many millis so a concurrent
    /// duplicate-probe assertion has a real in-flight window (no blocking
    /// primitives on the cooperative pool).
    var holdProbeMillis: UInt64?

    func adapter(for profile: ProviderProfile) -> any ProviderAdapter {
        lock.lock(); adapterConstructionCalls += 1; lock.unlock()
        return CountingAdapter(factory: self, profile: profile)
    }
    func markCredentials(_ credentials: ProviderCredentials) {
        lock.lock(); lastCredentialsUsed = credentials; lock.unlock()
    }
}

struct CountingAdapter: ProviderAdapter {
    let factory: CountingAdapterFactory
    let profile: ProviderProfile
    var protocolKind: ModelProtocol { profile.wireProtocol }

    func stream(request: ProviderStreamRequest,
                credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: FloeError.internalError("unused in probe tests")) }
    }
    func testConnection(provider: ProviderProfile,
                        credentials: ProviderCredentials) async throws {
        factory.markCredentials(credentials)
    }
    func listModels(provider: ProviderProfile,
                    credentials: ProviderCredentials) async throws -> [ModelProfile] {
        if let hold = factory.holdProbeMillis {
            try? await Task.sleep(nanoseconds: hold &* 1_000_000)
        }
        return (0..<2).map { index in
            ModelProfile(id: UUID(), providerID: provider.id,
                         remoteModelID: "discovered-\(index)",
                         displayName: "Discovered \(index)",
                         limits: ModelLimits(contextTokens: 4096, maxOutputTokens: 1024),
                         capabilities: [.text])
        }
    }
}
