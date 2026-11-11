// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeCapsuleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeInlineSwitch
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloeSettingsContentDensity
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeText

/** Closed value editor kind, mirrored from the rootsystem policy table. */
enum class DeviceAccessSystemSettingKindUi { INT, SCALE }

/** One closed settings key with its real stored state. */
data class DeviceAccessSystemSettingUi(
    val namespace: String,
    val key: String,
    val deviceWide: Boolean,
    val currentValue: String?,
    /** Stored value captured when the sheet opened; the restore target. */
    val baselineValue: String?,
    val kind: DeviceAccessSystemSettingKindUi,
    val minInclusive: Long,
    val maxInclusive: Long,
)

/** One typed change from the sheet to the host. */
data class DeviceAccessSystemSettingChangeUi(
    val namespace: String,
    val key: String,
    val value: String,
    /** Restore of an originally-absent key uses a delete. */
    val delete: Boolean = false,
)

/**
 * Real state for the system-settings sheet: the closed key list with stored
 * values, whether the ceilings/service allow edits right now, and the bounded
 * outcome of the last apply/restore (receipts summary, not internals).
 */
data class DeviceAccessSystemSettingsUiState(
    val entries: List<DeviceAccessSystemSettingUi> = emptyList(),
    val enabled: Boolean = false,
    val busy: Boolean = false,
    val lastResult: String? = null,
)

/**
 * Compact editor for the ten closed device settings. It opens as a sheet over
 * the device-access settings page: one summary row per key, inline edit
 * controls, a single Apply for the changed rows (at most eight, the typed
 * batch bound) and per-row Restore back to the value captured at open. Global
 * animation scales are labeled device-wide; system keys show the exact current
 * user in the caption.
 */
