// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas.ui.design

import android.graphics.Bitmap
import android.net.Uri
import com.floe.android.feature.canvas.CanvasProject
import com.floe.android.feature.canvas.DesignContentType
import com.floe.android.feature.canvas.DesignExportReceipt
import com.floe.android.feature.canvas.DesignPreviewReceipt
import com.floe.android.feature.canvas.DesignTargetBinding
import com.floe.android.feature.canvas.StagedDesignPayload

/**
 * One user-selected proposal source handed to the App-owned staging seam.
 *
 * The feature never reads bytes and never invents a staging token. [PickedUri]
 * is the exact SAF result; [ManualText] is typed by the user and is written to
 * one App-owned temporary file by the App before the real native stage call.
 */
sealed interface DesignProposalSource {
    data class PickedUri(val uri: Uri, val displayName: String?) : DesignProposalSource

    data class ManualText(
        val text: String,
        /** `md` / `txt` / `html`; the App writes exactly this extension. */
        val format: String,
    ) : DesignProposalSource
}

/**
 * Verified preview body returned by the App owner.
 *
 * Every body is produced from a native receipt that was re-proved against the
 * captured accepted Root/epoch, the live design state and the actual bytes
 * (size + SHA-256). No body is built from model text, a recorded path or a
 * second Canvas/design store.
 */
sealed interface DesignPreviewContent {
    data class Image(
        val bitmap: Bitmap,
        val format: String,
    ) : DesignPreviewContent

    data class Text(
        val text: String,
        val format: String,
        val truncated: Boolean,
    ) : DesignPreviewContent

    data class PdfPages(
        val pages: List<Bitmap>,
        val pageCount: Int,
        val format: String,
    ) : DesignPreviewContent

    /**
     * Read-only projection of the REAL `canvas.snapshot` JSON document.
     *
     * [project] is the EXACT canonical schema-7 Canvas document the native
     * design snapshot returned at the SAME [canvasRevision] (never a second
     * persisted Canvas and never metadata dressed up as a scene). The sheet
     * renders it through the existing read-only Canvas geometry/node
     * components. [assetBitmaps] contains only images whose bytes were read
     * through the captured native Canvas owner and whose SHA-256 matched the
     * snapshot reference; a missing entry renders the existing honest
     * placeholder, never a fabricated image. The bitmaps are owned by the
     * Canvas bitmap cache (`CanvasBitmapLoader`), so [recycle] must not free
     * them.
     *
     * [briefGoal]/[specRawMarkdown]/[candidateCount] remain design metadata
     * details only; they are never a substitute for the scene.
     */
    data class CanvasSnapshot(
        val canvasID: String,
        val canvasRevision: Long,
        val documentID: String,
        val nodeID: String,
        val contentType: DesignContentType,
        val briefGoal: String?,
        val specRawMarkdown: String?,
        val candidateCount: Int,
        val project: CanvasProject? = null,
        val assetBitmaps: Map<String, Bitmap> = emptyMap(),
        val assets: List<CanvasSnapshotAsset> = emptyList(),
        val assetsTruncated: Boolean = false,
    ) : DesignPreviewContent

    /** One bounded asset reference of the real snapshot document. */
    data class CanvasSnapshotAsset(
        val assetID: String,
        val kind: String,
        val mimeType: String?,
        val contentHash: String?,
        val byteCount: Long?,
        /** True only for a real asset row with a matching content hash. */
        val verified: Boolean,
        /** True when verified bytes were decoded for display. */
        val bitmapAvailable: Boolean,
    )

    data class Unavailable(
        val format: String,
    ) : DesignPreviewContent
}

/** Frees bounded native/bitmap buffers owned by one preview body. */
fun DesignPreviewContent.recycle() {
    when (this) {
        is DesignPreviewContent.Image -> if (!bitmap.isRecycled) bitmap.recycle()
        is DesignPreviewContent.PdfPages -> pages.forEach { page ->
            if (!page.isRecycled) page.recycle()
        }
        is DesignPreviewContent.Text,
        // Canvas snapshot bitmaps are cache-owned by CanvasBitmapLoader (the
        // Canvas editor shares that cache); recycling them here would free a
        // bitmap another surface may still draw.
        is DesignPreviewContent.CanvasSnapshot,
        is DesignPreviewContent.Unavailable,
        -> Unit
    }
}

