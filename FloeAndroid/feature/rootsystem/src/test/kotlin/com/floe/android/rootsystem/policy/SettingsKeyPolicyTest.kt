// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Source-only regression for the closed settings table and batch grammar. */
class SettingsKeyPolicyTest {

    private fun spec(namespace: String, key: String) =
        SettingsKeyPolicy.specFor(namespace, key)

    @Test
    fun closedTableContainsOnlyThePracticalKeys() {
        val ids = SettingsKeyPolicy.ALL_SPECS.map { it.namespace + "/" + it.key }
        assertEquals(
            listOf(
                "system/screen_brightness",
                "system/screen_brightness_mode",
                "system/accelerometer_rotation",
                "system/user_rotation",
                "system/screen_off_timeout",
                "system/sound_effects_enabled",
                "system/haptic_feedback_enabled",
                "global/window_animation_scale",
                "global/transition_animation_scale",
                "global/animator_duration_scale",
            ),
            ids,
        )
        // Exactly seven system (per current user) + three global (device-wide).
        assertEquals(
            7,
            SettingsKeyPolicy.ALL_SPECS.count { it.namespace == SettingsKeyPolicy.NAMESPACE_SYSTEM },
        )
        assertEquals(
            3,
            SettingsKeyPolicy.ALL_SPECS.count {
                it.namespace == SettingsKeyPolicy.NAMESPACE_GLOBAL && it.deviceWide
            },
        )
        assertNull(spec("secure", "screen_brightness"))
        assertNull(spec("system", "enabled_notification_listeners"))
        assertNull(spec("system", "adb_enabled"))
    }

    @Test
    fun intValuesAreWholeAndInsideRange() {
        val brightness = spec("system", "screen_brightness")!!
        assertEquals(
            SettingsKeyPolicy.ValueCheck.Ok("84"),
            SettingsKeyPolicy.checkValue(brightness, "84"),
        )
        assertEquals("value_range", (SettingsKeyPolicy.checkValue(brightness, "256") as SettingsKeyPolicy.ValueCheck.Rejected).code)
        assertEquals("value", (SettingsKeyPolicy.checkValue(brightness, "-1") as SettingsKeyPolicy.ValueCheck.Rejected).code)
        assertEquals("value", (SettingsKeyPolicy.checkValue(brightness, "8.5") as SettingsKeyPolicy.ValueCheck.Rejected).code)
        assertEquals("value", (SettingsKeyPolicy.checkValue(brightness, "abc") as SettingsKeyPolicy.ValueCheck.Rejected).code)
        assertEquals("value_missing", (SettingsKeyPolicy.checkValue(brightness, "") as SettingsKeyPolicy.ValueCheck.Rejected).code)
        assertEquals("value", (SettingsKeyPolicy.checkValue(brightness, "1e3") as SettingsKeyPolicy.ValueCheck.Rejected).code)

        val timeout = spec("system", "screen_off_timeout")!!
        assertEquals("value_range", (SettingsKeyPolicy.checkValue(timeout, "5000") as SettingsKeyPolicy.ValueCheck.Rejected).code)
        assertEquals("value_range", (SettingsKeyPolicy.checkValue(timeout, "1800001") as SettingsKeyPolicy.ValueCheck.Rejected).code)
        assertEquals(
            SettingsKeyPolicy.ValueCheck.Ok("60000"),
            SettingsKeyPolicy.checkValue(timeout, "60000"),
        )
    }

