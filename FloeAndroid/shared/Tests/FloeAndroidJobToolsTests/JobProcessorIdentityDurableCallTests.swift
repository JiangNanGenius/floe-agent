// SPDX-License-Identifier: MPL-2.0
//
// G03-R3 durable job call identity — ONE grammar, inverse round trip.
// AUTHORED, NOT RUN in this source lane (Main's grouped compile runs it;
// same discipline as the rest of FloeAndroidJobToolsTests).
//
// Why this exists (candidate 07 root cause): the Core session-open job
// fence compared the durable `jobs.<rowID>` grant claim against
// `row.toolCallID` — the submitting `jobs.submit` PROVIDER call id — which
// is a DIFFERENT identity space, so every model-submitted exec.shell job
// grant refused with `jobCallMismatch` before the engine ever dispatched.
// The repair makes `JobProcessorIdentity.callID(jobID:)` the single
// definition of the durable processor identity: `BackgroundJobService.start`
// freezes the processor ToolContext through it, and the grant fence
// re-derives the expected claim from the ORIGINAL proven row through it.
// These tests lock the grammar itself (byte-identical to the historical
// inline construction, canonical uppercase, strict inverse round trip, and
// identity-space separation). All fixtures are synthetic.

import XCTest
import Foundation
import FloeAndroidJobTools

final class JobProcessorIdentityDurableCallTests: XCTestCase {

    /// The durable identity is byte-identical to the historical frozen
    /// grammar (`"jobs." + uuidString`, canonical uppercase) and round-trips
    /// EXACTLY through the original parser — the service producer and the
    /// grant consumer therefore cannot drift apart.
    func testCallIDIsCanonicalDurableGrammarAndRoundTrips() {
        let id = UUID()
        let claim = JobProcessorIdentity.callID(jobID: id)
        XCTAssertEqual(claim, "jobs." + id.uuidString)
        XCTAssertEqual(JobProcessorIdentity.jobID(fromToolCallID: claim), id)
        XCTAssertEqual(JobProcessorIdentity.callID(jobID: id), claim,
                       "the grammar must be deterministic (row-derived, never random)")
    }

    /// The observed candidate-07 identity spaces, as fixed synthetic values:
    /// the durable claim of the job row and the submitting provider call id
    /// NEVER coincide — this is the exact condition the pre-repair fence
    /// (`claim != row.toolCallID`) made unsatisfiable for every
    /// model-submitted job grant.
    func testObservedCandidateFailureIdentitySpacesAreDisjoint() throws {
        let rowID = try XCTUnwrap(UUID(uuidString: "DB8FFC71-B37D-4D1D-879C-06A1D6852164"))
        let submittedProviderCallID = "call_r3c_2c3a3161fd_000001"
        let durable = JobProcessorIdentity.callID(jobID: rowID)
        XCTAssertEqual(durable, "jobs.DB8FFC71-B37D-4D1D-879C-06A1D6852164")
        XCTAssertNotEqual(durable, submittedProviderCallID)
        XCTAssertNil(JobProcessorIdentity.jobID(fromToolCallID: submittedProviderCallID),
                     "a provider call id is NOT a durable job identity in either direction")
    }

    /// Echoed variants are not the durable identity: a lowercase claim still
    /// PARSES to the same UUID (the original parser's tolerance is kept for
    /// tracking only), but the canonical `callID` value differs, so the
    /// grant lane's exact-equality fence keeps refusing echoes and trailing
    /// noise — identity strings ride UNCHANGED, same rule as the shell
    /// mailbox and the grant GET_STATE echo.
    func testEchoedVariantsAreNotTheCanonicalDurableIdentity() {
        let id = UUID()
        let durable = JobProcessorIdentity.callID(jobID: id)
        let lowercase = "jobs." + id.uuidString.lowercased()
        XCTAssertEqual(JobProcessorIdentity.jobID(fromToolCallID: lowercase), id)
        XCTAssertNotEqual(durable, lowercase)
        XCTAssertNotEqual(durable, durable + " ")
        XCTAssertNotEqual(durable, "JOBS." + id.uuidString)
        XCTAssertNil(JobProcessorIdentity.jobID(fromToolCallID: "jobs.garbage"))
    }
}
