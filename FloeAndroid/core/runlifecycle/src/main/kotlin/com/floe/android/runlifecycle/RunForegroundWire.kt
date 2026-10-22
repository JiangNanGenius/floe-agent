// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runlifecycle

/**
 * Trusted-host live-work snapshot from the narrow native projection
 * (`floe_run_foreground_snapshot`, shared/Sources/FloeAndroidCore/
 * RunForegroundProjection.swift). Counts ONLY of the ORIGINAL live
 * owned-work ledger (RB1 RuntimeOwnedWorkRegistry) under the CURRENT
 * accepted native root epoch — never a stored status string, never a
 * localized label, never model output.
 *
 * WIRE CONTRACT (pinned by RunForegroundWireTest against the ACTUAL
 * Swift serializer — any drift on either side must fail loudly here):
 *   epoch=<decimal>;storeReady=<1|0>;admissionFenced=<1|0>;
 *   run=<n>;childRun=<n>;tool=<n>;conversation=<n>;vaultMaintenance=<n>
 * Booleans are strictly `1`/`0` (NOT "true"/"false"). Any missing,
 * malformed or negative field means the whole read is UNKNOWN: unknown
 * NEVER closes a live lease and NEVER mints a foreground acquisition.
 */
data class NativeLiveWork(
    val nativeRootEpoch: Long,
    val storeReady: Boolean,
    val admissionFenced: Boolean,
    val runCount: Int,
    val childRunCount: Int,
    val toolCount: Int,
    val conversationCount: Int,
    val vaultMaintenanceCount: Int,
) {
    /** Quiescence for retained Agent leases (Main rule): real runs, child
     *  runs AND owned tool cleanup under the ledger. A root run may end
     *  while its owned tool work still cleans up; if only runs gated
     *  settlement the service could stop and Core could freeze mid
     *  cleanup. There is no other FGS owner for the tool lifecycle today,
     *  so toolCount counts toward live owned Agent work. The
     *  conversation/vault ledgers settle through their own owners and are
     *  intentionally excluded from this predicate. */
    val hasLiveRunOwnedWork: Boolean
        get() = runCount > 0 || childRunCount > 0 || toolCount > 0
}

object RunForegroundWire {

    /** Strict parser for the projection's ASCII line. null == unknown
     *  (including null input); values are never defaulted to 0-as-truth. */
    fun parse(raw: String?): NativeLiveWork? {
        if (raw.isNullOrEmpty()) return null
        val fields = raw.split(';').mapNotNull { part ->
            val index = part.indexOf('=')
            if (index <= 0) null else part.substring(0, index) to part.substring(index + 1)
        }.toMap()
        val epoch = fields["epoch"]?.toLongOrNull() ?: return null
        val storeReady = parseFlag(fields["storeReady"]) ?: return null
        val admissionFenced = parseFlag(fields["admissionFenced"]) ?: return null
        val run = fields["run"]?.toIntOrNull() ?: return null
        val childRun = fields["childRun"]?.toIntOrNull() ?: return null
        val tool = fields["tool"]?.toIntOrNull() ?: return null
        val conversation = fields["conversation"]?.toIntOrNull() ?: return null
        val vault = fields["vaultMaintenance"]?.toIntOrNull() ?: return null
        if (epoch < 0 || run < 0 || childRun < 0 || tool < 0 || conversation < 0 || vault < 0) {
            return null
        }
        return NativeLiveWork(
            nativeRootEpoch = epoch,
            storeReady = storeReady,
            admissionFenced = admissionFenced,
            runCount = run,
            childRunCount = childRun,
            toolCount = tool,
            conversationCount = conversation,
            vaultMaintenanceCount = vault,
        )
    }

    private fun parseFlag(raw: String?): Boolean? = when (raw) {
        "1" -> true
        "0" -> false
        else -> null // "true"/"false" or anything else is DRIFT == unknown.
    }
}
