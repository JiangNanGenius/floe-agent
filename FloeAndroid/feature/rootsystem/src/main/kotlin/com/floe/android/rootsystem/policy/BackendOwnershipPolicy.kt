// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

import com.floe.android.rootsystem.AdbStatus
import com.floe.android.rootsystem.RootStatus

/**
 * Pure ownership decisions for the one live privileged transport.
 *
 * The App controller holds at most one active binder, but publication is not
 * ownership. A paired ADB service may stay alive as standby while Root is the
 * active owner, and a Root binder left from an earlier App process may
 * republish after App death/update without becoming enabled again. Root stays
 * default-off and is only adopted/started after an explicit user action that
 * also observed effective UID 0 through the existing grant.
 *
 * These decisions have no Android/Binder dependency so the exact branches the
 * live controller executes can be checked on the JVM.
 */
object BackendOwnershipPolicy {

    enum class Owner { NONE, ADB, ROOT }

    enum class RefreshAction {
        /**
         * Keep the verified current owner. A published ADB binder must never
         * silently downgrade a live Root owner.
         */
        KEEP_CURRENT,

        /**
         * No verified owner: adopt the already published ADB binder. There is
         * deliberately no matching "adopt Root" action; Root requires the
         * explicit enable path.
         */
        ADOPT_ADB,

        /** No verified owner and no adoptable ADB binder. */
        NO_SERVICE,
    }

    fun decideRefresh(
        currentOwner: Owner,
        currentAlive: Boolean,
        adbPublished: Boolean,
    ): RefreshAction = when {
        currentAlive && currentOwner != Owner.NONE -> RefreshAction.KEEP_CURRENT
        adbPublished -> RefreshAction.ADOPT_ADB
        else -> RefreshAction.NO_SERVICE
    }

    data class ExplicitAdbPlan(
        /** Root is the live owner, so it must be stopped before ADB starts. */
        val stopLiveRoot: Boolean,
        /** A real owner switch fences every grant/operation of the old owner. */
        val fenceCurrentGrants: Boolean,
    )

    /**
     * Explicit user selection of ADB. A live Root backend is replaced only by
     * this explicit action (never by refresh/process discovery). A live ADB
     * backend is already the requested owner and is handled before this plan.
     */
    fun planExplicitAdb(currentOwner: Owner): ExplicitAdbPlan = ExplicitAdbPlan(
        stopLiveRoot = currentOwner == Owner.ROOT,
        fenceCurrentGrants = currentOwner == Owner.ROOT,
    )

    /** A Root switch to ADB or explicit Root-off must stop the live Root owner. */
    fun mustStopLiveRoot(currentOwner: Owner): Boolean = currentOwner == Owner.ROOT

    /**
     * ADB status while Root is the active owner. A former live service becomes
     * paired/standby; it must never keep claiming to be the active transport.
     */
    fun standbyAdbStatus(
        current: AdbStatus,
        pairingSupported: Boolean,
        connectPort: Int?,
    ): AdbStatus = when (current) {
        is AdbStatus.ServiceAlive,
        is AdbStatus.ServiceDied,
        -> if (pairingSupported) AdbStatus.Paired(connectPort) else AdbStatus.Disabled
        is AdbStatus.Pairing -> AdbStatus.PairRequired
        else -> current
    }

    /**
     * Root status after Root is no longer the live owner. A previously verified
     * grant is still available; without one Root is simply off.
     */
    fun inactiveRootStatus(hadVerifiedGrant: Boolean): RootStatus =
        if (hadVerifiedGrant) RootStatus.GrantFound else RootStatus.Off

    /**
     * The identity reported by a published helper. `record*` values are the
     * BinderHub publication metadata; `described*` values come from an actual
     * binder `describe()` call. Both must agree before any stop is attempted.
     */
    data class PublishedHelper(
        val recordMode: String,
        val recordUid: Int,
        val recordPid: Int,
        val recordVersion: Long,
        val recordSigning: String?,
        val describedOk: Boolean,
        val describedProtocol: Int,
        val describedMode: String?,
        val describedUid: Int,
        val describedPid: Int,
        val describedPackage: String?,
        val describedVersion: Long,
        val describedSigning: String?,
    )

    sealed interface PublishedVerdict {
        /** Same signed package, current App version: safe to adopt, not stop. */
        data object Current : PublishedVerdict

        /** Same signed package, an allowed older version: verify, stop, replace. */
        data class Replace(val pid: Int) : PublishedVerdict

        /** Not provably the same owned Floe helper: refuse; never kill it. */
        data class Refused(val code: String) : PublishedVerdict
    }

    /**
     * Decides whether a published binder may be adopted, replaced through its
     * typed stopServer call, or must be refused.
     *
     * Android's `app_process --nice-name` rewrites the whole argv block, so a
     * process name or `/proc/<pid>/cmdline` cannot prove ownership. Proof comes
     * from the published BinderHub record plus the live binder identity:
     * protocol, mode, exact installed host package, signing digest, UID, the
     * exact PID and a record/describe version agreement. Only an older
     * same-package version is replaceable; a newer/spoofed version is refused.
     */
    fun classifyPublishedHelper(
        helper: PublishedHelper,
        expectedMode: String,
        expectedProtocol: Int,
        hostPackage: String,
        hostSigning: String,
        currentVersion: Long,
    ): PublishedVerdict {
        val expectedUid = AccessPolicy.uidForMode(expectedMode)
            ?: return PublishedVerdict.Refused("mode")
        if (!helper.describedOk) return PublishedVerdict.Refused("describe")
        if (helper.describedProtocol != expectedProtocol) {
            return PublishedVerdict.Refused("protocol")
        }
        if (helper.recordMode != expectedMode || helper.describedMode != expectedMode) {
            return PublishedVerdict.Refused("mode")
        }
        if (helper.recordUid != expectedUid || helper.describedUid != expectedUid) {
            return PublishedVerdict.Refused("uid")
        }
        if (helper.describedPid <= 1 || helper.describedPid != helper.recordPid) {
            return PublishedVerdict.Refused("pid")
        }
        if (helper.describedPackage != hostPackage) {
            return PublishedVerdict.Refused("package")
        }
        val describedSigning = helper.describedSigning
        if (describedSigning == null ||
            !AccessPolicy.signingMatches(hostSigning, describedSigning)
        ) {
            return PublishedVerdict.Refused("signing")
        }
        val recordSigning = helper.recordSigning
        if (recordSigning == null ||
            !AccessPolicy.signingMatches(describedSigning, recordSigning)
        ) {
            return PublishedVerdict.Refused("signing")
        }
        if (helper.recordVersion <= 0 ||
            helper.describedVersion <= 0 ||
            helper.recordVersion != helper.describedVersion
        ) {
            return PublishedVerdict.Refused("version")
        }
        if (currentVersion <= 0) return PublishedVerdict.Refused("version")
        return when {
            helper.describedVersion == currentVersion -> PublishedVerdict.Current
            helper.describedVersion < currentVersion -> PublishedVerdict.Replace(helper.describedPid)
            // A helper that claims a version newer than the installed package
            // cannot be a legitimate old Floe process; refuse rather than kill.
            else -> PublishedVerdict.Refused("version")
        }
    }
}
