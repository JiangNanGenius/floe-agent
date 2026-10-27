// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import android.content.Context
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.print.PageRange
import android.print.PrintAttributes
import android.print.PrintDocumentAdapter
import android.print.PrintDocumentInfo
import android.print.PrintManager
import android.system.Os
import android.system.OsConstants
import com.floe.android.core.officeengine.R
import java.io.FileOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Result of a print START attempt. This is deliberately about the SYSTEM
 * PRINT DIALOG only: dialog/scope acceptance is NOT physical printing, and
 * the UI must never say "printed" from job submission (Main contract
 * 2026-10-27; no default cloud upload either — bytes go only to the local
 * print framework).
 */
sealed class PrintStartOutcome {
    object DialogOpened : PrintStartOutcome()

    /** No PrintManager service on this device (honest, path-free). */
    object NoPrintService : PrintStartOutcome()

    /** The owned source FD could not be taken for the session (file vanished/locked/shape refused). */
    object SourceUnavailable : PrintStartOutcome()

    /**
     * The foreground Activity that owns the dialog retired before admission:
     * starting a system dialog through a dead activity is REFUSED (Main
     * repair 2026-10-27); the owned FD closes exactly once and the caller
     * lease settles via [PrintFinish.StartAborted].
     */
    object ActivityRetired : PrintStartOutcome()
}

/**
 * Exactly-once source/lease release identity for the caller (Main repair
 * 2026-10-27; the D04 seam): [OfficePdfPrintFlow.requestPrint] invokes the
 * optional `onFinished` callback EXACTLY ONCE per print attempt —
 *  - [AdapterFinished] once the framework finished the job and the adapter's
 *    own [OfficePdfPrintAdapter.onFinish] released the pinned descriptor, or
 *  - [StartAborted] for every path where the dialog never took ownership
 *    (early page-count/shape refusal, source FD unavailable, no print
 *    service, retired activity, failed admission).
 * Neither identity ever waits on a model/physical-printer condition: the
 * print framework's own onFinish is the release point, and a job the dialog
 * took over keeps the source retained by design (module-retained verified
 * outputs stay immutable; see [OfficePdfVerifiedSource] owner obligations).
 */
sealed class PrintFinish {
    /** The real adapter.onFinish ran and the owned descriptor closed exactly once. */
    object AdapterFinished : PrintFinish()

    /** The dialog never started; the given outcome names why. Release settled at the refusal. */
    data class StartAborted(val outcome: PrintStartOutcome) : PrintFinish()
}

/**
 * Pure admission rules for the print flow (unit-tested without any Android
 * types; the real flow calls exactly these functions).
 */
object OfficePdfPrintAdmission {

    /**
     * BEFORE any dialog machinery: the page count must be a real renderer
     * count within the contract bound and the source must pass the shape
     * guard. Any refusal is [PrintStartOutcome.SourceUnavailable] — nothing
     * was opened, nobody may claim a print job.
     */
    fun prepare(pageCountOk: Boolean, sourceShapeOk: Boolean): PrintStartOutcome? = when {
        !pageCountOk || !sourceShapeOk -> PrintStartOutcome.SourceUnavailable
        else -> null
    }

    /**
     * On the MAIN thread, immediately before `PrintManager.print`: the
     * dialog belongs to the foreground activity; if that activity is
     * finishing/destroyed the attempt is REFUSED as
     * [PrintStartOutcome.ActivityRetired] rather than starting a dialog
     * through a retired context.
     */
    fun admitOnMain(activityAlive: Boolean): PrintStartOutcome? =
        if (!activityAlive) PrintStartOutcome.ActivityRetired else null
}

