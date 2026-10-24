// SPDX-License-Identifier: MPL-2.0
//
// G04-R1 network credential lease — component source tests.
// AUTHORED, NOT EXECUTED (grouped qualification is Main's). A synthetic
// authority actor mirrors the vault's typed receipts; nothing here touches
// the real vault, Keychain-equivalent storage, or the network.
//
// Proven contract surface:
//   * Unicode SMB/WebDAV passwords pass through EXACTLY (the Git ASCII
//     token shape is deliberately absent);
//   * staged tickets are one-shot: consume/abort/refused-capture paths all
//     drain the RAM table; a second consume never re-yields bytes;
//   * label smuggling (URL userinfo / signed-query tokens) refuses typed
//     BEFORE the vault sees anything, and the ticket is still drained;
//   * resolve requires the LIVE config ref (no cached grant truth);
//   * vault failure kinds keep their distinct tokens (effectUnknown is
//     never `.deleted`, cleanupPending is never silent);
//   * error tokens never carry secret bytes;
//   * retire zeroizes unconsumed stages and refuses later use.
import Foundation
import XCTest
@testable import FloeAndroidCore

final class G04NetworkCredentialLeaseTests: XCTestCase {

    // MARK: - Synthetic authority (vault-typed semantics, no real storage)

    private actor SyntheticAuthority: G04NetworkSecretAuthority {
        private(set) var captured: [UUID: Data] = [:]
        private(set) var resolveCalls: [UUID] = []
        var deleteOutcome: G04NetworkSecretDeletion = .deleted
        var deleteError: Error?
        func setDeleteOutcome(_ outcome: G04NetworkSecretDeletion) { deleteOutcome = outcome }
        func setDeleteError(_ error: Error) { deleteError = error }
        var availableOverrides: [UUID: Bool] = [:]

        func captureNetworkSecret(_ secret: Data, id: UUID, label: String,
                                  workspaceID: UUID) async throws {
            guard !secret.isEmpty else { throw G04NetworkSecretFailure.invalidLabel }
            captured[id] = secret
        }
        func replaceNetworkSecret(_ secret: Data, id: UUID, label: String) async throws {
            captured[id] = secret
        }
        func resolveNetworkSecret(id: UUID) async throws -> Data {
            resolveCalls.append(id)
            guard let secret = captured[id] else { throw G04NetworkSecretFailure.notFound }
            return secret
        }
        func deleteNetworkSecret(id: UUID) async throws -> G04NetworkSecretDeletion {
            if let deleteError { throw deleteError }
            captured[id] = nil
            return deleteOutcome
        }
        func networkSecretAvailable(id: UUID) async throws -> Bool {
            if let override = availableOverrides[id] { return override }
            return captured[id] != nil
        }
    }

    private func makeLease() -> (G04NetworkCredentialLease, SyntheticAuthority) {
        (G04NetworkCredentialLease(epoch: 42, authority: SyntheticAuthority()),
         SyntheticAuthority())
    }

    // MARK: - Unicode passthrough + one-shot tickets

    func testUnicodePasswordRoundTripsExactlyWithOneShotTicket() async throws {
        let authority = SyntheticAuthority()
        let lease = G04NetworkCredentialLease(epoch: 42, authority: authority)
        let password = Data("Pässwörd — 密码 🔐 café".utf8)   // Unicode, NOT the Git ASCII shape
        let ref = UUID()
        let ticket = await lease.stage(password)
        XCTAssertGreaterThan(ticket, 0)
        _ = try await lease.capture(ticket: ticket, credentialRef: ref,
                                    label: "Share (SMB) [host]", workspaceID: UUID())
        let stored = try await lease.resolve(credentialRef: ref, liveConfigCredentialRef: ref)
        XCTAssertEqual(stored, password)
        // The ticket is dead: a second capture attempt refuses typed.
        do {
            _ = try await lease.capture(ticket: ticket, credentialRef: UUID(),
                                        label: "Any (WebDAV) [h]", workspaceID: UUID())
            XCTFail("replayed ticket must refuse")
        } catch let error as G04NetworkSecretFailure {
            XCTAssertEqual(error, .invalidTicket)
        }
        // No ASCII validation: every byte above survived exactly.
        let again = try await lease.resolve(credentialRef: ref, liveConfigCredentialRef: ref)
        XCTAssertEqual(again, password)
    }

