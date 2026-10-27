// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.os.IBinder
import com.floe.android.core.officeengine.OfficeEngineCommands
import com.floe.android.core.officeengine.OfficeEngineCommandsPolicy
import com.floe.android.core.officeengine.precision.OfficePrecisionAction
import com.floe.android.core.officeengine.precision.OfficePrecisionContentKind
import com.floe.android.core.officeengine.precision.OfficePrecisionFailure
import com.floe.android.core.officeengine.precision.OfficePrecisionRequest
import com.floe.android.core.officeengine.precision.OfficePrecisionResult
import com.floe.android.core.officeengine.precision.OfficePrecisionState
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicLong

/**
 * Thin App-process client for the engine's fenced typed precision surface
 * (G05-R2 P-A). It rides the EXISTING engine command binding pattern
 * ([OfficeEngineCommands.bindIntent] + same-UID explicit non-exported
 * Service, exact sessionToken + mount-generation fences, generation read
 * through the existing readGeneration seam) and adds no new authority:
 * every operation is a structured allowlisted action translated to pinned
 * producer wire commands INSIDE the engine.
 *
 * Ownership rules (Main contract):
 *  - The App/runtime mints the operation identity ([newOpId]) from its OWN
 *    owned context (task/workspace identity it already holds). Document or
 *    tool output can never mint identity: the engine re-checks every fence
 *    against its own mount record and refuses disagreeing owner echoes.
 *  - This client NEVER registers a host save-channel (transaction 28
 *    registration ownership stays with the save-copy host); [hostChannel]
 *    is only the optional bind extra and SHOULD be the same channel binder
 *    the App already uses, or null.
 *  - Completion honesty: [execute] delivers ADMITTED only as a synchronous
 *    acknowledgement; the terminal callback result is the engine's typed
 *    QUERY_OBSERVED / NATIVE_COMPLETED / MUTATION_VERIFIED / REJECTED /
 *    FAILED / UNKNOWN. NATIVE_COMPLETED is NOT tool success — content
 *    verification completes through the owned flush/export receipts. A
 *    client-side deadline produces an honest UNKNOWN-shaped result while
 *    the engine may still settle the op; [readAnswer] re-reads it later.
 *  - Content discipline: typed answer content is delivered ONLY to the
 *    caller's callback; nothing is logged here (no text, no formulas, no
 *    tokens, no paths).
 *
 * Threading: binder transactions and the bounded answer poll run on the
 * caller-supplied [executor]; callbacks are invoked on that same executor.
 */
