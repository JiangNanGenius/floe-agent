// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeCapsuleButton
import com.floe.android.design.FloeChoiceChip
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbarIconButton
import com.floe.android.design.FloeVerticalDivider
import com.floe.android.design.IconGlyph
import com.floe.android.host.PlatformLaunchOwnership
import com.floe.android.host.spacefiles.SpaceFileEntry
import com.floe.android.host.spacefiles.SpaceFilesFailure
import com.floe.android.host.spacefiles.SpaceFilesHost
import com.floe.android.host.spacefiles.SpaceFilesNames
import com.floe.android.host.spacefiles.SpaceFilesNotice
import com.floe.android.host.spacefiles.SpaceFilesOpenResult
import com.floe.android.host.spacefiles.SpaceFilesOperation
import com.floe.android.host.spacefiles.SpaceFilesPreview
import com.floe.android.host.spacefiles.SpaceFilesProblem
import com.floe.android.host.spacefiles.SpaceFilesUiState
import com.floe.android.host.spacefiles.SpaceRootAccess
import com.floe.android.host.spacefiles.SpaceRootBrowse
import com.floe.android.host.spacefiles.SpaceRootUi
import com.floe.android.safgateway.SafPickerIntents
import com.floe.android.safgateway.SafUriRef
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Space → Files: the standalone authorized-folder manager.
 *
 * Contract used by the Space integration: `SpaceFilesDestination(onClose)`.
 * The page owns the system tree picker, its exact-flag result, the saved-root
 * catalog, folder navigation, paged listing, preview/open, and the explicit
 * create/rename/delete/copy/move actions. Provider IO, grants and cancellation
 * live in `com.floe.android.host.spacefiles.SpaceFilesController`; this file is
 * presentation plus the two Android calls that only a composition can make:
 * the picker Intent and ACTION_VIEW.
 */
