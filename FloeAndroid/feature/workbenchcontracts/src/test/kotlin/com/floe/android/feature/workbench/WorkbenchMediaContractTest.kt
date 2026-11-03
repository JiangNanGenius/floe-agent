// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench

import com.floe.android.feature.canvas.CreativeLimits
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Authored R2 media platform/limit contract checks. NOT RUN in contracts09. */
class WorkbenchMediaContractTest {
    private fun context() = CreativeProjectContext(
        projectID = "p1",
        sessionToken = "s1",
        storage = CreativeStorageLayer.AppOwned,
        origin = CreativeOriginContext.standalone(),
    )

    private fun snapshot() = RenderSnapshotLease(
        leaseID = "lease-1",
        mediaRootPath = "/trusted/root",
        relativePath = "Snapshots/p4.json",
        sha256 = "c".repeat(64),
        byteCount = 4096,
        expiresAt = "2026-11-01T01:00:00Z",
    )

    private fun binding() = MediaExportBinding(
        context = context(),
        mediaRootPath = "/trusted/root",
        projectRevision = 4,
        timelineDigest = "digest",
        attemptID = "attempt-1",
        snapshot = snapshot(),
    )

    @Test
    fun `r2 limits preserve r1 bridge and project budgets`() {
        assertEquals(CreativeLimits.REQUEST_BYTES, WorkbenchR2Limits.BRIDGE_REQUEST_BYTES)
        assertEquals(CreativeLimits.RESPONSE_BYTES, WorkbenchR2Limits.BRIDGE_RESPONSE_BYTES)
        assertEquals(CreativeLimits.CANVAS_PROJECT_BYTES, WorkbenchR2Limits.CANVAS_JSON_BYTES)
        assertEquals(CreativeLimits.MEDIA_PROJECT_BYTES, WorkbenchR2Limits.MEDIA_JSON_BYTES)
        assertEquals(CreativeLimits.MEDIA_COMMANDS, WorkbenchR2Limits.VIDEO_COMMANDS_PER_APPLY)
        assertTrue(WorkbenchR2Limits.RENDER_DESCRIPTOR_BYTES < WorkbenchR2Limits.RENDER_REPLY_BYTES)
        assertTrue(WorkbenchR2Limits.IMAGE_SOURCE_BYTES.toLong() < WorkbenchR2Limits.IMPORT_IMAGE_BYTES)
        assertEquals(2, WorkbenchR2Limits.MAX_LIVE_RENDER_TICKETS)
        assertTrue(WorkbenchR2Errors.ALL.contains(WorkbenchR2Errors.UNSUPPORTED_CODEC))
        assertTrue(WorkbenchR2Errors.ALL.contains(WorkbenchR2Errors.UNSUPPORTED_TRANSITION))
        assertTrue(WorkbenchR2Errors.ALL.contains(WorkbenchR2Errors.UNSUPPORTED_SOURCE_FORMAT))
        assertEquals(20, WorkbenchR2Errors.ALL.size)
    }

    @Test
    fun `large import policy is per kind and preflights two copies plus headroom`() {
        assertTrue(LargeImportPolicy.accepts(LargeImportKind.IMAGE, WorkbenchR2Limits.IMPORT_IMAGE_BYTES))
        assertFalse(LargeImportPolicy.accepts(
            LargeImportKind.IMAGE, WorkbenchR2Limits.IMPORT_IMAGE_BYTES + 1))
        assertTrue(LargeImportPolicy.accepts(LargeImportKind.AUDIO, WorkbenchR2Limits.IMPORT_AUDIO_BYTES))
        assertTrue(LargeImportPolicy.accepts(LargeImportKind.VIDEO, WorkbenchR2Limits.IMPORT_VIDEO_BYTES))
        assertFalse(LargeImportPolicy.accepts(LargeImportKind.VIDEO, 0))

        val source = 1024L * 1024L
        assertEquals(
            source * LargeImportPolicy.DUPLICATION_FACTOR +
                WorkbenchR2Limits.IMPORT_DISK_HEADROOM_BYTES,
            LargeImportPolicy.requiredFreeBytes(source))
        assertEquals(Long.MAX_VALUE, LargeImportPolicy.requiredFreeBytes(Long.MAX_VALUE))
        assertEquals(0L, LargeImportPolicy.requiredFreeBytes(0L))
        assertEquals(
            WorkbenchR2Limits.IMPORT_VIDEO_BYTES,
            LargeImportPolicy.rule(LargeImportKind.VIDEO).maxBytes)
    }

    @Test
    fun `export binding fixes an immutable revision and trusted root`() {
        val value = binding()
        assertEquals(4L, value.projectRevision)
        assertEquals("digest", value.timelineDigest)
        assertEquals("attempt-1", value.attemptID)
        assertTrue(value.mediaRootPath.startsWith("/"))
        assertEquals("lease-1", value.snapshot.leaseID)
        assertEquals("/trusted/root", value.snapshot.mediaRootPath)
        assertEquals("Snapshots/p4.json", value.snapshot.relativePath)
        assertEquals(4096L, value.snapshot.byteCount)

        val receipt = MediaExportReceipt(
            binding = MediaExportReceiptBinding(
                projectID = value.context.projectID,
                mediaRootPath = value.mediaRootPath,
                projectRevision = value.projectRevision,
                timelineDigest = value.timelineDigest,
                attemptID = value.attemptID,
            ),
            kind = MediaExportKind.VIDEO,
            outputRelativePath = "Workbench/Exports/attempt-1.mp4",
            mimeType = "video/mp4",
            byteCount = 10,
            sha256 = "b".repeat(64),
            verification = ExportVerification(
                playable = true,
                decodedDurationSeconds = 1.5,
                width = 1920,
                height = 1080,
                audioTrackCount = 1,
                container = "mp4",
                codec = "video/avc",
            ),
            completedAt = "2026-11-01T00:00:00Z",
        )
        assertTrue(receipt.verification.playable)
        assertEquals(1, receipt.verification.audioTrackCount)
        assertEquals(MediaExportState.COMPLETED.wire, "completed")
        assertFalse(receipt.outputRelativePath.startsWith("/"))
    }

