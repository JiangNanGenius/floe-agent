// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class RuntimeHostSubmitFenceTest {
    private fun request() = HostCommandRequest(
        command = "config.providers.list",
        scope = HostScope.ApplicationConfiguration("providers"),
        stateful = false,
        correlationID = "fence-test",
    )

    @Test
    fun queuedFenceIsCheckedAtExchangeAndRejectsRevokedOwner() = runBlocking {
        val executor = Executors.newSingleThreadExecutor()
        val dispatcher = executor.asCoroutineDispatcher()
        val held = CountDownLatch(1)
        val release = CountDownLatch(1)
        val calls = AtomicInteger()
        try {
            executor.execute { held.countDown(); release.await() }
            assertTrue(held.await(5, TimeUnit.SECONDS))
            val client = RuntimeHostCommandClient(
                exchange = object : HostBridgeExchange {
                    override fun exchange(request: String): String { calls.incrementAndGet(); return "{}" }
                },
                scope = CoroutineScope(Dispatchers.Default),
                ioDispatcher = dispatcher,
            )
            val current = AtomicBoolean(true)
            val result = async(start = CoroutineStart.UNDISPATCHED) {
                client.submit(request(), beforeSubmit = { current.get() })
            }
            current.set(false)
            release.countDown()
            assertEquals(HostSubmitResult.Rejected("not_submitted"), result.await())
            assertEquals(0, calls.get())
            assertFalse(client.ownsCorrelation("fence-test"))
        } finally {
            release.countDown()
            dispatcher.close()
            executor.shutdownNow()
        }
    }

    @Test
    fun callbackFailureRejectsButCancellationAfterExchangeIsNotClaimedUnsubmitted() = runBlocking {
        val calls = AtomicInteger()
        val client = RuntimeHostCommandClient(
            exchange = object : HostBridgeExchange {
                override fun exchange(request: String): String {
                    calls.incrementAndGet()
                    throw CancellationException("test")
                }
            },
            scope = CoroutineScope(Dispatchers.Default),
            ioDispatcher = Dispatchers.IO,
        )
        assertEquals(HostSubmitResult.Rejected("not_submitted"), client.submit(request()) { error("fence") })
        assertEquals(0, calls.get())
        assertEquals(HostSubmitResult.Superseded, client.submit(request()) { true })
        assertEquals(1, calls.get())
    }
}
