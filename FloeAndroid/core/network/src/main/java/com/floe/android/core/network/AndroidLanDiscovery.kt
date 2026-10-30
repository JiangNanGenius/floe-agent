// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import android.net.Network
import android.net.nsd.DiscoveryRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.SystemClock
import java.net.ConnectException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NoRouteToHostException
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * G07.2 LAN discovery.
 *
 * mDNS uses the platform NsdManager on the captured Network where the API
 * proves that route: API 33+ Network overload and API 35+ DiscoveryRequest.
 * The pre-API-33 legacy browse has no Network argument and no callback proof
 * of the answering network, so it is refused as typed unsupported rather
 * than claiming a captured or system-default route; the bounded TCP subnet
 * scan remains a real fallback. API 37+ uses FLAG_NO_PICKER, so a missing
 * ACCESS_LOCAL_NETWORK is a real FAILURE_PERMISSION_DENIED, never an
 * automatic system picker.
 *
 * The optional subnet scan is a bounded TCP connect sweep over RFC1918
 * addresses that the caller named explicitly. It never sweeps public ranges,
 * never reads payload/banners, never uses root/ADB/raw sockets and always
 * binds each socket to the captured Network.
 */
internal object AndroidLanDiscovery {
    private const val API_37 = 37
    private const val FAILURE_PERMISSION_DENIED = 7
    private const val POLL_MS = 250L
    private const val RESOLVE_TIMEOUT_MS = 2_500L
    private const val MAX_RESOLVE_CONCURRENCY = 4
    private const val RESERVED_TAIL_MS = 300L
    private const val PUBLISH_EVERY_ATTEMPTS = 8

    private data class MdnsOutcome(
        val summary: LanMdnsSummary?,
        val networkChanged: Boolean,
        val failure: LanFailure? = null,
    )

    private data class TcpOutcome(
        val summary: LanTcpScanSummary?,
        val networkChanged: Boolean,
    )

    private data class ResolvedInfo(
        val addresses: List<String> = emptyList(),
        val hostname: String? = null,
        val port: Int? = null,
        val attributes: Map<String, String>? = null,
        val networkHandle: String? = null,
        val resolution: String = "unresolved",
        val errorCode: Int? = null,
        val errorText: String? = null,
    )

    private class NsdResolveFailure(val code: Int) : Exception("NsdManager resolve failed with code $code")

    suspend fun discover(session: AndroidNetworkSession, request: LanDiscoveryRequest): ProbeResult {
        val network = session.activeNetwork ?: return LanDiscoveryResult.build(
            request = request,
            mdns = null,
            tcp = null,
            networkChanged = false,
            failure = LanFailure(
                ObservationStatus.UNAVAILABLE,
                "noActiveNetwork",
                "No active network is available for LAN discovery.",
            ),
        )
        val started = SystemClock.elapsedRealtime()
        val deadline = started + request.timeoutMs - RESERVED_TAIL_MS
        var mdns: LanMdnsSummary? = null
        var tcp: LanTcpScanSummary? = null
        var networkChanged = false

        try {
            session.verifySameCapturedNetwork()
        } catch (changed: NetworkChangedException) {
            return LanDiscoveryResult.build(request, null, null, networkChanged = true)
        }

        if (request.hasMdns) {
            val outcome = discoverMdns(session, network, request, deadline)
            mdns = outcome.summary
            networkChanged = outcome.networkChanged
            session.publishPartial(LanDiscoveryResult.build(request, mdns, null, networkChanged, outcome.failure))
            if (networkChanged) {
                return LanDiscoveryResult.build(request, mdns, null, networkChanged = true)
            }
            if (outcome.failure != null && !request.hasTcp) {
                return LanDiscoveryResult.build(request, mdns, null, false, outcome.failure)
            }
        }

        if (request.hasTcp && SystemClock.elapsedRealtime() < deadline - 100) {
            val outcome = scanTcp(session, network, request, mdns, deadline)
            tcp = outcome.summary
            networkChanged = networkChanged || outcome.networkChanged
            session.publishPartial(LanDiscoveryResult.build(request, mdns, tcp, networkChanged))
            if (networkChanged) {
                return LanDiscoveryResult.build(request, mdns, tcp, networkChanged = true)
            }
        }

        return LanDiscoveryResult.build(request, mdns, tcp, networkChanged)
    }

