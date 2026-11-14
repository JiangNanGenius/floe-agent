// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtimeipc

/**
 * The ONE lifecycle authority for a [RuntimeConnection]'s service binding and
 * its binder death registration (job-d4aeae04aa5a4f6c).
 *
 * Device evidence (Samsung SM-G9810, Full 1.0.10/code118, Full 13):
 * ART aborted with `JNI global reference table overflow (max=51200)` and
 * `50069 of RuntimeConnection$connection$1$$ExternalSyntheticLambda0`. Every
 * `onServiceConnected` used to allocate a NEW `linkToDeath` lambda and the
 * connection never unlinked it, so every bind (and every re-bind after a
 * refused poll) permanently consumed one JNI global reference on the
 * process-cached `BinderProxy`. The same dump showed 436 outstanding
 * `LoadedApk$ServiceDispatcher$InnerConnection` entries: duplicate `bindService`
 * calls for one [android.content.ServiceConnection] were never released either.
 *
 * This class is pure Kotlin so the exact invariants are unit-testable on the
 * JVM without a device:
 *  * at most ONE death registration per live endpoint, unlinked on
 *    replacement/loss/close (the JNI leak cannot recur),
 *  * a disconnected service is NOT re-bound (the framework reconnects the
 *    existing binding); only a real bind refusal/loss frees the binding,
 *  * `close()` unlinks and unbinds exactly once and is idempotent,
 *  * a late `onServiceConnected` after [close] never links or publishes.
 *
 * It carries no permission, no identity and no admission decision: the
 * authenticated handshake and every runtime-side gate stay exactly where they
 * are.
 */
internal class RuntimeBinderLifetime<T : Any> {
    /** The next connect() step for the caller. */
    enum class Connect {
        /** A live authenticated endpoint already exists: reuse it. */
        LIVE,
        /** A binding is registered but not (yet) connected: wait, never re-bind. */
        WAIT_FOR_RECONNECT,
        /** No binding is outstanding: create exactly one. */
        BIND,
        /** The connection is closed: refuse. */
        CLOSED,
    }

    /** What an accepted endpoint requires from the caller. */
    data class Attachment<E>(val link: Boolean, val previous: E?, val generation: Long)

    /** What an endpoint loss requires from the caller. */
    data class Detachment<E>(val unlink: E?, val wasLive: Boolean)

    /** What close() requires from the caller. */
    data class Teardown<E>(val unlink: E?, val unbind: Boolean)

    private var closed = false
    private var binding = false
    private var endpoint: T? = null
    private var linked: T? = null
    private var generation = 0L

    /** Counters for bounded-lifecycle regressions. */
    var bindAttempts = 0
        private set
    var links = 0
        private set
    var unlinks = 0
        private set

    @Synchronized fun connect(): Connect {
        if (closed) return Connect.CLOSED
        if (endpoint != null) return Connect.LIVE
        if (binding) return Connect.WAIT_FOR_RECONNECT
        binding = true
        bindAttempts += 1
        return Connect.BIND
    }

    /** `bindService` answered false (or refused before it was issued). */
    @Synchronized fun bindRefused() {
        if (!closed) binding = false
    }

    /**
     * Publish an accepted endpoint. Returns null when the connection was
     * closed while the callback was in flight: the caller must not link it.
     * A repeated callback for the SAME binder object never links twice.
     */
    @Synchronized fun onConnected(next: T): Attachment<T>? {
        if (closed) return null
        val previous = linked
        val needsLink = previous !== next
        if (needsLink) {
            if (previous != null) unlinks += 1
            links += 1
        }
        linked = next
        endpoint = next
        if (needsLink) generation += 1
        return Attachment(needsLink, if (needsLink) previous else null, generation)
    }

    /**
     * A real loss of the endpoint (peer death, `onServiceDisconnected`, binding
     * death or a null binding). The caller unlinks [Detachment.unlink] before
     * observing anything else.
     *
     * The service BINDING is deliberately kept: `onServiceDisconnected` and
     * `onBindingDied` leave the registered dispatcher in place and the
     * framework reconnects it, so an eager re-bind here registered a second,
     * permanently leaked dispatcher entry (436 in the Full 13 crash dump).
     * Callers that must retire the binding do so through [close], which
     * unbinds exactly once.
     */
    @Synchronized fun onLost(expected: T? = null, expectedGeneration: Long? = null): Detachment<T> {
        if (expected != null && (endpoint !== expected || generation != expectedGeneration)) {
            return Detachment(null, false)
        }
        val previous = linked
        val wasLive = endpoint != null
        if (previous != null) unlinks += 1
        linked = null
        endpoint = null
        return Detachment(previous, wasLive)
    }

    @Synchronized fun close(): Teardown<T> {
        if (closed) return Teardown(null, false)
        closed = true
        val previous = linked
        val unbind = binding
        if (previous != null) unlinks += 1
        linked = null
        endpoint = null
        binding = false
        return Teardown(previous, unbind)
    }

    @Synchronized fun isClosed(): Boolean = closed

    @Synchronized fun liveEndpoint(): T? = if (closed) null else endpoint

    @Synchronized fun currentGeneration(): Long = generation

    @Synchronized fun activeLinks(): Int = if (linked == null) 0 else 1
}
