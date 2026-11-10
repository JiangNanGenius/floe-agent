// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Source-only regression for the FULL-only trusted platform catalog. It pins
 * the closed descriptor shape the Swift parser enforces, the reviewed tool set
 * and the fail-closed availability mapping (no "available" optimism).
 */
class DeviceAccessToolCatalogTest {

    private val closedDescriptorKeys = setOf(
        "name", "description", "schema", "riskLabels", "effect",
        "isSideEffecting", "hostScope", "executionBoundary",
        "supportsConcurrentBatchDispatch",
    )

    private val canonicalRisks = setOf(
        "readsFiles", "writesFiles", "deletesFiles", "executesLocalCode",
        "executesRemoteCommand", "modifiesRemoteSystem", "networkAccess",
        "sendsDataToProvider", "controlsGUI", "accessesCredentials",
        "persistsPersonalData", "changesAgentBehavior",
    )

    @Test
    fun catalogIsClosedMainRunSerialAndUsesCanonicalMetadata() {
        val root = JSONObject(String(DeviceAccessToolCatalog.catalogJson(), Charsets.UTF_8))
        assertEquals(1, root.getInt("version"))
        val tools = root.getJSONArray("tools")
        assertEquals(DeviceAccessToolCatalog.allNames.size, tools.length())
        val seen = HashSet<String>()
        for (index in 0 until tools.length()) {
            val tool = tools.getJSONObject(index)
            assertEquals(closedDescriptorKeys, tool.keys().asSequence().toSet())
            val name = tool.getString("name")
            assertTrue(name in DeviceAccessToolCatalog.allNames)
            assertTrue("duplicate $name", seen.add(name))
            assertTrue(
                "ordinary network is unchanged; no raw host shell/code tool",
                !name.contains("shell") && !name.contains("exec"),
            )
            assertTrue(tool.getString("description").isNotBlank())
            assertFalse(tool.getBoolean("hostScope"))
            assertEquals("mainRunOnly", tool.getString("executionBoundary"))
            assertFalse(tool.getBoolean("supportsConcurrentBatchDispatch"))
            assertTrue(tool.getString("effect") in setOf("readOnly", "internalState", "mutating"))
            val sideEffecting = tool.getBoolean("isSideEffecting")
            if (tool.getString("effect") == "readOnly") assertFalse(sideEffecting)
            if (tool.getString("effect") == "mutating") assertTrue(sideEffecting)
            val risks = tool.getJSONArray("riskLabels")
            for (riskIndex in 0 until risks.length()) {
                val risk = risks.getString(riskIndex)
                assertTrue("unknown risk $risk", risk in canonicalRisks)
                assertFalse("code execution is never a platform tool risk",
                    risk == "executesLocalCode")
            }
            val schema = tool.getJSONObject("schema")
            assertEquals("object", schema.getString("type"))
            assertFalse(schema.getBoolean("additionalProperties"))
            assertTrue(schema.has("properties"))
        }
    }

    @Test
    fun mutatingToolsAreOnlyTheReviewedWritesAndPackageLifecycle() {
        val mutating = mutatingNames()
        assertEquals(
            setOf(
                DeviceAccessToolCatalog.PHONE_ACT,
                DeviceAccessToolCatalog.SYSTEM_FILES_WRITE,
                DeviceAccessToolCatalog.SYSTEM_FILES_MOVE,
                DeviceAccessToolCatalog.SYSTEM_FILES_DELETE,
                DeviceAccessToolCatalog.SYSTEM_PACKAGES_FORCE_STOP,
                DeviceAccessToolCatalog.SYSTEM_PACKAGES_STAGE,
                DeviceAccessToolCatalog.SYSTEM_PACKAGES_INSTALL,
                DeviceAccessToolCatalog.SYSTEM_PACKAGES_UNINSTALL,
                DeviceAccessToolCatalog.SYSTEM_PACKAGES_SET_ENABLED,
                DeviceAccessToolCatalog.SYSTEM_PACKAGES_REMOVE_FOR_USER,
                DeviceAccessToolCatalog.SYSTEM_PACKAGES_RESTORE,
            ),
            mutating,
        )
    }

