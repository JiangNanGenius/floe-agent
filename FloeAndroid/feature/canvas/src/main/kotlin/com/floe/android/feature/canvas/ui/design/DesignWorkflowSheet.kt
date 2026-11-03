// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas.ui.design

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeStatusLine
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph
import com.floe.android.feature.canvas.DesignAdoptMode
import com.floe.android.feature.canvas.DesignCandidateModel
import com.floe.android.feature.canvas.DesignCandidateStatus
import com.floe.android.feature.canvas.DesignComparison
import com.floe.android.feature.canvas.DesignContentType
import com.floe.android.feature.canvas.DesignDeliveryState
import com.floe.android.feature.canvas.DesignPublicationState
import com.floe.android.feature.canvas.DesignTargetKind
import com.floe.android.feature.canvas.DesignWorkMode
import com.floe.android.feature.canvas.ui.CanvasReadOnlyScene
import com.floe.android.feature.canvas.ui.R as CanvasR
import kotlinx.coroutines.launch

/**
 * Feature-owned full-window design workflow sheet.
 *
 * It is presented inside the existing Canvas editor / document destination as
 * one grouped panel on phones and a centered rounded panel on tablets. All
 * state lives in the App-retained [DesignWorkflowController]; this file never
 * writes a project, a file or a Canvas document.
 */
@Composable
fun DesignWorkflowSheet(
    controller: DesignWorkflowController,
    onClosed: () -> Unit,
) {
    var visible by remember(controller) { mutableStateOf(true) }
    val close = {
        if (visible) {
            visible = false
            // mark closed immediately; the App owner awaits real host staging
            // drain/receipt checks and frees preview buffers after closure.
            controller.close()
            onClosed()
        }
    }
    LaunchedEffect(controller) { controller.start() }
    FloeActionSheet(
        visible = visible,
        onDismiss = close,
        maxCardWidth = 760.dp,
        maxCardHeightFraction = 0.92f,
        modifier = Modifier.testTag("design.workflow"),
    ) {
        DesignWorkflowBody(controller = controller, onClose = close)
    }
}

