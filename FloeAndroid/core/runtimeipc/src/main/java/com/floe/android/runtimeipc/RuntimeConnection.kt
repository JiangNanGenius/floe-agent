// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtimeipc

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.Handler
import android.os.Looper
import android.os.Parcel
import org.json.JSONObject
import java.io.Closeable
import java.util.concurrent.CompletableFuture

/** Application-owned connection. Binder work must be called on an IO executor. */
class RuntimeConnection(
    context: Context,
    private val foregroundPermit: IBinder? = null,
    private val workspaceGrant: IBinder? = null,
) : Closeable {
    private val context = context.applicationContext
    val packages = RuntimePackages.forCore(context.packageName)
    private val verifier = RuntimePeerVerifier(context)
    private var endpoint: IBinder? = null
    private var pending: CompletableFuture<Unit>? = null
    private var bound = false
    private var closed = false
    private val mainHandler = Handler(Looper.getMainLooper())

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, service: IBinder) {
            synchronized(this@RuntimeConnection) {
                if (closed) return
                try {
                    check(name == ComponentName(packages.runtime, RuntimePackages.SERVICE))
                    verifier.verifyPeer(packages.runtime)
                    check(service.interfaceDescriptor == RuntimeWire.DESCRIPTOR)
                    service.linkToDeath({ disconnected() }, 0)
                    endpoint = service
                    pending?.complete(Unit)
                } catch (failure: Exception) {
                    pending?.completeExceptionally(failure)
                    close()
                }
            }
        }
        override fun onServiceDisconnected(name: ComponentName) = disconnected()
        override fun onBindingDied(name: ComponentName) { disconnected(); close() }
        override fun onNullBinding(name: ComponentName) { disconnected(); close() }
    }

    @Synchronized fun connect(): CompletableFuture<Unit> {
        check(!closed) { "Runtime connection is closed" }
        if (endpoint != null) return CompletableFuture.completedFuture(Unit)
        pending?.let { return it }
        val future = CompletableFuture<Unit>()
        pending = future
        try {
            verifier.verifyPeer(packages.runtime)
            bound = context.bindService(Intent().setComponent(
                ComponentName(packages.runtime, RuntimePackages.SERVICE)), connection, Context.BIND_AUTO_CREATE)
            check(bound) { "Runtime component unavailable" }
            // A timeout does not cancel any admitted workload. Closing only drops the binding.
            val timeout = Runnable {
                future.completeExceptionally(IllegalStateException("Runtime connection timed out"))
            }
            mainHandler.postDelayed(timeout, 10_000)
            future.whenComplete { _, failure ->
                mainHandler.removeCallbacks(timeout)
                if (failure != null) close()
            }
        } catch (failure: Exception) {
            future.completeExceptionally(failure)
            close()
        }
        return future
    }

    fun exchange(operation: String, payload: JSONObject = JSONObject(), requestID: String = java.util.UUID.randomUUID().toString()): JSONObject {
        check(android.os.Looper.myLooper() != android.os.Looper.getMainLooper()) {
            "Runtime IPC requires an IO executor"
        }
        val binder = synchronized(this) { check(!closed); checkNotNull(endpoint) }
        verifier.verifyPeer(packages.runtime)
        val text = RuntimeWire.encode(operation, payload, requestID)
        val request = RuntimeWire.decode(text)
        val data = Parcel.obtain()
        val result = Parcel.obtain()
        try {
            data.writeInterfaceToken(RuntimeWire.DESCRIPTOR)
            data.writeString(text)
            data.writeStrongBinder(foregroundPermit)
            data.writeStrongBinder(workspaceGrant)
            check(binder.transact(RuntimeWire.EXCHANGE, data, result, 0))
            require(result.dataSize() <= RuntimeWire.MAX_PARCEL_BYTES)
            result.readException()
            return RuntimeWire.verifyReply(request, requireNotNull(result.readString()))
        } finally { data.recycle(); result.recycle() }
    }

    @Synchronized private fun disconnected() {
        endpoint = null
        pending?.completeExceptionally(IllegalStateException("Runtime disconnected; work is not replayed"))
        pending = null
    }

    @Synchronized override fun close() {
        if (closed) return
        closed = true
        disconnected()
        if (bound) { bound = false; context.unbindService(connection) }
    }
}
