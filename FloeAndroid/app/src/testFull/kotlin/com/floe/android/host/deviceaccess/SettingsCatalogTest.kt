// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Source-only regression for the settings additions to the trusted catalog:
 * closed descriptors, the ABI six-name gate and fail-closed availability.
 */
class SettingsCatalogTest {

    private fun tool(name: String): JSONObject {
        val root = JSONObject(String(DeviceAccessToolCatalog.catalogJson(), Charsets.UTF_8))
        val tools = root.getJSONArray("tools")
        for (index in 0 until tools.length()) {
            val tool = tools.getJSONObject(index)
            if (tool.getString("name") == name) return tool
        }
        throw NoSuchElementException(name)
    }

    @Test
    fun settingsToolsAreInTheClosedCatalog() {
        assertTrue(DeviceAccessToolCatalog.SYSTEM_SETTINGS_READ in DeviceAccessToolCatalog.allNames)
        assertTrue(DeviceAccessToolCatalog.SYSTEM_SETTINGS_WRITE in DeviceAccessToolCatalog.allNames)
        // Tool count stays inside the settled catalog capacity (32 max).
        assertTrue(DeviceAccessToolCatalog.allNames.size <= 32)
        val read = tool(DeviceAccessToolCatalog.SYSTEM_SETTINGS_READ)
        assertEquals("readOnly", read.getString("effect"))
        assertFalse(read.getBoolean("isSideEffecting"))
        val write = tool(DeviceAccessToolCatalog.SYSTEM_SETTINGS_WRITE)
        assertEquals("mutating", write.getString("effect"))
        assertTrue(write.getBoolean("isSideEffecting"))
        assertEquals(
            listOf("modifiesRemoteSystem"),
            write.getJSONArray("riskLabels").let { risks ->
                List(risks.length()) { risks.getString(it) }
            },
        )
        val changes = write.getJSONObject("schema")
            .getJSONObject("properties")
            .getJSONObject("changes")
        assertEquals(1, changes.getInt("minItems"))
        assertEquals(8, changes.getInt("maxItems"))
        assertEquals("object", changes.getJSONObject("items").getString("type"))
    }

    @Test
    fun advancedAbiListIsExactlyTheSixClosedNames() {
        assertEquals(
            setOf(
                "system.packages.setEnabled",
                "system.packages.removeForUser",
                "system.packages.restore",
                "system.permissions.manage",
                "system.appOps.manage",
                "system.settings.write",
            ),
            DeviceAccessToolCatalog.ADVANCED_ABI_TOOL_NAMES,
        )
    }

    private fun availability(
        serviceAlive: Boolean = true,
        management: Boolean = true,
        master: Boolean = true,
        tools: Set<String> = setOf(DeviceAccessToolCatalog.SYSTEM_SETTINGS_WRITE),
    ) = DeviceAccessToolCatalog.Availability(
        systemServiceAlive = serviceAlive,
        packageManagementAllowed = management,
        advancedSystemManagementAllowed = master,
        advancedSystemAllowedTools = tools,
    )

    @Test
    fun readIsOfferedWithAnyLiveService() {
        val names = DeviceAccessToolCatalog.availableNames(
            availability(serviceAlive = true, management = false, master = false, tools = emptySet()),
        )
        assertTrue(DeviceAccessToolCatalog.SYSTEM_SETTINGS_READ in names)
        assertFalse(DeviceAccessToolCatalog.SYSTEM_SETTINGS_WRITE in names)
    }

    @Test
    fun writeNeedsManagementMasterAndItsOwnNameButNoTargets() {
        assertFalse(
            DeviceAccessToolCatalog.SYSTEM_SETTINGS_WRITE in
                DeviceAccessToolCatalog.availableNames(availability(master = false)),
        )
        assertFalse(
            DeviceAccessToolCatalog.SYSTEM_SETTINGS_WRITE in
                DeviceAccessToolCatalog.availableNames(availability(management = false)),
        )
        assertFalse(
            DeviceAccessToolCatalog.SYSTEM_SETTINGS_WRITE in
                DeviceAccessToolCatalog.availableNames(
                    availability(tools = setOf("system.permissions.manage")),
                ),
        )
        assertFalse(
            DeviceAccessToolCatalog.SYSTEM_SETTINGS_WRITE in
                DeviceAccessToolCatalog.availableNames(availability(serviceAlive = false)),
        )
        // The exact ABI name is required; a look-alike never passes.
        assertFalse(
            DeviceAccessToolCatalog.SYSTEM_SETTINGS_WRITE in
                DeviceAccessToolCatalog.availableNames(
                    availability(tools = setOf("system.settings.read")),
                ),
        )
        assertTrue(
            DeviceAccessToolCatalog.SYSTEM_SETTINGS_WRITE in
                DeviceAccessToolCatalog.availableNames(availability()),
        )
    }
}
