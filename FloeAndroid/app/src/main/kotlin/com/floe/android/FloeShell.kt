// SPDX-License-Identifier: MPL-2.0
package com.floe.android

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
import androidx.compose.foundation.Image
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
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.key
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.floe.android.design.Floe
import com.floe.android.design.LocalFloeOverlayMaterial
import com.floe.android.design.floeMaterialSource
import com.floe.android.design.rememberFloeMaterialController
import com.floe.android.design.FloeCheckboxRow
import com.floe.android.design.FloeColors
import com.floe.android.design.FloeDraftStore
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeSelectionStyle
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeText
import com.floe.android.design.FloeThemeMode
import com.floe.android.design.FloeVerticalDivider
import com.floe.android.design.InspectorContent
import com.floe.android.design.InspectorRoute
import com.floe.android.design.MoreDestination
import com.floe.android.host.capture.PacketCaptureNavigation
import com.floe.android.host.calendar.C06CalendarNavigation
import com.floe.android.host.entryflow.C07EntryFlowFeature
import com.floe.android.host.entryflow.C07EntryFlowHost
import com.floe.android.host.entryflow.C07EntryFlowSurface
import com.floe.android.host.entryflow.C07EntryNavigation
import com.floe.android.host.entryflow.C07EntryPackageKind
import com.floe.android.host.entryflow.C07HomeAttachmentStager
import com.floe.android.host.entryflow.C07PackageReviewOwner
import com.floe.android.design.SidebarSelection
import com.floe.android.design.WorkbenchSelection
import com.floe.android.feature.canvas.CreativeAvailability
import com.floe.android.feature.dataexchange.DataExchangePhase
import com.floe.android.feature.providers.FloeProviderSettingsDestination
import com.floe.android.host.AttachmentPickerEffect
import com.floe.android.host.LocalNetworkPermissionEffect
import com.floe.android.host.RuntimeHost
import com.floe.android.host.officerecovery.OfficeRecoveryEffect
import com.floe.android.host.RuntimeHostProvider
import com.floe.android.host.SkillsFolderPickerEffect
import com.floe.android.safgateway.SafAccessFlag
import com.floe.android.safgateway.SafUriRef
import com.floe.android.host.creative.GenerationForegroundOwner
import com.floe.android.host.creative.GenerationReturnDecision
import com.floe.android.host.creative.GenerationReturnNavigation
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
    val overlayMaterial = rememberFloeMaterialController()
    CompositionLocalProvider(LocalFloeOverlayMaterial provides overlayMaterial) {
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
}

