// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties
import com.floe.android.design.*
import com.floe.android.feature.ide.FloeIdeWorkspace
import com.floe.android.feature.ide.IdeBottomAccessory
import com.floe.android.host.G04WorkspaceEditorController
import com.floe.android.host.G04WorkspaceBridgeClient
import com.floe.android.host.RuntimeHost
import com.floe.android.host.RuntimeHostReadiness
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.roundToInt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

private class WorkspacePaneOwner {
    val live = AtomicBoolean(true)
}
private typealias WorkspacePaneBinding = G04WorkspaceEditorController.Binding
private enum class WorkspaceAction(val label: Int) {
    FILE(R.string.workspace_new_file), DIRECTORY(R.string.workspace_new_folder),
    MOVE(R.string.workspace_move), COPY(R.string.workspace_copy), DELETE(R.string.workspace_delete),
}
private enum class WorkspaceToolbarMenu { NEW, MORE }

/** Visible ordinary-task entry only. Opening the pane may bind that task's
 * real workspace; composition elsewhere never creates one or starts a Run.
 * The service owns drafts after this presentation is dismissed.
 *
 * Header ownership (Main aesthetics correction 2026-10-25, per the user
 * objection to the six oversized pills): this pane renders the ONE header row
 * — title, New (+), More (…), close — in every state while [title] comes from
 * the inspector and Close stays always visible. FloeInspector skips its
 * generic header only for this tab; the shared chrome, geometry and divider
 * are reproduced exactly (ToolbarHeight + 4 row, 10dp side padding, 34dp
 * circles inside 48dp targets), and the New/More command controls appear
 * only while the workspace is actually bound. 430dp has room for the title
 * (~120dp of its own, weighted with ellipsis on compact) plus three 48dp
 * targets; no second mostly-empty strip is ever added.
 */
