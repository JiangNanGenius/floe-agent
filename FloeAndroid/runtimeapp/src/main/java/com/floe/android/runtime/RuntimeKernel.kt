// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import android.content.Context
import android.os.IBinder
import com.floe.android.runtimeipc.RuntimeWire
import org.json.JSONObject
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** Implemented by the native-authority + installer + real process composition. */
internal interface RuntimeOperations {
    fun execute(request: RuntimeWire.Request, workspaceGrant: IBinder?, cancelled: () -> Boolean): JSONObject
    fun isExecuting(): Boolean
    /** Memory-only pages/progress. No disk, native, process waits or network. */
    fun snapshot(request: RuntimeWire.Request): JSONObject?
    fun validateCancellation(request: RuntimeWire.Request)
    fun stopOwnedWork(request: RuntimeWire.Request? = null)
    fun hasOwnedWork(): Boolean
}

/** Bounded transient IPC receipts, not the main App's durable BackgroundJobStore. */
class RuntimeKernel(context: Context) {
    private val context = context.applicationContext
    private val executor = ThreadPoolExecutor(1, 1, 30, TimeUnit.SECONDS,
        ArrayBlockingQueue(8)) { work -> Thread(work, "floe-linux-control") }.apply { allowCoreThreadTimeOut(true) }
    private val stopExecutor = ThreadPoolExecutor(1, 1, 30, TimeUnit.SECONDS,
        ArrayBlockingQueue(1)) { work -> Thread(work, "floe-linux-stop") }.apply { allowCoreThreadTimeOut(true) }
    private val stopQueued = AtomicBoolean()
    private val count = AtomicInteger()
    private val stopping = AtomicBoolean()
    private val pendingInstallID = AtomicReference<String?>()
    private val pendingShellID = AtomicReference<String?>()
    private val pendingPreflightID = AtomicReference<String?>()
    // REAL engine PROCESS generation, measured identity — never an auth
    // token and never a random success flag: the kernel object is created
    // once per runtime process instance (held by RuntimeApplication), so
    // pid + this boot nonce identify exactly one live peer generation.
    // Authentication stays exclusively in RuntimePeerVerifier and
    // RuntimeForegroundPermit; the trusted host readiness controller reads
    // these fields over the already-authenticated binder and refuses a
    // silent generation swap.
    private val runtimeBootToken: String get() = RuntimeProcessIdentity.bootToken
    private val runtimePid: Int get() = RuntimeProcessIdentity.pid
    private val receipts = LinkedHashMap<String, JSONObject>()
    @Volatile private var operations: RuntimeOperations? = null
    @Volatile var onChanged: ((Boolean) -> Unit)? = null

    fun hasOwnedWork(): Boolean = count.get() > 0 || operations?.hasOwnedWork() == true
    fun isExecuting(): Boolean = operations?.isExecuting() == true

