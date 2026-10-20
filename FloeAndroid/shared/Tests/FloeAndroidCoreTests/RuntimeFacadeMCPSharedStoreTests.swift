// SPDX-License-Identifier: MPL-2.0
//
// RB-6 shared-store / owner-namespace qualification tests (MCP-JOURNAL-
// ATOMIC-RMW, MCP-SERVER-ARRAY-ATOMIC-MUTATION, MCP-OWNER-RESOURCE-
// NAMESPACE). They run the REAL MCPDomain/ledger/coordinator against ONE
// original DatabaseManager and the controlled observing/scripted gateway.
import XCTest
import Foundation
import Crypto
@testable import FloeAndroidCore
import FloeCore
import FloeTools
import FloePersistence

final class RuntimeFacadeMCPSharedStoreTests: XCTestCase {

    override func tearDown() async throws {
        await RB6TestFixture.shutdownCurrent()
    }

    private struct Harness {
        let fixture: RB6TestFixture
        let gateway: RB6ObservingGateway
        let domainA: MCPDomain
        let domainB: MCPDomain
    }

    private func makeHarness(_ id: String) async throws -> Harness {
        let fixture = try await RB6TestFixture.make(id: id)
        let gateway = RB6ObservingGateway()
        let route = RB6RouteContext(token: "route-test", generation: 7)
        func makeDomain() -> MCPDomain {
            MCPDomain(services: .init(
                database: fixture.database, gateway: gateway,
                routeContext: route,
                transportAdmission: RB6TestAdmission(admits: false),
                clientFactory: OriginalMCPClientFactory(),
                ownedWork: fixture.ownedWorkLifecycle(),
                toolWork: FacadeToolWorkCoordinator(),
                registry: ToolRunnerRegistry(),
                hostContext: fixture.hostContext))
        }
        return Harness(fixture: fixture, gateway: gateway,
                       domainA: makeDomain(), domainB: makeDomain())
    }

    private func candidate(id: UUID, auth: String = "bearerToken") -> [String: Any] {
        ["id": id.uuidString, "displayName": "Shared \(id.uuidString.prefix(8))",
         "endpoint": "http://127.0.0.1:9/mcp", "enabled": false,
         "allowInsecureHTTP": true, "authentication": auth]
    }

    private func submitIntent(serverID: UUID, candidate: [String: Any],
                              secret: Data = Data("secret".utf8)) throws -> String {
        let intent: [String: Any] = [
            "intent": "set",
            "subject": ["kind": SubjectKind.mcpSave.rawValue,
                        "id": serverID.uuidString],
            "route": ["token": "route-test", "generation": 7],
            "candidate": candidate,
        ]
        return try SecretSaveIntentVault.shared.submit(
            intentJSON: try JSONSerialization.data(withJSONObject: intent,
                                                   options: [.sortedKeys]),
            secret: secret)
    }

    @discardableResult
    private func createServer(_ domain: MCPDomain, id: UUID = UUID(),
                              secret: Data = Data("secret".utf8)) async throws -> UUID {
        let token = try submitIntent(serverID: id,
                                     candidate: candidate(id: id).merging(
                                        ["createIntent": true]) { _, new in new },
                                     secret: secret)
        let reply = await domain.saveSet(ingressToken: token, envelopeRevision: nil)
        XCTAssertEqual(reply["state"] as? String, "committed", "\(reply)")
        return id
    }

    /// Async-safe revision unwrap (XCTUnwrap's autoclosure cannot await).
    private func revision(_ domain: MCPDomain, _ serverID: UUID) async throws
        -> ConfigRevision
    {
        // Refresh this facade's view from the ONE persisted array first (two
        // facades over one DB must read the newest row, not their cache).
        _ = try await domain.list(cursor: nil)
        let value = await domain.currentRevision(serverID: serverID)
        return try XCTUnwrap(value)
    }

    private func clear(_ domain: MCPDomain, serverID: UUID) async throws -> [String: Any] {
        let current = await domain.currentRevision(serverID: serverID)
        let revision = try XCTUnwrap(current)
        let body = try JSONSerialization.data(
            withJSONObject: candidate(id: serverID, auth: "none"),
            options: [.sortedKeys])
        return await domain.save(candidateJSON: body, secretIntent: "clear",
                                 envelopeRevision: revision)
    }

    // MARK: Ledger atomic RMW

