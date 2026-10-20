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
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
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
import com.floe.android.feature.providers.FloeProviderSettingsDestination
import com.floe.android.host.AttachmentPickerEffect
import com.floe.android.host.RuntimeHost
import com.floe.android.host.RuntimeHostProvider
import com.floe.android.host.rememberRuntimeHost
import kotlinx.coroutines.launch

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
    val runtimeHost = rememberRuntimeHost()
    // The shell renders with or without the runtime host; without it every
    // G02 surface keeps its honest G01 unavailable state.
    if (runtimeHost != null) {
        RuntimeHostProvider(runtimeHost) {
            FloeShellContent(
                themeMode = themeMode,
                onThemeModeChange = onThemeModeChange,
                runtimeHost = runtimeHost,
            )
        }
    } else {
        FloeShellContent(
            themeMode = themeMode,
            onThemeModeChange = onThemeModeChange,
            runtimeHost = null,
        )
    }
}

@Composable
private fun FloeShellContent(
    themeMode: FloeThemeMode,
    onThemeModeChange: (FloeThemeMode) -> Unit,
    runtimeHost: RuntimeHost?,
) {
    var selectionKey by rememberSaveable { mutableStateOf(SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK).key) }
    var selection: SidebarSelection by mutableStateOf(selectionFromKey(selectionKey))
    var settingsVisible by rememberSaveable { mutableStateOf(false) }
    var settingsSectionKey by rememberSaveable { mutableStateOf("") }
    var previewVisible by rememberSaveable { mutableStateOf(false) }
    var inspectorRoute by rememberSaveable { mutableStateOf<String?>(null) }
    var sidebarCollapsed by rememberSaveable { mutableStateOf(false) }
    var drawerOpen by rememberSaveable { mutableStateOf(false) }
    val scope = androidx.compose.runtime.rememberCoroutineScope()

    // G02 host presentation effects: navigation / inspector / permissions /
    // attachment picker. Observed here so composables stay observe-only.
    if (runtimeHost != null) {
        AttachmentPickerEffect(runtimeHost)
        val requestedNavigation by runtimeHost.conversations.navigationRequest.collectAsState()
        LaunchedEffect(requestedNavigation) {
            requestedNavigation?.let { target ->
                runtimeHost.conversations.navigationRequest.value = null
                applyHostNavigation(target, selection, runtimeHost) { next ->
                    selection = next
                    selectionKey = next.key
                    drawerOpen = false
                    inspectorRoute = null
                }
            }
        }
        val requestedInspector by runtimeHost.conversations.inspectorRequest.collectAsState()
        LaunchedEffect(requestedInspector) {
            requestedInspector?.let { (content, conversationId) ->
                runtimeHost.conversations.inspectorRequest.value = null
                inspectorRoute = encodeInspectorRoute(
                    InspectorRoute(content = mapInspectorContent(content), conversationId = conversationId),
                )
            }
        }
        val permissionsConversation by runtimeHost.conversations.permissionsRequest.collectAsState()
        LaunchedEffect(permissionsConversation) {
            permissionsConversation?.let { conversationId ->
                runtimeHost.conversations.permissionsRequest.value = null
                inspectorRoute = encodeInspectorRoute(
                    InspectorRoute(content = InspectorContent.PERMISSIONS, conversationId = conversationId),
                )
            }
        }
    }

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
            val opensSkillsSheet = target is SidebarSelection.More &&
                target.destination == MoreDestination.SKILLS
            val currentTemporary = runtimeHost?.conversations?.activeTemporarySession()
            val leavingConversation = selection is SidebarSelection.Conversation &&
                target.key != selection.key
            when {
                // The Skills sidebar row opens the Settings sheet at the
                // Skills section (the integrations destination lives in the
                // settings detail pane per its host contract).
                opensSkillsSheet -> {
                    drawerOpen = false
                    settingsSectionKey =
                        com.floe.android.design.FloeSettingsSection.SKILLS.name
                    settingsVisible = true
                }
                // Genuine route transition while a temporary session owns the
                // surface: fence admission BEFORE the transition (TMP-NAV-2);
                // the async drain continues afterwards.
                runtimeHost != null && currentTemporary != null && leavingConversation -> {
                    val ref = currentTemporary
                    scope.launch {
                        runtimeHost.conversations.tempFence.beginEnd(ref)
                        val admitted = runtimeHost.conversations.tempFence.awaitAdmission(ref)
                        if (admitted) {
                            selection = target
                            selectionKey = target.key
                            drawerOpen = false
                            inspectorRoute = null
                        }
                    }
                }
                else -> {
                    selection = target
                    selectionKey = target.key
                    drawerOpen = false
                    // Ordinary navigation (iOS semantics): leaving the visible
                    // conversation surface ends temporary chat; rotation,
                    // recreation, background and lock never reach this path.
                    inspectorRoute = null
                }
            }
        }

        val sidebarBody: @Composable (Boolean) -> Unit = { inDrawer ->
            FloeSidebar(
                selection = selection,
                onSelect = select,
                // Settings is a Dialog over the shell; close the compact drawer
                // first so dismissing it later cannot reveal a stale drawer
                // (finish review F04). Persistent sidebar is unaffected.
                // The footer gear is an ORDINARY settings presentation: drop a
                // stale deep-link section so the sheet opens with both panes /
                // the compact list root instead of the last requested section.
                onOpenSettings = {
                    drawerOpen = false
                    settingsSectionKey = ""
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
                    runtimeHost = runtimeHost,
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
            runtimeHost = runtimeHost,
            providerContent = if (runtimeHost == null) {
                null
            } else {
                { geometry, contentModifier ->
                    val providerState by runtimeHost.providers.destination.collectAsState()
                    FloeProviderSettingsDestination(
                        state = providerState,
                        holder = runtimeHost.providers.flowHolder,
                        modifier = contentModifier,
                        hostGeometry = geometry,
                    )
                }
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

/** Maps the component's inspector vocabulary onto the shell routes. */
private fun mapInspectorContent(content: com.floe.android.feature.conversation.InspectorRouteUi): InspectorContent =
    when (content) {
        com.floe.android.feature.conversation.InspectorRouteUi.PROGRESS -> InspectorContent.PROGRESS
        com.floe.android.feature.conversation.InspectorRouteUi.WORKSPACE_FILES -> InspectorContent.WORKSPACE_FILES
        com.floe.android.feature.conversation.InspectorRouteUi.CHANGES -> InspectorContent.CHANGES
        com.floe.android.feature.conversation.InspectorRouteUi.BROWSER -> InspectorContent.BROWSER
        com.floe.android.feature.conversation.InspectorRouteUi.TERMINAL -> InspectorContent.TERMINAL
        com.floe.android.feature.conversation.InspectorRouteUi.CHILD_AGENTS -> InspectorContent.CHILD_AGENTS
        com.floe.android.feature.conversation.InspectorRouteUi.PERMISSIONS -> InspectorContent.PERMISSIONS
    }

/**
 * Applies a host-requested navigation. Leaving a temporary conversation
 * surfaces fences through [com.floe.android.host.TemporaryNavigationFence]
 * before the route actually moves; the caller's [commit] performs the move.
 */
private suspend fun applyHostNavigation(
    target: SidebarSelection,
    current: SidebarSelection,
    runtimeHost: RuntimeHost,
    commit: (SidebarSelection) -> Unit,
) {
    val currentTemporary = runtimeHost.conversations.activeTemporarySession()
    val leavingConversation = current is SidebarSelection.Conversation &&
        target.key != current.key
    if (currentTemporary != null && leavingConversation) {
        runtimeHost.conversations.tempFence.beginEnd(currentTemporary)
        if (!runtimeHost.conversations.tempFence.awaitAdmission(currentTemporary)) {
            return
        }
    }
    commit(target)
}
