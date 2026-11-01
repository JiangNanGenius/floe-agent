// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.r2

import android.graphics.Paint
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Slider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.floe.android.design.Floe
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph
import com.floe.android.feature.workbench.VideoClip
import com.floe.android.feature.workbench.VideoTransitionKind
import com.floe.android.feature.workbench.ui.R
import com.floe.android.feature.workbench.ui.state.MediaEditorController
import java.util.Locale
import kotlin.math.ceil
import kotlin.math.max

/**
 * Horizontal video timeline with a real ruler, clip strip, music/caption
 * tracks and a red playhead.
 *
 * Clip trim handles commit ONE `updateClip` at drag end (one undo step), and
 * selection is owned by the retained controller so a drawer/rotation never
 * loses it. There is no thumbnail invention: a clip without a platform
 * thumbnail shows its asset name and timing.
 */
@Composable
internal fun MediaVideoTimeline(
    controller: MediaEditorController,
    compact: Boolean,
    modifier: Modifier = Modifier,
) {
    val timeline = controller.videoTimeline ?: return
    val placed = controller.videoPlaced
    val total = max(controller.videoDuration, placed.lastOrNull()?.timelineEnd ?: 0.0)
    val pps = controller.pixelsPerSecond.coerceIn(20f, 240f)
    val density = LocalDensity.current.density
    val zoomLabel = stringResource(R.string.media_r2_zoom)
    val stripWidth = max(
        (total * pps).toFloat(),
        placed.sumOf { max(8f, (it.duration * pps).toFloat()).toDouble() }.toFloat(),
    )
    val scroll = rememberScrollState()
    val selectedID = controller.selectedClipID
    val canEdit = controller.writable && !controller.busy && !controller.needsReload
    val clipHeight = if (compact) 40.dp else 54.dp
    val rulerHeight = 14.dp
    val musicTop = if (compact) 0.dp else rulerHeight + clipHeight + 4.dp
    val captionTop = if (compact) 0.dp else musicTop + 30.dp
    val stripHeight = if (compact) rulerHeight + clipHeight + 4.dp else captionTop + 24.dp

    Column(modifier.fillMaxWidth().background(Floe.colors.groupedSurface)) {
        Row(
            Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState())
                .padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            FloeCapsuleAction(
                label = stringResource(R.string.media_r2_split),
                onClick = { controller.splitSelectedClipAtPlayhead() },
                enabled = canEdit && selectedID != null,
            )
            FloeCapsuleAction(
                label = stringResource(R.string.media_r2_duplicate),
                onClick = { controller.duplicateSelectedClip() },
                enabled = canEdit && selectedID != null,
            )
            FloeCapsuleAction(
                label = stringResource(R.string.media_r2_delete),
                onClick = { controller.removeSelectedClip() },
                enabled = canEdit && selectedID != null,
                tint = Floe.colors.destructive,
            )
            FloeCapsuleAction(
                label = stringResource(R.string.media_r2_move_earlier),
                onClick = { controller.moveSelectedClip(earlier = true) },
                enabled = canEdit && selectedID != null,
                showHairline = false,
            )
            FloeCapsuleAction(
                label = stringResource(R.string.media_r2_move_later),
                onClick = { controller.moveSelectedClip(earlier = false) },
                enabled = canEdit && selectedID != null,
                showHairline = false,
            )
            FloeText(
                stringResource(R.string.media_r2_zoom),
                style = Floe.typography.metadata,
                color = Floe.colors.tertiaryLabel,
            )
            Slider(
                value = pps,
                onValueChange = { controller.updatePixelsPerSecond(it) },
                valueRange = 20f..240f,
                modifier = Modifier
                    .width(if (compact) 90.dp else 150.dp)
                    .height(32.dp)
                    .semantics { contentDescription = zoomLabel },
            )
        }
        Box(
            Modifier
                .fillMaxWidth()
                .height(stripHeight + 8.dp)
                .horizontalScroll(scroll)
                .pointerInput(pps, density) {
                    detectTapGestures { offset ->
                        controller.setPlayhead((offset.x / (pps * density)).toDouble())
                    }
                },
        ) {
            Box(
                Modifier
                    .width((stripWidth + 80f).dp)
                    .fillMaxHeight(),
            ) {
                TimelineRuler(
                    total = total,
                    pps = pps,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(rulerHeight),
                )
                placed.forEach { item ->
                    TimelineClip(
                        controller = controller,
                        placed = item,
                        pps = pps,
                        compact = compact,
                        height = clipHeight,
                        selected = selectedID == item.clip.id,
                        modifier = Modifier
                            .offset(
                                x = (item.timelineStart * pps).toFloat().dp,
                                y = rulerHeight + 2.dp,
                            )
                            .width(max(8f, (item.duration * pps).toFloat()).dp)
                            .height(clipHeight),
                    )
                }
                if (!compact) {
                    for (music in timeline.music) {
                        val width = max(40f, (music.lengthSeconds * pps).toFloat()).dp
                        Box(
                            Modifier
                                .offset(
                                    x = (music.offsetSeconds * pps).toFloat().dp,
                                    y = musicTop,
                                )
                                .width(width)
                                .height(26.dp)
                                .clip(RoundedCornerShape(4.dp))
                                .background(Floe.colors.accentFillFaint)
                                .padding(horizontal = 6.dp),
                            contentAlignment = Alignment.CenterStart,
                        ) {
                            FloeText(
                                "♪ " + (controller.asset(music.assetID)?.originalName
                                    ?: stringResource(R.string.media_r2_music)),
                                style = Floe.typography.metadata,
                                color = Floe.colors.accent,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                    for (caption in timeline.captions) {
                        val width = max(30f, ((caption.end - caption.start) * pps).toFloat()).dp
                        Box(
                            Modifier
                                .offset(
                                    x = (caption.start * pps).toFloat().dp,
                                    y = captionTop,
                                )
                                .width(width)
                                .height(20.dp)
                                .clip(RoundedCornerShape(4.dp))
                                .background(Floe.colors.fillTertiary)
                                .padding(horizontal = 5.dp),
                            contentAlignment = Alignment.CenterStart,
                        ) {
                            FloeText(
                                caption.text,
                                style = Floe.typography.metadata,
                                color = Floe.colors.label,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
                Box(
                    Modifier
                        .offset(x = (controller.playheadSeconds * pps).toFloat().dp)
                        .width(2.dp)
                        .fillMaxHeight()
                        .background(Floe.colors.destructive),
                )
            }
        }
    }
}

@Composable
private fun TimelineRuler(
    total: Double,
    pps: Float,
    modifier: Modifier = Modifier,
) {
    val step = max(1.0, ceil(total / 30.0))
    val separator = Floe.colors.separator
    Canvas(modifier) {
        val paint = Paint().apply {
            color = android.graphics.Color.GRAY
            textSize = 9.sp.toPx()
            isAntiAlias = true
        }
        var second = 0.0
        while (second <= total + 0.001) {
            val x = (second * pps).toFloat()
            drawLine(
                color = separator,
                start = Offset(x, size.height - 4.dp.toPx()),
                end = Offset(x, size.height),
                strokeWidth = 1f,
            )
            drawContext.canvas.nativeCanvas.drawText(
                "${second.toInt()}s",
                x + 2.dp.toPx(),
                size.height - 4.dp.toPx(),
                paint,
            )
            second += step
        }
    }
}

@Composable
private fun TimelineClip(
    controller: MediaEditorController,
    placed: PlacedVideoClip,
    pps: Float,
    compact: Boolean,
    height: androidx.compose.ui.unit.Dp,
    selected: Boolean,
    modifier: Modifier = Modifier,
) {
    val clip = placed.clip
    val assetName = controller.asset(clip.assetID)?.originalName ?: clip.assetID
    val unsupportedDissolve = clip.leadingTransition == VideoTransitionKind.CROSS_DISSOLVE &&
        controller.r2?.capabilities?.crossDissolveSupported != true
    val shape = RoundedCornerShape(6.dp)
    Box(
        modifier
            .clip(shape)
            .background(if (selected) Floe.colors.accentFillFaint else Floe.colors.fillTertiary)
            .border(
                width = if (selected) 2.dp else 1.dp,
                color = if (selected) Floe.colors.accent else Floe.colors.separator,
                shape = shape,
            )
            .clickable { controller.selectClip(clip.id) }
            .padding(horizontal = 6.dp, vertical = 3.dp),
    ) {
        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            FloeText(
                assetName,
                style = Floe.typography.metadata,
                color = Floe.colors.label,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                FloeText(
                    WorkbenchVideoMath.formatSeconds(placed.duration),
                    style = Floe.typography.metadata,
                    color = Floe.colors.tertiaryLabel,
                )
                if (clip.isMuted) {
                    FloeText(
                        "M",
                        style = Floe.typography.metadata,
                        color = Floe.colors.tertiaryLabel,
                    )
                }
                if (clip.speed != 1.0) {
                    FloeText(
                        String.format(Locale.US, "%.2g×", clip.speed),
                        style = Floe.typography.metadata,
                        color = Floe.colors.accent,
                    )
                }
                if (clip.leadingTransition == VideoTransitionKind.CROSS_DISSOLVE) {
                    FloeText(
                        if (unsupportedDissolve) "!" else "◐",
                        style = Floe.typography.metadata,
                        color = if (unsupportedDissolve) {
                            Floe.colors.pending
                        } else {
                            Floe.colors.secondaryLabel
                        },
                    )
                }
            }
        }
        if (selected) {
            TrimHandle(
                controller = controller,
                clip = clip,
                leading = true,
                pps = pps,
                description = stringResource(R.string.media_r2_trim_start),
                modifier = Modifier.align(Alignment.CenterStart).fillMaxHeight(),
            )
            TrimHandle(
                controller = controller,
                clip = clip,
                leading = false,
                pps = pps,
                description = stringResource(R.string.media_r2_trim_end),
                modifier = Modifier.align(Alignment.CenterEnd).fillMaxHeight(),
            )
        }
    }
}

@Composable
private fun TrimHandle(
    controller: MediaEditorController,
    clip: VideoClip,
    leading: Boolean,
    pps: Float,
    description: String,
    modifier: Modifier = Modifier,
) {
    var dragPx by remember(clip.id, leading) { mutableFloatStateOf(0f) }
    val density = LocalDensity.current.density
    Box(
        modifier
            .width(40.dp)
            .semantics { contentDescription = description }
            .background(Floe.colors.accent.copy(alpha = 0.55f))
            .pointerInput(clip.id, clip.trimStart, clip.trimEnd, pps, density, leading) {
                detectHorizontalDragGestures(
                    onDragStart = {
                        dragPx = 0f
                        controller.selectClip(clip.id)
                    },
                    onHorizontalDrag = { change, amount ->
                        change.consume()
                        dragPx += amount
                    },
                    onDragEnd = {
                        val delta = (dragPx / (pps * density)).toDouble()
                        if (leading) {
                            controller.updateSelectedClip(trimStart = clip.trimStart + delta)
                        } else {
                            controller.updateSelectedClip(trimEnd = clip.trimEnd + delta)
                        }
                        dragPx = 0f
                    },
                    onDragCancel = { dragPx = 0f },
                )
            },
        contentAlignment = Alignment.Center,
    ) {
        IconGlyph(
            if (leading) FloeIcons.ChevronBack else FloeIcons.ChevronForward,
            Floe.colors.accent,
            12.dp,
        )
    }
}
