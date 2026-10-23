// SPDX-License-Identifier: MPL-2.0
// Focused origin/binding/legacy-absence regressions for the G03-R3
// failed-start receipt handoff (job-150dee8e1ed14ba1) in LinuxShellPump.
// Author-written against the exact public 349a8690b91a73eae29a73df5cafdb9fdea2f878
// baseline; intended for the existing app JVM unit-test source set
// (kotlinx-serialization-json is already a production dependency; org.json
// is NOT used here on purpose — the same constraint the adjacent
// LinuxShellPumpRecoveryMergeTest documents). The completion ORDER itself
// (real drain/quiescence + grant/CoreIO close BEFORE the claim settles)
// stays owned by the unchanged watch structure; these tests pin ONLY the
// bounded decision functions the handoff adds. NOT executed by this lane.
package com.floe.android.host.linux

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private const val CONTROL = "3f2a1b0c-0000-4000-8000-000000000001" // pump control request ID
private val KEY = "ab".repeat(16)                                  // 32 lowercase hex
private val UPPER_KEY = KEY.uppercase()
private const val RUN_UPPER = "A1B2C3D4-0000-4000-9000-000000000004"
private const val RUN_LOWER = "a1b2c3d4-0000-4000-9000-000000000004"

private fun recoveryText(
    record: String = "importRestore",
    sessionKey: String = KEY,
    runText: String = RUN_UPPER,
    trigger: String = "cancelRequested",
    restored: String = "3",
    reverted: String = "1",
    retained: String = "0",
): String = """{"record":"$record","sessionKey":"$sessionKey","runID":"$runText","trigger":"$trigger",
    "restoredPriorChanges":$restored,"revertedNewEntries":$reverted,"retainedFailures":$retained}"""

