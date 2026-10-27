// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.precision

import com.floe.android.core.officeengine.CoolMessageTriage
import com.floe.android.core.officeengine.OfficeDocumentFormat
import com.floe.android.core.officeengine.OfficeOwnedEditDispatch

/**
 * Session-scoped orchestrator for the fenced Office precision surface.
 * One instance lives exactly as long as one native mount (Session) and owns
 * that mount's [OfficePrecisionLedger] — a new native incarnation therefore
 * starts with a clean correlation/quarantine/handle state, which is the ONLY
 * reconciliation for a poisoned barrier or a quarantined callback-answer
 * kind (Main early review 2026-10-27).
 *
 * Authority model:
 *  - The App/runtime mints the operation identity (opId, owner context) and
 *    acquires the mount generation through the EXISTING readGeneration seam;
 *    the engine re-checks every fence against its OWN mount record and
 *    never trusts document/tool output. Owner echoes that disagree with the
 *    mount's own ownerTaskId/workspaceId are refused (OWNER_MISMATCH).
 *  - Wire commands are built ONLY here/[OfficePrecisionProtocol] from
 *    validated typed parameters (postMobileMessageNative — the already
 *    device-proven wire path; the declared-but-unproven postUnoCommand JNI
 *    entry is deliberately NOT used).
 *  - The native operation lease is held ONLY while an operation is actually
 *    executing (claim → terminal), never while a model thinks between ops.
 *    While held it fences competing page retarget/write traffic (mouse/key/
 *    selecttext/setpart/uno/save/setviewreadonly/dialog/window events …)
 *    AND binder-side undo/redo, edit-toggle and save submissions — the
 *    working-copy hash alone cannot detect selection/part retargeting, so
 *    the lease is the real in-flight fence. Render/tile/zoom/visibility/
 *    keepalive traffic always flows (allowed lifecycle/render keepalives).
 *  - Diagnostics record operation/type/state/byte-count/hash summaries
 *    only — never selected text, formulas, tokens, nonces or paths. Typed
 *    content is returned exclusively through the fenced result read to the
 *    authorized same-UID owner.
 */
class OfficePrecisionEngine(private val host: OfficePrecisionHost) {

    /**
     * The mount-side capabilities this engine needs. Implemented by the
     * engine Service session; kept as an interface so the orchestration is
     * JVM-testable with a fake host.
     */
    interface OfficePrecisionHost {
        fun sessionToken(): String
        fun generation(): Long
        fun documentFormat(): OfficeDocumentFormat

        /** Mount reached a real READY state (READY_READ_ONLY / READY_EDITABLE). */
        fun isReadyState(): Boolean

        /** READY_EDITABLE AND the full native edit-permission witness set. */
        fun isEditableReady(): Boolean

        /** Mount still live for commands (not retired/superseded/closing, still current). */
        fun isMountLive(): Boolean

        /** A save flush awaits its ack or an export holds the control lane. */
        fun saveBusy(): Boolean

        /** Real re-read digest of the mutable working copy (null when absent). */
        fun workingCopyDigest(): Pair<String, Long>?

        /** Mount-owned identity facts (engine side of the owner fence). */
        fun ownerTaskId(): String?
        fun workspaceId(): String?
        fun sourceId(): String?
        fun sourceRevision(): String?
        fun sourceLogicalPath(): String?

        /** Last observed `.uno:ModifiedStatus` (corroboration only). */
        fun documentModified(): Boolean?

        /** Latest REAL page EDITMODE fact, independent of load permission or command intent. */
        fun isPageEditMode(): Boolean

        /**
         * Drives the existing bounded page edit-mode handshake for this owned
         * non-query operation. Ready is reported only after a real EDITMODE-on
         * observation (or when that observed state is already present).
         */
        fun prepareEditableView(
            opId: String,
            callback: (OfficePrecisionFailure?, String) -> Unit,
        )

        /** Fences a pending page-hook/timeout callback for this exact op. */
        fun cancelEditableViewPreparation(opId: String)

        /**
         * Sends the EDIT mount's own setviewreadonly=false immediately before
         * the first operation wire, inside the SAME nativeIngressLock section.
         * This is ordered native dispatch, not a local editability witness.
         */
        fun sendOwnedNativeEditable()

        /** Posts one wire message to the kit; throws on transport failure. */
        fun sendWire(message: String)

        /** Serializes with opens/flush/export/BYE (single control thread). */
        fun runOnControlLane(task: Runnable): Boolean

        /** Bounded watchdog scheduling (main handler semantics). */
        fun scheduleTimeout(delayMs: Long, task: Runnable): Any?
        fun cancelTimeout(handle: Any)

        /**
         * The SESSION-Wide native ingress monitor (LOActivity's
         * `nativeIngressLock`): the same instance whose synchronized block
         * makes one admitted page send atomic (gate check → real JNI send →
         * forwarded callback). Precision lease activation, admission re-checks,
         * target validation and the actual wire dispatch run under THIS
         * monitor — never an independent lock and never a bare boolean
         * pre-check (Main ingress integration 2026-10-26). The monitor is
         * held only across synchronous sections, NEVER across async waits
         * for native replies. Lock order: ingress → engineLock → ledger.
         */
        fun nativeIngressLock(): Any

