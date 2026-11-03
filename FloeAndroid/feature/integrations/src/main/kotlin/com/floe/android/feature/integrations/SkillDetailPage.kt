// SPDX-License-Identifier: MPL-2.0
//
// Dedicated full-catalog entry detail sheet (⇄ a SwiftUI plugin detail sheet).
//
// All values are host-projected from the verified schemaVersion-3 feed and
// the actual installed row. Install routes into the existing staged review;
// update/rollback route into the existing upgrade sheet (which owns the
// explicit confirmation and effect token). This screen never stages,
// installs, grants a capability or claims dependency readiness by itself.

package com.floe.android.feature.integrations

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionRow
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeSectionRow
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeStatusLine
import com.floe.android.design.FloeText

@Composable
fun SkillDetailPage(
    skillId: String,
    detail: SkillDetailUi?,
    holder: IntegrationsFlowHolder,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.fillMaxSize().testTag("skills.detail")) {
        IntegrationEditorToolbar(
            confirmLabel = stringResource(R.string.skills_detail_close),
            cancelLabel = stringResource(R.string.action_cancel),
            inFlight = false,
            confirmEnabled = true,
            onCancel = onClose,
            onConfirm = onClose,
            confirmTag = "skills.detailDone",
        )

        val current = detail?.takeIf { it.skillId == skillId && !it.isLoading }
        if (current == null) {
            Column(
                modifier = Modifier.fillMaxSize().padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                FloeActivityIndicator(
                    description = stringResource(R.string.skills_detail_loading),
                )
                Spacer(Modifier.height(12.dp))
                FloeText(
                    stringResource(R.string.skills_detail_loading),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            return@Column
        }
        val detailError = current.errorMessage
        if (detailError != null && current.version.isBlank()) {
            Column(Modifier.fillMaxWidth().padding(24.dp)) {
                FloeStatusLine(
                    icon = FloeIcons.InfoCircle,
                    text = detailError,
                    color = Floe.colors.secondaryLabel,
                )
            }
            return@Column
        }

        FloeText(
            current.name.ifBlank { current.skillId },
            style = Floe.typography.navLargeTitle,
            color = Floe.colors.label,
            modifier = Modifier.padding(start = 20.dp, end = 20.dp, bottom = 4.dp),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        FloeText(
            "v${current.version}",
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.padding(start = 20.dp, end = 20.dp, bottom = 8.dp),
        )

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .verticalScroll(rememberScrollState()),
        ) {
            if (current.description.isNotBlank()) {
                FloeText(
                    current.description,
                    style = Floe.typography.body,
                    color = Floe.colors.label,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
                )
            }
            current.notes?.takeIf { it.isNotBlank() }?.let { notes ->
                FloeText(
                    notes,
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp),
                )
            }

            FloeSettingsSectionCard(title = stringResource(R.string.skills_detail_title)) {
                DetailValueRow(
                    stringResource(R.string.skills_detail_version),
                    "v${current.version}",
                )
                if (current.category.isNotBlank()) {
                    DetailValueRow(
                        stringResource(R.string.skills_detail_category),
                        current.category,
                    )
                }
                if (current.tags.isNotEmpty()) {
                    DetailValueRow(
                        stringResource(R.string.skills_detail_tags),
                        current.tags.joinToString(", "),
                    )
                }
                if (current.installPlatforms.isNotEmpty()) {
                    DetailValueRow(
                        stringResource(R.string.skills_detail_platforms),
                        current.installPlatforms.joinToString(", "),
                    )
                }
                if (current.scriptRuntime.isNotBlank()) {
                    DetailValueRow(
                        stringResource(R.string.skills_detail_runtime),
                        current.scriptRuntime,
                    )
                }
                val execution = listOfNotNull(
                    current.executionOS,
                    current.executionArch,
                    current.executionEvidence,
                ).joinToString(" · ")
                if (execution.isNotBlank()) {
                    DetailValueRow(
                        stringResource(R.string.skills_detail_execution),
                        execution,
                    )
                }
                current.packageSize?.let { size ->
                    DetailValueRow(
                        stringResource(R.string.skills_detail_package_size),
                        stringResource(R.string.skills_import_size, size),
                    )
                }
                current.packageSHA256?.takeIf { it.isNotBlank() }?.let { digest ->
                    DetailValueRow(
                        stringResource(R.string.skills_detail_package_digest),
                        digest,
                        monospaced = true,
                    )
                }
            }

            FloeSettingsSectionCard(
                title = stringResource(R.string.skills_detail_availability),
            ) {
                if (current.installed) {
                    DetailValueRow(
                        stringResource(R.string.skills_detail_installed_version),
                        current.installedVersion?.let { "v$it" }
                            ?: stringResource(R.string.skills_detail_not_installed),
                    )
                    if (!current.installedEnabled) {
                        DetailStatus(
                            icon = FloeIcons.InfoCircle,
                            text = stringResource(R.string.skills_detail_installed_disabled),
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                } else {
                    DetailStatus(
                        icon = FloeIcons.InfoCircle,
                        text = stringResource(R.string.skills_detail_not_installed),
                        color = Floe.colors.secondaryLabel,
                    )
                }
                if (current.updateAvailable) {
                    DetailStatus(
                        icon = FloeIcons.Refresh,
                        text = stringResource(R.string.skills_detail_update_available),
                        color = Floe.colors.pending,
                    )
                }
                if (current.canManageRollback) {
                    DetailStatus(
                        icon = FloeIcons.CheckCircle,
                        text = stringResource(R.string.skills_detail_rollback_available),
                        color = Floe.colors.secondaryLabel,
                    )
                }
                if (current.offer == "incompatible") {
                    DetailStatus(
                        icon = FloeIcons.InfoCircle,
                        text = stringResource(R.string.plugins_requires_newer_app),
                        color = Floe.colors.secondaryLabel,
                    )
                } else if (current.offer != "installable" && !current.installed) {
                    DetailStatus(
                        icon = FloeIcons.InfoCircle,
                        text = stringResource(R.string.plugins_catalog_unavailable),
                        color = Floe.colors.secondaryLabel,
                    )
                }
            }

            if (current.canInstall || current.canUpdate || current.canManageRollback) {
                FloeSettingsSectionCard(title = null) {
                    if (current.canInstall) {
                        FloeActionRow(
                            label = stringResource(R.string.action_install),
                            onClick = { holder.installOfficialSkill(current.skillId) },
                            modifier = Modifier.testTag("skills.detailInstall"),
                        )
                    }
                    if (current.canUpdate || current.canManageRollback) {
                        FloeActionRow(
                            label = stringResource(R.string.skills_detail_manage),
                            onClick = { holder.openUpgrade(current.skillId) },
                            modifier = Modifier.testTag("skills.detailManage"),
                        )
                    }
                }
            }

            FloeSettingsSectionCard(
                title = stringResource(R.string.skills_detail_dependencies),
            ) {
                val dependencies = current.dependencies
                if (dependencies.state == "notDeclared" ||
                    dependencies.state == "notRequired") {
                    DetailStatus(
                        icon = FloeIcons.InfoCircle,
                        text = stringResource(R.string.skills_detail_no_dependencies),
                        color = Floe.colors.secondaryLabel,
                    )
                } else if (dependencies.state == "notInstalled") {
                    DetailStatus(
                        icon = FloeIcons.InfoCircle,
                        text = stringResource(R.string.skills_detail_dependencies_after_install),
                        color = Floe.colors.secondaryLabel,
                    )
                } else {
                    dependencies.readinessState?.let { readiness ->
                        val copy = when (readiness) {
                            "taskRequired" -> stringResource(
                                R.string.skills_detail_readiness_task_required)
                            else -> stringResource(R.string.skills_detail_readiness_pending)
                        }
                        DetailValueRow(
                            stringResource(R.string.skills_detail_dependency_readiness),
                            copy,
                        )
                    }
                    for (profile in dependencies.profiles) {
                        for (requirement in profile.requirements) {
                            FloeSectionRow(
                                title = {
                                    Column(Modifier.padding(vertical = 4.dp)) {
                                        Row(
                                            modifier = Modifier.fillMaxWidth(),
                                            verticalAlignment = Alignment.CenterVertically,
                                        ) {
                                            val kindLabel = dependencyKindLabel(requirement.kind)
                                            val requirementLabel = buildString {
                                                append(kindLabel)
                                                append(" · ")
                                                append(requirement.name)
                                                requirement.version?.let {
                                                    append(" ")
                                                    append(it)
                                                }
                                            }
                                            FloeText(
                                                requirementLabel,
                                                style = Floe.typography.bodyEmphasized,
                                                color = Floe.colors.label,
                                                modifier = Modifier.weight(1f, fill = false),
                                            )
                                            if (requirement.required) {
                                                Spacer(Modifier.width(6.dp))
                                                FloeBadgePill(
                                                    stringResource(R.string.skills_detail_required),
                                                    FloeBadgeTone.SECONDARY,
                                                )
                                            } else {
                                                Spacer(Modifier.width(6.dp))
                                                FloeBadgePill(
                                                    stringResource(R.string.skills_detail_optional),
                                                    FloeBadgeTone.SECONDARY,
                                                )
                                            }
                                        }
                                        FloeText(
                                            requirement.purpose,
                                            style = Floe.typography.metadata,
                                            color = Floe.colors.secondaryLabel,
                                        )
                                    }
                                },
                            )
                        }
                    }
                    for (component in dependencies.runtimeComponents) {
                        DetailValueRow(
                            stringResource(R.string.skills_detail_runtime_component),
                            "${component.componentID} ${component.componentVersion}",
                        )
                        val target = listOfNotNull(
                            component.targetOS,
                            component.targetArch,
                        ).joinToString("/")
                        if (target.isNotBlank()) {
                            DetailValueRow(
                                stringResource(R.string.skills_detail_execution),
                                target,
                            )
                        }
                        if (component.unavailableOnAndroidTaskLinux) {
                            DetailNote(
                                stringResource(R.string.skills_detail_component_unavailable),
                            )
                        } else if (component.androidSupply == "clientVersionFloorNotMet") {
                            DetailNote(
                                stringResource(R.string.plugins_requires_newer_app),
                            )
                        } else if (component.androidSupply == "requiresRiscVTaskLinux") {
                            DetailNote(
                                stringResource(R.string.skills_detail_component_riscv),
                            )
                        }
                    }
                }
            }

            current.errorMessage?.let {
                IntegrationIssueLine(it, modifier = Modifier.testTag("skills.detailError"))
            }
            Spacer(Modifier.height(16.dp))
        }
    }
}

@Composable
private fun DetailValueRow(label: String, value: String, monospaced: Boolean = false) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 7.dp)) {
        FloeText(
            label,
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        FloeText(
            value,
            style = if (monospaced) Floe.typography.evidence else Floe.typography.body,
            color = Floe.colors.label,
            maxLines = if (monospaced) 2 else 4,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun dependencyKindLabel(kind: String): String = when (kind) {
    "pip" -> stringResource(R.string.skills_detail_kind_pip)
    "apt" -> stringResource(R.string.skills_detail_kind_apt)
    "npm" -> stringResource(R.string.skills_detail_kind_npm)
    "font" -> stringResource(R.string.skills_detail_kind_font)
    "runtimeComponent" -> stringResource(R.string.skills_detail_kind_runtime_component)
    else -> stringResource(R.string.skills_detail_kind_unknown)
}

@Composable
private fun DetailStatus(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    text: String,
    color: androidx.compose.ui.graphics.Color,
) {
    FloeStatusLine(
        icon = icon,
        text = text,
        color = color,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
    )
}

@Composable
private fun DetailNote(text: String) {
    FloeText(
        text,
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
    )
}
