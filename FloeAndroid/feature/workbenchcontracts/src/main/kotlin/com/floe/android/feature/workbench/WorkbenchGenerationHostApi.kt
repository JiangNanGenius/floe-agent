// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench

/**
 * G09-R2 cloud generation consumer API.
 *
 * Every call carries the explicit [CreativeProjectContext]; the native host
 * re-resolves the accepted epoch, storage layer and real origin, and refuses a
 * mismatch. There is no `projectID`-only lookup and no foreign-job access:
 * status/cancel/deliver verify the durable job's actual owner before returning
 * any state.
 *
 * Submit and candidate adoption are fenced mutations:
 * * submit carries `expectedRevision` + stable `opID` and persists a durable
 *   request/job before the provider call;
 * * adoption carries `expectedRevision` + stable `opID` and is one native CAS
 *   transaction (verify candidate bytes, copy into the explicit project media
 *   root, append asset + layer/clip, advance one revision);
 * * an unknown transport outcome returns `outcomeUnknown` and is never
 *   resubmitted automatically.
 *
 * This interface is a consumer contract only. It declares no provider
 * implementation, no default success value and no in-memory fallback store.
 */
interface WorkbenchGenerationHostApi {
    suspend fun models(): GenerationModelCatalog

    suspend fun submitImage(
        context: CreativeProjectContext,
        expectedRevision: Long,
        opID: String,
        request: ImageGenerationRequest,
    ): ImageRequestHandle

    suspend fun imageStatus(
        context: CreativeProjectContext,
        requestID: String,
    ): ImageRequestStatus

    suspend fun dismissImageRequest(
        context: CreativeProjectContext,
        requestID: String,
        opID: String,
    )

    suspend fun submitVideo(
        context: CreativeProjectContext,
        expectedRevision: Long,
        opID: String,
        request: VideoGenerationRequest,
    ): VideoJobHandle

    suspend fun jobs(
        context: CreativeProjectContext,
        limit: Int = WorkbenchR2Limits.JOB_LIST_DEFAULT,
    ): List<MediaJobStatus>

    suspend fun refreshJob(
        context: CreativeProjectContext,
        jobID: String,
    ): MediaJobStatus

    suspend fun cancelJob(
        context: CreativeProjectContext,
        jobID: String,
        opID: String,
    ): MediaJobStatus

    suspend fun deliverResult(
        context: CreativeProjectContext,
        jobID: String,
        opID: String,
    ): DeliveredCandidate

    suspend fun candidates(context: CreativeProjectContext): List<MediaCandidate>

    suspend fun acceptCandidate(
        context: CreativeProjectContext,
        expectedRevision: Long,
        candidateID: String,
        opID: String,
    ): MediaProjectReceipt

    suspend fun rejectCandidate(
        context: CreativeProjectContext,
        candidateID: String,
        opID: String,
    ): CandidateMutationReceipt
}
