// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.r2

import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Slider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph
import com.floe.android.feature.workbench.ui.R
import com.floe.android.feature.workbench.ui.state.MediaEditorController
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Real video surface + transport for the workbench preview.
 *
 * The [android.view.Surface] is attached/detached independently of the player
 * handle, so opening a sheet, rotating or entering fullscreen keeps the same
 * player and playhead. Progress, duration and playing state come from the
 * platform [com.floe.android.feature.workbench.PlaybackHandle] listener.
 */
@Composable
internal fun MediaVideoSurface(
    controller: MediaEditorController,
    compact: Boolean,
    modifier: Modifier = Modifier,
) {
    val r2 = controller.r2
    val playback = r2?.playback
    val state = playback?.state
    val timeline = controller.videoTimeline
    val frameRate = controller.project.canvas?.frameRate ?: 30.0
    val duration = max(controller.videoDuration, state?.durationSeconds ?: 0.0)
    var scrubbing by remember(controller.projectID) { mutableStateOf(false) }
    var scrubValue by remember(controller.projectID) { mutableFloatStateOf(0f) }
    val playhead = controller.playheadSeconds
    val scrubLabel = stringResource(R.string.media_r2_scrub)

    DisposableEffect(playback) {
        onDispose { playback?.detach() }
    }

    Column(modifier.fillMaxSize().background(Color.Black)) {
        Box(Modifier.weight(1f).fillMaxWidth()) {
            if (playback != null) {
                val handle = playback
                AndroidView(
                    factory = { context ->
                        SurfaceView(context).apply {
                            holder.addCallback(
                                object : SurfaceHolder.Callback {
                                    override fun surfaceCreated(holder: SurfaceHolder) {
                                        val frame = holder.surfaceFrame
                                        handle.attach(
                                            holder.surface,
                                            frame.width().coerceAtLeast(1),
                                            frame.height().coerceAtLeast(1),
                                        )
                                    }

                                    override fun surfaceChanged(
                                        holder: SurfaceHolder,
                                        format: Int,
                                        width: Int,
                                        height: Int,
                                    ) {
                                        handle.attach(
                                            holder.surface,
                                            width.coerceAtLeast(1),
                                            height.coerceAtLeast(1),
                                        )
                                    }

                                    override fun surfaceDestroyed(holder: SurfaceHolder) {
                                        handle.detach()
                                    }
                                },
                            )
                        }
                    },
                    modifier = Modifier.fillMaxSize(),
                )
            }
            // Captions are rendered by the same Media3 composition used by
            // export. Only editor guides belong above the video Surface;
            // another text overlay would duplicate captions and ignore their
            // native font/alignment/safe-area styling.
            if (controller.showCaptionSafeArea && timeline != null) {
                CaptionSafeAreaGuide(
                    positionY = timeline.captionStyle.positionY,
                    alignment = timeline.captionStyle.alignment,
                )
            }
            when {
                playback == null -> {
                    Column(
                        Modifier.align(Alignment.Center),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        FloeText(
                            stringResource(R.string.media_r2_playback_unavailable),
                            style = Floe.typography.metadata,
                            color = Color.White,
                        )
                    }
                }
                playback.preparing && state == null -> {
                    Column(
                        Modifier
                            .align(Alignment.Center)
                            .background(Color.Black.copy(alpha = 0.45f), RoundedCornerShape(10.dp))
                            .padding(12.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        FloeActivityIndicator()
                        FloeText(
                            stringResource(R.string.media_r2_preparing_preview),
                            style = Floe.typography.metadata,
                            color = Color.White,
                        )
                    }
                }
                playback.failure != null -> {
                    Column(
                        Modifier
                            .align(Alignment.Center)
                            .background(Color.Black.copy(alpha = 0.58f), RoundedCornerShape(12.dp))
                            .padding(14.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        IconGlyph(FloeIcons.WarningTriangle, Floe.colors.pending, 26.dp)
                        FloeText(
                            stringResource(R.string.media_r2_preview_failed),
                            style = Floe.typography.bodyEmphasized,
                            color = Color.White,
                        )
                        FloeCapsuleAction(
                            label = stringResource(R.string.media_retry),
                            onClick = {
                                controller.r2?.preparePlayback(
                                    controller.revision,
                                    controller.playheadSeconds,
                                )
                            },
                        )
                    }
                }
            }
        }
        Row(
            Modifier
                .fillMaxWidth()
                .heightIn(min = FloeLayout.MinimumTarget)
                .background(Floe.colors.readingSurface)
                .padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            FloeCircleButton(
                icon = if (state?.isPlaying == true) FloeIcons.StopSquare else FloeIcons.PlayRuns,
                contentDescription = stringResource(
                    if (state?.isPlaying == true) R.string.media_r2_pause else R.string.media_r2_play,
                ),
                onClick = { playback?.togglePlay() },
                enabled = playback?.ready == true,
                visualSize = 36.dp,
                iconSize = 18.dp,
            )
            FloeCircleButton(
                icon = FloeIcons.ChevronBack,
                contentDescription = stringResource(R.string.media_r2_frame_back),
                onClick = {
                    playback?.let { player ->
                        player.pause()
                        val target = WorkbenchVideoMath.frameStep(
                            player.positionSeconds,
                            -1,
                            frameRate,
                            duration,
                        )
                        player.seekTo(target)
                        controller.setPlayhead(target)
                    }
                },
                visualSize = 32.dp,
                iconSize = 15.dp,
                enabled = playback?.ready == true,
            )
            FloeCircleButton(
                icon = FloeIcons.ChevronForward,
                contentDescription = stringResource(R.string.media_r2_frame_forward),
                onClick = {
                    playback?.let { player ->
                        player.pause()
                        val target = WorkbenchVideoMath.frameStep(
                            player.positionSeconds,
                            1,
                            frameRate,
                            duration,
                        )
                        player.seekTo(target)
                        controller.setPlayhead(target)
                    }
                },
                visualSize = 32.dp,
                iconSize = 15.dp,
                enabled = playback?.ready == true,
            )
            FloeText(
                WorkbenchVideoMath.timecode(
                    if (scrubbing) scrubValue.toDouble() else playhead,
                    frameRate,
                ),
                style = Floe.typography.evidence,
                color = Floe.colors.secondaryLabel,
            )
            Slider(
                value = if (scrubbing) scrubValue else playhead.toFloat(),
                onValueChange = {
                    scrubbing = true
                    scrubValue = it.coerceIn(0f, max(duration, 0.1).toFloat())
                },
                onValueChangeFinished = {
                    controller.setPlayhead(scrubValue.toDouble())
                    scrubbing = false
                },
                valueRange = 0f..max(duration, 0.1).toFloat(),
                modifier = Modifier
                    .weight(1f)
                    .height(32.dp)
                    .semantics { contentDescription = scrubLabel },
            )
            if (!compact) {
                FloeText(
                    WorkbenchVideoMath.timecode(duration, frameRate),
                    style = Floe.typography.evidence,
                    color = Floe.colors.tertiaryLabel,
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.media_r2_snap),
                    onClick = { controller.updateSnapEnabled(!controller.snapEnabled) },
                    tint = if (controller.snapEnabled) {
                        Floe.colors.accent
                    } else {
                        Floe.colors.secondaryLabel
                    },
                    showHairline = false,
                )
            }
            FloeCircleButton(
                icon = FloeIcons.Photo,
                contentDescription = stringResource(R.string.media_r2_set_cover),
                onClick = { controller.setCoverAtPlayhead() },
                enabled = !controller.busy && controller.writable,
                visualSize = 32.dp,
                iconSize = 16.dp,
            )
        }
        if (!compact) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 2.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                FloeText(
                    if (controller.videoLoading) {
                        stringResource(R.string.media_busy_loading)
                    } else {
                        stringResource(
                            R.string.media_r2_clip_count,
                            timeline?.clips?.size ?: 0,
                        )
                    },
                    style = Floe.typography.metadata,
                    color = Floe.colors.tertiaryLabel,
                )
                FloeText(
                    WorkbenchVideoMath.formatSeconds(duration),
                    style = Floe.typography.metadata,
                    color = Floe.colors.tertiaryLabel,
                )
            }
        }
    }
}

