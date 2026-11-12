// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.externaledit

import android.net.Uri

/**
 * One typed, App-owned read-only document VIEW for the background handoff
 * route.
 *
 * The request is constructed ONLY by [ArtifactHandoffController] from an
 * already verified handoff record and the current platform tool ticket. The
 * model never supplies an Intent, action, category, flags, extras, URI
 * authority, task/run identity or component; there is no generic
 * arbitrary-Intent surface here.
 *
 * The Full platform extension implements [ArtifactHandoffBackgroundDocumentLauncher]
 * over the EXISTING PhoneControl armed-owner/epoch/session fence. It is not a
 * second device controller and it creates no permission or target selection.
 */
internal data class ArtifactHandoffBackgroundDocumentRequest(
    /** Exact live task/run from the handoff ToolContext (validated UUIDs). */
    val taskID: String,
    val runID: String,
    /** Exact native epoch and host generation captured by the controller's
     * owner binding and re-proved immediately before the OS call. */
    val nativeEpoch: Long,
    val hostGeneration: Long,
    /** The App's own externaledits FileProvider URI for the verified private
     * copy. Only a read grant (plus ClipData) is ever attached. */
    val uri: Uri,
    val mimeType: String,
    val packageName: String,
    val className: String,
    val displayName: String,
)

/**
 * Result of the narrow background document VIEW.
 *
 * [Refused] is DEFINITELY not dispatched, so the controller may keep the
 * verified copy retryable. [Unknown] means the call may have reached the OS
 * and must never be replayed. [Accepted] is only the platform's acceptance
 * of the explicit Activity start: not display, playback, edit or import.
 * [Accepted.viewerVisible] is the optional, bounded post-dispatch foreground
 * read: true = the exact target package's window was observed, false = a
 * different ordinary window was observed instead, null = not attributable.
 * Even true is not proof that the viewer decoded or played the content.
 */
internal sealed class ArtifactHandoffBackgroundLaunchResult {
    data class Accepted(val viewerVisible: Boolean? = null) :
        ArtifactHandoffBackgroundLaunchResult()

    data class Refused(
        val code: String,
        /** Bounded model-facing next step; it never creates authority. */
        val nextStep: String? = null,
    ) : ArtifactHandoffBackgroundLaunchResult()

    data object Unknown : ArtifactHandoffBackgroundLaunchResult()
}

/**
 * Platform-owned implementation of the background document route.
 *
 * Implementations must take every decision again at launch time (live owner,
 * epoch/generation, task/run, armed target scope, exact installed VIEW
 * handler, still-live native ticket and user Stop/takeover/lock). They must
 * not accept a caller-supplied Intent or add write/persistable grants.
 */
internal interface ArtifactHandoffBackgroundDocumentLauncher {
    suspend fun launch(
        request: ArtifactHandoffBackgroundDocumentRequest,
        stillCurrent: () -> Boolean,
    ): ArtifactHandoffBackgroundLaunchResult
}
