// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.floe.android.R
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionRow
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeFormTextField
import com.floe.android.design.FloeInlineSwitch
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloeSecureFormField
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeSectionRow
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeStatusLine
import com.floe.android.design.FloeText
import com.floe.android.design.FloeValueRow
import com.floe.android.design.FloeIcons

/**
 * G02 web-search settings page. Mirrors the iOS split:
 *
 *  * the settings detail pane lists the 8 original presets plus any persisted
 *    custom provider, with direct enable toggles;
 *  * tapping a row opens a nested editor sheet with the actual metadata and
 *    per-kind credential fields.
 *
 * Stored secrets are never read back or displayed. The editor starts in Keep
 * whenever a credential is present and only creates a Set attempt when the
 * user explicitly selects Replace and enters every required field.
 */
@Composable
fun WebSearchSettingsPage(controller: WebSearchHostController) {
    LaunchedEffect(controller) { controller.ensureLoaded() }
    val state by controller.state.collectAsState()
    // The Settings sheet owns the SINGLE bounded vertical scroll for this
    // pane; a page-level scroll here would nest inside it (infinite max
    // height crash). The nested editor dialog keeps its own bounded scroll.
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        FloeSettingsSectionCard(title = stringResource(R.string.websearch_providers)) {
            if (state.loading && !state.loaded) {
                FloeSectionRow(title = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        FloeActivityIndicator(description = stringResource(R.string.websearch_loading))
                    }
                })
            }
            if (state.error != null && state.rows.isEmpty()) {
                FloeSectionRow(title = {
                    WebSearchStatusLine(
                        text = stringResource(R.string.websearch_unavailable),
                        warning = true,
                    )
                })
                FloeActionRow(
                    label = stringResource(R.string.settings_retry),
                    onClick = { controller.refresh() },
                )
            }
            state.rows.forEach { row ->
                FloeSectionRow(
                    onClick = { controller.openEditor(row.configuration.id) },
                    title = {
                        Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                            FloeText(
                                row.configuration.displayName,
                                style = Floe.typography.body,
                                color = Floe.colors.label,
                                maxLines = 1,
                            )
                            Spacer(Modifier.height(2.dp))
                            FloeText(
                                stringResource(webSearchKindLabel(row.configuration.kind)),
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                                maxLines = 1,
                            )
                            FloeText(
                                if (!row.configured) {
                                    stringResource(R.string.websearch_not_configured)
                                } else {
                                    stringResource(webSearchCredentialLabel(row.credentialState))
                                },
                                style = Floe.typography.metadata,
                                color = Floe.colors.tertiaryLabel,
                                maxLines = 1,
                            )
                        }
                    },
                    trailing = {
                        FloeInlineSwitch(
                            checked = row.configuration.enabled,
                            onCheckedChange = { enabled ->
                                controller.setEnabled(row.configuration.id, enabled)
                            },
                            description = stringResource(R.string.websearch_enabled),
                            enabled = !state.listSaveInFlight,
                        )
                    },
                )
            }
            FloeActionRow(
                label = stringResource(R.string.websearch_add_custom),
                onClick = { controller.openNewCustomProvider() },
                enabled = !state.listSaveInFlight,
            )
            FloeSectionRow(title = {
                FloeText(
                    stringResource(R.string.websearch_providers_footer),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(vertical = 8.dp),
                )
            })
        }
        if (state.lastSaved) {
            FloeSettingsSectionCard(title = stringResource(R.string.websearch_status)) {
                FloeSectionRow(title = {
                    WebSearchStatusLine(stringResource(R.string.websearch_saved))
                })
            }
        }
        state.listSaveError?.let { code ->
            FloeSettingsSectionCard(title = stringResource(R.string.websearch_save_failed)) {
                FloeSectionRow(title = {
                    WebSearchStatusLine(webSearchFailureText(code), warning = true)
                })
                FloeActionRow(
                    label = stringResource(R.string.settings_retry),
                    onClick = { controller.refresh() },
                )
            }
        }
        if (state.error != null && state.rows.isNotEmpty()) {
            FloeSettingsSectionCard(title = stringResource(R.string.settings_action_failed_title)) {
                FloeSectionRow(title = {
                    WebSearchStatusLine(
                        if (state.error == "readbackUnavailable") {
                            stringResource(R.string.websearch_readback_failed)
                        } else {
                            stringResource(R.string.websearch_unavailable)
                        },
                        warning = true,
                    )
                })
                FloeActionRow(
                    label = stringResource(R.string.settings_retry),
                    onClick = { controller.refresh() },
                )
            }
        }
    }

    state.editor?.let { editor ->
        WebSearchEditorSheet(controller = controller, editor = editor)
    }
}

