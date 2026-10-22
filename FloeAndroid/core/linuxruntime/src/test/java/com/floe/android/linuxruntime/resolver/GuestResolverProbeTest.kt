// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.resolver

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress

/**
 * The bounded tunnel probe against real UDP behavior on the host JVM
 * (production callers use the port-53 default; the port parameter exists
 * precisely so this evidence logic is verifiable without privileged
 * binds). A synthetic answer, silence and ICMP refusal must map to
 * REACHABLE / UNREACHABLE / REFUSED.
 */
class GuestResolverProbeTest {

    private val loopback = InetAddress.getByName("127.0.0.1")

    @Test
    fun answeringListenerIsReachableAndQueryIsTheReservedProbe() {
        val listener = DatagramSocket(0, loopback)
        var captured: ByteArray? = null
        var answered = false
        val thread = Thread {
            val incoming = DatagramPacket(ByteArray(512), 512)
            try {
                listener.soTimeout = 4_000
                listener.receive(incoming)
                captured = incoming.data.copyOf(incoming.length)
                // Reflect the header with QR set + NXDOMAIN (rcode 3).
                val reply = captured!!.copyOf(12)
                reply[2] = (reply[2].toInt() or 0x80).toByte()
                reply[3] = 3
                listener.send(DatagramPacket(reply, reply.size, incoming.socketAddress))
                answered = true
            } catch (_: Exception) {
            }
        }
        thread.start()
        val outcome = GuestResolverProbe.probeTunnel(listOf("127.0.0.1"), port = listener.localPort)
        thread.join(5_000)
        listener.close()
        assertEquals(TunnelProbe.REACHABLE, outcome)
        assertTrue(answered)
        val query = captured!!
        assertEquals(1, query[5].toInt()) // QDCOUNT
        assertEquals(0xF1.toByte(), query[0]) // reserved probe id
        // "floe-dns-probe.invalid" labels present:
        val text = String(query, Charsets.ISO_8859_1)
        assertTrue(text.contains("floe-dns-probe") && text.contains("invalid"))
    }

    @Test
    fun silentBoundPortTimesOutUnreachable() {
        val sink = DatagramSocket(0, loopback) // bound but never replies
        val outcome = GuestResolverProbe.probeTunnel(listOf("127.0.0.1"), port = sink.localPort)
        sink.close()
        assertEquals(TunnelProbe.UNREACHABLE, outcome)
    }

    @Test
    fun closedPortIsRefused() {
        val transient = DatagramSocket(0, loopback)
        val deadPort = transient.localPort
        transient.close()
        val outcome = GuestResolverProbe.probeTunnel(listOf("127.0.0.1"), port = deadPort)
        assertEquals(TunnelProbe.REFUSED, outcome)
    }

    @Test
    fun nonLoopbackCandidatesAreNeverProbed() {
        val outcome = GuestResolverProbe.probeTunnel(listOf("10.255.255.1", "172.31.0.2"), port = 53)
        assertEquals(TunnelProbe.UNREACHABLE, outcome) // zero attempts => honest silence
    }

    @Test
    fun probeQueryParsesAsReservedBadNameTypeA() {
        val query = GuestResolverProbe.buildProbeQuery()
        assertEquals(1, ((query[4].toInt() and 0xFF) shl 8) or (query[5].toInt() and 0xFF)) // QDCOUNT=1
        assertEquals("floe-dns-probe".length.toByte(), query[12])
        assertEquals(0.toByte(), query[12 + "floe-dns-probe".length + 1 + "invalid".length + 1])
    }
}
