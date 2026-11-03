// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench

/**
 * Frozen App-supplied port for the real G09-R2 media-enhancement surface.
 *
 * The feature module never persists enhancement state and never invents a
 * path, job ID or capability: the native service owns the durable journal,
 * the task-environment execution and the measured receipts. Unknown outcomes
 * are reported with the retained remote job ID and are never replayed here.
 */
interface WorkbenchEnhancementHostApi {
    suspend fun enhancementCapability(context: CreativeProjectContext): EnhancementCapability

    /** Returns the durable enhancement jobID immediately. */
    suspend fun submitEnhancement(
        context: CreativeProjectContext,
        request: EnhancementRequest,
    ): String

    suspend fun enhancementStatus(
        context: CreativeProjectContext,
        jobID: String,
    ): EnhancementStatus

    suspend fun cancelEnhancement(
        context: CreativeProjectContext,
        jobID: String,
    ): EnhancementStatus

    /**
     * Retries the ORIGINAL importAsset ownership for one COMPLETED job whose
     * verified output is not a project asset yet. Idempotent natively; a
     * retry after a successful import replays the committed import receipt.
     */
    suspend fun importEnhancementOutput(
        context: CreativeProjectContext,
        jobID: String,
    ): EnhancementStatus
}
