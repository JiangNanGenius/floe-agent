// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.output

import android.content.Context
import android.content.Intent
import com.floe.android.core.officeengine.pdf.OfficePdfVerifiedSource
import java.io.File
import java.nio.file.Files
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Main-process, Application-owned PDF OPEN consumer for durable run outputs
 * (lane 17; created by [com.floe.android.FloeApplication] in the ordinary
 * main process only — the isolated PDF process and the Office process return
 * from Application.onCreate long before this exists).
 *
 * Chain (the real registered route, source-ready for the batch):
 *  1. the conversation card's Open re-enters native by the EXACT owned
 *     (conversation, run, output) triple only;
 *  2. the reviewed [RunOutputOfficeSnapshotStager] streams the sealed bytes
 *     through the EXISTING egress — native re-derives the durable receipt,
 *     holds the generation lease, and this App proves the stream (exact
 *     length + whole-copy SHA + clean EOF + `%PDF-` magic + host-MIME
 *     agreement) into a SEPARATE App-owned immutable snapshot root
 *     (`files/RunOutputPdfPreview`, disjoint from every Office input/working
 *     root) before any UI opens;
 *  3. the launch is published into the REAL ownership coordinator
 *     ([RunOutputPdfLaunchRegistry]) and the non-exported
 *     [RunOutputPdfPreviewActivity] is started with NOTHING but the opaque
 *     random launch token — never a path, digest, MIME or model text;
 *  4. the viewer resolves the token against the live record (re-running the
 *     captured owner fence), renders through the SAME isolated
 *     [com.floe.android.core.officeengine.pdf.OfficePdfRenderHost] (no
 *     second renderer) and prints through the accepted
 *     [com.floe.android.core.officeengine.pdf.OfficePdfPrintFlow];
 *  5. the snapshot outlives the egress lease (proven copy may outlive the
 *     source) but never its OWN live owners: unlink happens ONLY through the
 *     coordinator's exactly-once cleanup decision after explicit close AND
 *     renderer quiescence AND the exactly-once print finish of every
 *     admitted attempt.
 *
 * It grants no new permission, reads no arbitrary path, and never launches
 * external apps: a run-output PDF opens INSIDE Floe or refuses honestly.
 */