        /** Identity-safe diagnostic line (bounded history). */
        fun recordDiagnostic(detail: String)

        fun elapsedMs(): Long
    }

    val ledger = OfficePrecisionLedger(clock = { host.elapsedMs() })

    private val engineLock = Any()

    @Volatile
    private var currentRun: OfficePrecisionLedger.OpRun? = null
    private var pumping = false
    private var timeoutHandle: Any? = null
    private var leaseNoticeReportedForOp: String? = null

    /**
     * True while an operation is executing (claimed → terminal). This is the
     * native operation lease: short, bounded by the step timeouts, and never
     * held while a model thinks between operations.
     */
    fun leaseActive(): Boolean = synchronized(engineLock) { currentRun != null }

    // ------------------------------------------------------------------
    // Page-input fencing + epochs (called from Session.onMessageFromJs)
    // ------------------------------------------------------------------

    /**
     * True when the given page command head must be REFUSED right now
     * because a precision operation holds the native lease. Fail-closed
     * allowlist: only pure render/tile/zoom/visibility/keepalive traffic
     * keeps flowing; every retarget/write/query-reply-collision class is
     * fenced (selection/part/window retargeting included — the working-copy
     * hash cannot see it, so the lease must).
     */
    fun blocksPageCommand(commandHead: String): Boolean {
        if (!leaseActive()) return false
        return commandHead !in LEASE_KEEPALIVE_COMMANDS
    }

    /** One bounded user-visible notice per operation (no spam). */
    fun claimLeaseNoticeOnce(opId: String?): Boolean {
        synchronized(engineLock) {
            if (opId == null || leaseNoticeReportedForOp == opId) return false
            leaseNoticeReportedForOp = opId
            return true
        }
    }

    /**
     * Classifies one FORWARDED page command for target/epoch bookkeeping:
     * retarget/write class advances the manual-input epoch (invalidating
     * captured targets even when ModifiedStatus merely stays true);
     * reply-collision query class arms the preventive barrier; anything
     * else (render/keepalive) is inert. Unknown forwarded commands are
     * treated as retarget class (fail-closed).
     */
    fun noteForwardedPageCommand(commandHead: String) {
        when {
            commandHead in LEASE_KEEPALIVE_COMMANDS -> Unit
            commandHead in PAGE_QUERY_REPLY_CLASS -> ledger.notePageQueryForwarded()
            else -> ledger.notePageInput()
        }
    }

    /**
     * True when a competing native ingress (save flush message, edit-mode
     * toggle, undo/redo) may ACTUALLY dispatch right now. Callers holding
     * the session ingress monitor re-check this immediately before their
     * real postMobileMessageNative — a pre-check outside the monitor is a
     * TOCTOU (Main ingress integration 2026-10-26).
     */
    fun canDispatchCompetingNative(): Boolean = !leaseActive()

    /**
     * Session observed a REAL page EDITMODE-off event on the control lane.
     * A non-query run never rides through that drift: before any effect it is
     * refused; after an effect-bearing wire it is UNKNOWN (never replayed).
     * Read-only queries do not own or require page edit mode.
     */
    fun onPageViewingObserved() {
        val run = synchronized(engineLock) { currentRun } ?: return
        if (run.request.action.effect == OfficePrecisionEffect.QUERY) return
        ledger.onPageViewing(run.request.opId)?.let { finishRun(it) }
    }

    // ------------------------------------------------------------------
    // Submission (binder thread)
    // ------------------------------------------------------------------

    /**
     * Fenced admission of one typed request. Returns the synchronous
     * ADMITTED acknowledgement or the exact typed REJECTED result (also
     * stored for readAnswer). NEVER a completion claim.
     */
    fun submit(request: OfficePrecisionRequest): OfficePrecisionResult {
        val now = host.elapsedMs()
        val rejection = admissionRejection(request)
        if (rejection != null) {
            val result = rejectedResult(request, rejection.first, rejection.second, now)
            ledger.recordRejection(result)
            host.recordDiagnostic(result.descriptorLine())
            return result
        }
        when (val outcome = ledger.submit(request)) {
            is OfficePrecisionLedger.SubmitOutcome.Rejected -> {
                val result = rejectedResult(request, outcome.failure, outcome.detail, now)
                ledger.recordRejection(result)
                host.recordDiagnostic(result.descriptorLine())
                return result
            }
            is OfficePrecisionLedger.SubmitOutcome.Accepted -> Unit
        }
        val admitted = OfficePrecisionResult(
            opId = request.opId,
            sessionToken = request.sessionToken,
            generation = request.generation,
            action = request.action,
            state = OfficePrecisionState.ADMITTED,
            failure = null,
            detail = null,
            answer = null,
            attestation = "accepted-for-processing",
            submittedAtElapsedMs = now,
            completedAtElapsedMs = now,
        )
        host.recordDiagnostic(
            "precision submit op=${request.opId} action=${request.action.name} " +
                "queue=${ledger.pendingCount()}",
        )
        pumpAsync()
        return admitted
    }

