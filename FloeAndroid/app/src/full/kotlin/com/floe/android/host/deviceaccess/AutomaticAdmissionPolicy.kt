// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.rootsystem.SystemOperation

/**
 * Pure durable-ceiling checks for the App's device-access tools.
 *
 * A2 authority model: the CANONICAL Swift approval pipeline is the only
 * issuer of approval grants. In ordinary automatic mode the runtime issues a
 * real, scope-bound `approvalGrantID` (task/run/call/epoch) for a side-
 * effecting platform tool BEFORE the ticket reaches this host, but only when
 * the trusted Full host has published the matching durable ceiling for the
 * live epoch (package management, or file writes over the selected roots).
 * This host never mints grant ids: without a canonical grant the interactive
 * hard gate already applied upstream and the call never arrives; the checks
 * below are fail-closed DEFENSE IN DEPTH so a revoked ceiling refuses even a
 * racing in-flight call.
 *
 * Nothing here widens the ceilings themselves: file writes still require the
 * exact selected root and the global write ceiling, package operations still
 * require the package-management ceiling, and every protected/system target
 * stays hard-refused by the backend policy.
 */
internal object AutomaticAdmissionPolicy {

    /** User ceilings consulted for one ordinary mutation decision. */
    data class Ceilings(
        /** The exact file root named by the call is part of the selection. */
        val requestedRootSelected: Boolean = false,
        /** The durable global write ceiling is on. */
        val fileWritesAllowed: Boolean = false,
        /** The durable package-management ceiling is on. */
        val packageManagementAllowed: Boolean = false,
        /** The ONE shared advanced-system master (durable). */
        val advancedSystemManagementAllowed: Boolean = false,
        /** Allowed advanced tool names from the ABI six-name closed list. */
        val advancedAllowedTools: Set<String> = emptySet(),
    )

    /**
     * True when [operation] is an ordinary mutation inside the enabled
     * durable ceilings. Used for the early, model-facing refusal and as the
     * host-side mirror of the published admission; the service re-checks the
     * management flag on the registered grant, so a disabled ceiling refuses
     * at every layer. Sensitive/system-damaging work is never admitted here.
     */
    fun isWithinEnabledCeilings(
        operation: SystemOperation,
        ceilings: Ceilings,
    ): Boolean = when (operation) {
        SystemOperation.FILE_WRITE,
        SystemOperation.FILE_MOVE,
        SystemOperation.FILE_DELETE,
        -> ceilings.requestedRootSelected && ceilings.fileWritesAllowed

        SystemOperation.PACKAGE_FORCE_STOP,
        SystemOperation.PACKAGE_INSTALL,
        SystemOperation.PACKAGE_UNINSTALL,
        SystemOperation.PACKAGE_STAGE,
        SystemOperation.PACKAGE_SET_ENABLED,
        SystemOperation.PACKAGE_REMOVE_FOR_USER,
        SystemOperation.PACKAGE_RESTORE,
        -> ceilings.packageManagementAllowed

        // Advanced permission/AppOps mutations auto-pass only inside the
        // same enabled management ceiling; the shared advanced master, the
        // exact allowed tool name and the selected-target ceiling are
        // enforced by the host gate and re-checked on the service grant.
        SystemOperation.PERMISSIONS_MANAGE,
        SystemOperation.APP_OPS_MANAGE,
        -> ceilings.packageManagementAllowed

        // The closed settings write carries the SAME management ceiling and
        // additionally requires the shared advanced master with its exact
        // ABI name selected. There is no separate grant path.
        SystemOperation.SETTINGS_WRITE,
        -> ceilings.packageManagementAllowed &&
            ceilings.advancedSystemManagementAllowed &&
            DeviceAccessToolCatalog.SYSTEM_SETTINGS_WRITE in ceilings.advancedAllowedTools

        else -> false
    }
}