@Composable
private fun WebSearchEditorSheet(
    controller: WebSearchHostController,
    editor: WebSearchHostController.WebSearchEditorState,
) {
    val state by controller.state.collectAsState()
    var revealed by remember(editor.editorId) { mutableStateOf<Set<String>>(emptySet()) }
    var confirmClear by remember(editor.editorId) { mutableStateOf(false) }
    val inFlight = editor.saveInFlight || state.loading

    DisposableEffect(editor.editorId, editor.routeToken) {
        onDispose {
            controller.disposeEditorIfOwned(editor.editorId, editor.routeToken)
        }
    }

    val configuration = LocalConfiguration.current
    val wide = configuration.screenWidthDp >= 700
    FloePageSheet(
        visible = true,
        onDismiss = { controller.closeEditor() },
        widthFraction = if (wide) 0.84f else 1f,
        heightFraction = if (wide) 0.88f else 1f,
        placement = if (wide) FloeSheetPlacement.CENTER else FloeSheetPlacement.BOTTOM,
        topInset = if (wide) 0.dp else FloeLayout.SettingsSheetTopInset,
    ) {
            Column(
                Modifier
                    .fillMaxSize()
                    .background(Floe.colors.readingSurface),
            ) {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.cancel),
                        onClick = { controller.closeEditor() },
                        enabled = !inFlight,
                    )
                    Column(Modifier.weight(1f)) {
                        FloeText(
                            stringResource(
                                if (editor.configured) {
                                    R.string.websearch_editor_title
                                } else {
                                    R.string.websearch_new_title
                                },
                            ),
                            style = Floe.typography.title,
                            color = Floe.colors.label,
                            maxLines = 1,
                        )
                        FloeText(
                            stringResource(webSearchKindLabel(editor.draft.kind)),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                            maxLines = 1,
                        )
                    }
                    if (inFlight) {
                        FloeActivityIndicator(description = stringResource(R.string.websearch_saving))
                    }
                    FloeCapsuleAction(
                        label = if (inFlight) {
                            stringResource(R.string.websearch_saving)
                        } else {
                            stringResource(R.string.settings_save)
                        },
                        onClick = {
                            if (editor.credentialIntent ==
                                WebSearchHostController.CredentialIntent.CLEAR
                            ) {
                                confirmClear = true
                            } else {
                                controller.saveEditor()
                            }
                        },
                        enabled = !inFlight && (
                            editor.credentialIntent ==
                                WebSearchHostController.CredentialIntent.KEEP ||
                                state.native.secureSave
                            ),
                    )
                }
                FloeDivider()
                Column(
                    Modifier
                        .fillMaxWidth()
                        .weight(1f)
                        .verticalScroll(rememberScrollState())
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                ) {
                    FloeSettingsSectionCard(title = stringResource(R.string.websearch_provider)) {
                        FloeFormTextField(
                            label = stringResource(R.string.websearch_display_name),
                            value = editor.draft.displayName,
                            onValueChange = controller::updateDisplayName,
                            enabled = !inFlight,
                        )
                        FloeValueRow(
                            title = stringResource(R.string.websearch_kind),
                            value = stringResource(webSearchKindLabel(editor.draft.kind)),
                        )
                        FloeFormTextField(
                            label = stringResource(R.string.websearch_endpoint),
                            value = editor.draft.endpointText,
                            onValueChange = controller::updateEndpoint,
                            enabled = !inFlight,
                            keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                                keyboardType = KeyboardType.Uri,
                            ),
                        )
                        FloeSectionRow(title = {
                            FloeText(
                                if (editor.draft.kind.requiresEndpoint) {
                                    stringResource(R.string.websearch_endpoint_required_note)
                                } else {
                                    stringResource(R.string.websearch_endpoint_optional)
                                },
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                            )
                        })
                        FloeFormTextField(
                            label = stringResource(R.string.websearch_priority),
                            value = editor.draft.priorityText,
                            onValueChange = controller::updatePriority,
                            enabled = !inFlight,
                            keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                                keyboardType = KeyboardType.Number,
                            ),
                        )
                        FloeFormTextField(
                            label = stringResource(R.string.websearch_region),
                            value = editor.draft.regionText,
                            onValueChange = controller::updateRegion,
                            enabled = !inFlight,
                        )
                        FloeSectionRow(title = {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                FloeText(
                                    stringResource(R.string.websearch_enabled),
                                    style = Floe.typography.body,
                                    color = Floe.colors.label,
                                    modifier = Modifier.weight(1f),
                                )
                                FloeInlineSwitch(
                                    checked = editor.draft.enabled,
                                    onCheckedChange = controller::updateEnabled,
                                    description = stringResource(R.string.websearch_enabled),
                                    enabled = !inFlight,
                                )
                            }
                        })
                        if (editor.draft.kind == WebSearchProviderKind.BOCHA_WEB) {
                            FloeSectionRow(title = {
                                Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        FloeText(
                                            stringResource(R.string.websearch_summary),
                                            style = Floe.typography.body,
                                            color = Floe.colors.label,
                                            modifier = Modifier.weight(1f),
                                        )
                                        FloeInlineSwitch(
                                            checked = editor.draft.options["summaryEnabled"] != "false",
                                            onCheckedChange = controller::updateSummaryEnabled,
                                            description = stringResource(R.string.websearch_summary),
                                            enabled = !inFlight,
                                        )
                                    }
                                    FloeText(
                                        stringResource(R.string.websearch_summary_caption),
                                        style = Floe.typography.metadata,
                                        color = Floe.colors.secondaryLabel,
                                    )
                                }
                            })
                        }
                        if (editor.draft.kind == WebSearchProviderKind.CUSTOM ||
                            editor.draft.kind == WebSearchProviderKind.VOLCENGINE
                        ) {
                            FloeSectionRow(title = {
                                WebSearchStatusLine(
                                    stringResource(R.string.websearch_custom_endpoint_note),
                                )
                            })
                        }
                    }

                    FloeSettingsSectionCard(title = stringResource(R.string.websearch_credential)) {
                        FloeSectionRow(title = {
                            Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                                FloeSegmented(
                                    options = listOf(
                                        stringResource(R.string.websearch_credential_keep),
                                        stringResource(R.string.websearch_credential_set),
                                        stringResource(R.string.websearch_credential_clear),
                                    ),
                                    selectedIndex = editor.credentialIntent.ordinal,
                                    onSelect = { index ->
                                        controller.setCredentialIntent(
                                            WebSearchHostController.CredentialIntent.entries[index],
                                        )
                                    },
                                )
                                Spacer(Modifier.height(8.dp))
                                WebSearchStatusLine(
                                    stringResource(
                                        webSearchCredentialLabel(editor.originalCredentialState),
                                    ),
                                )
                                Spacer(Modifier.height(4.dp))
                                FloeText(
                                    stringResource(
                                        when (editor.credentialIntent) {
                                            WebSearchHostController.CredentialIntent.KEEP ->
                                                R.string.websearch_credential_keep_note
                                            WebSearchHostController.CredentialIntent.SET ->
                                                R.string.websearch_credential_set_note
                                            WebSearchHostController.CredentialIntent.CLEAR ->
                                                R.string.websearch_credential_clear_note
                                        },
                                    ),
                                    style = Floe.typography.metadata,
                                    color = Floe.colors.secondaryLabel,
                                )
                            }
                        })
                        if (!state.native.secureSave &&
                            editor.credentialIntent != WebSearchHostController.CredentialIntent.KEEP
                        ) {
                            FloeSectionRow(title = {
                                WebSearchStatusLine(
                                    stringResource(R.string.websearch_credential_update_unavailable),
                                    warning = true,
                                )
                            })
                        }
                        if (editor.credentialIntent ==
                            WebSearchHostController.CredentialIntent.SET
                        ) {
                            editor.draft.kind.editableCredentialFields.forEach { field ->
                                val value = editor.draft.credentialValues[field.key] ?: ""
                                FloeSecureFormField(
                                    label = stringResource(
                                        if (field == WebSearchCredentialField.API_KEY &&
                                            editor.draft.kind == WebSearchProviderKind.SEARXNG
                                        ) {
                                            R.string.websearch_api_key_optional
                                        } else {
                                            webSearchCredentialFieldLabel(field)
                                        },
                                    ),
                                    value = value,
                                    onValueChange = { controller.updateCredential(field, it) },
                                    revealed = field.key in revealed,
                                    onRevealedChange = { shown ->
                                        revealed = if (shown) revealed + field.key
                                        else revealed - field.key
                                    },
                                    revealOnLabel = stringResource(R.string.websearch_show_credentials),
                                    revealOffLabel = stringResource(R.string.websearch_hide_credentials),
                                    enabled = !inFlight,
                                    isError = editor.failure == "credentialFieldsRequired" &&
                                        value.isBlank(),
                                )
                            }
                        }
                    }

                    editor.failure?.let { code ->
                        FloeSettingsSectionCard(title = stringResource(R.string.settings_action_failed_title)) {
                            FloeSectionRow(title = {
                                WebSearchStatusLine(
                                    webSearchFailureText(code),
                                    warning = true,
                                )
                            })
                            if (code == "staleRevision" || code == "baseRevisionConflict") {
                                FloeActionRow(
                                    label = stringResource(R.string.websearch_reload),
                                    onClick = { controller.reloadEditorForRetry() },
                                )
                            }
                        }
                    }
                }
        }
    }

    if (confirmClear) {
        FloeConfirmDialog(
            title = stringResource(R.string.websearch_credential_remove_confirm),
            message = stringResource(R.string.websearch_credential_remove_message),
            confirmLabel = stringResource(R.string.websearch_remove),
            dismissLabel = stringResource(R.string.cancel),
            onConfirm = {
                confirmClear = false
                controller.saveEditor()
            },
            onDismiss = { confirmClear = false },
        )
    }
}

