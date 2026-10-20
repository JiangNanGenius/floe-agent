// SPDX-License-Identifier: MPL-2.0
//
// Install-review and upgrade sheets.
//
// SkillInstallReviewPage ⇄ SkillInstallReviewSheet: source, requested
// capabilities, tools, audited scripts and pinned pure-Python dependencies —
// exactly the facts the original requires before an install confirmation.
// The confirm button starts the host's staged commit; this sheet never
// implies that installing grants tool permissions (SKL-SOURCE-NO-GRANT:
// structure+signature validation precedes registration and imported content
// cannot grant authority).
//
// SkillUpgradePage ⇄ SkillGitHubUpgradeSheet: installed/available versions,
// permission-expansion warning, commit, localized release notes, new
// capabilities/tools, per-file before/after previews, rollback with its own
// confirmation dialog, and the source fields for community refs. Apply and
// rollback dispatches carry an effect token so a late result cannot act on a
// newer sheet. Dismissal while the host is committing is blocked (the
// service owns the work; closing would not cancel it).

package com.floe.android.feature.integrations

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionRow
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloeFormTextField
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeSectionRow
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeStatusLine
import com.floe.android.design.FloeText
import io.github.robinpcrd.cupertino.section.SectionScope

/* ---------------------------- install review ---------------------------- */

@Composable
fun SkillInstallReviewPage(
    review: SkillInstallReviewUi,
    holder: IntegrationsFlowHolder,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.fillMaxSize().testTag("skills.installReview")) {
        IntegrationEditorToolbar(
            confirmLabel = stringResource(R.string.action_install),
            cancelLabel = stringResource(R.string.action_cancel),
            inFlight = review.commitInFlight,
            confirmEnabled = !review.commitInFlight,
            onCancel = onCancel,
            onConfirm = { holder.confirmInstallReview(review) },
            confirmTag = "skills.installConfirm",
        )
        FloeText(
            stringResource(R.string.skills_review_title),
            style = Floe.typography.navLargeTitle,
            color = Floe.colors.label,
            modifier = Modifier.padding(start = 20.dp, end = 20.dp, bottom = 8.dp),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .verticalScroll(rememberScrollState()),
        ) {
            FloeSettingsSectionCard(title = stringResource(R.string.skills_review_source)) {
                ReviewValueRow(
                    label = review.skillName,
                    value = "v${review.version}",
                )
                TextRow(review.sourceDisplay, tag = "skills.reviewSource")
            }
            FloeSettingsSectionCard(title = stringResource(R.string.skills_review_permissions)) {
                if (review.requestedCapabilities.isEmpty()) {
                    TextRow(stringResource(R.string.skills_review_none))
                } else {
                    review.requestedCapabilities.forEach { capability ->
                        TextRow(capability)
                    }
                }
            }
            IntegrationSectionFooter(stringResource(R.string.skills_review_no_grant_note))

            if (review.tools.isNotEmpty()) {
                FloeSettingsSectionCard(title = stringResource(R.string.skills_review_tools)) {
                    review.tools.forEach { tool -> TextRow(tool) }
                }
            }
            if (review.containsScripts) {
                FloeSettingsSectionCard(
                    title = stringResource(R.string.skills_review_scripts),
                ) {
                    review.scriptPaths.forEach { path ->
                        TextRow(path, monospaced = true)
                    }
                }
            }
            if (review.pythonPackages.isNotEmpty()) {
                FloeSettingsSectionCard(
                    title = stringResource(R.string.skills_review_python_packages),
                ) {
                    review.pythonPackages.forEach { requirement ->
                        Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                            FloeText(
                                requirement.spec,
                                style = Floe.typography.evidence,
                                color = Floe.colors.label,
                            )
                            FloeText(
                                requirement.purpose,
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                            )
                        }
                    }
                }
                IntegrationSectionFooter(stringResource(R.string.skills_review_pypi_note))
            }
            Spacer(Modifier.height(16.dp))
        }
    }
}

/* -------------------------------- upgrade -------------------------------- */

