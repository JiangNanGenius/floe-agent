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

    fun canManagePackage(
        packageName: String,
        userId: Int,
        ownPackages: Set<String>,
        allowed: Boolean,
        operation: String,
    ): String? = when {
        !allowed -> "management_disabled"
        userId !in 0..999 -> "user"
        packageName.length !in 3..255 -> "package"
        !Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$").matches(packageName) ->
            "package"
        operation !in setOf("force_stop") -> "operation"
        isProtectedPackage(packageName, ownPackages) -> "protected_target"
        else -> null
    }
}
