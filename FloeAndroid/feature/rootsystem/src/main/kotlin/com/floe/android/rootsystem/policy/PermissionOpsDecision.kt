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
     * appops set proof on the parsed per-package override of the SAME single
     * operation. For a concrete requested mode the post-set per-package
     * override must equal the request. For "default" the package must be
     * back at platform/UID behavior: either the per-package row is gone, or
     * the platform recorded an explicit "default" entry (observed on a
     * dedicated Samsung/API 33 device as `OP: default; rejectTime=...`).
     * The UID/platform fallback is reported separately and never widened
     * into an allow claim.
     */
    fun appOps(pmExitCode: Int, requestedMode: String, overrideAfter: String?): Outcome {
        val verified = when {
            pmExitCode != 0 -> false
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
