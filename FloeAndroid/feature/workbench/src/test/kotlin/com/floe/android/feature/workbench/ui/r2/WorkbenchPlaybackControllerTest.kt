// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.r2

import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.MediaAssetProbeRequest
import com.floe.android.feature.workbench.MediaExportBinding
import com.floe.android.feature.workbench.MediaExportJobHandle
import com.floe.android.feature.workbench.MediaExportRequest
import com.floe.android.feature.workbench.MediaExportStatus
import com.floe.android.feature.workbench.PlaybackHandle
import com.floe.android.feature.workbench.PlaybackListener
import com.floe.android.feature.workbench.PlaybackRequest
import com.floe.android.feature.workbench.PlaybackState
import com.floe.android.feature.workbench.ProbedAsset
import com.floe.android.feature.workbench.RenderCapabilities
import com.floe.android.feature.workbench.RenderSnapshotLease
import com.floe.android.feature.workbench.WorkbenchMediaPlatform
import com.floe.android.feature.workbench.ui.presentation.MediaFailureKind
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The platform playback handle prepares asynchronously: authority refusals,
 * snapshot verification, composition planning and decoder/player errors are
 * reported through PlaybackState.errorCode, never thrown into the prepare
 * coroutine. The controller must surface those codes as a real, visible
 * failure (not leave a black, inert preview), keep the transport disabled
 * while failed, and restart truthfully from a real ENDED event.
 *
 * Source-authored; execution stays with the integration owner.
 */
class WorkbenchPlaybackControllerTest {
    private val context = CreativeProjectContext(
        projectID = "project-1",
        sessionToken = "token",
        storage = CreativeStorageLayer.AppOwned,
        origin = null,
    )

    private fun binding(): MediaExportBinding = MediaExportBinding(
        context = context,
        mediaRootPath = "/tmp/floe-media",
        projectRevision = 7L,
        timelineDigest = "digest",
        attemptID = "playback-test",
        snapshot = RenderSnapshotLease(
            leaseID = "lease-1",
            mediaRootPath = "/tmp/floe-media",
            relativePath = "Workbench/project.json",
            sha256 = "0".repeat(64),
            byteCount = 10L,
            expiresAt = "2999-01-01T00:00:00Z",
        ),
    )

    private class FakeHandle : PlaybackHandle {
        val listeners = mutableListOf<PlaybackListener>()
        val seeks = mutableListOf<Double>()
        var plays = 0
        var pauses = 0
        var closed = false

        override val state: PlaybackState get() = PlaybackState()

        override fun attachSurface(surface: android.view.Surface, width: Int, height: Int): Boolean =
            false

        override fun detachSurface() = Unit

        override fun seekTo(positionSeconds: Double) {
            seeks += positionSeconds
        }

        override fun play() {
            plays += 1
        }

        override fun pause() {
            pauses += 1
        }

        override fun subscribe(listener: PlaybackListener): AutoCloseable {
            listeners += listener
            return AutoCloseable { listeners.remove(listener) }
        }

        override fun close() {
            closed = true
        }

        fun emit(state: PlaybackState) {
            listeners.forEach { it.onPlaybackState(state) }
        }
    }

    private class FakePlatform(val handle: FakeHandle) : WorkbenchMediaPlatform {
        override fun capabilities(): RenderCapabilities =
            throw NotImplementedError("not used by playback controller tests")

        override fun createPlayer(request: PlaybackRequest): PlaybackHandle = handle

        override suspend fun probe(request: MediaAssetProbeRequest): ProbedAsset =
            throw NotImplementedError("not used by playback controller tests")

        override suspend fun renderImagePreview(
            request: com.floe.android.feature.workbench.ImagePreviewRequest,
        ): com.floe.android.feature.workbench.ImagePreviewReceipt =
            throw NotImplementedError("not used by playback controller tests")

        override suspend fun submitExport(request: MediaExportRequest): MediaExportJobHandle =
            throw NotImplementedError("not used by playback controller tests")

        override suspend fun exportStatus(
            context: CreativeProjectContext,
            jobID: String,
        ): MediaExportStatus =
            throw NotImplementedError("not used by playback controller tests")