@Composable
private fun WebSearchStatusLine(text: String, warning: Boolean = false) {
    FloeStatusLine(
        icon = if (warning) FloeIcons.WarningTriangle else FloeIcons.InfoCircle,
        text = text,
        color = if (warning) Floe.colors.destructive else Floe.colors.secondaryLabel,
    )
}

private fun webSearchKindLabel(kind: WebSearchProviderKind): Int = when (kind) {
    WebSearchProviderKind.BOCHA_WEB, WebSearchProviderKind.BOCHA_AI -> R.string.websearch_kind_bocha
    WebSearchProviderKind.TENCENT_WSA -> R.string.websearch_kind_tencent
    WebSearchProviderKind.VOLCENGINE -> R.string.websearch_kind_volcengine
    WebSearchProviderKind.BRAVE -> R.string.websearch_kind_brave
    WebSearchProviderKind.TAVILY -> R.string.websearch_kind_tavily
    WebSearchProviderKind.EXA -> R.string.websearch_kind_exa
    WebSearchProviderKind.GOOGLE_PROGRAMMABLE -> R.string.websearch_kind_google
    WebSearchProviderKind.SEARXNG -> R.string.websearch_kind_searxng
    WebSearchProviderKind.CUSTOM -> R.string.websearch_kind_custom
}

