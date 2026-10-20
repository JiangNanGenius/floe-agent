// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
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
 * The pane shows honest unavailable/empty states until each real content
 * source is bound; task progress renders its pending state until the actual
 * progress binding lands (no synthetic samples on the runtime route).
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
            InspectorContent.PROGRESS -> FloeUnavailableView(
                icon = FloeIcons.Terminal,
                title = inspectorTitle(route.content),
                description = stringResource(R.string.inspector_progress_pending),
            )
            else -> FloeUnavailableView(
                icon = FloeIcons.Terminal,
                title = inspectorTitle(route.content),
                description = stringResource(R.string.inspector_runtime_pending),
            )
        }
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
