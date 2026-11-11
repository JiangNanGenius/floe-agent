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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
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
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloeSettingsContentDensity
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeText
import kotlinx.coroutines.launch

/**
 * Result of one user-initiated permission/AppOps read or change. [lines] is
 * a bounded, human-readable rendering produced by the host from the real
 * per-item receipts; [code] is a bounded failure token for the details area.
 */
sealed interface DeviceAccessPermissionOpsResult {
    data class Ok(val lines: String) : DeviceAccessPermissionOpsResult
    data class Failed(val code: String) : DeviceAccessPermissionOpsResult
}

/**
 * Settings-sheet inspector implemented by the Full host. Every call is one
 * user-initiated action that re-checks the CURRENT durable ceilings; it is
 * never a model path and mints no approval grants.
 */
interface DeviceAccessPermissionOpsInspector {
    suspend fun permissions(packageName: String): DeviceAccessPermissionOpsResult

    suspend fun appOps(packageName: String): DeviceAccessPermissionOpsResult

    suspend fun setPermission(
        packageName: String,
        permission: String,
        grant: Boolean,
    ): DeviceAccessPermissionOpsResult

    /**
     * Set one AppOps mode. [scope] is the closed write scope ("package"
     * legacy default, or "uid" for a uniquely owned UID when the user
     * enabled the UID-scope switch and the live peer supports it).
     */
    suspend fun setAppOp(
        packageName: String,
        operation: String,
        mode: String,
        scope: String,
    ): DeviceAccessPermissionOpsResult
}

/** Closed AppOps mode vocabulary (mirrors the frozen tool contract). */
val DEVICE_ACCESS_APPOPS_MODES = listOf("allow", "ignore", "deny", "default", "foreground")

/** Closed AppOps write-scope vocabulary (package = legacy default). */
const val DEVICE_ACCESS_APPOPS_SCOPE_PACKAGE = "package"
const val DEVICE_ACCESS_APPOPS_SCOPE_UID = "uid"

/**
 * Compact modal for inspecting and managing the SELECTED target apps' real
 * permission and AppOps state. Presentation only: all reads and changes go
 * through [DeviceAccessPermissionOpsInspector]; nothing here invents state.
 * Diagnostics stay in the status line, not in the row copy.
 */
