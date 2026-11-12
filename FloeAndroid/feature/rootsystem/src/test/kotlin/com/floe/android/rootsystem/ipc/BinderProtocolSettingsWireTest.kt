// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.ipc

import com.floe.android.rootsystem.SystemOperation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Transaction-position contract for the settings additions. The AIDL compiler
 * numbers methods by declaration order, so an insertion before the legacy
 * block would silently shift every shipped transaction; these pins fail if
 * the first nineteen methods, the appends or the wire version ever drift.
 * VERSION is 4 because build 108 already published VERSION=3.
 */
class BinderProtocolSettingsWireTest {

    @Test
    fun releasedWireThreeIsAnOlderKnownWire() {
        assertEquals(4, BinderProtocol.VERSION)
    }

    @Test
    fun firstNineteenLegacyMethodsKeepExactOrder() {
        assertEquals(
            listOf(
                "protocolVersion", "ping", "describe",
                "registerGrant", "revokeGrant", "revokeAllGrants",
                "fileList", "fileRead", "fileWrite", "fileMove", "fileDelete",
                "processQuery", "serviceQuery", "packageQuery", "networkDiagnostics",
                "managePackage", "packetCapture",
                "cancel", "stopOwnedService",
            ),
            BinderProtocol.wire2LegacyMethods,
        )
        assertEquals(19, BinderProtocol.wire2LegacyMethods.size)
    }

    @Test
    fun settingsMethodsAppendAfterEveryExistingMethod() {
        assertEquals(
            listOf("readSettings", "writeSettings"),
            BinderProtocol.wire6AppendedMethods,
        )
        assertEquals(
            BinderProtocol.wire3AppendedMethods +
                BinderProtocol.wire4AppendedMethods +
                BinderProtocol.wire5AppendedMethods +
                BinderProtocol.wire6AppendedMethods +
                BinderProtocol.wire7AppendedMethods,
            BinderProtocol.appendedMethods,
        )
        // The settings block is followed by the v4 UI transactions; no
        // earlier appended method may move.
        assertEquals(
            listOf("uiStatus", "uiObserve", "uiAct", "uiScreenshot", "uiCancel"),
            BinderProtocol.wire7AppendedMethods,
        )
        assertEquals("uiCancel", BinderProtocol.appendedMethods.last())
        // No duplicates anywhere: a shifted method would surface here.
        assertEquals(
            BinderProtocol.appendedMethods.size,
            BinderProtocol.appendedMethods.toSet().size,
        )
    }

    @Test
    fun settingsOperationsAreClosedAndManagementGated() {
        val settings = setOf(SystemOperation.SETTINGS_READ, SystemOperation.SETTINGS_WRITE)
        // The write rides the SAME management machinery as the package group.
        assertTrue(SystemOperation.SETTINGS_WRITE in SystemOperation.PACKAGE_MANAGEMENT_OPERATIONS)
        assertTrue(SystemOperation.SETTINGS_WRITE in SystemOperation.AUTO_ADMISSIBLE_PACKAGE_OPERATIONS)
        // The read is never management-gated.
        assertTrue(SystemOperation.SETTINGS_READ !in SystemOperation.PACKAGE_MANAGEMENT_OPERATIONS)
        assertTrue(settings.all { it in SystemOperation.entries })
    }
}