@Composable
internal fun WorkspaceFilesPane(host: RuntimeHost?, taskID: String?, title: String, onDismiss: () -> Unit) {
    val context = LocalContext.current.applicationContext
    val entry = taskID?.let { host?.conversations?.entryFor(it) }
    if (host == null || taskID == null || entry == null || entry.isTemporary) {
        Column(Modifier.fillMaxSize()) {
            WorkspacePaneHeader(title = title, onDismiss = onDismiss)
            FloeUnavailableView(icon = FloeIcons.Folder, title = stringResource(R.string.inspector_files),
                description = stringResource(if (entry?.isTemporary == true) R.string.workspace_temporary_unavailable else R.string.root_detail_absent),
                modifier = Modifier.weight(1f))
        }
        return
    }
    val readiness by host.readiness.collectAsState()
    val domain = readiness.domains["workspaceDomain"] as? RuntimeHostReadiness.DomainReadiness.Available
    val owner = remember(host, taskID, entry, domain?.generation) { WorkspacePaneOwner() }
    var binding by remember(owner) { mutableStateOf<WorkspacePaneBinding?>(null) }
    var failure by remember(owner) { mutableStateOf<String?>(null) }
    var retry by remember(owner) { mutableIntStateOf(0) }
    val scope = rememberCoroutineScope()
    val errorText: (String) -> String = { code ->
        context.getString(when (code) {
            "staleRevision", "conflict", "dirtyDocument" -> R.string.workspace_conflict_error
            "secretFile", "escapesRoot", "notAdmitted" -> R.string.workspace_access_error
            "contentTooLarge", "bufferLimit" -> R.string.workspace_size_error
            "languageServerUnavailable" -> R.string.workspace_language_unavailable
            "runtimeBusy" -> R.string.workspace_runtime_slot_busy
            "operationPending" -> R.string.workspace_run_pending
            "ownerChanged", "ownerUnavailable", "retired", "epochMismatch" -> R.string.workspace_owner_error
            else -> R.string.workspace_operation_error
        })
    }
    DisposableEffect(owner) {
        onDispose { owner.live.set(false) }
    }
    LaunchedEffect(owner, retry, readiness.storeReady) {
        binding = null; failure = null
        if (domain == null || !readiness.storeReady) {
            failure = context.getString(R.string.inspector_runtime_pending)
            return@LaunchedEffect
        }
        try {
            val retained = withContext(host.ioDispatcher) { host.workspaceEditors.acquire(taskID, errorText, owner.live) }
            if (owner.live.get() && retained.isCurrent()) binding = retained
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            if (owner.live.get()) failure = errorText((error as? G04WorkspaceBridgeClient.Failure)?.code ?: "internalError")
        }
    }
    val bound = binding
    if (bound == null) {
        Column(Modifier.fillMaxSize()) {
            WorkspacePaneHeader(title = title, onDismiss = onDismiss)
            Column(Modifier.weight(1f).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (failure == null) FloeActivityIndicator() else {
                    FloeText(failure!!, style = Floe.typography.body, color = Floe.colors.secondaryLabel)
                    FloeCapsuleButton(stringResource(R.string.workspace_retry), onClick = { retry++ })
                }
            }
        }
        return
    }
    val presenter = bound.presenter
    val sourceLane = remember(bound, host) {
        host.nativeRootEpoch()?.let { epoch ->
            host.workspaceSourceHost?.laneFor(
                taskID = bound.client.taskID, workspaceID = bound.client.workspaceID,
                nativeEpoch = epoch, hostGeneration = host.commandClient.generation(),
                isCurrentOwner = bound.isCurrent,
            )
        }
    }
    var sourcesVisible by remember(owner) { mutableStateOf(false) }
    var recoveryVisible by remember(owner) { mutableStateOf(false) }
    var networkVisible by remember(owner) { mutableStateOf(false) }
    var action by remember(owner) { mutableStateOf<WorkspaceAction?>(null) }
    var toolbarMenu by remember(owner) { mutableStateOf<WorkspaceToolbarMenu?>(null) }
    var newTriggerBounds by remember(owner) { mutableStateOf<Rect?>(null) }
    var moreTriggerBounds by remember(owner) { mutableStateOf<Rect?>(null) }
    var source by remember(owner) { mutableStateOf("") }
    var destination by remember(owner) { mutableStateOf("") }
    var operationError by remember(owner) { mutableStateOf<String?>(null) }
    var busy by remember(owner) { mutableStateOf(false) }
    val office = (context as? FloeApplication)?.officePreviews
    fun openOffice(path: String): Boolean {
        if (!com.floe.android.host.OfficePreviewController.supports(path)) return false
        val epoch = host.nativeRootEpoch()
        if (office == null || epoch == null || epoch <= 0 || !bound.isCurrent()) {
            office?.reportSourceUnavailable()
            return true
        }
        val generation = host.commandClient.generation()
        val sourceOwner = com.floe.android.host.WorkspaceOfficeSnapshotStager.Owner(
            bound.client.taskID, bound.client.workspaceID, epoch, generation)
        office.openWorkspace(sourceOwner, path) {
            // After the explicit click, the request belongs to the service,
            // not this pane's composition. Native egress revalidates its exact
            // workspace authority; rotation must not retire an input read.
            host.nativeRootEpoch() == epoch && host.commandClient.generation() == generation &&
                host.conversations.entryFor(sourceOwner.taskID)?.isTemporary == false
        }
        return true
    }
    fun openFile(path: String) { if (!openOffice(path)) presenter.openFile(path) }
    Column(Modifier.fillMaxSize()) {
        // One header row: title + New (+) + More (…) + close. The six REAL
        // actions are unchanged and simply regroup the way the iPad files
        // toolbar groups them — (+) opens New file / New folder, (…) opens
        // File actions / Provider files / Network storage / Recover edits —
        // each popup anchored to its measured trigger inside the live window
        // (never a full-screen dialog). System Back / outside tap dismiss the
        // menu first; the secondary forms then open normally on the next
        // explicit selection, exactly like the previous pills did.
        WorkspacePaneHeader(title = title, onDismiss = onDismiss) {
            FloeCircleButton(
                icon = FloeIcons.Plus,
                contentDescription = stringResource(R.string.workspace_new_menu),
                onClick = { toolbarMenu = if (toolbarMenu == WorkspaceToolbarMenu.NEW) null else WorkspaceToolbarMenu.NEW },
                enabled = !busy,
                visualSize = 34.dp,
                iconSize = 16.dp,
                modifier = Modifier.testTag("workspace.newMenuTrigger")
                    .onGloballyPositioned { coordinates -> newTriggerBounds = coordinates.boundsInWindow() },
            )
            FloeCircleButton(
                icon = FloeIcons.Ellipsis,
                contentDescription = stringResource(R.string.workspace_more_menu),
                onClick = { toolbarMenu = if (toolbarMenu == WorkspaceToolbarMenu.MORE) null else WorkspaceToolbarMenu.MORE },
                enabled = !busy,
                visualSize = 34.dp,
                iconSize = 16.dp,
                modifier = Modifier.testTag("workspace.moreMenuTrigger")
                    .onGloballyPositioned { coordinates -> moreTriggerBounds = coordinates.boundsInWindow() },
            )
        }
        // Host-supplied attached-pane accessory (2026-10-25 device evidence:
        // the toolbar toggle advertised a slot no content ever filled). The
        // content is the conversation's REAL owned terminal — the same
        // Application-owned G04TerminalHostController + WorkspaceTerminalPane
        // the inspector TERMINAL tab uses, with its explicit start-on-show,
        // single-slot busy refusal and honest availability copy unchanged.
        // The controller is read live inside the content lambda so the slot
        // never pins a stale (or null) controller from an older composition.
        // Slot visibility alone never mints a second PTY: an already-live
        // session is attached, not restarted; dismissing this presentation
        // never closes the owned session (service-owned lifecycle).
        FloeIdeWorkspace(
            presenter,
            onBack = onDismiss,
            modifier = Modifier.weight(1f),
            onOpenDocument = ::openOffice,
            bottomAccessory = IdeBottomAccessory(
                id = "terminal",
                label = stringResource(R.string.inspector_terminal),
                content = { WorkspaceTerminalPane(host.workspaceTerminal, bound.client.taskID) },
            ),
        )
    }
    val newAnchor = newTriggerBounds
    if (toolbarMenu == WorkspaceToolbarMenu.NEW && newAnchor != null) {
        WorkspaceAnchoredMenu(
            anchorBounds = newAnchor,
            tag = "workspace.newMenu",
            items = listOf(
                WorkspaceMenuItem(stringResource(R.string.workspace_new_file), enabled = !busy) {
                    toolbarMenu = null
                    source = ""; destination = ""; operationError = null
                    action = WorkspaceAction.FILE
                },
                WorkspaceMenuItem(stringResource(R.string.workspace_new_folder), enabled = !busy) {
                    toolbarMenu = null
                    source = ""; destination = ""; operationError = null
                    action = WorkspaceAction.DIRECTORY
                },
            ),
            onDismiss = { toolbarMenu = null },
        )
    }
    val moreAnchor = moreTriggerBounds
    if (toolbarMenu == WorkspaceToolbarMenu.MORE && moreAnchor != null) {
        WorkspaceAnchoredMenu(
            anchorBounds = moreAnchor,
            tag = "workspace.moreMenu",
            items = listOf(
                WorkspaceMenuItem(stringResource(R.string.workspace_file_actions), enabled = !busy) {
                    toolbarMenu = null
                    source = ""; destination = ""; operationError = null
                    action = WorkspaceAction.MOVE
                },
                // Menu labels are full EN/zh titles: the previous capsule row
                // used the "Network" short title with the full name only as
                // an a11y description; a menu row shows the real name (iOS
                // FileInspectorView workspaceActions menu does the same).
                WorkspaceMenuItem(stringResource(R.string.workspace_source_title), enabled = !busy) {
                    toolbarMenu = null; sourcesVisible = true
                },
                WorkspaceMenuItem(stringResource(R.string.network_workspace_title), enabled = !busy) {
                    toolbarMenu = null; networkVisible = true
                },
                WorkspaceMenuItem(stringResource(R.string.workspace_recovery_title), enabled = !busy) {
                    toolbarMenu = null; recoveryVisible = true
                },
            ),
            onDismiss = { toolbarMenu = null },
        )
    }
    WorkspaceRecoveryPanel(host, bound.client, recoveryVisible, onDismiss = { recoveryVisible = false },
        onOpenFile = ::openFile, onTreeChanged = { bound.ide.refreshWorkspace(); presenter.refreshTreeKeepingExpansion() })
    FloeActionSheet(visible = networkVisible, onDismiss = { networkVisible = false }, maxCardWidth = 640.dp) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState())) {
            WorkspaceNetworkPanel(
                host = host, taskID = bound.client.taskID, workspaceID = bound.client.workspaceID,
                isOwnerCurrent = bound.isCurrent,
                onOpenWorkspaceFile = { path -> openFile(path); networkVisible = false },
                onWorkspaceTreeChanged = { bound.ide.refreshWorkspace(); presenter.refreshTreeKeepingExpansion() },
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
    FloeActionSheet(visible = sourcesVisible, onDismiss = { sourcesVisible = false }, maxCardWidth = 640.dp) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState())) {
            WorkspaceSourcePanel(sourceLane,
                onOpenWorkspaceFile = { path -> openFile(path); sourcesVisible = false },
                onWorkspaceTreeChanged = { bound.ide.refreshWorkspace(); presenter.refreshTreeKeepingExpansion() },
                modifier = Modifier.fillMaxWidth())
        }
    }
    FloeActionSheet(visible = action != null, onDismiss = { if (!busy) action = null }) {
        val selected = action ?: return@FloeActionSheet
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            FloeText(stringResource(selected.label), style = Floe.typography.toolbarTitle, color = Floe.colors.label)
            if (selected in setOf(WorkspaceAction.MOVE, WorkspaceAction.COPY, WorkspaceAction.DELETE)) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf(WorkspaceAction.MOVE, WorkspaceAction.COPY, WorkspaceAction.DELETE).forEach { item ->
                        FloeCapsuleButton(stringResource(item.label), onClick = { action = item; operationError = null },
                            modifier = Modifier.weight(1f), enabled = !busy, prominent = item == selected)
                    }
                }
            }
            FloePlainFormField(stringResource(R.string.workspace_relative_path), source, { source = it }, enabled = !busy, monospaced = true)
            if (selected == WorkspaceAction.MOVE || selected == WorkspaceAction.COPY) {
                FloePlainFormField(stringResource(R.string.workspace_destination_path), destination, { destination = it }, enabled = !busy, monospaced = true)
            }
            if (selected == WorkspaceAction.DELETE) FloeText(stringResource(R.string.workspace_delete_confirmation), style = Floe.typography.body, color = Floe.colors.secondaryLabel)
            operationError?.let { FloeText(it, style = Floe.typography.body, color = Floe.colors.secondaryLabel) }
            if (busy) FloeActivityIndicator()
            FloeCapsuleButton(stringResource(if (selected == WorkspaceAction.DELETE) R.string.workspace_delete else R.string.workspace_apply),
                enabled = !busy && source.isNotBlank() && (selected !in setOf(WorkspaceAction.MOVE, WorkspaceAction.COPY) || destination.isNotBlank()),
                prominent = true, onClick = {
                    val path = source.trim(); val target = destination.trim(); val requested = selected
                    busy = true; operationError = null
                    scope.launch {
                        try {
                            withContext(host.ioDispatcher) {
                                val operation = when (requested) {
                                    WorkspaceAction.FILE -> "createFile"; WorkspaceAction.DIRECTORY -> "createDirectory"
                                    WorkspaceAction.MOVE -> "move"; WorkspaceAction.COPY -> "copy"; WorkspaceAction.DELETE -> "delete"
                                }
                                bound.client.request(operation, buildJsonObject {
                                    if (requested == WorkspaceAction.MOVE || requested == WorkspaceAction.COPY) {
                                        put("from", path); put("to", target)
                                    } else put("path", path)
                                    if (requested == WorkspaceAction.FILE) put("content", "")
                                    if (requested == WorkspaceAction.DELETE) put("recursive", true)
                                })
                            }
                            if (owner.live.get()) { action = null; bound.ide.refreshWorkspace(); presenter.refreshTreeKeepingExpansion() }
                        } catch (error: Exception) {
                            if (error is CancellationException) throw error
                            if (owner.live.get()) operationError = errorText((error as? G04WorkspaceBridgeClient.Failure)?.code ?: "internalError")
                        } finally { if (owner.live.get()) busy = false }
                    }
                })
            FloeCapsuleButton(stringResource(R.string.cancel), onClick = { action = null }, enabled = !busy)
        }
    }
}

