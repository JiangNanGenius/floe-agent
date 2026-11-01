// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.r2

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeInlineSwitch
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph
import com.floe.android.feature.workbench.CaptionAlignment
import com.floe.android.feature.workbench.VideoClip
import com.floe.android.feature.workbench.VideoTransitionKind
import com.floe.android.feature.workbench.ui.MediaSliderRow
import com.floe.android.feature.workbench.ui.R
import com.floe.android.feature.workbench.ui.assetMeta
import com.floe.android.feature.workbench.ui.mediaAssetKindLabelRes
import com.floe.android.feature.workbench.ui.state.MediaEditorController
import java.util.Locale
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Video asset list. Audio is a track source, not a layer; video assets are
 * appended through the real `appendClip` command, never by rewriting JSON.
 */
@Composable
internal fun MediaVideoAssetsPanel(
    controller: MediaEditorController,
    onImportVideo: (() -> Unit)?,
    onImportMusic: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val enabled = controller.writable && !controller.busy && !controller.needsReload
    Column(modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        Row(
            Modifier.fillMaxWidth().padding(start = 14.dp, end = 8.dp, top = 6.dp, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            FloeText(
                stringResource(R.string.media_assets),
                style = Floe.typography.section,
                modifier = Modifier.weight(1f),
            )
            if (onImportVideo != null) {
                FloeCapsuleAction(
                    label = stringResource(R.string.media_r2_add_clip),
                    onClick = onImportVideo,
                    enabled = enabled,
                    showHairline = false,
                )
            }
            if (onImportMusic != null) {
                FloeCapsuleAction(
                    label = stringResource(R.string.media_r2_add_music),
                    onClick = onImportMusic,
                    enabled = enabled,
                    showHairline = false,
                )
            }
        }
        FloeDivider()
        if (controller.project.assets.isEmpty()) {
            FloeText(
                stringResource(R.string.media_r2_no_assets),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(16.dp),
            )
            return@Column
        }
        LazyColumn(Modifier.weight(1f)) {
            items(controller.project.assets, key = { it.id }) { asset ->
                val usedAsClip = controller.videoTimeline?.clips?.any { it.assetID == asset.id } == true
                val usedAsMusic = controller.videoTimeline?.music?.any { it.assetID == asset.id } == true
                Row(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(min = FloeLayout.MinimumTarget)
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Box(
                        Modifier.size(38.dp).clip(RoundedCornerShape(8.dp))
                            .background(Floe.colors.fillTertiary),
                        contentAlignment = Alignment.Center,
                    ) {
                        IconGlyph(
                            if (asset.kind == "audio") FloeIcons.Mic else FloeIcons.PlayRuns,
                            Floe.colors.secondaryLabel,
                            18.dp,
                        )
                    }
                    Column(Modifier.weight(1f)) {
                        FloeText(
                            asset.originalName,
                            style = Floe.typography.metadata,
                            color = Floe.colors.label,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        FloeText(
                            stringResource(
                                R.string.media_asset_meta,
                                stringResource(mediaAssetKindLabelRes(asset)),
                                assetMeta(asset),
                            ),
                            style = Floe.typography.metadata,
                            color = Floe.colors.tertiaryLabel,
                            maxLines = 1,
                        )
                    }
                    if (asset.id in controller.missingAssetIDs) {
                        FloeBadgePill(
                            text = stringResource(R.string.media_layer_missing),
                            tone = FloeBadgeTone.PENDING,
                        )
                    } else if (asset.kind == "video" && !usedAsClip) {
                        FloeCapsuleAction(
                            label = stringResource(R.string.media_r2_add_to_timeline),
                            onClick = { controller.addClipFromAsset(asset.id) },
                            enabled = enabled,
                            showHairline = false,
                        )
                    } else if (asset.kind == "audio" && !usedAsMusic) {
                        FloeCapsuleAction(
                            label = stringResource(R.string.media_r2_add_as_music),
                            onClick = { controller.addMusic(asset.id) },
                            enabled = enabled,
                            showHairline = false,
                        )
                    } else if (usedAsClip || usedAsMusic) {
                        FloeBadgePill(
                            text = stringResource(R.string.media_r2_in_use),
                            tone = FloeBadgeTone.SECONDARY,
                        )
                    }
                }
            }
        }
    }
}

/**
 * Full video inspector: clip trim/speed/volume/rotation/crop/transition,
 * primary audio, music and captions, and the output canvas. Used as the wide
 * right column and inside the compact "Video" sheet.
 */
@Composable
internal fun MediaVideoPropertiesPanel(
    controller: MediaEditorController,
    modifier: Modifier = Modifier,
    showTitle: Boolean = true,
) {
    val timeline = controller.videoTimeline
    if (timeline == null) {
        Column(modifier.fillMaxSize().padding(16.dp)) {
            if (controller.videoLoading) {
                FloeText(
                    stringResource(R.string.media_busy_loading),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            } else {
                FloeText(
                    stringResource(R.string.media_r2_no_clips),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
        return
    }
    val enabled = controller.writable && !controller.busy && !controller.needsReload
    val clip = controller.selectedVideoClip
    Column(
        modifier
            .fillMaxSize()
            .background(Floe.colors.readingSurface)
            .verticalScroll(rememberScrollState()),
    ) {
        if (showTitle) {
            FloeText(
                stringResource(R.string.media_r2_video),
                style = Floe.typography.section,
                modifier = Modifier.padding(start = 14.dp, end = 14.dp, top = 10.dp, bottom = 6.dp),
            )
            FloeDivider()
        }
        if (clip != null) {
            ClipSection(controller, clip, enabled)
        } else {
            FloeText(
                stringResource(R.string.media_r2_select_clip),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(14.dp),
            )
        }
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FloeText(
                timeline.coverTime?.let {
                    stringResource(
                        R.string.media_r2_cover_value,
                        WorkbenchVideoMath.formatSeconds(it),
                    )
                } ?: stringResource(R.string.media_r2_cover_auto),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.weight(1f),
            )
            FloeCapsuleAction(
                label = stringResource(R.string.media_r2_set_cover),
                onClick = { controller.setCoverAtPlayhead() },
                enabled = enabled && controller.videoDuration > 0.0,
                showHairline = false,
            )
            if (timeline.coverTime != null) {
                FloeCapsuleAction(
                    label = stringResource(R.string.media_r2_clear_cover),
                    onClick = { controller.clearCover() },
                    enabled = enabled,
                    showHairline = false,
                    tint = Floe.colors.secondaryLabel,
                )
            }
        }
        SectionDivider(stringResource(R.string.media_r2_primary_audio))
        MediaSliderRow(
            label = stringResource(R.string.media_r2_master_volume),
            value = timeline.primaryVolume.toFloat(),
            range = 0f..4f,
            enabled = enabled,
            format = { String.format(Locale.US, "%.2f", it) },
            onCommit = { controller.setPrimaryVolume(it.toDouble()) },
        )
        ToggleRow(
            label = stringResource(R.string.media_r2_mute_original),
            checked = timeline.primaryMuted,
            enabled = enabled,
            onChange = { controller.setPrimaryMuted(it) },
        )
        SectionDivider(stringResource(R.string.media_r2_music_track))
        if (timeline.music.isEmpty()) {
            EmptyHint(stringResource(R.string.media_r2_no_music))
        }
        for (music in timeline.music) {
            val assetDuration = controller.asset(music.assetID)
                ?.metadata?.durationSeconds
                ?: (music.trimStart + music.lengthSeconds)
            val name = controller.asset(music.assetID)?.originalName
                ?: stringResource(R.string.media_r2_music)
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeText(
                    name,
                    style = Floe.typography.bodyEmphasized,
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.media_r2_remove),
                    onClick = { controller.removeMusic(music.id) },
                    enabled = enabled,
                    tint = Floe.colors.destructive,
                    showHairline = false,
                )
            }
            MediaSliderRow(
                label = "$name · ${stringResource(R.string.media_r2_offset)}",
                value = music.offsetSeconds.toFloat(),
                range = 0f..600f,
                enabled = enabled,
                format = { WorkbenchVideoMath.formatSeconds(it.toDouble()) },
                onCommit = { controller.updateMusic(music.id, offsetSeconds = it.toDouble()) },
            )
            MediaSliderRow(
                label = "$name · ${stringResource(R.string.media_r2_trim_start)}",
                value = music.trimStart.toFloat(),
                range = 0f..max(0.01f, (assetDuration - music.lengthSeconds).toFloat()),
                enabled = enabled,
                format = { WorkbenchVideoMath.formatSeconds(it.toDouble()) },
                onCommit = { controller.updateMusic(music.id, trimStart = it.toDouble()) },
            )
            MediaSliderRow(
                label = "$name · ${stringResource(R.string.media_r2_length)}",
                value = music.lengthSeconds.toFloat(),
                range = 0.1f..max(0.2f, (assetDuration - music.trimStart).toFloat()),
                enabled = enabled,
                format = { WorkbenchVideoMath.formatSeconds(it.toDouble()) },
                onCommit = { controller.updateMusic(music.id, lengthSeconds = it.toDouble()) },
            )
            MediaSliderRow(
                label = "$name · ${stringResource(R.string.media_r2_volume)}",
                value = music.volume.toFloat(),
                range = 0f..4f,
                enabled = enabled,
                format = { String.format(Locale.US, "%.2f", it) },
                onCommit = { controller.updateMusic(music.id, volume = it.toDouble()) },
            )
            MediaSliderRow(
                label = "$name · ${stringResource(R.string.media_r2_fade_in)}",
                value = music.fadeInSeconds.toFloat(),
                range = 0f..max(0.01f, (music.lengthSeconds - music.fadeOutSeconds).toFloat()),
                enabled = enabled,
                format = { WorkbenchVideoMath.formatSeconds(it.toDouble()) },
                onCommit = { controller.updateMusic(music.id, fadeInSeconds = it.toDouble()) },
            )
            MediaSliderRow(
                label = "$name · ${stringResource(R.string.media_r2_fade_out)}",
                value = music.fadeOutSeconds.toFloat(),
                range = 0f..max(0.01f, (music.lengthSeconds - music.fadeInSeconds).toFloat()),
                enabled = enabled,
                format = { WorkbenchVideoMath.formatSeconds(it.toDouble()) },
                onCommit = { controller.updateMusic(music.id, fadeOutSeconds = it.toDouble()) },
            )
        }
        SectionDivider(stringResource(R.string.media_r2_captions))
        if (timeline.captions.isEmpty()) {
            EmptyHint(stringResource(R.string.media_r2_no_captions))
        }
        for (caption in timeline.captions) {
            var text by remember(caption.id) { mutableStateOf(caption.text) }
            LaunchedEffect(caption.text) { if (caption.text != text) text = caption.text }
            Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    com.floe.android.design.FloePlainFormField(
                        label = stringResource(R.string.media_r2_caption_text),
                        value = text,
                        onValueChange = { text = it.take(2000) },
                        singleLine = false,
                        maxLines = 3,
                        minLines = 1,
                        enabled = enabled,
                        modifier = Modifier.weight(1f),
                    )
                    FloeCapsuleAction(
                        label = stringResource(R.string.media_apply),
                        onClick = { controller.updateCaption(caption.id, text = text) },
                        enabled = enabled && text.isNotBlank(),
                        showHairline = false,
                    )
                    FloeCapsuleAction(
                        label = stringResource(R.string.media_r2_remove),
                        onClick = { controller.removeCaption(caption.id) },
                        enabled = enabled,
                        tint = Floe.colors.destructive,
                        showHairline = false,
                    )
                }
                MediaSliderRow(
                    label = stringResource(R.string.media_r2_start),
                    value = caption.start.toFloat(),
                    range = 0f..max(0.1f, (caption.end - 0.05).toFloat()),
                    enabled = enabled,
                    format = { WorkbenchVideoMath.formatSeconds(it.toDouble()) },
                    onCommit = { controller.updateCaption(caption.id, start = it.toDouble()) },
                )
                MediaSliderRow(
                    label = stringResource(R.string.media_r2_end),
                    value = caption.end.toFloat(),
                    range = (caption.start + 0.05).toFloat()..max(
                        (caption.start + 0.1).toFloat(),
                        max(controller.videoDuration, caption.end).toFloat(),
                    ),
                    enabled = enabled,
                    format = { WorkbenchVideoMath.formatSeconds(it.toDouble()) },
                    onCommit = { controller.updateCaption(caption.id, end = it.toDouble()) },
                )
            }
        }
        NewCaptionRow(controller, enabled)
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            FloeCapsuleAction(
                label = stringResource(R.string.media_r2_shift_earlier),
                onClick = { controller.shiftCaptions(-0.1) },
                enabled = enabled && timeline.captions.isNotEmpty(),
            )
            FloeCapsuleAction(
                label = stringResource(R.string.media_r2_shift_later),
                onClick = { controller.shiftCaptions(0.1) },
                enabled = enabled && timeline.captions.isNotEmpty(),
            )
        }
        SectionDivider(stringResource(R.string.media_r2_caption_style))
        CaptionAlignmentRow(controller, timeline.captionStyle.alignment, enabled)
        ToggleRow(
            label = stringResource(R.string.media_r2_safe_area),
            checked = timeline.captionStyle.respectsSafeArea == true,
            enabled = enabled,
            onChange = {
                controller.setCaptionStyle(
                    timeline.captionStyle.copy(respectsSafeArea = it),
                )
            },
        )
        MediaSliderRow(
            label = stringResource(R.string.media_r2_vertical_position),
            value = timeline.captionStyle.positionY.toFloat(),
            range = 0.4f..0.98f,
            enabled = enabled,
            format = { String.format(Locale.US, "%.2f", it) },
            onCommit = {
                controller.setCaptionStyle(
                    timeline.captionStyle.copy(positionY = it.toDouble()),
                )
            },
        )
        MediaSliderRow(
            label = stringResource(R.string.media_r2_font_size),
            value = timeline.captionStyle.fontSize.toFloat(),
            range = 12f..96f,
            enabled = enabled,
            format = { it.roundToInt().toString() },
            onCommit = {
                controller.setCaptionStyle(
                    timeline.captionStyle.copy(fontSize = it.toDouble()),
                )
            },
        )
        com.floe.android.feature.workbench.ui.MediaColorRow(
            label = stringResource(R.string.media_r2_color),
            selected = timeline.captionStyle.colorHex,
            onSelect = {
                controller.setCaptionStyle(
                    timeline.captionStyle.copy(colorHex = it),
                )
            },
        )
        ToggleRow(
            label = stringResource(R.string.media_r2_show_safe_area),
            checked = controller.showCaptionSafeArea,
            enabled = true,
            onChange = { controller.updateShowCaptionSafeArea(it) },
        )
        SectionDivider(stringResource(R.string.media_r2_video_canvas))
        ToggleRow(
            label = stringResource(R.string.media_r2_snap),
            checked = controller.snapEnabled,
            enabled = true,
            onChange = { controller.updateSnapEnabled(it) },
        )
        VideoCanvasEditor(controller, enabled)
        FloeText(
            stringResource(R.string.media_r2_no_transcribe),
            style = Floe.typography.metadata,
            color = Floe.colors.tertiaryLabel,
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
        )
    }
}

