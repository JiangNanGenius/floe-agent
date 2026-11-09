// SPDX-License-Identifier: MPL-2.0
// Regression sources for the Alpha68 Samsung materialization-start failure
// (job-d169dd02bbb941bd): the runtime kernel's failed start receipt now
// carries a bounded closed-vocabulary `startFailureCode` (plus optional
// `startFailureErrno`); these tests pin the pump's strict capture grammar,
// its completion-time binding and the additive (never replacing) shape of the
// model-facing failed-start proof data.
// Author-written against the current LinuxShellPump companion; intended for
// the existing app JVM unit-test source set (kotlinx-serialization-json only,
// matching the adjacent failed-start receipt test). NOT executed by this lane.
package com.floe.android.host.linux

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private const val CONTROL = "7c1e2f90-1111-4222-8333-00000000000c"

private fun runtimeReceipt(
    state: String = "failed",
    requestID: String = CONTROL,
    code: String? = "rootfs_copy_io",
    errno: String? = null,
): String = buildString {
    append("""{"requestID":"$requestID","state":"$state","code":"operation_failed"""")
    if (code != null) append(""","startFailureCode":"$code"""")
    if (errno != null) append(""","startFailureErrno":$errno""")
    append("}")
}

class LinuxShellPumpRuntimeStartCodeTest {

    @Test fun validOwnFailedTerminalCapturesCodeAndErrno() {
        val token = LinuxShellPump.sanitizeStartFailureCode(
            runtimeReceipt(code = "rootfs_copy_io", errno = "5"), CONTROL)
        assertEquals("rootfs_copy_io", token!!.code)
        assertEquals(5, token.errno)
    }

    @Test fun codeWithoutErrnoCapturesWithNullErrno() {
        val token = LinuxShellPump.sanitizeStartFailureCode(runtimeReceipt(), CONTROL)
        assertEquals("rootfs_copy_io", token!!.code)
        assertNull(token.errno)
    }

    @Test fun legacyFailedTerminalWithoutAnyTokenStaysAbsent() {
        // The byte-identical legacy skeleton (no startFailureCode at all)
        // keeps the legacy proof shape: absence, not fake values.
        assertNull(LinuxShellPump.sanitizeStartFailureCode(runtimeReceipt(code = null), CONTROL))
    }

    @Test fun foreignControlRequestOrNonFailedStateNeverCaptures() {
        assertNull(LinuxShellPump.sanitizeStartFailureCode(
            runtimeReceipt(requestID = "9f2a1b0c-0000-4000-8000-000000000009"), CONTROL))
        for (state in listOf("queued", "running", "completed", "unknown", "")) {
            assertNull(LinuxShellPump.sanitizeStartFailureCode(runtimeReceipt(state = state), CONTROL))
        }
    }

    @Test fun grammarViolationsDropEverything() {
        // Uppercase, separators other than snake_case, overlength and empty
        // tokens are dropped; the vocabulary is lowercase snake_case <= 32.
        for (bad in listOf("Rootfs_Copy_IO", "rootfs copy io", "has/slash", "has\u0000nul",
                "x".repeat(33), "")) {
            assertNull("token <$bad> must not capture",
                LinuxShellPump.sanitizeStartFailureCode(runtimeReceipt(code = bad), CONTROL))
        }
    }

    @Test fun errnoMustBeAnExactBoundedInteger() {
        for (bad in listOf("0", "-1", "4096", "99999999999999999999", "3.5", "\"5\"", "true")) {
            assertNull("errno $bad must not capture",
                LinuxShellPump.sanitizeStartFailureCode(runtimeReceipt(errno = bad), CONTROL))
        }
        assertEquals(1, LinuxShellPump.sanitizeStartFailureCode(runtimeReceipt(errno = "1"), CONTROL)!!.errno)
        assertEquals(4095, LinuxShellPump.sanitizeStartFailureCode(runtimeReceipt(errno = "4095"), CONTROL)!!.errno)
    }

    @Test fun completionBindingRequiresCurrentEpochAndRealGrant() {
        val token = LinuxShellPump.sanitizeStartFailureCode(runtimeReceipt(), CONTROL)!!
        assertTrue(LinuxShellPump.bindsRuntimeStartFailure(token, "ab".repeat(16), epochMatches = true))
        assertFalse(LinuxShellPump.bindsRuntimeStartFailure(token, null, epochMatches = true))
        assertFalse(LinuxShellPump.bindsRuntimeStartFailure(token, "ab".repeat(16), epochMatches = false))
    }

    @Test fun rootfsStageReachesTheExistingNativeErrorCodeField() {
        val token = LinuxShellPump.sanitizeStartFailureCode(runtimeReceipt(), CONTROL)!!
        assertEquals("rootfs_copy_io", LinuxShellPump.reportedStartFailureCode("runtime_start_failed", token))
        assertEquals("rootfs_source_busy", LinuxShellPump.reportedStartFailureCode("runtime_start_failed",
            requireNotNull(LinuxShellPump.sanitizeStartFailureCode(runtimeReceipt(code = "rootfs_source_busy"), CONTROL))))
        assertEquals("runtime_start_failed", LinuxShellPump.reportedStartFailureCode(
            "runtime_start_failed", LinuxShellPump.RuntimeStartFailure("unknown_token", null)))
    }
}
