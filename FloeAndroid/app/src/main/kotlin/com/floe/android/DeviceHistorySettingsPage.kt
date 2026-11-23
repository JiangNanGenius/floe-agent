// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.floe.android.core.devicelink.DeviceHistoryPairingTicket
import com.floe.android.core.devicelink.DeviceHistorySyncError
import com.floe.android.core.devicelink.DeviceHistorySyncException
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionRow
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeFormTextField
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeInlineSwitch
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloeSectionRow
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbarIconButton
import com.floe.android.host.LocalNetworkAccessBroker
import com.floe.android.host.devicesync.DeviceHistoryPeer
import com.floe.android.host.devicesync.DeviceHistoryStatus
import com.floe.android.host.devicesync.DeviceHistorySyncHost
import com.floe.android.host.devicesync.DeviceHistorySyncState
import io.github.robinpcrd.cupertino.section.SectionScope
import java.net.URI
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

@Composable
internal fun DeviceHistorySettingsPage(localNetwork: LocalNetworkAccessBroker?) {
    val context = LocalContext.current
    val host = (context.applicationContext as FloeApplication).deviceHistorySync
    val state by host.state.collectAsState()
    val preferences = state.preferences
    val settingsAvailable = state.storeReady && !state.busy && state.status != DeviceHistoryStatus.SETTINGS_FAILED
    val connected = settingsAvailable && state.fingerprint != null
    var editingRelay by remember { mutableStateOf(false) }
    var addingPeer by remember { mutableStateOf(false) }
    var selectedPeerId by remember { mutableStateOf<String?>(null) }
    var needsLocalAccess by remember { mutableStateOf(false) }
    val owner = remember { "device-sync:" + UUID.randomUUID() }
    val visible = remember { AtomicBoolean(true) }
    val pairingLabel = stringResource(R.string.device_history_pairing_info)
    DisposableEffect(visible) {
        visible.set(true)
        onDispose { visible.set(false) }
    }
    LaunchedEffect(localNetwork, preferences.enabled) {
        if (preferences.enabled) {
            localNetwork?.refreshCheck()
            needsLocalAccess = when (localNetwork?.state) {
                LocalNetworkAccessBroker.PermissionState.Denied,
                LocalNetworkAccessBroker.PermissionState.DeniedForever -> true
                else -> false
            }
        }
    }

    Column(
        Modifier.fillMaxWidth().testTag("deviceHistorySync.settings").padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        FloeSettingsSectionCard(null, caption = { SyncCaption(stringResource(R.string.device_history_summary)) }) {
            SyncToggleRow(stringResource(R.string.device_history_enable), preferences.enabled,
                settingsAvailable, host::setEnabled)
            if (preferences.enabled) {
                SyncToggleRow(stringResource(R.string.device_history_public_relay), preferences.publicRelay,
                    settingsAvailable, host::setPublicRelay)
                FloeSectionRow(
                    title = { FloeText(stringResource(R.string.device_history_custom_relay)) },
                    trailing = { FloeText(preferences.customRelay?.let { URI(it).host }.orEmpty(),
                        style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) },
                    onClick = { editingRelay = true }, enabled = settingsAvailable,
                )
                if (needsLocalAccess && localNetwork != null) {
                    FloeActionRow(stringResource(R.string.device_history_allow_lan), {
                        localNetwork.runExplicitAction(
                            ownerID = owner, endpoint = "https://localhost",
                            isCurrent = visible::get, onDenied = { needsLocalAccess = true },
                            dispatch = {
                                needsLocalAccess = false
                                if (host.state.value.fingerprint != null) host.refreshAddress() else host.retry()
                            },
                        )
                    }, enabled = settingsAvailable)
                }
            }
        }
        SyncStatus(state)
        if (state.status == DeviceHistoryStatus.START_FAILED || state.status == DeviceHistoryStatus.SETTINGS_FAILED) {
            FloeSettingsSectionCard(null) {
                FloeActionRow(stringResource(R.string.retry), host::retry, enabled = !state.busy && state.storeReady)
            }
        }
        if (preferences.enabled) {
            FloeSettingsSectionCard(stringResource(R.string.device_history_this_device)) {
                state.fingerprint?.let { fingerprint ->
                    FloeSectionRow(title = { Fingerprint(fingerprint) })
                }
                FloeActionRow(stringResource(R.string.device_history_copy_pairing), {
                    state.pairingCode?.let { code ->
                        context.getSystemService(ClipboardManager::class.java)
                            ?.setPrimaryClip(ClipData.newPlainText(pairingLabel, code))
                    }
                }, enabled = connected && state.pairingCode != null)
                FloeActionRow(stringResource(R.string.device_history_refresh_address), host::refreshAddress,
                    enabled = connected)
            }
            FloeSettingsSectionCard(stringResource(R.string.device_history_peers)) {
                preferences.peers.forEach { peer ->
                    FloeSectionRow(
                        title = { FloeText(peer.name) },
                        caption = stringResource(R.string.device_history_shared_count, peer.sharedConversations.size),
                        onClick = { selectedPeerId = peer.id }, enabled = settingsAvailable,
                    )
                }
                FloeActionRow(stringResource(R.string.device_history_add_peer), { addingPeer = true },
                    enabled = connected)
            }
        }
    }
    if (editingRelay) {
        RelaySheet(preferences.customRelay.orEmpty(), onDismiss = { editingRelay = false }) { relay ->
            host.setCustomRelay(relay)
            editingRelay = false
        }
    }
    if (addingPeer) {
        PairingSheet(onDismiss = { addingPeer = false }) { ticket, name ->
            host.pair(ticket, name)
            addingPeer = false
        }
    }
    preferences.peers.firstOrNull { it.id == selectedPeerId }?.let { peer ->
        PeerSheet(host, state, peer) { selectedPeerId = null }
    }
}

