// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.WorkspaceDocumentSurface
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Conversation artifact direct-preview policy regressions
 * (job-ca4547223bea4819, source-only lane; Main executes the suite).
 *
 * The open itself is owner-fenced and staged by the existing typed viewers;
 * these tests pin the ONLY two pure decisions this lane added: the typed
 * refusal-code → user-presentable failure-class mapping (one honest wording
 * per refusal family, internal codes never surface raw) and the request
 * carrier invariants (owned identity only, positive token).
 */
class ConversationArtifactPreviewPolicyTest {

    @Test
    fun `owner retirements map to owner failure class`() {
        for (code in listOf(
            "ownerChanged", "ownerUnavailable", "ownerStopping", "retired",
            "epochMismatch", "workspaceUnbound", "superseded", "cancelled",
        )) {
            assertEquals(
                "code=$code", ConversationArtifactOpenFailureKind.OWNER,
                ConversationArtifactOpenPolicy.failureFor(code),
            )
        }
    }

    @Test
    fun `native guard refusals map to access failure class`() {
        for (code in listOf(
            "secretFile", "escapesRoot", "notAdmitted", "invalidTask",
            "invalidBinding", "invalidPath",
        )) {
            assertEquals(
                "code=$code", ConversationArtifactOpenFailureKind.ACCESS,
                ConversationArtifactOpenPolicy.failureFor(code),
            )
        }
    }

    @Test
    fun `size and busy refusals map to their own classes`() {
        assertEquals(
            ConversationArtifactOpenFailureKind.SIZE,
            ConversationArtifactOpenPolicy.failureFor("contentTooLarge"),
        )
        assertEquals(
            ConversationArtifactOpenFailureKind.SIZE,
            ConversationArtifactOpenPolicy.failureFor("bufferLimit"),
        )
        assertEquals(
            ConversationArtifactOpenFailureKind.BUSY,
            ConversationArtifactOpenPolicy.failureFor("officeBusy"),
        )
        assertEquals(
            ConversationArtifactOpenFailureKind.BUSY,
            ConversationArtifactOpenPolicy.failureFor("editorSessionsSaturated"),
        )
    }

    @Test
    fun `unknown refusal never surfaces raw and never fabricates a class`() {
        // Unknown/empty codes collapse to the generic SOURCE class: the banner
        // stays honest and concise instead of leaking an internal code.
        assertEquals(
            ConversationArtifactOpenFailureKind.SOURCE,
            ConversationArtifactOpenPolicy.failureFor("someInternalWireDetail"),
        )
        assertEquals(
            ConversationArtifactOpenFailureKind.SOURCE,
            ConversationArtifactOpenPolicy.failureFor(null),
        )
    }

    @Test
    fun `request carries owned identity only and derives the display name`() {
        val request = ConversationArtifactPreviewRequest(
            taskID = "3f6f8f9c-7d4a-4c1e-9b2a-1c5e8d3f6a70",
            workspaceID = "8d2b1c4e-5a6f-4e7b-9c3d-2f1a5b8c6d70",
            relativePath = "GeneratedMedia/video-clip.mp4",
            surface = WorkspaceDocumentSurface.MEDIA,
            token = 7L, nativeEpoch = 11L, hostGeneration = 3L, sessionEpoch = 5L,
        )
        assertEquals("video-clip.mp4", request.fileName)
        assertEquals(WorkspaceDocumentSurface.MEDIA, request.surface)
        // No host path, renderer ticket or model identity exists on the
        // carrier: only presentation and captured owner fields above.
        assertTrue(request.toString().contains("GeneratedMedia/video-clip.mp4"))
    }

    @Test
    fun `request refuses replaced root generation or conversation session`() {
        val request = ConversationArtifactPreviewRequest(
            taskID = "task", workspaceID = "workspace", relativePath = "clip.mp4",
            surface = WorkspaceDocumentSurface.MEDIA, token = 1L,
            nativeEpoch = 11L, hostGeneration = 3L, sessionEpoch = 5L,
        )
        assertTrue(request.matchesOwner(11L, 3L, 5L))
        org.junit.Assert.assertFalse(request.matchesOwner(null, 3L, 5L))
        org.junit.Assert.assertFalse(request.matchesOwner(12L, 3L, 5L))
        org.junit.Assert.assertFalse(request.matchesOwner(11L, 4L, 5L))
        org.junit.Assert.assertFalse(request.matchesOwner(11L, 3L, 6L))
    }

    @Test(expected = IllegalArgumentException::class)
    fun `request refuses a non-positive token`() {
        ConversationArtifactPreviewRequest(
            taskID = "3f6f8f9c-7d4a-4c1e-9b2a-1c5e8d3f6a70",
            workspaceID = "8d2b1c4e-5a6f-4e7b-9c3d-2f1a5b8c6d70",
            relativePath = "notes/plan.md",
            surface = WorkspaceDocumentSurface.CODE_EDITOR,
            token = 0L, nativeEpoch = 11L, hostGeneration = 3L, sessionEpoch = 5L,
        )
    }
}
