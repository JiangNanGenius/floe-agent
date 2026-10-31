// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.runlifecycle.ForegroundLease
import com.floe.android.runlifecycle.NativeLiveWork
import com.floe.android.runlifecycle.OperationKind
import com.floe.android.runlifecycle.RunForegroundController
import com.floe.android.runlifecycle.RunForegroundFailure
import com.floe.android.runlifecycle.RunForegroundWire
import java.util.concurrent.ConcurrentHashMap

/**
 * Seam Main implements with the JNI readback of
 * `floe_run_foreground_snapshot` (same fail-closed shape as the existing
 * narrow `RuntimeCoreNative` readers). Use `RunForegroundWire.parse` on
 * the raw ASCII line (wire pinned there: booleans are strictly 1/0);
 * null/unknown means "no trustworthy answer", NEVER zero-work truth.
 */
fun interface RunForegroundNativeSnapshotSource {
    /** null == no live generation or the readback failed: honest unknown. */
    fun read(): NativeLiveWork?
}

/**
 * The Core App host binding between ACTUAL runtime lifecycle and the
 * foreground controller. It contains no business logic and invents nothing:
 *
 *  * Foreground must be acquired in the USER-LAUNCHED phase, BEFORE the
 *    command dispatch, because dispatch itself can background the app and
 *    then the OS may refuse a start ([agentLaunchProvisional] → accepted
 *    handoff → settlement). The provisional lease is keyed by the UI's
 *    explicit-launch UUID; after the accepted `run.start` reply the
 *    authoritative lease (ORIGINAL native runID) is acquired FIRST and
 *    only then is the provisional lease released, so coverage is
 *    continuous. A DEFINITE no-admission releases the provisional lease;
 *    an UNCERTAIN receipt (dispatched, reply lost) retains it for
 *    resolution through [agentLaunchAdmitted] or
 *    [agentLaunchDefinitelyNotAdmitted] — never silently dropped, and
 *    NEVER settled from ledger counts (only Main's durable truth knows
 *    whether such a run ever materialized).
 *  * Agent run ids come from the ORIGINAL runtime context; [agentRunStarted]
 *    remains the direct hook when Main already holds an accepted reply
 *    (e.g. queued/goal continuations). Settlement closes run leases ONLY
 *    on a POSITIVE live-ledger zero — runs, child runs AND owned tool
 *    cleanup all detached under the CURRENT accepted epoch. A live run
 *    always occupies the ledger (attach precedes the accepted reply;
 *    detach only at real settlement), so known-zero proves every held
 *    lease's run really settled — even when a UI event pump detached on
 *    navigation and no holder saw the terminal echo.
 *    [nativeOwnedWorkChanged] is that REAL change-event entry, driven by
 *    Main's JNI/host observer on `floe_run_foreground_wait_change`
 *    (positive sequence change only). An unknown read retains everything.
 *    UI-side boundaries ([agentRunSettled], resume, [reconcileAgentRuns])
 *    run the same honest check. This is event-driven — never a busy
 *    poller — and count-based quiescence NEVER acquires foreground from
 *    counts.
 *  * A remote shell stop-request, EOF or run cancellation does NOT close a
 *    LOCAL_EXECUTION lease: Main holds the per-remote-session lease
 *    through ACTUAL release (and detached-cancellation reconciliation),
 *    closing only via [localSessionReleased].
 *  * DURABLE_JOB is an honest hook for the original job lifecycle AFTER
 *    the FloeAndroidJobTools handoff: ids come from the ORIGINAL runtime
 *    job context; this adapter never executes jobs, never duplicates a
 *    schema or jobs.submit, and never fabricates job state.
 *  * ENVIRONMENT_INSTALL leases wrap explicit user-started preparation
 *    work; the operation id is minted by the UI at that action.
 *
 * Acquisition failures are reported to [onUnavailable] with the typed
 * reason so the App stays honest: app-foreground chat keeps working
 * through the existing flow, and background availability is only claimed
 * when a lease actually exists. Readiness false/unknown NEVER creates the
 * service from nothing.
 */