    fun exchange(request: RuntimeWire.Request, workspaceGrant: IBinder?, foregroundAllowed: () -> Boolean): JSONObject {
        if (request.operation == "status") return JSONObject()
            .put("protocol", RuntimeWire.VERSION).put("foreground", foregroundAllowed())
            .put("active", hasOwnedWork()).put("stopping", stopping.get())
            .put("localNetworkGranted", android.os.Build.VERSION.SDK_INT < 37 || context.checkSelfPermission(
                RuntimeAccessActivity.PERMISSION) == android.content.pm.PackageManager.PERMISSION_GRANTED)
            // Loading metadata or binding the component does not enable a tool.
            .put("modelExecutionReady", false)
            // Actual applied guest resolver state (additive diagnostics;
            // counts/classes only, never raw server addresses).
            .put("resolver", RuntimeNetworkConfiguration.statusSnapshot())
            // Process-generation identity for the host's live anchoring.
            .put("runtimePid", runtimePid).put("runtimeBootToken", runtimeBootToken)
            // The workload contract version is advertised ONLY when this
            // kernel genuinely runs a single-slot executor with the
            // exclusive-start admission below. It is the engine's own real
            // attestation; an idle check belongs to the host ingest.
            .put("workloadContractVersion", if (executor.maximumPoolSize == 1) WORKLOAD_CONTRACT else "")
        if (request.operation == "request.status") {
            require(request.payload.keys().asSequence().toSet() == setOf("requestID"))
            val id = request.payload.getString("requestID")
            return synchronized(receipts) {
                receipts[id]?.let { JSONObject(it.toString()) }
                    ?: JSONObject().put("state", "unknown")
            }
        }
        operations?.snapshot(request)?.let { return it }
        if (request.operation == "install.cancel" || request.operation == "shell.cancel" ||
            request.operation == RuntimeWire.PREFLIGHT_CANCEL
        ) {
            // Urgent stop is never queued behind a download/materialization.
            if (request.operation == "install.cancel" && pendingInstallID.get() == request.payload.optString("requestID")) {
                require(request.payload.keys().asSequence().toSet() == setOf("requestID"))
            } else if (request.operation == "shell.cancel" && pendingShellID.get() == request.payload.optString("requestID")) {
                require(request.payload.keys().asSequence().toSet() == setOf("requestID"))
            } else if (request.operation == RuntimeWire.PREFLIGHT_CANCEL &&
                pendingPreflightID.get() == request.payload.optString("requestID")
            ) {
                require(request.payload.keys().asSequence().toSet() == setOf("requestID"))
            } else checkNotNull(operations).validateCancellation(request)
            requestStop(request)
            return JSONObject().put("state", "stop_requested")
        }
        val metadataOnly = request.operation == "install.status" || request.operation == "environment.list"
        // G03-R3 cleanup lane: data-deletion obligations must stay serviceable
        // while shell/model admission is fenced (the caller carries NO
        // foreground permit for them). This exemption is ONLY for the typed
        // scoped wipe; stopping still refuses, no grant is accepted/required,
        // and the receiver performs its own busy/quiescence deferral first.
        val cleanupLane = request.operation == RuntimeWire.CLEANUP
        if (request.operation == "shell.start" || request.operation == RuntimeWire.PREFLIGHT)
            check(workspaceGrant != null) { "Owned workspace grant is required" }
        check(metadataOnly || cleanupLane || foregroundAllowed()) { "Foreground work ownership is required" }
        check(!stopping.get()) { "Runtime is stopping" }
        synchronized(receipts) {
            receipts[request.id]?.let { return JSONObject(it.toString()) }
            if (request.operation == "install.start" || request.operation == "shell.start" ||
                request.operation == RuntimeWire.PREFLIGHT
            ) {
                // Exclusive single-workload admission: an unrelated busy
                // workload A makes a NEW preflight REFUSE before any state
                // is written; nothing about A is touched or cancelled.
                check(!hasOwnedWork()) { "Runtime already owns work" }
            }
            while (receipts.size >= 64) {
                val evict = receipts.entries.firstOrNull { it.value.optString("state") in setOf("completed", "failed") }
                    ?: error("Runtime control is busy")
                receipts.remove(evict.key)
            }
            receipts[request.id] = JSONObject().put("requestID", request.id).put("state", "queued")
            count.incrementAndGet() // reserve admission before another Binder call
            if (request.operation == "install.start") pendingInstallID.set(request.id)
            if (request.operation == "shell.start") pendingShellID.set(request.id)
            if (request.operation == RuntimeWire.PREFLIGHT) pendingPreflightID.set(request.id)
        }
        try {
            executor.execute {
                update(request.id, JSONObject().put("state", "running"))
                try {
                    check(!stopping.get() && (metadataOnly || cleanupLane || foregroundAllowed()))
                    // All native loading, disk work and real command admission
                    // happen on this owned IO thread, never on Binder/Main.
                    val runtime = operations ?: LinuxRuntimeOperations(context).also { operations = it }
                    check(!stopping.get() && (metadataOnly || cleanupLane || foregroundAllowed()))
                    val result = runtime.execute(request, workspaceGrant) { stopping.get() || (!metadataOnly && !foregroundAllowed()) }
                    RuntimeWire.bounded(result.toString())
                    update(request.id, JSONObject().put("state", "completed").put("result", result))
                } catch (_: Exception) {
                    // Never reflect command lines, paths, output or native error
                    // descriptions into Android system logs or generic notices.
                    update(request.id, JSONObject().put("state", "failed").put("code", "operation_failed"))
                } finally {
                    pendingInstallID.compareAndSet(request.id, null)
                    pendingShellID.compareAndSet(request.id, null)
                    pendingPreflightID.compareAndSet(request.id, null)
                    count.decrementAndGet()
                    if (!hasOwnedWork()) stopping.set(false)
                    onChanged?.invoke(stopping.get())
                }
            }
        } catch (_: RejectedExecutionException) {
            pendingInstallID.compareAndSet(request.id, null)
            pendingShellID.compareAndSet(request.id, null)
            pendingPreflightID.compareAndSet(request.id, null)
            count.decrementAndGet()
            synchronized(receipts) { receipts.remove(request.id) }
            throw IllegalStateException("Runtime control queue full")
        }
        onChanged?.invoke(false)
        return JSONObject().put("requestID", request.id).put("state", "queued")
    }

    fun requestStop(request: RuntimeWire.Request? = null) {
        stopping.set(true)
        if (stopQueued.compareAndSet(false, true)) stopExecutor.execute {
            try { operations?.stopOwnedWork(request) }
            catch (_: Exception) {
                // Keep owned work/leases and the stopping notice. An inability
                // to stop is not permission to tear down their directories.
            }
            finally {
                stopQueued.set(false)
                if (!hasOwnedWork()) stopping.set(false)
                onChanged?.invoke(stopping.get())
            }
        }
        if (!hasOwnedWork()) stopping.set(false)
        onChanged?.invoke(true)
    }

    private fun update(id: String, value: JSONObject) {
        value.put("requestID", id)
        synchronized(receipts) { receipts[id] = value }
    }

    companion object {
        /** Real single-workload engine contract (single-slot executor plus
         *  the exclusive-start admission above). Ingested as a FACT only
         *  while the engine additionally reports itself idle. */
        const val WORKLOAD_CONTRACT = "floe-single-workload-v1"
    }
}
