// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * G03-R3 authored-not-run boundary tests for the LinuxShellPump first-use
 * preflight REQUEST/REPLY grammar (pure parts only, per repo convention of
 * keeping plain JVM unit tests Android-framework-free). The mailbox claim
 * handling, grant minting and JNI behaviour are exercised by Main's
 * grouped compile + device acceptance, not here.
 */
class LinuxWorkspacePreflightClaimTest {

    // MEANINGFUL fixture: the Swift `UUID.uuidString` / CoreWorkspaceGrant
    // echo grammar is UPPER-CASE and actually CONTAINS A-F hex letters. A
    // digit-only fixture is identical under both Java grammars and therefore
    // MISSES the v1 lowercase-only bug — never use one as the pass case.
    private val coreCanonical = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"

    @Test fun coreIdentityFencingAcceptsUppercaseCanonicalBytes() {
        // Every REAL Core run containing A-F previously failed this gate.
        assertTrue(LinuxShellPump.isCanonicalUUID(coreCanonical))
        assertTrue(LinuxShellPump.isCanonicalUUID("ABCDEF12-3456-7890-ABCD-EF1234567890"))
        // Java lowercase canonical is a DIFFERENT grammar (runtime control
        // request IDs via RuntimeWire) and must NOT pass Core fencing.
        assertFalse(LinuxShellPump.isCanonicalUUID(coreCanonical.lowercase()))
        assertFalse(LinuxShellPump.isCanonicalUUID("3F2504E0-4F89-11d3-9A0C-0305E82C3301"))
        assertFalse(LinuxShellPump.isCanonicalUUID("$coreCanonical "))
        assertFalse(LinuxShellPump.isCanonicalUUID("3F2504E0-4F89-11D3-9A0C-0305E82C330"))
        assertFalse(LinuxShellPump.isCanonicalUUID("3F2504E0_4F89_11D3_9A0C_0305E82C3301"))
        assertFalse(LinuxShellPump.isCanonicalUUID(""))
        assertFalse(LinuxShellPump.isCanonicalUUID("run-42"))
        assertFalse(LinuxShellPump.isCanonicalUUID("GG2504E0-4F89-11D3-9A0C-0305E82C3301"))
    }

    @Test fun claimedIOReleaseNeedsSameRequestTerminalOrProvenRetirement() {
        // Only the SAME authenticated request's real kernel terminal settles.
        assertTrue(LinuxShellPump.isPreflightTerminalReceipt("completed"))
        assertTrue(LinuxShellPump.isPreflightTerminalReceipt("failed"))
        // Unknown/progress/missing replies and elapsed budgets are NOT
        // retirement and must never fabricate a settled outcome.
        assertFalse(LinuxShellPump.isPreflightTerminalReceipt("unknown"))
        assertFalse(LinuxShellPump.isPreflightTerminalReceipt("queued"))
        assertFalse(LinuxShellPump.isPreflightTerminalReceipt("running"))
        assertFalse(LinuxShellPump.isPreflightTerminalReceipt(null))
        // Peer/process retirement is proven ONLY by a DIFFERENT measured
        // generation than the one actually dispatched to.
        val dispatched = "runtime:pid1000:gen" + "a".repeat(32)
        assertTrue(LinuxShellPump.isPeerRetirementProven(dispatched, "runtime:pid1001:gen" + "b".repeat(32)))
        assertFalse(LinuxShellPump.isPeerRetirementProven(dispatched, dispatched))
        assertFalse(LinuxShellPump.isPeerRetirementProven(dispatched, null))
        assertFalse(LinuxShellPump.isPeerRetirementProven(null, dispatched))
        assertFalse(LinuxShellPump.isPeerRetirementProven(null, null))
    }

    @Test fun environmentIdsAreBoundedTokensNeverPaths() {
        assertTrue(LinuxShellPump.ENVIRONMENT_ID.matches("env-7_2.a:x1"))
        assertFalse(LinuxShellPump.ENVIRONMENT_ID.matches(""))
        assertFalse(LinuxShellPump.ENVIRONMENT_ID.matches("-leading"))
        assertFalse(LinuxShellPump.ENVIRONMENT_ID.matches("has space"))
        assertFalse(LinuxShellPump.ENVIRONMENT_ID.matches("/guess/temp/path"))
        assertFalse(LinuxShellPump.ENVIRONMENT_ID.matches("x".repeat(65)))
    }

    @Test fun ownCancellationsAreANarrowClosedCodeSet() {
        // CANCEL_CODES decides "no invalidation of the live facts": any
        // real failure code must stay OUTSIDE the set.
        assertTrue(LinuxShellPump.CANCEL_CODES.contains("caller_stopped"))
        assertTrue(LinuxShellPump.CANCEL_CODES.contains("preflight_cancelled"))
        assertFalse(LinuxShellPump.CANCEL_CODES.contains("runtime_busy"))
        assertFalse(LinuxShellPump.CANCEL_CODES.contains("workspace_unresolved"))
        assertFalse(LinuxShellPump.CANCEL_CODES.contains("mapping_unsynced"))
        assertFalse(LinuxShellPump.CANCEL_CODES.contains("dispatch_unsettled"))
        assertFalse(LinuxShellPump.CANCEL_CODES.contains("deletion_plan"))
    }

    @Test fun reasonsAndCodesNeverEscapeTheAsciiTokenGrammar() {
        assertTrue(LinuxShellPump.boundedToken("mapping_unsynced") == "mapping_unsynced")
        // Host filesystem messages (with spaces) must degrade to the fixed
        // refusal token instead of leaking paths into a reply or a reason.
        assertTrue(LinuxShellPump.boundedToken("No such file or directory") == "preflight_failed")
        assertTrue(LinuxShellPump.boundedCode(RuntimeException("runtime_busy")) == "runtime_busy")
        assertTrue(LinuxShellPump.boundedCode(RuntimeException("boom boom")) == "preflight_failed")
        // Overlong raw reasons are refused; they are not truncated into a new code.
        assertTrue(LinuxShellPump.boundedToken("x".repeat(32)) == "x".repeat(32))
        assertTrue(LinuxShellPump.boundedToken("x".repeat(33)) == "preflight_failed")
        assertTrue(LinuxShellPump.boundedToken("x".repeat(64)) == "preflight_failed")
    }
}
