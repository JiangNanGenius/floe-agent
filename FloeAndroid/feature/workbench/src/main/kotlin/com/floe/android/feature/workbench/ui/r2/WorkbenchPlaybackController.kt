// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.r2

import android.view.Surface
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.MediaExportBinding
import com.floe.android.feature.workbench.PlaybackHandle
import com.floe.android.feature.workbench.PlaybackRequest
import com.floe.android.feature.workbench.PlaybackState
import com.floe.android.feature.workbench.WorkbenchMediaPlatform
import com.floe.android.feature.workbench.ui.presentation.MediaFailure
import com.floe.android.feature.workbench.ui.presentation.MediaFailures
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * Retained video playback for one editor.
 *
 * The player handle is owned by this controller (never by a Composable), so
 * rotation, fullscreen, sheets and panel changes keep the same player and
 * playhead. The rendered surface is attached/detached separately and may come
 * and go while the player stays alive.
 *
 * Every prepared binding is an immutable native snapshot for an exact
 * revision; a new edit prepares a new binding instead of reusing a stale one.
 * Position/duration/isPlaying come from the real [PlaybackHandle] listener —
 * there is no local timer and no fabricated progress.
 */
@Stable
class WorkbenchPlaybackController(
    private val platform: WorkbenchMediaPlatform,
    private val prepareBinding: WorkbenchRenderBindingPreparer,
    private val releaseBinding: WorkbenchRenderBindingReleaser,
    private val contextProvider: () -> CreativeProjectContext?,
    private val onPosition: (Double) -> Unit,
    private val scope: CoroutineScope,
) {
    var state: PlaybackState? by mutableStateOf(null)
        private set
    var preparing: Boolean by mutableStateOf(false)
        private set
    var failure: MediaFailure? by mutableStateOf(null)
        private set
    var preparedRevision: Long? by mutableStateOf(null)
        private set
    var attached: Boolean by mutableStateOf(false)
        private set

    private var player: PlaybackHandle? = null
    private var subscription: AutoCloseable? = null
    private var binding: MediaExportBinding? = null
    private var prepareJob: Job? = null
    private var surface: Surface? = null
    private var surfaceWidth = 0
    private var surfaceHeight = 0
    private var requestedPlayhead = 0.0
    private var requestToken = 0

    val isPlaying: Boolean get() = state?.isPlaying == true
    val buffering: Boolean get() = state?.isBuffering == true
    val positionSeconds: Double get() = state?.positionSeconds ?: requestedPlayhead
    val durationSeconds: Double get() = state?.durationSeconds?.takeIf { it > 0.0 } ?: 0.0
    val ready: Boolean get() = player != null && !preparing

    /**
     * Prepares an immutable snapshot binding for [revision] and builds the
     * platform player. A newer call supersedes an older in-flight prepare.
     */
    fun prepare(
        revision: Long,
        startAtSeconds: Double = requestedPlayhead,
        autoplay: Boolean = false,
    ) {
        // A failed handle is never reused: retrying the same revision must
        // rebuild the player against a fresh immutable binding instead of
        // re-seeking a dead one.
        if (preparedRevision == revision && player != null && !preparing && failure == null) {
            requestedPlayhead = startAtSeconds
            player?.seekTo(startAtSeconds)
            if (autoplay) player?.play()
            return
        }
        val context = contextProvider() ?: run {
            failure = MediaFailure(
                com.floe.android.feature.workbench.ui.presentation.MediaFailureKind.SESSION_LOST,
                "staleSession",
            )
            return
        }
        val token = ++requestToken
        requestedPlayhead = startAtSeconds
        prepareJob?.cancel()
        prepareJob = scope.launch {
            preparing = true
            failure = null
            val attemptID = "playback-${UUID.randomUUID()}"
            var nextBinding: MediaExportBinding? = null
            var nextPlayer: PlaybackHandle? = null
            var nextSubscription: AutoCloseable? = null
            try {
                val createdBinding = prepareBinding.prepareRenderBinding(context, revision, attemptID)
                nextBinding = createdBinding
                if (token != requestToken) {
                    runCatching { releaseBinding.releaseRenderBinding(createdBinding) }
                    return@launch
                }
                val createdPlayer = platform.createPlayer(
                    PlaybackRequest(createdBinding, startAtSeconds = startAtSeconds),
                )
                nextPlayer = createdPlayer
                val createdSubscription = createdPlayer.subscribe { nextState ->
                    if (token == requestToken) {
                        state = nextState
                        // The platform handle reports terminal refusals and
                        // decoder/player errors through the state error code
                        // (its prepare runs asynchronously, so nothing is
                        // thrown to the prepare coroutine). Surfacing it here
                        // keeps a black, inert preview from masquerading as a
                        // healthy one: the failure panel and disabled
                        // transport appear instead. A clean state clears it.
                        failure = MediaFailures.fromCode(nextState.errorCode)
                        val position = nextState.positionSeconds
                        if (position.isFinite() && position >= 0.0) {
                            requestedPlayhead = position
                            onPosition(position)
                        }
                    }
                }
                nextSubscription = createdSubscription
                if (token != requestToken) {
                    runCatching { createdSubscription.close() }
                    runCatching { createdPlayer.close() }
                    runCatching { releaseBinding.releaseRenderBinding(createdBinding) }
                    return@launch
                }
                val previousPlayer = player
                val previousSubscription = subscription
                val previousBinding = binding
                player = createdPlayer
                subscription = createdSubscription
                binding = createdBinding
                nextBinding = null
                nextPlayer = null
                nextSubscription = null
                preparedRevision = revision
                val attachedSurface = surface
                if (attachedSurface != null && attachedSurface.isValid) {
                    attached = runCatching {
                        createdPlayer.attachSurface(attachedSurface, surfaceWidth, surfaceHeight)
                    }.getOrDefault(false)
                } else {
                    attached = false
                }
                runCatching { previousSubscription?.close() }
                runCatching { previousPlayer?.close() }
                if (previousBinding != null) {
                    runCatching { releaseBinding.releaseRenderBinding(previousBinding) }
                }
                createdPlayer.seekTo(startAtSeconds)
                if (autoplay) createdPlayer.play()
                preparing = false
            } catch (cancelled: CancellationException) {
                runCatching { nextSubscription?.close() }
                runCatching { nextPlayer?.close() }
                val created = nextBinding
                if (created != null) {
                    runCatching { releaseBinding.releaseRenderBinding(created) }
                }
                throw cancelled
            } catch (error: Throwable) {
                runCatching { nextSubscription?.close() }
                runCatching { nextPlayer?.close() }
                val created = nextBinding
                if (created != null) {
                    runCatching { releaseBinding.releaseRenderBinding(created) }
                }
                if (token == requestToken) {
                    preparing = false
                    failure = MediaFailures.from(error)
                }
            }
        }
    }

    fun attach(surface: Surface, width: Int, height: Int) {
        this.surface = surface
        surfaceWidth = width
        surfaceHeight = height
        val current = player ?: return
        if (!surface.isValid) return
        attached = runCatching { current.attachSurface(surface, width, height) }
            .getOrDefault(false)
    }

    fun detach() {
        surface = null
        attached = false
        runCatching { player?.detachSurface() }
    }

    fun seekTo(seconds: Double) {
        val clamped = seconds.coerceAtLeast(0.0)
        requestedPlayhead = clamped
        runCatching { player?.seekTo(clamped) }
    }

    fun togglePlay() {
        val current = player ?: return
        if (isPlaying) {
            runCatching { current.pause() }
            return
        }
        // A real end-of-composition event restarts from the beginning instead
        // of dead-playing at the end position.
        if (state?.ended == true) {
            requestedPlayhead = 0.0
            runCatching { current.seekTo(0.0) }
        }
        runCatching { current.play() }
    }

    fun pause() {
        runCatching { player?.pause() }
    }

    fun step(frames: Int, frameRate: Double, duration: Double) {
        val next = WorkbenchVideoMath.frameStep(
            positionSeconds, frames, frameRate, duration,
        )
        seekTo(next)
    }

    /** Releases the player/binding. Safe to call more than once. */
    fun close() {
        requestToken += 1
        prepareJob?.cancel()
        prepareJob = null
        runCatching { subscription?.close() }
        subscription = null
        runCatching { player?.close() }
        player = null
        val previousBinding = binding
        binding = null
        preparedRevision = null
        surface = null
        attached = false
        state = null
        failure = null
        preparing = false
        if (previousBinding != null) {
            scope.launch { runCatching { releaseBinding.releaseRenderBinding(previousBinding) } }
        }
    }
}