/**
 * Print adapter over ONE already-verified PDF source
 * ([OfficePdfVerifiedSource]: on the Office path produced by
 * [OfficePdfReceiptPolicy] after the exact owned OUTPUT_READY receipt; a
 * sealed run-output consumer may hand its own verified source through the
 * same adapter — one print path, one honesty contract).
 *
 * Semantics (official PrintDocumentAdapter contract + the AOSP
 * `PrintFileDocumentAdapter` reference, with its flaws corrected):
 *  - the adapter opens its OWN read-only NO-FOLLOW descriptor ONCE
 *    (constructor, off the main thread via [OfficePdfPrintFlow]) through the
 *    REAL public SDK surface ([OfficePdfSourceAccess]:
 *    `Os.open(O_RDONLY|O_CLOEXEC|O_NOFOLLOW)` + public
 *    `ParcelFileDescriptor.dup(FileDescriptor)` adoption + exact raw-FD
 *    close + `Os.fstat`/`S_ISREG` plain-regular proof — the previously
 *    referenced `MODE_RDONLY`/`MODE_NOFOLLOW`/`fileStatus` members DO NOT
 *    exist on the platform), and every layout/write identity reads through
 *    dup + `lseek` of THAT descriptor —
 *    the path is never re-opened as document authority, so a replaced path
 *    entry can never print under the old verified identity, while an
 *    in-place rewrite of the pinned inode is honestly refused by the
 *    whole-copy proof below ([OfficePdfPinnedSourceCopier]: exact length,
 *    whole-copy SHA-256 of the ACTUAL copied bytes and a clean EOF are all
 *    verified BEFORE any finish terminal may fire);
 *  - all methods arrive on the main thread; ALL real work (identity checks,
 *    byte copies) runs on a private single worker, callbacks are posted back
 *    to main — no AsyncTask, no blocking of layout callers; every worker
 *    pass starts at offset 0 (serialized + explicit lseek of this pass's own
 *    dup), so repeated [onWrite] calls can never continue each other's
 *    offsets;
 *  - every [onLayout] and every [onWrite] resolves exactly ONE terminal
 *    callback via [OfficePdfOnceCallback] — the reference class'
 *    double-callback (IOException failure + onPostExecute finish) is NOT
 *    copied. Cancellation settles with the platform `onWriteCancelled` /
 *    `onLayoutCancelled`, NEVER `onWriteFailed` (Main repair 2026-10-27);
 *  - a job whose pass could not run (worker rejection after shutdown) or
 *    whose cancellation signal was already cancelled settles through the
 *    same gate with the CORRECT terminal — no silent catch ever leaves a
 *    callback unresolved;
 *  - onWrite preserves the vector bytes: the COMPLETE verified PDF is copied
 *    unchanged to the destination (no rasterisation), and the reported
 *    written range is honestly PageRange.ALL_PAGES because the written data
 *    IS the full document (page subsetting is the print service's job, same
 *    platform behaviour as the AOSP file adapter — we never CLAIM an
 *    unimplemented subset);
 *  - [onFinish] RETIRES the session first (fence: late/queued passes settle
 *    CANCELLED through their gates, never a false finish), then closes the
 *    owned descriptor and fires the caller's release hook ONLY AFTER real
 *    I/O quiescence — the release is serialized on the same worker that ran
 *    every pass, after each has closed its own dup + destination stream in
 *    its `finally` ([OfficePdfPrintQuiescence]); the main thread never
 *    blocks joining I/O, the release fires exactly once, and a session with
 *    unsettled I/O RETAINS the owner honestly instead of faking a close.
 *    Already-verified source files are never deleted or rewritten by
 *    anything here.
 */
