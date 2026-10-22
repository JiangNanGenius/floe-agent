// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.resolver

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.PortUnreachableException
import java.net.SocketException
import java.net.SocketTimeoutException

/**
 * Bounded, read-only reachability probe for the netd DNS-proxy listener
 * shape (the loopback addresses LinkProperties reports when the system
 * routes DNS through its own encrypted/private resolver). Pure java.net:
 * nothing but the already system-assigned address and port is touched,
 * and the only payload is the synthetic reserved-bad label below.
 *
 * [port] defaults to the DNS port 53 (the only port glibc can use); the
 * override exists strictly so the probe logic itself is unit-testable on
 * a host JVM without binding privileged ports. Production callers must
 * use the default.
 */
object GuestResolverProbe {
    const val DNS_PORT = 53
    private const val WINDOW_MS = 300
    private const val MAX_SERVERS = 3

    /** Any DNS answer (regardless of rcode) proves the system listener
     *  accepts glibc-style queries from our UID, so guests can use the
     *  private-DNS path directly. Silence is UNREACHABLE, ICMP refusals
     *  are REFUSED; the caller then chooses bridge-or-fail-closed. */
    fun probeTunnel(servers: List<String>, port: Int = DNS_PORT): TunnelProbe {
        var refusedSeen = false
        var attempted = 0
        for (server in servers.take(MAX_SERVERS)) {
            val address = try {
                InetSocketAddress(InetAddress.getByName(server), port)
            } catch (_: Exception) {
                continue // defensive: callers pass verified literals
            }
            if (!address.address.isLoopbackAddress) continue // probe only the proxy shape
            attempted += 1
            val socket = try {
                DatagramSocket(null).apply {
                    connect(address)
                    soTimeout = WINDOW_MS
                }
            } catch (_: Exception) {
                refusedSeen = true
                continue
            }
            try {
                val query = buildProbeQuery()
                socket.send(DatagramPacket(query, query.size))
                val reply = ByteArray(512)
                try {
                    socket.receive(DatagramPacket(reply, reply.size))
                    return TunnelProbe.REACHABLE // any response = listener serves us
                } catch (_: SocketTimeoutException) {
                    // keep probing the remaining candidates
                } catch (_: PortUnreachableException) {
                    refusedSeen = true
                }
            } catch (_: Exception) {
                refusedSeen = true
            } finally {
                runCatching { (socket as? DatagramSocket)?.close() }
            }
        }
        if (attempted == 0) return TunnelProbe.UNREACHABLE
        return if (refusedSeen) TunnelProbe.REFUSED else TunnelProbe.UNREACHABLE
    }

    /** Query for "floe-dns-probe.invalid." type A IN: a reserved-bad label
     *  that proves transport without resolving real names. */
    fun buildProbeQuery(): ByteArray {
        val labels = listOf("floe-dns-probe", "invalid")
        val size = 12 + labels.sumOf { it.length + 1 } + 1 + 4
        val out = ByteArray(size)
        out[0] = 0xF1.toByte(); out[1] = 0x0E // fixed synthetic id
        out[2] = 0x01 // RD
        out[5] = 1 // QDCOUNT
        var cursor = 12
        for (label in labels) {
            out[cursor] = label.length.toByte(); cursor++
            label.toByteArray(Charsets.US_ASCII).copyInto(out, cursor)
            cursor += label.length
        }
        out[cursor] = 0; cursor++ // root label
        out[cursor] = 0; out[cursor + 1] = 1 // TYPE A
        out[cursor + 2] = 0; out[cursor + 3] = 1 // CLASS IN
        return out
    }
}
