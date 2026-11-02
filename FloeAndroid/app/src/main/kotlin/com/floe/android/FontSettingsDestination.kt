// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.widget.TextView
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.graphics.toArgb
import com.floe.android.design.*
import com.floe.android.host.fonts.FontSettingsHost
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable
internal fun FontSettingsEntry() {
    var open by rememberSaveable { mutableStateOf(false) }
    Box(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) {
        FloeSettingsSectionCard(stringResource(R.string.fonts_title)) {
            FloeValueRow(stringResource(R.string.fonts_manage), "") { open = true }
        }
    }
    if (open) {
        val app = LocalContext.current.applicationContext as FloeApplication
        FloePageSheet(visible = true, onDismiss = { open = false },
            widthFraction = if (LocalConfiguration.current.screenWidthDp < 600) 1f else .8f,
            heightFraction = .94f) { FontSettingsDestination(app.fontSettings) { open = false } }
    }
}

@Composable
private fun FontSettingsDestination(host: FontSettingsHost, onDismiss: () -> Unit) {
    val state by host.state.collectAsState()
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let(host::install)
    }
    var removeID by rememberSaveable { mutableStateOf<String?>(null) }
    LaunchedEffect(host) { host.refresh() }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically) {
            FloeText(stringResource(R.string.fonts_title), style = Floe.typography.title, modifier = Modifier.weight(1f))
            FloeToolbarIconButton(FloeIcons.ChevronDown, stringResource(R.string.done), onClick = onDismiss)
        }
        FloeDivider()
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                FloeCapsuleAction(stringResource(R.string.fonts_import), {
                    picker.launch(arrayOf("font/*", "application/x-font-ttf", "application/x-font-opentype", "application/octet-stream"))
                }, enabled = !state.busy)
                if (state.busy) FloeActivityIndicator()
            }
            FloeText(stringResource(R.string.fonts_scope), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            if (state.entries.isEmpty() && !state.busy) FloeText(stringResource(R.string.fonts_empty), color = Floe.colors.secondaryLabel)
            state.outcome?.let { result ->
                FloeText(stringResource(when (result) {
                    "installed" -> R.string.fonts_installed
                    "removed" -> R.string.fonts_removed
                    "missing" -> R.string.fonts_missing
                    else -> R.string.fonts_failed
                }), style = Floe.typography.metadata)
            }
            state.entries.forEach { entry ->
                key(entry.id) {
                    FloeSettingsSectionCard(entry.faces.first().name) {
                        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            entry.faces.forEach { face -> FontSample(host, entry.reference(face), face.name) }
                            FloeCapsuleAction(stringResource(R.string.fonts_remove), { removeID = entry.id },
                                enabled = !state.busy, tint = Floe.colors.destructive)
                        }
                    }
                }
            }
        }
    }
    removeID?.let { id ->
        FloeConfirmDialog(stringResource(R.string.fonts_remove), stringResource(R.string.fonts_remove_note),
            stringResource(R.string.fonts_remove), stringResource(R.string.cancel),
            onConfirm = { removeID = null; host.remove(id) }, onDismiss = { removeID = null })
    }
}

@Composable
private fun FontSample(host: FontSettingsHost, reference: String, name: String) {
    val typeface by produceState<android.graphics.Typeface?>(null, reference) {
        value = withContext(Dispatchers.IO) { runCatching { host.store.resolve(reference) }.getOrNull() }
    }
    val ink = Floe.colors.label.toArgb()
    val sample = stringResource(R.string.fonts_sample, name)
    if (typeface == null) FloeText(name, style = Floe.typography.body)
    else AndroidView(factory = { TextView(it).apply { textSize = 18f } },
        update = { it.text = sample; it.typeface = typeface; it.setTextColor(ink) }, modifier = Modifier.fillMaxWidth())
}
