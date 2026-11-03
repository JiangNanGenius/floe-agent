// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench

import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativePathGuard
import com.floe.android.feature.canvas.CreativeStorageLayer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Authored R2 generation/ownership contract checks. NOT RUN in contracts09. */
class WorkbenchGenerationContractTest {
    @Test
    fun `generation context is explicit and never project id only`() {
        val context = CreativeProjectContext(
            projectID = "p1",
            sessionToken = "s1",
            storage = CreativeStorageLayer.AppOwned,
            origin = CreativeOriginContext(CreativeOriginContext.CANVAS, ownerID = "c1"),
        )
        assertEquals("p1", context.projectID)
        assertTrue(context.storage is CreativeStorageLayer.AppOwned)
        assertEquals("canvas", context.origin?.kind)

        val workspace = CreativeProjectContext(
            projectID = "p2",
            sessionToken = "s2",
            storage = CreativeStorageLayer.Workspace("w1"),
        )
        assertTrue(workspace.storage is CreativeStorageLayer.Workspace)
        assertEquals("w1", (workspace.storage as CreativeStorageLayer.Workspace).workspaceID)
    }

    @Test
    fun `generation wire state spellings match the frozen lists`() {
        assertEquals(
            GenerationWire.IMAGE_REQUEST_STATES,
            ImageRequestState.entries.map { it.wire })
        assertEquals(
            GenerationWire.JOB_STATES,
            MediaJobState.entries.map { it.wire })
        assertEquals(
            GenerationWire.CANDIDATE_STATES,
            MediaCandidateState.entries.map { it.wire })
        assertEquals(
            GenerationWire.CANDIDATE_DELIVERY_OUTCOMES,
            CandidateDeliveryOutcome.entries.map { it.wire })
        assertEquals(7, GenerationWire.IMAGE_REQUEST_STATES.size)
        assertEquals(9, GenerationWire.JOB_STATES.size)
        assertEquals(4, GenerationWire.CANDIDATE_STATES.size)
        assertEquals(3, GenerationWire.CANDIDATE_DELIVERY_OUTCOMES.size)
    }

    @Test
    fun `model routes expose actual availability and honest cost notes`() {
        val route = GenerationModelRoute(
            routeID = "route-1",
            remoteModelID = "model-1",
            providerID = "provider-1",
            providerName = "Provider",
            kind = GenerationKind.IMAGE,
            enabled = true,
            available = false,
            unavailableReason = "route not configured for this account",
            parameters = GenerationParameterContract(
                sizes = listOf("1024x1024"),
                maxCount = 4,
                maxReferenceImages = 1,
            ),
            referenceImagePolicy = ReferenceImagePolicy(
                maxImages = 1,
                maxBytesPerImage = WorkbenchR2Limits.IMAGE_SOURCE_BYTES.toLong(),
                acceptedMimeTypes = listOf("image/png", "image/jpeg"),
            ),
            costNote = "The provider account is authoritative.",
        )
        val catalog = GenerationModelCatalog(image = listOf(route), video = emptyList())
        assertFalse(catalog.image.single().available)
        assertEquals("route not configured for this account",
            catalog.image.single().unavailableReason)
        assertTrue(catalog.image.single().costNote.isNotEmpty())
        assertEquals(4, catalog.image.single().parameters.maxCount)
    }

    @Test
    fun `candidate relative path is a safe native path not an absolute uri`() {
        val candidate = MediaCandidate(
            candidateID = "c1",
            projectID = "p1",
            kind = GenerationKind.VIDEO,
            createdAt = "2026-11-01T00:00:00Z",
            byteCount = 10,
            sha256 = "a".repeat(64),
            relativePath = "MediaProjects/Candidates/p1/c1.mp4",
        )
        assertTrue(CreativePathGuard.isSafeRelativePath(candidate.relativePath))
        assertFalse(CreativePathGuard.isSafeRelativePath("/absolute/c1.mp4"))
        assertFalse(CreativePathGuard.isSafeRelativePath("content://media/1"))
        assertEquals(MediaCandidateState.PENDING, candidate.state)
    }

    @Test
    fun `job status exposes task reference presence but no raw provider id`() {
        val status = MediaJobStatus(
            jobID = "job-1",
            projectID = "p1",
            state = MediaJobState.WAITING_FOR_PROVIDER,
            updatedAt = "2026-11-01T00:00:00Z",
            progressHint = 0.25,
            resultAvailable = false,
            providerTaskReferencePresent = true,
            lastErrorCode = null,
            retryable = false,
            canCancel = true,
        )
        assertEquals("waitingForProvider", status.state.wire)
        assertTrue(status.providerTaskReferencePresent)
        assertTrue(status.canCancel)
        assertEquals(
            setOf(
                "media.video.load", "media.video.apply", "generation.models",
                "generation.image.submit", "generation.image.status",
                "generation.image.dismiss", "generation.video.submit",
                "generation.video.status", "generation.video.cancel",
                "generation.video.deliver", "generation.candidates.list",
                "generation.candidates.accept", "generation.candidates.reject"),
            WorkbenchWireActions.ALL.toSet())
        assertEquals(13, WorkbenchWireActions.ALL.size)
    }

    @Test
    fun `submit handles carry stable identity and idempotency`() {
        val request = ImageGenerationRequest(
            prompt = "a red square",
            modelRouteID = "route-1",
            count = 2,
            sourceAssetID = "asset-1",
            referenceAssetIDs = listOf("asset-2"),
            idempotencyKey = "idem-1",
        )
        assertEquals(2, request.count)
        assertEquals("asset-1", request.sourceAssetID)
        assertEquals("idem-1", request.idempotencyKey)
        val handle = ImageRequestHandle(
            requestID = "r1",
            projectID = "p1",
            acceptedAt = "2026-11-01T00:00:00Z",
            state = ImageRequestState.SUBMITTED,
            idempotent = false,
        )
        assertEquals("submitted", handle.state.wire)
        assertEquals("job-1", VideoJobHandle(
            jobID = "job-1", projectID = "p1",
            acceptedAt = "2026-11-01T00:00:00Z",
            state = MediaJobState.SUBMITTED, idempotent = true).jobID)
    }
}
