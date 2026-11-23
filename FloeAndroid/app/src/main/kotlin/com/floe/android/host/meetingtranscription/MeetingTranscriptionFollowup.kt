// SPDX-License-Identifier: MPL-2.0
//
// Recording-stop follow-up coordinator for the meeting cloud transcription.
//
// The cloud transcription owner (MeetingTranscriptionManager) is process-wide
// and admits exactly one attempt, so a recording that stops while another
// transcription is still running cannot start immediately. This coordinator
// closes that drain without ever touching the provider itself:
//
//  * [onStoppedMaterial] decides, from the durable meeting detail, whether a
//    gracefully stopped, playable take should be transcribed. It is a pure
//    decision: no cloud call, no storage write. A take that already has a
//    committed transcript is never re-requested (no duplicate cost); an
//    incomplete/unplayable take is never requested at all.
//  * [enqueue]/[nextAfterSettle] reconcile restarts. A newer stop for the same
//    meeting replaces its still-queued follow-up (the older material is
//    superseded); a stop for another meeting waits its turn in FIFO order, so
//    no follow-up silently disappears while the single process attempt drains.
//  * [shouldAwaitMinutes] is the final-minutes gate: while a transcription for
//    this meeting is still running, minutes generated now would read an
//    interim transcript, so the caller waits for the terminal receipt and then
//    reads the refreshed detail. A late transcript therefore always folds into
//    the next minutes rather than being suppressed by an earlier summary.
//  * [dropMeeting] fences a deleted meeting so no late follow-up can rebuild it.
//
// All decisions are pure functions of the durable detail and the observable
// transcription state; the Compose layer only starts what this class returns.
package com.floe.android.host.meetingtranscription

import com.floe.android.host.meeting.MeetingDetail
import com.floe.android.host.meeting.MeetingMaterial
import com.floe.android.host.meeting.MeetingMaterialStatus
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * One follow-up transcription the caller should try to [start] on the process
 * manager. [expectedTranscriptionRevision] is the meeting transcript revision
 * observed when the take stopped; the manager re-checks it at commit time.
 */
internal data class MeetingTranscriptionFollowupRequest(
    val meetingId: String,
    val materialId: String,
    val expectedTranscriptionRevision: Long?,
)

internal class MeetingTranscriptionFollowup {
    private val lock = Any()
    private val queued = LinkedHashMap<String, MeetingTranscriptionFollowupRequest>()
    private var starting: MeetingTranscriptionFollowupRequest? = null
    private val _pending = MutableStateFlow<Set<String>>(emptySet())
    val pending = _pending.asStateFlow()

    private fun publish() { _pending.value = queued.keys + listOfNotNull(starting?.meetingId) }

    fun beginNext(): MeetingTranscriptionFollowupRequest? = synchronized(lock) {
        val next = queued.keys.firstOrNull() ?: return null
        queued.remove(next)?.also { starting = it; publish() }
    }

    fun isStarting(request: MeetingTranscriptionFollowupRequest): Boolean =
        synchronized(lock) { starting == request && !queued.containsKey(request.meetingId) }

    fun finishStarting(request: MeetingTranscriptionFollowupRequest, busy: Boolean) = synchronized(lock) {
        if (starting == request) {
            starting = null
            if (busy && !queued.containsKey(request.meetingId)) enqueue(request)
            publish()
        }
    }

    fun clear() = synchronized(lock) { queued.clear(); starting = null; publish() }


    /**
     * Decides the follow-up for one gracefully stopped take. Returns null when
     * no transcription should start: auto-transcribe is off, the take is not a
     * playable completed file, or the transcript for exactly this material is
     * already committed. The caller tries to start a non-null result; a Busy
     * answer must be passed to [enqueue].
     */
    fun onStoppedMaterial(
        detail: MeetingDetail,
        material: MeetingMaterial,
        autoTranscribe: Boolean,
    ): MeetingTranscriptionFollowupRequest? {
        if (!autoTranscribe) return null
        if (material.meetingId != detail.id) return null
        if (material.status != MeetingMaterialStatus.COMPLETED || !material.isPlayable) return null
        val transcription = detail.transcription
        if (transcription.materialId == material.id &&
            transcription.revision > 0L &&
            transcription.segments.isNotEmpty()
        ) {
            // Already transcribed: restarting would pay for the same content.
            return null
        }
        return MeetingTranscriptionFollowupRequest(
            meetingId = detail.id,
            materialId = material.id,
            expectedTranscriptionRevision = transcription.revision,
        )
    }

    /** Remembers a follow-up whose start was refused because another attempt owns the process slot. */
    fun enqueue(request: MeetingTranscriptionFollowupRequest) {
        synchronized(lock) {
            // Newest material for a meeting wins; a different meeting keeps its
            // own slot and FIFO position.
            queued[request.meetingId] = request
            while (queued.size > MAX_QUEUED) {
                queued.remove(queued.keys.first())
            }
            publish()
        }
    }

    /**
     * Clears any still-queued follow-up for [meetingId] after a direct start
     * succeeded: the started material supersedes an older queued take for the
     * same meeting. Idempotent.
     */
    fun onStarted(meetingId: String) {
        synchronized(lock) { queued.remove(meetingId); publish() }
    }

    /**
     * Returns the next follow-up to start once the process-wide attempt has
     * settled, or null when nothing waits. FIFO across meetings; the returned
     * request is removed, so a failed retry does not loop silently.
     */
    fun nextAfterSettle(): MeetingTranscriptionFollowupRequest? = synchronized(lock) {
        val first = queued.keys.firstOrNull() ?: return null
        queued.remove(first).also { publish() }
    }

    /** Drops exactly this meeting's queued follow-up; idempotent. */
    fun dropMeeting(meetingId: String) {
        synchronized(lock) {
            queued.remove(meetingId)
            if (starting?.meetingId == meetingId) starting = null
            publish()
        }
    }

    /**
     * True while minutes must wait for this meeting's transcription to reach a
     * terminal receipt. Only a session that belongs to exactly this meeting
     * gates it; another meeting's attempt never blocks this meeting's minutes.
     */
    fun shouldAwaitMinutes(meetingId: String, state: MeetingTranscriptionState): Boolean =
        state.session?.meetingId == meetingId && isRunningPhase(state.phase)

    private fun isRunningPhase(phase: MeetingTranscriptionPhase): Boolean = when (phase) {
        MeetingTranscriptionPhase.PREPARING,
        MeetingTranscriptionPhase.TRANSCRIBING,
        MeetingTranscriptionPhase.FINALIZING,
        MeetingTranscriptionPhase.CANCELLING,
        -> true
        else -> false
    }

    private companion object {
        const val MAX_QUEUED = 8
    }
}
