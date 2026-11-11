// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import com.floe.android.rootsystem.SettingsChange
import com.floe.android.rootsystem.SettingsChangeAction
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Source-only fixtures for the typed settings operations. The Runner seam is
 * scripted per call, so every decision below is exercised against a real
 * argv sequence and a real (fake) Settings-provider transcript — no device,
 * no shell, no model text.
 */
class SettingsOperationsTest {

    private class ScriptedRunner(
        private val user: Int = 0,
        private val script: (callIndex: Int, argv: List<String>) -> Pair<Int, String>,
    ) : SettingsOperations.Runner {
        val calls = ArrayList<List<String>>()
        var cancelled = false

        override fun run(
            argv: List<String>,
            timeoutMillis: Long,
            cancelled: () -> Boolean,
            onTail: (String) -> Unit,
        ): Int {
            if (cancelled()) throw SettingsOperations.SettingsException("cancelled")
            val (exit, tail) = script(calls.size, argv)
            calls += argv
            onTail(tail)
            return exit
        }
    }

    private fun ops(user: Int = 0, script: (Int, List<String>) -> Pair<Int, String>) =
        SettingsOperations({ user }, ScriptedRunner(user, script))

    private fun brightnessPut(value: String) =
        SettingsChange("system", "screen_brightness", SettingsChangeAction.PUT, value)

    /** get -> "120", put -> ok, get -> "84" */
    @Test
    fun putRetainsOldValueAndVerifiesStoredReadBack() {
        val transcript = listOf(
            listOf("/system/bin/settings", "get", "--user", "0", "system", "screen_brightness") to (0 to "120\n"),
            listOf("/system/bin/settings", "--user", "0", "put", "system", "screen_brightness", "84") to (0 to ""),
            listOf("/system/bin/settings", "get", "--user", "0", "system", "screen_brightness") to (0 to "84\n"),
        )
        var index = 0
        val operations = ops { _, argv ->
            val next = transcript[index]
            index += 1
            assertEquals(next.first, argv)
            next.second
        }
        val receipt = operations.write(listOf(brightnessPut("84"))) { false }
        assertFalse(receipt.cancelled)
        assertEquals(1, receipt.ok)
        val item = receipt.items.single()
        assertTrue(item.succeeded)
        assertEquals("setting_put_ok", item.detailCode)
        assertEquals("120", item.oldValue)
        assertEquals("84", item.requestedValue)
        assertEquals("84", item.effectiveValue)
        assertEquals(0, item.userId)
        assertFalse(item.deviceWide)
    }

    /** The OEM clamps: put ok exit but stored value differs -> honest failure. */
    @Test
    fun putWithDifferentStoredValueReportsMismatch() {
        var index = 0
        val tails = listOf("120\n", "", "60\n")
        val operations = ops { _, _ -> (0 to tails[index]).also { index += 1 } }
        val receipt = operations.write(listOf(brightnessPut("200"))) { false }
        val item = receipt.items.single()
        assertFalse(item.succeeded)
        assertEquals("setting_effective_mismatch", item.detailCode)
        assertEquals("200", item.requestedValue)
        assertEquals("60", item.effectiveValue)
        assertEquals("120", item.oldValue)
    }

    /** put exits non-zero with a real provider error tail -> failure with detail. */
    @Test
    fun putFailurePreservesOemErrorTail() {
        var index = 0
        val tails = listOf("120\n", "Error: failed to write\n", "120\n")
        val operations = ops { _, _ ->
            val exit = if (index == 1) 255 else 0
            (exit to tails[index]).also { index += 1 }
        }
        val receipt = operations.write(listOf(brightnessPut("84"))) { false }
        val item = receipt.items.single()
        assertFalse(item.succeeded)
        assertEquals("setting_put_failed", item.detailCode)
        assertEquals("Error: failed to write", item.failureDetail)
        assertEquals("120", item.oldValue)
    }

    /** Restore of an originally-absent value: delete and read-back absent. */
    @Test
    fun deleteRestoresOriginallyAbsentValue() {
        var index = 0
        val tails = listOf("null\n", "", "null\n")
        val operations = ops { _, _ -> (0 to tails[index]).also { index += 1 } }
        val receipt = operations.write(
            listOf(SettingsChange("system", "user_rotation", SettingsChangeAction.DELETE, null)),
        ) { false }
        val item = receipt.items.single()
        assertTrue(item.succeeded)
        assertEquals("setting_delete_ok", item.detailCode)
        assertNull(item.oldValue)
        assertNull(item.effectiveValue)
    }

