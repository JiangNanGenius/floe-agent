// SPDX-License-Identifier: MPL-2.0
//
// Transient skill forms, mapped from the three original sheets:
//  - SkillCreatorFormPage  ⇄ SkillCreatorSheet (name / "When should Floe use
//    it?" / instructions; Install disabled until all three are filled and the
//    host is idle — ⇄ the original button's disabled() expression);
//  - SkillFinderFormPage   ⇄ SkillFinderSheet (HTTPS source + rewrite model
//    picker defaulting to the host's default agent model ⇄ onAppear);
//  - SkillImportConfirmPage⇄ the fileImporter/installTraditionalPackage
//    surface, Android-shaped: it shows ONLY the opaque staged reference and
//    metadata (no path, no bytes) and asks for one explicit confirm.
//
// None of these forms performs any work itself: each submit is a host effect
// addressed to the form id, and the sheet closes only when the host projects
// a SUCCESS outcome for that same id (⇄ "dismiss if errorMessage == nil").

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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeChoiceOption
import com.floe.android.design.FloeFormChoiceField
import com.floe.android.design.FloeFormTextField
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeText

@Composable
fun SkillCreatorFormPage(
    slot: SkillFormSlot,
    skills: SkillsHubUiState,
    holder: IntegrationsFlowHolder,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val draft = slot.creatorDraft()
    val inFlight = slot.dispatchInFlight || skills.isWorking
    val enabled = SkillsDisplayLogic.creatorInstallEnabled(draft, skills.isWorking)

    SkillFormScaffold(
        title = stringResource(R.string.skills_creator),
        confirmLabel = stringResource(R.string.action_install),
        inFlight = inFlight,
        confirmEnabled = enabled,
        onCancel = onClose,
        onConfirm = { holder.submitCreator(slot.formId, skills.isWorking) },
        errorMessage = skills.formOutcome
            ?.takeIf { it.formId == slot.formId && !it.succeeded }
            ?.message,
        modifier = modifier,
        confirmTag = "skills.creatorInstall",
    ) {
        FloeSettingsSectionCard(title = null) {
            FloeFormTextField(
                label = stringResource(R.string.skills_name),
                value = slot.creatorName.value,
                onValueChange = { slot.creatorName.value = it },
                enabled = !inFlight,
            )
            FloeFormTextField(
                label = stringResource(R.string.skills_description),
                value = slot.creatorDescription.value,
                onValueChange = { slot.creatorDescription.value = it },
                enabled = !inFlight,
                singleLine = false,
                minLines = 2,
                maxLines = 4,
            )
            FloeFormTextField(
                label = stringResource(R.string.skills_instructions),
                value = slot.creatorInstructions.value,
                onValueChange = { slot.creatorInstructions.value = it },
                enabled = !inFlight,
                singleLine = false,
                minLines = 6,
                maxLines = 14,
            )
        }
    }
}