private fun failedReceipt(
    state: String = "failed",
    requestID: String = CONTROL,
    failureCode: String? = "importCancelled",
    recovery: String? = recoveryText(),
): String = buildString {
    append("""{"requestID":"$requestID","state":"$state","code":"operation_failed"""")
    if (failureCode != null) append(""","failureCode":"$failureCode"""")
    if (recovery != null) append(""","recovery":$recovery""")
    append("}")
}

private fun JsonObject.text(key: String): String? = (this[key] as? JsonPrimitive)?.content

class LinuxShellPumpFailedStartReceiptTest {

    // MARK: - Origin: the SAME control request's REAL failed kernel terminal

    @Test fun validOwnFailedTerminalCapturesExactly() {
        val evidence = LinuxShellPump.sanitizeFailedStartReceipt(failedReceipt(), CONTROL)
        assertNotNull(evidence)
        assertEquals("importCancelled", evidence!!.failureCode)
        assertEquals("importRestore", evidence.recovery.text("record"))
        assertEquals(KEY, evidence.recovery.text("sessionKey"))
        // Canonical UUID text and counters survive the closed rebuild.
        assertEquals(RUN_UPPER, evidence.recovery.text("runID"))
        assertEquals("cancelRequested", evidence.recovery.text("trigger"))
        assertTrue(evidence.recovery.toString().contains("\"restoredPriorChanges\":3"))
        assertTrue(evidence.recovery.toString().contains("\"revertedNewEntries\":1"))
        assertTrue(evidence.recovery.toString().contains("\"retainedFailures\":0"))
    }

    @Test fun legacyFailedTerminalStaysAbsentNotZeroed() {
        // The byte-identical legacy kernel record: no addenda keys at all.
        assertNull(LinuxShellPump.sanitizeFailedStartReceipt(
            failedReceipt(failureCode = null, recovery = null), CONTROL))
    }

    @Test fun foreignControlRequestIsDropped() {
        // Only THIS session's own control terminal qualifies; a failed input/
        // resize/install record (different requestID) can never contaminate.
        assertNull(LinuxShellPump.sanitizeFailedStartReceipt(
            failedReceipt(requestID = "9f2a1b0c-0000-4000-8000-000000000009"), CONTROL))
    }

    @Test fun nonFailedStatesNeverCapture() {
        // "No recovery claimed from generic quiescence alone": queued,
        // running, completed, unknown and a missing state capture NOTHING
        // even if they (impossibly) carried the additive fields.
        for (state in listOf("queued", "running", "completed", "unknown", "")) {
            assertNull(LinuxShellPump.sanitizeFailedStartReceipt(failedReceipt(state = state), CONTROL))
        }
    }

    // MARK: - Strict closed grammar (malformed -> ABSENT, never partial)

    @Test fun partialPairDropsEverything() {
        assertNull(LinuxShellPump.sanitizeFailedStartReceipt(failedReceipt(recovery = null), CONTROL))
        assertNull(LinuxShellPump.sanitizeFailedStartReceipt(failedReceipt(failureCode = null), CONTROL))
    }

    @Test fun unboundedOrNonPrintableFailureCodeDropped() {
        assertNull(LinuxShellPump.sanitizeFailedStartReceipt(failedReceipt(failureCode = "x".repeat(49)), CONTROL))
        assertNull(LinuxShellPump.sanitizeFailedStartReceipt(failedReceipt(failureCode = "has space"), CONTROL))
        assertNull(LinuxShellPump.sanitizeFailedStartReceipt(failedReceipt(failureCode = "line\nbreak"), CONTROL))
        assertNull(LinuxShellPump.sanitizeFailedStartReceipt(failedReceipt(failureCode = ""), CONTROL))
    }

    @Test fun closedFieldNamesRejectExtraOrMissing() {
        val extra = failedReceipt(recovery = recoveryText().removeSuffix("}") +
            ",\"absPath\":\"/private/tmp/x\"}")
        assertNull(LinuxShellPump.sanitizeFailedStartReceipt(extra, CONTROL))
        val missing = """{"record":"importRestore","sessionKey":"$KEY","trigger":"t",
            "restoredPriorChanges":1,"revertedNewEntries":1,"retainedFailures":0}"""
        assertNull(LinuxShellPump.sanitizeFailedStartReceipt(failedReceipt(recovery = missing), CONTROL))
    }

    @Test fun grammarViolationsDropped() {
        assertNull(LinuxShellPump.sanitizeFailedStartReceipt(
            failedReceipt(recovery = recoveryText(record = "exportFinish")), CONTROL))
        // Uppercase hex session key violates the closed lowercase grammar.
        assertNull(LinuxShellPump.sanitizeFailedStartReceipt(
            failedReceipt(recovery = recoveryText(sessionKey = UPPER_KEY)), CONTROL))
        // Non-UUID run echo (the exact Core canonical form is required).
        assertNull(LinuxShellPump.sanitizeFailedStartReceipt(
            failedReceipt(recovery = recoveryText(runText = "not-a-uuid")), CONTROL))
        // 49-char trigger exceeds the closed token bound.
        assertNull(LinuxShellPump.sanitizeFailedStartReceipt(
            failedReceipt(recovery = recoveryText(trigger = "t".repeat(49))), CONTROL))
    }

    @Test fun countersMustBeExactNonnegativeIntegers() {
        // Bool, strings, fractions, negatives and Long overflow are refused,
        // never coerced or truncated.
        for (bad in listOf("true", "\"3\"", "3.5", "-1", "99999999999999999999999")) {
            assertNull("counter $bad must not capture", LinuxShellPump.sanitizeFailedStartReceipt(
                failedReceipt(recovery = recoveryText(restored = bad)), CONTROL))
        }
        // retainedFailures>0 IS a legitimate honest measurement: capture it.
        assertNotNull(LinuxShellPump.sanitizeFailedStartReceipt(
            failedReceipt(recovery = recoveryText(restored = "0", reverted = "0", retained = "2")), CONTROL))
    }

    @Test fun sanitizedRecoveryCarriesOnlyTheClosedSevenFields() {
        val evidence = LinuxShellPump.sanitizeFailedStartReceipt(failedReceipt(), CONTROL)!!
        assertEquals(setOf("record", "sessionKey", "runID", "trigger",
            "restoredPriorChanges", "revertedNewEntries", "retainedFailures"),
            evidence.recovery.keys)
        assertTrue(evidence.recovery.toString().length < 512) // the 4 KiB ceiling is never approached
    }

    // MARK: - Completion-time re-bind (grant session / exact run / epoch)

    private fun boundEvidence(sessionKey: String = KEY, runText: String = RUN_UPPER) =
        LinuxShellPump.sanitizeFailedStartReceipt(failedReceipt(recovery = recoveryText(sessionKey = sessionKey, runText = runText)), CONTROL)!!

    @Test fun bindsOnlyToOwnGrantSessionOwnRunCurrentEpoch() {
        assertTrue(LinuxShellPump.bindsFailedStartEvidence(boundEvidence(), KEY, RUN_LOWER, true))
        // Case-insensitive canonical UUID identity: Core echoes UPPER while
        // the pump stores the Java-normalised lower form (same precedent as
        // the per-execution recovery merge above); an equal-text accident
        // with a DIFFERENT UUID must still fail (tested next).
        assertTrue(LinuxShellPump.bindsFailedStartEvidence(boundEvidence(), KEY, RUN_UPPER, true))
    }

    @Test fun foreignOrStaleBindingDropsTheAddendum() {
        assertFalse(LinuxShellPump.bindsFailedStartEvidence(boundEvidence(), "cd".repeat(16), RUN_LOWER, true))
        assertFalse(LinuxShellPump.bindsFailedStartEvidence(boundEvidence(), null, RUN_LOWER, true))
        assertFalse(LinuxShellPump.bindsFailedStartEvidence(
            boundEvidence(runText = "B1B2C3D4-0000-4000-9000-000000000004"), KEY, RUN_LOWER, true))
        // A stale native generation NEVER publishes: absence, not zeros.
        assertFalse(LinuxShellPump.bindsFailedStartEvidence(boundEvidence(), KEY, RUN_LOWER, false))
    }
}
