// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtimeipc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * job-d4aeae04aa5a4f6c — the recorded Full 13 crash was an ART JNI global
 * reference overflow (50,069 `RuntimeConnection$connection$1$$...Lambda0`
 * instances) plus 436 outstanding `LoadedApk$ServiceDispatcher$InnerConnection`
 * entries. These regressions pin the exact lifecycle rules that made that
 * impossible: one binding per connection, one death registration per live
 * endpoint, unlink on replacement/loss/close, and no re-bind for a merely
 * disconnected binding.
 */
class RuntimeBinderLifetimeTest {
    private class FakeBinder(val name: String) {
        override fun toString(): String = name
    }

    @Test
    fun oneBindIsReusedForUnboundedConnects() {
        val lifetime = RuntimeBinderLifetime<FakeBinder>()
        val door = FakeBinder("door")
        assertEquals(RuntimeBinderLifetime.Connect.BIND, lifetime.connect())
        assertTrue(lifetime.onConnected(door)!!.link)
        repeat(50_000) {
            assertEquals(RuntimeBinderLifetime.Connect.LIVE, lifetime.connect())
        }
        assertEquals(1, lifetime.bindAttempts)
        assertEquals(1, lifetime.links)
        assertEquals(1, lifetime.activeLinks())
    }

    @Test
    fun repeatedLossAndReconnectKeepsLinksBoundedAndBalanced() {
        val lifetime = RuntimeBinderLifetime<FakeBinder>()
        val door = FakeBinder("door")
        repeat(5_000) { cycle ->
            // The binding is created ONCE; every reconnect after a loss waits
            // for the framework and never issues another bindService.
            assertEquals(
                if (cycle == 0) RuntimeBinderLifetime.Connect.BIND
                else RuntimeBinderLifetime.Connect.WAIT_FOR_RECONNECT,
                lifetime.connect(),
            )
            val attachment = lifetime.onConnected(door)!!
            assertTrue("each new live endpoint links exactly once", attachment.link)
            assertEquals(1, lifetime.activeLinks())
            val lost = lifetime.onLost()
            assertSame("the EXACT linked endpoint is unlinked", door, lost.unlink)
            assertTrue(lost.wasLive)
            assertEquals(0, lifetime.activeLinks())
        }
        assertEquals("ONE bind for 5,000 recorded reconnects", 1, lifetime.bindAttempts)
        assertEquals(5_000, lifetime.links)
        assertEquals(5_000, lifetime.unlinks)
        assertEquals("links and unlinks stay balanced", lifetime.links, lifetime.unlinks)
    }

    @Test
    fun aDisconnectedBindingIsWaitedForNeverRebound() {
        val lifetime = RuntimeBinderLifetime<FakeBinder>()
        val door = FakeBinder("door")
        assertEquals(RuntimeBinderLifetime.Connect.BIND, lifetime.connect())
        lifetime.onConnected(door)
        // Service died, but bindService is still registered: the framework
        // reconnects the SAME dispatcher. Re-binding here would leak a
        // second ServiceDispatcher entry per reconnect (the 436 observed).
        lifetime.onLost()
        assertEquals(RuntimeBinderLifetime.Connect.WAIT_FOR_RECONNECT, lifetime.connect())
        assertEquals(RuntimeBinderLifetime.Connect.WAIT_FOR_RECONNECT, lifetime.connect())
        assertEquals(1, lifetime.bindAttempts)
        lifetime.onConnected(door)
        assertEquals(2, lifetime.links)
        assertEquals(1, lifetime.activeLinks())
    }

    @Test
    fun closeReleasesTheRegisteredBindingSoAFreshConnectionMayBind() {
        val lifetime = RuntimeBinderLifetime<FakeBinder>()
        lifetime.connect()
        lifetime.onConnected(FakeBinder("door"))
        lifetime.onLost()
        assertEquals(RuntimeBinderLifetime.Connect.WAIT_FOR_RECONNECT, lifetime.connect())
        assertTrue("close still unlinks/unbinds the registered binding", lifetime.close().unbind)
    }

    @Test
    fun binderReplacementUnlinksTheExactPreviousRecipientBeforeLinking() {
        val lifetime = RuntimeBinderLifetime<FakeBinder>()
        val old = FakeBinder("old")
        val fresh = FakeBinder("fresh")
        lifetime.connect()
        lifetime.onConnected(old)
        val attachment = lifetime.onConnected(fresh)!!
        assertTrue(attachment.link)
        assertSame(old, attachment.previous)
        assertEquals("the old endpoint is unlinked exactly once", 1, lifetime.unlinks)
        assertEquals(2, lifetime.links)
        assertEquals(1, lifetime.activeLinks())
    }