@Composable
fun SkillFinderFormPage(
    slot: SkillFormSlot,
    skills: SkillsHubUiState,
    holder: IntegrationsFlowHolder,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // ⇄ .onAppear: if rewriteModelID == nil { defaultRewriteModelID ?: first }
    LaunchedEffect(slot.formId, skills.rewriteModels, skills.defaultRewriteModelId) {
        if (slot.finderModelId.value == null) {
            slot.finderModelId.value =
                skills.defaultRewriteModelId ?: skills.rewriteModels.firstOrNull()?.modelId
        }
    }
    val inFlight = slot.dispatchInFlight || skills.isWorking
    val enabled = SkillsDisplayLogic.finderInstallEnabled(
        urlText = slot.finderUrl.value,
        selectedModelId = slot.finderModelId.value,
        hostWorking = skills.isWorking,
    )
    val modelOptions = skills.rewriteModels.map { FloeChoiceOption(it.modelId, it.displayName) }
    var modelMenuOpen by remember(slot.formId) { mutableStateOf(false) }

    SkillFormScaffold(
        title = stringResource(R.string.skills_finder),
        confirmLabel = stringResource(R.string.action_install),
        inFlight = inFlight,
        confirmEnabled = enabled,
        onCancel = onClose,
        onConfirm = { holder.submitFinder(slot.formId, skills.isWorking) },
        errorMessage = skills.formOutcome
            ?.takeIf { it.formId == slot.formId && !it.succeeded }
            ?.message,
        modifier = modifier,
        confirmTag = "skills.finderInstall",
        footer = stringResource(R.string.skills_finder_footer),
    ) {
        FloeSettingsSectionCard(title = stringResource(R.string.skills_finder_source)) {
            FloeFormTextField(
                label = "https://…",
                value = slot.finderUrl.value,
                onValueChange = { slot.finderUrl.value = it },
                enabled = !inFlight,
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Uri,
                    autoCorrectEnabled = false,
                ),
            )
            if (modelOptions.isNotEmpty()) {
                FloeFormChoiceField(
                    label = stringResource(R.string.skills_finder_model),
                    options = modelOptions,
                    selectedKey = slot.finderModelId.value,
                    expanded = modelMenuOpen,
                    onExpandedChange = { modelMenuOpen = it },
                    onSelect = { slot.finderModelId.value = it },
                )
            }
        }
    }
}

@Composable
fun SkillImportConfirmPage(
    slot: SkillFormSlot,
    skills: SkillsHubUiState,
    holder: IntegrationsFlowHolder,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val reference = slot.stagedReference.value
    val inFlight = slot.dispatchInFlight || skills.isWorking
    SkillFormScaffold(
        title = stringResource(R.string.skills_import_title),
        confirmLabel = stringResource(R.string.action_install),
        inFlight = inFlight,
        confirmEnabled = reference != null && !inFlight,
        onCancel = onClose,
        onConfirm = { holder.submitImport(slot.formId, skills.isWorking) },
        errorMessage = skills.formOutcome
            ?.takeIf { it.formId == slot.formId && !it.succeeded }
            ?.message,
        modifier = modifier,
        confirmTag = "skills.importInstall",
        footer = stringResource(R.string.skills_import_footer),
    ) {
        FloeSettingsSectionCard(title = stringResource(R.string.skills_review_source)) {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 10.dp)) {
                FloeText(
                    reference?.displayName ?: stringResource(R.string.skills_import_missing),
                    style = Floe.typography.body,
                    color = Floe.colors.label,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                reference?.mimeType?.let {
                    FloeText(it, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                }
                reference?.sizeBytes?.let {
                    FloeText(
                        stringResource(R.string.skills_import_size, it),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
            }
        }
    }
}

/* --------------------------------- chrome --------------------------------- */

@Composable
private fun SkillFormScaffold(
    title: String,
    confirmLabel: String,
    inFlight: Boolean,
    confirmEnabled: Boolean,
    onCancel: () -> Unit,
    onConfirm: () -> Unit,
    errorMessage: String?,
    modifier: Modifier = Modifier,
    confirmTag: String,
    footer: String? = null,
    content: @Composable () -> Unit,
) {
    Column(modifier = modifier.fillMaxSize().testTag("skills.form")) {
        IntegrationEditorToolbar(
            confirmLabel = confirmLabel,
            cancelLabel = stringResource(R.string.action_cancel),
            inFlight = inFlight,
            confirmEnabled = confirmEnabled,
            onCancel = onCancel,
            onConfirm = onConfirm,
            confirmTag = confirmTag,
        )
        FloeText(
            title,
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
            content()
            errorMessage?.let {
                IntegrationIssueLine(it, modifier = Modifier.testTag("skills.formError"))
            }
            footer?.let { IntegrationSectionFooter(it) }
            Spacer(Modifier.height(16.dp))
        }
    }
}
