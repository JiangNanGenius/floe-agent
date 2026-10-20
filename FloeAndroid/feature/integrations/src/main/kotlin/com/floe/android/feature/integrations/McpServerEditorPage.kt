// SPDX-License-Identifier: MPL-2.0
//
// MCP server add/edit sheet (⇄ SkillsView.swift MCPServerEditor), section-for-
// section in the iPad order: Server (name, endpoint, enabled, allow-canvas +
// footer) → Authentication (method, header name when custom, secure draft,
// stored-credential note) → Network security (insecure HTTP) → Tools (per-
// tool enable when a real discovery exists) → validation line.
//
// Honesty contract:
//  - the typed secret lives ONLY in the slot's RAM field and travels only
//    with a SET intent; the projection never returns a saved raw secret;
//  - "Save and connect" is disabled without an authoritative editor
//    projection and honest network availability; the host reports the real
//    outcome (saveOutcome/saveError) for this identity+epoch;
//  - the tools section renders ONLY host-projected discoveries (the draft
//    toggles ride the save; nothing here invents tool rows);
//  - a pending Linux/stdio route renders as temporarily unavailable, never
//    as removed, and never offers a fake connect action for it.

package com.floe.android.feature.integrations

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
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
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeChoiceOption
import com.floe.android.design.FloeFormChoiceField
import com.floe.android.design.FloeFormTextField
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeInlineSwitch
import com.floe.android.design.FloeSectionRow
import com.floe.android.design.FloeSecureFormField
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeStatusLine
import com.floe.android.design.FloeSwitchRow
import com.floe.android.design.FloeText
import io.github.robinpcrd.cupertino.section.SectionScope

