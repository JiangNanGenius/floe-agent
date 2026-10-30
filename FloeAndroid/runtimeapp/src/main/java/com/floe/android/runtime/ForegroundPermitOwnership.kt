// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

/**
 * Pure retirement/loss policy for `LinuxRuntimeService` (no Android, no
 * org.json, no Binder): JVM-testable by construction.
 *
 * The ORIGINAL service retained EVERY admitted foreground IBinder until the
 * whole engine owned nothing, then treated ANY retained permit that was no
 * longer active as a global stop. With two live interactive sessions that
 * makes a normally settled participant (A closed by the user) look like a
 * permission loss long after its own work ended, killing the healthy B.
 *
 * This round keeps the ORIGINAL fail-closed response for a permit that is
 * actually lost while its exact work is still owned, and changes only the
 * retirement rule:
 *
 *  * an association retires ONLY when every exact admitted request id is
 *    absent from the runtime's positively-owned set (the request really
 *    settled); a retired participant is then pruned with no stop at all;
 *  * an inactive/dead permit whose exact request is STILL owned is an active
 *    permit loss and keeps the ORIGINAL GLOBAL stop (shared UID and deferred
 *    exports make that fail-closed boundary the safer one);
 *  * an owned request id that has no association is UNKNOWN, not settled:
 *    unknown ownership never retires a token and never becomes a fabricated
 *    loss by itself. There is no elapsed-time prune and no new per-permit
 *    cancel/permission authority.
 *
 * Ownership facts come from `LinuxRuntimeOperations.ownedRequestIDs()`:
 * pending start, live `Running.startID`, a retained lease/failed lease and a
 * deferred export's OWNER start id. The plan is lifecycle metadata only.
 */
internal object ForegroundPermitOwnership {

    internal data class PermitView(
        /** Identity key of the retained foreground IBinder (production) or a
         *  test token; never serialized and never an authorization value. */
        val token: Any,
        /** Exact admitted work request ids associated with this permit. */
        val requestIDs: Set<String>,
        /** The ORIGINAL `RuntimeForegroundPermit.isActive` answer for THIS
         *  permit, measured by the caller outside any lock. */
        val active: Boolean,
    )

    internal data class Plan(
        /** Associations whose every request id is actually settled. */
        val retire: List<Any>,
        /** An inactive/dead permit still owns exact work: ORIGINAL global. */
        val activePermitLoss: Boolean,
    )

    internal fun plan(
        permits: List<PermitView>,
        ownedRequestIDs: Set<String>,
    ): Plan {
        val retire = ArrayList<Any>(permits.size)
        var activePermitLoss = false
        for (permit in permits) {
            // POSITIVE settlement only: a request id retires nothing until it
            // is absent from the live ownership set. Unknown ids stay
            // retained (no expiry) and are never classified as a loss here.
            val live = permit.requestIDs.intersect(ownedRequestIDs)
            if (live.isEmpty()) {
                retire.add(permit.token)
            } else if (!permit.active) {
                activePermitLoss = true
            }
        }
        return Plan(retire, activePermitLoss)
    }
}
