// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import android.content.Context
import java.io.Closeable
import java.time.Instant
import java.util.concurrent.CancellationException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject

/**
 * Frozen G07 phone-network platform service.
 *
 * The App owns exactly one instance. execute() never asks for a permission,
 * never probes before a request, and returns a bounded JSON
 * NetworkObservationV1 result. Every operation paints on the Android Network
 * captured for that execute() call; cancellation is scoped to one operation
 * ID and closes the sockets/connections the session owns. No shell, guest,
 * Root, ADB or process-global network bind is used.
 */
class PhoneNetworkService internal constructor(
    private val platform: NetworkPlatform,
    private val clock: () -> Instant = { Instant.now() },
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
) : Closeable {
    constructor(context: Context) : this(AndroidNetworkPlatform(context.applicationContext))

    private val jobs = ConcurrentHashMap<String, Deferred<String>>()
    private val sessions = ConcurrentHashMap<String, NetworkSession>()

    @Volatile
    private var closed = false

    suspend fun execute(requestJson: String): String {
        val measuredAt = clock().toString()
        val request = try {
            NetworkRequestParser.parse(requestJson)
        } catch (failure: RequestParseException) {
            return NetworkObservationJson.errorEnvelope(
                operationID = failure.operationID,
                methodWire = failure.methodWire,
                status = ObservationStatus.ERROR,
                measuredAt = measuredAt,
                code = failure.code,
                message = failure.message,
            )
        }
        if (closed) return cancelledEnvelope(request, measuredAt, null, "serviceClosed")

        return coroutineScope {
            val cancellation = CancellationSlot()
            val deferred = async(dispatcher, start = CoroutineStart.LAZY) {
                runRequest(request, measuredAt, cancellation)
            }
            val prior = jobs.putIfAbsent(request.operationID, deferred)
            if (prior != null) {
                deferred.cancel()
                return@coroutineScope NetworkObservationJson.errorEnvelope(
                    operationID = request.operationID,
                    methodWire = request.method.wire,
                    status = ObservationStatus.ERROR,
                    measuredAt = measuredAt,
                    code = "operationInFlight",
                    message = "an operation with this operationID is already running",
                )
            }
            deferred.invokeOnCompletion { jobs.remove(request.operationID, deferred) }
            if (closed) {
                deferred.cancel()
                return@coroutineScope cancelledEnvelope(request, measuredAt, null, "serviceClosed")
            }
            deferred.start()
            try {
                deferred.await()
            } catch (timeout: TimeoutCancellationException) {
                timeoutEnvelope(request, measuredAt, null)
            } catch (cancelled: CancellationException) {
                val stored = cancellation.result.get()
                if (!currentCoroutineContext().isActive) throw cancelled
                stored ?: cancelledEnvelope(request, measuredAt, null, "operationCancelled")
            }
        }
    }

    fun cancel(operationID: String) {
        jobs[operationID]?.cancel(CancellationException("network operation cancelled"))
        sessions.remove(operationID)?.let { session -> runCatching { session.close() } }
    }

    override fun close() {
        if (closed) return
        closed = true
        jobs.values.toList().forEach { job -> runCatching { job.cancel() } }
        sessions.values.toList().forEach { session -> runCatching { session.close() } }
        jobs.clear()
        sessions.clear()
    }

    private suspend fun runRequest(
        request: ParsedRequest,
        measuredAt: String,
        cancellation: CancellationSlot,
    ): String {
        var session: NetworkSession? = null
        try {
            val opened = platform.openSession(request)
            session = opened
            sessions[request.operationID] = opened
            currentCoroutineContext().ensureActive()
            if (closed) return cancelledEnvelope(request, measuredAt, opened.snapshot, "serviceClosed")

            val missing = opened.missingPermissions
            if (missing.isNotEmpty()) {
                return NetworkObservationJson.permissionEnvelope(
                    request = request,
                    measuredAt = measuredAt,
                    snapshot = opened.snapshot,
                    missingPermissions = missing,
                )
            }

            val result = withDeadlineAndClosure(opened, request.timeoutMs) {
                when (request.method) {
                    NetworkMethod.STATUS -> opened.status()
                    NetworkMethod.WIFI_SCAN -> opened.wifiScan(request.refresh)
                    NetworkMethod.DNS_LOOKUP -> opened.dnsLookup(
                        host = request.host ?: throw RequestParseException("invalidArguments", "host is required"),
                        recordType = request.recordType,
                        timeoutMs = request.timeoutMs,
                    )
                    NetworkMethod.PING -> opened.ping(
                        host = request.host ?: throw RequestParseException("invalidArguments", "host is required"),
                        count = request.count,
                        timeoutMs = request.timeoutMs,
                    )
                    NetworkMethod.TCP_PROBE -> opened.tcpProbe(
                        host = request.host ?: throw RequestParseException("invalidArguments", "host is required"),
                        port = request.port ?: throw RequestParseException("invalidArguments", "port is required"),
                        timeoutMs = request.timeoutMs,
                    )
                    NetworkMethod.HTTP -> opened.http(
                        target = request.httpTarget
                            ?: throw RequestParseException("invalidArguments", "url is required"),
                        timeoutMs = request.timeoutMs,
                        maxRedirects = request.maxRedirects,
                    )
                }
            }
            return envelopeFor(request, result, opened.snapshot, measuredAt)
        } catch (deadline: NetworkDeadlineExceededException) {
            return timeoutEnvelope(request, measuredAt, session?.snapshot)
        } catch (timeout: TimeoutCancellationException) {
            return timeoutEnvelope(request, measuredAt, session?.snapshot)
        } catch (cancelled: CancellationException) {
            val result = cancelledEnvelope(request, measuredAt, session?.snapshot, "operationCancelled")
            cancellation.result.compareAndSet(null, result)
            throw cancelled
        } catch (policy: TargetPolicyException) {
            return failureEnvelope(
                request = request,
                measuredAt = measuredAt,
                snapshot = session?.snapshot,
                status = ObservationStatus.UNSUPPORTED,
                code = policy.code,
                message = policy.message,
            )
        } catch (security: SecurityException) {
            val missing = session?.missingPermissions.orEmpty()
            return NetworkObservationJson.envelope(
                operationID = request.operationID,
                methodWire = request.method.wire,
                status = ObservationStatus.PERMISSION_REQUIRED,
                measuredAt = measuredAt,
                snapshot = session?.snapshot,
                target = request.target,
                observations = JSONObject().put("requiredFor", request.method.wire),
                limitations = session?.snapshot?.limitations.orEmpty(),
                cacheAgeMs = null,
                missingPermissions = missing,
            )
        } catch (failure: Throwable) {
            if (failure is VirtualMachineError) throw failure
            return failureEnvelope(
                request = request,
                measuredAt = measuredAt,
                snapshot = session?.snapshot,
                status = ObservationStatus.ERROR,
                code = "operationFailed",
                message = failure.javaClass.simpleName,
            )
        } finally {
            sessions.remove(request.operationID)
            runCatching { session?.close() }
        }
    }

    /**
     * Deadline watchdog and cancellation sentinel. The sentinel is a child of
     * the actual withTimeout scope, started UNDISPATCHED before blocking IO,
     * and closes the owned session in its finally block. Parent cancellation
     * therefore runs the close immediately instead of waiting for a blocked
     * child, while timeout cancellation closes from the same sentinel. The
     * timeout classification is retained if the close turns a blocking read
     * into an IOException before withTimeout itself throws.
     */
    private suspend fun <T> withDeadlineAndClosure(
        session: NetworkSession,
        timeoutMs: Int,
        block: suspend () -> T,
    ): T {
        val deadlineNanos = System.nanoTime() + timeoutMs.toLong() * 1_000_000L
        val timedOut = AtomicBoolean(false)
        return try {
            withTimeout(timeoutMs.toLong()) {
                val sentinel = launch(start = CoroutineStart.UNDISPATCHED) {
                    try {
                        delay(timeoutMs.toLong())
                        timedOut.set(true)
                    } finally {
                        runCatching { session.close() }
                    }
                }
                try {
                    val result = block()
                    if (timedOut.get() || System.nanoTime() >= deadlineNanos) {
                        throw NetworkDeadlineExceededException()
                    }
                    result
                } finally {
                    withContext(NonCancellable) { sentinel.cancelAndJoin() }
                }
            }
        } catch (deadline: NetworkDeadlineExceededException) {
            throw deadline
        } catch (timeout: TimeoutCancellationException) {
            timedOut.set(true)
            throw NetworkDeadlineExceededException()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            if (timedOut.get() || System.nanoTime() >= deadlineNanos) {
                throw NetworkDeadlineExceededException()
            }
            if (!currentCoroutineContext().isActive) {
                throw CancellationException("network operation cancelled")
            }
            throw failure
        } finally {
            runCatching { session.close() }
        }
    }

    private class NetworkDeadlineExceededException : Exception("network diagnostic deadline exceeded")

    private fun envelopeFor(
        request: ParsedRequest,
        result: ProbeResult,
        snapshot: NetworkSnapshot,
        measuredAt: String,
    ): String {
        val limitations = snapshot.limitations + result.limitations
        return NetworkObservationJson.envelope(
            operationID = request.operationID,
            methodWire = request.method.wire,
            status = result.status,
            measuredAt = measuredAt,
            snapshot = snapshot,
            target = result.target ?: request.target,
            observations = result.observations,
            limitations = limitations,
            cacheAgeMs = result.cacheAgeMs,
            missingPermissions = result.missingPermissions,
        )
    }

    private fun timeoutEnvelope(
        request: ParsedRequest,
        measuredAt: String,
        snapshot: NetworkSnapshot?,
    ): String = NetworkObservationJson.envelope(
        operationID = request.operationID,
        methodWire = request.method.wire,
        status = ObservationStatus.TIMEOUT,
        measuredAt = measuredAt,
        snapshot = snapshot,
        target = request.target,
        observations = JSONObject()
            .put("timeoutMs", request.timeoutMs)
            .put("phase", "operation"),
        limitations = snapshot?.limitations.orEmpty() + "The operation exceeded its bounded timeout.",
        cacheAgeMs = null,
        missingPermissions = emptyList(),
    )

    private fun cancelledEnvelope(
        request: ParsedRequest,
        measuredAt: String,
        snapshot: NetworkSnapshot?,
        reason: String,
    ): String = NetworkObservationJson.envelope(
        operationID = request.operationID,
        methodWire = request.method.wire,
        status = ObservationStatus.CANCELLED,
        measuredAt = measuredAt,
        snapshot = snapshot,
        target = request.target,
        observations = JSONObject()
            .put("cancelled", true)
            .put("reason", reason),
        limitations = snapshot?.limitations.orEmpty(),
        cacheAgeMs = null,
        missingPermissions = emptyList(),
    )

    private fun failureEnvelope(
        request: ParsedRequest,
        measuredAt: String,
        snapshot: NetworkSnapshot?,
        status: ObservationStatus,
        code: String,
        message: String?,
    ): String = NetworkObservationJson.envelope(
        operationID = request.operationID,
        methodWire = request.method.wire,
        status = status,
        measuredAt = measuredAt,
        snapshot = snapshot,
        target = request.target,
        observations = JSONObject().apply {
            put("errorCode", code)
            message?.takeIf { it.isNotBlank() }?.let { put("message", it.take(300)) }
        },
        limitations = snapshot?.limitations.orEmpty() + "The network operation did not complete.",
        cacheAgeMs = null,
        missingPermissions = emptyList(),
    )

    private class CancellationSlot {
        val result = AtomicReference<String?>(null)
    }
}
