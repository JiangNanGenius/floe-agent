// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.entryflow

import android.app.Activity
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.FloeSettingsExternalSection
import com.floe.android.design.Floe
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloePrimaryAction
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeText
import com.floe.android.feature.entryflow.EntryFeedbackSection
import com.floe.android.feature.entryflow.R
import com.floe.android.safgateway.PickKind
import com.floe.android.safgateway.PickRequestSpec
import com.floe.android.safgateway.SafPickerIntents
import io.github.robinpcrd.cupertino.section.SectionItem

/**
 * C07 reachable settings category: a skippable setup guide (revisit) and the
 * user-authored, locally exported feedback/diagnostics report. No account,
 * subscription, developer-funded test or remote send exists here.
 */
internal object C07EntryFlowFeature {
    fun settingsSection(): FloeSettingsExternalSection =
        FloeSettingsExternalSection(
            key = "x:entryflow",
            titleRes = R.string.entryflow_title,
            icon = FloeIcons.Gearshape,
            content = { C07EntryFlowSettingsDestination() },
        )
}

@Composable
private fun C07EntryFlowSettingsDestination() {
    val feedback by C07EntryFlowHost.feedback.collectAsState()
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        if (result.resultCode != Activity.RESULT_OK) {
            return@rememberLauncherForActivityResult
        }
        val uri = SafPickerIntents.resultUriString(result.data)
            ?.let { runCatching { Uri.parse(it) }.getOrNull() }
        if (uri == null) {
            C07EntryFlowHost.feedbackExportUnavailable()
            return@rememberLauncherForActivityResult
        }
        val flags = SafPickerIntents.resultFlags(result.data)
        if ((flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION) == 0) {
            C07EntryFlowHost.feedbackExportUnavailable()
            return@rememberLauncherForActivityResult
        }
        C07EntryFlowHost.exportFeedback(uri, flags)
    }

    fun launchExport() {
        val request = PickRequestSpec(
            requestKey = "entryflow-feedback",
            kind = PickKind.CREATE_DOCUMENT,
            mimeTypes = listOf("text/plain"),
            suggestedName = C07DiagnosticsExport.suggestedFileName(),
            initialDirectory = null,
        )
        try {
            launcher.launch(SafPickerIntents.from(request))
        } catch (_: Exception) {
            C07EntryFlowHost.feedbackExportUnavailable()
        }
    }

    Column(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
        FloeSettingsSectionCard(
            title = stringResource(R.string.entryflow_setup_title),
        ) {
            SectionItem {
                Column(Modifier.fillMaxWidth().padding(12.dp)) {
                    FloeText(
                        stringResource(R.string.entryflow_setup_body),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                    FloePrimaryAction(
                        label = stringResource(R.string.entryflow_setup_title),
                        onClick = { C07EntryFlowHost.openSetupGuide() },
                        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    )
                }
            }
        }
        FloeSettingsSectionCard(
            title = stringResource(R.string.entryflow_feedback_title),
        ) {
            SectionItem {
                FloeText(
                    stringResource(R.string.entryflow_feedback_body),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                )
            }
        }
        EntryFeedbackSection(
            state = feedback,
            onProblemChange = C07EntryFlowHost::updateFeedbackProblem,
            onIncludeDiagnostics = C07EntryFlowHost::setFeedbackDiagnostics,
            onExport = { launchExport() },
            onCancel = C07EntryFlowHost::cancelFeedbackExport,
            onDismissReceipt = C07EntryFlowHost::dismissFeedbackReceipt,
        )
    }
}