    private suspend fun discoverMdns(
        session: AndroidNetworkSession,
        network: Network,
        request: LanDiscoveryRequest,
        deadline: Long,
    ): MdnsOutcome {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            // The pre-API-33 NsdManager browse overload has no Network argument
            // and its callbacks do not prove which network answered. Refuse the
            // unscoped path instead of claiming the captured route; the bounded
            // TCP subnet scan remains available as a real fallback.
            return MdnsOutcome(
                summary = unsupportedSummary(
                    request,
                    scope = "unsupportedLegacyApi",
                    error = "nsdNetworkScopeUnsupported",
                ),
                networkChanged = false,
            )
        }
        val manager = session.context.getSystemService(NsdManager::class.java)
            ?: return MdnsOutcome(
                summary = unsupportedSummary(
                    request,
                    scope = "nsdUnavailable",
                    error = "nsdUnavailable",
                ),
                networkChanged = false,
            )
        val executor = NsdCallbackExecutor()
        session.trackAction { executor.close() }

        val callbacksClosed = AtomicBoolean(false)
        val started = SystemClock.elapsedRealtime()
        val states = ConcurrentHashMap<String, LanDiscoveryTypeState>()
        val listeners = ConcurrentHashMap<String, NsdManager.DiscoveryListener>()
        val found = ConcurrentHashMap<String, NsdServiceInfo>()
        val lostKeys = ConcurrentHashMap.newKeySet<String>()
        val networkChanged = AtomicBoolean(false)
        val truncated = AtomicBoolean(false)
        val filteredForeign = AtomicInteger(0)
        val stopped = AtomicBoolean(false)
        val capturedHandle = session.capturedNetworkHandle()?.let { handle ->
            "0x" + java.lang.Long.toHexString(handle)
        }

        fun publishIfChanged(): Boolean {
            if (callbacksClosed.get()) return true
            if (session.hasCapturedNetworkChanged()) {
                networkChanged.set(true)
                return true
            }
            return false
        }

