// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeText
import com.floe.android.feature.workbench.ImageLayer
import com.floe.android.feature.workbench.ui.state.LayerOperationCompletion
import com.floe.android.feature.workbench.ui.state.MediaEditorController
import java.util.Locale
import kotlin.math.roundToInt

/**
 * C03 selection/layer operation entry. These are REAL project commands
 * (`setImageSelection`, `addImageLayer(fill)`, `cutSelection`, and the
 * renderer-backed `copySelection`/`mergeLayers`), not screen captures or
 * inferred bucket fills. Every merge/copy raster comes from the shared
 * platform renderer and is committed through the normal native CAS/undo path.
 */
@Composable
internal fun MediaLayerOperationsSheet(
    controller: MediaEditorController,
    onDismiss: () -> Unit,
) {
    var selectedForMerge by remember(controller.project.revision) {
        mutableStateOf(
            setOfNotNull(controller.selectedLayerID),
        )
    }
    var fillColor by remember { mutableStateOf("#FFFFFF") }
    var fillOpacity by remember { mutableFloatStateOf(1f) }
    var selectionX by remember { mutableStateOf("0") }
    var selectionY by remember { mutableStateOf("0") }
    var selectionWidth by remember { mutableStateOf("1") }
    var selectionHeight by remember { mutableStateOf("1") }
    LaunchedEffect(Unit) { controller.clearLayerOperation() }
    val layer = controller.selectedLayer
    val selectionReady = controller.hasSelection
    val ready = controller.writable && !controller.busy && !controller.needsReload
    FloeActionSheet(visible = true, onDismiss = onDismiss) {
        Column(Modifier.fillMaxWidth()) {
            Row(
                Modifier.fillMaxWidth().padding(16.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FloeText(
                    layerText("Selection & layers", "选区与图层"),
                    style = Floe.typography.section,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleAction(
                    label = layerText("Done", "完成"),
                    onClick = onDismiss,
                )
            }
            FloeDivider()
            Column(
                Modifier.fillMaxWidth().padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                FloeText(
                    if (selectionReady) {
                        layerText("A vector selection is active.", "已存在矢量选区。")
                    } else {
                        layerText(
                            "Create a selection to fill, cut or copy.",
                            "请先创建选区，才能填充、剪切或拷贝。",
                        )
                    },
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FloeCapsuleAction(
                        label = layerText("Select all", "全选"),
                        onClick = { controller.selectAll() },
                        enabled = ready,
                    )
                    FloeCapsuleAction(
                        label = layerText("Clear selection", "清除选区"),
                        onClick = { controller.clearSelection() },
                        enabled = ready && controller.project.imageSelection != null,
                    )
                }
                FloeText(
                    layerText(
                        "Rectangle selection in normalized 0...1 coordinates",
                        "矩形选区（归一化坐标 0...1）",
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    FloePlainFormField(
                        label = "X",
                        value = selectionX,
                        onValueChange = { selectionX = it.take(6) },
                        modifier = Modifier.weight(1f),
                    )
                    FloePlainFormField(
                        label = "Y",
                        value = selectionY,
                        onValueChange = { selectionY = it.take(6) },
                        modifier = Modifier.weight(1f),
                    )
                    FloePlainFormField(
                        label = "W",
                        value = selectionWidth,
                        onValueChange = { selectionWidth = it.take(6) },
                        modifier = Modifier.weight(1f),
                    )
                    FloePlainFormField(
                        label = "H",
                        value = selectionHeight,
                        onValueChange = { selectionHeight = it.take(6) },
                        modifier = Modifier.weight(1f),
                    )
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FloeCapsuleAction(
                        label = layerText("Set rectangle selection", "设置矩形选区"),
                        onClick = {
                            val x = selectionX.toDoubleOrNull() ?: return@FloeCapsuleAction
                            val y = selectionY.toDoubleOrNull() ?: return@FloeCapsuleAction
                            val w = selectionWidth.toDoubleOrNull() ?: return@FloeCapsuleAction
                            val h = selectionHeight.toDoubleOrNull() ?: return@FloeCapsuleAction
                            controller.setRectangleSelection(x, y, w, h)
                        },
                        enabled = ready,
                    )
                }

                FloeDivider()
                FloeText(
                    layerText("Fill selection", "填充选区"),
                    style = Floe.typography.bodyEmphasized,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf("#FFFFFF", "#000000", "#0081F6", "#FF3B30", "#34C759").forEach { color ->
                        FloeCapsuleAction(
                            label = color,
                            onClick = { fillColor = color },
                            tint = if (color == fillColor) Floe.colors.accent else null,
                            enabled = ready,
                        )
                    }
                }
                MediaSliderRow(
                    label = layerText("Opacity", "不透明度"),
                    value = fillOpacity,
                    range = 0.02f..1f,
                    enabled = ready,
                    format = { "${(it * 100).roundToInt()}%" },
                    onCommit = { fillOpacity = it },
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FloeCapsuleAction(
                        label = layerText("Fill selection", "填充选区"),
                        onClick = {
                            controller.fillSelection(fillColor, fillOpacity.toDouble())
                        },
                        enabled = ready && selectionReady,
                        tint = Floe.colors.accent,
                    )
                    FloeCapsuleAction(
                        label = layerText("Cut from layer", "从图层剪切"),
                        onClick = { controller.cutSelection() },
                        enabled = ready && selectionReady && layer?.isLocked == false,
                    )
                    FloeCapsuleAction(
                        label = layerText("Copy as layer", "拷贝为图层"),
                        onClick = { controller.copySelectionToNewLayer() },
                        enabled = ready && controller.layerRasterAvailable &&
                            selectionReady && layer?.isLocked == false,
                        tint = Floe.colors.accent,
                    )
                }

                FloeDivider()
                FloeText(
                    layerText("Merge layers", "合并图层"),
                    style = Floe.typography.bodyEmphasized,
                )
                FloeText(
                    layerText(
                        "Choose at least two visible layers. The result is one reversible image layer.",
                        "选择至少两个可见图层。结果是一个可撤销的图像图层。",
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                controller.project.imageLayers.asReversed().forEach { item ->
                    MergeLayerRow(
                        layer = item,
                        checked = item.id in selectedForMerge,
                        onToggle = {
                            selectedForMerge = if (item.id in selectedForMerge) {
                                selectedForMerge - item.id
                            } else {
                                selectedForMerge + item.id
                            }
                        },
                        enabled = ready && !item.isLocked && !item.isHidden,
                    )
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FloeCapsuleAction(
                        label = layerText("Merge selected", "合并所选"),
                        onClick = { controller.mergeLayers(selectedForMerge.toList()) },
                        enabled = ready && controller.layerRasterAvailable &&
                            selectedForMerge.size >= 2,
                        tint = Floe.colors.accent,
                    )
                }

                controller.layerOperation.failure?.let { failure ->
                    FloeText(
                        layerFailureText(failure.code),
                        style = Floe.typography.metadata,
                        color = Floe.colors.destructive,
                    )
                }
                controller.layerOperation.completed?.let { completion ->
                    FloeText(
                        layerCompletionText(completion),
                        style = Floe.typography.metadata,
                        color = Floe.colors.success,
                    )
                }
                if (controller.layerOperation.busy) {
                    FloeText(
                        layerText("Rendering the real layer pixels…", "正在渲染真实图层像素…"),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
            }
        }
    }
}

@Composable
private fun MergeLayerRow(
    layer: ImageLayer,
    checked: Boolean,
    onToggle: () -> Unit,
    enabled: Boolean,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(if (checked) Floe.colors.accentFillFaint else Floe.colors.readingSurface)
            .clickable(enabled = enabled, onClick = onToggle)
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        FloeText(
            if (checked) "✓" else "○",
            style = Floe.typography.bodyEmphasized,
            color = if (checked) Floe.colors.accent else Floe.colors.secondaryLabel,
        )
        FloeText(
            layer.name.ifBlank { layer.kind },
            style = Floe.typography.metadata,
            color = if (layer.isHidden) Floe.colors.tertiaryLabel else Floe.colors.label,
            modifier = Modifier.weight(1f),
        )
        if (layer.isHidden) {
            FloeText(
                layerText("Hidden", "隐藏"),
                style = Floe.typography.metadata,
                color = Floe.colors.tertiaryLabel,
            )
        }
    }
}

private fun layerText(english: String, chinese: String): String =
    if (Locale.getDefault().language == "zh") chinese else english

private fun layerCompletionText(completion: LayerOperationCompletion): String = when (completion) {
    LayerOperationCompletion.SELECTION_SET -> layerText("Selection set.", "已设置选区。")
    LayerOperationCompletion.SELECTION_CLEARED -> layerText("Selection cleared.", "已清除选区。")
    LayerOperationCompletion.FILLED -> layerText("Filled the selection.", "已填充选区。")
    LayerOperationCompletion.CUT -> layerText("Cut the selection from the layer.", "已从图层剪切选区。")
    LayerOperationCompletion.COPIED -> layerText("Copied the selection as a layer.", "已将选区拷贝为图层。")
    LayerOperationCompletion.MERGED -> layerText("Merged the selected layers.", "已合并所选图层。")
}

private fun layerFailureText(code: String?): String = when (code) {
    "selectionRequired" -> layerText(
        "Create a selection first.", "请先创建选区。")
    "layerLocked" -> layerText(
        "Unlock the layer before editing it.", "请先解锁图层再编辑。")
    "mergeNeedsTwoLayers" -> layerText(
        "Choose at least two different layers.", "请选择至少两个不同图层。")
    "layerRasterRevisionChanged" -> layerText(
        "The project changed while rendering. Reopen the layer operations.",
        "渲染期间项目已更改，请重新打开图层操作。",
    )
    "renderUnsupported", "unsupportedSourceFormat" -> layerText(
        "These layers cannot be composited on this device.", "当前设备无法合成这些图层。")
    else -> layerText(
        "The layer operation failed. The original project is unchanged.",
        "图层操作失败，原项目保持不变。",
    )
}