@Composable
fun SkillUpgradePage(
    upgrade: SkillUpgradeUi,
    holder: IntegrationsFlowHolder,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var detailsOpen by remember(upgrade.skillId) { mutableStateOf(false) }
    var rollbackConfirm by remember(upgrade.skillId) { mutableStateOf(false) }
    // Local (non-secret) source fields, seeded from the saved community
    // source; official skills use the fixed hub source (fields hidden).
    var owner by remember(upgrade.skillId) { mutableStateOf(upgrade.savedSource?.owner.orEmpty()) }
    var repository by remember(upgrade.skillId) {
        mutableStateOf(upgrade.savedSource?.repository.orEmpty())
    }
    var ref by remember(upgrade.skillId) { mutableStateOf(upgrade.savedSource?.ref ?: "main") }
    var path by remember(upgrade.skillId) {
        mutableStateOf(upgrade.savedSource?.path ?: "SKILL.md")
    }

    val inFlight = upgrade.applyInFlight || upgrade.checkInFlight
    val canApply = upgrade.candidateVersion != null && !upgrade.isLatest && !inFlight
    val source = if (upgrade.isOfficial) {
        null
    } else {
        GitHubSourceFieldsUi(owner = owner, repository = repository, ref = ref, path = path)
    }

    Column(modifier = modifier.fillMaxSize().testTag("skills.upgrade")) {
        IntegrationEditorToolbar(
            confirmLabel = if (upgrade.candidateVersion == null) {
                stringResource(R.string.skills_update_check)
            } else {
                stringResource(R.string.skills_update_now)
            },
            cancelLabel = stringResource(R.string.action_cancel),
            inFlight = inFlight,
            confirmEnabled = if (upgrade.candidateVersion == null) !inFlight else canApply,
            onCancel = onClose,
            onConfirm = {
                if (upgrade.candidateVersion == null) {
                    holder.checkUpgrade(upgrade.skillId, source)
                } else {
                    holder.dispatchUpgradeEffect(
                        skillId = upgrade.skillId,
                        projection = upgrade,
                        rollback = false,
                        confirmed = true,
                    )
                }
            },
            confirmTag = if (upgrade.candidateVersion == null) {
                "skills.upgradeCheck"
            } else {
                "skills.upgradeApply"
            },
        )
        FloeText(
            upgrade.skillName,
            style = Floe.typography.navLargeTitle,
            color = Floe.colors.label,
            modifier = Modifier.padding(start = 20.dp, end = 20.dp, bottom = 8.dp),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .verticalScroll(rememberScrollState()),
        ) {
            FloeSettingsSectionCard(title = null) {
                ReviewValueRow(
                    label = stringResource(R.string.skills_update_installed),
                    value = "v${upgrade.installedVersion}",
                )
                upgrade.candidateVersion?.let { candidate ->
                    ReviewValueRow(
                        label = stringResource(R.string.skills_update_available),
                        value = "v$candidate",
                    )
                }
                when {
                    upgrade.addedCapabilities.isNotEmpty() || upgrade.addedTools.isNotEmpty() -> {
                        FloeSectionRow(
                            title = {
                                FloeStatusLine(
                                    icon = FloeIcons.ShieldAlert,
                                    text = stringResource(R.string.skills_update_permissions_warning),
                                    color = Floe.colors.pending,
                                )
                            },
                        )
                    }
                    upgrade.isLatest -> {
                        FloeSectionRow(
                            title = {
                                FloeStatusLine(
                                    icon = FloeIcons.CheckCircle,
                                    text = stringResource(R.string.skills_update_latest),
                                    color = Floe.colors.secondaryLabel,
                                )
                            },
                        )
                    }
                }
                if (upgrade.candidateVersion != null) {
                    FloeActionRow(
                        label = stringResource(R.string.skills_update_now),
                        onClick = {
                            holder.dispatchUpgradeEffect(
                                skillId = upgrade.skillId,
                                projection = upgrade,
                                rollback = false,
                                confirmed = true,
                            )
                        },
                        enabled = canApply,
                    )
                }
            }

            // Details disclosure (⇄ DisclosureGroup("skills.update.details"))
            FloeSettingsSectionCard(title = null) {
                FloeActionRow(
                    label = if (detailsOpen) {
                        stringResource(R.string.skills_update_hide_details)
                    } else {
                        stringResource(R.string.skills_update_details)
                    },
                    onClick = { detailsOpen = !detailsOpen },
                )
            }

            if (detailsOpen) {
                if (!upgrade.isOfficial) {
                    FloeSettingsSectionCard(title = stringResource(R.string.skills_update_source_section)) {
                        FloeFormTextField(
                            label = stringResource(R.string.skills_update_owner),
                            value = owner,
                            onValueChange = { owner = it },
                            enabled = !inFlight,
                        )
                        FloeFormTextField(
                            label = stringResource(R.string.skills_update_repository),
                            value = repository,
                            onValueChange = { repository = it },
                            enabled = !inFlight,
                        )
                        FloeFormTextField(
                            label = stringResource(R.string.skills_update_ref),
                            value = ref,
                            onValueChange = { ref = it },
                            enabled = !inFlight,
                            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false),
                        )
                        FloeFormTextField(
                            label = stringResource(R.string.skills_update_path),
                            value = path,
                            onValueChange = { path = it },
                            enabled = !inFlight,
                            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false),
                        )
                        FloeActionRow(
                            label = stringResource(R.string.skills_update_check),
                            onClick = { holder.checkUpgrade(upgrade.skillId, source) },
                            enabled = !inFlight,
                        )
                    }
                }
                TextRow(
                    upgrade.savedSource?.let {
                        "github.com/${it.owner}/${it.repository}@${it.ref}/${it.path}"
                    } ?: stringResource(R.string.skills_update_local_source),
                    tag = "skills.upgradeSource",
                )
                upgrade.releaseNotes?.let { notes ->
                    TextRow(notes, tag = "skills.upgradeNotes")
                }
                // Section-scope value rows need a grouped card context.
                FloeSettingsSectionCard(title = null) {
                    upgrade.commit?.let { commit ->
                        ReviewValueRow(
                            label = stringResource(R.string.skills_update_commit),
                            value = commit,
                        )
                    }
                    if (upgrade.addedCapabilities.isNotEmpty()) {
                        ReviewValueRow(
                            label = stringResource(R.string.skills_update_new_capabilities),
                            value = upgrade.addedCapabilities.sorted().joinToString(", "),
                        )
                    }
                    if (upgrade.addedTools.isNotEmpty()) {
                        ReviewValueRow(
                            label = stringResource(R.string.skills_update_new_tools),
                            value = upgrade.addedTools.sorted().joinToString(", "),
                        )
                    }
                }
                if (upgrade.changedFiles.isNotEmpty()) {
                    FloeSettingsSectionCard(title = stringResource(R.string.skills_update_changed_files)) {
                        upgrade.changedFiles.forEach { diff ->
                            Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                                FloeText(
                                    diff.path,
                                    style = Floe.typography.evidence,
                                    color = Floe.colors.label,
                                )
                                DiffPreview(
                                    label = stringResource(R.string.skills_update_before),
                                    text = diff.beforePreview,
                                )
                                DiffPreview(
                                    label = stringResource(R.string.skills_update_after),
                                    text = diff.afterPreview,
                                )
                            }
                        }
                    }
                }
                if (upgrade.canRollback) {
                    FloeSettingsSectionCard(title = null) {
                        FloeActionRow(
                            label = stringResource(R.string.skills_update_rollback),
                            onClick = { rollbackConfirm = true },
                            enabled = !inFlight,
                        )
                    }
                    IntegrationSectionFooter(stringResource(R.string.skills_update_rollback_note))
                }
            }

            upgrade.errorMessage?.let {
                IntegrationIssueLine(it, modifier = Modifier.testTag("skills.upgradeError"))
            }
            Spacer(Modifier.height(16.dp))
        }
    }

    if (rollbackConfirm) {
        FloeConfirmDialog(
            title = stringResource(R.string.skills_update_rollback_confirm_title),
            message = stringResource(R.string.skills_update_rollback_confirm_message),
            confirmLabel = stringResource(R.string.skills_update_rollback),
            dismissLabel = stringResource(R.string.action_cancel),
            onConfirm = {
                rollbackConfirm = false
                holder.dispatchUpgradeEffect(
                    skillId = upgrade.skillId,
                    projection = upgrade,
                    rollback = true,
                    confirmed = true,
                )
            },
            onDismiss = { rollbackConfirm = false },
        )
    }
}

/* --------------------------------- helpers -------------------------------- */

@Composable
private fun TextRow(text: String, tag: String? = null, monospaced: Boolean = false) {
    FloeText(
        text = text,
        style = if (monospaced) Floe.typography.evidence else Floe.typography.body,
        color = Floe.colors.secondaryLabel,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .then(if (tag != null) Modifier.testTag(tag) else Modifier),
    )
}

@Composable
private fun SectionScope.ReviewValueRow(label: String, value: String) {
    FloeSectionRow(
        title = { FloeText(label, style = Floe.typography.body, color = Floe.colors.label) },
        trailing = {
            FloeText(
                value,
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        },
    )
}

@Composable
private fun DiffPreview(label: String, text: String?) {
    FloeText(
        label,
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
    )
    FloeText(
        text = text?.takeIf { it.isNotBlank() } ?: stringResource(R.string.skills_update_absent),
        style = Floe.typography.evidence,
        color = Floe.colors.label,
        maxLines = 12,
        overflow = TextOverflow.Ellipsis,
    )
}