    @Test
    fun scaleValuesAreFiniteDecimalsInsideRange() {
        val scale = spec("global", "window_animation_scale")!!
        assertEquals(
            SettingsKeyPolicy.ValueCheck.Ok("1.5"),
            SettingsKeyPolicy.checkValue(scale, "1.500"),
        )
        assertEquals(SettingsKeyPolicy.ValueCheck.Ok("0"), SettingsKeyPolicy.checkValue(scale, "0"))
        assertEquals(
            SettingsKeyPolicy.ValueCheck.Ok("10"),
            SettingsKeyPolicy.checkValue(scale, "10"),
        )
        assertEquals("value_range", (SettingsKeyPolicy.checkValue(scale, "10.5") as SettingsKeyPolicy.ValueCheck.Rejected).code)
        assertEquals("value", (SettingsKeyPolicy.checkValue(scale, "0.0001") as SettingsKeyPolicy.ValueCheck.Rejected).code)
        assertEquals("value", (SettingsKeyPolicy.checkValue(scale, "NaN") as SettingsKeyPolicy.ValueCheck.Rejected).code)
        assertEquals("value", (SettingsKeyPolicy.checkValue(scale, "Infinity") as SettingsKeyPolicy.ValueCheck.Rejected).code)
        assertEquals("value", (SettingsKeyPolicy.checkValue(scale, ".5") as SettingsKeyPolicy.ValueCheck.Rejected).code)
        assertEquals("value", (SettingsKeyPolicy.checkValue(scale, "1.") as SettingsKeyPolicy.ValueCheck.Rejected).code)
        assertEquals("value", (SettingsKeyPolicy.checkValue(scale, "1.0005") as SettingsKeyPolicy.ValueCheck.Rejected).code)
    }

    private fun put(namespace: String, key: String, value: String?) =
        SettingsKeyPolicy.ChangeRequest(
            namespace,
            key,
            SettingsKeyPolicy.ChangeAction.PUT,
            value,
        )

    private fun delete(namespace: String, key: String) =
        SettingsKeyPolicy.ChangeRequest(namespace, key, SettingsKeyPolicy.ChangeAction.DELETE, null)

    @Test
    fun batchIsBoundedAndRejectsDuplicatesAndUnknownKeys() {
        val nine = List(9) { put("system", "screen_brightness", it.toString()) }
        assertEquals(
            "changes_too_many",
            (SettingsKeyPolicy.checkBatch(nine) as SettingsKeyPolicy.BatchCheck.Rejected).code,
        )
        assertEquals(
            "changes_duplicate",
            (SettingsKeyPolicy.checkBatch(
                listOf(put("system", "screen_brightness", "1"), put("system", "screen_brightness", "2")),
            ) as SettingsKeyPolicy.BatchCheck.Rejected).code,
        )
        assertEquals(
            "setting_namespace",
            (SettingsKeyPolicy.checkBatch(listOf(put("secure", "x", "1"))) as SettingsKeyPolicy.BatchCheck.Rejected).code,
        )
        assertEquals(
            "setting_key",
            (SettingsKeyPolicy.checkBatch(
                listOf(put("system", "unknown_key", "1")),
            ) as SettingsKeyPolicy.BatchCheck.Rejected).code,
        )
        assertEquals(
            "value",
            (SettingsKeyPolicy.checkBatch(listOf(put("system", "screen_brightness", "high"))) as SettingsKeyPolicy.BatchCheck.Rejected).code,
        )
        assertEquals(
            "changes_empty",
            (SettingsKeyPolicy.checkBatch(emptyList()) as SettingsKeyPolicy.BatchCheck.Rejected).code,
        )
    }

    @Test
    fun batchNormalizesValuesAndKeepsDeleteValueless() {
        val result = SettingsKeyPolicy.checkBatch(
            listOf(
                put("system", "screen_brightness", "00084"),
                put("global", "animator_duration_scale", "0.500"),
                delete("system", "user_rotation"),
            ),
        )
        assertTrue(result is SettingsKeyPolicy.BatchCheck.Ok)
        val ok = (result as SettingsKeyPolicy.BatchCheck.Ok).changes
        assertEquals("84", ok[0].value)
        assertEquals("0.5", ok[1].value)
        assertNull(ok[2].value)
        assertFalse(ok[2].deviceWideForTest())
    }

    private fun SettingsKeyPolicy.ChangeRequest.deviceWideForTest(): Boolean =
        SettingsKeyPolicy.specFor(namespace, key)?.deviceWide == true
}
