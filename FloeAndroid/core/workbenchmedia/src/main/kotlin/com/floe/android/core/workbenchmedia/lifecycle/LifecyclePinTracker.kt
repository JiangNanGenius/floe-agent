// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.lifecycle

import com.floe.android.core.workbenchmedia.MediaLifecyclePin
import com.floe.android.core.workbenchmedia.MediaLifecyclePinDecision
import com.floe.android.core.workbenchmedia.MediaLifecyclePinRequest
import com.floe.android.core.workbenchmedia.WorkbenchMediaLifecycleAuthority
import com.floe.android.core.workbenchmedia.util.MediaPaths
import com.floe.android.core.workbenchmedia.util.RENDERER_UNAVAILABLE
import com.floe.android.core.workbenchmedia.util.refusal
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal data class PinDrainReport(
    val drained: Boolean,
    val outstanding: Int,
    val inFlightAcquisitions: Int = 0,
    val releaseUnknown: Boolean = false,
    val reason: String? = null,
)

/**
 * Session-owned registry of native lifecycle pins. A pin is registered before
 * the platform hands the snapshot to a player/encoder/renderer, retained
 * through the actual worker/codec/player close, and removed only after native
 * confirms the unpin. A failed or unconfirmed release keeps the reference and
 * makes `drain()` fail closed; it never decrements a pin that may still be
 * owned by a worker.
 */
