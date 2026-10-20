// SPDX-License-Identifier: MPL-2.0
//
// TEST-ONLY synthetic two-pane Settings host.
//
// This is not the production App SettingsSheet and it is not a backend. It
// reproduces the host contract the real SettingsSheet now owns: a measured
// left category pane, a measured selected category row, a measured detail pane
// and the actual FloeProviderSettingsDestination embedded in the detail. The
// provider module is intentionally not an App dependency yet, so this harness
// is how the source-only qualification can exercise the real composable call
// path with measured geometry. Main's full-App build/UI acceptance remains the
// only App-level proof.

package com.floe.android.feature.providers

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeSettingsHostGeometry
import com.floe.android.design.FloeText
import com.floe.android.design.FloeVerticalDivider

@Composable
internal fun ProviderHostFixtureSurface(controller: ProviderFixtureController) {
    val density = LocalDensity.current
    if (controller.hostLargeFont) {
        CompositionLocalProvider(
            LocalDensity provides Density(density.density, fontScale = 2.5f),
        ) {
            ProviderHostTwoPaneSurface(controller)
        }
    } else {
        ProviderHostTwoPaneSurface(controller)
    }
}

@Composable
private fun ProviderHostTwoPaneSurface(controller: ProviderFixtureController) {
    var categoryBounds by remember { mutableStateOf<Rect?>(null) }
    var detailBounds by remember { mutableStateOf<Rect?>(null) }
    var selectedRowBounds by remember { mutableStateOf<Rect?>(null) }
    val density = LocalDensity.current
    val windowInfo = LocalWindowInfo.current
    val width = windowInfo.containerSize.width.coerceAtLeast(1)
    val height = windowInfo.containerSize.height.coerceAtLeast(1)
    val categoryVisible = controller.hostCategoryVisible
    val geometry = FloeSettingsHostGeometry(
        windowBoundsPx = Rect(0f, 0f, width.toFloat(), height.toFloat()),
        categoryPaneBoundsPx = if (categoryVisible) categoryBounds else null,
        detailPaneBoundsPx = detailBounds,
        selectedCategoryRowBoundsPx = if (categoryVisible) selectedRowBounds else null,
        triggerBoundsPx = null,
        safeInsetsPx = com.floe.android.design.FloeWindowInsetsPx.Zero,
        imeBottomInsetPx = 0,
        wideLayout = true,
        categoryPaneVisible = categoryVisible,
        density = density.density,
        fontScale = density.fontScale,
    )

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Floe.colors.groupedSurface)
            .windowInsetsPadding(WindowInsets.safeDrawing),
    ) {
        FloeText(
            text = stringResource(R.string.preview_synthetic_notice),
            style = Floe.typography.metadata,
            color = Floe.colors.pending,
            modifier = Modifier
                .fillMaxWidth()
                .background(Floe.colors.pending.copy(alpha = 0.12f))
                .padding(horizontal = 12.dp, vertical = 4.dp),
        )
        Row(Modifier.fillMaxSize()) {
            if (categoryVisible) {
                Column(
                    modifier = Modifier
                        .width(320.dp)
                        .fillMaxHeight()
                        .background(Floe.colors.sidebarSurface)
                        .onGloballyPositioned { coordinates ->
                            val bounds = coordinates.boundsInWindow()
                            if (categoryBounds != bounds) categoryBounds = bounds
                        }
                        .testTag("providerHost.categoryPane"),
                ) {
                    FloeText(
                        text = stringResource(R.string.provider_settings_title),
                        style = Floe.typography.title,
                        color = Floe.colors.label,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                    )
                    Spacer(Modifier.height(128.dp))
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 12.dp)
                            .heightIn(min = 52.dp)
                            .clip(RoundedCornerShape(percent = 50))
                            .background(Floe.colors.fillTertiary)
                            .onGloballyPositioned { coordinates ->
                                val bounds = coordinates.boundsInWindow()
                                if (selectedRowBounds != bounds) selectedRowBounds = bounds
                            }
                            .testTag("providerHost.categoryRow"),
                        contentAlignment = Alignment.CenterStart,
                    ) {
                        FloeText(
                            text = stringResource(R.string.provider_settings_title),
                            style = Floe.typography.body,
                            color = Floe.colors.label,
                            modifier = Modifier.padding(horizontal = 16.dp),
                        )
                    }
                }
                FloeVerticalDivider()
            }
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .onGloballyPositioned { coordinates ->
                        val bounds = coordinates.boundsInWindow()
                        if (detailBounds != bounds) detailBounds = bounds
                    }
                    .testTag("providerHost.detail"),
            ) {
                FloeProviderSettingsDestination(
                    state = controller.state.value,
                    holder = controller.holder,
                    hostGeometry = geometry,
                )
            }
        }
    }
}