/**
 * The pane's single header row, byte-for-byte reproducing the inspector's
 * generic chrome geometry (height, padding, title style, 34dp close circle
 * with contentDescription [R.string.close], trailing placement) and its
 * divider, with optional [actions] between the weighted, ellipsized title
 * and the always-visible close. Only WorkspaceFilesPane uses it, so the
 * design-system sheet/theme files stay untouched per Main's split; no
 * global header state and no effects — plain composable slotting.
 */
@Composable
private fun WorkspacePaneHeader(
    title: String,
    onDismiss: () -> Unit,
    actions: @Composable RowScope.() -> Unit = {},
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(FloeLayout.ToolbarHeight + 4.dp)
            .padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        FloeText(
            title,
            style = Floe.typography.toolbarTitle,
            color = Floe.colors.label,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        actions()
        FloeCircleButton(
            icon = FloeIcons.Xmark,
            contentDescription = stringResource(R.string.close),
            onClick = onDismiss,
            visualSize = 34.dp,
            iconSize = 15.dp,
        )
    }
    FloeDivider()
}

/** One row inside the pane-local compact command menu. */
private class WorkspaceMenuItem(val label: String, val enabled: Boolean, val onClick: () -> Unit)

private data class WorkspaceMenuMetrics(
    val horizontalMarginPx: Int,
    val verticalMarginPx: Int,
    val overlapPx: Int,
    val topInsetPx: Int,
    val imeBottomPx: Int,
)

