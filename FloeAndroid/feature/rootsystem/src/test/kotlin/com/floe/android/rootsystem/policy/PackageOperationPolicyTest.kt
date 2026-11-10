// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

import com.floe.android.rootsystem.SystemOperation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure regression for the widened typed package-management surface: the
 * closed force-stop/install/uninstall lifecycle, the protected/system
 * refusals that stay hard gates, the staged-APK path ceiling, and the
 * admission classification that keeps ordinary lifecycle operations
 * auto-passable inside the user's management ceiling.
 *
 * No Android APIs are touched: every decision here is replayed by the live
 * service and the App host on the device.
 */
class PackageOperationPolicyTest {

    private val own = setOf("com.floe.agent.full")

    // ------------------------------------------------------ lifecycle set

    @Test
    fun manageOperationsAreTheClosedLifecycleSet() {
        assertEquals(
            setOf("force_stop", "install", "uninstall"),
            ProtectedTargets.MANAGE_OPERATIONS,
        )
        assertEquals(
            ProtectedTargets.MANAGE_OPERATIONS + ProtectedTargets.APP_STATE_OPERATIONS,
            ProtectedTargets.AUTO_ADMISSIBLE_MANAGE_OPERATIONS,
        )
        assertEquals(
            setOf("set_enabled", "remove_for_user", "restore"),
            ProtectedTargets.APP_STATE_OPERATIONS,
        )
        assertEquals(
            setOf("enable", "disable", "disable-user"),
            ProtectedTargets.SET_ENABLED_STATES,
        )
        for (operation in listOf("force_stop", "install", "uninstall")) {
            assertNull(
                ProtectedTargets.canManagePackage(
                    packageName = "com.example.app",
                    userId = 0,
                    ownPackages = own,
                    allowed = true,
                    operation = operation,
                ),
            )
        }
    }

    @Test
    fun systemOperationClassificationMatchesTheManageSet() {
        assertEquals(
            setOf(
                SystemOperation.PACKAGE_FORCE_STOP,
                SystemOperation.PACKAGE_INSTALL,
                SystemOperation.PACKAGE_UNINSTALL,
                SystemOperation.PACKAGE_STAGE,
                SystemOperation.PACKAGE_SET_ENABLED,
                SystemOperation.PACKAGE_REMOVE_FOR_USER,
                SystemOperation.PACKAGE_RESTORE,
            ),
            SystemOperation.PACKAGE_MANAGEMENT_OPERATIONS,
        )
        assertEquals(
            SystemOperation.PACKAGE_MANAGEMENT_OPERATIONS,
            SystemOperation.AUTO_ADMISSIBLE_PACKAGE_OPERATIONS,
        )
        for (operation in SystemOperation.PACKAGE_MANAGEMENT_OPERATIONS) {
            assertTrue(SystemOperation.isPackageManagement(operation))
        }
        assertFalse(SystemOperation.isPackageManagement(SystemOperation.PACKAGE_QUERY))
        assertFalse(SystemOperation.isPackageManagement(SystemOperation.FILE_DELETE))
    }

    // ---------------------------------------------------------- hard gates

    @Test
    fun managementCeilingAndShapeAreCheckedBeforeAnyTarget() {
        assertEquals(
            "management_disabled",
            ProtectedTargets.canManagePackage(
                packageName = "com.example.app", userId = 0,
                ownPackages = own, allowed = false, operation = "install",
            ),
        )
        assertEquals(
            "user",
            ProtectedTargets.canManagePackage(
                packageName = "com.example.app", userId = 1000,
                ownPackages = own, allowed = true, operation = "uninstall",
            ),
        )
        assertEquals(
            "package",
            ProtectedTargets.canManagePackage(
                packageName = "not a package", userId = 0,
                ownPackages = own, allowed = true, operation = "force_stop",
            ),
        )
        assertEquals(
            "operation",
            ProtectedTargets.canManagePackage(
                packageName = "com.example.app", userId = 0,
                ownPackages = own, allowed = true, operation = "clear_data",
            ),
        )
    }