@Composable
internal fun DeviceAccessPermissionOpsSheet(
    visible: Boolean,
    targets: List<DeviceAccessPackageUi>,
    enabled: Boolean,
    inspector: DeviceAccessPermissionOpsInspector?,
    /**
     * True when the user allowed the AppOps UID write scope and the LIVE
     * peer advertises it; then the detail shows the App/UID scope choice.
     */
    uidScopeAvailable: Boolean = false,
    onDismiss: () -> Unit,
) {
    if (!visible) return
    val config = LocalConfiguration.current
    val compact = FloeLayout.usesCompactNavigation(
        config.screenWidthDp.toFloat(),
        config.smallestScreenWidthDp.toFloat(),
    )
    val scope = rememberCoroutineScope()
    var selectedPackage by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<DeviceAccessPermissionOpsResult?>(null) }
    var permissionsText by remember { mutableStateOf<String?>(null) }
    var appOpsRows by remember { mutableStateOf<List<AppOpsRowUi>>(emptyList()) }
    // AppOps write scope for the user-initiated set actions: "package" is
    // the legacy default; "uid" writes the UID-level mode and is offered
    // only when uidScopeAvailable (durable switch + live capability).
    var appOpsScope by remember { mutableStateOf(DEVICE_ACCESS_APPOPS_SCOPE_PACKAGE) }

    fun reload(packageName: String) {
        val active = inspector ?: return
        scope.launch {
            busy = true
            status = null
            val permissions = active.permissions(packageName)
            val ops = active.appOps(packageName)
            permissionsText = (permissions as? DeviceAccessPermissionOpsResult.Ok)?.lines
            appOpsRows = parseAppOpsRows((ops as? DeviceAccessPermissionOpsResult.Ok)?.lines)
            status = when {
                permissions is DeviceAccessPermissionOpsResult.Failed -> permissions
                ops is DeviceAccessPermissionOpsResult.Failed -> ops
                else -> null
            }
            busy = false
        }
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
                    FloeText(
                        stringResource(R.string.device_access_permission_ops_title),
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
                    stringResource(R.string.device_access_permission_ops_hint),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                )
                if (targets.isEmpty()) {
                    Column(
                        Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                            .padding(horizontal = 16.dp),
                    ) {
                        FloeText(
                            stringResource(R.string.device_access_permission_ops_empty),
                            style = Floe.typography.body,
                            color = Floe.colors.secondaryLabel,
                            modifier = Modifier.padding(vertical = 16.dp),
                        )
                    }
                    return@FloePageSheet
                }
                LazyColumn(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 16.dp)) {
                    items(targets.size) { index ->
                        val app = targets[index]
                        val open = app.packageName == selectedPackage
                        Column(
                            Modifier.fillMaxWidth().background(Floe.colors.sectionCardSurface)
                                .padding(horizontal = 12.dp, vertical = 6.dp),
                        ) {
                            Row(
                                Modifier.fillMaxWidth().heightIn(min = 44.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Column(Modifier.weight(1f)) {
                                    FloeText(app.label, style = Floe.typography.body, maxLines = 1,
                                        overflow = TextOverflow.Ellipsis)
                                    FloeText(app.packageName,
                                        style = Floe.typography.metadata,
                                        color = Floe.colors.secondaryLabel, maxLines = 1,
                                        overflow = TextOverflow.Ellipsis)
                                }
                                FloeCapsuleButton(
                                    stringResource(
                                        if (open) R.string.device_access_permission_ops_collapse
                                        else R.string.device_access_permission_ops_inspect,
                                    ),
                                    onClick = {
                                        if (open) {
                                            selectedPackage = null
                                            permissionsText = null
                                            appOpsRows = emptyList()
                                            status = null
                                            appOpsScope = DEVICE_ACCESS_APPOPS_SCOPE_PACKAGE
                                        } else {
                                            selectedPackage = app.packageName
                                            reload(app.packageName)
                                        }
                                    },
                                    enabled = enabled && !busy && inspector != null,
                                    modifier = Modifier.widthIn(min = 64.dp, max = 108.dp),
                                )
                            }
                            if (open) {
                                PermissionOpsDetail(
                                    busy = busy,
                                    permissionsText = permissionsText,
                                    appOpsRows = appOpsRows,
                                    status = status,
                                    uidScopeAvailable = uidScopeAvailable,
                                    appOpsScope = appOpsScope,
                                    onAppOpsScopeChange = { appOpsScope = it },
                                    enabled = enabled && !busy && inspector != null,
                                    onRefresh = { reload(app.packageName) },
                                    onSetPermission = { permission, grant ->
                                        val active = inspector ?: return@PermissionOpsDetail
                                        scope.launch {
                                            busy = true
                                            status = active.setPermission(app.packageName, permission, grant)
                                            busy = false
                                            reload(app.packageName)
                                        }
                                    },
                                    onSetAppOp = { operation, mode ->
                                        val active = inspector ?: return@PermissionOpsDetail
                                        scope.launch {
                                            busy = true
                                            status = active.setAppOp(
                                                app.packageName, operation, mode, appOpsScope,
                                            )
                                            busy = false
                                            reload(app.packageName)
                                        }
                                    },
                                )
                            }
                        }
                        FloeDivider()
                    }
                }
            }
        }
    }
}

internal data class AppOpsRowUi(
    val operation: String,
    val effective: String,
    val overrideMode: String?,
    val uidMode: String?,
    val defaultMode: String?,
)

/**
 * Host-rendered query lines are "token|effective[|override=..][|uid=..]
 * [|default=..]" per operation; keep the split tolerant and bounded so a
 * changed host rendering degrades to an empty list instead of a crash.
 */
internal fun parseAppOpsRows(lines: String?): List<AppOpsRowUi> {
    if (lines.isNullOrBlank()) return emptyList()
    return lines.lineSequence().map { it.trim() }.filter { it.isNotEmpty() }.mapNotNull { line ->
        val parts = line.split('|')
        if (parts.size < 2) return@mapNotNull null
        var overrideMode: String? = null
        var uidMode: String? = null
        var defaultMode: String? = null
        for (extra in parts.drop(2)) {
            when {
                extra.startsWith("override=") -> overrideMode = extra.substringAfter('=').take(16)
                extra.startsWith("uid=") -> uidMode = extra.substringAfter('=').take(16)
                extra.startsWith("default=") -> defaultMode = extra.substringAfter('=').take(16)
            }
        }
        AppOpsRowUi(
            operation = parts[0].take(32),
            effective = parts[1].take(16),
            overrideMode = overrideMode,
            uidMode = uidMode,
            defaultMode = defaultMode,
        )
    }.toList()
}

