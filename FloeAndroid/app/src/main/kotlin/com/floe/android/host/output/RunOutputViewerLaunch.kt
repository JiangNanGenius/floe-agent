// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.output

import java.io.File
import java.util.UUID

/**
 * The owned text/markdown + media OPEN lane: the REAL launch-ownership
 * coordinator for opening one verified durable run-output of a viewer-
 * supported kind (plain text/Markdown source, PNG/JPEG/WebP/GIF, WAV/MP3/
 * M4A/OGG audio, MP4/WebM/3GPP video) in the App-owned full-screen viewer.
 *
 * It deliberately uses NO Android types (same discipline as
 * [RunOutputPdfLaunchRegistry]), so the production object itself is directly
 * unit-testable; the preview controller and Activity are thin glue over
 * THESE decisions.
 *
 * Ownership model (mirrors the reviewed PDF lane 1:1):
 *  - an Intent carries ONLY the opaque [RunOutputViewerStaged.launchToken]
 *    (a random UUID minted by staging), never a path, digest, MIME or model
 *    text; the viewer resolves it against THIS live registry — an unknown or
 *    restored token (process death) is an honest expiry, and no live launch
 *    ownership is ever reconstructed from Intent bytes;
 *  - every open captures the conversation entry's exact owner facts through
 *    the [ownerCurrent] closure (ordinary conversation identity + session
 *    epoch + native root epoch + App command generation, all checked by the
 *    caller); [claim] and [attachViewer] re-run that check, so an owner that
 *    retired meanwhile cannot resurrect a launch;
 *  - the staged immutable snapshot's lifetime joins its REAL owners: the
 *    viewer screen attaches one lease on claim and releases it after its
 *    content really settled (text decoded / playback released); cleanup is
 *    decided exactly once per snapshot and a launch that closed while still
 *    held RETAINS its file honestly until the last real owner settles;
 *  - the single admission slot makes a second concurrent preview a typed
 *    refusal (busy), never a silent replacement of live owner state.
 */

/** One proven, App-owned immutable snapshot plus its owned launch facts.
 * `file`/`sessionDirectory` come from the reviewed stager (CREATE_NEW part →
 * fsync → rename → setReadOnly inside this app's own random session dir);
 * `sha256`/`bytes` are the streamed-verified whole-copy facts; `mimeType` is
 * the native-sealed receipt MIME the staging lane re-validated. Identity
 * fields are the exact owned receipt triple. */
internal data class RunOutputViewerStaged(
    val launchToken: String,
    val sessionDirectory: File,
    val file: File,
    val bytes: Long,
    val sha256: String,
    val displayName: String,
    val mimeType: String,
    val conversationID: String,
    val runID: String,
    val outputID: String,
)

/** What a viewer's opaque-token claim resolves to. [Expired] is the single
 * honest terminal for unknown/restored tokens AND for an owner that retired
 * (its live record is closed there, becoming unlink-eligible once drained).
 * [StageFailed] carries only a closed failure CODE (never a path). */
internal sealed class RunOutputViewerClaim {
    data class Live(val staged: RunOutputViewerStaged) : RunOutputViewerClaim()
    data class StageFailed(val code: String) : RunOutputViewerClaim()
    object Expired : RunOutputViewerClaim()
}

/**
 * The registry behind [RunOutputViewerPreviewController]: one admission
 * slot, live-launch resolution, viewer-lease joining and exactly-once
 * cleanup decisions. All mutations happen under one lock; every decision is
 * RETURNED to the caller so the Android glue only ACTS on real answers.
 */
internal class RunOutputViewerLaunchRegistry {

    private enum class State { LIVE, STAGE_FAILED, CLOSED }

    private class Launch(
        val token: String,
        val staged: RunOutputViewerStaged?,
        val failureCode: String?,
        val ownerCurrent: () -> Boolean,
        var state: State,
    ) {
        var viewerLeases = 0
        var purgeClaimed = false
    }

    private val lock = Any()

    /** Every reachable launch (live slot + closed records still owed owner
     * settlement). Bounded by construction. */
    private val records = HashMap<String, Launch>()

    /** The token of the CURRENT live launch the viewer may claim/attach to;
     * one admission slot at a time. */
    private var slotToken: String? = null

    /** Bounded staging ticket for the single IN-FLIGHT stage. */
    private var pendingId = 0L
    private var admissions = 0L

