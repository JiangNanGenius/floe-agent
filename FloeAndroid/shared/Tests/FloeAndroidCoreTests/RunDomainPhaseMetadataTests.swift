// SPDX-License-Identifier: MPL-2.0
//
// RunDomainError phase-metadata regressions (Main ready-cloud diagnosis).
//
// The storeOpenFailed/storeReadFailed vocabulary has MANY catch sites; the
// bounded static `phase` says WHICH one refused. Contract:
//  * default nil preserves every existing exact error byte-for-byte
//    (the wireObject of an unphased error is exactly {error, reason});
//  * a phase is a closed static enum string — never a path, SQL, payload
//    or free text; SQLite store codes are numeric ONLY;
//  * the App debug FloeRunFailure whitelist prints `phase` from the detail
//    map for run.start / run.startTask failures.
import XCTest
import Foundation
@testable import FloeAndroidCore

final class RunDomainPhaseMetadataTests: XCTestCase {

    func testUnphasedErrorKeepsTheExactOriginalWireObject() {
        let error = RunDomainError(.persistenceUnavailable, .storeReadFailed)
        XCTAssertEqual(error.phase, nil)
        XCTAssertEqual(error.storePrimaryCode, nil)
        XCTAssertEqual(error.storeExtendedCode, nil)
        XCTAssertEqual(error.wireObject,
                       ["error": "persistenceUnavailable", "reason": "storeReadFailed"])
    }

    func testPhasedErrorCarriesBoundedStaticMetadataOnly() {
        let error = RunDomainError(.persistenceUnavailable, .storeReadFailed,
                                   phase: .conversationProof,
                                   storePrimaryCode: 8, storeExtendedCode: 8_266)
        XCTAssertEqual(error.phase, .conversationProof)
        XCTAssertEqual(error.storePrimaryCode, 8)
        XCTAssertEqual(error.storeExtendedCode, 8_266)
        XCTAssertEqual(error.wireObject, [
            "error": "persistenceUnavailable",
            "reason": "storeReadFailed",
            "phase": "conversationProof",
            "storePrimary": "8",
            "storeExtended": "8266",
        ])
        // Every phase value is a closed static enum string.
        for phase in RunDomainError.Phase.allCases {
            XCTAssertFalse(phase.rawValue.isEmpty)
            XCTAssertTrue(phase.rawValue.allSatisfy { $0.isLetter },
                          "phase must be a closed static enum string, never free text")
        }
    }

    func testAddingPhaseNeverReplacesCodeOrReasonAndIsIdempotent() {
        let base = RunDomainError(.notFound, .conversationMissing)
        let phased = base.addingPhase(.conversationProof)
        XCTAssertEqual(phased.code, .notFound)
        XCTAssertEqual(phased.reason, .conversationMissing)
        XCTAssertEqual(phased.phase, .conversationProof)
        XCTAssertEqual(phased.addingPhase(.modelResolution).phase, .conversationProof,
                       "a set phase is never overwritten")
        XCTAssertEqual(base.addingPhase(nil).phase, nil)
    }

    /// Main decision: diagnostics must NOT change business error identity —
    /// equality is exactly (code, reason); the optional phase/store codes
    /// never participate, so every pre-existing semantic equality assertion
    /// keeps its original meaning.
    func testBusinessIdentityIsCodeAndReasonOnly() {
        let plain = RunDomainError(.persistenceUnavailable, .storeReadFailed)
        let phased = RunDomainError(.persistenceUnavailable, .storeReadFailed,
                                    phase: .launchPrepare,
                                    storePrimaryCode: 8, storeExtendedCode: 8_266)
        XCTAssertEqual(plain, phased)
        XCTAssertEqual(plain, RunDomainError(.persistenceUnavailable, .storeReadFailed,
                                             phase: .conversationProof))
        XCTAssertNotEqual(plain, RunDomainError(.persistenceUnavailable, .storeWriteFailed))
        XCTAssertNotEqual(plain, RunDomainError(.transportUnavailable, .storeReadFailed))
    }

    func testPersistenceUnavailableTerminalSurvivesWithPhaseDetail() {
        let error = RunDomainError(.persistenceUnavailable, .storeReadFailed,
                                   phase: .launchPrepare)
        let result = RunDomainReply.terminalResult(for: error)
        XCTAssertEqual(result.kind, .failed)
        XCTAssertEqual(result.code, .storeOpenFailed)
        XCTAssertEqual(result.detail?["phase"], "launchPrepare")
        XCTAssertEqual(result.detail?["error"], "persistenceUnavailable")
        XCTAssertEqual(result.detail?["reason"], "storeReadFailed")
    }

    func testNonPersistenceErrorsKeepTheirExactTerminalMapping() {
        let blocked = RunDomainReply.terminalResult(
            for: RunDomainError(.staleRevision, .revisionMismatch))
        XCTAssertEqual(blocked.kind, .rejected)
        XCTAssertEqual(blocked.code, .ordinaryRuntimeBlocked)
        XCTAssertEqual(blocked.detail, ["error": "staleRevision",
                                        "reason": "revisionMismatch"])
        let refused = RunDomainReply.terminalResult(
            for: RunDomainError(.notFound, .runMissing))
        XCTAssertEqual(refused.kind, .rejected)
        XCTAssertEqual(refused.code, .runRecordNotFound)
    }
}
