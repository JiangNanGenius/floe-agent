// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.networkartifact

import com.floe.android.core.networkmonitor.CoverageLimits
import com.floe.android.core.networkmonitor.CoveragePoint
import com.floe.android.core.networkmonitor.CoverageProbeParser
import com.floe.android.core.networkmonitor.CoverageProbeResult
import com.floe.android.core.networkmonitor.CoverageScanParser
import com.floe.android.core.networkmonitor.CoverageScanStatus
import com.floe.android.core.networkmonitor.CoverageSession
import com.floe.android.core.networkmonitor.CoverageSessionStore
import com.floe.android.feature.network.CoverageSampleRequest
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import org.json.JSONArray
import org.json.JSONObject

/** The application-owned phone service seam; tests inject a scripted executor. */
interface CoverageCaptureExecutor {
    suspend fun execute(requestJson: String): String
    fun cancel(operationID: String)
}

enum class CoverageFailure {
    NOT_FOUND,
    INVALID_INPUT,
    SESSION_LIMIT,
    POINT_LIMIT,
    PERMISSION_REQUIRED,
    SCAN_FAILED,
    STORE_FAILED,
    CANCELLED,
}

sealed interface CoverageResult {
    data class Success(
        val session: CoverageSession,
        val missingPermissions: List<String> = emptyList(),
    ) : CoverageResult
    data class Failure(
        val failure: CoverageFailure,
        val missingPermissions: List<String> = emptyList(),
    ) : CoverageResult
}

/**
 * Application-owned Wi-Fi coverage operations. Every sample is started by an
 * explicit visible action; the coordinator performs exactly one
 * `network.wifiScan` (refresh=true), plus one optional user-enabled
 * ping/TCP/download probe. It never scans on a timer, never invents a signal
 * value and never falls back to the host/shell.
 */
