// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.state

import com.floe.android.feature.notes.NotesService
import com.floe.android.feature.notes.ui.api.NotesHostPorts
import com.floe.android.feature.notes.ui.presentation.NotesEditConflict
import com.floe.android.feature.notes.ui.presentation.NotesFailure
import com.floe.android.feature.notes.ui.presentation.NotesPendingRecovery
import com.floe.android.feature.notes.ui.presentation.NotesRecoveryStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * App-owned Notes workspace lifecycle.
 *
 * Main should create ONE session beside the lazily constructed Notes host and
 * pass it to [com.floe.android.feature.notes.ui.FloeNotesWorkspace]. Keeping it
 * outside composition is what makes a real root-retirement flush possible:
 * the composable may disappear while the session still owns queued edits.
 *
 * Required shutdown order (also in HOST_PORTS.md):
 * 1. `await prepareForRootStop()` BEFORE retiring the accepted native root;
 * 2. retire/replace the root and call `await resumeAfterRootChange()` after the
 *    new epoch is accepted (the same process/service may rebind);
 * 3. `close()` only when the ViewModel/application owner is finished.
 *
 * `prepareForRootStop` returns per-document facts. `kept` means the exact edits
 * (and ink bytes) were retained in [NotesRecoveryStore] and must not be
 * reported as saved. A recovered report with `canRetire == false`, or a thrown
 * [NotesRecoveryStore.put] (for example `NotesRecoveryStorageException` from
 * the App store), MUST refuse root retirement: keep the live session, do not
 * close/discard it, then call [abortRootStop] to re-arm the same accepted
 * epoch. Only a report with `canRetire == true` allows the root to retire.
 */
public sealed interface NotesRecoveryResumeResult {
    public data object Restored : NotesRecoveryResumeResult
    public data object DocumentMissing : NotesRecoveryResumeResult
    public data object DocumentDeleted : NotesRecoveryResumeResult
    public data class Conflict(public val conflict: NotesEditConflict) : NotesRecoveryResumeResult
    public data class Failed(public val failure: NotesFailure) : NotesRecoveryResumeResult
}

public interface NotesEditorFlushPort {
    public suspend fun prepareForRootStop(deadlineMillis: Long = 4_000L): NotesRootStopReport
    public suspend fun resumeAfterRootChange(): NotesResumeReport
    /**
     * Re-arm the SAME accepted root epoch after a refused retirement (a
     * [NotesRootStopReport.canRetire] false or a thrown recovery write). It
     * clears the UI fence and retries retained edits; it does not stop, bind
     * or replace any native root. Never call it before a retention decision.
     * The default preserves source compatibility for older fakes/implementers.
     */
    public suspend fun abortRootStop(): NotesResumeReport = resumeAfterRootChange()
    public fun pendingRecovery(): List<NotesPendingRecovery>
    public fun discardRecovery(documentID: String)
    /** Replays one durable recovery record after validating document/kind/trash state. */
    public suspend fun resumeRecovery(documentID: String): NotesRecoveryResumeResult
}

public fun createNotesWorkspaceSession(
    service: NotesService,
    ports: NotesHostPorts,
): NotesWorkspaceSession = NotesWorkspaceSession(service, ports)

public class NotesWorkspaceSession internal constructor(
    service: NotesService,
    ports: NotesHostPorts,
    /** Main/App production default; tests may inject a deterministic scope. */
    scope: CoroutineScope? = null,
) : NotesEditorFlushPort {
    private val scope = scope ?: CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val stateLock = Any()

    @Volatile
    private var generation: Long = 0L

    @Volatile
    private var fenced: Boolean = false

    @Volatile
    private var stopping: Boolean = false

    internal val controller: NotesWorkspaceController = NotesWorkspaceController(
        service = service,
        ports = ports,
        scope = this.scope,
        generation = { generation },
        fenced = { fenced || stopping },
    )

    internal fun start() {
        controller.start()
    }

    override suspend fun prepareForRootStop(deadlineMillis: Long): NotesRootStopReport {
        synchronized(stateLock) {
            if (stopping) {
                // A stop is already in progress. Do not let a concurrent
                // caller authorize retirement from a stale report.
                return NotesRootStopReport(
                    flushedDocumentIDs = emptyList(),
                    kept = emptyList(),
                    timedOut = false,
                    canRetire = false,
                )
            }
            stopping = true
        }
        val report = try {
            controller.prepareForStop(deadlineMillis)
        } finally {
            synchronized(stateLock) {
                fenced = true
                generation += 1
                stopping = false
            }
        }
        return report
    }

    override suspend fun resumeAfterRootChange(): NotesResumeReport {
        synchronized(stateLock) {
            generation += 1
            fenced = false
            stopping = false
        }
        return controller.resumeAfterRoot()
    }

    override suspend fun abortRootStop(): NotesResumeReport {
        // Same-epoch re-arm after a refused/aborted retirement: no native root
        // stop or rebind happens here.
        synchronized(stateLock) {
            fenced = false
            stopping = false
        }
        return controller.resumeAfterRoot()
    }

    override fun pendingRecovery(): List<NotesPendingRecovery> = controller.ports.recovery.pending()

    override fun discardRecovery(documentID: String) {
        controller.ports.recovery.remove(documentID)
        controller.session(documentID)?.discardRecovery()
    }

    override suspend fun resumeRecovery(documentID: String): NotesRecoveryResumeResult {
        val recovery = controller.ports.recovery.pending().firstOrNull { it.documentID == documentID }
            ?: return NotesRecoveryResumeResult.DocumentMissing
        return controller.resumeRecovery(recovery)
    }

    /**
     * Final release. Call after [prepareForRootStop] when the owner is
     * shutting down; this cancels every in-flight view/event job but does not
     * delete any committed note. The shared [NotesService] is NOT closed here —
     * its App/runtime owner does that.
     */
    public fun close() {
        controller.dispose()
        scope.cancel()
    }

    /**
     * Composition-owned convenience: flush first, then release. Composition
     * cannot suspend in onDispose, so this launches on the session's own scope;
     * Main-owned sessions should call [prepareForRootStop] explicitly instead.
     */
    public fun closeAfterFlush(deadlineMillis: Long = 3_000L) {
        scope.launch {
            // Never dispose a session whose pending edits were not durably
            // retained. A failed stop leaves the session (and its recovery
            // handoff) alive instead of silently dropping user content.
            val report = runCatching { prepareForRootStop(deadlineMillis) }.getOrNull()
            if (report?.canRetire == true) close()
        }
    }
}
