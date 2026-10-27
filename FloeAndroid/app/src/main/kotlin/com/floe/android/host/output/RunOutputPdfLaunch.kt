// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.output

import java.io.File
import java.util.Locale
import java.util.UUID

/**
 * Lane 17: the REAL launch-ownership coordinator for opening one verified
 * durable run-output PDF in the App-owned preview screen. Like the accepted
 * [com.floe.android.core.officeengine.pdf.OfficePdfPrintQuiescence] pattern
 * it deliberately uses NO Android types, so the production object itself is
 * directly unit-testable ([RunOutputPdfLaunchRegistryTest]) — the controller
 * and the preview Activity are thin glue over THESE decisions and never
 * mirror them.
 *
 * Ownership model (Main contract 2026-10-27):
 *  - an Intent carries ONLY the opaque [RunOutputPdfStaged.launchToken] (a
 *    random UUID minted by staging), never a path, digest, MIME or model
 *    text; the viewer resolves it against THIS live registry — an unknown or
 *    restored token (process death) is an honest expiry, and no live launch
 *    ownership is ever reconstructed from Intent bytes;
 *  - every open captures the conversation entry's exact owner facts through
 *    the [ownerCurrent] closure (ordinary conversation identity + session
 *    epoch + native root epoch + App command generation, all checked by the
 *    caller); [claim] and [attachRenderer] re-run that check, so an owner
 *    that retired meanwhile cannot resurrect a launch or start new work;
 *  - the staged immutable snapshot's lifetime joins its REAL owners: renderer
 *    hosts attach/quiesce per screen instance (a rotation re-attaches while
 *    the old host is still draining; neither endangers an admitted print),
 *    and each print attempt counts from admission until the exactly-once
 *    [com.floe.android.core.officeengine.pdf.PrintFinish] terminal —
 *    AdapterFinished AND every StartAborted settle the count. UI close is
 *    NEVER print finish; an admitted dialog keeps the snapshot retained even
 *    after the viewer retired;
 *  - the single admission slot makes a second concurrent preview a typed
 *    refusal (busy), never a silent replacement of live owner state; the slot
 *    frees when the launch closes (user close / owner-expiry) and the
 *    unlink decision is handed out EXACTLY ONCE per snapshot; a launch that
 *    is closed but still draining or still printing RETAINS its file
 *    honestly until the last real owner settles.
 */

/** One proven, App-owned immutable snapshot plus its owned launch facts.
 * `file`/`sessionDirectory` come from the reviewed stager (CREATE_NEW part →
 * fsync → rename → setReadOnly inside this app's own random session dir);
 * `sha256`/`bytes` are the streamed-verified whole-copy facts, and the PDF
 * route additionally proved the `%PDF-` magic + host-MIME agreement before
 * publishing. Identity fields are the exact owned receipt triple. */
internal data class RunOutputPdfStaged(
    val launchToken: String,
    val sessionDirectory: File,
    val file: File,
    val bytes: Long,
    val sha256: String,
    val displayName: String,
    val conversationID: String,
    val runID: String,
    val outputID: String,
)

/** What a viewer's opaque-token claim resolves to. [Expired] is the single
 * honest terminal for unknown/restored tokens AND for an owner that retired
 * (its live record is closed there, becoming unlink-eligible once drained).
 * [StageFailed] carries only a closed failure CODE (never a path); the
 * viewer maps it to path-free copy. */
internal sealed class RunOutputPdfClaim {
    data class Live(val staged: RunOutputPdfStaged) : RunOutputPdfClaim()
    data class StageFailed(val code: String) : RunOutputPdfClaim()
    object Expired : RunOutputPdfClaim()
}

/**
 * The registry behind [RunOutputPdfPreviewController]: one admission slot,
 * live-launch resolution, renderer/print lease joining and exactly-once
 * cleanup decisions. All mutations happen under one lock; every decision is
 * RETURNED to the caller so the Android glue only ACTS on real answers
 * (launch on publish, purge only on a returned staged snapshot, refusal on
 * false/Expired) and can never fabricate progress or unlink early.
 */
internal class RunOutputPdfLaunchRegistry {

    private enum class State { LIVE, STAGE_FAILED, CLOSED }

    private class Launch(
        val token: String,
        val staged: RunOutputPdfStaged?,
        val failureCode: String?,
        val ownerCurrent: () -> Boolean,
        var state: State,
    ) {
        var rendererLeases = 0
        var printOutstanding = 0
        var purgeClaimed = false
    }

