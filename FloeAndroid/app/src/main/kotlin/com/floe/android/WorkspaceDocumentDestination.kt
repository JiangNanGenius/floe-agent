// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.app.Activity
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.floe.android.design.Floe
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeStatusLine
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbarIconButton
import com.floe.android.design.IconGlyph
import com.floe.android.designintegration.DesignExportPickerEffect
import com.floe.android.designintegration.DesignTargetResolver
import com.floe.android.feature.canvas.ui.design.DesignSessionRequest
import com.floe.android.feature.canvas.ui.design.DesignTargetDescriptor
import com.floe.android.feature.canvas.ui.design.DesignWorkflowController
import com.floe.android.feature.canvas.ui.design.DesignWorkflowSheet
import com.floe.android.feature.ide.FloeIdeDocumentWindow
import com.floe.android.feature.ide.IdeBottomAccessory
import com.floe.android.feature.ide.IdePresenter
import com.floe.android.feature.ide.IdeWorkspacePresentation
import com.floe.android.feature.workbench.ui.R as WorkbenchR
import com.floe.android.host.Owner
import com.floe.android.host.RuntimeHost
import com.floe.android.host.cad.C04CadFormat
import com.floe.android.host.cad.C04CadViewerDestination
import com.floe.android.host.WorkspaceDocumentPreviewPolicy
import java.util.Locale

/**
 * Typed presentation surface for a workspace document (G07.1).
 *
 * The iOS source is the authority for this split: `WorkspaceFileRouter`
 * (`FloeAgent/FloeApp/Workspace/WorkspaceFileRouter.swift`) sends text/code to
 * the code workbench, Office to the native engine, PDF to the document viewer,
 * CAD/image/media/archive to their own surfaces, and binaries to Quick Look.
 * `FileInspectorView.swift` L97-110 presents the code workbench (and the PDF
 * viewer tab it hosts) as a `fullScreenCover` over the stable split, while the
 * iPad inspector keeps the pane-sized preview; `WorkspaceIDEView.swift`
 * L172-180 exposes the explicit close and, on compact widths, keeps the tree
 * behind a drawer instead of a permanent column.
 *
 * Android uses the existing typed preview services with this mapping:
 * - text/code: the same [IdePresenter] editor that owns drafts/undo/save is
 *   presented full-window on a phone, and stays in the tablet inspector with
 *   an explicit "open full window" entry;
 * - Office: the already owned standalone Office viewer Activity (a real
 *   full-screen surface) is reused; the text workbench never receives it;
 * - PDF/raster bitmap: the real READ-ONLY full-window preview over the
 *   existing verified workspace snapshot + isolated PDF renderer / bounded
 *   BitmapFactory decoder (G07.1);
 * - media and supported CAD: their owned media preview and read-only C04
 *   viewer; unsupported formats keep an explicit typed fallback;
 * - archive: the real bounded archive browser (list/inspect/extract) over
 *   the ORIGINAL safe engine and G04 workspace lease;
 * - binary and unsupported image encodings: a typed fallback rather
 *   than decoding arbitrary bytes as text.
 *
 * Nothing here is a second document authority: the request only carries the
 * already-owned task/workspace/path identity, and every byte and every draft
 * still belongs to the native workspace service through the IDE presenter.
 */

/** Presentation class of one workspace file. Mirrors the iOS/Android shared policy. */
internal enum class WorkspaceDocumentSurface {
    CODE_EDITOR,
    OFFICE,
    PDF,
    IMAGE,
    MEDIA,
    CAD,
    ARCHIVE,
    QUICK_LOOK,
    ;

    /** Only the code workbench may read or write document bytes as UTF-8. */
    internal val opensInCodeEditor: Boolean get() = this == CODE_EDITOR
}

/**
 * Extension routing mirrored byte-for-byte from the shared Swift classifier
 * (`FloeAndroid/shared/Sources/FloeWorkspace/WorkspaceTextPolicy.swift`) and
 * the iOS `WorkspaceFileRouter`. The native bridge stays authoritative: even a
 * mis-routed path is refused there before any read/write. This object only
 * chooses which presentation surface the App opens, so a code page can never
 * be handed an Office/PDF/image path.
 */
