// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas

/**
 * G09-R2 design consumer API.
 *
 * The native design host is bound to the same accepted epoch/root as the R1
 * Canvas and media services. It reuses the shared Swift `DesignOwnerWorkflow`
 * (file/chat/creative owners) and `DesignCanvasService` (Canvas node owner)
 * behind explicit-root stores. This Kotlin interface is a consumer contract;
 * it declares no project/design store, no default `Application Support` root
 * and no success-only path.
 *
 * Canvas targets mutate through the existing Canvas repository CAS. Owner
 * targets use the owner envelope CAS. Both require explicit target identity,
 * explicit storage, the exact session token and a stable operation ID for
 * mutations. `epoch` is bound once through [bind] and supplied by the host, not
 * by a UI request.
 *
 * `preview` and `export` return verified file receipts (relative path, digest,
 * size/format) or a typed failure; they never return a bare success string.
 */
interface DesignHostApi {
    suspend fun bind(epoch: Long): CreativeBinding

    suspend fun status(): DesignHostStatus

    suspend fun state(binding: DesignTargetBinding): DesignStateProjection

    /** Bind/create the explicit owner envelope; Canvas uses the Canvas authority. */
    suspend fun bindTarget(request: DesignBindRequest): DesignStateProjection

    suspend fun setBrief(request: DesignBriefRequest): DesignStateProjection

    suspend fun setSpec(request: DesignSpecRequest): DesignStateProjection

    suspend fun freeze(request: DesignFreezeRequest): DesignFreezeReceipt

    suspend fun propose(request: DesignProposalRequest): DesignProposalResult

    suspend fun adopt(request: DesignAdoptRequest): DesignDecisionResult

    suspend fun reject(request: DesignRejectRequest): DesignDecisionReceipt

    suspend fun compare(request: DesignCompareRequest): DesignComparison

    suspend fun restore(request: DesignRestoreRequest): DesignStateProjection

    suspend fun preview(request: DesignPreviewRequest): DesignPreviewReceipt

    suspend fun export(request: DesignExportRequest): DesignExportReceipt
}
