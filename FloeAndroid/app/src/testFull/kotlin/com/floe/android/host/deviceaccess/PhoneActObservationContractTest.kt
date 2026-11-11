// SPDX-License-Identifier: MPL-2.0
// Proposed JVM regression source. Authored only in this private lane; Main
// runs it in the batched JVM set. No compile/run claim here.
// Intended final location (the stored job scope omitted the real deviceaccess
// test source set; see HANDOFF.json for the path rationale):
//   FloeAndroid/app/src/testFull/kotlin/com/floe/android/host/deviceaccess/
//   PhoneActObservationContractTest.kt
package com.floe.android.host.deviceaccess

import com.floe.android.host.deviceaccess.PhoneActionArguments.Request.Dispatch
import com.floe.android.host.deviceaccess.PhoneActionArguments.Request.InvalidArguments
import com.floe.android.host.deviceaccess.PhoneActionArguments.Request.MissingObservation
import com.floe.android.phonecontrol.PhoneControlAction
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the repaired `device.act` observation contract (published as
 * `phone.act` before the device-namespace rename; the wire contract itself
 * is unchanged) after the Alpha72 known-password fixture run:
 *  - a well-formed non-launch action without observationId classifies as
 *    [MissingObservation], which the host maps to the precise bounded
 *    [PhoneActionArguments.OBSERVATION_REQUIRED_CODE] failure instead of the
 *    undifferentiated `invalid_arguments` the device trace showed;
 *  - `launch` keeps both compatibilities unchanged: an omitted
 *    observationId dispatches with "" (the approved current-navigation
 *    launch path) and an explicit id passes through untouched;
 *  - malformed arguments keep the original precedence and refuse BEFORE any
 *    observation decision; the text/sensitiveText XOR, strict String type,
 *    size bound and explicit empty-string clear are untouched by the rule;
 *  - the advertised catalog stays inside the closed keyword subset the
 *    shared Swift bind enforces — a `oneOf`/`if`/`then` conditional is NOT
 *    provider-compatible here and would refuse the entire catalog at bind
 *    time — so the conditional rule lives in model-facing guidance plus the
 *    host-side precise code, never in an unsupported schema keyword;
 *  - the guidance and the host code name the SAME recovery token, and that
 *    token survives the transport's failure-code grammar byte-for-byte;
 *  - the catalog advertises ONLY the canonical device.* names: the legacy
 *    phone.* spellings are resolvable through the bounded Swift alias rule
 *    for persisted records but are never discoverable, so a tool cannot be
 *    advertised twice.
 *
 * All payloads are synthetic canaries; the fixture package name is the
 * already-published QA harness, not a user app.
 */
class PhoneActObservationContractTest {

    private fun request(raw: String): PhoneActionArguments.Request =
        PhoneActionArguments.request(JSONObject(raw))

    private fun descriptor(name: String): JSONObject {
        val root = JSONObject(String(DeviceAccessToolCatalog.catalogJson(), Charsets.UTF_8))
        val tools = root.getJSONArray("tools")
        for (index in 0 until tools.length()) {
            val tool = tools.getJSONObject(index)
            if (tool.getString("name") == name) return tool
        }
        throw AssertionError("$name missing from the trusted catalog")
    }

    // ------------------------------------------------- missing observation

    @Test
    fun everyWellFormedNonLaunchActionWithoutObservationIdIsMissingObservation() {
        // The exact Alpha72 failing shape: a well-formed sensitive fill that
        // omitted the parameter entirely. It is now a distinct outcome, not
        // a fold into invalid_arguments.
        assertTrue(
            request("""{"action":"setText","nodeRef":"n6","sensitiveText":"canary-obs72"}""")
                is MissingObservation,
        )
        assertTrue(request("""{"action":"click","nodeRef":"n6"}""") is MissingObservation)
        assertTrue(
            request("""{"action":"setText","nodeRef":"n6","text":"plain"}""") is MissingObservation,
        )
        assertTrue(
            request("""{"action":"scroll","nodeRef":"n6","direction":"forward"}""")
                is MissingObservation,
        )
        assertTrue(
            request("""{"action":"swipe","nodeRef":"n6","direction":"up"}""") is MissingObservation,
        )
        // back and home are non-launch too: the rule keeps covering them.
        assertTrue(request("""{"action":"back"}""") is MissingObservation)
        assertTrue(request("""{"action":"home"}""") is MissingObservation)
    }