private fun webSearchCredentialLabel(state: WebSearchCredentialState): Int = when (state) {
    WebSearchCredentialState.AVAILABLE -> R.string.websearch_credential_present
    WebSearchCredentialState.NO_CREDENTIAL_REQUIRED -> R.string.websearch_credential_not_required
    WebSearchCredentialState.GATEWAY_UNREGISTERED -> R.string.websearch_credential_gateway
    WebSearchCredentialState.SECRET_MISSING -> R.string.websearch_credential_missing
    WebSearchCredentialState.SECRET_LOCKED -> R.string.websearch_credential_locked
    WebSearchCredentialState.SECRET_INVALIDATED -> R.string.websearch_credential_invalid
    WebSearchCredentialState.OUTCOME_UNKNOWN -> R.string.websearch_credential_unknown
    WebSearchCredentialState.UNKNOWN -> R.string.websearch_credential_unknown
}

private fun webSearchCredentialFieldLabel(field: WebSearchCredentialField): Int = when (field) {
    WebSearchCredentialField.API_KEY -> R.string.websearch_api_key
    WebSearchCredentialField.SECRET_ID -> R.string.websearch_secret_id
    WebSearchCredentialField.SECRET_KEY -> R.string.websearch_secret_key
    WebSearchCredentialField.ENGINE_ID -> R.string.websearch_engine_id
}

@Composable
private fun webSearchFailureText(code: String): String = when (code) {
    "staleRevision", "baseRevisionConflict" -> stringResource(R.string.websearch_stale_revision)
    "credentialFieldsRequired" -> stringResource(R.string.websearch_credential_required)
    "endpointRequired" -> stringResource(R.string.websearch_endpoint_required)
    "endpointInvalid" -> stringResource(R.string.websearch_endpoint_invalid)
    "displayNameRequired" -> stringResource(R.string.websearch_display_name_required)
    "priorityInvalid" -> stringResource(R.string.websearch_priority_invalid)
    "secureSaveUnavailable", "secureSaveUnsupported" ->
        stringResource(R.string.websearch_credential_update_unavailable)
    "readbackUnavailable" -> stringResource(R.string.websearch_readback_failed)
    "configurationMissing" -> stringResource(R.string.websearch_configuration_missing)
    else -> stringResource(R.string.websearch_save_failed)
}