@Composable
private fun ClipSection(
    controller: MediaEditorController,
    clip: VideoClip,
    enabled: Boolean,
) {
    val assetDuration = controller.asset(clip.assetID)?.metadata?.durationSeconds
        ?: max(clip.trimEnd, clip.trimStart + 0.1)
    SectionDivider(
        (controller.asset(clip.assetID)?.originalName ?: stringResource(R.string.media_r2_clip)),
    )
    MediaSliderRow(
        label = stringResource(R.string.media_r2_trim_start),
        value = clip.trimStart.toFloat(),
        range = 0f..max(0.01f, (clip.trimEnd - 0.05).toFloat()),
        enabled = enabled,
        format = { WorkbenchVideoMath.formatSeconds(it.toDouble()) },
        onCommit = { controller.updateSelectedClip(trimStart = it.toDouble()) },
    )
    MediaSliderRow(
        label = stringResource(R.string.media_r2_trim_end),
        value = clip.trimEnd.toFloat(),
        range = (clip.trimStart + 0.05).toFloat()..max(
            (clip.trimStart + 0.1).toFloat(),
            (assetDuration + 0.05).toFloat(),
        ),
        enabled = enabled,
        format = { WorkbenchVideoMath.formatSeconds(it.toDouble()) },
        onCommit = { controller.updateSelectedClip(trimEnd = it.toDouble()) },
    )
    MediaSliderRow(
        label = stringResource(R.string.media_r2_speed),
        value = clip.speed.toFloat(),
        range = 0.1f..16f,
        enabled = enabled,
        format = { String.format(Locale.US, "%.2f×", it) },
        onCommit = { controller.updateSelectedClip(speed = it.toDouble()) },
    )
    MediaSliderRow(
        label = stringResource(R.string.media_r2_volume),
        value = clip.volume.toFloat(),
        range = 0f..4f,
        enabled = enabled,
        format = { String.format(Locale.US, "%.2f", it) },
        onCommit = { controller.updateSelectedClip(volume = it.toDouble()) },
    )
    ToggleRow(
        label = stringResource(R.string.media_r2_mute_clip),
        checked = clip.isMuted,
        enabled = enabled,
        onChange = { controller.updateSelectedClip(isMuted = it) },
    )
    FloeText(
        stringResource(R.string.media_r2_rotation),
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
        modifier = Modifier.padding(start = 14.dp, top = 4.dp),
    )
    val rotations = listOf(0, 90, 180, 270)
    val normalized = ((clip.rotationDegrees % 360.0 + 360.0) % 360.0).roundToInt()
    FloeSegmented(
        options = rotations.map { "$it°" },
        selectedIndex = rotations.indexOf(normalized).coerceAtLeast(0),
        onSelect = { controller.updateSelectedClip(rotationDegrees = rotations[it].toDouble()) },
        modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
    )
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        FloeCapsuleAction(
            label = stringResource(R.string.media_crop_sixteen_nine),
            onClick = { controller.setSelectedClipCropAspect(16.0 / 9.0) },
            enabled = enabled,
        )
        FloeCapsuleAction(
            label = stringResource(R.string.media_crop_square),
            onClick = { controller.setSelectedClipCropAspect(1.0) },
            enabled = enabled,
        )
        FloeCapsuleAction(
            label = "9:16",
            onClick = { controller.setSelectedClipCropAspect(9.0 / 16.0) },
            enabled = enabled,
        )
        FloeCapsuleAction(
            label = stringResource(R.string.media_crop_original),
            onClick = { controller.setSelectedClipCropAspect(null) },
            enabled = enabled,
        )
    }
    val dissolveSupported = controller.r2?.capabilities?.crossDissolveSupported == true
    FloeText(
        stringResource(R.string.media_r2_transition),
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
        modifier = Modifier.padding(start = 14.dp, top = 4.dp),
    )
    val transitionOptions = if (dissolveSupported) {
        listOf(
            stringResource(R.string.media_r2_hard_cut),
            stringResource(R.string.media_r2_cross_dissolve),
        )
    } else {
        listOf(stringResource(R.string.media_r2_hard_cut))
    }
    FloeSegmented(
        options = transitionOptions,
        selectedIndex = if (clip.leadingTransition == VideoTransitionKind.CROSS_DISSOLVE &&
            dissolveSupported
        ) 1 else 0,
        onSelect = {
            controller.setSelectedClipTransition(
                if (it == 1) VideoTransitionKind.CROSS_DISSOLVE else VideoTransitionKind.NONE,
            )
        },
        modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
    )
    if (!dissolveSupported) {
        FloeText(
            stringResource(R.string.media_r2_cross_dissolve_unsupported),
            style = Floe.typography.metadata,
            color = Floe.colors.pending,
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 2.dp),
        )
    }
    if (clip.leadingTransition == VideoTransitionKind.CROSS_DISSOLVE && dissolveSupported) {
        MediaSliderRow(
            label = stringResource(R.string.media_r2_dissolve_duration),
            value = clip.transitionDuration.toFloat(),
            range = 0.1f..2f,
            enabled = enabled,
            format = { WorkbenchVideoMath.formatSeconds(it.toDouble()) },
            onCommit = { controller.updateSelectedClip(transitionDuration = it.toDouble()) },
        )
    }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        FloeCapsuleAction(
            label = stringResource(R.string.media_r2_move_earlier),
            onClick = { controller.moveSelectedClip(earlier = true) },
            enabled = enabled,
        )
        FloeCapsuleAction(
            label = stringResource(R.string.media_r2_move_later),
            onClick = { controller.moveSelectedClip(earlier = false) },
            enabled = enabled,
        )
    }
}