    private val lock = Any()

    /** Every reachable launch (live slot + closed records still owed owner
     * settlement). Bounded by construction: at most one live launch plus the
     * closed ones whose snapshots were not yet handed to cleanup. */
    private val records = HashMap<String, Launch>()

    /** The token of the CURRENT live launch the viewer may claim/attach to;
     * one admission slot at a time. */
    private var slotToken: String? = null

    /** Bounded staging ticket for the single IN-FLIGHT stage (the stager's
     * lease window); publish/abandon settles it. */
    private var pendingId = 0L
    private var admissions = 0L

    /** Unlink decisions accumulated by [settleLocked], handed out once via
     * [drainPurges]. */
    private val purgeQueue = ArrayDeque<RunOutputPdfStaged>()

    /** True while the slot or the staging admission is taken. */
    fun slotBusy(): Boolean = synchronized(lock) { slotToken != null || pendingId != 0L }

    /** Reserve the single staging admission; 0 = busy (typed refusal,
     * nothing started, no lease taken). */
    fun admitStaging(): Long = synchronized(lock) {
        if (slotToken != null || pendingId != 0L) 0L
        else (++admissions).also { pendingId = it }
    }

    /** Still the current staging ticket? The stager's isCurrent closure
     * composes this with the caller's owner fence, so an abandoned staging
     * can never publish a snapshot nobody owns. */
    fun pendingActive(id: Long): Boolean = synchronized(lock) { pendingId == id && id != 0L }

    /** Settle an admission that staged nothing (owner retired mid-stage):
     * frees the slot, publishes no launch, keeps nothing. */
    fun abandonStaging(id: Long): Boolean = synchronized(lock) {
        if (pendingId != id) false
        else {
            pendingId = 0L
            true
        }
    }

    /** Publish one proven snapshot as the live launch. Returns false when
     * the ticket is stale or the slot was taken meanwhile: the caller must
     * then purge the just-staged directory itself — this registry never
     * claims a snapshot it did not accept. */
    fun publishLive(id: Long, staged: RunOutputPdfStaged, ownerCurrent: () -> Boolean): Boolean =
        synchronized(lock) {
            if (pendingId != id || slotToken != null) return@synchronized false
            pendingId = 0L
            records[staged.launchToken] =
                Launch(staged.launchToken, staged, null, ownerCurrent, State.LIVE)
            slotToken = staged.launchToken
            true
        }

    /** Publish an honest staging failure for the viewer to surface
     * (path-free code only). Like [publishLive], a stale ticket returns null
     * and the caller starts nothing. */
    fun publishFailed(id: Long, failureCode: String, ownerCurrent: () -> Boolean): String? =
        synchronized(lock) {
            if (pendingId != id || slotToken != null) return@synchronized null
            pendingId = 0L
            val token = UUID.randomUUID().toString()
            records[token] = Launch(token, null, failureCode, ownerCurrent, State.STAGE_FAILED)
            slotToken = token
            token
        }

    /** Resolve a viewer's opaque token. NEVER path/hash authority: only the
     * launch in the live slot answers, and a LIVE record whose owner retired
     * is closed here (honest expiry; its snapshot becomes cleanup-eligible
     * through the same drain the [drainPurges] seam hands out). */
    fun claim(token: String?): RunOutputPdfClaim = synchronized(lock) {
        val t = token ?: return@synchronized RunOutputPdfClaim.Expired
        if (slotToken != t) return@synchronized RunOutputPdfClaim.Expired
        val launch = records[t] ?: return@synchronized RunOutputPdfClaim.Expired
        when (launch.state) {
            State.STAGE_FAILED -> RunOutputPdfClaim.StageFailed(launch.failureCode ?: "source")
            State.CLOSED -> RunOutputPdfClaim.Expired
            State.LIVE -> {
                if (launch.ownerCurrent()) {
                    RunOutputPdfClaim.Live(requireNotNull(launch.staged))
                } else {
                    closeLocked(launch)
                    RunOutputPdfClaim.Expired
                }
            }
        }
    }

    /** Attach one renderer-host lease to the live launch (one screen
     * instance). False = refused (no live launch / owner retired — the
     * record is then closed there); the viewer must not render. */
    fun attachRenderer(token: String): Boolean = synchronized(lock) {
        val launch = slotLaunch(token, State.LIVE) ?: return@synchronized false
        if (!launch.ownerCurrent()) {
            closeLocked(launch)
            return@synchronized false
        }
        launch.rendererLeases++
        true
    }

