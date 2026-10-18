// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeCheckboxRow
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeText
import com.floe.android.design.FloeUnavailableView
import com.floe.android.design.InspectorContent
import com.floe.android.design.InspectorRoute
import androidx.compose.foundation.background

/**
 * On-demand inspector pane (iOS third column lives inside the stable detail
 * row; recreated per route identity, mirroring the `.id(route.id)` contract).
 * In the G01 foundation the pane renders only the clearly labelled synthetic
 * task-progress preview sample; the real workspace/browser/terminal contents
 * arrive with the runtime and must reuse this exact slot.
 */
@Composable
fun FloeInspectorPane(
    route: InspectorRoute,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    BackHandler(onBack = onDismiss)
    val colors = Floe.colors
    Column(modifier.fillMaxSize().background(colors.readingSurface)) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(FloeLayout.ToolbarHeight + 4.dp)
                .padding(horizontal = 10.dp),
        ) {
            FloeText(
                inspectorTitle(route.content),
                style = Floe.typography.toolbarTitle,
                color = colors.label,
                modifier = Modifier.align(Alignment.CenterStart),
            )
            FloeCircleButton(
                icon = FloeIcons.Xmark,
                contentDescription = stringResource(R.string.close),
                onClick = onDismiss,
                visualSize = 34.dp,
                iconSize = 15.dp,
                modifier = Modifier.align(Alignment.CenterEnd),
            )
        }
        FloeDivider()
        when (route.content) {
            InspectorContent.PROGRESS -> ProgressSample()
            else -> FloeUnavailableView(
                icon = FloeIcons.Terminal,
                title = inspectorTitle(route.content),
                description = stringResource(R.string.inspector_runtime_pending),
            )
        }
    }
}

/** Synthetic task-progress sample with working local selection controls. */
@Composable
private fun ProgressSample() {
    val colors = Floe.colors
    var reviewed by rememberSaveable { mutableStateOf(true) }
    var evidence by rememberSaveable { mutableStateOf(false) }
    var followUp by rememberSaveable { mutableStateOf(false) }
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(14.dp),
    ) {
        FloeText(
            stringResource(R.string.preview_synthetic),
            style = Floe.typography.metadata,
            color = colors.pending,
        )
        Spacer(Modifier.height(10.dp))
        // Progress bar in the accent (brand ramp is reserved; progress uses
        // the same interactive accent as iOS selection/progress semantics).
        Box(
            Modifier
                .fillMaxWidth()
                .height(6.dp)
                .clip(RoundedCornerShape(3.dp))
                .background(colors.fillTertiary),
        ) {
            Box(
                Modifier
                    .fillMaxWidth(0.62f)
                    .height(6.dp)
                    .clip(RoundedCornerShape(3.dp))
                    .background(colors.accent),
            )
        }
        Spacer(Modifier.height(14.dp))
        FloeText(stringResource(R.string.inspector_sample_steps), style = Floe.typography.section, color = colors.label)
        Spacer(Modifier.height(4.dp))
        FloeCheckboxRow(stringResource(R.string.inspector_sample_step1), reviewed, { reviewed = it })
        FloeCheckboxRow(stringResource(R.string.inspector_sample_step2), evidence, { evidence = it })
        FloeCheckboxRow(stringResource(R.string.inspector_sample_step3), followUp, { followUp = it })
        Spacer(Modifier.height(10.dp))
        FloeText(
            stringResource(R.string.preview_selection_count, listOf(reviewed, evidence, followUp).count { it }),
            style = Floe.typography.metadata,
            color = colors.secondaryLabel,
        )
    }
}

@Composable
private fun inspectorTitle(content: InspectorContent): String = when (content) {
    InspectorContent.PROGRESS -> stringResource(R.string.inspector_progress)
    InspectorContent.WORKSPACE_FILES -> stringResource(R.string.inspector_files)
    InspectorContent.CHANGES -> stringResource(R.string.inspector_changes)
    InspectorContent.BROWSER -> stringResource(R.string.inspector_browser)
    InspectorContent.TERMINAL -> stringResource(R.string.inspector_terminal)
    InspectorContent.CHILD_AGENTS -> stringResource(R.string.inspector_agents)
    InspectorContent.PERMISSIONS -> stringResource(R.string.inspector_permissions)
}
