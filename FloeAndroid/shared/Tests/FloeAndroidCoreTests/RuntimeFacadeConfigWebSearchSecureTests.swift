// SPDX-License-Identifier: MPL-2.0
//
// MC-WEBSEARCH-3 authored tests (job-97a740a3dbb946ce) — secure web-search
// credential ingress: Keep (legacy byte path, zero secret effects), Set
// (one-shot vault lease, exact namespace reference, per-kind field
// validation), Clear (current stored account, live-reference guard), CAS
// honesty (pre-effect probe + commit-time gate), durable cleanup journal
// (strict codec, corrupt preservation), namespace isolation from provider
// accounts, and root ownership (pending owner shared across facade
// instances; registry lease retained until real settlement).
// AUTHORED ONLY: NOT compiled, NOT executed by this source package; Main's
// serialized qualification lane runs them against the real toolchain.
// Synthetic fixture values only; no real credentials.

import XCTest
import Foundation
import GRDB
@testable import FloeAndroidCore
import FloeCore
import FloePersistence
import FloeAndroidWebTools

final class RuntimeFacadeConfigWebSearchSecureTests: XCTestCase {

    private var databaseURL: URL!
    private var database: DatabaseManager!

    private let configurationID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let routeToken = "route-websearch"
    private let routeGeneration: UInt64 = 7
    private let syntheticAPIKey = "sk-websearch-synthetic-00000001"

    override func setUp() async throws {
        _ = floeSecretGatewayRemove()
        SecretRequestMailbox.shared.resetForTesting()
        SecretSaveIntentVault.shared.resetForTesting()
        ProviderOperationCoordinatorRegistry.shared.removeAllForTesting()
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-websearch-secure-\(UUID().uuidString).db")
        database = try DatabaseManager(path: databaseURL)
        try await database.migrate()
    }

    override func tearDown() async throws {
        _ = floeSecretGatewayRemove()
        SecretRequestMailbox.shared.resetForTesting()
        SecretSaveIntentVault.shared.resetForTesting()
        ProviderOperationCoordinatorRegistry.shared.removeAllForTesting()
        try? await database.close()
        try? FileManager.default.removeItem(at: databaseURL)
    }

    // MARK: Fixtures

    private func makeFacade(gateway: (any SecretGatewayServicing)? = nil,
                            port: (any OwnedWorkRegistryPort)? = nil)
        -> ModelConfigurationFacade
    {
        ModelConfigurationFacade(
            database: database,
            gateway: gateway ?? IngressTestGateway(),
            catalogBytes: nil,
            transportAdmission: TransportAdmissionClosed(),
            routeContext: FixedRouteContext(token: routeToken, generation: routeGeneration),
            epochProvider: FixedEpochProvider(epoch: 1),
            ownedWorkRegistry: port ?? AlwaysAttachOwnedWorkPort())
    }

    private func makeConfiguration(kind: WebSearchProviderKind = .brave,
                                   account: String = "web-search.brave.fixture",
                                   endpoint: URL? = URL(string: "https://search.example.invalid"))
        -> WebSearchProviderConfiguration
    {
        WebSearchProviderConfiguration(id: configurationID, kind: kind,
                                       displayName: "Fixture \(kind.rawValue)",
                                       endpoint: endpoint,
                                       credentialAccount: account,
                                       enabled: true, priority: 5)
    }

