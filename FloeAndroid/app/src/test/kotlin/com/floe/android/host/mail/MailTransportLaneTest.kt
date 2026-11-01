// SPDX-License-Identifier: MPL-2.0
//
// C06 platform-lane tests with a scripted bridge/socket. Authored source;
// NOT RUN by this lane. No real socket, TLS, credential or device is used.

package com.floe.android.host.mail

import java.io.IOException
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SSLHandshakeException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

private class FakeBridge(
    private val descriptor: String,
    private val stop: Boolean = false,
) : MailTransportBridge {
    private val claims = AtomicInteger(0)
    val completed = mutableListOf<Pair<Long, Int>>()
    var laneClosedEpoch: Long = 0
    var boundEpoch: Long = 0
    var nextCalls = 0

    override fun bind(epoch: Long): Int { boundEpoch = epoch; return 0 }
    override fun laneReady(epoch: Long): Int = 0
    override fun next(timeoutMillis: Int): Long {
        nextCalls += 1
        return if (claims.getAndIncrement() == 0) 1L else -1L
    }
    override fun describe(claim: Long): String = descriptor
    override fun takeWrite(claim: Long, length: Int): ByteArray = ByteArray(length) { it.toByte() }
    override fun complete(claim: Long, status: Int, data: ByteArray?): Int {
        completed += claim to status
        return 0
    }
    override fun shouldStop(claim: Long): Boolean = stop
    override fun cancelSession(session: Long): Int = 0
    override fun closeAll(timeoutMillis: Int): Int = 0
    override fun laneClosed(epoch: Long): Int { laneClosedEpoch = epoch; return 0 }
}

private class FakeSocket(
    private val failHandshake: Boolean = false,
    private val readPayload: ByteArray = ByteArray(0),
) : MailSocket {
    val writes = mutableListOf<ByteArray>()
    var closed = false
    var upgraded = false

    override fun upgradeTls() {
        upgraded = true
        if (failHandshake) throw SSLHandshakeException("synthetic")
    }
    override fun readSome(maxBytes: Int): ByteArray? = readPayload
    override fun writeAll(data: ByteArray) { writes += data }
    override fun close() { closed = true }
}

private class FakeSocketFactory(
    private val socket: FakeSocket,
) : MailSocketFactory {
    var opened = 0
    override fun open(
        host: String, port: Int, implicitTls: Boolean,
        connectTimeoutMillis: Int, handshakeTimeoutMillis: Int,
    ): MailSocket {
        opened += 1
        try {
            if (implicitTls) socket.upgradeTls()
            return socket
        } catch (error: Throwable) {
            socket.close()
            throw error
        }
    }
}

class MailTransportLaneTest {
    private fun descriptor(op: String, writeLength: Int = 0): String =
        """{"claim":1,"session":9,"op":"$op","host":"127.0.0.1","port":993,
           "tls":"implicitTLS","maxBytes":64,"writeLength":$writeLength,
           "timeoutMillis":5000}""".trimIndent()

    @Test
    fun opensAndSettlesOneClaimThenAcknowledgesClose() = runBlocking {
        val bridge = FakeBridge(descriptor("open"))
        val socket = FakeSocket()
        val lane = MailTransportLane(
            scope = CoroutineScope(Dispatchers.Unconfined + SupervisorJob()),
            bridge = bridge,
            socketFactory = FakeSocketFactory(socket),
        )
        assertTrue(lane.start(7))
        delay(200)
        assertTrue(lane.stop(1_000))
        assertTrue(bridge.completed.any { it.second == MailTransportStatus.OK })
        assertEquals(7L, bridge.laneClosedEpoch)
        assertTrue(socket.upgraded)
    }

    @Test
    fun tlsHandshakeFailureIsTypedAndClosesTheSocket() = runBlocking {
        val bridge = FakeBridge(descriptor("open"))
        val socket = FakeSocket(failHandshake = true)
        val lane = MailTransportLane(
            scope = CoroutineScope(Dispatchers.Unconfined + SupervisorJob()),
            bridge = bridge,
            socketFactory = FakeSocketFactory(socket),
        )
        assertTrue(lane.start(7))
        delay(200)
        assertTrue(lane.stop(1_000))
        assertTrue(bridge.completed.any { it.second == MailTransportStatus.TLS_FAILED })
        assertTrue(socket.closed)
    }

    @Test
    fun writePullsTheBoundedPayloadAndWritesIt() = runBlocking {
        val bridge = FakeBridge(descriptor("write", writeLength = 4))
        val socket = FakeSocket()
        val lane = MailTransportLane(
            scope = CoroutineScope(Dispatchers.Unconfined + SupervisorJob()),
            bridge = bridge,
            socketFactory = FakeSocketFactory(socket),
        )
        assertTrue(lane.start(7))
        delay(200)
        assertTrue(lane.stop(1_000))
        assertEquals(1, socket.writes.size)
        assertEquals(4, socket.writes[0].size)
    }

    @Test
    fun cancellationIsSettledAsCancelledWithoutAnIoClaim() = runBlocking {
        val bridge = FakeBridge(descriptor("open"), stop = true)
        val socket = FakeSocket()
        val lane = MailTransportLane(
            scope = CoroutineScope(Dispatchers.Unconfined + SupervisorJob()),
            bridge = bridge,
            socketFactory = FakeSocketFactory(socket),
        )
        assertTrue(lane.start(7))
        delay(200)
        assertTrue(lane.stop(1_000))
        assertTrue(bridge.completed.any { it.second == MailTransportStatus.CANCELLED })
        assertFalse(socket.upgraded)
    }

    @Test
    fun localNetworkGateDenialNeverOpensASocket() = runBlocking {
        val bridge = FakeBridge(descriptor("open"))
        val socket = FakeSocket()
        val factory = FakeSocketFactory(socket)
        val lane = MailTransportLane(
            scope = CoroutineScope(Dispatchers.Unconfined + SupervisorJob()),
            bridge = bridge,
            socketFactory = factory,
            lanGate = C06MailLanGate { _, _ -> false },
        )
        assertTrue(lane.start(7))
        delay(200)
        assertTrue(lane.stop(1_000))
        assertTrue(bridge.completed.any { it.second == MailTransportStatus.LOCAL_NETWORK_REQUIRED })
        assertEquals(0, factory.opened)
    }
}
