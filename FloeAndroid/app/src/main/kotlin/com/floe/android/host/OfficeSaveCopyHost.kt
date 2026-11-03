// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.os.IBinder
import com.floe.android.core.officeengine.OfficeDocumentFormat
import com.floe.android.core.officeengine.OfficeEditState
import com.floe.android.core.officeengine.OfficeEngineCommands
import com.floe.android.core.officeengine.OfficeHostSaveChannel
import com.floe.android.core.officeengine.OfficeHostSaveHandoffPolicy
import com.floe.android.core.officeengine.OfficeHostSaveVerdict
import com.floe.android.core.officeengine.OfficeRequestPolicy
import com.floe.android.core.officeengine.OfficeSaveOperation
import com.floe.android.core.officeengine.OfficeSaveReceipt
import com.floe.android.core.officeengine.OfficeSaveRequest
import com.floe.android.core.officeengine.OfficeSaveState
import com.floe.android.host.officerecovery.OfficeRecoveryCandidate
import com.floe.android.host.officerecovery.OfficeRecoveryDestinationCheck
import com.floe.android.host.officerecovery.OfficeRecoveryExportOutcome
import com.floe.android.host.officerecovery.OfficeRecoveryExportPort
import com.floe.android.host.officerecovery.OfficeRecoveryJournal
import com.floe.android.host.officerecovery.OfficeRecoveryJournalSink
import com.floe.android.host.officerecovery.OfficeRecoveryOriginalState
import com.floe.android.host.officerecovery.OfficeRecoveryPrepareOutcome
import com.floe.android.host.officerecovery.OfficeRecoverySaveFacts
import com.floe.android.host.officerecovery.OfficeRecoveryVerifiedSource
import com.floe.android.host.officerecovery.OFFICE_RECOVERY_MIME_BY_FORMAT
import com.floe.android.safgateway.AndroidSafBackend
import com.floe.android.safgateway.PickAcceptResult
import com.floe.android.safgateway.PickRequestSpec
import com.floe.android.safgateway.SafCancelToken
import com.floe.android.safgateway.SafDocumentRef
import com.floe.android.safgateway.SafFailure
import com.floe.android.safgateway.SafGatewayService
import com.floe.android.safgateway.SafOutcome
import com.floe.android.safgateway.SafUriRef
import com.floe.android.safgateway.SafPickerIntents
import com.floe.android.safgateway.SafPlatformBackend
import java.io.File
import java.io.FileInputStream
import java.nio.file.Files
import java.util.Locale
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * A prepared save-target picker for the FOREGROUND module viewer to launch.
 * The App only constructs the Intent (via [SafPickerIntents] in the Android
 * adapter); it never launches it from the background (BAL), and the module
 * forwards the ACTUAL result back.
 */
internal data class OfficeSaveCopyPreparedPick(
    val identity: OfficeSaveCopyIdentity,
    val spec: PickRequestSpec,
)

/** One App→module terminal settlement (pure data; delivery is the adapter's job). */
internal data class OfficeSaveCopySettlement(
    val opId: String,
    val sessionToken: String,
    /** The EXACT native mount generation the op belongs to (never an App ordinal). */
    val nativeGeneration: Long,
    val verdict: OfficeHostSaveVerdict,
    /** Bounded technical code or null — never a path/URI dump or an enum of internals. */
    val message: String?,
)

/**
 * Pure orchestration core of the App-side Save-Copy host handoff (the Android
 * adapter is [OfficeSaveCopyHost] below; the split keeps every rule testable
 * on the JVM without touching framework types).
 *
 * Real route (Main contract 2026-10-26, module handoff §7):
 *  1. The module viewer's Save-Copy export produced a verified private
 *     artifact and POSTED the terminal OUTPUT_READY receipt to the App host
 *     channel SYNCHRONOUSLY BEFORE asking for a picker. [onReceipt] stores the
 *     exact immutable facts here — never scheduled later, so [onPrepare] can
 *     never race an unstored receipt.
 *  2. [onPrepare] validates the exact live session/op/generation, adapts the
 *     receipt into an [OfficeSaveCopySource] with an App-chosen strictly
 *     increasing PER-SAVE ordinal (distinct from the native mount generation),
 *     prepares the generic SaveCopy controller and returns the gateway spec.
 *     Without a stored, shape-and-path-valid OUTPUT_READY the prepare is
 *     refused (null) — the viewer then surfaces its honest notice.
 *  3. [onPickResult] accepts the ACTUAL result only for the identity captured
 *     at launch (the same op, exact native generation, once), and schedules
 *     delivery + transfer on the caller-provided service IO scheduler — the
 *     Binder/UI threads never run provider acceptance, probes or copy IO.
 *     The return value means ONLY "accepted for processing".
 *  4. [runDelivery] executes the real SAF acceptance, verified stream write
 *     and destination READ-BACK through [OfficeSaveCopyController]; only
 *     [OfficeSaveCopyOutcome.CopiedVerified] maps to COPY_SAVED. Failure and
 *     cancel map to their exact typed verdicts; a Stale result never
 *     announces anything (a stale call can not claim another document's
 *     success). Native OUTPUT_READY, a picked target and working-copy
 *     autosave are NOT user-file-saved states.
 *
 * Lifetime rules: one session per exact session token (a new Office session
 * uses a new [OfficeSaveCopyController]); [endSession] retires only the exact
 * waiting operation and releases the controller only after every scheduled IO
 * drained (quiescence, never a mid-IO clear). Nothing on these paths deletes
 * a working copy, a module-verified output or an uncertain provider
 * destination. C08 adds the durable [com.floe.android.host.officerecovery.OfficeRecoveryJournal]
 * and the App-owned review/action flow: receipts are persisted before a
 * picker can be prepared, the exact target before provider IO, and only a
 * destination read-back yields SAVED. Process loss mid-write stays UNCERTAIN
 * and is never retried automatically.
 */
