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

    @Synchronized fun list(): JSONObject = exchange("list")
    @Synchronized fun handshake(): JSONObject = exchange("handshake")

    @Synchronized fun acquire(payload: JSONObject): Lease {
        val arguments = JSONObject().put("projectID", payload.getString("projectID"))
            .put("runID", payload.getString("runID"))
        for (key in listOf("conversationID", "environmentID")) {
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
        check(exit.waitErrno == 0 && proof.audit.isCleanlyQuiescent && proof.stableSamples >= 2)
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
        check(!outcome.has("failure")) { "Environment authority refused $operation" }
        // Frozen V1 uses named operation results, with no synthesized _0 wrapper.
        return outcome.getJSONObject("ok").getJSONObject(operation)
    }
}
