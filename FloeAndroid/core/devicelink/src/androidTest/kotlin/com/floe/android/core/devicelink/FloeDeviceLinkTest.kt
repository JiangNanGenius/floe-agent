// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.devicelink

import android.os.Bundle
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.floe.android.core.devicelink.FloeDeviceLinkException.Reason
import java.net.InetSocketAddress
import java.net.Socket
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class FloeDeviceLinkTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test
    fun directExchangeChecksIdentityAndPayloadBounds() = runBlocking<Unit> {
        withEndpoints { server, client ->
            val remote = loopbackAddress(server)
            val decoded = FloeDeviceLinkAddress.fromJson(remote.toJson())
            assertEquals(remote, decoded)
            assertTrue("Android must emit the shared field name", remote.toJson().contains("\"endpointID\""))
            coroutineScope {
                val accepted = async { checkNotNull(server.acceptNext()) }
                client.connect(decoded).use { outgoing ->
                    accepted.await().use { incoming ->
                        assertEquals(remote.endpointId, outgoing.peerEndpointId)
                        assertEquals(client.address().endpointId, incoming.peerEndpointId)
                        assertTrue(outgoing.paths().any { it.isSelected && it.kind == FloeDeviceLinkPath.Kind.DIRECT })
                        val oversized = ByteArray(FloeDeviceLinkConnection.MAXIMUM_PAYLOAD_BYTES + 1)
                        assertReason(Reason.EMPTY_PAYLOAD) { outgoing.request(ByteArray(0)) }
                        assertReason(Reason.PAYLOAD_TOO_LARGE) { outgoing.request(oversized) }
                        val payload = byteArrayOf(0, 1, -1)
                        val reply = async { outgoing.request(payload) }
                        incoming.receiveRequest().use { request ->
                            assertArrayEquals(payload, request.payload)
                            assertReason(Reason.PAYLOAD_TOO_LARGE) { request.respond(oversized) }
                            request.respond(request.payload)
                            assertReason(Reason.RESPONSE_ALREADY_USED) { request.respond(payload) }
                        }
                        assertArrayEquals(payload, reply.await())
                    }
                }
            }
        }
    }

    @Test
    fun unapprovedPeersAndUnconfiguredRelaysAreRejected() = runBlocking<Unit> {
        withEndpoints(trustClient = false) { server, client ->
            assertReason(Reason.PEER_NOT_AUTHORIZED) { server.connect(loopbackAddress(client)) }
            assertReason(Reason.RELAY_NOT_ALLOWED) {
                client.connect(FloeDeviceLinkAddress(server.address().endpointId, "https://example.invalid/"))
            }
            coroutineScope {
                val accepted = async {
                    assertReason(Reason.PEER_NOT_AUTHORIZED) { server.acceptNext() }
                }
                // The server may close the connection before the dial returns.
                val outgoing = runCatching { client.connect(loopbackAddress(server)) }.getOrNull()
                try {
                    accepted.await()
                } finally {
                    outgoing?.close()
                }
            }
        }
    }

    @Test
    fun cancellingAnOutstandingRequestAllowsReconnect() = runBlocking<Unit> {
        withEndpoints { server, client ->
            val address = loopbackAddress(server)
            coroutineScope {
                val firstAccepted = async { checkNotNull(server.acceptNext()) }
                client.connect(address).use { outgoing ->
                    firstAccepted.await().use { incoming ->
                        val pending = async { outgoing.request(byteArrayOf(42)) }
                        incoming.receiveRequest().use { request ->
                            assertArrayEquals(byteArrayOf(42), request.payload)
                            pending.cancelAndJoin()
                            assertTrue(pending.isCancelled)
                        }
                    }
                }
                val secondAccepted = async { checkNotNull(server.acceptNext()) }
                client.connect(address).use { outgoing ->
                    secondAccepted.await().use { incoming ->
                        assertEquals(address.endpointId, outgoing.peerEndpointId)
                        val payload = byteArrayOf(7, 8, 9)
                        val reply = async { outgoing.request(payload) }
                        incoming.receiveRequest().use { it.respond(it.payload) }
                        assertArrayEquals(payload, reply.await())
                    }
                }
            }
        }
    }

    @Test
    fun exchangesWithMacOverPublicRelay() = runBlocking<Unit> {
        val port = InstrumentationRegistry.getArguments().getString("floeInteropPort")?.toIntOrNull()
        assumeTrue("Requires the Mac interop fixture", port != null)
        withTimeout(55_000L) {
            val identity = FloeDeviceLinkIdentity.generate()
            // The local fixture shares public pairing hints. The payload travels over the Iroh connection.
            val address = macAddress(requireNotNull(port), identity.endpointId)
            assertTrue(address.directAddresses.isEmpty())
            val link = FloeDeviceLink.bind(context, identity, setOf(address.endpointId))
            try {
                link.waitForRelayAddress()
                link.connect(address).use { connection ->
                    val before = connection.paths()
                    val payload = ByteArray(128 * 1024) { (it % 251).toByte() }
                    assertArrayEquals(payload, connection.request(payload))
                    val after = connection.paths()
                    assertTrue((before + after).any { it.kind == FloeDeviceLinkPath.Kind.RELAY && it.bytesSent > 0uL })
                    instrumentation.sendStatus(0, Bundle().apply {
                        putString("floePathBefore", before.toString())
                        putString("floePathAfter", after.toString())
                    })
                }
            } finally {
                link.close()
            }
        }
    }

    private suspend fun macAddress(port: Int, identity: String): FloeDeviceLinkAddress = withContext(Dispatchers.IO) {
        Socket().use { socket ->
            socket.soTimeout = 40_000
            socket.connect(InetSocketAddress("127.0.0.1", port), 5_000)
            socket.getOutputStream().bufferedWriter().apply {
                write(identity)
                newLine()
                flush()
            }
            FloeDeviceLinkAddress.fromJson(checkNotNull(socket.getInputStream().bufferedReader().readLine()))
        }
    }

    private suspend fun withEndpoints(
        trustClient: Boolean = true,
        operation: suspend (FloeDeviceLink, FloeDeviceLink) -> Unit,
    ) = withTimeout(15_000L) {
        val serverIdentity = FloeDeviceLinkIdentity.generate()
        val identity = FloeDeviceLinkIdentity.generate()
        val clientIdentity = FloeDeviceLinkIdentity(identity.privateKeyBytes())
        assertEquals(identity.endpointId, clientIdentity.endpointId)
        val server = FloeDeviceLink.bind(
            context, serverIdentity, if (trustClient) setOf(clientIdentity.endpointId) else emptySet(),
            FloeDeviceLinkRelay.DISABLED, "127.0.0.1:0",
        )
        try {
            val client = FloeDeviceLink.bind(
                context, clientIdentity, setOf(serverIdentity.endpointId), FloeDeviceLinkRelay.DISABLED, "127.0.0.1:0",
            )
            try {
                operation(server, client)
            } finally {
                client.close()
            }
        } finally {
            server.close()
        }
    }

    private fun loopbackAddress(endpoint: FloeDeviceLink): FloeDeviceLinkAddress = FloeDeviceLinkAddress(
        endpoint.address().endpointId,
        directAddresses = listOf(endpoint.boundSockets.first { it.startsWith("127.0.0.1:") }),
    )

    private suspend fun assertReason(reason: Reason, operation: suspend () -> Unit) {
        try {
            operation()
            fail("Expected $reason")
        } catch (error: FloeDeviceLinkException) {
            assertEquals(reason, error.reason)
        }
    }
}
