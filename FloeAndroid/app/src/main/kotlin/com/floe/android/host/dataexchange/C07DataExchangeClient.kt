// SPDX-License-Identifier: MPL-2.0
//
// Synchronous trusted-host client for `floe.data/16`. It is called only from
// the App-owned controller on an IO dispatcher. It carries no path, SAF URI,
// credential or model text to the native side: only opaque stage/job IDs,
// bounded byte chunks and the accepted owner token+epoch.
package com.floe.android.host.dataexchange

import com.floe.android.bridge.SwiftCore
import java.util.Base64
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

internal interface C07DataExchangeTransport {
    fun exchange(request: String): String
}

internal object SwiftC07DataExchangeTransport : C07DataExchangeTransport {
    override fun exchange(request: String): String = SwiftCore.exchange(request)
}

internal data class C07ExchangeOwner(
    val token: String,
    val nativeEpoch: Long,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("token", token)
        put("nativeEpoch", nativeEpoch)
    }
}

internal class C07ClientFailure(
    val code: String,
    val reason: String,
    val retryable: Boolean = false,
) : Exception("$code:$reason")

internal data class C07CapabilitiesUi(
    val formatVersion: Int,
    val backupExtension: String,
    val notesExtension: String,
    val chunkBytes: Int,
    val included: List<String>,
    val excluded: List<Pair<String, String>>,
    val databaseCopied: Boolean,
)

internal data class C07Plan(
    val projects: Int,
    val projectFiles: Int,
    val noteDocuments: Int,
    val noteResources: Int,
    val notebooks: Int,
    val settingsKeys: Int,
    val providerAdvisories: Int,
    val trashedNotesExcluded: Int,
    val skippedProjects: Int,
    val warnings: List<String>,
)

internal data class C07Receipt(
    val projects: Int,
    val noteDocuments: Int,
    val notebooks: Int,
    val settings: Int,
    val skippedProjects: Int,
)

internal data class C07Job(
    val jobID: String,
    val kind: String,
    val phase: String,
    val doneBytes: Long,
    val totalBytes: Long,
    val errorCode: String?,
    val warnings: List<String>,
    val fileByteCount: Long?,
    val fileSha256: String?,
    val canCommit: Boolean,
    val plan: C07Plan?,
    val receipt: C07Receipt?,
) {
    val terminal: Boolean
        get() = phase == "ready" || phase == "complete" || phase == "failed" ||
            phase == "cancelled"
}

internal data class C07Chunk(
    val data: ByteArray,
    val nextOffset: Long,
    val totalBytes: Long,
    val eof: Boolean,
)

internal data class C07Stage(
    val stageID: String,
    val chunkBytes: Int,
    val totalBytes: Long,
)

