// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Slider
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
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeInlineSwitch
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph
import com.floe.android.feature.workbench.ImageLayer
import com.floe.android.feature.workbench.ImageLayerAdjustment
import com.floe.android.feature.workbench.ImageTextContent
import com.floe.android.feature.workbench.MediaAssetReference
import com.floe.android.feature.workbench.ui.state.MediaEditorController
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Assets/layers list and properties controls for the media editor. These are
 * CONTENT panels: on a wide window they sit beside the preview; on compact
 * windows the editor presents them inside its own sheets.
 */
@Composable
internal fun MediaAssetsPanel(
    controller: MediaEditorController,
    onImport: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var selectedAssetID by remember(controller.projectID) { mutableStateOf<String?>(null) }
    LaunchedEffect(controller.project.assets) {
        if (controller.project.assets.none { it.id == selectedAssetID }) {
            selectedAssetID = null
        }
    }
    Column(modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        Row(
            Modifier.fillMaxWidth().padding(start = 14.dp, end = 8.dp, top = 6.dp, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FloeText(
                stringResource(R.string.media_assets),
                style = Floe.typography.section,
                modifier = Modifier.weight(1f),
            )
            FloeCapsuleAction(
                label = stringResource(R.string.media_import_asset),
                onClick = onImport,
                enabled = controller.isImageProject && controller.writable &&
                    !controller.busy && !controller.needsReload,
            )
        }
        FloeDivider()
        if (controller.project.assets.isEmpty()) {
            FloeText(
                stringResource(R.string.media_no_assets),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(16.dp),
            )
        } else {
            LazyColumn(Modifier.weight(1f)) {
                items(controller.project.assets, key = { it.id }) { asset ->
                    MediaAssetRow(
                        controller = controller,
                        asset = asset,
                        selected = asset.id == selectedAssetID,
                        onClick = { selectedAssetID = asset.id },
                    )
                }
            }
            val selected = controller.project.assets.firstOrNull { it.id == selectedAssetID }
            if (selected != null && selected.kind == "image" && controller.isImageProject) {
                FloeDivider()
                Row(Modifier.fillMaxWidth().padding(10.dp), horizontalArrangement = Arrangement.End) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.media_add_layer),
                        onClick = {
                            controller.addAssetAsLayer(selected.id)
                            selectedAssetID = null
                        },
                        enabled = controller.writable && !controller.busy && !controller.needsReload,
                        tint = Floe.colors.accent,
                    )
                }
            }
        }
    }
}

@Composable
private fun MediaAssetRow(
    controller: MediaEditorController,
    asset: MediaAssetReference,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val missing = asset.id in controller.missingAssetIDs
    val bitmap = controller.assetBitmaps[asset.id]
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = FloeLayout.MinimumTarget)
            .background(if (selected) Floe.colors.accentFillFaint else Floe.colors.readingSurface)
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            Modifier.size(40.dp).clip(RoundedCornerShape(8.dp))
                .background(Floe.colors.fillTertiary),
            contentAlignment = Alignment.Center,
        ) {
            if (bitmap != null) {
                Image(
                    bitmap = bitmap.asImageBitmap(),
                    contentDescription = asset.originalName,
                    modifier = Modifier.fillMaxSize(),
                    contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                )
            } else {
                IconGlyph(
                    if (asset.kind == "video") FloeIcons.PlayRuns else FloeIcons.Photo,
                    Floe.colors.secondaryLabel,
                    20.dp,
                )
            }
        }
        Column(Modifier.weight(1f)) {
            FloeText(
                asset.originalName.ifBlank { stringResource(R.string.media_layer_image) },
                style = Floe.typography.metadata,
                color = Floe.colors.label,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
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
        }
        if (missing) {
            FloeBadgePill(
                text = stringResource(R.string.media_missing_asset_title),
                tone = FloeBadgeTone.PENDING,
            )
        }
    }
}

