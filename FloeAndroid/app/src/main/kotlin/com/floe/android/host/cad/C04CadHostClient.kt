// SPDX-License-Identifier: MPL-2.0
//
// App-side client for the host-only `floe.cad/8` channel. Only structured
// metadata crosses this seam: no file bytes, image bytes, HTML, host path or
// credential. The Swift core validates ownership/path/resource rules and
// returns opaque resource ids plus readiness/capture receipts.
package com.floe.android.host.cad

import com.floe.android.bridge.SwiftCore
import com.floe.android.host.Owner
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

internal fun interface C04CadTransport {
    fun exchange(request: String): String
}

internal object SwiftC04CadTransport : C04CadTransport {
    override fun exchange(request: String): String = SwiftCore.exchange(request)
}

internal class C04CadHostFailure(val code: String) : Exception(code)

internal data class C04CadResourceDescriptor(
    val relativePath: String,
    val byteCount: Long,
    val sha256: String,
    val mediaType: String,
) {
    fun toJson(): JsonObject = buildJsonObject {
        put("relativePath", relativePath)
        put("byteCount", byteCount)
        put("sha256", sha256)
        put("mediaType", mediaType)
    }
}

internal data class C04CadBounds(
    val minimum: List<Double>? = null,
    val maximum: List<Double>? = null,
    val center: List<Double>? = null,
    val radius: Double? = null,
) {
    fun toJson(): JsonObject = buildJsonObject {
        minimum?.let { values ->
            put("min", buildJsonArray { values.forEach { value -> add(JsonPrimitive(value)) } })
        }
        maximum?.let { values ->
            put("max", buildJsonArray { values.forEach { value -> add(JsonPrimitive(value)) } })
        }
        center?.let { values ->
            put("center", buildJsonArray { values.forEach { value -> add(JsonPrimitive(value)) } })
        }
        radius?.let { put("radius", it) }
    }
}

internal data class C04CadSceneFacts(
    val format: C04CadFormat,
    val sourceUnits: String,
    val displayUnits: String,
    val bounds: C04CadBounds,
    val entityCount: Int?,
    val meshCount: Int,
    val triangleCount: Int,
    val vertexCount: Int,
    val missingResourceCount: Int,
    val frameSequence: Int,
    val limitations: String,
) {
    fun toJson(): JsonObject = buildJsonObject {
        put("format", format.extension)
        put("sourceUnits", sourceUnits)
        put("displayUnits", displayUnits)
        put("bounds", bounds.toJson())
        entityCount?.let { put("entityCount", it) }
        put("meshCount", meshCount)
        put("triangleCount", triangleCount)
        put("vertexCount", vertexCount)
        put("missingResourceCount", missingResourceCount)
        put("frameSequence", frameSequence)
        put("limitations", limitations)
        put("rendered", true)
    }
}

internal data class C04CadCoreSession(
    val sessionID: String,
    val tokenByPath: Map<String, String>,
    val reader: String,
    val family: String,
)

internal data class C04CadCoreReadiness(
    val sessionID: String,
    val frameSequence: Int,
)

internal data class C04CadCoreCapture(
    val receiptID: String,
    val sessionID: String,
    val pngSHA256: String,
    val byteCount: Long,
    val pixelWidth: Int,
    val pixelHeight: Int,
    val frameSequence: Int,
    val capturedAt: String?,
)

internal data class C04CadExtensionSummary(
    val schema: String,
    val meshVersion: Int,
    val meshCount: Int,
    val imageCount: Int,
    val resourceCount: Int,
    val totalBytes: Long,
    val sourceUnits: String,
    val upAxis: String,
)

