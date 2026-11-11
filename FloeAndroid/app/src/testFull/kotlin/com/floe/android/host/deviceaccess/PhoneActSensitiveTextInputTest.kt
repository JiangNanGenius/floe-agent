// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.phonecontrol.PhoneControlAction
import com.floe.android.phonecontrol.PhoneControlLimits
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the `device.act` sensitive-text input wire contract (published as
 * `phone.act` before the device-namespace rename; the wire shape is
 * unchanged): exactly one
 * text-bearing key (`text` XOR `sensitiveText`), the closed boolean-free
 * schema, the unchanged risk/effect ceiling and the serial main-run-only
 * execution boundary. Payload values are synthetic canaries.
 */
class PhoneActSensitiveTextInputTest {

    private fun phoneActDescriptor(): JSONObject {
        val root = JSONObject(String(DeviceAccessToolCatalog.catalogJson(), Charsets.UTF_8))
        val tools = root.getJSONArray("tools")
        for (index in 0 until tools.length()) {
            val tool = tools.getJSONObject(index)
            if (tool.getString("name") == DeviceAccessToolCatalog.DEVICE_ACT) return tool
        }
        throw AssertionError("device.act missing from the trusted catalog")
    }

    @Test
    fun schemaDeclaresBothTextInputKeysUnderAClosedBoundedShape() {
        val act = phoneActDescriptor()
        val schema = act.getJSONObject("schema")
        assertFalse(schema.getBoolean("additionalProperties"))
        val required = schema.getJSONArray("required")
        assertEquals(1, required.length())
        assertEquals("action", required.getString(0))
        val properties = schema.getJSONObject("properties")
        assertEquals(
            setOf("observationId", "action", "nodeRef", "text", "sensitiveText",
                "direction", "packageName"),
            properties.keys().asSequence().toSet(),
        )
        // The wire has NO boolean sensitivity flag: sensitivity is expressed
        // by the explicit sensitiveText parameter itself.
        assertFalse(properties.has("sensitive"))
        val sensitive = properties.getJSONObject("sensitiveText")
        assertEquals("string", sensitive.getString("type"))
        assertEquals(0, sensitive.getInt("minLength"))
        assertEquals(2_000, sensitive.getInt("maxLength"))
        assertEquals(
            2_000,
            properties.getJSONObject("text").getInt("maxLength"),
        )
        val actionEnum = properties.getJSONObject("action").getJSONArray("enum")
        assertTrue(actionEnum.getString(1) == "setText")
        // The description teaches the boundary without secrets.
        val description = act.getString("description")
        assertTrue(description.contains("sensitiveText"))
        assertTrue(description.contains("never both"))
        assertTrue(description.contains("never read back"))
        assertTrue(description.contains("Never search"))
        // Model-facing copy stays English (single trusted descriptor).
        assertFalse(description.contains("\n"))
    }

    @Test
    fun riskAndExecutionCeilingAreUnchangedByTheSensitiveRoute() {
        val act = phoneActDescriptor()
        val risks = act.getJSONArray("riskLabels")
        assertEquals(
            setOf("controlsGUI", "sendsDataToProvider"),
            (0 until risks.length()).map { risks.getString(it) }.toSet(),
        )
        assertEquals("mutating", act.getString("effect"))
        assertTrue(act.getBoolean("isSideEffecting"))
        assertFalse(act.getBoolean("hostScope"))
        assertEquals("mainRunOnly", act.getString("executionBoundary"))
        assertFalse(act.getBoolean("supportsConcurrentBatchDispatch"))
    }

    @Test
    fun sensitiveTextParsesToASensitiveDispatch() {
        val action = PhoneActionArguments.parse(
            JSONObject(
                """{"action":"setText","nodeRef":"n7","sensitiveText":"canary-9f2c"}""",
            ),
        )
        assertTrue(action is PhoneControlAction.SetText)
        val setText = action as PhoneControlAction.SetText
        assertTrue(setText.sensitive)
        assertEquals("n7", setText.nodeRef)
        // Bytes are preserved exactly for the one dispatch, never echoed.
        assertEquals("canary-9f2c", setText.text)
        assertFalse(setText.toString().contains("canary-9f2c"))
    }

