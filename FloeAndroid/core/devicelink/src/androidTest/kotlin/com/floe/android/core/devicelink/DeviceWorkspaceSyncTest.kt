// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.devicelink

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DeviceWorkspaceSyncTest {
    @Test
    fun swiftWorkspaceManifestVectorsAndLegacyOffers() {
        val empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        fun file(path: String) = DeviceWorkspaceEntry(path, DeviceWorkspaceEntry.Kind.FILE, 0, empty)
        fun rejected(vararg paths: String) = assertEquals(
            DeviceHistorySyncError.INVALID_RESPONSE,
            runCatching { DeviceWorkspaceManifest.encode(paths.map(::file)) }
                .exceptionOrNull().let { (it as? DeviceHistorySyncException)?.error },
        )
        val decomposed = file("e\u0301.txt")
        assertEquals(listOf(decomposed), DeviceWorkspaceManifest.decode(DeviceWorkspaceManifest.encode(listOf(decomposed))))
        rejected("é.txt", "e\u0301.txt")
        rejected("Demo/a", "demo/b")
        rejected("file", "file/sub")
        for (path in listOf(".Git/config", "nested/.ENV.local", "a//b", "../a", "Network/file", "photo.key")) {
            rejected(path)
        }

        val legacy = DeviceHistorySync.decodeReply(
            """{"version":1,"offers":[{"id":"$task","title":"Legacy"}]}""".encodeToByteArray(),
        )
        assertFalse(legacy.offers!!.single().workspaceFiles)
        val current = DeviceHistorySync.SyncReply(offers = listOf(DeviceHistoryOffer(task, "New", true)))
        assertTrue(DeviceHistorySync.decodeReply(DeviceHistorySync.encodeReply(current)).offers!!.single().workspaceFiles)
        val confirmation = DeviceHistorySync.SyncRequest(
            DeviceHistorySync.Operation.CONFIRM_WORKSPACE, task, indexes = listOf(0, 127),
        )
        assertEquals(listOf(0, 127), DeviceHistorySync.decodeRequest(DeviceHistorySync.encodeRequest(confirmation)).indexes)
    }

    @Test
    fun realQuicStreamsAndConfirmsMultiChunkAndEmptyFiles() = exercise { client, address, source ->
        val receiver = Receiver()
        val receipt = client.receiveFrom(address) { session ->
            assertArrayEquals(source.history, session.history(task))
            session.workspace(task, receiver)
        }
        assertEquals(DeviceWorkspaceReceipt(2, 1, 0), receipt)
        assertArrayEquals(source.payload, receiver.received.getValue("docs/file.bin"))
        assertArrayEquals(ByteArray(0), receiver.received.getValue("empty.txt"))
        assertEquals(setOf("docs/file.bin", "empty.txt"), receiver.confirmed)
        assertEquals(setOf(0, 2), source.confirmed)
        assertEquals(listOf(0L, 393_216L, 786_432L), source.offsets)

        val again = client.workspace(task, address, receiver)
        assertEquals(receipt, again)
        assertEquals(3, source.offsets.size)
    }

    @Test
    fun recoversNoFileFromAShareRevokedOnAnOpenConnection() = exercise { client, address, source ->
        val receiver = Receiver(beforeFile = { source.shared.set(false) })
        val failure = runCatching { client.workspace(task, address, receiver) }
            .exceptionOrNull() as? DeviceHistorySyncException
        assertEquals(DeviceHistorySyncError.NOT_SHARED, failure?.error)
        assertFalse(receiver.received.containsKey("docs/file.bin"))
        assertTrue(source.confirmed.isEmpty())
    }

    @Test
    fun aChangedChunkDoesNotReachAReceiptOrCommit() = exercise { client, address, source ->
        source.corrupt = true
        val receiver = Receiver()
        val failure = runCatching { client.workspace(task, address, receiver) }
            .exceptionOrNull() as? DeviceHistorySyncException
        assertEquals(DeviceHistorySyncError.INVALID_RESPONSE, failure?.error)
        assertFalse(receiver.received.containsKey("docs/file.bin"))
        assertTrue(source.confirmed.isEmpty())
    }

    private fun exercise(
        check: suspend (DeviceHistorySync, FloeDeviceLinkAddress, Source) -> Unit,
    ) = runBlocking {
        withTimeout(20_000) {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val right = FloeDeviceLinkIdentity.generate()
            val left = FloeDeviceLinkIdentity.generate()
            val serverLink = FloeDeviceLink.bind(context, right, setOf(left.endpointId),
                FloeDeviceLinkRelay.DISABLED, "127.0.0.1:0")
            val clientLink = FloeDeviceLink.bind(context, left, setOf(right.endpointId),
                FloeDeviceLinkRelay.DISABLED, "127.0.0.1:0")
            val source = Source()
            val server = DeviceHistorySync(serverLink, mapOf(left.endpointId to setOf(task)), source, source)
            val client = DeviceHistorySync(clientLink, mapOf(right.endpointId to emptySet()), source)
            try {
                server.start(this)
                val address = FloeDeviceLinkAddress(right.endpointId, null, listOf("127.0.0.1:${serverLink.listeningPort}"))
                check(client, address, source)
            } finally {
                client.stop()
                server.stop()
            }
        }
    }

    private class Source : DeviceWorkspaceSource, DeviceHistorySource {
        val payload = ByteArray(800 * 1024) { (it % 253).toByte() }
        val shared = AtomicBoolean(true)
        val offsets = mutableListOf<Long>()
        val confirmed = mutableSetOf<Int>()
        var corrupt = false
        override suspend fun offers(allowed: Set<UUID>) = listOf(DeviceHistoryOffer(task, "Synthetic"))
        val history = "Synthetic history".encodeToByteArray()
        override suspend fun export(taskId: UUID): ByteArray = history.copyOf()
        override suspend fun available(peer: String, task: UUID) = shared.get()
        override suspend fun prepare(peer: String, task: UUID) = object : DeviceWorkspaceSnapshot {
            override val entries = listOf(
                DeviceWorkspaceEntry("docs/file.bin", DeviceWorkspaceEntry.Kind.FILE, payload.size.toLong(),
                    DeviceWorkspaceManifest.digest(payload)),
                DeviceWorkspaceEntry("docs", DeviceWorkspaceEntry.Kind.DIRECTORY),
                DeviceWorkspaceEntry("empty.txt", DeviceWorkspaceEntry.Kind.FILE, 0,
                    DeviceWorkspaceManifest.digest(ByteArray(0))),
            )
            override suspend fun checkPermission() {
                if (!shared.get()) throw DeviceHistorySyncException(DeviceHistorySyncError.NOT_SHARED)
            }
            override suspend fun read(index: Int, offset: Long, length: Int): ByteArray {
                assertEquals(0, index)
                offsets.add(offset)
                return payload.copyOfRange(offset.toInt(), offset.toInt() + length).also {
                    if (corrupt && offset > 0) it[0] = (it[0].toInt() xor 1).toByte()
                }
            }
            override suspend fun confirm(indexes: List<Int>) { confirmed.addAll(indexes) }
            override fun close() = Unit
        }
    }

    private class Receiver(private val beforeFile: () -> Unit = {}) : DeviceWorkspaceReceiver {
        val received = mutableMapOf<String, ByteArray>()
        val confirmed = mutableSetOf<String>()
        override suspend fun accept(
            entry: DeviceWorkspaceEntry,
            download: DeviceWorkspaceDownload?,
        ): DeviceWorkspaceReceiver.Result {
            if (entry.kind == DeviceWorkspaceEntry.Kind.DIRECTORY) return DeviceWorkspaceReceiver.Result.DIRECTORY
            if (entry.path !in received) {
                if (entry.path != "empty.txt") beforeFile()
                val output = ByteArrayOutputStream()
                checkNotNull(download).to(output::write)
                received[entry.path] = output.toByteArray()
            }
            return DeviceWorkspaceReceiver.Result.AGREED
        }
        override suspend fun confirmed(entries: List<DeviceWorkspaceEntry>) {
            confirmed.addAll(entries.map { it.path })
        }
    }

    private companion object {
        val task: UUID = UUID.fromString("70a79f52-6fa4-4b52-9d0c-1c4a9b1d2e3f")
    }
}
