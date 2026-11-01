// SPDX-License-Identifier: MPL-2.0
//
// C05 remote-host list/editor. Presentation only: every effect (bridge,
// credential store, SSH transport) belongs to the App-owned controller.

package com.floe.android.feature.remote

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloePrimaryAction
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbar
import com.floe.android.design.FloeUnavailableView
import com.floe.android.design.IconGlyph
import io.github.robinpcrd.cupertino.CupertinoTextField
import io.github.robinpcrd.cupertino.CupertinoTextFieldDefaults

@Composable
fun RemoteDestinationUi(
    state: RemoteHostUiState,
    compact: Boolean,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    onRefresh: () -> Unit,
    onSave: (RemoteHostDraft, String?) -> Unit,
    onDelete: (String) -> Unit,
    onConnect: (String) -> Unit,
    onApproveChallenge: (accept: Boolean, replaceChanged: Boolean) -> Unit,
    onDismissError: () -> Unit,
    onCloseSession: () -> Unit,
    onOpenTunnel: (String, Int) -> Unit,
    onCloseTunnel: (String) -> Unit,
    onStartExec: (String) -> Unit,
    onCancelExec: () -> Unit,
    onReleaseExec: () -> Unit,
    onTerminalVisible: (Boolean) -> Unit,
) {
    val session = state.session
    if (session != null) {
        RemoteSessionPage(
            state = state,
            session = session,
            compact = compact,
            onCloseSession = onCloseSession,
            onOpenTunnel = onOpenTunnel,
            onCloseTunnel = onCloseTunnel,
            onStartExec = onStartExec,
            onCancelExec = onCancelExec,
            onReleaseExec = onReleaseExec,
            onTerminalVisible = onTerminalVisible,
            onDismissError = onDismissError,
        )
    } else {
        RemoteHostsPage(
            state = state,
            compact = compact,
            showSidebarToggle = showSidebarToggle,
            onExpandSidebar = onExpandSidebar,
            onOpenDrawer = onOpenDrawer,
            onRefresh = onRefresh,
            onSave = onSave,
            onDelete = onDelete,
            onConnect = onConnect,
            onApproveChallenge = onApproveChallenge,
            onDismissError = onDismissError,
        )
    }
}

