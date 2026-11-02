// SPDX-License-Identifier: MPL-2.0
//
// App-owned C06 system-services platform lane. Swift owns the bounded ticket
// table and every model/domain decision; this lane only claims one JSON ticket
// at a time, executes the real platform operation, and completes the ticket
// exactly once. Root retirement parks the lane, cancels pending tickets,
// joins the poller and acknowledges `laneClosed(epoch)`.

package com.floe.android.host.systemservices

import android.app.Activity
import android.util.Log
import com.floe.android.core.systemservices.HealthAggregation
import com.floe.android.core.systemservices.HealthMetric
import com.floe.android.core.systemservices.SystemServiceFailure
import com.floe.android.core.systemservices.SystemServiceFailureCode
import com.floe.android.core.systemservices.SystemServicesEngine
import java.time.Instant
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject

internal class SystemServicesLane(
    private val scope: CoroutineScope,
    private val engine: SystemServicesEngine,
    private val currentActivity: () -> Activity?,
    private val bridge: SystemHostBridge = PlatformSystemHostBridge,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val log: (String) -> Unit = { message ->
        Log.println(Log.DEBUG, "FloeC06SystemServices", message)
    },
) {
    private val running = AtomicBoolean(false)
    private var pollJob: Job? = null

    @Volatile
    private var epoch: Long = 0L

    val isRunning: Boolean get() = running.get()

    fun start(boundEpoch: Long): Boolean {
        if (boundEpoch <= 0L) return false
        if (!running.compareAndSet(false, true)) return epoch == boundEpoch
        epoch = boundEpoch
        try {
            val bindResult = bridge.bind(boundEpoch)
            if (bindResult != 0) {
                runCatching { log("System-service bind refused: $bindResult") }
                running.set(false)
                epoch = 0
                return false
            }
            val readyResult = bridge.laneReady(boundEpoch)
            if (readyResult != 0) {
                runCatching { log("System-service readiness refused: $readyResult") }
                running.set(false)
                epoch = 0
                return false
            }
        } catch (failure: Throwable) {
            runCatching { log("System-service startup failed: ${failure.javaClass.simpleName}") }
            running.set(false)
            epoch = 0
            return false
        }
        pollJob = scope.launch(ioDispatcher) { pollLoop(boundEpoch) }
        return true
    }

    /** True only when the poller ended and the Swift mailbox saw the exact
     *  generation acknowledgement. */
    fun stop(timeoutMillis: Int): Boolean {
        val wasRunning = running.getAndSet(false)
        pollJob?.cancel()
        val finished = runBlocking {
            withTimeoutOrNull(timeoutMillis.coerceIn(250, 10_000).toLong()) {
                pollJob?.join()
                true
            } ?: false
        }
        pollJob = null
        val boundEpoch = epoch
        epoch = 0L
        if (boundEpoch > 0L) {
            runCatching { bridge.closeAll(1_000) }
            runCatching { bridge.laneClosed(boundEpoch) }
        }
        engine.reset()
        return finished || !wasRunning
    }

    fun statsJson(): JSONObject? = try {
        bridge.stats()?.let { bytes ->
            String(bytes, Charsets.UTF_8).takeIf { it.isNotBlank() }?.let(::JSONObject)
        }
    } catch (_: Throwable) {
        null
    }

    private suspend fun pollLoop(boundEpoch: Long) {
        try {
            while (running.get() && scope.isActive) {
                val claim = bridge.next(250)
                if (claim == -1L) break
                if (claim <= 0L) continue
                handle(claim, boundEpoch)
            }
        } finally {
            running.set(false)
            runCatching { bridge.laneClosed(boundEpoch) }
        }
    }

    private suspend fun handle(claim: Long, boundEpoch: Long) {
        if (!running.get() || bridge.shouldStop(claim)) {
            bridge.complete(claim, STATUS_CANCELLED, null)
            return
        }
        val text = try {
            bridge.describe(claim)?.let { String(it, Charsets.UTF_8) }
        } catch (_: Throwable) {
            null
        }
        val request = text?.let { runCatching { JSONObject(it) }.getOrNull() }
        if (request == null) {
            completeJson(claim, STATUS_SHAPE, error("invalidRequest", "invalidHostRequest"))
            return
        }
        try {
            val claimEpoch = request.optLong("claimEpoch", -1L)
            if (claimEpoch != boundEpoch || epoch != boundEpoch) {
                completeJson(claim, STATUS_GENERATION, error("staleEpoch", "staleNativeEpoch"))
                return
            }
            val operation = request.optString("operation", "")
            val response = when (operation) {
                "location.fix" -> location()
                "contacts.scan" -> contacts(request)
                "nfc.read" -> nfc(request)
                "health.samples" -> healthSamples(request)
                "health.aggregate" -> healthAggregate(request)
                else -> throw SystemServiceFailure(
                    SystemServiceFailureCode.INVALID_REQUEST,
                    "unsupported system operation",
                )
            }
            completeJson(claim, STATUS_OK, response)
        } catch (cancelled: CancellationException) {
            bridge.complete(claim, STATUS_CANCELLED, null)
            throw cancelled
        } catch (failure: SystemServiceFailure) {
            completeJson(claim, STATUS_OK, failure(failure))
        } catch (throwable: Throwable) {
            log("system operation failed: ${throwable.javaClass.simpleName}")
            completeJson(
                claim,
                STATUS_OK,
                error(
                    "internalFailure",
                    "systemOperationFailed",
                    retryable = false,
                    detail = throwable.message?.take(160),
                ),
            )
        }
    }

    private suspend fun location(): JSONObject {
        val fix = engine.locationFix()
        return JSONObject().apply {
            put("ok", true)
            put("schema", HOST_SCHEMA)
            put("latitude", fix.latitude)
            put("longitude", fix.longitude)
            put("accuracyMeters", fix.accuracyMeters)
            put("timestamp", fix.timestamp.toString())
            put("precise", fix.precise)
            put("provider", fix.provider)
        }
    }

    private suspend fun contacts(request: JSONObject): JSONObject {
        val query = request.optString("query", "").takeIf { it.isNotBlank() }
        val field = request.optString("field", "any").takeIf { it.isNotBlank() }
        val scanToken = request.optString("scanToken", "").takeIf { it.isNotBlank() }
        val offset = request.optInt("offset", 0)
        val limit = request.optInt("limit", 50)
        val page = engine.contactsScan(query, field, scanToken, offset, limit)
        val rows = JSONArray()
        var encodedBytes = 0
        var trimmed = false
        for (row in page.rows) {
            val value = JSONObject().apply {
                put("id", row.id)
                put("displayName", row.displayName)
                put("organization", row.organization)
                put("phones", JSONArray(row.phones))
                put("emails", JSONArray(row.emails))
            }
            val rowBytes = value.toString().toByteArray(Charsets.UTF_8).size
            if (rows.length() > 0 && encodedBytes + rowBytes > REPLY_ROW_BUDGET) {
                trimmed = true
                break
            }
            rows.put(value)
            encodedBytes += rowBytes
        }
        return JSONObject().apply {
            put("ok", true)
            put("schema", HOST_SCHEMA)
            put("scanToken", page.scanToken)
            put("rows", rows)
            put("totalCount", page.totalCount)
            put("truncated", page.truncated || trimmed)
            val next = page.nextOffset?.takeIf { !trimmed } ?: (offset + rows.length())
                .takeIf { it < page.totalCount }
            next?.let { put("nextOffset", it) }
        }
    }

    private suspend fun nfc(request: JSONObject): JSONObject {
        val timeout = request.optInt("timeoutSeconds", 20)
        val result = engine.nfcRead(currentActivity(), timeout)
        val records = JSONArray()
        for (record in result.records) {
            records.put(
                JSONObject().apply {
                    put("index", record.index)
                    put("tnf", record.tnf)
                    put("type", record.type)
                    put("id", record.id)
                    put("kind", record.kind)
                    record.value?.let { put("value", it) }
                    put("payloadBytes", record.payloadBytes)
                    put("payloadSHA256", record.payloadSHA256)
                    put("truncated", record.truncated)
                },
            )
        }
        return JSONObject().apply {
            put("ok", true)
            put("schema", HOST_SCHEMA)
            put("records", records)
            put("rawBytes", result.rawBytes)
            put("writable", result.writable)
            put("techList", JSONArray(result.techList))
            put("truncated", result.truncated)
            put("elapsedMs", result.elapsedMs)
        }
    }

    private suspend fun healthSamples(request: JSONObject): JSONObject {
        val metric = HealthMetric.parse(request.optString("metric", ""))
            ?: throw SystemServiceFailure(SystemServiceFailureCode.INVALID_REQUEST, "invalid health metric")
        val start = instant(request.optString("start", ""), "start")
        val end = instant(request.optString("end", ""), "end")
        val limit = request.optInt("limit", 50)
            .coerceIn(1, com.floe.android.core.systemservices.SystemServicesBounds.MAX_HEALTH_PAGE)
        val pageToken = request.optString("pageToken", "").takeIf { it.isNotBlank() }
        val page = engine.healthSamples(metric, start, end, limit, pageToken)
        val rows = JSONArray()
        for (row in page.rows) {
            rows.put(
                JSONObject().apply {
                    put("metric", row.metric)
                    put("start", row.start.toString())
                    put("end", row.end.toString())
                    row.value?.let { put("value", it) }
                    put("unit", row.unit)
                    row.detail?.let { put("detail", it) }
                },
            )
        }
        return JSONObject().apply {
            put("ok", true)
            put("schema", HOST_SCHEMA)
            put("rows", rows)
            page.nextPageToken?.let { put("nextPageToken", it) }
            put("totalScanned", page.totalScanned)
            put("truncated", page.truncated)
        }
    }

    private suspend fun healthAggregate(request: JSONObject): JSONObject {
        val metric = HealthMetric.parse(request.optString("metric", ""))
            ?: throw SystemServiceFailure(SystemServiceFailureCode.INVALID_REQUEST, "invalid health metric")
        val aggregation = HealthAggregation.parse(request.optString("aggregation", ""))
            ?: throw SystemServiceFailure(SystemServiceFailureCode.INVALID_REQUEST, "invalid health aggregation")
        val start = instant(request.optString("start", ""), "start")
        val end = instant(request.optString("end", ""), "end")
        val result = engine.healthAggregate(metric, aggregation, start, end)
        return JSONObject().apply {
            put("ok", true)
            put("schema", HOST_SCHEMA)
            put("metric", result.metric)
            put("aggregation", result.aggregation)
            result.value?.let { put("value", it) }
            put("unit", result.unit)
            put("recordCount", result.recordCount)
            put("start", result.start.toString())
            put("end", result.end.toString())
            result.detail?.let { put("detail", it) }
        }
    }

    private fun completeJson(claim: Long, status: Int, value: JSONObject) {
        val bytes = value.toString().toByteArray(Charsets.UTF_8)
        if (bytes.size > MAX_REPLY_BYTES) {
            bridge.complete(
                claim,
                status,
                error("responseTooLarge", "providerReplyTooLarge").toString().toByteArray(Charsets.UTF_8),
            )
            return
        }
        bridge.complete(claim, status, bytes)
    }

    private fun failure(failure: SystemServiceFailure): JSONObject = error(
        code = failure.code.wire,
        reason = failure.message,
        retryable = failure.retryable,
        detail = failure.detail,
    )

    private fun error(
        code: String,
        reason: String,
        retryable: Boolean = false,
        detail: String? = null,
    ): JSONObject = JSONObject().apply {
        put("ok", false)
        put("schema", HOST_SCHEMA)
        put("code", code)
        put("reason", reason.take(160))
        put("retryable", retryable)
        detail?.let { put("detail", it.take(240)) }
    }

    private fun instant(raw: String, field: String): Instant = try {
        Instant.parse(raw)
    } catch (_: Exception) {
        throw SystemServiceFailure(
            SystemServiceFailureCode.INVALID_REQUEST,
            "invalid $field instant",
        )
    }

    companion object {
        const val HOST_SCHEMA = "floe.system.host/1"
        const val MAX_REPLY_BYTES = 49_152
        const val REPLY_ROW_BUDGET = 32_768
        const val STATUS_OK = 0
        const val STATUS_SHAPE = -105
        const val STATUS_GENERATION = -102
        const val STATUS_CANCELLED = -109
    }
}