@Composable
internal fun MediaLayersPanel(
    controller: MediaEditorController,
    onAddText: () -> Unit,
    onLayerOperations: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        Row(
            Modifier.fillMaxWidth().padding(start = 14.dp, end = 8.dp, top = 6.dp, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FloeText(
                stringResource(R.string.media_layers),
                style = Floe.typography.section,
                modifier = Modifier.weight(1f),
            )
            FloeCapsuleAction(
                label = stringResource(R.string.media_add_text_layer),
                onClick = onAddText,
                enabled = controller.isImageProject && controller.writable &&
                    !controller.busy && !controller.needsReload,
            )
            FloeCapsuleAction(
                label = if (java.util.Locale.getDefault().language == "zh") "选区" else "Select",
                onClick = onLayerOperations,
                enabled = controller.isImageProject && controller.writable &&
                    !controller.busy && !controller.needsReload,
                tint = Floe.colors.accent,
            )
        }
        FloeDivider()
        if (controller.project.imageLayers.isEmpty()) {
            FloeText(
                stringResource(R.string.media_no_layers),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(16.dp),
            )
        } else {
            LazyColumn(Modifier.weight(1f)) {
                items(
                    controller.project.imageLayers.asReversed(),
                    key = { it.id },
                ) { layer ->
                    MediaLayerRow(controller = controller, layer = layer)
                }
            }
        }
    }
}

@Composable
private fun MediaLayerRow(controller: MediaEditorController, layer: ImageLayer) {
    val selected = controller.selectedLayerID == layer.id
    val missing = layer.assetID?.let { it in controller.missingAssetIDs } == true
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = FloeLayout.MinimumTarget)
            .background(if (selected) Floe.colors.accentFillFaint else Floe.colors.readingSurface)
            .clickable { controller.selectLayer(layer.id) }
            .padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        IconGlyph(
            when (layer.kind) {
                "image" -> FloeIcons.Photo
                "text" -> FloeIcons.Pencil
                "freehand" -> FloeIcons.Wand
                else -> FloeIcons.Folder
            },
            if (selected) Floe.colors.accent else Floe.colors.secondaryLabel,
            18.dp,
        )
        Column(Modifier.weight(1f)) {
            FloeText(
                layer.name.ifBlank { stringResource(R.string.media_layer_name_unnamed) },
                style = Floe.typography.metadata,
                color = Floe.colors.label,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                FloeText(
                    stringResource(layerKindLabelRes(layer)),
                    style = Floe.typography.metadata,
                    color = Floe.colors.tertiaryLabel,
                )
                if (missing) {
                    FloeText(
                        "· " + stringResource(R.string.media_layer_missing),
                        style = Floe.typography.metadata,
                        color = Floe.colors.pending,
                    )
                }
            }
        }
        FloeCircleButton(
            icon = if (layer.isHidden) FloeIcons.EyeSlash else FloeIcons.Eye,
            contentDescription = stringResource(
                if (layer.isHidden) R.string.media_layer_show else R.string.media_layer_hide),
            onClick = { controller.setHidden(!layer.isHidden) },
            visualSize = 28.dp,
            iconSize = 14.dp,
            enabled = !controller.busy,
        )
        FloeCircleButton(
            icon = FloeIcons.ShieldCheck,
            contentDescription = stringResource(
                if (layer.isLocked) R.string.media_layer_unlock else R.string.media_layer_lock),
            onClick = { controller.setLocked(!layer.isLocked) },
            visualSize = 28.dp,
            iconSize = 14.dp,
            tint = if (layer.isLocked) Floe.colors.accent else Floe.colors.tertiaryLabel,
            enabled = !controller.busy,
        )
    }
}

@Composable
internal fun MediaPropertiesPanel(
    controller: MediaEditorController,
    drawMode: Boolean,
    onToggleDraw: () -> Unit,
    brushWidth: Float,
    onBrushWidth: (Float) -> Unit,
    brushColorHex: String,
    onBrushColor: (String) -> Unit,
    onDeleteLayer: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier
            .fillMaxSize()
            .background(Floe.colors.readingSurface)
            .verticalScroll(rememberScrollState()),
    ) {
        FloeText(
            stringResource(R.string.media_properties),
            style = Floe.typography.section,
            modifier = Modifier.padding(start = 14.dp, end = 14.dp, top = 10.dp, bottom = 6.dp),
        )
        FloeDivider()
        val layer = controller.selectedLayer
        if (layer == null) {
            MediaCanvasProperties(
                controller = controller,
                drawMode = drawMode,
                onToggleDraw = onToggleDraw,
                brushWidth = brushWidth,
                onBrushWidth = onBrushWidth,
                brushColorHex = brushColorHex,
                onBrushColor = onBrushColor,
            )
            return@Column
        }
        MediaLayerProperties(
            controller = controller,
            layer = layer,
            onDelete = onDeleteLayer,
        )
    }
}