    func testConcurrentTwoServerEnqueueKeepsBothIntents() async throws {
        let harness = try await makeHarness("store-enq2")
        let serverA = try await createServer(harness.domainA)
        let serverB = try await createServer(harness.domainA)
        // A pre-ticket no-effect delete keeps each intent (no pending owner).
        harness.gateway.deleteBehavior = .invalidReference
        let revisionA = try await revision(harness.domainA, serverA)
        let revisionB = try await revision(harness.domainB, serverB)
        let bodyA = try JSONSerialization.data(
            withJSONObject: candidate(id: serverA, auth: "none"), options: [.sortedKeys])
        let bodyB = try JSONSerialization.data(
            withJSONObject: candidate(id: serverB, auth: "none"), options: [.sortedKeys])
        async let stateA: String = {
            let reply = await harness.domainA.save(candidateJSON: bodyA,
                                                   secretIntent: "clear",
                                                   envelopeRevision: revisionA)
            return reply["state"] as? String ?? "missing"
        }()
        async let stateB: String = {
            let reply = await harness.domainB.save(candidateJSON: bodyB,
                                                   secretIntent: "clear",
                                                   envelopeRevision: revisionB)
            return reply["state"] as? String ?? "missing"
        }()
        let (replyA, replyB) = await (stateA, stateB)
        XCTAssertEqual(replyA, "committed")
        XCTAssertEqual(replyB, "committed")
        guard case .entries(let intents) = try await MCPSecretCleanupLedger.state(
            harness.fixture.database) else {
            return XCTFail("ledger must be decodable")
        }
        XCTAssertEqual(Set(intents.map(\.serverID)), [serverA, serverB],
                       "a concurrent cross-server enqueue must not lose an intent")
    }

    func testConcurrentEnqueueAndRemoveKeepsOnlyTheLiveIntent() async throws {
        let harness = try await makeHarness("store-enqrm")
        let serverA = try await createServer(harness.domainA, secret: Data("a".utf8))
        let serverC = try await createServer(harness.domainB, secret: Data("c".utf8))
        harness.gateway.deleteBehavior = .invalidReference
        let clearReply = try await clear(harness.domainA, serverID: serverA)
        XCTAssertEqual(clearReply["state"] as? String, "committed")
        harness.gateway.deleteBehavior = .committed
        let current = await harness.domainB.currentRevision(serverID: serverC)
        let removed = await harness.domainB.remove(serverID: serverC,
                                                   revision: try XCTUnwrap(current))
        XCTAssertEqual(removed["state"] as? String, "removed", "\(removed)")
        guard case .entries(let intents) = try await MCPSecretCleanupLedger.state(
            harness.fixture.database) else {
            return XCTFail("ledger must be decodable")
        }
        XCTAssertEqual(intents.filter { $0.serverID == serverA }.count, 1,
                       "the live server's intent survives the other server's remove")
        XCTAssertTrue(intents.allSatisfy { $0.serverID != serverC },
                      "the removed server's intents settled")
    }

    func testCorruptLedgerRefusesConcurrentEnqueueAndKeepsBytes() async throws {
        let harness = try await makeHarness("store-corrupt2")
        let settings = SQLiteSettingsStore(database: harness.fixture.database)
        let corrupt = "{broken"
        try await settings.setValue(corrupt, forKey: MCPDomain.cleanupSettingsKey)
        let uuidA = UUID(), uuidB = UUID()
        async let first: Void = {
            _ = try? await MCPSecretCleanupLedger.enqueue(
                .init(serverID: uuidA, account: "a", kind: .serverRemove),
                in: harness.fixture.database)
        }()
        async let second: Void = {
            _ = try? await MCPSecretCleanupLedger.enqueue(
                .init(serverID: uuidB, account: "b", kind: .serverRemove),
                in: harness.fixture.database)
        }()
        _ = await (first, second)
        let raw = try await settings.value(forKey: MCPDomain.cleanupSettingsKey)
        XCTAssertEqual(raw, corrupt, "corrupt bytes are preserved, never replaced")
    }

