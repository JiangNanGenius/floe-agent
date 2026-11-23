// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.devicelink

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.floe.android.core.devicelink.DeviceHistorySync.Companion.decodeReply
import com.floe.android.core.devicelink.DeviceHistorySync.Companion.decodeRequest
import com.floe.android.core.devicelink.DeviceHistorySync.Companion.encodeReply
import com.floe.android.core.devicelink.DeviceHistorySync.Companion.encodeRequest
import com.floe.android.core.devicelink.DeviceHistorySync.Operation.CHUNK
import com.floe.android.core.devicelink.DeviceHistorySync.Operation.OFFERS
import com.floe.android.core.devicelink.DeviceHistorySync.Operation.PREPARE
import com.floe.android.core.devicelink.DeviceHistorySync.RequestDecodeException
import com.floe.android.core.devicelink.DeviceHistorySync.SyncReply
import com.floe.android.core.devicelink.DeviceHistorySync.SyncRequest
import com.floe.android.core.devicelink.FloeDeviceLinkException.Reason
import java.util.Base64
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.json.JSONArray
import org.json.JSONObject

@RunWith(AndroidJUnit4::class)
class DeviceHistorySyncTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    // MARK: - Deterministic v1 wire fixtures (Swift omits nil optionals)

    @Test
    fun requestWireMatchesSwiftV1Shape() {
        val taskID = UUID.fromString("3f6f3f78-4a58-4d6b-9c1c-2f9a2a4f7e10")
        assertEquals(
            """{"version":1,"operation":"offers"}""",
            encodeRequest(SyncRequest(OFFERS)).decodeToString(),
        )
        assertEquals(
            """{"version":1,"operation":"prepare","taskID":"$taskID"}""",
            encodeRequest(SyncRequest(PREPARE, taskID = taskID)).decodeToString(),
        )
        assertEquals(
            """{"version":1,"operation":"chunk","taskID":"$taskID","offset":5}""",
            encodeRequest(SyncRequest(CHUNK, taskID = taskID, offset = 5L)).decodeToString(),
        )
    }

    @Test
    fun replyWireMatchesSwiftV1Shape() {
        val offer = DeviceHistoryOffer(UUID.fromString("8d79e0c6-4c9b-4a1e-8f4c-2c2a6dfb6a11"), "计划")
        assertEquals(
            """{"version":1,"offers":[{"id":"${offer.id}","title":"计划"}]}""",
            encodeReply(SyncReply(offers = listOf(offer))).decodeToString(),
        )
        assertEquals(
            """{"version":1,"size":3,"digest":"sha256:ab"}""",
            encodeReply(SyncReply(size = 3, digest = "sha256:ab")).decodeToString(),
        )
        assertEquals(
            """{"version":1,"bytes":"AQI="}""",
            encodeReply(SyncReply(bytes = byteArrayOf(1, 2))).decodeToString(),
        )
        assertEquals(
            """{"version":1,"failure":"notShared"}""",
            encodeReply(SyncReply(failure = DeviceHistorySyncError.NOT_SHARED)).decodeToString(),
        )
    }

    @Test
    fun decodesSwiftStyleOmittedKeysAndExplicitNulls() {
        val id = UUID.fromString("8d79e0c6-4c9b-4a1e-8f4c-2c2a6dfb6a11")
        // Swift Codable reply for offers: nil failure/size/digest/bytes keys are absent.
        val omitted = decodeReply(
            """{"version":1,"offers":[{"id":"$id","title":"t"}]}""".encodeToByteArray(),
        )
        assertEquals(listOf(DeviceHistoryOffer(id, "t")), omitted.offers)
        assertNull(omitted.failure)
        assertNull(omitted.size)
        assertNull(omitted.digest)
        assertNull(omitted.bytes)
        // Explicit nulls (older or foreign producers) must stay tolerated.
        val nulled = decodeReply(
            """{"version":1,"failure":null,"offers":null,"size":null,"digest":null,"bytes":null}"""
                .encodeToByteArray(),
        )
        assertNull(nulled.failure)
        assertNull(nulled.offers)
        assertNull(nulled.size)
        assertNull(nulled.digest)
        assertNull(nulled.bytes)
    }

    @Test
    fun rejectsWraparoundAndMismatchedWireValues() {
        val taskID = UUID.fromString("3f6f3f78-4a58-4d6b-9c1c-2f9a2a4f7e10")
        // A double offset (1e30) wraps Long conversion; the request is dropped.
        assertRequestDecodeFails(
            """{"version":1,"operation":"chunk","taskID":"$taskID","offset":1e30}""",
        )
        // A size that wraps past a 32-bit Int is rejected.
        assertReplyDecodeFails("""{"version":1,"size":4294967296}""")
        // Unknown failure codes collapse to invalidResponse like Swift's rawValue lookup.
        assertReplyFailure("""{"version":1,"failure":"bogus"}""", DeviceHistorySyncError.INVALID_RESPONSE)
        assertReplyFailure("""{"version":2}""", DeviceHistorySyncError.UNSUPPORTED_VERSION)
        assertReplyFailure("""{"version":1,"failure":"notShared"}""", DeviceHistorySyncError.NOT_SHARED)
    }

    // MARK: - Pairing tickets

    @Test
    fun pairingTicketRoundTripsWithVerifiedFingerprint() = runBlocking {
        val identity = FloeDeviceLinkIdentity.generate()
        val address = FloeDeviceLinkAddress(
            endpointId = identity.endpointId,
            directAddresses = listOf("192.168.1.2:12345"),
        )
        val code = DeviceHistoryPairingTicket(address).code()
        assertTrue(code.startsWith("floe-device:"))
        // The ticket body is the exact Swift v1 JSON with nil keys omitted.
        val payload = Base64.getDecoder().decode(code.removePrefix("floe-device:"))
        assertEquals(
            """{"version":1,"address":{"endpointID":"${identity.endpointId}","directAddresses":["192.168.1.2:12345"]}}""",
            payload.decodeToString(),
        )
        val parsed = DeviceHistoryPairingTicket.parse("  $code \n")
        assertEquals(address, parsed.address)
        assertEquals(identity.endpointId, parsed.fingerprint)
        assertEquals(code, parsed.code())
    }

    @Test
    fun pairingTicketRejectsMismatchedApprovals() = runBlocking {
        val valid = FloeDeviceLinkIdentity.generate().endpointId
        assertTicketFails("floe-device:not-base64!!!")
        assertTicketFails("wrong:prefix")
        assertTicketFails(ticketCode(valid, version = 2), DeviceHistorySyncError.UNSUPPORTED_VERSION)
        assertTicketFails(ticketCode("not-an-endpoint-id"))
        // A relay URL over 512 bytes is not approved.
        assertTicketFails(ticketCode(valid, relayUrl = "https://" + "a".repeat(510) + ".example"))
        // A 17th direct address breaks the v1 envelope.
        val many = (0 until 17).map { "10.0.0.$it:9999" }
        assertTicketFails(ticketCode(valid, directAddresses = many))
    }

    // MARK: - Link parity: custom relay, stable port, runtime trust replacement

    @Test
    fun customRelayValidatesAndKeepsListeningPort() = runBlocking {
        val identity = FloeDeviceLinkIdentity.generate()
        val link = FloeDeviceLink.bind(
            context, identity, emptySet(), FloeDeviceLinkRelay.Custom("https://relay.example"),
            bindAddress = "127.0.0.1:0",
        )
        try {
            assertEquals(setOf("https://relay.example"), link.relayUrls)
            val port = link.listeningPort
            assertTrue(port != null && port > 0)
            assertTrue(link.boundSockets.any { it.endsWith(":$port") })
            // A trust-set change does not rebind the endpoint.
            link.replaceTrustedEndpointIDs(emptySet())
            assertEquals(port, link.listeningPort)
        } finally {
            link.close()
        }
    }

    @Test
    fun customRelayRejectsNonHttpsAndQualifiedUrls() = runBlocking {
        val identity = FloeDeviceLinkIdentity.generate()
        for (url in listOf(
            "http://relay.example",
            "https://user@relay.example",
            "https://relay.example?query=1",
            "https://relay.example#fragment",
            "not a url",
        )) {
            try {
                FloeDeviceLink.bind(context, identity, emptySet(), FloeDeviceLinkRelay.Custom(url))
                fail("Expected RELAY_NOT_ALLOWED for $url")
            } catch (error: FloeDeviceLinkException) {
                assertEquals(Reason.RELAY_NOT_ALLOWED, error.reason)
            }
        }
    }

    @Test
    fun runtimeTrustReplacementDropsRevokedPeer() = runBlocking {
        withTimeout(15_000L) {
            val serverIdentity = FloeDeviceLinkIdentity.generate()
            val clientIdentity = FloeDeviceLinkIdentity.generate()
            val server = FloeDeviceLink.bind(
                context, serverIdentity, setOf(clientIdentity.endpointId),
                FloeDeviceLinkRelay.DISABLED, "127.0.0.1:0",
            )
            val client = FloeDeviceLink.bind(
                context, clientIdentity, setOf(serverIdentity.endpointId),
                FloeDeviceLinkRelay.DISABLED, "127.0.0.1:0",
            )
            try {
                val address = loopbackAddress(server)
                exchange(client, server, address)
                server.replaceTrustedEndpointIDs(emptySet())
                try {
                    exchange(client, server, address)
                    fail("Expected PEER_NOT_AUTHORIZED after revocation")
                } catch (error: FloeDeviceLinkException) {
                    assertEquals(Reason.PEER_NOT_AUTHORIZED, error.reason)
                }
                // Re-approval immediately restores the short pull.
                server.replaceTrustedEndpointIDs(setOf(clientIdentity.endpointId))
                exchange(client, server, address)
                // Own ID in the trust set is always refused.
                try {
                    server.replaceTrustedEndpointIDs(setOf(serverIdentity.endpointId))
                    fail("Expected SELF_CONNECTION")
                } catch (error: FloeDeviceLinkException) {
                    assertEquals(Reason.SELF_CONNECTION, error.reason)
                }
            } finally {
                client.close()
                server.close()
            }
        }
    }

    // MARK: - End-to-end history wire over loopback

    @Test
    fun loopbackTransfersChunkedHistoryWithDigestCheck() = runBlocking {
        val taskID = UUID.fromString("70a79f52-6fa4-4b52-9d0c-1c4a9b1d2e3f")
        // 800 KiB spans three 384 KiB chunks.
        val archive = ByteArray(800 * 1024) { (it % 253).toByte() }
        val source = object : DeviceHistorySource {
            override suspend fun offers(allowed: Set<UUID>): List<DeviceHistoryOffer> =
                if (taskID in allowed) listOf(DeviceHistoryOffer(taskID, "旅行")) else emptyList()
            override suspend fun export(taskId: UUID): ByteArray = archive.copyOf()
        }
        withSyncPair(source, sharedWithClient = setOf(taskID)) { serverSync, clientSync, serverLink, clientLink ->
            val offers = clientSync.offers(loopbackAddress(serverLink))
            assertEquals(listOf(DeviceHistoryOffer(taskID, "旅行")), offers)
            val pulled = clientSync.history(taskID, loopbackAddress(serverLink))
            assertArrayEquals(archive, pulled)
        }
    }

    @Test
    fun mismatchedApprovalsReturnTypedFailures() = runBlocking {
        val shared = UUID.fromString("70a79f52-6fa4-4b52-9d0c-1c4a9b1d2e3f")
        val hidden = UUID.fromString("2f5a0c26-9a2d-4e21-9f55-3e8f1a2b4c6d")
        val source = object : DeviceHistorySource {
            override suspend fun offers(allowed: Set<UUID>): List<DeviceHistoryOffer> =
                allowed.map { DeviceHistoryOffer(it, "标题 $it") }
            override suspend fun export(taskId: UUID): ByteArray = byteArrayOf(1, 2, 3)
        }
        withSyncPair(source) { serverSync, clientSync, serverLink, clientLink ->
            val clientId = clientLink.address().endpointId
            // Nothing shared yet: offers empty, prepare notShared.
            assertTrue(clientSync.offers(loopbackAddress(serverLink)).isEmpty())
            assertSyncError(DeviceHistorySyncError.NOT_SHARED) {
                clientSync.history(shared, loopbackAddress(serverLink))
            }
            // Share one task; the hidden task stays notShared even though export would answer.
            serverSync.replaceShares(mapOf(clientId to setOf(shared)))
            assertEquals(
                listOf(DeviceHistoryOffer(shared, "标题 $shared")),
                clientSync.offers(loopbackAddress(serverLink)),
            )
            assertSyncError(DeviceHistorySyncError.NOT_SHARED) {
                clientSync.history(hidden, loopbackAddress(serverLink))
            }
            // Revoke the peer entirely: the next pull is refused at the connection layer.
            serverSync.replaceShares(emptyMap())
            try {
                clientSync.offers(loopbackAddress(serverLink))
                fail("Expected revocation to close unauthorized sessions")
            } catch (error: FloeDeviceLinkException) {
                assertEquals(Reason.PEER_NOT_AUTHORIZED, error.reason)
            }
        }
    }

    @Test
    fun oversizedExportIsRejectedWithTooLarge() = runBlocking {
        val taskID = UUID.fromString("70a79f52-6fa4-4b52-9d0c-1c4a9b1d2e3f")
        val source = object : DeviceHistorySource {
            override suspend fun offers(allowed: Set<UUID>): List<DeviceHistoryOffer> =
                listOf(DeviceHistoryOffer(taskID, "big"))
            override suspend fun export(taskId: UUID): ByteArray =
                ByteArray(DeviceHistorySync.MAXIMUM_ARCHIVE_BYTES + 1)
        }
        withSyncPair(source) { serverSync, clientSync, serverLink, clientLink ->
            val clientId = clientLink.address().endpointId
            serverSync.replaceShares(mapOf(clientId to setOf(taskID)))
            assertSyncError(DeviceHistorySyncError.TOO_LARGE) {
                clientSync.history(taskID, loopbackAddress(serverLink))
            }
        }
    }

    @Test
    fun stopClosesListenerAndRejectsPulls() = runBlocking {
        val taskID = UUID.fromString("70a79f52-6fa4-4b52-9d0c-1c4a9b1d2e3f")
        val source = object : DeviceHistorySource {
            override suspend fun offers(allowed: Set<UUID>): List<DeviceHistoryOffer> =
                listOf(DeviceHistoryOffer(taskID, "t"))
            override suspend fun export(taskId: UUID): ByteArray = byteArrayOf(9)
        }
        val serverIdentity = FloeDeviceLinkIdentity.generate()
        val clientIdentity = FloeDeviceLinkIdentity.generate()
        val serverLink = FloeDeviceLink.bind(
            context, serverIdentity, setOf(clientIdentity.endpointId),
            FloeDeviceLinkRelay.DISABLED, "127.0.0.1:0",
        )
        val clientLink = FloeDeviceLink.bind(
            context, clientIdentity, setOf(serverIdentity.endpointId),
            FloeDeviceLinkRelay.DISABLED, "127.0.0.1:0",
        )
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val serverSync = DeviceHistorySync(
            serverLink, mapOf(clientIdentity.endpointId to setOf(taskID)), source,
        )
        serverSync.start(scope)
        try {
            clientLink.connect(loopbackAddress(serverLink)).use { connection ->
                connection.request(encodeRequest(SyncRequest(OFFERS)))
            }
            serverSync.stop()
            assertSyncError(DeviceHistorySyncError.DISCONNECTED) {
                serverSync.offers(loopbackAddress(clientLink))
            }
        } finally {
            serverSync.stop()
            clientLink.close()
        }
    }

    // MARK: - Fixtures and helpers

    private fun ticketCode(
        endpointId: String,
        version: Int = 1,
        relayUrl: String? = null,
        directAddresses: List<String> = emptyList(),
    ): String {
        val address = JSONObject()
            .put("endpointID", endpointId)
            .put("relayURL", relayUrl)
            .put("directAddresses", JSONArray(directAddresses))
        val json = JSONObject()
            .put("version", version)
            .put("address", address)
            .toString()
            .encodeToByteArray()
        return "floe-device:" + Base64.getEncoder().encodeToString(json)
    }

    private suspend fun exchange(
        client: FloeDeviceLink,
        server: FloeDeviceLink,
        address: FloeDeviceLinkAddress,
    ) = coroutineScope {
        val accepted = async { checkNotNull(server.acceptNext()) }
        client.connect(address).use { outgoing ->
            accepted.await().use { incoming ->
                val reply = async { outgoing.request(byteArrayOf(1)) }
                incoming.receiveRequest().use { it.respond(it.payload) }
                reply.await()
            }
        }
    }

    private suspend fun loopbackAddress(endpoint: FloeDeviceLink): FloeDeviceLinkAddress = FloeDeviceLinkAddress(
        endpoint.address().endpointId,
        directAddresses = listOf(endpoint.boundSockets.first { it.startsWith("127.0.0.1:") }),
    )

    private fun assertTicketFails(code: String, error: DeviceHistorySyncError = DeviceHistorySyncError.INVALID_RESPONSE) {
        try {
            DeviceHistoryPairingTicket.parse(code)
            fail("Expected $error")
        } catch (failure: DeviceHistorySyncException) {
            assertEquals(error, failure.error)
        }
    }

    private fun assertRequestDecodeFails(payload: String) {
        try {
            decodeRequest(payload.encodeToByteArray())
            fail("Expected RequestDecodeException")
        } catch (failure: RequestDecodeException) {
        }
    }

    private fun assertReplyDecodeFails(payload: String) {
        try {
            decodeReply(payload.encodeToByteArray())
            fail("Expected INVALID_RESPONSE")
        } catch (failure: DeviceHistorySyncException) {
            assertEquals(DeviceHistorySyncError.INVALID_RESPONSE, failure.error)
        }
    }

    private fun assertReplyFailure(payload: String, error: DeviceHistorySyncError) {
        try {
            decodeReply(payload.encodeToByteArray())
            fail("Expected $error")
        } catch (failure: DeviceHistorySyncException) {
            assertEquals(error, failure.error)
        }
    }

    private suspend fun assertSyncError(error: DeviceHistorySyncError, operation: suspend () -> Unit) {
        try {
            operation()
            fail("Expected $error")
        } catch (failure: DeviceHistorySyncException) {
            assertEquals(error, failure.error)
        }
    }

    private suspend fun withSyncPair(
        source: DeviceHistorySource,
        sharedWithClient: Set<UUID> = emptySet(),
        operation: suspend (DeviceHistorySync, DeviceHistorySync, FloeDeviceLink, FloeDeviceLink) -> Unit,
    ) = withTimeout(30_000L) {
        val serverIdentity = FloeDeviceLinkIdentity.generate()
        val clientIdentity = FloeDeviceLinkIdentity.generate()
        val serverLink = FloeDeviceLink.bind(
            context, serverIdentity, setOf(clientIdentity.endpointId),
            FloeDeviceLinkRelay.DISABLED, "127.0.0.1:0",
        )
        val clientLink = FloeDeviceLink.bind(
            context, clientIdentity, setOf(serverIdentity.endpointId),
            FloeDeviceLinkRelay.DISABLED, "127.0.0.1:0",
        )
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        // The serving side authorizes shares by the connecting peer's endpoint ID.
        val serverSync = DeviceHistorySync(
            serverLink, mapOf(clientIdentity.endpointId to sharedWithClient), source,
        )
        val clientSync = DeviceHistorySync(clientLink, emptyMap(), source)
        serverSync.start(scope)
        clientSync.start(scope)
        try {
            operation(serverSync, clientSync, serverLink, clientLink)
        } finally {
            serverSync.stop()
            clientSync.stop()
        }
    }
}
