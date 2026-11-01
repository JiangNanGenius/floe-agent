// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.r2

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeInlineSwitch
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeText
import com.floe.android.feature.workbench.CodecCapability
import com.floe.android.feature.workbench.ImageExportSettings
import com.floe.android.feature.workbench.MediaExportKind
import com.floe.android.feature.workbench.MediaExportState
import com.floe.android.feature.workbench.RenderCapabilities
import com.floe.android.feature.workbench.VideoExportSettings
import com.floe.android.feature.workbench.ui.MediaInlineFailure
import com.floe.android.feature.workbench.ui.MediaSliderRow
import com.floe.android.feature.workbench.ui.R
import com.floe.android.feature.workbench.ui.formatBytes
import com.floe.android.feature.workbench.ui.state.MediaEditorController
import java.util.Locale
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

private data class ResolutionOption(val label: String, val width: Int, val height: Int)

/**
 * Export sheet built from actual renderer capabilities.
 *
 * Unsupported codecs/transitions/containers are stated and blocked rather
 * than silently substituted. A result is shown only when the platform service
 * returns a completed job WITH a verified receipt; saving/sharing that receipt
 * goes through the App's required SAF/share callback.
 */
@Composable
internal fun MediaExportSheet(
    controller: MediaEditorController,
    onDismiss: () -> Unit,
) {
    val r2 = controller.r2 ?: return
    val capabilities = r2.capabilities
    FloeActionSheet(visible = true, onDismiss = onDismiss) {
        Column(Modifier.fillMaxSize()) {
            Row(
                Modifier.fillMaxWidth().padding(start = 16.dp, end = 10.dp, top = 8.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                FloeText(
                    stringResource(R.string.media_r2_export),
                    style = Floe.typography.section,
                    modifier = Modifier.weight(1f),
                )
                if (r2.exportBusy) FloeActivityIndicator()
                FloeCapsuleAction(
                    label = stringResource(R.string.media_refresh),
                    onClick = {
                        r2.reloadCapabilities()
                        controller.exportJobs.forEach { controller.refreshExport(it.jobID) }
                    },
                    enabled = !r2.capabilitiesLoading,
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.media_done),
                    onClick = onDismiss,
                )
            }
            FloeDivider()
            Column(
                Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
                    .padding(bottom = 16.dp),
            ) {
                val failure = r2.capabilitiesFailure
                if (capabilities == null) {
                    if (failure != null) {
                        MediaInlineFailure(
                            failure = failure,
                            onRetry = { r2.reloadCapabilities() },
                        )
                    } else {
                        Row(
                            Modifier.fillMaxWidth().padding(16.dp),
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            FloeActivityIndicator()
                            FloeText(
                                stringResource(R.string.media_r2_checking_capabilities),
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                            )
                        }
                    }
                } else if (controller.isVideoProject) {
                    VideoExportForm(controller, capabilities)
                } else if (controller.isImageProject) {
                    ImageExportForm(controller, capabilities)
                }
                r2.exports.recoveryFailure?.let { failure ->
                    MediaInlineFailure(failure = failure, onRetry = null)
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                        horizontalArrangement = Arrangement.End,
                    ) {
                        FloeCapsuleAction(
                            label = stringResource(R.string.media_retry),
                            onClick = { controller.recoverExports() },
                            showHairline = false,
                        )
                    }
                }
                r2.exportFailure?.let { failure ->
                    MediaInlineFailure(
                        failure = failure,
                        onRetry = { controller.clearExportFailure() },
                    )
                }
                ExportJobsSection(controller)
            }
        }
    }
}

