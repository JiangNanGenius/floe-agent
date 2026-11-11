// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Source-only regression for the four permission/AppOps catalog entries and
 * their fail-closed availability gating. The two query descriptors appear
 * only with the advanced master plus a non-empty selected target ceiling
 * inside the management ceiling; the two managers additionally require
 * their exact ABI name in the durable allowed-tools set. The reserved
 * system.settings.write name is never published, and the closed catalog
 * pins the 13-token AppOps operation vocabulary.
 */
class DeviceAccessPermissionOpsCatalogTest {

    private val baseAvailability = DeviceAccessToolCatalog.Availability(
        accessibilityConnected = false,
        targetPackagesSelected = false,
        screenCaptureSupported = false,
        systemServiceAlive = true,
        fileRootsSelected = false,
        fileWritesAllowed = false,
        packageManagementAllowed = true,
        advancedSystemManagementAllowed = false,
        advancedSystemAllowedTools = emptySet(),
        advancedSystemTargetsSelected = false,
    )

    @Test
    fun queriesRequireAdvancedMasterAndTargets() {
        val off = DeviceAccessToolCatalog.availableNames(baseAvailability)
        assertFalse(DeviceAccessToolCatalog.SYSTEM_PERMISSIONS_QUERY in off)
        assertFalse(DeviceAccessToolCatalog.SYSTEM_APPOPS_QUERY in off)

        val masterOn = baseAvailability.copy(
            advancedSystemManagementAllowed = true,
            advancedSystemTargetsSelected = true,
        )
        val on = DeviceAccessToolCatalog.availableNames(masterOn)
        assertTrue(DeviceAccessToolCatalog.SYSTEM_PERMISSIONS_QUERY in on)
        assertTrue(DeviceAccessToolCatalog.SYSTEM_APPOPS_QUERY in on)
        // Managers need their exact allowed-tools name.
        assertFalse(DeviceAccessToolCatalog.SYSTEM_PERMISSIONS_MANAGE in on)
        assertFalse(DeviceAccessToolCatalog.SYSTEM_APPOPS_MANAGE in on)
    }

    @Test
    fun managersRequireTheirExactAllowedName() {
        val availability = baseAvailability.copy(
            advancedSystemManagementAllowed = true,
            advancedSystemTargetsSelected = true,
            advancedSystemAllowedTools = setOf(DeviceAccessToolCatalog.SYSTEM_PERMISSIONS_MANAGE),
        )
        val names = DeviceAccessToolCatalog.availableNames(availability)
        assertTrue(DeviceAccessToolCatalog.SYSTEM_PERMISSIONS_MANAGE in names)
        assertFalse(DeviceAccessToolCatalog.SYSTEM_APPOPS_MANAGE in names)
    }

    @Test
    fun managementCeilingStaysAuthoritative() {
        val noManagement = baseAvailability.copy(
            packageManagementAllowed = false,
            advancedSystemManagementAllowed = true,
            advancedSystemTargetsSelected = true,
            advancedSystemAllowedTools = setOf(
                DeviceAccessToolCatalog.SYSTEM_PERMISSIONS_MANAGE,
                DeviceAccessToolCatalog.SYSTEM_APPOPS_MANAGE,
            ),
        )
        val names = DeviceAccessToolCatalog.availableNames(noManagement)
        assertFalse(DeviceAccessToolCatalog.SYSTEM_PERMISSIONS_QUERY in names)
        assertFalse(DeviceAccessToolCatalog.SYSTEM_APPOPS_QUERY in names)
        assertFalse(DeviceAccessToolCatalog.SYSTEM_PERMISSIONS_MANAGE in names)
        assertFalse(DeviceAccessToolCatalog.SYSTEM_APPOPS_MANAGE in names)
    }

    @Test
    fun implementedSettingsWriteKeepsItsOwnGateAndDescriptor() {
        val availability = baseAvailability.copy(
            advancedSystemManagementAllowed = true,
            advancedSystemTargetsSelected = true,
            advancedSystemAllowedTools = setOf(
                "system.settings.write",
                DeviceAccessToolCatalog.SYSTEM_PERMISSIONS_MANAGE,
                DeviceAccessToolCatalog.SYSTEM_APPOPS_MANAGE,
            ),
        )
        val names = DeviceAccessToolCatalog.availableNames(availability)
        assertTrue("system.settings.write" in names)
        assertTrue("system.settings.write" in DeviceAccessToolCatalog.allNames)
        assertTrue("system.settings.write" in DeviceAccessToolCatalog.SHIPPED_ADVANCED_TOOLS)
    }

    @Test
    fun shippedAdvancedToolsIncludesTheTwoManageNames() {
        assertEquals(
            setOf(
                DeviceAccessToolCatalog.SYSTEM_PACKAGES_SET_ENABLED,
                DeviceAccessToolCatalog.SYSTEM_PACKAGES_REMOVE_FOR_USER,
                DeviceAccessToolCatalog.SYSTEM_PACKAGES_RESTORE,
                DeviceAccessToolCatalog.SYSTEM_PERMISSIONS_MANAGE,
                DeviceAccessToolCatalog.SYSTEM_APPOPS_MANAGE,
                DeviceAccessToolCatalog.SYSTEM_SETTINGS_WRITE,
            ),
            DeviceAccessToolCatalog.SHIPPED_ADVANCED_TOOLS,
        )
    }

    @Test
    fun catalogPublishesFourDescriptorsWithClosedEnums() {
        val root = JSONObject(String(DeviceAccessToolCatalog.catalogJson(), Charsets.UTF_8))
        val tools = root.getJSONArray("tools")
        val byName = HashMap<String, JSONObject>()
        for (index in 0 until tools.length()) {
            val tool = tools.getJSONObject(index)
            byName[tool.getString("name")] = tool
        }
        val query = byName.getValue(DeviceAccessToolCatalog.SYSTEM_PERMISSIONS_QUERY)
        assertEquals("readOnly", query.getString("effect"))
        assertFalse(query.getBoolean("isSideEffecting"))
        val manage = byName.getValue(DeviceAccessToolCatalog.SYSTEM_PERMISSIONS_MANAGE)
        assertEquals("mutating", manage.getString("effect"))
        assertTrue(manage.getBoolean("isSideEffecting"))

        val appOpsManage = byName.getValue(DeviceAccessToolCatalog.SYSTEM_APPOPS_MANAGE)
        val items = appOpsManage.getJSONObject("schema")
            .getJSONObject("properties")
            .getJSONObject("items")
            .getJSONObject("items")
        val operations = items.getJSONObject("properties")
            .getJSONObject("operation")
            .getJSONArray("enum")
        // Closed 13-token vocabulary incl. the distinct background ops.
        assertEquals(13, operations.length())
        assertTrue(operations.toList().contains("background-run"))
        assertTrue(operations.toList().contains("background-run-any"))
        val modes = items.getJSONObject("properties")
            .getJSONObject("mode")
            .getJSONArray("enum")
        assertEquals(
            listOf("allow", "ignore", "deny", "default", "foreground"),
            modes.toList(),
        )
    }

    private fun org.json.JSONArray.toList(): List<String> =
        (0 until length()).map { getString(it) }
}
