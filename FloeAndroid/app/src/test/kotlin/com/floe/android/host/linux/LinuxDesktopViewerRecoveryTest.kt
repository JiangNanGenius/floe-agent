// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/**
 * Authored NOTRUN. Boundary contract for the N05 graphics-context lifecycle:
 * a dead Android-side VNC viewer lane must never by itself end the project's
 * owned display session. Only the fenced PTY control ping proves guest life;
 * the retained `-AlwaysShared` Xtigervnc server and its launcher loop keep the
 * DISPLAY context usable for project CLI work across viewer hide/reopen. The
 * host wires these decisions; these tests pin the closed decisions themselves.
 */
class LinuxDesktopViewerRecoveryTest {

    @Test fun provenGuestAfterViewerLossKeepsTheRunningSession() {
        assertEquals(LinuxDesktopViewerRecovery.Loss.viewerDisconnected,
            LinuxDesktopViewerRecovery.onViewerLoss(sessionLive = true, ownsFailedLane = true,
                phase = "running", controlProvedAlive = true))
    }

    /** An unproven control channel is never relabeled as "viewer only": the
     * pre-existing destructive session failure stays the conservative answer. */
    @Test fun unprovenGuestKeepsTheExistingSessionFailure() {
        assertEquals(LinuxDesktopViewerRecovery.Loss.sessionFailed,
            LinuxDesktopViewerRecovery.onViewerLoss(sessionLive = true, ownsFailedLane = true,
                phase = "running", controlProvedAlive = false))
    }

    /** A current fence with an unproven result is NOT ignored: only stale
     * ownership may drop a loss event silently. */
    @Test fun liveUnownedLaneOrStoppedRootCanNeverRewriteANewerSession() {
        listOf(
            // stopped flag or regenerated native root epoch
            Triple(false, true, "running"),
            // a newer lane already replaced vncID
            Triple(true, false, "running"),
            // phases where no viewer lane was ever adopted
            Triple(true, true, "starting"),
            Triple(true, true, "installing"),
            Triple(true, true, "failed"),
            Triple(true, true, "save_pending"),
            Triple(true, true, "close_pending"),
            Triple(true, true, null),
        ).forEach { (live, owns, phase) ->
            assertEquals("stale fence ($live,$owns,$phase) must ignore",
                LinuxDesktopViewerRecovery.Loss.ignore,
                LinuxDesktopViewerRecovery.onViewerLoss(live, owns, phase, controlProvedAlive = true))
            assertEquals("stale fence ($live,$owns,$phase) must ignore even unproven",
                LinuxDesktopViewerRecovery.Loss.ignore,
                LinuxDesktopViewerRecovery.onViewerLoss(live, owns, phase, controlProvedAlive = false))
        }
    }

    @Test fun reconnectIsOfferedOnlyOnAReopenEdgeOfAProvenViewerFailure() {
        assertTrue(LinuxDesktopViewerRecovery.shouldReconnect(visible = true,
            phase = "running", failure = LinuxDesktopViewerRecovery.viewerFailure))
        // Hidden: a background GUI must not stream or reconnect unconditionally.
        assertFalse(LinuxDesktopViewerRecovery.shouldReconnect(visible = false,
            phase = "running", failure = LinuxDesktopViewerRecovery.viewerFailure))
        // A proven-dead session (no control PONG) must never be resurrected;
        // only the explicit stop/Start path may replace it.
        assertFalse(LinuxDesktopViewerRecovery.shouldReconnect(visible = true,
            phase = "running", failure = LinuxDesktopViewerRecovery.sessionFailure))
        // Healthy, starting, failed or unrelated bounded failures: no work.
        assertFalse(LinuxDesktopViewerRecovery.shouldReconnect(visible = true, phase = "running", failure = null))
        assertFalse(LinuxDesktopViewerRecovery.shouldReconnect(visible = true, phase = "starting",
            failure = LinuxDesktopViewerRecovery.viewerFailure))
        assertFalse(LinuxDesktopViewerRecovery.shouldReconnect(visible = true, phase = "failed",
            failure = LinuxDesktopViewerRecovery.viewerFailure))
        assertFalse(LinuxDesktopViewerRecovery.shouldReconnect(visible = true, phase = "running", failure = "input_failed"))
    }

    /** Diagnostics may only carry the fixed bounded vocabulary: no raw guest
     * output, path or content can enter either failure name. */
    @Test fun failureVocabularyStaysBoundedDiagnostics() {
        val safe = Regex("[A-Za-z0-9_]{1,80}")
        assertTrue(LinuxDesktopViewerRecovery.viewerFailure.matches(safe))
        assertTrue(LinuxDesktopViewerRecovery.sessionFailure.matches(safe))
        assertEquals("viewer_disconnected", LinuxDesktopViewerRecovery.viewerFailure)
        assertEquals("desktop_disconnected", LinuxDesktopViewerRecovery.sessionFailure)
    }

    /** The reopen edges the shared viewer uses (app foreground, software
     * overlay return, sheet reopen) all arrive through setVisible(true); a
     * random retry flood from repeated edges must remain idempotent in the
     * decision itself: it depends only on the bounded current state. */
    @Test fun repeatedReopenEdgesDependOnlyOnCurrentBoundedState() {
        var failure: String? = LinuxDesktopViewerRecovery.viewerFailure
        assertTrue(LinuxDesktopViewerRecovery.shouldReconnect(true, "running", failure))
        assertTrue(LinuxDesktopViewerRecovery.shouldReconnect(true, "running", failure))
        failure = null
        assertFalse(LinuxDesktopViewerRecovery.shouldReconnect(true, "running", failure))
        // A fresh unrelated nonce can never match the bounded viewer vocabulary.
        assertFalse(LinuxDesktopViewerRecovery.shouldReconnect(true, "running", UUID.randomUUID().toString()))
    }
}
