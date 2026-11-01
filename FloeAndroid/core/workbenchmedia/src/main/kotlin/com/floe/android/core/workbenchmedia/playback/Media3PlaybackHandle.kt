// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.playback

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.Surface
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.Size
import androidx.media3.transformer.CompositionPlayer
import com.floe.android.core.workbenchmedia.AuthorityDecision
import com.floe.android.core.workbenchmedia.MediaLifecycleKind
import com.floe.android.core.workbenchmedia.MediaLifecyclePin
import com.floe.android.core.workbenchmedia.MediaLifecyclePinRequest
import com.floe.android.core.workbenchmedia.WorkbenchLeaseAuthority
import com.floe.android.core.workbenchmedia.WorkbenchMediaPlatformConfig
import com.floe.android.core.workbenchmedia.lifecycle.LifecyclePinTracker
import com.floe.android.core.workbenchmedia.snapshot.SnapshotExpectation
import com.floe.android.core.workbenchmedia.snapshot.SnapshotVerifier
import com.floe.android.core.workbenchmedia.util.MediaRefusal
import com.floe.android.core.workbenchmedia.util.RENDERER_UNAVAILABLE
import com.floe.android.core.workbenchmedia.video.CompositionPlanner
import com.floe.android.core.workbenchmedia.video.Media3CompositionFactory
import com.floe.android.feature.workbench.MediaExportBinding
import com.floe.android.feature.workbench.PlaybackHandle
import com.floe.android.feature.workbench.PlaybackListener
import com.floe.android.feature.workbench.PlaybackRequest
import com.floe.android.feature.workbench.PlaybackState
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Retained Media3 `CompositionPlayer` for one immutable snapshot. It plays the
 * SAME `Composition` object used by Transformer export; surface attach/detach
 * does not close the editor, and the handle owns no project file writes.
 */