@Composable
private fun SectionScope.SyncToggleRow(
    label: String, checked: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit,
) {
    FloeSectionRow(
        modifier = Modifier.toggleable(checked, enabled = enabled, role = Role.Switch, onValueChange = onChange),
        title = { FloeText(label) },
        trailing = { FloeInlineSwitch(checked, onChange, label,
            modifier = Modifier.clearAndSetSemantics { }, enabled = enabled) },
    )
}

@Composable
private fun PairingSheet(onDismiss: () -> Unit, confirm: (DeviceHistoryPairingTicket, String) -> Unit) {
    var name by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    var proposed by remember { mutableStateOf<DeviceHistoryPairingTicket?>(null) }
    var pairingError by remember { mutableStateOf<Int?>(null) }
    DeviceSyncSheet(stringResource(R.string.device_history_add_peer), onDismiss) {
        FloeSettingsSectionCard(null) {
            FloeFormTextField(stringResource(R.string.device_history_peer_name), name, { name = it.take(100) })
            FloeFormTextField(stringResource(R.string.device_history_paste_pairing), code, {
                code = it.take(8193)
                proposed = null
                pairingError = null
            }, singleLine = false, minLines = 3, maxLines = 5, isError = pairingError != null, monospaced = true)
            if (proposed == null) {
                FloeActionRow(stringResource(R.string.device_history_verify_peer), {
                    try {
                        proposed = DeviceHistoryPairingTicket.parse(code)
                        pairingError = null
                    } catch (failure: DeviceHistorySyncException) {
                        pairingError = if (failure.error == DeviceHistorySyncError.UNSUPPORTED_VERSION) {
                            R.string.device_history_incompatible
                        } else {
                            R.string.device_history_bad_pairing
                        }
                    }
                }, enabled = code.isNotBlank() && name.isNotBlank())
            }
        }
        pairingError?.let { SyncCaption(stringResource(it)) }
        proposed?.let { ticket ->
            FloeSettingsSectionCard(
                stringResource(R.string.device_history_verify_fingerprint),
                caption = { SyncCaption(stringResource(R.string.device_history_fingerprint_hint)) },
            ) {
                FloeSectionRow(title = { Fingerprint(ticket.address.endpointId) })
                FloeActionRow(stringResource(R.string.device_history_confirm_pair),
                    { confirm(ticket, name) }, enabled = name.isNotBlank())
            }
        }
    }
}

