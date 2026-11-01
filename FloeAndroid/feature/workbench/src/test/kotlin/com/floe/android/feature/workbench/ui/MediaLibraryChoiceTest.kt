// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui

import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.workbench.MediaProjectSummary
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaLibraryChoiceTest {
    private fun summary(
        ownerKind: String,
        ownerID: String? = null,
        environmentID: String? = null,
    ) = MediaProjectSummary(
        id = "88888888-8888-8888-8888-888888888888",
        name = "Project",
        kind = "image",
        revision = 2,
        updatedAt = "2026-11-01T00:00:00Z",
        ownerKind = ownerKind,
        ownerID = ownerID,
        environmentID = environmentID,
        assetCount = 1,
        layerCount = 1,
        corrupt = false,
        writable = true,
        provenanceWarning = false,
    )

    @Test
    fun workspaceWithRealIdentityOffersBothStorageChoices() {
        val value = summary("workspace", "77777777-7777-7777-7777-777777777777")
        assertTrue(workspaceCopyAvailable(value))
        assertTrue(editCopyOriginAvailable(value))
    }

    @Test
    fun workspaceWithoutIdentityOffersNeither() {
        val value = summary("workspace")
        assertFalse(workspaceCopyAvailable(value))
        assertFalse(editCopyOriginAvailable(value))
    }

    @Test
    fun filesOwnerMayUseBoundedOriginWithoutAnOwnerID() {
        val value = summary("files")
        assertFalse(workspaceCopyAvailable(value))
        assertTrue(editCopyOriginAvailable(value))
        val origin = originFromSummary(value)
        assertEquals(CreativeOriginContext.FILES, origin.kind)
        assertNull(origin.ownerID)
    }

    @Test
    fun chatAndCanvasRequireTheirRealOwner() {
        assertFalse(editCopyOriginAvailable(summary("chat")))
        assertFalse(editCopyOriginAvailable(summary("canvas")))
        assertTrue(editCopyOriginAvailable(
            summary("chat", "99999999-9999-9999-9999-999999999999")))
        assertTrue(editCopyOriginAvailable(
            summary("canvas", "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")))
    }

    @Test
    fun originPreservesRecordedEnvironmentProvenance() {
        val value = summary(
            "workspace",
            "77777777-7777-7777-7777-777777777777",
            environmentID = "linux-env-1",
        )
        val origin = originFromSummary(value)
        assertEquals("linux-env-1", origin.environmentID)
        assertEquals("77777777-7777-7777-7777-777777777777", origin.ownerID)
    }
}