internal object WorkspaceDocumentRouter {
    private val codeExtensions = setOf(
        "json", "jsonc", "swift", "py", "js", "mjs", "cjs", "jsx",
        "ts", "tsx", "c", "h", "m", "mm", "cc", "cpp", "cxx",
        "hpp", "html", "htm", "css", "scss", "xml", "yaml", "yml",
        "toml", "sh", "bash", "zsh", "fish", "rs", "go", "java",
        "kt", "kts", "sql", "rb", "php", "pl", "lua", "dart",
        "vue", "svelte", "gradle", "properties", "ini", "conf",
    )
    private val textExtensions = setOf(
        "txt", "md", "markdown", "json", "jsonc", "swift", "py",
        "js", "mjs", "cjs", "jsx", "ts", "tsx", "c", "h", "m",
        "mm", "cc", "cpp", "cxx", "hpp", "html", "htm", "css",
        "scss", "xml", "yaml", "yml", "toml", "sh", "bash", "zsh",
        "fish", "log", "csv", "rs", "go", "java", "kt", "kts",
        "sql", "rb", "php", "pl", "lua", "dart", "vue", "svelte",
        "gradle", "properties", "ini", "conf", "env", "gitignore",
        "dockerfile", "makefile", "patch", "diff",
    )
    private val officeExtensions = setOf(
        "docx", "docm", "xlsx", "xlsm", "pptx", "pptm", "doc", "xls",
        "ppt", "odt", "ods", "odp", "rtf",
    )
    private val cadExtensions = setOf(
        "dxf", "dwg", "step", "stp", "iges", "igs", "brep",
        "stl", "obj", "glb", "gltf", "3mf", "floecad",
    )
    private val imageExtensions = setOf(
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif",
        "bmp", "svg", "pdf",
    )
    private val mediaExtensions = setOf(
        "mov", "mp4", "m4v", "avi", "mkv", "webm", "mp3", "m4a", "wav", "aac", "flac",
    )
    private val archiveExtensions = setOf(
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "jar", "war", "ipa",
        "deb", "dmg", "iso",
    )
    private val binaryExtensions = setOf(
        "bin", "dat", "exe", "dll", "dylib", "so", "a", "o", "class", "pyc",
        "wasm", "sqlite", "db", "p12", "pfx", "cer", "der", "mobileprovision",
        "keystore", "ttf", "otf", "woff", "woff2",
    )

    /** The presentation surface for [relativePath]. Never guesses from content. */
    internal fun surfaceFor(relativePath: String): WorkspaceDocumentSurface {
        val name = relativePath.substringAfterLast('/').lowercase(Locale.ROOT)
        val extension = name.substringAfterLast('.', "")
        if (extension.isEmpty()) {
            // Extension-less well-known text files (Makefile, Dockerfile, …)
            // and unknown names both stay text-previewable, exactly like the
            // shared policy's `.unknown` case.
            return WorkspaceDocumentSurface.CODE_EDITOR
        }
        return when {
            extension in codeExtensions -> WorkspaceDocumentSurface.CODE_EDITOR
            extension in textExtensions -> WorkspaceDocumentSurface.CODE_EDITOR
            extension in officeExtensions -> WorkspaceDocumentSurface.OFFICE
            extension == "pdf" -> WorkspaceDocumentSurface.PDF
            extension in cadExtensions -> WorkspaceDocumentSurface.CAD
            extension in imageExtensions -> WorkspaceDocumentSurface.IMAGE
            extension in mediaExtensions -> WorkspaceDocumentSurface.MEDIA
            extension in archiveExtensions -> WorkspaceDocumentSurface.ARCHIVE
            extension in binaryExtensions -> WorkspaceDocumentSurface.QUICK_LOOK
            // Unknown extensions stay text-previewable exactly like iOS; the
            // native bridge still sniffs the bytes before any write.
            else -> WorkspaceDocumentSurface.CODE_EDITOR
        }
    }
}

