// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.ipc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure regression for the wire evolution contract of the permission/AppOps
 * packet: VERSION stays 3 (no wire-3 APK ever shipped), the legacy wire-2
 * first-19 keep their exact positions, every earlier appended method stays
 * in order, and the four new transactions ride at the tail after
 * releaseStagedApk. AIDL compiler numbers methods by declaration order, so
 * these lists ARE the binary contract the privileged service answers on.
 */
class BinderProtocolPermissionOpsWireTest {

    @Test
    fun versionStaysThreeWhileWireThreeIsUnshipped() {
        assertEquals(3, BinderProtocol.VERSION)
    }

    @Test
    fun legacyWireTwoFirstNineteenKeepTheirPositions() {
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
        assertEquals(
            BinderProtocol.wire2LegacyMethods.toSet().size,
            BinderProtocol.wire2LegacyMethods.size,
        )
    }

    @Test
    fun appendedMethodsAppendInOrderAfterTheLegacyBlock() {
        assertEquals(
            listOf("installPackage", "uninstallPackage", "stageApk"),
            BinderProtocol.wire3AppendedMethods,
        )
        assertEquals(
            listOf(
                "setPackageEnabled", "removePackageForUser", "restorePackage",
                "releaseStagedApk",
            ),
            BinderProtocol.wire4AppendedMethods,
        )
        // The permission/AppOps methods ride at the very tail of the same
        // unshipped revision; inserting them anywhere else would renumber
        // every later transaction.
        assertEquals(
            listOf(
                "queryPermissions", "managePermissions", "queryAppOps",
                "manageAppOps",
            ),
            BinderProtocol.wire5AppendedMethods,
        )
        assertEquals(
            BinderProtocol.wire3AppendedMethods +
                BinderProtocol.wire4AppendedMethods +
                BinderProtocol.wire5AppendedMethods +
                BinderProtocol.wire6AppendedMethods,
            BinderProtocol.appendedMethods,
        )
        val all = BinderProtocol.wire2LegacyMethods + BinderProtocol.appendedMethods
        assertEquals(all.size, all.toSet().size)
    }

    @Test
    fun permissionOpsKeysAreDistinctAndBounded() {
        val keys = listOf(
            BinderProtocol.KEY_PERMISSION_NAME,
            BinderProtocol.KEY_PERMISSION_ACTION,
            BinderProtocol.KEY_PERMISSIONS,
            BinderProtocol.KEY_APPOP_OPERATION,
            BinderProtocol.KEY_APPOP_MODE,
            BinderProtocol.KEY_APPOPS,
            BinderProtocol.KEY_GRANTED,
            BinderProtocol.KEY_GRANTED_BEFORE,
            BinderProtocol.KEY_PROTECTION_LEVEL,
            BinderProtocol.KEY_OVERRIDE_MODE,
            BinderProtocol.KEY_UID_MODE,
            BinderProtocol.KEY_DEFAULT_MODE,
            BinderProtocol.KEY_EFFECTIVE_MODE,
            BinderProtocol.KEY_OVERRIDE_BEFORE,
            BinderProtocol.KEY_UID_BEFORE,
            BinderProtocol.KEY_DEFAULT_BEFORE,
            BinderProtocol.KEY_EFFECTIVE_BEFORE,
            BinderProtocol.KEY_REQUESTED_MODE,
            BinderProtocol.KEY_OP_NAME,
        )
        assertEquals(keys.size, keys.toSet().size)
        for (key in keys) assertTrue(key.length <= 32)
    }
}