class OfficePdfPrintAdapter(
    private val source: OfficePdfVerifiedSource,
    private val documentLabel: String,
    private val pageCount: Int,
    context: Context,
    private val onSourceRelease: (() -> Unit)? = null,
) : PrintDocumentAdapter() {

    private val main = Handler(Looper.getMainLooper())
    private val printIo = Executors.newSingleThreadExecutor { r ->
        Thread(r, "floe-pdf-print").apply { isDaemon = true }
    }

    /**
     * The session's REAL lifetime coordinator (Main lane 14 repair): the
     * finish fence plus a serialized, exactly-once release that runs ON
     * [printIo] AFTER every already-queued pass closed its own dup and
     * destination stream. All adapter passes enter the worker through it.
     */
    private val quiescence = OfficePdfPrintQuiescence(submitFinalizer = printIo::execute)

    // Path-free, LOCALISED reasons (bilingual contract): the adapter is
    // constructed from an Activity context; reasons surface only inside the
    // system print dialog if a service shows them. onWriteCancelled/onLayout-
    // Cancelled take NO reason on the platform, so the cancelled string is
    // intentionally not referenced here.
    private val reasonGone: CharSequence =
        context.applicationContext.getString(R.string.office_print_reason_gone)
    private val reasonWriteFailed: CharSequence =
        context.applicationContext.getString(R.string.office_print_reason_write)

    /** Owned for the whole job; opened ONCE by the flow BEFORE the dialog starts. */
    @Volatile
    private var ownedFd: ParcelFileDescriptor?
    private val fdClosed = AtomicBoolean(false)

    init {
        // Plain regular, read-only, NO-FOLLOW descriptor over the owner-
        // verified file, through the REAL public SDK open path
        // ([OfficePdfSourceAccess]: Os.open O_RDONLY|O_CLOEXEC|O_NOFOLLOW +
        // dup adoption + raw-FD close + Os.fstat/S_ISREG under the
        // descriptor); from here on NOTHING re-opens the path.
        ownedFd = if (OfficePdfVerifiedSourceContract.shapeOk(source)) {
            OfficePdfSourceAccess.openPinnedReadOnly(source.readableFile, source.expectedBytes)
        } else {
            null
        }
        if (ownedFd != null && !pinnedIdentityOk()) {
            // Not a regular file / length differs / no %PDF- magic UNDER the
            // pinned descriptor: refuse the whole session honestly.
            runCatching { ownedFd?.close() }
            ownedFd = null
        }
    }

    /**
     * Source identity for the whole job. The adapter intentionally KEEPS
     * serving layout/write until the print framework's single [onFinish]:
     * once the system dialog accepted the job, the job belongs to the
     * framework (the owning menu Activity finishing must not sabotage an
     * in-flight dialog), and the owned FD + module-retained file guarantee
     * the bytes stay available. There is NO other termination path: onFinish
     * retires the session and closes the FD exactly once, only AFTER the
     * owned worker has drained every pass to real I/O quiescence — never
     * while a pass may still read or write.
     */
    fun sourceUnavailable(): Boolean = ownedFd == null

    override fun onLayout(
        oldAttributes: PrintAttributes?,
        newAttributes: PrintAttributes,
        cancellationSignal: CancellationSignal,
        callback: LayoutResultCallback,
        metadata: android.os.Bundle?,
    ) {
        val gate = OfficePdfOnceCallback("layout")
        if (quiescence.retired()) {
            // Session already finished (post-onFinish straggler): the only
            // honest terminal is CANCELLED, exactly once through the gate.
            gate.fire(OfficePdfOnceCallback.Terminal.CANCELLED) {
                main.post { callback.onLayoutCancelled() }
            }
            return
        }
        registerCancellation(cancellationSignal, gate, cancelSink = { callback.onLayoutCancelled() })
        try {
            printIo.execute {
                // Production entry (lane 14): queued-then-retired passes
                // settle CANCELLED — a late pass can NEVER emit a false
                // finish after the session retired.
                quiescence.runOrSettleCancel(
                    gate,
                    work = {
                        if (!pinnedIdentityOk()) {
                            gate.fire(OfficePdfOnceCallback.Terminal.FAILED) {
                                main.post { callback.onLayoutFailed(reasonGone) }
                            }
                        } else {
                            val info = PrintDocumentInfo.Builder(documentLabel)
                                .setPageCount(pageCount)
                                .setContentType(PrintDocumentInfo.CONTENT_TYPE_DOCUMENT)
                                .build()
                            // Static vector document: layout content NEVER
                            // changes between attribute updates, so
                            // `contentChanged=false` keeps the framework
                            // from needless re-writes (official caching
                            // guidance).
                            gate.fire(OfficePdfOnceCallback.Terminal.FINISHED) {
                                main.post { callback.onLayoutFinished(info, false) }
                            }
                        }
                    },
                    settleCancelled = { main.post { callback.onLayoutCancelled() } },
                )
            }
        } catch (e: RejectedExecutionException) {
            // Worker gone (post-onFinish straggler that raced the shutdown):
            // resolve the callback with ONE real terminal — cancelled once
            // the session retired, failed otherwise — never leave the
            // framework hanging on an un-settled request.
            if (quiescence.retired()) {
                gate.fire(OfficePdfOnceCallback.Terminal.CANCELLED) {
                    main.post { callback.onLayoutCancelled() }
                }
            } else {
                gate.fire(OfficePdfOnceCallback.Terminal.FAILED) {
                    main.post { callback.onLayoutFailed(reasonWriteFailed) }
                }
            }
        }
    }

    override fun onWrite(
        pages: Array<out PageRange>?,
        destination: ParcelFileDescriptor,
        cancellationSignal: CancellationSignal,
        callback: WriteResultCallback,
    ) {
        val gate = OfficePdfOnceCallback("write")
        val canceled = AtomicBoolean(false)
        if (quiescence.retired()) {
            // Session already finished: settle this straggler request CANCELLED
            // exactly once; no copy may start after retirement.
            gate.fire(OfficePdfOnceCallback.Terminal.CANCELLED) {
                main.post { callback.onWriteCancelled() }
            }
            return
        }
        registerCancellation(cancellationSignal, gate, canceled, cancelSink = { callback.onWriteCancelled() })
        try {
            printIo.execute {
                // Production entry (lane 14): a pass queued before the
                // finish but running after retirement settles CANCELLED via
                // the gate — never a false finish, never a double terminal.
                quiescence.runOrSettleCancel(
                    gate,
                    work = { runWritePass(destination, callback, canceled, gate) },
                    settleCancelled = { main.post { callback.onWriteCancelled() } },
                )
            }
        } catch (e: RejectedExecutionException) {
            if (quiescence.retired()) {
                gate.fire(OfficePdfOnceCallback.Terminal.CANCELLED) {
                    main.post { callback.onWriteCancelled() }
                }
            } else {
                gate.fire(OfficePdfOnceCallback.Terminal.FAILED) {
                    main.post { callback.onWriteFailed(reasonWriteFailed) }
                }
            }
        }
    }

    /**
     * One bounded, digest-verified copy pass THROUGH THE PINNED DESCRIPTOR
     * (dup + lseek 0 of [ownedFd]; never a path re-open). The success
     * terminal may only fire after [OfficePdfPinnedSourceCopier] proves
     * exact length + whole-copy SHA-256 + clean EOF of the bytes the
     * destination actually received.
     */
    private fun runWritePass(
        destination: ParcelFileDescriptor,
        callback: WriteResultCallback,
        canceled: AtomicBoolean,
        gate: OfficePdfOnceCallback,
    ) {
        val access = dupOwned()
        if (access == null) {
            if (gate.pending()) {
                gate.fire(OfficePdfOnceCallback.Terminal.FAILED) {
                    main.post { callback.onWriteFailed(reasonGone) }
                }
            }
            return
        }
        var outcome: OfficePdfPinnedSourceCopier.CopiedOutcome =
            OfficePdfPinnedSourceCopier.CopiedOutcome.DestinationWriteFailed
        var out: FileOutputStream? = null
        try {
            val dest = FileOutputStream(destination.fileDescriptor)
            out = dest
            outcome = OfficePdfPinnedSourceCopier.copyVerify(
                read = object : OfficePdfPinnedRead {
                    override fun seekToStart(): Boolean = try {
                        Os.lseek(access.fileDescriptor, 0, OsConstants.SEEK_SET)
                        true
                    } catch (e: Exception) {
                        false
                    }

                    override fun read(buf: ByteArray, off: Int, len: Int): Int = try {
                        Os.read(access.fileDescriptor, buf, off, len)
                    } catch (e: Exception) {
                        throw OfficePdfPinnedSourceCopier.DescriptorReadFault("pinned read", e)
                    }
                },
                write = object : OfficePdfPinnedWrite {
                    override fun write(buf: ByteArray, off: Int, len: Int) = try {
                        dest.write(buf, off, len)
                    } catch (e: Exception) {
                        throw OfficePdfPinnedSourceCopier.DestinationWriteFault("destination write", e)
                    }

                    override fun finish() = try {
                        dest.flush()
                    } catch (e: Exception) {
                        throw OfficePdfPinnedSourceCopier.DestinationWriteFault("destination flush", e)
                    }
                },
                expectedBytes = source.expectedBytes,
                expectedSha256Hex = source.expectedSha256,
                isCancelled = { canceled.get() || !gate.pending() },
            )
        } catch (e: Exception) {
            // Only destination-stream CONSTRUCTION can reach here (copyVerify
            // itself never throws): an un-writable destination is honestly a
            // write fault, never a claim about the source.
            outcome = OfficePdfPinnedSourceCopier.CopiedOutcome.DestinationWriteFailed
        } finally {
            runCatching { out?.close() }
            runCatching { access.close() } // this pass's dup, closed exactly once
        }
        when (OfficePdfPinnedSourceCopier.terminalFor(outcome)) {
            OfficePdfPinnedSourceCopier.PrintTerminalKind.FINISH ->
                gate.fire(OfficePdfOnceCallback.Terminal.FINISHED) {
                    // Written data is the COMPLETE verified document and it
                    // hashed to the frozen identity: honestly report ALL_PAGES
                    // (the AOSP file-adapter behaviour); we never rasterise or
                    // claim a subset we did not produce.
                    main.post { callback.onWriteFinished(arrayOf(PageRange.ALL_PAGES)) }
                }

            OfficePdfPinnedSourceCopier.PrintTerminalKind.CANCEL ->
                // Correct platform terminal: cancellation is NOT a failure
                // (Main repair 2026-10-27 — the delivered slice called
                // onWriteFailed here; the platform contract is onWriteCancelled).
                gate.fire(OfficePdfOnceCallback.Terminal.CANCELLED) {
                    main.post { callback.onWriteCancelled() }
                }

            OfficePdfPinnedSourceCopier.PrintTerminalKind.FAIL -> {
                val reason =
                    if (OfficePdfPinnedSourceCopier.isSourceIdentityFailure(outcome)) reasonGone else reasonWriteFailed
                gate.fire(OfficePdfOnceCallback.Terminal.FAILED) {
                    main.post { callback.onWriteFailed(reason) }
                }
            }
        }
        // If the gate was already fired (cancellation listener won the
        // race), every fire() above returned false and posted nothing:
        // exactly-one-terminal holds for the whole request.
    }

    override fun onFinish() {
        // Exactly-once ownership release for the whole job, ONLY after real
        // I/O quiescence (Main lane 14 repair). The coordinator first
        // RETIRES the session — fencing future work and settling any
        // already-queued pass CANCELLED through its own gate instead of a
        // false finish — and then serializes this release as the LAST task
        // on the same worker that ran every pass: each pass closes its OWN
        // dup + destination stream in its `finally`, so by the time this
        // task runs all pass I/O has physically settled. The caller thread
        // (framework main) never blocks joining the worker; if a pass can
        // never settle, the owner is honestly RETAINED here, never a fake
        // close. [OfficePdfPrintQuiescence] guarantees the release runs at
        // most once per session even if the framework (or the flow's
        // non-admitted fallback) calls finish more than once.
        quiescence.finish {
            // Runs on the floe-pdf-print worker AFTER every queued pass has
            // completed its own cleanup: close the BASE descriptor exactly
            // once, then fire the caller lease seam.
            if (fdClosed.compareAndSet(false, true)) {
                runCatching { ownedFd?.close() }
                ownedFd = null
                // Caller lease seam: the flow's finish gate ignores a duplicate
                // (early-abort paths settle StartAborted first).
                runCatching { onSourceRelease?.invoke() }
            }
        }
        // No new submissions after retirement; queued work (if any) still
        // drains on the worker before the serialized release above.
        runCatching { printIo.shutdown() }
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /**
     * Fresh dup of the pinned descriptor for one pass; null once the session
     * is retired or released — a pass starting after the finish fence can no
     * longer read through the base descriptor (it settles CANCELLED).
     */
    private fun dupOwned(): ParcelFileDescriptor? {
        val base = ownedFd ?: return null
        if (fdClosed.get() || quiescence.retired()) return null
        return try {
            base.dup()
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Cheap pinned identity: plain regular file + exact length via
     * `Os.fstat`/`S_ISREG` UNDER the OWNED descriptor
     * ([OfficePdfSourceAccess.plainRegularUnder] — the real public API;
     * `ParcelFileDescriptor.fileStatus` referenced before does not exist),
     * and the `%PDF-` magic read through the pinned descriptor (this pass's
     * own dup + lseek 0). This NEVER opens a path and NEVER claims more than
     * shape + magic — the full SHA proof of the actual printed bytes runs
     * inside every [onWrite] pass before its finish terminal.
     */
    private fun pinnedIdentityOk(): Boolean {
        val base = ownedFd ?: return false
        if (fdClosed.get() || quiescence.retired()) return false
        if (!OfficePdfSourceAccess.plainRegularUnder(base, source.expectedBytes)) return false
        val access = dupOwned() ?: return false
        try {
            val seeked = try {
                Os.lseek(access.fileDescriptor, 0, OsConstants.SEEK_SET)
                true
            } catch (e: Exception) {
                false
            }
            if (!seeked) return false
            val head = ByteArray(5)
            var got = 0
            while (got < 5) {
                val r = try {
                    Os.read(access.fileDescriptor, head, got, 5 - got)
                } catch (e: Exception) {
                    -1
                }
                if (r <= 0) break
                got += r
            }
            return got == 5 && OfficePdfPinnedSourceCopier.headMagicOk(head)
        } finally {
            runCatching { access.close() }
        }
    }

    /**
     * Registers the platform cancellation listener: a cancel settles the
     * request's gate with the CANCELLED terminal and posts the correct
     * `onXxxCancelled` callback exactly once. If the signal is ALREADY
     * cancelled (setOnCancelListener throws), the request settles cancelled
     * right here — no silent catch leaves a callback unresolved.
     */
    private fun registerCancellation(
        signal: CancellationSignal,
        gate: OfficePdfOnceCallback,
        canceled: AtomicBoolean? = null,
        cancelSink: () -> Unit,
    ) {
        fun settleCancel() {
            canceled?.set(true)
            gate.fire(OfficePdfOnceCallback.Terminal.CANCELLED) { main.post(cancelSink) }
        }
        try {
            signal.setOnCancelListener { settleCancel() }
        } catch (e: IllegalStateException) {
            settleCancel()
        }
    }
}

/**
 * Starts one print over a verified source. Page count comes from the
 * RENDERER itself ([OfficePdfRenderHost.documentInfo]) before the dialog
 * opens — the adapter never reports a guessed count.
 *
 * Threading/lifetime (Main repair 2026-10-27):
 *  - shape/page-count refusal runs up front; the owned-FD open + pinned
 *    identity check run OFF the main thread (adapter construction);
 *  - the ACTUAL `PrintManager.print` admission runs on the MAIN thread
 *    against the foreground activity passed as [context], guarded by a
 *    liveness check: a retired activity REFUSES to open the dialog
 *    ([PrintStartOutcome.ActivityRetired]) rather than leaking a dialog
 *    through a dead context;
 *  - `DialogOpened` means the SYSTEM DIALOG ADMITTED the job — never that
 *    anything was physically printed; nothing here waits for, or claims, a
 *    spooler/printer outcome;
 *  - [onFinished] settles EXACTLY ONCE per attempt for every path (see
 *    [PrintFinish]), which lets a durable consumer (D04) hold one lease
 *    from source validation until the real adapter `onFinish` and release
 *    it once — even on early page-count/no-service/unavailable/start
 *    failures and even when the owner UI retired;
 *  - no activity-destroy auto-cancel: once admitted, the job belongs to the
 *    framework ([OfficePdfPrintAdapter.onFinish] is the single release
 *    point); every NON-admitted path settles its honest abort identity at
 *    the refusal, and the same exactly-once finish path releases the owned
 *    FD only AFTER the adapter's I/O worker has quiesced (the fallback
 *    finish fences the session and serializes the close behind any work
 *    already submitted — no main-thread join, no double release).
 */
object OfficePdfPrintFlow {

    /**
     * Backwards-compatible signature: existing module callers pass the
     * trailing `onResult` lambda and no [onFinished]; the D04 consumer
     * passes [onFinished] to join its lease to the exactly-once release.
     */
    fun requestPrint(
        context: Context,
        source: OfficePdfVerifiedSource,
        pageCount: Int,
        documentLabel: String,
        onFinished: ((PrintFinish) -> Unit)? = null,
        onResult: (PrintStartOutcome) -> Unit,
    ) {
        val main = Handler(Looper.getMainLooper())
        val finishGate = OfficePdfOnceCallback("print-finish")
        fun settle(finish: PrintFinish) {
            finishGate.fire(OfficePdfOnceCallback.Terminal.FINISHED) {
                main.post { runCatching { onFinished?.invoke(finish) } }
            }
        }
        val prepare = OfficePdfPrintAdmission.prepare(
            pageCountOk = pageCount in 1..OfficePdfRendererContract.MAX_PAGE_INDEX,
            sourceShapeOk = OfficePdfVerifiedSourceContract.shapeOk(source),
        )
        if (prepare != null) {
            settle(PrintFinish.StartAborted(prepare))
            main.post { onResult(prepare) }
            return
        }
        val io = Executors.newSingleThreadExecutor { r ->
            Thread(r, "floe-pdf-print-start").apply { isDaemon = true }
        }
        io.execute {
            val manager = try {
                context.getSystemService(Context.PRINT_SERVICE) as? PrintManager
            } catch (e: Exception) {
                null
            }
            val adapter = OfficePdfPrintAdapter(
                source,
                documentLabel,
                pageCount,
                context,
                onSourceRelease = { settle(PrintFinish.AdapterFinished) },
            )
            if (adapter.sourceUnavailable()) {
                settle(PrintFinish.StartAborted(PrintStartOutcome.SourceUnavailable))
                runCatching { adapter.onFinish() } // fence + quiescent close; abort identity already settled
                main.post { onResult(PrintStartOutcome.SourceUnavailable) }
                io.shutdown()
                return@execute
            }
            if (manager == null) {
                settle(PrintFinish.StartAborted(PrintStartOutcome.NoPrintService))
                runCatching { adapter.onFinish() }
                main.post { onResult(PrintStartOutcome.NoPrintService) }
                io.shutdown()
                return@execute
            }
            // Real admission happens on MAIN with the activity-liveness fence.
            main.post {
                val retired = context is android.app.Activity && (context.isFinishing || context.isDestroyed)
                val refusal = OfficePdfPrintAdmission.admitOnMain(activityAlive = !retired)
                if (refusal != null) {
                    settle(PrintFinish.StartAborted(refusal))
                    runCatching { adapter.onFinish() }
                    onResult(refusal)
                    return@post
                }
                val outcome = try {
                    manager.print(
                        documentLabel,
                        adapter,
                        PrintAttributes.Builder().build(),
                    )
                    PrintStartOutcome.DialogOpened
                } catch (e: Exception) {
                    // Honest failure: dialog never accepted the job. Release
                    // the FD the adapter owned (exactly-once via the same
                    // onFinish path the framework did not reach).
                    settle(PrintFinish.StartAborted(PrintStartOutcome.NoPrintService))
                    runCatching { adapter.onFinish() }
                    PrintStartOutcome.NoPrintService
                }
                onResult(outcome)
            }
            io.shutdown()
        }
    }
}
