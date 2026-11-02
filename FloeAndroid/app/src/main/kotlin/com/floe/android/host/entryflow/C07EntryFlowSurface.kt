// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.entryflow

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.floe.android.design.FloeSettingsSection
import com.floe.android.feature.entryflow.EntryNoticeCard
import com.floe.android.feature.entryflow.EntrySetupGuideSheet
import com.floe.android.feature.entryflow.EntrySetupStep
import com.floe.android.feature.entryflow.EntrySetupUi
import com.floe.android.feature.entryflow.EntryShareSheet

/**
 * The App-owned presentation of an admitted share and the optional setup
 * guide. Mounted once by the shell; it never navigates on arrival, never sends
 * a task and never approves anything.
 */
@Composable
internal fun C07EntryFlowSurface(
    onOpenSettingsSection: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val share by C07EntryFlowHost.shareUi.collectAsState()
    val setup by C07EntryFlowHost.setupUi.collectAsState()
    val notice by C07EntryFlowHost.notice.collectAsState()
    val openSection by C07EntryFlowHost.openSettingsSection.collectAsState()

    // The package review owner exposes an EXISTING settings category. Opening
    // it is only requested after that owner really accepted the handoff.
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
            total = 6,
            visible = false,
        ),
        onNext = C07EntryFlowHost::nextSetupStep,
        onBack = C07EntryFlowHost::previousSetupStep,
        onSkip = C07EntryFlowHost::skipSetupGuide,
        onFinish = C07EntryFlowHost::finishSetupGuide,
        onAction = {
            when (setup?.step) {
                EntrySetupStep.MODELS -> {
                    C07EntryFlowHost.dismissSetupGuide()
                    onOpenSettingsSection(FloeSettingsSection.PROVIDERS.name)
                }
                EntrySetupStep.VOICE -> {
                    C07EntryFlowHost.dismissSetupGuide()
                    onOpenSettingsSection(FloeSettingsSection.GENERAL.name)
                }
                else -> Unit
            }
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
