// SPDX-License-Identifier: MPL-2.0
package com.floe.android.schedule

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.work.ListenableWorker
import com.floe.android.FloeApplication
import com.floe.android.bridge.RunForegroundNative
import com.floe.android.host.RuntimeHost
import com.floe.android.runlifecycle.RunForegroundWire
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Application-owned scheduling platform bootstrapper. Main calls
 * [attach] in `FloeApplication.onCreate` (data-only) and [bindHost] after the
 * real `RuntimeHost` is ready. It owns the AlarmManager/WorkManager transport,
 * the bounded rearm pass and the app-alive after-success drain; the logical
 * schedule authority stays the native SQLite occurrence ledger.
 */
internal object TaskSchedulePlatform {
    @Volatile
    private var coordinator: TaskScheduleCoordinator? = null
    /** The ONE Application-owned authority provider, shared by the platform
     * dispatch path and the UI. It is installed by `attach` before any host
     * or screen is bound, so the UI never has to invent a provider. */
    @Volatile
    private var environmentProvider: TaskScheduleEnvironmentProvider? = null

    @Synchronized
    fun attach(
        application: FloeApplication,
        environmentProvider: TaskScheduleEnvironmentProvider? = null,
    ): TaskScheduleCoordinator {
        coordinator?.release()
        this.environmentProvider = environmentProvider
        val created = TaskScheduleCoordinator(application, environmentProvider)
        coordinator = created
        return created
    }

    val current: TaskScheduleCoordinator?
        get() = coordinator

    /** Same instance the platform dispatch worker uses; null only before
     * `attach` (fixtures/previews), never a placeholder provider. */
    val authority: TaskScheduleEnvironmentProvider?
        get() = environmentProvider

    fun bindHost(host: RuntimeHost?) {
        if (host == null) return
        coordinator?.bind(host)
    }

    /** Root stop/retirement: stop observing the retired generation. A later
     * `bindHost` for the new accepted epoch re-establishes it. */
    fun onRootStopped(host: RuntimeHost?) {
        if (host == null) return
        coordinator?.unbind(host)
    }

    /** Immediate duplicate-safe nudge for an explicit `runNow` occurrence.
     * The Worker (not this call) performs the claim/launch under the real
     * foreground binding. */
    fun enqueuePendingDispatch(scheduleID: String) {
        coordinator?.enqueuePendingDispatch(scheduleID)
    }

    fun exactAlarmAllowed(context: Context): Boolean =
        TaskScheduleAlarmScheduler.exactAlarmAllowed(context)

    fun notificationsUsable(context: Context): Boolean =
        TaskScheduleAlarmScheduler.notificationsUsable(context)

    fun flexibleChosen(context: Context, scheduleID: String): Boolean =
        TaskScheduleChoiceStore(context).flexibleChosen(scheduleID)

    fun setFlexibleChosen(context: Context, scheduleID: String, chosen: Boolean) {
        TaskScheduleChoiceStore(context).setFlexibleChosen(scheduleID, chosen)
        TaskScheduleRearmWorker.enqueue(context)
    }

    fun transportNotice(context: Context, scheduleID: String): String? =
        TaskScheduleChoiceStore(context).notice(scheduleID)

