// SPDX-License-Identifier: MPL-2.0
// Pure JVM regression for the global-service stop decision.
package com.floe.android.host.deviceaccess

import com.floe.android.phonecontrol.PhoneControlOwner
import java.util.UUID
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The service API is global. A stopped A may call stop()/takeover() only while
 * A is still the one actual session; otherwise old cleanup must leave a newly
 * armed B untouched. Host callers evaluate this under automationMutex.
 */
class PhoneControlStopServicePolicyTest {

    private fun owner(task: Int, run: Int): PhoneControlOwner = PhoneControlOwner(
        UUID.fromString("00000000-0000-0000-0000-${task.toString().padStart(12, '0')}"),
        UUID.fromString("00000000-0000-0000-0000-${run.toString().padStart(12, '0')}"),
    )

    @Test
    fun stoppedOwnerMayFenceWhenNoNewerHostOrServiceOwnerExists() {
        val a = owner(1, 11)
        assertTrue(PhoneControlStopServicePolicy.mayFenceGlobalService(a, null, null))
        assertTrue(PhoneControlStopServicePolicy.mayFenceGlobalService(a, a, a))
        assertTrue(PhoneControlStopServicePolicy.mayFenceGlobalService(a, a, null))
        assertTrue(PhoneControlStopServicePolicy.mayFenceGlobalService(a, null, a))
    }

    @Test
    fun aNewerHostOwnerNeverGetsTheGlobalStop() {
        val a = owner(1, 11)
        val b = owner(2, 22)
        assertFalse(PhoneControlStopServicePolicy.mayFenceGlobalService(a, b, a))
        assertFalse(PhoneControlStopServicePolicy.mayFenceGlobalService(a, b, null))
        assertFalse(PhoneControlStopServicePolicy.mayFenceGlobalService(a, b, b))
    }

    @Test
    fun aNewerServiceOwnerNeverGetsTheGlobalStop() {
        val a = owner(1, 11)
        val b = owner(2, 22)
        assertFalse(PhoneControlStopServicePolicy.mayFenceGlobalService(a, null, b))
        assertFalse(PhoneControlStopServicePolicy.mayFenceGlobalService(a, a, b))
    }
}