/** Real free space (px) for the menu above/below the measured trigger,
 * between the safeDrawing top and the IME-excluded bottom of the LIVE
 * window — the same numbers the placement provider and the content height
 * bound use, so origin clamping and size clamping never disagree. */
private fun workspaceMenuFreeSpace(
    anchor: Rect,
    windowHeightPx: Int,
    metrics: WorkspaceMenuMetrics,
): Pair<Float, Float> {
    val safeWindowHeight = windowHeightPx.coerceAtLeast(1)
    val spaceAbove =
        (anchor.top - metrics.verticalMarginPx - metrics.topInsetPx - metrics.overlapPx)
            .coerceAtLeast(0f)
    val spaceBelow =
        (safeWindowHeight - anchor.bottom - metrics.verticalMarginPx - metrics.imeBottomPx +
            metrics.overlapPx)
            .coerceAtLeast(0f)
    return spaceAbove to spaceBelow
}

/**
 * Trailing-edge placement policy mirrored from the proven provider protocol
 * menu (feature/providers/ProviderProtocolMenu.kt, ⇄ iPad pull-down menu):
 * aligns the menu's right edge to the measured trigger, prefers the space
 * above with a small overlap, flips below when neither side fits and picks
 * the roomier side, and clamps every edge into the live window. Pure math
 * over the actual anchor/window/popup sizes — no global screen pixels, no
 * full-screen sheet on tablets.
 */
