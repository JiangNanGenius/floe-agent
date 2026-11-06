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

/** A separate scroll owner; filtering never replaces the full authorized selection. */
@Composable
internal fun DeviceAccessAppChooser(
    visible: Boolean,
    targets: DeviceAccessTargetsUi,
    enabled: Boolean,
    onSelectionChange: (Set<String>) -> Unit,
    onDismiss: () -> Unit,
) {
    if (!visible) return
    var query by remember { mutableStateOf("") }
    val config = LocalConfiguration.current
    val compact = FloeLayout.usesCompactNavigation(
        config.screenWidthDp.toFloat(), config.smallestScreenWidthDp.toFloat())
    val matches = remember(query, targets.packages, targets.selectedPackages) {
        targets.packages.filter {
            query.isBlank() || it.label.contains(query.trim(), ignoreCase = true) ||
                it.packageName.contains(query.trim(), ignoreCase = true)
        }.sortedWith(compareByDescending<DeviceAccessPackageUi> {
            it.packageName in targets.selectedPackages
        }.thenBy { it.label.lowercase() })
    }
    FloeSettingsContentDensity(compact) {
        FloePageSheet(
            visible = true,
            onDismiss = onDismiss,
            topInset = if (compact) 16.dp else 0.dp,
            widthFraction = if (compact) 1f else 0.62f,
            heightFraction = if (compact) 1f else 0.82f,
            placement = if (compact) FloeSheetPlacement.BOTTOM else FloeSheetPlacement.CENTER,
        ) {
            Column(Modifier.fillMaxSize().background(Floe.colors.groupedSurface)) {
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    FloeText(stringResource(R.string.device_access_targets_section),
                        style = Floe.typography.section, modifier = Modifier.weight(1f),
                        maxLines = 2, overflow = TextOverflow.Ellipsis)
                    FloeCapsuleButton(stringResource(R.string.done), onClick = onDismiss)
                }
                FloeDivider()
                FloeSearchField(query, { query = it },
                    stringResource(R.string.device_access_targets_search),
                    Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
                FloeText(stringResource(R.string.device_access_targets_count, targets.selectedPackages.size),
                    style = Floe.typography.metadata, color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
                LazyColumn(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 16.dp)) {
                    if (matches.isEmpty()) {
                        item {
                            FloeText(stringResource(if (targets.packages.isEmpty())
                                R.string.device_access_targets_empty else R.string.device_access_targets_no_matches),
                                style = Floe.typography.body, color = Floe.colors.secondaryLabel,
                                modifier = Modifier.padding(vertical = 16.dp))
                        }
                    }
                    items(matches, key = { it.packageName }) { app ->
                        val checked = app.packageName in targets.selectedPackages
                        val toggle: (Boolean) -> Unit = { selected ->
                            // Start from ALL selected apps, including those hidden by the query.
                            val next = targets.selectedPackages.toMutableSet()
                            if (selected) next += app.packageName else next -= app.packageName
                            onSelectionChange(next)
                        }
                        Row(
                            Modifier.fillMaxWidth().background(Floe.colors.sectionCardSurface)
                                .heightIn(min = 56.dp)
                                .toggleable(checked, enabled = enabled, role = Role.Switch, onValueChange = toggle)
                                .padding(horizontal = 12.dp, vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Column(Modifier.weight(1f)) {
                                FloeText(app.label, style = Floe.typography.body, maxLines = 1,
                                    overflow = TextOverflow.Ellipsis)
                                FloeText(app.packageName, style = Floe.typography.metadata,
                                    color = Floe.colors.secondaryLabel, maxLines = 1,
                                    overflow = TextOverflow.Ellipsis)
                            }
                            FloeInlineSwitch(checked, toggle, app.label, enabled = enabled,
                                modifier = Modifier.clearAndSetSemantics { })
                        }
                        FloeDivider()
                    }
                }
            }
        }
    }
}