/** Truthful terminal result of one SAF delivery. */
sealed interface DesignExportDeliveryResult {
    data class Delivered(val byteCount: Long, val sha256: String) :
        DesignExportDeliveryResult

    data object Cancelled : DesignExportDeliveryResult

    data class Refused(
        val code: String,
        val retryable: Boolean = false,
    ) : DesignExportDeliveryResult
}

/** User's explicit preservation constraints for one RESTRUCTURE. */
data class DesignPreservationConstraints(
    val content: List<String> = emptyList(),
    val data: List<String> = emptyList(),
    val behavior: List<String> = emptyList(),
    val formatBounds: List<String> = emptyList(),
) {
    fun isEmpty(): Boolean =
        content.isEmpty() && data.isEmpty() && behavior.isEmpty() && formatBounds.isEmpty()
}

enum class DesignTrustedOperation(val wire: String) {
    PROPOSE("propose"),
    FREEZE("freeze"),
    ADOPT("adopt"),
}

/** Exact values shown before a trusted confirmation is minted. */
data class DesignRestructureRequest(
    val binding: DesignTargetBinding,
    val operation: DesignTrustedOperation,
    val opID: String,
    val preservation: DesignPreservationConstraints,
    val artifactID: String? = null,
    val candidateID: String? = null,
    val baseRevisionID: String? = null,
)

data class DesignRestructureConfirmation(
    val token: String,
    val targetKey: String,
    val operationID: String,
    val originalTaskOwnerID: String?,
    val baseRevisionID: String?,
    val preservationDigest: String,
    val preservation: DesignPreservationConstraints,
    val expiresAt: String,
)

/**
 * App-owned callbacks the feature UI cannot implement:
 * staging, verified preview, verified export delivery and the trusted
 * restructure confirmation route.
 *
 * Every method is required. There is no default, no fake success and no UI
 * boolean that can stand in for a native grant.
 */
interface DesignUiPorts {
    suspend fun stageProposal(
        source: DesignProposalSource,
        sessionToken: String,
    ): StagedDesignPayload

    fun discardProposal(token: String)

    suspend fun openPreview(
        receipt: DesignPreviewReceipt,
        binding: DesignTargetBinding,
    ): DesignPreviewContent

    suspend fun deliverExport(
        receipt: DesignExportReceipt,
        binding: DesignTargetBinding,
    ): DesignExportDeliveryResult

    suspend fun prepareRestructure(
        request: DesignRestructureRequest,
    ): DesignRestructureConfirmation

    suspend fun confirmRestructure(
        confirmation: DesignRestructureConfirmation,
        binding: DesignTargetBinding,
    ): Boolean

    suspend fun revokeRestructure(
        confirmation: DesignRestructureConfirmation,
        binding: DesignTargetBinding,
    )
}

/** Display identity of the exact target, resolved by the App/Canvas owner. */
data class DesignTargetDescriptor(
    val title: String,
    val kindLabel: String,
    /** Canvas editor revision for the first bind; null for owner targets. */
    val expectedRevision: Long? = null,
)

/**
 * One acquired design session. [canvasRefresh] is supplied only by the Canvas
 * entry and reloads the authoritative Canvas envelope after an adoption while
 * preserving the Canvas selection/undo state.
 */
data class DesignSessionRequest(
    val binding: DesignTargetBinding,
    val descriptor: DesignTargetDescriptor,
    val canvasRefresh: (suspend () -> Boolean)? = null,
)

/**
 * App-retained design session factory.
 *
 * The App owns the bounded target map, the Application scope and the captured
 * epoch/root. The feature only asks for the retained controller for this exact
 * binding; it never creates a second owner/authority.
 */
interface DesignSessionProvider {
    /**
     * Returns the App-retained controller for this exact target binding.
     * Synchronous so a rotation/close cannot strand a newly retained session
     * between a cancelled coroutine and the map write; the controller's
     * [DesignWorkflowController.start] performs the real host bind and reports
     * a typed failure in the sheet when the target is not available.
     */
    fun acquire(request: DesignSessionRequest): DesignWorkflowController

    fun release(controller: DesignWorkflowController)
}
