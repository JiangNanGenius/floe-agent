// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkcapture

import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.system.OsConstants
import com.github.megatronking.netbare.ip.IpHeader
import com.github.megatronking.netbare.ip.Protocol
import com.github.megatronking.netbare.proxy.ProxyServerForwarder
import com.github.megatronking.netbare.proxy.TcpProxyServerForwarder
import com.github.megatronking.netbare.proxy.UdpProxyServerForwarder
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

data class DataPlaneStart(
    val accepted: Boolean,
    val code: String? = null,
    val startedAtMillis: Long = 0L,
)

data class DataPlaneStopProof(
    val forwardersStopped: Boolean,
    val dataPlaneThreadStopped: Boolean,
    val vpnFdClosed: Boolean,
)

/**
 * The no-root data plane. A real VpnService TUN fd is read packet by packet,
 * every packet is copied to the bounded PCAP sink, and TCP/UDP are handed to
 * the pinned NetBare forwarding servers. NetBare protects each remote socket
 * with [VpnService.protect] before connecting, preventing a routing loop.
 *
 * IPv4 is captured/forwarded. IPv6 has no installed route (see [VpnPlan]) so
 * ordinary IPv6 keeps using the underlying network; an unexpected IPv6 packet
 * is counted and never forwarded. ICMP is counted as unsupported rather than
 * pretending NetBare's unimplemented ICMP forwarder works.
 */
