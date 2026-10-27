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
import com.floe.android.safgateway.AndroidSafBackend
import com.floe.android.safgateway.PickRequestSpec
import com.floe.android.safgateway.SafCancelToken
import com.floe.android.safgateway.SafGatewayService
import com.floe.android.safgateway.SafOutcome
import com.floe.android.safgateway.SafPickerIntents
import com.floe.android.safgateway.SafPlatformBackend
import java.io.File
import java.io.FileInputStream
import java.nio.file.Files
import java.util.Locale
import java.util.concurrent.atomic.AtomicLong

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
 * destination; recoverable bytes stay the App's retention obligation and a
 * user-visible recovery flow is explicitly PENDING, not claimed.
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
        sessions[sessionToken] = Session(sessionToken, controller, displayName, original, ownerAlive)
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
        }
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
        val scheduled = runCatching {
            scheduler { cancel -> runDelivery(session, record, uriString, flags, cancel) }
        }.getOrDefault(false)
        if (!scheduled) {
            var becameIdle = false
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
                }
                built
            }
            try {
                settlement?.let(settlementSink)
            } finally {
                if (becameIdle) notifySessionsIdle()
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
        synchronized(lock) {
            session.pendingIo -= 1
            if (session.ended && session.pendingIo == 0) {
                sessions.remove(session.sessionToken)
                becameIdle = sessions.isEmpty()
            }
        }
        if (becameIdle) notifySessionsIdle()
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
internal class OfficeSaveCopyHost(context: Context) {

    private val appContext = context.applicationContext
    private val backend = AndroidSafBackend(appContext)
    private val gatewayService = SafGatewayService(backend, releaseBroker = SharedUriGrantAuthority.broker)
    private val stagingRoot = File(appContext.applicationInfo.dataDir, "files/OfficeSaveCopyScratch")
    private val outputsRoot = File(appContext.noBackupFilesDir, "floe-office-outputs")

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
        ownerAlive: () -> Boolean,
    ): Boolean {
        if (!handoff.beginSession(sessionToken, displayName, original, ownerAlive)) return false
        ensureConnected()
        return true
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
