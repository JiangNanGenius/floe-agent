// SPDX-License-Identifier: MPL-2.0
//
// RB-6 CAP-SECRET-2 qualification tests (authored by the caps qualifier; run
// against the ACTUAL production MCPDomain/ProviderOperationCoordinator/
// SecretGatewayRegistry + the original DatabaseManager). The only controlled
// seam is the physical backend (`RB6ObservingGateway`): it delivers the real
// per-claim receipt at queue-accept and lets the test drive the host
// completion, so retention/ACK/reconciliation decisions are exercised with
// individual physical truth rather than an async bool or a global counter.
import XCTest
import Foundation
import Crypto
@testable import FloeAndroidCore
import FloeCore
import FloeTools
import FloePersistence

final class RuntimeFacadeMCPPhysicalTests: XCTestCase {

    override func tearDown() async throws {
        await RB6TestFixture.shutdownCurrent()
    }

    private struct Harness {
        let fixture: RB6TestFixture
        let gateway: RB6ObservingGateway
        let domain: MCPDomain
    }

    private func makeHarness(_ id: String) async throws -> Harness {
        let fixture = try await RB6TestFixture.make(id: id)
        let gateway = RB6ObservingGateway()
        SecretGatewayRegistry.shared.register(gateway)
        let route = RB6RouteContext(token: "route-test", generation: 7)
        let domain = MCPDomain(services: .init(
            database: fixture.database,
            gateway: SecretGatewayRegistry.shared,
            routeContext: route,
            transportAdmission: RB6TestAdmission(admits: false),
            clientFactory: OriginalMCPClientFactory(),
            ownedWork: fixture.ownedWorkLifecycle(),
            toolWork: FacadeToolWorkCoordinator(),
            registry: ToolRunnerRegistry(),
            hostContext: fixture.hostContext))
        return Harness(fixture: fixture, gateway: gateway, domain: domain)
    }

    private func endpoint(serverID: UUID) -> String {
        "http://127.0.0.1:9/mcp"
    }

    private func account(serverID: UUID) -> String {
        "mcp.\(serverID.uuidString).http.127.0.0.1.9"
    }

    private func reference(serverID: UUID) -> String {
        SecretGatewayNaming.opaqueReference(namespace: "org.floeagent.ios.mcp",
                                            account: account(serverID: serverID))
    }

    private func candidate(id: UUID, auth: String = "bearerToken",
                           enabled: Bool = false,
                           createIntent: Bool = false) -> [String: Any] {
        var value: [String: Any] = [
            "id": id.uuidString, "displayName": "Physical Test",
            "endpoint": endpoint(serverID: id), "enabled": enabled,
            "allowInsecureHTTP": true, "authentication": auth,
        ]
        if createIntent { value["createIntent"] = true }
        return value
    }

    private func submitIntent(serverID: UUID, candidate: [String: Any],
                              secret: Data) throws -> String {
        let intent: [String: Any] = [
            "intent": "set",
            "subject": ["kind": SubjectKind.mcpSave.rawValue,
                        "id": serverID.uuidString],
            "route": ["token": "route-test", "generation": 7],
            "candidate": candidate,
        ]
        let data = try JSONSerialization.data(withJSONObject: intent, options: [.sortedKeys])
        return try SecretSaveIntentVault.shared.submit(intentJSON: data, secret: secret)
    }

    @discardableResult
    private func createServer(_ harness: Harness, secret: Data) async throws -> UUID {
        let id = UUID()
        let token = try submitIntent(
            serverID: id,
            candidate: candidate(id: id, createIntent: true),
            secret: secret)
        let reply = await harness.domain.saveSet(ingressToken: token,
                                                 envelopeRevision: nil)
        XCTAssertEqual(reply["state"] as? String, "committed", "create: \(reply)")
        return id
    }

    private func clear(_ harness: Harness, serverID: UUID) async throws -> [String: Any] {
        let current = await harness.domain.currentRevision(serverID: serverID)
        let revision = try XCTUnwrap(current)
        let body = try JSONSerialization.data(
            withJSONObject: candidate(id: serverID, auth: "none"),
            options: [.sortedKeys])
        return await harness.domain.save(candidateJSON: body, secretIntent: "clear",
                                        envelopeRevision: revision)
    }

    private func setNewSecret(_ harness: Harness, serverID: UUID,
                              secret: Data) async throws -> [String: Any] {
        let current = await harness.domain.currentRevision(serverID: serverID)
        let revision = try XCTUnwrap(current)
        let token = try submitIntent(serverID: serverID,
                                     candidate: candidate(id: serverID),
                                     secret: secret)
        return await harness.domain.saveSet(ingressToken: token,
                                            envelopeRevision: revision)
    }

    // MARK: Claimed delete outstanding blocks a newer same-account Set

