// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.entryflow

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.LocalActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.floe.android.FLOE_PHONE_ACCESS_SECTION_KEY
import com.floe.android.SETTINGS_DEEP_LINK_VOICE_INPUT
import com.floe.android.SETTINGS_DEEP_LINK_VOICE_OUTPUT
import com.floe.android.design.FloeSettingsSection
import com.floe.android.feature.entryflow.EntryNoticeCard
import com.floe.android.feature.entryflow.EntryNotificationAction
import com.floe.android.feature.entryflow.EntrySetupGuideSheet
import com.floe.android.feature.entryflow.EntrySetupStep
import com.floe.android.feature.entryflow.EntrySetupUi
import com.floe.android.feature.entryflow.EntryShareSheet
import com.floe.android.host.settings.DistributionSettingsFeature

/**
 * The App-owned presentation of an admitted share and the optional setup
 * guide. Mounted once by the shell; it never navigates on arrival, never sends
 * a task and never approves anything.
 *
 * Guide actions open the REAL existing owner of each capability (Settings
 * categories, the folder manager or the system notification controls). The
 * guide suspends while such a surface is open and returns to the same step
 * afterwards; nothing is enabled, granted or marked configured by opening it.
 */
@Composable
internal fun C07EntryFlowSurface(
    onOpenSettingsSection: (String) -> Unit,
    onOpenFiles: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val share by C07EntryFlowHost.shareUi.collectAsState()
    val setup by C07EntryFlowHost.setupUi.collectAsState()
    val notice by C07EntryFlowHost.notice.collectAsState()
    val openSection by C07EntryFlowHost.openSettingsSection.collectAsState()
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current

    // Real platform notification state drives the step's action: the Android
    // 13+ runtime permission while it can still be asked, otherwise the
    // system notification settings (the only control before Android 13).
    // `resumeTick` re-reads the rationale after a settings/dialog return.
    var resumeTick by remember { mutableIntStateOf(0) }
    var notificationAsked by rememberSaveable { mutableStateOf(false) }
    val activity = LocalActivity.current
    val notificationStepVisible = setup?.step == EntrySetupStep.NOTIFICATIONS
    val notificationPermissionGranted = !notificationStepVisible || Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
    val notificationAction = remember(
        resumeTick,
        notificationAsked,
        notificationPermissionGranted,
    ) {
        if (
            Build.VERSION.SDK_INT >= 33 &&
            !notificationPermissionGranted &&
            (!notificationAsked ||
                activity?.shouldShowRequestPermissionRationale(
                    Manifest.permission.POST_NOTIFICATIONS,
                ) == true)
        ) {
            EntryNotificationAction.REQUEST_PERMISSION
        } else {
            EntryNotificationAction.OPEN_SETTINGS
        }
    }
    val notificationPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) {
        // Grant or refusal: only re-read the real state. A refusal flips the
        // action to the system settings; nothing is retried automatically.
        notificationAsked = true
        C07EntryFlowHost.refreshSetupStatus()
    }
    // Returning from the system notification settings (or the permission
    // dialog) must refresh the step's status line. Observation only: the
    // guide itself is never dismissed or advanced by a resume.
    DisposableEffect(lifecycleOwner, notificationStepVisible) {
        if (!notificationStepVisible) return@DisposableEffect onDispose { }
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                resumeTick += 1
                C07EntryFlowHost.refreshSetupStatus()
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // The package review owner and the guide's configuration steps expose an
    // EXISTING settings category. Opening it is only requested after that
    // owner really accepted the handoff, or after the guide suspended itself.
    LaunchedEffect(openSection) {
        val key = openSection ?: return@LaunchedEffect
        onOpenSettingsSection(key)
        C07EntryFlowHost.consumeOpenSettingsSection(key)
    }

    share?.let { state ->
        val intakeID = state.intakeID
        EntryShareSheet(
            visible = true,
            state = state,
            onDismiss = C07EntryFlowHost::dismissShare,
            onChooseTask = {
                intakeID?.let(C07EntryFlowHost::chooseTaskDestination)
            },
            onChooseNotes = {
                intakeID?.let(C07EntryFlowHost::chooseNotesDestination)
            },
            onChooseReview = {
                intakeID?.let(C07EntryFlowHost::chooseReviewDestination)
            },
            onOpenReview = C07EntryFlowHost::openReviewFromShare,
            onDiscard = { C07EntryFlowHost.discardIntake() },
            onOpenNotes = C07EntryFlowHost::openNotesFromShare,
        )
    }

    EntrySetupGuideSheet(
        state = setup ?: EntrySetupUi(
            step = EntrySetupStep.WELCOME,
            index = 0,
            total = 1,
            visible = false,
        ),
        notificationAction = notificationAction,
        deviceSettingsReady = DistributionSettingsFeature.wired,
        onNext = C07EntryFlowHost::nextSetupStep,
        onBack = C07EntryFlowHost::previousSetupStep,
        onSkip = C07EntryFlowHost::skipSetupGuide,
        onFinish = C07EntryFlowHost::finishSetupGuide,
        onAction = {
            when (setup?.step) {
                EntrySetupStep.MODELS -> C07EntryFlowHost.beginSetupConfiguration(
                    FloeSettingsSection.PROVIDERS.name,
                )
                EntrySetupStep.VOICE -> C07EntryFlowHost.beginSetupConfiguration(
                    SETTINGS_DEEP_LINK_VOICE_INPUT,
                )
                EntrySetupStep.FILES -> {
                    // The real authorized-folder owner (Space → Files). The
                    // guide suspends and returns here when it closes.
                    C07EntryFlowHost.suspendSetupForConfiguration()
                    onOpenFiles()
                }
                EntrySetupStep.NOTIFICATIONS -> {
                    if (notificationAction == EntryNotificationAction.REQUEST_PERMISSION) {
                        runCatching {
                            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
                        }.onFailure {
                            C07EntryFlowHost.openSystemNotificationSettings()
                        }
                    } else {
                        C07EntryFlowHost.openSystemNotificationSettings()
                    }
                }
                EntrySetupStep.LINUX -> C07EntryFlowHost.beginSetupConfiguration(
                    FloeSettingsSection.EXECUTION.name,
                )
                EntrySetupStep.DEVICE -> C07EntryFlowHost.beginSetupConfiguration(
                    FLOE_PHONE_ACCESS_SECTION_KEY,
                )
                else -> Unit
            }
        },
        onSecondaryAction = if (setup?.step == EntrySetupStep.VOICE) {
            {
                C07EntryFlowHost.beginSetupConfiguration(SETTINGS_DEEP_LINK_VOICE_OUTPUT)
            }
        } else {
            null
        },
        onDismiss = C07EntryFlowHost::dismissSetupGuide,
    )

    Box(modifier.fillMaxWidth(), contentAlignment = Alignment.BottomCenter) {
        EntryNoticeCard(
            kind = notice,
            onDismiss = C07EntryFlowHost::dismissNotice,
            modifier = Modifier.padding(16.dp),
        )
    }
}
