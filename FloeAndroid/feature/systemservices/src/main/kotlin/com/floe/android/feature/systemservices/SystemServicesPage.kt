// SPDX-License-Identifier: MPL-2.0
//
// C06 System Services screen. Presentation only: permission dialogs, the
// platform lane and the Swift bridge are owned by the App host controller.

package com.floe.android.feature.systemservices

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeSectionHeader
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbar
import com.floe.android.design.FloeUnavailableView
import com.floe.android.design.IconGlyph

@Composable
fun SystemServicesDestinationUi(
    state: SystemServicesUiState,
    compact: Boolean,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    onRefresh: () -> Unit,
    onRequestPermission: (CapabilityKind) -> Unit,
    onGrantHealth: () -> Unit,
    onOpenSettings: (CapabilityKind) -> Unit,
    onInstallHealth: () -> Unit,
    onUpdateHealth: () -> Unit,
    onDismissNotice: () -> Unit,
) {
    Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeToolbar(
            title = stringResource(R.string.system_services_title),
            navigation = {
                if (compact || showSidebarToggle) {
                    FloeCircleButton(
                        icon = FloeIcons.SidebarToggle,
                        contentDescription = stringResource(R.string.system_services_open_sidebar),
                        onClick = if (compact) onOpenDrawer else onExpandSidebar,
                    )
                }
            },
            actions = {
                FloeCircleButton(
                    icon = FloeIcons.Refresh,
                    contentDescription = stringResource(R.string.system_services_refresh),
                    onClick = onRefresh,
                )
            },
            showHairline = true,
        )

        if (state.loading || !state.coreReady) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                if (state.loading) {
                    FloeActivityIndicator()
                } else {
                    FloeUnavailableView(
                        icon = FloeIcons.Gearshape,
                        title = stringResource(R.string.system_services_title),
                        description = stringResource(R.string.system_services_unavailable),
                    )
                }
            }
            return@Column
        }

        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            item {
                FloeText(
                    stringResource(R.string.system_services_intro),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(top = 12.dp, bottom = 2.dp),
                )
            }
            state.notice?.let { notice ->
                item { NoticeBanner(notice, onDismissNotice) }
            }
            item {
                CapabilityCard(
                    capability = state.location,
                    title = stringResource(R.string.system_services_location),
                    description = stringResource(R.string.system_services_location_detail),
                    icon = FloeIcons.Compass,
                    extra = state.location.precise?.let {
                        stringResource(
                            if (it) R.string.system_services_location_precise
                            else R.string.system_services_location_approximate,
                        )
                    },
                    onRequestPermission = { onRequestPermission(CapabilityKind.LOCATION) },
                    onOpenSettings = { onOpenSettings(CapabilityKind.LOCATION) },
                )
            }
            item {
                CapabilityCard(
                    capability = state.contacts,
                    title = stringResource(R.string.system_services_contacts),
                    description = stringResource(R.string.system_services_contacts_detail),
                    icon = FloeIcons.PersonCircleCheck,
                    extra = null,
                    onRequestPermission = { onRequestPermission(CapabilityKind.CONTACTS) },
                    onOpenSettings = { onOpenSettings(CapabilityKind.CONTACTS) },
                )
            }
            item {
                CapabilityCard(
                    capability = state.nfc,
                    title = stringResource(R.string.system_services_nfc),
                    description = stringResource(R.string.system_services_nfc_detail),
                    icon = FloeIcons.Antenna,
                    extra = if (state.nfc.state == CapabilityState.DISABLED) {
                        stringResource(R.string.system_services_nfc_disabled)
                    } else {
                        null
                    },
                    onRequestPermission = null,
                    onOpenSettings = { onOpenSettings(CapabilityKind.NFC) },
                )
            }
            item {
                CapabilityCard(
                    capability = state.health,
                    title = stringResource(R.string.system_services_health),
                    description = stringResource(R.string.system_services_health_detail),
                    icon = FloeIcons.Stethoscope,
                    extra = if (state.health.grantedMetricCount > 0) {
                        stringResource(
                            R.string.system_services_health_granted,
                            state.health.grantedMetricCount,
                        )
                    } else {
                        stringResource(R.string.system_services_health_none)
                    },
                    onRequestPermission = null,
                    onOpenSettings = { onOpenSettings(CapabilityKind.HEALTH) },
                    onGrantHealth = onGrantHealth,
                    onInstallHealth = onInstallHealth,
                    onUpdateHealth = onUpdateHealth,
                )
            }
            if (state.healthMetrics.isNotEmpty()) {
                item {
                    FloeSectionHeader(stringResource(R.string.system_services_health_metrics))
                }
                items(state.healthMetrics, key = { it.wire }) { metric ->
                    HealthMetricRow(metric)
                }
            }
            item {
                DiagnosticsCard(state.diagnostics)
            }
            item { Spacer(Modifier.size(20.dp)) }
        }
    }
}

