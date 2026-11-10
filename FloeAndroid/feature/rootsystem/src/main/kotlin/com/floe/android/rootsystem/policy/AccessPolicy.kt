// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

/** Pure decisions shared by the App controller and the privileged service. */
object AccessPolicy {

    const val UID_ROOT = 0
    const val UID_SHELL = 2000

    const val MODE_ADB = "adb"
    const val MODE_ROOT = "root"

    fun pairingSupported(api: Int): Boolean = api >= 30

    /** Android 9/10 get the explicit PC USB bootstrap path, not the pairing UI. */
    fun supportsUsbBootstrap(api: Int): Boolean = api in 28..29

    fun uidForMode(mode: String): Int? = when (mode) {
        MODE_ADB -> UID_SHELL
        MODE_ROOT -> UID_ROOT
        else -> null
    }

    fun modeAllowsUid(mode: String, uid: Int): Boolean = when (mode) {
        MODE_ADB -> uid == UID_SHELL
        MODE_ROOT -> uid == UID_ROOT
        else -> false
    }

    /** Root is never derived from ADB UID 0 or a debug build; it needs its own explicit grant. */
    fun rootStartDecision(
        enabled: Boolean,
        grantAvailable: Boolean,
        observedUid: Int?,
    ): RootStartDecision = when {
        !enabled -> RootStartDecision.Off
        !grantAvailable -> RootStartDecision.GrantNotFound
        observedUid == null -> RootStartDecision.GrantNotFound
        observedUid != UID_ROOT -> RootStartDecision.Refused("not_uid0")
        else -> RootStartDecision.StartAllowed
    }

    sealed interface RootStartDecision {
        data object Off : RootStartDecision
        data object GrantNotFound : RootStartDecision
        data object StartAllowed : RootStartDecision
        data class Refused(val code: String) : RootStartDecision
    }

    fun callerAllowed(callerUid: Int, callerPid: Int, appUid: Int): Boolean {
        if (callerPid <= 0 || callerUid < 0 || appUid < 0) return false
        if (callerUid % 100_000 != appUid % 100_000) return false
        return callerUid / 100_000 == appUid / 100_000
    }

    fun versionCompatible(expected: Long, actual: Long): Boolean =
        expected > 0 && actual > 0 && expected == actual

    fun signingMatches(expected: String, actual: String): Boolean =
        expected.length == 64 && actual.length == 64 &&
            expected.equals(actual, ignoreCase = true)

    /**
     * A result must never be reported as success after cancellation or a stale
     * generation was observed. The caller keeps the original result for
     * diagnostics but returns the denial to the Agent/tool layer.
     */
    fun resultCode(cancelled: Boolean, stale: Boolean, code: String?): String? = when {
        cancelled -> "cancelled"
        stale -> "stale"
        else -> code
    }
}

object ProtectedTargets {

    private val DENIED_PACKAGES = setOf(
        "android",
        "com.android.systemui",
        "com.android.settings",
        "com.android.shell",
        "com.android.providers.settings",
        "com.android.permissioncontroller",
        "com.google.android.gms",
        "com.google.android.gsf",
        "com.android.vending",
    )

    /**
     * Expands the supplied host package to the real Floe family first, so the
     * sibling runtime package is protected even when the service was launched
     * by the App package (and vice versa).
     */
    fun isProtectedPackage(packageName: String, ownPackages: Set<String>): Boolean {
        if (FloePackageFamily.contains(packageName, ownPackages)) return true
        return packageName in DENIED_PACKAGES
    }

    /**
     * Floe-private data and app-specific external storage stay protected for
     * every user, direct-boot (DE/CE), `/data/data` and adopted-volume alias.
     * An empty package set remains fail-closed instead of silently narrowing
     * to the stable parent.
     */
    fun isProtectedPath(path: String, ownPackages: Set<String>): Boolean =
        PathPolicy.isFloePrivatePath(
            path,
            if (ownPackages.isEmpty()) emptySet() else FloePackageFamily.protectedPackages(ownPackages),
        )