        override suspend fun cancelExport(
            context: CreativeProjectContext,
            jobID: String,
        ): MediaExportJobHandle =
            throw NotImplementedError("not used by playback controller tests")

        override fun observeExport(
            context: CreativeProjectContext,
            jobID: String,
            listener: (MediaExportStatus) -> Unit,
        ): AutoCloseable = AutoCloseable { }
    }

    private fun controller(
        handle: FakeHandle,
        released: MutableList<MediaExportBinding> = mutableListOf(),
        positions: MutableList<Double> = mutableListOf(),
    ): WorkbenchPlaybackController = WorkbenchPlaybackController(
        platform = FakePlatform(handle),
        prepareBinding = WorkbenchRenderBindingPreparer { _, _, _ -> binding() },
        releaseBinding = WorkbenchRenderBindingReleaser { released += it },
        contextProvider = { context },
        onPosition = { positions += it },
        scope = CoroutineScope(Dispatchers.Unconfined),
    )

    @Test
    fun stateErrorCodeSurfacesAsVisibleFailure() {
        val handle = FakeHandle()
        val controller = controller(handle)
        controller.prepare(revision = 7L)

        // The handle finished preparing without a failure; transport is ready.
        assertTrue(controller.ready)
        assertNull(controller.failure)

        // A terminal platform refusal arrives through the state code.
        handle.emit(
            PlaybackState(
                positionSeconds = 0.0,
                durationSeconds = 4.0,
                isPlaying = false,
                isBuffering = false,
                ended = false,
                errorCode = "unsupportedSourceFormat",
            ),
        )
        assertEquals(MediaFailureKind.UNSUPPORTED, controller.failure?.kind)
        assertEquals("unsupportedSourceFormat", controller.failure?.code)

        // A later clean state (e.g. a successful retry) clears the failure.
        handle.emit(
            PlaybackState(
                positionSeconds = 1.0,
                durationSeconds = 4.0,
                isPlaying = true,
                isBuffering = false,
                ended = false,
                errorCode = null,
            ),
        )
        assertNull(controller.failure)
        assertTrue(controller.isPlaying)
    }

    @Test
    fun retryPrepareClearsFailureAndRebuilds() {
        val handle = FakeHandle()
        val released = mutableListOf<MediaExportBinding>()
        val controller = controller(handle, released = released)
        controller.prepare(revision = 7L)
        handle.emit(PlaybackState(durationSeconds = 4.0, errorCode = "rendererUnavailable"))
        assertEquals(MediaFailureKind.UNSUPPORTED, controller.failure?.kind)

        controller.prepare(revision = 7L)
        assertNull(controller.failure)
        // The superseded player was closed and its binding released exactly
        // once through the required callback.
        assertTrue(handle.closed)
        assertEquals(1, released.size)
    }

    @Test
    fun endedToggleRestartsFromZero() {
        val handle = FakeHandle()
        val controller = controller(handle)
        controller.prepare(revision = 7L)
        handle.seeks.clear()
        handle.emit(
            PlaybackState(
                positionSeconds = 4.0,
                durationSeconds = 4.0,
                isPlaying = false,
                ended = true,
            ),
        )
        controller.togglePlay()
        assertEquals(listOf(0.0), handle.seeks)
        assertEquals(1, handle.plays)
    }

    @Test
    fun playingTogglePausesWithoutSeek() {
        val handle = FakeHandle()
        val controller = controller(handle)
        controller.prepare(revision = 7L)
        handle.seeks.clear()
        handle.emit(PlaybackState(positionSeconds = 2.0, durationSeconds = 4.0, isPlaying = true))
        controller.togglePlay()
        assertEquals(1, handle.pauses)
        assertTrue(handle.seeks.isEmpty())
        assertEquals(0, handle.plays)
    }

    @Test
    fun closeReleasesHandleAndFailure() {
        val handle = FakeHandle()
        val released = mutableListOf<MediaExportBinding>()
        val controller = controller(handle, released = released)
        controller.prepare(revision = 7L)
        handle.emit(PlaybackState(durationSeconds = 4.0, errorCode = "rendererUnavailable"))
        controller.close()
        assertTrue(handle.closed)
        assertNull(controller.failure)
        assertFalse(controller.ready)
        assertEquals(1, released.size)
    }
}