@Composable
private fun FloeShellContent(
    themeMode: FloeThemeMode,
    onThemeModeChange: (FloeThemeMode) -> Unit,
    runtimeHost: RuntimeHost?,
) {
    val application = androidx.compose.ui.platform.LocalContext.current.applicationContext as? FloeApplication
    val shellLifecycle = LocalLifecycleOwner.current.lifecycle
    val shellLifecycleState by shellLifecycle.currentStateFlow.collectAsState()
    // External SEND/VIEW can leave an older Activity in another task. Only
    // the resumed surface may consume application-owned navigation requests.
    val consumesExternalRoutes = shellLifecycleState.isAtLeast(Lifecycle.State.RESUMED)
    val officePreviews = application?.officePreviews
    if (officePreviews != null) {
        OfficePreviewEffect(officePreviews, themeMode)
        // C08: durable interrupted-Office-save review. Mounted beside the
        // existing preview effect; the controller owns discovery/actions and
        // performs nothing until the user chooses.
        OfficeRecoveryEffect(officePreviews.recovery)
    }
    if (application != null) {
        NotesPdfPasswordDialog(application.notesPdfPasswords)
        val notesPlatform by application.notesPlatform.collectAsState()
        (notesPlatform as? NotesPlatformLoadState.Ready)?.host?.let {
            com.floe.android.notesplatform.NotesPlatformEffectHost(it)
        }
    }
    var officeNavigationGeneration by remember { mutableLongStateOf(0L) }
    // G02 selection persistence contract: the SAVED key carries ONLY
    // durable/ordinary selections. A live temporary surface is RAM truth
    // owned by the application-scoped runtime host — it survives rotation/
    // background/recreation because the host does, and it is gone with the
    // process. A fresh process therefore restores Home or the last durable
    // conversation and never reinterprets a lost temporary id as a blank
    // ordinary chat; a genuinely Kept conversation persists through its
    // remapped durable id and reopens ordinary (same-id).
    var selectionKey by rememberSaveable { mutableStateOf(SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK).key) }
    // The live visible surface. REMEMBERED: the previous non-remembered
    // state object was recreated by every recomposition, which forced the
    // navigation collector to re-derive the visible selection from the
    // persisted key. Recreation re-initializes from the live RAM temporary
    // (when one exists) or the durable persisted key.
    val liveTemporaryIdAtRestore =
        runtimeHost?.conversations?.activeTemporarySession()?.conversationId
    var selection: SidebarSelection by remember {
        mutableStateOf(restoredShellSelection(selectionKey, liveTemporaryIdAtRestore))
    }
    LaunchedEffect(application, selection) {
        if (selection == SidebarSelection.More(MoreDestination.NOTES)) {
            application?.ensureNotesPlatform()
        }
    }

    /** The EXACT (conversation id, holder instance) the visible detail
     * surface currently binds, reported by the conversation destination
     * itself. Written only on holder binding, cleared on every visible-
     * selection commit. Lets the shell prove still-visible holder ownership
     * for the privacy-clear invalidation WITHOUT making the host registry
     * observable (a re-resolve through `holderFor` would silently re-create
     * a deleted id as an empty thread). */
    var visibleConversationBinding:
        Pair<String, com.floe.android.feature.conversation.ConversationFlowHolder>? by remember {
            mutableStateOf(null)
        }
    // Phone chat Back returns to the surface the task was opened from (Home,
    // Task Center or another workspace), not to the drawer and never to a
    // fabricated blank chat. It lives in RAM like the route itself.
    var conversationReturnTarget: SidebarSelection by remember {
        mutableStateOf(SidebarSelection.Workbench(WorkbenchSelection.OVERVIEW))
    }

    /** The one visible-selection write for every commit path: the live
     * surface always updates; the persisted key follows ONLY for durable/
     * ordinary targets, so a live temporary id never reaches saved state. */
    fun commitVisibleSelection(next: SidebarSelection) {
        if (selection != next) application?.cancelNotesPasswordPrompt()
        if (next is SidebarSelection.Conversation && selection !is SidebarSelection.Conversation) {
            conversationReturnTarget = selection
        }
        selection = next
        // The exact holder binding belongs to the PREVIOUS visible surface;
        // the conversation destination re-reports after composing the next.
        visibleConversationBinding = null
        runtimeHost?.conversations?.bindPrivacyVisibleHolder(null)
        val liveTemporaryId =
            runtimeHost?.conversations?.activeTemporarySession()?.conversationId
        if (!isLiveTemporarySelection(next, liveTemporaryId)) {
            selectionKey = next.key
        }
    }
    var settingsVisible by rememberSaveable { mutableStateOf(false) }
    var settingsSectionKey by rememberSaveable { mutableStateOf("") }
    var previewVisible by rememberSaveable { mutableStateOf(false) }
    var inspectorRoute by rememberSaveable { mutableStateOf<String?>(null) }
    var sidebarCollapsed by rememberSaveable { mutableStateOf(false) }
    var drawerOpen by rememberSaveable { mutableStateOf(false) }
    // The IME belongs to the surface that opened it. Opening the compact
    // drawer is explicit navigation to another surface, so the drawer takes
    // the keyboard away BEFORE it paints (device evidence: the terminal IME
    // covered the drawer bottom).
    val dismissIme = rememberImeDismissal()
    // One-shot sub-view signal for the Task Center. Incremented ONLY by an
    // ADMITTED Home→Task Center navigation commit (never by a refused
    // temporary-session fence), so the schedules surface cannot bypass the
    // shell's existing route authority.
    var taskCenterSchedulesToken by rememberSaveable { mutableIntStateOf(0) }
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    // Exact raw notification return, admitted only after the live claim and
    // current native bound epoch are re-proven. It survives Activity rotation
    // through the process-scoped owner; a refused fence dismisses it.
    val generationReturnRequest by GenerationReturnNavigation.pending.collectAsState()

    // G05-R2 Office AI transient launch admission (Main review 2026-10-27):
    // project the shell's MODAL surfaces (Settings Dialog, preview Dialog,
    // open drawer) onto the host for the AI lane's pre-claim admission only.
    // Observation-only: privacy holder binding, BACK handling, dialog stacking
    // and every launch behavior stay exactly as they are; the Settings Dialog
    // overlays the still-composed chat without clearing privacyVisibleHolder,
    // which is precisely why this separate fact exists.
    androidx.compose.runtime.LaunchedEffect(settingsVisible, previewVisible, drawerOpen) {
        runtimeHost?.uiModalSurfaceOwned = settingsVisible || previewVisible || drawerOpen
    }

    // The actual viewer claim reads these mutable state delegates on the
    // UI thread, including a modal change before its next recomposition.
    // Only AI opens require this gate; manual opens keep their own owner.
    val officeAiAdmissionOwner = remember(officePreviews) { Any() }
    androidx.compose.runtime.SideEffect {
        officePreviews?.setAiLaunchAdmission(officeAiAdmissionOwner) { taskId ->
            taskId != null && application?.isActivityInForeground() == true &&
                !settingsVisible && !previewVisible && !drawerOpen &&
                runtimeHost?.conversations?.currentVisibleConversationId() == taskId
        }
    }
    androidx.compose.runtime.DisposableEffect(officePreviews, officeAiAdmissionOwner) {
        onDispose { officePreviews?.clearAiLaunchAdmission(officeAiAdmissionOwner) }
    }

    // G02 host presentation effects: navigation / inspector / permissions /
    // attachment picker / Skills folder picker / API 37 local-network
    // permission dialog. Observed here so composables stay observe-only.
    // The three platform launch lanes mount EXACTLY once each, under this
    // same non-null RuntimeHost block; shell navigation and the temporary
    // Keep promotion below are untouched by them.
    if (runtimeHost != null) {
        AttachmentPickerEffect(runtimeHost)
        SkillsFolderPickerEffect(runtimeHost)
        LocalNetworkPermissionEffect(runtimeHost)
        com.floe.android.host.NetworkDiagnosticPermissionEffect(runtimeHost)
        com.floe.android.host.BackgroundTaskPermissionEffect(runtimeHost)
        // D04 (job-6f953da44de048d0): the owned run-output Save-Copy
        // CREATE_DOCUMENT launcher mounts exactly once with the other
        // platform pickers; a null service (fixtures) is inert.
        com.floe.android.host.output.RunOutputSavePickerEffect(application?.runOutputs)
        LaunchedEffect(runtimeHost) {
            val host = runtimeHost ?: return@LaunchedEffect
            C07EntryFlowHost.attach(host)
            C07EntryFlowHost.installHomeAttachmentStager(
                object : C07HomeAttachmentStager {
                    override fun stage(uris: List<android.net.Uri>): Boolean {
                        val (nonce, generation) =
                            host.conversations.rootWorkspace.currentDraftOwner()
                        return host.attachments.stageDraftUris(nonce, generation, uris)
                    }
                },
            )
            // C07 package handoff: the EXISTING Data Exchange owner performs
            // archive inspection/review (never restore on arrival). The source
            // reference is retained here BEFORE the entry owner releases its
            // lease, and released by that owner's exact source-settled callback.
            C07EntryFlowHost.installPackageReviewOwner(
                object : C07PackageReviewOwner {
                    override val settingsSectionKey: String = "data-exchange"

                    override fun beginReview(
                        uri: android.net.Uri,
                        kind: C07EntryPackageKind,
                        displayName: String,
                        releaseSource: () -> Unit,
                    ): Boolean {
                        // A .floecad package is a DIRECTORY. The only real
                        // import is the existing task-scoped workspace tree
                        // import; never fabricate a ZIP review for it.
                        if (kind == C07EntryPackageKind.CAD) return false
                        if (host.nativeRootEpoch() == null) return false
                        val exchange = host.c07DataExchange
                        if (exchange.state.value.busy ||
                            exchange.state.value.phase == DataExchangePhase.REVIEWING
                        ) {
                            return false
                        }
                        val retained = try {
                            com.floe.android.host.SharedUriGrantAuthority.broker.retain(
                                SafUriRef(uri.toString()),
                                SafAccessFlag.READ,
                            )
                        } catch (_: RuntimeException) {
                            return false
                        }
                        return try {
                            exchange.beginRestore(uri, kind.wire) {
                                runCatching { retained.release() }
                                releaseSource()
                            }
                            true
                        } catch (_: Throwable) {
                            runCatching { retained.release() }
                            false
                        }
                    }
                },
            )
        }
        LaunchedEffect(runtimeHost) {
            // ONE serial consumer for host navigation. Collecting (instead of
            // keying a LaunchedEffect on the value) means clearing the
            // request cannot cancel the application halfway through a
            // temporary-fence await: the final route commit always runs.
            runtimeHost.conversations.navigationRequest.collect { requested ->
                if (requested != null) {
                    runtimeHost.conversations.navigationRequest.value = null
                    // Home request ownership travels THROUGH the final route
                    // commit: the claim is taken before the fence await and
                    // re-validated after it, so an intent invalidated during
                    // the wait can never move the route. A Home-owned route
                    // is consumed exactly once; any other navigation commits
                    // normally, so a kept ordinary conversation can always be
                    // reopened from TaskCenter/history.
                    runtimeHost.home.applyHostNavigation(
                        target = requested,
                        waitForAdmission = {
                            val currentTemporary =
                                runtimeHost.conversations.activeTemporarySession()
                            // The REMEMBERED live surface is the visible
                            // selection (it tracks temporary truth that the
                            // durable-only persisted key intentionally
                            // does not carry).
                            val visibleSelection = selection
                            val leavingConversation =
                                visibleSelection is SidebarSelection.Conversation &&
                                    requested.key != visibleSelection.key
                            if (currentTemporary != null && leavingConversation) {
                                runtimeHost.conversations.tempFence.beginEnd(currentTemporary)
                                runtimeHost.conversations.tempFence
                                    .awaitAdmission(currentTemporary)
                            } else {
                                true
                            }
                        },
                        commit = { next ->
                            commitVisibleSelection(next)
                            drawerOpen = false
                            inspectorRoute = null
                        },
                    )
                }
            }
        }
        LaunchedEffect(runtimeHost) {
            // ONE serial consumer for the scoped same-id Keep promotion.
            // The committed terminal can arrive LATE (root-wide client, no
            // per-holder filtering in trackOperation), so the durable kept
            // selection reaches this shell ONLY while the EXACT origin
            // surface is still current. A stale adoption is dropped: no
            // old-id navigation, no fence-end of a new temporary session
            // that now owns the surface. Rotation/background reconstruction
            // of the same still-live origin re-adopts it as current first,
            // so the genuine keep-stays-where-you-was path remains valid.
            runtimeHost.conversations.keptPromotion.collect { promotion ->
                if (promotion != null) {
                    runtimeHost.conversations.keptPromotion.value = null
                    val originEntry = runtimeHost.conversations
                        .entryFor(promotion.originRef.conversationId)
                    if (keptPromotionAppliesToVisibleOrigin(
                            visible = selection,
                            visibleConversationEpoch =
                                originEntry?.holder?.session?.sessionEpoch,
                            origin = promotion.originRef,
                        )
                    ) {
                        commitVisibleSelection(
                            SidebarSelection.Conversation(promotion.durableConversationId),
                        )
                    }
                }
            }
        }
        LaunchedEffect(runtimeHost, consumesExternalRoutes) {
            // C06 notification return: reveal the existing Network workbench
            // so its live capture panel reads the service-owned state. The
            // Intent carries no path/session content and is consumed once.
            if (!consumesExternalRoutes) return@LaunchedEffect
            PacketCaptureNavigation.requests.collect { nonce ->
                if (nonce != null) {
                    PacketCaptureNavigation.consume(nonce)
                    commitVisibleSelection(SidebarSelection.More(MoreDestination.NETWORK))
                    drawerOpen = false
                    inspectorRoute = null
                }
            }
        }
        LaunchedEffect(runtimeHost) {
            // ONE serial consumer for the privacy-clear UI invalidation.
            // The host publishes an EXACT signal only after an authoritative
            // same-root conversation.get notFound; the shell — sole route
            // authority — retires and genuinely navigates away ONLY the
            // still-visible, exactly-owned durable surface. Every other
            // origin (moved away, Notes/survivor, the live temporary, a
            // re-opened/rebound same-id holder, or a root change during the
            // off-main await) drops the signal; the host release has already
            // fenced the deleted holder's pumps regardless.
            runtimeHost.conversations.privacyClearedConversation.collect { signal ->
                if (signal != null) {
                    runtimeHost.conversations.privacyClearedConversation.value = null
                    fun appliesNow(): Boolean = privacyClearedConversationAppliesToVisibleOrigin(
                        visible = selection,
                        boundConversationId = visibleConversationBinding?.first,
                        boundHolder = visibleConversationBinding?.second,
                        origin = signal,
                        liveTemporaryConversationId =
                            runtimeHost.conversations.activeTemporarySession()?.conversationId,
                    )
                    if (appliesNow()) {
                        // Native ownership re-check OFF the main thread.
                        val rootNow = kotlinx.coroutines.withContext(
                            kotlinx.coroutines.Dispatchers.IO) {
                            runtimeHost.nativeRootEpoch()
                        }
                        // The visible origin is RE-VALIDATED after the await.
                        if (rootNow == signal.rootEpoch && appliesNow()) {
                            // Genuine transition to the existing New Task
                            // route through the existing home lifecycle; the
                            // deleted visible holder is retired through the
                            // existing UI-owner path exactly when the
                            // admitted route commits.
                            runtimeHost.home.applyHostNavigation(
                                target =
                                    SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK),
                                // This scoped deletion signal must never end a
                                // replacement temporary session. Refuse stale
                                // origins instead of using the generic temp fence.
                                waitForAdmission = {
                                    appliesNow() && runtimeHost.conversations
                                        .activeTemporarySession() == null
                                },
                                commit = { next ->
                                    signal.holder.retireForNavigation()
                                    commitVisibleSelection(next)
                                    drawerOpen = false
                                    inspectorRoute = null
                                },
                            )
                        }
                    }
                }
            }
        }
        val browserAttention by runtimeHost.browser.panelAttention.collectAsState()
        val userPreviewRequests by runtimeHost.browser.previewPresentationRequests.collectAsState()
        val selectedBrowserTask = (selection as? SidebarSelection.Conversation)?.conversationId
        val attentionID = browserAttention.entries.firstOrNull { it.key.equals(selectedBrowserTask, true) }?.value
        val previewRequest = userPreviewRequests.entries.firstOrNull { it.key.equals(selectedBrowserTask, true) }
        LaunchedEffect(selectedBrowserTask, attentionID, previewRequest?.value) {
            val taskID = selectedBrowserTask ?: return@LaunchedEffect
            if (runtimeHost.conversations.entryFor(taskID)?.isTemporary == true) return@LaunchedEffect
            val pending = runtimeHost.browser.hasPendingPanelRequest(taskID)
            if (pending || previewRequest != null) {
                inspectorRoute = encodeInspectorRoute(InspectorRoute(InspectorContent.BROWSER, taskID))
                previewRequest?.let { runtimeHost.browser.consumePreviewPresentation(taskID, it.value) }
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
        // Sidebar chat rows read the SAME produced history wire as the Task
        // Center; one scoped load when the shell binds the host (run-event
        // settlement already refreshes through the host's own collector).
        LaunchedEffect(runtimeHost) {
            runtimeHost.conversations.reloadHistory()
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
    val overlayMaterial = LocalFloeOverlayMaterial.current

    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .background(Floe.colors.readingSurface),
    ) {
        if (runtimeHost != null) {
            val browserTasks by runtimeHost.browser.hostedTasks.collectAsState()
            // Real layout/viewport, no touch target or accessibility node.
            // Only already-owned platform bindings are hosted; merely
            // selecting a task does not conjure a workspace or session.
            browserTasks.forEach { taskID -> key(runtimeHost, taskID) {
                BrowserOffscreenHost(taskID, runtimeHost,
                    Modifier.requiredSize(1024.dp, 768.dp).alpha(0f).clearAndSetSemantics {})
            } }
        }
        val totalWidthDp = maxWidth.value
        val overlayMaxWidthDp = maxWidth * 0.92f
        val minimumWindowWidth = androidx.compose.ui.platform.LocalConfiguration.current.smallestScreenWidthDp.toFloat()
        val twoColumn = !FloeLayout.usesCompactNavigation(maxWidth.value, minimumWindowWidth)
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
        // Back engages from any non-Home visible surface — including a live
        // temporary one, whose id never reaches the persisted key; the
        // decision therefore reads the live selection, not the saved key.
        val baseNavCanRun = !persistentSidebar && route == null && !drawerOpen &&
            !settingsVisible && !previewVisible &&
            selection.key != SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK).key
        ImeFirstBackHandler(enabled = baseNavCanRun) {
            // System Back at a conversation surface IS an actual navigation
            // to New Task: when a temporary session owns the surface it
            // must pass the same synchronous fence as every other route
            // (TMP-NAV-2). Refusal/timeout never moves the route; ordinary
            // surfaces keep the direct platform behavior.
            val currentTemporary = runtimeHost?.conversations?.activeTemporarySession()
            if (runtimeHost != null && currentTemporary != null &&
                selection is SidebarSelection.Conversation
            ) {
                val ref = currentTemporary
                scope.launch {
                    runtimeHost.conversations.tempFence.beginEnd(ref)
                    if (runtimeHost.conversations.tempFence.awaitAdmission(ref)) {
                        runtimeHost.home.onNavigation(
                            SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK))
                        commitVisibleSelection(
                            SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK))
                    }
                }
            } else {
                runtimeHost?.home?.onNavigation(
                    SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK))
                commitVisibleSelection(
                    SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK))
            }
        }
        ImeFirstBackHandler(enabled = drawerOpen) { drawerOpen = false }

        fun navigateTo(
            target: SidebarSelection,
            openSchedules: Boolean,
            onCommitted: (() -> Unit)? = null,
            onRefused: (() -> Unit)? = null,
            mayCommit: () -> Boolean = { true },
        ) {
            if (!mayCommit()) {
                onRefused?.invoke()
                return
            }
            officeNavigationGeneration++
            val navigationGeneration = officeNavigationGeneration
            val previousSelectionKey = selection.key
            officePreviews?.cancelUnopened()
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
                    onCommitted?.invoke()
                }
                // Genuine route transition while a temporary session owns the
                // surface: fence admission BEFORE the transition (TMP-NAV-2);
                // the async drain continues afterwards. A REFUSED/timeout
                // fence commits nothing — including no schedule sub-view and
                // no generation-return open.
                runtimeHost != null && currentTemporary != null && leavingConversation -> {
                    val ref = currentTemporary
                    scope.launch {
                        runtimeHost.conversations.tempFence.beginEnd(ref)
                        val admitted = runtimeHost.conversations.tempFence.awaitAdmission(ref)
                        if (admitted &&
                            navigationGeneration == officeNavigationGeneration &&
                            selection.key == previousSelectionKey && mayCommit()
                        ) {
                            runtimeHost?.home?.onNavigation(target)
                            commitVisibleSelection(target)
                            if (taskCenterSchedulesOpenOnCommit(target, openSchedules)) {
                                taskCenterSchedulesToken++
                            }
                            drawerOpen = false
                            inspectorRoute = null
                            onCommitted?.invoke()
                        } else {
                            // The refused fence owns NO destination: nothing
                            // is opened and the caller must not claim success.
                            onRefused?.invoke()
                        }
                    }
                }
                else -> {
                    runtimeHost?.home?.onNavigation(target)
                    commitVisibleSelection(target)
                    if (taskCenterSchedulesOpenOnCommit(target, openSchedules)) {
                        taskCenterSchedulesToken++
                    }
                    drawerOpen = false
                    // Ordinary navigation (iOS semantics): leaving the visible
                    // conversation surface ends temporary chat; rotation,
                    // recreation, background and lock never reach this path.
                    inspectorRoute = null
                    onCommitted?.invoke()
                }
            }
        }

        val select: (SidebarSelection) -> Unit = { target ->
            navigateTo(target, openSchedules = false)
        }

        // Aggregate notifications carry no invented task association. Use
        // the existing route authority, including the temporary-chat fence.
        val ownedNotification by com.floe.android.host.notification.OwnedNotificationNavigation.pending.collectAsState()
        LaunchedEffect(ownedNotification?.id, consumesExternalRoutes) {
            if (!consumesExternalRoutes) return@LaunchedEffect
            val request = ownedNotification ?: return@LaunchedEffect
            val navigation = com.floe.android.host.notification.OwnedNotificationNavigation
            if (!navigation.isCurrent(request)) { navigation.dismiss(request.id); return@LaunchedEffect }
            navigateTo(
                target = SidebarSelection.Workbench(WorkbenchSelection.OVERVIEW),
                openSchedules = false,
                mayCommit = { shellLifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) && navigation.isCurrent(request) },
                onCommitted = {
                    settingsVisible = false
                    previewVisible = false
                    navigation.dismiss(request.id)
                },
                onRefused = { navigation.dismiss(request.id) },
            )
        }

        // C06 local reminder route. This is the shell's ONE calendar route
        // authority: the destination re-reads the exact todo and never opens a
        // different task/root. A temporary-chat fence refusal dismisses the
        // request instead of committing a partial navigation.
        val calendarReminderRoute by C06CalendarNavigation.pending.collectAsState()
        LaunchedEffect(calendarReminderRoute?.requestID, consumesExternalRoutes) {
            if (!consumesExternalRoutes) return@LaunchedEffect
            val request = calendarReminderRoute ?: return@LaunchedEffect
            if (C06CalendarNavigation.isExpired(request)) {
                C06CalendarNavigation.dismiss(request.requestID)
                return@LaunchedEffect
            }
            navigateTo(
                target = SidebarSelection.More(MoreDestination.CALENDAR),
                openSchedules = false,
                onRefused = { C06CalendarNavigation.dismiss(request.requestID) },
            )
        }

        // C07 external entry route. The App host has already re-read the
        // existing conversation/schedule store and refused stale targets; this
        // consumer only commits the ordinary route, with the EXISTING
        // temporary-chat fence and the existing schedule sub-view token.
        LaunchedEffect(runtimeHost, consumesExternalRoutes) {
            runtimeHost ?: return@LaunchedEffect
            if (!consumesExternalRoutes) return@LaunchedEffect
            C07EntryFlowHost.navigation.collect { requested ->
                val request = requested ?: return@collect
                fun navigateEntry(
                    target: SidebarSelection,
                    openSchedules: Boolean = false,
                    onCommitted: () -> Unit = {},
                    onRefused: () -> Unit = { C07EntryFlowHost.navigationRefused() },
                ) {
                    fun current() = shellLifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) &&
                        C07EntryFlowHost.navigation.value == request
                    navigateTo(target, openSchedules,
                        mayCommit = { current() },
                        onCommitted = {
                            onCommitted()
                            C07EntryFlowHost.consumeNavigation(request)
                        },
                        onRefused = {
                            // Leave a paused surface's request pending for the
                            // actual resumed Activity; do not consume its route.
                            if (current()) {
                                onRefused()
                                C07EntryFlowHost.consumeNavigation(request)
                            }
                        },
                    )
                }
                when (request) {
                    is C07EntryNavigation.OpenTask -> navigateEntry(
                        target = SidebarSelection.Conversation(request.conversationID),
                    )
                    is C07EntryNavigation.OpenSchedule -> navigateEntry(
                        target = SidebarSelection.Workbench(WorkbenchSelection.OVERVIEW),
                        openSchedules = true,
                    )
                    is C07EntryNavigation.OpenNewTask -> navigateEntry(
                        target = SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK),
                        openSchedules = false,
                        onCommitted = {
                            request.intakeID?.let(C07EntryFlowHost::applyTaskDestination)
                        },
                        onRefused = {
                            request.intakeID?.let {
                                C07EntryFlowHost.taskDestinationRefused(it, temporary = true)
                            }
                        },
                    )
                    C07EntryNavigation.OpenNotes -> navigateEntry(
                        target = SidebarSelection.More(MoreDestination.NOTES),
                        openSchedules = false,
                    )
                }
            }
        }

        // Generation notification return. This is the shell's single route
        // authority: it re-proves the opaque token against the LIVE registered
        // foreground claim, the exact captured project context and the CURRENT
        // native bound epoch, then uses the ordinary Creative route (including
        // the existing temporary-chat fence). A rejected token is dismissed
        // with no navigation; a refused fence publishes no approval, so no
        // project can open and no success is claimed.
        LaunchedEffect(application, generationReturnRequest?.requestID, consumesExternalRoutes) {
            if (!consumesExternalRoutes) return@LaunchedEffect
            val request = generationReturnRequest ?: return@LaunchedEffect
            val app = application ?: return@LaunchedEffect
            // Never swallow coroutine cancellation: a rotation during the
            // read must leave the one-shot pending for the next composition.
            val status = try {
                app.creativeHost.services.status()
            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                null
            }
            if (!shellLifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) return@LaunchedEffect
            val decision = if (request.source == GenerationReturnNavigation.Source.EXPORT) {
                com.floe.android.host.notification.resolveExportReturn(
                    request.token, status?.boundEpoch,
                    status?.availability ?: CreativeAvailability.Unavailable)
            } else GenerationForegroundOwner.resolveReturn(
                token = request.token,
                nowElapsedMillis = android.os.SystemClock.elapsedRealtime(),
                liveEpoch = status?.boundEpoch,
                availability =
                    status?.availability ?: CreativeAvailability.Unavailable,
            )
            when (decision) {
                is GenerationReturnDecision.Rejected -> {
                    // Unknown/expired token, unregistered claim, missing
                    // captured context, wrong root/epoch or unavailable host:
                    // refuse safely. Never falls back to the first project.
                    GenerationReturnNavigation.dismiss(request.requestID)
                }
                is GenerationReturnDecision.Authorized -> {
                    if (GenerationReturnNavigation.pending.value?.requestID !=
                        request.requestID) return@LaunchedEffect
                    val creative =
                        SidebarSelection.More(MoreDestination.CREATIVE)
                    val liveTemporary =
                        runtimeHost?.conversations?.activeTemporarySession()
                    if (selection == creative && liveTemporary == null) {
                        // Already on the exact destination: no redundant
                        // route side effect. Transient shell overlays must not
                        // hide the full-window project; the outer split and
                        // route order are unchanged.
                        settingsVisible = false
                        previewVisible = false
                        drawerOpen = false
                        inspectorRoute = null
                        GenerationReturnNavigation.approve(
                            request.requestID, decision.target)
                    } else {
                        navigateTo(
                            target = creative,
                            openSchedules = false,
                            mayCommit = {
                                shellLifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) &&
                                    GenerationReturnNavigation.pending.value?.requestID ==
                                    request.requestID &&
                                    (request.source != GenerationReturnNavigation.Source.EXPORT ||
                                        com.floe.android.host.notification.resolveExportReturn(request.token,
                                            application?.mediaWorkbench?.currentEpoch(), CreativeAvailability.Available) == decision)
                            },
                            onCommitted = {
                                // Close transient overlays only after the real
                                // route/fence commit, so a refused fence leaves
                                // the current surface untouched.
                                settingsVisible = false
                                previewVisible = false
                                drawerOpen = false
                                inspectorRoute = null
                                GenerationReturnNavigation.approve(
                                    request.requestID, decision.target)
                            },
                            onRefused = {
                                GenerationReturnNavigation.dismiss(
                                    request.requestID)
                            },
                        )
                    }
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
                runtimeHost = runtimeHost,
                onOpenDocument = officePreviews?.let { controller ->
                    {
                        val navigation = ++officeNavigationGeneration
                        drawerOpen = false
                        scope.launch {
                            val temporary = runtimeHost?.conversations?.activeTemporarySession()
                            if (runtimeHost != null && temporary != null) {
                                // This is explicit navigation to a local
                                // document, not an expanded temporary-chat
                                // tool ceiling or a view reconstruction.
                                runtimeHost.conversations.tempFence.beginEnd(temporary)
                                if (!runtimeHost.conversations.tempFence.awaitAdmission(temporary) ||
                                    navigation != officeNavigationGeneration ||
                                    runtimeHost.conversations.activeTemporarySession() != null) return@launch
                                val home = SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK)
                                runtimeHost.home.onNavigation(home)
                                commitVisibleSelection(home)
                            }
                            if (navigation != officeNavigationGeneration) return@launch
                            inspectorRoute = null
                            controller.requestProviderPick()
                        }
                        Unit
                    }
                },
            )
        }

        val detail: @Composable () -> Unit = {
            // G05-R3 office-return109 explicit owned-document return strip.
            // Visible ONLY on the conversation that OWNS the live VIEWING
            // Office mount; at click the controller re-proves the exact
            // identity + ownerCurrent fence and dispatches the raise under
            // the SAME lock, so no settle or replacement mount can be
            // selected in between. It cannot steal another chat's,
            // settings' or the home surface's navigation — and ordinary
            // system Back semantics elsewhere stay EXACTLY as before. One
            // tap raises the SAME viewer instance (document and owned
            // editContext preserved; no close, recreate or replay);
            // close/settle/replace clears the published identity and the
            // strip disappears with it. Provider-pick opens have no owner
            // and never show it.
            val officeState = officePreviews?.state?.collectAsState()?.value
            val recoveryState = officePreviews?.recovery?.state?.collectAsState()?.value
            val recoveryEntry = recoveryState != null &&
                !recoveryState.visible &&
                recoveryState.candidates.any { it.unresolved }
            val visibleConversationId =
                (selection as? SidebarSelection.Conversation)?.conversationId
            val ownedReturnTarget = officeState?.ownedReturn?.takeIf { target ->
                visibleConversationId != null && target.ownerTaskId == visibleConversationId
            }
            Column(Modifier.fillMaxSize()) {
                ownedReturnTarget?.let { target ->
                    val returnLabel = stringResource(
                        R.string.office_return_title,
                        officeState?.viewer?.request?.displayName.orEmpty(),
                    )
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 44.dp)
                            .clickable { officePreviews?.requestOwnedViewerRestore(target) }
                            .semantics { contentDescription = returnLabel }
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Image(
                            imageVector = FloeIcons.ChevronBack,
                            contentDescription = null,
                            colorFilter = ColorFilter.tint(Floe.colors.accent),
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.width(10.dp))
                        FloeText(
                            text = returnLabel,
                            modifier = Modifier.weight(1f),
                            style = Floe.typography.metadata,
                            color = Floe.colors.label,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Spacer(Modifier.width(10.dp))
                        FloeText(
                            text = stringResource(R.string.office_return_action),
                            style = Floe.typography.bodyEmphasized,
                            color = Floe.colors.accent,
                        )
                    }
                }
                if (recoveryEntry) {
                    // Bounded re-entry after the recovery sheet is dismissed:
                    // the review stays discoverable without a process restart.
                    val zhRecovery = java.util.Locale.getDefault().language == "zh"
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 44.dp)
                            .clickable { officePreviews?.recovery?.show() }
                            .semantics {
                                contentDescription = if (zhRecovery) "恢复 Office 文档" else "Recover Office document"
                            }
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        FloeText(
                            text = if (zhRecovery) "恢复 Office 文档" else "Recover Office document",
                            modifier = Modifier.weight(1f),
                            style = Floe.typography.metadata,
                            color = Floe.colors.label,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Spacer(Modifier.width(10.dp))
                        FloeText(
                            text = if (zhRecovery) "查看" else "Review",
                            style = Floe.typography.bodyEmphasized,
                            color = Floe.colors.accent,
                        )
                    }
                }
                FloeDetailColumn(
                    selection = selection,
                    showSidebarToggle = !persistentSidebar && twoColumn,
                    onExpandSidebar = { sidebarCollapsed = false },
                    onOpenDrawer = {
                        dismissIme()
                        drawerOpen = true
                    },
                    compact = !twoColumn,
                    inspectorRoute = route,
                    onInspectorDismiss = { inspectorRoute = null },
                    onOpenSettingsSection = { sectionKey ->
                        drawerOpen = false
                        settingsSectionKey = sectionKey
                        settingsVisible = true
                    },
                    runtimeHost = runtimeHost,
                    onConversationBack = {
                        select(conversationReturnTarget)
                    },
                    onConversationHolderBound = { boundId, boundHolder ->
                        visibleConversationBinding = boundId to boundHolder
                        runtimeHost?.conversations?.bindPrivacyVisibleHolder(boundHolder)
                    },
                    // Home's Scheduled Tasks card asks the SHELL to navigate;
                    // the token is incremented only after the real commit
                    // (including temporary-chat fence admission).
                    onOpenSchedules = {
                        navigateTo(
                            SidebarSelection.Workbench(WorkbenchSelection.OVERVIEW),
                            openSchedules = true,
                        )
                    },
                    taskCenterSchedulesToken = taskCenterSchedulesToken,
                    onTaskCenterSchedulesHandled = {
                        taskCenterSchedulesToken = 0
                    },
                )
            }
        }

        if (persistentSidebar) {
            Row(Modifier.fillMaxSize().statusBarsPadding().floeMaterialSource(overlayMaterial)) {
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
                                FloeInspectorPane(route = route, onDismiss = { inspectorRoute = null }, runtimeHost = runtimeHost)
                            }
                        }
                    }
                }
            }
        } else {
            Box(Modifier.fillMaxSize().statusBarsPadding().floeMaterialSource(overlayMaterial)) {
                detail()
                // Compact drawer: iOS phone idiom — width
                // min(390, max(300, w-44)), rounded corner, slight scale of
                // the content plane, dim scrim, tap-scrim or back to close.
                AnimatedVisibility(
                    visible = drawerOpen,
                    enter = fadeIn(tween(200)) + slideInHorizontally(tween(320, easing = LinearOutSlowInEasing)) { -it },
                    exit = fadeOut(tween(180)) + slideOutHorizontally(tween(260)) { -it },
                ) {
                    // Even during the IME's exit animation the drawer panel
                    // must end above the keyboard instead of hiding its
                    // bottom rows behind it.
                    Box(Modifier.fillMaxSize().imePadding()) {
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
            Box(Modifier.fillMaxSize().statusBarsPadding().floeMaterialSource(overlayMaterial, zIndex = 1f)) {
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
                ) { FloeInspectorPane(route = route, onDismiss = { inspectorRoute = null }, runtimeHost = runtimeHost) }
            }
        }

        runtimeHost?.conversations?.notesChatTransfers?.let { transfers ->
            NotesChatTransferNotice(
                transfers,
                Modifier.align(Alignment.BottomCenter).navigationBarsPadding().imePadding()
                    .padding(16.dp).widthIn(max = 560.dp),
            )
        }

        // C07 share/setup surfaces. Both are dismissible Dialogs over the
        // CURRENT route; arrival never navigates. The notice is a small
        // bounded card, not a second navigation layer.
        C07EntryFlowSurface(
            onOpenSettingsSection = { key ->
                settingsSectionKey = key
                settingsVisible = true
            },
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .imePadding()
                .padding(horizontal = 16.dp, vertical = 8.dp),
        )

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
            // Channel-neutral seam: the FULL flavour contributes the category
            // only after the App integrator attaches a real presentation; the
            // PLAY flavour returns an empty list and imports no channel type.
            externalSections =
                com.floe.android.host.settings.DistributionSettingsFeature.sections() +
                    listOf(
                        com.floe.android.host.dataexchange.C07DataExchangeFeature
                            .settingsSection(runtimeHost),
                        C07EntryFlowFeature.settingsSection(),
                    ),
        )

        // G05-R3 Alpha14: one self-update surface (full channel only; the
        // Play flavour object renders nothing and opens no dialog).
        com.floe.android.host.update.AppUpdateFeature.DialogHost()

        if (previewVisible) {
            ComponentPreviewScreen(onDismiss = { previewVisible = false })
        }
    }
}