        try {
            try {
                request.serviceTypes.forEach { serviceType ->
                    val state = LanDiscoveryTypeState()
                    states[serviceType] = state
                    val listener = object : NsdManager.DiscoveryListener {
                        override fun onDiscoveryStarted(serviceType: String) {
                            if (callbacksClosed.get()) return
                            state.started()
                        }

                        override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                            if (callbacksClosed.get() || stopped.get()) return
                            if (publishIfChanged()) return
                            val infoHandle = serviceNetworkHandle(serviceInfo)
                            if (infoHandle != null && capturedHandle != null && infoHandle != capturedHandle) {
                                filteredForeign.incrementAndGet()
                                return
                            }
                            val key = serviceKey(serviceInfo)
                            if (found.size >= NetworkLimits.MAX_LAN_SERVICES) {
                                truncated.set(true)
                                return
                            }
                            found.putIfAbsent(key, serviceInfo)
                        }

                        override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                            if (callbacksClosed.get() || stopped.get()) return
                            lostKeys.add(serviceKey(serviceInfo))
                        }

                        override fun onDiscoveryStopped(serviceType: String) {
                            if (callbacksClosed.get()) return
                            state.stopped()
                        }

                        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                            if (callbacksClosed.get()) return
                            state.startedFailure(errorCode, nsdErrorName(errorCode))
                        }

                        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                            if (callbacksClosed.get()) return
                            state.stopFailure(errorCode, nsdErrorName(errorCode))
                        }
                    }
                    listeners[serviceType] = listener
                    try {
                        when {
                            Build.VERSION.SDK_INT >= API_37 -> manager.discoverServices(
                                buildDiscoveryRequest(serviceType, network, noPicker = true),
                                executor,
                                listener,
                            )
                            Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM -> manager.discoverServices(
                                buildDiscoveryRequest(serviceType, network, noPicker = false),
                                executor,
                                listener,
                            )
                            else -> manager.discoverServices(
                                serviceType,
                                NsdManager.PROTOCOL_DNS_SD,
                                network,
                                executor,
                                listener,
                            )
                        }
                    } catch (failure: Exception) {
                        state.startedFailure(null, failure.javaClass.simpleName.take(64))
                    }
                }

                val discoveryEnd = minOf(started + request.discoveryDurationMs, deadline)
                while (true) {
                    if (publishIfChanged()) break
                    val now = SystemClock.elapsedRealtime()
                    if (now >= discoveryEnd) break
                    delay(minOf(POLL_MS, discoveryEnd - now))
                }
            } finally {
                stopped.set(true)
                listeners.values.forEach { listener ->
                    runCatching { manager.stopServiceDiscovery(listener) }
                }
            }

            if (session.hasCapturedNetworkChanged()) networkChanged.set(true)

            val remainingForResolve = deadline - SystemClock.elapsedRealtime()
            val resolved: Map<String, ResolvedInfo> = if (networkChanged.get() || remainingForResolve < 200L) {
                emptyMap()
            } else {
                val infos = found.entries.toList()
                val results = ConcurrentHashMap<String, ResolvedInfo>()
                coroutineScope {
                    val semaphore = Semaphore(MAX_RESOLVE_CONCURRENCY)
                    infos.map { (key, info) ->
                        launch {
                            val timeout = minOf(RESOLVE_TIMEOUT_MS, deadline - SystemClock.elapsedRealtime())
                            val infoResult = semaphore.withPermit {
                                if (timeout < 200L) {
                                    ResolvedInfo(resolution = "unresolved")
                                } else {
                                    resolveService(manager, executor, callbacksClosed, info, timeout)
                                }
                            }
                            results[key] = infoResult
                        }
                    }.forEach { it.join() }
                }
                results.toMap()
            }

            // All resolutions are complete. Fence late platform callbacks and
            // stop the worker before composing the result so nothing can
            // mutate a result that is already being read.
            callbacksClosed.set(true)
            executor.close()
            val callbacksDropped = executor.droppedCallbackCount > 0

            val serviceRecords = found.entries.mapNotNull { (key, info) ->
                val infoResult = resolved[key] ?: ResolvedInfo(resolution = "unresolved")
                val discoveryHandle = serviceNetworkHandle(info)
                val resolvedHandle = infoResult.networkHandle ?: discoveryHandle
                if (resolvedHandle != null && capturedHandle != null && resolvedHandle != capturedHandle) {
                    filteredForeign.incrementAndGet()
                    return@mapNotNull null
                }
                val matches = if (resolvedHandle == null || capturedHandle == null) {
                    null
                } else {
                    resolvedHandle == capturedHandle
                }
                LanServiceRecord(
                    serviceName = info.serviceName.orEmpty(),
                    serviceType = info.serviceType.orEmpty(),
                    subtypes = subtypesOf(info),
                    hostname = infoResult.hostname,
                    addresses = infoResult.addresses,
                    port = infoResult.port,
                    networkHandle = resolvedHandle,
                    networkMatchesCaptured = matches,
                    state = if (lostKeys.contains(key)) "lost" else "active",
                    resolution = infoResult.resolution,
                    resolveErrorCode = infoResult.errorCode,
                    resolveError = infoResult.errorText,
                    attributes = if (request.includeAttributes) infoResult.attributes else null,
                )
            }.sortedWith(compareBy({ it.serviceType }, { it.serviceName }))

            val perType = request.serviceTypes.map { serviceType ->
                val state = states[serviceType]?.snapshot()
                    ?: LanDiscoveryTypeState.Snapshot("startPending")
                LanTypeRecord(serviceType, state.state, state.errorCode, state.errorText)
            }
            val allStarted = states.isNotEmpty() && states.values.all { state ->
                val current = state.snapshot().state
                current == "started" || current == "stopped"
            }
            val truncatedResult = truncated.get() || callbacksDropped
            val noReplies = found.isEmpty() && allStarted && !truncatedResult
            val elapsed = SystemClock.elapsedRealtime() - started
            val summary = LanMdnsSummary(
                requestedServiceTypes = request.serviceTypes,
                scope = "capturedNetwork",
                networkScoped = true,
                discoveryDurationMs = request.discoveryDurationMs,
                elapsedMs = elapsed,
                services = serviceRecords,
                perType = perType,
                filteredForeignNetwork = filteredForeign.get(),
                truncated = truncatedResult,
                noReplies = noReplies,
                multicastLockHeld = null,
                stoppedReason = when {
                    networkChanged.get() -> "networkChanged"
                    callbacksDropped -> "callbackOverflow"
                    truncated.get() -> "serviceLimit"
                    else -> "duration"
                },
            )
            return MdnsOutcome(summary, networkChanged.get())
        } finally {
            callbacksClosed.set(true)
            executor.close()
        }
    }

    private suspend fun scanTcp(
        session: AndroidNetworkSession,
        network: Network,
        request: LanDiscoveryRequest,
        mdns: LanMdnsSummary?,
        deadline: Long,
    ): TcpOutcome {
        val subnet = request.subnet ?: return TcpOutcome(null, false)
        val (hosts, excludedSelf) = LanDiscoveryResult.excludeSelf(subnet, session.snapshot.linkAddresses)
        val pairs = ArrayList<Pair<String, Int>>(hosts.size * request.ports.size)
        hosts.forEach { host ->
            request.ports.forEach { port -> pairs += host to port }
        }
        val openPorts = ConcurrentLinkedQueue<LanTcpOpenPort>()
        val attemptedHosts = ConcurrentHashMap.newKeySet<String>()
        val hostsWithResponse = ConcurrentHashMap.newKeySet<String>()
        val hostsWithOpen = ConcurrentHashMap.newKeySet<String>()
        val completed = AtomicInteger(0)
        val refused = AtomicInteger(0)
        val timedOut = AtomicInteger(0)
        val errors = AtomicInteger(0)
        val unreachable = AtomicInteger(0)
        val next = AtomicInteger(0)
        val truncated = AtomicBoolean(false)
        val networkChanged = AtomicBoolean(false)
        val stoppedReason = AtomicReference("completed")
        val started = SystemClock.elapsedRealtime()

        fun progress(): LanTcpScanSummary = LanTcpScanSummary(
            subnetCidr = subnet.cidr,
            ports = request.ports,
            hostCount = subnet.addresses.size,
            excludedSelfAddresses = excludedSelf,
            attemptedHosts = attemptedHosts.size,
            plannedAttempts = pairs.size,
            completedAttempts = completed.get(),
            openPorts = openPorts.toList(),
            refusedAttempts = refused.get(),
            timedOutAttempts = timedOut.get(),
            errorAttempts = errors.get(),
            unreachableAttempts = unreachable.get(),
            hostsWithResponse = hostsWithResponse.size,
            hostsWithOpenPort = hostsWithOpen.size,
            truncated = truncated.get(),
            stoppedReason = if (networkChanged.get()) "networkChanged" else stoppedReason.get(),
            cancelled = session.isSessionClosed(),
            elapsedMs = SystemClock.elapsedRealtime() - started,
        )

        fun publish() {
            session.publishPartial(
                LanDiscoveryResult.build(
                    request,
                    mdns,
                    progress(),
                    networkChanged.get(),
                ),
            )
        }

        val workers = minOf(request.tcpConcurrency, pairs.size).coerceAtLeast(1)
        try {
            coroutineScope {
                repeat(workers) {
                    launch {
                        while (true) {
                            if (networkChanged.get()) break
                            if (session.isSessionClosed()) {
                                stoppedReason.set("cancelled")
                                break
                            }
                            if (SystemClock.elapsedRealtime() >= deadline) {
                                stoppedReason.compareAndSet("completed", "timeBudget")
                                break
                            }
                            val index = next.getAndIncrement()
                            if (index >= pairs.size) break
                            try {
                                session.verifySameCapturedNetwork()
                            } catch (_: NetworkChangedException) {
                                networkChanged.set(true)
                                stoppedReason.set("networkChanged")
                                break
                            }
                            val (host, port) = pairs[index]
                            attemptedHosts.add(host)
                            val socket = Socket()
                            session.trackCloseable(socket)
                            val connectStarted = System.nanoTime()
                            try {
                                network.bindSocket(socket)
                                socket.connect(
                                    InetSocketAddress(InetAddress.getByName(host), port),
                                    request.tcpConnectTimeoutMs,
                                )
                                hostsWithResponse.add(host)
                                hostsWithOpen.add(host)
                                if (openPorts.size < NetworkLimits.MAX_TCP_OPEN_PORTS) {
                                    openPorts.add(
                                        LanTcpOpenPort(
                                            address = host,
                                            port = port,
                                            connectTimeMs = (System.nanoTime() - connectStarted) / 1_000_000L,
                                        ),
                                    )
                                } else {
                                    truncated.set(true)
                                }
                            } catch (cancelled: CancellationException) {
                                throw cancelled
                            } catch (_: SocketTimeoutException) {
                                timedOut.incrementAndGet()
                            } catch (_: ConnectException) {
                                refused.incrementAndGet()
                                hostsWithResponse.add(host)
                            } catch (_: NoRouteToHostException) {
                                unreachable.incrementAndGet()
                            } catch (_: UnknownHostException) {
                                errors.incrementAndGet()
                            } catch (_: SecurityException) {
                                errors.incrementAndGet()
                            } catch (_: Exception) {
                                errors.incrementAndGet()
                            } finally {
                                runCatching { socket.close() }
                                val done = completed.incrementAndGet()
                                if (done % PUBLISH_EVERY_ATTEMPTS == 0) publish()
                            }
                        }
                    }
                }
            }
        } finally {
            publish()
        }
        return TcpOutcome(progress(), networkChanged.get())
    }

    private suspend fun resolveService(
        manager: NsdManager,
        executor: Executor,
        callbacksClosed: AtomicBoolean,
        info: NsdServiceInfo,
        timeoutMs: Long,
    ): ResolvedInfo {
        var callback: NsdManager.ServiceInfoCallback? = null
        return try {
            val resolvedInfo = withTimeoutOrNull(timeoutMs) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    suspendCancellableCoroutine<NsdServiceInfo> { continuation ->
                        val settled = AtomicBoolean(false)
                        fun resumeOnce(serviceInfo: NsdServiceInfo) {
                            if (callbacksClosed.get() || !settled.compareAndSet(false, true)) return
                            if (continuation.isActive) continuation.resume(serviceInfo)
                        }
                        fun resumeFailureOnce(failure: NsdResolveFailure) {
                            if (callbacksClosed.get() || !settled.compareAndSet(false, true)) return
                            if (continuation.isActive) continuation.resumeWithException(failure)
                        }
                        val serviceCallback = object : NsdManager.ServiceInfoCallback {
                            override fun onServiceUpdated(serviceInfo: NsdServiceInfo) =
                                resumeOnce(serviceInfo)

                            override fun onServiceLost() = Unit

                            override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) =
                                resumeFailureOnce(NsdResolveFailure(errorCode))

                            override fun onServiceInfoCallbackUnregistered() =
                                resumeFailureOnce(NsdResolveFailure(-1))
                        }
                        callback = serviceCallback
                        manager.registerServiceInfoCallback(info, executor, serviceCallback)
                        continuation.invokeOnCancellation {
                            runCatching { manager.unregisterServiceInfoCallback(serviceCallback) }
                        }
                    }
                } else {
                    suspendCancellableCoroutine<NsdServiceInfo> { continuation ->
                        val settled = AtomicBoolean(false)
                        fun resumeOnce(serviceInfo: NsdServiceInfo) {
                            if (callbacksClosed.get() || !settled.compareAndSet(false, true)) return
                            if (continuation.isActive) continuation.resume(serviceInfo)
                        }
                        fun resumeFailureOnce(failure: NsdResolveFailure) {
                            if (callbacksClosed.get() || !settled.compareAndSet(false, true)) return
                            if (continuation.isActive) continuation.resumeWithException(failure)
                        }
                        val listener = object : NsdManager.ResolveListener {
                            override fun onServiceResolved(serviceInfo: NsdServiceInfo) =
                                resumeOnce(serviceInfo)

                            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) =
                                resumeFailureOnce(NsdResolveFailure(errorCode))
                        }
                        manager.resolveService(info, executor, listener)
                    }
                }
            }
            if (resolvedInfo == null) {
                ResolvedInfo(resolution = "failed", errorText = "resolveTimeout")
            } else {
                val addresses = addressesOf(resolvedInfo)
                val port = resolvedInfo.port.takeIf { it in 1..65_535 }
                ResolvedInfo(
                    addresses = addresses,
                    hostname = hostnameOf(resolvedInfo),
                    port = port,
                    attributes = attributesOf(resolvedInfo),
                    networkHandle = serviceNetworkHandle(resolvedInfo),
                    resolution = if (addresses.isNotEmpty() && port != null) "resolved" else "unresolved",
                )
            }
        } catch (failure: NsdResolveFailure) {
            ResolvedInfo(
                resolution = "failed",
                errorCode = failure.code,
                errorText = nsdErrorName(failure.code),
            )
        } catch (failure: SecurityException) {
            ResolvedInfo(
                resolution = "failed",
                errorText = "securityException",
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            ResolvedInfo(
                resolution = "failed",
                errorText = failure.javaClass.simpleName.take(64),
            )
        } finally {
            callback?.let { serviceCallback ->
                runCatching { manager.unregisterServiceInfoCallback(serviceCallback) }
            }
            // API 33 has no stopServiceResolution; a late ResolveListener callback
            // checks continuation.isActive and is ignored after the timeout.
        }
    }

    private fun buildDiscoveryRequest(
        serviceType: String,
        network: Network,
        noPicker: Boolean,
    ): DiscoveryRequest {
        val builder = DiscoveryRequest.Builder(serviceType).setNetwork(network)
        if (noPicker) builder.setFlags(DiscoveryRequest.FLAG_NO_PICKER)
        return builder.build()
    }

    private fun serviceKey(info: NsdServiceInfo): String =
        "${info.serviceType.orEmpty()}|${info.serviceName.orEmpty()}|${serviceNetworkHandle(info) ?: "-"}"

    private fun serviceNetworkHandle(info: NsdServiceInfo): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return null
        val network = runCatching { info.network }.getOrNull() ?: return null
        return "0x${java.lang.Long.toHexString(network.networkHandle)}"
    }

    private fun addressesOf(info: NsdServiceInfo): List<String> {
        val addresses = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            runCatching { info.hostAddresses }.getOrNull().orEmpty()
        } else {
            @Suppress("DEPRECATION")
            listOfNotNull(runCatching { info.host }.getOrNull())
        }
        return addresses
            .mapNotNull { address -> address.hostAddress }
            .filterNot { literal ->
                NetworkTargetPolicy.isDenied(NetworkTargetPolicy.classifyLiteral(literal))
            }
            .distinct()
            .take(16)
    }

    private fun hostnameOf(info: NsdServiceInfo): String? {
        if (Build.VERSION.SDK_INT < 36) return null
        return runCatching { info.hostname }.getOrNull()?.takeIf { it.isNotBlank() }
    }

    private fun subtypesOf(info: NsdServiceInfo): List<String> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) return emptyList()
        return runCatching { info.subtypes.toList() }.getOrDefault(emptyList()).take(8)
    }

    private fun attributesOf(info: NsdServiceInfo): Map<String, String>? {
        val attributes = runCatching { info.attributes }.getOrNull() ?: return null
        if (attributes.isEmpty()) return null
        val bounded = LinkedHashMap<String, String>()
        attributes.entries.take(NetworkLimits.MAX_LAN_ATTRIBUTES).forEach { (rawKey, rawValue) ->
            val key = rawKey
                .filter { it.code in 0x20..0x7E }
                .take(NetworkLimits.MAX_LAN_ATTRIBUTE_KEY_CHARS)
            if (key.isEmpty()) return@forEach
            if (rawValue.size > NetworkLimits.MAX_LAN_ATTRIBUTE_VALUE_BYTES) return@forEach
            val printable = rawValue.all { (it.toInt() and 0xFF) in 0x20..0x7E }
            bounded[key] = if (printable) {
                String(rawValue, Charsets.UTF_8)
            } else {
                "0x" + rawValue.joinToString("") { byte ->
                    "%02x".format(byte.toInt() and 0xFF)
                }
            }
        }
        return bounded.ifEmpty { null }
    }

    private fun unsupportedSummary(
        request: LanDiscoveryRequest,
        scope: String,
        error: String,
    ): LanMdnsSummary {
        val perType = request.serviceTypes.map { serviceType ->
            LanTypeRecord(
                serviceType = serviceType,
                state = "startFailed",
                error = error,
            )
        }
        return LanMdnsSummary(
            requestedServiceTypes = request.serviceTypes,
            scope = scope,
            networkScoped = false,
            discoveryDurationMs = request.discoveryDurationMs,
            elapsedMs = 0L,
            services = emptyList(),
            perType = perType,
            filteredForeignNetwork = 0,
            truncated = false,
            noReplies = false,
            multicastLockHeld = null,
            stoppedReason = "unsupported",
        )
    }

    private fun nsdErrorName(code: Int): String = when (code) {
        0 -> "nsdInternalError"
        3 -> "nsdAlreadyActive"
        4 -> "nsdMaxLimit"
        6 -> "nsdBadParameters"
        7 -> "nsdPermissionDenied"
        else -> "nsdError"
    }
}