@Composable
private fun NewCaptionRow(controller: MediaEditorController, enabled: Boolean) {
    var text by remember { mutableStateOf("") }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        FloePlainFormField(
            label = stringResource(R.string.media_r2_new_caption),
            value = text,
            onValueChange = { text = it.take(2000) },
            enabled = enabled,
            modifier = Modifier.weight(1f),
        )
        FloeCapsuleAction(
            label = stringResource(R.string.media_r2_add),
            onClick = {
                val start = controller.playheadSeconds
                controller.addCaption(text, start, start + 2.0)
                text = ""
            },
            enabled = enabled && text.isNotBlank(),
            tint = Floe.colors.accent,
        )
    }
}

@Composable
private fun CaptionAlignmentRow(
    controller: MediaEditorController,
    alignment: CaptionAlignment?,
    enabled: Boolean,
) {
    val options = listOf(
        stringResource(R.string.media_r2_leading),
        stringResource(R.string.media_r2_center),
        stringResource(R.string.media_r2_trailing),
    )
    val index = when (alignment) {
        CaptionAlignment.LEADING -> 0
        CaptionAlignment.TRAILING -> 2
        else -> 1
    }
    FloeSegmented(
        options = options,
        selectedIndex = index,
        onSelect = {
            controller.videoTimeline?.let { current ->
                controller.setCaptionStyle(
                    current.captionStyle.copy(
                        alignment = when (it) {
                            0 -> CaptionAlignment.LEADING
                            2 -> CaptionAlignment.TRAILING
                            else -> CaptionAlignment.CENTER
                        },
                    ),
                )
            }
        },
        modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
    )
}

