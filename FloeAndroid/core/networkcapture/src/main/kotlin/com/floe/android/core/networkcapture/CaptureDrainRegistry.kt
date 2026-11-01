// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkcapture

/**
 * Process-wide ledger of capture resources that still have a live owner.
 *
 * A terminal [CaptureState] alone is not proof that the data plane, helper
 * process, forwarders or PCAP writer stopped. RootStop consults this registry
 * as well as the state machine, so a timed-out drain keeps the old generation
 * pending instead of retiring a live owner. Entries are created only after the
 * service actually acquired the resource, and are removed only when every real
 * close/join result is true.
 */
data class CaptureDrainState(
    val sessionId: String,
    val mode: CaptureMode,
    val registeredAtMillis: Long,
    val lastUpdateMillis: Long,
    val stopRequested: Boolean = false,
    val dataPlaneThreadStopped: Boolean = false,
    val forwardersStopped: Boolean = false,
    val vpnFdClosed: Boolean = false,
    val sinkDrained: Boolean = false,
    val sinkWriterJoined: Boolean = false,
    val vpnServiceStopped: Boolean = false,
    val rootStartJobJoined: Boolean = false,
    val rootProcessExited: Boolean = false,
    val rootFileOwnerClosed: Boolean = false,
    val rootDrainProven: Boolean = false,
    val lastFailure: String? = null,
    /**
     * Set by the App-owned finalizer after the original staging artifact was
     * finalized. Diagnostic only: resource settling never waits for analysis.
     */
    val finalizedAtMillis: Long? = null,
) {
    init {
        require(runCatching { java.util.UUID.fromString(sessionId) }.isSuccess) {
            "sessionId must be a UUID"
        }
    }

    /** True only when every real resource owner has reported its actual close. */
    val resourcesSettled: Boolean
        get() = when (mode) {
            CaptureMode.VPN -> stopRequested && dataPlaneThreadStopped &&
                forwardersStopped && vpnFdClosed && sinkDrained &&
                sinkWriterJoined && vpnServiceStopped
            CaptureMode.ROOT -> stopRequested && rootStartJobJoined &&
                rootProcessExited && rootFileOwnerClosed && rootDrainProven
        }

    fun outstanding(): List<String> = buildList {
        if (!stopRequested) add("stopRequested")
        when (mode) {
            CaptureMode.VPN -> {
                if (!dataPlaneThreadStopped) add("dataPlaneThreadStopped")
                if (!forwardersStopped) add("forwardersStopped")
                if (!vpnFdClosed) add("vpnFdClosed")
                if (!sinkDrained) add("sinkDrained")
                if (!sinkWriterJoined) add("sinkWriterJoined")
                if (!vpnServiceStopped) add("vpnServiceStopped")
            }
            CaptureMode.ROOT -> {
                if (!rootStartJobJoined) add("rootStartJobJoined")
                if (!rootProcessExited) add("rootProcessExited")
                if (!rootFileOwnerClosed) add("rootFileOwnerClosed")
                if (!rootDrainProven) add("rootDrainProven")
            }
        }
    }
}

class CaptureDrainRegistry(
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val lock = Any()
    private val states = LinkedHashMap<String, CaptureDrainState>()

    fun register(sessionId: String, mode: CaptureMode): CaptureDrainState = synchronized(lock) {
        val timestamp = now()
        val value = CaptureDrainState(
            sessionId = sessionId,
            mode = mode,
            registeredAtMillis = timestamp,
            lastUpdateMillis = timestamp,
        )
        states[sessionId] = value
        value
    }

    fun update(
        sessionId: String,
        transform: (CaptureDrainState) -> CaptureDrainState,
    ): CaptureDrainState? = synchronized(lock) {
        val current = states[sessionId] ?: return null
        val next = transform(current).copy(lastUpdateMillis = now())
        require(next.sessionId == current.sessionId && next.mode == current.mode) {
            "drain identity is immutable"
        }
        states[sessionId] = next
        next
    }

    fun snapshot(sessionId: String): CaptureDrainState? = synchronized(lock) {
        states[sessionId]
    }

    /** A session with no ledger entry never acquired an owned resource. */
    fun isSettled(sessionId: String): Boolean = synchronized(lock) {
        states[sessionId]?.resourcesSettled ?: true
    }

    fun outstanding(): List<CaptureDrainState> = synchronized(lock) {
        states.values.filter { !it.resourcesSettled }
    }

    fun hasOutstanding(): Boolean = synchronized(lock) {
        states.values.any { !it.resourcesSettled }
    }

    /**
     * Remove a settled entry. This fails closed: an unproven entry stays and
     * keeps RootStop blocked rather than disappearing from the ledger.
     */
    fun complete(sessionId: String) {
        synchronized(lock) {
            val current = states[sessionId] ?: return
            check(current.resourcesSettled) {
                "capture drain still owns ${current.outstanding()}"
            }
            states.remove(sessionId)
        }
    }

    /**
     * Mark the one finalize pass and remove the entry only when every real
     * resource owner already reported its close. This is the normal completion
     * path after the staging artifact was finalized; a still-live writer or
     * helper keeps the entry (and RootStop) blocked.
     */
    fun completeAfterFinalize(sessionId: String, atMillis: Long = now()): Boolean =
        synchronized(lock) {
            val current = states[sessionId] ?: return true
            val finalized = current.copy(finalizedAtMillis = atMillis)
            states[sessionId] = finalized
            if (!finalized.resourcesSettled) return false
            states.remove(sessionId)
            true
        }

    /** Test/diagnostic only; production paths never erase an unproven owner. */
    internal fun clearForTest(sessionId: String) {
        synchronized(lock) { states.remove(sessionId) }
    }

    companion object {
        /** App-process authority shared by the controller and both services. */
        val shared = CaptureDrainRegistry()
    }
}
