// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import android.content.Context
import com.floe.android.bridge.LinuxAuthorityNative
import com.floe.android.linuxruntime.ExitResult
import com.floe.android.linuxruntime.supervision.ProcessBirth
import com.floe.android.linuxruntime.supervision.Quiescence
import com.floe.android.runtimeipc.RuntimePackages
import com.floe.android.runtimeipc.RuntimePeerVerifier
import com.floe.android.runtimeipc.RuntimeWire
import org.json.JSONObject
import java.io.File
import java.util.UUID

/** Only the authority's bounded code crosses the metadata diagnostic seam. */
internal class RuntimeAuthorityRefusal(rawCode: String) : IllegalStateException("Environment authority refused the request.") {
    val code: String = rawCode.takeIf {
        it.length in 1..48 && it.all { c -> c.isLetterOrDigit() && c.code < 128 }
    } ?: "refused"

    companion object {
        fun metadataCode(operation: String, failure: Exception): String? =
            if (operation == "environment.list" && failure is RuntimeAuthorityRefusal) {
                "authority_" + failure.code
            } else null
    }
}

/** Private native lifecycle. These methods never appear in the Binder dispatch table. */
internal class LinuxAuthorityClient(context: Context) {
    private val filesRoot = context.filesDir.canonicalFile

    init {
        val packages = RuntimePackages.forRuntime(context.packageName)
        RuntimePeerVerifier(context).verifyPeer(packages.core)
    }

    data class Lease(val id: String, val descriptor: JSONObject) {
        val environmentID: String get() = descriptor.getString("environmentID")
    }

    @Synchronized fun configure(base: File, baseRevision: String) {
        val basePath = base.canonicalFile
        require(basePath.toPath().startsWith(filesRoot.toPath()) && basePath.isDirectory)
        val state = File(filesRoot, "Environments").apply { check(mkdirs() || isDirectory) }
        val workspaces = File(filesRoot, "Workspaces").apply { check(mkdirs() || isDirectory) }
        exchange("configure", JSONObject().put("stateRoot", state.canonicalPath)
            .put("workspacesRoot", workspaces.canonicalPath).put("baseRoot", basePath.path)
            .put("baseRevision", baseRevision))
    }

    /**
     * FROZEN legacy global metadata reply. Every sorted registry row in ONE
     * native reply; an inventory that encodes past the 64 KiB wire ceiling
     * fails closed with `replyTooLarge`. New callers that may face a large
     * registry MUST use [listPage] instead. Retained because the bounded
     * workspace-cleanup ownership proof still reads it, and because the
     * version-1 legacy shape is intentionally unchanged.
     */
    @Synchronized fun list(): JSONObject = exchange("list")
    @Synchronized fun handshake(): JSONObject = exchange("handshake")

    /**
     * ADDITIVE bounded metadata page (`listPage`). [projectID] is the already
     * validated canonical uppercase project UUID (null = global); [cursor] is
     * the opaque continuation returned by the previous page (null = first);
     * [limit] is 1..200 complete rows. The native authority filters the
     * trusted project BEFORE encoding and fits only complete rows within the
     * frozen 64 KiB reply ceiling.
     */
    @Synchronized fun listPage(projectID: String?, cursor: String?, limit: Int): JSONObject {
        val payload = JSONObject().put("limit", limit)
        if (projectID != null) payload.put("projectID", projectID)
        if (cursor != null) payload.put("cursor", cursor)
        return exchange("listPage", payload)
    }

    @Synchronized fun acquire(payload: JSONObject): Lease {
        val arguments = JSONObject().put("projectID", payload.getString("projectID"))
            .put("runID", payload.getString("runID"))
        for (key in listOf("conversationID", "environmentID", "leaseRole", "environmentScope")) {
            if (payload.has(key) && !payload.isNull(key)) arguments.put(key, payload.getString(key))
        }
        val result = exchange("acquire", arguments)
        return Lease(result.getString("leaseID"), result.getJSONObject("descriptor"))
    }

    @Synchronized fun started(lease: Lease, birth: ProcessBirth) {
        exchange("markStarted", JSONObject().put("leaseID", lease.id).put("processIdentity", identity(birth)))
    }

    @Synchronized fun cancel(lease: Lease) { exchange("cancel", JSONObject().put("leaseID", lease.id)) }

    /** Only for a launch that never started, or a stopped failed-spawn path proven by its owner. */
    @Synchronized fun abandonUnstarted(lease: Lease) { exchange("abandon", JSONObject().put("leaseID", lease.id)) }

    /** Root reap AND dedicated-UID proof are mandatory before the original lease is released. */
    @Synchronized fun complete(lease: Lease, birth: ProcessBirth, exit: ExitResult, proof: Quiescence.Proven) {
        // G07.3A: a per-workload proof may legitimately coexist with OTHER
        // owned workloads, so the audit is not globally "clean". The proof's
        // own scoped live set is empty by construction (`Quiescence.Proven`);
        // the inventory itself must still be fully readable and unambiguous.
        check(exit.waitErrno == 0 && proof.stableSamples >= 2 &&
            proof.audit.inventoryFailure == null && proof.audit.ambiguous.isEmpty())
        val status = if (exit.signaled) exit.termSig and 0x7f else (exit.exitCode and 0xff) shl 8
        exchange("complete", JSONObject().put("leaseID", lease.id).put("processIdentity", identity(birth))
            .put("quiescence", JSONObject().put("reaped", true).put("exitStatus", status)))
    }

    private fun identity(birth: ProcessBirth) = JSONObject().put("pid", birth.pid)
        .put("launcherToken", birth.identity)

    private fun exchange(operation: String, payload: JSONObject? = null): JSONObject {
        check(android.os.Looper.myLooper() != android.os.Looper.getMainLooper())
        val requestID = UUID.randomUUID().toString()
        val operationValue: Any = payload?.let { JSONObject().put(operation, it) } ?: operation
        val request = JSONObject().put("version", 1).put("requestID", requestID).put("operation", operationValue)
        val nativeResponse = try { LinuxAuthorityNative.exchange(RuntimeWire.bounded(request.toString())) }
        catch (failure: LinkageError) { throw IllegalStateException("Runtime native component unavailable", failure) }
        val response = JSONObject(RuntimeWire.bounded(nativeResponse))
        check(response.getInt("version") == 1 && response.getString("requestID") == requestID)
        val outcome = response.getJSONObject("outcome")
        if (outcome.has("failure")) {
            throw RuntimeAuthorityRefusal(outcome.optJSONObject("failure")?.optString("code").orEmpty())
        }
        // Frozen V1 uses named operation results, with no synthesized _0 wrapper.
        return outcome.getJSONObject("ok").getJSONObject(operation)
    }
}