    /** Opens the system exact-alarm permission screen (user action only). */
    fun openExactAlarmSettings(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 31) return false
        val intent = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
            .setData(Uri.parse("package:${context.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            context.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }
}

internal class TaskScheduleCoordinator(
    private val application: FloeApplication,
    private val environmentProvider: TaskScheduleEnvironmentProvider?,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val choices by lazy { TaskScheduleChoiceStore(application) }
    private val scheduler by lazy { TaskScheduleAlarmScheduler(application) }
    private val rearmMutex = Mutex()

    @Volatile private var host: RuntimeHost? = null
    /** EXACT accepted Root epoch this coordinator's observer/reconcile jobs
     *  belong to. The same `RuntimeHost` instance survives generations, so
     *  identity alone is never a generation proof. */
    @Volatile private var boundEpoch: Long? = null
    @Volatile private var observer: Job? = null
    /** Application-scoped late-terminal resolvers; cancelled on root stop or
     *  an accepted generation replacement so a retired generation cannot
     *  adopt work after shutdown. */
    private val reconciliations =
        java.util.concurrent.CopyOnWriteArrayList<Job>()

    fun bind(host: RuntimeHost) {
        // A real bind only follows an accepted Root (`OwnedStoreReady`).
        // Without a positive epoch there is nothing this generation can own;
        // the next ready event binds again.
        val epoch = host.nativeRootEpoch()?.takeIf { it > 0 } ?: return
        if (this.host === host && observer?.isActive == true && boundEpoch == epoch) {
            return
        }
        // Same instance, new accepted epoch: retire every old observer and
        // late resolver BEFORE the new generation is observed.
        retireGeneration()
        this.host = host
        this.boundEpoch = epoch
        observer = scope.launch { observeOwnedWork(host, epoch) }
        scope.launch { refreshWakeupsOnce(allowPendingDispatch = true) }
    }

    private fun retireGeneration() {
        observer?.cancel()
        observer = null
        reconciliations.forEach { it.cancel() }
        reconciliations.clear()
    }

    /** Stops observing a retired generation. The coordinator and its choice
     * store stay process-owned; `bind` re-arms for a later accepted epoch. */
    fun unbind(host: RuntimeHost) {
        if (this.host !== host) return
        retireGeneration()
        this.host = null
        this.boundEpoch = null
    }

    fun enqueuePendingDispatch(scheduleID: String) {
        TaskScheduleDispatchWorker.enqueue(
            application, scheduleID, TaskScheduleDispatchWorker.TRIGGER_PENDING)
    }

    fun release() {
        retireGeneration()
        host = null
        boundEpoch = null
        scope.cancel()
    }

    // ------------------------------------------------------------- worker API

    suspend fun dispatchFromWorker(
        worker: androidx.work.CoroutineWorker,
        scheduleID: String,
        trigger: String,
    ): ListenableWorker.Result {
        val current = waitForHost(HOST_WAIT_MILLIS)
            ?: return worker.retryOrFail(
                application, scheduleID, null, "runtime_unavailable")
        // The EXACT generation this dispatch may launch into. `RuntimeHost`
        // survives an accepted root replacement, so a live non-null epoch at
        // a later callback is not proof it is the SAME generation.
        val epochAtDispatch = current.nativeRootEpoch()
            ?: return worker.retryOrFail(
                application, scheduleID, null, "runtime_unavailable")
        if (!TaskScheduleAlarmScheduler.notificationsUsable(application)) {
            // A foreground-protected Agent run needs a usable notification.
            // Keep the occurrence pending instead of claiming it and then
            // silently losing the background task.
            choices.setNotice(scheduleID, "notifications_blocked")
            return worker.retryOrFail(
                application, scheduleID, null, "notifications_blocked")
        }
        val exactAllowed = TaskScheduleAlarmScheduler.exactAlarmAllowed(application)
        val flexible = choices.flexibleChosen(scheduleID)
        if (trigger == TaskScheduleDispatchWorker.TRIGGER_EXACT &&
            !exactAllowed && !flexible) {
            // Permission was revoked after arming: do not claim; wait for the
            // user's explicit choice or a re-grant.
            choices.setNotice(scheduleID, "exact_permission")
            TaskScheduleNotifications.postWaitingForExactPermission(
                application, scheduleID, "")
            refreshWakeupsOnce(allowPendingDispatch = true)
            return ListenableWorker.Result.success()
        }
        if (trigger == TaskScheduleDispatchWorker.TRIGGER_FLEXIBLE && !flexible) {
            return ListenableWorker.Result.success()
        }
        val foreground = current.runForeground
            ?: return worker.retryOrFail(
                application, scheduleID, null, "foreground_unavailable")
        val operationID = UUID.randomUUID().toString()
        val guard = TaskScheduleAdmissionGuard()
        // The provisional lease is the ONE user-visible launch window. Its
        // Stop action marks the attempt; pre-submit it aborts before any
        // dispatch, post-submit it is honoured through the canonical run
        // cancel after the authoritative lease is attached.
        val stopsPendingOccurrence =
            trigger == TaskScheduleDispatchWorker.TRIGGER_PENDING
        val provisional = try {
            foreground.agentLaunchProvisional(operationID) {
                guard.onStopRequested()
                // Durable Stop for a PENDING dispatch: cancel the intended
                // occurrence so no observer can resurrect it. An exact/
                // flexible wake has not created its due occurrence yet, so
                // there is nothing to cancel there (future cadence stays).
                if (stopsPendingOccurrence) {
                    scope.launch { cancelPendingDurably(current, scheduleID) }
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            false
        }
        if (!provisional) {
            // The EXISTING foreground authority refused to promote this
            // worker (typically a background FGS start restriction, a blocked
            // notification channel or an owner conflict). No native dispatch
            // is sent, so no occurrence is claimed: the durable row stays
            // pending, the in-app row shows the actionable notice, and this
            // bounded retry/failure path never fabricates a start.
            choices.setNotice(scheduleID, "foreground_unavailable")
            TaskScheduleNotifications.postTransportPending(application, scheduleID, "")
            return worker.retryOrFail(
                application, scheduleID, "", "foreground_unavailable")
        }

        // PRE-SUBMIT: nothing has been handed to the host queue yet, so a
        // cancellation or Stop can release the provisional lease exactly
        // (no command can ever launch a run for this attempt).
        if (guard.stopRequested()) {
            // The handler already launched this; call it directly too so the
            // durable cancellation really precedes the lease release.
            if (stopsPendingOccurrence) cancelPendingDurably(current, scheduleID)
            foreground.agentLaunchDefinitelyNotAdmitted(operationID)
            return ListenableWorker.Result.success()
        }
        val environments = try {
            when (val authority = environmentProvider?.environments()) {
                is TaskScheduleEnvironmentResult.Available -> authority.environments
                // An unreadable authority is NOT an empty list: passing none
                // makes the native gate refuse an environment-bound
                // occurrence with environmentSnapshotMissing instead of
                // substituting another environment.
                is TaskScheduleEnvironmentResult.Unavailable -> emptyList()
                null -> emptyList()
            }
        } catch (cancelled: CancellationException) {
            foreground.agentLaunchDefinitelyNotAdmitted(operationID)
            throw cancelled
        } catch (_: Throwable) {
            emptyList()
        }
        if (guard.stopRequested()) {
            if (stopsPendingOccurrence) cancelPendingDurably(current, scheduleID)
            foreground.agentLaunchDefinitelyNotAdmitted(operationID)
            return ListenableWorker.Result.success()
        }
        if (current.nativeRootEpoch() != epochAtDispatch) {
            // The accepted generation changed before the envelope was handed
            // to the host queue: nothing can have launched for this attempt.
            foreground.agentLaunchDefinitelyNotAdmitted(operationID)
            return ListenableWorker.Result.success()
        }

        val result = try {
            TaskScheduleCommands(current).dispatch(
                scheduleID = scheduleID,
                trigger = trigger,
                exactAlarmAllowed = exactAllowed,
                flexibleChosen = flexible,
                environments = environments,
                expectedEpoch = epochAtDispatch,
                onAccepted = guard::onAccepted,
                onSettled = guard::recordSettled,
            )
        } catch (cancelled: CancellationException) {
            if (guard.wasSubmitted()) {
                // The envelope reached the host queue. The host-owned effect
                // pump still delivers the REAL terminal; keep the provisional
                // lease and hand resolution to the coordinator scope. Never
                // release a receipt that may have produced a run.
                reconcileAdmission(
                    current, foreground, scheduleID, operationID,
                    epochAtDispatch, guard)
            } else {
                // Never admitted by the host queue: no command can launch.
                foreground.agentLaunchDefinitelyNotAdmitted(operationID)
            }
            throw cancelled
        }

        when (guard.effectiveDecision(result)) {
            TaskScheduleAdmissionDecision.ADMIT -> {
                val dispatch = (result as TaskScheduleResult.Ok<TaskScheduleDispatch>).value
                val runID = dispatch.runID
                val conversationID = dispatch.conversationID
                if (current.nativeRootEpoch() != epochAtDispatch) {
                    // The launch terminal belongs to a generation that is no
                    // longer accepted. Never re-acquire that old run (or its
                    // provisional lease) into the new generation; Root
                    // retirement owns the old lease.
                    return ListenableWorker.Result.success()
                }
                if (runID != null && conversationID != null) {
                    // A launch result that reached us MUST transfer coverage
                    // even if WorkManager cancels this coroutine now: attach
                    // the authoritative lease under NonCancellable before
                    // releasing the provisional one.
                    val admitted = try {
                        kotlinx.coroutines.withContext(
                            kotlinx.coroutines.NonCancellable) {
                            // Exact same-generation proof immediately before
                            // lease adoption.
                            if (current.nativeRootEpoch() != epochAtDispatch) {
                                false
                            } else {
                                foreground.agentLaunchAdmitted(
                                    operationID, conversationID, runID)
                            }
                        }
                    } catch (cancelled: CancellationException) {
                        // NonCancellable should not surface this; if it does,
                        // keep the provisional and let the REAL terminal
                        // resolve coverage instead of dropping the run.
                        reconcileAdmission(
                            current, foreground, scheduleID, operationID,
                            epochAtDispatch, guard)
                        throw cancelled
                    } catch (_: Throwable) {
                        false
                    }
                    if (admitted) {
                        choices.setNotice(scheduleID, null)
                        TaskScheduleNotifications.cancel(application, scheduleID)
                        if (guard.claimStopCancellation()) {
                            // Stop arrived while the launch was in flight. The
                            // run owns its authoritative lease now; cancel
                            // through the EXISTING canonical run path, which
                            // settles the lease at the real terminal. The
                            // claim makes this exactly once even if the late
                            // resolver already saw the same Stop.
                            current.conversations.cancelRunFromNotification(
                                conversationID, runID)
                        }
                    } else {
                        // A run launched but the authoritative lease could not
                        // be attached. Keep provisional coverage and resolve
                        // through the durable occurrence ledger; never drop
                        // real work.
                        choices.setNotice(scheduleID, "foreground_unavailable")
                        reconcileAdmission(
                            current, foreground, scheduleID, operationID,
                            epochAtDispatch, guard)
                    }
                } else {
                    // A "launched" outcome without both identities is
                    // UNKNOWN, not a rejection: keep the provisional coverage
                    // and let the real terminal/authoritative lease resolve.
                    choices.setNotice(scheduleID, "foreground_unavailable")
                    reconcileAdmission(
                        current, foreground, scheduleID, operationID,
                        epochAtDispatch, guard)
                }
                refreshWakeupsOnce(allowPendingDispatch = true)
                return ListenableWorker.Result.success()
            }
            TaskScheduleAdmissionDecision.RELEASE -> {
                foreground.agentLaunchDefinitelyNotAdmitted(operationID)
                if (result is TaskScheduleResult.Failure) {
                    if (result.code in TRANSIENT_CODES) {
                        return worker.retryOrFail(
                            application, scheduleID, null, result.code)
                    }
                    choices.setNotice(scheduleID, result.code)
                    TaskScheduleNotifications.postTransportPending(
                        application, scheduleID, "")
                    return ListenableWorker.Result.failure()
                }
                val dispatch = (result as TaskScheduleResult.Ok<TaskScheduleDispatch>).value
                when (dispatch.code) {
                    "exactAlarmPermission" -> {
                        choices.setNotice(scheduleID, "exact_permission")
                        TaskScheduleNotifications.postWaitingForExactPermission(
                            application, scheduleID, "")
                    }
                    "flexibleNotChosen" -> Unit
                    null -> choices.setNotice(scheduleID, null)
                    else -> {
                        choices.setNotice(scheduleID, dispatch.code)
                        TaskScheduleNotifications.postTransportPending(
                            application, scheduleID, "")
                    }
                }
                refreshWakeupsOnce(allowPendingDispatch = true)
                return ListenableWorker.Result.success()
            }
            TaskScheduleAdmissionDecision.RECONCILE -> {
                // Receipt/terminal unconfirmed: keep the provisional lease and
                // let the coordinator-owned resolution adopt a real run or
                // release after a bounded, ledger-backed observation. A retry
                // is safe: it re-dispatches only the SAME pending occurrence
                // (claim CAS collapses duplicates) and never replays an
                // unknown run outcome.
                reconcileAdmission(
                    current, foreground, scheduleID, operationID,
                    epochAtDispatch, guard)
                return worker.retryOrFail(
                    application, scheduleID, "", "dispatch_unconfirmed")
            }
        }
    }

    /**
     * Resolve a submitted-but-unobserved dispatch from the REAL host terminal.
     *
     * A caller timeout/cancellation only closes the worker's observation
     * window; it is NOT a terminal. The host-owned effect pump settles the
     * queued command exactly once, and this application-scoped resolver owns
     * the provisional lease until that actual terminal arrives. There is no
     * guessed "newest occurrence", no elapsed-time release and no blind
     * definitelyNotAdmitted for an unknown receipt; if the Root retires first,
     * `releaseAllForShutdown` owns the lease and its exit is ignored here.
     */
    /** Bounded, best-effort durable Stop. Failure leaves the pending row in
     *  place (no fake cancellation); the post-submit path still protects any
     *  real run. */
    private suspend fun cancelPendingDurably(host: RuntimeHost, scheduleID: String) {
        runCatching { TaskScheduleCommands(host).cancelPending(scheduleID) }
    }

    private fun reconcileAdmission(
        host: RuntimeHost,
        foreground: com.floe.android.host.RunForegroundBinding,
        scheduleID: String,
        operationID: String,
        epochAtDispatch: Long,
        guard: TaskScheduleAdmissionGuard,
    ) {
        // Same instance is NOT the same generation. The coordinator must own
        // this host AND the exact epoch captured at dispatch; a new accepted
        // epoch retires the old resolver before this can adopt anything.
        if (host !== this.host || boundEpoch != epochAtDispatch) return
        val job = scope.launch {
            try {
                // Root-lifecycle bounded: this job lives only while the
                // coordinator does; the exact-epoch check inside the resolver
                // prevents any late re-adoption across a generation change.
                val resolver = TaskScheduleLateAdmissionResolver(
                    guard = guard,
                    dispatchedEpoch = epochAtDispatch,
                    liveEpoch = { host.nativeRootEpoch() },
                    admit = { conversationID, runID ->
                        // Re-check the exact generation immediately before
                        // the authoritative lease is attached.
                        if (host !== this@TaskScheduleCoordinator.host ||
                            host.nativeRootEpoch() != epochAtDispatch) {
                            false
                        } else {
                            foreground.agentLaunchAdmitted(
                                operationID, conversationID, runID)
                        }
                    },
                    release = {
                        foreground.agentLaunchDefinitelyNotAdmitted(operationID)
                    },
                    cancelAdmittedRun = { conversationID, runID ->
                        // The EXISTING canonical run cancel; the guard claim
                        // guarantees this happens at most once for the
                        // attempt even across the live/late paths.
                        host.conversations.cancelRunFromNotification(
                            conversationID, runID)
                    },
                    notice = { code -> choices.setNotice(scheduleID, code) },
                )
                resolver.awaitAndResolve()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                // Unknown transport/state: retain the provisional coverage.
                choices.setNotice(scheduleID, "foreground_unavailable")
            }
        }
        reconciliations.add(job)
        job.invokeOnCompletion { reconciliations.remove(job) }
    }

    suspend fun rearmFromWorker(
        worker: androidx.work.CoroutineWorker,
    ): ListenableWorker.Result {
        if (waitForHost(HOST_WAIT_MILLIS) == null) {
            return worker.retryOrFail(application, "rearm", null, "runtime_unavailable")
        }
        return if (refreshWakeupsOnce(allowPendingDispatch = false)) {
            ListenableWorker.Result.success()
        } else {
            worker.retryOrFail(application, "rearm", null, "rearm_failed")
        }
    }

    // --------------------------------------------------------------- internals

    private suspend fun refreshWakeupsOnce(
        allowPendingDispatch: Boolean,
    ): Boolean = rearmMutex.withLock {
        val current = waitForHost(HOST_WAIT_MILLIS) ?: return@withLock false
        val commands = TaskScheduleCommands(current)
        val rearm = when (val result = commands.rearm()) {
            is TaskScheduleResult.Ok -> result.value
            is TaskScheduleResult.Failure -> return@withLock false
        }
        val exactAllowed = TaskScheduleAlarmScheduler.exactAlarmAllowed(application)
        scheduler.applyPlans(rearm.plans, exactAllowed)
        for (plan in rearm.plans) {
            val waiting = plan.enabled && plan.nextFireAtMillis != null &&
                !exactAllowed && !choices.flexibleChosen(plan.scheduleID)
            if (waiting) {
                choices.setNotice(plan.scheduleID, "exact_permission")
                TaskScheduleNotifications.postWaitingForExactPermission(
                    application, plan.scheduleID, "")
            } else if (choices.notice(plan.scheduleID) == "exact_permission") {
                choices.setNotice(plan.scheduleID, null)
                TaskScheduleNotifications.cancel(application, plan.scheduleID)
            }
        }
        // A pending occurrence (after-success or a crashed manual run) is
        // dispatched ONLY through the worker so the existing foreground
        // binding protects the run. Boot/time re-arm passes false.
        if (allowPendingDispatch) {
            for (scheduleID in rearm.pendingScheduleIDs) {
                TaskScheduleDispatchWorker.enqueue(
                    application, scheduleID, TaskScheduleDispatchWorker.TRIGGER_PENDING)
            }
        }
        return@withLock true
    }

    /**
     * Event-driven after-success drain. The native retire hook enqueues the
     * dependent occurrence durably; this observer notices the owned-work
     * change (blocking native wait, not a busy poller) and asks the service to
     * launch pending occurrences once the runtime is quiescent. Claim CAS
     * handles any overlap with a worker.
     */
    private suspend fun observeOwnedWork(boundHost: RuntimeHost, boundEpoch: Long) {
        var observed = 0L
        while (scope.isActive) {
            // Exact-generation fence: the same host instance survives an
            // accepted root replacement, so a non-null epoch is not enough.
            if (host !== boundHost || boundHost.nativeRootEpoch() != boundEpoch) return
            val changed = try {
                withContext(Dispatchers.IO) {
                    RunForegroundNative.waitChange(observed, 1_000)
                }
            } catch (_: Throwable) {
                delay(1_000)
                continue
            }
            if (changed == observed) continue
            observed = changed
            val snapshot = try {
                withContext(Dispatchers.IO) {
                    RunForegroundWire.parse(RunForegroundNative.snapshot())
                }
            } catch (_: Throwable) {
                null
            } ?: continue
            if (!snapshot.storeReady || snapshot.admissionFenced) continue
            if (snapshot.hasLiveRunOwnedWork) continue
            if (host !== boundHost || boundHost.nativeRootEpoch() != boundEpoch) return
            refreshWakeupsOnce(allowPendingDispatch = true)
        }
    }

    private suspend fun waitForHost(timeoutMillis: Long): RuntimeHost? {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (System.currentTimeMillis() < deadline) {
            val current = host
            if (current != null && current.nativeRootEpoch() != null) return current
            delay(250)
        }
        val current = host
        return current?.takeIf { it.nativeRootEpoch() != null }
    }

    companion object {
        private const val HOST_WAIT_MILLIS = 20_000L
        private val TRANSIENT_CODES = setOf(
            "runtime_unavailable", "timeout", "superseded", "cancelled",
            "store_unavailable", "occurrence_in_flight",
        )
    }
}