/**
 * One explicit full-window document request. It carries only the already-owned
 * identity plus a monotonically increasing presentation token; it is not a
 * permission, a second dirty store or a durable route.
 */
internal data class WorkspaceDocumentRequest(
    val taskID: String,
    val workspaceID: String,
    val path: String,
    val surface: WorkspaceDocumentSurface,
    val token: Long,
) {
    val fileName: String get() = path.substringAfterLast('/')
}

/**
 * Window/owner policy for the document presentation. Pure and JVM-testable:
 * the Compose layers only render the decisions taken here.
 */
internal object WorkspaceDocumentPresentation {
    /**
     * Phone full-window document presentation. Deliberately reads the ACTUAL
     * window width through the same boundary the accepted phone file-list
     * flow uses (`IdeWorkspacePresentation`), never the measured pane width:
     * the 430dp tablet inspector must keep the in-pane editor even though it
     * is narrower than a phone.
     */
    internal fun isPhoneWindow(windowWidthDp: Float?, smallestWindowWidthDp: Float? = null): Boolean =
        IdeWorkspacePresentation.isPhoneWindow(windowWidthDp, smallestWindowWidthDp)

    /**
     * Whether selecting [surface] on this window opens the full-window
     * destination instead of the inspector pane.
     *
     * Office is excluded because its owned viewer is already a separate
     * full-screen Activity; wrapping it in a Compose dialog would present two
     * windows for one document.
     */
    internal fun presentsFullWindow(
        windowWidthDp: Float?,
        surface: WorkspaceDocumentSurface,
        smallestWindowWidthDp: Float? = null,
    ): Boolean = when (surface) {
        WorkspaceDocumentSurface.OFFICE -> false
        WorkspaceDocumentSurface.CODE_EDITOR -> isPhoneWindow(windowWidthDp, smallestWindowWidthDp)
        // No in-pane typed preview exists yet; a document is always an
        // explicit surface rather than a squeezed text column.
        else -> true
    }

    /**
     * The explicit "open full window" entry for a tablet/wide inspector pane.
     * Only a real open text/code document has a window to promote; the pane
     * keeps showing the same editor (and its drafts) behind it.
     */
    internal fun offersExplicitFullWindow(
        windowWidthDp: Float?,
        surface: WorkspaceDocumentSurface?,
        smallestWindowWidthDp: Float? = null,
    ): Boolean = surface == WorkspaceDocumentSurface.CODE_EDITOR && !isPhoneWindow(windowWidthDp, smallestWindowWidthDp)

    /**
     * A request may be presented only while it still names the exact owning
     * task/workspace and that owner is current. A task switch, a retired
     * native root, a temporary chat or a reused stale request all fail closed.
     */
    internal fun requestIsCurrent(
        request: WorkspaceDocumentRequest,
        ownerTaskID: String?,
        ownerWorkspaceID: String?,
        ownerCurrent: Boolean,
        temporary: Boolean,
    ): Boolean = ownerCurrent && !temporary &&
        request.taskID == ownerTaskID && request.workspaceID == ownerWorkspaceID &&
        request.path.isNotBlank()

    /**
     * The full-window editor issues its one open intent only when the same
     * document is not already live or loading there. A rotation during the
     * load therefore re-uses the in-flight open instead of dispatching twice.
     */
    internal fun needsReopen(
        currentPath: String?,
        documentLoading: Boolean,
        requestedPath: String,
    ): Boolean = !documentLoading && currentPath != requestedPath
}

/**
 * The single full-window document destination (the Android equivalent of the
 * iOS `fullScreenCover(WorkspaceIDEView)` / typed document cover). One opaque
 * page, no task scrim, no sidebar or file tree beside it. Back and the parent
 * system Back close the document and return to the exact file list that owns
 * it; the header Close on a typed document also leaves the whole pane.
 */
