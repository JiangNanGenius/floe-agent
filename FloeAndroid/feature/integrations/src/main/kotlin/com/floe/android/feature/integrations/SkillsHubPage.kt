// SPDX-License-Identifier: MPL-2.0
//
// Skills hub (⇄ FloeApp/Skills/SkillsView.swift), section-for-section in the
// iPad order: segmented Discover/Installed → official plugin cards → import
// actions → scripted-update toggle → connectors → installed rows → host
// error lines. Every label and affordance comes from the host projection;
// nothing here derives availability (see SkillsDisplayLogic) and no success,
// tool count or progress is ever rendered on the module's own authority.
//
// Row-action mapping (⇄ the original's controls):
//  - catalog card: Install / Enable / "Update to vX" / "Ready to use" label
//    ⇄ center.installOfficialSkill / setEnabled / updatingSkill / status;
//  - installed row: enable switch ⇄ Toggle("skills.enabled"); update ⇄
//    Button arrow.down.circle; delete ⇄ swipeActions destructive (long-press
//    confirm on Android, the same narrow destructive intent via dialog);
//  - running row: stop ⇄ SKL-CANCEL (only when the host projects a run);
//  - Discover import actions: "plugins.import" ⇄ SkillsView.swift:84 → the
//    Skill FINDER URL sheet; "skills.import_folder" ⇄ SkillsView.swift:85 →
//    the FOLDER PICKER (host SAF presentation); "skills.creator" ⇄ :86 →
//    the creator. The holder routes all three, and a dedicated holder test
//    pins the finder/folder distinction so the two cannot silently collapse.

package com.floe.android.feature.integrations

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeActionRow
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeInlineSwitch
import com.floe.android.design.FloeSearchField
import com.floe.android.design.FloeSectionRow
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeStatusLine
import com.floe.android.design.FloeSwitchRow
import com.floe.android.design.FloeText
import com.floe.android.design.FloeUnavailableView
import com.floe.android.design.IconGlyph
import io.github.robinpcrd.cupertino.section.SectionScope

