// SPDX-License-Identifier: MPL-2.0
//
// Focused regression source for the C06 host-settlement proof contract.
// The pump can now publish a POSITIVE not-started proof when the runtime
// refused a start before admitting it; this suite pins that Core accepts it
// only in the complete shape, and that every incomplete/foreign proof keeps
// the durable job nonterminal instead of fabricating a terminal.
// AUTHORED-ONLY: the coordinator compiles and runs the integrated suite.
import Foundation
import XCTest
import FloeAndroidJobTools
@testable import FloeAndroidCore

final class LinuxShellJobSettlementProofTests: XCTestCase {

    private func proof(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    func testProvenNotStartedIsATypedSettlementWithBoundedReason() throws {
        let bytes = try proof([
            "epoch": 42, "state": "not_started",
            "requestID": "0F6C2A7E-1111-4222-8333-000000000001",
            "reason": "runtime_stopping",
        ])
        let settlement = try LinuxShellJobSettlement.decode(proofBytes: bytes, expectedEpoch: 42)
        XCTAssertEqual(settlement, .notStarted(reason: "runtime_stopping"))
    }

    func testNotStartedWithoutPumpClaimIdentityIsIncomplete() throws {
        let bytes = try proof([
            "epoch": 42, "state": "not_started", "reason": "runtime_stopping",
        ])
        let settlement = try LinuxShellJobSettlement.decode(proofBytes: bytes, expectedEpoch: 42)
        XCTAssertEqual(settlement, .unconfirmed(reason: "incomplete-not-started-proof"))
    }

    func testNotStartedCarryingASessionIsNotAStartProof() throws {
        let bytes = try proof([
            "epoch": 42, "state": "not_started",
            "requestID": "0F6C2A7E-1111-4222-8333-000000000001",
            "sessionID": "lease-1",
        ])
        let settlement = try LinuxShellJobSettlement.decode(proofBytes: bytes, expectedEpoch: 42)
        XCTAssertEqual(settlement, .unconfirmed(reason: "incomplete-not-started-proof"))
    }

    func testNotStartedReasonOutsideTheClosedGrammarIsDroppedNotTrusted() throws {
        let bytes = try proof([
            "epoch": 42, "state": "not_started",
            "requestID": "0F6C2A7E-1111-4222-8333-000000000001",
            "reason": "/data/user/0/private details",
        ])
        let settlement = try LinuxShellJobSettlement.decode(proofBytes: bytes, expectedEpoch: 42)
        XCTAssertEqual(settlement, .notStarted(reason: nil),
                       "an unbounded reason is dropped; the positive proof itself stands")
    }

    func testReleasedRequiresTheCompleteEngineTerminal() throws {
        let incomplete = try proof([
            "epoch": 42, "state": "released", "sessionID": "lease-1", "waitErrno": 0,
        ])
        XCTAssertEqual(try LinuxShellJobSettlement.decode(proofBytes: incomplete, expectedEpoch: 42),
                       .unconfirmed(reason: "incomplete-terminal-proof"),
                       "a released lease without the cancelled bit is not a terminal")

        let missingErrno = try proof([
            "epoch": 42, "state": "released", "sessionID": "lease-1", "cancelled": false,
        ])
        XCTAssertEqual(try LinuxShellJobSettlement.decode(proofBytes: missingErrno, expectedEpoch: 42),
                       .unconfirmed(reason: "incomplete-terminal-proof"),
                       "a wait result is never assumed benign when it was not observed")
    }

    func testReleasedMapsTheRealEngineTerminal() throws {
        let bytes = try proof([
            "epoch": 42, "state": "released", "sessionID": "lease-1",
            "cancelled": true, "stopReason": "user-stop", "exitCode": 143,
            "termSig": 15, "waitErrno": 0, "workspaceStatus": "synced",
        ])
        let settlement = try LinuxShellJobSettlement.decode(proofBytes: bytes, expectedEpoch: 42)
        XCTAssertEqual(settlement, .released(
            sessionID: "lease-1", cancelled: true, stopReason: "user-stop",
            exitCode: 143, termSig: 15, waitErrno: 0,
            workspaceStatus: "synced", workspaceRecoveryRef: nil, recovery: nil))
    }

    func testQuiescentAndUnknownStatesKeepTheirExactMeaning() throws {
        XCTAssertEqual(
            try LinuxShellJobSettlement.decode(
                proofBytes: try proof(["epoch": 42, "state": "quiescent"]),
                expectedEpoch: 42),
            .quiescent(note: "Runtime recovery proved no owned workload; command outcome is unknown."))
        XCTAssertEqual(
            try LinuxShellJobSettlement.decode(
                proofBytes: try proof(["epoch": 42, "state": "cancelled"]),
                expectedEpoch: 42),
            .unconfirmed(reason: "runtime-work-unresolved"),
            "an unknown settlement state can never terminalize a job")
    }

    func testForeignEpochProofIsRefused() throws {
        let bytes = try proof([
            "epoch": 41, "state": "not_started",
            "requestID": "0F6C2A7E-1111-4222-8333-000000000001",
        ])
        XCTAssertEqual(try LinuxShellJobSettlement.decode(proofBytes: bytes, expectedEpoch: 42),
                       .unconfirmed(reason: "foreign-generation"))
    }
}