@Composable
internal fun WorkspaceDocumentDestination(
    request: WorkspaceDocumentRequest,
    host: RuntimeHost,
    /** The read/write code workbench presenter. Null is ONLY honest for
     *  surfaces that never touch it (PDF/image/media/CAD/archive/covers) —
     *  the conversation artifact route passes null there because it acquires
     *  the workbench binding lazily and only for CODE_EDITOR. A null
     *  presenter on CODE_EDITOR renders the honest typed cover instead of a
     *  dead editor page. */
    presenter: IdePresenter?,
    bottomAccessory: IdeBottomAccessory?,
    ownerTaskID: String?,
    ownerWorkspaceID: String?,
    ownerCurrent: Boolean,
    temporary: Boolean,
    onBackToFiles: () -> Unit,
    onCloseTask: () -> Unit,
    onOpenFolder: ((String) -> Unit)? = null,
) {
    val current = WorkspaceDocumentPresentation.requestIsCurrent(
        request = request,
        ownerTaskID = ownerTaskID,
        ownerWorkspaceID = ownerWorkspaceID,
        ownerCurrent = ownerCurrent,
        temporary = temporary,
    )
    if (!current) {
        // A stale/retired owner must never keep another task's document on
        // screen: dismiss without rendering the editor for one frame.
        LaunchedEffect(request.token) { onBackToFiles() }
        return
    }
    // PDF/raster are the only two typed surfaces with a real viewer in this
    // batch. The extension policy (not a content guess) decides; SVG/TIFF
    // stay on the honest typed cover.
    val previewKind = remember(request.path, request.surface) {
        when (request.surface) {
            WorkspaceDocumentSurface.PDF, WorkspaceDocumentSurface.IMAGE ->
                WorkspaceDocumentPreviewPolicy.kindForPath(request.path)
            else -> null
        }
    }
    // IMAGE keeps its default preview and adds an explicit Edit entry that
    // opens the media workbench for this exact file. Opening Edit is local to
    // this document request, never a second outer route.
    var imageEditOpen by rememberSaveable(request.token) { mutableStateOf(false) }
    // Read the accepted native root once per explicit request (never on
    // every preview recomposition); a replaced generation is retired by the
    // root-stop drain, and the next explicit open reads the new one.
    val nativeEpoch = remember(request.token) { host.nativeRootEpoch() }
    val previewOwner = remember(request.taskID, request.workspaceID, request.token, nativeEpoch) {
        nativeEpoch?.takeIf { it > 0 }?.let { epoch ->
            runCatching {
                Owner(
                    taskID = request.taskID,
                    workspaceID = request.workspaceID,
                    nativeEpoch = epoch,
                    hostGeneration = host.commandClient.generation(),
                )
            }.getOrNull()
        }
    }
    // A real navigation away (task switch, inspector route change, dragged
    // pane dismissal) retires the Application-owned preview. Rotation keeps
    // the live snapshot/renderer because it reuses the same request token.
    val uiContext = LocalContext.current
    DisposableEffect(request.token, previewKind) {
        onDispose {
            if (previewKind != null &&
                (uiContext as? Activity)?.isChangingConfigurations != true
            ) {
                host.workspaceDocumentPreview.close(request.token)
            }
        }
    }
    val closePreview: () -> Unit = {
        if (previewKind != null) host.workspaceDocumentPreview.close(request.token)
    }
    val backToFiles: () -> Unit = {
        closePreview()
        onBackToFiles()
    }
    val closeTask: () -> Unit = {
        closePreview()
        onCloseTask()
    }
    // App-owned design session for the SAME file document request. The sheet
    // is a feature-owned dialog; this destination only supplies the real
    // workspace/file identity and the App owner. No design project, path
    // authority or second document store is created here.
    val application = uiContext.applicationContext as? FloeApplication
    var designController by remember(request.token) {
        mutableStateOf<DesignWorkflowController?>(null)
    }
    var designEntryFailure by remember(request.token) { mutableStateOf(false) }
    var designSheetRequested by rememberSaveable(request.token) { mutableStateOf(false) }
    val latestDesignController by rememberUpdatedState(designController)
    val designSessionToken = remember(
        request.taskID, request.workspaceID, request.path, request.token,
    ) {
        DesignTargetResolver.documentSessionToken(
            taskID = request.taskID,
            workspaceID = request.workspaceID,
            relativePath = request.path,
            requestToken = request.token,
        )
    }
    val openDesign: () -> Unit = {
        val owner = application?.designUi
        if (owner == null) {
            designEntryFailure = true
        } else {
            try {
                designEntryFailure = false
                designController = owner.acquire(
                    DesignSessionRequest(
                        binding = DesignTargetResolver.workspaceFileBinding(
                            workspaceID = request.workspaceID,
                            relativePath = request.path,
                            sessionToken = designSessionToken,
                        ),
                        descriptor = DesignTargetDescriptor(
                            title = request.fileName,
                            kindLabel = uiContext.getString(R.string.design_app_target_document),
                        ),
                    ),
                )
                designSheetRequested = true
            } catch (_: Throwable) {
                designEntryFailure = true
            }
        }
    }
    LaunchedEffect(designSheetRequested, request.token) {
        // Rotation restores the request flag; re-acquire the SAME retained
        // App controller so the sheet and its drafts survive.
        if (designSheetRequested && designController == null) {
            openDesign()
        }
    }
    DisposableEffect(request.token) {
        onDispose {
            if ((uiContext as? Activity)?.isChangingConfigurations != true) {
                latestDesignController?.let { design ->
                    application?.designUi?.release(design)
                }
            }
        }
    }
    Dialog(
        onDismissRequest = backToFiles,
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false,
            dismissOnBackPress = true,
            dismissOnClickOutside = false,
        ),
    ) {
        BackHandler(onBack = backToFiles)
        Box(
            Modifier
                .fillMaxSize()
                .background(Floe.colors.readingSurface)
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .testTag("workspace.documentDestination"),
        ) {
            when (request.surface) {
                WorkspaceDocumentSurface.CODE_EDITOR -> {
                    val codePresenter = presenter
                    if (codePresenter == null) {
                        // No workbench binding was admitted for this request
                        // (the conversation route acquires it lazily and only
                        // for code): the honest typed cover instead of a dead
                        // editor page. The Files pane always passes a live
                        // presenter, so its behavior is unchanged.
                        WorkspaceTypedDocumentSurface(
                            request = request,
                            onBackToFiles = backToFiles,
                            onCloseTask = closeTask,
                        )
                    } else {
                        val state by codePresenter.state.collectAsState()
                        LaunchedEffect(request.token, request.path) {
                            if (WorkspaceDocumentPresentation.needsReopen(
                                    state.snapshot?.relativePath, state.documentLoading, request.path,
                                )
                            ) {
                                // Same presenter, same drafts/undo: this is an
                                // explicit open intent, never a second editor.
                                codePresenter.openFile(request.path, claimsPaneLevel = false)
                            }
                        }
                        FloeIdeDocumentWindow(
                            presenter = codePresenter,
                            onClose = backToFiles,
                            bottomAccessory = bottomAccessory,
                            modifier = Modifier.fillMaxSize(),
                        )
                    }
                }
                WorkspaceDocumentSurface.PDF,
                WorkspaceDocumentSurface.IMAGE,
                -> {
                    when {
                        request.surface == WorkspaceDocumentSurface.IMAGE &&
                            imageEditOpen && previewOwner != null ->
                            CreativeDocumentMediaDestination(
                                request = request,
                                host = host,
                                owner = previewOwner,
                                kind = "image",
                                onBackToFiles = { imageEditOpen = false },
                            )
                        previewKind != null && previewOwner != null -> WorkspaceDocumentPreview(
                            controller = host.workspaceDocumentPreview,
                            request = request,
                            kind = previewKind,
                            owner = previewOwner,
                            onBackToFiles = backToFiles,
                            onCloseTask = closeTask,
                            onEdit = if (
                                request.surface == WorkspaceDocumentSurface.IMAGE &&
                                mediaImageEditSupported(request.path)
                            ) {
                                { imageEditOpen = true }
                            } else {
                                null
                            },
                        )
                        // SVG/TIFF routed to IMAGE but has no claimed decoder:
                        // keep the honest typed cover instead of failing late.
                        previewKind == null -> WorkspaceTypedDocumentSurface(
                            request = request,
                            onBackToFiles = backToFiles,
                            onCloseTask = closeTask,
                            bodyRes = R.string.workspace_document_image_unsupported_body,
                        )
                        // No live native root can authorize a read: never show
                        // a placeholder document over a retired generation.
                        else -> LaunchedEffect(request.token) { onBackToFiles() }
                    }
                }
                WorkspaceDocumentSurface.MEDIA -> {
                    // R1 media editing is ISO-BMFF (MP4/MOV/M4V) only. An
                    // unsupported media container keeps the honest typed cover
                    // instead of opening a fake timeline.
                    val mediaKind = mediaWorkbenchKind(request.path)
                    if (mediaKind != null && previewOwner != null) {
                        CreativeDocumentMediaDestination(
                            request = request,
                            host = host,
                            owner = previewOwner,
                            kind = mediaKind,
                            onBackToFiles = backToFiles,
                        )
                    } else {
                        WorkspaceTypedDocumentSurface(
                            request = request,
                            onBackToFiles = backToFiles,
                            onCloseTask = closeTask,
                        )
                    }
                }
                WorkspaceDocumentSurface.CAD -> {
                    // C04A/C04B: real offline read-only DXF/DWG/STEP/IGES/BREP
                    // and GLB/glTF/OBJ/STL/3MF viewing over the pinned bundled
                    // readers, plus native `.floecad` directory packages read
                    // by the App adapter. A malformed package is a typed
                    // failure inside the viewer, never a ZIP guess or a text
                    // document; its failure surface offers the safe folder
                    // escape below.
                    val cadFormat = C04CadFormat.fromPath(request.path)
                    when {
                        cadFormat != null && previewOwner != null ->
                            C04CadViewerDestination(
                                controller = host.cadViewer,
                                request = request,
                                owner = previewOwner,
                                onBackToFiles = backToFiles,
                                onCloseTask = closeTask,
                                onOpenFolder = onOpenFolder?.let { open ->
                                    { open(request.path) }
                                },
                            )
                        previewOwner == null ->
                            LaunchedEffect(request.token) { onBackToFiles() }
                        else -> WorkspaceTypedDocumentSurface(
                            request = request,
                            onBackToFiles = backToFiles,
                            onCloseTask = closeTask,
                        )
                    }
                }
                WorkspaceDocumentSurface.ARCHIVE -> {
                    // WSF-SAFE-EXTRACT: the real bounded browser over the
                    // Application-owned controller and the ORIGINAL safe
                    // engine/lease authority. A missing live native root
                    // retires the request instead of rendering a dead
                    // surface; formats the engine refuses (RAR) fail as an
                    // honest typed state inside the browser, never as a
                    // fake list.
                    if (previewOwner != null) {
                        WorkspaceArchiveDestination(
                            controller = host.workspaceArchive,
                            request = request,
                            owner = previewOwner,
                            onBackToFiles = backToFiles,
                            onCloseTask = closeTask,
                            onOpenFolder = onOpenFolder,
                        )
                    } else {
                        LaunchedEffect(request.token) { onBackToFiles() }
                    }
                }
                // Office is handled by its owned viewer Activity before this
                // destination is raised; reaching here means the engine is
                // unavailable. Binary keeps its honest typed cover.
                else -> WorkspaceTypedDocumentSurface(
                    request = request,
                    onBackToFiles = backToFiles,
                    onCloseTask = closeTask,
                )
            }
            val designEntryVisible = previewOwner != null && !imageEditOpen &&
                !(request.surface == WorkspaceDocumentSurface.MEDIA &&
                    mediaWorkbenchKind(request.path) != null)
            if (designEntryVisible) {
                Column(
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(top = 48.dp, end = 12.dp),
                    horizontalAlignment = Alignment.End,
                ) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.design_app_action),
                        onClick = openDesign,
                        modifier = Modifier.testTag("workspace.design"),
                    )
                    if (designEntryFailure) {
                        FloeStatusLine(
                            icon = FloeIcons.WarningTriangle,
                            text = stringResource(R.string.design_app_entry_unavailable),
                            color = Floe.colors.pending,
                            modifier = Modifier.padding(top = 4.dp),
                        )
                    }
                }
            }
        }
    }
    designController?.let { design ->
        DesignWorkflowSheet(
            controller = design,
            onClosed = {
                designController = null
                designSheetRequested = false
                application?.designUi?.release(design)
            },
        )
    }
    DesignExportPickerEffect(application?.designUi?.exportDelivery)
}