    @Test
    fun ordinaryTextParsesToTheUnchangedNonSensitiveDispatch() {
        val action = PhoneActionArguments.parse(
            JSONObject("""{"action":"setText","nodeRef":"n2","text":"search query"}"""),
        )
        assertTrue(action is PhoneControlAction.SetText)
        val setText = action as PhoneControlAction.SetText
        assertFalse(setText.sensitive)
        assertEquals("search query", setText.text)
        // Clearing an ordinary input keeps working (empty payload).
        val clear = PhoneActionArguments.parse(
            JSONObject("""{"action":"setText","nodeRef":"n2","text":""}"""),
        )
        assertTrue(clear is PhoneControlAction.SetText)
        assertEquals("", (clear as PhoneControlAction.SetText).text)
        assertFalse(clear.sensitive)
    }

    @Test
    fun theTwoTextInputKeysAreMutuallyExclusive() {
        val both = PhoneActionArguments.parse(
            JSONObject(
                """{"action":"setText","nodeRef":"n1","text":"plain","sensitiveText":"canary"}""",
            ),
        )
        assertNull("'text' and 'sensitiveText' together must be invalid", both)
        // There is no silent fallback: an empty sensitiveText is still the
        // sensitive route (used to clear a protected field), and it never
        // re-reads the ordinary key.
        val emptySensitive = PhoneActionArguments.parse(
            JSONObject("""{"action":"setText","nodeRef":"n1","sensitiveText":""}"""),
        )
        assertTrue(emptySensitive is PhoneControlAction.SetText)
        assertTrue((emptySensitive as PhoneControlAction.SetText).sensitive)
    }

    @Test
    fun oversizedSensitiveTextIsRefusedBeforeDispatch() {
        val oversized = "x".repeat(PhoneControlLimits.MAX_SET_TEXT_CHARS + 1)
        val arguments = JSONObject()
            .put("action", "setText")
            .put("nodeRef", "n1")
            .put("sensitiveText", oversized)
        assertNull(PhoneActionArguments.parse(arguments))
        val atLimit = JSONObject()
            .put("action", "setText")
            .put("nodeRef", "n1")
            .put("sensitiveText", "x".repeat(PhoneControlLimits.MAX_SET_TEXT_CHARS))
        assertNotNull(PhoneActionArguments.parse(atLimit))
    }

    @Test
    fun nonStringNullAndMissingInputsFailClosedInsteadOfImplicitClear() {
        // Compact synthetic decoder regression: org.json coercion and absent
        // keys must never dispatch an accidental clear.
        assertNull(PhoneActionArguments.parse(
            JSONObject("""{"action":"setText","nodeRef":"n1"}"""),
        ))
        assertNull(PhoneActionArguments.parse(
            JSONObject("""{"action":"setText","nodeRef":"n1","sensitiveText":null}"""),
        ))
        assertNull(PhoneActionArguments.parse(
            JSONObject("""{"action":"setText","nodeRef":"n1","text":null}"""),
        ))
        assertNull(PhoneActionArguments.parse(
            JSONObject("""{"action":"setText","nodeRef":"n1","text":5}"""),
        ))
        assertNull(PhoneActionArguments.parse(
            JSONObject("""{"action":"setText","nodeRef":"n1","sensitiveText":true}"""),
        ))
        assertNull(PhoneActionArguments.parse(
            JSONObject("""{"action":"setText","nodeRef":"n1","text":{"a":"b"}}"""),
        ))
        assertNull(PhoneActionArguments.parse(
            JSONObject("""{"action":"setText","nodeRef":"n1","sensitiveText":[1]}"""),
        ))
        // An explicit empty String remains the valid clear on both keys.
        val clearText = PhoneActionArguments.parse(
            JSONObject("""{"action":"setText","nodeRef":"n1","text":""}"""),
        )
        assertTrue(clearText is PhoneControlAction.SetText)
        assertFalse((clearText as PhoneControlAction.SetText).sensitive)
        val clearSensitive = PhoneActionArguments.parse(
            JSONObject("""{"action":"setText","nodeRef":"n1","sensitiveText":""}"""),
        )
        assertTrue((clearSensitive as PhoneControlAction.SetText).sensitive)
    }

    @Test
    fun malformedOrForgedRefsStillFailClosed() {
        assertNull(
            PhoneActionArguments.parse(
                JSONObject("""{"action":"setText","nodeRef":"","sensitiveText":"canary"}"""),
            ),
        )
        assertNull(
            PhoneActionArguments.parse(
                JSONObject("""{"action":"setText","nodeRef":"..","sensitiveText":"canary"}"""),
            ),
        )
        assertNull(
            PhoneActionArguments.parse(
                JSONObject("""{"action":"setText","sensitiveText":"canary"}"""),
            ),
        )
    }
}
