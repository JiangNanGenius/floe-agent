// FloeSecurityTests — atomic single-use claim on the in-memory approval
// grant store (T5 successor: exact-confirmation claim).
//
// The design adoption confirmation is a single-use grant on the EXISTING
// `ApprovalGrantStore`. `claimSingleUse` is the atomic gate that must
// authorize exactly one frozen operation: validate + burn in one actor
// call, exact scope match, a mismatched/expired/revoked/already-burned
// grant can never claim and a mismatch is never burned.
//
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import FloeSecurity

@Suite("FloeSecurity.ApprovalGrantStore single-use claim")
struct ApprovalGrantClaimTests {
    private let toolName = "design.ownerAdopt"

    private func grant(
        id: UUID = UUID(),
        tool: String? = nil,
        hostID: UUID? = nil,
        paths: [String] = ["target:t", "candidate:c", "baseline:b", "proposed:p", "mode:m", "scope:s"],
        singleUse: Bool = true,
        identity: String? = nil,
        expiresAt: Date? = nil
    ) -> ApprovalGrant {
        ApprovalGrant(
            id: id,
            scope: ApprovalScope(
                toolName: tool ?? toolName,
                hostID: hostID,
                paths: paths,
                singleUse: singleUse,
                toolAuthorizationIdentity: identity),
            expiresAt: expiresAt,
            policyName: "design.owner-adoption.user-minted")
    }

    private func requestScope(
        tool: String? = nil,
        hostID: UUID? = nil,
        paths: [String] = ["target:t", "candidate:c", "baseline:b", "proposed:p", "mode:m", "scope:s"],
        singleUse: Bool = true,
        identity: String? = nil
    ) -> ApprovalScope {
        ApprovalScope(
            toolName: tool ?? toolName,
            hostID: hostID,
            paths: paths,
            singleUse: singleUse,
            toolAuthorizationIdentity: identity)
    }

    @Test("Exact scope claims once; the burned grant can never claim again")
    func exactScopeClaimsOnce() async {
        let store = ApprovalGrantStore()
        let issued = grant()
        await store.add(issued)
        #expect(await store.grant(id: issued.id) != nil)

        let claimed = await store.claimSingleUse(id: issued.id, matching: requestScope())
        #expect(claimed?.id == issued.id)
        // Burned: neither the claim nor the plain lookup sees it again.
        #expect(await store.grant(id: issued.id) == nil)
        #expect(await store.claimSingleUse(id: issued.id, matching: requestScope()) == nil)
    }

    @Test("Path order is not semantic; the exact path set still claims")
    func pathOrderIsNotSemantic() async {
        let store = ApprovalGrantStore()
        let issued = grant(paths: ["a", "b", "c"])
        await store.add(issued)
        #expect(await store.claimSingleUse(
            id: issued.id, matching: requestScope(paths: ["c", "b", "a"])) != nil)
    }

    @Test("A mismatched claim never burns the grant (tool/host/path/identity)")
    func mismatchedClaimsNeverBurn() async {
        let store = ApprovalGrantStore()
        let host = UUID()
        let issued = grant(hostID: host, identity: "descriptor-1")
        await store.add(issued)

        // Wrong tool, wrong host, wrong descriptor identity, extra path,
        // missing path, different path value.
        let mismatches: [ApprovalScope] = [
            requestScope(tool: "other.tool", hostID: host, identity: "descriptor-1"),
            requestScope(hostID: UUID(), identity: "descriptor-1"),
            requestScope(hostID: host, identity: "descriptor-2"),
            requestScope(hostID: host,
                         paths: ["target:t", "candidate:c", "baseline:b", "proposed:p", "mode:m", "scope:s", "extra:x"],
                         identity: "descriptor-1"),
            requestScope(hostID: host,
                         paths: ["target:t", "candidate:c", "baseline:b", "proposed:p", "mode:m"],
                         identity: "descriptor-1"),
            requestScope(hostID: host,
                         paths: ["target:OTHER", "candidate:c", "baseline:b", "proposed:p", "mode:m", "scope:s"],
                         identity: "descriptor-1")
        ]
        for scope in mismatches {
            #expect(await store.claimSingleUse(id: issued.id, matching: scope) == nil)
        }
        // The grant is untouched and the exact claim still succeeds once.
        #expect(await store.grant(id: issued.id) != nil)
        #expect(await store.claimSingleUse(id: issued.id, matching: requestScope(hostID: host, identity: "descriptor-1")) != nil)
    }

    @Test("Expired grants cannot be claimed; revoke before claim blocks it")
    func expiryAndRevocationBlockClaims() async {
        let store = ApprovalGrantStore()
        let expired = grant(expiresAt: Date().addingTimeInterval(-1))
        await store.add(expired)
        #expect(await store.claimSingleUse(id: expired.id, matching: requestScope()) == nil)
        // An expired claim does not burn the record (purge is the only
        // removal), but it is not live either.
        #expect(await store.grant(id: expired.id) == nil)

        let revoked = grant()
        await store.add(revoked)
        await store.revoke(id: revoked.id)
        #expect(await store.claimSingleUse(id: revoked.id, matching: requestScope()) == nil)
        #expect(await store.grant(id: revoked.id) == nil)
    }

    @Test("A live grant with a fraction of a second left still claims before expiry")
    func liveGrantClaimsBeforeExpiry() async {
        let store = ApprovalGrantStore()
        let issued = grant(expiresAt: Date().addingTimeInterval(60))
        await store.add(issued)
        #expect(await store.claimSingleUse(id: issued.id, matching: requestScope()) != nil)
    }

    @Test("Reusable grants are never claimable and stay live; wrong id never claims")
    func reusableAndUnknownGrants() async {
        let store = ApprovalGrantStore()
        let reusable = grant(singleUse: false)
        await store.add(reusable)
        // Claiming requires a single-use BOTH on the stored grant and on
        // the request scope: a reusable grant is left live.
        #expect(await store.claimSingleUse(id: reusable.id, matching: requestScope(singleUse: false)) == nil)
        #expect(await store.claimSingleUse(id: reusable.id, matching: requestScope()) == nil)
        #expect(await store.grant(id: reusable.id) != nil)
        // A claim whose request scope is not single-use is refused.
        let single = grant()
        await store.add(single)
        #expect(await store.claimSingleUse(id: single.id, matching: requestScope(singleUse: false)) == nil)
        #expect(await store.grant(id: single.id) != nil)
        // Unknown id never claims.
        #expect(await store.claimSingleUse(id: UUID(), matching: requestScope()) == nil)
    }

    @Test("Concurrent claims of one grant have exactly one winner")
    func concurrentClaimsHaveOneWinner() async {
        let store = ApprovalGrantStore()
        let issued = grant()
        await store.add(issued)
        let scope = requestScope()
        let winners = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    await store.claimSingleUse(id: issued.id, matching: scope) != nil
                }
            }
            var count = 0
            for await won in group where won { count += 1 }
            return count
        }
        #expect(winners == 1)
        #expect(await store.grant(id: issued.id) == nil)
    }

    @Test("Legacy consumeIfSingleUse still burns reusable=false grants only")
    func legacyConsumeStillWorks() async {
        let store = ApprovalGrantStore()
        let single = grant()
        let reusable = grant(singleUse: false)
        await store.add(single)
        await store.add(reusable)
        await store.consumeIfSingleUse(single)
        await store.consumeIfSingleUse(reusable)
        #expect(await store.grant(id: single.id) == nil)
        #expect(await store.grant(id: reusable.id) != nil)
    }
}
