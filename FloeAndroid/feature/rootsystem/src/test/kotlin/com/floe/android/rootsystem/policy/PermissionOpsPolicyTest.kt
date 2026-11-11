// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure regression for the closed permission/AppOps policy: the action and
 * mode sets, the protection-level mutability split, the AppOps catalog
 * (canonical UPPERCASE operation names, SDK gates, distinct background
 * operations) and the single-op `appops get` parser against the REAL
 * sanitized output shapes observed on a dedicated Samsung/API 33 device
 * (n02-adb-real-command-support/SINGLE_OP_READONLY_GRAMMAR.json and
 * OWN_PACKAGE_APPOPS_READONLY_OUTPUT.json). No Android APIs are touched.
 */
class PermissionOpsPolicyTest {

    // ------------------------------------------------------------ actions

    @Test
    fun actionsAreTheClosedGrantRevokePair() {
        assertEquals(setOf("grant", "revoke"), PermissionOpsPolicy.ACTIONS)
    }

    @Test
    fun permissionNamesShareDottedPackageShape() {
        assertTrue(PermissionOpsPolicy.PERMISSION_NAME.matches("android.permission.CAMERA"))
        assertTrue(PermissionOpsPolicy.PERMISSION_NAME.matches("com.example.CUSTOM_PERM"))
        assertFalse(PermissionOpsPolicy.PERMISSION_NAME.matches("CAMERA"))
        assertFalse(PermissionOpsPolicy.PERMISSION_NAME.matches("a..b"))
        assertFalse(PermissionOpsPolicy.PERMISSION_NAME.matches("x".repeat(300)))
    }

    // ------------------------------------------------------ appops catalog

    @Test
    fun catalogOpNamesAreUppercasePlatformStrings() {
        // Lowercase names exit 255 "Unknown operation string" on a real
        // Samsung/API 33 (CAMERA_READONLY_GRAMMAR.json); the catalog must
        // carry the accepted canonical names only.
        for (spec in PermissionOpsPolicy.APP_OPS) {
            assertTrue(
                "op name must be uppercase: ${spec.opName}",
                spec.opName == spec.opName.uppercase() &&
                    spec.opName.none { it == ':' },
            )
        }
    }

    @Test
    fun backgroundOperationsAreDistinctEntries() {
        // RUN_IN_BACKGROUND and RUN_ANY_IN_BACKGROUND are both accepted and
        // distinct on API 33 (SINGLE_OP_READONLY_GRAMMAR.json); they are not
        // a rename.
        val legacy = PermissionOpsPolicy.appOp("background-run", 33)
        val modern = PermissionOpsPolicy.appOp("background-run-any", 33)
        assertEquals("RUN_IN_BACKGROUND", legacy?.opName)
        assertEquals("RUN_ANY_IN_BACKGROUND", modern?.opName)
        // Android 9 AOSP already includes this distinct operation.
        assertEquals("RUN_ANY_IN_BACKGROUND", PermissionOpsPolicy.appOp("background-run-any", 28)?.opName)
        assertNull(PermissionOpsPolicy.appOp("background-run-any", 27))
        assertEquals(
            PermissionOpsPolicy.APP_OPS.size,
            PermissionOpsPolicy.APP_OPS.map { it.token }.toSet().size,
        )
    }

    @Test
    fun unknownTokenAndLowSdkRefuse() {
        assertNull(PermissionOpsPolicy.appOp("mock-location", 33))
        assertNull(PermissionOpsPolicy.appOp("camera", 21))
        assertEquals(
            "CAMERA",
            PermissionOpsPolicy.appOp("camera", 33)?.opName,
        )
    }

    @Test
    fun modesAreClosedWithSdkGateOnForeground() {
        assertEquals(
            setOf("allow", "ignore", "deny", "default", "foreground"),
            PermissionOpsPolicy.MODES,
        )
        assertTrue(PermissionOpsPolicy.modeSupported("foreground", 29))
        assertFalse(PermissionOpsPolicy.modeSupported("foreground", 28))
        assertFalse(PermissionOpsPolicy.modeSupported("always", 33))
    }

    // ----------------------------------------------------- protection bits

    @Test
    fun protectionTokensCoverThePracticalLevels() {
        assertEquals(
            "dangerous",
            PermissionOpsPolicy.protectionToken(PermissionOpsPolicy.PROTECTION_DANGEROUS),
        )
        assertEquals(
            "development",
            PermissionOpsPolicy.protectionToken(PermissionOpsPolicy.PROTECTION_FLAG_DEVELOPMENT),
        )
        assertEquals(
            "signature",
            PermissionOpsPolicy.protectionToken(PermissionOpsPolicy.PROTECTION_SIGNATURE),
        )
        assertEquals(
            "privileged",
            PermissionOpsPolicy.protectionToken(
                PermissionOpsPolicy.PROTECTION_NORMAL or
                    PermissionOpsPolicy.PROTECTION_FLAG_PRIVILEGED,
            ),
        )
        assertEquals(
            "normal",
            PermissionOpsPolicy.protectionToken(PermissionOpsPolicy.PROTECTION_NORMAL),
        )
    }