@Composable
private fun MediaCanvasProperties(
    controller: MediaEditorController,
    drawMode: Boolean,
    onToggleDraw: () -> Unit,
    brushWidth: Float,
    onBrushWidth: (Float) -> Unit,
    brushColorHex: String,
    onBrushColor: (String) -> Unit,
) {
    val canvas = controller.project.canvas
    if (canvas != null) {
        FloeText(
            stringResource(R.string.media_canvas_size, canvas.width, canvas.height) +
                canvas.frameRate?.let { " · $it fps" }.orEmpty(),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp),
        )
    }
    if (controller.isVideoProject) {
        Column(Modifier.padding(14.dp)) {
            FloeText(
                stringResource(R.string.media_video_unavailable_title),
                style = Floe.typography.bodyEmphasized,
            )
            FloeText(
                stringResource(R.string.media_video_unavailable_body),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(top = 4.dp),
            )
            controller.project.assets.forEach { asset ->
                Row(
                    Modifier.fillMaxWidth().padding(top = 10.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconGlyph(FloeIcons.PlayRuns, Floe.colors.secondaryLabel, 18.dp)
                    FloeText(
                        asset.originalName,
                        style = Floe.typography.metadata,
                        color = Floe.colors.label,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    FloeText(
                        asset.metadata?.durationSeconds?.let {
                            stringResource(
                                R.string.media_video_duration,
                                String.format(Locale.US, "%.1f", it),
                            )
                        } ?: assetMeta(asset),
                        style = Floe.typography.metadata,
                        color = Floe.colors.tertiaryLabel,
                    )
                }
            }
        }
        return
    }
    if (controller.isImageProject) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FloeText(
                stringResource(R.string.media_draw),
                style = Floe.typography.body,
                modifier = Modifier.weight(1f),
            )
            FloeInlineSwitch(
                checked = drawMode,
                onCheckedChange = { onToggleDraw() },
                description = stringResource(R.string.media_draw),
                enabled = controller.writable && !controller.busy && !controller.needsReload,
            )
        }
        if (drawMode) {
            MediaSliderRow(
                label = stringResource(R.string.media_draw_width),
                value = brushWidth,
                range = 2f..120f,
                enabled = !controller.busy,
                format = { it.roundToInt().toString() },
                onCommit = onBrushWidth,
            )
            MediaColorRow(
                label = stringResource(R.string.media_draw_color),
                selected = brushColorHex,
                onSelect = onBrushColor,
            )
            FloeText(
                stringResource(R.string.media_draw_hint),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 6.dp),
            )
        }
        FloeDivider(Modifier.padding(vertical = 6.dp))
        FloeText(
            stringResource(R.string.media_canvas_adjustment),
            style = Floe.typography.groupHeader,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 4.dp),
        )
        val adjustment = controller.project.canvasAdjustment
        MediaSliderRow(
            label = stringResource(R.string.media_adjustments_brightness),
            value = (adjustment.brightness ?: 0.0).toFloat(),
            range = -1f..1f,
            enabled = !controller.busy && !controller.needsReload,
            format = { String.format(Locale.US, "%.2f", it) },
            onCommit = { value ->
                controller.setCanvasAdjustment(
                    adjustment.copy(brightness = if (value == 0f) null else value.toDouble()))
            },
        )
        MediaSliderRow(
            label = stringResource(R.string.media_adjustments_contrast),
            value = (adjustment.contrast ?: 0.0).toFloat(),
            range = -1f..1f,
            enabled = !controller.busy && !controller.needsReload,
            format = { String.format(Locale.US, "%.2f", it) },
            onCommit = { value ->
                controller.setCanvasAdjustment(
                    adjustment.copy(contrast = if (value == 0f) null else value.toDouble()))
            },
        )
        MediaSliderRow(
            label = stringResource(R.string.media_adjustments_saturation),
            value = (adjustment.saturation ?: 1.0).toFloat(),
            range = 0f..2f,
            enabled = !controller.busy && !controller.needsReload,
            format = { String.format(Locale.US, "%.2f", it) },
            onCommit = { value ->
                controller.setCanvasAdjustment(
                    adjustment.copy(saturation = if (value == 1f) null else value.toDouble()))
            },
        )
        FloeText(
            stringResource(R.string.media_adjustments_note),
            style = Floe.typography.metadata,
            color = Floe.colors.tertiaryLabel,
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp),
        )
    } else {
        FloeText(
            stringResource(R.string.media_select_layer_hint),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.padding(14.dp),
        )
    }
}

