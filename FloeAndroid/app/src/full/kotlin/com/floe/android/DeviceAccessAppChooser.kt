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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
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
import com.floe.android.design.FloeSearchField
import com.floe.android.design.FloeSettingsContentDensity
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeText

/** Phone-control target chooser; see [DeviceAccessAppChooserSheet]. */
@Composable
internal fun DeviceAccessAppChooser(
    visible: Boolean,
    targets: DeviceAccessTargetsUi,
    enabled: Boolean,
    onSelectionChange: (Set<String>) -> Unit,
    onDismiss: () -> Unit,
) = DeviceAccessAppChooserSheet(
    visible = visible,
    packages = targets.packages,
    selected = targets.selectedPackages,
    titleRes = R.string.device_access_targets_section,
    enabled = enabled,
    onSelectionChange = onSelectionChange,
    onDismiss = onDismiss,
)

/**
 * A separate scroll owner; filtering never replaces the full authorized
 * selection. The packages/selected inputs make the same compact multi-select
 * reusable for the advanced-system target ceiling.
 */
@Composable
internal fun DeviceAccessAppChooserSheet(
    visible: Boolean,
    packages: List<DeviceAccessPackageUi>,
    selected: Set<String>,
    titleRes: Int,
    enabled: Boolean,
    onSelectionChange: (Set<String>) -> Unit,
    onDismiss: () -> Unit,
    showIdentifiers: Boolean = true,
    searchable: Boolean = true,
    countLabelRes: Int = R.string.device_access_targets_count,
    heightFractionOverride: Float? = null,
    maxSelections: Int = 64,
) {
    if (!visible) return
    var query by remember { mutableStateOf("") }
    val config = LocalConfiguration.current
    val compact = FloeLayout.usesCompactNavigation(
        config.screenWidthDp.toFloat(), config.smallestScreenWidthDp.toFloat())
    val matches = remember(query, packages, selected) {
        packages.filter {
            query.isBlank() || it.label.contains(query.trim(), ignoreCase = true) ||
                it.packageName.contains(query.trim(), ignoreCase = true)
        }.sortedWith(compareByDescending<DeviceAccessPackageUi> {
            it.packageName in selected
        }.thenBy { it.label.lowercase() })
    }
    FloeSettingsContentDensity(compact) {
        FloePageSheet(
            visible = true,
            onDismiss = onDismiss,
            topInset = if (compact) 16.dp else 0.dp,
            widthFraction = if (compact) 1f else 0.62f,
            heightFraction = heightFractionOverride ?: if (compact) 1f else 0.82f,
            placement = if (compact) FloeSheetPlacement.BOTTOM else FloeSheetPlacement.CENTER,
        ) {
            Column(Modifier.fillMaxSize().background(Floe.colors.groupedSurface)) {
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    FloeText(stringResource(titleRes),
                        style = Floe.typography.section, modifier = Modifier.weight(1f),
                        maxLines = 2, overflow = TextOverflow.Ellipsis)
                    FloeCapsuleButton(stringResource(R.string.done), onClick = onDismiss,
                        modifier = Modifier.widthIn(min = 64.dp, max = 96.dp))
                }
                FloeDivider()
                if (searchable) {
                    FloeSearchField(query, { query = it },
                        stringResource(R.string.device_access_targets_search),
                        Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
                }
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    FloeText(
                        stringResource(
                            countLabelRes,
                            selected.size,
                        ),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        modifier = Modifier.weight(1f),
                    )
                    // Preserve selected identities and show the bound before
                    // a batch choice; never silently drop a later selection.
                    FloeCapsuleButton(
                        stringResource(if (packages.size > maxSelections)
                            R.string.device_access_select_to_limit else R.string.device_access_select_all),
                        onClick = {
                            onSelectionChange(
                                (selected + packages.map { it.packageName }).take(maxSelections).toSet(),
                            )
                        },
                        enabled = enabled,
                        modifier = Modifier.widthIn(min = 56.dp, max = 96.dp),
                    )
                    FloeCapsuleButton(
                        stringResource(R.string.device_access_clear),
                        onClick = { onSelectionChange(emptySet()) },
                        enabled = enabled,
                        modifier = Modifier.widthIn(min = 56.dp, max = 96.dp),
                    )
                }
                if (packages.size > maxSelections) {
                    FloeText(
                        stringResource(R.string.device_access_selection_limit, selected.size, maxSelections),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                    )
                }
                LazyColumn(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 16.dp)) {
                    if (matches.isEmpty()) {
                        item {
                            FloeText(stringResource(if (packages.isEmpty())
                                R.string.device_access_targets_empty else R.string.device_access_targets_no_matches),
                                style = Floe.typography.body, color = Floe.colors.secondaryLabel,
                                modifier = Modifier.padding(vertical = 16.dp))
                        }
                    }
                    items(matches, key = { it.packageName }) { app ->
                        val checked = app.packageName in selected
                        val rowEnabled = enabled && (checked || selected.size < maxSelections)
                        val toggle: (Boolean) -> Unit = { turnOn ->
                            // Start from ALL selected apps, including those hidden by the query.
                            val next = selected.toMutableSet()
                            if (turnOn && next.size < maxSelections) next += app.packageName
                            else if (!turnOn) next -= app.packageName
                            onSelectionChange(next)
                        }
                        Row(
                            Modifier.fillMaxWidth().background(Floe.colors.sectionCardSurface)
                                .heightIn(min = 56.dp)
                                .toggleable(checked, enabled = rowEnabled, role = Role.Switch, onValueChange = toggle)
                                .padding(horizontal = 12.dp, vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Column(Modifier.weight(1f)) {
                                FloeText(app.label, style = Floe.typography.body, maxLines = 1,
                                    overflow = TextOverflow.Ellipsis)
                                if (showIdentifiers) {
                                    FloeText(app.packageName, style = Floe.typography.metadata,
                                        color = Floe.colors.secondaryLabel, maxLines = 1,
                                        overflow = TextOverflow.Ellipsis)
                                }
                            }
                            FloeInlineSwitch(checked, toggle, app.label, enabled = rowEnabled,
                                modifier = Modifier.clearAndSetSemantics { })
                        }
                        FloeDivider()
                    }
                }
            }
        }
    }
}