private fun resolveWorkspaceMenuPosition(
    anchor: Rect,
    windowWidthPx: Int,
    windowHeightPx: Int,
    popupWidthPx: Int,
    popupHeightPx: Int,
    metrics: WorkspaceMenuMetrics,
): IntOffset {
    val safeWindowWidth = windowWidthPx.coerceAtLeast(1)
    val safeWindowHeight = windowHeightPx.coerceAtLeast(1)
    val widthPx = popupWidthPx.coerceIn(1, (safeWindowWidth - metrics.horizontalMarginPx * 2).coerceAtLeast(1))
    val popupHeight = popupHeightPx.coerceAtLeast(1)
    val maxX = (safeWindowWidth - metrics.horizontalMarginPx - widthPx)
        .coerceAtLeast(metrics.horizontalMarginPx)
    val x = (anchor.right.roundToInt() - widthPx)
        .coerceIn(metrics.horizontalMarginPx, maxX)
    val (spaceAbove, spaceBelow) = workspaceMenuFreeSpace(anchor, safeWindowHeight, metrics)
    val placeAbove = when {
        spaceAbove >= popupHeight -> true
        spaceBelow >= popupHeight -> false
        else -> spaceAbove >= spaceBelow
    }
    val rawY = if (placeAbove) {
        anchor.top.roundToInt() - popupHeight + metrics.overlapPx
    } else {
        anchor.bottom.roundToInt() - metrics.overlapPx
    }
    val topLimitPx = metrics.verticalMarginPx + metrics.topInsetPx
    val maxY = (safeWindowHeight - metrics.verticalMarginPx - metrics.imeBottomPx - popupHeight)
        .coerceAtLeast(topLimitPx)
    return IntOffset(x, rawY.coerceIn(topLimitPx, maxY))
}

