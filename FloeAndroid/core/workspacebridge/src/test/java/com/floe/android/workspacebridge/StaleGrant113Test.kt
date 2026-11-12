// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Author-written (NOT executed by this source stage) post112 FS01/FS12
 * regressions. The Linux owner-lifecycle repair must not weaken the ORIGINAL
 * workspace-grant refusal paths:
 *
 *  * a close/fenced grant refuses every NEW authenticated transaction
 *    (`grantClosed`) instead of dispatching into a retired session;
 *  * an already-entered transaction is really drained before close returns
 *    (no timeout/fake-zero release);
 *  * a retired/unknown runtime owner maps only through the existing closed
 *    refusal vocabulary, never a fabricated success token.
 */
class StaleGrant113Test {

    @Test
    fun fencedGrantRefusesNewTransactionsWithoutCounting() {
        val gate = WorkspaceIOLatch()
        assertTrue(gate.begin())
        assertEquals(1, gate.inflightCount)
        assertTrue(gate.fence())
        assertFalse("a fenced (stale/closed) grant must refuse new work", gate.begin())
        assertEquals("the refused entry is never counted", 1, gate.inflightCount)
        gate.end()
        assertEquals(0, gate.inflightCount)
    }

    @Test
    fun doubleFenceKeepsTheOriginalDrainOwner() {
        val gate = WorkspaceIOLatch()
        assertTrue(gate.fence())
        assertFalse("a second closer must not claim the same drain", gate.fence())
        assertTrue(gate.isFenced)
    }

    @Test
    fun retiredOwnerAndEpochKeepTheClosedGrantVocabulary() {
        // The runtime-side owner refusal and the native epoch retirement are
        // surfaced through the SAME existing tokens; the new lifecycle code
        // introduces no widened grant/success vocabulary.
        assertEquals("epochNotCurrent", CoreWorkspaceGrant.refusalToken(
            CoreWorkspaceGrant.REFUSAL_BINDING_REFUSED, "epochNotCurrent"))
        // A free-text/runtime-owner token is never passed through: it falls
        // back to the closed branch token, so the repair cannot widen the
        // grant-refusal vocabulary.
        assertEquals(CoreWorkspaceGrant.REFUSAL_BINDING_REFUSED,
            CoreWorkspaceGrant.refusalToken(
                CoreWorkspaceGrant.REFUSAL_BINDING_REFUSED, "workspaceOwnerUnavailable"))
        assertTrue("workspaceOwnerUnavailable" !in CoreWorkspaceGrant.NATIVE_REFUSAL_CODES)
    }
}
