// SPDX-License-Identifier: MPL-2.0
@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.floe.android

import android.Manifest
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionRow
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeCapsuleButton
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeInlineSwitch
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeSectionRow
import com.floe.android.design.FloeSecureFormField
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeSettingsContentDensity
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeStatusLine
import com.floe.android.design.FloeText
import com.floe.android.design.FloeValueRow
import com.floe.android.design.IconGlyph
import com.floe.android.host.deviceaccess.DeviceAccessToolCatalog
import com.floe.android.host.deviceaccess.PairingNotificationAccess
import com.floe.android.host.deviceaccess.PairingNotificationPolicy
import io.github.robinpcrd.cupertino.section.SectionScope

/**
 * G08 stateless "Phone" settings page.
 *
 * Contract boundaries:
 *  - Presentation ONLY. It imports nothing from `feature.phonecontrol`,
 *    `feature.rootsystem`, the embedded ADB module or any other unfinished
 *    backend; every state and every effect arrives through
 *    [DeviceAccessPresentationState] / [DeviceAccessCallbacks]. The App
 *    integrator wires the real flows in the next stage.
 *  - Platform truth is never invented. A status is rendered exactly as the
 *    supplied state says; this page has no "check succeeded" fallback and no
 *    AVAILABLE default. Service-alive only appears for [DeviceAccessAdbUi.ServiceAlive]
 *    and never implies an operation succeeded.
 *  - The three layers stay separate: ordinary Accessibility grant, embedded
 *    ADB pairing/service, and the default-off Root grant. Enabling ADB never
 *    enables Root, and a root grant is never inferred from ADB.
 *  - The pairing code is caller-owned RAM input. This page never saves it
 *    (no `rememberSaveable`), never logs it and never renders it outside the
 *    masked field. The reveal toggle is local presentation only.
 *  - FULL only: the page owns the platform POST_NOTIFICATIONS request/settings
 *    entry used by the inline pairing notification. It never posts the
 *    notification or handles the code itself; that stays in DeviceAccessHost.
 *  - The page is host-neutral so the same content works in the compact
 *    phone detail page and in the tablet settings detail column.
 *  - Compact overview (N08): the connection group (embedded ADB) leads the
 *    page so status and start/stop controls stay reachable on a phone, and
 *    the folder classes are progressive-disclosure count rows that open
 *    child sheets instead of permanent switch lists. Every control,
 *    callback, gate and capability state from the flat layout is preserved.
 *  - Compact density (N08 round 2): each connection card carries ONE status
 *    row whose trailing slot hosts the direct next action, so the phone
 *    scan is status → action without full-width button rows; sibling
 *    secondary actions share one wrapping capsule row. Static explanation
 *    prose rides behind an opened "Details" fold in the card footer; live
 *    identity (UID), state-specific guidance and risk hints stay visible.
 *    App management keeps both ceiling switches on the page with the full
 *    permission/risk wording in an opened details fold, and the staged-APK
 *    list moves into a child sheet that shows readable file identity
 *    (name, size, package) with exact staged IDs, callbacks and opened
 *    path/digest diagnostics preserved.
 */
enum class DeviceAccessScreenScopeUi { OFF, CURRENT_TASK, UNTIL_STOPPED }

enum class DeviceAccessTaskPhaseUi { RUNNING, WAITING_FOR_USER, TAKEN_OVER, STOPPING }

/** User-only arm state for phone control on the visible task. */
enum class DeviceAccessTaskControlUi { OFF, ARMED, STOPPED }

enum class DeviceAccessPairingDiscoveryUi { IDLE, DISCOVERING, FOUND, UNAVAILABLE }

data class DeviceAccessPackageUi(
    val packageName: String,
    val label: String,
    val selected: Boolean,
)

/** Keep all verified page/lookup rows searchable and preserve saved selections. */
internal fun mergeDeviceAccessAppCatalog(
    discovered: List<DeviceAccessPackageUi>,
    verifiedLookups: List<DeviceAccessPackageUi>,
    selected: Set<String>,
): List<DeviceAccessPackageUi> {
    val rows = LinkedHashMap<String, DeviceAccessPackageUi>()
    for (row in discovered) rows[row.packageName] = row
    for (row in verifiedLookups) rows.putIfAbsent(row.packageName, row)
    for (name in selected) rows.putIfAbsent(name, DeviceAccessPackageUi(name, name, true))
    return rows.values.map { it.copy(selected = it.packageName in selected) }
        .sortedWith(compareByDescending<DeviceAccessPackageUi> { it.selected }
            .thenBy { it.label.lowercase() })
}

/** Exact-name advanced lookup outcome surfaced inside the target sheet. */
enum class DeviceAccessLookupUiState { IDLE, RUNNING, FOUND, MISSING, ERROR }

enum class DeviceAccessFileRootKindUi { SHARED, SYSTEM, APP_DATA }

data class DeviceAccessFileRootUi(
    val id: String,
    val selected: Boolean,
    val labelRes: Int = 0,
    /** Explicit user-entered path for an app-data folder; empty for presets. */
    val label: String = "",
    /** True when the global write ceiling can apply to this root at all. */
    val writable: Boolean = true,
    val kind: DeviceAccessFileRootKindUi = DeviceAccessFileRootKindUi.SHARED,
)

/** One App-staged APK shown in the management surface; zero-privilege
 *  bookkeeping the user can inspect, stage and remove at any time. */
data class DeviceAccessStagedApkUi(
    val stagedId: String,
    val fileName: String,
    val sizeBytes: Long,
    val packageName: String?,
    val sha256: String,
)

/**
 * Explicit capability ceilings selected by the user. Empty package/root sets
 * mean "no target authorized", never "all targets": there is no blanket grant.
 */
data class DeviceAccessTargetsUi(
    val packages: List<DeviceAccessPackageUi> = emptyList(),
    val selectedPackages: Set<String> = emptySet(),
    val fileRoots: List<DeviceAccessFileRootUi> = emptyList(),
    val selectedRootIds: Set<String> = emptySet(),
    val fileWritesAllowed: Boolean = false,
    /** Root is the live service; only then may an app-data folder be added. */
    val appDataRootsAvailable: Boolean = false,
    val packageManagementAllowed: Boolean = false,
    /** The ONE shared advanced-system master switch. */
    val advancedSystemManagementAllowed: Boolean = false,
    /** Allowed advanced tool names (exact ABI names, shipped subset only). */
    val advancedSystemAllowedTools: Set<String> = emptySet(),
    val selectedAdvancedSystemTargets: Set<String> = emptySet(),
    /** Derived from the existing app-management and AppOps category gates. */
    val appOpsUidScopeAllowed: Boolean = false,
    /**
     * The LIVE privileged peer advertises the AppOps UID write scope; the
     * scope is available only while this is true, so an older service
     * never receives a UID request it would silently downgrade.
     */
    val appOpsUidScopeSupported: Boolean = false,
    /** Eligible advanced targets incl. disabled/removed preinstalled apps. */
    val advancedSystemTargets: List<DeviceAccessPackageUi> = emptyList(),
    /** Pre-window launcher rows; larger than packages.size means the sheet is
     *  a window and must say so instead of truncating silently. */
    val installedCatalogTotal: Int = 0,
    /** User-requested installed-package lookup; never changes selection. */
    val targetLookupState: DeviceAccessLookupUiState = DeviceAccessLookupUiState.IDLE,
    val targetLookupQuery: String = "",
    val catalogLoading: Boolean = false,
    val advancedCatalogReadFailed: Boolean = false,
    /** Merged advanced rows before the sheet window. */
    val advancedCatalogListed: Int = 0,
    /** True when the merged advanced catalog exceeds the sheet window. */
    val advancedCatalogWindowed: Boolean = false,
    /** The privileged service page itself hit its row bound. */
    val advancedCatalogServiceTruncated: Boolean = false,
    /** Exact-name lookup outcome the host verified against the service. */
    val advancedLookupState: DeviceAccessLookupUiState = DeviceAccessLookupUiState.IDLE,
    val advancedLookupQuery: String = "",
    /** True only while the privileged service can actually run a lookup. */
    val advancedLookupAvailable: Boolean = false,
    val stagedApks: List<DeviceAccessStagedApkUi> = emptyList(),
    val wholeScreenConsent: Boolean = false,
    val windowScreenshotCapable: Boolean = true,
)

enum class DeviceAccessBusyUi {
    NONE,
    PHONE_ARM,
    PAIRING,
    STARTING,
    STOPPING,
    FORGETTING,
    ROOT_CHECK,
    ROOT_ENABLE,
    TASK_STOP,
    TASK_TAKE_OVER,
}

enum class DeviceAccessAdbActionUi { ENABLE, PAIR, SUBMIT_CODE, CANCEL_PAIRING, START, STOP, FORGET, OPEN_DEVELOPER_OPTIONS }

sealed interface DeviceAccessAccessibilityUi {
    data object Off : DeviceAccessAccessibilityUi
    data object NotGranted : DeviceAccessAccessibilityUi
    data object Granted : DeviceAccessAccessibilityUi
    data object Restricted : DeviceAccessAccessibilityUi
    data object Revoked : DeviceAccessAccessibilityUi
}

sealed interface DeviceAccessAdbUi {
    /** The tier was never turned on by the user. */
    data object Off : DeviceAccessAdbUi

    /**
     * No usable pairing. [pairingSessionOpen] means the Android pairing
     * screen was opened from Floe. The six-digit code can be entered in the
     * inline notification while that screen stays in front, or in the visible
     * field when the device keeps the dialog open (manual/split path). The
     * value is caller-owned RAM only.
     */
    data class PairRequired(val pairingSessionOpen: Boolean = false) : DeviceAccessAdbUi

    /** A code was submitted; the service handshake is still pending. */
    data object Pairing : DeviceAccessAdbUi

    /** The pairing relationship exists but no Floe service is running. */
    data class Paired(val effectiveUid: Int? = null) : DeviceAccessAdbUi

    /** A live Floe-owned shell service. [effectiveUid] is reported, not assumed. */
    data class ServiceAlive(val effectiveUid: Int? = null) : DeviceAccessAdbUi

    /** The Floe service died after having been alive; pairing is untouched. */
    data class ServiceDied(val code: String? = null) : DeviceAccessAdbUi

    /** The device restarted: pair trust may remain, the service must start again. */
    data object RestartRequired : DeviceAccessAdbUi

    /** The user removed the pairing in Android settings. */
    data object Revoked : DeviceAccessAdbUi

    /** A typed terminal failure; the page never turns this into "running". */
    data class Error(val message: String, val code: String? = null) : DeviceAccessAdbUi
}

sealed interface DeviceAccessRootUi {
    /** Default off. Nothing has been checked yet. */
    data object Off : DeviceAccessRootUi

    data object GrantNotFound : DeviceAccessRootUi

