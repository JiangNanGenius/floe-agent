// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import android.os.SystemClock
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructPollfd
import java.io.IOException
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.UnknownHostException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runInterruptible
import org.json.JSONArray
import org.json.JSONObject

/**
 * Genuine bounded no-root IPv4 ICMP traceroute over the same unprivileged
 * datagram ping socket as [AndroidIcmpPing] (AF_INET, SOCK_DGRAM, IPPROTO_ICMP),
 * bound to the captured Android Network. Router errors are read from the
 * Linux IP_RECVERR error queue; normal echo replies retain their token.
 * `IP_TTL` is set per hop; original destination, actual socket identifier
 * and sequence correlate each router error to one in-flight probe.
 *
 * Timed-out or filtered hops are reported as such; a budget that ends early
 * keeps the hops actually observed (the partial result is published after
 * every hop so a timeout/cancel keeps the real route prefix). No shell, no
 * /system/bin/ping, no root and no host/Linux fallback is ever used.
 */
internal object AndroidIcmpTraceroute {
    private const val RECEIVE_BUFFER_BYTES = 2_048

    suspend fun traceroute(
        session: AndroidNetworkSession,
        request: TracerouteRequest,
    ): ProbeResult {
        val host = request.host
        try {
            NetworkTargetPolicy.checkHostPolicy(host)
        } catch (failure: TargetPolicyException) {
            return ProbeResult(
                status = ObservationStatus.UNSUPPORTED,
                observations = JSONObject().put("errorCode", failure.code),
                limitations = listOf(failure.message ?: "The traceroute target is not permitted."),
                target = host,
            )
        }
        val network = session.activeNetwork ?: return ProbeResult(
            status = ObservationStatus.UNAVAILABLE,
            observations = JSONObject().put("errorCode", "noActiveNetwork"),
            limitations = session.snapshot.limitations +
                "No active network is available for ICMP traceroute.",
            target = host,
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
                observations = JSONObject().put("requiredFor", NetworkMethod.TRACEROUTE.wire),
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
                    "This batch implements genuine IPv4 ICMP traceroute only; use tcpProbe or dnsLookup for IPv6 targets.",
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
            runCatching { Os.close(fd) }
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
        return try {
            Os.setsockoptInt(fd, OsConstants.IPPROTO_IP, IcmpErrorQueue.IP_RECVERR, 1)
            probeLoop(session, fd, address, host, request)
        } catch (cancelled: java.util.concurrent.CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            ProbeResult(
                status = ObservationStatus.ERROR,
                observations = JSONObject()
                    .put("errorCode", "icmpTracerouteFailed")
                    .put("errorClass", failure.javaClass.simpleName.take(64)),
                limitations = session.snapshot.limitations +
                    "The ICMP traceroute failed before a measurement was completed.",
                target = host,
            )
        } finally {
            runCatching { Os.close(fd) }
        }
    }

    private fun probeLoop(
        session: AndroidNetworkSession,
        fd: java.io.FileDescriptor,
        address: Inet4Address,
        host: String,
        request: TracerouteRequest,
    ): ProbeResult {
        val started = SystemClock.elapsedRealtime()
        // The envelope watchdog owns the hard deadline; this mirror budget
        // lets the loop stop cleanly and report the real partial route
        // instead of waiting for the watchdog to abort a blocked read.
        val deadlineMs = started + request.probeTimeoutMs.toLong() *
            request.probesPerHop * request.maxHops
        val hops = ArrayList<TracerouteHop>()
        val limitations = ArrayList<String>()
        limitations += "ICMP traceroute is IPv4-only in this batch; ICMPv6 traceroute is not implemented."
        limitations += "Android may rate-limit or drop ICMP echo traffic."
        val socketAddress = InetSocketAddress(address, 0)
        var nextSequence = 0
        var sendFailure: Exception? = null
        var budgetExhausted = false

        for (ttl in 1..request.maxHops) {
            if (session.isSessionClosed()) {
                return cancelledResult(session, host, request, address, hops, limitations, started)
            }
            if (deadlineMs - SystemClock.elapsedRealtime() <= 0L) {
                budgetExhausted = true
                break
            }
            if (!setHopTtl(fd, ttl)) {
                return ProbeResult(
                    status = ObservationStatus.UNSUPPORTED,
                    observations = observationsFor(request, address, hops, started)
                        .put("errorCode", "ttlOptionUnsupported")
                        .put("ttl", ttl),
                    limitations = session.snapshot.limitations + limitations +
                        "This system denied the per-hop IP_TTL socket option; traceroute is unavailable here.",
                    target = host,
                )
            }

            val probeRtts = ArrayList<Double>()
            var hopAddress: String? = null
            var hopStatus: TracerouteHopStatus? = null
            var unreachableCode: Int? = null
            for (probe in 1..request.probesPerHop) {
                if (session.isSessionClosed()) {
                    return cancelledResult(session, host, request, address, hops, limitations, started)
                }
                val probeBudget = deadlineMs - SystemClock.elapsedRealtime()
                if (probeBudget <= 0L) {
                    budgetExhausted = true
                    break
                }
                val sequence = nextSequence++
                val token = java.util.Random().nextInt()
                val sentAtNanos = System.nanoTime()
                val packet = IcmpPacket.buildEchoRequest(sequence, sentAtNanos, token)
                val sent = try {
                    Os.sendto(fd, packet, 0, packet.size, 0, socketAddress)
                } catch (failure: ErrnoException) {
                    sendFailure = failure
                    break
                } catch (failure: Exception) {
                    sendFailure = failure
                    break
                }
                if (sent != packet.size) {
                    sendFailure = IOException("short ICMP datagram send")
                    break
                }
                val outcome = awaitProbe(
                    session = session,
                    fd = fd,
                    sequence = sequence,
                    token = token,
                    sentAtNanos = sentAtNanos,
                    waitMs = minOf(request.probeTimeoutMs.toLong(), probeBudget),
                    target = address,
                )
                when (outcome) {
                    is ProbeOutcome.Reached -> {
                        // A reply without a readable source address cannot be
                        // attributed; keep the probe honest by ignoring it.
                        if (outcome.from.isNotBlank()) {
                            probeRtts += outcome.rttMs
                            hopAddress = outcome.from
                            hopStatus = TracerouteHopStatus.REACHED
                            unreachableCode = null
                        }
                    }

                    is ProbeOutcome.TimeExceeded -> {
                        if (hopStatus != TracerouteHopStatus.REACHED && outcome.from.isNotBlank()) {
                            probeRtts += outcome.rttMs
                            hopAddress = outcome.from
                            hopStatus = TracerouteHopStatus.TIME_EXCEEDED
                            unreachableCode = null
                        }
                    }

                    is ProbeOutcome.Unreachable -> {
                        if (hopStatus != TracerouteHopStatus.REACHED && outcome.from.isNotBlank()) {
                            probeRtts += outcome.rttMs
                            hopAddress = outcome.from
                            hopStatus = TracerouteHopStatus.UNREACHABLE
                            unreachableCode = outcome.code
                        }
                    }

                    ProbeOutcome.Timeout -> Unit
                }
                if (hopStatus == TracerouteHopStatus.REACHED) break
            }
            if (sendFailure != null) break
            if (budgetExhausted && hopStatus == null) break
            hops += TracerouteHop(
                ttl = ttl,
                status = hopStatus ?: TracerouteHopStatus.TIMEOUT,
                address = hopAddress,
                rttsMs = probeRtts,
                unreachableCode = unreachableCode,
            )
            publishPartial(session, host, request, address, hops, limitations, started)
            if (hopStatus == TracerouteHopStatus.REACHED) break
        }

        val reached = hops.lastOrNull()?.status == TracerouteHopStatus.REACHED
        val failure = sendFailure
        val merged = ArrayList(limitations)
        if (failure != null) {
            merged += "ICMP send stopped the traceroute: ${failure.javaClass.simpleName}."
        }
        if (budgetExhausted && !reached) {
            merged += "The hop budget ended before a probe to every requested TTL completed."
        }
        if (!reached && hops.isNotEmpty()) {
            merged += "The target did not respond within the requested hop budget; listed hops are actual observations."
        }
        if (hops.isEmpty() && failure == null) {
            merged += "No ICMP answer was received within the bounded probe window."
        }
        val anyResponse = hops.any {
            it.status == TracerouteHopStatus.REACHED ||
                it.status == TracerouteHopStatus.TIME_EXCEEDED ||
                it.status == TracerouteHopStatus.UNREACHABLE
        }
        val status = when {
            reached -> ObservationStatus.OK
            failure != null -> statusForSendFailure(failure)
            anyResponse -> ObservationStatus.PARTIAL
            else -> ObservationStatus.TIMEOUT
        }
        return ProbeResult(
            status = status,
            observations = observationsFor(request, address, hops, started).apply {
                put("reachedTarget", reached)
                if (budgetExhausted) put("budgetExhausted", true)
                failure?.let { put("sendErrorClass", it.javaClass.simpleName.take(64)) }
            },
            limitations = (session.snapshot.limitations + merged).distinct(),
            target = host,
        )
    }

    private sealed interface ProbeOutcome {
        data class Reached(val from: String, val rttMs: Double) : ProbeOutcome
        data class TimeExceeded(val from: String, val rttMs: Double) : ProbeOutcome
        data class Unreachable(val from: String, val code: Int, val rttMs: Double) : ProbeOutcome
        data object Timeout : ProbeOutcome
    }

    /**
     * Waits up to [waitMs] for THIS probe's answer, ignoring unrelated ICMP
     * traffic exactly like the frozen ping loop. RTTs are nanoTime deltas
     * from the real send instant, never wall-clock readings.
     */
    private fun awaitProbe(
        session: AndroidNetworkSession,
        fd: java.io.FileDescriptor,
        sequence: Int,
        token: Int,
        sentAtNanos: Long,
        waitMs: Long,
        target: Inet4Address,
    ): ProbeOutcome {
        val deadlineNanos = sentAtNanos + waitMs * 1_000_000L
        val identifier = (Os.getsockname(fd) as? InetSocketAddress)?.port
            ?: throw IOException("ICMP socket identifier unavailable")
        val pollFd = StructPollfd().apply {
            this.fd = fd
            events = OsConstants.POLLIN.toShort()
        }
        while (true) {
            val remainingMs = (deadlineNanos - System.nanoTime()) / 1_000_000L
            if (remainingMs <= 0L) return ProbeOutcome.Timeout
            val polled = try {
                Os.poll(arrayOf(pollFd), remainingMs.coerceAtMost(Integer.MAX_VALUE.toLong()).toInt())
            } catch (failure: ErrnoException) {
                if (session.isSessionClosed()) return ProbeOutcome.Timeout
                throw failure
            }
            if (session.isSessionClosed()) return ProbeOutcome.Timeout
            if (polled <= 0) continue
            val events = pollFd.revents.toInt()
            if ((events and (OsConstants.POLLNVAL or OsConstants.POLLHUP)) != 0) {
                throw IOException("ICMP socket closed")
            }
            if ((events and OsConstants.POLLERR) != 0) {
                val frame = try { IcmpErrorQueueNative.read(fd) }
                catch (failure: LinkageError) { throw IOException("ICMP error receiver unavailable", failure) }
                val error = frame?.let { IcmpErrorQueue.parse(it, target.address, identifier, sequence) }
                if (error != null) {
                    val rttMs = ((System.nanoTime() - sentAtNanos).coerceAtLeast(0L)) / 1_000_000.0
                    return if (error.type == IcmpPacket.TYPE_TIME_EXCEEDED) {
                        ProbeOutcome.TimeExceeded(error.address, rttMs)
                    } else {
                        ProbeOutcome.Unreachable(error.address, error.code, rttMs)
                    }
                }
                // recvmsg drains one queue item, even if unrelated/malformed.
                // The native adapter clears residual SO_ERROR on an empty queue.
            }
            if ((events and OsConstants.POLLIN) == 0) continue
            val buffer = ByteArray(RECEIVE_BUFFER_BYTES)
            val source = InetSocketAddress("0.0.0.0", 0)
            val read = try {
                Os.recvfrom(fd, buffer, 0, buffer.size, 0, source)
            } catch (_: Exception) {
                -1
            }
            if (read <= 0) continue
            val slice = buffer.copyOf(read)
            val receivedAt = System.nanoTime()
            val reply = IcmpPacket.parseEchoReply(slice, sequence, token)
            if (reply != null && source.address == target && reply.timestampNanos == sentAtNanos) {
                return ProbeOutcome.Reached(
                    from = source.address?.hostAddress ?: "",
                    rttMs = (receivedAt - reply.timestampNanos) / 1_000_000.0,
                )
            }

        }
    }

    private fun setHopTtl(fd: java.io.FileDescriptor, ttl: Int): Boolean = try {
        Os.setsockoptInt(fd, OsConstants.IPPROTO_IP, OsConstants.IP_TTL, ttl)
        true
    } catch (_: Exception) {
        false
    }

    private fun cancelledResult(
        session: AndroidNetworkSession,
        host: String,
        request: TracerouteRequest,
        address: Inet4Address,
        hops: List<TracerouteHop>,
        limitations: List<String>,
        started: Long,
    ): ProbeResult = ProbeResult(
        status = ObservationStatus.CANCELLED,
        observations = observationsFor(request, address, hops, started).apply {
            put("cancelled", true)
            put("reachedTarget", false)
            if (hops.isNotEmpty()) put("partial", true)
        },
        limitations = session.snapshot.limitations + limitations,
        target = host,
    )

    private fun publishPartial(
        session: AndroidNetworkSession,
        host: String,
        request: TracerouteRequest,
        address: Inet4Address,
        hops: List<TracerouteHop>,
        limitations: List<String>,
        started: Long,
    ) {
        session.publishPartial(
            ProbeResult(
                status = ObservationStatus.PARTIAL,
                observations = observationsFor(request, address, hops, started).apply {
                    put("reachedTarget", false)
                },
                limitations = limitations,
                target = host,
            ),
        )
    }

    private fun observationsFor(
        request: TracerouteRequest,
        address: Inet4Address,
        hops: List<TracerouteHop>,
        started: Long,
    ): JSONObject = JSONObject().apply {
        put("resolvedAddress", address.hostAddress)
        put("family", "IPv4")
        put("maxHops", request.maxHops)
        put("probesPerHop", request.probesPerHop)
        put("probeTimeoutMs", request.probeTimeoutMs)
        put("socketType", "unprivilegedDatagram")
        put("elapsedMs", SystemClock.elapsedRealtime() - started)
        put("hops", JSONArray().apply { hops.forEach { put(it.toJson()) } })
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
                    "The OS denied the unprivileged ICMP datagram socket; no TCP substitute is reported as traceroute."
                } else {
                    "The unprivileged ICMP datagram socket could not be created."
                },
            ),
            target = host,
        )
    }
}