private class WorkspaceMenuPositionProvider(
    private val anchor: Rect,
    private val metrics: WorkspaceMenuMetrics,
) : PopupPositionProvider {
    override fun calculatePosition(
        anchorBounds: IntRect,
        windowSize: IntSize,
        layoutDirection: LayoutDirection,
        popupContentSize: IntSize,
    ): IntOffset = resolveWorkspaceMenuPosition(
        anchor = anchor,
        windowWidthPx = windowSize.width,
        windowHeightPx = windowSize.height,
        popupWidthPx = popupContentSize.width,
        popupHeightPx = popupContentSize.height,
        metrics = metrics,
    )
}

/**
 * WorkspaceFiles-local compact anchored menu (presentation wrapper only).
 * A separate focusable popup window: 272dp menu width clamped to the live
 * window, content-fit height, 48dp rows independent of label size, and
 * outside-tap + system-Back dismissal that wins while the menu is open, so
 * dismissing New/More returns to the pane and the New file / New folder /
 * panel forms then open normally from the next explicit selection.
 * Deliberately NOT a new design-system sheet/popover API (FloeSheet stays
 * untouched per Main) and never a full-screen dialog for six commands.
 */
@Composable
private fun WorkspaceAnchoredMenu(
    anchorBounds: Rect,
    tag: String,
    items: List<WorkspaceMenuItem>,
    onDismiss: () -> Unit,
) {
    val density = LocalDensity.current
    val windowInfo = LocalWindowInfo.current
    val windowWidthPx = windowInfo.containerSize.width.coerceAtLeast(1)
    val windowHeightPx = windowInfo.containerSize.height.coerceAtLeast(1)
    val menuWidth = 272.dp.coerceAtMost(with(density) { windowWidthPx.toDp() } - 32.dp)
        .coerceAtLeast(1.dp)
    // REAL live-window insets read per composition (the same source the
    // composer/geometry lanes use): the menu may never cover the status/
    // cutout band or hide behind an open IME, on a short landscape phone or
    // at any font scale. No global display metrics, no guessed rows.
    val metrics = WorkspaceMenuMetrics(
        horizontalMarginPx = with(density) { 16.dp.roundToPx() },
        verticalMarginPx = with(density) { 12.dp.roundToPx() },
        overlapPx = with(density) { 6.dp.roundToPx() },
        topInsetPx = WindowInsets.safeDrawing.getTop(density),
        imeBottomPx = maxOf(WindowInsets.safeDrawing.getBottom(density), WindowInsets.ime.getBottom(density)),
    )
    val (spaceAbovePx, spaceBelowPx) = workspaceMenuFreeSpace(anchorBounds, windowHeightPx, metrics)
    val maxMenuHeight = with(density) {
        maxOf(spaceAbovePx, spaceBelowPx).roundToInt().coerceAtLeast(1).toDp()
    }
    val scrollState = rememberScrollState()
    val shape = RoundedCornerShape(FloeLayout.BubbleCorner)
    Popup(
        popupPositionProvider = WorkspaceMenuPositionProvider(anchorBounds, metrics),
        onDismissRequest = onDismiss,
        properties = PopupProperties(
            focusable = true,
            dismissOnBackPress = true,
            dismissOnClickOutside = true,
            clippingEnabled = false,
        ),
    ) {
        // Content-fit bounded card: it grows with its rows and is clamped to
        // the actual free space on the roomier side; anything taller (font
        // scale, translation, 4-row More menu on a short window) scrolls
        // INSIDE the card instead of overflowing the window. 48dp targets
        // and the focusable-popup Back behaviour are unchanged. The surface
        // chrome is the existing Floe popover one (shadow + corner clip +
        // hairline), like PopoverSurfaceCard / FloeHostPopoverCard.
        Box(
            modifier = Modifier
                .width(menuWidth)
                .heightIn(max = maxMenuHeight)
                .testTag(tag)
                .shadow(elevation = 20.dp, shape = shape, clip = false)
                .clip(shape)
                .background(Floe.colors.sectionCardSurface)
                .border(0.5.dp, Floe.colors.chromeHairline, shape),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(scrollState)
                    .padding(vertical = 4.dp),
            ) {
                items.forEach { item ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = FloeLayout.MinimumTarget)
                            .clickable(enabled = item.enabled, role = Role.Button, onClick = item.onClick)
                            .semantics { if (!item.enabled) disabled() }
                            .padding(horizontal = 12.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        FloeText(
                            item.label,
                            style = Floe.typography.body,
                            color = if (item.enabled) Floe.colors.label else Floe.colors.tertiaryLabel,
                            modifier = Modifier.weight(1f),
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
    }
}