@Composable
internal fun SpaceFilesDestination(onClose: () -> Unit) {
    val context = LocalContext.current
    val controller = remember(context.applicationContext) {
        SpaceFilesHost.controller(context.applicationContext)
    }
    val state by controller.state.collectAsState()
    val lifecycleOwner = LocalLifecycleOwner.current

    LaunchedEffect(controller) { controller.start() }
    DisposableEffect(controller, lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            // A background revoke must not leave rows looking accessible.
            if (event == Lifecycle.Event.ON_RESUME) controller.revalidate()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            // Fences view-scoped work and gives the page cursor back; an
            // in-flight provider mutation stays owned and still settles.
            controller.viewDetached()
        }
    }

    // ---- system tree picker (exact returned flags survive) ---------------
    val launchLedger = remember(controller) {
        PlatformLaunchOwnership.LaneLedger(controller.launchNamespace)
    }
    var issuedKey by rememberSaveable(controller) { mutableStateOf<String?>(null) }
    val treePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        val accepted = result.resultCode == Activity.RESULT_OK
        val uriString = if (accepted) SafPickerIntents.resultUriString(result.data) else null
        val flags = if (accepted) SafPickerIntents.resultFlags(result.data) else 0
        when (val decision = launchLedger.onCallback(controller.state.value.pick?.incarnation)) {
            is PlatformLaunchOwnership.CallbackDecision.Dispatch ->
                controller.onPickerResult(decision.incarnation, uriString, flags)
            PlatformLaunchOwnership.CallbackDecision.Drop -> controller.dropPickerCallback()
        }
        issuedKey = null
    }
    val pendingPick = state.pick
    LaunchedEffect(controller, pendingPick?.incarnation, issuedKey) {
        // Restore the exact launch identity after composition recreation: a
        // still-showing picker must not be launched a second time.
        if (issuedKey != null) {
            launchLedger.restore(PlatformLaunchOwnership.LaunchKey.decode(issuedKey))
        }
        val pick = pendingPick ?: return@LaunchedEffect
        when (val decision = launchLedger.onPending(pick.incarnation)) {
            is PlatformLaunchOwnership.PendingDecision.Launch -> {
                issuedKey = decision.savedKey.encode()
                runCatching { treePicker.launch(SafPickerIntents.from(pick.spec)) }
                    .onFailure {
                        // No picker activity can host the Intent: settle the
                        // request honestly, never as a grant.
                        launchLedger.release()
                        issuedKey = null
                        controller.cancelPicker(pick.incarnation)
                    }
            }
            PlatformLaunchOwnership.PendingDecision.Hold -> Unit
        }
    }

    // ---- ACTION_VIEW with a real temporary read grant --------------------
    val openRequest = state.openRequest
    LaunchedEffect(openRequest) {
        val request = openRequest ?: return@LaunchedEffect
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(Uri.parse(request.uri.uriString), request.mimeType.ifBlank { "*/*" })
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        // Package-visibility filtering can make resolveActivity answer null for
        // a handler that startActivity would still reach, so the real call is
        // the only truthful probe. Only what was observed is reported.
        val result = try {
            context.startActivity(intent)
            SpaceFilesOpenResult.LAUNCHED
        } catch (_: ActivityNotFoundException) {
            SpaceFilesOpenResult.NO_HANDLER
        } catch (_: Exception) {
            SpaceFilesOpenResult.FAILED
        }
        controller.completeOpenRequest(request.id, result)
    }

    // ---- local presentation state ---------------------------------------
    var selectedEntry by remember { mutableStateOf<SpaceFileEntry?>(null) }
    var nameSheet by remember { mutableStateOf<NameSheetState?>(null) }
    var deleteTarget by remember { mutableStateOf<SpaceFileEntry?>(null) }
    var removeRootTarget by remember { mutableStateOf<SpaceRootUi?>(null) }
    var rootsSheet by remember { mutableStateOf(false) }
    var moveConfirm by remember { mutableStateOf(false) }

    ImeFirstBackHandler {
        when {
            state.preview != null -> controller.dismissPreview()
            state.browse?.canGoUp == true -> controller.goUp()
            else -> onClose()
        }
    }

    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .background(Floe.colors.readingSurface),
    ) {
        val wide = maxWidth >= 840.dp
        Column(Modifier.fillMaxSize().navigationBarsPadding()) {
            SpaceFilesHeader(
                state = state,
                wide = wide,
                onClose = onClose,
                onAddFolder = {
                    nameSheet = null
                    rootsSheet = false
                    controller.requestAddFolder()
                },
                onManageRoots = { rootsSheet = true },
            )
            FloeDivider()
            if (wide) {
                Row(Modifier.weight(1f).fillMaxWidth()) {
                    SpaceFilesRootsPane(
                        roots = state.roots,
                        activeRootUri = state.browse?.root?.uri?.uriString,
                        busy = state.busy != null || state.pick != null,
                        modifier = Modifier.width(300.dp).fillMaxHeight(),
                        onOpen = { root -> controller.openRoot(root.uri) },
                        onReselect = { controller.requestAddFolder() },
                        onRemove = { removeRootTarget = it },
                        onAddFolder = { controller.requestAddFolder() },
                    )
                    FloeVerticalDivider()
                    SpaceFilesBrowserPane(
                        state = state,
                        modifier = Modifier.weight(1f),
                        onUp = controller::goUp,
                        onRefresh = controller::refreshBrowse,
                        onLoadMore = controller::loadMore,
                        onNewFolder = {
                            nameSheet = NameSheetState(NameSheetKind.FOLDER, null, "")
                        },
                        onNewFile = {
                            nameSheet = NameSheetState(NameSheetKind.FILE, null, "")
                        },
                        onOpenEntry = { entry ->
                            if (entry.isDirectory) controller.enterFolder(entry)
                            else controller.preview(entry)
                        },
                        onMenu = { selectedEntry = it },
                        onAddFolder = { controller.requestAddFolder() },
                        onDismissNotice = controller::dismissNotice,
                    )
                }
            } else {
                Column(Modifier.weight(1f).fillMaxWidth()) {
                    SpaceFilesCompactRoots(
                        roots = state.roots,
                        activeRootUri = state.browse?.root?.uri?.uriString,
                        onOpen = { root -> controller.openRoot(root.uri) },
                        onReselect = { controller.requestAddFolder() },
                    )
                    FloeDivider()
                    SpaceFilesBrowserPane(
                        state = state,
                        modifier = Modifier.weight(1f),
                        onUp = controller::goUp,
                        onRefresh = controller::refreshBrowse,
                        onLoadMore = controller::loadMore,
                        onNewFolder = {
                            nameSheet = NameSheetState(NameSheetKind.FOLDER, null, "")
                        },
                        onNewFile = {
                            nameSheet = NameSheetState(NameSheetKind.FILE, null, "")
                        },
                        onOpenEntry = { entry ->
                            if (entry.isDirectory) controller.enterFolder(entry)
                            else controller.preview(entry)
                        },
                        onMenu = { selectedEntry = it },
                        onAddFolder = { controller.requestAddFolder() },
                        onDismissNotice = controller::dismissNotice,
                    )
                }
            }
        }
    }

    // ---- entry actions ---------------------------------------------------
    SpaceFilesEntrySheet(
        entry = selectedEntry,
        busy = state.busy != null,
        writable = state.browse?.root?.write == true,
        onDismiss = { selectedEntry = null },
        onPreview = { selectedEntry = null; controller.preview(it) },
        onOpenWith = { selectedEntry = null; controller.requestExternalOpen(it) },
        onRename = {
            selectedEntry = null
            nameSheet = NameSheetState(NameSheetKind.RENAME, it, it.name)
        },
        onCopy = { selectedEntry = null; controller.beginCopy(it) },
        onMove = { selectedEntry = null; controller.beginMove(it) },
        onDelete = { selectedEntry = null; deleteTarget = it },
    )

    SpaceFilesNameSheet(
        sheet = nameSheet,
        busy = state.busy != null,
        onDismiss = { nameSheet = null },
        onConfirm = { value ->
            val sheet = nameSheet
            nameSheet = null
            when (sheet?.kind) {
                NameSheetKind.FOLDER -> controller.createFolder(value)
                NameSheetKind.FILE -> controller.createFile(value)
                NameSheetKind.RENAME -> sheet?.entry?.let { controller.rename(it, value) }
                null -> Unit
            }
        },
    )

    deleteTarget?.let { target ->
        FloeConfirmDialog(
            title = stringResource(R.string.space_files_delete_title, target.name),
            message = stringResource(R.string.space_files_delete_message),
            confirmLabel = stringResource(R.string.space_files_delete),
            dismissLabel = stringResource(R.string.cancel),
            onConfirm = {
                deleteTarget = null
                controller.delete(target)
            },
            onDismiss = { deleteTarget = null },
        )
    }

    removeRootTarget?.let { target ->
        FloeConfirmDialog(
            title = stringResource(R.string.space_files_root_remove_title),
            message = stringResource(R.string.space_files_root_remove_message),
            confirmLabel = stringResource(R.string.space_files_root_remove),
            dismissLabel = stringResource(R.string.cancel),
            onConfirm = {
                removeRootTarget = null
                controller.removeRoot(target.uri)
            },
            onDismiss = { removeRootTarget = null },
        )
    }

    SpaceFilesTransferSheet(
        state = state,
        moveConfirm = moveConfirm,
        onMoveConfirmChange = { moveConfirm = it },
        onSelectRoot = controller::transferSelectRoot,
        onEnter = controller::transferEnter,
        onUp = controller::transferUp,
        onLoadMore = controller::transferLoadMore,
        onConfirm = {
            moveConfirm = false
            controller.transferConfirm()
        },
        onCancel = controller::transferCancel,
    )

    SpaceFilesPreviewSheet(
        preview = state.preview,
        loading = state.previewLoading,
        onDismiss = controller::dismissPreview,
        onOpenWith = { preview ->
            controller.dismissPreview()
            controller.openPreviewExternally(preview)
        },
    )

    if (rootsSheet) {
        FloeActionSheet(
            visible = true,
            onDismiss = { rootsSheet = false },
            maxCardWidth = 560.dp,
        ) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                FloeText(
                    stringResource(R.string.space_files_roots),
                    style = Floe.typography.toolbarTitle,
                )
                if (state.roots.isEmpty()) {
                    FloeText(
                        stringResource(R.string.space_files_no_roots_description),
                        style = Floe.typography.body,
                        color = Floe.colors.secondaryLabel,
                    )
                }
                state.roots.forEach { root ->
                    SpaceFilesRootCard(
                        root = root,
                        selected = root.uri == state.browse?.root?.uri,
                        busy = state.busy != null,
                        onOpen = {
                            rootsSheet = false
                            controller.openRoot(root.uri)
                        },
                        onReselect = {
                            rootsSheet = false
                            controller.requestAddFolder()
                        },
                        onRemove = { removeRootTarget = it },
                    )
                }
                FloeCapsuleButton(
                    label = stringResource(R.string.space_files_add_folder),
                    onClick = {
                        rootsSheet = false
                        controller.requestAddFolder()
                    },
                    prominent = true,
                    enabled = state.busy == null && state.pick == null,
                )
                FloeCapsuleButton(
                    label = stringResource(R.string.close),
                    onClick = { rootsSheet = false },
                )
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Header + root navigation
// ---------------------------------------------------------------------------

@Composable
private fun SpaceFilesHeader(
    state: SpaceFilesUiState,
    wide: Boolean,
    onClose: () -> Unit,
    onAddFolder: () -> Unit,
    onManageRoots: () -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = FloeLayout.MinimumTarget)
                .clickable(role = Role.Button, onClick = onClose),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconGlyph(FloeIcons.ChevronBack, Floe.colors.accent, 16.dp)
            Spacer(Modifier.width(6.dp))
            FloeText(
                stringResource(R.string.space_title),
                style = Floe.typography.bodyEmphasized,
                color = Floe.colors.accent,
            )
        }
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    IconGlyph(FloeIcons.Folder, Floe.colors.accent, 22.dp)
                    FloeText(stringResource(R.string.space_files_title), style = Floe.typography.title)
                }
                FloeText(
                    stringResource(R.string.space_files_subtitle),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            if (!wide && state.roots.isNotEmpty()) {
                TextAction(
                    label = stringResource(R.string.space_files_roots),
                    onClick = onManageRoots,
                )
            }
            FloeCircleButton(
                icon = FloeIcons.Plus,
                contentDescription = stringResource(R.string.space_files_add_folder),
                onClick = onAddFolder,
                enabled = state.busy == null && state.pick == null,
            )
        }
    }
}