    @Test
    fun onlyDangerousOrDevelopmentPermissionsAreMutable() {
        assertNull(
            PermissionOpsPolicy.permissionMutable(PermissionOpsPolicy.PROTECTION_DANGEROUS),
        )
        assertNull(
            PermissionOpsPolicy.permissionMutable(
                PermissionOpsPolicy.PROTECTION_FLAG_DEVELOPMENT,
            ),
        )
        assertEquals(
            "permission_protected",
            PermissionOpsPolicy.permissionMutable(PermissionOpsPolicy.PROTECTION_SIGNATURE),
        )
        assertEquals(
            "permission_protected",
            PermissionOpsPolicy.permissionMutable(
                PermissionOpsPolicy.PROTECTION_NORMAL or
                    PermissionOpsPolicy.PROTECTION_FLAG_PRIVILEGED,
            ),
        )
    }

    // ------------------------------------------------------------- parser

    @Test
    fun parsesNoOperationsWithPlatformDefault() {
        // Real shape: CAMERA on the probe package.
        val parsed = PermissionOpsPolicy.parseAppOpsGet(
            "No operations.\nDefault mode: allow\n",
            "CAMERA",
        )
        assertFalse(parsed.unparseable)
        assertTrue(parsed.noOperations)
        assertNull(parsed.overrideMode)
        assertNull(parsed.uidMode)
        assertEquals("allow", parsed.defaultMode)
    }

    @Test
    fun parsesUidModeWithRepeatedOperationName() {
        // Real shape: COARSE_LOCATION on the probe package.
        val parsed = PermissionOpsPolicy.parseAppOpsGet(
            "Uid mode: COARSE_LOCATION: foreground\n",
            "COARSE_LOCATION",
        )
        assertFalse(parsed.unparseable)
        assertEquals("foreground", parsed.uidMode)
        assertNull(parsed.overrideMode)
    }

    @Test
    fun parsesUidModeAndPerPackageOverrideWithSemicolonTail() {
        // Real shape: FINE_LOCATION on the probe package — BOTH the UID-mode
        // line and a per-package override with a semicolon-delimited tail.
        val parsed = PermissionOpsPolicy.parseAppOpsGet(
            "Uid mode: FINE_LOCATION: foreground\n" +
                "FINE_LOCATION: allow; time=+10d13h0m50s194ms ago; " +
                "rejectTime=+11d13h8m37s511ms ago\n",
            "FINE_LOCATION",
        )
        assertFalse(parsed.unparseable)
        assertEquals("foreground", parsed.uidMode)
        assertEquals("allow", parsed.overrideMode)
    }

    @Test
    fun parsesExplicitDefaultOverrideRow() {
        // Real shape from the package dump: a per-package row recorded with
        // mode "default" and a reject time.
        val parsed = PermissionOpsPolicy.parseAppOpsGet(
            "SYSTEM_ALERT_WINDOW: default; rejectTime=+9h54m32s630ms ago\n",
            "SYSTEM_ALERT_WINDOW",
        )
        assertFalse(parsed.unparseable)
        assertEquals("default", parsed.overrideMode)
        assertNull(parsed.uidMode)
    }

    @Test
    fun parsesRunningAnnotationAndLegacyUidMode() {
        val running = PermissionOpsPolicy.parseAppOpsGet(
            "START_FOREGROUND: allow; time=+3m43s439ms ago (running)\n",
            "START_FOREGROUND",
        )
        assertFalse(running.unparseable)
        assertEquals("allow", running.overrideMode)
        val legacy = PermissionOpsPolicy.parseAppOpsGet(
            "Uid mode: ignore\n",
            "RECORD_AUDIO",
        )
        assertFalse(legacy.unparseable)
        assertEquals("ignore", legacy.uidMode)
    }

    @Test
    fun uidModeLineForAnotherOperationRefuses() {
        val parsed = PermissionOpsPolicy.parseAppOpsGet(
            "Uid mode: FINE_LOCATION: foreground\n",
            "CAMERA",
        )
        assertTrue(parsed.unparseable)
    }

    @Test
    fun unrecognizedContentRefusesInsteadOfDefaulting() {
        val parsed = PermissionOpsPolicy.parseAppOpsGet(
            "Something unexpected happened\n",
            "CAMERA",
        )
        assertTrue(parsed.unparseable)
        val empty = PermissionOpsPolicy.parseAppOpsGet("", "CAMERA")
        assertTrue(empty.unparseable)
        val badMode = PermissionOpsPolicy.parseAppOpsGet(
            "CAMERA: sideways\n",
            "CAMERA",
        )
        assertTrue(badMode.unparseable)
    }

    @Test
    fun sharedUidRefusalIsCountBased() {
        assertNull(PermissionOpsPolicy.sharedUidRefusal(1))
        assertNull(PermissionOpsPolicy.sharedUidRefusal(0))
        assertEquals(
            "shared_uid_refused",
            PermissionOpsPolicy.sharedUidRefusal(2),
        )
        assertEquals(
            "shared_uid_refused",
            PermissionOpsPolicy.sharedUidRefusal(5),
        )
    }

    @Test
    fun normalizeModeStripsTailsAndAnnotations() {
        assertEquals("allow", PermissionOpsPolicy.normalizeMode("allow; time=+1d ago"))
        assertEquals("foreground", PermissionOpsPolicy.normalizeMode("foreground (UID only)"))
        assertEquals("ignore", PermissionOpsPolicy.normalizeMode("ignore"))
        assertNull(PermissionOpsPolicy.normalizeMode("sideways"))
    }
}