class NetBareDataPlane(
    private val vpnService: VpnService,
    private val plan: VpnPlan,
    private val sink: PcapCaptureSink,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val stopRequested = AtomicBoolean(false)
    private val threadStopped = AtomicBoolean(false)
    private val vpnFdClosed = AtomicBoolean(false)
    private val forwardedPackets = AtomicLong(0)
    private val forwardedBytes = AtomicLong(0)
    private val failure = java.util.concurrent.atomic.AtomicReference<String?>(null)
    private val stopReason = java.util.concurrent.atomic.AtomicReference<CaptureEndReason?>(null)

    private var vpnDescriptor: ParcelFileDescriptor? = null
    private var input: FileInputStream? = null
    private var output: OutputStream? = null
    private var thread: Thread? = null
    private var tcpForwarder: ProxyServerForwarder? = null
    private var udpForwarder: ProxyServerForwarder? = null

    fun start(): DataPlaneStart {
        val builder = vpnService.Builder()
        try {
            builder.setBlocking(true)
            // No IPv6 address/route is installed. Explicitly allow that family
            // to bypass this IPv4 VPN instead of Android blocking it by default.
            builder.allowFamily(OsConstants.AF_INET6)
            builder.setMtu(plan.mtu)
            builder.addAddress(plan.address, plan.prefixLength)
            builder.setSession(plan.sessionName)
            for (route in plan.routes) {
                val (address, prefix) = route.split('/')
                builder.addRoute(address, prefix.toInt())
            }
            for (dns in plan.dnsServers) builder.addDnsServer(dns)
            for (packageName in plan.allowedPackages) {
                runCatching { builder.addAllowedApplication(packageName) }
                    .getOrElse { return DataPlaneStart(false, "allowedPackageUnavailable") }
            }
            for (packageName in plan.disallowedPackages) {
                runCatching { builder.addDisallowedApplication(packageName) }
                    .getOrElse { return DataPlaneStart(false, "disallowedPackageUnavailable") }
            }
            val descriptor = builder.establish()
                ?: return DataPlaneStart(false, "establishRefused")
            vpnDescriptor = descriptor
            val fd = descriptor.fileDescriptor
            input = FileInputStream(fd)
            val captureOutput = CaptureOutputStream(FileOutputStream(fd), sink)
            output = captureOutput

            val tcp = TcpProxyServerForwarder(vpnService, plan.address, plan.mtu)
            val udp = UdpProxyServerForwarder(vpnService, plan.mtu)
            tcpForwarder = tcp
            udpForwarder = udp
            tcp.prepare()
            udp.prepare()
            sink.start()
            thread = Thread({ runLoop() }, "floe-vpn-capture").also { it.start() }
            return DataPlaneStart(true, startedAtMillis = now())
        } catch (e: SecurityException) {
            releaseForwarders()
            closeVpn()
            return DataPlaneStart(false, "vpnPermissionDenied")
        } catch (e: IllegalStateException) {
            releaseForwarders()
            closeVpn()
            return DataPlaneStart(false, "vpnNotPrepared")
        } catch (e: IOException) {
            releaseForwarders()
            closeVpn()
            return DataPlaneStart(false, "dataPlaneStartFailed")
        }
    }

    fun requestStop(reason: CaptureEndReason) {
        stopReason.compareAndSet(null, reason)
        if (!stopRequested.compareAndSet(false, true)) return
        // Closing the TUN descriptor is what unblocks a blocking TUN read.
        // It happens only after stopRequested is visible; the state machine
        // still requires a join and sink drain before reporting completion.
        closeVpn()
        thread?.interrupt()
    }

    fun awaitStopped(timeoutMillis: Long): DataPlaneStopProof {
        require(timeoutMillis > 0) { "timeout" }
        val worker = thread
        if (worker != null) {
            worker.join(timeoutMillis)
            if (worker.isAlive) worker.interrupt()
        }
        val joined = worker?.isAlive != true
        if (joined) threadStopped.set(true)
        val tcpStopped = runCatching { tcpForwarder?.releaseAndJoin(2_000L) ?: true }
            .getOrDefault(false)
        val udpStopped = runCatching { udpForwarder?.releaseAndJoin(2_000L) ?: true }
            .getOrDefault(false)
        tcpForwarder = null
        udpForwarder = null
        return DataPlaneStopProof(
            forwardersStopped = tcpStopped && udpStopped,
            dataPlaneThreadStopped = joined,
            vpnFdClosed = vpnFdClosed.get(),
        )
    }

    fun forwardedPackets(): Long = forwardedPackets.get()
    fun forwardedBytes(): Long = forwardedBytes.get()
    fun failureCode(): String? = failure.get()
    fun requestedReason(): CaptureEndReason? = stopReason.get()
    fun isRunning(): Boolean = thread?.isAlive == true && !stopRequested.get()

    private fun runLoop() {
        val localInput = input ?: return
        val localOutput = output ?: return
        val buffer = ByteArray(plan.mtu)
        try {
            while (!stopRequested.get()) {
                val length = try {
                    localInput.read(buffer)
                } catch (e: IOException) {
                    if (!stopRequested.get()) failure.compareAndSet(null, "vpnReadFailed")
                    break
                }
                if (length < 0) break
                if (length == 0) continue
                val version = (buffer[0].toInt() and 0xF0) ushr 4
                if (version == 6) {
                    sink.noteIpv6Bypassed()
                    continue
                }
                if (version != 4 || length < IpHeader.MIN_HEADER_LENGTH) {
                    sink.noteUnsupportedPacket()
                    continue
                }
                // Capture before forwarding: a forwarding error must not erase
                // the packet evidence the user asked for.
                sink.offer(buffer, 0, length)
                val header = IpHeader(buffer, 0)
                val protocol = Protocol.parse(header.getProtocol().toInt() and 0xFF)
                val forwarder = when (protocol) {
                    Protocol.TCP -> tcpForwarder
                    Protocol.UDP -> udpForwarder
                    else -> null
                }
                if (forwarder == null) {
                    sink.noteUnsupportedPacket()
                    continue
                }
                try {
                    forwarder.forward(buffer, length, localOutput)
                } catch (e: IOException) {
                    if (!stopRequested.get()) failure.compareAndSet(null, "forwardingFailed")
                    break
                }
                sink.limitReason()?.let {
                    stopReason.compareAndSet(null, it)
                    break
                }
            }
        } finally {
            threadStopped.set(true)
        }
    }

    private fun releaseForwarders() {
        runCatching { tcpForwarder?.release() }
        runCatching { udpForwarder?.release() }
        tcpForwarder = null
        udpForwarder = null
    }

    private fun closeVpn() {
        runCatching { input?.close() }
        runCatching { output?.close() }
        val descriptorClosed = runCatching { vpnDescriptor?.close() }.isSuccess
        input = null
        output = null
        vpnDescriptor = null
        vpnFdClosed.set(descriptorClosed)
    }

    /**
     * Serializes concurrent writes from the TCP forwarder thread and the UDP
     * selector thread, copies each packet to PCAP first, then writes exactly
     * the same bytes to the TUN fd.
     */
    private inner class CaptureOutputStream(
        private val delegate: OutputStream,
        private val sink: PcapCaptureSink,
    ) : OutputStream() {
        @Synchronized
        override fun write(b: ByteArray, off: Int, len: Int) {
            sink.offer(b, off, len)
            delegate.write(b, off, len)
            forwardedPackets.incrementAndGet()
            forwardedBytes.addAndGet(len.toLong())
        }

        @Synchronized
        override fun write(b: Int) {
            val one = byteArrayOf(b.toByte())
            sink.offer(one, 0, 1)
            delegate.write(b)
            forwardedPackets.incrementAndGet()
            forwardedBytes.incrementAndGet()
        }

        override fun flush() = delegate.flush()
        override fun close() = delegate.close()
    }
}
