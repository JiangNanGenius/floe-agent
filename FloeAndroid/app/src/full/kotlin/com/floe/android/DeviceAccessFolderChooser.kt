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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
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

/**
 * Compact folder-target chooser opened as a child sheet from the device-access
 * settings page. The page shows only a count row per folder class (shared /
 * system inspection trees); the per-folder switches live here so the Phone
 * overview no longer carries six permanent switch rows per class.
 *
 * Presentation only: every toggle forwards the full next selection set through
 * [onSelectionChange]; the host keeps enforcing the durable ceilings. Batch
 * Select All / Clear operate on THIS sheet's class only and never drop
 * selections from the other class (a system-folder Clear never revokes a
 * shared-folder grant and vice versa). App-data folders are deliberately not
 * listed here; they stay explicit one-at-a-time Root grants on the page.
 */
@Composable
internal fun DeviceAccessFolderChooserSheet(
    visible: Boolean,
    titleRes: Int,
    roots: List<DeviceAccessFileRootUi>,
    selectedIds: Set<String>,
    hintRes: Int,
    emptyRes: Int,
    /** Shared folders offer batch grant/clear; read-only system trees stay
     *  per-folder (parity with the old permanent rows, which had no batch). */
    batch: Boolean,
    enabled: Boolean,
    onSelectionChange: (Set<String>) -> Unit,
    onDismiss: () -> Unit,
) {
    if (!visible) return
    val config = LocalConfiguration.current
    val compact = FloeLayout.usesCompactNavigation(
        config.screenWidthDp.toFloat(), config.smallestScreenWidthDp.toFloat(),
    )
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
                        stringResource(titleRes),
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
                FloeText(
                    stringResource(hintRes),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                )
                if (batch) {
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        FloeText(
                            stringResource(
                                R.string.device_access_folders_selected_count,
                                roots.count { it.id in selectedIds },
                                roots.size,
                            ),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                            modifier = Modifier.weight(1f),
                        )
                        // Class-scoped batch: union/intersect with THIS sheet's
                        // root ids only, so the other class's selection is kept.
                        FloeCapsuleButton(
                            stringResource(R.string.device_access_select_all),
                            onClick = {
                                onSelectionChange(selectedIds + roots.map { it.id }.toSet())
                            },
                            enabled = enabled,
                            modifier = Modifier.widthIn(min = 56.dp, max = 96.dp),
                        )
                        FloeCapsuleButton(
                            stringResource(R.string.device_access_clear),
                            onClick = { onSelectionChange(selectedIds - roots.map { it.id }.toSet()) },
                            enabled = enabled,
                            modifier = Modifier.widthIn(min = 56.dp, max = 96.dp),
                        )
                    }
                }
                LazyColumn(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 16.dp)) {
                    if (roots.isEmpty()) {
                        item {
                            FloeText(
                                stringResource(emptyRes),
                                style = Floe.typography.body,
                                color = Floe.colors.secondaryLabel,
                                modifier = Modifier.padding(vertical = 16.dp),
                            )
                        }
                    }
                    items(roots, key = { it.id }) { root ->
                        val checked = root.id in selectedIds
                        val title = if (root.label.isNotEmpty()) root.label
                            else stringResource(root.labelRes)
                        Row(
                            Modifier.fillMaxWidth().background(Floe.colors.sectionCardSurface)
                                .heightIn(min = 52.dp)
                                .toggleable(
                                    checked,
                                    enabled = enabled,
                                    role = Role.Switch,
                                    onValueChange = { turnOn ->
                                        val next = selectedIds.toMutableSet()
                                        if (turnOn) next += root.id else next -= root.id
                                        onSelectionChange(next)
                                    },
                                )
                                .padding(horizontal = 12.dp, vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            FloeText(
                                title,
                                style = Floe.typography.body,
                                modifier = Modifier.weight(1f),
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                            )
                            FloeInlineSwitch(
                                checked,
                                { turnOn ->
                                    val next = selectedIds.toMutableSet()
                                    if (turnOn) next += root.id else next -= root.id
                                    onSelectionChange(next)
                                },
                                title,
                                enabled = enabled,
                                modifier = Modifier.clearAndSetSemantics { },
                            )
                        }
                        FloeDivider()
                    }
                }
            }
        }
    }
}
