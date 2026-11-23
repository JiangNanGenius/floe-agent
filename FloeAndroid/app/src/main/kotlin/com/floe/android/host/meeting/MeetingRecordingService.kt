// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meeting

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.ServiceCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Non-exported microphone foreground service and the only audio writer.
 *
 * The service starts only after the controller verified RECORD_AUDIO and ran
 * from a user-visible context. Android may still refuse the background start
 * (while-in-use / FGS launch restrictions); that refusal is reported and no
 * audio is silently captured. The service does not restart after process death
 * (`START_NOT_STICKY`) and the next launch marks retained `.part` files as
 * INCOMPLETE instead of resuming them.
 */
class MeetingRecordingService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var ticker: Job? = null
    private var finishing = false
    // Incremented by every START. A delayed finish from an older start/stop
    // path is ignored, so it cannot tear down a newer recording.
    private var commandGeneration = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        MeetingRecordingNotifications.ensureChannel(this)
        MeetingRecordingRuntime.errorHandler = { handleRecorderError() }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action != null && action != ACTION_START) {
            // A notification command may arrive through
            // PendingIntent.getForegroundService. Re-assert the foreground
            // contract before any early stop path, including a stale intent
            // whose recording no longer exists.
            ensureForegroundForCommand()
        }
        when (action) {
            ACTION_START -> handleStart(intent)
            ACTION_PAUSE -> handleControl(intent) { context -> MeetingRecordingRuntime.pause(context) }
            ACTION_RESUME -> handleControl(intent) { context -> MeetingRecordingRuntime.resume(context) }
            ACTION_STOP -> handleStop(intent)
            ACTION_DISCARD -> handleDiscard(intent)
            ACTION_CANCEL_LIVE -> handleCancelLive(intent)
            else -> if (!MeetingRecordingRuntime.isActive) finishForeground(commandGeneration)
        }
        return START_NOT_STICKY
    }

    private fun handleStart(intent: Intent) {
        val meetingId = intent.getStringExtra(EXTRA_MEETING_ID)
        val recordingId = intent.getStringExtra(EXTRA_RECORDING_ID)
        if (meetingId == null || recordingId == null ||
            !MeetingIds.isValid(meetingId) || !MeetingIds.isValid(recordingId)
        ) {
            // An invalid start must not supersede the active generation.
            finishForeground(commandGeneration)
            return
        }
        if (MeetingRecordingRuntime.isActive) {
            // A duplicate intent for the SAME live generation is ignored. A
            // different draft is rejected without touching the active owner.
            if (!MeetingRecordingRuntime.matchesOwner(meetingId, recordingId)) {
                scope.launch {
                    withContext(Dispatchers.IO) {
                        runCatching {
                            MeetingStoreRegistry.get(applicationContext).repository
                                .failRecordingStart(meetingId, recordingId, "busy")
                        }
                    }
                    MeetingRecordingNotifications.update(
                        this@MeetingRecordingService,
                        MeetingRecordingRuntime.state.value,
                    )
                }
            }
            return
        }
        finishing = false
        val generation = ++commandGeneration
        val starting = MeetingRecordingState(
            phase = MeetingRecordingPhase.STARTING,
            meetingId = meetingId,
            recordingId = recordingId,
            startedAtMillis = null,
            elapsedMillis = 0L,
            error = null,
        )
        val notification = MeetingRecordingNotifications.build(this, starting)
        try {
            ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, foregroundType())
        } catch (_: Exception) {
            cleanupDeniedStart(meetingId, recordingId, generation)
            return
        }
        scope.launch {
            val started = MeetingRecordingRuntime.begin(
                context = applicationContext,
                meetingId = meetingId,
                recordingId = recordingId,
                liveCloudTranscription = intent.getBooleanExtra(EXTRA_LIVE_CLOUD, false),
            )
            if (!started) {
                val state = MeetingRecordingRuntime.state.value
                val handledByThisStart = state.phase == MeetingRecordingPhase.FAILED &&
                    state.recordingId == recordingId
                if (!handledByThisStart && !MeetingRecordingRuntime.matchesOwner(meetingId, recordingId)) {
                    // begin() refused this draft because another generation
                    // owns the microphone. Retire only the rejected draft.
                    withContext(Dispatchers.IO) {
                        runCatching {
                            MeetingStoreRegistry.get(applicationContext).repository
                                .failRecordingStart(meetingId, recordingId, "startRejected")
                        }
                    }
                }
                if (MeetingRecordingRuntime.isActive) {
                    MeetingRecordingNotifications.update(
                        this@MeetingRecordingService,
                        MeetingRecordingRuntime.state.value,
                    )
                } else {
                    finishForeground(generation)
                }
                return@launch
            }
            startTicker()
            MeetingRecordingNotifications.update(
                this@MeetingRecordingService,
                MeetingRecordingRuntime.state.value,
            )
        }
    }

    private fun handleControl(intent: Intent, block: suspend (Context) -> Unit) {
        val generation = commandGeneration
        if (!matchesActiveIntent(intent)) {
            if (!MeetingRecordingRuntime.isActive) finishForeground(generation)
            return
        }
        reassertForeground()
        scope.launch {
            runCatching { block(applicationContext) }
            MeetingRecordingNotifications.update(
                this@MeetingRecordingService,
                MeetingRecordingRuntime.state.value,
            )
            if (MeetingRecordingRuntime.isActive) {
                startTicker()
            } else {
                finishForeground(generation)
            }
        }
    }

    private fun handleStop(intent: Intent) {
        val generation = commandGeneration
        val meetingId = intent.getStringExtra(EXTRA_MEETING_ID)
        val recordingId = intent.getStringExtra(EXTRA_RECORDING_ID)
        if (!matchesActiveIntent(intent)) {
            if (!MeetingRecordingRuntime.isActive) finishForeground(generation)
            return
        }
        if (!MeetingRecordingRuntime.isActive) {
            // STARTING has no session yet: cancel that exact start instead of
            // throwing, so a timed-out start cannot begin recording later.
            if (meetingId != null && recordingId != null &&
                MeetingRecordingRuntime.cancelPendingStart(meetingId, recordingId)
            ) {
                MeetingRecordingNotifications.update(
                    this,
                    MeetingRecordingRuntime.state.value,
                )
                return
            }
            finishForeground(generation)
            return
        }
        reassertForeground()
        scope.launch {
            runCatching { MeetingRecordingRuntime.stop(applicationContext) }
            MeetingRecordingNotifications.update(
                this@MeetingRecordingService,
                MeetingRecordingRuntime.state.value,
            )
            finishForeground(generation)
        }
    }

    private fun handleDiscard(intent: Intent) {
        val generation = commandGeneration
        val meetingId = intent.getStringExtra(EXTRA_MEETING_ID)
        val recordingId = intent.getStringExtra(EXTRA_RECORDING_ID)
        if (!matchesActiveIntent(intent)) {
            if (!MeetingRecordingRuntime.isActive) finishForeground(generation)
            return
        }
        if (!MeetingRecordingRuntime.isActive) {
            if (meetingId != null && recordingId != null &&
                MeetingRecordingRuntime.cancelPendingStart(meetingId, recordingId)
            ) {
                MeetingRecordingNotifications.update(
                    this,
                    MeetingRecordingRuntime.state.value,
                )
                return
            }
            finishForeground(generation)
            return
        }
        reassertForeground()
        scope.launch {
            runCatching { MeetingRecordingRuntime.discard(applicationContext) }
            finishForeground(generation)
        }
    }

    private fun handleCancelLive(intent: Intent) {
        if (!matchesActiveIntent(intent)) {
            if (!MeetingRecordingRuntime.isActive) finishForeground(commandGeneration)
            return
        }
        reassertForeground()
        scope.launch {
            runCatching { MeetingRecordingRuntime.cancelLiveCloudTranscription(applicationContext) }
            MeetingRecordingNotifications.update(
                this@MeetingRecordingService,
                MeetingRecordingRuntime.state.value,
            )
        }
    }

    private fun handleRecorderError() {
        val generation = commandGeneration
        scope.launch {
            val detail = MeetingRecordingRuntime.state.value.error?.detail ?: "recorderError"
            runCatching { MeetingRecordingRuntime.stopAfterError(applicationContext, detail) }
            MeetingRecordingNotifications.update(
                this@MeetingRecordingService,
                MeetingRecordingRuntime.state.value,
            )
            finishForeground(generation)
        }
    }

    private fun startTicker() {
        if (ticker?.isActive == true) return
        ticker = scope.launch {
            while (isActive) {
                delay(1_000L)
                if (!MeetingRecordingRuntime.isActive) break
                MeetingRecordingRuntime.tick()
                MeetingRecordingNotifications.update(
                    this@MeetingRecordingService,
                    MeetingRecordingRuntime.state.value,
                )
            }
        }
    }

    private fun ensureForegroundForCommand() {
        if (MeetingRecordingRuntime.isActive) return
        runCatching {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                MeetingRecordingNotifications.build(this, MeetingRecordingRuntime.state.value),
                foregroundType(),
            )
        }
    }

    private fun reassertForeground() {
        runCatching {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                MeetingRecordingNotifications.build(this, MeetingRecordingRuntime.state.value),
                foregroundType(),
            )
        }
    }

    private fun matchesActiveIntent(intent: Intent): Boolean =
        MeetingRecordingRuntime.matchesOwner(
            intent.getStringExtra(EXTRA_MEETING_ID),
            intent.getStringExtra(EXTRA_RECORDING_ID),
        )

    private fun cleanupDeniedStart(meetingId: String, recordingId: String, generation: Long) {
        // startForeground was refused, so the service is not protected; do a
        // bounded synchronous metadata cleanup before stopping, and rely on
        // crash recovery if even that write cannot finish.
        runCatching {
            runBlocking {
                withTimeoutOrNull(2_000L) {
                    withContext(Dispatchers.IO) {
                        MeetingStoreRegistry.get(applicationContext).repository
                            .failRecordingStart(meetingId, recordingId, "foregroundDenied")
                    }
                }
            }
        }
        // A concurrent, already-started recording owns the service; a denied
        // second start must not tear it down.
        if (MeetingRecordingRuntime.isActive) {
            MeetingRecordingNotifications.update(
                this,
                MeetingRecordingRuntime.state.value,
            )
        } else {
            finishForeground(generation)
        }
    }

    /**
     * Stops only the service generation that requested it. A newer START has
     * already incremented [commandGeneration]; a delayed terminal callback from
     * the previous take cannot remove that recording's foreground service.
     */
    private fun finishForeground(generation: Long) {
        if (generation != commandGeneration) return
        if (finishing) return
        if (MeetingRecordingRuntime.isActive) return
        val phase = MeetingRecordingRuntime.state.value.phase
        if (phase == MeetingRecordingPhase.STARTING || phase == MeetingRecordingPhase.STOPPING) return
        finishing = true
        ticker?.cancel()
        ticker = null
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        MeetingRecordingNotifications.cancel(this)
        stopSelf()
    }

    private fun foregroundType(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        } else {
            0
        }

    override fun onDestroy() {
        ticker?.cancel()
        ticker = null
        MeetingRecordingRuntime.errorHandler = null
        if (MeetingRecordingRuntime.isActive) {
            MeetingRecordingRuntime.onServiceDestroyed(applicationContext)
        }
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        MeetingRecordingNotifications.cancel(this)
        scope.cancel()
        super.onDestroy()
    }

    companion object {
        internal const val ACTION_START = "com.floe.android.host.meeting.RECORD_START"
        internal const val ACTION_PAUSE = "com.floe.android.host.meeting.RECORD_PAUSE"
        internal const val ACTION_RESUME = "com.floe.android.host.meeting.RECORD_RESUME"
        internal const val ACTION_STOP = "com.floe.android.host.meeting.RECORD_STOP"
        internal const val ACTION_DISCARD = "com.floe.android.host.meeting.RECORD_DISCARD"
        internal const val EXTRA_MEETING_ID = "com.floe.android.host.meeting.extra.MEETING_ID"
        internal const val EXTRA_RECORDING_ID = "com.floe.android.host.meeting.extra.RECORDING_ID"
        internal const val EXTRA_LIVE_CLOUD = "com.floe.android.host.meeting.extra.LIVE_CLOUD"
        internal const val ACTION_CANCEL_LIVE = "com.floe.android.host.meeting.RECORD_CANCEL_LIVE"
        internal const val NOTIFICATION_ID = MeetingRecordingNotifications.NOTIFICATION_ID
    }
}