class CoverageArtifactCoordinator(
    private val store: CoverageSessionStore,
    private val executor: CoverageCaptureExecutor,
    private val idFactory: () -> String = { UUID.randomUUID().toString() },
    private val now: () -> Long = System::currentTimeMillis,
    private val currentTaskId: () -> String? = { null },
    private val ownerWorkspaceId: String? = null,
    private val maxSessions: Int = CoverageLimits.MAX_SESSIONS,
) {
    fun sessions(): List<CoverageSession> = store.list(maxSessions)

    fun session(sessionID: String): CoverageSession? = runCatching { store.load(sessionID) }.getOrNull()

    fun floorplan(sessionID: String): ByteArray? =
        runCatching { store.readFloorplan(sessionID) }.getOrNull()

    fun createSession(name: String): CoverageResult {
        val trimmed = name.trim()
        if (trimmed.isEmpty() || trimmed.length > CoverageLimits.MAX_NAME_CHARS) {
            return CoverageResult.Failure(CoverageFailure.INVALID_INPUT)
        }
        if (store.list().size >= maxSessions) {
            return CoverageResult.Failure(CoverageFailure.SESSION_LIMIT)
        }
        val timestamp = now()
        val session = CoverageSession(
            sessionID = idFactory(),
            name = trimmed,
            createdAtEpochMillis = timestamp,
            updatedAtEpochMillis = timestamp,
            ownerTaskId = currentTaskId()?.takeIf { it.isNotBlank() && it.length <= 64 },
            floorplan = null,
            points = emptyList(),
            ownerWorkspaceId = ownerWorkspaceId,
            agentReadable = false,
        )
        return runCatching { store.save(session) }.fold(
            onSuccess = { CoverageResult.Success(it.session) },
            onFailure = { CoverageResult.Failure(CoverageFailure.STORE_FAILED) },
        )
    }

    suspend fun sample(
        sessionID: String,
        request: CoverageSampleRequest,
    ): CoverageResult {
        val session = session(sessionID) ?: return CoverageResult.Failure(CoverageFailure.NOT_FOUND)
        if (session.points.size >= CoverageLimits.MAX_POINTS_PER_SESSION) {
            return CoverageResult.Failure(CoverageFailure.POINT_LIMIT)
        }
        if ((request.label?.length ?: 0) > CoverageLimits.MAX_LABEL_CHARS) {
            return CoverageResult.Failure(CoverageFailure.INVALID_INPUT)
        }
        if (request.x !in 0.0..1.0 || request.y !in 0.0..1.0) {
            return CoverageResult.Failure(CoverageFailure.INVALID_INPUT)
        }
        currentCoroutineContext().ensureActive()
        val capturedAt = now()
        val scanOperation = UUID.randomUUID().toString()
        val scanResponse = try {
            executor.execute(scanRequest(scanOperation))
        } catch (cancelled: CancellationException) {
            runCatching { executor.cancel(scanOperation) }
            throw cancelled
        } catch (_: Exception) {
            return CoverageResult.Failure(CoverageFailure.SCAN_FAILED)
        }
        currentCoroutineContext().ensureActive()
        val scan = try {
            CoverageScanParser.parse(scanResponse, capturedAt)
        } catch (_: Exception) {
            return CoverageResult.Failure(CoverageFailure.SCAN_FAILED)
        }
        val missing = ArrayList<String>(scan.missingPermissions)
        var probe: CoverageProbeResult? = null
        currentCoroutineContext().ensureActive()
        request.probe?.let { requested ->
            val kind = requested.kind
            if (kind != "none") {
                val operation = UUID.randomUUID().toString()
                val response = try {
                    executor.execute(probeRequest(operation, requested))
                } catch (cancelled: CancellationException) {
                    runCatching { executor.cancel(operation) }
                    throw cancelled
                } catch (_: Exception) {
                    null
                }
                if (response != null) {
                    val parsed = runCatching {
                        CoverageProbeParser.parse(kind, response, now())
                    }.getOrNull()
                    if (parsed != null) {
                        probe = parsed
                        if (parsed.status == CoverageScanStatus.PERMISSION_REQUIRED.wire) {
                            missing += rootMissingPermissions(response)
                        }
                    } else {
                        probe = CoverageProbeResult(
                            kind = kind, status = "error",
                            targetHost = requested.host.takeIf { it.isNotBlank() },
                            errorCode = "invalidObservation",
                            measuredAtEpochMillis = now(),
                        )
                    }
                } else {
                    probe = CoverageProbeResult(
                        kind = kind, status = "error",
                        targetHost = requested.host.takeIf { it.isNotBlank() },
                        errorCode = "probeFailed",
                        measuredAtEpochMillis = now(),
                    )
                }
            }
        }
        currentCoroutineContext().ensureActive()
        val point = CoveragePoint(
            pointID = UUID.randomUUID().toString(),
            label = request.label,
            x = request.x,
            y = request.y,
            createdAtEpochMillis = capturedAt,
            scan = scan,
            probe = probe,
        )
        val updated = session.copy(
            points = session.points + point,
            updatedAtEpochMillis = maxOf(session.updatedAtEpochMillis, capturedAt),
        )
        val saved = runCatching { store.save(updated) }.getOrElse {
            return CoverageResult.Failure(CoverageFailure.STORE_FAILED)
        }
        return CoverageResult.Success(saved.session, missing.distinct())
    }

    /** Explicit user grant; does not imply any file or network permission. */
    fun setAgentReadable(sessionID: String, readable: Boolean): CoverageResult {
        val session = store.load(sessionID) ?: return CoverageResult.Failure(CoverageFailure.NOT_FOUND)
        val updated = session.copy(
            agentReadable = readable,
            updatedAtEpochMillis = maxOf(session.updatedAtEpochMillis, now()),
        )
        return runCatching { store.save(updated) }.fold(
            onSuccess = { CoverageResult.Success(it.session) },
            onFailure = { CoverageResult.Failure(CoverageFailure.STORE_FAILED) },
        )
    }

    fun deleteSession(sessionID: String): Boolean = runCatching { store.delete(sessionID) }.getOrDefault(false)

    fun saveFloorplan(
        sessionID: String,
        bytes: ByteArray,
        mimeType: String,
        width: Int,
        height: Int,
    ): CoverageResult = try {
        val updated = store.saveFloorplan(sessionID, bytes, mimeType, width, height, now())
        CoverageResult.Success(updated)
    } catch (_: IOException) {
        CoverageResult.Failure(CoverageFailure.STORE_FAILED)
    } catch (_: IllegalArgumentException) {
        CoverageResult.Failure(CoverageFailure.INVALID_INPUT)
    }

    private fun scanRequest(operationID: String): String = JSONObject()
        .put("version", 1)
        .put("operationID", operationID)
        .put("method", "network.wifiScan")
        .put("arguments", JSONObject().put("refresh", true))
        .toString()

    private fun probeRequest(operationID: String, request: com.floe.android.feature.network.CoverageProbeRequestUi): String {
        val arguments = JSONObject()
        val method = when (request.kind) {
            "ping" -> {
                arguments.put("host", request.host)
                arguments.put("count", 4)
                arguments.put("timeoutMs", 5_000)
                "network.ping"
            }
            "tcp" -> {
                arguments.put("host", request.host)
                arguments.put("port", request.port.toIntOrNull() ?: 443)
                arguments.put("timeoutMs", 5_000)
                "network.tcpProbe"
            }
            "speedDownload" -> {
                arguments.put("direction", "download")
                arguments.put("downloadUrl", request.endpointUrl)
                arguments.put("maxBytesPerDirection", 8_388_608)
                arguments.put("durationBudgetMs", 10_000)
                arguments.put("warmupBytes", 0)
                arguments.put("allowMetered", request.allowMetered)
                arguments.put("timeoutMs", 30_000)
                "network.speedTest"
            }
            else -> throw IllegalArgumentException("unsupported probe")
        }
        return JSONObject()
            .put("version", 1)
            .put("operationID", operationID)
            .put("method", method)
            .put("arguments", arguments)
            .toString()
    }

    private fun rootMissingPermissions(raw: String): List<String> = runCatching {
        val array = JSONObject(raw).optJSONArray("missingPermissions") ?: JSONArray()
        (0 until minOf(array.length(), 16)).mapNotNull { index ->
            array.optString(index).takeIf { it.isNotBlank() }?.take(128)
        }
    }.getOrDefault(emptyList())
}
