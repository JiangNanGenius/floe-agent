// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Source-only regression for the strict settings tool arguments. JSON is
 * built with JSONArray/JSONObject or parsed literals (never raw Kotlin
 * collections) so the shapes mirror the real wire.
 */
class SettingsToolArgumentsTest {

    @Test
    fun readParsesClosedNamespaceAndKey() {
        val ok = SettingsToolArguments.read(
            JSONObject("{\"namespace\":\"system\",\"key\":\"screen_brightness\"}"),
        )
        assertTrue(ok is SettingsToolArguments.Request.Read)
        ok as SettingsToolArguments.Request.Read
        assertEquals("system", ok.namespace)
        assertEquals("screen_brightness", ok.key)

        assertEquals(
            "setting_namespace",
            (SettingsToolArguments.read(JSONObject("{\"namespace\":\"secure\",\"key\":\"x\"}")) as SettingsToolArguments.Request.Invalid).code,
        )
        assertEquals(
            "setting_key",
            (SettingsToolArguments.read(JSONObject("{\"namespace\":\"system\",\"key\":\"adb_enabled\"}")) as SettingsToolArguments.Request.Invalid).code,
        )
    }

    private fun change(namespace: String, key: String, action: String, value: String? = null) =
        JSONObject().apply {
            put("namespace", namespace)
            put("key", key)
            put("action", action)
            value?.let { put("value", it) }
        }

    @Test
    fun writeParsesNormalizesAndBoundsBatch() {
        val ok = SettingsToolArguments.write(
            JSONObject()
                .put("changes", org.json.JSONArray(listOf(
                    change("system", "screen_brightness", "put", "00084"),
                    change("global", "animator_duration_scale", "put", "0.500"),
                    change("system", "user_rotation", "delete"),
                ))),
        )
        assertTrue(ok is SettingsToolArguments.Request.Write)
        ok as SettingsToolArguments.Request.Write
        assertEquals(3, ok.changes.size)
        assertEquals("84", ok.changes[0].value)
        assertEquals("0.5", ok.changes[1].value)
        assertEquals(null, ok.changes[2].value)
    }

    @Test
    fun writeRefusesTooManyDuplicateUnknownAndBadValues() {
        val nine = org.json.JSONArray(
            List(9) { change("system", "screen_brightness", "put", it.toString()) },
        )
        assertEquals(
            "changes_too_many",
            (SettingsToolArguments.write(JSONObject().put("changes", nine)) as SettingsToolArguments.Request.Invalid).code,
        )
        assertEquals(
            "changes_duplicate",
            (SettingsToolArguments.write(
                JSONObject().put("changes", org.json.JSONArray(listOf(
                    change("system", "screen_brightness", "put", "1"),
                    change("system", "screen_brightness", "put", "2"),
                ))),
            ) as SettingsToolArguments.Request.Invalid).code,
        )
        assertEquals(
            "setting_key",
            (SettingsToolArguments.write(
                JSONObject().put("changes", org.json.JSONArray(listOf(
                    change("system", "not_a_key", "put", "1"),
                ))),
            ) as SettingsToolArguments.Request.Invalid).code,
        )
        assertEquals(
            "value_range",
            (SettingsToolArguments.write(
                JSONObject().put("changes", org.json.JSONArray(listOf(
                    change("system", "screen_brightness", "put", "999"),
                ))),
            ) as SettingsToolArguments.Request.Invalid).code,
        )
        assertEquals(
            "value",
            (SettingsToolArguments.write(
                JSONObject().put("changes", org.json.JSONArray(listOf(
                    change("global", "window_animation_scale", "put", "fast"),
                ))),
            ) as SettingsToolArguments.Request.Invalid).code,
        )
    }

    @Test
    fun writeRefusesMalformedShapes() {
        assertEquals(
            "changes",
            (SettingsToolArguments.write(JSONObject("{\"changes\":5}")) as SettingsToolArguments.Request.Invalid).code,
        )
        // A raw Kotlin collection stored by put() is NOT a JSONArray; the
        // parser must refuse it as malformed instead of crashing.
        assertEquals(
            "changes",
            (SettingsToolArguments.write(
                JSONObject().put("changes", listOf("a")),
            ) as SettingsToolArguments.Request.Invalid).code,
        )
        assertEquals(
            "changes",
            (SettingsToolArguments.write(
                JSONObject().put("changes", org.json.JSONArray(listOf(5))),
            ) as SettingsToolArguments.Request.Invalid).code,
        )
        assertEquals(
            "changes_empty",
            (SettingsToolArguments.write(
                JSONObject().put("changes", org.json.JSONArray()),
            ) as SettingsToolArguments.Request.Invalid).code,
        )
        assertEquals(
            "setting_action",
            (SettingsToolArguments.write(
                JSONObject().put("changes", org.json.JSONArray(listOf(
                    change("system", "screen_brightness", "toggle", "1"),
                ))),
            ) as SettingsToolArguments.Request.Invalid).code,
        )
        assertEquals(
            "value_missing",
            (SettingsToolArguments.write(
                JSONObject().put("changes", org.json.JSONArray(listOf(
                    change("system", "screen_brightness", "put"),
                ))),
            ) as SettingsToolArguments.Request.Invalid).code,
        )
        assertEquals(
            "changes",
            (SettingsToolArguments.write(
                JSONObject().put("changes", org.json.JSONArray(listOf(
                    change("system", "screen_brightness", "delete", "1"),
                ))),
            ) as SettingsToolArguments.Request.Invalid).code,
        )
    }
}
