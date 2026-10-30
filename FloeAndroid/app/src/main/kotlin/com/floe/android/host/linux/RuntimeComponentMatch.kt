// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import android.content.Context
import android.content.pm.PackageManager
import com.floe.android.runtimeipc.RuntimePackages
import com.floe.android.runtimeipc.RuntimePeerVerifier

/**
 * G03-R3 app-upgrade peer anchoring gate.
 *
 * The distro component is a SEPARATE package installed/updated beside the
 * App. A package update replaces the runtime process; until the matching
 * component build is actually installed, the PREVIOUS component is still a
 * valid signer/UID peer and would connect successfully. Ingesting that stale
 * peer's `runtimeUidBoundary` would anchor the fresh App root epoch to the
 * OLD process generation; the later component replacement then appears as
 * `peer_generation_drift`/`peerBoundaryConflict`, which the ORIGINAL guards
 * correctly refuse to re-anchor under the same root.
 *
 * This is NOT a new identity/permission authority: it is the SAME exact
 * expected-version check the setup surface already performs
 * ([LocalRuntimeSetupHost.componentMatches]) using the EXISTING trusted
 * PackageManager facts plus the ORIGINAL `RuntimePeerVerifier` signer/UID
 * admission. The readiness ingress consults it BEFORE creating a runtime
 * connection / committing any peer identity; the setup UI keeps its exact
 * install-action semantics. No model/peer payload or label participates.
 */
internal object RuntimeComponentMatch {

    internal enum class State {
        /** Exact expected build: signer/UID admission passed and
         *  longVersionCode equals this App's installed build. */
        MATCHING,
        /** No runtime component package installed yet. */
        MISSING,
        /** A valid same-signer component is installed, but it is a DIFFERENT
         *  build (the ordinary App-upgrade window before the matching
         *  component update lands). */
        VERSION_STALE,
        /** Installed package failed the ORIGINAL signer/UID admission. */
        IDENTITY_MISMATCH,
    }

    /** The trusted-PackageManager decision. Throws only when the platform
     *  itself refuses the package query; no state is guessed. */
    internal fun state(context: Context): State {
        val app = context.applicationContext
        val pair = RuntimePackages.forCore(app.packageName)
        val manager = app.packageManager
        val installed = try {
            manager.getPackageUid(pair.runtime, 0)
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }
        if (!installed) return State.MISSING
        try {
            RuntimePeerVerifier(app).verifyPeer(pair.runtime)
        } catch (_: SecurityException) {
            // Installed but a foreign signer / shared UID / wrong package
            // relationship: a refusal, never a fallback or different package.
            return State.IDENTITY_MISMATCH
        }
        return try {
            @Suppress("DEPRECATION")
            val own = manager.getPackageInfo(app.packageName, 0)
            @Suppress("DEPRECATION")
            val peer = manager.getPackageInfo(pair.runtime, 0)
            versionState(own.longVersionCode, peer.longVersionCode)
        } catch (_: PackageManager.NameNotFoundException) {
            State.MISSING
        }
    }

    /** The exact expected-build decision, pure: a fresh App upgrade with the
     *  previous component installed is `VERSION_STALE` (never allowed to
     *  anchor); only equal installed build codes are `MATCHING`. */
    internal fun versionState(ownVersionCode: Long, peerVersionCode: Long): State =
        if (ownVersionCode == peerVersionCode) State.MATCHING else State.VERSION_STALE

    /** The setup surface's original boolean contract: a missing/outdated
     *  component is an install action; a foreign signer is a refusal. */
    internal fun matches(context: Context): Boolean = when (state(context)) {
        State.MATCHING -> true
        State.MISSING, State.VERSION_STALE -> false
        State.IDENTITY_MISMATCH -> throw SecurityException("Runtime identity mismatch")
    }

    /** Typed closed refusal for the readiness ingress; null = may anchor.
     *  Pure mapping so the decision is pinned by a JVM regression. */
    internal fun refusalFor(state: State): String? = when (state) {
        State.MATCHING -> null
        State.MISSING -> "componentUnavailable"
        State.VERSION_STALE -> "componentVersionStale"
        State.IDENTITY_MISMATCH -> "componentIdentityMismatch"
    }

    /** Fail-closed readiness form: any platform failure that prevents a
     *  positive exact-build proof refuses (never anchors). */
    internal fun refusal(context: Context): String? = try {
        refusalFor(state(context))
    } catch (_: SecurityException) {
        refusalFor(State.IDENTITY_MISMATCH)
    } catch (_: Exception) {
        refusalFor(State.MISSING)
    }
}