    @Test
    fun availabilityFailsClosedUntilTheRealLayerIsUsable() {
        val nothing = DeviceAccessToolCatalog.availableNames(
            DeviceAccessToolCatalog.Availability())
        // Status is a read-only disclosure and is useful while everything is
        // off; nothing else may be advertised.
        assertEquals(setOf(DeviceAccessToolCatalog.SYSTEM_ACCESS_STATUS), nothing)

        val phone = DeviceAccessToolCatalog.availableNames(
            DeviceAccessToolCatalog.Availability(
                accessibilityConnected = true,
                targetPackagesSelected = true,
            ),
        )
        assertTrue(DeviceAccessToolCatalog.PHONE_OBSERVE in phone)
        assertTrue(DeviceAccessToolCatalog.PHONE_ACT in phone)
        assertFalse(
            "discovery follows the platform's real capture support, not a task grant",
            DeviceAccessToolCatalog.PHONE_SCREENSHOT in phone,
        )

        // Discovery is the POTENTIAL capability: the device supports capture.
        // Whether THIS task may see the screen is checked on every invocation
        // (screen_scope_off / whole_screen_consent_required) and never changes
        // what the live run was offered, so a grant made mid-run cannot make
        // the frozen catalog disagree with the provider request.
        val captureCapable = DeviceAccessToolCatalog.availableNames(
            DeviceAccessToolCatalog.Availability(
                accessibilityConnected = true,
                targetPackagesSelected = true,
                screenCaptureSupported = true,
            ),
        )
        assertTrue(DeviceAccessToolCatalog.PHONE_SCREENSHOT in captureCapable)

        val noTarget = DeviceAccessToolCatalog.availableNames(
            DeviceAccessToolCatalog.Availability(
                accessibilityConnected = true,
                targetPackagesSelected = false,
                screenCaptureSupported = true,
            ),
        )
        assertFalse(DeviceAccessToolCatalog.PHONE_SCREENSHOT in noTarget)
    }

    @Test
    fun systemAvailabilityRequiresARealServiceAndExplicitCeilings() {
        val serviceOnly = DeviceAccessToolCatalog.availableNames(
            DeviceAccessToolCatalog.Availability(systemServiceAlive = true),
        )
        assertTrue(DeviceAccessToolCatalog.SYSTEM_PROCESSES_QUERY in serviceOnly)
        assertTrue(DeviceAccessToolCatalog.SYSTEM_PACKAGES_QUERY in serviceOnly)
        assertTrue("the staged list is App-local and offered with any live service",
            DeviceAccessToolCatalog.SYSTEM_PACKAGES_STAGED in serviceOnly)
        assertFalse("no selected root", DeviceAccessToolCatalog.SYSTEM_FILES_LIST in serviceOnly)
        assertFalse("management is off by default",
            DeviceAccessToolCatalog.SYSTEM_PACKAGES_FORCE_STOP in serviceOnly)
        assertFalse(DeviceAccessToolCatalog.SYSTEM_PACKAGES_INSTALL in serviceOnly)
        assertFalse(DeviceAccessToolCatalog.SYSTEM_PACKAGES_UNINSTALL in serviceOnly)

        val roots = DeviceAccessToolCatalog.availableNames(
            DeviceAccessToolCatalog.Availability(
                systemServiceAlive = true,
                fileRootsSelected = true,
                fileWritesAllowed = false,
            ),
        )
        assertTrue(DeviceAccessToolCatalog.SYSTEM_FILES_LIST in roots)
        assertTrue(DeviceAccessToolCatalog.SYSTEM_FILES_READ in roots)
        assertFalse(DeviceAccessToolCatalog.SYSTEM_FILES_WRITE in roots)
        assertFalse(DeviceAccessToolCatalog.SYSTEM_FILES_DELETE in roots)

        val writes = DeviceAccessToolCatalog.availableNames(
            DeviceAccessToolCatalog.Availability(
                systemServiceAlive = true,
                fileRootsSelected = true,
                fileWritesAllowed = true,
                packageManagementAllowed = true,
            ),
        )
        assertTrue(DeviceAccessToolCatalog.SYSTEM_FILES_WRITE in writes)
        assertTrue(DeviceAccessToolCatalog.SYSTEM_FILES_MOVE in writes)
        assertTrue(DeviceAccessToolCatalog.SYSTEM_FILES_DELETE in writes)
        assertTrue(DeviceAccessToolCatalog.SYSTEM_PACKAGES_FORCE_STOP in writes)
        assertTrue(DeviceAccessToolCatalog.SYSTEM_PACKAGES_INSTALL in writes)
        assertTrue(DeviceAccessToolCatalog.SYSTEM_PACKAGES_UNINSTALL in writes)
        assertTrue(DeviceAccessToolCatalog.SYSTEM_PACKAGES_STAGED in writes)
        // Advanced app-state tools need the shared master + targets too.
        assertFalse(DeviceAccessToolCatalog.SYSTEM_PACKAGES_SET_ENABLED in writes)
        assertFalse(DeviceAccessToolCatalog.SYSTEM_PACKAGES_REMOVE_FOR_USER in writes)
        assertFalse(DeviceAccessToolCatalog.SYSTEM_PACKAGES_RESTORE in writes)
    }

