// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.output

import android.content.Context
import android.content.Intent
import com.floe.android.feature.conversation.RunOutputViewerKind
import com.floe.android.feature.conversation.RunOutputViewerSupport
import java.io.File
import java.nio.file.Files
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Main-process, Application-owned OPEN consumer for verified durable
 * run-output TEXT/Markdown and generated media (image/audio/video), created
 * by [com.floe.android.FloeApplication] in the ordinary main process only
 * (the isolated PDF and Office processes return from Application.onCreate
 * long before this exists).
 *
 * Chain (the same registered route shape as the PDF lane):
 *  1. the conversation card's Open re-enters native by the EXACT owned
 *     (conversation, run, output) triple only;
 *  2. the reviewed [RunOutputOfficeSnapshotStager] streams the sealed bytes
 *     through the EXISTING egress into a SEPARATE App-owned immutable
 *     snapshot root (`files/RunOutputViewerPreview`, disjoint from the PDF,
 *     Office and Save Copy roots) — whole-stream SHA + exact length + clean
 *     EOF proven before any UI opens;
 *  3. the sealed facts are re-classified from the STAGED receipt (never the
 *     card cache): an output whose native-sealed MIME and display name no
 *     longer agree with the admitted viewer kind is refused WHOLE;
 *  4. the launch is published into [RunOutputViewerLaunchRegistry] and the
 *     non-exported [RunOutputViewerPreviewActivity] is started with NOTHING
 *     but the opaque random launch token;
 *  5. the snapshot outlives the egress lease but never its OWN live owners:
 *     unlink happens ONLY through the coordinator's exactly-once cleanup
 *     decision after explicit close AND viewer quiescence.
 *
 * It grants no new permission, reads no arbitrary path, never launches
 * external apps and never mutates the immutable snapshot (the text space is
 * read-only; run-output originals stay runtime-owned and copy-only).
 */