@Composable
private fun SpaceFilesCompactRoots(
    roots: List<SpaceRootUi>,
    activeRootUri: String?,
    onOpen: (SpaceRootUi) -> Unit,
    onReselect: (SpaceRootUi) -> Unit,
) {
    if (roots.isEmpty()) return
    val active = roots.firstOrNull { it.uri.uriString == activeRootUri }
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            roots.forEach { root ->
                FloeChoiceChip(
                    label = rootLabel(root),
                    selected = root.uri.uriString == activeRootUri,
                    onClick = {
                        if (root.usable) onOpen(root) else onReselect(root)
                    },
                )
            }
        }
        if (active != null) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FloeText(
                    text = rootStatusText(active),
                    style = Floe.typography.metadata,
                    color = if (active.usable) Floe.colors.secondaryLabel else Floe.colors.destructive,
                    modifier = Modifier.weight(1f),
                )
                if (!active.usable) {
                    TextAction(
                        label = stringResource(R.string.space_files_root_reselect),
                        onClick = { onReselect(active) },
                    )
                }
            }
        }
    }
}

@Composable
private fun SpaceFilesRootsPane(
    roots: List<SpaceRootUi>,
    activeRootUri: String?,
    busy: Boolean,
    modifier: Modifier = Modifier,
    onOpen: (SpaceRootUi) -> Unit,
    onReselect: (SpaceRootUi) -> Unit,
    onRemove: (SpaceRootUi) -> Unit,
    onAddFolder: () -> Unit,
) {
    Column(
        modifier = modifier
            .verticalScroll(rememberScrollState())
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        FloeText(stringResource(R.string.space_files_roots), style = Floe.typography.section)
        if (roots.isEmpty()) {
            FloeText(
                stringResource(R.string.space_files_no_roots_description),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
        roots.forEach { root ->
            SpaceFilesRootCard(
                root = root,
                selected = root.uri.uriString == activeRootUri,
                busy = busy,
                onOpen = onOpen,
                onReselect = onReselect,
                onRemove = onRemove,
            )
        }
        FloeCapsuleButton(
            label = stringResource(R.string.space_files_add_folder),
            onClick = onAddFolder,
            enabled = !busy,
        )
    }
}

@Composable
private fun SpaceFilesRootCard(
    root: SpaceRootUi,
    selected: Boolean,
    busy: Boolean,
    onOpen: (SpaceRootUi) -> Unit,
    onReselect: (SpaceRootUi) -> Unit,
    onRemove: (SpaceRootUi) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(if (selected) Floe.colors.accentFillFaint else Floe.colors.fillTertiary)
            .clickable(enabled = root.usable && !busy, role = Role.Button) { onOpen(root) }
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            IconGlyph(
                FloeIcons.Folder,
                if (root.usable) Floe.colors.accent else Floe.colors.tertiaryLabel,
                18.dp,
            )
            FloeText(
                text = rootLabel(root),
                style = Floe.typography.bodyEmphasized,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            RootBadge(root)
        }
        FloeText(
            text = rootStatusText(root),
            style = Floe.typography.metadata,
            color = if (root.usable) Floe.colors.secondaryLabel else Floe.colors.destructive,
        )
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            if (root.usable) {
                TextAction(
                    label = stringResource(R.string.space_files_root_open),
                    onClick = { onOpen(root) },
                    enabled = !busy,
                )
            }
            TextAction(
                label = stringResource(R.string.space_files_root_reselect),
                onClick = { onReselect(root) },
                enabled = !busy,
            )
            TextAction(
                label = stringResource(R.string.space_files_root_remove),
                onClick = { onRemove(root) },
                enabled = !busy,
                destructive = true,
            )
        }
    }
}

