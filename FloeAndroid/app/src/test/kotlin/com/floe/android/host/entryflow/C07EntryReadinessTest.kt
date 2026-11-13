// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.entryflow

import com.floe.android.host.RuntimeHostReadiness
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class C07EntryReadinessTest {
    @Test
    fun coldTaskRouteWaitsForBothStoreAndRegisteredConversationDomain() = runBlocking {
        withTimeout(2_000) {
            val state = MutableStateFlow(RuntimeHostReadiness())
            val waiting = async(start = CoroutineStart.UNDISPATCHED) {
                awaitC07EntryReadiness(state, conversation = true)
            }
            assertFalse(waiting.isCompleted)
            state.value = state.value.copy(store = RuntimeHostReadiness.StoreReadiness.OwnedStoreReady)
            yield()
            assertFalse(waiting.isCompleted)
            state.value = state.value.copy(domains = mapOf(
                "conversationDomain" to RuntimeHostReadiness.DomainReadiness.Available(1),
            ))
            assertTrue(waiting.await())
        }
    }

    @Test
    fun scheduleOnlyRequiresItsStoreAndActualBootstrapFailureIsTerminal() = runBlocking {
        val ready = MutableStateFlow(RuntimeHostReadiness(
            store = RuntimeHostReadiness.StoreReadiness.OwnedStoreReady,
        ))
        assertTrue(awaitC07EntryReadiness(ready, conversation = false))
        val failed = MutableStateFlow(RuntimeHostReadiness(
            store = RuntimeHostReadiness.StoreReadiness.Failed("fixture"),
        ))
        assertFalse(awaitC07EntryReadiness(failed, conversation = true))
    }

    @Test
    fun cancelledReturnDoesNotWaitOrReadAnotherTask() = runBlocking {
        val state = MutableStateFlow(RuntimeHostReadiness())
        val waiting = async(start = CoroutineStart.UNDISPATCHED) {
            awaitC07EntryReadiness(state, conversation = true)
        }
        waiting.cancelAndJoin()
        assertTrue(waiting.isCancelled)
    }
}