    func testClaimedDeleteOutstandingBlocksNewerSetAndReconcilesViaWitness() async throws {
        let harness = try await makeHarness("phys-pending")
        let serverID = try await createServer(harness, secret: Data("old-secret".utf8))
        // The claimed (not yet completed) delete: the caller resumes
        // ambiguous while the individual physical lifetime is outstanding.
        harness.gateway.deleteBehavior = .claimedOutstanding
        let cleared = try await clear(harness, serverID: serverID)
        XCTAssertEqual(cleared["state"] as? String, "committed", "\(cleared)")
        XCTAssertEqual(cleared["credentialCleanup"] as? String, "queuedForRetry")
        XCTAssertEqual(cleared["pendingPhysicalSettlement"] as? Bool, true)
        XCTAssertEqual(harness.gateway.storedData(reference: reference(serverID: serverID)),
                       Data("old-secret".utf8),
                       "an outstanding delete must not claim the old secret removed")
        // A newer Set of the SAME account is refused while the old physical
        // lifetime is unresolved: no secret may be written behind it.
        let writesBefore = harness.gateway.counts().writes
        harness.gateway.deleteBehavior = .committed
        let refused = try await setNewSecret(harness, serverID: serverID,
                                             secret: Data("new-secret".utf8))
        XCTAssertEqual(refused["reason"] as? String, "mcpPhysicalOwnerPending",
                       "\(refused)")
        XCTAssertEqual(harness.gateway.counts().writes, writesBefore,
                       "no secret effect may occur while the pending owner holds")
        // The real host completion arrives for the ORIGINAL claim.
        harness.gateway.completeLastClaim(status: 4)
        switch await harness.domain.reconcilePendingSecretOwner(serverID: serverID) {
        case .settledNow(let reason):
            XCTAssertTrue(reason.hasPrefix("executionSettled.4"), reason)
        case .stillPending(let reason):
            XCTFail("pending owner must settle after the real completion: \(reason)")
        case .nothingPending:
            XCTFail("pending owner expected")
        }
        // The newer Set is now admitted and its secret wins.
        let accepted = try await setNewSecret(harness, serverID: serverID,
                                              secret: Data("new-secret".utf8))
        XCTAssertEqual(accepted["state"] as? String, "committed", "\(accepted)")
        XCTAssertEqual(harness.gateway.storedData(reference: reference(serverID: serverID)),
                       Data("new-secret".utf8))
        // The stale cleanup intent sees the NEWEST row owning the exact
        // account: it resolves WITHOUT deleting the newer secret.
        let drain = await harness.domain.drainCleanupQueue()
        XCTAssertEqual(drain["superseded"], 1, "\(drain)")
        XCTAssertEqual(drain["drained"], 0, "\(drain)")
        XCTAssertEqual(harness.gateway.storedData(reference: reference(serverID: serverID)),
                       Data("new-secret".utf8),
                       "a newer same-account Set must never be destroyed")
        let list = try await harness.domain.list(cursor: nil)
        let row = try XCTUnwrap((try XCTUnwrap(list["servers"] as? [[String: Any]]))
            .first { ($0["id"] as? String) == serverID.uuidString })
        XCTAssertEqual(row["secretCleanupPending"] as? Bool, false,
                       "the superseded intent was resolved without a delete")
    }

    // MARK: Corrupt durable intent is UNKNOWN, not empty

    func testCorruptCleanupLedgerPreservedAndBlocksDestructiveWork() async throws {
        let harness = try await makeHarness("phys-corrupt")
        let serverID = try await createServer(harness, secret: Data("old-secret".utf8))
        let settings = SQLiteSettingsStore(database: harness.fixture.database)
        let corrupt = "{not a valid intent array"
        try await settings.setValue(corrupt, forKey: MCPDomain.cleanupSettingsKey)
        // List reports a PENDING cleanup (corrupt is not empty).
        let list = try await harness.domain.list(cursor: nil)
        let row = try XCTUnwrap((try XCTUnwrap(list["servers"] as? [[String: Any]]))
            .first { ($0["id"] as? String) == serverID.uuidString })
        XCTAssertEqual(row["secretCleanupPending"] as? Bool, true)
        // Drain refuses to treat it as empty.
        let drain = await harness.domain.drainCleanupQueue()
        XCTAssertEqual(drain["corrupt"], 1, "\(drain)")
        XCTAssertEqual(drain["drained"], 0, "\(drain)")
        // A destructive save refuses (and never overwrites the unknown bytes).
        let rejected = try await clear(harness, serverID: serverID)
        XCTAssertEqual(rejected["errorCode"] as? String, "persistenceUnavailable",
                       "\(rejected)")
        XCTAssertEqual(rejected["reason"] as? String, "cleanupLedgerCorrupt")
        XCTAssertEqual(harness.gateway.storedData(reference: reference(serverID: serverID)),
                       Data("old-secret".utf8),
                       "no delete may run on a corrupt ledger")
        let raw = try await settings.value(forKey: MCPDomain.cleanupSettingsKey)
        XCTAssertEqual(raw, corrupt, "corrupt bytes are preserved, never discarded")
    }

    // MARK: Pre-ticket no-effect rejection is not authoritative absence