/** The one document header shared by the real PDF/image/archive surfaces
 * and the honest typed cover: Back to the owning file list, the exact file
 * name and Close. [onEdit] is a surface-owned primary action (image edit,
 * archive extract/decompress) with its own label; it adds no second
 * navigation authority. */
@Composable
internal fun WorkspaceDocumentHeader(
    fileName: String,
    onBackToFiles: () -> Unit,
    onCloseTask: () -> Unit,
    onEdit: (() -> Unit)? = null,
    editLabel: Int = WorkbenchR.string.creative_edit_image,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(FloeLayout.ToolbarHeight + 4.dp)
            .padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        FloeToolbarIconButton(
            icon = FloeIcons.ChevronBack,
            contentDescription = stringResource(R.string.workspace_document_back_to_files),
            onClick = onBackToFiles,
            modifier = Modifier.testTag("workspace.documentBack"),
        )
        FloeText(
            fileName,
            style = Floe.typography.toolbarTitle,
            color = Floe.colors.label,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (onEdit != null) {
            FloeCapsuleAction(
                label = stringResource(editLabel),
                onClick = onEdit,
            )
        }
        FloeToolbarIconButton(
            icon = FloeIcons.Xmark,
            contentDescription = stringResource(R.string.close),
            onClick = onCloseTask,
        )
    }
}