@Composable
fun SkillsHubPage(
    skills: SkillsHubUiState,
    holder: IntegrationsFlowHolder,
    modifier: Modifier = Modifier,
) {
    var deleteCandidate by remember { mutableStateOf<SkillInstalledRowUi?>(null) }
    val query = holder.hubSearchQuery.value
    val installed = remember(skills.installed, query) {
        SkillsDisplayLogic.filterRows(
            rows = skills.installed,
            query = query,
            nameOf = { it.name },
            summaryOf = { it.summary },
        )
    }
    val cards = remember(skills.catalogCards, query) {
        SkillsDisplayLogic.filterRows(
            rows = skills.catalogCards,
            query = query,
            nameOf = { it.name },
            summaryOf = { it.summary },
        )
    }
    val installedById = remember(skills.installed) {
        skills.installed.associateBy { it.skillId }
    }

    Box(modifier = modifier.fillMaxSize().testTag("skills.hub")) {
        Column(Modifier.fillMaxSize()) {
            IntegrationPaneHeader(
                title = stringResource(R.string.plugins_title),
                actions = {
                    IntegrationCircleAction(
                        icon = FloeIcons.Magnifier,
                        contentDescription = stringResource(R.string.skills_finder),
                        onClick = { holder.openFinder() },
                    )
                    IntegrationCircleAction(
                        icon = FloeIcons.Plus,
                        contentDescription = stringResource(R.string.skills_creator),
                        onClick = { holder.openCreator() },
                    )
                },
            )

            FloeSearchField(
                value = query,
                onValueChange = { holder.hubSearchQuery.value = it },
                placeholder = stringResource(R.string.plugins_search),
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )

            FloeSegmented(
                options = listOf(
                    stringResource(R.string.plugins_discover),
                    stringResource(R.string.plugins_installed),
                ),
                selectedIndex = if (holder.showingInstalled.value) 1 else 0,
                onSelect = { holder.showingInstalled.value = it == 1 },
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .verticalScroll(rememberScrollState()),
            ) {
                if (!holder.showingInstalled.value) {
                    // ⇄ Section("plugins.official")
                    if (cards.isNotEmpty()) {
                        FloeSettingsSectionCard(title = stringResource(R.string.plugins_official)) {
                            cards.forEach { card ->
                                FloeSectionRow(
                                    title = {
                                        CatalogCard(
                                            card = card,
                                            installedRow = installedById[card.skillId],
                                            onInstall = { holder.installOfficialSkill(card.skillId) },
                                            onEnable = { row ->
                                                holder.setSkillEnabled(row.skillId, row.revision, true)
                                            },
                                            onUpdate = { holder.openUpgrade(card.skillId) },
                                        )
                                    },
                                )
                            }
                        }
                    }
                    // ⇄ import actions section — THREE DIFFERENT destinations
                    // (SkillsView.swift:84-86). The pure mapping lives in
                    // SkillsImportRouting and the holder executes the route;
                    // tests pin both so finder/folder cannot collapse.
                    FloeSettingsSectionCard(title = null) {
                        FloeActionRow(
                            label = stringResource(R.string.plugins_import),
                            onClick = {
                                holder.runImportRoute(
                                    SkillsImportRouting.routeFor(DiscoverImportRowId.PLUGINS_IMPORT),
                                )
                            },
                        )
                        FloeActionRow(
                            label = stringResource(R.string.skills_import_folder),
                            onClick = {
                                holder.runImportRoute(
                                    SkillsImportRouting.routeFor(DiscoverImportRowId.IMPORT_FOLDER),
                                )
                            },
                        )
                        FloeActionRow(
                            label = stringResource(R.string.skills_creator),
                            onClick = {
                                holder.runImportRoute(
                                    SkillsImportRouting.routeFor(DiscoverImportRowId.CREATOR),
                                )
                            },
                        )
                    }
                    // ⇄ scripted auto-update section (shared preference with
                    // Settings → Content updates; one value, never a copy).
                    FloeSettingsSectionCard(title = stringResource(R.string.skills_auto_updates_title)) {
                        FloeSwitchRow(
                            title = stringResource(R.string.skills_auto_updates_label),
                            checked = skills.autoScriptedUpdates,
                            onCheckedChange = { holder.setAutoScriptedUpdates(it) },
                        )
                    }
                    IntegrationSectionFooter(stringResource(R.string.skills_auto_updates_footer))
                }

                // ⇄ Section("connectors.title") — present in both segments
                FloeSettingsSectionCard(title = stringResource(R.string.connectors_title)) {
                    FloeSectionRow(
                        onClick = { holder.openConnectors() },
                        leading = { IconBadge(FloeIcons.Antenna) },
                        title = {
                            Column {
                                FloeText(stringResource(R.string.connectors_manage), style = Floe.typography.body)
                                FloeText(
                                    stringResource(R.string.connectors_summary),
                                    style = Floe.typography.metadata,
                                    color = Floe.colors.secondaryLabel,
                                )
                            }
                        },
                    )
                }
                IntegrationSectionFooter(stringResource(R.string.connectors_footer))

                if (holder.showingInstalled.value) {
                    if (installed.isEmpty()) {
                        FloeUnavailableView(
                            icon = FloeIcons.Puzzle,
                            title = stringResource(R.string.skills_empty),
                            description = stringResource(R.string.skills_empty_hint),
                            modifier = Modifier.padding(vertical = 24.dp),
                        )
                    } else {
                        FloeSettingsSectionCard(title = null) {
                            installed.forEach { row ->
                                InstalledSkillRow(
                                    row = row,
                                    holder = holder,
                                    onLongPress = { deleteCandidate = row },
                                )
                            }
                        }
                    }
                }

                // ⇄ center.catalogError (secondary) / center.errorMessage (red)
                skills.catalogError?.let {
                    IntegrationMetaLine(it, modifier = Modifier.testTag("skills.catalogError"))
                }
                skills.errorMessage?.let {
                    IntegrationIssueLine(it, modifier = Modifier.testTag("skills.errorMessage"))
                }
                Spacer(Modifier.height(24.dp))
            }
        }

        // ⇄ .overlay { if center.isWorking ProgressView().controlSize(.large) }
        if (skills.isWorking) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                FloeActivityIndicator(description = stringResource(R.string.skills_working_cd))
            }
        }
    }

    val candidate = deleteCandidate
    if (candidate != null) {
        FloeConfirmDialog(
            title = stringResource(R.string.skills_remove_title),
            message = stringResource(R.string.skills_remove_message),
            confirmLabel = stringResource(R.string.action_delete),
            dismissLabel = stringResource(R.string.action_cancel),
            onConfirm = {
                deleteCandidate = null
                // Narrow destructive intent: ONLY after this explicit confirm.
                holder.deleteSkill(candidate.skillId, candidate.revision, confirmed = true)
            },
            onDismiss = { deleteCandidate = null },
        )
    }
}

