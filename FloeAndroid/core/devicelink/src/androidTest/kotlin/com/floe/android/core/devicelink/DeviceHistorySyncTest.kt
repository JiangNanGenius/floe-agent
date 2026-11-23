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
import com.floe.android.core.devicelink.DeviceHistorySync.Operation.PREPARE_PAGE
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
import org.junit.Assert.assertFalse
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

    // MARK: - v1 paging wire shapes (Swift donor: commit 667bfffa5)

    @Test
    fun preparePageRequestWireMatchesSwiftV1Shape() {
        val taskID = UUID.fromString("3f6f3f78-4a58-4d6b-9c1c-2f9a2a4f7e10")
        // The first request of a connection omits through entirely.
        assertEquals(
            """{"version":1,"operation":"preparePage","taskID":"$taskID"}""",
            encodeRequest(SyncRequest(PREPARE_PAGE, taskID = taskID)).decodeToString(),
        )
        assertEquals(
            """{"version":1,"operation":"preparePage","taskID":"$taskID","after":"c1"}""",
            encodeRequest(SyncRequest(PREPARE_PAGE, taskID = taskID, after = "c1")).decodeToString(),
        )
        // through is a non-negative Int64 on the wire: an integer, never a string.
        assertEquals(
            """{"version":1,"operation":"preparePage","taskID":"$taskID","after":"c1","through":41}""",
            encodeRequest(SyncRequest(PREPARE_PAGE, taskID = taskID, after = "c1", through = 41L)).decodeToString(),
        )
    }

    @Test
    fun pagedReplyWireMatchesSwiftV1Shape() {
        // Pages are announced only when supported; false stays omitted.
        assertEquals(
            """{"version":1,"offers":[],"historyPages":true}""",
            encodeReply(SyncReply(offers = emptyList(), historyPages = true)).decodeToString(),
        )
        assertEquals(
            """{"version":1,"offers":[]}""",
            encodeReply(SyncReply(offers = emptyList(), historyPages = false)).decodeToString(),
        )
        assertEquals(
            """{"version":1,"size":3,"digest":"sha256:ab","nextCursor":"n1","through":41,"hasMore":true}""",
            encodeReply(
                SyncReply(size = 3, digest = "sha256:ab", nextCursor = "n1", through = 41L, hasMore = true),
            ).decodeToString(),
        )
        // A terminal page without a nextCursor omits the key.
        assertEquals(
            """{"version":1,"size":3,"digest":"sha256:ab","through":41,"hasMore":false}""",
            encodeReply(SyncReply(size = 3, digest = "sha256:ab", through = 41L, hasMore = false)).decodeToString(),
        )
    }

    @Test
    fun decodesPagedRepliesWithOmittedKeysAndExplicitNulls() {
        val terminal = decodeReply(
            """{"version":1,"size":3,"digest":"sha256:ab","through":7,"hasMore":false}""".encodeToByteArray(),
        )
        assertNull(terminal.nextCursor)
        assertEquals(7L, terminal.through)
        assertEquals(false, terminal.hasMore)
        val pagedOffers = decodeReply("""{"version":1,"offers":[],"historyPages":true}""".encodeToByteArray())
        assertEquals(true, pagedOffers.historyPages)
        // A legacy offers reply simply omits the key.
        val legacyOffers = decodeReply("""{"version":1,"offers":[]}""".encodeToByteArray())
        assertNull(legacyOffers.historyPages)
        // Explicit nulls stay tolerated on every paging field.
        val nulled = decodeReply(
            """{"version":1,"historyPages":null,"nextCursor":null,"through":null,"hasMore":null}"""
                .encodeToByteArray(),
        )
        assertNull(nulled.historyPages)
        assertNull(nulled.nextCursor)
        assertNull(nulled.through)
        assertNull(nulled.hasMore)
    }

    @Test
    fun decodesTypedCursorFailure() {
        assertReplyFailure("""{"version":1,"failure":"cursorExpired"}""", DeviceHistorySyncError.CURSOR_EXPIRED)
        // Unknown values keep collapsing to invalidResponse.
        assertReplyFailure("""{"version":1,"failure":"malformed"}""", DeviceHistorySyncError.INVALID_RESPONSE)
    }

    @Test
    fun rejectsMismatchedPagedWireValues() {
        val taskID = UUID.fromString("3f6f3f78-4a58-4d6b-9c1c-2f9a2a4f7e10")
        // Cursors are strings and through is an integer; no coercion anywhere.
        assertRequestDecodeFails("""{"version":1,"operation":"preparePage","taskID":"$taskID","after":5}""")
        assertRequestDecodeFails("""{"version":1,"operation":"preparePage","taskID":"$taskID","through":"41"}""")
        assertRequestDecodeFails("""{"version":1,"operation":"preparePage","taskID":"$taskID","through":4.5}""")
        assertReplyDecodeFails("""{"version":1,"hasMore":"yes"}""")
        assertReplyDecodeFails("""{"version":1,"nextCursor":5}""")
        assertReplyDecodeFails("""{"version":1,"through":"41"}""")
        assertReplyDecodeFails("""{"version":1,"through":4.5}""")
        assertReplyDecodeFails("""{"version":1,"historyPages":"yes"}""")
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
            assertEquals(setOf("https://relay.example/"), link.relayUrls)
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
            override suspend fun export(taskId: UUID, version: Int): ByteArray = archive.copyOf()
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
            override suspend fun export(taskId: UUID, version: Int): ByteArray = byteArrayOf(1, 2, 3)
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
            } catch (error: DeviceHistorySyncException) {
                assertEquals(DeviceHistorySyncError.DISCONNECTED, error.error)
            }
        }
    }

    @Test
    fun oversizedExportIsRejectedWithTooLarge() = runBlocking {
        val taskID = UUID.fromString("70a79f52-6fa4-4b52-9d0c-1c4a9b1d2e3f")
        val source = object : DeviceHistorySource {
            override suspend fun offers(allowed: Set<UUID>): List<DeviceHistoryOffer> =
                listOf(DeviceHistoryOffer(taskID, "big"))
            override suspend fun export(taskId: UUID, version: Int): ByteArray =
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
            override suspend fun export(taskId: UUID, version: Int): ByteArray = byteArrayOf(9)
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

    // MARK: - v1 paging over loopback

    @Test
    fun catalogExposesOffersAndPageCapability() = runBlocking {
        val taskID = UUID.fromString("70a79f52-6fa4-4b52-9d0c-1c4a9b1d2e3f")
        val paged = FakePagedSource(taskID, ByteArray(64 * 1024) { it.toByte() }, pageSize = 16 * 1024)
        withSyncPair(paged, sharedWithClient = setOf(taskID)) { _, clientSync, serverLink, _ ->
            val catalog = clientSync.catalog(loopbackAddress(serverLink))
            assertEquals(listOf(DeviceHistoryOffer(taskID, "旅行")), catalog.offers)
            assertTrue(catalog.historyPages)
            // The existing offers API keeps working through the same exchange.
            assertEquals(catalog.offers, clientSync.offers(loopbackAddress(serverLink)))
        }
        // A legacy (non-paged) source keeps the exact v1 offers reply.
        val legacy = object : DeviceHistorySource {
            override suspend fun offers(allowed: Set<UUID>): List<DeviceHistoryOffer> =
                allowed.map { DeviceHistoryOffer(it, "标题 $it") }
            override suspend fun export(taskId: UUID, version: Int): ByteArray = byteArrayOf(1, 2, 3)
        }
        withSyncPair(legacy, sharedWithClient = setOf(taskID)) { _, clientSync, serverLink, _ ->
            val catalog = clientSync.catalog(loopbackAddress(serverLink))
            assertEquals(listOf(DeviceHistoryOffer(taskID, "标题 $taskID")), catalog.offers)
            assertFalse(catalog.historyPages)
        }
    }

    @Test
    fun pagedLoopbackPullsAllPagesWithStableUpperBound() = runBlocking {
        val taskID = UUID.fromString("70a79f52-6fa4-4b52-9d0c-1c4a9b1d2e3f")
        // 800 KiB spans three 300 KiB pages and three 384 KiB chunk frames.
        val archive = ByteArray(800 * 1024) { (it % 253).toByte() }
        val source = FakePagedSource(taskID, archive, pageSize = 300 * 1024)
        withSyncPair(source, sharedWithClient = setOf(taskID)) { _, clientSync, serverLink, _ ->
            val pages = mutableListOf<DeviceHistoryPage>()
            assertTrue(clientSync.historyPages(taskID, loopbackAddress(serverLink), null) { pages += it })
            assertEquals(3, pages.size)
            assertEquals(listOf(true, true, false), pages.map { it.hasMore })
            assertEquals(listOf(41L, 41L, 41L), pages.map { it.through })
            assertEquals(listOf("c307200", "c614400", "c819200"), pages.map { it.nextCursor })
            assertArrayEquals(archive, pages.fold(ByteArray(0)) { acc, page -> acc + page.bytes })
            // First request omits through; later pages echo it unchanged.
            assertEquals(
                listOf(
                    FakePagedSource.Call(null, null),
                    FakePagedSource.Call("c307200", 41L),
                    FakePagedSource.Call("c614400", 41L),
                ),
                source.calls,
            )
        }
    }

    @Test
    fun firstPageOfEmptyConversationOmitsCursor() = runBlocking {
        val taskID = UUID.fromString("70a79f52-6fa4-4b52-9d0c-1c4a9b1d2e3f")
        // The canonical archive JSON is non-empty even for an empty page.
        val source = FakePagedSource(taskID, ByteArray(0), pageSize = 1024)
        withSyncPair(source, sharedWithClient = setOf(taskID)) { _, clientSync, serverLink, _ ->
            val pages = mutableListOf<DeviceHistoryPage>()
            assertTrue(clientSync.historyPages(taskID, loopbackAddress(serverLink), null) { pages += it })
            assertEquals(1, pages.size)
            assertEquals(false, pages[0].hasMore)
            assertNull(pages[0].nextCursor)
            assertEquals("[]", pages[0].bytes.decodeToString())
            assertEquals(listOf(FakePagedSource.Call(null, null)), source.calls)
        }
    }

    @Test
    fun nothingNewTerminalPageEchoesResumeCursor() = runBlocking {
        val taskID = UUID.fromString("70a79f52-6fa4-4b52-9d0c-1c4a9b1d2e3f")
        val archive = ByteArray(600 * 1024) { (it % 251).toByte() }
        val source = FakePagedSource(taskID, archive, pageSize = 300 * 1024)
        // Seed the end cursor as if a previous transfer had reached it.
        source.registerCursor("c614400", 600 * 1024)
        withSyncPair(source, sharedWithClient = setOf(taskID)) { _, clientSync, serverLink, _ ->
            // Resume exactly at the end: a nothing-new terminal page is legal
            // and echoes the incoming cursor instead of a fresh one.
            val pages = mutableListOf<DeviceHistoryPage>()
            assertTrue(
                clientSync.historyPages(taskID, loopbackAddress(serverLink), "c614400") { pages += it },
            )
            assertEquals(1, pages.size)
            assertEquals(false, pages[0].hasMore)
            assertEquals("c614400", pages[0].nextCursor)
            assertEquals("[]", pages[0].bytes.decodeToString())
            assertEquals(listOf(FakePagedSource.Call("c614400", null)), source.calls)
        }
    }

    @Test
    fun resumeAfterExpiryStartsFreshConnectionWithoutThrough() = runBlocking {
        val taskID = UUID.fromString("70a79f52-6fa4-4b52-9d0c-1c4a9b1d2e3f")
        val archive = ByteArray(800 * 1024) { (it % 253).toByte() }
        val source = FakePagedSource(taskID, archive, pageSize = 300 * 1024)
        source.failure = { call ->
            if (call.after == "c307200" && call.through != null) {
                DeviceHistorySyncException(DeviceHistorySyncError.CURSOR_EXPIRED)
            } else {
                null
            }
        }
        withSyncPair(source, sharedWithClient = setOf(taskID)) { _, clientSync, serverLink, _ ->
            val address = loopbackAddress(serverLink)
            // Phase one: page one commits, then the mid-transfer expiry aborts.
            val firstPages = mutableListOf<DeviceHistoryPage>()
            val failure: DeviceHistorySyncException = try {
                clientSync.historyPages(taskID, address, null) { firstPages += it }
                fail("Expected cursorExpired")
                throw AssertionError("unreachable")
            } catch (failure: DeviceHistorySyncException) {
                failure
            }
            assertEquals(DeviceHistorySyncError.CURSOR_EXPIRED, failure.error)
            // A mid-transfer expiry is not restartable: only a refused first
            // preparePage carrying a resume cursor gets the short-circuit.
            assertFalse(failure.restartableCursor)
            assertEquals(1, firstPages.size)
            assertEquals(listOf(FakePagedSource.Call(null, null), FakePagedSource.Call("c307200", 41L)), source.calls)
            // Phase two: a new attempt resumes from the last committed cursor
            // and sends no prior through on its first request.
            val resumedPages = mutableListOf<DeviceHistoryPage>()
            assertTrue(clientSync.historyPages(taskID, address, "c307200") { resumedPages += it })
            assertEquals(2, resumedPages.size)
            assertEquals(listOf("c614400", "c819200"), resumedPages.map { it.nextCursor })
            assertEquals(
                listOf(
                    FakePagedSource.Call(null, null),
                    FakePagedSource.Call("c307200", 41L),
                    FakePagedSource.Call("c307200", null),
                    FakePagedSource.Call("c614400", 41L),
                ),
                source.calls,
            )
        }
    }

    @Test
    fun refusedFirstResumePageMarksCursorExpiredRestartable() = runBlocking {
        val taskID = UUID.fromString("70a79f52-6fa4-4b52-9d0c-1c4a9b1d2e3f")
        val source = FakePagedSource(taskID, ByteArray(1024) { it.toByte() }, pageSize = 512)
        withSyncPair(source, sharedWithClient = setOf(taskID)) { _, clientSync, serverLink, _ ->
            val failure: DeviceHistorySyncException = try {
                clientSync.historyPages(taskID, loopbackAddress(serverLink), "gone-cursor") {
                    fail("No page may be consumed")
                }
                fail("Expected cursorExpired")
                throw AssertionError("unreachable")
            } catch (failure: DeviceHistorySyncException) {
                failure
            }
            assertEquals(DeviceHistorySyncError.CURSOR_EXPIRED, failure.error)
            assertTrue(failure.restartableCursor)
            // The wire never retries implicitly: exactly one preparePage left.
            assertEquals(listOf(FakePagedSource.Call("gone-cursor", null)), source.calls)
        }
    }

    @Test
    fun legacyRemoteOffersSkipPagePullBeforeConsuming() = runBlocking {
        val taskID = UUID.fromString("70a79f52-6fa4-4b52-9d0c-1c4a9b1d2e3f")
        // A plain source cannot serve pages, so negotiation returns false
        // before any consume invocation.
        val legacy = object : DeviceHistorySource {
            override suspend fun offers(allowed: Set<UUID>): List<DeviceHistoryOffer> =
                allowed.map { DeviceHistoryOffer(it, "标题 $it") }
            override suspend fun export(taskId: UUID, version: Int): ByteArray = byteArrayOf(1, 2, 3)
        }
        withSyncPair(legacy, sharedWithClient = setOf(taskID)) { _, clientSync, serverLink, _ ->
            assertFalse(
                clientSync.historyPages(taskID, loopbackAddress(serverLink), null) {
                    fail("A legacy reply must not consume pages")
                },
            )
        }
    }

    @Test
    fun localPlainSourceRefusesPagePullWithoutConnecting() = runBlocking {
        val taskID = UUID.fromString("70a79f52-6fa4-4b52-9d0c-1c4a9b1d2e3f")
        val legacy = object : DeviceHistorySource {
            override suspend fun offers(allowed: Set<UUID>): List<DeviceHistoryOffer> = emptyList()
            override suspend fun export(taskId: UUID, version: Int): ByteArray = byteArrayOf(1)
        }
        withSyncPair(legacy, sharedWithClient = setOf(taskID)) { _, clientSync, serverLink, _ ->
            assertFalse(
                clientSync.historyPages(taskID, loopbackAddress(serverLink), null) {
                    fail("A local plain source must not consume pages")
                },
            )
        }
    }

    @Test
    fun wholeArchivePullStillWorksAgainstPagedSource() = runBlocking {
        val taskID = UUID.fromString("70a79f52-6fa4-4b52-9d0c-1c4a9b1d2e3f")
        val archive = ByteArray(1_028_631) { (it % 7).toByte() }
        val source = FakePagedSource(taskID, archive, pageSize = 64 * 1024)
        withSyncPair(source, sharedWithClient = setOf(taskID)) { _, clientSync, serverLink, _ ->
            // Legacy public paths stay byte-exact against a paging peer.
            assertEquals(listOf(DeviceHistoryOffer(taskID, "旅行")), clientSync.offers(loopbackAddress(serverLink)))
            assertArrayEquals(archive, clientSync.history(taskID, loopbackAddress(serverLink)))
            // And the paged path never touched the page source for that pull.
            assertTrue(source.calls.isEmpty())
        }
    }

    @Test
    fun notOfferedTaskFailsBeforePagePull() = runBlocking {
        val taskID = UUID.fromString("70a79f52-6fa4-4b52-9d0c-1c4a9b1d2e3f")
        val source = FakePagedSource(
            taskID, ByteArray(1024) { it.toByte() }, pageSize = 512, includeOffer = false,
        )
        withSyncPair(source, sharedWithClient = setOf(taskID)) { _, clientSync, serverLink, _ ->
            assertSyncError(DeviceHistorySyncError.NOT_SHARED) {
                clientSync.historyPages(taskID, loopbackAddress(serverLink), null) {
                    fail("A hidden task must not consume pages")
                }
            }
            assertTrue(source.calls.isEmpty())
        }
    }

    @Test
    fun invalidPreparePageFieldsGetTypedFailures() = runBlocking {
        val taskID = UUID.fromString("70a79f52-6fa4-4b52-9d0c-1c4a9b1d2e3f")
        val source = FakePagedSource(taskID, ByteArray(64 * 1024) { it.toByte() }, pageSize = 16 * 1024)
        withSyncPair(source, sharedWithClient = setOf(taskID)) { _, _, serverLink, clientLink ->
            val address = loopbackAddress(serverLink)
            // An empty resume cursor is invalidResponse, like Swift.
            clientLink.connect(address).use { connection ->
                assertReplyFailure(
                    connection.request(encodeRequest(SyncRequest(PREPARE_PAGE, taskID = taskID, after = "")))
                        .decodeToString(),
                    DeviceHistorySyncError.INVALID_RESPONSE,
                )
            }
            // Over 160 UTF-8 bytes is still invalidResponse, not a silent accept.
            clientLink.connect(address).use { connection ->
                assertReplyFailure(
                    connection.request(
                        encodeRequest(SyncRequest(PREPARE_PAGE, taskID = taskID, after = "x".repeat(161))),
                    ).decodeToString(),
                    DeviceHistorySyncError.INVALID_RESPONSE,
                )
            }
            // through must be non-negative and only accompany an after cursor.
            clientLink.connect(address).use { connection ->
                assertReplyFailure(
                    connection.request(
                        encodeRequest(SyncRequest(PREPARE_PAGE, taskID = taskID, after = "c0", through = -1L)),
                    ).decodeToString(),
                    DeviceHistorySyncError.INVALID_RESPONSE,
                )
            }
            clientLink.connect(address).use { connection ->
                assertReplyFailure(
                    connection.request(encodeRequest(SyncRequest(PREPARE_PAGE, taskID = taskID, through = 41L)))
                        .decodeToString(),
                    DeviceHistorySyncError.INVALID_RESPONSE,
                )
            }
            // preparePage never carries a chunk offset.
            clientLink.connect(address).use { connection ->
                assertReplyFailure(
                    connection.request(encodeRequest(SyncRequest(PREPARE_PAGE, taskID = taskID, offset = 0L)))
                        .decodeToString(),
                    DeviceHistorySyncError.INVALID_RESPONSE,
                )
            }
            assertTrue(source.calls.isEmpty())
        }
    }

    @Test
    fun revocationBetweenPagesStopsWithNotShared() = runBlocking {
        val taskID = UUID.fromString("70a79f52-6fa4-4b52-9d0c-1c4a9b1d2e3f")
        val archive = ByteArray(800 * 1024) { (it % 253).toByte() }
        val source = FakePagedSource(taskID, archive, pageSize = 300 * 1024)
        withSyncPair(source, sharedWithClient = setOf(taskID)) { serverSync, clientSync, serverLink, clientLink ->
            val clientId = clientLink.address().endpointId
            val pages = mutableListOf<DeviceHistoryPage>()
            // Revoke the task while the first page commits; the next
            // preparePage must be refused even though the peer stays trusted.
            assertSyncError(DeviceHistorySyncError.NOT_SHARED) {
                clientSync.historyPages(taskID, loopbackAddress(serverLink), null) { page ->
                    pages += page
                    serverSync.replaceShares(mapOf(clientId to emptySet()))
                }
            }
            assertEquals(1, pages.size)
            // Revocation is checked before the sender reads the next page.
            assertEquals(listOf(FakePagedSource.Call(null, null)), source.calls)
        }
    }

    @Test
    fun callbackFailureAbortsWithoutRetrying() = runBlocking {
        val taskID = UUID.fromString("70a79f52-6fa4-4b52-9d0c-1c4a9b1d2e3f")
        val archive = ByteArray(800 * 1024) { (it % 253).toByte() }
        val source = FakePagedSource(taskID, archive, pageSize = 300 * 1024)
        withSyncPair(source, sharedWithClient = setOf(taskID)) { _, clientSync, serverLink, _ ->
            val failure: IllegalStateException = try {
                clientSync.historyPages(taskID, loopbackAddress(serverLink), null) {
                    throw IllegalStateException("commit failed")
                }
                fail("Expected the callback failure to propagate")
                throw AssertionError("unreachable")
            } catch (failure: IllegalStateException) {
                failure
            }
            assertEquals("commit failed", failure.message)
            // No implicit retry: the source saw exactly one page request.
            assertEquals(1, source.calls.size)
        }
    }

    @Test
    fun hasMoreWithoutNextCursorIsRejected() = runBlocking {
        val taskID = UUID.fromString("70a79f52-6fa4-4b52-9d0c-1c4a9b1d2e3f")
        val source = FakePagedSource(taskID, ByteArray(64 * 1024) { it.toByte() }, pageSize = 16 * 1024)
        source.nextCursorOverride = { null }
        withSyncPair(source, sharedWithClient = setOf(taskID)) { _, clientSync, serverLink, _ ->
            assertSyncError(DeviceHistorySyncError.INVALID_RESPONSE) {
                clientSync.historyPages(taskID, loopbackAddress(serverLink), null) {
                    fail("A non-terminal page without a cursor must be rejected")
                }
            }
        }
    }

    @Test
    fun repeatingNextCursorIsRejected() = runBlocking {
        val taskID = UUID.fromString("70a79f52-6fa4-4b52-9d0c-1c4a9b1d2e3f")
        val archive = ByteArray(800 * 1024) { (it % 253).toByte() }
        val source = FakePagedSource(taskID, archive, pageSize = 300 * 1024)
        // Page one repeats the incoming cursor: no progress, no pull.
        source.nextCursorOverride = { it.after }
        withSyncPair(source, sharedWithClient = setOf(taskID)) { _, clientSync, serverLink, _ ->
            assertSyncError(DeviceHistorySyncError.INVALID_RESPONSE) {
                clientSync.historyPages(taskID, loopbackAddress(serverLink), null) {
                    fail("A repeating cursor must be rejected")
                }
            }
        }
    }

    @Test
    fun cursorCountBeyondUpperBoundIsRejected() = runBlocking {
        val taskID = UUID.fromString("70a79f52-6fa4-4b52-9d0c-1c4a9b1d2e3f")
        // An upper bound of one admits at most one distinct cursor; a source
        // that keeps paging past it is distrusted immediately.
        val source = FakePagedSource(taskID, ByteArray(64 * 1024) { it.toByte() }, pageSize = 16 * 1024, upperBound = 1L)
        withSyncPair(source, sharedWithClient = setOf(taskID)) { _, clientSync, serverLink, _ ->
            assertSyncError(DeviceHistorySyncError.INVALID_RESPONSE) {
                clientSync.historyPages(taskID, loopbackAddress(serverLink), null) {
                    fail("More cursors than the sequence bound must be rejected")
                }
            }
        }
    }

    @Test
    fun midTransferUpperBoundChangeIsRejected() = runBlocking {
        val taskID = UUID.fromString("70a79f52-6fa4-4b52-9d0c-1c4a9b1d2e3f")
        val archive = ByteArray(800 * 1024) { (it % 253).toByte() }
        val source = FakePagedSource(taskID, archive, pageSize = 300 * 1024)
        // The upper bound is fixed for the sequence; page two changes it.
        source.throughOverride = { call -> if (call.after == "c307200") 99L else 41L }
        withSyncPair(source, sharedWithClient = setOf(taskID)) { _, clientSync, serverLink, _ ->
            val pages = mutableListOf<DeviceHistoryPage>()
            assertSyncError(DeviceHistorySyncError.INVALID_RESPONSE) {
                clientSync.historyPages(taskID, loopbackAddress(serverLink), null) { pages += it }
            }
            assertEquals(1, pages.size)
            assertEquals(2, source.calls.size)
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

    /**
     * A deterministic paging source over a canonical archive. Pages are byte
     * ranges of [archive]; a page with nothing new carries the canonical
     * non-empty empty JSON (`[]`), echoes the incoming cursor, and omits it on
     * the very first page. Anomalies are injected per call.
     */
    private class FakePagedSource(
        private val taskID: UUID,
        private val archive: ByteArray,
        private val pageSize: Int,
        private val upperBound: Long = 41L,
        private val includeOffer: Boolean = true,
    ) : DeviceHistoryPagedSource {
        data class Call(val after: String?, val through: Long?)

        private val lock = Any()
        private val cursorOffsets = HashMap<String, Int>()
        private val callLog = ArrayList<Call>()

        val calls: List<Call>
            get() = synchronized(lock) { callLog.toList() }

        var failure: ((Call) -> DeviceHistorySyncException?)? = null
        var nextCursorOverride: ((Call) -> String?)? = null
        var throughOverride: ((Call) -> Long)? = null
        var hasMoreOverride: ((Call) -> Boolean)? = null

        fun registerCursor(cursor: String, position: Int) {
            synchronized(lock) { cursorOffsets[cursor] = position }
        }

        override suspend fun offers(allowed: Set<UUID>): List<DeviceHistoryOffer> =
            if (includeOffer && taskID in allowed) listOf(DeviceHistoryOffer(taskID, "旅行")) else emptyList()

        override suspend fun export(taskId: UUID, version: Int): ByteArray = archive.copyOf()

        override suspend fun historyPage(
            taskId: UUID, after: String?, through: Long?, version: Int,
        ): DeviceHistoryPage {
            val call = Call(after, through)
            synchronized(lock) { callLog += call }
            failure?.invoke(call)?.let { throw it }
            val start = when (after) {
                null -> 0
                else -> synchronized(lock) { cursorOffsets[after] }
                    ?: throw DeviceHistorySyncException(DeviceHistorySyncError.CURSOR_EXPIRED)
            }
            val end = minOf(start + pageSize, archive.size)
            val hasMore = end < archive.size
            val next: String? = if (hasMore || start < end) {
                // Non-terminal pages and data-bearing last pages advance to the
                // range end as the last cursor.
                val cursor = "c$end"
                synchronized(lock) { cursorOffsets[cursor] = end }
                cursor
            } else {
                // Nothing new: echo the incoming cursor; null on the first
                // page of a completely empty conversation.
                after
            }
            val overrideCursor = nextCursorOverride
            return DeviceHistoryPage(
                bytes = if (start == end) "[]".encodeToByteArray() else archive.copyOfRange(start, end),
                nextCursor = if (overrideCursor == null) next else overrideCursor(call),
                through = throughOverride?.invoke(call) ?: upperBound,
                hasMore = hasMoreOverride?.invoke(call) ?: hasMore,
            )
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