    @Test
    fun `render ticket descriptor is bounded and carries a snapshot lease`() {
        val descriptor = RenderTicketDescriptor(
            ticketID = "t1",
            descriptorVersion = 1,
            kind = MediaExportKind.VIDEO,
            projectID = "p1",
            attemptID = "attempt-1",
            mediaRootPath = "/trusted/root",
            storage = CreativeStorageLayer.AppOwned,
            origin = CreativeOriginContext.standalone(),
            projectRevision = 4,
            timelineDigest = "digest",
            leaseID = "lease-1",
            ownerReference = "owner-1",
            epoch = 9,
            snapshotRelativePath = "Snapshots/p4.json",
            snapshotSHA256 = "c".repeat(64),
            snapshotByteCount = 4096,
            snapshotLeaseExpiresAt = "2026-11-01T01:00:00Z",
            outputRelativePath = "Workbench/Exports/t1.mp4",
            videoSettings = VideoExportSettings(
                codecMime = "video/avc",
                width = 1920,
                height = 1080,
                frameRate = 30.0,
                quality = 0.9,
                fileName = "t1",
            ),
            expiresAt = "2026-11-01T01:00:00Z",
            descriptorByteCount = 512,
        )
        assertTrue(descriptor.descriptorByteCount <= WorkbenchR2Limits.RENDER_DESCRIPTOR_BYTES)
        assertEquals("Snapshots/p4.json", descriptor.snapshotRelativePath)
        assertEquals("/trusted/root", descriptor.mediaRootPath)
        assertEquals("attempt-1", descriptor.attemptID)
        assertTrue(descriptor.storage is CreativeStorageLayer.AppOwned)
        assertEquals("2026-11-01T01:00:00Z", descriptor.snapshotLeaseExpiresAt)
        assertTrue(descriptor.leaseID.isNotEmpty())
        val claimed = ClaimedRenderTicket(
            descriptor = descriptor,
            claimToken = "claim-1",
            claimedAt = "2026-11-01T00:00:00Z",
            leaseExpiresAt = "2026-11-01T01:00:00Z",
        )
        assertEquals("claim-1", claimed.claimToken)
        assertEquals(
            WorkbenchR2Limits.MAX_LIVE_RENDER_TICKETS,
            RenderTicketStats(live = 0, claimed = 0, completed = 0,
                cancelled = 0, failed = 0).maxLive)
        assertEquals(5, RenderTicketReplyStatus.entries.size)
    }

    @Test
    fun `tool export has only a real renderer route or an honest unavailable route`() {
        val available = MediaProjectToolExportCapability(
            route = MediaProjectToolExportRoute.RENDER_TICKET,
            registered = false,
            reason = "registration is deferred until the native bridge is real",
            supportedActions = setOf("read", "propose", "apply", "export"),
        )
        assertEquals("renderTicket", available.route.wire)
        assertFalse(available.registered)
        val unavailable = MediaProjectToolExportCapability(
            route = MediaProjectToolExportRoute.UNAVAILABLE,
            reason = "no renderer connected",
        )
        assertEquals("unavailable", unavailable.route.wire)
        assertEquals(
            setOf("read", "propose", "apply", "export"),
            available.supportedActions)
    }

    @Test
    fun `staged import metadata carries token digest and per kind bounds`() {
        val metadata = StagedImportMetadata(
            token = "stage-1",
            kind = LargeImportKind.VIDEO,
            fileName = "clip.mp4",
            mimeType = "video/mp4",
            byteCount = 1024,
            sha256 = "d".repeat(64),
        )
        val validation = StagedImportValidation(
            accepted = true,
            requiredFreeBytes = LargeImportPolicy.requiredFreeBytes(metadata.byteCount),
            maxBytes = LargeImportPolicy.rule(metadata.kind).maxBytes,
        )
        assertTrue(validation.accepted)
        assertEquals(WorkbenchR2Limits.IMPORT_VIDEO_BYTES, validation.maxBytes)
        assertEquals("video", metadata.kind.wire)

        val newProject = LargeImportRequest.NewProject(
            storage = CreativeStorageLayer.AppOwned,
            origin = CreativeOriginContext.standalone(),
            name = "Clip",
            kind = NewMediaProjectKind.VIDEO,
            sessionToken = "s1",
            opID = "op-1",
            metadata = metadata.copy(mediaMetadata = MediaAssetMetadata(width = 1920, height = 1080)),
            preparedIntentToken = null,
        )
        assertEquals("video", newProject.kind.wire)
        assertEquals("op-1", newProject.opID)
        assertNull(newProject.preparedIntentToken)
        assertTrue(newProject.storage is CreativeStorageLayer.AppOwned)

        val pending = LargeImportStatus(
            jobID = "job-1", state = LargeImportState.STAGING,
            updatedAt = "2026-11-01T00:00:00Z", progress = 0.25,
        )
        assertNull(pending.createdProjectID)
        assertNull(pending.asset)
        assertEquals("staging", pending.state.wire)
    }
}