    @Test
    fun nonLaunchActionsWithObservationIdDispatchWithTheExactId() {
        val click = request(
            """{"action":"click","nodeRef":"n6","observationId":"observation-id-1"}""",
        ) as Dispatch
        assertEquals("observation-id-1", click.observationId)
        assertEquals(PhoneControlAction.Click("n6"), click.action)
        val sensitive = request(
            """{"action":"setText","nodeRef":"n6","sensitiveText":"canary-obs72",""" +
                """"observationId":"observation-id-2"}""",
        ) as Dispatch
        assertEquals("observation-id-2", sensitive.observationId)
        val back = request("""{"action":"back","observationId":"observation-id-3"}""") as Dispatch
        assertEquals(PhoneControlAction.Back, back.action)
    }

    // --------------------------------------------------- launch compat

    @Test
    fun launchCompatibilityIsUnchangedWithAndWithoutObservationId() {
        val bare = request("""{"action":"launch","packageName":"com.floe.qa.password72"}""")
        val bareDispatch = bare as Dispatch
        // "" means the host takes the existing launchApplication path; the
        // decision never fabricates an implicit latest observation.
        assertEquals("", bareDispatch.observationId)
        assertEquals(
            PhoneControlAction.Launch("com.floe.qa.password72"),
            bareDispatch.action,
        )
        val withId = request(
            """{"action":"launch","packageName":"com.floe.qa.password72",""" +
                """"observationId":"observation-id-1"}""",
        ) as Dispatch
        assertEquals("observation-id-1", withId.observationId)
    }

    // ------------------------------------------------- precedence & XOR

    @Test
    fun malformedArgumentsTakePrecedenceOverTheObservationRule() {
        // Genuinely broken arguments must NOT be mislabeled as a missing
        // observation; the host still answers invalid_arguments first.
        assertTrue(request("""{"action":"setText","nodeRef":"n6"}""") is InvalidArguments)
        assertTrue(request("""{"action":"teleport"}""") is InvalidArguments)
        assertTrue(request("""{"action":"click"}""") is InvalidArguments)
        assertTrue(request("""{"action":"launch"}""") is InvalidArguments)
        assertTrue(request("""{"action":"scroll","nodeRef":"n6"}""") is InvalidArguments)
    }

    @Test
    fun theSensitiveXorAndClearRulesSurviveTheObservationDecision() {
        assertTrue(
            request(
                """{"action":"setText","nodeRef":"n6","text":"a","sensitiveText":"b",""" +
                    """"observationId":"o1"}""",
            ) is InvalidArguments,
        )
        assertTrue(
            request("""{"action":"setText","nodeRef":"n6","observationId":"o1"}""")
                is InvalidArguments,
        )
        val sensitive = request(
            """{"action":"setText","nodeRef":"n6","sensitiveText":"canary-obs72",""" +
                """"observationId":"o1"}""",
        ) as Dispatch
        val setText = sensitive.action as PhoneControlAction.SetText
        assertTrue(setText.sensitive)
        assertEquals("canary-obs72", setText.text)
        assertFalse(setText.toString().contains("canary-obs72"))
        // An explicit empty sensitiveText stays the valid protected clear.
        val clear = request(
            """{"action":"setText","nodeRef":"n6","sensitiveText":"",""" +
                """"observationId":"o1"}""",
        ) as Dispatch
        val clearText = clear.action as PhoneControlAction.SetText
        assertTrue(clearText.sensitive)
        assertEquals("", clearText.text)
    }

    // ------------------------------------------------ transport shape