@Composable
private fun VideoCanvasEditor(controller: MediaEditorController, enabled: Boolean) {
    val canvas = controller.project.canvas
    var width by remember(controller.projectID) { mutableStateOf((canvas?.width ?: 1280).toString()) }
    var height by remember(controller.projectID) { mutableStateOf((canvas?.height ?: 720).toString()) }
    var fps by remember(controller.projectID) { mutableFloatStateOf((canvas?.frameRate ?: 30.0).toFloat()) }
    LaunchedEffect(canvas?.width) {
        canvas?.width?.let { width = it.toString() }
    }
    LaunchedEffect(canvas?.height) {
        canvas?.height?.let { height = it.toString() }
    }
    LaunchedEffect(canvas?.frameRate) {
        canvas?.frameRate?.let { fps = it.toFloat() }
    }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloePlainFormField(
            label = stringResource(R.string.media_r2_width),
            value = width,
            onValueChange = { width = it.filter { ch -> ch.isDigit() }.take(4) },
            enabled = enabled,
            modifier = Modifier.weight(1f),
        )
        FloePlainFormField(
            label = stringResource(R.string.media_r2_height),
            value = height,
            onValueChange = { height = it.filter { ch -> ch.isDigit() }.take(4) },
            enabled = enabled,
            modifier = Modifier.weight(1f),
        )
    }
    MediaSliderRow(
        label = stringResource(R.string.media_r2_frame_rate),
        value = fps,
        range = 1f..120f,
        enabled = enabled,
        format = { it.roundToInt().toString() },
        onCommit = { fps = it },
    )
    Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp), horizontalArrangement = Arrangement.End) {
        FloeCapsuleAction(
            label = stringResource(R.string.media_r2_apply_canvas),
            onClick = {
                val w = width.toIntOrNull() ?: return@FloeCapsuleAction
                val h = height.toIntOrNull() ?: return@FloeCapsuleAction
                controller.setVideoCanvas(w, h, fps.toDouble())
            },
            enabled = enabled,
            tint = Floe.colors.accent,
        )
    }
}

