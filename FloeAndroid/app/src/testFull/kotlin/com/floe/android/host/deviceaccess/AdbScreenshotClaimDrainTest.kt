// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.phonecontrol.PhoneControlOwner
import com.floe.android.rootsystem.OperationClaim
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Test

class AdbScreenshotClaimDrainTest {
    @Test
    fun oldGrantDrainPreservesReconnectedGrantAndOtherOwner() {
        val owner = PhoneControlOwner(UUID.randomUUID(), UUID.randomUUID())
        val other = PhoneControlOwner(UUID.randomUUID(), UUID.randomUUID())
        fun claim(who: PhoneControlOwner, grant: String) = OperationClaim(
            who.taskID.toString(), who.runID.toString(), 1, grant, UUID.randomUUID().toString(),
        )
        val old = claim(owner, "old")
        val replacement = claim(owner, "new")
        val otherClaim = claim(other, "other")
        val claims = mutableSetOf(old, replacement, otherClaim)
        assertEquals(listOf(old), drainAdbScreenshotClaims(claims, owner, "old"))
        assertEquals(setOf(replacement, otherClaim), claims)
    }
}