internal class OfficeSaveCopyHandoff(
    private val service: SafGatewayService,
    private val backend: SafPlatformBackend,
    /** Caller-created directory that hosts the PER-SESSION controller scratch dirs. */
    private val stagingRoot: File,
    /** Canonical module output root: <noBackupFilesDir>/floe-office-outputs. */
    private val outputsRoot: File,
    /** Runs one block on the service-owned IO context. False = refused to queue. */
    private val scheduler: (block: (SafCancelToken) -> Unit) -> Boolean,
    /** Delivers one terminal settlement to the module (synchronous binder in the adapter). */
    private val settlementSink: (OfficeSaveCopySettlement) -> Unit,
    /**
     * Invoked OUTSIDE the handoff lock exactly when the LAST session is
     * removed — including a drain that finishes after the session was already
     * marked ended (Main lifecycle fix 2026-10-26: endEditSession's momentary
     * hasOpenSessions()==false check could not see a later quiescent drain, so
     * the command binding leaked). The adapter must recheck idleness under its
     * own bind lock before releasing the connection so a newly opened session
     * can never lose its binding.
     */
    private val onSessionsIdle: () -> Unit,
    /**
     * Additive Office AI lane seam (Main host20 contract): invoked FIRST,
     * exactly once, for EVERY shape-validated receipt — the AI waiter's own
     * validation is separate and the STAGED_EXPORT/OUTPUT_READY Save-Copy
     * filter below it stays UNCHANGED, so a foreign AI export receipt never
     * reaches the manual picker flow. The default `{}` keeps every existing
     * behavior and assertion byte-identical.
     */
    private val receiptObserver: (OfficeSaveReceipt) -> Unit = {},
    /** Durable recoverability ledger; null preserves the pre-C08 behavior. */
    private val recoveryJournal: OfficeRecoveryJournalSink? = null,
    /** AI-lane exports are not offered as manual recovery candidates. */
    private val journalEligibility: (sessionToken: String, opId: String) -> Boolean = { _, _ -> true },
    /** Fired OUTSIDE the lock when one exact session is removed (drained or immediate). */
    private val onSessionQuiescent: (sessionToken: String) -> Unit = {},
) {

    private companion object {
        /** Mirrors android.app.Activity.RESULT_OK; local so the core stays framework-free. */
        const val RESULT_OK = -1

        /** Bounded RAM tracking per session (newest kept; superseded notices are moot). */
        const val MAX_TRACKED = 8

        val OP_ID = Regex("^[A-Za-z0-9_-]{1,64}$")
        val SHA256_HEX = Regex("^[0-9a-f]{64}$")

        val MIME_BY_FORMAT: Map<String, String> = mapOf(
            "docx" to OfficeDocumentFormat.DOCX.mime,
            "xlsx" to OfficeDocumentFormat.XLSX.mime,
            "pptx" to OfficeDocumentFormat.PPTX.mime,
            "odt" to "application/vnd.oasis.opendocument.text",
            "ods" to "application/vnd.oasis.opendocument.spreadsheet",
            "odp" to "application/vnd.oasis.opendocument.presentation",
            "pdf" to "application/pdf",
        )
    }

    /** One prepared op: exact identity + the native generation it belongs to. */
    private class LaunchRecord(
        val identity: OfficeSaveCopyIdentity,
        val nativeGeneration: Long,
        var delivered: Boolean = false,
        var moduleSettled: Boolean = false,
    )

    private inner class Session(
        val sessionToken: String,
        val controller: OfficeSaveCopyController,
        val displayName: String,
        /** Provider original facts for the same-original refusal (workspace/local docs: null). */
        val original: OfficeSaveCopyOriginal?,
        /** Lock-free liveness probe of the owning viewer operation. */
        val ownerAlive: () -> Boolean,
        /** Recovery candidate this exact session's working copy belongs to. */
        val recoveryCandidateId: String?,
    ) {
        val ordinal = AtomicLong(0)
        val outputs = LinkedHashMap<String, OfficeSaveReceipt>()
        val launched = LinkedHashMap<String, LaunchRecord>()
        var pendingIo = 0
        var ended = false
        var lastEditState: OfficeEditState? = null
    }

    private val lock = Any()
    private val sessions = LinkedHashMap<String, Session>()

    /** Original internal failures, RAM-only, for explicit diagnostics — never ordinary UI copy. */
    @Volatile
    var diagnostic: Any? = null
        private set

    fun hasOpenSessions(): Boolean = synchronized(lock) { sessions.isNotEmpty() }

    // ------------------------------------------------------------------
    // Session lifecycle (one controller per exact Office session)
    // ------------------------------------------------------------------

    fun beginSession(
        sessionToken: String,
        displayName: String,
        original: OfficeSaveCopyOriginal?,
        recoveryCandidateId: String? = null,
        ownerAlive: () -> Boolean,
    ): Boolean = synchronized(lock) {
        if (sessions.containsKey(sessionToken)) {
            diagnostic = "session already open"
            return false
        }
        // The token doubles as the per-session scratch directory name: refuse
        // anything path-shaped instead of silently sanitizing it.
        if (sessionToken.isBlank() || sessionToken.length > 128 ||
            sessionToken.any { it.code < 0x20 || it == '/' || it == '\\' }
        ) {
            diagnostic = "session token unusable as staging name"
            return false
        }
        val dir = File(stagingRoot, sessionToken)
        val usable = runCatching {
            (dir.isDirectory || dir.mkdirs()) && !Files.isSymbolicLink(dir.toPath())
        }.getOrDefault(false)
        if (!usable) {
            diagnostic = "save-copy staging directory unavailable"
            return false
        }
        val controller = try {
            OfficeSaveCopyController(service, backend, sessionToken, dir)
        } catch (bad: IllegalArgumentException) {
            diagnostic = bad
            return false
        }
        sessions[sessionToken] = Session(
            sessionToken, controller, displayName, original, ownerAlive, recoveryCandidateId,
        )
        true
    }

    /**
     * The owning viewer closed/failed/was replaced: retire ONLY the exact
     * waiting operation, announce COPY_CANCELLED for prepared-but-never-picked
     * ops, and release the controller strictly after all scheduled IO drained.
     * No output, working copy or partial destination is deleted here.
     */
    fun endSession(sessionToken: String) {
        val settlements = ArrayList<OfficeSaveCopySettlement>()
        var becameIdle = false
        var removed = false
        synchronized(lock) {
            val s = sessions[sessionToken]
                ?: return
            s.ended = true
            val state = s.controller.state()
            if (state is OfficeSaveCopyState.Active) {
                // Bounded retire: in-flight acceptance/IO is never cleared here
                // (Deferred) — its running owner settles at quiescence.
                s.controller.retire(state.identity)
            }
            for ((opId, record) in s.launched) {
                if (!record.delivered && !record.moduleSettled) {
                    record.moduleSettled = true
                    settlements += OfficeSaveCopySettlement(
                        opId, sessionToken, record.nativeGeneration,
                        OfficeHostSaveVerdict.COPY_CANCELLED, null,
                    )
                }
            }
            if (s.pendingIo == 0) {
                sessions.remove(sessionToken)
                becameIdle = sessions.isEmpty()
                removed = true
            }
        }
        // Sink OUTSIDE the host lock: the settlement is a synchronous binder
        // transaction and must never be issued while holding the lock the
        // inbound channel callbacks need. A throwing sink preserves its
        // original failure (propagated) yet still notifies idleness here in
        // finally, so the adapter's connection cannot be stranded by it; a
        // later in-flight drain notifies through its own path.
        try {
            settlements.forEach(settlementSink)
        } finally {
            if (becameIdle) notifySessionsIdle()
            if (removed) notifySessionQuiescent(sessionToken)
        }
    }

    /** One exact session is gone after all of its scheduled IO drained. */
    private fun notifySessionQuiescent(sessionToken: String) {
        runCatching { onSessionQuiescent(sessionToken) }.onFailure { diagnostic = it }
    }

    /** True while this exact session still owns scheduled transfer IO. */
    fun isSessionBusy(sessionToken: String): Boolean = synchronized(lock) {
        sessions[sessionToken]?.let { it.pendingIo > 0 || !it.ended } ?: false
    }

    /** Idle notification runs outside the host lock; its own failure never masks an original one. */
    private fun notifySessionsIdle() {
        runCatching { onSessionsIdle() }.onFailure { diagnostic = it }
    }

    // ------------------------------------------------------------------
    // Channel handlers (run on Binder threads; return fast, never do provider IO)
    // ------------------------------------------------------------------

    /**
     * Stores the immutable OUTPUT_READY facts synchronously (the module
     * guarantees this transaction happens-before PREPARE_TARGET for the same
     * op). Every fact is shape-, ownership- and path-validated here; anything
     * else is refused fail-closed.
     */
    fun onReceipt(receipt: OfficeSaveReceipt): Boolean {
        // Common shape validation for EVERY receipt (the AI observer's gate).
        if (!OP_ID.matches(receipt.opId) || receipt.generation < 1L) return false
        if (receipt.sessionToken.isBlank() || receipt.sessionToken.length > 128 ||
            receipt.sessionToken.any { it.code < 0x20 || it == '/' || it == '\\' }
        ) {
            return false
        }
        // C08: refresh the durable working-copy fingerprint after a real
        // FLUSHED/UNMODIFIED receipt. This is best-effort (the receipt flow is
        // unchanged); a journal write failure is diagnostic, never a claim.
        if (receipt.operation == OfficeSaveOperation.WORKING_COPY_FLUSH &&
            (receipt.state == OfficeSaveState.FLUSHED || receipt.state == OfficeSaveState.UNMODIFIED) &&
            receipt.workingCopySha256 != null &&
            journalEligibility(receipt.sessionToken, receipt.opId)
        ) {
            val candidateId = synchronized(lock) {
                sessions[receipt.sessionToken]?.takeIf { !it.ended && it.ownerAlive() }?.recoveryCandidateId
            }
            val journal = recoveryJournal
            if (candidateId != null && journal != null) {
                runCatching {
                    journal.recordFlush(
                        candidateId,
                        requireNotNull(receipt.workingCopySha256),
                        receipt.workingCopyBytes,
                    )
                }.onFailure { diagnostic = it }
            }
        }
        // Additive Office AI lane observer FIRST for every shape-validated
        // receipt (Main host20). Its failure can never break the Save-Copy
        // filter below (observer work is the AI waiter table only).
        runCatching { receiptObserver(receipt) }.onFailure { diagnostic = it }
        if (receipt.operation != OfficeSaveOperation.STAGED_EXPORT ||
            receipt.state != OfficeSaveState.OUTPUT_READY
        ) {
            return false
        }
        val format = receipt.format?.lowercase(Locale.ROOT) ?: return false
        if (format !in OfficeRequestPolicy.EXPORT_FORMATS) return false
        val sha = receipt.outputSha256 ?: return false
        if (!SHA256_HEX.matches(sha)) return false
        val bytes = receipt.outputBytes
        if (bytes !in 1..OfficeSaveCopySource.MAX_BYTES) return false
        val path = receipt.outputDocumentPath ?: return false
        if (!outputIsBoundedCanonical(path, receipt.generation, receipt.opId, format)) {
            diagnostic = "staged output shape refused for op ${receipt.opId}"
            return false
        }
        return synchronized(lock) {
            val session = sessions[receipt.sessionToken] ?: return false
            if (session.ended || !session.ownerAlive()) return false
            val candidateId = session.recoveryCandidateId
            val journal = recoveryJournal
            if (candidateId != null && journal != null &&
                journalEligibility(receipt.sessionToken, receipt.opId)
            ) {
                // The verified output identity must be durable BEFORE the
                // handoff can ever expose a picker. A refused journal write is
                // an honest refusal (the module keeps its own output).
                val persisted = runCatching {
                    journal.recordOutputReady(candidateId, receipt)
                }.getOrDefault(false)
                if (!persisted) {
                    diagnostic = "recovery journal refused staged output for op ${receipt.opId}"
                    return false
                }
            }
            session.outputs[receipt.opId] = receipt
            while (session.outputs.size > MAX_TRACKED) session.outputs.remove(session.outputs.keys.first())
            true
        }
    }

    /** Latest observed edit-state snapshot for the exact live session (diagnostics only). */
    fun onEditState(state: OfficeEditState): Boolean = synchronized(lock) {
        val session = sessions[state.sessionToken] ?: return false
        if (session.ended || !session.ownerAlive()) return false
        session.lastEditState = state
        true
    }

    /**
     * Builds the prepared picker for EXACTLY this op. Refused (null) unless:
     * the session is live, no picker was already prepared for the op, the
     * matching OUTPUT_READY receipt is stored with the same generation and
     * format, the private output still passes the canonical ownership check,
     * and the generic controller accepts the adapted source. No lease is
     * attached: releasing the service borrow never deletes the module-owned
     * verified bytes (the caller retains independent recovery ownership).
     */
    fun onPrepare(request: OfficeHostSaveHandoffPolicy.PrepareRequest): OfficeSaveCopyPreparedPick? =
        synchronized(lock) {
            val session = sessions[request.sessionToken] ?: return null
            if (session.ended || !session.ownerAlive()) return null
            if (!OP_ID.matches(request.opId) || request.generation < 1L) return null
            if (session.launched.containsKey(request.opId)) return null
            val receipt = session.outputs[request.opId] ?: return null
            val format = request.format.lowercase(Locale.ROOT)
            if (receipt.generation != request.generation ||
                receipt.format?.lowercase(Locale.ROOT) != format
            ) {
                return null
            }
            val path = receipt.outputDocumentPath ?: return null
            if (!outputIsBoundedCanonical(path, request.generation, request.opId, format)) return null
            val mime = MIME_BY_FORMAT[format] ?: return null
            val output = runCatching { File(path).canonicalFile }.getOrNull() ?: return null
            val name = safeSegment(request.suggestedName)
                ?: safeSegment(session.displayName)
                ?: "office-copy.$format"
            // One save at a time: a busy controller must not consume an App
            // ordinal (the host lock serializes prepares, so state→identity→
            // prepare has no interleaving).
            if (session.controller.state() is OfficeSaveCopyState.Active) return null
            val identity = OfficeSaveCopyIdentity(
                sessionToken = request.sessionToken,
                // The native op id keys the module handoff; the per-save ordinal
                // below is the App's own ledger id and stays DISTINCT from the
                // native mount generation in receipt.generation.
                operation = request.opId,
                generation = session.ordinal.incrementAndGet(),
            )
            val source = try {
                OfficeSaveCopySource.create(
                    identity = identity,
                    expectedSha256 = receipt.outputSha256!!,
                    lengthBytes = receipt.outputBytes,
                    mimeType = mime,
                    suggestedName = name,
                    original = session.original,
                    lease = null,
                ) { FileInputStream(output) }
            } catch (illegal: IllegalArgumentException) {
                diagnostic = illegal
                return null
            }
            val prepared = session.controller.prepare(source)
            if (prepared !is OfficeSaveCopyPrepareResult.Prepared) {
                diagnostic = prepared
                return null
            }
            session.launched[request.opId] = LaunchRecord(identity, request.generation)
            while (session.launched.size > MAX_TRACKED) session.launched.remove(session.launched.keys.first())
            OfficeSaveCopyPreparedPick(identity, prepared.spec)
        }

    /**
     * The ACTUAL foreground picker result for one op. Only the identity
     * captured at THIS op's launch may bind, exactly once; only RESULT_OK
     * carries the real URI/flags verbatim. Returns true = accepted for
     * processing only — success exists solely after the scheduled transfer's
     * destination read-back.
     */
    fun onPickResult(result: OfficeHostSaveHandoffPolicy.PickResult): Boolean {
        val binding: Pair<Session, LaunchRecord> = synchronized(lock) {
            val session = sessions[result.sessionToken] ?: return false
            if (session.ended || !session.ownerAlive()) return false
            val record = session.launched[result.opId] ?: return false
            if (record.nativeGeneration != result.generation || record.delivered) return false
            record.delivered = true
            session.pendingIo += 1
            session to record
        }
        val (session, record) = binding
        val accepted = result.resultCode == RESULT_OK
        val uriString = if (accepted) result.uriString else null
        val flags = if (accepted) result.resultFlags else 0
        // C08: persist TRANSFERRING + the exact destination BEFORE any
        // provider write can start. A journal failure aborts without writing.
        val transferJournal = recoveryJournal
        if (accepted && uriString != null && session.recoveryCandidateId != null &&
            transferJournal != null && journalEligibility(session.sessionToken, result.opId)
        ) {
            val persisted = runCatching {
                transferJournal.markTransferStarted(
                    session.recoveryCandidateId,
                    result.opId,
                    uriString,
                )
            }.getOrDefault(false)
            if (!persisted) {
                var becameIdle = false
                var removed = false
                val settlement = synchronized(lock) {
                    session.pendingIo -= 1
                    record.delivered = false
                    val built = if (record.moduleSettled) null else {
                        record.moduleSettled = true
                        OfficeSaveCopySettlement(
                            record.identity.operation, record.identity.sessionToken,
                            record.nativeGeneration, OfficeHostSaveVerdict.COPY_FAILED,
                            "recovery-journal-unavailable",
                        )
                    }
                    if (session.ended && session.pendingIo == 0) {
                        sessions.remove(session.sessionToken)
                        becameIdle = sessions.isEmpty()
                        removed = true
                    }
                    built
                }
                try {
                    settlement?.let(settlementSink)
                } finally {
                    if (becameIdle) notifySessionsIdle()
                    if (removed) notifySessionQuiescent(session.sessionToken)
                }
                return true
            }
        }
        val scheduled = runCatching {
            scheduler { cancel -> runDelivery(session, record, uriString, flags, cancel) }
        }.getOrDefault(false)
        if (!scheduled) {
            var becameIdle = false
            var removed = false
            val settlement = synchronized(lock) {
                session.pendingIo -= 1
                record.delivered = false
                val built = if (record.moduleSettled) null else {
                    record.moduleSettled = true
                    OfficeSaveCopySettlement(
                        record.identity.operation, record.identity.sessionToken,
                        record.nativeGeneration, OfficeHostSaveVerdict.COPY_FAILED,
                        "host-io-scheduler-unavailable",
                    )
                }
                if (session.ended && session.pendingIo == 0) {
                    sessions.remove(session.sessionToken)
                    becameIdle = sessions.isEmpty()
                    removed = true
                }
                built
            }
            try {
                settlement?.let(settlementSink)
            } finally {
                if (becameIdle) notifySessionsIdle()
                if (removed) notifySessionQuiescent(session.sessionToken)
            }
        }
        return true
    }

    // ------------------------------------------------------------------
    // Scheduled transaction body (service IO context, never Binder/UI)
    // ------------------------------------------------------------------

    private fun runDelivery(
        session: Session,
        record: LaunchRecord,
        uriString: String?,
        returnedIntentFlags: Int,
        cancel: SafCancelToken,
    ) {
        val outcome: OfficeSaveCopyOutcome = try {
            val delivery = session.controller.deliverPickResult(uriString, returnedIntentFlags, record.identity)
            when (delivery) {
                is OfficeSaveCopyDelivery.TargetAccepted -> session.controller.transfer(record.identity, cancel)
                else -> session.controller.settledOutcome()?.takeIf { it.identity == record.identity }
                    ?: OfficeSaveCopyOutcome.Stale(record.identity, "delivery did not bind")
            }
        } catch (unexpected: RuntimeException) {
            diagnostic = unexpected
            OfficeSaveCopyOutcome.Failed(
                record.identity, code = "host-transaction-unexpected",
                stage = OfficeSaveCopyStage.TRANSFERRING,
                detail = unexpected.javaClass.simpleName,
            )
        }
        val candidateId = session.recoveryCandidateId
        val settlementJournal = recoveryJournal
        if (candidateId != null && settlementJournal != null && outcome !is OfficeSaveCopyOutcome.Stale) {
            val facts = when (outcome) {
                is OfficeSaveCopyOutcome.CopiedVerified -> OfficeRecoverySaveFacts(
                    saved = true,
                    uncertain = false,
                    code = null,
                    destinationUri = outcome.destination.uri.uriString,
                    destinationSha256 = outcome.destinationSha256,
                    destinationBytes = outcome.bytes,
                )
                is OfficeSaveCopyOutcome.Cancelled -> OfficeRecoverySaveFacts(
                    saved = false,
                    uncertain = outcome.partialWritePossible,
                    code = if (outcome.partialWritePossible) "cancelled-mid-write" else "cancelled",
                    destinationUri = outcome.targetUri?.uriString,
                    destinationSha256 = null,
                    destinationBytes = 0L,
                )
                is OfficeSaveCopyOutcome.Failed -> OfficeRecoverySaveFacts(
                    saved = false,
                    uncertain = outcome.partialWritePossible,
                    code = outcome.code,
                    destinationUri = outcome.ownedTargetUri?.uriString,
                    destinationSha256 = null,
                    destinationBytes = 0L,
                )
                is OfficeSaveCopyOutcome.Stale -> null
            }
            if (facts != null) {
                runCatching {
                    settlementJournal.settleSave(candidateId, record.identity.operation, facts)
                }.onFailure { diagnostic = it }
            }
        }
        val settlement = synchronized(lock) {
            if (record.moduleSettled) {
                null // a duplicate/late body never announces twice
            } else {
                when (outcome) {
                    // The ONLY path that may say "saved": exact destination byte/hash read-back.
                    is OfficeSaveCopyOutcome.CopiedVerified -> settle(record, OfficeHostSaveVerdict.COPY_SAVED, null)
                    is OfficeSaveCopyOutcome.Cancelled -> settle(record, OfficeHostSaveVerdict.COPY_CANCELLED, null)
                    is OfficeSaveCopyOutcome.Failed -> settle(record, OfficeHostSaveVerdict.COPY_FAILED, outcome.code)
                    // Stale: no transaction record for THIS identity — never announce
                    // another document's success or failure from a foreign call.
                    is OfficeSaveCopyOutcome.Stale -> null
                }
            }
        }
        // Main lifecycle fix 2026-10-26: the settlement delivery must NOT be
        // able to strand the drain bookkeeping. Capture the sink failure,
        // perform the pendingIo decrement + session removal and the idle
        // notification, then re-raise the ORIGINAL failure unchanged (the
        // scheduled task records it honestly). No IO/lease is released early
        // here; the controller's own finally already drained its resources.
        var sinkFailure: Throwable? = null
        try {
            settlement?.let(settlementSink)
        } catch (sink: Throwable) {
            sinkFailure = sink
        }
        var becameIdle = false
        var removed = false
        synchronized(lock) {
            session.pendingIo -= 1
            if (session.ended && session.pendingIo == 0) {
                sessions.remove(session.sessionToken)
                becameIdle = sessions.isEmpty()
                removed = true
            }
        }
        if (becameIdle) notifySessionsIdle()
        if (removed) notifySessionQuiescent(session.sessionToken)
        sinkFailure?.let { throw it }
    }

    /** Caller holds [lock]: mark the record settled and build its exact-identity settlement. */
    private fun settle(record: LaunchRecord, verdict: OfficeHostSaveVerdict, message: String?): OfficeSaveCopySettlement {
        record.moduleSettled = true
        return OfficeSaveCopySettlement(
            opId = record.identity.operation,
            sessionToken = record.identity.sessionToken,
            nativeGeneration = record.nativeGeneration,
            verdict = verdict,
            message = message?.take(240),
        )
    }

    // ------------------------------------------------------------------
    // Pure validation helpers
    // ------------------------------------------------------------------

    /**
     * Bounded canonical private output check: the receipt path must be an
     * absolute regular file (never a symlink) at exactly
     * <outputsRoot>/<nativeGeneration>/<opId>-<elapsed>.<format> under the
     * module's noBackupFilesDir/floe-office-outputs root.
     */
    private fun outputIsBoundedCanonical(path: String, generation: Long, opId: String, format: String): Boolean {
        if (path.isEmpty() || path.contains('\u0000') || !File(path).isAbsolute) return false
        val canonical = runCatching { File(path).canonicalFile }.getOrNull() ?: return false
        val root = runCatching { outputsRoot.canonicalFile }.getOrNull() ?: return false
        val parent = canonical.parentFile ?: return false
        return canonical.isFile &&
            !Files.isSymbolicLink(File(path).toPath()) &&
            parent.name == generation.toString() &&
            parent.parentFile?.path == root.path &&
            canonical.name.matches(Regex("^" + Regex.escape(opId) + "-[0-9]+\\." + Regex.escape(format) + "$"))
    }

    /** Single safe display segment (the source factory re-enforces this; refuse early anyway). */
    private fun safeSegment(raw: String?): String? {
        val segment = raw?.trim()?.substringAfterLast('/')?.substringAfterLast('\\')?.takeIf { it.isNotBlank() }
            ?: return null
        return if (OfficeSaveCopySource.isUnsafeDisplaySegment(segment)) null else segment
    }
}