/**
 * The explicit typed document surface for formats this build has no in-app
 * viewer for. It names the exact file and type and never pretends to render
 * or decode anything. This replaces the previous fallback that handed every
 * unknown path to the UTF-8 text workbench.
 */
@Composable
private fun WorkspaceTypedDocumentSurface(
    request: WorkspaceDocumentRequest,
    onBackToFiles: () -> Unit,
    onCloseTask: () -> Unit,
    bodyRes: Int = R.string.workspace_document_unavailable_body,
) {
    Column(Modifier.fillMaxSize()) {
        WorkspaceDocumentHeader(
            fileName = request.fileName,
            onBackToFiles = onBackToFiles,
            onCloseTask = onCloseTask,
        )
        FloeDivider()
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(28.dp),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            IconGlyph(FloeIcons.InfoCircle, Floe.colors.tertiaryLabel, 34.dp)
            FloeText(
                stringResource(typedSurfaceTypeLabel(request.surface)),
                style = Floe.typography.section,
                color = Floe.colors.label,
                modifier = Modifier.padding(top = 12.dp),
            )
            FloeText(
                stringResource(bodyRes),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(top = 6.dp),
            )
            FloeText(
                request.path,
                style = Floe.typography.metadata,
                color = Floe.colors.tertiaryLabel,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 18.dp),
            )
        }
    }
}

private fun typedSurfaceTypeLabel(surface: WorkspaceDocumentSurface): Int = when (surface) {
    WorkspaceDocumentSurface.OFFICE -> R.string.workspace_document_type_office
    WorkspaceDocumentSurface.PDF -> R.string.workspace_document_type_pdf
    WorkspaceDocumentSurface.IMAGE -> R.string.workspace_document_type_image
    WorkspaceDocumentSurface.MEDIA -> R.string.workspace_document_type_media
    WorkspaceDocumentSurface.CAD -> R.string.workspace_document_type_cad
    WorkspaceDocumentSurface.ARCHIVE -> R.string.workspace_document_type_archive
    WorkspaceDocumentSurface.QUICK_LOOK -> R.string.workspace_document_type_binary
    WorkspaceDocumentSurface.CODE_EDITOR -> R.string.workspace_document_type_text
}
