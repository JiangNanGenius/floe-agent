// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * AUTHORED NOT RUN regression for the safe-to-abandon start path.
 *
 * Existing old code removed `heldLeases`/`leaseStartIDs`/`leaseRoles` even
 * when the ORIGINAL `authority.abandonUnstarted(lease)` call threw. Under the
 * new exact-request permit ownership that would falsely settle a retained
 * never-started lease: its foreground permit could be pruned, and a real
 * abandon failure would become invisible. The decision must retain every
 * exact ownership map unless the native abandon actually acknowledged.
 */
class RuntimeStartAbandonTest {

    @Test
    fun failedNativeAbandonRetainsEveryExactOwnershipMap() {
        for (startedOwner in listOf(false, true)) {
            for (registeredParticipant in listOf(false, true)) {
                val cleanup = LinuxRuntimeOperations.startAbandonCleanup(
                    abandonAcknowledged = false,
                    startedOwner = startedOwner,
                    registeredParticipant = registeredParticipant,
                )
                assertFalse("held lease must stay retained", cleanup.removeHeldLease)
                assertFalse("start-id ownership must stay retained", cleanup.removeLeaseStart)
                assertFalse("role must stay retained", cleanup.removeLeaseRole)
                assertFalse("owner registration must stay retained", cleanup.removeWorkspaceOwner)
                assertFalse("participant registration must stay retained", cleanup.removeParticipant)
            }
        }
    }

    @Test
    fun acknowledgedNativeAbandonRetiresOnlyRegisteredExactOwnership() {
        val all = LinuxRuntimeOperations.startAbandonCleanup(
            abandonAcknowledged = true,
            startedOwner = true,
            registeredParticipant = true,
        )
        assertTrue(all.removeHeldLease)
        assertTrue(all.removeLeaseStart)
        assertTrue(all.removeLeaseRole)
        assertTrue(all.removeWorkspaceOwner)
        assertTrue(all.removeParticipant)

        val noRegistrations = LinuxRuntimeOperations.startAbandonCleanup(
            abandonAcknowledged = true,
            startedOwner = false,
            registeredParticipant = false,
        )
        assertTrue(noRegistrations.removeHeldLease)
        assertTrue(noRegistrations.removeLeaseStart)
        assertTrue(noRegistrations.removeLeaseRole)
        assertFalse(noRegistrations.removeWorkspaceOwner)
        assertFalse(noRegistrations.removeParticipant)
    }
}
