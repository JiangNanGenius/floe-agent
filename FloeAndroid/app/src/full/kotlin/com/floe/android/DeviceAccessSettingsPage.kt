// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionRow
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeCapsuleButton
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeInlineSwitch
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeSectionRow
import com.floe.android.design.FloeSecureFormField
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeStatusLine
import com.floe.android.design.FloeText
import com.floe.android.design.FloeValueRow

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
 *  - The page is host-neutral so the same content works in the compact
 *    phone detail page and in the tablet settings detail column.
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
     * screen was opened from Floe and the user came back to enter the code;
     * the entry field then stays available (the caller keeps it in RAM).
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

data class DeviceAccessUiError(
    val message: String,
    /** Typed diagnostic token; shown only inside the opened details fold. */
    val code: String? = null,
)

data class DeviceAccessPresentationState(
    val accessibility: DeviceAccessAccessibilityUi = DeviceAccessAccessibilityUi.Off,
    val adb: DeviceAccessAdbUi = DeviceAccessAdbUi.Off,
    val root: DeviceAccessRootUi = DeviceAccessRootUi.Off,
    val screenScope: DeviceAccessScreenScopeUi = DeviceAccessScreenScopeUi.OFF,
    val activeTask: DeviceAccessActiveTaskUi? = null,
    val taskControl: DeviceAccessTaskControlUi = DeviceAccessTaskControlUi.OFF,
    val targets: DeviceAccessTargetsUi = DeviceAccessTargetsUi(),
    val busy: DeviceAccessBusyUi = DeviceAccessBusyUi.NONE,
    val error: DeviceAccessUiError? = null,
    /** True only on API >= 30 where wireless ADB pairing exists. */
    val pairingSupported: Boolean = true,
    /** Ephemeral pairing port held in RAM only; never persisted/logged. */
    val pairingPort: String = "",
    val pairingDiscovery: DeviceAccessPairingDiscoveryUi = DeviceAccessPairingDiscoveryUi.IDLE,
    /** True after the real controller's USB bootstrap command was copied. */
    val usbBootstrapExported: Boolean = false,
)

/**
 * All effects return to the App integrator. Default lambdas are inert so a
 * preview or a not-yet-wired host can compose the page without pretending an
 * action happened.
 */
class DeviceAccessCallbacks(
    val onOpenAccessibilitySettings: () -> Unit = {},
    val onRefresh: () -> Unit = {},
    /** USER-ONLY: allows phone control for the exact visible task/run. */
    val onArmPhoneControl: () -> Unit = {},
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
    val onScreenScopeChange: (DeviceAccessScreenScopeUi) -> Unit = {},
    val onEnableAdb: () -> Unit = {},
    /** Opens the system Wireless debugging pairing screen and posts the
     * temporary return notification; the caller keeps Floe's code entry alive. */
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
                setOf(DeviceAccessAdbActionUi.START, DeviceAccessAdbActionUi.FORGET)
            is DeviceAccessAdbUi.ServiceAlive ->
                setOf(DeviceAccessAdbActionUi.STOP, DeviceAccessAdbActionUi.FORGET)
            is DeviceAccessAdbUi.ServiceDied ->
                setOf(DeviceAccessAdbActionUi.START, DeviceAccessAdbActionUi.FORGET)
            DeviceAccessAdbUi.RestartRequired ->
                setOf(DeviceAccessAdbActionUi.START, DeviceAccessAdbActionUi.OPEN_DEVELOPER_OPTIONS)
            DeviceAccessAdbUi.Revoked ->
                setOf(DeviceAccessAdbActionUi.PAIR, DeviceAccessAdbActionUi.OPEN_DEVELOPER_OPTIONS)
            is DeviceAccessAdbUi.Error ->
                setOf(DeviceAccessAdbActionUi.ENABLE, DeviceAccessAdbActionUi.PAIR)
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

    /** The whole-screen capture disclosure is shown whenever screen scope is
     * on; API 34+ prefers window capture but never silently widens to display. */
    fun wholeScreenConsentVisible(state: DeviceAccessPresentationState): Boolean =
        state.screenScope != DeviceAccessScreenScopeUi.OFF

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
}