internal class LifecyclePinTracker(
    private val authority: WorkbenchMediaLifecycleAuthority,
    ioDispatcher: CoroutineDispatcher,
) {
    private val lock = Any()
    private val scope = CoroutineScope(SupervisorJob() + ioDispatcher)
    private val pins = ConcurrentHashMap<String, TrackedPin>()
    private val acquiring = AtomicInteger(0)
    @Volatile private var fenced = false
    @Volatile private var closed = false

    /**
     * One-way drain fence. It is synchronized with [acquire]'s entry so an
     * acquire cannot slip into the gap between "not fenced" and registration
     * while drain is deciding that no pin/acquire is outstanding.
     */
    fun fence() {
        synchronized(lock) { fenced = true }
    }

    suspend fun acquire(request: MediaLifecyclePinRequest): MediaLifecyclePin {
        synchronized(lock) {
            if (fenced || closed) {
                throw refusal(RENDERER_UNAVAILABLE, "The media session lifecycle registry is no longer accepting pins")
            }
            acquiring.incrementAndGet()
        }
        try {
            return acquireRegistered(request)
        } finally {
            acquiring.decrementAndGet()
        }
    }

    private suspend fun acquireRegistered(request: MediaLifecyclePinRequest): MediaLifecyclePin {
        val decision = try {
            // A pin RPC must not be abandoned halfway through: if native has
            // already incremented its refcount, the caller needs the token so
            // the worker can release it after its IO actually stops.
            withContext(NonCancellable) { authority.pin(request) }
        } catch (failure: Exception) {
            throw refusal(
                RENDERER_UNAVAILABLE,
                "The native lifecycle pin could not be acquired: ${failure.message}",
                retryable = true,
            )
        }
        val pin = when (decision) {
            is MediaLifecyclePinDecision.Pinned -> decision.pin
            is MediaLifecyclePinDecision.Refused -> throw refusal(
                decision.code.ifBlank { RENDERER_UNAVAILABLE },
                decision.reason,
                decision.retryable,
            )
        }
        val invalidReason = validateEcho(pin, request)
        if (invalidReason != null) {
            // Preserve the native reference even though the echo is unusable.
            // It is released here when possible; a failed release remains
            // tracked so session drain reports an outstanding pin instead of
            // pretending the Root can be freed.
            registerAndReleaseAsync(pin)
            throw refusal(RENDERER_UNAVAILABLE, invalidReason)
        }
        val previous = pins.putIfAbsent(pin.pinToken, TrackedPin(pin))
        if (previous != null) {
            // A duplicate current token would make a later release decrement
            // another owner's pin. Do not release it here; fail closed and
            // require the native adapter to issue unique tokens.
            throw refusal(
                RENDERER_UNAVAILABLE,
                "The native lifecycle authority returned an already-owned pin token",
            )
        }
        return pin
    }

    fun releaseAsync(pin: MediaLifecyclePin) {
        // Mark the intentional release request before dispatching. A pin whose
        // owner path failed before requesting release (for example a failed
        // player close) must remain owned; drain must not "help" by releasing
        // a reference the owner may still need.
        pins[pin.pinToken]?.releaseRequested?.set(true)
        scope.launch { release(pin) }
    }

    /**
     * Idempotent release. Returns true only when the tracked native pin is
     * actually gone. A concurrent release of the same token returns false
     * rather than calling native twice; the owner/drain retries after the
     * in-flight attempt finishes.
     */
    suspend fun release(pin: MediaLifecyclePin): Boolean {
        val tracked = pins[pin.pinToken] ?: return true
        tracked.releaseRequested.set(true)
        if (!tracked.tryBeginRelease()) return false
        return try {
            val released = try {
                withContext(NonCancellable) { authority.release(tracked.pin) }
            } catch (_: Exception) {
                false
            }
            if (released) {
                pins.remove(tracked.pin.pinToken, tracked)
                true
            } else {
                tracked.unknown.set(true)
                false
            }
        } finally {
            tracked.endRelease()
        }
    }

    fun outstandingCount(): Int = pins.size

    /**
     * Waits for worker/player releases, retries any idle retained pin once, and
     * reports truthfully. It never removes a pin without a native success.
     */
    suspend fun awaitDrained(timeoutMillis: Long): PinDrainReport {
        val deadline = System.currentTimeMillis() + timeoutMillis.coerceIn(0L, 60_000L)
        while ((pins.isNotEmpty() || acquiring.get() > 0) && System.currentTimeMillis() < deadline) {
            delay(50L)
        }
        if (pins.isNotEmpty()) {
            for (tracked in pins.values.toList()) {
                if (tracked.releaseRequested.get()) {
                    release(tracked.pin)
                }
            }
        }
        while ((pins.isNotEmpty() || acquiring.get() > 0) && System.currentTimeMillis() < deadline) {
            delay(25L)
        }
        val outstanding = pins.size
        val inFlight = acquiring.get()
        val unknown = pins.values.any { it.unknown.get() }
        return PinDrainReport(
            drained = outstanding == 0 && inFlight == 0,
            outstanding = outstanding,
            inFlightAcquisitions = inFlight,
            releaseUnknown = outstanding > 0 && unknown,
            reason = when {
                outstanding == 0 && inFlight == 0 -> null
                inFlight > 0 -> "A native lifecycle pin acquisition is still in flight"
                unknown -> "A native lifecycle pin release was not confirmed"
                else -> "Native lifecycle pins are still owned"
            },
        )
    }

    /** Cancel the helper scope only after every pin was confirmed released. */
    fun shutdown() {
        synchronized(lock) { closed = true }
        scope.cancel()
    }

    private fun registerAndReleaseAsync(pin: MediaLifecyclePin) {
        val tracked = TrackedPin(pin)
        if (pins.putIfAbsent(pin.pinToken, tracked) == null) {
            releaseAsync(pin)
        }
    }

    private fun validateEcho(pin: MediaLifecyclePin, request: MediaLifecyclePinRequest): String? {
        if (pin.pinToken.isBlank() || pin.pinToken.length > 512 ||
            pin.pinToken.any { it.isWhitespace() }
        ) {
            return "The native lifecycle pin token is not a bounded opaque value"
        }
        if (pin.epoch != request.epoch) {
            return "The native lifecycle pin belongs to a different epoch"
        }
        if (pin.projectID != request.context.projectID) {
            return "The native lifecycle pin belongs to another project"
        }
        if (pin.kind != request.kind || pin.attemptID != request.attemptID) {
            return "The native lifecycle pin does not match the requested attempt"
        }
        val expectedRoot = MediaPaths.canonicalRoot(request.mediaRootPath)
            ?: return "The requested lifecycle root is not an existing directory"
        val pinnedRoot = MediaPaths.canonicalRoot(pin.mediaRootPath)
            ?: return "The native lifecycle pin root is not an existing directory"
        if (pinnedRoot.path != expectedRoot.path) {
            return "The native lifecycle pin root differs from the accepted project root"
        }
        return null
    }

    private class TrackedPin(val pin: MediaLifecyclePin) {
        private val releasing = AtomicInteger(0)
        val unknown = AtomicBoolean(false)
        val releaseRequested = AtomicBoolean(false)

        fun tryBeginRelease(): Boolean = releasing.compareAndSet(0, 1)

        fun endRelease() {
            releasing.set(0)
        }
    }
}