@Composable
private fun RemoteHostsPage(
    state: RemoteHostUiState,
    compact: Boolean,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    onRefresh: () -> Unit,
    onSave: (RemoteHostDraft, String?) -> Unit,
    onDelete: (String) -> Unit,
    onConnect: (String) -> Unit,
    onApproveChallenge: (accept: Boolean, replaceChanged: Boolean) -> Unit,
    onDismissError: () -> Unit,
) {
    var editorVisible by rememberSaveable { mutableStateOf(false) }
    var editingId by rememberSaveable { mutableStateOf<String?>(null) }
    var draft by remember { mutableStateOf(RemoteHostDraft()) }
    var secret by remember { mutableStateOf("") }
    var secretRevealed by remember { mutableStateOf(false) }
    var pendingDelete by remember { mutableStateOf<RemoteHostSummaryUi?>(null) }

    Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeToolbar(
            title = stringResource(R.string.remote_hosts_title),
            navigation = {
                if (compact || showSidebarToggle) {
                    com.floe.android.design.FloeCircleButton(
                        icon = FloeIcons.SidebarToggle,
                        contentDescription = stringResource(R.string.open_sidebar),
                        onClick = if (compact) onOpenDrawer else onExpandSidebar,
                    )
                }
            },
            actions = {
                if (state.busy != null) {
                    com.floe.android.design.FloeActivityIndicator()
                    Spacer(Modifier.width(6.dp))
                }
                com.floe.android.design.FloeCircleButton(
                    icon = FloeIcons.Plus,
                    contentDescription = stringResource(R.string.remote_hosts_add),
                    onClick = {
                        editingId = null
                        draft = RemoteHostDraft()
                        secret = ""
                        secretRevealed = false
                        editorVisible = true
                    },
                )
                com.floe.android.design.FloeCircleButton(
                    icon = FloeIcons.Refresh,
                    contentDescription = stringResource(R.string.remote_hosts_refresh),
                    onClick = onRefresh,
                )
            },
            showHairline = true,
        )

        val error = state.error
        if (error != null) {
            RemoteErrorBanner(error, onDismissError)
        }

        when {
            state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                com.floe.android.design.FloeActivityIndicator(description = stringResource(R.string.remote_loading))
            }
            !state.coreReady -> FloeUnavailableView(
                icon = FloeIcons.Terminal,
                title = stringResource(R.string.remote_hosts_title),
                description = stringResource(R.string.remote_hosts_unavailable),
                action = null,
            )
            state.profiles.isEmpty() -> FloeUnavailableView(
                icon = FloeIcons.Terminal,
                title = stringResource(R.string.remote_hosts_empty_title),
                description = stringResource(R.string.remote_hosts_empty_hint),
                action = null,
            )
            else -> LazyColumn(
                modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(state.profiles, key = { it.id }) { host ->
                    RemoteHostRow(
                        host = host,
                        busy = state.busy,
                        onConnect = { onConnect(host.id) },
                        onEdit = {
                            editingId = host.id
                            draft = RemoteHostDraft.from(
                                state.details[host.id] ?: RemoteHostDetailUi(
                                    summary = host,
                                    jumpHops = emptyList(),
                                    vncEndpointCount = host.vncEndpointCount,
                                    auxiliaryConnectionCount = host.auxiliaryConnectionCount,
                                )
                            )
                            secret = ""
                            secretRevealed = false
                            editorVisible = true
                        },
                        onDelete = { pendingDelete = host },
                    )
                }
                item { Spacer(Modifier.height(16.dp)) }
            }
        }
    }

    if (editorVisible) {
        RemoteEditorSheet(
            existingId = editingId,
            jumpHopCount = editingId?.let { state.details[it] }?.jumpHops?.size ?: 0,
            draft = draft,
            secret = secret,
            secretRevealed = secretRevealed,
            onRevealedChange = { secretRevealed = it },
            onDraftChange = { draft = it },
            onSecretChange = { secret = it },
            onDismiss = { editorVisible = false },
            onSave = {
                editorVisible = false
                onSave(draft, secret.takeIf { it.isNotBlank() })
                secret = ""
            },
        )
    }

    pendingDelete?.let { host ->
        FloeConfirmDialog(
            title = stringResource(R.string.remote_delete_title),
            message = stringResource(R.string.remote_delete_message),
            confirmLabel = stringResource(R.string.remote_delete),
            dismissLabel = stringResource(R.string.remote_cancel),
            onConfirm = {
                pendingDelete = null
                onDelete(host.id)
            },
            onDismiss = { pendingDelete = null },
        )
    }

    state.challenge?.let { challenge ->
        RemoteHostKeyDialog(
            challenge = challenge,
            onDecision = onApproveChallenge,
        )
    }
}

@Composable
private fun RemoteErrorBanner(error: RemoteHostUiError, onDismiss: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Floe.colors.destructive.copy(alpha = 0.08f))
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconGlyph(FloeIcons.WarningTriangle, Floe.colors.destructive, 16.dp)
        Spacer(Modifier.width(8.dp))
        FloeText(
            remoteMessage(error.code),
            style = Floe.typography.metadata,
            color = Floe.colors.destructive,
            modifier = Modifier.weight(1f),
        )
        FloeCapsuleAction(
            label = stringResource(R.string.remote_cancel),
            onClick = onDismiss,
            showHairline = false,
            tint = Floe.colors.destructive,
        )
    }
}

