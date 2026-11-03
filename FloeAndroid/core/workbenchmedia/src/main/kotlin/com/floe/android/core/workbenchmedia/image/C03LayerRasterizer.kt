// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.image

import android.graphics.Bitmap
import com.floe.android.core.workbenchmedia.AuthorityGrant
import com.floe.android.core.workbenchmedia.snapshot.SnapshotExpectation
import com.floe.android.core.workbenchmedia.snapshot.SnapshotVerifier
import com.floe.android.core.workbenchmedia.util.MediaClock
import com.floe.android.core.workbenchmedia.util.MediaPaths
import com.floe.android.core.workbenchmedia.util.STORAGE_UNAVAILABLE
import com.floe.android.core.workbenchmedia.util.SystemMediaClock
import com.floe.android.core.workbenchmedia.util.WRITE_FAILED
import com.floe.android.core.workbenchmedia.util.atomicReplace
import com.floe.android.core.workbenchmedia.util.nowIso
import com.floe.android.core.workbenchmedia.util.refusal
import com.floe.android.core.workbenchmedia.util.writeFullySync
import com.floe.android.core.workbenchmedia.video.ImageVerifier
import com.floe.android.feature.workbench.MediaExportBinding
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import kotlinx.serialization.json.JsonObject

/**
 * C03 layer raster output. This is NOT a second project store: the returned
 * asset reference is the one the existing `addAsset` + `mergeLayers`/
 * `copySelection` commands commit through the normal native CAS/undo path.
 */
enum class C03LayerRasterMode {
    MERGE,
    COPY_SELECTION,
}

data class C03LayerRasterRequest(
    val binding: MediaExportBinding,
    val mode: C03LayerRasterMode,
    /** Two or more distinct layer ids for MERGE; one source id for COPY. */
    val layerIDs: List<String> = emptyList(),
    /** The project-wide vector selection for COPY_SELECTION. */
    val selection: JsonObject? = null,
    /** User-facing base name; the stored PNG has a generated safe suffix. */
    val name: String? = null,
)

data class C03RasterMetadata(
    val width: Int,
    val height: Int,
    val hasAlpha: Boolean,
)

data class C03RasterAsset(
    val id: String,
    val kind: String,
    val relativePath: String,
    val originalName: String,
    val byteCount: Long,
    val contentHash: String,
    val metadata: C03RasterMetadata,
)

data class C03LayerRasterReceipt(
    val asset: C03RasterAsset,
    val projectID: String,
    val projectRevision: Long,
    val mode: C03LayerRasterMode,
    val width: Int,
    val height: Int,
    val mimeType: String,
    val byteCount: Long,
    val sha256: String,
    val completedAt: String,
)

/**
 * Real full-canvas layer rasterization for the C03 merge/copy operations.
 *
 * The input is the SAME immutable native-issued snapshot the preview/export
 * renderer uses. It is re-verified here (lease expiry, canonical root,
 * containment, size, SHA-256, schema/revision) before any pixel is produced.
 * The output is written as a verified PNG under the trusted project root,
 * fsynced, dimension/format re-decoded, and only then atomically published.
 * Source assets and the original project JSON are never modified.
 *
 * MERGE matches the fixed iOS renderer: only the named visible layers, in
 * project stacking order, composited onto a transparent full-canvas bitmap and
 * WITHOUT the whole-canvas adjustment. COPY_SELECTION renders one layer through
 * that same pipeline and then multiplies it by the project selection mask.
 */
object C03LayerRasterService {
    const val MAX_RASTER_BYTES = 512L * 1024L * 1024L

