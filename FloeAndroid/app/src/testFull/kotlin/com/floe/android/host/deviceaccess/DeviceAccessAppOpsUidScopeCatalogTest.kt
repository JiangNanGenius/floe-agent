// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Focused regression for the N02 AppOps UID write scope descriptor: the
 * optional closed scope enum rides on the existing system.appOps.manage
 * items schema (no new tool name, no ABI change), the legacy closed
 * operation/mode enums are untouched, and the description states honestly
 * that a package override alone never changes the effective UID mode.
 */
class DeviceAccessAppOpsUidScopeCatalogTest {

    private fun appOpsManageDescriptor(): JSONObject {
        val root = JSONObject(String(DeviceAccessToolCatalog.catalogJson(), Charsets.UTF_8))
        val tools = root.getJSONArray("tools")
        for (index in 0 until tools.length()) {
            val tool = tools.getJSONObject(index)
            if (tool.getString("name") == DeviceAccessToolCatalog.SYSTEM_APPOPS_MANAGE) {
                return tool
            }
        }
        throw NoSuchElementException("system.appOps.manage descriptor missing")
    }

    @Test
    fun itemsSchemaCarriesTheClosedScopeEnum() {
        val items = appOpsManageDescriptor().getJSONObject("schema")
            .getJSONObject("properties")
            .getJSONObject("items")
            .getJSONObject("items")
        val properties = items.getJSONObject("properties")
        val scope = properties.getJSONObject("scope")
        assertEquals("string", scope.getString("type"))
        assertEquals(
            listOf("package", "uid"),
            (0 until scope.getJSONArray("enum").length()).map {
                scope.getJSONArray("enum").getString(it)
            },
        )
        // Scope is optional: legacy requests without it stay valid.
        val required = items.getJSONArray("required")
        val requiredNames = (0 until required.length()).map { required.getString(it) }
        assertTrue("packageName" in requiredNames)
        assertTrue("operation" in requiredNames)
        assertTrue("mode" in requiredNames)
        assertFalse("scope" in requiredNames)
    }

    @Test
    fun legacyClosedEnumsAreUnchanged() {
        val items = appOpsManageDescriptor().getJSONObject("schema")
            .getJSONObject("properties")
            .getJSONObject("items")
            .getJSONObject("items")
        val properties = items.getJSONObject("properties")
        assertEquals(
            13,
            properties.getJSONObject("operation").getJSONArray("enum").length(),
        )
        assertEquals(
            listOf("allow", "ignore", "deny", "default", "foreground"),
            (0 until properties.getJSONObject("mode").getJSONArray("enum").length()).map {
                properties.getJSONObject("mode").getJSONArray("enum").getString(it)
            },
        )
    }

    @Test
    fun noNewToolNameIsIntroduced() {
        // One bounded capability package: the UID scope is a mode of the
        // existing tool, so the catalog/tool-name set and the ABI's six-name
        // advanced list stay exactly as shipped.
        assertEquals(27, DeviceAccessToolCatalog.allNames.size)
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
    fun descriptionStatesTheEffectiveModeLimitHonestly() {
        val description = appOpsManageDescriptor().getString("description")
        assertTrue(description.contains("scope=uid"))
        assertTrue(description.contains("effective"))
        // The legacy-only restriction text must be gone: UID scope exists now.
        assertFalse(description.contains("never a UID"))
    }
}
