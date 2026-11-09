// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.junit.Assert.*
import org.junit.Test

class ComponentInstallHandoffTest {
    @Test fun confirmationBeforeCommitReturnsCannotBeOverwrittenByInstalling() = runBlocking {
        val mutex = Mutex(); val handoff = ComponentInstallHandoff(mutex)
        var visible = "idle"
        lateinit var callback: kotlinx.coroutines.Job
        mutex.withLock {
            handoff.begin()
            callback = launch(start = CoroutineStart.UNDISPATCHED) {
                handoff.route(17) { visible = "confirmation" }
            }
            assertFalse(callback.isCompleted)
            handoff.bind(17)
            visible = "installing"
        }
        callback.join()
        assertEquals("confirmation", visible)
    }
    @Test fun abandonedOldSessionCannotCancelCurrentRetry() = runBlocking {
        val mutex = Mutex(); val handoff = ComponentInstallHandoff(mutex)
        mutex.withLock { handoff.begin(); handoff.bind(19) }
        var visible = "installing"
        assertFalse(handoff.route(18) { visible = "cancelled" })
        assertTrue(handoff.route(19) { visible = "confirmation" })
        assertEquals("confirmation", visible)
    }
    @Test fun lateCallbacksCannotReviveACompletedSession() = runBlocking {
        val mutex = Mutex(); val handoff = ComponentInstallHandoff(mutex)
        mutex.withLock { handoff.begin(); handoff.bind(21) }
        assertTrue(handoff.route(21) { handoff.completed() })
        var changed = false
        assertFalse(handoff.route(21) { changed = true })
        assertFalse(changed)
    }
}