    @Test
    fun theObservationFailureCodeIsTransportShapedAndSharedWithTheGuidance() {
        val code = PhoneActionArguments.OBSERVATION_REQUIRED_CODE
        // Swift's isValidFailureCode grammar: letter first, ASCII
        // alphanumeric plus '_'/'-', at most 64 characters.
        assertTrue(Regex("^[A-Za-z][A-Za-z0-9_-]{0,63}$").matches(code))
        // BoundedResultText is the Kotlin-side sanitizer for failure codes;
        // the token must survive it byte-for-byte.
        assertEquals(code, BoundedResultText.token(code))
        // The model-facing recovery token in the catalog is the SAME code.
        assertTrue(descriptor(DeviceAccessToolCatalog.DEVICE_ACT).getString("description")
            .contains(code))
    }

    // ---------------------------------------------------- guidance

    @Test
    fun theActGuidanceTeachesTheRequirementAndRecoveryWithoutNewKeywords() {
        val act = descriptor(DeviceAccessToolCatalog.DEVICE_ACT)
        val description = act.getString("description")
        assertTrue(description.contains("every action except launch requires"))
        assertTrue(description.contains("Only action=launch may omit observationId"))
        assertTrue(description.contains("observe again first"))
        assertFalse("the trusted descriptor stays single-line", description.contains("\n"))
        assertTrue(
            description.toByteArray(Charsets.UTF_8).size <= 4_096,
        )
        val schema = act.getJSONObject("schema")
        val required = schema.getJSONArray("required")
        // The conditional rule cannot be pushed into `required`: that would
        // break the launch-without-observation compatibility at the mailbox
        // pre-dispatch validator, and the closed subset rejects conditionals.
        assertEquals(1, required.length())
        assertEquals("action", required.getString(0))
        val observationId = schema.getJSONObject("properties")
            .getJSONObject("observationId")
        val propertyDescription = observationId.getString("description")
        assertTrue(
            propertyDescription.startsWith("Required for every action except launch"),
        )
        assertFalse("the misleading 'optional' framing is retired",
            propertyDescription.contains("optional"))
        // Shared schema-node annotation ceiling.
        assertTrue(propertyDescription.toByteArray(Charsets.UTF_8).size <= 256)
        assertEquals("string", observationId.getString("type"))
        assertEquals(1, observationId.getInt("minLength"))
        assertEquals(64, observationId.getInt("maxLength"))
    }

    @Test
    fun theObserveGuidanceNamesTheActHandoff() {
        val observe = descriptor(DeviceAccessToolCatalog.DEVICE_OBSERVE)
        val description = observe.getString("description")
        assertTrue(description.contains("Pass the returned observation= id as observationId"))
        assertTrue(description.contains("every device.act action except launch requires it"))
        assertTrue(description.toByteArray(Charsets.UTF_8).size <= 4_096)
    }

    @Test
    fun theCatalogAdvertisesOnlyCanonicalDeviceNames() {
        // The rename is discovery-exact: the trusted catalog carries the
        // canonical device.* names and NEVER the legacy phone.* spellings,
        // so a resumed model cannot see a tool advertised twice and unknown
        // phone.* names have nothing to attach to. Persisted phone.* records
        // stay resumable through the bounded Swift alias rule instead.
        val root = JSONObject(String(DeviceAccessToolCatalog.catalogJson(), Charsets.UTF_8))
        val tools = root.getJSONArray("tools")
        val names = HashSet<String>()
        for (index in 0 until tools.length()) {
            names += tools.getJSONObject(index).getString("name")
        }
        assertTrue(DeviceAccessToolCatalog.DEVICE_OBSERVE in names)
        assertTrue(DeviceAccessToolCatalog.DEVICE_ACT in names)
        assertTrue(DeviceAccessToolCatalog.DEVICE_SCREENSHOT in names)
        assertFalse("legacy phone.observe must not be advertised",
            "phone.observe" in names)
        assertFalse("legacy phone.act must not be advertised",
            "phone.act" in names)
        assertFalse("legacy phone.screenshot must not be advertised",
            "phone.screenshot" in names)
        // The same exact-name rule guards fail-closed availability.
        val available = DeviceAccessToolCatalog.availableNames(
            DeviceAccessToolCatalog.Availability(
                accessibilityConnected = true,
                targetPackagesSelected = true,
                screenCaptureSupported = true,
            ),
        )
        assertFalse("phone.observe" in available)
        assertFalse("phone.act" in available)
        assertFalse("phone.screenshot" in available)
        assertTrue(DeviceAccessToolCatalog.DEVICE_SCREENSHOT in available)
    }