@Composable
internal fun DeviceAccessSystemSettingsSheet(
    visible: Boolean,
    state: DeviceAccessSystemSettingsUiState,
    onApply: (List<DeviceAccessSystemSettingChangeUi>) -> Unit,
    /** [baseline] is the stored value captured when the sheet opened; null
     *  restores an originally-absent key with a delete. */
    onRestore: (DeviceAccessSystemSettingUi, String?) -> Unit,
    onDismiss: () -> Unit,
) {
    if (!visible) return
    val config = LocalConfiguration.current
    val compact = FloeLayout.usesCompactNavigation(
        config.screenWidthDp.toFloat(), config.smallestScreenWidthDp.toFloat(),
    )
    // Drafts and restore baselines live only while the sheet is open; Apply
    // sends only rows whose draft differs from the stored value. Null
    // current (absent) shows as "-".
    val drafts = remember {
        mutableStateMapOf<String, String>().apply {
            state.entries.forEach { put(it.namespace + "/" + it.key, it.currentValue ?: "") }
        }
    }
    val baselines = remember {
        mutableMapOf<String, String?>().apply {
            state.entries.forEach { put(it.namespace + "/" + it.key, it.currentValue) }
        }
    }
    var appliedOnce by remember { mutableStateOf(false) }
    // The real read arrives after the sheet opens. Capture its baseline once;
    // update observable drafts after an explicit Apply/Restore completes.
    LaunchedEffect(state.entries, state.busy) {
        state.entries.forEach { entry ->
            val id = entry.namespace + "/" + entry.key
            if (!baselines.containsKey(id)) baselines[id] = entry.currentValue
            if (!drafts.containsKey(id) || (appliedOnce && !state.busy)) {
                drafts[id] = entry.currentValue ?: ""
            }
        }
    }
    FloeSettingsContentDensity(compact) {
        FloePageSheet(
            visible = true,
            onDismiss = onDismiss,
            topInset = if (compact) 16.dp else 0.dp,
            widthFraction = if (compact) 1f else 0.6f,
            heightFraction = if (compact) 1f else 0.8f,
            placement = if (compact) FloeSheetPlacement.BOTTOM else FloeSheetPlacement.CENTER,
        ) {
            Column(Modifier.fillMaxSize().background(Floe.colors.groupedSurface)) {
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    FloeText(
                        stringResource(R.string.device_access_system_settings_sheet_title),
                        style = Floe.typography.section,
                        modifier = Modifier.weight(1f),
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    FloeCapsuleButton(
                        stringResource(R.string.done),
                        onClick = onDismiss,
                        modifier = Modifier.widthIn(min = 64.dp, max = 96.dp),
                    )
                }
                FloeDivider()
                val changed = state.entries.filter {
                    (drafts[it.namespace + "/" + it.key] ?: "") != (it.currentValue ?: "")
                }
                SheetCaption(
                    text = when {
                        !state.enabled -> stringResource(
                            R.string.device_access_system_settings_requires_ceiling)
                        changed.size > 8 -> stringResource(
                            R.string.device_access_system_settings_too_many, changed.size)
                        state.busy -> stringResource(R.string.device_access_permission_ops_loading)
                        state.lastResult != null -> state.lastResult
                        else -> stringResource(R.string.device_access_system_settings_hint)
                    },
                    error = !state.enabled || changed.size > 8,
                )
                SheetActionRow(
                    applyEnabled = state.enabled && !state.busy && changed.isNotEmpty() &&
                        changed.size <= 8,
                    busy = state.busy,
                    onApply = {
                        appliedOnce = true
                        onApply(changed.map {
                            DeviceAccessSystemSettingChangeUi(
                                namespace = it.namespace,
                                key = it.key,
                                value = drafts[it.namespace + "/" + it.key] ?: "",
                            )
                        })
                    },
                )
                FloeDivider()
                Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
                    state.entries.forEach { entry ->
                        SettingRow(
                            entry = entry,
                            enabled = state.enabled && !state.busy,
                            draft = drafts[entry.namespace + "/" + entry.key] ?: "",
                            onDraft = { drafts[entry.namespace + "/" + entry.key] = it },
                            onRestore = {
                                appliedOnce = true
                                onRestore(entry, baselines[entry.namespace + "/" + entry.key])
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SheetCaption(text: String, error: Boolean) {
    FloeText(
        text,
        style = Floe.typography.metadata,
        color = if (error) Floe.colors.destructive else Floe.colors.secondaryLabel,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
        maxLines = 3,
        overflow = TextOverflow.Ellipsis,
    )
}

@Composable
private fun SheetActionRow(
    applyEnabled: Boolean,
    busy: Boolean,
    onApply: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        FloeText(
            stringResource(
                if (busy) R.string.device_access_system_settings_applying
                else R.string.device_access_system_settings_apply_hint,
            ),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.weight(1f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        FloeCapsuleButton(
            stringResource(R.string.device_access_system_settings_apply),
            onClick = onApply,
            enabled = applyEnabled,
            modifier = Modifier.widthIn(min = 72.dp, max = 120.dp),
        )
    }
}

@Composable
private fun SettingRow(
    entry: DeviceAccessSystemSettingUi,
    enabled: Boolean,
    draft: String,
    onDraft: (String) -> Unit,
    onRestore: () -> Unit,
) {
    val label = settingLabelRes(entry.namespace, entry.key)
    val scope = if (entry.deviceWide) {
        stringResource(R.string.device_access_system_settings_device_wide)
    } else {
        stringResource(R.string.device_access_system_settings_current_user)
    }
    androidx.compose.foundation.layout.Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Column(Modifier.weight(1f)) {
            FloeText(
                stringResource(label),
                style = Floe.typography.body,
                color = Floe.colors.label,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            FloeText(
                scope,
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        when {
            entry.kind == DeviceAccessSystemSettingKindUi.INT &&
                entry.minInclusive == 0L && entry.maxInclusive == 1L -> {
                FloeInlineSwitch(
                    checked = draft == "1",
                    onCheckedChange = { onDraft(if (it) "1" else "0") },
                    description = stringResource(label),
                    enabled = enabled,
                )
            }
            else -> Stepper(
                valueText = draft.ifEmpty { "-" },
                onStepDown = { onDraft(stepValue(entry, draft, down = true)) },
                onStepUp = { onDraft(stepValue(entry, draft, down = false)) },
                enabled = enabled,
            )
        }
        FloeCapsuleButton(
            stringResource(R.string.device_access_system_settings_restore),
            onClick = onRestore,
            enabled = enabled,
            modifier = Modifier.widthIn(min = 64.dp, max = 96.dp),
        )
    }
}

@Composable
private fun Stepper(
    valueText: String,
    onStepDown: () -> Unit,
    onStepUp: () -> Unit,
    enabled: Boolean,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        FloeCapsuleButton("−", onClick = onStepDown, enabled = enabled,
            modifier = Modifier.widthIn(min = 40.dp, max = 48.dp))
        FloeText(
            valueText,
            style = Floe.typography.body,
            color = Floe.colors.label,
            modifier = Modifier.widthIn(min = 44.dp),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        FloeCapsuleButton("+", onClick = onStepUp, enabled = enabled,
            modifier = Modifier.widthIn(min = 40.dp, max = 48.dp))
    }
}

/** Step one increment, clamped to the closed range; empty draft starts at min. */
internal fun stepValue(
    entry: DeviceAccessSystemSettingUi,
    draft: String,
    down: Boolean,
): String {
    val step = when {
        entry.kind == DeviceAccessSystemSettingKindUi.SCALE -> 0.5
        entry.maxInclusive <= 3 -> 1.0
        entry.maxInclusive <= 255 -> 16.0
        else -> 5_000.0
    }
    val current = draft.toDoubleOrNull()?.takeIf { it.isFinite() } ?: 0.0
    val next = (if (down) current - step else current + step)
        .coerceIn(entry.minInclusive.toDouble(), entry.maxInclusive.toDouble())
    return if (entry.kind == DeviceAccessSystemSettingKindUi.INT) {
        next.toLong().toString()
    } else {
        val rounded = (next * 2).toLong() / 2.0
        if (rounded % 1.0 == 0.0) rounded.toLong().toString() else rounded.toString()
    }
}

/** Bilingual labels live in resources; unknown keys fall back to the key. */
internal fun settingLabelRes(namespace: String, key: String): Int = when (namespace + "/" + key) {
    "system/screen_brightness" -> R.string.device_access_system_settings_brightness
    "system/screen_brightness_mode" -> R.string.device_access_system_settings_brightness_mode
    "system/accelerometer_rotation" -> R.string.device_access_system_settings_accelerometer_rotation
    "system/user_rotation" -> R.string.device_access_system_settings_user_rotation
    "system/screen_off_timeout" -> R.string.device_access_system_settings_screen_off_timeout
    "system/sound_effects_enabled" -> R.string.device_access_system_settings_sound_effects
    "system/haptic_feedback_enabled" -> R.string.device_access_system_settings_haptic_feedback
    "global/window_animation_scale" -> R.string.device_access_system_settings_window_animation
    "global/transition_animation_scale" -> R.string.device_access_system_settings_transition_animation
    "global/animator_duration_scale" -> R.string.device_access_system_settings_animator_duration
    else -> R.string.device_access_system_settings_unknown
}
