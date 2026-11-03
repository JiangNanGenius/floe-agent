// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.fonts

import android.content.Context
import android.system.Os
import android.system.OsConstants
import com.floe.android.bridge.SwiftCore
import com.floe.android.core.fonts.ManagedFontStore
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.UUID

/** Single App-owned mailbox drain. No JNI call awaits filesystem/Typeface.
 * A claimed operation is synchronous on this IO lane; coroutine cancellation
 * cannot manufacture physical settlement. Unknown settlements are retried,
 * never the font mutation itself. */
internal class FontToolHostPump(
    context: Context, private val scope: CoroutineScope,
    private val currentEpoch: () -> Long?,
) {
    private val app = context.applicationContext
    private val store = ManagedFontStore(app)
    @Volatile private var stopping = false
    @Volatile private var boundEpoch = 0L
    @Volatile private var needsBind = true
    @Volatile private var pending: Settlement? = null
    private var job: Job? = null
    private data class Settlement(val epoch: Long, val id: String, val receipt: String)
    private fun call(operation: String, epoch: Long, configure: JSONObject.() -> Unit = {}): JSONObject {
        val request = JSONObject().put("version", 27).put("operation", operation).put("epoch", epoch)
            .put("requestID", UUID.randomUUID().toString()).apply(configure)
        val encoded = request.toString()
        require(encoded.toByteArray().size <= 65536) { "Font host request too large" }
        val raw = SwiftCore.exchange(encoded)
        require(raw.toByteArray().size <= 65536) { "Font host reply too large" }
        return JSONObject(raw).also { require(it.getInt("version") == 27) }
    }
    @Synchronized fun start() {
        if (job?.isActive == true) return
        stopping = false
        needsBind = true
        job = scope.launch(Dispatchers.IO) {
            try {
            while (isActive && (!stopping || pending != null)) {
                val settlement = pending
                if (settlement != null) {
                    if (runCatching { call("font.host.settle", settlement.epoch) {
                        put("ticketID", settlement.id); put("receipt", settlement.receipt)
                    }.optBoolean("ok") }.getOrDefault(false)) pending = null
                    else delay(200)
                    continue
                }
                if (stopping) break
                val epoch = currentEpoch()?.takeIf { it > 0 } ?: boundEpoch.takeIf { it > 0 }
                if (epoch == null) { delay(200); continue }
                if (epoch != boundEpoch || needsBind) {
                    if (boundEpoch > 0 && epoch != boundEpoch) runCatching { call("font.host.close", boundEpoch) }
                    if (!runCatching { call("font.host.bind", epoch).optBoolean("ok") }.getOrDefault(false)) {
                        delay(200); continue
                    }
                    boundEpoch = epoch
                    needsBind = false
                }
                val response = runCatching { call("font.host.claim", epoch) }.getOrNull()
                val ticket = response?.takeIf { it.optBoolean("ok") }?.optJSONObject("ticket")
                if (ticket == null) { delay(100); continue }
                val id = ticket.getString("id")
                require(UUID.fromString(id).toString() == id && ticket.getLong("epoch") == epoch)
                val receipt = try {
                    val request = JSONObject(ticket.getString("request"))
                    if (request.optString("ownerScope") == "dataExchange") {
                        require(UUID.fromString(request.getString("exchangeID")).toString() == request.getString("exchangeID"))
                    } else {
                        require(UUID.fromString(request.getString("taskID")).toString() == request.getString("taskID"))
                        require(UUID.fromString(request.getString("runID")).toString() == request.getString("runID"))
                    }
                    execute(epoch, id, request)
                } catch (_: com.floe.android.core.fonts.FontCommitUncertain) {
                    JSONObject().put("ok", false).put("error", "outcomeUnknown")
                } catch (_: Exception) { JSONObject().put("ok", false).put("error", "fontOperationFailed") }
                  catch (_: LinkageError) { JSONObject().put("ok", false).put("error", "fontServiceUnavailable") }
                pending = Settlement(epoch, id, receipt.toString())
            }
            } finally {
                if (boundEpoch > 0) runCatching { call("font.host.close", boundEpoch) }
            }
        }
    }
    @Synchronized fun resumeAfterRefusedStop() {
        stopping = false
        needsBind = true
        if (job?.isActive != true) start()
    }
    suspend fun stopAndJoin(): Boolean = withContext(NonCancellable + Dispatchers.IO) {
        stopping = true
        val epoch = boundEpoch
        if (epoch > 0) runCatching { call("font.host.close", epoch) }
        val owned = synchronized(this@FontToolHostPump) { job }
        val joined = withTimeoutOrNull(5000) { owned?.join(); true } == true
        val drained = epoch <= 0 || runCatching { call("font.host.close", epoch).optBoolean("drained") }.getOrDefault(false)
        joined && pending == null && drained
    }
    private fun execute(epoch: Long, id: String, request: JSONObject): JSONObject {
        val allowed = {
            !stopping && boundEpoch == epoch && runCatching {
                call("font.host.canCommit", epoch) { put("ticketID", id) }.optBoolean("allowed")
            }.getOrDefault(false)
        }
        check(allowed()) { "Font operation cancelled" }
        val method = request.getString("method")
        if (method.startsWith("snapshot.")) {
            require(request.optString("ownerScope") == "dataExchange")
            val exchangeID = request.getString("exchangeID")
            val snapshots = com.floe.android.core.fonts.ManagedFontSnapshots(store)
            return when (method) {
                "snapshot.export" -> snapshots.export(exchangeID)
                "snapshot.prepare" -> snapshots.prepare(exchangeID, request.getString("catalogSHA256"), allowed)
                "snapshot.status" -> snapshots.status(exchangeID)
                "snapshot.adopt" -> snapshots.adopt(exchangeID, allowed)
                "snapshot.rollback" -> snapshots.rollback(exchangeID, request.optString("allowMissing") == "true")
                "snapshot.complete" -> snapshots.complete(exchangeID)
                else -> error("Unsupported font snapshot operation")
            }
        }
        return when (method) {
            "list" -> page(request.optString("cursor", "").takeIf { it.isNotEmpty() })
            "remove" -> JSONObject().put("ok", true).put("removed", store.remove(request.getString("id"), allowed))
            "install" -> {
                val inputID = request.getString("inputID")
                require(UUID.fromString(inputID).toString() == inputID)
                val digest = request.getString("sha256"); require(digest.matches(Regex("[a-f0-9]{64}")))
                val bytes = request.getLong("byteCount"); require(bytes in 12..32L * 1024 * 1024)
                val parent = File(app.filesDir, "FontIncomingV1")
                val directory = File(parent, inputID)
                listOf(parent, directory).forEach { require(OsConstants.S_ISDIR(Os.lstat(it.path).st_mode)) }
                val file = File(directory, "font.bin")
                require(OsConstants.S_ISREG(Os.lstat(file.path).st_mode) && file.length() == bytes)
                val entry = store.install(file.inputStream(), digest, bytes, allowed)
                JSONObject().put("ok", true).put("font", entryJSON(entry))
            }
            else -> error("Unsupported font operation")
        }
    }
    private fun entryJSON(entry: ManagedFontStore.Entry): JSONObject {
        val faces = JSONArray()
        entry.faces.forEach { faces.put(JSONObject().put("name", it.name).put("index", it.index)
            .put("reference", entry.reference(it))) }
        return JSONObject().put("id", entry.id).put("bytes", entry.bytes).put("faces", faces)
    }
    private fun page(cursor: String?): JSONObject {
        val entries = store.list().sortedBy { it.id }
        val fingerprint = MessageDigest.getInstance("SHA-256").digest(entries.joinToString("\n") { it.id }.toByteArray())
            .joinToString("") { "%02x".format(it) }
        val start = if (cursor == null) 0 else {
            val parts = cursor.split(':'); require(parts.size == 2 && parts[0] == fingerprint) { "Font list changed" }
            parts[1].toInt().also { require(it in 0..entries.size) }
        }
        val values = JSONArray(); var end = start
        var size = 0
        while (end < entries.size && end - start < 25) {
            val entry = entryJSON(entries[end]); val bytes = entry.toString().toByteArray().size
            if (size + bytes > 24 * 1024) break
            values.put(entry); size += bytes; end++
        }
        require(end > start || end == entries.size) { "Font entry too large" }
        return JSONObject().put("ok", true).put("fonts", values).put("hasMore", end < entries.size)
            .put("nextCursor", if (end < entries.size) "$fingerprint:$end" else JSONObject.NULL)
    }
}
