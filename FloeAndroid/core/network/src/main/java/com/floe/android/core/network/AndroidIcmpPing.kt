// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import android.os.SystemClock
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructPollfd
import android.system.StructTimeval
import java.io.IOException
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.UnknownHostException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runInterruptible
import org.json.JSONArray
import org.json.JSONObject

/**
 * Genuine IPv4 ICMP echo over an unprivileged datagram ping socket
 * (AF_INET, SOCK_DGRAM, IPPROTO_ICMP), bound to the captured Android Network.
 * If the kernel/device denies that socket, this returns typed unsupported; it
 * never relabels a TCP connect as ping.
 */
internal object AndroidIcmpPing {
    private const val INTERVAL_MS = 1_000L
    private const val RECEIVE_BUFFER_BYTES = 2_048

    suspend fun ping(
        session: AndroidNetworkSession,
        host: String,
        count: Int,
        timeoutMs: Int,
    ): ProbeResult {
        try {
            NetworkTargetPolicy.checkHostPolicy(host)
        } catch (failure: TargetPolicyException) {
            return ProbeResult(
                status = ObservationStatus.UNSUPPORTED,
                observations = JSONObject().put("errorCode", failure.code),
                limitations = listOf(failure.message ?: "The ping target is not permitted."),
            )
        }
        val network = session.activeNetwork ?: return ProbeResult(
            status = ObservationStatus.UNAVAILABLE,
            observations = JSONObject().put("errorCode", "noActiveNetwork"),
            limitations = session.snapshot.limitations + "No active network is available for ICMP.",
        )
        val addresses = try {
            runInterruptible(Dispatchers.IO) { network.getAllByName(host).toList() }
        } catch (cancelled: java.util.concurrent.CancellationException) {
            throw cancelled
        } catch (_: UnknownHostException) {
            return ProbeResult(
                status = ObservationStatus.UNAVAILABLE,
                observations = JSONObject().put("errorCode", "dnsFailure"),
                limitations = session.snapshot.limitations +
                    "The target name did not resolve on the captured network.",
                target = host,
            )
        } catch (failure: Exception) {
            return ProbeResult(
                status = ObservationStatus.ERROR,
                observations = JSONObject().put("errorCode", "dnsFailure")
                    .put("errorClass", failure.javaClass.simpleName.take(64)),
                limitations = session.snapshot.limitations + "The target name could not be resolved.",
                target = host,
            )
        }

        val literals = addresses.mapNotNull { it.hostAddress }
        val local = try {
            NetworkTargetPolicy.checkResolvedAddresses(host, literals)
        } catch (failure: TargetPolicyException) {
            return ProbeResult(
                status = if (failure.code == "dnsFailure") {
                    ObservationStatus.UNAVAILABLE
                } else {
                    ObservationStatus.UNSUPPORTED
                },
                observations = JSONObject().put("errorCode", failure.code),
                limitations = listOf(failure.message ?: "A resolved address is not permitted."),
                target = host,
            )
        }
        if (local && session.localNetworkPermissionMissing()) {
            return ProbeResult(
                status = ObservationStatus.PERMISSION_REQUIRED,
                observations = JSONObject().put("requiredFor", NetworkMethod.PING.wire),
                limitations = session.snapshot.limitations +
                    "A local-network diagnostic needs the shared ACCESS_LOCAL_NETWORK grant.",
                target = host,
                missingPermissions = session.localNetworkMissingPermissions(),
            )
        }
        val address = addresses.filterIsInstance<Inet4Address>().firstOrNull()
            ?: return ProbeResult(
                status = ObservationStatus.UNSUPPORTED,
                observations = JSONObject()
                    .put("unsupportedReason", "icmpv6NotImplemented")
                    .put("resolvedAddresses", JSONArray().apply { literals.forEach { put(it) } }),
                limitations = listOf(
                    "This batch implements genuine IPv4 ICMP echo only; use tcpProbe or dnsLookup for IPv6 targets.",
                ),
                target = host,
            )

        val fd = try {
            Os.socket(OsConstants.AF_INET, OsConstants.SOCK_DGRAM, OsConstants.IPPROTO_ICMP)
        } catch (failure: ErrnoException) {
            return unsupportedSocket(failure, host)
        } catch (failure: Exception) {
            return ProbeResult(
                status = ObservationStatus.ERROR,
                observations = JSONObject()
                    .put("errorCode", "icmpSocketFailed")
                    .put("errorClass", failure.javaClass.simpleName.take(64)),
                limitations = session.snapshot.limitations +
                    "The unprivileged ICMP socket could not be created.",
                target = host,
            )
        }
        session.trackAction { runCatching { Os.close(fd) } }
        try {
            network.bindSocket(fd)
        } catch (failure: Exception) {
            return ProbeResult(
                status = ObservationStatus.UNAVAILABLE,
                observations = JSONObject()
                    .put("errorCode", "networkBindFailed")
                    .put("errorClass", failure.javaClass.simpleName.take(64)),
                limitations = session.snapshot.limitations +
                    "The ICMP socket could not be bound to the captured Network; no default-network fallback is used.",
                target = host,
            )
        }
        val timeoutLimit = try {
            Os.setsockoptTimeval(
                fd,
                OsConstants.SOL_SOCKET,
                OsConstants.SO_RCVTIMEO,
                StructTimeval.fromMillis(INTERVAL_MS),
            )
            true
        } catch (_: Exception) {
            false
        }
        return try {
            probeLoop(session, fd, address, host, count, timeoutMs, timeoutLimit)
        } catch (cancelled: java.util.concurrent.CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            ProbeResult(
                status = ObservationStatus.ERROR,
                observations = JSONObject()
                    .put("errorCode", "icmpProbeFailed")
                    .put("errorClass", failure.javaClass.simpleName.take(64)),
                limitations = session.snapshot.limitations + "The ICMP probe failed before a measurement was completed.",
                target = host,
            )
        } finally {
            runCatching { Os.close(fd) }
        }
    }

