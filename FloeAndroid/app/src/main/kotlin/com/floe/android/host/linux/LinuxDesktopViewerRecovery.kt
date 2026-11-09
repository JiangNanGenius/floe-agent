// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

/**
 * Pure disposition seam between a dead viewer lane and a dead project session.
 *
 * The guest display is an Xtigervnc server started with `-AlwaysShared` inside
 * the retained PTY launcher's control loop. A closed or failed Android-side VNC
 * client session is therefore a viewer transport fact, NOT proof that the
 * project's real environment/display context died. The only authoritative
 * retained-child check is a fenced ping on the existing PTY control channel:
 * the launcher returns FLOE_PONG only while both server and window manager
 * children are alive, on the same terminal token and root epoch. An unproven
 * session keeps the existing destructive failure, so
 * nothing ever publishes "alive" without evidence, and a hidden viewer is
 * never rebuilt into unconditional background GUI work.
 */
internal object LinuxDesktopViewerRecovery {
    /** Viewer transport lost while the proven guest session keeps serving CLI work. */
    const val viewerFailure = "viewer_disconnected"
    /** Existing session-death vocabulary: the guest control channel itself refused or timed out. */
    const val sessionFailure = "desktop_disconnected"

    enum class Loss { ignore, viewerDisconnected, sessionFailed }

    /**
     * `sessionLive` is the host's own stopped/epoch fence, `ownsFailedLane` is
     * the retired lane still being the current vncID, and `phase` is the owned
     * session phase. Any stale fence ignores the loss so a queued classification
     * can never corrupt a newer session or a stopped one. Only with every fence
     * current does a proven control channel demote the loss to a viewer failure
     * (session and DISPLAY context stay running); without proof the existing
     * session failure is preserved unchanged.
     */
    fun onViewerLoss(sessionLive: Boolean, ownsFailedLane: Boolean, phase: String?,
        controlProvedAlive: Boolean): Loss = when {
        !sessionLive || !ownsFailedLane || phase != "running" -> Loss.ignore
        controlProvedAlive -> Loss.viewerDisconnected
        else -> Loss.sessionFailed
    }

    /**
     * Reconnect is offered only on a viewer reopen edge for a running session
     * in the bounded viewer-failure state. A healthy session, an explicit
     * session failure, a non-running phase or a hidden viewer never triggers
     * background reconnection work.
     */
    fun shouldReconnect(visible: Boolean, phase: String?, failure: String?): Boolean =
        visible && phase == "running" && failure == viewerFailure
}