@Composable
private fun VideoExportForm(
    controller: MediaEditorController,
    capabilities: RenderCapabilities,
) {
    val r2 = controller.r2 ?: return
    val timeline = controller.videoTimeline
    val encoders = capabilities.encoders
        .filter { it.isEncoder && it.mimeType.startsWith("video/") }
        .distinctBy { it.mimeType }
    val codec = encoders.firstOrNull()
    val maxWidth = minOf(
        capabilities.maxWidth.takeIf { it > 0 } ?: Int.MAX_VALUE,
        codec?.maxWidth?.takeIf { it > 0 } ?: Int.MAX_VALUE,
    )
    val maxHeight = minOf(
        capabilities.maxHeight.takeIf { it > 0 } ?: Int.MAX_VALUE,
        codec?.maxHeight?.takeIf { it > 0 } ?: Int.MAX_VALUE,
    )
    val presets = listOf(
        ResolutionOption("1920×1080", 1920, 1080),
        ResolutionOption("1080×1920", 1080, 1920),
        ResolutionOption("1080×1080", 1080, 1080),
        ResolutionOption("1280×720", 1280, 720),
        ResolutionOption("720×1280", 720, 1280),
        ResolutionOption("720×720", 720, 720),
    ).filter { it.width <= maxWidth && it.height <= maxHeight }
    val canvas = controller.project.canvas
    var codecMime by remember(capabilities.probedAt) {
        mutableStateOf(codec?.mimeType.orEmpty())
    }
    var resolution by remember(capabilities.probedAt) {
        mutableStateOf(
            presets.firstOrNull {
                it.width == canvas?.width && it.height == canvas?.height
            } ?: presets.firstOrNull(),
        )
    }
    val maxFps = minOf(
        capabilities.maxFrameRate.takeIf { it > 0 } ?: 0.0,
        (encoders.firstOrNull { it.mimeType == codecMime }?.maxFrameRate ?: 0.0)
            .takeIf { it > 0.0 } ?: Double.MAX_VALUE,
    )
    val fpsChoices = listOf(24.0, 25.0, 30.0, 50.0, 60.0)
        .filter { maxFps <= 0.0 || it <= maxFps + 0.001 }
        .ifEmpty { listOf((maxFps.takeIf { it > 0.0 } ?: 30.0)) }
    var frameRate by remember(capabilities.probedAt) {
        mutableFloatStateOf(
            (canvas?.frameRate ?: 30.0).toFloat().let { value ->
                if (fpsChoices.any { kotlin.math.abs(it - value) < 0.01 }) value
                else fpsChoices.first().toFloat()
            },
        )
    }
    var quality by remember { mutableFloatStateOf(0.9f) }
    var fileName by remember(controller.projectID) {
        mutableStateOf(defaultFileName(controller.project.name))
    }
    val duration = controller.videoDuration
    val selectedResolution = resolution
    val dissolveUnsupported = timeline?.let { WorkbenchVideoMath.hasCrossDissolve(it) } == true &&
        !capabilities.crossDissolveSupported
    val tooManyClips = capabilities.maxClips > 0 &&
        (timeline?.clips?.size ?: 0) > capabilities.maxClips
    val tooLong = capabilities.maxDurationSeconds > 0.0 &&
        duration > capabilities.maxDurationSeconds + 0.05
    val blockers = buildList {
        if (encoders.isEmpty()) add(stringResource(R.string.media_r2_export_no_encoder))
        if (timeline == null || timeline.clips.isEmpty()) {
            add(stringResource(R.string.media_r2_export_no_clips))
        }
        if (presets.isEmpty()) add(stringResource(R.string.media_r2_export_no_resolution))
        val selectedEncoder = encoders.firstOrNull { it.mimeType == codecMime }
        if (selectedEncoder != null && selectedResolution != null &&
            (selectedResolution.width > selectedEncoder.maxWidth ||
                selectedResolution.height > selectedEncoder.maxHeight)
        ) {
            add(stringResource(R.string.media_r2_export_resolution_limit, selectedEncoder.maxWidth))
        }
        if (maxFps > 0.0 && frameRate > maxFps + 0.001) {
            add(stringResource(R.string.media_r2_export_fps_limit, maxFps.roundToInt()))
        }
        if (dissolveUnsupported) add(stringResource(R.string.media_r2_export_block_dissolve))
        if (tooManyClips) {
            add(stringResource(R.string.media_r2_export_too_many_clips, capabilities.maxClips))
        }
        if (tooLong) {
            add(
                stringResource(
                    R.string.media_r2_export_too_long,
                    WorkbenchVideoMath.formatSeconds(capabilities.maxDurationSeconds),
                ),
            )
        }
        if (quality <= 0f) add(stringResource(R.string.media_r2_export_bad_settings))
    }

    SectionTitle(stringResource(R.string.media_r2_video_export))
    FloeText(
        stringResource(R.string.media_video_hdr_export_boundary),
        style = Floe.typography.metadata,
        color = Floe.colors.tertiaryLabel,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
    )
    FloeText(
        stringResource(R.string.media_r2_codec),
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
        modifier = Modifier.padding(start = 16.dp, top = 4.dp),
    )
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
            .padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        encoders.forEach { encoder ->
            FloeCapsuleAction(
                label = codecDisplayName(encoder.mimeType),
                onClick = { codecMime = encoder.mimeType },
                tint = if (encoder.mimeType == codecMime) Floe.colors.accent else null,
            )
        }
    }
    FloeText(
        stringResource(R.string.media_r2_resolution),
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
        modifier = Modifier.padding(start = 16.dp, top = 4.dp),
    )
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
            .padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        presets.forEach { option ->
            FloeCapsuleAction(
                label = option.label,
                onClick = { resolution = option },
                tint = if (resolution == option) Floe.colors.accent else null,
            )
        }
    }
    OptionRow(
        label = stringResource(R.string.media_r2_frame_rate),
        values = fpsChoices.map { it.roundToInt().toString() },
        selected = frameRate.roundToInt().toString(),
        onSelect = { label -> label.toFloatOrNull()?.let { frameRate = it } },
    )
    MediaSliderRow(
        label = stringResource(R.string.media_r2_quality),
        value = quality,
        range = 0.2f..1f,
        enabled = true,
        format = { "${(it * 100).roundToInt()}%" },
        onCommit = { quality = it },
    )
    FloePlainFormField(
        label = stringResource(R.string.media_r2_file_name),
        value = fileName,
        onValueChange = { fileName = it.take(80) },
        modifier = Modifier.padding(horizontal = 16.dp),
    )
    Blockers(blockers)
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.End,
    ) {
        FloeCapsuleAction(
            label = stringResource(R.string.media_r2_export_video),
            onClick = {
                val target = resolution ?: return@FloeCapsuleAction
                val mime = codecMime.ifBlank { return@FloeCapsuleAction }
                r2.submitVideoExport(
                    VideoExportSettings(
                        codecMime = mime,
                        width = target.width,
                        height = target.height,
                        frameRate = frameRate.toDouble(),
                        quality = quality.toDouble(),
                        fileName = sanitizeFileName(fileName),
                    ),
                )
            },
            enabled = blockers.isEmpty() && !r2.exportBusy,
            tint = Floe.colors.accent,
        )
    }
}