    func testFullLedgerExistingIntentIdempotentNewRejected() async throws {
        let harness = try await makeHarness("store-full")
        let database = harness.fixture.database
        for index in 0..<MCPSecretCleanupLedger.maximumEntries {
            let serverID = UUID()
            try await MCPSecretCleanupLedger.enqueue(
                .init(serverID: serverID,
                      account: "mcp.\(serverID.uuidString).http.127.0.0.1.9",
                      kind: .accountReplace),
                in: database)
        }
        // The SAME intent is idempotent even at capacity.
        let repeated = try await MCPSecretCleanupLedger.readStrict(database).first!
        try await MCPSecretCleanupLedger.enqueue(repeated, in: database)
        // A NEW intent is refused pre-effect.
        do {
            try await MCPSecretCleanupLedger.enqueue(
                .init(serverID: UUID(), account: "new-account",
                      kind: .serverRemove),
                in: database)
            XCTFail("a full ledger must refuse a new intent")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .mailboxSaturated)
            XCTAssertEqual(error.reason, "cleanupLedgerFull")
        }
        let finalCount = try await MCPSecretCleanupLedger.readStrict(database).count
        XCTAssertEqual(finalCount, MCPSecretCleanupLedger.maximumEntries)
    }

    // MARK: Server-array atomic mutation

    func testTwoFacadeStaleCacheSavesPreserveSiblings() async throws {
        let harness = try await makeHarness("store-2facade")
        // Both facades observe an EMPTY array first (their caches start
        // stale relative to the other's later write).
        _ = try await harness.domainA.list(cursor: nil)
        _ = try await harness.domainB.list(cursor: nil)
        let serverA = UUID(), serverB = UUID()
        let tokenA = try submitIntent(serverID: serverA,
                                      candidate: candidate(id: serverA)
                                        .merging(["createIntent": true]) { _, n in n })
        let savedA = await harness.domainA.saveSet(ingressToken: tokenA,
                                                   envelopeRevision: nil)
        XCTAssertEqual(savedA["state"] as? String, "committed", "\(savedA)")
        // B writes its own server; A's record must survive.
        let tokenB = try submitIntent(serverID: serverB,
                                      candidate: candidate(id: serverB)
                                        .merging(["createIntent": true]) { _, n in n })
        let savedB = await harness.domainB.saveSet(ingressToken: tokenB,
                                                   envelopeRevision: nil)
        XCTAssertEqual(savedB["state"] as? String, "committed", "\(savedB)")
        let fresh = try await harness.domainA.list(cursor: nil)
        let ids = Set((try XCTUnwrap(fresh["servers"] as? [[String: Any]]))
            .compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) })
        XCTAssertEqual(ids, [serverA, serverB],
                       "a stale second facade must not drop the first facade's row")
    }

    func testOverlappingDifferentServerSaveAndRemovePreserveRecords() async throws {
        let harness = try await makeHarness("store-overlap")
        let existing = try await createServer(harness.domainA,
                                              secret: Data("existing".utf8))
        let newID = UUID()
        // Seed a stale cache in B before the overlapping operations.
        _ = try await harness.domainB.list(cursor: nil)
        let removeRevision = try await revision(harness.domainA, existing)
        let newToken = try submitIntent(serverID: newID,
                                        candidate: candidate(id: newID)
                                            .merging(["createIntent": true]) { _, n in n })
        async let savedState: String = {
            let reply = await harness.domainB.saveSet(ingressToken: newToken,
                                                      envelopeRevision: nil)
            return reply["state"] as? String ?? "missing"
        }()
        async let removedState: String = {
            let reply = await harness.domainA.remove(serverID: existing,
                                                     revision: removeRevision)
            return reply["state"] as? String ?? "missing"
        }()
        let (saved, removed) = await (savedState, removedState)
        XCTAssertEqual(saved, "committed")
        XCTAssertEqual(removed, "removed")
        let fresh = try await harness.domainA.list(cursor: nil)
        let ids = Set((try XCTUnwrap(fresh["servers"] as? [[String: Any]]))
            .compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) })
        XCTAssertEqual(ids, [newID],
                       "the concurrently written server survives the other's remove")
    }

    func testSameServerStaleRevisionCASRejectsWithoutExtraEffect() async throws {
        let harness = try await makeHarness("store-cas")
        let serverID = try await createServer(harness.domainA)
        let stale = try await revision(harness.domainB, serverID)
        // A commits a REAL change (enabled flip) through the OTHER facade.
        let current = try await revision(harness.domainA, serverID)
        let enabledReply = await harness.domainA.setEnabled(serverID: serverID,
                                                            enabled: true,
                                                            revision: current)
        XCTAssertEqual(enabledReply["state"] as? String, "enabled", "\(enabledReply)")
        let advanced = try await revision(harness.domainB, serverID)
        XCTAssertNotEqual(advanced.version, stale.version,
                          "A's change must advance the target revision")
        // B still holds the old revision: the targeted CAS refuses with NO
        // row/secret effect.
        let rejected = await harness.domainB.setEnabled(serverID: serverID, enabled: false,
                                                        revision: stale)
        XCTAssertEqual(rejected["errorCode"] as? String, "staleRevision", "\(rejected)")
        let fresh = try await harness.domainA.list(cursor: nil)
        let row = try XCTUnwrap((try XCTUnwrap(fresh["servers"] as? [[String: Any]]))
            .first { ($0["id"] as? String) == serverID.uuidString })
        XCTAssertEqual(row["enabled"] as? Bool, true,
                       "the stale revision changed nothing")
    }

    // MARK: Owner-namespace isolation

    func testSameUUIDProviderAndMCPOwnersAreIsolated() async throws {
        let harness = try await makeHarness("store-namespace")
        let shared = UUID()
        let providerPool = ProviderOperationCoordinatorRegistry.shared
            .coordinator(for: harness.fixture.database)
        let mcpPool = MCPOperationCoordinatorRegistry.shared
            .coordinator(for: harness.fixture.database)
        XCTAssertFalse(providerPool === mcpPool,
                       "model and MCP owner pools are separate namespaces")
        // A live MODEL provider operation for the UUID must not block an MCP
        // server with the SAME UUID.
        guard case .attached(let providerTicket) =
                await providerPool.beginOperation(providerID: shared, kind: .save) else {
            return XCTFail("provider begin expected")
        }
        let serverID = try await createServer(harness.domainA, id: shared)
        XCTAssertEqual(serverID, shared)
        // An MCP operation on the same UUID must not block the provider.
        guard case .attached(let mcpTicket) =
                await mcpPool.beginOperation(providerID: shared, kind: .save) else {
            await providerPool.endOperation(providerTicket)
            return XCTFail("MCP begin expected")
        }
        await mcpPool.endOperation(mcpTicket)
        // A PENDING model provider owner must not force MCP reconciliation.
        await providerPool.parkPending(providerTicket, intent: .secretWrite,
                                       receipt: nil, lease: nil, witness: nil)
        let mcpAfterProviderPending = await harness.domainA.setEnabled(
            serverID: shared, enabled: false,
            revision: try await revision(harness.domainA, shared))
        XCTAssertEqual(mcpAfterProviderPending["state"] as? String, "disabled",
                       "\(mcpAfterProviderPending)")
        let providerPending = await providerPool.pendingRecord(providerID: shared)
        XCTAssertNotNil(providerPending, "the provider pending owner is untouched")
    }

    func testTwoMCPFacadesSameUUIDShareOnePendingOwner() async throws {
        let harness = try await makeHarness("store-mcp-pending")
        let serverID = try await createServer(harness.domainA)
        let mcpPool = MCPOperationCoordinatorRegistry.shared
            .coordinator(for: harness.fixture.database)
        // A (facade A) parks a claimed physical owner for the UUID.
        harness.gateway.deleteBehavior = .claimedOutstanding
        _ = try await clear(harness.domainA, serverID: serverID)
        let mcpPending = await mcpPool.pendingRecord(providerID: serverID)
        XCTAssertNotNil(mcpPending, "the MCP pending owner lives in the MCP namespace")
        // B (facade B) resolves the SAME coordinator and is refused while the
        // owner is outstanding.
        let blockedRevision = try await revision(harness.domainB, serverID)
        let blockedToken = try submitIntent(serverID: serverID,
                                            candidate: candidate(id: serverID))
        let refused = await harness.domainB.saveSet(ingressToken: blockedToken,
                                                    envelopeRevision: blockedRevision)
        XCTAssertEqual(refused["reason"] as? String, "mcpPhysicalOwnerPending",
                       "\(refused)")
        // Real completion + reconciliation through B settles the shared owner.
        harness.gateway.completeLastClaim(status: 4)
        switch await harness.domainB.reconcilePendingSecretOwner(serverID: serverID) {
        case .settledNow:
            break
        case .stillPending(let reason):
            XCTFail("shared MCP owner must settle: \(reason)")
        case .nothingPending:
            XCTFail("pending owner expected")
        }
        let acceptedRevision = try await revision(harness.domainB, serverID)
        let acceptedToken = try submitIntent(serverID: serverID,
                                             candidate: candidate(id: serverID))
        let accepted = await harness.domainB.saveSet(ingressToken: acceptedToken,
                                                     envelopeRevision: acceptedRevision)
        XCTAssertEqual(accepted["state"] as? String, "committed", "\(accepted)")
    }
}
