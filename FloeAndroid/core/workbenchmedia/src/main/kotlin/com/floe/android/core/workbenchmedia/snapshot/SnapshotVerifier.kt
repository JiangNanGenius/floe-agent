// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.snapshot

import com.floe.android.core.workbenchmedia.AuthorityGrant
import com.floe.android.core.workbenchmedia.util.Digests
import com.floe.android.core.workbenchmedia.util.MediaClock
import com.floe.android.core.workbenchmedia.util.MediaPaths
import com.floe.android.core.workbenchmedia.util.RENDER_UNSUPPORTED
import com.floe.android.core.workbenchmedia.util.RENDER_TICKET_EXPIRED
import com.floe.android.core.workbenchmedia.util.isExpired
import com.floe.android.core.workbenchmedia.util.refusal
import com.floe.android.feature.workbench.RenderSnapshotLease
import com.floe.android.feature.workbench.RenderTicketDescriptor
import com.floe.android.feature.workbench.WorkbenchR2Limits
import java.io.File
import java.nio.charset.StandardCharsets

internal data class SnapshotExpectation(
    val epoch: Long,
    val projectID: String,
    val revision: Long,
    val timelineDigest: String,
    val mediaRootPath: String,
    val attemptID: String,
    val lease: RenderSnapshotLease,
)

internal data class VerifiedSnapshot(
    val root: File,
    val file: File,
    val lease: RenderSnapshotLease,
    val projection: SnapshotProjection,
)

/**
 * Proves the EXACT native-issued snapshot bytes before any decoder sees them:
 * lease liveness/expiry, canonical trusted root, relative containment, size,
 * SHA-256, schema-1 parse, project/revision binding and the native authority
 * grant. A project JSON path recorded inside the document is never used as a
 * file or root grant.
 */
internal object SnapshotVerifier {
    fun verify(
        expected: SnapshotExpectation,
        grant: AuthorityGrant,
        clock: MediaClock,
    ): VerifiedSnapshot {
        if (grant.epoch != expected.epoch) {
            throw refusal(RENDER_UNSUPPORTED, "Snapshot lease belongs to a different epoch")
        }
        if (grant.projectID != null && grant.projectID != expected.projectID) {
            throw refusal(RENDER_UNSUPPORTED, "Snapshot grant project does not match the request")
        }
        if (grant.revision != null && grant.revision != expected.revision) {
            throw refusal(RENDER_UNSUPPORTED, "Snapshot grant revision does not match the request")
        }
        if (grant.timelineDigest != null && grant.timelineDigest != expected.timelineDigest) {
            throw refusal(RENDER_UNSUPPORTED, "Snapshot timeline digest does not match the request")
        }
        val root = MediaPaths.canonicalRoot(expected.mediaRootPath)
            ?: throw refusal(RENDER_UNSUPPORTED, "The native media root is not an existing directory")
        val grantRoot = MediaPaths.canonicalRoot(grant.mediaRootPath)
            ?: throw refusal(RENDER_UNSUPPORTED, "The authority grant root is not an existing directory")
        if (grantRoot.path != root.path) {
            throw refusal(RENDER_UNSUPPORTED, "The authority grant root differs from the binding root")
        }
        val leaseRoot = MediaPaths.canonicalRoot(expected.lease.mediaRootPath)
            ?: throw refusal(RENDER_UNSUPPORTED, "The snapshot lease root is not an existing directory")
        if (leaseRoot.path != root.path) {
            throw refusal(RENDER_UNSUPPORTED, "The snapshot lease root differs from the binding root")
        }
        if (isExpired(expected.lease.expiresAt, clock)) {
            throw refusal(RENDER_TICKET_EXPIRED, "The native snapshot lease has expired", retryable = true)
        }
        if (expected.lease.byteCount <= 0L || expected.lease.byteCount > WorkbenchR2Limits.MEDIA_JSON_BYTES) {
            throw refusal(RENDER_UNSUPPORTED, "Snapshot size is outside the 8 MiB project snapshot bound")
        }
        if (!Digests.isSha256(expected.lease.sha256)) {
            throw refusal(RENDER_UNSUPPORTED, "Snapshot digest is not a lowercase SHA-256")
        }
        val file = MediaPaths.resolveExistingUnder(root, expected.lease.relativePath)
            ?: throw refusal(RENDER_UNSUPPORTED, "Snapshot path is not a regular contained file")
        if (file.length() != expected.lease.byteCount) {
            throw refusal(RENDER_UNSUPPORTED, "Snapshot byte count changed after the lease was issued")
        }
        val bytes = try {
            file.readBytes()
        } catch (failure: Exception) {
            throw refusal(RENDER_UNSUPPORTED, "Snapshot could not be read: ${failure.message}")
        }
        if (bytes.size.toLong() != expected.lease.byteCount) {
            throw refusal(RENDER_UNSUPPORTED, "Snapshot size changed while reading")
        }
        val actual = Digests.sha256(bytes)
        if (!actual.equals(expected.lease.sha256, ignoreCase = false)) {
            throw refusal(RENDER_UNSUPPORTED, "Snapshot SHA-256 does not match the native lease")
        }
        val text = try {
            String(bytes, StandardCharsets.UTF_8)
        } catch (failure: Exception) {
            throw refusal(RENDER_UNSUPPORTED, "Snapshot is not valid UTF-8")
        }
        val projection = ProjectSnapshotParser.parse(text)
        if (projection.project.id != expected.projectID) {
            throw refusal(RENDER_UNSUPPORTED, "Snapshot project id does not match the accepted project")
        }
        if (projection.project.revision != expected.revision) {
            throw refusal(RENDER_UNSUPPORTED, "Snapshot revision does not match the accepted revision")
        }
        return VerifiedSnapshot(root, file, expected.lease, projection)
    }

    fun expectationForDescriptor(descriptor: RenderTicketDescriptor): SnapshotExpectation =
        SnapshotExpectation(
            epoch = descriptor.epoch,
            projectID = descriptor.projectID,
            revision = descriptor.projectRevision,
            timelineDigest = descriptor.timelineDigest,
            mediaRootPath = descriptor.mediaRootPath,
            attemptID = descriptor.attemptID,
            lease = RenderSnapshotLease(
                leaseID = descriptor.leaseID,
                mediaRootPath = descriptor.mediaRootPath,
                relativePath = descriptor.snapshotRelativePath,
                sha256 = descriptor.snapshotSHA256,
                byteCount = descriptor.snapshotByteCount,
                expiresAt = descriptor.snapshotLeaseExpiresAt,
            ),
        )
}