/* ------------------------------ catalog card ------------------------------ */

@Composable
private fun CatalogCard(
    card: SkillCatalogCardUi,
    installedRow: SkillInstalledRowUi?,
    onInstall: () -> Unit,
    onEnable: (SkillInstalledRowUi) -> Unit,
    onUpdate: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            FloeText(
                card.name,
                style = Floe.typography.bodyEmphasized,
                color = Floe.colors.label,
                modifier = Modifier.weight(1f, fill = false),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.width(8.dp))
            FloeText(
                "v${card.version}",
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                maxLines = 1,
            )
        }
        FloeText(
            card.summary,
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )
        when (val action = SkillsDisplayLogic.catalogAction(card.state)) {
            CatalogCardAction.Install -> CardActionText(
                label = stringResource(R.string.action_install),
                tag = "skills.catalogInstall",
                onClick = onInstall,
            )
            CatalogCardAction.Enable -> CardActionText(
                label = stringResource(R.string.plugins_enable),
                tag = "skills.catalogEnable",
                onClick = { installedRow?.let(onEnable) },
            )
            is CatalogCardAction.OpenUpgrade -> CardActionText(
                label = stringResource(R.string.skills_update_to, action.version),
                tag = "skills.catalogUpdate",
                onClick = onUpdate,
            )
            CatalogCardAction.Busy -> FloeActivityIndicator(
                description = stringResource(R.string.skills_installing_cd),
            )
            CatalogCardAction.None -> FloeStatusLine(
                icon = FloeIcons.CheckCircle,
                text = stringResource(R.string.plugins_ready),
                color = Floe.colors.secondaryLabel,
            )
            is CatalogCardAction.Explain -> FloeStatusLine(
                // Honest unavailability: the host's reason, never a silent
                // dead button.
                icon = FloeIcons.InfoCircle,
                text = action.remediation,
                color = Floe.colors.secondaryLabel,
            )
        }
    }
}

@Composable
private fun CardActionText(label: String, tag: String, onClick: () -> Unit) {
    FloeText(
        label,
        style = Floe.typography.bodyEmphasized,
        color = Floe.colors.accent,
        modifier = Modifier
            .testTag(tag)
            .padding(vertical = 6.dp, horizontal = 2.dp)
            .clickable(onClick = onClick),
    )
}

/* ----------------------------- installed row ----------------------------- */