    /** An existing root grant is present; the user still has to turn it on. */
    data object GrantFound : DeviceAccessRootUi

    data class Enabled(val effectiveUid: Int? = null) : DeviceAccessRootUi

    data class Refused(val code: String? = null) : DeviceAccessRootUi

    data class Error(val message: String, val code: String? = null) : DeviceAccessRootUi
}

data class DeviceAccessActiveTaskUi(
    val title: String,
    val phase: DeviceAccessTaskPhaseUi,
)

enum class DeviceAccessErrorSectionUi { GENERAL, ADB }

data class DeviceAccessUiError(
    val message: String,
    /** Typed diagnostic token; shown only inside the opened details fold. */
    val code: String? = null,
    val section: DeviceAccessErrorSectionUi = DeviceAccessErrorSectionUi.GENERAL,
)

data class DeviceAccessPresentationState(
    val accessibility: DeviceAccessAccessibilityUi = DeviceAccessAccessibilityUi.Off,
    val adb: DeviceAccessAdbUi = DeviceAccessAdbUi.Off,
    val root: DeviceAccessRootUi = DeviceAccessRootUi.Off,
    val screenScope: DeviceAccessScreenScopeUi = DeviceAccessScreenScopeUi.OFF,
    val activeTask: DeviceAccessActiveTaskUi? = null,
    val taskControl: DeviceAccessTaskControlUi = DeviceAccessTaskControlUi.OFF,
    val targets: DeviceAccessTargetsUi = DeviceAccessTargetsUi(),
    /** Closed system-settings sheet: stored values, gate and last outcome. */
    val systemSettings: DeviceAccessSystemSettingsUiState = DeviceAccessSystemSettingsUiState(),
    val busy: DeviceAccessBusyUi = DeviceAccessBusyUi.NONE,
    val error: DeviceAccessUiError? = null,
    /** True only on API >= 30 where wireless ADB pairing exists. */
    val pairingSupported: Boolean = true,
    /** Ephemeral pairing port held in RAM only; never persisted/logged. */
    val pairingPort: String = "",
    val pairingDiscovery: DeviceAccessPairingDiscoveryUi = DeviceAccessPairingDiscoveryUi.IDLE,
    /** True after the real controller's USB bootstrap command was copied. */
    val usbBootstrapExported: Boolean = false,
    val automaticPhoneControl: Boolean = false,
    val autoUnlock: Boolean = false,
    val unlockConfigured: Boolean = false,
    val floatingControls: Boolean = false,
)

/**
 * All effects return to the App integrator. Default lambdas are inert so a
 * preview or a not-yet-wired host can compose the page without pretending an
 * action happened.
 */
class DeviceAccessCallbacks(
    val onOpenAccessibilitySettings: () -> Unit = {},
    val onRefresh: () -> Unit = {},
    /** Lightweight catalog re-read when a target sheet opens; the page never
     *  blocks on it and the host coalesces bursts. */
    val onTargetsRefresh: () -> Unit = {},
    val onTargetLookup: (String) -> Unit = {},
    /** USER-ONLY: resolves one exact typed package name against the live
     *  service so targets outside the listed window stay discoverable. */
    val onAdvancedTargetLookup: (String) -> Unit = { },
    /** USER-ONLY: allows phone control for the exact visible task/run. */
    val onArmPhoneControl: () -> Unit = {},
    val onAutomaticControlChange: (Boolean) -> Unit = {},
    val onAutoUnlockChange: (Boolean) -> Unit = {},
    val onSaveUnlockCredential: (String) -> Unit = {},
    val onForgetUnlockCredential: () -> Unit = {},
    val onFloatingControlsChange: (Boolean) -> Unit = {},
    val onStopActiveTask: () -> Unit = {},
    val onTakeOverActiveTask: () -> Unit = {},
    val onAllowedPackagesChange: (Set<String>) -> Unit = {},
    val onFileRootsChange: (Set<String>) -> Unit = {},
    /** Adds one explicit other-app data folder while Root is live. The host
     *  validates it against the backend-validated shape; it is never derived
     *  from model text or from enabling Root itself. */
    val onAddAppDataRoot: (String) -> Unit = {},
    val onFileWritesChange: (Boolean) -> Unit = {},
    val onWholeScreenConsentChange: (Boolean) -> Unit = {},
    val onPackageManagementChange: (Boolean) -> Unit = {},
    /** The shared advanced-system master; disabling revokes live grants. */
    val onAdvancedSystemChange: (Boolean) -> Unit = {},
    /** Allowed advanced tool names (shipped app-state subset only). */
    val onAdvancedSystemToolsChange: (Set<String>) -> Unit = {},
    /** Selected installed-app targets for the advanced group. */
    val onAdvancedSystemTargetsChange: (Set<String>) -> Unit = {},
    val onScreenScopeChange: (DeviceAccessScreenScopeUi) -> Unit = {},
    val onEnableAdb: () -> Unit = {},
    /** Opens the system Wireless debugging pairing screen and posts the
     * inline-code notification; the caller keeps Floe's code entry alive. */
    val onPairAdb: () -> Unit = {},
    /** [code] is the RAM-only field value; the callee must not persist/log it. */
    val onSubmitPairingCode: (String) -> Unit = {},
    /** Ephemeral numeric fallback when bounded NSD discovery is unavailable. */
    val onPairingPortChange: (String) -> Unit = {},
    val onDiscoverPairingPort: () -> Unit = {},
    /** Android 9/10 only: copy the command/script produced by the real
     * embedded controller. Never a fabricated "wireless is ready" state. */
    val onExportUsbBootstrap: () -> Unit = {},
    val onCancelPairing: () -> Unit = {},
    val onStartAdbService: () -> Unit = {},
    val onStopAdbService: () -> Unit = {},
    val onForgetAdbPairing: () -> Unit = {},
    val onOpenDeveloperOptions: () -> Unit = {},
    val onCheckRootGrant: () -> Unit = {},
    val onEnableRoot: (Boolean) -> Unit = {},
    /** Stage SAF-picked APKs into the App-local install staging dir. */
    val onStageApks: (List<android.net.Uri>) -> Unit = {},
    val onRemoveStagedApk: (String) -> Unit = {},
    /** Immediately revoke every live system-access grant (visible revoke). */
    val onRevokeSystemGrants: () -> Unit = {},
    /** Re-read the stored values for the system-settings sheet. */
    val onSystemSettingsRefresh: () -> Unit = {},
    /** Apply the sheet's typed batch (at most 8 changes; user action). */
    val onSystemSettingsApply: (List<DeviceAccessSystemSettingChangeUi>) -> Unit = {},
    /** Restore one key to [baseline], the value captured when the sheet opened. */
    val onSystemSettingsRestore: (DeviceAccessSystemSettingUi, String?) -> Unit = { _, _ -> },
)

/**
 * Pairing-code input policy. Android's wireless-debugging code is exactly six
 * digits; anything else is not submittable. The value itself is never copied
 * into this object, a log, a Bundle or a diagnostics record.
 */
object DeviceAccessPairingCode {
    const val LENGTH = 6

    fun sanitize(input: String): String = input.filter { it.isDigit() }.take(LENGTH)

    fun canSubmit(input: String): Boolean = sanitize(input).length == LENGTH
}

/**
 * Pure presentation policy for [DeviceAccessSettingsPage]. Keeping the action
 * sets and status copy here (instead of inline composable branches) pins the
 * truthfulness rules with JVM tests:
 *  - distinct states stay distinct (no collapsed "available");
 *  - busy work disables conflicting actions;
 *  - root starts OFF and can be switched only after a real grant is found;
 *  - ADB never implies Root and an ADB code field appears only for an open
 *    pairing session.
 */
object DeviceAccessPresentation {

    fun accessibilityStatusRes(state: DeviceAccessAccessibilityUi): Int = when (state) {
        DeviceAccessAccessibilityUi.Off -> R.string.device_access_state_off
        DeviceAccessAccessibilityUi.NotGranted -> R.string.device_access_state_not_granted
        DeviceAccessAccessibilityUi.Granted -> R.string.device_access_state_granted
        DeviceAccessAccessibilityUi.Restricted -> R.string.device_access_state_restricted
        DeviceAccessAccessibilityUi.Revoked -> R.string.device_access_state_revoked
    }

    fun accessibilityGranted(state: DeviceAccessAccessibilityUi): Boolean =
        state == DeviceAccessAccessibilityUi.Granted

    fun adbStatusRes(state: DeviceAccessAdbUi): Int = when (state) {
        DeviceAccessAdbUi.Off -> R.string.device_access_adb_state_off
        is DeviceAccessAdbUi.PairRequired -> R.string.device_access_adb_state_pair_required
        DeviceAccessAdbUi.Pairing -> R.string.device_access_adb_state_pairing
        is DeviceAccessAdbUi.Paired -> R.string.device_access_adb_state_paired
        is DeviceAccessAdbUi.ServiceAlive -> R.string.device_access_adb_state_alive
        is DeviceAccessAdbUi.ServiceDied -> R.string.device_access_adb_state_died
        DeviceAccessAdbUi.RestartRequired -> R.string.device_access_adb_state_restart
        DeviceAccessAdbUi.Revoked -> R.string.device_access_adb_state_revoked
        is DeviceAccessAdbUi.Error -> R.string.device_access_adb_state_error
    }

    /** Only a live, verified service reports a real effective UID. A pairing
     *  relationship is not a running process and never implies shell access. */
    fun adbEffectiveUid(state: DeviceAccessAdbUi): Int? = when (state) {
        is DeviceAccessAdbUi.ServiceAlive -> state.effectiveUid
        else -> null
    }