    private fun admissionRejection(
        request: OfficePrecisionRequest,
    ): Pair<OfficePrecisionFailure, String>? {
        if (!host.isMountLive()) {
            return OfficePrecisionFailure.SESSION_ENDING to "mount-not-live"
        }
        if (request.sessionToken != host.sessionToken() || request.generation != host.generation()) {
            return OfficePrecisionFailure.SESSION_MISMATCH to "no-live-mount-for-this-identity"
        }
        if (!host.isReadyState()) {
            return OfficePrecisionFailure.SESSION_ENDING to "mount-not-ready"
        }
        // Owner fence: the engine's OWN mount record wins; a disagreeing
        // caller echo is refused (identity is never taken from the caller).
        val mountTask = host.ownerTaskId()
        if (request.ownerTaskId != null && mountTask != null && request.ownerTaskId != mountTask) {
            return OfficePrecisionFailure.OWNER_MISMATCH to "owner-task-disagrees-with-mount"
        }
        val mountWorkspace = host.workspaceId()
        if (request.workspaceId != null && mountWorkspace != null && request.workspaceId != mountWorkspace) {
            return OfficePrecisionFailure.OWNER_MISMATCH to "workspace-disagrees-with-mount"
        }
        OfficePrecisionRequest.validate(request)?.let {
            return it to "request-shape"
        }
        OfficePrecisionRequest.validateForFormat(request, host.documentFormat())?.let {
            return it to "format-availability"
        }
        if (request.action.effect != OfficePrecisionEffect.QUERY) {
            if (!host.isEditableReady()) {
                return OfficePrecisionFailure.NOT_EDITABLE to "mount-not-editable-ready"
            }
            if (host.saveBusy()) {
                return OfficePrecisionFailure.SAVE_IN_FLIGHT to "save-operation-in-flight"
            }
        }
        return null
    }

    private fun rejectedResult(
        request: OfficePrecisionRequest,
        failure: OfficePrecisionFailure,
        detail: String?,
        now: Long,
    ): OfficePrecisionResult = OfficePrecisionResult(
        opId = request.opId,
        sessionToken = request.sessionToken,
        generation = request.generation,
        action = request.action,
        state = OfficePrecisionState.REJECTED,
        failure = failure,
        detail = detail?.take(240),
        answer = null,
        attestation = "refused-before-dispatch",
        submittedAtElapsedMs = now,
        completedAtElapsedMs = now,
    )

    /**
     * Reads (and consumes) the terminal result for one exact fenced op —
     * the ONLY path typed content ever leaves the engine, to the same-UID
     * owner that passed the token/generation fence.
     *
     * Reply-budget gate (Main marshalling review 2026-10-27): the
     * serialized UTF-16 reply size is estimated BEFORE the result is
     * consumed. A result that could not survive Parcel.writeString within
     * the binder budget is replaced with an honest typed receipt — an
     * oversize READ never masquerades as successful content, and an effect
     * that already occurred keeps its small state/receipt (state, failure,
     * attestation lineage, byte counts) instead of being lost to a
     * TransactionTooLargeException. Content is never .take()-truncated.
     */
    fun readAnswer(opId: String, sessionToken: String, generation: Long): OfficePrecisionResult? {
        if (!host.isMountLive()) return null
        if (sessionToken != host.sessionToken() || generation != host.generation()) return null
        val peeked = ledger.peekResult(opId) ?: return null
        if (peeked.sessionToken != sessionToken || peeked.generation != generation) return null
        if (!OfficePrecisionProtocol.fitsReplyBudget(peeked)) {
            val original = ledger.takeResult(opId) ?: return null
            val refusal = replyBudgetRefusal(original)
            // A QUERY refusal is fully delivered RIGHT HERE: the oversized
            // result is consumed exactly once (takeResult), and the typed
            // refusal must not linger in the ledger for a second delivery —
            // every other read path here is destructive too.
            // An EFFECT (mutation) refusal stays durably readable: the effect
            // already happened, so its replacement is stored until the
            // consumer reads it.
            if (original.action.effect != OfficePrecisionEffect.QUERY) {
                ledger.recordRejection(refusal)
            }
            host.recordDiagnostic(
                "precision op=$opId answer exceeded reply budget: typed refusal issued " +
                    "parcel-estimate=${OfficePrecisionProtocol.estimateResultParcelBytes(original)}",
            )
            return refusal
        }
        return ledger.takeResult(opId)
    }

    private fun replyBudgetRefusal(original: OfficePrecisionResult): OfficePrecisionResult {
        val estimate = OfficePrecisionProtocol.estimateResultParcelBytes(original)
        val contentBytes = when (val answer = original.answer) {
            is OfficePrecisionAnswer.TextSelection -> answer.byteCount
            is OfficePrecisionAnswer.MutationApplied ->
                answer.preEffectEvidence?.selectionByteCount ?: 0
            else -> 0
        }
        val query = original.action.effect == OfficePrecisionEffect.QUERY
        return original.copy(
            // An oversize query answer is an honest typed failure, never a
            // success label without content; a completed mutation keeps its
            // real state and small receipt.
            state = if (query) OfficePrecisionState.FAILED else original.state,
            failure = if (query) OfficePrecisionFailure.ANSWER_TOO_LARGE else original.failure,
            detail = "answer-parcel-bytes=$estimate content-bytes=$contentBytes",
            answer = when (val answer = original.answer) {
                is OfficePrecisionAnswer.TextSelection -> null
                // Keep the already-completed effect's small honest receipt,
                // but never return an oversize pre-effect payload or pretend
                // its unavailable semantic baseline survived the fallback.
                is OfficePrecisionAnswer.MutationApplied ->
                    answer.copy(preEffectEvidence = null)
                else -> answer
            },
            attestation = original.attestation + "+reply-budget-refused",
        )
    }