@Composable
private fun ToggleRow(
    label: String,
    checked: Boolean,
    enabled: Boolean,
    onChange: (Boolean) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloeText(label, style = Floe.typography.body, modifier = Modifier.weight(1f))
        FloeInlineSwitch(
            checked = checked,
            onCheckedChange = onChange,
            description = label,
            enabled = enabled,
        )
    }
}

@Composable
private fun SectionDivider(title: String) {
    FloeDivider(Modifier.padding(vertical = 6.dp))
    FloeText(
        title,
        style = Floe.typography.groupHeader,
        color = Floe.colors.secondaryLabel,
        modifier = Modifier.padding(horizontal = 14.dp, vertical = 4.dp),
    )
}

@Composable
private fun EmptyHint(text: String) {
    FloeText(
        text,
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
        modifier = Modifier.padding(horizontal = 14.dp, vertical = 6.dp),
    )
}

/** Compact-window video asset drawer. */
@Composable
internal fun MediaVideoAssetsSheet(
    controller: MediaEditorController,
    onImportVideo: (() -> Unit)?,
    onImportMusic: (() -> Unit)?,
    onDismiss: () -> Unit,
) {
    FloeActionSheet(visible = true, onDismiss = onDismiss) {
        Column(Modifier.fillMaxSize()) {
            Row(
                Modifier.fillMaxWidth().padding(start = 16.dp, end = 10.dp, top = 8.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeText(
                    stringResource(R.string.media_assets),
                    style = Floe.typography.section,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.media_done),
                    onClick = onDismiss,
                )
            }
            FloeDivider()
            MediaVideoAssetsPanel(
                controller = controller,
                onImportVideo = onImportVideo,
                onImportMusic = onImportMusic,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

/** Compact-window video inspector drawer. */
@Composable
internal fun MediaVideoPanelSheet(
    controller: MediaEditorController,
    onDismiss: () -> Unit,
) {
    FloeActionSheet(visible = true, onDismiss = onDismiss) {
        Column(Modifier.fillMaxSize()) {
            Row(
                Modifier.fillMaxWidth().padding(start = 16.dp, end = 10.dp, top = 8.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeText(
                    stringResource(R.string.media_r2_video),
                    style = Floe.typography.section,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.media_done),
                    onClick = onDismiss,
                )
            }
            FloeDivider()
            MediaVideoPropertiesPanel(
                controller = controller,
                showTitle = false,
                modifier = Modifier.weight(1f),
            )
        }
    }
}