@Composable
private fun CapabilityCard(
    capability: CapabilityUi,
    title: String,
    description: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    extra: String?,
    onRequestPermission: (() -> Unit)?,
    onOpenSettings: () -> Unit,
    onGrantHealth: (() -> Unit)? = null,
    onInstallHealth: (() -> Unit)? = null,
    onUpdateHealth: (() -> Unit)? = null,
) {
    Column(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Floe.colors.sectionCardSurface)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconGlyph(icon, Floe.colors.accent, 22.dp)
            Spacer(Modifier.width(10.dp))
            FloeText(title, style = Floe.typography.body)
            Spacer(Modifier.weight(1f))
            FloeBadgePill(
                text = statusLabel(capability.state),
                tone = statusTone(capability.state),
            )
        }
        FloeText(
            description,
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        extra?.let {
            FloeText(it, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        }
        val healthAction: (@Composable () -> Unit)? = when {
            onGrantHealth != null && capability.state == CapabilityState.NEEDS_PERMISSION -> {
                { FloeCapsuleAction(stringResource(R.string.system_services_health_grant), onGrantHealth) }
            }
            onInstallHealth != null && capability.state == CapabilityState.NOT_INSTALLED -> {
                { FloeCapsuleAction(stringResource(R.string.system_services_health_install), onInstallHealth) }
            }
            onUpdateHealth != null && capability.state == CapabilityState.UPDATE_REQUIRED -> {
                { FloeCapsuleAction(stringResource(R.string.system_services_health_update), onUpdateHealth) }
            }
            else -> null
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            when (capability.state) {
                CapabilityState.NEEDS_PERMISSION -> if (onRequestPermission != null) {
                    FloeCapsuleAction(
                        stringResource(R.string.system_services_allow),
                        onRequestPermission,
                    )
                } else {
                    healthAction?.invoke()
                }
                CapabilityState.DENIED, CapabilityState.RESTRICTED, CapabilityState.DISABLED,
                CapabilityState.UPDATE_REQUIRED, CapabilityState.NOT_INSTALLED ->
                    healthAction?.invoke()
                else -> Unit
            }
            if (capability.canOpenSettings &&
                capability.state != CapabilityState.NOT_INSTALLED &&
                capability.state != CapabilityState.UPDATE_REQUIRED
            ) {
                FloeCapsuleAction(
                    stringResource(R.string.system_services_open_settings),
                    onOpenSettings,
                )
            }
        }
        if (capability.state == CapabilityState.READY ||
            capability.state == CapabilityState.NEEDS_PERMISSION
        ) {
            FloeText(
                stringResource(R.string.system_services_foreground),
                style = Floe.typography.metadata,
                color = Floe.colors.tertiaryLabel,
            )
        }
    }
}

@Composable
private fun HealthMetricRow(metric: HealthMetricUi) {
    Row(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(Floe.colors.sectionCardSurface)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloeText(
            healthMetricLabel(metric.wire),
            style = Floe.typography.body,
            modifier = Modifier.weight(1f),
        )
        FloeBadgePill(
            text = stringResource(
                if (metric.granted) R.string.system_services_metric_allowed
                else R.string.system_services_metric_not_allowed,
            ),
            tone = if (metric.granted) FloeBadgeTone.SUCCESS else FloeBadgeTone.SECONDARY,
        )
    }
}

