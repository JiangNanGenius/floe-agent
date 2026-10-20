// SPDX-License-Identifier: MPL-2.0
//
// Root presentation destination for the Skills/MCP administration flow. The
// host embeds this inside the existing settings detail section (the app does
// not depend on this module yet; the binder stage wires it), supplies an
// immutable [IntegrationsDestinationState] and owns a caller-retained
// [IntegrationsFlowHolder] across configuration changes.
//
// Layout (provisional pending the real iPad Skills/MCP captures — see
// IntegrationsUiCommon): tablet sheets are centered fractions of the window
// with the retained settings context visible behind; compact windows use
// full-width bottom sheets. Navigation is innermost-first: hub → connectors
// → MCP servers → editor, plus the skill sheets above the hub.
//
// Host outcomes are consumed here, fenced by the holder:
//  - install review sync (one pane per reviewId);
//  - MCP save outcome (only the CURRENT editor identity may close);
//  - transient form outcome (only the open form id);
//  - upgrade effect token (only the open sheet's latest dispatch).

package com.floe.android.feature.integrations

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeText
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction

@Composable
fun FloeSkillsSettingsDestination(
    state: IntegrationsDestinationState,
    holder: IntegrationsFlowHolder,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    val windowInfo = LocalWindowInfo.current
    val windowWidthDp = with(density) { windowInfo.containerSize.width.toDp() }
    val wide = windowWidthDp >= FloeLayout.PersistentTwoColumnMinWidth
    val panes = holder.navigation.snapshot()

    // Initial host load once per retained holder (⇄ .task load + catalog).
    LaunchedEffect(Unit) { holder.loadOnce() }

    // A host-staged install review becomes its own sheet exactly once.
    LaunchedEffect(state.installReview) {
        holder.syncInstallReviewPane(state.installReview)
    }

    // Form outcome consumption (creator / finder / folder import).
    LaunchedEffect(state.skills.formOutcome) {
        holder.applyFormOutcome(state.skills.formOutcome)
    }

    // MCP save outcome for the CURRENT editor only. The monotonic host
    // save-failure sequence is part of the key: a retry can fail
    // synchronously inside saveMcpServer, so its begin and failure
    // projections can coalesce into one frame with the SAME text and outcome
    // as the previous attempt. Without the sequence the effect would never
    // re-run and the duplicate-save latch would stay closed forever.
    val editorIdentity = holder.currentMcpEditorIdentity()
    val projectedEditor = state.editor?.takeIf { projected ->
        editorIdentity != null && projected.identity.isCurrentFor(editorIdentity)
    }
    val editorSaveFailureSequence = projectedEditor?.saveFailureSequence ?: 0L
    LaunchedEffect(
        projectedEditor?.identity,
        projectedEditor?.saveOutcome,
        projectedEditor?.saveError,
        editorSaveFailureSequence,
        projectedEditor?.saveInFlight,
    ) {
        val identity = editorIdentity ?: return@LaunchedEffect
        val projected = projectedEditor ?: return@LaunchedEffect
        when (val outcome = projected.saveOutcome) {
            is McpSaveOutcomeUi.Succeeded -> holder.finalizeSavedEditor(identity)
            is McpSaveOutcomeUi.Failed -> if (!projected.saveInFlight) {
                // A failure event belongs to a FINISHED attempt. Wait for the
                // final projection rather than releasing a newer attempt's
                // latch while the host still reports it in flight.
                holder.noteMcpSaveAttemptFinished(identity, projected.saveFailureSequence)
            }
            null -> if (projected.saveError != null && !projected.saveInFlight) {
                holder.noteMcpSaveAttemptFinished(identity, projected.saveFailureSequence)
            }
        }
    }

    // Upgrade effect consumption for the open sheet's latest dispatch.
    LaunchedEffect(state.upgrade?.skillId, state.upgrade?.lastEffect) {
        val projected = state.upgrade ?: return@LaunchedEffect
        holder.applyUpgradeEffect(projected.skillId, projected.lastEffect)
    }

    BackHandler(enabled = holder.navigation.depth > 1) {
        holder.back()
    }

    // Base: the segmented hub inside the settings detail.
    SkillsHubPage(skills = state.skills, holder = holder, modifier = modifier)

    panes.forEach { entry ->
        when (entry.pane) {
            IntegrationsPane.SKILLS_HUB -> Unit

            IntegrationsPane.CONNECTORS -> {
                FloePageSheet(
                    visible = true,
                    onDismiss = { holder.back() },
                    widthFraction = if (wide) 0.66f else 1f,
                    heightFraction = if (wide) 0.82f else 1f,
                    placement = if (wide) FloeSheetPlacement.CENTER else FloeSheetPlacement.BOTTOM,
                ) {
                    ConnectorsPage(
                        connectors = state.connectors,
                        mcpEnabledCount = state.mcp.servers.count { it.enabled },
                        onBack = { holder.back() },
                        onOpenMcp = { holder.openMcpServers() },
                        onOpenDestination = { holder.openConnectorDestination(it) },
                    )
                }
            }

            IntegrationsPane.MCP_SERVERS -> {
                FloePageSheet(
                    visible = true,
                    onDismiss = { holder.back() },
                    widthFraction = if (wide) 0.66f else 1f,
                    heightFraction = if (wide) 0.88f else 1f,
                    placement = if (wide) FloeSheetPlacement.CENTER else FloeSheetPlacement.BOTTOM,
                ) {
                    McpServersPage(
                        mcp = state.mcp,
                        holder = holder,
                        onBack = { holder.back() },
                        onAdd = { holder.openMcpEditor(null) },
                    )
                }
            }

            IntegrationsPane.MCP_EDITOR -> {
                val slot = holder.mcpEditors.slot(entry.key) ?: return@forEach
                FloePageSheet(
                    visible = true,
                    onDismiss = { holder.cancelMcpEditor(slot.identity) },
                    widthFraction = if (wide) IntegrationsSheetMetrics.MCP_EDITOR_WIDTH_FRACTION else 1f,
                    heightFraction = if (wide) IntegrationsSheetMetrics.MCP_EDITOR_HEIGHT_FRACTION else 1f,
                    placement = if (wide) FloeSheetPlacement.CENTER else FloeSheetPlacement.BOTTOM,
                ) {
                    McpServerEditorPage(
                        identity = slot.identity,
                        slot = slot,
                        editor = state.editor,
                        holder = holder,
                        onCancel = { holder.cancelMcpEditor(slot.identity) },
                        onSave = {
                            val projected = state.editor
                                ?.takeIf { it.identity.isCurrentFor(slot.identity) }
                            holder.saveMcpEditor(slot.identity, projected?.saveInFlight == true)
                        },
                    )
                }
            }

            IntegrationsPane.SKILL_CREATOR -> {
                val slot = holder.skillForms.slot(entry.key) ?: return@forEach
                FloePageSheet(
                    visible = true,
                    onDismiss = { holder.closeForm(entry.key) },
                    widthFraction = if (wide) IntegrationsSheetMetrics.SKILL_FORM_WIDTH_FRACTION else 1f,
                    heightFraction = if (wide) IntegrationsSheetMetrics.SKILL_FORM_HEIGHT_FRACTION else 1f,
                    placement = if (wide) FloeSheetPlacement.CENTER else FloeSheetPlacement.BOTTOM,
                ) {
                    SkillCreatorFormPage(
                        slot = slot,
                        skills = state.skills,
                        holder = holder,
                        onClose = { holder.closeForm(entry.key) },
                    )
                }
            }

            IntegrationsPane.SKILL_FINDER -> {
                val slot = holder.skillForms.slot(entry.key) ?: return@forEach
                FloePageSheet(
                    visible = true,
                    onDismiss = { holder.closeForm(entry.key) },
                    widthFraction = if (wide) IntegrationsSheetMetrics.SKILL_FORM_WIDTH_FRACTION else 1f,
                    heightFraction = if (wide) IntegrationsSheetMetrics.SKILL_FORM_HEIGHT_FRACTION else 1f,
                    placement = if (wide) FloeSheetPlacement.CENTER else FloeSheetPlacement.BOTTOM,
                ) {
                    SkillFinderFormPage(
                        slot = slot,
                        skills = state.skills,
                        holder = holder,
                        onClose = { holder.closeForm(entry.key) },
                    )
                }
            }

            IntegrationsPane.SKILL_IMPORT -> {
                val slot = holder.skillForms.slot(entry.key) ?: return@forEach
                FloePageSheet(
                    visible = true,
                    onDismiss = { holder.closeForm(entry.key) },
                    widthFraction = if (wide) IntegrationsSheetMetrics.SKILL_FORM_WIDTH_FRACTION else 1f,
                    heightFraction = if (wide) IntegrationsSheetMetrics.SKILL_FORM_HEIGHT_FRACTION else 1f,
                    placement = if (wide) FloeSheetPlacement.CENTER else FloeSheetPlacement.BOTTOM,
                ) {
                    SkillImportConfirmPage(
                        slot = slot,
                        skills = state.skills,
                        holder = holder,
                        onClose = { holder.closeForm(entry.key) },
                    )
                }
            }

            IntegrationsPane.INSTALL_REVIEW -> {
                val review = state.installReview?.takeIf { it.reviewId.toString() == entry.key }
                    ?: return@forEach
                FloePageSheet(
                    visible = true,
                    onDismiss = { holder.cancelInstallReview(review) },
                    widthFraction = if (wide) IntegrationsSheetMetrics.INSTALL_REVIEW_WIDTH_FRACTION else 1f,
                    heightFraction = if (wide) IntegrationsSheetMetrics.INSTALL_REVIEW_HEIGHT_FRACTION else 1f,
                    placement = if (wide) FloeSheetPlacement.CENTER else FloeSheetPlacement.BOTTOM,
                ) {
                    SkillInstallReviewPage(
                        review = review,
                        holder = holder,
                        onCancel = { holder.cancelInstallReview(review) },
                    )
                }
            }

            IntegrationsPane.UPGRADE_REVIEW -> {
                val skillId = entry.key
                // Seed from the projection, else a pure host read; auto-check
                // once per session (⇄ .onAppear check for official / known
                // sources). Both are host effects; the sheet never invents a
                // candidate version.
                val seed = state.upgrade?.takeIf { it.skillId == skillId }
                    ?: remember(skillId) { holder.seedUpgrade(skillId) }
                LaunchedEffect(skillId, state.upgrade) {
                    holder.autoCheckUpgradeOnOpen(skillId, state.upgrade)
                }
                FloePageSheet(
                    visible = true,
                    onDismiss = {
                        // ⇄ interactiveDismissDisabled(center.isWorking): the
                        // host owns an in-flight commit; dismissal waits.
                        if (!holder.isUpgradeInFlight(seed)) holder.cancelUpgrade(skillId)
                    },
                    widthFraction = if (wide) IntegrationsSheetMetrics.UPGRADE_WIDTH_FRACTION else 1f,
                    heightFraction = if (wide) IntegrationsSheetMetrics.UPGRADE_HEIGHT_FRACTION else 1f,
                    placement = if (wide) FloeSheetPlacement.CENTER else FloeSheetPlacement.BOTTOM,
                ) {
                    if (seed != null) {
                        SkillUpgradePage(
                            upgrade = seed,
                            holder = holder,
                            onClose = { holder.cancelUpgrade(skillId) },
                        )
                    } else {
                        UpgradeUnavailable(
                            onClose = { holder.cancelUpgrade(skillId) },
                        )
                    }
                }
            }
        }
    }
}

/** Honest unavailable upgrade sheet when the host cannot seed it. */
@Composable
private fun UpgradeUnavailable(onClose: () -> Unit) {
    Box(Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(24.dp),
        ) {
            FloeActivityIndicator(description = stringResource(R.string.integration_waiting_host))
            FloeText(
                stringResource(R.string.integration_waiting_host),
                style = Floe.typography.body,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(vertical = 12.dp),
            )
            FloeCapsuleAction(
                label = stringResource(R.string.action_cancel),
                onClick = onClose,
                tint = Floe.colors.label,
            )
        }
    }
}