    // ------------------------------------------------------------------
    // Native frame observation (native thread, BEFORE the WebView relay)
    // ------------------------------------------------------------------

    /**
     * Feeds one triaged native→page frame into the correlation ledger.
     * Returns true when an `error:` frame was CONSUMED as the armed
     * operation's producer refusal (the service must then skip the generic
     * mount-failure handling for it — a precision step error is an
     * operation outcome, not a document failure).
     */
    fun observeNativeFrame(triage: CoolMessageTriage.TriageResult, message: ByteArray): Boolean {
        val kind = mapKind(triage.kind) ?: return false
        if (triage.kind == CoolMessageTriage.Kind.STATE_CHANGED) {
            triage.stateChange?.let { change ->
                if (change.commandName == ".uno:ModifiedStatus") {
                    ledger.lastModifiedStatus = change.state == "true"
                }
            }
        }
        val prefix = asciiPrefix(message)
        val expectKey = ledger.armedExpectationKey()
        val frame = buildFrame(kind, prefix, triage, message, expectKey)
        var consumedError = false
        when (val event = ledger.onFrame(frame)) {
            OfficePrecisionLedger.LedgerEvent.Ignored -> Unit
            is OfficePrecisionLedger.LedgerEvent.DispatchStep -> {
                val run = currentRun
                if (run != null && run.request.opId == event.opId) {
                    val posted = host.runOnControlLane { dispatchStep(run, event.stepIndex) }
                    if (!posted) failRunTransport(run, "control-lane-unavailable")
                }
            }
            is OfficePrecisionLedger.LedgerEvent.Terminal -> finishRun(event.result)
            is OfficePrecisionLedger.LedgerEvent.ConsumedError -> {
                consumedError = true
                finishRun(event.result)
            }
        }
        return consumedError
    }

    private fun buildFrame(
        kind: OfficePrecisionLedger.FrameKind,
        prefix: String,
        triage: CoolMessageTriage.TriageResult,
        message: ByteArray,
        expectKey: String?,
    ): OfficePrecisionLedger.ObservedFrame {
        // Bounded payload extraction ONLY when an armed step can consume it
        // (keeps the relay hot path free of content copies; content itself
        // is never logged — only byte counts and hashes leave this class).
        return when (kind) {
            OfficePrecisionLedger.FrameKind.STATUS -> {
                if (expectKey == OfficePrecisionPlan.Expectation.StatusAnswer.key && prefix == "status") {
                    val extract = extractPayload(message, "status:".length, OfficePrecisionProtocol.MAX_ANSWER_BYTES)
                    OfficePrecisionLedger.ObservedFrame(kind, prefix, extract.first, extract.second, extract.third)
                } else {
                    OfficePrecisionLedger.ObservedFrame(kind, prefix, null, message.size, false)
                }
            }
            OfficePrecisionLedger.FrameKind.COMMAND_VALUE -> {
                val header = triage.commandValue
                OfficePrecisionLedger.ObservedFrame(
                    kind = kind,
                    prefix = prefix,
                    payload = if (header?.commandName != null) "present" else null,
                    payloadBytes = message.size,
                    commandName = header?.commandName,
                    commandValues = header?.commandValues,
                )
            }
            OfficePrecisionLedger.FrameKind.TEXT_SELECTION_CONTENT -> {
                if (expectKey == OfficePrecisionPlan.Expectation.TextSelectionContent.key) {
                    // The protocol parser owns the two pinned framings
                    // ("...: <raw>" vs "...\n<json>"), so the WHOLE frame
                    // text is extracted (bounded; content itself is never
                    // truncated — oversize is refused with its byte count).
                    val extract = extractPayload(message, 0, OfficePrecisionProtocol.MAX_ANSWER_BYTES + 64)
                    OfficePrecisionLedger.ObservedFrame(kind, prefix, extract.first, extract.second, extract.third)
                } else {
                    OfficePrecisionLedger.ObservedFrame(kind, prefix, null, message.size, false)
                }
            }
            OfficePrecisionLedger.FrameKind.PRESENTATION_INFO -> {
                if (expectKey == OfficePrecisionPlan.Expectation.PresentationInfoAnswer.key) {
                    val extract = extractPayload(message, "presentationinfo:".length, OfficePrecisionProtocol.MAX_ANSWER_BYTES)
                    OfficePrecisionLedger.ObservedFrame(kind, prefix, extract.first, extract.second, extract.third)
                } else {
                    OfficePrecisionLedger.ObservedFrame(kind, prefix, null, message.size, false)
                }
            }
            // Callback-emitted frames (textselection/graphicselection/cell*
            // pushes) are corroboration only — no expectation waits for them,
            // so their payload is NEVER extracted (content stays out of
            // memory; only kind + size are counted).
            OfficePrecisionLedger.FrameKind.TEXT_SELECTION,
            OfficePrecisionLedger.FrameKind.GRAPHIC_SELECTION,
            OfficePrecisionLedger.FrameKind.CELL_CURSOR,
            OfficePrecisionLedger.FrameKind.CELL_ADDRESS,
            OfficePrecisionLedger.FrameKind.CELL_FORMULA,
            -> OfficePrecisionLedger.ObservedFrame(kind, prefix, null, message.size, false)
            OfficePrecisionLedger.FrameKind.PASTE_RESULT -> OfficePrecisionLedger.ObservedFrame(
                kind = kind,
                prefix = prefix,
                payloadBytes = message.size,
                pasteVerdict = triage.pasteVerdict,
            )
            OfficePrecisionLedger.FrameKind.PART_SET -> OfficePrecisionLedger.ObservedFrame(
                kind = kind,
                prefix = prefix,
                payloadBytes = message.size,
                partEcho = triage.part?.part,
            )
            OfficePrecisionLedger.FrameKind.ERROR -> OfficePrecisionLedger.ObservedFrame(
                kind = kind,
                prefix = prefix,
                payloadBytes = message.size,
                errorCmd = triage.error?.cmd,
                errorKind = triage.error?.kind,
            )
            else -> OfficePrecisionLedger.ObservedFrame(kind, prefix, null, message.size, false)
        }
    }

