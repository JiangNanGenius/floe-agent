// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.r2

import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.MediaExportBinding
import com.floe.android.feature.workbench.MediaExportReceipt
import com.floe.android.feature.workbench.MediaExportStatus
import com.floe.android.feature.workbench.WorkbenchEnhancementConfigurationHostApi
import com.floe.android.feature.workbench.WorkbenchEnhancementHostApi
import com.floe.android.feature.workbench.WorkbenchGenerationHostApi
import com.floe.android.feature.workbench.WorkbenchMediaPlatform
import com.floe.android.feature.workbench.WorkbenchVideoHostApi
import com.floe.android.feature.workbench.ui.api.MediaPickedSource

/**
 * Required feature-side binding callback.
 *
 * The UI never derives a timeline digest and never reopens the mutable latest
 * project for a render. It asks the host for an immutable snapshot lease for
 * the exact [CreativeProjectContext], revision and attempt. The native owner
 * decides whether such a snapshot exists; a refusal is surfaced as
 * [com.floe.android.feature.canvas.CreativeException].
 *
 * This callback is part of the R2 integration contract: the App must supply a
 * real native implementation. There is no default, no fallback digest and no
 * "latest revision" retry inside the feature module.
 */
fun interface WorkbenchRenderBindingPreparer {
    suspend fun prepareRenderBinding(
        context: CreativeProjectContext,
        expectedRevision: Long,
        attemptID: String,
    ): MediaExportBinding
}

/**
 * Required release callback for a prepared binding/snapshot lease.
 *
 * Called exactly once for each prepared binding after the owning render or
 * playback handle reached a real terminal state. Release must be idempotent;
 * an export still running keeps its lease until the platform reports
 * completed/cancelled/failed/interrupted/timeout.
 */
fun interface WorkbenchRenderBindingReleaser {
    suspend fun releaseRenderBinding(binding: MediaExportBinding)
}

/** User destination picked through the App's SAF/share surface. */
sealed interface WorkbenchExportDeliveryResult {
    /** The App completed a real share/save of the verified output. */
    data object Delivered : WorkbenchExportDeliveryResult

    /** The user dismissed the destination surface; nothing was written. */
    data object Cancelled : WorkbenchExportDeliveryResult

    /** The destination operation failed. [code] is a bounded host code. */
    data class Failed(val code: String? = null) : WorkbenchExportDeliveryResult
}

/**
 * Required delivery callback for a VERIFIED export receipt.
 *
 * The receipt's relative path is the only output identity the feature passes
 * on. The App owns SAF/MediaStore destinations and must not treat that path
 * as write authority; it re-opens the file through its own verified read-back.
 */
fun interface WorkbenchExportDelivery {
    suspend fun deliverExport(receipt: MediaExportReceipt): WorkbenchExportDeliveryResult
}

/**
 * Bounded process-restart enumeration of the platform's non-frozen export
 * journal. It is scoped by the CURRENT authorized project context, returns
 * only host-issued statuses/receipts, and never invents an ID, a lease or a
 * second database. A recovered record does not imply a live snapshot lease;
 * retry remains unavailable unless the original request was captured.
 */
fun interface WorkbenchRecoveredExportLister {
    suspend fun listRecoveredExports(
        context: CreativeProjectContext,
        limit: Int,
    ): List<MediaExportStatus>
}

enum class WorkbenchMediaPickKind { VIDEO, AUDIO }

/**
 * Feature-owned audio/video picker callback. The App implements it with its
 * real Activity Result picker and returns a staged [MediaPickedSource]; the
 * feature never invents a path or reads a raw content URI.
 */
fun interface WorkbenchMediaPicker {
    suspend fun pickMedia(kind: WorkbenchMediaPickKind): MediaPickedSource?
}

/**
 * Complete G09-R2 capability set for one bound media session.
 *
 * Every member is a required real port. R1 sessions may omit the whole bundle
 * (video stays an honest unavailable state); once supplied, the integrated R2
 * path uses these exact objects and fails visibly when one is unavailable.
 * There is deliberately no dummy/no-op implementation and no default success.
 */
class WorkbenchR2Ports(
    val video: WorkbenchVideoHostApi,
    val generation: WorkbenchGenerationHostApi,
    val platform: WorkbenchMediaPlatform,
    val recoveredExports: WorkbenchRecoveredExportLister,
    val renderBindings: WorkbenchRenderBindingPreparer,
    val releaseRenderBinding: WorkbenchRenderBindingReleaser,
    val exportDelivery: WorkbenchExportDelivery,
    val enhancement: WorkbenchEnhancementHostApi,
    val enhancementConfiguration: WorkbenchEnhancementConfigurationHostApi,
)
