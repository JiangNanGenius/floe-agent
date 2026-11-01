// SPDX-License-Identifier: MPL-2.0
package com.floe.android.designintegration

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.R
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloePrimaryAction
import com.floe.android.design.FloeStatusLine
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph
import com.floe.android.feature.canvas.DesignContentType
import com.floe.android.feature.canvas.ui.design.DesignWorkflowSheet
import com.floe.android.host.creative.CreativeDesignPendingRequest
import com.floe.android.host.creative.CreativeDesignRequestState
import com.floe.android.feature.canvas.ui.R as CanvasR

/**
 * Compact native Floe action inside the existing Creative grouping.
 *
 * This is not a new outer route: the action opens one App-owned panel above
 * the current Creative destination. The panel starts/continues a real creative
 * design request through the published creative host API only.
 */
@Composable
internal fun CreativeDesignEntryAction(
    controller: CreativeDesignEntryController,
    modifier: Modifier = Modifier,
) {
    var visible by rememberSaveable { mutableStateOf(false) }
    FloeCircleButton(
        icon = FloeIcons.Wand,
        contentDescription = stringResource(R.string.design_app_action),
        onClick = { visible = true },
        modifier = modifier,
    )
    CreativeDesignEntrySheet(
        controller = controller,
        visible = visible,
        onDismiss = {
            controller.closePanel()
            visible = false
        },
    )
}

@Composable
internal fun CreativeDesignEntrySheet(
    controller: CreativeDesignEntryController,
    visible: Boolean,
    onDismiss: () -> Unit,
) {
    if (!visible) return
    val active = controller.active
    LaunchedEffect(visible, active?.binding) {
        controller.refreshPending()
        if (active == null || active.requestState == CreativeDesignRequestState.AWAITING_FIRST_RESULT) {
            controller.refreshAssets()
        }
    }
    FloeActionSheet(
        visible = visible,
        onDismiss = onDismiss,
        maxCardWidth = 720.dp,
        maxCardHeightFraction = 0.92f,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .heightIn(max = 760.dp)
                .verticalScroll(rememberScrollState())
                .padding(20.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    FloeText(
                        stringResource(R.string.design_entry_title),
                        style = Floe.typography.section,
                    )
                    FloeText(
                        stringResource(R.string.design_entry_subtitle),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        modifier = Modifier.padding(top = 2.dp),
                    )
                }
                FloeCapsuleAction(
                    label = stringResource(R.string.design_entry_close),
                    onClick = onDismiss,
                )
            }
            controller.failure?.let { failure ->
                DesignEntryFailureLine(failure) { controller.dismissFailure() }
            }
            if (active == null) {
                PendingRequestsSection(controller)
                NewDesignSection(controller)
            } else {
                ActiveRequestSection(controller, active)
            }
        }
    }
    controller.workflowController?.let { design ->
        DesignWorkflowSheet(
            controller = design,
            onClosed = { controller.closeWorkflow() },
        )
    }
}

@Composable
private fun DesignEntryFailureLine(
    failure: CreativeDesignEntryFailure,
    onDismiss: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().padding(top = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloeStatusLine(
            icon = FloeIcons.InfoCircle,
            text = creativeEntryFailureText(failure),
            color = Floe.colors.pending,
            modifier = Modifier.weight(1f),
        )
        FloeCapsuleAction(
            label = stringResource(R.string.design_entry_dismiss),
            onClick = onDismiss,
            modifier = Modifier.padding(start = 8.dp),
        )
    }
}