internal class Media3PlaybackHandle(
    context: Context,
    private val config: WorkbenchMediaPlatformConfig,
    private val authority: WorkbenchLeaseAuthority,
    private val planner: CompositionPlanner,
    private val request: PlaybackRequest,
    private val pins: LifecyclePinTracker,
) : PlaybackHandle {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + config.ioDispatcher)
    private val stateRef = AtomicReference(
        PlaybackState(isBuffering = true),
    )
    private val listeners = CopyOnWriteArrayList<PlaybackListener>()
    private val closed = AtomicBoolean(false)
    private var prepareJob: Job? = null
    private var player: CompositionPlayer? = null
    @Volatile private var surface: Surface? = null
    @Volatile private var surfaceWidth = 0
    @Volatile private var surfaceHeight = 0
    @Volatile private var playWhenReady = false
    @Volatile private var durationSeconds = 0.0
    private val pinRef = AtomicReference<MediaLifecyclePin?>(null)
    private val prepareDone = AtomicBoolean(false)
    private val playerReleased = AtomicBoolean(false)
    private val handedOff = AtomicBoolean(false)

    private val ticker = object : Runnable {
        override fun run() {
            if (closed.get()) return
            emit()
            mainHandler.postDelayed(this, 250L)
        }
    }

    private val playerListener = object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) {
            emit()
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            emit()
        }

        override fun onPlayerError(error: PlaybackException) {
            update(
                stateRef.get().copy(
                    isBuffering = false,
                    isPlaying = false,
                    errorCode = RENDERER_UNAVAILABLE,
                ),
            )
        }
    }

    init {
        val created = runOnMain {
            CompositionPlayer.Builder(context)
                .setLooper(Looper.getMainLooper())
                .build()
                .also { it.addListener(playerListener) }
        }
        player = created
        mainHandler.post(ticker)
        prepareJob = scope.launch { prepare() }
    }

    override val state: PlaybackState get() = stateRef.get()

    override fun attachSurface(surface: Surface, width: Int, height: Int): Boolean {
        if (closed.get() || width <= 0 || height <= 0) return false
        this.surface = surface
        surfaceWidth = width
        surfaceHeight = height
        val current = player ?: return false
        runOnMain {
            if (!closed.get()) {
                current.setVideoSurface(surface, Size(width, height))
            }
        }
        return !closed.get()
    }

    override fun detachSurface() {
        surface = null
        val current = player ?: return
        runOnMain { if (!closed.get()) current.clearVideoSurface() }
    }

    override fun seekTo(positionSeconds: Double) {
        if (closed.get()) return
        val target = positionSeconds.coerceAtLeast(0.0).let {
            if (durationSeconds > 0.0) it.coerceAtMost(durationSeconds) else it
        }
        val current = player ?: return
        runOnMain { if (!closed.get()) runCatching { current.seekTo((target * 1000.0).toLong()) } }
    }

    override fun play() {
        if (closed.get()) return
        playWhenReady = true
        val current = player ?: return
        runOnMain { if (!closed.get()) current.play() }
    }

    override fun pause() {
        if (closed.get()) return
        playWhenReady = false
        val current = player ?: return
        runOnMain { if (!closed.get()) current.pause() }
    }

    override fun subscribe(listener: PlaybackListener): AutoCloseable {
        if (closed.get()) return AutoCloseable { }
        listeners += listener
        listener.onPlaybackState(stateRef.get())
        return AutoCloseable { listeners.remove(listener) }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        prepareJob?.cancel()
        scope.cancel()
        mainHandler.removeCallbacks(ticker)
        val current = player
        player = null
        val releasedOk = if (current == null) {
            true
        } else {
            runCatching {
                runOnMain {
                    runCatching { current.removeListener(playerListener) }
                    runCatching { current.release() }.isSuccess
                }
            }.getOrDefault(false)
        }
        playerReleased.set(releasedOk)
        stateRef.set(stateRef.get().copy(isBuffering = false, isPlaying = false))
        maybeReleasePin()
    }

    private suspend fun prepare() {
        try {
            val binding: MediaExportBinding = request.binding
            val decision = authority.validateRenderBinding(binding)
            val grant = when (decision) {
                is AuthorityDecision.Accepted -> decision.grant
                is AuthorityDecision.Refused -> throw MediaRefusal(
                    decision.code, decision.reason, decision.retryable,
                )
            }
            // Pin before the snapshot verifier reads project bytes or the
            // player is handed a composition. The pin stays owned until the
            // player has actually been released.
            val pin = pins.acquire(
                MediaLifecyclePinRequest(
                    context = binding.context,
                    kind = MediaLifecycleKind.PLAYBACK,
                    epoch = grant.epoch,
                    mediaRootPath = grant.mediaRootPath,
                    attemptID = binding.attemptID,
                ),
            )
            pinRef.set(pin)
            if (closed.get()) {
                releasePinNow()
                return
            }
            val snapshot = SnapshotVerifier.verify(
                SnapshotExpectation(
                    epoch = grant.epoch,
                    projectID = binding.context.projectID,
                    revision = binding.projectRevision,
                    timelineDigest = binding.timelineDigest,
                    mediaRootPath = binding.mediaRootPath,
                    attemptID = binding.attemptID,
                    lease = binding.snapshot,
                ),
                grant,
                MediaClockAdapter(config),
            )
            val builtPlan = planner.planForPlayback(snapshot)
            durationSeconds = builtPlan.durationSeconds
            val composition = Media3CompositionFactory.build(builtPlan)
            val current = player ?: return
            runOnMain {
                if (closed.get()) return@runOnMain
                current.setComposition(composition)
                handedOff.set(true)
                current.prepare()
                surface?.let { current.setVideoSurface(it, Size(surfaceWidth, surfaceHeight)) }
                val start = (request.startAtSeconds ?: builtPlan.coverTimeSeconds ?: 0.0)
                    .coerceIn(0.0, builtPlan.durationSeconds)
                if (start > 0.0) current.seekTo((start * 1000.0).toLong())
                if (playWhenReady) current.play()
            }
            update(stateRef.get().copy(isBuffering = false))
        } catch (failure: MediaRefusal) {
            if (!handedOff.get()) releasePinNow()
            if (closed.get()) return
            update(
                stateRef.get().copy(
                    isBuffering = false,
                    isPlaying = false,
                    errorCode = failure.code,
                ),
            )
        } catch (_: kotlinx.coroutines.CancellationException) {
            // handle close cancels preparation; the pin is released only after
            // the actual snapshot/player read path has returned.
            if (!handedOff.get()) releasePinNow()
        } catch (_: Throwable) {
            if (!handedOff.get()) releasePinNow()
            if (!closed.get()) {
                update(
                    stateRef.get().copy(
                        isBuffering = false,
                        isPlaying = false,
                        errorCode = RENDERER_UNAVAILABLE,
                    ),
                )
            }
        } finally {
            prepareDone.set(true)
            maybeReleasePin()
        }
    }

    /**
     * Release is deferred until the preparation coroutine has returned and the
     * player release actually succeeded. A blocking snapshot read or a failed
     * player release therefore keeps the native pin owned for session drain.
     */
    private fun maybeReleasePin() {
        if (closed.get() && prepareDone.get() && playerReleased.get()) {
            releasePinNow()
        }
    }

    private fun releasePinNow() {
        val pin = pinRef.getAndSet(null) ?: return
        pins.releaseAsync(pin)
    }

    private fun emit() {
        if (closed.get()) return
        val current = player ?: return
        val currentState = current.playbackState
        val position = runCatching { current.currentPosition / 1000.0 }.getOrDefault(0.0)
        val duration = runCatching { current.duration / 1000.0 }.getOrDefault(-1.0)
        if (duration > 0.0) durationSeconds = duration
        update(
            PlaybackState(
                positionSeconds = position.coerceAtLeast(0.0),
                durationSeconds = durationSeconds,
                isPlaying = current.isPlaying,
                isBuffering = currentState == Player.STATE_BUFFERING,
                ended = currentState == Player.STATE_ENDED,
                errorCode = stateRef.get().errorCode,
            ),
        )
    }

    private fun update(next: PlaybackState) {
        if (closed.get()) return
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { update(next) }
            return
        }
        stateRef.set(next)
        listeners.forEach { listener -> runCatching { listener.onPlaybackState(next) } }
    }

    private fun <T> runOnMain(block: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return block()
        val latch = CountDownLatch(1)
        var value: T? = null
        var failure: Throwable? = null
        mainHandler.post {
            try {
                value = block()
            } catch (error: Throwable) {
                failure = error
            } finally {
                latch.countDown()
            }
        }
        if (!latch.await(10, TimeUnit.SECONDS)) {
            throw IllegalStateException("Media3 player main-thread call timed out")
        }
        failure?.let { throw it }
        @Suppress("UNCHECKED_CAST")
        return value as T
    }

    private class MediaClockAdapter(private val config: WorkbenchMediaPlatformConfig) :
        com.floe.android.core.workbenchmedia.util.MediaClock {
        override fun nowMillis(): Long = config.clockMillis()
    }
}
