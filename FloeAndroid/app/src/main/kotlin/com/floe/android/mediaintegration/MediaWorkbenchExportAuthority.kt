// SPDX-License-Identifier: MPL-2.0
package com.floe.android.mediaintegration

import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.MediaExportReceipt
import com.floe.android.feature.workbench.MediaExportStatus
import java.io.File
import java.util.Locale

/**
 * Full identity of one VERIFIED export receipt.
 *
 * This is the only key under which the App retains a Save/Share
 * re-authorization. The output path is an identity here, never write
 * authority; the exact project root still comes from a live native
 * `resolveProjectMediaRoot(context)` re-proof.
 *
 * Two receipts that share only a project/attempt are DIFFERENT entries; the
 * registry therefore cannot accept a different output path, hash or size for
 * an attempt it already knows.
 */
internal data class MediaWorkbenchReceiptIdentity(
    val projectID: String,
    val mediaRootPath: String,
    val projectRevision: Long,
    val timelineDigest: String,
    val attemptID: String,
    val outputRelativePath: String,
    val mimeType: String,
    val byteCount: Long,
    val sha256: String,
) {
    companion object {
        private val ATTEMPT = Regex("[A-Za-z0-9._-]{1,64}")

        /** Strict receipt-shape validation; null is a typed `invalidReceipt`. */
        fun of(receipt: MediaExportReceipt): MediaWorkbenchReceiptIdentity? {
            val binding = receipt.binding
            if (binding.projectID.isBlank() || binding.projectID.length > 200) return null
            if (binding.mediaRootPath.isBlank() || binding.mediaRootPath.length > 4096 ||
                !binding.mediaRootPath.startsWith("/")
            ) {
                return null
            }
            if (binding.projectRevision < 0L) return null
            if (binding.timelineDigest.isBlank() || binding.timelineDigest.length > 256 ||
                binding.timelineDigest.any { it.code < 0x20 }
            ) {
                return null
            }
            if (!ATTEMPT.matches(binding.attemptID)) return null
            if (!MediaWorkbenchExportProof.isSafeRelativePath(receipt.outputRelativePath)) return null
            val mime = receipt.mimeType
            if (mime.isBlank() || mime.length > 128 || mime.contains('*') ||
                mime.count { it == '/' } != 1
            ) {
                return null
            }
            if (receipt.byteCount !in 1L..MediaWorkbenchExportProof.MAX_BYTES) return null
            if (!MediaWorkbenchExportProof.isSha256Hex(receipt.sha256)) return null
            return MediaWorkbenchReceiptIdentity(
                projectID = binding.projectID,
                mediaRootPath = binding.mediaRootPath,
                projectRevision = binding.projectRevision,
                timelineDigest = binding.timelineDigest,
                attemptID = binding.attemptID,
                outputRelativePath = receipt.outputRelativePath,
                mimeType = mime,
                byteCount = receipt.byteCount,
                sha256 = receipt.sha256.lowercase(Locale.ROOT),
            )
        }
    }
}

/**
 * Exact owner captured at the moment the App itself prepared a binding or
 * received a verified status/list entry for the CURRENT editor context.
 *
 * `canonicalRootPath` is a native-resolved per-project root, never the
 * accepted base ancestor and never a receipt/recorded path.
 */
internal data class MediaWorkbenchCapturedOwner(
    val context: CreativeProjectContext,
    val epoch: Long,
    val projectID: String,
    val canonicalRootPath: String,
    val ownerProof: String,
    val storageKey: String,
    val originKey: String?,
    val storage: CreativeStorageLayer,
)

/** Live native echo re-resolved immediately before a Save/Share is admitted. */
internal data class MediaWorkbenchResolvedOwner(
    val epoch: Long,
    val mediaRootPath: String,
    val projectID: String,
    val ownerProof: String,
    val storageKey: String,
    val originKey: String?,
    val storage: CreativeStorageLayer,
)

internal sealed interface MediaWorkbenchOwnerDecision {
    data class Granted(
        val canonicalRoot: File,
        val ownerProof: String,
    ) : MediaWorkbenchOwnerDecision

    data class Refused(val code: String) : MediaWorkbenchOwnerDecision
}

/**
 * Pure authorization rule for one Save/Share.
 *
 * It accepts ONLY an exact previously captured owner plus a live native echo
 * of the same epoch/project/root/storage/origin/durable owner proof. The
 * receipt root is compared for identity equality only; it can never widen the
 * root. Missing/stale/foreign ownership is refused, never retried against the
 * accepted base ancestor.
 */