@Composable
private fun MediaLayerProperties(
    controller: MediaEditorController,
    layer: ImageLayer,
    onDelete: () -> Unit,
) {
    val missing = layer.assetID?.let { it in controller.missingAssetIDs } == true
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Column(Modifier.weight(1f)) {
            FloeText(
                layer.name.ifBlank { stringResource(R.string.media_layer_name_unnamed) },
                style = Floe.typography.bodyEmphasized,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            FloeText(
                stringResource(layerKindLabelRes(layer)),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
        if (missing) {
            FloeBadgePill(
                text = stringResource(R.string.media_layer_missing),
                tone = FloeBadgeTone.PENDING,
            )
        }
        if (layer.isLocked) {
            FloeBadgePill(
                text = stringResource(R.string.media_layer_lock),
                tone = FloeBadgeTone.SECONDARY,
            )
        }
    }
    val enabled = controller.writable && !controller.busy && !controller.needsReload &&
        !layer.isLocked
    MediaSliderRow(
        label = stringResource(R.string.media_layer_opacity),
        value = layer.opacity.toFloat(),
        range = 0f..1f,
        enabled = controller.writable && !controller.busy && !controller.needsReload,
        format = { "${(it * 100).roundToInt()}%" },
        onCommit = { controller.setOpacity(it.toDouble()) },
    )
    MediaSliderRow(
        label = stringResource(R.string.media_layer_scale),
        value = layer.transform.scale.toFloat(),
        range = 0.05f..8f,
        enabled = enabled,
        format = { String.format(Locale.US, "%.2f", it) },
        onCommit = { controller.setScale(it.toDouble()) },
    )
    MediaSliderRow(
        label = stringResource(R.string.media_layer_rotation),
        value = layer.transform.rotationDegrees.toFloat(),
        range = -180f..180f,
        enabled = enabled,
        format = { "${it.roundToInt()}°" },
        onCommit = { controller.setRotation(it.toDouble()) },
    )
    MediaSliderRow(
        label = stringResource(R.string.media_center_x),
        value = layer.transform.centerX.toFloat(),
        range = 0f..1f,
        enabled = enabled,
        format = { String.format(Locale.US, "%.2f", it) },
        onCommit = { controller.setCenter(it.toDouble(), layer.transform.centerY) },
    )
    MediaSliderRow(
        label = stringResource(R.string.media_center_y),
        value = layer.transform.centerY.toFloat(),
        range = 0f..1f,
        enabled = enabled,
        format = { String.format(Locale.US, "%.2f", it) },
        onCommit = { controller.setCenter(layer.transform.centerX, it.toDouble()) },
    )
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        FloeCapsuleAction(
            label = stringResource(R.string.media_layer_flip_horizontal),
            onClick = { controller.flip(horizontal = true) },
            enabled = enabled,
        )
        FloeCapsuleAction(
            label = stringResource(R.string.media_layer_flip_vertical),
            onClick = { controller.flip(horizontal = false) },
            enabled = enabled,
        )
    }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloeText(
            stringResource(R.string.media_layer_visible),
            style = Floe.typography.body,
            modifier = Modifier.weight(1f),
        )
        FloeInlineSwitch(
            checked = !layer.isHidden,
            onCheckedChange = { visible -> controller.setHidden(!visible) },
            description = stringResource(R.string.media_layer_visible),
            enabled = !controller.busy && !controller.needsReload,
        )
    }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloeText(
            stringResource(R.string.media_layer_lock),
            style = Floe.typography.body,
            modifier = Modifier.weight(1f),
        )
        FloeInlineSwitch(
            checked = layer.isLocked,
            onCheckedChange = { controller.setLocked(it) },
            description = stringResource(R.string.media_layer_lock),
            enabled = !controller.busy && !controller.needsReload,
        )
    }
    if (layer.kind == "image") {
        FloeDivider(Modifier.padding(vertical = 6.dp))
        FloeText(
            stringResource(R.string.media_layer_crop),
            style = Floe.typography.groupHeader,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 4.dp),
        )
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                .padding(horizontal = 14.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            FloeCapsuleAction(
                label = stringResource(R.string.media_crop_original),
                onClick = { controller.setCropAspect(null) },
                enabled = enabled,
            )
            FloeCapsuleAction(
                label = stringResource(R.string.media_crop_square),
                onClick = { controller.setCropAspect(1.0) },
                enabled = enabled,
            )
            FloeCapsuleAction(
                label = stringResource(R.string.media_crop_four_three),
                onClick = { controller.setCropAspect(4.0 / 3.0) },
                enabled = enabled,
            )
            FloeCapsuleAction(
                label = stringResource(R.string.media_crop_sixteen_nine),
                onClick = { controller.setCropAspect(16.0 / 9.0) },
                enabled = enabled,
            )
        }
    }
    if (layer.kind == "text") {
        FloeDivider(Modifier.padding(vertical = 6.dp))
        MediaTextEditor(controller = controller, layer = layer, enabled = enabled)
    }
    FloeDivider(Modifier.padding(vertical = 6.dp))
    FloeText(
        stringResource(R.string.media_adjustments),
        style = Floe.typography.groupHeader,
        color = Floe.colors.secondaryLabel,
        modifier = Modifier.padding(horizontal = 14.dp, vertical = 4.dp),
    )
    val adjustment = layer.adjustment
    MediaSliderRow(
        label = stringResource(R.string.media_adjustments_brightness),
        value = (adjustment.brightness ?: 0.0).toFloat(),
        range = -1f..1f,
        enabled = enabled,
        format = { String.format(Locale.US, "%.2f", it) },
        onCommit = { value ->
            controller.setLayerAdjustment(
                adjustment.copy(brightness = if (value == 0f) null else value.toDouble()))
        },
    )
    MediaSliderRow(
        label = stringResource(R.string.media_adjustments_contrast),
        value = (adjustment.contrast ?: 0.0).toFloat(),
        range = -1f..1f,
        enabled = enabled,
        format = { String.format(Locale.US, "%.2f", it) },
        onCommit = { value ->
            controller.setLayerAdjustment(
                adjustment.copy(contrast = if (value == 0f) null else value.toDouble()))
        },
    )
    MediaSliderRow(
        label = stringResource(R.string.media_adjustments_saturation),
        value = (adjustment.saturation ?: 1.0).toFloat(),
        range = 0f..2f,
        enabled = enabled,
        format = { String.format(Locale.US, "%.2f", it) },
        onCommit = { value ->
            controller.setLayerAdjustment(
                adjustment.copy(saturation = if (value == 1f) null else value.toDouble()))
        },
    )
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloeCircleButton(
            icon = FloeIcons.ChevronUp,
            contentDescription = stringResource(R.string.media_layer_move_up),
            onClick = { controller.moveSelectedLayer(up = true) },
            visualSize = 30.dp,
            iconSize = 15.dp,
            enabled = !controller.busy && !controller.needsReload && !layer.isLocked,
        )
        FloeCircleButton(
            icon = FloeIcons.ChevronDown,
            contentDescription = stringResource(R.string.media_layer_move_down),
            onClick = { controller.moveSelectedLayer(up = false) },
            visualSize = 30.dp,
            iconSize = 15.dp,
            enabled = !controller.busy && !controller.needsReload && !layer.isLocked,
        )
        Spacer(Modifier.weight(1f))
        FloeCapsuleAction(
            label = stringResource(R.string.media_layer_duplicate),
            onClick = { controller.duplicateSelectedLayer() },
            enabled = !controller.busy && !controller.needsReload && controller.writable,
        )
        FloeCapsuleAction(
            label = stringResource(R.string.media_layer_delete),
            onClick = onDelete,
            enabled = !controller.busy && !controller.needsReload &&
                controller.writable && !layer.isLocked,
            tint = Floe.colors.destructive,
        )
    }
}

