package com.floe.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceAccessAppCatalogTest {
    @Test fun appsBeyondTheFormerDisplayLimitRemainSearchable() {
        val discovered = (0 until 457).map {
            DeviceAccessPackageUi("org.example.app$it", "App $it", false)
        }
        val rows = mergeDeviceAccessAppCatalog(discovered, emptyList(), emptySet())
        assertEquals(457, rows.size)
        assertEquals("org.example.app456", rows.single { it.packageName.endsWith("app456") }.packageName)
    }

    @Test fun exactLookupOutsideTheBoundedPageIsAvailableBeforeSelection() {
        val page = (0 until 500).map {
            DeviceAccessPackageUi("org.example.app$it", "App $it", false)
        }
        val lookup = DeviceAccessPackageUi("org.example.verified", "Verified app", false)
        val rows = mergeDeviceAccessAppCatalog(page, listOf(lookup), emptySet())
        assertEquals(501, rows.size)
        assertEquals(lookup, rows.single { it.packageName == lookup.packageName })
        assertFalse(rows.single { it.packageName == lookup.packageName }.selected)
    }

    @Test fun persistedSelectionsSurviveVisibilityChangesWithoutInventingMetadata() {
        val rows = mergeDeviceAccessAppCatalog(emptyList(), emptyList(), setOf("org.example.hidden"))
        assertEquals(listOf(DeviceAccessPackageUi("org.example.hidden", "org.example.hidden", true)), rows)
    }

    @Test fun currentInventoryMetadataWinsAndSelectionFollowsTheSavedIdentity() {
        val rows = mergeDeviceAccessAppCatalog(
            listOf(DeviceAccessPackageUi("org.example.app", "Current label", false)),
            listOf(DeviceAccessPackageUi("org.example.app", "Stale label", true)),
            setOf("org.example.app"),
        )
        assertEquals(1, rows.size)
        assertEquals("Current label", rows.single().label)
        assertTrue(rows.single().selected)
        assertFalse(mergeDeviceAccessAppCatalog(rows, emptyList(), emptySet()).single().selected)
    }
}
