// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.gallery

import com.floe.android.core.workbenchmedia.AuthorityDecision
import com.floe.android.core.workbenchmedia.gallery.AndroidMediaGallerySaver
import com.floe.android.core.workbenchmedia.gallery.GalleryArtifactAuthority
import com.floe.android.core.workbenchmedia.gallery.GalleryArtifactDecision
import com.floe.android.core.workbenchmedia.gallery.GalleryArtifactGrant
import com.floe.android.core.workbenchmedia.gallery.GalleryCollection
import com.floe.android.core.workbenchmedia.gallery.GallerySaveOptions
import com.floe.android.core.workbenchmedia.gallery.GallerySaveResult
import com.floe.android.core.workbenchmedia.image.C03LayerRasterMode
import com.floe.android.core.workbenchmedia.image.C03LayerRasterRequest
import com.floe.android.core.workbenchmedia.image.C03LayerRasterService
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.MediaExportReceipt
import com.floe.android.feature.workbench.ui.api.MediaGalleryCollection
import com.floe.android.feature.workbench.ui.api.MediaGallerySaveOutcome
import com.floe.android.feature.workbench.ui.api.MediaGallerySavePort
import com.floe.android.feature.workbench.ui.api.MediaLayerRasterPort
import com.floe.android.feature.workbench.ui.api.MediaLayerRasterReceipt
import com.floe.android.feature.workbench.ui.api.MediaLayerRasterRequest
import com.floe.android.host.creative.CreativeHostController
import com.floe.android.mediaintegration.MediaWorkbenchLeaseAuthority
import com.floe.android.mediaintegration.toExportBinding
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Application-owned C03 layer raster bridge.
 *
 * The exact project snapshot is prepared by the SAME native authority used by
 * preview/export, re-validated through the same lease authority, rendered by
 * the shared layer renderer, and the native lease is released only after the
 * renderer/file IO has stopped. No caller path, asset id or synthetic hash is
 * accepted.
 */
internal class MediaLayerRasterController(
    private val hostProvider: () -> CreativeHostController,
) : MediaLayerRasterPort {
    override suspend fun renderLayerRaster(
        context: CreativeProjectContext,
        expectedRevision: Long,
        mode: String,
        request: MediaLayerRasterRequest,
    ): MediaLayerRasterReceipt = withContext(Dispatchers.IO) {
        val modeValue = when (mode) {
            "merge" -> C03LayerRasterMode.MERGE
            "copySelection" -> C03LayerRasterMode.COPY_SELECTION
            else -> throw CreativeException("invalidRequest", "invalidLayerRasterMode")
        }
        val authority = hostProvider().r2Authority
        val attemptID = "layer-${UUID.randomUUID()}"
        val prepared = authority.prepareRenderBinding(context, expectedRevision, attemptID)
        val binding = prepared.toExportBinding()
        try {
            val decision = MediaWorkbenchLeaseAuthority(hostProvider)
                .validateRenderBinding(binding)
            val grant = when (decision) {
                is AuthorityDecision.Accepted -> decision.grant
                is AuthorityDecision.Refused -> throw CreativeException(
                    decision.code,
                    decision.reason,
                    decision.retryable,
                )
            }
            val receipt = C03LayerRasterService.render(
                C03LayerRasterRequest(
                    binding = binding,
                    mode = modeValue,
                    layerIDs = request.layerIDs,
                    selection = request.selection,
                    name = request.name ?: if (modeValue == C03LayerRasterMode.MERGE) {
                        "merged"
                    } else {
                        "selection-copy"
                    },
                ),
                grant,
            )
            MediaLayerRasterReceipt(
                assetID = receipt.asset.id,
                relativePath = receipt.asset.relativePath,
                originalName = receipt.asset.originalName,
                byteCount = receipt.asset.byteCount,
                sha256 = receipt.asset.contentHash,
                width = receipt.asset.metadata.width,
                height = receipt.asset.metadata.height,
                projectID = receipt.projectID,
                projectRevision = receipt.projectRevision,
            )
        } finally {
            // The renderer has stopped before this point, so the native lease
            // may be released. A late release failure is not allowed to turn a
            // real verified raster into a fake failure; the lease remains
            // bounded and owned by native until expiry.
            runCatching { hostProvider().r2Snapshots.release(prepared.snapshot) }
        }
    }
}