@Composable
private fun MediaTextEditor(
    controller: MediaEditorController,
    layer: ImageLayer,
    enabled: Boolean,
) {
    val content = layer.text ?: ImageTextContent(text = "")
    var text by remember(layer.id) { mutableStateOf(content.text) }
    var fontSize by remember(layer.id) { mutableStateOf(content.fontSize.toString()) }
    var colorHex by remember(layer.id) { mutableStateOf(content.colorHex) }
    LaunchedEffect(content.text) { if (content.text != text) text = content.text }
    LaunchedEffect(content.colorHex) { if (content.colorHex != colorHex) colorHex = content.colorHex }
    FloeText(
        stringResource(R.string.media_text_content),
        style = Floe.typography.groupHeader,
        color = Floe.colors.secondaryLabel,
        modifier = Modifier.padding(horizontal = 14.dp, vertical = 4.dp),
    )
    FloePlainFormField(
        label = stringResource(R.string.media_text_content),
        value = text,
        onValueChange = { text = it.take(4096) },
        singleLine = false,
        maxLines = 6,
        minLines = 2,
        enabled = enabled,
        modifier = Modifier.padding(horizontal = 14.dp),
    )
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloePlainFormField(
            label = stringResource(R.string.media_text_size),
            value = fontSize,
            onValueChange = { fontSize = it.filter { ch -> ch.isDigit() }.take(4) },
            enabled = enabled,
        )
    }
    MediaColorRow(
        label = stringResource(R.string.media_text_color),
        selected = colorHex,
        onSelect = { colorHex = it },
    )
    Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp), horizontalArrangement = Arrangement.End) {
        FloeCapsuleAction(
            label = stringResource(R.string.media_apply),
            onClick = {
                val size = fontSize.toDoubleOrNull()?.coerceIn(1.0, 1000.0) ?: content.fontSize
                controller.setText(
                    content.copy(
                        text = text,
                        fontSize = size,
                        colorHex = colorHex,
                    ),
                )
            },
            enabled = enabled && text.isNotBlank(),
            tint = Floe.colors.accent,
        )
    }
}