    private suspend fun probeLoop(
        session: AndroidNetworkSession,
        fd: java.io.FileDescriptor,
        address: Inet4Address,
        host: String,
        count: Int,
        timeoutMs: Int,
        receiveTimeoutSet: Boolean,
    ): ProbeResult {
        val started = SystemClock.elapsedRealtime()
        val budget = timeoutMs.toLong()
        val probes = JSONArray()
        val rtts = ArrayList<Double>()
        var sent = 0
        var received = 0
        var sendFailure: Exception? = null
        val limitations = ArrayList<String>()
        limitations += "ICMP echo is IPv4-only in this batch; ICMPv6 echo is not implemented."
        limitations += "Reply TTL is not available from an unprivileged datagram ICMP socket."
        limitations += "Android may rate-limit or drop ICMP echo traffic."
        if (!receiveTimeoutSet) {
            limitations += "SO_RCVTIMEO could not be set; the poll deadline still bounds each probe."
        }

        val socketAddress = InetSocketAddress(address, 0)
        while (sent < count) {
            if (session.isSessionClosed()) {
                return ProbeResult(
                    status = ObservationStatus.CANCELLED,
                    observations = JSONObject().put("cancelled", true),
                    limitations = limitations,
                    target = host,
                )
            }
            val remaining = budget - (SystemClock.elapsedRealtime() - started)
            if (remaining <= 0L) break
            val sequence = sent
            val token = java.util.Random().nextInt()
            val timestamp = System.nanoTime()
            val packet = IcmpPacket.buildEchoRequest(sequence, timestamp, token)
            val probeStarted = System.nanoTime()
            val written = try {
                Os.sendto(fd, packet, 0, packet.size, 0, socketAddress)
            } catch (failure: ErrnoException) {
                sendFailure = failure
                break
            } catch (failure: Exception) {
                sendFailure = failure
                break
            }
            if (written != packet.size) {
                sendFailure = IOException("short ICMP datagram send")
                break
            }
            sent++
            val waitMs = minOf(INTERVAL_MS, remaining)
            val pollFd = StructPollfd().apply {
                this.fd = fd
                events = OsConstants.POLLIN.toShort()
            }
            val polled = try {
                Os.poll(arrayOf(pollFd), waitMs.toInt())
            } catch (failure: ErrnoException) {
                if (session.isSessionClosed()) {
                    return ProbeResult(
                        status = ObservationStatus.CANCELLED,
                        observations = JSONObject().put("cancelled", true),
                        limitations = limitations,
                        target = host,
                    )
                }
                sendFailure = failure
                break
            }
            var reply: IcmpPacket.EchoReply? = null
            var replyFrom: String? = null
            if (polled > 0 && (pollFd.revents.toInt() and OsConstants.POLLIN) != 0) {
                val buffer = ByteArray(RECEIVE_BUFFER_BYTES)
                val source = InetSocketAddress("0.0.0.0", 0)
                val read = try {
                    Os.recvfrom(fd, buffer, 0, buffer.size, 0, source)
                } catch (_: Exception) {
                    -1
                }
                if (read > 0) {
                    reply = IcmpPacket.parseEchoReply(buffer.copyOf(read), sequence, token)
                    if (reply != null) replyFrom = source.address?.hostAddress
                }
            }
            if (reply != null) {
                val rttMs = (System.nanoTime() - reply.timestampNanos) / 1_000_000.0
                rtts += rttMs
                received++
                probes.put(
                    JSONObject()
                        .put("sequence", sequence)
                        .put("replied", true)
                        .put("rttMs", rttMs)
                        .apply { replyFrom?.let { put("replyFrom", it) } },
                )
            } else {
                probes.put(
                    JSONObject()
                        .put("sequence", sequence)
                        .put("replied", false),
                )
            }
            val elapsedInProbe = (System.nanoTime() - probeStarted) / 1_000_000L
            if (sent < count) {
                val sleep = minOf(
                    INTERVAL_MS - elapsedInProbe,
                    budget - (SystemClock.elapsedRealtime() - started),
                )
                if (sleep > 0L) delay(sleep)
            }
        }

        val lost = sent - received
        val lossPercent = if (sent > 0) lost * 100.0 / sent else 0.0
        val observations = JSONObject().apply {
            put("resolvedAddress", address.hostAddress)
            put("family", "IPv4")
            put("countRequested", count)
            put("sent", sent)
            put("received", received)
            put("lost", lost)
            put("packetLossPercent", lossPercent)
            put("timeoutBudgetMs", timeoutMs)
            put("probeIntervalMs", INTERVAL_MS)
            put("socketType", "unprivilegedDatagram")
            put("probes", probes)
            rtts.minOrNull()?.let { put("rttMinMs", it) }
            rtts.maxOrNull()?.let { put("rttMaxMs", it) }
            if (rtts.isNotEmpty()) put("rttAvgMs", rtts.average())
            if (sendFailure != null) {
                put("sendErrorClass", sendFailure!!.javaClass.simpleName.take(64))
            }
        }
        if (sent < count) {
            limitations += "The timeout budget allowed $sent of $count requested probes."
        }
        if (sendFailure != null) {
            limitations += "ICMP send stopped after $sent probes: ${sendFailure!!.javaClass.simpleName}."
        }
        val status = when {
            sendFailure != null && received > 0 -> ObservationStatus.OK
            sendFailure != null -> statusForSendFailure(sendFailure)
            received > 0 -> ObservationStatus.OK
            sent > 0 -> ObservationStatus.TIMEOUT
            else -> ObservationStatus.ERROR
        }
        if (received == 0 && sent > 0) {
            limitations += "No ICMP echo reply was received within the bounded probe window."
        }
        return ProbeResult(
            status = status,
            observations = observations,
            limitations = limitations,
            target = host,
        )
    }

    private fun statusForSendFailure(failure: Exception?): ObservationStatus = when {
        failure is ErrnoException && (failure.errno == OsConstants.EACCES || failure.errno == OsConstants.EPERM) ->
            ObservationStatus.UNSUPPORTED
        failure is ErrnoException && (failure.errno == OsConstants.ENETUNREACH || failure.errno == OsConstants.EHOSTUNREACH) ->
            ObservationStatus.UNAVAILABLE
        else -> ObservationStatus.ERROR
    }

    private fun unsupportedSocket(failure: ErrnoException, host: String): ProbeResult {
        val denied = failure.errno == OsConstants.EACCES || failure.errno == OsConstants.EPERM
        return ProbeResult(
            status = if (denied) ObservationStatus.UNSUPPORTED else ObservationStatus.ERROR,
            observations = JSONObject()
                .put("errorCode", if (denied) "icmpSocketDenied" else "icmpSocketFailed")
                .put("errno", failure.errno),
            limitations = listOf(
                if (denied) {
                    "The OS denied the unprivileged ICMP datagram socket; no TCP substitute is reported as ping."
                } else {
                    "The unprivileged ICMP datagram socket could not be created."
                },
            ),
            target = host,
        )
    }
}
