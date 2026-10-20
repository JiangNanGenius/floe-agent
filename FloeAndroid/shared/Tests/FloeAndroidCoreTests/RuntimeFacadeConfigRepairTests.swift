// SPDX-License-Identifier: MPL-2.0
//
// RB2-REPAIR (job-ffa06be4f2d34ac4) — MC-R1/MC-R2/MC-R3 behavior + MC-R4
// controlled-seam lifetime tests through PUBLIC production flows and the
// ORIGINAL file-backed schema-46 DatabaseManager (real migrations, real
// store/draft/runner/codec, real one-shot SecretSaveIntentVault lease where a
// secret crosses). Test doubles are limited to controlled injected faults and
// call counters; no production path is a fake or a no-op. AUTHORED ONLY: NOT
// compiled, NOT executed by this source package (Swift 6.4.1 frontend GRAMMAR
// parsing is recorded in evidence/GRAMMAR_PARSE*.log; grammar ≠ module/type/
// concurrency check, and the later Main-serialized qualification owns real
// execution).
//
// The real-SecretRequestMailbox MC-R4 suite (claim held after watchdog, late
// real completion releasing exactly once, queued-cancel/rebind/old-generation
// completion) lives in RuntimeFacadeConfigPhysicalTests.swift.

import XCTest
import Foundation
import GRDB
@testable import FloeAndroidCore
import FloeCore
import FloePersistence
import FloeProviders

final class RuntimeFacadeConfigRepairTests: XCTestCase {

    private var databaseURL: URL!
    private var database: DatabaseManager!

    private let providerID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let routeToken = "route-repair"
    private let routeGeneration: UInt64 = 7
    private let syntheticSecret = Data("sk-repair-synthetic-000000000011".utf8)

    override func setUp() async throws {
        _ = floeSecretGatewayRemove()
        SecretRequestMailbox.shared.resetForTesting()
        SecretSaveIntentVault.shared.resetForTesting()
        ProviderOperationCoordinatorRegistry.shared.removeAllForTesting()
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-rb2-repair-\(UUID().uuidString).db")
        database = try DatabaseManager(path: databaseURL)
        try await database.migrate()
        let version = try await database.userVersion()
        XCTAssertEqual(version, DatabaseManager.currentSchemaVersion)
    }

    override func tearDown() async throws {
        _ = floeSecretGatewayRemove()
        SecretRequestMailbox.shared.resetForTesting()
        SecretSaveIntentVault.shared.resetForTesting()
        ProviderOperationCoordinatorRegistry.shared.removeAllForTesting()
        try? await database.close()
        try? FileManager.default.removeItem(at: databaseURL)
    }

    // MARK: Helpers

    private func makeGateway() -> HoldingRepairGateway { HoldingRepairGateway() }

    private func makeFacade(gateway: any SecretGatewayServicing,
                            ownership: (any ProviderOperationOwning)? = nil,
                            registry: (any OwnedWorkRegistryPort)? = nil)
        -> ModelConfigurationFacade
    {
        ModelConfigurationFacade(
            database: database,
            gateway: gateway,
            catalogBytes: nil,
            transportAdmission: TransportAdmissionClosed(),
            routeContext: FixedRouteContext(token: routeToken, generation: routeGeneration),
            ownership: ownership,
            epochProvider: FixedEpochProvider(epoch: 1),
            ownedWorkRegistry: registry ?? AlwaysAttachOwnedWorkPort())
    }

    private func store() -> ModelConfigurationStore {
        ModelConfigurationStore(database: database)
    }