@Composable
internal fun MediaColorRow(
    label: String,
    selected: String,
    onSelect: (String) -> Unit,
) {
    FloeText(
        label,
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
        modifier = Modifier.padding(start = 14.dp, top = 4.dp),
    )
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
            .padding(horizontal = 14.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        SWATCHES.forEach { hex ->
            val color = com.floe.android.feature.workbench.ui.presentation.MediaColor
                .parseCompose(hex, Floe.colors.label)
            Box(
                Modifier
                    .size(FloeLayout.MinimumTarget)
                    .clickable { onSelect(hex) }
                    .semantics { contentDescription = hex },
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    Modifier.size(28.dp).clip(RoundedCornerShape(6.dp)).background(color)
                        .then(Modifier),
                )
                if (selected.equals(hex, ignoreCase = true)) {
                    IconGlyph(FloeIcons.Checkmark, Floe.colors.accent, 14.dp)
                }
            }
        }
    }
}

@Composable
internal fun MediaSliderRow(
    label: String,
    value: Float,
    range: ClosedFloatingPointRange<Float>,
    enabled: Boolean,
    format: (Float) -> String,
    onCommit: (Float) -> Unit,
) {
    var local by remember(label, value) { mutableFloatStateOf(value) }
    Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            FloeText(
                label,
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.weight(1f),
            )
            FloeText(
                format(local),
                style = Floe.typography.metadata,
                color = Floe.colors.tertiaryLabel,
            )
        }
        Slider(
            value = local,
            onValueChange = { local = it },
            onValueChangeFinished = { onCommit(local) },
            valueRange = range,
            enabled = enabled,
            modifier = Modifier.heightIn(min = 32.dp),
        )
    }
}

@Composable
internal fun MediaTextLayerSheet(
    busy: Boolean,
    onDismiss: () -> Unit,
    onConfirm: (String, Double, String) -> Unit,
) {
    var text by remember { mutableStateOf("") }
    var size by remember { mutableFloatStateOf(48f) }
    var color by remember { mutableStateOf("#000000") }
    FloeActionSheet(visible = true, onDismiss = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(20.dp)) {
            FloeText(
                stringResource(R.string.media_add_text_layer),
                style = Floe.typography.section,
            )
            Spacer(Modifier.height(10.dp))
            FloePlainFormField(
                label = stringResource(R.string.media_text_content),
                value = text,
                onValueChange = { text = it.take(4096) },
                singleLine = false,
                maxLines = 6,
                minLines = 2,
                enabled = !busy,
            )
            MediaSliderRow(
                label = stringResource(R.string.media_text_size),
                value = size,
                range = 12f..240f,
                enabled = !busy,
                format = { it.roundToInt().toString() },
                onCommit = { size = it },
            )
            MediaColorRow(
                label = stringResource(R.string.media_text_color),
                selected = color,
                onSelect = { color = it },
            )
            Row(
                Modifier.fillMaxWidth().padding(top = 12.dp),
                horizontalArrangement = Arrangement.End,
            ) {
                FloeCapsuleAction(
                    label = stringResource(R.string.media_cancel),
                    onClick = onDismiss,
                    enabled = !busy,
                )
                Spacer(Modifier.width(10.dp))
                FloeCapsuleAction(
                    label = stringResource(R.string.media_add_layer),
                    onClick = { onConfirm(text.trim(), size.toDouble(), color) },
                    enabled = text.isNotBlank() && !busy,
                    tint = Floe.colors.accent,
                )
            }
        }
    }
}

private val SWATCHES = listOf(
    "#000000", "#FFFFFF", "#0081F6", "#FF3B30", "#FF9500", "#34C759", "#8F5CF0",
)
