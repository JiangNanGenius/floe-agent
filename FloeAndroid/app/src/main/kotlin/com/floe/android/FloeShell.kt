// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeCheckboxRow
import com.floe.android.design.FloeColors
import com.floe.android.design.FloeDraftStore
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeSelectionStyle
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeThemeMode
import com.floe.android.design.FloeVerticalDivider
import com.floe.android.design.InspectorContent
import com.floe.android.design.InspectorRoute
import com.floe.android.design.MoreDestination
import com.floe.android.design.SidebarSelection
import com.floe.android.design.WorkbenchSelection

/**
 * Process-lifetime foundation state. Nothing here survives process death and
 * nothing pretends otherwise: drafts live in RAM (G02 adds durable storage),
 * the selection survives rotation through [rememberSaveable].
 */
object FloeFoundation {
    val draftStore = FloeDraftStore()
}

@Composable
fun FloeShell(
    themeMode: FloeThemeMode,
    onThemeModeChange: (FloeThemeMode) -> Unit,
) {
    var selectionKey by rememberSaveable { mutableStateOf(SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK).key) }
    var selection: SidebarSelection by mutableStateOf(selectionFromKey(selectionKey))
    var settingsVisible by rememberSaveable { mutableStateOf(false) }
    var settingsSectionKey by rememberSaveable { mutableStateOf("") }
    var previewVisible by rememberSaveable { mutableStateOf(false) }
    var inspectorRoute by rememberSaveable { mutableStateOf<String?>(null) }
    var sidebarCollapsed by rememberSaveable { mutableStateOf(false) }
    var drawerOpen by rememberSaveable { mutableStateOf(false) }

    val route: InspectorRoute? = inspectorRoute?.let { decodeInspectorRoute(it) }

    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .background(Floe.colors.readingSurface),
    ) {
        val totalWidthDp = maxWidth.value
        val overlayMaxWidthDp = maxWidth * 0.92f
        val twoColumn = maxWidth >= FloeLayout.PersistentTwoColumnMinWidth
        val persistentSidebar = twoColumn && !sidebarCollapsed
        val inspectorWidthFits = twoColumn && !sidebarCollapsed &&
            maxWidth >= FloeLayout.InspectorOverlayMaxTotalWidth
        val showInspectorPane = route != null && inspectorWidthFits
        val showInspectorOverlay = route != null && !inspectorWidthFits

        // System back priority (LATER registrations win in Compose):
        // preview (its own handler, registered last) > settings sheet
        // (owned by FloePageSheet) > inspector (owned by FloeInspectorPane)
        // > drawer > base navigation. The base handler only engages when it
        // has a real navigation action, so at New Task root with nothing
        // open, system back delegates to the platform normally.
        val baseNavCanRun = !persistentSidebar && route == null && !drawerOpen &&
            !settingsVisible && !previewVisible &&
            selectionKey != SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK).key
        BackHandler(enabled = baseNavCanRun) {
            selection = SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK)
            selectionKey = selection.key
        }
        BackHandler(enabled = drawerOpen) { drawerOpen = false }

        val select: (SidebarSelection) -> Unit = { target ->
            selection = target
            selectionKey = target.key
            drawerOpen = false
            // Leaving the visible conversation surface ends temporary chat on
            // iOS; G01 has no temporary session yet, so navigation just moves
            // the ordinary route state.
            inspectorRoute = null
        }

        val sidebarBody: @Composable (Boolean) -> Unit = { inDrawer ->
            FloeSidebar(
                selection = selection,
                onSelect = select,
                // Settings is a Dialog over the shell; close the compact drawer
                // first so dismissing it later cannot reveal a stale drawer
                // (finish review F04). Persistent sidebar is unaffected.
                onOpenSettings = {
                    drawerOpen = false
                    settingsVisible = true
                },
                onCollapseRequested = if (twoColumn && !inDrawer) {
                    { sidebarCollapsed = true }
                } else null,
            )
        }

        val detail: @Composable () -> Unit = {
            Column(Modifier.fillMaxSize()) {
                FloeDetailColumn(
                    selection = selection,
                    showSidebarToggle = !persistentSidebar && twoColumn,
                    onExpandSidebar = { sidebarCollapsed = false },
                    onOpenDrawer = { drawerOpen = true },
                    compact = !twoColumn,
                    inspectorRoute = route,
                    onInspectorDismiss = { inspectorRoute = null },
                    onOpenSettingsSection = { sectionKey ->
                        drawerOpen = false
                        settingsSectionKey = sectionKey
                        settingsVisible = true
                    },
                )
            }
        }

        if (persistentSidebar) {
            Row(Modifier.fillMaxSize().statusBarsPadding()) {
                Box(
                    Modifier
                        .widthIn(FloeLayout.SidebarMinWidth, FloeLayout.SidebarMaxWidth)
                        .width(FloeLayout.SidebarIdealWidth)
                        .fillMaxHeight(),
                ) { sidebarBody(false) }
                FloeVerticalDivider()
                Box(
                    Modifier
                        .weight(1f)
                        .fillMaxHeight(),
                ) {
                    Row(Modifier.fillMaxSize()) {
                        Box(Modifier.weight(1f).fillMaxHeight()) { detail() }
                        if (showInspectorPane && route != null) {
                            FloeVerticalDivider()
                            Box(
                                Modifier
                                    .widthIn(FloeLayout.InspectorMinWidth, FloeLayout.InspectorMaxWidth)
                                    .width(FloeLayout.InspectorIdealWidth)
                                    .fillMaxHeight(),
                            ) {
                                FloeInspectorPane(route = route, onDismiss = { inspectorRoute = null })
                            }
                        }
                    }
                }
            }
        } else {
            Box(Modifier.fillMaxSize().statusBarsPadding()) {
                detail()
                // Compact drawer: iOS phone idiom — width
                // min(390, max(300, w-44)), rounded corner, slight scale of
                // the content plane, dim scrim, tap-scrim or back to close.
                AnimatedVisibility(
                    visible = drawerOpen,
                    enter = fadeIn(tween(200)) + slideInHorizontally(tween(320, easing = LinearOutSlowInEasing)) { -it },
                    exit = fadeOut(tween(180)) + slideOutHorizontally(tween(260)) { -it },
                ) {
                    Box(Modifier.fillMaxSize()) {
                        Box(
                            Modifier
                                .fillMaxSize()
                                .background(Floe.colors.label.copy(alpha = 0.22f))
                                .clickable { drawerOpen = false },
                        )
                        Box(
                            Modifier
                                .width(drawerWidthPx(totalWidthDp))
                                .fillMaxHeight()
                                .padding(vertical = 6.dp)
                                .padding(start = 4.dp, end = 6.dp)
                                .clip(RoundedCornerShape(FloeLayout.DrawerCorner))
                                .background(Floe.colors.sidebarSurface),
                        ) { sidebarBody(true) }
                    }
                }
            }
        }

        if (showInspectorOverlay && route != null) {
            // Local adaptation (recorded in UI_FOUNDATION.md): when a
            // persistent sidebar + readable content + inspector minimum
            // widths cannot coexist, the inspector takes a full-height
            // trailing overlay instead of squeezing content to near zero.
            Box(Modifier.fillMaxSize().statusBarsPadding()) {
                Box(
                    Modifier
                        .fillMaxSize()
                        .background(Floe.colors.label.copy(alpha = 0.18f))
                        .clickable { inspectorRoute = null },
                )
                Box(
                    Modifier
                        .widthIn(max = overlayMaxWidthDp)
                        .fillMaxHeight()
                        .background(Floe.colors.readingSurface),
                ) { FloeInspectorPane(route = route, onDismiss = { inspectorRoute = null }) }
            }
        }

        SettingsSheet(
            visible = settingsVisible,
            initialSection = settingsSectionKey,
            themeMode = themeMode,
            onThemeModeChange = onThemeModeChange,
            onDismiss = { settingsVisible = false },
            // The preview is composed in the shell window, while settings is a
            // separate Dialog window. Open it only after the sheet is gone so
            // one tap reveals the preview instead of stacking it behind the
            // still-open Dialog (finish review F04).
            onOpenPreview = {
                // Defensively clear both shell overlays: the preview is the
                // topmost explicit page, so Back from it must return to the
                // underlying route/home with no stale drawer or sheet.
                drawerOpen = false
                settingsVisible = false
                previewVisible = true
            },
        )

        if (previewVisible) {
            ComponentPreviewScreen(onDismiss = { previewVisible = false })
        }
    }
}