    fun render(
        request: C03LayerRasterRequest,
        grant: AuthorityGrant,
    ): C03LayerRasterReceipt {
        val clock: MediaClock = SystemMediaClock()
        val binding = request.binding
        val snapshot = SnapshotVerifier.verify(
            SnapshotExpectation(
                epoch = grant.epoch,
                projectID = binding.context.projectID,
                revision = binding.projectRevision,
                timelineDigest = binding.timelineDigest,
                mediaRootPath = binding.mediaRootPath,
                attemptID = binding.attemptID,
                lease = binding.snapshot,
            ),
            grant,
            clock,
        )
        val project = snapshot.projection.project
        val canvas = project.canvas
            ?: throw refusal(
                com.floe.android.core.workbenchmedia.util.RENDER_UNSUPPORTED,
                "Image project has no canvas",
            )
        if (project.kind != "image") {
            throw refusal(
                com.floe.android.core.workbenchmedia.util.UNSUPPORTED_SOURCE_FORMAT,
                "Layer rasterization is only available for image projects",
            )
        }
        val target = ImageRenderTarget(canvas.width, canvas.height, preview = false)
        // The Android raster path is 8-bit ARGB_8888. A source HDR transfer,
        // >8-bit HEIF/AV1 bit depth or gain map cannot be preserved in a merge
        // or copy asset; refuse instead of silently tone-mapping it.
        val hdr = HdrSourceProbe.projectHasHdrSource(project, snapshot.root)
        if (hdr.isHdr) {
            throw refusal(
                com.floe.android.core.workbenchmedia.util.RENDER_UNSUPPORTED,
                "Layer merge/copy cannot preserve this HDR source " +
                    "(${hdr.detail ?: "hdr"}); convert it to SDR explicitly first",
            )
        }
        val renderer = ImageProjectRenderer(snapshot)
        val bitmap = when (request.mode) {
            C03LayerRasterMode.MERGE -> {
                val ids = request.layerIDs.distinct()
                if (ids.size < 2 || ids.size != request.layerIDs.size) {
                    throw com.floe.android.core.workbenchmedia.util.refusal(
                        com.floe.android.core.workbenchmedia.util.INVALID_PAYLOAD,
                        "Merge needs at least two distinct layer ids",
                    )
                }
                for (id in ids) {
                    val layer = project.imageLayers.firstOrNull { it.id == id }
                        ?: throw refusal(
                            com.floe.android.core.workbenchmedia.util.RENDER_UNSUPPORTED,
                            "Merge layer $id is missing",
                        )
                    if (layer.isLocked) {
                        throw refusal(
                            com.floe.android.core.workbenchmedia.util.RENDER_UNSUPPORTED,
                            "Layer '${layer.name}' is locked",
                        )
                    }
                }
                renderer.renderMerge(ids.toSet(), target)
            }
            C03LayerRasterMode.COPY_SELECTION -> {
                if (request.layerIDs.size != 1) {
                    throw com.floe.android.core.workbenchmedia.util.refusal(
                        com.floe.android.core.workbenchmedia.util.INVALID_PAYLOAD,
                        "Copy selection needs exactly one source layer",
                    )
                }
                val selection = request.selection
                    ?: throw com.floe.android.core.workbenchmedia.util.refusal(
                        com.floe.android.core.workbenchmedia.util.INVALID_PAYLOAD,
                        "Copy selection needs a non-empty selection",
                    )
                val parsed = MaskRasterizer.parseSelection(selection)
                if (parsed == null || parsed.shapes.isEmpty()) {
                    throw com.floe.android.core.workbenchmedia.util.refusal(
                        com.floe.android.core.workbenchmedia.util.INVALID_PAYLOAD,
                        "Copy selection needs a shaped selection",
                    )
                }
                val layer = project.imageLayers.firstOrNull { it.id == request.layerIDs.single() }
                    ?: throw refusal(
                        com.floe.android.core.workbenchmedia.util.RENDER_UNSUPPORTED,
                        "Copy source layer is missing",
                    )
                if (layer.isLocked) {
                    throw refusal(
                        com.floe.android.core.workbenchmedia.util.RENDER_UNSUPPORTED,
                        "Layer '${layer.name}' is locked",
                    )
                }
                renderer.renderCopySelection(layer.id, selection, target)
            }
        }
        try {
            val assetID = UUID.randomUUID().toString()
            val baseName = safeBaseName(request.name)
            val relative = "Workbench/Assets/$assetID-$baseName.png"
            val output = MediaPaths.resolveOutputUnder(snapshot.root, relative)
                ?: throw refusal(
                    STORAGE_UNAVAILABLE,
                    "Layer raster output path escapes the trusted media root",
                )
            if (output.exists()) {
                throw refusal(WRITE_FAILED, "Layer raster output already exists")
            }
            val parent = output.parentFile
                ?: throw refusal(STORAGE_UNAVAILABLE, "Layer raster directory is unavailable")
            if (!parent.isDirectory && !parent.mkdirs()) {
                throw refusal(STORAGE_UNAVAILABLE, "Layer raster directory could not be created")
            }
            val staging = File(parent, ".${binding.attemptID}-${assetID}.png.part")
            staging.delete()
            try {
                val encoded = ByteArrayOutputStream()
                if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, encoded)) {
                    throw refusal(
                        com.floe.android.core.workbenchmedia.util.RENDERER_UNAVAILABLE,
                        "Layer raster PNG encoder failed",
                    )
                }
                val bytes = encoded.toByteArray()
                if (bytes.isEmpty() || bytes.size.toLong() > MAX_RASTER_BYTES) {
                    throw refusal(
                        com.floe.android.core.workbenchmedia.util.RENDERER_UNAVAILABLE,
                        "Layer raster bytes are outside the bounded output size",
                    )
                }
                writeFullySync(staging, bytes)
                if (ImageVerifier.detectFormat(staging) != "png") {
                    throw refusal(
                        com.floe.android.core.workbenchmedia.util.RENDERER_UNAVAILABLE,
                        "Layer raster PNG could not be re-detected",
                    )
                }
                val verified = ImageVerifier.verify(
                    file = staging,
                    expectedWidth = bitmap.width,
                    expectedHeight = bitmap.height,
                    format = "png",
                    maxBytes = MAX_RASTER_BYTES,
                )
                atomicReplace(staging, output)
                return C03LayerRasterReceipt(
                    asset = C03RasterAsset(
                        id = assetID,
                        kind = "image",
                        relativePath = relative,
                        originalName = "$baseName.png",
                        byteCount = verified.byteCount,
                        contentHash = verified.sha256,
                        metadata = C03RasterMetadata(
                            width = bitmap.width,
                            height = bitmap.height,
                            hasAlpha = true,
                        ),
                    ),
                    projectID = project.id,
                    projectRevision = project.revision,
                    mode = request.mode,
                    width = bitmap.width,
                    height = bitmap.height,
                    mimeType = "image/png",
                    byteCount = verified.byteCount,
                    sha256 = verified.sha256,
                    completedAt = clock.nowIso(),
                )
            } catch (failure: Throwable) {
                staging.delete()
                throw failure
            }
        } finally {
            if (!bitmap.isRecycled) bitmap.recycle()
        }
    }

    private fun safeBaseName(raw: String?): String {
        val cleaned = raw
            ?.trim()
            ?.take(96)
            ?.map { ch ->
                if (ch in 'a'..'z' || ch in 'A'..'Z' || ch in '0'..'9' || ch == '-' || ch == '_') {
                    ch
                } else {
                    '-'
                }
            }
            ?.joinToString("")
            ?.trim('-')
            .orEmpty()
        return cleaned.ifEmpty { "layer-raster" }
    }
}