@Composable
fun DeviceAccessSettingsPage(
    state: DeviceAccessPresentationState,
    callbacks: DeviceAccessCallbacks,
    pairingCode: String,
    onPairingCodeChange: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = Floe.colors
    // Presentation-only toggles: deliberately NOT saveable, so nothing about
    // the pairing field or a failure detail survives process death.
    var showErrorDetails by remember { mutableStateOf(false) }
    var revealPairingCode by remember { mutableStateOf(false) }
    var confirmForget by remember { mutableStateOf(false) }
    var confirmRootCheck by remember { mutableStateOf(false) }
    // Explicit app-data folder draft. RAM-only presentation input; the host
    // validates the backend-shape before it becomes a grantable root.
    var appDataDraft by remember { mutableStateOf("") }
    val adbActions = DeviceAccessPresentation.adbActions(state.adb, state.busy)
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

        // ------------------------------------------------ accessibility layer
        FloeSettingsSectionCard(title = stringResource(R.string.device_access_accessibility_section)) {
            FloeValueRow(stringResource(R.string.device_access_status_label), accessibilityStatus)
            FloeSectionRow(title = {
                Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                    FloeText(
                        stringResource(R.string.device_access_accessibility_disclosure),
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                    )
                    Spacer(Modifier.height(6.dp))
                    FloeText(
                        stringResource(R.string.device_access_boundary_title),
                        style = Floe.typography.metadata,
                        color = colors.label,
                    )
                    BoundaryLine(stringResource(R.string.device_access_boundary_nodes))
                    BoundaryLine(stringResource(R.string.device_access_boundary_secrets))
                    BoundaryLine(stringResource(R.string.device_access_boundary_actions))
                    BoundaryLine(stringResource(R.string.device_access_boundary_screenshots))
                }
            })
            if (state.accessibility == DeviceAccessAccessibilityUi.Restricted) {
                FloeSectionRow(title = {
                    FloeText(
                        stringResource(R.string.device_access_accessibility_restricted_hint),
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                    )
                })
            }
            FloeActionRow(
                label = stringResource(R.string.device_access_open_settings),
                onClick = callbacks.onOpenAccessibilitySettings,
            )
        }

        // ------------------------------------------------- target application scope
        FloeSettingsSectionCard(title = stringResource(R.string.device_access_targets_section)) {
            FloeSectionRow(title = {
                FloeText(
                    stringResource(R.string.device_access_targets_intro),
                    style = Floe.typography.metadata,
                    color = colors.secondaryLabel,
                )
            })
            if (state.targets.packages.isEmpty()) {
                FloeSectionRow(title = {
                    FloeText(
                        stringResource(R.string.device_access_targets_empty),
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                    )
                })
            } else {
                state.targets.packages.forEach { pkg ->
                    FloeSectionRow(
                        title = {
                            Column(Modifier.fillMaxWidth()) {
                                FloeText(
                                    pkg.label,
                                    style = Floe.typography.body,
                                    color = colors.label,
                                    maxLines = 1,
                                )
                                FloeText(
                                    pkg.packageName,
                                    style = Floe.typography.metadata,
                                    color = colors.secondaryLabel,
                                    maxLines = 1,
                                )
                            }
                        },
                        trailing = {
                            FloeInlineSwitch(
                                checked = pkg.selected,
                                onCheckedChange = { checked ->
                                    val next = state.targets.selectedPackages.toMutableSet()
                                    if (checked) next += pkg.packageName
                                    else next -= pkg.packageName
                                    callbacks.onAllowedPackagesChange(next)
                                },
                                description = pkg.label,
                                enabled = state.busy == DeviceAccessBusyUi.NONE,
                            )
                        },
                    )
                }
            }
        }

        // ------------------------------------------------------- file ceilings
        FloeSettingsSectionCard(title = stringResource(R.string.device_access_roots_section)) {
            FloeSectionRow(title = {
                FloeText(
                    stringResource(R.string.device_access_roots_intro),
                    style = Floe.typography.metadata,
                    color = colors.secondaryLabel,
                )
            })
            val shared = state.targets.fileRoots.filter {
                it.kind == DeviceAccessFileRootKindUi.SHARED
            }
            if (shared.isEmpty()) {
                FloeSectionRow(title = {
                    FloeText(
                        stringResource(R.string.device_access_roots_empty),
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                    )
                })
            } else {
                shared.forEach { root ->
                    FileRootRow(root, state, callbacks)
                }
            }
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
            )
            FloeSectionRow(title = {
                FloeText(
                    stringResource(R.string.device_access_file_writes_hint),
                    style = Floe.typography.metadata,
                    color = colors.secondaryLabel,
                )
            })
        }

        // Read-only platform inspection trees. Never writable, never remounted.
        FloeSettingsSectionCard(title = stringResource(R.string.device_access_system_roots_section)) {
            FloeSectionRow(title = {
                FloeText(
                    stringResource(R.string.device_access_system_roots_hint),
                    style = Floe.typography.metadata,
                    color = colors.secondaryLabel,
                )
            })
            state.targets.fileRoots
                .filter { it.kind == DeviceAccessFileRootKindUi.SYSTEM }
                .forEach { root -> FileRootRow(root, state, callbacks) }
        }

        // Explicit other-app data folders: Root must be the live service; the
        // root service resolves the path and reports OS/SELinux/unlock truth.
        FloeSettingsSectionCard(title = stringResource(R.string.device_access_app_data_section)) {
            FloeSectionRow(title = {
                FloeText(
                    stringResource(R.string.device_access_app_data_hint),
                    style = Floe.typography.metadata,
                    color = colors.secondaryLabel,
                )
            })
            if (state.targets.appDataRootsAvailable) {
                state.targets.fileRoots
                    .filter { it.kind == DeviceAccessFileRootKindUi.APP_DATA }
                    .forEach { root -> FileRootRow(root, state, callbacks) }
                FloeSectionRow(title = {
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
                })
                FloeSectionRow(title = {
                    FloeText(
                        stringResource(R.string.device_access_app_data_example),
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                    )
                })
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
                FloeSectionRow(title = {
                    FloeText(
                        stringResource(R.string.device_access_app_data_requires_root),
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                    )
                })
            }
        }

        // The package ceiling is separate from file scopes: enabling it never
        // adds a file root, and enabling Root never enables it.
        FloeSettingsSectionCard(title = stringResource(R.string.device_access_management_section)) {
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
            FloeSectionRow(title = {
                FloeText(
                    stringResource(R.string.device_access_package_management_hint),
                    style = Floe.typography.metadata,
                    color = colors.secondaryLabel,
                )
            })
        }

        // --------------------------------------------------- active task card
        FloeSettingsSectionCard(title = stringResource(R.string.device_access_active_section)) {
            val task = state.activeTask
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
                if (state.taskControl == DeviceAccessTaskControlUi.ARMED) {
                    FloeActionRow(
                        label = stringResource(R.string.device_access_stop_task),
                        onClick = callbacks.onStopActiveTask,
                        enabled = DeviceAccessPresentation.canStopTask(state),
                    )
                    FloeActionRow(
                        label = stringResource(R.string.device_access_take_over),
                        onClick = callbacks.onTakeOverActiveTask,
                        enabled = DeviceAccessPresentation.canTakeOverTask(state),
                    )
                    FloeSectionRow(title = {
                        FloeText(
                            stringResource(R.string.device_access_take_over_hint),
                            style = Floe.typography.metadata,
                            color = colors.secondaryLabel,
                        )
                    })
                } else {
                    FloeSectionRow(title = {
                        FloeText(
                            stringResource(
                                if (state.taskControl == DeviceAccessTaskControlUi.STOPPED) {
                                    R.string.device_access_task_stopped
                                } else {
                                    R.string.device_access_task_not_allowed
                                },
                            ),
                            style = Floe.typography.metadata,
                            color = colors.secondaryLabel,
                        )
                    })
                    FloeSectionRow(title = {
                        FloeCapsuleButton(
                            stringResource(R.string.device_access_allow_task),
                            onClick = callbacks.onArmPhoneControl,
                            enabled = DeviceAccessPresentation.canArmPhoneControl(state),
                            prominent = true,
                        )
                    })
                    if (!DeviceAccessPresentation.packageTargetsValid(state)) {
                        FloeSectionRow(title = {
                            FloeText(
                                stringResource(R.string.device_access_select_apps_first),
                                style = Floe.typography.metadata,
                                color = colors.secondaryLabel,
                            )
                        })
                    }
                }
            }
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
                )
                FloeSectionRow(title = {
                    FloeText(
                        stringResource(
                            if (DeviceAccessPresentation.wholeScreenConsentRequired(state)) {
                                R.string.device_access_whole_screen_required
                            } else {
                                R.string.device_access_whole_screen_hint
                            },
                        ),
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                    )
                })
            }
        }

        // --------------------------------------------------- embedded ADB layer
        FloeSettingsSectionCard(title = stringResource(R.string.device_access_adb_section)) {
            FloeValueRow(stringResource(R.string.device_access_status_label), adbStatus)
            FloeSectionRow(title = {
                FloeText(
                    stringResource(R.string.device_access_adb_intro),
                    style = Floe.typography.metadata,
                    color = colors.secondaryLabel,
                )
            })
            if (!state.pairingSupported) {
                FloeSectionRow(title = {
                    FloeText(
                        stringResource(R.string.device_access_pairing_unsupported),
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                    )
                })
                FloeActionRow(
                    label = stringResource(R.string.device_access_usb_bootstrap),
                    onClick = callbacks.onExportUsbBootstrap,
                    enabled = state.busy == DeviceAccessBusyUi.NONE,
                )
                if (state.usbBootstrapExported) {
                    FloeSectionRow(title = {
                        FloeText(
                            stringResource(R.string.device_access_usb_bootstrap_copied),
                            style = Floe.typography.metadata,
                            color = colors.secondaryLabel,
                        )
                    })
                }
            }
            DeviceAccessPresentation.adbEffectiveUid(state.adb)?.let { uid ->
                FloeSectionRow(title = {
                    FloeText(
                        stringResource(R.string.device_access_adb_state_uid, uid),
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                    )
                })
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
                FloeSectionRow(title = {
                    FloeCapsuleButton(
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
                })
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
            // State-specific guidance, never a fabricated success.
            when (val adb = state.adb) {
                is DeviceAccessAdbUi.PairRequired -> if (adb.pairingSessionOpen) {
                    FloeSectionRow(title = { AdbHint(stringResource(R.string.device_access_adb_pair_hint)) })
                }
                DeviceAccessAdbUi.RestartRequired ->
                    FloeSectionRow(title = { AdbHint(stringResource(R.string.device_access_adb_restart_hint)) })
                DeviceAccessAdbUi.Revoked ->
                    FloeSectionRow(title = { AdbHint(stringResource(R.string.device_access_adb_revoked_hint)) })
                DeviceAccessAdbUi.Pairing ->
                    FloeSectionRow(title = { AdbHint(stringResource(R.string.device_access_adb_pair_hint)) })
                else -> Unit
            }
            // One explicit row per action the current state genuinely offers.
            if (DeviceAccessAdbActionUi.ENABLE in adbActions) {
                FloeSectionRow(title = {
                    FloeCapsuleButton(
                        stringResource(R.string.device_access_adb_enable),
                        onClick = callbacks.onEnableAdb,
                    )
                })
            }
            if (DeviceAccessAdbActionUi.PAIR in adbActions) {
                FloeSectionRow(title = {
                    FloeCapsuleButton(
                        stringResource(R.string.device_access_adb_pair),
                        onClick = callbacks.onPairAdb,
                    )
                })
                FloeSectionRow(title = { AdbHint(stringResource(R.string.device_access_adb_pair_hint)) })
            }
            if (DeviceAccessAdbActionUi.START in adbActions) {
                FloeSectionRow(title = {
                    FloeCapsuleButton(
                        stringResource(R.string.device_access_adb_start),
                        onClick = callbacks.onStartAdbService,
                    )
                })
            }
            if (DeviceAccessAdbActionUi.STOP in adbActions) {
                FloeSectionRow(title = {
                    FloeCapsuleButton(
                        stringResource(R.string.device_access_adb_stop),
                        onClick = callbacks.onStopAdbService,
                    )
                })
            }
            if (DeviceAccessAdbActionUi.CANCEL_PAIRING in adbActions) {
                FloeActionRow(
                    label = stringResource(R.string.device_access_adb_cancel_pairing),
                    onClick = callbacks.onCancelPairing,
                )
            }
            if (DeviceAccessAdbActionUi.OPEN_DEVELOPER_OPTIONS in adbActions) {
                FloeActionRow(
                    label = stringResource(R.string.device_access_adb_open_developer_options),
                    onClick = callbacks.onOpenDeveloperOptions,
                )
            }
            if (DeviceAccessAdbActionUi.FORGET in adbActions) {
                FloeActionRow(
                    label = stringResource(R.string.device_access_adb_forget),
                    onClick = { confirmForget = true },
                )
            }
        }

        // ---------------------------------------------------------- root layer
        FloeSettingsSectionCard(title = stringResource(R.string.device_access_root_section)) {
            FloeValueRow(stringResource(R.string.device_access_status_label), rootStatus)
            FloeSectionRow(title = {
                Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                    FloeText(
                        stringResource(R.string.device_access_root_intro),
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                    )
                    FloeText(
                        stringResource(R.string.device_access_root_enable_hint),
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                    )
                }
            })
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
            )
            DeviceAccessPresentation.rootEffectiveUid(state.root)?.let { uid ->
                FloeSectionRow(title = {
                    FloeText(
                        stringResource(R.string.device_access_root_uid, uid),
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                    )
                })
            }
            if (DeviceAccessPresentation.rootCheckVisible(state.root)) {
                FloeActionRow(
                    label = stringResource(R.string.device_access_root_check),
                    onClick = { confirmRootCheck = true },
                    enabled = state.busy != DeviceAccessBusyUi.ROOT_CHECK &&
                        state.busy != DeviceAccessBusyUi.ROOT_ENABLE,
                )
            }
        }

        // --------------------------------------------------------- typed error
        state.error?.let { error ->
            FloeSettingsSectionCard(title = null) {
                FloeSectionRow(title = {
                    FloeStatusLine(
                        icon = FloeIcons.WarningTriangle,
                        text = error.message,
                        color = colors.destructive,
                    )
                })
                val code = DeviceAccessPresentation.errorCode(error)
                if (code != null) {
                    val detailsLabel = stringResource(
                        if (showErrorDetails) R.string.device_access_error_hide_details
                        else R.string.device_access_error_details)
                    FloeActionRow(
                        label = detailsLabel,
                        onClick = { showErrorDetails = !showErrorDetails },
                    )
                    if (showErrorDetails) {
                        FloeSectionRow(title = {
                            // Machine token only: bounded and never translated.
                            FloeText(
                                code,
                                style = Floe.typography.evidence,
                                color = colors.secondaryLabel,
                            )
                        })
                    }
                }
                FloeActionRow(
                    label = stringResource(R.string.device_access_retry),
                    onClick = callbacks.onRefresh,
                )
            }
        }
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

@Composable
private fun AdbHint(text: String) {
    FloeText(
        text = text,
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
    )
}