@Composable
private fun RootBadge(root: SpaceRootUi) {
    when (root.access) {
        SpaceRootAccess.REVOKED -> FloeBadgePill(
            stringResource(R.string.space_files_root_badge_revoked),
            FloeBadgeTone.DESTRUCTIVE,
        )
        SpaceRootAccess.READ_ONLY -> FloeBadgePill(
            stringResource(R.string.space_files_root_badge_read_only),
            FloeBadgeTone.SECONDARY,
        )
        SpaceRootAccess.READ_WRITE -> FloeBadgePill(
            text = if (root.persisted) {
                stringResource(R.string.space_files_root_badge_permanent)
            } else {
                stringResource(R.string.space_files_root_badge_session)
            },
            tone = if (root.persisted) FloeBadgeTone.ACCENT else FloeBadgeTone.PENDING,
        )
    }
}

@Composable
private fun rootLabel(root: SpaceRootUi): String =
    root.name.ifBlank { stringResource(R.string.space_files_root_unnamed) }

@Composable
private fun rootStatusText(root: SpaceRootUi): String = when (root.access) {
    SpaceRootAccess.REVOKED -> stringResource(R.string.space_files_root_status_revoked)
    SpaceRootAccess.READ_ONLY -> stringResource(R.string.space_files_read_only_hint)
    SpaceRootAccess.READ_WRITE -> if (root.persisted) {
        stringResource(R.string.space_files_root_status_permanent)
    } else {
        stringResource(R.string.space_files_root_status_session)
    }
}

// ---------------------------------------------------------------------------
// Browser
// ---------------------------------------------------------------------------

