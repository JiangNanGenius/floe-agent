// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.executiontarget

import com.floe.android.RuntimeBootstrapCapability
import com.floe.android.SecretGatewayCapability
import com.floe.android.host.HostBridgeExchange
import com.floe.android.host.RuntimeHost
import com.floe.android.host.RuntimeHostCommandClient
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Blocking trusted-host replies can outlive coroutine cancellation. */
class ExecutionTargetHostControllerTest {
    private val taskA = "11111111-1111-1111-1111-111111111111"
    private val taskB = "22222222-2222-2222-2222-222222222222"

    private fun reply(task: String, canCreate: Boolean = true) =
        """{"ok":true,"taskID":"$task","canCreateInitialTarget":$canCreate,
            "remoteExecutionAllowed":false,"hasUsableLocalEnvironment":false,
            "localEnvironments":[],"remoteHosts":[]}"""

    private fun host(scope: CoroutineScope) = RuntimeHost(
        commandClient = RuntimeHostCommandClient(
            exchange = object : HostBridgeExchange {
                override fun exchange(request: String) =
                    """{"version":3,"ok":false,"code":"fixtureNoOperation"}"""
            },
            scope = scope, ioDispatcher = Dispatchers.IO,
        ),
        gatewayCapability = MutableStateFlow(SecretGatewayCapability.Loading),
        bootstrapCapability = MutableStateFlow(RuntimeBootstrapCapability.Idle),
        scope = scope, ioDispatcher = Dispatchers.IO,
    ).apply {
        nativeRootEpochReader = { 7L }
        onBootstrapCapability(RuntimeBootstrapCapability.OwnedStoreReady)
    }

    @Test
    fun lateReplyForPreviousTaskCannotReplaceNewTaskSnapshot() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val entered = CountDownLatch(1)
        val allowReturn = CountDownLatch(1)
        val returned = CountDownLatch(1)
        val controller = ExecutionTargetHostController(host(scope), C02TargetClient { request ->
            if (request.contains(taskA)) {
                entered.countDown()
                try {
                    check(allowReturn.await(3, TimeUnit.SECONDS))
                    reply(taskA)
                } finally { returned.countDown() }
            } else reply(taskB)
        })
        try {
            controller.load(taskA)
            assertTrue(entered.await(3, TimeUnit.SECONDS))
            controller.load(taskB)
            withTimeout(3_000) { controller.state.first { it.snapshot?.taskID == taskB } }
            allowReturn.countDown()
            assertTrue(returned.await(3, TimeUnit.SECONDS))
            val stale = withTimeoutOrNull(200) { controller.state.first { it.snapshot?.taskID == taskA } }
            assertNull(stale)
            assertEquals(taskB, controller.state.value.taskID)
        } finally {
            allowReturn.countDown(); controller.release(); scope.cancel()
        }
    }

    @Test
    fun refreshingSameTaskFencesTheOlderReplyAtTheSameRootGeneration() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val entered = CountDownLatch(1)
        val allowReturn = CountDownLatch(1)
        val returned = CountDownLatch(1)
        val calls = AtomicInteger()
        val controller = ExecutionTargetHostController(host(scope), C02TargetClient {
            if (calls.incrementAndGet() == 1) {
                entered.countDown()
                try {
                    check(allowReturn.await(3, TimeUnit.SECONDS))
                    reply(taskA, canCreate = false)
                } finally { returned.countDown() }
            } else reply(taskA)
        })
        try {
            controller.load(taskA)
            assertTrue(entered.await(3, TimeUnit.SECONDS))
            controller.refresh()
            withTimeout(3_000) { controller.state.first { it.snapshot?.canCreateInitialTarget == true } }
            allowReturn.countDown()
            assertTrue(returned.await(3, TimeUnit.SECONDS))
            assertNull(withTimeoutOrNull(200) {
                controller.state.first { it.snapshot?.canCreateInitialTarget == false }
            })
        } finally {
            allowReturn.countDown(); controller.release(); scope.cancel()
        }
    }

    @Test
    fun releaseFencesAnAlreadyDispatchedBlockingSnapshot() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val entered = CountDownLatch(1)
        val allowReturn = CountDownLatch(1)
        val returned = CountDownLatch(1)
        val controller = ExecutionTargetHostController(host(scope), C02TargetClient {
            entered.countDown()
            try {
                check(allowReturn.await(3, TimeUnit.SECONDS))
                reply(taskA)
            } finally { returned.countDown() }
        })
        try {
            controller.load(taskA)
            assertTrue(entered.await(3, TimeUnit.SECONDS))
            controller.release()
            allowReturn.countDown()
            assertTrue(returned.await(3, TimeUnit.SECONDS))
            assertNull(withTimeoutOrNull(200) { controller.state.first { it.snapshot != null } })
        } finally {
            allowReturn.countDown(); controller.release(); scope.cancel()
        }
    }
}