@Composable
private fun CaptionSafeAreaGuide(
    positionY: Double,
    alignment: com.floe.android.feature.workbench.CaptionAlignment?,
) {
    Canvas(Modifier.fillMaxSize()) {
        val insetX = size.width * 0.05f
        val insetY = size.height * 0.05f
        drawRect(
            color = Color(0xFFF2D64B).copy(alpha = 0.85f),
            topLeft = Offset(insetX, insetY),
            size = androidx.compose.ui.geometry.Size(
                size.width - insetX * 2,
                size.height - insetY * 2,
            ),
            style = Stroke(
                width = 1.dp.toPx(),
                pathEffect = PathEffect.dashPathEffect(floatArrayOf(6f, 4f)),
            ),
        )
        val y = size.height * positionY.toFloat().coerceIn(0f, 1f)
        drawLine(
            color = Color(0xFFF2D64B).copy(alpha = 0.85f),
            start = Offset(0f, y),
            end = Offset(size.width, y),
            strokeWidth = 1f,
        )
        val barWidth = size.width * 0.3f
        val barX = when (alignment) {
            com.floe.android.feature.workbench.CaptionAlignment.LEADING -> size.width * 0.05f
            com.floe.android.feature.workbench.CaptionAlignment.TRAILING ->
                size.width * 0.95f - barWidth
            else -> (size.width - barWidth) / 2f
        }
        drawRect(
            color = Color(0xFFF2D64B).copy(alpha = 0.6f),
            topLeft = Offset(barX, y - 7.dp.toPx()),
            size = androidx.compose.ui.geometry.Size(barWidth, 14.dp.toPx()),
        )
    }
}

/** Small deterministic size label shared by playback and export. */
internal fun videoFrameRateLabel(frameRate: Double): String {
    val rounded = frameRate.roundToInt()
    return if (rounded > 0) "$rounded fps" else "—"
}
