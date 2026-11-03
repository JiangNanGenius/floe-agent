// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench

import com.floe.android.feature.canvas.CreativeStorageLayer

/**
 * Trusted read envelope for a video project.
 *
 * [project] is the ACTUAL native schema-1 project; [timeline] is a typed
 * projection of `project.videoTimeline`. [mediaRootPath] is copied from the
 * trusted native envelope and is never accepted back as a write root. The
 * envelope does not invent hardware capabilities: those come from the separate
 * Kotlin platform port and are not asserted by Swift.
 */
data class VideoProjectEnvelope(
    val project: MediaProject,
    val timeline: VideoTimeline,
    /** Read-only trusted media root; never accepted as a write path. */
    val mediaRootPath: String,
    val storage: CreativeStorageLayer,
    val writable: Boolean,
    val warnings: List<String> = emptyList(),
)

/**
 * G09-R2 video timeline consumer API.
 *
 * This is additive: R1 [WorkbenchHostApi] and its image command vocabulary are
 * unchanged. Both open and apply require the explicit [CreativeProjectContext]
 * (session token + real storage layer + optional real origin); the bound host
 * supplies the accepted epoch separately. A recorded project path or
 * environment ID is never authority.
 *
 * `applyVideo` is ONE native CAS transaction via the existing Swift
 * `MediaEditCommand` engine. It advances one revision and one undo step for
 * the whole batch and returns the recorded receipt for a replayed `opID`.
 */
interface WorkbenchVideoHostApi {
    suspend fun loadVideo(context: CreativeProjectContext): VideoProjectEnvelope

    suspend fun applyVideo(
        context: CreativeProjectContext,
        expectedRevision: Long,
        opID: String,
        commands: List<VideoEditCommand>,
    ): MediaProjectReceipt
}