    /** One attached host finished its quiescent drain (its release join ran
     * after the owned worker settled every descriptor). */
    fun rendererQuiesced(token: String) = synchronized(lock) {
        val launch = records[token] ?: return@synchronized Unit
        if (launch.rendererLeases > 0) launch.rendererLeases--
        settleLocked(launch)
    }

    /** Begin one print attempt (the flow performs the real admission; this
     * is the OWNER lease count). False = refused: the viewer must not start
     * printing against a retired launch and nothing is counted. */
    fun beginPrint(token: String): Boolean = synchronized(lock) {
        val launch = slotLaunch(token, State.LIVE) ?: return@synchronized false
        if (!launch.ownerCurrent()) {
            closeLocked(launch)
            return@synchronized false
        }
        launch.printOutstanding++
        true
    }

    /** The exactly-once [com.floe.android.core.officeengine.pdf.PrintFinish]
     * terminal for one counted attempt arrived (AdapterFinished OR
     * StartAborted). This is the ONLY print-side settlement path; UI close
     * never substitutes for it. */
    fun finishPrint(token: String) = synchronized(lock) {
        val launch = records[token] ?: return@synchronized Unit
        if (launch.printOutstanding > 0) launch.printOutstanding--
        settleLocked(launch)
    }

    /** Explicit user close of the launch screen (back/close — NEVER a
     * configuration-change destroy: rotation does not call this). Frees the
     * slot and evaluates cleanup against the live leases; a still-printing
     * or still-draining launch keeps its file until the last real owner
     * settles via [rendererQuiesced]/[finishPrint], which then run the same
     * cleanup decision for the already-closed record. */
    fun userClose(token: String) = synchronized(lock) {
        val launch = records[token] ?: return@synchronized Unit
        closeLocked(launch)
    }

    /** Hand out the unlink decisions accumulated so far (exactly once per
     * snapshot — the queue is drained atomically with the claim). The
     * controller calls this after EVERY state-changing interaction and only
     * ever purges what this returns: nothing is deleted while a renderer
     * host or an admitted print is outstanding, and a refused/never-claimed
     * launch that expired with zero owners cleans right here. */
    fun drainPurges(): List<RunOutputPdfStaged> = synchronized(lock) {
        if (purgeQueue.isEmpty()) return@synchronized emptyList()
        val taken = purgeQueue.toList()
        purgeQueue.clear()
        taken
    }

    // ------------------------------------------------------------------
    // Internals (all under [lock])
    // ------------------------------------------------------------------

    private fun slotLaunch(token: String, state: State): Launch? =
        if (slotToken != token) null else records[token]?.takeIf { it.state == state }

    private fun closeLocked(launch: Launch) {
        if (launch.state == State.CLOSED) return
        launch.state = State.CLOSED
        if (slotToken == launch.token) slotToken = null
        if (launch.staged == null) {
            // A closed failure screen has no bytes of its own to clean.
            records.remove(launch.token)
            return
        }
        // The record may ALREADY be fully drained (expiry before any render
        // or print attached): run the cleanup decision right here so a
        // never-watched snapshot cannot leak.
        settleLocked(launch)
    }

    /** The single cleanup decision: CLOSED, staged, zero outstanding owners,
     * never already handed out — the snapshot then leaves the registry and
     * waits in [purgeQueue] for exactly one drain. Anything else RETAINS the
     * file honestly (still printing, still draining, still live). */
    private fun settleLocked(launch: Launch): Unit {
        val staged = launch.staged ?: return
        if (launch.state != State.CLOSED) return
        if (launch.rendererLeases != 0 || launch.printOutstanding != 0) return
        if (launch.purgeClaimed) return
        launch.purgeClaimed = true
        records.remove(launch.token)
        purgeQueue.add(staged)
    }
}

/** Shared closed agreement for the run-output PDF Open route: the native
 * verified MIME must MATCH the sealed `.pdf` extension (never either alone). */
internal fun runOutputPdfOpenAgreement(mimeType: String, displayName: String): Boolean =
    mimeType == RunOutputOfficeSnapshotStager.PDF_MIME &&
        displayName.substringAfterLast('.', "").lowercase(Locale.ROOT) ==
        RunOutputOfficeSnapshotStager.FORMAT_PDF