@Composable
private fun PermissionOpsDetail(
    busy: Boolean,
    permissionsText: String?,
    appOpsRows: List<AppOpsRowUi>,
    status: DeviceAccessPermissionOpsResult?,
    uidScopeAvailable: Boolean,
    appOpsScope: String,
    onAppOpsScopeChange: (String) -> Unit,
    enabled: Boolean,
    onRefresh: () -> Unit,
    onSetPermission: (String, Boolean) -> Unit,
    onSetAppOp: (String, String) -> Unit,
) {
    Column(
        Modifier.fillMaxWidth().padding(vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FloeText(
                stringResource(R.string.device_access_permission_ops_section_permissions),
                style = Floe.typography.body,
                color = Floe.colors.label,
                modifier = Modifier.weight(1f),
            )
            FloeCapsuleButton(
                stringResource(R.string.device_access_permission_ops_refresh),
                onClick = onRefresh,
                enabled = enabled,
                modifier = Modifier.widthIn(min = 64.dp, max = 96.dp),
            )
        }
        if (busy) {
            FloeText(
                stringResource(R.string.device_access_permission_ops_loading),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
        permissionsText?.lineSequence()?.drop(1)?.take(40)?.forEach { line ->
            // "granted|dangerous|android.permission.CAMERA" — only runtime
            // (dangerous/development) rows are actionable; everything else
            // is a read-only disclosure.
            val parts = line.split('|')
            if (parts.size < 3) return@forEach
            val granted = parts[0] == "granted"
            val level = parts[1]
            val name = parts[2]
            val actionable = "dangerous" in level || "development" in level
            Row(
                Modifier.fillMaxWidth().heightIn(min = 36.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Column(Modifier.weight(1f)) {
                    FloeText(name, style = Floe.typography.metadata, maxLines = 1,
                        overflow = TextOverflow.Ellipsis)
                    FloeText(
                        stringResource(
                            if (granted) R.string.device_access_permission_ops_granted
                            else R.string.device_access_permission_ops_not_granted,
                        ) + " · " + level,
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                if (actionable) {
                    FloeCapsuleButton(
                        stringResource(
                            if (granted) R.string.device_access_permission_ops_revoke
                            else R.string.device_access_permission_ops_grant,
                        ),
                        onClick = { onSetPermission(name, !granted) },
                        enabled = enabled,
                        modifier = Modifier.widthIn(min = 64.dp, max = 96.dp),
                    )
                }
            }
        }
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FloeText(
                stringResource(R.string.device_access_permission_ops_section_appops),
                style = Floe.typography.body,
                color = Floe.colors.label,
                modifier = Modifier.weight(1f),
            )
            // Meaningful scope choice, visible only when the user allowed
            // the UID scope AND the live peer supports it; diagnostics stay
            // in the status line.
            if (uidScopeAvailable) {
                FloeSegmented(
                    options = listOf(
                        stringResource(R.string.device_access_permission_ops_scope_app),
                        stringResource(R.string.device_access_permission_ops_scope_uid),
                    ),
                    selectedIndex = if (appOpsScope == DEVICE_ACCESS_APPOPS_SCOPE_UID) 1 else 0,
                    onSelect = { index ->
                        onAppOpsScopeChange(
                            if (index == 1) {
                                DEVICE_ACCESS_APPOPS_SCOPE_UID
                            } else {
                                DEVICE_ACCESS_APPOPS_SCOPE_PACKAGE
                            },
                        )
                    },
                )
            }
        }
        if (uidScopeAvailable && appOpsScope == DEVICE_ACCESS_APPOPS_SCOPE_UID) {
            FloeText(
                stringResource(R.string.device_access_permission_ops_scope_uid_hint),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
        appOpsRows.forEach { row ->
            Column(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    FloeText(
                        row.operation + " → " + row.effective,
                        style = Floe.typography.metadata,
                        modifier = Modifier.weight(1f),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Row(
                    Modifier.fillMaxWidth().padding(top = 2.dp),
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    DEVICE_ACCESS_APPOPS_MODES.forEach { mode ->
                        FloeCapsuleButton(
                            mode,
                            onClick = { onSetAppOp(row.operation, mode) },
                            enabled = enabled && mode != row.effective,
                            modifier = Modifier.widthIn(min = 56.dp, max = 92.dp),
                        )
                    }
                }
            }
        }
        when (status) {
            is DeviceAccessPermissionOpsResult.Failed -> FloeText(
                stringResource(
                    R.string.device_access_permission_ops_failed,
                    status.code.take(80),
                ),
                style = Floe.typography.metadata,
                color = Floe.colors.destructive,
            )
            else -> Unit
        }
    }
}