    /** Actions the current state honestly offers while nothing is in flight. */
    fun adbActions(
        state: DeviceAccessAdbUi,
        busy: DeviceAccessBusyUi = DeviceAccessBusyUi.NONE,
    ): Set<DeviceAccessAdbActionUi> {
        val base = when (state) {
            DeviceAccessAdbUi.Off -> setOf(DeviceAccessAdbActionUi.ENABLE)
            is DeviceAccessAdbUi.PairRequired ->
                if (state.pairingSessionOpen) {
                    setOf(
                        DeviceAccessAdbActionUi.SUBMIT_CODE,
                        DeviceAccessAdbActionUi.CANCEL_PAIRING,
                        DeviceAccessAdbActionUi.OPEN_DEVELOPER_OPTIONS,
                    )
                } else {
                    setOf(DeviceAccessAdbActionUi.PAIR, DeviceAccessAdbActionUi.OPEN_DEVELOPER_OPTIONS)
                }
            DeviceAccessAdbUi.Pairing -> setOf(DeviceAccessAdbActionUi.CANCEL_PAIRING)
            is DeviceAccessAdbUi.Paired ->
                setOf(DeviceAccessAdbActionUi.START, DeviceAccessAdbActionUi.FORGET,
                    DeviceAccessAdbActionUi.OPEN_DEVELOPER_OPTIONS)
            is DeviceAccessAdbUi.ServiceAlive ->
                setOf(DeviceAccessAdbActionUi.STOP, DeviceAccessAdbActionUi.FORGET)
            is DeviceAccessAdbUi.ServiceDied ->
                setOf(DeviceAccessAdbActionUi.START, DeviceAccessAdbActionUi.FORGET,
                    DeviceAccessAdbActionUi.OPEN_DEVELOPER_OPTIONS)
            DeviceAccessAdbUi.RestartRequired ->
                setOf(DeviceAccessAdbActionUi.START, DeviceAccessAdbActionUi.OPEN_DEVELOPER_OPTIONS)
            DeviceAccessAdbUi.Revoked ->
                setOf(DeviceAccessAdbActionUi.PAIR, DeviceAccessAdbActionUi.OPEN_DEVELOPER_OPTIONS)
            is DeviceAccessAdbUi.Error ->
                setOf(DeviceAccessAdbActionUi.ENABLE, DeviceAccessAdbActionUi.PAIR,
                    DeviceAccessAdbActionUi.OPEN_DEVELOPER_OPTIONS)
        }
        return when (busy) {
            DeviceAccessBusyUi.NONE -> base
            // Cancelling a pairing handshake is the one action that stays
            // available while that same handshake is in flight.
            DeviceAccessBusyUi.PAIRING ->
                if (DeviceAccessAdbActionUi.CANCEL_PAIRING in base) {
                    setOf(DeviceAccessAdbActionUi.CANCEL_PAIRING)
                } else {
                    emptySet()
                }
            else -> emptySet()
        }
    }

    fun adbShowsCodeField(state: DeviceAccessAdbUi): Boolean =
        state is DeviceAccessAdbUi.PairRequired && state.pairingSessionOpen

    fun adbSubmitEnabled(
        code: String,
        state: DeviceAccessAdbUi,
        busy: DeviceAccessBusyUi,
    ): Boolean = adbShowsCodeField(state) && busy == DeviceAccessBusyUi.NONE &&
        DeviceAccessPairingCode.canSubmit(code)

    /** A pairing submission also requires the REAL ephemeral port. */
    fun adbSubmitEnabled(
        code: String,
        port: String,
        state: DeviceAccessAdbUi,
        busy: DeviceAccessBusyUi,
    ): Boolean = adbSubmitEnabled(code, state, busy) && pairingPortValid(port)

    /** Row labels for the shipped advanced tool names; 0 for anything else. */
    fun advancedToolLabelRes(tool: String): Int = when (tool) {
        DeviceAccessToolCatalog.SYSTEM_PACKAGES_SET_ENABLED ->
            R.string.device_access_advanced_tool_set_enabled
        DeviceAccessToolCatalog.SYSTEM_PACKAGES_REMOVE_FOR_USER ->
            R.string.device_access_advanced_tool_remove_for_user
        DeviceAccessToolCatalog.SYSTEM_PACKAGES_RESTORE ->
            R.string.device_access_advanced_tool_restore
        DeviceAccessToolCatalog.SYSTEM_PERMISSIONS_MANAGE ->
            R.string.device_access_advanced_tool_permissions_manage
        DeviceAccessToolCatalog.SYSTEM_APPOPS_MANAGE ->
            R.string.device_access_advanced_tool_appops_manage
        DeviceAccessToolCatalog.SYSTEM_SETTINGS_WRITE ->
            R.string.device_access_system_settings_entry
        else -> 0
    }

    fun rootStatusRes(state: DeviceAccessRootUi): Int = when (state) {
        DeviceAccessRootUi.Off -> R.string.device_access_root_state_off
        DeviceAccessRootUi.GrantNotFound -> R.string.device_access_root_state_no_grant
        DeviceAccessRootUi.GrantFound -> R.string.device_access_root_state_grant_found
        is DeviceAccessRootUi.Enabled -> R.string.device_access_root_state_enabled
        is DeviceAccessRootUi.Refused -> R.string.device_access_root_state_refused
        is DeviceAccessRootUi.Error -> R.string.device_access_root_state_error
    }

    /** Root is default-off: only a discovered grant or an already-enabled
     * state can be switched. Nothing here is derived from the ADB state. */
    fun rootSwitchEnabled(state: DeviceAccessRootUi): Boolean = when (state) {
        DeviceAccessRootUi.GrantFound -> true
        is DeviceAccessRootUi.Enabled -> true
        else -> false
    }

    fun rootSwitchChecked(state: DeviceAccessRootUi): Boolean = state is DeviceAccessRootUi.Enabled

    fun rootEffectiveUid(state: DeviceAccessRootUi): Int? =
        (state as? DeviceAccessRootUi.Enabled)?.effectiveUid

    fun rootCheckVisible(state: DeviceAccessRootUi): Boolean = when (state) {
        DeviceAccessRootUi.Off, DeviceAccessRootUi.GrantNotFound,
        is DeviceAccessRootUi.Refused, is DeviceAccessRootUi.Error -> true
        DeviceAccessRootUi.GrantFound, is DeviceAccessRootUi.Enabled -> false
    }

    /** The write ceiling can only be switched on when at least one selected
     *  root is actually writable. Platform system roots never qualify. */
    fun fileWritesToggleEnabled(targets: DeviceAccessTargetsUi): Boolean =
        targets.fileRoots.any { root ->
            root.selected && root.writable && root.kind != DeviceAccessFileRootKindUi.SYSTEM
        }

    /** Batch-grant selection: every preset root (shared + platform inspection
     *  trees). Explicit other-app folders stay user-typed one at a time. */
    fun allSelectableRootIds(targets: DeviceAccessTargetsUi): Set<String> =
        targets.fileRoots
            .filter { it.kind != DeviceAccessFileRootKindUi.APP_DATA }
            .map { it.id }
            .toSet()

    /** Batch-grant selection: the full authorized app list. The host clamps
     *  the persisted ceiling to its own maximum. */
    fun allSelectablePackageIds(targets: DeviceAccessTargetsUi): Set<String> =
        targets.packages.map { it.packageName }.toSet()

    fun appDataFolderAddEnabled(state: DeviceAccessPresentationState): Boolean =
        state.targets.appDataRootsAvailable &&
            state.root is DeviceAccessRootUi.Enabled &&
            state.busy == DeviceAccessBusyUi.NONE

    fun screenScopeEnabled(state: DeviceAccessPresentationState): Boolean =
        state.activeTask != null

    /** Arm is a USER gesture on the exact visible task; it is never a tool. */
    fun canArmPhoneControl(state: DeviceAccessPresentationState): Boolean =
        state.activeTask != null &&
            state.taskControl != DeviceAccessTaskControlUi.ARMED &&
            state.busy == DeviceAccessBusyUi.NONE &&
            state.accessibility == DeviceAccessAccessibilityUi.Granted &&
            state.targets.selectedPackages.isNotEmpty()

    fun canStopTask(state: DeviceAccessPresentationState): Boolean =
        state.activeTask != null &&
            state.taskControl == DeviceAccessTaskControlUi.ARMED &&
            state.busy == DeviceAccessBusyUi.NONE

    fun canTakeOverTask(state: DeviceAccessPresentationState): Boolean =
        state.activeTask != null &&
            state.taskControl == DeviceAccessTaskControlUi.ARMED &&
            state.busy == DeviceAccessBusyUi.NONE &&
            (state.activeTask.phase == DeviceAccessTaskPhaseUi.RUNNING ||
                state.activeTask.phase == DeviceAccessTaskPhaseUi.WAITING_FOR_USER)

    /** Keep saved consent reachable for revocation after the task scope ends.
     * API 34+ prefers window capture but never silently widens to display. */
    fun wholeScreenConsentVisible(state: DeviceAccessPresentationState): Boolean =
        state.screenScope != DeviceAccessScreenScopeUi.OFF || state.targets.wholeScreenConsent

    fun wholeScreenConsentRequired(state: DeviceAccessPresentationState): Boolean =
        state.screenScope != DeviceAccessScreenScopeUi.OFF &&
            !state.targets.windowScreenshotCapable

    fun fileToolScopeValid(state: DeviceAccessPresentationState): Boolean =
        state.targets.fileRoots.any { root ->
            root.selected &&
                (root.kind != DeviceAccessFileRootKindUi.APP_DATA ||
                    state.targets.appDataRootsAvailable)
        }

    fun packageTargetsValid(state: DeviceAccessPresentationState): Boolean =
        state.targets.selectedPackages.isNotEmpty()

    fun pairingPortValid(raw: String): Boolean =
        com.floe.android.host.deviceaccess.AdbPairingPortDiscovery.parsePort(raw) != null

    fun taskPhaseRes(phase: DeviceAccessTaskPhaseUi): Int = when (phase) {
        DeviceAccessTaskPhaseUi.RUNNING -> R.string.device_access_active_running
        DeviceAccessTaskPhaseUi.WAITING_FOR_USER -> R.string.device_access_active_waiting
        DeviceAccessTaskPhaseUi.TAKEN_OVER -> R.string.device_access_active_taken_over
        DeviceAccessTaskPhaseUi.STOPPING -> R.string.device_access_active_stopping
    }

    /**
     * The only value ever rendered inside the opened details fold: a bounded
     * machine token. Unknown characters are dropped, never translated.
     */
    fun errorCode(error: DeviceAccessUiError?): String? = error?.code
        ?.take(96)
        ?.filter { it.isLetterOrDigit() || it in "_.-:" }
        ?.ifEmpty { null }

    fun adbStartFailureRes(code: String): Int = when (code) {
        "no_connect_port" -> R.string.device_access_adb_no_connection
        "pair_required", "identity_unpaired" -> R.string.device_access_adb_pair_first
        "usb_bootstrap_required" -> R.string.device_access_pairing_unsupported
        "adb_connect", "adb_connect_tls", "adb_connect_refused", "adb_connect_host",
        "adb_connect_io", "adb_connect_timeout", "adb_connect_protocol", "adb_connect_output" ->
            R.string.device_access_adb_connection_failed
        else -> R.string.device_access_adb_start_failed
    }
}