internal class RunOutputPdfPreviewController(
    context: Context,
    private val scope: CoroutineScope,
) {
    private val appContext = context.applicationContext
    private val pdfRoot = File(appContext.applicationInfo.dataDir, "files/RunOutputPdfPreview")
    private val stager = RunOutputOfficeSnapshotStager(
        pdfRoot, NativeRunOutputChannel, RunOutputOfficeSnapshotStager.PDF_FORMAT_EXTENSIONS,
    )
    /** The production ownership coordinator (pure-JVM, directly tested):
     * every decision below delegates to it — this class only performs the
     * Android actions the coordinator's answers authorize. */
    private val registry = RunOutputPdfLaunchRegistry()

    /** Typed busy refusal BEFORE any staging starts (single admission slot;
     * mirrors the Office controller's click-time isBusy check). */
    fun hasActiveLaunch(): Boolean = registry.slotBusy()

    /**
     * Start one verified PDF open. [owner] carries the exact captured
     * conversation/run/output + live native epoch + App command generation;
     * [ownerCurrent] re-checks the ORDINARY conversation entry (never
     * temporary chat, never a foreign run) through staging AND claim. True
     * means the host STARTED the verified pipeline (the viewer will open
     * with either the proven snapshot or its honest failure); false is a
     * typed refusal that started nothing.
     */
    fun openRunOutputPdf(
        owner: RunOutputOfficeSnapshotStager.Owner,
        ownerCurrent: () -> Boolean,
    ): Boolean {
        val pending = registry.admitStaging()
        if (pending == 0L) return false
        scope.launch(Dispatchers.IO) {
            val outcome = runCatching {
                stager.stage(owner) { registry.pendingActive(pending) && ownerCurrent() }
            }
            outcome.fold(
                onSuccess = { snapshot ->
                    val parent = snapshot.file.parentFile
                    if (parent == null) {
                        registry.abandonStaging(pending)
                    } else {
                        val staged = RunOutputPdfStaged(
                            launchToken = snapshot.sessionID,
                            sessionDirectory = parent,
                            file = snapshot.file,
                            bytes = snapshot.bytes,
                            sha256 = snapshot.sha256,
                            displayName = snapshot.displayName,
                            conversationID = owner.conversationID,
                            runID = owner.runID,
                            outputID = owner.outputID,
                        )
                        if (registry.publishLive(pending, staged, ownerCurrent)) {
                            launchViewer(staged.launchToken)
                        } else {
                            // Stale ticket (abandoned meanwhile): the registry
                            // refused this snapshot, so its own random dir is
                            // this controller's to remove — nothing was launched.
                            purge(staged)
                        }
                    }
                    settlePurges()
                },
                onFailure = { error ->
                    val code = closedFailureCode(error)
                    if (code == FAILURE_OWNER_CHANGED) {
                        // Owner retired mid-stage: honest abandon, NO dead-end
                        // screen (the conversation itself is gone/replaced);
                        // the stager already released the lease and removed
                        // its partial directory.
                        registry.abandonStaging(pending)
                    } else {
                        val token = registry.publishFailed(pending, code, ownerCurrent)
                        if (token != null) launchViewer(token)
                    }
                    settlePurges()
                },
            )
        }
        return true
    }

    // ------------------------------------------------------------------
    // Viewer seams — each delegates to the coordinator, then acts on the
    // REAL answers only.
    // ------------------------------------------------------------------

    /** Resolve the opaque launch token (Intent carries NOTHING else). */
    fun claimForViewer(token: String?): RunOutputPdfClaim {
        val claim = registry.claim(token)
        settlePurges()
        return claim
    }

    /** Attach one renderer-host owner lease for the live launch. */
    fun attachRenderer(token: String): Boolean {
        val attached = registry.attachRenderer(token)
        settlePurges()
        return attached
    }

    /** The host's quiescent release join ran (every descriptor of every
     * transaction physically settled on the owned worker). */
    fun onRendererQuiesced(token: String) {
        registry.rendererQuiesced(token)
        settlePurges()
    }

    /** Count one print attempt BEFORE the flow call; false = the launch
     * retired — the viewer must not print, and nothing was counted. */
    fun beginPrintAttempt(token: String): Boolean {
        val started = registry.beginPrint(token)
        settlePurges()
        return started
    }

    /** The exactly-once [com.floe.android.core.officeengine.pdf.PrintFinish]
     * terminal for one counted attempt. NEVER called by UI destruction:
     * an admitted dialog keeps the snapshot retained until the framework's
     * own finish path settles it (and a non-admitted attempt settles at its
     * typed refusal). */
    fun onPrintSettled(token: String) {
        registry.finishPrint(token)
        settlePurges()
    }

    /** Explicit user close ONLY (back/close). Rotation destroys a screen
     * without ever reaching here, so an admitted print can never be
     * unwound because the UI moved. */
    fun onUserClose(token: String) {
        registry.userClose(token)
        settlePurges()
    }

    /** Closed failure vocabulary surfaced to the viewer (path-free, mirrors
     * the stager's typed codes; never an exception message or path).
     *
     * Doctrine (accepted consumer12 `OfficePreviewController.stagingError`
     * shape, aligned to lane 16): the owned stream saying NO — a typed
     * negative (open/info/read/close refusal such as -702/-704 when the
     * session was fenced/closed mid-I/O, a truncated or drifted stream, a
     * digest or EOF disagreement, storage denial) is a SOURCE-unavailable
     * statement about the CURRENT stream, never a claim about the document
     * bytes, and is always terminal-failed here (no retry-to-green; card
     * refresh re-proves from the durable receipt). Only the two closed PDF
     * IDENTITY refusals (host-MIME disagreement with the sealed extension,
     * or first streamed bytes that are not `%PDF-`) may be worded as
     * "not a readable PDF"; size gets its own honest line. */
    private fun closedFailureCode(error: Throwable): String = when {
        error is RunOutputOfficeSnapshotStager.Failure -> when (error.code) {
            "ownerChanged" -> FAILURE_OWNER_CHANGED
            "contentTooLarge" -> FAILURE_TOO_LARGE
            "invalidPdfFormat", "invalidPdfMagic", "invalidOfficeFormat" -> FAILURE_FORMAT
            else -> FAILURE_SOURCE
        }
        error is LinkageError -> FAILURE_SOURCE
        else -> FAILURE_SOURCE
    }

    private fun launchViewer(token: String) {
        val intent = Intent(appContext, RunOutputPdfPreviewActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(RunOutputPdfPreviewActivity.EXTRA_LAUNCH_TOKEN, token)
        val started = runCatching { appContext.startActivity(intent) }.isSuccess
        if (!started) {
            // Nothing may hold the slot or the bytes without a viewer.
            registry.userClose(token)
            settlePurges()
        }
    }

    /** Hand every accumulated cleanup decision to owned IO, exactly once
     * (the registry only ever produces a decision per snapshot). */
    private fun settlePurges() {
        val due = registry.drainPurges()
        if (due.isEmpty()) return
        scope.launch(Dispatchers.IO) { due.forEach { purge(it) } }
    }

    /** Own-dir-only removal, mirroring the reviewed Office stager cleanup:
     * a direct child of the canonical root whose name is the stager's random
     * session UUID, containing only the regular files this lane created. A
     * verification miss RETAINS the directory (never touch unknown bytes). */
    private fun purge(staged: RunOutputPdfStaged) {
        runCatching {
            val rootC = pdfRoot.canonicalFile
            val dirC = staged.sessionDirectory.canonicalFile
            if (dirC.parentFile != rootC) return
            if (runCatching { UUID.fromString(dirC.name).toString() }
                    .getOrNull() != dirC.name
            ) return
            dirC.listFiles()?.forEach { child ->
                if (child.isFile && !Files.isSymbolicLink(child.toPath())) {
                    runCatching { child.delete() }
                }
            }
            runCatching { dirC.delete() }
        }
    }

    private companion object {
        const val FAILURE_OWNER_CHANGED = "ownerChanged"
        const val FAILURE_TOO_LARGE = "contentTooLarge"
        const val FAILURE_SOURCE = "source"
        const val FAILURE_FORMAT = "format"
    }
}

/** The staged run-output PDF as an honest [OfficePdfVerifiedSource] handoff
 * for the SHARED renderer/print family: the three facts were proven BY THIS
 * App during staging (sealed receipt re-derived natively, whole-stream SHA,
 * exact length, magic, EOF) and the file is App-owned, read-only and
 * immutable. It grants no path authority to anyone: the renderer re-opens
 * its OWN pinned NO-FOLLOW descriptor per request, and the print adapter
 * pins its own descriptor for the job. */
internal class RunOutputPdfVerifiedSource(
    private val staged: RunOutputPdfStaged,
) : OfficePdfVerifiedSource {
    override val readableFile: File get() = staged.file
    override val expectedSha256: String get() = staged.sha256
    override val expectedBytes: Long get() = staged.bytes
}