@Composable
private fun ImageExportForm(
    controller: MediaEditorController,
    capabilities: RenderCapabilities,
) {
    val r2 = controller.r2 ?: return
    val formats = capabilities.imageFormats
        .map { it.lowercase(Locale.US) }
        .filter { it in setOf("png", "jpeg", "jpg", "heic") }
        .map { if (it == "jpg") "jpeg" else it }
        .distinct()
        .filter { it != "heic" || capabilities.heicSupported }
    var format by remember(capabilities.probedAt) {
        mutableStateOf(formats.firstOrNull() ?: "png")
    }
    var quality by remember { mutableFloatStateOf(0.95f) }
    var preserveTransparency by remember { mutableStateOf(true) }
    var fileName by remember(controller.projectID) {
        mutableStateOf(defaultFileName(controller.project.name))
    }
    val presetWidth = controller.project.canvas?.width
    val presetHeight = controller.project.canvas?.height
    var width by remember(controller.projectID) {
        mutableStateOf(presetWidth?.toString().orEmpty())
    }
    var height by remember(controller.projectID) {
        mutableStateOf(presetHeight?.toString().orEmpty())
    }
    val blockers = buildList {
        if (formats.isEmpty()) add(stringResource(R.string.media_r2_export_no_image_format))
        val w = width.toIntOrNull()
        val h = height.toIntOrNull()
        if (w != null && capabilities.maxWidth > 0 && w > capabilities.maxWidth) {
            add(stringResource(R.string.media_r2_export_resolution_limit, capabilities.maxWidth))
        }
        if (h != null && capabilities.maxHeight > 0 && h > capabilities.maxHeight) {
            add(stringResource(R.string.media_r2_export_resolution_limit, capabilities.maxHeight))
        }
        if (w != null && w < 1 || h != null && h < 1) {
            add(stringResource(R.string.media_r2_export_bad_settings))
        }
    }
    SectionTitle(stringResource(R.string.media_r2_image_export))
    FloeText(
        stringResource(R.string.media_image_sdr_export_boundary),
        style = Floe.typography.metadata,
        color = Floe.colors.tertiaryLabel,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
    )
    OptionRow(
        label = stringResource(R.string.media_r2_format),
        values = formats,
        selected = format,
        onSelect = { format = it },
    )
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloePlainFormField(
            label = stringResource(R.string.media_r2_width),
            value = width,
            onValueChange = { width = it.filter { ch -> ch.isDigit() }.take(4) },
            modifier = Modifier.weight(1f),
        )
        FloePlainFormField(
            label = stringResource(R.string.media_r2_height),
            value = height,
            onValueChange = { height = it.filter { ch -> ch.isDigit() }.take(4) },
            modifier = Modifier.weight(1f),
        )
    }
    MediaSliderRow(
        label = stringResource(R.string.media_r2_quality),
        value = quality,
        range = 0.2f..1f,
        enabled = format != "png",
        format = { "${(it * 100).roundToInt()}%" },
        onCommit = { quality = it },
    )
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloeText(
            stringResource(R.string.media_image_preserve_transparency),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.weight(1f),
        )
        FloeInlineSwitch(
            checked = preserveTransparency,
            onCheckedChange = { preserveTransparency = it },
            description = stringResource(R.string.media_image_preserve_transparency),
        )
    }
    if (format == "heic") {
        FloeText(
            stringResource(R.string.media_image_heic_alpha_boundary),
            style = Floe.typography.metadata,
            color = Floe.colors.tertiaryLabel,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 2.dp),
        )
    }
    FloePlainFormField(
        label = stringResource(R.string.media_r2_file_name),
        value = fileName,
        onValueChange = { fileName = it.take(80) },
        modifier = Modifier.padding(horizontal = 16.dp),
    )
    Blockers(blockers)
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.End,
    ) {
        FloeCapsuleAction(
            label = stringResource(R.string.media_r2_export_image),
            onClick = {
                r2.submitImageExport(
                    ImageExportSettings(
                        format = format,
                        width = width.toIntOrNull()?.takeIf { it > 0 },
                        height = height.toIntOrNull()?.takeIf { it > 0 },
                        quality = quality.toDouble(),
                        preserveTransparency = preserveTransparency,
                        fileName = sanitizeFileName(fileName),
                    ),
                )
            },
            enabled = blockers.isEmpty() && !r2.exportBusy && format.isNotBlank(),
            tint = Floe.colors.accent,
        )
    }
}