    @Test
    fun floeFamilyAndPlatformPackagesAreRefusedForEveryLifecycleOperation() {
        val protectedPackages = listOf(
            "com.floe.agent",
            "com.floe.agent.full",
            "com.floe.agent.full.dev",
            "com.floe.agent.runtime.full",
            "com.floe.agent.runtime.full.dev",
            "android",
            "com.android.systemui",
            "com.android.settings",
            "com.android.shell",
            "com.google.android.gms",
        )
        for (packageName in protectedPackages) {
            for (operation in listOf("force_stop", "install", "uninstall")) {
                assertEquals(
                    "$packageName $operation",
                    "protected_target",
                    ProtectedTargets.canManagePackage(
                        packageName = packageName, userId = 0,
                        ownPackages = own, allowed = true, operation = operation,
                    ),
                )
            }
        }
    }

    @Test
    fun systemPackagesAreNeverUninstalled() {
        assertEquals(
            "system_package",
            ProtectedTargets.canAlterSystemPackage("uninstall", systemPackage = true),
        )
        assertNull(ProtectedTargets.canAlterSystemPackage("uninstall", systemPackage = false))
        assertNull(ProtectedTargets.canAlterSystemPackage("install", systemPackage = true))
    }

    // -------------------------------------------------------- app-state set

    @Test
    fun appStateOperationsRespectTargetClassAndCurrentRoles() {
        val roles = setOf("com.example.launcher", "com.example.ime", "com.example.dialer")
        // set_enabled: third-party and noncritical system packages are OK.
        assertNull(
            ProtectedTargets.canChangeAppState(
                "com.example.app", 0, own, true, "set_enabled",
                systemPackage = false, currentRolePackages = roles),
        )
        assertNull(
            ProtectedTargets.canChangeAppState(
                "com.example.bloat", 0, own, true, "set_enabled",
                systemPackage = true, currentRolePackages = roles),
        )
        // Current launcher/IME/dialer holders are refused for every op.
        for (role in roles) {
            assertEquals(
                "protected_role",
                ProtectedTargets.canChangeAppState(
                    role, 0, own, true, "set_enabled",
                    systemPackage = false, currentRolePackages = roles),
            )
        }
        // remove/restore are system-image only.
        assertEquals(
            "not_system_package",
            ProtectedTargets.canChangeAppState(
                "com.example.app", 0, own, true, "remove_for_user",
                systemPackage = false, currentRolePackages = roles),
        )
        assertNull(
            ProtectedTargets.canChangeAppState(
                "com.example.bloat", 0, own, true, "remove_for_user",
                systemPackage = true, currentRolePackages = roles),
        )
        assertNull(
            ProtectedTargets.canChangeAppState(
                "com.example.bloat", 0, own, true, "restore",
                systemPackage = true, currentRolePackages = roles),
        )
        // Shared admission shape still applies.
        assertEquals(
            "management_disabled",
            ProtectedTargets.canChangeAppState(
                "com.example.app", 0, own, false, "set_enabled",
                systemPackage = false, currentRolePackages = roles),
        )
        assertEquals(
            "protected_target",
            ProtectedTargets.canChangeAppState(
                "com.floe.agent.full", 0, own, true, "set_enabled",
                systemPackage = false, currentRolePackages = roles),
        )
        assertEquals(
            "operation",
            ProtectedTargets.canChangeAppState(
                "com.example.app", 0, own, true, "clear_data",
                systemPackage = false, currentRolePackages = roles),
        )
    }

    // ------------------------------------------------------- staged paths