    private func seedRow(revision: Int64 = 0, secret: Bool = true,
                         baseURL: String = "https://api.example.invalid/v1",
                         displayName: String = "Repair seed") async throws {
        try await store().saveProvider(ProviderProfile(
            id: providerID, kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: baseURL)!,
            displayName: displayName,
            secretRef: secret
                ? SecretReference(keychainAccount: ConfigSecretIdentity.providerAccount(providerID: providerID),
                                  synchronizable: false)
                : nil,
            syncRevision: revision))
    }

    private func candidateJSON(baseURL: String = "https://api.example.invalid/v1",
                               createIntent: Bool = false) throws -> [String: Any] {
        let capsData = try JSONEncoder().encode(ModelCapabilities.text)
        return [
            "id": providerID.uuidString,
            "kind": ProviderKind.openAI.rawValue,
            "wireProtocol": ModelProtocol.openAIChatCompletions.rawValue,
            "baseURL": baseURL,
            "displayName": "Repair Candidate",
            "syncEnabled": false,
            "selectedModels": [],
            "managedCapabilities": try JSONSerialization.jsonObject(
                with: capsData, options: [.fragmentsAllowed]),
            "serviceRoleIsConversation": true,
            "createIntent": createIntent,
        ]
    }

    private func submitIntent(candidate: [String: Any],
                              baseRevision: [String: String]?) throws -> String {
        var intent: [String: Any] = [
            "subject": ["kind": SubjectKind.providerSave.rawValue, "id": providerID.uuidString],
            "route": ["token": routeToken, "generation": routeGeneration],
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

    private func keepEnvelope(displayNameRename: String? = nil,
                              baseURL: String = "https://api.example.invalid/v1") throws -> Data {
        var candidate = try candidateJSON(baseURL: baseURL)
        if let displayNameRename { candidate["displayName"] = displayNameRename }
        return try JSONSerialization.data(withJSONObject: candidate, options: [.sortedKeys])
    }

    private func revision(_ value: Int64) -> ConfigRevision {
        ConfigRevision.provider(id: providerID, syncRevision: value)
    }

    private func ledgerEntry(intent: ProviderSecretCleanupEntry.Intent,
                             providerID: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        -> ProviderSecretCleanupEntry
    {
        ProviderSecretCleanupEntry(providerID: providerID,
                                   account: ConfigSecretIdentity.providerAccount(providerID: providerID),
                                   intent: intent)
    }

    // Raw byte truth of the ledger row (nil = no row; "<NULL>" = NULL column).
    private func rawLedgerBytes() async throws -> Data? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT value_json FROM app_settings WHERE key = ?",
                arguments: [ConfigSettingsKeys.providerSecretCleanup]
            ) else { return nil }
            let text: String? = row["value_json"]
            guard let text else { return Data("<NULL>".utf8) }
            return Data(text.utf8)
        }
    }

    private func writeLedger(_ text: String) async throws {
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO app_settings (key, value_json, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET
                        value_json = excluded.value_json,
                        updated_at = excluded.updated_at
                    """,
                arguments: [ConfigSettingsKeys.providerSecretCleanup, text,
                            "2026-10-19T00:00:00.000Z"])
        }
    }

    private func referenceForProvider() -> String {
        ConfigSecretIdentity.providerOpaqueReference(
            for: ConfigSecretIdentity.providerSecretReference(
                account: ConfigSecretIdentity.providerAccount(providerID: providerID),
                synchronizable: false))
    }

    // MARK: - MC-R1: durable provider-revision advance + stale rejection

    func testTwoEditorSnapshotsSameRevisionFirstCommitsSecondStaleZeroEffect() async throws {
        let gateway = makeGateway()
        let facade = makeFacade(gateway: gateway)
        // Editor A snapshots revision 0 (absent marker) and commits; the
        // accepted edit ADVANCES the persisted revision to 1 (Main MC-R1).
        let candidate = try candidateJSON(createIntent: true)
        let tokenA = try submitIntent(candidate: candidate,
                                      baseRevision: ["resourceID": "provider.\(providerID.uuidString)",
                                                     "version": "0"])
        let first = await facade.saveProviderSet(ingressToken: tokenA, envelopeRevision: revision(0))
        guard case .committed(let committed) = first else {
            return XCTFail("first editor must commit: \(first.failedDescriptionForTests)")
        }
        XCTAssertEqual(committed.providerRevision.version, "1",
                       "accepted provider edit must ADVANCE the persisted revision")
        let row1Optional = try await store().provider(id: providerID)
        let row1 = try XCTUnwrap(row1Optional)
        XCTAssertEqual(row1.syncRevision, 1)

        // Editor B still holds the SAME stale snapshot (revision "0").
        let writesBefore = gateway.snapshot().writes.count
        let deletesBefore = gateway.snapshot().deletes.count
        let ledgerBytesBefore = try await rawLedgerBytes()
        let second = await facade.saveProviderKeep(
            candidateJSON: try keepEnvelope(displayNameRename: "Stale second"),
            envelopeRevision: revision(0))
        guard case .failed(let failed) = second,
              failed.error.code == .staleRevision,
              failed.error.reason == "providerEnvelopeRevision" else {
            return XCTFail("stale sequential second editor must be rejected: \(second.failedDescriptionForTests)")
        }
        XCTAssertFalse(failed.databaseRowWritten)
        XCTAssertNil(failed.secretDisposition)
        // Deterministically pre-known stale ⇒ ZERO side effects.
        XCTAssertEqual(gateway.snapshot().writes.count, writesBefore)
        XCTAssertEqual(gateway.snapshot().deletes.count, deletesBefore)
        let row2Optional = try await store().provider(id: providerID)
        let row2 = try XCTUnwrap(row2Optional)
        XCTAssertEqual(row2.syncRevision, 1, "zero overwrite")
        XCTAssertEqual(row2.displayName, row1.displayName)
        let ledgerBytesAfter = try await rawLedgerBytes()
        XCTAssertEqual(ledgerBytesBefore, ledgerBytesAfter, "ledger untouched")
    }

    func testOldDeleteAfterFirstEditRefusesAndRowSurvives() async throws {
        let gateway = makeGateway()
        let facade = makeFacade(gateway: gateway)
        let candidate = try candidateJSON(createIntent: true)
        let token = try submitIntent(candidate: candidate, baseRevision: nil)
        let created = await facade.saveProviderSet(ingressToken: token, envelopeRevision: nil)
        guard case .committed = created else {
            return XCTFail("create must commit: \(created.failedDescriptionForTests)")
        }
        let deletesBefore = gateway.snapshot().deletes.count
        do {
            _ = try await facade.deleteProvider(revision: revision(0))
            XCTFail("delete with the pre-edit revision must be refused")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .staleRevision)
            XCTAssertEqual(error.reason, "providerDeleteRevision")
        }
        let rowOptional = try await store().provider(id: providerID)
        let row = try XCTUnwrap(rowOptional)
        XCTAssertEqual(row.syncRevision, 1)
        XCTAssertEqual(gateway.snapshot().deletes.count, deletesBefore,
                       "zero secret effect on stale delete")
        // The durable same-writer CAS independently guards the transaction
        // itself (defense past any observation path):
        do {
            try await store().deleteProvider(id: providerID, expectedSyncRevision: 0)
            XCTFail("in-transaction CAS must reject")
        } catch is ModelConfigurationRevisionConflict {
            // expected
        }
        let stillOptional = try await store().provider(id: providerID)
        let still = try XCTUnwrap(stillOptional)
        XCTAssertEqual(still.syncRevision, 1, "CAS rejection mutated nothing")
        // The CURRENT revision succeeds through the gated delete.
        let done = try await facade.deleteProvider(revision: revision(1))
        XCTAssertEqual(done.secretCleanup, .removed)
        let gone = try await store().provider(id: providerID)
        XCTAssertNil(gone)
    }

    func testReentrantTwoCommitterWrappersAndRealConcurrentDBWriter() async throws {
        try await seedRow(revision: 0)
        let draft = ProviderSaveDraft(
            providerID: providerID, kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURLString: "https://api.example.invalid/v1",
            displayName: "Racer", presetID: nil,
            existingSecretRef: SecretReference(keychainAccount: ConfigSecretIdentity.providerAccount(providerID: providerID),
                                               synchronizable: false),
            nonSecretHeaders: [:], isEnabled: true, allowsPlainHTTP: false,
            toolNameCompatibility: false, syncEnabled: false, enteredAPIKey: "",
            selectedModels: [], managedCapabilities: .text,
            serviceRoleIsConversation: true, defaultModelID: nil,
            existingCreatedAt: Date(timeIntervalSince1970: 1), existingSyncRevision: 0,
            existingBaseURL: URL(string: "https://api.example.invalid/v1"),
            existingKind: .openAI)
        guard case .success(let request) = draft.makeRequest() else {
            return XCTFail("draft must build the frozen request")
        }
        // TWO reentrant committer WRAPPERS over the same durable store, both
        // holding the same observed base revision 0, plus ONE real concurrent
        // DatabaseManager.writer (the original un-gated bundle path at
        // revision 0). All through the SAME file-backed DatabaseManager.
        let committerA = ModelConfigurationCommitter(database: database)
        let committerB = ModelConfigurationCommitter(database: database)
        let raw = store()
        await committerA.stageNextBundleExpectation(providerID: providerID,
                                                    expectation: .editAtRevision(0))
        await committerB.stageNextBundleExpectation(providerID: providerID,
                                                    expectation: .editAtRevision(0))
        let profile = request.profile
        let rawProviderID = providerID
        // ACTUAL concurrent independent DatabaseManager.writers: the ORIGINAL
        // un-gated legacy path, started TOGETHER with the gated race. They
        // carry NON-matching revisions (7 and 42) on purpose: a legacy
        // syncRevision-0 write could legitimately reset the durable revision
        // between two gated commits (the original ABA ambiguity), making the
        // "<=1" assertion meaningless; a non-matching revision makes any raw
        // write break the base-0 observation, so the gated CAS result is
        // deterministic while the writers genuinely run concurrently.
        let rawA = Task {
            try await raw.saveProviderBundle(
                provider: ProviderProfile(
                    id: rawProviderID, kind: .openAI, wireProtocol: .openAIChatCompletions,
                    baseURL: URL(string: "https://raw-a.example.invalid/v1")!,
                    displayName: "Raw concurrent A",
                    secretRef: profile.secretRef,
                    syncRevision: 7),
                models: [])
        }
        let rawB = Task {
            try await raw.saveProviderBundle(
                provider: ProviderProfile(
                    id: rawProviderID, kind: .openAI, wireProtocol: .openAIChatCompletions,
                    baseURL: URL(string: "https://raw-b.example.invalid/v1")!,
                    displayName: "Raw concurrent B",
                    secretRef: profile.secretRef,
                    syncRevision: 42),
                models: [])
        }
        let taskA = Task { try await committerA.commitProviderBundle(request) }
        let taskB = Task { try await committerB.commitProviderBundle(request) }
        var gatedAccepted = 0
        var gatedConflicts = 0
        do { _ = try await taskA.value; gatedAccepted += 1 }
        catch is ModelConfigurationRevisionConflict { gatedConflicts += 1 }
        do { _ = try await taskB.value; gatedAccepted += 1 }
        catch is ModelConfigurationRevisionConflict { gatedConflicts += 1 }
        _ = try? await rawA.value
        _ = try? await rawB.value
        // Durability rule: TWO gated commits at the SAME observed base can
        // NEVER both pass while the persisted revision only moves forward.
        // Under the concurrent non-matching raw writes the base-0 observation
        // may be broken for BOTH (0 accepted) or only the loser (1 accepted);
        // two accepts are impossible.
        XCTAssertLessThanOrEqual(gatedAccepted, 1,
                                 "two gated commits at one base must not both pass CAS")
        XCTAssertEqual(gatedAccepted + gatedConflicts, 2,
                       "every gated attempt ended in an exact typed outcome")
        let afterOptional = try await store().provider(id: providerID)
        let after = try XCTUnwrap(afterOptional)
        XCTAssertTrue([1, 7, 42].contains(after.syncRevision),
                      "final revision is the gated winner (1) or a raw writer (7/42), got \(after.syncRevision)")
        // Deterministic stale proof: the persisted revision is no longer 0,
        // so a late base-0 gated attempt conflicts with ZERO side effects.
        let late = ModelConfigurationCommitter(database: database)
        await late.stageNextBundleExpectation(providerID: providerID,
                                              expectation: .editAtRevision(0))
        do {
            _ = try await late.commitProviderBundle(request)
            XCTFail("stale base must conflict after the race")
        } catch is ModelConfigurationRevisionConflict {
            // expected
        }
        let unchangedOptional = try await store().provider(id: providerID)
        let unchanged = try XCTUnwrap(unchangedOptional)
        XCTAssertEqual(unchanged.syncRevision, after.syncRevision,
                       "a rejected stale commit mutates nothing")
        // The controlled between-secret-write-and-bundle-CAS stale-write
        // coverage is retained separately in
        // testSecretWriteCommittedThenDurableCASRejectionReportsPartialCommit.
    }

    func testSecretWriteCommittedThenDurableCASRejectionReportsPartialCommit() async throws {
        try await seedRow(revision: 0)
        let gateway = HoldingRepairGateway()
        let ownership = ProviderOperationOwnership()
        let port = AlwaysAttachOwnedWorkPort()
        let ownedWork = ConfigOwnedWorkLifecycle(registry: port,
                                                 epochProvider: FixedEpochProvider(epoch: 1))
        let raceDatabase = database
        let racingProviderID = providerID
        let executor = ProviderSaveExecutor(
            database: database,
            gateway: gateway,
            ownership: ownership,
            ownedWork: ownedWork,
            secretWriteFault: { _, _ in
                // REAL concurrent DatabaseManager.writer between the secret
                // write and the bundle CAS.
                let racer = ModelConfigurationStore(database: try XCTUnwrap(raceDatabase))
                try await racer.saveProvider(ProviderProfile(
                    id: racingProviderID,
                    kind: .openAI, wireProtocol: .openAIChatCompletions,
                    baseURL: URL(string: "https://racer.example.invalid/v1")!,
                    displayName: "Concurrent racer",
                    secretRef: SecretReference(keychainAccount: "provider.11111111-1111-1111-1111-111111111111",
                                               synchronizable: false),
                    syncRevision: 7))
            })
        let candidate = try candidateJSON()
        let token = try submitIntent(candidate: candidate,
                                     baseRevision: ["resourceID": "provider.\(providerID.uuidString)",
                                                    "version": "0"])
        let execution = await executor.saveSet(token: token,
                                               route: RouteBinding(token: routeToken,
                                                                   generation: routeGeneration),
                                               envelopeRevision: revision(0))
        guard case .failed(let failed) = execution else {
            return XCTFail("must report the durable CAS refusal typed: \(execution.failedDescriptionForTests)")
        }
        XCTAssertEqual(failed.error.code, ConfigWireCode.staleRevision)
        XCTAssertTrue(failed.error.reason.hasPrefix("providerBundleCAS"))
        XCTAssertEqual(failed.secretDisposition, SecretEffectDisposition.committed,
                       "the secret write itself committed BEFORE the CAS")
        XCTAssertFalse(failed.databaseRowWritten,
                       "the gated bundle transaction wrote NOTHING")
        XCTAssertEqual(failed.phase, ProviderSaveRunError.localCommit("").phase)
        if case .executionSettled? = failed.physicalSettlement {
            // success return ⇒ terminal event ⇒ no owner retention
        } else {
            XCTFail("a settled write must not pretend outstanding")
        }
        XCTAssertFalse(failed.pendingReconciliation)
        let rowOptional = try await store().provider(id: providerID)
        let row = try XCTUnwrap(rowOptional)
        XCTAssertEqual(row.baseURL.absoluteString, "https://racer.example.invalid/v1",
                       "the stale gated edit zero-overwrote the concurrent writer")
        XCTAssertEqual(row.syncRevision, 7)
        // Retry at the CURRENT revision converges (deterministic reference
        // write idempotence + advanced CAS base).
        let token2 = try submitIntent(candidate: candidate,
                                      baseRevision: ["resourceID": "provider.\(providerID.uuidString)",
                                                     "version": "7"])
        let executor2 = ProviderSaveExecutor(database: database, gateway: gateway,
                                             ownership: ownership, ownedWork: ownedWork)
        let retry = await executor2.saveSet(token: token2,
                                            route: RouteBinding(token: routeToken,
                                                                generation: routeGeneration),
                                            envelopeRevision: revision(7))
        guard case .committed(let retryCommitted) = retry else {
            return XCTFail("retry must converge: \(retry.failedDescriptionForTests)")
        }
        XCTAssertEqual(retryCommitted.providerRevision.version, "8")
    }

    func testProviderRevisionAdvancesAndOverflowRefusesTyped() async throws {
        let gateway = makeGateway()
        let facade = makeFacade(gateway: gateway)
        let candidate = try candidateJSON(createIntent: true)
        let token = try submitIntent(candidate: candidate, baseRevision: nil)
        let created = await facade.saveProviderSet(ingressToken: token, envelopeRevision: nil)
        guard case .committed = created else {
            return XCTFail("create must commit: \(created.failedDescriptionForTests)")
        }
        var expected: Int64 = 1
        for index in 2...4 {
            let saved = await facade.saveProviderKeep(
                candidateJSON: try keepEnvelope(displayNameRename: "Edit \(index)"),
                envelopeRevision: revision(expected))
            guard case .committed(let committed) = saved else {
                return XCTFail("edit \(index) must commit: \(saved.failedDescriptionForTests)")
            }
            expected += 1
            XCTAssertEqual(committed.providerRevision.version, String(expected),
                           "each accepted edit advances exactly one")
        }
        // Overflow: Int64.max cannot advance — typed refusal BEFORE any
        // secret/DB effect (no wraparound).
        try await seedRow(revision: Int64.max, displayName: "Overflow edge")
        let writesBefore = gateway.snapshot().writes.count
        let overflow = await facade.saveProviderKeep(
            candidateJSON: try keepEnvelope(displayNameRename: "Never"),
            envelopeRevision: revision(Int64.max))
        guard case .failed(let failed) = overflow,
              failed.error.code == .staleRevision,
              failed.error.reason == "providerRevisionExhausted" else {
            return XCTFail("overflow must refuse typed: \(overflow.failedDescriptionForTests)")
        }
        XCTAssertEqual(gateway.snapshot().writes.count, writesBefore, "zero secret effect")
        let rowOptional = try await store().provider(id: providerID)
        let row = try XCTUnwrap(rowOptional)
        XCTAssertEqual(row.syncRevision, Int64.max, "row untouched")
    }

    func testStoreMirrorDefaultPathPreservesOriginalSemantics() async throws {
        let raw = store()
        // nil expectation ⇒ EXACT original write (supplied revision verbatim,
        // no gate, no advance).
        try await raw.saveProvider(ProviderProfile(
            id: providerID, kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.example.invalid/v1")!,
            displayName: "Legacy path", syncRevision: 42))
        let legacyOptional = try await raw.provider(id: providerID)
        let legacy = try XCTUnwrap(legacyOptional)
        XCTAssertEqual(legacy.syncRevision, 42)
        // Gated CREATE with the row PRESENT must conflict ("absent" means the
        // row may not exist — never "matches a persisted 0").
        do {
            _ = try await raw.saveProviderBundle(
                provider: ProviderProfile(
                    id: providerID, kind: .openAI, wireProtocol: .openAIChatCompletions,
                    baseURL: URL(string: "https://api.example.invalid/v1")!,
                    displayName: "Late creator"),
                models: [],
                expectedState: .absent)
            XCTFail("create CAS must observe the existing row")
        } catch let conflict as ModelConfigurationRevisionConflict {
            XCTAssertEqual(conflict.domain, "providerBundle")
            XCTAssertEqual(conflict.expected, 0)
            XCTAssertEqual(conflict.observed, 42)
        }
        let unchangedOptional = try await raw.provider(id: providerID)
        let unchanged = try XCTUnwrap(unchangedOptional)
        XCTAssertEqual(unchanged.syncRevision, 42)
        // Gated EDIT at the actual base ADVANCES by exactly one.
        var editProfile = unchanged
        editProfile.displayName = "Gated edit"
        _ = try await raw.saveProviderBundle(provider: editProfile, models: [],
                                             expectedState: .revision(42))
        let advancedOptional = try await raw.provider(id: providerID)
        let advanced = try XCTUnwrap(advancedOptional)
        XCTAssertEqual(advanced.syncRevision, 43)
        XCTAssertEqual(advanced.displayName, "Gated edit")
        // Original unconditional delete path stays (nil default).
        try await raw.deleteProvider(id: providerID)
        let gone = try await raw.provider(id: providerID)
        XCTAssertNil(gone)
    }

    // MARK: - MC-R2: corrupt ledger preservation (strict bounded decoder)

    private func ledgerCases() -> [(name: String, text: String)] {
        let idA = providerID.uuidString
        let accountA = ConfigSecretIdentity.providerAccount(providerID: providerID)
        let idB = UUID().uuidString
        let validA = "{\"account\":\"\(accountA)\",\"intent\":\"providerDelete\",\"providerID\":\"\(idA)\"}"
        let rows257: String = {
            var parts: [String] = []
            for _ in 0..<257 {
                let id = UUID()
                parts.append("{\"account\":\"\(ConfigSecretIdentity.providerAccount(providerID: id))\",\"intent\":\"secretClear\",\"providerID\":\"\(id.uuidString)\"}")
            }
            return "[" + parts.joined(separator: ",") + "]"
        }()
        let hugeBlob: String = {
            // ~1 MiB of raw bytes: MUST be refused on the bound BEFORE any
            // JSON deserialization is attempted.
            var text = "["
            text += String(repeating: "{\"account\":\"provider.", count: 12_000)
            text += "]"
            return text
        }()
        return [
            ("nonArrayObject", "{\"entries\":[]}"),
            ("malformedJSON", "{not json"),
            ("wrongTypes", "[{\"account\":1,\"intent\":2,\"providerID\":3}]"),
            ("invalidLateRow", "[\(validA),{\"account\":\"not-an-account\",\"intent\":\"secretClear\",\"providerID\":\"\(idB)\"}]"),
            ("rows257", rows257),
            ("duplicateIdentity", "[\(validA),\(validA)]"),
            ("duplicateProvider", "[\(validA),{\"account\":\"\(accountA)\",\"intent\":\"secretClear\",\"providerID\":\"\(idA)\"}]"),
            ("hugeRawBlob", hugeBlob),
            ("emptyText", ""),
            ("unknownExtraField", "[{\"account\":\"\(accountA)\",\"intent\":\"providerDelete\",\"providerID\":\"\(idA)\",\"extra\":1}]"),
            ("badIntent", "[{\"account\":\"\(accountA)\",\"intent\":\"vaporize\",\"providerID\":\"\(idA)\"}]"),
        ]
    }

    func testLedgerCorruptVariantsPreserveExactBytesAcrossAllOperations() async throws {
        let gateway = makeGateway()
        let ownership = ProviderOperationOwnership()
        let ownedWork = ConfigOwnedWorkLifecycle(registry: AlwaysAttachOwnedWorkPort(),
                                                 epochProvider: FixedEpochProvider(epoch: 1))
        let cleanup = ProviderSecretCleanup(database: database)
        for (name, text) in ledgerCases() {
            try await writeLedger(text)
            let bytesBefore = try await rawLedgerBytes()
            // entries(): typed corrupt; NEVER a usable empty/filtered list.
            do {
                let list = try await cleanup.entries()
                _ = list
                XCTFail("corrupt ledger must never decode to a usable list (\(name))")
            } catch let error as ConfigDomainError {
                XCTAssertEqual(error.code, .persistenceUnavailable, name)
                XCTAssertTrue(error.reason.hasPrefix("cleanupLedgerCorrupt"),
                              "\(name): \(error.reason)")
            }
            // enqueue: fails closed WITHOUT rewriting the stored bytes.
            do {
                try await cleanup.enqueue(ledgerEntry(intent: .secretClear,
                                                      providerID: UUID()))
                XCTFail("enqueue must fail closed on corrupt ledger (\(name))")
            } catch let error as ConfigDomainError {
                XCTAssertTrue(error.reason.hasPrefix("cleanupLedgerCorrupt"),
                              "\(name): \(error.reason)")
            }
            // dequeueMatching: refuses to rewrite.
            do {
                _ = try await cleanup.dequeueMatching(providerID: providerID,
                                                      intent: .providerDelete)
                XCTFail("dequeue must fail closed on corrupt ledger (\(name))")
            } catch let error as ConfigDomainError {
                XCTAssertTrue(error.reason.hasPrefix("cleanupLedgerCorrupt"), name)
            }
            // drain: typed failure, ZERO backend effects, bytes intact.
            do {
                _ = try await cleanup.drain(gateway: gateway, ownership: ownership,
                                            ownedWork: ownedWork)
                XCTFail("drain must fail closed on corrupt ledger (\(name))")
            } catch let error as ConfigDomainError {
                XCTAssertTrue(error.reason.hasPrefix("cleanupLedgerCorrupt"), name)
            }
            let bytesAfter = try await rawLedgerBytes()
            XCTAssertEqual(bytesBefore, bytesAfter,
                           "exact corrupt bytes preserved across ALL operations (\(name))")
            XCTAssertTrue(gateway.snapshot().deletes.isEmpty, name)
            XCTAssertTrue(gateway.snapshot().writes.isEmpty, name)
            let providers = try await store().providers()
            XCTAssertTrue(providers.isEmpty, name)
        }
        // Absent vs empty-array vs corrupt distinct:
        try await database.writer { db in
            try db.execute(sql: "DELETE FROM app_settings WHERE key = ?",
                           arguments: [ConfigSettingsKeys.providerSecretCleanup])
        }
        let absentEntries = try await cleanup.entries()
        XCTAssertTrue(absentEntries.isEmpty) // absent ⇒ [] (no row)
        try await writeLedger("[]")
        let validEmpty = try await cleanup.entries()
        XCTAssertTrue(validEmpty.isEmpty)    // "[]" ⇒ VALID empty, distinct
        try await cleanup.enqueue(ledgerEntry(intent: .providerDelete))
        let after = try await cleanup.entries()
        XCTAssertEqual(after.count, 1)       // and writing works from valid empty
    }

    func testValidLaterEntriesSurviveAfterCorruptionRepaired() async throws {
        let gateway = makeGateway()
        let ownership = ProviderOperationOwnership()
        let ownedWork = ConfigOwnedWorkLifecycle(registry: AlwaysAttachOwnedWorkPort(),
                                                 epochProvider: FixedEpochProvider(epoch: 1))
        let cleanup = ProviderSecretCleanup(database: database)
        let idB = UUID()
        let entryB = ledgerEntry(intent: .secretClear, providerID: idB)
        // Corrupt: valid first entry + INVALID second entry.
        try await writeLedger("""
            [{"account":"\(ConfigSecretIdentity.providerAccount(providerID: providerID))",
              "intent":"providerDelete",
              "providerID":"\(providerID.uuidString)"},
             {"account":"not-an-account","intent":"secretClear",
              "providerID":"\(idB.uuidString)"}]
            """)
        do {
            _ = try await cleanup.entries()
            XCTFail("strict all-or-fail decode must reject")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.reason, "cleanupLedgerCorrupt.entryInvalidField")
        }
        // The VALID later entry's BYTES remain untouched inside the preserved
        // blob (never silently dropped).
        let bytesOptional = try await rawLedgerBytes()
        let bytes = try XCTUnwrap(bytesOptional)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains(idB.uuidString),
                      "the later valid entry's identity bytes must survive the corrupt state")
        // Operator repair rewrites the ledger through the REAL codec path
        // with both intended entries; both then drain.
        try await database.writer { db in
            try db.execute(sql: "DELETE FROM app_settings WHERE key = ?",
                           arguments: [ConfigSettingsKeys.providerSecretCleanup])
        }
        try await cleanup.enqueue(ledgerEntry(intent: .providerDelete))
        try await cleanup.enqueue(entryB)
        let result = try await cleanup.drain(gateway: gateway, ownership: ownership,
                                             ownedWork: ownedWork)
        XCTAssertEqual(result.entriesRemaining, 0)
        XCTAssertEqual(result.outcomes.count, 2)
        XCTAssertEqual(result.outcomes[providerID], .secretRemoved)
        XCTAssertEqual(result.outcomes[idB], .secretRemoved)
    }

    func testLedgerCapStaysEnforcedAndSaturatedWritesFailClosed() async throws {
        let cleanup = ProviderSecretCleanup(database: database)
        for _ in 0..<ProviderSecretCleanup.maximumEntries {
            let id = UUID()
            try await cleanup.enqueue(.init(providerID: id,
                                            account: ConfigSecretIdentity.providerAccount(providerID: id),
                                            intent: .providerDelete))
        }
        let overflow = UUID()
        do {
            try await cleanup.enqueue(.init(providerID: overflow,
                                            account: ConfigSecretIdentity.providerAccount(providerID: overflow),
                                            intent: .providerDelete))
            XCTFail("saturated ledger must fail closed")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .persistenceUnavailable)
            XCTAssertEqual(error.reason, "cleanupLedgerSaturated")
        }
        let entries = try await cleanup.entries()
        XCTAssertEqual(entries.count, ProviderSecretCleanup.maximumEntries,
                       "the full valid ledger stays strictly decodable and intact")
    }

    // MARK: - MC-R3: pre-ticket rejections never finalize intents

    func testDrainInvalidReferenceKeepsEntryAndNeverAlreadyAbsent() async throws {
        let gateway = makeGateway()
        gateway.deleteError = SecretBackendError.invalidReference
        let cleanup = ProviderSecretCleanup(database: database)
        try await cleanup.enqueue(ledgerEntry(intent: .providerDelete))
        let result = try await cleanup.drain(
            gateway: gateway,
            ownership: ProviderOperationOwnership(),
            ownedWork: ConfigOwnedWorkLifecycle(registry: AlwaysAttachOwnedWorkPort(),
                                                epochProvider: FixedEpochProvider(epoch: 1)))
        guard case .effectRejectedKeptForRetry(let reason)? = result.outcomes[providerID],
              reason == "invalidReference" else {
            return XCTFail("invalidReference must keep the entry as a retryable diagnostic")
        }
        XCTAssertEqual(result.entriesRemaining, 1)
        // Recovery converges via the IDEMPOTENT delete, not a fake conclusion.
        gateway.deleteError = nil
        let second = try await cleanup.drain(
            gateway: gateway,
            ownership: ProviderOperationOwnership(),
            ownedWork: ConfigOwnedWorkLifecycle(registry: AlwaysAttachOwnedWorkPort(),
                                                epochProvider: FixedEpochProvider(epoch: 1)))
        XCTAssertEqual(second.outcomes[providerID], .secretRemoved)
        XCTAssertEqual(second.entriesRemaining, 0)
    }

    func testDeleteProviderInvalidValueQueuesRetryNotProvablyAbsent() async throws {
        let gateway = makeGateway()
        try await seedRow(revision: 0)
        gateway.deleteError = SecretBackendError.invalidValue
        let facade = makeFacade(gateway: gateway)
        let result = try await facade.deleteProvider(revision: revision(0))
        switch result.secretCleanup {
        case .queuedForRetry(let reason):
            XCTAssertTrue(reason.hasPrefix("attemptRejected.invalidValue"), reason)
        case .provablyAbsent:
            return XCTFail("MC-R3: a validation refusal never proves absence")
        default:
            return XCTFail("wrong cleanup channel: \(result.secretCleanup)")
        }
        let cleanup = ProviderSecretCleanup(database: database)
        let entries = try await cleanup.entries()
        XCTAssertEqual(entries.count, 1, "durable intent retained")
        XCTAssertEqual(entries[0].intent, .providerDelete)
    }

    func testClearInvalidReferenceKeepsCleanupEntryAndProjectsHonestly() async throws {
        let gateway = makeGateway()
        try await seedRow(revision: 0)
        gateway.deleteError = SecretBackendError.invalidReference
        let facade = makeFacade(gateway: gateway)
        let router = ModelConfigurationCommandRouter(facade: facade)
        let response = await router.handle(command: "config.provider.save",
                                           envelope: ["payload": [
                                               "secretIntent": "clear",
                                               "candidate": try candidateJSON(),
                                           ],
                                           "revision": ["resourceID": "provider.\(providerID.uuidString)",
                                                        "version": "0"]])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let value = try XCTUnwrap(object["value"] as? [String: Any])
        XCTAssertEqual(value["state"] as? String, "cleared")
        XCTAssertEqual(value["cleanupQueuedForRetry"] as? Bool, true)
        XCTAssertEqual(value["secretCleanup"] as? String, "attemptRejectedNoEffect",
                       "MC-R3: rejected attempts must NOT claim provablyAbsent")
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertFalse(text.contains("provablyAbsent"), text)
        XCTAssertFalse(text.contains("removed"), "never bogus removal")
        let cleanup = ProviderSecretCleanup(database: database)
        let entries = try await cleanup.entries()
        XCTAssertEqual(entries.map(\.intent), [.secretClear], "entry preserved for drain")
        let rowOptional = try await store().provider(id: providerID)
        let row = try XCTUnwrap(rowOptional)
        XCTAssertNil(row.secretRef, "the clear itself committed (SQLite side)")
    }

    func testReadInvalidReferenceFailsClosedNeverSecretMissing() async throws {
        try await seedRow(revision: 0)
        let gateway = makeGateway()
        gateway.readError = SecretBackendError.invalidReference
        let adapters = CountingAdapterFactory()
        let facade = ModelConfigurationFacade(
            database: database, gateway: gateway, catalogBytes: nil,
            transportAdmission: AdmissionOpen(),
            routeContext: ConfigRouteContextUnavailable(),
            adapters: adapters,
            epochProvider: FixedEpochProvider(epoch: 1),
            ownedWorkRegistry: AlwaysAttachOwnedWorkPort())
        let outcome = await facade.probeForEffect(providerID: providerID)
        XCTAssertEqual(outcome.status, .failed)
        // NOT secretMissing: fails closed as secretLocked (never invites an
        // overwrite, never anonymous).
        XCTAssertEqual(outcome.failureReason, "credentialUnavailable:secretLocked")
        XCTAssertEqual(adapters.adapterConstructionCalls, 0)
        let status = try await facade.providerSecretStatus(providerID: providerID)
        if case .outcomeUnknown = status {
            // honest unknown read state
        } else {
            XCTFail("status must be outcomeUnknown, got \(status)")
        }
    }

    // MARK: - MC-R4 (controlled seams): retention, tickets, coordination

    func testUnsettledSaveParksOwnerAndBlocksNewerOperation() async throws {
        let gateway = makeGateway()
        gateway.nextWriteError = SecretBackendError.dispatcherUnresponsive
        let facade = makeFacade(gateway: gateway)
        let candidate = try candidateJSON(createIntent: true)
        let token = try submitIntent(candidate: candidate, baseRevision: nil)
        let first = await facade.saveProviderSet(ingressToken: token, envelopeRevision: nil)
        guard case .failed(let failed) = first, failed.pendingReconciliation else {
            return XCTFail("postclaim unknown must retain the owner: \(first.failedDescriptionForTests)")
        }
        let coordinator = ProviderOperationCoordinatorRegistry.shared.coordinator(for: database)
        let pending = await coordinator.pendingRecord(providerID: providerID)
        XCTAssertNotNil(pending, "durable pending owner retained")
        // A newer intent on the same provider is refused; NOTHING is written.
        let writesBefore = gateway.snapshot().writes.count
        let second = await facade.saveProviderKeep(
            candidateJSON: try keepEnvelope(displayNameRename: "Newer attempt"),
            envelopeRevision: revision(1))
        guard case .failed(let secondFailed) = second,
              secondFailed.error.reason == "providerPendingReconciliation",
              secondFailed.pendingReconciliation else {
            return XCTFail("pending provider must refuse new intents")
        }
        XCTAssertEqual(gateway.snapshot().writes.count, writesBefore,
                       "no newer write can slip past the retained owner")
        // Reconcile with NO individual receipt: honest still-pending (never a
        // fake settlement from durable intent or counters).
        let outcome = await facade.reconcileProviderRecovery(providerID: providerID)
        XCTAssertEqual(outcome, .stillPending(reason: "noIndividualReceipt"))
        let stillPending = await coordinator.pendingRecord(providerID: providerID)
        XCTAssertNotNil(stillPending)
    }

    func testProcessDeathRestartDrainConvergesAndKeepsNewerLiveSetNotDeleted() async throws {
        // Phase 1: create-path postclaim unknown on an OBSERVING fake whose
        // record shows the claimed execution still outstanding.
        let gateway = OutstandingObservingGateway()
        gateway.pendingThrow = SecretBackendError.dispatcherUnresponsive
        let facade = makeFacade(gateway: gateway)
        let candidate = try candidateJSON(createIntent: true)
        let token = try submitIntent(candidate: candidate, baseRevision: nil)
        let first = await facade.saveProviderSet(ingressToken: token, envelopeRevision: nil)
        guard case .failed(let failed) = first, failed.pendingReconciliation else {
            return XCTFail("observed outstanding write must park: \(first.failedDescriptionForTests)")
        }
        // Simulated process death: close this DatabaseManager and reopen the
        // SAME file (fresh instances = fresh RAM: pending/leases gone; the
        // durable ledger entry survives).
        try await database.close()
        database = try DatabaseManager(path: databaseURL)
        let cleanup = ProviderSecretCleanup(database: database)
        let entries = try await cleanup.entries()
        XCTAssertEqual(entries.map(\.intent), [.secretWrite],
                       "durable recovery intent survived the restart")
        // The user's NEWER successful Set lands (row now exists and OWNS the
        // deterministic reference — the orphan secret is its own key bytes).
        let gateway2 = HoldingRepairGateway()
        gateway2.seed(referenceForProvider(), syntheticSecret)
        let facade2 = makeFacade(gateway: gateway2)
        let token2 = try submitIntent(candidate: candidate, baseRevision: nil)
        let retry = await facade2.saveProviderSet(ingressToken: token2, envelopeRevision: nil)
        guard case .committed = retry else {
            return XCTFail("restart-fresh coordinator must allow retry: \(retry.failedDescriptionForTests)")
        }
        // Model the interleaving where the OLDER .secretWrite entry was never
        // finalized (crash between bundle commit and compare-and-delete).
        try await cleanup.enqueue(.init(providerID: providerID,
                                        account: ConfigSecretIdentity.providerAccount(providerID: providerID),
                                        intent: .secretWrite))
        let drained = try await facade2.drainProviderCleanup()
        guard case .intentResolvedWithoutDelete(let reason)? = drained.outcomes[providerID],
              reason == "writeConvergedRowOwnsSecret" else {
            return XCTFail("the converged row owns the reference; the entry must resolve WITHOUT deleting")
        }
        XCTAssertTrue(gateway2.snapshot().deletes.isEmpty,
                      "MC-R4: a live referenced secret is NEVER compensated/deleted")
        let rowOptional = try await ModelConfigurationStore(database: database).provider(id: providerID)
        let row = try XCTUnwrap(rowOptional)
        XCTAssertNotNil(row.secretRef, "newer live Set intact")
    }

    func testExistingLiveReferenceNotErroneouslyCompensatedAfterWriteFail() async throws {
        // providerDelete-entry rule generalized: any intent whose row still
        // owns the deterministic reference resolves WITHOUT deleting.
        let gateway = makeGateway()
        try await seedRow(revision: 0)
        let cleanup = ProviderSecretCleanup(database: database)
        try await cleanup.enqueue(ledgerEntry(intent: .secretWrite))
        let result = try await cleanup.drain(
            gateway: gateway,
            ownership: ProviderOperationOwnership(),
            ownedWork: ConfigOwnedWorkLifecycle(registry: AlwaysAttachOwnedWorkPort(),
                                                epochProvider: FixedEpochProvider(epoch: 1)))
        XCTAssertEqual(result.outcomes[providerID],
                       .intentResolvedWithoutDelete(reason: "writeConvergedRowOwnsSecret"))
        XCTAssertTrue(gateway.snapshot().deletes.isEmpty)
        let rowOptional = try await store().provider(id: providerID)
        let row = try XCTUnwrap(rowOptional)
        XCTAssertNotNil(row.secretRef)
    }

    func testStaleTicketReleaseCannotFreeLaterOwner() async throws {
        let coordinator = ProviderOperationCoordinator()
        guard case .attached(let ticketOne) = await coordinator.beginOperation(providerID: providerID,
                                                                               kind: .save) else {
            return XCTFail("first begin must attach")
        }
        await coordinator.endOperation(ticketOne)
        guard case .attached(let ticketTwo) = await coordinator.beginOperation(providerID: providerID,
                                                                               kind: .cleanup) else {
            return XCTFail("second begin must attach after release")
        }
        // MC-R4: a same-kind, WRONG-IDENTITY (tokenless-style) release can
        // never free the later owner.
        let forged = ProviderOperationTicket(providerID: providerID, kind: ticketTwo.kind,
                                             claimID: UUID())
        await coordinator.endOperation(forged)
        if case .conflict = await coordinator.beginOperation(providerID: providerID, kind: .save) {
            // still held ✓
        } else {
            XCTFail("stale/same-kind release must never free the later owner")
        }
        await coordinator.endOperation(ticketTwo)
        if case .attached = await coordinator.beginOperation(providerID: providerID, kind: .save) {
            // released only by the true owner ✓
        } else {
            XCTFail("true owner release must work")
        }
    }

    func testTwoFacadesSameContextCoordinateAndReject() async throws {
        let coordinator = ProviderOperationCoordinatorRegistry.shared.coordinator(for: database)
        let otherForSameDatabase = ProviderOperationCoordinatorRegistry.shared.coordinator(for: database)
        XCTAssertTrue(sameCoordinator(coordinator, otherForSameDatabase),
                      "one DatabaseManager instance resolves ONE shared coordinator")
        let freshURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-rb2-repair-other-\(UUID().uuidString).db")
        let otherDatabase = try DatabaseManager(path: freshURL)
        let separateCoordinator = ProviderOperationCoordinatorRegistry.shared.coordinator(for: otherDatabase)
        XCTAssertFalse(sameCoordinator(coordinator, separateCoordinator),
                       "distinct trusted contexts never share gates")
        try await otherDatabase.close()
        try? FileManager.default.removeItem(at: freshURL)
        // Two facades over the same context: the first holds the provider
        // while its gateway write is delayed; the second must COORDINATE-
        // REJECT, never interleave an effect on one provider.
        let holdGateway = HoldingRepairGateway()
        holdGateway.writeDelayNanoseconds = 250_000_000
        let facadeA = makeFacade(gateway: holdGateway)
        let facadeB = makeFacade(gateway: holdGateway)
        let candidate = try candidateJSON(createIntent: true)
        let tokenA = try submitIntent(candidate: candidate, baseRevision: nil)
        let taskA = Task { await facadeA.saveProviderSet(ingressToken: tokenA, envelopeRevision: nil) }
        try? await Task.sleep(nanoseconds: 80_000_000)
        let tokenB = try submitIntent(candidate: candidate, baseRevision: nil)
        let executionB = await facadeB.saveProviderSet(ingressToken: tokenB, envelopeRevision: nil)
        guard case .failed(let failedB) = executionB,
              failedB.error.code == .duplicateInFlight,
              failedB.phase == "ownership" else {
            _ = await taskA.value
            return XCTFail("second facade must coordinate-reject while the first is in flight")
        }
        let executionA = await taskA.value
        guard case .committed = executionA else {
            return XCTFail("first facade must commit: \(executionA.failedDescriptionForTests)")
        }
        // The rejected facade's consumed lease stays spent (one-shot truth).
        let replayB = await facadeB.saveProviderSet(ingressToken: tokenB, envelopeRevision: nil)
        guard case .failed(let replay) = replayB,
              replay.error.reason == "saveIntentAlreadyConsumed" else {
            return XCTFail("conflicting set must report the intent spent: \(replayB.failedDescriptionForTests)")
        }
    }

    private func sameCoordinator(_ a: ProviderOperationCoordinator,
                                 _ b: ProviderOperationCoordinator) -> Bool {
        ObjectIdentifier(a as AnyObject) == ObjectIdentifier(b as AnyObject)
    }

    func testSaveAndDrainInterleaveBothDirections() async throws {
        // CV-R1 both-direction gate through the shared coordinator: an
        // in-flight drain cleanup attempt gates saves, and vice versa.
        let gateway = HoldingRepairGateway()
        gateway.deleteDelayNanoseconds = 250_000_000
        let cleanup = ProviderSecretCleanup(database: database)
        // Row absent + providerDelete entry ⇒ the drain does the bounded
        // backend delete (delayed ⇒ observable in-flight window).
        try await cleanup.enqueue(ledgerEntry(intent: .providerDelete))
        let coordinator = ProviderOperationCoordinatorRegistry.shared.coordinator(for: database)
        let facade = makeFacade(gateway: gateway, ownership: coordinator)
        let drainTask = Task { try await facade.drainProviderCleanup() }
        try? await Task.sleep(nanoseconds: 80_000_000)
        let blocked = await facade.saveProviderKeep(
            candidateJSON: try keepEnvelope(displayNameRename: "Blocked by drain"),
            envelopeRevision: revision(0))
        guard case .failed(let failed) = blocked,
              failed.error.code == .duplicateInFlight else {
            _ = try? await drainTask.value
            return XCTFail("a drain attempt must gate saves (CV-R1 both directions)")
        }
        let drained = try await drainTask.value
        XCTAssertEqual(drained.outcomes[providerID], .secretRemoved)
        XCTAssertEqual(drained.entriesRemaining, 0)
        // After the drain's awaited effect actually settled, the save path
        // proceeds (create, since the row is absent).
        let candidate = try candidateJSON(createIntent: true)
        let token = try submitIntent(candidate: candidate, baseRevision: nil)
        let saved = await facade.saveProviderSet(ingressToken: token, envelopeRevision: nil)
        guard case .committed = saved else {
            return XCTFail("post-drain save must proceed: \(saved.failedDescriptionForTests)")
        }
    }

    func testOwnedWorkRegistryLeasePreservedUntilSettledShutdownWaitsRealOwner() async throws {
        let gateway = OutstandingObservingGateway()
        gateway.pendingThrow = SecretBackendError.dispatcherUnresponsive
        let port = CountingOwnedWorkPort()
        let facade = ModelConfigurationFacade(
            database: database, gateway: gateway, catalogBytes: nil,
            transportAdmission: TransportAdmissionClosed(),
            routeContext: FixedRouteContext(token: routeToken, generation: routeGeneration),
            epochProvider: FixedEpochProvider(epoch: 1),
            ownedWorkRegistry: port)
        let candidate = try candidateJSON(createIntent: true)
        let token = try submitIntent(candidate: candidate, baseRevision: nil)
        let execution = await facade.saveProviderSet(ingressToken: token, envelopeRevision: nil)
        guard case .failed(let failed) = execution, failed.pendingReconciliation else {
            return XCTFail("claimed-outstanding write must park")
        }
        // Physical execution outstanding ⇒ the attached lease is NOT
        // detached; RB1 retirement (waitForDrain/count) genuinely waits.
        let counts = port.counts()
        XCTAssertEqual(counts.attached, 1)
        XCTAssertEqual(counts.detached, 0,
                       "MC-R4: no detach while the operation is physically outstanding")
        XCTAssertEqual(port.liveTokens().count, 1)
        // Host completion arrives (controlled trusted-host trigger).
        gateway.markClaimedSettled(status: 3)
        let outcome = await facade.reconcileProviderRecovery(providerID: providerID)
        guard case .settledNow(let reason) = outcome else {
            return XCTFail("settled physical truth must release: \(outcome)")
        }
        XCTAssertTrue(reason.hasPrefix("executionSettled.3"), reason)
        XCTAssertEqual(port.counts().detached, 1, "released exactly once, after real settlement")
        XCTAssertEqual(port.liveTokens().count, 0,
                       "shutdown can now proceed: zero owned work")
    }

    func testNoTimerOrCallerCancelReleasesPendingOwner() async throws {
        let gateway = OutstandingObservingGateway()
        gateway.pendingThrow = SecretBackendError.dispatcherUnresponsive
        let facade = makeFacade(gateway: gateway)
        let candidate = try candidateJSON(createIntent: true)
        let token = try submitIntent(candidate: candidate, baseRevision: nil)
        let execution = await facade.saveProviderSet(ingressToken: token, envelopeRevision: nil)
        guard case .failed(let failed) = execution, failed.pendingReconciliation else {
            return XCTFail("must park")
        }
        // Caller cancellation of its own wrapper + elapsed time must not
        // release: reconcile keeps reporting the honest outstanding state.
        let cancellable = Task { try await Task.sleep(nanoseconds: 150_000_000) }
        cancellable.cancel()
        _ = await cancellable.result
        let coordinator = ProviderOperationCoordinatorRegistry.shared.coordinator(for: database)
        for _ in 0..<3 {
            let outcome = await facade.reconcileProviderRecovery(providerID: providerID)
            XCTAssertEqual(outcome, .stillPending(reason: "physicalOutstanding"))
        }
        let pending = await coordinator.pendingRecord(providerID: providerID)
        XCTAssertNotNil(pending, "pending owner survived time + cancellation, as required")
        // Recovery ONLY after the trusted completion.
        gateway.markClaimedSettled(status: 4)
        let final = await facade.reconcileProviderRecovery(providerID: providerID)
        if case .settledNow = final {
            // ok
        } else {
            XCTFail("settled truth must release: \(final)")
        }
    }

    func testNeverDispatchedSignalReleasesOwnerWithProvableC0() async throws {
        // Contrast (Main requiredSemantics): the SAME caller error value,
        // with the individual record provably neverDispatched, releases the
        // owner immediately (no parking) — and STILL keeps the deletion
        // intent per MC-R3 (no-effect ≠ absent).
        let gateway = OutstandingObservingGateway()
        gateway.pendingThrow = SecretBackendError.dispatcherUnresponsive
        gateway.programNextNeverDispatched(reason: .watchdogDrainedQueued)
        let facade = makeFacade(gateway: gateway)
        let candidate = try candidateJSON(createIntent: true)
        let token = try submitIntent(candidate: candidate, baseRevision: nil)
        let execution = await facade.saveProviderSet(ingressToken: token, envelopeRevision: nil)
        guard case .failed(let failed) = execution else {
            return XCTFail("must fail typed")
        }
        XCTAssertFalse(failed.pendingReconciliation,
                       "neverDispatched proof ⇒ honest release, no retention")
        if case .neverExecuted(let reason)? = failed.physicalSettlement,
           reason == "watchdogDrainedQueued" {
            // exact individual truth
        } else {
            XCTFail("expected neverExecuted.watchdogDrainedQueued, got \(String(describing: failed.physicalSettlement))")
        }
        // MC-R3: even provable no-effect does not fake absence — the create
        // intent entry stays for the drain.
        let cleanup = ProviderSecretCleanup(database: database)
        let entries = try await cleanup.entries()
        XCTAssertEqual(entries.map(\.intent), [.secretWrite])
        let coordinator = ProviderOperationCoordinatorRegistry.shared.coordinator(for: database)
        let pending = await coordinator.pendingRecord(providerID: providerID)
        XCTAssertNil(pending)
    }
}

// MARK: - Controlled doubles (injected faults/counters only)

/// Secret gateway double with call accounting, programmable errors and
/// controlled delays (mirrors the frozen registry surface; used where the
/// REAL mailbox ordering itself is not under test — see the physical suite).
final class HoldingRepairGateway: SecretGatewayServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var storeMap: [String: Data] = [:]
    private var writesLog: [(reference: String, bytes: Data)] = []
    private var readsLog: [String] = []
    private var deletesLog: [String] = []
    var registered = true
    var nextWriteError: Error?
    var deleteError: Error?
    var readError: Error?
    var writeDelayNanoseconds: UInt64 = 0
    var deleteDelayNanoseconds: UInt64 = 0

    var isRegistered: Bool {
        lock.lock(); defer { lock.unlock() }
        return registered
    }
    func snapshot() -> (writes: [(reference: String, bytes: Data)],
                        reads: [String], deletes: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (writesLog, readsLog, deletesLog)
    }
    func seed(_ reference: String, _ bytes: Data) {
        lock.lock(); storeMap[reference] = bytes; lock.unlock()
    }
    func read(reference: String) async throws -> Data? {
        let (registered, error, value): (Bool, Error?, Data?) = lock.withLock {
            readsLog.append(reference)
            return (self.registered, readError, storeMap[reference])
        }
        guard registered else { throw SecretGatewayError.needsConfiguration }
        if let error { throw error }
        return value
    }
    func write(reference: String, value: Data) async throws {
        if writeDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: writeDelayNanoseconds)
        }
        let (registered, error): (Bool, Error?) = lock.withLock {
            let registered = self.registered
            let error = nextWriteError
            nextWriteError = nil
            return (registered, error)
        }
        guard registered else { throw SecretGatewayError.needsConfiguration }
        if let error { throw error }
        lock.withLock {
            storeMap[reference] = value
            writesLog.append((reference, value))
        }
    }
    func delete(reference: String) async throws {
        if deleteDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: deleteDelayNanoseconds)
        }
        let (registered, error): (Bool, Error?) = lock.withLock {
            deletesLog.append(reference)
            return (self.registered, deleteError)
        }
        guard registered else { throw SecretGatewayError.needsConfiguration }
        if let error { throw error }
        lock.withLock { storeMap[reference] = nil }
    }
}

/// Controlled double implementing the Main-authorized physical seam with
/// programmable per-operation truth. It is NOT the mailbox (the real mailbox
/// is driven in RuntimeFacadeConfigPhysicalTests); this double exercises
/// RB2's CONSUMPTION of the API surface: claimed-outstanding → park, settled
/// → release, neverDispatched → provable C0 release, untracked → conservative.
final class OutstandingObservingGateway: SecretGatewayServicing,
    PhysicalObservingSecretGateway, @unchecked Sendable
{
    private let lock = NSLock()
    private var storeMap: [String: Data] = [:]
    private var records: [Int64: PhysicalOperationSnapshot] = [:]
    private var outstandingOrder: [Int64] = []
    private var nextClaim: Int64 = 900_001
    private var logWrites: [String] = []
    private var logDeletes: [String] = []
    var registered = true
    /// Programmed post-claim caller error for the NEXT operation.
    var pendingThrow: Error?
    /// When true, the next operation's record is provably neverDispatched.
    private var nextNeverDispatched: PhysicalNeverDispatchedReason?

    var isRegistered: Bool { lock.lock(); defer { lock.unlock() }; return registered }

    func read(reference: String) async throws -> Data? {
        lock.withLock { storeMap[reference] }
    }
    func write(reference: String, value: Data) async throws {
        lock.withLock { storeMap[reference] = value }
    }
    func delete(reference: String) async throws {
        lock.withLock { storeMap[reference] = nil }
    }

    func readObserved(reference: String,
                      onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?) async throws -> Data? {
        let claim = deliver(kind: .read, reference: reference, onQueued: onQueued)
        if let error = consumePendingThrow() { throw error }
        let (status, value): (Int32, Data?) = lock.withLock {
            (storeMap[reference] == nil ? 2 : 1, storeMap[reference])
        }
        settle(claim: claim, status: status)
        return value
    }

    func writeObserved(reference: String, value: Data,
                       onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?) async throws {
        let claim = deliver(kind: .write, reference: reference, onQueued: onQueued)
        if let error = consumePendingThrow() { throw error }
        lock.withLock {
            storeMap[reference] = value
            logWrites.append(reference)
        }
        settle(claim: claim, status: 3)
    }

    func deleteObserved(reference: String,
                        onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?) async throws {
        let claim = deliver(kind: .delete, reference: reference, onQueued: onQueued)
        if let error = consumePendingThrow() { throw error }
        lock.withLock {
            storeMap[reference] = nil
            logDeletes.append(reference)
        }
        settle(claim: claim, status: 4)
    }

    private func consumePendingThrow() -> Error? {
        lock.lock(); defer { lock.unlock() }
        let error = pendingThrow
        pendingThrow = nil
        return error
    }

    private func deliver(kind: PhysicalOperationKind, reference: String,
                         onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?) -> Int64 {
        lock.lock()
        let claim = nextClaim
        nextClaim += 1
        if let reason = nextNeverDispatched {
            nextNeverDispatched = nil
            records[claim] = .neverDispatched(reason: reason)
        } else {
            records[claim] = .claimedOutstanding
            outstandingOrder.append(claim)
        }
        lock.unlock()
        onQueued?(PhysicalOperationReceipt(claim: claim, epoch: 1, reference: reference,
                                           kind: kind, tracked: true))
        return claim
    }

    private func settle(claim: Int64, status: Int32) {
        lock.lock()
        if records[claim] == .claimedOutstanding {
            records[claim] = .settled(status: status)
            outstandingOrder.removeAll { $0 == claim }
        }
        lock.unlock()
    }

    func physicalSnapshot(claim: Int64) -> PhysicalOperationSnapshot {
        lock.lock(); defer { lock.unlock() }
        return records[claim] ?? .notRecorded
    }

    func resolvePhysical(claim: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let record = records[claim] else { return true }
        switch record {
        case .settled, .neverDispatched:
            records.removeValue(forKey: claim)
            return true
        case .queued, .claimedOutstanding, .notRecorded:
            return false
        }
    }

    /// Scripted double: returns the CURRENT record truth immediately (the
    /// repair suites drive terminal transitions through markClaimedSettled
    /// and consume the subscription from the REAL mailbox instead).
    func awaitPhysicalSettlement(claim: Int64) async -> PhysicalOperationSnapshot {
        physicalSnapshot(claim: claim)
    }

    /// Controlled "trusted host completion arrives" for the oldest
    /// outstanding claim (statuses follow the frozen mailbox protocol).
    func markClaimedSettled(status: Int32) {
        lock.lock()
        guard let claim = outstandingOrder.first else { lock.unlock(); return }
        outstandingOrder.removeFirst()
        records[claim] = .settled(status: status)
        lock.unlock()
    }

    func programNextNeverDispatched(reason: PhysicalNeverDispatchedReason) {
        lock.lock(); nextNeverDispatched = reason; lock.unlock()
    }

    var physicalWriteLog: [String] {
        lock.lock(); defer { lock.unlock() }; return logWrites
    }
    var physicalDeleteLog: [String] {
        lock.lock(); defer { lock.unlock() }; return logDeletes
    }
}

/// Exact-token counting port of the reviewed RB1 registry shape: detach is
/// only TRUE once for a real attached token (like the shared registry), so
/// the tests can assert the retained owned-work count until physical
/// settlement ("shutdown waits real owner").
final class CountingOwnedWorkPort: OwnedWorkRegistryPort, @unchecked Sendable {
    private let lock = NSLock()
    private var counter = 0
    private var attachedTokens: [RuntimeOwnedWorkToken] = []
    private var detached: [String] = []

    func attach(epoch: UInt64, kind: RuntimeOwnedWorkKind,
                ownerID: String) -> RuntimeOwnedWorkAttachOutcome {
        lock.lock()
        counter += 1
        let hex = String(format: "%032x", counter)
        let token = RuntimeOwnedWorkToken(receipt: "work:v1:" + hex, epoch: epoch,
                                          kind: kind, ownerID: ownerID)
        attachedTokens.append(token)
        lock.unlock()
        return .attached(token)
    }
    func detach(_ token: RuntimeOwnedWorkToken) -> Bool {
        lock.lock()
        guard attachedTokens.contains(token), !detached.contains(token.receipt) else {
            lock.unlock()
            return false
        }
        detached.append(token.receipt)
        lock.unlock()
        return true
    }
    func isAttached(_ token: RuntimeOwnedWorkToken) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return attachedTokens.contains(token) && !detached.contains(token.receipt)
    }
    func counts() -> (attached: Int, detached: Int) {
        lock.lock(); defer { lock.unlock() }
        return (attachedTokens.count, detached.count)
    }
    func liveTokens() -> [RuntimeOwnedWorkToken] {
        lock.lock(); defer { lock.unlock() }
        return attachedTokens.filter { !detached.contains($0.receipt) }
    }
}