    @Test
    fun duplicateCallbackForTheSameBinderNeverRegistersTwice() {
        val lifetime = RuntimeBinderLifetime<FakeBinder>()
        val door = FakeBinder("door")
        lifetime.connect()
        lifetime.onConnected(door)
        val duplicate = lifetime.onConnected(door)!!
        assertFalse("same endpoint must not link again", duplicate.link)
        assertNull(duplicate.previous)
        assertEquals(1, lifetime.links)
        assertEquals(0, lifetime.unlinks)
        assertEquals(1, lifetime.activeLinks())
    }

    @Test
    fun retiredDeathCallbackCannotDiscardReplacement() {
        val lifetime = RuntimeBinderLifetime<FakeBinder>()
        val old = FakeBinder("old")
        val fresh = FakeBinder("fresh")
        lifetime.connect()
        val first = lifetime.onConnected(old)!!
        lifetime.onConnected(fresh)
        val stale = lifetime.onLost(old, first.generation)
        assertFalse(stale.wasLive)
        assertNull(stale.unlink)
        assertSame(fresh, lifetime.liveEndpoint())
        assertEquals(1, lifetime.activeLinks())
    }

    @Test
    fun priorRegistrationCannotDiscardReconnectedSameBinder() {
        val lifetime = RuntimeBinderLifetime<FakeBinder>()
        val door = FakeBinder("door")
        lifetime.connect()
        val first = lifetime.onConnected(door)!!
        lifetime.onLost(door, first.generation)
        val second = lifetime.onConnected(door)!!
        val duplicate = lifetime.onConnected(door)!!
        assertEquals(second.generation, duplicate.generation)
        assertFalse(lifetime.onLost(door, first.generation).wasLive)
        assertSame(door, lifetime.liveEndpoint())
        assertTrue(lifetime.onLost(door, second.generation).wasLive)
    }

    @Test
    fun closeUnlinksAndUnbindsExactlyOnce() {
        val lifetime = RuntimeBinderLifetime<FakeBinder>()
        val door = FakeBinder("door")
        lifetime.connect()
        lifetime.onConnected(door)
        val teardown = lifetime.close()
        assertSame(door, teardown.unlink)
        assertTrue(teardown.unbind)
        assertTrue(lifetime.isClosed())
        assertEquals(0, lifetime.activeLinks())
        val again = lifetime.close()
        assertNull("close is idempotent", again.unlink)
        assertFalse(again.unbind)
        assertEquals(1, lifetime.unlinks)
    }

    @Test
    fun aLateConnectedCallbackAfterCloseNeverLinksOrPublishes() {
        val lifetime = RuntimeBinderLifetime<FakeBinder>()
        lifetime.connect()
        lifetime.close()
        assertNull(lifetime.onConnected(FakeBinder("late")))
        assertEquals(0, lifetime.links)
        assertEquals(0, lifetime.activeLinks())
        assertNull(lifetime.liveEndpoint())
        assertEquals(RuntimeBinderLifetime.Connect.CLOSED, lifetime.connect())
    }

    @Test
    fun aLateLossAfterCloseReportsNothing() {
        val lifetime = RuntimeBinderLifetime<FakeBinder>()
        val door = FakeBinder("door")
        lifetime.connect()
        lifetime.onConnected(door)
        lifetime.close()
        val late = lifetime.onLost()
        assertNull("close already unlinked the exact recipient", late.unlink)
        assertFalse("a closed connection has no live endpoint", late.wasLive)
        assertEquals(0, lifetime.activeLinks())
    }

    @Test
    fun aWaiterTimeoutIsNotATransportLoss() {
        val pending = java.util.concurrent.ExecutionException(
            IllegalStateException(RuntimeConnection.CONNECT_TIMEOUT_MESSAGE))
        assertTrue("the coalesced waiter timeout must keep the binding", RuntimeConnection.isConnectWaitTimeout(pending))
        assertTrue(RuntimeConnection.isConnectWaitTimeout(java.util.concurrent.TimeoutException()))
        assertFalse(
            "a refused handshake must be dropped",
            RuntimeConnection.isConnectWaitTimeout(IllegalStateException("Runtime component unavailable")),
        )
        assertFalse(RuntimeConnection.isConnectWaitTimeout(RuntimeTransportFailure("binder died")))
        assertFalse(RuntimeConnection.isConnectWaitTimeout(null))
    }

    @Test
    fun aRefusedBindFreesTheNextBindAttempt() {
        val lifetime = RuntimeBinderLifetime<FakeBinder>()
        assertEquals(RuntimeBinderLifetime.Connect.BIND, lifetime.connect())
        lifetime.bindRefused()
        assertEquals(RuntimeBinderLifetime.Connect.BIND, lifetime.connect())
        assertEquals(2, lifetime.bindAttempts)
    }
}