    /**
     * True when deleting [path] recursively would remove a Floe-private
     * subtree underneath it. Callers must refuse before any partial mutation.
     */
    fun containsProtectedSubtree(path: String, ownPackages: Set<String>): Boolean =
        PathPolicy.isFloePrivateAncestor(
            path,
            if (ownPackages.isEmpty()) emptySet() else FloePackageFamily.protectedPackages(ownPackages),
        )

    /** Platform inspection trees are never writable in this batch. */
    fun isReadOnlySystemPath(path: String): Boolean =
        PathPolicy.isReadOnlySystemPath(path)

    /** Closed lifecycle operations the typed package-management path serves. */
    val MANAGE_OPERATIONS: Set<String> = setOf("force_stop", "install", "uninstall")

    /**
     * Closed app-state operations the typed package-management path serves:
     * enable/disable/disable-user, per-user removal of noncritical
     * preinstalled apps and install-existing restore.
     */
    val APP_STATE_OPERATIONS: Set<String> = setOf("set_enabled", "remove_for_user", "restore")

    /** Closed requested-state tokens for the set_enabled operation. */
    val SET_ENABLED_STATES: Set<String> = setOf("enable", "disable", "disable-user")

    /**
     * Operations an admitted task may auto-pass inside the user's enabled
     * package-management ceiling. Everything else keeps the explicit
     * interactive hard gate; the app-state group additionally requires the
     * per-action durable switches and a non-empty selected target ceiling.
     */
    val AUTO_ADMISSIBLE_MANAGE_OPERATIONS: Set<String> =
        MANAGE_OPERATIONS + APP_STATE_OPERATIONS

    fun canManagePackage(
        packageName: String,
        userId: Int,
        ownPackages: Set<String>,
        allowed: Boolean,
        operation: String,
    ): String? = baseManageDenial(packageName, userId, ownPackages, allowed)?.let { return it }
        ?: if (operation !in MANAGE_OPERATIONS) "operation" else null

    /** Shared admission shape for every typed package-management operation. */
    private fun baseManageDenial(
        packageName: String,
        userId: Int,
        ownPackages: Set<String>,
        allowed: Boolean,
    ): String? = when {
        !allowed -> "management_disabled"
        userId !in 0..999 -> "user"
        packageName.length !in 3..255 -> "package"
        packageName != "android" && !Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$").matches(packageName) ->
            "package"
        isProtectedPackage(packageName, ownPackages) -> "protected_target"
        else -> null
    }

    /**
     * Uninstall refuses platform/system packages outright: removing them is
     * system-damaging even when ordinary third-party uninstall is enabled.
     * Install instead refuses early when the staged archive already names a
     * protected/system identity the reinstall could impersonate.
     */
    fun canAlterSystemPackage(operation: String, systemPackage: Boolean): String? = when {
        operation == "uninstall" && systemPackage -> "system_package"
        else -> null
    }

    /**
     * App-state operations (enable/disable/disable-user, per-user removal of
     * preinstalled apps, install-existing restore).
     *
     * Beyond the shared management/protected checks this enforces the real
     * target classes:
     *  - set_enabled: third-party or noncritical preinstalled packages; the
     *    packages currently holding the launcher / input-method / dialer
     *    roles are refused because disabling them breaks the device (the OS
     *    would refuse anyway; an OS refusal is reported as a real failure).
     *  - remove_for_user / restore: ONLY system-image packages, and only for
     *    the current user; third-party packages use the ordinary uninstall
     *    path instead. The system image is never modified.
     *
     * [currentRolePackages] are resolved device-side from the real role
     * holders (default launcher activity, Settings.Secure default input
     * method, TelecomManager default dialer), never from model text.
     */
    fun canChangeAppState(
        packageName: String,
        userId: Int,
        ownPackages: Set<String>,
        allowed: Boolean,
        operation: String,
        systemPackage: Boolean,
        currentRolePackages: Set<String>,
    ): String? {
        baseManageDenial(packageName, userId, ownPackages, allowed)?.let { return it }
        if (operation !in APP_STATE_OPERATIONS) return "operation"
        if (packageName in currentRolePackages) return "protected_role"
        return when (operation) {
            "set_enabled" -> null
            "remove_for_user", "restore" ->
                if (systemPackage) null else "not_system_package"
            else -> "operation"
        }
    }
}