@Composable
private fun RemoteHostRow(
    host: RemoteHostSummaryUi,
    busy: String?,
    onConnect: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Floe.colors.chromeSurface)
            .clickable(onClick = onEdit)
            .padding(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            FloeText(
                host.displayName,
                style = Floe.typography.bodyEmphasized,
                color = Floe.colors.label,
                modifier = Modifier.weight(1f),
            )
            FloeBadgePill(
                text = when {
                    host.usesKey -> stringResource(R.string.remote_auth_key)
                    host.auth.kind == "none" -> stringResource(R.string.remote_no_ssh)
                    else -> stringResource(R.string.remote_auth_password)
                },
                tone = FloeBadgeTone.SECONDARY,
            )
            if (host.jumpHopCount > 0) {
                Spacer(Modifier.width(6.dp))
                FloeBadgePill(
                    text = host.jumpHopCount.toString(),
                    tone = FloeBadgeTone.ACCENT,
                )
            }
        }
        Spacer(Modifier.height(4.dp))
        FloeText(
            host.endpoint,
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FloeCapsuleAction(
                label = stringResource(R.string.remote_connect),
                onClick = onConnect,
                enabled = busy == null,
            )
            FloeCapsuleAction(
                label = stringResource(R.string.remote_edit),
                onClick = onEdit,
                enabled = busy == null,
            )
            FloeCapsuleAction(
                label = stringResource(R.string.remote_delete),
                onClick = onDelete,
                enabled = busy == null,
                tint = Floe.colors.destructive,
            )
        }
    }
}