    private fun mapKind(kind: CoolMessageTriage.Kind): OfficePrecisionLedger.FrameKind? = when (kind) {
        CoolMessageTriage.Kind.STATUS -> OfficePrecisionLedger.FrameKind.STATUS
        CoolMessageTriage.Kind.COMMAND_VALUE -> OfficePrecisionLedger.FrameKind.COMMAND_VALUE
        CoolMessageTriage.Kind.TEXT_SELECTION_CONTENT -> OfficePrecisionLedger.FrameKind.TEXT_SELECTION_CONTENT
        CoolMessageTriage.Kind.COMPLEX_SELECTION -> OfficePrecisionLedger.FrameKind.COMPLEX_SELECTION
        CoolMessageTriage.Kind.PASTE_RESULT -> OfficePrecisionLedger.FrameKind.PASTE_RESULT
        CoolMessageTriage.Kind.PART_SET -> OfficePrecisionLedger.FrameKind.PART_SET
        CoolMessageTriage.Kind.TEXT_SELECTION -> OfficePrecisionLedger.FrameKind.TEXT_SELECTION
        CoolMessageTriage.Kind.GRAPHIC_SELECTION -> OfficePrecisionLedger.FrameKind.GRAPHIC_SELECTION
        CoolMessageTriage.Kind.CELL_CURSOR -> OfficePrecisionLedger.FrameKind.CELL_CURSOR
        CoolMessageTriage.Kind.CELL_ADDRESS -> OfficePrecisionLedger.FrameKind.CELL_ADDRESS
        CoolMessageTriage.Kind.CELL_FORMULA -> OfficePrecisionLedger.FrameKind.CELL_FORMULA
        CoolMessageTriage.Kind.PRESENTATION_INFO -> OfficePrecisionLedger.FrameKind.PRESENTATION_INFO
        CoolMessageTriage.Kind.STATE_CHANGED -> OfficePrecisionLedger.FrameKind.STATE_CHANGED
        CoolMessageTriage.Kind.UNO_COMMAND_RESULT -> OfficePrecisionLedger.FrameKind.UNO_COMMAND_RESULT
        CoolMessageTriage.Kind.ERROR -> OfficePrecisionLedger.FrameKind.ERROR
        else -> null
    }

    /** Leading ASCII token before ':' (e.g. "status" vs "statusupdate"). */
    private fun asciiPrefix(message: ByteArray): String {
        val sb = StringBuilder(24)
        for (i in 0 until minOf(message.size, 32)) {
            val b = message[i].toInt() and 0xff
            if (b == ':'.code) break
            sb.append(if (b in 0x20..0x7e) b.toChar() else ' ')
        }
        return sb.toString().trim()
    }

    /**
     * Extracts the frame payload after [prefixLength] bytes, bounded by
     * [maxBytes]. Oversize payloads are REFUSED (oversize=true, no content)
     * — never truncated. Returns (payload?, realPayloadBytes, oversize).
     */
    private fun extractPayload(
        message: ByteArray,
        prefixLength: Int,
        maxBytes: Int,
    ): Triple<String?, Int, Boolean> {
        val realBytes = (message.size - prefixLength).coerceAtLeast(0)
        if (realBytes > maxBytes) return Triple(null, realBytes, true)
        val text = String(message, prefixLength, realBytes, Charsets.UTF_8)
        return Triple(text, realBytes, false)
    }

