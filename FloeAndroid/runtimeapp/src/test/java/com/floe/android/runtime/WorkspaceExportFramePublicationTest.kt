// SPDX-License-Identifier: MPL-2.0
// Regression for the reproducible multi-terminal natural-exit fault
// (first exit while another tab stays alive reported "Terminal unavailable").
//
// Established producer race: finish() assigns `workspaceResult` BEFORE
// `owned.finished` becomes true. The shell.poll / stdio.poll page builders
// sampled `owned.finished.get()` into `leaseReleased` but published the
// workspace/export metadata as soon as `workspaceResult` existed. A poll in
// that window emitted `leaseReleased=false` together with
// `workspaceStatus="deferred"` — the exact combination the trusted Swift poll
// decoder correctly refuses as replyMalformed, which the G04 terminal domain
// then surfaced as a false `fault` phase even though the engine had proved a
// real exit. The last (synced) release did not trip the guard only because a
// pre-release "synced" is ignored before release.
//
// The fix publishes workspace metadata ONLY from the SAME immutable release
// snapshot that produced `leaseReleased` (`putWorkspaceExportFrame`). These
// tests pin that contract at the producer boundary; the Swift decoder stays
// strict (no decode bypass, no fabricated exit).
package com.floe.android.runtime

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkspaceExportFramePublicationTest {

    @Test
    fun preReleaseDeferredResultIsNotPublishedWithPendingLease() {
        // The exact first-owner-release window: workspaceResult already holds
        // the deferred export while finished is still false. The frame must
        // NOT carry workspaceStatus yet (it may only ever ride a released
        // terminal), otherwise the host decoder rejects the whole frame.
        val frame = JSONObject()
        putWorkspaceExportFrame(
            result = frame,
            released = false,
            workspaceResult = JSONObject()
                .put("workspaceStatus", "deferred")
                .put("workspaceKey", "project-1"),
            workspaceOwner = true,
        )
        assertFalse("no workspace metadata before release", frame.has("workspaceStatus"))
        assertFalse("no owner fact before release", frame.has("workspaceOwner"))
        assertFalse("no workspace key before release", frame.has("workspaceKey"))
    }

    @Test
    fun releasedDeferredOwnerPublishesTypedOwnerFact() {
        // First owner release, observed after the real terminal: the deferred
        // status rides the released frame together with the typed owner fact
        // the decoder requires (owner == true retains the export obligation).
        val frame = JSONObject()
        putWorkspaceExportFrame(
            result = frame,
            released = true,
            workspaceResult = JSONObject()
                .put("workspaceStatus", "deferred")
                .put("workspaceKey", "project-1"),
            workspaceOwner = true,
        )
        assertEquals("deferred", frame.getString("workspaceStatus"))
        assertEquals("project-1", frame.getString("workspaceKey"))
        assertTrue(frame.getBoolean("workspaceOwner"))
    }

    @Test
    fun releasedParticipantDeferredPublishesOwnerFalse() {
        // A participant whose shared export is owned by the still-live owner:
        // the same released-frame contract carries owner == false.
        val frame = JSONObject()
        putWorkspaceExportFrame(
            result = frame,
            released = true,
            workspaceResult = JSONObject()
                .put("workspaceStatus", "deferred")
                .put("workspaceKey", "project-1"),
            workspaceOwner = false,
        )
        assertEquals("deferred", frame.getString("workspaceStatus"))
        assertFalse(frame.getBoolean("workspaceOwner"))
    }

    @Test
    fun releasedSyncedExportPublishesFullMetadata() {
        // Last exit performs the real export; the settled frame carries the
        // export result (recovery refs included) on the released terminal.
        val frame = JSONObject()
        putWorkspaceExportFrame(
            result = frame,
            released = true,
            workspaceResult = JSONObject()
                .put("workspaceStatus", "synced")
                .put("workspaceKey", "project-1")
                .put("workspaceRecoveryRef", "0".repeat(32)),
            workspaceOwner = true,
        )
        assertEquals("synced", frame.getString("workspaceStatus"))
        assertEquals("0".repeat(32), frame.getString("workspaceRecoveryRef"))
        assertTrue(frame.getBoolean("workspaceOwner"))
    }

    @Test
    fun releasedFailedExportPublishesHonestFailureStatus() {
        // A genuine failed export still reports its honest status on the
        // released frame — never a fabricated synced/deferred success.
        val frame = JSONObject()
        putWorkspaceExportFrame(
            result = frame,
            released = true,
            workspaceResult = JSONObject()
                .put("workspaceStatus", "error")
                .put("workspaceKey", "project-1"),
            workspaceOwner = true,
        )
        assertEquals("error", frame.getString("workspaceStatus"))
    }

    @Test
    fun releasedWithNoWorkspaceResultPublishesNothing() {
        // A terminal that never owned a workspace (or raced its release)
        // simply carries no metadata — absence stays absence.
        val frame = JSONObject()
        putWorkspaceExportFrame(result = frame, released = true, workspaceResult = null, workspaceOwner = true)
        assertFalse(frame.has("workspaceStatus"))
        assertFalse(frame.has("workspaceOwner"))
    }
}