private fun drawerWidthPx(availableDp: Float) = FloeLayout.drawerWidth(availableDp)

/**
 * Home's Scheduled Tasks card may open the Task Center's schedules sub-view
 * ONLY when the committed route really is the Task Center. A temporary-chat
 * fence refusal performs no commit (nothing is opened), and any other target
 * stays a plain navigation. Pure so the route policy is pinned by a JVM test.
 */
internal fun taskCenterSchedulesOpenOnCommit(
    committed: SidebarSelection?,
    requestedFromHome: Boolean,
): Boolean = requestedFromHome &&
    committed == SidebarSelection.Workbench(WorkbenchSelection.OVERVIEW)

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

/**
 * The shell's restore decision (see the G02 selection persistence
 * contract at the top of [FloeShellContent]): the persisted key carries
 * ONLY durable/ordinary selections, while a live temporary surface is
 * RAM truth owned by the application-scoped runtime host. A recreation
 * re-adopts the live temporary when one exists (rotation/background/lock
 * keep the RAM session); a fresh process after true process death has no
 * RAM temporary, so it restores exactly what the durable persisted key
 * says — Home or a genuinely saved conversation — never a lost temporary
 * id reinterpreted as a blank ordinary chat.
 */
internal fun restoredShellSelection(
    savedKey: String,
    liveTemporaryConversationId: String?,
): SidebarSelection = liveTemporaryConversationId
    ?.let { SidebarSelection.Conversation(it) }
    ?: selectionFromKey(savedKey)