internal class C07DataExchangeClient(
    private val transport: C07DataExchangeTransport = SwiftC07DataExchangeTransport,
) {
    fun capabilities(owner: C07ExchangeOwner): C07CapabilitiesUi {
        val response = exchange("c07.capabilities", owner) { }
        val excluded = mutableListOf<Pair<String, String>>()
        val array = response.optJSONArray("excluded") ?: JSONArray()
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            excluded += item.optString("id") to item.optString("reason")
        }
        val included = mutableListOf<String>()
        val includedArray = response.optJSONArray("included") ?: JSONArray()
        for (index in 0 until includedArray.length()) {
            includedArray.optString(index).takeIf { it.isNotEmpty() }?.let { included += it }
        }
        return C07CapabilitiesUi(
            formatVersion = response.optInt("formatVersion", 1),
            backupExtension = response.optString("backupExtension", "floebackup"),
            notesExtension = response.optString("notesExtension", "floenote"),
            chunkBytes = response.optInt("chunkBytes", 24_576),
            included = included,
            excluded = excluded,
            databaseCopied = response.optBoolean("databaseCopied", false),
        )
    }

    fun backupBegin(owner: C07ExchangeOwner, includeRetainedProjects: Boolean): String =
        exchange("c07.backup.begin", owner) {
            put("includeRetainedProjects", includeRetainedProjects)
        }.getString("jobID")

    fun noteExportBegin(owner: C07ExchangeOwner, documentID: String, revision: Int): String =
        exchange("c07.document.exportNote", owner) {
            put("documentID", documentID)
            put("expectedRevision", revision)
        }.getString("jobID")

    fun status(owner: C07ExchangeOwner, jobID: String): C07Job {
        val response = exchange("c07.job.status", owner) { put("jobID", jobID) }
        val planObject = response.optJSONObject("plan")
        val receiptObject = response.optJSONObject("receipt")
        return C07Job(
            jobID = response.optString("jobID", jobID),
            kind = response.optString("kind"),
            phase = response.optString("phase", "failed"),
            doneBytes = response.optLong("doneBytes", 0L),
            totalBytes = response.optLong("totalBytes", 0L),
            errorCode = response.optString("error").takeIf { it.isNotEmpty() },
            warnings = strings(response.optJSONArray("warnings")),
            fileByteCount = response.optLong("fileByteCount", -1L)
                .takeIf { it >= 0L },
            fileSha256 = response.optString("fileSHA256").takeIf { it.isNotEmpty() },
            canCommit = response.optBoolean("canCommit", false),
            plan = planObject?.let {
                C07Plan(
                    projects = it.optInt("projects", 0),
                    projectFiles = it.optInt("projectFiles", 0),
                    noteDocuments = it.optInt("noteDocuments", 0),
                    noteResources = it.optInt("noteResources", 0),
                    notebooks = it.optInt("notebooks", 0),
                    settingsKeys = it.optInt("settingsKeys", 0),
                    providerAdvisories = it.optInt("providerAdvisories", 0),
                    trashedNotesExcluded = it.optInt("trashedNotesExcluded", 0),
                    skippedProjects = it.optInt("skippedProjects", 0),
                    warnings = strings(response.optJSONArray("warnings")),
                )
            },
            receipt = receiptObject?.let {
                C07Receipt(
                    projects = it.optInt("projects", 0),
                    noteDocuments = it.optInt("noteDocuments", 0),
                    notebooks = it.optInt("notebooks", 0),
                    settings = it.optInt("settings", 0),
                    skippedProjects = it.optInt("projectsSkipped", 0),
                )
            },
        )
    }

    fun read(owner: C07ExchangeOwner, jobID: String, offset: Long, maxBytes: Int): C07Chunk {
        val response = exchange("c07.job.read", owner) {
            put("jobID", jobID)
            put("offset", offset)
            put("maxBytes", maxBytes)
        }
        val encoded = response.optString("dataBase64")
        return C07Chunk(
            data = if (encoded.isEmpty()) ByteArray(0) else Base64.getDecoder().decode(encoded),
            nextOffset = response.optLong("nextOffset", offset),
            totalBytes = response.optLong("totalBytes", 0L),
            eof = response.optBoolean("eof", true),
        )
    }

    fun close(owner: C07ExchangeOwner, jobID: String) {
        exchange("c07.job.close", owner) { put("jobID", jobID) }
    }

    fun cancel(owner: C07ExchangeOwner, jobID: String) {
        exchange("c07.job.cancel", owner) { put("jobID", jobID) }
    }

    fun stageBegin(owner: C07ExchangeOwner, byteCount: Long): C07Stage {
        val response = exchange("c07.restore.stageBegin", owner) {
            put("byteCount", byteCount)
        }
        return C07Stage(
            stageID = response.getString("stageID"),
            chunkBytes = response.optInt("chunkBytes", 24_576),
            totalBytes = response.optLong("totalBytes", byteCount),
        )
    }

    fun stageAppend(owner: C07ExchangeOwner, stageID: String, data: ByteArray): Pair<Long, Long> {
        val response = exchange("c07.restore.stageAppend", owner) {
            put("stageID", stageID)
            put("dataBase64", Base64.getEncoder().encodeToString(data))
        }
        return response.optLong("receivedBytes", 0L) to response.optLong("totalBytes", 0L)
    }

    fun stageCommit(owner: C07ExchangeOwner, stageID: String) {
        exchange("c07.restore.stageCommit", owner) { put("stageID", stageID) }
    }

    fun stageAbort(owner: C07ExchangeOwner, stageID: String) {
        runCatching {
            exchange("c07.restore.stageAbort", owner) { put("stageID", stageID) }
        }
    }

    fun inspect(owner: C07ExchangeOwner, stageID: String, notePackage: Boolean): String =
        exchange("c07.restore.inspect", owner) {
            put("stageID", stageID)
            put("kind", if (notePackage) "note" else "backup")
        }.getString("jobID")

    fun commit(owner: C07ExchangeOwner, jobID: String): String =
        exchange("c07.restore.commit", owner) { put("jobID", jobID) }
            .getString("jobID")

    fun abort(owner: C07ExchangeOwner, jobID: String) {
        runCatching { exchange("c07.restore.abort", owner) { put("jobID", jobID) } }
    }

    fun pending(owner: C07ExchangeOwner): Int =
        exchange("c07.restore.pending", owner) { }
            .optInt("pendingRecoveries", 0)

    fun recover(owner: C07ExchangeOwner): Pair<Int, Int> {
        val response = exchange("c07.restore.recover", owner) { }
        return response.optInt("recovered", 0) to response.optInt("failed", 0)
    }

    private fun exchange(
        operation: String,
        owner: C07ExchangeOwner,
        body: JSONObject.() -> Unit,
    ): JSONObject {
        val request = JSONObject().apply {
            put("version", PROTOCOL_VERSION)
            put("schema", SCHEMA)
            put("operation", operation)
            put("requestID", UUID.randomUUID().toString())
            put("owner", owner.toJson())
            body()
        }
        val raw = try {
            transport.exchange(request.toString())
        } catch (error: Throwable) {
            throw C07ClientFailure("bridgeUnavailable", error.javaClass.simpleName)
        }
        val response = try {
            JSONObject(raw)
        } catch (error: Throwable) {
            throw C07ClientFailure("invalidReply", "invalidJSON")
        }
        if (!response.optBoolean("ok", false)) {
            throw C07ClientFailure(
                code = response.optString("code", response.optString("error", "unknown")),
                reason = response.optString("reason"),
                retryable = response.optBoolean("retryable", false),
            )
        }
        return response
    }

    private fun strings(array: JSONArray?): List<String> {
        if (array == null) return emptyList()
        val values = ArrayList<String>(minOf(array.length(), 32))
        for (index in 0 until minOf(array.length(), 32)) {
            array.optString(index).takeIf { it.isNotEmpty() }?.let { values += it }
        }
        return values
    }

    internal companion object {
        const val PROTOCOL_VERSION = 16
        const val SCHEMA = "floe.data/16"
        const val MAX_CHUNK = 24_576
    }
}
