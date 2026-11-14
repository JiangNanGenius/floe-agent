// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtimeipc

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.DeadObjectException
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.os.RemoteException
import org.json.JSONObject
import java.io.Closeable
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeoutException

/** Application-owned connection. Binder work must be called on an IO executor. */
class RuntimeConnection(
    context: Context,
    private val foregroundPermit: IBinder? = null,
    private val workspaceGrant: IBinder? = null,
) : Closeable {
    private val context = context.applicationContext
    val packages = RuntimePackages.forCore(context.packageName)
    private val verifier = RuntimePeerVerifier(context)
    private val mainHandler = Handler(Looper.getMainLooper())

    /** One linked recipient per endpoint, fenced against a retired endpoint's queued death. */
    private var deathLink: Pair<IBinder, IBinder.DeathRecipient>? = null

    private val lifetime = RuntimeBinderLifetime<IBinder>()
    private var pending: CompletableFuture<Unit>? = null

    /**
     * G03-R3 additive trusted-host observer (Main merge region): invoked
     * once per ACTUAL loss of a live binder endpoint — peer death, service
     * disconnect, binding death or null binding — and NEVER for an
     * intentional local [close]. Observation only: it grants no permission,
     * relaxes no admission, and the readiness controller re-checks that the
     * callback belongs to its current generation before acting, so a late
     * callback can never revive a stopped or replaced root.
     */
    @Volatile var onPeerLost: (() -> Unit)? = null

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, service: IBinder) {
            var complete: CompletableFuture<Unit>? = null
            var refused: Exception? = null
            var lostEndpoint = false
            synchronized(this@RuntimeConnection) {
                if (lifetime.isClosed()) return
                try {
                    check(name == ComponentName(packages.runtime, RuntimePackages.SERVICE))
                    verifier.verifyPeer(packages.runtime)
                    check(service.interfaceDescriptor == RuntimeWire.DESCRIPTOR)
                    val attachment = lifetime.onConnected(service) ?: return
                    if (attachment.link) {
                        unlinkDeathLocked()
                        val recipient = IBinder.DeathRecipient {
                            disconnected(service, attachment.generation)
                        }
                        service.linkToDeath(recipient, 0)
                        deathLink = service to recipient
                    }
                    complete = pending
                    pending = null
                } catch (dead: DeadObjectException) {
                    // The endpoint died between delivery and link. Roll the
                    // published endpoint back and let the framework deliver
                    // the real disconnect; never link a dead object.
                    lifetime.onLost()
                    lostEndpoint = true
                    refused = IllegalStateException("Runtime endpoint is already dead", dead)
                } catch (failure: Exception) {
                    refused = failure
                }
                if (refused != null) {
                    complete = pending
                    pending = null
                }
            }
            refused?.let { failure ->
                complete?.completeExceptionally(failure)
                if (!lostEndpoint) close()
                return
            }
            complete?.complete(Unit)
        }

        override fun onServiceDisconnected(name: ComponentName) {
            // The binding is still registered; the framework reconnects the
            // SAME dispatcher. Re-binding here would leak a second one.
            disconnected()
        }

        override fun onBindingDied(name: ComponentName) {
            // The framework has already declared this binding dead; retiring
            // it through close() is what releases the ServiceDispatcher. The
            // binding is intentionally NOT re-created here.
            disconnected()
            close()
        }

        override fun onNullBinding(name: ComponentName) {
            // A null binding can never deliver a service: release the exact
            // dispatcher instead of leaving it registered forever.
            disconnected()
            close()
        }
    }

    /**
     * Coalesced, retry-safe connect.
     *
     * * a live endpoint is reused;
     * * an in-flight waiter is joined;
     * * a registered-but-disconnected binding is WAITED for (never re-bound);
     * * only a connection with no binding issues exactly one `bindService`.
     *
     * A waiter timeout fails ONLY that waiter: the binding stays registered
     * and may still deliver [ServiceConnection.onServiceConnected]. That is
     * what lets a cold, idle runtime service finish starting instead of being
     * unbound and re-bound every few seconds.
     */
    fun connect(): CompletableFuture<Unit> {
        synchronized(this) {
            check(!lifetime.isClosed()) { "Runtime connection is closed" }
            lifetime.liveEndpoint()?.let { return CompletableFuture.completedFuture(Unit) }
            pending?.let { return it }
            val future = CompletableFuture<Unit>()
            pending = future
            when (lifetime.connect()) {
                RuntimeBinderLifetime.Connect.LIVE -> {
                    pending = null
                    future.complete(Unit)
                    return future
                }
                RuntimeBinderLifetime.Connect.BIND -> {
                    try {
                        verifier.verifyPeer(packages.runtime)
                        val accepted = context.bindService(
                            Intent().setComponent(
                                ComponentName(packages.runtime, RuntimePackages.SERVICE)),
                            connection,
                            Context.BIND_AUTO_CREATE,
                        )
                        if (!accepted) {
                            lifetime.bindRefused()
                            pending = null
                            future.completeExceptionally(
                                IllegalStateException("Runtime component unavailable"))
                            return future
                        }
                    } catch (failure: Exception) {
                        lifetime.bindRefused()
                        pending = null
                        future.completeExceptionally(failure)
                        return future
                    }
                }
                RuntimeBinderLifetime.Connect.WAIT_FOR_RECONNECT -> Unit
                RuntimeBinderLifetime.Connect.CLOSED -> {
                    pending = null
                    throw IllegalStateException("Runtime connection is closed")
                }
            }
            // A timeout does not cancel any admitted workload and does not
            // drop the binding; it only ends THIS wait. Closing only happens
            // through close()/binding death.
            val timeout = Runnable {
                synchronized(this) { if (pending === future) pending = null }
                future.completeExceptionally(IllegalStateException(CONNECT_TIMEOUT_MESSAGE))
            }
            mainHandler.postDelayed(timeout, CONNECT_TIMEOUT_MILLIS)
            future.whenComplete { _, _ -> mainHandler.removeCallbacks(timeout) }
            return future
        }
    }

    fun exchange(operation: String, payload: JSONObject = JSONObject(), requestID: String = java.util.UUID.randomUUID().toString()): JSONObject {
        check(android.os.Looper.myLooper() != android.os.Looper.getMainLooper()) {
            "Runtime IPC requires an IO executor"
        }
        val binder = synchronized(this) {
            if (lifetime.isClosed()) throw RuntimeTransportFailure("Runtime connection is closed")
            lifetime.liveEndpoint() ?: throw RuntimeTransportFailure("Runtime connection is not bound")
        }
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
            val transacted = try {
                binder.transact(RuntimeWire.EXCHANGE, data, result, 0)
            } catch (dead: RemoteException) {
                // A dead/refused binder is a REAL transport loss: the caller
                // may drop this channel, but the authenticated endpoint is
                // never replaced silently here.
                throw RuntimeTransportFailure("Runtime transact failed", dead)
            }
            if (!transacted) throw RuntimeTransportFailure("Runtime transact was refused")
            if (result.dataSize() > RuntimeWire.MAX_PARCEL_BYTES) {
                throw RuntimeTransportFailure("Runtime reply exceeded the bounded parcel")
            }
            try { result.readException() } catch (remote: RuntimeException) {
                throw RuntimeTransportFailure("Runtime reply carried an exception", remote)
            }
            val reply = result.readString()
                ?: throw RuntimeTransportFailure("Runtime reply frame is missing")
            return try {
                RuntimeWire.verifyReply(request, reply)
            } catch (malformed: RuntimeException) {
                throw RuntimeTransportFailure("Runtime reply frame is malformed", malformed)
            }
        } finally {
            data.recycle()
            result.recycle()
        }
    }

    /**
     * G03-R3: the CURRENT authenticated peer facts for a live connection
     * (real peer UID, installed package version, actual signing-chain digest,
     * endpoint generation token). Trusted-host receipt stamping ONLY — the
     * measurement re-runs the same `RuntimePeerVerifier` admission and never
     * relaxes it; a closed/disconnected/changed peer returns null (an
     * "unknown", never a placeholder). Call off the main thread.
     */
    fun currentPeerProof(): RuntimePeerProof? {
        val binder = synchronized(this) {
            if (lifetime.isClosed()) return null
            lifetime.liveEndpoint() ?: return null
        }
        return RuntimePeerProof.measure(context, binder, synchronized(this) { lifetime.currentGeneration() })
    }

    private fun unlinkDeathLocked() {
        val linked = deathLink ?: return
        deathLink = null
        runCatching { linked.first.unlinkToDeath(linked.second, 0) }
    }

    private fun disconnected(expected: IBinder? = null, expectedGeneration: Long? = null) {
        val outcome = synchronized(this) {
            val lost = lifetime.onLost(expected, expectedGeneration)
            if (expected != null && !lost.wasLive) return
            // Link/unlink and publication share this lock. A disconnect must
            // never unlink a replacement registered by a concurrent callback.
            unlinkDeathLocked()
            val waiter = pending
            pending = null
            lost to waiter
        }
        // Unlink the EXACT recipient once; the endpoint may already be dead
        // (unlinkToDeath then throws IllegalArgumentException) — never fatal.
        outcome.second?.completeExceptionally(
            IllegalStateException("Runtime disconnected; work is not replayed"))
        // Observation only, fired for a REAL loss of a live endpoint (not for
        // the intentional local close(), which marks the connection closed
        // before any teardown).
        if (outcome.first.wasLive && !lifetime.isClosed()) runCatching { onPeerLost?.invoke() }
    }

    override fun close() {
        val outcome = synchronized(this) {
            if (lifetime.isClosed()) return
            val teardown = lifetime.close()
            unlinkDeathLocked()
            val waiter = pending
            pending = null
            teardown to waiter
        }
        outcome.second?.completeExceptionally(IllegalStateException("Runtime connection is closed"))
        if (outcome.first.unbind) runCatching { context.unbindService(connection) }
    }

    /** Internal bounded-lifecycle snapshot (diagnostics/regressions only). */
    internal fun lifecycleSnapshot(): LifecycleSnapshot = LifecycleSnapshot(
        bindAttempts = lifetime.bindAttempts,
        links = lifetime.links,
        unlinks = lifetime.unlinks,
        activeLinks = lifetime.activeLinks(),
        generation = lifetime.currentGeneration(),
        closed = lifetime.isClosed(),
    )

    internal data class LifecycleSnapshot(
        val bindAttempts: Int,
        val links: Int,
        val unlinks: Int,
        val activeLinks: Int,
        val generation: Long,
        val closed: Boolean,
    )

    companion object {
        /** The bounded waiter timeout value (never a connection teardown). */
        const val CONNECT_TIMEOUT_MESSAGE = "Runtime connection timed out"
        const val CONNECT_TIMEOUT_MILLIS = 10_000L
        private const val MAX_CAUSE_DEPTH = 8

        /**
         * True when [failure] is only a WAITER timeout: the binding may still
         * complete and must not be dropped. Accepts the caller's
         * [TimeoutException] and the engine's own coalesced-waiter failure
         * (wrapped by `CompletableFuture.get` in an [ExecutionException]).
         */
        fun isConnectWaitTimeout(failure: Throwable?): Boolean {
            var current = failure
            var depth = 0
            while (current != null && depth < MAX_CAUSE_DEPTH) {
                if (current is TimeoutException) return true
                if (current is IllegalStateException && current.message == CONNECT_TIMEOUT_MESSAGE) return true
                current = current.cause
                depth += 1
            }
            return false
        }
    }
}