/** True when [next] is the conversation currently backed by the live RAM
 * temporary session. Such a selection must never reach saved state. */
internal fun isLiveTemporarySelection(
    next: SidebarSelection,
    liveTemporaryConversationId: String?,
): Boolean = next is SidebarSelection.Conversation &&
    liveTemporaryConversationId != null &&
    next.conversationId == liveTemporaryConversationId

/**
 * Whether a same-id Keep promotion may persist the durable saved
 * selection: ONLY while the visible surface is still the exact origin
 * conversation AND the registry still holds that same session epoch.
 * A visible-surface change (leave/new task), a replacement registration
 * under the same logical id (rebind/late reuse), or an absent entry all
 * drop the adoption — the genuine durable rows stay in history instead.
 */
internal fun keptPromotionAppliesToVisibleOrigin(
    visible: SidebarSelection,
    visibleConversationEpoch: Long?,
    origin: com.floe.android.feature.conversation.TemporarySessionRef,
): Boolean = visible is SidebarSelection.Conversation &&
    visible.conversationId == origin.conversationId &&
    visibleConversationEpoch == origin.sessionEpoch

/**
 * Whether a privacy-cleared conversation signal may invalidate the VISIBLE
 * surface: ONLY while the visible selection is still that exact durable
 * conversation AND the detail surface is bound to the EXACT signaled holder
 * instance ([boundHolder] identity — a re-opened/rebound same-id holder is a
 * different instance and is never retired/navigated by a stale signal) AND
 * the visible surface is not the live RAM temporary one. The shell
 * re-checks this after the off-main native-root await before committing the
 * New Task transition; Notes/survivor surfaces never match because their
 * visible selection is not this conversation.
 */
internal fun privacyClearedConversationAppliesToVisibleOrigin(
    visible: SidebarSelection,
    boundConversationId: String?,
    boundHolder: com.floe.android.feature.conversation.ConversationFlowHolder?,
    origin: com.floe.android.host.PrivacyClearedConversationSignal,
    liveTemporaryConversationId: String?,
): Boolean = visible is SidebarSelection.Conversation &&
    visible.conversationId == origin.conversationId &&
    visible.conversationId != liveTemporaryConversationId &&
    boundConversationId == origin.conversationId &&
    boundHolder != null && boundHolder === origin.holder

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
