// SPDX-License-Identifier: MPL-2.0
// Pure JVM regression for per-owner asynchronous revisions.
package com.floe.android.host.deviceaccess

import com.floe.android.phonecontrol.PhoneControlOwner
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * A Stop/Pause of task A previously bumped one global revision, causing B's
 * in-flight arm, screenshot or Continue result to be discarded. The revision
 * is now per exact owner; stopping A cannot fence B.
 */
class PhoneControlRevisionsTest {

    private fun owner(task: Int, run: Int): PhoneControlOwner = PhoneControlOwner(
        UUID.fromString("00000000-0000-0000-0000-${task.toString().padStart(12, '0')}"),
        UUID.fromString("00000000-0000-0000-0000-${run.toString().padStart(12, '0')}"),
    )

    @Test
    fun bumpingOneOwnerLeavesAnotherOwnerRevisionUnchanged() {
        val revisions = PhoneControlRevisions()
        val a = owner(1, 11)
        val b = owner(2, 22)
        val bBefore = revisions.current(b)

        val aBefore = revisions.current(a)
        val aAfter = revisions.bump(a)

        assertNotEquals(aBefore, aAfter)
        assertEquals(aAfter, revisions.current(a))
        assertEquals("B's in-flight result must stay valid", bBefore, revisions.current(b))
    }

    @Test
    fun clearingOneOwnerDoesNotTouchAnother() {
        val revisions = PhoneControlRevisions()
        val a = owner(1, 11)
        val b = owner(2, 22)
        val bAfter = revisions.bump(b)

        revisions.bump(a)
        revisions.clear(a)

        assertEquals(0L, revisions.current(a))
        assertEquals(bAfter, revisions.current(b))
    }

    @Test
    fun aNewOwnerStartsAtZeroAndNeverInheritsAnOldFence() {
        val revisions = PhoneControlRevisions()
        val a = owner(1, 11)
        revisions.bump(a)
        val fresh = owner(1, 12)
        assertEquals(0L, revisions.current(fresh))
    }
}