    @Test
    fun globalScaleUsesNoUserFlagAndReportsDeviceWide() {
        val calls = ArrayList<List<String>>()
        val tails = listOf("1.0\n", "", "0.5\n")
        var index = 0
        val operations = SettingsOperations(
            { 0 },
            SettingsOperations.Runner { argv, _, cancelled, onTail ->
                if (cancelled()) throw SettingsOperations.SettingsException("cancelled")
                calls += argv
                onTail(tails[index]); index += 1
                0
            },
        )
        val receipt = operations.write(
            listOf(SettingsChange("global", "window_animation_scale", SettingsChangeAction.PUT, "0.5")),
        ) { false }
        val item = receipt.items.single()
        assertTrue(item.succeeded)
        assertTrue(item.deviceWide)
        assertEquals(-1, item.userId)
        // Device-wide argv must not carry --user.
        assertEquals(
            listOf("/system/bin/settings", "get", "global", "window_animation_scale"),
            calls[0],
        )
        assertEquals(
            listOf("/system/bin/settings", "put", "global", "window_animation_scale", "0.5"),
            calls[1],
        )
    }

    /** Read reports absence for the provider's literal `null` output. */
    @Test
    fun readReportsAbsentValueWithoutFabrication() {
        val operations = ops { _, _ -> 0 to "null\n" }
        val result = operations.read("system", "haptic_feedback_enabled") { false }
        assertNull(result.value)
        assertEquals(0, result.userId)
        assertFalse(result.deviceWide)
    }

    /** CANCEL AFTER ONE COMPLETED: cancellation lands INSIDE the second item
     * (during its read-back), so the first item's receipt must survive, the
     * in-flight item must not be faked, and the batch reports cancelled with
     * the remaining item counted as skipped. */
    @Test
    fun cancellationInsideSecondItemPreservesFirstReceipt() {
        val cancelAfterCalls = 4 // item1: get,put,get (3) + item2 get (1)
        val runner = object : SettingsOperations.Runner {
            var calls = 0
            var flag = false
            override fun run(
                argv: List<String>,
                timeoutMillis: Long,
                cancelled: () -> Boolean,
                onTail: (String) -> Unit,
            ): Int {
                calls += 1
                if (calls <= 3) {
                    when (calls) {
                        1 -> onTail("120\n")
                        2 -> onTail("")
                        3 -> onTail("84\n")
                    }
                    return 0
                }
                // Fourth call: the read-back of the second item observes the
                // cancellation fence.
                flag = true
                throw SettingsOperations.SettingsException("cancelled")
            }
        }
        val operations = SettingsOperations({ 0 }, runner)
        val receipt = operations.write(
            listOf(
                brightnessPut("84"),
                SettingsChange("system", "screen_off_timeout", SettingsChangeAction.PUT, "60000"),
                SettingsChange("system", "sound_effects_enabled", SettingsChangeAction.PUT, "1"),
            ),
        ) { runner.flag }
        assertTrue(receipt.cancelled)
        assertEquals(1, receipt.ok)
        assertEquals(0, receipt.failed)
        assertEquals(2, receipt.skipped)
        assertEquals(3, receipt.requested)
        val item = receipt.items.single()
        assertTrue(item.succeeded)
        assertEquals("system", item.namespace)
        assertEquals("screen_brightness", item.key)
        // The in-flight timeout item produced NO receipt (never faked).
        assertFalse(receipt.items.any { it.key == "screen_off_timeout" })
        assertEquals(130, receipt.exitStatus())
    }

    /** Cancellation before the first item: nothing completed, all skipped. */
    @Test
    fun cancellationBeforeFirstItemSkipsEverything() {
        val operations = ops { _, _ -> 0 to "1\n" }
        val receipt = operations.write(listOf(brightnessPut("84"))) { true }
        assertTrue(receipt.cancelled)
        assertEquals(0, receipt.ok)
        assertEquals(1, receipt.skipped)
        assertTrue(receipt.items.isEmpty())
        assertEquals(130, receipt.exitStatus())
    }

    /** Per-item failure does not abort the batch; partial outcomes stay. */
    @Test
    fun itemFailureKeepsBatchGoingAndExitStatusIsNonZero() {
        var index = 0
        // item1: get ok, put fails(exit 255), get ok; item2: get/put/get ok.
        val operations = ops { _, _ ->
            index += 1
            when (index) {
                2 -> 255 to "SecurityException: denied"
                else -> 0 to when (index) {
                    1 -> "120\n"
                    3 -> "120\n"
                    4 -> "1\n"
                    6 -> "0\n"
                    else -> ""
                }
            }
        }
        val receipt = operations.write(
            listOf(
                brightnessPut("84"),
                SettingsChange("system", "accelerometer_rotation", SettingsChangeAction.PUT, "0"),
            ),
        ) { false }
        assertFalse(receipt.cancelled)
        assertEquals(1, receipt.ok)
        assertEquals(1, receipt.failed)
        assertEquals(0, receipt.skipped)
        assertEquals(1, receipt.exitStatus())
        assertEquals("setting_put_failed", receipt.items[0].detailCode)
        assertTrue(receipt.items[1].succeeded)
    }
}
