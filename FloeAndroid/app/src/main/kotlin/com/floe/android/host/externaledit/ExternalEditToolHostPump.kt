// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.externaledit

import android.app.Activity
import android.app.KeyguardManager
import com.floe.android.FloeApplication
import com.floe.android.bridge.SwiftCore
import com.floe.android.host.RuntimeHost
import java.lang.ref.WeakReference
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject

/** Common Full/Play Android editor adapter. Accessibility is not needed to
 * hand a file to an editor; automated phone input stays in the Full lane. */
internal class ExternalEditToolHostPump(private val host: RuntimeHost) {
    @Volatile private var activity: WeakReference<Activity>? = null
    @Volatile private var stopping = false
    @Volatile private var epoch = 0L
    @Volatile private var needsBind = true
    @Volatile private var pending: Settlement? = null
    private var job: Job? = null
    private data class Settlement(val epoch: Long, val ticket: String, val receipt: String)

    fun setActivity(value: Activity?) { activity = value?.let(::WeakReference) }
    private fun call(operation: String, expected: Long, configure: JSONObject.() -> Unit = {}): JSONObject {
        val request = JSONObject().put("version", 29).put("operation", operation)
            .put("epoch", expected).put("requestID", UUID.randomUUID().toString()).apply(configure)
        val encoded = request.toString()
        require(encoded.toByteArray().size <= 16384)
        val raw = SwiftCore.exchange(encoded)
        require(raw.toByteArray().size <= 16384)
        return JSONObject(raw).also { require(it.getInt("version") == 29) }
    }

    @Synchronized fun start() {
        if (job?.isActive == true) return
        stopping = false; needsBind = true
        job = host.scope.launch(Dispatchers.IO) {
            try {
                while (isActive && (!stopping || pending != null)) {
                    val settlement = pending
                    if (settlement != null) {
                        // Only the acknowledgement is repeated. No Intent or
                        // file effect is replayed after an uncertain return.
                        if (runCatching { call("externalEdit.host.settle", settlement.epoch) {
                            put("ticketID", settlement.ticket); put("receipt", settlement.receipt)
                        }.optBoolean("ok") }.getOrDefault(false)) pending = null
                        else delay(250)
                        continue
                    }
                    if (stopping) break
                    val current = host.nativeRootEpoch()
                    if (current == null) { delay(250); continue }
                    if (current != epoch || needsBind) {
                        if (epoch > 0 && epoch != current) runCatching { call("externalEdit.host.close", epoch) }
                        if (!runCatching { call("externalEdit.host.bind", current).optBoolean("ok") }.getOrDefault(false)) {
                            delay(250); continue
                        }
                        epoch = current; needsBind = false
                    }
                    val response = runCatching { call("externalEdit.host.claim", current) }.getOrNull()
                    val ticket = response?.takeIf { it.optBoolean("ok") }?.optJSONObject("ticket")
                    if (ticket == null) { delay(250); continue }
                    val id = ticket.optString("id")
                    // Preserve a claimed ticket even for a malformed trusted
                    // frame, so its owner receives an actual failure receipt.
                    val result = try {
                        require(ExternalEditOwner.validUUID(id) && ticket.getLong("epoch") == current)
                        execute(current, id, JSONObject(ticket.getString("request")))
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (_: Exception) { JSONObject().put("ok", false).put("error", "invalidEditorRequest") }
                    catch (_: LinkageError) { JSONObject().put("ok", false).put("error", "runtimeUnavailable") }
                    pending = Settlement(current, id, result.toString())
                }
            } finally { if (epoch > 0) runCatching { call("externalEdit.host.close", epoch) } }
        }
    }

    private suspend fun execute(expected: Long, ticket: String, request: JSONObject): JSONObject {
        require(request.keys().asSequence().toSet().all { it in setOf("action", "path", "taskID",
            "workspaceID", "runID", "callID", "sessionID", "chooseApplication") })
        val owner = ExternalEditOwner(request.getString("taskID"), request.getString("workspaceID"))
        val run = request.getString("runID"); require(ExternalEditOwner.validUUID(run))
        val callID = request.getString("callID")
        require(callID.length in 1..128 && callID.none { it.code < 32 })
        val action = request.getString("action"); require(action in setOf("open", "status", "finish", "cancel"))
        val path = request.getString("path"); require(path.length <= 1024 && ExternalEditPolicy.validPath(path))
        val session = if (request.has("sessionID")) request.getString("sessionID").also {
            require(ExternalEditOwner.validUUID(it)) } else null
        require(action == "open" || session != null)
        require(!request.has("chooseApplication") || request.get("chooseApplication") is Boolean)
        val allowed = {
            !stopping && epoch == expected && host.nativeRootEpoch() == expected && runCatching {
                call("externalEdit.host.canCommit", expected) { put("ticketID", ticket) }.optBoolean("allowed")
            }.getOrDefault(false)
        }
        if (!allowed()) return JSONObject().put("ok", false).put("error", "cancelled")
        val target = activity?.get()?.takeIf {
            !it.isFinishing && !it.isDestroyed &&
                (it.application as? FloeApplication)?.isActivityInForeground() == true &&
                host.conversations.currentVisibleConversationId().equals(owner.taskID, true) &&
                !it.getSystemService(KeyguardManager::class.java).isKeyguardLocked
        }
        return host.externalEdits.toolOperation(target, owner, action, path, session,
            request.optBoolean("chooseApplication"), "$run:$callID", allowed)
    }

    @Synchronized fun resumeAfterRefusedStop() {
        stopping = false; needsBind = true
        if (job?.isActive != true) start()
    }
    suspend fun stopAndJoin(): Boolean = withContext(NonCancellable + Dispatchers.IO) {
        stopping = true
        val expected = epoch
        if (expected > 0) runCatching { call("externalEdit.host.close", expected) }
        val owned = synchronized(this@ExternalEditToolHostPump) { job }
        val joined = withTimeoutOrNull(5000) { owned?.join(); true } == true
        val drained = expected <= 0 || runCatching {
            call("externalEdit.host.close", expected).optBoolean("drained")
        }.getOrDefault(false)
        joined && pending == null && drained
    }
}