@Composable
private fun DiagnosticsCard(rows: List<DiagnosticRowUi>) {
    var expanded by remember { mutableStateOf(false) }
    Column(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Floe.colors.sectionCardSurface)
            .clickable { expanded = !expanded }
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            FloeText(
                stringResource(R.string.system_services_diagnostics),
                style = Floe.typography.body,
                modifier = Modifier.weight(1f),
            )
            FloeText(
                stringResource(
                    if (expanded) R.string.system_services_hide_details
                    else R.string.system_services_show_details,
                ),
                style = Floe.typography.metadata,
                color = Floe.colors.accent,
            )
        }
        FloeText(
            stringResource(R.string.system_services_diagnostics_hint),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        if (expanded) {
            FloeDivider()
            rows.forEach { row ->
                Row(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
                    FloeText(
                        row.key,
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        modifier = Modifier.width(150.dp),
                    )
                    FloeText(
                        row.value,
                        style = Floe.typography.metadata,
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        }
    }
}

@Composable
private fun NoticeBanner(notice: String, onDismiss: () -> Unit) {
    val text = when (notice) {
        SystemServicesNotice.GRANT_FAILED -> stringResource(R.string.system_services_notice_grant_failed)
        SystemServicesNotice.REFRESH_FAILED -> stringResource(R.string.system_services_notice_refresh_failed)
        SystemServicesNotice.SETTINGS_UNAVAILABLE -> stringResource(R.string.system_services_notice_settings_unavailable)
        SystemServicesNotice.HEALTH_NOT_INSTALLED -> stringResource(R.string.system_services_notice_health_missing)
        SystemServicesNotice.NFC_DISABLED -> stringResource(R.string.system_services_notice_nfc_disabled)
        SystemServicesNotice.PERMISSION_DENIED -> stringResource(R.string.system_services_notice_permission_denied)
        SystemServicesNotice.BUSY -> stringResource(R.string.system_services_notice_busy)
        else -> return
    }
    Row(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(Floe.colors.sectionCardSurface)
            .padding(start = 14.dp, end = 6.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloeText(
            text,
            style = Floe.typography.metadata,
            modifier = Modifier.weight(1f),
        )
        TextButton(onClick = onDismiss) {
            FloeText(stringResource(R.string.system_services_dismiss), color = Floe.colors.accent)
        }
    }
}

@Composable
private fun statusLabel(state: CapabilityState): String = stringResource(
    when (state) {
        CapabilityState.READY -> R.string.system_services_status_ready
        CapabilityState.NEEDS_PERMISSION -> R.string.system_services_status_needs_permission
        CapabilityState.DENIED -> R.string.system_services_status_denied
        CapabilityState.RESTRICTED -> R.string.system_services_status_restricted
        CapabilityState.DISABLED -> R.string.system_services_status_disabled
        CapabilityState.UPDATE_REQUIRED -> R.string.system_services_status_update
        CapabilityState.NOT_INSTALLED -> R.string.system_services_status_not_installed
        CapabilityState.UNSUPPORTED -> R.string.system_services_status_unsupported
    },
)

private fun statusTone(state: CapabilityState): FloeBadgeTone = when (state) {
    CapabilityState.READY -> FloeBadgeTone.SUCCESS
    CapabilityState.NEEDS_PERMISSION, CapabilityState.UPDATE_REQUIRED -> FloeBadgeTone.PENDING
    CapabilityState.DENIED, CapabilityState.RESTRICTED -> FloeBadgeTone.DESTRUCTIVE
    else -> FloeBadgeTone.SECONDARY
}

@Composable
private fun healthMetricLabel(wire: String): String = stringResource(
    when (wire) {
        "steps" -> R.string.system_services_metric_steps
        "activeEnergy" -> R.string.system_services_metric_active_energy
        "heartRate" -> R.string.system_services_metric_heart_rate
        "restingHeartRate" -> R.string.system_services_metric_resting_heart_rate
        "sleep" -> R.string.system_services_metric_sleep
        "workouts" -> R.string.system_services_metric_workouts
        "bodyMass" -> R.string.system_services_metric_body_mass
        "oxygenSaturation" -> R.string.system_services_metric_oxygen
        "heartRateVariability" -> R.string.system_services_metric_hrv
        else -> R.string.system_services_metric_steps
    },
)