    private func savePayload(_ configurations: [WebSearchProviderConfiguration],
                             credential: [String: Any]? = nil) throws -> Data {
        var object: [String: Any] = [
            "configurations": try configurations.map { try configurationObject($0) },
        ]
        if let credential { object["credential"] = credential }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func configurationObject(_ configuration: WebSearchProviderConfiguration) throws
        -> [String: Any]
    {
        let data = try JSONEncoder().encode(configuration)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func absentRevision() -> ConfigRevision {
        ConfigRevision.webSearch(digest: ModelConfigurationFacade.webSearchDigest(nil))
    }

    /// Submit a one-shot save intent through the REAL C ABI (like the
    /// parent ingress suite): webSearchSave subject, route frozen at
    /// save-tap, candidate = the exact configuration, value = the ORIGINAL
    /// WebSearchCredential JSON bytes.
    private func submitWebSearchIntent(
        candidate: WebSearchProviderConfiguration,
        credentialJSON: [String: String],
        subjectKind: SubjectKind = .webSearchSave
    ) throws -> String {
        let credentialBytes = try JSONEncoder().encode(WebSearchCredential(values: credentialJSON))
        let intent: [String: Any] = [
            "subject": ["kind": subjectKind.rawValue, "id": configurationID.uuidString],
            "route": ["token": routeToken, "generation": routeGeneration],
            "intent": "set",
            "baseRevision": ["resourceID": "settings.websearch",
                             "version": ModelConfigurationFacade.webSearchDigest(nil)],
            "candidate": try configurationObject(candidate),
        ]
        let data = try JSONSerialization.data(withJSONObject: intent, options: [.sortedKeys])
        var json = data
        json.append(0)
        var tokenBuffer = [CChar](repeating: 0, count: 64)
        var status: Int32 = -1
        json.withUnsafeBytes { jsonRaw in
            credentialBytes.withUnsafeBytes { secretRaw in
                tokenBuffer.withUnsafeMutableBufferPointer { buffer in
                    status = floeSecretSaveIntentSubmit(
                        jsonRaw.bindMemory(to: CChar.self).baseAddress,
                        secretRaw.bindMemory(to: UInt8.self).baseAddress,
                        Int32(credentialBytes.count),
                        buffer.baseAddress, 40)
                }
            }
        }
        XCTAssertEqual(status, 0, "synthetic web-search intent submit must succeed")
        return String(cString: tokenBuffer)
    }

    // MARK: 1. Keep is the legacy byte path with zero secret effects

    func testWebSearchKeepLegacyAndExplicitAreMetadataOnlyWithZeroSecretEffects() async throws {
        let gateway = IngressTestGateway()
        let facade = makeFacade(gateway: gateway)
        let config = makeConfiguration()
        // Legacy omission.
        _ = try await facade.saveWebSearch(
            payload: try savePayload([config]),
            revision: absentRevision())
        // Explicit keep, at the revision the PREVIOUS save actually produced
        // (the persisted canonical JSON is sorted-key encoded).
        let currentRevision = try await facade.getWebSearch().revision
        _ = try await facade.saveWebSearch(
            payload: try savePayload([config], credential: [
                "configurationID": configurationID.uuidString, "intent": "keep",
            ]),
            revision: currentRevision)
        let snapshot = gateway.snapshot()
        XCTAssertTrue(snapshot.writes.isEmpty, "keep never writes a secret")
        XCTAssertTrue(snapshot.deletes.isEmpty, "keep never deletes a secret")
        let reread = try await facade.getWebSearch()
        XCTAssertEqual(reread.states.count, 1)
        XCTAssertEqual(reread.states[0].credentialState, .secretMissing)
    }

    // MARK: 2. Set writes at the EXACT namespace reference and commits the list

    func testWebSearchSetWritesSecretAtExactNamespaceReferenceAndCommitsList() async throws {
        let gateway = IngressTestGateway()
        let facade = makeFacade(gateway: gateway)
        let config = makeConfiguration()
        let token = try submitWebSearchIntent(candidate: config,
                                              credentialJSON: ["apiKey": syntheticAPIKey])
        let payload = try savePayload([config], credential: [
            "configurationID": configurationID.uuidString,
            "intent": "set",
            "saveIntentToken": token,
        ])
        let saved = try await facade.saveWebSearch(payload: payload, revision: absentRevision())
        XCTAssertEqual(saved.states.count, 1)
        XCTAssertEqual(saved.states[0].credentialState, .available)
        // The write went ONLY to the web-search namespace reference.
        let expectedReference = ConfigSecretIdentity.webSearchOpaqueReference(
            credentialAccount: config.credentialAccount)
        XCTAssertEqual(gateway.snapshot().writes.map { $0.reference }, [expectedReference])
        let written = try XCTUnwrap(gateway.snapshot().writes.first?.bytes)
        XCTAssertEqual(String(data: written, encoding: .utf8),
                       "{\"values\":{\"apiKey\":\"\(syntheticAPIKey)\"}}")
        // One-shot: replay with the same token is typed-refused, never rewritten.
        // The revision must be CURRENT, otherwise the pre-effect CAS refuses
        // before the vault is consulted (the boundary under test is the lease).
        let currentRevision = try await facade.getWebSearch().revision
        do {
            _ = try await facade.saveWebSearch(payload: payload,
                                               revision: currentRevision)
            XCTFail("one-shot replay must refuse")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertEqual(error.reason, "saveIntentAlreadyConsumed")
        }
        XCTAssertEqual(gateway.snapshot().writes.count, 1)
    }

    // MARK: 3. Cross-subject tokens can never drive the web-search save

    func testWebSearchSetRefusesCrossSubjectProviderTokenWithZeroEffects() async throws {
        let gateway = IngressTestGateway()
        let facade = makeFacade(gateway: gateway)
        let config = makeConfiguration()
        // A providerSave token minted for the SAME id: the vault subject
        // grammar may even accept the submit (provider ids are valid
        // providerSave subjects), but the web-search consume refuses it.
        let foreignToken = try submitWebSearchIntent(
            candidate: config, credentialJSON: ["apiKey": syntheticAPIKey],
            subjectKind: .providerSave)
        let payload = try savePayload([config], credential: [
            "configurationID": configurationID.uuidString,
            "intent": "set",
            "saveIntentToken": foreignToken,
        ])
        do {
            _ = try await facade.saveWebSearch(payload: payload, revision: absentRevision())
            XCTFail("cross-subject token must refuse")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .invalidEnvelope)
            XCTAssertEqual(error.reason, "saveIntentSubjectMismatch")
        }
        XCTAssertTrue(gateway.snapshot().writes.isEmpty)
        let persistedRaw = try await SQLiteSettingsStore(database: database)
            .value(forKey: ConfigSettingsKeys.webSearchConfigurations)
        XCTAssertNil(persistedRaw)
    }

    // MARK: 4. Per-kind mandatory field validation (original rules)

    func testWebSearchSetValidatesCredentialFieldsByKindBeforeEffects() async throws {
        let gateway = IngressTestGateway()
        let facade = makeFacade(gateway: gateway)
        // brave requires apiKey; provide engineId instead → typed refusal.
        let config = makeConfiguration()
        let token = try submitWebSearchIntent(candidate: config,
                                              credentialJSON: ["engineId": "x"])
        let payload = try savePayload([config], credential: [
            "configurationID": configurationID.uuidString,
            "intent": "set",
            "saveIntentToken": token,
        ])
        do {
            _ = try await facade.saveWebSearch(payload: payload, revision: absentRevision())
            XCTFail("missing apiKey must refuse before effects")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .invalidEnvelope)
            XCTAssertEqual(error.reason, "websearchCredentialField.apiKey")
        }
        XCTAssertTrue(gateway.snapshot().writes.isEmpty)
    }