@Composable
private fun RelaySheet(address: String, onDismiss: () -> Unit, save: (String) -> Unit) {
    var value by remember(address) { mutableStateOf(address) }
    DeviceSyncSheet(stringResource(R.string.device_history_custom_relay), onDismiss) {
        FloeSettingsSectionCard(null, caption = { SyncCaption(stringResource(R.string.device_history_relay_hint)) }) {
            FloeFormTextField("https://", value, { value = it.take(513) },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
            FloeActionRow(stringResource(R.string.device_history_save_relay), { save(value) })
        }
    }
}

@Composable
private fun PeerSheet(host: DeviceHistorySyncHost, state: DeviceHistorySyncState,
                      peer: DeviceHistoryPeer, onDismiss: () -> Unit) {
    val projected = state.viewedPeer == peer.id
    val canManage = state.storeReady && !state.busy && state.status != DeviceHistoryStatus.SETTINGS_FAILED
    val canReceive = canManage && state.fingerprint != null
    var confirmingRemove by remember(peer.id) { mutableStateOf(false) }
    LaunchedEffect(peer.id) { host.showLocalOffers(peer.id) }
    DeviceSyncSheet(peer.name, onDismiss) {
        SyncStatus(state)
        FloeSettingsSectionCard(stringResource(R.string.device_history_receive_section)) {
            FloeActionRow(stringResource(R.string.device_history_list_remote), { host.fetch(peer.id) }, enabled = canReceive)
            if (projected) {
                val offers = state.remoteOffers
                if (offers?.isEmpty() == true) {
                    FloeSectionRow(title = { SyncCaption(stringResource(R.string.device_history_no_remote)) })
                }
                offers.orEmpty().forEach { offer ->
                    FloeSectionRow(title = { FloeText(offer.title) },
                        trailing = { SyncCaption(stringResource(R.string.device_history_receive)) },
                        onClick = { host.receive(peer.id, offer.id) }, enabled = canReceive)
                }
            }
        }
        FloeSettingsSectionCard(stringResource(R.string.device_history_share_section)) {
            if (projected) {
                state.localOffers.forEach { task ->
                    SyncToggleRow(task.title, task.id in peer.sharedConversations, canManage) {
                        host.share(peer.id, task.id, it)
                    }
                }
            }
            if (state.localOffers.isEmpty()) {
                FloeActionRow(stringResource(R.string.device_history_load_local),
                    { host.showLocalOffers(peer.id) }, enabled = canManage)
            }
        }
        FloeSettingsSectionCard(null) {
            FloeSectionRow(
                title = { FloeText(stringResource(R.string.device_history_remove), color = Floe.colors.destructive) },
                onClick = { confirmingRemove = true }, enabled = canManage,
            )
        }
    }
    if (confirmingRemove) {
        FloeConfirmDialog(
            title = stringResource(R.string.device_history_remove),
            message = stringResource(R.string.device_history_remove_hint, peer.name),
            confirmLabel = stringResource(R.string.device_history_remove),
            dismissLabel = stringResource(R.string.cancel),
            onConfirm = {
                confirmingRemove = false
                host.remove(peer.id)
                onDismiss()
            },
            onDismiss = { confirmingRemove = false },
        )
    }
}

@Composable
private fun DeviceSyncSheet(title: String, onDismiss: () -> Unit, content: @Composable () -> Unit) {
    FloePageSheet(visible = true, onDismiss = onDismiss,
        widthFraction = if (LocalConfiguration.current.screenWidthDp < 600) 1f else .76f,
        heightFraction = .88f) {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically) {
                FloeText(title, style = Floe.typography.title, modifier = Modifier.weight(1f))
                FloeToolbarIconButton(FloeIcons.ChevronDown, stringResource(R.string.done), onClick = onDismiss)
            }
            FloeDivider()
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                content()
            }
        }
    }
}

@Composable
private fun Fingerprint(value: String) {
    SelectionContainer {
        FloeText(value, style = Floe.typography.evidence, color = Floe.colors.secondaryLabel)
    }
}

@Composable
private fun SyncStatus(state: DeviceHistorySyncState) {
    if (state.busy) {
        FloeActivityIndicator()
        return
    }
    val text = when (state.status) {
        DeviceHistoryStatus.IDLE -> if (state.preferences.enabled && !state.storeReady) {
            stringResource(R.string.device_history_wait_store)
        } else return
        DeviceHistoryStatus.READY -> return
        DeviceHistoryStatus.START_FAILED -> stringResource(R.string.device_history_start_failed)
        DeviceHistoryStatus.SETTINGS_FAILED -> stringResource(R.string.device_history_settings_failed)
        DeviceHistoryStatus.TRANSFER_FAILED -> stringResource(R.string.device_history_transfer_failed)
        DeviceHistoryStatus.CONFLICT -> stringResource(R.string.device_history_conflict)
        DeviceHistoryStatus.BUSY_TASK -> stringResource(R.string.device_history_task_busy)
        DeviceHistoryStatus.INCOMPATIBLE -> stringResource(R.string.device_history_incompatible)
        DeviceHistoryStatus.INVALID_RELAY -> stringResource(R.string.device_history_bad_relay)
        DeviceHistoryStatus.RELAY_PENDING -> stringResource(R.string.device_history_relay_pending)
        DeviceHistoryStatus.IMPORT_UNCONFIRMED -> stringResource(R.string.device_history_import_unconfirmed)
        DeviceHistoryStatus.RECEIVED -> stringResource(R.string.device_history_received, state.importedMessages)
    }
    SyncCaption(text)
}

@Composable
private fun SyncCaption(text: String) {
    FloeText(text, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
}
