// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.r2

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeInlineSwitch
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeText
import com.floe.android.feature.workbench.EnhancementJobState
import com.floe.android.feature.workbench.EnhancementMethod
import com.floe.android.feature.workbench.EnhancementOperation
import com.floe.android.feature.workbench.EnhancementRequest
import com.floe.android.feature.workbench.ui.MediaInlineFailure
import com.floe.android.feature.workbench.ui.R
import com.floe.android.feature.workbench.ui.formatBytes
import com.floe.android.feature.workbench.ui.state.MediaEditorController
import java.util.Locale

private val INTERPOLATION_FPS_PRESETS = listOf(30, 60, 90, 120, 144, 240)

/**
 * Enhancement sheet for the real G09-R2 media enhancement surface.
 *
 * Frame interpolation runs as a real ffmpeg `minterpolate` job in the task
 * Linux environment; super-resolution runs on the user-configured fal.ai
 * video backend. Neither path is ever plain scaling, and every result row is
 * measured (dimensions, frame rate, duration, bytes, SHA-256) by the native
 * pipeline before it is shown here. "Configure" opens the same retained
 * backend-configuration flow as Settings.
 */
@Composable
internal fun MediaEnhancementSheet(
    controller: MediaEditorController,
    onDismiss: () -> Unit,
) {
    val r2 = controller.r2 ?: return
    val enhancement = r2.enhancement
    val capability = enhancement.capability

    var selectedAssetID by remember { mutableStateOf<String?>(null) }
    var method by remember { mutableStateOf(EnhancementMethod.INTERPOLATION) }
    var targetFPS by remember { mutableIntStateOf(60) }
    var scaleFactor by remember { mutableIntStateOf(2) }
    var hdrOutput by remember { mutableStateOf(false) }
    var outputName by remember { mutableStateOf("") }
    var showConfigure by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { enhancement.reloadCapability() }

    // Refresh the project envelope once the verified output becomes a real
    // project asset, so the preview/save surfaces see it immediately.
    val importCompleted = enhancement.status?.receipt?.importedAssetID != null
    LaunchedEffect(importCompleted) {
        if (importCompleted) controller.reload()
    }

    val videoAssets = controller.envelope.project.assets.filter { it.kind == "video" }
    val selectedAsset = videoAssets.firstOrNull { it.id == selectedAssetID }

    if (showConfigure) {
        MediaEnhancementConfigurationSheet(
            controller = r2.enhancementConfiguration,
            onDismiss = {
                showConfigure = false
                enhancement.reloadCapability()
            },
        )
        return
    }

    FloeActionSheet(visible = true, onDismiss = onDismiss) {
        Column(Modifier.fillMaxSize()) {
            Row(
                Modifier.fillMaxWidth().padding(start = 16.dp, end = 10.dp, top = 8.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                FloeText(
                    stringResource(R.string.media_enhancement_title),
                    style = Floe.typography.section,
                    modifier = Modifier.weight(1f),
                )
                if (enhancement.submitting) FloeActivityIndicator()
                FloeCapsuleAction(
                    label = stringResource(R.string.media_refresh),
                    onClick = { enhancement.reloadCapability() },
                    enabled = !enhancement.capabilityLoading,
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
                val failure = enhancement.failure
                when {
                    capability == null -> Row(
                        Modifier.fillMaxWidth().padding(16.dp),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        FloeActivityIndicator()
                        FloeText(
                            stringResource(R.string.media_enhancement_checking),
                            style = Floe.typography.metadata,
                        )
                    }
                    failure != null -> MediaInlineFailure(
                        failure = failure,
                        onRetry = { enhancement.reloadCapability() },
                    )
                    else -> {
                        EnhancementCapabilityBlock(
                            capability = capability,
                            interpolationSelected = method == EnhancementMethod.INTERPOLATION,
                            onSelectMethod = { method = it },
                            onConfigure = { showConfigure = true },
                        )
                        FloeDivider()
                        EnhancementInputRow(
                            assets = videoAssets,
                            selectedID = selectedAssetID,
                            onSelect = { selectedAssetID = it },
                        )
                        if (selectedAsset != null) {
                            FloeDivider()
                            if (method == EnhancementMethod.INTERPOLATION) {
                                EnhancementInterpolationForm(
                                    targetFPS = targetFPS,
                                    onTargetFPS = { targetFPS = it },
                                )
                            } else {
                                EnhancementSuperResolutionForm(
                                    scaleFactor = scaleFactor,
                                    onScale = { scaleFactor = it },
                                    hdrOutput = hdrOutput,
                                    onHDR = { hdrOutput = it },
                                    backendName = capability.superResolutionBackendName,
                                )
                            }
                            FloePlainFormField(
                                label = stringResource(R.string.media_enhancement_output_name),
                                value = outputName,
                                onValueChange = { outputName = it },
                            )
                            EnhancementSubmitBlock(
                                controller = controller,
                                enhancement = enhancement,
                                selectedAssetPath = selectedAsset.relativePath,
                                method = method,
                                targetFPS = targetFPS,
                                scaleFactor = scaleFactor,
                                hdrOutput = hdrOutput,
                                outputName = outputName,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun EnhancementCapabilityBlock(
    capability: com.floe.android.feature.workbench.EnhancementCapability,
    interpolationSelected: Boolean,
    onSelectMethod: (EnhancementMethod) -> Unit,
    onConfigure: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            FloeText(
                stringResource(R.string.media_enhancement_method),
                style = Floe.typography.metadata,
                modifier = Modifier.weight(1f),
            )
            FloeCapsuleAction(
                label = stringResource(R.string.media_enhancement_configure),
                onClick = onConfigure,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FloeCapsuleAction(
                label = stringResource(R.string.media_enhancement_interpolation),
                onClick = { onSelectMethod(EnhancementMethod.INTERPOLATION) },
                enabled = capability.interpolationReady || interpolationSelected,
            )
            FloeCapsuleAction(
                label = stringResource(R.string.media_enhancement_super_resolution),
                onClick = { onSelectMethod(EnhancementMethod.SUPER_RESOLUTION) },
                enabled = capability.superResolutionReady,
            )
        }
        val reason = if (interpolationSelected) {
            capability.interpolationUnavailableReason
        } else {
            capability.superResolutionUnavailableReason
        }
        val reasonCopy = EnhancementErrorCopy.unavailableReason(reason)
        if (reasonCopy != null) {
            FloeText(
                reasonCopy,
                style = Floe.typography.metadata,
                color = Floe.colors.pending,
            )
        }
    }
}

@Composable
private fun EnhancementInputRow(
    assets: List<com.floe.android.feature.workbench.MediaAssetReference>,
    selectedID: String?,
    onSelect: (String) -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        FloeText(
            stringResource(R.string.media_enhancement_input),
            style = Floe.typography.metadata,
        )
        if (assets.isEmpty()) {
            FloeText(
                stringResource(R.string.media_enhancement_no_video_assets),
                style = Floe.typography.metadata,
            )
        } else {
            assets.forEach { asset ->
                FloeCapsuleAction(
                    label = asset.originalName,
                    onClick = { onSelect(asset.id) },
                    enabled = true,
                )
            }
            if (selectedID == null) {
                FloeText(
                    stringResource(R.string.media_enhancement_pick_input),
                    style = Floe.typography.metadata,
                )
            }
        }
    }
}

@Composable
private fun EnhancementInterpolationForm(
    targetFPS: Int,
    onTargetFPS: (Int) -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        FloeText(
            stringResource(R.string.media_enhancement_target_fps),
            style = Floe.typography.metadata,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            INTERPOLATION_FPS_PRESETS.forEach { fps ->
                FloeCapsuleAction(
                    label = stringResource(R.string.media_enhancement_fps_label, fps),
                    onClick = { onTargetFPS(fps) },
                    enabled = true,
                )
            }
        }
    }
}

@Composable
private fun EnhancementSuperResolutionForm(
    scaleFactor: Int,
    onScale: (Int) -> Unit,
    hdrOutput: Boolean,
    onHDR: (Boolean) -> Unit,
    backendName: String?,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        FloeText(
            stringResource(R.string.media_enhancement_scale),
            style = Floe.typography.metadata,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf(2, 3, 4).forEach { scale ->
                FloeCapsuleAction(
                    label = stringResource(R.string.media_enhancement_scale_label, scale),
                    onClick = { onScale(scale) },
                    enabled = true,
                )
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            FloeInlineSwitch(
                checked = hdrOutput,
                onCheckedChange = onHDR,
                description = stringResource(R.string.media_enhancement_hdr_output),
            )
        }
        if (hdrOutput) {
            FloeText(
                stringResource(R.string.media_enhancement_hdr_note),
                style = Floe.typography.metadata,
                color = Floe.colors.pending,
            )
        }
        if (backendName != null) {
            FloeText(
                stringResource(R.string.media_enhancement_backend, backendName),
                style = Floe.typography.metadata,
            )
        }
    }
}

@Composable
private fun EnhancementSubmitBlock(
    controller: MediaEditorController,
    enhancement: WorkbenchEnhancementController,
    selectedAssetPath: String,
    method: EnhancementMethod,
    targetFPS: Int,
    scaleFactor: Int,
    hdrOutput: Boolean,
    outputName: String,
) {
    val status = enhancement.status
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        when {
            status == null -> {
                val fallbackName = defaultEnhancementOutputName(selectedAssetPath, method)
                val finalName = outputName.trim().ifEmpty { fallbackName }
                FloeCapsuleAction(
                    label = stringResource(R.string.media_enhancement_submit),
                    onClick = {
                        val operation = when (method) {
                            EnhancementMethod.INTERPOLATION ->
                                EnhancementOperation.Interpolation(targetFPS.toDouble())
                            EnhancementMethod.SUPER_RESOLUTION ->
                                EnhancementOperation.SuperResolution(
                                    scaleFactor = scaleFactor,
                                    bitDepth = if (hdrOutput) 10 else 8,
                                )
                        }
                        enhancement.submit(
                            EnhancementRequest(
                                inputRelativePath = selectedAssetPath,
                                operation = operation,
                                outputFileName = finalName,
                            ),
                        )
                    },
                    enabled = !enhancement.submitting && !enhancement.busy,
                )
                FloeText(
                    stringResource(
                        R.string.media_enhancement_output_preview,
                        outputName.trim().ifEmpty { fallbackName },
                    ),
                    style = Floe.typography.metadata,
                )
            }
            status.state == EnhancementJobState.COMPLETED && status.receipt != null -> {
                val receipt = requireNotNull(status.receipt)
                // The native settle commits + verifies the output, then
                // re-enters the original importAsset ownership. Until that
                // identity lands the import is pending; drive it once (the
                // native retry is idempotent through the durable import
                // receipt) and reload the editor envelope when it lands.
                val importPending = receipt.importedAssetID == null &&
                    receipt.importErrorCode == null
                LaunchedEffect(status.jobID, importPending) {
                    if (importPending) enhancement.importOutput()
                }
                EnhancementReceiptView(
                    receipt = receipt,
                    importing = importPending,
                    onImport = { enhancement.importOutput() },
                )
            }
            else -> {
                val progress = status.progress
                FloeText(
                    stringResource(
                        R.string.media_enhancement_state,
                        status.state.name.lowercase(Locale.ROOT),
                    ),
                    style = Floe.typography.metadata,
                )
                if (progress != null && progress.totalUnits > 0) {
                    FloeText(
                        stringResource(
                            R.string.media_enhancement_progress,
                            progress.completedUnits,
                            progress.totalUnits,
                        ),
                        style = Floe.typography.metadata,
                    )
                }
                if (status.canCancel) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.media_cancel),
                        onClick = { enhancement.cancel() },
                        enabled = true,
                    )
                }
                if (status.state == EnhancementJobState.OUTCOME_UNKNOWN) {
                    FloeText(
                        stringResource(R.string.media_enhancement_outcome_unknown),
                        style = Floe.typography.metadata,
                        color = Floe.colors.pending,
                    )
                }
                if (status.state == EnhancementJobState.FAILED) {
                    FloeText(
                        EnhancementErrorCopy.failure(status.errorCode, status.errorDetail),
                        style = Floe.typography.metadata,
                        color = Floe.colors.destructive,
                    )
                }
            }
        }
    }
}

@Composable
private fun EnhancementReceiptView(
    receipt: com.floe.android.feature.workbench.EnhancementReceipt,
    importing: Boolean,
    onImport: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        FloeText(
            stringResource(R.string.media_enhancement_receipt_title),
            style = Floe.typography.metadata,
        )
        FloeText(
            stringResource(
                R.string.media_enhancement_receipt_method,
                receipt.engine,
                receipt.method.name.lowercase(Locale.ROOT),
            ),
            style = Floe.typography.metadata,
        )
        FloeText(
            stringResource(
                R.string.media_enhancement_receipt_source,
                receipt.sourceWidth,
                receipt.sourceHeight,
                receipt.sourceFPS,
            ),
            style = Floe.typography.metadata,
        )
        FloeText(
            stringResource(
                R.string.media_enhancement_receipt_output,
                receipt.outputWidth,
                receipt.outputHeight,
                receipt.outputFPS,
            ),
            style = Floe.typography.metadata,
        )
        FloeText(
            stringResource(
                R.string.media_enhancement_receipt_file,
                formatBytes(receipt.outputBytes),
                receipt.outputSHA256.take(12),
            ),
            style = Floe.typography.metadata,
        )
        FloeText(
            stringResource(
                R.string.media_enhancement_receipt_path,
                receipt.outputRelativePath,
            ),
            style = Floe.typography.metadata,
        )
        when {
            receipt.importedAssetID != null -> FloeText(
                stringResource(R.string.media_enhancement_import_added),
                style = Floe.typography.metadata,
                color = Floe.colors.success,
            )
            importing -> Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeActivityIndicator()
                FloeText(
                    stringResource(R.string.media_enhancement_import_adding),
                    style = Floe.typography.metadata,
                )
            }
            else -> {
                FloeText(
                    stringResource(R.string.media_enhancement_import_failed),
                    style = Floe.typography.metadata,
                    color = Floe.colors.pending,
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.media_enhancement_import_retry),
                    onClick = onImport,
                )
            }
        }
    }
}

private fun defaultEnhancementOutputName(inputPath: String, method: EnhancementMethod): String {
    val base = inputPath.substringAfterLast('/').substringBeforeLast('.')
    val suffix = when (method) {
        EnhancementMethod.INTERPOLATION -> "enhanced-fps"
        EnhancementMethod.SUPER_RESOLUTION -> "enhanced-sr"
    }
    return "$base-$suffix.mp4"
}