    @Test
    fun advancedToolsRequireMasterAllowedNameAndTargets() {
        val base = DeviceAccessToolCatalog.Availability(
            systemServiceAlive = true,
            packageManagementAllowed = true,
            advancedSystemManagementAllowed = true,
            advancedSystemTargetsSelected = true,
        )
        // No allowed names: nothing extra is advertised.
        assertEquals(
            setOf(
                DeviceAccessToolCatalog.SYSTEM_ACCESS_STATUS,
                DeviceAccessToolCatalog.SYSTEM_PROCESSES_QUERY,
                DeviceAccessToolCatalog.SYSTEM_SERVICES_QUERY,
                DeviceAccessToolCatalog.SYSTEM_PACKAGES_QUERY,
                DeviceAccessToolCatalog.SYSTEM_NETWORK_DIAGNOSTICS,
                DeviceAccessToolCatalog.SYSTEM_PACKAGES_FORCE_STOP,
                DeviceAccessToolCatalog.SYSTEM_PACKAGES_INSTALL,
                DeviceAccessToolCatalog.SYSTEM_PACKAGES_UNINSTALL,
                DeviceAccessToolCatalog.SYSTEM_PACKAGES_STAGED,
                DeviceAccessToolCatalog.SYSTEM_PACKAGES_STAGE,
            ),
            DeviceAccessToolCatalog.availableNames(base),
        )
        val allThree = base.copy(
            advancedSystemAllowedTools = DeviceAccessToolCatalog.SHIPPED_ADVANCED_TOOLS,
        )
        val offered = DeviceAccessToolCatalog.availableNames(allThree)
        assertTrue(DeviceAccessToolCatalog.SYSTEM_PACKAGES_SET_ENABLED in offered)
        assertTrue(DeviceAccessToolCatalog.SYSTEM_PACKAGES_REMOVE_FOR_USER in offered)
        assertTrue(DeviceAccessToolCatalog.SYSTEM_PACKAGES_RESTORE in offered)

        // Master off or no targets: fail-closed even with allowed names.
        assertFalse(
            DeviceAccessToolCatalog.SYSTEM_PACKAGES_SET_ENABLED in
                DeviceAccessToolCatalog.availableNames(
                    allThree.copy(advancedSystemManagementAllowed = false)),
        )
        assertFalse(
            DeviceAccessToolCatalog.SYSTEM_PACKAGES_RESTORE in
                DeviceAccessToolCatalog.availableNames(
                    allThree.copy(advancedSystemTargetsSelected = false)),
        )
        // Reserved ABI names are never advertised.
        for (reserved in listOf(
            "system.permissions.manage", "system.appOps.manage", "system.settings.write")) {
            assertFalse(reserved in DeviceAccessToolCatalog.availableNames(allThree))
        }
    }

    @Test
    fun availabilityNeverExceedsTheBoundCatalog() {
        val all = DeviceAccessToolCatalog.availableNames(
            DeviceAccessToolCatalog.Availability(
                accessibilityConnected = true,
                targetPackagesSelected = true,
                screenCaptureSupported = true,
                systemServiceAlive = true,
                fileRootsSelected = true,
                fileWritesAllowed = true,
                packageManagementAllowed = true,
                advancedSystemManagementAllowed = true,
                advancedSystemAllowedTools = DeviceAccessToolCatalog.SHIPPED_ADVANCED_TOOLS,
                advancedSystemTargetsSelected = true,
            ),
        )
        assertEquals(DeviceAccessToolCatalog.allNames, all)
    }

    private fun mutatingNames(): Set<String> {
        val root = JSONObject(String(DeviceAccessToolCatalog.catalogJson(), Charsets.UTF_8))
        val tools = root.getJSONArray("tools")
        val result = HashSet<String>()
        for (index in 0 until tools.length()) {
            val tool = tools.getJSONObject(index)
            if (tool.getString("effect") == "mutating") result += tool.getString("name")
        }
        return result
    }
}