@Composable
private fun RemoteEditorSheet(
    existingId: String?,
    jumpHopCount: Int,
    draft: RemoteHostDraft,
    secret: String,
    secretRevealed: Boolean,
    onRevealedChange: (Boolean) -> Unit,
    onDraftChange: (RemoteHostDraft) -> Unit,
    onSecretChange: (String) -> Unit,
    onDismiss: () -> Unit,
    onSave: () -> Unit,
) {
    val validation = validateRemoteHostDraft(draft)
    val authIndex = if (draft.authKind == RemoteHostDraft.AUTH_KEY) 1 else 0
    val keyIndex = when (draft.keyType) {
        RemoteHostDraft.KEY_P256 -> 1
        RemoteHostDraft.KEY_RSA4096 -> 2
        else -> 0
    }
    val policyIndex = if (draft.hostKeyPolicy == RemoteHostDraft.POLICY_PINNED) 1 else 0

    FloePageSheet(
        visible = true,
        onDismiss = onDismiss,
        widthFraction = 0.78f,
        heightFraction = 0.9f,
        placement = FloeSheetPlacement.CENTER,
    ) {
        Column(Modifier.fillMaxSize().padding(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeCapsuleAction(
                    label = stringResource(R.string.remote_cancel),
                    onClick = onDismiss,
                    showHairline = false,
                )
                Spacer(Modifier.weight(1f))
                FloeText(
                    stringResource(if (existingId == null) R.string.remote_hosts_add else R.string.remote_edit),
                    style = Floe.typography.section,
                    color = Floe.colors.label,
                )
                Spacer(Modifier.weight(1f))
                FloeCapsuleAction(
                    label = stringResource(R.string.remote_save),
                    onClick = onSave,
                    enabled = validation == null,
                )
            }
            FloeDivider(Modifier.padding(vertical = 8.dp))
            Column(
                Modifier.weight(1f).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                FieldLabel(stringResource(R.string.remote_display_name))
                FloePlainFormField(
                    label = stringResource(R.string.remote_display_name),
                    value = draft.displayName,
                    onValueChange = { onDraftChange(draft.copy(displayName = it)) },
                )
                FieldLabel(stringResource(R.string.remote_address))
                FloePlainFormField(
                    label = stringResource(R.string.remote_address),
                    value = draft.address,
                    onValueChange = { onDraftChange(draft.copy(address = it)) },
                )
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Column(Modifier.weight(1f)) {
                        FieldLabel(stringResource(R.string.remote_port))
                        FloePlainFormField(
                            label = stringResource(R.string.remote_port),
                            value = draft.port,
                            onValueChange = { onDraftChange(draft.copy(port = it)) },
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        )
                    }
                    Column(Modifier.weight(2f)) {
                        FieldLabel(stringResource(R.string.remote_user))
                        FloePlainFormField(
                            label = stringResource(R.string.remote_user),
                            value = draft.user,
                            onValueChange = { onDraftChange(draft.copy(user = it)) },
                        )
                    }
                }
                FieldLabel(stringResource(R.string.remote_authentication))
                FloeSegmented(
                    options = listOf(
                        stringResource(R.string.remote_auth_password),
                        stringResource(R.string.remote_auth_key),
                    ),
                    selectedIndex = authIndex,
                    onSelect = { index ->
                        onDraftChange(
                            draft.copy(
                                authKind = if (index == 1) {
                                    RemoteHostDraft.AUTH_KEY
                                } else {
                                    RemoteHostDraft.AUTH_PASSWORD
                                }
                            )
                        )
                    },
                )
                if (draft.authKind == RemoteHostDraft.AUTH_KEY) {
                    FieldLabel(stringResource(R.string.remote_key_type))
                    FloeSegmented(
                        options = listOf(
                            stringResource(R.string.remote_key_ed25519),
                            stringResource(R.string.remote_key_p256),
                            stringResource(R.string.remote_key_rsa),
                        ),
                        selectedIndex = keyIndex,
                        onSelect = { index ->
                            onDraftChange(
                                draft.copy(
                                    keyType = when (index) {
                                        1 -> RemoteHostDraft.KEY_P256
                                        2 -> RemoteHostDraft.KEY_RSA4096
                                        else -> RemoteHostDraft.KEY_ED25519
                                    }
                                )
                            )
                        },
                    )
                }
                FieldLabel(
                    if (draft.authKind == RemoteHostDraft.AUTH_KEY) {
                        stringResource(R.string.remote_private_key)
                    } else {
                        stringResource(R.string.remote_password)
                    }
                )
                SecureSecretField(
                    label = stringResource(R.string.remote_secret_keep_hint),
                    value = secret,
                    onValueChange = onSecretChange,
                    revealed = secretRevealed,
                    onRevealedChange = onRevealedChange,
                    revealLabel = stringResource(R.string.remote_reveal_secret),
                    hideLabel = stringResource(R.string.remote_hide_secret),
                    singleLine = draft.authKind != RemoteHostDraft.AUTH_KEY,
                    minLines = if (draft.authKind == RemoteHostDraft.AUTH_KEY) 4 else 1,
                    maxLines = if (draft.authKind == RemoteHostDraft.AUTH_KEY) 8 else 1,
                    monospaced = draft.authKind == RemoteHostDraft.AUTH_KEY,
                )
                FieldLabel(stringResource(R.string.remote_host_key_policy))
                FloeSegmented(
                    options = listOf(
                        stringResource(R.string.remote_policy_tofu),
                        stringResource(R.string.remote_policy_pinned),
                    ),
                    selectedIndex = policyIndex,
                    onSelect = { index ->
                        onDraftChange(
                            draft.copy(
                                hostKeyPolicy = if (index == 1) {
                                    RemoteHostDraft.POLICY_PINNED
                                } else {
                                    RemoteHostDraft.POLICY_TOFU
                                }
                            )
                        )
                    },
                )
                if (draft.hostKeyPolicy == RemoteHostDraft.POLICY_PINNED) {
                    FieldLabel(stringResource(R.string.remote_fingerprint))
                    FloePlainFormField(
                        label = stringResource(R.string.remote_fingerprint),
                        value = draft.pinnedFingerprint,
                        onValueChange = { onDraftChange(draft.copy(pinnedFingerprint = it)) },
                        monospaced = true,
                    )
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    FloeText(
                        stringResource(R.string.remote_legacy_algorithms),
                        style = Floe.typography.body,
                        color = Floe.colors.label,
                        modifier = Modifier.weight(1f),
                    )
                    com.floe.android.design.FloeInlineSwitch(
                        checked = draft.allowsLegacyAlgorithms,
                        onCheckedChange = { onDraftChange(draft.copy(allowsLegacyAlgorithms = it)) },
                        description = stringResource(R.string.remote_legacy_algorithms),
                    )
                }
                if (existingId != null) {
                    FloeText(
                        stringResource(R.string.remote_jump_hops, jumpHopCount),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
                validation?.let { code ->
                    FloeText(
                        remoteMessage(code),
                        style = Floe.typography.metadata,
                        color = Floe.colors.destructive,
                    )
                }
            }
        }
    }
}

@Composable
private fun SecureSecretField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    revealed: Boolean,
    onRevealedChange: (Boolean) -> Unit,
    revealLabel: String,
    hideLabel: String,
    singleLine: Boolean,
    minLines: Int,
    maxLines: Int,
    monospaced: Boolean,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        CupertinoTextField(
            value = value,
            onValueChange = onValueChange,
            modifier = Modifier
                .weight(1f)
                .semantics { contentDescription = label },
            textStyle = (if (monospaced) Floe.typography.evidence else Floe.typography.body)
                .copy(color = Floe.colors.label),
            placeholder = {
                FloeText(
                    label,
                    style = if (monospaced) Floe.typography.evidence else Floe.typography.body,
                    color = Floe.colors.placeholderText,
                    maxLines = 1,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                )
            },
            singleLine = singleLine,
            minLines = minLines,
            maxLines = maxLines,
            visualTransformation = if (revealed) {
                VisualTransformation.None
            } else {
                PasswordVisualTransformation()
            },
            keyboardOptions = KeyboardOptions(
                keyboardType = if (monospaced) KeyboardType.Text else KeyboardType.Password,
            ),
            colors = CupertinoTextFieldDefaults.colors(),
        )
        Box(
            modifier = Modifier
                .size(FloeLayout.MinimumTarget)
                .clickable { onRevealedChange(!revealed) }
                .semantics { contentDescription = if (revealed) hideLabel else revealLabel },
            contentAlignment = Alignment.Center,
        ) {
            IconGlyph(
                if (revealed) FloeIcons.EyeSlash else FloeIcons.Eye,
                Floe.colors.secondaryLabel,
                20.dp,
            )
        }
    }
}