    @Test
    fun legacyPhoneConstantsCarryTheCanonicalValues() {
        // The retained PHONE_* identifiers keep the canonical device values
        // so out-of-lane legacy test source and historical receipts stay
        // readable; they can never resurrect the old wire spelling.
        assertEquals("device.observe", DeviceAccessToolCatalog.PHONE_OBSERVE)
        assertEquals("device.act", DeviceAccessToolCatalog.PHONE_ACT)
        assertEquals("device.screenshot", DeviceAccessToolCatalog.PHONE_SCREENSHOT)
        assertEquals(DeviceAccessToolCatalog.DEVICE_OBSERVE,
            DeviceAccessToolCatalog.PHONE_OBSERVE)
        assertEquals(DeviceAccessToolCatalog.DEVICE_ACT,
            DeviceAccessToolCatalog.PHONE_ACT)
        assertEquals(DeviceAccessToolCatalog.DEVICE_SCREENSHOT,
            DeviceAccessToolCatalog.PHONE_SCREENSHOT)
    }

    @Test
    fun everyCatalogSchemaNodeUsesOnlyTheSharedValidatorsClosedKeywordSubset() {
        // Mirrors the Swift PlatformToolSchemaValidator.requireOnly subset.
        // This is the ACTUAL schema-preservation boundary: the catalog
        // schema is re-serialized verbatim at bind, and any keyword outside
        // this map refuses the ENTIRE catalog (descriptorInvalid), silently
        // removing every phone/system tool from the live run. A conditional
        // `required` for non-launch actions is therefore impossible in the
        // advertised schema; the enforced contract is the host-side precise
        // code pinned above.
        val annotations = setOf("type", "description", "title")
        val perType = mapOf(
            "object" to annotations + setOf("properties", "required", "additionalProperties"),
            "array" to annotations + setOf("items", "minItems", "maxItems"),
            "string" to annotations + setOf("minLength", "maxLength", "enum"),
            "integer" to annotations + setOf("minimum", "maximum"),
            "number" to annotations + setOf("minimum", "maximum"),
            "boolean" to annotations,
        )
        val conditionals = setOf(
            "oneOf", "anyOf", "allOf", "if", "then", "else", "not",
            "dependentRequired", "dependentSchemas", "prefixItems",
        )
        val root = JSONObject(String(DeviceAccessToolCatalog.catalogJson(), Charsets.UTF_8))
        val tools = root.getJSONArray("tools")
        for (index in 0 until tools.length()) {
            val tool = tools.getJSONObject(index)
            assertSchemaNode(tool.getString("name"), tool.getJSONObject("schema"), perType, conditionals)
        }
    }

    private fun assertSchemaNode(
        tool: String,
        node: JSONObject,
        perType: Map<String, Set<String>>,
        conditionals: Set<String>,
    ) {
        val type = node.getString("type")
        val allowed = perType[type]
            ?: throw AssertionError("$tool: unsupported schema type $type")
        for (key in node.keys().asSequence().toSet()) {
            assertTrue("$tool: unsupported schema keyword $key", key in allowed)
            assertTrue("$tool: conditional keyword $key must never appear", key !in conditionals)
        }
        if (type == "object") {
            val properties = node.getJSONObject("properties")
            for (key in properties.keys()) {
                assertSchemaNode(
                    tool, properties.getJSONObject(key), perType, conditionals,
                )
            }
        }
        if (type == "array") {
            assertSchemaNode(tool, node.getJSONObject("items"), perType, conditionals)
        }
    }
}