internal class C04CadHostClient(
    private val transport: C04CadTransport = SwiftC04CadTransport,
) {
    private val json = Json { ignoreUnknownKeys = false }

    fun handshake(): JsonObject = call(
        buildJsonObject {
            put("version", VERSION)
            put("operation", "handshake")
            put("requestID", UUID.randomUUID().toString())
        },
    )

    fun begin(
        owner: Owner,
        relativePath: String,
        format: C04CadFormat,
        sourceBytes: Long,
        resources: List<C04CadResourceDescriptor>,
    ): C04CadCoreSession {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c04.session.begin")
                put("requestID", UUID.randomUUID().toString())
                put("owner", buildJsonObject {
                    put("taskID", owner.taskID)
                    put("workspaceID", owner.workspaceID)
                    put("nativeEpoch", owner.nativeEpoch)
                    put("hostGeneration", owner.hostGeneration)
                })
                put("relativePath", relativePath)
                put("format", format.extension)
                put("sourceBytes", sourceBytes)
                put("resources", buildJsonArray {
                    resources.forEach { add(it.toJson()) }
                })
            },
        )
        val sessionID = response.string("sessionID")
            ?: throw C04CadHostFailure("missingSessionID")
        val grants = response["grants"] as? JsonArray ?: JsonArray(emptyList())
        val tokens = LinkedHashMap<String, String>()
        for (grant in grants) {
            val objectValue = grant as? JsonObject ?: continue
            val path = objectValue.string("relativePath") ?: continue
            val token = objectValue.string("resourceID") ?: continue
            val canonical = try {
                UUID.fromString(token).toString()
            } catch (_: IllegalArgumentException) {
                throw C04CadHostFailure("invalidResourceID")
            }
            if (!canonical.equals(token, ignoreCase = true)) {
                throw C04CadHostFailure("invalidResourceID")
            }
            tokens[path] = token
        }
        if (tokens.size != resources.size) throw C04CadHostFailure("resourceGrantMismatch")
        val routing = response["routing"] as? JsonObject
        return C04CadCoreSession(
            sessionID = sessionID,
            tokenByPath = tokens,
            reader = routing?.string("reader") ?: format.reader,
            family = routing?.string("family") ?: format.wireName,
        )
    }

    fun readiness(sessionID: String, facts: C04CadSceneFacts): C04CadCoreReadiness {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c04.session.readiness")
                put("requestID", UUID.randomUUID().toString())
                put("sessionID", sessionID)
                put("facts", facts.toJson())
            },
        )
        return C04CadCoreReadiness(
            sessionID = response.string("sessionID") ?: sessionID,
            frameSequence = response.int("frameSequence") ?: facts.frameSequence,
        )
    }

    fun capture(
        sessionID: String,
        pngHeaderHex: String,
        pngSHA256: String,
        byteCount: Long,
        pixelWidth: Int,
        pixelHeight: Int,
        frameSequence: Int,
    ): C04CadCoreCapture {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c04.session.capture")
                put("requestID", UUID.randomUUID().toString())
                put("sessionID", sessionID)
                put("pngHeaderHex", pngHeaderHex)
                put("pngSHA256", pngSHA256)
                put("byteCount", byteCount)
                put("pixelWidth", pixelWidth)
                put("pixelHeight", pixelHeight)
                put("frameSequence", frameSequence)
            },
        )
        val receipt = response["receipt"] as? JsonObject
            ?: throw C04CadHostFailure("missingCaptureReceipt")
        return C04CadCoreCapture(
            receiptID = receipt.string("receiptID")
                ?: throw C04CadHostFailure("missingReceiptID"),
            sessionID = receipt.string("sessionID") ?: sessionID,
            pngSHA256 = receipt.string("pngSHA256") ?: pngSHA256,
            byteCount = receipt.long("byteCount") ?: byteCount,
            pixelWidth = receipt.int("pixelWidth") ?: pixelWidth,
            pixelHeight = receipt.int("pixelHeight") ?: pixelHeight,
            frameSequence = receipt.int("frameSequence") ?: frameSequence,
            capturedAt = receipt.string("capturedAt"),
        )
    }

    fun end(sessionID: String): Int {
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c04.session.end")
                put("requestID", UUID.randomUUID().toString())
                put("sessionID", sessionID)
            },
        )
        return response.int("released") ?: 0
    }

    fun cancelAll() {
        call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c04.cancelAll")
                put("requestID", UUID.randomUUID().toString())
            },
        )
    }

    fun validateExtension(manifestJson: String): C04CadExtensionSummary {
        val manifest = try {
            json.parseToJsonElement(manifestJson)
        } catch (_: Throwable) {
            throw C04CadHostFailure("invalidPackageJson")
        }
        if (manifest !is JsonObject) throw C04CadHostFailure("invalidPackageJson")
        val response = call(
            buildJsonObject {
                put("version", VERSION)
                put("operation", "c04.extension.validate")
                put("requestID", UUID.randomUUID().toString())
                put("manifest", manifest)
            },
        )
        val summary = response["summary"] as? JsonObject
            ?: throw C04CadHostFailure("missingPackageSummary")
        return C04CadExtensionSummary(
            schema = summary.string("schema") ?: C04CadPackageContract.schema,
            meshVersion = summary.int("meshVersion")
                ?: throw C04CadHostFailure("missingPackageSummary"),
            meshCount = summary.int("meshCount") ?: 0,
            imageCount = summary.int("imageCount") ?: 0,
            resourceCount = summary.int("resourceCount") ?: 0,
            totalBytes = summary.long("totalBytes") ?: 0L,
            sourceUnits = summary.string("sourceUnits") ?: "unknown",
            upAxis = summary.string("upAxis") ?: "z",
        )
    }

    private fun call(request: JsonObject): JsonObject {
        val raw = try {
            transport.exchange(request.toString())
        } catch (error: Throwable) {
            throw C04CadHostFailure(
                if (error is LinkageError) "coreUnavailable" else "transport")
        }
        val response = try {
            json.parseToJsonElement(raw) as? JsonObject
        } catch (_: Throwable) {
            null
        } ?: throw C04CadHostFailure("invalidResponse")
        val ok = (response["ok"] as? JsonPrimitive)?.booleanOrNull == true
        if (!ok) {
            val code = response.string("code") ?: response.string("error") ?: "refused"
            throw C04CadHostFailure(code)
        }
        val version = response.int("version")
        if (version != null && version != VERSION) {
            throw C04CadHostFailure("unsupportedVersion")
        }
        return response
    }

    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    private fun JsonObject.int(key: String): Int? =
        (this[key] as? JsonPrimitive)?.intOrNull

    private fun JsonObject.long(key: String): Long? =
        (this[key] as? JsonPrimitive)?.longOrNull

    companion object {
        const val VERSION = 8
    }
}

internal object C04CadPackageContract {
    const val schema = "floe.cad-package/1"
}