/**
 * Application-owned Android adapter for the Save-Copy host handoff, created by
 * the App-side [OfficePreviewController] (which the Application owns). It
 * instantiates the exact-session [OfficeHostSaveChannel.parentBinder] once and
 * hands it to the module TWICE with the SAME identity rules:
 *  - attached to every EDIT viewer launch via [com.floe.android.core.officeengine.OfficeEngine.viewerIntent]
 *    beside the existing opaque closeAck + viewerIncarnation;
 *  - carried on the command bind Intent (distinct ACTION identity, non-exported,
 *    same UID). Because Android caches the binder per bind identity and onBind
 *    is NOT re-invoked for a repeat bind, EVERY [onServiceConnected] must call
 *    [OfficeEngineCommands.registerHostChannel] with the actual channel — this
 *    adapter does exactly that (Main API addendum 2026-10-26).
 *
 * Save IO belongs to this application-owned service context, never to a
 * Compose view: view remounts do not cancel transfers, and app process
 * lifetime owns the drain. The engine command connection is bound only while
 * at least one EDIT session is open and released when the last closes.
 */
internal class OfficeSaveCopyHost(
    context: Context,
    private val scope: CoroutineScope,
    private val recoveryJournal: OfficeRecoveryJournal? = null,
) : OfficeRecoveryExportPort {

    private val appContext = context.applicationContext
    private val backend = AndroidSafBackend(appContext)
    private val gatewayService = SafGatewayService(backend, releaseBroker = SharedUriGrantAuthority.broker)
    private val stagingRoot = File(appContext.applicationInfo.dataDir, "files/OfficeSaveCopyScratch")
    private val outputsRoot = File(appContext.noBackupFilesDir, "floe-office-outputs")

    /** Fired when one exact viewer session is fully drained (see handoff). */
    @Volatile
    private var sessionQuiescentListener: ((String) -> Unit)? = null

    private class RecoveryExportOp(
        val candidateId: String,
        val controller: OfficeSaveCopyController,
        val identity: OfficeSaveCopyIdentity,
        val scratchDir: File,
    ) {
        @Volatile var delivering: Boolean = false
    }

    private class DestinationReauthOp(
        val candidateId: String,
        val spec: PickRequestSpec,
    )

    private val recoveryLock = Any()
    private val recoveryOps = LinkedHashMap<String, RecoveryExportOp>()
    private val destinationReauthOps = LinkedHashMap<String, DestinationReauthOp>()

    init {
        // A previous process may have died mid-preparation. No transfer can be
        // running in THIS process yet, and the Office engine process never uses
        // this directory, so only one-off recovery scratch is removed. Disk IO
        // runs off-main; a failure is harmless (bounded private scratch).
        scope.launch(Dispatchers.IO) {
            runCatching {
                stagingRoot.listFiles()
                    ?.filter { it.isDirectory && it.name.startsWith("recovery-") }
                    ?.forEach { dir -> dir.listFiles()?.forEach { it.delete() }; dir.delete() }
            }
        }
    }

    /** The single Office AI lane receipt observer (host20): set by the
     * RuntimeHost-owned pump for its bound epoch and cleared on retire.
     * Null = inert; every existing behavior is byte-identical. */
    @Volatile
    private var aiReceiptObserver: ((OfficeSaveReceipt) -> Unit)? = null

    /** Exact op keys dispatched through the AI lane. A receipt/prepare for a
     * tracked op must NEVER hand the FOREGROUND viewer a manual SAF picker —
     * the AI chain consumes its own typed receipts (Main host20). Bounded;
     * ops are never reused, so entries simply age out. */
    private val aiOperationGuard = com.floe.android.host.officeai.OfficeAiOperationGuard()

    private val handoff = OfficeSaveCopyHandoff(
        service = gatewayService,
        backend = backend,
        stagingRoot = stagingRoot,
        outputsRoot = outputsRoot,
        scheduler = ::scheduleIo,
        settlementSink = ::deliverSettlement,
        onSessionsIdle = ::releaseIdleConnection,
        receiptObserver = { receipt -> aiReceiptObserver?.invoke(receipt) },
        recoveryJournal = recoveryJournal,
        journalEligibility = { token, opId -> !isAiOwnedOperation(token, opId) },
        onSessionQuiescent = { token -> sessionQuiescentListener?.invoke(token) },
    )

    /** The single parent endpoint the module fences by same-UID + descriptor. */
    val channel: IBinder by lazy {
        OfficeHostSaveChannel.parentBinder(
            onPrepare = { request ->
                if (isAiOwnedOperation(request.sessionToken, request.opId)) {
                    // A foreign AI export must never open the manual SAF
                    // picker; the AI chain consumes its own receipts.
                    null
                } else {
                    handoff.onPrepare(request)?.let { pick -> SafPickerIntents.from(pick.spec) }
                }
            },
            onPickResult = { result -> handoff.onPickResult(result) },
            onReceipt = { receipt -> handoff.onReceipt(receipt) },
            onEditState = { state -> handoff.onEditState(state) },
        )
    }

    /** Attaches (or clears with null) the single Office AI lane receipt
     * observer feeding the handoff's shape-validated receipt stream. The
     * channel-28 registration ownership and the Save-Copy filter below the
     * observer are untouched. */
    internal fun attachAiReceiptObserver(observer: ((OfficeSaveReceipt) -> Unit)?) {
        aiReceiptObserver = observer
    }

    private fun isAiOwnedOperation(sessionToken: String, opId: String): Boolean =
        aiOperationGuard.contains(sessionToken, opId)

    /**
     * Submits one AI-lane save/export op through THIS host's OWN
     * transaction-20 binding — the same [OfficeEngineCommands.submitSave]
     * the viewer flow uses (no second binder, no channel-28 change). The
     * exact op is tracked BEFORE dispatch so its OUTPUT_READY can only
     * settle the AI waiter, never the manual picker.
     *
     * The typed outcome keeps the dispatch-proof distinction Main's final
     * review requires (same doctrine as the precision adapter): a missing
     * command binding proves nothing was sent ([NotBound] shape via
     * [com.floe.android.host.officeai.OfficeAiSaveSubmit.NotBound]); a lost
     * reply AFTER the transaction was issued is
     * [com.floe.android.host.officeai.OfficeAiSaveSubmit.AttemptedWithoutReply]
     * — the op may hold the engine and must resolve through the registered
     * receipt waiter or stay UNKNOWN/retained, never a re-send.
     */
    internal fun aiSubmitSave(
        request: OfficeSaveRequest,
    ): com.floe.android.host.officeai.OfficeAiSaveSubmit {
        ensureConnected()
        aiOperationGuard.track(request.sessionToken, request.opId)
        val client = synchronized(bindLock) { commands }
            ?: return com.floe.android.host.officeai.OfficeAiSaveSubmit.NotBound
        // submitSave is documented fail-closed (returns null on any transport
        // problem AFTER the transaction was attempted); a throwing client
        // frame is treated identically — attempted-without-reply.
        val code = runCatching { client.submitSave(request) }.getOrNull()
        return code?.let { com.floe.android.host.officeai.OfficeAiSaveSubmit.Code(it) }
            ?: com.floe.android.host.officeai.OfficeAiSaveSubmit.AttemptedWithoutReply
    }

    /** The ENGINE's native mount generation for the exact session token
     * (0 when no live mount / no command binding) — read through the same
     * deterministic acquisition seam the viewer uses. */
    internal fun aiReadGeneration(sessionToken: String): Long {
        ensureConnected()
        val client = synchronized(bindLock) { commands } ?: return 0L
        return runCatching { client.readGeneration(sessionToken) }.getOrDefault(0L)
    }

    /** The ENGINE's live edit-state projection for the exact session +
     * native generation (null when unresolvable). Observed facts only —
     * READY_EDITABLE/editPermissionEstablished are real engine witnesses,
     * never an App "editable" flag. */
    internal fun aiReadState(sessionToken: String, generation: Long): OfficeEditState? {
        ensureConnected()
        val client = synchronized(bindLock) { commands } ?: return null
        return runCatching { client.readState(sessionToken, generation) }.getOrNull()
    }

    private val bindLock = Any()
    @Volatile
    private var commands: OfficeEngineCommands? = null
    private var bound = false
    private val pending = ArrayDeque<OfficeSaveCopySettlement>()

    /** Settlement transport failure evidence, RAM-only, explicit diagnostics only. */
    @Volatile
    var settlementDiagnostic: String? = null
        private set

    private val connection: ServiceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            val client = OfficeEngineCommands(binder)
            // REQUIRED on EVERY connect: onBind extras are cached per bind
            // identity and later bindings cannot refresh a callback by extras
            // alone; only this explicit transaction-28 registration updates it.
            val registered = runCatching { client.registerHostChannel(channel) }.getOrDefault(false)
            if (!registered) settlementDiagnostic = "host channel re-registration refused"
            val flush: List<OfficeSaveCopySettlement> = synchronized(bindLock) {
                commands = client
                // onServiceConnected runs on the main thread; drain the queue
                // onto the service IO context instead of blocking the UI on
                // binder transactions.
                val copy = pending.toList()
                pending.clear()
                copy
            }
            if (flush.isNotEmpty()) {
                scheduleIo { settlementSinkSequence(flush) }
            }
        }

        override fun onServiceDisconnected(name: ComponentName) {
            // Engine process death: the mounts those verdicts belonged to are
            // gone; keep the queue bounded — a later bind is a NEW mount and
            // fenced-stale settlements simply refuse (never re-announced by
            // another document's session).
            synchronized(bindLock) { commands = null }
        }

        override fun onBindingDied(name: ComponentName) {
            // Main lifecycle fix 2026-10-26: a died binding's REGISTRATION must
            // be released with unbindService too — clearing only `bound` would
            // strand the registered ServiceConnection handle. No invented
            // successful reconnect: a later EDIT session's begin will re-bind
            // from a clean state.
            synchronized(bindLock) {
                commands = null
                pending.clear()
                if (bound) {
                    runCatching { appContext.unbindService(connection) }
                    bound = false
                }
            }
            settlementDiagnostic = "engine command binding died"
        }

        override fun onNullBinding(name: ComponentName) {
            // The registration stays alive and is released coherently when the
            // last session goes idle (releaseIdleConnection) — unbinding from
            // here without a session recheck would race a fresh begin.
            synchronized(bindLock) {
                commands = null
                pending.clear()
            }
            settlementDiagnostic = "engine returned a null command binding"
        }
    }

    private fun settlementSinkSequence(settlements: List<OfficeSaveCopySettlement>) {
        settlements.forEach { deliverSettlementNow(it) }
    }

    /** Opens one exact-session handoff and ensures the command connection exists. */
    fun beginEditSession(
        sessionToken: String,
        displayName: String,
        original: OfficeSaveCopyOriginal?,
        recoveryCandidateId: String?,
        ownerAlive: () -> Boolean,
    ): Boolean {
        if (!handoff.beginSession(
                sessionToken, displayName, original, recoveryCandidateId, ownerAlive,
            )
        ) {
            return false
        }
        ensureConnected()
        return true
    }

    /** Installs the single App-owned "one session fully drained" listener. */
    internal fun setSessionQuiescentListener(listener: ((String) -> Unit)?) {
        sessionQuiescentListener = listener
    }

    /** Closes one exact session; releases the controller's IO ownership at drain.
     * Connection release is driven by the handoff's quiescent-drain idle
     * notification (Main lifecycle fix 2026-10-26), never by this call's
     * momentary session count — an ended session with IO still in flight must
     * keep the binding until that IO drains. */
    fun endEditSession(sessionToken: String) {
        handoff.endSession(sessionToken)
    }

    /**
     * Called from the handoff OUTSIDE its lock exactly when the last session
     * was removed (immediately, or later when a drained in-flight IO quiesced).
     * Rechecks idleness while holding [bindLock] so a session opened in the
     * meantime can never lose its connection; the recheck takes only the short
     * host lock and no path holds the host lock while waiting on bindLock.
     */
    private fun releaseIdleConnection() {
        synchronized(bindLock) {
            if (bound && !handoff.hasOpenSessions()) {
                runCatching { appContext.unbindService(connection) }
                bound = false
                commands = null
                pending.clear()
            }
        }
    }

    /** Last internal handoff/transport failure, for explicit diagnostic views only. */
    fun lastDiagnostic(): Any? = handoff.diagnostic ?: settlementDiagnostic

    // ------------------------------------------------------------------
    // C08 recovery export port (OfficeRecoveryExportPort)
    // ------------------------------------------------------------------

    /**
     * Prepare ONE App-owned recovery export of the exact module-verified
     * output. This reuses the SAME [OfficeSaveCopyController] and SAF gateway
     * as the viewer Save-Copy flow; no second save system is created. The
     * returned spec is launched only by the foreground recovery effect.
     */
    override fun prepare(
        candidate: OfficeRecoveryCandidate,
        source: OfficeRecoveryVerifiedSource,
    ): OfficeRecoveryPrepareOutcome {
        val format = source.format.lowercase(Locale.ROOT)
        val mime = OFFICE_RECOVERY_MIME_BY_FORMAT[format]
            ?: return OfficeRecoveryPrepareOutcome.Refused("format")
        if (!recoveryOutputIsOwned(source.path) ||
            source.bytes !in 1..OfficeSaveCopySource.MAX_BYTES ||
            !Regex("^[0-9a-f]{64}$").matches(source.sha256)
        ) {
            return OfficeRecoveryPrepareOutcome.Refused("source")
        }
        val suffix = UUID.randomUUID().toString().replace("-", "").take(24)
        val requestId = "recovery-$suffix"
        val sessionToken = "recovery-session-$suffix"
        val scratch = File(stagingRoot, "recovery-$requestId")
        val usable = runCatching {
            (scratch.isDirectory || scratch.mkdirs()) && !Files.isSymbolicLink(scratch.toPath())
        }.getOrDefault(false)
        if (!usable) return OfficeRecoveryPrepareOutcome.Refused("storage")
        val identity = try {
            OfficeSaveCopyIdentity(sessionToken, requestId, 1L)
        } catch (_: IllegalArgumentException) {
            runCatching { scratch.delete() }
            return OfficeRecoveryPrepareOutcome.Refused("identity")
        }
        val original = candidate.originalUri?.let { uri ->
            runCatching { OfficeSaveCopyOriginal(SafUriRef(uri), candidate.originalDocumentId) }.getOrNull()
        }
        val displayName = recoverySuggestedName(candidate.displayName, format)
        val controller = try {
            OfficeSaveCopyController(gatewayService, backend, sessionToken, scratch)
        } catch (_: IllegalArgumentException) {
            runCatching { scratch.delete() }
            return OfficeRecoveryPrepareOutcome.Refused("storage")
        }
        val saveSource = try {
            OfficeSaveCopySource.create(
                identity = identity,
                expectedSha256 = source.sha256,
                lengthBytes = source.bytes,
                mimeType = mime,
                suggestedName = displayName,
                original = original,
                lease = null,
            ) { FileInputStream(File(source.path)) }
        } catch (_: IllegalArgumentException) {
            runCatching { scratch.delete() }
            return OfficeRecoveryPrepareOutcome.Refused("source")
        }
        val prepared = controller.prepare(saveSource)
        if (prepared !is OfficeSaveCopyPrepareResult.Prepared) {
            runCatching { scratch.delete() }
            return OfficeRecoveryPrepareOutcome.Refused("prepare")
        }
        val op = RecoveryExportOp(candidate.id, controller, identity, scratch)
        synchronized(recoveryLock) {
            recoveryOps[requestId] = op
        }
        return OfficeRecoveryPrepareOutcome.Ready(requestId, prepared.spec)
    }

    /**
     * Deliver the ACTUAL picker result and run the real acceptance, bounded
     * stream write and destination read-back on the gateway IO context. The
     * callback carries the honest App-side outcome; this method returning true
     * means only "scheduled/started".
     */
    override fun deliver(
        requestId: String,
        uriString: String?,
        resultFlags: Int,
        callback: (OfficeRecoveryExportOutcome) -> Unit,
    ): Boolean {
        val op = synchronized(recoveryLock) { recoveryOps[requestId] } ?: return false
        op.delivering = true
        val scheduled = runCatching {
            gatewayService.submit { cancel ->
                val outcome = try {
                    val delivery = op.controller.deliverPickResult(uriString, resultFlags, op.identity)
                    when (delivery) {
                        is OfficeSaveCopyDelivery.TargetAccepted ->
                            op.controller.transfer(op.identity, cancel)
                        else -> op.controller.settledOutcome()
                            ?.takeIf { it.identity == op.identity }
                            ?: OfficeSaveCopyOutcome.Stale(op.identity, "delivery did not bind")
                    }
                } catch (unexpected: RuntimeException) {
                    // An unexpected unwind may have happened after acceptance,
                    // so the destination is kept UNCERTAIN rather than labeled
                    // failed; nothing is retried automatically.
                    OfficeSaveCopyOutcome.Failed(
                        op.identity,
                        code = "recovery-transaction-unexpected",
                        stage = OfficeSaveCopyStage.TRANSFERRING,
                        detail = unexpected.javaClass.simpleName,
                        ownedTargetUri = uriString?.let { runCatching { SafUriRef(it) }.getOrNull() },
                        partialWritePossible = true,
                    )
                }
                val mapped = recoveryOutcome(requestId, outcome)
                try {
                    callback(mapped)
                } finally {
                    op.delivering = false
                    cleanupRecoveryOp(requestId)
                }
                SafOutcome.success(Unit)
            }
            true
        }.getOrDefault(false)
        if (!scheduled) {
            op.delivering = false
            try {
                callback(OfficeRecoveryExportOutcome.Failed(requestId, "scheduler-unavailable"))
            } finally {
                cleanupRecoveryOp(requestId)
            }
        }
        return true
    }

    override fun cancel(requestId: String) {
        var target: RecoveryExportOp? = null
        synchronized(recoveryLock) {
            destinationReauthOps.remove(requestId)
            val current = recoveryOps[requestId] ?: return
            if (current.delivering) return
            recoveryOps.remove(requestId)
            target = current
        }
        target?.let(::deleteRecoveryScratch)
    }

    override fun hasActiveFor(candidateId: String): Boolean = synchronized(recoveryLock) {
        recoveryOps.values.any { it.candidateId == candidateId }
    }

    override fun isSessionBusy(sessionToken: String): Boolean = handoff.isSessionBusy(sessionToken)

    override fun prepareDestinationReauthorization(
        candidate: OfficeRecoveryCandidate,
    ): OfficeRecoveryPrepareOutcome {
        val format = (candidate.outputFormat ?: candidate.format).lowercase(Locale.ROOT)
        val mime = OFFICE_RECOVERY_MIME_BY_FORMAT[format]
            ?: return OfficeRecoveryPrepareOutcome.Refused("format")
        val requestId = "reauth-" + UUID.randomUUID().toString().replace("-", "").take(24)
        val spec = try {
            gatewayService.grants.pickerForOpenDocument(listOf(mime))
        } catch (_: IllegalArgumentException) {
            return OfficeRecoveryPrepareOutcome.Refused("picker")
        }
        synchronized(recoveryLock) {
            destinationReauthOps[requestId] = DestinationReauthOp(candidate.id, spec)
        }
        return OfficeRecoveryPrepareOutcome.Ready(requestId, spec)
    }

    /**
     * Accept the re-picked destination through the SAME gateway, then require
     * the exact destination identity AND byte equality. A different file is
     * never treated as the previous destination; no write occurs here.
     */
    override fun deliverDestinationReauthorization(
        requestId: String,
        uriString: String?,
        resultFlags: Int,
        expectedUri: String,
        expectedSha256: String,
        expectedBytes: Long,
    ): OfficeRecoveryDestinationCheck {
        val op = synchronized(recoveryLock) { destinationReauthOps.remove(requestId) }
            ?: return OfficeRecoveryDestinationCheck.Unavailable("stale")
        val accepted = try {
            gatewayService.grants.acceptPickResult(op.spec, uriString, resultFlags)
        } catch (_: RuntimeException) {
            return OfficeRecoveryDestinationCheck.Unavailable("acceptance-failed")
        }
        return when (accepted) {
            is PickAcceptResult.Cancelled -> OfficeRecoveryDestinationCheck.Unavailable("cancelled")
            is PickAcceptResult.Rejected -> OfficeRecoveryDestinationCheck.GrantRequired(accepted.reason)
            is PickAcceptResult.Accepted -> {
                if (accepted.uri.uriString != expectedUri) {
                    OfficeRecoveryDestinationCheck.Differs(null, null, "identity-mismatch")
                } else {
                    checkDestination(accepted.uri.uriString, expectedSha256, expectedBytes)
                }
            }
        }
    }

    /**
     * Read the uncertain destination back under a LIVE grant. It never
     * persists/takes a grant, never writes, and never deletes. Missing/expired
     * access is reported as GrantRequired so the UI can offer a deliberate
     * new-copy save instead of silently re-taking authority.
     */
    override fun checkDestination(
        uriString: String,
        expectedSha256: String,
        expectedBytes: Long,
    ): OfficeRecoveryDestinationCheck {
        val target = runCatching { SafDocumentRef(null, null, null, SafUriRef(uriString)) }.getOrNull()
            ?: return OfficeRecoveryDestinationCheck.Unavailable("invalid-uri")
        val operation = runCatching {
            gatewayService.submit { cancel ->
                gatewayService.operations.streamRead(
                    target,
                    OfficeSaveCopySource.MAX_BYTES,
                    null,
                    cancel,
                ) { _, _ -> }
            }
        }.getOrNull() ?: return OfficeRecoveryDestinationCheck.Unavailable("scheduler-unavailable")
        return when (val outcome = operation.await(30_000L)) {
            is SafOutcome.Failure -> when (val failure = outcome.failure) {
                SafFailure.GrantMissing, SafFailure.Revoked ->
                    OfficeRecoveryDestinationCheck.GrantRequired(failure.code)
                is SafFailure.RePickRequired ->
                    OfficeRecoveryDestinationCheck.GrantRequired(failure.code)
                SafFailure.NotFound ->
                    OfficeRecoveryDestinationCheck.Differs(null, null, "not-found")
                is SafFailure.SizeLimitExceeded ->
                    OfficeRecoveryDestinationCheck.Differs(null, null, "size-limit")
                else -> OfficeRecoveryDestinationCheck.Unavailable(failure.code)
            }
            is SafOutcome.Success -> {
                val summary = outcome.value
                if (summary.completed && summary.bytes == expectedBytes && summary.sha256 == expectedSha256) {
                    OfficeRecoveryDestinationCheck.Verified(summary.sha256, summary.bytes)
                } else {
                    OfficeRecoveryDestinationCheck.Differs(summary.bytes, summary.sha256, "content-differs")
                }
            }
        }
    }

    /**
     * Stage the live provider original into an App-owned immutable review
     * directory using the EXISTING provider operations and live grant. This
     * performs a READ only: no write, no rename, no grant persistence and no
     * original overwrite. The caller supplies a directory it already owns
     * and is responsible for deleting it after the review.
     */
    fun captureOriginal(
        uriString: String,
        directory: File,
        timeoutMillis: Long = 30_000L,
    ): com.floe.android.host.officereview.OfficeOriginalCapture {
        val source = runCatching { SafDocumentRef(null, null, null, SafUriRef(uriString)) }.getOrNull()
            ?: return com.floe.android.host.officereview.OfficeOriginalCapture.Failed("invalidIdentity")
        val root = runCatching { directory.canonicalFile }.getOrNull()
            ?: return com.floe.android.host.officereview.OfficeOriginalCapture.Failed("reviewStorageUnavailable")
        if (!root.isDirectory) return com.floe.android.host.officereview.OfficeOriginalCapture.Failed("reviewStorageUnavailable")
        val operation = runCatching {
            gatewayService.submit { cancel ->
                gatewayService.operations.stageToWorkingCopy(
                    source,
                    root,
                    OfficeSaveCopySource.MAX_BYTES,
                    cancel,
                )
            }
        }.getOrNull() ?: return com.floe.android.host.officereview.OfficeOriginalCapture.Failed("gatewayUnavailable")
        return when (val outcome = operation.await(timeoutMillis)) {
            is SafOutcome.Failure -> com.floe.android.host.officereview.OfficeOriginalCapture.Failed(
                when (outcome.failure) {
                    SafFailure.GrantMissing, SafFailure.Revoked ->
                        "grantRequired"
                    is SafFailure.RePickRequired -> "grantRequired"
                    SafFailure.NotFound -> "originalMissing"
                    is SafFailure.SizeLimitExceeded -> "originalTooLarge"
                    is SafFailure.Unsupported -> "originalUnsupported"
                    else -> "originalUnavailable"
                },
            )
            is SafOutcome.Success -> {
                val copy = outcome.value
                val file = copy.local.file
                val verified = runCatching {
                    file.isFile &&
                        !Files.isSymbolicLink(file.toPath()) &&
                        file.length() == copy.bytes &&
                        file.setReadOnly()
                }.getOrDefault(false)
                if (!verified) {
                    runCatching { file.delete() }
                    com.floe.android.host.officereview.OfficeOriginalCapture.Failed("originalUnverified")
                } else {
                    com.floe.android.host.officereview.OfficeOriginalCapture.Captured(
                        file = file,
                        sha256 = copy.sha256,
                        bytes = copy.bytes,
                    )
                }
            }
        }
    }

    /**
     * Probe whether the provider original still has the source fingerprint.
     * This is a read under the EXISTING live grant only; it never trusts the
     * persisted URI string and never re-takes access.
     */
    override fun probeOriginal(
        uriString: String,
        expectedSha256: String,
        expectedBytes: Long,
    ): OfficeRecoveryOriginalState {
        val source = runCatching { SafDocumentRef(null, null, null, SafUriRef(uriString)) }.getOrNull()
            ?: return OfficeRecoveryOriginalState.UNAVAILABLE
        val operation = runCatching {
            gatewayService.submit { cancel ->
                gatewayService.operations.streamRead(
                    source,
                    OfficeSaveCopySource.MAX_BYTES,
                    null,
                    cancel,
                ) { _, _ -> }
            }
        }.getOrNull() ?: return OfficeRecoveryOriginalState.UNAVAILABLE
        return when (val outcome = operation.await(30_000L)) {
            is SafOutcome.Failure -> when (outcome.failure) {
                SafFailure.GrantMissing, SafFailure.Revoked -> OfficeRecoveryOriginalState.UNAVAILABLE
                is SafFailure.RePickRequired -> OfficeRecoveryOriginalState.UNAVAILABLE
                SafFailure.NotFound -> OfficeRecoveryOriginalState.CHANGED
                is SafFailure.SizeLimitExceeded -> OfficeRecoveryOriginalState.CHANGED
                else -> OfficeRecoveryOriginalState.UNAVAILABLE
            }
            is SafOutcome.Success -> {
                val summary = outcome.value
                if (summary.completed && summary.bytes == expectedBytes && summary.sha256 == expectedSha256) {
                    OfficeRecoveryOriginalState.UNCHANGED
                } else {
                    OfficeRecoveryOriginalState.CHANGED
                }
            }
        }
    }

    private fun recoveryOutcome(
        requestId: String,
        outcome: OfficeSaveCopyOutcome,
    ): OfficeRecoveryExportOutcome = when (outcome) {
        is OfficeSaveCopyOutcome.CopiedVerified -> OfficeRecoveryExportOutcome.Saved(
            requestId,
            outcome.destination.uri.uriString,
            outcome.destinationSha256,
            outcome.bytes,
        )
        is OfficeSaveCopyOutcome.Cancelled -> if (outcome.partialWritePossible) {
            OfficeRecoveryExportOutcome.Uncertain(
                requestId,
                outcome.targetUri?.uriString,
                "cancelled-mid-write",
            )
        } else {
            OfficeRecoveryExportOutcome.Cancelled(requestId, "cancelled")
        }
        is OfficeSaveCopyOutcome.Failed -> if (outcome.partialWritePossible) {
            OfficeRecoveryExportOutcome.Uncertain(
                requestId,
                outcome.ownedTargetUri?.uriString,
                outcome.code,
            )
        } else {
            OfficeRecoveryExportOutcome.Failed(requestId, outcome.code)
        }
        is OfficeSaveCopyOutcome.Stale -> OfficeRecoveryExportOutcome.Stale(requestId, outcome.reason)
    }

    private fun recoveryOutputIsOwned(path: String): Boolean {
        if (path.isEmpty() || path.length > 4096 || path.contains('\u0000') || !File(path).isAbsolute) return false
        val file = runCatching { File(path).canonicalFile }.getOrNull() ?: return false
        val root = runCatching { outputsRoot.canonicalFile }.getOrNull() ?: return false
        return !Files.isSymbolicLink(File(path).toPath()) &&
            file.isFile &&
            file.path.startsWith(root.path + File.separator)
    }

    private fun recoverySuggestedName(raw: String?, format: String): String {
        val trimmed = raw?.trim().orEmpty()
        val base = trimmed
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .substringBeforeLast('.', trimmed)
            .takeIf { it.isNotBlank() && it.length <= 220 }
        val name = ((base ?: "office-copy") + "." + format).take(240)
        return if (OfficeSaveCopySource.isUnsafeDisplaySegment(name)) "office-copy.$format" else name
    }

    private fun cleanupRecoveryOp(requestId: String) {
        var target: RecoveryExportOp? = null
        synchronized(recoveryLock) {
            val current = recoveryOps[requestId] ?: return
            if (current.delivering) return
            recoveryOps.remove(requestId)
            target = current
        }
        target?.let(::deleteRecoveryScratch)
    }

    private fun deleteRecoveryScratch(op: RecoveryExportOp) {
        runCatching {
            op.scratchDir.listFiles()?.forEach { it.delete() }
            op.scratchDir.delete()
        }
    }

    private fun ensureConnected() = synchronized(bindLock) {
        if (bound) return
        val intent = OfficeEngineCommands.bindIntent(appContext, channel)
        bound = runCatching {
            appContext.bindService(intent, connection, Context.BIND_AUTO_CREATE)
        }.getOrDefault(false)
        if (!bound) settlementDiagnostic = "engine command bind refused"
    }

    private fun scheduleIo(block: (SafCancelToken) -> Unit): Boolean = runCatching {
        gatewayService.submit { cancel ->
            block(cancel)
            SafOutcome.success(Unit)
        }
        true
    }.getOrDefault(false)

    private fun deliverSettlement(settlement: OfficeSaveCopySettlement) {
        val clientSnapshot: OfficeEngineCommands?
        synchronized(bindLock) {
            if (commands == null) {
                // Bounded backlog for a fast reconnect only; a mount that never
                // returns simply never receives it (honest: no success claimed).
                if (pending.size >= MAX_PENDING_SETTLEMENTS) pending.removeFirst()
                pending.addLast(settlement)
                return
            }
            clientSnapshot = commands
        }
        clientSnapshot?.let { deliverSettlementNow(settlement, it) }
    }

    private fun deliverSettlementNow(settlement: OfficeSaveCopySettlement, client: OfficeEngineCommands? = null) {
        val target = client ?: synchronized(bindLock) { commands } ?: run {
            deliverSettlement(settlement)
            return
        }
        val sent = runCatching {
            target.settleHostSaveCopy(
                settlement.opId,
                settlement.sessionToken,
                settlement.nativeGeneration,
                settlement.verdict,
                settlement.message,
            )
        }.getOrDefault(false)
        if (!sent) {
            // Fenced (stale mount/op) or transport failure: never retry across
            // another session, never fake the acknowledgement.
            settlementDiagnostic = "settlement refused op=${settlement.opId} verdict=${settlement.verdict.name}"
        }
    }

    private companion object {
        const val MAX_PENDING_SETTLEMENTS = 8
    }
}