    // ------------------------------------------------------------------
    // Control-lane execution
    //
    // Ingress-monitor discipline (Main ingress integration 2026-10-26):
    // lease activation (claim), admission re-checks, target validation and
    // the ACTUAL wire dispatch all run inside the session-wide
    // `nativeIngressLock` monitor — the SAME monitor that makes one admitted
    // page send atomic (gate check → JNI send → forwarded callback/epoch
    // update). Consequences: a page send already admitted always finishes
    // posting AND updating its epoch before precision validation runs (so a
    // racing manual retarget/edit provably conflicts the target), and any
    // later page mutation/selection is refused once the lease is active.
    // The monitor is NEVER held across async waits for native replies; the
    // lock order is always ingress → engineLock → ledger.
    // ------------------------------------------------------------------

    private fun pumpAsync() {
        host.runOnControlLane { pump() }
    }

    private fun pump() {
        synchronized(engineLock) {
            if (pumping) return
            pumping = true
        }
        try {
            while (true) {
                val claimed = synchronized(host.nativeIngressLock()) {
                    val run = ledger.claimNext() ?: return@synchronized false
                    synchronized(engineLock) {
                        currentRun = run // lease ACTIVATION, under the ingress monitor
                        leaseNoticeReportedForOp = null
                    }
                    beginRun(run)
                    true
                }
                if (!claimed) break
                if (leaseActive()) break // awaiting native answers; finishRun re-pumps
            }
        } finally {
            synchronized(engineLock) { pumping = false }
        }
    }

    /**
     * Claims one run, then (for every non-query action) waits for the REAL
     * page edit-mode handshake before target consumption or any plan wire.
     * READY_EDITABLE / the load ReadOnly barrier remain eligibility gates,
     * never substitutes for the current page EDITMODE fact.
     */
    private fun beginRun(run: OfficePrecisionLedger.OpRun) {
        if (!host.isMountLive() || !host.isReadyState() ||
            run.request.sessionToken != host.sessionToken() ||
            run.request.generation != host.generation()
        ) {
            ledger.rejectRun(run, OfficePrecisionFailure.SESSION_ENDING, "mount-ended-before-dispatch")
                ?.let { finishRun(it) }
            return
        }
        val action = run.request.action
        if (action.effect != OfficePrecisionEffect.QUERY) {
            if (!host.isEditableReady()) {
                ledger.rejectRun(run, OfficePrecisionFailure.NOT_EDITABLE, "mount-not-editable-ready-at-dispatch")
                    ?.let { finishRun(it) }
                return
            }
            if (host.saveBusy()) {
                ledger.rejectRun(run, OfficePrecisionFailure.SAVE_IN_FLIGHT, "save-operation-in-flight-at-dispatch")
                    ?.let { finishRun(it) }
                return
            }
            host.prepareEditableView(run.request.opId) { failure, detail ->
                if (currentRun !== run) return@prepareEditableView
                if (failure != null) {
                    ledger.rejectRun(run, failure, detail)?.let { finishRun(it) }
                } else {
                    continuePreparedRun(run)
                }
            }
        } else {
            continuePreparedRun(run)
        }
    }

    /**
     * Async page callbacks do not inherit beginRun's caller-held monitor.
     * Re-enter the existing ingress monitor before target CAS and step 0;
     * immediate callbacks simply re-enter the same monitor reentrantly.
     */
    private fun continuePreparedRun(run: OfficePrecisionLedger.OpRun) {
        synchronized(host.nativeIngressLock()) {
            continuePreparedRunLocked(run)
        }
    }

    private fun continuePreparedRunLocked(run: OfficePrecisionLedger.OpRun) {
        if (currentRun !== run) return
        if (!host.isMountLive() || !host.isReadyState() ||
            run.request.sessionToken != host.sessionToken() ||
            run.request.generation != host.generation()
        ) {
            ledger.rejectRun(run, OfficePrecisionFailure.SESSION_ENDING, "mount-ended-after-edit-preparation")
                ?.let { finishRun(it) }
            return
        }
        val action = run.request.action
        if (action.effect != OfficePrecisionEffect.QUERY) {
            if (!host.isEditableReady()) {
                ledger.rejectRun(run, OfficePrecisionFailure.NOT_EDITABLE, "edit-permission-lost-after-preparation")
                    ?.let { finishRun(it) }
                return
            }
            if (host.saveBusy()) {
                ledger.rejectRun(run, OfficePrecisionFailure.SAVE_IN_FLIGHT, "save-started-during-edit-preparation")
                    ?.let { finishRun(it) }
                return
            }
        }
        if (action.effect == OfficePrecisionEffect.CONTENT) {
            // Consume the single-use target only AFTER the real page edit
            // handshake. A failed hook/timeout therefore cannot burn a fresh
            // capture or dispatch a guessed mutation.
            val digest = host.workingCopyDigest()
            val sha = digest?.first
            when (val check = ledger.validateTarget(
                handleId = run.request.targetHandle,
                generation = host.generation(),
                currentWorkingCopySha256 = sha,
                consume = true,
            )) {
                is OfficePrecisionLedger.TargetCheck.Refused -> {
                    ledger.rejectRun(run, check.failure, check.detail)?.let { finishRun(it) }
                    return
                }
                is OfficePrecisionLedger.TargetCheck.Ok -> run.contentTarget = check.target
            }
            run.contextSha = sha
        }
        if (action == OfficePrecisionAction.CAPTURE_TARGET) {
            val digest = host.workingCopyDigest()
            ledger.pendingCaptureTarget = ledger.issueTarget(
                generation = host.generation(),
                workingCopySha256 = digest?.first,
                workingCopyBytes = digest?.second ?: 0L,
                documentModified = host.documentModified(),
                sourceId = host.sourceId(),
                sourceRevision = host.sourceRevision(),
                sourceLogicalPath = host.sourceLogicalPath(),
                workspaceId = host.workspaceId(),
                ownerTaskId = host.ownerTaskId(),
            )
        }
        dispatchStep(run, 0)
    }

