// SPDX-License-Identifier: MPL-2.0
//
// n08 honest POSIX shell contract (one-shot113). The recorded run assumed
// Bash-style directory brace expansion in an exec.shell command. The real
// non-interactive entrypoint is `/bin/sh -lc` in the Debian guest (dash),
// so brace expansion is unavailable even before the model's malformed
// quote. The description is the schema-level contract the model reads; this
// regression pins the corrected, non-overclaiming text and the guidance
// against masking a failed setup step with a trailing echo.
// AUTHORED, NOT EXECUTED — compilation and the unified test run stay with
// the primary coordinator.

import XCTest
import FloeAndroidShellTools

final class LocalShellPosixContractTests: XCTestCase {
    func testDescriptionStatesTheRealNoninteractiveShell() {
        let description = LocalShellTool.toolDescription
        XCTAssertTrue(description.contains("/bin/sh -lc"))
        XCTAssertTrue(description.contains("dash"))
        XCTAssertTrue(description.contains("not Bash"))
    }

    func testDescriptionRejectsBashBraceExpansionAndExplicitPathAssumptions() {
        let description = LocalShellTool.toolDescription
        XCTAssertTrue(description.contains("brace expansion"))
        XCTAssertTrue(description.contains("arrays"))
        XCTAssertTrue(description.contains("process substitution"))
        XCTAssertTrue(description.contains("pass each path explicitly"))
    }

    func testDescriptionRequiresRealExitStatusChecks() {
        let description = LocalShellTool.toolDescription
        XCTAssertTrue(description.contains("check every setup step's exit status"))
        XCTAssertTrue(description.contains("trailing echo"))
        XCTAssertTrue(description.contains("does not prove"))
    }

    func testDescriptionDirectsRecoverableSetupMistakesToANonDestructiveCorrection() {
        let description = LocalShellTool.toolDescription
        XCTAssertTrue(
            description.contains("Do not delete files or directories the user did not ask to delete")
        )
        XCTAssertTrue(description.contains("non-destructive command"))
    }

    func testCommandSchemaRepeatsThePOSIXEntrypoint() {
        let schema = LocalShellTool.parametersJSON
        XCTAssertTrue(schema.contains("runs as /bin/sh -lc"))
        XCTAssertTrue(schema.contains("no Bash brace expansion"))
    }

    func testBashRequiresAnExplicitAvailabilityProbe() {
        let description = LocalShellTool.toolDescription
        XCTAssertTrue(description.contains("Use bash -lc only after command -v bash proves Bash is installed"))
    }
}