class RunForegroundBinding(
    private val controller: RunForegroundController,
    private val nativeSnapshot: RunForegroundNativeSnapshotSource?,
    /** Routes the notification Stop to the canonical `run.cancel` command
     *  (Main wires this to the existing ConversationHostController seam).
     *  A false answer means "request not delivered now" — it is NOT
     *  settlement: the lease waits for the real ledger settlement. */
    private val cancelAgentRun: (conversationID: String, runID: String) -> Boolean,
    /** Requests the ACTUAL remote session release through the runtime
     *  channel. The response is not settlement either: [localSessionReleased]
     *  arrives only after the real release reconciles. */
    private val releaseLocalSession: (sessionID: String) -> Unit,
    /** Honest availability reporting for Main's UI copy/diagnostics. */
    private val onUnavailable: (operation: String, failure: RunForegroundFailure) -> Unit = { _, _ -> },
    /** Counts only; no task, conversation, provider or file identifiers. */
    private val onDiagnostic: (String) -> Unit = {},
) {

    private val agentRunLeases = ConcurrentHashMap<String, ForegroundLease>()
    private val agentRunConversation = ConcurrentHashMap<String, String>()
    /** Provisional user-launch leases keyed by the UI-minted launch
     *  operation UUID; retained across an uncertain receipt until Main
     *  resolves the admission truth. */
    private val provisionalLaunchLeases = ConcurrentHashMap<String, ForegroundLease>()
    private val localSessionLeases = ConcurrentHashMap<String, ForegroundLease>()
    private val installLeases = ConcurrentHashMap<String, ForegroundLease>()
    private val durableJobLeases = ConcurrentHashMap<String, ForegroundLease>()
    private val lastLedgerDiagnostic = java.util.concurrent.atomic.AtomicReference<String?>(null)

    /** Concurrent duplicate lifecycle echoes must not lose a refcounted claim. */
    private fun retainSingleLease(leases: ConcurrentHashMap<String, ForegroundLease>, key: String, lease: ForegroundLease) {
        while (true) {
            val previous = leases.putIfAbsent(key, lease) ?: return
            if (previous.isClosed) {
                if (leases.replace(key, previous, lease)) return
                continue
            }
            lease.close() // release the duplicate contribution, keep the original
            return
        }
    }

    // MARK: User-launched run acquisition (before dispatch, no OS race)

    /**
     * Acquire foreground ownership for an EXPLICIT user launch action
     * BEFORE the `run.start` command is dispatched, while the OS still
     * grants the user-initiated start window. [launchOperationID] is the
     * stable UUID the UI mints at that explicit action (never inferred).
     * Returns false — with the typed failure reported — when foreground
     * could not be established at the user-visible phase; Main then keeps
     * the app-foreground chat flow and reports background availability
     * honestly.
     *
     * [onStopRequested] routes an early Stop press (before the run exists)
     * to the real "abandon/cancel this launch attempt" path Main owns —
     * the provisional lease itself is only closed at admission handoff,
     * definite rejection or resolved settlement, never by the press.
     */
    suspend fun agentLaunchProvisional(
        launchOperationID: String,
        onStopRequested: com.floe.android.runlifecycle.RunStopHandler? = null,
    ): Boolean {
        if (provisionalLaunchLeases[launchOperationID]?.let { it.isActiveNow() } == true) return true
        val lease = try {
            controller.acquireOperation(
                operationID = launchOperationID,
                kind = OperationKind.AGENT_RUN,
                stopHandler = onStopRequested,
            )
        } catch (cancellation: kotlinx.coroutines.CancellationException) {
            throw cancellation // controller rolled back this contribution already.
        } catch (failure: RunForegroundFailure) {
            onUnavailable("agent-launch", failure)
            return false
        }
        retainSingleLease(provisionalLaunchLeases, launchOperationID, lease)
        return true
    }

    /**
     * The accepted `run.start` reply carries the AUTHORITATIVE native
     * runID. Order is coverage-preserving: acquire/attach the
     * authoritative lease FIRST, and only release the provisional lease
     * after that lease is held — a close-then-acquire could otherwise
     * empty the owned set mid-launch and let the service stop.
     */
    suspend fun agentLaunchAdmitted(
        launchOperationID: String,
        conversationID: String,
        runID: String,
    ): Boolean {
        val authoritative = agentRunStarted(conversationID, runID)
        if (authoritative) {
            provisionalLaunchLeases.remove(launchOperationID)?.close()
        }
        // On false the provisional lease stays retained: an accepted reply
        // with a failing authoritative acquire means the foreground truth
        // changed under us; Main reports honestly and resolves later.
        return authoritative
    }

    /** A DEFINITE no-admission answer for the dispatch (typed native
     *  rejection before any run materialized): release the provisional
     *  lease. An uncertain receipt must NOT call this. */
    fun agentLaunchDefinitelyNotAdmitted(launchOperationID: String) {
        provisionalLaunchLeases.remove(launchOperationID)?.close()
    }

    /** Late admission discovered after an uncertain receipt (e.g. the run
     *  surfaces through a queue/snapshot event): resolve the provisional
     *  lease through the same handoff. */
    suspend fun agentLaunchReceiptResolved(
        launchOperationID: String,
        conversationID: String,
        runID: String,
    ): Boolean = agentLaunchAdmitted(launchOperationID, conversationID, runID)

    // MARK: Agent runs (ORIGINAL runtime ids)

    /** Direct hook for paths where Main already holds the accepted reply
     *  (queued/goal continuations). `runID` is the canonical native run
     *  UUID — never a view or conversation guess. */
    suspend fun agentRunStarted(conversationID: String, runID: String): Boolean {
        agentRunConversation[runID] = conversationID
        val existing = agentRunLeases[runID]
        if (existing?.isActiveNow() == true) return true
        val lease = try {
            controller.acquireOperation(
                operationID = runID,
                kind = OperationKind.AGENT_RUN,
                stopHandler = {
                    val conversation = agentRunConversation[runID] ?: conversationID
                    cancelAgentRun(conversation, runID)
                    Unit
                },
            )
        } catch (cancellation: kotlinx.coroutines.CancellationException) {
            // The controller already rolled back its own contribution; drop
            // the local bookkeeping so a later real admission re-acquires
            // cleanly under a fresh owner generation.
            agentRunConversation.remove(runID)
            throw cancellation
        } catch (failure: RunForegroundFailure) {
            agentRunConversation.remove(runID)
            onUnavailable("agent-run", failure)
            return false
        }
        retainSingleLease(agentRunLeases, runID, lease)
        return true
    }

    /** The existing host terminal boundary for this exact run (UI side).
     *  Never closes anything by itself: settlement requires the ledger
     *  check below, which a missed terminal echo cannot break. */
    fun agentRunSettled(runID: String) {
        reconcileAgentRuns()
    }

    /**
     * Event-driven ledger check entry for UI-side boundaries (terminal
     * echo, App resume). Same rules as [nativeOwnedWorkChanged].
     */
    fun reconcileAgentRuns() {
        settleOnKnownQuiescence()
    }

    /**
     * Main's JNI/host observer calls this when the bounded
     * `floe_run_foreground_wait_change` reports a POSITIVE sequence
     * change for the current observation (a value lower than the
     * observation means the signal state was replaced — rebase by calling
     * this too; the unknown case simply retains). Reading the live ledger
     * is the ONLY thing this does: known-zero settles held Agent run
     * leases WITHOUT requiring a UI terminal that a detached pump missed.
     * Unknown retains everything, honestly. Never acquires foreground
     * from counts; never touches provisional launch leases (their truth
     * lives in Main's durable admission).
     */
    fun nativeOwnedWorkChanged() {
        settleOnKnownQuiescence()
    }

    private fun reportLedgerDiagnostic(snapshot: NativeLiveWork?) {
        val native = snapshot?.let {
            "epoch=${it.nativeRootEpoch},ready=${it.storeReady},fenced=${it.admissionFenced}," +
                "run=${it.runCount},child=${it.childRunCount},tool=${it.toolCount}"
        } ?: "unknown"
        val value = "native=$native;agent=${agentRunLeases.size};" +
            "launch=${provisionalLaunchLeases.size};local=${localSessionLeases.size};" +
            "install=${installLeases.size};job=${durableJobLeases.size}"
        if (lastLedgerDiagnostic.getAndSet(value) != value) {
            runCatching { onDiagnostic(value) }
        }
    }

    private fun settleOnKnownQuiescence() {
        val snapshot = nativeSnapshot?.read()
        reportLedgerDiagnostic(snapshot)
        if (agentRunLeases.isEmpty()) return
        if (snapshot == null) return // unknown: retain.
        if (snapshot.nativeRootEpoch <= 0L) return // no trustworthy epoch: retain.
        if (snapshot.hasLiveRunOwnedWork) return // real work continues.
        settleAllAgentLeases()
    }

    /** Every Agent run lease is safe to settle on a KNOWN ledger zero.
     *  A fresh read guards each close: if new real work attaches while we
     *  iterate (a run admitted between the first read and a later close),
     *  the re-read shows live work and we STOP settling — the newer lease
     *  stays protected; the loop cost is one lock-only native read per
     *  lease and runs only on genuine settle events, never busy. */
    private fun settleAllAgentLeases() {
        for (runID in agentRunLeases.keys.toList()) {
            if (agentRunLeases[runID]?.isClosed == true) {
                agentRunLeases.remove(runID)
                agentRunConversation.remove(runID)
                continue
            }
            val fresh = nativeSnapshot?.read() ?: return // became unknown: retain rest.
            if (fresh.nativeRootEpoch <= 0L || fresh.hasLiveRunOwnedWork) return
            agentRunConversation.remove(runID)
            agentRunLeases.remove(runID)?.close()
        }
    }

    // MARK: Local runtime sessions (actual open PTY sessions are owned work)

    /** `sessionID` is the ORIGINAL stable session identity (UUID form)
     *  from the runtime session context, never an inferred or
     *  view-scoped value. An idle app is NOT owned work; a real open
     *  session is. */
    suspend fun localSessionOpened(sessionID: String): Boolean {
        if (localSessionLeases[sessionID]?.let { it.isActiveNow() } == true) return true
        val lease = try {
            controller.acquireOperation(
                operationID = sessionID,
                kind = OperationKind.LOCAL_EXECUTION,
                stopHandler = { releaseLocalSession(sessionID) },
            )
        } catch (cancellation: kotlinx.coroutines.CancellationException) {
            throw cancellation
        } catch (failure: RunForegroundFailure) {
            onUnavailable("local-session", failure)
            return false
        }
        retainSingleLease(localSessionLeases, sessionID, lease)
        return true
    }

    /** Main calls this ONLY after the ACTUAL remote release reconciled
     *  (including detached-cancellation reconciliation). Shell stop
     *  requests, EOF or cancellation answers never route here. */
    fun localSessionReleased(sessionID: String) {
        localSessionLeases.remove(sessionID)?.close()
    }

    // MARK: Environment preparation (explicit UI action, minted id)

    suspend fun environmentPreparationStarted(operationID: String): Boolean {
        if (installLeases[operationID]?.let { it.isActiveNow() } == true) return true
        val lease = try {
            controller.acquireOperation(
                operationID = operationID,
                kind = OperationKind.ENVIRONMENT_INSTALL,
                stopHandler = null, // Main registers the installer's real stop route.
            )
        } catch (cancellation: kotlinx.coroutines.CancellationException) {
            throw cancellation
        } catch (failure: RunForegroundFailure) {
            onUnavailable("environment-install", failure)
            return false
        }
        retainSingleLease(installLeases, operationID, lease)
        return true
    }

    /** The installer's actual terminal (success, failure or cancelled
     *  settlement) — not the progress echo — closes the lease. */
    fun environmentPreparationSettled(operationID: String) {
        installLeases.remove(operationID)?.close()
    }

    // MARK: Durable jobs (honest hook; the original lifecycle stays authority)

    /** Wired by Main ONLY after the FloeAndroidJobTools handoff, with ids
     *  from the ORIGINAL runtime job context. No job execution, no schema
     *  duplication and no jobs.submit live here. */
    suspend fun durableJobAdmitted(jobID: String, onStopRequested: () -> Unit): Boolean {
        if (durableJobLeases[jobID]?.let { it.isActiveNow() } == true) return true
        val lease = try {
            controller.acquireOperation(
                operationID = jobID,
                kind = OperationKind.DURABLE_JOB,
                stopHandler = { onStopRequested() },
            )
        } catch (cancellation: kotlinx.coroutines.CancellationException) {
            throw cancellation
        } catch (failure: RunForegroundFailure) {
            onUnavailable("durable-job", failure)
            return false
        }
        retainSingleLease(durableJobLeases, jobID, lease)
        return true
    }

    /** The ORIGINAL job authority reports real settlement here. */
    fun durableJobSettled(jobID: String) {
        durableJobLeases.remove(jobID)?.close()
    }

    // MARK: Honest observation + owner-stop boundary

    fun heldOperations(): Set<String> = controller.heldOperations()

    /** Diagnostics-only closed mirror of the CURRENT owned operation KINDS
     *  (Diagnostics & About details popup). Pure read through the SAME
     *  controller authority; mutates nothing, owns nothing. */
    fun heldOperationKinds(): Set<OperationKind> = controller.heldOperationKinds()

    /** True only with a confirmed real foreground service; never a
     *  preference-backed or optimistic "ready". */
    fun isForegroundConfirmed(): Boolean = controller.isForegroundConfirmed()

    /** Diagnostics-only honest read of the owned-work CPU wake (mirrors
     *  the controller; the wake itself stays owned by the service +
     *  coordinator, never by this binding or any view). */
    fun isCpuWakeHeld(): Boolean = controller.isCpuWakeHeld()

    /**
     * Application owner-stop boundary. Releases SERVICE ownership for all
     *  leases WITHOUT cancelling any underlying work (the original
     *  authorities keep governing their operations).
     *
     * Main MUST call this ONLY AFTER the REAL root/work cleanup proof
     * (the native Root pre-shutdown drain gate has settled: owned store
     * closed, live domain work drained) — never from a stop REQUEST, an
     *  exit animation or a mere navigation. Releasing service ownership
     *  before real settlement would drop protection while work is still
     *  live; that ordering belongs to Main's shutdown gate.
     */
    fun releaseAllForShutdown() {
        provisionalLaunchLeases.values.forEach { it.close() }
        provisionalLaunchLeases.clear()
        agentRunLeases.values.forEach { it.close() }
        agentRunLeases.clear()
        agentRunConversation.clear()
        localSessionLeases.values.forEach { it.close() }
        localSessionLeases.clear()
        installLeases.values.forEach { it.close() }
        installLeases.clear()
        durableJobLeases.values.forEach { it.close() }
        durableJobLeases.clear()
    }

    /** Raw-line entry point for Main's JNI adapter convenience: strictly
     *  parse the projection ASCII (null == unknown). */
    fun parseNativeSnapshot(raw: String?): NativeLiveWork? = RunForegroundWire.parse(raw)
}
