// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meeting

import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File

/**
 * Real MediaPlayer-backed playback for one app-owned material. All player
 * calls are marshalled to the main looper. Media errors are reported from
 * MediaPlayer's own error callback; release is idempotent and drops the native
 * resources even after an error.
 */
internal class MeetingMediaPlayer(
    private val file: File,
    expectedDurationMillis: Long,
) : MeetingPlayer {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val _state = MutableStateFlow(
        MeetingPlayerState(
            status = MeetingPlayerStatus.IDLE,
            positionMillis = 0L,
            durationMillis = expectedDurationMillis.coerceAtLeast(0L),
            error = null,
        ),
    )
    override val state: StateFlow<MeetingPlayerState> = _state.asStateFlow()

    private var player: MediaPlayer? = null
    private var prepared: Boolean = false
    private var released: Boolean = false
    private var autoPlayOnPrepare: Boolean = false
    private var pendingSeekMillis: Long? = null

    private val ticker = object : Runnable {
        override fun run() {
            if (released) return
            val current = player ?: return
            if (_state.value.status != MeetingPlayerStatus.PLAYING) return
            val position = runCatching { current.currentPosition.toLong() }.getOrDefault(0L)
            val duration = runCatching { current.duration.toLong() }.getOrDefault(_state.value.durationMillis)
            _state.value = _state.value.copy(
                positionMillis = position.coerceAtLeast(0L),
                durationMillis = duration.coerceAtLeast(0L),
            )
            mainHandler.postDelayed(this, POSITION_INTERVAL_MILLIS)
        }
    }

    override fun play() {
        mainHandler.post {
            if (released) return@post
            if (prepared) {
                startPlayback()
            } else {
                autoPlayOnPrepare = true
                preparePlayer()
            }
        }
    }

    override fun pause() {
        mainHandler.post {
            if (released) return@post
            autoPlayOnPrepare = false
            val current = player
            if (current != null && prepared && _state.value.status == MeetingPlayerStatus.PLAYING) {
                runCatching { current.pause() }
                stopTicker()
                _state.value = _state.value.copy(
                    status = MeetingPlayerStatus.PAUSED,
                    positionMillis = runCatching { current.currentPosition.toLong() }
                        .getOrDefault(_state.value.positionMillis),
                )
            }
        }
    }

    override fun seekTo(positionMillis: Long) {
        mainHandler.post {
            if (released) return@post
            val target = positionMillis.coerceAtLeast(0L)
            val current = player
            if (current != null && prepared) {
                val duration = runCatching { current.duration.toLong() }.getOrDefault(0L)
                val clamped = if (duration > 0) target.coerceAtMost(duration) else target
                runCatching { current.seekTo(clamped.toInt()) }
                _state.value = _state.value.copy(positionMillis = clamped)
            } else {
                pendingSeekMillis = target
                if (current == null) preparePlayer()
            }
        }
    }

    override fun release() {
        mainHandler.post {
            if (released) return@post
            released = true
            stopTicker()
            releasePlayer()
            _state.value = _state.value.copy(
                status = MeetingPlayerStatus.RELEASED,
                error = _state.value.error,
            )
        }
    }

    private fun preparePlayer() {
        if (released || player != null) return
        if (!file.isFile || file.length() <= 0L) {
            fail(
                MeetingError(
                    code = MeetingErrorCode.MISSING_MEDIA,
                    message = "The recording file is unavailable.",
                    retryable = false,
                ),
            )
            return
        }
        _state.value = _state.value.copy(
            status = MeetingPlayerStatus.PREPARING,
            error = null,
        )
        val created = MediaPlayer()
        player = created
        try {
            created.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            created.setDataSource(file.absolutePath)
            created.setOnPreparedListener {
                onPrepared()
            }
            created.setOnCompletionListener {
                stopTicker()
                _state.value = _state.value.copy(
                    status = MeetingPlayerStatus.ENDED,
                    positionMillis = _state.value.durationMillis,
                )
            }
            created.setOnErrorListener { _, what, extra ->
                fail(
                    MeetingError(
                        code = MeetingErrorCode.PLAYBACK_FAILED,
                        message = "The recording could not be played.",
                        retryable = false,
                        detail = "what=$what extra=$extra",
                    ),
                )
                true
            }
            created.prepareAsync()
        } catch (error: Exception) {
            fail(
                MeetingError(
                    code = MeetingErrorCode.PLAYBACK_FAILED,
                    message = "The recording could not be played.",
                    retryable = false,
                    detail = error.javaClass.simpleName,
                ),
            )
        }
    }

    private fun onPrepared() {
        if (released) return
        val current = player ?: return
        prepared = true
        val duration = runCatching { current.duration.toLong() }.getOrDefault(0L).coerceAtLeast(0L)
        val seek = pendingSeekMillis
        pendingSeekMillis = null
        val position = if (seek != null) {
            val clamped = if (duration > 0) seek.coerceAtMost(duration) else seek
            runCatching { current.seekTo(clamped.toInt()) }
            clamped
        } else {
            0L
        }
        if (autoPlayOnPrepare) {
            startPlayback()
        } else {
            _state.value = _state.value.copy(
                status = MeetingPlayerStatus.PAUSED,
                positionMillis = position,
                durationMillis = duration,
            )
        }
    }

    private fun startPlayback() {
        val current = player ?: return
        if (!prepared || released) return
        try {
            current.start()
        } catch (error: Exception) {
            fail(
                MeetingError(
                    code = MeetingErrorCode.PLAYBACK_FAILED,
                    message = "The recording could not be played.",
                    retryable = false,
                    detail = error.javaClass.simpleName,
                ),
            )
            return
        }
        _state.value = _state.value.copy(
            status = MeetingPlayerStatus.PLAYING,
            error = null,
        )
        stopTicker()
        mainHandler.post(ticker)
    }

    private fun stopTicker() {
        mainHandler.removeCallbacks(ticker)
    }

    private fun fail(error: MeetingError) {
        if (released) return
        stopTicker()
        releasePlayer()
        _state.value = _state.value.copy(
            status = MeetingPlayerStatus.ERROR,
            error = error,
        )
    }

    private fun releasePlayer() {
        val current = player
        player = null
        prepared = false
        if (current != null) {
            runCatching { current.reset() }
            runCatching { current.release() }
        }
    }

    private companion object {
        const val POSITION_INTERVAL_MILLIS = 250L
    }
}