    func testPreTicketDeleteRejectionKeepsIntentForRetry() async throws {
        let harness = try await makeHarness("phys-noeffect")
        let serverID = try await createServer(harness, secret: Data("old-secret".utf8))
        harness.gateway.deleteBehavior = .invalidReference
        let cleared = try await clear(harness, serverID: serverID)
        XCTAssertEqual(cleared["state"] as? String, "committed", "\(cleared)")
        XCTAssertEqual(cleared["credentialCleanup"] as? String, "queuedForRetry")
        XCTAssertNotEqual(cleared["pendingPhysicalSettlement"] as? Bool, true,
                          "a never-queued rejection has no outstanding physical owner")
        XCTAssertEqual(harness.gateway.storedData(reference: reference(serverID: serverID)),
                       Data("old-secret".utf8))
        // The drain must NOT finalize the intent from invalidReference.
        let drain = await harness.domain.drainCleanupQueue()
        XCTAssertEqual(drain["deferred"], 1, "\(drain)")
        XCTAssertEqual(drain["drained"], 0, "\(drain)")
        XCTAssertEqual(harness.gateway.storedData(reference: reference(serverID: serverID)),
                       Data("old-secret".utf8),
                       "invalidReference is not proof the old secret is absent")
        // Once a REAL committed delete happens, the intent settles.
        harness.gateway.deleteBehavior = .committed
        let second = await harness.domain.drainCleanupQueue()
        XCTAssertEqual(second["drained"], 1, "\(second)")
        XCTAssertNil(harness.gateway.storedData(reference: reference(serverID: serverID)))
    }

    // MARK: The pending owner keeps its ORIGINAL witness

    func testReplacementRegistryCannotChangePendingPhysicalTruth() async throws {
        let harness = try await makeHarness("phys-witness")
        let serverID = try await createServer(harness, secret: Data("old-secret".utf8))
        harness.gateway.deleteBehavior = .claimedOutstanding
        _ = try await clear(harness, serverID: serverID)
        // Re-point the global registry at a NON-observing gateway: a naive
        // reconciliation would now read `.notRecorded` from the current
        // registry. The pending record must keep using the EXACT original
        // witness (the observing gateway) instead.
        let replacement = RB6ScriptedGateway()
        SecretGatewayRegistry.shared.register(replacement)
        switch await harness.domain.reconcilePendingSecretOwner(serverID: serverID) {
        case .stillPending(let reason):
            XCTAssertEqual(reason, "physicalOutstanding", reason)
        case .settledNow(let reason):
            XCTFail("must not settle via the replacement registry: \(reason)")
        case .nothingPending:
            XCTFail("pending owner expected")
        }
        // The original witness delivers the real completion.
        harness.gateway.completeLastClaim(status: 4)
        switch await harness.domain.reconcilePendingSecretOwner(serverID: serverID) {
        case .settledNow(let reason):
            XCTAssertTrue(reason.hasPrefix("executionSettled.4"), reason)
        case .stillPending(let reason):
            XCTFail("original witness completion must settle: \(reason)")
        case .nothingPending:
            XCTFail("pending owner expected")
        }
        XCTAssertEqual(replacement.counts().deletes, 0,
                       "the replacement gateway is never used for the old claim")
    }

    // MARK: remove parks the first outstanding lifetime and retries the rest

    func testRemoveWithOutstandingDeleteParksAndReportsRetry() async throws {
        let harness = try await makeHarness("phys-remove")
        let serverID = try await createServer(harness, secret: Data("old-secret".utf8))
        harness.gateway.deleteBehavior = .claimedOutstanding
        let current = await harness.domain.currentRevision(serverID: serverID)
        let revision = try XCTUnwrap(current)
        let removed = await harness.domain.remove(serverID: serverID, revision: revision)
        XCTAssertEqual(removed["state"] as? String, "removed", "\(removed)")
        XCTAssertEqual(removed["credentialCleanup"] as? String, "queuedForRetry")
        XCTAssertEqual(removed["pendingPhysicalSettlement"] as? Bool, true)
        let list = try await harness.domain.list(cursor: nil)
        XCTAssertTrue((try XCTUnwrap(list["servers"] as? [Any])).isEmpty,
                      "the config row delete itself is committed")
        // Real completion → the parked owner settles; the remaining legacy
        // intent is then processed by the bounded drain.
        harness.gateway.completeLastClaim(status: 4)
        switch await harness.domain.reconcilePendingSecretOwner(serverID: serverID) {
        case .settledNow:
            break
        case .stillPending(let reason):
            XCTFail("remove pending owner must settle: \(reason)")
        case .nothingPending:
            XCTFail("pending owner expected")
        }
        harness.gateway.deleteBehavior = .committed
        let drain = await harness.domain.drainCleanupQueue()
        XCTAssertGreaterThanOrEqual((drain["drained"] ?? 0) + (drain["superseded"] ?? 0), 1,
                                    "\(drain)")
        XCTAssertEqual(drain["deferred"], 0, "\(drain)")
    }
}

