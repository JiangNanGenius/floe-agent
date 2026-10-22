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
        if (request.operation == "request.status") {
            require(request.payload.keys().asSequence().toSet() == setOf("requestID"))
            val id = request.payload.getString("requestID")
            return synchronized(receipts) {
                receipts[id]?.let { JSONObject(it.toString()) }
                    ?: JSONObject().put("state", "unknown")
            }
        }
        operations?.snapshot(request)?.let { return it }
        if (request.operation == "install.cancel" || request.operation == "shell.cancel") {
            // Urgent stop is never queued behind a download/materialization.
            if (request.operation == "install.cancel" && pendingInstallID.get() == request.payload.optString("requestID")) {
                require(request.payload.keys().asSequence().toSet() == setOf("requestID"))
            } else if (request.operation == "shell.cancel" && pendingShellID.get() == request.payload.optString("requestID")) {
                require(request.payload.keys().asSequence().toSet() == setOf("requestID"))
            } else checkNotNull(operations).validateCancellation(request)
            requestStop(request)
            return JSONObject().put("state", "stop_requested")
        }
        val metadataOnly = request.operation == "install.status" || request.operation == "environment.list"
        if (request.operation == "shell.start") check(workspaceGrant != null) { "Owned workspace grant is required" }
        check(metadataOnly || foregroundAllowed()) { "Foreground work ownership is required" }
        check(!stopping.get()) { "Runtime is stopping" }
        synchronized(receipts) {
            receipts[request.id]?.let { return JSONObject(it.toString()) }
            if (request.operation == "install.start" || request.operation == "shell.start") {
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
        }
        try {
            executor.execute {
                update(request.id, JSONObject().put("state", "running"))
                try {
                    check(!stopping.get() && (metadataOnly || foregroundAllowed()))
                    // All native loading, disk work and real command admission
                    // happen on this owned IO thread, never on Binder/Main.
                    val runtime = operations ?: LinuxRuntimeOperations(context).also { operations = it }
                    check(!stopping.get() && (metadataOnly || foregroundAllowed()))
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
                    count.decrementAndGet()
                    if (!hasOwnedWork()) stopping.set(false)
                    onChanged?.invoke(stopping.get())
                }
            }
        } catch (_: RejectedExecutionException) {
            pendingInstallID.compareAndSet(request.id, null)
            pendingShellID.compareAndSet(request.id, null)
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
}