internal object MediaWorkbenchExportAuthorization {
    fun authorize(
        identity: MediaWorkbenchReceiptIdentity,
        captured: MediaWorkbenchCapturedOwner?,
        resolved: MediaWorkbenchResolvedOwner,
        epochLive: Boolean,
    ): MediaWorkbenchOwnerDecision {
        val owner = captured
            ?: return MediaWorkbenchOwnerDecision.Refused("exportOwnerUnverified")
        if (identity.projectID != owner.projectID) {
            return MediaWorkbenchOwnerDecision.Refused("crossOwnerRefused")
        }
        if (!epochLive || resolved.epoch <= 0L || resolved.epoch != owner.epoch) {
            return MediaWorkbenchOwnerDecision.Refused("staleGeneration")
        }
        if (resolved.projectID != owner.projectID ||
            resolved.projectID != identity.projectID
        ) {
            return MediaWorkbenchOwnerDecision.Refused("crossOwnerRefused")
        }
        if (resolved.ownerProof.isBlank() ||
            resolved.ownerProof != owner.ownerProof
        ) {
            return MediaWorkbenchOwnerDecision.Refused("crossOwnerRefused")
        }
        if (resolved.storageKey.isBlank() ||
            resolved.storageKey != owner.storageKey
        ) {
            return MediaWorkbenchOwnerDecision.Refused("crossOwnerRefused")
        }
        if (!sameNullable(resolved.originKey, owner.originKey)) {
            return MediaWorkbenchOwnerDecision.Refused("crossOwnerRefused")
        }
        if (resolved.storage != owner.storage || owner.storage != owner.context.storage) {
            return MediaWorkbenchOwnerDecision.Refused("crossOwnerRefused")
        }
        val resolvedRoot = canonicalPath(resolved.mediaRootPath)
            ?: return MediaWorkbenchOwnerDecision.Refused("exportRootRefused")
        if (resolvedRoot != owner.canonicalRootPath) {
            return MediaWorkbenchOwnerDecision.Refused("crossOwnerRefused")
        }
        val identityRoot = canonicalPath(identity.mediaRootPath)
            ?: return MediaWorkbenchOwnerDecision.Refused("exportRootRefused")
        if (identityRoot != resolvedRoot) {
            return MediaWorkbenchOwnerDecision.Refused("crossOwnerRefused")
        }
        return MediaWorkbenchOwnerDecision.Granted(
            canonicalRoot = File(resolvedRoot),
            ownerProof = owner.ownerProof,
        )
    }

    fun canonicalPath(path: String): String? {
        if (path.isBlank() || !path.startsWith("/") || path.length > 4096) return null
        return runCatching { File(path).canonicalFile.path }.getOrNull()
    }

    private fun sameNullable(left: String?, right: String?): Boolean =
        (left ?: "") == (right ?: "")
}

/**
 * Bounded transient map full-receipt-identity -> exact captured owner.
 *
 * The SAME durable owner refreshed by a reopened editor context replaces the
 * older session, but a receipt identity carrying a foreign owner proof never
 * overwrites a recorded entry.
 */
internal class MediaWorkbenchReceiptRegistry(
    private val maxEntries: Int = 64,
) {
    private val entries =
        object : LinkedHashMap<MediaWorkbenchReceiptIdentity, MediaWorkbenchCapturedOwner>(
            16, 0.75f, true) {
            override fun removeEldestEntry(
                eldest: MutableMap.MutableEntry<
                    MediaWorkbenchReceiptIdentity, MediaWorkbenchCapturedOwner>?,
            ): Boolean = size > maxEntries
        }

    fun remember(
        identity: MediaWorkbenchReceiptIdentity,
        owner: MediaWorkbenchCapturedOwner,
    ) {
        synchronized(entries) {
            val existing = entries[identity]
            if (existing == null || sameOwner(existing, owner)) {
                entries[identity] = owner
            }
        }
    }

    fun lookup(identity: MediaWorkbenchReceiptIdentity): MediaWorkbenchCapturedOwner? =
        synchronized(entries) { entries[identity] }

    fun clear() {
        synchronized(entries) { entries.clear() }
    }

    fun size(): Int = synchronized(entries) { entries.size }

    private fun sameOwner(
        left: MediaWorkbenchCapturedOwner,
        right: MediaWorkbenchCapturedOwner,
    ): Boolean =
        left.projectID == right.projectID &&
            left.ownerProof == right.ownerProof &&
            left.storageKey == right.storageKey &&
            (left.originKey ?: "") == (right.originKey ?: "") &&
            left.canonicalRootPath == right.canonicalRootPath
}

/**
 * Captured immutable binding from `prepareRenderBinding`.
 *
 * It is not write authority and not a receipt by itself: it only lets a
 * verified status/observe reply be matched to the exact prepared attempt and
 * supplied with the owner proof captured while that editor was live.
 */
internal data class MediaWorkbenchPreparedCapture(
    val owner: MediaWorkbenchCapturedOwner,
    val projectRevision: Long,
    val timelineDigest: String,
    val attemptID: String,
) {
    fun matches(identity: MediaWorkbenchReceiptIdentity): Boolean =
        identity.attemptID == attemptID &&
            identity.projectID == owner.projectID &&
            identity.projectRevision == projectRevision &&
            identity.timelineDigest == timelineDigest &&
            MediaWorkbenchExportAuthorization.canonicalPath(identity.mediaRootPath) ==
            owner.canonicalRootPath
}

internal class MediaWorkbenchPreparedRegistry(
    private val maxEntries: Int = 32,
) {
    private val entries =
        object : LinkedHashMap<String, MediaWorkbenchPreparedCapture>(16, 0.75f, true) {
            override fun removeEldestEntry(
                eldest: MutableMap.MutableEntry<String, MediaWorkbenchPreparedCapture>?,
            ): Boolean = size > maxEntries
        }

    fun remember(capture: MediaWorkbenchPreparedCapture) {
        synchronized(entries) { entries[capture.attemptID] = capture }
    }

    fun lookup(attemptID: String): MediaWorkbenchPreparedCapture? =
        synchronized(entries) { entries[attemptID] }

    fun clear() {
        synchronized(entries) { entries.clear() }
    }

    fun size(): Int = synchronized(entries) { entries.size }
}

/**
 * Narrow bridge from the App platform facade/listing into the delivery's
 * bounded captured-authority maps. The facade is the only caller for status
 * and observe; the host lister is the only caller for recovery lists.
 */
internal interface MediaWorkbenchReceiptRecorder {
    suspend fun recordVerifiedStatus(
        context: CreativeProjectContext,
        status: MediaExportStatus,
    )

    fun recordObservedStatus(
        context: CreativeProjectContext,
        status: MediaExportStatus,
    )
}