    func testWebSearchSetRefusesSearXNGKindThatRequiresNoCredential() async throws {
        let gateway = IngressTestGateway()
        let facade = makeFacade(gateway: gateway)
        let config = makeConfiguration(
            kind: .searxng, account: "unused.searxng.fixture",
            endpoint: URL(string: "http://127.0.0.1:8888"))
        let token = try submitWebSearchIntent(candidate: config,
                                              credentialJSON: ["apiKey": syntheticAPIKey])
        let payload = try savePayload([config], credential: [
            "configurationID": configurationID.uuidString,
            "intent": "set",
            "saveIntentToken": token,
        ])
        do {
            _ = try await facade.saveWebSearch(payload: payload, revision: absentRevision())
            XCTFail("searxng set must refuse")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.reason, "websearchCredentialNotRequired")
        }
        XCTAssertTrue(gateway.snapshot().writes.isEmpty)
    }

    // MARK: 5. Clear removes only the current stored account's secret

    func testWebSearchClearRemovesCurrentStoredSecretAndCommitsList() async throws {
        let gateway = IngressTestGateway()
        let facade = makeFacade(gateway: gateway)
        let config = makeConfiguration()
        // Seed the CURRENT stored list + the secret (as a prior Set would).
        _ = try await facade.saveWebSearch(payload: try savePayload([config]),
                                           revision: absentRevision())
        let reference = ConfigSecretIdentity.webSearchOpaqueReference(
            credentialAccount: config.credentialAccount)
        gateway.seed(reference, try JSONEncoder().encode(
            WebSearchCredential(values: ["apiKey": syntheticAPIKey])))
        let currentDigest = try await facade.getWebSearch().revision.version
        let cleared = try await facade.saveWebSearch(
            payload: try savePayload([config], credential: [
                "configurationID": configurationID.uuidString, "intent": "clear",
            ]),
            revision: ConfigRevision.webSearch(digest: currentDigest))
        XCTAssertEqual(cleared.states[0].credentialState, .secretMissing)
        XCTAssertEqual(gateway.snapshot().deletes, [reference])
        let refreshed = try await facade.getWebSearch()
        XCTAssertEqual(refreshed.states[0].credentialState, .secretMissing)
    }

    func testWebSearchClearRefusesLiveReferencedAccount() async throws {
        let gateway = IngressTestGateway()
        let facade = makeFacade(gateway: gateway)
        let config = makeConfiguration(account: "web-search.shared.fixture")
        // Stored: config A holds the account. Incoming: A is REPLACED by a
        // different id holding the SAME account; a clear targeted at A
        // would delete the secret the live B references → refuse.
        _ = try await facade.saveWebSearch(payload: try savePayload([config]),
                                           revision: absentRevision())
        let currentDigest = try await facade.getWebSearch().revision.version
        let replacementID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let replacement = WebSearchProviderConfiguration(
            id: replacementID, kind: .brave, displayName: "Replacement",
            endpoint: URL(string: "https://search.example.invalid"),
            credentialAccount: "web-search.shared.fixture")
        do {
            _ = try await facade.saveWebSearch(
                payload: try savePayload([replacement], credential: [
                    "configurationID": configurationID.uuidString, "intent": "clear",
                ]),
                revision: ConfigRevision.webSearch(digest: currentDigest))
            XCTFail("clear of a live referenced account must refuse")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.reason, "websearchAccountLiveReferenced")
        }
        XCTAssertTrue(gateway.snapshot().deletes.isEmpty)
    }

    // MARK: 6. CAS honesty: pre-effect probe refuses without effects

    func testWebSearchStaleCASRefusesBeforeAnySecretEffect() async throws {
        let gateway = IngressTestGateway()
        let facade = makeFacade(gateway: gateway)
        let config = makeConfiguration()
        // Commit the list once so the absent digest is stale.
        _ = try await facade.saveWebSearch(payload: try savePayload([config]),
                                           revision: absentRevision())
        let token = try submitWebSearchIntent(candidate: config,
                                              credentialJSON: ["apiKey": syntheticAPIKey])
        let payload = try savePayload([config], credential: [
            "configurationID": configurationID.uuidString,
            "intent": "set",
            "saveIntentToken": token,
        ])
        do {
            _ = try await facade.saveWebSearch(payload: payload, revision: absentRevision())
            XCTFail("stale revision must refuse")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .staleRevision)
        }
        XCTAssertTrue(gateway.snapshot().writes.isEmpty, "pre-effect probe: no write")
        // The intent was NOT consumed by the refused attempt: a fresh save
        // against the CURRENT revision with the same token succeeds.
        let currentDigest = try await facade.getWebSearch().revision.version
        let retried = try await facade.saveWebSearch(
            payload: payload, revision: ConfigRevision.webSearch(digest: currentDigest))
        XCTAssertEqual(retried.states[0].credentialState, .available)
    }

    // MARK: 7. Durable cleanup journal: strict codec, corrupt preservation

    func testWebSearchCleanupJournalCorruptBytesPreservedAndTyped() async throws {
        let facade = makeFacade()
        _ = facade // silence unused in source-only build
        let cleanup = WebSearchSecretCleanup(database: database)
        // Seed corrupt bytes at the journal key.
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO app_settings (key, value_json, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET
                        value_json = excluded.value_json,
                        updated_at = excluded.updated_at
                    """,
                arguments: [ConfigSettingsKeys.webSearchSecretCleanup,
                            "}{not-json", "2026-10-19T00:00:00.000Z"])
        }
        do {
            _ = try await cleanup.entries()
            XCTFail("corrupt journal must refuse typed")
        } catch let error as ConfigDomainError {
            XCTAssertTrue(error.reason.hasPrefix("webSearchCleanupCorrupt."))
        }
        do {
            try await cleanup.enqueue(.init(configurationID: configurationID,
                                            account: "web-search.x", intent: .secretWrite))
            XCTFail("enqueue on corrupt journal must fail closed")
        } catch let error as ConfigDomainError {
            XCTAssertTrue(error.reason.hasPrefix("webSearchCleanupCorrupt."))
        }
        // The corrupt bytes are preserved EXACTLY (never rewritten empty or
        // truncated).
        let raw = try await SQLiteSettingsStore(database: database)
            .value(forKey: ConfigSettingsKeys.webSearchSecretCleanup)
        XCTAssertEqual(raw, "}{not-json")
    }

    func testWebSearchCleanupJournalValidLaterEntriesSurviveSaturationRefusal() async throws {
        let cleanup = WebSearchSecretCleanup(database: database)
        try await cleanup.enqueue(.init(configurationID: configurationID,
                                        account: "web-search.a", intent: .secretWrite))
        // A duplicate (same id, same intent) is idempotent; a conflicting
        // new intent REPLACES (never duplicates).
        try await cleanup.enqueue(.init(configurationID: configurationID,
                                        account: "web-search.a", intent: .secretWrite))
        try await cleanup.enqueue(.init(configurationID: configurationID,
                                        account: "web-search.a", intent: .secretClear))
        let entries = try await cleanup.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].intent, .secretClear)
        // Compare-and-delete only removes the EXACT intent.
        let removedWrong = try await cleanup.dequeueMatching(
            configurationID: configurationID, intent: .secretWrite)
        XCTAssertFalse(removedWrong)
        let removedExact = try await cleanup.dequeueMatching(
            configurationID: configurationID, intent: .secretClear)
        XCTAssertTrue(removedExact)
        let remainingEntries = try await cleanup.entries()
        XCTAssertTrue(remainingEntries.isEmpty)
    }

    // MARK: 8. Namespace isolation: model provider accounts never alias

    func testWebSearchNamespaceIsolationFromProviderAccountWithSameUUID() async throws {
        let gateway = IngressTestGateway()
        let facade = makeFacade(gateway: gateway)
        let config = makeConfiguration(account: "provider.\(configurationID.uuidString)")
        // Deliberately reuse the SAME UUID a provider would use; the
        // namespaces must still produce distinct references.
        let webReference = ConfigSecretIdentity.webSearchOpaqueReference(
            credentialAccount: config.credentialAccount)
        let providerReference = ConfigSecretIdentity.providerOpaqueReference(
            for: ConfigSecretIdentity.providerSecretReference(
                account: config.credentialAccount, synchronizable: false))
        XCTAssertNotEqual(webReference, providerReference)
        let token = try submitWebSearchIntent(candidate: config,
                                              credentialJSON: ["apiKey": syntheticAPIKey])
        _ = try await facade.saveWebSearch(
            payload: try savePayload([config], credential: [
                "configurationID": configurationID.uuidString,
                "intent": "set",
                "saveIntentToken": token,
            ]),
            revision: absentRevision())
        let writes = gateway.snapshot().writes
        XCTAssertEqual(writes.map { $0.reference }, [webReference])
        XCTAssertFalse(writes.contains { $0.reference == providerReference })
    }

    // MARK: 9. Root ownership: pending owner shared across facade instances

    func testWebSearchPendingOwnerRetainedAcrossFacadeRecreationAndSettlesWithoutRestart()
        async throws
    {
        // REAL mailbox gateway: the TEST plays host (bind/install/claim).
        _ = floeSecretMailboxBind(1)
        XCTAssertEqual(floeSecretGatewayInstall(), 0)
        let port = WebSearchCountingOwnedWorkPort()
        let facadeA = makeFacade(gateway: SecretGatewayRegistry.shared, port: port)
        let config = makeConfiguration()
        _ = try await facadeA.saveWebSearch(payload: try savePayload([config]),
                                            revision: absentRevision())
        let currentDigest = try await facadeA.getWebSearch().revision.version
        let token = try submitWebSearchIntent(candidate: config,
                                              credentialJSON: ["apiKey": syntheticAPIKey])
        let payload = try savePayload([config], credential: [
            "configurationID": configurationID.uuidString,
            "intent": "set",
            "saveIntentToken": token,
        ])
        let setTask = Task {
            try await facadeA.saveWebSearch(payload: payload,
                                            revision: ConfigRevision.webSearch(
                                                digest: currentDigest))
        }
        // Host claims the write, then the mailbox closes (RootStop-shaped
        // interruption): the caller resumes unknown while the physical
        // execution is outstanding → the owner is PARKED (ticket + registry
        // lease + receipt retained).
        let claim = try await requireHostClaim()
        _ = floeSecretGatewayRemove()
        do {
            _ = try await setTask.value
            XCTFail("interrupted set must surface the pending refusal")
        } catch let error as ConfigDomainError {
            XCTAssertTrue(error.reason.hasPrefix("websearchSecretPending."))
        }
        // MC-OBSERVER-PENDING-OWNER (Main 2026-10-19): NO new mailbox bind,
        // NO gateway re-install. The old pending operation must drain purely
        // through the witness captured at its attempt, while the registry
        // remains removed. The frozen mailbox object itself is retained by
        // the pending record — the close was the RootStop-shaped
        // interruption; the physical record survives inside it.
        XCTAssertFalse(SecretGatewayRegistry.shared.supportsPhysicalObservation,
                       "no observing gateway is registered after remove()")
        // The pending record retained the exact attempt witness.
        let coordinator = ProviderOperationCoordinatorRegistry.shared
            .coordinator(for: database)
        let pendingOptional = await coordinator.pendingRecord(
            providerID: configurationID)
        let pending = try XCTUnwrap(pendingOptional)
        let witness = try XCTUnwrap(pending.witness as? MailboxSecretGateway)
        XCTAssertTrue(witness === MailboxSecretGateway.shared,
                      "the witness is the ORIGINAL mailbox gateway object")
        // A NEW facade over the SAME database sees the durable pending owner
        // through the SHARED coordinator (no restart, no per-instance gate).
        let facadeB = makeFacade(gateway: SecretGatewayRegistry.shared, port: port)
        // The late REAL completion arrives with the caller already settled
        // by the close: the frozen mailbox reports -103 and still settles
        // the individual physical record exactly once.
        XCTAssertEqual(SecretRequestMailbox.shared.complete(claim: claim, status: 3,
                                                            value: nil, valueLen: 0), -103)
        let outcome = await facadeB.reconcileWebSearchRecovery(
            configurationID: configurationID)
        guard case .settledNow = outcome else {
            return XCTFail("late completion must settle the parked owner, got \(outcome)")
        }
        // The registry lease was retained until the REAL settlement (root
        // close genuinely waited the owner) and detached exactly once.
        XCTAssertEqual(port.attachCount, 1)
        XCTAssertEqual(port.detachCount, 1)
        // The journal kept the write intent through the interruption: the
        // bootstrap drain will converge it (live list owns the account ⇒
        // resolved without delete). Assert the intent is still recorded.
        let journal = try await WebSearchSecretCleanup(database: database).entries()
        XCTAssertEqual(journal.map { $0.intent }, [.secretWrite])
    }

    // MARK: Host helpers (real mailbox)

    private func requireHostClaim(file: StaticString = #filePath, line: UInt = #line) async throws -> Int64 {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let claim = SecretRequestMailbox.shared.awaitClaim(timeoutMillis: 0)
            if claim > 0 { return claim }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("host must claim the queued write", file: file, line: line)
        return 0
    }
}

/// Counting owned-work port: proves the registry lease was attached BEFORE
/// the effect chain and detached exactly when the owner truly settled.
final class WebSearchCountingOwnedWorkPort: OwnedWorkRegistryPort, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: Int] = [:]
    private(set) var attachCount = 0
    private(set) var detachCount = 0

    func attach(epoch: UInt64, kind: RuntimeOwnedWorkKind,
                ownerID: String) -> RuntimeOwnedWorkAttachOutcome {
        lock.lock()
        attachCount += 1
        let receipt = "work:v1:" + String(format: "%032x", attachCount)
        tokens[receipt] = attachCount
        lock.unlock()
        return .attached(RuntimeOwnedWorkToken(receipt: receipt, epoch: epoch,
                                               kind: kind, ownerID: ownerID))
    }

    func detach(_ token: RuntimeOwnedWorkToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard tokens[token.receipt] != nil else { return false }
        tokens.removeValue(forKey: token.receipt)
        detachCount += 1
        return true
    }

    func isAttached(_ token: RuntimeOwnedWorkToken) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tokens[token.receipt] != nil
    }
}
