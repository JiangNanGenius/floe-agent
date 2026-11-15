// SPDX-License-Identifier: MPL-2.0
//
// App host adapter for THIS task's finite background jobs. It owns ONLY
// correlation, bounds and owner fencing: the native job service/store remains
// the sole authority, and the durable projection it publishes is exactly the
// re-read reply (no optimistic terminal, no invented progress).
package com.floe.android.host.jobs

import com.floe.android.bridge.SwiftCore
import com.floe.android.host.ConversationFlowHolderEntry
import com.floe.android.host.RuntimeHost
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal class BackgroundJobsHostController(
    private val host: RuntimeHost,
) {
    /** One in-flight bounded read per conversation. */
    private val refreshes = ConcurrentHashMap<String, Job>()
    /** One in-flight cancel per exact job id. */
    private val cancellations = ConcurrentHashMap<String, Job>()

    /**
     * Start ONE bounded durable read for this holder. Returns true when the
     * read was dispatched; a second concurrent read for the same conversation
     * is refused (the UI latch also hides the action). [quiet] skips the
     * visible loading flip for the waiting-run observation poll.
     */
    fun refresh(entry: ConversationFlowHolderEntry, quiet: Boolean = false): Boolean {
        val session = entry.holder.session
        val conversationId = session.conversationId
        val epoch = host.nativeRootEpoch() ?: return false
        if (entry.holder.retired || entry.isTemporary || epoch <= 0L) return false
        if (refreshes.containsKey(conversationId)) return false
        val generation = host.commandClient.generation()
        if (!quiet) {
            entry.builder.backgroundJobsListingStarted()
            entry.holder.applyHostSnapshot(entry.builder.build())
        }
        val job = host.scope.launch(
            host.ioDispatcher,
            start = CoroutineStart.LAZY,
        ) {
            var snapshot: BackgroundJobsWire.Snapshot? = null
            try {
                val request = BackgroundJobsWire.listRequest(
                    requestID = host.commandClient.correlationID("jobs"),
                    epoch = epoch,
                    conversationID = conversationId,
                )
                snapshot = if (request.toByteArray(Charsets.UTF_8).size >
                    BackgroundJobsWire.MAX_REQUEST_BYTES
                ) {
                    BackgroundJobsWire.Snapshot(emptyList(), false, "requestTooLarge")
                } else {
                    BackgroundJobsWire.parse(SwiftCore.exchange(request))
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                snapshot = BackgroundJobsWire.Snapshot(
                    emptyList(), false, "jobsUnavailable")
            } finally {
                refreshes.remove(conversationId, currentCoroutineContext()[Job])
                // A cancelled coroutine (retired surface/app scope) carries no
                // result and must not publish a synthetic failure.
                val result = snapshot
                if (result != null) {
                    withContext(NonCancellable + Dispatchers.Main.immediate) {
                        if (!ownerCurrent(entry, session, epoch, generation)) {
                            return@withContext
                        }
                        if (result.error != null) {
                            entry.builder.applyBackgroundJobsFailure(result.error)
                        } else {
                            if (!quiet) {
                                val terminalCount = result.jobs.count { it.terminal }
                                android.util.Log.i("FloeTaskJobs",
                                    "list jobs=${result.jobs.size} terminal=$terminalCount " +
                                        "nonterminal=${result.jobs.size - terminalCount} " +
                                        "truncated=${result.truncated}")
                            }
                            entry.builder.applyBackgroundJobs(
                                result.jobs, result.truncated, null)
                        }
                        entry.holder.applyHostSnapshot(entry.builder.build())
                    }
                }
            }
        }
        refreshes[conversationId] = job
        job.start()
        return true
    }

    /**
     * Exact-identity cooperative Cancel. The native owner re-proves the
     * durable run ownership; the reply is the refreshed durable projection, so
     * the row can stay nonterminal ("cancelling") exactly as the processor
     * reports.
     */
    fun cancel(entry: ConversationFlowHolderEntry, jobId: String, runId: String): Boolean {
        val session = entry.holder.session
        val conversationId = session.conversationId
        val epoch = host.nativeRootEpoch() ?: return false
        if (entry.holder.retired || entry.isTemporary || epoch <= 0L) return false
        if (jobId.isBlank() || runId.isBlank()) return false
        val key = "$conversationId:$jobId"
        if (cancellations.containsKey(key)) return false
        val generation = host.commandClient.generation()
        val job = host.scope.launch(
            host.ioDispatcher,
            start = CoroutineStart.LAZY,
        ) {
            var snapshot: BackgroundJobsWire.Snapshot? = null
            var actionError: String? = null
            try {
                val request = BackgroundJobsWire.cancelRequest(
                    requestID = host.commandClient.correlationID("jobcancel"),
                    epoch = epoch,
                    conversationID = conversationId,
                    runID = runId,
                    jobID = jobId,
                )
                if (request.toByteArray(Charsets.UTF_8).size >
                    BackgroundJobsWire.MAX_REQUEST_BYTES
                ) {
                    actionError = "requestTooLarge"
                } else {
                    val parsed = BackgroundJobsWire.parse(SwiftCore.exchange(request))
                    snapshot = parsed
                    actionError = parsed.error
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                actionError = "jobsUnavailable"
            } finally {
                cancellations.remove(key, currentCoroutineContext()[Job])
                val result = snapshot
                val failure = actionError
                withContext(NonCancellable + Dispatchers.Main.immediate) {
                    if (ownerCurrent(entry, session, epoch, generation)) {
                        if (result != null && result.error == null) {
                            entry.builder.applyBackgroundJobs(
                                result.jobs, result.truncated, null)
                        } else if (result != null && result.error != null) {
                            entry.builder.applyBackgroundJobsFailure(result.error)
                        }
                        if (failure != null) {
                            entry.builder.applyBackgroundJobActionFailure(failure)
                        }
                        if (result != null || failure != null) {
                            entry.holder.applyHostSnapshot(entry.builder.build())
                        }
                        entry.holder.applyBackgroundJobActionSettled(jobId)
                    }
                }
            }
        }
        cancellations[key] = job
        job.start()
        return true
    }

    /** Cancel/refresh latches that must be cleared when the surface retires. */
    fun clearFor(conversationId: String) {
        refreshes.remove(conversationId)?.cancel()
        val prefix = "$conversationId:"
        for (key in cancellations.keys.filter { it.startsWith(prefix) }) {
            cancellations.remove(key)?.cancel()
        }
    }

    private fun ownerCurrent(
        entry: ConversationFlowHolderEntry,
        session: com.floe.android.feature.conversation.ConversationSessionToken,
        epoch: Long,
        generation: Long,
    ): Boolean = !entry.holder.retired &&
        entry.holder.session == session &&
        host.nativeRootEpoch() == epoch &&
        host.commandClient.generation() == generation
}