class OfficePrecisionClient(
    private val appContext: Context,
    private val executor: Executor,
    private val hostChannel: IBinder? = null,
) {

    private val bindLock = Any()

    @Volatile
    private var commands: OfficeEngineCommands? = null
    private var bound = false

    /** RAM-only transport diagnostic (identity-safe; never content). */
    @Volatile
    var transportDiagnostic: String? = null
        private set

    private val opCounter = AtomicLong(0)

    private val connection: ServiceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            synchronized(bindLock) { commands = OfficeEngineCommands(binder) }
        }

        override fun onServiceDisconnected(name: ComponentName) {
            synchronized(bindLock) { commands = null }
        }

        override fun onBindingDied(name: ComponentName) {
            synchronized(bindLock) {
                commands = null
                if (bound) {
                    runCatching { appContext.unbindService(connection) }
                    bound = false
                }
            }
            transportDiagnostic = "precision engine binding died"
        }

        override fun onNullBinding(name: ComponentName) {
            synchronized(bindLock) { commands = null }
            transportDiagnostic = "precision engine returned a null binding"
        }
    }

    /** Caller-owned operation identity (matches the engine's opId grammar). */
    fun newOpId(prefix: String): String {
        val safePrefix = prefix.filter { it.isLetterOrDigit() || it == '-' || it == '_' }
            .take(16)
            .ifEmpty { "op" }
        val seq = opCounter.incrementAndGet()
        val unique = UUID.randomUUID().toString().replace("-", "").take(24)
        return "$safePrefix-$seq-$unique".take(64)
    }

    /**
     * Native mount generation for the exact session token (0 when no live
     * mount) — the existing deterministic acquisition seam. Fence every
     * precision request with this value.
     */
    fun readGeneration(sessionToken: String): Long {
        val client = connectedOrNull() ?: return 0L
        return client.readGeneration(sessionToken)
    }

    /**
     * Runs one typed precision operation to its terminal engine result.
     *
     * @param timeoutMs bounded wait for the TERMINAL result (the engine has
     *   its own per-step bounded windows; this deadline only stops the
     *   client poll — an honest client-side UNKNOWN is delivered and the
     *   engine's real terminal stays re-readable via [readAnswer]).
     */
    fun execute(
        request: OfficePrecisionRequest,
        timeoutMs: Long = DEFAULT_TIMEOUT_MS,
        callback: (OfficePrecisionResult) -> Unit,
    ) {
        executor.execute {
            val client = connectedOrNull()
            if (client == null) {
                callback(
                    localRefusal(
                        request,
                        OfficePrecisionFailure.TRANSPORT,
                        "engine-command-binding-unavailable",
                    ),
                )
                return@execute
            }
            val admission = runCatching { client.postPrecisionCommand(request) }.getOrNull()
            if (admission == null) {
                callback(localRefusal(request, OfficePrecisionFailure.TRANSPORT, "binder-transport-failed"))
                return@execute
            }
            if (admission != OfficeEngineCommandsPolicy.PRECISION_ACCEPTED) {
                // The engine stored the exact typed refusal; prefer it over
                // the coarse code (fall back to the code when unreadable).
                val typed = runCatching {
                    client.readPrecisionAnswer(request.opId, request.sessionToken, request.generation)
                }.getOrNull()
                callback(
                    typed ?: localRefusal(
                        request,
                        failureForAdmissionCode(admission),
                        "admission-code=$admission",
                    ),
                )
                return@execute
            }
            callback(pollUntilTerminal(client, request, timeoutMs))
        }
    }

    /**
     * Re-reads a terminal result the engine may have settled after a
     * client-side deadline (consumes it). Null while pending/unknown.
     */
    fun readAnswer(opId: String, sessionToken: String, generation: Long): OfficePrecisionResult? {
        val client = connectedOrNull() ?: return null
        return runCatching { client.readPrecisionAnswer(opId, sessionToken, generation) }.getOrNull()
    }

    private fun pollUntilTerminal(
        client: OfficeEngineCommands,
        request: OfficePrecisionRequest,
        timeoutMs: Long,
    ): OfficePrecisionResult {
        val deadline = System.currentTimeMillis() + timeoutMs
        var intervalMs = FIRST_POLL_INTERVAL_MS
        while (true) {
            val result = runCatching {
                client.readPrecisionAnswer(request.opId, request.sessionToken, request.generation)
            }.getOrNull()
            if (result != null) return result
            val remaining = deadline - System.currentTimeMillis()
            if (remaining <= 0L) {
                // Honest client-side unknown: the engine keeps its own
                // bounded windows and may still settle this op; the result
                // stays re-readable via readAnswer for the mount's life.
                return OfficePrecisionResult(
                    opId = request.opId,
                    sessionToken = request.sessionToken,
                    generation = request.generation,
                    action = request.action,
                    state = OfficePrecisionState.UNKNOWN,
                    failure = OfficePrecisionFailure.TIMEOUT,
                    detail = "client-deadline-exceeded-engine-may-still-settle",
                    answer = null,
                    attestation = "client-poll-deadline",
                    submittedAtElapsedMs = android.os.SystemClock.elapsedRealtime(),
                    completedAtElapsedMs = android.os.SystemClock.elapsedRealtime(),
                )
            }
            try {
                Thread.sleep(minOf(intervalMs, remaining))
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                return localRefusal(request, OfficePrecisionFailure.TRANSPORT, "poll-interrupted")
            }
            intervalMs = (intervalMs * 3 / 2).coerceAtMost(MAX_POLL_INTERVAL_MS)
        }
    }

    private fun connectedOrNull(): OfficeEngineCommands? {
        synchronized(bindLock) {
            commands?.let { return it }
            if (!bound) {
                val intent = OfficeEngineCommands.bindIntent(appContext, hostChannel)
                bound = runCatching {
                    appContext.bindService(intent, connection, Context.BIND_AUTO_CREATE)
                }.getOrDefault(false)
                if (!bound) transportDiagnostic = "precision engine bind refused"
            }
            return commands
        }
    }

    /**
     * Releases the client's own service connection. Bind/unbind are paired
     * per ServiceConnection, so this never disturbs the save-copy host's
     * independent connection to the same engine binding.
     */
    fun release() {
        synchronized(bindLock) {
            commands = null
            if (bound) {
                runCatching { appContext.unbindService(connection) }
                bound = false
            }
        }
    }

    private fun localRefusal(
        request: OfficePrecisionRequest,
        failure: OfficePrecisionFailure,
        detail: String,
    ): OfficePrecisionResult {
        val now = android.os.SystemClock.elapsedRealtime()
        return OfficePrecisionResult(
            opId = request.opId,
            sessionToken = request.sessionToken,
            generation = request.generation,
            action = request.action,
            state = OfficePrecisionState.REJECTED,
            failure = failure,
            detail = detail,
            answer = null,
            attestation = "client-local-refusal",
            submittedAtElapsedMs = now,
            completedAtElapsedMs = now,
        )
    }

    private fun failureForAdmissionCode(code: Int): OfficePrecisionFailure = when (code) {
        OfficeEngineCommandsPolicy.PRECISION_REJECTED_SHAPE -> OfficePrecisionFailure.INVALID_REQUEST
        OfficeEngineCommandsPolicy.PRECISION_REJECTED_SESSION -> OfficePrecisionFailure.SESSION_MISMATCH
        OfficeEngineCommandsPolicy.PRECISION_REJECTED_BUSY -> OfficePrecisionFailure.MUTATION_IN_FLIGHT
        OfficeEngineCommandsPolicy.PRECISION_REJECTED_SIZE -> OfficePrecisionFailure.REQUEST_TOO_LARGE
        else -> OfficePrecisionFailure.INTERNAL
    }

    companion object {
        const val DEFAULT_TIMEOUT_MS = 90_000L
        private const val FIRST_POLL_INTERVAL_MS = 20L
        private const val MAX_POLL_INTERVAL_MS = 250L

        // ---- stable request builders (concrete consumer API) -------------

        /** CAPTURE_TARGET: mints the engine-held dual-revision target handle. */
        fun captureTargetRequest(
            opId: String,
            sessionToken: String,
            generation: Long,
            ownerTaskId: String? = null,
            workspaceId: String? = null,
        ): OfficePrecisionRequest = OfficePrecisionRequest(
            opId = opId,
            sessionToken = sessionToken,
            generation = generation,
            action = OfficePrecisionAction.CAPTURE_TARGET,
            ownerTaskId = ownerTaskId,
            workspaceId = workspaceId,
        )

        /** QUERY_DOCUMENT_CONTEXT: real producer `status:` facts. */
        fun documentContextRequest(
            opId: String,
            sessionToken: String,
            generation: Long,
        ): OfficePrecisionRequest = OfficePrecisionRequest(
            opId = opId,
            sessionToken = sessionToken,
            generation = generation,
            action = OfficePrecisionAction.QUERY_DOCUMENT_CONTEXT,
        )

        /** QUERY_TEXT_SELECTION: typed selection content read. */
        fun textSelectionRequest(
            opId: String,
            sessionToken: String,
            generation: Long,
        ): OfficePrecisionRequest = OfficePrecisionRequest(
            opId = opId,
            sessionToken = sessionToken,
            generation = generation,
            action = OfficePrecisionAction.QUERY_TEXT_SELECTION,
        )

        /** QUERY_CELL_CURSOR: Calc cursor/range POSITION readback. */
        fun cellCursorRequest(
            opId: String,
            sessionToken: String,
            generation: Long,
        ): OfficePrecisionRequest = OfficePrecisionRequest(
            opId = opId,
            sessionToken = sessionToken,
            generation = generation,
            action = OfficePrecisionAction.QUERY_CELL_CURSOR,
        )

        /** QUERY_PRESENTATION_INFO: Impress slide-inventory readback. */
        fun presentationInfoRequest(
            opId: String,
            sessionToken: String,
            generation: Long,
        ): OfficePrecisionRequest = OfficePrecisionRequest(
            opId = opId,
            sessionToken = sessionToken,
            generation = generation,
            action = OfficePrecisionAction.QUERY_PRESENTATION_INFO,
        )

        /** SELECT_SLIDE: slide/sheet navigation with producer echo proof. */
        fun selectSlideRequest(
            opId: String,
            sessionToken: String,
            generation: Long,
            partId: String,
        ): OfficePrecisionRequest = OfficePrecisionRequest(
            opId = opId,
            sessionToken = sessionToken,
            generation = generation,
            action = OfficePrecisionAction.SELECT_SLIDE,
            partId = partId,
        )

        /** SELECT_ALL_TEXT: select-all with real effect-frame proof. */
        fun selectAllTextRequest(
            opId: String,
            sessionToken: String,
            generation: Long,
        ): OfficePrecisionRequest = OfficePrecisionRequest(
            opId = opId,
            sessionToken = sessionToken,
            generation = generation,
            action = OfficePrecisionAction.SELECT_ALL_TEXT,
        )

        /** APPLY_TEXT: paste-protocol text apply against a captured target. */
        fun applyTextRequest(
            opId: String,
            sessionToken: String,
            generation: Long,
            text: String,
            targetHandle: String,
        ): OfficePrecisionRequest = OfficePrecisionRequest(
            opId = opId,
            sessionToken = sessionToken,
            generation = generation,
            action = OfficePrecisionAction.APPLY_TEXT,
            text = text,
            targetHandle = targetHandle,
        )

        /**
         * SET_CELL_CONTENT: single-cell literal/formula set against a
         * captured target (single-cell-safe content only — tab/CR/LF is
         * refused by the engine, never spread across cells).
         */
        fun setCellContentRequest(
            opId: String,
            sessionToken: String,
            generation: Long,
            cellAddress: String,
            text: String,
            contentKind: OfficePrecisionContentKind,
            targetHandle: String,
        ): OfficePrecisionRequest = OfficePrecisionRequest(
            opId = opId,
            sessionToken = sessionToken,
            generation = generation,
            action = OfficePrecisionAction.SET_CELL_CONTENT,
            text = text,
            contentKind = contentKind,
            cellAddress = cellAddress,
            targetHandle = targetHandle,
        )
    }
}
