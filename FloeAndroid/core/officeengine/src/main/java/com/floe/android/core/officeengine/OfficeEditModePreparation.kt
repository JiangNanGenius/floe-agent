// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

/** Failure of the bounded, operation-owned page edit-mode preparation. */
internal enum class OfficeEditModePreparationFailure {
    NOT_EDITABLE,
    TIMEOUT,
    SESSION_ENDING,
    BUSY,
    TRANSPORT,
}

/** One honest edit-preparation result; readiness is never inferred from a send. */
internal data class OfficeEditModePreparationResult(
    val failure: OfficeEditModePreparationFailure?,
    val detail: String,
) {
    val isReady: Boolean get() = failure == null

    companion object {
        fun ready() = OfficeEditModePreparationResult(null, "page-edit-mode-observed")
    }
}

/** Exact operation/preparation incarnation used at real native/JS execution points. */
internal data class OfficeEditModePreparationToken(
    val opId: String,
    val serial: Long,
)

/**
 * The single ordered dispatch rule shared by precision mutations and flush.
 * The caller MUST hold the session's nativeIngressLock. A current page
 * EDITMODE-on fact is required immediately before the already-authorized
 * native per-view command and the actual operation are sent consecutively on
 * the existing serial wire. Viewing state sends nothing. The native command
 * is ordering, not a success claim; content/save proof remains independent.
 */
internal object OfficeOwnedEditDispatch {
    fun run(
        isPageEditMode: () -> Boolean,
        sendNativeEditable: () -> Unit,
        sendOperation: () -> Unit,
    ): Boolean {
        if (!isPageEditMode()) return false
        sendNativeEditable()
        // A native send can synchronously re-enter host callbacks. Re-check
        // the real page fact before the effect/save command may follow.
        if (!isPageEditMode()) return false
        sendOperation()
        return true
    }
}

/**
 * Bounded operation-owned entry into the pinned page's real edit mode.
 *
 * A load-permission barrier and READY_EDITABLE only make an EDIT mount
 * eligible; they do not prove that its page is editing. When the latest real
 * EDITMODE observation is off, this coordinator drives the existing guarded
 * page hook and waits for the page's own EDITMODE-on observation. There is no
 * sleep or sent-flag success path. Every callback is fenced by the Active
 * instance, so cancellation, timeout, mount close and stale JS callbacks can
 * never complete a later operation.
 *
 * Calls normally arrive on the Session control lane. Host timeout/JS hooks
 * are marshalled back to that lane; small state transitions are synchronized
 * so cancel/close remain safe from binder/teardown threads.
 */