private fun drawerWidthPx(availableDp: Float) = FloeLayout.drawerWidth(availableDp)

/* --------------------------- selection persistence -------------------------- */

internal val SidebarSelection.key: String
    get() = when (this) {
        is SidebarSelection.Workbench -> "w:${selection.name}"
        is SidebarSelection.More -> "m:${destination.name}"
        is SidebarSelection.Workspace -> "p:$workspaceId"
        is SidebarSelection.Conversation -> "c:$conversationId"
    }

internal fun selectionFromKey(key: String): SidebarSelection = when {
    key.startsWith("w:") -> SidebarSelection.Workbench(WorkbenchSelection.valueOf(key.removePrefix("w:")))
    key.startsWith("m:") -> SidebarSelection.More(MoreDestination.valueOf(key.removePrefix("m:")))
    key.startsWith("p:") -> SidebarSelection.Workspace(key.removePrefix("p:"))
    key.startsWith("c:") -> SidebarSelection.Conversation(key.removePrefix("c:"))
    else -> SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK)
}

internal fun encodeInspectorRoute(route: InspectorRoute): String =
    "${route.content.name}|${route.conversationId ?: ""}"

internal fun decodeInspectorRoute(raw: String): InspectorRoute {
    val parts = raw.split('|')
    return InspectorRoute(
        content = runCatching { InspectorContent.valueOf(parts[0]) }.getOrDefault(InspectorContent.PROGRESS),
        conversationId = parts.getOrNull(1)?.takeIf { it.isNotEmpty() },
    )
}