@Composable
fun McpServerEditorPage(
    identity: McpEditorIdentity,
    slot: McpEditorSlot,
    editor: McpEditorUiState?,
    holder: IntegrationsFlowHolder,
    onCancel: () -> Unit,
    onSave: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val projected = editor?.takeIf { it.identity.isCurrentFor(identity) }
    val seed = projected?.seed ?: slot.seed
    val draft = slot.snapshot.value
    val inFlight = projected?.saveInFlight == true || slot.saveDispatched
    val networkAvailable = projected?.networkActionsAvailable == true
    val saveError = projected?.saveError
    // ⇄ disabled(displayName.empty || endpointText.empty) at the toolbar;
    // everything else is answered by the host's Swift validation on dispatch.
    val saveEnabled = projected != null && networkAvailable && !inFlight &&
        draft.displayName.isNotBlank() && draft.endpointText.isNotEmpty()
    var authMenuOpen by remember(identity.editorId) { mutableStateOf(false) }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(Floe.colors.groupedSurface)
            .testTag("mcp.editorPage")
            .imePadding()
            .navigationBarsPadding(),
    ) {
        IntegrationEditorToolbar(
            confirmLabel = stringResource(R.string.mcp_save_and_connect),
            cancelLabel = stringResource(R.string.action_cancel),
            inFlight = inFlight,
            confirmEnabled = saveEnabled,
            onCancel = onCancel,
            onConfirm = onSave,
            confirmTag = "mcp.saveAction",
        )
        FloeText(
            text = if (draft.displayName.isBlank()) {
                stringResource(R.string.mcp_add_title)
            } else {
                draft.displayName
            },
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
                .verticalScroll(rememberScrollState())
                .padding(bottom = 16.dp),
        ) {
            // When no authoritative projection exists yet, the editor states
            // that plainly instead of pretending the form can commit.
            if (projected == null) {
                IntegrationMetaLine(stringResource(R.string.integration_waiting_host))
            } else if (!networkAvailable) {
                IntegrationMetaLine(
                    projected.networkActionsUnavailableReason
                        ?: stringResource(R.string.integration_network_unavailable),
                )
            }

            (seed.transport as? McpTransportUi.PendingEnvironment)?.let { pending ->
                FloeSettingsSectionCard(title = stringResource(R.string.mcp_transport_section)) {
                    FloeStatusLine(
                        icon = FloeIcons.InfoCircle,
                        text = pending.remediation,
                        color = Floe.colors.secondaryLabel,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
                    )
                }
            }

            /* ------------------------------- server ------------------------------- */
            FloeSettingsSectionCard(title = stringResource(R.string.mcp_server_section)) {
                FloeFormTextField(
                    label = stringResource(R.string.mcp_name_field),
                    value = draft.displayName,
                    onValueChange = { holder.setMcpDisplayName(identity, it) },
                )
                FloeFormTextField(
                    label = stringResource(R.string.mcp_endpoint_field),
                    value = draft.endpointText,
                    onValueChange = { holder.setMcpEndpoint(identity, it) },
                    keyboardOptions = KeyboardOptions(
                        keyboardType = KeyboardType.Uri,
                        autoCorrectEnabled = false,
                    ),
                    isError = McpFormPreflight.looksInvalid(draft)
                        ?.let {
                            it == McpPreflightFinding.ENDPOINT_REQUIRED ||
                                it == McpPreflightFinding.ENDPOINT_UNPARSEABLE
                        } == true,
                )
                FloeSwitchRow(
                    title = stringResource(R.string.mcp_enabled_field),
                    checked = draft.enabled,
                    onCheckedChange = { holder.setMcpEnabled(identity, it) },
                )
                FloeSwitchRow(
                    title = stringResource(R.string.mcp_allow_canvas),
                    checked = draft.allowInCanvas,
                    onCheckedChange = { holder.setMcpAllowInCanvas(identity, it) },
                )
            }
            IntegrationSectionFooter(stringResource(R.string.mcp_server_footer))

            /* ---------------------------- authentication ---------------------------- */
            FloeSettingsSectionCard(title = stringResource(R.string.mcp_auth_section)) {
                val stored = projected?.credentialStored ?: seed.credentialStored
                val options = listOf(
                    FloeChoiceOption(
                        McpAuthenticationUi.NONE.swiftRaw,
                        stringResource(R.string.mcp_auth_none),
                    ),
                    FloeChoiceOption(
                        McpAuthenticationUi.BEARER_TOKEN.swiftRaw,
                        stringResource(R.string.mcp_auth_bearer),
                    ),
                    FloeChoiceOption(
                        McpAuthenticationUi.CUSTOM_HEADER.swiftRaw,
                        stringResource(R.string.mcp_auth_custom_header),
                    ),
                )
                FloeFormChoiceField(
                    label = stringResource(R.string.mcp_auth_method),
                    options = options,
                    selectedKey = draft.authentication.swiftRaw,
                    expanded = authMenuOpen,
                    onExpandedChange = { authMenuOpen = it },
                    onSelect = { key ->
                        val next = options.first { it.key == key }.key
                            .let { raw ->
                                McpAuthenticationUi.entries.first { it.swiftRaw == raw }
                            }
                        holder.setMcpAuthentication(identity, next)
                    },
                )
                if (draft.authentication == McpAuthenticationUi.CUSTOM_HEADER) {
                    FloeFormTextField(
                        label = stringResource(R.string.mcp_header_name),
                        value = draft.credentialHeaderName,
                        onValueChange = { holder.setMcpHeaderName(identity, it) },
                        keyboardOptions = KeyboardOptions(autoCorrectEnabled = false),
                        isError = McpFormPreflight.looksInvalid(draft) ==
                            McpPreflightFinding.HEADER_NAME_INVALID,
                    )
                }
                if (draft.authentication != McpAuthenticationUi.NONE) {
                    SectionCredentialField(
                        identity = identity,
                        slot = slot,
                        stored = stored,
                        holder = holder,
                    )
                    if (stored) {
                        FloeStatusLine(
                            icon = FloeIcons.ShieldCheck,
                            text = stringResource(R.string.mcp_credentials_saved),
                            color = Floe.colors.secondaryLabel,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
                        )
                    }
                }
            }

            /* --------------------------- network security --------------------------- */
            FloeSettingsSectionCard(title = stringResource(R.string.mcp_network_security)) {
                FloeSwitchRow(
                    title = stringResource(R.string.mcp_allow_insecure_http),
                    checked = draft.allowInsecureHttp,
                    onCheckedChange = { holder.setMcpAllowInsecureHttp(identity, it) },
                )
            }

            /* -------------------------------- tools -------------------------------- */
            val liveTools: List<McpToolRowUi>? = projected?.tools ?: seed.tools.ifEmpty { null }
            if (!liveTools.isNullOrEmpty()) {
                FloeSettingsSectionCard(title = stringResource(R.string.mcp_tools_section)) {
                    liveTools.forEach { tool ->
                        FloeSectionRow(
                            title = {
                                Column {
                                    FloeText(
                                        tool.displayName ?: tool.remoteName,
                                        style = Floe.typography.body,
                                        color = Floe.colors.label,
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                    FloeText(
                                        tool.toolDescription,
                                        style = Floe.typography.metadata,
                                        color = Floe.colors.secondaryLabel,
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                    if (tool.destructiveHint) {
                                        // Hints come from the server and are
                                        // UNTRUSTED metadata: they inform the
                                        // approval UI, they never grant or
                                        // auto-approve anything.
                                        FloeStatusLine(
                                            icon = FloeIcons.ShieldAlert,
                                            text = stringResource(R.string.mcp_tool_destructive_hint),
                                            color = Floe.colors.pending,
                                        )
                                    } else if (tool.readOnlyHint) {
                                        FloeStatusLine(
                                            icon = FloeIcons.InfoCircle,
                                            text = stringResource(R.string.mcp_tool_readonly_hint),
                                            color = Floe.colors.secondaryLabel,
                                        )
                                    }
                                }
                            },
                            trailing = {
                                FloeInlineSwitch(
                                    checked = McpDraftLogic.toolEnabled(draft, tool),
                                    onCheckedChange = {
                                        holder.setMcpToolEnabledDraft(identity, tool.remoteName, it)
                                    },
                                    description = stringResource(R.string.mcp_tool_enable_cd, tool.displayName ?: tool.remoteName),
                                )
                            },
                        )
                    }
                }
                IntegrationSectionFooter(stringResource(R.string.mcp_tools_footer))
            }

            /* ----------------------------- findings ----------------------------- */
            saveError?.let {
                IntegrationIssueLine(it, modifier = Modifier.testTag("mcp.saveError"))
            }
            val preflight = McpFormPreflight.looksInvalid(draft)
            if (preflight != null && saveError == null) {
                IntegrationMetaLine(preflightMessage(preflight))
            }
        }
    }
}

/** ⇄ SecureField with the stored/new placeholder switch + local reveal. */
@Composable
private fun SectionScope.SectionCredentialField(
    identity: McpEditorIdentity,
    slot: McpEditorSlot,
    stored: Boolean,
    holder: IntegrationsFlowHolder,
) {
    // The field renders the RAM draft only. `stored` flips the placeholder
    // (⇄ "enter new credentials to replace the" vs "Credentials"); reveal is
    // local and never fetches the stored secret.
    FloeSecureFormField(
        label = stringResource(
            if (stored) R.string.mcp_credential_replace else R.string.providers_credentials,
        ),
        value = slot.secureInput.value.orEmpty(),
        onValueChange = { holder.setMcpSecureInput(identity, it) },
        revealed = slot.revealSecureInput.value,
        onRevealedChange = { slot.revealSecureInput.value = it },
        revealOnLabel = stringResource(R.string.mcp_reveal_on),
        revealOffLabel = stringResource(R.string.mcp_reveal_off),
    )
}

@Composable
private fun preflightMessage(finding: McpPreflightFinding): String = when (finding) {
    McpPreflightFinding.NAME_REQUIRED -> stringResource(R.string.mcp_name_required)
    McpPreflightFinding.ENDPOINT_REQUIRED,
    McpPreflightFinding.ENDPOINT_UNPARSEABLE,
    -> stringResource(R.string.mcp_valid_url_required)
    McpPreflightFinding.ENDPOINT_EMBEDS_CREDENTIAL ->
        stringResource(R.string.mcp_credential_in_url)
    McpPreflightFinding.INSECURE_HTTP_NOT_ALLOWED ->
        stringResource(R.string.mcp_insecure_blocked_hint)
    McpPreflightFinding.HEADER_NAME_INVALID ->
        stringResource(R.string.mcp_header_name_invalid)
}