    /** Unlink decisions accumulated by [settleLocked], handed out once via
     * [drainPurges]. */
    private val purgeQueue = ArrayDeque<RunOutputViewerStaged>()

    /** True while the slot or the staging admission is taken. */
    fun slotBusy(): Boolean = synchronized(lock) { slotToken != null || pendingId != 0L }

    /** Reserve the single staging admission; 0 = busy (typed refusal,
     * nothing started, no lease taken). */
    fun admitStaging(): Long = synchronized(lock) {
        if (slotToken != null || pendingId != 0L) 0L
        else (++admissions).also { pendingId = it }
    }

    /** Still the current staging ticket? The stager's isCurrent closure
     * composes this with the caller's owner fence. */
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
    fun publishLive(id: Long, staged: RunOutputViewerStaged,
                    ownerCurrent: () -> Boolean): Boolean =
        synchronized(lock) {
            if (pendingId != id || slotToken != null) return@synchronized false
            pendingId = 0L
            records[staged.launchToken] =
                Launch(staged.launchToken, staged, null, ownerCurrent, State.LIVE)
            slotToken = staged.launchToken
            true
        }

    /** Publish an honest staging failure for the viewer to surface
     * (path-free code only). A stale ticket returns null and the caller
     * starts nothing. */
    fun publishFailed(id: Long, failureCode: String,
                      ownerCurrent: () -> Boolean): String? =
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
     * through the same drain [drainPurges] hands out). */
    fun claim(token: String?): RunOutputViewerClaim = synchronized(lock) {
        val t = token ?: return@synchronized RunOutputViewerClaim.Expired
        if (slotToken != t) return@synchronized RunOutputViewerClaim.Expired
        val launch = records[t] ?: return@synchronized RunOutputViewerClaim.Expired
        when (launch.state) {
            State.STAGE_FAILED ->
                RunOutputViewerClaim.StageFailed(launch.failureCode ?: "source")
            State.CLOSED -> RunOutputViewerClaim.Expired
            State.LIVE -> {
                if (launch.ownerCurrent()) {
                    RunOutputViewerClaim.Live(requireNotNull(launch.staged))
                } else {
                    closeLocked(launch)
                    RunOutputViewerClaim.Expired
                }
            }
        }
    }

    /** Attach one viewer lease to the live launch (one screen instance).
     * False = refused (no live launch / owner retired — the record is then
     * closed there); the viewer must not show content. */
    fun attachViewer(token: String): Boolean = synchronized(lock) {
        val launch = slotLaunch(token, State.LIVE) ?: return@synchronized false
        if (!launch.ownerCurrent()) {
            closeLocked(launch)
            return@synchronized false
        }
        launch.viewerLeases++
        true
    }

    /** One attached screen finished its real settlement (text decoded and
     * shown / media player released). */
    fun viewerQuiesced(token: String) = synchronized(lock) {
        val launch = records[token] ?: return@synchronized Unit
        if (launch.viewerLeases > 0) launch.viewerLeases--
        settleLocked(launch)
    }

    /** Explicit user close of the viewer (back/close — NEVER a
     * configuration-change destroy: rotation is handled by configChanges).
     * Frees the slot and evaluates cleanup against the live leases; a
     * still-held launch keeps its file until [viewerQuiesced] settles. */
    fun userClose(token: String) = synchronized(lock) {
        val launch = records[token] ?: return@synchronized Unit
        closeLocked(launch)
    }

    /** Hand out the unlink decisions accumulated so far (exactly once per
     * snapshot). The controller calls this after EVERY state-changing
     * interaction and only ever purges what this returns. */
    fun drainPurges(): List<RunOutputViewerStaged> = synchronized(lock) {
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
            records.remove(launch.token)
            return
        }
        settleLocked(launch)
    }

    /** The single cleanup decision: CLOSED, staged, zero outstanding owners,
     * never already handed out — the snapshot then leaves the registry and
     * waits in [purgeQueue] for exactly one drain. Anything else RETAINS the
     * file honestly. */
    private fun settleLocked(launch: Launch) {
        val staged = launch.staged ?: return
        if (launch.state != State.CLOSED) return
        if (launch.viewerLeases != 0) return
        if (launch.purgeClaimed) return
        launch.purgeClaimed = true
        records.remove(launch.token)
        purgeQueue.add(staged)
    }
}