/**
 * Application-owned gallery save + owner re-proof.
 *
 * The live native root proof is the only root authority. A receipt is accepted
 * only when its project id, canonical media root and exact verified bytes agree
 * with the current editor's native owner grant; the saver then performs the
 * ContentResolver/MediaStore write and readback.
 */
internal class MediaGallerySaveController(
    context: android.content.Context,
    private val hostProvider: () -> CreativeHostController,
) : MediaGallerySavePort, GalleryArtifactAuthority {
    private val saver = AndroidMediaGallerySaver(context, this)

    override suspend fun saveToGallery(
        context: CreativeProjectContext,
        receipt: MediaExportReceipt,
        collection: MediaGalleryCollection,
    ): MediaGallerySaveOutcome = withContext(Dispatchers.IO) {
        var result = saver.save(
            receipt = receipt,
            context = context,
            options = GallerySaveOptions(
                collection = when (collection) {
                    MediaGalleryCollection.IMAGE -> GalleryCollection.IMAGE
                    MediaGalleryCollection.VIDEO -> GalleryCollection.VIDEO
                },
            ),
        )
        // API 28 only: the user's explicit Save action triggers the one real
        // OS permission request; the Activity owns the launcher (Main patch).
        // API 29+ own-media insertion never reaches this branch.
        if (result is GallerySaveResult.PermissionRequired) {
            val granted = GalleryPermissionRequester.request()
            if (granted == true) {
                result = saver.save(
                    receipt = receipt,
                    context = context,
                    options = GallerySaveOptions(
                        collection = when (collection) {
                            MediaGalleryCollection.IMAGE -> GalleryCollection.IMAGE
                            MediaGalleryCollection.VIDEO -> GalleryCollection.VIDEO
                        },
                    ),
                )
            }
        }
        when (result) {
            is GallerySaveResult.Saved -> MediaGallerySaveOutcome.Saved(
                contentURI = result.receipt.contentURI,
                displayName = result.receipt.displayName,
                byteCount = result.receipt.byteCount,
                sha256 = result.receipt.sha256,
                readbackSha256 = result.receipt.readbackSha256,
            )
            is GallerySaveResult.PermissionRequired -> MediaGallerySaveOutcome.PermissionRequired(
                result.permission)
            is GallerySaveResult.Failed -> MediaGallerySaveOutcome.Failed(
                code = result.code,
                retryable = result.retryable,
                pendingCleaned = result.pendingCleaned,
            )
        }
    }

    override suspend fun authorize(
        receipt: MediaExportReceipt,
        context: CreativeProjectContext,
    ): GalleryArtifactDecision {
        val authority = hostProvider().r2Authority
        val resolved = try {
            authority.resolveProjectMediaRoot(context)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: CreativeException) {
            return GalleryArtifactDecision.Refused(
                error.code,
                error.reason ?: "The project media root could not be verified",
                error.retryable,
            )
        } catch (_: Throwable) {
            return GalleryArtifactDecision.Refused(
                "galleryAuthorityUnavailable",
                "The project media root could not be verified",
                retryable = true,
            )
        }
        if (resolved.epoch <= 0L || !authority.isEpochLive(resolved.epoch)) {
            return GalleryArtifactDecision.Refused("staleGeneration", "The project root is no longer live")
        }
        if (resolved.projectID != receipt.binding.projectID ||
            resolved.projectID != context.projectID
        ) {
            return GalleryArtifactDecision.Refused("galleryOwnerMismatch", "The export belongs to another project")
        }
        val receiptRoot = runCatching {
            java.io.File(receipt.binding.mediaRootPath).canonicalFile.path
        }.getOrNull()
        val liveRoot = runCatching {
            java.io.File(resolved.mediaRootPath).canonicalFile.path
        }.getOrNull()
        if (receiptRoot == null || liveRoot == null || receiptRoot != liveRoot) {
            return GalleryArtifactDecision.Refused("galleryOwnerMismatch", "The export root is not the live project root")
        }
        if (resolved.ownerProof.isBlank()) {
            return GalleryArtifactDecision.Refused("galleryOwnerMismatch", "The project owner proof is unavailable")
        }
        return GalleryArtifactDecision.Granted(
            GalleryArtifactGrant(
                canonicalRootPath = liveRoot,
                projectID = resolved.projectID,
                ownerProof = resolved.ownerProof,
            ),
        )
    }
}