@Composable
private fun DesignWorkflowBody(
    controller: DesignWorkflowController,
    onClose: () -> Unit,
) {
    val pickFile = rememberDesignProposalPicker()
    val scope = rememberCoroutineScope()

    Column(
        Modifier
            .fillMaxWidth()
            .heightIn(max = 780.dp)
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                FloeText(
                    controller.descriptor.title,
                    style = Floe.typography.section,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(top = 4.dp),
                ) {
                    FloeText(
                        controller.descriptor.kindLabel,
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                    controller.state?.let { state ->
                        FloeBadgePill(
                            text = stringResource(
                                CanvasR.string.design_workflow_revision,
                                state.ownerRevision,
                            ),
                            tone = FloeBadgeTone.SECONDARY,
                        )
                    }
                }
            }
            FloeCapsuleAction(
                label = stringResource(CanvasR.string.design_workflow_close),
                onClick = onClose,
                modifier = Modifier.testTag("design.close"),
            )
        }

        Spacer(Modifier.height(10.dp))

        if (controller.loading && controller.state == null) {
            Row(
                Modifier.fillMaxWidth().padding(vertical = 18.dp),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeActivityIndicator()
                Spacer(Modifier.size(10.dp))
                FloeText(
                    stringResource(CanvasR.string.design_workflow_loading),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }

        controller.failure?.let { failure ->
            DesignFailureCard(
                failure = failure,
                onRetry = controller::retry,
                onReload = controller::refresh,
                onDismiss = controller::dismissFailure,
            )
            Spacer(Modifier.height(10.dp))
        }

        controller.notice?.let { notice ->
            DesignNoticeLine(notice = notice, onDismiss = controller::dismissNotice)
            Spacer(Modifier.height(10.dp))
        }

        val state = controller.state
        if (state != null) {
            if (!state.writable) {
                FloeStatusLine(
                    icon = FloeIcons.InfoCircle,
                    text = stringResource(CanvasR.string.design_workflow_read_only),
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(bottom = 10.dp),
                )
            }
            DesignTargetGroup(controller)
            Spacer(Modifier.height(10.dp))
            BriefGroup(controller)
            Spacer(Modifier.height(10.dp))
            SpecGroup(controller)
            Spacer(Modifier.height(10.dp))
            FreezeGroup(controller)
            if (controller.requiresPreservation) {
                Spacer(Modifier.height(10.dp))
                PreservationGroup(controller)
            }
            Spacer(Modifier.height(10.dp))
            ProposalGroup(
                controller = controller,
                onPickFile = {
                    scope.launch {
                        val picked = pickFile()
                        if (picked != null) {
                            controller.stagePicked(picked.first, picked.second)
                        }
                    }
                },
                onStageManual = {
                    controller.stageManualText(
                        controller.manualProposalText,
                        controller.manualProposalFormat,
                    )
                    controller.manualProposalOpen = false
                },
            )
            Spacer(Modifier.height(10.dp))
            CandidatesGroup(controller)
            Spacer(Modifier.height(10.dp))
            RevisionsGroup(controller)
            Spacer(Modifier.height(10.dp))
            PreviewGroup(controller)
            if (controller.canvasRefreshPending) {
                Spacer(Modifier.height(10.dp))
                FloeStatusLine(
                    icon = FloeIcons.WarningTriangle,
                    text = stringResource(CanvasR.string.design_canvas_refresh_pending),
                    color = Floe.colors.pending,
                    modifier = Modifier.fillMaxWidth(),
                )
                Row(
                    Modifier.fillMaxWidth().padding(top = 6.dp),
                    horizontalArrangement = Arrangement.End,
                ) {
                    FloeCapsuleAction(
                        label = stringResource(CanvasR.string.design_canvas_reload),
                        onClick = controller::reloadCanvas,
                    )
                }
            }
        } else if (controller.failure == null && !controller.loading) {
            FloeText(
                stringResource(CanvasR.string.design_workflow_empty),
                style = Floe.typography.body,
                color = Floe.colors.secondaryLabel,
            )
        }

        controller.pendingConfirmation?.let { confirmation ->
            Spacer(Modifier.height(12.dp))
            RestructureConfirmationCard(
                controller = controller,
                confirmation = confirmation,
                busy = controller.busy,
                onConfirm = controller::confirmRestructure,
                onCancel = controller::cancelRestructure,
            )
        }
    }
}

@Composable
private fun DesignTargetGroup(controller: DesignWorkflowController) {
    val target = controller.binding.target
    DesignGroup(title = stringResource(CanvasR.string.design_target_section)) {
        DesignValueRow(
            stringResource(CanvasR.string.design_target_kind),
            designKindLabel(target.kind),
        )
        DesignValueRow(
            stringResource(CanvasR.string.design_target_owner_revision),
            (controller.state?.ownerRevision ?: 0L).toString(),
        )
        DesignValueRow(
            stringResource(CanvasR.string.design_target_content),
            designContentLabel(controller.state?.project?.contentType),
        )
        controller.state?.project?.frozenRun?.let { run ->
            run.workMode?.let {
                DesignValueRow(
                    stringResource(CanvasR.string.design_target_frozen_mode),
                    workModeLabel(it),
                )
            }
            run.desiredFormat?.takeIf { it.isNotBlank() }?.let {
                DesignValueRow(
                    stringResource(CanvasR.string.design_target_frozen_format),
                    it,
                )
            }
        }
    }
}

@Composable
private fun BriefGroup(controller: DesignWorkflowController) {
    val editable = controller.canEditBrief && !controller.busy &&
        controller.pendingConfirmation == null
    DesignGroup(title = stringResource(CanvasR.string.design_brief_section)) {
        FloePlainFormField(
            label = stringResource(CanvasR.string.design_brief_goal),
            value = controller.draft.goal,
            onValueChange = {
                controller.updateDraft(controller.draft.copy(goal = it))
            },
            enabled = editable,
        )
        FloePlainFormField(
            label = stringResource(CanvasR.string.design_brief_audience),
            value = controller.draft.audience,
            onValueChange = {
                controller.updateDraft(controller.draft.copy(audience = it))
            },
            enabled = editable,
        )
        FloePlainFormField(
            label = stringResource(CanvasR.string.design_brief_constraints),
            value = controller.draft.constraintsText,
            onValueChange = {
                controller.updateDraft(controller.draft.copy(constraintsText = it))
            },
            enabled = editable,
            singleLine = false,
            minLines = 2,
            maxLines = 4,
        )
        Row(
            Modifier.fillMaxWidth().padding(top = 6.dp),
            horizontalArrangement = Arrangement.End,
        ) {
            FloeCapsuleAction(
                label = stringResource(CanvasR.string.design_brief_save),
                onClick = controller::saveBrief,
                enabled = editable && controller.draft.goal.isNotBlank(),
            )
        }
    }
}

@Composable
private fun SpecGroup(controller: DesignWorkflowController) {
    val editable = controller.canEditSpec && !controller.busy &&
        controller.pendingConfirmation == null
    DesignGroup(title = stringResource(CanvasR.string.design_spec_section)) {
        FloePlainFormField(
            label = stringResource(CanvasR.string.design_spec_palette),
            value = controller.draft.paletteText,
            onValueChange = {
                controller.updateDraft(controller.draft.copy(paletteText = it))
            },
            enabled = editable,
            singleLine = false,
            minLines = 2,
            maxLines = 4,
        )
        FloePlainFormField(
            label = stringResource(CanvasR.string.design_spec_typography),
            value = controller.draft.typography,
            onValueChange = {
                controller.updateDraft(controller.draft.copy(typography = it))
            },
            enabled = editable,
        )
        FloePlainFormField(
            label = stringResource(CanvasR.string.design_spec_layout),
            value = controller.draft.layout,
            onValueChange = {
                controller.updateDraft(controller.draft.copy(layout = it))
            },
            enabled = editable,
        )
        FloePlainFormField(
            label = stringResource(CanvasR.string.design_spec_spacing),
            value = controller.draft.spacing,
            onValueChange = {
                controller.updateDraft(controller.draft.copy(spacing = it))
            },
            enabled = editable,
        )
        FloePlainFormField(
            label = stringResource(CanvasR.string.design_spec_brand_assets),
            value = controller.draft.brandAssetRefsText,
            onValueChange = {
                controller.updateDraft(controller.draft.copy(brandAssetRefsText = it))
            },
            enabled = editable,
            singleLine = false,
            minLines = 2,
            maxLines = 4,
        )
        FloePlainFormField(
            label = stringResource(CanvasR.string.design_spec_voice),
            value = controller.draft.voice,
            onValueChange = {
                controller.updateDraft(controller.draft.copy(voice = it))
            },
            enabled = editable,
        )
        FloePlainFormField(
            label = stringResource(CanvasR.string.design_spec_prohibitions),
            value = controller.draft.prohibitionsText,
            onValueChange = {
                controller.updateDraft(controller.draft.copy(prohibitionsText = it))
            },
            enabled = editable,
            singleLine = false,
            minLines = 2,
            maxLines = 4,
        )
        FloePlainFormField(
            label = stringResource(CanvasR.string.design_spec_raw_markdown),
            value = controller.draft.rawMarkdown,
            onValueChange = {
                controller.updateDraft(controller.draft.copy(rawMarkdown = it))
            },
            enabled = editable,
            singleLine = false,
            minLines = 5,
            maxLines = 10,
            monospaced = true,
        )
        Row(
            Modifier.fillMaxWidth().padding(top = 6.dp),
            horizontalArrangement = Arrangement.End,
        ) {
            FloeCapsuleAction(
                label = stringResource(CanvasR.string.design_spec_save),
                onClick = controller::saveSpec,
                enabled = editable,
            )
        }
    }
}

@Composable
private fun FreezeGroup(controller: DesignWorkflowController) {
    val editable = !controller.busy && controller.pendingConfirmation == null
    DesignGroup(
        title = stringResource(CanvasR.string.design_freeze_section),
        subtitle = stringResource(CanvasR.string.design_freeze_body),
    ) {
        FloeText(
            stringResource(CanvasR.string.design_work_mode),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        FloeSegmented(
            options = listOf(
                stringResource(CanvasR.string.design_work_create),
                stringResource(CanvasR.string.design_work_modify),
                stringResource(CanvasR.string.design_work_restructure),
            ),
            selectedIndex = when (controller.workMode) {
                DesignWorkMode.CREATE -> 0
                DesignWorkMode.MODIFY -> 1
                DesignWorkMode.RESTRUCTURE -> 2
            },
            onSelect = { index ->
                if (controller.pendingConfirmation == null) {
                    controller.selectWorkMode(
                        when (index) {
                            0 -> DesignWorkMode.CREATE
                            1 -> DesignWorkMode.MODIFY
                            else -> DesignWorkMode.RESTRUCTURE
                        },
                    )
                }
            },
            modifier = Modifier.padding(top = 6.dp),
        )
        FloePlainFormField(
            label = stringResource(CanvasR.string.design_output_format),
            value = controller.desiredFormat,
            onValueChange = controller::updateDesiredFormat,
            enabled = editable,
        )
        FloeText(
            stringResource(CanvasR.string.design_output_format_hint),
            style = Floe.typography.metadata,
            color = Floe.colors.tertiaryLabel,
            modifier = Modifier.padding(top = 2.dp),
        )
        Row(
            Modifier.fillMaxWidth().padding(top = 8.dp),
            horizontalArrangement = Arrangement.End,
        ) {
            FloeCapsuleAction(
                label = stringResource(CanvasR.string.design_freeze_action),
                onClick = controller::freeze,
                enabled = controller.canFreeze && editable,
            )
        }
    }
}

@Composable
private fun PreservationGroup(controller: DesignWorkflowController) {
    val editable = !controller.busy && controller.pendingConfirmation == null
    DesignGroup(
        title = stringResource(CanvasR.string.design_preservation_section),
        subtitle = stringResource(CanvasR.string.design_preservation_body),
    ) {
        PreservationField(
            label = stringResource(CanvasR.string.design_preservation_content),
            value = controller.preservationDraft.content,
            onValueChange = {
                controller.updatePreservationDraft(
                    controller.preservationDraft.copy(content = it))
            },
            enabled = editable,
        )
        PreservationField(
            label = stringResource(CanvasR.string.design_preservation_data),
            value = controller.preservationDraft.data,
            onValueChange = {
                controller.updatePreservationDraft(
                    controller.preservationDraft.copy(data = it))
            },
            enabled = editable,
        )
        PreservationField(
            label = stringResource(CanvasR.string.design_preservation_behavior),
            value = controller.preservationDraft.behavior,
            onValueChange = {
                controller.updatePreservationDraft(
                    controller.preservationDraft.copy(behavior = it))
            },
            enabled = editable,
        )
        PreservationField(
            label = stringResource(CanvasR.string.design_preservation_format),
            value = controller.preservationDraft.formatBounds,
            onValueChange = {
                controller.updatePreservationDraft(
                    controller.preservationDraft.copy(formatBounds = it))
            },
            enabled = editable,
        )
    }
}

@Composable
private fun PreservationField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    enabled: Boolean,
) {
    FloePlainFormField(
        label = label,
        value = value,
        onValueChange = onValueChange,
        enabled = enabled,
        singleLine = false,
        minLines = 2,
        maxLines = 4,
    )
}

@Composable
private fun ProposalGroup(
    controller: DesignWorkflowController,
    onPickFile: () -> Unit,
    onStageManual: () -> Unit,
) {
    val editable = controller.canPropose && !controller.busy &&
        controller.pendingConfirmation == null
    DesignGroup(title = stringResource(CanvasR.string.design_proposal_section)) {
        if (controller.artifacts.isEmpty()) {
            FloeText(
                stringResource(CanvasR.string.design_proposal_need_freeze),
                style = Floe.typography.body,
                color = Floe.colors.secondaryLabel,
            )
            return@DesignGroup
        }
        if (controller.artifacts.size > 1) {
            FloeText(
                stringResource(CanvasR.string.design_proposal_variant),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                controller.artifacts.take(8).forEach { artifact ->
                    FloeCapsuleAction(
                        label = artifact.displayName
                            ?: stringResource(
                                CanvasR.string.design_revision_number,
                                artifact.currentRevision?.number ?: 0,
                            ),
                        onClick = { controller.selectArtifact(artifact.artifactID) },
                        tint = if (controller.selectedArtifactID == artifact.artifactID) {
                            Floe.colors.accent
                        } else {
                            Floe.colors.secondaryLabel
                        },
                        enabled = editable,
                    )
                }
            }
        }
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            FloeCapsuleAction(
                label = stringResource(CanvasR.string.design_proposal_choose_file),
                onClick = onPickFile,
                enabled = editable,
            )
            FloeCapsuleAction(
                label = stringResource(CanvasR.string.design_proposal_write_text),
                onClick = {
                    controller.manualProposalOpen = !controller.manualProposalOpen
                },
                enabled = editable,
            )
        }
        if (controller.manualProposalOpen) {
            FloePlainFormField(
                label = stringResource(CanvasR.string.design_proposal_text),
                value = controller.manualProposalText,
                onValueChange = { controller.manualProposalText = it },
                enabled = editable,
                singleLine = false,
                minLines = 4,
                maxLines = 10,
                monospaced = true,
                modifier = Modifier.padding(top = 6.dp),
            )
            FloeText(
                stringResource(CanvasR.string.design_proposal_text_format),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(top = 6.dp),
            )
            FloeSegmented(
                options = listOf("md", "txt", "html"),
                selectedIndex = when (controller.manualProposalFormat) {
                    "txt" -> 1
                    "html" -> 2
                    else -> 0
                },
                onSelect = {
                    controller.manualProposalFormat =
                        if (it == 1) "txt" else if (it == 2) "html" else "md"
                },
                modifier = Modifier.padding(top = 4.dp),
            )
            Row(
                Modifier.fillMaxWidth().padding(top = 6.dp),
                horizontalArrangement = Arrangement.End,
            ) {
                FloeCapsuleAction(
                    label = stringResource(CanvasR.string.design_proposal_stage),
                    onClick = onStageManual,
                    enabled = editable && controller.manualProposalText.isNotBlank(),
                )
            }
        }
        controller.stagedPayload?.let { payload ->
            Row(
                Modifier.fillMaxWidth().padding(top = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Column(Modifier.weight(1f)) {
                    FloeText(
                        controller.stagedLabel ?: payload.format,
                        style = Floe.typography.bodyEmphasized,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    FloeText(
                        stringResource(
                            CanvasR.string.design_proposal_staged,
                            payload.format,
                            payload.byteCount,
                        ),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                FloeCapsuleAction(
                    label = stringResource(CanvasR.string.design_proposal_discard),
                    onClick = controller::discardStaged,
                    enabled = !controller.busy,
                )
            }
        }
        FloePlainFormField(
            label = stringResource(CanvasR.string.design_proposal_summary),
            value = controller.proposalSummary,
            onValueChange = { controller.proposalSummary = it },
            enabled = editable,
            modifier = Modifier.padding(top = 6.dp),
        )
        FloePlainFormField(
            label = stringResource(CanvasR.string.design_proposal_diff),
            value = controller.proposalDiffText,
            onValueChange = { controller.proposalDiffText = it },
            enabled = editable,
            singleLine = false,
            minLines = 2,
            maxLines = 5,
        )
        Row(
            Modifier.fillMaxWidth().padding(top = 8.dp),
            horizontalArrangement = Arrangement.End,
        ) {
            FloeCapsuleAction(
                label = stringResource(CanvasR.string.design_proposal_action),
                onClick = controller::propose,
                enabled = editable &&
                    controller.stagedPayload != null &&
                    controller.proposalSummary.isNotBlank(),
            )
        }
    }
}

@Composable
private fun CandidatesGroup(controller: DesignWorkflowController) {
    DesignGroup(title = stringResource(CanvasR.string.design_candidates_section)) {
        if (controller.candidates.isEmpty()) {
            FloeText(
                stringResource(CanvasR.string.design_candidates_empty),
                style = Floe.typography.body,
                color = Floe.colors.secondaryLabel,
            )
            return@DesignGroup
        }
        controller.candidates
            .sortedByDescending { it.createdAt }
            .forEach { candidate ->
                CandidateCard(
                    controller = controller,
                    candidate = candidate,
                    selected = controller.selectedCandidateID == candidate.id,
                )
                Spacer(Modifier.height(8.dp))
            }
        controller.comparison?.let { comparison ->
            ComparisonCard(controller, comparison)
        }
        controller.decision?.let { result ->
            DesignGroupInner {
                DesignValueRow(
                    stringResource(CanvasR.string.design_decision_delivery),
                    deliveryLabel(result.delivery.state),
                )
                DesignValueRow(
                    stringResource(CanvasR.string.design_decision_publication),
                    publicationLabel(result.publication.state),
                )
            }
        }
    }
}

@Composable
private fun CandidateCard(
    controller: DesignWorkflowController,
    candidate: DesignCandidateModel,
    selected: Boolean,
) {
    val busy = controller.busy
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Floe.colors.groupedSurface)
            .border(
                1.dp,
                if (selected) Floe.colors.accent else Floe.colors.separator,
                RoundedCornerShape(12.dp),
            )
            .clickable { controller.selectCandidate(candidate.id) }
            .padding(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            FloeText(
                candidate.summary.ifBlank {
                    stringResource(CanvasR.string.design_candidate_untitled)
                },
                style = Floe.typography.bodyEmphasized,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            FloeBadgePill(
                text = candidateStatusLabel(candidate.status),
                tone = candidateStatusTone(candidate.status),
            )
        }
        FloeText(
            stringResource(
                CanvasR.string.design_candidate_revisions,
                revisionLabel(controller, candidate.baseRevisionID),
                revisionLabel(controller, candidate.proposedRevisionID),
            ),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.padding(top = 2.dp),
        )
        if (candidate.diff.isNotEmpty()) {
            FloeText(
                candidate.diff.take(8).joinToString("\n"),
                style = Floe.typography.evidence,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
        if (candidate.feedbackIDs.isNotEmpty()) {
            DesignValueRow(
                stringResource(CanvasR.string.design_candidate_feedback),
                candidate.feedbackIDs.size.toString(),
            )
        }
        Row(
            Modifier.fillMaxWidth().padding(top = 6.dp).horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            FloeCapsuleAction(
                label = stringResource(CanvasR.string.design_candidate_preview),
                onClick = { controller.preview(candidateID = candidate.id) },
                enabled = !busy,
            )
            FloeCapsuleAction(
                label = stringResource(CanvasR.string.design_candidate_compare),
                onClick = {
                    controller.selectCandidate(candidate.id)
                    controller.compare()
                },
                enabled = !busy && controller.canCompare,
            )
        }
        if (candidate.status == DesignCandidateStatus.PENDING && controller.canAdopt) {
            Row(
                Modifier.fillMaxWidth().padding(top = 6.dp).horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                FloeCapsuleAction(
                    label = stringResource(CanvasR.string.design_candidate_adopt_original),
                    onClick = {
                        controller.selectCandidate(candidate.id)
                        controller.adopt(DesignAdoptMode.UPDATE_ORIGINAL)
                    },
                    enabled = !busy,
                )
                FloeCapsuleAction(
                    label = stringResource(CanvasR.string.design_candidate_adopt_variant),
                    onClick = {
                        controller.selectCandidate(candidate.id)
                        controller.adopt(DesignAdoptMode.VARIANT)
                    },
                    enabled = !busy,
                )
                FloeCapsuleAction(
                    label = stringResource(CanvasR.string.design_candidate_reject),
                    onClick = {
                        controller.selectCandidate(candidate.id)
                        controller.reject()
                    },
                    enabled = !busy && controller.canReject,
                )
            }
        }
    }
}

@Composable
private fun ComparisonCard(
    controller: DesignWorkflowController,
    comparison: DesignComparison,
) {
    var details by remember(comparison) { mutableStateOf(false) }
    DesignGroupInner {
        FloeText(
            stringResource(CanvasR.string.design_compare_section),
            style = Floe.typography.groupHeader,
            color = Floe.colors.secondaryLabel,
        )
        DesignValueRow(
            stringResource(CanvasR.string.design_compare_changed),
            if (comparison.changed) {
                stringResource(CanvasR.string.design_compare_yes)
            } else {
                stringResource(CanvasR.string.design_compare_no)
            },
        )
        DesignValueRow(
            stringResource(CanvasR.string.design_compare_latest),
            controller.selectedArtifact?.currentRevision?.number?.let {
                stringResource(CanvasR.string.design_revision_number, it)
            } ?: stringResource(CanvasR.string.design_revision_unknown),
        )
        if (comparison.diff.isNotEmpty()) {
            FloeText(
                comparison.diff.take(12).joinToString("\n"),
                style = Floe.typography.evidence,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
        if (comparison.diffTruncated) {
            FloeText(
                stringResource(CanvasR.string.design_compare_truncated),
                style = Floe.typography.metadata,
                color = Floe.colors.pending,
            )
        }
        FloeCapsuleAction(
            label = stringResource(CanvasR.string.design_workflow_details),
            onClick = { details = !details },
            modifier = Modifier.padding(top = 6.dp),
        )
        if (details) {
            DesignValueRow(
                stringResource(CanvasR.string.design_compare_base),
                comparison.baseSHA256,
            )
            DesignValueRow(
                stringResource(CanvasR.string.design_compare_proposed),
                comparison.proposedSHA256,
            )
        }
    }
}

@Composable
private fun revisionLabel(controller: DesignWorkflowController, revisionID: String): String {
    val info = controller.revisions.firstOrNull { it.revisionID == revisionID }
    return if (info != null) {
        stringResource(CanvasR.string.design_revision_number, info.number)
    } else {
        stringResource(CanvasR.string.design_revision_unknown)
    }
}

@Composable
private fun RevisionsGroup(controller: DesignWorkflowController) {
    if (controller.revisions.isEmpty()) return
    DesignGroup(title = stringResource(CanvasR.string.design_revisions_section)) {
        controller.revisions
            .sortedByDescending { it.number }
            .forEach { revision ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(min = 44.dp)
                        .padding(vertical = 4.dp)
                        .horizontalScroll(rememberScrollState()),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Column(Modifier.weight(1f)) {
                        FloeText(
                            stringResource(
                                CanvasR.string.design_revision_row,
                                revision.number,
                                revision.format ?: "bin",
                            ),
                            style = Floe.typography.body,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        if (revision.isCurrent) {
                            FloeBadgePill(
                                text = stringResource(CanvasR.string.design_revision_current),
                                tone = FloeBadgeTone.SUCCESS,
                            )
                        }
                    }
                    FloeCapsuleAction(
                        label = stringResource(CanvasR.string.design_revision_preview),
                        onClick = {
                            controller.preview(revisionID = revision.revisionID)
                        },
                        enabled = !controller.busy,
                    )
                    FloeCapsuleAction(
                        label = stringResource(CanvasR.string.design_revision_export),
                        onClick = {
                            controller.exportCurrent(revisionID = revision.revisionID)
                        },
                        enabled = !controller.busy,
                    )
                    if (controller.canRestore && !revision.isCurrent) {
                        FloeCapsuleAction(
                            label = stringResource(CanvasR.string.design_revision_restore),
                            onClick = { controller.restore(revision.revisionID) },
                            enabled = !controller.busy,
                        )
                    }
                }
            }
    }
}

@Composable
private fun PreviewGroup(controller: DesignWorkflowController) {
    DesignGroup(title = stringResource(CanvasR.string.design_preview_section)) {
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            FloeCapsuleAction(
                label = stringResource(CanvasR.string.design_preview_current),
                onClick = { controller.preview() },
                enabled = !controller.busy,
            )
            controller.previewReceipt?.let { receipt ->
                FloeCapsuleAction(
                    label = stringResource(CanvasR.string.design_preview_close),
                    onClick = controller::closePreview,
                )
                FloeCapsuleAction(
                    label = stringResource(
                        CanvasR.string.design_export_action,
                        receipt.format,
                    ),
                    onClick = {
                        controller.exportCurrent(
                            candidateID = controller.previewCandidateID,
                            revisionID = controller.previewRevisionID,
                        )
                    },
                    enabled = !controller.busy,
                )
            }
        }
        controller.previewContent?.let { content ->
            PreviewBody(content)
        } ?: FloeText(
            stringResource(CanvasR.string.design_preview_none),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.padding(top = 6.dp),
        )
        controller.exportResult?.let { result ->
            val text = when (result) {
                is DesignExportDeliveryResult.Delivered -> stringResource(
                    CanvasR.string.design_export_delivered,
                    result.byteCount,
                )
                DesignExportDeliveryResult.Cancelled ->
                    stringResource(CanvasR.string.design_export_cancelled)
                is DesignExportDeliveryResult.Refused -> stringResource(
                    CanvasR.string.design_export_refused,
                    exportRefusalLabel(result.code),
                )
            }
            FloeStatusLine(
                icon = if (result is DesignExportDeliveryResult.Delivered) {
                    FloeIcons.CheckCircle
                } else {
                    FloeIcons.InfoCircle
                },
                text = text,
                color = if (result is DesignExportDeliveryResult.Delivered) {
                    Floe.colors.success
                } else {
                    Floe.colors.secondaryLabel
                },
                modifier = Modifier.padding(top = 6.dp),
            )
        }
    }
}

@Composable
private fun PreviewBody(content: DesignPreviewContent) {
    when (content) {
        is DesignPreviewContent.Image -> {
            Image(
                bitmap = content.bitmap.asImageBitmap(),
                contentDescription = stringResource(CanvasR.string.design_preview_image),
                contentScale = ContentScale.Fit,
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 340.dp)
                    .padding(top = 8.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(Floe.colors.readingSurface),
            )
        }
        is DesignPreviewContent.Text -> {
            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(top = 8.dp)
                    .heightIn(max = 320.dp)
                    .verticalScroll(rememberScrollState())
                    .clip(RoundedCornerShape(10.dp))
                    .background(Floe.colors.readingSurface)
                    .padding(10.dp),
            ) {
                FloeText(content.text, style = Floe.typography.evidence)
                if (content.truncated) {
                    FloeText(
                        stringResource(CanvasR.string.design_preview_text_truncated),
                        style = Floe.typography.metadata,
                        color = Floe.colors.pending,
                        modifier = Modifier.padding(top = 6.dp),
                    )
                }
            }
        }
        is DesignPreviewContent.PdfPages -> {
            Column(Modifier.padding(top = 8.dp)) {
                FloeText(
                    stringResource(
                        CanvasR.string.design_preview_pdf_pages,
                        content.pageCount,
                        content.pages.size,
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(bottom = 6.dp),
                )
                content.pages.forEachIndexed { index, page ->
                    Image(
                        bitmap = page.asImageBitmap(),
                        contentDescription = stringResource(
                            CanvasR.string.design_preview_pdf_page, index + 1),
                        contentScale = ContentScale.Fit,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 320.dp)
                            .padding(bottom = 6.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .background(Floe.colors.readingSurface),
                    )
                }
            }
        }
        is DesignPreviewContent.CanvasSnapshot -> {
            var details by remember(content) { mutableStateOf(false) }
            val project = content.project
            val document = project?.let { value ->
                value.documents.firstOrNull { it.id == content.documentID }
            }
            if (project != null && document != null) {
                // The ACTUAL captured Canvas document, rendered through the
                // existing read-only Canvas geometry/node components. Images
                // appear only when the App verified their bytes/digest against
                // the captured native Canvas owner; otherwise the existing
                // honest "image unavailable" placeholder stays.
                CanvasReadOnlyScene(
                    project = project,
                    documentID = document.id,
                    selectedNodeID = content.nodeID,
                    assetBitmaps = content.assetBitmaps,
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 320.dp)
                        .padding(top = 8.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(Floe.colors.readingSurface),
                )
                if (content.assetsTruncated) {
                    FloeText(
                        stringResource(CanvasR.string.design_preview_canvas_assets_truncated),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        modifier = Modifier.padding(top = 6.dp),
                    )
                }
                val unverifiedImages = content.assets.count {
                    it.kind.equals("image", ignoreCase = true) && !it.verified
                }
                val missingImageBitmaps = document.nodes.any { node ->
                    node.kind.equals("image", ignoreCase = true) &&
                        node.asset?.id?.let { content.assetBitmaps[it] } == null
                }
                if (unverifiedImages > 0 || missingImageBitmaps) {
                    FloeText(
                        stringResource(CanvasR.string.design_preview_canvas_assets_unverified),
                        style = Floe.typography.metadata,
                        color = Floe.colors.pending,
                        modifier = Modifier.padding(top = 6.dp),
                    )
                }
            } else {
                FloeStatusLine(
                    icon = FloeIcons.InfoCircle,
                    text = stringResource(CanvasR.string.design_preview_canvas_unavailable),
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
            DesignGroupInner {
                FloeText(
                    stringResource(CanvasR.string.design_preview_canvas_snapshot),
                    style = Floe.typography.groupHeader,
                    color = Floe.colors.secondaryLabel,
                )
                DesignValueRow(
                    stringResource(CanvasR.string.design_preview_canvas_revision),
                    content.canvasRevision.toString(),
                )
                DesignValueRow(
                    stringResource(CanvasR.string.design_preview_canvas_kind),
                    designContentLabel(content.contentType),
                )
                FloeCapsuleAction(
                    label = stringResource(CanvasR.string.design_workflow_details),
                    onClick = { details = !details },
                    modifier = Modifier.padding(top = 4.dp),
                )
                if (details) {
                    DesignValueRow(
                        stringResource(CanvasR.string.design_preview_canvas_id),
                        content.canvasID,
                    )
                    DesignValueRow(
                        stringResource(CanvasR.string.design_preview_canvas_node),
                        content.nodeID,
                    )
                }
                content.briefGoal?.takeIf { it.isNotBlank() }?.let {
                    DesignValueRow(stringResource(CanvasR.string.design_brief_goal), it)
                }
                content.specRawMarkdown?.takeIf { it.isNotBlank() }?.let {
                    FloeText(
                        it.take(4000),
                        style = Floe.typography.evidence,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 220.dp)
                            .verticalScroll(rememberScrollState())
                            .padding(top = 4.dp),
                    )
                }
                DesignValueRow(
                    stringResource(CanvasR.string.design_candidates_section),
                    content.candidateCount.toString(),
                )
            }
        }
        is DesignPreviewContent.Unavailable -> {
            FloeStatusLine(
                icon = FloeIcons.InfoCircle,
                text = stringResource(
                    CanvasR.string.design_preview_unsupported, content.format),
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(top = 8.dp),
            )
        }
    }
}

@Composable
private fun RestructureConfirmationCard(
    controller: DesignWorkflowController,
    confirmation: DesignRestructureConfirmation,
    busy: Boolean,
    onConfirm: () -> Unit,
    onCancel: () -> Unit,
) {
    var details by remember(confirmation) { mutableStateOf(false) }
    val baseNumber = controller.revisions
        .firstOrNull { it.revisionID == confirmation.baseRevisionID }
        ?.number
    val operationLabel = when (controller.pendingConfirmationOperation) {
        DesignTrustedOperation.FREEZE -> stringResource(CanvasR.string.design_work_restructure)
        DesignTrustedOperation.PROPOSE -> stringResource(CanvasR.string.design_proposal_action)
        DesignTrustedOperation.ADOPT -> stringResource(CanvasR.string.design_candidate_adopt_original)
        null -> stringResource(CanvasR.string.design_work_restructure)
    }
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Floe.colors.groupedSurface)
            .border(1.dp, Floe.colors.pending, RoundedCornerShape(14.dp))
            .padding(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconGlyph(FloeIcons.ShieldCheck, Floe.colors.pending, 18.dp)
            Spacer(Modifier.size(8.dp))
            FloeText(
                stringResource(CanvasR.string.design_restructure_confirm_title),
                style = Floe.typography.bodyEmphasized,
            )
        }
        FloeText(
            stringResource(CanvasR.string.design_restructure_review),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.padding(top = 4.dp),
        )
        // Product copy shows the human target and the user's own preservation
        // words. Opaque binding/receipt identifiers stay in Details only; the
        // UI still compares the exact typed values internally.
        DesignValueRow(
            stringResource(CanvasR.string.design_restructure_target),
            controller.descriptor.title,
        )
        DesignValueRow(
            stringResource(CanvasR.string.design_restructure_operation),
            operationLabel,
        )
        baseNumber?.let {
            DesignValueRow(
                stringResource(CanvasR.string.design_restructure_base),
                stringResource(CanvasR.string.design_revision_number, it),
            )
        }
        PreservationSummary(confirmation.preservation)
        Row(
            Modifier.fillMaxWidth().padding(top = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FloeCapsuleAction(
                label = stringResource(CanvasR.string.design_workflow_details),
                onClick = { details = !details },
            )
            Spacer(Modifier.weight(1f))
        }
        if (details) {
            DesignValueRow(
                stringResource(CanvasR.string.design_restructure_binding),
                confirmation.targetKey,
            )
            DesignValueRow(
                stringResource(CanvasR.string.design_restructure_confirmation_id),
                confirmation.operationID,
            )
            confirmation.originalTaskOwnerID?.let {
                DesignValueRow(
                    stringResource(CanvasR.string.design_restructure_original_task), it)
            }
            confirmation.baseRevisionID?.let {
                DesignValueRow(stringResource(CanvasR.string.design_restructure_base_id), it)
            }
            DesignValueRow(
                stringResource(CanvasR.string.design_restructure_digest),
                confirmation.preservationDigest,
            )
            if (confirmation.expiresAt.isNotBlank()) {
                DesignValueRow(
                    stringResource(CanvasR.string.design_restructure_expires),
                    confirmation.expiresAt,
                )
            }
        }
        Row(
            Modifier.fillMaxWidth().padding(top = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            FloeCapsuleAction(
                label = stringResource(CanvasR.string.design_restructure_cancel),
                onClick = onCancel,
                enabled = !busy,
            )
            Spacer(Modifier.weight(1f))
            FloeCapsuleAction(
                label = stringResource(CanvasR.string.design_restructure_confirm_action),
                onClick = onConfirm,
                enabled = !busy,
                modifier = Modifier.testTag("design.restructure.confirm"),
            )
        }
    }
}

@Composable
private fun PreservationSummary(constraints: DesignPreservationConstraints) {
    PreservationSummaryLine(
        stringResource(CanvasR.string.design_preservation_content), constraints.content)
    PreservationSummaryLine(
        stringResource(CanvasR.string.design_preservation_data), constraints.data)
    PreservationSummaryLine(
        stringResource(CanvasR.string.design_preservation_behavior), constraints.behavior)
    PreservationSummaryLine(
        stringResource(CanvasR.string.design_preservation_format), constraints.formatBounds)
}

@Composable
private fun PreservationSummaryLine(label: String, values: List<String>) {
    if (values.isEmpty()) return
    DesignValueRow(label, values.joinToString(" · "))
}

@Composable
private fun DesignFailureCard(
    failure: DesignFailure,
    onRetry: () -> Unit,
    onReload: () -> Unit,
    onDismiss: () -> Unit,
) {
    var detailsOpen by remember(failure) { mutableStateOf(false) }
    val reload = failure.code in setOf(
        "designConflict", "outcomeUnknown", "staleGeneration", "staleSession",
    )
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Floe.colors.groupedSurface)
            .border(1.dp, Floe.colors.destructive, RoundedCornerShape(12.dp))
            .padding(12.dp),
    ) {
        FloeStatusLine(
            icon = FloeIcons.WarningTriangle,
            text = failureTitle(failure),
            color = Floe.colors.destructive,
            style = Floe.typography.bodyEmphasized,
        )
        FloeText(
            failureBody(failure),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.padding(top = 4.dp),
        )
        Row(
            Modifier.fillMaxWidth().padding(top = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            FloeCapsuleAction(
                label = stringResource(CanvasR.string.design_workflow_dismiss),
                onClick = onDismiss,
            )
            if (reload) {
                FloeCapsuleAction(
                    label = stringResource(CanvasR.string.design_workflow_reload),
                    onClick = onReload,
                )
            } else if (failure.retryable) {
                FloeCapsuleAction(
                    label = stringResource(CanvasR.string.design_workflow_retry),
                    onClick = onRetry,
                )
            }
            Spacer(Modifier.weight(1f))
            FloeCapsuleAction(
                label = stringResource(CanvasR.string.design_workflow_details),
                onClick = { detailsOpen = !detailsOpen },
            )
        }
        if (detailsOpen) {
            FloeText(
                buildString {
                    append(failure.code)
                    failure.detail?.takeIf { it.isNotBlank() }?.let {
                        append(" · ")
                        append(it)
                    }
                    append(" · ")
                    append(failure.operation.name.lowercase())
                },
                style = Floe.typography.evidence,
                color = Floe.colors.tertiaryLabel,
                modifier = Modifier.padding(top = 8.dp),
            )
        }
    }
}

@Composable
private fun DesignNoticeLine(notice: DesignNotice, onDismiss: () -> Unit) {
    val text = when (notice) {
        DesignNotice.SAVED -> stringResource(CanvasR.string.design_notice_saved)
        DesignNotice.FROZEN -> stringResource(CanvasR.string.design_notice_frozen)
        DesignNotice.PROPOSED -> stringResource(CanvasR.string.design_notice_proposed)
        DesignNotice.ADOPTED -> stringResource(CanvasR.string.design_notice_adopted)
        DesignNotice.REJECTED -> stringResource(CanvasR.string.design_notice_rejected)
        DesignNotice.RESTORED -> stringResource(CanvasR.string.design_notice_restored)
        DesignNotice.EXPORTED -> stringResource(CanvasR.string.design_notice_exported)
        DesignNotice.CANVAS_REFRESH_PENDING ->
            stringResource(CanvasR.string.design_canvas_refresh_pending)
    }
    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        FloeStatusLine(
            icon = FloeIcons.CheckCircle,
            text = text,
            color = Floe.colors.success,
            modifier = Modifier.weight(1f),
        )
        FloeCapsuleAction(
            label = stringResource(CanvasR.string.design_workflow_dismiss),
            onClick = onDismiss,
        )
    }
}

@Composable
private fun DesignGroup(
    title: String,
    subtitle: String? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Floe.colors.sectionCardSurface)
            .border(0.5.dp, Floe.colors.separator, RoundedCornerShape(14.dp))
            .padding(14.dp),
    ) {
        FloeText(title, style = Floe.typography.section)
        if (subtitle != null) {
            FloeText(
                subtitle,
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
        Spacer(Modifier.height(6.dp))
        content()
    }
}

@Composable
private fun DesignGroupInner(content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(top = 8.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(Floe.colors.readingSurface)
            .padding(10.dp),
        content = content,
    )
}

@Composable
private fun DesignValueRow(label: String, value: String) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 32.dp)
            .padding(vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        FloeText(
            label,
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.weight(1f),
        )
        FloeText(
            value,
            style = Floe.typography.metadata,
            color = Floe.colors.label,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1.2f),
        )
    }
}

// MARK: - Labels

@Composable
private fun designKindLabel(kind: DesignTargetKind): String = when (kind) {
    DesignTargetKind.CANVAS_NODE -> stringResource(CanvasR.string.design_kind_canvas)
    DesignTargetKind.FILE_DOCUMENT -> stringResource(CanvasR.string.design_kind_file)
    DesignTargetKind.CHAT_ATTACHMENT -> stringResource(CanvasR.string.design_kind_chat)
    DesignTargetKind.CREATIVE_DOCUMENT -> stringResource(CanvasR.string.design_kind_creative)
}

@Composable
private fun designContentLabel(contentType: DesignContentType?): String = when (contentType) {
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
    null -> stringResource(CanvasR.string.design_content_unknown)
}

@Composable
private fun workModeLabel(mode: DesignWorkMode): String = when (mode) {
    DesignWorkMode.CREATE -> stringResource(CanvasR.string.design_work_create)
    DesignWorkMode.MODIFY -> stringResource(CanvasR.string.design_work_modify)
    DesignWorkMode.RESTRUCTURE -> stringResource(CanvasR.string.design_work_restructure)
}

@Composable
private fun candidateStatusLabel(status: DesignCandidateStatus): String = when (status) {
    DesignCandidateStatus.PENDING -> stringResource(CanvasR.string.design_candidate_status_pending)
    DesignCandidateStatus.ADOPTED -> stringResource(CanvasR.string.design_candidate_status_adopted)
    DesignCandidateStatus.REJECTED -> stringResource(CanvasR.string.design_candidate_status_rejected)
    DesignCandidateStatus.SUPERSEDED -> stringResource(CanvasR.string.design_candidate_status_superseded)
}

private fun candidateStatusTone(status: DesignCandidateStatus): FloeBadgeTone = when (status) {
    DesignCandidateStatus.PENDING -> FloeBadgeTone.PENDING
    DesignCandidateStatus.ADOPTED -> FloeBadgeTone.SUCCESS
    DesignCandidateStatus.REJECTED -> FloeBadgeTone.DESTRUCTIVE
    DesignCandidateStatus.SUPERSEDED -> FloeBadgeTone.SECONDARY
}

@Composable
private fun deliveryLabel(state: DesignDeliveryState): String = when (state) {
    DesignDeliveryState.NOT_REQUIRED -> stringResource(CanvasR.string.design_delivery_not_required)
    DesignDeliveryState.DELIVERED -> stringResource(CanvasR.string.design_delivery_delivered)
    DesignDeliveryState.PENDING -> stringResource(CanvasR.string.design_delivery_pending)
}

@Composable
private fun publicationLabel(state: DesignPublicationState): String = when (state) {
    DesignPublicationState.NOT_REQUIRED ->
        stringResource(CanvasR.string.design_publication_not_required)
    DesignPublicationState.PUBLISHED ->
        stringResource(CanvasR.string.design_publication_published)
    DesignPublicationState.PENDING ->
        stringResource(CanvasR.string.design_publication_pending)
}

@Composable
private fun exportRefusalLabel(code: String): String = when (code) {
    "designVerifyMismatch", "designVerifyUnavailable", "designOutputChanged",
    "designReceiptChanged", "designLengthMismatch" ->
        stringResource(CanvasR.string.design_export_refused_verify)
    "staleGeneration", "staleSession", "designOwnerUnverified" ->
        stringResource(CanvasR.string.design_export_refused_session)
    "designPickCancelled" -> stringResource(CanvasR.string.design_export_cancelled)
    else -> stringResource(CanvasR.string.design_export_refused_generic)
}

@Composable
private fun failureTitle(failure: DesignFailure): String = when (failure.code) {
    "designConflict" -> stringResource(CanvasR.string.design_error_conflict_title)
    "outcomeUnknown" -> stringResource(CanvasR.string.design_error_unknown_title)
    "designPublicationPending" -> stringResource(CanvasR.string.design_error_pending_title)
    "designTargetUnavailable" -> stringResource(CanvasR.string.design_error_target_title)
    "designAuthorityUnavailable" -> stringResource(CanvasR.string.design_error_authority_title)
    "designAuthorityExpired" -> stringResource(CanvasR.string.design_error_expired_title)
    "designAuthorityMismatch" -> stringResource(CanvasR.string.design_error_mismatch_title)
    "designPreviewTooLarge", "designPayloadTooLarge" ->
        stringResource(CanvasR.string.design_error_too_large_title)
    else -> stringResource(CanvasR.string.design_error_title)
}

@Composable
private fun failureBody(failure: DesignFailure): String {
    val code = failure.detail ?: failure.code
    return when (code) {
        "designNotBound", "designUnavailable", "targetKindUnavailable" ->
            stringResource(CanvasR.string.design_error_unavailable_body)
        "designConflict" -> stringResource(CanvasR.string.design_error_conflict_body)
        "outcomeUnknown" -> stringResource(CanvasR.string.design_error_unknown_body)
        "designPublicationPending", "designDeliveryPending" ->
            stringResource(CanvasR.string.design_error_pending_body)
        "designTargetUnavailable", "cadDesignReadOnly", "invalidCanvasIdentity" ->
            stringResource(CanvasR.string.design_error_target_body)
        "staleGeneration", "staleSession", "designSessionClosed",
        "designOwnerUnverified", "designReceiptChanged" ->
            stringResource(CanvasR.string.design_error_session_body)
        "designPickCancelled" -> stringResource(CanvasR.string.design_export_cancelled)
        "designAuthorityUnavailable", "ownerProofUnavailable", "confirmationUnavailable" ->
            stringResource(CanvasR.string.design_error_authority_body)
        "designAuthorityExpired", "confirmationExpiredOrMissing" ->
            stringResource(CanvasR.string.design_error_expired_body)
        "designAuthorityMismatch", "confirmationDoesNotMatchTarget" ->
            stringResource(CanvasR.string.design_error_mismatch_body)
        "designAuthorityPending", "confirmationPending" ->
            stringResource(CanvasR.string.design_error_confirmation_pending_body)
        "preservationConstraintsRequired", "designAuthorityInvalid" ->
            stringResource(CanvasR.string.design_error_preservation_body)
        "designPayloadMissing", "noCurrentRevision", "artifactNotFound", "noDesignState" ->
            stringResource(CanvasR.string.design_error_payload_body)
        "proposalSourceRequired" -> stringResource(CanvasR.string.design_error_source_body)
        "freezeRequired" -> stringResource(CanvasR.string.design_error_freeze_body)
        "designPreviewTooLarge" -> stringResource(CanvasR.string.design_error_preview_size_body)
        "designPayloadTooLarge" -> stringResource(CanvasR.string.design_error_payload_size_body)
        "renderUnsupported", "unsupportedFormat", "requestedFormatDiffersFromSource",
        "exportFormatUnavailable" -> stringResource(CanvasR.string.design_error_format_body)
        "canvasRefreshFailed" -> stringResource(CanvasR.string.design_canvas_refresh_pending)
        else -> stringResource(CanvasR.string.design_error_generic_body)
    }
}

// MARK: - Proposal file picker

@Composable
private fun rememberDesignProposalPicker(): suspend () -> Pair<android.net.Uri, String?>? {
    val context = androidx.compose.ui.platform.LocalContext.current
    var pending by remember {
        mutableStateOf<kotlinx.coroutines.CompletableDeferred<Pair<android.net.Uri, String?>?>?>(null)
    }
    val launcher = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.OpenDocument(),
    ) { uri ->
        val target = pending
        pending = null
        if (uri == null) {
            target?.complete(null)
        } else {
            val name = runCatching {
                context.contentResolver.query(
                    uri,
                    arrayOf(android.provider.OpenableColumns.DISPLAY_NAME),
                    null,
                    null,
                    null,
                )?.use { cursor ->
                    val index = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                    if (index >= 0 && cursor.moveToFirst()) cursor.getString(index) else null
                }
            }.getOrNull()
            target?.complete(uri to name)
        }
    }
    return remember(launcher) {
        suspend {
            val deferred =
                kotlinx.coroutines.CompletableDeferred<Pair<android.net.Uri, String?>?>()
            pending = deferred
            // The native host is the format authority; the picker only asks
            // the user for one real source document.
            launcher.launch(arrayOf("*/*"))
            try {
                deferred.await()
            } finally {
                if (pending === deferred) pending = null
            }
        }
    }
}