@Composable
private fun SectionScope.InstalledSkillRow(
    row: SkillInstalledRowUi,
    holder: IntegrationsFlowHolder,
    onLongPress: () -> Unit,
) {
    val cancelling = holder.isRunCancelling(row)
    FloeSectionRow(
        onLongClick = if (SkillsDisplayLogic.canDelete(row)) onLongPress else null,
        description = stringResource(R.string.skills_row_cd, row.name),
        title = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    FloeText(row.name, style = Floe.typography.bodyEmphasized, color = Floe.colors.label)
                    Spacer(Modifier.width(8.dp))
                    FloeText(
                        "v${row.version}",
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        maxLines = 1,
                    )
                }
                row.summary?.let {
                    FloeText(
                        it,
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                // Availability + offer: host verdicts only (never derived).
                AvailabilityBadge(row)
                OfferLine(row)
                val showRunLine = row.runActivity is SkillRunActivityUi.Running ||
                    row.runActivity is SkillRunActivityUi.Cancelling || cancelling
                if (showRunLine) {
                    FloeStatusLine(
                        icon = FloeIcons.Terminal,
                        text = stringResource(
                            if (cancelling || row.runActivity is SkillRunActivityUi.Cancelling) {
                                R.string.skills_run_cancelling
                            } else {
                                R.string.skills_run_running
                            },
                        ),
                        color = Floe.colors.secondaryLabel,
                    )
                }
                row.installStage?.let { stage ->
                    FloeStatusLine(
                        icon = FloeIcons.Refresh,
                        text = stageLabel(stage),
                        color = Floe.colors.secondaryLabel,
                    )
                }
                val updateVersion = row.updateAvailableVersion
                if (updateVersion != null) {
                    CardActionText(
                        label = stringResource(R.string.skills_update_to, updateVersion),
                        tag = "skills.updateAction",
                        onClick = { holder.openUpgrade(row.skillId) },
                    )
                }
            }
        },
        trailing = {
            if (SkillsDisplayLogic.canRequestStop(row) || cancelling) {
                IntegrationCircleAction(
                    icon = FloeIcons.StopSquare,
                    contentDescription = if (cancelling) {
                        stringResource(R.string.skills_run_cancelling)
                    } else {
                        stringResource(R.string.skills_run_stop)
                    },
                    // The affordance mirrors the live latch; the holder's
                    // exact-scope guard is the actual duplicate protection.
                    enabled = SkillsDisplayLogic.canRequestStop(row) && !cancelling,
                    onClick = { holder.cancelSkillRun(row) },
                )
            }
            FloeInlineSwitch(
                checked = row.enabled,
                onCheckedChange = { holder.setSkillEnabled(row.skillId, row.revision, it) },
                description = stringResource(R.string.skills_enabled_cd),
                enabled = SkillsDisplayLogic.canToggleEnabled(row),
            )
        },
    )
}

@Composable
private fun AvailabilityBadge(row: SkillInstalledRowUi) {
    when (val availability = row.availability) {
        SkillAvailabilityUi.Usable -> if (row.enabled) {
            FloeBadgePill(stringResource(R.string.skills_badge_usable), FloeBadgeTone.SUCCESS)
        }
        SkillAvailabilityUi.Disabled -> Unit // the switch already reads off
        is SkillAvailabilityUi.NeedsConfiguration -> FloeStatusLine(
            icon = FloeIcons.Gearshape,
            text = availability.remediation,
            color = Floe.colors.pending,
        )
        is SkillAvailabilityUi.EnvironmentUnavailable -> FloeStatusLine(
            icon = FloeIcons.InfoCircle,
            text = availability.remediation,
            color = Floe.colors.secondaryLabel,
        )
        is SkillAvailabilityUi.Blocked -> FloeStatusLine(
            icon = FloeIcons.ShieldAlert,
            text = availability.reason,
            color = Floe.colors.secondaryLabel,
        )
    }
}

@Composable
private fun OfferLine(row: SkillInstalledRowUi) {
    when (val summary = SkillsDisplayLogic.offerSummary(row)) {
        OfferSummary.Offered -> FloeText(
            stringResource(R.string.skills_offered),
            style = Floe.typography.metadata,
            color = Floe.colors.success,
        )
        is OfferSummary.NotOffered -> FloeText(
            summary.remediation ?: stringResource(R.string.skills_not_offered),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        is OfferSummary.NotOfferedModelOverride -> FloeText(
            summary.note ?: stringResource(R.string.skills_not_offered_override),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun stageLabel(stage: SkillInstallStageUi): String = when (stage) {
    SkillInstallStageUi.STAGING_SOURCE -> stringResource(R.string.skills_stage_staging)
    SkillInstallStageUi.VALIDATING_PACKAGE -> stringResource(R.string.skills_stage_validating)
    SkillInstallStageUi.CHECKING_COMPATIBILITY -> stringResource(R.string.skills_stage_compatibility)
    SkillInstallStageUi.COMMITTING -> stringResource(R.string.skills_stage_committing)
}

@Composable
private fun IconBadge(icon: ImageVector) {
    Box(
        modifier = Modifier.size(28.dp),
        contentAlignment = Alignment.Center,
    ) {
        IconGlyph(icon, Floe.colors.secondaryLabel, 20.dp)
    }
}