    /**
     * Arms and posts one step (control lane only; acquires the ingress
     * monitor — reentrant when called from [beginRun]).
     */
    private fun dispatchStep(run: OfficePrecisionLedger.OpRun, stepIndex: Int) {
        if (currentRun !== run) return
        val step = run.plan.getOrNull(stepIndex) ?: return
        synchronized(host.nativeIngressLock()) {
            if (currentRun !== run) return
            if (!host.isMountLive()) {
                ledger.rejectRun(run, OfficePrecisionFailure.SESSION_ENDING, "mount-ended-before-step")
                    ?.let { finishRun(it) }
                return
            }
            if (step.check == OfficePrecisionPlan.StepCheck.PasteSuccess) {
                // The pre-effect query may have waited for native evidence.
                // Re-check the consumed capture at the ACTUAL paste boundary,
                // under the same ingress monitor, rather than relying only on
                // admission-time CAS. A drift refuses before content is sent.
                val digest = host.workingCopyDigest()
                when (val check = ledger.revalidateContentTargetBeforePaste(
                    run, host.generation(), digest?.first,
                )) {
                    is OfficePrecisionLedger.TargetCheck.Refused -> {
                        ledger.rejectRun(run, check.failure, check.detail)?.let { finishRun(it) }
                        return
                    }
                    is OfficePrecisionLedger.TargetCheck.Ok -> Unit
                }
            }
            val expect = step.expect
            when (val decision = ledger.armStep(run, stepIndex)) {
                is OfficePrecisionLedger.ArmDecision.Reject -> {
                    // ledger already terminated the run (refusal path).
                    run.lastTerminal?.let { finishRun(it) }
                    return
                }
                OfficePrecisionLedger.ArmDecision.BarrierFirst -> {
                    armTimeout(run, stepIndex, BARRIER_TIMEOUT_MS)
                    try {
                        host.sendWire(OfficePrecisionProtocol.CMD_BARRIER)
                    } catch (t: Throwable) {
                        cancelTimeout()
                        ledger.abortDispatch(run, t.javaClass.simpleName)?.let { finishRun(it) }
                    }
                }
                OfficePrecisionLedger.ArmDecision.DispatchNow -> {
                    if (expect != null) armTimeout(run, stepIndex, step.timeoutMs)
                    try {
                        val dispatched = OfficeOwnedEditDispatch.run(
                            // Queries never acquire edit authority. Every
                            // non-query run requires the current REAL page
                            // observation again at this exact dispatch point.
                            isPageEditMode = {
                                run.request.action.effect == OfficePrecisionEffect.QUERY || host.isPageEditMode()
                            },
                            sendNativeEditable = {
                                if (run.request.action.effect != OfficePrecisionEffect.QUERY &&
                                    !run.ownedEditViewAsserted
                                ) {
                                    // Same ingress monitor + same serial wire
                                    // as the operation below. This is ordered
                                    // dispatch, not an as-sent success flag.
                                    host.sendOwnedNativeEditable()
                                    run.ownedEditViewAsserted = true
                                }
                            },
                            sendOperation = {
                                if (currentRun !== run) {
                                    throw IllegalStateException("stale-precision-run")
                                }
                                // Mark BEFORE native code can synchronously
                                // re-enter page-off/error callbacks.
                                ledger.noteWireDispatchStarted(run, stepIndex)
                                host.sendWire(step.wire)
                            },
                        )
                        if (!dispatched) {
                            cancelTimeout()
                            ledger.onPageViewing(run.request.opId)?.let { finishRun(it) }
                            return
                        }
                    } catch (t: Throwable) {
                        cancelTimeout()
                        ledger.abortDispatch(run, t.javaClass.simpleName)?.let { finishRun(it) }
                        return
                    }
                    // The wire REALLY reached the kit: effect-bearing steps
                    // mark the run so the terminal advances the effect epoch
                    // even on FAILED/UNKNOWN (maybe-effect) outcomes.
                    ledger.noteWireDispatched(run, stepIndex)
                    if (expect == null) {
                        when (val event = ledger.markDispatched(run, stepIndex)) {
                            is OfficePrecisionLedger.LedgerEvent.DispatchStep ->
                                dispatchStep(run, event.stepIndex)
                            is OfficePrecisionLedger.LedgerEvent.Terminal -> finishRun(event.result)
                            else -> Unit
                        }
                    }
                }
            }
        }
    }