@Composable
private fun ExportJobsSection(controller: MediaEditorController) {
    val jobs = controller.exportJobs
    if (jobs.isEmpty()) return
    SectionTitle(stringResource(R.string.media_r2_export_jobs))
    for (job in jobs) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 6.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(Floe.colors.fillTertiary)
                .padding(10.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeText(
                    stringResource(
                        if (job.kind == MediaExportKind.IMAGE) {
                            R.string.media_r2_image_export
                        } else {
                            R.string.media_r2_video_export
                        },
                    ),
                    style = Floe.typography.bodyEmphasized,
                    modifier = Modifier.weight(1f),
                )
                if (job.recovered) {
                    FloeBadgePill(
                        text = stringResource(R.string.media_r2_recovered),
                        tone = FloeBadgeTone.SECONDARY,
                    )
                }
                FloeBadgePill(
                    text = stringResource(exportStateRes(job.status.state)),
                    tone = when (job.status.state) {
                        MediaExportState.COMPLETED -> FloeBadgeTone.SUCCESS
                        MediaExportState.CANCELLED -> FloeBadgeTone.SECONDARY
                        MediaExportState.FAILED,
                        MediaExportState.INTERRUPTED,
                        MediaExportState.TIMEOUT,
                        -> FloeBadgeTone.DESTRUCTIVE
                        else -> FloeBadgeTone.ACCENT
                    },
                )
            }
            job.status.progress?.let { progress ->
                FloeText(
                    String.format(Locale.US, "%.0f%%", progress * 100),
                    style = Floe.typography.metadata,
                    color = Floe.colors.tertiaryLabel,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (job.status.errorCode != null) {
                FloeText(
                    stringResource(R.string.media_r2_request_failed),
                    style = Floe.typography.metadata,
                    color = Floe.colors.pending,
                )
            }
            if (job.recovered && job.verifiedReceipt == null) {
                FloeText(
                    stringResource(R.string.media_r2_recovered_note),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                FloeCapsuleAction(
                    label = stringResource(R.string.media_refresh),
                    onClick = { controller.refreshExport(job.jobID) },
                    showHairline = false,
                )
                if (!job.terminal) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.media_r2_cancel),
                        onClick = { controller.cancelExport(job.jobID) },
                        tint = Floe.colors.destructive,
                        showHairline = false,
                    )
                } else if (job.canRetry) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.media_r2_retry),
                        onClick = { controller.retryExport(job.jobID) },
                        tint = Floe.colors.accent,
                        showHairline = false,
                    )
                }
            }
            val receipt = job.verifiedReceipt
            if (receipt != null) {
                VerifiedReceipt(controller, job.jobID, receipt)
            }
        }
    }
}

