// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

/**
 * Pure outcome computation for the typed package install/uninstall lifecycle.
 *
 * Extracted from the privileged service so the exact success semantics the
 * App reports to the model are unit-testable without an Android runtime:
 *
 * - A reported success ALWAYS means the real `pm` child completed with exit
 *   code 0 AND a post-operation PackageManager read-back proves the REQUESTED
 *   end state for the SAME user the operation targeted. An already-installed
 *   older version therefore never upgrades a failed update to "success".
 * - Install additionally requires the read-back versionCode to equal the
 *   staged archive's versionCode and the installed signing identity set to
 *   equal the archive's signing identity set (empty read-back identity never
 *   verifies: fail closed, never widen).
 * - Uninstall requires the package to be absent after a zero exit.
 * - Cancellation and stale state dominate every other outcome.
 *
 * Detail codes are bounded diagnostic tokens for the model summary, never
 * parsed authority.
 */
object PackageLifecycleDecision {

    data class InstallFacts(
        val pmExitCode: Int,
        val presentAfter: Boolean,
        val archiveVersionCode: Long,
        val installedVersionCode: Long?,
        val signingMatched: Boolean,
    )

    data class Outcome(
        val succeeded: Boolean,
        val detailCode: String,
    )

    fun install(facts: InstallFacts): Outcome {
        val verified = facts.pmExitCode == 0 &&
            facts.presentAfter &&
            facts.installedVersionCode == facts.archiveVersionCode &&
            facts.signingMatched
        val detail = when {
            verified -> "present"
            facts.pmExitCode != 0 -> "install_failed"
            !facts.presentAfter -> "verify_failed"
            facts.installedVersionCode != facts.archiveVersionCode -> "verify_failed"
            !facts.signingMatched -> "verify_failed"
            else -> "verify_failed"
        }
        return Outcome(succeeded = verified, detailCode = detail)
    }

    data class UninstallFacts(
        val pmExitCode: Int,
        val presentAfter: Boolean,
    )

    fun uninstall(facts: UninstallFacts): Outcome {
        val verified = facts.pmExitCode == 0 && !facts.presentAfter
        val detail = when {
            verified -> "absent"
            facts.pmExitCode != 0 -> "uninstall_failed"
            else -> "verify_failed"
        }
        return Outcome(succeeded = verified, detailCode = detail)
    }

    /**
     * Per-user removal of a preinstalled app has the same proof shape as an
     * ordinary uninstall: a zero exit plus absence for the exact requested
     * user. The system image stays untouched, so absence can only ever be
     * per-user.
     */
    fun removeForUser(facts: UninstallFacts): Outcome = uninstall(facts)

    data class RestoreFacts(
        val pmExitCode: Int,
        val presentAfter: Boolean,
    )

    /**
     * install-existing restore succeeds only when the command completed with
     * exit 0 and the package is present again for the requested user.
     */
    fun restore(facts: RestoreFacts): Outcome {
        val verified = facts.pmExitCode == 0 && facts.presentAfter
        val detail = when {
            verified -> "present"
            facts.pmExitCode != 0 -> "restore_failed"
            else -> "verify_failed"
        }
        return Outcome(succeeded = verified, detailCode = detail)
    }

    /**
     * enable/disable/disable-user proof: a zero exit is not enough — the
     * PackageManager enabled-setting read-back for the exact user must
     * match the state requested by the pm command. OS refusals (protected,
     * current-role or critical packages) exit nonzero and are reported as
     * real failures, never relabelled "unsupported".
     */
    fun setEnabled(
        pmExitCode: Int,
        requestedState: String,
        observedState: String,
    ): Outcome {
        val expectedState = when (requestedState) {
            "enable" -> "enabled"
            "disable" -> "disabled"
            "disable-user" -> "disabled-user"
            else -> null
        }
        val verified = pmExitCode == 0 && expectedState != null && observedState == expectedState
        val detail = when {
            verified -> "state_matched"
            pmExitCode != 0 -> "state_failed"
            else -> "verify_failed"
        }
        return Outcome(succeeded = verified, detailCode = detail)
    }
}
