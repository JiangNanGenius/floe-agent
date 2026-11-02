// SPDX-License-Identifier: MPL-2.0
package com.floe.android.mediaintegration

import com.floe.android.core.workbenchmedia.AuthorityDecision
import com.floe.android.core.workbenchmedia.RecoveryRootDecision
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.RenderSnapshotLease
import com.floe.android.host.creative.R2AuthorityDecision
import com.floe.android.host.creative.R2AuthorityGrant
import com.floe.android.host.creative.R2PreparedRenderBinding
import com.floe.android.host.creative.R2ProjectMediaRoot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaWorkbenchAuthorityMappingTest {
    private val context = CreativeProjectContext(
        projectID = "project-1",
        sessionToken = "session-1",
        storage = CreativeStorageLayer.AppOwned,
        origin = CreativeOriginContext.standalone(),
    )

    private val lease = RenderSnapshotLease(
        leaseID = "lease-1",
        mediaRootPath = "/root/projects/project-1",
        relativePath = "Workbench/Snapshots/lease-1.json",
        sha256 = "a".repeat(64),
        byteCount = 1024,
        expiresAt = "2026-11-01T00:00:00Z",
    )

    @Test
    fun preparedBindingRoundTripsWithoutDerivingAnything() {
        val prepared = R2PreparedRenderBinding(
            context = context,
            mediaRootPath = lease.mediaRootPath,
            projectRevision = 7,
            timelineDigest = "digest-1",
            attemptID = "export-1",
            snapshot = lease,
        )
        val binding = prepared.toExportBinding()
        assertEquals(prepared.context, binding.context)
        assertEquals(prepared.mediaRootPath, binding.mediaRootPath)
        assertEquals(prepared.projectRevision, binding.projectRevision)
        assertEquals(prepared.timelineDigest, binding.timelineDigest)
        assertEquals(prepared.attemptID, binding.attemptID)
        assertEquals(prepared.snapshot, binding.snapshot)
        assertEquals(prepared, binding.toPrepared())
    }

    @Test
    fun recoveryUsesStableOwnerProofAndPerProjectRoot() {
        val grant = R2ProjectMediaRoot(
            epoch = 42,
            mediaRootPath = "/root/projects/project-1",
            projectID = "project-1",
            revision = 9,
            timelineDigest = "digest-9",
            storage = CreativeStorageLayer.AppOwned,
            ownerKind = "standalone",
            ownerID = null,
            ownerProof = "durable-owner-proof",
            storageKey = "appOwned",
            originKey = "standalone",
            writable = true,
        ).toPlatformGrant()
        assertTrue(grant is RecoveryRootDecision.Accepted)
        val accepted = grant as RecoveryRootDecision.Accepted
        assertEquals(42, accepted.grant.epoch)
        assertEquals("/root/projects/project-1", accepted.grant.mediaRootPath)
        assertEquals("durable-owner-proof", accepted.grant.ownerKey)
        assertEquals("appOwned", accepted.grant.storageKey)
        assertEquals("standalone", accepted.grant.originKey)
    }

    @Test
    fun incompleteRecoveryGrantIsRefusedNotEchoed() {
        val refused = R2ProjectMediaRoot(
            epoch = 0,
            mediaRootPath = "/root",
            projectID = "project-1",
            revision = 1,
            timelineDigest = "digest",
            storage = CreativeStorageLayer.AppOwned,
            ownerKind = "standalone",
            ownerID = null,
            ownerProof = "",
            storageKey = "",
            originKey = null,
            writable = true,
        ).toPlatformGrant()
        assertTrue(refused is RecoveryRootDecision.Refused)
    }

    @Test
    fun authorityRefusalKeepsTypedCode() {
        val refused = R2AuthorityDecision(
            accepted = false,
            grant = null,
            code = "staleSession",
            reason = "sessionNotLive",
            retryable = true,
        ).toPlatform()
        assertTrue(refused is AuthorityDecision.Refused)
        val value = refused as AuthorityDecision.Refused
        assertEquals("staleSession", value.code)
        assertEquals("sessionNotLive", value.reason)
        assertTrue(value.retryable)

        val accepted = R2AuthorityDecision(
            accepted = true,
            grant = R2AuthorityGrant(
                epoch = 3,
                mediaRootPath = "/root/projects/project-1",
                projectID = "project-1",
                revision = 4,
                timelineDigest = "digest-4",
            ),
        ).toPlatform()
        assertTrue(accepted is AuthorityDecision.Accepted)
        assertEquals(4L, (accepted as AuthorityDecision.Accepted).grant.revision)
    }
}
