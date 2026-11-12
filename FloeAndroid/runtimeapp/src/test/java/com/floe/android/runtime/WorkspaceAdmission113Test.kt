// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Author-written (NOT executed by this source stage) regressions for the
 * post112 FS01/FS12 owner life cycle. They pin the runtime's authoritative
 * workspace-owner resolution:
 *
 *  * a stale `workspaceReuse` hint (the named owner already settled or belongs
 *    to a retired runtime generation) never deadlocks a live task with
 *    `workspaceOwnerUnavailable`;
 *  * the runtime still joins the ONE actual live owner of the exact project,
 *    or a retained deferred export;
 *  * a retained/unknown project owner and multiple live owners remain
 *    fail-closed refusals (no implicit first/currentUI selection, no release
 *    by guess);
 *  * a start with no owner at all becomes a normal new owner (the import
 *    path), never a fabricated participant.
 */
class WorkspaceAdmission113Test {

    private fun resolve(
        requestedShared: Boolean = false,
        expectedOwner: String? = null,
        projectOwner: String? = null,
        live: Collection<String> = emptyList(),
        deferred: Boolean = false,
    ) = LinuxRuntimeOperations.resolveWorkspaceAdmission(
        requestedShared = requestedShared,
        expectedOwnerSessionID = expectedOwner,
        projectOwnerLeaseID = projectOwner,
        liveProjectOwnerLeaseIDs = live,
        deferredLive = deferred,
    )

    @Test
    fun sharedHintNamingTheLiveOwnerJoinsThatOwner() {
        val answer = resolve(requestedShared = true, expectedOwner = "lease-A", live = listOf("lease-A"))
        assertEquals("lease-A", answer.ownerLeaseID)
        assertTrue(answer.participant)
        assertNull(answer.refusal)
    }

    @Test
    fun staleHintWithAnotherLiveProjectOwnerJoinsTheAuthoritativeOwner() {
        // The original owner settled while this task stayed live; the runtime
        // has since admitted its real project owner. The stale lease id must
        // not be treated as a refusal, and must never be used as the owner.
        val answer = resolve(requestedShared = true, expectedOwner = "lease-old", live = listOf("lease-live"))
        assertEquals("lease-live", answer.ownerLeaseID)
        assertTrue(answer.participant)
        assertNull(answer.refusal)
    }

    @Test
    fun staleHintWithNoOwnerBecomesAFreshOwnerImport() {
        // This is the actual seq631/730/781/877 shape: the retained local
        // session was already settled in the runtime, so the named owner is
        // gone and no project owner/deferred export exists. A live run with a
        // real grant must be able to start its own workspace owner again.
        val answer = resolve(requestedShared = true, expectedOwner = "lease-retired")
        assertNull(answer.ownerLeaseID)
        assertFalse(answer.participant)
        assertNull(answer.refusal)
    }

    @Test
    fun retainedProjectOwnerStillRefusesANewOwner() {
        // A retained/unknown owner (failed native release or an unfinished
        // export) owns the project slot. Never import over it.
        val answer = resolve(projectOwner = "lease-retained")
        assertNull(answer.ownerLeaseID)
        assertFalse(answer.participant)
        assertEquals("workspaceOwnerUnavailable", answer.refusal)
    }

    @Test
    fun multipleLiveOwnersFailClosedInsteadOfChoosingOne() {
        val answer = resolve(live = listOf("lease-A", "lease-B"))
        assertNull(answer.ownerLeaseID)
        assertFalse(answer.participant)
        assertEquals("workspaceOwnerUnavailable", answer.refusal)
    }

    @Test
    fun deferredExportKeepsParticipantsOnTheSameGuestTree() {
        val answer = resolve(deferred = true)
        assertNull(answer.ownerLeaseID)
        assertTrue(answer.participant)
        assertNull(answer.refusal)
    }

    @Test
    fun malformedSharedHintWithoutAnOwnerStaysRefused() {
        val answer = resolve(requestedShared = true, expectedOwner = null)
        assertNull(answer.ownerLeaseID)
        assertFalse(answer.participant)
        assertEquals("workspaceOwnerUnavailable", answer.refusal)
    }

    @Test
    fun ordinaryStartWithNoOwnerBecomesTheImportOwner() {
        val answer = resolve()
        assertNull(answer.ownerLeaseID)
        assertFalse(answer.participant)
        assertNull(answer.refusal)
    }

    @Test
    fun liveOwnerWinsOverAnOrdinaryStart() {
        val answer = resolve(live = listOf("lease-A"))
        assertEquals("lease-A", answer.ownerLeaseID)
        assertTrue(answer.participant)
        assertNull(answer.refusal)
    }
}
