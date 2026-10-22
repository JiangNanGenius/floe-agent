// SPDX-License-Identifier: MPL-2.0
@file:OptIn(io.github.robinpcrd.cupertino.ExperimentalCupertinoApi::class)

package com.floe.android

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.bridge.SwiftCore
import io.github.robinpcrd.cupertino.section.SectionItem
import com.floe.android.contracts.Distribution
import com.floe.android.design.Floe
import com.floe.android.design.FloePrimaryAction
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeText
import com.floe.android.design.FloeValueRow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * Diagnostics & About (iOS `DiagnosticsAboutView` analog). The shared-core
 * row performs the REAL JNI handshake off the main thread — connection
 * status is measured, never assumed. Debug builds additionally expose the
 * clearly-labelled synthetic component preview (G02+ thread screens will
 * reuse these same composables).
 */
@Composable
fun DiagnosticsSettingsPage(onOpenPreview: () -> Unit) {
    val colors = Floe.colors
    var status by remember { mutableStateOf<Boolean?>(null) }
    var failure by remember { mutableStateOf(false) }
    var attempt by remember { mutableIntStateOf(0) }
    LaunchedEffect(attempt) {
        status = null
        failure = false
        val result = withContext(Dispatchers.IO) {
            runCatching { JSONObject(SwiftCore.handshake()).getBoolean("ok") }
        }
        result.fold(onSuccess = { status = it }, onFailure = { failure = true })
    }
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        // The sheet's independent detail header owns the 34sp section title.
        FloeSettingsSectionCard(title = stringResource(R.string.shared_core)) {
            FloeValueRow(
                title = stringResource(R.string.shared_core),
                value = when {
                    failure || status == false -> stringResource(R.string.unavailable)
                    status == true -> stringResource(R.string.connected)
                    else -> stringResource(R.string.checking)
                },
            )
            if (failure || status == false) {
                SectionItem(
                    title = {
                        FloePrimaryAction(
                            label = stringResource(R.string.retry),
                            onClick = { attempt++ },
                            modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
                            enabled = true,
                        )
                    },
                )
            }
        }
        // G03-R3 bounded read-only local-task-execution stage (Main-authorized
        // observability, 2026-10-23): the honest stage token composed ONLY
        // from the ORIGINAL readiness authority — a CLOSED vocabulary (known
        // stage/refusal tokens or the fixed `redacted`), epoch-tagged so a
        // late old-Root callback never surfaces under the current generation.
        // Never paths/keys/prompts/commands. The Retry action is ONE bounded
        // user-initiated fresh re-ingress through the SAME authorized
        // primitive the verified install transition uses — no idle polling,
        // no qualification shortcut; it re-measures live proof and refuses on
        // any real drift.
        val app = LocalContext.current.applicationContext as FloeApplication
        var stage by remember { mutableStateOf<String?>(null) }
        var stageAttempt by remember { mutableIntStateOf(0) }
        LaunchedEffect(stageAttempt) {
            if (stageAttempt > 0) {
                withContext(Dispatchers.IO) { app.retryLinuxTaskExecutionIngress() }
            }
            stage = withContext(Dispatchers.IO) { app.linuxTaskExecutionDiagnostic() }
        }
        FloeSettingsSectionCard(title = stringResource(R.string.diagnostics_local_task_execution)) {
            FloeValueRow(
                title = stringResource(R.string.diagnostics_local_task_execution),
                value = when (stage) {
                    null -> stringResource(R.string.checking)
                    "ready" -> stringResource(R.string.linux_environment_tools_ready)
                    else -> stringResource(R.string.unavailable)
                },
            )
            val shown = stage
            if (shown != null && shown != "ready") {
                SectionItem(
                    title = {
                        FloeText(
                            shown,
                            style = Floe.typography.metadata,
                            color = colors.secondaryLabel,
                        )
                    },
                )
                SectionItem(
                    title = {
                        FloePrimaryAction(
                            label = stringResource(R.string.retry),
                            onClick = { stageAttempt++ },
                            modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
                            enabled = true,
                        )
                    },
                )
            }
        }
        if (BuildConfig.DEBUG) {
            FloeSettingsSectionCard(title = stringResource(R.string.component_preview_section)) {
                SectionItem(
                    title = {
                        Column(Modifier.fillMaxWidth().padding(top = 4.dp)) {
                            FloeText(
                                stringResource(R.string.component_preview_note),
                                style = Floe.typography.metadata,
                                color = colors.secondaryLabel,
                            )
                            Spacer(Modifier.height(8.dp))
                            FloePrimaryAction(
                                label = stringResource(R.string.component_preview_open),
                                onClick = onOpenPreview,
                                modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp),
                            )
                        }
                    },
                )
            }
        }
        FloeSettingsSectionCard(title = stringResource(R.string.about)) {
            FloeValueRow(stringResource(R.string.build_version), BuildConfig.VERSION_NAME)
            FloeValueRow(
                stringResource(R.string.distribution),
                stringResource(
                    if (DistributionModules.distribution == Distribution.FULL) R.string.full_distribution else R.string.play_distribution
                ),
            )
            SectionItem(
                title = {
                    FloeText(
                        stringResource(R.string.foundation_stage_note),
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                        modifier = Modifier.padding(bottom = 10.dp),
                    )
                },
            )
        }
    }
}
