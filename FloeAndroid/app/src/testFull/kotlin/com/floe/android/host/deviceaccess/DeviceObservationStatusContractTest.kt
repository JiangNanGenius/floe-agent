// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * N03 source-level contract: the trusted descriptors must explain the bounded
 * late-control coverage and separate potential screenshot support from the
 * CURRENT live consent/readiness, without advertising arguments or tools that
 * the host does not implement. The FS03 paging and FS04 focus/commit arguments
 * are ADDITIVE optional keys inside the same closed schema subset, so the
 * shared Swift bind and provider-facing compatibility are preserved.
 */
class DeviceObservationStatusContractTest {
    private fun descriptor(name: String): JSONObject {
        val root = JSONObject(String(DeviceAccessToolCatalog.catalogJson(), Charsets.UTF_8))
        val tools = root.getJSONArray("tools")
        for (index in 0 until tools.length()) {
            val tool = tools.getJSONObject(index)
            if (tool.getString("name") == name) return tool
        }
        throw AssertionError("$name missing from the trusted catalog")
    }

    private fun properties(name: String): Set<String> {
        val schema = descriptor(name).getJSONObject("schema")
        val props = schema.getJSONObject("properties")
        return props.keys().asSequence().toSet()
    }

    @Test
    fun observeDescriptorExplainsActionableFirstBoundedCoverage() {
        val description = descriptor(DeviceAccessToolCatalog.DEVICE_OBSERVE)
            .getString("description")
        assertTrue(description.contains("actionable-first"))
        assertTrue(description.contains("moreActions"))
        assertTrue(description.contains("scanned"))
        assertTrue(description.contains("includeInvisible"))
        assertTrue(description.contains("refusal does not change your selected apps"))
        assertTrue(description.contains("nextOffset"))
        assertTrue(description.contains("retained observation"))
        assertTrue(description.contains("truncated=scan"))
        assertFalse(description.contains("unlimited"))
        assertEquals(
            setOf("includeInvisible", "observationId", "offset"),
            properties(DeviceAccessToolCatalog.DEVICE_OBSERVE),
        )
    }

    @Test
    fun actDescriptorPublishesGenericFocusCommitAndRealScrollSemantics() {
        val description = descriptor(DeviceAccessToolCatalog.DEVICE_ACT)
            .getString("description")
        assertTrue(description.contains("focus"))
        assertTrue(description.contains("commit"))
        assertTrue(description.contains("IME action"))
        assertTrue(description.contains("Android 11+"))
        assertTrue(description.contains("ACTION_CLICK"))
        assertTrue(description.contains("never synthesizes a coordinate tap"))
        assertTrue(description.contains("ACTION_SCROLL_FORWARD"))
        assertTrue(description.contains("finger direction"))
        assertTrue(description.contains("field buffer"))
        assertTrue(description.contains("NOT proof"))
        val actionEnum = descriptor(DeviceAccessToolCatalog.DEVICE_ACT)
            .getJSONObject("schema")
            .getJSONObject("properties")
            .getJSONObject("action")
            .getJSONArray("enum")
            .let { list -> (0 until list.length()).map { list.getString(it) } }
        assertTrue("focus" in actionEnum)
        assertTrue("commit" in actionEnum)
        assertTrue("click" in actionEnum)
        assertTrue("launch" in actionEnum)
    }

    @Test
    fun screenshotDescriptorDistinguishesPotentialFromLiveConsentAndRecovery() {
        val description = descriptor(DeviceAccessToolCatalog.DEVICE_SCREENSHOT)
            .getString("description")
        assertTrue(description.contains("system.access.status"))
        assertTrue(description.contains("screenshotReady"))
        assertTrue(description.contains("Android 14"))
        assertTrue(description.contains("Android 11-13"))
        assertTrue(description.contains("window_screenshot_unsupported"))
        assertTrue(description.contains("screen_scope_off"))
        assertTrue(description.contains("whole_screen_consent_required"))
        assertTrue(description.contains("observe again"))
        assertTrue(description.contains("does not deselect"))
        assertTrue(description.contains("No Play grant"))
        assertEquals(
            setOf("observationId"),
            properties(DeviceAccessToolCatalog.DEVICE_SCREENSHOT),
        )
    }

    @Test
    fun accessStatusDescriptorPublishesLiveScreenshotReadinessFields() {
        val description = descriptor(DeviceAccessToolCatalog.SYSTEM_ACCESS_STATUS)
            .getString("description")
        assertTrue(description.contains("screenshotSupport"))
        assertTrue(description.contains("window_or_display"))
        assertTrue(description.contains("display_only"))
        assertTrue(description.contains("wholeScreenConsent"))
        assertTrue(description.contains("screenshotReady"))
        assertTrue(description.contains("displayReady"))
        assertTrue(description.contains("windowReady"))
        assertTrue(description.contains("screenshotNext"))
        assertTrue(description.contains("never changes a permission"))
        assertTrue(description.contains("VNC"))
        assertTrue(properties(DeviceAccessToolCatalog.SYSTEM_ACCESS_STATUS).isEmpty())
    }
}
