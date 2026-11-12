// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The dynamic device.observe schema exposes only the closed source selector. */
class DeviceObserveSourceSchemaTest {

    private fun tools(): List<org.json.JSONObject> {
        val array = JSONArray(String(DeviceAccessToolCatalog.catalogJson(), Charsets.UTF_8))
        return (0 until array.length()).map { array.getJSONObject(it) }
    }

    @Test fun observeSchemaOffersAutoAndAdbOnly() {
        val observe = tools().first { it.getString("name") == "device.observe" }
        val properties = observe.getJSONObject("schema").getJSONObject("properties")
        val values = properties.getJSONObject("source").getJSONArray("enum")
        val names = (0 until values.length()).map { values.getString(it) }
        assertEquals(listOf("auto", "adb"), names)
        val required = observe.getJSONObject("schema").getJSONArray("required")
        val requiredNames = (0 until required.length()).map { required.getString(it) }
        assertFalse("source stays optional for normal callers", "source" in requiredNames)
        assertTrue(properties.has("observationId"))
    }

    @Test fun actDescriptionPointsToTheFreshAdbObservePath() {
        val act = tools().first { it.getString("name") == "device.act" }
        val description = act.getString("description")
        assertTrue(description.contains("source=adb"))
        assertTrue(description.contains("fresh"))
        assertTrue(description.contains("never replay"))
    }
}
