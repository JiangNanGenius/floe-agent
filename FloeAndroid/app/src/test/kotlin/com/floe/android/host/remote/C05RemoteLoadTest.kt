// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.remote

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import kotlinx.serialization.json.*

class C05RemoteLoadTest {
    @Test fun firstProfileLoadUsesItsOwnLaneAndLeavesLoadingState() = runBlocking {
        val requests = mutableListOf<String>()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val client = C05RemoteClient(C05RemoteTransport { raw ->
            val request = Json.parseToJsonElement(raw).jsonObject
            val operation = request.getValue("operation").jsonPrimitive.content
            requests += operation
            when (operation) {
                "c05.capabilities" -> """{"ok":true,"operation":"c05.capabilities","coreReady":true,"credentialGatewayReady":true,"epoch":7}"""
                "c05.profile.list" -> {
                    assertEquals(7L, request.getValue("owner").jsonObject.getValue("nativeEpoch").jsonPrimitive.long)
                    """{"ok":true,"operation":"c05.profile.list","hosts":[]}"""
                }
                else -> error("Unexpected request: $operation")
            }
        })
        try {
            val controller = C05RemoteHostController(scope, Dispatchers.Unconfined,
                Dispatchers.Unconfined, currentNativeEpoch = { 7L }, client = client,
                vncVideo = object : C05VNCVideoTransport {
                    override fun acquire(epoch: Long, ownerToken: String, sessionID: String): ByteArray? =
                        error("Profile loading must not acquire video")
                    override fun read(epoch: Long, leaseID: String, offset: Long,
                        target: ByteArray, targetOffset: Int, length: Int): Int = error("Unexpected video read")
                    override fun release(epoch: Long, leaseID: String): Int = error("Unexpected video release")
                })
            controller.enter()
            assertEquals(listOf("c05.capabilities", "c05.profile.list"), requests)
            assertFalse(controller.state.value.loading)
            assertTrue(controller.state.value.coreReady)
            assertTrue(controller.state.value.profiles.isEmpty())
            assertNull(controller.state.value.error)
        } finally { scope.cancel() }
    }
}
