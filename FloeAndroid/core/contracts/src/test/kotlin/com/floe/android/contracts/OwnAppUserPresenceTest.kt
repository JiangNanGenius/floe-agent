// SPDX-License-Identifier: MPL-2.0
package com.floe.android.contracts

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Signal-lifecycle tests for the neutral own-App physical-input bridge.
 *
 * Production contract: the phone-control runtime binds one listener on real
 * AccessibilityService attach and clears it on detach. These tests pin the
 * lifecycle the service relies on — a replaced/retired listener can never
 * observe or mutate a newer session, and a service that never attached leaves
 * the common Activity call a cheap no-op (Play and no-service Full alike).
 */
class OwnAppUserPresenceTest {
    private class RecordingListener : OwnAppUserPresence.Listener {
        var count = 0
        override fun onOwnAppUserInteraction() { count += 1 }
    }

    @After
    fun tearDown() {
        // The bridge is process-global; never leak a listener into another test.
        OwnAppUserPresence.setListener(null)
    }

    @Test
    fun reportedInteractionReachesTheBoundListener() {
        val listener = RecordingListener()
        OwnAppUserPresence.setListener(listener)
        OwnAppUserPresence.reportOwnAppUserInteraction()
        OwnAppUserPresence.reportOwnAppUserInteraction()
        assertEquals(2, listener.count)
    }

    @Test
    fun replacingTheListenerDetachesTheRetiredOne() {
        val retired = RecordingListener()
        val live = RecordingListener()
        OwnAppUserPresence.setListener(retired)
        // Service rebind: a NEW session's listener replaces the old one. The
        // retired listener must not receive new task input.
        OwnAppUserPresence.setListener(live)
        OwnAppUserPresence.reportOwnAppUserInteraction()
        assertEquals(0, retired.count)
        assertEquals(1, live.count)
    }

    @Test
    fun clearedListenerReceivesNothingAfterDetach() {
        val listener = RecordingListener()
        OwnAppUserPresence.setListener(listener)
        OwnAppUserPresence.setListener(null)
        OwnAppUserPresence.reportOwnAppUserInteraction()
        assertEquals(0, listener.count)
    }

    @Test
    fun reportWithoutAListenerIsANoOp() {
        // Common-source Activity calls this on every real user interaction;
        // with the Full service detached (or on Play) it must do nothing.
        OwnAppUserPresence.reportOwnAppUserInteraction()
    }
}