@Composable
private fun PendingRequestsSection(controller: CreativeDesignEntryController) {
    DesignEntryGroup(title = stringResource(R.string.design_entry_pending_title)) {
        val failure = controller.pendingFailure
        if (failure != null) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeStatusLine(
                    icon = FloeIcons.InfoCircle,
                    text = creativeEntryFailureText(failure),
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.design_entry_retry),
                    onClick = controller::refreshPending,
                )
            }
            return@DesignEntryGroup
        }
        if (controller.pendingLoading && controller.pending.isEmpty()) {
            FloeActivityIndicator(description = stringResource(R.string.design_entry_loading))
            return@DesignEntryGroup
        }
        if (controller.pending.isEmpty()) {
            FloeText(
                stringResource(R.string.design_entry_pending_empty),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            return@DesignEntryGroup
        }
        controller.pending.forEach { request ->
            PendingRequestRow(controller, request)
        }
        if (controller.pendingHasMore) {
            FloeCapsuleAction(
                label = stringResource(R.string.design_entry_show_more),
                onClick = controller::loadMorePending,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}

@Composable
private fun PendingRequestRow(
    controller: CreativeDesignEntryController,
    request: CreativeDesignPendingRequest,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(Floe.colors.fillTertiary)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconGlyph(FloeIcons.Wand, Floe.colors.secondaryLabel, 18.dp)
        Column(Modifier.weight(1f).padding(start = 10.dp)) {
            FloeText(
                creativeKindLabel(request.requestedOutputKind),
                style = Floe.typography.bodyEmphasized,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            FloeText(
                pendingStateLabel(request.state),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                maxLines = 1,
            )
        }
        FloeCapsuleAction(
            label = stringResource(R.string.design_entry_continue),
            onClick = { controller.reopen(request) },
            enabled = !controller.busy,
        )
    }
}

@Composable
private fun NewDesignSection(controller: CreativeDesignEntryController) {
    DesignEntryGroup(title = stringResource(R.string.design_entry_new_title)) {
        FloeText(
            stringResource(R.string.design_entry_kind_hint),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        Row(
            Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState())
                .padding(top = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            CreativeDesignEntryController.AVAILABLE_KINDS.forEach { kind ->
                val selected = controller.selectedKind == kind
                FloeCapsuleAction(
                    label = creativeKindLabel(kind),
                    onClick = { controller.selectKind(kind) },
                    enabled = !controller.busy,
                    tint = if (selected) Floe.colors.accent else Floe.colors.secondaryLabel,
                    showHairline = !selected,
                )
            }
        }
        FloePlainFormField(
            label = stringResource(R.string.design_entry_brief_label),
            value = controller.briefGoal,
            onValueChange = controller::updateBrief,
            modifier = Modifier.padding(top = 10.dp),
            enabled = !controller.busy,
            singleLine = false,
            minLines = 1,
            maxLines = 3,
        )
        FloePrimaryAction(
            label = stringResource(R.string.design_entry_create),
            onClick = controller::createRequest,
            modifier = Modifier.fillMaxWidth().padding(top = 10.dp),
            enabled = !controller.busy,
        )
    }
}

@Composable
private fun ActiveRequestSection(
    controller: CreativeDesignEntryController,
    active: CreativeDesignActive,
) {
    val openDocument = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri != null) controller.importFile(uri, displayName = null)
    }
    DesignEntryGroup(title = creativeKindLabel(active.requestedKind)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            FloeBadgePill(
                text = pendingStateLabel(active.requestState),
                tone = if (active.requestState == CreativeDesignRequestState.FIRST_RESULT_BOUND) {
                    FloeBadgeTone.SUCCESS
                } else {
                    FloeBadgeTone.PENDING
                },
            )
            Box(Modifier.weight(1f))
            FloeCapsuleAction(
                label = stringResource(R.string.design_entry_back),
                onClick = controller::closePanel,
                enabled = !controller.busy,
            )
        }
        if (active.requestState == CreativeDesignRequestState.AWAITING_FIRST_RESULT) {
            MaterialPicker(controller, active, openDocument::launch)
        } else {
            BoundMaterial(controller, active)
        }
    }
}