@Composable
private fun SpaceFilesBrowserPane(
    state: SpaceFilesUiState,
    modifier: Modifier = Modifier,
    onUp: () -> Unit,
    onRefresh: () -> Unit,
    onLoadMore: () -> Unit,
    onNewFolder: () -> Unit,
    onNewFile: () -> Unit,
    onOpenEntry: (SpaceFileEntry) -> Unit,
    onMenu: (SpaceFileEntry) -> Unit,
    onAddFolder: () -> Unit,
    onDismissNotice: () -> Unit,
) {
    val browse = state.browse
    Column(modifier.fillMaxHeight()) {
        if (browse == null) {
            if (!state.catalogLoaded) {
                LoadingLine(stringResource(R.string.space_files_loading))
            } else if (state.roots.isEmpty()) {
                SpaceFilesEmptyRoots(onAddFolder)
            } else {
                SpaceFilesCenteredHint(stringResource(R.string.space_files_open_root_hint))
            }
            return@Column
        }
        SpaceFilesBrowserToolbar(
            browse = browse,
            busy = state.busy != null,
            onUp = onUp,
            onRefresh = onRefresh,
        )
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            FloeCapsuleButton(
                label = stringResource(R.string.space_files_new_folder),
                onClick = onNewFolder,
                modifier = Modifier.weight(1f),
                enabled = browse.canCreateHere && state.busy == null,
            )
            FloeCapsuleButton(
                label = stringResource(R.string.space_files_new_file),
                onClick = onNewFile,
                modifier = Modifier.weight(1f),
                enabled = browse.canCreateHere && state.busy == null,
            )
        }
        if (!browse.canCreateHere && browse.error?.blocking != true && !browse.loading) {
            FloeText(
                text = if (browse.root.access == SpaceRootAccess.READ_ONLY) {
                    stringResource(R.string.space_files_error_read_only)
                } else {
                    stringResource(R.string.space_files_create_unavailable)
                },
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
            )
        }
        state.busy?.let { operation ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FloeActivityIndicator()
                FloeText(
                    text = busyText(operation),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
        state.notice?.let { notice ->
            SpaceFilesNoticeLine(notice = notice, onDismiss = onDismissNotice)
        }
        browse.error?.let { failure ->
            SpaceFilesErrorLine(
                failure = failure,
                onRetry = onRefresh,
                onReselect = onAddFolder,
            )
        }
        if (browse.loading && browse.entries.isEmpty()) {
            LoadingLine(stringResource(R.string.space_files_loading))
        } else if (browse.initialised && browse.entries.isEmpty() && browse.error == null) {
            SpaceFilesCenteredHint(stringResource(R.string.space_files_empty))
        } else {
            LazyColumn(Modifier.weight(1f).fillMaxWidth()) {
                items(items = browse.entries, key = { it.ref.uri.uriString }) { entry ->
                    SpaceFileRow(
                        entry = entry,
                        enabled = state.busy == null,
                        onOpen = { onOpenEntry(entry) },
                        onMenu = { onMenu(entry) },
                    )
                    FloeDivider(Modifier.padding(start = 46.dp))
                }
                if (browse.hasMore) {
                    item(key = "load-more") {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 12.dp, vertical = 8.dp),
                            horizontalArrangement = Arrangement.Center,
                        ) {
                            FloeCapsuleButton(
                                label = stringResource(R.string.space_files_load_more),
                                onClick = onLoadMore,
                                enabled = !browse.loadingMore,
                                modifier = Modifier.widthIn(max = 280.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SpaceFilesBrowserToolbar(
    browse: SpaceRootBrowse,
    busy: Boolean,
    onUp: () -> Unit,
    onRefresh: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (browse.canGoUp) {
            FloeToolbarIconButton(
                icon = FloeIcons.ChevronBack,
                contentDescription = stringResource(R.string.space_files_up),
                onClick = onUp,
                enabled = !busy,
            )
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            FloeText(
                text = browse.path.joinToString(" › ") { it.name.ifBlank { "…" } },
                style = Floe.typography.bodyEmphasized,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            FloeText(
                text = rootStatusText(browse.root),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        FloeToolbarIconButton(
            icon = FloeIcons.Refresh,
            contentDescription = stringResource(R.string.space_files_refresh),
            onClick = onRefresh,
            enabled = !busy && !browse.loading,
        )
    }
}

@Composable
private fun SpaceFileRow(
    entry: SpaceFileEntry,
    enabled: Boolean,
    onOpen: () -> Unit,
    onMenu: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .clickable(enabled = enabled, role = Role.Button, onClick = onOpen)
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconGlyph(entryIcon(entry), Floe.colors.accent, 20.dp)
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            FloeText(
                text = entry.name,
                style = Floe.typography.body,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            FloeText(
                text = entryMeta(entry),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        FloeToolbarIconButton(
            icon = FloeIcons.Ellipsis,
            contentDescription = stringResource(R.string.space_files_actions, entry.name),
            onClick = onMenu,
            enabled = enabled,
        )
    }
}

private fun entryIcon(entry: SpaceFileEntry) = when {
    entry.isDirectory -> FloeIcons.Folder
    SpaceFilesNames.allowsImagePreview(entry.mimeType, entry.name) -> FloeIcons.Photo
    else -> FloeIcons.Document
}

@Composable
private fun entryMeta(entry: SpaceFileEntry): String {
    if (entry.isDirectory) return stringResource(R.string.space_files_folder)
    val size = entry.sizeBytes?.let { SpaceFilesNames.formatBytes(it) }
        ?: stringResource(R.string.space_files_size_unknown)
    return if (entry.mimeType.isBlank()) {
        size
    } else {
        stringResource(R.string.space_files_row_meta, entry.mimeType, size)
    }
}

// ---------------------------------------------------------------------------
// Notices, errors, empty states
// ---------------------------------------------------------------------------

@Composable
private fun SpaceFilesNoticeLine(notice: SpaceFilesNotice, onDismiss: () -> Unit) {
    var showDetails by remember(notice) { mutableStateOf(false) }
    val message = noticeText(notice) ?: return
    val detail = when (notice) {
        is SpaceFilesNotice.Failed -> notice.failure.detail
        is SpaceFilesNotice.Completed -> notice.detail
        else -> null
    }
    val failed = notice is SpaceFilesNotice.Failed
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 4.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(Floe.colors.fillTertiary)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        FloeText(
            text = message,
            style = Floe.typography.body,
            color = if (failed) Floe.colors.destructive else Floe.colors.label,
        )
        if (detail != null) {
            TextAction(
                label = stringResource(R.string.space_files_error_details),
                onClick = { showDetails = !showDetails },
            )
            if (showDetails) {
                FloeText(
                    text = detail,
                    style = Floe.typography.evidence,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
        TextAction(
            label = stringResource(R.string.space_files_notice_dismiss),
            onClick = onDismiss,
        )
    }
}

@Composable
private fun noticeText(notice: SpaceFilesNotice): String? = when (notice) {
    is SpaceFilesNotice.RootAdded -> if (notice.sessionOnly) {
        stringResource(R.string.space_files_notice_added_session)
    } else {
        stringResource(R.string.space_files_notice_added)
    }
    is SpaceFilesNotice.RootRemoved -> stringResource(R.string.space_files_notice_removed)
    is SpaceFilesNotice.PickCancelled -> stringResource(R.string.space_files_notice_pick_cancelled)
    is SpaceFilesNotice.PickRejected -> stringResource(R.string.space_files_notice_pick_rejected)
    is SpaceFilesNotice.PageReloaded -> stringResource(R.string.space_files_notice_page_reloaded)
    is SpaceFilesNotice.Failed -> problemText(notice.failure.problem)
    is SpaceFilesNotice.Completed -> when (notice.operation) {
        SpaceFilesOperation.CREATE_FOLDER ->
            stringResource(R.string.space_files_notice_created_folder, notice.name)
        SpaceFilesOperation.CREATE_FILE ->
            stringResource(R.string.space_files_notice_created_file, notice.name)
        SpaceFilesOperation.RENAME -> if (notice.detail != null) {
            stringResource(R.string.space_files_notice_renamed_pending)
        } else {
            stringResource(R.string.space_files_notice_renamed, notice.name)
        }
        SpaceFilesOperation.DELETE ->
            stringResource(R.string.space_files_notice_deleted, notice.name)
        SpaceFilesOperation.COPY ->
            stringResource(R.string.space_files_notice_copied, notice.name)
        SpaceFilesOperation.MOVE -> if (notice.sourceRetained) {
            stringResource(R.string.space_files_notice_moved_source_kept, notice.name)
        } else {
            stringResource(R.string.space_files_notice_moved, notice.name)
        }
        else -> null
    }
}

@Composable
private fun SpaceFilesErrorLine(
    failure: SpaceFilesFailure,
    onRetry: () -> Unit,
    onReselect: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 4.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(Floe.colors.fillTertiary)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        FloeText(
            text = stringResource(R.string.space_files_error_title),
            style = Floe.typography.bodyEmphasized,
            color = Floe.colors.destructive,
        )
        FloeText(
            text = problemText(failure.problem),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (failure.retryable) {
                FloeCapsuleButton(
                    label = stringResource(R.string.retry),
                    onClick = onRetry,
                    modifier = Modifier.weight(1f),
                )
            }
            if (failure.blocking) {
                FloeCapsuleButton(
                    label = stringResource(R.string.space_files_root_reselect),
                    onClick = onReselect,
                    modifier = Modifier.weight(1f),
                    prominent = true,
                )
            }
        }
    }
}

@Composable
private fun SpaceFilesEmptyRoots(onAddFolder: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Box(
            modifier = Modifier
                .size(64.dp)
                .clip(CircleShape)
                .background(Floe.colors.fillTertiary),
            contentAlignment = Alignment.Center,
        ) {
            IconGlyph(FloeIcons.Folder, Floe.colors.secondaryLabel, 28.dp)
        }
        Spacer(Modifier.height(14.dp))
        FloeText(stringResource(R.string.space_files_no_roots_title), style = Floe.typography.section)
        Spacer(Modifier.height(6.dp))
        FloeText(
            stringResource(R.string.space_files_no_roots_description),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        Spacer(Modifier.height(14.dp))
        FloeCapsuleButton(
            label = stringResource(R.string.space_files_add_folder),
            onClick = onAddFolder,
            prominent = true,
            modifier = Modifier.widthIn(max = 280.dp),
        )
        Spacer(Modifier.height(6.dp))
        FloeText(
            stringResource(R.string.space_files_add_folder_caption),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
    }
}

@Composable
private fun SpaceFilesCenteredHint(text: String) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        FloeText(text, style = Floe.typography.body, color = Floe.colors.secondaryLabel)
    }
}

@Composable
private fun LoadingLine(text: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        FloeActivityIndicator()
        FloeText(text, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
    }
}

@Composable
private fun TextAction(
    label: String,
    onClick: () -> Unit,
    enabled: Boolean = true,
    destructive: Boolean = false,
) {
    Box(
        modifier = Modifier
            .heightIn(min = FloeLayout.MinimumTarget)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        FloeText(
            text = label,
            style = Floe.typography.bodyEmphasized,
            color = when {
                !enabled -> Floe.colors.tertiaryLabel
                destructive -> Floe.colors.destructive
                else -> Floe.colors.accent
            },
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

// ---------------------------------------------------------------------------
// Entry actions, forms and transfer
// ---------------------------------------------------------------------------

private enum class NameSheetKind { FOLDER, FILE, RENAME }

private data class NameSheetState(
    val kind: NameSheetKind,
    val entry: SpaceFileEntry?,
    val initial: String,
)

@Composable
private fun SpaceFilesEntrySheet(
    entry: SpaceFileEntry?,
    busy: Boolean,
    writable: Boolean,
    onDismiss: () -> Unit,
    onPreview: (SpaceFileEntry) -> Unit,
    onOpenWith: (SpaceFileEntry) -> Unit,
    onRename: (SpaceFileEntry) -> Unit,
    onCopy: (SpaceFileEntry) -> Unit,
    onMove: (SpaceFileEntry) -> Unit,
    onDelete: (SpaceFileEntry) -> Unit,
) {
    FloeActionSheet(
        visible = entry != null,
        onDismiss = onDismiss,
        maxCardWidth = 560.dp,
    ) {
        if (entry != null) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                FloeText(
                    text = entry.name,
                    style = Floe.typography.toolbarTitle,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                FloeText(
                    text = entryMeta(entry),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                if (entry.isVirtual) {
                    FloeText(
                        text = stringResource(R.string.space_files_virtual_hint),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
                if (!entry.isDirectory) {
                    FloeCapsuleButton(
                        label = stringResource(R.string.space_files_preview),
                        onClick = { onPreview(entry) },
                        enabled = !busy && !entry.isVirtual,
                    )
                    FloeCapsuleButton(
                        label = stringResource(R.string.space_files_open_with),
                        onClick = { onOpenWith(entry) },
                        enabled = !busy && !entry.isVirtual,
                    )
                }
                FloeCapsuleButton(
                    label = stringResource(R.string.space_files_rename),
                    onClick = { onRename(entry) },
                    enabled = !busy && writable && entry.canRename,
                )
                FloeCapsuleButton(
                    label = stringResource(R.string.space_files_copy_to),
                    onClick = { onCopy(entry) },
                    enabled = !busy && !entry.isDirectory && entry.canCopy,
                )
                FloeCapsuleButton(
                    label = stringResource(R.string.space_files_move_to),
                    onClick = { onMove(entry) },
                    enabled = !busy && writable && entry.canWrite,
                )
                FloeCapsuleButton(
                    label = stringResource(R.string.space_files_delete),
                    onClick = { onDelete(entry) },
                    enabled = !busy && writable && entry.canDelete,
                )
                if (entry.isDirectory) {
                    FloeText(
                        text = stringResource(R.string.space_files_folder_copy_hint),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                } else if (!writable) {
                    FloeText(
                        text = stringResource(R.string.space_files_error_read_only),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                } else if (!entry.isDirectory && (!entry.canCopy || !entry.canRename || !entry.canDelete)) {
                    FloeText(
                        text = stringResource(R.string.space_files_capability_hint),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
                FloeCapsuleButton(
                    label = stringResource(R.string.cancel),
                    onClick = onDismiss,
                )
            }
        }
    }
}

@Composable
private fun SpaceFilesNameSheet(
    sheet: NameSheetState?,
    busy: Boolean,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    FloeActionSheet(
        visible = sheet != null,
        onDismiss = { if (!busy) onDismiss() },
        maxCardWidth = 520.dp,
    ) {
        if (sheet != null) {
            var name by remember(sheet) { mutableStateOf(sheet.initial) }
            val valid = SpaceFilesNames.isSafeSegment(name.trim())
            Column(
                Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                FloeText(
                    text = nameSheetTitle(sheet),
                    style = Floe.typography.toolbarTitle,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                if (sheet.kind == NameSheetKind.FILE) {
                    FloeText(
                        text = stringResource(R.string.space_files_new_file_hint),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
                FloePlainFormField(
                    label = stringResource(R.string.space_files_name_label),
                    value = name,
                    onValueChange = { name = it },
                    enabled = !busy,
                    singleLine = true,
                )
                FloeText(
                    text = stringResource(R.string.space_files_name_hint),
                    style = Floe.typography.metadata,
                    color = if (name.isBlank() || valid) {
                        Floe.colors.secondaryLabel
                    } else {
                        Floe.colors.destructive
                    },
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FloeCapsuleButton(
                        label = if (sheet.kind == NameSheetKind.RENAME) {
                            stringResource(R.string.space_files_rename)
                        } else {
                            stringResource(R.string.space_files_create)
                        },
                        onClick = { onConfirm(name) },
                        modifier = Modifier.weight(1f),
                        enabled = valid && !busy,
                        prominent = true,
                    )
                    FloeCapsuleButton(
                        label = stringResource(R.string.cancel),
                        onClick = onDismiss,
                        modifier = Modifier.weight(1f),
                        enabled = !busy,
                    )
                }
            }
        }
    }
}

@Composable
private fun nameSheetTitle(sheet: NameSheetState): String = when (sheet.kind) {
    NameSheetKind.FOLDER -> stringResource(R.string.space_files_new_folder_title)
    NameSheetKind.FILE -> stringResource(R.string.space_files_new_file_title)
    NameSheetKind.RENAME -> stringResource(
        R.string.space_files_rename_title,
        sheet.entry?.name ?: stringResource(R.string.space_files_root_unnamed),
    )
}

@Composable
private fun SpaceFilesTransferSheet(
    state: SpaceFilesUiState,
    moveConfirm: Boolean,
    onMoveConfirmChange: (Boolean) -> Unit,
    onSelectRoot: (SafUriRef) -> Unit,
    onEnter: (SpaceFileEntry) -> Unit,
    onUp: () -> Unit,
    onLoadMore: () -> Unit,
    onConfirm: () -> Unit,
    onCancel: () -> Unit,
) {
    val transfer = state.transfer
    FloeActionSheet(
        visible = transfer != null,
        onDismiss = { if (state.busy == null) onCancel() },
        maxCardWidth = 640.dp,
    ) {
        if (transfer != null) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                FloeText(
                    text = if (transfer.operation == SpaceFilesOperation.COPY) {
                        stringResource(R.string.space_files_transfer_copy_title, transfer.source.name)
                    } else {
                        stringResource(R.string.space_files_transfer_move_title, transfer.source.name)
                    },
                    style = Floe.typography.toolbarTitle,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                FloeText(
                    text = stringResource(R.string.space_files_transfer_destination),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                if (state.roots.size > 1) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        state.roots.forEach { root ->
                            FloeChoiceChip(
                                label = rootLabel(root),
                                selected = root.uri == transfer.tree,
                                enabled = root.usable && state.busy == null,
                                onClick = { onSelectRoot(root.uri) },
                            )
                        }
                    }
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    if (transfer.canGoUp) {
                        FloeToolbarIconButton(
                            icon = FloeIcons.ChevronBack,
                            contentDescription = stringResource(R.string.space_files_up),
                            onClick = onUp,
                            enabled = state.busy == null && !transfer.loading,
                        )
                    }
                    FloeText(
                        text = transfer.path.joinToString(" › ") { it.name.ifBlank { "…" } },
                        style = Floe.typography.bodyEmphasized,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                }
                transfer.error?.let { failure ->
                    FloeText(
                        text = problemText(failure.problem),
                        style = Floe.typography.metadata,
                        color = Floe.colors.destructive,
                    )
                }
                if (transfer.loading) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        FloeActivityIndicator()
                        FloeText(
                            text = stringResource(R.string.space_files_loading),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                }
                Column(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(max = 260.dp)
                        .verticalScroll(rememberScrollState()),
                ) {
                    transfer.directories.forEach { directory ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(min = 48.dp)
                                .clickable(
                                    enabled = state.busy == null && !transfer.loading,
                                    role = Role.Button,
                                ) { onEnter(directory) }
                                .padding(horizontal = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            IconGlyph(FloeIcons.Folder, Floe.colors.accent, 18.dp)
                            Spacer(Modifier.width(8.dp))
                            FloeText(
                                text = directory.name,
                                style = Floe.typography.body,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f),
                            )
                            IconGlyph(FloeIcons.ChevronForward, Floe.colors.tertiaryLabel, 14.dp)
                        }
                    }
                    if (!transfer.loading && transfer.directories.isEmpty() && transfer.error == null) {
                        FloeText(
                            text = stringResource(R.string.space_files_transfer_empty),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                            modifier = Modifier.padding(vertical = 8.dp),
                        )
                    }
                    if (transfer.hasMore) {
                        TextAction(
                            label = stringResource(R.string.space_files_load_more),
                            onClick = onLoadMore,
                            enabled = !transfer.loading,
                        )
                    }
                }
                FloeText(
                    text = if (transfer.operation == SpaceFilesOperation.COPY) {
                        stringResource(R.string.space_files_transfer_hint_copy)
                    } else {
                        stringResource(R.string.space_files_transfer_hint_move)
                    },
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                val destinationFolderId = transfer.folder?.documentId
                val sameFolderMove = transfer.operation == SpaceFilesOperation.MOVE &&
                    transfer.tree == transfer.source.ref.tree &&
                    destinationFolderId != null &&
                    destinationFolderId == transfer.source.ref.parentDocumentId
                if (sameFolderMove) {
                    FloeText(
                        text = stringResource(R.string.space_files_error_invalid_destination),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
                val canPlace = !transfer.loading && transfer.error == null &&
                    state.busy == null && !sameFolderMove
                if (transfer.operation == SpaceFilesOperation.COPY) {
                    FloeCapsuleButton(
                        label = stringResource(R.string.space_files_transfer_copy_here),
                        onClick = onConfirm,
                        prominent = true,
                        enabled = canPlace,
                    )
                } else {
                    FloeCapsuleButton(
                        label = stringResource(R.string.space_files_transfer_move_here),
                        onClick = { onMoveConfirmChange(true) },
                        prominent = true,
                        enabled = canPlace,
                    )
                }
                FloeCapsuleButton(
                    label = stringResource(R.string.cancel),
                    onClick = onCancel,
                    enabled = state.busy == null,
                )
            }
        }
    }
    if (moveConfirm && transfer != null) {
        FloeConfirmDialog(
            title = stringResource(R.string.space_files_move_confirm_title, transfer.source.name),
            message = stringResource(R.string.space_files_move_confirm_message),
            confirmLabel = stringResource(R.string.space_files_move_confirm),
            dismissLabel = stringResource(R.string.cancel),
            onConfirm = {
                onMoveConfirmChange(false)
                onConfirm()
            },
            onDismiss = { onMoveConfirmChange(false) },
        )
    }
}

// ---------------------------------------------------------------------------
// Preview
// ---------------------------------------------------------------------------

private sealed interface PreviewBitmapState {
    data object Loading : PreviewBitmapState
    data class Ready(val image: ImageBitmap) : PreviewBitmapState
    data object Failed : PreviewBitmapState
}

@Composable
private fun SpaceFilesPreviewSheet(
    preview: SpaceFilesPreview?,
    loading: Boolean,
    onDismiss: () -> Unit,
    onOpenWith: (SpaceFilesPreview) -> Unit,
) {
    FloeActionSheet(
        visible = preview != null || loading,
        onDismiss = onDismiss,
        maxCardWidth = 720.dp,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            when {
                loading -> {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        FloeActivityIndicator()
                        FloeText(
                            text = stringResource(R.string.space_files_busy_preview),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                }
                preview != null -> {
                    FloeText(
                        text = preview.name,
                        style = Floe.typography.toolbarTitle,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    FloeText(
                        text = previewMeta(preview),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                    when (preview) {
                        is SpaceFilesPreview.Text -> {
                            if (preview.text.isEmpty()) {
                                FloeText(
                                    text = stringResource(R.string.space_files_preview_empty),
                                    style = Floe.typography.body,
                                    color = Floe.colors.secondaryLabel,
                                )
                            } else {
                                Box(
                                    Modifier
                                        .fillMaxWidth()
                                        .heightIn(max = 420.dp)
                                        .verticalScroll(rememberScrollState()),
                                ) {
                                    SelectionContainer {
                                        FloeText(
                                            text = preview.text,
                                            style = Floe.typography.metadata.copy(
                                                fontFamily = FontFamily.Monospace,
                                            ),
                                            color = Floe.colors.label,
                                        )
                                    }
                                }
                            }
                        }
                        is SpaceFilesPreview.Image -> {
                            val imageState by produceState<PreviewBitmapState>(
                                initialValue = PreviewBitmapState.Loading,
                                key1 = preview.file,
                            ) {
                                value = withContext(Dispatchers.IO) {
                                    decodeBoundedImage(preview.file)
                                        ?.let { PreviewBitmapState.Ready(it) }
                                        ?: PreviewBitmapState.Failed
                                }
                            }
                            when (val current = imageState) {
                                PreviewBitmapState.Loading -> Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                ) {
                                    FloeActivityIndicator()
                                    FloeText(
                                        text = stringResource(R.string.space_files_loading),
                                        style = Floe.typography.metadata,
                                        color = Floe.colors.secondaryLabel,
                                    )
                                }
                                PreviewBitmapState.Failed -> FloeText(
                                    text = stringResource(R.string.space_files_preview_unavailable),
                                    style = Floe.typography.body,
                                    color = Floe.colors.secondaryLabel,
                                )
                                is PreviewBitmapState.Ready -> Image(
                                    bitmap = current.image,
                                    contentDescription = preview.name,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .heightIn(max = 420.dp),
                                    contentScale = ContentScale.Fit,
                                )
                            }
                        }
                        is SpaceFilesPreview.Unavailable -> {
                            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                FloeText(
                                    text = stringResource(R.string.space_files_preview_unavailable),
                                    style = Floe.typography.bodyEmphasized,
                                )
                                FloeText(
                                    text = problemText(preview.failure.problem),
                                    style = Floe.typography.metadata,
                                    color = Floe.colors.secondaryLabel,
                                )
                            }
                        }
                    }
                    if (preview.isVirtual) {
                        FloeText(
                            text = stringResource(R.string.space_files_virtual_hint),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FloeCapsuleButton(
                            label = stringResource(R.string.space_files_open_with),
                            onClick = { onOpenWith(preview) },
                            modifier = Modifier.weight(1f),
                            enabled = !preview.isVirtual,
                        )
                        FloeCapsuleButton(
                            label = stringResource(R.string.close),
                            onClick = onDismiss,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
                else -> {
                    FloeCapsuleButton(
                        label = stringResource(R.string.close),
                        onClick = onDismiss,
                    )
                }
            }
        }
    }
}

@Composable
private fun previewMeta(preview: SpaceFilesPreview): String {
    val size = preview.bytes?.let { SpaceFilesNames.formatBytes(it) }
        ?: stringResource(R.string.space_files_size_unknown)
    return if (preview.mimeType.isBlank()) {
        size
    } else {
        stringResource(R.string.space_files_row_meta, preview.mimeType, size)
    }
}

/** Bounded decode: never load an arbitrarily large bitmap into the UI. */
private fun decodeBoundedImage(file: File, maxEdge: Int = 1600): ImageBitmap? = runCatching {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.path, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return@runCatching null
    var sample = 1
    while (bounds.outWidth / sample > maxEdge || bounds.outHeight / sample > maxEdge) {
        sample *= 2
    }
    val options = BitmapFactory.Options().apply { inSampleSize = sample }
    BitmapFactory.decodeFile(file.path, options)?.asImageBitmap()
}.getOrNull()

// ---------------------------------------------------------------------------
// Closed copy for provider problems / progress
// ---------------------------------------------------------------------------

@Composable
private fun problemText(problem: SpaceFilesProblem): String = stringResource(
    when (problem) {
        SpaceFilesProblem.GRANT_REVOKED -> R.string.space_files_error_revoked
        SpaceFilesProblem.GRANT_MISSING -> R.string.space_files_error_grant_missing
        SpaceFilesProblem.RE_PICK_REQUIRED -> R.string.space_files_error_re_pick
        SpaceFilesProblem.READ_ONLY -> R.string.space_files_error_read_only
        SpaceFilesProblem.UNSUPPORTED -> R.string.space_files_error_unsupported
        SpaceFilesProblem.NOT_FOUND -> R.string.space_files_error_not_found
        SpaceFilesProblem.PROVIDER_OFFLINE -> R.string.space_files_error_provider_offline
        SpaceFilesProblem.CONFLICT -> R.string.space_files_error_conflict
        SpaceFilesProblem.SIZE_LIMIT -> R.string.space_files_error_size_limit
        SpaceFilesProblem.AMBIGUOUS -> R.string.space_files_error_ambiguous
        SpaceFilesProblem.CANCELLED -> R.string.space_files_error_cancelled
        SpaceFilesProblem.INVALID_NAME -> R.string.space_files_error_invalid_name
        SpaceFilesProblem.INVALID_DESTINATION -> R.string.space_files_error_invalid_destination
        SpaceFilesProblem.NO_HANDLER -> R.string.space_files_error_no_handler
        SpaceFilesProblem.BINARY -> R.string.space_files_error_binary
        SpaceFilesProblem.IO -> R.string.space_files_error_io
        SpaceFilesProblem.FAILED -> R.string.space_files_error_failed
    },
)

@Composable
private fun busyText(operation: SpaceFilesOperation): String = stringResource(
    when (operation) {
        SpaceFilesOperation.CREATE_FOLDER, SpaceFilesOperation.CREATE_FILE ->
            R.string.space_files_busy_create
        SpaceFilesOperation.RENAME -> R.string.space_files_busy_rename
        SpaceFilesOperation.DELETE -> R.string.space_files_busy_delete
        SpaceFilesOperation.COPY -> R.string.space_files_busy_copy
        SpaceFilesOperation.MOVE -> R.string.space_files_busy_move
        SpaceFilesOperation.PREVIEW -> R.string.space_files_busy_preview
        else -> R.string.space_files_loading
    },
)