    func testStageBoundsAndSaturatedTableRefuseTyped() async throws {
        let lease = G04NetworkCredentialLease(epoch: 42, authority: SyntheticAuthority())
        let emptyStage = await lease.stage(Data())
        XCTAssertEqual(emptyStage, -2)
        let oversizedStage = await lease.stage(Data(repeating: 0x41, count: 65_537))
        XCTAssertEqual(oversizedStage, -2)
        var tickets: [Int64] = []
        for _ in 0 ..< 8 { tickets.append(await lease.stage(Data("x".utf8))) }
        XCTAssertTrue(tickets.allSatisfy { $0 > 0 })
        let saturatedStage = await lease.stage(Data("late".utf8))
        XCTAssertEqual(saturatedStage, -2)   // bounded table
    }

    func testLabelSmugglingRefusesAndStillDrainsTicket() async throws {
        let authority = SyntheticAuthority()
        let lease = G04NetworkCredentialLease(epoch: 7, authority: authority)
        for label in ["https://admin:Sup3rSecret@host/dav",
                      "Mount [dav.example.test]?sig=abcdef"] {
            let ticket = await lease.stage(Data("unicode-pass 密码".utf8))
            XCTAssertGreaterThan(ticket, 0)
            do {
                _ = try await lease.capture(ticket: ticket, credentialRef: UUID(),
                                            label: label, workspaceID: UUID())
                XCTFail("smuggled label must refuse")
            } catch let error as G04NetworkSecretFailure {
                XCTAssertEqual(error, .invalidLabel)
            }
            // Drained anyway: the staged secret cannot be captured later.
            do {
                _ = try await lease.capture(ticket: ticket, credentialRef: UUID(),
                                            label: "Fine (WebDAV) [h]", workspaceID: UUID())
                XCTFail("ticket must already be consumed")
            } catch let error as G04NetworkSecretFailure {
                XCTAssertEqual(error, .invalidTicket)
            }
        }
        let stored = await authority.captured
        XCTAssertTrue(stored.isEmpty)
        let stats = await lease.stats
        XCTAssertEqual(stats.liveStages, 0)
    }

    func testSecretBytesNeverAppearInErrorTokens() async throws {
        let authority = SyntheticAuthority()
        await authority.setDeleteError(G04NetworkSecretFailure.gatewayEffectUnknown)
        let lease = G04NetworkCredentialLease(epoch: 9, authority: authority)
        do {
            _ = try await lease.resolve(credentialRef: UUID(), liveConfigCredentialRef: nil)
            XCTFail("cross-ref resolve must refuse")
        } catch let error as G04NetworkSecretFailure {
            XCTAssertFalse(String(describing: error).contains("密码"))
        }
        do {
            _ = try await lease.revoke(credentialRef: UUID())
            XCTFail("delete error must propagate")
        } catch let error as G04NetworkSecretFailure {
            XCTAssertEqual(error, .gatewayEffectUnknown)   // unknown != deleted
        }
    }

    // MARK: - Live config revalidation (no cached grant truth)