    private fun armTimeout(run: OfficePrecisionLedger.OpRun, stepIndex: Int, timeoutMs: Long) {
        cancelTimeout()
        val opId = run.request.opId
        val task = Runnable { settleStepTimeout(opId, stepIndex) }
        val handle = host.scheduleTimeout(timeoutMs, task)
        synchronized(engineLock) { timeoutHandle = handle }
        if (handle == null) {
            // No scheduler available: settle immediately and honestly.
            settleStepTimeout(opId, stepIndex)
        }
    }

    /** Settles one step timeout on the serialized control lane when possible. */
    private fun settleStepTimeout(opId: String, stepIndex: Int) {
        val ran = host.runOnControlLane {
            val result = ledger.onStepTimeout(opId, stepIndex)
            if (result != null) finishRun(result)
        }
        if (!ran) {
            // Control lane gone (teardown): settle directly — the mount
            // terminal path would settle the run UNKNOWN anyway, and the
            // ledger's exactly-once guard keeps this safe.
            val result = ledger.onStepTimeout(opId, stepIndex)
            if (result != null) finishRun(result)
        }
    }

    private fun cancelTimeout() {
        val handle = synchronized(engineLock) {
            val h = timeoutHandle
            timeoutHandle = null
            h
        }
        if (handle != null) host.cancelTimeout(handle)
    }

    private fun failRunTransport(run: OfficePrecisionLedger.OpRun, detail: String) {
        ledger.abortDispatch(run, detail)?.let { finishRun(it) }
    }

    /** Terminal bookkeeping: diagnostics, lease release, pump continuation. */
    private fun finishRun(result: OfficePrecisionResult) {
        cancelTimeout()
        host.cancelEditableViewPreparation(result.opId)
        synchronized(engineLock) {
            if (currentRun?.request?.opId == result.opId) currentRun = null
        }
        host.recordDiagnostic(
            "precision op=${result.opId} action=${result.action.name} state=${result.state.name}" +
                (result.failure?.let { " failure=$it" } ?: "") +
                " attest=${result.attestation.take(160)}",
        )
        val quarantine = ledger.quarantineActive()
        val poisoned = ledger.barrierPoisoned()
        if (quarantine || poisoned) {
            host.recordDiagnostic(
                "precision correlation fence: quarantine=$quarantine barrierPoisoned=$poisoned",
            )
        }
        pumpAsync()
    }

    /** Mount end (BYE/close/process loss): settle everything UNKNOWN, retain all data. */
    fun onMountTerminal() {
        cancelTimeout()
        synchronized(engineLock) { currentRun?.request?.opId }?.let(host::cancelEditableViewPreparation)
        val results = ledger.onMountTerminal()
        synchronized(engineLock) { currentRun = null }
        results.forEach { result ->
            host.recordDiagnostic(
                "precision op=${result.opId} action=${result.action.name} state=${result.state.name}" +
                    " (mount-terminal)",
            )
        }
    }

    companion object {
        /** Barrier window (short: the local kit answers the pull promptly or not at all). */
        const val BARRIER_TIMEOUT_MS = 15_000L

        /**
         * Page commands that keep flowing while the precision lease is
         * held: pure render/tile/zoom/visibility/keepalive/session-class
         * traffic that cannot retarget selection/part/window state and
         * whose replies cannot collide with precision answer kinds
         * (allowed lifecycle/cancel/render keepalives — Main review
         * 2026-10-27). EVERYTHING else is fail-closed fenced during the
         * lease (mouse/key/selecttext/cellcursor/setpart/find/uno/save/
         * setviewreadonly/dialog/window commands and the reply-collision
         * query class included).
         */
        val LEASE_KEEPALIVE_COMMANDS: Set<String> = setOf(
            "coolclient", "loolclient", "tile", "tilecombine", "tileprocessed",
            "canceltiles", "renderfont", "rendersearchresult", "clientzoom",
            "clientvisiblearea", "clientarea", "resizewindow", "paintwindow",
            "renderwindow", "useractive", "userinactive", "ping", "a11ystate",
            "geta11yfocusedparagraph", "geta11ycaretposition", "getchildid",
            "versionbar", "clientchangeduimode", "longrunningactiondetection",
            // Documented above: `statusupdate:`/`partstatus:` carry distinct
            // reply prefixes and can NEVER settle a `status:` expectation, so
            // they must stay keepalive (unfenced, and inert in
            // noteForwardedPageCommand) exactly as PAGE_QUERY_REPLY_CLASS
            // states.
            "statusupdate", "partstatus",
        )

        /**
         * Page commands whose ANSWERS collide with precision answer kinds
         * (`textselectioncontent:` / `commandvalues:` / `presentationinfo:`
         * / `status:`): while NOT leased they arm the preventive barrier —
         * their late replies must never complete a fresh operation. While
         * leased they are blocked like every other non-keepalive command.
         * (`statusupdate:`/`partstatus:` replies carry distinct prefixes and
         * can never settle a `status:` expectation — they stay keepalive.)
         */
        val PAGE_QUERY_REPLY_CLASS: Set<String> = setOf(
            "gettextselection", "commandvalues", "getpresentationinfo", "status",
        )
    }
}
