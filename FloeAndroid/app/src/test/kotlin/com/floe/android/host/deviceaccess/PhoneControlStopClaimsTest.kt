// SPDX-License-Identifier: MPL-2.0
// Pure JVM regression for exact-owner stop cleanup ownership.
package com.floe.android.host.deviceaccess

import com.floe.android.phonecontrol.PhoneControlOwner
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the two integration gaps from the Full12 review:
 *  - a pending A cleanup must not make a later B Stop look like a duplicate;
 *  - an older A cleanup must not clear the newer B stop's busy ownership.
 */
class PhoneControlStopClaimsTest {

    private fun owner(task: Int, run: Int): PhoneControlOwner = PhoneControlOwner(
        UUID.fromString("00000000-0000-0000-0000-${task.toString().padStart(12, '0')}"),
        UUID.fromString("00000000-0000-0000-0000-${run.toString().padStart(12, '0')}"),
    )

    @Test
    fun aDifferentOwnerCanClaimWhileOldCleanupIsPending() {
        val claims = PhoneControlStopClaims()
        val a = owner(1, 11)
        val b = owner(2, 22)
        val stopA = claims.begin(a, stopToken = 1, takeOver = false)

        assertFalse("B is not a duplicate of A", claims.isDuplicate(b, 2))
        val stopB = claims.begin(b, stopToken = 2, takeOver = false)

        assertFalse("the newest stop owns foreground presentation", claims.finish(stopA))
        assertEquals(stopB, claims.current())
        assertTrue(claims.finish(stopB))
        assertNull(claims.current())
    }

    @Test
    fun sameOwnerAndSameStopTokenIsDuplicateButNewGenerationIsNot() {
        val claims = PhoneControlStopClaims()
        val a = owner(1, 11)
        claims.begin(a, stopToken = 1, takeOver = false)

        assertTrue(claims.isDuplicate(a, 1))
        assertFalse("a re-allowed owner stopped again is a new generation", claims.isDuplicate(a, 2))
        assertFalse("another owner is never a duplicate", claims.isDuplicate(owner(2, 22), 1))
    }

    @Test
    fun oldFinishCannotClearNewerStopClaim() {
        val claims = PhoneControlStopClaims()
        val a = owner(1, 11)
        val b = owner(2, 22)
        val old = claims.begin(a, stopToken = 1, takeOver = false)
        val fresh = claims.begin(b, stopToken = 2, takeOver = true)

        assertFalse(claims.finish(old))
        assertEquals(fresh, claims.current())
        assertTrue(claims.finish(fresh))
        assertNull(claims.current())
    }

    @Test
    fun clearDropsOnlyPresentationOwnership() {
        val claims = PhoneControlStopClaims()
        val a = owner(1, 11)
        val claim = claims.begin(a, stopToken = 1, takeOver = false)
        assertNotNull(claim)

        claims.clear()

        assertNull(claims.current())
        assertFalse(claims.finish(claim))
    }
}