@Composable
private fun VerifiedReceipt(
    controller: MediaEditorController,
    jobID: String,
    receipt: com.floe.android.feature.workbench.MediaExportReceipt,
) {
    val scope = rememberCoroutineScope()
    var notice by remember(jobID) { mutableStateOf<Int?>(null) }
    LaunchedEffect(jobID) { controller.clearGallerySave() }
    Column(
        Modifier
            .fillMaxWidth()
            .padding(top = 4.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(Floe.colors.readingSurface)
            .padding(8.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        FloeText(
            stringResource(R.string.media_r2_verified_export),
            style = Floe.typography.bodyEmphasized,
            color = Floe.colors.success,
        )
        FloeText(
            stringResource(
                R.string.media_r2_export_details,
                receipt.verification.width,
                receipt.verification.height,
                formatBytes(receipt.byteCount),
            ),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        FloeText(
            receipt.verification.codec + " · " + receipt.verification.container +
                if (receipt.verification.playable) {
                    " · " + stringResource(R.string.media_r2_playable)
                } else {
                    ""
                },
            style = Floe.typography.metadata,
            color = Floe.colors.tertiaryLabel,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            FloeCapsuleAction(
                label = stringResource(R.string.media_r2_save_share),
                onClick = {
                    scope.launch {
                        when (controller.deliverExport(jobID, receipt)) {
                            WorkbenchExportDeliveryResult.Delivered -> {
                                notice = R.string.media_r2_delivered
                            }
                            WorkbenchExportDeliveryResult.Cancelled -> notice = null
                            is WorkbenchExportDeliveryResult.Failed -> {
                                notice = R.string.media_r2_delivery_failed
                            }
                            else -> notice = R.string.media_r2_delivery_failed
                        }
                    }
                },
                tint = Floe.colors.accent,
            )
            if (controller.gallerySaveAvailable) {
                FloeCapsuleAction(
                    label = if (java.util.Locale.getDefault().language == "zh") {
                        "保存到相册"
                    } else {
                        "Save to Gallery"
                    },
                    onClick = { controller.saveReceiptToGallery(jobID, receipt) },
                    enabled = !controller.gallerySave.busy,
                    showHairline = false,
                )
            }
        }
        notice?.let {
            FloeText(
                stringResource(it),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
        controller.gallerySave.savedDisplayName?.let { name ->
            FloeText(
                if (java.util.Locale.getDefault().language == "zh") {
                    "已保存到相册：$name"
                } else {
                    "Saved to Gallery: $name"
                },
                style = Floe.typography.metadata,
                color = Floe.colors.success,
            )
            FloeCapsuleAction(
                label = if (java.util.Locale.getDefault().language == "zh") {
                    "清除提示"
                } else {
                    "Dismiss"
                },
                onClick = { controller.clearGallerySave() },
                showHairline = false,
            )
        }
        controller.gallerySave.permission?.let {
            FloeText(
                if (java.util.Locale.getDefault().language == "zh") {
                    "保存到系统相册需要存储权限。请从系统设置允许后重试。"
                } else {
                    "Saving to the system gallery needs storage permission. Allow it in system settings and retry."
                },
                style = Floe.typography.metadata,
                color = Floe.colors.pending,
            )
        }
        controller.gallerySave.failure?.let { _ ->
            FloeText(
                if (java.util.Locale.getDefault().language == "zh") {
                    "保存到相册失败，已验证的导出文件仍保留。"
                } else {
                    "Gallery save failed; the verified export is still retained."
                },
                style = Floe.typography.metadata,
                color = Floe.colors.destructive,
            )
            FloeCapsuleAction(
                label = stringResource(R.string.media_r2_retry),
                onClick = { controller.saveReceiptToGallery(jobID, receipt) },
                showHairline = false,
            )
        }
    }
}

@Composable
private fun Blockers(blockers: List<String>) {
    if (blockers.isEmpty()) return
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(Floe.colors.pending.copy(alpha = 0.10f))
            .padding(8.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        blockers.forEach { blocker ->
            FloeText(
                blocker,
                style = Floe.typography.metadata,
                color = Floe.colors.pending,
            )
        }
    }
}

@Composable
private fun OptionRow(
    label: String,
    values: List<String>,
    selected: String,
    onSelect: (String) -> Unit,
) {
    FloeText(
        label,
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
        modifier = Modifier.padding(start = 16.dp, top = 4.dp),
    )
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
            .padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        values.forEach { value ->
            FloeCapsuleAction(
                label = value,
                onClick = { onSelect(value) },
                tint = if (value == selected) Floe.colors.accent else null,
            )
        }
    }
}

@Composable
private fun SectionTitle(title: String) {
    FloeDivider(Modifier.padding(top = 8.dp))
    FloeText(
        title,
        style = Floe.typography.groupHeader,
        color = Floe.colors.secondaryLabel,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
    )
}

private fun exportStateRes(state: MediaExportState): Int = when (state) {
    MediaExportState.QUEUED -> R.string.media_r2_state_queued
    MediaExportState.RUNNING -> R.string.media_r2_state_running
    MediaExportState.VERIFYING -> R.string.media_r2_state_verifying
    MediaExportState.COMPLETED -> R.string.media_r2_state_completed
    MediaExportState.CANCELLED -> R.string.media_r2_state_cancelled
    MediaExportState.FAILED -> R.string.media_r2_state_failed
    MediaExportState.INTERRUPTED -> R.string.media_r2_state_interrupted
    MediaExportState.TIMEOUT -> R.string.media_r2_state_timeout
}

private fun codecDisplayName(mimeType: String): String = when (mimeType) {
    "video/avc" -> "H.264"
    "video/hevc" -> "HEVC"
    "video/av01" -> "AV1"
    "video/x-vnd.on2.vp9" -> "VP9"
    else -> mimeType
}

private fun defaultFileName(projectName: String): String {
    val base = projectName.trim().ifBlank { "export" }
    return base.take(60)
}

private fun sanitizeFileName(name: String): String {
    val cleaned = name.trim().map { ch ->
        if (ch.isLetterOrDigit() || ch == '-' || ch == '_' || ch == ' ') ch else '_'
    }.joinToString("").trim().ifBlank { "export" }
    return cleaned.take(80)
}