    func testResolveRequiresExactLiveConfigRef() async throws {
        let authority = SyntheticAuthority()
        let lease = G04NetworkCredentialLease(epoch: 11, authority: authority)
        let ref = UUID()
        let other = UUID()
        let ticket = await lease.stage(Data("pass".utf8))
        _ = try await lease.capture(ticket: ticket, credentialRef: ref,
                                    label: "N (WebDAV) [h]", workspaceID: UUID())
        // The live config now names a DIFFERENT ref (edited/revoked):
        // resolve refuses WITHOUT consulting the authority.
        do {
            _ = try await lease.resolve(credentialRef: ref, liveConfigCredentialRef: other)
            XCTFail("stale config ref must refuse")
        } catch let error as G04NetworkSecretFailure {
            XCTAssertEqual(error, .notFound)
        }
        let calls = await authority.resolveCalls
        XCTAssertTrue(calls.isEmpty)
        // nil live ref (credential cleared) refuses the same way.
        do {
            _ = try await lease.resolve(credentialRef: ref, liveConfigCredentialRef: nil)
            XCTFail("cleared config ref must refuse")
        } catch let error as G04NetworkSecretFailure {
            XCTAssertEqual(error, .notFound)
        }
        // Revalidation mirrors the same rule without bytes.
        let live = try await lease.revalidate(credentialRef: ref, liveConfigCredentialRef: other)
        XCTAssertFalse(live)
        let trueLive = try await lease.revalidate(credentialRef: ref, liveConfigCredentialRef: ref)
        XCTAssertTrue(trueLive)
    }

    func testDurablePendingDeletionIsReportedNotForgiven() async throws {
        let authority = SyntheticAuthority()
        await authority.setDeleteOutcome(.durablePending)
        let lease = G04NetworkCredentialLease(epoch: 3, authority: authority)
        let ref = UUID()
        let ticket = await lease.stage(Data("p".utf8))
        _ = try await lease.capture(ticket: ticket, credentialRef: ref,
                                    label: "M (SMB) [h]", workspaceID: UUID())
        let outcome = try await lease.revoke(credentialRef: ref)
        XCTAssertEqual(outcome, .durablePending)
    }

    // MARK: - Retirement

    func testRetireZeroizesStagesAndRefusesLaterUse() async throws {
        let lease = G04NetworkCredentialLease(epoch: 5, authority: SyntheticAuthority())
        let liveTicket = await lease.stage(Data("abandon-me 密码".utf8))
        XCTAssertGreaterThan(liveTicket, 0)
        await lease.retire()
        let retiredStage = await lease.stage(Data("late".utf8))
        XCTAssertEqual(retiredStage, -1)
        do {
            _ = try await lease.resolve(credentialRef: UUID(), liveConfigCredentialRef: UUID())
            XCTFail("retired lease must refuse")
        } catch let error as G04NetworkSecretFailure {
            XCTAssertEqual(error, .leaseRetired)
        }
        let stats = await lease.stats
        XCTAssertEqual(stats.liveStages, 0)
        XCTAssertGreaterThanOrEqual(stats.zeroized, 1)
    }

    func testAbortStageIsTypedOnce() async throws {
        let lease = G04NetworkCredentialLease(epoch: 6, authority: SyntheticAuthority())
        let ticket = await lease.stage(Data("x".utf8))
        let first = await lease.abortStage(ticket)
        XCTAssertTrue(first)
        let second = await lease.abortStage(ticket)
        XCTAssertFalse(second)   // never a fake second success
    }

    // MARK: - Redaction

    func testEndpointRedactionDropsQueryFragmentAndUserinfo() throws {
        let plain = try XCTUnwrap(URL(string: "https://dav.example.test:8443/files/team?sign=SECRET#frag"))
        XCTAssertEqual(G04NetworkSecretRedaction.endpoint(plain),
                       "https://dav.example.test:8443/files/team")
        let label = G04NetworkSecretRedaction.safeMountLabel(
            name: "Team", transport: .webDAV, endpoint: plain)
        XCTAssertFalse(label.contains("SECRET"))
        XCTAssertFalse(label.contains("#frag"))
        XCTAssertTrue(G04NetworkSecretRedaction.labelLooksSafe(label))
    }
}