internal class RunOutputViewerPreviewController(
    context: Context,
    private val scope: CoroutineScope,
) {
    private val appContext = context.applicationContext
    private val viewerRoot = File(appContext.applicationInfo.dataDir, "files/RunOutputViewerPreview")
    private val stager = RunOutputOfficeSnapshotStager(
        viewerRoot, NativeRunOutputChannel, RunOutputViewerSupport.STAGED_EXTENSIONS,
    )
    private val registry = RunOutputViewerLaunchRegistry()

    /** Typed busy refusal BEFORE any staging starts (single admission slot;
     * mirrors the PDF controller's click-time check). */
    fun hasActiveLaunch(): Boolean = registry.slotBusy()

    /**
     * Start one verified viewer open. [expectedKind] is the caller's
     * card-level classification; the STAGED native-sealed facts re-derive
     * the kind and must AGREE, so a stale card can never open bytes the
     * owner no longer vouches for. True means the host STARTED the verified
     * pipeline; false is a typed refusal that started nothing.
     */
    fun openRunOutputViewer(
        owner: RunOutputOfficeSnapshotStager.Owner,
        expectedKind: RunOutputViewerKind,
        ownerCurrent: () -> Boolean,
    ): Boolean {
        if (expectedKind == RunOutputViewerKind.UNSUPPORTED) return false
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
                        // No session directory to own: publish nothing.
                        registry.abandonStaging(pending)
                        settlePurges()
                        return@fold
                    }
                    val staged = RunOutputViewerStaged(
                        launchToken = snapshot.sessionID,
                        sessionDirectory = parent,
                        file = snapshot.file,
                        bytes = snapshot.bytes,
                        sha256 = snapshot.sha256,
                        displayName = snapshot.displayName,
                        mimeType = snapshot.mimeType,
                        conversationID = owner.conversationID,
                        runID = owner.runID,
                        outputID = owner.outputID,
                    )
                    // Re-derive the kind from the NATIVE-SEALED staged facts;
                    // the launch publishes only when the staged receipt agrees
                    // with the admitted card kind.
                    val stagedKind = RunOutputViewerSupport.classify(
                        snapshot.mimeType, snapshot.displayName)
                    if (stagedKind == expectedKind) {
                        if (registry.publishLive(pending, staged, ownerCurrent)) {
                            launchViewer(staged.launchToken)
                        } else {
                            // Stale ticket: the registry refused this
                            // snapshot, so its own random dir is ours to
                            // remove — nothing was launched.
                            purge(staged)
                        }
                    } else {
                        // Identity drift between the cached card and the
                        // sealed stream: purge the bytes we just staged and
                        // surface the honest typed refusal screen.
                        purge(staged)
                        val token = registry.publishFailed(pending, FAILURE_FORMAT, ownerCurrent)
                        if (token != null) launchViewer(token)
                    }
                    settlePurges()
                },
                onFailure = { error ->
                    val code = closedFailureCode(error)
                    if (code == FAILURE_OWNER_CHANGED) {
                        // Owner retired mid-stage: honest abandon, NO dead-end
                        // screen; the stager already released the lease and
                        // removed its partial directory.
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
    fun claimForViewer(token: String?): RunOutputViewerClaim {
        val claim = registry.claim(token)
        settlePurges()
        return claim
    }

    /** Attach one viewer lease for the live launch. */
    fun attachViewer(token: String): Boolean {
        val attached = registry.attachViewer(token)
        settlePurges()
        return attached
    }

    /** The screen's content really settled (text decoded / player released). */
    fun onViewerQuiesced(token: String) {
        registry.viewerQuiesced(token)
        settlePurges()
    }

    /** Explicit user close ONLY (back/close — never a config change). */
    fun onUserClose(token: String) {
        registry.userClose(token)
        settlePurges()
    }

    /** Closed failure vocabulary surfaced to the viewer (path-free, mirrors
     * the PDF lane doctrine): a typed negative from the owned stream is a
     * SOURCE-unavailable statement about the CURRENT stream, never a claim
     * about the document bytes; only the identity-drift refusal
     * ([FAILURE_FORMAT]) says the sealed facts disagree, and size gets its
     * own honest line. */
    private fun closedFailureCode(error: Throwable): String = when {
        error is RunOutputOfficeSnapshotStager.Failure -> when (error.code) {
            "ownerChanged" -> FAILURE_OWNER_CHANGED
            "contentTooLarge" -> FAILURE_TOO_LARGE
            "invalidOfficeFormat" -> FAILURE_FORMAT
            else -> FAILURE_GONE
        }
        error is LinkageError -> FAILURE_GONE
        else -> FAILURE_GONE
    }

    private fun launchViewer(token: String) {
        val intent = Intent(appContext, RunOutputViewerPreviewActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(RunOutputViewerPreviewActivity.EXTRA_LAUNCH_TOKEN, token)
        val started = runCatching { appContext.startActivity(intent) }.isSuccess
        if (!started) {
            // Nothing may hold the slot without a viewer.
            registry.userClose(token)
            settlePurges()
        }
    }

    /** Hand every accumulated cleanup decision to owned IO, exactly once. */
    private fun settlePurges() {
        val due = registry.drainPurges()
        if (due.isEmpty()) return
        scope.launch(Dispatchers.IO) { due.forEach { purge(it) } }
    }

    /** Own-dir-only removal, mirroring the reviewed PDF purge: a direct
     * child of the canonical root whose name is the stager's random session
     * UUID, containing only the regular files this lane created. A
     * verification miss RETAINS the directory (never touch unknown bytes). */
    private fun purge(staged: RunOutputViewerStaged) {
        runCatching {
            val rootC = viewerRoot.canonicalFile
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
        const val FAILURE_TOO_LARGE = "tooLarge"
        const val FAILURE_GONE = "gone"
        const val FAILURE_FORMAT = "format"
    }
}