@Composable
fun DeviceAccessSettingsPage(
    state: DeviceAccessPresentationState,
    callbacks: DeviceAccessCallbacks,
    pairingCode: String,
    onPairingCodeChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    permissionOpsInspector: DeviceAccessPermissionOpsInspector? = null,
) {
    val colors = Floe.colors
    // Presentation-only toggles: deliberately NOT saveable, so nothing about
    // the pairing field or a failure detail survives process death.
    var showErrorDetails by remember { mutableStateOf(false) }
    var revealPairingCode by remember { mutableStateOf(false) }
    var confirmForget by remember { mutableStateOf(false) }
    var confirmRootCheck by remember { mutableStateOf(false) }
    var confirmAutomatic by remember { mutableStateOf(false) }
    var appChooserOpen by remember { mutableStateOf(false) }
    var permissionOpsOpen by remember { mutableStateOf(false) }
    var advancedChooserOpen by remember { mutableStateOf(false) }
    var advancedToolsChooserOpen by remember { mutableStateOf(false) }
    var systemSettingsOpen by remember { mutableStateOf(false) }
    var sharedFoldersOpen by remember { mutableStateOf(false) }
    var systemFoldersOpen by remember { mutableStateOf(false) }
    var stagedApksOpen by remember { mutableStateOf(false) }
    var adbDetailsOpen by remember { mutableStateOf(false) }
    var accessibilityLimitsOpen by remember { mutableStateOf(false) }
    var managementDetailsOpen by remember { mutableStateOf(false) }
    var confirmUnlock by remember { mutableStateOf(false) }
    var unlockDraft by remember { mutableStateOf("") }
    var revealUnlock by remember { mutableStateOf(false) }
    // FULL-only inline notification permission. The notification is what lets
    // the user enter the six-digit code while Android's pairing dialog stays
    // in front; when it is unavailable the page says so and keeps the manual
    // (split-screen) path explicit instead of claiming a broken return flow.
    // Fresh catalog whenever a target sheet opens; the host coalesces these
    // with the install/remove monitor, so a burst of opens is one refresh.
    LaunchedEffect(appChooserOpen) { if (appChooserOpen) callbacks.onTargetsRefresh() }
    LaunchedEffect(advancedChooserOpen) { if (advancedChooserOpen) callbacks.onTargetsRefresh() }

    DeviceAccessAppChooser(
        visible = appChooserOpen,
        targets = state.targets,
        enabled = state.busy == DeviceAccessBusyUi.NONE,
        onSelectionChange = callbacks.onAllowedPackagesChange,
        onDismiss = { appChooserOpen = false },
        catalogTotal = state.targets.installedCatalogTotal,
        onCatalogRefresh = callbacks.onTargetsRefresh,
        onLookup = callbacks.onTargetLookup,
    )
    // Compact permission/AppOps inspector over the SELECTED advanced
    // targets; user-initiated reads/changes only, durable ceilings enforced
    // by the host on every action.
    DeviceAccessPermissionOpsSheet(
        visible = permissionOpsOpen,
        targets = state.targets.advancedSystemTargets.filter { it.selected },
        enabled = state.busy == DeviceAccessBusyUi.NONE,
        inspector = permissionOpsInspector,
        uidScopeAvailable = state.targets.appOpsUidScopeAllowed &&
            state.targets.appOpsUidScopeSupported,
        onDismiss = { permissionOpsOpen = false },
    )
    DeviceAccessAppChooserSheet(
        visible = advancedChooserOpen,
        packages = state.targets.advancedSystemTargets,
        selected = state.targets.selectedAdvancedSystemTargets,
        titleRes = R.string.device_access_targets_section_advanced,
        enabled = state.busy == DeviceAccessBusyUi.NONE,
        onSelectionChange = callbacks.onAdvancedSystemTargetsChange,
        onDismiss = { advancedChooserOpen = false },
        catalogListed = state.targets.advancedSystemTargets.size,
        catalogTotal = state.targets.advancedCatalogListed,
        catalogTruncated = state.targets.advancedCatalogServiceTruncated,
        lookupEnabled = state.targets.advancedLookupAvailable,
        lookupState = state.targets.advancedLookupState,
        lookupQuery = state.targets.advancedLookupQuery,
        onLookup = callbacks.onAdvancedTargetLookup,
        catalogLoading = state.targets.catalogLoading,
        catalogReadFailed = state.targets.advancedCatalogReadFailed,
        onCatalogRefresh = callbacks.onTargetsRefresh,
    )
    DeviceAccessAppChooserSheet(
        visible = advancedToolsChooserOpen,
        packages = DeviceAccessToolCatalog.SHIPPED_ADVANCED_TOOLS.map { tool ->
            DeviceAccessPackageUi(
                packageName = tool,
                label = stringResource(DeviceAccessPresentation.advancedToolLabelRes(tool)),
                selected = tool in state.targets.advancedSystemAllowedTools,
            )
        },
        selected = state.targets.advancedSystemAllowedTools,
        titleRes = R.string.device_access_advanced_categories,
        enabled = state.busy == DeviceAccessBusyUi.NONE,
        onSelectionChange = callbacks.onAdvancedSystemToolsChange,
        onDismiss = { advancedToolsChooserOpen = false },
        showIdentifiers = false,
        searchable = false,
        countLabelRes = R.string.device_access_advanced_categories_count,
        heightFractionOverride = 0.72f,
    )
    DeviceAccessSystemSettingsSheet(
        visible = systemSettingsOpen,
        state = state.systemSettings,
        onApply = callbacks.onSystemSettingsApply,
        onRestore = callbacks.onSystemSettingsRestore,
        onDismiss = { systemSettingsOpen = false },
    )
    // Progressive-disclosure folder selectors: the page carries one count row
    // per folder class; the per-folder switches live in these child sheets.
    // App-data folders are never listed here (explicit Root grants stay on
    // the page), and a sheet's batch buttons only touch its own class.
    val sharedRoots = state.targets.fileRoots.filter {
        it.kind == DeviceAccessFileRootKindUi.SHARED
    }
    val systemRoots = state.targets.fileRoots.filter {
        it.kind == DeviceAccessFileRootKindUi.SYSTEM
    }
    DeviceAccessFolderChooserSheet(
        visible = sharedFoldersOpen,
        titleRes = R.string.device_access_folders_shared,
        roots = sharedRoots,
        selectedIds = state.targets.selectedRootIds,
        hintRes = R.string.device_access_roots_intro,
        emptyRes = R.string.device_access_roots_empty,
        batch = true,
        enabled = state.busy == DeviceAccessBusyUi.NONE,
        onSelectionChange = callbacks.onFileRootsChange,
        onDismiss = { sharedFoldersOpen = false },
    )
    DeviceAccessFolderChooserSheet(
        visible = systemFoldersOpen,
        titleRes = R.string.device_access_system_roots_section,
        roots = systemRoots,
        selectedIds = state.targets.selectedRootIds,
        hintRes = R.string.device_access_system_roots_hint,
        emptyRes = R.string.device_access_system_roots_hint,
        batch = false,
        enabled = state.busy == DeviceAccessBusyUi.NONE,
        onSelectionChange = callbacks.onFileRootsChange,
        onDismiss = { systemFoldersOpen = false },
    )
    val context = LocalContext.current
    var notificationAvailability by remember {
        mutableStateOf(PairingNotificationAccess.availability(context))
    }
    var notificationDeniedHere by remember { mutableStateOf(false) }
    var pairAfterNotificationGrant by remember { mutableStateOf(false) }
    val notificationPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        notificationAvailability = PairingNotificationAccess.availability(context)
        if (!granted) notificationDeniedHere = true
        if (pairAfterNotificationGrant) {
            pairAfterNotificationGrant = false
            // Pairing is still useful on devices that keep the dialog open;
            // the page shows the explicit inline-unavailable hint.
            callbacks.onPairAdb()
        }
    }
    // Multi-APK SAF staging. The launcher hands picked document uris to the
    // host, which copies bytes into the App-local staging dir; staging alone
    // never installs anything.
    val stageApks = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments(),
    ) { uris ->
        if (uris.isNotEmpty()) callbacks.onStageApks(uris)
    }
    // Progressive-disclosure staging: the page carries one count row; the
    // stage action, the per-APK rows and the opened path/digest diagnostics
    // live in this child sheet. Remove forwards the EXACT stagedId through
    // the existing callback; staging alone never installs anything.
    DeviceAccessStagedApksSheet(
        visible = stagedApksOpen,
        stagedApks = state.targets.stagedApks,
        enabled = state.busy == DeviceAccessBusyUi.NONE,
        onStageClick = {
            stageApks.launch(arrayOf("application/vnd.android.package-archive"))
        },
        onRemove = callbacks.onRemoveStagedApk,
        onDismiss = { stagedApksOpen = false },
    )
    val activity = context as? ComponentActivity
    DisposableEffect(activity) {
        if (activity == null) return@DisposableEffect onDispose { }
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                val next = PairingNotificationAccess.availability(context)
                notificationAvailability = next
                if (next == PairingNotificationPolicy.Availability.AVAILABLE) {
                    notificationDeniedHere = false
                }
            }
        }
        activity.lifecycle.addObserver(observer)
        onDispose { activity.lifecycle.removeObserver(observer) }
    }
    val allowPairingNotifications: () -> Unit = {
        if (notificationAvailability ==
            PairingNotificationPolicy.Availability.PERMISSION_REQUIRED &&
            !notificationDeniedHere
        ) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            // App/channel block or a permission the platform will no longer
            // ask for: the real system settings page is the honest action.
            PairingNotificationAccess.openSettings(context)
        }
    }
    val pairWithNotification: () -> Unit = {
        when (notificationAvailability) {
            PairingNotificationPolicy.Availability.AVAILABLE -> callbacks.onPairAdb()
            PairingNotificationPolicy.Availability.PERMISSION_REQUIRED -> {
                pairAfterNotificationGrant = true
                notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
            else -> {
                notificationDeniedHere = true
                callbacks.onPairAdb()
            }
        }
    }
    // Explicit app-data folder draft. RAM-only presentation input; the host
    // validates the backend-shape before it becomes a grantable root.
    var appDataDraft by remember { mutableStateOf("") }
    val adbActions = DeviceAccessPresentation.adbActions(state.adb, state.busy)
    // One direct next action rides the status row; the remaining honest
    // actions for the current state share one wrapping capsule row. The
    // action sets come from DeviceAccessPresentation, so busy work already
    // disables conflicting actions and no dead control is rendered.
    val adbPrimaryAction: Pair<String, () -> Unit>? = when {
        DeviceAccessAdbActionUi.STOP in adbActions ->
            stringResource(R.string.device_access_adb_stop) to callbacks.onStopAdbService
        DeviceAccessAdbActionUi.START in adbActions ->
            stringResource(R.string.device_access_adb_start) to callbacks.onStartAdbService
        DeviceAccessAdbActionUi.ENABLE in adbActions ->
            stringResource(R.string.device_access_adb_enable) to callbacks.onEnableAdb
        DeviceAccessAdbActionUi.PAIR in adbActions ->
            stringResource(R.string.device_access_adb_pair) to pairWithNotification
        // Pairing code form is open: submit rides next to the code field.
        else -> null
    }
    val adbCancelLabel = stringResource(R.string.device_access_adb_cancel_pairing)
    val adbDevOptionsLabel = stringResource(R.string.device_access_adb_open_developer_options)
    val adbForgetLabel = stringResource(R.string.device_access_adb_forget)
    val adbSecondaryActions: List<Pair<String, () -> Unit>> = listOfNotNull(
        if (DeviceAccessAdbActionUi.CANCEL_PAIRING in adbActions &&
            !DeviceAccessPresentation.adbShowsCodeField(state.adb)
        ) {
            adbCancelLabel to callbacks.onCancelPairing
        } else {
            null
        },
        if (DeviceAccessAdbActionUi.OPEN_DEVELOPER_OPTIONS in adbActions) {
            adbDevOptionsLabel to callbacks.onOpenDeveloperOptions
        } else {
            null
        },
        if (DeviceAccessAdbActionUi.FORGET in adbActions) {
            adbForgetLabel to { confirmForget = true }
        } else {
            null
        },
    )
    val accessibilityStatus = stringResource(
        DeviceAccessPresentation.accessibilityStatusRes(state.accessibility))
    val adbStatus = stringResource(DeviceAccessPresentation.adbStatusRes(state.adb))
    val rootStatus = stringResource(DeviceAccessPresentation.rootStatusRes(state.root))

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        FloeText(
            stringResource(R.string.device_access_intro),
            style = Floe.typography.metadata,
            color = colors.secondaryLabel,
        )

        // --------------------------------------------------- embedded ADB layer
        // The connection group leads the compact overview: the status row and
        // the enable/pair/start/stop controls stay reachable without scrolling
        // past capability prose or folder lists. The card keeps every status
        // row, control and inline validation; all pure explanations live in
        // the iOS-style footer below the card, in the same conditions and the
        // same reading order as the flat layout.
        FloeSettingsSectionCard(
            title = stringResource(R.string.device_access_adb_section),
            caption = {
                Column {
                    DeviceAccessPresentation.adbEffectiveUid(state.adb)?.let { uid ->
                        CaptionText(stringResource(R.string.device_access_adb_state_uid, uid))
                    }
                    // State-specific guidance, never a fabricated success. While
                    // the pairing session is open the notification text explains
                    // the inline path; the manual/split fallback keeps the real
                    // system action wording.
                    when (val adb = state.adb) {
                        is DeviceAccessAdbUi.PairRequired -> if (adb.pairingSessionOpen) {
                            when (notificationAvailability) {
                                PairingNotificationPolicy.Availability.AVAILABLE -> CaptionText(
                                    stringResource(R.string.device_access_adb_pair_open_hint),
                                    Modifier.padding(top = 2.dp),
                                )
                                PairingNotificationPolicy.Availability.UNSUPPORTED -> Unit
                                else -> CaptionText(
                                    stringResource(R.string.device_access_pairing_notification_off),
                                    Modifier.padding(top = 2.dp),
                                )
                            }
                        }
                        DeviceAccessAdbUi.RestartRequired -> CaptionText(
                            stringResource(R.string.device_access_adb_restart_hint),
                            Modifier.padding(top = 2.dp),
                        )
                        DeviceAccessAdbUi.Revoked -> CaptionText(
                            stringResource(R.string.device_access_adb_revoked_hint),
                            Modifier.padding(top = 2.dp),
                        )
                        else -> Unit
                    }
                    if (DeviceAccessAdbActionUi.PAIR in adbActions) {
                        CaptionText(
                            stringResource(R.string.device_access_adb_pair_hint),
                            Modifier.padding(top = 2.dp),
                        )
                    }
                    if (!state.pairingSupported) {
                        CaptionText(
                            stringResource(R.string.device_access_pairing_unsupported),
                            Modifier.padding(top = 2.dp),
                        )
                        if (state.usbBootstrapExported) {
                            CaptionText(
                                stringResource(R.string.device_access_usb_bootstrap_copied),
                                Modifier.padding(top = 2.dp),
                            )
                        }
                    }
                    // Static implementation explanation lives behind the opened
                    // details fold; live identity and next-step guidance above
                    // stay visible. Same string, same conditions as the flat
                    // layout.
                    CaptionDetailsToggle(adbDetailsOpen) { adbDetailsOpen = !adbDetailsOpen }
                    if (adbDetailsOpen) {
                        CaptionText(
                            stringResource(R.string.device_access_adb_intro),
                            Modifier.padding(top = 2.dp),
                        )
                    }
                }
            },
        ) {
            StatusActionRow(
                status = adbStatus,
                actionLabel = adbPrimaryAction?.first,
                onAction = adbPrimaryAction?.second,
            )
            state.error?.takeIf { it.section == DeviceAccessErrorSectionUi.ADB }?.let { error ->
                DeviceAccessErrorRows(error, showErrorDetails,
                    onToggleDetails = { showErrorDetails = !showErrorDetails },
                    onRefresh = callbacks.onRefresh)
            }
            if (!state.pairingSupported) {
                FloeActionRow(
                    label = stringResource(R.string.device_access_usb_bootstrap),
                    onClick = callbacks.onExportUsbBootstrap,
                    enabled = state.busy == DeviceAccessBusyUi.NONE,
                )
            }
            // Pairing port + code entry: ephemeral RAM-only caller state.
            if (DeviceAccessPresentation.adbShowsCodeField(state.adb)) {
                when (state.pairingDiscovery) {
                    DeviceAccessPairingDiscoveryUi.DISCOVERING ->
                        FloeSectionRow(title = {
                            FloeText(
                                stringResource(R.string.device_access_pairing_port_searching),
                                style = Floe.typography.metadata,
                                color = colors.secondaryLabel,
                            )
                        })
                    DeviceAccessPairingDiscoveryUi.FOUND ->
                        FloeValueRow(
                            stringResource(R.string.device_access_pairing_port_label),
                            state.pairingPort,
                        )
                    else -> FloeSectionRow(title = {
                        FloePlainFormField(
                            label = stringResource(R.string.device_access_pairing_port_label),
                            value = state.pairingPort,
                            onValueChange = { raw ->
                                val digits = raw.filter { it.isDigit() }.take(5)
                                callbacks.onPairingPortChange(digits)
                            },
                            keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                                keyboardType = androidx.compose.ui.text.input.KeyboardType.Number,
                            ),
                            enabled = state.busy == DeviceAccessBusyUi.NONE,
                        )
                    })
                }
                FloeActionRow(
                    label = stringResource(R.string.device_access_pairing_port_find),
                    onClick = callbacks.onDiscoverPairingPort,
                    enabled = state.busy == DeviceAccessBusyUi.NONE &&
                        state.pairingDiscovery != DeviceAccessPairingDiscoveryUi.DISCOVERING,
                )
                FloeSecureFormField(
                    label = stringResource(R.string.device_access_adb_code_label),
                    value = pairingCode,
                    onValueChange = { onPairingCodeChange(DeviceAccessPairingCode.sanitize(it)) },
                    revealed = revealPairingCode,
                    onRevealedChange = { revealPairingCode = it },
                    revealOnLabel = stringResource(R.string.notes_pdf_unlock_show),
                    revealOffLabel = stringResource(R.string.notes_pdf_unlock_hide),
                )
                // Submit and cancel share one wrapping capsule row instead of
                // stacking full-width button rows above the keyboard.
                FlowRow(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    PageCapsuleButton(
                        stringResource(R.string.device_access_adb_code_submit),
                        onClick = {
                            if (DeviceAccessPairingCode.canSubmit(pairingCode) &&
                                DeviceAccessPresentation.pairingPortValid(state.pairingPort)
                            ) {
                                callbacks.onSubmitPairingCode(pairingCode)
                                onPairingCodeChange("")
                            }
                        },
                        enabled = DeviceAccessPresentation.adbSubmitEnabled(
                            pairingCode, state.pairingPort, state.adb, state.busy),
                    )
                    if (DeviceAccessAdbActionUi.CANCEL_PAIRING in adbActions) {
                        PageCapsuleButton(
                            stringResource(R.string.device_access_adb_cancel_pairing),
                            onClick = callbacks.onCancelPairing,
                        )
                    }
                }
                // Inline validation stays adjacent to the field while the
                // partial code is on screen: it is a transient error state,
                // not a group explanation.
                if (pairingCode.isNotEmpty() && !DeviceAccessPairingCode.canSubmit(pairingCode)) {
                    FloeSectionRow(title = {
                        FloeText(
                            stringResource(R.string.device_access_adb_code_invalid),
                            style = Floe.typography.metadata,
                            color = colors.destructive,
                        )
                    })
                }
            }
            when (val adb = state.adb) {
                is DeviceAccessAdbUi.PairRequired -> if (adb.pairingSessionOpen) {
                    PairingNotificationAction(
                        availability = notificationAvailability,
                        permissionDenied = notificationDeniedHere,
                        onAllow = allowPairingNotifications,
                    )
                }
                else -> Unit
            }
            // Remaining actions the current state genuinely offers share one
            // wrapping capsule row (cancel / developer options / forget).
            if (adbSecondaryActions.isNotEmpty()) {
                FlowRow(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    adbSecondaryActions.forEach { (label, onClick) ->
                        PageCapsuleButton(label, onClick)
                    }
                }
            }
        }

        // ---------------------------------------------------------- root layer
        // Default-off and separate from ADB. One status row carries the direct
        // next action (check grant) in its trailing slot; the enable hint
        // belongs to the switch and rides inside its 48dp cell; the risk
        // disclosure stays in the card footer.
        val rootUid = DeviceAccessPresentation.rootEffectiveUid(state.root)
        FloeSettingsSectionCard(
            title = stringResource(R.string.device_access_root_section),
            caption = {
                Column {
                    rootUid?.let { uid ->
                        CaptionText(stringResource(R.string.device_access_root_uid, uid))
                    }
                    CaptionText(stringResource(R.string.device_access_root_intro))
                }
            },
        ) {
            StatusActionRow(
                status = rootStatus,
                actionLabel = if (DeviceAccessPresentation.rootCheckVisible(state.root)) {
                    stringResource(R.string.device_access_root_check)
                } else {
                    null
                },
                onAction = if (DeviceAccessPresentation.rootCheckVisible(state.root)) {
                    { confirmRootCheck = true }
                } else {
                    null
                },
                actionEnabled = state.busy != DeviceAccessBusyUi.ROOT_CHECK &&
                    state.busy != DeviceAccessBusyUi.ROOT_ENABLE,
            )
            FloeSectionRow(
                title = {
                    FloeText(
                        stringResource(R.string.device_access_root_enable),
                        style = Floe.typography.body,
                        color = colors.label,
                    )
                },
                trailing = {
                    val checked = DeviceAccessPresentation.rootSwitchChecked(state.root)
                    FloeInlineSwitch(
                        checked = checked,
                        onCheckedChange = { enabled ->
                            if (DeviceAccessPresentation.rootSwitchEnabled(state.root)) {
                                callbacks.onEnableRoot(enabled)
                            }
                        },
                        enabled = DeviceAccessPresentation.rootSwitchEnabled(state.root) &&
                            state.busy != DeviceAccessBusyUi.ROOT_ENABLE,
                        description = stringResource(R.string.device_access_root_enable),
                    )
                },
                caption = stringResource(R.string.device_access_root_enable_hint),
            )
        }

        // ------------------------------------------------- accessibility layer
        // One status row carries the honest system action in its trailing slot.
        // The disclosure stays visible; the limits list rides behind an opened
        // details fold — identical text and conditions, nothing is dropped.
        FloeSettingsSectionCard(
            title = stringResource(R.string.device_access_accessibility_section),
            caption = {
                Column {
                    if (state.accessibility == DeviceAccessAccessibilityUi.Restricted) {
                        CaptionText(
                            stringResource(R.string.device_access_accessibility_restricted_hint),
                        )
                    }
                    CaptionText(stringResource(R.string.device_access_accessibility_disclosure))
                    CaptionDetailsToggle(accessibilityLimitsOpen) {
                        accessibilityLimitsOpen = !accessibilityLimitsOpen
                    }
                    if (accessibilityLimitsOpen) {
                        CaptionText(
                            stringResource(R.string.device_access_boundary_title),
                            Modifier.padding(top = 2.dp),
                        )
                        BoundaryLine(stringResource(R.string.device_access_boundary_nodes))
                        BoundaryLine(stringResource(R.string.device_access_boundary_secrets))
                        BoundaryLine(stringResource(R.string.device_access_boundary_actions))
                        BoundaryLine(stringResource(R.string.device_access_boundary_screenshots))
                    }
                }
            },
        ) {
            StatusActionRow(
                status = accessibilityStatus,
                actionLabel = stringResource(R.string.device_access_open_settings),
                onAction = callbacks.onOpenAccessibilitySettings,
            )
        }

        // --------------------------------------------------- active task card
        // Control rows stay in the card; the explanations for this card's
        // current branch move to the iOS-style section footer (card caption)
        // or the acting row's own caption — same strings, same conditions,
        // no interactive affordance leaves the card.
        val task = state.activeTask
        val taskArmed = state.taskControl == DeviceAccessTaskControlUi.ARMED
        FloeSettingsSectionCard(
            title = stringResource(R.string.device_access_active_section),
            caption = when {
                task == null -> null
                taskArmed -> (@Composable {
                    CaptionText(stringResource(R.string.device_access_take_over_hint))
                })
                else -> (@Composable {
                    Column {
                        CaptionText(
                            stringResource(
                                if (state.taskControl == DeviceAccessTaskControlUi.STOPPED) {
                                    R.string.device_access_task_stopped
                                } else {
                                    R.string.device_access_task_not_allowed
                                },
                            ),
                        )
                        if (!DeviceAccessPresentation.packageTargetsValid(state)) {
                            CaptionText(
                                stringResource(R.string.device_access_select_apps_first),
                                Modifier.padding(top = 2.dp),
                            )
                        }
                    }
                })
            },
        ) {
            if (task == null) {
                FloeSectionRow(title = {
                    FloeText(
                        stringResource(R.string.device_access_active_none),
                        style = Floe.typography.body,
                        color = colors.secondaryLabel,
                    )
                })
            } else {
                FloeSectionRow(title = {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                        FloeText(
                            task.title,
                            style = Floe.typography.body,
                            color = colors.label,
                            modifier = Modifier.weight(1f),
                            maxLines = 2,
                        )
                        FloeBadgePill(
                            stringResource(DeviceAccessPresentation.taskPhaseRes(task.phase)),
                            tone = when (task.phase) {
                                DeviceAccessTaskPhaseUi.TAKEN_OVER -> FloeBadgeTone.SECONDARY
                                DeviceAccessTaskPhaseUi.STOPPING -> FloeBadgeTone.PENDING
                                DeviceAccessTaskPhaseUi.WAITING_FOR_USER -> FloeBadgeTone.PENDING
                                DeviceAccessTaskPhaseUi.RUNNING -> FloeBadgeTone.ACCENT
                            },
                        )
                    }
                })
                if (taskArmed) {
                    // Stop and take over are sibling controls: one wrapping
                    // capsule row, each keeping its own honest enabled state.
                    FlowRow(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        PageCapsuleButton(
                            stringResource(R.string.device_access_stop_task),
                            onClick = callbacks.onStopActiveTask,
                            enabled = DeviceAccessPresentation.canStopTask(state),
                        )
                        PageCapsuleButton(
                            stringResource(R.string.device_access_take_over),
                            onClick = callbacks.onTakeOverActiveTask,
                            enabled = DeviceAccessPresentation.canTakeOverTask(state),
                        )
                    }
                } else {
                    FloeSectionRow(title = {
                        FloeCapsuleButton(
                            stringResource(R.string.device_access_allow_task),
                            onClick = callbacks.onArmPhoneControl,
                            enabled = DeviceAccessPresentation.canArmPhoneControl(state),
                            prominent = true,
                        )
                    })
                }
            }
        }

        FloeSettingsSectionCard(
            title = stringResource(R.string.device_access_targets_section),
            caption = if (state.targets.selectedPackages.isEmpty()) {
                @Composable { CaptionText(stringResource(R.string.device_access_select_apps_first)) }
            } else {
                null
            },
        ) {
            FloeValueRow(
                title = stringResource(R.string.device_access_targets_choose),
                value = stringResource(R.string.device_access_targets_count, state.targets.selectedPackages.size),
                onClick = { appChooserOpen = true },
            )
        }

        FloeSettingsSectionCard(
            title = stringResource(R.string.phone_automation_title),
            // While the unlock editor is expanded its explanation reads as the
            // card footer instead of stealing a full grouped row.
            caption = if (confirmUnlock) {
                @Composable { CaptionText(stringResource(R.string.phone_automation_unlock_hint)) }
            } else {
                null
            },
        ) {
            // Each switch keeps its own hint inside the same 48dp target cell:
            // the caption belongs to the control, not to a second row.
            FloeSectionRow(
                title = { FloeText(stringResource(R.string.phone_automation_automatic)) },
                trailing = {
                    FloeInlineSwitch(state.automaticPhoneControl,
                        { if (it) confirmAutomatic = true else callbacks.onAutomaticControlChange(false) },
                        description = stringResource(R.string.phone_automation_automatic))
                },
                caption = stringResource(R.string.phone_automation_automatic_hint),
            )
            FloeSectionRow(title = { FloeText(stringResource(R.string.phone_automation_unlock)) }, trailing = {
                FloeInlineSwitch(state.autoUnlock,
                    { if (it) confirmUnlock = true else callbacks.onAutoUnlockChange(false) },
                    description = stringResource(R.string.phone_automation_unlock))
            })
            if (confirmUnlock) {
                FloeSecureFormField(label = stringResource(R.string.phone_automation_credential),
                    value = unlockDraft, onValueChange = { unlockDraft = it.take(64) },
                    revealed = revealUnlock, onRevealedChange = { revealUnlock = it },
                    revealOnLabel = stringResource(R.string.notes_pdf_unlock_show),
                    revealOffLabel = stringResource(R.string.notes_pdf_unlock_hide))
                FloeActionRow(label = stringResource(R.string.phone_automation_consent_unlock),
                    enabled = unlockDraft.isNotEmpty() || state.unlockConfigured,
                    onClick = {
                        if (unlockDraft.isNotEmpty()) callbacks.onSaveUnlockCredential(unlockDraft)
                        else callbacks.onAutoUnlockChange(true)
                        unlockDraft = ""; revealUnlock = false; confirmUnlock = false
                    })
                FloeActionRow(label = stringResource(R.string.cancel), onClick = {
                    unlockDraft = ""; revealUnlock = false; confirmUnlock = false
                })
            }
            if (state.unlockConfigured) FloeActionRow(
                label = stringResource(R.string.phone_automation_forget),
                onClick = callbacks.onForgetUnlockCredential)
            FloeSectionRow(title = { FloeText(stringResource(R.string.phone_automation_floating)) }, trailing = {
                FloeInlineSwitch(state.floatingControls, callbacks.onFloatingControlsChange,
                    description = stringResource(R.string.phone_automation_floating))
            })
        }

        // ------------------------------------------------------ file ceilings
        // Progressive disclosure (N08): one count row per folder class opens
        // the child sheet with the per-folder switches, so the phone overview
        // no longer carries six permanent shared rows plus six permanent
        // system rows. The write ceiling stays here as the visible master
        // switch because it reads the current selection state.
        val sharedSelected = sharedRoots.count { it.id in state.targets.selectedRootIds }
        val systemSelected = systemRoots.count { it.id in state.targets.selectedRootIds }
        FloeSettingsSectionCard(
            title = stringResource(R.string.device_access_folders_section),
            caption = {
                Column {
                    CaptionText(stringResource(R.string.device_access_roots_intro))
                    if (sharedRoots.isEmpty()) {
                        CaptionText(
                            stringResource(R.string.device_access_roots_empty),
                            Modifier.padding(top = 2.dp),
                        )
                    }
                }
            },
        ) {
            FloeValueRow(
                title = stringResource(R.string.device_access_folders_shared),
                value = stringResource(
                    R.string.device_access_folders_selected_count,
                    sharedSelected,
                    sharedRoots.size,
                ),
                onClick = { sharedFoldersOpen = true },
            )
            FloeValueRow(
                title = stringResource(R.string.device_access_system_roots_section),
                value = stringResource(
                    R.string.device_access_folders_selected_count,
                    systemSelected,
                    systemRoots.size,
                ),
                onClick = { systemFoldersOpen = true },
            )
            FloeSectionRow(
                title = {
                    FloeText(
                        stringResource(R.string.device_access_file_writes),
                        style = Floe.typography.body,
                        color = colors.label,
                    )
                },
                trailing = {
                    FloeInlineSwitch(
                        checked = state.targets.fileWritesAllowed,
                        onCheckedChange = callbacks.onFileWritesChange,
                        description = stringResource(R.string.device_access_file_writes),
                        enabled = state.busy == DeviceAccessBusyUi.NONE &&
                            DeviceAccessPresentation.fileWritesToggleEnabled(state.targets),
                    )
                },
                caption = stringResource(R.string.device_access_file_writes_hint),
            )
        }

        // Explicit other-app data folders: Root must be the live service; the
        // root service resolves the path and reports OS/SELinux/unlock truth.
        // These stay permanent rows: each one is an explicit user-typed grant,
        // not a preset list, and the add field belongs next to them.
        val appDataAvailable = state.targets.appDataRootsAvailable
        FloeSettingsSectionCard(
            title = stringResource(R.string.device_access_app_data_section),
            caption = if (appDataAvailable) {
                @Composable { CaptionText(stringResource(R.string.device_access_app_data_hint)) }
            } else {
                null
            },
        ) {
            if (appDataAvailable) {
                state.targets.fileRoots
                    .filter { it.kind == DeviceAccessFileRootKindUi.APP_DATA }
                    .forEach { root -> FileRootRow(root, state, callbacks) }
                // The format example belongs to the input above it: it rides
                // in the same cell instead of adding a grouped row.
                FloeSectionRow(
                    title = {
                        FloePlainFormField(
                            label = stringResource(R.string.device_access_app_data_add_label),
                            value = appDataDraft,
                            onValueChange = { raw ->
                                appDataDraft = raw
                                    .filter { it != '\n' && it != '\r' }
                                    .take(900)
                            },
                            enabled = state.busy == DeviceAccessBusyUi.NONE,
                        )
                    },
                    caption = stringResource(R.string.device_access_app_data_example),
                )
                FloeActionRow(
                    label = stringResource(R.string.device_access_app_data_add),
                    onClick = {
                        callbacks.onAddAppDataRoot(appDataDraft)
                        appDataDraft = ""
                    },
                    enabled = DeviceAccessPresentation.appDataFolderAddEnabled(state) &&
                        appDataDraft.isNotBlank(),
                )
            } else {
                // Without a live Root service the actionable requirement is
                // the whole message; the full path/SELinux explanation appears
                // with the add field once Root is running.
                FloeSectionRow(title = {
                    CaptionText(stringResource(R.string.device_access_app_data_requires_root))
                })
            }
        }

        // The package ceiling is separate from file scopes: enabling it never
        // adds a file root, and enabling Root never enables it. Inside the
        // ceiling, admitted tasks auto-pass the repetitive per-call approval
        // for force-stop/install/uninstall of ordinary third-party packages;
        // Floe itself and system packages stay hard-refused, and the revoke
        // row below is the visible stop for everything live right now.
        FloeSettingsSectionCard(
            title = stringResource(R.string.device_access_management_section),
            caption = {
                Column {
                    // The full permission/risk wording for both ceiling
                    // switches stays one tap away in the opened details fold;
                    // the switch labels above name what each grant allows.
                    CaptionDetailsToggle(managementDetailsOpen) {
                        managementDetailsOpen = !managementDetailsOpen
                    }
                    if (managementDetailsOpen) {
                        FloeText(
                            stringResource(R.string.device_access_package_management),
                            style = Floe.typography.body,
                            color = colors.label,
                            modifier = Modifier.padding(top = 2.dp),
                        )
                        CaptionText(stringResource(R.string.device_access_package_management_hint))
                        FloeText(
                            stringResource(R.string.device_access_advanced_master),
                            style = Floe.typography.body,
                            color = colors.label,
                            modifier = Modifier.padding(top = 6.dp),
                        )
                        CaptionText(stringResource(R.string.device_access_advanced_master_hint))
                    }
                }
            },
        ) {
            FloeSectionRow(
                title = {
                    FloeText(
                        stringResource(R.string.device_access_package_management),
                        style = Floe.typography.body,
                        color = colors.label,
                    )
                },
                trailing = {
                    FloeInlineSwitch(
                        checked = state.targets.packageManagementAllowed,
                        onCheckedChange = callbacks.onPackageManagementChange,
                        description = stringResource(R.string.device_access_package_management),
                        enabled = state.busy == DeviceAccessBusyUi.NONE,
                    )
                },
            )
            // The shared advanced-system master. It is intentionally one
            // switch: the per-name allowed list and the target chooser below
            // are the granular controls; the reserved permission/AppOps/
            // settings names get no placeholder rows.
            FloeSectionRow(
                title = {
                    FloeText(
                        stringResource(R.string.device_access_advanced_master),
                        style = Floe.typography.body,
                        color = colors.label,
                    )
                },
                trailing = {
                    FloeInlineSwitch(
                        checked = state.targets.advancedSystemManagementAllowed,
                        onCheckedChange = callbacks.onAdvancedSystemChange,
                        description = stringResource(R.string.device_access_advanced_master),
                        enabled = state.busy == DeviceAccessBusyUi.NONE,
                    )
                },
            )
            if (state.targets.advancedSystemManagementAllowed) {
                FloeActionRow(
                    label = stringResource(R.string.device_access_advanced_categories),
                    onClick = { advancedToolsChooserOpen = true },
                    enabled = state.busy == DeviceAccessBusyUi.NONE,
                    trailing = {
                        FloeText(
                            stringResource(
                                R.string.device_access_advanced_categories_count,
                                state.targets.advancedSystemAllowedTools.intersect(
                                    DeviceAccessToolCatalog.SHIPPED_ADVANCED_TOOLS).size,
                            ),
                            style = Floe.typography.metadata,
                            color = colors.secondaryLabel,
                        )
                    },
                )
                FloeActionRow(
                    label = stringResource(R.string.device_access_advanced_choose_targets),
                    onClick = { advancedChooserOpen = true },
                    enabled = state.busy == DeviceAccessBusyUi.NONE,
                    trailing = {
                        FloeText(
                            stringResource(
                                R.string.device_access_advanced_targets_count,
                                state.targets.selectedAdvancedSystemTargets.size,
                            ),
                            style = Floe.typography.metadata,
                            color = colors.secondaryLabel,
                        )
                    },
                )
                if (state.targets.appOpsUidScopeAllowed &&
                    !state.targets.appOpsUidScopeSupported
                ) {
                    FloeText(
                        stringResource(R.string.device_access_appops_uid_scope_unsupported),
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                    )
                }
            }
            // Compact entry to the closed system-settings editor. It renders
            // only when the real ceiling (management + advanced master +
            // system.settings.write) is enabled, so it is never a dead
            // control; the opened sheet re-reads the stored values first.
            if (state.systemSettings.enabled) {
                FloeActionRow(
                    label = stringResource(R.string.device_access_system_settings_entry),
                    onClick = {
                        callbacks.onSystemSettingsRefresh()
                        systemSettingsOpen = true
                    },
                    enabled = state.busy == DeviceAccessBusyUi.NONE,
                )
            }
            // Progressive-disclosure staging: one count row opens the child
            // sheet carrying the stage action, the readable APK rows and the
            // opened path/digest diagnostics. Exact staged IDs and the remove
            // callback are unchanged.
            FloeValueRow(
                title = stringResource(R.string.device_access_stage_apks),
                value = stringResource(
                    R.string.device_access_staged_count, state.targets.stagedApks.size),
                onClick = { stagedApksOpen = true },
            )
            FloeActionRow(
                label = stringResource(R.string.device_access_revoke_grants),
                onClick = callbacks.onRevokeSystemGrants,
                enabled = state.busy == DeviceAccessBusyUi.NONE,
            )
            FloeActionRow(
                label = stringResource(R.string.device_access_permission_ops_open),
                onClick = { permissionOpsOpen = true },
                enabled = state.busy == DeviceAccessBusyUi.NONE &&
                    permissionOpsInspector != null &&
                    state.targets.packageManagementAllowed &&
                    state.targets.advancedSystemManagementAllowed &&
                    state.targets.selectedAdvancedSystemTargets.isNotEmpty(),
            )
        }

        // ------------------------------------------------------ screen content
        FloeSettingsSectionCard(title = stringResource(R.string.device_access_screen_section)) {
            FloeSectionRow(title = {
                Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                    FloeText(
                        stringResource(R.string.device_access_screen_hint),
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                    )
                    Spacer(Modifier.height(8.dp))
                    // Scope belongs to a live task. With no active task the
                    // page shows the honest requirement instead of an enabled
                    // control that silently does nothing.
                    if (DeviceAccessPresentation.screenScopeEnabled(state)) {
                        FloeSegmented(
                            options = listOf(
                                stringResource(R.string.device_access_screen_off),
                                stringResource(R.string.device_access_screen_task),
                                stringResource(R.string.device_access_screen_until_stopped),
                            ),
                            selectedIndex = when (state.screenScope) {
                                DeviceAccessScreenScopeUi.OFF -> 0
                                DeviceAccessScreenScopeUi.CURRENT_TASK -> 1
                                DeviceAccessScreenScopeUi.UNTIL_STOPPED -> 2
                            },
                            onSelect = { index ->
                                callbacks.onScreenScopeChange(
                                    when (index) {
                                        1 -> DeviceAccessScreenScopeUi.CURRENT_TASK
                                        2 -> DeviceAccessScreenScopeUi.UNTIL_STOPPED
                                        else -> DeviceAccessScreenScopeUi.OFF
                                    },
                                )
                            },
                        )
                    } else {
                        FloeText(
                            stringResource(R.string.device_access_screen_requires_task),
                            style = Floe.typography.metadata,
                            color = colors.secondaryLabel,
                        )
                    }
                }
            })
            if (DeviceAccessPresentation.wholeScreenConsentVisible(state)) {
                FloeSectionRow(
                    title = {
                        FloeText(
                            stringResource(R.string.device_access_whole_screen_capture),
                            style = Floe.typography.body,
                            color = colors.label,
                        )
                    },
                    trailing = {
                        FloeInlineSwitch(
                            checked = state.targets.wholeScreenConsent,
                            onCheckedChange = callbacks.onWholeScreenConsentChange,
                            description = stringResource(R.string.device_access_whole_screen_capture),
                            enabled = state.busy == DeviceAccessBusyUi.NONE,
                        )
                    },
                    // The consent explanation is this control's own caption —
                    // it rides inside the switch's 48dp cell.
                    caption = stringResource(
                        if (DeviceAccessPresentation.wholeScreenConsentRequired(state)) {
                            R.string.device_access_whole_screen_required
                        } else {
                            R.string.device_access_whole_screen_hint
                        },
                    ),
                )
            }
        }

        // --------------------------------------------------------- typed error
        state.error?.takeIf { it.section != DeviceAccessErrorSectionUi.ADB }?.let { error ->
            FloeSettingsSectionCard(title = null) {
                DeviceAccessErrorRows(error, showErrorDetails,
                    onToggleDetails = { showErrorDetails = !showErrorDetails },
                    onRefresh = callbacks.onRefresh)
            }
        }
    }

    if (confirmAutomatic) {
        FloeConfirmDialog(
            title = stringResource(R.string.phone_automation_automatic),
            message = stringResource(R.string.phone_automation_automatic_hint),
            confirmLabel = stringResource(R.string.phone_automation_allow),
            dismissLabel = stringResource(R.string.cancel),
            onConfirm = { confirmAutomatic = false; callbacks.onAutomaticControlChange(true) },
            onDismiss = { confirmAutomatic = false })
    }
    if (confirmForget) {
        FloeConfirmDialog(
            title = stringResource(R.string.device_access_adb_forget_title),
            message = stringResource(R.string.device_access_adb_forget_message),
            confirmLabel = stringResource(R.string.device_access_adb_forget),
            dismissLabel = stringResource(R.string.cancel),
            onConfirm = {
                confirmForget = false
                callbacks.onForgetAdbPairing()
            },
            onDismiss = { confirmForget = false },
        )
    }
    if (confirmRootCheck) {
        FloeConfirmDialog(
            title = stringResource(R.string.device_access_root_check_title),
            message = stringResource(R.string.device_access_root_check_message),
            confirmLabel = stringResource(R.string.device_access_root_check),
            dismissLabel = stringResource(R.string.cancel),
            onConfirm = {
                confirmRootCheck = false
                callbacks.onCheckRootGrant()
            },
            onDismiss = { confirmRootCheck = false },
        )
    }
}

