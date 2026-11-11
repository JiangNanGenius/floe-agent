// SPDX-License-Identifier: MPL-2.0
// Regression sources for the N02 A5 Samsung environmentTransaction start
// failure (job-46036bc8e99f4602): the runtime kernel now types every
// environment-transaction prepare stage (bounded closed vocabulary plus
// optional numeric errno and bounded divergence detail); these tests pin the
// pump's strict capture grammar for the transaction stage/detail, its
// completion-time binding and the additive (never replacing) shape of the
// model-facing failed-start proof data.
// Author-written against the current LinuxShellPump companion; intended for
// the existing app JVM unit-test source set (kotlinx-serialization-json only,
// matching the adjacent failed-start receipt test). NOT executed by this lane.
package com.floe.android.host.linux

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

private const val STAGE_CONTROL = "7c1e2f90-1111-4222-8333-0000000000d1"

private fun stageReceipt(
    state: String = "failed",
    requestID: String = STAGE_CONTROL,
    code: String? = "transaction_snapshot_verify_changed",
    errno: String? = null,
    detail: String? = null,
): String = buildString {
    append("""{"requestID":"$requestID","state":"$state","code":"operation_failed"""")
    if (code != null) append(""","startFailureCode":"$code"""")
    if (errno != null) append(""","startFailureErrno":$errno""")
    if (detail != null) append(""","startFailureDetail":"$detail"""")
    append("}")
}

class LinuxShellPumpTransactionStageCodeTest {

    @Test fun everyTransactionStageReachesTheNativeCodeField() {
        for (code in listOf("transaction_journal_present", "transaction_insufficient_space",
                "transaction_image_io", "transaction_snapshot_copy_io",
                "transaction_snapshot_verify_changed", "transaction_identity_changed",
                "transaction_publish_io")) {
            val token = LinuxShellPump.sanitizeStartFailureCode(stageReceipt(code = code), STAGE_CONTROL)
            assertEquals(code, LinuxShellPump.reportedStartFailureCode("runtime_start_failed", token!!))
        }
    }

    @Test fun verifyStageCapturesBoundedDivergenceDetail() {
        val token = LinuxShellPump.sanitizeStartFailureCode(
            stageReceipt(code = "transaction_snapshot_verify_changed", errno = "28", detail = "modified"),
            STAGE_CONTROL)
        assertEquals("transaction_snapshot_verify_changed", token!!.code)
        assertEquals(28, token.errno)
        assertEquals("modified", token.detail)
    }

    @Test fun detailWithoutErrnoCapturesWithNullErrno() {
        val token = LinuxShellPump.sanitizeStartFailureCode(
            stageReceipt(detail = "content"), STAGE_CONTROL)
        assertEquals("content", token!!.detail)
        assertNull(token.errno)
    }

    @Test fun malformedDetailDropsTheWholeCapture() {
        // A malformed detail never reaches the receipt partially forwarded:
        // the capture as a whole is dropped and the legacy proof stays
        // byte-identical (absence stays absence).
        for (bad in listOf("Modified", "has space", "has/slash", "x".repeat(33), "")) {
            assertNull("detail <$bad> must drop the capture",
                LinuxShellPump.sanitizeStartFailureCode(stageReceipt(detail = bad), STAGE_CONTROL))
        }
    }

    @Test fun stringOrBoolDetailNeverCaptures() {
        assertNull(LinuxShellPump.sanitizeStartFailureCode(
            """{"requestID":"$STAGE_CONTROL","state":"failed","code":"operation_failed",""" +
                """"startFailureCode":"transaction_image_io","startFailureDetail":5}""", STAGE_CONTROL))
        assertNull(LinuxShellPump.sanitizeStartFailureCode(
            """{"requestID":"$STAGE_CONTROL","state":"failed","code":"operation_failed",""" +
                """"startFailureCode":"transaction_image_io","startFailureDetail":true}""", STAGE_CONTROL))
    }

    @Test fun legacyTerminalAndForeignRequestStayAbsent() {
        assertNull(LinuxShellPump.sanitizeStartFailureCode(stageReceipt(code = null), STAGE_CONTROL))
        assertNull(LinuxShellPump.sanitizeStartFailureCode(
            stageReceipt(requestID = "9f2a1b0c-0000-4000-8000-000000000009"), STAGE_CONTROL))
    }
}