@Composable
private fun FieldLabel(text: String) {
    FloeText(
        text,
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
    )
}

@Composable
private fun RemoteHostKeyDialog(
    challenge: RemoteHostKeyChallengeUi,
    onDecision: (accept: Boolean, replaceChanged: Boolean) -> Unit,
) {
    if (challenge.changed) {
        FloeConfirmDialog(
            title = stringResource(R.string.remote_replace_title),
            message = stringResource(
                R.string.remote_replace_message,
                challenge.address,
                challenge.port,
                challenge.fingerprintSHA256,
                challenge.expectedFingerprintSHA256 ?: "—",
            ),
            confirmLabel = stringResource(R.string.remote_replace_confirm),
            dismissLabel = stringResource(R.string.remote_cancel),
            onConfirm = { onDecision(true, true) },
            onDismiss = { onDecision(false, false) },
        )
    } else {
        FloeConfirmDialog(
            title = stringResource(R.string.remote_trust_title),
            message = stringResource(
                R.string.remote_trust_message,
                challenge.address,
                challenge.port,
                challenge.keyType,
            ) + "\n" + stringResource(R.string.remote_trust_fingerprint, challenge.fingerprintSHA256),
            confirmLabel = stringResource(R.string.remote_trust_confirm),
            dismissLabel = stringResource(R.string.remote_cancel),
            onConfirm = { onDecision(true, false) },
            onDismiss = { onDecision(false, false) },
        )
    }
}