@Composable
private fun SectionScope.DeviceAccessErrorRows(
    error: DeviceAccessUiError,
    showDetails: Boolean,
    onToggleDetails: () -> Unit,
    onRefresh: () -> Unit,
) {
    FloeSectionRow(title = {
        FloeStatusLine(icon = FloeIcons.WarningTriangle, text = error.message,
            color = Floe.colors.destructive)
    })
    DeviceAccessPresentation.errorCode(error)?.let { code ->
        FloeActionRow(label = stringResource(
            if (showDetails) R.string.device_access_error_hide_details
            else R.string.device_access_error_details), onClick = onToggleDetails)
        if (showDetails) {
            FloeSectionRow(title = {
                FloeText(code, style = Floe.typography.evidence, color = Floe.colors.secondaryLabel)
            })
        }
    }
    FloeActionRow(label = stringResource(R.string.device_access_retry), onClick = onRefresh)
}

@Composable
private fun io.github.robinpcrd.cupertino.section.SectionScope.FileRootRow(
    root: DeviceAccessFileRootUi,
    state: DeviceAccessPresentationState,
    callbacks: DeviceAccessCallbacks,
) {
    val title = if (root.label.isNotEmpty()) root.label else stringResource(root.labelRes)
    FloeSectionRow(
        title = {
            FloeText(
                title,
                style = Floe.typography.body,
                color = Floe.colors.label,
                maxLines = 2,
            )
        },
        trailing = {
            FloeInlineSwitch(
                checked = root.selected,
                onCheckedChange = { checked ->
                    val next = state.targets.selectedRootIds.toMutableSet()
                    if (checked) next += root.id else next -= root.id
                    callbacks.onFileRootsChange(next)
                },
                description = title,
                enabled = state.busy == DeviceAccessBusyUi.NONE,
            )
        },
    )
}