internal class OfficeEditModePreparation(
    private val host: Host,
    private val timeoutMs: Long = DEFAULT_TIMEOUT_MS,
) {
    interface Host {
        fun isMountLive(): Boolean
        fun isEditableReady(): Boolean
        fun isPageEditMode(): Boolean

        /**
         * Sends only while this exact token is active at the REAL native
         * dispatch point. False means cancel/close already fenced the send.
         */
        fun sendNativeEditable(token: OfficeEditModePreparationToken): Boolean

        /** Queues the existing guarded page hook; its runnable re-checks token. */
        fun enterPageEditMode(
            token: OfficeEditModePreparationToken,
            onHookResult: (Boolean) -> Unit,
        )

        fun runOnControlLane(task: Runnable): Boolean
        fun scheduleTimeout(delayMs: Long, task: Runnable): Any?
        fun cancelTimeout(handle: Any)
        fun recordDiagnostic(detail: String)
    }

    private data class Active(
        val token: OfficeEditModePreparationToken,
        val callback: (OfficeEditModePreparationResult) -> Unit,
        var timeoutHandle: Any? = null,
    ) {
        val opId: String get() = token.opId
    }

    private val lock = Any()
    private var active: Active? = null
    private var nextSerial = 0L
    private var closed = false

    fun prepare(
        opId: String,
        callback: (OfficeEditModePreparationResult) -> Unit,
    ) {
        var started: Active? = null
        val immediate = synchronized(lock) {
            when {
                closed -> OfficeEditModePreparationResult(
                    OfficeEditModePreparationFailure.SESSION_ENDING,
                    "edit-preparation-closed",
                )
                active != null -> OfficeEditModePreparationResult(
                    OfficeEditModePreparationFailure.BUSY,
                    "edit-preparation-already-active",
                )
                !host.isMountLive() -> OfficeEditModePreparationResult(
                    OfficeEditModePreparationFailure.SESSION_ENDING,
                    "mount-not-live",
                )
                !host.isEditableReady() -> OfficeEditModePreparationResult(
                    OfficeEditModePreparationFailure.NOT_EDITABLE,
                    "mount-not-editable-ready",
                )
                host.isPageEditMode() -> OfficeEditModePreparationResult.ready()
                else -> {
                    val pending = Active(
                        OfficeEditModePreparationToken(opId, ++nextSerial),
                        callback,
                    )
                    active = pending
                    started = pending
                    null
                }
            }
        }
        if (immediate != null) {
            callback(immediate)
            return
        }
        val pending = started ?: return
        host.recordDiagnostic("edit preparation start op=$opId pageEditMode=false")

        try {
            // The page's own edit hook may emit a duplicate setviewreadonly;
            // the precision lease intentionally fences that page duplicate.
            // This service-owned send is the authorized native counterpart.
            if (!host.sendNativeEditable(pending.token)) {
                finish(
                    pending,
                    OfficeEditModePreparationResult(
                        OfficeEditModePreparationFailure.SESSION_ENDING,
                        "native-edit-dispatch-fenced",
                    ),
                )
                return
            }
        } catch (t: Throwable) {
            finish(
                pending,
                OfficeEditModePreparationResult(
                    OfficeEditModePreparationFailure.TRANSPORT,
                    "native-edit-send-${t.javaClass.simpleName}",
                ),
            )
            return
        }

        val timeoutTask = Runnable {
            dispatchToControlLane(
                Runnable {
                    finish(
                        pending,
                        OfficeEditModePreparationResult(
                            OfficeEditModePreparationFailure.TIMEOUT,
                            "page-edit-mode-timeout",
                        ),
                    )
                },
            )
        }
        val handle = try {
            host.scheduleTimeout(timeoutMs, timeoutTask)
        } catch (t: Throwable) {
            finish(
                pending,
                OfficeEditModePreparationResult(
                    OfficeEditModePreparationFailure.TRANSPORT,
                    "edit-timeout-schedule-${t.javaClass.simpleName}",
                ),
            )
            return
        }
        val stale = synchronized(lock) {
            if (active !== pending) {
                true
            } else {
                pending.timeoutHandle = handle
                false
            }
        }
        if (stale) {
            if (handle != null) host.cancelTimeout(handle)
            return
        }
        if (handle == null) {
            finish(
                pending,
                OfficeEditModePreparationResult(
                    OfficeEditModePreparationFailure.TIMEOUT,
                    "page-edit-mode-no-scheduler",
                ),
            )
            return
        }

        try {
            host.enterPageEditMode(pending.token) { hookRan ->
                dispatchToControlLane(
                    Runnable {
                        if (!hookRan) {
                            finish(
                                pending,
                                OfficeEditModePreparationResult(
                                    OfficeEditModePreparationFailure.TRANSPORT,
                                    "page-edit-hook-unavailable",
                                ),
                            )
                        }
                        // hookRan=true only proves the JS hook was invoked.
                        // Readiness still requires onPageEditMode(true).
                    }
                )
            }
        } catch (t: Throwable) {
            finish(
                pending,
                OfficeEditModePreparationResult(
                    OfficeEditModePreparationFailure.TRANSPORT,
                    "page-edit-hook-${t.javaClass.simpleName}",
                ),
            )
        }
    }

    /**
     * Executes a real native/JS side effect only if this exact preparation
     * incarnation is still active. Session calls this while holding
     * nativeIngressLock and uses the SAME lock around cancel/close, so once
     * cancellation returns no late native send or WebView hook can start.
     * No operation callback is invoked under this monitor.
     */
    fun runIfActive(
        token: OfficeEditModePreparationToken,
        action: () -> Unit,
    ): Boolean = synchronized(lock) {
        if (active?.token != token) return@synchronized false
        action()
        true
    }

    /** Consumes the real page EDITMODE observation forwarded by Session. */
    fun onPageEditMode(enabled: Boolean) {
        val pending = synchronized(lock) { active } ?: return
        if (!enabled) {
            finish(
                pending,
                OfficeEditModePreparationResult(
                    OfficeEditModePreparationFailure.NOT_EDITABLE,
                    "page-viewing-during-edit-preparation",
                ),
            )
            return
        }
        val result = when {
            !host.isMountLive() -> OfficeEditModePreparationResult(
                OfficeEditModePreparationFailure.SESSION_ENDING,
                "mount-ended-during-edit-preparation",
            )
            !host.isEditableReady() -> OfficeEditModePreparationResult(
                OfficeEditModePreparationFailure.NOT_EDITABLE,
                "edit-permission-lost-during-preparation",
            )
            !host.isPageEditMode() -> OfficeEditModePreparationResult(
                OfficeEditModePreparationFailure.NOT_EDITABLE,
                "page-edit-ack-without-current-state",
            )
            else -> OfficeEditModePreparationResult.ready()
        }
        finish(pending, result)
    }

    /** Cancels only this exact preparation; its late callbacks become no-ops. */
    fun cancel(opId: String) {
        val cancelled = synchronized(lock) {
            val pending = active?.takeIf { it.opId == opId }
            if (pending != null) active = null
            pending
        } ?: return
        cancelled.timeoutHandle?.let(host::cancelTimeout)
        host.recordDiagnostic("edit preparation cancelled op=$opId")
    }

    /** Mount terminal: clear without invoking an operation callback. */
    fun close() {
        val cancelled = synchronized(lock) {
            closed = true
            val pending = active
            active = null
            pending
        } ?: return
        cancelled.timeoutHandle?.let(host::cancelTimeout)
    }

    private fun finish(
        pending: Active,
        result: OfficeEditModePreparationResult,
    ) {
        val callback = synchronized(lock) {
            if (active !== pending) return
            active = null
            pending.timeoutHandle?.let(host::cancelTimeout)
            pending.callback
        }
        host.recordDiagnostic(
            "edit preparation finish op=${pending.opId} ready=${result.isReady} detail=${result.detail}",
        )
        callback(result)
    }

    private fun dispatchToControlLane(task: Runnable) {
        // During teardown the lane may already be gone. The synchronized
        // Active fence still prevents a stale completion; mount close owns
        // the final UNKNOWN settlement in that case.
        if (!host.runOnControlLane(task)) task.run()
    }

    companion object {
        const val DEFAULT_TIMEOUT_MS = 10_000L
    }
}