@Composable
private fun MaterialPicker(
    controller: CreativeDesignEntryController,
    active: CreativeDesignActive,
    launchPicker: (Array<String>) -> Unit,
) {
    FloeDivider(Modifier.padding(vertical = 10.dp))
    FloeText(
        stringResource(R.string.design_entry_materials_title),
        style = Floe.typography.groupHeader,
        color = Floe.colors.secondaryLabel,
    )
    val failure = controller.assetsFailure
    if (failure != null) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            FloeStatusLine(
                icon = FloeIcons.InfoCircle,
                text = creativeEntryFailureText(failure),
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.weight(1f),
            )
            FloeCapsuleAction(
                label = stringResource(R.string.design_entry_retry),
                onClick = controller::refreshAssets,
            )
        }
    } else if (controller.assetsLoading && controller.assets.isEmpty()) {
        FloeActivityIndicator(description = stringResource(R.string.design_entry_loading))
    } else if (controller.assets.isEmpty()) {
        FloeText(
            stringResource(R.string.design_entry_materials_empty),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
    } else {
        controller.assets.forEach { material ->
            MaterialRow(controller, material)
        }
        if (controller.assetsHasMore) {
            FloeCapsuleAction(
                label = stringResource(R.string.design_entry_show_more),
                onClick = controller::loadMoreAssets,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
    active.pendingImport?.let { pending ->
        Row(
            Modifier.fillMaxWidth().padding(top = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FloeText(
                stringResource(R.string.design_entry_import_pending),
                style = Floe.typography.metadata,
                color = Floe.colors.pending,
                modifier = Modifier.weight(1f),
            )
            FloeCapsuleAction(
                label = stringResource(R.string.design_entry_retry_import),
                onClick = controller::retryImport,
                enabled = !controller.busy,
            )
            FloeCapsuleAction(
                label = stringResource(R.string.design_entry_remove_import),
                onClick = controller::discardImport,
                enabled = !controller.busy,
                modifier = Modifier.padding(start = 6.dp),
            )
        }
    }
    FloePrimaryAction(
        label = stringResource(R.string.design_entry_import),
        onClick = { launchPicker(arrayOf("*/*")) },
        modifier = Modifier.fillMaxWidth().padding(top = 10.dp),
        enabled = !controller.busy,
    )
}

@Composable
private fun MaterialRow(
    controller: CreativeDesignEntryController,
    material: CreativeDesignAssetUi,
) {
    val selectable = material.asset.selectable && material.matchesRequestedKind
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .padding(top = 4.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(Floe.colors.fillTertiary)
            .then(
                if (selectable && !controller.busy) {
                    Modifier.clickable { controller.chooseRetained(material) }
                } else {
                    Modifier
                },
            )
            .semantics {
                contentDescription = material.asset.displayName
            }
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconGlyph(
            if (material.matchesRequestedKind) FloeIcons.Photo else FloeIcons.Paperclip,
            if (selectable) Floe.colors.label else Floe.colors.tertiaryLabel,
            18.dp,
        )
        Column(Modifier.weight(1f).padding(start = 10.dp)) {
            FloeText(
                material.asset.displayName.ifBlank {
                    stringResource(R.string.design_entry_untitled_material)
                },
                style = Floe.typography.body,
                color = if (selectable) Floe.colors.label else Floe.colors.secondaryLabel,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            FloeText(
                materialDescription(material),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun BoundMaterial(
    controller: CreativeDesignEntryController,
    active: CreativeDesignActive,
) {
    FloeDivider(Modifier.padding(vertical = 10.dp))
    FloeText(
        stringResource(
            R.string.design_entry_material_added,
            active.boundAssetName?.takeIf { it.isNotBlank() }
                ?: active.boundFormat?.uppercase().orEmpty(),
        ),
        style = Floe.typography.bodyEmphasized,
        maxLines = 2,
        overflow = TextOverflow.Ellipsis,
    )
    FloeText(
        stringResource(R.string.design_entry_material_hint),
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
        modifier = Modifier.padding(top = 4.dp),
    )
    if (controller.lastPublicationPending) {
        FloeStatusLine(
            icon = FloeIcons.InfoCircle,
            text = stringResource(R.string.design_entry_publication_pending),
            color = Floe.colors.pending,
            modifier = Modifier.padding(top = 6.dp),
        )
    }
    val entryTitle = stringResource(R.string.design_entry_title)
    val entryKind = creativeKindLabel(active.requestedKind)
    FloePrimaryAction(
        label = stringResource(R.string.design_entry_open_workflow),
        onClick = {
            controller.openWorkflow(
                title = entryTitle,
                kindLabel = entryKind,
            )
        },
        modifier = Modifier.fillMaxWidth().padding(top = 10.dp),
        enabled = !controller.busy,
    )
}

@Composable
private fun DesignEntryGroup(title: String, content: @Composable () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(top = 14.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(Floe.colors.sectionCardSurface)
            .padding(14.dp),
    ) {
        FloeText(
            title,
            style = Floe.typography.groupHeader,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.padding(bottom = 6.dp),
        )
        content()
    }
}

@Composable
internal fun creativeKindLabel(kind: DesignContentType): String = when (kind) {
    DesignContentType.WEBPAGE -> stringResource(CanvasR.string.design_content_webpage)
    DesignContentType.PROTOTYPE -> stringResource(CanvasR.string.design_content_prototype)
    DesignContentType.PRESENTATION -> stringResource(CanvasR.string.design_content_presentation)
    DesignContentType.IMAGE -> stringResource(CanvasR.string.design_content_image)
    DesignContentType.VIDEO -> stringResource(CanvasR.string.design_content_video)
    DesignContentType.OFFICE_DOCUMENT -> stringResource(CanvasR.string.design_content_office)
    DesignContentType.NOTES -> stringResource(CanvasR.string.design_content_notes)
    DesignContentType.PDF -> stringResource(CanvasR.string.design_content_pdf)
    DesignContentType.CAD -> stringResource(CanvasR.string.design_content_cad)
    DesignContentType.COMPOSITION -> stringResource(CanvasR.string.design_content_composition)
}

@Composable
private fun pendingStateLabel(state: CreativeDesignRequestState): String = when (state) {
    CreativeDesignRequestState.AWAITING_FIRST_RESULT ->
        stringResource(R.string.design_entry_state_awaiting)
    CreativeDesignRequestState.FIRST_RESULT_BOUND ->
        stringResource(R.string.design_entry_state_bound)
}

@Composable
private fun materialDescription(material: CreativeDesignAssetUi): String {
    val format = material.asset.format.uppercase()
    val size = formatBytes(material.asset.byteCount)
    return if (material.matchesRequestedKind) {
        stringResource(R.string.design_entry_material_meta, format, size)
    } else {
        stringResource(R.string.design_entry_material_mismatch, format, size)
    }
}

@Composable
internal fun creativeEntryFailureText(failure: CreativeDesignEntryFailure): String {
    val reason = failure.reason.orEmpty()
    return when {
        failure.code == "creativeMaterialTypeMismatch" || reason == "formatFamilyMismatch" ->
            stringResource(R.string.design_entry_error_mismatch)
        failure.code == "designPayloadTooLarge" || failure.code == "designPreviewTooLarge" ->
            stringResource(R.string.design_entry_error_too_large)
        failure.code == "designConflict" || failure.code == "designTargetMismatch" ->
            stringResource(R.string.design_entry_error_conflict)
        failure.code == "staleSession" || failure.code == "staleGeneration" ||
            reason == "designSessionClosed" ->
            stringResource(R.string.design_entry_error_stale)
        reason == "creativeAssetInventoryRequiresAcceptedDatabase" ->
            stringResource(R.string.design_entry_materials_unavailable)
        failure.code == "notAuthorized" ->
            stringResource(R.string.design_entry_error_not_allowed)
        failure.code == "needsCoreUpdate" ->
            stringResource(R.string.design_entry_error_core)
        failure.code == "runtimeUnavailable" || failure.code == "designUnavailable" ->
            stringResource(R.string.design_entry_error_unavailable)
        failure.code == "designTargetUnavailable" ->
            stringResource(R.string.design_entry_error_target)
        failure.code == "assetEmpty" || failure.code == "designPayloadMissing" ||
            failure.code == "assetStagingUnavailable" ->
            stringResource(R.string.design_entry_error_unreadable)
        else -> stringResource(R.string.design_entry_error_generic)
    }
}

internal fun formatBytes(bytes: Long): String = when {
    bytes <= 0L -> ""
    bytes < 1024L -> "$bytes B"
    bytes < 1024L * 1024L -> "${bytes / 1024L} KB"
    bytes < 1024L * 1024L * 1024L -> String.format("%.1f MB", bytes / (1024.0 * 1024.0))
    else -> String.format("%.1f GB", bytes / (1024.0 * 1024.0 * 1024.0))
}
