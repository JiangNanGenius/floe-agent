// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

/**
 * Pure outcome computation for the typed permission/AppOps mutations.
 *
 * Mirrored on [PackageLifecycleDecision]: a reported success ALWAYS means
 * the real `pm`/`appops` child completed with exit code 0 AND an independent
 * post-operation read-back proves the requested state for the SAME user the
 * operation targeted. A bare command success never upgrades to "success",
 * unparseable read-back output never reports success, and a mismatch stays
 * a real per-item failure with a bounded detail token.
 */
object PermissionOpsDecision {

    data class Outcome(val succeeded: Boolean, val detailCode: String)

    /**
     * pm grant/revoke proof: exit 0 is not enough — the PackageManager
     * read-back of the exact user's grant state must equal the requested
     * end state. OS refusals (signature/fixed/admin/platform permissions)
     * exit nonzero and stay real failures, never relabelled "unsupported".
     */
    fun permission(pmExitCode: Int, action: String, grantedAfter: Boolean): Outcome {
        val wantGranted = action == PermissionOpsPolicy.ACTION_GRANT
        val verified = pmExitCode == 0 && grantedAfter == wantGranted
        val detail = when {
            verified -> "state_matched"
            pmExitCode != 0 -> if (wantGranted) "grant_failed" else "revoke_failed"
            else -> "verify_failed"
        }
        return Outcome(succeeded = verified, detailCode = detail)
    }

    /**
     * appops set proof on the parsed row of the SAME single operation that
     * the requested scope actually writes. PACKAGE scope (the legacy default)
     * proves on the per-package override: a concrete requested mode must
     * equal it; "default" means the package is back at platform/UID behavior
     * (override row gone, or the platform recorded an explicit "default"
     * entry as seen on Samsung/API 33 as `OP: default; rejectTime=...`).
     * UID scope proves on the UID-level row instead: a concrete mode must
     * equal the observed UID mode; "default" means the UID row is gone or
     * recorded "default". Proving the wrong layer for the scope is a real
     * failure ("verify_failed"), never a success: per the frozen C1 evidence
     * a package-override match must not be reported as an effective UID
     * change, and a UID match must not be reported as a package restore.
     */
    fun appOps(
        pmExitCode: Int,
        requestedMode: String,
        overrideAfter: String?,
        scope: String = PermissionOpsPolicy.SCOPE_PACKAGE,
        uidAfter: String? = null,
    ): Outcome {
        val verified = when {
            pmExitCode != 0 -> false
            scope == PermissionOpsPolicy.SCOPE_UID -> when (requestedMode) {
                "default" -> uidAfter == null || uidAfter == "default"
                else -> uidAfter == requestedMode
            }
            requestedMode == "default" ->
                overrideAfter == null || overrideAfter == "default"
            else -> overrideAfter == requestedMode
        }
        val detail = when {
            verified -> "mode_matched"
            pmExitCode != 0 -> "mode_failed"
            else -> "verify_failed"
        }
        return Outcome(succeeded = verified, detailCode = detail)
    }

    /**
     * Configured AppOps mode from one parsed single-op read. Android gives
     * a non-default UID policy precedence over the package policy; otherwise
     * the package override wins, then the printed platform default. Explicit
     * "default" restores inherited behavior. This is not proof of runtime
     * permission, foreground state or hardware availability. With only the
     * "No operations." marker and no default line the effective mode is
     * "default" (platform behavior applies); with nothing recognized at
     * all it is "unknown" — never an invented allow.
     */
    fun effectiveMode(
        overrideMode: String?,
        uidMode: String?,
        defaultMode: String?,
        noOperations: Boolean,
    ): String {
        val uid = uidMode?.takeUnless { it == "default" }
        if (uid != null) return uid
        val live = overrideMode?.takeUnless { it == "default" }
        if (live != null) return live
        if (defaultMode != null) return defaultMode
        return if (noOperations) "default" else "unknown"
    }
}