@Composable
private fun BoundaryLine(text: String) {
    FloeText(
        text = "• $text",
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
        modifier = Modifier.padding(top = 2.dp),
    )
}

/**
 * The page's shared explanation wording: metadata role + secondaryLabel on
 * the caller-supplied modifier slot. Used inside card captions (iOS grouped
 * footers) and stacked status lines; pure text, never a control, never a
 * touch target.
 */
@Composable
private fun CaptionText(text: String, modifier: Modifier = Modifier) {
    FloeText(
        text,
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
        modifier = modifier,
    )
}

/**
 * Accent "Details / Hide details" disclosure used inside card captions. Lives
 * in the footer (not a section row) so explanatory prose opens in place
 * without adding permanent rows; keeps the shared 48dp hit floor.
 */
@Composable
private fun CaptionDetailsToggle(open: Boolean, onToggle: () -> Unit) {
    val label = stringResource(
        if (open) R.string.device_access_details_hide
        else R.string.device_access_details
    )
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = FloeLayout.MinimumTarget)
            .clickable(onClick = onToggle, role = Role.Button)
            .semantics { contentDescription = label },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        FloeText(
            label,
            style = Floe.typography.metadata,
            color = Floe.colors.accent,
            maxLines = 1,
        )
        IconGlyph(
            icon = if (open) FloeIcons.ChevronUp else FloeIcons.ChevronDown,
            tint = Floe.colors.accent,
            size = 12.dp,
        )
    }
}