    @Test
    fun serviceStagingIdentityRequiresTheFullDigest() {
        val digest = "a".repeat(64)
        val root = "/data/local/tmp/floe-staging-2000-com.floe.agent.full"
        assertEquals("$root/$digest.apk",
            StagedApkPolicy.ownedStagedPath(2000, "com.floe.agent.full", digest))
        assertEquals(root, StagedApkPolicy.ownedStageRoot(2000, "com.floe.agent.full"))
        assertTrue(StagedApkPolicy.isOwnedStagePath(
            "$root/$digest.apk", 2000, "com.floe.agent.full"))
        assertFalse(StagedApkPolicy.isOwnedStagePath(
            "$root/$digest.apk", 0, "com.floe.agent.full"))
        assertFalse(StagedApkPolicy.isOwnedStagePath(
            "/data/local/tmp/floe-staging-0-com.floe.agent.full/$digest.apk",
            2000, "com.floe.agent.full"))
        assertNull(StagedApkPolicy.ownedStagedPath(2000, "com.floe.agent.full", digest.dropLast(1)))
        assertNull(StagedApkPolicy.ownedStagedPath(2000, "not a package", digest))
        assertNull(StagedApkPolicy.ownedStageRoot(-1, "com.floe.agent.full"))
    }

    @Test
    fun serviceStagedPathShapeAcceptsOnlyNamespacedLeafFiles() {
        val digest = "b".repeat(64)
        assertTrue(StagedApkPolicy.isServiceStagedPath(
            "/data/local/tmp/floe-staging-0-com.floe.agent/$digest.apk"))
        assertTrue(StagedApkPolicy.isServiceStagedPath(
            "/data/local/tmp/floe-staging-2000-com.floe.agent.dev/$digest.apk"))
        // Old shared global layout and foreign trees are not service-issued.
        assertFalse(StagedApkPolicy.isServiceStagedPath("/data/local/tmp/floe-staging/$digest.apk"))
        assertFalse(StagedApkPolicy.isServiceStagedPath(
            "/data/local/tmp/floe-staging-2000/$digest.apk"))
        assertFalse(StagedApkPolicy.isServiceStagedPath(
            "/data/local/tmp/floe-staging-2000-com.floe.agent.full/nested/$digest.apk"))
        assertFalse(StagedApkPolicy.isServiceStagedPath(
            "/data/local/tmp/floe-staging-2000-com.floe.agent.full/notadigest.apk"))
        assertFalse(StagedApkPolicy.isServiceStagedPath("/sdcard/floe-staging-2000-com.floe.agent/$digest.apk"))
    }

    @Test
    fun stagedApkPathsOnlyComeFromSharedStorageTrees() {
        for (path in listOf(
            "/data/local/tmp/floe-stage/app.apk",
            "/data/media/0/Android/data/com.floe.agent.full/files/apk-staging/x.apk",
            "/sdcard/Download/app.apk",
            "/storage/emulated/0/Android/data/com.floe.agent.full/files/apk-staging/x.apk",
            "/storage/self/primary/Download/app.apk",
            "/mnt/expand/1234-5678/user/0/app.apk",
        )) {
            assertEquals(path, path, StagedApkPolicy.normalizeStagedPath(path))
        }
    }

    @Test
    fun stagedApkPathsRefusePrivatePlatformAndVirtualTrees() {
        for (path in listOf(
            "relative/app.apk",
            "/sdcard/../data/data/com.x/files/a.apk",
            "/data/data/com.example/app.apk",
            "/data/user/0/com.example/app.apk",
            "/data/user_de/0/com.example/app.apk",
            "/data/misc/app.apk",
            "/system/app/app.apk",
            "/vendor/app.apk",
            "/apex/com.android.app/app.apk",
            "/proc/1/root.apk",
            "/storage/emulated/0/app\u0000.apk",
            "/storage/emulated/0/app\\name.apk",
            "/",
            "/unrelated/tree/app.apk",
        )) {
            assertNull(path, StagedApkPolicy.normalizeStagedPath(path))
        }
        // Segment shape is bounded.
        assertNull(StagedApkPolicy.normalizeStagedPath("/sdcard/" + "a".repeat(300)))
        assertNull(
            StagedApkPolicy.normalizeStagedPath(
                "/sdcard/" + List(40) { "seg" }.joinToString("/"),
            ),
        )
    }
}