/**
 * Compact capsule for dense phone rows: the same Floe capsule shape/fill and
 * the shared 48dp floor as the wide [FloeCapsuleButton], without the baked-in
 * full-width chrome, so sibling actions can share one wrapping row.
 */
@Composable
private fun PageCapsuleButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    Box(
        modifier = modifier
            .heightIn(min = FloeLayout.MinimumTarget)
            .clip(FloeLayout.SidebarSelectionShape)
            .background(Floe.colors.fillTertiary)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics {
                contentDescription = label
                if (!enabled) disabled()
            }
            .padding(horizontal = 12.dp, vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        FloeText(
            label,
            style = Floe.typography.body,
            color = if (enabled) Floe.colors.label else Floe.colors.secondaryLabel,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * One status cell with the capability's direct next action in the trailing
 * slot: the phone scan reads status → action without a separate full-width
 * button row. The label/value wording is identical to the old status row.
 */
@Composable
private fun SectionScope.StatusActionRow(
    status: String,
    actionLabel: String?,
    onAction: (() -> Unit)?,
    actionEnabled: Boolean = true,
) {
    val statusLabel = stringResource(R.string.device_access_status_label)
    FloeSectionRow(title = {
        Row(
            Modifier
                .fillMaxWidth()
                .semantics { contentDescription = "$statusLabel: $status" },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Column(Modifier.weight(1f)) {
                FloeText(
                    statusLabel,
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                FloeText(
                    status,
                    style = Floe.typography.body,
                    color = Floe.colors.label,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (actionLabel != null && onAction != null) {
                PageCapsuleButton(actionLabel, onAction, enabled = actionEnabled)
            }
        }
    })
}

/**
 * Staged-APK detail sheet: the phone overview carries only a count row; the
 * stage action, the readable per-APK rows and the opened path/digest
 * diagnostics live here. Rows show file identity (name, size, package), never
 * raw internal directories; the exact staged path and SHA-256 stay available
 * behind each row's opened details. Remove forwards the EXACT stagedId
 * through the existing callback.
 */
@Composable
private fun DeviceAccessStagedApksSheet(
    visible: Boolean,
    stagedApks: List<DeviceAccessStagedApkUi>,
    enabled: Boolean,
    onStageClick: () -> Unit,
    onRemove: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    if (!visible) return
    val config = LocalConfiguration.current
    val compact = FloeLayout.usesCompactNavigation(
        config.screenWidthDp.toFloat(), config.smallestScreenWidthDp.toFloat(),
    )
    var expandedIds by remember { mutableStateOf(setOf<String>()) }
    val context = LocalContext.current
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
                        stringResource(R.string.device_access_stage_apks),
                        style = Floe.typography.section,
                        modifier = Modifier.weight(1f),
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    PageCapsuleButton(
                        stringResource(R.string.done),
                        onClick = onDismiss,
                    )
                }
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    PageCapsuleButton(
                        stringResource(R.string.device_access_stage_apks),
                        onClick = onStageClick,
                        enabled = enabled,
                    )
                    if (stagedApks.isNotEmpty()) {
                        FloeText(
                            stringResource(R.string.device_access_staged_count, stagedApks.size),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                }
                if (stagedApks.isEmpty()) {
                    FloeText(
                        stringResource(R.string.device_access_staged_empty),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                    )
                } else {
                    LazyColumn(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 16.dp)) {
                        items(stagedApks, key = { it.stagedId }) { apk ->
                            val expanded = apk.stagedId in expandedIds
                            StagedApkRow(
                                apk = apk,
                                subtitle = stagedApkSubtitle(context, apk),
                                expanded = expanded,
                                enabled = enabled,
                                onToggleDiagnostics = {
                                    expandedIds = if (expanded) {
                                        expandedIds - apk.stagedId
                                    } else {
                                        expandedIds + apk.stagedId
                                    }
                                },
                                onRemove = { onRemove(apk.stagedId) },
                            )
                        }
                    }
                }
            }
        }
    }
}

/** One staged-APK row: readable identity plus opened path/digest diagnostics. */
@Composable
private fun StagedApkRow(
    apk: DeviceAccessStagedApkUi,
    subtitle: String,
    expanded: Boolean,
    enabled: Boolean,
    onToggleDiagnostics: () -> Unit,
    onRemove: () -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(Floe.colors.sectionCardSurface)
            .clickable(onClick = onToggleDiagnostics, role = Role.Button)
            .heightIn(min = 52.dp)
            .padding(horizontal = 12.dp, vertical = 4.dp),
    ) {
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Column(Modifier.weight(1f)) {
                FloeText(
                    // Service-adopted entries record their full staged path;
                    // the identity line shows the file name only. The exact
                    // path stays in the opened diagnostics below.
                    apk.fileName.substringAfterLast('/'),
                    style = Floe.typography.body,
                    color = Floe.colors.label,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                FloeText(
                    subtitle,
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            PageCapsuleButton(
                stringResource(R.string.device_access_staged_remove),
                onClick = onRemove,
                enabled = enabled,
            )
        }
        if (expanded) {
            CaptionText(
                stringResource(R.string.device_access_staged_path_label) + ": " + apk.fileName,
                Modifier.padding(top = 4.dp),
            )
            CaptionText(
                stringResource(R.string.device_access_staged_sha_label) + ": " + apk.sha256,
                Modifier.padding(top = 2.dp),
            )
        }
    }
}

/** One-line staged APK subtitle: human size plus the archive package name. */
private fun stagedApkSubtitle(context: android.content.Context, apk: DeviceAccessStagedApkUi): String {
    val size = android.text.format.Formatter.formatShortFileSize(context, apk.sizeBytes)
    val pkg = apk.packageName ?: context.getString(R.string.device_access_staged_pkg_unknown)
    return "$size · $pkg"
}

/**
 * Inline pairing availability is shown only for an actually open pairing
 * session. The explanation text now lives in the card caption; this scope
 * keeps only the honest system action row. AVAILABLE needs no action,
 * UNSUPPORTED renders nothing, and anything else names the real permission
 * request or system-settings entry. There is no "Paired" claim here and no
 * promise that returning to Floe preserves Android's pairing dialog.
 */
@Composable
private fun SectionScope.PairingNotificationAction(
    availability: PairingNotificationPolicy.Availability,
    permissionDenied: Boolean,
    onAllow: () -> Unit,
) {
    when (availability) {
        PairingNotificationPolicy.Availability.AVAILABLE,
        PairingNotificationPolicy.Availability.UNSUPPORTED -> Unit
        else -> FloeActionRow(
            label = stringResource(
                if (availability ==
                    PairingNotificationPolicy.Availability.PERMISSION_REQUIRED &&
                    !permissionDenied
                ) {
                    R.string.device_access_pairing_notification_allow
                } else {
                    R.string.device_access_pairing_notification_settings
                },
            ),
            onClick = onAllow,
        )
    }
}
